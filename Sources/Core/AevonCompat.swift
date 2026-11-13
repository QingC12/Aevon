//
//  AevonCompat.swift — Aevon 0.0.42, the seams the old plugin's files expect.
//
//  0.0.42 moves the operator's own ring implementation over from the archived
//  plugin (D:\备份源码\Aevon — the user's own code, versions up to V0.3.x)
//  essentially verbatim: AevonRingMenu, AevonRingIcon, AevonHoverKeyframes,
//  AevonRingUnfold, AevonSpring, AevonRingStore, AevonQuickAction and
//  AevonRecProbe all keep their original names, constants and comments, because
//  "1:1" is the requirement and a rename is a rewrite.
//
//  What this file buys is the small set of external symbols those files call
//  that the old binary provided and this one spells differently:
//
//    AevonLog           -> Log.write (same file, same format)
//    AevonPrefs         -> CFPreferences on the one domain this package owns
//    AevonFloatMotion   -> only the haptic entry was needed by the menu
//    AevonAppIcon       -> RingIcons (icon lookup + the same 22.37% rounding)
//    AevonWindowManager -> name lookup + a launch hook set by RingHost
//    AevonRingGrip      -> the old edge bar; here the grip is RingHost's dot
//    AevonEdgeEntry     -> presentation hooks set by RingHost / no-ops
//    AevonTrySystem…    -> the two ObjC shims, as Swift (responds check first)
//    AevonWindowLevels,
//    AevonPassthroughWindow,
//    AevonHostWindow    -> overlay window for toast / recording badge
//
//  Everything here is glue, not logic: the smallest body that satisfies the
//  caller, with the caller's own comment preserved where it explains why.
//

import UIKit
import ObjectiveC.runtime
import ReplayKit
import AudioToolbox

// MARK: - Log

/// The old plugin's logger. `info` and `warn` both land in
/// /var/mobile/Aevon.log through the same Log.write the rest of this package
/// uses — one file, one tail command, no second logging path to babysit.
enum AevonLog {
    static func info(_ text: String)    { Log.write(text) }
    static func warn(_ text: String)    { Log.write(text) }
}

// MARK: - Preferences

/// CFPreferences reader on this package's own domain. The old plugin's domain
/// was `com.Aevon` (capital A); this package ships as `com.aevon` and writes
/// every other key there, so the store joins the same domain instead of
/// splitting the operator's settings across two files.
///
/// The old file's warning is reprinted because it is still true: reading here
/// is an IPC round trip. Keep it out of per-frame paths.
enum AevonPrefs {
    static let domain = Aevon.domain as CFString

    static func rawValue(_ key: String) -> Any? {
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static func synchronize() {
        CFPreferencesAppSynchronize(domain)
    }

    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = rawValue(key) as? NSNumber { return value.boolValue }
        return defaultValue
    }

    static func double(_ key: String, default defaultValue: Double) -> Double {
        if let value = rawValue(key) as? NSNumber { return value.doubleValue }
        if let text = rawValue(key) as? String, let parsed = Double(text) { return parsed }
        return defaultValue
    }
}

// MARK: - Haptics

/// 圆盘唯一的反馈出口 —— 母版 `sub_4a764` 的移植。
///
/// 母版 `disasm-Stheno-s0.txt` 里这一段是全库**唯一**的反馈函数，十个调用点
/// 都汇到它（`0x4c334` 滑过图标、`0x1a2c4/0x1ba74/0x1c350` 展开/收起/选中、
/// `0x2dd8c` 点击、`0x6114c` 钉住、`0x60674` 设置开关、另三处动作按钮）。
/// 它做的是一个二选一，不是两件事：
///
///     0x4a7b0  mov  w0, #0xe                 ← ToggleMask 第 15 项 `vibrate`
///     0x4a7cc  tbz  w19,#0, 0x4a84c          ← 关 → 去播系统音
///     0x4a820  bl   AppStorage…wrappedValue  ← 强度是变量，不是常量
///     0x4a844  bl   _objc_msgSend            ← impactOccurredWithIntensity:
///     0x4a84c  mov  w0, #0x485               ← 1157
///     0x4a850  bl   _AudioServicesPlaySystemSound
///
/// 那一条 `AppStorage…wrappedValue` 是关键：母版的强度读 `VibrateIntensity`，
/// 默认 0.5（`0x6a530 fmov d0,#0.5`）但**面板里可调**（`VibrateIntensityControlView`）。
/// 0.4.63 把 0.5 写死，于是「与母版默认相同」却「与母版能调到的不相同」——
/// 用户 0.4.64 说震感偏小，根在这里。现在强度和音量共用 `RingConfig.feedback`。
enum AevonFloatMotion {

