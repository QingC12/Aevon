//
//  RingHost.swift — Aevon, the carrier shape on the home screen.
//
//  0.0.42 — the disc is no longer this package's own RingView. It is the
//  operator's archived implementation (D:\备份源码\Aevon, their own code from
//  the 0.2.x/0.3.x line), moved over file by file and kept 1:1:
//
//      AevonRingMenu        the disc: hub, tracks, hover jump, unfold, rotation
//      AevonHoverKeyframes  the GIF-measured rise/land keyframes (V0.3.22)
//      AevonRingUnfold      the scale-from-a-point entrance (V0.3.23)
//      AevonSpring          one response/ζ spring family for every motion
//      AevonRingStore       RingApps list, 36 cap, snapshot, quick-action seed
//
//  What stays here is everything that is genuinely host-side:
//
//    · the window (level normal+1) and the passthrough hit testing,
//    · the window level and its system-overlay exemption (0.0.45): the summon
//      geometry lives above every app so it can be reached from anywhere, and
//      goes away for the three places it must not appear — 锁屏 / 控制中心 /
//      通知中心. Aevon(43) #3 asked for exactly that map.
//    · the entry — 0.1.24: a left swipe starting within 18 pt of the right
//      edge, in the bottom 35 % of the screen. The visible strip (0.0.44, a
//      short vertical bar flush with the edge) is **gone**: Aevon(107)
//      「既然现在改为依赖右缘左滑触发圆盘，干脆直接移除触发条」.
//    · wiring the menu's three hooks (launch / panel / grip visibility) to
//      this package's SceneProbe card route and Settings page,
//    · the Darwin-notification refresh path.
//
//  Deliberate limits, because this runs inside SpringBoard:
//
//    · It never runs when Gate.evaluate() said anything but .pass.
//    · The window returns nil from hitTest everywhere except the disc and the
//      grip. Everything else falls through to the home screen.
//    · `!ring.desktop = false` in Settings removes the window entirely without
//      a respring.
//

import UIKit
// 0.1.17 — 键盘通道走 `CFNotificationCenterGetDarwinNotifyCenter()`。UIKit 会间接
// 带进 CoreFoundation，但这里显式写出来：跨进程通知是本文件唯一依赖 CF 的地方，
// 以后换 import 顺序时不该靠运气。
import CoreFoundation

final class RingHost: NSObject {

    static let shared = RingHost()

    /// Preference key for "put the grip on the home screen". Ships on, because
    /// a shape nobody can see is not a feature. Prefixed with "!" to stay out
    /// of the master's 81 keys and out of the generated table.
    static let enabledKey = "!ring.desktop"

    private var window: UIWindow?

    /* ⛔ 0.1.24 — **竖条（`bar` / `barBlur` / `barPad` / `barFadeTimer`）整条删除。**
     *
     * 用户 Aevon(107)：「既然现在改为依赖右缘左滑触发圆盘，干脆直接移除触发条」。
     * 它从 0.0.44 起就是「入口」本身（点它 / 划过它才呼盘），但 0.1.19 把呼盘
     * 接到右缘手势、0.1.23 又接到应用层 `sendEvent` 之后，它只剩两个作用：
     * 占掉右侧一块像素，以及让设置里那三个滑块还有东西可调。
     *
     * 一并删掉的还有 `BarMetrics` / `metrics()` / `barCentreY()` / `paintBar()` /
     * `revealBar()` / `addBar()` / `setGripVisible()` / `handleBarPan()` 和
     * `RingConfig` 的 `barY / barLength / barWidth`。
     */

    /// 0.1.18 — **热区可见层整条撤除**（0.1.15 ~ 0.1.17 曾在这里画一层淡青色底纹）。
    ///
    /// 用户 Aevon(104) 原话：「移除屏幕右侧的手势热区可见性（其实上一版的 10 pt 时
    /// 从屏幕右侧的边框处左滑时 95 % 会触发也挺好，它不会占用大部分屏幕右侧的内容，
    /// 不需要修改了）」。0.1.15 画它是为了把「够不着」变成看得见的事，目的达到了
    /// （Aevon(102) 33 次点击、Aevon(103) 0 次点击 —— 「要划不要点」已经学会），
    /// 代价是右侧常驻一条青色底纹挡住内容。现在撤掉，判定几何（`stripWidth` 12 pt）
    /// 一个数都不动：**画的不再画，认的还照认**。
    ///
    /// 撤掉的还有 `hotFlash` / `hotLogged` / `hotTint` 与 `RingConfig.hotZone`
    /// —— 留着不用会被 CI 的 `-Werror` 抓（unused variable）。

    /// 0.0.45 — 竖条上那根手指还在屏上。`AevonRingGrip.hasActiveGripTouch`
    /// 从这里取值，圆盘的静默看门狗据此放过「按住不动」的局。
    private var barHeld = false

    /// 0.0.45 — 系统面板（锁屏 / 控制中心 / 通知中心）豁免的定时器与缓存。
    private var overlayTimer: Timer?
    private var overlayCheckedAt: CFTimeInterval = 0
    private var overlayUp = false

    /// 0.1.17 — 键盘在屏。**信号来自应用进程**（见 `AevonAppHook.m` 的
    /// `AevonKbObserve`）：软键盘在 iOS 15+ 属于前台应用那一侧，SpringBoard
    /// 的进程里既没有键盘窗口、也收不到 `UIKeyboardWillShow`，所以这一侧只能
    /// 等 App 进程报。
    ///
    /// 通道是 Darwin 通知 `com.aevon.kb.up`，**租约 3 秒**：App 在键盘在屏期间
    /// 每秒续一次，桌面这一侧只记「最后一次听到的是什么时候」。这样 App 被杀、
    /// 或者切走时那条「收起」没送到，最多 3 秒触发区就自己回来 —— 不像写死的
    /// 布尔那样一旦卡住就永久失灵（0.1.8 的停靠标记踩过这个坑）。
    private var kbAt: CFTimeInterval = 0
    /// 上一次写进日志的键盘状态，只在变化时说话。
    private var kbLogged = false
    /// Darwin 观察者的裸指针，`stop()` 要按同一个人注销。
    private var kbObserver: UnsafeMutableRawPointer?
    /// 租约时长。1 秒心跳 + 3 秒租约 = 丢两条心跳才判死，够宽松。
    private let kbLease: CFTimeInterval = 3.0
    /// 0.1.19 — 呼盘垫上一次的隐藏状态，只在变化时写日志。
    /// 用来把「垫子被键盘/面板收走了」和「手指没落到带子上」分开。
    private var edgeHiddenLogged = false
    /// 0.1.22 — 窗口丢了场景只报一次。那种状态下触摸永远送不进来，
    /// 反复报没有新信息，还会把同一个 tick 的其它证词冲掉。
    private var sceneLostLogged = false
    /// 0.1.23 — 应用层（`UIApplication.sendEvent:`）那条入口的跟踪状态。
    private var edgeWatchStart: CGPoint = .zero
    private var edgeWatching = false
    private var edgeOwned = false
    private var edgeNoteCount = 0
    /// 0.1.17 — 通道名。**两个类型，别合并。**
    ///
    /// 同一对 API 的 name 参数签名不一样，这是 CoreFoundation 的历史遗留：
    ///   · `CFNotificationCenterAddObserver` 要 `CFString?`；
    ///   · `CFNotificationCenterRemoveObserver` 要 `CFNotificationName?`。
    /// 而 `CFNotificationName` 是 `CF_TYPED_ENUM` 导入的独立结构体，不是 `CFString`
    /// 的别名。0.1.17 连续两次推在这一行上：第一次只给 `CFString`，Add 编过了、
    /// Remove 报 `cannot convert 'CFString' to 'CFNotificationName?'`；第二次全换成
    /// `CFNotificationName`，Remove 编过了、Add 反着报 `cannot convert
    /// 'CFNotificationName' to 'CFString?'`。两个常量各规各位。
    ///
    /// 0.1.18 — 一条通道变两条：`kb.up`（在屏，每秒续租）与 `kb.off`（收起，一次性）。
    /// 0.1.17 只有 up，收起只能等 3 秒租约过期（用户 Aevon(104)：「关掉键盘后它还要
    /// 1 秒左右才出现」）。四条常量各管一处，同样不能合并。
    private static let kbUpText = "com.aevon.kb.up" as CFString
    private static let kbUpName = CFNotificationName("com.aevon.kb.up" as CFString)
    private static let kbOffText = "com.aevon.kb.off" as CFString
    private static let kbOffName = CFNotificationName("com.aevon.kb.off" as CFString)
    /// 0.0.47 — 连续两次判真才隐藏。见 `syncOverlayVisibility`。
    private var overlayStrikes = 0
    /// 0.0.47 — 垫子上落过几次手指。前 20 次写进日志，用来分开「没落上」与
    /// 「落上了没被当手势」。
    private var padProbe = 0
    /// 0.0.49 — 上一次写进日志的尺寸（宽×10、长×10 拼成的整数），只用来去重。
    private var laidOutMetrics = 0

    /// 0.1.10 — 应用层那条路（`rawBar`）撤除后，它的四个状态一起删掉：
    /// `rawDownAt` / `rawMovedFar` / `rawOpenedHere` / `barProbe`，以及只服务于
    /// 它的 `discProbe`。留着不用会被 CI 的 `-Werror` 抓（unused variable）。

    /// 0.1.11 — 「这一下不算呼盘」记过几次。0.1.10 时它是
    /// `gestureRecognizerShouldBegin` 的拒绝计数，现在由 `EdgeSwipePad.onReject` 写。
    ///
    /// 0.1.16 — 这个 `#N` 是判据本身：「停在 #1 = 整场只拒过 1 次」。所以它必须
    /// 一直往上数，不能因为「日志太多了」而在某个数上闭嘴 —— 见 `padBlockProbe`。
    private var stripProbe = 0
    /// 0.1.16 — 闸门拒绝（`pad refused by`）与被系统抢断（`pad cancelled`）各自
    /// 一份计数，各自限流。
    ///
    /// 0.1.12 起这三类**共用** `stripProbe < 20` 一个上限，后果在 Aevon(102) 的
    /// 日志里露出来了：33 次未开盘的落指只有 20 次留下 `strip refuse dx=0 dy=0`，
    /// 后面 13 次一声不响 —— 又变回「日志干干净净、可用户明明点了没反应」，
    /// 正是 MEMORY 里那条「静默三态 = 日志无法对账」。每类各留 40 次，够一整场
    /// 正常测试用，又不会把手机写爆。
    private var padBlockProbe = 0
    private var padCancelProbe = 0
    /// 每类证词的上限。40 是「一场 10 分钟的试用里最多能踩多少次」的量级估计，
    /// 不是从数据里算出来的 —— 它只是防刷屏的天花板，不是判据。
    private let probeLimit = 40

    /// 0.0.55 — 右缘左滑呼盘的触摸带。旧版 `AevonRingGrip.bandRect` 的同一套几何：
    /// 贴右缘 15 pt 宽 × 屏幕底部 35 % 高。旧版在这台 17.3.1 上做过 49 次 hold
    /// 的落点统计（12~15 pt 占 84%，0~6 pt 一次都没有），15 pt 是「拇指顶在屏幕外
    /// 时手指中心真正落得到的地方」—— 不是拍出来的值，不要凭手感改。
    private var edgePad: UIView?
    /// 0.0.55 — 上一次由边缘带呼盘的时间。0.6 s 节流，旧版原值：一次呼盘之后
    /// 手指往往还贴着边，没有它，收起的圆盘会被同一段滑动立刻再喊出来。
    private var edgeAt: CFTimeInterval = 0
    /// 旧版常量：底部 35 % / 节流 0.6 s（zoneHDefault）。
    /// 0.1.13 — 节流 0.6 → 0.3 s：用户 Aevon(100) 那句「触发几率很小」里有一截
    /// 是这个 —— 圆盘开了一次又收起，手指还在边上再划，0.6 s 内一律 `pad refused
    /// by throttle`。**新的一次落指是个明确动作**，0.3 s 已足够防「同一段滑动
    /// 把盘再喊一次」。
    ///
    /// 带宽不再用 `edgeWidth`。它就是 `stripWidth`（0.1.16 起 10 pt），两处定义
    /// 会出现「日志说 band=15、实际认 24」这种对不上的情况。
    private let edgeHeightPercent: CGFloat = 35
    private let edgeInterval: CFTimeInterval = 0.3

