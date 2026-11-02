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

private let darwinCallback: CFNotificationCallback = { _, _, name, _, _ in
    // Compare as CFString with CFEqual. Bridging CFNotificationName to a Swift
    // String is not available on this toolchain, and the name is only ever
    // compared, never printed.
    let isPreferences = name.map { CFEqual($0, Aevon.notePrefs as CFString) } ?? false

    // A setting changed. The snapshot file is already on disk (Settings writes
    // it before posting), so this is a re-read, not a command that can be lost.
    if isPreferences {
        DispatchQueue.main.async {
            RingHost.shared.refresh()
        }
        return
    }

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
    CFNotificationCenterAddObserver(center, nil, darwinCallback,
                                    Aevon.noteCommand as CFString, nil,
                                    .deliverImmediately)
    CFNotificationCenterAddObserver(center, nil, darwinCallback,
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
    }
}
