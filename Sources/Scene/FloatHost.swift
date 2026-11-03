import UIKit

/// The floating window shell.
///
/// 0.2.x already proved the two hard parts on this phone: a window built from
/// the main `UIWindowScene`, and a `hitTest` that answers nil for itself so a
/// touch that misses the card falls through to whatever is underneath.
///
/// 0.0.35 moved the gesture surface out of the card, and that part is settled: a
/// hosted scene view is a real UIView that owns its touches and forwards them to
/// the app, so recognizers on the card's own view never fired (Aevon(33)). The
/// band has to be a sibling ring *outside* the picture.
///
/// 0.0.40 is the operator's own map, and it is smaller than the master's:
///
///          ┌─────────── 顶部：不接，触摸穿透 ───────────┐
///          │                                             │
///   左侧   │   ╔═══════════════════════════════╗         │   右侧
///   拖动   │   ║        the card — the app      ║         │   拖动
///   点吸附 │   ╚═══════════════════════════════╝         │   点吸附
///          │                                             │
///          ├──────────┬─────────────────┬───────────────┤
///          │ 缩放/复位 │ 拖动移动/上滑关   │   缩放/复位    │
///          └──────────┴─────────────────┴───────────────┘
///
/// 0.0.43 — the corners resize again. 0.0.40 removed the two resize cells on
/// the honest grounds that a resize reachable only through the dead top strip
/// was no resize at all; Aevon(41) answered with the operator's own map: the
/// bottom corners are where resize belongs. A drag on a corner now scales the
/// card around its opposite corner — the shape the master's own caption
/// promises (「边角区域滑动缩放，长按重启」) — and the long press keeps its
/// geometry reset. The card's aspect never changes: the picture is one shape
/// scaled, so a resize is a height choice and the width follows.
///
/// Why the top strip is empty. 0.0.35-0.0.39 had four cells up there — 边中's
/// flick-to-close and the two top corners' resize — copied from the master's
/// `GestureIntroduction`. Both were reachable only by aiming at a band that sits
/// on top of the picture, and the operator asked for them gone. A band that
/// answers nothing is worse than no band, because it eats touches that belong to
/// the app, so the top strip is punched out of the hit area entirely instead of
/// being left as dead weight. The close gesture did not disappear with it: 边中's
/// 快速上滑 lives on the bottom band now, where the same text applies ("竖屏上下").
///
/// 吸附 changed meaning in this version. It used to be a drag that snapped to an
/// edge and a double tap that minimised. Both are gone. 吸附 is now one tap on a
/// side band: the card becomes a docked 停靠小窗 on that side, and a tap anywhere
/// on the mini's picture brings the full card back. Two taps were always the
/// wrong shape for this — the operator has to aim at a specific band twice, and
/// the way *out* of the mini was a band, not the window it had just become.
final class FloatHost: NSObject, UIGestureRecognizerDelegate {
    static let shared = FloatHost()

    /// Which part of the ring a touch landed on.
    private enum Zone {
        case left
        case right
        case bottomMiddle
        case bottomCorner
    }

    private var window: FloatWindow?
    private var card: UIView?
    private var content: UIView?
    private var close: UIControl?
    private var grip: GripView?
    /// The transparent shield a docked card puts over its own picture. It exists
    /// for one reason: while the card is mini, a tap on the picture has to mean
    /// "give me the window back" instead of reaching the app.
    private var shield: UIControl?
    private var onClose: ((String) -> Void)?
    /// The scene's own size. Every resize is this shape, scaled — the card never
    /// gets an aspect the picture does not have.
    private var natural: CGSize = .zero

