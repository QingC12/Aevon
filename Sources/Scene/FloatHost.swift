import UIKit

/// The floating window shell.
///
/// 0.2.x already proved the two hard parts on this phone: a window built from
/// the main `UIWindowScene`, and a `hitTest` that answers nil for itself so a
/// touch that misses the card falls through to whatever is underneath. This
/// reuses exactly that shape. The only thing it adds is the card the hosted
/// scene view goes into — 320 wide, the picture's own aspect, 12pt corners,
/// 2pt white edge — because the operator has to be able to see that the view is
/// really on screen before anything is activated.
///
/// 0.0.35 — the grip moves outside the card, where hers is.
///
/// 0.0.34 put the gesture band on the inside of the card's top and bottom edge,
/// read off her `GestureIntroduction` and nothing else. Aevon(33) answered with
/// ninety seconds of card, `beat 1` to `beat 320`, and not one `gesture` line:
/// the band was real, it was simply covered by the thing it was wrapped around.
/// A hosted scene view is a real UIView that owns its touches and forwards them
/// to the app — recognizers on the ancestor get nothing, which is exactly why
/// the ✕ disc worked (a sibling above it) and a drag did not.
///
/// Her own settings say where the band goes. Two keys out of her localisation
/// file, and the second one only makes sense if the band is outside:
///
///   SIFEI              = 扩展::浮窗4边交互
///   GestureBorderWidth = 减小浮窗手势宽度
///
/// and her text, verbatim:
///
///   浮窗手势区域为边缘外侧, 竖屏上下, 横屏左右;
///   边中区域快速上滑关闭, 俩点缩小, 长按切换横竖;
///   边角区域滑动缩放, 长按重启;
///   其余部分滑动移动, 长按+滑动缩放
///
/// 边缘外侧 — outside the edge. So the gesture surface is a ring wrapped around
/// the card, 40pt wide, with the card's own rect punched out of it:
///
///   ┌──────────── ring ────────────┐
///   │  边角  │   边中   │  边角      │   top band: middle third is 边中,
///   │  (角)  │  上滑关  │  (角)      │   the corner squares are 边角
///   ├───────┴──────────┴───────────┤
///   │ 其余                          │   left band: move
///   │   ╔══════════════════════╗   │
///   │   ║   the card — the app  ║   │   nothing here belongs to us any more
///   │   ╚══════════════════════╝   │
///   │ 其余                          │
///   ├───────┬──────────┬───────────┤
///   │  边角  │   边中   │  边角      │
///   └───────┴──────────┴───────────┘
///
/// Three things fall out of that, and all three are improvements rather than
/// compromises:
///
///   1. The band cannot be swallowed. Nothing is hosted in the ring, so no
///      remote scene view sits between the finger and the recognizer.
///   2. The picture is the app's again. Her model has no interior zone, so
///      tapping, scrolling and liking inside the card work as they do in a real
///      window — 0.0.34 ate those touches with a pan recognizer.
///   3. Moving the card is a band gesture, not a card gesture, which is why a
///      card that fills most of the screen is still draggable from its edge.
///
/// Two deviations, both printed in the log rather than discovered later:
///
///   - 长按切换横竖 and 长按重启 are wired to what this chain can do. There is no
///     orientation write in the scene path, so a rotation would move the card and
///     not the picture; and 重启 by rebuilding the window is the 0.0.20 presenter
///     remount that cost a phone. The long press says what it was asked for and
///     resets geometry — the half of 重启 a window can do by itself.
///   - 边角 is the four corner squares exactly, because her two trim settings are
///     named 左角 / 右角. The rest of the band moves, so a hand sliding along an
///     edge never resizes by accident.
final class FloatHost: NSObject, UIGestureRecognizerDelegate {
    static let shared = FloatHost()

    /// Which part of the ring a touch landed on. The mother ship's names.
    private enum Zone {
        case edgeMiddle
        case edgeCorner
        case rest
    }

