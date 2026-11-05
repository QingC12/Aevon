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

# 0.0.42 起圆盘本体换成旧版插件的实现（几何内定 64 / 46 / 40，见
# AevonRingMenu.swift），Ring 面板里不再有「写一个数值、桌面立刻变」的母本键
# —— 圆盘的增删排序走编辑器，几何不走滑条。接通口径改为按面板逐项核对。
#
# 0.0.65 — 「接通」是可以核对的，不是口径：窗口侧真的在读这个键
# （CardLayout.preferredHeight），所以它在这里点名。
# 0.0.64 的 `GeometryScaleEnabled` 随功能一起撤了（Aevon(57)：没任何用处），
# 于是 `OWN_KEYS` 也空了 —— 本项目不再往母本的 81 键里加东西。
WIRED_KEYS = {"HeightFraction"}
OWN_KEYS = set()

# 0.0.41 明确放弃的母本键。界面里没有它们，代码里也没有读取它们的地方 ——
# 但 81 键的对账必须继续成立，所以放弃本身要记账，而不是让总数悄悄少五位。
DROPPED = [
    ("RTSIH", "半圆盘", "只要圆盘，半圆盘自 0.0.41 起不实现"),
    ("RTSIQ", "直角盘", "只要圆盘，直角盘自 0.0.41 起不实现"),
    ("RTSIZ", "任意角度", "只要圆盘，任意角度自 0.0.41 起不实现"),
    ("RTSIF", "圆盘", "唯一的形状，不再需要开关 —— 常开即没有开关"),
    ("LastIconAngle", "尾角", "只对任意角度有意义的开口角度"),
    ("Radius", "半径", "0.0.42 圆盘本体换成旧版实现，几何内定（内圈 64 / 弧距 46 / 图标 40），滑条没有读取方"),
    ("IconWidth", "图标宽度", "同上：旧版圆盘的图标尺寸按每圈弧距自适应（上限 40pt），不再由设置决定"),
    ("RotationAngle", "旋转角", "同上：起点固定在正上方，旋转交给「按住圆心 1 秒」的旋转模式"),
    ("Star", "收藏", "旧版圆盘没有收藏（长按图标）功能，0.0.42 随本体一并移交；增删排序全部走编辑器"),
]

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
        dict(k="HeightFraction", cn="高度系数", cell="slider", d=0.62, rng=(0.30, 0.80),
             note="浮窗第一次打开时的高度（占屏幕高度的比例），宽度按画面比例跟随。"
                  "拖动或缩放过的浮窗以它自己的记忆为准；长按底角可复位到这个值。"),
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

    ("Ring", "承载形状", "旧版插件的圆盘整体移入（0.0.42）：呼出、展开、划过、旋转与收藏列表全部按旧版实现 1:1。", [
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
    specs = []
    if panel_id == "Apps":
        # 应用面板原本只有 7 行母本键，没有一处能真正改东西。托盘入口放在
        # 最上面：它的数据是活的（@ring.apps 现读 apps.plist），按钮直达
        # 添加/删除/排序页，和「承载形状」面板里那个是同一个入口。
        specs.append({"cell": "PSGroupCell", "label": "托盘",
                      "footerText": "托盘装哪些 App 由这里决定，改动立刻作用到桌面上的环。"
                                    "不指定时退回系统自动挑选的前 12 个。"})
        specs.append({"cell": "PSTitleValueCell", "label": "已选应用",
                      "key": "@ring.apps", "default": "自动", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "编辑应用（添加 / 删除 / 排序）",
                      "action": "editApps:", "defaults": DOMAIN})
    if panel_id == "Window":
        # 探针放在这一页最上面：这一页的 15 个键都是浮窗参数，但浮窗本身
        # 还没做 —— 先能用同一个入口把「这台设备上到底有什么场景」测出来，
        # 后面写承载层才不是猜。转储在 SpringBoard 里跑，不在这里。
        specs.append({"cell": "PSGroupCell", "label": "探针",
                      "footerText": "浮窗不是塞进桌面的视图，而是自建 UIScene，"
                                    "需要先知道这台 iOS 上场景接口长什么样。"
                                    "四个按钮都把结果写进 /var/mobile/Aevon.log："
                                    "第一个以 scene: 开头，是当前场景与窗口清单；"
                                    "第二个以 scene2: 开头，是承载层的真实方法表（已退役，只剩一行）；"
                                    "第三个以 calls: 开头，把母本用到的每一条调用"
                                    "核对到这台 iOS 上真正定义它的类与签名；"
                                    "第四个以 win: 开头：先装母本那套停用管理钩子（带自检），6 秒后记住你切到的那个 App，"
                                    "你上滑回桌面时卡片才出现。前三个只读；第四个会装钩子，"
                                    "失败时 SpringBoard 可能注销一次。"
                                    "各只执行一次，不会在开机时重放。"})
        specs.append({"cell": "PSButtonCell", "label": "转储场景与窗口（写 Aevon.log）",
                      "action": "sceneProbe:", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "转储承载接口面（方法表）",
                      "action": "sceneSurface:", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "核对调用点（母本 123 条调用）",
                      "action": "sceneCalls:", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "装钩子并建浮窗（切到目标 App，再上滑回桌面）",
                      "action": "sceneWindow:", "defaults": DOMAIN})

    if panel_id == "Ring":
        # 预览放在最上面：预览里跑的就是桌面那一份 AevonRingMenu（旧版 1:1），
        # 展开动画、划过跳跃、阻尼旋转全部是本体，只有「开 App」被拦下弹提示。
        specs.append({"cell": "PSGroupCell", "label": "预览",
                      "footerText": "预览跑的就是桌面那份圆盘（旧版实现 1:1）。"
                                    "动画全是真的，只有开 App 被拦成提示。"})
        specs.append({"cell": "PSTitleValueCell", "label": "当前承载",
                      "key": "@ring.summary", "default": "—", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "预览承载形状（全屏）",
                      "action": "previewRing:", "defaults": DOMAIN})

        # 桌面承载：0.0.6 起 RingHost 把同一个 RingView 挂到桌面右下角。
        # 这个 key 不属于母本 81 键，所以加 "!" 前缀单独记账。
        #
        # 0.1.24 — 竖条整体下线（用户 Aevon(107)：「既然现在改为依赖右缘左滑
        # 触发圆盘，干脆直接移除触发条」）。这一组只剩「装不装」这一个开关了，
        # 文案也不再提竖条。
        specs.append({"cell": "PSGroupCell", "label": "桌面",
                      "footerText": "开启后圆盘挂在桌面上，靠屏幕右缘的左滑手势呼出：" 
                                    "手指贴着右边框、在屏幕**下部 35%**之内向左划，"
                                    "圆盘就从固定点展开。点图标启动 App，按住圆心 1 秒旋转，"
                                    "抬手落在盘外或图标间隙收起。"})
        specs.append({"cell": "PSSwitchCell", "label": "桌面显示圆盘",
                      "key": "!ring.desktop", "default": True, "defaults": DOMAIN})
        specs.append({"cell": "PSTitleValueCell", "label": "桌面状态",
                      "key": "@ring.host", "default": "—", "defaults": DOMAIN})

        # 0.1.24 — 呼盘手势的说明（没有开关了）。
        #
        # 0.1.19 加的「热区覆盖整条右缘」开关在这一版删掉：Aevon(107) 证明整条
        # 右缘能呼出，但用户随即指出「依旧是右侧全部能触发」，要求改回底部 35%
        # 以避免与左滑返回插件冲突。既然只有一个正确答案，就不再给用户一个
        # 会让他自己踩坑的开关。
        specs.append({"cell": "PSGroupCell", "label": "呼盘手势",
                      "footerText": "手指贴着右边框、在屏幕**底部往上 35%** 之内"
                                    "（约 y ≥ 屏幕高度 65% 的位置）向左划，圆盘就展开。"
                                    "上半段整条让给系统与应用自己的返回手势，互不干扰。"
                                    "触发条已移除，屏上不再显示任何常驻标记；"
                                    "键盘弹出时这 35% 也一起让路。"})

        # App 侧激活态桥：浮窗里的内容能不能点，取决于 App 自己是否认为
        # 自己在前台。这一项装在一个独立注入点里（只注入 UIKit，不碰桌面），
        # 关掉即等于回到 0.0.43 的行为，不需要卸载。
        specs.append({"cell": "PSGroupCell", "label": "内容交互",
                      "footerText": "浮窗里的 App 是被另一个进程显示出来的，"
                                    "它自己会认为「我在后台」，UIKit 于是丢掉转发进来的触摸——"
                                    "画面在动、声音在放，就是点不动，这就是原因。"
                                    "开启后，只有当 App 自己的场景设置说「前台」而它自己说「后台」时，"
                                    "才把这个矛盾按前台解释；正常前后台切换不受影响。"
                                    "关掉它立刻回到旧行为，改动对之后打开的 App 生效。"})
        specs.append({"cell": "PSSwitchCell", "label": "内容可点击（App 侧桥接）",
                      "key": "!ring.appHook", "default": True, "defaults": DOMAIN})

        # 应用：这一版起这份清单由操作者自己决定，顺序就是托盘顺序。
        specs.append({"cell": "PSGroupCell", "label": "应用",
                      "footerText": "托盘里放哪些 App、按什么顺序，全部由编辑器决定"
                                    "（上限 36 个，含「截图 / 录屏」两个动作槽）。"
                                    "顺序就是落位顺序：内圈装不下的向外扩圈，"
                                    "圈数由数量自己决定。改动立刻生效，不需要重载。"})
        specs.append({"cell": "PSTitleValueCell", "label": "已选应用",
                      "key": "@ring.apps", "default": "自动", "defaults": DOMAIN})
        specs.append({"cell": "PSButtonCell", "label": "编辑应用（添加 / 删除 / 排序）",
                      "action": "editApps:", "defaults": DOMAIN})

        # 0.1.24 — 「竖条位置」「竖条大小」两组全部删除。
        #
        # 它们控制的东西（`!ring.barY` / `!ring.barLength` / `!ring.barWidth`）
        # 只喂 `RingHost.metrics()`，而那个函数这一版整个下线了。留一组调不出
        # 任何反应的滑块比没有更糟：用户会以为「竖条还在，只是调不出来」。
        #
        # 呼盘几何现在只有一个来源（`stripRect`：贴右缘 18 pt × 底部 35%），
        # 没有可调项，也就不需要任何控件。

        # 0.1.18 — 热区可见层撤除（Aevon(104) 第 3 条：「移除屏幕右侧的手势热区
        # 可见性…它不会占用大部分屏幕右侧的内容，不需要修改了」）。
        # 设置项、`!ring.hotzone` 键、`RingConfig.hotZone`、绘制层一起下线。
        #
        # 0.1.21 — 这一段说明也撤掉：它写的「贴右缘 12 pt 宽、底部 35% 高」已经
        # 和 0.1.20 的实测几何（贴边 18 pt、整条右缘）对不上，留着只会让用户
        # 按错的边界去划。热区本身唯一的说明现在在「呼盘手势」那一组里。


        # 手势：母本把这些写进 GestureIntroduction 原文，圆盘这边没有独立设置项，
        # 但功能必须能被发现 —— 一个只有作者知道的长按，等于没有做。
        specs.append({"cell": "PSGroupCell", "label": "手势",
                      "footerText": "手指划过图标：图标跳起并停住，离开后沉下（GIF 量出的关键帧）。"
                                    "按住圆心 1 秒进入旋转模式（圆心变青绿），再按 1 秒退出。"
                                    "抬手落在图标上=打开，落在圆心=打开本面板，"
                                    "落在盘外或图标间隙=收起。删除 App 只走编辑器。"})
    specs.append({"cell": "PSGroupCell", "label": title, "footerText": intro})
    for it in items:
        specs.append(BUILDERS[it["cell"]](it))
    return {"title": title, "items": specs}


def write_plist(path, obj, text=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        # 用二进制格式：和系统一致，也避免中文 XML 转义问题
        #
        # 0.0.50 — 根面板例外，写成 XML 文本。它里面唯一会随版本变的东西是
        # 「版本」那一行的占位值（`@status.version` 运行时由 Gate 的状态文件
        # 供给，这里的值只在这一行还没加载时显示），可是二进制 plist 每升一次
        # 版本就整体换一份不可 diff 的字节：git 认不出、审阅看不见、推送工具
        # 也只能整块覆盖。XML 之后这一处改动就是一行文本。
        fmt = plistlib.FMT_XML if text else plistlib.FMT_BINARY
        plistlib.dump(obj, fh, fmt=fmt)


# ---------------------------------------------------------------------------
# 根面板：状态 / 安全闸门 / 诊断 都是真功能，其余是入口
# ---------------------------------------------------------------------------

def build_root(panel_items, wired):
    total = panel_items + len(APPS_ITEMS)
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
                  "footerText": f"下面 8 个面板共 {total} 项，母本键与母本一一对应"
                                f"（母本 81 键中有 {len(DROPPED)} 项已明确放弃，"
                                f"名单见交付说明）。点任一项进入该面板；"
                                f"承载形状已整体换成旧版实现，"
                                f"其余面板的开关会写入 com.aevon 域，等对应功能落地后即生效。"})
    for pid, title, _intro in [(p[0], p[1], p[2]) for p in PANELS]:
        # PSButtonCell + 显式 action：0.0.5 用 PSChildPaneSpecifier，这一版 iOS
        # 不给它选中态，8 行全是死的。按钮是唯一不会随框架改版失效的写法，
        # 由 RootListController 自己 push。
        items.append({"cell": "PSButtonCell", "label": title,
                      "action": "openPanel:", "panel": pid})
    items.append({"cell": "PSButtonCell", "label": "应用与全局",
                  "action": "openPanel:", "panel": "Apps"})

    # 快捷入口：不经过面板，直接作用于桌面上的环。面板页的装载一旦在某个
    # iOS 版本上失败，这两个按钮仍然可达 —— 它们是这一版新功能的唯一保证。
    items.append({"cell": "PSGroupCell", "label": "快捷操作",
                  "footerText": "这两个动作不经过面板，直接作用于桌面上的环："
                                "预览用当前参数全屏画一次；应用与排序改的是托盘装哪些 App。"})
    items.append({"cell": "PSButtonCell", "label": "预览承载形状（全屏）",
                  "action": "previewRing:", "defaults": DOMAIN})
    items.append({"cell": "PSButtonCell", "label": "应用与排序（托盘）",
                  "action": "editApps:", "defaults": DOMAIN})

    items.append({"cell": "PSGroupCell", "label": "关于",
                  "footerText": f"Aevon {VERSION} · Swift · arm64e · 8 个面板全部可进入。"
                                f"承载形状：旧版圆盘 1:1 移入——右缘左滑呼出，划过跳跃、"
                                f"阻尼旋转、逐点展开全是本体；应用在编辑器里增删排序"
                                f"（上限 36，含截图 / 录屏动作槽）。"
                                f"0.1.45 起：键盘换算的「屏幕高」改用承载场景的高"
                                f"（上一版用整屏高，与键盘窗高相等，式子退化等于没换算），"
                                f"并加一条无缩放时的平移式取大；"
                                f"通知那侧一个钩子都不挂，只把 SpringBoard 里真实存在的"
                                f"通知类方法名列出来（前几版按名字猜的路全部被真机否掉）。"
                                f"点通知/横幅里的新消息改用悬浮窗打开。"
                                f"其余面板的开关写入域、随对应功能落地。"
                                f"所有改动只写 {DOMAIN}，不触碰系统文件。"})

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
            # 只有真正写进运行参数并被桌面读取的键才标「已接通」，
            # 其余只是写域、功能尚未落地，不能标成一样的状态。
            wired = it["k"] in WIRED_KEYS
            tag = ("<span class='tag tD'>已接通</span>" if wired
                   else "<span class='tag tW'>待接通</span>")
            rows.append(
                f"<tr><td class='num'>{n:02d}</td><td>{esc(title)}</td>"
                f"<td class='mono'>{esc(it['k'])}</td><td>{esc(it['cn'])}</td>"
                f"<td class='ctr'>{CELL_CN[it['cell']]}</td><td class='mono sm'>{esc(rng)}</td>"
                f"<td>{esc(it['note'])}</td>"
                f"<td class='ctr'>{tag}</td></tr>"
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

    panel_items = sum(len(p[3]) for p in PANELS)
    wired = len({it["k"] for p in PANELS for it in p[3]} & WIRED_KEYS)
    write_plist(os.path.join(BUNDLE, "Root.plist"), build_root(panel_items, wired), text=True)
    written.append("Root.plist")

    rows, n = html_rows()
    with open(os.path.join(OUTDIR, "settings-tbody.html"), "w", encoding="utf-8") as fh:
        fh.write(rows)

    ring_keys = [it["k"] for p in PANELS if p[0] == "Ring" for it in p[3]]
    wired = set(ring_keys) & WIRED_KEYS

    manifest = {
        "package": "com.aevon",
        "version": VERSION,
        "domain": DOMAIN,
        "total_母本键": 81,
        "设置项": n,
        "文案键": len(TEXT_KEYS),
        "已接通": len(wired),
        "面板": [
            {"id": p[0], "title": p[1], "count": len(p[3])} for p in PANELS
        ] + [{"id": "Apps", "title": "应用与全局", "count": len(APPS_ITEMS)}],
        "文案键清单": [{"key": k, "cn": c} for k, c in TEXT_KEYS],
        "明确放弃": [{"key": k, "cn": c, "why": w} for k, c, w in DROPPED],
        # 不属于母本 81 键的 Aevon 自有开关，单独记账，避免它们混进复刻进度。
        "自有项": [
            {"key": "!ring.desktop", "cn": "桌面显示圆盘", "cell": "switch",
             "default": True, "wired": True},
            {"key": "@ring.host", "cn": "桌面状态", "cell": "title", "wired": True},
            {"key": "@ring.summary", "cn": "当前承载", "cell": "title", "wired": True},
        ],
        "items": [
            {"panel": p[0], "key": it["k"], "cn": it["cn"],
             "cell": it["cell"], "wired": it["k"] in wired}
            for p in PANELS for it in p[3]
        ] + [
            {"panel": "Apps", "key": it["k"], "cn": it["cn"],
             "cell": it["cell"], "wired": False} for it in APPS_ITEMS
        ],
    }
    with open(os.path.join(OUTDIR, "settings-manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    own = len(OWN_KEYS & {it["k"] for p in PANELS for it in p[3]})
    print("设置项:", n, "（其中自有键:", own, "）| 文案键:", len(TEXT_KEYS),
          "| 明确放弃:", len(DROPPED),
          "| 母本口径合计:", n - own + len(TEXT_KEYS) + len(DROPPED))
    assert n - own + len(TEXT_KEYS) + len(DROPPED) == 81, "与母本 81 键对不上"
    print("plist:", ", ".join(written))


if __name__ == "__main__":
    main()
