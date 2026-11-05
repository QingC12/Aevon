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
    var haptic: Bool = true          // 震动
    var intensity: CGFloat = 0.7     // 强度
    var speed: CGFloat = 1           // 速度

    /// "Put the grip on the home screen." Not one of the master's 81 keys, so
    /// it is prefixed and kept out of the generated table. Ships on: a shape
    /// nobody can see is not a feature.
    var desktop: Bool = true

    /// 0.0.44 — where the summon strip sits, in percent of the screen height
    /// (0 = top edge, 100 = bottom edge, 50 = the middle). A percentage rather
    /// than a point for the same reason the old grip stored a fraction: the
    /// same number means the same place after a rotation.
    var barY: CGFloat = 50

    /// 0.0.49 — 竖条的长度，按**屏幕高度的百分比**存（默认 6 %）。
    ///
    /// Aevon(47) #3 asked whether the "hard to trigger after locking" problem
    /// was about length and width. It is not (see `RingHost.raiseWindow`), but
    /// the operator wants the shape in his own hands, so both became settings.
    /// A percentage rather than points so the strip keeps its proportion on a
    /// 932 pt phone and on an 844 pt one, and after a rotation.
    var barLength: CGFloat = 6

    /// 0.0.49 — 竖条的宽度，按**40 pt 的百分比**存（默认 20 % ⇒ 8 pt）。
    ///
    /// 40 pt is the ceiling on purpose: the strip lives on the screen edge where
    /// pages have their own tap targets (back, list rows, sliders), and a wider
    /// strip would start stealing them. So the UI shows a percentage and the
    /// code never lets the result exceed 40 pt.
    var barWidth: CGFloat = 20

    /// 0.1.19 — 呼盘热区是否覆盖**整条右缘**（默认开）。
    ///
    /// 0.1.18 把竖条改成「亮 0.5 s 就淡出」之后，用户的第一反应是
    /// 「触发条隐藏后无法通过手势呼出圆盘」—— 竖条不只是个按钮，它同时是
    /// **「带子在这儿」的唯一视觉路标**。路标没了，手指就不知道该贴哪一段划；
    /// 而带子只有底部 35 %，上半段划上去连 `pad down` 都不会有，看起来像失效。
    ///
    /// 现在默认整条右缘（上下各留 8 / 12 pt 让开状态栏与 home 条），划哪儿都算；
    /// 留一个开关是为了「某些页面右缘要留给它自己的返回手势」这种局面对得上账。
    var fullEdge: Bool = true

    /// 0.1.19 — 展开后固定，对应母版的 `AutoPin`（「自锁::展开后立即固定」）。
    ///
    /// 母版 `Stheno.dylib` 的偏好结构里有 `autoPin` / `pinSpeed` / `vibratePin`
    /// 三个字段，手势状态里有 `pinned` / `pinSpeed` / `fingerLocation` /
    /// `fingerStartLocation` / `translationPadding` —— 也就是「手指按下时盘跟着
    /// 手指走（fingerLocation + translationPadding），松手时按 pinSpeed 缓动到
    /// 指定位并置 pinned」。我们照这个语义做：手指在屏上时圆心跟手，抬手没选中
    /// 图标就**固定在原地不收起**，再点图标或点盘外才结束。
    ///
    /// 默认开：用户 Aevon(104) 第 2 条要的就是这个（「像 stheno 母版那样跟随手指
    /// 移动，然后固定」）。关掉即回到 0.1.18 的「抬手未选中就收起」。
    var autoPin: Bool = true

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
        "DampingFraction", "CustomSpringAnimation", "VIBRATE", "INTENSITY",
        "Speed", "!ring.desktop", "!ring.barY",
        "!ring.barLength", "!ring.barWidth",
        "!ring.fulledge", "!ring.autopin",
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
        config.haptic = flag("VIBRATE", true)
        config.intensity = clamp(number("INTENSITY", 0.7), 0.10, 1.0)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        config.desktop = flag("!ring.desktop", true)
        config.barY = clamp(number("!ring.barY", 50), 0, 100)
        config.barLength = clamp(number("!ring.barLength", 6), 4, 20)
        config.barWidth = clamp(number("!ring.barWidth", 20), 10, 100)
        config.fullEdge = flag("!ring.fulledge", true)
        config.autoPin = flag("!ring.autopin", true)
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
            "VIBRATE": haptic,
            "INTENSITY": Double(intensity),
            "Speed": Double(speed),
            "summary": summary,
            "desktop": desktop,
            "barY": Double(barY),
            "barLength": Double(barLength),
            "barWidth": Double(barWidth),
            "fullEdge": fullEdge,
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
        config.haptic = flag("VIBRATE", true)
        config.intensity = clamp(number("INTENSITY", 0.7), 0.10, 1.0)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        config.desktop = flag("desktop", true)
        config.barY = clamp(number("barY", 50), 0, 100)
        config.barLength = clamp(number("barLength", 6), 4, 20)
        config.barWidth = clamp(number("barWidth", 20), 10, 100)
        config.fullEdge = flag("fullEdge", true)
        config.autoPin = flag("autoPin", true)
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
