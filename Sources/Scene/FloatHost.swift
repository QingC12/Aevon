import UIKit

/// The floating window shell.
///
/// 0.2.x already proved the two hard parts on this phone: a window built from
/// the main `UIWindowScene`, and a `hitTest` that answers nil for itself so a
/// touch that misses the card falls through to whatever is underneath.
///
/// 0.0.35 moved the gesture surface out of the card, and that part is settled: a
/// hosted scene view is a real UIView that owns its touches and forwards them to
/// the app, so recognizers on the card's own view never fired (Aevon(33)). The
/// band has to be a sibling ring *outside* the picture.
///
/// 0.0.40 is the operator's own map, and 0.0.47 gives the top edge its gestures
/// back so that the map is a perimeter rather than three edges:
///
///    · 四周（含顶部）：拖动 = 移动窗口
///    · 左侧 / 右侧：点一下 = 贴边吸附
///    · 底边中段：上滑 = 关闭
///    · 左下 / 右下角：拖动 = 缩放，长按 = 复位
///
/// 0.0.43 — the corners resize again. 0.0.40 removed the two resize cells on
/// the honest grounds that a resize reachable only through the dead top strip
/// was no resize at all; Aevon(41) answered with the operator's own map: the
/// bottom corners are where resize belongs. A drag on a corner now scales the
/// card around its opposite corner — the shape the master's own caption
/// promises (「边角区域滑动缩放，长按重启」) — and the long press keeps its
/// geometry reset. The card's aspect never changes: the picture is one shape
/// scaled, so a resize is a height choice and the width follows.
///
/// Why the top strip came back. 0.0.35-0.0.39 had four cells up there — 边中's
/// flick-to-close and the two top corners' resize — and 0.0.40 punched the strip
/// out when those cells left. 0.0.47 restores it as plain 拖动: the master's own
/// caption is 「浮窗手势区域为边缘外侧」— a perimeter, all four sides — and
/// Aevon(44)/(45) reporting 「四边手势依旧失效」 three rounds running is what a
/// perimeter with one dead edge looks like from the outside. The strip still
/// answers no tap and no long press, so nothing docks or resets by accident.
///
/// 吸附 changed meaning in this version. It used to be a drag that snapped to an
/// edge and a double tap that minimised. Both are gone. 吸附 is now one tap on a
/// side band: the card becomes a docked 停靠小窗 on that side, and a tap anywhere
/// on the mini's picture brings the full card back. Two taps were always the
/// wrong shape for this — the operator has to aim at a specific band twice, and
/// the way *out* of the mini was a band, not the window it had just become.
///
/// 0.0.54 — 画面里不再有自己的控件。右上角那颗 ✕ 撤了：它压在 App 画面右上角，
/// 和 App 自己的顶栏挤在一起，既挡内容又不好看；关窗仍有底边上滑与十分钟上限。
///
/// 0.0.60 — 那刀裁切撤了。裁切能去掉顶栏，但切掉的东西不会自己回来：App 仍是
/// 按整屏排好的，卡片只是它的一截。改比例是另一条路 —— 承载面按小胖屏的尺寸
/// （5 : 3）重新布局，App 会排一版适合这个窗口的界面，顶栏、底栏都在里面。
/// 这也是母本的做法：她的窗口比例是设置项（`CustomFrameInit` /
/// `RightCornerTrim` / `LeftCornerTrim`），不是屏幕比例。
///
/// 0.0.62 — 交给系统的那块「屏幕」改成**与手机等宽**（高按 5:3），卡片是它的
/// 等比缩小。0.0.61 交的是卡片自己的尺寸（345 宽），任何按屏幕宽度布局的层都会
/// 出界（抖音右侧那一列、视频居中都不对）；等宽之后它们全部落在界内，字号与
/// 圆角也顺带按同一个 scale 收敛。见 `fatRender`。
final class FloatHost: NSObject, UIGestureRecognizerDelegate {
    /// 0.0.98 — 两个槽，轮流当主窗。
    ///
    /// 一个 `static let shared` 就是「整个插件只有一块卡」的另一半：`show` 的第一句
    /// 是 `host.teardown()`，它拆的永远是同一个宿主，所以第二个窗开出来时第一个必然
    /// 被连根拔掉 —— 圆盘再选图标「没反应」，往下挖就是这一行。
    ///
    /// 现在两个槽交替使用：新窗用另一个槽，旧窗原封不动留在自己那一份对象上降级成
    /// 停靠小窗。它的 window、card、承载视图、scene 引用都在原处，**不需要搬家**，
    /// 也就没有「搬家中途画错」这一类错。
    ///
    /// 0.0.99 — 2 → 11。V1 只验骨架，第三个 App 来的时候两个槽都占着，
    /// 于是「先降级、后找槽」变成了「旧主窗被缩小、新窗开不出来」，屏幕上只剩
    /// 两圈停靠小窗和一圈手势光晕 —— Aevon(87) 的原话是「变成不显示悬浮窗只有
    /// 白色光晕」。槽位够用之后这条失败路径根本不会被走到。
    ///
    /// 11 = 1 主 + 10 停靠（用户定档：右侧 5 → 左侧 5）。上限与排列见
    /// `dockHeight` / `dockAsMini`。
    private static var slots: [FloatHost] = []
    private static var mainIndex = 0
    static let slotCap = 11

    /// 0.1.7 — **「上一个主悬浮窗」的几何**，升窗时唯一的落点来源。
    ///
    /// 0.1.5 让升窗去读 `CardLayout.loadRuntime()`（按边记忆：`left` / `right` 两组
    /// 归一化坐标）。那份记忆有两个毛病，合起来就是用户 Aevon(94) 第 2 条
    /// 「还原成主悬浮窗时的位置还是在变，每一个都不一样」：
    ///
    ///   1. **按边记忆**：`remember` 按卡片此刻在屏幕左半还是右半决定写 `left` 还是
    ///      `right`，而 `plan` 读的是 `placement.edge` 那一边 —— 同一张卡被拖到左
    ///      半边之后，下一次升窗就跳到 `left` 那份完全不同的坐标上；
    ///   2. **只在拖动结束时写**：中间任何一次拖动的落点都会把记忆改掉。
    ///
    /// Aevon(94) 的实测就是这个形状：同一串升窗操作里有 23,210（16 次）、
    /// 23,199（2 次）、23,201、65,218 四个不同落点，全部对得上当时最后一次
    /// `card remembered …` 的百分比，而不是「刚才那个主窗在哪」。
    ///
    /// 用户要的是**一个确定的东西**：你刚才那张主卡在哪儿、多大，点小窗升回来就是
    /// 那儿、那么大。所以这里记一帧**实际 frame**（不是百分比、不分边），在「主窗
    /// 被降级」和「新主窗建好」两处各写一次，升窗直接用它。
    static var lastMainFrame: CGRect?

    private static func ensureSlots() {
        if slots.isEmpty { slots = (0..<slotCap).map { _ in FloatHost() } }
    }

    /// 当前主窗的宿主。0.0.97 及以前这是唯一那个宿主，名字留着是为了不改调用点。
    /// 注意：它是**计算属性**，`mainIndex` 一变它就跟着变 —— 拿住它之后不要再
    /// 通过 `shared` 读第二次。
    static var shared: FloatHost {
        ensureSlots()
        return slots[mainIndex]
    }

    /// 全部槽。`AevonFloatTouch` 靠它找手指落在哪一块上。
    static var everySlot: [FloatHost] {
        ensureSlots()
        return slots
    }

    /// 手指该先问谁：**停靠小窗在前，主窗在后**（0.1.5）。
    ///
    /// 0.1.0~0.1.4 是「主窗永远第一个」（为了不让小窗按槽号顺序抢走主窗手势）。
    /// 那条纪律漏了一个情形，用户 Aevon(93) 第 2 条报的就是它：
    ///
    ///   主窗被拖到左右边缘、**压在一张停靠小窗上**时，主窗那侧的手势环
    ///   （`ringHolds`，卡片外 `reach` ≈ 51 pt）正好盖住小窗。主窗先被问、
    ///   先认领 ⇒ 用户点在小窗上的那一下变成了「主窗的环带」，小窗永远拿不到
    ///   那一下，升不回主窗。
    ///
    /// 先问小窗不会有反作用：小窗只在自己那块矩形（含 6 pt 容忍带）里认领，
    /// 落在外面就回 false，主窗照旧拿到它该拿的环带 —— 认领范围是矩形对矩形，
    /// 谁先问谁就赢在重叠区，而重叠区按用户的裁决归小窗。
    ///
    /// 顺序不为空的槽不参与 —— 它们的 `window` 是 nil，`rawTouch` 第一句就会
    /// 早退，排进来只是白跑一遍。
    static var touchOrder: [FloatHost] {
        ensureSlots()
        let main = slots[mainIndex]
        var order: [FloatHost] = []
        // 主窗自己也可能停靠着（`mainIndex` 不随降级更新），所以判据是 `onMini`
        // 而不是「不等于 mainIndex」：真正的大卡片永远排在最后一个。
        for slot in slots where slot.window != nil && slot.onMini {
            order.append(slot)
        }
        if main.window != nil && !main.onMini {
            order.append(main)
        }
        for slot in slots where slot.window != nil && !slot.onMini && slot !== main {
            order.append(slot)
        }
        return order
    }

    /// 当前主窗里演的 App；没有主窗时是空串。
    ///
    /// 0.0.98 — `cardUp` 原来是「有没有卡」唯一答案，多窗之后它变成「屏幕上还有
    /// 没有至少一块卡」，于是「新卡起没起来」这件事必须换一个判据。这个名字就是
    /// 那个判据：它同时要求「主窗槽有位」和「里面放的是谁」。
    static var mainBundle: String {
        ensureSlots()
        let host = slots[mainIndex]
        // 0.0.99 — 停靠中的那个不算主窗。多窗之后「主窗」= 这个槽里有一张**大**
        // 卡片；一个被降级成停靠小窗的宿主仍然有 window，但它已经让位了。
        guard host.window != nil, host.miniFrame == nil else { return "" }
        return host.bundle
    }

    /// 0.1.6 — 屏幕上还有没有任何一块卡（大卡或停靠小窗都算）。
    ///
    /// 圆盘的右缘带（`RingHost.edgePad`）要和「卡片在屏」这件事对齐：卡片贴右缘
    /// 时，拖卡片底角的手会先落进那 15 pt 带宽里。0.0.55 起它读的是
    /// `AevonRingGrip.cardUp` —— 一个只在 `openCard` / `closeCard` 写两笔的静态
    /// 布尔值。关主窗而留下停靠小窗时，`closeCard` 无条件把它写成 false（见
    /// SceneProbe 那一行），于是**小窗还在屏上、右缘带却重新开了**，带宽压在小窗
    /// 上，点小窗那一下就变成呼圆盘 —— 用户报的「点了没反应 / 透传」里有一份是它。
    ///
    /// 这里按槽现算，不存状态：任何时候问都等于此刻的事实。
    static var anyCardUp: Bool {
        ensureSlots()
        return slots.contains { $0.window != nil }
    }

    /// 新主窗该住哪个槽：当前槽空着就给它，否则找另一个空槽；两个都满返回 nil。
    ///
    /// 返回 nil 是 V1 唯一的「拒绝服务」出口（屏幕上已经有一主一停两窗）。日志会说
    /// 清楚是这一条拒的，而不是像 0.0.97 之前那样静悄悄 return。
    static func takeMainSlot() -> FloatHost? {
        ensureSlots()
        let current = slots[mainIndex]
        if current.window == nil { return current }
        for (index, slot) in slots.enumerated() where slot.window == nil {
            mainIndex = index
            return slot
        }
        return nil
    }

    /// 0.0.99 — 「先问有没有槽，再决定降不降级」。
    ///
    /// 0.0.98 的顺序是反的：`openCard` 先 `demoteMain()` 把主窗缩成小窗，然后
    /// `show` 才发现没槽。两个槽都占着时，这一下把旧主窗缩小了、新窗开不出来，
    /// 屏幕上只剩两圈停靠小窗和一圈手势光晕（Aevon(87)）。判据要在动手之前问。
    static func hasFreeSlot() -> Bool {
        ensureSlots()
        return slots.contains { $0.window == nil }
    }

    // MARK: - 0.0.99 停靠排列

    /// 停靠小窗的排列顺序：右列 0~4 从上往下，左列 0~4 从上往下。
    ///
    /// 用户定档「右侧吸附 5 个之后从左边顶部继续排」。分两列存而不是一张总表，
    /// 是因为**手工点边停靠**要落在被点的那一侧（两侧红区都是「点击停靠」），
    /// 而**自动降级**才按「右侧先满」排队。一张总表做不到这两件事同时成立。
    private static var dockRight: [FloatHost] = []
    private static var dockLeft: [FloatHost] = []
    private static let columnCap = 5

    private static func columnIndex(_ host: FloatHost) -> (right: Bool, row: Int)? {
        if let i = dockRight.firstIndex(where: { $0 === host }) { return (true, i) }
        if let i = dockLeft.firstIndex(where: { $0 === host }) { return (false, i) }
        return nil
    }

    private static func slotIndex(of host: FloatHost) -> Int? {
        ensureSlots()
        return slots.firstIndex(where: { $0 === host })
    }

    /// 一个停靠小窗该占第几格。`preferLeft` 表示「手指点的是左边」。
    @discardableResult
    private static func claimDock(_ host: FloatHost, preferLeft: Bool) -> Bool {
        if columnIndex(host) != nil { return preferLeft }
        // 优先落被点的那一侧；那一列满了再换列。两列都满就挤掉右列最上面那个
        // （它是最早停靠的），这是 V1 的兜底，V2 会换成「只换主窗内容」。
        if preferLeft {
            if dockLeft.count < columnCap { dockLeft.append(host); return true }
            if dockRight.count < columnCap { dockRight.append(host); return false }
            dockRight.removeFirst()
            dockRight.append(host)
            return false
        }
        if dockRight.count < columnCap { dockRight.append(host); return false }
        if dockLeft.count < columnCap { dockLeft.append(host); return true }
        dockLeft.removeFirst()
        dockLeft.append(host)
        return true
    }

    private static func releaseDock(_ host: FloatHost) {
        dockRight.removeAll { $0 === host }
        dockLeft.removeAll { $0 === host }
    }

    /// 停靠小窗的尺寸：**固定**，不随数量变（Aevon(88) 第 1 条）。
    ///
    /// 0.0.99 是按数量分档（280 / 220 / 186），结果是「多开一个，所有小窗一起
    /// 变小」—— 用户的原话是「吸附的小窗应该是固定大小，而不是随着数量增加而
    /// 变小」。而且那一档还带了个真 bug：跨档时先来的几个没有重排，日志里
    /// `nth=2 at 0,280`（高 280，占 280~560）与 `nth=3 at 0,440`（高 220）压了
    /// 120 pt，两个小窗叠在一起。固定尺寸把这两件事一起解决。
    ///
    /// 0.1.0 把它固定成 `0.20 × 屏高`（932 → 186），0.1.1 又改了：加了上下留白
    /// 与窗间缝之后，186 一定装不下五个（5×186 + 4×6 + 93 = 1047 > 932），
    /// 所以尺寸改成**反推**的，见下面的 `DockMetrics`。

    /// 一列 5 个的几何：上下留安全区、窗与窗之间留缝（Aevon(89) 第 3 条）。
    ///
    /// 0.1.0 的 `y = row * height` 把第 1 个放在 `y=0`：那是**屏幕顶端**，刘海
    /// 机的状态栏正好压在它上面（27 pt 时间 / 59 pt 灵动岛）。最后一格
    /// `y = 4 × 186 = 744`，底边 930，home 条也压着它。用户的原话是「顶部已经
    /// 贴到屏幕顶部，被状态栏遮挡」，要的是上下都留出区域、窗与窗之间也要有缝。
    ///
    /// 于是尺寸不再是 `0.20 × 屏高` 这个拍出来的比例，而是**反推**的：
    ///
    ///     可用高 = 屏高 − 上留 − 下留
    ///     窗高   = (可用高 − 4 × 缝) / 5
    ///
    /// 三处留白都按屏高比例算，换机型仍然「一列正好装五个」。932 pt 上落成：
    /// 上留 61、下留 32、缝 6、窗高 163、宽 98。
    ///
    /// 为什么不再用 `dockHeightFraction`：那个比例是「拍出来的尺寸」，一旦加上
    /// 留白就一定装不下五个（5 × 186 + 4 × 6 + 93 = 1047 > 932）。反推则永远
    /// 装得下，代价是小窗小一圈 —— 用户已经明确同意这个取舍。
    private struct DockMetrics {
        var top: CGFloat
        var gap: CGFloat
        var height: CGFloat
        var width: CGFloat
    }

    private static func dockMetrics(in bounds: CGRect) -> DockMetrics {
        let h = bounds.height
        // 上留 6.5 % ≈ 61 pt（状态栏 59 + 2 呼吸），下留 3.4 % ≈ 32 pt（home 条
        // 34，但不能吃满，否则最后一格贴边）。比例在矮屏上也要有下限。
        let top = Swift.max(44, (h * 0.065).rounded())
        let bottom = Swift.max(24, (h * 0.034).rounded())
        let gap = Swift.max(4, (h * 0.0065).rounded())
        let usable = h - top - bottom
        let slots = CGFloat(columnCap)
        let raw = (usable - gap * (slots - 1)) / slots
        // 下限 90：再小就认不出是谁。也是「装不下五个」的兜底 —— 真到这一步
        // 宁可窗小，也不再往屏幕外挤。
        let height = Swift.max(90, raw.rounded(.down))
        return DockMetrics(top: top, gap: gap, height: height,
                           width: height / fatAspect)
    }

    /// 重新摆所有停靠小窗。每次停靠 / 取消 / 拆窗之后都调一次 ——
    /// 尺寸固定之后它不再是「跨档才跑」，而是「位置永远等于 行号 × 行高」。
    /// - Parameter animated: 升窗补位时传 true，让其余小窗**滑**上去一格。
    ///
    ///   0.1.10 — 用户 Aevon(97) 第 2 条：「点击了小窗 1 回到主悬浮窗时，234 变成
    ///   123 时，只有内容在变，而没有出现卡片的上移动作动画」。
    ///
    ///   根因就是这里：`placeDock` 里 `card.frame = ...` 是硬赋值，UIKit 没有
    ///   任何一帧过渡。而小窗的框几乎不可见（只有画面），所以肉眼看到的是
    ///   「内容跳了一格、卡片没动」。加动画之后框和画面一起走。
    static func relayoutDocked(animated: Bool = false) {
        ensureSlots()
        guard dockRight.isEmpty == false || dockLeft.isEmpty == false else { return }
        let probe = dockRight.first ?? dockLeft.first
        let bounds = probe?.window?.bounds ?? UIScreen.main.bounds
        let metrics = dockMetrics(in: bounds)
        for (row, host) in dockRight.enumerated() {
            host.placeDock(right: true, row: row, metrics: metrics, animated: animated)
        }
        for (row, host) in dockLeft.enumerated() {
            host.placeDock(right: false, row: row, metrics: metrics, animated: animated)
        }
    }

    /// 把这一格摆到指定列的第 `row` 行。只改几何，不碰内容。
    private func placeDock(right: Bool, row: Int, metrics: DockMetrics, animated: Bool = false) {
        guard let card = card, let window = window else { return }
        let width = metrics.width
        let height = metrics.height
        let x = right ? window.bounds.width - width : 0
        // 行号 × (窗高 + 缝)，起点再让出上留 —— 这两项缺一个就会要么贴顶、
        // 要么窗与窗紧挨。
        let y = metrics.top + CGFloat(row) * (height + metrics.gap)
        let target = CGRect(x: x, y: y, width: width, height: height)
        // 0.1.26 — 尺寸也进动画。
        //
        // 0.1.10 只在「尺寸不变、只换行」时动画，理由是「框缩完、画面还在旧尺寸」
        // 会出现中间帧。那个中间帧的真实成因是**只**animate了 frame：`content` 的
        // `transform` / `center` 是同一个动画块之外写的，于是各走各的。
        //
        // 现在两者在同一个块里：卡片走 `bounds` + `center`，画面走 `followContent`。
        // 中间帧为什么是准的：`fitScale` 对 5:3 的画布是 `卡宽 / 画布宽` 的线性
        // 函数，线性函数与插值可交换 —— `lerp(scale(A), scale(B), t)` 恰好等于
        // `scale(lerp(A, B, t))`。所以每一帧画面都正好填满框，不会露边。
        let moving = animated && card.frame != target
        if moving {
            AevonMotion.spring {
                card.bounds = CGRect(origin: .zero, size: target.size)
                card.center = CGPoint(x: target.midX, y: target.midY)
                self.followContent()
                self.syncGrip()
            }
        } else {
            card.frame = target
            followContent()
        }
        // `miniFrame` **不动**：它记的是「取消停靠要回到的那个大卡片」，不是
        // 「小窗现在在哪」。在这里覆盖它，取消停靠就会回到一个小窗尺寸。
        installShield()
        // 0.1.7 — **停靠小窗里那块画面不再接触摸。**
        //
        // 用户第四次报「点小窗依旧会触发应用内的操作」。Aevon(94) 的证据把范围压到
        // 了一处：`win: mini touch down=N eaten=N near=0` —— 我们在 `sendEvent` 里
        // 每一下都吞了，App 却还是动了。也就是说这条触摸**同时**被送到了承载的
        // App（remote scene 的画面在窗口服务器眼里是独立的一块），我们吞掉的只是
        // SpringBoard 这一份。
        //
        // 所以从承载面本身下手：小窗的定义就是「不可操作」（母本 `SingleTapMinimize`），
        // 整块画面不参与命中，触摸只会落到我们这张卡和它上面的 shield 上。升回主窗
        // 时在 `performUndock` 里恢复。
        content?.isUserInteractionEnabled = false
        Log.write("win: mini touch lock content=0")
        // 0.1.8 — 告诉 App 进程「你被停靠了」（Aevon(95) 第 1 条）。
        //
        // 0.1.7 的 `isUserInteractionEnabled = false` 也没用：用户的原话是「快速点击
        // 时依旧会触发小窗应用内点击，尤其是抬手时才触发」。抬手才响 = App 收到的是
        // 一份**完整**的点按（began…ended），它自己按 UIKit 的规矩在 ended 那一拍
        // 派发。那份投递不经过我们的承载视图，也不经过 SpringBoard 的 `sendEvent:`。
        //
        // 所以标记要落到 App 自己的容器里，由 App 侧的 `-[UIApplication sendEvent:]`
        // 读（见 `AevonAppHook.m` 的 `AevonAppSendEvent`）。
        setMiniFlag(true)
        // 0.1.0 — 停靠小窗没有手势环。`syncGrip` 会按新尺寸重算环，摆完必须把
        // 它收起：环是「可操作」的意思，而小窗的定义就是不可操作。
        if !moving { syncGrip() }
        grip?.isHidden = true
        // 遮罩必须盖在画面之上、且吃掉整张卡片 —— 用户要的是「点小窗任何位置都
        // 还原成主窗，且不要透传到 App 里」。
        if let shield = shield { card.bringSubviewToFront(shield) }
    }

