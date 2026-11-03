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
/// 0.0.33 — the card became furniture. Aevon(31) closed the last open question
/// on the chain (picture, hand-back, no respring), so the eight second probe
/// that proved it is gone and the card now stays until it is closed, moved or
/// resized. Nothing below touches the scene: drag and pinch move the card, the
/// close button calls back into the teardown that already hands the scene back.
final class FloatHost: NSObject {
    static let shared = FloatHost()

    private var window: FloatWindow?
    private var card: UIView?
    private var content: UIView?
    private var close: UIControl?
    private var onClose: (() -> Void)?
    /// The scene's own size. Every resize is this shape, scaled — the card never
    /// gets an aspect the picture does not have.
    private var natural: CGSize = .zero
    private var pinchStart: CGSize = .zero

    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 480
    private let corner: CGFloat = 12
    private let edge: CGFloat = 2
    private let margin: CGFloat = 8
    private let minWidth: CGFloat = 140
    private let closeSize: CGFloat = 30

    var level: CGFloat { window?.windowLevel.rawValue ?? 0 }

    /// Answers a host only when the window is really up and really holds the
    /// view. A nil answer means "activate nothing": a presenter whose view is
    /// not in a window is 0.0.20's black screen, and that is not worth one more
    /// phone.
    static func show(_ view: UIView, onClose: @escaping () -> Void) -> FloatHost? {
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
        let hook = onClose
        onClose = nil
        Log.write("win: close tapped")
        DispatchQueue.main.async { hook?() }
    }

    // MARK: - drag and resize

    private func installGestures(on card: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        card.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        card.addGestureRecognizer(pinch)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let card = card, let window = window else { return }
        let step = gesture.translation(in: window)
        var frame = card.frame
        frame.origin.x += step.x
        frame.origin.y += step.y
        card.frame = clamped(frame, in: window.bounds)
        gesture.setTranslation(.zero, in: window)
        // Only the end of a drag is worth a line: a drag emits dozens of events
        // and the log is the thing that has to stay readable at 250 ms a beat.
        if gesture.state == .ended || gesture.state == .cancelled {
            Log.write("win: card moved to " + point(card.frame.origin)
                      + " size=" + size(card.bounds.size))
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let card = card, let window = window,
              natural.width > 16, natural.height > 16 else { return }
        if gesture.state == .began {
            pinchStart = card.bounds.size
            return
        }
        guard gesture.state == .changed || gesture.state == .ended else { return }

        let ratio = natural.width / natural.height
        var w = pinchStart.width * gesture.scale
        w = min(max(w, minWidth), max(minWidth, window.bounds.width - 32))
        var h = w / ratio
        let tallest = max(120, window.bounds.height - 160)
        if h > tallest {
            h = tallest
            w = h * ratio
        }
        card.bounds = CGRect(origin: .zero, size: CGSize(width: w, height: h))
        let scale = h / natural.height
        content?.center = CGPoint(x: w / 2, y: h / 2)
        content?.transform = CGAffineTransform(scaleX: scale, y: scale)
        card.frame = clamped(card.frame, in: window.bounds)

        if gesture.state == .ended {
            Log.write("win: card resized " + size(card.bounds.size)
                      + " scale=" + String(format: "%.3f", scale))
        }
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
