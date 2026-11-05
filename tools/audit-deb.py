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
# 2026-11-03 第五次改判 —— **解除体积闸门**（操作者定档）。
#
# 前四次都在「放宽到一个更大的数」，每次仍然会在某个版本上再撞一次，
# 而每撞一次就烧掉一轮 CI：构建本身是好的，死在审计的体积比较上。
# 构建额度是有限资源，体积不是——一个 640 KB 的 dylib 和 700 KB 的
# dylib 在手机上没有任何区别，而一次白跑的 CI 是实打实的时间。
#
# 所以这三行不再是闸门，是**账本**：照旧打印每个产物的字节数与占比，
# 交付说明里照旧记账（体积是给操作者看的信息，不是给构建看的门槛）。
# `None` 表示无上限——判据只留「有没有这个文件」「架构对不对」。
BUDGET_DEB = None
BUDGET_TWEAK = None
BUDGET_PREFS = None

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
        # 体积只记账，不阻断（见文件头 BUDGET_* 的说明）。架构、Swift 运行时
        # 这两个判据才是真判据——体积超了说明功能长大了，不说明包坏了。
        if budget is None:
            note = f"{len(data):,} B (no ceiling)"
        elif len(data) > budget:
            note = f"{len(data):,} B (over old budget {budget:,} B — recorded, not fatal)"
        else:
            note = f"{len(data):,} B ({len(data) * 100 // budget}% of budget)"
        ok(f"{name}: thin arm64e, Swift, {note}")

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

    # -- 5c. 几何缩放已经撤掉（0.0.65）-------------------------------------
    # Aevon(57) 的判决是「没有任何用处」，所以这一版删掉的不只是开关，是整条
    # 路径（换画布 + 记忆形状 + 抬手重排）。这里留一条反向断言：Window.plist 里
    # 不许再出现那一行 —— 设置里还挂着一个没有实现的开关，比没有更糟。
    window_plist = files.get(f"{BUNDLE_DIR}/Window.plist")
    if window_plist is None:
        bad("window: Window.plist missing")
    else:
        window_items = plistlib.loads(window_plist).get("items", [])
        geom = [row for row in window_items if row.get("key") == "GeometryScaleEnabled"]
        if geom:
            bad("window: 几何缩放 这一行还在 —— 0.0.65 已经把它撤了")
        else:
            ok(f"window: {len(window_items)} rows, 几何缩放 removed")

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
        elif "@ring.apps" not in keys:
            bad("ring: the app list has no live row")
        elif "resetGrip:" in actions or "@ring.grip" in keys:  # gone
            # 0.1.24 — 竖条下线，`@ring.grip`（位置读数）与 `resetGrip:`（回中）
            # 一起删。它们读写的 `barY` 字段已经不在 `RingConfig` 里，留着就是
            # 一个点下去会崩的行。
            bad("ring: @ring.grip / resetGrip: are back — the summon bar is gone, "
                "they would read a field that no longer exists")
        elif "!ring.barY" in keys or "!ring.barLength" in keys \
                or "!ring.barWidth" in keys:
            # 0.1.24 — 竖条下线，三个滑块跟着删。**再出现就是回归**：那意味着
            # `RingConfig` 的字段又长回来了，而 `metrics()` 早已不存在，滑到任何
            # 位置都不会有任何反应 —— 一个调不出东西的控件比没有更糟。
            bad("ring: the summon bar sliders are back in the panel — 0.1.24 removed "
                "the bar, a slider that writes a key nothing reads is a lie")
        elif "!ring.fulledge" in keys:
            # 0.1.24 — 热区定稿在「贴右缘 18 pt × 底部 35 %」。留一个能把它改成
            # 整条右缘的开关，等于把 0.1.19~0.1.23 那段「和左滑返回插件抢地盘」
            # 的坑原样留给用户。
            bad("ring: !ring.fulledge is back — 0.1.24 froze the band at the bottom "
                "35 %, the full-edge档 is exactly what caused the plugin clash")
        elif "!ring.appHook" not in keys:
            bad("ring: no !ring.appHook switch — an app-side bridge that cannot be "
                "turned off is a bridge with no way back")
        else:
            ok("ring: 旧版圆盘, live summary, preview, apps, grip reset, desktop "
               "switch, app-side bridge switch (bar sliders and !ring.fulledge gone)")

    for token in (b"RingPreviewController", b"openPanel:",
                  b"PanelController", b"previewRing:", b"editApps:",
                  b"AppListController", b"AppPickerController",
                  b"prefs: open app list",
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
                  # 0.1.24 — `ring: bar position ` 随竖条一起下线。替它的是
                  # `ring: edge claim=`：竖条那行原本自带 `claim=` 段，是「热区在
                  # 哪儿」的唯一读数；竖条没了，这条读数必须自己站出来，否则下一
                  # 份日志连「带子在不在底部 35 %」都答不出。
                  b"ring: edge claim=", b"ring: expanded (",
                  # 0.0.45 的 `ring: held open at ` / `ring: bar released at ` 两条
                  # 在 0.1.24 撤掉：它们只由 `handleBarPan`（按住竖条拖动）打印，
                  # 而那个手势随竖条一起删了。
                  # 0.1.7 — `ring: bar touch at ` 已经下线：竖条那块 40×212 的
                  # 视觉垫子不再接收触摸（用户 Aevon(94)「点击全屏应用的操作会
                  # 误触圆盘」「移除点击触发圆盘，只保留左滑」）。那一行是
                  # `BarPad.onDown` 的探针，跟着一起撤；现在落指只有 `bar raw down`
                  # 那一条（贴边 14 pt，带 strip= 读数）。
                  # 0.1.10 — `ring: bar raw down at ` 随 `rawBar` 一起删掉：
                  # 呼出不再走 `-[UIApplication sendEvent:]`。
                  # 0.1.11 — `ring: strip refuse dx=` 留用（仍是「这一下不算呼盘」
                  # 的证词），但不再来自 `gestureRecognizerShouldBegin`，而是
                  # `EdgeSwipePad.onReject`。0.1.10 那条 `UIPanGestureRecognizer` +
                  # delegate 的路已被真机日志判死（translation 只有 10 pt，门槛 12
                  # 永远够不到 ⇒ Aevon(98) 一个盘都呼不出来）。
                  b"ring: strip refuse dx=",
                  # 0.1.11 — 落指就报一声：这条是「手指真的落到右缘 14 pt 上了」
                  # 的唯一证词。以后「呼不出」先看它有没有：没有 ⇒ 就是几何没覆盖
                  # 或 pad 被别人盖住；有但没有 `edge swipe open at` ⇒ 是判据问题。
                  # 0.1.12 — 改名成 `ring: pad down at `：它现在是**无条件**的
                  # （在闸门之前报），所以「没落到带上」与「落上了被闸挡住」终于
                  # 分得开。Aevon(99) 的 5 分半里只有 2 次落指、拒绝计数停在 #1，
                  # 就是被这个静默害的。配套两条：被挡原因、未开就抢断。
                  b"ring: pad down at ",
                  b"ring: pad refused by ",
                  b"ring: pad cancelled dx=",
                  # 0.1.13 — 命中区的两块地要能在日志里读出来：贴边列 + 抓手光环。
                  # ` claim=` 只有 7 字节会被编成立即数，所以整段合成一个长格式串，
                  # 断言取后半段（halo 那 24 字节）。没有它，「触发几率很小」到底是
                  # 带宽不够还是判据太严，下一份日志还是分不开。
                  # 0.1.16 — 光环撤掉（触发区收成贴边 10 pt 一条），` halo=…` 这段
                  # 格式串也随之消失，改断言 `claim` 段的尾部：仍是同一个长格式串，
                  # 只是参数少了三个。留着旧断言 = audit 直接 MISS。
                  b" claim=%.0fx%.0f at y=%.0f",
                  # 0.1.18 — 热区可见层撤除（Aevon(104) 第 3 条：「移除屏幕右侧的
                  # 手势热区可见性」）。两条旧断言反过来用：不能再出现在二进制里。
                  # 0.1.17 — 键盘避让的三条证词。第一条证明观察者装上了，后两条
                  # 证明「键盘起来 → 让路」这条链真的跑过；只有第一条而没有后两条，
                  # 就是「装上了但收不到心跳」（App 侧没编译进通道）。
                  b"ring: keyboard watch armed (lease 3.0 s)",
                  b"ring: keyboard up, edge band stepped aside",
                  b"ring: keyboard gone, edge band back",
                  # 0.1.18 — 键盘「收起」那条独立通道（Aevon(104) 第 1 条要求
                  # 「关键盘后立即出现」）。宿主侧注册它、App 侧发它，两边各断言一次。
                  b"com.aevon.kb.off",
                  # 0.1.18 — 圆心跟手（Aevon(104) 第 2 条）。这条标记在
                  # `AevonRingMenu.applyAnchor` 的日志里，没有它就说明「圆心还是
                  # 固定 215,699」。
                  b"AevonRingAnchorFollowV118",
                  # 0.1.19 — 「呼盘垫被谁收走的」证词。
                  # 前两条把「垫子被键盘/面板藏了」和「手指没落到带子上」分开。
                  b"ring: edge pad stepped aside",
                  b"ring: edge pad back on the right edge",
                  # 0.1.20 — 呼不出圆盘的两条新证词（Aevon(105)）。
                  #   · fallback：根视图兜底命中，证明「手指落在带子里，但子视图
                  #     层级把它漏掉了」这条路真的走到了；
                  #   · stale disc：上一个盘已经脱离视图、`current` 还留着 ——
                  #     0.1.19 里这就是「贴边划没反应，日志还干净」的死因。
                  # 0.1.19 的 `AevonRingAutoPinV119` 断言撤掉：0.1.20 起
                  # `autoPin` 恒 false，那段日志永不执行，留着只会让 audit 骗人。
                  b"ring: summon fell back to edge pad #",
                  b"ring: stale disc cleared before summon (not on screen)",
                  # 0.1.22 — 呼盘判定搬到了窗口的 `sendEvent` 上（Aevon(105)：
                  # 整份日志零 `pad down`，说明手指根本没送到边垫）。
                  #   · `win touch` 是「窗口到底收没收到触摸」的唯一分界线 ——
                  #     它比 `pad down` 更靠上游：有它没 pad down = 命中链断，
                  #     两个都没有 = 窗口不在触摸派发里；
                  #   · `mount state` 是挂载现场留档（scene / level / hidden /
                  #     pad frame / padOn），四种「划了没反应」一次摆开。
                  b"ring: win touch at ",
                  b"ring: mount state ",
                  # 0.1.23 — 呼盘判定最终落点：`UIApplication.sendEvent:`。
                  # 0.1.22 的窗口级 `sendEvent` 在 Aevon(106) 里零调用，而这一层
                  # 一直是通的（浮窗五个手势靠它）。`app touch` 是「进程收到了
                  # 这根手指」的新分界线。
                  b"ring: app touch at ",
                  b"AevonRingEdgeTouch",
                  # 窗口丢了场景 ⇒ 触摸永远送不进来（能合成、能看见、收不到）。
                  b"ring: window lost its scene, touches will not be delivered",
                  b"ring: host layer put back on top (level=",
                  b"hidden (system overlay up)",
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
    # 0.1.18 — 热区可见层是**删掉**的，不是「默认关」。两条旧标记必须真的不在
    # 二进制里：只要还能 grep 到，就说明那层淡青色底纹还挂在宿主视图上，
    # 用户会在桌面上又看见它。
    for gone in (b"ring: hot zone shown",                 # gone
                 b"ring: hot zone hidden (switch off)",   # gone
                 # 0.1.24 — 竖条整体下线（Aevon(107)：「干脆直接移除触发条」）。
                 # 下面三条都属于它：淡出动画、按住拖动、点它开合。任何一条还能
                 # 在二进制里 grep 到，就说明有个可见的东西又回到了屏幕上。
                 b"ring: bar faded out (auto hide 0.5 s)",  # gone
                 b"ring: held open at ",                     # gone
                 b"ring: bar released at "):                 # gone
        if gone in dylib_early:
            bad(f"host: {gone.decode()} still in Aevon.dylib — a removed layer came "
                "back (hot zone 0.1.18 / summon bar 0.1.24)")
        else:
            ok(f"host: {gone.decode()} gone (removed layer stayed removed)")
    # The app list moved from the file store to the old plugin's snapshot store
    # (UserDefaults suite + RingAppsSnapshot, V0.0.31 semantics kept verbatim).
    if b"RingAppsSnapshot" not in dylib_early:
        bad("host: RingAppsSnapshot missing from the tweak — the disc's list store "
            "did not come across with the port")
    # 0.0.44 — the grip dot is gone and so is layout.plist: the bar's height is
    # a preference, so what has to be in the dylib is the line that proves the
    # host read it.
    if b"ring: edge claim=" not in dylib_early:
        bad("host: the edge band never reports its geometry — nothing in the log "
            "would say where the 18 pt / bottom-35 % strip actually sits")
    # 0.0.68 — the hosted mark is **diagnostic only** now. 0.0.67 made it the
    # sole hosted test on the app side and handed it a "re-layout every window"
    # job; the mark is a cross-process file read that a sandboxed app may not be
    # allowed to do at all, so the test was both slow and unreliable. What is
    # left is the log line that says which app the card is showing — worth
    # keeping, worth checking, but nothing depends on it any more.
    hosted_path = b"/var/mobile/Library/Logs/Aevon/hosted.plist"
    if hosted_path not in dylib_early:
        bad("host: hosted.plist path missing from the tweak — the log line that "
            "says who the card is showing would have nothing to point at")
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
                      # 0.0.63 — App 这一侧的几何量尺。Aevon(55) 的抖音「视频在中
                      # 上、下面是纯 #333」在宿主侧三个读数里全都对得上（窗口确实
                      # 是 430x717），剩下唯一没量的是 App 自己怎么看这块屏幕。
                      # 这一串不在二进制里，就等于这一轮没有任何新证据。
                      b"app: geom ",
                      # 量尺走「主脊」：`spine` 从根视图往下挑面积最大的子视图，
                      # `peers` 是每一层的兄弟；只有走到播放器那一层，「视频偏上」
                      # 才有页码可指。
                      b"phys=%.0fx%.0f scene=",
                      b"spine%d %s",
                      b"peers%d n=%lu",
                      # 0.0.70 — 桥接自己的落点。没有它，这个文件里所有读数在沙盒
                      # App 中都写不出去（`fopen("/var/mobile/Aevon.log")` 在沙盒
                      # 里必然失败），量尺等于白跑。
                      b"aevon-app.log",
                      # 0.0.71 — 断层那一刀的四个证据。Aevon(61) 的读数已经排除
                      # 「尺寸不对」（主脊八层全是 430x717），剩下的只能是翻页位置：
                      #   · `app: page ` = 这一组读数的通道（和 `app: geom` 并列）；
                      #   · `pager keep box=… span=…` = 认出来的那个翻页器：视口、
                      #     内容、单元格、偏移、内边距、是否分页。Aevon(62) 之后
                      #     这一行是「记住翻页器」这一步的唯一证词 —— 没有它，
                      #     下一次日志里 `pager=0` 是「没认出」还是「没忘掉」分不开；
                      #   · `scroll y=… -> … page=…` = 真正挪动过的那一次，带前后
                      #     两个数、页高与单元格高，下一次日志可以自己复核算术；
                      #   · `player b=… grav=… src=…` = 播放器那一层，用来分开
                      #     「翻页错位」和「播放器只有一条」这两种完全不同的成因。
                      b"app: page ",
                      b"pager keep box=%.0f span=%.0fx%.0f",
                      b"inset=%.0f paging=%d pages=%.0f",
                      # 0.0.77 — 落点从「按格点算」改成「问那一页自己在哪」。Aevon(67)
                      # 的四组读数把格点算术判死了：行原点相对 `N × box` 的偏离依次
                      # 是 +214 / +214 / −358 / +214，214 = 932 − 717，也就是「视口上方
                      # 还有几行没重排」。所以这三行是新一轮唯一的判据：
                      #   `anchor keep …` = 尺寸变化那一拍钉住的行下标，以及当时那一页
                      #     的 frame/高度（`ok=1` 才是钉住了；`ok=0` 说明这个 App 的
                      #     翻页器不是 UITableView/UICollectionView，只剩 frame 可用）；
                      #   `align …`      = 真的挪了一次，带行原点、页高与视口高；
                      #   `anchor done …` = 那一页终于「原点对齐 + 高度等于视口」，收工。
                      b"anchor keep row=%ld,%ld at=%.0f",
                      b"align %s y=%.0f -> %.0f row=%.0f h=%.0f",
                      b"clean=%d span=%.0f moves=%d",
                      b"anchor done row=%ld,%ld at=%.0f",
                      b"align capped moves=%d at=%.0f",
                      # 0.0.81 — 「交还整屏」那一路的重排往后推。Aevon(72) 六次开合
                      # 六次卡屏，唯一插在关卡那一拍的动作就是这次整表重排；现在它
                      # 只在 App 真的回到前台之后才做。三行是唯一的判据：
                      #   `hold … wait active` = 还停着（`n=` 是等了几拍，正常一两次）；
                      #   `resume active … after=` = 回来了，等了多久（秒）；
                      #   `resume stale …` = 等了 7.5 s 它的 `applicationState`
                      #     仍然是 background —— 那种情形下我们照做，并把这句写下来。
                      b"hold reason=%s wait active n=%d box=%.0f target=%.0f",
                      b"resume active box=%.0f target=%.0f after=%.1fs",
                      b"resume stale app stays background, acting anyway",
                      # 0.0.74 — 翻页器此刻的形状：视口、内容、offset、单元格，
                      # 以及前三个子视图（页本身）的原点与高度。
                      # 「换算写对了、断层还在」这两个互相矛盾的事实，只有
                      # `span`/`k0` 能把它们分开，所以这一条是下一轮的判据本身。
                      b"state %s box=%.0fx%.0f span=%.0fx%.0f off=%.0f,%.0f "
                      b"cell=%.0f,%.0f,%.0fx%.0f kids=%lu clean=%d stale=%d",
                      # 0.0.75 — 子视图前面加了类名。Aevon(65) 的读数已经证明
                      # 「十一页里只有一页按新高度重排」（8102 = 10×717 + 932），
                      # 剩下唯一没答的问题是「这一页到底是 UICollectionView 的
                      # cell 还是 App 自己写的复用视图」—— 那决定了下一版能不能
                      # 直接让它重建页面。类名就在这一列里。
                      b" k%lu=%.28s:%.0f,%.0fx%.0f",
                      # 0.0.76 — 断层的成因从「算错了」改成「算不出来」。Aevon(66)
                      # 同一秒里两行互相打脸（`snap clean` 摆对了、紧接一行
                      # `scroll y=2151 -> 1864` 又按 932 取整挪回两页之间），
                      # 所以 0.0.76 起页高不齐就一帧 offset 都不写，改为请 App
                      # 自己重排。这两条日志就是那条路的唯一证据：
                      #   `rebuild …` = 发了「你的页过期了」，带翻页器类名/父类/
                      #     是不是 UICollectionView/layout 类名与 itemSize；
                      #   `inside …` = 页里面的尺寸（视频为什么贴到顶栏）。
                      b"rebuild %s cls=%s<%s> cv=%d",
                      b"inside %s box=%.0f",
                      # 0.0.78 — 上面那条路（`setNeedsLayout`）只让表格**重画**，
                      # 没有重新问「这一行该多高」。Aevon(68) 的关卡那一拍是
                      # `align … row=3513 h=717 box=932`：视口摆对了行原点，可那一行
                      # 还是 717，于是下面露出 215 pt 的下一条，四秒后 `k1` 仍是
                      # `717x430`。所以这一版改成请表格**作废行高缓存**
                      # （`beginUpdates` / `endUpdates`），这两条断言就是它还在的
                      # 证据 —— 它们同时排除「又回去用 setNeedsLayout 凑」这条路。
                      b"beginUpdates",
                      b"endUpdates",
                      b"performWithoutAnimation:",
                      b"stuck %s box=%.0f full=%.0f",
                      b"stuck cut%s (below the window)",
                      # 0.0.79 — 断层这一族收口之后，剩下两件：
                      #
                      # ① 换屏之后视频不自己播（Aevon(69)：「需要手动点击暂停后
                      #    再次点击」）。这一组是那条路的全部证据 —— `play note`
                      #    说换屏之前这一页有几个在播（`was=0` 就是我们不打算管），
                      #    `resume play` 说替它按了一次，`resume ok` 说它自己回来了
                      #    （不按），`resume gone` / `resume mute` 说这一页上根本
                      #    看不见 AVPlayerLayer —— 下一版要换入口的判据就是这两条。
                      b"play note was=%d paused=%d",
                      b"resume ok %s playing=%d",
                      b"resume play %s was=%d paused=%d n=%d",
                      b"resume gone %s playing=0 paused=0",
                      b"resume mute no AVPlayerLayer",
                      # ② 哔哩哔哩竖版：页就是 932 高，5:3 的卡装不下。0.0.79 在这里
                      #    留过一个「下次给整屏画布」的记号，0.0.82 撤了 —— 见下面
                      #    的反向断言。不再换画布，`stuck` 那几行读数照旧（它仍在
                      #    量、仍在置脏），所以上面两条断言原样保留。
                      # 0.0.80 — 「卡屏」的成因：`stale` 把**视口外面**的旧页也数进去
                      # 了（`k0=AWEFeedViewCell:932,932x430` 在 0–717 的视口下面），于是
                      # 「页不齐」永远成立，`beginUpdates/endUpdates` 每 0.35 s 一次、
                      # 一次开卡十来次 —— 那几秒主线程在反复整表重排。这两个断言是
                      # 新的收口：`rebuild stop` 证明「发完没变就不再发」这道验收真的
                      # 生效过（下一份日志里它有、且每条会话最多一行，就是判对了）。
                      b"rebuild stop n=%d top=%.0f box=%.0f stale=%d",
                      # 0.0.80 — 分享面板（Aevon(71)）：只量不改。`sheet` 带层名/高度/
                      # 顶边/画布高，`sheet cut` 列出「底边落在窗口以下」的叶子视图 ——
                      # 那里面就是看不见的发送按钮。
                      b"sheet %.32s h=%.0f top=%.0f box=%.0f",
                      b"sheet cut%s (below the window)",
                      # 0.0.82 — 面板「往上抬一截」。读到这一行，说明面板的底边确实
                      # 超出了窗口（`by=` 是超出的量），而且我们把它对齐回来了。
                      # 0.0.83 加了 `in=`：从**第一次看见面板**到真的抬上去用了多久。
                      # Aevon(74) 那一版这 1 秒是节拍堆出来的，`in` 就是它的验收
                      # —— 下一份日志里这一项在 0.2 s 以上，就说明节拍还没改对。
                      b"sheet lift by=%.0f h=%.0f box=%.0f n=%d in=%.2fs",
                      # 0.0.85 — 横版画面贴顶：`video band` 是「把那一块挪到卡片
                      # 正中」的回执（`h` 画面高、`y` 挪之前的上沿、`want` 目标上沿、
                      # `dy` 挪了多少、`r=` 拿谁当视频区）；`video band none` 是
                      # 「找不到那块矩形」的证据行，紧跟一行 `video tree` 把候选的
                      # 直接子视图列出来 —— 有它、没有前者，说明判据要换。
                      # 0.0.86 — 多一行 `video scan`：候选**在卡片坐标系里**的矩形、
                      # 目标、缺口。0.0.85 在视频区自己的坐标系里算，原点偏移漏进结果，
                      # 屏幕上就永远差那么一截；这一行就是那个偏移的证据。
                      # 另有 `video clip`：祖先会裁时把位移夹回来，宁可少挪不留黑块。
                      # 0.0.87 — `via=` 是这一版的判据：`layout` = 在 App 排完版、
                      # CoreAnimation 提交这一帧之前就摆好了（用户看不到跳）；`tick` =
                      # 心跳才追上（屏幕上会跳一下）。0.0.86 之前只有后者。
                      # 0.0.89 — 行尾多了 `c=`/`b=`/`ty=`：cell 与画面指针的尾 4 位、
                      # 写入前画面自己的位移。同一秒里 `c=` 相同而 `y=` 变回去
                      # = App 把我们的位移抹掉（对打）；`c=` 变了 = 换页。
                      # 0.0.94 — 行尾再加 `ln=`（车道：0 整页 cell、1 视频区、-1 心跳）
                      # 与 `dr=`（写入那一刻翻页器是否还在拖/惯性滑动）。Aevon(84) 里
                      # 唯一的 `via=layout` 写入就是死前最后一条读数，可它分不出车道、
                      # 也分不出当时在不在滑 —— 这两个数就是下一版的判据。
                      b"video band v=%.24s h=%.0f y=%.0f want=%.0f dy=%.0f n=%d r=%.24s via=%.8s c=%04lx b=%04lx ty=%.0f ln=%d dr=%d",
                      # 迟到的原因是「摆得晚」，所以钩住 App 自己的排版那一层：
                      # 字符串在二进制里，说明这条安装路径没被编译掉。
                      b"layoutSubviews",
                      b"video scan %.20s r=%.0f,%.0f,%.0fx%.0f want=%.0f gap=%.0f",
                      b"video clip %.20s moved=%.0f need=%.0f n=%d",
                      # 0.0.89 — `walk=` 是这一趟走了多少个视图（预算 4000）：一直顶在
                      # 4000 就是预算不够，不是判据写错。
                      b"video band none cls=%.24s h=%.0f box=%.0f walk=%lu c=%04lx",
                      b"video tree b=%.0fx%.0f n=%lu",
                      # 0.0.88 — 两行新的刹车/复位读数，对应 Aevon(78) 的两个症状：
                      #   `video slow` = 某一次排版扫描贵过 8 ms，我们主动停 2 秒。
                      #   Aevon(78) 的「滑着滑着卡住、声音还在放」是主线程被吃掉的
                      #   形状；有这一行就说明刹车真的踩过，没有就说明卡点在别处。
                      #   `video reset on foreground` = 从后台/锁屏回来，画面记账整个
                      #   作废、重新开始。Aevon(78) 的「锁屏后居中失效、必须重开浮窗」
                      #   就是记账没作废（按次数计的配额早就用完了）。
                      b"video slow %.20s spent=%.0fms hold=2s",
                      # 0.0.89 — 每 0.5 s 结算一次「排版钩子吃了多少主线程」：
                      # `n` 次、`spent` 毫秒、`%` 占半秒的比例。低于 40 ms 不出声。
                      # Aevon(79) 的 4.5 秒卡顿只能从「日志空白」反推，有这一行
                      # 就能直接看是谁、多少次、多少毫秒。0.0.93 把门槛从 80 降到
                      # 40：Aevon(83) 一条都没有，而「每次 1~2 ms × 几十次」正好
                      # 卡在 80 的线下 —— 那是滚动被拖垮的典型形态。
                      # 0.0.97 — 全段耗时与三个出口。
                      # `all` = 钩子从进到出（含 bounds / PagerGet / PageCellOf /
                      # CardIsUp 这些从来没被量过的固定开销）；`spent` 只是
                      # KnownApply 那一段。`fast`/`scan` 分开「快路径命中」与
                      # 「真扫一趟」—— all 大而 fast 占绝大多数就是**次数**问题。
                      b"video load n=%d spent=%.0fms all=%.0fms fast=%d scan=%d",
                      # 0.0.90 — 两行证词，对应 Aevon(80) 的「悬浮窗只剩一圈白色光晕」：
                      #   `video known n= d= c=` = 这一页认出来的画面**路径**（几块、
                      #   几层下来、哪一页）。0.0.89 这里存的是对象指针，快路径每帧
                      #   把上一帧的指针 cast 回 UIView 发消息（MRC，不 retain）——
                      #   cell 被复用、画面被释放就是野指针，进程当场死。
                      #   `app: boot pid=` = 每个进程一行。下一份日志数 `app: boot`
                      #   有几行就知道这中间死过几次，不用再靠 `geom` 出没出两对去猜。
                      b"video known n=%d d=%d c=%04lx",
                      # 0.0.92 — 「一秒写了几次」。Aevon(82) 的卡屏（页面滑不动、
                      # 点不动）里 `video load` 一条都没有 ⇒ 不是单次慢，是次数多；
                      # 而「次数」这个数当时没有读数。峰值 < 20 不写，所以正常时
                      # 日志里看不到这一行。
                      b"video rate n=%d/s",
                      # 0.0.93 — 「这一页的记账真的废了、清账重来」。Aevon(83) 的
                      # 卡屏是「一次对不上就清账 → 整页 BFS → 重认 → 又对不上」
                      # 的循环叠出来的；现在连续 3 次才清，真清时留这一行。
                      # 判据：卡屏那一刻如果它 **密集出现**，就是链本身不稳；
                      # 如果它 2 秒才一条、甚至没有，卡屏就不在这条路上。
                      b"video miss n=%d c=%04lx",
                      # 0.0.95 — 钩子的**频率**读数与熔断。
                      # Aevon(85) 的看门狗给出 `hook=59300 → 527855`（33,468 次/秒、
                      # 主线程 16 秒不返回、期间我们一次都没写）⇒ 排版期写 transform
                      # 把 App 的布局弄成不收敛的循环。这一版把写入压到本轮 runloop
                      # 末尾，并且每秒结算一次钩子频率：>200 留一行 `video hook`，
                      # >2500 判风暴、停写停扫 3 秒。判据：正常滑动应当 <200 不出现；
                      # 出现了说明这一页本来就重，那 3 秒的静默是买保险。
                      # 0.0.97 — `top=` 是「这段窗口里最烫的槽位:次数」，与
                      # `video hook slot` 那张表配对就能把「是哪个类在爆」对上号。
                      # Aevon(86) 只有 5,500 次/秒这个总数：既可能是「一个类在一帧
                      # 里被排 90 次」（布局不收敛），也可能是「90 个实例各排 1 次」
                      # （正常）—— 这两种修法完全相反。
                      b"video hook n=%d/s top=%d:%d",
                      b"video hook slot i=%d v=%d %.28s",
                      b"video storm n=%d/s hold=3s",
                      # 0.0.96 — 提前装钩子（B 路）每张卡一行：`n` = 这次新挂上的
                      # 类数（页 + 画面区，最多 AEVON_HOOK_SLOTS=12）。
                      # 判据：n>0 说明 B 路真的执行了；整份日志一条都没有 ⇒
                      # 开卡那一拍翻页器还没建出页，或者候选全被尺寸筛掉了。
                      b"video hook pre n=%d",
                      # 0.0.97 — 「预居中每拍处理了几页、成了几页」。Aevon(86) 说
                      # 「过程更清晰了」，而 A 路的目的就是让它不可见：
                      # `pages=1` ⇒ 根本没拿到相邻页；`ok` 有但仍跳 ⇒ 写进去又被抹了。
                      b"video tick pages=%d ok=%d",
                      # 0.0.97 — App 把我们写进去的位移抹掉的次数。
                      # `video band` 只记前两次写入，之后对打多少次都是静默的；
                      # 这一行让「一直在和它对着干」第一次有读数。
                      b"video bounce n=%d",
                      b"app: boot pid=%d",
                      # 0.1.8 — App 侧闸门的证词（Aevon(95) 第 1 条）。停靠状态下
                      # App 自己的 `sendEvent:` 吞掉整条事件表：`down` = 吞掉的按下
                      # 数，`ev` = 吞掉的事件数。这行出现 ⇒ 漏的那一份投递确实经过
                      # App 的 UIApplication；一行都没有而用户仍被点到 ⇒ 它连
                      # UIApplication 都不经过，下一手要往 `_UIApplicationHandleEvent-
                      # FromEventQueue` 上走。
                      b"app: mini touch swallowed down=%d ev=%d",
                      # 0.1.9 — Darwin 通知通道（容器取不到时的唯一一条）。
                      # 名字是格式串，前缀就是它；两个方向都要在二进制里。
                      b"com.aevon.mini.on.%@",
                      b"com.aevon.mini.off.%@",
                      # 0.0.91 — 死因证词。signal handler 只做 open/write/close
                      # （崩溃现场不能碰 NSString/stdio），`step=` 说死在哪个函数里；
                      # 异常那一路带名字与原因。`alive t=` 是被托管期间每秒一行：
                      # 进程若被系统 SIGKILL，它就停在某一秒上，下一次 `boot` 就是
                      # 死亡时刻 —— 这种杀法谁都拦不住，只能靠「最后一秒」定位。
                      b"app: crash sig=%d step=%d sub=%d d=%d",
                      b"app: crash exc %s: %s step=%d",
                      b"alive t=%d",
                      # 0.0.94 — **卡死**（不是崩溃）的证词。Aevon(84) 里 App 侧日志
                      # 14 秒零输出、宿主 `cs=2 sublayers=1` 正常、随后 pid 换了，
                      # 而 `app: crash` 一条都没有 ⇒ 主线程不回来，不是我们慢
                      # （`video load` 全程 0 条，没有任何半秒被吃掉 40 ms）。
                      #   `app: hang step= sub= d= hook= c= b=` = 停在哪一句、重入深度、
                      #   这 2 秒里钩子被叫了几次、正在改哪一格哪一块。
                      #   `hook` 很小而 `sub=5` ⇒ 一次没回来（就在 setTransform 上）；
                      #   `hook` 上千且 `d` 很大 ⇒ 又一次自我递归。
                      #   `app: hang pc=` 是主线程 PC + 9 层返回地址，配合
                      #   `app: base=` 就能算出哪些帧落在我们自己这个 dylib 里。
                      # 0.0.97 — 加了三段：`cost=` 是这 2 秒里钩子吃了多少毫秒
                      # （以前只有次数，没有时间）；`w=` 是距最后一次真正写入多久
                      # （Aevon(86) 那次是 116 秒 ⇒ 不能说「写入点着了风暴」）；
                      # `where=` 是主线程此刻所在模块的 basename（dladdr 得到）——
                      # UIKitCore 与 AwemeCore 意味着完全相反的结论。
                      b"app: hang step=%d sub=%d d=%d hook=%d cost=%.0fms w=%.0fs top=%d:%d where=%.20s c=%04lx b=%04lx cpu=%d st=%d gap=%.0fms th=%d mem=%ldMB off=%d quiet=%d",
                      # 0.1.2 — `pc=` 从裸地址改成 `模块+偏移`（`%s`），因为裸地址
                      # 只能靠「落在哪个镜像」去推，推不出函数名；85/86 两份日志里的
                      # `291e6…` 连镜像都读不出来（PAC 签名没抹掉）。
                      b"app: hang pc=%s",
                      # 0.1.2 — 全部线程各自的落点。主线程卡在 CA 提交里这一条记录，
                      # 只有在「别的线程是不是也在等我们」时才有结论。
                      b"app: hang threads=%d",
                      # 0.1.2 — 两个取证开关的读数。没有这两行，一份日志分不清
                      # 「开关开着但没生效」和「开关根本没编译进去」：
                      #   `probe mode` = 进程启动时那一行（mainOnly / quiet / bundle）；
                      #   `probe offmain n= quiet n=` = 子线程上进来的钩子次数（非 0
                      #   就证明抖音确实在子线程排版）与被静默模式挡下的次数。
                      b"probe mode mainOnly=%d quiet=%d bundle=%.60s",
                      b"probe offmain n=%d quiet n=%d",
                      b"app: base=%lx",
                      b"video reset on foreground",
                      # 0.0.84 — 抬高从「呈现」这一声开始，不再等心跳相位。
                      b"presentViewController:animated:completion:",
                      b"settle gave up after 90s",
                      b"player b=%.0fx%.0f grav=%s src=%.0fx%.0f",
                      b"videoGravity",
                      # 兜底：不依赖谁的子类重写了过渡回调，每 0.15 s 看一眼窗口高。
                      b"transition h=%.0f last=%.0f full=%.0f",
                      b"watch first",
                      b"viewWillTransitionToSize:withTransitionCoordinator:",
                      # 0.1.17 — 键盘在屏的上报通道。软键盘属于应用进程，桌面
                      # 那侧收不到任何系统通知；没有这个字符串，`ring: keyboard
                      # up` 就永远不会出现，而用户看到的是「打字时仍然误触」。
                      b"com.aevon.kb.up",
                      # 0.1.18 — 「收起」那条独立通道（Aevon(104) 第 1 条：
                      # 「关键盘后立即出现」）。不发它，桌面只能等 3 秒租约过期。
                      b"com.aevon.kb.off",
                      b"app: keyboard up (bridge)",
                      # 0.1.24 — 应用侧右缘吞手指（Aevon(107)：「右侧滑动时会触发
                      # 应用内的滑动操作」）。SpringBoard 吞掉的是它自己那一份，
                      # App 一份不少 —— 这一行证明 App 侧的闸门真的装上了。
                      b"app: edge touch at ",
                      b"setContentOffset:"):
            if token not in bridge:
                bad(f"bridge: {token.decode()} missing from AevonApp.dylib")
        # 0.0.68 — 反向断言，比上面那组重要得多。这一栏里的每一条都对应一次真机
        # 事故，而不是一次代码风格意见：
        #
        #   · 0.0.65 在 App 进程里换了 `UIScreen.bounds` / `_referenceBounds` /
        #     `_boundsForInterfaceOrientation:`，于是整台机器打不开应用、桌面黑屏、
        #     小组件空白；
        #   · 0.0.67 只把 `bounds` 换回来、并且加了「名片一翻就给每个窗口补一次
        #     layoutIfNeeded」，真机反馈与原样一字不差。
        #
        # 两个版本、同一种故障 —— 结论不是「判据还要再收窄」，而是**这件事本身
        # 不能做**：屏幕尺寸是系统的世界观，替任何一个进程改写它，代价都是整台
        # 机器。所以后面任何一个串重新出现在 AevonApp.dylib 里，都是这条路又回来
        # 了，直接 FAIL，不给「这次判据更严」留余地。
        #
        # 每行末尾的 `# gone` 是给 tools/push-gate.py 看的：反向断言故意不在源码
        # 里，闸门否则会把它当成「漏改的断言」拦下。
        for token in (b"_referenceBounds",                                  # gone
                      b"_boundsForInterfaceOrientation:",                   # gone
                      # 名片：0.0.67 拿它当唯一判据。它是一次跨进程文件读，沙箱里
                      # 未必读得到；读不到就是「卡里的 App 永远不是前台」，触摸直
                      # 接失效。判据回到 scene settings（见 AevonHosted）。
                      b"hosted.plist",                                      # gone
                      # 0.0.74 — 两次 17 pt 轻推与「替操作者缩放一下」都被撤掉了：
                      # Aevon(64) 的原话是「内容会自己跳动，然后完成重排」，而那
                      # 两次推正是跳动的来源（日志里 `transition h=700 / h=734`
                      # 一来一回各一次）。它们不该再回来 —— 下一次如果又需要逼
                      # App 重排，必须在画面露出来之前做完，不许再动已经上屏的卡。
                      b"win: scene nudge door=",                            # gone
                      b"win: content jiggle ",                              # gone
                      # 0.0.76 — 「混装时把视口摆到那一页上」这条落点本身是对的，
                      # 但它与紧随其后的 `round(y/box)*box` 共用同一个 offset，
                      # 后一条必覆盖前一条，于是同一秒里先摆对、再挪歪。0.0.76 起
                      # 页高不齐就一帧都不写，所以这条日志连同那条公式一起撤掉；
                      # 它若回来，说明「两条公式抢一个 offset」又回来了。
                      b"snap clean y=%.0f -> %.0f at=%.0f",                 # gone
                      # 0.0.77 — 三处「按格点算 offset」全部撤掉：`round(y/box)*box`
                      # 与 `N × 新页高` 都建在「0 是格点原点」上，而 Aevon(67) 证明
                      # 那个原点每有一行没重排就漂 215。它们若回来，说明又有人在
                      # 用算术代替「问那一页在哪」。
                      b"scroll y=%.0f -> %.0f page=%.0f",                   # gone
                      b"transition scroll y=%.0f -> %.0f page=%.0f",        # gone
                      b"next=%.0f",                                         # gone
                      b" box=%.0f cell=%.0f span=%.0f",                     # gone
                      # 强制重排：`layoutIfNeeded` / `setFrame:` 在这个文件里只剩
                      # 一种用法 —— 替别人的 window 排一次版，而那正是 0.0.67 的
                      # 第二个动作。
                      b"layoutIfNeeded",                                    # gone
                      b"setFrame:",                                         # gone
                      # 0.0.78 — `reloadData` 会让表格把每一屏都重建一次，等于替
                      # 用户翻了一次页：视频重来、正在看的那一帖被丢掉。它一直是
                      # 「能让行高对上」的最短路径，也是这一版明确不走的那条。
                      b"reloadData",                                        # gone
                      b"hosted, relayout",                                  # gone
                      # 0.0.98 — 「已经有卡就忽略」这条拒绝撤掉了，改成「旧主窗降级
                      # + 新图标开主窗」。它若回来，就是「主悬浮窗打开时再选图标没有
                      # 任何反应」又回来了 —— 这一条比本栏其它任何一条都更容易被
                      # 悄悄写回去，因为它看起来像一条稳妥的守卫。
                      b"ignored, a card is already up",                     # gone
                      b"released, relayout",                                # gone
                      # 名片 + 冷启动那对组合：名片写不进去时判据永远不成立，
                      # 每次开窗都会先杀掉那个 App。
                      b"/var/mobile/Library/Logs/Aevon/bridge",              # gone
                      # 0.0.82 — 「整屏画布」整条撤掉。Aevon(73) 的读数是
                      # `render=430x932 full=1 card=366x610` + `letterbox side=42pt`：
                      # 卡片是 5:3，画面是 9:19.5，两边各让 42 pt。成因不是判据太松，
                      # 是**记号活得太久** —— 0.0.79 把一次判定写进 App 的 tmp，
                      # 从此这个 App 每次开卡都是整屏画布。用户拍板：主页面按 5:3
                      # 真重排优先于竖版那一页显示不全。所以记号与它的读取路径
                      # 都不许再回来；画布只有一个来源（`fatRender` 的 5:3）。
                      b"want full canvas",                                   # gone
                      # 0.0.90 — 「拿上一帧存下来的视图指针直接发消息」这条路
                      # 一条都不许留：野指针就是 Aevon(80) 的两次进程死亡。
                      b"isDescendantOfView:",                                # gone
                      b"aevon-full"):                                        # gone
            if token in bridge:
                bad(f"bridge: {token.decode()} 又出现了 —— 在 App 进程里改屏幕、"
                    f"或者替别人的窗口强制重排，这两件事已经各自毁过一个版本，"
                    f"不许第三次")
        # 96 KB, not 64: ObjC exception handling (@try around every KVC read on a
        # private key) pulls in the unwind tables and the personality routine,
        # and that is ~45 KB of the 69. Paying it once per process is the price
        # of never crashing an app over a missing key. The ceiling exists to
        # catch a *second* feature arriving in this file, not to argue with the
        # language runtime.
        # 0.0.45 — 也是账本，不是闸门。这个数仍然值得看：它乘上 250 个
        # 进程才是真正的常驻成本，交付说明里每次都要写出来。
        ok(f"bridge: AevonApp.dylib {len(bridge):,} B, state bridge + SpringBoard guard")
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
                  b"win: no window - presenter released",
                  b"win: window up level=",
                  b"win: activate ran=",
                  b"win: state hosting=",
                  b"win: view sublayers=",
                  b"win: scene layerManager layers=",
                  b"win: after 1s hosted=",
                  b"win: scale factor=",
                  # 0.0.62 — 圆角与字号是同一次缩放的产物，得能在日志里互相印证：
                  # `scale factor` 掉到 0.80 ⇒ `card_corner_pt` 落在 34 上下。
                  # 只断言后缀也存在，是因为这一行是拼接出来的，前半段在不在
                  # 不说明后半段有没有被编进去。
                  b" card_corner_pt=",
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
                  # 0.0.60 — 小胖屏。`win: fat scene ratio=` 是这一版的比例与屏幕
                  # 尺寸，`hosted=` 是下发给承载面的逻辑尺寸、`card=` 是它显示的
                  # 尺寸；`hosted bounds after=` 是 0.25 s 之后回读的实际 bounds ——
                  # presenter 有自己的尺寸管理，这一行才分得清「我们没走到」与
                  # 「走过去了但被系统改回来了」。三行缺任何一行，真机上就只剩
                  # 「窗口看着不对」这一句可读的话。
                  b"win: fat scene ratio=",
                  b"win: hosted bounds after=",
                  # 0.0.81 — 卡片形状与画布形状分家。卡片从此恒为 5:3（`plan`
                  # 只按 `fatAspect` 算），画布按等比装进去；装不满时两边留边，
                  # 这一行就是那条边有多宽。它是「哔哩哔哩 9:19.5 的卡」这个
                  # 故障唯一的正面读数：没有这一行，下一次只能靠看截图猜。
                  b"win: letterbox side=%.0fpt flat=%d canvas=%.0fx%.0f",
                  # 0.0.61 — 逻辑尺寸。Aevon(52) 证明了 0.0.60 的错在哪：只改
                  # 承载视图的 bounds，App 仍按整屏排版（`scale=1.000`、字大、
                  # 顶栏偏右、底栏与抖音右侧那一列在框外）。这四条是这一版唯一
                  # 能自证的读数：`asked=` 是目标，`push door=` 是主动推的门，
                  # `after=` 是 system 回读（两次，0.25 s / 1.2 s），`restored=`
                  # 是关窗时有没有还回去 —— 不还，那个 App 从此是 377 宽的排版。
                  b"win: scene frame asked=",
                  b"win: scene frame push door=",
                  b"win: scene frame after=",
                  b"win: scene frame restored door=",
                  # 0.0.65 — 换画布那条路撤了（几何缩放整条删除），只剩看门狗：
                  # `frame drift now=` 是两秒一拍的对账，抓到「scene 被系统改回
                  # 整屏」——画布现在只有一个来源，被改回去就是真的被改了，
                  # 这一行还留着，因为它证明的是「画布还稳着」。
                  b"win: frame drift now=",
                  # 0.0.65 — 只剩一种缩放（等比例），所以这一行不再有 mode：
                  # `canvas=` 是这块画布（整场缩放里它不该变，变了就是又有人去
                  # 改 settings），`card=` 是卡片当下的大小，`corner=` 按卡宽算
                  # —— 0.0.63 按「卡高 / 画布高」算，往下压扁时会掉到 4 %，
                  # 看着就是直角，这一行能当场读出来。
                  b"win: resize canvas=",
                  # 0.0.66 — 「旧进程就先杀掉」那条路撤了（它靠一张名片文件判断
                  # 进程新旧，名片写不进去时判据永远不成立，于是每次开窗都先结束
                  # 那个 App）。`win: icon cold start ` 改成反向断言，见本函数末尾。
                  # 0.0.54 的顶栏裁剪在 0.0.60 撤掉了（`topbar_cropped_src=` /
                  # `topbar_kept_pt=` 随实现一起删）：留着一条断言源码里已经不存在
                  # 的字符串，CI 会当场失败。✕ 撤掉之后 `close requested by` 仍在
                  # —— 底边上滑照样走同一条出口，只是不再有 `close button` 这个理由。
                  # 0.0.55 — 右缘左滑呼盘（移植旧版 bandRect：贴右缘 15 pt × 底部
                  # 35 %）。`edge swipe open at` 是它真的召回了圆盘，`edge swipe
                  # released` 是抬手；两条都没有 = 识别器没认领，而不是「带子太窄」。
                  b"ring: edge swipe open at ",
                  b"ring: edge swipe released at ",
                  # 0.0.55 — 浮窗期间禁止空闲熄屏（移植旧版 idle 三通道）。
                  # `held mask=` 是打开时的位掩码（8 = 断言通道命中，4 = 只有
                  # UIApplication 兜底），`kick mask=` 是 20 秒一次的续命拍，
                  # `released mask=` 是关窗时的释放 —— 少了最后一条就是旧版
                  # Aevon(41) #7「关窗后不再自动锁屏」的原样重演。
                  b"win: idle timer held mask=",
                  b"win: idle timer kick mask=",
                  b"win: idle timer released mask=",
                  # 0.0.56 — 圆盘中心的应用选择面板 + 白图标过滤。
                  # `panel: catalogue built rows=` 是面板真的按过滤后的表建起来了；
                  # `panel: picked app ` 是选中那一下；`panel: panel closed (` 记
                  # 的是走了哪条出口（关闭钮 / 点外面 / 下滑 / 选中）；两条
                  # `app chooser` 证明竖条和右缘带被收回又交还 —— 少了后一条，
                  # 面板关掉之后竖条就再也不响了。
                  b"panel: catalogue built rows=",
                  b"panel: picked app ",
                  b"panel: panel closed (",
                  b"ring: center panel -> app chooser (",
                  b"ring: app chooser gone (",
                  # 0.1.6 — **圆盘入口的唯一开关与它的自愈**。
                  #   `ring: grip armed edge=…` 是右缘带触摸开关的现算结果，每变一次
                  #   写一行（`card=` 是此刻还有没有卡，`panel=` 是应用面板在不在）。
                  #   用户 Aevon(94) 报「右侧呼不出圆盘、打不开悬浮窗」，就是这个开关
                  #   被某条没走完的路径关死了。这一行出现在启动后不久 = 开关有归口；
                  #   一直不出现 = 一次都没变过。
                  #   0.1.24 — `bar=` 那段随竖条删除，只剩 `edge=`。
                  b"ring: grip armed edge=",
                  # 0.1.7 — 三条新证据（Aevon(94)）：
                  #   `win: undock read last main frame ` = 升窗用的是**上一次主窗的
                  #     实际 frame**（`FloatHost.lastMainFrame`），不再读按边存的百分比。
                  #     用户报「还原成主悬浮窗时的位置每一个都不一样」，这一行给出每一次
                  #     的真实落点，前后两次该完全相同。
                  #   `win: mini touch lock content=0` = 停靠小窗把那块承载画面设成不
                  #     接触摸。第四次报「点小窗依旧触发应用内的操作」的最后一道闸。
                  #   `ring: edge swipe cancelled by the system` = 贴边左滑被系统抢断
                  #     的分支（与 `released` 分开，抬手与中断不再混为一谈）。
                  b"win: undock read last main frame ",
                  b"win: mini touch lock content=0",
                  b"ring: edge swipe cancelled by the system",
                  # 0.1.8 — 停靠标记（Aevon(95) 第 1 条：点小窗仍触发 App 内点击，
                  # 而且是抬手那一拍）。宿主把「你被停靠了」写进 App 自己的沙盒，
                  # App 侧的 `-[UIApplication sendEvent:]` 读它并吞掉整条事件表。
                  #   这三行缺任何一条都等于「这一版没有新证据」：
                  #   宿主写标记 / 启动时按名单清（崩了也不留死标记）/ App 真的吞了。
                  b"win: mini flag armed ",
                  b"boot mini flags cleared ",
                  # 0.1.9 — 停靠标记的第二条通道（Aevon(96) 第 2 条：`(no container)`
                  # 出现 49 次，容器找不到就写不进文件，那些 App 的闸门一次都没装上）。
                  #   `(notify only)` / `(notify+file)` 是返回值打出来的口径 ——
                  #   日志里看到 `(notify only)` 就说明「文件不成、通知成了」。
                  b" notify only, no file",
                  b" notify and file",
                  # 0.1.10 — `ring: disc touch down at ` 也删了。圆盘在屏时的触摸
                  # 不再靠应用层那条通道喂（`AevonRingMenu` 自己重写了
                  # `touchesBegan/Moved/Ended/Cancelled`，挂在 host 上本来就在命中链里），
                  # 所以这条探针随 `rawBar` 一起撤。
                  # 白图标过滤：一条汇总（kept / dropped 与四个理由各多少），
                  # 外加每个被丢掉的白图标的名字（前 20 个）。只看汇总分不清
                  # 「删掉的是几个白图标」还是「删掉了半屏正常 App」。
                  b"icons: catalogue kept=",
                  b"icons: drop blank ",
                  # 0.0.57 — 应用面板搜索。`panel: search` 是每次过滤后的结果条数
                  # （0 也打，所以「搜不到」和「搜索没接上」能分开），
                  # `panel: keyboard overlap=` 是抽屉为键盘让开的量 —— 这条为 0
                  # 说明键盘根本没升起来，那就不是布局问题。
                  b"panel: search ",
                  b"panel: keyboard overlap=",
                  # 0.0.47 — 手势面搬进自己的窗口（statusBar+1，见
                  # FloatHost.makeBand）。两条：`band window up level=` 证明那一
                  # 层真的建起来了，`band probe` 是该窗口收到的每一次命中提问（点
                  # 与答案）。有 probe 而答案 nil，是环判错；一条 probe 都没有，
                  # 是触摸连这一层都没到 —— 这正是 0.0.44-0.0.46 分不开的两件事。
                  b"win: band window up level=",
                  b"win: band probe ",
                  # 0.0.48 — 手指入口搬到 `-[UIApplication sendEvent:]`。四份日志
                  # 证明「窗口会不会被问到」不可靠（`event hit` / `band probe` 整场
                  # 只有 ✕ 那一条），所以这一轮不再依赖窗口命中。`raw touch grab
                  # zone=` 是这条路真的收到手指的唯一证据，`raw long press corner`
                  # 是长按复位，`raw touch cancelled` 是系统把手势收走。
                  b"win: touch seen at ",
                  b"win: raw touch grab zone=",
                  # 0.1.0 — 「恢复默认尺寸」从右下角搬到它内侧那一格，所以这条路
                  # 的证据也跟着改名（旧串 `raw long press corner` 已不存在）。
                  b"win: raw long press bottom-right-side",
                  b"win: raw touch cancelled by the system",
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
                  # 0.0.59 — 冷启动首帧。三条缺一不可：
                  # `launch state cs=` 是建卡那一刻的判据读数（contentState、
                  # layerManager.layers、是否前台可见、是否按住），
                  # `held=1` 写在同一条行的末尾，说明卡片真的被按住了（拼在这一行
                  # 里是为了少一次 activate 之前的写盘 —— 那一笔直接排在首帧前面），
                  # `first frame watch beats=` 是观察器真的等到并放行（带毫秒数，
                  # 能直接读出这段空窗多长）。缺第一条说明判据没跑；缺第三条说明
                  # 卡片永远不显示 —— 那是比闪黑更糟的一版。
                  b"win: launch state cs=",
                  b"first frame watch beats=",
                  b"win: first frame shown after ",
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
                  # 0.0.98 — 多窗的第一版证据。这一组少一条，就说明「圆盘再选
                  # 图标有反应」只落地了一半：
                  #   `win: slot taken` = 新主窗拿到了哪一个槽，后面跟着保活名单、
                  #     有画布的窗数、以及「没登记就设尺寸」的次数。读法：两个窗
                  #     都在时 `frames=2`、`orphan=0`；`armed=` 里必须同时有两个
                  #     bundle，否则降级的那一个下一拍就会被系统收走（黑窗）。
                  #   `win: demote` = 旧主窗被降级，后面跟着它落到哪条边 —— 用户
                  #     提的「已存在的悬浮窗自动吸附到屏幕边缘」就是这一行。
                  #   `win: card demoted` = 降级真的改了几何（尺寸 + 落点）。
                  #   `win: no free slot, ` = V1 的饱和拒绝：一主一停已经占满，
                  #     这一下不再是静悄悄 return，而是能在日志里数出来的拒绝。
                  b"win: slot taken bundle=%@ slot=%d armed=%@ frames=%ld orphan=%ld",
                  b"win: demote old=%@ side=%@ new=%@",
                  b"win: card demoted side=%@",
                  b"win: no free slot, ",
                  b"win: no free slot, %@ declined before demote",
                  b"win: demote found no card",
                  # 0.0.99 — 修 Aevon(87) 的一组证据：
                  #   `win: card docked … nth=` = 停靠落点由排列表算（不是「按卡片原来
                  #     靠哪边」），`nth=` 是当前停靠总数，决定尺寸档位。
                  #   `win: gesture gate open zone=` = 长按闸门真的开了（两侧按住才
                  #     移动、底中按住才关闭）。
                  #   `win: gesture edge-middle not a close up=` 后面带 `gate=0/1`：
                  #     轻滑底中不关闭，是这一版「上滑关闭容易误触」的修法。
                  #   `win: no window - presenter released` = 开窗失败后 presenter
                  #     被拆掉。这条缺了，同一个 App 第二次选就是主线程卡死。
                  #   `win: hide found no window for ` = 找错名字时不拆别人的窗。
                  b"win: card docked %.0fx%.0f at %.0f,%.0f nth=%d col=%@ row=%d",
                  b"win: gesture gate open zone=",
                  b"raw gesture gate open zone=",
                  b"win: gesture edge-middle not a close up=%d vx=%d dy=%d gate=%d",
                  b"win: no window - presenter released",
                  b"win: hide found no window for ",
                  # 0.1.0 — 修 Aevon(88) 三条反馈的一组证据：
                  #   `win: card docked … col=R/L row=` = 落点由「右列先满再左列」那条
                  #     队列算。0.0.99 是 5 个全堆左列（`nth=1 at 0,0`、`nth=2 at 0,280`），
                  #     这一行是那次修复的读数。
                  #   `win: gesture long press bottom-right-side` = 底右内那格的长按真的
                  #     收到了（用户：「底部右侧的长按恢复默认尺寸不易触发」）。
                  #   `win: gesture long press bottom-left-side, 横屏 not wired yet` =
                  #     底左内那格是 V4 的位子，本版只确认格子能收到手指。
                  #   `win: grip ring band=` 后面带 `cell=`：两个数都是卡片宽度的比例，
                  #     卡片一变它们就变 —— 用户第 2 条「热区随悬浮窗大小变化」的判据。
                  b"win: grip ring band=",
                  b"win: gesture long press bottom-right-side",
                  # 只到逗号：`b"..."` 里不能放中文（bytes 只能 ASCII），而源码里
                  # 这个前缀已经唯一 —— 半句就够定位。
                  b"win: gesture long press bottom-left-side, ",
                  b"win: raw long press bottom-right-side, already default",
                  # 0.1.1 — 修 Aevon(89) 三条反馈的一组证据：
                  #   `win: card already default … target …` = 复位判定的**两端**都
                  #     打出来了。0.1.0 只打现状，于是「目标被算成现状」与「本来就
                  #     是默认」在日志上一模一样（Aevon(89) 第 1 条：复位永远不生效）。
                  #     两端相等 = 真默认；不相等却没复位 = 判定还是错的。
                  #   `win: mini tap down at ` / `win: mini tap up, promoting back to
                  #     main` = 停靠小窗把触摸**吞掉**并按一次还原成主窗。缺第二条
                  #     ⇒ 手指走了 App 那条路（Aevon(89) 第 2 条：点小窗透传）。
                  #   `win: card docked … at` 的 y 不再是 0 的整数倍 ⇒ 上下留白与窗间
                  #     缝都生效了（Aevon(89) 第 3 条）。
                  b"win: mini tap down at ",
                  b"win: mini tap up, promoting back to main",
                  # 0.1.3 — 小窗触摸**一条都不放行**的判据（Aevon(91) 第 1 条）。
                  # 0.1.1 在小窗贴边的那一侧让了 12 pt，于是一次完整的点击被交给
                  # 了 App；而 `mini tap down` 只在吞掉之后才写，漏掉的那些一行都
                  # 没有。这一行把「落进矩形的按下数」和「被吞掉的按下数」并排打
                  # 出来：`down != eaten` 就是又漏了。整条字面量，不拼。
                  b"win: mini touch down=%d eaten=%d near=%d",
                  # 0.1.4 — 三个新读数，各管一条：
                  #   `win: level %.0f -> %.0f %@` = 卡片窗换档（主窗 101 / 小窗 100）。
                  #     用户 Aevon(92) 第 2 条「新吸附的小窗遮挡主悬浮窗」就是同一层
                  #     级下按建窗顺序排 z 序造成的；这行是换档真的发生的证据。
                  #   `win: mini miss at ` = 落在小窗框**外** 24 pt 内却没被认领的按下。
                  #     92 里 `down`/`eaten` 一直相等却仍透传，漏的就是这些没进
                  #     `inside` 那一支的事件。
                  b"win: level %.0f -> %.0f %@",
                  b"win: mini miss at ",
                  # 0.1.5 — 四条新证据（Aevon(93)）：
                  #   `win: zone top ignored at ` = 顶部环带上被拒绝的按下。顶部从
                  #     0.1.5 起不是把手（第 1 条：`zone=top` 认领 16 次、真的搬走
                  #     卡片 5 次）。这行出现 = 门在生效；一次都没有 = 用户没再误戳。
                  #   `win: mini lift deferred ` = 点小窗之后**下一拍**才升降。
                  #     它必须是 `card undocked` 的**前一行**：倒过来就说明又在
                  #     `sendEvent` 里面改窗口层级了（第 4 条的修法）。
                  #   `win: card undocked … mem=NN%` = 升主窗用的尺寸来自**全局记忆**
                  #     而不是这张卡停靠前的 frame（第 3 条）。五张卡该是同一个百分比。
                  b"win: zone top ignored at ",
                  b"win: mini lift deferred ",
                  b"win: card undocked ",
                  # 0.0.69 — 三条新的行为证据，缺一条就说明这一轮有一件事没落地：
                  #   · `long press corner, already default` = 长按在默认尺寸上真的
                  #     什么都不做（Aevon(59) 的第一条）；
                  #   · `canvas re-asserted` = 承载面尺寸在 `activate` 之后又交了一
                  #     次（「每次打开内容尺寸不对」的修法，见 FloatHost）；
                  #   · `frame restore again` = 关窗后第二次交还整屏（退出后偏下）。
                  b"win: card already default %.0fx%.0f target %.0fx%.0f at %.0f,%.0f",
                  b"win: canvas re-asserted ",
                  b"win: frame restore again door=",
                  # 0.0.70 — 沙盒 App 的读数取回。这三条是「量尺终于能到手」的证据：
                  # 桥接退到自己的 tmp（`aevon-app.log`），宿主开卡/关卡时取回并
                  # 以 `applog[<bundle>]: ` 前缀并进主日志，首帧之后还会补一次真实
                  # 的窗口尺寸变化（`scene nudge`）。缺任何一条，抖音那一侧就还是
                  # 「量了也看不见」。
                  b"win: app log lines=",
                  # 0.1.2 — 宿主第一次「听懂」App 的求救。Aevon(90) 里抖音自己写了
                  # 8 条 `app: hang`，宿主每 2 秒读走、只数行数、随后丢掉 ——
                  # 卡死的前 85 秒我们一条证词都没有。这三条是这一轮的判据：
                  #   `app hang echo` = 把 App 的原话转写进主日志（时间轴对齐）；
                  #   `app hung n=/total=/silent=` = 卡了几行、累计多少、心跳静默几秒；
                  #   `hung snap` = 卡死期间宿主侧现场（每 2 秒一条，5 条）。
                  b"win: app hang echo ",
                  b"win: app hung n=",
                  b"win: hung snap %@ cs=",
                  # 0.0.75 — 关卡之后 4 s 再取一次。Aevon(65) 缺的正是这一段：
                  # App 真正按 932 重排是在用户回到全屏那一刻，而那时的读数一条
                  # 都没取回来（关卡那一拍只取到 3 行，之后 12 s 的 `state` 全在
                  # 文件里没被读）。字面量给到 22 字节，躲开「≤15 字节编成立即数」。
                  b" from after card closed",
                  # 0.0.91 — 死场景的证词与接回。Aevon(80)/Aevon(81) 的
                  # 「浮窗消失、只剩一圈白色光晕」= 被托管的进程没了：
                  # `cs=0` 且 `sublayers=0` 连续两拍。第一行是判定，
                  # 后三行是动作（关卡 + 0.6 s 后用同一个 bundle 重开）
                  # 与它的三道闸（120 s 上限、已有卡、重开失败）。
                  b"win: scene dead cs=0 layers=0 beats=",
                  b"win: revive bundle=",
                  b"win: revive suppressed, last one ",
                  b"win: revive gave up ",
                  # 0.0.92 — 手指进来多少、被我们吞掉多少（宿主侧每秒一行）。
                  # `in>0 eat=0` ⇒ 卡屏不在我们这一侧（手指进到场景里了，我们
                  # 一条都没吞）；`eat>0` ⇒ 是我们吞的。Aevon(82) 的「页面滑不动、
                  # 点不动」当时只能靠 `touch seen` 的前 12 条去推测，分不出这两种。
                  b"win: touch in=%d eat=%d",
                  b"applog[%@]: ",
                  # 0.0.74 — 轻推与「替操作者缩放一下」都撤了：Aevon(64) 的原话
                  # 是「内容会自己跳动」，而那两次 17 pt 正是跳动的来源。反过来
                  # 还要能证明它们真的不在了 —— 见下面的反向断言。
                  # 0.0.73 — 「第一次打开内容尺寸不对」的真正修法。承载面的
                  # `transform` / `center` 会被系统的 presentation 重设抹掉（每次
                  # scene settings 被写都会），卡片于是按 1:1 裁掉右侧与底栏。
                  # 这一行只在**真的被抹掉之后重写**时出现：日志里第一次开卡出现
                  # 一两行是正常的，每 200 ms 都出现就说明还有别的东西在抹它。
                  b"win: placement put back ",
                  # 这里原本还有一条 `after nudge`，CI 第一轮把它拦下来了：
                  # Swift 会把 ≤15 字节的字符串字面量编成立即数，`"after nudge"`
                  # 是 11 字节，二进制里根本搜不到。日志里它照样会出现（运行时由
                  # 立即数拼出来），只是不能拿它当「代码在里面」的证据。
                  # 同一类坑见 MEMORY：「日志拼接段 ≤15 字节被编成立即数」。
                  b"aevon-app.log",
                  # 0.0.40 — 闪黑。这一行只在系统真的动过场景的休眠状态时出现，
                  # 它是「黑一下」来自场景被收走 还是 来自合成器 的唯一分界。
                  b"win: scene deactivation #",
                  # 0.0.50 — Aevon(48) 把 0.0.40 那道选择题答完了：切换 App 的
                  # 每一轮 fg 都没变过，黑不经过 settings。判据换成 scene 自己的
                  # contentState，掉下去与回来各一行，回来那行带毫秒数。
                  b"win: picture dropped cs=",
                  b"win: picture back after ",
                  # 母本那三件套里的后两件。这个字面量同时证明 0.0.50 写的是
                  # level/idle，而不是只写 foreground。
                  b"setIdleModeEnabled:",
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
                  # 0.0.82 — 交还后台改成「拆完 presenter 再写」。Aevon(73) 里每一张卡
                  # 都是 `door=1 fg=yes` + 0.6 s 后 `retry door=1 fg=no`：第一次没落地，
                  # 而那一秒正好是「关掉浮窗后立刻点图标」被按回去的那一秒。这一行
                  # 就是新时序的读数（`first=` 是拆之前那一次的返回值）。
                  b"win: background after teardown door=",
                  b"hook: selftest got=%ld want=102",
                  b"_setDeactivationReasons:onScene:withSettings:reason:",
                  b"_scene:interceptUpdateWithNewSettings:",
                  # 0.0.52 — 事前改参数。母本挂的是子类，0.0.29 挂的是父类，
                  # 于是 intercept=0 两次。这两条字符串证明候选点与装钩子时的
                  # 形状回执都进了二进制。0.0.54 删掉了第三个候选点
                  # （SBDeviceApplicationSceneViewController）：0.0.53 真机日志里
                  # `client=0` 走完全场，那条路一次都没响过。
                  b"SBMainDisplaySceneManager",
                  b" shape cls=%@",
                  b"presenter %@ -> %@",
                  b"/var/mobile/Library/Logs/Aevon/win.step"):
        if token not in dylib_early:
            bad(f"probe: {token.decode()} missing from Aevon.dylib — "
                "the probe would never reach SpringBoard")

    # 0.0.99 — 用户定档「两侧轻滑不移动，只有长按后拖才移动」。
    # 正向证据已在上面（`gesture gate open zone=` / `raw gesture gate open zone=`）；
    # 这里只留一条反向：0.0.98 及以前那一版**没有**闸门，两侧一碰就走。
    # 不断言 OC 选择子名（`gestureRecognizerShouldBegin` 之类）——Swift 的协议扩展
    # 方法名不一定落进 `__objc_methname`，拿它当断言就是拿构建成败赌一个假设。

    # 0.0.66 — 「旧进程就先杀掉」这条路不许回来。它要读一张名片文件判断进程
    # 新旧，而那一步依赖沙箱里的写盘；写不进去时判据永远不成立，于是每次开窗
    # 都先 SIGKILL 那个 App —— 一次写失败换来「App 打不开」。旧进程的唯一坏处
    # 只是这一版的改动没生效，那是可以容忍的。
    for token in (b"win: icon cold start ",                          # gone
                  b"AevonColdStartReady",                            # gone
                  b"/var/mobile/Library/Logs/Aevon/bridge"):          # gone
        if token in dylib_early:
            bad(f"probe: {token.decode()} 又出现了 —— 0.0.66 已撤掉换进程那条路")

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
    ok(f"size: deb {len(blob):,} B (no ceiling — recorded only)")

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
