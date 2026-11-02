//
//  GripLayout.swift — Aevon, where the grip sits.
//
//  Compiled into BOTH binaries. The drag happens in SpringBoard (it is the
//  only process with a window on the home screen), the position row lives in
//  Settings, and neither may guess what the other meant:
//
//      SpringBoard  drag the dot  →  layout.plist  →  notify(com.aevon.prefs)
//      Settings     read layout.plist  →  "位置 82% / 91%"
//      Settings     复位  →  delete layout.plist  →  notify
//
//  The stored value is *normalised* (0…1 of the host view), not a point.
//  A point saved in portrait is meaningless after a rotation; a fraction is
//  the same place on the screen in both orientations, which is what a person
//  expects from "I put it there".
//
//  An absent file means "default corner". That is a deliberate state, not a
//  missing one: deleting the file is how 复位 works, so it must be readable as
//  a valid answer rather than an error.
//

import Foundation
import CoreGraphics

public enum GripLayout {

    /// Nil when the grip has never been dragged (or was reset).
    public static func load() -> CGPoint? {
        return point(from: Aevon.layoutPath)
    }

    /// Same read, but any path — used by the settings row so a preview of the
    /// file and the live host can never disagree.
    public static func point(from path: String) -> CGPoint? {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let x = dict["x"] as? NSNumber,
              let y = dict["y"] as? NSNumber else { return nil }
        return CGPoint(x: clampFraction(CGFloat(x.doubleValue)),
                       y: clampFraction(CGFloat(y.doubleValue)))
    }

    /// Normalised point. Returns false when the file could not be written,
    /// which is the only failure the caller can do anything about.
    @discardableResult
    public static func save(_ normalized: CGPoint) -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "x": Double(clampFraction(normalized.x)),
            "y": Double(clampFraction(normalized.y)),
            "savedAt": Date().timeIntervalSince1970,
        ]
        return (payload as NSDictionary).write(toFile: Aevon.layoutPath, atomically: true)
    }

    /// Back to the corner: removing the file *is* the reset signal.
    @discardableResult
    public static func reset() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Aevon.layoutPath) else { return true }
        do {
            try manager.removeItem(atPath: Aevon.layoutPath)
            return true
        } catch {
            return false
        }
    }

    /// One line for the settings row.
    public static func describe() -> String {
        guard let point = load() else { return "右下角（默认）" }
        let x = Int((point.x * 100).rounded())
        let y = Int((point.y * 100).rounded())
        let right = point.x >= 0.66
        let left = point.x < 0.34
        let bottom = point.y >= 0.66
        let top = point.y < 0.34

        let corner: String
        if right && bottom { corner = "右下" }
        else if left && bottom { corner = "左下" }
        else if right && top { corner = "右上" }
        else if left && top { corner = "左上" }
        else { corner = "自由位置" }
        return "\(corner) · 横向 \(x)% · 纵向 \(y)%"
    }

    // MARK: Helpers

    /// Keeps a fraction inside the screen. 0.04 is the smallest value that
    /// still leaves the 40 pt touch pad fully reachable on any iPhone.
    private static func clampFraction(_ value: CGFloat) -> CGFloat {
        return Swift.min(0.96, Swift.max(0.04, value))
    }
}
