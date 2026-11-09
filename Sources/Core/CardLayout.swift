//
//  CardLayout.swift — Aevon, where the floating card sits and how big it is.
//
//  The master does not store a frame. `EgdeGestureView` keeps five values:
//
//      _leftPecent   _rightPecent            horizontal, one per edge
//      _leftHeightPecent   _rightHeightPecent   vertical, one per edge
//      _edgeWidth                            the docking band, in points
//
//  and `SettingEnv` persists exactly the same five, which is the part that
//  matters: they are settings, not runtime state. 0.0.38 recomputed the card
//  from scratch on every open — `card 320x694 at 55,119` in Aevon(37), the
//  same numbers every single time, because there was nothing to remember.
//
//  Two sets rather than one is the whole design. A card docked left and the
//  same card docked right are two placements, and the operator expects each
//  to come back as it was left; a single saved CGRect answers for one screen
//  that has two edges. `_effectEdge` says which of the two is live.
//
//  Values are fractions of the host bounds, never points. A frame saved in
//  portrait means nothing after a rotation; a fraction is the same place.
//

import Foundation
import CoreGraphics

public enum CardLayout {

    /// `Edge` in the master (`left` / `right`, and `AppearEdge` adds `both`
    /// for where the *handle* may appear — not for where the card docked).
    public enum Edge: String {
        case left
        case right
    }

    /// The master's `_leftPecent` family, plus the one size value it keeps
    /// separately as `HeightFraction`.
    public struct Placement {
        /// Bumped whenever the built-in size changes meaning. A file stamped
        /// with an older number is read as "default + drag", not as a choice.
        ///
        /// 0.0.46 — version 3. Aevon(44) reports the default as 「几乎占满整个
        /// 屏幕」, and a saved 85 % card would keep that true on the one phone
        /// that reported it, so the stamp moves with the number.
        ///
        /// 0.2.39 — version 4. 默认高度系数 62 % → 63 %（量自 Stheno 的演示
        /// 视频），圆角从「固定 38 pt」改成「卡宽 × 12.73 %」。旧存盘里记的是
        /// 上一版的尺寸，留着就等于「新默认在你那台手机上永远不出现」，所以
        /// 戳记照例往前走一格：旧文件按 `initial` + 边（边是真选择，留着）。
        public static let currentVersion = 4

        /// `_effectEdge` — which edge the card is docked to right now.
        public var edge: Edge
        /// Normalised top-left corner while docked left.
        public var left: CGPoint
        /// Normalised top-left corner while docked right.
        public var right: CGPoint
        /// `HeightFraction` — card height as a fraction of the host height.
        /// The width follows the scene's own aspect, so one number is enough.
        public var heightFraction: CGFloat

