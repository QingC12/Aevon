//
//  RingModel.swift — Aevon, carrier shape ("承载形状").
//
//  Pure numbers: reading the ring keys and turning them into icon positions.
//  No UIKit, no side effects, so this file can be reasoned about (and
//  unit-checked) without a device.
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
//  0.0.41 — 圆盘 only, and more than one of them.
//
//  The master ships four shapes and the operator asked for one: 圆盘. The other
//  three are gone from the model *and* from Settings, not hidden behind a
//  default, because a control that writes a key nothing reads is a lie told in
//  a list. RTSIH / RTSIQ / RTSIZ / LastIconAngle are recorded as dropped in
//  tools/gen-settings.py so the 81-key reconciliation still closes.
//
//  What replaces them is the one thing a single circle could not do: grow
//  outwards. A circle holds a fixed number of icons at a given radius, and
//  0.0.38-0.0.40 answered "more icons than fit" by silently growing the radius
//  or shrinking the icons — both of which are the geometry arguing with the
//  operator. Now the ring keeps its radius and adds a ring: index order fills
//  the inner circle first, then the next one out, and only the count decides
//  how many.
//

import Foundation
import CoreGraphics

// MARK: - Configuration

struct RingConfig {

    var radius: CGFloat = 64         // 内圈半径
    var iconWidth: CGFloat = 44
    var rotation: CGFloat = 0        // 起点角
    var damping: CGFloat = 0.82      // 阻尼系数
    var customSpring: Bool = true    // 动画弹性
    var star: Bool = true            // 收藏（长按图标）
    var haptic: Bool = true          // 震动
    var intensity: CGFloat = 0.7     // 强度
    var speed: CGFloat = 1           // 速度

    /// RingEnv._pinSpeed. How fast a 收藏 lands in its new place. Not one of
    /// the master's 81 keys — the master keeps it as a derived value, so it is
    /// derived here too instead of being invented as a control.
    var pinSpeed: CGFloat = 1.6

    /// "Put the grip on the home screen." Not one of the master's 81 keys, so
    /// it is prefixed and kept out of the generated table. Ships on: a shape
    /// nobody can see is not a feature.
    var desktop: Bool = true

    /// Every key whose change has to be mirrored to ring.plist. One list, so a
    /// new ring control cannot be added to the UI and forgotten here.
    static let mirroredKeys: Set<String> = [
        "Radius", "IconWidth", "RotationAngle", "Star",
        "DampingFraction", "CustomSpringAnimation", "VIBRATE", "INTENSITY",
        "Speed", "!ring.desktop",
    ]

