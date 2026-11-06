//
//  ActivateProbe.swift — Aevon, SpringBoard side.
//
//  0.1.87 — 「通知点击 → 浮窗」的取证：**只读，不接管**。
//
//  落点是 0.1.86 的真机普查定的，不是猜的。母本那条
//
//      SBMainWorkspace -_activateBundleID:requestID:isTrusted:options:
//                       source:originalSource:withResult:
//
//  在真机上 `no-method`（0.1.85 的日志）。普查把 `activ` 系全列出来后，真身是
//  SBMainWorkspace 自己实现的四条**同形状**方法：
//
//      _handleOpenApplicationRequest:options:activationSettings:origin:withResult:
//      _handleUntrustedOpenRequestForApplication:options:...
//      _handleTrustedOpenRequestForApplication:options:...
//      _handleUserActionRequest:options:...
//
//  四条编码逐字相同（`v56@0:8@16@24@32@40@?48`，5 参数 + 结果块）。这一版把
//  四条一起装成观察器：读一遍参数、原样转发、异步写一行日志，不写行为判定。
//  它们每一行都在决定「这个 App 要不要起来」，所以闸必须硬，见 `AevonScene.m`
//  里 `AevonActivateProbeInstall` 的四道闸（存在 / 逐字节形状 / 归属 / 原实现）。
//
//  这道口子的危险不在「写错一个 if」，而在「装上去之后才发现形状不对」。
//  装配侧的闸（存在 / 逐字节形状 / 归属 / 原实现）在 `AevonScene.m` 里；这一侧
//  负责剩下的两道：
//
//    闸四 · 启动闩   装配前写 `notify.armed`，活到 180 秒才摘。它还在 ⇒ 上一次
//                    就是死在这条钩子上 ⇒ 这次不装，并落下 `notify.off`。
//    闸六 · 延迟装载 装载后 3 秒才装。那时主屏已经在，`AevonStart` 里任何一行
//                    都不可能再是「开不了机」的原因。
//
//  调用预算（四条合计 32 行）在替身里。
//
//  这六道之外还有一条不写在代码里、写在顺序里的：**快照在原实现之前，落盘在原
//  实现之后**。快照只读、不分配、不写盘 —— 它不改任何参数，所以系统那一段照旧
//  原样跑；落盘走主队列异步，那 0.1~0.3 ms 不该压在「点开 App」那一拍上。
//

import Foundation

/// `AevonScene.m` 里的 C 函数，只此一处声明。
@_silgen_name("AevonActivateProbeInstall")
private func AevonActivateProbeInstall()

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
