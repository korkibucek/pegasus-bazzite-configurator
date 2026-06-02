#!/usr/bin/env python3
"""Minimal, safe reader/appender for Steam's binary ``shortcuts.vdf``.

Binary parsing in shell is unacceptably error-prone for a file whose corruption
would lose the user's non-Steam shortcuts, so this is Python (stdlib only;
``python3`` ships in the Fedora/Bazzite base). The bash wrapper
(``scripts/add-to-steam.sh``) handles discovery, backups, the Steam-running
guard, and confirmation; this module only parses, appends idempotently, and
serialises.

Binary VDF format (as used by shortcuts.vdf):
  0x00 <key\\0> <map...> 0x08      a nested map (0x08 closes it)
  0x01 <key\\0> <value\\0>         a UTF-8 string
  0x02 <key\\0> <int32-le>         a 32-bit little-endian integer
The file is one top-level map named "shortcuts" whose children are entries
keyed "0","1",... ; the stream ends with the top-level 0x08.
"""
import argparse
import binascii
import sys
from collections import OrderedDict


# --- parser -----------------------------------------------------------------
def _read_cstr(buf, i):
    end = buf.index(b"\x00", i)
    return buf[i:end].decode("utf-8", "replace"), end + 1


def _parse_map(buf, i):
    """Parse a map body starting at i; return (OrderedDict, next_index)."""
    out = OrderedDict()
    while True:
        if i >= len(buf):
            raise ValueError("unexpected end of shortcuts.vdf")
        t = buf[i]; i += 1
        if t == 0x08:               # end of this map
            return out, i
        key, i = _read_cstr(buf, i)
        if t == 0x00:               # nested map
            val, i = _parse_map(buf, i)
        elif t == 0x01:             # string
            val, i = _read_cstr(buf, i)
        elif t == 0x02:             # int32 little-endian
            val = int.from_bytes(buf[i:i + 4], "little"); i += 4
        else:
            raise ValueError("unknown VDF type byte 0x%02x at %d" % (t, i - 1))
        out[key] = val
    # not reached


def parse(buf):
    if not buf:
        # An absent/empty file is treated as an empty shortcuts map.
        return OrderedDict([("shortcuts", OrderedDict())])
    root, _ = _parse_map(buf, 0)
    if "shortcuts" not in root:
        raise ValueError("not a shortcuts.vdf (no 'shortcuts' map)")
    return root


# --- serialiser -------------------------------------------------------------
def _emit(key, val, out):
    if isinstance(val, OrderedDict) or isinstance(val, dict):
        out += b"\x00" + key.encode() + b"\x00"
        for k, v in val.items():
            _emit(k, v, out)
        out += b"\x08"
    elif isinstance(val, int):
        out += b"\x02" + key.encode() + b"\x00" + (val & 0xFFFFFFFF).to_bytes(4, "little")
    else:
        out += b"\x01" + key.encode() + b"\x00" + str(val).encode("utf-8") + b"\x00"


def serialize(root):
    out = bytearray()
    for k, v in root.items():
        _emit(k, v, out)
    out += b"\x08"          # close the implicit top-level/root map
    return bytes(out)


# --- shortcut helpers -------------------------------------------------------
def _gen_appid(exe, name):
    # Deterministic non-Steam appid (high bit set, matching Steam's convention),
    # so re-runs are stable and the idempotency check is reliable.
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return crc | 0x80000000


def _entries(root):
    return root["shortcuts"]


def has_shortcut(root, *, exe, name, flatpak):
    for entry in _entries(root).values():
        if not isinstance(entry, (dict, OrderedDict)):
            continue
        if flatpak and entry.get("FlatpakAppID") == flatpak:
            return True
        if entry.get("AppName") == name and entry.get("Exe", "").strip('"') == exe.strip('"'):
            return True
        if flatpak and flatpak in str(entry.get("LaunchOptions", "")):
            return True
    return False


