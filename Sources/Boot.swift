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

private func observeCommands() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterAddObserver(center, nil, commandCallback,
                                    Aevon.noteCommand as CFString, nil,
                                    .deliverImmediately)
    CFNotificationCenterAddObserver(center, nil, prefsCallback,
                                    Aevon.notePrefs as CFString, nil,
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
    scheduleStableReset()

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