    private var config = RingConfig()
    private var expanded = false

    /// Cheap change detectors. Comparing a string costs nothing and lets a
    /// rotation or a slider drag skip the rebuild entirely.
    private var appsSignature = ""

    private var observers: [NSObjectProtocol] = []

    // MARK: - Enabled?

    /// Defaults to true only when the key has never been written; an explicit
    /// "off" must survive a respring. Read through the runtime config, so the
    /// switch works even when Preferences and SpringBoard disagree about where
    /// the domain lives on roothide.
    var isEnabled: Bool {
        return RingConfig.loadRuntime().desktop
    }

    // MARK: - Lifecycle

    /// Called once, after the gate said .pass, and again by refresh() when the
    /// operator flips the switch back on.
    func start() {
        guard window == nil else { refresh(); return }

        config = RingConfig.loadRuntime()

        let window = makeWindow()
        window.backgroundColor = .clear
        window.isOpaque = false
        // 0.0.45 — **任何一个页面**都能呼出圆盘（Aevon(43) #3）。
        //
        // `normal + 1` was enough while the bar only had to sit on the home
        // screen: SpringBoard's own windows and the icon layer share that
        // level. A full-screen app brings its own window at `normal`, and the
        // app's scene is composited above the home screen — a bar at +1 ends up
        // underneath it and is simply not there.
        //
        // `statusBar + 1` (1001) is above every app window and still below
        // `alert` (2000), which is where the control centre, the notification
        // centre and the lock screen cover sheet live — so even if the timer
        // below is late, the system's own panels win. The level is not the
        // exemption, it is the layer; the exemption is `systemOverlayUp`.
        // `statusBar + 2` (1002) — 0.0.47 raised it one step. The float card's
        // gesture ring now lives in a window of its own at `statusBar + 1` (see
        // `FloatHost.makeBand`), and that ring covers the right edge where the
        // bar sits. One step above keeps the bar the first thing a thumb finds,
        // which is what 「任何页面都能呼出」 needs.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 2)
        window.rootViewController = UIViewController()
        // 0.1.20 — 留一个具名引用：根视图同时是「边缘带兜底命中」的落点，
        // 见文件末尾 `PassthroughView.hitTest`。
        let host = PassthroughView(frame: window.bounds)
        host.backgroundColor = .clear
        window.rootViewController?.view = host
        window.isHidden = false
        self.window = window

        // The menu's three exits into the world. Set once, before anything can
        // present the disc, so the first tap already has a route home.
        AevonWindowManager.launchHandler = { [weak self] bundleID in
            self?.openFromRing(bundleID)
        }
        AevonEdgeEntry.openPanelHandler = { [weak self] in
            self?.openPanel()
        }
        // 0.1.24 — `AevonRingGrip.setVisibleHandler` 不再注册：它唯一的用途是
        // 「圆盘收起时把竖条亮回来」，而竖条这一版整个下线条了。`AevonRingGrip`
        // 那个兼容层本身不动（菜单 `dismiss()` 里还在调 `setVisible(true)`），
        // 只是没人接这个电话。
        //
        // 0.0.45 — 右缘手势按住期间，圆盘不许因为"静默"自收（手指根本没离开屏幕）。
        AevonRingGrip.activeTouchHandler = { [weak self] in
            self?.barHeld ?? false
        }
        // 0.1.10 — 这里原本还有一条 `AevonRingGrip.barTouchHandler`（应用层
        // sendEvent 入口）。整条撤掉了：呼出只走 `edgePad` 上的识别器，
        // 理由见文件末尾 `gestureRecognizerShouldBegin` 上方那段。

        addEdgePad()
        layout()
        startOverlayWatch()
        startKeyboardWatch()
        syncOverlayVisibility()
        seedStore()

        observe()
        Log.write("ring: hosted on desktop (旧版圆盘 1:1 · AevonRingMenu "
                  + "\(AevonRingStore.bundleIDs().count)/\(AevonRingStore.maxCount))")
        // 0.1.22 — **挂载现场一次性留档。**
        //
        // 「划了没反应」有四种事实：窗口没收到事件、垫子不在带子上、垫子被藏、
        // 判据拒绝。前三种在旧日志里全都长得一样（只有最后一种会说话）。
        // 这一行把窗口与垫子的硬状态一次摆出来，下一份日志一眼就能定位到第几层。
        mountStateLine()

        // Warm the icon cache off the critical path. The first tap must not
        // pay for a LaunchServices enumeration; one second after mount is a
        // quiet moment even on a busy SpringBoard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.preloadIcons()
        }
    }

    func stop() {
        AevonRingMenu.dismissCurrent()
        expanded = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        overlayTimer?.invalidate()
        overlayTimer = nil
        // 0.1.18 — 下次 `start()` 从慢档开始，别继承上一轮「藏起来」的快档。
        overlayFastTick = false
        stopKeyboardWatch()
        AevonRingGrip.activeTouchHandler = nil
        barHeld = false
        overlayStrikes = 0
        padProbe = 0
        // 0.1.16 — 三类证词各自的计数器一起清零，否则「关了再开」之后
        // `strip refuse` 的编号会从上次的位置接着数。
        stripProbe = 0
        padBlockProbe = 0
        padCancelProbe = 0
        // 0.1.19 — 装配状态也一起归零，否则「关了再开」第一次 tick 会拿旧值
        // 判「没变化」而不写日志。
        edgeHiddenLogged = false
        sceneLostLogged = false

        // 0.1.24 — 竖条已整体下线，这里只剩呼盘垫要摘。
        edgePad?.removeFromSuperview()
        edgePad = nil
        window?.isHidden = true
        window = nil
        Log.write("ring: removed from desktop (switch off)")
    }

    /// Settings changed. Re-read the snapshot, refresh the app store, and
    /// either install, remove or reload — never respring.
    func refresh() {
        guard isEnabled else {
            if window != nil { stop() }
            return
        }
        guard window != nil else { start(); return }

        config = RingConfig.loadRuntime()
        // The bar's height on the screen is one of those sliders, so every
        // refresh re-lays out. `layout()` is a handful of frame writes; the
        // cheaper alternative is a bar that only moves after a respring.
        layout()

        // The app list is a separate store with its own lifecycle: the editor
        // writes it, the Darwin notification says "look now", and only a real
        // change is worth a re-read (a slider drag also lands here).
        AevonRingStore.refreshFromSettings()
        let count = AevonRingStore.bundleIDs().count
        let signature = "\(count)/" + AevonRingStore.bundleIDs().joined(separator: ",")
        if signature != appsSignature {
            appsSignature = signature
            Log.write("ring: apps -> \(count) "
                      + (AevonRingStore.bundleIDs().isEmpty ? "(automatic list)" : "(operator list)"))
        }
    }

    // MARK: - Window

    /// A window, not a subview of SpringBoard's own window: the home screen
    /// re-creates its hierarchy on rotation and on app exit, and anything added
    /// straight to it disappears with the next layout pass.
    private func makeWindow() -> UIWindow {
        let window: PassthroughWindow
        if #available(iOS 13.0, *), let scene = mainScene() {
            window = PassthroughWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = PassthroughWindow(frame: UIScreen.main.bounds)
        }
        wireEdgeJudge(window)
        return window
    }

    /// 0.1.22 — 窗口级呼盘判定的接线。
    ///
    /// 几何仍然只有 `stripRect` 一个来源：窗口这边问的是同一个矩形，所以
    /// 「视图命中」和「窗口判定」不会出现两套带宽。
    private func wireEdgeJudge(_ window: UIWindow) {
        guard let w = window as? PassthroughWindow else { return }
        w.edgeRect = { [weak self] in
            guard let self = self, let win = self.window, win.bounds.width > 0 else { return nil }
            return self.stripRect(in: win.bounds)
        }
        // 带子被键盘 / 面板收走时不判：那段时间右缘本来就该还给应用。
        w.edgeArmed = { [weak self] in
            guard let self = self, let pad = self.edgePad else { return false }
            return !pad.isHidden && pad.isUserInteractionEnabled
        }
        // `expanded` 是「这一根手指已经在开圆盘了」。圆盘固定留在屏上
        //（`autoPin`）不算 busy —— 那种情况用户就是想再划一次重摆。
        w.edgeBusy = { [weak self] in self?.expanded ?? false }
        w.edgeOnPhase = { [weak self] phase, from, to in
            self?.handleEdgePhase(phase, from: from, to: to)
        }
        w.edgeTouchNote = { point, inset in
            // 一个格式串，不拼：` inset=` 只有 7 字节，拼出来会被编成立即数。
            Log.write(String(format: "ring: win touch at %.0f,%.0f inset=%.0f",
                             point.x, point.y, inset))
        }
    }

    /// 0.1.22 — 窗口 + 边垫的硬状态，挂载时写一次。
    ///
    /// 这四件事各自都能让「划右缘没反应」而彼此看不出区别：
    /// 窗口没进触摸派发（`scene=nil` / `hidden=1` / `touchable=0`）、
    /// 垫子不在带子上（`pad=` 与 `claim=` 对不上）、
    /// 垫子被藏（`padHidden=1`）、垫子被禁（`padOn=0`）。
    private func mountStateLine() {
        guard let w = window as? PassthroughWindow, let pad = edgePad else { return }
        Log.write("ring: mount state "
                  + String(format: "win=%.0fx%.0f", w.bounds.width, w.bounds.height)
                  + " level=" + String(Int(w.windowLevel.rawValue))
                  + " hidden=" + (w.isHidden ? "1" : "0")
                  + " touchable=" + (w.isUserInteractionEnabled ? "1" : "0")
                  + " scene=" + (w.windowScene == nil ? "nil" : "ok")
                  + " pad=" + String(format: "%.0fx%.0f@%.0f,%.0f",
                                     pad.frame.width, pad.frame.height,
                                     pad.frame.minX, pad.frame.minY)
                  + " padOn=" + (pad.isUserInteractionEnabled ? "1" : "0")
                  + " padHidden=" + (pad.isHidden ? "1" : "0"))
    }

    /// `UIApplication.shared` is a force-unwrapped accessor. Inside SpringBoard
    /// it is normally valid, but "normally" is not a guarantee worth crashing a
    /// phone over: go through the runtime and return nil when there is no app
    /// object yet, so the worst case is a fallback window instead of a crash.
    private func mainScene() -> UIWindowScene? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: selector),
              let unmanaged = meta.perform(selector),
              let application = unmanaged.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        let scenes = application.connectedScenes.compactMap { $0 as? UIWindowScene }
        // 0.1.22 — **优先挂在「前台活跃」的那个场景上。**
        //
        // SpringBoard 可能同时挂着不止一个 `UIWindowScene`（主屏、车机、外接、
        // 锁屏转场中间态）。`first` 拿到的是集合顺序里的第一个，**不保证是
        // 用户正在戳的那块屏**。挂在后台场景上的窗口照样能显示（窗口服务器按
        // level 合成），但触摸派发是**按场景**路由的 —— 那种窗口一个触摸都
        // 收不到，日志里连 `pad down` 都不会有。
        //
        // 这就是「带子明明在、怎么划都没反应」最省事的一种解释，一并按事实排序：
        // 先要前台活跃且铺满屏的，再退到任意一个。
        if let active = scenes.first(where: {
            $0.activationState == .foregroundActive
                && $0.coordinateSpace.bounds.width > 0
        }) {
            return active
        }
        return scenes.first
    }

    private func observe() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIDevice.orientationDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil,
                                               queue: .main) { [weak self] _ in
                guard let self = self else { return }
                // 0.0.49 — 解锁 / 回前台是窗口栈被重排的时刻，先把自己放回顶上，
                // 再按新尺寸重新布局（旋转和分屏也走这里）。
                if name == UIApplication.didBecomeActiveNotification {
                    self.raiseWindow()
                }
                self.layout()
            })
        }
        // The screen's bounds change on rotation and on split-screen size
        // changes; the grip has to stay in the corner in both.
        observers.append(center.addObserver(forName: UIScreen.didConnectNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        })
    }

    private func layout() {
        guard let window = window else { return }
        if #available(iOS 13.0, *), let scene = window.windowScene {
            window.frame = scene.coordinateSpace.bounds
        } else {
            window.frame = UIScreen.main.bounds
        }

        let bounds = window.bounds
        guard bounds.width > 0 else { return }
        // 0.1.22 — **窗口丢了场景 = 一个触摸都收不到。**
        //
        // `UIWindow.windowScene` 是只读的：一旦它变成 nil（场景被系统回收、
        // 或者创建时挂在了后来失效的那个场景上），这个窗口还能被合成出来
        // （所以竖条照样看得见），但触摸派发是按场景路由的 —— 从此这根手指
        // 永远送不进来，日志里连 `pad down` 都没有。只报一次，不刷屏。
        if window.windowScene == nil, !sceneLostLogged {
            sceneLostLogged = true
            Log.write("ring: window lost its scene, touches will not be delivered")
        }

        // 0.1.24 — 竖条下线之后，`layout()` 只剩一件事要做：把呼盘垫放到
        // `stripRect` 上（贴右缘 18 pt × 底部 35 %）。
        //
        // 0.0.48 — 这条带的位置同时交给浮窗那一侧（`AevonRingGrip.summonRect`）：
        // 浮窗的手指入口在应用层就把环上的触摸吃掉了，环的右半边正好压在这里；
        // 没有这条线，卡片开着时贴右缘划会被当成拖浮窗。
        AevonRingGrip.summonRect = stripRect(in: bounds)
        // 0.1.13 — frame 只是外接矩形，真正认领的是 `claimRects`（0.1.16 起只剩
        // 贴边那一列，光环已撤）。外接矩形里剩下的角**不属于我们**，由
        // `EdgeSwipePad.point(inside:)` 退回给应用。
        edgePad?.frame = claimBounds(in: bounds)
        // 0.1.20 — **呼盘垫必须是 `host` 的最上层（圆盘不在屏时）。**
        // 圆盘打的是 `host.bringSubviewToFront(menu)`，它收起之后没有谁把垫子
        // 抬回来；之后再有任何视图被加到 host 上，垫子就沉到下面去了。这条
        // 每次布局纠一次，配合根视图兜底，两条路各自独立。
        if let pad = edgePad, let hostView = window.rootViewController?.view,
           AevonRingMenu.presented == nil {
            hostView.bringSubviewToFront(pad)
        }
        // 0.1.6 — 开关只有一个来源（`syncGrip`）。原来这里直接写
        // `!AevonRingGrip.cardUp`，那是第三个各写一遍的地方：布局写一次、开卡关一次、
        // 面板关回调再写一次，任何一条路没回来，入口就一直是关的。
        syncGrip()
        window.rootViewController?.view.frame = bounds

        // 面板正在上面的时候换了页面（比如通知中心拉下来又弹回去），
        // layout 是唯一会被叫到的地方，顺手把可见性对齐一次。
        syncOverlayVisibility()

        // 0.1.24 — **呼盘几何改成无条件报一次（按值去重）。**
        //
        // 竖条没了，`bar position …` 那条自带 `claim=` 的日志也跟着没了。可
        // 「热区到底在哪」是后续每一轮排查的第一句问话，必须留在日志里：
        // `claim=18x326 at y=606` 就是「贴右缘 18 pt × 底部 35 %」的实测值，
        // 判据在日志里自证，不靠记忆。
        let claim = stripRect(in: bounds)
        let claimKey = Int(claim.minY) * 1000 + Int(claim.height)
        if claimKey != laidOutMetrics {
            laidOutMetrics = claimKey
            Log.write(String(format: "ring: edge claim=%.0fx%.0f at y=%.0f bottom-35%%",
                             stripWidth, claim.height, claim.minY))
        }
    }

    /// 0.0.55 — 右缘那条「贴边左滑呼盘」的触摸带（移植旧版 V0.3.28 AevonEdgeBandOnly328）。
    ///
    /// 为什么不是 `UIPanGestureRecognizer`：旧版自建腿用的就是系统那个
    /// `UIScreenEdgePanGestureRecognizer`（`edges = .right`），它自己只认「从屏幕
    /// 边缘起手 + 横向划」—— 竖着划会识别失败并把手指还给 App，这正是我们要的
    /// 那一半放行。换成通用 pan，右缘上下滚动也会被算成呼盘。
    ///
    /// 它和竖条的 `barPad` 是两块互不相干的地盘：竖条在屏幕高度 50 % 附近，
    /// 这条在底部 35 %，各挂各的识别器，谁都不改谁的帧。
    ///
    /// 0.1.7 — **改成贴右缘、全高、14 pt 的一条，并且这是唯一还接触摸的那一块。**
    ///
    /// 用户 Aevon(94) 第 1 条把习惯说清楚了：「我更加喜欢手势贴近右侧屏幕和边框
    /// 边缘向左滑动触发圆盘」。原来这条只占底部 35 %，而竖条的 pad 是 40×212 的
    /// 隐形大块、还带点击 —— 于是「在卡片里点右侧」会呼出圆盘、「在别处左滑」又
    /// 落不到这条带上。现在几何只有一个：右缘 14 pt × 全高（让开顶部 10 pt 状态栏
    /// 与底部 12 pt home 条），条子上只有「从屏幕边缘起手 + 向左划」这一种手势。
    /// 0.1.10 — 撤掉 `sendEvent` 自研判据，改交给 UIKit 手势仲裁。
    /// 0.1.11 — 再退一步：连 `UIPanGestureRecognizer` 也不用，判定搬进 pad 的
    /// `touchesMoved`（见 `EdgeSwipePad`）。
    ///
    /// 两次退的教训合起来是一句话：**「什么时候问」比「问什么」更致命。**
    /// 0.1.10 的方向判据本身没错，错在它跑在 `gestureRecognizerShouldBegin` 里 ——
    /// 那一拍 `translation` 只有 10 pt 上下，`-12` 的线永远够不到，而返回 false
    /// 又让识别器整根作废（Aevon(98) 三次样本 −11/−4/−0，一个盘都没出来）。
    /// 自己收 `touchesMoved` 就没有这个问题：位移随时可查、判据随时可下、认输
    /// 也是随时可认，不需要跟 UIKit 的时机对齐。
    ///
    /// Aevon 从 0.0.49 到 0.1.9 的十几次「透传」是 `sendEvent:` 自建通道的债；
    /// 0.1.10 的「呼不出」是把手势语义借给别人、又借错了时机的债。现在这条带上
    /// 只有一种事件源（`UIView` 触摸回调），序列天然完整，不存半截态。
    private func addEdgePad() {
        guard let host = window?.rootViewController?.view else { return }
        let pad = EdgeSwipePad(frame: .zero)
        pad.backgroundColor = .clear
        pad.isUserInteractionEnabled = true
        // 0.1.11 — **不再挂 `UIPanGestureRecognizer`，也不再有
        // `gestureRecognizerShouldBegin`。**
        //
        // 0.1.10 真机日志（Aevon(98)）把那条路判死了：
        //     ring: strip refuse dx=-11 dy=0 #1
        //     ring: strip refuse dx=-4  dy=0 #2
        //     ring: strip refuse dx=-0  dy=0 #3
        // 三次左滑全被 `t.x <= -12` 挡掉。UIKit 调 `gestureRecognizerShouldBegin`
        // 的时机就是「pan 自己刚够到启动线」那一拍，此刻 `translation` 只有 10 pt
        // 上下（-11 已是最大样本），**-12 永远不可达**；而 shouldBegin 返回 false
        // 会让识别器直接 failed —— 这一根手指之后再滑多远都不会再问一次。
        // 于是「一个都呼不出来」。
        //
        // 现在把判定搬进 pad 自己的 `touchesMoved`：位移由我们累积，够左才
        // 「开」，往右或竖向占优就「收手」，全程不依赖 UIKit 何时来问。
        //
        // 0.1.12 — 闸门从 Bool 改成「原因串」：被挡住也要说话。Aevon(99) 那
        // 份日志里 5 分半只有 2 次落指，而「没落到带上」「落上了被挡住」「放行了
        // 没滑够」三种事实完全同形（都是缺 `open at`），只能靠原因串拆开。
        pad.blockReason = { [weak self] in
            guard let self = self else { return "gone" }
            // 面板在屏：右缘整条让给面板自己（0.0.56 的语义）。
            if AevonAppPanel.current != nil { return "panel" }
            // 圆盘已经在屏：这一下不是「呼出」，收手。
            // 0.1.19 — 只有**没固定住**的盘才拒绝。固定住的盘（抬手未选中但开着
            // 「展开后固定」）应该被下一次边缘滑动拖走重摆；否则用户会看到
            // 「盘还在屏上，但划边缘一点反应都没有」—— 那是 0.1.18 的死角。
            if let menu = AevonRingMenu.presented, !menu.isPinned { return "ring" }
            // 连击节流：一次呼盘之后手指往往还贴着边，没有它同一段滑动会把盘再
            // 喊一次。0.1.13 起 0.3 s（原 0.6 s）：太快了会把「收起来再划一次」
            // 也一起拒掉，用户感觉就是「时灵时不灵」。
            if CACurrentMediaTime() - self.edgeAt <= self.edgeInterval { return "throttle" }
            return nil
        }
        pad.onPhase = { [weak self] phase, from, to in
            self?.handleEdgePhase(phase, from: from, to: to)
        }
        // 0.1.13 — **`yieldsToRing` 撤掉。** 它原来是「圆盘在屏时 `hitTest` 返回
        // nil」，本意是把右缘还给圆盘。但 nil 的含义是「这块不归我」，而圆盘挂在
        // 圆心 (215,699)、外圈半径 108 —— 最右才到 x=323，**永远够不到 404 以外的
        // 这条带**。所以那块地不是还给了圆盘，是还给了下面的应用：用户在圆盘开着
        // 的时候贴着右缘一划，收到的是应用的左滑返回。用户 Aevon(100) 第 2 条
        // 「触发条区域中还有几率触发左滑返回」的一条路就在这儿。
        //
        // 现在这条带在任何时候都只归我们：圆盘开着就认「这一下不开盘」并吃掉，
        // 应用一条都收不到。
        pad.claimRects = { [weak self] in
            guard let self = self, let window = self.window else { return [] }
            return self.claimRects(in: window.bounds)
        }
        // 0.1.12 — 落指无条件报点：这一行证明「手指真的落在这条带上」，是
        // 「没落到带上」与其余失败原因的唯一分界线。
        // 0.1.13 — 附带离右缘多少 pt：Aevon(100) 里 14 次落指全在 3~6 pt，说明
        // 用户的习惯是「顶到边缘」；以后调带宽不用再猜。
        pad.onDown = { [weak self] at in
            let inset = (self?.window?.bounds.maxX ?? at.x) - at.x
            // 一个格式串，不拼 —— ` inset=` 只有 7 字节，拼出来的话会被编成立即数，
            // 二进制里 grep 不到（audit 断言就白写一条）。
            Log.write(String(format: "ring: pad down at %.0f,%.0f inset=%.0f",
                             at.x, at.y, inset))
        }
        pad.onBlocked = { [weak self] reason in
            guard let self = self, self.padBlockProbe < self.probeLimit else { return }
            self.padBlockProbe += 1
            Log.write("ring: pad refused by " + reason
                      + " #" + String(self.padBlockProbe))
        }
        pad.onReject = { [weak self] delta in
            guard let self = self, self.stripProbe < self.probeLimit else { return }
            self.stripProbe += 1
            Log.write("ring: strip refuse dx=" + String(format: "%.0f", delta.width)
                      + " dy=" + String(format: "%.0f", delta.height)
                      + " #" + String(self.stripProbe))
        }
        pad.onCancel = { [weak self] delta in
            guard let self = self, self.padCancelProbe < self.probeLimit else { return }
            self.padCancelProbe += 1
            // 未开就被抢断 = 「滑了没反应、日志还干净」的唯一来源，必须留证词。
            Log.write("ring: pad cancelled dx=" + String(format: "%.0f", delta.width)
                      + " dy=" + String(format: "%.0f", delta.height)
                      + " #" + String(self.padCancelProbe))
        }
        // 0.1.7 — 点击识别器不挂。用户明确要求「移除点击触发圆盘，只保留左滑」。
        host.addSubview(pad)
        edgePad = pad
        // 0.1.20 — 根视图兜底：右缘那一条永远轮得到我们，不管上面盖了几层。
        if let shield = host as? PassthroughView {
            shield.fallbackHit = pad
            shield.fallbackRect = { [weak self] in
                guard let self = self, let window = self.window else { return nil }
                return self.stripRect(in: window.bounds)
            }
        }
    }

    /// 0.1.17 — 呼盘命中区的贴边列宽。唯一一处几何定义。
    ///
    /// 一路的量：0.1.13 = 24、0.1.15 = 40（另加 108×248 的光环宽区）、0.1.16 = 10、
    /// 0.1.17 = 12、0.1.20 = 18。
    ///
    /// Aevon(103) 的真机日志证明 10 pt 这边已经到边了：25 次落指 **25 次全开**
    /// （判据零失败），但 inset 分布是 `4:1 / 7:3 / 8:3 / 9:11 / 10:7` ——
    /// **18 次挤在 9 和 10**，也就是说用户每次都贴着这条线的边界落指，再往里
    /// 一点就掉出去了。用户的原话是「窄了很多，灵敏度也下降了」，要求 +2。
    ///
    /// 12 的依据不是手感，是这条分布：中位 9、最大值正好 10，说明「够得着的
    /// 习惯落点」在 9 上下浮动 ±2；12 把这段浮动的上沿包进来，又不会回到 24/40
    /// 那种「认领一大片、应用拿不到手指」的老毛病。
    ///
    /// ⛔ **0.1.20 起 12 → 18。** 0.1.19 把带子拉成全高、宽度仍是 12，用户回的是
    /// 「这一版依旧无法呼出圆盘，触发条自动消失后，无法通过右侧的触发区呼出
    /// 圆盘」。12 是「有可见竖条当路标」时量出来的：竖条亮着，手指是**对着那条
    /// 亮线**落的，落点自然压在 9~12。0.1.18 起竖条 0.5 s 就淡出，路标没了，
    /// 用户只能凭「大概贴边」落指，落点整体往里挪了 —— 12 pt 里那 3 pt 的余量
    /// 就不够了。18 把「凭感觉贴边」的落点包进来，代价是右缘多认领 6 pt；
    /// 24/40 那两版的问题是「吃掉应用右缘一整片」，18 到 24 之间才是那片地的边。
    private let stripWidth: CGFloat = 18
    /// 0.1.11 — 「认作左滑的最小横向位移」这个常量搬进了 `EdgeSwipePad.openDistance`
    /// （10 pt）。原来这里是 12 并且用于 `gestureRecognizerShouldBegin`，那一拍
    /// `translation` 只有 10 pt 上下，12 永远够不到 —— 就是 Aevon(98)「呼不出」的死因。

    /// 0.1.8 — 高度回到「从底部往上 35 %」（`edgeHeightPercent`）。
    ///
    /// 0.1.7 把它做成了全高（让开顶 10、底 12），本意是「贴边哪一段左滑都能呼盘」，
    /// 真机结果是**和左滑返回插件抢整条右缘**：Aevon(95) 第 2 条原话「现在屏幕右侧
    /// 整个边缘向左滑动都会触发圆盘，不会触发 app 内的操作，但是它和我安装的左滑
    /// 返回插件冲突」。右滑返回在全高每一段都要用，圆盘只需要一个够得着的角落。
    ///
    /// 所以高度收回 35 %，位置在底部 —— 拇指自然够得到，屏幕中上部整条让给系统
    /// 与插件。这一条同时把 0.1.6 那个「卡片里点右侧任意位置误触」的根也压住了：
    /// 命中区只有右下角这一块 14 × 326。
    private func stripRect(in bounds: CGRect) -> CGRect {
        // 0.1.24 — **定稿在「底部往上 35 %」，不再有整条右缘这一档。**
        //
        // 时间线：0.1.8~0.1.18 一直是底部 35 %；0.1.19 因为竖条淡出后失去路标，
        // 用户「隐藏触发条之后呼不出圆盘」，才放到整条右缘。0.1.23 换到应用层
        // `sendEvent` 之后通道终于通了，Aevon(107) 的 13 次呼盘全部成功，但用户
        // 随即指出「右侧全部能触发」——**这正是 0.1.8 就记下的那条代价**：
        // 整条右缘和左滑返回插件抢同一片地。
        //
        // 现在竖条整体下线（用户原话「干脆直接移除触发条」），路标问题不存在了，
        // 于是回到 35 %：屏幕中上部整条让给系统与应用自己的返回手势，只有拇指
        // 自然垂落的那一段归我们。
        //
        // Aevon(107) 的落点分布正好落在这一档里（y = 434/567/655/666/694/704/
        // 716/723/725/726/728/737，932 的 65 % = 606，主力在 655~737）。
        let h = bounds.height * edgeHeightPercent / 100
        return CGRect(x: bounds.maxX - stripWidth,
                      y: bounds.maxY - h,
                      width: stripWidth,
                      height: Swift.max(0, h))
    }

    /// 0.1.16 — 认领的地盘只剩**一条**：贴右缘 10 pt × 底部 35 %。
    ///
    /// 0.1.13~0.1.15 这里是两块（列 + 抓手光环）。光环撤掉的账见 `stripWidth`
    /// 上方：它确实接住了 6 次「没对准」的落指（inset 32~81），但它同时也把
    /// 右侧一大片地认领掉了 —— 用户选择「宁可难，也别吃应用」。
    ///
    /// **认领 = 应用拿不到这一根手指**（窗口在上层，没有「先收下再还回去」这回事），
    /// 所以形状必须跟「看得见的东西 + 拇指落得到的地方」对齐，能小就不大。
    private func claimRects(in bounds: CGRect) -> [CGRect] {
        guard bounds.width > 0 else { return [] }
        return [stripRect(in: bounds)]
    }

    /// 认领区的外接矩形，也就是 `edgePad` 的 frame。命中与否由
    /// `EdgeSwipePad.point(inside:)` 按 `claimRects` 再判一次 —— 外接矩形里
    /// 不属于任何一块的那些点必须**放行**，否则整块 frame 会被吃掉。
    /// 0.1.16 只剩一条矩形，frame 与 `claimRects` 此刻重合；这个函数保留是为了
    /// 以后再加形状时不用改调用方。
    private func claimBounds(in bounds: CGRect) -> CGRect {
        let rects = claimRects(in: bounds)
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// 0.0.55 — 浮窗开/关时同步右缘带能不能接触摸。
    ///
    /// 只在 `layout()` 里同步是不够的：卡片是在两次布局之间打开的，那段时间
    /// 边缘带还开着，右下角的手会先落进带子里 —— 守卫里那句 `cardUp` 能拦住
    /// 呼盘，拦不住「这根手指已经被吃掉」。
    func setEdgeActive(_ active: Bool) {
        // 0.1.6 — 参数留着只为不改调用方；真正写下去的值由 `syncGrip()` 现算。
        //
        // `closeCard` 里那句 `setEdgeActive(true)` 在 `clearHosted` **之前**跑，
        // 那一刻停靠小窗的宿主还在，按参数照写就会把带宽重新压到小窗上。现算
        // 就没有这个先后问题：问的是「此刻还有没有卡」。
        _ = active
        syncGrip()
    }

    /// 0.1.6 — 右缘带的触摸开关，唯一来源（0.1.24 起竖条已不在，只剩这一条带）。
    ///
    /// 之前是三处各写一遍：`layout()` 按 `AevonRingGrip.cardUp` 写、`openPanel()`
    /// 关一次、面板 `onClose` 再写回。三个写点排在一起看不出问题，可它们之间
    /// 只要有一条路没走到 —— 面板被 `present` 的「换一个新的」那条路直接摘掉
    /// （那条路不回调 `onClose`）、卡片在两次布局之间开合、关主窗时小窗还留着 ——
    /// 就会留下一个**关死的入口**，直到重启桌面。用户看到的就是「右侧呼不出
    /// 圆盘」。
    ///
    /// 现在按事实现算，并且挂在 0.4 s 那条 tick 上：任何一次状态来不及恢复，
    /// 下一个 tick 都会把它纠正回来。
    func syncGrip() {
        // 0.1.6 — 带的几何也一起对齐。`layout()` 里有 `bounds.width > 0` 的早退，
        // 窗口尺寸还没到位时那一拍不会写 `summonRect`，留一个 `.zero` 在里面就等于
        // 「带子看得见、按下去不算我的」。这里每 tick 补一次，代价是一次 CGRect 赋值。
        //
        // 0.1.7 — 写的是**贴边条带**，不是那块 40×212 的视觉垫子（垫子 0.1.24 已删）。
        if let window = window, window.bounds.width > 0 {
            AevonRingGrip.summonRect = stripRect(in: window.bounds)
        }
        // 0.1.20 — 每 tick 确认呼盘垫还在 `host` 的最上层（圆盘不在屏时）。
        // 只在「它已经不是最后一个」时才重排，正常情况零成本。
        if let pad = edgePad, !pad.isHidden, AevonRingMenu.presented == nil,
           let hostView = window?.rootViewController?.view,
           hostView.subviews.last !== pad {
            hostView.bringSubviewToFront(pad)
        }
        let panel = AevonAppPanel.current != nil
        let card = FloatHost.anyCardUp
        // 0.1.10 — **不再是 `!panel && !card`。**
        //
        // 0.0.55 关掉这条带是因为「卡片右下角拖拽的手会先落进带子里」。那是
        // 自建触摸区的年代：进了带子就等于被吞，卡片的拖动直接没了。
        //
        // 换成手势识别器之后这条顾虑不成立了 —— 方向不达标（纵向拖、斜着拖）
        // `gestureRecognizerShouldBegin` 返回 false，UIKit 把**整根**序列还给
        // 卡片，拖动一点不受影响。反过来，卡片在屏时这条带必须开着：用户 Aevon(97)
        // 第 1 条「从右侧屏幕边缘向左滑触发全屏 App 内操作」就是它被关掉造成的
        //（日志 `ring: grip armed bar=1 edge=0 card=1`：卡片在屏 → 带子闭嘴 →
        // 右缘左滑整条落到 App 进程，SpringBoard 连事件都收不到）。
        let edgeOn = !panel
        // 0.1.6 那个「开关唯一归口」的兑现：三处各写一遍的老写法（layout /
        // openPanel / onClose）全撤之后，这里是唯一还会碰它的地方。
        if edgePad?.isUserInteractionEnabled != edgeOn {
            edgePad?.isUserInteractionEnabled = edgeOn
        }
        guard edgeOn != gripLoggedEdge else { return }
        gripLoggedEdge = edgeOn
        // 一整条字面量前缀（不是拼接）：审计要在二进制里 grep 到它。
        Log.write("ring: grip armed edge=" + (edgeOn ? "1" : "0")
                  + " card=" + (card ? "1" : "0")
                  + " panel=" + (panel ? "1" : "0"))
    }

    /// 上一次写进日志的开关值，只用来去重。
    private var gripLoggedEdge = true

    /* ⛔ 0.1.23 — **呼盘判定搬到 `UIApplication.sendEvent:` 上。**
     *
     * 三层都试过了，一层一层被日志否掉：
     *   · 0.1.10~0.1.21 挂 `edgePad`（视图命中）⇒ Aevon(105) 零 `pad down`；
     *   · 0.1.20 加 `PassthroughView.hitTest` 兜底 ⇒ 同上，连兜底那行都没有；
     *   · 0.1.22 搬窗口的 `sendEvent` ⇒ Aevon(106) 整份日志**零 `win touch`**。
     *
     * 而 0.1.22 的 `mount state` 在同一份日志里是全绿的：
     * `win=430x932 level=1002 hidden=0 touchable=1 scene=ok pad=18x912@412,8 padOn=1`。
     * 窗口没被藏、没被禁、场景在、垫子几何正确 —— 可 `sendEvent` 一次没被调用。
     * 唯一的解释是 `UIApplication` 派发时**根本没选中这个窗口**（`_hitTestWindow`
     * 按它自己的顺序问，问到哪一层返回 nil 就跳过一个窗口）。
     *
     * 这条结论项目里早就写下过一遍，只是写的是浮窗（见 `AevonScene.m`
     * 「卡片外面没有一个触摸进过我们的任何窗口」那段）：`-[UIApplication
     * sendEvent:]` 是唯一一个不管命中哪个窗口都会经过的地方。浮窗的五个手势
     * 就是靠它工作的 —— 所以那个入口在 SpringBoard 里**确定是通的**。
     *
     * 现在把右缘判定也挂在那里：`AevonScene.m` 的 `AevonSendEventReplacement`
     * 先问浮窗（`AevonFloatTouch`），没被吃掉再问这一层。
     *
     * 判据与 `EdgeSwipePad` 完全一致（8 pt 开 / 16 pt 认输 / `*0.7` 斜度容忍），
     * 只是位移由这里自己累积 —— 两者共用一个来源 `stripRect`，不会出现两套带宽。
     *
     * - Parameter phase: `UITouchPhase` 原值（0 began / 1 moved / 2 stationary /
     *   3 ended / 4 cancelled）。
     * - Returns: 这一拍要不要吞掉（不往应用传）。
     */
    func edgeTouch(phase: Int32, x: Double, y: Double) -> Bool {
        guard let window = window, window.bounds.width > 0,
              let pad = edgePad else { return false }
        let point = CGPoint(x: x, y: y)

        switch phase {
        case 0:  // began
            // 键盘 / 面板在屏时带子收走，右缘整条还给应用。
            guard !pad.isHidden, pad.isUserInteractionEnabled,
                  stripRect(in: window.bounds).contains(point) else {
                edgeWatching = false
                return false
            }
            edgeWatchStart = point
            edgeWatching = true
            edgeOwned = false
            if edgeNoteCount < 20 {
                edgeNoteCount += 1
                // 一个格式串，不拼：` inset=` 只有 7 字节，拼出来会被编成立即数。
                Log.write(String(format: "ring: app touch at %.0f,%.0f inset=%.0f",
                                 point.x, point.y, window.bounds.maxX - point.x))
            }
            // 第一拍不吞：应用该收到的 `began` 照常收到。只有真的判成左滑之后
            // 才从那一刻起接管，方向不对应用全程无感。
            return false

        case 1, 2:  // moved / stationary
            guard edgeWatching else { return false }
            if edgeOwned {
                handleEdgePhase(.moved, from: edgeWatchStart, to: point)
                return true
            }
            let dx = point.x - edgeWatchStart.x
            let dy = point.y - edgeWatchStart.y
            if dx <= -8, abs(dx) >= abs(dy) * 0.7 {
                // 已经在开圆盘了（另一条入口先到）：别抢，也别吞。
                if expanded { edgeWatching = false; return false }
                edgeOwned = true
                handleEdgePhase(.began, from: edgeWatchStart, to: point)
                return true
            }
            // 认输要决定性：走够 16 pt 且方向明确不横，才放弃这一根。
            if dx >= 16 || (abs(dy) >= 16 && abs(dy) > abs(dx)) {
                edgeWatching = false
            }
            return false

        case 3:  // ended
            guard edgeWatching else { return false }
            edgeWatching = false
            guard edgeOwned else { return false }
            edgeOwned = false
            handleEdgePhase(.ended, from: edgeWatchStart, to: point)
            return true

        case 4:  // cancelled
            guard edgeWatching else { return false }
            edgeWatching = false
            guard edgeOwned else { return false }
            edgeOwned = false
            handleEdgePhase(.cancelled, from: edgeWatchStart, to: point)
            return true

        default:
            return false
        }
    }

    /// 右缘的滑动。语义与竖条那条完全一致（落指 → 圆盘从这一点长出来 → 跟随 →
    /// 抬手定生死），只是入口不同：竖条要**按住它**，这里只要**贴着右缘往左划**。
    ///
    /// 0.1.11 — 方向与节流全部前移到 `EdgeSwipePad` 内部（位移由它自己累积，
    /// 够左才报 `.began`）。所以 `.began` 进来时必是「贴边向左滑」，这里没有任何
    /// 早退分支：进得来就一定弹盘。
    ///
    /// 坐标已由 pad 转成 window 坐标（`from`/`to`），和旧 `location(in: window)` 同口径。
    private func handleEdgePhase(_ phase: EdgeSwipePad.Phase,
                                 from: CGPoint,
                                 to: CGPoint) {
        guard let window = window, let host = window.rootViewController?.view else { return }
        let point = to
        switch phase {
        case .down:
            break

        case .began:
            edgeAt = CACurrentMediaTime()
            barHeld = true
            /* 0.1.24 — 竖条已经下线，这里不再有「亮 0.5 s」那一下。
             * 整个屏幕在这一刻起不再有任何常驻或闪现的标记 —— 用户要的就是这个。
             */
            /* 0.1.20 — **僵尸盘先清掉，再开盘。**
             *
             * 0.1.19 的写法是「`presented` 非 nil 就把它当成在屏上的盘，只喂跟手」。
             * 可 `presented` 只是静态变量 `current`，它和「屏上真有一个能看见的盘」
             * 不是一回事：`dismiss()` 的动画跑完、视图被摘掉、或者圆盘被别的路径
             * 从 `superview` 上摘走之后，`current` 仍可能留着。那种时候边缘一划，
             * 代码走进「跟手」分支，屏幕上什么都不出现 —— 用户看到的就是
             * **「贴边划了，一点反应都没有」**，而且日志里连 `edge swipe open`
             * 都不会有（那一行只在 `else` 分支里）。
             *
             * 判据只用两条硬事实：`superview` 和 `window`。两者任一为空，这个盘
             * 在物理上就不可能被看见 / 被摸到，先 `dismissCurrent()` 把它归零
             * （`dismiss()` 会同步写 `current = nil`），再走正常开盘。
             */
            if let menu = AevonRingMenu.presented, menu.superview != nil, menu.window != nil {
                menu.beginRemoteTracking(at: point, source: "edge")
            } else {
                if AevonRingMenu.presented != nil {
                    Log.write("ring: stale disc cleared before summon (not on screen)")
                    AevonRingMenu.dismissCurrent()
                }
                expanded = true
                AevonRingMenu.presentTracking(in: host, at: point, source: "edge")
                // 0.1.24 — 带子的高度一起报。热区定稿在「底部往上 35 %」之后，
                // 这一行是「手指那条高度到底在不在带子里」的唯一判据：
                // 430×932 上应当是 `band=18x326`，起点 y ≥ 606。
                Log.write("ring: edge swipe open at "
                          + String(format: "%.0f,%.0f", point.x, point.y)
                          + " band=" + String(format: "%.0f", stripWidth)
                          + "x" + String(format: "%.0f", stripRect(in: window.bounds).height)
                          + " bottom-35%")
            }

        case .moved:
            guard barHeld else { return }
            // 0.1.20 — **不再调 `remoteAnchor`**（跟手已撤，用户 Aevon(105)）。
            // 圆心由 `computeGeometry` 固定成「中心偏下、右移 10 % 屏宽」。
            // 指针喂料保留：它负责角度 / 高亮 / 抬手判定，与圆心位置无关。
            AevonRingMenu.presented?.remoteMoved(to: point, source: "edge")

        case .ended:
            guard barHeld else { return }
            barHeld = false
            expanded = false
            guard let menu = AevonRingMenu.presented else { return }
            menu.remoteLift(at: point, source: "edge")
            Log.write("ring: edge swipe released at "
                      + String(format: "%.0f,%.0f", point.x, point.y))

        case .cancelled:
            guard barHeld else { return }
            barHeld = false
            expanded = false
            guard let menu = AevonRingMenu.presented else { return }
            // 系统抢断（来电、控制中心、来电浮层、别的识别器优先）时要有证词，
            // 否则「滑到一半圆盘没了」和「我们自己的 bug」分不开。
            menu.remoteCancelled(source: "edge")
            Log.write("ring: edge swipe cancelled by the system")
        }
    }

    /* ⛔ 0.1.24 — 竖条那一套方法整段删除：
     *   `setGripVisible`（圆盘开合时调竖条透明度）
     *   `paintBar`（自适应配色 + 0.5 pt 描边）
     *   `revealBar`（亮 0.5 s 再淡出）
     *   `toggle`（点竖条开合）
     *   `handleBarPan`（按住竖条拖动）
     * 它们全都要么读写 `bar`/`barBlur`/`barPad`，要么只服务「点竖条」这条入口。
     * 呼盘现在只有一条路：右缘左滑（`edgeTouch` / `EdgeSwipePad`）。
     */

    // MARK: - 0.1.10 应用层触摸入口已整条撤除（母版路线）
    //
    // 0.0.49~0.1.9 这里曾有一条 `rawBar(phase:at:stamp:)`：由 `-[UIApplication
    // sendEvent:]` 喂进来，自己按坐标判是不是落在右缘、自己维护 `stripHeld` /
    // `barTracked` / `rawMovedFar` 状态机、自己决定哪一相位吞哪一相位放行。
    //
    // 那条路是所有「透传 / 半截 / 假点击」的来源：`sendEvent` 只有一个事件的
    // 视野，没有「这根手指整段归谁」的概念 —— began 吞了、moved 放行、ended 再吞，
    // App 那边看到的就是一根残缺的手指。
    //
    // 0.1.11 起呼出入口只剩 `edgePad`（`EdgeSwipePad`）自己收的 `touchesBegan`
    // 一族：位移在 pad 里累积，够左才弹盘、不达标就当没发生（连 super 都不调，
    // 事件不上传）。0.1.10 那版把判定放在 `gestureRecognizerShouldBegin` 里，
    // 结果被 UIKit 的调用时机卡死（`translation` 只有 10 pt，门槛却是 12）——
    // 这条注释留着是为了让后来的人知道「这里曾经有过什么、为什么删」，而不是
    // 又一次把它加回来。


    /// 0.0.49 — 把这一层重新插回窗口栈顶。
    ///
    /// Aevon(47) #3 的现象是「注销后第一次非常灵敏，锁屏一次之后就不容易触发」。
    /// 条子的位置、长度、宽度都没变（日志里 `size=` 一直是同一组数），变的只有
    /// 窗口栈：锁屏 → 解锁会让 SpringBoard 重排一遍窗口，我们这一层可能被一个
    /// **透明但会接触摸**的窗口压住 —— 条子照样看得见（上面那层是透明的），按下去
    /// 却不算我们的。所以每次解锁 / 回到前台，把 level 抬一格再放回去：UIKit 在
    /// 每次 level 变化时都会把窗口重新插进窗口栈，这一下就是置顶，而且不重建
    /// 窗口、不碰 rootViewController、不丢已经挂上的手势。
    ///
    /// 0.1.24 — 竖条没了，但这条**必须留着**：它保护的是窗口本身（呼叫垫的命中
    /// 依赖它在上层），不是那根可见的条子。
    private func raiseWindow() {
        guard let window = window, !window.isHidden else { return }
        let level = window.windowLevel
        window.windowLevel = UIWindow.Level(rawValue: level.rawValue + 1)
        window.windowLevel = level
        window.isHidden = false
        Log.write("ring: host layer put back on top (level="
                  + String(Int(level.rawValue)) + ")")
    }

    // MARK: - 0.0.45 系统面板豁免

    /// 锁屏 / 控制中心 / 通知中心 —— 呼盘带在这三处不出现（Aevon(43) #3）。
    ///
    /// 窗口层级（statusBar + 1）已经把这三种面板留在上面，但「没被盖住」不等于
    /// 「不该显示」：控制中心是半屏、锁屏是另一套 UI，竖条浮在上面既难看也没有
    /// 意义。所以再加一道主动隐藏，判据全部走运行时，不编译期依赖 SpringBoard。
    ///
    /// 0.35 秒缓存：这个查询每次要过 3 个单例 + 最多 6 次 KVC，而调用点是 0.4
    /// 秒一次的定时器 —— 缓存把「面板刚好在这个 tick 里打开」的延迟压到看不出来。
    ///
    /// 0.1.18 — 加 `fresh`：**藏起来的时候不吃缓存。** 用户 Aevon(104) 第 1 条是
    /// 「返回桌面时它会在 1 秒内出现，减少这个 1 秒的时间」。那 1 秒的两段里有一段
    /// 就是这条缓存：面板已经走了，采样还捏着上一次「在上面」的读数，得等它过期。
    /// 只在藏起来时跳缓存 —— 那时 tick 是 0.2 s，一秒 5 次单例查询，代价可接受；
    /// 而「早一点显示」永远比「晚一点显示」安全（显示早了只是多一条可见的带子，
    /// 显示晚了是「划了没反应」）。
    private func systemOverlayUp(fresh: Bool) -> Bool {
        let now = CACurrentMediaTime()
        if !fresh && now - overlayCheckedAt < 0.35 { return overlayUp }
        overlayCheckedAt = now
        overlayUp = computeSystemOverlay()
        return overlayUp
    }

    private func computeSystemOverlay() -> Bool {
        if boolValue(sharedInstance("SBLockScreenManager"), "isUILocked") { return true }
        let cover = sharedInstance("SBCoverSheetPresentationManager")
        if boolValue(cover, "isPresented") || boolValue(cover, "isVisible") { return true }
        let center = sharedInstance("SBControlCenterController")
        if boolValue(center, "isVisible") || boolValue(center, "isPresented") { return true }
        return false
    }

    private func sharedInstance(_ className: String) -> NSObject? {
        guard let meta = NSClassFromString(className) as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("sharedInstanceIfExists")
        guard meta.responds(to: selector),
              let unmanaged = meta.perform(selector) else { return nil }
        return unmanaged.takeUnretainedValue() as? NSObject
    }

    /// The old version asked `responds(to:)` and then ran KVC. That guard is
    /// not enough: a class that forwards answers YES and `value(forKey:)` still
    /// raises, and an ObjC exception crossing Swift frames kills the process —
    /// this runs in SpringBoard on a timer, so that is safe mode.
    ///
    /// 0.1.38 — `AevonSafe.flag` reads the getter through its IMP instead: if
    /// the method exists the call cannot raise, and if it does not the answer is
    /// simply "off", which is what every caller here wants anyway.
    private func boolValue(_ object: NSObject?, _ key: String) -> Bool {
        AevonSafe.flag(object, key)
    }

    /// 0.1.18 — tick 有两档速度。
    ///
    /// 「返回桌面后 1 秒才出现」的另一半来源就是 tick 周期：显示要等下一个 tick
    /// 才被发现，最坏 0.4 s。**藏起来的时候**改成 0.2 s（那时每秒 5 次单例查询，
    /// 可以接受），出现延迟压到 0.2 s 以内；**显示着的时候**仍然 0.4 s，不为一块
    /// 看不见的地方烧 CPU。换档只在状态变化时发生，`rescheduleOverlayWatch` 自己
    /// 去重（同一个档位重复调用直接返回）。
    private var overlayFastTick = false

    private func startOverlayWatch() {
        rescheduleOverlayWatch(fast: false)
    }

    private func rescheduleOverlayWatch(fast: Bool) {
        guard overlayTimer == nil || fast != overlayFastTick else { return }
        overlayFastTick = fast
        overlayTimer?.invalidate()
        let timer = Timer(timeInterval: fast ? 0.2 : 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.syncOverlayVisibility()
            // 0.1.6 — 同一个 tick 顺手把两个入口的开关对齐一次。它是「关死的
            // 入口」唯一的自愈路径：不依赖任何一条回调按时回来。
            self.syncGrip()
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayTimer = timer
    }

    // MARK: - 0.1.17 键盘在屏（信号来自应用进程）

    /// 注册 Darwin 观察者。
    ///
    /// 回调**不碰 UI**：它可能在任意线程被投递，只把时间戳搬到主线程。
    /// 0.1.18 — 搬到主线程之后**立刻**对齐一次显隐，不再等 0.4 s 那个 tick 来
    /// 收货：用户 Aevon(104) 第 1 条就是要这一点（「关键盘后立即出现」）。
    /// 两条通道走同一个出口（`syncOverlayVisibility`），不会出现「两条路各藏一半」。
    private func startKeyboardWatch() {
        stopKeyboardWatch()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, RingHost.kbUpCallback,
                                        RingHost.kbUpText, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, RingHost.kbOffCallback,
                                        RingHost.kbOffText, nil, .deliverImmediately)
        kbObserver = observer
        Log.write("ring: keyboard watch armed (lease 3.0 s)")
    }

    private func stopKeyboardWatch() {
        guard let observer = kbObserver else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(center, UnsafeRawPointer(observer),
                                           RingHost.kbUpName, nil)
        CFNotificationCenterRemoveObserver(center, UnsafeRawPointer(observer),
                                           RingHost.kbOffName, nil)
        kbObserver = nil
        kbAt = 0
        kbLogged = false
    }

    /// `CFNotificationCallback` 是 C 函数指针，不能捕获上下文 —— 用不捕获的
    /// 静态闭包 + `Unmanaged` 把 `self` 递进来。
    ///
    /// ⚠️ 第二个参数是 `UnsafeMutableRawPointer?`，而 `fromOpaque` 收的是
    /// `UnsafeRawPointer` —— Swift 不会隐式转，必须先包一层（0.1.16 的
    /// `CFNotificationCenterRemoveObserver` 同理）。
    private static let kbUpCallback: CFNotificationCallback = { _, raw, _, _, _ in
        guard let raw = raw else { return }
        Unmanaged<RingHost>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue().keyboardBeat()
    }

    /// 0.1.18 — 单独的「收起」回调。同一个观察者挂两条通知，靠回调分叉而不是
    /// 比较 `name`：`CFNotificationName` 的相等要过 `CFEqual`，多一层类型换算
    /// 就多一个编译期的坑，两条不捕获的闭包是更省事的写法。
    private static let kbOffCallback: CFNotificationCallback = { _, raw, _, _, _ in
        guard let raw = raw else { return }
        Unmanaged<RingHost>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue().keyboardGone()
    }

    /// 应用进程说「键盘还在」：续租，然后**立刻**对齐显隐（把触发区藏掉）。
    private func keyboardBeat() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.kbAt = CACurrentMediaTime()
            self.syncOverlayVisibility()
        }
    }

    /// 应用进程说「键盘收了」：租约清零，然后立刻对齐（把触发区还回来）。
    ///
    /// 这里是 0.1.18 相对 0.1.17 的关键一处：以前收起只能等 3 秒租约自然过期，
    /// 用户看到的就是「键盘已经下去了，触发条还要等一下才回来」。
    private func keyboardGone() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.kbAt = 0
            self.syncOverlayVisibility()
        }
    }

    /// 租约内听到过心跳 ⇒ 键盘在屏。3 秒没听到就自己判收起：App 被杀、切走、
    /// 或者「收起」那条通知丢在通道上，触发区最多僵 3 秒。
    private var keyboardUp: Bool {
        return kbAt > 0 && CACurrentMediaTime() - kbAt < kbLease
    }

    private func syncOverlayVisibility() {
        guard let pad = edgePad else { return }
        // 0.0.47 — 一次判真不算数。
        //
        // Aevon(45) #1 是「有时会无法触发，需要多次点击或滑动」。这个定时器就是
        // 那个「有时」：`systemOverlayUp` 是缓存的单次采样，转场里读到
        // 一次「面板在上面」，`pad.isHidden` 就置真 —— 而隐藏的视图不参与命中，
        // 这一段时间里按上去什么都不会发生。两次连续判真才藏（0.4 秒一 tick，
        // 缓存 0.35 秒，两次采样互相独立），并且手指还在垫子上（`barHeld`）时
        // 一律不藏。
        //
        // 0.1.18 — 藏起来的时候每次采样都跳过缓存（见 `systemOverlayUp(fresh:)`）。
        // 严格来说两次采样就不再「互相独立」了（0.2 s 一 tick），所以藏的门槛不放：
        // 仍然是两次判真。显示那边反过来 —— 一次判假就够，早显示是安全的。
        let wasHidden = pad.isHidden
        if systemOverlayUp(fresh: wasHidden) && !barHeld {
            overlayStrikes = Swift.min(overlayStrikes + 1, 2)
        } else {
            overlayStrikes = 0
        }
        // 0.1.17 — 键盘走同一条出口，但**不参与两次判真**：应用那边已经是
        // 「键盘确实起来了」之后才报的，再延迟 0.4 秒只会让用户先误触一两下
        // 删除键。Aevon(103) 的原话：「键盘打开时，右侧触发区必须让路，
        // 不然容易误触」。
        let keyboard = keyboardUp
        if keyboard != kbLogged {
            kbLogged = keyboard
            Log.write(keyboard
                      ? "ring: keyboard up, edge band stepped aside"
                      : "ring: keyboard gone, edge band back")
        }
        let hidden = (overlayStrikes >= 2 || keyboard) && !barHeld
        // 0.1.24 — 只剩呼盘垫这一层要藏（竖条已下线）。藏起来之后这一根手指
        // 落在键盘上，键盘照常收。
        edgePad?.isHidden = hidden
        // 0.1.19 — **谁把呼盘垫关掉的，日志里必须看得见。**
        // 隐藏的视图不参与命中，它一旦被藏住，「划了没反应」和「带子不在这儿」
        // 在日志里长得一模一样（后者至少有 `pad down`，前者一个字都没有）。
        // 只在这一位变化时写，不会刷屏。
        if edgeHiddenLogged != hidden {
            edgeHiddenLogged = hidden
            Log.write(hidden ? "ring: edge pad stepped aside"
                             : "ring: edge pad back on the right edge")
        }
        // tick 速度跟着「藏没藏」换档：藏着的时候快（早点显示），显示着的时候慢。
        rescheduleOverlayWatch(fast: hidden)
        guard wasHidden != hidden else { return }
        pad.isHidden = hidden
        // 0.0.49 — 面板刚退下去，正是窗口栈最不可靠的时刻：顺手把这一层放回顶上，
        // 免得「看得见但按不到」。
        // 0.1.24 — 竖条没了，回来时只剩 `raiseWindow()` 这一件事可做：面板刚退
        // 下去，正是窗口栈最不可靠的时刻，把这一层放回顶上是「看得见也按得到」
        // 的唯一保证。
        if !hidden {
            raiseWindow()
        }
        // 键盘与系统面板分开报：混成一句之后，「按不出来」就分不清是哪条路关的。
        // 键盘那两条已由上面的 `keyboard up / gone` 覆盖，这里只报面板这一条 ——
        // 0.1.16 及以前这里用的是同一个 `overlayStrikes` 判，结果「shown」几乎
        // 永远打不出来（收起时 strikes 已经归 0 了）。
        if keyboard { return }
        Log.write("ring: edge band " + (hidden ? "hidden (system overlay up)"
                                               : "shown (system overlay gone)"))
    }

    // MARK: - Disc (AevonRingMenu, 1:1)

    /* ⛔ 0.1.24 — `expand()` / `collapse()` 删除，它们是死代码。
     *
     * 这两个函数原本只有 `toggle()`（点竖条开合）一个调用者。竖条下线、
     * `toggle` 一起删之后，它们再也没有任何入口 —— 圆盘现在只有一条路：
     * `handleEdgePhase` → `AevonRingMenu.presentTracking`。
     *
     * 留着不只是无用：`-dead_strip` 会把它们剥掉，而 audit 里断言的那句
     * 「圆盘已展开」日志（`ring: expanded` 那一行）也就跟着从二进制里消失 ——
     * 0.1.24 第一次 CI 就是这么挂的，报的是这句 missing from Aevon.dylib。
     * 删干净，断言一起撤。
     */

    // MARK: - Store seeding

    /// First run: the store is empty, so the disc would be an empty circle.
    /// Seed the first ten catalogue apps once — the old `AevonRingStore` wrote
    /// the same seed from its own catalogue; this package's catalogue is
    /// RingIcons.
    private func seedStore() {
        guard AevonRingStore.bundleIDs().isEmpty else {
            Log.write("ring: \(AevonRingStore.bundleIDs().count) apps in store "
                      + "(operator list)")
            return
        }
        AevonRingStore.seedIfNeeded(from: RingIcons.catalogue())
        Log.write("ring: seeded \(AevonRingStore.bundleIDs().count) apps "
                  + "(first run, editable in Settings)")
    }

    private func preloadIcons() {
        // The menu draws its own icons through AevonAppIcon; this warm-up just
        // pays the LaunchServices enumeration once, off the critical path.
        let started = Date()
        let catalogue = RingIcons.catalogue()
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        Log.write("ring: \(catalogue.count) apps via LaunchServices in \(milliseconds)ms")
    }

    // MARK: - Launching

    /// The disc's activate path. `AevonWindowManager.launchAndOpen` is the old
    /// name; the hook routes it here. Same contract as 0.0.38's ring tap: the
    /// card route first, a plain full-screen launch as the fallback — a tap
    /// must never be a dead end.
    private func openFromRing(_ bundleID: String) {
        guard !bundleID.hasPrefix("placeholder.") else { return }
        SceneProbe.openCard(bundleID) { [weak self] reason in
            Log.write("ring: card route declined (" + reason + "), opening " + bundleID)
            self?.launch(bundleID)
        }
    }

    /// 0.1.40 — 通知点击那条路。
    ///
    /// 和圆盘图标同一个终点（`openFromRing`），只是多一行来路证词：日志里
    /// `notify: open <bundle>` 之后紧跟 `ring: card route declined …` 时，
    /// 才能分清「通知这条路没通」和「通了但卡片没起来」。
    func openFromNotification(_ bundleID: String) {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("placeholder.") else { return }
        Log.write("notify: open " + bundleID)
        openFromRing(bundleID)
    }

    /// The old behaviour, kept as the fallback and unchanged: the same private
    /// entry point SpringBoard itself uses. Guarded at every step.
    private func launch(_ bundleID: String) {
        guard let meta = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            Log.write("ring: LSApplicationWorkspace unavailable, cannot open \(bundleID)")
            return
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard meta.responds(to: defaultSelector),
              let workspace = meta.perform(defaultSelector)?
                  .takeUnretainedValue() as? NSObject else { return }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector) else { return }

        Log.write("ring: launch \(bundleID)")
        _ = workspace.perform(openSelector, with: bundleID)
    }

    /// 圆心（四宫格）→ 应用选择面板（0.0.56）。
    ///
    /// 0.0.55 及以前这里是把「设置」App 推到前台 —— 一个 tweak 能诚实做到的
    /// 唯一一件事。现在圆盘自己有了面板：所有可打开的桌面 App、按拇指的位置
    /// 排在面板里，点一个直接开浮窗。设置页仍然是圆盘列表的编辑器，但它不再
    /// 是「想开一个不在盘里的 App」的唯一出口。
    ///
    /// 面板在屏期间，竖条和右缘手势带都收回触摸：面板占了屏幕下半部，那两样
    /// 东西正好压在它上面，留着就是「按哪儿都在呼圆盘」。
    private func openPanel() {
        guard let host = window?.rootViewController?.view else { return }
        AevonRingMenu.dismissCurrent()
        expanded = false
        barHeld = false
        // 0.1.6 — 先起面板再关入口，然后统一 `syncGrip()`。
        //
        // 原来这两行写在 `present` **之前**（那时还判断不出「面板在屏」），
        // 而恢复只挂在面板的 `onClose` 上 —— `present` 的「已经有一个面板」
        // 那条路会把旧面板的 `onClose` 置 nil 直接摘掉，恢复逻辑跟着一起没了，
        // 从此右侧按不出圆盘。现在开关是现算的，谁摘掉面板都不影响它。
        Log.write("ring: center panel -> app chooser (" + String(RingIcons.catalogue().count) + " apps)")
        AevonAppPanel.present(in: host,
                              onPick: { [weak self] bundleID in
                                  self?.openFromRing(bundleID)
                              },
                              onClose: { [weak self] reason in
                                  guard let self = self else { return }
                                  self.syncGrip()
                                  Log.write("ring: app chooser gone (" + reason + "), grip back")
                              })
        syncGrip()
    }
}

