#!/bin/bash
# lib/ollama.sh - Ollama/LiteLLM API wrapper with statistics tracking

set -euo pipefail

: "${OLLAMA_HOST:=http://localhost:11434}"
: "${OLLAMA_NUM_CTX:=24000}"
: "${MAX_TOKENS:=16384}"
: "${TEMPERATURE:=1.0}"
: "${USE_LITELLM:=false}"
: "${LITELLM_PROXY_URL:=}"
: "${LITELLM_MODEL:=}"
: "${LITELLM_API_KEY:=}"

STATS_FILE="${TMP_BASE}/session_stats_$$.json"
STATS_LOCK="${STATS_FILE}.lock"

_init_stats() {
    mkdir -p "$(dirname "$STATS_FILE")"
    if [[ ! -f "$STATS_FILE" ]]; then
        cat > "$STATS_FILE" <<'EOF'
{
  "videos_processed": 0,
  "total_requests": 0,
  "total_prompt_tokens": 0,
  "total_completion_tokens": 0,
  "total_input_words": 0,
  "total_output_words": 0,
  "total_duration_ms": 0
}
EOF
    fi
}

_update_stats() {
    if [[ "$TESTING_MODE" == "true" ]]; then
        return 0  # Skip stats update in testing mode
    fi
    local eval_count="${1:-0}"
    local prompt_eval_count="${2:-0}"
    local duration_ms="${3:-0}"
    
    (
        flock -x 200
        local current
        current=$(cat "$STATS_FILE")
        
        local new_requests=$(( $(echo "$current" | jq -r '.total_requests') + 1 ))
        local new_prompt_tokens=$(( $(echo "$current" | jq -r '.total_prompt_tokens') + prompt_eval_count ))
        local new_completion_tokens=$(( $(echo "$current" | jq -r '.total_completion_tokens') + eval_count ))
        local new_duration=$(( $(echo "$current" | jq -r '.total_duration_ms') + duration_ms ))
        
        cat > "$STATS_FILE" <<EOF
{
  "videos_processed": $(echo "$current" | jq -r '.videos_processed'),
  "total_requests": $new_requests,
  "total_prompt_tokens": $new_prompt_tokens,
  "total_completion_tokens": $new_completion_tokens,
  "total_input_words": $(echo "$current" | jq -r '.total_input_words'),
  "total_output_words": $(echo "$current" | jq -r '.total_output_words'),
  "total_duration_ms": $new_duration
}
EOF
    ) 200>"$STATS_LOCK"
}

update_video_stats() {
    local input_words="${1:-0}"
    local output_words="${2:-0}"
    
    (
        flock -x 200
        local current
        current=$(cat "$STATS_FILE")
        
        cat > "$STATS_FILE" <<EOF
{
  "videos_processed": $(( $(echo "$current" | jq -r '.videos_processed') + 1 )),
  "total_requests": $(echo "$current" | jq -r '.total_requests'),
  "total_prompt_tokens": $(echo "$current" | jq -r '.total_prompt_tokens'),
  "total_completion_tokens": $(echo "$current" | jq -r '.total_completion_tokens'),
  "total_input_words": $(( $(echo "$current" | jq -r '.total_input_words') + input_words )),
  "total_output_words": $(( $(echo "$current" | jq -r '.total_output_words') + output_words )),
  "total_duration_ms": $(echo "$current" | jq -r '.total_duration_ms')
}
EOF
    ) 200>"$STATS_LOCK"
}