    /// 母版 `mov w0, #0x485` = 1157。全库 `_AudioServicesPlaySystemSound` 只有
    /// 这一个调用点（`AevonQuickAction` 里那记 1108 是截图快门，不是圆盘反馈）。
    ///
    /// ⛔ 不要换 ID、不要自己合成。用户 0.4.64 明确「按母版中的音效，添加到圆盘
    /// 旋转里，不需要我们自己寻找新的」。旋转的齿轮感来自**触发间隔**（每转
    /// 6° 一声，转得快就密），不是换一个更像齿轮的音色。
    static let soundID: SystemSoundID = 1157

    /// 旋转时每转多少度一声。
    ///
    /// 母版没有这个数 —— 母版旋转过程完全没有反馈。6° 是按「一圈 60 声」定的：
    /// 慢转约每秒两三声，快转自然连成一片。
    static let gearStep: CGFloat = 6.0

    // MARK: 运行期镜像

    private static var soundOn = false
    private static var level: CGFloat = 0.7
    private static var known = false

    /// 两条刷新源都调它：`RingHost.refresh()`（改设置 → Darwin）与
    /// `AevonRingMenu.present()`（每次呼盘）。⚠ 粘性全局量必须有同寿命的刷新源，
    /// 少任何一条，「改完设置要重载桌面才生效」就会回来。
    static func refresh() {
        let config = RingConfig.loadRuntime()
        soundOn = config.sound
        level = config.feedback
        known = true
    }

    private static var soundReplacesHaptic: Bool {
        if !known { refresh() }
        return soundOn
    }

    private static var strength: CGFloat {
        if !known { refresh() }
        return level
    }

    // MARK: 震动

    /// 母版把 generator 建成**全局单例**（`0x4a8b0` 由 `swift_once` 只跑一次），
    /// 0.4.63 却是每一记都新建一个。新引擎没有 prepare，第一拍会被系统压轻或
    /// 延后 —— 这是「震感偏小」的第二个来源，不只是 0.5 那个数。
    ///
    /// 保留两档（Light / Medium）而不是母版那一个 Light：`pick`（选中开窗）
    /// 用 Medium 是 0.4.63 起就有的手感，本版没有理由把它降回去。
    private static let lightEngine = UIImpactFeedbackGenerator(style: .light)
    private static let mediumEngine = UIImpactFeedbackGenerator(style: .medium)
    private static var prepared = false

    private static func prepareEngines() {
        guard !prepared else { return }
        prepared = true
        lightEngine.prepare()
        mediumEngine.prepare()
    }

    private static func fireHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        prepareEngines()
        let engine: UIImpactFeedbackGenerator = (style == .light) ? lightEngine : mediumEngine
        let selector = NSSelectorFromString("impactOccurredWithIntensity:")
        if let method = class_getInstanceMethod(UIImpactFeedbackGenerator.self, selector) {
            typealias IntensityFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
            let function = unsafeBitCast(method_getImplementation(method), to: IntensityFn.self)
            function(engine, selector, strength)
        } else {
            engine.impactOccurred(intensity: strength)   // iOS 13+ 公开重载，同参数
        }
    }

    // MARK: 声音

    /// `AudioServicesPlaySystemSound` 本身**没有音量参数** —— 母版也只有这一句，
    /// 所以母版的音量就是系统「铃声与提示音」的音量，谁也调不了。
    /// 要让滑条管音量，只能用私有的 `AudioServicesPlaySystemSoundWithVolume`；
    /// 拿不到就原样退回母版那一个调用（音量交回系统）。
    private typealias VolumeFn = @convention(c) (SystemSoundID, Float) -> Void
    private static let playWithVolume: VolumeFn? = {
        // -2 是 RTLD_DEFAULT：在整个已加载镜像里找，不限定某个句柄。
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(handle, "AudioServicesPlaySystemSoundWithVolume") else {
            return nil
        }
        return unsafeBitCast(symbol, to: VolumeFn.self)
    }()

    private static func fireSound() {
        let value = Swift.max(0.0, Swift.min(1.0, strength))
        if let function = playWithVolume {
            function(soundID, Float(value))
        } else {
            AudioServicesPlaySystemSound(soundID)
        }
    }

    // MARK: 出口

    /// `source` 只进日志：hover / unfold / close / pick / rotate / panel。
    /// 圆盘上九个反馈点全走这一条出口，靠它区分「这一记是谁要的」。
    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                       source: String = "menu") {
        if soundReplacesHaptic {
            fireSound()
            note("声音", source)
            return
        }
        fireHaptic(style)
        note("震动", source)
    }

    /// 旋转模式的「齿」：按角度步进调用，每 6° 一记。
    ///
    /// ⛔ 只在声音模式响。震动模式下旋转**不震** —— 母版的旋转过程本来就没有
    /// 反馈，每格震一下会变成持续嗡鸣。这也是「声音代替震动」的本来语义。
    static func gear(source: String = "rotate") {
        guard soundReplacesHaptic else { return }
        let now = CACurrentMediaTime()
        // 转得再快也留 28 ms 间隙：1157 约 30 ms 长，再密就只剩噪音。
        if now - lastGearAt < 0.028 { return }
        lastGearAt = now
        fireSound()
        note("齿轮", source)
    }

    private static var lastGearAt: CFAbsoluteTime = 0

    /// 日志带当前值：改过滑条之后第一件事就是确认「新数真的读到了」。
    /// `vol=1` 表示走的是带音量的私有入口，`vol=0` 表示退回母版原调用。
    private static func note(_ kind: String, _ source: String) {
        let value = String(format: "%.2f", Double(strength))
        if kind == "震动" {
            AevonLog.info("[圆盘] 震动 i=" + value + " src=" + source)
        } else {
            let via = playWithVolume != nil ? "1" : "0"
            AevonLog.info("[圆盘] " + kind + " id=1157 v=" + value
                          + " vol=" + via + " src=" + source)
        }
    }
}