    private var window: FloatWindow?
    private var card: UIView?
    private var content: UIView?
    private var close: UIControl?
    private var grip: GripView?
    /// 0.0.36 — debug only. The band drawn on screen, so "the gesture does not
    /// fire" stops being a matter of opinion. Delete with `installGrip`'s call.
    private var map: GripMap?
    private var onClose: ((String) -> Void)?
    /// The scene's own size. Every resize is this shape, scaled — the card never
    /// gets an aspect the picture does not have.
    private var natural: CGSize = .zero

    private var pan: UIPanGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    private var zone: Zone = .rest
    private var pressZone: Zone = .rest
    private var panStep: CGPoint = .zero
    /// Which end of the ring the drag started on. A corner above the card grows
    /// when the finger goes up; a corner below it grows the other way round.
    /// Without this, half the corners fight the hand.
    private var cornerTop = true
    private var pressStep: CGPoint = .zero
    private var miniFrame: CGRect?

    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 480
    private let corner: CGFloat = 12
    private let edge: CGFloat = 2
    private let margin: CGFloat = 8
    private let minWidth: CGFloat = 140
    private let closeSize: CGFloat = 30
    /// `GestureBorderWidth` in her settings, described there as 减小浮窗手势宽度 —
    /// i.e. the shipped default is a band you might want to shrink, so it is not
    /// a hairline. 40pt of ring outside a 320pt card is wide enough to find with
    /// a thumb without looking, and it costs the desktop 40pt of icon margin
    /// around the card, which is the price of the ring being outside at all.
    private let band: CGFloat = 40
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

        // 0.0.24 scaled the scene view to fit a fixed 320x480 card and the
        // operator saw what that means: a 430x932 picture in a 2:3 box is 221
        // wide, so ~50pt of black sat on each side. A card that shows a phone is
        // a card shaped like a phone. The card now takes the picture's aspect
        // and the width is the only thing chosen.
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
        // Where the ring is, so the next log can be read against her matrix
        // instead of against the code. Two `let`s: one long concatenation of
        // format calls is a type-checker timeout, and 0.0.30 lost a build to it.
        let ring = "win: grip ring band=" + String(format: "%.0f", host.band)
        let cell = " cell=" + String(format: "%.0f", FloatHost.cell(in: card.bounds.size).width)
        Log.write(ring + cell
                  + " 外侧 (边中 上滑关/双击缩, 边角 滑缩放/长按复位, 其余 滑移动/长按滑缩放)")
        // The painted band and the real band are the same rectangle or they are
        // two different bugs. This line is the comparison, printed once.
        if let grip = host.grip {
            let rect = "win: grip map hole=" + String(format: "%.0f,%.0f %.0fx%.0f",
                                                      grip.hole.origin.x, grip.hole.origin.y,
                                                      grip.hole.width, grip.hole.height)
            let out = " ring=" + String(format: "%.0f,%.0f %.0fx%.0f",
                                        grip.frame.origin.x, grip.frame.origin.y,
                                        grip.bounds.width, grip.bounds.height)
            Log.write(rect + out)
        }
        return window.isHidden ? nil : host
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
        map = nil
        card = nil
        content = nil
        close = nil
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
    /// black bar. Width is chosen first (320, capped by the screen) and the
    /// height follows; the screen caps the height in the other direction.
    ///
    /// 0.0.24 chose a 320x480 card and a fit-to-card scale, which is the same
    /// thing as asking for two black bars: 932/430 of a 320-wide card is 694
    /// tall, and 320 wide of a 430-wide picture is 319 — the numbers only agree
    /// when the card has the picture's aspect.
    private func plan(in bounds: CGRect, source: CGSize) -> (frame: CGRect, scale: CGFloat) {
        guard bounds.width > 64, bounds.height > 200, source.height > 16 else {
            return (CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight), 1)
        }
        let ratio = source.width / source.height
        var w = min(cardWidth, bounds.width - 32)
        var h = w / ratio
        let tallest = bounds.height - 160
        if h > tallest {
            h = tallest
            w = h * ratio
        }
        let x = (bounds.width - w) / 2
        let y = max(60, (bounds.height - h) / 2)
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
    /// own call stack. One `async`, and the card cannot be pulled out from under
    /// the event that closed it.
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
    /// card's own rect declared as a hole. Nothing else about it is special:
    /// it has no background, it draws nothing, it exists to be touched.
    ///
    /// 0.0.36 puts a `GripMap` inside it. That is a paint job, not a feature:
    /// Aevon(33) and Aevon(34) both reported "the gesture does not fire" with a
    /// log that proves the ring was built and never touched once. Two very
    /// different defects look identical from the log alone — the finger went to
    /// the picture instead of the band (the picture is 320x694, the band is 40
    /// wide, and nothing on screen said where the line is), or the touch was
    /// lost before it reached us. A band you can see settles which one it is on
    /// the next screenshot. Remove the two `map` lines and the class below when
    /// the gesture is confirmed.
    private func installGrip(on root: UIView) {
        guard let card = card else { return }
        let grip = GripView(frame: card.frame.insetBy(dx: -band, dy: -band))
        grip.backgroundColor = .clear
        grip.isUserInteractionEnabled = true
        grip.hole = CGRect(x: band, y: band, width: card.bounds.width, height: card.bounds.height)

        // Inside the ring, above the picture, and deaf: `isUserInteractionEnabled`
        // is false so hit testing walks straight through it to the ring itself.
        let map = GripMap(frame: grip.bounds)
        map.isUserInteractionEnabled = false
        map.backgroundColor = .clear
        grip.addSubview(map)

        root.addSubview(grip)
        self.grip = grip
        self.map = map
        syncGrip()
    }