show_stats() {
    if [[ ! -f "$STATS_FILE" ]]; then
        return
    fi
    
    local stats
    stats=$(cat "$STATS_FILE")
    
    local requests prompt_tokens completion_tokens input_words output_words duration_ms videos
    requests=$(echo "$stats" | jq -r '.total_requests')
    prompt_tokens=$(echo "$stats" | jq -r '.total_prompt_tokens')
    completion_tokens=$(echo "$stats" | jq -r '.total_completion_tokens')
    input_words=$(echo "$stats" | jq -r '.total_input_words')
    output_words=$(echo "$stats" | jq -r '.total_output_words')
    duration_ms=$(echo "$stats" | jq -r '.total_duration_ms')
    videos=$(echo "$stats" | jq -r '.videos_processed')
    
    local total_tokens=$((prompt_tokens + completion_tokens))
    local duration_sec=$((duration_ms / 1000))
    local minutes=$((duration_sec / 60))
    local seconds=$((duration_sec % 60))

    local duration_str
    if [[ "$minutes" -gt 0 ]]; then
        duration_str="${minutes} min ${seconds} sec"
    else
        duration_str="${duration_sec}s"
    fi

    local stats_output
    stats_output=$(
        echo ""
        echo "========================================"
        echo "           Session Statistics          "
        echo "========================================"
        printf "%-20s %s\n" "Videos processed:" "$videos"
        printf "%-20s %s\n" "LLM requests:" "$requests"
        printf "%-20s %s\n" "Prompt tokens:" "$prompt_tokens"
        printf "%-20s %s\n" "Completion tokens:" "$completion_tokens"
        printf "%-20s %s\n" "Total tokens:" "$total_tokens"
        printf "%-20s %s\n" "Input words:" "$input_words"
        printf "%-20s %s\n" "Output words:" "$output_words"
        printf "%-20s %s\n" "Duration:" "$duration_str"
        echo "========================================"
    )
    
    echo "$stats_output" | systemd-cat -p 4 -t yt-summary
    echo "$stats_output"
}

format_stats_markdown() {
    if [[ ! -f "$STATS_FILE" ]]; then
        return
    fi
    
    local stats
    stats=$(cat "$STATS_FILE")
    
    local requests prompt_tokens completion_tokens input_words output_words duration_ms videos
    requests=$(echo "$stats" | jq -r '.total_requests')
    prompt_tokens=$(echo "$stats" | jq -r '.total_prompt_tokens')
    completion_tokens=$(echo "$stats" | jq -r '.total_completion_tokens')
    input_words=$(echo "$stats" | jq -r '.total_input_words')
    output_words=$(echo "$stats" | jq -r '.total_output_words')
    duration_ms=$(echo "$stats" | jq -r '.total_duration_ms')
    videos=$(echo "$stats" | jq -r '.videos_processed')
    
local total_tokens=$((prompt_tokens + completion_tokens))
    local duration_sec=$((duration_ms / 1000))
    local minutes=$((duration_sec / 60))
    local seconds=$((duration_sec % 60))

    local duration_str
    if [[ "$minutes" -gt 0 ]]; then
        duration_str="${minutes} min ${seconds} sec"
    else
        duration_str="${duration_sec}s"
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local stats_output
    stats_output=$(
        printf '\n=============================\n           Session Statistics\n=============================\n'
        printf '%-14s %14s\n' "Videos:" "$videos"
        printf '%-14s %14s\n' "LLM requests:" "$requests"
        printf '%-14s %14s\n' "Prompt tokens:" "$prompt_tokens"
        printf '%-14s %14s\n' "Compl. Tokens:" "$completion_tokens"
        printf '%-14s %14s\n' "Total tokens:" "$total_tokens"
        printf '%-14s %14s\n' "Input words:" "$input_words"
        printf '%-14s %14s\n' "Output words:" "$output_words"
        printf '%-14s %14s\n' "Duration:" "$duration_str"
        printf '=============================\n'
    )

    
    echo "$stats_output" | systemd-cat -p 4 -t yt-summary
    echo "$stats_output"
}

ollama_check() {
    if ! curl -s --max-time 5 "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
        echo "ERROR: Cannot connect to Ollama at $OLLAMA_HOST" >&2
        echo "Make sure Ollama is running: ollama serve" >&2
        exit 1
    fi
}

ollama_model_exists() {
    local model="${1#ollama/}"
    local models
    models=$(curl -s --max-time 5 "$OLLAMA_HOST/api/tags" | jq -r '.models[].name')
    while IFS= read -r m; do
        if [[ "$m" == "$model" ]]; then
            return 0
        fi
    done <<< "$models"
    return 1
}

