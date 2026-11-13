//
//  RingModel.swift — Aevon, the carrier shape's configuration.
//
//  0.0.42 — the disc itself moved over from the operator's archived plugin
//  (Sources/Ring/AevonRingMenu.swift and friends, kept 1:1). The old
//  implementation carries its own geometry — inner radius 64, arc spacing 46,
//  40 pt icons, multi-ring distribution by count — so the home-grown slot
//  maths that used to live below RingConfig is gone with the home-grown
//  RingView. What remains is the cross-process configuration plumbing:
//
//      Settings → sliders/switches → domain + ring.plist + Darwin
//      → RingHost.refresh() → the disc on the desktop picks it up
//
//  Radius / IconWidth / RotationAngle are still read and mirrored (the panel
//  rows were dropped in 0.0.42 — the old disc's geometry is fixed — but the
//  snapshot format keeps them so an older snapshot file still loads).
//

import Foundation
import CoreGraphics

// MARK: - Configuration

struct RingConfig {

    var radius: CGFloat = 64         // 内圈半径（旧版圆盘不用它；快照格式保留）
    var iconWidth: CGFloat = 44
    var rotation: CGFloat = 0        // 起点角（同上）
    var damping: CGFloat = 0.82      // 阻尼系数
    var customSpring: Bool = true    // 动画弹性
    var star: Bool = true            // 收藏（0.0.42 起圆盘本体不再提供）
    var speed: CGFloat = 1           // 速度

    // 0.4.63 — `haptic` 与 `intensity` 两个字段**删除**。
    //
    // 它们读的 `VIBRATE` / `INTENSITY` 从来就没有控件（`gen-settings.py` 的
    // `WIRED` 里没有这两个键），也就是「一个拧了没反应的开关」的孪生形态：
    // 一个谁都不知道存在、改了却真的会生效的隐藏字段。现在圆盘的反馈是二选一
    // （`sound`），强度只有母版那一个 0.5，两个字段都没有第二个读者了。

    /// 0.4.63 — **一个开关，两选一：震动 / 声音。**
    ///
    /// 母版 `sub_4a764` 逐行是这么写的（`disasm-Stheno-s0.txt`）：
    ///
    ///     0x4a7b0  mov  w0, #0xe          ← 读 ToggleMask 第 15 项 `vibrate`
    ///     0x4a7cc  tbz  w19,#0, 0x4a84c   ← 关 → 跳去播系统音
    ///     0x4a844  bl   _objc_msgSend     ← impactOccurredWithIntensity:（默认 0.5）
    ///     0x4a84c  mov  w0, #0x485        ← 1157
    ///     0x4a850  bl   _AudioServicesPlaySystemSound
    ///
    /// 也就是说声音在母版里**不是**「和震动一起响」，而是「震动关掉时的替代」。
    /// 所以不做两个开关：`SOUND` 关（默认）= 震动，开 = 播系统音、不震。
    var sound: Bool = false

    /// "Put the grip on the home screen." Not one of the master's 81 keys, so
    /// it is prefixed and kept out of the generated table. Ships on: a shape
    /// nobody can see is not a feature.
    var desktop: Bool = true

    /// 0.1.24 — **`barY` / `barLength` / `barWidth` / `fullEdge` 四个字段全部删除。**
    ///
    /// 它们只喂 `RingHost.metrics()` 与 `stripRect()` 里那条整条右缘的分支，而
    /// 竖条整体下线、热区定稿在「贴右缘 18 pt × 底部 35 %」之后，两边都没有
    /// 读取方了。留着字段会让 `settings-manifest.json` 里的对账继续把它们算成
    /// 「已接通」，而实际上没有任何控件能改到它们 —— 账面上对、行为上是死的。
    ///
    /// 用户 Aevon(107) 的原话：「右侧全部能触发，改为底部向上 35 %，避免和左滑
    /// 返回插件冲突」「干脆直接移除触发条」。既然只有一个正确答案，就不设开关。

    /// 0.1.19 — 展开后固定，对应母版的 `AutoPin`（「自锁::展开后立即固定」）。
    ///
    /// 母版 `Stheno.dylib` 的偏好结构里有 `autoPin` / `pinSpeed` / `vibratePin`
    /// 三个字段，手势状态里有 `pinned` / `pinSpeed` / `fingerLocation` /
    /// `fingerStartLocation` / `translationPadding` —— 也就是「手指按下时盘跟着
    /// 手指走（fingerLocation + translationPadding），松手时按 pinSpeed 缓动到
    /// 指定位并置 pinned」。
    ///
    /// ⛔ **0.1.20 起默认关。** 用户 Aevon(105) 把「跟手」整条否了（「既然圆盘和
    /// 圆心跟手无法制作，那么恢复成之前的固定位置出现」），跟手一撤，`AutoPin`
    /// 剩下的那半截语义（抬手未选中也不收起）就变成了负担：盘固定在屏上、又不再
    /// 跟着手指走，用户下一次贴边划只会把它拖来拖去，看起来像「呼不出新盘」。
    /// 恢复 0.1.18 的老语义 —— 抬手没选中就收起，下一次划边从干净状态开始。
    /// 想要「留在屏上」的人可以在设置里打开 `!ring.autopin`。
    var autoPin: Bool = false

