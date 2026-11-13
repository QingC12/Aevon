import UIKit

/// 圆盘上的一个 App 单元（V0.0.22：**恢复原生 App 图标**）。
///
/// 取图走 `AevonAppIcon`（多源兜底），取到就显示圆角方形图标；
/// 取不到才退回「深色胶囊 + 白字」的文字卡片，保证任何情况下都能认出是哪个 App。
final class AevonRingIcon: UIView {
    let bundleID: String
    var displayName: String

    private let label = UILabel()
    private let iconView = UIImageView()
    /// 是否成功拿到原生图标（决定高亮时改边框还是改底色）
    private let hasIcon: Bool

    /* V0.3.22（AevonGifHaloV322）：图标脚下一圈**白色柔光底盘**。
     *
     * GIF 里每个图标下面都有这圈白底，被手指压住的那个最亮 —— 它是「图标从盘面
     * 跳出来」的主要读感来源，比边框变色强得多（也是 Stheno 看起来很「Q」的原因
     * 之一：白底把图标从背景里切出来，视觉重量集中，跳起来才有存在感）。
     *
     * 实现选的是**预渲染一张径向渐变位图**，不是 shadow 也不是多层圆：
     *   · 用 `layer.shadow`：模糊核会跟着 `layer.transform` 每帧重算，跳一次 100ms
     *     就是十来次重栅格化 —— 0.3.20 刚把阴影开销按下去，不能再开回来；
     *   · 用三层不同 alpha 的圆：21 个图标 × 3 = 63 个额外图层，太浪费；
     *   · 位图 = 一个带纹理的quad，缩放只是 texture 拉伸，代价约等于零。
     * 图只生成一次（96×96，各图标共享同一份 UIImage）。 */
    private let haloView = UIImageView()
    private var haloOn = false

    /* V0.3.20（AevonKeyframeHoverV320）：划过动画改成 **一条定长关键帧**。
     *
     * 三版的血泪账：
     *   0.3.18 整盘一个 animator —— 每次切换把全部 20 个图标定格丢弃再重发；
     *   0.3.19 每图标一条弹簧 —— 每次切换重建 5 条，每条都要 `finishAnimation(at: .current)`
     *          取当前呈现值（渲染服务器往返），实测 60 次/秒，就是用户说的「丢帧」；
     *   0.3.20 只剩两种**定长关键帧**：`rise`（被划过，200ms）与 `land`（被离开，250ms）。
     *          一次播完、不 retarget；中途改目标时用 `AevonHoverKeyframes.sample` 纯数学
     *          接住当前姿态，**不碰 `layer.presentation()`**。
     *
     * 「上一个还在空中」也从结构上消失了：0.3.19 的余韵是按队列下标取振幅，而实测
     * 划过间隔只有 72~100ms、弹簧沉降却要 0.34~0.63s ⇒ 永远走不到目标就被改目标，
     * 身后形成一条永不落地的人形扇。现在每个图标只有「升起 / 落地」两态，
     * 落地里带**一记余弹**（用户点名要的），但一定会结束。 */
    private enum HoverMotion {
        case idle
        case rise
        case land
    }
    private var hoverMotion: HoverMotion = .idle
    /// 当前这条关键帧的起点（`CACurrentMediaTime()` 基准；入场带延时，会往后推）
    private var hoverMotionStart: CFTimeInterval = 0
    /// **目标态**（不是动画中间值）：true = 应该抬起，false = 应该落地。
    /// `applyHover` 只比这一个布尔量，所以一次切换最多起两条动画。
    var hoverLifted = false
    /// 入场 / 划过 / 落地共用一把键：`layer.transform` 只允许有一个主人
    ///（否则入场动画会和划过动画同时写它，呼盘后立刻划过就有一跳）。
    private static let hoverKey = "aevonHover"
    /// V0.3.22：这一条关键帧启动时的姿态。关键帧表会按它**重新定标**
    ///（见 `AevonHoverKeyframes.rebase`），求值时必须用同一个基准，否则
    /// 取样点落在「没定标的那条曲线」上，下一次接手就会跳一下。
    private var hoverMotionFrom: AevonHoverSample = .ground

    init(bundleID: String, name: String, size: CGFloat) {
        self.bundleID = bundleID
        self.displayName = name
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏两个动作槽没有 App 图标，
        // 用 SF Symbol 画（白色实心，和原生图标一样铺满方框）。
        let actionIcon = AevonQuickAction.symbolImage(bundleID: bundleID, size: size - 4)
        let icon = actionIcon ?? AevonAppIcon.image(bundleID: bundleID, size: size - 4)
        self.hasIcon = icon != nil
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        backgroundColor = hasIcon ? .clear : UIColor(white: 0.12, alpha: 0.92)
        isUserInteractionEnabled = false
        // V0.0.31（AevonRingSquareV31）：改回方形（用户 Aevon(24)：圆形看着别扭）
        // —— 与系统主屏图标一致的圆角方，外壳与内部图标都按 0.26 / 0.2237 圆角率。
        layer.cornerRadius = size * 0.26
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        /* V0.3.20（AevonShadowPathV320，性能包 P1/P2）：
         * 21 个图标一直有阴影，而 `shadowPath` 从来没设过 ⇒ Core Animation 每帧都要
         * 对整层 alpha 做一次卷积来生成阴影；划过还把 `shadowRadius` 从 6 改到 10，
         * 等于模糊核每帧重算。这是「丢帧」的 GPU 侧那一半。
         * 现在：路径一次算好（圆角方，随 bounds 固定不变），半径钉死 8 —— 划过只改
         * `shadowOpacity`，不再触发重新栅格化。 */
        layer.shadowRadius = AevonRingIcon.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowPath = UIBezierPath(roundedRect: bounds,
                                        cornerRadius: size * 0.26).cgPath

        /* V0.3.22（AevonGifHaloV322）：白晕先挂上（在 iconView 之下），默认全透明。
         * 直径 ≈ 1.42× 图标 —— GIF 里量出来的比值（图标 24px、白盘 34px）。
         * 它跟着 `layer.transform` 一起缩放，所以抬起放大 1.25 时白晕同步长大，
         * 和 GIF 里「白盘也跟着变亮变大」一致。 */
        let halo = size * 0.21
        haloView.frame = bounds.insetBy(dx: -halo, dy: -halo)
        haloView.image = AevonRingIcon.haloImage
        haloView.contentMode = .scaleToFill
        haloView.alpha = 0
        haloView.isUserInteractionEnabled = false
        addSubview(haloView)

        if let icon = icon {
            iconView.image = icon
            iconView.frame = bounds.insetBy(dx: 2, dy: 2)
            // 动作槽是 SF Symbol，居中即可（拉伸会把线条图撑变形）
            iconView.contentMode = actionIcon != nil ? .center : .scaleAspectFill
            iconView.isUserInteractionEnabled = false
            /* V0.3.20（AevonPreRoundIconV320，性能包 P3）：
             * 原来这里是 `cornerRadius + clipsToBounds = true`，等于给 21 个图标各挂一个
             * 圆角 mask 图层 —— 每个都是一次离屏渲染。而 `AevonAppIcon.image` 早就把
             * 圆角（22.37%）烘进位图里了，这一层 mask 完全是白花的。
             * `iconView` 的尺寸就是位图尺寸，去掉 mask 后观感一模一样。 */
            iconView.clipsToBounds = false
            addSubview(iconView)
        } else {
            label.frame = bounds.insetBy(dx: 3, dy: 2)
            label.text = AevonRingIcon.shortName(name)
            label.textAlignment = .center
            label.textColor = .white
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.62
            label.isUserInteractionEnabled = false
            addSubview(label)
            label.font = UIFont.systemFont(ofSize: AevonRingIcon.fontSize(for: label.text ?? "", size: size),
                                           weight: .medium)
        }
    }

    /// 0.1.38 — 返 nil，不 `fatalError`。这个类只由代码创建，走到这里说明系统
    /// 在按 nib 反序列化它；那条路上 Swift 的 `fatalError` 会直接终止进程，而
    /// 这里跑在 SpringBoard 里 —— 那就是一次安全模式。返 nil 只是「这个视图没
    /// 加载出来」，系统会当作普通失败。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 当前是否处于高亮态（避免手指每移一帧就重写一遍 layer 属性）
    private var highlightedNow = false

    /// V0.3.20（AevonShadowPathV320）：阴影半径**钉死**，划过只改不透明度。
    /// 以前是 `highlighted ? 10 : 6`，每次高亮切换都要重算一次模糊核。
    static let shadowRadius: CGFloat = 8

    /// V0.3.22（AevonGifHaloV322）：白色柔光底盘位图，**全类共享一份**。
    ///
    /// 中心 α≈0.95（被图标自己盖住，看不到），到 62% 半径还有 0.55，
    /// 之后平滑收到 0 —— 露出来的那圈就是 GIF 里那种「白雾」。
    static let haloImage: UIImage? = {
        let d: CGFloat = 96
        let rect = CGRect(x: 0, y: 0, width: d, height: d)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(white: 1, alpha: 0.95).cgColor,
                          UIColor(white: 1, alpha: 0.88).cgColor,
                          UIColor(white: 1, alpha: 0.46).cgColor,
                          UIColor(white: 1, alpha: 0.0).cgColor] as CFArray
            let locs: [CGFloat] = [0.0, 0.46, 0.72, 1.0]
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: locs) else { return }
            c.drawRadialGradient(g,
                                 startCenter: CGPoint(x: d / 2, y: d / 2), startRadius: 0,
                                 endCenter: CGPoint(x: d / 2, y: d / 2), endRadius: d / 2,
                                 options: [])
        }
    }()

    /// V0.3.22（AevonGifHaloV322）：白晕开关。跟着高亮走，不和 `layer.transform` 抢主人
    ///（transform 归关键帧引擎，这里只动 `alpha`，两条通道互不覆盖）。
    func setHalo(_ on: Bool, animated: Bool) {
        guard on != haloOn else { return }
        haloOn = on
        guard animated else {
            haloView.alpha = on ? 1 : 0
            return
        }
        UIView.animate(withDuration: on ? 0.10 : 0.17,
                       delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut],
                       animations: { self.haloView.alpha = on ? 1 : 0 })
    }

    /// 高亮「松手就会打开」的那个图标
    func setHighlighted(_ highlighted: Bool) {
        setHighlighted(highlighted, animated: false)
    }

    /// V0.3.20（AevonHighlightFadeV320）：高亮也走 130ms 淡入。
    ///
    /// 以前 `borderColor` / `shadowColor` 是写在 animator 的 `addAnimations` 块里的 ——
    /// **CALayer 属性在 UIView 动画块里不插值**，是硬切，于是「蓝框啪一下出现、
    /// 图标还在弹簧里飞」两个东西不同步。这里改用 CATransaction 隐式动画驱动颜色，
    /// 只有一根 0.5→2.5pt 的边框宽度不参与（发丝线跳变看不出来，参与反而触发重绘）。
    func setHighlighted(_ highlighted: Bool, animated: Bool) {
        guard highlighted != highlightedNow else { return }
        highlightedNow = highlighted
        layer.borderWidth = highlighted ? 2.5 : 0.5
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(AevonRingMenu.hoverHighlightFade)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        layer.borderColor = (highlighted
            ? UIColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
            : UIColor(white: 1.0, alpha: 0.16)).cgColor
        // 选中用蓝色光晕强化（文字已经去掉了，靠这个确认选的是哪个）
        layer.shadowColor = (highlighted
            ? UIColor(red: 0.30, green: 0.78, blue: 1.0, alpha: 1.0)
            : UIColor.black).cgColor
        layer.shadowOpacity = highlighted ? 0.85 : 0.45
        if !hasIcon {
            backgroundColor = highlighted
                ? UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.96)
                : UIColor(white: 0.12, alpha: 0.92)
        }
        if animated { CATransaction.commit() }
        // V0.3.22（AevonGifHaloV322）：白晕跟着高亮走（GIF 里被压住的那个最亮）
        setHalo(highlighted, animated: animated)
    }

    // MARK: - V0.3.20（AevonKeyframeHoverV320）：划过关键帧

    /// 此刻的姿态。**纯数学求值，不问渲染服务器** —— 这是本版不掉帧的关键。
    func hoverSample() -> AevonHoverSample {
        let elapsed = CGFloat(CACurrentMediaTime() - hoverMotionStart)
        switch hoverMotion {
        case .rise:
            return AevonHoverKeyframes.sample(AevonHoverKeyframes.riseKeys, at: elapsed,
                                              from: hoverMotionFrom)
        case .land:
            return AevonHoverKeyframes.sample(AevonHoverKeyframes.landKeys, at: elapsed,
                                              from: hoverMotionFrom)
        case .idle:
            return hoverLifted ? AevonHoverKeyframes.lifted : .ground
        }
    }

    /// 被划过：**100ms 抬到 `hoverLift` 并停住**（GIF 的「跳上去」）。
    ///
    /// V0.3.22（AevonGifHoverV322）：稳态从「贴地」改回「悬停」。
    /// 0.3.21 冲上去 34ms、66ms 就回地面，全程 90ms ≈ 4 帧，眼睛读不到「跳」；
    /// GIF 是跳上去就一直停着，手指离开才慢慢沉 —— 那才叫跳起来。
    func riseHover() {
        let from = hoverSample()
        let anim = AevonHoverKeyframes.animation(AevonHoverKeyframes.riseKeys,
                                                 from: from,
                                                 style: .rise)
        layer.transform = AevonHoverKeyframes.lifted.transform3D()
        layer.removeAnimation(forKey: AevonRingIcon.hoverKey)
        layer.add(anim, forKey: AevonRingIcon.hoverKey)
        /* V0.3.22（AevonGifHaloV322）：抬起的那一个必须画在相邻图标**上面**。
         * 用 `zPosition` 而不是 `bringSubviewToFront` —— 后者会动 subviews 数组，
         * 一次切换要重排 21 个图层；zPosition 只是渲染顺序，零结构变更。
         * 不用子层重排的代价：hitTest 不受影响（图标本身 `isUserInteractionEnabled = false`）。 */
        layer.zPosition = 1000
        hoverMotion = .rise
        hoverMotionStart = CACurrentMediaTime()
        hoverMotionFrom = from
        hoverLifted = true
        setHighlighted(true, animated: true)
    }

    /// 被离开：**170ms 慢慢沉回去**，单调、无回弹（GIF 的「松手落下」）。
    func landHover() {
        let from = hoverSample()
        let anim = AevonHoverKeyframes.animation(AevonHoverKeyframes.landKeys,
                                                 from: from,
                                                 style: .land)
        layer.transform = CATransform3DIdentity
        layer.removeAnimation(forKey: AevonRingIcon.hoverKey)
        layer.add(anim, forKey: AevonRingIcon.hoverKey)
        layer.zPosition = 0
        hoverMotion = .land
        hoverMotionStart = CACurrentMediaTime()
        hoverMotionFrom = from
        hoverLifted = false
        setHighlighted(false, animated: true)
    }

    /// 归零（收起圆盘 / 重建列表时）。**必须同时清掉 layer 上的动画** ——
    /// 关键帧是 `fillMode: .forwards`，只清状态不摘动画，`dismiss` 后面写的
    /// `icon.transform` 会被这条在途动画盖住（图标就不往圆心收了）。
    ///
    /// V0.3.22（AevonGifHoverV322）：加了 `snap` 开关。
    /// `snap = true`（重建列表）：直接抹平到 identity。
    /// `snap = false`（收起圆盘）：**保留当前 transform**，让后面的「吸回圆心」
    /// 动画从这里接着走 —— 否则稳态抬起 46pt 的图标会先**啪一下掉回原位**再飞向圆心，
    /// 0.3.21 因为 `hoverLift = 0` 看不出来，这一版会非常明显。
    func resetHover(snap: Bool = true) {
        layer.removeAnimation(forKey: AevonRingIcon.hoverKey)
        if snap {
            layer.transform = CATransform3DIdentity
            layer.zPosition = 0
        }
        hoverMotion = .idle
        hoverMotionStart = 0
        hoverMotionFrom = .ground
        hoverLifted = false
        // 收起档让它跟着一起淡出，不要「白圈啪一下就没了」
        setHighlighted(false, animated: !snap)
        setHalo(false, animated: !snap)
    }

    /// 名字太长会挤成一团：超过 6 个字就截断（圆盘上一行最多 4 字、两行 8 字，取 6 兼顾）
    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 6 { return trimmed }
        return String(trimmed.prefix(6))
    }

    private static func fontSize(for text: String, size: CGFloat) -> CGFloat {
        switch text.count {
        case 0...2: return size * 0.30
        case 3: return size * 0.26
        case 4: return size * 0.235
        default: return size * 0.21
        }
    }
}

