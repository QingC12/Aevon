//
//  Paths.swift — Aevon
//
//  Compiled into BOTH binaries (SpringBoard tweak + Settings bundle), so the
//  two processes can never disagree about where things live.
//
//  Rules for this file:
//    · Foundation only — no UIKit, no private API.
//    · Every path is absolute and written once, here.
//

import Foundation

public enum Aevon {

    /// Must equal control:Version and the bundle's CFBundleShortVersionString.
    /// The CI preflight fails the build when the three drift apart.
    public static let version = "0.4.8"

    /// Preferences domain. Deliberately independent of the package name:
    /// renaming the package must never lose the operator's gate state.
    public static let domain = "com.aevon"

    /// The one log file the operator is told to look at.
    public static let logPath = "/var/mobile/Aevon.log"

    /// Gate state. NOT under Library/Preferences: a roothide jailbreak
    /// redirects that path per process, so SpringBoard and Settings would
    /// read different copies of the same file.
    public static let stateDir  = "/var/mobile/Library/Logs/Aevon"
    public static let statePath = "/var/mobile/Library/Logs/Aevon/state.plist"
    public static let panicPath = "/var/mobile/Library/Logs/Aevon/panic"

    /// The carrier-shape values, mirrored out of the preferences domain.
    ///
    /// Why a file as well as the domain: on roothide, Library/Preferences is
    /// redirected per process, so Settings and SpringBoard can read two
    /// different copies of "Radius". This path is plain and shared, the same
    /// reason state.plist lives here. Settings writes it on every change,
    /// SpringBoard reads it on every notification.
    public static let ringPath = "/var/mobile/Library/Logs/Aevon/ring.plist"

    /// 0.0.44 — 谁正在被浮窗承载。
    ///
    /// The card's app needs to know one thing no app can learn on its own: that
    /// another process is showing its scene. Scene settings are supposed to say
    /// so and may not arrive in the app's own copy, so the host writes this file
    /// as well; the AevonApp injection (Sources/App/AevonAppHook.m) reads it and
    /// stops reporting "background" to UIKit. Absent file = nobody is hosted.
    public static let hostedPath = "/var/mobile/Library/Logs/Aevon/hosted.plist"

    /// 0.0.39 — where the floating card sits, and how big it is.
    ///
    /// The master keeps this as five values inside `EgdeGestureView` /
    /// `SettingEnv`, not as one frame: `_leftPecent` `_rightPecent`
    /// `_leftHeightPecent` `_rightHeightPecent` and `_edgeWidth`. Two sets, one
    /// per edge, because a card docked on the left and the same card docked on
    /// the right are two different placements and the operator expects each to
    /// come back the way it was left. A stored CGRect cannot express that: it
    /// holds one position for a screen that has two.
    public static let cardPath = "/var/mobile/Library/Logs/Aevon/card.plist"

    /// 0.2.91 — 「上一次死在哪一步」。
    ///
    /// 只在**进程被信号带走时才会留在盘上**：正常走完就自己删掉。所以开机看到
    /// 这一行，说明上一次运行没走完，后面的名字就是断点。Aevon(223) 那三次连崩
    /// 之所以一行线索都没留下，就是因为那一下死在写日志之前。
    public static let actStepPath = "/var/mobile/Library/Logs/Aevon/act.step"

    /// 0.1.44 那套「逐类逐方法试调」普查留下的两件落盘物：走到第几类（state）
    /// 与收到哪个信号（fault）。普查本身 0.4.0 已删，这两件只由
    /// `SceneProbe.reportPreviousDeath` 读 —— 它要回答的唯一问题是
    /// 「上一次是不是死在普查里、死在哪一类」。
    public static let callStatePath = "/var/mobile/Library/Logs/Aevon/call.state"
    public static let callFaultPath = "/var/mobile/Library/Logs/Aevon/call.fault"

    /// 开卡链的断点标记（同上，`mark(_:)` / `unmark()` 在 `float` 里写）。
    public static let winStepPath = "/var/mobile/Library/Logs/Aevon/win.step"

