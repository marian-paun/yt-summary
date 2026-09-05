#!/bin/bash
# lib/tts.sh - Text-to-Speech using Piper or edge-tts

# Map language codes to BCP-47 tags for SSML
lang_to_bcp47() {
    local lang="$1"
    case "$lang" in
        en) echo "en-US" ;;
        it) echo "it-IT" ;;
        es) echo "es-ES" ;;
        fr) echo "fr-FR" ;;
        de) echo "de-DE" ;;
        pt) echo "pt-BR" ;;
        ja) echo "ja-JP" ;;
        ko) echo "ko-KR" ;;
        zh) echo "zh-CN" ;;
        ru) echo "ru-RU" ;;
        ar) echo "ar-EG" ;;
        hi) echo "hi-IN" ;;
        ro) echo "ro-RO" ;;
        *) echo "en-US" ;;
    esac
}

# Get default edge-tts voice for a language
is_english_text() {
    local text="$1"
    local lower_text
    lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Common English words that are unlikely to appear in Romance languages
    local english_indicators=" the is are was were have has had will would can could should might may be been being do does did this that these those it its he she they we you i my your his her our their what which who whom how when where why not no yes but and or if then than so too very also just only even still already yet"

    local match_count=0
    local word_count=0

    # Count words and English indicator matches
    for word in $lower_text; do
        word_count=$((word_count + 1))
        if [[ "$english_indicators" == *" $word "* ]] || [[ "$english_indicators" == *" $word"* ]]; then
            match_count=$((match_count + 1))
        fi
    done

    # If more than 15% of words are English indicators, likely English
    if [[ $word_count -gt 0 ]]; then
        local ratio=$((match_count * 100 / word_count))
        if [[ $ratio -ge 15 ]]; then
            return 0  # Is English
        fi
    fi
    return 1  # Not English
}

