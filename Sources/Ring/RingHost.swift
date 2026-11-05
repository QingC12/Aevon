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
//    · the summon bar's window level and its system-overlay exemption (0.0.45):
//      the bar lives above every app so it can be reached from anywhere, and
//      goes away for the three places it must not appear — 锁屏 / 控制中心 /
//      通知中心. Aevon(43) #3 asked for exactly that map.
//    · the summon bar — 0.0.44's entry: a short vertical strip flush with the
//      right edge. 0.0.14-0.0.43 used a 14 pt dot in the corner, and Aevon(42)
//      said what a dot in a corner is worth: 「有点不容易触发」. A strip along the
//      edge can be hit without aiming, it takes its colours from the material
//      behind it instead of guessing white-on-white, and its height on the
//      screen is a slider in 承载形状 instead of a drag that had to be
//      discovered. Tap it, or swipe left across it.
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

final class RingHost: NSObject {

    static let shared = RingHost()

    /// Preference key for "put the grip on the home screen". Ships on, because
    /// a shape nobody can see is not a feature. Prefixed with "!" to stay out
    /// of the master's 81 keys and out of the generated table.
    static let enabledKey = "!ring.desktop"

    private var window: UIWindow?
    /// The visible strip. Drawn, not drawn *on*: a UIView whose only child is a
    /// blur, so it picks up whatever is behind it.
    private var bar: UIView?
    private var barBlur: UIVisualEffectView?
    /// The touch pad. Wider than the strip on purpose — a bar flush with the
    /// edge gives a thumb nothing to aim at, so the pad reaches 40 pt inwards
    /// while the strip itself stays 8 pt of visible width.
    private var barPad: UIView?

    /// Strip geometry. 8 x 56 reads as a handle rather than a control, and it
    /// is 4x the dot's target area without covering an icon.
    ///
    /// 0.0.47 — the pad grew to 46 x 150. Aevon(45) #1 is 「触发不灵敏，需要多次
    /// 点击或滑动」, and a 40 x 112 target a thumb has to hit exactly is one of
    /// the two things that produces that sentence (the other one is the overlay
    /// timer hiding the pad, fixed below). The strip itself does not change:
    /// what grew is the part nobody sees.
    /// 0.0.49 — 竖条的尺寸不再是常量，而是由两个百分比算出来（设置面板里
    /// 「竖条长度」「竖条宽度」两行）。四条边都是纯函数的结果，所以 `layout()`
    /// 和 `barCentreY()` 永远看到同一组数。
    private struct BarMetrics {
        let barWidth: CGFloat    // 可见宽度，硬上限 40 pt
        let barHeight: CGFloat   // 可见长度
        let padWidth: CGFloat    // 触摸垫宽度（≥ 可见宽度 + 余量）
        let padHeight: CGFloat   // 触摸垫长度
    }

    private func metrics(in bounds: CGRect) -> BarMetrics {
        // 宽度：40 pt 的百分比。上限写死 40 —— 竖条贴屏幕右缘，那里有页面自己
        // 的点击目标（返回、列表行、滑条），再宽就开始抢它们。
        let width = Swift.min(40, Swift.max(4, 40 * config.barWidth / 100))
        // 长度：屏幕高度的百分比。4–20 % 在本机是 37–186 pt。
        let height = Swift.min(240, Swift.max(24, bounds.height * config.barLength / 100))
        // 垫子比条子大一圈：手指落在半英寸外也算命中，这是「不灵敏」的第一道防线。
        let padW = Swift.min(76, Swift.max(40, width + 32))
        let padH = Swift.min(320, Swift.max(96, height * 2 + 38))
        return BarMetrics(barWidth: width, barHeight: height,
                          padWidth: padW, padHeight: padH)
    }

    /// The last percentage that was laid out, so a slider drag logs one line per
    /// real change instead of one per refresh.
    private var laidOutPercent: Int = -1

    /// 0.0.45 — 竖条上那根手指还在屏上。`AevonRingGrip.hasActiveGripTouch`
    /// 从这里取值，圆盘的静默看门狗据此放过「按住不动」的局。
    private var barHeld = false

