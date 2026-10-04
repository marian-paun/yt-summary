# AGENTS.md - yt-summary (YouTube summarizer)

## Run

```bash
./yt-summary "https://youtube.com/watch?v=VIDEO_ID"
./yt-summary --help
./yt-summary --help-all   # advanced/legacy options + every .env variable
```

Invocation errors (no target, unknown option, option missing its value) print a
short synopsis on stderr and exit 1 - not the full help.

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

- **Entry point**: `./yt-summary` (1329 lines) — main orchestrator, CLI parsing, pipeline coordination, output formatting
- **Libraries** (sourced by the entry point):
  - `lib/ollama.sh` — LLM API wrappers & session statistics
    - `ollama_chat()` — primary LLM call (Ollama native API); also delegates to `litellm_chat()` when `USE_LITELLM=true`
    - `litellm_chat()` — LiteLLM proxy (OpenAI-compatible) chat completion
    - Statistics: `_init_stats()`, `_update_stats()`, `update_video_stats()`, `stats_snapshot()`, `stats_tic()/toc()`, `show_stats()`, `format_stats_markdown()`
    - Model checks: `ollama_check()`, `ollama_model_exists()`
    - `init_stats()` — public initializer
  - `lib/omniroute.sh` — Omniroute proxy backend
    - `omniroute_chat()` — OpenAI-compatible chat completion via Omniroute; updates stats via `_update_stats()` if available
  - `lib/fallback.sh` — Cascading fallback backend (`LLM_BACKEND=fallback`)
    - `fallback_chat()` — tries Omniroute → Ollama Cloud (multi-key) → Ollama Local
    - `_omniroute_chat_fallback()`, `_ollama_cloud_chat_with_key()`, `_ollama_local_chat_fallback()` — per-tier implementations with retries
    - `try_omniroute()`, `try_ollama_cloud()`, `try_ollama_local()` — orchestration with retry loops
  - `lib/transcript.sh` — Transcript acquisition (yt-dlp + youtube-transcript-api + whisper fallback)
    - `fetch_transcript_with_fallback()` — main entry: tiered fetch (1) yt-dlp manual/auto subs RO/EN, (2) any-language subs, (3) auto subs, (4) youtube-transcript-api manual, (5) youtube-transcript-api auto, (6) whisper
    - `fetch_transcript()` — yt-dlp subtitle fetcher with language preference
    - `_fetch_with_yt_dlp_subtitles()`, `_fetch_with_yt_dlp_auto_subs()`, `_fetch_with_yt_dlp_any_sub()` — subtitle tiers
    - `_fetch_with_transcript_api()`, `_fetch_with_transcript_api_auto()` — python fallback
    - `_srt_to_text()` — SRT/VTT → plain text (dedup, HTML unescape)
    - `get_playlist_videos()` — playlist expansion with `--max-playlist-videos` / `--max-playlist-video-age-days` filters
    - `extract_video_id()`, `get_video_title()`, `is_playlist()`, `detect_audio_language()`, `get_transcript_word_count()`
  - `lib/whisper.sh` — whisper-ctranslate2 transcription fallback (local or remote over SSH)
    - `whisper_transcribe()` — orchestration: download audio → (optional) SSH transfer → run whisper (transcribe ± translate) → pull output → normalize
    - `whisper_download_audio()` — yt-dlp `-x --audio-format m4a`
    - `_whisper_push_file()`, `_whisper_pull_file()` — rsync/scp/shared transfer
    - `_whisper_run()` — invokes `whisper-ctranslate2` locally or via SSH (no timeout, req 2.8)
    - `_whisper_audio_lang()`, `whisper_result_lang()` — language detection helpers
    - `_whisper_ssh_setup()`, `_whisper_rsync_e_cmd()`, `_whisper_scp()` — SSH transport
    - `_whisper_cleanup_remote()` — remote work dir cleanup
  - `lib/cache.sh` — File-based summary cache with checksum validation
    - `cache_init()`, `cache_get_path()`, `cache_has_summary()`, `cache_has_key_points()`, `cache_is_complete()`
    - `cache_write_with_checksum()`, `cache_read()`, `cache_read_with_checksum()`, `cache_checksum()`
  - `lib/tts.sh` — Text-to-speech (Piper / edge-tts)
    - `generate_audio()` — dispatcher: strips markdown via `prepare_tts_text()` then calls engine
    - `prepare_tts_text()` — removes headers, bullets, blank lines
    - `generate_audio_piper()` — Piper TTS → WAV → ffmpeg → m4a/mp3
    - `generate_audio_edge_tts()` — edge-tts → mp3 → (optional) ffmpeg → m4a; on failure sets `EDGE_TTS_FAILURE=fallback` for Piper retry
    - `generate_audio_with_piper()` — resolves voice path, calls Piper
    - `get_voice_for_language()`, `get_edge_tts_voice()` — voice resolution (defaults per language)
    - `check_voice_exists()`, `resolve_tts_bin()` — validation helpers
  - `lib/help.sh` — CLI help/usage rendering and `.env` reference
    - `usage()` — dispatches `short` (synopsis), `help` (options), `all` (advanced + env + examples)
    - `env_show()`, `env_show_secret()`, `env_entry()` — formatting helpers
    - `suggest_option()` — typo correction for unknown flags
