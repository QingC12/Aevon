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
final class FloatHost {
    static let shared = FloatHost()

    private var window: FloatWindow?
    private var card: UIView?

    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 480
    private let corner: CGFloat = 12
    private let edge: CGFloat = 2

    var level: CGFloat { window?.windowLevel.rawValue ?? 0 }

    /// Answers a host only when the window is really up and really holds the
    /// view. A nil answer means "activate nothing": a presenter whose view is
    /// not in a window is 0.0.20's black screen, and that is not worth one more
    /// phone.
    static func show(_ view: UIView) -> FloatHost? {
        let host = shared
        host.teardown()
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
        guard let window = window else { return }
        for sub in card?.subviews ?? [] { sub.removeFromSuperview() }
        card?.removeFromSuperview()
        card = nil
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