// MARK: - 0.1.11 右缘呼盘垫（自己掌勺的触摸判定）

/// 右缘的呼盘垫。**判定在这里做，不在手势识别器里做。**
///
/// 0.1.13 — 认领的不是「14 pt 一条」而是两块地：贴右缘 24 pt × 底部 35 % 的列，
/// 加上可见抓手周围 46×176 的宽区。Aevon(100) 的 14 次落指全在离边 3~6 pt，
/// 而旧测说拇指中心通常落在 12~15 pt —— 14 pt 的带宽把分布的中位数压在边界上，
/// 这就是「触发几率很小」的主要来源。
///
/// 0.1.16 — **又收回一条**：光环撤掉，只剩贴右缘 10 pt × 底部 35 %（用户定值）。
/// 0.1.15 的 40 + 光环把成功率做到 63/63（所有划动全开），代价是右侧一大片地
/// 被认领 —— 热区可见之后那块面积太显眼，而且认领 = 应用拿不到这一根手指。
/// 取舍与已知代价写在 `RingHost.stripWidth` 上方，别再按「越宽越好」往回加。
///
/// 为什么撤掉 `UIPanGestureRecognizer` + `gestureRecognizerShouldBegin`（0.1.10）：
///
/// UIKit 调 `shouldBegin` 的时机是「pan 刚刚够到自己的启动线」那一拍，此时
/// `translation` 只有 10 pt 上下。0.1.10 要求 `dx <= -12`，而 Aevon(98) 真机
/// 三次左滑的样本是 −11 / −4 / −0 —— **-12 在那一拍永远到不了**。更糟的是
/// `shouldBegin` 返回 false 会让识别器直接 failed，这一根手指之后滑多远都不会
/// 再被问第二次，于是「一个都呼不出来」。
///
/// 换成 `UIView` 自己收 `touchesBegan/Moved/Ended`：
/// - 位移自己累积，够左且横向占优 ⇒ 报 `.began`（弹盘）
/// - 走得不远但甩得很快（≥900 pt/s）⇒ 也算左滑（短促左甩是拇指最常用的形态）
/// - 往右、或竖向占优**且已经走了 16 pt** ⇒ 报 `.reject` 并停止跟踪
/// - 没到任何一条就抬手 ⇒ `.reject`（点击不弹盘，用户 Aevon(94) 第 1 条）
///
/// 0.1.12 — **三处静默改掉了。** Aevon(99) 的日志里 5 分半只有 2 次落指
/// （拒绝计数停在 `#1`），而「手指没落到带上」「落上了被闸挡住」「放行了没滑够」
/// 在这份日志里完全一样：都是没有 `open at`。现在落指无条件报点
/// （`ring: pad down at`），被闸挡住报原因（`ring: pad refused by`），未开就被
/// 系统抢断也报位移（`ring: pad cancelled dx=`）—— 三者从此分得开。
///
/// 事件序列是 UIKit 正规投递（began → moved* → ended），不会出现半截态；
/// 而这条带子命中时下层 App 本来就收不到触摸（窗口在上层），所以「不误触 App」
/// 是结构性的，不靠我们发任何广播。
final class EdgeSwipePad: UIView {
    enum Phase {
        case down      // 落指（仅报点，不做业务）
        case began     // 判定为左滑 ⇒ 呼盘
        case moved     // 跟随
        case ended     // 抬手
        case cancelled // 被系统取消
    }

