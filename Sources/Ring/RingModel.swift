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
    var haptic: Bool = true          // 震动
    var intensity: CGFloat = 0.7     // 强度
    var speed: CGFloat = 1           // 速度

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
        config.haptic = flag("VIBRATE", true)
        config.intensity = clamp(number("INTENSITY", 0.7), 0.10, 1.0)
        config.speed = clamp(number("Speed", 1), 0.2, 2.0)
        return config
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        return Swift.min(high, Swift.max(low, value))
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

struct RingSlot {
    let angle: CGFloat      // degrees, 0 = up, clockwise
    let center: CGPoint     // in the host view's coordinate space
}

/// Places `count` icons on the configured shape around `pivot`.
///
/// Open shapes (half / quarter / free) spread their icons *inclusive* of both
/// ends, so the first and last icon sit exactly on the boundary. A closed ring
/// divides evenly instead, so there is no double-occupied angle at 0°/360°.
func ringSlots(pivot: CGPoint, count: Int, config: RingConfig) -> [RingSlot] {
    guard count > 0 else { return [] }

    var angles: [CGFloat] = []
    angles.reserveCapacity(count)

    if config.closedRing {
        let step = 360 / CGFloat(count)
        for index in 0..<count {
            angles.append(config.rotation + CGFloat(index) * step)
        }
    } else {
        let span = config.sweep
        let start = config.shape == .free ? config.rotation : config.rotation - span / 2
        let step = count > 1 ? span / CGFloat(count - 1) : 0
        for index in 0..<count {
            angles.append(start + CGFloat(index) * step)
        }
    }

    return angles.map { angle in
        let radians = angle * .pi / 180
        let point = CGPoint(x: pivot.x + config.radius * sin(radians),
                            y: pivot.y - config.radius * cos(radians))
        return RingSlot(angle: angle, center: point)
    }
}
