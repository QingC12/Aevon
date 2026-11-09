#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen-settings.py — 设置面板的唯一数据源。

0.2.60 起按「已经做出来的功能」重写：只保留运行时会读的键，
不再复刻母本那 81 个键，也不在界面里写版本更新日志。

一张表同时产出：
  · 设置面板的 plist（界面）
  · build/settings-tbody.html（交付文档里的设置清单）
  · build/settings-manifest.json（对账表）

面板结构（两级）：
  根页     状态 / 浮窗与圆盘 / 接管范围 / 诊断 / 安全
  Window   浮窗尺寸与黑名单
  Ring     圆盘开关、应用清单、预览
"""
import json
import os
import plistlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE = os.path.join(
    ROOT, "layout", "Library", "PreferenceBundles", "AevonPrefs.bundle"
)
OUTDIR = os.path.join(ROOT, "build")

DOMAIN = "com.aevon"


def control_version():
    """控制文件是版本号的唯一来源：control / Paths.swift / Info.plist 三处一致，
    由 CI 的 preflight 断言，这里只是把它带进界面文案和文档里。"""
    with open(os.path.join(ROOT, "control"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("Version:"):
                return line.split(":", 1)[1].strip()
    raise SystemExit("control 里没有 Version:")


VERSION = control_version()

# 运行时真的会读的键。没列在这里的键不该出现在界面上 ——
# 一个拧了没反应的开关比没有更糟。
WIRED = {
    "HeightFraction",        # CardLayout：浮窗首帧高度
    "windowBlacklistText",   # AevonOpenDecide：名单里的 App 走原生
    "!ring.desktop",         # RingHost：桌面是否挂圆盘
    "!gate.notify",          # 写 notify.off 文件闸
    "!gate.share",           # 写 share.off 文件闸
}

# ---------------------------------------------------------------------------
# 二级页面
# ---------------------------------------------------------------------------

PANELS = [
    ("Window", "浮窗", [
        dict(k="HeightFraction", cn="高度", cell="slider", d=0.63, rng=(0.30, 0.80),
             note="浮窗第一次打开时占屏幕高度的比例。宽度按 5:3 跟随，"
                  "所以只要调这一个数。拖动或缩放过之后，以那张卡自己的记忆为准；"
                  "长按卡片底角可以复位到这里。"),
        dict(k="windowBlacklistText", cn="不走浮窗的 App", cell="text",
             d="", note="填 bundle id，用逗号或空格分隔。名单里的 App 不进浮窗："
                        "通知、分享、链接都按系统原生方式打开，是某个 App 在浮窗里"
                        "用不了时唯一的自救手段。写前缀会盖住它名下所有 App，"
                        "例如 com.autonavi 也命中 com.autonavi.amap。"),
    ]),

    ("Ring", "圆盘", [
        dict(k="!ring.desktop", cn="在桌面显示", cell="switch", d=True,
             note="开着时，手指贴屏幕右缘、在下部 35% 之内向左划，圆盘从固定点展开。"
                  "关掉只是不显示，不影响浮窗。"),
        dict(k="@ring.host", cn="桌面状态", cell="title", d="—",
             note="桌面进程回报的当前状态。显示「未加载」表示 Aevon 没有在桌面里跑，"
                  "多半是安全闸门开着，或刚改完还没重载。"),
        dict(k="@ring.summary", cn="当前承载", cell="title", d="—",
             note="圆盘现在用的几何（圈数与每圈容量）。它随你在编辑器里的增删"
                  "自动变化，不用手调。"),
        dict(k="@ring.apps", cn="已选应用", cell="title", d="自动",
             note="圆盘里装哪些 App。留空时自动挑最近使用的 12 个。"),
    ]),
]

PANEL_BUTTONS = [("Window", "浮窗尺寸与名单", "高度、以及哪些 App 不走浮窗"),
                 ("Ring", "圆盘", "桌面开关、应用清单与预览")]


# ---------------------------------------------------------------------------
# 单元构造
# ---------------------------------------------------------------------------

def spec_switch(key, cn, default):
    return {"cell": "PSSwitchCell", "label": cn, "key": key,
            "default": bool(default), "defaults": DOMAIN}


def spec_slider(key, cn, default, rng):
    lo, hi = rng
    return {"cell": "PSSliderCell", "label": cn, "key": key,
            "default": float(default), "min": float(lo), "max": float(hi),
            "showValue": True, "defaults": DOMAIN}


def spec_title(key, cn, default):
    return {"cell": "PSTitleValueCell", "label": cn, "key": key,
            "default": str(default), "defaults": DOMAIN}


def spec_text(key, cn, default, placeholder=""):
    item = {"cell": "PSTextFieldSpecifier", "label": cn, "key": key,
            "default": str(default), "defaults": DOMAIN}
    if placeholder:
        item["placeholder"] = placeholder
    return item


def spec_of(it):
    if it["cell"] == "slider":
        return spec_slider(it["k"], it["cn"], it["d"], it["rng"])
    if it["cell"] == "switch":
        return spec_switch(it["k"], it["cn"], it["d"])
    if it["cell"] == "text":
        return spec_text(it["k"], it["cn"], it["d"], it.get("placeholder", ""))
    return spec_title(it["k"], it["cn"], it["d"])


def build_panel(panel_id, title, items):
    specs = []
    for it in items:
        specs.append({"cell": "PSGroupCell", "label": it["cn"], "footerText": it["note"]})
        specs.append(spec_of(it))
    # 圆盘的三个动作：编辑器与预览是这一页唯一的「能改东西」的入口。
    if panel_id == "Ring":
        specs.append({"cell": "PSGroupCell", "label": "应用",
                      "footerText": "增删与排序决定图标落在哪一圈；改动立刻生效，"
                                    "不需要重载桌面。上限 36 个（含截图 / 录屏两个动作槽）。"})
        specs.append({"cell": "PSButtonCell", "label": "编辑应用",
                      "action": "editApps:", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "预览圆盘（全屏）",
                      "action": "previewRing:", "defaults": DOMAIN})
    return {"title": title, "items": specs}


# ---------------------------------------------------------------------------
# 根页
# ---------------------------------------------------------------------------

def build_root():
    items = []

    items.append({"cell": "PSGroupCell", "label": "状态",
                  "footerText": "读数来自桌面进程写下的记录，不是这里的缓存。"})
    items.append(spec_title("@status.version", "版本", "—"))
    items.append(spec_title("@status.state", "注入", "—"))
    items.append(spec_title("@status.last", "最近一次加载", "—"))

    items.append({"cell": "PSGroupCell", "label": "浮窗与圆盘",
                  "footerText": "点进去改尺寸、名单和圆盘。"})
    for pid, label, _sub in PANEL_BUTTONS:
        items.append({"cell": "PSButtonCell", "label": label,
                      "action": "openPanel:", "panel": pid})

    items.append({"cell": "PSGroupCell", "label": "接管范围",
                  "footerText": "关掉的那一类请求按系统原生方式打开，Aevon 一个字节都不改。"
                                "关掉之后立刻生效，不需要重载。"})
    items.append({"cell": "PSSwitchCell", "label": "通知点开进浮窗",
                  "key": "!gate.notify", "default": True, "defaults": DOMAIN})
    items.append({"cell": "PSSwitchCell", "label": "分享进浮窗",
                  "key": "!gate.share", "default": True, "defaults": DOMAIN})

    items.append({"cell": "PSGroupCell", "label": "诊断",
                  "footerText": "日志页显示最近 600 行，右上角可整段复制，"
                                "手机上就能把现场发出来，不用导出文件。"})
    items.append({"cell": "PSButtonCell", "label": "查看日志",
                  "action": "openLog:", "defaults": DOMAIN})

    items.append({"cell": "PSGroupCell", "label": "安全",
                  "footerText": "两个闸门任一开启，重载桌面后 Aevon 不装任何 hook。"
                                "关掉它们不会自动恢复，需要再重载一次。"})
    items.append({"cell": "PSSwitchCell", "label": "停用（重载后生效）",
                  "key": "!gate.disabled", "default": False, "defaults": DOMAIN})
    items.append({"cell": "PSSwitchCell", "label": "紧急停止（G0）",
                  "key": "!gate.panic", "default": False, "defaults": DOMAIN})
    items.append({"cell": "PSButtonCell", "label": "清除崩溃计数",
                  "action": "clearAttempts:", "defaults": DOMAIN})
    items.append({"cell": "PSButtonCell", "label": "重载桌面",
                  "action": "respring:", "defaults": DOMAIN})

    items.append({"cell": "PSGroupCell", "label": "",
                  "footerText": f"Aevon {VERSION} · 装完或改完闸门需要重启桌面。"})
    return {"title": "Aevon", "items": items}


# ---------------------------------------------------------------------------
# 写盘
# ---------------------------------------------------------------------------

def write_plist(path, obj, text=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        plistlib.dump(obj, fh, fmt=plistlib.FMT_XML if text else plistlib.FMT_BINARY)


CELL_CN = {"switch": "开关", "slider": "滑杆", "text": "文本", "title": "只读"}


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def html_rows():
    rows, n = [], 0
    for pid, title, items in PANELS:
        for it in items:
            n += 1
            if it["cell"] == "slider":
                lo, hi = it["rng"]
                rng = f"{lo:g} ~ {hi:g}　默认 {it['d']:g}"
            elif it["cell"] == "switch":
                rng = "开 / 关　默认" + ("开" if it["d"] else "关")
            elif it["cell"] == "text":
                rng = "文本"
            else:
                rng = "—"
            rows.append(
                f"<tr><td class='num'>{n:02d}</td><td>{esc(title)}</td>"
                f"<td class='mono'>{esc(it['k'])}</td><td>{esc(it['cn'])}</td>"
                f"<td class='ctr'>{CELL_CN[it['cell']]}</td><td class='mono sm'>{esc(rng)}</td>"
                f"<td>{esc(it['note'])}</td></tr>")
    return "\n".join(rows), n


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    written = []

    # 旧版的 8 个母本面板文件不再被引用，留着只会让 layout 里多出死页面。
    for stale in ["Apps", "Gesture", "Keyboard", "Notify", "Jump", "Listen", "Window", "Ring"]:
        path = os.path.join(BUNDLE, stale + ".plist")
        if os.path.exists(path):
            os.remove(path)

    for pid, title, items in PANELS:
        write_plist(os.path.join(BUNDLE, pid + ".plist"), build_panel(pid, title, items))
        written.append(pid + ".plist")

    write_plist(os.path.join(BUNDLE, "Root.plist"), build_root(), text=True)
    written.append("Root.plist")

    rows, n = html_rows()
    with open(os.path.join(OUTDIR, "settings-tbody.html"), "w", encoding="utf-8") as fh:
        fh.write(rows)

    manifest = {
        "package": "com.aevon",
        "version": VERSION,
        "domain": DOMAIN,
        "设置项": n,
        "面板": [{"id": p[0], "title": p[1], "count": len(p[2])} for p in PANELS],
        "items": [
            {"panel": p[0], "key": it["k"], "cn": it["cn"], "cell": it["cell"],
             "wired": it["k"] in WIRED}
            for p in PANELS for it in p[2]
        ],
    }
    with open(os.path.join(OUTDIR, "settings-manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    print("设置项:", n, "| 面板:", len(PANELS))
    print("plist:", ", ".join(written))


if __name__ == "__main__":
    main()
