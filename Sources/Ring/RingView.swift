//
//  RingView.swift — Aevon, the carrier shape itself.
//
//  What it draws: N app icons sitting on the rings described by RingModel.
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
//  shadow fields exist for exactly that), and a per-icon stagger cannot be
//  expressed as one UIView animation anyway.
//
//  0.0.41 — 圆盘 only, many rings, and two gestures fewer.
//
//  The 回收站 (drag an icon to the middle to delete) is gone: it was reachable
//  only by dragging an icon *off* the shape, which is also how the shape is
//  rotated, and the operator never used it. Deleting an app belongs to
//  应用 → 编辑应用, where the list is visible while it happens. 尾角定形 went
//  with 任意角度, so the pan has exactly one meaning now: turn the disc.
//
//  Gestures (all local to the ring, all reversible):
//    · tap icon         launch / pick
//    · slide across     highlight follows the finger, release opens it
//    · long-press icon  收藏 / 取消收藏 (`Star`)
//    · drag empty arc   rotate the whole shape
//

import Foundation
import UIKit

final class RingView: UIView {

    // MARK: Callbacks — the host decides what a gesture *means*

    var onPick: ((RingApp) -> Void)?
    /// 收藏: long-press toggled `Star` for this app.
    var onPin: ((RingApp) -> Void)?
    /// 拖拽改变了旋转角。The host persists it.
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
    private var panning = false
    private var panAnchorAngle: CGFloat = 0
    private var panStartRotation: CGFloat = 0

    // MARK: 0.0.39 — 手指滑过图标 (母本 `_selected` + `fingerLocation`)

    /// `RingEnv._selected`. The icon under the finger, or -1. The master keeps
    /// exactly this one index; the highlight is not a per-view state, because
    /// two highlighted icons would be two answers to "which one will open".
    private var hoverIndex = -1
    /// `RingEnv._translationPadding`, applied to the *radius* rather than to the
    /// distance travelled.
    ///
    /// 0.0.39 measured travel and Aevon(38) says the highlight never followed a
    /// finger. The reason is structural: a pan's `.began` is delivered only after
    /// ~10 pt of slop, so `hoverStart` was already 10 pt from where the finger
    /// went down, and the very next frame crossed the threshold — the highlight
    /// lived for one frame and the shape started turning under it.
    ///
    /// A slide across the icons is a *tangential* move: the distance to the pivot
    /// barely changes. Leaving the band — toward the centre, or out past the
    /// icons — is a *radial* move. One number separates the two, and it is the
    /// number the master keeps (`_translationPadding`).
    private let dragThreshold: CGFloat = 10
    /// The touch is still in the pick phase (no drag has started yet).
    private var hovering = false
    /// Distance from the pivot when the touch went down.
    private var hoverRadius: CGFloat = 0
    /// A tap that arrives right after a hover picked an icon must not open a
    /// second app. The two recognisers see the same touch and neither is
    /// cancelled by the other, so the pick owns the next third of a second.
    private var suppressTapUntil: CFTimeInterval = 0

    /// How much the icon under the finger grows. The master's own recording
    /// (`证据/stheno图标动画.GIF`) shows the picked icon clearly larger than its
    /// neighbours with a light rim around it; 1.2× is what that reads as at
    /// 44 pt, and it is small enough that the neighbours keep their slots.
    private let hoverScale: CGFloat = 1.2

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
        // A highlight index that outlives its icons points at whatever is
        // rebuilt into that slot next — one icon permanently lit for no reason.
        hoverIndex = -1
        hovering = false

        guard !apps.isEmpty else {
            iconCount = 0
            return
        }

        iconCount = apps.count
        slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        bornAt = Array(repeating: 0, count: iconCount)
        logLayout()

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

