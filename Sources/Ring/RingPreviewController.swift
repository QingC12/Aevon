//
//  RingPreviewController.swift — Aevon, the panel's disc preview.
//
//  0.0.42 — the preview now hosts the very same disc the desktop does: the
//  archived plugin's AevonRingMenu, presented into this controller's view with
//  its activate path intercepted. Before the port the preview rendered a
//  home-grown RingView, which meant "the preview looks right" proved nothing
//  about the desktop; now there is exactly one disc implementation in the
//  package and both sides show it.
//
//  What is intercepted: opening an app. A preview tap shows a toast and keeps
//  the disc up; on the desktop the same tap goes through SceneProbe's card
//  route. The animations — unfold, hover jump, halo, damping rotation — are
//  the real ones, because they are the real view.
//

import UIKit

final class RingPreviewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "承载形状 · 圆盘"

        let hint = UILabel()
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.textColor = .secondaryLabel
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.text = "松手落在图标上 → 这里只弹提示（真机才会开 App）；落在盘外或间隙 → 收起圆盘。按住圆心 1 秒进入旋转模式。"
        hint.frame = CGRect(x: 24, y: 70, width: view.bounds.width - 48, height: 60)
        hint.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        view.addSubview(hint)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // The one hook the menu can fire inside a preview: launch intercepted.
        // Cleared on the way out so a stale hook can never route a desktop tap
        // into a dead preview.
        AevonRingMenu.activateHook = { [weak self] icon in
            self?.showToast("预览选中：\(icon.displayName)")
            return true
        }

        let started = Date()
        AevonRingMenu.present(in: view)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        Log.write("prefs: ring preview icons=\(AevonRingStore.bundleIDs().count) "
                  + "in \(milliseconds)ms")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AevonRingMenu.dismissCurrent()
        AevonRingMenu.activateHook = nil
    }

    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0.08, alpha: 0.86)
        label.layer.cornerRadius = 12
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        let fitting = label.sizeThatFits(CGSize(width: view.bounds.width - 64, height: 60))
        label.frame = CGRect(x: (view.bounds.width - fitting.width - 36) / 2,
                             y: view.bounds.height - 140,
                             width: fitting.width + 36,
                             height: max(fitting.height + 18, 40))
        view.addSubview(label)
        label.alpha = 0
        UIView.animate(withDuration: 0.16, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.24, delay: 0.9,
                           animations: { label.alpha = 0 },
                           completion: { _ in label.removeFromSuperview() })
        }
    }
}
