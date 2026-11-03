//
//  RingPreviewController.swift — Aevon, a place to look at the carrier shape.
//
//  Why the preview lives inside Settings instead of on the home screen:
//  the shape is what is being reviewed right now, and a shape can be reviewed
//  without a window. Hosting it here means zero new code in SpringBoard, zero
//  respring to look at it, and zero chance that a geometry experiment can stop
//  a phone from booting. The RingView it hosts is the exact same class the
//  floating window will host later.
//
//  Everything on screen is derived from the Ring panel's own values, so moving
//  a slider and tapping 重播 is a real experiment, not a mock-up.
//

import UIKit

final class RingPreviewController: UIViewController {

    private var config: RingConfig
    private var apps: [RingApp]
    private let source: IconSource

    private var ring: RingView?
    private var guide: RingGuideView?
    private var chrome: [UIView] = []
    private var pivot: CGPoint = .zero
    private let toast = UILabel()

    init(config: RingConfig, apps: [RingApp], source: IconSource) {
        self.config = config
        self.apps = apps
        self.source = source
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("RingPreviewController is created in code only")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1)
        buildChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        pivot = CGPoint(x: view.bounds.midX, y: view.bounds.midY + 40)

        if guide == nil {
            let guide = RingGuideView(frame: view.bounds)
            guide.config = config
            guide.pivot = pivot
            guide.rings = config.ringCount(for: apps.count)
            guide.backgroundColor = .clear
            guide.isUserInteractionEnabled = false
            view.insertSubview(guide, at: 0)
            self.guide = guide
        }
        guide?.frame = view.bounds
        guide?.rings = config.ringCount(for: apps.count)
        guide?.setNeedsDisplay()

        if ring == nil {
            let ring = RingView(frame: view.bounds, config: config, apps: apps, pivot: pivot)
            ring.onPick = { [weak self] app in self?.showToast(app.name) }
            // The preview is the only place these can be tried without a
            // respring, so it has to exercise the same callbacks the desktop
            // host does — otherwise it is a picture, not a test.
            ring.onPin = { [weak self] app in self?.pin(app) }
            ring.onConfigChange = { [weak self] edited in self?.persist(edited) }
            ring.onBackgroundTap = { [weak self] in self?.showToast("点图标启动 · 空档拖动旋转 · 长按收藏") }
            view.addSubview(ring)
            bringChromeToFront()
            self.ring = ring
            ring.appear()
        }
        ring?.frame = view.bounds
    }

    /// The ring is added during layout, so it lands above everything that was
    /// built in viewDidLoad. Re-raising the recorded chrome is order-explicit:
    /// no guess about subview indices, no optional comparison.
    private func bringChromeToFront() {
        for subview in chrome {
            view.bringSubviewToFront(subview)
        }
    }

    // MARK: Chrome

    private func buildChrome() {
        let title = UILabel()
        title.text = "承载形状 · 圆盘"
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white

        let subtitle = UILabel()
        subtitle.text = config.summary
        subtitle.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.62)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let origin = UILabel()
        origin.text = "\(apps.count) 个 App · \(source.note)"
        origin.font = .systemFont(ofSize: 12)
        origin.textColor = UIColor.white.withAlphaComponent(0.42)
        origin.textAlignment = .center
        origin.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [title, subtitle, origin])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        chrome.append(header)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = UIColor.white.withAlphaComponent(0.75)
        close.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        close.layer.cornerRadius = 17
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(close)
        chrome.append(close)

        let replay = UIButton(type: .system)
        replay.setTitle("重播动画", for: .normal)
        replay.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        replay.tintColor = .white
        replay.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        replay.layer.cornerRadius = 20
        // No contentEdgeInsets: deprecated in iOS 15 and ignored once the
        // button has a configuration. The size is expressed as constraints
        // instead, which keeps the pill the same on every iOS this runs on.
        replay.translatesAutoresizingMaskIntoConstraints = false
        replay.addTarget(self, action: #selector(replayTapped), for: .touchUpInside)
        view.addSubview(replay)
        chrome.append(replay)

        let hint = UILabel()
        hint.text = "点图标看它属于哪个 App。在图标之间的空档拖动可整体旋转。"
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = UIColor.white.withAlphaComponent(0.38)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        chrome.append(hint)

        toast.font = .systemFont(ofSize: 14, weight: .medium)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        toast.layer.cornerRadius = 14
        toast.layer.masksToBounds = true
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        chrome.append(toast)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 56),

            close.topAnchor.constraint(equalTo: safe.topAnchor, constant: 18),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            close.widthAnchor.constraint(equalToConstant: 34),
            close.heightAnchor.constraint(equalToConstant: 34),

            replay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            replay.widthAnchor.constraint(equalToConstant: 152),
            replay.heightAnchor.constraint(equalToConstant: 44),
            replay.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -14),

            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            hint.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -18),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: replay.topAnchor, constant: -16),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            toast.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: Actions

    // MARK: Live editing (same file the desktop reads)

    private func reloadApps() {
        let loaded = RingApps.resolved(limit: RingApps.maxCount)
        apps = loaded.apps
        ring?.reload(apps: apps)
    }

    private func pin(_ app: RingApp) {
        RingApps.togglePin(app.bundleID)
        let pinned = RingApps.isPinned(app.bundleID)
        Log.write("prefs: preview pin " + app.bundleID + " -> " + (pinned ? "on" : "off"))
        showToast(pinned ? "已收藏 " + app.name : "已取消收藏 " + app.name)
        reloadApps()
    }

    private func persist(_ edited: RingConfig) {
        config.rotation = edited.rotation
        var snapshot = RingConfig.loadRuntime()
        snapshot.rotation = edited.rotation
        snapshot.writeSnapshot()
        Log.write("prefs: preview geometry -> " + config.summary)
    }

    @objc private func closeTapped() {
        if let ring = ring {
            ring.disappear { [weak self] in self?.dismiss(animated: true) }
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func replayTapped() {
        ring?.replay()
    }

    private func showToast(_ name: String) {
        toast.text = "  \(name)  "
        toast.alpha = 0
        UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 }
        UIView.animate(withDuration: 0.35, delay: 1.1, options: [.curveEaseIn], animations: {
            self.toast.alpha = 0
        })
    }
}

