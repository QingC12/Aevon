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
    public static let version = "0.0.3"

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
