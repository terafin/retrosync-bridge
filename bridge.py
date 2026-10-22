#!/usr/bin/env python3
"""retrosync-bridge: bidirectional save sync between RetroSaveManager and WebDAV.

WebDAV layout (RetroArch on iPhone):
    /webdav/<core>/<game>.srm

RSM layout (SGM-Helper from MiSTer/Steam Deck/LaunchBox/Pocket):
    /rsm/<system>/<game>/save-<id>/payload.sav

Both trees are watched; on write, MD5 compare + copy across.
"""
import hashlib
import json
import os
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

WEBDAV_SAVES = Path(os.environ.get("WEBDAV_SAVES", "/webdav"))
RSM_SAVES = Path(os.environ.get("RSM_SAVES", "/rsm"))
RSM_URL = os.environ.get("RSM_URL", "").strip().rstrip("/")

# RetroArch core name -> RSM system name
CORE_MAP = {
    # Nintendo
    "Gambatte": "Nintendo Game Boy",
    "SameBoy": "Nintendo Game Boy",
    "mGBA": "Game Boy Advance",
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
    "Genesis Plus GX": "Sega Genesis-Mega Drive",
    "PicoDrive": "Sega Genesis",
    "Beetle Saturn": "Sega Saturn",
    "YabaSanshiro": "Sega Saturn",
    # Sony
    "Beetle PSX HW": "PlayStation",
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


def has_payload_with_hash(game_dir: Path, want: str) -> bool:
    """True when any payload under this game's record has these exact bytes."""
    for payload in game_dir.rglob("payload.*"):
        try:
            if payload.is_file() and file_hash(payload) == want:
                return True
        except OSError:
            continue
    return False


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

    src_hash = file_hash(webdav_file)

    # Prefer the folder the game's own record already lives in, so the reverse
    # adds to where the game is rather than to a display-name variant. Correcting
    # CORE_MAP's strings is a patch, not a fix: the store carries both names for
    # some systems, and only the record can say which one this game uses.
    #
    # The slug rule alone could not rescue the case it most needed. RetroArch
    # keeps one save in every core folder that can open the game, so an iPhone
    # with Snes9x and Gambatte holds F-Zero.srm in both. Arriving from Gambatte,
    # the slug rule looks for a record whose slug is "gameboy", finds only the
    # SNES one, and creates a second, mis-typed record beside it. So when the
    # folder-derived path would be a NEW record, identical bytes already filed
    # under any system win: same save, and the store already has the right
    # system on it. Content is the discriminator, not the name -- two genuinely
    # different F-Zero saves are still allowed to be two records.
    if not rsm_dir.exists():
        want_slug = next((sl for sl, c in SLUG_TO_CORE.items() if c == core), None)
        same_content = None
        for cand in RSM_SAVES.iterdir() if RSM_SAVES.exists() else []:
            game_dir = cand / game
            if not (cand.is_dir() and game_dir.exists()):
                continue
            sample = next(game_dir.rglob("payload.*"), None)
            if sample and want_slug and read_system_slug(sample) == want_slug:
                rsm_dir = game_dir
                break
            if same_content is None and has_payload_with_hash(game_dir, src_hash):
                same_content = game_dir
        else:
            if same_content is not None:
                rsm_dir = same_content

    # Nothing to do when these exact bytes are already filed under this game.
    # After the forward direction copies a save out, the reverse sees it in
    # WebDAV and would otherwise upload it again as a second record.
    store_payloads = [p for p in (rsm_dir.rglob("payload.*") if rsm_dir.exists() else [])
                      if p.is_file()]
    for other in store_payloads:
        if file_hash(other) == src_hash:
            return

    # Is this actually an iPhone edit, or an echo of what we copied out?
    #
    # shutil.copy2 preserves mtime, so a file the forward direction wrote
    # carries the STORE payload's timestamp. A genuine edit on the device sets
    # mtime to now. Only a strictly newer WebDAV copy is uploaded; otherwise a
    # stale WebDAV file would overwrite a newer store save on every pass.
    try:
        src_mtime = webdav_file.stat().st_mtime
        if store_payloads and src_mtime <= max(p.stat().st_mtime for p in store_payloads):
            return
    except OSError:
        pass

    # The system is READ from the record this game already has, matching the
    # folder choice above; the core name is only a fallback for a game the
    # store has never seen.
    present = next(rsm_dir.rglob("payload.*"), None) if rsm_dir.exists() else None
    slug = read_system_slug(present) if present else None
    if not slug:
        slug = next((sl for sl, core_name in SLUG_TO_CORE.items() if core_name == core), None)
    if slug is None:
        print(f"[UNMAPPED] core={core!r} system={system!r} -- add it to SLUG_TO_CORE")
        return

    upload_webdav_save(webdav_file, slug, game)


def upload_webdav_save(webdav_file: Path, system_slug: str, game: str) -> None:
    """File a WebDAV save through the server's own write path.

    The reverse direction used to write payload.<ext> and a hand-made
    metadata.json straight into the store. That record is not a record the
    server can read: the loader decodes the store's full record shape and a
    three-field stub leaves it with no id and no payload file, so the save
    stayed on disk and appeared in no listing. Rebuilding that shape here
    would be a second implementation of the server's schema, and it would have
    to be kept in step forever.

    A multipart POST to /saves goes through the same path a device does: the
    server validates the payload, names the record, and indexes it. The
    synthetic rom key is the same device-less identity the server already
    accepts for PlayStation and Wii saves -- a stable key per game, not a
    claim to know the ROM's hash.
    """
    if not RSM_URL:
        print("[ERR] RSM_URL is not set; cannot file "
              f"{webdav_file.name} (set it to the server's base URL)")
        return

    rom_sha1 = lookup_rom_sha1(game) or f"bridge:{system_slug}:{game.strip().lower()}"
    boundary = "----retrosync" + uuid.uuid4().hex
    parts = []

    def field(name: str, value: str) -> None:
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n".encode()
        )

    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
        f'filename="{webdav_file.name}"\r\nContent-Type: application/octet-stream\r\n\r\n'
        .encode()
    )
    parts.append(webdav_file.read_bytes())
    parts.append(b"\r\n")
    field("slotName", "default")
    field("system", system_slug)
    field("rom_sha1", rom_sha1)
    parts.append(f"--{boundary}--\r\n".encode())

    request = urllib.request.Request(
        f"{RSM_URL}/saves",
        data=b"".join(parts),
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "X-CSRF-Protection": "1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"[WEBDAV->RSM] {webdav_file.name} -> {system_slug}/{game} "
                  f"({response.status})")
    except urllib.error.HTTPError as exc:
        print(f"[ERR] webdav->rsm {webdav_file}: {exc.code} "
              f"{exc.read().decode(errors='replace').strip()}")
    except OSError as exc:
        print(f"[ERR] webdav->rsm {webdav_file}: {exc}")


