#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen-settings.py — 唯一的数据源。

一张表同时产出：
  · 设置面板的 8 份 plist（界面）
  · build/settings-tbody.html（交付文档里的设置清单）
  · build/settings-manifest.json（后续逐项接通时的对账表）

所以文档里写的和界面上显示的永远不会不一致。

键名沿用 Stheno 母本的原样键名，这样逆向资料、界面、以后的实现三方可以
逐条对上。中文标签按同一语义重写，不照抄母本文案。
"""
import json
import os
import plistlib
import sys

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

# ---------------------------------------------------------------------------
# 面板定义
#    k      母本键名（保持原样，用于对账）
#    cn     界面标签
#    cell   switch | slider | title
#    d      默认值
#    rng    slider 的 (min, max)
#    note   操作逻辑：这个开关到底管什么
# ---------------------------------------------------------------------------

PANELS = [
    ("Window", "窗口与场景", "窗口的生命周期、几何与启动时序。", [
        dict(k="SISI", cn="单窗口", cell="switch", d=False,
             note="同一 App 只保留一个浮窗；切换 App 时状态同步，切回来还原默认尺寸。"),
        dict(k="HVSeperate", cn="横竖分离", cell="switch", d=False,
             note="横屏与竖屏各自独立，可同时存在两个浮窗。关掉则共用一个。"),
        dict(k="SSTemperoryAutoClose", cn="临时窗口", cell="switch", d=False,
             note="从底边激活新窗口时，自动关闭当前浮窗，避免叠窗。"),
        dict(k="CustomFrameInit", cn="自定义初始比例", cell="switch", d=False,
             note="浮窗首帧不套用系统比例，直接使用下面的宽度/高度系数。"),
        dict(k="Width", cn="宽度", cell="slider", d=0.55, rng=(0.30, 1.00),
             note="浮窗宽度占屏幕宽度的比例。"),
        dict(k="HeightFraction", cn="高度系数", cell="slider", d=0.62, rng=(0.20, 1.00),
             note="在宽度基础上再乘的系数，决定最终高度。"),
        dict(k="Size", cn="尺寸", cell="slider", d=0.60, rng=(0.40, 1.00),
             note="基准尺寸，圆盘展开时按此推导各图标位置。"),
        dict(k="BallparkFigure", cn="近似取值", cell="switch", d=False,
             note="尺寸取近似值，省掉逐帧重算；视觉差异约 1pt。"),
        dict(k="LeftCornerTrim", cn="左角微调", cell="switch", d=True,
             note="左下角：滑动微调比例，长按反向调整。"),
        dict(k="RightCornerTrim", cn="右角切换", cell="switch", d=True,
             note="右下角：点击在基础比例之间切换。"),
        dict(k="AutoPin", cn="自锁", cell="switch", d=False,
             note="展开后立即固定，不再随内容高度变化。"),
        dict(k="SingleTapMinimize", cn="单点缩小", cell="switch", d=False,
             note="单击贴边缩成不可操作的缩略态，再点恢复。"),
        dict(k="DelayResume", cn="延迟启动", cell="switch", d=False,
             note="展开动画播完再启动 App，避免动画期掉帧。"),
        dict(k="Speed", cn="速度", cell="slider", d=1.00, rng=(0.20, 2.00),
             note="展开/收起的速度倍率，1.0 为母本默认节奏。"),
        dict(k="DelayRotate", cn="延迟旋转", cell="switch", d=False,
             note="等动画结束再旋转窗口，避免旋转与缩放同时插值。"),
    ]),

    ("Ring", "承载形状", "图标托盘（圆盘）的形状、几何与旋转行为。", [
        dict(k="RTSIF", cn="圆盘", cell="switch", d=True,
             note="完整圆形托盘，图标沿圆周均分。"),
        dict(k="RTSIH", cn="半圆盘", cell="switch", d=False,
             note="只取上半个圆周，适合贴边使用。"),
        dict(k="RTSIQ", cn="直角盘", cell="switch", d=False,
             note="四分之一圆周，贴角展开。"),
        dict(k="RTSIZ", cn="任意角度", cell="switch", d=False,
             note="拖拽旋转最后一个图标来定角度，与上面三种互斥。"),
        dict(k="Radius", cn="半径", cell="slider", d=64.0, rng=(40.0, 120.0),
             note="托盘半径，单位 pt。"),
        dict(k="IconWidth", cn="图标宽度", cell="slider", d=44.0, rng=(28.0, 64.0),
             note="单个图标的边长，影响圆盘整体外径。"),
        dict(k="RotationAngle", cn="旋转角", cell="slider", d=0.0, rng=(-180.0, 180.0),
             note="整个托盘的朝向偏移。"),
        dict(k="LastIconAngle", cn="尾角", cell="slider", d=0.0, rng=(-180.0, 180.0),
             note="最后一个图标的落位角度，决定扇区开口方向。"),
        dict(k="Star", cn="收藏", cell="switch", d=False,
             note="把当前 App 标为收藏，托盘里置顶。"),
        dict(k="IOMI0", cn="旋转 自适应", cell="switch", d=True,
             note="让系统决定何时旋转。三选一，建议只开一个。"),
        dict(k="IOMI1", cn="旋转 立即", cell="switch", d=False,
             note="立刻跟随，游戏内视角容易错乱。"),
        dict(k="IOMI2", cn="旋转 延迟", cell="switch", d=False,
             note="等内容稳定后再旋转，观感最稳。"),
    ]),

    ("Gesture", "手势与动效", "边缘手势区、触感反馈与弹簧动画。", [
        dict(k="EBCI", cn="可调触发边", cell="switch", d=False,
             note="开启后边缘触发区的宽度由下面一项决定，否则用系统默认。"),
        dict(k="GestureBorderWidth", cn="手势宽度", cell="slider", d=18.0, rng=(8.0, 40.0),
             note="边缘可识别区域的宽度，单位 pt；越窄越容易误触内部控件。"),
        dict(k="FastMoveControl", cn="快滑灵敏度", cell="slider", d=1.00, rng=(0.20, 2.00),
             note="快速滑动时的输入增益。"),
        dict(k="SIFEI", cn="四边扩展", cell="switch", d=False,
             note="浮窗四条边都参与交互，而不只是贴边那一侧。"),
        dict(k="IconJump", cn="防遮挡跳动", cell="switch", d=False,
             note="托盘被浮窗挡住时自动跳位。"),
        dict(k="VIBRATE", cn="震动", cell="switch", d=True,
             note="手势落点时给触感反馈。"),
        dict(k="INTENSITY", cn="强度", cell="slider", d=0.70, rng=(0.10, 1.00),
             note="触感强度，对应 impactOccurredWithIntensity: 的参数。"),
        dict(k="DampingFraction", cn="阻尼系数", cell="slider", d=0.82, rng=(0.10, 1.00),
             note="弹簧动画阻尼，越小回弹越明显。"),
        dict(k="CustomSpringAnimation", cn="动画弹性", cell="switch", d=True,
             note="使用自定义弹簧参数，关掉则走系统默认曲线。"),
    ]),

    ("Keyboard", "键盘与输入", "浮窗是独立场景，键盘在场景之外，必须桥接。", [
        dict(k="PortraitKeyboard", cn="竖向键盘", cell="switch", d=False,
             note="横屏时把键盘强制按竖向布局绘制进浮窗。"),
        dict(k="IntersectionHeightFraction", cn="键盘避让", cell="slider", d=0.50, rng=(0.00, 1.00),
             note="浮窗与键盘相交时向上让出的高度比例。"),
        dict(k="HookUIKit", cn="注入 UIKit", cell="switch", d=False,
             note="扩大注入范围到 UIKit 进程。改动此项必须重启桌面，且只对已添加的 App 生效。"),
    ]),

    ("Notify", "通知", "通知如何进入浮窗。", [
        dict(k="Notification", cn="通知总开关", cell="switch", d=True,
             note="关掉后下面三项全部失效。"),
        dict(k="SISNFI", cn="通知转浮窗", cell="switch", d=False,
             note="收到通知时直接把对应 App 拉进浮窗。"),
        dict(k="ForegroundNotify", cn="前台通知", cell="switch", d=False,
             note="仅对已经在浮窗里的 App 生效，不打扰其他。"),
        dict(k="FrontmostNotify", cn="附加主 App", cell="switch", d=False,
             note="通知同时附加到当前主 App 上。"),
    ]),

    ("Jump", "跳转与伪装", "App 内链接、第三方登录、支付与广告的落地策略。", [
        dict(k="SISURLI", cn="URL 跳转", cell="switch", d=True,
             note="授权、支付、广告等 URL 统一在浮窗里打开。"),
        dict(k="SSNoUniversalLinks", cn="UniversalLinks 转 Safari", cell="switch", d=False,
             note="把 UniversalLink 改走 Safari 打开，需要 UIKit 注入。"),
        dict(k="SSNoSafariViewService", cn="SafariViewService 转 Safari", cell="switch", d=False,
             note="把应用内浏览器改走 Safari，需要进程注入。"),
        dict(k="SISATI", cn="Activity", cell="switch", d=False,
             note="分享面板里的 Activity 请求同样走浮窗。"),
        dict(k="SISASI", cn="StoreKitUIService", cell="switch", d=False,
             note="内购界面接管；母本注明伪装失败率较高。"),
        dict(k="SISSBI", cn="SpringBoard 请求", cell="switch", d=False,
             note="允许 SpringBoard 侧发起激活目标浮窗。"),
        dict(k="SIVSI", cn="视图服务", cell="switch", d=False,
             note="授予浮窗向外跳转的权限。"),
        dict(k="SSInterceptor", cn="跳转伪装", cell="switch", d=False,
             note="拦截跳转并给图标提示；建议按单个 App 开启，全局开容易误伤。"),
        dict(k="BlockInterceptor", cn="拦截", cell="switch", d=False,
             note="直接阻断跳转，不放行。"),
        dict(k="SSInterceptorSilence", cn="静默", cell="switch", d=False,
             note="伪装成功时不提示；SafariViewService 是例外，仍会提示。"),
        dict(k="SIPI", cn="预览", cell="switch", d=False,
             note="浮窗里显示 App 快照而不是实时画面，省电但会滞后。"),
    ]),

    ("Listen", "监听与系统动作", "系统级服务请求如何落到浮窗。", [
        dict(k="SSListen", cn="浮窗激活", cell="switch", d=False,
             note="系统服务请求激活时，改为在浮窗里打开。"),
        dict(k="ServiceListen", cn="服务监听", cell="switch", d=False,
             note="监听系统服务调用，是上面一项的前置。"),
        dict(k="SISRI", cn="缩小范围", cell="switch", d=False,
             note="只允许已添加的 App 走浮窗激活，避免全局接管。"),
        dict(k="SICMI", cn="摄像头", cell="switch", d=False,
             note="允许浮窗内的 App 使用摄像头。"),
    ]),
]

# 母本 81 个键里剩下的纯文案键。它们不是设置项，但必须记账，
# 否则「81 项全复刻」这句话就无法核对。
TEXT_KEYS = [
    ("YES", "是"), ("NO", "否"), ("Dismiss", "关闭"), ("Modify", "修改"),
    ("Replace", "替换"), ("Copy", "拷贝"), ("Inject", "注入"), ("Error", "错误"),
    ("Warning", "警告"), ("Window", "窗口"), ("Gesture", "手势"),
    ("Introduction", "简介"), ("System", "系统"), ("Other", "其它"),
    ("User", "用户"), ("Preference", "自定义"), ("GestureIntroduction", "手势简介长文案"),
]

# 应用与全局：不是普通开关，单独处理
APPS_ITEMS = [
    dict(k="GlobalPreference", cn="全局设置", cell="switch", d=False,
         note="对所有 App 生效的默认值。"),
    dict(k="AutoRemoveAppSettings", cn="自整理自定义", cell="switch", d=False,
         note="自动删除与全局值一致的单 App 设置，保持列表干净。"),
    dict(k="UserList", cn="用户列表", cell="title", d="0 个 App",
         note="已添加的 App 列表，P4 接入。"),
    dict(k="SystemList", cn="系统列表", cell="title", d="0 个 App",
         note="系统 App 列表，P4 接入。"),
    dict(k="ActivateCode", cn="激活码", cell="title", d="未启用（不复刻授权体系）",
         note="母本的商业授权位。保留键位与位置，功能不实现。"),
    dict(k="RespringYourselfToActivate", cn="自行注销激活", cell="title", d="不适用",
         note="母本用于授权后自注销；本项目无授权，故保留占位。"),
]


# ---------------------------------------------------------------------------
# plist 生成
# ---------------------------------------------------------------------------

def spec_switch(it):
    return {
        "cell": "PSSwitchCell",
        "label": it["cn"],
        "key": it["k"],
        "default": bool(it["d"]),
        "defaults": DOMAIN,
    }


def spec_slider(it):
    lo, hi = it["rng"]
    return {
        "cell": "PSSliderCell",
        "label": it["cn"],
        "key": it["k"],
        "default": float(it["d"]),
        "min": float(lo),
        "max": float(hi),
        "showValue": True,
        "defaults": DOMAIN,
    }


def spec_title(it):
    return {
        "cell": "PSTitleValueCell",
        "label": it["cn"],
        "key": it["k"],
        "default": str(it["d"]),
        "defaults": DOMAIN,
    }


BUILDERS = {"switch": spec_switch, "slider": spec_slider, "title": spec_title}


def build_panel(panel_id, title, intro, items):
    specs = [{"cell": "PSGroupCell", "label": title, "footerText": intro}]
    for it in items:
        specs.append(BUILDERS[it["cell"]](it))
    return {"title": title, "items": specs}


def write_plist(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        # 用二进制格式：和系统一致，也避免中文 XML 转义问题
        plistlib.dump(obj, fh, fmt=plistlib.FMT_BINARY)


# ---------------------------------------------------------------------------
# 根面板：状态 / 安全闸门 / 诊断 都是真功能，其余是入口
# ---------------------------------------------------------------------------

def build_root():
    items = []

    items.append({"cell": "PSGroupCell", "label": "状态",
                  "footerText": "本页数据直接读自注入进程写下的记录，不是缓存。"})
    for label, key, default in [
        ("注入状态", "@status.state", "—"),
        ("版本", "@status.version", "—"),
        ("启动次数", "@status.loads", "—"),
        ("最近一次加载", "@status.last", "—"),
        ("日志文件", "@status.log", "/var/mobile/Aevon.log"),
    ]:
        items.append({"cell": "PSTitleValueCell", "label": label,
                      "key": key, "default": default, "defaults": DOMAIN})

    items.append({"cell": "PSGroupCell", "label": "安全闸门",
                  "footerText": "这两个开关是应急用的。任一开启后，桌面重载时 Aevon 不安装任何 hook。"
                                "关闭 G0/G1 不会自动恢复，需要重载桌面。"})
    items.append({"cell": "PSSwitchCell", "label": "紧急停止（G0）",
                  "key": "!gate.panic", "default": False, "defaults": DOMAIN})
    items.append({"cell": "PSSwitchCell", "label": "暂停注入（G1）",
                  "key": "!gate.disabled", "default": False, "defaults": DOMAIN})
    items.append({"cell": "PSButtonCell", "label": "清除崩溃计数",
                  "action": "clearAttempts:", "defaults": DOMAIN})
    items.append({"cell": "PSButtonCell", "label": "重载桌面（应用闸门变更）",
                  "action": "respring:", "defaults": DOMAIN})

    items.append({"cell": "PSGroupCell", "label": "功能设置",
                  "footerText": "下面 8 个面板共 64 项，键名与母本一一对应。"
                                "本期只复刻界面与操作逻辑，开关尚未接通；每接通一项会在版本说明里标注。"})
    for pid, title, _intro in [(p[0], p[1], p[2]) for p in PANELS]:
        items.append({"cell": "PSChildPaneSpecifier", "label": title,
                      "file": pid, "File": pid})
    items.append({"cell": "PSChildPaneSpecifier", "label": "应用与全局",
                  "file": "Apps", "File": "Apps"})

    items.append({"cell": "PSGroupCell", "label": "关于",
                  "footerText": f"Aevon {VERSION} · Swift · arm64e · 设置 64/64 项已就位，"
                                f"功能 0/64 已接通。所有改动只写 {DOMAIN}，不触碰系统文件。"})

    return {"title": "Aevon", "items": items}


# ---------------------------------------------------------------------------
# 文档表格
# ---------------------------------------------------------------------------

CELL_CN = {"switch": "开关", "slider": "滑杆", "title": "只读"}


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def html_rows():
    rows = []
    n = 0
    for pid, title, _intro, items in [(p[0], p[1], p[2], p[3]) for p in PANELS] + \
                                     [("Apps", "应用与全局", "", APPS_ITEMS)]:
        for it in items:
            n += 1
            if it["cell"] == "slider":
                lo, hi = it["rng"]
                rng = f"{lo:g} ~ {hi:g}　默认 {it['d']:g}"
            elif it["cell"] == "switch":
                rng = "开 / 关　默认" + ("开" if it["d"] else "关")
            else:
                rng = "—"
            rows.append(
                f"<tr><td class='num'>{n:02d}</td><td>{esc(title)}</td>"
                f"<td class='mono'>{esc(it['k'])}</td><td>{esc(it['cn'])}</td>"
                f"<td class='ctr'>{CELL_CN[it['cell']]}</td><td class='mono sm'>{esc(rng)}</td>"
                f"<td>{esc(it['note'])}</td>"
                f"<td class='ctr'><span class='tag tW'>未接通</span></td></tr>"
            )
    return "\n".join(rows), n


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    written = []

    for pid, title, intro, items in PANELS:
        write_plist(os.path.join(BUNDLE, pid + ".plist"),
                    build_panel(pid, title, intro, items))
        written.append(pid + ".plist")

    write_plist(os.path.join(BUNDLE, "Apps.plist"),
                build_panel("Apps", "应用与全局",
                            "全局默认值与单 App 覆盖的关系；本期为占位。", APPS_ITEMS))
    written.append("Apps.plist")

    write_plist(os.path.join(BUNDLE, "Root.plist"), build_root())
    written.append("Root.plist")

    rows, n = html_rows()
    with open(os.path.join(OUTDIR, "settings-tbody.html"), "w", encoding="utf-8") as fh:
        fh.write(rows)

    manifest = {
        "package": "com.aevon",
        "version": VERSION,
        "domain": DOMAIN,
        "total_母本键": 81,
        "设置项": n,
        "文案键": len(TEXT_KEYS),
        "已接通": 0,
        "面板": [
            {"id": p[0], "title": p[1], "count": len(p[3])} for p in PANELS
        ] + [{"id": "Apps", "title": "应用与全局", "count": len(APPS_ITEMS)}],
        "文案键清单": [{"key": k, "cn": c} for k, c in TEXT_KEYS],
        "items": [
            {"panel": p[0], "key": it["k"], "cn": it["cn"],
             "cell": it["cell"], "wired": False}
            for p in PANELS for it in p[3]
        ] + [
            {"panel": "Apps", "key": it["k"], "cn": it["cn"],
             "cell": it["cell"], "wired": False} for it in APPS_ITEMS
        ],
    }
    with open(os.path.join(OUTDIR, "settings-manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    print("设置项:", n, "| 文案键:", len(TEXT_KEYS), "| 合计:", n + len(TEXT_KEYS))
    assert n + len(TEXT_KEYS) == 81, "与母本 81 键对不上"
    print("plist:", ", ".join(written))


if __name__ == "__main__":
    main()
