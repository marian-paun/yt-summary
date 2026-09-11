#!/bin/bash
set -euo pipefail

# Load .env from same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#export }"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            export "$key=$value"
        fi
    done < "$SCRIPT_DIR/.env"
fi

: "${MQTT_BROKER:=}"
: "${MQTT_TOPIC:=}"
: "${MQTT_USER:=}"
: "${MQTT_PASSWORD:=}"

if [[ -z "$MQTT_BROKER" ]] || [[ -z "$MQTT_TOPIC" ]]; then
    echo "Error: MQTT_BROKER and MQTT_TOPIC must be set in .env or environment" >&2
    echo "Usage: MQTT_BROKER=broker.example.com MQTT_TOPIC=stats ./test-mqtt.sh" >&2
    exit 1
fi

if ! command -v mosquitto_pub &>/dev/null; then
    echo "Error: mosquitto_pub not found. Install mosquitto-clients." >&2
    exit 1
fi

random_between() {
    local min="$1" max="$2"
    echo $(( RANDOM % (max - min + 1) + min ))
}

PAYLOAD=$(jq -n \
    --arg timestamp "$(date '+%Y-%m-%dT%H:%M:%S')" \
    --argjson videos_processed "$(random_between 1 20)" \
    --argjson total_requests "$(random_between 1 50)" \
    --argjson total_prompt_tokens "$(random_between 1000 100000)" \
    --argjson total_completion_tokens "$(random_between 500 50000)" \
    --argjson total_input_words "$(random_between 5000 500000)" \
    --argjson total_output_words "$(random_between 1000 100000)" \
    --argjson total_duration_ms "$(random_between 1000 120000)" \
    '{
        timestamp: $timestamp,
        videos_processed: $videos_processed,
        total_requests: $total_requests,
        total_prompt_tokens: $total_prompt_tokens,
        total_completion_tokens: $total_completion_tokens,
        total_input_words: $total_input_words,
        total_output_words: $total_output_words,
        total_duration_ms: $total_duration_ms
    }')

echo "Sending test MQTT message to $MQTT_TOPIC on $MQTT_BROKER:"
echo "$PAYLOAD" | jq .

mqtt_args=(-h "$MQTT_BROKER" -t "$MQTT_TOPIC" -m "$PAYLOAD" -q 0)

if [[ -n "$MQTT_USER" ]]; then
    mqtt_args+=(-u "$MQTT_USER")
fi
if [[ -n "$MQTT_PASSWORD" ]]; then
    mqtt_args+=(-P "$MQTT_PASSWORD")
fi

if mosquitto_pub "${mqtt_args[@]}"; then
    echo "Message sent successfully."
else
    echo "Failed to send MQTT message." >&2
    exit 1
fi