    /// Gap kept between two neighbouring icons, in points. The master's own
    /// screenshots never show icons touching, so this is a floor, not a taste.
    /// It is also the gap between two rings: 44 + 6 = 50 pt of radial distance
    /// is what keeps an icon on ring 2 from overlapping one on ring 1.
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
            "capacity": perRing(0),
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
        return config
    }

    /// What SpringBoard uses: the snapshot first (it is what the operator just
    /// changed), the preference domain second (a fresh install has no file yet).
    static func loadRuntime() -> RingConfig {
        return loadSnapshot() ?? load()
    }

    // MARK: Rings — 0.0.41 的内圈 / 外圈几何

    /// Radius of ring `ring`. Ring 0 is the operator's own 半径 slider; every
    /// ring further out clears the previous one by icon + gap, which is the
    /// same number that keeps two neighbours on one ring apart.
    func radius(of ring: Int) -> CGFloat {
        if ring <= 0 { return Swift.max(8, radius) }
        return Swift.max(8, radius) + CGFloat(ring) * (iconWidth + RingConfig.iconGap)
    }

    /// How many icons fit on one ring without touching. This is the same chord
    /// arithmetic 0.0.38 used for the whole circle, applied per ring: a chord
    /// of icon + gap subtends 2·asin(c / 2r) at the centre.
    func perRing(_ ring: Int) -> Int {
        let r = radius(of: ring)
        let chord = iconWidth + RingConfig.iconGap
        guard r > chord / 2 else { return 3 }
        let step = 2 * asin(Swift.min(1, chord / (2 * r)))
        guard step > 0.01 else { return 3 }
        return Swift.max(3, Int((2 * Double.pi) / Double(step)))
    }

    /// How many rings `count` icons need. Summed capacity, not a division by
    /// the inner ring: the second ring holds more than the first, so eight
    /// icons fit one ring while nine need two only because ring 0 is full.
    func ringCount(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        var total = 0
        var ring = 0
        while total < count, ring < 8 {
            total += perRing(ring)
            ring += 1
        }
        return Swift.max(1, ring)
    }

    /// How many icons land on each ring.
    ///
    /// Filling the inner ring to the brim and dropping the remainder outside
    /// would put a single lonely icon on ring 2 for nine apps. Spreading them
    /// evenly looks like one shape growing rather than one shape with a stray,
    /// and the two bounds keep it honest: `floorHere` is the number the outer
    /// rings cannot absorb (so nothing overflows), `even` is the fair share.
    func distribution(for count: Int) -> [Int] {
        let rings = ringCount(for: count)
        guard rings > 0 else { return [] }
        var counts = [Int](repeating: 0, count: rings)
        var remaining = count
        for ring in 0..<rings {
            var later = 0
            if ring + 1 < rings {
                for outer in (ring + 1)..<rings { later += perRing(outer) }
            }
            let floorHere = Swift.max(0, remaining - later)
            let even = Int((Double(remaining) / Double(rings - ring)).rounded(.up))
            counts[ring] = Swift.min(perRing(ring), Swift.max(floorHere, even))
            remaining -= counts[ring]
        }
        return counts
    }

    /// One line for the settings row: what the ring is right now.
    /// Built with interpolation rather than String(format:) on purpose — a
    /// `%d` fed with a Swift Int is a 32/64-bit mismatch waiting to print
    /// garbage on the one row whose job is to tell the truth.
    var summary: String {
        let angle = rotation == 0 ? "起点 0°" : "起点 \(Int(rotation))°"
        return "圆盘 · R\(Int(radius)) · \(Int(iconWidth))pt · 内圈 \(perRing(0)) · \(angle)"
    }
}

// MARK: - Geometry

struct RingSlot {
    let angle: CGFloat      // degrees, 0 = up, clockwise
    let center: CGPoint     // in the host view's coordinate space
    let radius: CGFloat     // this slot's own ring radius
    let ring: Int           // 0 = 内圈
    let fraction: CGFloat   // 0 = first icon to appear, 1 = last
}

/// Places `count` icons on concentric rings around `pivot`.
///
/// The array is in the operator's own order and the view draws it by index, so
/// "sorting" and "which ring" are the same fact read once: index 0 is the head
/// of the inner ring, and the list wraps outwards. Ring 2 onwards is rotated by
/// half a step so two rings with the same count do not line up into spokes.
func ringSlots(pivot: CGPoint, count: Int, config: RingConfig) -> [RingSlot] {
    guard count > 0 else { return [] }

    let counts = config.distribution(for: count)
    var slots: [RingSlot] = []
    slots.reserveCapacity(count)
    var placed = 0

    for (ring, n) in counts.enumerated() where n > 0 {
        let r = config.radius(of: ring)
        let step = 360 / CGFloat(n)
        let phase: CGFloat = ring % 2 == 0 ? 0 : step / 2
        for index in 0..<n {
            let angle = config.rotation + phase + CGFloat(index) * step
            let radians = angle * .pi / 180
            let point = CGPoint(x: pivot.x + r * sin(radians),
                                y: pivot.y - r * cos(radians))
            let fraction = count > 1 ? CGFloat(placed) / CGFloat(count - 1) : 0
            slots.append(RingSlot(angle: angle, center: point, radius: r,
                                  ring: ring, fraction: fraction))
            placed += 1
        }
    }
    return slots
}