    /// Every frame change goes through here. A ring that lags its card by one
    /// event is a ring the finger misses by one band.
    private func syncGrip() {
        guard let card = card, let grip = grip else { return }
        grip.frame = card.frame.insetBy(dx: -band, dy: -band)
        grip.hole = CGRect(x: band, y: band,
                           width: card.bounds.width, height: card.bounds.height)
        guard let map = map else { return }
        map.frame = grip.bounds
        map.hole = grip.hole
        map.cell = FloatHost.cell(in: card.bounds.size)
    }

    /// 竖屏上下, 横屏左右 — the card is always the scene's portrait shape here, so
    /// the bands that count are the top and bottom ones. The middle third of a
    /// band is 边中; the four squares where two bands meet are 边角; everything
    /// else in the ring moves the card.
    private func zoneFor(_ point: CGPoint) -> Zone {
        guard let card = card else { return .rest }
        let size = card.bounds.size
        let outsideX = point.x < 0 || point.x > size.width
        let outsideY = point.y < 0 || point.y > size.height
        if outsideX && outsideY { return .edgeCorner }
        if outsideY {
            let cell = FloatHost.cell(in: size)
            if point.x >= cell.minX && point.x <= cell.maxX { return .edgeMiddle }
        }
        return .rest
    }

    private static func cell(in size: CGSize) -> CGRect {
        let third = size.width / 3
        return CGRect(x: third, y: 0, width: third, height: size.height)
    }

    private func name(_ zone: Zone) -> String {
        switch zone {
        case .edgeMiddle: return "edge-middle"
        case .edgeCorner: return "edge-corner"
        case .rest: return "rest"
        }
    }

