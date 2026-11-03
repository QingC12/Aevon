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
    private let barWidth: CGFloat = 8
    private let barHeight: CGFloat = 56
    private let padWidth: CGFloat = 40
    private let padHeight: CGFloat = 112

    /// The last percentage that was laid out, so a slider drag logs one line per
    /// real change instead of one per refresh.
    private var laidOutPercent: Int = -1

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
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
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

        addBar()
        layout()
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
        window.rootViewController?.view.frame = bounds
        paintBar()

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

        // The pad is the target, the bar is the paint job. 40 pt of pad means a
        // thumb that lands half an inch from the edge still finds it; the pad is
        // flush with the screen edge so nothing has to be aimed at.
        let pad = UIView(frame: .zero)
        pad.backgroundColor = .clear
        pad.isUserInteractionEnabled = true
        pad.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                        action: #selector(toggle)))
        // 0.0.44 — 「点击或者向左滑动时触发」. A swipe recogniser, not a pan: this
        // one only has to fire, and a pan would need its own failure rules
        // against the tap.
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipeOpen))
        swipe.direction = .left
        swipe.numberOfTouchesRequired = 1
        pad.addGestureRecognizer(swipe)
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

    /// 向左滑动 → 呼出. The bar sits on the right edge, so the natural gesture is
    /// the thumb travelling away from the edge. It only ever opens: a swipe that
    /// closes would fight the disc's own lift-to-dismiss, which already ends in
    /// the same place.
    @objc private func swipeOpen(_ gesture: UISwipeGestureRecognizer) {
        if expanded { return }
        expand()
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