    /// 0.1.18 — `hotZone` 已删除（热区可见层整条撤除，Aevon(104) 第 3 条）。
    ///
    /// 0.1.15 加它是为了把「够不着」变成看得见的事，这个目的在 Aevon(102)/(103)
    /// 两轮里已经达到（33 次点击 → 0 次点击）；代价是右侧常驻一条淡青底纹。
    /// 用户明确要求移除，于是连同键 `!ring.hotzone`、设置项、绘制层一起删，
    /// 判定几何（贴边 12 pt）不变。

    /// Every key whose change has to be mirrored to ring.plist. One list, so a
    /// new ring control cannot be added to the UI and forgotten here.
    static let mirroredKeys: Set<String> = [
        "Radius", "IconWidth", "RotationAngle", "Star",
        "DampingFraction", "CustomSpringAnimation",
        "Speed", "!ring.desktop", "!ring.autopin", "SOUND",
    ]

    // MARK: Reading

    static func load() -> RingConfig {
        let store = UserDefaults(suiteName: Aevon.domain)
        let legacy = UserDefaults(suiteName: Aevon.legacyDomain)

        func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
            if let value = store?.object(forKey: key) as? NSNumber {
                return CGFloat(value.doubleValue)
            }
            if let value = legacy?.object(forKey: key) as? NSNumber {
                return CGFloat(value.doubleValue)
            }
            return fallback
        }

        func flag(_ key: String, _ fallback: Bool) -> Bool {
            if store?.object(forKey: key) != nil { return store?.bool(forKey: key) ?? fallback }
            if legacy?.object(forKey: key) != nil { return legacy?.bool(forKey: key) ?? fallback }
            return fallback
        }

        var config = RingConfig()
        config.radius = clamp(number("Radius", 64), 40, 120)
        config.iconWidth = clamp(number("IconWidth", 44), 28, 64)
        config.rotation = clamp(number("RotationAngle", 0), -180, 180)
        config.damping = clamp(number("DampingFraction", 0.82), 0.10, 1.0)
        config.customSpring = flag("CustomSpringAnimation", true)
        config.star = flag("Star", true)
        config.sound = flag("SOUND", false)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        config.desktop = flag("!ring.desktop", true)
        config.autoPin = false   // 0.1.20：跟手已撤，本版一律不固定（见 `autoPin` 字段注释）
        return config
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        return Swift.min(high, Swift.max(low, value))
    }

    // MARK: Snapshot — the cross-process channel

    /// The settings process writes this file after every change; SpringBoard
    /// reads it when the Darwin notification arrives. Preferences alone are
    /// not enough on roothide (Library/Preferences is redirected per process),
    /// and a file is the one thing both processes see the same way.
    var snapshot: [String: Any] {
        return [
            "Radius": Double(radius),
            "IconWidth": Double(iconWidth),
            "RotationAngle": Double(rotation),
            "DampingFraction": Double(damping),
            "CustomSpringAnimation": customSpring,
            "Star": star,
            "SOUND": sound,
            "Speed": Double(speed),
            "summary": summary,
            "desktop": desktop,
            "autoPin": autoPin,
            "writtenAt": Date().timeIntervalSince1970,
        ]
    }

    @discardableResult
    func writeSnapshot() -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        return (snapshot as NSDictionary).write(toFile: Aevon.ringPath, atomically: true)
    }

    static func loadSnapshot() -> RingConfig? {
        guard let dict = NSDictionary(contentsOfFile: Aevon.ringPath) as? [String: Any] else {
            return nil
        }

        func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
            return (dict[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            return (dict[key] as? NSNumber)?.boolValue ?? fallback
        }

        var config = RingConfig()
        config.radius = clamp(number("Radius", 64), 40, 120)
        config.iconWidth = clamp(number("IconWidth", 44), 28, 64)
        config.rotation = clamp(number("RotationAngle", 0), -180, 180)
        config.damping = clamp(number("DampingFraction", 0.82), 0.10, 1.0)
        config.customSpring = flag("CustomSpringAnimation", true)
        config.star = flag("Star", true)
        config.sound = flag("SOUND", false)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        config.desktop = flag("desktop", true)
        config.autoPin = false   // 0.1.20：同 `load()`，忽略存盘值
        return config
    }

    /// What SpringBoard uses: the snapshot first (it is what the operator just
    /// changed), the preference domain second (a fresh install has no file yet).
    static func loadRuntime() -> RingConfig {
        return loadSnapshot() ?? load()
    }

    /// One line for the settings row: what the ring is right now.
    /// Built with interpolation rather than String(format:) on purpose — a
    /// `%d` fed with a Swift Int is a 32/64-bit mismatch waiting to print
    /// garbage on the one row whose job is to tell the truth.
    var summary: String {
        let store = AevonRingStore.bundleIDs()
        return "圆盘 · \(store.count)/\(AevonRingStore.maxCount) App"
    }
}