    /// 0.1.8 — 停靠标记的本地缓存。文件只在**状态变化**时写一次：`placeDock`
    /// 每次重排都会跑（停靠、取消停靠、拆窗都会触发 `relayoutDocked`），每一格
    /// 都写一次文件既慢，也会把日志糊成一片。
    private var miniFlagged = false

    /// 0.1.8 — 把「我被停靠成小窗」这件事告诉 App 进程（见 `AevonAppMiniFlagSet`）。
    ///
    /// 0.1.9 — 通道从「只有文件」变成「通知 + 文件」，返回值也变成位掩码：
    /// 0 = 两条都没成，1 = 只有通知，2 = 通知 + 文件，3 = 只有文件。日志必须分得清，
    /// 否则「用户说还是透传」和「闸门根本没装上」在日志上长得一模一样。
    private func setMiniFlag(_ mini: Bool) {
        guard miniFlagged != mini else { return }
        miniFlagged = mini
        let mask = Int(AevonAppMiniFlagSet(bundle, mini))
        // 文案必须长过 16 字节：15 字节以内的字符串字面量在 -Osize 下会被编成
        // 一条 mov 立即数，二进制里根本搜不到（` mem=%.0f%%` 就是这么 MISS 的）。
        let how: String
        switch mask {
        case 0: how = " no channel at all"
        case 1: how = " notify only, no file"
        case 2: how = " notify and file"
        case 3: how = " file only, no notify"
        default: how = " unknown channel mask"
        }
        Log.write((mini ? "win: mini flag armed " : "win: mini flag cleared ")
                  + (bundle.isEmpty ? "-" : bundle)
                  + how)
        if mini {
            FloatHost.startMiniBeat()
        } else {
            FloatHost.stopMiniBeatIfIdle()
        }
    }

    /// 0.1.9 — 停靠标记的**心跳**。App 侧把 on 当成 2.5 s 的租约，这里每秒续一次。
    ///
    /// 为什么需要心跳而不是只发一次：off 那条通知如果在通道上丢了，或者桌面进程
    /// 直接崩了，App 侧会永久认为「我是小窗」—— 用户看到的是那个 App 再也点不动。
    /// 有租约就没有这个死态：最多僵 2.5 秒，自己恢复。
    private static var miniBeat: Timer?

    private static func startMiniBeat() {
        guard miniBeat == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            FloatHost.ensureSlots()
            var live = 0
            for host in FloatHost.slots where host.miniFlagged {
                live += 1
                AevonAppMiniNotify(host.bundle, true)
            }
            if live == 0 { FloatHost.stopMiniBeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        miniBeat = timer
    }

    private static func stopMiniBeatIfIdle() {
        ensureSlots()
        if slots.contains(where: { $0.miniFlagged }) { return }
        stopMiniBeat()
    }

    private static func stopMiniBeat() {
        miniBeat?.invalidate()
        miniBeat = nil
    }

    /// 把当前主窗缩成停靠小窗。主窗位置**不动**：`mainIndex` 不在这里换，
    /// 换槽发生在 `takeMainSlot()` 找到另一个空槽的那一刻 —— 两件事分开做，
    /// 是因为「降级」本身不应该让任何指针失效。
    ///
    /// `except` 是 0.1.1 加的：`undock`（点小窗还原）要先让旧主窗让位，但那个
    /// 时候 `mainIndex` 可能还指着刚升上来的这一张 —— 不排除它，就会「刚点开就
    /// 被自己缩回去」。
    ///
    /// 0.1.3 — 找的是「真正的那张主窗」，不是 `slots[mainIndex]` 这一个格子。
    ///
    /// 0.1.1 只看 `slots[mainIndex]`，而 `dockAsMini` **从来不换 `mainIndex`**
    /// （按上面的注释，换槽是 `takeMainSlot()` 的事）。于是主窗降级成小窗之后，
    /// `mainIndex` 一直指着那个已经变小的槽：下一次点别的停靠小窗来还原，
    /// `demoteMain` 一看 `miniFrame != nil` 就回 `already`，**一张卡都没降级** ——
    /// 屏幕上两张一样大的卡片摞在一起，用户看到的是「点了一下，什么都没发生」。
    /// Aevon(91) 的 `replaced=already` / `replaced=self` 就是这条，一共出现 8 次。
    ///
    /// 现在两步：先看 `mainIndex` 那一格是不是真的主窗，不是就全槽扫一遍。
    /// `into` 是「降级之后落哪一列」（true = 左），`nil` 表示按队列规则自己算。
    @discardableResult
    static func demoteMain(except: FloatHost? = nil, into column: Bool? = nil) -> String {
        ensureSlots()
        let head = slots[mainIndex]
        let fromHead: FloatHost? =
            (head !== except && head.window != nil && head.card != nil
             && head.miniFrame == nil) ? head : nil
        let pick = fromHead ?? slots.first {
            $0 !== except && $0.window != nil && $0.card != nil && $0.miniFrame == nil
        }
        guard let host = pick else { return "none" }
        return host.dockAsMini(into: column)
    }

    /// Which part of the ring a touch landed on.
    private enum Zone {
        case left
        case right
        case top
        case bottomMiddle
        /// 0.0.69 — 底角拆成两个。
        ///
        /// 母本的语言包把左右两角当成两件事：`LeftCornerTrim`「左角::滑动进一步
        /// 调整比例, 长按反向调整」、`RightCornerTrim`「右角::点击切换基础窗口
        /// 比例」，而 `GestureIntroduction` 里「长按」只出现在「边中区域…长按切换
        /// 横竖」这一句上。Aevon(59) 的要求与这条一致：**长按重启只留在右下角，
        /// 左下角这一格空出来给横屏手势**。合并成一个 `bottomCorner` 时这两件事
        /// 无法分开 —— 一个格子只能有一个长按。
        case bottomLeft
        case bottomRight
        /// 0.1.0 — 底排从三格改成五格，角两侧各补一格（Aevon(88) 第 2 条）。
        ///
        /// 0.0.99 的底排只有三格：角 / 中 / 角，而「恢复默认尺寸」这个长按被绑在
        /// 右下角上 —— 同一个格子里既有一个「一碰就缩放」的拖动，又有一个「按住
        /// 0.25 秒」的长按，拖动永远先赢。用户的原话是「底部右侧的长按恢复默认
        /// 尺寸不易触发，反而是底部两侧的缩放手势很灵敏」，说的就是这一件事。
        ///
        /// 拆开之后：角只做缩放，侧格只做长按。两个动作各占一个格子，判据只有
        /// 一条（手指落在哪个格里），不需要用时间/距离去猜意图。
        ///
        /// `bottomLeftSide` 是给 V4 的「长按切横屏」留的位 —— 本版只落格子和日志，
        /// 切换动作还没实现，因为要动 `FBScene.settings.interfaceOrientation`。
        case bottomLeftSide
        case bottomRightSide

        var isCorner: Bool { self == .bottomLeft || self == .bottomRight }

        /// 底排两侧那两格（不是角）。它们不移动、不缩放、不停靠，只有长按。
        var isBottomSide: Bool { self == .bottomLeftSide || self == .bottomRightSide }
    }

    private var window: FloatWindow?
    /// 0.0.47 — 手势面自己的窗口，层级 statusBar+1。见 `makeBand()`。
    private var bandWindow: BandWindow?
    /// 手势环相对卡片的四边内嵌量。卡片贴到某一边时，那一边的环就被屏幕截短，
    /// 所以它是算出来的，不是常数 `reach`。
    private var bandInset: CGPoint = .zero
    private var card: UIView?
    private var content: UIView?
    private var grip: GripView?
    /// The transparent shield a docked card puts over its own picture. It exists
    /// for one reason: while the card is mini, a tap on the picture has to mean
    /// "give me the window back" instead of reaching the app.
    private var shield: UIControl?
    private var onClose: ((String) -> Void)?
    /// 0.0.98 — 这张卡里演的是谁。
    ///
    /// C 侧的画布目标与保活名单都按 bundle 分槽，所以宿主必须记住自己那一格是
    /// 谁的。0.0.82 撤掉这个参数时它用来选画布比例（那件事已经统一成 5:3），
    /// 现在它只是一个键 —— 但仍然必须存在，否则写画布时不知道该写哪一格。
    private(set) var bundle = ""
    /// The scene's own size. Every resize is this shape, scaled — the card never
    /// gets an aspect the picture does not have.
    ///
    /// 0.0.62 — `natural` 是**交给系统的那块屏幕**（`fatRender` 算的：与手机等宽，
    /// 高按 5:3），不是卡片尺寸、也不是真机屏幕。承载面的 `bounds` 与 scene 的
    /// `settings.frame` 都是它，所以 App 按这个尺寸排版；卡片是它的等比缩小
    /// （scale 约 0.80）。拖大拖小走 transform，`natural` 不变 ——
    /// 窗口在手上被拉扯的时候不该让 App 每一帧重排一次。
    ///
    /// `visible` 与它相等（不再裁顶栏），留成两个名字是因为 `followContent` /
    /// `recenterCard` 都读 `visible`：语义上一个是「坐标空间」，一个是「看得见的
    /// 那一块」，0.0.60 之后两者重合。
    private var natural: CGSize = .zero
    private var visible: CGSize = .zero

    /// 0.0.65 — 设备屏幕圆角，开窗时读一次。`applyCorner` 每一帧都要用，而
    /// `_displayCornerRadius` 是一次 KVC。
    private var screenCorner: CGFloat = 0
    /// 0.0.54 的顶栏裁切量。0.0.60 起恒为 0（改比例而不是裁画面），保留这个量
    /// 是因为两条对齐路径都按它算中心，0 就是「不用对齐」。
    private var cropTop: CGFloat = 0

    /// 0.0.58 — 卡片是不是在等第一帧。
    ///
    /// 母本 `ReflectManager` 里有 `_launching` / `_showCover` / `_covered` /
    /// `_cover` 四个字段，但整张表里没有任何快照或图像缓存字段 —— 她的 cover
    /// 不是截图。0.0.57 按这四条做了一版「图标 + 名字」的封面，被否了：那不是
    /// 画面，只是另一张图。这一版改成不画任何东西，等真画面自己到。
    private var awaitingFrame = false
    private var frameAt: CFTimeInterval = 0
    /// 0.0.73 — `reapplyPlacement` 写过几行日志。抹一次写一行，稳定之后闭嘴。
    private var placementLogs = 0

    private var pan: UIPanGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    private var zone: Zone = .left
    private var panStep: CGPoint = .zero
    /// 0.0.99 — 长按闸门。
    ///
    /// 用户定档的五格（对照他发的那张图）：**两侧轻滑什么都不做，只有按住
    /// 0.25 秒之后拖才移动**；底部中间轻滑是移动，按住 0.25 秒之后上滑才是关闭。
    /// 这两条都要一个「这次触摸里长按有没有成立」的读数，就是 `gateAt`。
    ///
    /// 为什么记时刻而不是布尔：两条输入路径里，长按都可能比 `dragBegin` **晚**
    /// 成立（手指先落、停 0.25 秒、再移动 → 长按先到、pan 后到，`dragBegin` 是
    /// pan 的到来）。布尔会在 `dragBegin` 那一拍被抹掉；时刻不会，它只由触摸
    /// 结束清（`gateReset`），所以「按住再拖」这一整段都看得到闸门。
    private var gateAt: CFTimeInterval = 0
    private var gateOpen: Bool { gateAt > 0 && CACurrentMediaTime() - gateAt < 3.0 }

    private func gateOpenNow(_ on: Bool) {
        gateAt = on ? CACurrentMediaTime() : 0
    }

    private func gateReset() { gateAt = 0 }
    /// 0.0.43 — the frame a corner resize started from, and which corner the
    /// finger is on. The opposite corner is the anchor that never moves.
    private var resizeStart: CGRect?
    private var resizeFromLeft = false
    /// The frame to come back to. Non-nil is the only definition of "docked".
    private var miniFrame: CGRect?
    /// 0.0.47 — how many hitTest questions the band window has answered (and
    /// written down). Bounded, like every other probe here: SpringBoard's log is
    /// not the place for a stream.
    private var ringProbe = 0

    // 0.0.48 — 应用层原始触摸的状态（见 `rawTouch`）。识别器那条路有自己的
    // 状态机（UIKit 的），这条路必须有自己的一份：谁在跑由「事件有没有被吞掉」
    // 决定，而一次触摸只可能走其中一条。
    private var rawActive = false
    private var rawStart = CGPoint.zero
    private var rawLast = CGPoint.zero
    private var rawMoved = false
    private var rawStamp: TimeInterval = 0
    private var rawVelocity = CGPoint.zero
    private var rawProbe = 0
    /// 卡片开着时，前 12 个到达应用层的触摸都写一行（不管落在哪里）。它回答的
    /// 是「卡片外面到底有没有触摸进到 SpringBoard」—— 0.0.44-0.0.47 四轮里唯一
    /// 始终分不开的问题。
    private var rawSeen = 0
    /// 0.1.5 — 顶部环带上被忽略的按下数（前 8 条写日志）。顶部从 0.1.5 起不是
    /// 把手，这一行是「用户还在往那里戳」的唯一证据（见 `rawTouch` case 0）。
    private var rawTopIgnored = 0
    private var rawPress: DispatchWorkItem?

    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 480
    /// 0.0.48 — 原来这里是 `edge = 2`，卡片那圈白描边。描边撤了（见 `show`），
    /// 常量一起撤，免得留一个没人读的 2。
    private let margin: CGFloat = 8
    /// 0.0.60 — 小胖屏的宽高比（高 : 宽），5 : 3。
    ///
    /// 母本没有「裁掉顶栏」这种东西。她的三个设置项在二进制里连成一串：
    /// `CustomFrameInit`（修改窗口比例）、`RightCornerTrim`（**点击切换基础窗口
    /// 比例**）、`LeftCornerTrim`（**滑动进一步调整比例, 长按反向调整**），
    /// 另一个 `HeightFraction`（高度系数）单独管大小。也就是说：她的窗口
    /// 比例是一个可以选的量，不是屏幕的比例。
    ///
    /// 内容之所以完整，是因为 `setResizesHostedContext:` —— 承载面按**窗口自己
    /// 的尺寸**重新布局，App 会排一版适合这个窗口的界面。0.0.54 那刀（按原比
    /// 例布局、再把高度减掉顶栏）是「从整屏画面里切一截」，切掉的东西不会自己
    /// 回来；换比例是「让 App 重新画一张」，顶栏、底栏、抖音右侧那一列都在新布
    /// 局里。
    ///
    /// 12 : 7 是另一个候选（略瘦一点，高 12 宽 7）。改这一行即可。
    static let fatAspect: CGFloat = 5.0 / 3.0

    /// 0.0.62 — 交给系统的「这块屏幕有多大」。
    ///
    /// 0.0.60/0.0.61 交的是**卡片本身**的尺寸（345×574）。比例对了，但宽度只有
    /// 屏幕的 80 %，于是任何按屏幕宽度布局的层都会出界：Aevon(53) 里抖音的右侧
    /// 点赞/评论那一列按 430 贴在右缘，落在 345 之外，整块看不见；视频在 430×932
    /// 里居中，被 345×574 的上半截裁掉。
    ///
    /// 母本交给系统的从来不是「小卡片」，是**一个比例的屏幕**：她调的是窗口比例，
    /// 比例一变 App 就重排一版，而屏幕宽度这个量她从没动过。
    ///
    /// 所以这里给的是「和这台手机一样宽、但矮成 5:3」的一块屏幕：
    ///   宽 = 屏宽，高 = 屏宽 × 高宽比（5:3 ⇒ 416 pt 屏给 430×716）。
    /// 好处一次解决三件事：
    ///   ① 按屏幕宽度布局的东西（抖音工具栏、各种贴边浮层）全部落在界内；
    ///   ② 卡片是从它缩出来的（428 → 345，scale 0.80），字号跟着缩 20 % ——
    ///      「悬浮窗内字体有点大」不用另加一套缩放，它就是同一个缩放；
    ///   ③ 圆角按同一个 scale 缩（55 → 44），「太圆」也是同一件事。
    /// 比例由宽高共同决定，所以它仍然是 5:3，不是把整屏压扁。
    /// 0.0.65 — 形状固定 5:3，不再有「记住的形状」。
    ///
    /// 0.0.63/0.0.64 让角拖动改窗口比例（母本 `LeftCornerTrim` 那条路），代价是
    /// 画布尺寸变成一个需要持久化的变量。Aevon(57) 的判决是这条路没有价值：
    /// 「几何缩放没有任何用处」。于是它连同 `CanvasHeight` 一起撤掉 —— 少一个
    /// 状态，就少一整类「读回来和上次不一样」的错位。
    static func fatRender(in screen: CGSize) -> CGSize {
        guard screen.width > 100, screen.height > 200 else {
            return CGSize(width: 430, height: 717)
        }
        // 0.0.82 — 画布只有一个来源，就是这一行。0.0.79 在这里加过一个 `full`
        // 分支（整屏画布），0.0.82 撤掉了，原因写在 `AevonAppHook.m` 里那段注释：
        // 记号是持久的，一次判定变成永久政策，最后的表现是「卡片 5:3、画面 9:19.5、
        // 两边各 42 pt 黑边」。用户拍板：主页面按 5:3 真重排优先。
        // 高宽比 = 高 / 宽。5:3 的高度是宽度的 1.667 倍。
        let w = screen.width
        var h = w * fatAspect
        // 矮屏兜底：scene 的 frame 不该高过屏幕。
        h = Swift.min(h, screen.height)
        h = Swift.max(h, 240)
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// 0.0.81 — 画布装进卡片的那个比例。
    ///
    /// 0.0.60~0.0.80 只有一个比例：卡片是画布的等比缩小，两者形状永远相同。于是
    /// 「卡片形状」这件事一直是被画布决定的 —— 哔哩哔哩竖版那一页按整屏 932 排，
    /// 卡片就跟着变成 282×610（9:19.5）。Aevon(72) 的判决是：**卡片的形状不该由
    /// 某个 App 的页面决定**。
    ///
    /// 所以从 0.0.81 起分成两件事：
    ///   · 卡片形状 = 5:3，和别的 App 一样（`plan` 只按 `fatAspect` 算）；
    ///   · 画布怎么装进这张卡 = 等比、取小的那一边、居中（这个函数）。
    ///
    /// 0.0.82 起画布也恒为 5:3（整屏画布那条路撤了），两者形状永远相同，这个函数
    /// 于是回到恒等变换（比例 0.851，`shown` 与 `fill` 相等）。留着它是因为它是
    /// 「画布和卡片不是同一个形状」这一件事的**唯一**落点：哪一天真的又需要装
    /// 一块不一样的画布，装法已经在这里，不需要再发明一次。
    static func fitScale(for source: CGSize, in card: CGSize) -> CGFloat {
        guard source.width > 16, source.height > 16,
              card.width > 16, card.height > 16 else { return 1 }
        return Swift.min(card.width / source.width, card.height / source.height)
    }

    /// 0.0.49 — 卡片下面那层柔光。跟着 card 的 frame 与圆角走。
    private var glow: UIView?
    /// 0.0.45 — 吸附 (docked) size, from the master's 「贴边缩小」.
    ///
    /// The master docks flush against the edge and keeps the picture's aspect;
    /// how small it goes is its 高度系数 taken down to a handle. Three tenths
    /// of the screen height is 280 pt tall and 129 wide here — big enough to
    /// read the app, small enough to be out of the way, and the same shape as
    /// the card it came from.
    private let miniHeightFraction: CGFloat = 0.30
    /// The height the docked card has on this screen, and the floor a corner
    /// resize may not go under — one function so "smallest" means one thing.
    private func miniHeight(in bounds: CGRect) -> CGFloat {
        return bounds.height * miniHeightFraction
    }
    /// `GestureBorderWidth` in her settings, described there as 减小浮窗手势宽度.
    /// The master's own edge band is 30 pt (`_edgeWidth`, legible in the same
    /// constant annotation that gave the height fractions); the *floating
    /// window* band is the one its caption calls 边缘外侧 and it is wider.
    ///
    /// 0.0.35 shipped 40. 0.0.40 cut it to 32, and Aevon(39) answered with
    /// 「移除热区可见性后，四周的手势失效」. 0.0.42 painted the band, gestures
    /// came back, 0.0.44 unpainted it and they died again — and Aevon(43)'s
    /// log finally says why, which is neither visibility nor the app bridge:
    ///
    ///   0.0.43 (working):  card 320x694 at 52,106  → band reached (418, 846)
    ///   0.0.44 (broken):   card 265x575 at 76,207   → band reached (387, 828)
    ///
    /// The band is measured from the card's edge, so a card that shrinks takes
    /// its own hit area with it: the same thumb, the same place on the screen,
    /// now lands 30 pt past the ring and touches the desktop. The painted map
    /// only ever *reported* where the ring was; the defect was the ring's size.
    ///
    /// 60 pt + 6 of slack it is. That is a band a thumb finds without being
    /// told, and it survives the card being resized smaller by the operator.
    ///
    /// 0.1.0 — **环的厚度改成跟着卡片宽度走**（Aevon(88) 第 2 条）。
    ///
    /// 常数 60 是一条只在「卡片接近满屏」时成立的近似：373 宽的卡片它占 16 %，
    /// 一旦缩到 275 就占 22 %，而底部那一格里还挤着两个角和三块格。用户的原话
    /// 是「手势热区长度应该随着悬浮窗大小而变化」—— 环是卡片的一部分，卡片小
    /// 了环就该窄。
    ///
    /// 15.5 % 这个比例是从「373 宽 → 57.8」反推的：它让默认尺寸下的手感与
    /// 0.0.99 的 60 pt 几乎一样（差 2 pt，测不出来），同时把 275 宽的那档从
    /// 60 收到 42.6。
    private var band: CGFloat {
        let width = card?.bounds.width ?? 0
        guard width > 16 else { return bandMax }
        return Swift.min(bandMax, Swift.max(bandMin, width * bandRatio))
    }
    private let bandRatio: CGFloat = 0.155
    private let bandMin: CGFloat = 20
    private let bandMax: CGFloat = 60
    /// 0.0.41 — 6 pt of tolerance on the *outside*. 0.0.37's Aevon(35) shows a
    /// thumb landing at x=390 on a card whose right edge was 375: 15 pt outside,
    /// comfortably inside a 40 pt band. The same thumb on 0.0.40's 32 pt band
    /// touched nothing. `band` is what the zone map is written in; `slack` is
    /// how far past it a touch still counts, and the two are added once, here,
    /// so the hit area and the zone arithmetic can never drift apart.
    ///
    /// 0.1.0 — 也跟着成比例。它是 `band` 的一成，上下夹在 3~8 pt：环窄的时候
    /// 一层固定 6 pt 的外扩会把「窄环」变成「宽环」，等于白改。
    private var slack: CGFloat { Swift.min(8, Swift.max(3, band * 0.10)) }
    /// The ring's real half-width: the band plus its tolerance.
    private var reach: CGFloat { band + slack }
    /// 底排五格里的角格与侧格：正方形，边长与环同宽。
    ///
    /// 用户原话「底角的缩放手势热区应该是圆角（高和宽各占一点的角）」。以前角
    /// 是「底带的三分之一宽」—— 一个 373 宽的卡片角格有 124 pt，比环还深，于是
    /// 「碰一下底边靠右」就变成缩放。改成边长 = 环厚之后，角是一个真正的方角，
    /// 想缩放就得瞄准那个角。
    ///
    /// `width / 5` 是硬上限：五个格子的宽度加起来不能超过卡片宽度，否则底排
    /// 会互相蚕食（112 宽的小窗上 4 × 20 只剩 32 给中格）。
    private var cellSide: CGFloat {
        let width = card?.bounds.width ?? 0
        guard width > 16 else { return bandMin }
        return Swift.min(band, width / 5)
    }
    /// 快速上滑: a flick, not a drag. 900 pt/s is above a deliberate slow drag and
    /// below the speed a thumb reaches when it is actually swiping away.
    private let flick: CGFloat = 900
    /// 0.1.0 — 长按门槛 0.4 → 0.25 秒（用户：「所有需要长按触发的手势时间改为 0.25」）。
    ///
    /// 0.4 是为「上滑关闭不要误触」挑的，但它同时把另外两个长按（两侧开移动闸门、
    /// 底右侧恢复默认尺寸）也拖到了 0.4 —— 那两个不是危险动作，等这么久只会让人
    /// 以为没反应。0.25 仍在系统长按（0.5）之下，`allowableMovement = 12` 保证
    /// 轻滑不会把它误判成长按。
    private let pressDelay: TimeInterval = 0.25

    var level: CGFloat { window?.windowLevel.rawValue ?? 0 }

    /// 0.1.4 — 卡片窗分成两档，**主窗一定压在所有停靠小窗之上**。
    ///
    /// Aevon(92) 第 2 条：「新吸附的小窗会遮挡主悬浮窗，已经吸附的不会」。
    /// 根因不在几何，在 z 序：0.1.3 之前所有卡片窗都是 `normal + 100` 同一个
    /// 层级，而同一层的 UIWindow 按**建窗顺序**排 —— 也就是按「谁先被打开」。
    /// 于是后开的 App 的窗永远压在先开的窗上面；先开的那张升成主窗（几何上
    /// 347x578 铺满屏幕中间）之后，它的窗仍然在最底下，被后开的那张小窗
    /// （98x163）盖住右下角那一条。
    ///
    /// 用户的原话是「已经吸附的不会」—— 完全对得上：老的窗在下面，新的在上面。
    ///
    /// 两档而不是「每次升窗都把窗提到最前」：提层要改 level 再改回来
    /// （`RingHost` 里就是这么干的），中间那一瞬会重排两次；分档是稳态，
    /// 只有「降级 / 升窗」这两个动作会换档，平时一次都不动。
    static let miniLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 100)
    /// 主窗比小窗高一层。101 与 `statusBar`（1000）之间留着整个普通窗口区间，
    /// 不会和手势环（`statusBar + 2`）、竖条（`statusBar + 1`）打架。
    static let mainLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 101)

