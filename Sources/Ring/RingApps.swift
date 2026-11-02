//
//  RingApps.swift — Aevon, which apps the shape carries, and in what order.
//
//  Compiled into BOTH binaries. Until this build the ring always showed whatever
//  LaunchServices happened to enumerate first, which made "add, remove, sort"
//  impossible to honour. The list now lives in one file:
//
//      /var/mobile/Library/Logs/Aevon/apps.plist   (array of bundle ids)
//
//  Settings owns it; SpringBoard only reads it. An empty or missing file means
//  "nothing chosen yet", and the ring falls back to the automatic list rather
//  than going blank — an empty ring would look like a geometry bug.
//
//  Order is the operator's order, not alphabetical: the first id is the one
//  that lands on the shape's starting angle, so reordering is a real feature.
//

import Foundation
import UIKit

enum RingApps {

    /// Hard ceiling. The geometry never shows more than 12 today, but keeping
    /// the file bounded means a runaway import cannot grow it without limit.
    static let maxCount = 24

    // MARK: Reading

    static func selectedIDs() -> [String] {
        return ids(from: Aevon.appsPath)
    }

    static func ids(from path: String) -> [String] {
        guard let raw = NSArray(contentsOfFile: path) as? [Any] else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for element in raw {
            guard let id = element as? String, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// True when the operator has made a choice. Without it the ring uses the
    /// automatic list, which is what a fresh install should show.
    static var hasCustomList: Bool {
        return !selectedIDs().isEmpty
    }

    // MARK: Writing

    @discardableResult
    static func save(_ ids: [String]) -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        var seen = Set<String>()
        var clean: [String] = []
        for id in ids where !id.isEmpty && !seen.contains(id) {
            seen.insert(id)
            clean.append(id)
        }
        if clean.count > maxCount { clean = Array(clean.prefix(maxCount)) }
        return (clean as NSArray).write(toFile: Aevon.appsPath, atomically: true)
    }

    @discardableResult
    static func add(_ bundleID: String) -> Bool {
        var ids = selectedIDs()
        guard !ids.contains(bundleID) else { return true }
        ids.append(bundleID)
        return save(ids)
    }

    @discardableResult
    static func remove(_ bundleID: String) -> Bool {
        return save(selectedIDs().filter { $0 != bundleID })
    }

    @discardableResult
    static func move(from: Int, to: Int) -> Bool {
        var ids = selectedIDs()
        guard from >= 0, from < ids.count, to >= 0, to <= ids.count else { return false }
        let id = ids.remove(at: from)
        ids.insert(id, at: Swift.min(to, ids.count))
        return save(ids)
    }

    /// Back to automatic: delete the file, do not write an empty array. Both
    /// read as "no choice", but only the missing file is also what 复位 means.
    @discardableResult
    static func reset() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Aevon.appsPath) else { return true }
        do {
            try manager.removeItem(atPath: Aevon.appsPath)
            return true
        } catch {
            return false
        }
    }

    // MARK: For the ring

    /// What SpringBoard should draw: the operator's list in their own order,
    /// or the automatic list when they have not chosen.
    static func resolved(limit: Int) -> (apps: [RingApp], source: IconSource) {
        let ids = selectedIDs()
        guard !ids.isEmpty else { return RingIcons.load(limit: limit) }

        let apps = ids.prefix(limit).map { RingIcons.ringApp(for: $0) }
        let source: IconSource = RingIcons.catalogue().isEmpty ? .placeholder : .launchServices
        return (Array(apps), source)
    }

    /// Cheap change detector: the host compares this string across a refresh
    /// instead of diffing arrays, so a rotate or a resize never rebuilds icons.
    static func signature() -> String {
        let ids = selectedIDs()
        return ids.isEmpty ? "auto" : ids.joined(separator: ",")
    }

    // MARK: For the settings row

    static func summary() -> String {
        let ids = selectedIDs()
        guard !ids.isEmpty else {
            return "自动（未指定，取系统前 12 个）"
        }
        let names = ids.prefix(3).map { RingIcons.ringApp(for: $0).name }
        let more = ids.count > names.count ? "…" : ""
        return "\(ids.count) 个 · " + names.joined(separator: "、") + more
    }
}
