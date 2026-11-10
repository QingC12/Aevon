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
    public static let version = "0.3.4"

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

    /// The operator's own icon list, in their own order. Settings writes it,
    /// SpringBoard reads it. Empty file = "no choice made yet", and the ring
    /// falls back to the automatic list instead of showing nothing.
    public static let appsPath = "/var/mobile/Library/Logs/Aevon/apps.plist"

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

    /// A request, not a setting: Settings drops this file and posts the prefs
    /// note; SpringBoard deletes it and writes the scene dump to the log. A
    /// file rather than a preference because the two processes disagree about
    /// where the domain lives on roothide, and because "one shot" is exactly
    /// what a file is.
    public static let probePath = "/var/mobile/Library/Logs/Aevon/probe.request"

    /// 0.2.91 — 「上一次死在哪一步」。
    ///
    /// 两份都是**进程被信号带走时才会留在盘上**的标记：正常走完就自己删掉。
    /// 所以开机看到这两行，说明上一次运行没走完，而后面的名字就是断点。
    ///
    /// `last.step` 由 URL 落点那条路写（`url:enter` / `url:target` / `url:branch` /
    /// `url:forward` / `url:rescue`）；`act.step` 由激活探针写，只用在一个会
    /// 解引用私有结构的地方（`_Block_signature`）。Aevon(223) 那三次连崩之所以
    /// 一行线索都没留下，就是因为那一下死在写日志之前。
    public static let urlStepPath = "/var/mobile/Library/Logs/Aevon/last.step"
    public static let actStepPath = "/var/mobile/Library/Logs/Aevon/act.step"


    /// 承载层普查跑过没有。内容是这个包的版本号：装新版本会重跑一份，
    /// 单纯重启不会 —— 普查是只读的，但它没有理由在每次开机都占一行日志。
    /// 0.2.80 起，这一份是「Stheno 的 presenter 路能不能走」在真机上的唯一证词。
    public static let presenterStampPath = "/var/mobile/Library/Logs/Aevon/presenter.stamp"

    /// 普查正走到哪个类。写法与 `winStepPath` 同一条纪律：凡是有可能带走进程的
    /// 调用，调用前先把名字落盘 —— 一个只读普查理论上不该崩，但「理论上」不值钱，
    /// 上次 SpringBoard 安全模式就是拿「理论上」换来的。跑完即删。
    public static let presenterStepPath = "/var/mobile/Library/Logs/Aevon/presenter.step"

    /// 0.2.83 — 普查自己的一份账，和 Aevon.log 分开。
    ///
    /// 为什么非分不可：0.2.82 那一轮普查的产出**被装包动作吃掉了**。
    /// `postinst` 从 0.2.21 起就把 `/var/mobile/Aevon.log` 截断（省得每次进
    /// Filza 手动删），而普查是「一个版本只跑一次」；于是「跑过 → 装包清日志
    /// → 重启看到 skip」这条路上，数据在写出来的那一秒就已经注定读不到。
    /// Aevon(214) 正是这一格：13:09:25 的 `census skip version=0.2.82` 说明
    /// 上一次真跑过，而日志从 13:09:23 才开始 —— 前半段不存在了。
    ///
    /// 一份独立文件还有第二个好处：追加、不清空，多次普查可以并排读。
    public static let presenterCensusPath = "/var/mobile/Library/Logs/Aevon/presenter.census"

    /// 手写这个文件 = 下一次开机**无视**版本标记再跑一遍普查，跑完自己删掉。
    /// 存在的理由：普查一旦被任何东西吃掉，重来一次不该再烧一个构建。
    public static let presenterForcePath = "/var/mobile/Library/Logs/Aevon/presenter.force"

    /// The class a scan was looking at when the process stopped. Written before
    /// each class is touched, so it is the one witness that survives a SIGKILL —
    /// a signal handler cannot, and a jetsam kill and one poisonous class leave
    /// the same log otherwise. Raw bytes on purpose (4-byte index + name): a
    /// million writes are cheap, and this runs once per class.
    public static let callStatePath = "/var/mobile/Library/Logs/Aevon/call.state"

    /// Classes that already killed a scan, one per line. Read at the start of
    /// every scan and written at boot from `callStatePath`: a probe that walks
    /// straight back into a class that took SpringBoard down teaches nothing.
    public static let callSkipPath = "/var/mobile/Library/Logs/Aevon/call.skip"

    /// The signal that ended the last walk, four raw bytes, written from the
    /// handler itself. Everything else about these runs is inference: a bad
    /// class, a jetsam kill and a watchdog kill all leave the log ending mid
    /// sentence. A signal number separates the first from the other two, and a
    /// missing file says the process was killed rather than faulted.
    public static let callFaultPath = "/var/mobile/Library/Logs/Aevon/call.fault"

    /// The window probe's own step marker, one short name per line, rewritten
    /// before every call that could take SpringBoard down and deleted once the
    /// call returns. SpringBoard has now died twice on a call we chose from a
    /// string table — 0.0.15 inside `_createSceneWithDefinition:`, 0.0.16 right
    /// after `presentationView`. Both times the log ended between two lines and
    /// the culprit had to be inferred. With this file the next boot says it.
    public static let winStepPath = "/var/mobile/Library/Logs/Aevon/win.step"

    /// 0.0.21 — the latch a hook leaves behind, and the reason 0.0.20 cannot
    /// happen twice. Written *before* an IMP is replaced and deleted only after
    /// every one of them is put back. If it is still on disk at the next
    /// request, the last run either died inside the hook or was killed with it
    /// installed, and the answer is to not install it again — a hook that
    /// survives its own run is the one failure mode a crash counter cannot see,
    /// because nothing crashed. 0.0.20 left three live scenes' presenters
    /// activated with no way back and the phone went black while SpringBoard
    /// kept answering heartbeats.

    /// 0.1.85 — 通知点击观察器的两道闩。
    ///
    /// `armed` 在装配**之前**写、活到 180 秒才摘。它还在 = 上一次装上去之后
    /// 没活到摘闩，那一次 SpringBoard 的死因不必再猜：就是这条钩子。
    ///
    /// `off` 是那个结论的落点，也是操作者的手动开关。它存在时一个字节都不碰；
    /// 自动落下之后要重新取证，删掉这个文件再重启即可。用文件而不是偏好域，
    /// 理由与 `state.plist` 相同：roothide 会按进程重定向 Library/Preferences，
    /// 而这个判断必须在任何进程里都读到同一份。
    public static let activateArmedPath = "/var/mobile/Library/Logs/Aevon/notify.armed"
    public static let activateOffPath   = "/var/mobile/Library/Logs/Aevon/notify.off"
    /// 0.2.26 — 连续几次启动看见旧闩。`1` 只跳过一次装配，`2` 才落 `notify.off`；
    /// 普通重载桌面也会留下旧闩，一振就关会把这个功能永久误伤（0.2.25 的真机日志）。
    public static let activateStrikesPath = "/var/mobile/Library/Logs/Aevon/notify.strikes"

    /// 0.1.92 — 分享面板那条路自己的开关。与 `notify.off` 分开是因为两者风险不同：
    /// 「分享文件给别的 App」带交接，出问题时往往只是「打开是空的」，而通知那条是
    /// 「点了没反应」；把两条路绑在一个开关上，想收一条就得把另一条也关掉。
    /// **`notify.off` 仍然是总闸**：两个任一存在，分享一律不接管。
    public static let shareOffPath      = "/var/mobile/Library/Logs/Aevon/share.off"

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
