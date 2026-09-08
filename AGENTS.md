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
./yt-summary URL --email [EMAIL_REDACTED]              # requires mail/sendmail/mutt
./yt-summary URL --audio                               # generate TTS audio
./yt-summary URL --telegram                            # send stats via Telegram
./yt-summary URL --stats                               # show session statistics
./yt-summary URL --think                               # enable Ollama think mode
./yt-summary playlist_url --max-playlist-videos 10    # process first 10 videos
```

## Architecture

- **Entry point**: `./yt-summary` (1329 lines)
- **Libraries**: `lib/ollama.sh`, `lib/cache.sh`, `lib/transcript.sh`, `lib/tts.sh`, `lib/omniroute.sh`
- **Pipeline**: fetch transcript → split into chunks → summarize each → merge → extract key points

## Dependencies

- **Required**: `ollama`, `yt-dlp`, `jq`, `curl`
- **Optional**: `python3` + `youtube-transcript-api` (fallback transcript fetch), `mail`/`sendmail`/`mutt` (email), `piper-tts` or `edge-tts` (TTS/audio), `ffmpeg` (audio format conversion)

## LLM Backends

Three backends are supported via `--backend` or `LLM_BACKEND` env var:

| Backend | Description | Options |
|---------|-------------|---------|
| `ollama` | Default local backend | `--model`, `--host`, `--num-ctx`, `--think` |
| `litellm` | LiteLLM proxy (cloud models) | `--litellm-proxy`, `--litellm-model`, `--litellm-key` |
| `omniroute` | Omniroute proxy (model routing) | `--omniroute`, `--omniroute-model`, `--omniroute-key` |

Only options for the selected backend are applied.

## Output Options

| Option | Description |
|--------|-------------|
| `--summary-only` | Only generate summary section |
| `--key-points-only` | Only generate key points section |
| `--print-only` | Print to console only, don't save to file |
| `--save-only` | Save to file only, don't print to console |
| `--email EMAIL` | Send output via email (requires sendmail/mail/mutt) |
| `--telegram` | Send session stats via Telegram |
| `--audio` | Generate audio from summary |
| `--voice VOICE` | Explicit voice name (overrides language detection) |
| `--tts-engine ENGINE` | TTS engine: `piper` or `edge-tts` |
| `--audio-format FORMAT` | Audio format: `m4a` or `mp3` |
| `--stats` | Show session statistics at end |
| `--include-stats` | Include statistics in output document |

## Playlist Processing

- Supports YouTube playlist URLs automatically detected
- `--max-playlist-videos N` — limit number of videos processed
- `--max-playlist-video-age-days N` — skip videos older than N days

## External Tracking

Videos are tracked in a file (default: `/data/ltr/yt-dlp/files`) to avoid reprocessing. Use `--force` to reprocess skipped videos.

## Environment variables

All variables below can be set in a `.env` file next to the script (loaded safely at startup, no eval). `.env` is gitignored; `.env.example` is the committed template. Precedence: CLI flags > env > `.env` > defaults.

| Variable | Default | Purpose |
|----------|---------|---------|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `OLLAMA_MODEL` | `gemma2:2b` | Model name |
| `OLLAMA_NUM_CTX` | `24000` | Ollama context window |
| `LLM_BACKEND` | `ollama` | Backend: `ollama`, `litellm`, or `omniroute` |
| `CHUNK_WORDS` | `900` | Words per transcript chunk |
| `MAX_TOKENS` | `30000` | Max tokens per LLM response |
| `TEMPERATURE` | `0.1` | LLM temperature |
| `MAX_RETRIES` | `5` | LLM retries |
| `SUMMARY_LENGTH` | `medium` | short/medium/long |
| `TARGET_LANGUAGE` | `en` | Output language. If set (env/.env/`--language`), it is respected; otherwise per-video audio-language detection applies (Romanian audio → Romanian, otherwise English) |
| `PROMPT_SYSTEM_CHUNK` / `PROMPT_USER_CHUNK` | *(defaults)* | Chunk-summarization prompts |
| `PROMPT_SYSTEM_AGGREGATE` / `PROMPT_USER_AGGREGATE` | *(defaults)* | Merge prompts |
| `PROMPT_SYSTEM_KEYPOINTS` / `PROMPT_USER_KEYPOINTS` | *(defaults)* | Key-points prompts |
| `CACHE_DIR` | `/tmp/yt-summary-cache` | Where summaries are cached |
| `USE_LITELLM` | `false` | Deprecated: use `LLM_BACKEND=litellm` |
| `LITELLM_PROXY_URL` | *(empty)* | LiteLLM proxy URL |
| `LITELLM_MODEL` | *(empty)* | LiteLLM model name |
| `LITELLM_API_KEY` | *(empty)* | LiteLLM API key |
| `USE_OMNIROUTE` | `false` | Deprecated: use `LLM_BACKEND=omniroute` |
| `OMNIROUTE_URL` | `http://localhost:20128` | Omniroute proxy URL |
| `OMNIROUTE_MODEL` | *(empty)* | Omniroute model name |
| `OMNIROUTE_API_KEY` | *(empty)* | Omniroute API key |
| `TTS_ENGINE` | `piper` | TTS engine: `piper` or `edge-tts` |
| `AUDIO_FORMAT` | `mp3` | Audio output format |
| `AUDIO_VOICE` | *(empty)* | Explicit voice name |
| `VOICES_DIR` | `/data/configs/voices` | Piper TTS voices directory |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot token |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | Telegram API base URL |
| `SEND_TELEGRAM` | `false` | Send Telegram notifications |
| `EMAIL_FROM` | *(empty)* | Sender email address |
| `TMP_BASE` | `/temp/yt-summary` | Temp file base dir |
| `EXTERNAL_TRACKING_FILE` | `/data/ltr/yt-dlp/files` | Video ID tracking file |
| `MAX_PLAYLIST_VIDEO_AGE_DAYS` | `0` | Max video age for playlists (0 = no limit) |
| `MAX_PLAYLIST_VIDEOS` | `0` | Max videos per playlist (0 = no limit) |

> [!WARNING]
> Never add real API keys/tokens to committed files. Keep them in the
> gitignored `.env` (chmod 600). If a secret was ever committed, rotate it.