# Detect language of a text segment based on Unicode character ranges and word patterns
detect_segment_language() {
    local text="$1"
    local target_lang="${2:-en}"
    local total_chars=0
    local latin_chars=0
    local cyrillic_chars=0
    local cjk_chars=0
    local arabic_chars=0
    local devanagari_chars=0

    # Count characters by script (simplified heuristic)
    local i char ord
    for (( i=0; i<${#text}; i++ )); do
        char="${text:$i:1}"
        ord=$(printf '%d' "'$char" 2>/dev/null || echo 0)

        # Skip spaces and punctuation (don't count as any script)
        if [[ $ord -lt 48 ]] || [[ $ord -gt 126 && $ord -lt 192 ]]; then
            continue
        fi

        total_chars=$((total_chars + 1))

        # Latin: 0x0041-0x005A, 0x0061-0x007A, 0x00C0-0x024F
        if [[ $ord -ge 65 && $ord -le 90 ]] || [[ $ord -ge 97 && $ord -le 122 ]] || \
           [[ $ord -ge 192 && $ord -le 591 ]]; then
            latin_chars=$((latin_chars + 1))
        # Cyrillic: 0x0400-0x04FF
        elif [[ $ord -ge 1024 && $ord -le 1279 ]]; then
            cyrillic_chars=$((cyrillic_chars + 1))
        # CJK Unified: 0x4E00-0x9FFF, 0x3040-0x309F (Hiragana), 0x30A0-0x30FF (Katakana)
        elif [[ $ord -ge 19968 && $ord -le 40959 ]] || \
             [[ $ord -ge 12352 && $ord -le 12447 ]] || \
             [[ $ord -ge 12448 && $ord -le 12543 ]]; then
            cjk_chars=$((cjk_chars + 1))
        # Arabic: 0x0600-0x06FF
        elif [[ $ord -ge 1536 && $ord -le 1791 ]]; then
            arabic_chars=$((arabic_chars + 1))
        # Devanagari (Hindi): 0x0900-0x097F
        elif [[ $ord -ge 2304 && $ord -le 2431 ]]; then
            devanagari_chars=$((devanagari_chars + 1))
        fi
    done

    if [[ $total_chars -eq 0 ]]; then
        echo "unknown"
        return
    fi

    # Require at least 20% of characters to be in a non-Latin script to trigger language switch
    local threshold=$((total_chars / 5))

    if [[ $cjk_chars -gt $threshold && $cjk_chars -gt $latin_chars ]]; then
        echo "cjk"
    elif [[ $cyrillic_chars -gt $threshold && $cyrillic_chars -gt $latin_chars ]]; then
        echo "ru"
    elif [[ $arabic_chars -gt $threshold ]]; then
        echo "ar"
    elif [[ $devanagari_chars -gt $threshold ]]; then
        echo "hi"
    elif [[ $latin_chars -gt 0 ]]; then
        # For Latin script, check if it's English or the target language
        # Only flag as English if target is NOT English and text appears to be English
        if [[ "$target_lang" != "en" ]] && is_english_text "$text"; then
            echo "en"
        else
            echo "latin"
        fi
    else
        echo "latin"
    fi
}

# Convert plain text to SSML with language-aware voice switching
text_to_ssml() {
    local text="$1"
    local target_lang="$2"
    local target_voice="$3"

    local bcp47_target
    bcp47_target=$(lang_to_bcp47 "$target_lang")

    # Split text into sentences (rough split on sentence boundaries)
    local sentences
    sentences=$(echo "$text" | sed 's/\([.!?]\)\s*/\1\n/g')

    local ssml="<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"${bcp47_target}\">"
    local has_foreign=false

    while IFS= read -r sentence || [[ -n "$sentence" ]]; do
        [[ -z "$sentence" ]] && continue

        local seg_lang
        seg_lang=$(detect_segment_language "$sentence" "$target_lang")

        case "$seg_lang" in
            latin)
                # Use target language voice
                ssml+="<voice name=\"${target_voice}\">${sentence}</voice>"
                ;;
            en)
                # English detected in non-English text - use English voice
                ssml+="<lang xml:lang=\"en-US\"><voice name=\"en-US-EmmaMultilingualNeural\">${sentence}</voice></lang>"
                has_foreign=true
                ;;
            ru)
                ssml+="<lang xml:lang=\"ru-RU\"><voice name=\"ru-RU-SvetlanaNeural\">${sentence}</voice></lang>"
                has_foreign=true
                ;;
            cjk)
                # Detect specific CJK language (simplified: default to Chinese for now)
                if [[ "$target_lang" == "ja" ]]; then
                    ssml+="<lang xml:lang=\"ja-JP\"><voice name=\"ja-JP-NanamiNeural\">${sentence}</voice></lang>"
                elif [[ "$target_lang" == "ko" ]]; then
                    ssml+="<lang xml:lang=\"ko-KR\"><voice name=\"ko-KR-SunHiNeural\">${sentence}</voice></lang>"
                else
                    ssml+="<lang xml:lang=\"zh-CN\"><voice name=\"zh-CN-XiaoxiaoNeural\">${sentence}</voice></lang>"
                fi
                has_foreign=true
                ;;
            ar)
                ssml+="<lang xml:lang=\"ar-EG\"><voice name=\"ar-EG-SalmaNeural\">${sentence}</voice></lang>"
                has_foreign=true
                ;;
            hi)
                ssml+="<lang xml:lang=\"hi-IN\"><voice name=\"hi-IN-SwaraNeural\">${sentence}</voice></lang>"
                has_foreign=true
                ;;
            *)
                ssml+="<voice name=\"${target_voice}\">${sentence}</voice>"
                ;;
        esac
    done <<< "$sentences"

    ssml+="</speak>"

    # Return the SSML and whether foreign segments were found
    if [[ "$has_foreign" == "true" ]]; then
        echo "$ssml"
        return 0
    else
        return 1
    fi
}

