//
//  ActivateProbe.swift — Aevon, SpringBoard side.
//
//  0.1.88 — 「通知点击 → 浮窗」：**第一次真的改行为**。
//
//  0.1.85 找错了名字（`_activateBundleID:…` 在这台机器上不存在），0.1.86 用只读
//  普查把真名列了出来，0.1.87 按真名装上去、只读、只转发，拿到了一份完整的现场：
//
//      notify: hit op=open      act=#UINotificationResponseAction n=1 req=com.tencent.mqq
//      notify: hit op=trusted   act=#UINotificationResponseAction n=1 req=com.tencent.mqq
//
//  于是这一版有三件事是确定的，不再是猜的：
//
//    · 点通知走 `SBMainWorkspace -_handleOpenApplicationRequest:…`，再进
//      `-_handleTrustedOpenRequestForApplication:…`；
//    · 「这是通知点击」的判据是 `options.__Actions.firstObject` 的类名含
//      `NotificationResponseAction`（同一天从分享面板打开 App 是同样两条，
//      但 `act=- n=0`，两者分得开）；
//    · 目标 bundle id 就在 `request` 自己身上（它就是那个字符串）。
//
//  所以这个替身第一次有了「不原样转发」的分支：认出是通知点击时，SpringBoard 那
//  一段（建 app layout、全屏推前台）整段跳过，改叫 `AevonOpenFromNotification`
//  → `SceneProbe.openCard` → 挂起启动 + 建卡片，和圆盘图标走同一条路。
//
//  危险面随之变大，所以闸也变多了，见 `AevonScene.m` 里 `AevonOpenDecide`：
//
//    闸一 · 开关   `notify.off` 在 ⇒ 一个字节都不改，行为和 0.1.87 完全一样。
//                  这一条每拍都查，不是只在装配那一刻查一次。
//    闸二 · 判据   类名必须含 `NotificationResponseAction`。点图标、分享面板、
//                  系统 URL 都不含，一律照旧全屏。
//    闸三 · 目标   取不到 bundle 或目标是 SpringBoard 自己 ⇒ 不接管。
//    闸四 · 兜底   吞掉之后 2.5 秒查 `AevonCardIsUpFor()`；卡片没起来就把原实现
//                  补调一次。判据是「卡片在不在」，不是「过了多久」。
//
//  装配侧的四道闸（存在 / 逐字节形状 / 归属 / 原实现）与两道时间闸（`notify.armed`
//  180 秒、装载后 3 秒）原样保留 —— 0.1.87 证明了它们能装上，也证明了它们没惹事。
//

import Foundation

/// `AevonScene.m` 里的 C 函数，只此一处声明。
@_silgen_name("AevonActivateProbeInstall")
private func AevonActivateProbeInstall()

/// `AevonScene.m` 的分流判定每一拍都要问一次「人关了没有」。
///
/// 只在装配那一刻查一次是不够的：`notify.off` 的语义是「现在别动我的 App 打开」，
/// 而人在发现不对劲之后建这个文件时，钩子已经在内存里跑着了。所以这条查询放在
/// 热路径上 —— 一次 `fileExists` 对一次 App 启动来说可以忽略。
@_cdecl("AevonActivateSwitchOff")
public func AevonActivateSwitchOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.activateOffPath) ? 1 : 0
}

enum ActivateProbe {

    /// 装上去之后活这么久，就算这个 IMP 本身不是死因。
    ///
    /// 180 秒是权衡，不是证据：一个写错的替换体死在**第一次被调用**上，而
    /// 装完三分钟内正常用机必然会有一次 App 激活。取更长会让「无关的一次
    /// 崩溃」也把这条口子关掉，取更短则可能一次都没验到。
    static let latchSeconds: Double = 180.0

    /// 装载后多久装钩子。2 秒是主屏的存在时间（`RingHost` 用同一个数）。
    static let installDelay: Double = 3.0

    /// 由 `AevonStart` 在 `Gate.evaluate()` 放行之后调用一次。
    static func arm() {
        let manager = FileManager.default

        // 闸四（前半）· 人关的。开关在就一个字节都不碰。
        if manager.fileExists(atPath: Aevon.activateOffPath) {
            Log.write("notify: activate off switch=notify.off")
            return
        }

        // 闸四（后半）· 上一次的闩还在。
        //
        // 闩在装配前写、活到 180 秒才摘，所以「下次启动还看得见它」只有一种
        // 解释：上一次装上去之后没活到摘闩。这时候最该做的不是再装一遍，
        // 而是把结论落下来并停手 —— 一份日志的价值远低于一台能开机的手机。
        if manager.fileExists(atPath: Aevon.activateArmedPath) {
            Log.write("notify: activate latch held, previous boot died while armed")
            try? manager.removeItem(atPath: Aevon.activateArmedPath)
            try? manager.createDirectory(atPath: Aevon.stateDir,
                                         withIntermediateDirectories: true)
            manager.createFile(atPath: Aevon.activateOffPath, contents: Data())
            return
        }

        try? manager.createDirectory(atPath: Aevon.stateDir,
                                     withIntermediateDirectories: true)
        try? Aevon.version.write(toFile: Aevon.activateArmedPath,
                                 atomically: true, encoding: .utf8)
        Log.write("notify: activate arm scheduled in \(Int(installDelay))s")

        // 闸六 · 延迟装载。
        DispatchQueue.main.asyncAfter(deadline: .now() + installDelay) {
            AevonActivateProbeInstall()
        }

        // 闸四（收尾）· 松闩。到点还活着，说明装配与这个 IMP 都不致命。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + latchSeconds) {
            guard manager.fileExists(atPath: Aevon.activateArmedPath) else { return }
            try? manager.removeItem(atPath: Aevon.activateArmedPath)
            Log.write("notify: activate latch cleared uptime=\(Int(latchSeconds))s")
        }
    }
}