    /// Ring coordinates back to the card's own, which is the space the zones and
    /// the geometry are written in. A point outside the card comes back negative
    /// or past the size, and that is precisely how a band is recognised.
    private func cardPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - band, y: point.y - band)
    }

    // MARK: - gestures

    private func installGestures() {
        guard let grip = grip else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        grip.addGestureRecognizer(pan)
        self.pan = pan

        // 长按 is half of two of her four cells, so it is not an accessory here:
        // 0.4s is her delay, and it has to lose to a pan (a drag that starts
        // moving is a drag, not a press).
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = pressDelay
        press.allowableMovement = 12
        press.delegate = self
        grip.addGestureRecognizer(press)
        self.press = press

        // 俩点缩小 — two taps in 边中, and only there: a double tap on the rest of
        // the ring belongs to nothing, and a double tap inside the card belongs
        // to the app.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        tap.delegate = self
        grip.addGestureRecognizer(tap)
        self.tap = tap
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let grip = grip else { return true }
        let zone = zoneFor(cardPoint(gesture.location(in: grip)))
        if gesture === tap {
            // 俩点缩小 — two taps in 边中, and only there: a double tap on the
            // rest of the ring belongs to nothing, and a double tap inside the
            // card belongs to the app.
            return zone == .edgeMiddle
        }
        if gesture === press {
            // 0.0.37 — 边中 does not take a long press at all. Its 长按 is
            // 切换横竖, which this chain cannot do, so the recognizer was only
            // there to be reported in the log — and it was, twenty times in
            // Aevon(35). The cost was not the log line: `handlePress` disables
            // the pan when it begins, so "press the cyan block, then flick up"
            // disabled the very recognizer that reads a flick. The close
            // gesture was never missed; it was switched off half a second
            // before it started.
            return zone != .edgeMiddle
        }
        return true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let card = card, let window = window, let grip = grip else { return }
        switch gesture.state {
        case .began:
            let start = cardPoint(gesture.location(in: grip))
            zone = zoneFor(start)
            cornerTop = start.y < 0
            panStep = .zero
            // Which band the finger found. If the operator reports "it does not
            // work" again, this line says whether the touch arrived and which
            // zone it was counted as — two very different defects.
            Log.write("win: gesture grab zone=" + name(zone)
                      + " at " + point(start))
        case .changed:
            // Every delta is measured in the window, never in the card or the
            // ring. Both are being resized and moved by this very gesture, so
            // their coordinate spaces are rulers that stretch.
            let total = gesture.translation(in: window)
            let dx = total.x - panStep.x
            let dy = total.y - panStep.y
            panStep = total
            switch zone {
            case .rest:
                var frame = card.frame
                frame.origin.x += dx
                frame.origin.y += dy
                card.frame = clamped(frame, in: window.bounds)
                syncGrip()
            case .edgeCorner:
                // 边角区域滑动缩放 — direct, no long press. Vertical drag changes
                // the height and the width follows the scene's own ratio, with the
                // band's own sign so the edge stays under the finger.
                resize(height: card.bounds.height + (cornerTop ? -dy : dy))
            case .edgeMiddle:
                // 边中 only answers a flick; dragging there is not a move, and
                // moving the card from its own edge is how a window gets dragged
                // out of the user's hand.
                break
            }
        case .ended, .cancelled:
            finishPan(gesture, card: card, window: window)
        default:
            break
        }
    }

    private func finishPan(_ gesture: UIPanGestureRecognizer, card: UIView, window: UIWindow) {
        switch zone {
        case .edgeMiddle:
            // 边中区域快速上滑关闭. Two readings, either one closes.
            //
            // Travel first. 0.0.36 read speed alone, and Aevon(35) recorded
            // four attempts at `up=-159 / 0 / -199 / -2327` — not one of them
            // positive, on a phone where the operator was swiping up. A
            // velocity sample is the last frame or two of the finger; a thumb
            // that reaches its target and settles flips the sign without ever
            // going back down. Travel is the whole path and cannot flip.
            //
            // Speed stays as the second reading, because a short hard flick
            // barely travels and is still a flick.
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
            } else {
                Log.write("win: gesture edge-middle not a flick up=" + String(Int(up))
                          + " vx=" + String(Int(speed.x))
                          + " dy=" + String(Int(total.y)))
            }
        case .edgeCorner:
            let scale = card.bounds.height / max(natural.height, 1)
            let end = cornerTop ? " top band" : " bottom band"
            Log.write("win: card resized " + size(card.bounds.size)
                      + " by corner, scale=" + String(format: "%.3f", scale) + end)
        case .rest:
            Log.write("win: card moved to " + point(card.frame.origin)
                      + " size=" + size(card.bounds.size))
        }
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let card = card, let window = window, let grip = grip else { return }
        switch gesture.state {
        case .began:
            pressZone = zoneFor(cardPoint(gesture.location(in: grip)))
            pressStep = gesture.location(in: window)
            // A press that becomes a drag must not also drag the card: 长按+滑动
            // is a resize, and two recognizers fighting over one finger is how a
            // window ends up in two places at once.
            pan?.isEnabled = false
            switch pressZone {
            case .edgeCorner:
                Log.write("win: gesture long press edge-corner, 重启 as geometry reset")
                resetToPlan(in: window.bounds)
            case .rest:
                Log.write("win: gesture long press rest, drag to resize")
            default:
                // 边中 never reaches here: `gestureRecognizerShouldBegin` refuses
                // the press there, because 切换横竖 is not wired and disabling the
                // pan is what killed the flick in 0.0.36.
                break
            }
        case .changed:
            guard pressZone == .rest else { break }
            let total = gesture.location(in: window)
            let dy = total.y - pressStep.y
            pressStep = total
            resize(height: card.bounds.height + dy)
        case .ended, .cancelled, .failed:
            if pressZone == .rest {
                Log.write("win: card resized " + size(card.bounds.size)
                          + " by long press, scale=" + String(format: "%.3f",
                                                              card.bounds.height / max(natural.height, 1)))
            }
            pan?.isEnabled = true
        default:
            break
        }
    }

    /// 俩点缩小 — 贴边缩小, 不可操作. Two taps in the band shrink the card to the
    /// narrowest width and dock it against the nearer screen edge; two more bring
    /// back exactly the frame it had, because a minimise with no way back is a
    /// close with extra steps.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let card = card, let window = window else { return }
        if let saved = miniFrame {
            card.frame = clamped(saved, in: window.bounds)
            miniFrame = nil
            followContent()
            syncGrip()
            Log.write("win: gesture double tap restored " + size(card.bounds.size)
                      + " at " + point(card.frame.origin))
            return
        }
        guard natural.height > 16 else { return }
        miniFrame = card.frame
        let height = minWidth / (natural.width / natural.height)
        let dockLeft = card.center.x < window.bounds.midX
        let x = dockLeft ? margin : window.bounds.width - minWidth - margin
        let y = min(max(card.frame.origin.y, margin), window.bounds.height - height - margin)
        card.frame = CGRect(x: x, y: y, width: minWidth, height: height)
        followContent()
        syncGrip()
        Log.write("win: gesture double tap minimised " + size(card.bounds.size)
                  + (dockLeft ? " docked left" : " docked right"))
    }

    // MARK: - geometry

    /// Height is the one number a resize moves; width follows the scene's ratio.
    /// Anything else is the two black bars of 0.0.24 coming back.
    private func resize(height: CGFloat) {
        guard let card = card, let window = window,
              natural.width > 16, natural.height > 16 else { return }
        let ratio = natural.width / natural.height
        var h = height
        var w = h * ratio
        let widest = max(minWidth, window.bounds.width - 32)
        if w > widest {
            w = widest
            h = w / ratio
        }
        if w < minWidth {
            w = minWidth
            h = w / ratio
        }
        let tallest = window.bounds.height - 160
        if h > tallest {
            h = tallest
            w = h * ratio
        }
        card.bounds = CGRect(origin: .zero, size: CGSize(width: w, height: h))
        followContent()
        card.frame = clamped(card.frame, in: window.bounds)
        syncGrip()
    }

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
    /// card was built with. A window that has been dragged to a corner, shrunk to
    /// nothing or grown past the screen has no other way home, and rebuilding it
    /// would re-run the presenter mount that 0.0.20 already paid for.
    private func resetToPlan(in bounds: CGRect) {
        guard let card = card, natural.height > 16, bounds.width > 64 else { return }
        let plan = self.plan(in: bounds, source: natural)
        card.frame = plan.frame
        miniFrame = nil
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
/// rect punched out.
///
/// It exists because a hosted scene view owns its touches. Aevon(33) put the
/// recognizers on the card and got ninety seconds of silence — the presentation
/// view forwarded every touch in the picture to the app, and the ✕ disc worked
/// only because it is a sibling drawn above it. Outside the card there is no
/// scene, no remote window and nothing to forward to: a touch on the ring is a
/// touch on a plain view in our own window.
///
/// `hole` is what keeps the picture honest. Touching inside the card returns nil
/// from hitTest, so the touch goes to the card, to the presentation view, and to
/// the app — tapping, scrolling and liking inside the floating window behave
/// like a real window, which 0.0.34's pan recognizer had taken away.
final class GripView: UIView {
    /// The card's rect in this view's own coordinates.
    var hole: CGRect = .zero
    /// The first few touches are written down. If a report ever says "the edge
    /// still does nothing", this line separates "the touch never arrived" from
    /// "it arrived in a zone that does not do that" without another build.
    private var proven = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && !hole.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard proven < 4, let touch = touches.first else { return }
        proven += 1
        Log.write("win: grip touch at " + String(format: "%.0f,%.0f", touch.location(in: self).x,
                                                 touch.location(in: self).y)
                  + " #" + String(proven))
    }
}

