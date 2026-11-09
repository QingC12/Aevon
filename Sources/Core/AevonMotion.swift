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
        transitionDuration = response
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
        if depth == 0 {
            transitionDuration = 0
            drain()
        }
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

    /// 0.2.43 — 这一次过渡有多长。补间（圆角）必须与几何同长。
    ///
    /// 0.1.26 起 `applyCorner` 补的那条 `CABasicAnimation` 用的是 `response`
    /// （母本 0.2727 s）。几何走 `spring` 时两者相等，看不出问题；0.2.43 把键盘
    /// 让位换成固定 0.24 s 的 `fill` 之后，圆角就会比框慢 0.033 s 落地 ——
    /// 一个 60 Hz 屏上是两帧的「角还在动、框已停」。这里记下当前过渡的真时长，
    /// 让补间读同一个数。0 表示不在过渡里（调用方回退到 `response`）。
    private(set) static var transitionDuration: TimeInterval = 0

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
    ///
    /// 0.1.34 — 0.38 s / ζ0.62 被用户判成「太快了，是飞入吗」。
    ///
    /// 这一条与入场弹跳**不是同一个动作**：入场是从 0.74 在**原地**长到 1，
    /// 升窗还要同时把小窗那一点（通常贴着右缘）搬到主窗落点，位移常在两三百 pt。
    /// 缩放 + 长位移叠在同一条 0.38 s 的欠阻尼曲线上，前 0.1 s 就把七成路程
    /// 走完 —— 眼睛读到的不是「长大」，是「一个小方块飞过去然后撑开」。
    ///
    /// 两个数一起改：时长 0.55 s 让位移那一段有地方落脚，阻尼 0.72 把过冲从
    /// 8 % 压到约 4 %（峰值 1.04）。仍然是一次可见的收尾，但不再像撞上去。
    static let liftDuration: TimeInterval = 0.55
    static let liftDamping: CGFloat = 0.72

    /// 0.1.76 — 键盘弹出时卡片张开、收起时缩回的那一段。
    ///
    /// 实测参考（用户提供的同类浮窗录屏，2026-10）：键盘弹出时卡片整体位移
    /// 316 pt —— 正好等于键盘高度 —— 从开始移动到稳定用 **0.36~0.40 s**。
    /// 逐帧位移量是前大后小（1234→1150→1080→1046→1012→965→928→918），
    /// 末尾 2 pt 内收、**没有过冲**，所以是一条 ease-out，不是弹簧。
    ///
    /// 0.1.77 — **0.36 s 按用户实测偏慢**（Aevon(148)：「过渡动画有点慢，看起来
    /// 不流畅」）。参考录屏量的是**别人家**浮窗的总位移时间，它那一段里还包含
    /// 键盘自己的 0.25 s 动画；我们把卡片独立于键盘跑 0.36 s，于是卡片比键盘晚
    /// 0.11 s 落地 —— 眼睛看到的是「键盘已经到位、窗口还在长」的拖尾，这就是
    /// 「不流畅」的来源。改回与系统键盘同速的 **0.24 s**：起手跟键盘同拍，
    /// 落地也同拍，中间不再有多余尾段。曲线仍是 ease-out（实测前大后小、无过冲）。
    static let fillDuration: TimeInterval = 0.24

    /// 0.2.43 — 键盘让位这一段**改回弹簧**，阻尼取过阻尼边界。
    ///
    /// 0.1.76/0.1.77 用的是 `curveEaseOut` 0.24 s，判据是「前大后小、没有过冲」。
    /// 那个判据本身没错，问题出在**它不是一次 `AevonMotion` 过渡**：
    /// `applyCorner` 靠 `AevonMotion.inFlight`（`depth > 0`）判断「正在过渡，圆角
    /// 要补一条同时长的 `CABasicAnimation`」。裸 `UIView.animate` 不抬 `depth`，
    /// 于是卡片 352→430 的那 0.24 s 里框在长大、`cornerRadius` 从 44.8 硬跳到
    /// 54.7 —— 角先变大、框后跟上，用户看到的就是「放大过程中闪一下」。
    ///
    /// 阻尼 1.0 是母本 `1.1` 在 UIKit 侧的收敛值（见文件头）：过阻尼、不回弹。
    /// 这里**不要**为了「弹一下」把阻尼调小 —— 放大的终点是屏幕底边（932），
    /// 过冲那一段落在屏幕外，肉眼拿不到任何弹性，只会让落地晚一拍。
    /// 初速 0.35 只补一件事：过阻尼弹簧起手是零速度，跟键盘同拍时会显得
    /// 「键盘先动、卡片后动」；给一点初速，第一帧就跟上。
    static let fillDamping: CGFloat = 1.0
    static let fillVelocity: CGFloat = 0.35

    /// 0.2.43 — 键盘张开/缩回自己的一条弹簧。
    ///
    /// 与 `spring` 的唯一区别是**时长固定** `fillDuration`：0.1.77 量过，这一段
    /// 必须与系统键盘同速，不能跟着「动画弹性」滑条变。除此之外与 `spring`
    /// 完全一致：抬 `depth`（让 `inFlight` 成立、圆角补间生效）、嵌套并入外层、
    /// 返回后清 `outside` 队列。
    @discardableResult
    static func fill(_ changes: @escaping () -> Void,
                     completion: ((Bool) -> Void)? = nil) -> Bool {
        depth += 1
        if depth > 1 {
            changes()
            depth -= 1
            if depth == 0 { drain() }
            return false
        }
        if !announcedFill {
            announcedFill = true
            Log.write(String(format: "win: kb spring t=%.2f zeta=%.2f v=%.2f",
                             fillDuration, fillDamping, fillVelocity))
        }
        transitionDuration = fillDuration
        UIView.animate(withDuration: fillDuration, delay: 0,
                       usingSpringWithDamping: fillDamping,
                       initialSpringVelocity: fillVelocity,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: changes,
                       completion: completion)
        depth -= 1
        if depth == 0 {
            transitionDuration = 0
            drain()
        }
        return true
    }

    private static var announcedFill = false

    /// 0.1.83 — **收起前先挂起这么久。**
    ///
    /// Aevon(151) 里 `fill off` 与下一条 `fill on` 常常落在同一秒内：App 侧一次
    /// 假收起（同一个键盘窗量到 0）就把卡片缩回小窗，一两拍后又被心跳张开 ——
    /// 用户的原话是「放大时会先向下缩一下，然后再放大」和「键盘自动收起」。
    ///
    /// 0.60 s 的依据是 App 那串心跳：键盘还在时 `com.aevon.kb.up` 每秒一发，
    /// 假收起后面一定紧跟一条「又起来了」。真收起时也只多等 0.60 s —— 那 0.60 s
    /// 里卡片仍是键盘态几何，屏幕上是「键盘已经下去、窗口还贴着底」，不会露黑。
    ///
    /// 0.2.42 — **0.60 → 0.10。** 那 0.60 s 是对同一个事实的**第二次确认**。
    ///
    /// 0.1.84 起 App 侧已经不是「一次判定就报」了：`AevonKbSettleWait` 先等
    /// 0.30 s、再每 0.18 s 量一次三态，要连续两次 `GONE` 才 `settle gone` 并
    /// 下发 `com.aevon.kb.off`；量到 `TOP` 的那一拍走 `settle keep`，一个字都不发。
    /// 也就是说假收起在 App 那一层就被吃掉了，桌面这一侧再压 0.60 s 只是在等
    /// 一个**已经等过的时间**：真收起时整条链是
    ///   键盘动画 0.25 + App 侧确认 ~0.48 + 0.60（这里）+ 0.15（场景落地）
    ///   + 0.24（缩回动画）≈ 1.7 s，
    /// 用户量到的「关了键盘要等一秒左右才还原」就是这一段。
    ///
    /// 留 0.10 s 只为一件事：Darwin 通知不保证顺序，收起的同一拍里可能还有一条
    /// 在途的 `kb.up`。0.10 s 足够吃掉它，再短就等于不留。
    ///
    /// 0.2.59 — **0.10 → 0.35。**「App 侧已经确认过」这个前提在 Aevon(200) 里
    /// 被推翻了。抖音的输入框在屏那 6 秒里，宿主连做了三轮「收起 → 又张开」：
    ///
    ///   keyboard fill on  card=430x717 at 0,215
    ///   keyboard fill off card=352x587 at 43,162   ← 假收起
    ///   keyboard fill on  card=430x717 at 0,215    ← 一拍之后又张开
    ///
    /// 每一轮卡片都在 352x587@43,162 与 430x717@0,215 之间飞一次，而场景跟着
    /// `frame drift` 追一次 —— 那几帧里卡片矩形与场景矩形不同源，用户看到的就是
    /// 「键盘一弹，画面往上跳、中下一条发黑」。
    ///
    /// 0.35 s 比系统键盘的收起动画（0.25 s）长一点点：真收起时卡片是在键盘已经
    /// 落下去之后紧接着缩回的，看起来是一次收；假收起会被紧随其后的 `kb.up`
    /// 在这 0.35 s 里否决掉，一个几何都不写。用 0.35 而不是更长，是因为再长
    /// 用户就会觉得「关了键盘窗口还赖着」（0.1.76 那条教训）。
    static let unfillHold: TimeInterval = 0.35

    /// 0.2.42 — 收起时「先放场景、再动卡片」之间的那一拍。
    ///
    /// `AevonPushSceneFrame` 走 `updateSettings:withTransitionContext:`，写完即返回，
    /// 真正落地要等系统下一帧。0.1.67 量的 0.15 s 是这个落地时间的保守值（60 Hz
    /// 下九帧）。这一段**不能省**：省掉就是 0.1.66 那个「卡片先收、场景后搬」，
    /// 中间那一拍 App 按 215 摆、卡片按 0 装，用户看到的是「关键盘时闪黑一下」。
    /// 它只是从代码里的字面量挪到这里，与 `unfillHold` 放在一起，好让「收起一共
    /// 要多久」只有一处能读。
    static let unfillSettle: TimeInterval = 0.15

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
