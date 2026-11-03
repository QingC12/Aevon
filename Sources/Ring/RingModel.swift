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

    /// Every key whose change has to be mirrored to ring.plist. One list, so a
    /// new ring control cannot be added to the UI and forgotten here.
    static let mirroredKeys: Set<String> = [
        "Radius", "IconWidth", "RotationAngle", "Star",
        "DampingFraction", "CustomSpringAnimation", "VIBRATE", "INTENSITY",
        "Speed", "!ring.desktop", "!ring.barY",
        "!ring.barLength", "!ring.barWidth",
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
