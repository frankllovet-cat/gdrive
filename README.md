# gdrive

Two-way Google Drive sync for Linux, built on [`rclone bisync`](https://rclone.org/bisync/).
A single shell script + cron gives you a self-hosted "Google Drive for Desktop"
experience: whichever side has the **newer** file wins, and deletions propagate
both ways.

> **In a hurry?** See **[HOWTO.md](HOWTO.md)** for the two-minute version of both
> approaches (mirror and mount). This README is the full reference.

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

## Google setup (one time)

You need your own OAuth client id/secret — rclone's shared one is being
retired. All of this happens once, in the Google Cloud Console, before you touch
rclone.

### 1. Create a project and enable the Drive API

1. Open <https://console.cloud.google.com/> and create a project (or pick an
   existing one).
2. Go to **APIs & Services → Library**, search for **Google Drive API**, open it
   and click **Enable**.

### 2. Configure the OAuth consent screen

1. Go to **APIs & Services → OAuth consent screen**.
2. **User type: External** → **Create**.
3. Fill in **App name**, **User support email** and **Developer contact
   information** (your own address is fine).
4. **Scopes:** you can skip this step — rclone requests the Drive scope at login.
5. **Test users:** add your own Google address (required while the app is in
   *Testing*).
6. **Save**.

### 3. Create the OAuth client

1. Go to **APIs & Services → Credentials**.
2. **+ Create credentials → OAuth client ID**.
3. **Application type: Desktop app**; give it any name.
4. Copy the **Client ID** and **Client secret** — you'll paste them into
   `rclone config` below.

### 4. Publish the app (recommended)

While the app is in **Testing**, Google expires the login token after **~7
days**, so you'd have to re-authenticate every week. To avoid that, publish it:

1. On **OAuth consent screen → Audience**, click **Publish app** → **Confirm**.
2. If the button is greyed out, fill in **Branding** first — an **Application
   home page** URL, an **Application privacy policy** link, and **Authorized
   domains** (any URLs you control; a free GitHub Pages site is fine) — then
   **Save** and return to **Audience**.

The app stays **unverified**: when you log in you'll see a *"Google hasn't
verified this app"* screen — click **Advanced → Go to … (unsafe)**. That's
expected and fine for personal use; verification is only needed for public apps.

---

## Setup

### 1. Install rclone

```bash
sudo -v && curl https://rclone.org/install.sh | sudo bash
rclone version    # want v1.75.x or newer
```

### 2. Create an OAuth remote in rclone

Using the **Client ID** and **Client secret** from the [Google setup](#google-setup-one-time) above:

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

## Alternative approach: mount (stream files on demand)

`rclone bisync` (above) keeps a full local copy. If you'd rather **not** store
everything locally and instead fetch files/folders only when you open them —
like Google Drive's "Stream files" mode — use `rclone mount`, which presents the
remote as a local folder backed by FUSE.

Requirements: FUSE (`fuse3` on Debian/Ubuntu → `sudo apt install fuse3`).

### Quick mount

```bash
mkdir -p ~/Drive
rclone mount gdrive: ~/Drive \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 2G \
  --vfs-cache-max-age 24h \
  --vfs-read-chunk-size 32M \
  --vfs-read-chunk-size-limit 128M \
  --dir-cache-time 1h \
  --poll-interval 0 \
  --drive-skip-gdocs \
  --daemon
```

Unmount with `fusermount3 -u ~/Drive`. To mount only a subfolder, use
`gdrive:SomeFolder` instead of `gdrive:`.

### Keep it mounted at boot (systemd `--user`)

`~/.config/systemd/user/gdrive-mount.service`:

```ini
[Unit]
Description=Mount Google Drive (rclone)
After=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p %h/Drive
ExecStart=/usr/bin/rclone mount gdrive: %h/Drive \
  --vfs-cache-mode writes --vfs-cache-max-size 2G --vfs-cache-max-age 24h \
  --vfs-read-chunk-size 32M --vfs-read-chunk-size-limit 128M \
  --dir-cache-time 1h --poll-interval 0 --drive-skip-gdocs
ExecStop=/bin/fusermount3 -u %h/Drive
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now gdrive-mount.service
loginctl enable-linger "$USER"     # start at boot without logging in
```

### Flag choices (and why)

| Flag | Default | Tuned | Why |
| ---- | ------- | ----- | --- |
| `--vfs-cache-max-size` | off (unlimited) | `2G` | cap the disk cache so it can't fill the disk |
| `--vfs-read-chunk-size-limit` | off (unlimited) | `128M` | bound readahead memory while streaming large files |
| `--vfs-read-chunk-size` | 128M | `32M` | less RAM per open file |
| `--dir-cache-time` | 5m | `1h` | fewer listing API calls, snappier navigation |
| `--poll-interval` | 1m | `0` | no background polling (saves quota/battery); folders refresh when their cache expires |
| `--vfs-cache-mode` | off | `writes` | allow open→edit→save through the mount (`off` = read-only streaming, `full` = also cache reads) |
| `--drive-skip-gdocs` | — | on | native Google Docs can't be opened via a mount; hide them instead of showing broken 0-byte files |

Leave `--drive-pacer-*` at their defaults — Drive rate-limits aggressively and
tightening the pacer just causes `403`s.

### Mount vs mirror

| | `bisync` (mirror) | `rclone mount` (stream) |
| --- | --- | --- |
| Local disk | full copy | cache only |
| When fetched | all up front | on demand |
| Offline | yes | no (except cached) |
| Good for | backup, offline | browsing, streaming, low disk |

### Caveats

- Needs network to open anything not yet cached; first open has latency.
- New remote files can take up to `--dir-cache-time` to appear. Lower it (e.g.
  `30m`) if you add files from other devices often.
- Native Google Docs/Sheets/Slides won't open (no real size) — same reason the
  mirror approach skips them.
- It's **not a backup** — deleting in the mount deletes in Drive.
- Don't mount inside the `bisync` folder (`~/gdrive`); keep the two separate.

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
