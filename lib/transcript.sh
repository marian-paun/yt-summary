#!/bin/bash
# lib/transcript.sh - Transcript fetching using yt-dlp with whisper-ctranslate2 fallback

set -euo pipefail

# Global: detected source language of the transcript (for metadata)
TRANSCRIPT_DETECTED_LANG="${TRANSCRIPT_DETECTED_LANG:-}"
# Global: where the transcript came from (subtitles | whisper)
TRANSCRIPT_SOURCE="${TRANSCRIPT_SOURCE:-}"

# Optional path to a yt-dlp cookies file, used for subtitle downloads to
# avoid HTTP 429 throttling from YouTube's caption endpoint.
: "${YTDLP_COOKIES:=}"

# Common yt-dlp flags for subtitle downloads: retries ride out transient
# HTTP 429s (YouTube throttles the caption endpoint harder than media), and a
# cookies file avoids the throttling altogether when one is configured.
_ytdlp_sub_args() {
  local args=(--retries 5 --fragment-retries 5 --retry-sleep "linear=3::1")
  if [[ -n "${YTDLP_COOKIES:-}" ]]; then
    if [[ -f "$YTDLP_COOKIES" ]]; then
      args+=(--cookies "$YTDLP_COOKIES")
    else
      log_transcript_warn "YTDLP_COOKIES file not found: ${YTDLP_COOKIES}"
    fi
  fi
  printf '%s\n' "${args[@]}"
}

TRANSCRIPT_TMP="${TMP_BASE}/transcripts"
METADATA_TMP="${TMP_BASE}/metadata"
: "${MAX_PLAYLIST_VIDEO_AGE_DAYS:=0}"  # 0 means no limit
: "${MAX_PLAYLIST_VIDEOS:=0}"         # 0 means no limit

_log_transcript() {
  local level="$1"
  shift
  if [[ "${TRANSCRIPT_VERBOSE:-false}" == "true" ]] || [[ "$level" == "ERROR" ]]; then
    echo "[${level}] [transcript] $*" >&2
  fi
}

log_transcript_info() { _log_transcript "INFO" "$@"; }
log_transcript_debug() { _log_transcript "DEBUG" "$@"; }
log_transcript_warn() { _log_transcript "WARN" "$@"; }
log_transcript_error() { _log_transcript "ERROR" "$@"; }

_transcript_init() {
  mkdir -p "$TRANSCRIPT_TMP" "$METADATA_TMP"
}

is_playlist() {
  local url="$1"

  if [[ "$url" == *"playlist"* ]]; then
    return 0
  fi

  if [[ "$url" == *"list="* ]] && [[ "$url" != *"/watch"* ]]; then
    return 0
  fi

  # Channel videos pages (like @username/videos) should be treated as playlists
  if [[ "$url" == *"/videos" ]] && [[ "$url" == *"youtube.com/"* ]] && [[ "$url" != *"/watch"* ]]; then
    return 0
  fi

  return 1
}

