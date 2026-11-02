//
//  Log.swift — Aevon
//
//  One file, one line per event: /var/mobile/Aevon.log
//
//  Logging must never take a process down. Every failure here is silent:
//  if the file cannot be written (Settings is sandboxed on some jailbreaks)
//  the message still reaches the system log through NSLog.
//

import Foundation

public enum Log {

    /// Hard cap. When exceeded the file is dropped and started over: an
    /// unbounded log on a phone that runs for weeks is a storage leak.
    private static let cap: Int64 = 512 * 1024

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public static func write(_ message: String) {
        NSLog("[Aevon] %@", message)

        let manager = FileManager.default
        // stat(2) rather than FileManager attributes: no Swift-Foundation
        // overlay symbol needed, and this file has to stay linkable with
        // nothing but libswiftCore.
        var info: stat = stat()
        if stat(Aevon.logPath, &info) == 0, info.st_size > cap {
            try? manager.removeItem(atPath: Aevon.logPath)
        }
        if !manager.fileExists(atPath: Aevon.logPath) {
            manager.createFile(atPath: Aevon.logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: Aevon.logPath) else { return }
        defer { try? handle.close() }

        _ = try? handle.seekToEnd()
        let line = "\(stamp.string(from: Date())) [\(Aevon.version)] \(message)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
