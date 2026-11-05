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

    /// 卡片入场/出场时缩到的比例。母本用 SwiftUI 的 `.scale` 过渡，默认锚点
    /// 是中心、默认比例 0（`AnyTransition.scale` 的语义）。0 会让整张卡在
    /// 第一帧「从无到有」，观感上是一次跳变；0.94 才是「弹出来」。
    static let enterScale: CGFloat = 0.94

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
    /// 关闭上会显得拖。0.2 s 的 ease-out 与 0.27 s 的 spring 在肉眼上是同一档。
    static func exit(_ views: [UIView], completion: @escaping () -> Void) {
        for view in views { view.isUserInteractionEnabled = false }
        UIView.animate(withDuration: 0.2, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState],
                       animations: {
                           for view in views {
                               view.alpha = 0
                               view.transform = CGAffineTransform(scaleX: enterScale,
                                                                  y: enterScale)
                           }
                       },
                       completion: { _ in completion() })
    }

    /// 入场（开窗）：从 `enterScale` 弹到 1。透明度由首帧看门狗负责
    /// （`FloatHost.revealContent`），这里只做缩放 —— 两件事分开，才不会出现
    /// 「卡片先亮、画面后到」那种两段式。
    static func enter(_ views: [UIView]) {
        for view in views {
            view.transform = CGAffineTransform(scaleX: enterScale, y: enterScale)
        }
        spring {
            for view in views { view.transform = .identity }
        }
    }
}