extract_video_id() {
  local url="$1"

  if [[ "$url" =~ youtube\.com/watch\?v=([^&]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$url" =~ youtu\.be/([^?]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$url"
  fi
}

get_video_title() {
  local url="$1"
  local video_id
  video_id=$(extract_video_id "$url")

  _transcript_init

  local cache_file="${METADATA_TMP}/${video_id}.title"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return
  fi

  local title
  title=$(yt-dlp --get-title --no-warnings "$url" 2>/dev/null) || {
    echo "Unknown Video"
    return
  }

  echo "$title" > "$cache_file"
  echo "$title"
}

get_playlist_videos() {
  local playlist_url="$1"

  # Build yt-dlp arguments with server-side filtering
  # Include metadata: url|title|duration|language|epoch
  local ytdlp_args=(--flat-playlist --print '%(url)s|%(title)s|%(duration)s|%(language)s|%(epoch)s' --no-warnings)

  # If no limits are set, return all videos with metadata (no server-side filtering)
  if [[ "${MAX_PLAYLIST_VIDEOS:-0}" -eq 0 ]] && [[ "${MAX_PLAYLIST_VIDEO_AGE_DAYS:-0}" -eq 0 ]]; then
    yt-dlp "${ytdlp_args[@]}" "$playlist_url" 2>/dev/null
    return
  fi

  # Use playlist-end for count limit (works because channel videos are newest-first)
  if [[ "${MAX_PLAYLIST_VIDEOS:-0}" -gt 0 ]]; then
    ytdlp_args+=(--playlist-end "${MAX_PLAYLIST_VIDEOS}")
  fi

  # Use dateafter for age limit (reduces fetched videos significantly)
  if [[ "${MAX_PLAYLIST_VIDEO_AGE_DAYS:-0}" -gt 0 ]]; then
    local cutoff_date
    cutoff_date=$(date -d "-${MAX_PLAYLIST_VIDEO_AGE_DAYS} days" +%Y%m%d 2>/dev/null || date -v-"${MAX_PLAYLIST_VIDEO_AGE_DAYS}d" +%Y%m%d)
    ytdlp_args+=(--dateafter "${cutoff_date}")
  fi

  # Create temporary file for video metadata
  local temp_file
  temp_file=$(mktemp -p "${TMP_BASE}")

  # Get video URLs with metadata (with server-side filtering)
  yt-dlp "${ytdlp_args[@]}" "$playlist_url" 2>/dev/null > "$temp_file"

  # Process the results (apply any remaining local filters)
  local current_epoch
  current_epoch=$(date +%s)
  local count=0

  while IFS='|' read -r url title duration language epoch; do
    [[ -z "$url" ]] && continue

    # Check count limit if set (in case dateafter returned more than needed)
    if [[ "${MAX_PLAYLIST_VIDEOS:-0}" -gt 0 && $count -ge $MAX_PLAYLIST_VIDEOS ]]; then
      break
    fi

    # Handle videos with unavailable epoch timestamps
    if [[ -z "$epoch" ]] || [[ "$epoch" == "NA" ]]; then
      # If we're filtering by age, skip videos with unknown dates
      if [[ "${MAX_PLAYLIST_VIDEO_AGE_DAYS:-0}" -gt 0 ]]; then
        continue
      fi
      # If we're only filtering by count, include them
      echo "$url|$title|$duration|$language|$epoch"
      count=$((count + 1))
      continue
    fi

    # Check age limit if set (double-check for edge cases)
    if [[ "${MAX_PLAYLIST_VIDEO_AGE_DAYS:-0}" -gt 0 ]]; then
      local seconds_diff
      seconds_diff=$(( (current_epoch - epoch) ))
      local days_diff
      days_diff=$(( seconds_diff / 86400 ))
      if [[ $days_diff -gt $((MAX_PLAYLIST_VIDEO_AGE_DAYS)) ]]; then
        continue
      fi
    fi

    echo "$url|$title|$duration|$language|$epoch"
    count=$((count + 1))
  done < "$temp_file"

  rm -f "$temp_file"
}

fetch_transcript() {
  local video_id="$1"
  local lang="${2:-en}"

  _transcript_init

  local output_file="${TRANSCRIPT_TMP}/${video_id}_${lang}.txt"

  if [[ -f "$output_file" ]]; then
    log_transcript_info "Using cached transcript: $output_file"
    # Recover the language recorded when the transcript was first fetched
    # so the English-translation rule still applies on cache hits.
    [[ -f "${output_file}.lang" ]] && TRANSCRIPT_DETECTED_LANG="$(cat "${output_file}.lang")"
      echo "$output_file"
      return
  fi

  log_transcript_info "Fetching transcript for video: $video_id (language: $lang)"

  if _fetch_with_yt_dlp_subtitles "$video_id" "$lang" "$output_file"; then
    log_transcript_info "Transcript fetched via yt-dlp subtitles (language: $lang)"
    echo "$output_file"
    return
  fi

  log_transcript_debug "Manual subtitles not available via yt-dlp"

  if _fetch_with_yt_dlp_any_sub "$video_id" "$output_file"; then
    log_transcript_info "Transcript fetched via yt-dlp any-language subtitles"
    echo "$output_file"
    return
  fi

  log_transcript_debug "Any-language subtitles not available via yt-dlp"

  if _fetch_with_yt_dlp_auto_subs "$video_id" "$output_file"; then
    log_transcript_info "Transcript fetched via yt-dlp auto-generated subtitles"
    echo "$output_file"
    return
  fi

  log_transcript_debug "Auto subtitles not available via yt-dlp"

  if _fetch_with_transcript_api "$video_id" "$lang" "$output_file"; then
    log_transcript_info "Transcript fetched via youtube-transcript-api (manual: $lang)"
    echo "$output_file"
    return
  fi

  log_transcript_debug "youtube-transcript-api manual subtitles not available"

  if _fetch_with_transcript_api_auto "$video_id" "$output_file"; then
    log_transcript_info "Transcript fetched via youtube-transcript-api (auto-generated)"
    echo "$output_file"
    return
  fi

  log_transcript_debug "youtube-transcript-api auto subtitles not available"
  log_transcript_error "No subtitles available for video: $video_id"
  return 1
}

# Multi-tier transcript acquisition (INSTRUCTIONS.md 2.1, 2.3, 2.7):
#   1. RO/EN subtitles (via fetch_transcript, incl. any-language fallback)
#   2. audio download + whisper-ctranslate2 transcription
# On success echoes the transcript text file path. Also persists the source
# ("subtitles" | "whisper") and detected language to METADATA_TMP marker files
# keyed by video id — the caller typically runs us inside $() (a subshell), so
# plain global variables cannot be relied upon for that data.
fetch_transcript_with_fallback() {
  local url="$1"
  local video_id="$2"
  local lang="${3:-en}"

  TRANSCRIPT_SOURCE=""
  TRANSCRIPT_DETECTED_LANG=""

  # Stats step timers (defined in lib/ollama.sh when present).
  _stats_tick() { declare -f stats_tic >/dev/null 2>&1 && { stats_tic "$@"; return 0; }; return 0; }
  _stats_tock() { declare -f stats_toc >/dev/null 2>&1 && { stats_toc "$@"; return 0; }; return 0; }

  local transcript_file="" src="subtitles" detected=""
  _stats_tick "ytdlp"
  if transcript_file=$(fetch_transcript "$video_id" "$lang") && [[ -s "$transcript_file" ]]; then
    _stats_tock "ytdlp"
    src="subtitles"
    detected="${TRANSCRIPT_DETECTED_LANG:-$lang}"
  else
    _stats_tock "ytdlp"
    # Whisper transcription fallback
    log_transcript_info "No usable subtitles; trying whisper-ctranslate2 transcription..."
    if declare -f whisper_transcribe >/dev/null 2>&1; then
      _stats_tick "whisper"
      if transcript_file=$(whisper_transcribe "$url" "$video_id") && [[ -s "$transcript_file" ]]; then
        _stats_tock "whisper"
        src="whisper"
        detected="$(whisper_result_lang "$video_id")"
      else
        _stats_tock "whisper"
      fi
    else
      log_transcript_warn "whisper_transcribe() unavailable (lib/whisper.sh not loaded)"
    fi
  fi

  if [[ -z "$transcript_file" ]] || [[ ! -s "$transcript_file" ]]; then
    log_transcript_error "No transcript could be obtained for video: $video_id"
    return 1
  fi

  TRANSCRIPT_SOURCE="$src"
  TRANSCRIPT_DETECTED_LANG="$detected"
  if [[ -n "${METADATA_TMP:-}" ]]; then
    mkdir -p "$METADATA_TMP"
    echo "$src" > "${METADATA_TMP}/${video_id}.transcript_source"
    echo "$detected" > "${METADATA_TMP}/${video_id}.transcript_lang"
  fi
  echo "$transcript_file"
}

# Prints the best-matching subtitle file in $temp_dir for the given language
# preference list (first match wins). Manual tracks are preferred over
# auto-generated ones for the same language; falls back to any subtitle file.
_pick_subtitle() {
  local temp_dir="$1"
  shift
  local lang
  for lang in "$@"; do
    local m
    m=$(find "$temp_dir" -name "*.${lang}.srt" -o -name "*.${lang}.vtt" 2>/dev/null | head -1)
    if [[ -n "$m" ]] && [[ -f "$m" ]]; then
      echo "$m"
      return 0
    fi
    m=$(find "$temp_dir" -name "*.${lang}-*.srt" -o -name "*.${lang}-*.vtt" 2>/dev/null | head -1)
    if [[ -n "$m" ]] && [[ -f "$m" ]]; then
      echo "$m"
      return 0
    fi
  done
  find "$temp_dir" -name "*.srt" -o -name "*.vtt" 2>/dev/null | head -1
}

# Extracts the language code from a yt-dlp subtitle filename
# (<id>.<lang>.srt or <id>.<lang>-auto.srt). Strips the "-auto"/"-orig" suffix.
_subtitle_file_lang() {
  local sub_file="$1"
  local lang
  lang=$(basename "$sub_file" | sed -E 's/.*\.([A-Za-z0-9_-]+)\.(srt|vtt)$/\1/')
  echo "${lang%%-*}"
}

_fetch_with_yt_dlp_subtitles() {
  local video_id="$1"
  local lang="$2"
  local output_file="$3"

  local cache_key="${video_id}_${lang}_yt_dlp_sub"
  local cache_path="${TRANSCRIPT_TMP}/${cache_key}.checksum"

  # Check if we have a cached transcript with the same checksum
  if [[ -f "$cache_path" ]]; then
    local cached_checksum
    cached_checksum=$(cat "$cache_path")
    local current_checksum
    current_checksum=$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')
    if [[ "$cached_checksum" == "$current_checksum" ]]; then
      log_transcript_info "Using cached transcript (same content)"
      [[ -f "${output_file}.lang" ]] && TRANSCRIPT_DETECTED_LANG="$(cat "${output_file}.lang")"
      return 0
    fi
    log_transcript_debug "Transcript content changed, re-fetching"
  fi

  log_transcript_debug "Trying yt-dlp manual subtitles (language: $lang)"

  local temp_dir="${TRANSCRIPT_TMP}/${video_id}_manual_temp"
  mkdir -p "$temp_dir"

  # Retries ride out transient HTTP 429s: YouTube throttles the caption
  # endpoint harder than media downloads, which otherwise silently kills
  # this tier (and the auto-sub fallbacks) and sends us to whisper.
  # shellcheck disable=SC2046
  yt-dlp --write-sub --write-auto-sub --sub-langs "${lang},en" --skip-download --convert-subs srt --no-playlist \
        $(_ytdlp_sub_args) --output "${temp_dir}/%(id)s" "https://youtube.com/watch?v=${video_id}" > /dev/null 2>&1 || true

  local sub_file
  if [[ "$lang" == "en" ]]; then
    sub_file=$(_pick_subtitle "$temp_dir" "en")
  else
    sub_file=$(_pick_subtitle "$temp_dir" "$lang" "en")
  fi

  if [[ -n "$sub_file" ]] && [[ -f "$sub_file" ]]; then
    log_transcript_debug "Found subtitle file: $sub_file"
    TRANSCRIPT_DETECTED_LANG="$(_subtitle_file_lang "$sub_file")"
    log_transcript_debug "Detected language: $TRANSCRIPT_DETECTED_LANG"
    _srt_to_text "$sub_file" > "$output_file"
    rm -rf "$temp_dir"

    local word_count
    word_count=$(wc -w < "$output_file")
    log_transcript_debug "Converted transcript: $word_count words"

    if [[ $word_count -gt 10 ]]; then
      # Cache the checksum
      echo "$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')" > "$cache_path"
      echo "$TRANSCRIPT_DETECTED_LANG" > "${output_file}.lang"
      return 0
    fi
  fi

  rm -rf "$temp_dir"
  # Clean up stale cache
  rm -f "$cache_path"
  return 1
}

_fetch_with_yt_dlp_auto_subs() {
  local video_id="$1"
  local output_file="$2"

  local cache_key="${video_id}_auto_yt_dlp"
  local cache_path="${TRANSCRIPT_TMP}/${cache_key}.checksum"

  # Check if we have a cached transcript with the same checksum
  if [[ -f "$cache_path" ]]; then
    local cached_checksum
    cached_checksum=$(cat "$cache_path")
    local current_checksum
    current_checksum=$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')
    if [[ "$cached_checksum" == "$current_checksum" ]]; then
      log_transcript_info "Using cached auto transcript (same content)"
      [[ -f "${output_file}.lang" ]] && TRANSCRIPT_DETECTED_LANG="$(cat "${output_file}.lang")"
      return 0
    fi
    log_transcript_debug "Auto transcript content changed, re-fetching"
  fi

  log_transcript_debug "Trying yt-dlp auto-generated subtitles"

  local temp_dir="${TRANSCRIPT_TMP}/${video_id}_auto_temp"
  mkdir -p "$temp_dir"

  # shellcheck disable=SC2046
  yt-dlp --skip-download --write-auto-sub --convert-subs srt $(_ytdlp_sub_args) --output "${temp_dir}/%(id)s.%(ext)s" \
    "https://youtube.com/watch?v=${video_id}" > /dev/null 2>&1 || true

  local sub_file
  sub_file=$(find "$temp_dir" \( -name "*.srt" -o -name "*.vtt" \) -print -quit)
  if [[ -n "$sub_file" ]] && [[ -f "$sub_file" ]]; then
    log_transcript_debug "Found auto-generated subtitle file: $sub_file"
    TRANSCRIPT_DETECTED_LANG="$(_subtitle_file_lang "$sub_file")"
    log_transcript_debug "Detected language: $TRANSCRIPT_DETECTED_LANG"
    _srt_to_text "$sub_file" > "$output_file"
    rm -rf "$temp_dir"
    local word_count
    word_count=$(wc -w < "$output_file")
    log_transcript_debug "Converted auto transcript: $word_count words"
    if [[ $word_count -gt 10 ]]; then
      # Cache the checksum
      echo "$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')" > "$cache_path"
      echo "$TRANSCRIPT_DETECTED_LANG" > "${output_file}.lang"
      return 0
    fi
  fi
  rm -rf "$temp_dir"
  # Clean up stale cache
  rm -f "$cache_path"
  return 1
}

_fetch_with_yt_dlp_any_sub() {
  local video_id="$1"
  local output_file="$2"

  local cache_key="${video_id}_any_yt_dlp"
  local cache_path="${TRANSCRIPT_TMP}/${cache_key}.checksum"

  # Check if we have a cached transcript with the same checksum
  if [[ -f "$cache_path" ]]; then
    local cached_checksum
    cached_checksum=$(cat "$cache_path")
    local current_checksum
    current_checksum=$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')
    if [[ "$cached_checksum" == "$current_checksum" ]]; then
      log_transcript_info "Using cached any-language transcript (same content)"
      [[ -f "${output_file}.lang" ]] && TRANSCRIPT_DETECTED_LANG="$(cat "${output_file}.lang")"
      return 0
    fi
    log_transcript_debug "Any-language transcript content changed, re-fetching"
  fi

  log_transcript_debug "Trying yt-dlp any-language subtitles"

  local temp_dir="${TRANSCRIPT_TMP}/${video_id}_any_temp"
  mkdir -p "$temp_dir"

  # Fetch all available subtitle and auto-generated subtitles
  # This includes any language that YouTube provides
  # shellcheck disable=SC2046
  yt-dlp --write-sub --write-auto-sub --sub-langs "all" --skip-download --convert-subs srt --no-playlist \
    $(_ytdlp_sub_args) --output "${temp_dir}/%(id)s" "https://youtube.com/watch?v=${video_id}" > /dev/null 2>&1 || true

  # Find the most substantial subtitle file (prefer manual over auto,
  # and English/Romanian over arbitrary auto-translated tracks).
  local sub_file
  sub_file=$(_pick_subtitle "$temp_dir" "en" "ro")

  if [[ -n "$sub_file" ]] && [[ -f "$sub_file" ]]; then
    log_transcript_debug "Found any-language subtitle file: $sub_file"

    # Detect the language from the filename suffix (yt-dlp names files
    # as <id>.<lang>.srt or <id>.<lang>-auto.srt).
    TRANSCRIPT_DETECTED_LANG="$(_subtitle_file_lang "$sub_file")"
    log_transcript_debug "Detected language: $TRANSCRIPT_DETECTED_LANG"

    _srt_to_text "$sub_file" > "$output_file"
    rm -rf "$temp_dir"

    local word_count
    word_count=$(wc -w < "$output_file")
    log_transcript_debug "Converted any-language transcript: $word_count words"

    if [[ $word_count -gt 10 ]]; then
      # Cache the checksum
      echo "$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')" > "$cache_path"
      echo "$TRANSCRIPT_DETECTED_LANG" > "${output_file}.lang"
      return 0
    fi
  fi

  rm -rf "$temp_dir"
  # Clean up stale cache
  rm -f "$cache_path"
  return 1
}

_fetch_with_transcript_api() {
  local video_id="$1"
  local lang="$2"
  local output_file="$3"

  log_transcript_debug "Trying youtube-transcript-api (manual: $lang)"

  python3 - "$video_id" "$lang" "$output_file" <<'PYEOF'
import sys
sys.argv.pop(0)
video_id = sys.argv[0]
lang = sys.argv[1]
output_file = sys.argv[2]

try:
    from youtube_transcript_api import YouTubeTranscriptApi

    # youtube-transcript-api >= 1.0 replaced the class-level list_transcripts()
    # with an instance-level list(); both expose the same Transcript shape.
    api = YouTubeTranscriptApi()
    if hasattr(api, 'list'):
        transcript_list = api.list(video_id)
    else:
        transcript_list = api.list_transcripts(video_id)

    try:
        transcript = transcript_list.find_transcript([lang, 'en'])
    except Exception:
        transcript = transcript_list.find_transcript(['en'])

    if transcript:
        snippets = transcript.fetch()
        with open(output_file, 'w', encoding='utf-8') as f:
            last_text = ""
            for snippet in snippets:
                text = snippet.text.strip()
                if text and text != last_text:
                    f.write(text + ' ')
                    last_text = text

        # Record the actual track language for the English-translation rule.
        with open(output_file + '.lang', 'w') as lf:
            lf.write((transcript.language_code or lang).split('-')[0] or 'en')

        import os
        if os.path.getsize(output_file) > 10:
            sys.exit(0)
except Exception:
    pass

sys.exit(1)

PYEOF

  if [[ -s "$output_file" ]] && [[ $(wc -c < "$output_file") -gt 10 ]]; then
    TRANSCRIPT_DETECTED_LANG="$(cat "${output_file}.lang" 2>/dev/null || echo "$lang")"
    return 0
  fi
  return 1
}

_fetch_with_transcript_api_auto() {
  local video_id="$1"
  local output_file="$2"

  log_transcript_debug "Trying youtube-transcript-api (auto-generated)"

  python3 - "$video_id" "$output_file" <<'PYEOF'
import sys
sys.argv.pop(0)
video_id = sys.argv[0]
output_file = sys.argv[1]

try:
    from youtube_transcript_api import YouTubeTranscriptApi

    # youtube-transcript-api >= 1.0 replaced the class-level list_transcripts()
    # with an instance-level list(); both expose the same Transcript shape.
    api = YouTubeTranscriptApi()
    if hasattr(api, 'list'):
        transcript_list = api.list(video_id)
    else:
        transcript_list = api.list_transcripts(video_id)

    auto_transcripts = []
    for transcript in transcript_list:
        if transcript.is_generated:
            auto_transcripts.append(transcript)

    if not auto_transcripts:
        sys.exit(1)

    transcript = auto_transcripts[0]
    snippets = transcript.fetch()

    with open(output_file, 'w', encoding='utf-8') as f:
        last_text = ""
        for snippet in snippets:
            text = snippet.text.strip()
            if text and text != last_text:
                f.write(text + ' ')
                last_text = text

    # Record the actual track language for the English-translation rule.
    with open(output_file + '.lang', 'w') as lf:
        lf.write((transcript.language_code or 'en').split('-')[0] or 'en')

    import os
    if os.path.getsize(output_file) > 10:
        print(f"Using auto transcript (language: {transcript.language_code})", file=sys.stderr)
        sys.exit(0)

except Exception:
    pass

sys.exit(1)

PYEOF

  if [[ -s "$output_file" ]] && [[ $(wc -c < "$output_file") -gt 10 ]]; then
    TRANSCRIPT_DETECTED_LANG="$(cat "${output_file}.lang" 2>/dev/null || echo "en")"
    return 0
  fi
  return 1
}

_srt_to_text() {
  local srt_file="$1"

  # Single awk pass for all SRT cleaning and text extraction
  awk '
    {
    # Skip empty lines, WEBVTT header, index numbers, timestamps, and line markers
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^WEBVTT/) next
    if ($0 ~ /^[0-9]+$/) next
    if ($0 ~ /^[[:digit:]]{2}:[[:digit:]]{2}:[[:digit:]]{2}/) next
    if ($0 ~ /^-->$/) next

    # Remove HTML tags
    gsub(/<[^>]*>/, "")

    # HTML entity unescaping
    gsub(/&/, "&")
    gsub(/</, "<")
    gsub(/>/, ">")
    gsub(/"/, "\"")

    # Remove trailing whitespace
    gsub(/[[:space:]]*$/, "")

    # Skip if line is empty after cleaning
    if (length($0) == 0) next

      # Deduplicate consecutive identical lines
      if ($0 == last) next
      last = $0

      # Accumulate text, space-separated
      if (text == "") {
        text = $0
      } else {
        text = text " " $0
      }
    }
    END {
      # Normalize multiple spaces, remove leading/trailing spaces
      gsub(/  +/, " ", text)
      sub(/^ /, "", text)
      sub(/ $/, "", text)
      print text
    }' "$srt_file"
}

get_transcript_word_count() {
  local transcript_file="$1"
  wc -w < "$transcript_file"
}

detect_audio_language() {
  local url="$1"
  local pre_fetched_language="${2:-}"
  local video_id
  video_id=$(extract_video_id "$url")

  _transcript_init

  local cache_file="${METADATA_TMP}/${video_id}.audio_lang"
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return
  fi

  local lang="en"

  # Use pre-fetched language if available (from playlist batch metadata)
  if [[ -n "$pre_fetched_language" ]]; then
    case "$pre_fetched_language" in
      ro|ro-*) lang="ro" ;;
      *)       lang="en" ;;
    esac
    echo "$lang" > "$cache_file"
    echo "$lang"
    return
  fi

  # Primary signal: yt-dlp metadata reports the video's language.
  local reported
  reported=$(yt-dlp --skip-download --no-warnings --print "%(language)s" "$url" 2>/dev/null)

  if [[ -n "$reported" ]]; then
    case "$reported" in
      ro|ro-*) lang="ro" ;;
      *)       lang="en" ;;
    esac
    echo "$lang" > "$cache_file"
    echo "$lang"
    return
  fi

  # Fallback: check manual subtitles for a Romanian track (a strong
  # indicator the audio itself is Romanian).
  local subs
  subs=$(yt-dlp --list-subs --skip-download --no-warnings "$url" 2>/dev/null)
  if printf '%s\n' "$subs" | awk '
    /^\[info\] Available subtitles/ { in_manual=1; next }
    /^\[info\] Available (automatic )?captions/ { in_manual=0; next }
    in_manual && /^ro[[:space:]-]/ { found=1; exit }
    END { exit !found }
    '; then
    lang="ro"
  fi

  echo "$lang" > "$cache_file"
  echo "$lang"
}
