//
//  SceneActions.swift — Aevon, the one thing the 窗口与场景 panel can *do*.
//
//  The probe has to run in SpringBoard: that is the process that owns the real
//  scene tree. Settings cannot measure it, and dumping Settings' own two scenes
//  would be a convincing wrong answer — so this file only drops a request and
//  asks the host to wake up.
//
//  Nothing here is written into the preference domain: a request is a file,
//  deleted by whoever consumes it, which makes "exactly one probe per tap"
//  free instead of a flag somebody has to remember to clear.
//

import UIKit

enum SceneActions {

    static func probeScene(from controller: UIViewController) {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        let wrote = (try? stamp.write(toFile: Aevon.probePath, atomically: true,
                                     encoding: .utf8)) != nil
        if wrote {
            // Same note the host already listens to: no new observer, no new
            // failure mode.
            notifyPost(Aevon.notePrefs)
        }
        Log.write("prefs: scene probe requested -> " + (wrote ? "ok" : "write failed"))

        report(wrote, from: controller)
    }

    private static func report(_ ok: Bool, from controller: UIViewController) {
        let title = ok ? "已请求场景探针" : "请求失败"
        let message = ok
            ? "SpringBoard 会在一秒内把场景树写进 /var/mobile/Aevon.log，"
            + "以 scene: 开头。这次转储只发生一次，不会在下次开机重放。"
            : "无法写入 " + Aevon.probePath + "，请检查该目录权限。"
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
        controller.present(sheet, animated: true)
    }
}
