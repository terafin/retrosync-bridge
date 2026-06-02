#!/usr/bin/env python3
"""retrosync-bridge: bidirectional save sync between RetroSaveManager and WebDAV.

WebDAV layout (RetroArch on iPhone):
    /webdav/<core>/<game>.srm

RSM layout (SGM-Helper from MiSTer/Steam Deck/LaunchBox/Pocket):
    /rsm/<system>/<game>/save-<id>/payload.sav

Both trees are watched; on write, MD5 compare + copy across.
"""
import hashlib
import shutil
import time
from pathlib import Path

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

WEBDAV_SAVES = Path("/webdav")
RSM_SAVES = Path("/rsm")

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

    dest = save_dir / "payload.sav"
    if dest.exists() and file_hash(webdav_file) == file_hash(dest):
        return

    try:
        shutil.copy2(webdav_file, dest)
        print(f"[WEBDAV->RSM] {webdav_file.name} -> {system}/{game}")
    except (OSError, PermissionError) as e:
        print(f"[ERR] webdav->rsm {webdav_file}: {e}")


def rsm_to_webdav(rsm_file: Path) -> None:
    """RSM -> WebDAV (iPhone)."""
    if not rsm_file.exists() or rsm_file.name != "payload.sav":
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
    dest = webdav_dir / f"{game}.srm"
    if dest.exists() and file_hash(rsm_file) == file_hash(dest):
        return

    try:
        shutil.copy2(rsm_file, dest)
        print(f"[RSM->WEBDAV] {system}/{game} -> {core}/{game}.srm")
    except (OSError, PermissionError) as e:
        print(f"[ERR] rsm->webdav {rsm_file}: {e}")


class WebDAVHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        if path.suffix.lower() in (".srm", ".sav"):
            time.sleep(0.5)  # debounce
            webdav_to_rsm(path)

    def on_created(self, event):
        self.on_modified(event)


class RSMHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        if path.name == "payload.sav":
            time.sleep(0.5)
            rsm_to_webdav(path)

    def on_created(self, event):
        self.on_modified(event)


def initial_sync() -> None:
    print("[INIT] Running initial sync...")
    for srm in WEBDAV_SAVES.rglob("*.srm"):
        webdav_to_rsm(srm)
    for sav in RSM_SAVES.rglob("payload.sav"):
        rsm_to_webdav(sav)
    print("[INIT] Initial sync complete")


def main() -> None:
    print(f"retrosync-bridge starting...\n  WebDAV: {WEBDAV_SAVES}\n  RSM:    {RSM_SAVES}")
    initial_sync()

    observer = Observer()
    observer.schedule(WebDAVHandler(), str(WEBDAV_SAVES), recursive=True)
    observer.schedule(RSMHandler(), str(RSM_SAVES), recursive=True)
    observer.start()

    print("[RUNNING] Watching for changes...")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()
