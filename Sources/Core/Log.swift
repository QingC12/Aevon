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

/// 0.1.40 — C 侧的日志入口。
///
/// `AevonScene.m` 里新加的两条链（键盘宿主归位、通知点击开浮窗）都是事件型的：
/// 它们要写的是「这一刻发生了什么」，而那个文件里的 `AevonNote` 是**缓冲**，
/// 要等某一次 `AevonTakeNotes` 才落盘 —— 键盘弹起后如果什么都没发生，缓冲里的
/// 证词就永远读不到。所以给 C 一个直写口，走同一个 `Log.write`（同一份
/// `/var/mobile/Aevon.log`、同一个 512 KB 截断、同一个版本号后缀）。
@_cdecl("AevonLogRaw")
public func AevonLogRaw(_ line: UnsafePointer<CChar>?) {
    guard let line = line else { return }
    var text = String(cString: line)
    while text.hasSuffix("\n") { text.removeLast() }
    guard !text.isEmpty else { return }
    Log.write(text)
}
