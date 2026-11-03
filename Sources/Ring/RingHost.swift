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
//    · the grip dot — tap to summon, drag to move (this package's entry; the
//      old plugin summoned from a screen-edge bar, which this phone's build
//      replaced with a dot on purpose),
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
    private var grip: UIView?
    private var gripPad: UIView?

    /// Where the drag that is in progress started. Only used while a pan is
    /// live; the durable value is the normalised point in layout.plist.
    private var dragOrigin: CGPoint = .zero

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

        addGrip()
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

        grip?.removeFromSuperview()
        gripPad?.removeFromSuperview()
        grip = nil
        gripPad = nil
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

        let point = gripPoint(in: bounds)

        // The grip is a subview of the pad, so only the pad moves. Setting the
        // dot's centre here would move it in the pad's coordinate space.
        gripPad?.center = point
        window.rootViewController?.view.frame = bounds
        // A rotation can switch the appearance under a live dot; repainting on
        // every layout pass is one property write and keeps it visible through
        // that switch.
        paintGrip()
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

    /// The menu hides the dot while it is open and asks for it back on the way
    /// down (`AevonRingGrip.setVisible(true)` in dismiss). The dot stays
    /// visible here — tapping it again is this build's way of closing the disc
    /// — but the hook exists so the menu's own dismiss path stays 1:1 with the
    /// file it came from.
    private func setGripVisible(_ visible: Bool) {
        guard let pad = gripPad else { return }
        pad.isUserInteractionEnabled = true
        UIView.animate(withDuration: 0.18) {
            pad.alpha = visible ? 1 : 0.72
        }
    }

    /// 0.0.39 — the dot has to be visible on whatever is behind it.
    ///
    /// A white core with a black outline is the only pair that reads on both a
    /// white page and a black one; the outline thickens in light mode, where a
    /// hairline white-on-white would still be invisible at arm's length.
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
        if expanded { collapse() } else { expand() }
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
            pad.isUserInteractionEnabled = true
            if expanded { collapse() }

        case .changed:
            let translation = gesture.translation(in: host)
            let target = clamped(CGPoint(x: dragOrigin.x + translation.x,
                                         y: dragOrigin.y + translation.y),
                                 in: host.bounds)
            pad.center = target

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
