#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
audit-deb.py — 安装包闸门（CI 与本地同一份逻辑）

这是「不能变砖 / 不能偷偷变大」这两条要求里唯一可以机械验证的部分。
它把 deb 拆开逐条断言；任何一条不满足，构建失败。

检查项
  1  ar 容器与 control 字段（无 Description、架构必须是 iphoneos-arm64e）
  2  载荷白名单（只允许 Aevon 自己的文件，且不允许 var/jb 前缀）
  3  Mach-O 必须是 thin arm64e（不是 fat，也不是 arm64）
  4  Swift 实证（二进制里必须有 libswiftCore）
  5  设置入口自洽（PreferenceLoader plist ↔  bundle ↔ 面板 plist）
  6  体积预算（超过即失败，防止"再加一点点"慢慢膨胀）

用法: audit-deb.py <file.deb>
"""
import io
import os
import plistlib
import struct
import sys
import tarfile

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE

# 体积预算（字节）。不是目标值，是闸门：超过就说明有东西偷偷长大了。
BUDGET_DEB = 520 * 1024
BUDGET_TWEAK = 320 * 1024
BUDGET_PREFS = 400 * 1024

PREFIXES = (
    "Library/MobileSubstrate/DynamicLibraries/",
    "Library/PreferenceBundles/AevonPrefs.bundle/",
    "Library/PreferenceLoader/Preferences/",
)

BUNDLE_DIR = "Library/PreferenceBundles/AevonPrefs.bundle"

failures = []
notes = []


def ok(msg):
    notes.append(("PASS", msg))


def bad(msg):
    failures.append(msg)
    notes.append(("FAIL", msg))


def warn(msg):
    notes.append(("WARN", msg))


# ---------------------------------------------------------------------------
# ar / tar
# ---------------------------------------------------------------------------

def read_ar(blob):
    if blob[:8] != b"!<arch>\n":
        raise SystemExit("not an ar archive")
    members = {}
    offset = 8
    while offset + 60 <= len(blob):
        header = blob[offset:offset + 60]
        name = header[0:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        members[name] = blob[offset + 60:offset + 60 + size]
        offset += 60 + size
        if offset % 2:
            offset += 1
    return members


def read_tar(blob):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            name = member.name.lstrip("./")
            files[name] = tar.extractfile(member).read()
    return files


def macho_summary(blob):
    magic = struct.unpack_from(">I", blob, 0)[0]
    if magic == FAT_MAGIC:
        return {"fat": True}
    le = struct.unpack_from("<I", blob, 0)[0]
    if le != MH_MAGIC_64:
        return {"fat": False, "magic": hex(le), "cputype": None}
    cputype, cpusubtype = struct.unpack_from("<ii", blob, 4)
    return {"fat": False, "magic": hex(le), "cputype": cputype, "cpusubtype": cpusubtype}


# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
        print("usage: audit-deb.py <file.deb>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    blob = open(path, "rb").read()
    print(f"== audit: {os.path.basename(path)} ({len(blob):,} B) ==")

    members = read_ar(blob)
    if "debian-binary" not in members:
        bad("debian-binary missing")
    control_member = next((n for n in members if n.startswith("control.tar")), None)
    data_member = next((n for n in members if n.startswith("data.tar")), None)
    if not control_member or not data_member:
        bad("control.tar / data.tar missing")
        return report()

    control = read_tar(members[control_member])
    files = read_tar(members[data_member])

    # -- 1. control ---------------------------------------------------------
    fields = {}
    raw_control = control.get("control", b"").decode("utf-8", "replace")
    for line in raw_control.splitlines():
        if ": " in line and not line.startswith(" "):
            key, value = line.split(": ", 1)
            fields[key.strip()] = value.strip()

    for required in ("Package", "Name", "Version", "Architecture", "Depends"):
        if required not in fields:
            bad(f"control: {required} missing")

    if fields.get("Architecture") != "iphoneos-arm64e":
        bad(f"control: Architecture is {fields.get('Architecture')!r}, must be iphoneos-arm64e")
    else:
        ok("control: iphoneos-arm64e")

    if "Description" in fields:
        bad("control: Description present (Sileo would render an empty paragraph)")
    else:
        ok("control: no Description")

    if fields.get("Package") != "com.aevon":
        bad(f"control: Package is {fields.get('Package')!r}, must be com.aevon")
    else:
        ok("control: Package com.aevon")

    if "Replaces" not in fields:
        warn("control: no Replaces (upgrade from com.aevon.aevon would collide)")

    print(f"   Package   {fields.get('Package')}")
    print(f"   Version   {fields.get('Version')}")
    print(f"   Arch      {fields.get('Architecture')}")

    # -- 2. payload whitelist ----------------------------------------------
    for name in files:
        if "var/jb" in name:
            bad(f"payload: rootless prefix in {name} (this is a roothide package)")
        if not name.startswith(PREFIXES):
            bad(f"payload: unexpected path {name}")
    if not failures:
        ok(f"payload: {len(files)} files, all inside Aevon's own paths")

    # -- 3/4. Mach-O --------------------------------------------------------
    binaries = {
        "Library/MobileSubstrate/DynamicLibraries/Aevon.dylib": BUDGET_TWEAK,
        f"{BUNDLE_DIR}/AevonPrefs": BUDGET_PREFS,
    }
    for name, budget in binaries.items():
        data = files.get(name)
        if data is None:
            bad(f"payload: {name} missing")
            continue
        info = macho_summary(data)
        if info["fat"]:
            bad(f"{name}: fat binary (must be a single arm64e slice)")
            continue
        if info.get("cputype") != CPU_TYPE_ARM64:
            bad(f"{name}: not arm64 (cputype={info.get('cputype')})")
            continue
        subtype = info["cpusubtype"] & 0x00FFFFFF
        if subtype != CPU_SUBTYPE_ARM64E:
            bad(f"{name}: cpusubtype={subtype}, must be arm64e (2)")
            continue
        if b"libswiftCore" not in data:
            bad(f"{name}: no libswiftCore — this binary is not built from Swift")
            continue
        if len(data) > budget:
            bad(f"{name}: {len(data):,} B over budget {budget:,} B")
            continue
        ok(f"{name}: thin arm64e, Swift, {len(data):,} B ({len(data) * 100 // budget}% of budget)")

    # -- 5. settings registration ------------------------------------------
    entry = files.get("Library/PreferenceLoader/Preferences/Aevon.plist")
    info_plist = files.get(f"{BUNDLE_DIR}/Info.plist")
    if entry is None:
        bad("payload: PreferenceLoader entry missing (nothing would show in Settings)")
    elif info_plist is None:
        bad(f"payload: {BUNDLE_DIR}/Info.plist missing")
    else:
        entry_dict = plistlib.loads(entry).get("entry", {})
        info = plistlib.loads(info_plist)
        if entry_dict.get("bundle") != "AevonPrefs":
            bad(f"entry: bundle={entry_dict.get('bundle')!r}, must be AevonPrefs")
        if info.get("CFBundleExecutable") != entry_dict.get("bundle"):
            bad("bundle: CFBundleExecutable != entry.bundle")
        detail = entry_dict.get("detail", "")
        if not detail.endswith("RootListController"):
            bad(f"entry: detail={detail!r} is not a RootListController")
        elif f"{BUNDLE_DIR}/{info.get('CFBundleExecutable')}" not in files:
            bad("bundle: executable named in Info.plist is not in the package")
        if info.get("CFBundleShortVersionString") != fields.get("Version"):
            bad(f"bundle: CFBundleShortVersionString={info.get('CFBundleShortVersionString')!r} "
                f"!= control Version {fields.get('Version')!r}")
        if entry_dict.get("isController") is not True:
            warn("entry: isController not set (PreferenceLoader is happier with it)")
        ok(f"entry: {entry_dict.get('label')} -> {detail} (bundle {entry_dict.get('bundle')})")

    root = files.get(f"{BUNDLE_DIR}/Root.plist")
    if root is None:
        bad("payload: Root.plist missing")
        panes = []
    else:
        root_dict = plistlib.loads(root)
        panes = [item.get("file") for item in root_dict.get("items", [])
                 if item.get("cell") == "PSChildPaneSpecifier"]
        missing = [p for p in panes if f"{BUNDLE_DIR}/{p}.plist" not in files]
        items = root_dict.get("items", [])
        if missing:
            bad(f"panes: referenced but not packaged: {', '.join(missing)}")
        else:
            ok(f"panes: {len(panes)} child panes all resolve, root has {len(items)} items")
        if len(items) < 20:
            bad(f"root: only {len(items)} items — the page would render almost empty")

    # -- 5b. the controller must fill its own specifiers ivar ---------------
    # 0.0.3 overrode only the readers, PSListController never populated the
    # ivar, and Settings rendered a blank page. This string is the proof that
    # the explicit load is still there.
    prefs = files.get(f"{BUNDLE_DIR}/AevonPrefs", b"")
    if b"loadSpecifiersFromPlistName:" not in prefs:
        bad("prefs: bundle never calls loadSpecifiersFromPlistName: — "
            "the specifiers ivar stays nil and Settings shows a black page")
    else:
        ok("prefs: loads Root.plist explicitly into the specifiers ivar")

    # -- 5c. carrier shape (0.0.5) ------------------------------------------
    # The ring is the first real rendering code in this project, and its three
    # regressions are all silent: a lost preview row, a lost shape switch, or a
    # build that quietly dropped the view. Assert all three.
    ring_plist = files.get(f"{BUNDLE_DIR}/Ring.plist")
    if ring_plist is None:
        bad("ring: Ring.plist missing")
    else:
        ring_items = plistlib.loads(ring_plist).get("items", [])
        actions = [item.get("action") for item in ring_items]
        keys = [item.get("key") for item in ring_items]
        shapes = [k for k in keys if k in ("RTSIF", "RTSIH", "RTSIQ", "RTSIZ")]
        if "previewRing:" not in actions:
            bad("ring: no previewRing: row — the carrier shape is unreachable")
        elif "@ring.summary" not in keys:
            bad("ring: no @ring.summary row — nothing reports the live geometry")
        elif len(shapes) != 4:
            bad(f"ring: {len(shapes)} of 4 shape switches present")
        else:
            ok("ring: 4 shapes, live summary, preview action")

    for token in (b"RingView", b"RingPreviewController",
                  b"_applicationIconImageForBundleIdentifier:"):
        if token not in prefs:
            bad(f"ring: {token.decode()} missing from the bundle binary")

    # -- 6. log path contract ----------------------------------------------
    dylib = files.get("Library/MobileSubstrate/DynamicLibraries/Aevon.dylib", b"")
    if b"/var/mobile/Aevon.log" not in dylib:
        bad("log: /var/mobile/Aevon.log not referenced in the tweak binary")
    else:
        ok("log: /var/mobile/Aevon.log")

    # -- 7. size ------------------------------------------------------------
    if len(blob) > BUDGET_DEB:
        bad(f"size: deb {len(blob):,} B over budget {BUDGET_DEB:,} B")
    else:
        ok(f"size: deb {len(blob):,} B ({len(blob) * 100 // BUDGET_DEB}% of budget)")

    print(f"   payload   {len(files)} files, {sum(len(v) for v in files.values()):,} B")
    return report()


def report():
    print("")
    for status, msg in notes:
        print(f"  [{status}] {msg}")
    if failures:
        print("")
        print(f"AUDIT: FAIL — {len(failures)} blocking issue(s)")
        return 1
    print("")
    print("AUDIT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
