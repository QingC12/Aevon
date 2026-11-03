//
//  RingModel.swift — Aevon, carrier shape ("承载形状").
//
//  Pure numbers: reading the 12 Ring keys, and turning them into icon
//  positions. No UIKit, no side effects, so this file can be reasoned about
//  (and unit-checked) without a device.
//
//  Angle convention, fixed here once:
//      0°   = straight up (12 o'clock)
//      +90° = to the right
//      +180°= straight down
//  i.e. clockwise, matching how a person reads a "旋转角" slider. Everything
//  else in the project (view code, preview guide, documents) uses this.
//
//  Where the numbers come from (reverse engineering, 2026-10-14):
//      RingEnv ivars: _radius _iconWidth _rotateDegree _tailDegree _angleScale
//      zh-Hans: RTSIF 圆盘 / RTSIH 半圆盘 / RTSIQ 直角盘 / RTSIZ 任意
//      GIF measurement (证据/stheno图标动画.GIF, 393pt-wide screen):
//      radius ≈ 54 pt, icon ≈ 46 pt → consistent with Radius=64, IconWidth=44
//      at the master's own scale factor.
//

import Foundation
import CoreGraphics

// MARK: - Shape

enum RingShape: Int {
    case full = 0       // RTSIF 圆盘
    case half           // RTSIH 半圆盘
    case quarter        // RTSIQ 直角盘
    case free           // RTSIZ 任意角度

    var title: String {
        switch self {
        case .full:    return "圆盘"
        case .half:    return "半圆盘"
        case .quarter: return "直角盘"
        case .free:    return "任意角度"
        }
    }

    /// Degrees actually covered. `free` is derived from 旋转角/尾角 instead.
    var sweep: CGFloat {
        switch self {
        case .full:    return 360
        case .half:    return 180
        case .quarter: return 90
        case .free:    return 0
        }
    }

    /// A full circle closes on itself, so its icon count is not "sweep/step+1".
    var isClosed: Bool { self == .full }
}

// MARK: - Configuration

struct RingConfig {

    var shape: RingShape = .full
    var radius: CGFloat = 64
    var iconWidth: CGFloat = 44
    var rotation: CGFloat = 0        // 旋转角
    var tail: CGFloat = 0            // 尾角
    var damping: CGFloat = 0.82      // 阻尼系数
    var customSpring: Bool = true    // 动画弹性
    var star: Bool = true            // 收藏（长按图标）
    var haptic: Bool = true          // 震动
    var intensity: CGFloat = 0.7     // 强度
    var speed: CGFloat = 1           // 速度

    /// RingEnv._pinSpeed. How fast a 收藏 lands in its new place. Not one of
    /// the 81 keys — the master keeps it as a derived value, so it is derived
    /// here too instead of being invented as a control.
    var pinSpeed: CGFloat = 1.6

    /// "Put the grip on the home screen." Not one of the master's 81 keys, so
    /// it is prefixed and kept out of the generated table. Ships on: a shape
    /// nobody can see is not a feature.
    var desktop: Bool = true

    /// Every key whose change has to be mirrored to ring.plist. One list, so a
    /// new ring control cannot be added to the UI and forgotten here.
    static let mirroredKeys: Set<String> = [
        "RTSIF", "RTSIH", "RTSIQ", "RTSIZ",
        "Radius", "IconWidth", "RotationAngle", "LastIconAngle", "Star",
        "DampingFraction", "CustomSpringAnimation", "VIBRATE", "INTENSITY",
        "Speed", "!ring.desktop",
    ]

    /// Gap kept between two neighbouring icons, in points. The master's own
    /// screenshots never show icons touching, so this is a floor, not a taste.
    static let iconGap: CGFloat = 6

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

        // Mutually exclusive in the master's UI. Order matters: if more than
        // one is on, the most specific wins, so a stray write can never leave
        // the ring in a shape nothing can describe.
        if flag("RTSIZ", false) {
            config.shape = .free
        } else if flag("RTSIQ", false) {
            config.shape = .quarter
        } else if flag("RTSIH", false) {
            config.shape = .half
        } else {
            config.shape = .full
        }

