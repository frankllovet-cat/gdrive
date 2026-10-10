#!/usr/bin/env bash
#
# Two-way "newest wins" sync between Google Drive (via rclone, OAuth) and a
# local folder, using `rclone bisync`. Intended to run from cron every few
# minutes, so it behaves like a Google Drive / MEGA desktop client.
#
# Design:
# - Google Drive is the HUB. Run this on any number of machines; they all sync
#   to the same Drive, never machine-to-machine.
# - The first run builds a baseline with --resync (can take a long time).
# - Later runs propagate changes both ways. --conflict-resolve newer = the newer
#   file wins on either side, and deletions propagate too.
# - If the same file is edited on two machines before they sync, the newer wins
#   and the older is kept, renamed with a .conflict suffix.
#
# Optional environment variables:
#   REMOTE   rclone remote to sync            (default: gdrive:)
#   LOCAL    local folder to keep in sync     (default: $HOME/gdrive)
#   LOG      log file                         (default: $HOME/gdrive-bisync.log)
#
set -u

# cron runs with a minimal environment: set a sane PATH and resolve the current
# user ourselves (cron does NOT define $USER, which would abort with `set -u`).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RUNUSER="$(id -un 2>/dev/null || echo "${USER:-user}")"

REMOTE="${REMOTE:-gdrive:}"
LOCAL="${LOCAL:-$HOME/gdrive}"
LOG="${LOG:-$HOME/gdrive-bisync.log}"
MARKER="$HOME/.cache/rclone/bisync-${RUNUSER}-initialized"
LOCK="$HOME/.cache/rclone/bisync-${RUNUSER}.lock"

mkdir -p "$LOCAL" "$(dirname "$LOG")" "$(dirname "$LOCK")"

# 1. Never run two syncs at once (the first full sync can run for hours).
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Is) another sync is already running - skipping" >> "$LOG"
    exit 0
fi

# 1b. Keep the log from growing forever: if it exceeds 10 MB, rotate it.
LOG_MAX=$((10*1024*1024))   # 10 MB
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt "$LOG_MAX" ]; then
    mv -f "$LOG" "$LOG.1"   # keep the current log + one previous
    gzip -f "$LOG.1"        # compress the previous -> gdrive-bisync.log.1.gz
fi

# 2. Shared flags for every bisync run.
COMMON=( --drive-skip-gdocs
         --resilient --recover --max-lock 2m
         --conflict-resolve newer
         --create-empty-src-dirs
         -v --log-file "$LOG" )

# 3. The first ever run needs --resync to build the baseline.
echo "$(date -Is) START (pid $$)" >> "$LOG"
if [ ! -f "$MARKER" ]; then
    echo "$(date -Is) first run: initial --resync (can take a long time)" >> "$LOG"
    rclone bisync "$REMOTE" "$LOCAL" \
        --resync --resync-mode newer \
        "${COMMON[@]}"
    rc=$?
else
    rclone bisync "$REMOTE" "$LOCAL" "${COMMON[@]}"
    rc=$?
fi

# 4. Mark the pair as initialised after a successful run.
if [ "$rc" -eq 0 ]; then
    touch "$MARKER"
    echo "$(date -Is) DONE OK" >> "$LOG"
else
    echo "$(date -Is) DONE FAILED (rc=$rc)" >> "$LOG"
fi

exit "$rc"