    /// 按「现在是大卡片还是停靠小窗」换档。只在真的变了的时候写一次 ——
    /// 每次写 `windowLevel` 都是一次窗口表重排，平稳期不该有这种开销。
    private func applyWindowLevel() {
        guard let window = window else { return }
        let want = miniFrame == nil ? FloatHost.mainLevel : FloatHost.miniLevel
        guard window.windowLevel != want else { return }
        let old = window.windowLevel.rawValue
        window.windowLevel = want
        Log.write(String(format: "win: level %.0f -> %.0f %@",
                         old, want.rawValue, miniFrame == nil ? "main" : "mini"))
    }

    /// 0.0.63 — 现在交给系统的画布尺寸。看门狗（SceneProbe 的保活时钟）拿它和
    /// scene 真实的 `settings.frame` 对比，被系统改回去时当场重写并记一行 ——
    /// 0.0.61/0.0.62 只在一开一关两个时刻回读，中间那几秒是不是被改回去了，
    /// 日志里从来没有过答案。
    var canvas: CGSize { natural }

    /// Answers a host only when the window is really up and really holds the
    /// view. A nil answer means "activate nothing": a presenter whose view is
    /// not in a window is 0.0.20's black screen, and that is not worth one more
    /// phone.
    ///
    /// 0.0.82 — `bundle:` 参数随「按 App 换画布」一起撤了：画布只有一个来源，
    /// 宿主侧不再需要知道这是谁。
    static func show(_ view: UIView, bundle: String, awaitingFrame: Bool = false,
                     onClose: @escaping (String) -> Void) -> FloatHost? {
        // 0.0.98 — 取一个空槽，而不是「拿唯一那个宿主先拆掉」。
        //
        // 拆了再建有一个致命形状：建窗失败时屏幕上什么都不剩，而旧窗已经被拆过，
        // 用户看到的是「点了图标，原来的窗也没了」。现在两个槽都占着就返回 nil，
        // 由调用方说「满了」—— 一个能被日志看见的拒绝，好过一个看不见的拆。
        guard let host = takeMainSlot() else {
            Log.write("win: no free slot, " + bundle + " not shown")
            return nil
        }
        host.teardown()
        host.bundle = bundle
        host.onClose = onClose
        // 0.0.98 — 多窗的位置在这一行里。读法：
        //   `slot=` 这次占的是第几个槽（0/1），`armed=` 保活名单里现在有谁，
        //   `frames=` 有几块画布有目标，`orphan=` 有几处调用点没先登记就设尺寸。
        // 「第二个窗开出来但停靠的那个黑了」⇒ armed 里少了它，或者 frames 不等于 2。
        Log.write(String(format: "win: slot taken bundle=%@ slot=%d armed=%@ frames=%ld orphan=%ld",
                         bundle, mainIndex, AevonHookArmedList(),
                         AevonFrameArmedCount(), AevonFrameOrphanCount()))
        guard let window = host.makeWindow() else { return nil }

        window.backgroundColor = .clear
        window.isOpaque = false
        // 0.1.4 — 新开的窗一律按主窗起档（见 `mainLevel` / `miniLevel`）。
        // 这里是**唯一**建窗的地方，所以两档不会出现第三个数。
        window.windowLevel = FloatHost.mainLevel
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.isHidden = false
        guard let root = window.rootViewController?.view else {
            window.isHidden = true
            return nil
        }

        // A card that shows a phone is a card shaped like a phone: the width is
        // chosen, the height follows the picture's own aspect (0.0.24's fixed
        // 320x480 card is what put black bars at the sides).
        // 0.0.60 — 承载面按小胖屏的尺寸重新布局。
        //
        // 原来这里用的是 scene 自己的尺寸（整块屏幕），卡片是它的等比缩小 ——
        // 卡片于是永远和手机一样瘦长（430×932 的 0.62 高 = 267×578），内容只是
        // 变小。母本不是这样：她用 `setResizesHostedContext:` 让承载面跟着窗口
        // 的尺寸走，App 会按这个尺寸**重新排一版**，顶栏、底栏、抖音右侧那一列
        // 都在新布局里 —— 不是从旧布局里裁出来的。
        //
        // `bounds` 是 scene 的逻辑坐标空间：改它等于告诉 App「你的屏幕有这么大」。
        // 只碰 bounds，不碰 frame —— 后者会连同位置一起挪，0.0.22 的黑屏就是
        // 那么来的。transform 在下面单独设。
        // 0.0.62 — 交给系统的是「与手机等宽、高按 5:3 的一块屏幕」，不是卡片本身。
        // 卡片尺寸仍由高度系数决定，但它现在是这块屏幕的**等比缩小**（scale 约
        // 0.80），所以字号与圆角一起按同一个比例变小 —— 见 `fatRender`。
        // 0.0.65 — 画布只有一个来源：屏幕宽度 × 5:3。没有第二个写入口，
        // 「记忆的形状」与开关一起撤了（见 `fatRender`）。
        // 0.0.79 — 只有一个例外：这个 App 上一次把「我的页是整屏高」写在记号里
        // （哔哩哔哩的竖版故事）。那就给它整屏画布，卡片按整屏比例缩 —— 见
        // `wantsFullCanvas` 与 `fatRender` 的 `full` 分支。
        // 0.0.82 — 那个例外撤了：画布恒为 5:3，`render` 与 `hosted` 从此永远相等。
        let source = FloatHost.fatRender(in: window.bounds.size)

        // 0.0.61 — 这一行才是「小胖屏」真正生效的地方。
        //
        // 改下面的 `view.bounds` 只换了画布，App 依旧按整屏排版；Aevon(52) 的日志
        // 把它摊得很清楚：`hosted bounds after=377x628 asked=377x628`（视图确实改
        // 了），`scale factor=1.000`（一比一），于是 430 宽的界面被直接裁进 377 的
        // 框 —— 字大、顶栏偏右、底栏与抖音右侧那一列都在框外。
        //
        // `AevonSceneFrameSet` 把目标记在 C 侧，intercept 钩子在系统下一次更新
        // settings 时把它写进 scene 的 frame（母本的路线），SceneProbe 拿到 scene
        // 后还会主动推一次，不等系统那一拍。
        // 0.0.98 — 画布目标按窗登记：这一块画布归 `bundle`，不再是「唯一的那一块」。
        // 0.0.82 撤掉的 `bundle:` 参数因此回来了，但用途完全不同：那时它用来换画布
        // 比例，现在它只是 C 侧那张表里的一个键。
        AevonSceneFrameSet(host.bundle, 0, 0, Double(source.width), Double(source.height))

        view.transform = .identity
        view.autoresizingMask = []
        view.bounds = CGRect(origin: .zero, size: source)

        let plan = host.plan(in: window.bounds, source: source)
        // 0.0.60 — 不再裁顶栏。要的是「完整展示」，可见块就是承载面本身。
        // `visible` 这个名字留着：`followContent` / `recenterCard` 都读它。
        let visible = source
        let frame = plan.frame

        let card = UIView(frame: frame)
        // 0.1.7 — 新开的这张就是主窗，它的几何就是「上一个主悬浮窗」的基准。
        FloatHost.lastMainFrame = frame
        // 0.0.81 — 画布装不满卡片时（哔哩哔哩竖版：430×932 按高等比缩进 5:3），
        // 两边会各露出一条。留透明就是把桌面透进来，看上去像卡片没画完；填黑
        // 是「这一页之外」的通用答案，和播放器留边同一套观感。画布正好是 5:3
        // 时（其余所有 App）这一行等于 `.clear`，和以前一模一样。
        card.backgroundColor = .clear
        // 0.0.48 — 白色描边撤掉（Aevon(46) #2「边缘的白色线条太明显」）。
        //
        // 那 2 pt 是 0.0.24 留下的：当时卡片里可能是空的，需要一个框说明「这是一
        // 个窗口」。现在卡片里永远是真实画面，画面自己就是边界；再画一条白线，
        // 等于给一张有内容的图套个相框。圆角保留（它是有用的，见 `applyCorner`），
        // 边框不保留。
        card.clipsToBounds = true
        card.isUserInteractionEnabled = true
        host.card = card
        host.content = view
        host.natural = source
        host.visible = visible
        host.screenCorner = FloatHost.deviceCorner()
        // 0.0.60 — 裁切量恒为 0。`cropTop` 这个量还留着，因为 `followContent`
        // 与 `recenterCard` 都按它对齐中心：0 就是「不用对齐」，两条路径都正确。
        host.cropTop = 0
        host.applyCorner()
        host.applyBars()

        // 承载面保持 scene 自己的坐标空间，整块缩放 —— 改 `frame` 会重写那个
        // 空间，0.0.22 的空白卡片就是那么来的。`bounds` 已经在上面对准小胖屏
        // 尺寸了（那一步让 App 重新布局），这里只负责把它摆在卡片中间。
        //
        // 0.0.60 — `scale` 初始就是 1.000：卡片的尺寸就是承载面的尺寸，一比一。
        // 之后拖大拖小走的是 transform，`bounds` 不再变 —— 一个窗口在手上被拉
        // 扯的时候不该让 App 每一帧都重排一次界面。
        view.center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        view.transform = CGAffineTransform(scaleX: plan.scale, y: plan.scale)
        card.addSubview(view)

        // 0.0.58 — 冷启动不再盖图标。
        //
        // 0.0.57 盖的是「图标 + 名字」。它不是黑屏，但也不是那个 App —— 用户
        // 看到的是「点了微信，出来一张微信的卡片封面」，那是应用商店的观感，
        // 不是系统该有的观感（Aevon(52) 的原话：这样不好看）。
        //
        // 母本没有这一步，原因在它的选择子表：`launchApplicationWithIdentifier:
        // suspended:` 根本不在 `__objc_selrefs` 里，它走的是
        // `_activateBundleID:requestID:isTrusted:options:source:originalSource:
        // withResult:` 与 `_createSceneWithDefinition:...` —— 系统自己的激活路
        // 径，App 从诞生那一瞬就是「该画」的状态，第一帧不需要谁去激活。
        // 我们这条挂起启动的路做不到这一点（见 SceneProbe 的唤醒段），所以
        // 能改的不是「画得更好」，而是**不让空窗被看见**：
        //
        //   卡片先建好、但 alpha 为 0 —— 桌面上什么都不多出来；
        //   第一帧到的那个节拍淡入；三秒还没到就强制露出来，让操作者至少能关掉。
        //
        // 这比「先给一块深色板再换成画面」少一次亮度的硬切换：那一次切换本身
        // 就是被投诉的那个「闪」。
        if awaitingFrame {
            host.awaitingFrame = true
            host.frameAt = CACurrentMediaTime()
            card.alpha = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak host] in
                host?.revealContent("timeout")
            }
        }
        // 0.0.49 — 光晕在卡片**下面**。描边撤掉之后，深色壁纸上的卡片边界看不出来
        // （Aevon(47) #2）；母本的做法不是画线，而是给卡片加一层柔光 —— 二进制里
        // 有 SwiftUI 的 `_ShadowEffect` 与 `_BlurEffect`，没有 border 相关的具体值。
        // 所以这里是 `layer.shadow`，不是 border：模糊半径大、透明度低，只负责把
        // 卡片从同样深的背景里托起来，不构成一条可见的边。
        //
        // 单独一层而非直接给 card 加阴影：card 自己 `masksToBounds = true`（画面要
        // 被圆角裁掉），阴影会被一起裁掉。放在下面当兄弟，才画得出来。
        let glow = UIView(frame: plan.frame)
        glow.backgroundColor = .clear
        glow.isUserInteractionEnabled = false
        glow.layer.shadowOffset = .zero
        glow.layer.shadowOpacity = 1
        // 0.0.59 — 光晕必须与卡片同进同出。
        //
        // 0.0.58 只把 `card.alpha` 置 0，漏了这一个兄弟层：卡片透明的一两秒里，
        // 屏幕上仍然有一圈阴影在，形状和位置都与卡片一样。Aevon(58) 说的
        // 「悬浮窗先出现」就是它 —— 不是窗口，是窗口的影子。然后卡片淡入、
        // 画面跳进来，第二下就是「闪」。
        if host.awaitingFrame { glow.alpha = 0 }
        root.addSubview(glow)
        host.glow = glow
        root.addSubview(card)

        host.window = window
        // 0.0.47 — 手势环搬到 band 窗口（statusBar+1）。卡片留在这一层，所以
        // 里头的点击滑动照旧；伸手的那一圈在一个不会被任何 App 窗口盖住的层。
        host.installGrip(on: host.makeBand() ?? root)
        host.installGestures()

        // 0.0.60 起是「与手机等宽、高按 5:3」的日志口径。`hosted=` 是下发承载面
        // 的逻辑尺寸，`card=` 是它在屏幕上的尺寸；两者除一个 scale 之外相等就是
        // 「App 按这个尺寸重新布局」。0.0.82 起 `render=` 不再有第二种可能：
        // 0.0.79 那个 `full=0/1` 的读数随整屏画布一起撤了，这一行里 `render=`
        // 与 `hosted=` 必须永远是同一个数；不一样的版本，就是又有人换过画布。
        let fatA = String(format: "win: fat scene ratio=%.3f screen=%.0fx%.0f render=%.0fx%.0f",
                          FloatHost.fatAspect,
                          window.bounds.width, window.bounds.height,
                          source.width, source.height)
        let fatB = String(format: " hosted=%.0fx%.0f card=%.0fx%.0f at %.0f,%.0f held=%d",
                          source.width, source.height,
                          card.bounds.width, card.bounds.height,
                          card.frame.origin.x, card.frame.origin.y,
                          host.awaitingFrame ? 1 : 0)
        Log.write(fatA + fatB)
        // 0.0.61 — 逻辑尺寸的证词。上面那行说的是「画布多大」，这一行说的才是
        // 「App 以为自己有多大」。两行都读到同一个数，小胖屏才真的成立。
        Log.write("win: scene frame asked=" + String(format: "%.0fx%.0f", source.width, source.height)
                  + " screen=" + String(format: "%.0fx%.0f", window.bounds.width, window.bounds.height))
        // 一次性的证词：presenter 有自己的尺寸管理，万一它把 `bounds` 改回屏幕
        // 尺寸，这一行会直接说出来 —— 「小胖屏没生效」和「App 不肯按新尺寸重排」
        // 是两件事，只有这一个读数能把它们分开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak view] in
            guard let view = view else { return }
            Log.write(String(format: "win: hosted bounds after=%.0fx%.0f asked=%.0fx%.0f",
                             view.bounds.width, view.bounds.height,
                             source.width, source.height))
        }
        Log.write("win: scale factor=" + String(format: "%.3f", plan.scale)
                  + " shown=" + String(format: "%.0fx%.0f",
                                       visible.width * plan.scale, visible.height * plan.scale)
                  + " fill=" + String(format: "%.0fx%.0f",
                                      card.bounds.width, card.bounds.height)
                  + " card_corner_pt=" + String(format: "%.0f", card.layer.cornerRadius))
        // 0.0.81 — 画布装进 5:3 之后两边各留多少。
        //
        // 0.0.82 起画布恒为 5:3，两边必然是 0（取整误差 ≤ 0.5 pt，这条不打印）。
        // 留着它是因为它是「卡片和画布不是一个形状」唯一的读数：哪一天这一行又
        // 打出 42，就说明画布又被谁换成了整屏 —— Aevon(73) 的哔哩哔哩就是这个数。
        let barSide = Swift.max(0, (frame.width - visible.width * plan.scale) / 2)
        if barSide > 0.5 {
            Log.write(String(format: "win: letterbox side=%.0fpt flat=%d canvas=%.0fx%.0f",
                             barSide, 1, source.width, source.height))
        }
        // 0.0.64 — 开窗这一拍就说清「边角拖动现在是什么语义」，并且把圆角的
        // 三个输入都摆在同一行：`mode` 来自设置，`canvas` 是交给系统的形状，
        // `corner` 是按卡宽算出来的那个数。
        host.logResize()
        // Where the ring is, so the next log can be read against the code instead
        // of against a memory. Two `let`s: one long concatenation of format calls
        // is a type-checker timeout, and 0.0.30 lost a build to it.
        let ring = "win: grip ring band=" + String(format: "%.0f", host.band)
        // 0.1.0 — 底排五格之后不再有「一个中格矩形」可打印，改打角格边长（角与
        // 侧格同宽）。这一行是「热区到底多大」的唯一读数：它是环厚的一个比例，
        // 卡片一变它就变 —— 正是 Aevon(88) 第 2 条要验的东西。
        let cell = " cell=" + String(format: "%.0f", host.cellSide)
        // 0.0.46 — the room left on each side, printed with the ring. A band
        // narrower than `reach` is a band the thumb cannot find, and that is
        // exactly what 0.0.45 could not show: `room=l57 r8 t56 b84` would have
        // ended the round in one line.
        let room = " room=" + String(format: "%.0f/%.0f/%.0f/%.0f",
                                     card.frame.minX,
                                     window.bounds.width - card.frame.maxX,
                                     card.frame.minY,
                                     window.bounds.height - card.frame.maxY)
        // 0.0.47 — 环实际铺到哪儿，和圆角一起打印。`inset` 是环相对卡片的内嵌量
        // （卡片贴边时那一边会小于 60），`corner` 是缩放后的屏幕圆角。
        let fit = " inset=" + String(format: "%.0f/%.0f", host.bandInset.x, host.bandInset.y)
            + " corner=" + String(format: "%.0f", card.layer.cornerRadius)
        Log.write(ring + cell + room + fit
                  + " 外侧 (四边 拖动, 左右 点吸附, 底中 上滑关, 底角 缩放, 底右内 长按复位, 底左内 横屏待落)")
        // 0.1.26 — 入场：0.94 → 1。母本的卡片出现是 SwiftUI 的 `AnyTransition`
        // （`.scale`/`.opacity` 组合，`AnyTransitionV5scale` / `V7opacity` /
        // `V8combined` 三个 stub 都在），不是硬切。这里只做缩放，透明度归
        // `revealContent` 管 —— 两件事分开，才不会「卡片先亮、画面后到」两段式。
        var entering: [UIView] = [card]
        if let glow = host.glow { entering.append(glow) }
        AevonMotion.enter(entering)
        return window.isHidden ? nil : host
    }

    /// Records what the operator just did with the card.
    ///
    /// Called at the end of a move and nowhere else: an in-flight drag would be a
    /// disk write forty times a second on SpringBoard's main thread, for a value
    /// nobody can read until the finger lifts.
    ///
    /// 0.0.40 — the drag no longer snaps to an edge. Snapping and 吸附 stopped
    /// being the same thing the moment 吸附 became a tap: a card pulled hard
    /// against the screen for being nudged near it, while a card that becomes a
    /// 停靠小窗 only on a deliberate tap, are two answers to one word. The card
    /// now stays exactly where the finger left it, and that is what is stored.
    ///
    /// While docked, only the mini's own frame is updated. Writing that to the
    /// file would make a temporary size look like the operator's chosen one.
    private func remember(in bounds: CGRect) {
        guard let card = card, bounds.width > 0, bounds.height > 0 else { return }
        // 0.0.99 — 停靠中不改记忆。
        //
        // `miniFrame` 是「取消停靠要回到的那个大卡片」，不是「小窗现在在哪」。
        // 0.0.98 及以前这里把 `card.frame`（小窗）写进去，于是拖一下停靠小窗、
        // 再取消停靠，回到的是一个 168×280 的「大卡片」。
        if miniFrame != nil { return }
        var placement = CardLayout.loadRuntime()
        let origin = card.frame.origin
        let normalized = CGPoint(x: origin.x / bounds.width, y: origin.y / bounds.height)
        placement.edge = origin.x + card.bounds.width / 2 < bounds.width / 2 ? .left : .right
        if placement.edge == .left {
            placement.left = normalized
        } else {
            placement.right = normalized
        }
        placement.heightFraction = card.bounds.height / bounds.height

        let ok = CardLayout.save(placement)
        let side = placement.edge == .left ? "left" : "right"
        let at = String(Int((normalized.x * 100).rounded())) + "% / "
            + String(Int((normalized.y * 100).rounded())) + "%"
        let tall = " h=" + String(Int((placement.heightFraction * 100).rounded())) + "%"
        Log.write("win: card remembered " + side + " at " + at + tall
                  + (ok ? "" : " (write failed)"))
    }

    /// The hosted view belongs to the system. It leaves with the card and never
    /// with the window: holding a presentation view after the presenter is gone
    /// keeps a scene alive that should have been reclaimed.
    static func hide() {
        shared.teardown()
    }

    /// 0.0.98 — 只拆「这个 App 那一块」。
    ///
    /// 多窗之后「关一个窗」不再等于「拆唯一那个宿主」：关掉主窗时停靠小窗必须
    /// 活着，否则用户看到的是「关一个，两个都没了」。按 bundle 找宿主；找不到
    /// （或名字为空，那是老调用点）就退回拆当前主窗 —— 旧行为因此完全不变。
    static func hide(bundle: String) {
        ensureSlots()
        if !bundle.isEmpty {
            for slot in slots where slot.window != nil && slot.bundle == bundle {
                slot.teardown()
                // 0.0.99 — 关掉的若是主窗，`mainIndex` 要指向还活着的那一个，
                // 否则 `mainBundle` 从此回答空串，下一个 `openCard` 会以为屏幕上
                // 没有卡而跳过错位。
                if slots[mainIndex].window == nil,
                   let alive = slots.firstIndex(where: { $0.window != nil }) {
                    mainIndex = alive
                }
                return
            }
            // 0.0.99 — 名字对不上就**什么都不拆**。0.0.98 这里退回拆当前主窗，
            // 多窗之后那等于「找不到 A 就把 B 关掉」。
            Log.write("win: hide found no window for " + bundle)
            return
        }
        shared.teardown()
    }

    private func teardown() {
        guard let window = window else {
            bandWindow?.isHidden = true
            bandWindow = nil
            onClose = nil
            FloatHost.releaseDock(self)
            // 0.1.26 — 拆掉一格之后，后面几格要「滑上来」而不是瞬移。
            FloatHost.relayoutDocked(animated: true)
            return
        }
        // 0.0.68 — 收窗时**不碰**承载视图。
        //
        // 0.0.67 在这里写过 `content.bounds = UIScreen.main.bounds.size` 与
        // `transform = .identity`，想复位 Aevon(58) 的「关掉浮窗后全屏打开抖音整体
        // 偏下」。那两个属性确实是我们改过的，但 `content` 不是我们的对象 ——
        // `_UIScenePresentationView` 下面挂着 `_UIContextLayerHostView` 和那个 App
        // 的 scene。在 presenter 还活着的时候替它写 bounds，是让系统按「整屏」去
        // 重排一个逻辑尺寸仍是 717 的场景；真机结果是应用打不开、桌面黑屏，与
        // 0.0.65 那次同形。
        //
        // 我们现在做的只有「把它从卡片上摘下来」，剩下的交给 `deactivate` /
        // `invalidate`。代价是那条「退出后偏下」还没修（本轮明确不修），收益是
        // 不再有任何一行代码去写别人的视图。
        for sub in card?.subviews ?? [] { sub.removeFromSuperview() }
        grip?.removeFromSuperview()
        glow?.removeFromSuperview()
        glow = nil
        card?.removeFromSuperview()
        // 0.1.8 — 拆窗也要撤标记：留在 App 容器里等于那个 App 以后再也收不到触摸。
        setMiniFlag(false)
        grip = nil
        shield = nil
        awaitingFrame = false
        card = nil
        content = nil
        visible = .zero
        cropTop = 0
        pan = nil
        press = nil
        tap = nil
        miniFrame = nil
        ringProbe = 0
        rawProbe = 0
        rawSeen = 0
        rawActive = false
        rawPress?.cancel()
        rawPress = nil
        lastTouchStamp = 0
        lastTouchPhase = -1
        lastTouchEaten = false
        bandInset = .zero
        onClose = nil
        // The band's window goes with it. It is full-screen and one level below
        // the summon bar; leaving it up would be a transparent sheet over the
        // desktop for as long as SpringBoard lives.
        bandWindow?.isHidden = true
        bandWindow = nil
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        // 0.0.99 — 关掉的窗必须退出停靠表，否则后面的小窗会按一个空槽算位置。
        FloatHost.releaseDock(self)
        // 0.1.26 — 见上：补位要有过渡，不能瞬移。
        FloatHost.relayoutDocked(animated: true)
    }

    private func makeWindow() -> FloatWindow? {
        if let scene = mainScene() {
            let window = FloatWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            return window
        }
        return FloatWindow(frame: UIScreen.main.bounds)
    }

    /// 0.0.47 — 手势面所在的那一层。
    ///
    /// 母本自己的证据（Stheno 0.1.23）：Preference 的文案里有
    /// `StatusBarEmbeddedWindow = 嵌入状态栏窗口`，类表里有
    /// `_TtC6Stheno21UIStatusBarWindowHook`，`SthenoWindow` 又自己实现了
    /// `-hitTest:withEvent:`。三件事合起来是一句话：母本不把浮窗的手势面放在
    /// 普通层级的窗口里，它挂到系统最上层去。
    ///
    /// 我们这边的证据一样硬：0.0.46 的几何是对的（环 399x710，四边各留 66），
    /// 但 Aevon(44)/(45) 两份日志里，卡片所在的那个窗口一共只收到**一个**触摸
    /// —— 就是 ✕ 关闭键。触摸根本没到窗口，几何再准也没有机会生效。所以手势面
    /// 搬上来，卡片留在下面：内容照样能点能滑，伸手的那一圈在一个 App 窗口盖
    /// 不到的高度。
    private func makeBand() -> UIView? {
        guard let scene = mainScene() else { return nil }
        let window = BandWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .clear
        window.isOpaque = false
        // 竖条搬到 statusBar+2（见 RingHost.start），比这一层高一级：卡片开着
        // 的时候，右侧的环正好压在竖条原来的位置上，竖条必须在上面才抢得到手指。
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        let root = BandRoot(frame: window.bounds)
        root.backgroundColor = .clear
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let controller = UIViewController()
        controller.view = root
        window.rootViewController = controller
        window.isHidden = false
        window.probe = { [weak self] point, hit in
            guard let self = self, self.ringProbe < 20 else { return }
            self.ringProbe += 1
            Log.write("win: band probe " + String(format: "%.0f,%.0f", point.x, point.y)
                      + " -> " + hit)
        }
        bandWindow = window
        Log.write("win: band window up level=" + String(Int(window.windowLevel.rawValue)))
        return root
    }

    /// The card is the picture's shape, so there is no leftover to show as a
    /// black bar. Width is chosen first (capped by the screen) and the height
    /// follows; the screen caps the height in the other direction.
    ///
    /// 0.0.39 — the card comes back where it was left: height from
    /// `HeightFraction`, width from the scene's aspect, origin from the stored
    /// corner for the current edge, clamped on screen.
    /// `given` 是**可选的**输入口径，0.1.1 才加。
    ///
    /// 以前这里只读 `loadRuntime()`（存盘的 `Placement`），于是 `resetToPlan` 拿
    /// 它算「默认尺寸」—— 而存盘里的 `heightFraction` 正是**用户上次缩放后的
    /// 高度**（`remember` 每次都写）。两边同一个来源，算出来的 frame 和卡片现状
    /// 必然一致，`already default` 就永远成立：Aevon(89) 里 322×537、259×431、
    /// 397×662、360×600 四个不同尺寸全部被判「已经是默认」。
    ///
    /// 「默认」必须是**出厂值**（`Placement.initial`，含设置里的高度系数滑条），
    /// 不是存盘值。存盘值只该决定「下次开窗摆哪、多大」，不该决定「复位目标是
    /// 什么」—— 否则复位就是「复位到我现在这样」。
    private func plan(in bounds: CGRect, source: CGSize,
                      using given: CardLayout.Placement? = nil) -> (frame: CGRect, scale: CGFloat) {
        guard bounds.width > 64, bounds.height > 200, source.height > 16 else {
            return (CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight), 1)
        }
        let placement = given ?? CardLayout.loadRuntime()
        // 0.0.81 — 卡片的形状不再跟着画布走。以前 `ratio = source.width /
        // source.height`，于是「画布是什么形状，卡片就是什么形状」；哔哩哔哩
        // 要 932 的画布，卡片就成了 9:19.5，用户看到的是「小胖屏对它无效」。
        // 现在卡片永远是 5:3，画布按 `fitScale` 装进去（等比、居中）。
        let ratio = 1.0 / FloatHost.fatAspect

        var h = bounds.height * placement.heightFraction
        var w = h * ratio
        let widest = bounds.width - margin * 2
        if w > widest {
            w = widest
            h = w / ratio
        }
        // The tall guard from 0.0.24 stays: a short screen with a tall scene
        // still has to leave room to see what is behind the card.
        // 0.0.45 — 96, not 160: at 160 the master's own 85 % height was being
        // clipped to 772 pt on a 932 screen, which reintroduced the strip.
        let tallest = bounds.height - 96
        if h > tallest {
            h = tallest
            w = h * ratio
        }
        // 0.0.62 — 不放大。卡片高过承载面高时 scale > 1，画面是插值出来的，
        // 字会变糊；高度系数调到 80 % 时正好踩到这条（717 × 0.8 = 573，勉强
        // 还没到，但没有这行就等于把「能不能放大」交给了滑条）。缩放比落在
        // 0<scale≤1 这一侧，圆角与字号才都只有「变小」这一个方向。
        if h > source.height {
            h = source.height
            w = h * ratio
        }
        let saved = placement.origin(for: placement.edge)
        var x = saved.x * bounds.width
        var y = saved.y * bounds.height
        // 0.0.46 — the card may not use the last `reach` of the screen.
        //
        // The band lives *outside* the card, so the two are in direct
        // competition for the same pixels: 0.0.45's card was 365 pt wide on a
        // 430 pt screen and sat 8 pt from the right edge, which means the right
        // band was 8 pt wide. Aevon(44) read that as 「四周的手势依旧是失效」
        // and it is neither a hit-test bug nor an app-bridge bug — the band was
        // simply not there. Whatever the card's size, it now leaves `reach` on
        // every side the screen has room for.
        //
        // 0.0.67 — **while it has no room, it keeps the operator's place.**
        //
        // The `else` branch used to centre the card, and that was the whole of
        // Aevon(58)'s 「缩放时会自动挪位置」: the fat canvas is 430 wide, the band
        // claim is 66 per side, so any card wider than 298 pt fell into the
        // else branch and had its remembered x thrown away. Every card here is
        // 350-371 wide — the branch was not an edge case, it was the only case.
        // Aevon(58) shows it three times over: remembered 12 % (=52 pt) came
        // back at 30, 10 % (=43) came back at 34, 9 % (=39) landed on 38 — the
        // last one only because centring happened to agree with the memory.
        //
        // A card that wide has already eaten the band's room; `bandRect` shrinks
        // the ring to whatever is actually left, so centring buys nothing and
        // costs the operator their place. Keep the place, clamp on screen.
        let room = reach
        if w + room * 2 <= bounds.width {
            x = Swift.min(Swift.max(room, x), bounds.width - w - room)
        } else {
            x = Swift.min(Swift.max(0, x), Swift.max(0, bounds.width - w))
        }
        // Clamp as a rectangle, not as two numbers: a width change from a
        // rotation must not leave the right edge 40 pt outside the screen.
        if h + room * 2 <= bounds.height {
            y = Swift.min(Swift.max(0, y), bounds.height - h - room)
        } else {
            y = Swift.min(Swift.max(0, y), Swift.max(0, bounds.height - h))
        }
        return (CGRect(x: x, y: y, width: w, height: h),
                FloatHost.fitScale(for: source, in: CGSize(width: w, height: h)))
    }

    // MARK: - close
    //
    // 0.0.54 — 右上角那颗 ✕ 撤掉了（Aevon 的要求：它压在画面上，和 App 自己
    // 的顶栏右下角凑在一起，又挡内容又不好看）。关窗的路没有变少，只是换成
    // 手势：底边中段快速上滑仍然关闭（`dragEnd`），另外还有十分钟上限兜底。
    // 这里留着 `requestClose` —— 它现在是**唯一**一条关窗入口的出口，把
    // 「谁关的」写进日志，比从一个控件数组里猜要可靠。

    private func requestClose(_ reason: String) {
        let hook = onClose
        onClose = nil
        Log.write("win: close requested by " + reason)
        // 0.1.26 — 关窗也要有过渡。原来这一拍直接回调，场景一拆卡片就没了 ——
        // 用户看到的「关闭没有动画」就是这个。缩回 + 淡出 0.2 s，然后才交回
        // 场景拆除；动画期间卡片不接受触摸，免得「点了关还拖了一下」。
        var leaving: [UIView] = []
        if let card = card { leaving.append(card) }
        if let glow = glow { leaving.append(glow) }
        guard leaving.isEmpty == false else {
            DispatchQueue.main.async { hook?(reason) }
            return
        }
        AevonMotion.exit(leaving) {
            DispatchQueue.main.async { hook?(reason) }
        }
    }

    // MARK: - ring

    /// The ring is the card's frame grown by `reach` on all four sides, with the
    /// card's own rect declared as a hole. Nothing about it is special: it has no
    /// background, it draws nothing, it exists to be touched.
    ///
    /// 0.0.47 — 手势环：卡片四周一圈，厚度 `reach`，但**按屏幕截断**，一路铺到
    /// 屏幕边缘。
    ///
    /// 0.0.46 用的是 `card.frame.insetBy(dx: -66, dy: -66)`。卡片居中时四周各
    /// 剩 82 pt，环只吃 66，靠屏幕边的最后 16 pt 是死区 —— 而「从屏幕边缘往里
    /// 划」正是伸手的第一个动作，那一划正好落在死区里。
    private func installGrip(on root: UIView) {
        guard let card = card else { return }
        let shape = bandRect(for: card)
        let grip = GripView(frame: shape.frame)
        grip.backgroundColor = .clear
        grip.isUserInteractionEnabled = true
        grip.hole = shape.hole
        root.addSubview(grip)
        self.grip = grip
        syncGrip()
    }

    /// 环的 frame、卡片在环里的位置、以及环相对卡片的四边内嵌量。三者出自同
    /// 一次计算，所以「环在哪」和「zone 怎么算」不可能各说各话。
    private func bandRect(for card: UIView) -> (frame: CGRect, hole: CGRect, inset: CGPoint) {
        let bounds = window?.bounds ?? UIScreen.main.bounds
        let left = Swift.min(reach, Swift.max(0, card.frame.minX))
        let right = Swift.min(reach, Swift.max(0, bounds.maxX - card.frame.maxX))
        let top = Swift.min(reach, Swift.max(0, card.frame.minY))
        let bottom = Swift.min(reach, Swift.max(0, bounds.maxY - card.frame.maxY))
        let frame = CGRect(x: card.frame.minX - left,
                           y: card.frame.minY - top,
                           width: card.frame.width + left + right,
                           height: card.frame.height + top + bottom)
        let hole = CGRect(x: left, y: top,
                          width: card.frame.width, height: card.frame.height)
        return (frame, hole, CGPoint(x: left, y: top))
    }

    /// 0.0.47 — 圆角。
    ///
    /// 母本的数据：`DeviceEnv` 有 `cornerRadius` 字段，二进制 `__cstring` 里有
    /// `_displayCornerRadius` 这个键，`ReflectManager` 有 `finalCardCorner` ——
    /// 也就是说圆角不是拍出来的常数，取的是**设备自己的屏幕圆角**，再按卡片
    /// 的缩放比缩一遍，并且和 frame 一起被动画。
    ///
    /// 这里照做：卡片是 430x932 的画面按 0.62 缩小，屏幕圆角 55 就落成 34。
    /// 0.0.62 — 圆角再收一档。
    ///
    /// 之前是「设备圆角 × 视图缩放比」。缩放比从 1.000 掉到 0.80 之后，圆角
    /// 确实从 55 变成 44，但**它占卡片宽的比例一点没变**（55/430 与 44/345 都是
    /// 12.8 %）—— 所以「太圆」不会因为缩放而改善，得单独收比例。
    ///
    /// `cornerTune` 把 12.8 % 拉到 11.5 %：345 宽的卡片从 44 落到 40。这是母本
    /// `ReflectManager.finalCardCorner` 那层意思（设备圆角 × 卡片缩放比）之外的
    /// 一次人为收敛 —— 她的卡片永远接近整屏，不需要这一档，我们的不是。
    ///
    /// 0.0.64 — 两个真机反馈把这一档夹在中间：0.0.61 的 44（12.8 %）「太圆」，
    /// 0.0.63 的 34（10.1 %）「太方」。取中点偏上 11.5 %：337 宽的卡片落 39。
    private let cornerTune: CGFloat = 0.90

    /// 0.0.64 — 圆角**只由卡片的短边走**，不再由「卡片高 / 画布高」推。
    ///
    /// 0.0.63 的写法是 `deviceCorner * (cardH / visibleH) * tune`，而那正是
    /// 「缩放时四角会变成直角」那条反馈的成因，日志里数得出来：12:17:28 画布
    /// 换到 430×716，之后一路往下拖，卡片被拖到 363×279 时 `cardH / 716` 只剩
    /// 0.39 —— 圆角算出来 16.7 pt，占 363 宽只有 4.6 %，看着就是直角。
    /// 抬手之后画布跟着换，圆角又弹回 10 %，于是「一缩放就方、一松手又圆」。
    ///
    /// 圆角在观感上由**卡片自己的宽度**支配（0.0.62 就是这一条），那就直接按
    /// 宽度算：`屏幕圆角 × (卡宽 / 屏宽) × tune`，卡宽不变圆角就不变。竖着压扁
    /// 一张卡不再改变它的圆角。几何缩放关掉之后这条更关键：画布从此不动，
    /// 若还按 `cardH / 画布高` 算，圆角会随着卡片变矮一路缩水并且再也不回来。
    private func applyCorner() {
        guard let card = card, natural.width > 1 else { return }
        let corner = screenCorner > 1 ? screenCorner : FloatHost.deviceCorner()
        let share = corner / natural.width * cornerTune
        // 短边：竖着的卡片是宽度（和 0.0.62 同一个数），压扁的卡片是高度，
        // 两者都不会超过半张卡 —— 再大就是胶囊，不是圆角。
        let side = Swift.min(card.bounds.width, card.bounds.height)
        let radius = Swift.max(6, Swift.min(side * share, side / 2))
        // 0.1.26 — 圆角跟着尺寸一起走。
        //
        // `cornerRadius` 不是 UIView 的动画属性：在 `UIView.animate` 块里改它是
        // 硬赋值，卡片从 98×163 长回 347×578 的那 0.27 秒里，外框在动、圆角已经
        // 跳到终点值 —— 观感是「框是软的、角是硬的」。正在一次过渡里就补一条同
        // 时长的 `CABasicAnimation`，把这一跳盖掉。
        if AevonMotion.inFlight, abs(card.layer.cornerRadius - radius) > 0.5 {
            let anim = CABasicAnimation(keyPath: "cornerRadius")
            anim.fromValue = card.layer.cornerRadius
            anim.toValue = radius
            anim.duration = AevonMotion.response
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.layer.add(anim, forKey: "aevon.corner")
        }
        card.layer.cornerRadius = radius
        card.layer.cornerCurve = .continuous
        card.layer.masksToBounds = true
    }

    /// The screen's own corner radius, asked for at runtime. roothide's SpringBoard
    /// answers `_displayCornerRadius`; a device that does not gets the value every
    /// full-screen iPhone since the X has used, which is close enough to look right.
    private static func deviceCorner() -> CGFloat {
        let selector = NSSelectorFromString("_displayCornerRadius")
        if UIScreen.main.responds(to: selector),
           let value = UIScreen.main.value(forKey: "_displayCornerRadius") as? NSNumber,
           value.doubleValue > 1 {
            return CGFloat(value.doubleValue)
        }
        return 55
    }

    /// Every frame change goes through here. A ring that lags its card by one
    /// event is a ring the finger misses by one band.
    private func syncGrip() {
        guard let card = card, let grip = grip else { return }
        let shape = bandRect(for: card)
        grip.frame = shape.frame
        grip.hole = shape.hole
        bandInset = shape.inset
        // 光晕、圆角、环三者必须同一次事件里一起走。慢一帧就是「卡片动了、光圈
        // 还留在原地」。
        applyGlow()
    }

    /// 0.0.49 — 卡片边缘的柔光。
    ///
    /// 深色模式给白、浅色模式给黑，两者都只在很低的透明度上：目的是让卡片从
    /// 和它一样深的背景里分出来，而不是给卡片画一圈灯。半径取圆角的六成左右，
    /// 这样光从圆角里透出来的形状和卡片本身的连续曲率一致。
    private func applyGlow() {
        guard let card = card, let glow = glow else { return }
        glow.frame = card.frame
        let radius = card.layer.cornerRadius
        let dark = card.traitCollection.userInterfaceStyle == .dark
        // 0.22 / 0.16 — 两次真机反馈之间的取值：0.35 已经能看出「发光」，0.10 在
        // 深色壁纸上又看不出来。深色的白稍强，因为白色比黑色更需要靠亮度争边界。
        glow.layer.shadowColor = (dark ? UIColor.white : UIColor.black).cgColor
        glow.layer.shadowOpacity = dark ? 0.22 : 0.16
        glow.layer.shadowRadius = Swift.max(10, Swift.min(radius * 0.7, 22))
        glow.layer.shadowPath = UIBezierPath(roundedRect: glow.bounds,
                                            cornerRadius: radius).cgPath
    }



    /// 底排怎么分格：角 / 侧 / 中 / 侧 / 角，五格（0.1.0）。
    ///
    /// 角格与侧格都是边长 = 环厚的正方形（见 `cellSide`），中间那一格吃掉剩下的
    /// 宽度。所以整排的宽度恒等于卡片宽度，不会出现「最后一格探到卡片外面」。
    ///
    /// 上沿（`top`）与左右两条竖边仍是各自一整格：母本的文案把整个周界都算作
    /// 手势区（「浮窗手势区域为边缘外侧」），而「四边手势失效」那三轮反馈说的是
    /// 周界上有一条边是死的。
    private func zoneFor(_ point: CGPoint) -> Zone {
        guard let card = card else { return .bottomRight }
        let size = card.bounds.size
        if point.y > size.height {
            let side = cellSide
            if point.x < side { return .bottomLeft }
            if point.x < side * 2 { return .bottomLeftSide }
            if point.x > size.width - side { return .bottomRight }
            if point.x > size.width - side * 2 { return .bottomRightSide }
            return .bottomMiddle
        }
        if point.y < 0 { return .top }
        return point.x < 0 ? .left : .right
    }


    private func name(_ zone: Zone) -> String {
        switch zone {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottomMiddle: return "bottom-middle"
        case .bottomLeft: return "bottom-left"
        case .bottomRight: return "bottom-right"
        case .bottomLeftSide: return "bottom-left-side"
        case .bottomRightSide: return "bottom-right-side"
        }
    }

    /// Ring coordinates back to the card's own, which is the space the zones and
    /// the geometry are written in. A point outside the card comes back negative
    /// or past the size, and that is precisely how a band is recognised.
    private func cardPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - bandInset.x, y: point.y - bandInset.y)
    }

    // MARK: - gestures

    private func installGestures() {
        guard let grip = grip else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        grip.addGestureRecognizer(pan)
        self.pan = pan

        // 长按 is now one cell only: 边角's 重启, wired to a geometry reset.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = pressDelay
        press.allowableMovement = 12
        press.delegate = self
        grip.addGestureRecognizer(press)
        self.press = press

        // 0.0.40 — one tap on a side band docks the card. It used to be a double
        // tap on 边中 that minimised, which meant aiming twice at a band and then
        // finding the way back behind the same band again.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDockTap(_:)))
        tap.delegate = self
        grip.addGestureRecognizer(tap)
        self.tap = tap
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let grip = grip else { return true }
        let zone = zoneFor(cardPoint(gesture.location(in: grip)))
        if gesture === tap {
            return zone == .left || zone == .right
        }
        if gesture === pan {
            // 0.0.99 — 两侧轻滑不许开 pan。
            //
            // 用户定档「两侧：点击停靠，长按拖拽移动」——轻滑既不停靠也不移动。
            // 若让 pan 在闸门没开时也起来，`UIPanGestureRecognizer` 一开始就会把
            // 同一次触摸从 tap 那里抢走（识别器之间是排他的），于是「点一下停靠」
            // 会一起失效。让 pan 在闸门关着时不开，tap 才有机会赢。
            //
            // 「按住 0.25 秒再拖」不受影响：那时闸门已经打开，pan 才起步。
            if zone == .left || zone == .right {
                return gateOpen
            }
            // 0.1.0 — 底排两侧那两格只有长按，没有拖动。
            //
            // 它们的动作（恢复默认尺寸 / 切横屏）都是「按一下」，格子本身不该
            // 能被拖走：一拖就等于借这两个格子移动卡片。让 pan 在这里也要求
            // 闸门，长按才有机会先成立。
            if zone.isBottomSide {
                return gateOpen
            }
            return true
        }
        if gesture === press {
            // 0.1.0 — 长按现在有四种意思，四格都需要它：
            //   底右内 = 恢复默认尺寸（0.0.39 起的「重启」；0.1.0 从右下角搬过来）
            //   两侧   = 打开移动闸门（轻滑不移动，按住拖才移动）
            //   底中   = 打开关闭闸门（轻滑只是移动，按住后上滑才关）
            //   底左内 = 切横屏（V4，本版只记日志）
            // 角格不再收长按：它整格都是「裸滑即缩放」，按住不动的时候用户想做的
            // 是缩放而不是复位，抢过来只会让缩放变得小心翼翼。
            return zone == .bottomRightSide || zone == .bottomMiddle
                || zone == .bottomLeftSide
                || zone == .left || zone == .right
        }
        return true
    }

    /// 0.0.99 — 长按与拖动必须能同时活着。
    ///
    /// 五格里的「两侧：按住 0.25 秒之后拖才移动」要求长按先成立、拖动后接上。
    /// UIKit 默认的排他规则会让先成立的那个把另一个判负，于是「按住再拖」永远
    /// 拖不动 —— 长按赢了，pan 已经失败。`allowableMovement = 12` 保证轻滑的
    /// 长按一定失败（手指动了 >12 pt），所以放开并行不会让轻滑也开闸。
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair = (gesture === press && other === pan) || (gesture === pan && other === press)
        return pair
    }

    /// 0.0.48 — 手势逻辑从识别器里拆了出来：同一段代码现在有两个入口。
    ///
    ///   1. `GripView` 上的 UIPanGestureRecognizer（原来的路，留着当兜底）
    ///   2. `-[UIApplication sendEvent:]` 送来的原始触摸（见 `rawTouch`）
    ///
    /// 两条路互斥：原始触摸在应用层被吞掉时，UIKit 根本不会把它分发给任何视图，
    /// 识别器也就不会响。所以两个入口共用 `zone` / `resizeStart` 这一份状态没有
    /// 二义 —— 同一次触摸只可能由其中一条跑完。
    private func dragBegin(at start: CGPoint) {
        guard let card = card else { return }
        zone = zoneFor(start)
        panStep = .zero
        // 0.0.99 — 闸门不在这里归零：长按有可能比这一拍晚成立。清点在
        // `dragEnd` / `rawTouch` 的抬起那一拍（`gateReset`）。
        // Which band the finger found. If the operator reports "it does not
        // work" again, this line says whether the touch arrived and which
        // zone it was counted as — two very different defects.
        Log.write("win: gesture grab zone=" + name(zone)
                  + " at " + point(start))
        // 0.0.43 — a corner drag resizes; every other band moves. The anchor is
        // the opposite corner, read once here: a zone is which cell the finger
        // landed in, not a thing that changes mid-drag.
        if zone.isCorner {
            resizeStart = card.frame
            // 0.0.69 — 锚点由格子决定，不再由手指落在卡片中线哪一侧推出来：
            // 左下角拖 = 右上角不动，右下角拖 = 左上角不动。
            resizeFromLeft = zone == .bottomLeft
            logResize()
        } else {
            resizeStart = nil
        }
    }

    /// 0.0.65 — 一行说清这次缩放用的是哪块画布。0.0.64 的 `mode=` 撤了：
    /// 现在只有一种缩放（等比例），模式这个量不存在了。
    private func logResize() {
        guard let card = card else { return }
        Log.write(String(format: "win: resize canvas=%.0fx%.0f card=%.0fx%.0f corner=%.0f",
                         natural.width, natural.height,
                         card.bounds.width, card.bounds.height,
                         card.layer.cornerRadius))
    }

    /// `total` is the finger's travel since it landed, in the window's space —
    /// never in the card's or the ring's, because both are being moved and
    /// resized by this very gesture and their rulers stretch.
    private func dragMove(total: CGPoint, velocity: CGPoint) {
        guard let card = card, let window = window else { return }
        let dx = total.x - panStep.x
        let dy = total.y - panStep.y
        panStep = total
        if zone.isCorner, let start = resizeStart {
            // 边角拖动 = 等比例缩放（0.0.43 起；0.0.65 起只剩这一种）。
            //
            // 0.0.63/0.0.64 在这里分过两条路：宽度跟手指（改窗口比例、抬手换画布
            // 让 App 重排）与宽度由高度推出来（普通缩放）。Aevon(57) 判了第一条
            // 没用，于是这里只留下一条：**宽度永远由高度和按下时的形状决定**，
            // 画布（scene 的 settings.frame）在整场缩放里不动。
            //
            // 这也是最省的一条：App 从头到尾不知道窗口变过，没有一次重排，
            // 画面只是被 transform 放大缩小 —— 拖动是真跟手。
            let shortest = miniHeight(in: window.bounds)
            let tallest = window.bounds.height - margin * 2
            let widest = window.bounds.width - margin * 2
            var h = Swift.min(tallest, Swift.max(shortest, start.height + total.y))
            let ratio = start.width / Swift.max(start.height, 1)
            var w = h * ratio
            // 顶到左右边界时反解高度，形状不变 —— 宽度先到就先停，不是把卡片
            // 压成另一条比例。
            if w > widest {
                w = widest
                h = Swift.max(shortest, w / ratio)
            }
            var frame: CGRect
            if resizeFromLeft {
                frame = CGRect(x: start.maxX - w, y: start.minY,
                               width: w, height: h)
            } else {
                frame = CGRect(x: start.minX, y: start.minY,
                               width: w, height: h)
            }
            // 0.0.67 — 缩放这一路**不夹**，也不再每帧重算圆角。
            //
            // 夹这一下就是 Aevon(58) 的「抖动」：`clamped` 的底部预留量取决于
            // **高度**（`under = frame.height + reach*2 <= bounds.height ? reach : 0`），
            // 高度是这一手势正在改的量，于是卡片一涨、`maxY` 一落，y 被往上顶；
            // 手一松或者往下拖，高度回落、y 又被放回来 —— 卡片自己在跳。
            // 缩放的分支里 x/y 本来就是常量（锚点是对角），唯一会动的只有宽高，
            // 而宽高在上面已经被 `widest` / `tallest` 挡住了，没有出界的可能。
            //
            // 圆角同理：拖大拖小时 `side = min(w, h)` 每帧都变，`cornerRadius`
            // 每帧都写一次等于每帧重建一次裁剪路径，而卡片底下是远程 scene 层 ——
            // 观感就是边缘在抖。拖动中不动圆角，抬手时一次算准（`dragEnd`）。
            card.frame = frame
            followContent(updateCorner: false)
            syncGrip()
        } else {
            // All four cells move. 0.0.40 removed the two that resized, so a
            // drag on the band is a drag on the band, wherever it started;
            // 0.0.43 gave the corners their own meaning back, so a drag on
            // a corner is a resize and this branch is the other three.
            //
            // 0.0.99 — 两侧要长按闸门。用户原话「两侧红色为点击停靠，长按拖拽
            // 移动」：轻滑不移动，只有按住 0.25 秒之后才跟手。顶部与底部中间不要
            // 闸门（底部中间是「轻滑为移动悬浮窗」）。
            //
            // 闸门关着时**不移动，但 `panStep` 照旧推进**（上面那三行已经做了）：
            // 它记的是「手指上一拍在哪」，所以长按成立之后的第一帧位移只有手指
            // 那一帧真正走过的距离，卡片不会瞬移半个屏幕。
            if (zone == .left || zone == .right) && !gateOpen {
                return
            }
            // 0.0.99 — 底中长按之后的那一段是「关闭手势」，不是移动。
            // 不挡住的话，按住 0.25 秒再上滑会一边把卡片往上拖一边关掉。
            if zone == .bottomMiddle && gateOpen {
                return
            }
            // 0.1.0 — 底排两侧那两格只有长按，没有拖动。它们分别代表「切横屏」
            // 与「恢复默认尺寸」，是按钮不是把手：手指在那里划过不该让卡片跟着飞。
            if zone.isBottomSide {
                return
            }
            // 0.1.5 — 顶部不是把手（Aevon(93) 第 1 条）。这里是识别器那条兜底路
            // 的闸：`rawTouch` 已经不再认领 `.top`，但 `GripView` 上的
            // UIPanGestureRecognizer 仍然可能在卡片外那一条上成立 —— 两条路必须
            // 给同一个答案，否则「原始触摸关了、识别器还在搬窗口」。
            if zone == .top {
                return
            }
            var frame = card.frame
            frame.origin.x += dx
            frame.origin.y += dy
            card.frame = clamped(frame, in: window.bounds)
            syncGrip()
        }
    }

    private func dragEnd(total: CGPoint, velocity: CGPoint) {
        guard let card = card, let window = window else { return }
        // 0.0.99 — 两侧轻滑：闸门没开就什么都没发生。不做 `remember`，也不写
        // 「moved」—— 那张卡片根本一动没动，写一行只会让下一份日志看起来像
        // 「移动了但没生效」。
        if (zone == .left || zone == .right) && !gateOpen && miniFrame == nil {
            gateReset()
            return
        }
        // 0.1.0 — 底排两侧：只有长按，拖动不产生任何结果。闸门（= 长按成立）
        // 并不是这里的放行条件 —— 就算长按成立了，那两格的动作用长按本身已经
        // 做完了（复位 / 待落的横屏），抬手这一拍不该再叠一次移动。
        if zone.isBottomSide {
            gateReset()
            return
        }
        // 0.1.5 — 顶部不是把手：这一拍什么都没发生，不该写 `card moved to`，
        // 更不该把「桌上原来的位置」覆盖成记忆（Aevon(93) 里 5 次误拖就是这么
        // 把位置改掉的）。
        if zone == .top {
            gateReset()
            return
        }
        if miniFrame != nil { return }
        if zone.isCorner, resizeStart != nil {
            resizeStart = nil
            // 画布不动，也就没有重排要付：只把画面按新尺寸摆正、把圆角按新
            // 宽度重算一次（圆角跟着卡宽，不跟着卡高）。
            followContent()
            syncGrip()
            Log.write("win: card resized to " + point(card.frame.origin)
                      + " size=" + size(card.bounds.size))
            logResize()
            remember(in: window.bounds)
            return
        }
        if zone == .bottomMiddle {
            // 0.0.99 — 关闭要「先按住 0.25 秒」。
            //
            // Aevon(87) 之前的规则是「快速上滑就关」，而用户的原话是「现在的
            // 上滑关闭容易误触」。五格图里底中是两件事：轻滑 = 移动，长按 0.25 秒
            // 之后上滑 = 关闭。闸门就是这两件事的分界，没有第二套判据。
            let lift = -total.y
            let up = -velocity.y
            let byTravel = lift > 50 && abs(total.y) > abs(total.x)
            let bySpeed = up > flick && up > abs(velocity.x)
            if gateOpen, byTravel || bySpeed {
                Log.write("win: gesture edge-middle flick up=" + String(Int(up))
                          + " dy=" + String(Int(total.y)) + " -> close")
                requestClose("edge swipe up")
                return
            }
            Log.write(String(format: "win: gesture edge-middle not a close up=%d vx=%d dy=%d gate=%d",
                             Int(up), Int(velocity.x), Int(total.y), gateOpen ? 1 : 0))

            // 底中轻滑只是移动：这一格不 dock、不 close，落在这里就是「移动」，
            // 由下面的 `remember` 收尾。
        }
        gateReset()
        Log.write("win: card moved to " + point(card.frame.origin)
                  + " size=" + size(card.bounds.size))
        remember(in: window.bounds)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let grip = grip else { return }
        switch gesture.state {
        case .began:
            dragBegin(at: cardPoint(gesture.location(in: grip)))
        case .changed:
            // `nil` = 本手势所在窗口的坐标系。两层都是全屏、原点重合，而 band
            // 那一层在整个拖动过程中不动，是唯一稳定的尺子。
            dragMove(total: gesture.translation(in: nil), velocity: gesture.velocity(in: nil))
        case .ended, .cancelled:
            dragEnd(total: gesture.translation(in: nil), velocity: gesture.velocity(in: nil))
        default:
            break
        }
    }


    /// 边角长按 = 重启 (母本文案「边角区域滑动缩放, 长按重启」). Since 0.0.39 the
    /// plan reads the remembered placement, so resetting the frame alone would
    /// restore the very numbers the operator wanted gone — the remembered
    /// placement has to go first, or "restart" is a no-op.
    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let window = window, let grip = grip else { return }
        switch gesture.state {
        case .began:
            // 0.1.0 — 五格里的长按有四种意思，各占一格：
            //   底右内 = 恢复默认尺寸（0.0.39 起的「重启」，先清记忆再复位）
            //   两侧   = 开移动闸门
            //   底中   = 开关闭闸门
            //   底左内 = 切横屏（V4，本版只记日志，不动界面）
            // 两个角**不收**长按：角格整格是「一碰就缩放」，按住不动时用户想做的
            // 还是缩放，把复位抢过来只会让缩放变得小心翼翼。
            //
            // 这里**重新算一次格子**，不读 `zone`：两侧的 pan 在闸门关着时根本
            // 不会开始（见 `gestureRecognizerShouldBegin`），`dragBegin` 也就没跑，
            // `zone` 会一直是上一次那个。长按是第一现场，格子从这里读最可靠。
            let here = zoneFor(cardPoint(gesture.location(in: grip)))
            if here == .bottomRightSide {
                // A press that becomes a drag must not also drag the card.
                pan?.isEnabled = false
                if resetToPlan(in: window.bounds) {
                    Log.write("win: gesture long press bottom-right-side, 重启 as geometry reset")
                } else {
                    // 已经是默认尺寸时 `resetToPlan` 回 false。写一行是因为「长按
                    // 到底有没有被收到」和「收到了但没什么可复位」是两件事。
                    Log.write("win: gesture long press bottom-right-side, already default")
                }
                return
            }
            if here == .bottomLeftSide {
                // V4 的位子。本版只确认「这一格的长按收到了」—— 真去改
                // `interfaceOrientation` 是单独一版的事，不跟手势混在一起。
                Log.write("win: gesture long press bottom-left-side, 横屏 not wired yet")
                return
            }
            if here.isCorner {
                Log.write("win: gesture long press on corner, scaling is a drag here")
                return
            }
            guard here == .left || here == .right || here == .bottomMiddle else { return }
            gateOpenNow(true)
            Log.write("win: gesture gate open zone=" + name(here))
        case .ended, .cancelled, .failed:
            pan?.isEnabled = true
            // 0.0.99 — **不在这里清闸门**。
            //
            // 抬手那一拍，长按与拖动谁先收到 `ended` 是不确定的；清早了
            // `dragEnd` 就会看到「闸门关着」，于是「按住拖」的落点不被记住、
            // 「按住后上滑」也不关。闸门只由 `dragEnd` 与原始触摸的抬起清。
        default:
            break
        }
    }

    /// 吸附 — one tap on a side band. Docked is `miniFrame != nil`, and that is
    /// the only thing that says so: a second flag would be a second answer.
    @objc private func handleDockTap(_ gesture: UITapGestureRecognizer) {
        guard let grip = grip else { return }
        dock(zone: zoneFor(cardPoint(gesture.location(in: grip))))
    }

    /// 0.0.48 — the body of the tap, callable without a recognizer: the raw
    /// touch path lands here too, because a tap is a touch that never moved.
    private func dock(zone landed: Zone) {
        guard landed == .left || landed == .right else { return }
        // `window` 不再在这里读：几何全部搬进 `applyMini` 了。留着这个判断是为了
        // 「没有窗口就没有卡片」这条早退语义不变 —— 少了它，`undock` 会拿到半死状态。
        guard card != nil, window != nil else { return }
        if miniFrame != nil {
            undock()
            return
        }
        guard natural.height > 16 else { return }
        let side: CardLayout.Edge = landed == .left ? .left : .right
        // `manual: true` —— 手指点的就是这一侧，落点跟着手指走。
        applyMini(side: side, manual: true)
    }

    /// 0.0.98 — 缩成停靠小窗，几何只有这一份。
    ///
    /// `dock(zone:)`（手指点边）与 `dockAsMini()`（被新主窗挤下去）是两种触发，
    /// 但落点必须一模一样：尺寸公式分叉过一次就会变成「点着停靠和自动停靠长得
    /// 不一样」，那种差异没人能一眼看出来是 bug。所以 `side` 由调用方给，几何
    /// 全在这里。
    ///
    /// 0.0.45 — 贴边缩小，母本自己的说法。高度是唯一的自由量（宽度由画面形状
    /// 推出来），卡片贴齐它被停靠的那条边 —— 一个离边还有缝的小窗，等于没做到
    /// 「让开」这件事本身。
    /// 0.1.0 — `manual` 决定「这一格落哪一列」。
    ///
    /// 两种触发必须分开，这是 Aevon(88) 日志里一眼能看见的缺陷：`claimDock` 原来
    /// 按「卡片原来更靠近哪条边」优先落列，而**自动降级**的卡片几乎总在主窗默认
    /// 位置（偏左），于是 5 个全部堆到左列：`nth=1 at 0,0`、`nth=2 at 0,280` ——
    /// 右列一个都没用上，而用户定的规则是「右侧 5 个之后从左边顶部继续排」。
    ///
    ///  · `manual = true`（手指点左边条）→ 落被点的那一列，这是「我要放这边」；
    ///  · `manual = false`（被新主窗挤下去）→ 永远从右列开始填，填满才往左。
    private func applyMini(side: CardLayout.Edge, manual: Bool, into column: Bool? = nil) {
        guard let card = card, window != nil else { return }
        // 0.1.7 — 缩之前先把这张主窗的实际几何记下来（升窗的唯一落点来源，
        // 见 `lastMainFrame`）。必须写在 `claimDock` / `relayoutDocked` 之前：
        // 那两步会把 frame 改成小窗的 98x163。
        FloatHost.lastMainFrame = card.frame
        // 展开前的 frame 只记一次：已经停靠过就不再覆盖，否则「取消停靠」会回到
        // 上一次的小窗尺寸，而不是回到大卡片。
        if miniFrame == nil { miniFrame = card.frame }
        // 0.1.3 — `column` 优先：`undock` 要求「被挤下去的那张主窗落在**这一列**
        // 的最后一格」，那条规则不能交给「右列先满」去猜（点左列的窗却排到右列，
        // 就是两列开始互相借位）。
        //
        // 0.1.26 — 从「落位」到「其余各格补位」是一件事，必须落在同一个 spring 里。
        // 原来 `relayoutDocked()` 是无动画版：这一张缩成小窗有过渡，后面四张
        // 补位却是瞬移，两者叠在同一拍里，用户看到的就是「1 的画面直接变成 2」。
        let prefer: Bool? = column
        AevonMotion.spring {
            FloatHost.claimDock(self, preferLeft: prefer ?? (manual && side == .left))
            FloatHost.relayoutDocked(animated: true)
            // 0.1.4 — 变小的这一瞬降到小窗档，否则它会继续压在主窗上面（见 `mainLevel`）。
            self.applyWindowLevel()
        }
        let landed = card.frame
        let column = FloatHost.columnIndex(self)
        Log.write(String(format: "win: card docked %.0fx%.0f at %.0f,%.0f nth=%d col=%@ row=%d",
                         landed.width, landed.height,
                         landed.origin.x, landed.origin.y,
                         FloatHost.dockCount,
                         column?.right == true ? "R" : "L",
                         (column?.row ?? -1) + 1))
    }

    /// 停靠表里现在有几个。
    static var dockCount: Int { dockRight.count + dockLeft.count }

    /// 被新主窗挤下去：缩成小窗，进「右列先满、再左列」那条队列。
    /// 返回落到的边名，给 `win: demote` 那行日志用。
    private func dockAsMini(into column: Bool? = nil) -> String {
        guard let card = card, let window = window, natural.height > 16 else { return "none" }
        if miniFrame != nil { return "already" }
        // `manual: false` —— 这是系统替用户做的决定，落哪一列由队列算，不由卡片
        // 原来漂在哪半边算（Aevon(88) 里 5 个全堆左列就是这条的锅）。
        applyMini(side: card.frame.midX < window.bounds.width / 2 ? .left : .right,
                  manual: false, into: column)
        // 落点由排列表决定，不由「原来靠哪边」决定 —— 所以名字要等摆完之后再读。
        let name = FloatHost.columnIndex(self)?.right == false ? "left" : "right"
        Log.write(String(format: "win: card demoted side=%@ %@ at %@",
                         name, size(card.bounds.size), point(card.frame.origin)))
        return name
    }

    // MARK: - 应用层触摸（0.0.48）

    /// 0.0.67 — 同一条事件只处理一次。
    ///
    /// Aevon(58) 的日志里每一拍都是成对的：`ring: bar raw down … #1` 紧跟
    /// `#2`（同一个坐标），`win: touch seen at 347,792` 两行一模一样，
    /// `win: gesture grab zone=…` 也一样。也就是说 `-[UIApplication sendEvent:]`
    /// 这一条事件被投递了两次，而两次都进了我们的入口 —— `dragBegin` 被调两遍
    /// （`resizeStart` 被重设）、`barTouch` 的计数被加两次。
    ///
    /// 为什么这版才显形不重要，能不能挡住才重要：`UITouch.timestamp` 对同一条
    /// 事件是同一个数，对不同事件不同。同相位 + 同时间戳 = 同一条事件，直接
    /// 回上一次的答案（被吞的继续被吞，没吞的继续不吞）。
    ///
    /// 顺带修掉的是圆盘：`summon bar` 的按下计数一直是双倍，选中判定也跟着
    /// 走两遍。
    private var lastTouchStamp: TimeInterval = 0
    private var lastTouchPhase = -1
    private var lastTouchEaten = false

    func touchEntry(phase: Int, at screen: CGPoint, stamp: TimeInterval) -> Bool {
        if stamp > 0, stamp == lastTouchStamp, phase == lastTouchPhase {
            return lastTouchEaten
        }
        lastTouchStamp = stamp
        lastTouchPhase = phase
        let eaten = rawTouch(phase: phase, at: screen, stamp: stamp)
        lastTouchEaten = eaten
        FloatHost.touchIn += 1
        if eaten { FloatHost.touchEaten += 1 }
        // 0.0.92 — 每秒结算一行：「手指进来了多少、被我们吞掉了多少」。
        //
        // Aevon(82) 的卡屏（页面滑不动、点不动）只有两种可能：要么我们吞了触摸，
        // 要么 App 自己不吃。原来的 `win: touch seen` 只记前 12 条按下事件，
        // 之后一片空白 —— 分不出这两种。这一行把两个数放在一起：
        //   `in=8 eat=0` ⇒ 手指进来了、我们一条都没吞 ⇒ 问题在 App 侧（或场景）；
        //   `in=8 eat=7` ⇒ 是我们吞的，接下来只要看 zone 就够了。
        FloatHost.settleTouchCounter(at: stamp)
        return eaten
    }

    /// 每秒一次。`stamp` 是 `UITouch.timestamp`（系统时钟），和日志时间轴同源，
    /// 所以不用再取一次 Date —— 两次取时间在这条路径上是白花。
    private static func settleTouchCounter(at stamp: TimeInterval) {
        if touchAt == 0 { touchAt = stamp; return }
        if stamp - touchAt < 1.0 { return }
        let n = touchIn
        let e = touchEaten
        let md = miniDown
        let me = miniEaten
        let mn = miniNear
        touchIn = 0
        touchEaten = 0
        miniDown = 0
        miniEaten = 0
        miniNear = 0
        touchAt = stamp
        // 没手指、也没吞过：这一秒什么都不用说。
        guard n > 0 || e > 0 else { return }
        // 0.1.3 — 小窗那一侧的单独结算。`down` 与 `eaten` 不等就是漏了一条。
        // 0.1.4 — `near` 是「落在小窗框外 6 pt 容忍带里」的按下数，它不进 `down`
        // （`down` 只数框内）。一直 `down=0 near=N` ⇒ 手指总在框外，容忍带不够；
        // `down=N near=0` 却仍然透传 ⇒ 漏的根本不在这条路上，要去查 `sendEvent`。
        if md > 0 || me > 0 || mn > 0 {
            Log.write(String(format: "win: mini touch down=%d eaten=%d near=%d", md, me, mn))
        }
        // 一整条字面量（不是拼接）：交付前的审计要在二进制里 grep 到它，
        // 相邻字面量拼出来的串在源码里根本搜不到 —— 这个坑记在项目纪律里。
        Log.write(String(format: "win: touch in=%d eat=%d", n, e))
    }

    /// 0.0.92 — 这一秒进来的触摸数 / 被我们吞掉的数（见 `settleTouchCounter`）。
    private static var touchIn = 0
    private static var touchEaten = 0
    /// 0.1.3 — 停靠小窗上「落进矩形」与「被吞掉」的按下数。两个数必须永远相等：
    /// 只要出现 `down > eaten`，就是又有事件被放给 App 了（0.1.1 的 `edge` 例外
    /// 就是靠这个才看得见 —— 那一版的 `mini tap down` 只在吞掉之后才写，漏的
    /// 那些一行日志都没有）。
    private static var miniDown = 0
    private static var miniEaten = 0
    private static var touchAt: TimeInterval = 0

    /// 环上的原始触摸。`phase` 用 UITouchPhase 的数值：0 began / 1 moved /
    /// 3 ended / 4 cancelled。返回 true 表示这条事件被浮窗吃掉。
    ///
    /// 为什么要绕到这一层：Aevon(44)/(45)/(46) 三份日志里，卡片外面**一个触摸
    /// 都没有进过我们的任何窗口** —— `win: event hit` 整场只有 ✕ 那一条，
    /// 0.0.47 独立窗口那版的 `win: band probe` 也只有 ✕ 那一条；而卡片里的 ✕
    /// 一直好用。也就是说「窗口收不收得到触摸」这件事本身不可靠，环的几何从来
    /// 不是瓶颈（0.0.44-0.0.47 都在改几何）。
    ///
    /// `-[UIApplication sendEvent:]` 是唯一一个「不管命中哪个窗口都会经过」的
    /// 入口，所以浮窗的四个边从这里拿手指，不再指望某个窗口被问到。
    func rawTouch(phase: Int, at screen: CGPoint, stamp: TimeInterval) -> Bool {
        // 0.1.6 — 竖条那一次问**搬到 `AevonFloatTouch`**（见文件末尾），不在这里。
        //
        // 0.0.49~0.1.5 它在这是第一句，而唯一的调用方是 `touchEntry` ——
        // `touchEntry` 只能由 `touchOrder` 里的宿主触发。0.1.5 把 `touchOrder`
        // 改成「只收 `window != nil` 的槽」，于是**屏幕上没有卡片时列表是空的**，
        // 这句话一次都不会执行：竖条在应用层的入口整条消失，只剩 `barPad` 上
        // 那两个 UIKit 识别器 —— 而那个入口之所以存在，正是因为识别器在真机上
        // 不可靠（Aevon(47) #3「锁屏一次之后就不容易触发」）。
        //
        // 用户的话：「你把右侧呼出圆盘的手势取消了，呼不出圆盘，无法打开悬浮窗」。
        // 圆盘成了进不去的门，后面四条自然一条都测不了。
        //
        // 搬到调用方之后，它和「屏幕上有没有卡」彻底解耦：卡片一张都没有时也照问。
        guard let card = card, let window = window else {
            // 卡片在手势中途被关掉：这一路已经把 began 吞了，收尾也必须吞，否则
            // UIKit 会收到一根它从没见过的手指的结束事件。
            let was = rawActive
            rawActive = false
            rawPress?.cancel()
            rawPress = nil
            return was
        }
        let frame = card.frame
        let local = CGPoint(x: screen.x - frame.minX, y: screen.y - frame.minY)
        // 0.1.0 — 停靠小窗没有环（Aevon(88) 第 3 条）。
        //
        // 母本对她的贴边小窗用的是 `SingleTapMinimize` 那句话：「单点缩小::贴边
        // 缩小, 不可操作」。不可操作 = 没有手势区。这不只是「小窗用不着手势」：
        // 5 个 112 宽的小窗竖排在左边缘，每个原本带一圈 66 pt 的环，叠起来就是
        // 一整条宽 178 pt 的带子 —— 主窗的左边环被压在下面，`AevonFloatTouch` 按
        // 槽号问、谁先认领谁吞，于是主窗的手势时灵时不灵。拆掉环，那条带子就
        // 不存在了。
        //
        // 收尾仍然必须接住：手指是在这道门之前按下的，抬起也要在这里吞掉。
        //
        // 0.1.1 — 小窗要**吞**触摸，不能放行（Aevon(89) 第 2 条）。
        //
        // 0.1.0 这里直接 `return was`（按下那一刻 `rawActive` 是 false），于是
        // 整根手指原样交给 App：用户点小窗想还原，App 里自己那一块被点到了，
        // 小窗纹丝不动。`shield`（UIControl）本该替我们接住，但它只存在于宿主
        // 窗口里，而宿主窗口对触摸是穿透的 —— 真机上唯一能拦住这条路的就是
        // 这个函数（0.0.47 起 `sendEvent` 就是主通道，`win: touch in=` 就是它的
        // 计数器）。
        //
        // 语义：**落在小窗矩形里的那一下就是「还原」**，吞掉并升主窗；落在小窗
        // 外面（含四周一点点环的余量）什么都不做，原样放行。按下去之后手指移开
        // 超过 12 pt 就不算点按，但仍然吞到底 —— began 已经吞了，半路放手会让
        // UIKit 收到一根它从没见过的结束事件。
        if miniFrame != nil || miniTapEaten {
            // 降级可能发生在拖动中途：上一根手指的主窗状态必须现在清掉，
            // 否则 `rawActive` 会一直悬着 true，之后每一次抬起都以为自己在收尾。
            //
            // 0.1.3 — `|| miniTapEaten`：小窗被点中升回主窗之后 `miniFrame` 立刻
            // 变 nil，而那一根手指可能还有 `cancelled` 没走完。不留这条，它就会
            // 掉进下面主窗那条路 —— App 会收到一根它从没见过的手指的收尾事件
            // （「半根手指」的老毛病）。这里只保证**同一根手指**收完，下一根手指
            // 的第一拍 `miniTouch` 会把 `miniTapEaten` 重新判成 false。
            // 0.1.5 — **没被小窗认领时要能继续走主窗这条路**。
            //
            // 0.1.1~0.1.4 这里直接 `return miniTouch(...)`：只要这张卡停靠着
            // （`miniFrame != nil`），它自己那一侧的环带就**整块失效** ——
            // `miniTouch` 回 false 之后没有再往下判的机会。Aevon(93) 里主窗被
            // 拖到小窗旁边时那一侧拖不动，一半是这个。
            //
            // 现在的语义分三种：
            //   · 小窗认领了（`miniTouch` 回 true）⇒ 吞掉，主窗状态清干净；
            //   · 不是按下（phase ≠ 0）⇒ 上一根手指的余波，`miniTapEaten` 说了算，
            //     绝不掉进主窗那条路（App 会收到一根它从没见过的手指的收尾）；
            //   · 按下但落在小窗外面 ⇒ 这一根手指不是小窗的，清掉标记继续往下走。
            if miniTouch(phase: phase, local: local) {
                rawActive = false
                rawPress?.cancel()
                rawPress = nil
                return true
            }
            if phase != 0 { return miniTapEaten }
            miniTapOn = false
            miniTapEaten = false
            // 0.1.5 — **停靠着就到此为止**：小窗只有「点按升主窗」这一个手势
            // （母本 `SingleTapMinimize` 的「不可操作」）。少了这一行，落在小窗
            // 外面一点点（超出 6 pt 容忍带）的按下会继续掉进主窗那条路，把这张
            // 小窗当成大卡片拖着走 —— `miniFrame` 非 nil 时它自己的环带也是坏的。
            if miniFrame != nil { return false }
        }
        switch phase {
        case 0:
            if rawSeen < 12 {
                rawSeen += 1
                Log.write("win: touch seen at " + point(screen)
                          + " card=" + point(frame.origin))
            }
            // 系统手势的地盘不抢：屏幕最下面 12 pt 是 home 条，最上面 10 pt 是
            // 状态栏下拉。环是圆的，少这一条边不影响任何人伸手。
            guard screen.y < window.bounds.maxY - 12,
                  screen.y > 10 else { return false }
            // 竖条的地盘也不抢：卡片开着的时候换 App 的路不能被我自己的环堵死。
            guard !AevonRingGrip.summonRect.contains(screen) else { return false }
            guard ringHolds(local, size: card.bounds.size) else { return false }
            // 0.1.5 — **顶部那一条不再是把手**（Aevon(93) 第 1 条）。
            //
            // `zoneFor` 把 `y < 0` 判成 `.top`，而 `dragMove` 的非缩放分支对
            // `.top` 没有闸门 ⇒ 卡片上方那一条环带是「轻滑就跟着走」。Aevon(93)
            // 里它被认领 16 次、真的把卡片拖走 5 次（`zone=top at 341,-37`
            // → `card moved to 36,188`）：用户从卡片顶边往上滑想滚内容，
            // 滑到卡片外面那一下就变成「搬窗口」。
            //
            // 五格图里没有顶部这一格：移动是两侧（长按 0.25 s）和底中（轻滑）。
            // 顶部留着**只让系统手势过**（状态栏下拉），我们自己一格都不认。
            if zoneFor(local) == .top {
                if rawTopIgnored < 8 {
                    rawTopIgnored += 1
                    Log.write("win: zone top ignored at " + point(local))
                }
                return false
            }
            rawActive = true
            rawStart = screen
            rawLast = screen
            rawMoved = false
            rawStamp = stamp
            rawVelocity = .zero
            // 0.0.99 — 新的一次触摸，闸门先关上（上一条的手指可能没走完收尾）。
            gateReset()
            dragBegin(at: local)
            if rawProbe < 20 {
                rawProbe += 1
                Log.write("win: raw touch grab zone=" + name(zone)
                          + " at " + point(local))
            }
            // 0.0.99 — 长按在这一条路上也得有，因为事件根本没进 UIKit：底中
            // 「按住 0.25 秒才允许关闭」与两侧「按住才允许移动」都要自己计时。
            // 0.1.0 — 底排两侧那两格也归长按管（复位 / 待落的横屏）。
            if zone == .bottomRightSide || zone == .bottomLeftSide
                || zone == .bottomMiddle
                || zone == .left || zone == .right {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.rawPressFired()
                }
                rawPress = work
                DispatchQueue.main.asyncAfter(deadline: .now() + pressDelay, execute: work)
            }
            return true
        case 1:
            guard rawActive else { return false }
            let total = CGPoint(x: screen.x - rawStart.x, y: screen.y - rawStart.y)
            if !rawMoved, abs(total.x) + abs(total.y) > 6 {
                rawMoved = true
                rawPress?.cancel()
                rawPress = nil
            }
            let dt = Swift.max(stamp - rawStamp, 0.008)
            rawVelocity = CGPoint(x: (screen.x - rawLast.x) / CGFloat(dt),
                                  y: (screen.y - rawLast.y) / CGFloat(dt))
            rawLast = screen
            rawStamp = stamp
            if rawMoved { dragMove(total: total, velocity: rawVelocity) }
            return true
        case 3, 4:
            guard rawActive else { return false }
            rawActive = false
            rawPress?.cancel()
            rawPress = nil
            if phase == 4 {
                Log.write("win: raw touch cancelled by the system")
                return true
            }
            let total = CGPoint(x: screen.x - rawStart.x, y: screen.y - rawStart.y)
            if rawMoved {
                dragEnd(total: total, velocity: rawVelocity)
            } else if zone == .left || zone == .right {
                dock(zone: zone)
            }
            return true
        default:
            return rawActive
        }
    }

    private func rawPressFired() {
        guard rawActive, !rawMoved, let window = window else { return }
        // 0.1.0 — 「恢复默认尺寸」从右下角搬到它内侧那一格（Aevon(88) 第 2 条）。
        // 角格现在整格是裸滑缩放，长按在那里什么都不做。
        if zone == .bottomRightSide {
            // 0.0.69 — 只有真的动了才写这一行。已经是默认尺寸时 `resetToPlan` 回
            // false，日志里就只剩它自己那句 `already default`。
            if resetToPlan(in: window.bounds) {
                Log.write("win: raw long press bottom-right-side, 重启 as geometry reset")
            } else {
                Log.write("win: raw long press bottom-right-side, already default")
            }
            return
        }
        if zone == .bottomLeftSide {
            Log.write("win: raw long press bottom-left-side, 横屏 not wired yet")
            return
        }
        // 0.0.99 — 两侧与底中：长按成立 = 开闸门。手指还在屏幕上，接下来的移动
        // 或上滑才有意义。
        guard zone == .left || zone == .right || zone == .bottomMiddle else { return }
        gateOpenNow(true)
        Log.write("win: raw gesture gate open zone=" + name(zone))
    }

    // MARK: - 0.1.1 停靠小窗的点按

    /// 停靠小窗上这一下算不算「还原」。见 `rawTouch` 里那道门的注释。
    ///
    /// 两个标记缺一不可：
    ///   · `miniTapOn` = 「这还算一次点击」，位移超了就不算；
    ///   · `miniTapEaten` = 「这一根手指已经被我们吃掉了」，一次认领就一直有效。
    ///
    /// 只用前者会出事：手指滑一下就变成 false，于是**同一根手指的后半段回给
    /// App** —— App 从没见过 `began`，收到的是半根手指。后者才是「吞到底」。
    private var miniTapOn = false
    private var miniTapEaten = false
    private var miniTapStart: CGPoint = .zero
    /// 0.1.3 — `mini tap down` 只写前 12 条（Aevon(91) 一次会话点了 20 多次，
    /// 每条都写会把日志埋掉），之后靠每秒那一行计数继续作证。
    private var miniLogs = 0
    /// 0.1.4 — `mini miss` 的日志预算，与 `miniLogs` 分开：一种是正常的认领，
    /// 一种是漏网，混用一个预算会让其中一种把另一种挤掉。
    private var miniMissLogs = 0

    /// 0.1.4 — 小窗边缘的「手滑」容忍带（pt）。
    ///
    /// Aevon(92) 里 `down` 与 `eaten` **每一行都相等**（1/1、2/2、4/4…），可用户
    /// 第三次报「透传还在」。两个数相等的唯一解释是：漏掉的那些根本没进
    /// `miniTouch` 的 `inside` 那一支 —— 它们连 `miniDown` 都没加。
    ///
    /// 小窗只有 98x163，又贴着屏幕边缘，手指中心落在边界外 1~2 pt 是很常见的。
    /// 一旦 `began` 被判成「窗外」，后面 `moved` / `ended` 全都放行 ⇒ App 收到
    /// **一整次完整点击**，而我们两条计数都不动，日志上完全看不见。
    ///
    /// 6 pt：半个指腹的余量，比屏幕最外那 12 pt 系统手势区小一半，不足以把
    /// 小窗旁边的桌面图标也吃进来。
    private static let miniSlop: CGFloat = 6
    /// 落进容忍带（窗外但很近）的按下数 —— 与 `miniDown` 分开记，因为它的
    /// 「算不算一次点按」的语义相同、但位置不在小窗里，下次要看的是它的量。
    private static var miniNear = 0

    /// 这张卡现在是不是停靠小窗。给多指那条窄入口用（`AevonFloatTouchMini`）。
    var onMini: Bool { miniFrame != nil && window != nil }

    /// 屏幕坐标是不是落在这一张小窗里（含 `miniSlop` 容忍带）。
    ///
    /// 和 `rawTouch` 里那段 `screen - card.frame.origin` 是同一个算法 —— 两处必须
    /// 一致，否则「多指入口认领的」与「单指入口认领的」会变成两个不同的矩形。
    func miniHit(_ screen: CGPoint) -> Bool {
        guard miniFrame != nil, let card = card else { return false }
        let local = CGPoint(x: screen.x - card.frame.minX, y: screen.y - card.frame.minY)
        return card.bounds.insetBy(dx: -FloatHost.miniSlop, dy: -FloatHost.miniSlop)
            .contains(local)
    }

    /// 卡片坐标系里的 `local`（`rawTouch` 已减掉 frame 原点）。
    private func miniTouch(phase: Int, local: CGPoint) -> Bool {
        let inside = card.map { $0.bounds.contains(local) } ?? false
        // 0.1.4 — 窗外 6 pt 也算「小窗这一下」（见 `miniSlop`）。
        let near = card.map {
            $0.bounds.insetBy(dx: -FloatHost.miniSlop, dy: -FloatHost.miniSlop).contains(local)
        } ?? false
        switch phase {
        case 0:
            // 每一根新手指都重新判一次：上一根留下的 `miniTapEaten` 不能带过来，
            // 否则手指落在小窗**外面**也会被当成「已经认领」，之后它的移动全被吃。
            miniTapOn = false
            miniTapEaten = false
            // 0.1.5 — **已经升回主窗的卡不再认领。**
            //
            // `miniTapEaten` 从现在起要活到下一根手指（见 case 3），而升窗之后
            // `card.bounds` 已经是那张 347×578 的大卡片 —— 少了这道门，下一根
            // 手指按在主窗里就会被 `inside` 判成「点在小窗上」，整块主窗的触摸
            // 全被吃掉。停靠状态是这一支唯一的入场券。
            guard miniFrame != nil else { return false }
            // 手指在小窗外面：不认领，原样放行（屏幕别处该干嘛干嘛）。
            // 0.1.4 — 但「外面一点点」要认领：`miniSlop` 那 6 pt 不是装饰，
            // 它是 Aevon(92) 里「透传还在、可 down 与 eaten 却全相等」的唯一出口。
            guard inside || near else {
                // 落在附近（24 pt 内）却没被认领的按下，前 12 条写出来。这一行
                // 就是下次判「是不是又从这里漏了」的证据 —— 远处那些正常放行
                // 的不写，否则日志会被桌面的点击灌满。
                if miniMissLogs < 12,
                   card.map({ $0.bounds.insetBy(dx: -24, dy: -24).contains(local) }) == true {
                    miniMissLogs += 1
                    Log.write("win: mini miss at " + point(local))
                }
                return false
            }
            // 0.1.3 — **小窗矩形以内，一条都不放行**（Aevon(91) 第 1 条）。
            //
            // 0.1.1 在这里留了两条例外：小窗贴着屏幕左边时最外 12 pt 放行、贴着
            // 右边时最右 12 pt 放行，理由是「左边缘右滑返回」。但那两条的代价是
            // 一条**完整的点击**被交给 App（began 没吞咽 ⇒ moved/ended 也全放行），
            // 用户看到的是「点小窗，App 里被点了一下」。日志里 `mini tap down` 只
            // 在吞掉之后才写，所以漏掉的那些**一行都没有** —— `in=12 eat=11`
            // 那一条就是唯一的痕迹。
            //
            // 用户定档：「整个小窗页面都关闭任何触摸（点击、上下滑动、左右滑动），
            // 但是恢复成主悬浮窗时必须立刻还原触摸」。所以例外全撤：屏幕最左那条
            // 12 pt 也不再让给「返回」，代价是左列有小窗的那一段高度划不出返回 ——
            // 没有小窗的竖直位置照旧可以划。
            miniTapOn = true
            miniTapEaten = true
            miniTapStart = local
            FloatHost.miniDown += 1
            FloatHost.miniEaten += 1
            if !inside { FloatHost.miniNear += 1 }
            if miniLogs < 12 {
                miniLogs += 1
                Log.write("win: mini tap down at " + point(local))
            }
            return true
        case 1:
            guard miniTapEaten else { return false }
            // 位移按卡片坐标算即可：小窗不跟手移动，坐标系不会变。
            let dx = local.x - miniTapStart.x
            let dy = local.y - miniTapStart.y
            if abs(dx) + abs(dy) > 12 { miniTapOn = false }
            // 已经吞了按下，移动也必须吞。
            return true
        case 3:
            let claimed = miniTapOn
            let eaten = miniTapEaten
            miniTapOn = false
            // 0.1.5 — **这里不再清 `miniTapEaten`**。
            //
            // 0.1.3/0.1.4 在抬手那一拍把它清成 false，而 `undock` 又把
            // `miniFrame` 清成 nil —— 于是这一根手指余下的任何一拍（UIKit 在
            // ended 之后还会补 `stationary`，或者取消路径晚到）都会掉进主窗
            // 那条路、`rawActive` 又是 false、于是**原样放行给 App**。
            // 那正是用户三次报的「点小窗还原成主窗时，App 里被点了一下」。
            //
            // 标记只在下一根手指的 `case 0` 清零（那里会重新判定），一次认领
            // 就一直吃到这根手指彻底走完。
            // 认领过的手指，抬起一律吞掉（哪怕中途滑出了小窗）。
            guard eaten else { return false }
            guard claimed else { return true }
            // 抬手才升窗：按下就升会让「按住不放」变成一次立刻发生的布局重排。
            Log.write("win: mini tap up, promoting back to main")
            undock()
            return true
        case 4:
            // 0.1.5 — 与 `case 3` 同理：取消也不清标记，留给下一根手指的
            // `case 0` 重新判定。清在这里等于把余下的收尾放给 App。
            return miniTapEaten
        default:
            // 2 = 静止。这一拍什么都不该发生，也什么都不能改。
            return miniTapEaten
        }
    }

    /// 手指是否落在环上：卡片之外，且离卡片边缘不超过 `reach`。卡片坐标系，
    /// 和 `zoneFor` / `cardPoint` 用的是同一个。
    private func ringHolds(_ local: CGPoint, size: CGSize) -> Bool {
        let outside = local.x < 0 || local.y < 0
            || local.x > size.width || local.y > size.height
        guard outside else { return false }
        return local.x >= -reach && local.x <= size.width + reach
            && local.y >= -reach && local.y <= size.height + reach
    }

    // MARK: - 冷启动封面

    /// 冷启动的 App 要几百毫秒才画得出第一帧，这段空窗里卡片是透明的，
    /// 露出来的是窗口后面的黑。母本的办法不是等，是先放一个封面上去。
    ///
    /// 第一帧到了（或三秒超时）：把卡片露出来。
    ///
    /// 0.0.58 —— 这一步以前叫 `revealCover`，作用是撤掉一层图标板。现在没有
    /// 板要撤：卡片自己从 alpha 0 上来，所以只有「什么时候」还有意义。
    ///
    /// 淡入而不是直接置 1。画面自己浮现像系统在放大图标；卡片弹出来像被塞了
    /// 一个窗口 —— 同一个 0.16 秒，两种观感。
    ///
    /// 0.0.59 —— 「闪」这一条修在这里。
    ///
    /// 0.0.58 的 0.16 秒淡入是**没有前提**的：它跟着保活时钟（稳态 200 ms 一拍）
    /// 判断 `contentState == 2`，而那是「scene 认为有内容」，比「这一帧真的上了
    /// 屏」早。于是淡入的前半段画面还是黑的，后半段画面才来 —— 一次渐变里夹着
    /// 一次跳变，眼睛看到的就是闪。
    ///
    /// 现在两件事一起改：谁来 reveal 交给 `SceneProbe` 的 50 ms 观察器（连续两拍
    /// 满足才动手，见 `watchFirstFrame`），这里只管「已经能画了，所以浮现」。
    /// 光晕同步，否则卡片透明而影子还在。
    func revealContent(_ why: String) {
        guard awaitingFrame else { return }
        awaitingFrame = false
        let ms = (CACurrentMediaTime() - frameAt) * 1000
        Log.write(String(format: "win: first frame shown after %.0fms (%@)",
                         ms, why as NSString))
        guard let card = card else { return }
        let glow = self.glow
        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState],
                       animations: {
                           card.alpha = 1
                           glow?.alpha = 1
                       },
                       completion: nil)
    }

    /// 首帧观察器问的那一个问题。`revealContent` 有 guard，这里只负责回答
    /// 「还有没有人在等」—— 观察器每 50 ms 醒一次，卡片露出来之后就该停。
    var waitingForFrame: Bool { awaitingFrame }

    /// The way out of 停靠小窗: a tap anywhere on its picture. The scene view
    /// would swallow that tap and forward it to the app, so a transparent shield
    /// goes above it — the same trick as the ✕ used to be, a sibling drawn over
    /// the hosted view. 0.0.54 — there is no ✕ to stay below any more, so the
    /// shield goes straight on top of the picture.
    private func installShield() {
        guard let card = card, shield == nil else { return }
        let view = UIControl(frame: card.bounds)
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addTarget(self, action: #selector(undock), for: .touchUpInside)
        card.addSubview(view)
        shield = view
    }

    /// 0.1.5 — 「点小窗升主窗」**只在下一拍 runloop 动手**。
    ///
    /// 这里排队的不是一个几何动作，而是一整套结构手术：换 `windowLevel`、
    /// 把另一张卡缩成小窗（改它的 frame、换档、装 shield、推 scene 的
    /// settings.frame）、改自己的 frame、改画面的 `content.transform`。
    ///
    /// 而调用点全在 `-[UIApplication sendEvent:]` 里面（`rawTouch` → case 3 →
    /// `miniTouch` → 这里）。UIKit 此刻正持有这根手指的完整状态在派发事件，
    /// 中途把窗口层级和视图树换掉，它派发的「目标窗口」与返回后看到的层级就
    /// 对不上了 —— 用户三次报的「点小窗还原成主窗时，App 里也被点了一下」正是
    /// 这个形状。`requestClose` 从 0.0.54 起就是排队做的，这里是同一条纪律。
    ///
    /// 排队也让 `miniTouch` 的返回值更干净：抬手那一拍先**完整吞掉**、`sendEvent`
    /// 正常返回，下一拍再升降。
    @objc private func undock() {
        guard miniFrame != nil, !liftPending else { return }
        liftPending = true
        Log.write("win: mini lift deferred " + bundle)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.liftPending = false
            self.performUndock()
        }
    }

    /// 0.1.5 — 「已经排了一次升降」的闩。没有它，同一拍里两条路（识别器 +
    /// 原始触摸）各排一次，第二遍会在一张已经是主窗的卡上再跑一次手术。
    private var liftPending = false

    private func performUndock() {
        guard let card = card, let window = window, miniFrame != nil else { return }
        miniFrame = nil
        // 0.1.4 — 先抬层再改几何：反过来会有一帧「大卡片已经铺开、但还在小窗层」
        // 的画面，那正是用户报的「主窗被新小窗压住」（见 `mainLevel`）。
        applyWindowLevel()
        // 0.1.3 — 先记下「这一张原来在哪一列」，再把它从队列里摘掉。
        //
        // 用户定档：点 1~5 里任何一个小窗，升上来的这张占它的位置，其余依次上升
        // 补位，**被挤下去的原主窗落到这一列的最后一格（第 5 格）**；左右两列
        // 各自独立，不互相借位。所以降级必须指定列 —— 等 `releaseDock` 之后这
        // 个信息就没了。
        let column: Bool? = FloatHost.columnIndex(self).map { !$0.right }
        // 0.1.26 — 「我变大 + 旧主窗变小 + 其余各格补位」是**同一件事**。
        //
        // 用户 Aevon(108) 第 2 条：「没有卡片变为主悬浮窗的过渡」。原来这三步各自
        // 硬写几何：`demoteMain` 里那张瞬间缩成 98×163，我自己瞬间铺成 347×578，
        // 队列里其余几张瞬移一格 —— 一帧之内三件事同时发生，看起来就是「画面
        // 直接换了一张」。母本用 SwiftUI 的 `withAnimation` 包住整批状态变化
        // （74 处），所以它天然是一次过渡；这里靠 `AevonMotion.spring` 的嵌套
        // 合并拿到同一个效果。
        // 0.1.0 — 环必须先放出来再改几何。停靠时 `placeDock` 把它收起了；如果
        // 在动画块里才 `isHidden = false`，那条 `grip.frame` 的动画是在「隐藏」
        // 状态下登记的，露出来之后会跳一帧。
        grip?.isHidden = false
        var replaced = "none"
        AevonMotion.spring {
            // 0.0.99 — 走了就得让位：后面的小窗要顶上来，档位也可能跨回去。
            FloatHost.releaseDock(self)
            // 0.0.99 — 取消停靠 = 升为主窗。多窗之后「还原来那张大卡片」不再是
            // 唯一结果：别的槽里可能还坐着一个主窗，两张一样大的卡片会叠在一起。
            //
            // 0.1.1 — **这句注释在 0.0.99/0.1.0 里是空话**：那两版只把 `mainIndex`
            // 挪过来，旧主窗原样坐在原处，于是「点小窗还原」之后屏幕上两张同样大小
            // 的卡片摞在一起，用户看到的是「点了一下，什么都没发生」。
            //
            // 0.1.3 — 降级目标改成「真正的主窗」，并且落到**这一列**的队尾（第 5 格）。
            // Aevon(91) 里 `replaced=already` 出现 5 次、`replaced=self` 出现 6 次：
            // 前者是 `mainIndex` 指着一个小窗（谁都没被降级，两张大的摞在一起），
            // 后者是 `mainIndex` 指着正要升上来的这一张（自己被自己排除掉）。
            replaced = FloatHost.demoteMain(except: self, into: column)
            if let index = FloatHost.slotIndex(of: self) {
                FloatHost.mainIndex = index
            }
            // 0.1.5 — **尺寸与位置都读全局记忆**，不再用 `miniFrame`。
            //
            // `miniFrame` 是「这张卡自己停靠之前长什么样」。用户的原话是：还原成
            // 主悬浮窗时的尺寸应该是**上一个主悬浮窗**的尺寸（含位置），而不是它
            // 吸附成小窗之前自己的那个。这也是母本的口径：`mfMainCardScale` /
            // `mfMainCardPosX/Y` 是全局唯一的一份，不按 App 各存。
            let bounds = window.bounds
            let planned = self.plan(in: bounds, source: self.natural)
            // 0.1.7 — 落点用「上一个主悬浮窗的真实 frame」，不再读按边存的百分比。
            // 见 `lastMainFrame`：那一份会被拖动改写、还会按左右半边分两套，于是
            // 每一次升窗落在哪儿都不一定。这里用的是上一次主窗**实际**在哪，所以
            // 每一次都一样，而且等于用户刚放下的那张卡。
            let target = self.clamped(FloatHost.lastMainFrame ?? planned.frame, in: bounds)
            // 0.1.26 — `bounds` + `center`，不是 `frame`：前者是 UIView 文档里
            // 可以安全进动画的那一对，后者会同时写 position 和 bounds，在
            // 一次 spring 里插值出两套曲线。
            card.bounds = CGRect(origin: .zero, size: target.size)
            card.center = CGPoint(x: target.midX, y: target.midY)
            FloatHost.lastMainFrame = target
            self.followContent()
            self.syncGrip()
            // 0.1.10 — 补位要看得见。
            FloatHost.relayoutDocked(animated: true)
        }
        Log.write("win: undock read last main frame "
                  + point(card.frame.origin) + " " + size(card.frame.size))
        shield?.removeFromSuperview()
        shield = nil
        // 0.1.7 — 画面重新可操作（小窗那条锁在 `placeDock` 里上）。
        content?.isUserInteractionEnabled = true
        // 0.1.8 — 标记必须在几何恢复之后立刻撤掉：留在里面等于「App 永远收不到触摸」。
        setMiniFlag(false)
        Log.write("win: card undocked " + size(card.bounds.size)
                  + " at " + point(card.frame.origin)
                  + " promoted=" + bundle
                  + " col=" + (column == nil ? "none" : (column! ? "L" : "R"))
                  + " replaced=" + replaced
                  + String(format: " mem=%.0f%%", CardLayout.loadRuntime().heightFraction * 100))
    }

    // MARK: - geometry

    /// The content keeps the card's size for one reason only: it is the scene's
    /// own coordinate space, scaled. Re-centring without re-scaling is how a
    /// resize leaves the picture in the old corner.
    ///
    /// 0.0.54 — 顶部被裁掉 `cropTop` 源点，所以中心也要跟着上移半个裁切量，
    /// 否则缩小一次之后顶部那一条又会滑回卡片里。
    private func followContent(updateCorner: Bool = true) {
        guard let card = card, let content = content, visible.height > 16 else { return }
        let scale = FloatHost.fitScale(for: visible, in: card.bounds.size)
        content.center = CGPoint(x: card.bounds.midX,
                                 y: card.bounds.midY - cropTop * scale / 2)
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        // A resized card is the same device at another scale, so the corner is
        // the same screen corner at another scale. Leaving the old radius on a
        // shrunk card reads as a rounded rectangle that has been sanded down.
        //
        // 0.0.64 — 圆角不再读上面那个 `scale`（那是「画面缩放比」，跟着卡片
        // 高度走）。见 `applyCorner`：观感上的圆角只由卡宽决定。
        //
        // 0.0.67 — 拖动的每一帧传 false：圆角在 `dragEnd` 里一次算准。
        if updateCorner { applyCorner() }
        applyBars()
    }

    /// 画布在这张卡片里有没有留边。有就填黑，没有就透明 —— 一个判断，两个
    /// 调用点（开窗、每次缩放之后），所以卡片不会出现「缩一下底色变了」。
    private func applyBars() {
        guard let card = card else { return }
        let scale = FloatHost.fitScale(for: visible, in: card.bounds.size)
        let shown = CGSize(width: visible.width * scale, height: visible.height * scale)
        let bars = shown.width < card.bounds.width - 0.5 || shown.height < card.bounds.height - 0.5
        let wanted: UIColor = bars ? .black : .clear
        if card.backgroundColor != wanted { card.backgroundColor = wanted }
    }

    // MARK: - 0.0.73 承载面的位置看门狗

    /// 「第一次打开内容尺寸不对，必须手动缩放一下」的真正成因。
    ///
    /// Aevon(63) 的两张截图（同一面卡，354x590 与 376x627，缩放比 0.823 / 0.874）
    /// 把形状量出来了 —— 用卡内坐标对齐到 430x717 版式：
    ///
    ///   首开：顶栏文字在卡内 74.6 pt，文案首行 524.5 pt；
    ///   缩放后：顶栏 63.4 pt，文案 463.3 pt，两者比值 1.13 ≈ 1/0.874。
    ///
    /// 74.6 / 524.5 与 430x717 版式里的 72.5 / 530 **一比一**吻合。也就是说首开那张
    /// 不是「另一种排版」，而是**内容按 1:1 画、被卡片从右下裁掉**：右侧那一列图标
    /// （内容 x 380..420）和整条底栏（y 634..717）都落在 354x590 的框外 —— 这正是
    /// 截图里「没有右列、没有底栏、文案被切」的形状，也解释了为什么它在任何 App 上
    /// 都一样：裁的是我们的承载面，不是别人的界面。
    ///
    /// 谁把 `transform` 抹掉的：`_UIScenePresentationView` 由 `_UIScenePresenter`
    /// 托管，每次 scene 的 settings 被写（`AevonSceneFrameSet`、轻推、还原都是写它），
    /// 系统就按 scene 的 frame 重设一次它的 `frame`：原点 (0,0)、尺寸 430x717、
    /// transform 单位阵。`show` 里那两行写在 `presenter.activate` 之前，activate
    /// 之后每一次 settings 写入都会再抹一次，而 `reassertCanvas` 只写 `bounds`
    /// —— 于是最后一次轻推还原之后，卡片就停在 1:1 那一版上。
    ///
    /// 角拖动之所以能救回来：`followContent` 把这两个量又写了一遍。
    ///
    /// 所以修法不是再猜一个比例，而是让这两个量每次被抹掉之后自己回来。只碰我们
    /// 自己的承载视图，不碰 App 的窗口，也不碰系统的任何测量。
    @discardableResult
    func reapplyPlacement(_ why: String) -> Bool {
        guard let card = card, let content = content, visible.height > 16 else { return false }
        let scale = FloatHost.fitScale(for: visible, in: card.bounds.size)
        let center = CGPoint(x: card.bounds.midX,
                             y: card.bounds.midY - cropTop * scale / 2)
        let at = content.transform
        let off = abs(at.a - scale) > 0.004 || abs(at.d - scale) > 0.004
            || abs(content.center.x - center.x) > 0.5
            || abs(content.center.y - center.y) > 0.5
        guard off else { return false }
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        content.center = center
        // 前 12 次各写一行：这一条如果真的每拍都要重写，说明还有别的东西在抹它，
        // 日志会直接说出频率；稳定下来之后就不再占版面。
        if placementLogs < 12 {
            placementLogs += 1
            Log.write("win: placement put back " + String(format: "%.3f", scale)
                      + " was=" + String(format: "%.3f", at.a)
                      + " (" + why + ")")
        }
        return true
    }

    /// `重启`, as much of it as a window can do by itself: back to the frame the
    /// card was built with, with the remembered placement cleared first.
    ///
    /// 0.0.69 — 返回「真的做了没有」。Aevon(59)：卡片本来就在默认的 5:3 尺寸上
    /// 长按，什么都不该发生 —— 原来的实现仍然清记忆、重算、重设 frame，虽然
    /// 落地数值一样，但 `CardLayout.reset()` 把用户记住的位置抹掉了，下一次开
    /// 窗就换了地方。所以「已经默认」必须在这里早退，而且早退要在清记忆之前。
    @discardableResult
    private func resetToPlan(in bounds: CGRect) -> Bool {
        guard let card = card, natural.height > 16, bounds.width > 64 else { return false }
        // 0.0.65 — 形状不再存盘，也就没有「复位形状」这件事：画布永远是
        // `fatRender` 算出来的那一块，复位只把卡片摆回开窗时的位置与大小。
        // 0.0.54 — 复位要和 `show` 算同一件事：按原始比例布局，再把高度减掉
        // 顶栏。直接用 `visible` 去 plan 会得到另一条比例（scale 变大、卡片变
        // 宽），复位一次窗口就胖一圈 —— 这是最容易在真机上被当成「新 bug」的
        // 那种不一致。
        // 0.1.1 — 「默认」= 出厂值，不是存盘值。见 `plan(using:)` 的注释：
        // 存盘里的高度就是用户上次缩放的结果，拿它当目标等于「复位到我现在这样」，
        // 于是 `already default` 永远成立（Aevon(89) 第 1 条）。
        let base = self.plan(in: bounds, source: natural, using: CardLayout.Placement.initial)
        var frame = base.frame
        frame.size.height = Swift.max(80, base.frame.height - cropTop * base.scale)
        // 0.1.3 — 位置也归位：**屏幕正中心**（用户定档：「尺寸回 5:3 + 位置屏幕
        // 正中心」）。
        //
        // 0.1.1 只把尺寸算对，位置仍然是 `plan` 里「记忆的落点」。而那个落点会被
        // `clamped` 的 `side` 推一把 —— Aevon(91) 三次复位落在 45,177 / 54,177 /
        // 54,177，正中心是 42,177。差 3 pt 看不出来，差 12 pt 就是「复位没复到位」。
        // 现在不经过那个落点：算完尺寸，直接把原点摆在正中。`plan` 仍然照常参与，
        // 因为高度系数、`widest`/`tallest`/`source.height` 三道夹子都在它里面 ——
        // 5:3 这个形状是它保证的，不能被这里绕过。
        frame.origin.x = ((bounds.width - frame.width) / 2).rounded()
        frame.origin.y = ((bounds.height - frame.height) / 2).rounded()
        // 1.5 pt 是「同一个尺寸」的容差：`fatRender` 四舍五入、屏幕高度系数
        // 取整，都可能让同一个默认值落成 347.4 与 347。停靠中（`miniFrame`
        // 非 nil）永远不算默认，长按要能把它还原回来。
        //
        // 0.1.3 — **中心点也参与判定**。尺寸对了但位置没在正中，就不是「已经默认」：
        // 用户要的是「回 5:3 + 回屏幕正中心」，只判尺寸会让一台「尺寸刚好、位置
        // 偏 12 pt」的手机永远复位不回来（Aevon(91) 的 54,177 就是这样：尺寸
        // 347x578 与目标一模一样，`already default` 会直接早退）。
        if miniFrame == nil,
           abs(card.frame.width - frame.width) < 1.5,
           abs(card.frame.height - frame.height) < 1.5,
           abs(card.frame.midX - frame.midX) < 1.5,
           abs(card.frame.midY - frame.midY) < 1.5 {
            // 0.1.1 — 把**目标**也打进日志。0.1.0 那句只有现状，于是「已经默认」
            // 与「目标和现状被算成同一个」在日志上长得一模一样 —— Aevon(89) 就是
            // 靠这一点藏了整整一版。
            Log.write(String(format: "win: card already default %.0fx%.0f target %.0fx%.0f at %.0f,%.0f",
                             card.bounds.width, card.bounds.height,
                             frame.width, frame.height,
                             frame.origin.x, frame.origin.y))
            return false
        }
        CardLayout.reset()
        miniFrame = nil
        // 0.1.26 — 复位是「一次状态变化」：尺寸与位置一起走同一个 spring。
        // 原来这一句是硬赋值，长按之后卡片「啪」地换了个大小 —— 用户要的
        // 「移动/复位动画」就是这一句。
        let target = clamped(frame, in: bounds)
        AevonMotion.spring {
            card.bounds = CGRect(origin: .zero, size: target.size)
            card.center = CGPoint(x: target.midX, y: target.midY)
            self.followContent()
            self.syncGrip()
        }
        shield?.removeFromSuperview()
        shield = nil
        Log.write(String(format: "win: card reset to %.0fx%.0f at %.0f,%.0f",
                         card.bounds.width, card.bounds.height,
                         card.frame.origin.x, card.frame.origin.y))
        return true
    }

    // MARK: - 0.0.69 激活之后再交一次画布尺寸

    /// 承载面的尺寸在 `show` 里就写好了 —— 但那一步发生在 `presenter.activate`
    /// **之前**。
    ///
    /// Aevon(59) 的第一条（「每一次打开时内容尺寸不对，必须手动缩放一下才显示正确
    /// 的顶栏底栏」）和上一版遗留的第二条是同一件事，判据是这个调用顺序，不是猜：
    ///
    ///   · `show` 里的 `view.bounds = source`（932 → 717）跑在 `activate` 前一行；
    ///   · 日志里 `view cls=_UIScenePresentationView … natural=430x932` 之后紧跟
    ///     `hosted bounds after=430x717` —— **视图**确实换了尺寸；
    ///   · 而真机上「手动缩放一下」改的正是这个尺寸：`followContent` 每帧重写
    ///     `transform`/`center`，承载上下文随之重排一次，App 才开始按 717 排版。
    ///
    /// 也就是说：尺寸写在了 presenter 还没接管的时候，那一次 resize 没有被当成
    /// 「App 的窗口变了」。这里补的正是那一次，而且只碰我们自己的承载视图 ——
    /// 同一个对象、同一个进程、1 pt 的真实变化。绝不下沉到 App 的窗口去
    /// （0.0.67 那么做毁过一台手机）。
    func reassertCanvas() {
        guard let content = content, natural.height > 16 else { return }
        let target = CGRect(origin: .zero, size: natural)
        content.bounds = CGRect(x: 0, y: 0, width: natural.width, height: natural.height + 1)
        // 两次写在同一个 runloop 里会被合并成一次布局，App 看不到「变过」。
        // 0.02 s 之后写第二次，中间隔一次提交。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self = self, let content = self.content else { return }
            content.bounds = target
            self.followContent()
            Log.write("win: canvas re-asserted " + self.size(self.natural)
                      + " after activate")
        }
    }

    // MARK: - 0.0.72 替操作者做掉「手动缩放一下」

    /// 卡片还在：`card` 与窗口都非空。给延迟回调用的判据 —— 0.45 s 之内可能
    /// 又关又开一面新卡，那时候不该再往旧 scene 上写。
    var isUp: Bool { card != nil && window != nil }

    /// A card that can be dragged off the screen can only be brought back by
    /// closing it, so the edges are a wall, not a suggestion.
    ///
    /// 0.0.46 — the wall is `reach` thick, not `margin`. `margin` is 8 pt and a
    /// drag that parked the card 8 pt from the left edge left an 8 pt band
    /// there — the operator's own next drag then "did nothing". The top keeps
    /// none of it: the top strip answers no gesture at all, so reserving room
    /// above the card would only be a gap nobody can use.
    private func clamped(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var result = frame
        // 0.1.3 — 左右**不再留 `reach`**（Aevon(91) 第 4 条）。
        //
        // 0.0.46 那行是 `frame.width + reach*2 <= bounds.width ? reach : 0`，
        // 本意是「放得下就让出一条环」，实际效果**正好相反**：
        //   · 卡片宽到放不下（347 宽 + 2×59 = 465 > 430）⇒ side = 0 ⇒ 能贴边；
        //   · 卡片窄一点（300 宽 + 118 = 418 ≤ 430）⇒ side = 59 ⇒ x 只能在
        //     max(59, 430-300-59=71) 与 59 之间，也就是 **59~71**。整块屏幕只
        //     剩 12 pt 的活动量，用户看到的是「只能在屏幕中间上下移动，像被挡住」。
        // 越窄越动不了，这条规则从来就不是「留环形空间」，而是「窄卡片锁中间」。
        //
        // 用户要的是能贴到左右边缘。贴上之后那一侧的环确实没了（`bandRect` 按
        // 屏幕截断），但另一侧、上边、底中三段都还在 —— 手势不缺路。底部那个
        // `under` 保留：底中上滑是关闭手势，那一段环不能没有。
        let side: CGFloat = 0
        let under = frame.height + reach * 2 <= bounds.height ? reach : 0
        let maxX = max(side, bounds.width - result.width - side)
        let maxY = max(0, bounds.height - result.height - under)
        result.origin.x = min(max(result.origin.x, side), maxX)
        result.origin.y = min(max(result.origin.y, 0), maxY)
        return result
    }

    private func point(_ p: CGPoint) -> String {
        String(format: "%.0f,%.0f", p.x, p.y)
    }

    private func size(_ s: CGSize) -> String {
        String(format: "%.0fx%.0f", s.width, s.height)
    }

    /// `UIApplication.shared` is a force-unwrapped accessor. Inside SpringBoard
    /// it is normally valid, and "normally" is not worth a phone: go through the
    /// runtime and fall back to a screen-sized window when there is no app yet.
    private func mainScene() -> UIWindowScene? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: selector),
              let unmanaged = meta.perform(selector),
              let application = unmanaged.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        return application.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