        /// 0.0.46 — 62 %, and the number comes from a measurement rather than
        /// from that annotation. It is also the value 设置里 `高度系数` ships
        /// with, so the panel and the first frame agree instead of disagreeing
        /// by thirty points of screen.
        ///
        /// 0.0.45 read `"0.2 0.3 0.9 0.85 30.0"` as "the window is 85 % tall"
        /// and shipped it. Aevon(44) is unambiguous: 「默认的尺寸太大了。几乎占满
        /// 整个屏幕」. 85 % is 792 pt of a 932 pt screen with 365 pt of width —
        /// a card that leaves 8 pt on the right, which is also the width of the
        /// gesture band on that side, so the same round reports the outer
        /// gestures dead (see `FloatHost.band`). The two reports are one defect.
        ///
        /// The 0.9/0.85 pair cannot be proven to mean window height: those two
        /// fields sit beside `_leftPecent`/`_rightPecent` in `EgdeGestureView`,
        /// whose job is the *edge band* — 90 % and 85 % of the height is where a
        /// handle spans. A window is not a band.
        ///
        /// 62 % is 578 pt tall and 267 wide here: a window, not a second screen,
        /// with 81 pt of screen on each side and 177 pt above and below for the
        /// band to live in.
        ///
        /// 0.2.39 — 62 % → 63 %，这次是有对照物的：Stheno 的演示视频
        /// （886×1920，iPhone 393×852@3x 缩放，1 pt = 2.2545 px，靠底部 Home
        /// 条 315 px = 139 pt 定的比例）。逐像素量出来她的卡片是
        ///   宽 707 px = 313.6 pt = 屏宽 79.8 %
        ///   高 1209 px = 536.3 pt = 屏高 63.0 %
        ///   圆角 90 px = 39.9 pt = 卡宽 12.73 %
        /// 我们的卡片形状是钉死的 5:3（`FloatHost.fatAspect`），宽高比 0.600，
        /// 她那块是 0.585 —— 一条轴对齐另一条就必然差一点。选高度轴：63.0 % 是
        /// 直接量到的那一个数，也是「高度系数」这个名字指的东西；宽度于是被
        /// 5:3 推成 81.9 %（她 79.8 %，差 2.1 个点）。想按宽度对齐就在设置里把
        /// 高度系数调到 61 %（343×572，宽 79.8 %）—— 滑条就是为这种取舍留的。
        ///
        /// 0.2.38 的 62 % 其实已经落在她身上（80.6 %×62.0 %，两轴差 ≤1 个点）：
        /// 0.0.81 把卡片从「跟着画布长」改成钉死 5:3 的时候，宽度一次从 267
        /// 涨到 347，那条「我们的窗口比她的窄」的观感就是那次修掉的。这一版
        /// 补的是另一条：圆角。
        public static var initial: Placement {
            let height = preferredHeight
            let x = (1 - widthFraction(for: height)) / 2
            // Vertically centred, so the band has the same room above and below
            // and neither corner resize starts against a screen edge.
            let y = (1 - height) / 2
            return Placement(edge: .right,
                             left: CGPoint(x: x, y: y),
                             right: CGPoint(x: x, y: y),
                             heightFraction: height)
        }

        /// The built-in height, before anything is remembered.
        ///
        /// 0.2.39 — 0.63：Stheno 演示视频里那张卡片的身高，占屏高 63.0 %
        /// （量法见 `initial` 上面那段）。设置里「高度系数」的出厂值必须与它
        /// 一致（`tools/gen-settings.py` 的 `d=`），否则面板显示 62 %、卡片开
        /// 出来 63 %，差的那 9 pt 会被人当成「滑条没生效」。
        public static let defaultHeight: CGFloat = 0.63

        /// 0.2.39 — 高度的合法区间，读写两端共用。
        ///
        /// 这三个数以前散在四个地方（`read` 的 0.30/0.92、`preferredHeight` 的
        /// 0.30/0.80、`FloatHost.plan` 的三道夹子、`dragMove` 的另一道），于是
        /// 「同一个尺寸」在存盘里和在屏幕上可以是两个数。现在这里只有一份：
        /// 读回来越界就夹、写出去越界也夹，窗口侧再用 `nominalHeightRange`
        /// 把「画布高 / 屏高减 96」并进去。
        ///
        /// 下面 0.30 是「最小主窗」（屏高 30 %，与 `FloatHost.miniHeightFraction`
        /// 同一个数）；0.92 是「再大就不是窗口了」的硬上限，正常情况下画布高
        /// 会先拦住它。
        public static let minHeight: CGFloat = 0.30
        public static let maxHeight: CGFloat = 0.92
        /// 0.0.46 — 设置 → 窗口与场景 → 高度系数. That row shipped in 0.0.42
        /// with a note promising it decides the floating window's height, and
        /// nothing read it: the card took the height from its own saved file and
        /// the slider moved a key nobody opened. Wiring it here is the shortest
        /// honest way to answer 「尺寸太大」 twice in a row — the operator can
        /// now set the first frame's height without waiting for a build.
        ///
        /// Read once per open (an IPC round trip, never per frame). The saved
        /// placement still wins after a drag or a resize — that is the more
        /// specific choice — and 长按底角 clears it, which re-reads this.
        public static var preferredHeight: CGFloat {
            let stored = CGFloat(AevonPrefs.double("HeightFraction",
                                                  default: Double(defaultHeight)))
            return Swift.min(0.80, Swift.max(minHeight, stored))
        }

