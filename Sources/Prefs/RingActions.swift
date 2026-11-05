//
//  RingActions.swift — Aevon, the three things the Ring panel can *do*.
//
//  Kept in one place because both pages need them: the root page has the
//  preview button, and the Ring panel has preview / edit apps / reset grip.
//  Before this file the panel's preview button pointed at a selector only the
//  root controller implemented, so it silently did nothing — the same class of
//  bug as the dead rows in 0.0.5, one layer down.
//
//  Every action here is harmless by construction:
//    · preview    hosts the real disc (AevonRingMenu) with launch intercepted
//    · edit apps  edits the store the disc reads (AevonRingStore)
//    · reset grip deletes one file and asks the host to re-read
//

import UIKit

enum RingActions {

    /// Full-screen preview. It is the real disc with the real animations —
    /// a test, not a mock-up.
    static func preview(from controller: UIViewController) {
        let preview = RingPreviewController()
        controller.present(preview, animated: true)
    }

    /// Add / remove / reorder. Pushed rather than presented when there is a
    /// navigation stack, so 返回 behaves like every other page in Settings.
    static func editApps(from controller: UIViewController) {
        let list = AppListController()
        if let navigation = controller.navigationController {
            navigation.pushViewController(list, animated: true)
        } else {
            controller.present(UINavigationController(rootViewController: list),
                               animated: true)
        }
        Log.write("prefs: open app list")
    }

}