        config.radius = clamp(number("Radius", 64), 40, 120)
        config.iconWidth = clamp(number("IconWidth", 44), 28, 64)
        config.rotation = clamp(number("RotationAngle", 0), -180, 180)
        config.tail = clamp(number("LastIconAngle", 0), -180, 180)
        config.damping = clamp(number("DampingFraction", 0.82), 0.10, 1.0)
        config.customSpring = flag("CustomSpringAnimation", true)
        config.star = flag("Star", true)
        config.haptic = flag("VIBRATE", true)
        config.intensity = clamp(number("INTENSITY", 0.7), 0.10, 1.0)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        config.desktop = flag("!ring.desktop", true)
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
            "shape": shape.title,
            "shapeIndex": shape.rawValue,
            "RTSIF": shape == .full,
            "RTSIH": shape == .half,
            "RTSIQ": shape == .quarter,
            "RTSIZ": shape == .free,
            "Radius": Double(radius),
            "IconWidth": Double(iconWidth),
            "RotationAngle": Double(rotation),
            "LastIconAngle": Double(tail),
            "DampingFraction": Double(damping),
            "CustomSpringAnimation": customSpring,
            "Star": star,
            "VIBRATE": haptic,
            "INTENSITY": Double(intensity),
            "Speed": Double(speed),
            "capacity": capacity,
            "summary": summary,
            "desktop": desktop,
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
        // A snapshot without a readable shape was not written by this version;
        // ignore it instead of inventing a geometry from half a file.
        guard let raw = (dict["shapeIndex"] as? NSNumber)?.intValue,
              let shape = RingShape(rawValue: raw) else { return nil }

        func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
            return (dict[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            return (dict[key] as? NSNumber)?.boolValue ?? fallback
        }

        var config = RingConfig()
        config.shape = shape
        config.radius = clamp(number("Radius", 64), 40, 120)
        config.iconWidth = clamp(number("IconWidth", 44), 28, 64)
        config.rotation = clamp(number("RotationAngle", 0), -180, 180)
        config.tail = clamp(number("LastIconAngle", 0), -180, 180)
        config.damping = clamp(number("DampingFraction", 0.82), 0.10, 1.0)
        config.customSpring = flag("CustomSpringAnimation", true)
        config.star = flag("Star", true)
        config.haptic = flag("VIBRATE", true)
        config.intensity = clamp(number("INTENSITY", 0.7), 0.10, 1.0)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        config.desktop = flag("desktop", true)
        return config
    }

    /// What SpringBoard uses: the snapshot first (it is what the operator just
    /// changed), the preference domain second (a fresh install has no file yet).
    static func loadRuntime() -> RingConfig {
        return loadSnapshot() ?? load()
    }

    // MARK: Derived

    /// Degrees between neighbours, or 0 when the shape cannot hold two icons.
    var sweep: CGFloat {
        if shape.isClosed { return 360 }
        if shape == .free {
            let span = tail - rotation
            return abs(span) < 5 ? 360 : span
        }
        return shape.sweep
    }

    /// A ring that covers a full turn — either because the shape is closed or
    /// because "任意" was dragged until the tail met the head.
    var closedRing: Bool {
        return shape.isClosed || abs(sweep) >= 359.5
    }

    /// Where the arc begins.
    ///
    /// A closed ring starts at 旋转角 and wraps. The half and quarter shapes are
    /// centred on 旋转角 (so 0° means "straight up"), which is how the master's
    /// own screenshots read. 任意 starts at 旋转角 and ends at 尾角 — that is
    /// exactly the pair the two sliders name.
    var arcStart: CGFloat {
        if closedRing { return rotation }
        if shape == .free { return rotation }
        return rotation - sweep / 2
    }

    /// The arc at a given expansion progress. RingEnv calls that progress
    /// `_angleScale`; it is 0 → 1, not a scale factor.
    func arc(progress: CGFloat) -> RingArc {
        return RingArc(start: arcStart, sweep: sweep,
                       progress: Swift.min(1, Swift.max(0, progress)))
    }

    /// How many icons fit without touching. A closed ring must also close the
    /// gap back to the first icon, which is why it uses a plain division.
    var capacity: Int {
        let step = 2 * asin(Swift.min(1, (iconWidth + RingConfig.iconGap) / (2 * radius)))
        guard step > 0.01 else { return 3 }
        let span = abs(sweep) * .pi / 180
        if closedRing {
            return Swift.max(3, Swift.min(12, Int(span / step)))
        }
        return Swift.max(2, Swift.min(12, Int(span / step) + 1))
    }

    /// `capacity` for a geometry this config does not have yet. Written as a
    /// copy rather than as a second formula: two spellings of one rule is how
    /// "the ring holds 7" and "the ring holds 8" both end up true.
    private func capacity(radius r: CGFloat, iconWidth w: CGFloat) -> Int {
        var probe = self
        probe.radius = r
        probe.iconWidth = w
        return probe.capacity
    }

