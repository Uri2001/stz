#!/usr/bin/env bash
# stz.sh — universal backup/restore via tar+ssh+zstd
# Author: Uri2001. License: MIT.
set -Eeuo pipefail

VERSION="1.0.0"

# ---------- default settings ----------
SSH_BIN=${SSH_BIN:-ssh}
PV_BIN=${PV_BIN:-pv}
TAR_BIN=${TAR_BIN:-tar}
ZSTD_BIN=${ZSTD_BIN:-zstd}

USE_PV=1                  # 1=show progress, 0=disable
SUDO_REMOTE="sudo -n"     # how to call sudo on remote side
SUDO_LOCAL="sudo -n"      # how to call sudo locally for extraction
ZSTD_LEVEL=19             # zstd compression level
ZSTD_THREADS=0            # 0=auto
KEEP_ACLS=1               # --acls
KEEP_XATTRS=1             # --xattrs

SSH_PORT=""
SSH_IDENTITY=""

ARCHIVE_FILE=""           # path to .tar.zst
REMOTE_HOST=""            # user@host
RESTORE_PREFIX="/"        # where to extract on remote (default "/")
OUT_DIR="."               # where to write archives / test extractions locally

DRY_RUN=0                 # 1=show commands without executing
VERBOSE=0                 # 1=show full commands before execution

EXCLUDES=()               # --exclude
PATHS=()                  # paths relative to / (etc/nginx, var/www, ...)

# ---------- utilities ----------
log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR ] %s\n' "$*"  >&2; }
die()  { err "$*"; exit 1; }

cleanup_partial() {
  local rc=$?
  if (( rc != 0 )) && [[ -n "${ARCHIVE_FILE:-}" && -f "$ARCHIVE_FILE" ]]; then
    warn "Removing partially created file: $ARCHIVE_FILE (code $rc)"
    rm -f -- "$ARCHIVE_FILE" || true
  fi
  exit "$rc"
}
trap cleanup_partial EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH"
}
has_cmd() { command -v "$1" >/dev/null 2>&1; }

shell_escape() {
  # Escape arguments for safe passing through SSH
  local result=""
  for arg in "$@"; do
    result+="$(printf '%q ' "$arg")"
  done
  printf '%s' "$result"
}

build_ssh_opts() {
  local -n _arr=$1
  _arr=()
  [[ -n "$SSH_PORT"     ]] && _arr+=(-p "$SSH_PORT")
  [[ -n "$SSH_IDENTITY" ]] && _arr+=(-i "$SSH_IDENTITY")
  # Recommended options for script mode:
  _arr+=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  _arr+=(-o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
}

bytes_of() {
  # print file size in bytes (works both GNU and BSD stat)
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

tar_feat_flags() {
  # build --acls/--xattrs flags if enabled; fills array by reference
  local -n _tff=$1
  _tff=()
  (( KEEP_ACLS   )) && _tff+=(--acls)
  (( KEEP_XATTRS )) && _tff+=(--xattrs)
}

pv_or_cat() {
  # if USE_PV=1 and pv available — use it; otherwise cat
  if (( USE_PV )) && has_cmd "$PV_BIN"; then
    "$PV_BIN"
  else
    cat
  fi
}

pv_file_or_cat() {
  # show progress for a known-size file
  local f="$1"
  if (( USE_PV )) && has_cmd "$PV_BIN"; then
    local size
    size=$(bytes_of "$f")
    "$PV_BIN" -s "$size" "$f"
  else
    cat "$f"
  fi
}

print_help() {
cat <<'USAGE'
Usage:
  stz.sh <command> [options] [paths...]

Commands:
  backup         — create local archive from remote paths (remote -> local .tar.zst)
  list           — show archive contents as tree
  test-restore   — test extract archive into local folder
  restore        — restore archive to remote server (local -> remote)

General options:
  -h, --help                 show help
  -V, --version              print version
  -v, --verbose              show full commands before execution
  --dry-run                  show commands without executing
  --no-pv                    disable progress indicator
  --no-acls                  do not preserve ACLs (default: preserve)
  --no-xattrs                do not preserve xattrs (default: preserve)

SSH / sudo:
  -H, --host USER@HOST       remote host (for backup/restore)
  -p, --port PORT            SSH port
  -i, --identity KEY         SSH private key
  --sudo-remote CMD          sudo command remotely (default 'sudo -n')
  --sudo-local  CMD          sudo command locally (default 'sudo -n')

Archive / paths:
  -f, --file FILE.tar.zst    archive path (for list/test-restore/restore; for backup — output file)
  -o, --out-dir DIR          local directory for archive/test extraction (default: .)
  --prefix DIR               prefix on remote during restore (default: /)
  --exclude GLOB             exclude pattern (can be repeated)
  --zstd-level N             zstd compression level (1..22, default 19)
  --threads N                zstd threads (0=auto)

For backup: specify paths relative to / (e.g. etc/nginx var/www).

Examples:
  # Backup from remote server
  stz.sh backup -H user@host -f nginx.tzst etc/nginx

  # View archive content as tree
  stz.sh list -f nginx.tzst

  # Test extraction locally (into ./restore-test)
  stz.sh test-restore -f nginx.tzst -o ./restore-test

  # Restore archive to remote server (to root)
  stz.sh restore -f nginx.tzst -H user@host

  # Restore into alternative prefix on remote
  stz.sh restore -f nginx.tzst -H user@host --prefix /tmp/restore-root
USAGE
}

# ---------- arg parsing ----------
# Handle --help / --version before extracting MODE
case "${1:-}" in
  -h|--help)    print_help; exit 0;;
  -V|--version) echo "$VERSION"; exit 0;;
