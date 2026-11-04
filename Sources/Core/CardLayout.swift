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
        public static let currentVersion = 3

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
        public static let defaultHeight: CGFloat = 0.62
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
            return Swift.min(0.80, Swift.max(0.30, stored))
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
        public static func widthFraction(for heightFraction: CGFloat) -> CGFloat {
            return Swift.min(0.92, heightFraction)
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
        placement.heightFraction = Swift.min(0.92, Swift.max(0.30, height))
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
        let payload: [String: Any] = [
            "edge": placement.edge.rawValue,
            "leftPecent": Double(clampFraction(placement.left.x)),
            "leftHeightPecent": Double(clampFraction(placement.left.y)),
            "rightPecent": Double(clampFraction(placement.right.x)),
            "rightHeightPecent": Double(clampFraction(placement.right.y)),
            "HeightFraction": Double(placement.heightFraction),
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
