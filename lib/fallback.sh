#!/bin/bash
# lib/fallback.sh - Cascading fallback LLM backend
# Tries Omniroute -> Ollama Cloud (multi-key) -> Ollama Local

set -euo pipefail

: "${OLLAMA_CLOUD_API_KEYS:=}"
: "${OLLAMA_CLOUD_URL:=https://api.ollama.cloud}"
: "${OLLAMA_CLOUD_MODEL:=}"
: "${OLLAMA_LOCAL_MODEL:=gemma2:2b}"
: "${MAX_RETRIES:=5}"
: "${TEMPERATURE:=0.1}"
: "${MAX_TOKENS:=30000}"

_omniroute_chat_fallback() {
  local model="$1"
  local system="${2:-}"
  local user="$3"

  local model_name="${OMNIROUTE_MODEL:-$model}"

  local start_ns
  start_ns=$(date +%s%N)

  local tmp_dir
  tmp_dir=$(mktemp -d)
  printf '%s' "$system" > "$tmp_dir/system.txt"
  printf '%s' "$user" > "$tmp_dir/user.txt"

  jq -n \
    --arg model "$model_name" \
    --rawfile system "$tmp_dir/system.txt" \
    --rawfile user "$tmp_dir/user.txt" \
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
     }' > "$tmp_dir/request.json"

  local headers=("-H" "Content-Type: application/json")
  if [[ -n "${OMNIROUTE_API_KEY:-}" ]]; then
    headers+=("-H" "Authorization: Bearer $OMNIROUTE_API_KEY")
  fi

  local response
  response=$(curl -s --max-time 300 -X POST "${OMNIROUTE_URL:-http://localhost:20128}/v1/chat/completions" "${headers[@]}" -d "@$tmp_dir/request.json")
  rm -rf "$tmp_dir"

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

  if declare -f _update_stats > /dev/null 2>&1; then
    _update_stats "$completion_tokens" "$prompt_tokens" "$duration_ms"
  fi

  echo "$generated_text"
}

_ollama_cloud_chat_with_key() {
  local model="$1"
  local system="$2"
  local user="$3"
  local api_key="$4"

  local model_name="${OLLAMA_CLOUD_MODEL:-$model}"

  local start_ns
  start_ns=$(date +%s%N)

  local tmp_dir
  tmp_dir=$(mktemp -d)
  printf '%s' "$system" > "$tmp_dir/system.txt"
  printf '%s' "$user" > "$tmp_dir/user.txt"

  jq -n \
    --arg model "$model_name" \
    --rawfile system "$tmp_dir/system.txt" \
    --rawfile user "$tmp_dir/user.txt" \
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
     }' > "$tmp_dir/request.json"

  local response
  response=$(curl -s --max-time 300 -X POST "${OLLAMA_CLOUD_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $api_key" \
    -d "@$tmp_dir/request.json")
  rm -rf "$tmp_dir"

  local end_ns
  end_ns=$(date +%s%N)
  local duration_ms=$(( (end_ns - start_ns) / 1000000 ))

  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    local error
    error=$(echo "$response" | jq -r '.error')
    echo "ERROR: Ollama Cloud error: $error" >&2
    return 1
  fi

  local generated_text
  generated_text=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [[ -z "$generated_text" ]] || [[ "$generated_text" == "null" ]]; then
    echo "ERROR: Ollama Cloud returned empty response" >&2
    return 1
  fi

  local prompt_words=$(echo "$system $user" | wc -w)
  local completion_words=$(echo "$generated_text" | wc -w)
  local prompt_tokens=$((prompt_words * 4 / 3))
  local completion_tokens=$((completion_words * 4 / 3))

  if declare -f _update_stats > /dev/null 2>&1; then
    _update_stats "$completion_tokens" "$prompt_tokens" "$duration_ms"
  fi

  echo "$generated_text"
}