esac

MODE="${1:-}"
[[ -z "$MODE" ]] && { print_help; exit 1; }
shift || true

while (( $# )); do
  case "$1" in
    -h|--help) print_help; exit 0;;
    -V|--version) echo "$VERSION"; exit 0;;
    -v|--verbose) VERBOSE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --no-pv) USE_PV=0; shift;;
    --no-acls) KEEP_ACLS=0; shift;;
    --no-xattrs) KEEP_XATTRS=0; shift;;
    -H|--host) REMOTE_HOST="${2:?}"; shift 2;;
    -p|--port) SSH_PORT="${2:?}"; shift 2;;
    -i|--identity) SSH_IDENTITY="${2:?}"; shift 2;;
    --sudo-remote) SUDO_REMOTE="${2:?}"; shift 2;;
    --sudo-local)  SUDO_LOCAL="${2:?}";  shift 2;;
    -f|--file) ARCHIVE_FILE="${2:?}"; shift 2;;
    -o|--out-dir) OUT_DIR="${2:?}"; shift 2;;
    --prefix) RESTORE_PREFIX="${2:?}"; shift 2;;
    --exclude) EXCLUDES+=("${2:?}"); shift 2;;
    --zstd-level) ZSTD_LEVEL="${2:?}"; shift 2;;
    --threads) ZSTD_THREADS="${2:?}"; shift 2;;
    --) shift; break;;
    -*)
      die "Unknown option: $1 (see --help)";;
    *)
      # Remaining args are paths for backup (relative to /)
      PATHS+=("$1"); shift;;
  esac
done

# ---------- parameter validation ----------
[[ "$ZSTD_LEVEL" =~ ^[0-9]+$ ]] || die "--zstd-level must be a number (got '$ZSTD_LEVEL')"
(( ZSTD_LEVEL >= 1 && ZSTD_LEVEL <= 22 )) || die "--zstd-level must be 1..22 (got $ZSTD_LEVEL)"
[[ "$ZSTD_THREADS" =~ ^[0-9]+$ ]] || die "--threads must be a non-negative number (got '$ZSTD_THREADS')"

# ---------- environment checks ----------
require_cmd "$SSH_BIN"
require_cmd "$TAR_BIN"
require_cmd "$ZSTD_BIN"
if (( USE_PV )); then
  has_cmd "$PV_BIN" || warn "pv not found — progress indicator will be disabled"
fi

