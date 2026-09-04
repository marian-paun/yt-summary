# AGENTS.md - yt-summary (YouTube summarizer)

## Run

```bash
./yt-summary "https://youtube.com/watch?v=VIDEO_ID"
./yt-summary --help
```

## Key commands

```bash
./yt-summary URL [model] --length short|medium|long  # default: medium
./yt-summary URL --key-points-only --print-only      # console only
./yt-summary urls.txt --force                        # batch + force reprocess
./yt-summary URL --email user@example.com              # requires mail/sendmail/mutt
```

## Architecture

- **Entry point**: `./yt-summary` (1108 lines)
- **Libraries**: `lib/ollama.sh`, `lib/cache.sh`, `lib/transcript.sh`, `lib/tts.sh`, `lib/omniroute.sh`
- **Pipeline**: fetch transcript → split into chunks → summarize each → merge → extract key points

## Dependencies

- **Required**: `ollama`, `yt-dlp`, `jq`, `curl`
- **Optional**: `python3` + `youtube-transcript-api` (fallback transcript fetch), `mail`/`sendmail`/`mutt` (email)

## Environment variables

All variables below can be set in a `.env` file next to the script (loaded safely at startup, no eval). `.env` is gitignored; `.env.example` is the committed template. Precedence: CLI flags > env > `.env` > defaults.

| Variable | Default | Purpose |
|----------|---------|---------|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `OLLAMA_MODEL` | `gemma2:2b` | Model name |
| `OLLAMA_NUM_CTX` | `24000` | Ollama context window |
| `LLM_BACKEND` | `ollama` | Backend: `ollama`, `litellm`, or `omniroute`; only the selected backend's options apply |
| `CHUNK_WORDS` | `900` | Words per transcript chunk |
| `MAX_TOKENS` | `30000` | Max tokens per LLM response |
| `TEMPERATURE` | `0.1` | LLM temperature |
| `MAX_RETRIES` | `5` | LLM retries |
| `SUMMARY_LENGTH` | `medium` | short/medium/long |
| `TARGET_LANGUAGE` | `en` | Output language |
| `CACHE_DIR` | `/tmp/yt-summary-cache` | Where summaries are cached |
| `USE_LITELLM` | `false` | Deprecated: route via LiteLLM proxy (use `LLM_BACKEND=litellm`) |
| `LITELLM_PROXY_URL` | *(empty)* | LiteLLM proxy URL |
| `LITELLM_API_KEY` | *(empty)* | LiteLLM API key |
| `USE_OMNIROUTE` | `false` | Deprecated: route via Omniroute proxy (use `LLM_BACKEND=omniroute`) |
| `OMNIROUTE_URL` | `http://localhost:20128` | Omniroute proxy URL |
| `OMNIROUTE_API_KEY` | *(empty)* | Omniroute API key |
| `SEND_TELEGRAM` | `false` | Send Telegram notification |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot token |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID |
| `TMP_BASE` | `/temp/yt-summary` | Temp file base dir |
| `EXTERNAL_TRACKING_FILE` | `/data/ltr/yt-dlp/files` | Video ID tracking file |
| `VOICES_DIR` | `/data/configs/voices` | Piper TTS voices dir |

> [!WARNING]
> Never add real API keys/tokens to committed files. Keep them in the
> gitignored `.env` (chmod 600). If a secret was ever committed, rotate it.