/// The gesture ring: the card's frame grown by the band, with the card's own
/// rect punched out and the top strip punched out too.
///
/// It exists because a hosted scene view owns its touches. Aevon(33) put the
/// recognizers on the card and got ninety seconds of silence — the presentation
/// view forwarded every touch in the picture to the app, and the ✕ disc worked
/// only because it is a sibling drawn above it. Outside the card there is no
/// scene, no remote window and nothing to forward to.
///
/// `hole` is what keeps the picture honest. Touching inside the card returns nil
/// from hitTest, so the touch goes to the card, to the presentation view, and to
/// the app — tapping, scrolling and liking inside the floating window behave like
/// a real window.
///
/// 0.0.47 — 这一圈住进了自己的窗口（`FloatHost.makeBand`），所以它不再和卡片
/// 抢同一个窗口的命中，也不再有「被某个兄弟视图挡在前面」这种可能。
final class GripView: UIView {
    /// The card's rect in this view's own coordinates.
    var hole: CGRect = .zero
    /// The first few touches are written down. If a report ever says "the edge
    /// still does nothing", this line separates "the touch never arrived" from
    /// "it arrived in a zone that does not do that".
    ///
    /// 0.0.41 — four was too few. Aevon(39)'s log holds exactly one touch per
    /// card (the ✕), because the operator's four attempts at the band came
    /// after it and the counter had already stopped. Eight now, and the window
    /// below matches.
    private var proven = 0   // 0.0.45 — 8 → 20; Aevon(43) spent all four band
                             // attempts inside the first eight touched slots