    private var pan: UIPanGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    private var zone: Zone = .left
    private var panStep: CGPoint = .zero
    /// 0.0.43 — the frame a corner resize started from, and which corner the
    /// finger is on. The opposite corner is the anchor that never moves.
    private var resizeStart: CGRect?
    private var resizeFromLeft = false
    /// The frame to come back to. Non-nil is the only definition of "docked".
    private var miniFrame: CGRect?

    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 480
    private let corner: CGFloat = 12
    private let edge: CGFloat = 2
    private let margin: CGFloat = 8
    private let minWidth: CGFloat = 140
    private let closeSize: CGFloat = 30
    /// `GestureBorderWidth` in her settings, described there as 减小浮窗手势宽度.
    ///
    /// 0.0.35 shipped 40 pt. 0.0.40 answered "the band is in the way" with 32,
    /// and Aevon(39) answered that with 「移除热区可见性后，四周的手势失效」:
    /// the painted band was the only thing saying where the 32 pt edge was, and
    /// once it was gone a thumb landing 34 pt out was touching the desktop.
    /// 40 is the master's own default and it is back; the visible band stays
    /// gone, because the problem was never that it was visible.
    private let band: CGFloat = 40
    /// 0.0.41 — 6 pt of tolerance on the *outside*. 0.0.37's Aevon(35) shows a
    /// thumb landing at x=390 on a card whose right edge was 375: 15 pt outside,
    /// comfortably inside a 40 pt band. The same thumb on 0.0.40's 32 pt band
    /// touched nothing. `band` is what the zone map is written in; `slack` is
    /// how far past it a touch still counts, and the two are added once, here,
    /// so the hit area and the zone arithmetic can never drift apart.
    private let slack: CGFloat = 6
    /// The ring's real half-width: the band plus its tolerance.
    private var reach: CGFloat { band + slack }
    /// 快速上滑: a flick, not a drag. 900 pt/s is above a deliberate slow drag and
    /// below the speed a thumb reaches when it is actually swiping away.
    private let flick: CGFloat = 900
    private let pressDelay: TimeInterval = 0.4

    var level: CGFloat { window?.windowLevel.rawValue ?? 0 }

    /// Answers a host only when the window is really up and really holds the
    /// view. A nil answer means "activate nothing": a presenter whose view is
    /// not in a window is 0.0.20's black screen, and that is not worth one more
    /// phone.
    static func show(_ view: UIView, onClose: @escaping (String) -> Void) -> FloatHost? {
        let host = shared
        host.teardown()
        host.onClose = onClose
        guard let window = host.makeWindow() else { return nil }

        window.backgroundColor = .clear
        window.isOpaque = false
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 100)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.isHidden = false
        guard let root = window.rootViewController?.view else {
            window.isHidden = true
            return nil
        }

        // A card that shows a phone is a card shaped like a phone: the width is
        // chosen, the height follows the picture's own aspect (0.0.24's fixed
        // 320x480 card is what put black bars at the sides).
        let natural = view.bounds.size
        let source = (natural.width > 16 && natural.height > 16) ? natural : window.bounds.size
        let plan = host.plan(in: window.bounds, source: source)

        let card = UIView(frame: plan.frame)
        card.backgroundColor = .clear
        card.layer.cornerRadius = host.corner
        card.layer.borderWidth = host.edge
        card.layer.borderColor = UIColor.white.cgColor
        card.clipsToBounds = true
        card.isUserInteractionEnabled = true

        // The scene view keeps the scene's own coordinate space and is scaled as
        // a whole — setting `frame` instead rewrites that space, which is what
        // 0.0.22 did when the card came up empty.
        view.transform = .identity
        view.autoresizingMask = []
        view.bounds = CGRect(origin: .zero, size: source)
        view.center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        view.transform = CGAffineTransform(scaleX: plan.scale, y: plan.scale)
        card.addSubview(view)
        root.addSubview(card)

        host.window = window
        host.card = card
        host.content = view
        host.natural = source
        host.installClose()
        // The ring goes in last, so it is above the card in the window. Its own
        // hitTest hands back nothing inside the card's rect, so a touch on the
        // picture still reaches the app — the ring is above, not in the way.
        host.installGrip(on: root)
        host.installGestures()

