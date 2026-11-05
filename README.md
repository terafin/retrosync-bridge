# retrosync-bridge

Bidirectional save sync between [RetroSaveManager](https://github.com/joeblack2k/retrosavemanager) and a WebDAV share.

**Why:** RSM is great for desktop/console clients (MiSTer SuperStation One, Steam Deck, LaunchBox PC, Analogue Pocket) via SGM-Helper. But iPhone RetroArch only speaks WebDAV. This bridge watches both trees and copies on change, so the iPhone sees the same saves as everything else.

## How it works

- **WebDAV side**: `/webdav/<core>/<game>.srm` — RetroArch's flat layout (core directory + game-named save file)
- **RSM side**: `/rsm/<system>/<game>/save-<id>/payload.sav` — RSM's structured layout, written by the server
- A `CORE_MAP` translates RetroArch core names ↔ RSM system names (Gambatte ↔ "Nintendo Game Boy", etc.)
- **WebDAV → RSM** is an upload: the bridge POSTs the save to the server's `/saves`, which validates it, names the record and indexes it. It never writes a record into the store itself — a hand-written record is not one the server can read
- **RSM → WebDAV** copies the stored payload out, MD5-compared before copying so a restore does not echo back
- Initial sync at startup walks both trees once

## Run

```bash
docker run -d --name retrosync-bridge \
  -v /path/to/webdav/saves:/webdav \
  -v /path/to/rsm/saves:/rsm \
  -e RSM_URL=http://retrosavemanager:80 \
  --restart unless-stopped \
  ghcr.io/terafin/retrosync-bridge:latest
```

## Dry run

`DRY_RUN=1` makes one pass over the real trees and exits. It decides exactly as a live
pass does, uploads and writes nothing, and lists every upload and write it would have
made. It refuses a bad layout the same way, and fails if it read nothing, since a wrong
mount reads nothing too. Run it before starting the service on new mounts:

```bash
docker run --rm -e DRY_RUN=1 \
  -v /path/to/webdav/saves:/webdav:ro \
  -v /path/to/rsm/saves:/rsm:ro \
  ghcr.io/terafin/retrosync-bridge:latest
```

## Image

`ghcr.io/terafin/retrosync-bridge:latest` — auto-built by GitHub Actions on every push to `main`.

## Limitations (v1)

- Save states (`.state` / `.freezestate`) are NOT synced — only `.srm`/`.sav`
- CORE_MAP covers ~20 common cores; add yours via PR
- `RSM_URL` is required for the WebDAV → RSM direction; without it the bridge logs an error per file and uploads nothing
- A WebDAV save with no ROM the server knows is filed under a stable synthetic key (`bridge:<system>:<game>`), the same device-less identity the server already accepts for PlayStation and Wii saves