    // 0.0.44 — the heat map is invisible again, and this time the geometry
    // stays exactly where it is.
    //
    // 0.0.42 painted it because Aevon(40) could not say whether a thumb that
    // landed nowhere had missed the ring or the ring had missed the thumb. That
    // question is answered: Aevon(41)/(42) show `gesture grab zone=right`,
    // `bottom-middle` and `bottom-corner` arriving, docking, resizing and
    // flick-closing. Aevon(42) asks for the colour to go away — while the four
    // zones stay, because they are what the fingers find.
    //
    // So: no fill, no `draw`. The zones are `point(inside:)` and the zone
    // arithmetic below, which do not need to be visible to work. It is one
    // subclass with one property and no pixels.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return !hole.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard proven < 20, let touch = touches.first else { return }
        proven += 1
        Log.write("win: grip touch at " + String(format: "%.0f,%.0f", touch.location(in: self).x,
                                                 touch.location(in: self).y)
                  + " #" + String(proven))
    }
}

/// A window that is only answerable where its content is. Everything else falls
/// through to the app underneath, which is what makes a floating card usable
/// while a full-screen app is running.
final class FloatWindow: UIWindow {
    /// The first few touches, printed as they enter the window and before any hit
    /// testing of our own. Two reports in a row have ended with "the gesture does
    /// not fire" and an empty probe, and an empty probe means either the touch
    /// never reached this window or it reached it and missed the ring.
    /// `sendEvent` is the one place that can tell those apart.
    private var seen = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The bare root view is not a thing to answer with: letting it take the
        // touch costs the desktop its icons and gains nothing, because it has no
        // recognizers and no controls on it.
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }

    override func sendEvent(_ event: UIEvent) {
        if seen < 20, let touch = event.allTouches?.first, touch.phase == .began {
            seen += 1
            let point = touch.location(in: self)
            let who = hitTest(point, with: event)
                .map { String(cString: object_getClassName($0)) } ?? "nil"
            Log.write("win: event hit #" + String(seen)
                      + " at " + String(format: "%.0f,%.0f", point.x, point.y)
                      + " -> " + who)
        }
        super.sendEvent(event)
    }
}

