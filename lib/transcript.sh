#!/bin/bash
# lib/transcript.sh - Transcript fetching using yt-dlp

set -euo pipefail

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
    
    # If no limits are set, return all videos as before
    if [[ "${MAX_PLAYLIST_VIDEOS:-0}" -eq 0 ]] && [[ "${MAX_PLAYLIST_VIDEO_AGE_DAYS:-0}" -eq 0 ]]; then
        yt-dlp --flat-playlist --print '%(url)s' --no-warnings "$playlist_url" 2>/dev/null
        return
    fi
    
    # Create temporary file for video metadata
    local temp_file
    temp_file=$(mktemp)
    
    # Get video URLs with epoch timestamps
    yt-dlp --flat-playlist --print '%(url)s|%(epoch)s' --no-warnings "$playlist_url" 2>/dev/null > "$temp_file"
    
    # Process the results
    local current_epoch
    current_epoch=$(date +%s)
    local count=0
    
    while IFS='|' read -r url epoch; do
        [[ -z "$url" ]] && continue
        
        # Check count limit if set
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
            echo "$url"
            count=$((count + 1))
            continue
        fi
        
        # Check age limit if set
        if [[ "${MAX_PLAYLIST_VIDEO_AGE_DAYS:-0}" -gt 0 ]]; then
            # Calculate seconds difference
            local seconds_diff
            seconds_diff=$(( (current_epoch - epoch) ))
            
            # Convert to days
            local days_diff
            days_diff=$(( seconds_diff / 86400 ))
            
            # Skip if older than max age
            if [[ $days_diff -gt $((MAX_PLAYLIST_VIDEO_AGE_DAYS)) ]]; then
                continue
            fi
        fi
        
        echo "$url"
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
            return 0
        fi
        log_transcript_debug "Transcript content changed, re-fetching"
    fi

    log_transcript_debug "Trying yt-dlp manual subtitles (language: $lang)"

    local temp_dir="${TRANSCRIPT_TMP}/${video_id}_manual_temp"
    mkdir -p "$temp_dir"

    yt-dlp --write-sub --write-auto-sub --sub-langs "${lang},en" \
        --skip-download --convert-subs srt --no-playlist \
        --output "${temp_dir}/%(id)s" \
        "https://youtube.com/watch?v=${video_id}" > /dev/null 2>&1 || true

    local sub_file
    sub_file=$(find "$temp_dir" -name "*.srt" -o -name "*.vtt" 2>/dev/null | head -1)

    if [[ -n "$sub_file" ]] && [[ -f "$sub_file" ]]; then
        log_transcript_debug "Found subtitle file: $sub_file"
        _srt_to_text "$sub_file" > "$output_file"
        rm -rf "$temp_dir"

        local word_count
        word_count=$(wc -w < "$output_file")
        log_transcript_debug "Converted transcript: $word_count words"

        if [[ $word_count -gt 10 ]]; then
            # Cache the checksum
            echo "$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')" > "$cache_path"
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
            return 0
        fi
        log_transcript_debug "Auto transcript content changed, re-fetching"
    fi

    log_transcript_debug "Trying yt-dlp auto-generated subtitles"

    local temp_dir="${TRANSCRIPT_TMP}/${video_id}_auto_temp"
    mkdir -p "$temp_dir"

    yt-dlp --skip-download --write-auto-sub --convert-subs srt \
        --output "${temp_dir}/%(id)s.%(ext)s" \
        "https://youtube.com/watch?v=${video_id}" > /dev/null 2>&1 || true

    local sub_file
    sub_file=$(find "$temp_dir" -name "*.srt" -o -name "*.vtt" -print -quit)
    if [[ -n "$sub_file" ]] && [[ -f "$sub_file" ]]; then
        log_transcript_debug "Found auto-generated subtitle file: $sub_file"
        _srt_to_text "$sub_file" > "$output_file"
        rm -rf "$temp_dir"
        local word_count
        word_count=$(wc -w < "$output_file")
        log_transcript_debug "Converted auto transcript: $word_count words"
        if [[ $word_count -gt 10 ]]; then
            # Cache the checksum
            echo "$(md5sum "$output_file" 2>/dev/null | awk '{print $1}')" > "$cache_path"
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
    
    python3 - - "$video_id" "$lang" "$output_file" <<'PYEOF'
import sys
sys.argv.pop(0)
video_id = sys.argv[0]
lang = sys.argv[1]
output_file = sys.argv[2]

try:
    from youtube_transcript_api import YouTubeTranscriptApi

    transcript_list = YouTubeTranscriptApi.list_transcripts(video_id)

    try:
        transcript = transcript_list.find_transcript([lang, 'en'])
    except:
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

        import os
        if os.path.getsize(output_file) > 10:
            sys.exit(0)
except Exception as e:
    pass

sys.exit(1)

PYEOF

    [[ -s "$output_file" ]] && [[ $(wc -c < "$output_file") -gt 10 ]]
}

_fetch_with_transcript_api_auto() {
    local video_id="$1"
    local output_file="$2"
    
    log_transcript_debug "Trying youtube-transcript-api (auto-generated)"
    
    python3 - - "$video_id" "$output_file" <<'PYEOF'
import sys
sys.argv.pop(0)
video_id = sys.argv[0]
output_file = sys.argv[1]

try:
    from youtube_transcript_api import YouTubeTranscriptApi

    transcript_list = YouTubeTranscriptApi.list_transcripts(video_id)

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

    import os
    if os.path.getsize(output_file) > 10:
        print(f"Using auto transcript (language: {transcript.language_code})", file=sys.stderr)
        sys.exit(0)

except Exception as e:
    pass

sys.exit(1)

PYEOF

    [[ -s "$output_file" ]] && [[ $(wc -c < "$output_file") -gt 10 ]]
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