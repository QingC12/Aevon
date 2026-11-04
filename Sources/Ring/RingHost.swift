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
        AevonRingGrip.summonRect = barPad?.frame ?? .zero
        // 0.0.55 — 右缘带：贴右缘 15 pt，从底部往上 35 %。卡片在屏时收回触摸
        //（`AevonRingGrip.cardUp`），否则右下角拖卡片的手会先落进带子里。
        let edgeH = bounds.height * edgeHeightPercent / 100
        edgePad?.frame = CGRect(x: bounds.maxX - edgeWidth,
                                y: bounds.maxY - edgeH,
                                width: edgeWidth, height: edgeH)
        edgePad?.isUserInteractionEnabled = !AevonRingGrip.cardUp
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
                      + String(Int(m.padHeight.rounded())))
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
        pad.isUserInteractionEnabled = true
        pad.onDown = { [weak self] point in
            guard let self = self, self.padProbe < 20 else { return }
            self.padProbe += 1
            Log.write("ring: bar touch at " + String(format: "%.0f,%.0f", point.x, point.y)
                      + " #" + String(self.padProbe))
        }
        pad.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                        action: #selector(toggle)))
        // 0.0.45 — 滑动呼出改成**按住拖动**，这是 Aevon(43) #5 的原话：
        // 「旧版圆盘的逻辑是滑动时出现圆盘，手指没有离开屏幕时圆盘不会自动收起，
        //   手指离开屏幕时会自动关闭圆盘」。
        //
        // 0.0.44 用的是 `UISwipeGestureRecognizer`，它只在**手指抬起时**才识别
        // 成功 —— 也就是说圆盘是在手指离开之后才出现的，此后没有任何东西在喂它，
        // 于是「按住不放也不收」从物理上就不可能。`UIPanGestureRecognizer` 从
        // 落指那一刻就开始报，正好把整根手指交给圆盘（presentTracking 一族）。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleBarPan(_:)))
        pan.maximumNumberOfTouches = 1
        // 不做方向过滤。竖条只有 40x112，落在这块面积上的触摸本来就是给它的；
        // 反过来，「先往下再往左」的斜滑很常见，方向闸门只会把这类真实的拖动
        // 判成失败（而失败后这根手指就再也不会被重新考虑）。
        pad.addGestureRecognizer(pan)
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

    /// 0.0.55 — 右缘那条「贴边左滑呼盘」的带子（移植旧版 V0.3.28 AevonEdgeBandOnly328）。
    ///
    /// 为什么不是 `UIPanGestureRecognizer`：旧版自建腿用的就是系统那个
    /// `UIScreenEdgePanGestureRecognizer`（`edges = .right`），它自己只认「从屏幕
    /// 边缘起手 + 横向划」—— 竖着划会识别失败并把手指还给 App，这正是我们要的
    /// 那一半放行。换成通用 pan，右缘上下滚动也会被算成呼盘。
    ///
    /// 它和竖条的 `barPad` 是两块互不相干的地盘：竖条在屏幕高度 50 % 附近，
    /// 这条在底部 35 %，各挂各的识别器，谁都不改谁的帧。
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
        host.addSubview(pad)
        edgePad = pad
    }

    /// 0.0.55 — 浮窗开/关时同步右缘带能不能接触摸。
    ///
    /// 只在 `layout()` 里同步是不够的：卡片是在两次布局之间打开的，那段时间
    /// 边缘带还开着，右下角的手会先落进带子里 —— 守卫里那句 `cardUp` 能拦住
    /// 呼盘，拦不住「这根手指已经被吃掉」。
    func setEdgeActive(_ active: Bool) {
        edgePad?.isUserInteractionEnabled = active
    }

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
            guard !AevonRingGrip.cardUp else { return }
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
        pad.isUserInteractionEnabled = true
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

    /// 竖条的手指，来源是 `-[UIApplication sendEvent:]`（见 `AevonRingGrip.barTouch`）。
    ///
    /// `phase` 用 UITouchPhase 的数值：0 began / 1 moved / 3 ended / 4 cancelled。
    /// 返回 true = 这条事件被竖条吃掉，不再往下传（也不再有 UIKit 识别器参与）。
    ///
    /// 语义与 `handleBarPan` 完全一致，一个字都没改：
    ///   · 落指 → 圆盘从这一点长出来；
    ///   · 手指在屏幕上 → 圆盘跟着走，`barHeld` 挡住看门狗；
    ///   · 抬手在图标上 → 打开浮窗；抬手在盘外 → 收起。
    ///
    /// 唯一的补充是「短按」：这条路吃掉了事件，识别器不会响，所以原来由
    /// UITapGestureRecognizer 负责的「点一下开 / 再点一下关」在这里补：
    /// 手指没怎么动就抬手，按 `toggle()` 的语义处理。
    func rawBar(phase: Int, at point: CGPoint, stamp: TimeInterval) -> Bool {
        guard let window = window, let host = window.rootViewController?.view else { return false }
        // 0.0.56 — 面板在屏时，应用层这条入口也要闭嘴。竖条和右缘带的视图触摸
        // 已经关了，但这条路走的是 `-[UIApplication sendEvent:]`，不经过视图 ——
        // 少了这一句，面板上滑一下就会从面板底下长出一个圆盘。
        guard AevonAppPanel.current == nil else { return false }
        // 只在两种情况下接管：手指落在垫子上，或者这根手指已经在驱动圆盘了。
        // 圆盘是「点一下」开着的时候，盘面上的触摸交给圆盘自己的窗口。
        let onPad = AevonRingGrip.summonRect.contains(point)
        guard barHeld || (onPad && AevonRingMenu.presented == nil) else { return false }

        switch phase {
        case 0:
            rawDownAt = point
            rawMovedFar = false
            rawOpenedHere = (AevonRingMenu.presented == nil)
            barHeld = true
            if let menu = AevonRingMenu.presented {
                menu.beginRemoteTracking(at: point, source: "bar")
            } else {
                expanded = true
                AevonRingMenu.presentTracking(in: host, at: point, source: "bar")
            }
            if barProbe < 20 {
                barProbe += 1
                Log.write("ring: bar raw down at "
                          + String(format: "%.0f,%.0f", point.x, point.y)
                          + " pad=" + String(format: "%.0f,%.0f",
                                             AevonRingGrip.summonRect.minX,
                                             AevonRingGrip.summonRect.minY)
                          + " #" + String(barProbe))
            }
            return true

        case 1:
            guard barHeld else { return false }
            if abs(point.x - rawDownAt.x) + abs(point.y - rawDownAt.y) > 6 {
                rawMovedFar = true
            }
            AevonRingMenu.presented?.remoteMoved(to: point, source: "bar")
            return true

        case 3, 4:
            guard barHeld else { return false }
            barHeld = false
            let held = rawMovedFar
            let openedHere = rawOpenedHere
            rawMovedFar = false
            guard let menu = AevonRingMenu.presented else {
                expanded = false
                return true
            }
            if phase == 4 {
                expanded = false
                menu.remoteCancelled(source: "bar")
                Log.write("ring: bar raw cancelled by the system")
                return true
            }
            if held {
                expanded = false
                menu.remoteLift(at: point, source: "bar")
            } else if openedHere {
                // 短按 = 点一下竖条。跟踪式呈现换成常驻式，和 `expand()` 一样。
                AevonRingMenu.dismissCurrent()
                expanded = false
                expand()
                Log.write("ring: bar raw tapped open")
            } else {
                expanded = false
                collapse()
                Log.write("ring: bar raw tapped closed")
            }
            return true

        default:
            return barHeld
        }
    }

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
            self?.syncOverlayVisibility()
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
        barPad?.isUserInteractionEnabled = false
        edgePad?.isUserInteractionEnabled = false
        Log.write("ring: center panel -> app chooser (" + String(RingIcons.catalogue().count) + " apps)")
        AevonAppPanel.present(in: host,
                              onPick: { [weak self] bundleID in
                                  self?.openFromRing(bundleID)
                              },
                              onClose: { [weak self] reason in
                                  guard let self = self else { return }
                                  self.barPad?.isUserInteractionEnabled = true
                                  self.edgePad?.isUserInteractionEnabled = !AevonRingGrip.cardUp
                                  Log.write("ring: app chooser gone (" + reason + "), grip back")
                              })
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