// MARK: - Icons

/// The old plugin resolved icons through an ObjC shim (`AevonIconImage`); this
/// package already has RingIcons doing the same LaunchServices → bundle scan
/// walk. The adapter keeps the old call shape (nil when there is no *real*
/// icon, so the ring's letter-tile fallback still fires) and adds the same
/// 22.37 % corner rounding the old renderer applied.
enum AevonAppIcon {
    private static var cache: [String: UIImage] = [:]
    private static var failed = Set<String>()

    static func image(bundleID: String, size: CGFloat) -> UIImage? {
        if bundleID.isEmpty { return nil }
        if let cached = cache[bundleID] { return cached }
        if failed.contains(bundleID) { return nil }
        guard let item = RingIcons.item(for: bundleID),
              let source = RingIcons.realIcon(for: item) else {
            failed.insert(bundleID)
            return nil
        }
        let target = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rounded = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: target)
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.2237).addClip()
            source.draw(in: rect)
        }
        cache[bundleID] = rounded
        return rounded
    }
}

// MARK: - Window plumbing

/// Overlay window level. Same numbers as the old `AevonWindowLevels`: the
/// toast and the recording badge must sit above everything this package makes.
enum AevonWindowLevels {
    static let overlay = UIWindow.Level(rawValue: 10_000_100)
}

/// Passthrough window: an unanswered hit falls through. Copied because the
/// toast and badge windows must never eat a touch themselves.
class AevonPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Overlay window factory. The old one lived on `AevonHostWindow` with a
/// scene-scoring walk; here the first connected scene is enough — the toast
/// and the badge are the only tenants and both tolerate a missing scene by
/// simply not showing (the callers already guard on nil).
enum AevonHostWindow {
    /// SpringBoard 里 `UIApplication.shared` 不是可以裸碰的东西（本仓库的铁律）：
    /// 走运行时拿 sharedApplication，拿不到就让调用方走「不显示」分支。
    static func firstWindowScene() -> UIWindowScene? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: selector),
              let unmanaged = meta.perform(selector),
              let application = unmanaged.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        return application.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    static func makeOverlayWindow() -> UIWindow? {
        guard let scene = firstWindowScene() else {
            AevonLog.warn("[窗口] 创建外部图层窗口失败：没有可用的前台场景")
            return nil
        }
        let overlay = AevonPassthroughWindow(windowScene: scene)
        overlay.frame = UIScreen.main.bounds
        overlay.backgroundColor = .clear
        overlay.windowLevel = AevonWindowLevels.overlay

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        overlay.rootViewController = root
        overlay.isHidden = false
        return overlay
    }
}

// MARK: - Recording shims

/// The two ObjC shims from AevonAssertionShim.m, as Swift. The @try around the
/// old call sites cannot come across (Swift does not catch ObjC exceptions);
/// the respondsToSelector gate stays, which is the check that decides the
/// branch on every iOS this targets.
func AevonTrySystemRecordingStart(_ recorder: NSObject?, handler: (@convention(block) (NSError?) -> Void)?) -> Bool {
    guard let recorder = recorder else { return false }
    let sel = NSSelectorFromString("startSystemRecordingWithMicrophoneEnabled:handler:")
    guard recorder.responds(to: sel) else { return false }
    recorder.perform(sel, with: true, with: handler as AnyObject?)
    return true
}

