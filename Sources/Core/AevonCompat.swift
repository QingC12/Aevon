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

/// Only the haptic entry of the old `AevonFloatMotion` is called by the ring
/// menu (rotation-mode feedback), so only that entry came over. Intensity is
/// resolved the same way the old file did: the private
/// `impactOccurredWithIntensity:` when the system has it, the public API when
/// it does not — never a crash over a vibration.
enum AevonFloatMotion {

    static func hapticIntensity(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> CGFloat {
        switch style {
        case .light:  return 0.55
        case .medium: return 0.85
        case .heavy:  return 1.00
        case .soft:   return 0.45
        case .rigid:  return 0.70
        @unknown default: return 0.85
        }
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        let selector = NSSelectorFromString("impactOccurredWithIntensity:")
        guard let method = class_getInstanceMethod(UIImpactFeedbackGenerator.self, selector) else {
            generator.impactOccurred()
            return
        }
        typealias IntensityFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: IntensityFn.self)
        function(generator, selector, hapticIntensity(for: style))
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

    /// The old call tore the summon finger's adoption down. There is no adopter
    /// here, so there is nothing to tear down — kept as a call site so the
    /// menu's dismiss path stays byte-identical.
    static func ringDidDismiss() {}

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
