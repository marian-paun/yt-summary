#!/bin/bash
# lib/help.sh - Usage/help output and the .env reference
#
# Rendering levels:
#   usage short  -> synopsis only, used for error paths (missing target,
#                   unknown option) so real errors are not buried in the
#                   full help text
#   usage help   -> option reference (--help / -h)
#   usage all    -> options + advanced/legacy + every .env variable
#                   (--help-all)

# Print the effective value of the variable named by $1.
# Empty values are reported as "(unset)" so "KEY=" and a missing key look alike.
env_show() {
  local name="$1" value=""
  if [[ -v $name ]]; then
    value="${!name}"
  fi
  if [[ -z "$value" ]]; then
    printf '(unset)'
  elif [[ "$value" == *$'\n'* ]]; then
    # Multi-line values (heredoc prompts) are summarized, not dumped
    printf '(set: %d lines, %d chars)' "$(printf '%s\n' "$value" | wc -l)" "${#value}"
  elif (( ${#value} > 72 )); then
    printf '(set: %d chars)' "${#value}"
  else
    printf '%s' "$value"
  fi
}

# Same as env_show, but never prints the value itself: secrets report only
# whether they are configured.
env_show_secret() {
  local name="$1"
  if [[ -v $name && -n "${!name}" ]]; then
    printf '(set)'
  else
    printf '(unset)'
  fi
}

# env_entry NAME VALUE DESCRIPTION...
env_entry() {
  local name="$1" value="$2"
  shift 2
  printf '  %-28s %s\n' "$name" "$value"
  local line
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
}

usage_synopsis() {
  cat <<EOF
yt-summary - YouTube video/playlist summarizer using Ollama/LiteLLM/Omniroute

USAGE:
  yt-summary [options] <target>
  yt-summary --help
  yt-summary --help-all

TARGET:
  YouTube video URL, playlist URL, or a text file containing URLs (one per line)
EOF
}

usage_help() {
  cat <<EOF
yt-summary - YouTube video/playlist summarizer using Ollama/LiteLLM/Omniroute

USAGE:
  yt-summary [options] <target>
  yt-summary --help
  yt-summary --help-all

CONFIGURATION:
  A .env file in the script directory (gitignored) sets all defaults.
  Precedence: CLI flags > environment variables > .env > hard defaults.
  Run 'yt-summary --help-all' for advanced/legacy options and the full list of
  .env variables.

TARGET:
  YouTube video URL, playlist URL, or a text file containing URLs (one per line)

BACKEND & MODEL OPTIONS:
  --backend BACKEND          LLM backend: ollama, litellm, omniroute, fallback (default: ${LLM_BACKEND})
  -m, --model MODEL          Model name (default: ${OLLAMA_MODEL})
  --url, --proxy URL         Backend server/proxy URL (default: ${OLLAMA_HOST})
  --api-key, --key KEY       API key for LiteLLM or Omniroute
  --host HOST                Ollama server URL (default: ${OLLAMA_HOST})
  --num-ctx NUM              Context window size for Ollama (default: ${OLLAMA_NUM_CTX})

CONTENT & OUTPUT OPTIONS:
  --length LENGTH            Summary length: short, medium, long (default: ${SUMMARY_LENGTH})
  -l, --language LANG        Target language (ISO 639 code, default: ${TARGET_LANGUAGE})
  --summary-only             Only generate summary section
  --key-points-only          Only generate key points section
  --print-only               Print output to console only
  --save-only                Save output to file only
  -s, --stats                Show session statistics at the end
  --include-stats            Include per-video statistics in output document
  -e, --email EMAIL          Send output to email address
  --from EMAIL               Sender email address (default: same as --email)
  --telegram                 Send per-video statistics as a Telegram message

AUDIO (TTS) OPTIONS:
  --audio                    Generate audio from summary
  --audio-output FILE        Output audio file path
  --audio-format FORMAT      Audio format: m4a or mp3 (default: ${AUDIO_FORMAT})
  --voice VOICE              Explicit voice name (overrides language selection);
                               for piper also accepts a filename in VOICES_DIR or a path to a .onnx file
  --tts-engine ENGINE        TTS engine: piper or edge-tts (default: ${TTS_ENGINE});
                               edge-tts falls back to piper when it cannot reach the service
  --no-phonetic              Disable phonetic rewrite of foreign words before TTS (default: enabled)

TRANSCRIPTION FALLBACK (WHISPER) OPTIONS:
  All options below configure the whisper-ctranslate2 fallback, used when no
  subtitles are available: the audio track is transcribed (locally or via SSH).
  --no-whisper               Disable the whisper transcription fallback
  --whisper-host HOST        whisper host: localhost or remote IP/hostname (default: ${WHISPER_HOST})
  --whisper-model MODEL      whisper model: tiny/base/small/medium/large-v3 (default: ${WHISPER_MODEL})
  --whisper-ssh-user USER    SSH username on the remote whisper host
  --whisper-ssh-auth AUTH    SSH auth mode: config | key | password (default: ${WHISPER_SSH_AUTH})
  --whisper-ssh-key KEY      SSH private key path when auth=key (default: ${WHISPER_SSH_KEY})
  --whisper-ssh-password PASSWORD
                             SSH password when auth=password (requires sshpass)
  --whisper-transfer MODE    Audio transfer: rsync | scp | shared (default: ${WHISPER_TRANSFER})
  --whisper-remote-dir DIR   Remote work dir on whisper host (default: ${WHISPER_REMOTE_DIR})
  --whisper-shared-dir DIR   Shared folder path when transfer=shared

PLAYLIST OPTIONS:
  --max-playlist-videos N    Maximum number of videos to process from playlists (0 = no limit)
  --max-playlist-video-age-days D
                             Maximum age of videos to process from playlists in days (0 = no limit)

SYSTEM & CACHE OPTIONS:
  -f, --force                Force regeneration even if cached
  --no-auto-chunk            Disable the LLM chunk-size recommendation (use CHUNK_WORDS)
  --cleanup                  Delete temporary files after processing
  -v, --verbose              Enable verbose/debug output

HELP OPTIONS:
  -h, --help                 Show this help summary
  --help-all                 Show all options (advanced/legacy) and every .env variable
EOF
}

usage_advanced() {
  cat <<EOF

ADVANCED & LEGACY OPTIONS:
  --think                    Enable think/reasoning mode (Ollama, Omniroute, LiteLLM, Fallback)
  --chunk-words WORDS        Target words per chunk (default: ${CHUNK_WORDS}; disables auto chunk size)
  --auto-chunk               Ask the LLM for the recommended chunk size before summarizing
                             (default: ${AUTO_CHUNK})
  --max-tokens TOKENS        Max tokens per response (default: ${MAX_TOKENS})
  --temperature TEMP         Temperature for LLM (default: ${TEMPERATURE})
  --max-retries RETRIES      Max retries per LLM call (default: ${MAX_RETRIES})
  --testing                  Testing mode: generate output without caching or stats
  --ignore-processed         Skip videos that have already been processed
  --transcript-verbose       Show transcript fetching details
  --litellm-proxy URL        [Deprecated] Alias for --backend litellm --url URL
  --litellm-model MODEL      [Deprecated] Alias for --backend litellm --model MODEL
  --litellm-key KEY          [Deprecated] Alias for --backend litellm --api-key KEY
  --omniroute URL            [Deprecated] Alias for --backend omniroute --url URL
  --omniroute-model MODEL    [Deprecated] Alias for --backend omniroute --model MODEL
  --omniroute-key KEY        [Deprecated] Alias for --backend omniroute --api-key KEY
EOF
}

usage_env() {
  cat <<EOF

ENVIRONMENT / .env REFERENCE:
  Every variable below can be set in the .env file next to the script (or in the
  environment). Values shown are the effective ones for the current run;
  "(unset)" means the variable has no value, and long values are reported by
  size only. Secrets are never printed, just "(set)"/"(unset)".
  See .env.example for a ready-to-copy template.

  --- LLM backend selection ---
EOF

  env_entry LLM_BACKEND "$(env_show LLM_BACKEND)" \
    "LLM backend: ollama | litellm | omniroute (hard default: omniroute)" \
    "CLI: --backend BACKEND"
  env_entry LLM_MODEL "$(env_show LLM_MODEL)" \
    "Unified model name applied to the selected backend" \
    "CLI: -m, --model MODEL"
  env_entry LLM_URL "$(env_show LLM_URL)" \
    "Unified server/proxy URL applied to the selected backend" \
    "CLI: --url, --proxy URL"
  env_entry LLM_API_KEY "$(env_show_secret LLM_API_KEY)" \
    "Unified API key applied to the selected backend (litellm/omniroute)" \
    "CLI: --api-key, --key KEY"
  env_entry USE_LITELLM "$(env_show USE_LITELLM)" \
    "[Deprecated] true selects the litellm backend; use LLM_BACKEND instead"
  env_entry USE_OMNIROUTE "$(env_show USE_OMNIROUTE)" \
    "[Deprecated] true selects the omniroute backend; use LLM_BACKEND instead"

  cat <<EOF

  --- LLM backend: Ollama ---
EOF
  env_entry OLLAMA_HOST "$(env_show OLLAMA_HOST)" "Ollama server URL" \
    "CLI: --host / --url URL"
  env_entry OLLAMA_MODEL "$(env_show OLLAMA_MODEL)" "Ollama model name" \
    "CLI: -m, --model MODEL"
  env_entry OLLAMA_NUM_CTX "$(env_show OLLAMA_NUM_CTX)" "Context window size" \
    "CLI: --num-ctx NUM"
  env_entry MAX_TOKENS "$(env_show MAX_TOKENS)" "Max tokens per LLM response" \
    "CLI: --max-tokens TOKENS"
  env_entry TEMPERATURE "$(env_show TEMPERATURE)" "LLM temperature" \
    "CLI: --temperature TEMP"
  env_entry MAX_RETRIES "$(env_show MAX_RETRIES)" "Max retries per LLM call" \
    "CLI: --max-retries RETRIES"

  cat <<EOF

  --- LLM backend: LiteLLM proxy (LLM_BACKEND=litellm) ---
EOF
  env_entry LITELLM_PROXY_URL "$(env_show LITELLM_PROXY_URL)" "LiteLLM proxy URL" \
    "CLI: --url URL"
  env_entry LITELLM_MODEL "$(env_show LITELLM_MODEL)" "LiteLLM model name" \
    "CLI: -m, --model MODEL"
  env_entry LITELLM_API_KEY "$(env_show_secret LITELLM_API_KEY)" "LiteLLM API key" \
    "CLI: --api-key KEY"

  cat <<EOF

  --- LLM backend: Omniroute proxy (LLM_BACKEND=omniroute) ---
EOF
  env_entry OMNIROUTE_URL "$(env_show OMNIROUTE_URL)" "Omniroute proxy URL" \
    "CLI: --url URL"
  env_entry OMNIROUTE_MODEL "$(env_show OMNIROUTE_MODEL)" "Omniroute model name" \
    "CLI: -m, --model MODEL"
  env_entry OMNIROUTE_API_KEY "$(env_show_secret OMNIROUTE_API_KEY)" \
    "Omniroute API key" "CLI: --api-key KEY"

  cat <<EOF

  --- LLM backend: Fallback cascade (LLM_BACKEND=fallback) ---
  Tries Omniroute first, then Ollama Cloud (multi-key), then Ollama Local.
EOF
  env_entry OLLAMA_CLOUD_API_KEYS "$(env_show_secret OLLAMA_CLOUD_API_KEYS)" \
    "Comma-separated Ollama Cloud API keys (1-3), tried in order"
  env_entry OLLAMA_CLOUD_URL "$(env_show OLLAMA_CLOUD_URL)" \
    "Ollama Cloud API base URL (OpenAI-compatible)"
  env_entry OLLAMA_CLOUD_MODEL "$(env_show OLLAMA_CLOUD_MODEL)" \
    "Model name for Ollama Cloud"
  env_entry OLLAMA_LOCAL_MODEL "$(env_show OLLAMA_LOCAL_MODEL)" \
    "Model name for local Ollama (last resort)"

  cat <<EOF

  --- Summarization ---
EOF
  env_entry SUMMARY_LENGTH "$(env_show SUMMARY_LENGTH)" \
    "Summary length: short | medium | long" "CLI: --length LENGTH"
  env_entry TARGET_LANGUAGE "$(env_show TARGET_LANGUAGE)" \
    "Output language. When set, audio-language detection is skipped;" \
    "otherwise per-video detection runs (Romanian audio -> Romanian, else English)." \
    "CLI: -l, --language LANG"
  env_entry CHUNK_WORDS "$(env_show CHUNK_WORDS)" \
    "Words per transcript chunk" "CLI: --chunk-words WORDS"
  env_entry AUTO_CHUNK "$(env_show AUTO_CHUNK)" \
    "false = always use CHUNK_WORDS instead of asking the LLM" \
    "CLI: --no-auto-chunk"
  env_entry CACHE_DIR "$(env_show CACHE_DIR)" \
    "Directory where summaries are cached" "CLI: -f, --force bypasses the cache"

  cat <<EOF

  --- Prompt templates (all optional; leave unset to keep the built-in defaults) ---
  {{...}} placeholders are substituted at use time; .env.example lists them all
  and shows the heredoc syntax for the multi-line PROMPT_USER_* values.
EOF
  env_entry PROMPT_SYSTEM_CHUNK "$(env_show PROMPT_SYSTEM_CHUNK)" \
    "System prompt for chunk summarization (single line)"
  env_entry PROMPT_USER_CHUNK "$(env_show PROMPT_USER_CHUNK)" \
    "User prompt for chunk summarization (heredoc)"
  env_entry PROMPT_SYSTEM_AGGREGATE "$(env_show PROMPT_SYSTEM_AGGREGATE)" \
    "System prompt for summary aggregation (single line)"
  env_entry PROMPT_USER_AGGREGATE "$(env_show PROMPT_USER_AGGREGATE)" \
    "User prompt for summary aggregation (heredoc)"
  env_entry PROMPT_SYSTEM_KEYPOINTS "$(env_show PROMPT_SYSTEM_KEYPOINTS)" \
    "System prompt for key-point extraction (single line)"
  env_entry PROMPT_USER_KEYPOINTS "$(env_show PROMPT_USER_KEYPOINTS)" \
    "User prompt for key-point extraction (heredoc)"
  env_entry PROMPT_SYSTEM_CHUNKSIZE "$(env_show PROMPT_SYSTEM_CHUNKSIZE)" \
    "System prompt for chunk-size recommendation (single line)"
  env_entry PROMPT_USER_CHUNKSIZE "$(env_show PROMPT_USER_CHUNKSIZE)" \
    "User prompt for chunk-size recommendation (heredoc)"

  cat <<EOF

  --- Playlists ---
EOF
  env_entry MAX_PLAYLIST_VIDEOS "$(env_show MAX_PLAYLIST_VIDEOS)" \
    "Max videos per playlist (0 = no limit)" \
    "CLI: --max-playlist-videos N"
  env_entry MAX_PLAYLIST_VIDEO_AGE_DAYS "$(env_show MAX_PLAYLIST_VIDEO_AGE_DAYS)" \
    "Skip videos older than N days (0 = no limit)" \
    "CLI: --max-playlist-video-age-days D"

  cat <<EOF

  --- TTS / audio ---
EOF
  env_entry TTS_ENGINE "$(env_show TTS_ENGINE)" \
    "TTS engine: piper | edge-tts (edge-tts falls back to piper on failure)" \
    "CLI: --tts-engine ENGINE"
  env_entry PIPER_BIN "$(env_show PIPER_BIN)" \
    "piper executable: name resolved on PATH, or a full path"
  env_entry EDGE_TTS_BIN "$(env_show EDGE_TTS_BIN)" \
    "edge-tts executable: name resolved on PATH, or a full path"
  env_entry AUDIO_FORMAT "$(env_show AUDIO_FORMAT)" \
    "Audio output format: m4a | mp3" "CLI: --audio-format FORMAT"
  env_entry AUDIO_VOICE "$(env_show AUDIO_VOICE)" \
    "Explicit voice name (for piper also a filename in VOICES_DIR or a .onnx path)" \
    "CLI: --voice VOICE"
  env_entry VOICES_DIR "$(env_show VOICES_DIR)" \
    "Directory holding piper .onnx voices (e.g. /data/configs/voices)"
  env_entry DEFAULT_VOICE_PIPER_EN "$(env_show DEFAULT_VOICE_PIPER_EN)" \
    "Default English piper voice (filename without .onnx) when --voice is unset"
  env_entry DEFAULT_VOICE_PIPER_RO "$(env_show DEFAULT_VOICE_PIPER_RO)" \
    "Default Romanian piper voice (filename without .onnx) when --voice is unset"
  env_entry DEFAULT_VOICE_TTS_EN "$(env_show DEFAULT_VOICE_TTS_EN)" \
    "Default English edge-tts voice name when --voice is unset"
  env_entry DEFAULT_VOICE_TTS_RO "$(env_show DEFAULT_VOICE_TTS_RO)" \
    "Default Romanian edge-tts voice name when --voice is unset"
  env_entry PHONETIC_TTS "$(env_show PHONETIC_TTS)" \
    "true enables phonetic rewrite of foreign words/acronyms before TTS" \
    "CLI: --no-phonetic"
  env_entry PROMPT_SYSTEM_PHONETIC "$(env_show PROMPT_SYSTEM_PHONETIC)" \
    "System prompt for phonetic rewrite (single line)"
  env_entry PROMPT_USER_PHONETIC "$(env_show PROMPT_USER_PHONETIC)" \
    "User prompt for phonetic rewrite (heredoc)"

  cat <<EOF

  --- Notifications ---
EOF
  env_entry SEND_TELEGRAM "$(env_show SEND_TELEGRAM)" \
    "true sends Telegram notifications" "CLI: --telegram"
  env_entry TELEGRAM_BOT_TOKEN "$(env_show_secret TELEGRAM_BOT_TOKEN)" \
    "Telegram bot token (secret)"
  env_entry TELEGRAM_CHAT_ID "$(env_show TELEGRAM_CHAT_ID)" "Telegram chat ID"
  env_entry TELEGRAM_API_URL "$(env_show TELEGRAM_API_URL)" "Telegram API base URL"
  env_entry MQTT_BROKER "$(env_show MQTT_BROKER)" \
    "MQTT broker host; when set with MQTT_TOPIC, session statistics are" \
    "published as JSON after processing (requires mosquitto-clients)"
  env_entry MQTT_TOPIC "$(env_show MQTT_TOPIC)" "MQTT topic for statistics"
  env_entry MQTT_USER "$(env_show MQTT_USER)" "MQTT username"
  env_entry MQTT_PASSWORD "$(env_show_secret MQTT_PASSWORD)" "MQTT password (secret)"
  env_entry EMAIL_FROM "$(env_show EMAIL_FROM)" \
    "Sender email address" "CLI: --from EMAIL"

  cat <<EOF

  --- Whisper transcription fallback ---
  Used when no manual or auto-generated subtitle can be obtained for a video.
EOF
  env_entry WHISPER_ENABLED "$(env_show WHISPER_ENABLED)" \
    "false disables the whisper fallback" "CLI: --no-whisper"
  env_entry YTDLP_COOKIES "$(env_show YTDLP_COOKIES)" \
    "yt-dlp cookies file; avoids HTTP 429 from the caption endpoint so" \
    "auto-generated subtitles are used instead of falling back to whisper"
  env_entry WHISPER_HOST "$(env_show WHISPER_HOST)" \
    "localhost or a remote IP/hostname" "CLI: --whisper-host HOST"
  env_entry WHISPER_MODEL "$(env_show WHISPER_MODEL)" \
    "whisper model: tiny | base | small | medium | large-v3" \
    "CLI: --whisper-model MODEL"
  env_entry WHISPER_BIN "$(env_show WHISPER_BIN)" \
    "whisper-ctranslate2 executable (name on PATH or full path); local mode only"
  env_entry WHISPER_SSH_USER "$(env_show WHISPER_SSH_USER)" \
    "SSH username on the remote whisper host" "CLI: --whisper-ssh-user USER"
  env_entry WHISPER_SSH_AUTH "$(env_show WHISPER_SSH_AUTH)" \
    "SSH auth mode: config | key | password" "CLI: --whisper-ssh-auth AUTH"
  env_entry WHISPER_SSH_KEY "$(env_show WHISPER_SSH_KEY)" \
    "SSH private key path (auth=key)" "CLI: --whisper-ssh-key KEY"
  env_entry WHISPER_SSH_PASSWORD "$(env_show_secret WHISPER_SSH_PASSWORD)" \
    "SSH password (auth=password, requires sshpass)" \
    "CLI: --whisper-ssh-password PASSWORD"
  env_entry WHISPER_TRANSFER "$(env_show WHISPER_TRANSFER)" \
    "Audio transfer: rsync | scp | shared" "CLI: --whisper-transfer MODE"
  env_entry WHISPER_REMOTE_DIR "$(env_show WHISPER_REMOTE_DIR)" \
    "Work dir on the remote whisper host" "CLI: --whisper-remote-dir DIR"
  env_entry WHISPER_SHARED_DIR "$(env_show WHISPER_SHARED_DIR)" \
    "Shared folder path, valid on both machines (transfer=shared)" \
    "CLI: --whisper-shared-dir DIR"

  cat <<EOF

  --- Paths ---
EOF
  env_entry TMP_BASE "$(env_show TMP_BASE)" \
    "Base dir for temporary files. A fresh mktemp directory is created when" \
    "unset; a directory set here is reused and NOT removed on exit."
  env_entry CACHE_DIR "$(env_show CACHE_DIR)" "Directory where summaries are cached"
  env_entry EXTERNAL_TRACKING_FILE "$(env_show EXTERNAL_TRACKING_FILE)" \
    "File listing already-processed videos to avoid reprocessing"
}

usage_examples() {
  cat <<EOF

EXAMPLES:
  yt-summary "https://www.youtube.com/watch?v=VIDEO_ID"
  yt-summary -m llama3.2:3b --length short urls.txt
  yt-summary --backend litellm --url http://localhost:4000 -m gpt-4o "https://youtube.com/watch?v=ID"
  yt-summary --backend omniroute -m llama3 "https://youtube.com/watch?v=ID"
  yt-summary --stats "https://www.youtube.com/playlist?list=PLAYLIST_ID"
EOF
}

# usage [short|help|all]
usage() {
  case "${1:-help}" in
    short) usage_synopsis ;;
    help)  usage_help ;;
    all)   usage_help; usage_advanced; usage_env; usage_examples ;;
    *)     usage_help ;;
  esac
}

