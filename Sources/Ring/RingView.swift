//
//  RingView.swift — Aevon, the carrier shape itself.
//
//  What it draws: N app icons sitting on the arc described by RingModel.
//  Nothing else. No window, no gesture hijack of its own, no app launching
//  policy — this view is deliberately a leaf, so the settings preview and the
//  home-screen host can both run it unchanged.
//
//  The animation is the master's model, not a guess (逆向 P4，四级证据):
//
//    1  `_angleScale` 是展开进度 0→1，不是缩放
//    2  可见弧段 = 旋转角 → 尾角，按进度扫过
//    3  每个图标按自身角度决定出场时刻 → 依次弹出
//    4  radius / iconWidth 随进度同步插值 → 从边缘长出来
//
//  So there is one number to animate: `progress`. Everything else — which
//  icons exist yet, how far out they sit, how big they are — is a function of
//  it. That is why this file has a display link instead of a dozen nested
//  UIView animations: the master interpolates per frame (its 16 `xxxLast`
//  shadow fields exist for exactly that), and a per-icon stagger driven by
//  angle cannot be expressed as one UIView animation anyway.
//
//  Gestures (all local to the ring, all reversible):
//    · tap icon         launch / pick
//    · drag icon        move it; drop near the pivot to删除 (回收站)
//    · long-press icon  收藏 / 取消收藏 (`Star`)
//    · drag empty arc   rotate the whole shape
//    · drag last icon   任意 shape only: set the tail (`RTSIZ` 拖拽定形)
//

import Foundation
import UIKit

final class RingView: UIView {

    // MARK: Callbacks — the host decides what a gesture *means*

    var onPick: ((RingApp) -> Void)?
    /// 回收站: the operator dragged an icon into the middle.
    var onRemove: ((RingApp) -> Void)?
    /// 收藏: long-press toggled `Star` for this app.
    var onPin: ((RingApp) -> Void)?
    /// 拖拽改变了几何（旋转角，或「任意」形状的尾角）。The host persists it.
    /// Whole config rather than just the angle: dragging the last icon in the
    /// 任意 shape changes the tail, and a callback that only carries rotation
    /// would silently drop that.
    var onConfigChange: ((RingConfig) -> Void)?
    /// A tap that hit the ring but not an icon. The host collapses.
    var onBackgroundTap: (() -> Void)?

    // MARK: State

    private(set) var config: RingConfig
    private var apps: [RingApp]
    private var pivot: CGPoint

    private var iconViews: [UIView] = []
    private var slots: [RingSlot] = []
    private var bornAt: [CFTimeInterval] = []
    private var iconCount = 0

    // Animation
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var duration: TimeInterval = 0.52
    private var progress: CGFloat = 0
    private var expanding = true
    private var collapseCompletion: (() -> Void)?

    // Gesture bookkeeping
    private enum PanMode { case none, rotate, tail, icon }
    private var panMode: PanMode = .none
    private var panIcon = -1
    private var panAnchorAngle: CGFloat = 0
    private var panStartRotation: CGFloat = 0
    private var panStartTail: CGFloat = 0
    private var panStartCenter: CGPoint = .zero
    private var trashActive = false
    private var trashView: UIView?
    private var isDragging = false

    // MARK: Init

    init(frame: CGRect, config: RingConfig, apps: [RingApp], pivot: CGPoint) {
        self.config = config
        self.apps = apps
        self.pivot = pivot
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        // Long press is how the master's `Star` works: hold an icon, it becomes
        // pinned. It has to lose to the pan, otherwise a slow drag pins apps.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.42
        press.allowableMovement = 12
        press.delegate = self
        addGestureRecognizer(press)

        build()
    }

    required init?(coder: NSCoder) {
        fatalError("RingView is created in code only")
    }

    deinit {
        link?.invalidate()
    }

    // MARK: Building

