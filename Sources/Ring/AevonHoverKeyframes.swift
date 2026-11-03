import UIKit

/* V0.3.20（AevonKeyframeHoverV320）→ V0.3.21（AevonHoverJumpV321）→ V0.3.22（AevonGifHoverV322）：
 * 圆盘图标的划过动画 —— **定长关键帧引擎**。
 *
 * ═══ 本版波形直接从 Stheno 的屏幕录制里量出来（用户提供的 GIF）═══
 *
 * GIF 是 295×639 —— 正好是 iPhone 15 Pro（1179×2556，393pt 宽）的 1/4，
 * 所以 **1 GIF px = 1.333 pt**。下面所有 pt 值都是这么换算的。
 *
 * 量的是一个被手指压住的图标（红点 24px 宽 = 32pt）：
 *
 *   上浮 lift（pt，取包围盒中心）：
 *     0 → 1 → 13 → 30 → 48 → 57 → **61(峰值)** → 59 → 54 → 40 → 32 → 20 → 17 → 9 → 8 → 5 → 4 → 1 → 0
 *     归一化：17% → 2%，33% → 22%，50% → 50%，67% → 78%，83% → 93%，100% → 100%
 *     ⇒ **慢起、中段最快、尾段收住 = easeInOut**，全程 ≈ 100ms，**没有过冲**。
 *
 *   回落（手指离开）：61 → 59 → 54 → 40 → 32 → 20 → 17 → 9 → 8 → 5 → 4 → 1 → 0
 *     归一化：7% → 2%，14% → 11%，21% → 35%，29% → 48%，36% → 67%，50% → 85%，79% → 98%
 *     ⇒ 同样是 easeInOut，全程 ≈ 235ms，落得很慢、没有回弹。**这就是「跳上去停住、
 *       松手慢慢沉下来」的手感** —— 不是我们 0.3.20/0.3.21 那种「冲上去立刻砸回地面再弹」。
 *
 *   缩放：32pt → 40pt = **1.25×**，与 lift 同步单调变化，**全程没有 non-uniform 挤压**
 *     （0.3.20 的 rubberBand 是错的方向：用户说的「抖」有一半是它自己抖出来的）。
 *
 *   地盘：每个图标脚下有一圈**白色柔光底盘**（直径 ≈ 1.42× 图标），被压住的图标
 *     底盘最亮 —— 这是「跳出来」读感的主要来源，比边框颜色强得多。
 *
 * ═══ 0.3.21 为什么还是「原地抖动」（Aevon(97)）═══
 *
 * 0.3.21 把稳态做成「贴地」：32pt 峰值在 t=34ms、t=66ms 就回地面，全程 90ms。
 * 66ms ≈ 4 帧（60Hz），眼睛来不及读成「跳」，只能读成「抖一下」；而且稳态在地面，
 * 所以「跳起来」这件事在整段交互里只占 4 帧，剩下全是原点不动。
 * **GIF 的做法正好相反：跳上去之后就一直停在空中（稳态 = 抬起），离开才慢慢落。**
 *
 * ═══ 结构不变的优点（继续保留）═══
 *
 * 定长、一次播完、不 retarget。中途改目标时用 `sample(_:at:)` 纯数学接住当前姿态，
 * 不需要问渲染服务器，所以不会回到 `finishAnimation(at: .current)` 那个往返。
 */

/// 一帧关键帧：上抬 pt + 缩放。
struct AevonHoverKey {
    /// 相对动画起点的秒数（严格递增，首帧必须为 0）
    let t: CGFloat
    /// 上抬高度（pt，正值 = 向上）
    let lift: CGFloat
    /// V0.3.22：等比缩放。GIF 里全程 **等比**，不再有 sx/sy 分离的挤压。
    let scale: CGFloat

    init(t: CGFloat, lift: CGFloat, scale: CGFloat) {
        self.t = t
        self.lift = lift
        self.scale = scale
    }
}

/// 某一时刻的姿态（可换算成 `CATransform3D`）。
struct AevonHoverSample {
    let lift: CGFloat
    let scale: CGFloat

    /// 落地 / 未高亮状态
    static let ground = AevonHoverSample(lift: 0, scale: 1)

    func transform3D() -> CATransform3D {
        /* ⛔ 顺序就是语义：`CATransform3DConcat(a, b)` = `a·b`，点走 `p' = p·a·b`，
         * 也就是 **a 先生效**。要「先绕中心缩放、再精确上移 lift pt」，必须是
         * `Concat(Scale, Translation)`。
         *
         * V0.3.21（AevonHoverJumpV321）修正：0.3.20 写的是 `Concat(Translation, Scale)`，
         * 等于先平移再缩放 ⇒ **平移量被 sy 乘了一遍**（实测抬升 = lift × sy）。 */
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                   CATransform3DMakeTranslation(0, -lift, 0))
    }
}