litellm_chat() {
    local model="$1"
    local system="${2:-}"
    local user="$3"
    
    local model_name="${LITELLM_MODEL:-$model}"
    
    local start_ns
    start_ns=$(date +%s%N)
    
    local request_body
    request_body=$(jq -n \
        --arg model "$model_name" \
        --arg system "$system" \
        --arg user "$user" \
        --argjson temperature "$TEMPERATURE" \
        --argjson max_tokens "$MAX_TOKENS" \
        --argjson stream false \
        '{
            model: $model,
            messages: [
                {role: "system", content: $system},
                {role: "user", content: $user}
            ],
            temperature: $temperature,
            max_tokens: $max_tokens,
            stream: $stream
        }')
    
    # Build curl headers
    local headers=("-H" "Content-Type: application/json")
    if [[ -n "$LITELLM_API_KEY" ]]; then
        headers+=("-H" "Authorization: Bearer $LITELLM_API_KEY")
    fi
    
    local response
    response=$(curl -s --max-time 300 -X POST "$LITELLM_PROXY_URL/v1/chat/completions" \
        "${headers[@]}" \
        -d "$request_body")
    
    local end_ns
    end_ns=$(date +%s%N)
    local duration_ms=$(( (end_ns - start_ns) / 1000000 ))
    
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        local error
        error=$(echo "$response" | jq -r '.error')
        echo "ERROR: LiteLLM error: $error" >&2
        return 1
    fi
    
    # Extract content from LiteLLM response format
    local generated_text
    generated_text=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$generated_text" ]] || [[ "$generated_text" == "null" ]]; then
        echo "ERROR: LiteLLM returned empty response" >&2
        return 1
    fi
    
    # For stats, we approximate token counts
    local prompt_words=$(echo "$system $user" | wc -w)
    local completion_words=$(echo "$generated_text" | wc -w)
    local prompt_tokens=$((prompt_words * 4 / 3))  # Rough approximation
    local completion_tokens=$((completion_words * 4 / 3))  # Rough approximation
    
    _update_stats "$completion_tokens" "$prompt_tokens" "$duration_ms"
    
    echo "$generated_text"
}

ollama_chat() {
    local model="$1"
    local system="$2"
    local user="$3"
    
    # If using LiteLLM, delegate to LiteLLM
    if [[ "$USE_LITELLM" == "true" ]]; then
        litellm_chat "$model" "$system" "$user"
        return $?
    fi
    
    local model_name="${model#ollama/}"
    
    local start_ns
    start_ns=$(date +%s%N)
    
    # Use temporary file to avoid argument list too long errors
    local tmp_json
    tmp_json=$(mktemp "${TMP_BASE}/request_XXXXXX.json")
    
    jq -n \
        --arg model "$model_name" \
        --arg system "$system" \
        --arg user "$user" \
        --argjson temperature "$TEMPERATURE" \
        --argjson num_predict "$MAX_TOKENS" \
        --argjson num_ctx "$OLLAMA_NUM_CTX" \
        '{
            model: $model,
            stream: false,
            options: {
                temperature: $temperature,
                num_predict: $num_predict,
                num_ctx: $num_ctx
            },
            messages: [
                {role: "system", content: $system},
                {role: "user", content: $user}
            ]
        }' > "$tmp_json"
    
    local response
    response=$(curl -s --max-time 300 -X POST "$OLLAMA_HOST/api/chat" \
        -H "Content-Type: application/json" \
        -d @"$tmp_json")
    
    rm -f "$tmp_json"
    
    local end_ns
    end_ns=$(date +%s%N)
    local duration_ms=$(( (end_ns - start_ns) / 1000000 ))
    
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        local error
        error=$(echo "$response" | jq -r '.error')
        echo "ERROR: $error" >&2
        return 1
    fi
    
    local eval_count prompt_eval_count generated_text
    eval_count=$(echo "$response" | jq -r '.eval_count // 0')
    prompt_eval_count=$(echo "$response" | jq -r '.prompt_eval_count // 0')
    generated_text=$(echo "$response" | jq -r '.message.content')
    
    if [[ -z "$generated_text" ]] || [[ "$generated_text" == "null" ]]; then
        echo "ERROR: Ollama returned empty response" >&2
        return 1
    fi
    
    _update_stats "$eval_count" "$prompt_eval_count" "$duration_ms"
    
    echo "$generated_text"
}

init_stats() {
    _init_stats
}