    private func build() {
        for view in iconViews { view.removeFromSuperview() }
        iconViews.removeAll()
        slots.removeAll()
        bornAt.removeAll()

        guard !apps.isEmpty else {
            iconCount = 0
            return
        }

        iconCount = Swift.min(apps.count, config.capacity)
        slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        bornAt = Array(repeating: 0, count: iconCount)

        for (index, _) in slots.enumerated() {
            let icon = makeIconView(apps[index % apps.count])
            icon.tag = index
            icon.center = pivot
            icon.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            icon.alpha = 0
            addSubview(icon)
            iconViews.append(icon)
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

    // MARK: Animation — one number drives everything

    private func speedFactor() -> Double {
        return Double(Swift.max(0.2, Swift.min(2, config.speed)))
    }

    func appear() {
        guard !iconViews.isEmpty else { return }
        expanding = true
        duration = 0.58 / speedFactor()
        begin()
    }

    /// Re-runs the sweep without rebuilding the icons, so a parameter change is
    /// visible immediately.
    func replay() {
        for (index, view) in iconViews.enumerated() {
            view.layer.removeAllAnimations()
            view.center = pivot
            view.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            view.alpha = 0
            if index < bornAt.count { bornAt[index] = 0 }
        }
        progress = 0
        appear()
    }

    /// 收回: same sweep backwards. The tail icon leaves first, because that is
    /// the reverse of the order in which it arrived.
    func disappear(completion: (() -> Void)? = nil) {
        guard !iconViews.isEmpty else {
            completion?()
            return
        }
        expanding = false
        collapseCompletion = completion
        duration = 0.34 / speedFactor()
        begin()
    }

    private func begin() {
        link?.invalidate()
        startTime = CACurrentMediaTime()
        let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
        display.add(to: .main, forMode: .common)
        link = display
        tick(display)
    }

    @objc private func tick(_ display: CADisplayLink) {
        let elapsed = display.timestamp - startTime
        let t = Swift.min(1, Swift.max(0, CGFloat(elapsed / duration)))
        let eased = easing(t)
        progress = expanding ? eased : 1 - eased
        placeIcons(progress: progress)

        if t >= 1 {
            display.invalidate()
            link = nil
            progress = expanding ? 1 : 0
            placeIcons(progress: progress)
            if !expanding {
                let done = collapseCompletion
                collapseCompletion = nil
                done?()
            }
        }
    }

    /// A critically-damped-ish curve that honours 阻尼系数: 1.0 is a plain
    /// ease-out, low values overshoot and settle. 母本把 dampingFraction 交给
    /// 同一个 spring 入口，这里用闭式解，免掉一层 CA 动画的时序不可控。
    private func easing(_ t: CGFloat) -> CGFloat {
        guard config.customSpring else {
            // 动画弹性 off: plain ease-out, no overshoot at all.
            return 1 - powC(1 - t, 3)
        }
        // Base curve plus a decaying overshoot term. Written this way instead
        // of a damped oscillator so that t = 1 lands on exactly 1 — a spring
        // formula that ends at 0.998 leaves every icon a pixel off its slot.
        let zeta = Swift.max(0.18, Swift.min(1, config.damping))
        let base = 1 - powC(1 - t, 2.2)
        let bounce = (1 - zeta) * sin(t * .pi) * powC(1 - t, 1.4) * 0.55
        return base + bounce
    }

    /// The one function that puts every icon where it belongs at a given
    /// expansion progress. Called every frame; cheap by construction.
    private func placeIcons(progress p: CGFloat) {
        guard !iconViews.isEmpty, slots.count == iconViews.count else { return }

        // 母本第 4 条: radius / iconWidth 随进度插值. 0.58 is the starting
        // fraction: the arc is already visible, it just grows out of the pivot.
        let radius = config.radius * (0.58 + 0.42 * p)
        let side = Swift.max(10, config.iconWidth * (0.55 + 0.45 * p))
        let arc = config.arc(progress: p)
        let now = CACurrentMediaTime()

        for (index, view) in iconViews.enumerated() {
            let slot = slots[index]
            let angle = slot.angle * .pi / 180
            let center = CGPoint(x: pivot.x + radius * sin(angle),
                                 y: pivot.y - radius * cos(angle))

            // 母本第 2、3 条: an icon exists once the sweep has passed it.
            let shown = p >= 0.999 || arc.reached(slot.angle)
            if shown {
                if bornAt[index] == 0 { bornAt[index] = now }
            } else {
                bornAt[index] = 0
            }

            if panMode == .icon && panIcon == index && isDragging {
                // A dragged icon is not on its slot; do not fight the finger.
                view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                view.layer.cornerRadius = side * 0.2237
                continue
            }

            view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            view.layer.cornerRadius = side * 0.2237
            view.center = center

            guard shown else {
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
                continue
            }

            // Per-icon pop: 0.16 s from the moment its angle is reached.
            let age = now - bornAt[index]
            let k = CGFloat(Swift.min(1, Swift.max(0, age / 0.16)))
            let pop = 0.34 + 0.66 * easeOut(k)
            view.transform = CGAffineTransform(scaleX: pop, y: pop)
            view.alpha = Swift.min(1, k * 1.6)
        }
    }

    private func easeOut(_ t: CGFloat) -> CGFloat {
        return 1 - powC(1 - t, 3)
    }

    /// CGFloat 上的幂运算走 Double。CoreGraphics 大体上提供 CGFloat 重载，
    /// 但"大体上"在 Swift 里等于一次构建失败；显式转换只要一行。
    private func powC(_ base: CGFloat, _ exponent: Double) -> CGFloat {
        return CGFloat(Foundation.pow(Double(base), exponent))
    }

    // MARK: Geometry updates

    /// Re-applies a configuration in place. The icons are never rebuilt, so a
    /// drag or a slider stays at 60 fps.
    func update(config newConfig: RingConfig) {
        // Capacity is a function of the config: change the radius and the ring
        // holds a different number of icons. Updating in place would leave
        // `slots` and `iconViews` with different counts, and the guard in
        // placeIcons would then freeze every icon where it stands.
        let count = Swift.min(apps.count, newConfig.capacity)
        if count != iconCount {
            rebuild(config: newConfig)
            return
        }
        config = newConfig
        slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        if bornAt.count != iconCount {
            bornAt = Array(repeating: 0, count: iconCount)
        }
        placeIcons(progress: progress)
    }

    /// Re-applies a configuration that changes the icon *count* (radius, icon
    /// width and shape all do). Rebuilding is correct here: sliding eight icons
    /// into six slots looks like a glitch, while a fresh sweep looks like the
    /// shape changed — which it did.
    func rebuild(config newConfig: RingConfig, apps newApps: [RingApp]? = nil) {
        link?.invalidate()
        link = nil
        config = newConfig
        if let newApps = newApps { apps = newApps }
        progress = 0
        build()
        appear()
    }

    /// 收藏 / 回收站 之后换一批图标，但不重播扫掠。母本的 `_pinSpeed` 说的就是
    /// 这段重排的时长：图标就地滑到新位置，而不是整个圆盘重新长一遍。
    ///
    /// The icons are explicitly marked as *already born* before the last
    /// `placeIcons` call. Without that they are still at scale 0.2 / alpha 0
    /// waiting for a display link that only exists during a sweep — the ring
    /// would come back from a 收藏 completely blank.
    func reload(apps newApps: [RingApp]) {
        link?.invalidate()
        link = nil

        let count = Swift.min(newApps.count, config.capacity)
        let keepsViews = count == iconCount && count > 0
        apps = newApps

        if keepsViews {
            // Same number of icons: swap the artwork and let them glide, which
            // is what a re-sort looks like. Rebuilding here would blink.
            for (index, view) in iconViews.enumerated() {
                (view.subviews.first as? UIImageView)?.image = apps[index % apps.count].icon
            }
            slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        } else {
            progress = 0
            build()
        }

        bornAt = Array(repeating: CACurrentMediaTime() - 1, count: iconCount)
        progress = 1
        UIView.animate(withDuration: 0.24 / speedFactor(), delay: 0,
                       usingSpringWithDamping: 0.82, initialSpringVelocity: 0.2,
                       options: [.beginFromCurrentState]) {
            self.placeIcons(progress: 1)
        }
    }

    /// The pivot follows the grip when the screen rotates or the host window
    /// changes size. Re-seating is instant: nothing is animating at that point.
    func movePivot(_ point: CGPoint) {
        pivot = point
        slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        placeIcons(progress: progress)
    }

    /// 回收站/收藏 之后，图标要消失得有个交代。
    func detach(appAt index: Int, completion: (() -> Void)? = nil) {
        guard index >= 0, index < iconViews.count else {
            completion?()
            return
        }
        let view = iconViews[index]
        UIView.animate(withDuration: 0.18, animations: {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            view.center = self.pivot
        }, completion: { _ in
            view.removeFromSuperview()
            completion?()
        })
    }

    // MARK: Hit testing

    /// Claim the icons and the arc band, nothing else. In the floating window
    /// empty space must fall through to the home screen — a full-screen view
    /// that swallows every tap is worse than no ring at all.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        for view in iconViews where view.frame.insetBy(dx: -6, dy: -6).contains(point) {
            return self
        }
        guard iconCount > 0, isVisible(point) else { return nil }
        return self
    }

