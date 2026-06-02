# retrosync-bridge

Bidirectional save sync between [RetroSaveManager](https://github.com/joeblack2k/retrosavemanager) and a WebDAV share.

**Why:** RSM is great for desktop/console clients (MiSTer SuperStation One, Steam Deck, LaunchBox PC, Analogue Pocket) via SGM-Helper. But iPhone RetroArch only speaks WebDAV. This bridge watches both trees and copies on change, so the iPhone sees the same saves as everything else.

## How it works

- **WebDAV side**: `/webdav/<core>/<game>.srm` — RetroArch's flat layout (core directory + game-named save file)
- **RSM side**: `/rsm/<system>/<game>/save-<id>/payload.sav` — RSM's structured layout
- A `CORE_MAP` translates RetroArch core names ↔ RSM system names (Gambatte ↔ "Nintendo Game Boy", etc.)
- [Watchdog](https://pypi.org/project/watchdog/) observers on both trees fire on `.srm`/`.sav` writes; MD5-compared before copy to avoid restore loops
- Initial sync at startup walks both trees once

## Run

```bash
docker run -d --name retrosync-bridge \
  -v /path/to/webdav/saves:/webdav \
  -v /path/to/rsm/saves:/rsm \
  --restart unless-stopped \
  ghcr.io/terafin/retrosync-bridge:latest
```

## Image

`ghcr.io/terafin/retrosync-bridge:latest` — auto-built by GitHub Actions on every push to `main`.

## Limitations (v1)

- Save states (`.state` / `.freezestate`) are NOT synced — only `.srm`/`.sav`
- CORE_MAP covers ~20 common cores; add yours via PR
- "Most recent" RSM save dir is selected by file mtime (older versions sorted alphabetically, which was wrong)
