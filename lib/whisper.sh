#!/bin/bash
# lib/whisper.sh - whisper-ctranslate2 transcription fallback
#
# Runs whisper-ctranslate2 locally or on a remote machine over SSH.
# Audio is downloaded via yt-dlp, optionally transferred (rsync/scp/shared
# folder), transcribed, and the result is written as plain text in the same
# format as converted subtitles so it can be fed into the normal pipeline.

set -euo pipefail

: "${WHISPER_ENABLED:=true}"
: "${WHISPER_HOST:=localhost}"
: "${WHISPER_SSH_USER:=}"
: "${WHISPER_SSH_AUTH:=config}"        # config | key | password
: "${WHISPER_SSH_KEY:=$HOME/.ssh/id_rsa}"
: "${WHISPER_SSH_PASSWORD:=}"
: "${WHISPER_TRANSFER:=rsync}"          # rsync | scp | shared
: "${WHISPER_SHARED_DIR:=}"
: "${WHISPER_REMOTE_DIR:=/tmp/yt-summary-whisper}"
: "${WHISPER_MODEL:=medium}"
: "${WHISPER_BIN:=whisper-ctranslate2}"

WHISPER_HOST="${WHISPER_HOST:-localhost}"
WHISPER_DETECTED_LANG="${WHISPER_DETECTED_LANG:-}"

WHISPER_TMP="${TMP_BASE}/whisper"
WHISPER_AUDIO_DIR="${WHISPER_TMP}/audio"
WHISPER_OUT_DIR="${WHISPER_TMP}/out"

_whisper_log() {
    local level="$1"
    shift
    if [[ "${TRANSCRIPT_VERBOSE:-false}" == "true" ]] || [[ "$level" == "ERROR" ]] || [[ "$level" == "WARN" ]]; then
        echo "[${level}] [whisper] $*" >&2
    fi
}

whisper_log_info() { _whisper_log "INFO" "$@"; }
whisper_log_debug() { _whisper_log "DEBUG" "$@"; }
whisper_log_warn() { _whisper_log "WARN" "$@"; }
whisper_log_error() { _whisper_log "ERROR" "$@"; }

_whisper_init() {
    mkdir -p "$WHISPER_AUDIO_DIR" "$WHISPER_OUT_DIR"
}

_is_remote() {
    [[ "$WHISPER_HOST" != "localhost" ]]
}

# --- SSH setup ----------------------------------------------------------------

# Validates the SSH configuration and sets the global _WHISPER_SSH_ARGS array
# plus WHISPER_SSH_TARGET so the same transport works for ssh, scp and rsync.
_whisper_ssh_setup() {
    _WHISPER_SSH_ARGS=()
    WHISPER_SSH_TARGET="$WHISPER_HOST"
    if [[ -n "$WHISPER_SSH_USER" ]]; then
        WHISPER_SSH_TARGET="${WHISPER_SSH_USER}@${WHISPER_HOST}"
    fi

    case "$WHISPER_SSH_AUTH" in
        key)
            if [[ ! -f "$WHISPER_SSH_KEY" ]]; then
                whisper_log_error "SSH key not found: $WHISPER_SSH_KEY"
                return 1
            fi
            _WHISPER_SSH_ARGS=(ssh -i "$WHISPER_SSH_KEY" -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "$WHISPER_SSH_TARGET")
            ;;
        password)
            if ! command -v sshpass >/dev/null 2>&1; then
                whisper_log_error "sshpass is required for WHISPER_SSH_AUTH=password"
                return 1
            fi
            if [[ -z "$WHISPER_SSH_PASSWORD" ]]; then
                whisper_log_error "WHISPER_SSH_PASSWORD is empty"
                return 1
            fi
            _WHISPER_SSH_ARGS=(sshpass -p "$WHISPER_SSH_PASSWORD" ssh \
                -o StrictHostKeyChecking=accept-new "$WHISPER_SSH_TARGET")
            ;;
        config|*)
            # Rely on ~/.ssh/config for host alias/user/key.
            _WHISPER_SSH_ARGS=(ssh -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "$WHISPER_SSH_TARGET")
            ;;
    esac
}