    /// 阶段闸：面板在屏 / 圆盘已开 / 节流未到 ⇒ 不接这一根，**并说明是哪一条**。
    ///
    /// 0.1.12 — 原来是 `isArmed: (() -> Bool)?`：被挡的时候一个字都不写，于是
    /// 「没落到带上」和「落上了被挡住」在日志里长得一模一样（Aevon(99) 两份
    /// 日志的 5 分半里只有 2 次落指，其余尝试无从对账）。现在返回原因串。
    var blockReason: (() -> String?)?
    /// 认领的地盘（窗口坐标）。命中由这几块矩形决定，不是 frame —— frame 只是
    /// 它们的外接矩形，里面的「空角」必须放行应用。
    var claimRects: (() -> [CGRect])?
    /// 业务回调，坐标已转成 window 坐标。
    var onPhase: ((Phase, CGPoint, CGPoint) -> Void)?
    /// 落指报点，取证用（坐标 window）。**无条件**，在闸门之前。
    var onDown: ((CGPoint) -> Void)?
    /// 落指被闸挡住时的证词（附原因）。
    var onBlocked: ((String) -> Void)?
    /// 「这一下不算呼盘」时的证词，附最终位移。
    var onReject: ((CGSize) -> Void)?
    /// 未开就被系统抢断（来电、控制中心、别的识别器优先）时的证词。
    var onCancel: ((CGSize) -> Void)?

