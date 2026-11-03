import UIKit

/* V0.3.23（AevonRingUnfoldV323）：圆盘「从一点长成一个圆」的展开引擎。
 *
 * 依据是用户给的 Stheno 录屏（IMG_1757 逐帧量出来的）：
 *
 *   · 图标**不是**各自从自己那条轨道上淡入的 —— 它们先**叠在同一个点上**（锚点），
 *     然后整簇一起向外铺开，边铺边长大。录屏里 f60 那一簇小图标几乎叠成一团，
 *     f72 已经铺开一半、尺寸也到一半，f84 基本到位。
 *   · 铺开过程中 **图标间距 ÷ 图标尺寸 ≈ 常数** —— 也就是说整簇是「最终圆盘的一个
 *     等比缩小版」，而不是「图标不动、只把半径拉开」。这一条决定了实现方式：
 *     半径与图标缩放必须用**同一个标量 s**，写死两个独立曲线就会走形。
 *   · 没有回弹、没有过冲（录屏里一次都没有），是单调的 easeInOut。
 *
 * 所以这里只有一个标量 `progress`，由它同时决定半径系数与缩放系数：
 *
 *     s(p) = minScale + (1 − minScale) · smoothstep(p)
 *     半径  = 目标半径 · s(p)
 *     缩放  = s(p)
 *
 * ## 为什么是「进度驱动」而不是「时长驱动」
 *
 * 用户要求「随着手指拖动而逐渐成圆形圆盘」—— 圆盘的长出应当跟手。所以 progress
 * 取**两条曲线的较大值**：
 *
 *     progress = max( 时间曲线 , 拖动曲线 )
 *
 *   时间曲线：present 之后 `duration` 内 easeOut 到 1（兜底：手指停住不动也不会卡住）
 *   拖动曲线：指针离召唤点的距离 / dragDistance（跟手：划得快就长得快）
 *
 * 取 max 而不是「二选一」的好处：两个方向都只会让进度**单调增加**，所以不存在
 * 「拖动停下 → 进度倒退 → 图标往回缩」这种抖动。这也和 0.3.19 那套余韵队相反 ——
 * 那套是按队列下标推进，一旦输入停止就永远差一格。
 */
enum AevonRingUnfold {
    /// 时间兜底时长。录屏的铺开约 450ms；这里取 0.55s，让「跟手」有机会赢过时间曲线
    /// （正常一次呼盘拖动大约 200~300ms，拖动曲线会先到 1）。
    static let duration: CFTimeInterval = 0.55
    /// 起点缩放：整簇叠在圆心时的样子。0.26 时 21 个图标叠成一团小方点，
    /// 与录屏第一帧的观感一致（再小就看不出是图标了）。
    static let minScale: CGFloat = 0.26
    /// 拖动曲线量程：指针离召唤点 130pt 视为「完全展开」。
    /// 右缘把手到盘心约 175pt、到内圈图标约 95pt —— 所以「划到图标」时已经 0.65 以上。
    static let dragDistance: CGFloat = 130
    /// 拖动死区：召唤那一下指针本来就离得近，前 10pt 不该算进度。
    static let dragLead: CGFloat = 10
    /// 枢纽（中心面板）的起点缩放。比图标那簇略大 —— 它是「盘」的芯，不该跟着一起缩成点。
    static let minHubScale: CGFloat = 0.62
    /// 淡入速度：progress 到 0.31 时图标已经不透明。
    /// 再慢就会看到「半透明的小图标在飞」，录屏里没有那个阶段。
    static let alphaGain: CGFloat = 3.2

    static func clamp(_ value: CGFloat) -> CGFloat {
        return min(1, max(0, value))
    }

    /// smoothstep：3p² − 2p³。录屏的铺开曲线就是「慢起 → 快中段 → 慢收尾」，
    /// 而且两端导数为 0 —— 起手和落定都不会有速度突变（0.3.21 的「抖一下」正是
    /// 起手速度太高：66ms 从 0 冲到 32pt）。
    static func ease(_ progress: CGFloat) -> CGFloat {
        let p = clamp(progress)
        return p * p * (3 - 2 * p)
    }

    /// 半径系数与图标缩放**共用**这一个值（等比缩小版，见文件头）。
    static func scale(at progress: CGFloat) -> CGFloat {
        return minScale + (1 - minScale) * ease(progress)
    }

    static func hubScale(at progress: CGFloat) -> CGFloat {
        return minHubScale + (1 - minHubScale) * ease(progress)
    }

    static func alpha(at progress: CGFloat) -> CGFloat {
        return clamp(progress * alphaGain)
    }

    /// 指针位移 → 拖动进度。
    static func dragProgress(distance: CGFloat) -> CGFloat {
        return clamp((distance - dragLead) / dragDistance)
    }
}