- **Pipeline**: fetch transcript → split into chunks → summarize each → merge → extract key points → (optional) phonetic rewrite → (optional) TTS audio

## Dependencies

- **Required**: `ollama`, `yt-dlp`, `jq`, `curl`
- **Optional**: `python3` + `youtube-transcript-api` (fallback transcript fetch; `pip install --user --break-system-packages youtube-transcript-api` — this is the reliable path when YouTube throttles yt-dlp's caption endpoint with HTTP 429), `mail`/`sendmail`/`mutt` (email), `piper-tts` or `edge-tts` (TTS/audio), `ffmpeg` (audio format conversion), `whisper-ctranslate2` (transcription fallback), `sshpass` (SSH password auth), `rsync`/`scp` (audio transfer to a remote whisper host)

## Transcription Fallback

When no manual or auto-generated subtitle (RO/EN or any other language) is available, `yt-summary` downloads the audio track and transcribes it with **whisper-ctranslate2** (`lib/whisper.sh`). The whisper engine may run locally (`WHISPER_HOST=localhost`) or on a remote machine reached over SSH (username/password, username/SSH-key, or a `~/.ssh/config` alias). Audio is transferred with rsync, scp, or a shared folder.

The transcript acquisition order in `fetch_transcript_with_fallback()` (`lib/transcript.sh`) is:

1. yt-dlp manual/auto subs (`ro,en`)
2. yt-dlp any-language manual/auto subs (summarized **with translation to English** when the source is not RO/EN)
3. yt-dlp auto-generated subs (any language; also translated to English when the source is not RO/EN)
4. `youtube-transcript-api` manual/auto subs (requires the `youtube-transcript-api` python module for `python3`; on Debian install with `pip install --user --break-system-packages youtube-transcript-api`). This tier is the reliable path when YouTube throttles yt-dlp's caption endpoint (HTTP 429) for a video that only has auto-generated captions.
5. whisper-ctranslate2 audio transcription (RO/EN audio → transcribe only; other languages → transcribe **and** translate to English, translation feeds the summary)

Long transcriptions are expected (Req 2.8): no timeout is applied to whisper; the process is aborted only on a whisper error/crash or missing output.

| Option | Description |
|--------|-------------|
| `--no-whisper` | Disable the whisper transcription fallback |
| `--whisper-host HOST` | whisper host: `localhost` or remote IP/hostname |
| `--whisper-model MODEL` | whisper model: `tiny`/`base`/`small`/`medium`/`large-v3` |
| `--whisper-ssh-user USER` | SSH username on the remote whisper host |
| `--whisper-ssh-auth AUTH` | SSH auth: `config` \| `key` \| `password` |
| `--whisper-ssh-key KEY` | SSH key path when `auth=key` |
| `--whisper-ssh-password PASS` | SSH password when `auth=password` (requires `sshpass`) |
| `--whisper-transfer MODE` | Audio transfer: `rsync` \| `scp` \| `shared` |
| `--whisper-remote-dir DIR` | Remote work dir on the whisper host |
| `--whisper-shared-dir DIR` | Shared folder path when `transfer=shared` |

## LLM Backends

Four backends are supported via `--backend` or `LLM_BACKEND` env var:

| Backend | Description | Options |
|---------|-------------|---------|
| `ollama` | local backend | `-m`/`--model`, `--url`/`-h`, `--num-ctx`, `--think` |
| `litellm` | LiteLLM proxy (cloud models) | `--backend litellm`, `-m`/`--model`, `--url`/`--proxy`, `--api-key` |
| `omniroute` | default Omniroute proxy (model routing) | `--backend omniroute`, `-m`/`--model`, `--url`/`--proxy`, `--api-key` |
| `fallback` | cascading fallback: Omniroute → Ollama Cloud → Ollama Local | `--backend fallback`, `OLLAMA_CLOUD_API_KEYS`, `OLLAMA_CLOUD_URL`, `OLLAMA_CLOUD_MODEL`, `OLLAMA_LOCAL_MODEL` |

Unified flags (`-m`/`--model`, `--url`/`--proxy`, `--api-key`/`--key`) work across all backends. Legacy backend flags (`--litellm-proxy`, `--omniroute`, `--litellm-model`, etc.) remain supported as backward-compatible aliases.

### Fallback Backend

The `fallback` backend implements a cascading fallback strategy:
1. **Omniroute** (primary) - Try first with configured `OMNIROUTE_*` options
2. **Ollama Cloud** (secondary) - Try if Omniroute fails; supports multiple API keys in priority order via `OLLAMA_CLOUD_API_KEYS` (comma-separated)
3. **Ollama Local** (tertiary) - Try if all Ollama Cloud keys fail; uses local Ollama at `localhost:11434` with `OLLAMA_LOCAL_MODEL`
4. **Abort** - If all three fail, abort the request

Configuration via `.env`:
- `OLLAMA_CLOUD_API_KEYS` - Comma-separated list of 1-3 API keys
- `OLLAMA_CLOUD_URL` - Ollama Cloud API base URL (default: `https://api.ollama.cloud`)
- `OLLAMA_CLOUD_MODEL` - Model name for Ollama Cloud
- `OLLAMA_LOCAL_MODEL` - Model name for local Ollama (default: `gemma2:2b`)

## Output Options

| Option | Description |
|--------|-------------|
| `--summary-only` | Only generate summary section |
| `--key-points-only` | Only generate key points section |
| `--print-only` | Print to console only, don't save to file |
| `--save-only` | Save to file only, don't print to console |
| `--email EMAIL` | Send output via email (requires sendmail/mail/mutt) |
| `--telegram` | Send per-video statistics via Telegram (one message after each video) |
| `--audio` | Generate audio from summary |
| `--voice VOICE` | Explicit voice name (overrides language detection) |
| `--tts-engine ENGINE` | TTS engine: `piper` or `edge-tts`. If `edge-tts` cannot deliver the audio (binary missing, connection refused, service unavailable, throttling, crash), it automatically falls back to `piper` using the default voice for the detected language. A bad `--voice` or a local ffmpeg failure is reported instead of falling back. |
| `--audio-format FORMAT` | Audio format: `m4a` or `mp3` |
| `--stats` | Show session statistics at end (counts, tokens, and per-video processing durations: YT-dlp extraction → Whisper → LLM duration → TTS → Total) |
| `--include-stats` | Include per-video statistics in output document (the final `--stats` block stays cumulative for the whole session) |
| `--no-auto-chunk` | Disable the LLM chunk-size recommendation (use configured `CHUNK_WORDS`) |

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
| `LLM_BACKEND` | `omniroute` | Backend: `ollama`, `litellm`, or `omniroute` |
| `LLM_URL` / `LLM_MODEL` / `LLM_API_KEY` | *(empty)* | Unified overrides applied to the selected backend |
| `CHUNK_WORDS` | `900` | Words per transcript chunk |
| `AUTO_CHUNK` | `true` | Ask the LLM for the recommended chunk size before summarizing (`false` = always use `CHUNK_WORDS`; an explicit `--chunk-words` flag also disables it) |
| `MAX_TOKENS` | `30000` | Max tokens per LLM response |
| `TEMPERATURE` | `0.1` | LLM temperature |
| `MAX_RETRIES` | `5` | LLM retries |
| `SUMMARY_LENGTH` | `medium` | short/medium/long |
| `TARGET_LANGUAGE` | `en` | Output language. If set (env/.env/`--language`), it is respected; otherwise per-video audio-language detection applies (Romanian audio → Romanian, otherwise English) |
| `PROMPT_SYSTEM_CHUNK` / `PROMPT_USER_CHUNK` | *(defaults)* | Chunk-summarization prompts |
| `PROMPT_SYSTEM_AGGREGATE` / `PROMPT_USER_AGGREGATE` | *(defaults)* | Merge prompts |
| `PROMPT_SYSTEM_KEYPOINTS` / `PROMPT_USER_KEYPOINTS` | *(defaults)* | Key-points prompts |
| `PROMPT_SYSTEM_CHUNKSIZE` / `PROMPT_USER_CHUNKSIZE` | *(defaults)* | Chunk-size recommendation prompts (placeholders: `{{INPUT_WORDS}}`, `{{DEFAULT_CHUNK_WORDS}}`) |
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
| `PIPER_BIN` | `piper` | Piper binary: name resolved on `PATH`, or a full path |
| `EDGE_TTS_BIN` | `edge-tts` | edge-tts binary: name resolved on `PATH`, or a full path |
| `AUDIO_FORMAT` | `mp3` | Audio output format |
| `AUDIO_VOICE` | *(empty)* | Explicit voice name (or, for piper, a path to a `.onnx` file) |
| `VOICES_DIR` | `/data/configs/voices` | Piper TTS voices directory |
| `DEFAULT_VOICE_PIPER_EN` | `en_US-ryan-high` | Default English voice for piper (filename, no `.onnx`) when `--voice` unset |
| `DEFAULT_VOICE_PIPER_RO` | `ro_RO-sanda-high` | Default Romanian voice for piper (filename, no `.onnx`) when `--voice` unset |
| `DEFAULT_VOICE_TTS_EN` | `en-US-EmmaMultilingualNeural` | Default English voice for edge-tts (voice name) when `--voice` unset |
| `DEFAULT_VOICE_TTS_RO` | `ro-RO-AlinaNeural` | Default Romanian voice for edge-tts (voice name) when `--voice` unset |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot token |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | Telegram API base URL |
| `SEND_TELEGRAM` | `true` | Send Telegram notifications |
| `MQTT_BROKER` / `MQTT_TOPIC` / `MQTT_USER` / `MQTT_PASSWORD` | *(empty)* | Publish session statistics as JSON (requires `mosquitto-clients`) |
| `EMAIL_FROM` | *(empty)* | Sender email address |
| `TMP_BASE` | *fresh `mktemp -d` per run* | Temp file base dir; a configured dir is reused and not deleted on exit |
| `EXTERNAL_TRACKING_FILE` | `/data/ltr/yt-dlp/files` | Video ID tracking file |
| `MAX_PLAYLIST_VIDEO_AGE_DAYS` | `0` | Max video age for playlists (0 = no limit) |
| `MAX_PLAYLIST_VIDEOS` | `0` | Max videos per playlist (0 = no limit) |
| `WHISPER_ENABLED` | `true` | Enable whisper-ctranslate2 fallback (set `false` or use `--no-whisper`) |
| `YTDLP_COOKIES` | *(empty)* | Path to a yt-dlp cookies file used for subtitle downloads. YouTube throttles the caption endpoint with HTTP 429 for anonymous requests; cookies avoid that so auto-generated subtitles are used instead of falling back to whisper |
| `WHISPER_HOST` | `localhost` | whisper host: `localhost` or remote IP/hostname |
| `WHISPER_MODEL` | `medium` | whisper model: tiny/base/small/medium/large-v3 |
| `WHISPER_BIN` | `whisper-ctranslate2` | Binary name/path (local mode) |
| `WHISPER_SSH_USER` | *(empty)* | SSH username on the remote whisper host |
| `WHISPER_SSH_AUTH` | `config` | SSH auth mode: `config` \| `key` \| `password` |
| `WHISPER_SSH_KEY` | `~/.ssh/id_rsa` | SSH private key path (auth=key) |
| `WHISPER_SSH_PASSWORD` | *(empty)* | SSH password (auth=password; requires `sshpass`) |
| `WHISPER_TRANSFER` | `rsync` | Audio transfer: `rsync` \| `scp` \| `shared` |
| `WHISPER_SHARED_DIR` | *(empty)* | Shared folder path (transfer=shared) |
| `WHISPER_REMOTE_DIR` | `/tmp/yt-summary-whisper` | Remote work dir on the whisper host |
| `WHISPER_BIN` | `whisper-ctranslate2` | whisper binary name/path (local mode) |
| `PROMPT_SYSTEM_CHUNKSIZE` / `PROMPT_USER_CHUNKSIZE` | *(defaults)* | Chunk-size recommendation prompts |

> [!WARNING]
> Never add real API keys/tokens to committed files. Keep them in the
> gitignored `.env` (chmod 600). If a secret was ever committed, rotate it.
