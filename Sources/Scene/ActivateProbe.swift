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
//  0.1.89 补的是「点完之后没人收场」：真机日志证明五条通知全部进了浮窗、一次 replay
//  都没有，但通知中心不关、横幅不收。原因不是漏写，是 0.1.88 那个「不转发」的代价 ——
//  收面板与收横幅本来挂在 SpringBoard 那段收尾里。所以分流之后 0.45 秒补一次收尾，
//  实现与闸都在 `AevonScene.m` 的 `AevonNotifyCleanup`；这一侧一行都没动。
//
//  0.1.90 修的是 0.1.89 那次收尾自己的两处错（Aevon(157)）：横幅收了、面板一次都没收，
//  三次 `cover=locked` 一次 `cover=down`。
//
//    · `SBLockScreenManager.isUILocked` **不能当锁屏闸**：通知中心（CoverSheet）就是锁屏
//      那一套 UI，它在屏时这一位本来就是 1 —— 这个闸在唯一该收的场景里恒为真，等于把功能
//      关掉。改用 `isPasscodeLocked`（真要用密码才拦），并配一条更硬的判据见下。
//    · 收面板不能定时，要**等卡片**：真机上分流那一拍到卡片真正在隔着 2~3 秒，0.45 秒
//      就收会露出两三秒空白桌面。改成 0.15 秒一拍、最多 24 拍轮询 `AevonCardIsUpFor()`，
//      卡片在的那一拍收面板。卡片没起来就不收 —— 真锁屏时挂起启动起不来，卡片自然不会
//      出现，锁这件事就不用单独去猜。
//    · 形状闸的比较键写错了：`@?`（块）归一化后与 `@` 不同，于是 `v@:BB@?` 永远不等于
//      候选表里的 `v@:BB@`，六个候选一次都没进过闸。0.1.90 把 `@?` 折叠成 `@`，并把
//      六个候选的真实编码在开机后第一次收尾时打一行 `notify: cover sels …`。
//
//  0.1.91 只调速度，不碰判据。Aevon(158) 证明收面板这条链通了（四次点击四次
//  `cover=ok:`，其中三次 `wait=0`），慢的是 0.45 秒起始延迟 + 0.15 秒节拍：
//
//    · 起始延迟 0.45 → 0.10 秒，节拍 0.15 → 0.04 秒（`AEVON_CLEAN_DELAY` / `_POLL`）。
//    · 冷启动时卡片要等 scene 才占槽（0.1~0.5 秒），干等那半秒就是用户说的「慢」。
//      所以给「卡在路上」单开一个出口：`AevonCardIsComingFor`（`openCard` 进门就登记，
//      3 秒过期）答 1 且已等满 0.3 秒 ⇒ 也收，面板自己那 0.35 秒下滑正好盖住卡片落地。
//    · `openCard` 压根没接手（真锁屏 / 开卡失败）时两位都答 0 ⇒ 一拍都不收，
//      最多问到 3.6 秒 —— 0.1.90 的安全判据原样保留。
//    · 日志多了 `at=`（手指 → 面板开始走，毫秒）与 `f=1`（在「卡在路上」时收的）。
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
