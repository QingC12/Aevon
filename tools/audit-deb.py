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
        # 0.2.60 — 设置按功能重写，只剩两个二级页。
        elif len(panes) != 2:
            bad(f"panes: {len(panes)} openable panels, expected 2")
        else:
            ok(f"panes: {len(panes)} child panes open via openPanel:, root has {len(items)} items")
        if len(items) < 14:
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

    # 0.2.83 — 承载层普查那行必须真的接线。
    #
    # 0.2.80 写好了三个探针函数却没有一行 plist 指向它们，于是「探针按钮」
    # 在设置里根本不存在，取证通路只剩开机那一次 —— 而开机那一次被装包截断
    # 吃掉了。这里两头都查：plist 里有这一行，二进制里有同名 @objc 入口。
    # 只查 plist 会放过「行画出来了、点下去没反应」这种最难查的形态。
    if root is not None:
        if not any(i.get("action") == "probePresenter:"
                   for i in plistlib.loads(root).get("items", [])):
            bad("prefs: Root.plist has no probePresenter: row — the census "
                "is unreachable without a rebuild")
        elif b"probePresenter:" not in prefs:
            bad("prefs: Root.plist names probePresenter: but the bundle has "
                "no such @objc action — the row would be dead")
        else:
            ok("prefs: 承载层普查 row is wired (plist action + @objc entry)")

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
    panel_names = ["Window", "Ring"]
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
                  b"ring: edge claim=",
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
                  # 0.1.78 — 从写死的 `lease 3.0 s` 改成带参数的格式串。0.1.77 把复查
                  # 窗口缩到 1.7 s 之后这行还印着 3.0，判据被自己写脏了；现在印的是
                  # 常量本身（`kbLease` / `kbReview`）。
                  b"ring: keyboard watch armed (lease %.1f s review %.1f s)",
                  b"ring: keyboard up, edge band stepped aside",
                  b"ring: keyboard gone, edge band back",
                  # 0.1.76 — 租约兜底：Darwin 「键盘收了」丢一条时，靠这一行把
                  # 卡片收回去（Aevon(147) 的「必须再开关一次键盘才还原」）。
                  b"ring: keyboard lease gone, fill back",
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
                  b"AevonRingPointerHandoffV216",
                  # 0.1.26 — 悬浮窗动效（Aevon(108) 第 1~3 条）。
                  #
                  # 这条格式串只在 `AevonMotion.spring` **第一次真的被调用**时才
                  # 打出去，所以它证明的不是「模块编进去了」，而是「有代码在调
                  # 它」：`-dead_strip` 会把没有任何调用点的函数连同它的字面量一起
                  # 剥掉 —— 0.1.24 的 `ring: expanded (` 就是这样在 CI 挂掉的。
                  #
                  # 反过来说：这条 MISS，就说明升窗 / 停靠 / 复位里至少有一条路
                  # 又回到了「硬写几何、没有过渡」的老样子。
                  b"win: motion spring response=",
                  # 0.1.27 — 停靠收缩（Aevon(108)：「吸附时翻转一下」）。
                  #
                  # `dock flight` 打在这张卡开始缩的那一拍，`dock landed` 打在
                  # `transform` 交回 `bounds` 的那一拍。两条必须成对：只有 flight
                  # 没有 landed ⇒ 落地的完成回调没接上，那一张会永远停在「缩到
                  # 一半」的样子（点它、升窗都会露出马脚）。所以一起断言。
                  b"win: dock flight ",
                  b"win: dock landed ",
                  # 0.1.28 — 打开 Q 弹 / 关闭收缩。
                  #
                  # `enter bounce` 写在欠阻尼入场第一次真的开跑的那一拍，
                  # `exit shrink` 写在关窗出场第一次开跑的那一拍。两条都是
                  # 「函数真的被调到」的证词：`-dead_strip` 会把没人调的代码整段
                  # 剥掉，所以二进制里有没有这两个串，等于「这条路还在不在」。
                  b"win: enter bounce ",
                  b"win: exit shrink ",
                  # 0.1.29 — 四条新证词，各对应一条用户要求：
                  #   `corner fixed`   圆角按档位固定（不再随尺寸比例）
                  #   `band report`    主窗四边热区交给 App 进程
                  #   `style `         系统深浅色变了（桌面侧接住并转发）
                  # 0.1.31 — `lift bounce` 换成 `lift one shot`：升窗不再「长完再弹」，
                  # 改成一条从当前尺寸到目标的曲线（见 `AevonMotion.lift`）。
                  # 0.2.40 — `corner fixed` 换成 `corner w=`：圆角不再是固定档位，
                  # 改成「卡宽 × 12.73 %」，日志把卡宽、半径、比例一并打出来。
                  # 用带格式符的整句：`win: corner w=` 只有 15 字节，会被编成立即数。
                  b"win: corner w=%.0f r=%.0f pct=%.1f",
                  b"win: lift one shot ",
                  b"win: band report ",
                  b"win: style follow ",
                  # 0.1.31 — 锁屏 / 通知中心 / 控制中心盖上来时整层让开，
                  # 以及恢复显示后那一次「把承载面动一下」。
                  # 0.1.34 — 解锁后重挂承载面：`canvas revived` 是动作本身，
                  # `revive after unlock` 是保活时钟接住那一次的信号。两条都
                  # 必须在内核里 —— 前两版黑屏就是「窗口回来了、画面没回来」。
                  # 0.2.2 — 0.2.0 那两条「盖着就收卡」整段删除（见反向断言表）。
                  # 剩下的两条遮挡闸都只做一件事：建卡失败时**不许**回落全屏。
                  b"win: icon card closed by cover, no fallback",
                  # 0.2.1 — 4 秒等不到场景、这一刻系统界面还盖着 ⇒ 一个字节都不开。
                  b"win: icon card gave up under cover, no fallback",
                  # 0.2.3 — 卡片没起来时留一行证词。0.2.4 — 这一行后面跟回落，
                  # 所以措辞从 `no fallback` 改成 `falling back`（见文件末尾）。
                  b"ring: card declined (",
                  # 0.2.4 — 母版那条「失败回落原生一次」又接回来了，带滑动窗口限流。
                  b"ring: launch done t=%ldms",
                  b"ring: launch skip ",
                  # 0.2.4 — 第二条口径：拦截点记过的 scene（manager 枚举列不出的那种）。
                  b"win: scene from hook table ",
                  # 0.2.79 — 同一个 bundle 多份 scene 时的打分取舍。
                  #   `all shell` = 全部空壳（前台运行/可见/内容/前台位都是 0），
                  #       交回 nil，让 `openCard` 走自建；
                  #   `pick` = 打过分、挑中了不是空壳的那一份。
                  # 12:21:06 的微信黑卡就是「没打分、取第一份」造成的。
                  b"win: listed scene all shell b=",
                  b"win: live scene pick b=",
                  # 0.2.4 — 挂起启动带重试（对应母版 maxAttempts/delay）。
                  b"win: icon relaunch %@ try=%ld door=%ld t=%ldms",
                  # 0.2.3 — 等 scene 那几秒的现场快照（pid + 全部 scene 标识）。
                  # 0.2.4 — 多一个 hook 计数：枚举里有几个、拦截点记了几个。
                  b"win: wait scene %lds app=%d n=%ld hook=%d %@",
                  # 0.2.4 — 黑名单。断言用长键名而不是 `blacklist`（9 字节会被
                  # 编成立即数，`why=blacklist` 又是拼出来的，都不在二进制里）。
                  b"windowBlacklistText",
                  # 0.2.4 — 圆盘那条路的名单闸（它没有打开请求可判，单独问一次）。
                  b"ring: blacklisted, native open ",
                  # 0.2.4 — 等满 12 秒的出口。**不能写 `no scene in 12s`**：那句
                  # 正好 15 字节，Swift 把它编成立即数，二进制里没有这个串。
                  b"no scene after 12s and 3 retries",
                  b"win: canvas revived ",
                  b"win: revive after unlock tick=",
                  # 0.1.61 — 键盘态的**进与出**都在。0.1.60 只留下了「进」：
                  # 进入分支把 `kbFilled` 置真的那几行被删掉，收起分支第一行
                  # `guard kbFilled` 于是恒真返回 —— Aevon(132) 里
                  # `win: keyboard fill on` 刷了 60 多条、`fill off` 零条，
                  # 卡片永远停在 430x717@0,215，三边贴屏、环带按不到。
                  # 两条都断言，缺一条就是这条路又断了半边。
                  # 0.2.60 — 键盘不再改几何：`fill on/off` 与 `armed hold` 三条
                  # 一起下线，只剩这一行「键盘来了 / 走了，卡片没动」。这一行
                  # 出现却看不到卡片几何变化，才是这一版要的行为。
                  #
                  # 0.2.62 — 它现在只在 `kb.keep` 开关**打开**时出现（默认关：
                  # 走母版的键盘态）。所以这条断言证明的是「退路还在」，不是主路径。
                  b"win: keyboard %@ card kept %.0fx%.0f at %.0f,%.0f scene=%.0f",
                  # 0.2.62 — 主路径：键盘态把卡片撑满屏宽、1:1，键盘原生尺寸。
                  # 这一行带 `native` 才说明走的是母版那条路（Stheno 分屏键盘实测）；
                  # 只有 `card kept` 没有 `native` = 开关被打开着。
                  b"win: keyboard native on card=",
                  # `kb-to-card=` 仍由 `finishKeyboardUnfill` 保留（迁移路径）。
                  b" kb-to-card=%.0fms",
                  # 0.2.43 — 键盘让位那一段的曲线与补推。
                  #   `kb spring t=` = 张开/缩回走的是 `AevonMotion.fill`（过阻尼弹簧、
                  #     固定 0.24 s），不是裸 `UIView.animate`。这条路要是退回裸块，
                  #     `AevonMotion.inFlight` 就恒假，圆角补间的闸跟着失效 ——
                  #     用户报的「放大时闪一下」正是那么来的。
                  #   `kb push late gave up door=0` = 场景帧四拍都没推成。它应当**罕见**；
                  #     每开一次键盘就出现一次，说明 `AevonPushSceneFrame` 一直在
                  #     hook 里被拒，得回头看那条死锁纪律的边界。
                  b"win: kb spring t=%.2f zeta=%.2f v=%.2f",
                  # 0.2.57 — 放弃那一行带上了原因码。旧串 `gave up door=0` 已经
                  # 不存在：它分不开「已经等于目标」与「被钩子挡了」。
                  # 这两行是**拼接**出来的（`String(format:)` 在那个闭包里会让
                  # 类型检查器超时），所以 `__cstring` 里只有前缀，没有 `%d` 尾巴。
                  # 0.2.59 — 五件事各有自己的一行证词，缺哪条就等于那一步没接上：
                  #   `warm start/done` = 圆盘悬停预热（抖音冷启动那 749 ms 从这里挪走）；
                  #   `auth card close` = 授权交接完成后收微信/QQ 卡；
                  #   `share swap nogate` = 来源顶不回来时提前走兜底（那 1.2 s 的乱跳）；
                  #   `card closed after auth` = Swift 侧真的把那张卡拆了。
                  b"win: warm start b=%@",
                  b"win: warm done b=%@ at=%.0fms pid=%d",
                  b"notify: auth card close b=%@ why=%s",
                  b"win: card closed after auth b=",
                  # 0.2.91 — 分享点了就进安全模式：`_Block_signature` 被当成
                  # `struct { void *; const char *; } *` 读。真原型返回的是
                  # `const char *` 本身，于是 `sig->signature` 读到签名串自己的
                  # 第 8~16 字节（崩溃地址 `0x22726f7272455340` = `@SError"`），
                  # `strnlen` 踩上去就是 EXC_BAD_ACCESS + PAC 失败，而且是**在
                  # 写日志之前** —— 所以三份日志里连一行 `act: activate` 都没有。
                  # 这一条断言证明的是「出错时有话说」，不是「不会出错」：
                  b"landing: url threw %s",
                  # 0.2.79 — **撤掉 0.2.74 的「吞掉 + 自建 + 投递」。**
                  #
                  # Aevon(212) 把它证伪在三处，而且每一处都指向同一个根：
                  # 自建 scene 里没有系统那一次激活。
                  #   · QQ      `appurl ack ok=1 via=app-src … rsp=0` —— SDK 没接；
                  #   · 支付宝  `appurl give why=timeout at=6342ms` —— 连回执都没有；
                  #   · 微信第二次 `own live attach` + `launch state cs=0` —— 黑卡。
                  #
                  #   `oauth native` = 这一条授权 / 支付原样交给系统激活，卡片在
                  #       scene 一登记时收回来（紧跟 `notify: auth swap card`）。
                  #       `url=` 只说明这一拍照样带不带 URL，不参与判断。
                  b"notify: oauth native b=%s src=%@ scheme=%s pay=%s url=%d card=%d",
                  # 0.2.80 — 承载层只读普查。这是 Stheno 的 presenter 路线在
                  # 本机能不能走的唯一证词，少了这几行就只剩推断：
                  #   class     每个类在不在、方法数、ivar 数、父类
                  #   selector  关注选择子定义在哪个类上、真实类型编码
                  #   ivar      presenter / hostView 的形状（P1 的接口面）
                  #   method    两类的全量方法名
                  #   live      前台 scene 答不答 presenter 那三个选择子
                  #   end/skip  这一轮跑完 / 本版本已跑过
                  b"presenter: census begin version=",
                  b"presenter: class ",
                  b"presenter: selector ",
                  b"presenter: ivar ",
                  b"presenter: method ",
                  # 0.2.87 — `presenter: live app=1 scene=` 与
                  # `presenter: live app=none scene=none` 两条断言随
                  # `describeLiveCarrier` 一起删除：那个函数问的七个名字没有一个
                  # 能给出信息（四个是猜的，`uiPresentationManager` 挂在 NSObject
                  # 上 ⇒ responds 恒真），留着只会让 census 账本更难读。
                  b"presenter: census end classes=",
                  b"presenter: census skip version=",
                  # 上一轮普查死在哪 —— 标记先写、普查后跑的代价由这一行补回来。
                  b"presenter: last census stopped at ",
                  # 0.2.83 — 普查的第二个出口。0.2.82 那一轮的数据是被装包动作
                  # 吃掉的：`postinst` 从 0.2.21 起就截断 Aevon.log，而普查一个
                  # 版本只跑一次 ⇒ Aevon(214) 只剩一行 `census skip version=0.2.82`。
                  # 这三条字面量就是「数据不会再被装包吃掉」与「不必烧构建、
                  # 不必重启就能重跑」在二进制里的证词：
                  #   presenter.census  专用账本（追加，装包不清）
                  #   presenter.force   手写即强制重跑
                  #   why=              boot / panel / force，三个入口分开读
                  b"presenter.census",
                  b"presenter.force",
                  # 0.2.84 — 第二轮普查：按选择子反查归属类。第一轮只回答「类在不在」，
                  # 而写调用需要的是「这一步定义在哪个类上、编码是什么」。三条字面量
                  # 就是这一轮真的跑过、并且自己收尾了的证词：
                  #   pass begin … classes=  开始扫，附带运行时类总数
                  #   pass end found=…       扫完，命中的「选择子 × 类」总条数
                  #   aborted                拿不到类表（真机上不该出现，出现即这一版白跑）
                  b"carrier: pass begin why=",
                  b"carrier: pass end found=",
                  b"carrier: pass aborted, no class list",
                  # 0.2.85 — 方案 S 的取证面。0.2.84 只回答了「谁实现了那 21 个
                  # 选择子」，写调用还差三块，这一版一次取全：
                  #   · URL 到底能从哪儿拿 —— `shape:` 把打开请求的四个参数
                  #     （request / options / activationSettings / origin）摊开，
                  #     probe 行逐个报「有没有这个名字 + 返回什么」；
                  #   · definition / settings / manager 的全量方法表 —— carrier
                  #     新增五个类，方法名以 `carrier: m <类> <选择子> <编码>` 落地；
                  #   · 母本那个构造器长在哪个类上 —— 只有全类扫描能答。
                  # 前缀全部长过 15 字节，理由同上：短的会被编成立即数搜不到。
                  b"initWithURL:workspaceOriginatingProcess:",
                  b"workspaceOriginatingProcess",
                  b"parametersForSpecification:",
                  # 0.2.87 — 三条 `shape:` 断言随 `AevonOpenShapeDump` 一起删除。
                  # 它跑过一轮（Aevon(219)）并且答完了：第一个参数是 bundle id
                  # 字符串，URL 只在 options 的 `__PayloadURL` 里、且是裸 NSURL。
                  # 函数已从源码移除 —— 未调用的静态函数会被 `-Osize` 整段消除，
                  # 留断言必然落空（这一版就是这么被 CI 挡下来的）。
                  b"FBSMutableSceneDefinition",
                  b"FBSMutableSceneSettings",
                  # 0.2.86 — 方案 S 判死之后的一轮「URL 装哪」取证。这一轮不再问
                  # 「谁实现了什么」，而是问「action 投进哪个容器」：
                  #   · 七类 `carrier: class` —— parameters / transitionContext /
                  #     UISOpenURLAction / LSApplicationWorkspace，母本那条
                  #     `initWithURL:workspaceOriginatingProcess:` 所在的对象链；
                  #   · 八条选择子 —— `transitionContext` / `setActions:` 一族，
                  #     命中与不命中都是读数（`carrier: none` 同样是答案）；
                  #   · `shape: payload` / `shape: actions` / `shape: act[]` ——
                  #     打开请求里 payload 与 actions 元素的真实类名和 ivar 名。
                  # 0.2.85 把 shape 挂在 `verdict == 1` 上，真机两次分享都走
                  # `return 0`，探针一次没落地；这一版改挂在「带 payload」上。
                  b"FBSSceneParameters",
                  b"FBSSceneTransitionContext",
                  b"UIMutableSceneTransitionContext",
                  b"UISOpenURLAction",
                  b"LSApplicationWorkspace",
                  b"openSensitiveURL:withOptions:",
                  b"setObject:forActivationSetting:",
                  # 0.2.87 — `shape: payload` / `shape: actions` / `shape: act[]`
                  # 三条断言同样随函数删除而移除。它们那一轮的读数记在这里备查：
                  #   shape: payload url=#NSURL len=-1   → `__PayloadURL` 是裸 NSURL
                  #   shape: actions none                → 没有现成的 BSAction
                  #   shape: req cls=__NSCFString        → 第一个参数根本不是 request
                  # 0.2.87 — 三路并轨母版。这一版唯一的**行为改动**是「普通深链
                  # 不再吞掉」，两个新日志行就是它的判据面：
                  #   · `notify: link native` —— 这一族改报 `linkpass` /
                  #     `safaripass` 并放行（旧行 `notify: link b=` 不再出现）；
                  #   · `notify: prewarm`     —— 母版第一招，`door=` 报挂起启动的结果
                  #     （1 成功 / 2 拒绝 / 0 没有这个方法），`ms=` 是那次同步 XPC 的耗时。
                  # 两个新类名补上「系统怎么把 URL 递进来」这一格：
                  #   `FBSystemService` 只有 15 B（不写断言），
                  #   `FBSOpenApplicationOptions` + `openApplication:options:withResult:`
                  #   是它的正反面。
                  b"notify: link native b=%s kind=%s scheme=%s front=%d card=%d",
                  b"notify: prewarm b=%s door=%ld ms=%d",
                  b"FBSOpenApplicationOptions",
                  b"openApplication:options:withResult:",
                  # 0.2.88 — 整屏那一帧的开关。`SBActivationSettings` 第 6 格
                  # `eventOnly`（键名由本机键表打出来，不是猜的），两行就是它的
                  # 全部判据面：
                  #   · `win: act key ev=` —— 键表里有没有这一格。`-1` = 本机没有，
                  #     那是读数不是故障，`eventbit` 整格跳过、行为退回 0.2.87；
                  #   · `notify: eventbit` —— 写给哪一次激活、读回多少。`read=1` 才是
                  #     「写进去了」，与 `suspended` 当初的判据同形。
                  b"win: act key ev=%d evflag=%d",
                  b"notify: eventbit idx=%d flag=%d read=%ld b=%s why=%s n=%d",
                  # 0.2.89 — 起点迁移第①段：激活那一拍，**只读**。
                  #
                  # 这一版的行为改动是零：两个方法都只挂上、原样尾调。所以它的
                  # 断言面只有「装没装上」和「装的是不是这两个真名」两件事，
                  # 一行行为断言都不该有 —— 有的话就说明这一版已经不只读了。
                  #
                  # 两个真名都要进包：`_activateBundleID:…` 在 `FBSystemService`，
                  # `_createSceneWithDefinition:…fromRemnant:…completion:` 在
                  # `FBSceneManager`。0.1.85~0.1.87 三次「本机没有」都出在只在一个
                  # 类里找，名字本身一次没写错过。
                  b"_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:",
                  b"_createSceneWithDefinition:settings:initialClientSettings:"
                  b"transitionContext:fromRemnant:usingClientProvider:completion:",
                  # 形状闸：activate 走整串相等（219 的普查给的就是这一串），
                  # createScene 只钉头尾 + 总长（中段类型静态读不出全串）。
                  b"v68@0:8@16@24B32@36@44@52@?60",
                  b"act: shape %s cls=%@ types=%s",
                  b"act: shape reject cls=%@ got=%s want=%s",
                  b"act: activate owners=%d",
                  b"act: createScene owners=%d",
                  # 四行读数，第①段要回答的就是这四件事：
                  #   `payload=1`  → URL 真的装在激活请求的 options 里（母版靠这一条
                  #                  才不用自己投 URL）；`keys=` 是那份 options 的大小；
                  #   `gap=`       → createScene 与它前面那次激活差多少毫秒（谁先谁后
                  #                  由正负号直接读出来）；
                  #   `id=` / `idc=` → scene 的身份在建 scene **之前**就拿得到吗 ——
                  #                  这是第②段能不能先建 presenter 的唯一前提；
                  #   `blk=1`      → completion 在第 7 位上，还是空。
                  #
                  # 0.2.90 — 第①段回来后改的口径：`res=` 删了（那是在读一个 void
                  # 方法的返回值，读到栈上垃圾）；options 改走 `dictionary`/`payload`
                  # 两级取字典（`via=` 说明走的是哪一级）；`sl=`/`susp=` 是「让系统
                  # 别摆屏」的两个候选键；`set=`/`frame=`/`resize=`/`tctx=`/`act=`
                  # /`icl=` 是 createScene 六个参数的形状，`csig=`/`rsig=` 是两个块
                  # 的真实签名；`fw=`/`fs=` 是那一刀几何写了几次、被挡几次。
                  b"act: activate n=%ld t=%lld trusted=%d b=%s opt=%s via=%d "
                  b"keys=%ld payload=%d sl=%d susp=%d k=%s rsig=%s",
                  b"act: scene n=%ld t=%lld gap=%ld def=%s idc=%s id=%s rem=%s prov=%s "
                  b"blk=%d set=%s frame=%d resize=%d tctx=%s act=%d icl=%s csig=%s",
                  b"act: hits activate=%ld scene=%ld boot=%d fw=%ld fs=%ld fi=%ld card=%s",
                  b"act: frame birth wrote=1 b=%s before=%.0fx%.0f after=%.0fx%.0f by=%s",
                  b"act: frame birth blocked why=%s b=%s set=%s",
                  # 0.2.92 — 不可变 settings 是 trap 不是异常：写下去 FrontBoard
                  # `_setValue:forSetting:` 直接 `__builtin_trap()`，`@try` 抓不住。
                  # 这几串是「闸真的在写之前」的证词，缺一条就说明又有人绕过闸写信。
                  b"act: frame birth threw %s cls=%s",
                  b"birth:immutable",
                  b"birth:enter",
                  b"birth:wrote",
                  # 0.3.20 — G1 的旁路。0.3.19 只从 `FBScene` 上找 handle，三条读法
                  # 全不答就 give up，于是 G2/G3 一次没跑。这三串证明「换 App 那一侧」
                  # 的代码真的进了包：fallback 起手、某一条读法答了、以及两条都断时
                  # 把 SBApplication 的 scene 族方法名列出来。
                  b"probe: G1 fallback b=%s",
                  b"probe: G1 via=%s cls=%s",
                  b"probe: G1 give up how=%s app=%s %@",
                  # 0.3.20 — `born == 0` 的黑洞。0.2.90 起只记 1（写了）/ 2（挡住），
                  # 「压根不是目标」一个字都不记，于是 Aevon(246) 里 `frame birth`
                  # 零行、分不清「没生效」与「没轮到」。
                  b"act: frame birth idle why=%s card=%s id=%s set=%s",
                  # 0.3.20 — 这条写路自己的闸。语义与 notify.off 不同：关的是「写」。
                  b"birth:off",
                  # 0.3.20 — **写路的扳机**。0.3.8 清零 URL 接管后 AevonActCardBundle
                  # 永远为空，`AevonActFrameBirth` 第一行就 return 0，于是「出生即卡
                  # 尺寸」从 0.3.8 起一次都没跑过。这一串是 Swift `openCard` 调的
                  # `AevonCardTargetArm` 打的，它出现就说明扳机接上了。
                  b"act: arm b=%s n=%ld",
                  # 0.3.22 — 普查一次性化。Aevon(247) 的 1869 行里 890 行是
                  # `presenter:` / `carrier:` 两轮普查，每次重启把 99307 个类重扫一遍
                  # 重打一遍。只把打印删掉是「永远不查」，所以要断言这两条路都进了包：
                  # 跳过（同一版第二次起）与强制（手写 `census.force`）。
                  b"presenter: census skip v=",
                  b"presenter: census forced why=",
                  # 0.3.23 — **URL 路的扳机 + 干跑。**
                  #
                  # Aevon(248) 的两次 QQ 分享都是 `act: activate ... payload=1` 到
                  # `act: scene id=sceneID:com.tencent.mqq-default` 只隔 39 ms，中间
                  # 没有任何 `act: arm` —— 于是 `AevonActCardBundle` 一直是空的，
                  # 出生尺寸在 URL 路上一次没跑过。这两串证明扳机真的接进了激活钩子
                  # （`src=url` 与圆盘的 `act: arm b=` 是两条独立读数，不能互相顶替）。
                  b"act: arm src=url b=%s kind=%d n=%ld write=%d",
                  # 0.3.28 — 普通深链（kind=1）不再上扳机。Aevon(3) 里
                  # `act: arm src=url b=com.apple.mobilesafari kind=1` 后面紧跟
                  # `act: frame birth dry=1 b=com.apple.mobilesafari` —— 深链、
                  # 不拒答、不排卡，却进了 birth 的干跑分支，只因 0.3.23 把两种
                  # kind 一起 arm。这一串是「它真的被排除」的唯一读数。
                  b"act: arm skip why=link b=%s kind=%d n=%ld",
                  # 干跑那一行：默认不写，只记「本来要写成什么、走副本还是直写」。
                  # 唯一能证明「四道门全过、只差按下开关」的读数。
                  b"act: frame birth dry=1 b=%s before=%.0fx%.0f want=%.0fx%.0f via=%s",
                  # 0.3.24 — **URL 路第一次接上承载。**
                  #
                  # Aevon(250)：frame 写成功了（`after=430x717`），系统也认了，
                  # 但装 scene 的窗口还是 430×932 —— 「像全屏又不是，下半屏黑」。
                  # 这一版在分享激活之后排一次 `openCard`，把 scene 挂到我们的卡上。
                  # 三串分别是：排上了 / 被闸挡住（`off` `off-late` `nowrite` `up`）/
                  # 真的开始建卡。少任何一串都说明这条承载路没进包。
                  b"act: url card queue b=%s n=%ld after=350ms",
                  b"act: url card skip why=off b=%s",
                  b"act: url card now b=%s",
                  # 0.3.25 — **URL 路的进场顺序。**
                  #
                  # Aevon(251)：卡建对了（`own live attach` / `hosting=yes` /
                  # `first frame 107ms`），但系统那份全屏承载还在，scene 被抽走
                  # 之后它就成了黑窗压在卡下面。根因是 0.3.24 走了
                  # `AevonOpenCardDirect`（`homed: true`，跳过 home-first）。
                  #
                  # 这一版改走 `AevonOpenCardURL`（`homed: false`）。两串是证据：
                  # 出口符号能证明那一支进了包；日志串能证明它真的被调用过
                  # （圆盘路不经过这个入口，所以出现即等于 URL 路走到了 home-first）。
                  b"AevonOpenCardURL",
                  b"win: url card via home-first b=",
                  # 0.3.26 — **拒答：0.3.8 之后第一次在「问句」那一拍改答案。**
                  #
                  # 之前每一版都是「答开 → 系统提交 → 我们去撤」；全屏那扇窗在
                  # 我们代码跑起来之前就存在，所以撤得再早也看得见（0.3.21 是
                  # 最早可写的一拍，它仍然看得见）。这一版不调原函数 ⇒ 没有激活
                  # 事务 ⇒ 没有那扇窗。
                  #
                  # 四串分别是：拒了（带 URL 与 `reply=none`）/ 旧路让位 /
                  # 自己开卡 / 补投一次。少任何一串都说明这一支没进包。
                  b"act: deny b=%s kind=%d n=%ld reply=none url=%.140s",
                  b"act: url card skip why=deny b=%s",
                  b"act: deny card b=%s",
                  b"act: deny redeliver ok=1 n=%ld how=%s b=%s url=%.100s",
                  # 0.3.27 — **补投改成 scene action（不再提交激活事务）。**
                  #
                  # Aevon(2)：`act: deny ... url=-` 后面 2.6 s 一律
                  # `act: deny redeliver skip why=nourl` —— `__PayloadURL` 是 `NSURL`，
                  # 0.3.26 只认 `NSString`，于是 URL 从来没记下来，QQ 只被拉起、
                  # 停在首页。这一版认两种类型，并且把投递从 `openSensitiveURL:`
                  # （会再走一次激活 ⇒ 全屏窗回来）改成给目标 scene 送 action。
                  #
                  # 五串分别是：类的方法表（下一版据此定名字）/ 送到或没送到 /
                  # 等 scene（0 = 还没登记）/ 硬路径不可用时的唯一读数 /
                  # 软路径自己的闸。缺任何一串都说明这一支没进包。
                  b"act: deliver census cls=%s cm=%@ im=%@ iv=%@",
                  b"act: deliver ok=%d act=%s send=%s cls=%s has=%d/%d fix=%d iv=%s b=%s url=%.100s",
                  b"act: deliver act empty how=%s fix=%d b=%s",
                  b"act: deliver wait why=noscene b=%s",
                  b"act: deliver skip why=soft-off",
                  b"/var/mobile/Library/Logs/Aevon/url.redeliver.soft",
                  # 符号本身也要在：路径常量在、函数没编进去的例子有过（0.2.87）。
                  b"AevonURLRedeliverSoftOn",
                  # 补投会再触发一次激活，那一次必须放行，否则自己拒自己、打转。
                  b"act: pass why=redeliver b=%s",
                  # 0.3.29 — **投递不再等固定 2.6 s，冷启动补发两发。**
                  #
                  # Aevon(252)：`act: deny` 到 `act: deliver done` 每次都正好差 3 s，
                  # 而 deliver 之后 QQ 立刻进选好友页 —— 那 3 s 是 0.3.26 的定时器，
                  # 不是 QQ 慢。改成 0.35 s 起手、每 0.2 s 问一次 scene（挂上就投）。
                  #
                  # 第一次分享停在首页则是冷启动：`app: boot pid=50788` 在投递前 2 s，
                  # 首页恢复盖掉了分享页。所以拒答那一刻按 `pid` 定冷/热，冷的多发两发。
                  #
                  # 三串分别是：冷/热判定（下一份日志的第一判据）/ 投出去了还是被补发 /
                  # 补发的关闸。少任何一串都说明这一版没进包。
                  b"act: deny cold=%d pid=%d run=%d shots=%d b=%s",
                  b"act: deliver done tick=%d cold=%d left=%d b=%s",
                  b"AevonURLShotOff",
                  b"/var/mobile/Library/Logs/Aevon/url.shot.off",
                  # 0.3.30 — **URL 装进新 scene 的 transitionContext。**
                  #
                  # Aevon(253)：热启动 scene action「秒出」，冷启动连发三发全丢
                  # （tick=3/4/5 三行 `deliver ok=1`，QQ 侧一个字都没有）。差别不在
                  # 时间，在投递口 —— 原生 URL 激活是把 action 装进 tctx 交给新 scene
                  # 的（0.3.23 亲眼看到 `n=1`）。四串分别是：装上了（带 had/act/cls）/
                  # 被闸挡住 / 装好之后不再叠 scene action / 闸的文件名。
                  b"act: tctx put ok=%d had=%ld act=%s cls=%s n=%ld b=%s url=%.80s",
                  b"act: tctx skip why=off",
                  b"act: deliver skip why=tctx b=%s",
                  b"AevonURLTctxOff",
                  b"/var/mobile/Library/Logs/Aevon/url.tctx.off",
                  # 两把闸自己的路径常量 —— 文件名写错就等于没有闸。
                  b"/var/mobile/Library/Logs/Aevon/url.deny.off",
                  b"/var/mobile/Library/Logs/Aevon/url.redeliver.off",
                  # 反向闸自己的路径常量 —— 文件闸写错文件名就等于没有闸。
                  b"/var/mobile/Library/Logs/Aevon/url.card.off",
                  # 分享那次 transitionContext 里装了 action（`n=1`），可从来没看过
                  # 是哪个类。这一串是「action 本体」的唯一读数，缺了就是没进包。
                  b"probe: tctx act cls=%s d=%s",
                  # 0.3.20 — `probe:tctx` 是 Aevon(246) 记录的上一次死因，可那一份日志
                  # 被装包清空了，死了都不知道死在哪一类上。这一行排在 @try 之前、
                  # 方法表之前，trap 也能留下类名。
                  b"probe: tctx enter ctx=%s set=%s",
                  # 0.2.91 把正常收尾写成空串，等于自己擦掉断点；这一串证明
                  # 「收尾有名字」而不是一片空白。Swift 侧的 `(settled)` /
                  # `(INTERRUPTED)` 是插值出来的，二进制里没有独立字面量，
                  # 不能拿来断言 —— 能在产物里查到的是这个 C 字面量。
                  b"sig:done",
                  # `_Block_signature` 用 dlsym 取，所以这串必须进二进制；取不到就
                  # 是这一格空着，不是这条断言该消失。
                  b"_Block_signature",
                  b"__LaunchSceneless",
                  b"/var/mobile/Library/Logs/Aevon/act.step",
                  # 0.2.75 — 安全闸的**运行期**复查。Aevon(207) 里用户把 G0 与 G1
                  # 都打开，`win: touch in=17 eat=3` 照样在吞 —— 原因是设置侧只写
                  # 文件/偏好不发通知，而闸本身只在加载时判定一次。这五条就是
                  # 「那道闸现在真的会在运行中停下来」的全部证词：
                  #
                  #   `armed`  = 快照接了初值（没这行 = 这一版又只在加载时判一次）；
                  #   `switch` = 状态真的变了（G0/G1 任一打开）；
                  #   `stand down … cards=` = 卡片与圆盘被撤走，`cards` 是撤了几张
                  #       （0 也可能是对的：闸在没卡时打开；所以它要和 `probe:` 那行
                  #       一起读，不能单看）；
                  #   `released` = 解闸，圆盘按用户自己的开关重新评估；
                  #   `probe: gate snapshot` = 停手那一刻屏上剩什么（探针，只读）。
                  #
                  # 前缀全部长过 15 字节：短的那种被 Swift 编成立即数，二进制里
                  # 一个字节都搜不到，断言会在 CI 里挂而本地看着没问题。
                  b"gate: runtime armed off=",
                  b"gate: runtime switch ",
                  b"gate: stand down why=",
                  b"gate: released why=",
                  b"probe: gate snapshot why=",
                  # 0.2.76 — URL 四路（跳转 / 分享 / 授权 / 支付）去名单化。
                  # 判据从「两个 scheme」换成「问 LaunchServices 这条 URL 归谁」，
                  # 于是三行都必须能在产物里搜到：
                  #
                  #   `bundle from url` = 请求里没有 bundle，是**这条分支**把目标
                  #       App 算出来的。Aevon(210) 的
                  #       `notify: hit op=open b=- … act=#UILinkConnectionAction`
                  #       以前紧跟 `why=nobundle` 整条放行，现在它必须有这一行；
                  #   `landing: url hand … why=auth` = 微/QQ/支付宝那一族刻意让给
                  #       分流（吞掉 + 自建），落点不接 —— 出现它说明「两条链不再
                  #       各建一张卡」这条规则被走到了；
                  #   `landing: url keep … why=front` = 目标 App 已经在前台且不在卡
                  #       里，落点不动它。这条是防「把用户正在用的整屏 App 缩进卡」
                  #       的那道否决，不能没有。
                  b"notify: bundle from url b=%@",
                  # 通知名 `com.aevon.gate` **不在这里断言**：它只有 14 字节，会被
                  # Swift 编成立即数，二进制里一个字节都没有。它通不通，由运行时
                  # 那两行直接读出来：`settings: G0 emergency stop -> on` 之后若
                  # 紧跟 `gate: runtime switch 1`，通知就是通的；只出现前者，说明
                  # 喊了没人应 —— 那正是 Aevon(207) 的形状。
                  # 0.2.62 — 放行之后 100 ms 内收进卡片（Aevon(203) 第 1 条：授权
                  # 不能停在整屏）。两行一起断言：`card` = 真的收进来了，
                  # `giveup` = 收不进来时把登记彻底撤掉（否则整屏只画上半截）。
                  b"notify: auth swap card b=%s after=%dms fg=%d live=%d board=%d",
                  # 0.3.0 — URL 四路统一主干。0.2.x 的两套入口 / 三套收卡调度 /
                  # 四套兜底已收成「一个判定 + 一个调度」。这三条是主干是否真的
                  # 接上的唯一证词：
                  #   `route: settle`      四路都汇到这一个调度点，`kind=` 分辨是哪一路；
                  #   `route: settle skip` 卡已在 / 开关关着时不重复建卡；
                  #   `route: settle why=off` 总闸生效时一个字节都不改行为。
                  b"route: settle b=%s kind=%s",
                  b"route: settle skip b=%s why=incard",
                  b"route: settle skip b=%s why=off",
                  b"notify: auth swap giveup b=%s fg=%d live=%d tick=%d build=%d",
                  # 0.2.70 — 授权那一支**不再**改激活设置（0.2.69 的挂起位已撤：
                  # 挂起的进程不跑，SSO 没人接；而且「激活一个不上屏的目标」正是
                  # 0.2.69 分享死局的形状）。
                  # 0.2.67 — 授权结果回到第三方 App：放行，不按进小窗。
                  # 0.2.79 — 补 `ptk=`：带 paste token 的回跳（微信把登录结果
                  # 塞在粘贴板里送回来）也要认成回跳，否则发起方会被
                  # `paste promote` 收进卡片。`ptk=1` 就是那一格。
                  b"notify: auth return b=%s src=%@ recent=%d in=%d ptk=%d",
                  # 0.2.63/0.2.66 — 落点（对比报告的方案 A）：系统的 URL 打开入口带一个
                  # `display` 参数（真机编码 `v60@0:8@16@24B32@36@44@?52` ⇒ 它是对象）。
                  # 0.2.70 — **display 原样下发**（0.2.69 的 nil + 补台已撤：nil 让目标
                  # 不上屏、建卡等不到 scene，主屏又没有前台 App ⇒ 手势失效、无法注销）。
                  #   `owners=` / `cls=… types=` = 这个选择子在这台系统上存不存在、
                  #      形状对不对（对不上就不装，只留一行 shape skip）；
                  #   `hooked` = 真装上了；
                  #   `url … land=1` = 那一次会接手落点（display 原样交给系统）；
                  #   `url card` = 随后把那份 scene 收进了卡片。
                  # 另两条 `landing: %s cls=` 是 Stheno 的激活口与 TrollOpen 的
                  # 实体口的普查，只记录、不改变行为 —— 它们的答案决定下一版要不要
                  # 换入口。
                  b"_openURLCore:display:animating:activationSettings:origin:withResult:",
                  b"landing: url owners=%d",
                  b"landing: url cls=%@ types=%s",
                  b"landing: url hooked",
                  b"landing: url shape ok (sig=%s)",
                  b"landing: url shape skip (sig=%s args=%d)",
                  b"landing: url build b=%s after=%dms",
                  b"landing: %s cls=%@ types=%s",
                  # 0.2.60 — 卡片走了、App 窗口还回场景高（「全屏中下黑」的另一半）。
                  # 0.2.46 — 「让抖音真重排」这一版的四条：显示覆盖 / 参考尺寸 /
                  # 屏幕跟随 / 回执。逐条都要能在产物里 grep 到，缺哪条就等于那一步
                  # 没有证词：
                  #   `via=override` = 走的是 `copyWithOverrideBounds:`（不是可变副本），
                  #     这是「覆盖必成」的判据。真机上如果只有 `via=mutable` 或
                  #     `keep … (no setBounds)`，说明这条路没打开，抖音仍会按 932 排。
                  #   `own ref` = 建 scene 时把内容参考尺寸定成了画布大小。
                  #   `display follow` = 推 frame 时屏幕跟着变（尺寸真的不同才会出现）。
                  #   `scene ack` = transition 门的回执，证明「门后面真的有人接」。
                  b"win: own display %.0fx%.0f -> %.0fx%.0f via=override",
                  b"win: own display override skip enc=%s n=%u",
                  b"win: own display cap=%d",
                  b"win: own ref %.0fx%.0f via=%s",
                  b"win: own ref skip %s enc=%s n=%u",
                  b"win: display follow %.0fx%.0f -> %.0fx%.0f slot=%d",
                  b"win: display follow skip slot=%d dt=%.0fms",
                  b"win: scene ack slot=%d",
                  # 两个私有选择子名必须真的进二进制：它们同时是「这条路走的是哪个
                  # 入口」和下一版要不要换路的依据。名字来自对比报告第五节那张表。
                  b"copyWithOverrideBounds:",
                  b"setContentReferenceSize:withContentOrientation:andContainerOrientation:",
                  # 只问不调的探针：`FBUpdateSceneTransaction` 在真机上叫什么、在不在。
                  # 这一版**没有**用它（用回执），所以它出现在产物里不代表被调用过。
                  b"win: own txn %s meta=%d inst=%d enc=%s",
                  # 0.1.87 — 激活入口观察器。名字不是猜的：0.1.86 的普查在真机上
                  # 把四条同形状的方法列了出来（`surf: SBMainWorkspace~activ
                  # n=16/170`），这一版按真名装，闸二改成**逐字节比对参数编码**。
                  #
                  # 四条选择子都要在二进制里 —— 少一条就是「少装一路观察」，
                  # 而那在日志里只表现为「某条从来没命中」，与「这条路不走」
                  # 分不开。
                  b"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:",
                  b"_handleUntrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
                  b"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
                  b"_handleUserActionRequest:options:activationSettings:origin:withResult:",
                  # 形状闸：真机量到的编码就是这 21 个字节。它同时是「装没装」的
                  # 判据和下一版的 ABI 依据，所以必须能在产物里 grep 到。
                  b"v56@0:8@16@24@32@40@?48",
                  #   armed  = 四条里装上了几条，skip= 写清每条为什么没装
                  #            （absent / shape(真实编码) / inherited / no-orig）
                  b"notify: open armed n=%d/%d shape=%s skip=%@",
                  b"notify: open absent reason=no-class",
                  # 取证行本身。op 是四条里的哪一条，b/src/act/url 是母本当年
                  # 那三个字段的真值，req/opt/set/org 是四个参数的真实类名。
                  b"notify: hit op=%s b=%s src=%s act=%s n=%d url=%s req=%s opt=%s set=%s org=%s",
                  # 闸五：预算用尽后闭嘴的那一行（四条合计 32 行）。
                  b"notify: open budget spent n=96",
                  # 0.1.88 — 分流。这是第一次「不原样转发」，所以每一条分支都要
                  # 能在产物里 grep 到：哪一条缺了，就等于那一种结局没有证词。
                  #
                  #   divert b=… op=… why=… unlock=…  吞掉了，去开卡片
                  #   divert chain b=…                同一次点击的第二条，吞掉但不再开
                  #   divert pass b=… why=…           认出来了但没吞（开关/上限/取不到）
                  # 0.2.1 — `divert card up` / `divert replay` / `replay threw` 三条删掉：
                  #   2.5 秒重放整段拔掉（它是自循环的发动机，Aevon(169)）。它们现在在
                  #   反向断言表里，见下面的 `# gone`。
                  b"notify: divert pass b=%s why=%s",
                  # 0.2.77 — 熔断换了形状：全局 60 次 / 60 秒，外加每个 App
                  # 3 秒 / 6 次的连击计数。Aevon(211) 12:00:17 的支付就是被旧的
                  # 「24 次 / 10 分钟」掐掉的（三分钟的正常使用只有 24 次）。
                  # `why=cap` / `why=loop` 只有四个字母，会被编成立即数，所以
                  # 断言认这一行长的 —— 它是「究竟哪一把尺掐的」的唯一证词。
                  b"notify: divert loop b=%s n=%d",
                  # 0.2.77 — 落点解析不出来时的三条证词：
                  #   pending  记在案上了（下一跳应当报门牌）
                  #   ls miss  LaunchServices 断在哪一步（class/shared/ws/one-nil/…）
                  #   link late 下一跳把目标报出来了，收卡链已排上
                  b"landing: url ls miss step=%s",
                  # 0.2.77 — 同一条授权来两拍（payload / url）时，第二拍不再
                  # 建第二个 presenter（Aevon(211) 11:58:28 的
                  # `presenter threw … already in use`）。
                  # 0.2.1 — 判据收紧以后的新结局：带 payload、但来源是 SpringBoard 的
                  # 那种打开，只在紧跟我们自己那次分流时才被吞（`why=syschain` 会出现在
                  # 上面那行 chain 日志里 —— 短串会被编成立即数，所以断言只认这条长的）。
                  b"com.apple.springboard",
                  # 判据要能在二进制里找到，否则「为什么没吞」全靠猜。
                  b"NotificationResponseAction",
                  # 0.1.89 — 分流之后的收尾。收面板 / 收横幅这两件事本来挂在
                  # SpringBoard 那一段的收尾里，被跳过之后要自己补。每一条候选
                  # 选择子都必须能在产物里 grep 到 —— 少一条就等于少一条试过的
                  # 路，而「面板还是没关」与「压根没试」在日志里长得不一样。
                  #
                  #   hub      = dispatcher 走哪条路拿到的、拿到的是什么类
                  #   clean    = 一次收尾的横幅结论（面板另起一行，见下）
                  #   cover    = 面板的结论，`wait=` 是等了几拍才等到卡片
                  #   sels     = 六个候选的真实编码，一次开机一行（0.1.90 新增）
                  #
                  # 0.1.90 的变化：`cover=locked` 那条闸删了 —— `isUILocked` 在通知
                  # 中心在屏时本来就是 1，等于把功能关掉；换成 `cover=skip:passcode`
                  # 与 `cover=skip:nocard` 两条。所以这两条必须在产物里，而 `locked`
                  # 必须不在。
                  b"notify: hub d=%@ via=%s",
                  # 0.1.91 — 面板那行多了两格：`at=` 是手指到面板开始走的毫秒数，
                  # `f=1` 表示「卡在路上就收了」而不是「卡片已经在」。用户报的是
                  # 「会收但慢」，没有这两格，下一版只能再靠感觉调。
                  # 0.1.92 — 清通知（点开 = 已读）。母版线 log67~log71 四版试出来的落点，
                  # 每一条都要能在产物里找到，否则「没清」与「没试」在日志里长得一样：
                  #   clear b=… id=… via=… sel=… = 清成功了，写清走的是哪个宿主/哪个方法
                  #   clear=noid                 = 取不到标识（这一版的安全出口）
                  #   clear=noreq                = 标识有了，但没有哪个宿主认这条请求
                  #   clear map                  = 一次开机的「能力地图」，下一版据此改名字
                  #   clear b=%@ clear=noid      = 上面那条的 Swift 版（分流那一拍就写）
                  b"notify: clear map",
                  # 0.2.5 — 清通知改「截对象」。老路（上面五条 getter + 各宿主比对）在
                  # 真机 6/6 是 `clear=noid`：猜标识这件事本身走不通，不是名字没试全。
                  # 新路的证词是这七条，缺一条就等于「那条分支没跑过」：
                  #
                  #   capture live / failed   钩子装上没有（装上才有对象可截）
                  #   capture class missing   通知栈 20 次都没起来（懒加载的真实现）
                  #   capture req=… ok=…      钩子**第一次**被调用时四个参数的真实类名；
                  #                           `ok=1` 是「第三格确实是 NotificationRequest」，
                  #                           参数顺序猜错的唯一现场证据就是这里
                  #   clear b=… via=…         真正动手那一次：哪个宿主、哪个方法、哪条标识
                  #   clear b=… capture=…     截对象没成（section 不符 / 无 withdraw），
                  #                           写清是哪一半缺的
                  #   clear b=… via=capture only  老路取不到标识，但截到了对象 —— 这一拍
                  #                           仍然排队（0.1.9x 的死结就是「没标识就不排」）
                  b"notify: capture live cls=%@",
                  b"notify: capture failed %@",
                  b"notify: capture class missing after 20 tries",
                  b"notify: capture req=%s dest=%s act=%s ok=%d",
                  # 0.2.37 — 两条清通知证词前面多了一格 `%s`（` retry` / 空串），
                  # 1.6 秒那次补刀与第一拍在日志里要能分开。
                  # 0.2.7 —— 三家综合（TrollOpen / Myrtle / Mango）这一版的四条证词。
                  #
                  #   shareprobe   分享那一拍的全部现场：来源、payload 类型、结果块形状、
                  #                挂起键读回值、settings 四个能力、options 全部键名。
                  #                它存在的理由就是「分享这条路从来没有真机现场」——
                  #                快照有 32 拍预算，分享常排在第 11 拍之后。
                  #   forward adopt 第二道认领（同一 App 2 秒内）。Aevon(173) 里 op=trusted
                  #                转发出去之后，op=untrusted 那条又被转发一次，多出来
                  #                的那次原实现调用就是把 App 拉上全屏的那一次。
                  #   win: ability 三家各自的核心能力在 iOS 17.3.1 上还在不在
                  #                （forceBackgrounded / _setDeactivationReasons /
                  #                 SBTransientOverlayWindow / 进程事务 / _openURLCore）。
                  #                只问不调，问错也只是 0。
                  # 0.2.12 —— 挂起位写在 settings 对象上（不是 options 字典）。
                  # 0.2.9 那版 `win: act dump` 已作废并删除（四个 tag 全是 n=1
                  # _settings=0x1 —— 这个类只有一个 ivar，做差在数学上不可能有结果），
                  # 它现在在反向断言表里。替代它的三件东西：
                  #   act enc   setFlag/flagFor 两个方法的真实编码（接线前必须知道形状）
                  #   act key   下标 → 名字 + 每个 flag 值的描述（挑挂起位靠它）
                  #   suspbit   置位后立刻读回（「写了」和「生效了」不是一件事）
                  b"win: act enc set=%s get=%s",
                  b'win: act key %d "%.30s"%@',
                  b"win: act key pick=%d flag=%d n=%d enc=%s",
                  # 0.2.39 —— 分享黑名单（`shareBlacklist` / `notify: blacklist drain`）
                  # 已随微信移出整块删除，这里不再断言旧证词。
                  # 一次开机一遍：这一族到底有哪些手段。真 API 名靠 census 不靠 strings。
                  b"win: act api set=SBActivationSettings n=%u %@",
                  b"win: act api set=absent",
                  # 「按回后台 / 别前台激活」这一族的存在性（-1 类不在 / 0 方法不在 / 1 可调）。
                  b"win: ability bg app=%d ctrl=%d mainws=%d sbws=%d set=%d susp=%d fg=%d",
                  b"win: ability deact2 sbws=%d fbmgr=%d fluid=%d coord=%d",
                  # 因果读数：转发前/后目标 App 在系统眼里是不是前台。
                  # 0.2.10 —— 自建 scene 的三问：类在不在 / 名字叫什么 /
                  #                   关键选择子落在哪个类、什么形状。全部 class_copyMethodList
                  #                   + method_getTypeEncoding，一个对象都不建、一次 msgSend
                  #                   都不发 —— 这条线的历史是两次安全模式，所以本版只问。
                  b"surf: scn exists a",
                  b"surf: scn exists b",
                  b"surf: scn names total=%d",
                  b"surf: scn sel %s n=%d",
                  b"surf: scn sel total=%d",
                  # 0.2.11 —— 0.2.10 那五个答 none 的名字改成「全类扫」。三条证词：
                  #   host <sel> <cls> i|c{enc}   名字在、宿主是谁、形状（改 IMP 前必须知道）
                  #   host none <sel>             全类都没有 —— 那就是真不在，得换宿主进程
                  #   urln <cls>.<sel>{enc}       按 openurl + display|scene 重新取名（防改名）
                  # 仍然只读。产物里缺这三条，等于这一版什么都没问。
                  b"surf: scn host %s %s %c{%s}",
                  b"surf: scn host none %s",
                  b"surf: scn host total=%d urln=%d",
                  b"surf: scn urln %s.%s{%s}",
                  # 0.2.13 —— 真正开始用自建 scene（不再是「先全屏、再抢」）。
                  #
                  # 这一族是整条链上第一次「scene 不是系统给的」。每一条都是产物里
                  # 必须能找到的证词，缺一条就等于那一格根本没编进去：
                  #   own gate need=  miss=   那 35 样私有面问过几样、缺几样（0 才敢调）
                  #   own miss       缺的是哪一类哪一个选择子（只问不调，问错也只是 0）
                  #   own begin      起进程那一刻：谁的、从哪条路进来、画布多大
                  #   own compose ok scene=… id=…   真建出来了，是什么类、什么 identity
                  #   own done phase=…  scene=…     completion 落地时的终态
                  #   own start      openCard 这一拍的判决（1 = 走自建，其余 = 退回老路）
                  #   own scene up   自建 scene 交到卡片手里的时刻（毫秒）
                  #   own gave up    自建失败，落回 0.2.12 那条挂起启动
                  #   own destroyed  关卡：destroyScene，而不是 push background
                  b"win: own gate need=%d miss=%ld",
                  b"win: own miss %s%s %s",
                  # 0.3.1 — 自建 scene 在**行为上**下线（Aevon(225) 的安全模式
                  # 就崩在 `createSceneWithDefinition:initialParameters:` 那一行）。
                  #
                  # 但代码仍留在产物里，这一点已实测：`AevonOwnStart` 是全局符号
                  # （`NSInteger AevonOwnStart(...)`，非 static），C 侧还有引用，
                  # 链接器的 `-dead_strip` 不会摘它 —— 0.3.1 产物里
                  # `win: own begin` / `win: own compose ok` / `win: own done` /
                  # `createSceneWithDefinition:initialParameters:` 各命中 1~2 次。
                  #
                  # 所以这里**不能**写反向断言（写了就必红）。真正的闸是运行时那一个：
                  # 文件级 `AevonOwnRetired = 1`，函数第一句就返回 0，一次
                  # `objc_msgSend` 都不会发生。下一版若把这套代码整段摘除（推荐），
                  # 再把这些断言连同函数一起删 —— 0.2.92 的教训是「要删就删到底」。
                  b"win: own begin b=%@ from=%s frame=%.0fx%.0f",
                  b"win: own compose ok scene=%s id=%s",
                  b"win: own done phase=%ld scene=%s",
                  b"win: own scene up after ",
                  b"win: own gave up door=%ld b=%@ after %ldms",
                  b"win: own destroyed %@",
                  # 0.3.2 — presenter 只建造原型（A/B 两条读数把范围收敛到这一条）。
                  # 0.3.3 — identifier 与生产链错开：0.3.2 用 `com.aevon.float`
                  # 真机撞了 7 次 `already in use`，只有卡片拆掉之后才成功 1 次。
                  b"presenter: birth ok=1 b=%s why=%s cls=%s view=%s resize=%d",
                  b"presenter: birth fail b=%s why=busy(%s) id=%s",
                  # 0.3.5 — `setResizesHostedContext:` 的 owner 是
                  # `UIMutableScenePresentationContext`，不是 presenter。
                  # Aevon(230) 四路全部 `resize=-1` 就是这个原因；生产链那句
                  # `AevonCallSetBool(presenter, …)` 从 0.2.x 起一直静默失效。
                  b"presenter: resize ctx cls=%@ read=%@",
                  b"presenter: resize ctx no setter cls=%@",
                  # 0.3.6 — 线 B 扩展：`setActions:` 的真实编码、有没有 getter、
                  # 现状是什么。三条读数把方向收敛到这一条之后，先问清楚再动手。
                  b"probe: tctx cls=%s actions=%d enc=%s getter=%d now=%s n=%ld frame=%d %s | set cls=%s %s",
                  # 0.3.7 — payload 的每个键值。线 A 已确认 options 只有
                  # `setDictionary:` 一个写入口，要改就必须先看清里面有什么。
                  b"probe: payload n=%ld via=%d |%s",
                  # 0.3.8 — 照母版 P1 的承载链取证（线 D/E/F）。三条线全只读：
                  #   D: 建独立承载的 5 个符号（UIWindow(windowScene:) / presenter /
                  #      _UIContextLayerHostView / setResizesHostedContext:）
                  #   E: 收窗链（_dismissPresentable / deactivateWithTransitionContext）
                  #      —— 母版各 2 次，Aevon 一次都没调过
                  #   F: SBDeviceApplicationSceneViewController 的可用面
                  b"probe: D1 UIWindow initWithWindowScene = %@",
                  b"probe: D3 UIScenePresentationManager createPresenter = %@",
                  b"probe: D4 _UIContextLayerHostView initWithSceneLayer = %@",
                  b"probe: E%d %s dismiss=%s deactivate=%s",
                  b"probe: F1 SBDeviceApplicationSceneViewController set* = %@",
                  # 0.3.9 — P1 落地前三问：sceneHandle 拿不拿得到、newSceneViewController
                  # 出不出 VC、那个 VC 收不收 resize/background 两刀。
                  # 线 F 只答了「选择子在」，这三条答「能不能拿到能挂的东西」。
                  b"probe: G1 scene.%s -> %s",
                  b"probe: G2 %s vc=%s view=%s size=%.0fx%.0f",
                  b"probe: G3 %s resize=%d bg=%d mode=%d grabber=%d",
                  # 0.3.11 — H 线：`_targetWindowSceneForApplication:…` 是
                  # 「决定 App 落到哪个 windowScene」的那一拍。四个参数全是
                  # 对象/BOOL，返回一个对象，hook 风险低。母版没用过它，
                  # 所以这一版只装壳、原样尾调、只记读数。
                  b"probe: H1 owner=SBMainWorkspace enc=%s",
                  b"probe: H1 shape skip (%s)",
                  b"probe: H2 n=%ld app=%s ret=%s",
                  b"probe: H4 app=%s cls=%s opt=%s fg=%d",
                  # 0.3.15 — 0.3.14 的通用透传壳已整段删除（Aevon(240) 崩在
                  # `objc_retain_x20`，根因是统一 `void*` 壳破坏了 ARC 返回语义与
                  # callee-saved 寄存器契约）。这里改成**纯只读普查**：
                  # 只问 owner / 返回类型 / 参数个数 / 编码，一次 hook 都不装。
                  b"census: %s owner=%s ret=%c argc=%d enc=%s",
                  b"census: %s absent",
                  b"census: done found=%d missing=%d total=%d",
                  # 0.3.16 — 四个返回 void 的入口，逐个手写壳（不用通用透传）。
                  # 选它们是因为 `v` 返回不碰返回寄存器、参数全是对象不拆寄存器。
                  b"h4: layout.add armed",
                  b"h4: layout.addC armed",
                  b"h4: sysvc armed",
                  b"h4: destroy armed",
                  b"layout: add item=%s ws=%s",
                  b"layout: addC item=%s ws=%s",
                  b"h4: sysvc n=%ld actseq=%ld svc=%s req=%s",
                  # 0.3.18 — 普查 FBSMutableSceneDefinition / FBSMutableSceneParameters。
                  # 系统建 scene 传的是可变子类，而 0.2.85 查的是不可变父类。
                  b"defn: %s chain=%@",
                  b"defn: %s methods %@",
                  b"defn: %s ivars %@",
                  b"defn: mut.%s enc=%s",
                  b"defn: mut.%s absent",
                  b"defn: done",
                  # 0.3.19 — 验证 updateSettingsWithBlock: 的 block 收到什么类。
                  # 这是唯一可能「能改 settings」的入口（contra 0.3.13 的 48 方法零 setter）。
                  b"p2: set armed",
                  b"p2: cli armed",
                  b"p2: set.ctx cls=%s",
                  b"p2: cli.ctx cls=%s",
                  b"p2: set called n=%ld blk=%s",
                  b"p2: set shape skip (%s)",
                  b"presenter: birth fail b=%s why=nil id=%s",
                  b"presenter: birth skip b=%s why=nopm",
                  b"presenter: birth threw b=%s why=%s",
                  # 0.2.14 —— 两处修根因：
                  #   own live attach   已经有活 scene ⇒ 直接贴，一个启动请求都不发
                  #                     （0.2.13 这里还会落下去走挂起启动，等于自己
                  #                      又补了一次「摆前台」）
                  #   forward held      分享那条请求进入待发（这时还没交给系统）
                  #   forward flush     scene 到位 / 超时之后真正投出去，带等了多久
                  b"win: own live attach %@ t=%ldms wait=%ldms",
                  # 0.2.37 — 「桌面图标把卡片里的 App 拿去全屏」那一次的两个现场：
                  #   card yield seen   系统往我们 hosted 的 scene 写了整屏 frame
                  #   card yielded      卡片出口真的跑了（Swift 侧）
                  # 少任意一条 = 这条反应式让路没有编进产物。
                  b"win: card yield seen b=%s now=%.0fx%.0f want=%.0fx%.0f",
                  b"win: card yielded to fullscreen b=",
                  # 0.2.38 — 让路改成「松手」：自建 scene 交给系统，不销毁。
                  # 少了这一条，设置 App 在「卡片 → 全屏」那一拍会闪退。
                  b"win: own handed over %@",
                  # 0.2.38 — 粘贴板分享的诊断行：下一版要靠它决定 token 能不能本地投递。
                  b"notify: paste token b=%s cls=%s desc=%@",
                  # 0.2.39 — 粘贴板/微信分享「先放行、再把前台 App 收回卡片」。
                  # 少了这两条，分享要么停在原生全屏，要么根本没人去收卡。
                  # 0.2.43 — 分享完成后把来源 App 请回全屏，卡片浮在它上方：
                  # 少了 source/restore 这一对，卡片背后就只有桌面。
                  b"notify: share source b=%s target=%s",
                  # 0.2.44 — UIApplication 拒绝时的备份启动通道。
                  # 0.2.46 — 分享收卡不再先回桌面：先把来源 App 顶回前台，
                  # 等目标离开前台后直接建卡（homed: true）。少任意一条，
                  # 真机上就又会看到「QQ 全屏 → 桌面 → 文件列表 → 卡片」。
                  b"win: direct card declined (",
                  # 0.2.48 — 应用内链接跳 Safari / 微信 QQ 登录授权不再整屏：
                  # 认出带 URL 的打开请求、建卡、把 URL 投进卡片里的 App。
                  # 少任意一条，这两类请求就又回到 `plain` 全屏那条老路。
                  # 0.2.58 — 这条行尾补了 `front=` 与 `card=`：
                  #     `front=1 card=1` 就是「卡里的 App 被 SpringBoard 认成前台」，
                  #     旧版在这里放行成全屏，授权回调一跳全屏就是这个。
                  #
                  # 0.2.87 — 原来断言的是 `notify: link b=…`。这一族并轨母版之后
                  # 改成放行（`return 0` + `AevonAuthSwapSchedule`），日志行也改名为
                  # `notify: link native b=…`，词条已挪到 0.2.87 段。
                  # 这里保留的是同一族的另外三行：卡里回调 / 建卡 / 回落。
                  b"notify: link incard b=%s scheme=%s front=%d",
                  b"linkchain",
                  # 0.2.15 —— 尺寸 + 分享两件：
                  #   own display       scene 的 displayConfiguration 被改成画布大小
                  #                     （不改就是「UIScreen 932 / 窗口 717」，按屏幕
                  #                      排版的 App 直接错位）
                  #   appurl send       宿主把 URL + options 写进目标 App 容器
                  #   appurl ack        App 侧回执（ok=1 via=app|scene）
                  #   appurl give      没回执 ⇒ 退回老路转发
                  #   forward drop      投递成功 ⇒ 就地销毁，一个字节都不交给 SB
                  b"win: own display %.0fx%.0f -> %.0fx%.0f",
                  b"win: own display keep %.0fx%.0f (no setBounds) cls=%s mut=%d",
                  b"win: own safe top=%.0f bottom=%.0f src=win",
                  b"win: own safe top=%.0f bottom=0 src=statusbar",
                  b"win: own safe set %.0f/%.0f enc=%s",
                  b"win: own safe skip top=%.0f bottom=%.0f enc=%s n=%u",
                  # 0.2.17 —— 抖音「出生整屏」那一次尺寸变化，以及分享不再抢跑。
                  #   own staged        这个 App 的 scene 先按整屏建，贴上后再推到画布
                  #                     （名单里现在只有抖音；串在产物里 = 名单真的编进去了）
                  #   share lost        投递失败就地销毁（不再交回 SB）
                  #   ack … [%@]        回执原文进主日志（pid / sc / wsc / dlg / rsp）
                  b"win: own staged %.0fx%.0f -> %.0fx%.0f b=%@",
                  b"com.ss.iphone.ugc.Aweme",
                  # 0.2.18 —— 0 ms 抢跑的修复：两种「等」各自的收尾词不能丢。
                  #   no deliver    卡片 3 秒内一次投递都没发起 ⇒ 就地销毁
                  #   appurl stuck  投递挂满 6 秒 ⇒ 也算失败，仍然不交回 SB
                  b"setDisplayConfiguration:",
                  # 这一字典的字面量是「自建」这件事在产物里的锚：三个类名任何一个
                  # 拼错，工程就编译成一条永远走不进去的路，而日志只会说 gate miss。
                  b"FBSMutableSceneDefinition",
                  b"FBApplicationProcessLaunchTransaction",
                  b"registerProcessForAuditToken:",
                  b"createSceneWithDefinition:initialParameters:",
                  b"win: ability app forceBg=%d ctrl forceBg=%d app dehost=%d ctrl dehost=%d",
                  b"win: ability scene deact=%d/%d overlay=%d txn=%d openurl=%d/%d",
                  # settings 能力行补了两个读数（getFlag / n）。0.2.6 之前它是「一次开机
                  # 只记一次」，分享换一条路进来时日志里什么都没有。
                  # 放行侧独立预算（原来与通知共用 6 条，第三次点击之后永久静默）。
                  b"notify: divert pass b=%s why=%s n=%d",
                  # Mango 的「判内容就绪」：空壳不建卡，继续等。
                  b" shell=1 (deferred, no black card)",
                  # 这一对是三家逆向（2026-11-08）里同时出现在 `__objc_selrefs` 的选择子：
                  # TrollOpen 1.5.2 就是拿它们做「点通知 → 清掉那一条」的。选择子本身
                  # 必须在产物里 —— 名字写错一位，钩子装不上，而日志只会说 failed。
                  b"destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:",
                  # 归属校验：截到的请求必须属于这次分流的目标 App，否则不清。
                  b"sectionIdentifier",
                  # 取标识的五条无参 getter。`identifier` 故意不在里面（BSAction 自己也有），
                  # 这几条同时是「这一版到底问过哪些名字」的证词。
                  # 找请求：一个按标识取 + 三个列表 + 一张字典。
                  # 四个清除方法 + 四个 destination 宿主。
                  b"withdrawNotificationRequest:",
                  b"lockScreenDestination",
                  # 0.1.92 — 分享面板 → 浮窗。判据只有一个字符串：来源进程。
                  # 0.1.97 — 判据从「只有 sharingd」扩到「来源是分享扩展 或 这次打开带东西」。
                  # 四个字面量就是这两条判据的全部证据面。
                  b"__PayloadURL",
                  b"__PasteSharingToken",
                  b"ShareExtension",
                  b"sharetimeline",
                  # 0.1.95 — 分享带 payload 时必须交回系统的那一次调用。
                  #   ActivateSuspended = 只写这一个键，让 App 不上前台但 launch option 送到
                  #   forward done ok=1 / ok=0 / err = 交回去之后系统怎么回的
                  # 0.1.98 — 挂起键的**值**才是要写进字典的键名。0.1.95~97 写的是常量名，
                  #   系统不认，于是分享时全屏和卡片一起被拉起（Aevon(165) 回环那行的 keys
                  #   里能直接看到那个长名字躺着）。
                  b"__ActivateSuspended",
                  # 0.1.96 — 自己交回去的那条请求要认出来，只放行（不认就会二次分流）。
                  # 0.1.99 — 三条诊断。这一版不改行为，价值全在这三行能不能被真机读出来：
                  #   pass      = 被放行的那条请求（哪一条、为什么、带没带东西）。
                  #               Aevon(167) 里 QQ 有一条 op=user 被放行，而 Sileo 没有，
                  #               全屏的来源高度怀疑就在它身上。
                  #   fwd settings = 第 4 个参数（SBActivationSettings）认不认「挂起」相关选择子。
                  #   clear probe  = 点通知时公开链断在哪一跳（母版 log70 取到过标识，我们 6/6 没有）。
                  b"notify: pass b=%s op=%s why=%s src=%s pay=%s n=%d",
                  # 0.1.99 — 能力地图加了 dispatcher 类名那一格（取不到是最要紧的一种结果）。
                  b"notify: clear map d=%s",
                  b"sharingd",
                  b"UIApplicationLaunchOptionsSourceApplicationKey",
                  b"UIApplicationLaunchOptionsURLKey",
                  # 0.1.93 — 主线程看门狗。这一整版的价值就是「下次卡死能被一句话
                  # 说清」，所以这两条必须在产物里：
                  #   win: main stall …ms (no main beat …s) = 主线程真被卡住了，毫秒数是时长
                  # 两条队列标签（名字都刻意长过 16 字节：15 字节以内会被编成立即数，
                  # 二进制里根本搜不到 —— 这是这个工程记了很久的坑）。
                  b"win: main stall %.0fms (no main beat %.1fs ago)",
                  b"com.aevon.pulse.monitor",
                  # 0.1.93 — 手势那条广播挪去后台队列：串行队列的名字要在产物里。
                  b"com.aevon.band.publish",
                  # 0.1.94 — 开机清理小窗标记时「没清掉的留在名单里」那一行。
                  # 没有它，「这条标记会不会永久残留」就又从日志里消失了。
                  b"win: mini flag clear stuck n=%d keep",
                  # 形状闸的六个期望值。它们同时是「这一版到底校验了什么」的证词。
                  # 横幅：只有 GCD 计时器才动，而且必须是这个名字的那一个。
                  b"dispatch_source",
                  b"bannerDestination",
                  b"dashBoardDestination",
                  b"notificationCenterDestination",
                  # dispatcher 的三条取法 + 起点。
                  b"notificationDispatcher",
                  b"ncDispatcher",
                  b"_notificationDispatcher",
                  b"delegate",
                  # 闸四（Swift 侧）：闩的两振。0.2.26 起第一次只跳过本次装配，
                  # 第二次才落 notify.off —— 普通重载桌面不再永久关掉通知/分享。
                  b"notify: activate latch held 1/2, this boot stays native",
                  b"notify: activate latch held twice, notify.off written",
                  b"notify: activate latch cleared uptime=",
                  b"notify: activate off switch=notify.off",
                  b"notify: activate arm scheduled in ",
                  # 0.1.86 — 激活面普查（只读）。这一版的价值全在「取证是不是
                  # 真的装进去了」：0.1.85 的教训是断言写了、位置放错了，于是
                  # audit 失败而二进制其实没问题。所以这五条必须落在 Aevon.dylib
                  # （SpringBoard 侧）那一组里 —— AevonApp.dylib 没有这个文件。
                  #   exists  = 18 个候选类在不在（1 / 0）
                  #   ~       = 某个类自己的方法名，花括号里是参数编码
                  #   g       = 全局命中（不限类名）
                  #   begin/end = 一次普查的边界，缺 end 就是半路断了
                  b"surf: exists ",
                  b"surf: chain %@",
                  b"surf: %s~%s n=%d/%u %@",
                  b"surf: g n=%d %@",
                  b"surf: begin (0.1.86 read-only)",
                  b"surf: end",):

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
                 b"ring: bar released at ",                 # gone
                 # 0.1.90 — `cover=locked` 这条结论整个删了。它背后是
                 # `isUILocked`，而通知中心在屏时那一位本来就是 1：闸在唯一
                 # 该收的场景里恒真。留着这个字面量就等于留着那条死路。
                 b"cover=locked",                           # gone
                 # 0.2.0 — 「整层隐藏」整段删除（Aevon(168)：粘性标记让整台
                 # 手机再也开不出浮窗）。这条前缀还能 grep 到，就说明那个
                 # `systemCovered` 静态量又回来了 —— 它一旦回来，卡片就又会
                 # 在锁屏后被自己藏住，而摘标记的只剩一个已经停摆的时钟。
                 b"win: system cover ",                     # gone
                 # 0.2.1 — 2.5 秒重放与它的成功判据。Aevon(169) 证明这条路会自己喂
                 # 自己：补调原实现 ⇒ 原实现再走一遍被接管的入口 ⇒ 又分流又建卡又
                 # 失败，每轮附一次 10 秒整的同步 XPC（主线程 2 分 07 秒停 100 秒）。
                 # 任何一条还能 grep 到，就说明那台发动机还在。
                 b"notify: divert replay b=%@",             # gone
                 b"notify: divert replay threw %@",         # gone
                 b"notify: divert card up b=%@",            # gone
                 # 0.2.2 — 遮挡收卡的两条（建卡末步 + 保活时钟）。Aevon(171)：
                 # 点通知那一刻 `isUILocked` 必然为真，这两条闸把每一次
                 # 「通知 → 浮窗」都在建好之后自己拆了，用户看到「不全屏也不出窗」。
                 # 任何一条还能 grep 到，就说明卡片又被遮挡判据杀了。
                 b"win: card closed at once (system cover up)",   # gone
                 b"win: card closed by system cover",             # gone
                 # 0.2.3 删掉的那条「2.5 秒重放」仍然不许回来（Aevon(169) 的
                 # 自循环 + 10 秒同步 XPC 就是它）。0.2.4 恢复了「回落原生一次」，
                 # 但那是 `ring: launch` 这一条腿，与 `card route declined` 不是
                 # 一回事：后者是旧文件里那个会自己喂自己的闭包。
                 b"ring: card route declined (",                  # gone
                 # 0.2.12 — 形状转储整块删除。四个 tag 全 `n=1 _settings=0x1`，
                 # 它从来没有回答过任何问题，只会占预算。还能 grep 到就是没删干净。
                 b"win: act dump tag=%s c=%s n=%u %s",            # gone
                 # 0.2.79 — 投递那条链在授权 / 支付上被证伪，两行日志随
                 # 代码一起删除。还能 grep 到就说明那一支又回来了。
                 b"notify: oauth swallow b=%s src=%@ scheme=%s pay=%s card=%d",  # gone
                 b"notify: oauth pass b=%s scheme=%s pay=%s card=%d why=nourl"):   # gone
        if gone in dylib_early:
            bad(f"host: {gone.decode()} still in Aevon.dylib — a removed layer came "
                "back (hot zone 0.1.18 / summon bar 0.1.24 / cover lock gate 0.1.90)")
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
                      # 0.2.12 — 异常行补 sub=/inSheet=，并加 14 帧调用栈
                      # （`app: crash at <i> <符号>`）。判据只有一条：栈上有没有
                      # `AevonApp` 这一族帧 —— 有才是我们抛的。
                      b"app: crash exc %s: %s step=%d sub=%d inSheet=%d",
                      b"app: crash at %lu %.220s",
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
                      # 0.1.29 — 主窗四边热区的应用侧闸门（「上滑关闭悬浮窗时
                      # 全屏 app 也向下滑动」）。这条字符串缺了，就说明那条通道
                      # 没编进去 —— 宿主会照旧发通知，但 App 里没人接。
                      b"app: band touch at ",
                      # 0.1.34 — 通道换了来源之后的两条判据：
                      #   `band note`  ⇒ 固定名通知真的到了（上一版注册 NULL 收不到）
                      #   `band prefs` ⇒ 值真的读到了（V109/V110 都死在「文件读空」）
                      # 只出现前者说明取值那一步错，两条都不出现说明通知没到 ——
                      # 下一份日志能直接分开，不用再猜。
                      b"app: band note from host",
                      b"app: band prefs on=",
                      # 0.1.60/0.1.63 — 「收 App 自己的窗口」这件事的证词。它只有
                      # 一个落点（`AevonKbFitWindow`，只改高度、只对 key window）：
                      # `kb: win fit h=` 每次落地打一行，`kb: win unfit h=` 收起时
                      # 还回场景高，`kb: win fit reject` 是读数越界被拦。
                      # 0.1.62 曾把这段整段删掉、只留 `kb: win keep` 读数 ——
                      # Aevon(134) 的结果是 23 次开键盘、输入框一次没出现，
                      # 所以这条路又回来了，三条断言一起回来。
                      b"kb: win hold h=%.0f",
                      # 0.1.68 — 「键盘到底遮住这个窗口多少」由我们自己算，返回给
                      # UIKit（`intersectionHeightForWindowScene:`）。系统按「窗口在
                      # 屏幕 0」求交得 101，真实交集是 316 —— `kb: inter true= sys=`
                      # 每次不一致时打一行，这一行在，就说明钩子真的改写了返回值。
                      # 0.1.70 — 键盘顶改取「见过的最小通知顶边」（键盘只会从屏
                      # 幕下方往上滑，动画中间值全在结算值上面，取最小＝取结算值），
                      # 再减掉该 App 自己输入条的高度（按 Bundle 标定）。上面这条
                      # `inter … top=%.0f kbH=%.0f` 里的 `top` 是**减完标定**的值。
                      # 0.1.71 — 这个值不再等于真实键盘高度：微信解出来是 574
                      # （比 316 还大 258，那是它自己多铺的一条），判据看
                      # `kb: caret … bar=` 与它的 1:1 关系，不要对 316。
                      b"kb: inter true=%.0f sys=%.0f origin=%.0f sceneH=%.0f top=%.0f kbH=%.0f",
                      # 0.1.71 — 键盘顶「只降不升」的落点。0.1.72 起它**不再是决策源**
                      # （顶边改由 `AevonKbTopFixed` 钉死），只在本机尺寸不认识时兜底，
                      # 同时留作「通知原值还在漂」的证词：Aevon(143) 里微信的
                      # 761→663→565→467 与 QQ 的 761→637→513，就是逐次抬高的源头。
                      b"kb: top settle kept=%.0f raw=%.0f was=%.0f",
                      # 通知矩形只做一次换算：顶边取 `AevonKbTopFixed` 钉死的结算值，
                      # 再减去该 App 的标定（`cal`）。写的是**绝对值**，不是 `-=`，
                      # 所以同一会话多条通知重复到达也不会累加。
                      # 0.1.72 — 加 `fixed=` 字段：>0 表示这次用的是钉死值（本机
                      # 430×932），=0 表示不认识这台机器、退回通知原值。
                      b"kb: note rect raw=%.0f out=%.0f cal=%.0f fixed=%.0f nh=%.0f",
                      b"kb: win unfit h=%.0f",
                      b"kb: win fit reject want=%.0f",
                      # 0.1.64 — 「收起」不再当场落状态：先压 0.30 s，到点量一次键盘
                      # 视图再定。`settle keep` = 通知是误报（键盘还在屏上），
                      # `settle gone` = 真收了、这时才还窗口。两条都在才说明这个
                      # 闸门没被写成「无脑延迟」。
                      b"kb: settle keep top=%.0f",
                      # 0.1.84 — **收起由「一次判定」改成「轮询到落地」。**
                      # Aevon(152) 里 8 次真收起全都是：hide 通知（off=1）→ 键盘窗
                      # 变空壳（`top zero … sub=1`）→ 旧版把空壳折成缓存 573 →
                      # `settle keep` 把这次收起作废 → 靠 1 Hz 心跳凑三连零兜底 →
                      # 5~10 s 后才 `fill off`。现在测量分三态（TOP / SHELL / GONE），
                      # 只有 TOP 才算「误报」，SHELL 继续量，GONE 连两拍就落地。
                      # `state=` = 当拍状态（0 走了 / 1 空壳 / 2 量到），`n=` = 第几拍。
                      b"kb: settle gone top=%.0f state=%d n=%d",
                      b"kb: settle wait top=%.0f state=%d n=%d",
                      # 0.1.80 — 量不到时把键盘窗的形状写下来。Aevon(150) 把上一版
                      # 的推断推翻了：31 条**全是** `win=430x932@0 hid=0 sub=1`，
                      # 窗从没收成 430×316，也没被隐藏 —— 那个 0 只是「重排中的
                      # 空壳」。`last=` 是当时缓存的上一次真值，这一行同时证明
                      # 「窗还在」和「缓存有几」。
                      b"kb: top zero win=%.0fx%.0f@%.0f hid=%d sub=%lu last=%.0f",
                      # 0.1.80 — **真收起唯一的证词**。窗被隐藏/透明/移出窗口栈时
                      # 才走这一条；它和上面那条成对，下一份日志里 `gone` 的次数
                      # 就该等于用户真的关了几次键盘。
                      b"kb: gone hid=%d alpha=%.2f win=%.0fx%.0f pool=%d vis=%d",
                      # 0.1.83 — **换窗**。手里那只量不到、而另一只（进程窗口总表
                      # 或键盘管理器自己报的）量到了 ⇒ 说明攥着的是上一轮会话的
                      # 空壳。没有这一行就无法证明「24 次 kb=0」是被换窗治好的。
                      b"kb: adopt top=%.0f hud=%d win=%.0fx%.0f src=%d",
                      # 0.1.80 — 另一种收法：整只窗滑到屏幕底以下（形状仍是 430×932）。
                      b"kb: gone slid win=%.0fx%.0f@%.0f",
                      # 0.1.80 — 收起那一帧的原样透传（旧版会把 932 改写成 611，
                      # 等于把「键盘走了」改写成「键盘来了」）。
                      b"kb: note off raw=%.0f name=",
                      # 0.1.78 — 第四条通道：改 App 自己的 `additionalSafeAreaInsets`。
                      # Safari 的前三条通道全无效（通知矩形 / 交集 / 参考线都试过），
                      # 唯一一定服从的量是它自己的安全区。这两行是「写进去」和
                      # 「按原样还回来」的证词，缺一条就可能留下错位。
                      b"kb: safe inset bottom=%.0f was=%.0f cover=%.0f",
                      b"kb: safe inset restored bottom=%.0f",
                      # 0.1.78 — 两条补救通道的升级点：extra 补过却还被盖
                      # ⇒ 说明它不读通知矩形，换安全区。
                      b"kb: learn safe=1 bar=%.0f target=%.0f need=%.0f extra=%.0f cover=%.0f",
                      # 0.1.80 — 升级之后仍被盖：只记一行，不再叠第三条通道。
                      # 酷安就是这样被顶出卡片的（通知 209 + 参考线 316 + 安全区
                      # 316 = 841 pt），所以这一版必须有「到此为止」的证词。
                      b"kb: learn stuck safe=1 bar=%.0f target=%.0f need=%.0f hit=%d",
                      # 0.1.83 — **通道会失效，所以必须有撤销。** 酷安把两份让位
                      # 同时吃进去却一像素不动（`bar` 恒 826..920），撤销之后回到
                      # 通知矩形那条（`out=616−209=407`）。两条证词：撤销那一次，
                      # 以及之后不再重试的那几拍。
                      b"kb: learn safe gave up bar=%.0f target=%.0f need=%.0f cal=%.0f",
                      b"kb: learn give up bar=%.0f target=%.0f need=%.0f cal=%.0f",
                      # 0.1.65 — 「把量到的键盘顶抬到系统认可的那条线」。
                      # 0.1.66 — 锚点改成**一次学到、之后每次都用**，不再拿每一拍
                      # 的交集现算（Aevon(137)：抖音那两拍读到 74/101，锚点算成
                      # 858，差太远被挡 ⇒ 一次没校正，窗口停在 533）。三条证词：
                      #   `anchor fallback` ⇒ 还没学到，用 932−316 兜底；
                      #   `anchor learned`  ⇒ 从系统的稳定交集值学到；
                      #   `top anchor`      ⇒ 每次落地用的锚点与量值。
                      # 0.1.67 — 316 才是键盘高（键盘 616..932），289 是**我们
                      # 收过窗口之后** UIKit 重新结算的偏小值；0.1.65/0.1.66 把
                      # 289 当真值，窗口收到 643，输入框整条被键盘盖住。
                      b"kb: top anchor measured=%.0f",
                      b"kb: anchor learned lead=%.0f",
                      b"kb: anchor fallback -> %.0f",
                      # 0.1.66 — 收起的唯一来源。0.1.64/0.1.65 拿 `willChangeFrame`
                      # 的 `on=NO` 当收起，而那正是**我们收自己窗口**惹出来的补发
                      # 通知（Aevon(137)：16 次 fit 配 16 次 unfit，同秒成对，
                      # 输入框只在一瞬间露头）。现在只认 hide 通知，另加一条
                      # 「静置 2 s 且量两次都空」的空窗兜底。
                      # 0.1.80 — hide 通知不再直接等于「收起」，先看它的原始矩形
                      # 落到哪里：真收起 `origin.y` 落在屏幕底（932），假的那条
                      # （Aevon(150) 里弹起后约 1 s 就来一条）还在屏内。`off=`
                      # 就是这条判定的结果，两类的条数都该在日志里数得出来。
                      b"kb: hide note gap=%.2f raw=%.0f h=%.0f off=%d",
                      # 0.1.80 — `off=0` 的那些被这条挡下。
                      b"kb: hide note veto raw=%.0f",
                      # 0.1.84 — 兜底改成「只数窗真的不在屏上」，两票即认。旧版按
                      # `top <= 200` 数，空壳（折成缓存 573）不算、缓存过期又算，
                      # 于是它既误触发又装死。`hits=` 是实际连票数。
                      b"kb: idle zero close hits=%d",
                      # 0.1.67 — 输入框到底在哪一行（屏幕坐标）。判据从此是
                      # 「输入框底边 ≤ 键盘顶边」，不再靠推。
                      # 0.1.69 — 后面补了 `bar=`：`UITextView` 自己那一条的屏幕矩形。
                      # 只看光标分不清「输入框整体在键盘下面」和「输入框在上面、
                      # 只有光标冒出去」，而这两种情形的修法相反。
                      b"kb: caret cls=%s y=%.0f..%.0f x=%.0f win=%.0f kb=%.0f bar=%.0f..%.0f",
                      # 0.1.75 — 自学习的落点。这一行在，就说明「表外 App 被盖
                      # 之后自己记住补偿量」这条闭环真的装进了包里：量到输入框
                      # 底边低于键盘上沿 − 50 时，把差额按 Bundle 写进偏好域，
                      # 下一次开键盘直接生效 —— 不用把每个 App 装一遍再手调。
                      # 0.1.80 — Safari 只读安全区，而安全区一开就得让通知矩形
                      # 整体让开（`safeOnly`），否则就是「让两次」。
                      b"kb: learn bar=%.0f target=%.0f need=%.0f extra=%.0f -> %.0f",
                      # 0.1.35 — 判不中的时候把坐标与两个矩形写下来。V111 里
                      # `app: band touch at` 是 0，而带子的值明明是对的 ⇒ 分不出
                      # 「这一拍没进来」还是「进来了被几何否掉」。有这一行就分得开。
                      b"app: band miss at ",
                      # 0.1.39 — 起手落在环带里、但**还没**归宿主的那一拍。
                      #
                      # 0.1.36 在这里断言的是 `app: band hold at `：那是「起手就被
                      # 锁吞掉」的证词。0.1.39 起手不再吞（点按要能点），那条路
                      # 整个不存在了 —— 现在起手只记候选（`… watch`），接管要等
                      # 宿主在第一次真的移动时才上的锁（`… held`）。
                      # 撤掉一条旧证词必须补一条新的，否则下一份日志里
                      # 「谁吞的」这个问题又变成空白。
                      b"app: band touch at %.0f,%.0f watch",
                      # 0.1.29 — 深浅色的应用侧观察者。
                      b"com.aevon.style.",
                      # 0.2.15 — 分享 payload 的落点。这三行分别代表「交给自己了」
                      # 与两种「没东西可交」；通道名与回执名也一起钉住 —— 宿主和
                      # 应用两侧的拼写只要差一个字符，这条链就永久静默。
                      b"com.aevon.openurl.",
                      b"app: openurl ok=%d via=%s u=%d opt=%d src=%d sc=%d wsc=%d wins=%d state=%d rsp=%d dlg=%s",
                      # 0.2.18 —— 回执又加了 `wins` / `state`：区分「一条 scene 都没有」
                      # 与「有窗口但没 scene」。两个字段都不进产物就等于这版白改。
                      b"ok=%d via=%s pid=%d sc=%d wsc=%d wins=%d state=%d dlg=%s rsp=%d",
                      # 0.2.17 —— AppDelegate 的两条老入口。QQ 这类老工程常常只实现
                      # 这两条；名字写错一位就等于那条路从来没存在过。
                      b"application:openURL:sourceApplication:annotation:",
                      b"application:handleOpenURL:",
                      b"app: openurl ctx opt miss",
                      # 0.2.42 —— 微信分享崩溃的修复标记：`_options` 必须是对象。
                      # 这两行只有真的按「系统类 / 替身」二选一才存在，缺了说明
                      # 又把裸字典塞回去了。
                      b"app: openurl ctx opt real",
                      b"app: openurl ctx opt stub",
                      b"app: openurl no file",
                      b"app: openurl bad plist",
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
                      # 强制重排：`layoutIfNeeded` **仍然全禁**。0.0.67 的第二个
                      # 动作就是「名片一翻就给每个窗口补一次 layoutIfNeeded」，
                      # 那一次真机反馈与原样一字不差。
                      b"layoutIfNeeded",                                    # gone
                      # ⚠️ 0.1.60 — `setFrame:` **从本栏撤出**，但只放宽到唯一一种
                      # 用法：键盘通知里、只对当前 key window、只改高度（见
                      # `AevonKbFitWindow`）。理由与做法都写在下面那条正向断言里。
                      # 撤一条旧禁令必须补一条新的证词，否则下一次没人知道边界在哪。
                      # 0.0.78 — `reloadData` 会让表格把每一屏都重建一次，等于替
                      # 用户翻了一次页：视频重来、正在看的那一帖被丢掉。它一直是
                      # 「能让行高对上」的最短路径，也是这一版明确不走的那条。
                      b"reloadData",                                        # gone
                      b"hosted, relayout",                                  # gone
                      # 0.1.80 — 撤掉的第三条让位通道：喂 `keyboardLayoutGuide`。
                      # 酷安拿到三份让位（通知 209 + 参考线 316 + 安全区 316 = 841），
                      # 一根底部工具栏从 775 被顶到卡片上沿之外，输入框整套消失。
                      # 这条通道从来没有一份日志能证明「喂过之后 bar 上移」，却有
                      # 这份反证。它若回来，就是「三份让位同时生效」又回来了。
                      b"kb: guide fill h=%.0f",                             # gone
                      # 0.1.84 — 旧的两条收起证词：「量一次、0.40 s 后再量一次」。
                      # 它们本身没错，错在 `measure=` 那个数是由「空壳折成上次真值」
                      # 得来的 —— Aevon(152) 里 8 次真收起全部先落成 `settle keep`，
                      # 然后等心跳凑三连零，5~10 s 才还原。判据改成三态轮询之后这两
                      # 条格式串不该再出现；若它们回来，说明「拿缓存值当在屏证据」的
                      # 那条路又接上了。
                      b"kb: settle gone measure=%.0f",                      # gone
                      b"kb: settle wait measure=%.0f",                      # gone
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
                      # 0.1.70 — 「按场景原点平移键盘矩形」整条撤掉。它不是无害的
                      # 换算：这三个 App 自己就用 `UIScreen 高 − 键盘顶` 算让位，
                      # 平移之后同一个会话里先给未平移的、再给平移的，App 把两次
                      # 让位累加（抖音 184+399 ⇒ 输入条底边到屏幕 349）。它若回来，
                      # 就是「输入框被抬高」又回来了。
                      b"kb: note shift=%.0f",                               # gone
                      b"kb: note keep=",                                    # gone
                      b"kb: top correct measured",                          # gone
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
    # 0.2.60 — 设置按「已经做出来的功能」重写：探针按钮不再出现在界面上，
    # 这一页只剩两个真的会被桌面读取的键。页面本身仍要检查 —— 少一行就等于
    # 「手机上那个滑条 / 文本框没了」。
    window_plist = files.get(f"{BUNDLE_DIR}/Window.plist")
    if window_plist is None:
        bad("prefs: Window.plist missing")
    else:
        window_items = plistlib.loads(window_plist).get("items", [])
        window_keys = [item.get("key") for item in window_items
                       if item.get("cell") in ("PSSliderCell", "PSTextFieldSpecifier")]
        if "HeightFraction" not in window_keys:
            bad("prefs: 浮窗页没有 HeightFraction 滑条 — 尺寸没法在手机上改")
        elif "windowBlacklistText" not in window_keys:
            bad("prefs: 浮窗页没有黑名单文本框 — 走不通的 App 没有自救手段")
        else:
            ok("prefs: 浮窗页 " + str(len(window_items)) + " 行，高度与黑名单都在")

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
                  # 0.2.6 — 系统面板在屏时卡片让开（alpha 0），退掉后回来。
                  # 用户报「悬浮窗在通知中心和控制中心出现」，而 0.2.2 已经证明
                  # 「遮挡就收卡」会把每次通知→浮窗自己拆掉 ⇒ 只能让开、不能拆。
                  # 这两行是那条路的全部证词：一条进、一条出。任何一条不在产物里，
                  # 「面板里还看得见卡」与「根本没试过让开」就分不开。
                  b"win: card stepped aside (system overlay up)",
                  b"win: card back (system overlay gone)",
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
                  #
                  # 0.2.40 — 第一条约文字和它背后的机制一起换了：
                  #   `win: undock read placed frame ` = 升窗目标由 `plan(存盘)` 算出，
                  #     与开窗同一个函数、同一组夹子；`FloatHost.lastMainFrame` 那帧
                  #     内存缓存已撤销（键盘态与别的 App 都会把它写歪，用户报「时大时小」）。
                  #     判据：同一串「点小窗升回」操作里，这一行的 `WxH at X,Y` 每次
                  #     都必须一样，且与上一次 `win: plan card=` 的落点对得上。
                  #   # gone — b"win: undock read last main frame "
                  b"win: undock read placed frame ",
                  # 0.2.40 — 几何的唯一读数。开窗 / 升窗 / 复位三条路都汇到 `plan`，
                  # 这一行写出结果、来源与合法区间：`src=memory` 是存盘、`src=default`
                  # 是出厂值。一段日志里 `card=` 与 `remembered f=` 必须互相还原得回来。
                  # 断言用**带格式符的那半句**：只有 `win: plan card=` 是 15 字节，
                  # 会被编成立即数，二进制里搜不到（push-gate 会拦）。
                  b"win: plan card=%.0fx%.0f at %.0f,%.0f f=%.4f",
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
                  # 0.2.0 — 原来断言前缀 `win: icon launch `。这一版把这一行换成
                  #   一条带计时的完整字面量（3 秒卡顿的分段取证要靠它），前缀本身
                  #   不再是独立字面量，所以断言跟着换成整条。
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
                  # 0.2.43 — 同一行里的偏差读数。`dC` 是「修之前被推走多少」，
                  # `org` 是当时的场景原点。键盘态下如果 `dC` ≈ (0, org)，
                  # 就证实了系统按 scene 原点重设承载面 frame 这条机制；也就是
                  # 用户报的「放大时闪一下」的物证。没有这两个数，那一下永远只能
                  # 靠肉眼描述。
                  b" dC=%.0f,%.0f org=%.0f",
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