    /// True when the point sits in the annulus the icons live on, within the
    /// part of the sweep that has already appeared.
    private func isVisible(_ point: CGPoint) -> Bool {
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let distance = sqrt(dx * dx + dy * dy)
        let band = Swift.max(config.iconWidth, 22)
        guard distance > config.radius - band, distance < config.radius + band else {
            return false
        }
        let angle = atan2(dx, -dy) * 180 / .pi
        return progress >= 0.999 || config.arc(progress: progress).reached(angle)
    }

    // MARK: Input

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !iconViews.isEmpty, !apps.isEmpty else { return }
        let point = gesture.location(in: self)

        for (index, view) in iconViews.enumerated() {
            guard view.alpha > 0.3, view.frame.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            let app = apps[index % apps.count]
            UIView.animate(withDuration: 0.12, animations: {
                view.transform = CGAffineTransform(scaleX: 1.14, y: 1.14)
            }, completion: { _ in
                UIView.animate(withDuration: 0.2) { view.transform = .identity }
            })
            haptic(intensity: config.intensity)
            onPick?(app)
            return
        }

        // Not an icon: the host may close the ring. Doing it here would leave
        // the host's `expanded` flag lying.
        onBackgroundTap?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        // 母本的 Star 就是这个开关：关掉之后长按不再收藏，其余手感不变。
        guard config.star, gesture.state == .began, !iconViews.isEmpty else { return }
        let point = gesture.location(in: self)
        for (index, view) in iconViews.enumerated()
        where view.alpha > 0.5 && view.frame.insetBy(dx: -4, dy: -4).contains(point) {
            haptic(intensity: Swift.max(0.35, config.intensity * 0.8))
            onPin?(apps[index % apps.count])
            return
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !iconViews.isEmpty else { return }
        let point = gesture.location(in: self)

        switch gesture.state {
        case .began:
            beginPan(at: point)
        case .changed:
            continuePan(to: point)
        case .ended, .cancelled, .failed:
            endPan()
        default:
            break
        }
    }

