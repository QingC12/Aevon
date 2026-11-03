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

    // 0.0.48 — 浮窗的手指入口。装在 `-[UIApplication sendEvent:]` 上，理由写在
    // AevonScene.m 那一段的注释里：四份日志证明「窗口会不会被问到」不可靠，而
    // 这个方法是每一个触摸都必经的地方。装不上就只是退回旧行为，不会弄坏触摸。
    AevonInstallTouchTap()

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
