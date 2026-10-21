#!/usr/bin/env python3
"""retrosync-bridge: bidirectional save sync between RetroSaveManager and WebDAV.

WebDAV layout (RetroArch on iPhone):
    /webdav/<core>/<game>.srm

RSM layout (SGM-Helper from MiSTer/Steam Deck/LaunchBox/Pocket):
    /rsm/<system>/<game>/save-<id>/payload.sav

Both trees are watched; on write, MD5 compare + copy across.
"""
import hashlib
import os
import shutil
import time
from pathlib import Path

WEBDAV_SAVES = Path(os.environ.get("WEBDAV_SAVES", "/webdav"))
RSM_SAVES = Path(os.environ.get("RSM_SAVES", "/rsm"))

# RetroArch core name -> RSM system name
CORE_MAP = {
    # Nintendo
    "Gambatte": "Nintendo Game Boy",
    "SameBoy": "Nintendo Game Boy",
    "mGBA": "Nintendo Game Boy Advance",
    "VBA-M": "Nintendo Game Boy Advance",
    "FCEUmm": "Nintendo Entertainment System",
    "Nestopia": "Nintendo Entertainment System",
    "Mesen": "Nintendo Entertainment System",
    "Snes9x": "Nintendo Super Nintendo Entertainment System",
    "bsnes": "Nintendo Super Nintendo Entertainment System",
    "Mupen64Plus-Next": "Nintendo 64",
    "ParaLLEl N64": "Nintendo 64",
    "melonDS": "Nintendo DS",
    "DeSmuME": "Nintendo DS",
    # Sega
    "Genesis Plus GX": "Sega Genesis",
    "PicoDrive": "Sega Genesis",
    "Beetle Saturn": "Sega Saturn",
    "YabaSanshiro": "Sega Saturn",
    # Sony
    "Beetle PSX HW": "Sony PlayStation",
    "PCSX ReARMed": "Sony PlayStation",
    "SwanStation": "Sony PlayStation",
    "PPSSPP": "Sony PSP",
    # Other
    "Stella": "Atari 2600",
    "VICE x64": "Commodore 64",
}


def file_hash(path: Path) -> str:
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def webdav_to_rsm(webdav_file: Path) -> None:
    """WebDAV (iPhone) -> RSM."""
    if not webdav_file.exists():
        return
    core = webdav_file.parent.name
    system = CORE_MAP.get(core)
    if not system:
        print(f"[SKIP] Unknown core: {core}")
        return

    game = webdav_file.stem
    rsm_dir = RSM_SAVES / system / game

    # Pick the most recently MODIFIED save dir if any, else create one.
    # (Earlier versions sorted alphabetically — wrong, since save IDs are random hex.)
    existing = list(rsm_dir.glob("save-*")) if rsm_dir.exists() else []
    if existing:
        save_dir = max(existing, key=lambda p: p.stat().st_mtime)
    else:
        save_id = hashlib.md5(f"{system}{game}{time.time()}".encode()).hexdigest()[:12]
        save_dir = rsm_dir / f"save-{save_id}"
        save_dir.mkdir(parents=True, exist_ok=True)

    dest = save_dir / f"payload{webdav_file.suffix}"
    if dest.exists() and file_hash(webdav_file) == file_hash(dest):
        return

    try:
        shutil.copy2(webdav_file, dest)
        print(f"[WEBDAV->RSM] {webdav_file.name} -> {system}/{game}")
    except (OSError, PermissionError) as e:
        print(f"[ERR] webdav->rsm {webdav_file}: {e}")