/// 0.0.47 — 手势面的窗口。层级 statusBar+1：任何 App 的窗口都在它下面，所以
/// 「浮窗外侧」这一圈不会因为某个窗口盖在上面而收不到触摸。
///
/// `hitTest` 只回答一件事：命中环（`GripView`）就返回环，别处一律 nil —— 桌面
/// 图标、卡片里的 App 都还归别人。前 20 次提问写进日志：点在哪、答的哪个类。
/// 下一份日志因此能一句话分开「窗口没收到触摸」和「收到了但环判错」，这正是
/// 0.0.44-0.0.46 三轮里始终分不开的那两件事。
final class BandWindow: UIWindow {
    var probe: ((CGPoint, String) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        let answer = (hit === self || hit === rootViewController?.view) ? nil : hit
        probe?(point, answer.map { String(cString: object_getClassName($0)) } ?? "nil")
        return answer
    }
}

/// 这一层的根视图，和竖条那层一样：自己什么都不接，接住的只有环。一张全屏且
/// 会答话的透明视图，就是一张桌面点不动的透明纸。
final class BandRoot: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 0.0.48 — `-[UIApplication sendEvent:]` 的落点（钩子在 Sources/AevonScene.m）。
///
/// `@_cdecl` 只有一个理由：这个函数必须能被 C 直接调用。钩子跑在每一个事件上，
/// 它不该为了调一行 Swift 去建桥、查类、拼 block —— 三个 double 和一个小整数就
/// 是全部。
///
/// 返回 1 = 这条事件已被浮窗吃掉，不要把原事件再交下去。
///
/// 0.0.98 — 逐块问。以前只有一个宿主，`shared.touchEntry` 就是全部答案；现在屏幕
/// 上可能同时有一主一停两块卡，各自的手势环在不同位置，必须让每一块都看见这根手指
/// —— 谁先认领谁吞，其余原样放行。
///
/// 0.1.0 — **主窗排第一个**。以前这里按槽号顺序问（`everySlot`），而槽号是「谁先
/// 开的窗」，与「谁是主窗」无关：`mainIndex` 会随着降级/取消停靠搬来搬去。于是
/// 一个 3 号槽的停靠小窗可能比 0 号槽的主窗先被问到 —— 它的环（固定厚度 66 pt，
/// 在 112 宽的小窗上盖出去 66 pt）把主窗那侧的手势抢走。Aevon(88) 第 3 条
/// 「多个吸附小窗时手势很混乱、有些触发不了」就是这个。
///
/// 停靠小窗的手势环本版已经整圈拆掉（见 `rawTouch` 的那道早退），但顺序仍然要
/// 定死：只靠「它自己会回 false」是隐式的，哪天小窗上又长出一点热区，这条规则
/// 就是唯一的保险。
@_cdecl("AevonFloatTouch")
public func AevonFloatTouch(_ phase: Int32, _ x: Double, _ y: Double, _ stamp: Double) -> Int32 {
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
    let when = TimeInterval(stamp)
    // 0.1.10 — 竖条那一声 `AevonRingGrip.barTouch` **删掉了**。
    //
    // 它从 0.0.49 起就在这条通道上，用户 Aevon(97) 明确要求「不要按照旧版本
    // Aevon 手势制作，现在使用母版触发区手势从新制作」。母版（Stheno）的呼出
    // 只走 `UIGestureRecognizer` + delegate（它二进制里连 `sendEvent` 都没有），
    // 圆盘的呼出入口现在只剩 `RingHost` 那个 `UIPanGestureRecognizer`。
    //
    // 这条函数从此只服务浮窗（主窗五格手势 / 停靠小窗）。左滑呼盘不再需要它，
    // 也就不再可能出现「began 被这里吞了、moved 漏给 App」那种半截序列。
    for host in FloatHost.touchOrder {
        if host.touchEntry(phase: Int(phase), at: point, stamp: when) { return 1 }
    }
    return 0
}

