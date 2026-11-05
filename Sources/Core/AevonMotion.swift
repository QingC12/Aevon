import UIKit

/// 0.1.26 — 悬浮窗所有过渡的唯一来源。
///
/// 参数不是拍出来的。`Stheno.dylib`（0.1.23，2 153 664 B）里有 **48 处**
/// `Animation.spring(response:dampingFraction:blendDuration:)` 调用，它们全部内联
/// 成同一个工厂形状，逐字节一致：
///
///     0x50d4  bl   #0x51454                 ; k = 读「动画弹性」设置
///     0x50d8  mov  x8, #0x3333333333333333
///     0x50dc  movk x8, #0x3fd3, lsl #48     ; d1 = 0.3
///     0x50e0  fmov d1, x8
///     0x50e4  fdiv d8, d1, d0               ; response = 0.3 / k
///     0x50ec  fmov d1, d0                   ; damping  = k
///     0x50f0  movi d2, #0                   ; blend    = 0
///     0x50f4  fmov d0, d8
///     0x50f8  bl   Animation.spring(…)      ; ← 同一个 stub，48 个调用点
///
/// 那个 `k` 的默认值在同函数的常量池分支里：`__const@0xb4498 = 1.1`
/// （`SettingEnv.__dampingFraction`，界面文案 `DampingFraction = 阻尼系数`）。
/// 于是母本整 App 只有**一套**弹簧：**0.2727 s / dampingFraction 1.1 / blend 0**。
/// 过阻尼、不回弹、收尾干净 —— 这是「点了之后马上就是结果」的观感来源。
///
/// 另外三处非弹性过渡是 `easeInOut(duration: 0.2969)`（3 处）与
/// `easeIn(duration: 0.1484)`（3 处），进/出场用的过渡造型则是
/// `.move(edge: .top/.bottom).combined(with: .opacity)`（0x1b9a0 / 0x1bb2c
/// 两组，`mov w0, #2` = Edge.bottom、`mov w0, #0` = Edge.top）。
///
/// 复刻到 UIKit 的口径：
///   · 所有几何变化（开、关、移动、复位、停靠补位、升降主窗）都走本文件的
///     `spring`，一次状态变化 = **一个**动画块（嵌套调用自动并入外层）；
///   · 入场/出场用「缩放 + 淡入淡出」（对应 `AnyTransition` 的 scale/opacity 组合；
///     母本对边条用 move，对卡片用缩放 —— 卡片没有边可贴，move 没有落点）；
///   · `dampingFraction 1.1` 在 UIKit 侧收敛到 1.0：二者在 0.27 s 内都看不到
///     回弹，而 UIKit 的 `usingSpringWithDamping:` 只定义了 0…1。
enum AevonMotion {

    // MARK: - 母本的三个数

    /// 「动画弹性」k。母本默认 1.1（`__const@0xb4498`）。
    /// 用户把滑条调小 → 时长变长、回弹变明显，与母本同向。
    static var elasticity: CGFloat = 1.1

    /// `response = 0.3 / k`。0.2 是下限，防止滑条到底时算出十几秒的动画。
    static var response: TimeInterval { TimeInterval(0.3 / Swift.max(0.2, elasticity)) }

    /// 卡片入场起点。母本用 SwiftUI 的 `.scale` 过渡，默认锚点是中心、默认
    /// 比例 0（`AnyTransition.scale` 的语义）。0 会让整张卡在第一帧「从无到
    /// 有」，观感上是一次跳变。
    ///
    /// 0.1.28 — 从 0.94 改成 0.74，这一条是「Q 弹」能不能看见的唯一开关。
    /// 关键不是阻尼，是**行程**：弹簧的过冲幅度是相对「起点→终点」这段行程
    /// 的比例，不是相对终值的比例。ζ=0.42 的过冲约 25 %，0.94→1 的行程只有
    /// 6 %，弹出去 1.5 % —— 那是像素级的抖动，肉眼看不见；0.74→1 的行程
    /// 26 %，同样阻尼下峰值到 1.06，才是「弹一下」。
    static let enterScale: CGFloat = 0.74

    /// 入场弹簧。母本那一套是过阻尼（damping 1.1）、不回弹；入场单独用一条
    /// 欠阻尼曲线，这是唯一一处有意偏离母本的地方 —— 它换的不是观感风格，
    /// 是「这个窗口刚被放到屏幕上」这件事本身要有分量。
    ///
    /// 0.44 s 比母本的 0.27 s 长：弹簧要跑完一个完整的「冲过头 → 回落」才
    /// 叫弹，压缩时长只会把回落砍掉（UIKit 在 duration 到点时直接吸附终值，
    /// 那就是一次硬跳）。
    static let enterDuration: TimeInterval = 0.44
    static let enterDamping: CGFloat = 0.42
    /// 初速度（1.0 = 一秒走完全程）。0.5 让前段更冲，弹的感觉从起手就有。
    static let enterVelocity: CGFloat = 0.5

