#!/bin/bash
# ============================================================================
#  Import a Windows MCode export into the macOS MCode runtime.
#
#    ./mac-import.sh --zip /path/to/mcode-migration-windows-YYYYMMDD-HHMMSS.zip
#
#  What it does, in order:
#    1. refuses to run while the MCode app is open (it holds the sqlite db)
#    2. unpacks the export into a staging dir
#    3. backs up the current macOS data dir (moved aside, not deleted)
#    4. installs the exported data on top of the macOS runtime
#    5. rewrites Windows absolute paths -> macOS paths inside runtime-state.sqlite
#    6. prints a verification report
#
#  Requires: python3 (system python is fine), unzip, sqlite3 (system sqlite3 is fine)
#  Note: the app must be REOPENED after this script finishes.
# ============================================================================
set -euo pipefail

DATA_DIR="${MINIMAX_DATA_DIR:-$HOME/.minimax}"
ZIP=""
ASSUME_YES=0
EXTRA_MAPS=()

usage() {
    cat <<'EOF'
Usage: mac-import.sh --zip <export.zip> [options]

  --zip <path>       Windows export produced by windows-export.ps1 (required)
  --data-dir <path>  Target data dir (default: ~/.minimax or $MINIMAX_DATA_DIR)
  --map <WIN=>MAC>   Extra path rule, repeatable.
                     Example: --map 'D:\Projects=/Users/ni0kk/Projects'
  --yes              Do not ask for confirmation
  -h, --help         This help

Example:
  ./mac-import.sh --zip ~/Downloads/mcode-migration-windows-20261022-120000.zip
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --zip)      ZIP="${2:?--zip needs a value}"; shift 2 ;;
        --data-dir) DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
        --map)      EXTRA_MAPS+=("${2:?--map needs a value}"); shift 2 ;;
        --yes|-y)   ASSUME_YES=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[ -n "$ZIP" ] || { usage; exit 1; }
