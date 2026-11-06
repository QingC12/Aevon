//
//  ActivateProbe.swift — Aevon, SpringBoard side.
//
//  0.1.85 — 「通知点击 → 浮窗」的第一步：**只取证，不接管**。
//
//  为什么这一步单独一版：stheno 的正解是 SpringBoard 的 App 激活总入口
//
//      SBMainWorkspace -_activateBundleID:requestID:isTrusted:options:
//                       source:originalSource:withResult:
//
//  它每一行都在决定「这个 App 要不要起来」。0.1.40~0.1.45 在这条路上已经
//  失败过五次（`_executeTransitionRequest:` 挂上了但零调用、三个「通知」类
//  在 SpringBoard 里根本不存在），而每一次失败都是靠一份真机日志才认出来的。
//  所以这一版不写任何行为判定：钩子进去只读一次参数、写一行日志、原样转发。
//
//  这道口子的危险不在「写错一个 if」，而在「装上去之后才发现形状不对」。
//  因此装配前后一共六道闸，任何一道不成立就什么都不做：
//
//    闸一 · 存在性   类或方法不在 ⇒ 不装，并把 `activate` / `bundle` 的真名
//                    列出来（下一版按真名改，不按名字赌）。
//    闸二 · 参数形状 对象参数必须正好 6 个。差一个就是错位调用 —— 那是
//                    SpringBoard 的崩溃，不是一行日志。0.0.53 已经在这上面
//                    吃过一次：`AevonObjectArgs` 数错，两个候选一个都没装上，
//                    而日志看起来一切正常。
//    闸三 · 方法归属 必须由 `SBMainWorkspace` 自己实现。`class_getInstanceMethod`
//                    会沿父类链找，改到父类上等于同时改了所有兄弟类。
//    闸四 · 启动闩   装配前写 `notify.armed`，活到 180 秒才摘。它还在 ⇒ 上一次
//                    就是死在这条钩子上 ⇒ 这次不装，并落下 `notify.off`。
//    闸五 · 调用预算 最多 60 行，然后闭嘴（钩子留着，只是不再取证）。
//    闸六 · 延迟装载 装载后 3 秒才装。那时主屏已经在，`AevonStart` 里任何一行
//                    都不可能再是「开不了机」的原因。
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
