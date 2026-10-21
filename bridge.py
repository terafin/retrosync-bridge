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

    # Choose a save dir that holds THIS extension, newest first.
    #
    # The previous rule took the newest-mtime dir regardless of what it held, so a
    # WebDAV .srm was written into a directory whose payload was .sav — with
    # different content — overwriting it. One pass destroyed the distinct
    # component and the forward direction then propagated the damage.
    #
    # A store directory is a save *component*: payload.srm and payload.sav in one
    # dir are different files with different bytes. So a dir is only a valid
    # target if it already holds this extension, or holds no payload at all.
    existing = list(rsm_dir.glob("save-*")) if rsm_dir.exists() else []
    want = f"payload{webdav_file.suffix}"
    # Two rules, both needed:
    #
    # 1. If these exact bytes already exist under this game, there is nothing to
    #    do. After the forward direction copies a save out, the reverse sees it in
    #    WebDAV and would otherwise copy it straight back, gaining a duplicate
    #    under another save's record.
    src_hash = file_hash(webdav_file)
    for other in rsm_dir.rglob("payload.*") if rsm_dir.exists() else []:
        if other.is_file() and file_hash(other) == src_hash:
            return
    #
    # 2. A dir is a valid target only if it already holds THIS extension, or
    #    holds no payload at all. A dir holding a different component is its own
    #    record — that is what the Crystal case shows: the .rtc directory is not a
    #    place to put a .srm.
    compatible = [d for d in existing
                  if (d / want).exists() or not list(d.glob("payload.*"))]
    if compatible:
        save_dir = max(compatible, key=lambda p: p.stat().st_mtime)
    else:
        save_id = hashlib.md5(f"{system}{game}{time.time()}".encode()).hexdigest()[:12]
        save_dir = rsm_dir / f"save-{save_id}"
        save_dir.mkdir(parents=True, exist_ok=True)
        # A save dir without a record is an orphan: the forward direction selects
        # by newest metadata.json uploadedAt and falls back to dir mtime when the
        # record is absent, so a recordless dir created seconds ago outranks a
        # real save from last week and masks it. Every dir gets a record, as the
        # store's own writes do.
        slug = next((sl for sl, core_name in SLUG_TO_CORE.items()
                     if core_name == core), None)
        try:
            import json
            from datetime import datetime, timezone
            with open(save_dir / "metadata.json", "w") as fh:
                json.dump({
                    "systemPath": system,
                    "systemSlug": slug,
                    "uploadedAt": datetime.now(timezone.utc)
                                  .strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "source": "retrosync-bridge",
                }, fh)
        except OSError as e:
            print(f"[ERR] could not write metadata for {save_dir}: {e}")

    dest = save_dir / want
    if dest.exists() and file_hash(webdav_file) == file_hash(dest):
        return

    try:
        shutil.copy2(webdav_file, dest)
        print(f"[WEBDAV->RSM] {webdav_file.name} -> {system}/{game}")
    except (OSError, PermissionError) as e:
        print(f"[ERR] webdav->rsm {webdav_file}: {e}")


# Canonical identity is the server's systemSlug. Every save directory carries a
# metadata.json stating it, so the system is READ, never inferred from a display
# name. Only the WebDAV destination needs a core name, and that is the seven-row
# table below -- stable, keyed on slug, and not a naming negotiation.
SLUG_TO_CORE = {
    "snes": "Snes9x",
    "n64": "Mupen64Plus-Next",
    "gameboy": "Gambatte",
    "nes": "FCEUmm",
    "gba": "mGBA",
    "psx": "Beetle PSX HW",
    "genesis": "Genesis Plus GX",
}


def read_system_slug(payload: Path) -> str | None:
    """systemSlug from the metadata.json sitting beside the payload.

    The old CORE_MAP matched display names against folder names and missed at
    both ends: the store carries long and short folders side by side, and its
    own strings ("Sony PlayStation") do not match the records ("PlayStation").
    Reading the slug removes both failures -- 45 of 46 payloads carry a record.
    """
    meta = payload.parent / "metadata.json"
    try:
        import json
        with open(meta) as fh:
            rec = json.load(fh)
    except Exception:
        return None
    slug = rec.get("systemSlug")
    if isinstance(slug, str) and slug.strip():
        return slug.strip().lower()
    system = rec.get("system")
    if isinstance(system, dict):
        slug = system.get("slug")
        if isinstance(slug, str) and slug.strip():
            return slug.strip().lower()
    return None


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
    slug = read_system_slug(rsm_file)
    core = SLUG_TO_CORE.get(slug) if slug else None
    if not core:
        # No record beside the payload, or a slug with no known core. Fall back
        # to the old display-name map so behaviour degrades rather than breaks.
        core = next((k for k, v in CORE_MAP.items() if v == system), None)
    if not core:
        print(f"[SKIP] Unknown system: {system} (slug={slug})")
        return

    webdav_dir = WEBDAV_SAVES / core
    webdav_dir.mkdir(parents=True, exist_ok=True)
    dest = webdav_dir / f"{game}{rsm_file.suffix}"
    if dest.exists() and file_hash(rsm_file) == file_hash(dest):
        return

    try:
        shutil.copy2(rsm_file, dest)
        print(f"[RSM->WEBDAV] {system}/{game} -> {core}/{dest.name}")
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
