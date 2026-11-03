//
//  RingHost.swift — Aevon, the carrier shape on the home screen.
//
//  This is the part that makes the settings panel mean something. Until 0.0.5
//  the ring only existed inside a full-screen preview: the sliders wrote
//  values, the preview read them, and nothing on the desktop ever changed.
//  0.0.6 hosts the very same RingView in SpringBoard, so:
//
//      Settings → 半径/图标宽度/形状/旋转角/速度  →  ring.plist + Darwin
//      →  RingHost.refresh()  →  the ring on screen changes
//
//  Deliberate limits, because this runs inside SpringBoard:
//
//    · It never runs when Gate.evaluate() said anything but .pass.
//    · It owns one window at level normal+1, and that window returns nil from
//      hitTest everywhere except the grip and the icons. Everything else falls
//      through, so the home screen keeps every touch it had before.
//    · The ring starts collapsed: one 12 pt grip in the bottom-right corner.
//      No gesture hijack, no always-on overlay, nothing that can eat a swipe.
//    · `!ring.desktop = false` in Settings removes the window entirely without
//      a respring.
//
//  Gesture takeover (edge swipe to summon) is the last thing to be added, not
//  the first: a bad hit region is the one bug that makes a phone unusable.
//

import UIKit

final class RingHost: NSObject {

    static let shared = RingHost()

    /// Preference key for "put the grip on the home screen". Ships on, because
    /// a shape nobody can see is not a feature. Prefixed with "!" to stay out
    /// of the master's 81 keys and out of the generated 64-item table.
    static let enabledKey = "!ring.desktop"

    private var window: UIWindow?
    private var grip: UIView?
    private var gripPad: UIView?
    private var ring: RingView?

    private var config = RingConfig()
    private var apps: [RingApp] = []
    private var expanded = false
    private var preloaded = false

    /// Where the drag that is in progress started. Only used while a pan is
    /// live; the durable value is the normalised point in layout.plist.
    private var dragOrigin: CGPoint = .zero

    /// Cheap change detectors. Comparing a string costs nothing and lets a
    /// rotation or a slider drag skip the icon rebuild entirely.
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

        addGrip()
        layout()

        observe()
        Log.write("ring: hosted on desktop (radius=\(Int(config.radius)) "
                  + "icon=\(Int(config.iconWidth)) shape=圆盘)")