    /// 认作左滑的最小横向位移。8 pt 是「有意图地划」的下限；0.1.10 的 12
    /// 撞上的正是 UIKit 自己的 10 pt 启动线，这里必须明显低于它。
    private let openDistance: CGFloat = 8
    /// 认输的位移。只有**决定性**的位移才收手：0.1.11 用 8 pt，拇指起手的纵向
    /// 抖动一起手就把这一根判死（Aevon(99) 那次 `dx=-2 dy=-7`）。
    private let failDistance: CGFloat = 16
    /// 快甩判据：位移这么点但速度够，也算左滑。
    private let flickDistance: CGFloat = 5
    private let flickSpeed: Double = 900
    /// 0.1.15 — 允许多斜。
    ///
    /// 0.1.14 及以前要求 `|dx| > |dy|`（横向必须严格占优），那等于只认「水平
    /// 左推」。但单手右手持机时拇指是从右下角往左上**斜着**扫的：Aevon(101) 的
    /// 原话「双手拿着才容易触发，单手不易」里有一半是这一条 —— 双手时另一只手
    /// 可以从侧面水平推，单手时拇指的轨迹天然带 30~50° 的竖分量，`|dx| > |dy|`
    /// 直接把这类划法判成「不是左滑」，连带着盘也不开。
    ///
    /// 0.7 的含义：竖分量到横分量的 1.43 倍以内（约 55°）仍算左滑。再斜下去
    /// 就真是竖划了 —— 而竖划在右缘是页面的滚动，不能抢。判「这不是左滑」的
    /// 那条线（`failDistance`）同时要求竖向**占优**，两道门是配套的。
    private let slantTolerance: CGFloat = 0.7

