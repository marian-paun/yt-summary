#!/bin/bash
# lib/omniroute.sh - Omniroute API wrapper

set -euo pipefail

: "${USE_OMNIROUTE:=false}"
: "${OMNIROUTE_URL:=http://localhost:20128}"
: "${OMNIROUTE_MODEL:=}"
: "${OMNIROUTE_API_KEY:=}"
: "${TEMPERATURE:=1.0}"
: "${MAX_TOKENS:=16384}"

omniroute_chat() {
    local model="$1"
    local system="${2:-}"
    local user="$3"
    
    local model_name="${OMNIROUTE_MODEL:-$model}"
    
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
    
    local headers=("-H" "Content-Type: application/json")
    if [[ -n "$OMNIROUTE_API_KEY" ]]; then
        headers+=("-H" "Authorization: Bearer $OMNIROUTE_API_KEY")
    fi
    
    local response
    response=$(curl -s --max-time 300 -X POST "$OMNIROUTE_URL/v1/chat/completions" \
        "${headers[@]}" \
        -d "$request_body")
    
    local end_ns
    end_ns=$(date +%s%N)
    local duration_ms=$(( (end_ns - start_ns) / 1000000 ))
    
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        local error
        error=$(echo "$response" | jq -r '.error')
        echo "ERROR: Omniroute error: $error" >&2
        return 1
    fi
    
    local generated_text
    generated_text=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$generated_text" ]] || [[ "$generated_text" == "null" ]]; then
        echo "ERROR: Omniroute returned empty response" >&2
        return 1
    fi
    
    local prompt_words=$(echo "$system $user" | wc -w)
    local completion_words=$(echo "$generated_text" | wc -w)
    local prompt_tokens=$((prompt_words * 4 / 3))
    local completion_tokens=$((completion_words * 4 / 3))
    
    # Update stats if function is available
    if declare -f _update_stats > /dev/null 2>&1; then
        _update_stats "$completion_tokens" "$prompt_tokens" "$duration_ms"
    fi
    
    echo "$generated_text"
}
