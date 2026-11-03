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
//    · preview    reads values, writes nothing
//    · edit apps  edits one file under /var/mobile/Library/Logs/Aevon
//    · reset grip deletes one file and asks the host to re-read
//

import UIKit

enum RingActions {

    /// Full-screen preview. Everything on it comes from the panel's live
    /// values, so it is a test, not a mock-up.
    static func preview(from controller: UIViewController) {
        let started = Date()
        let config = RingConfig.load()
        let loaded = RingApps.resolved(limit: RingApps.maxCount)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        Log.write("prefs: ring preview icons=\(loaded.apps.count) "
                  + "rings=\(config.ringCount(for: loaded.apps.count)) "
                  + "source=\(loaded.source.rawValue) in \(milliseconds)ms")

        let preview = RingPreviewController(config: config,
                                            apps: loaded.apps,
                                            source: loaded.source)
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

    /// Back to the corner. Deleting layout.plist is the whole signal; the host
    /// notices on the notification and re-lays out from the default.
    static func resetGrip(from controller: UIViewController) {
        let ok = GripLayout.reset()
        notifyPost(Aevon.notePrefs)
        Log.write("prefs: grip reset -> \(ok ? "ok" : "failed")")
        if !ok {
            let sheet = UIAlertController(title: "复位失败",
                                          message: "无法删除 \(Aevon.layoutPath)，"
                                                 + "请检查该目录权限。",
                                          preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
            controller.present(sheet, animated: true)
        }
    }
}