def add_shortcut(root, *, name, exe, startdir, launch, flatpak=""):
    entries = _entries(root)
    appid = _gen_appid(exe, name)
    entry = OrderedDict([
        ("appid", appid),
        ("AppName", name),
        ("Exe", exe),
        ("StartDir", startdir),
        ("icon", ""),
        ("ShortcutPath", ""),
        ("LaunchOptions", launch),
        ("IsHidden", 0),
        ("AllowDesktopConfig", 1),
        ("AllowOverlay", 1),
        ("OpenVR", 0),
        ("Devkit", 0),
        ("DevkitGameID", ""),
        ("DevkitOverrideAppID", 0),
        ("LastPlayTime", 0),
        ("FlatpakAppID", flatpak),
        ("tags", OrderedDict()),
    ])
    next_index = str(len(entries))
    # Keys are numeric strings; use the max+1 to be safe if non-sequential.
    nums = [int(k) for k in entries.keys() if k.isdigit()]
    if nums:
        next_index = str(max(nums) + 1)
    entries[next_index] = entry
    return appid


# --- CLI --------------------------------------------------------------------
def cmd_add(a):
    try:
        with open(a.vdf, "rb") as f:
            root = parse(f.read())
    except FileNotFoundError:
        root = parse(b"")
    if has_shortcut(root, exe=a.exe, name=a.name, flatpak=a.flatpak):
        print("exists: a matching Pegasus shortcut is already present; no change")
        return 0
    if a.dry_run:
        print("would add shortcut: name=%r exe=%r launch=%r flatpak=%r -> %s"
              % (a.name, a.exe, a.launch, a.flatpak, a.vdf))
        return 0
    appid = add_shortcut(root, name=a.name, exe=a.exe, startdir=a.startdir,
                         launch=a.launch, flatpak=a.flatpak)
    data = serialize(root)
    # Re-parse what we are about to write as a final integrity check.
    parse(data)
    with open(a.vdf, "wb") as f:
        f.write(data)
    print("added shortcut '%s' (appid %d) to %s" % (a.name, appid, a.vdf))
    return 0


def cmd_selftest(_a):
    # Round-trip: empty -> add -> serialise -> parse -> add another -> verify.
    root = parse(b"")
    add_shortcut(root, name="Pegasus", exe='"/usr/bin/flatpak"',
                 startdir='"/home/u"', launch="run org.pegasus_frontend.Pegasus",
                 flatpak="org.pegasus_frontend.Pegasus")
    blob = serialize(root)
    root2 = parse(blob)
    assert list(_entries(root2).keys()) == ["0"], _entries(root2).keys()
    e = _entries(root2)["0"]
    assert e["AppName"] == "Pegasus", e
    assert e["Exe"] == '"/usr/bin/flatpak"', e
    assert e["LaunchOptions"] == "run org.pegasus_frontend.Pegasus", e
    assert e["IsHidden"] == 0 and e["AllowOverlay"] == 1, e
    assert e["FlatpakAppID"] == "org.pegasus_frontend.Pegasus", e
    assert isinstance(e["tags"], (dict, OrderedDict)), e
    # Idempotency: adding the same one must be detected.
    assert has_shortcut(root2, exe='"/usr/bin/flatpak"', name="Pegasus",
                        flatpak="org.pegasus_frontend.Pegasus")
    # A second, different shortcut appends at index 1 and round-trips.
    add_shortcut(root2, name="Other", exe='"/bin/x"', startdir='"/"', launch="")
    root3 = parse(serialize(root2))
    assert list(_entries(root3).keys()) == ["0", "1"], _entries(root3).keys()
    print("steam_shortcuts selftest OK")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Steam shortcuts.vdf appender")
    sub = p.add_subparsers(dest="cmd", required=True)
    pa = sub.add_parser("add")
    pa.add_argument("--vdf", required=True)
    pa.add_argument("--name", required=True)
    pa.add_argument("--exe", required=True)
    pa.add_argument("--startdir", required=True)
    pa.add_argument("--launch", default="")
    pa.add_argument("--flatpak", default="")
    pa.add_argument("--dry-run", action="store_true")
    pa.set_defaults(func=cmd_add)
    ps = sub.add_parser("selftest")
    ps.set_defaults(func=cmd_selftest)
    a = p.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