# Prints the ssh transport string used by `rsync -e`.
_whisper_rsync_e_cmd() {
    case "$WHISPER_SSH_AUTH" in
        password) printf 'sshpass -p %q ssh -o StrictHostKeyChecking=accept-new' "$WHISPER_SSH_PASSWORD" ;;
        key)      printf 'ssh -i %q -o BatchMode=yes -o StrictHostKeyChecking=accept-new' "$WHISPER_SSH_KEY" ;;
        *)        printf 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' ;;
    esac
}

# Runs a command on the whisper host. No timeouts are applied: a long-running
# transcription is expected and must not be aborted (req 2.8).
_whisper_run_remote() {
    local remote_cmd="$1"
    _whisper_ssh_setup || return 1
    "${_WHISPER_SSH_ARGS[@]}" "$remote_cmd"
}

# --- Audio download -----------------------------------------------------------

whisper_download_audio() {
    local url="$1"
    local video_id="$2"

    _whisper_init

    local out_pattern="${WHISPER_AUDIO_DIR}/${video_id}.%(ext)s"

    # -x extracts audio; m4a keeps files small for transfer. ffmpeg is needed
    # for extraction (already a soft dependency of the project).
    whisper_log_info "Downloading audio track for $video_id (this may take a while)..."
    if ! yt-dlp -x --audio-format m4a --audio-quality 0 \
        --no-playlist -o "$out_pattern" "$url" >&2; then
        whisper_log_error "yt-dlp audio download failed for $video_id"
        return 1
    fi

    local audio_file
    audio_file=$(find "$WHISPER_AUDIO_DIR" -maxdepth 1 -name "${video_id}.m4a" | head -1)
    if [[ -z "$audio_file" ]] || [[ ! -f "$audio_file" ]]; then
        whisper_log_error "Downloaded audio file not found for $video_id"
        return 1
    fi

    echo "$audio_file"
}

# --- Transfer -----------------------------------------------------------------

# Transfers a local file to the whisper host. Prints the path of the file
# as seen by the whisper host.
_whisper_push_file() {
    local local_path="$1"
    local fname
    fname=$(basename "$local_path")

    case "$WHISPER_TRANSFER" in
        shared)
            if [[ -z "$WHISPER_SHARED_DIR" ]]; then
                whisper_log_error "WHISPER_SHARED_DIR is empty but WHISPER_TRANSFER=shared"
                return 1
            fi
            local remote_path="${WHISPER_SHARED_DIR}/${fname}"
            cp "$local_path" "$remote_path" || {
                whisper_log_error "copy to shared dir failed: $remote_path"
                return 1
            }
            echo "$remote_path"
            ;;
        rsync)
            _whisper_ssh_setup || return 1
            local e_cmd remote_path
            e_cmd=$(_whisper_rsync_e_cmd)
            remote_path="${WHISPER_REMOTE_DIR}/${fname}"
            if ! rsync -z -e "$e_cmd" "$local_path" \
                "${WHISPER_SSH_TARGET}:${remote_path}" >&2; then
                whisper_log_error "rsync transfer failed: $local_path"
                return 1
            fi
            echo "$remote_path"
            ;;
        scp)
            _whisper_ssh_setup || return 1
            local remote_path="${WHISPER_REMOTE_DIR}/${fname}"
            if ! _whisper_scp "$local_path" "${WHISPER_SSH_TARGET}:${remote_path}"; then
                whisper_log_error "scp transfer failed: $local_path"
                return 1
            fi
            echo "$remote_path"
            ;;
        *)
            whisper_log_error "Invalid WHISPER_TRANSFER: $WHISPER_TRANSFER (must be rsync, scp, or shared)"
            return 1
            ;;
    esac
}

# Fetches a remote file back to a local path.
_whisper_pull_file() {
    local remote_path="$1"
    local local_path="$2"

    case "$WHISPER_TRANSFER" in
        shared)
            cp "$remote_path" "$local_path"
            ;;
        rsync)
            _whisper_ssh_setup || return 1
            local e_cmd
            e_cmd=$(_whisper_rsync_e_cmd)
            rsync -z -e "$e_cmd" "${WHISPER_SSH_TARGET}:${remote_path}" "$local_path" >&2
            ;;
        scp)
            _whisper_ssh_setup || return 1
            _whisper_scp "${WHISPER_SSH_TARGET}:${remote_path}" "$local_path"
            ;;
    esac
}