/// 关键帧的用途 —— 只影响各段的分段缓动。
enum AevonHoverStyle {
    case rise
    case land
}

enum AevonHoverKeyframes {

    /// 划过起跳：**100ms 慢起 → 中段最快 → 收在顶点**，停在 `hoverLift` 不下来。
    ///
    /// 形状照着 GIF 归一化出来的 6 个采样点（见文件头）：
    ///   20% → 9%，42% → 43%，64% → 74%，86% → 96%，100% → 100%。
    /// **单调上升、没有过冲** —— GIF 里一次都没有冲过头再回来，过冲才是「抖」。
    static let riseKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 0.0, scale: 1.000),
        AevonHoverKey(t: 0.022, lift: 4.0, scale: 1.022),
        AevonHoverKey(t: 0.046, lift: 20.0, scale: 1.109),
        AevonHoverKey(t: 0.068, lift: 34.0, scale: 1.185),
        AevonHoverKey(t: 0.086, lift: 44.0, scale: 1.239),
        AevonHoverKey(t: 0.100, lift: 46.0, scale: 1.250),
    ]

    /// 划过落地（手指离开）：**170ms 慢慢沉下去**，单调、无回弹。
    ///
    /// GIF 的回落要 235ms（比起来还慢一倍）。这里压到 170ms 是为了让步进 69ms 的
    /// 快速划过不会同时挂着四五个图标 —— 但曲线形状照搬：
    ///   12% → 2%，28% → 35%，47% → 67%，61% → 85%，89% → 98%，100% → 0。
    static let landKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 46.0, scale: 1.250),
        AevonHoverKey(t: 0.020, lift: 45.0, scale: 1.245),
        AevonHoverKey(t: 0.048, lift: 38.0, scale: 1.207),
        AevonHoverKey(t: 0.080, lift: 24.0, scale: 1.130),
        AevonHoverKey(t: 0.104, lift: 15.0, scale: 1.082),
        AevonHoverKey(t: 0.130, lift: 7.0, scale: 1.038),
        AevonHoverKey(t: 0.152, lift: 2.0, scale: 1.011),
        AevonHoverKey(t: 0.170, lift: 0.0, scale: 1.000),
    ]

    static var riseDuration: CFTimeInterval { CFTimeInterval(riseKeys[riseKeys.count - 1].t) }
    static var landDuration: CFTimeInterval { CFTimeInterval(landKeys[landKeys.count - 1].t) }

    /// 高亮稳态（划过之后停住的样子）——**就是 `riseKeys` 的末帧**。
    ///
    /// V0.3.22（AevonGifHoverV322）：`hoverLift` 从 0 改回 **46pt**。
    /// 0.3.21 把稳态压在地面，想用「90ms 里冲上去再砸下来」表达跳跃，
    /// 结果是 66ms 就回地面 = 4 帧，眼睛只读得到「抖一下」。
    /// GIF 的做法相反：**跳上去就一直停在空中，离开才慢慢落** —— 这才是「跳」。
    static let lifted = AevonHoverSample(lift: AevonRingMenu.hoverLift,
                                         scale: AevonRingMenu.hoverScale)

    /// 纯数学求值 —— **不碰 `layer.presentation()`**，这是本版不掉帧的关键。
    ///
    /// 关键帧是自己定的表，任意时刻的值就是个分段线性函数；分段内不套缓动
    ///（与 `timingFunctions` 有一点点差），差值在 8~16ms 的一帧里不到 0.3pt，
    /// 肉眼不可见，换来的是「中途改目标时不需要向渲染服务器要呈现值」。
    ///
    /// `from` 必须和开动画时传的是同一个 —— 内部会先 `rebase` 再取值，否则取到的是
    /// 「没重新定标的那条曲线」上的点，和屏上真正在走的曲线对不上，下一次接手就会跳一下。
    static func sample(_ keys: [AevonHoverKey],
                       at time: CGFloat,
                       from: AevonHoverSample? = nil) -> AevonHoverSample {
        // ⛔ 不能写成 `let keys = ... keys ...`：Swift 会报
        //   「Variable used within its own initial value」（新绑定在自己的初值里不可见）。
        let table = from.map { rebase(keys, from: $0) } ?? keys
        guard let first = table.first, let last = table.last else { return .ground }
        if time <= first.t {
            return AevonHoverSample(lift: first.lift, scale: first.scale)
        }
        if time >= last.t {
            return AevonHoverSample(lift: last.lift, scale: last.scale)
        }
        var index = 1
        while index < table.count {
            let a = table[index - 1]
            let b = table[index]
            if time <= b.t {
                let span = b.t - a.t
                let k = span > 0.0001 ? (time - a.t) / span : 1
                return AevonHoverSample(lift: a.lift + (b.lift - a.lift) * k,
                                        scale: a.scale + (b.scale - a.scale) * k)
            }
            index += 1
        }
        return AevonHoverSample(lift: last.lift, scale: last.scale)
    }

    /// 把整条曲线按 `from` **重新定标**：首帧严格等于 `from`，末帧保持原值，单调性不变。
    ///
    /// ⛔ 为什么非做不可（0.3.21 遗留的真 bug）：
    /// `animation(_:from:)` 只是把第一帧换成 `from`。如果 `from` 不在表的起点上，
    /// 后面几帧还是原值 —— 于是「半路折返」时会先往反方向走一下：
    ///   · 划过 A 后 100ms 内又划回 A：`from.lift ≈ 20`，rise 表第 2 帧是 4 ⇒ **先掉到 4 再爬**；
    ///   · 离开时 `from.lift ≈ 20`，land 表第 2 帧是 45 ⇒ **先弹到 45 再沉**。
    /// 这两种都是肉眼可见的一下反向抽动，正好也是用户说的「抖」的一种。
    /// 按振幅等比缩放后，首帧就是 `from`、末帧还是目标值，中间单调 —— 反向抽动消失。
    static func rebase(_ keys: [AevonHoverKey], from: AevonHoverSample) -> [AevonHoverKey] {
        guard let first = keys.first, let last = keys.last, keys.count > 1 else { return keys }
        let dl = last.lift - first.lift
        let ds = last.scale - first.scale
        let kl = abs(dl) > 0.0001 ? (last.lift - from.lift) / dl : 0
        let ks = abs(ds) > 0.0001 ? (last.scale - from.scale) / ds : 0
        return keys.map { key in
            AevonHoverKey(t: key.t,
                          lift: from.lift + (key.lift - first.lift) * kl,
                          scale: from.scale + (key.scale - first.scale) * ks)
        }
    }

    /// 造一条 `CAKeyframeAnimation(keyPath: "transform")`。
    ///
    /// `from` 接住「此刻的姿态」：表先按 `rebase` 重新定标，线段因此连续，
    /// 不需要 `stopAnimation` / `finishAnimation`，也就没有那次渲染服务器往返。
    static func animation(_ keys: [AevonHoverKey],
                          from: AevonHoverSample,
                          style: AevonHoverStyle) -> CAKeyframeAnimation {
        // 同上：不能在 `keys` 自己的初值里引用 `keys`，另起一个名字。
        let table = rebase(keys, from: from)
        var samples: [AevonHoverSample] = [from]
        var times: [CGFloat] = [0]
        for key in table.dropFirst() {
            samples.append(AevonHoverSample(lift: key.lift, scale: key.scale))
            times.append(key.t)
        }
        let total = table[table.count - 1].t
        let denom = total > 0.0001 ? total : 1

        let anim = CAKeyframeAnimation(keyPath: "transform")
        // ⛔ 必须包成 NSValue(caTransform3D:)：`transform` 这条 keyPath 只认 NSValue，
        // 直接塞 `[CATransform3D]` 会被当成一堆无法解释的 Any，动画不生效（静默）。
        anim.values = samples.map { NSValue(caTransform3D: $0.transform3D()) }
        anim.keyTimes = times.map { NSNumber(value: Double($0 / denom)) }
        anim.duration = CFTimeInterval(total)
        anim.timingFunctions = timingFunctions(count: samples.count - 1, style: style)
        anim.fillMode = .forwards
        // 模型值在动手之前就已经写成「终点」，所以动画结束即可摘掉，不会闪。
        anim.isRemovedOnCompletion = true
        return anim
    }

    /// 分段缓动。
    ///
    /// V0.3.22（AevonGifHoverV322）：三张表全部改成 **easeInEaseOut** —— 这是从 GIF
    /// 的归一化采样点里量出来的：起点几帧几乎不动（慢起）、中段一下拉开（最快）、
    /// 尾部再收住。0.3.21 那种「起手 easeOut 猛地出去、下落 easeIn 砸下来」是
    /// 「重物坠落」，不是 GIF 的「弹起来」。
    private static func timingFunctions(count: Int, style: AevonHoverStyle) -> [CAMediaTimingFunction] {
        let easeBoth = CAMediaTimingFunction(name: .easeInEaseOut)
        guard count > 0 else { return [] }
        switch style {
        case .rise, .land:
            return Array(repeating: easeBoth, count: count)
        }
    }
}