    private var start: CGPoint = .zero
    /// 落指时刻，用来算甩动速度（`UITouch.timestamp`）。
    private var startAt: CFTimeInterval = 0
    private var tracking = false
    private var opened = false

    /// 圆盘在屏时**不再让开**（0.1.13）：见 `addEdgePad` 里那段账 —— 让开的其实是
    /// 应用，不是圆盘。命中只按 `claimRects` 两块矩形判。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let rects = claimRects?(), !rects.isEmpty else {
            return super.point(inside: point, with: event)
        }
        let inWindow = convert(point, to: window)
        return rects.contains { $0.contains(inWindow) }
    }

    // 下面四个触摸方法**都不调 super**：一调，未处理的触摸就沿响应链上传
    // （pad → host view → 控制器 → window），圆盘刚打开的那一根会被下层系统
    // 手势再吃一遍。这条带子既然自己判，就自己收尾。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 多指不算呼盘：只认第一根。
        guard touches.count == 1, let touch = touches.first else {
            tracking = false
            onBlocked?("multi")
            return
        }
        start = touch.location(in: self)
        startAt = touch.timestamp
        tracking = true
        opened = false
        // 0.1.12 — **先报点，再判闸。** 落指这一声是无条件的：它证明「手指确实
        // 落在这条 14 pt 带上」，之后才有资格区分「被闸挡住」与「滑得不够」。
        onDown?(convert(start, to: window))
        if let reason = blockReason?() {
            tracking = false
            onBlocked?(reason)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking, let touch = touches.first else { return }
        let point = touch.location(in: self)
        if opened {
            onPhase?(.moved, convert(start, to: window), convert(point, to: window))
            return
        }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let span = Swift.max(touch.timestamp - startAt, 0.001)
        let speed = -Double(dx) / span        // 向左为正，pt/s
        // ① 走够 8 pt 且方向够横 ⇒ 呼盘。两个条件同时成立，纵向拖不会误开。
        //    0.1.15 — 「横向占优」放宽成 `|dx| >= |dy| * 0.7`，理由见 `slantTolerance`。
        if dx <= -openDistance, abs(dx) >= abs(dy) * slantTolerance {
            opened = true
            onPhase?(.began, convert(start, to: window), convert(point, to: window))
            return
        }
        // ② 走得不远但甩得很快 ⇒ 也算。只按位移判会把短促左甩当点击扔掉，
        //    而拇指在窄带上最常用的正是这一种。
        if dx <= -flickDistance, speed >= flickSpeed,
           abs(dx) >= abs(dy) * slantTolerance {
            opened = true
            onPhase?(.began, convert(start, to: window), convert(point, to: window))
            return
        }
        // ③ 认输要**决定性**：走够 16 pt 之后才收手，中间这段继续看 —— 后面只要
        //    横向压过来，盘照样出来。0.1.11 的 8 pt 门槛把起手抖动当成了结论。
        if dx >= failDistance || (abs(dy) >= failDistance && abs(dy) > abs(dx)) {
            tracking = false
            onReject?(CGSize(width: dx, height: dy))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking else { return }
        tracking = false
        let point = touches.first?.location(in: self) ?? start
        let dx = point.x - start.x
        let dy = point.y - start.y
        if opened {
            onPhase?(.ended, convert(start, to: window), convert(point, to: window))
            return
        }
        // ④ 采样粗的时候位移可能整段落在最后一次投递里：抬手那一刻只要够 8 pt
        //    且横向占优，仍然算左滑（先报 `.began` 再报 `.ended`，盘照常出来）。
        if dx <= -openDistance, abs(dx) >= abs(dy) * slantTolerance {
            opened = true
            onPhase?(.began, convert(start, to: window), convert(point, to: window))
            onPhase?(.ended, convert(start, to: window), convert(point, to: window))
            return
        }
        // 停在原地就抬手 = 点击。用户 Aevon(94) 明确要求「移除点击触发圆盘」。
        onReject?(CGSize(width: dx, height: dy))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking else { return }
        tracking = false
        let point = touches.first?.location(in: self) ?? start
        let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
        if opened {
            onPhase?(.cancelled, convert(start, to: window), convert(point, to: window))
        } else {
            // 0.1.12 — 未开就被抢断，原来一个字都不写。它是「滑了没反应、日志
            // 里还干干净净」的唯一来源（被别的识别器/窗口先拿走），必须留证词。
            onCancel?(delta)
        }
    }
}