/// 0.1.4 — 多指时只问停靠小窗的那条窄入口。
///
/// `sendEvent` 钩子原来在 `[touches count] != 1` 时**整条事件都不看**（见
/// `AevonSendEventReplacement` 的注释：多指就是在替系统决定缩放手势的生死）。
/// 那条纪律来自「浮窗的五个手势都是单指」，但它漏了一个情形：只要有一根手指
/// 落在停靠小窗上，那一下**必须**被吞，否则会透给 App —— 而「有小窗时恰好还有
/// 另一根手指在别处」并不罕见（前一根还没抬干净、或者手掌压到屏幕）。
///
/// 所以这条入口只做一件事：手指**真的落在某张小窗里（含 6 pt 容忍带）**时，
/// 把事件交给那一张去吞；不落在任何小窗里就回 0，主窗那条路一步都不碰。
/// 多指不归主窗管这条纪律因此没被破坏。
@_cdecl("AevonFloatTouchMini")
public func AevonFloatTouchMini(_ phase: Int32, _ x: Double, _ y: Double, _ stamp: Double) -> Int32 {
    let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
    let when = TimeInterval(stamp)
    for host in FloatHost.touchOrder where host.onMini {
        if !host.miniHit(point) { continue }
        return host.touchEntry(phase: Int(phase), at: point, stamp: when) ? 1 : 0
    }
    return 0
}
