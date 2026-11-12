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
        // 0.2.75 — 写完之后必须喊一声。文件与偏好都只是「放在那里」，
        // SpringBoard 进程不会自己去看；没有这一句，开关就只是界面上的一个勾。
        notifyPost(Aevon.noteGate)
    }

    // 0.4.0 — 「分流文件闸」（`notify.off` / `share.off`）整块删除：这两个闸门
    // 管的是「通知 / 分享要不要接管」，而这一版不再接管任何一条打开请求。
    // 面板上对应的两个开关（`!gate.notify` / `!gate.share`）一并去掉 ——
    // 留一个拧了没反应的开关，比没有更糟。

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
        notifyPost(Aevon.noteGate)
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
        // 解闸同样要喊：`refreshRuntime` 只有收到通知才复查，而「复位」正是
        // 用户把 G0/G1 关掉之后期望立刻生效的那一下。
        notifyPost(Aevon.noteGate)
    }

    // MARK: 运行期闸（0.2.75）

    //
    //  Aevon(207)：`settings: G0 emergency stop -> on` 之后
    //  `win: touch in=17 eat=3`、`ring: edge swipe open`、`win: keepalive beat`
    //  一条不少。用户的原话是「闸门都无法制止」。
    //
    //  两道机制同时缺失：
    //
    //    ① 设置侧只写文件 / 偏好，不发任何通知 —— SpringBoard 不知道；
    //    ② 即使知道，`evaluate()` 也只在加载时跑过一次，之后没有任何复查点，
    //       而 `AevonInstallTouchTap` 用 `dispatch_once` 装上的 `sendEvent:`
    //       替身永远不会被摘掉。
    //
    //  修法分两半：写的那半在 `setPanic` / `setDisabled` / `resetAttempts`
    //  末尾发 `Aevon.noteGate`；读的那半就是下面这个快照。快照刻意做成一个
    //  Bool —— 触摸路径上不能有 IO，连 `fileExists` 都不该每根手指查一次。
    //

    /// 闸关着 = 我们已经交还触摸。初值 false：加载时 `evaluate()` 已经 pass，
    /// 否则 `AevonStart` 在更早的地方就返回了。
    private static var runtimeOffFlag = false
    private static var runtimeKnown = false

    /// 触摸路径读这一个。主线程写、主线程读，不做原子包装。
    public static var runtimeOff: Bool { runtimeOffFlag }

    /// 立刻复查 G0/G1（只看这两道，不碰 G2 的计数与写盘）。
    ///
    /// 返回「现在是不是该停手」。调用方在返回 true 时执行停手动作 —— 这么做是
    /// 为了让 Gate 不依赖 UI 层：`Gate.swift` 同时编进 tweak 与设置包，把
    /// `RingHost` / `FloatHost` 写进来会让设置包链接到一堆用不上的东西。
    @discardableResult
    public static func refreshRuntime(_ why: String) -> Bool {
        let g0 = panicActive
        let g1 = disabledActive
        let off = g0 || g1
        // 三元不写在插值里：这一行的类型检查在 0.2.57 / 0.0.30 各拖垮过一次构建。
        let flag = off ? "1" : "0"
        let f0 = g0 ? "1" : "0"
        let f1 = g1 ? "1" : "0"
        if !runtimeKnown {
            runtimeKnown = true
            runtimeOffFlag = off
            Log.write("gate: runtime armed off=" + flag + " why=" + why)
            return off
        }
        if off == runtimeOffFlag { return off }
        runtimeOffFlag = off
        // 前缀刻意长过 15 字节：短的那个会被 Swift 编成立即数，二进制里 grep
        // 不到，audit 就少一条能证明「闸真的接上了」的锚点。
        Log.write("gate: runtime switch " + flag + " why=" + why
                  + " g0=" + f0 + " g1=" + f1)
        return off
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

/// 0.2.75 — `-[UIApplication sendEvent:]` 的替身每收一个触摸先问这一句。
///
/// 为什么是 C 函数而不是直接调 `Gate.runtimeOff`：替身写在 `AevonScene.m` 里，
/// 那是纯 ObjC 文件，要看见 Swift 的静态成员就得有桥接头，而这个工程刻意没有
/// Umbrella header（`Boot.swift` 顶部那几个 `@_silgen_name` 就是同一个理由的
/// 产物）。返回值取 `int` 而非 `BOOL`：跨语言边界上不依赖 ABI 的类型细节。
@_cdecl("AevonGateOff")
public func AevonGateOff() -> Int32 {
    return Gate.runtimeOff ? 1 : 0
}
