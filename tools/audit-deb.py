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
#
# 2026-11-03 重划 BUDGET_TWEAK 320 KB → 344 KB：
#   0.0.14 起 dylib 里多了一整块场景取证（AevonScene.m 的 C 垫片 + SceneProbe 的
#   census / attempt 两条路），实测 312,496 → 330,064 B，真实代码增长 17.5 KB。
#   期间试过三次压体积，都只省下百字节量级，已证明无杠杆：
#     1. 删两个已无人调用的 C 函数（AevonAnswers / AevonCreatePresenter）—— 减 112 B，
#        因为 dead_strip 早就把它们摘掉了，占体积的是符号表不是代码；
#     2. Makefile 加 -Wl,-x 剥离局部符号 —— 零收益，打包时本来就 strip；
#     3. -Osize 是唯一有效的杠杆（0.0.14 已用，省 16 KB），但不能再收。
#   所以这里放宽到 344 KB（352,256 B），给后续取证留 ~22 KB 余量；
#   一旦再超，说明是新增长而不是历史欠账，仍然要查。
#
# 2026-11-03 第二次重划 344 KB → 372 KB（380,928 B）：
#   0.0.24 新增窗口树遍历 + 场景载体匹配，实测 330,176 → 347,248 B（+17,072），
#   0.0.25 又加链式隐藏与桌面取证。成本主要在 Swift 的 KVC 键名字面量、
#   NSStringFromClass 的泛型实例化与日志拼接，-Osize 已在用，压不动。
#
# 2026-11-03 第三次改判 372 KB → 512 KB（524,288 B）—— 暂停体积闸门：
#   0.0.36 把 40pt 手势环画出来（GripMap 六个 UIView + 一条入口探针），
#   dylib 366,960 → 383,648 B，超了 2,720 B。连续三次排除法试下来，
#   「改成不覆写 draw」「删掉三行文字」「拆掉 sendEvent 探针」各自只省
#   48–112 B，说明这 16 KB 就是这段 Swift 代码本身：-Osize 下每行真实
#   代码约 200–300 B，CGRect 字面量、UIColor 调用、可选链都不便宜。
#   也就是说 372 KB 的余量其实只剩不到 14 KB，早就不是「下个功能前先
#   删旧代码」能覆盖的量级了。
#
#   操作者的判断是：先让手势能用，体积后期统一收。这是对的——体积从来
#   不是功能的前提，反过来才是。闸门因此放宽到 512 KB，它不是被取消了：
#   53 万字节仍然挡得住「链接进来一个静态库」这种量级的事故，只是不再
#   挡一个 6 视图的调试热区图。
#
#   阶段目标：手势真机确认 → 删掉 GripMap 与入口探针 → 回到 366,960 B
#   附近 → 再把这道闸门收回 372 KB。收闸门和删调试代码是同一步。
#
# 2026-11-03 第四次放宽 512 KB → 640 KB（655,360 B）—— 旧版圆盘整包移入：
#   0.0.42 按操作者的决定把 D://备份源码//Aevon 的圆盘全家 1:1 移进包
#   （AevonRingMenu + 关键帧 + 展开引擎 + 统一弹簧 + 列表存储 + 截图/录屏
#   动作），dylib 实测 404,496 → 530,688 B（+126 KB）。这一步不是「偷偷
#   长大」，是操作者点名要的功能整体进场；体积账照旧记账（见交付说明），
#   收紧的事留给「删调试件」那一轮。prefs 同理 400 → 512 KB。
BUDGET_DEB = 660 * 1024
BUDGET_TWEAK = 640 * 1024
BUDGET_PREFS = 512 * 1024

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
        items = root_dict.get("items", [])
        # 0.0.5 used PSChildPaneSpecifier and iOS refused to select the rows,
        # so "8 panels" existed on paper only. Every entry row must now be a
        # button that names an action and a panel, or the page is decorative.
        panes, broken = [], []
        for item in items:
            if item.get("cell") != "PSButtonCell":
                continue
            panel = item.get("panel")
            if not panel:
                continue
            panes.append(panel)
            if item.get("action") != "openPanel:":
                broken.append(f"{panel}: action={item.get('action')!r}")
            if f"{BUNDLE_DIR}/{panel}.plist" not in files:
                broken.append(f"{panel}: plist not packaged")
        if broken:
            bad("panes: " + "; ".join(broken))
        elif len(panes) != 8:
            bad(f"panes: {len(panes)} openable panels, expected 8")
        else:
            ok(f"panes: {len(panes)} child panes open via openPanel:, root has {len(items)} items")
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

    # 0.0.6's panel page returned early when Preferences had already filled the
    # ivar, which made all eight panels render the same rows. The log line is
    # the only thing that tells the two cases apart on a device, so its presence
    # is asserted here: a panel that silently reuses preloaded rows again would
    # also be a panel with no log line.
    # The marker is deliberately written as plain concatenation in the source:
    # an interpolated literal is not a reliable thing to grep for, and this file
    # exists to be greppable.
    if b"prefs: panel loader v1 " not in prefs:
        bad("prefs: the panel loader marker is missing from AevonPrefs — "
            "PanelController may not be compiled into the bundle")
    else:
        ok("prefs: panel loader present (marker line)")

    # -- 5b-bis. every panel must have its *own* content --------------------
    # The shipped 0.0.6 regression was eight panels showing the same handful of
    # switches. The cause (an early return before the plist was read) is fixed,
    # but a generator edit could make the plists genuinely identical, which
    # looks exactly the same on a phone. Compare their contents.
    panel_names = ["Window", "Ring", "Gesture", "Keyboard",
                   "Notify", "Jump", "Listen", "Apps"]
    signatures = {}
    for name in panel_names:
        # Deliberately NOT `blob`: that name holds the .deb itself and is used
        # by the size check at the end. Reusing it here made the report print
        # the size of the last plist (842 B) instead of the package.
        panel_blob = files.get(f"{BUNDLE_DIR}/{name}.plist")
        if panel_blob is None:
            bad(f"panels: {name}.plist missing")
            continue
        entries = plistlib.loads(panel_blob).get("items", [])
        if len(entries) < 3:
            bad(f"panels: {name} has only {len(entries)} rows")
        signatures[name] = tuple(
            (e.get("cell"), e.get("label"), e.get("key"), e.get("action"))
            for e in entries)
    clash = [a for a in signatures for b in signatures
             if a < b and signatures[a] == signatures[b]]
    if clash:
        bad(f"panels: identical body in {', '.join(clash)} — "
            "the panel plist is probably being ignored again")
    elif signatures:
        counts = [len(v) for v in signatures.values()]
        ok(f"panels: {len(signatures)} panels all different, "
           f"{min(counts)}–{max(counts)} rows each")

    # -- 5c. carrier shape (0.0.5, wired to the desktop in 0.0.6) -----------
    # The ring is the first real rendering code in this project, and its
    # regressions are all silent: a lost preview row, a lost shape switch, a
    # build that dropped the view, or a desktop host that was never mounted.
    ring_plist = files.get(f"{BUNDLE_DIR}/Ring.plist")
    if ring_plist is None:
        bad("ring: Ring.plist missing")
    else:
        ring_items = plistlib.loads(ring_plist).get("items", [])
        actions = [item.get("action") for item in ring_items]
        keys = [item.get("key") for item in ring_items]
        # 0.0.41/0.0.42 — 圆盘 only, and the disc is now the archived plugin's
        # implementation with its own fixed geometry. The shape switches, 尾角,
        # the three geometry sliders and 收藏 are all gone from the panel on
        # purpose (a control that writes a key nothing reads is a lie), so the
        # assertion is that they are *absent*: a re-added row is a regression.
        shapes = [k for k in keys if k in ("RTSIF", "RTSIH", "RTSIQ", "RTSIZ",
                                           "LastIconAngle", "Radius", "IconWidth",
                                           "RotationAngle", "Star")]
        if "@ring.star" in keys:
            bad("ring: @ring.star still in the panel — 收藏 moved into the old "
                "disc's hands (there is no pin) and the row lies")
        elif "previewRing:" not in actions:
            bad("ring: no previewRing: row — the carrier shape is unreachable")
        elif "@ring.summary" not in keys:
            bad("ring: no @ring.summary row — nothing reports the live geometry")
        elif shapes:
            bad(f"ring: {', '.join(shapes)} back in the panel — 0.0.41 is 圆盘 only")
        elif "!ring.desktop" not in keys:
            bad("ring: no !ring.desktop switch — the desktop host cannot be turned off")
        elif "editApps:" not in actions:
            bad("ring: no editApps: row — apps cannot be added, removed or sorted")
        elif "resetGrip:" not in actions:
            bad("ring: no resetGrip: row — a grip dragged off screen could not be recovered")
        elif "@ring.apps" not in keys or "@ring.grip" not in keys:
            bad("ring: the app list / grip position has no live row")
        elif "!ring.barY" not in keys:
            bad("ring: no !ring.barY slider — the summon bar's height cannot be set")
        elif "!ring.appHook" not in keys:
            bad("ring: no !ring.appHook switch — an app-side bridge that cannot be "
                "turned off is a bridge with no way back")
        else:
            bar = [i for i in ring_items if i.get("key") == "!ring.barY"]
            if not bar or bar[0].get("cell") != "PSSliderCell":
                bad("ring: !ring.barY is not a slider — a percentage needs a range")
            elif not (bar[0].get("min") == 0.0 and bar[0].get("max") == 100.0):
                bad("ring: !ring.barY range is not 0…100 — the row says percent")
            elif not bar[0].get("showValue"):
                bad("ring: !ring.barY does not show its value — 实时百分比 is the point")
            else:
                ok("ring: 旧版圆盘, live summary, preview, apps, grip reset, "
                   "bar position slider, desktop switch, app-side bridge switch")

    for token in (b"RingPreviewController", b"openPanel:",
                  b"PanelController", b"previewRing:", b"editApps:", b"resetGrip:",
                  b"AppListController", b"AppPickerController",
                  b"prefs: open app list", b"prefs: bar position 50",
                  b"AevonRingEditorCell", b"AevonRingAddCell",
                  b"_applicationIconImageForBundleIdentifier:"):
        if token not in prefs:
            bad(f"ring: {token.decode()} missing from the bundle binary")

    # -- 5d. the desktop host must actually be in the tweak ------------------
    # A local Swift function's name is stripped from a FINALPACKAGE build, so
    # assert on strings that are *content* of the host, not on symbol names:
    # the class, the private API it calls, and the line it logs on mount.
    #
    # Every log marker below is at least 16 bytes on purpose: Swift encodes
    # literals of 15 bytes or less as immediates inside the instruction stream,
    # so a short marker simply is not present in the file and this check fails
    # in CI while looking fine locally. tools/push-gate.py enforces the length.
    dylib_early = files.get("Library/MobileSubstrate/DynamicLibraries/Aevon.dylib", b"")
    for token in (b"RingHost", b"ring: hosted on desktop", b"LSApplicationWorkspace",
                  b"ring: bar position ", b"ring: expanded (",
                  b"(first run, editable in Settings)",
                  # 0.0.42 — the ported disc must be in the dylib. These tags are
                  # string literals inside the disc's own log lines / source, so
                  # FINALPACKAGE cannot strip them the way it strips type names.
                  b"AevonKeyframeHoverV320", b"AevonGifHoverV322", b"AevonRingIcon40V323",
                  b"AevonRingUnfoldV323", b"AevonQuickScreenshotV262",
                  b"AevonQuickRecordingV262", b"RingSpringDamping",
                  b"AevonRingMultiRing", b"AevonRingHoldRotateV28",
                  b"AevonRingPointerHandoffV216"):
        if token not in dylib_early:
            bad(f"host: {token.decode(errors='replace')} missing from Aevon.dylib — "
                "the ring would never appear on the home screen")
    # The app list moved from the file store to the old plugin's snapshot store
    # (UserDefaults suite + RingAppsSnapshot, V0.0.31 semantics kept verbatim).
    if b"RingAppsSnapshot" not in dylib_early:
        bad("host: RingAppsSnapshot missing from the tweak — the disc's list store "
            "did not come across with the port")
    # 0.0.44 — the grip dot is gone and so is layout.plist: the bar's height is
    # a preference, so what has to be in the dylib is the line that proves the
    # host read it.
    if b"ring: bar position " not in dylib_early:
        bad("host: the summon bar never reports its position — the slider would "
            "move a bar this file cannot prove exists")
    # 0.0.44 — the hosted mark is the half of the bridge that does not travel
    # through FrontBoard, so both sides must agree on the path or the app never
    # learns it is on screen.
    hosted_path = b"/var/mobile/Library/Logs/Aevon/hosted.plist"
    if hosted_path not in dylib_early:
        bad("host: hosted.plist path missing from the tweak — nothing would tell "
            "the card's app that it is being shown")
    if b"win: hosted mark " not in dylib_early:
        bad("host: the hosted mark is never logged — a mark nobody can see is a "
            "mark nobody can debug")
    if b"com.aevon.prefs" not in prefs:
        bad("host: settings never posts com.aevon.prefs — changes would not reach SpringBoard")
    if b"/var/mobile/Library/Logs/Aevon/ring.plist" not in prefs \
            or b"/var/mobile/Library/Logs/Aevon/ring.plist" not in dylib_early:
        bad("host: ring.plist path missing from one side — the two processes would disagree")

    # -- 5d2. the app-side bridge (0.0.44) ----------------------------------
    # A second injection point, and the first one in this project that loads
    # into every app. Two things can go wrong silently: the dylib does not ship
    # (the card goes back to being a picture you cannot touch), or it grows into
    # something that has no business sitting in 250 processes.
    bridge = files.get("Library/MobileSubstrate/DynamicLibraries/AevonApp.dylib", b"")
    if not bridge:
        bad("bridge: AevonApp.dylib missing — a hosted app would keep refusing "
            "the touches the card forwards to it")
    else:
        for token in (b"hosted scene claims foreground", b"applicationState",
                      b"activationState", b"com.apple.springboard",
                      b"/var/mobile/Library/Logs/Aevon/hosted.plist"):
            if token not in bridge:
                bad(f"bridge: {token.decode()} missing from AevonApp.dylib")
        # 96 KB, not 64: ObjC exception handling (@try around every KVC read on a
        # private key) pulls in the unwind tables and the personality routine,
        # and that is ~45 KB of the 69. Paying it once per process is the price
        # of never crashing an app over a missing key. The ceiling exists to
        # catch a *second* feature arriving in this file, not to argue with the
        # language runtime.
        if len(bridge) > 98304:
            bad(f"bridge: AevonApp.dylib is {len(bridge)} B — this file loads into "
                "every app on the phone, 96 KB is the ceiling")
        else:
            ok(f"bridge: AevonApp.dylib {len(bridge)} B, state bridge + SpringBoard guard")
    bridge_filter = files.get("Library/MobileSubstrate/DynamicLibraries/AevonApp.plist", b"")
    if b"com.apple.UIKit" not in bridge_filter:
        bad("bridge: AevonApp.plist does not filter on UIKit — no app would load the bridge")

    # -- 5e. the scene probe (0.0.6, 窗口与场景 P0) -------------------------
    # The probe is the difference between "the master's carrier API is probably
    # there" and knowing what it actually answers on this iOS. If it silently
    # falls out of either binary the next phase gets built on a guess, so its
    # rows and its markers are checked like any other shipped feature.
    window_plist = files.get(f"{BUNDLE_DIR}/Window.plist")
    if window_plist is None:
        bad("probe: Window.plist missing")
    else:
        window_items = plistlib.loads(window_plist).get("items", [])
        window_actions = [item.get("action") for item in window_items]
        window_labels = [item.get("label") for item in window_items
                         if item.get("cell") == "PSGroupCell"]
        if "sceneProbe:" not in window_actions:
            bad("probe: no sceneProbe: row on 窗口与场景 — the scene tree cannot be measured")
        elif "探针" not in window_labels:
            bad("probe: the 探针 group lost its label")
        elif "sceneSurface:" not in window_actions:
            bad("probe: no sceneSurface: row — the carrier call surface stays a guess")
        elif "sceneCalls:" not in window_actions:
            bad("probe: no sceneCalls: row — the master's calls never get resolved to a class")
        elif "sceneWindow:" not in window_actions:
            bad("probe: no sceneWindow: row — the window build has no way in")
        else:
            ok("probe: 窗口与场景 has the 探针 group and all four of its buttons")

    for token in (b"sceneProbe:", b"sceneSurface:", b"sceneCalls:", b"sceneWindow:",
                  b"prefs: scene probe requested"):
        if token not in prefs:
            bad(f"probe: {token.decode()} missing from the bundle binary")

    # 0.0.23 answers the one question 0.0.22 could not: the card was on screen
    # and was empty. Three things changed, and each one has a marker here.
    #
    # The scene is chosen six seconds after the tap, when the operator has had
    # time to switch to the app they want floated — 0.0.22 chose it while
    # Settings was in front, which is the one moment the target app is certain
    # to be in the background. The foreground question is now asked four ways
    # (two FBScene accessibility readings plus two settings spellings), and each
    # candidate is printed, because 0.0.22 asked settings alone, got -1 back
    # from both spellings, and read that silence as "no scene is in front".
    #
    # The view keeps the scene's own size and is scaled as a whole. 0.0.22 set
    # its frame to the card's 320x480, which rewrites the scene's coordinate
    # space rather than shrinking it.
    #
    # And the blank card is separated into its three possible causes by two
    # counters FBSceneLayerManager and _UISceneLayerHostContainerView already
    # declare: layers, hostedLayers, nonHostedLayers.
    #
    # Every marker below is longer than 15 bytes on purpose: Swift compiles a
    # shorter literal into an immediate inside the instruction stream, so the
    # bytes never reach the file and CI would fail on a build that works.
    # tools/push-gate.py screens for that before a push.
    #
    # Deliberately NOT asserted: `win: no presenter`, `win: no presentationView`
    # and `win: no window …` share constant prefixes, and LLVM merges shared
    # prefixes at link time; only the longest distinctive half is checked.
    for token in (b"scene: probe begin", b"scene: probe end",
                  b"scene: window level", b"scene: carrier view", b"scene: live scenes",
                  b"win: previous run died at ",
                  b"win: armed, building in 6s (switch to the target app now)",
                  b"win: no app scene in the list this run",
                  b"win: scene candidate ",
                  b"win: enumerating scenes ",
                  b" background, nothing to float",
                  b"win: no uiPresentationManager",
                  b"win: no presentationView",
                  b"win: no window - nothing activated",
                  b"win: window up level=",
                  b"win: activate ran=",
                  b"win: state hosting=",
                  b"win: view sublayers=",
                  b"win: scene layerManager layers=",
                  b"win: after 1s hosted=",
                  b"win: scale factor=",
                  # 0.0.33 — the card stays, so the eight second line is gone.
                  # What replaces it is what a card can now be told to do. 0.0.40
                  # dropped resize (both corner drags left), so move, dock and
                  # close are the three, and all three print: a card that moves
                  # without logging leaves no way to tell a drag from a jump.
                  b"win: card moved to ",
                  # 0.0.35 — the band moved outside the card, so these two strings
                  # are the proof that a gesture surface exists at all and that it
                  # is a ring rather than a band on the inside of the picture:
                  # Aevon(33) showed ninety seconds of card with the recognizers
                  # attached to a view that owns its touches.
                  b"win: grip ring band=",
                  b"win: grip touch at ",
                  # 0.0.36 — Aevon(33) and Aevon(34) both reported "the gesture
                  # does not fire" while the log proved the ring existed and was
                  # never touched once. `event hit #n` is how the next run
                  # separates "the finger never found the band" from "the touch
                  # never reached this window at all": it prints the touch as it
                  # enters, with the hitTest answer beside it. (The painted band
                  # served its purpose and left in 0.0.40.)
                  b"win: event hit #",
                  # 0.0.38 — 图标 → 悬浮窗。三条：挂起启动的门口、场景等到的时刻、
                  # 承载形状装不下时几何让步的那一行。少了第一条，「点图标没反应」
                  # 就又是一次无法分辨的报告。
                  # 0.0.39 — 位置/大小记忆与吸附、手指滑过高亮。两条各自
                  # 是「记不住」和「高亮不跟随」的唯一证据。
                  b"win: card remembered ",
                  # 0.0.42 — 高亮跟随的证据换成人：旧版圆盘自己的日志标记
                  # （指针通道交接 / 划过汇总 / 圆心旋转），全是日志字面量。
                  b"AevonRingPointerHandoffV216",
                  b"AevonRingMultiRing",
                  b"win: icon launch ",
                  b"win: icon scene up after ",
                  # 0.0.42 — 多圈几何随旧版圆盘移交：布局规则（外圈一定比内圈多、
                  # 相邻圈错开半格）在 AevonRingMenu.distribution / radii 里，
                  # 断言落在圆心旋转模式的日志标记上（日志字面量，必进二进制）。
                  b"AevonRingHoldRotateV28",
                  # 0.0.34 — the mother ship's 区域 × 动作 matrix replaced our
                  # pinch-and-drag shell. Aevon(38) cut it down to five cells:
                  # both sides move and dock on a tap, the bottom band moves and
                  # closes on a flick, the bottom corners reset on a long press,
                  # and the whole top strip answers nothing at all.
                  b"win: gesture grab zone=",
                  b"win: gesture edge-middle flick up=",
                  b"win: card reset to ",
                  # 0.0.40 — 吸附 is a tap and the way back is the window itself.
                  b"win: card docked ",
                  b"win: card undocked ",
                  # 0.0.40 — 闪黑。这一行只在系统真的动过场景的休眠状态时出现，
                  # 它是「黑一下」来自场景被收走 还是 来自合成器 的唯一分界。
                  b"win: scene deactivation #",
                  b"win: close requested by ",
                  # 0.0.27 — the mother ship's route. The two selectors are the
                  # ones her binary calls and hooks; the selftest string is the
                  # only proof in the package that the write path is exercised
                  # before SpringBoard is touched at all.
                  b"win: now swipe up to the desktop - the card follows",
                  b"win: left the app at ",
                  # 0.0.31 — the push moved off the hook and onto a main-thread
                  # keepalive clock. `force foreground door=` is gone on purpose:
                  # that line was printed from inside `_setDeactivationReasons:`
                  # and the process stopped printing anything at all seven
                  # seconds later. These two strings are the only proof in the
                  # package that the clock and its census reached the binary.
                  b"win: keepalive beat ",
                  b"win: push banned for this run",
                  # 0.0.32 — the hand-back. Aevon(30) closed the card and left
                  # the settings saying `foreground=yes`, so Douyin played on to
                  # an empty desktop. These two strings are the only proof in the
                  # package that the scene is written back and read back.
                  #
                  # 0.0.33 moved the teardown out of the timer and into a
                  # function, so the line names who closed the card instead of
                  # how long it lived.
                  b"win: card closed by ",
                  b"win: background retry door=",
                  b"hook: selftest got=%ld want=102",
                  b"_setDeactivationReasons:onScene:withSettings:reason:",
                  b"_scene:interceptUpdateWithNewSettings:",
                  b"presenter %@ -> %@",
                  b"/var/mobile/Library/Logs/Aevon/win.step"):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "the probe would never reach SpringBoard")

    # The surface dump was retired in 0.0.11 to pay for the call table. What
    # must stay in the binary is the retirement line itself: the button is still
    # on the panel, and a press that logs nothing is indistinguishable from a
    # request that never arrived.
    for token in (b"scene2: retired in 0.0.11", b"docs/REVERSE-NOTES.md"):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "a retired section that says nothing reads as a dead button")

    # The call table is the gate on building a window: if its markers or the
    # per-line prefix fall out of the stripped binary, the log comes back empty
    # and looks like 'nothing answered' instead of 'the dump never ran'.
    for token in (b"calls: definition begin v2 targets=", b"calls: defined by ",
                  b"calls: definition end v2 missing=", b"calls: scan reached "):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "the call table would come back empty and read as a negative")

    # 0.0.13 splits the call table in two: the family walk, and a name-only pass
    # over the tail it may no longer walk. Losing any of these lines silently
    # turns "nine selectors unresolved" into "nine selectors nobody asked about".
    for token in (b"calls: tail cand ", b"calls: tail owns ", b"calls: tail done names=",
                  b"calls: previous run faulted with signal ",
                  b"calls: that class lives in ",
                  b"/var/mobile/Library/Logs/Aevon/call.fault"):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "the tail pass would report nothing and look like 'no owner exists'")

    # 0.0.9: the scan that killed SpringBoard twice now carries its own witness.
    # Each of these three is load-bearing on its own —
    #   `phase1`   the first half's results, so a death in the second half is not fatal
    #   `died at`  the class named at next boot instead of "something, somewhere"
    #   `ordering` separates a death in the main-thread ordering pass from one in the walk
    for token in (b"calls: phase1 by ", b"calls: previous scan died at ",
                  b"calls: ordering walk over ", b"calls: skip list now holds "):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "a third SpringBoard death would be as blind as the first two")
    for token in (b"/var/mobile/Library/Logs/Aevon/call.state",
                  b"/var/mobile/Library/Logs/Aevon/call.skip"):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "the death marker and the skip list would silently stop working")

    # 0.0.7 crashed SpringBoard mid-scan with nothing written. The progress line
    # is what turns the next crash from "somewhere" into "class N", so its
    # absence from the binary would be a silent regression to blind guessing.
    if b"calls: scan reached " not in dylib_early:
        bad("probe: the progress line is gone — a crash would again be unattributable")

    probe_path = b"/var/mobile/Library/Logs/Aevon/probe.request"
    if probe_path not in prefs or probe_path not in dylib_early:
        bad("probe: the request path is missing from one side — Settings could ask "
            "for a dump nothing would ever answer")

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