// MARK: - Guide

/// Faint proof of the geometry: every ring the current list actually uses, the
/// starting angle, and the pivot. Without it, "半径 64" is a number; with it,
/// the number is visible next to the icons that use it — and so is the ring the
/// ninth icon went to, which is the one thing 0.0.41 added.
final class RingGuideView: UIView {

    var config = RingConfig()
    var pivot: CGPoint = .zero
    /// How many rings this list needs. Set by the controller from the live
    /// count, so the guide draws the shape the icons are on.
    var rings = 1

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let dash: [CGFloat] = [2, 5]
        for ring in 0..<Swift.max(1, rings) {
            let radius = config.radius(of: ring)
            let circle = UIBezierPath(ovalIn: CGRect(x: pivot.x - radius,
                                                     y: pivot.y - radius,
                                                     width: radius * 2,
                                                     height: radius * 2))
            circle.lineWidth = 1
            circle.setLineDash(dash, count: dash.count, phase: 0)
            UIColor.white.withAlphaComponent(ring == 0 ? 0.20 : 0.11).setStroke()
            circle.stroke()
        }

        // 起点: the spoke the first icon sits on. 旋转角 is otherwise a number.
        let radians = config.rotation * .pi / 180
        let head = CGPoint(x: pivot.x + config.radius * sin(radians),
                           y: pivot.y - config.radius * cos(radians))
        let spoke = UIBezierPath()
        spoke.move(to: pivot)
        spoke.addLine(to: head)
        spoke.lineWidth = 1
        UIColor.white.withAlphaComponent(0.26).setStroke()
        spoke.stroke()

        context.setFillColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        context.fillEllipse(in: CGRect(x: pivot.x - 3, y: pivot.y - 3, width: 6, height: 6))
    }
}
