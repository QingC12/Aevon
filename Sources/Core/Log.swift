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
        // 0.0.59 — `NSLog` 从这里挪到失败兜底。
        //
        // 它是同步的 syslog 写，在 SpringBoard 主线程上一次 1~3 ms。建卡那条路
        // 上 activate 之前有七次日志，全在首帧前面排着队 —— 七次 NSLog 就是
        // 十到二十毫秒的「点下去还没动」。文件日志一直是最有用的那一份（操作者
        // 拿到的都是 /var/mobile/Aevon.log），syslog 只是它的副本；副本不该比
        // 正文更贵。写不进文件的时候再退回 NSLog，那才是它唯一有价值的场合。
        guard let handle = FileHandle(forWritingAtPath: Aevon.logPath) else {
            NSLog("[Aevon] %@", message)
            return
        }
        defer { try? handle.close() }

        _ = try? handle.seekToEnd()
        let line = "\(stamp.string(from: Date())) [\(Aevon.version)] \(message)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