    /// 0.0.45 — 系统面板（锁屏 / 控制中心 / 通知中心）豁免的定时器与缓存。
    private var overlayTimer: Timer?
    private var overlayCheckedAt: CFTimeInterval = 0
    private var overlayUp = false
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

    /// 0.1.11 — 「这一下不算呼盘」记过几次（前 20 次写日志）。0.1.10 时它是
    /// `gestureRecognizerShouldBegin` 的拒绝计数，现在由 `EdgeSwipePad.onReject` 写。
    private var stripProbe = 0

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
    /// 带宽不再用 `edgeWidth`。它就是 `stripWidth`（0.1.13 起 24 pt），两处定义
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
        window.rootViewController?.view = PassthroughView(frame: window.bounds)
        window.rootViewController?.view.backgroundColor = .clear
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
        AevonRingGrip.setVisibleHandler = { [weak self] visible in
            self?.setGripVisible(visible)
        }
        // 0.0.45 — 竖条按住期间，圆盘不许因为"静默"自收（手指根本没离开屏幕）。
        AevonRingGrip.activeTouchHandler = { [weak self] in
            self?.barHeld ?? false
        }
        // 0.1.10 — 这里原本还有一条 `AevonRingGrip.barTouchHandler`（应用层
        // sendEvent 入口）。整条撤掉了：呼出只走 `edgePad` 上的识别器，
        // 理由见文件末尾 `gestureRecognizerShouldBegin` 上方那段。

        addBar()
        addEdgePad()
        layout()
        startOverlayWatch()
        syncOverlayVisibility()
        seedStore()

        observe()
        Log.write("ring: hosted on desktop (旧版圆盘 1:1 · AevonRingMenu "
                  + "\(AevonRingStore.bundleIDs().count)/\(AevonRingStore.maxCount))")

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
        AevonRingGrip.activeTouchHandler = nil
        barHeld = false
        overlayStrikes = 0
        padProbe = 0