    /// The one line that makes "it shows eight of my nine icons" answerable
    /// from the log instead of from a screenshot: how many rings the list
    /// needed and what each of them holds. 0.0.38-0.0.40 logged a 让步
    /// (`capacity fit`) because the shape was arguing with the list; there is
    /// nothing to concede now, only a shape to describe.
    private func logLayout() {
        let counts = config.distribution(for: iconCount)
        var body = ""
        for (ring, n) in counts.enumerated() {
            body += (ring == 0 ? "" : "/") + String(n)
        }
        Log.write("ring: ring layout " + String(iconCount) + " icons -> "
                  + String(counts.count) + " ring(s) " + body)
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
        hoverIndex = -1
        hovering = false
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
        // Each ring grows from its own radius, so ring 2 sweeps out further
        // rather than starting where ring 1 ended.
        let side = Swift.max(10, config.iconWidth * (0.55 + 0.45 * p))
        let now = CACurrentMediaTime()

        for (index, view) in iconViews.enumerated() {
            let slot = slots[index]
            let radius = slot.radius * (0.58 + 0.42 * p)
            let angle = slot.angle * .pi / 180
            let center = CGPoint(x: pivot.x + radius * sin(angle),
                                 y: pivot.y - radius * cos(angle))

            // 母本第 2、3 条: an icon exists once the sweep has passed it. The
            // cue is the icon's own place in the list, which is also its ring —
            // the inner circle fills first and the next one follows it out.
            let shown = p >= 0.999 || p >= slot.fraction * 0.92
            if shown {
                if bornAt[index] == 0 { bornAt[index] = now }
            } else {
                bornAt[index] = 0
            }

            view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            view.layer.cornerRadius = side * 0.2237
            view.center = center

            guard shown else {
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
                continue
            }

            // Per-icon pop: 0.16 s from the moment it is reached.
            let age = now - bornAt[index]
            let k = CGFloat(Swift.min(1, Swift.max(0, age / 0.16)))
            let pop = 0.34 + 0.66 * easeOut(k)
            // 手指滑过的那一个再放大一点 (母本 `_selected`). Kept inside the
            // same assignment as `pop` on purpose: two writes to `transform` in
            // one frame means one of them wins at random.
            let scale = index == hoverIndex ? pop * hoverScale : pop
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
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
        // Both the ring radii and the icons per ring are functions of the
        // config, so a change can leave `slots` and `iconViews` with different
        // counts — and the guard in placeIcons would then freeze every icon
        // where it stands.
        config = newConfig
        if slots.count != iconViews.count || apps.count != iconViews.count {
            rebuild(config: newConfig)
            return
        }
        slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        if bornAt.count != iconCount {
            bornAt = Array(repeating: 0, count: iconCount)
        }
        placeIcons(progress: progress)
    }

    /// Re-applies a configuration that changes the layout. Rebuilding is
    /// correct here: sliding icons from one ring to another looks like a
    /// glitch, while a fresh sweep looks like the shape changed — which it did.
    func rebuild(config newConfig: RingConfig, apps newApps: [RingApp]? = nil) {
        link?.invalidate()
        link = nil
        config = newConfig
        if let newApps = newApps { apps = newApps }
        progress = 0
        build()
        appear()
    }

    /// 收藏 之后换一批图标，但不重播扫掠。母本的 `_pinSpeed` 说的就是这段
    /// 重排的时长：图标就地滑到新位置，而不是整个圆盘重新长一遍。
    ///
    /// The icons are explicitly marked as *already born* before the last
    /// `placeIcons` call. Without that they are still at scale 0.2 / alpha 0
    /// waiting for a display link that only exists during a sweep — the ring
    /// would come back from a 收藏 completely blank.
    func reload(apps newApps: [RingApp]) {
        link?.invalidate()
        link = nil

        apps = newApps
        let count = newApps.count
        let keepsViews = count == iconCount && count > 0
        // The selection does not survive a shorter list: index 5 of eight is a
        // different app than index 5 of six, and a highlight that lands on the
        // wrong icon after a 收藏 is worse than no highlight.
        if !keepsViews || hoverIndex >= count { hoverIndex = -1 }

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

    // MARK: Hit testing

    /// Claim the icons and the ring bands, nothing else. In the floating window
    /// empty space must fall through to the home screen — a full-screen view
    /// that swallows every tap is worse than no ring at all.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        for view in iconViews where view.frame.insetBy(dx: -6, dy: -6).contains(point) {
            return self
        }
        guard iconCount > 0, onRing(point) else { return nil }
        return self
    }

    /// True when the point sits on one of the bands the icons live on. Every
    /// ring counts, not just the inner one: a touch on ring 2 is a touch on the
    /// shape, and 0.0.41 is the first version where ring 2 exists.
    private func onRing(_ point: CGPoint) -> Bool {
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let distance = sqrt(dx * dx + dy * dy)
        let band = Swift.max(config.iconWidth, 22)
        for slot in slots where abs(distance - slot.radius) < band {
            return true
        }
        return false
    }

    // MARK: Input

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !iconViews.isEmpty, !apps.isEmpty else { return }
        // A hover that just opened something consumed this same touch. Without
        // this the pick fires twice: once from the pan's `.ended`, once from the
        // tap that the pan never cancels.
        guard CACurrentMediaTime() >= suppressTapUntil else { return }
        let point = gesture.location(in: self)

        for (index, view) in iconViews.enumerated() {
            guard view.alpha > 0.3, view.frame.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            pick(index: index)
            return
        }