/// 径向圆盘选择器（V0.0.23：整体缩到原来的 75% 面积 + 外圈多于内圈 + 手势对调）。
///
/// 形态：
///   · 圆心固定在屏幕水平中央、纵向 **75%**；
///   · 圈数按数量自动增加（≤8 一圈 / 9~20 两圈 / ≥21 三圈），
///     **每圈容量按半径递增**（内圈少、外圈多），相邻圈错开半个步进，视觉更自然；
///   · 内圈半径 62、间距 50（V0.0.28 收紧），图标 40pt、圆心按钮 48pt；
///   · 圆心按钮是蓝色圆 + 四宫格图标，点它打开完整应用选择面板。
///
/// 交互（V0.0.28 定稿，**替换掉此前所有旋转 / 解锁判定**）：
///   1. 圆盘呼出后默认是「选择模式」—— 手指指到哪个图标就高亮哪个，
///      松手落在图标上 → 用浮窗打开它；落在圆心 → 打开完整面板；落在空白 / 盘外 → 收起。
///   2. 手指在**圆心图标上停 1 秒** → 进入「旋转模式」（轻震 + 涟漪 + 圆心变青绿），
///      此后**顺时针、逆时针都能跟手旋转**。
///   3. 旋转模式下**其它图标一律不能选中**，只有圆心可以操作；
///      再按住圆心 1 秒（或按一下就松手）→ 退出旋转，回到选择模式。
///   4. 旋转中把手指移到盘外松手 → 收起圆盘（不打开任何 App）。
///   5. 唤出圆盘的那根手指**不必抬起**：它直接从边缘滑进圆盘就能选图标。
///      **手指没离开屏幕，圆盘绝不收起**（哪怕手指已经在盘外滑了一大圈 —— 呼盘那一下
///      手指本来就贴在右缘、离圆心一百多 pt，那不叫「在盘外」）；
///      只有**抬手**那一刻才判定：在盘外 → 收；在图标之间的间隙里 → 也收；
///      落在图标上 → 开窗；落在圆心 → 打开面板。
///      （V0.2.18 / AevonRingCloseOnLiftV218，取代 0.0.28 的「盘外抬手保持展开」
///      AevonRingKeepOpenV28 与 0.2.17 的「抬手即收」AevonRingLiftDismissV217 —— 规则没变，
///      变的是「手指还在屏上时，外面的定时器不许替它收」。）
///   6. **屏幕上没有任何文字**（圆心、底部都没有）—— 状态只靠圆心图标 / 颜色和动效表达。
///
/// 触摸来源去重：唤出圆盘的那根手指可能同时被「边缘手势条」「窗口 sendEvent 探针」
/// 「全局触摸通道」看到，三条通道都会转发同一个点。这里用 `pointerSource`
/// 只认最先开始的那一条，避免同一次滑动被算两遍。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    /* V0.3.23（AevonRingIcon40V323）：图标 35 → **40pt**（用户本轮要求）。
     *
     * 0.3.21 为了收紧盘面把图标收到 35，现在要放大回来，环径必须**一起**放：
     *   弧间距 42 → 46、内圈基准 60 → 64、相邻圈径向步进 39 → 44、
     *   自适应系数 0.83 → 0.86（40 / 46 ≈ 0.87 是「图标刚好不互相碰到」的上限，
     *   0.86 留 0.5pt 余量；取 0.83 会把 46pt 弧间距算成 38.2，40pt 图标撑不满）。
     * 21 个 App（8/13）实测：半径 60/99 → **64/108**，最外缘 116.5 → **128**。
     *
     * ⛔ 内圈 64 也是物理下限：圆心盘半径 39 + 图标半径 20 + 5pt 间隙 = 64。
     * 再小 40pt 图标就会压到中心盘上（0.2.10 那版「中心图标被盖住」就是这么来的）。
     * `layoutHub` 里的底盘半径是按内圈半径反算的，改这里它会自己缩，不用手调。 */
    private static let iconSize: CGFloat = 40
    private static let centerSize: CGFloat = 52
    /// 命中半径系数
    private static let hitFactor: CGFloat = 0.95
    /* V0.3.19（AevonHoverTrailV319）：命中滞回。
     *
     * Aevon(95) 实测 765 次划过里有 **112 次是 A→B→A 的 200ms 内回跳**（15%），
     * 最短的 8ms 一个来回（`31.156 Loon → 31.164 威锋 → 31.181 Loon`）。
     * 原因很直接：没有滞回时「离得最近的那个」在角平分线上会逐帧翻转，
     * 而每次翻转都要重建弹道 —— 视觉上就是图标原地抖、怎么也弹不起来。
     *
     * 规则：现任图标在自己的放大幅度内（`hoverHysteresisReach` 倍）继续占有，
     * 只有别的图标在**弧长**上比它近 `hoverHysteresisGap` pt 以上才换人。
     * 两个数都是 pt / 倍数，不随圈半径变。 */
    private static let hoverHysteresisReach: CGFloat = 1.35
    private static let hoverHysteresisGap: CGFloat = 8
    /// 圆心按住多久进入 / 退出旋转模式（秒）
    private static let centerHoldDuration: TimeInterval = 1.0
    /// 圆心命中半径（比按钮本身放大一点，手指压在图标边缘也算）
    private static let centerHitRadius: CGFloat = 40

    // MARK: - 划过图标的「跳跃」动画（V0.0.35 起，V0.3.22 按 Stheno 录屏定档）
    //
    // V0.3.22（AevonGifHoverV322，用户给的 Stheno 屏幕录制）：
    //   · `hoverLift` **0 → 46pt**：0.3.21 把稳态压在地面，靠「34ms 冲到顶、66ms 回地面」
    //     表达跳跃 —— 66ms ≈ 4 帧，眼睛读不到「跳」，只读得到「抖一下」。
    //     录屏里是**跳上去就一直停在空中**（手指压着不动它就停着），离开才慢慢沉下去。
    //     这 46pt 换算自录屏：图标 32pt、峰值抬升 61pt ⇒ **1.9×**；我们图标 35pt、
    //     环径向间隙只有 39pt，取 **1.31×（46pt）** —— 再高内圈图标会横穿外圈。
    //   · `hoverScale` **1.18 → 1.25**：录屏里 32pt → 40pt 正好 1.25，全程等比。
    /// 高亮稳态的向上偏移（= `riseKeys` 末帧）
    static let hoverLift: CGFloat = 46
    /// 高亮稳态的放大倍数（= `riseKeys` 末帧）
    static let hoverScale: CGFloat = 1.25
    /* V0.3.20（AevonKeyframeHoverV320）：这里原来是一整套弹簧参数 —— 划过弹簧的
     * response、四拍余韵的振幅 / response 放大 / 错峰延迟三组数组、升起与回落两个初速，
     * 连同下发函数一起整块删掉了（「Q 弹」现在来自下面这些定长关键帧）。
     *
     * 为什么删，而不是再调一次数（Aevon(96) 定量）：
     *   余韵按**队列下标**取振幅 [1.0, 0.60, 0.32, 0.14]、response 再乘 [1, 1.25, 1.55, 1.85]
     *   ⇒ 沉降到 1% 要 0.34 / 0.43 / 0.53 / 0.63 秒；而实测划过间隔中位数只有 72~100ms。
     *   每个图标还没走到目标就被改目标，身后于是形成一条**永不落地的人形扇**
     *   （10pt / 5pt / 2pt）—— 用户说的「上一个还在空中」就是这条扇。
     *   而且每图标一条弹道 × 每次切换 5 个 × 12 次/秒 = 60 次/秒的
     *   `finishAnimation(at: .current)`，每次都要取当前呈现值（渲染服务器往返），
     *   这就是「丢帧」。
     *
     * 现在动画全部在 `Sources/AevonHoverKeyframes.swift`：定长关键帧、一次播完、
     * 中途改目标纯数学接住。`hoverLift` / `hoverScale` 就是关键帧表末帧（停住的样子）。 */
    /// V0.3.20（AevonHighlightFadeV320）：蓝框 / 光晕跟着一起淡入的时长。
    static let hoverHighlightFade: TimeInterval = 0.13
    /// 指针事件中断多久之后允许新手指出手接管（自愈，防止某条通道漏发 ended 把圆盘卡死）
    private static let pointerStaleInterval: CFTimeInterval = 1.2
    /// V0.2.66（AevonRingIdleV266）：指针静默多久后判定「手指早已离屏但 ended 漏发」
    /// → 自动收起圆盘。用户 Aevon(39) #5：滑动呼出圆盘后抬手，圆盘留在屏上必须
    /// 再点一下才消失 —— 就是某条通道漏了 ended，`isFingerDown` 恒真，圆盘成了死态。
    /// 0.8 秒比 pointerStaleInterval(1.2) 短：宁可早一点收，也不让用户多点一次。
    /// 副作用：按住圆盘完全静止 0.8 秒也会收 —— 「静止不动」与「已抬手」在事件层
    /// 无法区分，选择偏向用户报的那一侧。
    private static let pointerIdleDismissInterval: CFTimeInterval = 0.8
    /// 指针**通道**交接阈值（V0.2.16 / AevonRingPointerHandoffV216）。
    ///
    /// 与上面那个 1.2 秒不是一回事：1.2 秒管的是「新手指出手」，这里管的是
    /// 「同一根手指换一条通道继续喂」。用 0.12 秒是因为系统手势识别器判向失败后
    /// 就再也不投递了（Aevon(102) 里 9 次呼盘全部在 0.1~0.5 秒内 Failed），
    /// 交接必须比这个快，否则圆盘会明显「愣一下」。
    private static let pointerHandoffInterval: CFTimeInterval = 0.12
    /// V0.3.16（AevonOwnLiftV316）：抬手帧被交换闸拒的日志限流（0.5s 一条）。
    private static var lastLiftRejectLogAt: CFTimeInterval = 0
    /// 圆心纵向位置（占屏幕高度比例）
    private static let verticalRatio: CGFloat = 0.75

    /// 0.1.20 — **圆心横向右移量（占屏幕宽度比例）。**
    ///
    /// 用户 Aevon(105)：「恢复成之前的固定位置出现，但是需要调整一下位置，之前是
    /// 屏幕正中心靠下，在此基础上靠右一点」。0.1.18/0.1.19 的「跟手」做不出来
    /// （跟手 ⇒ 手指永远在圆心 ⇒ 拖多远都选不中图标），所以退回固定点，但把
    /// 固定点本身右移 —— 右手拇指从右缘伸进来时，最左侧那一圈图标才是够得着的
    /// 那个。390 pt 宽上 0.10 = 39 pt，圆心从 195 到 234；外沿仍按
    /// `min(圆心到左, 到右)` 夹，右侧图标不会被推出屏幕。
    private static let horizontalShiftRatio: CGFloat = 0.10

    /// 0.1.18 — 本次呼盘的落点，由 `presentTracking` 塞进来、`present(in:)` 取走。
    /// 静态是为了在 `AevonRingMenu` 实例创建之前就把值递进去（几何是在 `reload()`
    /// 里一次算完的，没有第二次布局机会）。
    private static var pendingAnchor: CGPoint?

    private let dimView = UIView()
    private let trackLayer = CAShapeLayer()
    private let centerButton = UIButton(type: .custom)
    // V0.2.10（AevonRingHubV210）：圆心外面加两层「底盘」。
    //
    // 用户 Aevon(96)：「美化一下圆盘中间的应用选择器面板」。原来圆心就是一个孤零零的
    // 蓝色圆浮在图标中间，和内圈 62pt 的轨道之间空出一大块，看着像没画完。
    // 现在补两层同心圆盘（外层 92、内层 70，都是白色的 6~7% 填充 + 1pt 微光描边），
    // 圆心按钮本身改成渐变蓝、按下 / 旋转时整组一起换色 —— 变成「枢纽」而不是「一个按钮」。
    // 两层都 `isUserInteractionEnabled = false`，绝不参与触摸判定（命中仍走几何距离）。
    private let hubPlate = UIView()
    private let hubInner = UIView()
    private let centerGradient = CAGradientLayer()
    // V0.2.11（AevonRingGlyphTopV211）：四宫格「应用选择」图标单独一层。
    //
    // 用户 Aevon(97) 第四条：「圆盘中心的应用选择图标不要被蓝色层覆盖」。
    // 0.2.10 把圆心底色从 backgroundColor 换成了插在 layer 第 0 位的 CAGradientLayer ——
    // 于是这个图标能不能看见，取决于 UIKit 给 UIButton 的 imageView 排在第几层，
    // 那是实现细节，不该由它决定。现在图标是**独立视图**，层级比按钮高一级（zPosition 3），
    // 蓝层再怎么插都盖不住它。
    private let centerGlyph = UIImageView()

    private var icons: [AevonRingIcon] = []
    private var iconRadii: [CGFloat] = []
    private var iconBaseAngles: [CGFloat] = []
    private var ringCounts: [Int] = []
    private var ringRadii: [CGFloat] = []

    private var rotation: CGFloat = 0
    /// 阻尼显示角（V0.0.30 起，V0.0.33 升级为速度弹簧）：图标不直接贴手指角度。
    /// V0.0.33（AevonRingSpringV33）：从「每帧追 32%」的纯指数追赶，换成
    /// **质量-弹簧-阻尼**积分器 —— 带速度项，急停会过冲回摆（Q 弹），
    /// 慢拖有黏滞阻尼感（更跟手、更顺），比 diff*0.32 的发飘手感强得多。
    private var displayRotation: CGFloat = 0
    /// 显示角速度（度/帧），弹簧积分器的状态量
    private var displayVelocity: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var ringCenter: CGPoint = .zero
    /// 0.1.18 — 这一盘的落点（nil = 老行为：水平正中、纵向 75%）。
    /// 0.1.19 — 不再是「赋值一次」：`remoteAnchor(to:)` 会在手指移动时持续改写它，
    /// 于是圆心跟着手指走，抬手那一刻才真正固定（母版的 pinned / pinSpeed 语义）。
    private var anchor: CGPoint?
    /// 0.1.19 — 这一局是否开了「展开后固定」（由 `present(in:)` 从配置里读一次）。
    var autoPin = true
    /// 0.1.19 — 已经固定住了：抬手没选中也不收起，等下一次触摸（点图标 / 点盘外）。
    /// 静默看门狗必须认这一位，否则固定住的盘会在 0.8 秒后被它自己收走。
    private var pinned = false
    private var isDismissing = false

    /* V0.3.20（AevonFrameProbeV320，性能包 P6）：本轮展开期间的**帧率自证**。
     *
     * 以前判断「流畅不流畅」全靠手感描述，来回调了三版都没有硬指标。
     * 这里挂一条只读的 CADisplayLink：每帧只做两次浮点比较，收起时打一条
     * 「平均 fps / 最大帧间隔 / >16.7ms 的帧数」。下一轮就能直接看数字，
     * 不用再猜「丢帧」到底是渲染慢还是事件少。 */
    private var frameWatch: CADisplayLink?
    private var frameCount = 0
    private var frameSlow = 0
    private var frameMaxGap: CFTimeInterval = 0
    private var frameLastAt: CFTimeInterval = 0
    private var frameFirstAt: CFTimeInterval = 0

    // V0.0.28：统一指针状态（唤出圆盘的那根手指 / 事后新按的手指走同一套逻辑）
    /// 当前指针归属（"" = 没有活动指针）。同一时刻只认一根手指。
    private var pointerSource = ""
    /// 交接日志限频（AevonRingPointerHandoffV216）
    private var pointerHandoffLogAt: CFTimeInterval = 0
    private var pointerPoint: CGPoint = .zero
    private var pointerAngle: CGFloat = 0
    private var pointerLastEventAt: CFTimeInterval = 0
    /// 这根手指是否进过圆盘范围（区分「唤出圆盘那一下」和「进盘后拖出去取消」）
    private var pointerEverInsideRing = false

    /// 0.1.18 — 这根手指**动过没有**（够不够 12 pt 的死区）。
    ///
    /// 圆心跟手之后，呼盘那一点就落在盘里：Aevon(104) 的落点 (390,740) 距新圆心
    /// (296,740) 只有 94 pt，正压在「外圈 108 ± 容差 31」这条带上 —— 展开那一拍
    /// 就会高亮右侧某个图标，抬手（哪怕只是想看看）就把它打开了。
    ///
    /// 所以「从边缘划出来」的那根手指要先动过 12 pt 才允许高亮；直接落在盘上的
    /// 手指（`source == "local"`，点图标就是他本意）不受这条限制，一点即选。
    private var hoverArmed = true
    private var hoverOrigin: CGPoint = .zero
    private static let hoverDeadband: CGFloat = 12

    /// 手指是否**还压在屏上**（V0.2.18 / AevonRingFingerDownV218）。
    ///
    /// 用户 Aevon(104) 把关闭规则讲清楚了：
    ///   ① 手指滑出圆盘但没离开屏幕 —— **不算**「在圆盘外」，圆盘不许收；
    ///   ② 只有手指**离开屏幕**时在盘外，或落在图标之间的**间隙**里，才收圆盘。
    ///
    /// 所以「收不收」只由 `handlePointerEnded` 一处决定。这个字段的作用是给外面
    /// （SpringBoard 侧的三个定时器）一个判据：手指还在屏上就别替我收。
    /// 置真：began / moved / 通道交接；置假：ended / cancelled / 收起。
    private(set) var isFingerDown = false

    /// 距离上一次指针事件过去了多少秒（没有过事件时返回一个大数）。
    /// 只用于「真的没人操作了」的安全网，不参与「收不收」的判断。
    var pointerIdleSeconds: CFTimeInterval {
        guard pointerLastEventAt > 0 else { return .greatestFiniteMagnitude }
        return CACurrentMediaTime() - pointerLastEventAt
    }

    /// 旋转模式：只有「按住圆心 1 秒」能开关
    private var rotating = false
    private var centerHoldTimer: Timer?
    /// 刚切换过模式：要等手指离开圆心 / 重新按下，才允许再按 1 秒切换
    private var centerHoldSuppressed = false

    // V0.0.39（AevonRingNoHoldRemoveV39）：长按图标移除功能已整体删除（用户不需要）；
    // 圆盘列表的增删统一走设置页的圆盘编辑器。

    // MARK: - 呼出 / 收起

    static func present(in host: UIView) {
        if let existing = current {
            // 0.1.18 — 这条早退不建盘，`pendingAnchor` 不能留在静态里过夜：
            // 下一次 `present(in:)`（面板 / 预览那条路，anchor 本来该是 nil）
            // 会莫名其妙地被摆到上一次的落点上。
            AevonRingMenu.pendingAnchor = nil
            existing.dismiss()
            return
        }
        let menu = AevonRingMenu(frame: host.bounds)
        /* V0.3.18（AevonSpringUnifyV318）：阻尼比在展开这一刻读一次，之后整局复用。
         * 滑条改动要下次呼盘才生效 —— 这是刻意的：逐帧读 prefs 是跨进程 IPC。 */
        menu.hoverZ = AevonSpring.userDampingFraction()
        /* 0.4.63 — `SOUND` 的第二个刷新源：每一次呼盘读一次 ring.plist。
         * 第一个源是 `RingHost.refresh()`（改设置 → Darwin）。两条都要，
         * 因为一个粘性全局量必须有人按期把它拉回真实值。 */
        AevonFloatMotion.refreshSound()
        /* 0.1.19 — 「展开后固定」每局读一次（母版把它做成设置项 `AutoPin`：
         * 自锁::展开后立即固定）。读一次而不是逐帧读：一次呼盘只召唤一次盘，
         * 逐帧读 UserDefaults 是跨进程 IO。 */
        menu.autoPin = RingConfig.loadRuntime().autoPin
        /* 0.1.18 — 圆心跟手：`presentTracking` 把落点塞进 `pendingAnchor`，这里
         * 在 `reload()`（真正算半径与图标位置的地方）之前吃掉它。
         * 用完立刻清空 —— 下一条 `present(in:)`（比如面板那条路）不能再拿上一次
         * 的落点去摆盘。 */
        menu.anchor = AevonRingMenu.pendingAnchor
        AevonRingMenu.pendingAnchor = nil
        host.addSubview(menu)
        host.bringSubviewToFront(menu)
        current = menu
        menu.reload()
        // V0.3.19（AevonHoverTrailV319）：新盘从「没有划过任何图标」开始，余韵队列清空
        menu.resetHoverWave()
        menu.animateIn()
        menu.startIdleWatch()
        menu.startFrameWatch()
    }

    /// 0.0.45 — **按住呼出**（召唤条那条路唯一的正确形态）。
    ///
    /// 操作者对旧版行为的原话：「滑动时出现圆盘，手指没有离开屏幕时圆盘不会
    /// 自动收起关闭圆盘，手指离开屏幕时会自动关闭圆盘」。这正是
    /// `beginRemoteTracking / remoteMoved / remoteLift` 这三条通道原本的语义
    /// （V0.3.16 的权威抬手、V0.2.18 的「只有抬手才收」），本文件本来就写好
    /// 了 —— 缺的只是一个「呼盘时就带上手指」的入口。
    ///
    /// 与 `present(in:)` 的差别只有一处：挂上之后立刻把这根手指登记成当前
    /// 指针，并把它落下的位置记成展开原点（`unfoldOrigin`），于是圆盘从手指
    /// 按下的那一点长出来，跟着手指走，抬手才结束。点一下（不带手指）的路径
    /// 仍然走 `present(in:)`。
    @discardableResult
    static func presentTracking(in host: UIView, at point: CGPoint,
                                source: String) -> AevonRingMenu? {
        if current != nil { return nil }
        /* 0.1.20 — **不再把落点当圆心。**
         *
         * 0.1.18/0.1.19 让圆心跟着呼盘的那一下走（`pendingAnchor = point`），
         * 用户 Aevon(105) 的结论是这条路做不成：跟手 ⇒ 手指永远在圆心 ⇒
         * 到每个图标的距离恒定 ⇒ 拖多远都选不中一个。现在的语义回到「固定位置
         * 出现」，位置由 `computeGeometry` 里的 `horizontalShiftRatio` 决定：
         * 中心偏下，再往右挪 10% 屏宽。
         *
         * 静态 `pendingAnchor` 留着不删（`present(in:)` 仍在读、仍在清），只是
         * 这条路永远不写它 —— 于是 `applyAnchor` 是空转。
         */
        AevonRingMenu.pendingAnchor = nil
        present(in: host)
        guard let menu = current else { return nil }
        menu.beginRemoteTracking(at: point, source: source)
        return menu
    }

    // MARK: - V0.2.66（AevonRingIdleV266）：指针静默自动收起
    //
    // 用户 Aevon(39) #5：滑动呼出圆盘后手指离开屏幕，圆盘留在屏上必须再点一下。
    // 抬手判定（handlePointerEnded）本身没问题 —— 问题是那条通道**根本没把 ended
    // 送进来**（收养手指只登记观察，通道交接 / 系统手势抢断都可能漏发最后一报），
    // isFingerDown 恒真，圆盘成了死态。这里用「静默时长」兜底：0.8 秒没有任何
    // 指针事件就判定手指早已离屏，按「抬手未选中」收起。

    private var idleWatch: Timer?

    // MARK: - V0.3.20（AevonFrameProbeV320）：帧率自证

    private func startFrameWatch() {
        stopFrameWatch()
        frameCount = 0
        frameSlow = 0
        frameMaxGap = 0
        frameLastAt = 0
        frameFirstAt = 0
        let link = CADisplayLink(target: self, selector: #selector(stepFrameWatch))
        link.add(to: .main, forMode: .common)
        frameWatch = link
    }

    @objc private func stepFrameWatch() {
        let now = CACurrentMediaTime()
        if frameFirstAt == 0 { frameFirstAt = now }
        if frameLastAt > 0 {
            let gap = now - frameLastAt
            if gap > frameMaxGap { frameMaxGap = gap }
            // 120Hz 一帧 8.33ms；掉到 60Hz 是 16.7ms。用 16.7 当「明显掉帧」的门槛。
            if gap > 0.0167 { frameSlow += 1 }
        }
        frameLastAt = now
        frameCount += 1
    }

    private func stopFrameWatch() {
        frameWatch?.invalidate()
        frameWatch = nil
    }

    /// 收起时打一条。故意放在 `flushHoverSummary` 之后 —— 两个数放一起才好对账。
    private func flushFrameWatch() {
        let span = frameLastAt - frameFirstAt
        defer { stopFrameWatch() }
        guard frameCount > 2, span > 0.2 else { return }
        let fps = Double(frameCount - 1) / span
        AevonLog.info("[圆盘] 本轮帧率 平均 \(String(format: "%.1f", fps))fps"
            + " / \(frameCount) 帧"
            + " / 最大间隔 \(String(format: "%.1f", frameMaxGap * 1000))ms"
            + " / >16.7ms 的帧 \(frameSlow)"
            + "（AevonFrameProbeV320）")
    }

    private func startIdleWatch() {
        idleWatch?.invalidate()
        // 呼盘后先给 1 秒宽限：部分通道（视图层 pan）呼盘后才交指针，
        // 不能让「还没喂过第一报」被误判成「手指早已离屏」。
        presentedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, AevonRingMenu.current === self, !self.isDismissing else { return }
            guard CACurrentMediaTime() - self.presentedAt >= 1.0 else { return }
            // V0.2.69（AevonRingIdleFixV269，用户 Aevon(41) #2「触发圆盘时，手指
            // 没有离开屏幕，有时候会自动关闭圆盘」）：静默 ≠ 手指已离屏 —— 用户
            // 按住不动（圆心按住 / 旋转模式 / 盯着看）同样静默。真判据是 UIKit
            // 活跃触摸：圆盘视图与把手上都查不到活跃 touch，才算「ended 真漏发」。
            // 圆心按住与旋转模式照旧豁免（它们的 touch 一定在）。
            guard !self.rotating, self.centerHoldTimer == nil else { return }
            /* 0.0.45：**没喂过任何指针，就不存在「ended 漏发」。**
             *
             * `pointerIdleSeconds` 在 `pointerLastEventAt == 0` 时返回极大值，本意是
             * 「从没来过 = 静默无限久」。但这只对「曾有一根手指、ended 丢了」成立。
             * 召唤条点一下就开的那条路上，手指是**按下之前就抬起了**，圆盘从来没有
             * 指针 —— 于是它必然在 1 秒宽限后自己收起。Aevon(43) 的日志逐字印证：
             *
             *   19:10:36 [圆盘] 已展开（20 个 App …）
             *   19:10:37 [圆盘] 指针已静默 1797...e308s → 自动收起（ended 漏发实锤）
             *
             * 一秒不是「漏发实锤」，是「根本没人来过」。这种局面的收尾由用户自己的
             * 下一次触摸（touchesBegan 接管）或抬手判定负责，看门狗在这里没有职责。 */
            // 0.1.19 — 「展开后固定」那一局，抬手之后本来就没有指针了，
            // 看门狗在这里没有职责（它不是 ended 漏发，是我们把人留住了）。
            guard !self.pinned else { return }
            guard self.pointerLastEventAt > 0 else { return }
            guard self.pointerIdleSeconds >= AevonRingMenu.pointerIdleDismissInterval else { return }
            guard !self.hasLiveTouch else { return }
            AevonLog.info("[圆盘] 指针已静默 \(String(format: "%.1f", self.pointerIdleSeconds))s"
                + "（最后落点 (\(String(format: "%.0f", self.pointerPoint.x)), \(String(format: "%.0f", self.pointerPoint.y)))）"
                + " → 圆盘与把手均无活跃触摸（ended 漏发实锤），自动收起"
                + "（AevonRingIdleV266 AevonRingIdleFixV269）")
            self.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleWatch = timer
    }

    private var presentedAt: CFTimeInterval = 0

    // MARK: - V0.3.23（AevonRingUnfoldV323）：展开进度
    //
    // 整个「长成圆盘」只由**一个标量**驱动，见 AevonRingUnfold 的文件头。
    // 存成字段而不是局部变量，是因为拖动回调要写它（`unfoldDragProgress`），
    // 而逐帧步进在读它 —— 两个入口都必须看到同一份进度。
    private var unfoldLink: CADisplayLink?
    /// 当前铺开到哪（0 = 全叠在圆心，1 = 完全展开）
    private var unfoldProgress: CGFloat = 1
    /// 拖动贡献的进度（只增不减，防止手指回撤时盘面往回收）
    private var unfoldDragProgress: CGFloat = 0
    private var unfoldStartedAt: CFTimeInterval = 0
    /// 召唤点 —— 拖动曲线的原点。圆盘是**从手指召唤它的那个点**长出来的。
    private var unfoldOrigin: CGPoint?

    /// V0.2.69（AevonRingIdleFixV269）：圆盘视图与把手上还有没有活跃触摸。
    /// 静默看门狗的「ended 真漏发」判据 —— 手指物理在屏上时 UIKit 一定把
    /// touch 挂在命中视图（圆盘全屏视图 / 把手控件）上，查得到就不是漏发。
    /// V0.2.69（AevonRingIdleFixV269）：圆盘视图与把手上还有没有活跃触摸。
    /// 静默看门狗的「ended 真漏发」判据 —— UIKit touches 家族是硬通道（指针
    /// 喂料通道会漏最后一报），圆盘自己的触摸计数为 0 且把手上也没手指，
    /// 才算「手指真不在屏上」。
    fileprivate var hasLiveTouch: Bool {
        if uiKitTouchCount > 0 { return true }
        if AevonRingGrip.hasActiveGripTouch { return true }
        return false
    }

    static var presented: AevonRingMenu? { return current }

    /// 0.1.19 — 这一盘是否已经「固定住」（抬手未选中、但开了展开后固定）。
    ///
    /// 呼盘垫用它决定「边缘再划一下」是拒绝还是接管：固定住的盘应该被下一次
    /// 边缘滑动**拖走重摆**，而不是像 0.1.18 那样一律 `pad refused by ring`
    /// —— 那时用户看到的就是「盘还在，但划边缘没反应」。
    var isPinned: Bool { return pinned }
    static var isPresented: Bool { return current != nil }

    static func dismissCurrent() {
        current?.dismiss()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = true

        dimView.backgroundColor = UIColor(white: 0, alpha: 0.28)
        dimView.frame = bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.isUserInteractionEnabled = false
        addSubview(dimView)

        // 每圈一条极淡的描边，给出「圆盘」的轮廓
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.13).cgColor
        trackLayer.lineWidth = 1.5
        layer.addSublayer(trackLayer)

        /* V0.2.10（AevonRingHubV210）：圆心底盘（两层同心圆，纯图层，不参与触摸）
         * V0.3.23（AevonHubPanelV323）：**中心盘与外圈图标刻意做成两种东西** ——
         *   外圈 = 40pt 原生 App 图标 + 白晕 + 逐图标阴影（一个个「物件」）；
         *   中心 = 无图标语义的**玻璃面板**：两层同心盘（层 + 内孔）、连续圆角、
         *          更亮的底面、更细的描边，再叠一层面板里的圆角方「按钮」。
         * 用户要的「中心的面板图标和外圈的图标存在一些差异」就是这条：
         * 外圈是 App，中心是「面板入口」，视觉语言必须不一样，否则会被当成第 22 个 App。 */
        hubPlate.isUserInteractionEnabled = false
        hubPlate.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        hubPlate.layer.borderWidth = 1.0
        hubPlate.layer.borderColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        hubPlate.layer.cornerCurve = .continuous
        hubPlate.layer.zPosition = 0
        addSubview(hubPlate)

        hubInner.isUserInteractionEnabled = false
        hubInner.backgroundColor = UIColor(white: 1.0, alpha: 0.06)
        hubInner.layer.borderWidth = 1.0
        hubInner.layer.borderColor = UIColor(white: 1.0, alpha: 0.12).cgColor
        hubInner.layer.cornerCurve = .continuous
        hubInner.layer.zPosition = 0
        addSubview(hubInner)

        // V0.0.25：圆心只留四宫格图标，不再有任何文字
        // V0.0.26：底部提示文字也一并移除 —— 屏幕上不再出现任何说明文字，
        //          后续用「选中动画」表达状态（用户 Aevon(19) 要求）

        centerButton.frame = CGRect(x: 0, y: 0, width: AevonRingMenu.centerSize, height: AevonRingMenu.centerSize)
        // V0.2.10（AevonRingHubV210）：填充改渐变（底色交给 CAGradientLayer，按钮自身透明）
        centerButton.backgroundColor = .clear
        /* V0.3.23（AevonHubPanelV323）：圆心从「圆」改成**圆角更大的方面板**。
         * 外圈图标是 26% 圆角的 App 图标，这里是 34% —— 同为方形但更圆、更大（52pt），
         * 加上它没有白晕、没有图标阴影，一眼就能分出「这是面板入口，不是 App」。 */
        centerButton.layer.cornerRadius = AevonRingMenu.centerSize * 0.34
        centerButton.layer.cornerCurve = .continuous
        centerGradient.cornerRadius = AevonRingMenu.centerSize * 0.34
        centerGradient.cornerCurve = .continuous
        centerGradient.startPoint = CGPoint(x: 0.18, y: 0.02)
        centerGradient.endPoint = CGPoint(x: 0.82, y: 1.0)
        centerGradient.colors = [
            UIColor(red: 0.30, green: 0.66, blue: 1.00, alpha: 0.98).cgColor,
            UIColor(red: 0.07, green: 0.36, blue: 0.88, alpha: 0.98).cgColor
        ]
        centerButton.layer.insertSublayer(centerGradient, at: 0)
        centerButton.layer.shadowColor = UIColor.black.cgColor
        centerButton.layer.shadowOpacity = 0.40
        centerButton.layer.shadowRadius = 14
        centerButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        // 圆心图标：四宫格（表示「应用列表 / 面板」）
        // V0.2.11（AevonRingGlyphTopV211）：图标不再挂在按钮上（UIButton 的 imageView 层级
        // 由 UIKit 决定，蓝色渐变一插入就可能压住它）—— 改成独立视图，zPosition 最高。
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        if let symbol = UIImage(systemName: "square.grid.2x2.fill", withConfiguration: symbolConfig) {
            centerGlyph.image = symbol
            centerGlyph.tintColor = .white
        } else {
            centerButton.setTitle("A", for: .normal)
            centerButton.setTitleColor(.white, for: .normal)
            centerButton.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        }
        // 圆心不接收触摸：由几何判定处理，避免和旋转手势冲突
        centerButton.isUserInteractionEnabled = false
        centerButton.layer.zPosition = 2
        addSubview(centerButton)

        // 图标层压在最上面：蓝色渐变 / 底盘 / 高亮环都在它下面，怎么插都盖不住
        centerGlyph.isUserInteractionEnabled = false
        centerGlyph.contentMode = .scaleAspectFit
        centerGlyph.layer.zPosition = 3
        addSubview(centerGlyph)
    }

    /// 0.1.38 — 返 nil，不 `fatalError`。这个类只由代码创建，走到这里说明系统
    /// 在按 nib 反序列化它；那条路上 Swift 的 `fatalError` 会直接终止进程，而
    /// 这里跑在 SpringBoard 里 —— 那就是一次安全模式。返 nil 只是「这个视图没
    /// 加载出来」，系统会当作普通失败。
    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        centerHoldTimer?.invalidate()
        displayLink?.invalidate()
        displayLink = nil
        unfoldLink?.invalidate()
        unfoldLink = nil
    }

    // MARK: - 几何

    private func computeGeometry() {
        // 圆心固定：纵向 75%（用户 2026-10-22 第二次要求）。
        //
        // 0.1.18 — 这**只是第一遍**：`applyAnchor` 会在 `ringRadii` 算完之后把圆心
        // 挪到这次呼盘的落点上。分两拍是因为 `maxRadius`（决定每圈半径）要读
        // `ringCenter`，而夹落点又要知道最大半径 —— 两件事互相依赖。
        //
        // 0.1.20 — **跟手撤掉，圆心回到固定点，但横向右移。** 用户 Aevon(105)：
        // 「既然圆盘和圆心跟手无法制作，那么恢复成之前的固定位置出现，但是需要
        // 调整一下位置，之前是屏幕正中心靠下，在此基础上靠右一点」。`pendingAnchor`
        // 现在恒为 nil（`presentTracking` 不再塞落点），所以 `applyAnchor` 是空转，
        // 下面这一行就是最终圆心。
        let shift = bounds.width * AevonRingMenu.horizontalShiftRatio
        ringCenter = CGPoint(x: bounds.midX + shift,
                             y: bounds.height * AevonRingMenu.verticalRatio)

        centerButton.center = ringCenter
        centerGradient.frame = centerButton.bounds
        layoutHub()
    }

    /// 0.1.18 — 把圆心夹进屏幕（外沿 = 最外圈半径 + 图标半宽 + 6 pt 余量）。
    ///
    /// 必须在 `ringRadii` 算完之后调（那时才知道这一盘到底多大），并且必须在
    /// `drawRingTracks()` / `layoutIcons()` 之前 —— 那两个函数都按 `ringCenter`
    /// 落笔，晚一步就会得到「轨道跟手、图标不动」的半截盘。
    ///
    /// 屏幕装不下这一盘（外沿 × 2 > 短边）时退回固定圆心：与其把半径压到看不清，
    /// 不如承认这一台放不下「拇指当圆心」。
    ///
    /// 0.1.19 — 加 `announce`：跟手时每帧都会调它，逐次写日志会把日志淹掉。
    /// 只在「这一盘第一次定位」和「抬手固定」两处说话。
    private func applyAnchor(announce: Bool = false) {
        guard let target = anchor else { return }
        let outer = (ringRadii.max() ?? 62) + AevonRingMenu.iconSize / 2 + 6
        guard bounds.width > outer * 2, bounds.height > outer * 2 else { return }
        let x = Swift.min(Swift.max(target.x, outer), bounds.width - outer)
        let y = Swift.min(Swift.max(target.y, outer), bounds.height - outer)
        ringCenter = CGPoint(x: x, y: y)
        guard announce else { return }
        AevonLog.info("[圆盘] 圆心跟手 ("
            + String(format: "%.0f,%.0f", target.x, target.y) + " → "
            + String(format: "%.0f,%.0f", x, y) + "，外沿 " + String(Int(outer))
            + "pt）（AevonRingAnchorFollowV118）")
    }

    /// 0.1.19 — **手指还在屏上时，圆心跟着它走。**
    ///
    /// 用户 Aevon(104) 第 2 条要的是「像 stheno 母版那样跟随手指移动，然后固定」。
    /// 0.1.18 只在 `.began` 那一拍取一次落点（离边 8~12 pt 的那个点），夹进屏幕
    /// 之后固定 —— 手指继续往里滑，盘却停在边上不动，看起来像「盘跟手指没关系」。
    ///
    /// 现在每次 `moved` 都把落点喂进来，夹进屏幕后重新落笔。落笔只有三个消费者
    /// （轨道 / 图标 / 心圆底盘），逐帧调用就是一次 `UIBezierPath` 重建 + N 次
    /// `center` 赋值，21 个图标也只是几十次浮点运算。
    ///
    /// 位移小于 0.5 pt 直接返回：单指抖动会让同一位置反复重建路径，白烧帧。
    ///
    /// ---
    /// ⛔ **0.1.20 起这个函数是空转。** 用户 Aevon(105) 判了这条路的死刑：
    /// 「既然圆盘和圆心跟手无法制作，那么恢复成之前的固定位置出现」。原因在
    /// 0.1.19 的实现里就写明过：跟手 ⇒ 手指永远在圆心 ⇒ 到每个图标的距离恒定
    /// ⇒ **拖多远都选不中一个图标**。两段式（先摆位置、抬手固定、再点选）在
    /// 真机上也没站住 —— 用户要的是「划开就能选」，不是「先摆再选」。
    ///
    /// 函数保留、调用点保留、行为清空：`RingHost` 的 `.moved` 仍然每帧调它，
    /// 但圆心不再移动。这样万一以后要做「手动拖盘」的显式入口，接回来只改这里。
    func remoteAnchor(to point: CGPoint) {
        _ = point
    }

    /// V0.2.11（AevonRingHubFitV211）：心圆底盘 + 四宫格图标的尺寸与位置。
    ///
    /// 0.2.10 把底盘写死成 92 / 70 —— 92 的半径 46 比「内圈半径 60 − 图标半宽 17.5 = 42.5」
    /// 还大 3.5pt，于是底盘边缘必然压在内圈图标的内侧边上（早期反馈「中心图标被盖住」）。
    /// 现在按**实际内圈半径和本圈图标尺寸**反算：
    ///   底盘半径 = min(46, 内圈半径 − 图标半宽 − 5)，至少 35；
    ///   内层半径 = 底盘半径 − 6，至少 30。
    /// 一圈布局（内圈半径更大）时自动放大，多圈挤压时自动缩小，永远不与图标相交。
    private func layoutHub() {
        let innerRadius = ringRadii.first ?? 64
        let iconHalf = (icons.first.map { $0.bounds.width } ?? AevonRingMenu.iconSize) / 2
        let plateRadius = min(46, max(35, innerRadius - iconHalf - 5))
        // V0.3.23：内孔从「盘半径 − 6」放开到「− 8」—— 40pt 图标时盘半径 39，
        // 内孔 31 刚好把 52pt 的中心按钮（半对角 26.2）完整留在里面，不压到环上。
        let innerHole = max(30, plateRadius - 8)

        hubPlate.bounds = CGRect(x: 0, y: 0, width: plateRadius * 2, height: plateRadius * 2)
        hubPlate.center = ringCenter
        hubPlate.layer.cornerRadius = plateRadius

        hubInner.bounds = CGRect(x: 0, y: 0, width: innerHole * 2, height: innerHole * 2)
        hubInner.center = ringCenter
        hubInner.layer.cornerRadius = innerHole

        let glyphSide: CGFloat = 24
        centerGlyph.frame = CGRect(x: 0, y: 0, width: glyphSide, height: glyphSide)
        centerGlyph.center = ringCenter
    }

    /// 圆的可用最大半径：不超出左右边界，也不顶到状态栏 / 底部
    ///
    /// 0.1.20 — 横向那一项从「屏幕半宽」改成「圆心到**较近那一侧**的距离」。
    /// 圆心右移 39 pt 之后，还用半宽算半径就会把最右一列图标顶出屏幕（圆心
    /// 234 + 半径 169 + 图标 20 = 423 > 390）。`sideRoom` 是同一件事的正确写法，
    /// 居中时它等于半宽，右移越多它收得越紧，永远不会溢出。
    private var maxRadius: CGFloat {
        let sideRoom = Swift.min(ringCenter.x, bounds.width - ringCenter.x)
        let byWidth = sideRoom - AevonRingMenu.iconSize / 2 - 6
        let verticalRoom = min(ringCenter.y, bounds.height - ringCenter.y)
        let byHeight = verticalRoom - AevonRingMenu.iconSize / 2 - 12
        return max(64, min(byWidth, byHeight))
    }

    /// 各圈半径。
    ///
    /// V0.0.30（AevonRingDenseV29 → 自适应间距）：**一切以圆心图标为基准向外扩散**——
    /// 半径 = max(内圈基准 60 + 39×圈序, 每圈数量 × 42pt ÷ 2π)，即「图标中心间距 ≈42pt」
    /// 恒定、内圈永远不小于贴住圆心的 60（60 − 圆心半径 24 − 图标半径 17.5 = 18.5pt 间隙）。
    /// 8 个 → 60、21 个(8/13) → 60/99、25 个(10/15) → 71/110。
    /// 不会再出现「内圈被数量撑到 70+、离中心一大截」（用户 Aevon(23) 反馈）。
    /// 上限压到 maxRadius（不顶屏幕边）。
    ///
    /// V0.3.21（AevonRingIcon35V321）：46 / 62 / 44 三个数一起收到 **42 / 60 / 39**，
    /// V0.3.23（AevonRingIcon40V323）：与图标 40pt 配套。
    /// 44 = 40 + 4pt 径向间隙，46 = 40 + 6pt 弧上间隙，内圈 64 = 圆心盘 39 + 20 + 5。
    private func radii(forCounts counts: [Int]) -> [CGFloat] {
        guard !counts.isEmpty else { return [] }
        let spacing: CGFloat = 46
        let inner: CGFloat = 64
        let limit = maxRadius
        var result: [CGFloat] = []
        var previous: CGFloat = 0
        for (index, count) in counts.enumerated() {
            let base = inner + 44 * CGFloat(index)
            var r = max(base, spacing * CGFloat(count) / (2 * .pi))
            r = max(r, previous + 44)
            r = min(r, limit)
            result.append(r)
            previous = r
        }
        return result
    }

    /// 按总数决定每圈放几个（V0.0.29 重写，标记 AevonRingDenseV29）。
    ///
    /// 旧版问题（用户 Aevon(22) 反馈）：固定权重 1 : 1.5 : 2 + 内圈半径 62 起步，
    /// 21~25 个 App 时内圈只摊到 4~5 个，弧线间距被拉到 ~80pt，「图标之间的间隔非常大」。
    ///
    /// 新规则（配合 `radii(forCounts:)` 的「数量反推半径」一起用）：
    ///   · ≤16 个：一圈（半径由数量反推，4 个也只会撑到 62 的下限）；
    ///   · 17~34 个：两圈，内圈约 40%（20 个 → 8 + 12，半径约 70 / 106，间距≈55）；
    ///   · ≥35 个：三圈，权重 1 : 1.5 : 2（36 个 → 8 + 12 + 16，间距≈55）。
    /// 外圈仍不少于内圈；每圈数量有上限（12 / 15 / 20），防止间距被压到图标重叠。
    static func distribution(for total: Int) -> [Int] {
        guard total > 0 else { return [] }
        if total <= 16 { return [total] }
        if total <= 34 {
            var inner = Int((CGFloat(total) * 0.4).rounded())
            inner = min(max(inner, 4), 12)
            return [inner, total - inner]
        }
        let caps = [12, 15, 20]
        let weights: [CGFloat] = [1, 1.5, 2]
        var parts = weights.enumerated().map { (i, w) in
            min(max(Int((CGFloat(total) * w / 4.5).rounded(.down)), 4), caps[i])
        }
        var rest = total - parts.reduce(0, +)
        // 余数先给外圈、再给中圈（保持「外多内少」），同时不超容量
        var guardCounter = 0
        while rest > 0 && guardCounter < 64 {
            guardCounter += 1
            if parts[2] < caps[2] { parts[2] += 1; rest -= 1 }
            else if parts[1] < caps[1] { parts[1] += 1; rest -= 1 }
            else if parts[0] < caps[0] { parts[0] += 1; rest -= 1 }
            else { break }
        }
        // 超出总容量（>47 个）时溢出塞给外圈，间距略压小于目标值即可
        if rest > 0 { parts[2] += rest }
        return parts
    }

    private func reload() {
        computeGeometry()
        for icon in icons { icon.removeFromSuperview() }
        icons.removeAll()
        iconRadii.removeAll()
        iconBaseAngles.removeAll()
        ringCounts.removeAll()
        ringRadii.removeAll()

        let bundleIDs = AevonRingStore.bundleIDs()

        // 由内到外依次填圈：容量按总数动态分配（外圈一定比内圈多）
        ringCounts = AevonRingMenu.distribution(for: bundleIDs.count)
        ringRadii = radii(forCounts: ringCounts)
        // 0.1.18 — 半径有了，才夹得住落点；夹完再落笔（轨道 / 图标都在下面）。
        // 0.1.19 — 这一处要说话：它是「这一盘的圆心落在哪」的唯一一行证词。
        applyAnchor(announce: true)

        var cursor = 0
        for (ringIndex, count) in ringCounts.enumerated() {
            let radius = ringRadii[ringIndex]
            let step = 360 / CGFloat(max(count, 1))
            // 相邻圈错开半个步进：图标不会在上下方向连成一条直线，视觉更自然
            let offset: CGFloat = (ringIndex % 2 == 1) ? step / 2 : 0
            // V0.3.23（AevonRingIcon40V323）：图标大小自适应 —— 按本圈弧间距缩放，
            // 挤的时候自动变小、疏的时候最多到 `iconSize`（40pt）。
            // 系数 0.83 → 0.86：40 / 46 ≈ 0.87 是「刚好不互相碰到」的上限，0.86 留 0.5pt 余量。
            // 疏圈（内圈 8 个 / R 64 → 弧间距 50.3）算 43.2 → 被 40 截住，
            // 也就是内圈永远满尺寸 40，只有挤到弧间距 < 46 的圈才会缩。
            let arcSpacing = 2 * CGFloat.pi * radius / CGFloat(max(count, 1))
            let iconSize = min(AevonRingMenu.iconSize, max(28, arcSpacing * 0.86))
            for i in 0..<count {
                guard cursor < bundleIDs.count else { break }
                let bundleID = bundleIDs[cursor]
                cursor += 1
                let name = AevonWindowManager.title(for: bundleID)
                let icon = AevonRingIcon(bundleID: bundleID, name: name, size: iconSize)
                // V0.2.11（AevonRingGlyphTopV211）：图标层级固定 1（底盘 0 / 蓝层按钮 2 / 四宫格 3）
                icon.layer.zPosition = 1
                addSubview(icon)
                icons.append(icon)
                iconRadii.append(radius)
                iconBaseAngles.append(-90 + offset + CGFloat(i) * step)
            }
        }

        drawRingTracks()
        layoutIcons()
        // 图标与半径都就位了，按真实几何重算心圆底盘（不能放在 computeGeometry 里 ——
        // 那一刻 ringRadii / icons 还是空的，会算成默认 62/40）
        layoutHub()

        // V0.0.26：屏幕上不再有任何提示文字（圆心 / 底部都没有）
        let radiiText = ringRadii.map { String(Int($0)) }.joined(separator: "/")
        let countsText = ringCounts.map(String.init).joined(separator: "/")
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，\(ringCounts.count) 圈，每圈 \(countsText) 个，半径 \(radiiText)，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))，图标 \(Int(icons.first?.bounds.width ?? 0))pt / 间距 46pt 恒定 / 内圈贴中心 64 / 方形图标自适应 / 位置固定记忆 / 速度弹簧跟手 / 进度驱动展开 / 状态位共享内存）（AevonRingFullCircle AevonRingMultiRing AevonRingNativeIconV22 AevonRingAnchor75V21 AevonRingLayoutFitV23 AevonRingCenterTextFreeV24 AevonRingNoLabelV25 AevonRingNoHintV26 AevonRingInnerTightV28 AevonRingHoldRotateV28 AevonRingTwoModeV28 AevonRingDenseV29 AevonRingSpringV30 AevonRingDampV30 AevonRingSquareV31 AevonRingAutoSizeV31 AevonRingPinnedV31 AevonRingSpringV33 AevonNotifyRingV34 AevonRingHopV35 AevonRingGlyphTopV211 AevonRingHubFitV211 AevonRingIcon35V321 AevonHoverJumpV321 AevonGifHoverV322 AevonGifHaloV322 AevonRingIcon40V323 AevonRingUnfoldV323 AevonHubPanelV323）")
    }

    private func drawRingTracks() {
        let path = UIBezierPath()
        for radius in ringRadii {
            path.append(UIBezierPath(arcCenter: ringCenter,
                                     radius: radius,
                                     startAngle: 0,
                                     endAngle: CGFloat.pi * 2,
                                     clockwise: true))
        }
        trackLayer.path = path.cgPath
        trackLayer.frame = bounds
    }

    private func layoutIcons(_ angle: CGFloat? = nil) {
        guard !icons.isEmpty else { return }
        let use = angle ?? rotation
        for (index, icon) in icons.enumerated() {
            guard index < iconRadii.count, index < iconBaseAngles.count else { continue }
            let radians = (iconBaseAngles[index] + use) * .pi / 180
            let radius = iconRadii[index]
            icon.center = CGPoint(x: ringCenter.x + radius * cos(radians),
                                  y: ringCenter.y + radius * sin(radians))
        }
    }

    // MARK: - 阻尼跟手旋转（V0.0.30，V0.0.33 速度弹簧 AevonRingSpringV33）

    /// 启动弹簧追赶：图标角速度向 `rotation` 弹簧收敛，
    /// 收敛完成后自动停掉 CADisplayLink（平时零开销）。
    private func startDamping() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepDamping))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stopDamping() {
        displayLink?.invalidate()
        displayLink = nil
        displayVelocity = 0
    }

    /// V0.0.33 速度弹簧积分器（AevonRingSpringV33）。
    /// 加速度 = 刚度 × 位移 − 阻尼 × 速度；半隐式欧拉积分，60/120Hz 自适应 dt。
    ///
    /// V0.3.18（AevonSpringUnifyV318）：系数不再是一组孤立的 140/16，改由
    /// `AevonSpring.coefficients(response:dampingFraction:)` 从 (0.45, 0.68) 换算 ——
    /// 与划过 / 入场 / 收起是同一条 ζ 谱。140/16 等价于 (0.531, 0.676)，数值接近但
    /// 换算基准不同；统一之后「拖着转」与「划过去」的收尾是同一个劲儿。
    /// k = (2π/0.45)² ≈ 195、c = 2×0.68×2π/0.45 ≈ 19。
    private static let spinSpring = AevonSpring.coefficients(response: 0.45, dampingFraction: 0.68)

    @objc private func stepDamping() {
        guard AevonRingMenu.current === self, !isDismissing else {
            stopDamping()
            return
        }
        let diff = rotation - displayRotation
        if abs(diff) <= 0.05 && abs(displayVelocity) <= 0.4 {
            displayRotation = rotation
            displayVelocity = 0
            layoutIcons(displayRotation)
            stopDamping()
            return
        }
        // dt 用 displayLink 真实帧间隔（秒），120Hz 设备上步长减半，手感一致
        let dt = CGFloat(displayLink?.duration ?? (1.0 / 60.0))
        let stiffness: CGFloat = AevonRingMenu.spinSpring.stiffness
        let damping: CGFloat = AevonRingMenu.spinSpring.damping
        let accel = stiffness * diff - damping * displayVelocity
        displayVelocity += accel * dt
        displayRotation += displayVelocity * dt
        layoutIcons(displayRotation)
    }

    // MARK: - 动画

    /* V0.3.23（AevonRingUnfoldV323）：入场改成**一个进度标量驱动的径向展开**。
     *
     * 0.3.22 及以前是「21 个图标各起一条位置弹簧 + 一条缩放入场关键帧，按 index 错峰
     * 0.018s」—— 那是「同时弹射、逐个落地」。用户给的新录屏不是这样：
     *
     *   录屏 f58~f100：整簇图标**先叠在同一个点上**，然后一起向外铺开、边铺边长大，
     *   铺开过程中「间距 ÷ 图标尺寸」几乎不变 —— 也就是**最终圆盘的一个等比缩小版
     *   在持续放大**。它既不是「图标不动、半径拉开」，也不是「先长大再飞出去」。
     *
     * 所以这里只留一个标量 `progress`（见 AevonRingUnfold）：
     *
     *     半径 = 目标半径 · s(p)     图标缩放 = s(p)     α = α(p)
     *
     * 三条曲线共用一个 s，等比关系天然成立，21 个图标之间也没有任何相位差 ——
     * 录屏里那一簇是**整体**长的，不是一个个长的。
     *
     * 进度 = max(时间曲线, 拖动曲线)：手指划得快就长得快（用户要的「跟手」），
     * 手指停住也会在 0.55s 内自己长完（不会卡在半个盘）。
     */
    private func animateIn() {
        // 0.4.63 — 母版 `0x1a2c4`（圆盘展开，先震再起动画）。
        AevonFloatMotion.haptic(.light, source: "unfold")
        // 遮罩单独一条淡入：它和盘面几何无关，跟着 progress 走只会让背景忽明忽暗
        dimView.alpha = 0
        UIView.animate(withDuration: 0.18, animations: { self.dimView.alpha = 1 })

        unfoldDragProgress = 0
        unfoldProgress = 0
        unfoldStartedAt = CACurrentMediaTime()
        applyUnfold(0)
        startUnfold()
    }

    /// 按进度铺一次盘面。逐帧调用（21 个图标 × position/transform/alpha），
    /// 都是属性直写，不做动画重建 —— 0.3.19 那种「每帧重建 5 条弹道」才是丢帧源。
    private func applyUnfold(_ progress: CGFloat) {
        let s = AevonRingUnfold.scale(at: progress)
        let a = AevonRingUnfold.alpha(at: progress)
        let hub = AevonRingUnfold.hubScale(at: progress)
        let track = AevonRingUnfold.ease(progress)

        trackLayer.opacity = Float(track)
        for (index, icon) in icons.enumerated() {
            guard index < iconRadii.count, index < iconBaseAngles.count else { continue }
            let radians = (iconBaseAngles[index] + rotation) * .pi / 180
            // 半径与尺寸同乘 s ⇒ 整簇是目标布局的等比缩小版（录屏里就是这样）
            let radius = iconRadii[index] * s
            icon.center = CGPoint(x: ringCenter.x + radius * cos(radians),
                                  y: ringCenter.y + radius * sin(radians))
            icon.layer.transform = CATransform3DMakeScale(s, s, 1)
            icon.alpha = a
        }
        hubPlate.transform = CGAffineTransform(scaleX: hub, y: hub)
        hubInner.transform = CGAffineTransform(scaleX: hub, y: hub)
        centerButton.transform = CGAffineTransform(scaleX: hub, y: hub)
        centerGlyph.transform = CGAffineTransform(scaleX: hub, y: hub)
        hubPlate.alpha = a
        hubInner.alpha = a
        centerButton.alpha = a
        centerGlyph.alpha = a
    }

    private func startUnfold() {
        unfoldLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(stepUnfold))
        link.add(to: .main, forMode: .common)
        unfoldLink = link
    }

    private func stopUnfold() {
        unfoldLink?.invalidate()
        unfoldLink = nil
    }

    @objc private func stepUnfold() {
        let elapsed = CACurrentMediaTime() - unfoldStartedAt
        let byTime = AevonRingUnfold.clamp(CGFloat(elapsed / AevonRingUnfold.duration))
        // 只增不减：两条曲线取 max，拖动停下不会让盘面往回缩
        let target = max(byTime, unfoldDragProgress)
        if target > unfoldProgress {
            unfoldProgress = target
            applyUnfold(unfoldProgress)
        }
        if unfoldProgress >= 0.999 {
            finishUnfold()
        }
    }

    /// 落定：把姿态写回**精确值**（逐帧累乘会留 0.001 级误差，收尾要一抹干净），
    /// 然后兑现展开期间记下的划过（`applyHover` 在展开期间只记录不下发）。
    private func finishUnfold() {
        stopUnfold()
        unfoldProgress = 1
        trackLayer.opacity = 1
        for icon in icons {
            icon.layer.transform = CATransform3DIdentity
            icon.alpha = 1
        }
        layoutIcons()
        hubPlate.transform = .identity
        hubInner.transform = .identity
        centerButton.transform = .identity
        centerGlyph.transform = .identity
        hubPlate.alpha = 1
        hubInner.alpha = 1
        centerButton.alpha = 1
        centerGlyph.alpha = 1
        applyHover()
    }

    /// V0.2.88（AevonRingDismissInstantV288）：选中开窗路径必须**瞬时收起**。
    ///
    /// Aevon(61)「打开悬浮窗时依旧会先闪一下，然后出现悬浮窗」取证：选中后走的是
    /// 弹簧收拢 0.3s + 整体淡出 0.18s + **再等 0.18s 才 launchAndOpen** —— 用户看到
    /// 「圆盘消散（闪一下）→ 约 1 秒空档 → 悬浮窗出现」。显形链 0.2.87 已全部瞬时化
    /// 之后，圆盘收起动画就是开窗前屏幕上最后一个过渡，它就是把「从虚到实」的观感
    /// 递给用户的最后一人。选中 = 用户已经做出决定，动画没有信息量，纯负资产。
    /// 抬手未选中 / 旋转松手等被动收起保留原动画（那里动画有「回到桌面」的连续感）。
    private func dismiss(instant: Bool = false) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        isDismissing = true
        /* 0.4.63 — 母版 `0x1ba74`（圆盘收起）。
         *
         * ⛔ 瞬时档**不震**：那条路只有「选中开窗」走，而 `activate` 已经震过
         * 一记（母版 `0x1c350` 选中 / `0x2dd8c` 点击）。母版那几个点是「一个动作
         * 一记」，不是叠加 —— 在这里补一下就会变成连震两下。
         */
        if !instant { AevonFloatMotion.haptic(.light, source: "close") }
        // V0.2.66（AevonRingIdleV266）：静默看门狗随圆盘一起停。
        idleWatch?.invalidate()
        idleWatch = nil
        // V0.2.8（AevonRingDismissNoTouchV208）：收起决定一做出就立刻断触摸 ——
        // 0.18 秒淡出动画期间这个全屏视图不再截住任何点击（Aevon(94) 用户
        // 「桌面无法操作」的最坏情况兜底：动画 completion 万一没跑，触摸通道也已还清）。
        isUserInteractionEnabled = false
        cancelCenterHold()
        clearPointer()
        stopDamping()
        // V0.3.23：展开到一半就收起 —— 逐帧步进必须先停，否则它会把收到的图标
        // 又按进度摆回盘面，盖掉下面的收拢动画。
        stopUnfold()
        unfoldProgress = 1
        /* V0.3.20（AevonKeyframeHoverV320）：先把划过关键帧**整体摘掉**再让「吸附回圆心」
         * 接管 transform。关键帧是 `fillMode: .forwards`，只清状态不摘动画的话，
         * 下面 `icon.transform = scale(0.1)` 会被在途动画盖住 —— 图标就不往圆心收了。 */
        for icon in icons {
            // V0.3.22：收起档**不要抹平 transform** —— 抬起 46pt 的图标要
            // 从这里平滑地被吸回圆心，而不是先掉回原位再飞。
            icon.resetHover(snap: false)
        }
        // V0.3.19（AevonHoverTrailV319）：收起前把本轮划过汇总打一次（逐条日志已改汇总）
        flushHoverSummary()
        // V0.3.20（AevonFrameProbeV320）：帧率自证也在这里结账
        flushFrameWatch()
        AevonRingMenu.current = nil
        // V0.2.50（AevonRingGripV250）：圆盘收起 → 把手重新露出来
        AevonRingGrip.setVisible(true)
        // V0.0.24：立刻解除「吞掉那根手指」的接管，把事件通道还给 App
        AevonEdgeEntry.ringDidDismiss()
        // V0.2.88（AevonRingDismissInstantV288）：瞬时档 —— 零动画直接摘除。
        if instant {
            removeFromSuperview()
            AevonLog.info("[圆盘] 选中收起：瞬时摘除，无弹簧无淡出（AevonRingDismissInstantV288）")
            return
        }
        // V0.0.30：图标被圆心「吸」回来（弹簧收拢），比整体淡出更有生命感
        // V0.3.18（AevonSpringUnifyV318）：同一条 ζ 谱里收得最紧的一档（response 0.32 / ζ 0.85）——
        // 收起是「决定已经做完」，不需要回摆，只要不硬切。
        let spring = AevonSpring.params(response: 0.32,
                                        dampingFraction: max(hoverZ, 0.85),
                                        initialVelocity: CGVector(dx: 0.30, dy: 0.30))
        for icon in icons {
            let animator = UIViewPropertyAnimator(duration: 1.0, timingParameters: spring)
            animator.addAnimations {
                icon.center = self.ringCenter
                icon.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                icon.alpha = 0
            }
            animator.startAnimation()
        }
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
            self.centerButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            self.centerGlyph.alpha = 0
            self.hubPlate.alpha = 0
            self.hubInner.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    // MARK: - 统一指针处理（V0.0.28）
    //
    // 唤出圆盘的那根手指（global / strip / window）与事后新按的手指（local）
    // 走完全相同的状态机，只是 source 不同 —— 这样「手指不用抬起就能选图标」。
    //
    // 两种模式：
    //   · 选择（默认）：指到哪个图标高亮哪个，松手开窗；
    //   · 旋转（圆心按住 1 秒进入）：顺 / 逆时针都跟手转，期间除了圆心都不能选。

    /// 圆盘被呼出时立刻调用，`point` 是窗口坐标。
    func beginRemoteTracking(at point: CGPoint, source: String) {
        /* V0.3.23（AevonRingUnfoldV323）：这个点就是「圆盘从哪儿长出来」的原点。
         * 拖动曲线用它算位移 —— 手指从边缘往里划，划得越远盘长得越开。 */
        unfoldOrigin = point
        handlePointerBegan(at: point, source: source)
    }

    func remoteMoved(to point: CGPoint, source: String, authoritative: Bool = false) {
        handlePointerMoved(to: point, source: source, authoritative: authoritative)
    }

    func remoteEnded(at point: CGPoint, source: String) {
        handlePointerEnded(at: point, source: source)
    }

    /// V0.3.16（AevonOwnLiftV316）：**权威抬手** —— 来自召唤那根手指所属的识别器。
    ///
    /// 与 `remoteEnded` 的唯一差别：不过 `claimPointer` 的「原通道静默 ≥0.12s」交换闸。
    /// 那道闸是为「指针从一条喂料通道换到另一条」设计的（两条通道报的坐标有差值，
    /// 必须确认原通道已死才敢抢）。抬手帧不属于这个场景：它就是这根手指的终点，
    /// 谁先到谁说了算 —— 被闸吞掉只会让圆盘多钉 1 秒。
    func remoteLift(at point: CGPoint, source: String) {
        handlePointerEnded(at: point, source: source, authoritative: true)
    }

    func remoteCancelled(source: String) {
        handlePointerCancelled(source: source)
    }

    /// V0.0.29：当前是否有活动指针（与 `handlePointerBegan` 的去重判定同口径）。
    /// 圆盘展开期间，新落下的手指只有在没有活动指针时才接管为当前指针。
    var isPointerActive: Bool {
        return !pointerSource.isEmpty &&
               CACurrentMediaTime() - pointerLastEventAt < AevonRingMenu.pointerStaleInterval
    }

    /// 这条通道现在能不能代表当前指针；能就直接通过，不能就按静默时长决定要不要交接。
    ///
    /// V0.2.16（AevonRingPointerHandoffV216）：**指针不能死绑在一条通道上。**
    ///
    /// Aevon(102) 的账（15 次呼盘：`systemgesture` 9 / `appedge` 4 / `strip` 2）：
    /// 呼盘时把指针绑成呼盘来源的字符串，但 `systemgesture` 那个字符串在这一版**没有
    /// 任何活着的喂料方** —— 唯一用它的 `AevonSystemGestureV105` 早在 0.1.13 就停手了
    /// （探针 P7-4 的「愿接=0」就是它）。于是那 9 次呼盘之后：
    ///   · 手指继续往圆心滑 → 一条 moved 都进不来，图标不高亮也不旋转 = 「选不中」；
    ///   · 抬手 → ended 也进不来 → 指针一直挂在圆盘上，只能等 1.2 秒超时后
    ///     由下一次触摸（圆盘自己的 `touchesBegan`）接管 = 「必须抬手再摸一次」。
    ///
    /// 现在：原通道静默 ≥0.12 秒就允许另一条通道接手，并**重设角度基线**
    /// （两条通道报的坐标有差，不重设会被算成一次旋转，圆盘会跳一下）。
    /// 原通道一直在动就抢不走，所以「同一次滑动被算两遍」的去重语义没丢。
    private func claimPointer(source: String, at point: CGPoint) -> Bool {
        let now = CACurrentMediaTime()
        if pointerSource == source { return true }
        let silence = now - pointerLastEventAt
        if !pointerSource.isEmpty, silence < AevonRingMenu.pointerHandoffInterval { return false }
        let previous = pointerSource
        pointerSource = source
        pointerPoint = point
        pointerAngle = angle(from: ringCenter, to: point)
        pointerLastEventAt = now
        // V0.2.18（AevonRingFingerDownV218）：换通道继续喂，说明这根手指还在屏上。
        isFingerDown = true
        if isInsideRingArea(point) { pointerEverInsideRing = true }
        if !previous.isEmpty, now - pointerHandoffLogAt > 0.5 {
            pointerHandoffLogAt = now
            AevonLog.info("[圆盘] 指针通道交接 \(previous) → \(source)（原通道已静默 \(Int(silence * 1000))ms，重设角度基线、不产生旋转）（AevonRingPointerHandoffV216）")
        }
        return true
    }

    private func handlePointerBegan(at point: CGPoint, source: String) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        let now = CACurrentMediaTime()
        // 上一根手指还在操作就忽略新的（超时视为通道漏发 ended，允许新手指接管）
        if !pointerSource.isEmpty, now - pointerLastEventAt < AevonRingMenu.pointerStaleInterval {
            return
        }
        pointerSource = source
        pointerPoint = point
        pointerAngle = angle(from: ringCenter, to: point)
        pointerLastEventAt = now
        isFingerDown = true
        // V0.3.23：没有 `beginRemoteTracking` 的召唤路径（窗口侧 / 识别器侧）也要有原点
        if unfoldOrigin == nil { unfoldOrigin = point }
        pointerEverInsideRing = isInsideRingArea(point)
        // 新手指落下来，重新允许「按住圆心 1 秒」切换模式
        centerHoldSuppressed = false
        // 0.1.19 — 固定住的盘被手指再碰一次，就交回这一次触摸决定去留
        // （点图标 → 开窗；点盘外 → 收起）。
        pinned = false
        // 0.1.18 — 见 `hoverArmed`：呼盘那根手指先不许高亮，动过 12 pt 再说。
        hoverArmed = (source == "local")
        hoverOrigin = point
        if rotating || !hoverArmed {
            setHovered(nil)
        } else {
            setHovered(icon(at: point))
        }
        updateCenterHold(at: point)
    }

    private func handlePointerMoved(to point: CGPoint, source: String,
                                    authoritative: Bool = false) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        if authoritative {
            /* V0.3.17（AevonOwnFeedV317）：权威喂料 —— 坐标来自**持有这根手指的识别器**。
             *
             * 为什么可以不过交换闸：`claimPointer` 的 0.12 秒静默要求是给「两根手指经
             * 两条喂料通道换车道」用的。识别器与手指一对一，它报的坐标不需要旁证。
             * Aevon(94) 里 9 次成功交接时刻全部落在 120/123/124/128ms —— 正好是那道闸，
             * 也就是说每次展开都必然先盲 0.12 秒；手指在这段时间里停下，这一次就永久失明。
             *
             * 通道名变了要重设角度基线：两条通道报的坐标有差值，不重设会被算成一次
             * 旋转（指针轻轻一动圆盘就转一下）。 */
            if pointerSource != source {
                pointerSource = source
                pointerAngle = angle(from: ringCenter, to: point)
            }
        } else {
            guard claimPointer(source: source, at: point) else { return }
        }
        pointerPoint = point
        pointerLastEventAt = CACurrentMediaTime()
        isFingerDown = true
        if isInsideRingArea(point) { pointerEverInsideRing = true }
        // 0.1.18 — 走够死区才解锁高亮（呼盘那根手指）。
        if !hoverArmed,
           hypot(point.x - hoverOrigin.x, point.y - hoverOrigin.y) >= AevonRingMenu.hoverDeadband {
            hoverArmed = true
        }
        /* V0.3.23（AevonRingUnfoldV323）：**跟手**。
         * 拖动曲线只增不减（`max`）—— 手指往回撤时盘面不会跟着缩，
         * 否则「划过头再修一下」会让 21 个图标整体往回抽，比不跟手更难看。 */
        if unfoldProgress < 1, let origin = unfoldOrigin {
            let travelled = hypot(point.x - origin.x, point.y - origin.y)
            let byDrag = AevonRingUnfold.dragProgress(distance: travelled)
            if byDrag > unfoldDragProgress { unfoldDragProgress = byDrag }
        }

        let currentAngle = angle(from: ringCenter, to: point)
        var delta = currentAngle - pointerAngle
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        pointerAngle = currentAngle

        if rotating {
            // 旋转模式：顺时针 / 逆时针都跟手转；画面上不选中任何图标。
            // V0.0.30：不直接贴手指角度，走阻尼追赶（图标有「韧劲」的跟随感）
            if abs(delta) > 0.01 {
                rotation += delta
                startDamping()
            }
            setHovered(nil)
        } else {
            setHovered(hoverArmed ? icon(at: point) : nil)
        }
        // 手指离开圆心就解除「刚切换过」的抑制，也取消还没到 1 秒的计时
        if !isInsideCenter(point) { centerHoldSuppressed = false }
        updateCenterHold(at: point)
    }

    /// 手指**离开屏幕**。圆盘收不收，全部在这一处决定（V0.2.18 / AevonRingCloseOnLiftV218）。
    ///
    /// 用户 Aevon(104) 把规则讲清楚了，这里逐条对上：
    ///   · 滑出圆盘但手指没离开屏幕 → **什么都不做**（不叫「在圆盘外」，不许收）；
    ///   · 抬手时在盘外 → 收；
    ///   · 抬手时落在图标之间的**间隙**里（盘内但没有图标）→ 收；
    ///   · 抬手时正好在图标上 → 用浮窗打开它；
    ///   · 抬手时在圆心 → 打开应用面板。
    /// 换句话说：**只有抬手这一件事会收起圆盘**（加上选中开窗、圆心面板、三指急救三条显式路径）。
    private func handlePointerEnded(at point: CGPoint, source: String,
                                    authoritative: Bool = false) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        /* V0.3.16（AevonOwnLiftV316）：`authoritative == true` 只由自建识别器腿的抬手
         * 回调传入（`remoteLift`）。识别器与手指是一对一的，它报的抬手不需要任何
         * 「原通道静默时长」旁证 —— 那道 0.12s 闸是给「指针换喂料通道」用的
         * （两条通道坐标有差值，必须确认原通道已死），抬手帧套上去只会被静默吞掉。
         * Aevon(93) 的 16 次「圆盘钉住 1 秒」全部落在这一条上。 */
        if !authoritative {
            if !claimPointer(source: source, at: point) {
                /* V0.3.16（AevonOwnLiftV316）：被交换闸拒 = 抬手帧到了但通道没换过来。
                 * 以前这里是静默 return，Aevon(93) 那 16 次「圆盘钉住 1 秒」在日志上
                 * 完全空白，分不清到底是「ended 没到」还是「到了被拒」。留这一条，
                 * 下一份日志一眼可判；限流 0.5s 防刷。 */
                let now = CACurrentMediaTime()
                if now - AevonRingMenu.lastLiftRejectLogAt > 0.5 {
                    AevonRingMenu.lastLiftRejectLogAt = now
                    let silence = pointerLastEventAt > 0
                        ? Int((now - pointerLastEventAt) * 1000) : -1
                    AevonLog.info("[圆盘] 抬手帧被通道交换闸拒（来源 \(source)，"
                        + "当前指针 \(pointerSource.isEmpty ? "空" : pointerSource)，"
                        + "静默 \(silence)ms）→ 圆盘只能等看门狗（AevonOwnLiftV316）")
                }
                return
            }
        }
        cancelCenterHold()
        pointerPoint = point
        if isInsideRingArea(point) { pointerEverInsideRing = true }
        // 取证用：这根手指这一次有没有进过盘内（0.2.17 起不再影响「收不收」，
        // 只写进日志 —— 用户报「刚划出来就没了」时，靠它区分是抬手太早还是触发太晚）
        let everInside = pointerEverInsideRing
        let landing = isInsideRingArea(point) ? "盘内" : "盘外"
        clearPointer()

        // ① 旋转模式：按在圆心松手 = 退出旋转；其余一律收起（与选择模式同一条规则）
        if rotating {
            if isInsideCenter(point) {
                setRotating(false, at: point)
                AevonLog.info("[圆盘] 圆心松手，退出旋转模式，回到选图标（AevonRingHoldRotateV28）")
                return
            }
            AevonLog.info("[圆盘] 旋转中松手（\(landing)，来源 \(source)），收起圆盘（AevonRingCloseOnLiftV218）")
            setHovered(nil)
            dismiss()
            return
        }

        // ② 选择模式：落在图标上就开窗
        // 0.1.18 — `hoverArmed == false`（呼盘那根手指一动没动）= 他只是想看看，
        // 这一下按「未选中」处理，不能让「展开就松手」变成「打开了一个 App」。
        if hoverArmed, let icon = icon(at: point) {
            setHovered(nil)
            activate(icon)
            return
        }

        // ③ 落在圆心：打开完整面板（V0.0.30 起面板只显示可开浮窗的 App）
        if isInsideCenter(point) {
            AevonLog.info("[圆盘] 圆心被点击，打开应用面板")
            dismiss()
            AevonEdgeEntry.openPanel()
            return
        }

        // ④ 落在盘外、或落在盘内图标之间的间隙：**一律收起**
        //
        // 0.0.28 ~ 0.2.16 这里是「从没进过圆盘（就是唤出圆盘那一下）→ 圆盘保持展开等下一次触摸」
        // （旧标记 AevonRingKeepOpenV28，0.2.17 起作废）。用户 Aevon(103) 的结论很直接：
        // 松开就该收起 —— 圆盘的用法是「按住不松、直接滑到图标上再松手」（0.2.16 的
        // 指针通道交接就是为了这条路），没松手就不该有第二个状态。
        // 留着「保持展开」只有一个后果：呼盘那一下抬起，屏上多一个必须再点一次才消失的圆盘。
        //
        // Aevon(104) 补充的语义（本版写进日志，免得再猜）：**只有抬手才会收**。
        // 呼盘那一刻手指贴在右缘、离圆心一百多 pt（本来就在盘外），这不叫「手指在圆盘外」；
        // 手指继续按着往盘里滑的整段过程，圆盘一动不动，直到抬手才判定。
        // 0.1.19 — **展开后固定**（母版 `AutoPin`）：抬手没选中图标就把盘留在原地，
        // 用另一根手指 / 再点一次选。0.1.18 及以前这里是直接收起，于是「划出来以后
        // 想换手再选」这件事根本做不到。
        if autoPin {
            pinned = true
            AevonLog.info("[圆盘] 抬手未选中（\(landing)·间隙，来源 \(source)），"
                + "「展开后固定」开着 → 固定在 ("
                + String(format: "%.0f,%.0f", ringCenter.x, ringCenter.y)
                + ") 不收起，等下一次触摸（AevonRingAutoPinV119）")
            setHovered(nil)
            return
        }
        AevonLog.info("[圆盘] 抬手未选中（\(landing)·间隙，来源 \(source)，进过盘内=\(everInside ? "是" : "否")），收起圆盘（AevonRingLiftDismissV217 AevonRingCloseOnLiftV218）")
        setHovered(nil)
        dismiss()
    }

    private func handlePointerCancelled(source: String) {
        if source != pointerSource {
            // 不是当前指针那条通道报的取消：只有原通道已经静默（它死了）才顺手清，
            // 否则会误清一条还在动的指针。
            guard CACurrentMediaTime() - pointerLastEventAt >= AevonRingMenu.pointerHandoffInterval else { return }
        }
        cancelCenterHold()
        clearPointer()
        // V0.2.18（AevonRingCloseOnLiftV218）：**取消 ≠ 抬手**。
        //
        // 取消是「这条通道不投了」的意思（系统手势识别器被别的识别器抢走、App 切后台…），
        // 手指通常还压在屏幕上。把它当成抬手，等于让三个定时器重新获得「替圆盘收」的权力，
        // 用户看到的就是「我手指没离开，圆盘自己收了」。这里保留「手指在屏上」的判断，
        // 真正的收尾交给 30 秒静默安全网，或者下一根手指的 touchesBegan。
        isFingerDown = true
    }

    private func clearPointer() {
        // V0.3.19（AevonHoverTrailV319）：这根手指的划过明细在这里结账（每根手指一条）
        flushHoverSummary()
        pointerSource = ""
        pointerEverInsideRing = false
        pointerLastEventAt = 0
        // V0.2.18（AevonRingFingerDownV218）：指针没了 = 这根手指已经离开屏幕（或圆盘已收起）。
        // 外面三个定时器看到这一位变假，才会重新使用「强制收起」这一档。
        isFingerDown = false
    }

    // MARK: - 圆心按住 1 秒：开 / 关旋转模式

    private func distanceToCenter(_ point: CGPoint) -> CGFloat {
        let dx = point.x - ringCenter.x
        let dy = point.y - ringCenter.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func isInsideCenter(_ point: CGPoint) -> Bool {
        return distanceToCenter(point) <= AevonRingMenu.centerHitRadius
    }

    /// 圆盘的外沿（最外圈半径 + 图标半宽 + 一点余量）—— 走出这个范围的松手算「取消」
    private var ringOuterLimit: CGFloat {
        let outer = ringRadii.max() ?? 62
        return outer + AevonRingMenu.iconSize / 2 + 20
    }

    private func isInsideRingArea(_ point: CGPoint) -> Bool {
        return distanceToCenter(point) <= ringOuterLimit
    }

    private func updateCenterHold(at point: CGPoint) {
        guard !centerHoldSuppressed else {
            cancelCenterHold()
            return
        }
        if isInsideCenter(point) {
            if centerHoldTimer == nil { scheduleCenterHold() }
        } else {
            cancelCenterHold()
        }
    }

    private func scheduleCenterHold() {
        cancelCenterHold()
        let timer = Timer(timeInterval: AevonRingMenu.centerHoldDuration, repeats: false) { [weak self] _ in
            guard let self = self, AevonRingMenu.current === self, !self.isDismissing else { return }
            self.centerHoldTimer = nil
            guard self.isInsideCenter(self.pointerPoint) else { return }
            // 切换后必须先离开圆心（或重新按下）才能再切一次，避免按着不动来回抖
            self.centerHoldSuppressed = true
            let turnOn = !self.rotating
            self.setRotating(turnOn, at: self.pointerPoint)
            AevonLog.info("[圆盘] 圆心按住 1 秒 → \(turnOn ? "进入旋转模式（顺 / 逆时针都能转）" : "退出旋转模式（可以选图标）")（AevonRingHoldRotateV28）")
        }
        // 手指按住时 RunLoop 处于 tracking 模式，必须挂 common modes
        RunLoop.main.add(timer, forMode: .common)
        centerHoldTimer = timer
    }

    private func cancelCenterHold() {
        centerHoldTimer?.invalidate()
        centerHoldTimer = nil
    }

    private func setRotating(_ on: Bool, at point: CGPoint?) {
        guard rotating != on else { return }
        rotating = on
        updateCenterAppearance()
        if on {
            pulseRotationFeedback()
            setHovered(nil)
            return
        }
        AevonFloatMotion.haptic(.light, source: "rotate-off")
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 0.86, 1.0]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.3
        centerButton.layer.add(pulse, forKey: "centerPulse")
        if let point = point, !isInsideCenter(point) {
            setHovered(icon(at: point))
        } else {
            setHovered(nil)
        }
    }

    /// 圆心按钮外观：蓝 + 四宫格 = 选择模式；青绿 + 旋转箭头 = 旋转模式。
    /// 屏幕上没有文字，这个颜色 / 图标就是**唯一的模式指示**。
    private func updateCenterAppearance() {
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        let name = rotating ? "arrow.triangle.2.circlepath" : "square.grid.2x2.fill"
        if let symbol = UIImage(systemName: name, withConfiguration: config) {
            // V0.2.11（AevonRingGlyphTopV211）：换的是独立图标层，不是按钮的 image
            centerGlyph.image = symbol
        }
        centerGlyph.tintColor = .white
        // V0.2.10（AevonRingHubV210）：底色改由渐变层承担，这里换的是渐变的两个端点。
        let top = rotating
            ? UIColor(red: 0.26, green: 0.88, blue: 0.74, alpha: 0.98)
            : UIColor(red: 0.30, green: 0.66, blue: 1.00, alpha: 0.98)
        let bottom = rotating
            ? UIColor(red: 0.05, green: 0.52, blue: 0.44, alpha: 0.98)
            : UIColor(red: 0.07, green: 0.36, blue: 0.88, alpha: 0.98)
        centerGradient.colors = [top.cgColor, bottom.cgColor]
        hubInner.layer.borderColor = (rotating
            ? UIColor(red: 0.25, green: 0.92, blue: 0.78, alpha: 0.40).cgColor
            : UIColor(white: 1.0, alpha: 0.10).cgColor)
        centerButton.layer.shadowColor = (rotating
            ? UIColor(red: 0.20, green: 0.95, blue: 0.80, alpha: 1.0)
            : UIColor.black).cgColor
        centerButton.layer.shadowOpacity = rotating ? 0.75 : 0.45
    }

    /// 进入旋转模式的反馈：一圈涟漪 + 轻度触感 + 圆心轻微放大。
    private func pulseRotationFeedback() {
        AevonFloatMotion.haptic(.medium, source: "rotate-on")
        guard let radius = ringRadii.first, radius > 0 else { return }
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = UIBezierPath(arcCenter: ringCenter,
                                 radius: radius,
                                 startAngle: 0,
                                 endAngle: .pi * 2,
                                 clockwise: true).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(red: 0.25, green: 0.92, blue: 0.78, alpha: 1.0).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer.addSublayer(ring)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0]
        fade.keyTimes = [0, 0.22, 1]
        fade.duration = 0.55
        ring.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ring.removeFromSuperlayer()
        }

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.18, 1.0]
        pop.keyTimes = [0, 0.45, 1]
        pop.duration = 0.34
        centerButton.layer.add(pop, forKey: "centerPop")
    }

    /// 高亮「松手就会打开」的那个图标。
    ///
    /// V0.0.25 起**屏幕上不再出现任何文字**——选中只靠放大 + 蓝色描边 + 蓝色光晕，
    /// 旋转模式下则完全不选中（`rotating` 时调用方只传 nil）。
    /// V0.3.17（AevonHoverTrackV317）：当前高亮的 App。
    ///
    /// 单独存一份而不是「问图标自己」，是因为这里要判的是**状态切换**：`setHovered`
    /// 每帧都会调一次，只有真的换了一个图标才是用户看得见的「划过」。
    private var hoveredBundleID = ""

    /// V0.3.19：当前高亮图标本体 —— 命中滞回要用它。
    private var hoveredIcon: AevonRingIcon?

    /// V0.3.19（AevonHoverTrailV319）：本轮划过计数与最近几个名字 —— 日志降载用。
    ///
    /// 以前每划过一次就写一条日志，而 `AevonLog` 每次都要新建 `DateFormatter`、
    /// 打开 / 关闭一次文件、再 `stat` 一次。Aevon(95) 定量：峰值 **62 行/秒**，
    /// 全落在触摸热路径上，120Hz 下 8.3ms 一帧，这条必掉帧。
    /// 现在只在抬手 / 收起时打一条汇总，明细保留最近 8 个名字。
    private var hoverSwitchCount = 0
    private var hoverRecentNames: [String] = []

    /// 本次展开的阻尼比。在 `present` 里读一次缓存 —— `AevonPrefs` 走 CFPreferences，
    /// 是跨进程 IPC，放进 `setHovered` 这种逐帧路径会拖慢触摸响应。
    var hoverZ: Double = AevonSpring.defaultDampingFraction

    /// 0.2.59 — 划过预热（见 `setHovered` 里的调用点）。
    ///
    /// 令牌法的理由：只有「同一个图标停够 0.18 s」才值得热。换图标就把令牌加一，
    /// 之前排上的那一拍到点时会发现令牌变了、直接放弃 —— 不额外持有任何对象。
    ///
    /// 为什么不直接调 `AevonOwnWarm`：这个文件**同时编进宿主与设置包**。
    /// 宿主侧的真身在 `AevonScene.m`（`Aevon.dylib`），设置进程里根本没有那个
    /// dylib —— 直接声明会链接成空符号，设置里点一下「预览」划过图标就崩。
    /// 所以现场 `dlsym` 找，找不到就当没有（设置包里恒为 nil，行为回到 0.2.58）。
    private typealias AevonWarmFn = @convention(c) (AnyObject) -> Int
    private static var warmToken = 0
    private static let warmSymbol: AevonWarmFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AevonOwnWarm") else {
            return nil
        }
        return unsafeBitCast(sym, to: AevonWarmFn.self)
    }()

    private func scheduleWarm(_ bundleID: String) {
        guard bundleID.count > 2 else { return }
        guard AevonRingMenu.warmSymbol != nil else { return }
        AevonRingMenu.warmToken &+= 1
        let token = AevonRingMenu.warmToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self else { return }
            guard AevonRingMenu.warmToken == token else { return }
            guard self.hoveredBundleID == bundleID else { return }
            guard let warm = AevonRingMenu.warmSymbol else { return }
            _ = warm(bundleID as NSString)
        }
    }

    private func setHovered(_ icon: AevonRingIcon?) {
        let newID = icon?.bundleID ?? ""
        guard newID != hoveredBundleID else { return }
        hoveredBundleID = newID
        hoveredIcon = icon
        if let icon = icon {
            /* 0.4.63 — 母版 `0x4c334`：**手指滑过图标**一记。
             *
             * 那一处的判据是「选中 index 变了就震，`0x3e7 = 999` 是空位哨兵，
             * 回到空位不震」—— 换成这里的说法就是：`newID` 非空才算一次划过，
             * 离开所有图标（空 ID）什么都不做。上面那条 `guard` 已经把「同一个
             * 图标报两次」挡住了，所以手指停在某个图标上不会持续震。
             */
            AevonFloatMotion.haptic(.light, source: "hover")
            /* V0.3.19（AevonHoverTrailV319）：只在内存里记一笔，**不写盘**。
             * 逐条「划过 X」日志的成本见 `hoverSwitchCount` 的注释。 */
            hoverSwitchCount += 1
            hoverRecentNames.append(icon.displayName)
            if hoverRecentNames.count > 8 { hoverRecentNames.removeFirst() }
            /* 0.2.59 — 划过预热。
             *
             * Aevon(200)：抖音从圆盘打开时 `own start … t=1ms` 之后要等
             * **749 ms** 才 `own scene up`，那一段全在等 App 进程起来
             * （`app: boot pid=26158` 就落在中间）。用户量的是「点了到看见」，
             * 所以把这段挪到手指还停在图标上的时候去付：悬停满 0.18 s 就让宿主
             * 用 `launchIntent=4` 把进程拉起来（不建 scene、不上屏），松手选中时
             * 往往已经在跑，`own start` 只剩建 scene 那一小截。
             *
             * 只在真的「停下来了」才热：换一个图标就把令牌作废，快速划过整排
             * 不会有任何启动 —— 那时用户还没决定，替他把半个桌面拉起来是错的。
             */
            scheduleWarm(icon.bundleID)
        }
        applyHover()
    }

    /// V0.3.20（AevonKeyframeHoverV320）：**只比目标态**，一次切换最多起两条动画。
    ///
    /// 旧版这里是「按余韵队列逐档下发」，一次切换要重建 5 条弹簧弹道、每条都
    /// `finishAnimation(at: .current)` 取呈现值；现在每个图标只有「该抬起 / 该落地」
    /// 一个布尔量，没变就一个字都不动。
    ///
    /// 「先后起伏」不需要余韵队：手指扫过时 A 升起、B 在 72ms 后升起、A 同时开始落地
    /// —— 波峰自然往前走。而且**每个图标都一定会落地**（`landHover` 是 250ms 定长
    /// 关键帧，带一记余弹），不存在挂在空中。
    private func applyHover() {
        /* V0.3.23（AevonRingUnfoldV323）：展开期间**只记录、不下发**。
         * 图标此刻的缩放由 `applyUnfold` 独占 `layer.transform`，划过关键帧再来写它
         * 就会打架（抬起 46pt 的图标带着 0.4 的缩放飞出去）。
         * 展开结束的 `finishUnfold` 会再调一次这里，把期间记下的那一笔兑现。 */
        guard unfoldProgress >= 1 else { return }
        for item in icons {
            let want = (item === hoveredIcon)
            guard want != item.hoverLifted else { continue }
            if want {
                item.riseHover()
            } else {
                item.landHover()
            }
        }
    }

    /// V0.3.20（AevonKeyframeHoverV320）：展开 / 重建列表时把所有划过动画归零。
    private func resetHoverWave() {
        hoveredBundleID = ""
        hoveredIcon = nil
        hoverSwitchCount = 0
        hoverRecentNames.removeAll()
        for icon in icons {
            icon.resetHover()
        }
    }

    /// V0.3.19：本轮划过汇总（只在抬手 / 收起时调一次）。
    private func flushHoverSummary() {
        guard hoverSwitchCount > 0 else { return }
        let tail = hoverRecentNames.suffix(6).joined(separator: "→")
        AevonLog.info("[圆盘] 本轮划过 \(hoverSwitchCount) 次（最后几个：\(tail)）"
            + "（AevonKeyframeHoverV320）")
        hoverSwitchCount = 0
        hoverRecentNames.removeAll()
    }

    // MARK: - 本地触摸（第二根手指 / 抬手后再按）

    /// V0.2.69（AevonRingIdleFixV269）：UIKit 层活跃触摸计数 —— 静默看门狗的
    /// 「ended 真漏发」实判。touches 家族是 UIResponder 硬通道（指针喂料通道
    /// 会漏最后一报，UIKit 不会），计数为 0 = 手指真不在圆盘上。
    private var uiKitTouchCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        uiKitTouchCount += touches.count
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        handlePointerBegan(at: point, source: "local")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        handlePointerMoved(to: point, source: "local")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        uiKitTouchCount = max(0, uiKitTouchCount - touches.count)
        guard !isDismissing else { return }
        let point = touches.first?.location(in: self) ?? pointerPoint
        handlePointerEnded(at: point, source: "local")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        uiKitTouchCount = 0
        handlePointerCancelled(source: "local")
    }

    // MARK: - 选中开窗

    /// 0.0.42 移植接缝：设置页预览宿主注入的选中接管。返回 true = 已接管，
    /// 圆盘不执行开窗（预览页里点图标应该弹 toast，而不是真的开 App）。
    /// SpringBoard 侧不设置它，走原来的路径，一个字都不变。
    static var activateHook: ((AevonRingIcon) -> Bool)?

    private func activate(_ icon: AevonRingIcon) {
        if AevonRingMenu.activateHook?(icon) == true { return }
        // 0.4.63 — 母版 `0x1c350`（选中）/ `0x2dd8c`（点击）：一个动作一记。
        // 用 medium 而不是 hover 那档 light，是为了让「选中」和「划过」摸得出差别；
        // 强度仍是全局那一个 0.5（母版只有一个 VibrateIntensity）。
        AevonFloatMotion.haptic(.medium, source: "pick")
        let bundleID = icon.bundleID
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏不是 App，直接执行动作，不开窗。
        if AevonQuickAction.isAction(bundleID) {
            AevonLog.info("[圆盘] 选中 \(icon.displayName) (\(bundleID))，执行快捷动作并收起圆盘"
                + "（AevonQuickActionV262）")
            icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            AevonEdgeEntry.noteSelectionCooldown()
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                AevonQuickAction.perform(bundleID: bundleID)
            }
            return
        }
        AevonLog.info("[圆盘] 选中 \(icon.displayName) (\(bundleID))，打开浮窗并收起圆盘")
        icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        // V0.2.8（AevonSelectionCoolV208）：选中后 1.5 秒内 global 兜底不呼盘 ——
        // Aevon(94) 21:53:45 实证：选中开窗后 0.65 秒同一根手指的移动又呼了一次盘。
        AevonEdgeEntry.noteSelectionCooldown()
        // V0.2.88（AevonRingDismissInstantV288）：收起瞬时化 + 开窗不再等 0.18s。
        // 原来「弹簧 0.3s + 淡出 0.18s + 延迟 0.18s 才开窗」= 用户看到的
        // 「先闪一下（圆盘消散），空档约 1 秒，然后悬浮窗才出现」。防重复呼盘
        // 由 noteSelectionCooldown 的 1.5s 冷却继续兜底，0.18s 延迟没有第二个职责。
        dismiss(instant: true)
        AevonWindowManager.launchAndOpen(bundleID: bundleID)
    }

    // MARK: - 几何工具

    /// 命中哪个图标：先按角度找该圈上最近的一个，再校验弧长距离。
    private func icon(at point: CGPoint) -> AevonRingIcon? {
        guard !icons.isEmpty else { return nil }
        let dx = point.x - ringCenter.x
        let dy = point.y - ringCenter.y
        let distance = (dx * dx + dy * dy).squareRoot()
        var pointAngle = atan2(dy, dx) * 180 / .pi
        if pointAngle < 0 { pointAngle += 360 }

        var best: AevonRingIcon?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (index, icon) in icons.enumerated() {
            guard index < iconRadii.count, index < iconBaseAngles.count else { continue }
            let radius = iconRadii[index]
            // 径向容差：半圈间距（至少图标半径）—— V0.0.31 用图标实际尺寸（自适应后各圈不同）
            //
            // V0.2.18（AevonRingHitStableV218）：这里必须用 `bounds`，不能用 `frame`。
            // `frame` 会跟着 transform 变 —— 悬停放大从 1.18 提到 1.30 之后，
            // 被放大的那个图标判定半径会跟着膨胀 30%，隔壁图标会被它抢走，
            // 表现是「手指明明在这个图标上，高亮的却是旁边那个」。
            // `bounds` 不受 transform 影响，永远是布局时的原始尺寸。
            let baseSize = icon.bounds.width
            let tolerance = max(baseSize * 0.78, 28)
            guard abs(distance - radius) <= tolerance else { continue }
            var iconAngle = (iconBaseAngles[index] + rotation).truncatingRemainder(dividingBy: 360)
            if iconAngle < 0 { iconAngle += 360 }
            var delta = abs(iconAngle - pointAngle)
            if delta > 180 { delta = 360 - delta }
            // 角距换算成弧长（pt），再挑最近的
            let arc = delta * .pi / 180 * radius
            if arc < bestScore {
                bestScore = arc
                best = icon
            }
        }
        /* V0.3.19（AevonHoverTrailV319）：现任优先（命中滞回）。
         *
         * 没有这一段时，指针压在两个图标的角平分线上，「最近的那个」会逐帧翻转 ——
         * Aevon(95) 实测 765 次划过里 112 次是 A→B→A（15%），最短 8ms 一个来回。
         * 规则：现任图标只要还在自己放大幅度内（1.35 倍命中半径）就继续占有，
         * 除非别的图标在弧长上比它近 `hoverHysteresisGap` pt 以上。
         * 注意判在 `guard let candidate` 之前 —— 否则「现任还在范围内、但没人是候选」
         * 的那一帧会返回 nil，高亮凭空灭一下。 */
        if let cur = hoveredIcon, cur !== best,
           let curArc = arcScore(of: cur, distance: distance, pointAngle: pointAngle) {
            let reach = cur.bounds.width * AevonRingMenu.hitFactor * AevonRingMenu.hoverHysteresisReach
            if curArc <= reach, bestScore > curArc - AevonRingMenu.hoverHysteresisGap {
                return cur
            }
        }
        guard let candidate = best else { return nil }
        return bestScore <= candidate.bounds.width * AevonRingMenu.hitFactor ? candidate : nil
    }

    /// V0.3.19（AevonHoverTrailV319）：单个图标相对指针的**弧长**距离（pt）。
    /// 超出它那一圈的径向容差就返回 nil（和 `icon(at:)` 里同一套判据）。
    private func arcScore(of icon: AevonRingIcon, distance: CGFloat, pointAngle: CGFloat) -> CGFloat? {
        guard let index = icons.firstIndex(where: { $0 === icon }),
              index < iconRadii.count, index < iconBaseAngles.count else { return nil }
        let radius = iconRadii[index]
        let tolerance = max(icon.bounds.width * 0.78, 28)
        guard abs(distance - radius) <= tolerance else { return nil }
        var iconAngle = (iconBaseAngles[index] + rotation).truncatingRemainder(dividingBy: 360)
        if iconAngle < 0 { iconAngle += 360 }
        var delta = abs(iconAngle - pointAngle)
        if delta > 180 { delta = 360 - delta }
        return delta * .pi / 180 * radius
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        return atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}