        /// Width as a fraction of the host width, given a height fraction.
        ///
        /// 0.0.46 — this used to be `0.4614 * heightFraction`, which is the
        /// *point* ratio (430 : 932) multiplied by a fraction: a unit error.
        /// At 85 % it asked for x = 30 % of the width, `plan` clamped that to
        /// "8 pt from the right edge", and the card ended up pinned off-centre.
        /// The scene is full-bleed inside the card and carries the phone's own
        /// aspect, so on the phone that shows it the width fraction *is* the
        /// height fraction. Other aspects are handled at plan time, where the
        /// real scene size is known.
        ///
        /// 0.2.39 — 上面那条前提在 0.0.81 就不成立了：卡片不再是「和画布同
        /// 形状、长度跟着画布长」，而是钉死 5:3。卡高 = 屏高 × f，卡宽 = 卡高
        /// × 0.6，于是宽度占比 = f × 0.6 ÷ (430/932) = f × 1.3004，不是 f。
        ///
        /// 这个数只喂 `initial` 的 x，但错得很显眼：f = 0.62 时这里报 62 %
        /// （x = 19 % = 81.7 pt），而卡片实际有 80.6 % 宽（346.7 pt），`plan`
        /// 的 room 分支只好把 x 夹到 430 − 346.7 = 83.3 —— **默认卡片其实贴着
        /// 右边缘**，右边那条 66 pt 的环带一点不剩，左边宽 81.7 pt。用户看到的
        /// 是「卡片偏右、右边手势按不到」，而 x 那个数本身没有错，是喂给它的
        /// 宽度占比错了。
        ///
        /// 0.4614 是这台手机的高宽比（430 : 932），仓库里一直这么用；0.6 是
        /// 5:3 的倒数。两处都是常数，不引入新的量。
        public static func widthFraction(for heightFraction: CGFloat) -> CGFloat {
            let cardAspect = 0.6                      // 1 / (5:3)，同 `FloatHost.fatAspect`
            let phoneAspect = 0.4614                  // 430 : 932
            return Swift.min(0.92, heightFraction * cardAspect / phoneAspect)
        }

        public func origin(for edge: Edge) -> CGPoint {
            return edge == .left ? left : right
        }
    }

    /// `_edgeWidth`, 30 pt. This is the one number in the master's constant
    /// pool — `"0.2 0.3 0.9 0.85 30.0"`, sitting immediately after the five
    /// field names — that can be assigned with confidence: it is the only
    /// non-fraction in the group, and `edgeWidth` is the only one of the five
    /// measured in points. The other four cannot be mapped to names from that
    /// string alone, so they are not guessed at here; they are measured from
    /// the operator's own drags instead.
    public static let edgeWidth: CGFloat = 30

    // MARK: Reading

    public static func load() -> Placement? {
        return read(Aevon.cardPath)
    }

    /// Any path — the settings row shows the same file the live host reads.
    public static func read(_ path: String) -> Placement? {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        // A file without a readable edge was not written by this version.
        // Inventing a placement from half a file is how a card comes back on
        // the wrong side of the screen.
        guard let raw = dict["edge"] as? String,
              let edge = Edge(rawValue: raw) else { return nil }
        // 0.0.45 — a placement saved before the default size changed is not a
        // placement the operator chose *against* the new default; it is the old
        // default plus whatever drag happened under it. Keeping it would make
        // 「改默认尺寸」 invisible on exactly the phone that reported the problem,
        // so anything without the current stamp falls back to `initial`. The
        // edge is kept: which side the card lives on is a real choice.
        guard (dict["layoutVersion"] as? NSNumber)?.intValue == Placement.currentVersion else {
            var fresh = Placement.initial
            fresh.edge = edge
            return fresh
        }

        func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
            return (dict[key] as? NSNumber).map { clampFraction(CGFloat($0.doubleValue)) }
                ?? fallback
        }

