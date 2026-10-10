# gdrive

Two-way Google Drive sync for Linux, built on [`rclone bisync`](https://rclone.org/bisync/).
A single shell script + cron gives you a self-hosted "Google Drive for Desktop"
experience: whichever side has the **newer** file wins, and deletions propagate
both ways.

```
 local folder  <—— newer wins / deletions ——>  Google Drive
```

## Features

- **Two-way sync** — uploads and downloads, the newer file always wins.
- **Deletions propagate** in both directions.
- **Conflict handling** — if a file changes on both sides between runs, the
  newer version wins and the older is kept, suffixed `.conflict1`.
- **Runs from cron** every few minutes, with a lock so overlapping runs are
  skipped.
- **Self-maintaining log** — rotates at 10 MB and gzips the previous one.
- **Only syncs files you own** (see `auth_owner_only` below), so files other
  people shared with you don't cause permission errors.
- **Skips native Google Docs/Sheets/Slides** (they stay cloud-only).

## Requirements

- Linux (uses `flock`, `stat -c`, `gzip`).
- [rclone](https://rclone.org/install/) **v1.66 or newer** (`bisync` gained
  `--conflict-resolve`/`--resilient`/`--recover` around then; v1.75+ recommended).
- A Google account.

## Setup

### 1. Install rclone

```bash
sudo -v && curl https://rclone.org/install.sh | sudo bash
rclone version    # want v1.75.x or newer
```

### 2. Create an OAuth remote

rclone's shared client id is being retired, so create your own OAuth client:

1. In Google Cloud Console → APIs & Services → **Credentials**, create an
   **OAuth client ID** of type **Desktop app**. (Enable the Drive API first.)
2. If prompted, configure the OAuth consent screen; you can leave the app in
   *Testing* and add your own address under **Audience → Test users**.

Then:

```bash
rclone config
# n) New remote
# name> gdrive
# Storage> drive
# client_id>      <your client id>
# client_secret>  <your client secret>
# scope> 1                     # full access
# service_account_file>        # leave blank
# Use web browser to authenticate?> y   # log in and allow
# Configure as a Shared Drive?> n
# Then: y (keep) and q (quit)
```

If you see `Access blocked … has not completed the Google verification
process`, add your own address as a **test user** in the OAuth consent screen
(Audience) and run `rclone config reconnect gdrive:`.

> Apps left in **Testing** mode expire the login token after ~7 days. To avoid
> having to `rclone config reconnect gdrive:` weekly, publish the app (OAuth
> consent screen → Audience → **Publish app**). Unverified personal apps are
> fine — you'll just click through a warning when you log in.

### 3. Only sync files you own

```bash
rclone config update gdrive auth_owner_only true
```

Without this, `bisync` may try to delete files that other people shared with
you — which Google refuses, aborting the whole run.

### 4. Install the script

```bash
install -m 0755 gdrive-bisync.sh ~/gdrive-bisync.sh
```

Optional: instead of editing the script, override the defaults with environment
variables (see the header of the script):

```bash
REMOTE="gdrive:" LOCAL="$HOME/gdrive"
```

### 5. First run (builds the baseline)

```bash
nohup ~/gdrive-bisync.sh >/dev/null 2>&1 &
tail -f ~/gdrive-bisync.log
```

The first run downloads the entire Drive and can take a **long** time; Google
Drive rate-limits to roughly 2 files/second. You'll see `START` … `DONE OK`
when it finishes. **Do not** add `--resync` to the cron job — see below.

### 6. Schedule it

```bash
( crontab -l 2>/dev/null; \
  echo '*/5 * * * * ~/gdrive-bisync.sh >> ~/gdrive-bisync-cron.log 2>&1' \
) | crontab -
```

Done — it now keeps the folder in sync every 5 minutes.

## How it works

`bisync` remembers a listing of both sides from the previous run. Each run:

| Change since last run            | Result                                     |
| -------------------------------- | ------------------------------------------ |
| Newer on the local machine       | uploaded to Drive                          |
| Newer in Drive                   | downloaded to the machine                  |
| Deleted on one side              | deleted on the other                       |
| Changed on **both** sides        | newer wins; older kept as `…conflict1`     |

Flags used by the script:

| Flag | Why |
| ---- | --- |
| `--drive-skip-gdocs` | Native Google Docs have no real size; excluding them avoids sync churn. |
| `--resilient --recover --max-lock 2m` | Auto-recover from interruptions instead of requiring a manual `--resync`. |
| `--conflict-resolve newer` | Pick the newer file as the winner on conflicts. |
| `--create-empty-src-dirs` | Keep empty directories in sync too. |
| `--resync --resync-mode newer` | Only on the **first** run: build the baseline. |

## Important notes

- **Never put `--resync` in the cron command.** `--resync` only *copies* (it
  builds a superset of both sides), so a file deleted on one side would just be
  copied back on every run. Deletions only propagate on normal runs. The script
  adds `--resync` automatically on the first run and remembers it via a marker.
- **Google Docs/Sheets/Slides/Forms are not synced** — they remain cloud-only.
  `rclone` can't reliably round-trip them.
- **Files owned by others are ignored** thanks to `auth_owner_only`. If you do
  want shared files locally, remove that setting and make sure you have write
  permission (otherwise delete propagation will fail).
- **Running on several machines:** point them all at the same Drive. Each
  machine runs its own `bisync` (never machine-to-machine). If two machines edit
  the same file before either syncs, the newer wins and the older is kept as a
  `.conflict1` copy.
- **Logs / state:**
  - `~/gdrive-bisync.log` (rotated to `…log.1.gz` at 10 MB)
  - `~/.cache/rclone/bisync/` — per-machine baseline listings

## Troubleshooting

- `another sync is already running - skipping` — normal; a previous run is
  still going.
- `storageQuotaExceeded` — you're using a service account. Service accounts
  have no storage quota and can't write to a personal Drive; use OAuth instead.
- `insufficientFilePermissions` on delete — the file is owned by someone else.
  Set `auth_owner_only true` (see above).
- `Duplicate object found in source - ignoring` — Google Drive allows several
  files with the same name in one folder. This is harmless; clean them up with
  `rclone dedupe remote:path --dedupe-mode newest`.
- Start over: delete the state and run again —
  ```bash
  rm -rf ~/.cache/rclone/bisync ~/.cache/rclone/bisync-"$(id -un)"-initialized
  ~/gdrive-bisync.sh
  ```

## License

MIT
