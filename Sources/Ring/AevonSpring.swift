import UIKit

/// V0.3.18（AevonSpringUnifyV318）：圆盘弹簧的**统一物理模型**。
///
/// 为什么不再用 `UIView.animate(withDuration:usingSpringWithDamping:initialSpringVelocity:)`
/// ----------------------------------------------------------------------------------
/// 那是 iOS 7 的老 API，`duration` 的语义是「从起振到静止的总时长」；而 Stheno 用的是
/// SwiftUI `Animation.spring(response:dampingFraction:blendDuration:)`（二进制实证：符号
/// `_$s7SwiftUI9AnimationV6spring8response15dampingFraction13blendDurationACSd_S2dtFZ`
/// 在 `Stheno.dylib` 里出现 4 处），其中 `response` 是**一个振荡周期**。两个数不是
/// 同一个物理量 —— 拿 UIKit 的 0.52 去对 Stheno 的手感，怎么调都对不上。
///
/// 0.3.17 及以前的圆盘上同时跑着五种弹法，阻尼比从 0.34 跨到 0.78：
///   · 划过放大+跳跃  UIView.animate(0.52s, ζ 0.34, v 3.4)
///   · 图标入场弹射  UIViewPropertyAnimator(0.55s, ζ 0.55, v 0.4)
///   · 旋转跟手      手写积分 k=140 c=16（等效 response 0.531 / ζ 0.676）
///   · 收起吸附      0.3s / ζ 0.78 / v 0.5
///   · 开合淡入      easeOut 0.16 / 0.26
/// 五条弹道互相打架，观感就是「不连贯」—— 这不是某一个数值调偏了。
///
/// 本文件把 (response, ζ) 直接换算成 UIKit 的物理参数：
///     ω0 = 2π / response
///     k  = ω0²          （mass 取 1）
///     c  = 2ζω0
/// SwiftUI 内部解算的也正是这三样，所以这组参数与 Stheno 的 spring 是同一族。
enum AevonSpring {

    /// 统一弹簧参数。`response` 单位秒（一个振荡周期），`dampingFraction` 0~1。
    static func params(response: Double,
                       dampingFraction: Double,
                       initialVelocity: CGVector = .zero) -> UISpringTimingParameters {
        let r = max(response, 0.05)
        let z = min(max(dampingFraction, 0.05), 1.0)
        let w0 = 2.0 * Double.pi / r
        // ⛔ UISpringTimingParameters 的四个参数都是 CGFloat —— Double 不会自动桥接，必须显式转。
        return UISpringTimingParameters(mass: 1,
                                        stiffness: CGFloat(w0 * w0),
                                        damping: CGFloat(2.0 * z * w0),
                                        initialVelocity: initialVelocity)
    }

    /// 同一组 (response, ζ) 换算成手写积分器要的 (刚度, 阻尼系数)，mass 取 1。
    /// 圆盘旋转跟手走的是半隐式欧拉积分（`AevonRingMenu.stepDamping`），
    /// 只有换成同一组系数，它才和其它四条弹道是同一个手感族。
    static func coefficients(response: Double,
                             dampingFraction: Double) -> (stiffness: CGFloat, damping: CGFloat) {
        let r = max(response, 0.05)
        let z = min(max(dampingFraction, 0.05), 1.0)
        let w0 = 2.0 * Double.pi / r
        return (CGFloat(w0 * w0), CGFloat(2.0 * z * w0))
    }

    // MARK: - 用户可调阻尼（临时项）

    /// 默认阻尼比。
    ///
    /// V0.3.19（AevonHoverTrailV319）：0.72 → **0.60**。
    /// ζ 只决定**过冲**，管不了起步：0.72 的峰值过冲只有 3.8%，划过时几乎看不出「弹」；
    /// 0.60 是 9.5%，配合 response 0.28 才有「抬起来 → 略微超调 → 落回去」那一下。
    /// 再往下（0.5）过冲 16.3%，会在快速连划时显得晃 —— 滑条下限就是 0.5。
    static let defaultDampingFraction: Double = 0.60

    /// ⛔ **临时项**（用户 2026-10-30 明确要求）：动画定型后会把设置里的滑条删掉，
    /// 这里改成直接返回常量。因为调用点拿的是这个函数，删滑条时只需把函数体换掉，
    /// `AevonRingMenu` 一行都不用动。
    ///
    /// ⚠️ 只在**圆盘展开那一刻**调一次（`AevonRingMenu.present`），不许进 `setHovered`
    /// 这种逐帧路径 —— `AevonPrefs` 走 CFPreferences，是跨进程 IPC，放进热路径会拖慢
    /// 触摸响应（`AevonPrefs.synchronize` 的注释里记着这条）。
    static func userDampingFraction() -> Double {
        let v = AevonPrefs.double("RingSpringDamping", default: defaultDampingFraction)
        return min(max(v, 0.50), 1.00)
    }
}
