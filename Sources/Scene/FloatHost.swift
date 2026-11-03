import UIKit

/// The floating window shell.
///
/// 0.2.x already proved the two hard parts on this phone: a window built from
/// the main `UIWindowScene`, and a `hitTest` that answers nil for itself so a
/// touch that misses the card falls through to whatever is underneath. This
/// reuses exactly that shape. The only thing it adds is the card the hosted
/// scene view goes into — 320x480, 12pt corners, 2pt white edge — because the
/// operator has to be able to see that the view is really on screen before
/// anything is activated.
///
/// 0.0.34 — the gestures are the mother ship's, not ours. Aevon(32) showed the
/// problem without saying it: fifty seconds of card, `wrote` climbing 1 -> 3 -> 5,
/// and not one `card moved to` line, because a pinch-and-drag shell is not what
/// a Stheno user does. Her own text is the specification, verbatim out of
/// `zh-Hans Localizable.strings`:
///
///   浮窗手势区域为边缘外侧, 竖屏上下, 横屏左右;
///   边中区域快速上滑关闭, 俩点缩小, 长按切换横竖;
///   边角区域滑动缩放, 长按重启;
///   其余部分滑动移动, 长按+滑动缩放
///
/// So the card is a three-region surface, not one pan area:
///
///   区域        快速上滑   双击      长按            长按+滑动
///   边中        关闭       缩小      切换横竖        —
///   边角        —          —         重启            滑动缩放
///   其余        —          —         —               缩放
///                                       （其余部分: 滑动 = 移动）
///
/// Two deviations, both named here rather than discovered later:
///
///   1. The band is on the *inside* of the card's top and bottom edge. Her text
///      says 边缘外侧 — outside — because her window sits against the screen
///      edge, so outside it there is nothing to steal. Our card floats in the
///      middle of the desktop: a band outside it would have to claim touches on
///      the desktop itself, and the desktop is where the icons are.
///   2. 长按切换横竖 and 长按重启 are wired to what this chain can actually do.
///      There is no orientation write anywhere in 0.0.33's scene path, so a
///      rotation gesture would move the card and not the picture; and 重启 by
///      rebuilding the window is the 0.0.20 presenter-remount that cost a phone.
///      The long press prints what it was asked to do and resets the geometry,
///      which is the half of 重启 that a window can do by itself.
final class FloatHost: NSObject, UIGestureRecognizerDelegate {
    static let shared = FloatHost()

    /// Which part of the card a touch landed on. The mother ship's names.
    private enum Zone {
        case edgeMiddle
        case edgeCorner
        case interior
    }

    private var window: FloatWindow?
    private var card: UIView?
    private var content: UIView?
    private var close: UIControl?
    private var onClose: ((String) -> Void)?
    /// The scene's own size. Every resize is this shape, scaled — the card never
    /// gets an aspect the picture does not have.
    private var natural: CGSize = .zero

    private var pan: UIPanGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    private var zone: Zone = .interior
    private var pressZone: Zone = .interior
    private var panStep: CGPoint = .zero
    /// Which band the drag started in. 边角 on the top edge has to follow the
    /// finger: pulling that edge down shrinks the card, and the bottom edge is
    /// the other way round. Without this, one of the two corners fights the hand.
    private var bandTop = true
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
    /// a hairline. 44pt on a 320pt card is the same proportion as a 12% band on a
    /// 375pt phone, which is what an edge gesture has to be to be findable by a
    /// thumb without looking.
    private let band: CGFloat = 44
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
        // and the width is the only thing chosen — 0.0.24 logged
        // `scale factor=0.515 shown=221x480`, and the sum of those two numbers
        // is the two black bars.
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
        host.installGestures(on: card)

        Log.write("win: card "
                  + String(format: "%.0fx%.0f", card.bounds.width, card.bounds.height)
                  + " at " + String(format: "%.0f,%.0f", card.frame.origin.x, card.frame.origin.y)
                  + " natural=" + String(format: "%.0fx%.0f", source.width, source.height))
        Log.write("win: scale factor=" + String(format: "%.3f", plan.scale)
                  + " shown=" + String(format: "%.0fx%.0f",
                                       source.width * plan.scale, source.height * plan.scale)
                  + " fill=" + String(format: "%.0fx%.0f",
                                      card.bounds.width, card.bounds.height))
        // One line that says which regions exist, so the next log can be read
        // against the matrix instead of against the code. Split into `let`s
        // because one long concatenation of format calls is a type-checker
        // timeout, and 0.0.30 lost a whole build to exactly that.
        let head = "win: gesture zones band=" + String(format: "%.0f", host.band)
        let middle = " middle=" + String(format: "%.0f", FloatHost.cell(in: card.bounds.size).width)
        Log.write(head + middle
                  + " (边中 上滑关/双击缩/长按横竖, 边角 滑缩放/长按复位, 其余 滑移动/长按滑缩放)")
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
        card?.removeFromSuperview()
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

    // MARK: - zones

