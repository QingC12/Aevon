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
        request("tree", from: controller, title: "已请求场景探针")
    }

    /// Second dump: the call surface P1 needs, not the tree. Kept as its own
    /// button because it is the one probe that messages FrontBoard, and a
    /// measurement that can crash SpringBoard should not be reachable by the
    /// button an operator taps first.
    static func probeSurface(from controller: UIViewController) {
        request("api", from: controller, title: "已请求接口面探针")
    }

    /// Third dump: the master's own calls, resolved to a defining class on this
    /// iOS. This is the one that has to match the reverse notes before a window
    /// is created — a call that lands on the wrong class is worse than a call
    /// that is missing, because it can still return something.
    static func probeCalls(from controller: UIViewController) {
        request("calls", from: controller, title: "已请求调用点核对")
    }

    /// Fourth mode: read a live scene, then try to create one. Two phases in the
    /// same run because the second is worthless without the first: the payload
    /// it needs is a copy of what phase 1 just printed. This is the only button
    /// that writes to FrontBoard, so its sheet says so before anything happens.
    static func probeWindow(from controller: UIViewController) {
        request("window", from: controller, title: "已请求建窗取证")
    }

    private static func request(_ mode: String, from controller: UIViewController, title: String) {
        // The file is written here, not through SceneProbe: that type lives in
        // the tweak target only, and asking Settings to reach into SpringBoard's
        // code is how you end up compiling the whole carrier into this bundle.
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        let wrote = (try? mode.write(toFile: Aevon.probePath, atomically: true,
                                     encoding: .utf8)) != nil
        if wrote {
            // Same note the host already listens to: no new observer, no new
            // failure mode.
            notifyPost(Aevon.notePrefs)
        }
        Log.write("prefs: scene probe requested -> " + mode + " " + (wrote ? "ok" : "write failed"))
        report(wrote, mode: mode, title: title, from: controller)
    }

    private static func report(_ ok: Bool, mode: String, title: String,
                               from controller: UIViewController) {
        let message: String
        if !ok {
            message = "无法写入 " + Aevon.probePath + "，请检查该目录权限。"
        } else if mode == "window" {
            message = "两步依次执行：先把现有场景的 definition / settings / clientSettings "
                + "写进 /var/mobile/Aevon.log，再用它们的副本尝试建一个新场景。"
                + "第二步会真的向系统注册场景，失败时 SpringBoard 可能注销一次——"
                + "第一步的数据在此之前已经落盘，重开机后照样能读。"
        } else {
            message = "SpringBoard 会在一秒内把结果写进 /var/mobile/Aevon.log。"
                + "这次转储只发生一次，不会在下次开机重放。"
        }
        let sheet = UIAlertController(title: ok ? title : "请求失败",
                                      message: message, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
        controller.present(sheet, animated: true)
    }
}