// MARK: - Passthrough plumbing

/// The window must never be the hit target. Returning nil for itself makes
/// every point that no subview claims fall through to SpringBoard below.
/* ⛔ 0.1.24 — `BarPad` 删除。它存在的唯一理由是「竖条的垫子上落指就报一声」
 * （`ring: pad down at …` 那行证词的原产地）。竖条下线之后没有任何地方再构造它，
 * 留着就是一个永远不执行的类。
 *
 * 注意 `ring: pad down` 这行证词**没有消失** —— `EdgeSwipePad.onDown` 现在负责它，
 * 位置在 `addEdgePad()` 里。
 */

private final class PassthroughWindow: UIWindow {
    /* ⛔ 0.1.22 — **呼盘判定搬到窗口的 `sendEvent` 上。**
     *
     * Aevon(105) 的日志把「视图命中」这条路判死了：整份日志里
     * `claim=18x912 at y=8`（带子在全高、18 pt、贴边）和
     * `edge pad back on the right edge`（没被藏）都在，可是
     * **一条 `pad down` 都没有** —— 手指压根没送到 `edgePad` 上。
     *
     * 0.1.20 加的根视图兜底（`PassthroughView.hitTest`）理应接住它，但那份
     * 日志里 `summon fell back to edge pad` 也一次没出现，说明
     * **`hitTest` 根本没被问到**：0.1.21 的兜底挂在「点落在 `stripRect` 里」，
     * 只要 `host` 的 frame / 坐标换算出一点岔子，这条兜底就静默失效，
     * 而它失效时没有任何证词 —— 和「带子不在这儿」长得一模一样。
     *
     * `sendEvent` 是窗口收到触摸的**必经之路**，没有子视图层级能绕开它。
     * 所以把判定直接放在这里：
     *   ① 落点落在带子里 ⇒ 无条件报一行（这是「窗口到底收没收到触摸」的
     *      唯一分界线，比 `pad down` 更靠上游）；
     *   ② 位移够左 ⇒ 直接开圆盘，并把后续事件吞掉（这根手指归圆盘）；
     *   ③ 方向不对 ⇒ 原样 `super`，应用该收到什么还收到什么。
     *
     * `edgePad` 保留不动：它仍是「带内点击被我们吃掉、不落到应用」的那道门。
     * 两条路各管一段，互相不抢 —— 谁先判出「这是左滑」谁就 `owned`，
     * 另一个看 `edgeBusy` 就知道已经有人在处理。
     */
    var edgeRect: (() -> CGRect?)?
    /// 带子此刻能不能用（键盘 / 面板在屏时不能）。
    var edgeArmed: (() -> Bool)?
    /// 已经有人在处理这根手指了（`RingHost.expanded`）。
    var edgeBusy: (() -> Bool)?
    var edgeOnPhase: ((EdgeSwipePad.Phase, CGPoint, CGPoint) -> Void)?
    /// 落点证词，参数是 (窗口坐标, 离右缘多少 pt)。
    var edgeTouchNote: ((CGPoint, CGFloat) -> Void)?