/// The band, painted. Debug only — 0.0.36.
///
/// Six plain views laid over the ring: four yellow strips for the side bands,
/// two cyan patches for 边中 (the middle third of the top and bottom band, the
/// one that closes on a flick). The card's rect is left empty, so the picture is
/// still the picture and this cannot be mistaken for a UI element.
///
/// The reason it exists: Aevon(33) and Aevon(34) both said the gesture does not
/// fire, and both logs proved the ring was built and never touched. A band
/// nobody can see is a band a thumb can miss by exactly the amount that matters
/// — the card is 320x694 and the band is 40pt outside it. Once the gesture is
/// confirmed, remove `map` from FloatHost and this class.
///
/// Views rather than `draw(_:)`: painting the same six rectangles in a draw
/// method cost 16 KB of binary, because overriding `draw` puts the whole layer
/// display path back into a tweak that had none of it. Six `UIView`s are
/// allocations at runtime, not bytes in the file.
final class GripMap: UIView {
    /// The card's rect, in this view's coordinates. Nothing is drawn there.
    var hole: CGRect = .zero {
        didSet { setNeedsLayout() }
    }
    /// The middle third of the card's width — 边中.
    var cell: CGRect = .zero {
        didSet { setNeedsLayout() }
    }
    private var strips: [UIView] = []