# scp wrapper honoring the configured SSH auth method.
_whisper_scp() {
    local -a scp_args=(scp)
    case "$WHISPER_SSH_AUTH" in
        password) scp_args=(sshpass -p "$WHISPER_SSH_PASSWORD" scp) ;;
        key)      scp_args=(scp -i "$WHISPER_SSH_KEY" -o BatchMode=yes) ;;
        *)        scp_args=(scp) ;;
    esac
    scp_args+=( -o StrictHostKeyChecking=accept-new "$@" )
    "${scp_args[@]}"
}

# --- Cleanup --------------------------------------------------------------------

# Cleans up the remote work directory after transcription.
_whisper_cleanup_remote() {
    if ! _is_remote; then
        return 0
    fi
    local work_dir="$WHISPER_REMOTE_DIR"
    if [[ "$WHISPER_TRANSFER" == "shared" ]]; then
        work_dir="$WHISPER_SHARED_DIR"
    fi
    if [[ -z "$work_dir" ]]; then
        return 0
    fi
    _whisper_ssh_setup || return 0
    _whisper_run_remote "rm -rf $(printf '%q' "$work_dir")" >/dev/null 2>&1 || true
}

# --- Whisper execution ----------------------------------------------------------

# Runs whisper-ctranslate2 on the given audio path (as seen by the whisper
# host) with the given task, producing output named after the audio basename
# in $out_dir. No timeout: aborts only on whisper error/crash (req 2.8).
_whisper_run() {
    local audio_path="$1"   # path as seen by whisper host
    local task="$2"         # transcribe | translate
    local out_dir="$3"      # output dir on whisper host
    shift 3
    local -a lang_flags=("$@")   # optional --language CODE

    local -a args=(--model "$WHISPER_MODEL" --task "$task" \
        --output_format txt --output_dir "$out_dir")
    if [[ "${#lang_flags[@]}" -gt 0 ]]; then
        args+=( "${lang_flags[@]}" )
    fi

    if ! _is_remote; then
        if ! command -v "$WHISPER_BIN" >/dev/null 2>&1; then
            whisper_log_error "$WHISPER_BIN not found locally; install it or set WHISPER_HOST to a remote host"
            return 1
        fi
        whisper_log_info "Running whisper-ctranslate2 locally (task=$task, model=$WHISPER_MODEL)..."
        whisper_log_info "Transcription can take a long time; it will not be aborted unless whisper errors or crashes."
        # No timeout — see req 2.8
        "$WHISPER_BIN" "${args[@]}" "$audio_path" 2>&1 | while IFS= read -r line; do
            whisper_log_debug "whisper: $line"
        done
        return "${PIPESTATUS[0]}"
    else
        # Build a single, properly quoted remote command.
        local remote_cmd
        remote_cmd="$WHISPER_BIN --model $(printf '%q' "$WHISPER_MODEL") --task $(printf '%q' "$task") \
            --output_format txt --output_dir $(printf '%q' "$out_dir")"
        local lf
        for lf in "${lang_flags[@]}"; do
            remote_cmd+=" $(printf '%q' "$lf")"
        done
        remote_cmd+=" $(printf '%q' "$audio_path") 2>&1"

        whisper_log_info "Running whisper-ctranslate2 on $WHISPER_HOST (task=$task, model=$WHISPER_MODEL)..."
        whisper_log_info "Transcription can take a long time; it will not be aborted unless whisper errors or crashes."
        # No timeout — see req 2.8. stderr and stdout are streamed to the log.
        _whisper_run_remote "$remote_cmd" 2>&1 | while IFS= read -r line; do
            whisper_log_debug "whisper: $line"
        done
        return "${PIPESTATUS[0]}"
    fi
}