func AevonTrySystemRecordingStop(_ recorder: NSObject?) -> Bool {
    guard let recorder = recorder else { return false }
    let sel = NSSelectorFromString("stopSystemRecording:")
    guard recorder.responds(to: sel) else { return false }
    recorder.perform(sel, with: nil)
    return true
}

// MARK: - Ring integration hooks

/// The menu's three calls into the old edge-entry system. This package has no
/// edge entry — the disc is summoned by tapping RingHost's grip dot — so these
/// are hooks RingHost fills in at start(), and no-ops everywhere else. That is
/// also what lets the settings preview host the same menu without a host
/// process behind it.
enum AevonEdgeEntry {
    /// Set by RingHost: opens the app panel. The old panel was an in-SB picker;
    /// here it is the Settings page (the editor lives there now).
    static var openPanelHandler: (() -> Void)?
    static func openPanel() { openPanelHandler?() }

    /// 圆盘收起时由 `AevonRingMenu.dismiss()` 调一次（唯一调用点，1361 行附近）。
    ///
    /// 0.4.2 — 这里原本是空实现（注释写着「没有 adopter，没什么可拆的」），
    /// 但 `RingHost.expanded` 正是那个 adopter：它只在 `handleEdgePhase` 的
    /// `.ended` / `.cancelled` 两格里复位。圆盘被**别的路径**收起时（点击图标、
    /// 静默看门狗、面板、选中后自动收），这两格一条都收不到 —— `expanded`
    /// 就停在 true，`edgeTouch` 的 `.moved` 分支于是每次都走
    /// `if expanded { edgeWatching = false; return false }`，表现正是用户报的
    /// 「圆盘恢复后手势再也唤不出，只能注销」。挂一个 handler 让它归零。
    static var ringDidDismissHandler: (() -> Void)?
    static func ringDidDismiss() { ringDidDismissHandler?() }

    /// The old 1.5 s re-summon guard for the swipe entry. The entry here is a
    /// deliberate tap on a dot, not a swipe that can double-fire, so the guard
    /// has nothing to guard.
    static func noteSelectionCooldown() {}
}

/// The old edge bar. `setVisible` shows/hides the summon handle while the disc
/// is open; `hasActiveGripTouch` fed the menu's idle watchdog. The grip here is
/// RingHost's dot in the same window, so `setVisible` is a hook it fills in,
/// and the touch query is answered by RingHost when it owns that state.
enum AevonRingGrip {
    static var setVisibleHandler: ((Bool) -> Void)?
    static func setVisible(_ visible: Bool) { setVisibleHandler?(visible) }

    /// The watchdog treats "grip touch alive" as a reason not to auto-dismiss.
    ///
    /// 0.0.45 — this stops being a constant. The summon bar now *holds* the
    /// disc: a finger pressed on the bar drags the ring open, moves it, and
    /// only lifting ends the session (the operator's own words for the old
    /// behaviour: 「手指在没有离开屏幕时圆盘不会自动收起」). While that pan is
    /// live the finger is on the bar, not on the disc, so UIKit's touch count
    /// on the menu view is zero — without this hook the 1.5 s watchdog would
    /// dismiss a disc whose finger never left the screen, which is exactly the
    /// bug Aevon(41) #2 reported.
    static var activeTouchHandler: (() -> Bool)?
    static var hasActiveGripTouch: Bool { return activeTouchHandler?() ?? false }

    /// 0.0.48 — 竖条触摸垫在屏幕上的位置，由 RingHost 在每次布局后写进来。
    ///
    /// 浮窗的手指入口（`-[UIApplication sendEvent:]`）会把落在浮窗环上的触摸
    /// 全部吃掉，而环的右半边正好压在竖条原来的位置上。没有这个矩形，卡片开着
    /// 的时候点竖条会被当成「拖浮窗」—— 换 App 的路就被自己的浮窗堵死了。
    static var summonRect: CGRect = .zero

