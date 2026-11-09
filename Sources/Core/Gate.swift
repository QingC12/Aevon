//
//  Gate.swift — Aevon
//
//  The safety model, in one place. Nothing above the gate check may execute:
//  no hook, no spawn, no allocation of anything that survives the process.
//
//    G0  panic      panic file exists  OR  pref(panic)          == true
//    G1  disabled   state.disabled     OR  pref(disabled)       == true
//    G2  crash loop more than 3 loads inside 300 s -> self-disable
//
//  Why two sources for G0/G1: the tweak runs in SpringBoard (may write files,
//  may not reach cfprefsd), the bundle runs in Settings (the opposite). The
//  answer is always the OR of both, so either side alone can stop the tweak.
//

import Foundation

public enum Verdict: Equatable {
    case pass
    case panic
    case disabled
    case crashLoop
    case unwritable
}

public enum Gate {

    /// A false positive only means "a tweak switched itself off".
    /// A false negative means one more crash loop. Bias towards false positives.
    static let maxAttempts = 3
    static let crashWindow: TimeInterval = 300
    static let stableDelay: TimeInterval = 60

    // MARK: Preferences (always available, both processes)

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: Aevon.domain)
    }

    private static var legacyDefaults: UserDefaults? {
        UserDefaults(suiteName: Aevon.legacyDomain)
    }

    public static func prefBool(_ key: String) -> Bool {
        if defaults?.bool(forKey: key) == true { return true }
        if legacyDefaults?.bool(forKey: key) == true { return true }
        return false
    }

    public static func setPrefBool(_ key: String, _ on: Bool) {
        guard let store = defaults else { return }
        if on {
            store.set(true, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    // MARK: State file

    public static func readState() -> [String: Any] {
        if let state = NSDictionary(contentsOfFile: Aevon.statePath) as? [String: Any] {
            return state
        }
        if let legacy = NSDictionary(contentsOfFile: Aevon.legacyStatePath) as? [String: Any] {
            return legacy
        }
        return [:]
    }

    @discardableResult
    public static func writeState(_ state: [String: Any]) -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        return (state as NSDictionary).write(toFile: Aevon.statePath, atomically: true)
    }

    // MARK: G0 / G1

    public static var panicActive: Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: Aevon.panicPath) { return true }
        if manager.fileExists(atPath: Aevon.legacyPanicPath) { return true }
        // "!gate.panic" is the raw specifier key: if the settings controller
        // ever falls through to the default write path, the value still lands
        // somewhere the gate looks at. Cheap insurance, one line.
        return prefBool("panic") || prefBool("!gate.panic")
    }

    public static var disabledActive: Bool {
        if (readState()["disabled"] as? NSNumber)?.boolValue == true { return true }
        return prefBool("disabled") || prefBool("!gate.disabled")
    }

    public static func setPanic(_ on: Bool) {
        setPrefBool("panic", on)
        let manager = FileManager.default
        if on {
            try? manager.createDirectory(atPath: Aevon.stateDir,
                                         withIntermediateDirectories: true)
            manager.createFile(atPath: Aevon.panicPath, contents: Data())
        } else {
            try? manager.removeItem(atPath: Aevon.panicPath)
            try? manager.removeItem(atPath: Aevon.legacyPanicPath)
        }
    }

    // MARK: 分流文件闸（0.2.60 起有界面开关）

    /// `notify.off` 存在 = 通知那条路整个不接管。界面上的开关是它的反面
    /// （「通知点开进浮窗」开 = 文件不在），这里只暴露事实，取反在控制器里做。
    public static var notifyOffActive: Bool {
        FileManager.default.fileExists(atPath: Aevon.activateOffPath)
    }

    /// `share.off` 存在 = 分享面板那条路不接管。
    public static var shareOffActive: Bool {
        FileManager.default.fileExists(atPath: Aevon.shareOffPath)
    }

    public static func setNotifyOff(_ off: Bool) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: Aevon.stateDir,
                                     withIntermediateDirectories: true)
        if off {
            manager.createFile(atPath: Aevon.activateOffPath, contents: Data())
        } else {
            try? manager.removeItem(atPath: Aevon.activateOffPath)
        }
    }

    public static func setShareOff(_ off: Bool) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: Aevon.stateDir,
                                     withIntermediateDirectories: true)
        if off {
            manager.createFile(atPath: Aevon.shareOffPath, contents: Data())
        } else {
            try? manager.removeItem(atPath: Aevon.shareOffPath)
        }
    }

    public static func setDisabled(_ on: Bool, reason: String) {
        setPrefBool("disabled", on)
        var state = readState()
        state["disabled"] = on
        if on {
            state["disabledReason"] = reason
            state["disabledAt"] = Date().timeIntervalSince1970
        } else {
            state.removeValue(forKey: "disabledReason")
            state.removeValue(forKey: "disabledAt")
            state["attempts"] = 0
        }
        writeState(state)
    }

    /// Clears the crash counter on both sides of the channel.
    public static func resetAttempts() {
        var state = readState()
        state["attempts"] = 0
        state.removeValue(forKey: "disabledReason")
        state.removeValue(forKey: "disabledAt")
        if (state["disabled"] as? NSNumber)?.boolValue == true { state["disabled"] = false }
        writeState(state)
        setPrefBool("disabled", false)
        setPrefBool("!gate.disabled", false)
    }

    // MARK: Control channel (Settings -> SpringBoard)

    /// The verb of the next SpringBoard command lives in preferences; the
    /// Darwin notification only says "look now". A notification that never
    /// arrives therefore cannot lose the command.
    public static func request(_ command: String) {
        setString(command, forKey: "pendingCommand")
        notifyPost(Aevon.noteCommand)
    }

    /// Reads and clears, so a command is acted on at most once.
    public static func takePendingCommand() -> String? {
        guard let command = defaults?.string(forKey: "pendingCommand"), !command.isEmpty else {
            return nil
        }
        setString(nil, forKey: "pendingCommand")
        return command
    }

    private static func setString(_ value: String?, forKey key: String) {
        guard let store = defaults else { return }
        if let value = value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    // MARK: Verification

    public static func evaluate() -> Verdict {
        if panicActive {
            Log.write("gate G0: panic active, standing down (zero hooks)")
            return .panic
        }
        if disabledActive {
            let reason = (readState()["disabledReason"] as? String) ?? "unknown"
            Log.write("gate G1: disabled, reason=\(reason)")
            return .disabled
        }

        var state = readState()
        let now = Date().timeIntervalSince1970
        let last = (state["lastAttempt"] as? NSNumber)?.doubleValue ?? 0
        var attempts = (state["attempts"] as? NSNumber)?.intValue ?? 0
        if last <= 0 || now - last > crashWindow { attempts = 0 }
        attempts += 1

        state["attempts"] = attempts
        state["lastAttempt"] = now
        state["version"] = Aevon.version
        state["lastLoad"] = now

        // Cannot count attempts -> cannot guarantee the breaker works.
        // Fail safe: stand down.
        guard writeState(state) else {
            Log.write("gate G2: state not writable at \(Aevon.statePath), standing down")
            return .unwritable
        }

        if attempts > maxAttempts {
            var off = readState()
            off["disabled"] = true
            off["disabledReason"] = "auto:crash-loop"
            off["disabledAt"] = now
            writeState(off)
            Log.write("gate G2: \(attempts) unstable loads within \(Int(crashWindow))s, self-disabled")
            return .crashLoop
        }

        return .pass
    }

    // MARK: Human-readable state (settings rows)

    public static var statusText: String {
        if panicActive { return "已紧急停止（G0）" }
        if disabledActive { return "已暂停注入（G1）" }
        if (readState()["disabledReason"] as? String) == "auto:crash-loop" {
            return "已自动停用（G2）"
        }
        return "运行中"
    }

    public static func timeText(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
