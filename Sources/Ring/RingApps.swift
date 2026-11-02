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

    /// File layout, v2:
    ///
    ///     { "version": 2, "apps": [id…], "pinned": [id…] }
    ///
    /// v1 was a bare array. Both are read; only v2 is written. A file that is
    /// still v1 keeps working, which matters because the operator already has
    /// a list they built by hand.
    private struct Store {
        var apps: [String] = []
        var pinned: [String] = []
    }

    // MARK: Reading

    static func selectedIDs() -> [String] {
        return read(Aevon.appsPath).apps
    }

    /// RingEnv._pinned. Order inside this set is not meaningful: the list order
    /// decides where a pinned app sits, the pin only decides that it comes
    /// first.
    static func pinnedIDs() -> Set<String> {
        return Set(read(Aevon.appsPath).pinned)
    }

    static func isPinned(_ bundleID: String) -> Bool {
        return read(Aevon.appsPath).pinned.contains(bundleID)
    }

    private static func read(_ path: String) -> Store {
        var store = Store()
        if let dict = NSDictionary(contentsOfFile: path) as? [String: Any] {
            store.apps = clean(dict["apps"] as? [Any] ?? [])
            store.pinned = clean(dict["pinned"] as? [Any] ?? [])
            // A pin for an app that is no longer in the list would resurrect it
            // on the next read; drop those instead.
            let present = Set(store.apps)
            store.pinned = store.pinned.filter { present.contains($0) }
            return store
        }
        // v1: a bare array of bundle ids.
        store.apps = clean(NSArray(contentsOfFile: path) as? [Any] ?? [])
        return store
    }

    private static func clean(_ raw: [Any]) -> [String] {
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
        var store = read(Aevon.appsPath)
        store.apps = ids
        return write(store)
    }

    @discardableResult
    private static func write(_ store: Store) -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        var apps = clean(store.apps)
        if apps.count > maxCount { apps = Array(apps.prefix(maxCount)) }
        let present = Set(apps)
        let pinned = clean(store.pinned).filter { present.contains($0) }
        let dict: [String: Any] = [
            "version": 2,
            "apps": apps,
            "pinned": pinned,
        ]
        return (dict as NSDictionary).write(toFile: Aevon.appsPath, atomically: true)
    }

    @discardableResult
    static func add(_ bundleID: String) -> Bool {
        var ids = selectedIDs()
        guard !ids.contains(bundleID) else { return true }
        ids.append(bundleID)
        return save(ids)
    }

    /// The automatic list, frozen into an explicit one.
    ///
    /// On a fresh install `apps` is empty because the ring is showing the
    /// automatic list. `remove` and `togglePin` edit `apps`, so editing that
    /// empty list writes an empty list, the ring drops straight back to
    /// automatic, and the icon the operator just trashed reappears — a delete
    /// that does not delete. Freezing first makes the gesture mean what it
    /// looks like it means, and because the ids are exactly the ones already on
    /// screen, the ring does not reshuffle when it happens.
    private static func frozen(_ store: Store) -> Store {
        guard store.apps.isEmpty else { return store }
        var seeded = store
        seeded.apps = clean(RingIcons.load(limit: maxCount).apps.map { $0.bundleID })
        return seeded
    }

    @discardableResult
    static func remove(_ bundleID: String) -> Bool {
        var store = frozen(read(Aevon.appsPath))
        store.apps = store.apps.filter { $0 != bundleID }
        store.pinned = store.pinned.filter { $0 != bundleID }
        return write(store)
    }

    /// 收藏 / 取消收藏. The app keeps its position in the operator's list — the
    /// pin only lifts it to the front when the ring is drawn, so unpinning puts
    /// it back exactly where it was instead of at the end.
    @discardableResult
    static func togglePin(_ bundleID: String) -> Bool {
        var store = frozen(read(Aevon.appsPath))
        guard store.apps.contains(bundleID) else { return false }
        if let index = store.pinned.firstIndex(of: bundleID) {
            store.pinned.remove(at: index)
        } else {
            store.pinned.append(bundleID)
        }
        return write(store)
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

    /// 收藏 first, then the operator's own order. Stable: an app that is not
    /// pinned keeps its relative position, which is what makes 取消收藏 feel
    /// like it put the icon back rather than shuffling the ring.
    static func ordered(limit: Int) -> [String] {
        let store = read(Aevon.appsPath)
        let pinned = Set(store.pinned)
        let head = store.apps.filter { pinned.contains($0) }
        let tail = store.apps.filter { !pinned.contains($0) }
        return Array((head + tail).prefix(limit))
    }

    /// What SpringBoard should draw: the operator's list in their own order,
    /// or the automatic list when they have not chosen.
    static func resolved(limit: Int) -> (apps: [RingApp], source: IconSource) {
        let ids = ordered(limit: limit)
        guard !ids.isEmpty else { return RingIcons.load(limit: limit) }

        let apps = ids.map { RingIcons.ringApp(for: $0) }
        let source: IconSource = RingIcons.catalogue().isEmpty ? .placeholder : .launchServices
        return (apps, source)
    }

    /// Cheap change detector: the host compares this string across a refresh
    /// instead of diffing arrays, so a rotate or a resize never rebuilds icons.
    /// Pins are part of it — a pin changes the order, and an order change that
    /// does not refresh is a feature that silently does nothing.
    static func signature() -> String {
        let store = read(Aevon.appsPath)
        if store.apps.isEmpty { return "auto" }
        return store.apps.joined(separator: ",")
            + "|p:" + store.pinned.sorted().joined(separator: ",")
    }

    // MARK: For the settings row

    /// One line for the 收藏 row. The master has `Star` as a key but no page of
    /// its own: a pin is a gesture on the icon, so the only thing Settings can
    /// honestly show is what is pinned right now.
    static func starSummary() -> String {
        let store = read(Aevon.appsPath)
        if store.pinned.isEmpty {
            return "未收藏（在圆盘上长按图标即可收藏）"
        }
        let names = ordered(limit: store.pinned.count)
            .map { RingIcons.ringApp(for: $0).name }
            .prefix(3)
        let more = store.pinned.count > names.count ? "…" : ""
        return "收藏 " + String(store.pinned.count) + " 个 · "
            + names.joined(separator: "、") + more
    }

    static func summary() -> String {
        let store = read(Aevon.appsPath)
        guard !store.apps.isEmpty else {
            return "自动（未指定，取系统前 12 个）"
        }
        let names = ordered(limit: 3).map { RingIcons.ringApp(for: $0).name }
        let more = store.apps.count > names.count ? "…" : ""
        let star = store.pinned.isEmpty ? "" : " · 收藏 \(store.pinned.count)"
        return "\(store.apps.count) 个" + star + " · " + names.joined(separator: "、") + more
    }
}