    private var watch: UITouch?
    private var startPoint: CGPoint = .zero
    private var owned = false
    /// 落点证词的上限。**每答一次窗口就多一行日志，但一次都不能省** ——
    /// 「窗口收不到触摸」这种事故只有这一行能证。
    private var noted = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func sendEvent(_ event: UIEvent) {
        guard event.type == .touches, let touches = event.allTouches else {
            super.sendEvent(event)
            return
        }
        for touch in touches {
            let point = touch.location(in: self)
            switch touch.phase {
            case .began:
                // 多指不算呼盘：只认第一根，第二根落下时直接不管。
                guard watch == nil else { continue }
                guard edgeArmed?() ?? true,
                      let rect = edgeRect?(), rect.contains(point) else { continue }
                watch = touch
                startPoint = point
                owned = false
                if noted < 20 {
                    noted += 1
                    edgeTouchNote?(point, bounds.maxX - point.x)
                }

            case .moved:
                guard let w = watch, w === touch else { continue }
                if owned {
                    edgeOnPhase?(.moved, startPoint, point)
                    continue
                }
                let dx = point.x - startPoint.x
                let dy = point.y - startPoint.y
                // 与 `EdgeSwipePad` 同一套门：够左 8 pt 且横向不明显吃亏（*0.7）。
                if dx <= -8, abs(dx) >= abs(dy) * 0.7 {
                    // 别处已经在处理这根手指 ⇒ 别抢，也别吞。
                    if edgeBusy?() ?? false { watch = nil; continue }
                    owned = true
                    edgeOnPhase?(.began, startPoint, point)
                }

            case .ended:
                guard let w = watch, w === touch else { continue }
                watch = nil
                if owned {
                    owned = false
                    edgeOnPhase?(.ended, startPoint, point)
                    // 抬手这一帧也吞掉：应用只收到过 `began`，再给它一个
                    // `ended` 会让它把那半根序列当成一次点击 / 一次返回。
                    return
                }

            case .cancelled:
                guard let w = watch, w === touch else { continue }
                watch = nil
                if owned {
                    owned = false
                    edgeOnPhase?(.cancelled, startPoint, point)
                    return
                }

            @unknown default:
                break
            }
        }
        // 这根手指已经归圆盘了：后续事件不再下发，否则应用会拿半根序列
        // （只有 began、没有 ended）去跑它自己的返回手势。
        if owned { return }
        super.sendEvent(event)
    }
}

private final class PassthroughView: UIView {
    /// 0.1.20 — **边缘带的最后一道兜底。**
    ///
    /// `hitTest` 只把「命中了我们自己」当成穿透；子视图照常参与命中。可
    /// `edgePad` 是 `host` 的**普通子视图** —— 只要有任何一层比它晚添加、
    /// 比它大的透明视图盖在右缘上（圆盘的全屏视图、面板容器、浮动窗的环形
    /// 手势层、甚至一次布局把它的 frame 算成零），`super.hitTest` 就再也
    /// 返回不到它，用户贴着右缘划一整条都落不到呼盘垫上，日志里连
    /// `pad down` 都没有。
    ///
    /// 这跟 0.1.19「触发条消失后呼不出」的观感完全一致，而且**没有任何证词**：
    /// 不是判据拒绝了，是手指根本没送到。
    ///
    /// 所以在根视图这一层补一条：点落在认领矩形里、且那块地此刻归我们
    /// （`pad` 没被藏、没被禁），就直接把 pad 交出去，绕过所有子视图层级。
    /// 几何仍然只有 `stripRect` 一个来源，兜底不扩大也不缩小认领范围。
    weak var fallbackHit: UIView?
    var fallbackRect: (() -> CGRect?)?
    private var fallbackLogged = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let pad = fallbackHit, !pad.isHidden, pad.isUserInteractionEnabled,
           let rect = fallbackRect?() {
            let inWindow = convert(point, to: window)
            if rect.contains(inWindow) {
                if fallbackLogged < 3 {
                    fallbackLogged += 1
                    Log.write("ring: summon fell back to edge pad #"
                              + String(fallbackLogged))
                }
                return pad
            }
        }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - 应用层触摸入口（0.1.23）

/// `AevonScene.m` 的 `AevonSendEventReplacement` 调的入口。
///
/// 为什么是 C 而不是直接 `RingHost.shared.edgeTouch(...)`：调用方是 ObjC，
/// 而 Swift 的类名 / 方法名在 `-x` 链接之后不进符号表，ObjC 那边看不到。
/// `@_cdecl` 给的是一个稳定的 C 符号，两个编译单元只靠这一行名字耦合。
///
/// 返回值：非 0 = 这一拍吞掉（不往应用传）。
@_cdecl("AevonRingEdgeTouch")
public func AevonRingEdgeTouch(_ phase: Int32, _ x: Double, _ y: Double) -> Int32 {
    RingHost.shared.edgeTouch(phase: phase, x: x, y: y) ? 1 : 0
}