    /// 出场（关窗）。0.1.28 — 时间从 0.2 s 压到 0.17 s：关闭是「快走」，
    /// 慢一点都不如不关。ease-in 让收缩由慢到快，像被吸走而不是自己躺下去。
    static let exitDuration: TimeInterval = 0.17
    static let exitScale: CGFloat = 0.82

    // MARK: - 合并

    /// 嵌套深度。一次操作里可能连着调好几个会改几何的函数（升主窗 → 降级旧主窗
    /// → 重排停靠列），它们必须落在**同一个** spring 里，否则屏幕上是三段时间
    /// 不同步的动画 —— 那正是用户说的「看起来像 1 的画面直接变成 2」。
    private static var depth = 0

    /// 第一次真的走一次弹簧时留一行。它有两个用处：
    ///   ① 交付审计在二进制里 grep `win: motion spring response=`，证明这个模块
    ///      真的进了 Aevon.dylib（`-dead_strip` 会把没人调的代码整段剥掉）；
    ///   ② 真机上「动画到底用的哪一组参数」不必再靠记忆，日志里就写着。
    /// 只打一次：动画每点一下都跑，每次都写会把日志糊掉。
    private static var announced = false

    /// 在母本那一套弹簧里执行 `changes`。嵌套调用直接执行，由最外层统一收口。
    /// 返回 true 表示这一层真的开了动画（调用方可以据此决定要不要接 completion）。
    @discardableResult
    static func spring(_ changes: @escaping () -> Void,
                       completion: ((Bool) -> Void)? = nil) -> Bool {
        depth += 1
        if depth > 1 {
            changes()
            depth -= 1
            if depth == 0 { drain() }
            return false
        }
        if !announced {
            announced = true
            Log.write(String(format: "win: motion spring response=%.3f damping=%.3f blend=%.3f",
                             response, Swift.min(1, Swift.max(0.05, elasticity)), 0))
        }
        UIView.animate(withDuration: response,
                       delay: 0,
                       usingSpringWithDamping: Swift.min(1, Swift.max(0.05, elasticity)),
                       initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: changes,
                       completion: completion)
        // 动画块已经登记完，这一拍里排队的「块外手术」现在可以跑了 —— 仍然是
        // 同一拍 runloop，屏幕上与这次 spring 同时开始。
        depth -= 1
        if depth == 0 { drain() }
        return true
    }

    // MARK: - 动画块之外

    /// 0.1.27 — 排队要「在动画块之外」执行的动作。
    ///
    /// 在 `spring` 的闭包里再开一次 `UIView.animate` 就是嵌套动画块：UIKit 对
    /// 它没有定义，外层正在动的属性会把内层吞掉一半。而停靠收缩必须是自己的一次
    /// 动画 —— 它动的是 `transform`，外面那层同时还在动 `bounds`/`center`，
    /// 两者写在同一个块里，UIKit 会按来源各插一条曲线（那正是「吸附时翻转一下」
    /// 的形状）。
    ///
    /// 所以：排队，等最外层的 `UIView.animate` 返回后立刻跑。同一拍 runloop，
    /// 肉眼上与外面的 spring 是同时开始的。
    static func outside(_ work: @escaping () -> Void) {
        queued.append(work)
        if depth == 0 { drain() }
    }

    private static var queued: [() -> Void] = []

    /// 已经在清队列。收缩动画自己也会走 `spring`，它结束时又会调到这里 ——
    /// 没有这个闩，队列会被内外两层同时消费，顺序就乱了。
    private static var draining = false

    private static func drain() {
        guard draining == false else { return }
        draining = true
        while queued.isEmpty == false {
            // 先摘再跑：这一段自己可能又往队列里塞东西，那些接在后面处理。
            queued.removeFirst()()
        }
        draining = false
    }

    /// 现在是「已经在一次过渡里」吗。给圆角这类**不是** UIView 动画属性的东西用：
    /// `cornerRadius` 在 `UIView.animate` 块里是硬赋值，必须自己补一条 CABasicAnimation。
    static var inFlight: Bool { depth > 0 }

    // MARK: - 入场 / 出场