        bar?.removeFromSuperview()
        barPad?.removeFromSuperview()
        edgePad?.removeFromSuperview()
        bar = nil
        barBlur = nil
        barPad = nil
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
        if #available(iOS 13.0, *), let scene = mainScene() {
            let window = PassthroughWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            return window
        }
        return PassthroughWindow(frame: UIScreen.main.bounds)
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
        return application.connectedScenes.compactMap { $0 as? UIWindowScene }.first
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

        // Flush with the right edge: `maxX - padWidth` is the pad's left edge
        // and the strip sits in the pad's last `barWidth` points, so the strip
        // and the screen edge are the same line. Nothing floats in from the
        // edge — a strip inset by a margin is a strip a thumb can miss.
        let m = metrics(in: bounds)
        let centre = barCentreY(in: bounds)
        barPad?.frame = CGRect(x: bounds.maxX - m.padWidth,
                               y: centre - m.padHeight / 2,
                               width: m.padWidth, height: m.padHeight)
        bar?.frame = CGRect(x: m.padWidth - m.barWidth,
                            y: (m.padHeight - m.barHeight) / 2,
                            width: m.barWidth, height: m.barHeight)
        // 尺寸变了，圆角也要跟着：8 pt 宽的条子是 4 pt 圆角，40 pt 宽还是 4 pt
        // 就成了方凳；跟着宽度取一半，两端永远是圆的。
        bar?.layer.cornerRadius = m.barWidth / 2
        // 0.0.48 — 竖条的触摸垫位置交给浮窗那一侧。浮窗的手指入口在应用层就
        // 把环上的触摸吃掉了，环的右半边正好压在这里；没有这条线，卡片开着时
        // 点竖条会被当成拖浮窗（见 AevonRingGrip.summonRect）。
        //
        // 0.1.7 — 交出去的是**贴边 14 pt 那条带**（与 `rawBar` 的认领范围同一个），
        // 不再是 40×212 的视觉垫子：垫子只是画，拿它当让路地盘会让卡片右缘的环
        // 白瞎 40 pt。
        AevonRingGrip.summonRect = stripRect(in: bounds)
        // 0.0.55 — 右缘带：贴右缘 15 pt，从底部往上 35 %。卡片在屏时收回触摸
        //（`AevonRingGrip.cardUp`），否则右下角拖卡片的手会先落进带子里。
        //
        // 0.1.7 — 整条带子换成 `stripRect` 那一条，竖条那块 40×212 的垫子从这一刻
        // 起**只是画**，不接触摸（见 `addBar`）。0.1.8 起 `stripRect` 的高度又回到
        // 底部 35 %（全高会和左滑返回插件抢整条右缘，见那个函数上的注释）。
        // 0.1.13 — frame 只是外接矩形，真正认领的是 `claimRects` 那两块（列 + 光环）。
        // 外接矩形里剩下的角**不属于我们**，由 `EdgeSwipePad.point(inside:)` 退回给应用。
        edgePad?.frame = claimBounds(in: bounds)
        // 0.1.6 — 开关只有一个来源（`syncGrip`）。原来这里直接写
        // `!AevonRingGrip.cardUp`，那是第三个各写一遍的地方：布局写一次、开卡关一次、
        // 面板关回调再写一次，任何一条路没回来，入口就一直是关的。
        syncGrip()
        window.rootViewController?.view.frame = bounds
        paintBar()

        // 面板正在上面的时候换了页面（比如通知中心拉下来又弹回去），
        // layout 是唯一会被叫到的地方，顺手把可见性对齐一次。
        syncOverlayVisibility()

        // 位置和尺寸一起报。0.0.49 起竖条的长宽是两个滑块，日志里必须能看见
        // 改完之后实际生效的点数 —— 否则「还是不灵敏」时没法区分「滑块没生效」
        // 和「生效了但位置不对」。
        let percent = Int((config.barY).rounded())
        let sizeKey = Int(m.barWidth * 10) * 100_000 + Int(m.barHeight * 10)
        if percent != laidOutPercent || sizeKey != laidOutMetrics {
            laidOutPercent = percent
            laidOutMetrics = sizeKey
            Log.write("ring: bar position " + String(percent)
                      + "% of the screen height (right edge) size="
                      + String(Int(m.barWidth.rounded())) + "x"
                      + String(Int(m.barHeight.rounded())) + "pt pad="
                      + String(Int(m.padWidth.rounded())) + "x"
                      + String(Int(m.padHeight.rounded()))
                      // 0.1.8 — 呼盘命中区一起报：`claim=24x326 at y=606` 是
                      // 「贴右缘 × 底部 35 %」的实测值，判据在日志里自证。
                      // 0.1.13 — 加了 `halo`（对着可见抓手那一段的宽区），并且
                      // 整段合成**一个**长格式串：` claim=` 只有 7 字节，会被编成
                      // 立即数，二进制里 grep 不到（audit 断言就抓了个空）。
                      + String(format: " claim=%.0fx%.0f at y=%.0f halo=%.0fx%.0f at y=%.0f",
                               stripWidth, stripRect(in: bounds).height,
                               stripRect(in: bounds).minY,
                               haloWidth, haloRect(in: bounds).height,
                               haloRect(in: bounds).minY))
        }
    }

    /// Where the strip's centre sits, as the operator's percentage of the
    /// screen height. The pad's half-height is the clamp, not the strip's: a
    /// bar at 0 % must still be reachable, and the thing the finger lands on is
    /// the pad.
    private func barCentreY(in bounds: CGRect) -> CGFloat {
        let half = metrics(in: bounds).padHeight / 2
        let y = bounds.height * config.barY / 100
        return Swift.min(bounds.maxY - half, Swift.max(half, y))
    }

    // MARK: - Summon bar

    private func addBar() {
        guard let host = window?.rootViewController?.view else { return }

        // The pad is the target, the bar is the paint job. 46 pt of pad means a
        // thumb that lands half an inch from the edge still finds it; the pad is
        // flush with the screen edge so nothing has to be aimed at.
        let pad = BarPad(frame: .zero)
        pad.backgroundColor = .clear
        // 0.1.7 — **竖条从这一刻起只负责「画」，不接收任何触摸。**
        //
        // 原来这块垫子是 40×212 的隐形命中区，还挂着 tap（点一下开/关圆盘）与
        // pan（按住拖动）。用户 Aevon(94) 第 1 条报的就是它：「当你点击全屏应用
        // 的操作是会误触圆盘触发」—— 40 pt 宽几乎盖掉了右缘一整条，卡片里点右边
        // 任何位置都可能落进来。整条逻辑搬到 `rawBar`（应用层 sendEvent）与
        // `edgePad`（贴边 14 pt 的系统边缘滑动）之后，这里只留像素。
        pad.isUserInteractionEnabled = false
        pad.onDown = nil
        host.addSubview(pad)
        barPad = pad

        let bar = UIView(frame: .zero)
        bar.isUserInteractionEnabled = false
        bar.layer.cornerRadius = metrics(in: window?.bounds ?? UIScreen.main.bounds).barWidth / 2
        bar.layer.cornerCurve = .continuous
        bar.clipsToBounds = true
        pad.addSubview(bar)
        self.bar = bar

        // The adaptive half. A `UIVisualEffectView` is the only thing in UIKit
        // that answers "what colour is behind me" without a screenshot: it
        // samples the backdrop and keeps a readable contrast over a white page,
        // a black page and a photograph alike. The border in `paintBar` is the
        // fallback for the cases where a backdrop is unavailable.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.isUserInteractionEnabled = false
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.addSubview(blur)
        barBlur = blur

        paintBar()
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
            if AevonRingMenu.presented != nil { return "ring" }
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
            Log.write("ring: pad down at "
                      + String(format: "%.0f,%.0f", at.x, at.y)
                      + " inset=" + String(format: "%.0f", inset))
        }
        pad.onBlocked = { [weak self] reason in
            guard let self = self, self.stripProbe < 20 else { return }
            self.stripProbe += 1
            Log.write("ring: pad refused by " + reason)
        }
        pad.onReject = { [weak self] delta in
            guard let self = self, self.stripProbe < 20 else { return }
            self.stripProbe += 1
            Log.write("ring: strip refuse dx=" + String(format: "%.0f", delta.width)
                      + " dy=" + String(format: "%.0f", delta.height)
                      + " #" + String(self.stripProbe))
        }
        pad.onCancel = { [weak self] delta in
            guard let self = self, self.stripProbe < 20 else { return }
            self.stripProbe += 1
            // 未开就被抢断 = 「滑了没反应、日志还干净」的唯一来源，必须留证词。
            Log.write("ring: pad cancelled dx=" + String(format: "%.0f", delta.width)
                      + " dy=" + String(format: "%.0f", delta.height))
        }
        // 0.1.7 — 点击识别器不挂。用户明确要求「移除点击触发圆盘，只保留左滑」。
        host.addSubview(pad)
        edgePad = pad
    }

    /// 0.1.13 — 呼盘命中区的贴边列宽。唯一一处几何定义。
    ///
    /// 14 → 24：0.1.12 的真机日志（Aevon(100)）里 14 次落指**全部**在
    /// `x = 424…427`（离右缘 3~6 pt），一次没落在 408~423 这一段 —— 不是没人划，
    /// 是划了也落不进来。而这个文件里 0.0.55 留下的旧测（49 次 hold）说拇指中心
    /// 真正落在**离边 12~15 pt**：14 pt 的带宽正好把分布的中位数压在边界上，
    /// 一半样本在里、一半在外。24 pt 把 12~15 这一簇整个包进来，两侧各留余量。
    private let stripWidth: CGFloat = 24
    /// 0.1.13 — 可见抓手周围的宽区（「光环」）。
    ///
    /// 用户对着那条 6×87 的可见抓手去划，手落在哪儿不由我们决定；只在贴边 24 pt
    /// 里认，等于要求他把指尖顶到屏幕边缘。光环把**可见物的周围**也算成我们的，
    /// 而它只覆盖抓手上下 `haloHeight` 这一段，不是一个 46×326 的大方块 ——
    /// 方块会白吃掉应用右下角一整条（发送键、输入框都在那儿）。
    private let haloWidth: CGFloat = 46
    private let haloHeight: CGFloat = 176
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
        let h = bounds.height * edgeHeightPercent / 100
        return CGRect(x: bounds.maxX - stripWidth,
                      y: bounds.maxY - h,
                      width: stripWidth,
                      height: Swift.max(0, h))
    }

    /// 0.1.13 — 可见抓手周围那块宽区。中心跟着 `barY` 滑块走，高度 `haloHeight`。
    private func haloRect(in bounds: CGRect) -> CGRect {
        let centre = barCentreY(in: bounds)
        let h = Swift.min(haloHeight, stripRect(in: bounds).height)
        return CGRect(x: bounds.maxX - haloWidth,
                      y: centre - h / 2,
                      width: haloWidth, height: h)
    }

    /// 0.1.13 — 真正认领的两块地：贴边列 + 抓手光环。
    ///
    /// **认领 = 应用拿不到这一根手指**（窗口在上层，没有「先收下再还回去」这回事），
    /// 所以形状必须跟「看得见的东西 + 拇指落得到的地方」对齐，能小就不大。
    /// 列负责「贴着右缘随便哪一段都能划」，光环负责「对着抓手划但手落偏了」。
    private func claimRects(in bounds: CGRect) -> [CGRect] {
        guard bounds.width > 0 else { return [] }
        return [stripRect(in: bounds), haloRect(in: bounds)]
    }

    /// 两块地的外接矩形，也就是 `edgePad` 的 frame。命中与否由
    /// `EdgeSwipePad.point(inside:)` 按 `claimRects` 再判一次 —— 外接矩形里
    /// 不属于任何一块的那些点必须**放行**，否则 46×326 会被整块吃掉。
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

    /// 0.1.6 — 竖条与右缘带的触摸开关，唯一来源。
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
        // 0.1.6 — 竖条的地盘也一起对齐。`layout()` 里有 `bounds.width > 0` 的早退，
        // 窗口尺寸还没到位时那一拍不会写 `summonRect`，留一个 `.zero` 在里面就等于
        // 「条子看得见、按下去不算我的」。这里每 tick 补一次，代价是一次 CGRect 赋值。
        //
        // 0.1.7 — 写的是**贴边条带**，不是那块 40×212 的视觉垫子。垫子现在只是画
        // （`addBar`），拿它当「浮窗的环要让开的地盘」会白让掉 40 pt 宽的一条，
        // 卡片的右缘环在那里整块失效。
        if let window = window, window.bounds.width > 0 {
            AevonRingGrip.summonRect = stripRect(in: window.bounds)
        }
        let panel = AevonAppPanel.current != nil
        let card = FloatHost.anyCardUp
        let barOn = !panel
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
        // 0.1.7 — 视觉垫子永远不接触摸。触摸只有两个入口：`rawBar`（应用层）与
        // `edgePad`（贴边 14 pt）。这一行是 0.1.6 那个「开关唯一归口」的兑现：
        // 三处各写一遍的老写法（layout / openPanel / onClose）全撤之后，这里是
        // 唯一还会碰它的地方。
        if barPad?.isUserInteractionEnabled != false {
            barPad?.isUserInteractionEnabled = false
        }
        if edgePad?.isUserInteractionEnabled != edgeOn {
            edgePad?.isUserInteractionEnabled = edgeOn
        }
        guard barOn != gripLoggedBar || edgeOn != gripLoggedEdge else { return }
        gripLoggedBar = barOn
        gripLoggedEdge = edgeOn
        // 一整条字面量前缀（不是拼接）：审计要在二进制里 grep 到它。
        Log.write("ring: grip armed bar=" + (barOn ? "1" : "0")
                  + " edge=" + (edgeOn ? "1" : "0")
                  + " card=" + (card ? "1" : "0")
                  + " panel=" + (panel ? "1" : "0"))
    }

    /// 上一次写进日志的开关值，只用来去重。
    private var gripLoggedBar = true
    private var gripLoggedEdge = true

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
            if let menu = AevonRingMenu.presented {
                menu.beginRemoteTracking(at: point, source: "edge")
            } else {
                expanded = true
                AevonRingMenu.presentTracking(in: host, at: point, source: "edge")
                Log.write("ring: edge swipe open at "
                          + String(format: "%.0f,%.0f", point.x, point.y)
                          + " band=" + String(format: "%.0f", stripWidth))
            }

        case .moved:
            guard barHeld else { return }
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

    /// The disc hides the bar while it is open and asks for it back on the way
    /// down (`AevonRingGrip.setVisible(true)` in dismiss). Kept on the pad, not
    /// on the bar: alpha on the pad fades both without touching the material's
    /// own alpha.
    private func setGripVisible(_ visible: Bool) {
        guard let pad = barPad else { return }
        // 0.1.7 — 这里**不再**把 `isUserInteractionEnabled` 写回 true。
        //
        // 0.1.6 及以前这一行是「圆盘收起后把竖条交还给手指」。竖条现在只是画
        // （见 `addBar`），触摸全在 `rawBar` / `edgePad` 上；写回 true 等于把那块
        // 40×212 的隐形命中区又长回来，卡片里点右侧重新开始误触圆盘。
        UIView.animate(withDuration: 0.18) {
            pad.alpha = visible ? 1 : 0.72
        }
    }

    /// 0.0.44 — the strip has to be visible on whatever is behind it, and the
    /// answer is no longer a guessed pair of colours.
    ///
    /// The material supplies the fill; this supplies the edge. On a light page
    /// the material is a pale haze and needs a dark hairline; on a dark one it
    /// is a grey mist and needs the light one. That is one property write per
    /// layout pass, and it is what keeps the strip off the "invisible, therefore
    /// broken" list that the dot spent six versions on.
    private func paintBar() {
        guard let bar = bar else { return }
        let dark = window?.traitCollection.userInterfaceStyle == .dark
        if UIAccessibility.isReduceTransparencyEnabled {
            // No backdrop to sample: fall back to the dot's own recipe rather
            // than to an invisible strip.
            barBlur?.alpha = 0
            bar.backgroundColor = UIColor.white.withAlphaComponent(dark ? 0.66 : 0.88)
            bar.layer.borderColor = UIColor.black.withAlphaComponent(dark ? 0.50 : 0.45).cgColor
        } else {
            barBlur?.alpha = 1
            bar.backgroundColor = .clear
            bar.layer.borderColor = (dark ? UIColor.white : UIColor.black)
                .withAlphaComponent(0.32).cgColor
        }
        bar.layer.borderWidth = 0.5
        bar.alpha = 1
    }

    @objc private func toggle() {
        if expanded { collapse() } else { expand() }
    }

    /// 按住拖动（0.0.45）。
    ///
    /// 这条路从头到尾只有一根手指：落指 → 圆盘从这一点长出来 → 报告每一次移动
    /// → 抬手定生死。**没有任何一步替用户做决定**：
    ///
    ///   · 停在竖条上不动 → 圆盘开着（看门狗被 `barHeld` 挡住）；
    ///   · 向左划到某个图标 → 那个图标高亮（跳起回落的关键帧是圆盘自己的）；
    ///   · 抬手在图标上 → 打开浮窗；抬手在盘外 / 间隙 → 收起。
    ///
    /// 这三条不是这里写的规则，是 `AevonRingMenu.handlePointerEnded` 原本的语义
    /// （V0.2.18 AevonRingCloseOnLiftV218），这里只是把手指接上去。
    @objc private func handleBarPan(_ gesture: UIPanGestureRecognizer) {
        guard let window = window, let host = window.rootViewController?.view else { return }
        let point = gesture.location(in: window)

        switch gesture.state {
        case .began:
            barHeld = true
            if let menu = AevonRingMenu.presented {
                // 圆盘已经开着（点一下开的那种），这根手指直接接管它。
                menu.beginRemoteTracking(at: point, source: "bar")
            } else {
                expanded = true
                AevonRingMenu.presentTracking(in: host, at: point, source: "bar")
                Log.write("ring: held open at "
                          + String(format: "%.0f,%.0f", point.x, point.y)
                          + " (\(AevonRingStore.bundleIDs().count) apps)")
            }

        case .changed:
            AevonRingMenu.presented?.remoteMoved(to: point, source: "bar")

        case .ended, .cancelled, .failed:
            barHeld = false
            expanded = false
            guard let menu = AevonRingMenu.presented else { return }
            if gesture.state == .ended {
                // 权威抬手：不受 0.12 秒通道交换闸影响（V0.3.16）。
                menu.remoteLift(at: point, source: "bar")
            } else {
                // 手势被系统抢断 = 这根手指的去向不由我们决定了，收起最安全。
                menu.remoteCancelled(source: "bar")
            }
            Log.write("ring: bar released at "
                      + String(format: "%.0f,%.0f", point.x, point.y))

        default:
            break
        }
    }

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


    /// 0.0.49 — 把竖条那一层重新插回窗口栈顶。
    ///
    /// Aevon(47) #3 的现象是「注销后第一次非常灵敏，锁屏一次之后就不容易触发」。
    /// 条子的位置、长度、宽度都没变（日志里 `size=` 一直是同一组数），变的只有
    /// 窗口栈：锁屏 → 解锁会让 SpringBoard 重排一遍窗口，我们这一层可能被一个
    /// **透明但会接触摸**的窗口压住 —— 条子照样看得见（上面那层是透明的），按下去
    /// 却不算我们的。所以每次解锁 / 回到前台，把 level 抬一格再放回去：UIKit 在
    /// 每次 level 变化时都会把窗口重新插进窗口栈，这一下就是置顶，而且不重建
    /// 窗口、不碰 rootViewController、不丢已经挂上的手势。
    private func raiseWindow() {
        guard let window = window, !window.isHidden else { return }
        let level = window.windowLevel
        window.windowLevel = UIWindow.Level(rawValue: level.rawValue + 1)
        window.windowLevel = level
        window.isHidden = false
        Log.write("ring: bar layer put back on top (level="
                  + String(Int(level.rawValue)) + ")")
    }

    // MARK: - 0.0.45 系统面板豁免

    /// 锁屏 / 控制中心 / 通知中心 —— 竖条在这三处不出现（Aevon(43) #3）。
    ///
    /// 窗口层级（statusBar + 1）已经把这三种面板留在上面，但「没被盖住」不等于
    /// 「不该显示」：控制中心是半屏、锁屏是另一套 UI，竖条浮在上面既难看也没有
    /// 意义。所以再加一道主动隐藏，判据全部走运行时，不编译期依赖 SpringBoard。
    ///
    /// 0.35 秒缓存：这个查询每次要过 3 个单例 + 最多 6 次 KVC，而调用点是 0.4
    /// 秒一次的定时器 —— 缓存把「面板刚好在这个 tick 里打开」的延迟压到看不出来。
    private var systemOverlayUp: Bool {
        let now = CACurrentMediaTime()
        if now - overlayCheckedAt < 0.35 { return overlayUp }
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

    /// `responds(to:)` first, then KVC: `value(forKey:)` on a key the object does
    /// not have raises, and this runs in SpringBoard on a timer.
    private func boolValue(_ object: NSObject?, _ key: String) -> Bool {
        guard let object = object,
              object.responds(to: NSSelectorFromString(key)),
              let value = object.value(forKey: key) as? NSNumber else { return false }
        return value.boolValue
    }

    private func startOverlayWatch() {
        overlayTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.syncOverlayVisibility()
            // 0.1.6 — 同一个 tick 顺手把两个入口的开关对齐一次。它是「关死的
            // 入口」唯一的自愈路径：不依赖任何一条回调按时回来。
            self.syncGrip()
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayTimer = timer
    }

    private func syncOverlayVisibility() {
        guard let pad = barPad else { return }
        // 0.0.47 — 一次判真不算数。
        //
        // Aevon(45) #1 是「有时会无法触发，需要多次点击或滑动」。这个定时器就是
        // 那个「有时」：`systemOverlayUp` 是 0.35 秒缓存的单次采样，转场里读到
        // 一次「面板在上面」，`pad.isHidden` 就置真 —— 而隐藏的视图不参与命中，
        // 这一段时间里按上去什么都不会发生。两次连续判真才藏（0.4 秒一 tick，
        // 缓存 0.35 秒，两次采样互相独立），并且手指还在垫子上（`barHeld`）时
        // 一律不藏。
        if systemOverlayUp && !barHeld {
            overlayStrikes = Swift.min(overlayStrikes + 1, 2)
        } else {
            overlayStrikes = 0
        }
        let hidden = overlayStrikes >= 2 && !barHeld
        guard pad.isHidden != hidden else { return }
        pad.isHidden = hidden
        // 0.0.49 — 面板刚退下去，正是窗口栈最不可靠的时刻：顺手把这一层放回顶上，
        // 免得「看得见但按不到」。
        if !hidden { raiseWindow() }
        Log.write("ring: summon bar " + (hidden ? "hidden (system overlay up)"
                                                 : "shown (system overlay gone)"))
    }

    // MARK: - Disc (AevonRingMenu, 1:1)

    private func expand() {
        // 0.0.56 — 应用选择面板在屏时不呼圆盘：两者都要屏幕下半部，叠在一起
        // 就是「点哪儿都不对」。
        guard AevonAppPanel.current == nil else { return }
        guard !expanded, let host = window?.rootViewController?.view else { return }
        expanded = true

        // The disc reads the store itself, plays its own unfold
        // (`AevonRingUnfold` — the whole cluster grows from one point, the
        // GIF's own entrance) and owns every touch until it goes away.
        AevonRingMenu.present(in: host)
        Log.write("ring: expanded (\(AevonRingStore.bundleIDs().count) apps)")
    }

    private func collapse() {
        guard expanded else { return }
        expanded = false
        AevonRingMenu.dismissCurrent()
        Log.write("ring: collapsed")
    }

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
/// 0.1.13 — 认领的不是「14 pt 一条」而是两块地（见 `RingHost.claimRects`）：
/// 贴右缘 24 pt × 底部 35 % 的列，加上可见抓手周围 46×176 的宽区。Aevon(100)
/// 的 14 次落指全在离边 3~6 pt，而旧测说拇指中心通常落在 12~15 pt —— 14 pt 的
/// 带宽把分布的中位数压在边界上，这就是「触发几率很小」的主要来源。
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
        // ① 走够 8 pt 且横向占优 ⇒ 呼盘。两个条件同时成立，纵向拖不会误开。
        if dx <= -openDistance, abs(dx) > abs(dy) {
            opened = true
            onPhase?(.began, convert(start, to: window), convert(point, to: window))
            return
        }
        // ② 走得不远但甩得很快 ⇒ 也算。只按位移判会把短促左甩当点击扔掉，
        //    而拇指在窄带上最常用的正是这一种。
        if dx <= -flickDistance, speed >= flickSpeed, abs(dx) >= abs(dy) {
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
        if dx <= -openDistance, abs(dx) >= abs(dy) {
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
/// 0.0.47 — 落指就先报一声的触摸垫。
///
/// 「触发不灵敏」有两种事实：手指没落到垫子上，或者落上了但没被当成手势（手势
/// 仲裁、被别的窗口拿走、垫子被藏起来）。垫子在 `touchesBegan` 报一次，日志就能
/// 把这两种分开 —— 在此之前三轮里它们长得一模一样。
final class BarPad: UIView {
    var onDown: ((CGPoint) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            onDown?(touch.location(in: superview))
        }
        super.touchesBegan(touches, with: event)
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