    private func beginPan(at point: CGPoint) {
        let angle = angleOf(point)
        panStartRotation = config.rotation
        panStartTail = config.tail
        panAnchorAngle = angle
        panMode = .rotate
        panIcon = -1

        // An icon under the finger wins over "rotate the shape".
        for (index, view) in iconViews.enumerated()
        where view.alpha > 0.4 && view.frame.insetBy(dx: -8, dy: -8).contains(point) {
            panMode = .icon
            panIcon = index
            panStartCenter = view.center
            isDragging = true
            // 任意形状: 拖最后一个图标 = 定形（母本 RTSIZ 的原文）
            if config.shape == .free && index == iconViews.count - 1 {
                panMode = .tail
                isDragging = false
            }
            return
        }
    }

    private func continuePan(to point: CGPoint) {
        switch panMode {
        case .icon:
            guard panIcon >= 0, panIcon < iconViews.count else { return }
            iconViews[panIcon].center = point
            updateTrash(at: point)

        case .tail:
            var updated = config
            var value = updated.tail + (angleOf(point) - panAnchorAngle)
            value = Swift.max(updated.rotation + 12, Swift.min(updated.rotation + 360, value))
            panAnchorAngle = angleOf(point)
            updated.tail = value
            config = updated
            slots = ringSlots(pivot: pivot, count: iconCount, config: config)
            placeIcons(progress: progress)

        case .rotate:
            var updated = config
            updated.rotation = normalised(panStartRotation + (angleOf(point) - panAnchorAngle))
            config = updated
            slots = ringSlots(pivot: pivot, count: iconCount, config: config)
            placeIcons(progress: progress)

        case .none:
            break
        }
    }

