# HOWTO — gdrive

Two ways to use Google Drive from Linux. Pick one — or both.

```
A. Mirror  →  keeps a full local copy, two-way, works offline
B. Mount   →  fetches files on demand, no local copy (low disk)
```

## 0. One-time setup (needed for both)

1. **Install rclone** (v1.66+, v1.75+ recommended):
   ```bash
   sudo -v && curl https://rclone.org/install.sh | sudo bash
   ```

2. **Create an OAuth remote named `gdrive`.** You need your own OAuth
   client id/secret (rclone's shared one is retired) — see the
   [Google setup](README.md#google-setup-one-time) section in README.md.
   ```bash
   rclone config
   # n) New remote
   # name> gdrive
   # Storage> drive
   # client_id>      <your client id>
   # client_secret>  <your client secret>
   # scope> 1                     # full access
   # service_account_file>        # leave blank
   # Use web browser to authenticate?> y
   # Configure as a Shared Drive?> n
   # y (keep) then q (quit)
   ```

3. **Only sync files you own** (avoids permission errors on other people's
   shared files):
   ```bash
   rclone config update gdrive auth_owner_only true
   ```

---

## A. Mirror — download everything, keep it in sync

Keeps a full copy in `~/gdrive` and syncs **both ways**; the newer file wins and
deletions propagate. Works offline. Run it from cron.

```bash
install -m 0755 gdrive-bisync.sh ~/gdrive-bisync.sh

# first run = full download (can take hours)
nohup ~/gdrive-bisync.sh >/dev/null 2>&1 &
tail -f ~/gdrive-bisync.log

# schedule it every 5 minutes
( crontab -l 2>/dev/null; \
  echo '*/5 * * * * ~/gdrive-bisync.sh >> ~/gdrive-bisync-cron.log 2>&1' \
) | crontab -
```

**Choose A if** you want a full offline copy / backup.

---

## B. Mount — stream files on demand

Presents your Drive as a local folder and fetches each file/folder only when you
open it (like Google Drive's "Stream files" mode). Nothing is stored locally
except a bounded cache.

```bash
sudo apt install -y fuse3
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

# unmount when done
fusermount3 -u ~/Drive
```

**Choose B if** you want to save disk and only access the files you need. To
keep it mounted at boot, see the systemd service in README.md.

---

## Which one?

| You want… | Use |
| --- | --- |
| a full offline copy / backup, two-way edits | **A. Mirror** |
| to save disk, access files on demand | **B. Mount** |
| both (offline copy + on-demand browsing) | run both (keep them separate) |

Full details — every flag, the systemd service, caveats and troubleshooting —
are in **[README.md](README.md)**.
