#!/bin/bash
# lib/tts.sh - Text-to-Speech using Piper, edge-tts, or gtts-cli

: "${PIPER_BIN:=piper}"
: "${EDGE_TTS_BIN:=edge-tts}"
: "${GTTS_CLI_BIN:=gtts-cli}"
: "${EDGE_TTS_TIMEOUT:=30}"
: "${EDGE_TTS_ATTEMPTS:=3}"

# Why the last generate_audio_edge_tts call failed. Empty on success.
#   "fallback" - edge-tts could not deliver the audio (binary missing, network
#                or service error, rate limit, crash). Worth retrying locally
#                with piper.
#   "fatal"    - the request or the local tooling is at fault (bad voice name,
#                bad output format, ffmpeg failure). Retrying under piper
#                would fail the same way and hide the real cause.
EDGE_TTS_FAILURE=""

# Mask credentials in a proxy URL (or free text) for logging.
#   scheme://user:pass@host:port -> scheme://***@host:port
mask_proxy_credentials() {
    printf '%s' "$1" | sed -E 's#(://)[^/@[:space:]]*@#\1***@#g'
}

# Resolve a TTS binary name or path to an absolute executable path.
# Accepts a path to an existing file, otherwise looks the name up on PATH.
resolve_tts_bin() {
    local bin="$1"
    local label="$2"

    if [[ "$bin" == */* ]]; then
        if [[ -x "$bin" ]]; then
            echo "$bin"
            return 0
        fi
    else
        local resolved
        if resolved=$(command -v "$bin" 2>/dev/null) && [[ -n "$resolved" ]]; then
            echo "$resolved"
            return 0
        fi
    fi

    log_error "$label not found: $bin"
    log_error "Install it or set the corresponding *_BIN variable to its full path"
    return 1
}

get_voice_for_language() {
    local language="${1:-en}"
    local voice_override="${2:-}"
    local voices_dir="${3:-${VOICES_DIR:-/data/configs/voices}}"

    if [[ -n "$voice_override" ]]; then
        # Already a usable path to a voice file.
        if [[ -f "$voice_override" ]]; then
            echo "$voice_override"
            return 0
        fi
        # Relative to VOICES_DIR, with or without the .onnx extension.
        local voice_path="${voices_dir}/${voice_override}.onnx"
        if [[ -f "$voice_path" ]]; then
            echo "$voice_path"
            return 0
        fi
        voice_path="${voices_dir}/${voice_override}"
        if [[ -f "$voice_path" ]]; then
            echo "$voice_path"
            return 0
        fi
        log_error "Voice not found: $voice_override"
        log_error "Available voices in ${voices_dir}:"
        find "$voices_dir" -maxdepth 1 -name '*.onnx' -type f -print0 2>/dev/null \
            | xargs -0 -r -n1 basename | sed 's/\.onnx$//' | while read -r v; do
            echo "  - $v"
        done
        return 1
    fi

    case "$language" in
        ro)
            echo "${voices_dir}/${DEFAULT_VOICE_PIPER_RO:-ro_RO-sanda-high}.onnx"
            ;;
        *)
            echo "${voices_dir}/${DEFAULT_VOICE_PIPER_EN:-en_US-ryan-high}.onnx"
            ;;
    esac
}

check_voice_exists() {
    local voice_path="$1"

    if [[ ! -f "$voice_path" ]]; then
        log_error "Voice file not found: $voice_path"
        return 1
    fi

    local config_path="${voice_path%.onnx}.onnx.json"
    if [[ ! -f "$config_path" ]]; then
        log_error "Voice config not found: $config_path"
        return 1
    fi

    return 0
}

get_edge_tts_voice() {
    local language="${1:-en}"
    local voice_override="${2:-}"

    if [[ -n "$voice_override" ]]; then
        echo "$voice_override"
        return 0
    fi
    
    # Return a default voice for the language
    case "$language" in
        en) echo "${DEFAULT_VOICE_TTS_EN:-en-US-EmmaMultilingualNeural}" ;;
        es) echo "es-ES-ElviraNeural" ;;
        fr) echo "fr-FR-DeniseNeural" ;;
        de) echo "de-DE-KatjaNeural" ;;
        it) echo "it-IT-ElsaNeural" ;;
        pt) echo "pt-BR-FranciscaNeural" ;;
        ja) echo "ja-JP-NanamiNeural" ;;
        ko) echo "ko-KR-SunHiNeural" ;;
        zh) echo "zh-CN-XiaoxiaoNeural" ;;
        ru) echo "ru-RU-SvetlanaNeural" ;;
        ar) echo "ar-EG-SalmaNeural" ;;
        hi) echo "hi-IN-SwaraNeural" ;;
        ro) echo "${DEFAULT_VOICE_TTS_RO:-ro-RO-AlinaNeural}" ;;
        *) echo "${DEFAULT_VOICE_TTS_EN:-en-US-EmmaMultilingualNeural}" ;;
    esac
}

generate_audio_piper() {
    local text="$1"
    local voice_path="$2"
    local output_file="$3"
    local format="${4:-m4a}"

    if ! check_voice_exists "$voice_path"; then
        return 1
    fi

    case "$format" in
        m4a|mp3) ;;
        *)
            log_error "Invalid audio format: $format (must be: m4a, mp3)"
            return 1
            ;;
    esac

    local config_path="${voice_path%.onnx}.onnx.json"
    local temp_dir="${TMP_BASE}/tts_$$"
    mkdir -p "$temp_dir"

    local input_file="${temp_dir}/input.txt"
    local wav_file="${temp_dir}/output.wav"

    log_debug "Writing text to: $input_file"
    echo "$text" > "$input_file"

    log_info "Generating audio with Piper..."

    local piper_bin
    piper_bin=$(resolve_tts_bin "$PIPER_BIN" "Piper") || { rm -rf "$temp_dir"; return 1; }

    if ! "$piper_bin" -m "$voice_path" -c "$config_path" -i "$input_file" -f "$wav_file" 2>&1; then
        log_error "Piper failed to generate audio"
        rm -rf "$temp_dir"
        return 1
    fi

    log_debug "Converting to $format..."

    if [[ "$format" == "m4a" ]]; then
        local codec="aac"
    else
        local codec="libmp3lame"
    fi

    if ! ffmpeg -y -i "$wav_file" -vn -c:a "$codec" -b:a "192k" "$output_file" 2>&1 | grep -v "^\\["; then
        log_error "FFmpeg conversion failed"
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"

    log_info "Audio saved to: $output_file"
    return 0
}

generate_audio_edge_tts() {
    local text="$1"
    local voice="$2"
    local output_file="$3"
    local format="${4:-m4a}"
    local proxy="${5:-}"
    local output

    case "$format" in
        m4a|mp3) ;;
        *)
            log_error "Invalid audio format: $format (must be: m4a, mp3)"
            EDGE_TTS_FAILURE="fatal"
            return 1
            ;;
    esac

    # edge-tts rejects anything that is not an edge-tts voice name
    # client-side. Checking it here keeps a typo from being silently degraded
    # to a different engine - and a different voice - by the piper fallback.
    if [[ ! "$voice" =~ ^[a-z]{2,}-[A-Z]{2,}-(.+Neural)$ ]]; then
        log_error "Invalid edge-tts voice name: $voice"
        log_error "Voice names look like 'ro-RO-AlinaNeural' (see: $EDGE_TTS_BIN --list-voices)"
        EDGE_TTS_FAILURE="fatal"
        return 1
    fi

    # Create temporary file for text input
    local temp_dir="${TMP_BASE}/edge-tts_$$"
    mkdir -p "$temp_dir"
    local input_file="${temp_dir}/input.txt"
    echo "$text" > "$input_file"

    log_info "Generating audio with edge-tts using voice: $voice"

    local edge_tts_text
    edge_tts_text=$(cat "$input_file")

    # Use edge-tts to generate audio
    local edge_tts_args=("--voice" "$voice" "--write-media" "$output_file" "--text" "$edge_tts_text")

    # Add proxy support if provided
    if [[ -n "$proxy" ]]; then
        edge_tts_args+=("--proxy" "$proxy")
    elif [[ -n "${EDGE_TTS_PROXY:-}" ]]; then
        edge_tts_args+=("--proxy" "$EDGE_TTS_PROXY")
    fi

    local edge_tts_bin
    if ! edge_tts_bin=$(resolve_tts_bin "$EDGE_TTS_BIN" "edge-tts"); then
        rm -rf "$temp_dir"
        EDGE_TTS_FAILURE="fallback"
        return 1
    fi

    # Disable SSL verification when using a proxy (allows self-signed certs on local proxies)
    # PYTHONHTTPSVERIFY affects stdlib ssl/urllib; AIOHTTP_CLIENT_SSL_VERIFY affects aiohttp
    local ssl_verify="1"
    if [[ -n "$proxy" ]] || [[ -n "${EDGE_TTS_PROXY:-}" ]]; then
        ssl_verify="0"
    fi

    # A non-zero exit here means edge-tts could not deliver the audio: the
    # service refused the connection, was unavailable, throttled the request,
    # or the client crashed. All of these are worth retrying locally.
    # A timeout guards against a hung connection (e.g. a dead proxy).
    if ! output=$(PYTHONHTTPSVERIFY="$ssl_verify" AIOHTTP_CLIENT_SSL_VERIFY="$ssl_verify" timeout "$EDGE_TTS_TIMEOUT" "$edge_tts_bin" "${edge_tts_args[@]}" 2>&1); then
        log_error "edge-tts failed to generate audio: $(mask_proxy_credentials "$output")"
        rm -rf "$temp_dir"
        EDGE_TTS_FAILURE="fallback"
        return 1
    fi

    # edge-tts outputs mp3 by default, convert if needed for m4a
    if [[ "$format" == "m4a" ]]; then
        log_debug "Converting MP3 to M4A..."
        local temp_mp3="${temp_dir}/temp.mp3"
        mv "$output_file" "$temp_mp3"
        if ! ffmpeg -y -i "$temp_mp3" -vn -c:a aac -b:a "192k" "$output_file" 2>&1; then
            log_error "FFmpeg conversion from MP3 to M4A failed"
            rm -rf "$temp_dir"
            # ffmpeg is local and is also what piper needs, so a retry would
            # fail identically.
            EDGE_TTS_FAILURE="fatal"
            return 1
        fi
    fi

    rm -rf "$temp_dir"
    log_info "Audio saved to: $output_file"
    return 0
}

# Generate audio with gtts-cli (Google Text-to-Speech).
# gtts-cli outputs MP3 by default; we convert to M4A if needed.
# Supported languages: see `gtts-cli --all` for the full list.
# Common language codes: en, ro, es, fr, de, it, pt, ja, ko, zh, ru, ar, hi, etc.
generate_audio_gtts_cli() {
    local text="$1"
    local language="$2"
    local output_file="$3"
    local format="${4:-m4a}"
    local slow="${5:-false}"
    local output

    case "$format" in
        m4a|mp3) ;;
        *)
            log_error "Invalid audio format: $format (must be: m4a, mp3)"
            return 1
            ;;
    esac

    # Create temporary file for text input
    local temp_dir="${TMP_BASE}/gtts-cli_$$"
    mkdir -p "$temp_dir"
    local input_file="${temp_dir}/input.txt"
    echo "$text" > "$input_file"

    log_info "Generating audio with gtts-cli using language: $language"

    local gtts_bin
    if ! gtts_bin=$(resolve_tts_bin "$GTTS_CLI_BIN" "gtts-cli"); then
        rm -rf "$temp_dir"
        return 1
    fi

    # gtts-cli reads from stdin with -f - or from file with -f FILE
    # Use -f - to read from stdin for reliability with long texts
    local gtts_args=("--lang" "$language" "--output" "$output_file" "-f" "-")
    [[ "$slow" == "true" ]] && gtts_args+=("--slow")

    if ! output=$("$gtts_bin" "${gtts_args[@]}" < "$input_file" 2>&1); then
        log_error "gtts-cli failed to generate audio: $output"
        rm -rf "$temp_dir"
        return 1
    fi

    # gtts-cli outputs MP3 by default, convert if needed for m4a
    if [[ "$format" == "m4a" ]]; then
        log_debug "Converting MP3 to M4A..."
        local temp_mp3="${temp_dir}/temp.mp3"
        mv "$output_file" "$temp_mp3"
        if ! ffmpeg -y -i "$temp_mp3" -vn -c:a aac -b:a "192k" "$output_file" 2>&1; then
            log_error "FFmpeg conversion from MP3 to M4A failed"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    rm -rf "$temp_dir"
    log_info "Audio saved to: $output_file"
    return 0
}

# Generate audio with Piper, resolving the voice for the target language.
# voice_setting may be empty, a name in voices_dir, or a path to a .onnx file.
generate_audio_with_piper() {
    local text="$1"
    local voice_setting="$2"
    local output_file="$3"
    local format="$4"
    local language="$5"
    local voices_dir="$6"

    local voice_path
    # If voice_setting is already a full path, use it directly
    if [[ "$voice_setting" == /* ]] && [[ -f "$voice_setting" ]]; then
        voice_path="$voice_setting"
    else
        voice_path=$(get_voice_for_language "$language" "$voice_setting" "$voices_dir") || return 1
    fi

    generate_audio_piper "$text" "$voice_path" "$output_file" "$format"
}

prepare_tts_text() {
    local text="$1"
    echo "$text" | sed -E 's/^[#[:space:]]*(Summary|Key Points|Key-Points|Overview|Highlights|Key Takeaways)[[:space:]]*$//gi' \
                       | sed -E 's/^[#[:space:]]+//' \
                       | sed -E 's/^[[:space:]]*[-*+][[:space:]]+//' \
                       | sed -E '/^[[:space:]]*$/d'
}

# Try a single edge-tts endpoint (direct when proxy is empty, otherwise the
# given proxy) up to EDGE_TTS_ATTEMPTS times. Returns 0 on the first success.
# Leaves EDGE_TTS_FAILURE holding the class of the last failure so the caller
# can decide whether another endpoint is worth trying.
_edge_tts_try_endpoint() {
    local text="$1"
    local voice="$2"
    local output_file="$3"
    local format="$4"
    local proxy="$5"

    local attempts="${EDGE_TTS_ATTEMPTS:-3}"
    if [[ ! "$attempts" =~ ^[0-9]+$ ]] || (( attempts < 1 )); then
        attempts=3
    fi

    local label="direct connection"
    [[ -n "$proxy" ]] && label="proxy $(mask_proxy_credentials "$proxy")"

    local attempt
    for (( attempt = 1; attempt <= attempts; attempt++ )); do
        rm -f "$output_file"  # drop any partial output
        EDGE_TTS_FAILURE=""
        if generate_audio_edge_tts "$text" "$voice" "$output_file" "$format" "$proxy"; then
            return 0
        fi
        # A fatal error would fail identically on every attempt and endpoint.
        [[ "$EDGE_TTS_FAILURE" != "fallback" ]] && return 1
        if (( attempt < attempts )); then
            log_warn "edge-tts ${label} failed (attempt ${attempt}/${attempts}); retrying"
        fi
    done

    return 1
}

generate_audio() {
    local text="$1"
    local voice_setting="$2"
    local output_file="$3"
    local format="${4:-m4a}"
    local tts_engine="${5:-piper}"
    local language="${6:-en}"
    local voices_dir="${7:-${VOICES_DIR:-/data/configs/voices}}"

    text=$(prepare_tts_text "$text")

    case "$tts_engine" in
        piper)
            generate_audio_with_piper "$text" "$voice_setting" "$output_file" "$format" "$language" "$voices_dir"
            ;;
        edge-tts)
            # 1. edge-tts: resolve the voice, then try a direct connection.
            local voice
            voice=$(get_edge_tts_voice "$language" "$voice_setting") || return 1

            if _edge_tts_try_endpoint "$text" "$voice" "$output_file" "$format" ""; then
                return 0
            fi

            # A fatal error (bad voice/format, local ffmpeg failure) would
            # fail the same way through every proxy and through piper, so
            # abort now instead of silently degrading to a different voice.
            if [[ "$EDGE_TTS_FAILURE" != "fallback" ]]; then
                return 1
            fi

            # 2. The failure was recoverable (network/service): try the
            #    configured proxies in sequence.
            local -a proxies_to_try=()
            if [[ -n "${EDGE_TTS_PROXIES:-}" ]]; then
                IFS=',' read -ra proxy_list <<< "$EDGE_TTS_PROXIES"
                for p in "${proxy_list[@]}"; do
                    p="$(echo "$p" | xargs)"
                    [[ -n "$p" ]] && proxies_to_try+=("$p")
                done
            fi
            # Individual proxy variables: EDGE_TTS_PROXY1..4, in order.
            local i var_name proxy_val
            for i in 1 2 3 4; do
                var_name="EDGE_TTS_PROXY${i}"
                proxy_val="${!var_name:-}"
                [[ -n "$proxy_val" ]] && proxies_to_try+=("$proxy_val")
            done

            # Deduplicate while preserving order.
            local tried_proxies=() p tp is_dup
            for p in "${proxies_to_try[@]}"; do
                is_dup=false
                for tp in "${tried_proxies[@]}"; do
                    [[ "$tp" == "$p" ]] && { is_dup=true; break; }
                done
                [[ "$is_dup" == false ]] && tried_proxies+=("$p")
            done

            if [[ ${#tried_proxies[@]} -gt 0 ]]; then
                log_info "Direct edge-tts failed; trying ${#tried_proxies[@]} configured proxy(ies)"
            fi

            for p in "${tried_proxies[@]}"; do
                log_info "Trying edge-tts with proxy: $(mask_proxy_credentials "$p")"
                if _edge_tts_try_endpoint "$text" "$voice" "$output_file" "$format" "$p"; then
                    return 0
                fi
                # A fatal error through a proxy would fail the same way
                # through piper, so abort instead of degrading.
                [[ "$EDGE_TTS_FAILURE" != "fallback" ]] && return 1
            done

            log_warn "edge-tts unavailable, falling back to gtts-cli"
            # 3. Try gtts-cli (Google TTS).
            # Map language code for gtts-cli (it uses ISO 639-1 codes)
            local gtts_lang="$language"
            case "$language" in
                ro) gtts_lang="ro" ;;
                en) gtts_lang="en" ;;
                es) gtts_lang="es" ;;
                fr) gtts_lang="fr" ;;
                de) gtts_lang="de" ;;
                it) gtts_lang="it" ;;
                pt) gtts_lang="pt" ;;
                ja) gtts_lang="ja" ;;
                ko) gtts_lang="ko" ;;
                zh) gtts_lang="zh" ;;
                ru) gtts_lang="ru" ;;
                ar) gtts_lang="ar" ;;
                hi) gtts_lang="hi" ;;
                *) gtts_lang="en" ;;
            esac
            rm -f "$output_file"
            if generate_audio_gtts_cli "$text" "$gtts_lang" "$output_file" "$format"; then
                return 0
            fi

            log_warn "gtts-cli unavailable, falling back to piper"

            # 4. Try piper (local, faster, but requires model download).
            rm -f "$output_file"
            if generate_audio_with_piper "$text" "" "$output_file" "$format" "$language" "$voices_dir"; then
                return 0
            fi

            # Piper failed too. Signal the caller to deliver the text another
            # way (Telegram).
            export SEND_TELEGRAM=true # Force Telegram send
            return 1 # Indicate failure so the caller can send summary via Telegram
            ;;
        *)
            log_error "Invalid TTS engine: $tts_engine (must be: piper, edge-tts)"
            return 1
            ;;
    esac
}