def rsm_to_webdav(rsm_file: Path) -> None:
    """RSM -> WebDAV (iPhone)."""
    if not rsm_file.exists() or not rsm_file.name.startswith("payload."):
        return
    try:
        parts = rsm_file.relative_to(RSM_SAVES).parts
        if len(parts) < 4:
            return
        system, game = parts[0], parts[1]
    except ValueError:
        return

    # Reverse-map: pick first core that maps to this system. Multiple cores may map to one
    # system (Gambatte+SameBoy both -> "Nintendo Game Boy"); we just pick one for the WebDAV
    # filename. RetroArch will use whichever core file matches its game name.
    core = next((k for k, v in CORE_MAP.items() if v == system), None)
    if not core:
        print(f"[SKIP] Unknown system: {system}")
        return

    webdav_dir = WEBDAV_SAVES / core
    webdav_dir.mkdir(parents=True, exist_ok=True)
    dest = webdav_dir / f"{game}{rsm_file.suffix}"
    if dest.exists() and file_hash(rsm_file) == file_hash(dest):
        return

    # .rtc is a clock sidecar, not the save itself. Carry it alongside, but never
    # let it win over a real payload for the same game.
    if rsm_file.suffix == ".rtc" and dest.with_suffix(".srm").exists():
        return

    try:
        shutil.copy2(rsm_file, dest)
        print(f"[RSM->WEBDAV] {system}/{game} -> {core}/{game}.srm")
    except (OSError, PermissionError) as e:
        print(f"[ERR] rsm->webdav {rsm_file}: {e}")



def rsm_payloads():
    """Every RSM payload, whatever the host extension.

    The store writes payload.<ext> where ext varies by source device and system:
    srm, sav, sra, mpk, rtc, mcr. Globbing payload.sav alone matched 5 of 81
    payloads in the live store, so the RSM -> WebDAV direction saw almost nothing.
    """
    return (p for p in RSM_SAVES.rglob("payload.*")
            if "_rsm" not in p.relative_to(RSM_SAVES).parts[:1])


def newest_payload_per_game_and_ext():
    """One payload per (system, game, extension), chosen by the newest record.

    Several save dirs can exist for one game - a retried upload, or a second
    device - and keeping the extension alone does not disambiguate two payload.srm.
    Picking the first one os.walk happens to yield is not a policy, so this uses
    the same rule the server does: the newest record wins. metadata.json's
    uploadedAt is preferred; the directory mtime is the fallback for records that
    predate it.
    """
    best = {}
    for payload in rsm_payloads():
        try:
            parts = payload.relative_to(RSM_SAVES).parts
            if len(parts) < 4:
                continue
            key = (parts[0], parts[1], payload.suffix)
            stamp = record_timestamp(payload)
        except ValueError:
            continue
        if key not in best or stamp > best[key][0]:
            best[key] = (stamp, payload)
    return [p for _stamp, p in best.values()]


def record_timestamp(payload: Path) -> float:
    meta = payload.parent / "metadata.json"
    try:
        import json
        with open(meta) as fh:
            rec = json.load(fh)
        for field in ("uploadedAt", "lastSeenAt", "createdAt"):
            value = rec.get(field)
            if value:
                from datetime import datetime
                return datetime.fromisoformat(
                    value.replace("Z", "+00:00")).timestamp()
    except Exception:
        pass
    try:
        return payload.parent.stat().st_mtime
    except OSError:
        return 0.0


def initial_sync() -> None:
    print("[SYNC] Running sync pass...")
    for srm in WEBDAV_SAVES.rglob("*.srm"):
        webdav_to_rsm(srm)
    for payload in newest_payload_per_game_and_ext():
        rsm_to_webdav(payload)
    print("[SYNC] Sync pass complete")


def main() -> None:
    interval = int(os.environ.get("POLL_INTERVAL_SECS", "60"))
    print(f"retrosync-bridge starting...\n  WebDAV: {WEBDAV_SAVES}\n  RSM:    {RSM_SAVES}\n  poll:   {interval}s")

    # Polling, not inotify. Both trees are NFS mounts written by other containers
    # on other hosts, and inotify delivers no events for those writes -- the
    # observer would start cleanly, log "watching", and never fire again. The
    # trees are small (tens of files), the per-file work is an MD5 compare that
    # already skips unchanged content, so a periodic full pass is cheap and does
    # not care who wrote the file.
    print("[RUNNING] Polling for changes...")
    try:
        while True:
            try:
                initial_sync()
            except Exception as exc:  # keep the loop alive across transient NFS errors
                print(f"[ERR] sync pass failed: {exc}")
            time.sleep(interval)
    except KeyboardInterrupt:
        print("[STOP] interrupted")


if __name__ == "__main__":
    main()