        Log.write("win: card "
                  + String(format: "%.0fx%.0f", card.bounds.width, card.bounds.height)
                  + " at " + String(format: "%.0f,%.0f", card.frame.origin.x, card.frame.origin.y)
                  + " natural=" + String(format: "%.0fx%.0f", source.width, source.height))
        Log.write("win: scale factor=" + String(format: "%.3f", plan.scale)
                  + " shown=" + String(format: "%.0fx%.0f",
                                       source.width * plan.scale, source.height * plan.scale)
                  + " fill=" + String(format: "%.0fx%.0f",
                                      card.bounds.width, card.bounds.height))
        // Where the ring is, so the next log can be read against the code instead
        // of against a memory. Two `let`s: one long concatenation of format calls
        // is a type-checker timeout, and 0.0.30 lost a build to it.
        let ring = "win: grip ring band=" + String(format: "%.0f", host.band)
        let cell = " cell=" + String(format: "%.0f", FloatHost.cell(in: card.bounds.size).width)
        Log.write(ring + cell
                  + " 外侧 (左右 拖动/点吸附, 底中 拖动/上滑关, 底角 缩放/长按复位, 顶部不接)")
        return window.isHidden ? nil : host
    }

    /// Records what the operator just did with the card.
    ///
    /// Called at the end of a move and nowhere else: an in-flight drag would be a
    /// disk write forty times a second on SpringBoard's main thread, for a value
    /// nobody can read until the finger lifts.
    ///
    /// 0.0.40 — the drag no longer snaps to an edge. Snapping and 吸附 stopped
    /// being the same thing the moment 吸附 became a tap: a card pulled hard
    /// against the screen for being nudged near it, while a card that becomes a
    /// 停靠小窗 only on a deliberate tap, are two answers to one word. The card
    /// now stays exactly where the finger left it, and that is what is stored.
    ///
    /// While docked, only the mini's own frame is updated. Writing that to the
    /// file would make a temporary size look like the operator's chosen one.
    private func remember(in bounds: CGRect) {
        guard let card = card, bounds.width > 0, bounds.height > 0 else { return }
        if miniFrame != nil {
            miniFrame = card.frame
            return
        }
        var placement = CardLayout.loadRuntime()
        let origin = card.frame.origin
        let normalized = CGPoint(x: origin.x / bounds.width, y: origin.y / bounds.height)
        placement.edge = origin.x + card.bounds.width / 2 < bounds.width / 2 ? .left : .right
        if placement.edge == .left {
            placement.left = normalized
        } else {
            placement.right = normalized
        }
        placement.heightFraction = card.bounds.height / bounds.height

        let ok = CardLayout.save(placement)
        let side = placement.edge == .left ? "left" : "right"
        let at = String(Int((normalized.x * 100).rounded())) + "% / "
            + String(Int((normalized.y * 100).rounded())) + "%"
        let tall = " h=" + String(Int((placement.heightFraction * 100).rounded())) + "%"
        Log.write("win: card remembered " + side + " at " + at + tall
                  + (ok ? "" : " (write failed)"))
    }

    /// The hosted view belongs to the system. It leaves with the card and never
    /// with the window: holding a presentation view after the presenter is gone
    /// keeps a scene alive that should have been reclaimed.
    static func hide() {
        shared.teardown()
    }

    private func teardown() {
        guard let window = window else {
            onClose = nil
            return
        }
        for sub in card?.subviews ?? [] { sub.removeFromSuperview() }
        grip?.removeFromSuperview()
        card?.removeFromSuperview()
        grip = nil
        close = nil
        shield = nil
        card = nil
        content = nil
        pan = nil
        press = nil
        tap = nil
        miniFrame = nil
        onClose = nil
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
    }

    private func makeWindow() -> FloatWindow? {
        if let scene = mainScene() {
            let window = FloatWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            return window
        }
        return FloatWindow(frame: UIScreen.main.bounds)
    }

    /// The card is the picture's shape, so there is no leftover to show as a
    /// black bar. Width is chosen first (capped by the screen) and the height
    /// follows; the screen caps the height in the other direction.
    ///
    /// 0.0.39 — the card comes back where it was left: height from
    /// `HeightFraction`, width from the scene's aspect, origin from the stored
    /// corner for the current edge, clamped on screen.
    private func plan(in bounds: CGRect, source: CGSize) -> (frame: CGRect, scale: CGFloat) {
        guard bounds.width > 64, bounds.height > 200, source.height > 16 else {
            return (CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight), 1)
        }
        let placement = CardLayout.loadRuntime()
        let ratio = source.width / source.height

        var h = bounds.height * placement.heightFraction
        var w = h * ratio
        let widest = bounds.width - margin * 2
        if w > widest {
            w = widest
            h = w / ratio
        }
        // The tall guard from 0.0.24 stays: a short screen with a tall scene
        // still has to leave room to see what is behind the card.
        let tallest = bounds.height - 160
        if h > tallest {
            h = tallest
            w = h * ratio
        }

        let saved = placement.origin(for: placement.edge)
        var x = saved.x * bounds.width
        var y = saved.y * bounds.height
        // Clamp as a rectangle, not as two numbers: a width change from a
        // rotation must not leave the right edge 40 pt outside the screen.
        x = Swift.min(Swift.max(margin, x), Swift.max(margin, bounds.width - w - margin))
        y = Swift.min(Swift.max(0, y), Swift.max(0, bounds.height - h))
        return (CGRect(x: x, y: y, width: w, height: h), h / source.height)
    }

    // MARK: - close

    /// A 30pt disc in the top-right corner. It is added after the scene view, so
    /// hit testing reaches it first: a hosted scene view is a real UIView and
    /// would otherwise swallow the touch and forward it to the app.
    private func installClose() {
        guard let card = card else { return }
        let disc = UIControl(frame: CGRect(x: card.bounds.width - margin - closeSize,
                                           y: margin,
                                           width: closeSize,
                                           height: closeSize))
        disc.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        disc.layer.cornerRadius = closeSize / 2
        disc.layer.borderWidth = 1
        disc.layer.borderColor = UIColor.white.withAlphaComponent(0.75).cgColor
        disc.autoresizingMask = [.flexibleLeftMargin]
        disc.addTarget(self, action: #selector(tapClose), for: .touchUpInside)

        let cross = UILabel(frame: disc.bounds)
        cross.text = "✕"
        cross.textColor = .white
        cross.font = .systemFont(ofSize: 15, weight: .semibold)
        cross.textAlignment = .center
        cross.isUserInteractionEnabled = false
        disc.addSubview(cross)

        card.addSubview(disc)
        close = disc
    }

    /// Called from inside a touch dispatch on the view being removed, so the
    /// teardown runs on the next turn of the run loop rather than under UIKit's
    /// own call stack.
    @objc private func tapClose() {
        requestClose("close button")
    }

    private func requestClose(_ reason: String) {
        let hook = onClose
        onClose = nil
        Log.write("win: close requested by " + reason)
        DispatchQueue.main.async { hook?(reason) }
    }

    // MARK: - ring

    /// The ring is the card's frame grown by `band` on all four sides, with the
    /// card's own rect declared as a hole and the top strip declared dead.
    /// Nothing about it is special: it has no background, it draws nothing, it
    /// exists to be touched.
    private func installGrip(on root: UIView) {
        guard let card = card else { return }
        let grip = GripView(frame: card.frame.insetBy(dx: -reach, dy: -reach))
        grip.backgroundColor = .clear
        grip.isUserInteractionEnabled = true
        grip.hole = CGRect(x: reach, y: reach,
                           width: card.bounds.width, height: card.bounds.height)
        root.addSubview(grip)
        self.grip = grip
        syncGrip()
    }

    /// Every frame change goes through here. A ring that lags its card by one
    /// event is a ring the finger misses by one band.
    private func syncGrip() {
        guard let card = card, let grip = grip else { return }
        grip.frame = card.frame.insetBy(dx: -reach, dy: -reach)
        grip.hole = CGRect(x: reach, y: reach,
                           width: card.bounds.width, height: card.bounds.height)
    }

    /// The bottom band's middle third — the cell that closes on a flick and
    /// moves otherwise. The rest of the bottom band is 边角.
    private func zoneFor(_ point: CGPoint) -> Zone {
        guard let card = card else { return .bottomCorner }
        let size = card.bounds.size
        if point.y > size.height {
            let cell = FloatHost.cell(in: size)
            let middle = point.x >= cell.minX && point.x <= cell.maxX
            return middle ? .bottomMiddle : .bottomCorner
        }
        return point.x < 0 ? .left : .right
    }

    // Not private: GripView (same file, different type) paints the heat map
    // with the very same cell arithmetic, and one number must not fork in two.
    static func cell(in size: CGSize) -> CGRect {
        let third = size.width / 3
        return CGRect(x: third, y: 0, width: third, height: size.height)
    }

    private func name(_ zone: Zone) -> String {
        switch zone {
        case .left: return "left"
        case .right: return "right"
        case .bottomMiddle: return "bottom-middle"
        case .bottomCorner: return "bottom-corner"
        }
    }

    /// Ring coordinates back to the card's own, which is the space the zones and
    /// the geometry are written in. A point outside the card comes back negative
    /// or past the size, and that is precisely how a band is recognised.
    private func cardPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - reach, y: point.y - reach)
    }

    // MARK: - gestures

    private func installGestures() {
        guard let grip = grip else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        grip.addGestureRecognizer(pan)
        self.pan = pan

        // 长按 is now one cell only: 边角's 重启, wired to a geometry reset.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = pressDelay
        press.allowableMovement = 12
        press.delegate = self
        grip.addGestureRecognizer(press)
        self.press = press

        // 0.0.40 — one tap on a side band docks the card. It used to be a double
        // tap on 边中 that minimised, which meant aiming twice at a band and then
        // finding the way back behind the same band again.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDockTap(_:)))
        tap.delegate = self
        grip.addGestureRecognizer(tap)
        self.tap = tap
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let grip = grip else { return true }
        let zone = zoneFor(cardPoint(gesture.location(in: grip)))
        if gesture === tap {
            return zone == .left || zone == .right
        }
        if gesture === press {
            // Only 边角: the sides' long press is nothing at all now, and a press
            // that begins disables the pan, so allowing it there would cost the
            // move gesture its finger for 0.4 s.
            return zone == .bottomCorner
        }
        return true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let card = card, let window = window, let grip = grip else { return }
        switch gesture.state {
        case .began:
            let start = cardPoint(gesture.location(in: grip))
            zone = zoneFor(start)
            panStep = .zero
            // Which band the finger found. If the operator reports "it does not
            // work" again, this line says whether the touch arrived and which
            // zone it was counted as — two very different defects.
            Log.write("win: gesture grab zone=" + name(zone)
                      + " at " + point(start))
            // 0.0.43 — a corner drag resizes; every other band moves. The
            // anchor is the opposite corner, read once here: a zone is which
            // cell the finger landed in, not a thing that changes mid-drag.
            // `card` is already unwrapped by the guard above.
            if zone == .bottomCorner {
                resizeStart = card.frame
                resizeFromLeft = start.x < card.bounds.width / 2
            } else {
                resizeStart = nil
            }
        case .changed:
            // Every delta is measured in the window, never in the card or the
            // ring. Both are being resized and moved by this very gesture, so
            // their coordinate spaces are rulers that stretch.
            let total = gesture.translation(in: window)
            let dx = total.x - panStep.x
            let dy = total.y - panStep.y
            panStep = total
            if zone == .bottomCorner, let start = resizeStart {
                // 边角拖动 = 缩放（0.0.43）。The finger's vertical travel is the
                // height; the width follows the picture's own aspect. Down
                // grows, up shrinks, and the opposite corner stays put.
                let ratio = natural.width / Swift.max(natural.height, 1)
                var h = start.height + total.y
                var w = h * ratio
                let widest = window.bounds.width - margin * 2
                if w > widest {
                    w = widest
                    h = w / ratio
                }
                // The docked mini is the smallest shape the card ever takes;
                // a resize cannot go under it.
                let shortest = minWidth / Swift.max(ratio, 0.0001)
                if h < shortest {
                    h = shortest
                    w = h * ratio
                }
                let tallest = window.bounds.height - margin * 2
                if h > tallest {
                    h = tallest
                    w = h * ratio
                }
                var frame: CGRect
                if resizeFromLeft {
                    frame = CGRect(x: start.maxX - w, y: start.minY,
                                   width: w, height: h)
                } else {
                    frame = CGRect(x: start.minX, y: start.minY,
                                   width: w, height: h)
                }
                card.frame = clamped(frame, in: window.bounds)
                followContent()
                syncGrip()
            } else {
                // All four cells move. 0.0.40 removed the two that resized, so a
                // drag on the band is a drag on the band, wherever it started;
                // 0.0.43 gave the corners their own meaning back, so a drag on
                // a corner is a resize and this branch is the other three.
                var frame = card.frame
                frame.origin.x += dx
                frame.origin.y += dy
                card.frame = clamped(frame, in: window.bounds)
                syncGrip()
            }
        case .ended, .cancelled:
            if zone == .bottomCorner, resizeStart != nil {
                resizeStart = nil
                Log.write("win: card resized to " + point(card.frame.origin)
                          + " size=" + size(card.bounds.size))
                remember(in: window.bounds)
            } else {
                finishPan(gesture, card: card, window: window)
            }
        default:
            break
        }
    }

    private func finishPan(_ gesture: UIPanGestureRecognizer, card: UIView, window: UIWindow) {
        if zone == .bottomMiddle {
            // 边中区域快速上滑关闭. Two readings, either one closes.
            //
            // Travel first. 0.0.36 read speed alone, and Aevon(35) recorded four
            // attempts at `up=-159 / 0 / -199 / -2327` — not one of them
            // positive, on a phone where the operator was swiping up. A velocity
            // sample is the last frame or two of the finger; a thumb that reaches
            // its target and settles flips the sign without ever going back down.
            // Travel is the whole path and cannot flip. Speed stays as the second
            // reading, because a short hard flick barely travels and is still a
            // flick.
            let total = gesture.translation(in: window)
            let speed = gesture.velocity(in: window)
            let lift = -total.y
            let up = -speed.y
            let byTravel = lift > 50 && abs(total.y) > abs(total.x)
            let bySpeed = up > flick && up > abs(speed.x)
            if byTravel || bySpeed {
                Log.write("win: gesture edge-middle flick up=" + String(Int(up))
                          + " dy=" + String(Int(total.y)) + " -> close")
                requestClose("edge swipe up")
                return
            }
            Log.write("win: gesture edge-middle not a flick up=" + String(Int(up))
                      + " vx=" + String(Int(speed.x))
                      + " dy=" + String(Int(total.y)))
        }
        Log.write("win: card moved to " + point(card.frame.origin)
                  + " size=" + size(card.bounds.size))
        remember(in: window.bounds)
    }

    /// 边角长按 = 重启 (母本文案「边角区域滑动缩放, 长按重启」). Since 0.0.39 the
    /// plan reads the remembered placement, so resetting the frame alone would
    /// restore the very numbers the operator wanted gone — the remembered
    /// placement has to go first, or "restart" is a no-op.
    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let window = window else { return }
        switch gesture.state {
        case .began:
            // A press that becomes a drag must not also drag the card.
            pan?.isEnabled = false
            Log.write("win: gesture long press corner, 重启 as geometry reset")
            resetToPlan(in: window.bounds)
        case .ended, .cancelled, .failed:
            pan?.isEnabled = true
        default:
            break
        }
    }

    /// 吸附 — one tap on a side band. Docked is `miniFrame != nil`, and that is
    /// the only thing that says so: a second flag would be a second answer.
    @objc private func handleDockTap(_ gesture: UITapGestureRecognizer) {
        guard let grip = grip, let card = card, let window = window else { return }
        let zone = zoneFor(cardPoint(gesture.location(in: grip)))
        guard zone == .left || zone == .right else { return }
        if miniFrame != nil {
            undock()
            return
        }
        guard natural.height > 16 else { return }
        miniFrame = card.frame
        let height = minWidth / (natural.width / natural.height)
        let edge: CardLayout.Edge = zone == .left ? .left : .right
        let x = edge == .left ? margin : window.bounds.width - minWidth - margin
        let y = Swift.min(Swift.max(card.frame.minY, margin),
                          Swift.max(margin, window.bounds.height - height - margin))
        card.frame = CGRect(x: x, y: y, width: minWidth, height: height)
        followContent()
        installShield()
        syncGrip()
        Log.write("win: card docked " + (edge == .left ? "left " : "right ")
                  + size(card.bounds.size) + " at " + point(card.frame.origin))
    }

    /// The way out of 停靠小窗: a tap anywhere on its picture. The scene view
    /// would swallow that tap and forward it to the app, so a transparent shield
    /// goes above it — the same reasoning as the ✕, which works because it is a
    /// sibling drawn over the hosted view. It is inserted *below* the ✕ so the
    /// close button keeps working while the card is docked.
    private func installShield() {
        guard let card = card, shield == nil else { return }
        let view = UIControl(frame: card.bounds)
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addTarget(self, action: #selector(undock), for: .touchUpInside)
        if let close = close {
            card.insertSubview(view, belowSubview: close)
        } else {
            card.addSubview(view)
        }
        shield = view
    }

    @objc private func undock() {
        guard let card = card, let window = window, let saved = miniFrame else { return }
        miniFrame = nil
        card.frame = clamped(saved, in: window.bounds)
        followContent()
        shield?.removeFromSuperview()
        shield = nil
        syncGrip()
        Log.write("win: card undocked " + size(card.bounds.size)
                  + " at " + point(card.frame.origin))
    }

    // MARK: - geometry

    /// The content keeps the card's size for one reason only: it is the scene's
    /// own coordinate space, scaled. Re-centring without re-scaling is how a
    /// resize leaves the picture in the old corner.
    private func followContent() {
        guard let card = card, let content = content, natural.height > 16 else { return }
        content.center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        let scale = card.bounds.height / natural.height
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// 重启, as much of it as a window can do by itself: back to the frame the
    /// card was built with, with the remembered placement cleared first.
    private func resetToPlan(in bounds: CGRect) {
        guard let card = card, natural.height > 16, bounds.width > 64 else { return }
        CardLayout.reset()
        let plan = self.plan(in: bounds, source: natural)
        card.frame = plan.frame
        miniFrame = nil
        shield?.removeFromSuperview()
        shield = nil
        followContent()
        syncGrip()
        Log.write("win: card reset to " + size(card.bounds.size)
                  + " at " + point(card.frame.origin))
    }

    /// A card that can be dragged off the screen can only be brought back by
    /// closing it, so the edges are a wall, not a suggestion.
    private func clamped(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var result = frame
        let maxX = max(margin, bounds.width - result.width - margin)
        let maxY = max(margin, bounds.height - result.height - margin)
        result.origin.x = min(max(result.origin.x, margin), maxX)
        result.origin.y = min(max(result.origin.y, margin), maxY)
        return result
    }

    private func point(_ p: CGPoint) -> String {
        String(format: "%.0f,%.0f", p.x, p.y)
    }

    private func size(_ s: CGSize) -> String {
        String(format: "%.0fx%.0f", s.width, s.height)
    }

    /// `UIApplication.shared` is a force-unwrapped accessor. Inside SpringBoard
    /// it is normally valid, and "normally" is not worth a phone: go through the
    /// runtime and fall back to a screen-sized window when there is no app yet.
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
}

/// The gesture ring: the card's frame grown by the band, with the card's own
/// rect punched out and the top strip punched out too.
///
/// It exists because a hosted scene view owns its touches. Aevon(33) put the
/// recognizers on the card and got ninety seconds of silence — the presentation
/// view forwarded every touch in the picture to the app, and the ✕ disc worked
/// only because it is a sibling drawn above it. Outside the card there is no
/// scene, no remote window and nothing to forward to.
///
/// `hole` is what keeps the picture honest. Touching inside the card returns nil
/// from hitTest, so the touch goes to the card, to the presentation view, and to
/// the app — tapping, scrolling and liking inside the floating window behave like
/// a real window.
final class GripView: UIView {
    /// The card's rect in this view's own coordinates.
    var hole: CGRect = .zero
    /// The first few touches are written down. If a report ever says "the edge
    /// still does nothing", this line separates "the touch never arrived" from
    /// "it arrived in a zone that does not do that".
    ///
    /// 0.0.41 — four was too few. Aevon(39)'s log holds exactly one touch per
    /// card (the ✕), because the operator's four attempts at the band came
    /// after it and the counter had already stopped. Eight now, and the window
    /// below matches.
    private var proven = 0

    // 0.0.44 — the heat map is invisible again, and this time the geometry
    // stays exactly where it is.
    //
    // 0.0.42 painted it because Aevon(40) could not say whether a thumb that
    // landed nowhere had missed the ring or the ring had missed the thumb. That
    // question is answered: Aevon(41)/(42) show `gesture grab zone=right`,
    // `bottom-middle` and `bottom-corner` arriving, docking, resizing and
    // flick-closing. Aevon(42) asks for the colour to go away — while the four
    // zones stay, because they are what the fingers find.
    //
    // So: no fill, no `draw`. The zones are `point(inside:)` and the zone
    // arithmetic below, which do not need to be visible to work. It is one
    // subclass with one property and no pixels.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        if hole.contains(point) { return false }
        // 0.0.40 — the whole top strip is dead. It has no gesture any more, and a
        // band that answers nothing but still eats the touch is worse than no
        // band: the picture underneath loses taps for no benefit.
        if point.y < hole.minY { return false }
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard proven < 8, let touch = touches.first else { return }
        proven += 1
        Log.write("win: grip touch at " + String(format: "%.0f,%.0f", touch.location(in: self).x,
                                                 touch.location(in: self).y)
                  + " #" + String(proven))
    }
}

/// A window that is only answerable where its content is. Everything else falls
/// through to the app underneath, which is what makes a floating card usable
/// while a full-screen app is running.
final class FloatWindow: UIWindow {
    /// The first few touches, printed as they enter the window and before any hit
    /// testing of our own. Two reports in a row have ended with "the gesture does
    /// not fire" and an empty probe, and an empty probe means either the touch
    /// never reached this window or it reached it and missed the ring.
    /// `sendEvent` is the one place that can tell those apart.
    private var seen = 0   // 0.0.41 — 6 → 8, same reason as `GripView.proven`

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The bare root view is not a thing to answer with: letting it take the
        // touch costs the desktop its icons and gains nothing, because it has no
        // recognizers and no controls on it.
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }

    override func sendEvent(_ event: UIEvent) {
        if seen < 8, let touch = event.allTouches?.first, touch.phase == .began {
            seen += 1
            let point = touch.location(in: self)
            let who = hitTest(point, with: event)
                .map { String(cString: object_getClassName($0)) } ?? "nil"
            Log.write("win: event hit #" + String(seen)
                      + " at " + String(format: "%.0f,%.0f", point.x, point.y)
                      + " -> " + who)
        }
        super.sendEvent(event)
    }
}