    /// 0.1.10 — 竖条的应用层手指入口（`barTouchHandler` / `barTouch`）已删。
    ///
    /// 它曾让 `-[UIApplication sendEvent:]` 把落在条子上的手指直接交给 RingHost，
    /// 用来绕开「锁屏后窗口栈重排、条子看得见按不到」。代价是整条呼出链都变成
    /// 自己拼触摸语义：`sendEvent` 只看得到单个事件，看不到「这根手指整段归谁」，
    /// 于是出现了半截序列 / 假点击 / 孤儿帧（Aevon(94)~(97) 那几轮的全部门）。
    ///
    /// 0.1.11 — 呼出只走 `RingHost` 的 `EdgeSwipePad`：它自己收 `touchesBegan`
    /// 一族、自己累积位移，够左才弹盘。0.1.10 那版把判据放在
    /// `gestureRecognizerShouldBegin` 里，被 UIKit 的调用时机卡死（那一拍
    /// `translation` 只有 10 pt，门槛却是 12），Aevon(98) 一个盘都呼不出来。
    /// 窗口被压住的顾虑用母版同款办法解决 —— 每次解锁/回前台把窗口 level 抬一格
    /// 再放回（见 `raiseWindow`），不靠事件通道兜底。

    /// 0.0.55 — 浮窗（卡片）此刻在屏上。由 SceneProbe 在开卡/关卡时写。
    ///
    /// 右缘那条「贴边左滑呼盘」的触摸带（`edgePad`，15 pt × 底部 35%）与浮窗外侧
    /// 手势环在右下角是重叠的：卡片贴右缘时，拖卡片底角的手会先落在带宽里。
    /// 卡片开着就让这条带闭嘴 —— 换 App 还有竖条那条路，而拖卡片没有第二条路。
    static var cardUp = false
}

/// The old window manager, reduced to the two things the menu calls:
/// a display name, and the launch. The launch goes through a hook so the
/// SpringBoard binary routes it through SceneProbe's card path while the
/// settings preview intercepts it instead.
enum AevonWindowManager {
    /// Set by RingHost in SpringBoard; the preview sets its own.
    static var launchHandler: ((String) -> Void)?

    static func launchAndOpen(bundleID: String) {
        launchHandler?(bundleID)
    }

    static func title(for bundleID: String) -> String {
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏是圆盘里的动作槽，不是 App。
        if let action = AevonQuickAction.title(for: bundleID) { return action }
        return RingIcons.item(for: bundleID)?.name ?? bundleID
    }
}

/// Reading a private property without the two ways this normally kills a phone.
///
/// 0.1.38 — written after the safe-mode report. Two assumptions were wrong in
/// the same place:
///
///   ① **`value(forKey:)` can raise, and Swift cannot catch it.** A key the
///      class does not have ends in `valueForUndefinedKey:`, whose default
///      raises `NSUndefinedKeyException`. `@try` exists only in ObjC here, so
///      the exception unwinds through Swift frames and takes the process with
///      it — in SpringBoard that is safe mode.
///   ② **`responds(to:)` is not the guard it looks like.** A class that
///      forwards answers YES and then raises anyway, so "it said yes" proves
///      nothing about the value.
///
/// Asking the runtime for the method itself cannot be wrong: if the method is
/// there, calling it cannot raise; if it is not, nil is the honest answer. The
/// IMP is cast to the shape the encoding promises, so nothing gets autoreleased
/// behind our back — which is the other half of the 0.1.35 crash.
enum AevonSafe {
    /// The first real character of a return type, after `r n N o O R V`.
    private static func kind(_ target: NSObject, _ sel: Selector) -> Character? {
        guard let method = class_getInstanceMethod(type(of: target), sel),
              let types = method_getTypeEncoding(method) else { return nil }
        var body = Substring(String(cString: types))
        while let first = body.first, "rnNoORV".contains(first) { body = body.dropFirst() }
        return body.first
    }

    /// An object-returning getter. Nil when the method is absent, when it
    /// returns a scalar (the 0.1.35 crash: `contentState` is an integer), and
    /// when the value simply is nil.
    ///
    /// `perform` is fine **once the return type is known to be an object** —
    /// that is the whole point of the guard above it. It only misbehaves when
    /// the method hands back a number, which is exactly what the encoding check
    /// rejects.
    static func object(_ target: NSObject?, _ key: String) -> NSObject? {
        guard let target = target else { return nil }
        let sel = NSSelectorFromString(key)
        guard let found = kind(target, sel), found == "@" || found == "#" else { return nil }
        return target.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    /// A numeric getter read as a boolean. -1 is never returned: a missing
    /// method is `false`, because every caller here treats "absent" as "off".
    static func flag(_ target: NSObject?, _ key: String) -> Bool {
        guard let target = target else { return false }
        let sel = NSSelectorFromString(key)
        guard let found = kind(target, sel), "QqIiLlCcSsB".contains(found),
              let method = class_getInstanceMethod(type(of: target), sel) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector) -> UInt64
        let call = unsafeBitCast(method_getImplementation(method), to: Call.self)
        return call(target, sel) != 0
    }
}
