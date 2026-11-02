//
//  RingView.swift — Aevon, the carrier shape itself.
//
//  What it draws: N app icons sitting on the arc described by RingModel.
//  Nothing else. No window, no gesture hijack, no app launching — this view is
//  deliberately a leaf, so it can be hosted by the settings preview today and
//  by the floating window later without a single line changing.
//
//  The animation is taken from the master's own recording
//  (证据/stheno图标动画.GIF, 522 frames @ 20 ms): the icons do not fade in on
//  their arc — they bloom *out of the pivot*, arriving from the centre while
//  scaling up, each one a few milliseconds after the previous. That is the
//  motion reproduced below: start at the pivot at 12 % scale, spring to the
//  slot, stagger 22 ms.
//

import UIKit

final class RingView: UIView {

    /// Fired when an icon is tapped. The preview uses it to show which app the
    /// ring resolved; the floating window will use it to launch.
    var onPick: ((RingApp) -> Void)?

    private(set) var config: RingConfig
    private var apps: [RingApp]
    private var pivot: CGPoint

    private var iconViews: [UIView] = []
    private var targetCenters: [CGPoint] = []
    private var iconCount = 0

    private var panAnchor: CGFloat = 0

    // MARK: Init

    init(frame: CGRect, config: RingConfig, apps: [RingApp], pivot: CGPoint) {
        self.config = config
        self.apps = apps
        self.pivot = pivot
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("RingView is created in code only")
    }

    // MARK: Building

    private func build() {
        for view in iconViews { view.removeFromSuperview() }
        iconViews.removeAll()
        targetCenters.removeAll()

        guard !apps.isEmpty else { return }

        iconCount = Swift.min(apps.count, config.capacity)
        let slots = ringSlots(pivot: pivot, count: iconCount, config: config)

        for (index, slot) in slots.enumerated() {
            let icon = makeIconView(apps[index % apps.count])
            icon.tag = index
            icon.center = pivot
            icon.transform = CGAffineTransform(scaleX: 0.12, y: 0.12)
            icon.alpha = 0
            addSubview(icon)
            iconViews.append(icon)
            targetCenters.append(slot.center)
        }
    }

    private func makeIconView(_ app: RingApp) -> UIView {
        let side = config.iconWidth
        let container = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        container.layer.cornerRadius = side * 0.2237     // iOS squircle ratio
        container.layer.cornerCurve = .continuous
        container.layer.masksToBounds = true
        container.backgroundColor = UIColor.white
        container.isUserInteractionEnabled = false

        let image = UIImageView(frame: container.bounds)
        image.image = app.icon
        image.contentMode = .scaleAspectFill
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(image)
        return container
    }

    // MARK: Animation

    /// Bloom out of the pivot. Stagger is per icon, so a 12-icon ring reads as
    /// one motion rather than twelve.
    func appear() {
        guard !iconViews.isEmpty else { return }

        // CGFloat / Double never mix implicitly: normalise the speed once.
        let speed = Double(Swift.max(0.2, Swift.min(2, config.speed)))
        let duration = 0.52 / speed
        let stagger = 0.022 / speed

        for (index, view) in iconViews.enumerated() {
            let target = targetCenters[index]
            let animator: UIViewPropertyAnimator
            if config.customSpring {
                animator = UIViewPropertyAnimator(duration: duration,
                                                  dampingRatio: Swift.max(0.15, config.damping))
            } else {
                animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut)
            }
            animator.addAnimations {
                view.center = target
                view.transform = .identity
                view.alpha = 1
            }
            animator.startAnimation(afterDelay: Double(index) * stagger)
        }

        haptic()
    }

    /// Back into the pivot. Reverse of `appear`, faster: closing should feel
    /// like letting go, not like watching the same animation backwards.
    func disappear(completion: (() -> Void)? = nil) {
        let duration = 0.30 / Double(Swift.max(0.2, Swift.min(2, config.speed)))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn], animations: {
            for view in self.iconViews {
                view.center = self.pivot
                view.transform = CGAffineTransform(scaleX: 0.12, y: 0.12)
                view.alpha = 0
            }
        }, completion: { _ in completion?() })
    }

    /// Re-runs the bloom without rebuilding the icons, so a parameter change is
    /// visible immediately.
    func replay() {
        resetToPivot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.appear()
        }
    }

    private func resetToPivot() {
        for view in iconViews {
            view.layer.removeAllAnimations()
            view.center = pivot
            view.transform = CGAffineTransform(scaleX: 0.12, y: 0.12)
            view.alpha = 0
        }
    }

    // MARK: Geometry updates (任意角度)

    /// Re-applies a configuration in place. Only the arc changes; the icons are
    /// never rebuilt, so a drag stays at 60 fps.
    func update(config newConfig: RingConfig) {
        config = newConfig
        let slots = ringSlots(pivot: pivot, count: iconCount, config: newConfig)
        for (index, view) in iconViews.enumerated() where index < slots.count {
            targetCenters[index] = slots[index].center
            view.center = slots[index].center
        }
    }

    /// Re-applies a configuration that changes the icon *count* (radius, icon
    /// width and shape all do). The old icons are removed and new ones bloom
    /// out of the pivot, which is what "the shape changed" should look like —
    /// sliding eight icons into six slots would only look like a glitch.
    func rebuild(config newConfig: RingConfig, apps newApps: [RingApp]? = nil) {
        config = newConfig
        if let newApps = newApps { apps = newApps }

        for view in iconViews { view.removeFromSuperview() }
        iconViews.removeAll()
        targetCenters.removeAll()
        iconCount = 0

        build()
        appear()
    }

    /// The pivot follows the grip when the screen rotates or the host window
    /// changes size. Re-seating is instant: nothing is animating at that point.
    func movePivot(_ point: CGPoint) {
        pivot = point
        let slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        for (index, view) in iconViews.enumerated() where index < slots.count {
            targetCenters[index] = slots[index].center
            view.center = slots[index].center
        }
    }

    /// Only the icons take touches. Everything else in this view is empty
    /// space, and in the floating window empty space has to fall through to
    /// whatever is underneath — otherwise a full-screen ring would swallow
    /// every tap on the home screen.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        for view in iconViews where view.frame.insetBy(dx: -6, dy: -6).contains(point) {
            return self
        }
        return nil
    }

    // MARK: Input

    /// Drag rotates the ring by moving the tail angle — the master's
    /// 「拖拽旋转最后一个图标」. Only meaningful for the 任意 shape, so every
    /// other shape ignores the gesture entirely instead of fighting the host.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard config.shape == .free, !iconViews.isEmpty else { return }

        let point = gesture.location(in: self)
        let angle = atan2(point.x - pivot.x, pivot.y - point.y) * 180 / .pi

        switch gesture.state {
        case .began:
            panAnchor = angle - config.tail
        case .changed:
            var updated = config
            updated.tail = angle - panAnchor
            update(config: updated)
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !iconViews.isEmpty else { return }
        let point = gesture.location(in: self)

        for (index, view) in iconViews.enumerated() where view.frame.contains(point) {
            let app = apps[index % apps.count]
            UIView.animate(withDuration: 0.12, animations: {
                view.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            }, completion: { _ in
                UIView.animate(withDuration: 0.18) { view.transform = .identity }
            })
            haptic()
            onPick?(app)
            return
        }
    }

    private func haptic() {
        guard config.haptic else { return }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: Swift.max(0.1, Swift.min(1, config.intensity)))
    }
}