    // 0.4.0 — 这里原来还有 42 条常量：`probePath` 与 `presenter*`（普查请求）、
    // `activate*` / `shareOff` / `birthOff`（接管闸门）、`census*`、以及整排
    // `url.*`（写路、拒答、补投、tctx、授权、放行、桥、冷启动扣留 / 收卡 /
    // 自建承载 / 显示层 / 延后交回）。它们对应的功能这一版全部删除，
    // 常量一并去掉 —— 一个指向已删功能的路径，只会让下一个人以为它还在。


    /// Pre-0.0.3 locations. Read on upgrade so a stop stays a stop.
    public static let legacyDomain    = "com.aevon.aevon"
    public static let legacyStatePath = "/var/mobile/Library/Preferences/com.aevon.state.plist"
    public static let legacyPanicPath = "/var/mobile/Library/Preferences/com.aevon.panic"

    /// Darwin notifications — the only channel from Settings into SpringBoard.
    /// One notification, verb in preferences: a dropped notification then
    /// cannot silently swallow a respring, and the callback never has to
    /// parse the notification name.
    public static let noteCommand    = "com.aevon.command"
    public static let commandRespring = "respring"
    public static let commandReset    = "reset"

    /// "A setting changed, re-read it." Sent after every write from Settings,
    /// and also posted by the tweak so a second Settings window stays honest.
    /// The payload is not in the notification: whoever receives it reads the
    /// snapshot file, which is written *before* this is posted.
    public static let notePrefs      = "com.aevon.prefs"

    /// 0.2.75 — 「安全闸动了，立刻复查」。
    ///
    /// 为什么不能复用上面两条：`noteCommand` 的回调第一句就是
    /// `takePendingCommand()`，没有挂起命令就直接返回；`notePrefs` 的回调只刷
    /// 圆盘与探针，从来不问闸。两道闸是「现在就必须停手」的语义，值一次单独的
    /// 通道，读的是同一个 `Gate.refreshRuntime()`。
    ///
    /// Aevon(207) 的现场：`22:07:17 settings: G0 emergency stop -> on` 之后
    /// `win: touch in=` 照常计数、`ring:` 照常响应 —— 开关确实写进了偏好域，但
    /// SpringBoard 这一侧从头到尾没收到过任何通知，而闸本身又只在加载时判定
    /// 一次。两道保险同时失效，用户看到的就是「闸门都无法制止」。
    public static let noteGate       = "com.aevon.gate"
}

// MARK: - Darwin notifications

// notify.h is not part of the Swift Darwin overlay; declare the one symbol we
// use instead of pulling a bridging header into the tweak target.
@_silgen_name("notify_post")
func aevonNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

public func notifyPost(_ name: String) {
    _ = name.withCString { aevonNotifyPost($0) }
}

// MARK: - Jailbreak root

/// roothide keeps its bootstrap in a randomised directory:
///   /var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX
/// rootless keeps it at /var/jb. Neither is hardcoded: look once, cache.
public enum JailbreakRoot {
    public static let path: String? = {
        let base = "/var/containers/Bundle/Application"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for name in names.sorted() where name.hasPrefix(".jbroot-") {
                return base + "/" + name
            }
        }
        if FileManager.default.fileExists(atPath: "/var/jb") { return "/var/jb" }
        return nil
    }()
}

// MARK: - Process spawning

public enum Spawn {

    /// Runs one argv with posix_spawn. Returns false when the binary is
    /// missing or the sandbox refuses the exec — never throws, never loops.
    @discardableResult
    public static func run(_ argv: [String]) -> Bool {
        guard let path = argv.first, !path.isEmpty else { return false }
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }

        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                if let pointer = pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
        }

        var pid = pid_t(0)
        let result: Int32 = pointers.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return posix_spawn(&pid, path, nil, nil,
                               UnsafeMutablePointer(mutating: base), environ)
        }
        return result == 0
    }

    /// Bootstrap helpers first: on roothide they are the real ones.
    public static var respringCommands: [[String]] {
        var out: [[String]] = []
        if let root = JailbreakRoot.path {
            out.append([root + "/usr/bin/sbreload"])
            out.append([root + "/usr/bin/killall", "-9", "SpringBoard"])
        }
        out.append(["/usr/bin/sbreload"])
        out.append(["/usr/bin/killall", "-9", "SpringBoard"])
        return out
    }

    /// True when one of the candidates actually started.
    @discardableResult
    public static func respring() -> Bool {
        for command in respringCommands {
            if run(command) { return true }
        }
        return false
    }
}