    private func endPan() {
        let mode = panMode
        panMode = .none
        isDragging = false

        if mode == .icon, panIcon >= 0, panIcon < iconViews.count {
            let view = iconViews[panIcon]
            if trashActive {
                let app = apps[panIcon % apps.count]
                hideTrash()
                detach(appAt: panIcon)
                haptic(intensity: 1.0)
                onRemove?(app)
                panIcon = -1
                return
            }
            // Snap back onto its own slot.
            if panIcon < slots.count {
                let slot = slots[panIcon]
                let angle = slot.angle * .pi / 180
                let target = CGPoint(x: pivot.x + config.radius * sin(angle),
                                     y: pivot.y - config.radius * cos(angle))
                UIView.animate(withDuration: 0.22, delay: 0,
                               usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4,
                               options: [.beginFromCurrentState], animations: {
                    view.center = target
                }, completion: nil)
            }
        }

        if mode == .rotate || mode == .tail {
            onConfigChange?(config)
        }

        hideTrash()
        panIcon = -1
    }

    // MARK: 回收站

    /// Dragging an icon to the middle deletes it, which is the only way to
    /// remove an app without opening Settings. The target is deliberate: it is
    /// where the ring came from, so the icon goes back to the pivot it grew out
    /// of.
    private func updateTrash(at point: CGPoint) {
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let distance = sqrt(dx * dx + dy * dy)
        let inside = distance < Swift.max(44, config.radius * 0.45)
        if inside == trashActive { return }
        trashActive = inside
        if inside {
            showTrash()
            haptic(intensity: 0.5)
        } else {
            hideTrash()
        }
    }

    private func showTrash() {
        if trashView == nil {
            let side: CGFloat = 52
            let view = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
            view.center = pivot
            view.backgroundColor = UIColor.systemRed.withAlphaComponent(0.92)
            view.layer.cornerRadius = side / 2
            view.layer.cornerCurve = .continuous
            view.isUserInteractionEnabled = false

            let glyph = UIImageView(frame: view.bounds.insetBy(dx: 14, dy: 14))
            glyph.contentMode = .scaleAspectFit
            glyph.tintColor = .white
            glyph.image = UIImage(systemName: "trash")
            glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(glyph)

            addSubview(view)
            trashView = view
        }
        trashView?.alpha = 1
        trashView?.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.16) {
            self.trashView?.transform = .identity
        }
    }

    private func hideTrash() {
        guard let view = trashView else { return }
        trashView = nil
        UIView.animate(withDuration: 0.14, animations: {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        }, completion: { _ in
            view.removeFromSuperview()
        })
    }

    // MARK: Helpers

    private func angleOf(_ point: CGPoint) -> CGFloat {
        return atan2(point.x - pivot.x, pivot.y - point.y) * 180 / .pi
    }

    /// Keeps 旋转角 in (-180, 180], the same range the slider writes.
    private func normalised(_ degrees: CGFloat) -> CGFloat {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// 母本用私有 `impactOccurredWithIntensity:`。自从 iOS 13 起公有 API
    /// 就是同一个入口（同名、同参数），所以这里不做 IMP 强转 —— 在 arm64e 上
    /// 把方法 IMP 当 C 函数指针调用，是拿桌面稳定性换一个已经存在的功能。
    private func haptic(intensity: CGFloat) {
        guard config.haptic else { return }
        let value = Swift.max(0.05, Swift.min(1, intensity))
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: value)
    }
}

// MARK: - Gesture arbitration

extension RingView: UIGestureRecognizerDelegate {

    /// A held finger must not pin an app while it is actually dragging the
    /// ring. The direction matters: `shouldBeRequiredToFailBy` says "the press
    /// loses as soon as the pan begins", which leaves a plain hold working.
    /// `shouldRequireFailureOf` would be the opposite and would demand that the
    /// pan *fail* first — a pan that simply never begins never fails, so 收藏
    /// would stop working altogether.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        return gestureRecognizer is UILongPressGestureRecognizer
            && other is UIPanGestureRecognizer
    }
}
