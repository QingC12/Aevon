//
//  Boot.swift — Aevon, SpringBoard side.
//
//  Entry point is called from AevonBoot.m (three lines of C: a constructor
//  cannot be written in Swift, and a dylib needs one). Everything after that
//  is Swift.
//
//  INVARIANT, do not break:
//    Nothing may run before Gate.evaluate() returns .pass. This dylib must
//    never be the reason a phone cannot boot.
//

import Foundation
import CoreFoundation

/// `AevonScene.m` 里的 C 函数，只此一处声明。写成 `@_silgen_name` 而不是桥接头
/// 文件：这个工程没有 Umbrella header，而两个名字是全部要交换的东西。
@_silgen_name("AevonInstallTouchTap")
private func AevonInstallTouchTap()

/// 0.2.63 — 落点钩子（`_openURLCore:display:…`）。**必须在开机这一拍装**：
/// `AevonHookInstall()` 是建第一张卡时才调用的，而这条钩子要管的正是「第一张卡
/// 还不存在」的那一刻。装晚一步，系统那次 URL 打开已经过去了。
@_silgen_name("AevonLandingBoot")
private func AevonLandingBoot()

// Two notifications, two callbacks. Deciding "which notification is this" by
// comparing the name needs a CFString -> String bridge that this toolchain
// refuses (CFNotificationName is not class-constrained here), so the name is
// never inspected at all: the observer registration already says what it is.
private let prefsCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        RingHost.shared.refresh()
        // A probe request rides the same note: Settings drops a file, this
        // process owns the scene tree. One shot, then the file is gone.
        SceneProbe.consumeRequest()
    }
}

private let commandCallback: CFNotificationCallback = { _, _, _, _, _ in
    guard let command = Gate.takePendingCommand() else { return }

    switch command {
    case Aevon.commandRespring:
        if !Spawn.respring() {
            Log.write("respring request failed: no usable helper")
        }

    case Aevon.commandReset:
        Gate.resetAttempts()
        Log.write("reset: attempt counter cleared from Settings")

    default:
        Log.write("command ignored: \(command)")
    }
}

/// 0.2.75 — 闸动了。
///
/// 这道回调是「紧急停止」真正落地的地方。以前设置侧改完 G0/G1 只写文件与偏好，
/// 这一侧既不收通知、也没有任何复查点，于是用户看到的是开关打勾、行为照旧。
private let gateCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        gateApply("note")
    }
}

/// 复查闸，并在它为「关」时把浮窗与圆盘一起收掉。
///
/// 为什么停手要收窗口，而不是只让 `sendEvent:` 放行：放行只是把手指还给系统，
/// 窗口本身还盖在屏幕上 —— 触摸会正常派发，落点却是我们的空窗口，那一块照样
/// 是死的。用户要的是「这个插件现在别管事」，那就得把它从屏幕上撤走。
///
/// 刻意不 respring：G0 的意义是「不重启也能马上停下来」。真要重启，设置页有
/// 单独的命令。
private func gateApply(_ why: String) {
    let off = Gate.refreshRuntime(why)
    guard off else {
        // 解闸：圆盘按用户自己的开关重新评估，卡片不自动复活（谁关的就谁开）。
        RingHost.gateStopped = false
        RingHost.shared.refresh()
        Log.write("gate: released why=\(why)")
        return
    }
    RingHost.gateStopped = true
    RingHost.shared.refresh()
    let cards = FloatHost.standDownAll("gate stopped")
    Log.write("gate: stand down why=\(why) cards=\(cards) ring=0 touch=0")
    SceneProbe.gateSnapshot(why: why, cards: cards)
}

private func observeCommands() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterAddObserver(center, nil, commandCallback,
                                    Aevon.noteCommand as CFString, nil,
                                    .deliverImmediately)
    CFNotificationCenterAddObserver(center, nil, prefsCallback,
                                    Aevon.notePrefs as CFString, nil,
                                    .deliverImmediately)
    CFNotificationCenterAddObserver(center, nil, gateCallback,
                                    Aevon.noteGate as CFString, nil,
                                    .deliverImmediately)
}