# Long options accepted by the parser, used to suggest a close match when an
# unknown option is passed.
KNOWN_LONG_OPTIONS=(
  --backend --model --url --proxy --api-key --key --host --num-ctx
  --length --language --summary-only --key-points-only --print-only --save-only
  --stats --include-stats --email --from --telegram
  --audio --audio-output --audio-format --voice --tts-engine --no-phonetic
  --no-whisper --whisper-host --whisper-model --whisper-ssh-user
  --whisper-ssh-auth --whisper-ssh-key --whisper-ssh-password
  --whisper-transfer --whisper-remote-dir --whisper-shared-dir
  --max-playlist-videos --max-playlist-video-age-days
  --force --no-auto-chunk --auto-chunk --chunk-words --max-tokens
  --temperature --max-retries --cleanup --verbose --help --help-all
  --think --testing --ignore-processed --transcript-verbose
  --litellm-proxy --litellm-model --litellm-key
  --omniroute --omniroute-model --omniroute-key
)

# suggest_option OPTION -> prints the closest known long option, or nothing.
# Matches candidates on a shared 3-letter prefix and keeps the one with the
# smallest length difference, so typos like '--lenght' resolve to '--length'.
suggest_option() {
  local option="${1#--}" candidate best="" best_delta=99 delta
  [[ -z "$option" ]] && return 0

  for candidate in "${KNOWN_LONG_OPTIONS[@]}"; do
    candidate="${candidate#--}"
    if [[ "${option:0:3}" != "${candidate:0:3}" ]]; then
      continue
    fi
    if (( ${#candidate} >= ${#option} )); then
      delta=$(( ${#candidate} - ${#option} ))
    else
      delta=$(( ${#option} - ${#candidate} ))
    fi
    if (( delta < best_delta )); then
      best_delta=$delta
      best="--$candidate"
    fi
  done

  if [[ -n "$best" ]] && (( best_delta <= 4 )); then
    printf '%s' "$best"
  fi
}