        var placement = Placement.initial
        placement.edge = edge
        placement.left = CGPoint(x: number("leftPecent", placement.left.x),
                                 y: number("leftHeightPecent", placement.left.y))
        placement.right = CGPoint(x: number("rightPecent", placement.right.x),
                                  y: number("rightHeightPecent", placement.right.y))
        // Height gets its own clamp: 0.3 is a card, 0.99 is a second screen
        // with no way to reach the close button behind it.
        //
        // 0.0.64 — 下界从 0.35 改回 0.30。边角拖动的最小高度是屏幕的 30 %
        // （`FloatHost.miniHeight`），设置里的「高度系数」滑条也是 0.30 起；
        // 读回来卡在 0.35 等于「拖到最小 → 存 30 % → 重开变 35 %」，一次缩小
        // 记不住。三个数现在说的是同一件事。
        let height = (dict["HeightFraction"] as? NSNumber).map { CGFloat($0.doubleValue) }
            ?? placement.heightFraction
        placement.heightFraction = Swift.min(Placement.maxHeight,
                                            Swift.max(Placement.minHeight, height))
        return placement
    }

    /// What SpringBoard uses: the file when the operator has dragged the card,
    /// the pre-memory default otherwise.
    public static func loadRuntime() -> Placement {
        return load() ?? .initial
    }

    // MARK: Writing

    @discardableResult
    public static func save(_ placement: Placement) -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        // 0.2.39 — 写出去之前夹到同一组边界。窗口侧的 `remember` 已经按
        // `nominalHeightRange` 夹过；这里再夹一次，是为了让设置面板 / 将来别的
        // 写入者也不会把「还原不回来的尺寸」写进这份唯一的记忆。
        let height = Swift.min(Placement.maxHeight,
                               Swift.max(Placement.minHeight, placement.heightFraction))
        let payload: [String: Any] = [
            "edge": placement.edge.rawValue,
            "leftPecent": Double(clampFraction(placement.left.x)),
            "leftHeightPecent": Double(clampFraction(placement.left.y)),
            "rightPecent": Double(clampFraction(placement.right.x)),
            "rightHeightPecent": Double(clampFraction(placement.right.y)),
            "HeightFraction": Double(height),
            "layoutVersion": Placement.currentVersion,
            "edgeWidth": Double(edgeWidth),
            "savedAt": Date().timeIntervalSince1970,
        ]
        return (payload as NSDictionary).write(toFile: Aevon.cardPath, atomically: true)
    }

    @discardableResult
    public static func reset() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Aevon.cardPath) else { return true }
        do {
            try manager.removeItem(atPath: Aevon.cardPath)
            return true
        } catch {
            return false
        }
    }

    // 0.0.40 — `dockEdge` / `dockOrigin` are gone with the drag-snap. 吸附 is
    // now a tap on a side band (the card becomes a 停靠小窗), and a drag simply
    // leaves the card where the finger let go. Keeping a second meaning of the
    // same word would have meant two rules for one edge.

    /// One line for the settings row, in the same shape as `GripLayout.describe`.
    public static func describe() -> String {
        guard let placement = load() else {
            return "未记录（默认居中 · 高度 \(Int(Placement.initial.heightFraction * 100))%）"
        }
        let side = placement.edge == .left ? "左侧" : "右侧"
        let point = placement.origin(for: placement.edge)
        let x = Int((point.x * 100).rounded())
        let y = Int((point.y * 100).rounded())
        let height = Int((placement.heightFraction * 100).rounded())
        return "\(side) · 横向 \(x)% · 纵向 \(y)% · 高度 \(height)%"
    }

    // MARK: Helpers

    private static func clampFraction(_ value: CGFloat) -> CGFloat {
        return Swift.min(1, Swift.max(0, value))
    }
}