def lookup_rom_sha1(game: str) -> str | None:
    """The server's rom hash for this game, when it knows one."""
    if not RSM_URL:
        return None
    query = urllib.parse.urlencode({"filenameStem": game})
    try:
        with urllib.request.urlopen(f"{RSM_URL}/rom/lookup?{query}", timeout=10) as response:
            body = json.load(response)
    except (OSError, ValueError):
        return None
    rom = body.get("rom") if isinstance(body, dict) else None
    sha1 = rom.get("sha1") if isinstance(rom, dict) else None
    if isinstance(sha1, str) and sha1.strip():
        return sha1.strip()
    return None


# Canonical identity is the server's systemSlug. Every save directory carries a
# metadata.json stating it, so the system is READ, never inferred from a display
# name. Only the WebDAV destination needs a core name, and that is the seven-row
# table below -- stable, keyed on slug, and not a naming negotiation.
# slug -> RetroArch core directory name.
#
# OBSERVED means the directory exists in the live WebDAV tree, so RetroArch has
# created or read it and the name is known to be right. ASSUMED means the name
# comes from the arcade's core folders and the plan, and nothing has confirmed
# the iPhone's RetroArch uses it. An assumed row that is wrong does not fail --
# it writes a save into a folder RetroArch never scans and still logs
# [RSM->WEBDAV] success. Do not let an assumed row stand unmarked.
# Systems the iPhone has no WebDAV core for. Arcade saves are per-machine MAME
# nvram, which RetroArch on iOS neither writes nor reads, so there is nothing
# to map them to. Listing them here keeps the per-pass walk quiet instead of
# printing [UNMAPPED] for every arcade record forever -- the warning still
# fires for a slug nobody has decided about, which is what it is for.
NO_WEBDAV_SYSTEMS = {"arcade"}

SLUG_TO_CORE = {
    "snes": "Snes9x",                   # observed: /webdav/saves/Snes9x
    "gameboy": "Gambatte",              # observed: /webdav/saves/Gambatte
    "nes": "FCEUmm",                    # name verified (libretro corename); iPhone core choice unverified
    "gba": "mGBA",                      # name verified (libretro corename); iPhone core choice unverified
    "psx": "Beetle PSX HW",             # name verified (libretro corename); iPhone core choice unverified
    "n64": "Mupen64Plus-Next",          # name verified (libretro corename); iPhone core choice unverified
    "genesis": "Genesis Plus GX",       # name verified (libretro corename); iPhone core choice unverified
    # Genesis Plus GX also runs Master System and Game Gear, so the three share a
    # folder. Genesis stays first: a WebDAV save the store has never seen falls back
    # to the first slug for its core, and the store record decides it for the rest.
    "master-system": "Genesis Plus GX",
    "game-gear": "Genesis Plus GX",
    "psp": "PPSSPP",                    # name verified (libretro corename); iPhone core choice unverified
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
    if slug in NO_WEBDAV_SYSTEMS:
        return
    core = SLUG_TO_CORE.get(slug) if slug else None
    if not core:
        # No record beside the payload, or a slug with no known core. Fall back
        # to the old display-name map so behaviour degrades rather than breaks.
        core = next((k for k, v in CORE_MAP.items() if v == system), None)
    if not core:
        if slug:
            # A real slug with no core mapping: a decision nobody has made yet,
            # not noise. Distinct marker and its own count so it cannot hide
            # inside the unknown-system total.
            print(f"[UNMAPPED] slug={slug!r} system={system!r} "
                  f"-- add it to SLUG_TO_CORE before trusting this platform")
        else:
            print(f"[SKIP] Unknown system: {system} (no metadata.json record)")
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
            slug = read_system_slug(payload)
            core = SLUG_TO_CORE.get(slug) if slug else None
            if not core:
                core = next((k for k, v in CORE_MAP.items() if v == parts[0]), None)
            # Key on the DESTINATION. Two store folders for one game (SNES and
            # Nintendo Super Nintendo Entertainment System) are two source keys
            # but one output file; keying on the source let both write it every
            # pass and one shadowed the other forever, by walk order.
            key = (core or parts[0], parts[1], payload.suffix)
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
        from datetime import datetime
        # Real records nest their timestamp under "summary"; reading only the
        # root silently fell through to directory mtime for most of the store.
        for holder in (rec, rec.get("summary") or {}):
            for field in ("uploadedAt", "lastSeenAt", "createdAt"):
                value = holder.get(field)
                if value:
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
