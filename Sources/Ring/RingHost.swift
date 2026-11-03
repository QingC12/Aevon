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
    private let barWidth: CGFloat = 8
    private let barHeight: CGFloat = 56
    private let padWidth: CGFloat = 46
    private let padHeight: CGFloat = 150

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

        addBar()
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
        bar = nil
        barBlur = nil
        barPad = nil
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
                self?.layout()
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
        let centre = barCentreY(in: bounds)
        barPad?.frame = CGRect(x: bounds.maxX - padWidth,
                               y: centre - padHeight / 2,
                               width: padWidth, height: padHeight)
        bar?.frame = CGRect(x: padWidth - barWidth, y: (padHeight - barHeight) / 2,
                            width: barWidth, height: barHeight)
        // 0.0.48 — 竖条的触摸垫位置交给浮窗那一侧。浮窗的手指入口在应用层就
        // 把环上的触摸吃掉了，环的右半边正好压在这里；没有这条线，卡片开着时
        // 点竖条会被当成拖浮窗（见 AevonRingGrip.summonRect）。
        AevonRingGrip.summonRect = barPad?.frame ?? .zero
        window.rootViewController?.view.frame = bounds
        paintBar()

        // 面板正在上面的时候换了页面（比如通知中心拉下来又弹回去），
        // layout 是唯一会被叫到的地方，顺手把可见性对齐一次。
        syncOverlayVisibility()

        let percent = Int((config.barY).rounded())
        if percent != laidOutPercent {
            laidOutPercent = percent
            Log.write("ring: bar position " + String(percent)
                      + "% of the screen height (right edge)")
        }
    }

    /// Where the strip's centre sits, as the operator's percentage of the
    /// screen height. The pad's half-height is the clamp, not the strip's: a
    /// bar at 0 % must still be reachable, and the thing the finger lands on is
    /// the pad.
    private func barCentreY(in bounds: CGRect) -> CGFloat {
        let half = padHeight / 2
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
        bar.layer.cornerRadius = barWidth / 2
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
        Log.write("ring: summon bar " + (hidden ? "hidden (system overlay up)"
                                                 : "shown (system overlay gone)"))
    }

    // MARK: - Disc (AevonRingMenu, 1:1)

    private func expand() {
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

    /// 圆心（四宫格面板入口）→ 设置。The old plugin opened an in-SpringBoard app
    /// panel here; this package's panel is the Settings editor (圆盘 App), and
    /// opening the Settings app is the one honest route a tweak has.
    private func openPanel() {
        Log.write("ring: center panel -> Settings (圆盘 App editor)")
        launch("com.apple.Preferences")
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