    override func layoutSubviews() {
        if strips.isEmpty {
            for index in 0..<6 {
                let ink: UIColor = index < 4 ? .yellow : .cyan
                let view = UIView()
                view.backgroundColor = ink.withAlphaComponent(index < 4 ? 0.30 : 0.60)
                view.layer.borderWidth = 1
                view.layer.borderColor = ink.cgColor
                view.isUserInteractionEnabled = false
                addSubview(view)
                strips.append(view)
            }
        }
        let w = bounds.width
        let h = bounds.height
        let bx = hole.minX
        let by = hole.minY
        strips[0].frame = CGRect(x: 0, y: 0, width: w, height: by)
        strips[1].frame = CGRect(x: 0, y: hole.maxY, width: w, height: h - hole.maxY)
        strips[2].frame = CGRect(x: 0, y: hole.minY, width: bx, height: hole.height)
        strips[3].frame = CGRect(x: hole.maxX, y: hole.minY,
                                 width: w - hole.maxX, height: hole.height)
        let mid = CGRect(x: hole.minX + cell.minX, y: 0, width: cell.width, height: by)
        strips[4].frame = mid
        strips[5].frame = CGRect(x: mid.minX, y: hole.maxY,
                                 width: mid.width, height: h - hole.maxY)
    }
}

/// A window that is only answerable where its content is. Everything else falls
/// through to the app underneath, which is what makes a floating card usable
/// while a full-screen app is running.
final class FloatWindow: UIWindow {
    /// 0.0.36 — the first few touches, printed where they enter the window and
    /// before any hit testing of our own. Two reports in a row have ended with
    /// "the gesture does not fire" and an empty `grip touch` probe, and an empty
    /// probe means either the touch never reached this window or it reached it
    /// and missed the ring. `sendEvent` is the one place that can tell those
    /// apart: it runs for every touch that arrives, whatever the answer to
    /// hitTest turns out to be, and it can print that answer next to it.
    private var seen = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The card is answerable only where something is drawn in it. The bare
        // root view is not a thing to answer with: letting it take the touch
        // costs the desktop its icons and gains nothing, because it has no
        // recognizers and no controls on it.
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }

    override func sendEvent(_ event: UIEvent) {
        if seen < 6, let touch = event.allTouches?.first, touch.phase == .began {
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