# Returns the raw audio language code reported by yt-dlp, or "unknown".
_whisper_audio_lang() {
    local url="$1"
    local video_id="$2"

    local lang="unknown"
    if [[ -n "${METADATA_TMP:-}" ]]; then
        local cache_file="${METADATA_TMP}/${video_id}.whisper_lang"
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return
        fi

        local meta
        meta=$(yt-dlp --skip-download --no-warnings --print "%(language)s" "$url" 2>/dev/null || true)
        if [[ -n "$meta" && "$meta" != "NA" && "$meta" != "None" ]]; then
            lang="${meta%%-*}"   # e.g. "ro-RO" -> "ro"
        fi
        mkdir -p "$METADATA_TMP" 2>/dev/null || true
        echo "$lang" > "$cache_file" 2>/dev/null || true
    fi
    echo "$lang"
}

# Echoes the first existing, non-empty file among the given candidates.
_whisper_existing() {
    local f
    for f in "$@"; do
        if [[ -s "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Echoes the language of the transcript produced for a video id, or "" if the
# marker file is missing. Must be used instead of reading WHISPER_DETECTED_LANG
# when whisper_transcribe() was called through command substitution (subshell).
whisper_result_lang() {
    local video_id="$1"
    if [[ -f "${WHISPER_OUT_DIR}/${video_id}.lang" ]]; then
        cat "${WHISPER_OUT_DIR}/${video_id}.lang"
    else
        echo ""
    fi
}

# --- Orchestration ----------------------------------------------------------------

# Transcribes the video's audio track. On success, echoes the path of the
# normalized transcript text file (plain text, subtitle-style, req 2.7) and
# sets WHISPER_DETECTED_LANG to the language of the delivered text.
whisper_transcribe() {
    local url="$1"
    local video_id="$2"

    if [[ "$WHISPER_ENABLED" != "true" ]]; then
        whisper_log_debug "Whisper fallback disabled (WHISPER_ENABLED != true)"
        return 1
    fi

    WHISPER_DETECTED_LANG=""
    _whisper_init || return 1

    # Reuse a transcription produced earlier in this run (req 2.8: long
    # transcriptions must not be repeated needlessly).
    local cached_txt="${WHISPER_OUT_DIR}/${video_id}_final.txt"
    if [[ -s "$cached_txt" ]]; then
        WHISPER_DETECTED_LANG="$(cat "${WHISPER_OUT_DIR}/${video_id}.lang" 2>/dev/null || echo en)"
        whisper_log_info "Using cached whisper transcript: $cached_txt"
        echo "$cached_txt"
        return 0
    fi

    local audio_file
    audio_file=$(whisper_download_audio "$url" "$video_id") || return 1

    local audio_lang
    audio_lang=$(_whisper_audio_lang "$url" "$video_id")

    # Run set selection (req 2.6):
    #   ro/en audio              -> transcribe only
    #   other / unknown audio    -> transcribe (original) + translate (English)
    # The English translation feeds the summary pipeline.
    # Distinct audio basenames yield distinct output files so neither run
    # overwrites the other (whisper names output after the input basename).
    local -a run_tasks=() run_names=() run_langs=() run_files=()
    if [[ "$audio_lang" == "ro" || "$audio_lang" == "en" ]]; then
        run_tasks=(transcribe)
        run_names=("$video_id")
        run_langs=("$audio_lang")
        run_files=("$audio_file")
    else
        whisper_log_info "Audio language '${audio_lang}' is not RO/EN: producing both transcription and English translation (req 2.6)"
        cp "$audio_file" "${WHISPER_AUDIO_DIR}/${video_id}_orig.m4a"
        cp "$audio_file" "${WHISPER_AUDIO_DIR}/${video_id}_en.m4a"
        run_tasks=(transcribe translate)
        run_names=("${video_id}_orig" "${video_id}_en")
        run_langs=("$audio_lang" "$audio_lang")
        run_files=("${WHISPER_AUDIO_DIR}/${video_id}_orig.m4a" "${WHISPER_AUDIO_DIR}/${video_id}_en.m4a")
    fi

    local out_dir="$WHISPER_OUT_DIR"
    if _is_remote; then
        # The whisper host work dir. For transfer=shared the shared folder is
        # the work dir too (it is the same path on both machines); otherwise a
        # remote dir that audio is pushed to / output pulled from.
        local work_dir="$WHISPER_REMOTE_DIR"
        if [[ "$WHISPER_TRANSFER" == "shared" ]]; then
            if [[ -z "$WHISPER_SHARED_DIR" ]]; then
                whisper_log_error "WHISPER_SHARED_DIR is empty but WHISPER_TRANSFER=shared"
                return 1
            fi
            work_dir="$WHISPER_SHARED_DIR"
        fi

        _whisper_run_remote "mkdir -p $(printf '%q' "$work_dir")" || {
            whisper_log_error "Failed to create remote dir $work_dir on $WHISPER_HOST"
            return 1
        }
        out_dir="$work_dir"

        local -a remote_files=()
        local lf
        for lf in "${run_files[@]}"; do
            local pushed
            pushed=$(_whisper_push_file "$lf") || {
                whisper_log_error "Failed to transfer audio to $WHISPER_HOST"
                return 1
            }
            remote_files+=( "$pushed" )
        done
        run_files=( "${remote_files[@]}" )
    fi

    local i task in_name produced
    for i in "${!run_tasks[@]}"; do
        task="${run_tasks[$i]}"
        in_name="${run_names[$i]}"

        local -a lang_flag=()
        if [[ "${run_langs[$i]}" != "unknown" ]]; then
            lang_flag=( --language "${run_langs[$i]}" )
        fi

        produced="${out_dir}/${in_name}.txt"
        # Remove stale output so a failed run is detected by a missing file.
        if _is_remote; then
            _whisper_run_remote "rm -f $(printf '%q' "$produced")" >/dev/null 2>&1 || true
        else
            rm -f "$produced"
        fi

        if ! _whisper_run "${run_files[$i]}" "$task" "$out_dir" "${lang_flag[@]}"; then
            whisper_log_error "whisper-ctranslate2 exited with an error (task=$task)"
            return 1
        fi

        # Verify the output exists (abort only on error/crash, not duration).
        if _is_remote; then
            local staged="${WHISPER_TMP}/${in_name}.txt"
            if ! _whisper_pull_file "$produced" "$staged"; then
                whisper_log_error "Failed to fetch whisper output from $WHISPER_HOST (task=$task)"
                return 1
            fi
            if [[ ! -s "$staged" ]]; then
                whisper_log_error "whisper produced no output on remote host (task=$task)"
                return 1
            fi
        elif [[ ! -s "$produced" ]]; then
            whisper_log_error "whisper produced no output (task=$task)"
            return 1
        fi
    done

    # Req 2.6: the English translation feeds the summary when it was produced.
    local result_file
    result_file=$(_whisper_existing \
        "${WHISPER_TMP}/${video_id}_en.txt"   "${WHISPER_OUT_DIR}/${video_id}_en.txt" \
        "${WHISPER_TMP}/${video_id}.txt"      "${WHISPER_OUT_DIR}/${video_id}.txt" \
        "${WHISPER_TMP}/${video_id}_orig.txt" "${WHISPER_OUT_DIR}/${video_id}_orig.txt") || true
    if [[ -z "$result_file" ]]; then
        whisper_log_error "No whisper output files found"
        return 1
    fi

    if [[ "$result_file" == *"_en.txt" ]]; then
        WHISPER_DETECTED_LANG="en"
    else
        WHISPER_DETECTED_LANG="$audio_lang"
    fi

    # Normalize: collapse to a single flowing line like _srt_to_text output
    # (req 2.7: process the transcribed text like a normal subtitle download).
    local normalized="${WHISPER_OUT_DIR}/${video_id}_final.txt"
    awk 'BEGIN{RS="";}{gsub(/\n/, " "); gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, ""); printf "%s", $0}' "$result_file" > "$normalized"

    if [[ ! -s "$normalized" ]]; then
        whisper_log_error "Whisper transcript normalization failed"
        return 1
    fi
    echo "$WHISPER_DETECTED_LANG" > "${WHISPER_OUT_DIR}/${video_id}.lang"

    whisper_log_info "Whisper transcription complete (language: $WHISPER_DETECTED_LANG)"
    _whisper_cleanup_remote
    echo "$normalized"
}