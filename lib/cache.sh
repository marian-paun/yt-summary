#!/bin/bash
# lib/cache.sh - File-based caching for summaries

set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/tmp/yt-summary-cache}"

cache_init() {
    mkdir -p "$CACHE_DIR"
}

cache_get_path() {
    local video_id="$1"
    echo "${CACHE_DIR}/${video_id}.md"
}

cache_has_summary() {
    local video_id="$1"
    local path
    path=$(cache_get_path "$video_id")
    
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    
    if grep -q "^## Summary$" "$path"; then
        return 0
    fi
    
    return 1
}

cache_has_key_points() {
    local video_id="$1"
    local path
    path=$(cache_get_path "$video_id")
    
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    
    if grep -q "^## Key Points$" "$path"; then
        return 0
    fi
    
    return 1
}

cache_is_complete() {
    local video_id="$1"
    local need_summary="${2:-true}"
    local need_keypoints="${3:-true}"
    
    if [[ "$need_summary" == "true" ]] && ! cache_has_summary "$video_id"; then
        return 1
    fi
    
    if [[ "$need_keypoints" == "true" ]] && ! cache_has_key_points "$video_id"; then
        return 1
    fi
    
    return 0
}

# Checksum-based cache: returns cached content if file exists and checksum matches
# Usage: cache_checksum <video_id> <checksum>
# Returns: 0 if cache hit, 1 if cache miss
cache_checksum() {
    local video_id="$1"
    local checksum="$2"
    local path
    path=$(cache_get_path "$video_id")
    
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    
    local cached_checksum
    cached_checksum=$(cat "${path}.checksum" 2>/dev/null || echo "")
    
    if [[ "$cached_checksum" == "$checksum" ]]; then
        return 0
    fi
    
    return 1
}

# Write content to cache with checksum
# Usage: cache_write_with_checksum <video_id> <content> <checksum>
cache_write_with_checksum() {
    local video_id="$1"
    local content="$2"
    local checksum="$3"
    
    cache_init
    
    local path
    path=$(cache_get_path "$video_id")
    
    echo "$content" > "$path"
    echo "$checksum" > "${path}.checksum"
    
    log_debug "Cached summary with checksum to ${path}"
}

# Read cached content, verifying checksum first
# Usage: cache_read_with_checksum <video_id> <checksum>
# Returns: 0 if cache hit, 1 if cache miss
cache_read_with_checksum() {
    local video_id="$1"
    local checksum="$2"
    local path
    path=$(cache_get_path "$video_id")
    
    if ! cache_checksum "$video_id" "$checksum"; then
        return 1
    fi
    
    cat "$path"
    return 0
}

# Generate a checksum from content
# Usage: cache_generate_checksum <content>
cache_generate_checksum() {
    echo "$1" | md5sum | awk '{print $1}'
}
