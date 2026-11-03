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
        /// `_effectEdge` — which edge the card is docked to right now.
        public var edge: Edge
        /// Normalised top-left corner while docked left.
        public var left: CGPoint
        /// Normalised top-left corner while docked right.
        public var right: CGPoint
        /// `HeightFraction` — card height as a fraction of the host height.
        /// The width follows the scene's own aspect, so one number is enough.
        public var heightFraction: CGFloat

        /// What 0.0.38 did, expressed in these terms: 320x694 centred in a
        /// 430x932 host. Starting from the old numbers rather than from a
        /// nicer-looking guess means the first open after the upgrade looks
        /// exactly like the last one, and only the operator's own drag changes
        /// it from there.
        public static var initial: Placement {
            return Placement(edge: .right,
                             left: CGPoint(x: 55.0 / 430.0, y: 119.0 / 932.0),
                             right: CGPoint(x: 55.0 / 430.0, y: 119.0 / 932.0),
                             heightFraction: 694.0 / 932.0)
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

    // MARK: Docking

    /// Does this frame belong to an edge?
    ///
    /// The band is measured from the card's own edge to the screen's edge, not
    /// from the finger: a card whose left side is within `edgeWidth` of the
    /// screen's left side is a card the operator was trying to put on the left.
    /// Anything further in is a free position and keeps whichever side it is
    /// already on — a card must not jump across the screen because it was
    /// nudged two points past the centre line.
    ///
    /// Returns nil for "free": the caller keeps the current edge.
    public static func dockEdge(_ frame: CGRect, in bounds: CGRect) -> Edge? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Both edges within the band can only happen on a card nearly as wide
        // as the screen; the nearer one wins, so a docked card never sits in
        // the middle declaring itself on both sides.
        let toLeft = frame.minX
        let toRight = bounds.maxX - frame.maxX
        if toLeft <= edgeWidth && toLeft <= toRight { return .left }
        if toRight <= edgeWidth { return .right }
        return nil
    }

    /// Where a docked card actually sits: hard against the edge, minus the
    /// window margin, so the close button is not under the screen's rounded
    /// corner.
    public static func dockOrigin(_ edge: Edge, width: CGFloat,
                                  in bounds: CGRect, margin: CGFloat) -> CGPoint {
        let x = edge == .left ? margin : bounds.maxX - width - margin
        return CGPoint(x: x, y: 0)
    }

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
