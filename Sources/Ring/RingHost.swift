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

    /// 0.0.49 — 走应用层那条路时这根手指的状态。
    private var rawDownAt: CGPoint = .zero
    private var rawMovedFar = false
    private var rawOpenedHere = false
    private var barProbe = 0

    /// 0.1.9 — 圆盘在屏时落在盘面（全屏）上的手指，取证计数。
    private var discProbe = 0

    /// 0.0.55 — 右缘左滑呼盘的触摸带。旧版 `AevonRingGrip.bandRect` 的同一套几何：
    /// 贴右缘 15 pt 宽 × 屏幕底部 35 % 高。旧版在这台 17.3.1 上做过 49 次 hold
    /// 的落点统计（12~15 pt 占 84%，0~6 pt 一次都没有），15 pt 是「拇指顶在屏幕外
    /// 时手指中心真正落得到的地方」—— 不是拍出来的值，不要凭手感改。
    private var edgePad: UIView?
    /// 0.0.55 — 上一次由边缘带呼盘的时间。0.6 s 节流，旧版原值：一次呼盘之后
    /// 手指往往还贴着边，没有它，收起的圆盘会被同一段滑动立刻再喊出来。
    private var edgeAt: CFTimeInterval = 0
    /// 旧版常量：带宽 15 pt / 底部 35 % / 节流 0.6 s（zoneWDefault / zoneHDefault）。
    private let edgeWidth: CGFloat = 15
    private let edgeHeightPercent: CGFloat = 35
    private let edgeInterval: CFTimeInterval = 0.6

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
        // 0.0.49 — 竖条的手指入口。和浮窗环一样走 `-[UIApplication sendEvent:]`：
        // 锁屏一次之后窗口栈会被重排，我们这一层可能被一个透明窗压住，条子还
        // 看得见、按下去却不算我们的。这条路过的是事件，不是窗口，压不住。
        AevonRingGrip.barTouchHandler = { [weak self] phase, point, stamp in
            self?.rawBar(phase: phase, at: point, stamp: stamp) ?? false
        }

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
        AevonRingGrip.barTouchHandler = nil
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
        edgePad?.frame = stripRect(in: bounds)
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
                      // 0.1.8 — 呼盘命中区一起报：`strip=14x326 at y=606` 就是
                      // 「贴右缘 14 pt × 底部 35 %」的实测值，判据在日志里自证。
                      + " strip="
                      + String(format: "%.0fx%.0f at y=%.0f",
                               stripWidth, stripRect(in: bounds).height,
                               stripRect(in: bounds).minY))
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
    private func addEdgePad() {
        guard let host = window?.rootViewController?.view else { return }
        let pad = UIView(frame: .zero)
        pad.backgroundColor = .clear
        pad.isUserInteractionEnabled = true
        let pan = UIScreenEdgePanGestureRecognizer(target: self,
                                                   action: #selector(handleEdgePan(_:)))
        pan.edges = .right
        pan.maximumNumberOfTouches = 1
        pad.addGestureRecognizer(pan)
        // 0.1.7 — 点击识别器不挂。用户明确要求「移除点击触发圆盘，只保留左滑」。
        host.addSubview(pad)
        edgePad = pad
    }

    /// 0.1.7 — 呼盘的手势条：贴右缘。唯一一处几何定义。
    private let stripWidth: CGFloat = 14
    /// 0.1.7 — 认作「左滑」的最小横向位移。
    private let ringSwipe: CGFloat = 12

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
        let edgeOn = !panel && !card
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
    /// 旧版的经验值原样保留：带内不看方向、移动就召唤，0.6 s 节流。
    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let window = window, let host = window.rootViewController?.view else { return }
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began:
            // 卡片在屏：这条带闭嘴（它与浮窗外侧手势环在右下角重叠）。
            // 0.1.6 — 判据改成现算，见 `FloatHost.anyCardUp`。
            guard !FloatHost.anyCardUp else { return }
            // 0.1.7 — **只认向左划**。`UIScreenEdgePanGestureRecognizer` 只保证
            // 「从右缘起手」，方向它不管；不判这一下，从右缘往右/上下划也会呼盘。
            // 位移取的是 gesture 的累计平移，`.began` 时约 10 pt，符号是可靠的。
            guard gesture.translation(in: window).x < 0 else { return }
            let now = CACurrentMediaTime()
            guard now - edgeAt > edgeInterval else { return }
            edgeAt = now
            barHeld = true
            if let menu = AevonRingMenu.presented {
                menu.beginRemoteTracking(at: point, source: "edge")
            } else {
                expanded = true
                AevonRingMenu.presentTracking(in: host, at: point, source: "edge")
                Log.write("ring: edge swipe open at "
                          + String(format: "%.0f,%.0f", point.x, point.y)
                          + " band=" + String(format: "%.0f", edgeWidth))
            }

        case .changed:
            guard barHeld else { return }
            AevonRingMenu.presented?.remoteMoved(to: point, source: "edge")

        case .ended, .cancelled, .failed:
            guard barHeld else { return }
            barHeld = false
            expanded = false
            guard let menu = AevonRingMenu.presented else { return }
            if gesture.state == .ended {
                menu.remoteLift(at: point, source: "edge")
            } else {
                menu.remoteCancelled(source: "edge")
            }
            Log.write("ring: edge swipe released at "
                      + String(format: "%.0f,%.0f", point.x, point.y))

        default:
            break
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

    // MARK: - 0.0.49 竖条的应用层触摸

    /// 贴右缘那一条的手指，来源是 `-[UIApplication sendEvent:]`（见 `AevonRingGrip.barTouch`）。
    ///
    /// `phase` 用 UITouchPhase 的数值：0 began / 1 moved / 3 ended / 4 cancelled。
    /// 返回 true = 这条事件被这条带子吃掉，不再往下传（也不再有 UIKit 识别器参与）。
    ///
    /// 0.1.7 — **语义整条换掉，按用户 Aevon(94) 第 1 条**：
    ///
    ///   「圆盘触发条区域中当你点击全屏应用的操作是会误触圆盘触发。并且向左滑动时
    ///     也会误触发全屏 app 内的应用操作。…… 并且移除点击触发圆盘的功能，只保留
    ///     左滑触发圆盘。」
    ///
    /// 旧的语义是「落在 40×212 垫子上就开（按住拖动）」+「短按 = 点一下开/关」。
    /// 垫子 40 pt 宽几乎盖住右缘一整条，卡片里点右侧任何位置都会呼出圆盘；短按那
    /// 一支更是纯粹的多余手势。
    ///
    /// 新语义只有一条：
    ///   · 落指**必须在贴右缘 14 pt 的条带里**（`stripRect`）—— 之外的点击一律
    ///     放行，App 该干嘛干嘛；
    ///   · 条带内落指先**吞住**（不然 UIKit 那两条识别器会抢，卡片的环也会抢），
    ///     但**不弹盘**；
    ///   · 手指**向左**移过 `ringSwipe`（12 pt）且横向占优，才在那一刻把圆盘从起点
    ///     长出来，随后跟随；
    ///   · 抬手：认过方向 → `remoteLift` 定生死；没认过方向（= 一次点击）→
    ///     **什么都不做**。点击触发圆盘那条路从这一版起不存在。
    func rawBar(phase: Int, at point: CGPoint, stamp: TimeInterval) -> Bool {
        guard let window = window, let host = window.rootViewController?.view else { return false }
        // 0.0.56 — 面板在屏时，应用层这条入口也要闭嘴。竖条和右缘带的视图触摸
        // 已经关了，但这条路走的是 `-[UIApplication sendEvent:]`，不经过视图 ——
        // 少了这一句，面板上滑一下就会从面板底下长出一个圆盘。
        guard AevonAppPanel.current == nil else { return false }

        if stripHeld {
            switch phase {
            case 0:
                // 第二条通道把同一根手指的 began 又送了一次（Aevon(58) 的成对日志）。
                // 手已经在手里了，保持原状，别再开一次。
                return true
            case 1:
                let dx = point.x - rawDownAt.x
                let dy = point.y - rawDownAt.y
                // 方向确认只在第一次过线时做一次。
                if !barTracked, dx <= -ringSwipe, abs(dx) >= abs(dy) {
                    barTracked = true
                    if let menu = AevonRingMenu.presented {
                        menu.beginRemoteTracking(at: point, source: "edge")
                    } else {
                        AevonRingMenu.presentTracking(in: host, at: rawDownAt, source: "edge")
                    }
                    Log.write("ring: edge swipe open at "
                              + String(format: "%.0f,%.0f", rawDownAt.x, rawDownAt.y)
                              + " band=" + String(format: "%.0f", stripWidth))
                }
                if barTracked {
                    AevonRingMenu.presented?.remoteMoved(to: point, source: "edge")
                }
                return true
            case 3, 4:
                stripHeld = false
                barHeld = false
                let tracked = barTracked
                barTracked = false
                guard let menu = AevonRingMenu.presented else { return true }
                if !tracked {
                    // 一次点击（或一次纵向滚动）：用户要求点击不触发圆盘，
                    // 所以这里既不开也不关，静默收尾。
                    return true
                }
                if phase == 4 {
                    menu.remoteCancelled(source: "edge")
                    Log.write("ring: edge swipe cancelled by the system")
                } else {
                    menu.remoteLift(at: point, source: "edge")
                    Log.write("ring: edge swipe released at "
                              + String(format: "%.0f,%.0f", point.x, point.y))
                }
                return true
            default:
                return true
            }
        }

        // 0.1.9 — 圆盘在屏时它是**模态的**（全屏暗化 + 抬手未选中就收起），但它的
        // 触摸一条都收不到：宿主窗口对触摸是穿透的，`AevonRingMenu` 自己的
        // `touchesBegan` 从来没被调用过。此前手指落在盘面上滑动，整条漏给下面的
        // App —— 用户 Aevon(96) 第 1 条「圆盘打开期间手指在圆盘中滑动时会触发
        // 应用内的滑动」。所以应用层把圆盘期间的**全屏**触摸接过来，按三条远程
        // 通道喂给圆盘（点图标 / 圆心开面板 / 盘外收起全在 `handlePointerEnded`）。
        //
        // 为什么是全屏而不是「盘面那个圆」：圆盘开着时它把整屏压暗了 28 %，
        // 语义上就是模态；盘外的落指本来就该走「抬手未选中 → 收起」这一条，
        // 不该同时点到下面的 App。
        if let menu = AevonRingMenu.presented {
            switch phase {
            case 0:
                if !menu.isPointerActive {
                    menu.beginRemoteTracking(at: point, source: "disc")
                    if discProbe < 20 {
                        discProbe += 1
                        Log.write("ring: disc touch down at "
                                  + String(format: "%.0f,%.0f", point.x, point.y)
                                  + " #" + String(discProbe))
                    }
                }
                return true
            case 1:
                menu.remoteMoved(to: point, source: "disc")
                return true
            case 3:
                menu.remoteLift(at: point, source: "disc")
                return true
            case 4:
                menu.remoteCancelled(source: "disc")
                return true
            default:
                return true
            }
        }

        // 新的一根手指：只认贴边条带里的落指。
        guard phase == 0 else { return false }
        guard stripRect(in: window.bounds).contains(point) else { return false }
        rawDownAt = point
        stripHeld = true
        barHeld = true          // 看门狗（`hasActiveGripTouch`）与右侧遮罩都读它
        barTracked = false
        if barProbe < 20 {
            barProbe += 1
            Log.write("ring: bar raw down at "
                      + String(format: "%.0f,%.0f", point.x, point.y)
                      + " strip=" + String(format: "%.0f", stripWidth)
                      + " #" + String(barProbe))
        }
        return true
    }

    /// 0.1.7 — 这一根手指已经确认是「左滑」并且圆盘已经长出来了。
    private var barTracked = false

    /// 0.1.7 — `rawBar` 自己那根手指的状态。
    ///
    /// 不能复用 `barHeld`：那是 UIKit 那条边缘 pan（`handleEdgePan`）的状态，
    /// 也是圆盘看门狗 `hasActiveGripTouch` 的读数。两个入口在同一根手指上互相
    /// 覆盖，就会出现「pan 已经接管、rawBar 还把 moved 吃掉」这种僵局 ——
    /// 圆盘长出来之后不再跟手。`barHeld` 现在只是它的镜像。
    private var stripHeld = false

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