        // Not an icon: the host may close the ring. Doing it here would leave
        // the host's `expanded` flag lying.
        onBackgroundTap?()
    }

    /// One place that opens an icon, so a tap and a slide-to-pick can never
    /// disagree about the haptic or the pop — and cannot open two apps.
    ///
    /// The gate lives *here* rather than in the pan's `.ended`: for a touch that
    /// never travelled, the tap recogniser and the pan recogniser both fire, and
    /// UIKit does not promise which one runs first. Guarding at the entry point
    /// makes the order irrelevant; guarding at either caller only protects
    /// against the order that was tested.
    private func pick(index: Int) {
        guard index >= 0, index < iconViews.count, !apps.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard now >= suppressTapUntil else { return }
        suppressTapUntil = now + 0.35
        let view = iconViews[index]
        UIView.animate(withDuration: 0.12, animations: {
            let base = index == self.hoverIndex ? self.hoverScale : 1
            view.transform = CGAffineTransform(scaleX: base * 1.14, y: base * 1.14)
        }, completion: { _ in
            UIView.animate(withDuration: 0.2) { view.transform = .identity }
        })
        haptic(intensity: config.intensity)
        // 0.0.40 — the press is allowed to be seen. `open()` collapses the ring
        // immediately, and the collapse's own display link rewrites every icon's
        // transform on every frame, which erased the 0.12 s pop before it drew a
        // single frame. Aevon(38): 「只有圆环展开式动画，没有其他任何动画」.
        // 90 ms is shorter than a blink at arm's length and long enough for the
        // scale-up plus the rim to land.
        let app = apps[index % apps.count]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            self?.onPick?(app)
        }
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
            // A touch that lands on an icon is picking; one that lands on the
            // empty arc is turning the shape. Only the first can become a
            // hover, because only the first has anything to hover.
            panning = false
            hoverRadius = radial(point)
            hovering = iconIndex(at: point) >= 0
            if hovering {
                updateHover(at: point)
            } else {
                beginPan(at: point)
            }
        case .changed:
            if hovering {
                // Tangential movement keeps the pick alive however far the finger
                // slides; a radial move hands the touch to the drag path. Written
                // as a radius test, not a travel test — see `dragThreshold`.
                if abs(radial(point) - hoverRadius) <= dragThreshold {
                    updateHover(at: point)
                    return
                }
                hovering = false
                clearHover()
                beginPan(at: point)
                return
            }
            if panning { turnPan(to: point) }
        case .ended, .cancelled, .failed:
            if hovering {
                hovering = false
                let picked = hoverIndex
                let committed = gesture.state == .ended
                clearHover()
                // `.cancelled` and `.failed` are the system taking the touch
                // away (a call, a gesture losing to another). Opening an app on
                // those is opening an app nobody asked for.
                if committed, picked >= 0, picked < apps.count {
                    pick(index: picked)
                }
                return
            }
            endPan()
        default:
            break
        }
    }

    /// `_selected` — the nearest icon the finger is *on*, or -1.
    private func updateHover(at point: CGPoint) {
        guard progress >= 0.999 else { return }
        let target = iconIndex(at: point)
        guard target != hoverIndex else { return }
        hoverIndex = target
        applyHover()
        // One line per icon crossed. This is the only evidence in the log that a
        // slide across the shape is being read at all — without it "the highlight
        // does not follow my finger" is indistinguishable from "the ring never saw
        // the touch".
        if target >= 0 {
            Log.write("ring: hover icon " + String(target) + " of "
                      + String(iconViews.count))
            // One soft click per icon crossed, not per frame: this function
            // already returned early when the index did not change.
            haptic(intensity: Swift.max(0.3, config.intensity * 0.6))
        }
    }

    /// Which icon the finger is on, or -1. Distance to the centre rather than a
    /// frame test: the icons sit on arcs, so a rectangle test picks a neighbour
    /// whenever the finger passes between two of them. The reach is a little
    /// wider than half an icon so sliding along an arc never falls into a dead
    /// gap and blanks the highlight between every pair.
    private func iconIndex(at point: CGPoint) -> Int {
        var best = -1
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, view) in iconViews.enumerated() where view.alpha > 0.3 {
            let dx = view.center.x - point.x
            let dy = view.center.y - point.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= config.iconWidth * 0.85 ? best : -1
    }

    /// Distance from the pivot — the one coordinate a slide along an arc leaves
    /// alone.
    private func radial(_ point: CGPoint) -> CGFloat {
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        return sqrt(dx * dx + dy * dy)
    }

    private func clearHover() {
        guard hoverIndex != -1 else { return }
        hoverIndex = -1
        applyHover()
    }

    /// Puts the current `hoverIndex` onto the icons. Called from here and from
    /// `placeIcons`, which owns `transform` during the sweep — two writers of
    /// one property is how a highlight ends up one icon behind the finger.
    ///
    /// The rim is a layer border rather than a shadow: the icons clip to their
    /// squircle (`masksToBounds`), so a shadow would be clipped away entirely
    /// and the operator would see the icon grow with no rim at all.
    private func applyHover() {
        for (index, view) in iconViews.enumerated() {
            let on = index == hoverIndex
            view.layer.borderWidth = on ? 2 : 0
            view.layer.borderColor = on ? UIColor.white.cgColor : UIColor.clear.cgColor
        }
        placeIcons(progress: progress)
    }

    private func beginPan(at point: CGPoint) {
        panAnchorAngle = angleOf(point)
        panStartRotation = config.rotation
        panning = true
    }

    /// One meaning: turn the disc. 0.0.41 removed the two that used to share
    /// this path — dragging an icon (it only ever ended in the 回收站) and
    /// dragging the last icon to set 尾角 (that shape is gone).
    private func turnPan(to point: CGPoint) {
        var updated = config
        updated.rotation = normalised(panStartRotation + (angleOf(point) - panAnchorAngle))
        config = updated
        slots = ringSlots(pivot: pivot, count: iconCount, config: config)
        placeIcons(progress: progress)
    }

    private func endPan() {
        guard panning else { return }
        panning = false
        onConfigChange?(config)
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