    /// 0.0.38 — 图标数量不该被几何偷偷截掉一半。
    ///
    /// Aevon(36): the operator put nine apps in the ring, tapped the dot, and
    /// counted seven. Nothing had failed — `capacity` is a fact about a circle
    /// (R64 with 44 pt icons holds exactly seven), and the eighth icon was never
    /// built. Silently truncating the operator's own list is the wrong answer to
    /// a geometry question, so the geometry gives way instead: the icons shrink
    /// first (44 → 26 pt, the floor the settings slider already uses), and only
    /// when that is exhausted does the ring grow (64 → 120 pt, the slider's own
    /// ceiling). A list that does not fit even at R120 / 26 pt is still cut, and
    /// the caller logs that instead of pretending.
    ///
    /// The operator's own numbers are never written back: this is a rendering
    /// decision, and the sliders stay the master control.
    func fitted(to count: Int) -> (radius: CGFloat, iconWidth: CGFloat) {
        var r = radius
        var w = iconWidth
        var steps = 0
        while capacity(radius: r, iconWidth: w) < count, steps < 64 {
            steps += 1
            if w > 26 {
                w = Swift.max(26, w - 2)
            } else if r < 120 {
                r = Swift.min(120, r + 4)
            } else {
                break
            }
        }
        return (r, w)
    }

    /// One line for the settings row: what the ring is right now.
    /// Built with interpolation rather than String(format:) on purpose — a
    /// `%d` fed with a Swift Int is a 32/64-bit mismatch waiting to print
    /// garbage on the one row whose job is to tell the truth.
    var summary: String {
        let angle: String
        if shape == .free {
            angle = "\(Int(rotation))°→\(Int(tail))°"
        } else if rotation == 0 {
            angle = "起点 0°"
        } else {
            angle = "起点 \(Int(rotation))°"
        }
        return "\(shape.title) · R\(Int(radius)) · \(Int(iconWidth))pt · \(capacity) 个 · \(angle)"
    }
}

// MARK: - Geometry

/// The sweep, as a value the animation can carry around.
///
/// 母本 P4 的四条（逆向 A 级）:
///   1  `_angleScale` 是展开进度 0→1，不是缩放；
///   2  可见弧段 = `_rotationAngle` → `_tailDegree` 按 `_angleScale` 扫过；
///   3  每个图标按自身角度决定出场时刻 → 依次弹出（stagger）；
///   4  radius / iconWidth / offset 随进度同步插值 → 从边缘长出来。
///
/// All four are expressed by this one struct plus `slotFraction`: nothing else
/// in the animation needs to know what a shape is.
struct RingArc {
    let start: CGFloat      // degrees
    let sweep: CGFloat      // signed degrees
    var progress: CGFloat   // 0...1

    /// Where the tail currently is. Icons beyond this have not appeared yet.
    var visibleEnd: CGFloat { return start + sweep * progress }

    /// How far along the sweep a given angle sits: 0 at the head, 1 at the
    /// tail. This is the icon's own cue — 母本第 3 条.
    func fraction(of angle: CGFloat) -> CGFloat {
        guard abs(sweep) > 0.01 else { return 1 }
        return (angle - start) / sweep
    }

    /// True once the sweep has passed that angle.
    func reached(_ angle: CGFloat) -> Bool {
        return fraction(of: angle) <= progress + 0.0001
    }
}

struct RingSlot {
    let angle: CGFloat      // degrees, 0 = up, clockwise
    let center: CGPoint     // in the host view's coordinate space
    let fraction: CGFloat   // 0 = head of the arc, 1 = tail
}

/// Places `count` icons on the configured shape around `pivot`.
///
/// Open shapes (half / quarter / free) spread their icons *inclusive* of both
/// ends, so the first and last icon sit exactly on the boundary. A closed ring
/// divides evenly instead, so there is no double-occupied angle at 0°/360°.
func ringSlots(pivot: CGPoint, count: Int, config: RingConfig,
               radius: CGFloat? = nil, rotation: CGFloat? = nil) -> [RingSlot] {
    guard count > 0 else { return [] }

    let useRadius = radius ?? config.radius
    let useRotation = rotation ?? config.rotation
    var tuned = config
    tuned.rotation = useRotation
    let start = tuned.arcStart
    let span = tuned.sweep

    var angles: [CGFloat] = []
    angles.reserveCapacity(count)

    if config.closedRing {
        let step = 360 / CGFloat(count)
        for index in 0..<count {
            angles.append(start + CGFloat(index) * step)
        }
    } else {
        let step = count > 1 ? span / CGFloat(count - 1) : 0
        for index in 0..<count {
            angles.append(start + CGFloat(index) * step)
        }
    }

    let arc = RingArc(start: start, sweep: span, progress: 1)
    return angles.map { angle in
        let radians = angle * .pi / 180
        let point = CGPoint(x: pivot.x + useRadius * sin(radians),
                            y: pivot.y - useRadius * cos(radians))
        return RingSlot(angle: angle, center: point, fraction: arc.fraction(of: angle))
    }
}