get_voice_for_language() {
    local language="${1:-en}"
    local voice_override="${2:-}"
    local voices_dir="${3:-${VOICES_DIR:-/data/configs/voices}}"

    if [[ -n "$voice_override" ]]; then
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
        ls "$voices_dir"/*.onnx 2>/dev/null | xargs -n1 basename | sed 's/.onnx$//' | while read -r v; do
            echo "  - $v"
        done
        return 1
    fi

    case "$language" in
        ro)
            echo "${voices_dir}/ro_RO-mihai-medium.onnx"
            ;;
        *)
            echo "${voices_dir}/en_GB-alan-medium.onnx"
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
    
    # Map language codes to edge-tts voice prefixes
    case "$language" in
        en) lang_prefix="en" ;;
        es) lang_prefix="es" ;;
        fr) lang_prefix="fr" ;;
        de) lang_prefix="de" ;;
        it) lang_prefix="it" ;;
        pt) lang_prefix="pt" ;;
        ja) lang_prefix="ja" ;;
        ko) lang_prefix="ko" ;;
        zh) lang_prefix="zh" ;;
        ru) lang_prefix="ru" ;;
        ar) lang_prefix="ar" ;;
        hi) lang_prefix="hi" ;;
        ro) lang_prefix="ro" ;;
        *) lang_prefix="en" ;; # Default to English
    esac
    
    if [[ -n "$voice_override" ]]; then
        echo "$voice_override"
        return 0
    fi
    
    # Return a default voice for the language
    case "$language" in
        en) echo "en-US-EmmaMultilingualNeural" ;;
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
        ro) echo "ro-RO-AlinaNeural" ;;
        *) echo "en-US-EmmaMultilingualNeural" ;;
    esac
}

generate_audio_piper() {
    local text="$1"
    local voice_path="$2"
    local output_file="$3"
    local format="${4:-m4a}"
    local ssml_input="${5:-false}"

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

    # Piper doesn't support SSML natively, so strip tags if SSML input
    local clean_text="$text"
    if [[ "$ssml_input" == "true" ]]; then
        # Strip SSML tags, keeping only text content
        clean_text=$(echo "$text" | sed 's/<[^>]*>//g' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
        log_debug "Stripped SSML tags for Piper input"
    fi

    log_debug "Writing text to: $input_file"
    echo "$clean_text" > "$input_file"

    log_info "Generating audio with Piper..."

    if ! /home/marp/.local/bin/piper -m "$voice_path" -c "$config_path" -i "$input_file" -f "$wav_file" 2>&1; then
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
    local ssml_input="${5:-false}"

    case "$format" in
        m4a) output_format="audio-16khz-128kbitrate-mono-mp3" ;;
        mp3) output_format="audio-16khz-128kbitrate-mono-mp3" ;;
        *)
            log_error "Invalid audio format: $format (must be: m4a, mp3)"
            return 1
            ;;
    esac

    # Create temporary file for text input
    local temp_dir="${TMP_BASE}/edge-tts_$$"
    mkdir -p "$temp_dir"
    local input_file="${temp_dir}/input.txt"
    echo "$text" > "$input_file"

    log_info "Generating audio with edge-tts using voice: $voice"

    # edge-tts does not support --ssml; strip tags if SSML input
    local edge_tts_text
    if [[ "$ssml_input" == "true" ]]; then
        edge_tts_text=$(sed 's/<[^>]*>//g; s/  */ /g; s/^ //; s/ $//' "$input_file")
        log_debug "Stripped SSML tags for edge-tts input"
    else
        edge_tts_text=$(cat "$input_file")
    fi

    # Use edge-tts to generate audio
    local edge_tts_args=("--voice" "$voice" "--write-media" "$output_file" "--text" "$edge_tts_text")

    if ! output=$(/home/marp/.local/bin/edge-tts "${edge_tts_args[@]}" 2>&1); then
        log_error "edge-tts failed to generate audio: $output"
        rm -rf "$temp_dir"
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
            return 1
        fi
    fi

    rm -rf "$temp_dir"
    log_info "Audio saved to: $output_file"
    return 0
}

generate_audio() {
    local text="$1"
    local voice_setting="$2"
    local output_file="$3"
    local format="${4:-m4a}"
    local tts_engine="${5:-piper}"
    local language="${6:-en}"
    local voices_dir="${7:-${VOICES_DIR:-/data/configs/voices}}"

    # Try to generate SSML with multi-language voice switching
    local ssml_output=""
    local use_ssml=false

    case "$tts_engine" in
        piper)
            local voice_path
            # If voice_setting is already a full path, use it directly
            if [[ "$voice_setting" == /* ]] && [[ -f "$voice_setting" ]]; then
                voice_path="$voice_setting"
            else
                voice_path=$(get_voice_for_language "$language" "$voice_setting" "$voices_dir") || return 1
            fi
            # Piper doesn't support SSML voice switching, skip SSML generation
            generate_audio_piper "$text" "$voice_path" "$output_file" "$format" "false"
            ;;
        edge-tts)
            local voice
            voice=$(get_edge_tts_voice "$language" "$voice_setting") || return 1

            # Try to generate SSML for multi-language support
            if ssml_output=$(text_to_ssml "$text" "$language" "$voice"); then
                use_ssml=true
                log_info "Multi-language content detected, using SSML with voice switching"
            fi

            if [[ "$use_ssml" == "true" ]]; then
                generate_audio_edge_tts "$ssml_output" "$voice" "$output_file" "$format" "true"
            else
                generate_audio_edge_tts "$text" "$voice" "$output_file" "$format" "false"
            fi
            ;;
        *)
            log_error "Invalid TTS engine: $tts_engine (must be: piper, edge-tts)"
            return 1
            ;;
    esac
}