    /// 竖屏上下, 横屏左右 — the card is always the scene's portrait shape here, so
    /// the band lives on the top and bottom edge. 边中 is the middle third of the
    /// band; the outer thirds are 边角, where her resize corners are.
    private func zoneFor(_ point: CGPoint) -> Zone {
        guard let card = card else { return .interior }
        let size = card.bounds.size
        let reach = min(band, size.height / 4)
        guard point.y <= reach || point.y >= size.height - reach else { return .interior }
        let middle = FloatHost.cell(in: size)
        if point.x >= middle.minX && point.x <= middle.maxX { return .edgeMiddle }
        return .edgeCorner
    }

    private static func cell(in size: CGSize) -> CGRect {
        let third = size.width / 3
        return CGRect(x: third, y: 0, width: third, height: size.height)
    }

    // MARK: - gestures

    private func installGestures(on card: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        card.addGestureRecognizer(pan)
        self.pan = pan

        // 长按 is half of two of her four cells, so it is not an accessory here:
        // 0.4s is her delay, and it has to lose to a pan (a drag that starts
        // moving is a drag, not a press).
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = pressDelay
        press.allowableMovement = 12
        press.delegate = self
        card.addGestureRecognizer(press)
        self.press = press

        // 俩点缩小 — two taps in 边中. It begins only there, so a double tap in
        // the middle of the picture still belongs to the app.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        tap.delegate = self
        card.addGestureRecognizer(tap)
        self.tap = tap
    }

    /// The close disc is a control, not a gesture surface. Without this a swipe
    /// that starts on the ✕ becomes a 边角 resize and the tap that follows is
    /// cancelled — the one button on the card would be the one thing that does
    /// not work.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let disc = close else { return true }
        return !disc.bounds.contains(touch.location(in: disc))
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let card = card, gesture === tap else { return true }
        return zoneFor(gesture.location(in: card)) == .edgeMiddle
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let card = card, let window = window else { return }
        switch gesture.state {
        case .began:
            zone = zoneFor(gesture.location(in: card))
            bandTop = gesture.location(in: card).y <= card.bounds.height / 2
            panStep = .zero
        case .changed:
            // Every delta is measured in the window, never in the card. The card
            // is being resized while the finger moves, so its own coordinate
            // space is a ruler that stretches: 0.0.24 read a 40pt drag as 55 and
            // the corner ran away from the finger.
            let total = gesture.translation(in: window)
            let dx = total.x - panStep.x
            let dy = total.y - panStep.y
            panStep = total
            switch zone {
            case .interior:
                var frame = card.frame
                frame.origin.x += dx
                frame.origin.y += dy
                card.frame = clamped(frame, in: window.bounds)
            case .edgeCorner:
                // 边角区域滑动缩放 — direct, no long press. Vertical drag changes
                // the height and the width follows the scene's own ratio, with the
                // band's own sign so the edge stays under the finger.
                resize(height: card.bounds.height + (bandTop ? -dy : dy))
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
            // 边中区域快速上滑关闭. A flick is up-and-fast: the upward component
            // has to clear the threshold and has to be the larger one, or a
            // diagonal drag along the band would close a window nobody meant to
            // close.
            let speed = gesture.velocity(in: card)
            let up = -speed.y
            if up > flick && up > abs(speed.x) {
                Log.write("win: gesture edge-middle flick up=" + String(Int(up))
                          + " -> close")
                requestClose("edge swipe up")
            } else {
                Log.write("win: gesture edge-middle not a flick up=" + String(Int(up))
                          + " vx=" + String(Int(speed.x)))
            }
        case .edgeCorner:
            let scale = card.bounds.height / max(natural.height, 1)
            let band = bandTop ? " top band" : " bottom band"
            Log.write("win: card resized " + size(card.bounds.size)
                      + " by corner, scale=" + String(format: "%.3f", scale) + band)
        case .interior:
            Log.write("win: card moved to " + point(card.frame.origin)
                      + " size=" + size(card.bounds.size))
        }
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let card = card, let window = window else { return }
        switch gesture.state {
        case .began:
            pressZone = zoneFor(gesture.location(in: card))
            pressStep = gesture.location(in: window)
            // A press that becomes a drag must not also drag the card: 长按+滑动
            // is a resize, and two recognizers fighting over one finger is how a
            // window ends up in two places at once.
            pan?.isEnabled = false
            switch pressZone {
            case .edgeMiddle:
                Log.write("win: gesture long press edge-middle, 切换横竖 not wired - "
                          + "no orientation write in this chain")
            case .edgeCorner:
                Log.write("win: gesture long press edge-corner, 重启 as geometry reset")
                resetToPlan(in: window.bounds)
            case .interior:
                Log.write("win: gesture long press interior, drag to resize")
            }
        case .changed:
            guard pressZone == .interior else { break }
            let total = gesture.location(in: window)
            let dy = total.y - pressStep.y
            pressStep = total
            resize(height: card.bounds.height + dy)
        case .ended, .cancelled, .failed:
            if pressZone == .interior {
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

/// A window that is only answerable where its content is. Everything else falls
/// through to the app underneath, which is what makes a floating card usable
/// while a full-screen app is running.
final class FloatWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