        // Warm the icon cache off the critical path. The first tap must not
        // pay for a LaunchServices enumeration; one second after mount is a
        // quiet moment even on a busy SpringBoard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.preloadIcons()
        }
    }

    func stop() {
        collapse(animated: false)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        grip?.removeFromSuperview()
        gripPad?.removeFromSuperview()
        grip = nil
        gripPad = nil
        window?.isHidden = true
        window = nil
        Log.write("ring: removed from desktop (switch off)")
    }

    /// Settings changed. Re-read the snapshot and either install, remove or
    /// reshape — never respring, never reload SpringBoard.
    func refresh() {
        guard isEnabled else {
            if window != nil { stop() }
            return
        }
        guard window != nil else { start(); return }

        let updated = RingConfig.loadRuntime()
        let changed = updated.radius != config.radius
            || updated.iconWidth != config.iconWidth
            || updated.rotation != config.rotation
            || updated.speed != config.speed
            || updated.damping != config.damping
            || updated.customSpring != config.customSpring
            || updated.star != config.star
            || updated.haptic != config.haptic
            || updated.intensity != config.intensity
            || updated.desktop != config.desktop
        config = updated

        // The app list is a separate file with its own lifecycle: it changes on
        // add / remove / reorder, not on a slider drag, so it gets its own
        // check instead of forcing a rebuild every time.
        let signature = RingApps.signature()
        var appsChanged = false
        if signature != appsSignature {
            appsSignature = signature
            let loaded = RingApps.resolved(limit: RingApps.maxCount)
            apps = loaded.apps
            appsChanged = true
            Log.write("ring: apps -> \(apps.count) (\(loaded.source.rawValue)), "
                      + (signature == "auto" ? "automatic list" : "operator list"))
        }

        // Applies a reset or a move made from Settings; harmless when the grip
        // has not moved.
        layout()

        guard changed || appsChanged else { return }
        if changed { Log.write("ring: live update -> \(config.summary)") }
        if expanded {
            ring?.rebuild(config: config, apps: apps.isEmpty ? nil : apps)
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

        let point = gripPoint(in: bounds)

        // The grip is a subview of the pad, so only the pad moves. Setting the
        // dot's centre here would move it in the pad's coordinate space.
        gripPad?.center = point
        window.rootViewController?.view.frame = bounds
        // A rotation can switch the appearance under a live dot; repainting on
        // every layout pass is one property write and keeps it visible through
        // that switch.
        paintGrip()

        if let ring = ring {
            ring.frame = bounds
            ring.movePivot(point)
        }
    }

    /// Where the grip belongs: the operator's own position when one was saved,
    /// the bottom-right corner otherwise. Normalised on purpose — 82% / 91% is
    /// the same place on the screen after a rotation, a stored point is not.
    private func gripPoint(in bounds: CGRect) -> CGPoint {
        if let saved = GripLayout.load() {
            return clamped(CGPoint(x: saved.x * bounds.width,
                                   y: saved.y * bounds.height),
                           in: bounds)
        }
        let inset = window?.safeAreaInsets ?? .zero
        let margin: CGFloat = 34
        return CGPoint(x: bounds.maxX - Swift.max(margin, inset.right + 14),
                       y: bounds.maxY - Swift.max(margin, inset.bottom + 22))
    }

    /// Keeps the whole 40 pt touch pad on screen. A grip dragged half off the
    /// edge is a grip that cannot be tapped back.
    private func clamped(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        let half: CGFloat = 20
        let x = Swift.min(bounds.maxX - half, Swift.max(half, point.x))
        let y = Swift.min(bounds.maxY - half, Swift.max(half, point.y))
        return CGPoint(x: x, y: y)
    }

    // MARK: - Grip

    private func addGrip() {
        guard let host = window?.rootViewController?.view else { return }

        // The dot is 14 pt because it must not look like a control; the touch
        // area is 40 pt because the corner of a phone is the hardest place to
        // hit. Same reason the pad is invisible: no chrome, just a target.
        let padSide: CGFloat = 40
        let pad = UIView(frame: CGRect(x: 0, y: 0, width: padSide, height: padSide))
        pad.backgroundColor = .clear
        pad.isUserInteractionEnabled = true
        pad.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                        action: #selector(toggle)))
        // Drag to move. The tap still wins for a touch that does not travel,
        // which is why the two recognisers can share the same 40 pt pad.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGripPan(_:)))
        pan.maximumNumberOfTouches = 1
        pad.addGestureRecognizer(pan)
        host.addSubview(pad)
        gripPad = pad

        let side: CGFloat = 14
        let grip = UIView(frame: CGRect(x: (padSide - side) / 2, y: (padSide - side) / 2,
                                        width: side, height: side))
        grip.layer.cornerRadius = side / 2
        grip.layer.cornerCurve = .continuous
        grip.isUserInteractionEnabled = false
        pad.addSubview(grip)
        self.grip = grip
        paintGrip()
    }

    /// 0.0.39 — the dot has to be visible on whatever is behind it.
    ///
    /// 0.0.38 painted it white at 22% with a 1 pt white border. On a white
    /// page — which is what a full-screen light-mode app is — that is not a
    /// faint dot, it is no dot: white on white with a white edge. Aevon(37)
    /// is the first log where the operator opened a light app and could not
    /// find it at all.
    ///
    /// The master has no desktop dot to copy the shape from: its handle is the
    /// edge bar (`EgdeGestureView`, `AppearEdge`, `_edgeWidth`) and it is
    /// summoned from the screen edge, not tapped. What the master does have,
    /// and what is copied here, is `_colorScheme` on `RingView` and on every
    /// capsule control: the chrome is repainted for the current appearance
    /// instead of assuming a dark one.
    ///
    /// So the dot is no longer one colour with one edge. It is a white core
    /// with a black outline, which is the only pair that reads on both a white
    /// page and a black one — the light core carries a dark screen, the dark
    /// outline carries a light one — and the outline thickens in light mode,
    /// where a hairline white-on-white would still be invisible at arm's
    /// length.
    private func paintGrip() {
        guard let grip = grip else { return }
        let dark = window?.traitCollection.userInterfaceStyle == .dark
        // Not `?? .dark`: an unanswered trait collection in SpringBoard is the
        // light case more often than not, and guessing wrong is what made the
        // dot vanish. 0.86/0.62 both read; only the outline changes.
        grip.backgroundColor = UIColor.white.withAlphaComponent(dark ? 0.62 : 0.86)
        grip.layer.borderWidth = dark ? 1 : 2
        grip.layer.borderColor = UIColor.black.withAlphaComponent(dark ? 0.45 : 0.55).cgColor
        grip.layer.shadowColor = UIColor.black.cgColor
        grip.layer.shadowOpacity = dark ? 0.45 : 0.35
        grip.layer.shadowRadius = 3
        grip.layer.shadowOffset = CGSize(width: 0, height: 1)
        grip.alpha = 1
    }

    @objc private func toggle() {
        if expanded { collapse(animated: true) } else { expand() }
    }

    /// Moving the grip is the one gesture this project takes for itself, so it
    /// is deliberately narrow: one finger, on a 40 pt pad, and the ring is put
    /// away the moment the drag starts. No long press, no swipe from an edge —
    /// a hijacked screen edge is the bug that makes a phone feel broken.
    @objc private func handleGripPan(_ gesture: UIPanGestureRecognizer) {
        guard let pad = gripPad, let host = window?.rootViewController?.view else { return }

        switch gesture.state {
        case .began:
            dragOrigin = pad.center
            if expanded { collapse(animated: true) }

        case .changed:
            let translation = gesture.translation(in: host)
            let target = clamped(CGPoint(x: dragOrigin.x + translation.x,
                                         y: dragOrigin.y + translation.y),
                                 in: host.bounds)
            pad.center = target
            ring?.movePivot(target)

        case .ended, .cancelled, .failed:
            let bounds = host.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let normalized = CGPoint(x: pad.center.x / bounds.width,
                                     y: pad.center.y / bounds.height)
            if GripLayout.save(normalized) {
                Log.write("ring: grip moved to \(Int(normalized.x * 100))% / "
                          + "\(Int(normalized.y * 100))%")
            }
            layout()   // re-clamps and re-reads, so the saved value is what is shown

        default:
            break
        }
    }

    private func animateGrip(expanded: Bool) {
        // 0.0.39 — 0.45 while expanded was another way of losing the dot: the
        // ring is drawn around it, and the only way to put the ring away is to
        // tap this. It now dims without becoming hard to find.
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState]) {
            self.grip?.alpha = expanded ? 0.72 : 1
        }
    }

    // MARK: - Ring

    private func expand() {
        guard !expanded, let host = window?.rootViewController?.view else { return }
        expanded = true

        let pivot = gripPad?.center ?? CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        let apps = currentApps()

        let ring = RingView(frame: host.bounds, config: config, apps: apps, pivot: pivot)
        ring.onPick = { [weak self] app in
            self?.open(app)
        }
        // 收藏 / 拖拽旋转 all end up in one file (apps.plist) or in the runtime
        // snapshot. The view never writes anything itself, so the two hosts
        // cannot disagree about who owns the data.
        //
        // 0.0.41 — 回收站 is gone. Deleting an app belonged to a drag that only
        // ever happened by accident (the same drag rotates the disc), and it
        // wrote to a file the operator could not see while doing it.
        ring.onPin = { [weak self] app in
            self?.pin(app)
        }
        ring.onConfigChange = { [weak self] edited in
            self?.persistGeometry(edited)
        }
        ring.onBackgroundTap = { [weak self] in
            self?.collapse(animated: true)
        }
        host.addSubview(ring)
        if let pad = gripPad { host.bringSubviewToFront(pad) }
        self.ring = ring
        ring.appear()
        animateGrip(expanded: true)
    }

    private func collapse(animated: Bool) {
        guard expanded || ring != nil else { return }
        expanded = false

        let dying = ring
        ring = nil
        guard let dying = dying else {
            animateGrip(expanded: false)
            return
        }
        if animated {
            dying.disappear { dying.removeFromSuperview() }
        } else {
            dying.removeFromSuperview()
        }
        animateGrip(expanded: false)
    }

    private func currentApps() -> [RingApp] {
        if apps.isEmpty { preloadIcons() }
        return apps
    }

    private func preloadIcons() {
        guard !preloaded else { return }
        preloaded = true
        // Main thread on purpose: the icon lookup walks LaunchServices and
        // draws placeholder tiles, and neither is documented as thread-safe.
        // Mount + 1 s is a quiet moment, so the cost is invisible.
        let started = Date()
        let loaded = RingApps.resolved(limit: RingApps.maxCount)
        apps = loaded.apps
        appsSignature = RingApps.signature()

        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        Log.write("ring: \(loaded.apps.count) apps via \(loaded.source.rawValue) in \(milliseconds)ms"
                  + (appsSignature == "auto" ? " (automatic)" : " (operator list)"))

        if expanded, !apps.isEmpty {
            ring?.rebuild(config: config, apps: apps)
        }
    }

    // MARK: - 托盘编辑（桌面侧）

    /// 收藏 (`Star`). A pinned app moves to the head of the ring, which is the
    /// only ordering the master's ring has.
    private func pin(_ app: RingApp) {
        let ok = RingApps.togglePin(app.bundleID)
        let now = RingApps.isPinned(app.bundleID)
        Log.write("ring: pin toggle " + app.bundleID + " -> " + (now ? "on" : "off")
                  + (ok ? "" : " (write failed)"))
        reloadApps()
    }

    /// 旋转角 set by dragging the empty arc. Written to the runtime snapshot so
    /// the ring comes back the way it was left; the settings slider stays the
    /// master control, so the next write from Settings wins.
    private func persistGeometry(_ edited: RingConfig) {
        var snapshot = RingConfig.loadRuntime()
        snapshot.rotation = edited.rotation
        config.rotation = edited.rotation
        if snapshot.writeSnapshot() {
            Log.write("ring: rotate -> " + config.summary)
        }
    }

    /// Re-reads apps.plist and rebuilds the open ring. Cheap: the icon images
    /// are cached by bundle id, so this is an array sort, not a redraw of the
    /// whole catalogue.
    private func reloadApps() {
        let loaded = RingApps.resolved(limit: RingApps.maxCount)
        apps = loaded.apps
        appsSignature = RingApps.signature()
        Log.write("ring: apps -> " + String(apps.count) + " (" + loaded.source.rawValue + ")")
        ring?.reload(apps: apps)
    }

    // MARK: - Launching

    /// 0.0.38 — the icon opens the app *as a floating card*, not full screen.
    ///
    /// Until this version the only way to a card was Settings → 窗口与场景 →
    /// arm → six seconds → switch to the app → swipe up to the desktop. The
    /// ring is already the operator's own list of apps, so a tap on it is the
    /// same request with one gesture instead of five.
    ///
    /// `SceneProbe.openCard` owns the whole route; this only decides what to do
    /// when it declines. A tap must never be a dead end: a suspended launch the
    /// system refuses, or a scene that never appears in four seconds, means the
    /// operator asked for an app and gets the app — plainly, full screen.
    private func open(_ app: RingApp) {
        collapse(animated: true)
        guard !app.bundleID.hasPrefix("placeholder.") else { return }
        SceneProbe.openCard(app.bundleID) { [weak self] reason in
            Log.write("ring: card route declined (" + reason + "), opening " + app.bundleID)
            self?.launch(app)
        }
    }

    /// The old behaviour, kept as the fallback and unchanged: the same private
    /// entry point SpringBoard itself uses. Guarded at every step: on a system
    /// without it the tap simply does nothing, which is a far better failure
    /// than an unrecognized selector inside SpringBoard.
    private func launch(_ app: RingApp) {
        guard !app.bundleID.hasPrefix("placeholder.") else { return }
        guard let meta = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            Log.write("ring: LSApplicationWorkspace unavailable, cannot open \(app.bundleID)")
            return
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard meta.responds(to: defaultSelector),
              let workspace = meta.perform(defaultSelector)?
                  .takeUnretainedValue() as? NSObject else { return }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector) else { return }

        Log.write("ring: launch \(app.bundleID)")
        _ = workspace.perform(openSelector, with: app.bundleID)
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