_ollama_local_chat_fallback() {
  local model="$1"
  local system="$2"
  local user="$3"

  local model_name="${OLLAMA_LOCAL_MODEL:-$model}"
  local ollama_host="http://localhost:11434"

  local start_ns
  start_ns=$(date +%s%N)

  local tmp_json
  tmp_json=$(mktemp "${TMP_BASE}/request_XXXXXX.json")

  jq -n \
    --arg model "$model_name" \
    --arg system "$system" \
    --arg user "$user" \
    --argjson temperature "$TEMPERATURE" \
    --argjson num_predict "$MAX_TOKENS" \
    --argjson num_ctx "${OLLAMA_NUM_CTX:-24000}" \
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
  response=$(curl -s --max-time 300 -X POST "$ollama_host/api/chat" -H "Content-Type: application/json" -d @"$tmp_json")

  rm -f "$tmp_json"

  local end_ns
  end_ns=$(date +%s%N)
  local duration_ms=$(( (end_ns - start_ns) / 1000000 ))

  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    local error
    error=$(echo "$response" | jq -r '.error')
    echo "ERROR: Ollama Local error: $error" >&2
    return 1
  fi

  local eval_count prompt_eval_count generated_text
  eval_count=$(echo "$response" | jq -r '.eval_count // 0')
  prompt_eval_count=$(echo "$response" | jq -r '.prompt_eval_count // 0')
  generated_text=$(echo "$response" | jq -r '.message.content')

  if [[ -z "$generated_text" ]] || [[ "$generated_text" == "null" ]]; then
    echo "ERROR: Ollama Local returned empty response" >&2
    return 1
  fi

  if declare -f _update_stats > /dev/null 2>&1; then
    _update_stats "$eval_count" "$prompt_eval_count" "$duration_ms"
  fi

  echo "$generated_text"
}

try_omniroute() {
  local model="$1"
  local system="$2"
  local user="$3"

  local attempt=0
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    if _omniroute_chat_fallback "$model" "$system" "$user"; then
      return 0
    fi
    attempt=$((attempt + 1))
    [[ $attempt -lt $MAX_RETRIES ]] && sleep 1
  done
  return 1
}

try_ollama_cloud() {
  local model="$1"
  local system="$2"
  local user="$3"

  if [[ -z "$OLLAMA_CLOUD_API_KEYS" ]]; then
    return 1
  fi

  local IFS=','
  read -ra keys <<< "$OLLAMA_CLOUD_API_KEYS"

  for key in "${keys[@]}"; do
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "$key" ]] && continue

    local attempt=0
    while [[ $attempt -lt $MAX_RETRIES ]]; do
      if _ollama_cloud_chat_with_key "$model" "$system" "$user" "$key"; then
        return 0
      fi
      attempt=$((attempt + 1))
      [[ $attempt -lt $MAX_RETRIES ]] && sleep 1
    done
  done
  return 1
}

try_ollama_local() {
  local model="$1"
  local system="$2"
  local user="$3"

  local attempt=0
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    if _ollama_local_chat_fallback "$model" "$system" "$user"; then
      return 0
    fi
    attempt=$((attempt + 1))
    [[ $attempt -lt $MAX_RETRIES ]] && sleep 1
  done
  return 1
}

fallback_chat() {
  local model="$1"
  local system="$2"
  local user="$3"

  log_info "Fallback: trying Omniroute..."
  if try_omniroute "$model" "$system" "$user"; then
    return 0
  fi
  log_warn "Omniroute failed after $MAX_RETRIES attempts"

  if [[ -n "$OLLAMA_CLOUD_API_KEYS" ]]; then
    log_info "Fallback: trying Ollama Cloud..."
    if try_ollama_cloud "$model" "$system" "$user"; then
      return 0
    fi
    log_warn "Ollama Cloud failed (all keys exhausted)"
  fi

  log_info "Fallback: trying Ollama Local..."
  if try_ollama_local "$model" "$system" "$user"; then
    return 0
  fi
  log_error "All fallback backends failed"
  return 1
}