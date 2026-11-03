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
        public static let currentVersion = 2

        /// `_effectEdge` — which edge the card is docked to right now.
        public var edge: Edge
        /// Normalised top-left corner while docked left.
        public var left: CGPoint
        /// Normalised top-left corner while docked right.
        public var right: CGPoint
        /// `HeightFraction` — card height as a fraction of the host height.
        /// The width follows the scene's own aspect, so one number is enough.
        public var heightFraction: CGFloat

        /// 0.0.45 — the master's own 高度系数, not 0.0.38's leftover.
        ///
        /// Aevon(43) said the card reads as 「特别的细长条」. It was: 694/932 =
        /// 74.5 % of the screen height, and with the picture's own aspect
        /// (430:932) the width lands at 320 pt — a strip, not a window.
        ///
        /// The master keeps this number in `SettingEnv._windowHeight` (labelled
        /// `HeightFraction` = 高度系数 in its own strings) and its default is
        /// legible in the only numeric annotation the binary still carries:
        /// `"0.2 0.3 0.9 0.85 30.0"`, sitting directly after `EgdeGestureView`'s
        /// five geometry fields — `_leftPecent`, `_rightPecent`,
        /// `_leftHeightPecent`, `_rightHeightPecent`, `_edgeWidth`. So the two
        /// heights are 90 % and 85 %, and 30 pt is the master's edge band width
        /// (already used above as `edgeWidth`).
        ///
        /// 0.85 it is — the docked-right default, the conservative of the two.
        /// Width follows the picture, so the card becomes 366x792 on this
        /// 430x932 phone: full-height, centred, and nothing like a strip.
        public static var initial: Placement {
            // 366 wide in a 430 screen → 32 pt either side, held as a fraction so
            // a rotation keeps the card centred instead of pinned left.
            let x = (1 - ratio(for: 0.85)) / 2
            return Placement(edge: .right,
                             left: CGPoint(x: x, y: 0.06),
                             right: CGPoint(x: x, y: 0.06),
                             heightFraction: 0.85)
        }

        /// Width as a fraction of the host width, given a height fraction. The
        /// picture is 430:932, so the card is that shape scaled — one number
        /// (height) decides both, and the operator only ever chooses the height.
        public static func ratio(for heightFraction: CGFloat) -> CGFloat {
            // 0.4614 = 430/932, the picture's own aspect on this phone. Written
            // as a constant so the initial placement does not depend on a live
            // screen being available when the setting page asks for a preview.
            return 0.4614 * heightFraction
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
        let height = (dict["HeightFraction"] as? NSNumber).map { CGFloat($0.doubleValue) }
            ?? placement.heightFraction
        placement.heightFraction = Swift.min(0.92, Swift.max(0.35, height))
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