[ -f "$ZIP" ] || { echo "zip not found: $ZIP" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v unzip   >/dev/null || { echo "unzip is required" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf 'OK  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*"; }

# ---------------------------------------------------------------- 1. app must be closed
say "Checking that MCode is not running..."
if pgrep -f "MiniMax Code.app" >/dev/null 2>&1; then
    echo "MCode is running. Quit it completely (Cmd+Q / menu bar -> Quit), then re-run." >&2
    exit 1
fi
ok "MCode is not running."

# ---------------------------------------------------------------- 2. stage
STAGE="$(mktemp -d -t mcode-import 2>/dev/null || true)"
if [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
    STAGE="$HOME/.mcode-import-tmp-$$"
    mkdir -p "$STAGE"
fi
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

say "Unpacking $ZIP"
python3 -c '
import zipfile, sys, os
z_path, out_dir = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(z_path, "r") as zf:
    for m in zf.infolist():
        p = m.filename.replace("\\", "/")
        parts = [x[:60] if len(x.encode("utf-8", "ignore")) > 200 else x for x in p.split("/") if x and x != ".."]
        if not parts: continue
        target = os.path.join(out_dir, *parts)
        if p.endswith("/") or m.is_dir():
            os.makedirs(target, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(m) as s, open(target, "wb") as d:
                d.write(s.read())
' "$ZIP" "$STAGE" && chmod -R u+rwX "$STAGE"
PAYLOAD="$STAGE"
if [ -d "$STAGE/mcode-migration-export" ]; then
    PAYLOAD="$STAGE/mcode-migration-export"
    info "payload root: mcode-migration-export"
fi

if [ ! -f "$PAYLOAD/export-manifest.json" ]; then
    echo "This does not look like an MCode export (no export-manifest.json)." >&2
    exit 1
fi
MANIFEST="$PAYLOAD/export-manifest.json"
ok "Export unpacked."

# ---------------------------------------------------------------- 3. what are we replacing
DB_REL="v2/sqlite/runtime-state.sqlite"
if [ ! -f "$DATA_DIR/$DB_REL" ]; then
    echo "Current macOS runtime db not found at $DATA_DIR/$DB_REL" >&2
    exit 1
fi

BACKUP="${DATA_DIR}.backup-$(date +%Y%m%d-%H%M%S)"

say "Backing up the current macOS data dir"
mv "$DATA_DIR" "$BACKUP"
mkdir -p "$DATA_DIR"
ok "backup: $BACKUP"

# ---------------------------------------------------------------- 4. install payload
say "Installing the exported data into $DATA_DIR"
# the exported tree wins for the data it contains; machine-local dirs are kept from the backup
cp -R "$PAYLOAD/." "$DATA_DIR/"

# restore machine-local pieces that belong to THIS mac
restore() {
    for rel in "$@"; do
        src="$BACKUP/$rel"
        dst="$DATA_DIR/$rel"
        if [ ! -e "$src" ]; then continue; fi
        if [ -e "$dst" ]; then continue; fi
        mkdir -p "$(dirname "$dst")"
        cp -R "$src" "$dst"
        info "kept local: $rel"
    done
}
restore auth .builtin-skills bin shims run cache \
        v2/plugin-cache v2/plugin-hook-cache v2/runtime-owner-leases \
        v2/session-handoff v2/observability v2/migration v2/workspaces

# the exported sqlite db replaces the mac one
if [ -f "$DATA_DIR/$DB_REL" ]; then ok "runtime-state.sqlite replaced"; fi

# ---------------------------------------------------------------- 5. path rewrite
say "Rewriting Windows paths inside the runtime db"
REWRITER="$HERE/rewrite_paths.py"
[ -f "$REWRITER" ] || { echo "rewrite_paths.py is missing next to this script" >&2; exit 1; }

PY_ARGS=(--db "$DATA_DIR/$DB_REL" --manifest "$MANIFEST")
for m in ${EXTRA_MAPS+"${EXTRA_MAPS[@]}"}; do
    PY_ARGS+=(--map "$m")
done
if [ "$ASSUME_YES" -eq 1 ]; then
    PY_ARGS+=(--apply)
fi
python3 "$REWRITER" "${PY_ARGS[@]}" || {
    echo "Path rewrite failed. The data is still imported; fix the paths manually and re-run." >&2
    exit 1
}

# ---------------------------------------------------------------- 6. verify
say "Verification"
DB="$DATA_DIR/$DB_REL"
if command -v sqlite3 >/dev/null; then
    q() { sqlite3 "$DB" "$1"; }
    info "sessions       : $(q 'select count(*) from local_runtime_sessions;')"
    info "projects       : $(q 'select count(*) from local_runtime_projects;')"
    info "agents (db)    : $(q 'select count(*) from agents;')"
    info "user messages  : $(q 'select count(*) from local_runtime_messages;')"
    echo
    info "projects:"
    q "select coalesce(workspace_dir,'(default project)') || '  ->  ' || (case when workspace_dir GLOB '*:*' then 'WINDOWS PATH - needs fixing' else 'ok' end) from local_runtime_projects order by workspace_dir;" | sed 's/^/      /'
    echo
    info "sample sessions:"
    q "select session_id || '  |  ' || coalesce(title,'') from local_runtime_sessions order by updated_at_ms desc limit 5;" | sed 's/^/      /'
else
    warn "sqlite3 not found - skipping the report."
fi

echo
ok "Import finished."
cat <<EOF

Next steps on this Mac:
  1. Open MCode. Sign in if asked (logins are NOT migrated - they are device bound).
  2. Check the conversation list and your custom agents / skills are there.
  3. Projects whose folder was NOT copied over will still show their old path.
     Copy those project folders to this Mac, then re-run:
         ./mac-import.sh --zip <same.zip> --map 'C:\\Users\\<you>=<here>'
     or fix them in the app UI.
  4. Scheduled tasks / IM bridges still carry Windows commands and paths.
     Review them in the app and turn them off on the OLD machine
     (otherwise Feishu/Telegram messages get handled twice).
  5. The old machine can be wiped after you have confirmed sessions + memory show up here.

Rollback: delete "$DATA_DIR" and rename the backup back:
    rm -rf "$DATA_DIR" && mv "$BACKUP" "$DATA_DIR"
EOF