/// One shot, 60 s after a successful load: if the process is still alive the
/// crash counter is meaningless, so clear it.
private func scheduleStableReset() {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Gate.stableDelay) {
        if Gate.panicActive || Gate.disabledActive { return }   // never resurrect behind the operator's back
        var state = Gate.readState()
        state["attempts"] = 0
        state["stableSince"] = Date().timeIntervalSince1970
        Gate.writeState(state)
        Log.write("heartbeat: \(Int(Gate.stableDelay))s uptime reached, attempt counter cleared")
    }
}

@_cdecl("AevonStart")
public func AevonStart() {
    guard case .pass = Gate.evaluate() else { return }

    Log.write("boot ok: version \(Aevon.version), pid \(getpid())")

    // 0.2.91 — 上一次是被哪一步带走的。
    //
    // 这两份标记只在进程被信号杀掉时才留得下来（正常走完自己删）。所以开机
    // 读到它们 = 上一次没走完，名字就是断点。Aevon(223) 那三次连崩里一句
    // 线索都没有，正是因为那一下死在写日志之前 —— 这一行就是补上的那句话。
    //
    // 0.2.92 — 加判定后缀。0.2.91 那版在正常收尾时把 `act.step` 写成**空串**，
    // 于是「崩在写日志之前」和「什么都没发生」长得一模一样，Aevon(224) 就栽在
    // 这上面（读到 `step=-`，其实不是没有断点，是断点被自己擦掉了）。现在正常
    // 收尾写具体终态名，开机就知道该不该当事故看。
    let settledSteps: Set<String> = ["sig:done", "birth:wrote", "birth:immutable",
                                     "birth:noset", "birth:noframe", "birth:small",
                                     "birth:threw"]
    let stepFiles: [(path: String, label: String)] = [
        (Aevon.urlStepPath, "url"),
        (Aevon.actStepPath, "act"),
    ]
    for entry in stepFiles {
        guard let raw = try? String(contentsOfFile: entry.path, encoding: .utf8) else { continue }
        let step = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict: String
        if step.isEmpty {
            verdict = "-"
        } else if settledSteps.contains(step) {
            verdict = "\(step) (settled)"
        } else {
            verdict = "\(step) (INTERRUPTED)"
        }
        Log.write("boot: last \(entry.label) step=\(verdict)")
        try? FileManager.default.removeItem(atPath: entry.path)
    }


    // 0.1.93 — 主线程心跳。Aevon(161) 最后三十五分钟一行日志都没有：手指按在
    // 屏幕上，`sendEvent` 一次都没再被调用。那种「什么都停了」有两种完全不同的
    // 成因 —— 主线程被卡死，或者窗口根本收不到触摸 —— 而日志上长得一模一样。
    // 这个看门狗在后台队列上每秒问主线程一次「你还在吗」：主线程真卡了，它会
    // 从后台直接写一行 `win: main stall …ms`（不走 `Log.write`，那条路的日期
    // 格式化器不是线程安全的）；心跳照常在写、只是没有触摸，就说明卡的不是主线程。
    Aevon.version.withCString { AevonMainStallWatchdogStart($0) }

    // 0.1.8 — 上一次留下的停靠标记。桌面进程崩掉时标记会留在 App 容器里，那个
    // App 从此收不到触摸；这一拍按名单清干净。个数写进启动日志，下次看日志就能
    // 分清「没清过」和「清了几条」。
    Log.write("boot mini flags cleared \(AevonAppMiniFlagsClearAll())")

    // 0.0.48 — 浮窗的手指入口。装在 `-[UIApplication sendEvent:]` 上，理由写在
    // AevonScene.m 那一段的注释里：四份日志证明「窗口会不会被问到」不可靠，而
    // 这个方法是每一个触摸都必经的地方。装不上就只是退回旧行为，不会弄坏触摸。
    AevonInstallTouchTap()

    // 0.1.40 — 通知点击开浮窗。挂 `SBMainWorkspace -executeTransitionRequest:`，
    // 认的是 action 的类名而不是母本那套 Swift 方法名（方法名被 strip，猜等于赌）。
    //
    // 0.1.41 — 这里原来还有 `AevonKeyboardHostInstall()`，撤了。它在 SpringBoard
    // 里遍历窗口树并把「类名带 Keyboard」的视图按全屏 bounds 摆正，0.1.40 真机
    // 第一下点输入框就进了安全模式（`__NSMallocBlock__ countByEnumerating...`）。
    // 母本 `SthenoKb.dylib` 注入 SpringBoard 却连 UIView 都没导入 —— 键盘几何
    // 全在键盘进程（`AevonAppHook.m` 的 `AevonKbNativeInstall`），这里不该有活。
    AevonNotificationOpenInstall()

    // 0.2.5 — 清通知改「截对象」。老路是从动作对象反推标识再去各宿主里比对，
    // 真机 6/6 `clear=noid`（猜标识这件事本身走不通，不是 getter 没试全）。
    // 这一条挂的是系统的通知动作入口，第三个参数就是 `NCNotificationRequest` 本体，
    // 直接拿对象去 withdraw。钩子只登记、原样转发，不改变通知的任何行为；
    // 类不存在时它自己 3 秒后重试（通知栈懒加载）。
    AevonNotificationCaptureInstall()

    // 0.2.63 — 落点：系统的 URL 打开入口带一个 `display` 参数，要进卡片的那个
    // App 传 NO。放在这里而不是 `openCard` 里，理由写在 `AevonLandingBoot` 上。
    AevonLandingBoot()

    // 0.1.85 — 通知点击观察器。**只取证，不接管**：挂的是 SpringBoard 的
    // App 激活总入口，替身只读一遍参数、原样转发、写一行日志。
    // 装配的三道前置闸在这里，钩子自己的两道在 AevonScene.m 里；六道闸的
    // 分工与理由写在 Sources/Scene/ActivateProbe.swift 的文件头。
    ActivateProbe.arm()

    // Before anything else touches the runtime: if a probe left a death marker
    // behind, name the class that stopped it and blacklist it. This is the only
    // way a probe that killed SpringBoard can be read instead of guessed at.
    SceneProbe.reportPreviousDeath()
    observeCommands()
    // 0.2.75 — 运行期闸的初值。走到这一行 `evaluate()` 已经 pass，所以它必然
    // 记成 `off=0`；这一句的价值是给日志一个锚点：排查时先看 `runtime armed`
    // 在不在，再看后面有没有 `runtime off` —— 两行就能分清「闸没接上」和
    // 「闸接了但没人动它」。
    Gate.refreshRuntime("boot")
    scheduleStableReset()

    // 0.2.80 — Stheno 的 presenter 路线开工前先取证。
    //
    // 这一步只读：问类在不在、选择子定义在哪个类上、真实类型编码是什么。
    // 一个未知选择子都不调，一个 presenter 都不建。产出（`presenter: …` 那些行）
    // 决定 P1 怎么写 —— 权限表里的每个字段都是 SpringBoard 崩不崩的分界线。
    // 每个版本只跑一次，标记文件带版本号，重启不重放。
    SceneProbe.presenterCensusOnce()

    // ---------------------------------------------------------------------
    // The carrier shape, hosted in SpringBoard.
    //
    // Deferred: a constructor runs while SpringBoard is still assembling its
    // scene, and a window created then can end up without one. Two seconds is
    // after the home screen exists and before anyone reaches for the corner.
    //
    // Everything it does is gated again inside RingHost: the "!" switch off
    // means no window at all, and a closed switch removes an open one.
    // ---------------------------------------------------------------------
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        RingHost.shared.refresh()
        Log.write("ring: mount pass done, desktop=\(RingHost.shared.isEnabled)")
        // Second chance for a probe: the request may have been written while
        // this process was still coming up and the note went nowhere.
        SceneProbe.consumeRequest()
    }
}