# ---------- command functions ----------
cmd_backup() {
  [[ -n "$REMOTE_HOST" ]] || die "Need --host for backup"
  (( ${#PATHS[@]} )) || die "Need at least one path (e.g. etc/nginx)"
  mkdir -p -- "$OUT_DIR"

  if [[ -z "$ARCHIVE_FILE" ]]; then
    local stamp host_sanitized
    stamp=$(date +%F-%H%M%S)
    host_sanitized=${REMOTE_HOST//@/_}
    ARCHIVE_FILE="$OUT_DIR/backup-${host_sanitized}-${stamp}.tar.zst"
  else
    [[ "$ARCHIVE_FILE" = /* ]] || ARCHIVE_FILE="$OUT_DIR/$ARCHIVE_FILE"
  fi

  log "Checking tar availability on remote..."
  local ssh_opts=()
  build_ssh_opts ssh_opts
  local check_cmd
  check_cmd="command -v $(shell_escape "$TAR_BIN") >/dev/null"
  if ! "$SSH_BIN" "${ssh_opts[@]}" "$REMOTE_HOST" "$check_cmd"; then
    die "tar not found on remote"
  fi

  local -a tflags=()
  tar_feat_flags tflags

  log "Creating archive: $ARCHIVE_FILE"
  log "Sources (remote:/): ${PATHS[*]}"
  log "Excludes: ${EXCLUDES[*]:-(none)}"

  # Build escaped remote tar command
  local -a remote_parts=()
  remote_parts+=($SUDO_REMOTE)
  remote_parts+=("$TAR_BIN" -C / -cpf -)
  (( ${#tflags[@]} )) && remote_parts+=("${tflags[@]}")
  for ex in "${EXCLUDES[@]}"; do remote_parts+=(--exclude="$ex"); done
  remote_parts+=("${PATHS[@]}")
  local remote_cmd_str
  remote_cmd_str=$(shell_escape "${remote_parts[@]}")

  local pipeline_desc="$SSH_BIN ${ssh_opts[*]} $REMOTE_HOST <remote_tar> | pv | $ZSTD_BIN -T$ZSTD_THREADS -$ZSTD_LEVEL -c > $ARCHIVE_FILE"
  (( VERBOSE )) && log "Remote command: $remote_cmd_str"
  (( VERBOSE )) && log "Pipeline: $pipeline_desc"

  if (( DRY_RUN )); then
    log "[dry-run] Would execute: $pipeline_desc"
    return
  fi

  # pipeline: ssh (tar stdout) | pv? | zstd > file
  "$SSH_BIN" "${ssh_opts[@]}" "$REMOTE_HOST" "$remote_cmd_str" \
    | { (( USE_PV )) && has_cmd "$PV_BIN" && "$PV_BIN" || cat; } \
    | "$ZSTD_BIN" -T"$ZSTD_THREADS" -"$ZSTD_LEVEL" -c > "$ARCHIVE_FILE"

  log "Verifying archive integrity..."
  if ! "$ZSTD_BIN" -t "$ARCHIVE_FILE" 2>/dev/null; then
    die "Archive verification failed: $ARCHIVE_FILE is corrupted"
  fi

  log "Done: $ARCHIVE_FILE"
}

# Print "tree" view from tar -tf
print_tree_from_list() {
  # stdin: list of paths, one per line
  awk -F'/' '
  function rtrim_slash(s){ sub(/\/$/,"",s); return s }
  { line=$0; gsub(/^\.\//,"",line); line=rtrim_slash(line); paths[++n]=line; }
  END{
    for(i=1;i<=n;i++){
      p=paths[i]; if(p=="") continue;
      split(p, a, "/"); depth=length(a);
      parent=p; sub(/\/[^\/]+$/,"",parent); if(parent==p) parent=""
      nextp=(i<n)?paths[i+1]:""
      nextparent=nextp; sub(/\/[^\/]+$/,"",nextparent); if(nextparent==nextp) nextparent=""
      last=(parent!=nextparent)
      indent=""
      for (k=1; k<depth; k++) indent=indent "  "
      leaf=a[depth]
      isdir=match(p, /\/$/)
      printf "%s%s %s%s\n", indent, (last?"└─":"├─"), leaf, (isdir?"/":"")
    }
  }'
}

cmd_list() {
  [[ -n "$ARCHIVE_FILE" ]] || die "Need --file for list"
  [[ -f "$ARCHIVE_FILE" ]] || die "File not found: $ARCHIVE_FILE"
  log "Archive content (tree): $ARCHIVE_FILE"
  pv_file_or_cat "$ARCHIVE_FILE" \
    | "$ZSTD_BIN" -dc \
    | "$TAR_BIN" -tf - \
    | sort \
    | print_tree_from_list
}

cmd_test_restore() {
  [[ -n "$ARCHIVE_FILE" ]] || die "Need --file for test-restore"
  [[ -f "$ARCHIVE_FILE" ]] || die "File not found: $ARCHIVE_FILE"
  mkdir -p -- "$OUT_DIR"

  if (( EUID != 0 )); then
    warn "You are not root. Restoring owners/permissions may fail. Use sudo."
  fi

  local -a tflags=()
  tar_feat_flags tflags

  # Check free space
  if has_cmd df && has_cmd awk; then
    local uncompressed_size avail_kb
    uncompressed_size=$("$ZSTD_BIN" -l "$ARCHIVE_FILE" 2>/dev/null | awk 'NR==2{print $3}') || true
    if [[ -n "${uncompressed_size:-}" && "$uncompressed_size" =~ ^[0-9]+$ ]]; then
      avail_kb=$(df -k "$OUT_DIR" | awk 'NR==2{print $4}') || true
      if [[ -n "${avail_kb:-}" && "$avail_kb" =~ ^[0-9]+$ ]]; then
        local uncompressed_kb=$(( uncompressed_size / 1024 ))
        if (( uncompressed_kb > avail_kb )); then
          warn "Low disk space: archive uncompressed ~${uncompressed_kb}KB, available ~${avail_kb}KB in $OUT_DIR"
        fi
      fi
    fi
  fi

  local extract_desc="$SUDO_LOCAL $TAR_BIN -C $OUT_DIR -xpf - --numeric-owner ${tflags[*]}"
  (( VERBOSE )) && log "Extract command: $extract_desc"

  if (( DRY_RUN )); then
    log "[dry-run] Would extract $ARCHIVE_FILE into $OUT_DIR"
    return
  fi

  log "Test extraction into: $OUT_DIR"
  pv_file_or_cat "$ARCHIVE_FILE" \
    | "$ZSTD_BIN" -dc \
    | $SUDO_LOCAL "$TAR_BIN" -C "$OUT_DIR" -xpf - --numeric-owner "${tflags[@]}"
  log "Done."
}

cmd_restore() {
  [[ -n "$ARCHIVE_FILE" ]] || die "Need --file for restore"
  [[ -f "$ARCHIVE_FILE" ]] || die "File not found: $ARCHIVE_FILE"
  [[ -n "$REMOTE_HOST" ]] || die "Need --host for restore"

  local ssh_opts=()
  build_ssh_opts ssh_opts

  log "Checking tar availability on remote..."
  local check_cmd
  check_cmd="command -v $(shell_escape "$TAR_BIN") >/dev/null"
  "$SSH_BIN" "${ssh_opts[@]}" "$REMOTE_HOST" "$check_cmd" \
    || die "tar not found on remote"

  log "Creating prefix dir on remote: $RESTORE_PREFIX"
  local mkdir_cmd
  mkdir_cmd=$(shell_escape $SUDO_REMOTE mkdir -p -- "$RESTORE_PREFIX")
  "$SSH_BIN" "${ssh_opts[@]}" "$REMOTE_HOST" "$mkdir_cmd"

  local -a tflags=()
  tar_feat_flags tflags

  local -a tar_parts=()
  tar_parts+=($SUDO_REMOTE)
  tar_parts+=("$TAR_BIN" -C "$RESTORE_PREFIX" -xpf - --numeric-owner)
  (( ${#tflags[@]} )) && tar_parts+=("${tflags[@]}")
  local tar_cmd_str
  tar_cmd_str=$(shell_escape "${tar_parts[@]}")

  (( VERBOSE )) && log "Remote tar command: $tar_cmd_str"

  if (( DRY_RUN )); then
    log "[dry-run] Would restore $ARCHIVE_FILE → $REMOTE_HOST:$RESTORE_PREFIX"
    return
  fi

  log "Restoring $ARCHIVE_FILE → $REMOTE_HOST:$RESTORE_PREFIX"
  pv_file_or_cat "$ARCHIVE_FILE" \
    | "$ZSTD_BIN" -dc \
    | "$SSH_BIN" "${ssh_opts[@]}" "$REMOTE_HOST" "$tar_cmd_str"
  log "Done."
}

# ---------- dispatcher ----------
case "$MODE" in
  backup)        cmd_backup;;
  list)          cmd_list;;
  test-restore)  cmd_test_restore;;
  restore)       cmd_restore;;
  *) die "Unknown command: $MODE (see --help)";;
esac