    /// 出场（关窗）：缩回 + 淡出，然后才把窗口拆掉。
    ///
    /// 不用 `spring` 的默认时长：母本关窗是「消失」，过阻尼的 0.27 s 收尾放在
    /// 关闭上会显得拖。0.17 s 的 ease-in 与 0.27 s 的 spring 在肉眼上是同一档，
    /// 但加速段的尾巴让「没了」这件事显得干脆。
    ///
    /// 0.1.28 — 缩到 0.82（0.1.26 是 0.94）。6 % 的收缩在淡出旁边看不出来，
    /// 一整张卡片要掉 18 % 才有「收走」的形状。
    static func exit(_ views: [UIView], completion: @escaping () -> Void) {
        for view in views { view.isUserInteractionEnabled = false }
        if !announcedExit {
            announcedExit = true
            Log.write(String(format: "win: exit shrink 1.00->%.2f t=%.2f ease-in",
                             exitScale, exitDuration))
        }
        UIView.animate(withDuration: exitDuration, delay: 0,
                       options: [.curveEaseIn, .beginFromCurrentState],
                       animations: {
                           for view in views {
                               view.alpha = 0
                               view.transform = CGAffineTransform(scaleX: exitScale,
                                                                  y: exitScale)
                           }
                       },
                       completion: { _ in completion() })
    }

    private static var announcedExit = false

    /// 入场（开窗）：从 `enterScale` 弹到 1。
    ///
    /// 0.1.28 — 这是全工程唯一一条**欠阻尼**曲线（`enterDamping` 0.42 < 1）。
    /// 它会真的冲过 1 再回落，观感就是「Q 弹」。透明度不在这里管：
    /// `FloatHost.revealContent` 用 0.12 s 把卡片从 alpha 0 提上来，两件事分开，
    /// 才不会「卡片先亮、画面后到」那种两段式。
    ///
    /// 返回 true 表示真的开了动画（`inFlight` 时排队，由外层收口）。
    @discardableResult
    static func bounce(_ views: [UIView], completion: (() -> Void)? = nil) -> Bool {
        guard depth == 0 else {
            outside { bounce(views, completion: completion) }
            return false
        }
        if !announcedEnter {
            announcedEnter = true
            Log.write(String(format: "win: enter bounce %.2f->1.00 t=%.2f zeta=%.2f",
                             enterScale, enterDuration, enterDamping))
        }
        for view in views {
            view.transform = CGAffineTransform(scaleX: enterScale, y: enterScale)
        }
        UIView.animate(withDuration: enterDuration, delay: 0,
                       usingSpringWithDamping: enterDamping,
                       initialSpringVelocity: enterVelocity,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: {
                           for view in views { view.transform = .identity }
                       },
                       completion: { _ in completion?() })
        return true
    }

    private static var announcedEnter = false

    // MARK: - 升窗（小窗 → 主窗）

    /// 0.1.31 — 升窗**一条曲线**，不再「长完了再弹一下」。
    ///
    /// 0.1.29 是两段：几何先用母本那套过阻尼 spring 长到主窗尺寸（0.27 s），
    /// 落定之后 `bounceAfterLift` 再从 0.74 弹到 1。用户原话：「看着很别扭。
    /// 长大后再弹一下，修复一下。」—— 眼睛读到的是两个动作，不是一次过渡。
    ///
    /// 现在起点就是**小窗此刻的真实尺寸**（`from` = 小窗视觉尺寸 / 目标尺寸），
    /// 终点 1，中间不换手。方向也是对的：卡片一路上涨，只在末尾轻轻过冲一点
    /// 再落定，这就是「长大带着弹性」，不是「长完再补一下」。
    ///
    /// 阻尼没有沿用入场的 0.42：入场是 0.74→1（行程 26 %），过冲 23 % 落在
    /// 1.06；升窗起点约 0.32（行程 68 %），同样 0.42 会冲到 1.16 —— 卡片比目标
    /// 大 16 %，那就不是「弹一下」而是「胀一下」。0.62 的过冲约 8 %，峰值 1.05，
    /// 在屏幕上刚好是一次可见的收尾。
    static let liftDuration: TimeInterval = 0.38
    static let liftDamping: CGFloat = 0.62

    @discardableResult
    static func lift(_ views: [UIView], from scale: CGFloat, center: CGPoint?,
                     completion: (() -> Void)? = nil) -> Bool {
        guard depth == 0 else {
            outside {
                _ = AevonMotion.lift(views, from: scale, center: center, completion: completion)
            }
            return false
        }
        if !announcedLift {
            announcedLift = true
            Log.write(String(format: "win: lift one shot %.2f->1.00 t=%.2f zeta=%.2f",
                             scale, liftDuration, liftDamping))
        }
        let start = Swift.min(1, Swift.max(0.05, scale))
        for view in views {
            view.transform = CGAffineTransform(scaleX: start, y: start)
        }
        UIView.animate(withDuration: liftDuration, delay: 0,
                       usingSpringWithDamping: liftDamping,
                       initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: {
                           for view in views { view.transform = .identity }
                           if let spot = center {
                               for view in views { view.center = spot }
                           }
                       },
                       completion: { _ in completion?() })
        return true
    }

    private static var announcedLift = false
}
