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

        let card = UIView(frame: host.frameInWindow(window))
        card.backgroundColor = .clear
        card.layer.cornerRadius = host.corner
        card.layer.borderWidth = host.edge
        card.layer.borderColor = UIColor.white.cgColor
        card.clipsToBounds = true

        view.frame = CGRect(origin: .zero, size: card.bounds.size)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(view)
        root.addSubview(card)

        host.window = window
        host.card = card
        Log.write("win: card "
                  + String(format: "%.0fx%.0f", card.bounds.width, card.bounds.height)
                  + " at " + String(format: "%.0f,%.0f", card.frame.origin.x, card.frame.origin.y)
                  + " hosted=" + String(format: "%.0fx%.0f", view.bounds.width, view.bounds.height))
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

    /// Centred horizontally, a little below the top so the status bar and the
    /// notch stay clear, and never larger than the screen it lands on.
    private func frameInWindow(_ window: FloatWindow) -> CGRect {
        let bounds = window.bounds
        guard bounds.width > 64, bounds.height > 200 else {
            return CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        }
        let w = min(cardWidth, bounds.width - 32)
        let h = min(cardHeight, bounds.height - 160)
        return CGRect(x: (bounds.width - w) / 2, y: 120, width: w, height: h)
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
