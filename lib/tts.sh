#!/bin/bash
# lib/tts.sh - Text-to-Speech using Piper or edge-tts

: "${PIPER_BIN:=piper}"
: "${EDGE_TTS_BIN:=edge-tts}"

# Why the last generate_audio_edge_tts call failed. Empty on success.
#   "fallback" - edge-tts could not deliver the audio (binary missing, network
#                or service error, rate limit, crash). Worth retrying locally
#                with piper.
#   "fatal"    - the request or the local tooling is at fault (bad voice name,
#                bad output format, ffmpeg failure). Retrying under piper would
#                fail the same way and hide the real cause.
EDGE_TTS_FAILURE=""

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

    local edge_tts_bin
    if ! edge_tts_bin=$(resolve_tts_bin "$EDGE_TTS_BIN" "edge-tts"); then
        rm -rf "$temp_dir"
        EDGE_TTS_FAILURE="fallback"
        return 1
    fi

    # A non-zero exit here means edge-tts could not deliver the audio: the
    # service refused the connection, was unavailable, throttled the request,
    # or the client crashed. All of these are worth retrying locally.
    if ! output=$("$edge_tts_bin" "${edge_tts_args[@]}" 2>&1); then
        log_error "edge-tts failed to generate audio: $output"
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

generate_audio() {
    local text="$1"
    local voice_setting="$2"
    local output_file="$3"
    local format="${4:-m4a}"
    local tts_engine="${5:-piper}"
    local language="${6:-en}"
    local voices_dir="${7:-${VOICES_DIR:-/data/configs/voices}}"

    # Strip markdown headers, section titles, chapter markers, and bullet point markers for audio reading
    text=$(echo "$text" | sed -E 's/^[#[:space:]]*(Summary|Key Points|Key-Points|Overview|Highlights|Key Takeaways)[[:space:]]*$//gi' \
                       | sed -E 's/^[#[:space:]]+//' \
                       | sed -E 's/^[[:space:]]*[-*+][[:space:]]+//' \
                       | sed -E '/^[[:space:]]*$/d')

    case "$tts_engine" in
        piper)
            generate_audio_with_piper "$text" "$voice_setting" "$output_file" "$format" "$language" "$voices_dir"
            ;;
        edge-tts)
            local voice
            voice=$(get_edge_tts_voice "$language" "$voice_setting") || return 1

            if generate_audio_edge_tts "$text" "$voice" "$output_file" "$format"; then
                return 0
            fi

            # Retry locally only when edge-tts itself could not deliver the
            # audio. A bad voice name or a local ffmpeg problem would fail the
            # same way under piper, and falling back would bury the real cause
            # behind a silently different voice.
            if [[ "$EDGE_TTS_FAILURE" != "fallback" ]]; then
                return 1
            fi

            log_warn "edge-tts unavailable, falling back to piper"
            rm -f "$output_file"  # discard any partial output from the failed attempt
            # The requested --voice is an edge-tts voice name with no piper
            # equivalent, so the fallback uses the default voice for the
            # detected language instead.
            generate_audio_with_piper "$text" "" "$output_file" "$format" "$language" "$voices_dir"
            ;;
        *)
            log_error "Invalid TTS engine: $tts_engine (must be: piper, edge-tts)"
            return 1
            ;;
    esac
}
