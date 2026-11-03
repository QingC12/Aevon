import Foundation

/// 圆盘里的 App 收藏（数组顺序 = 圆盘上从下往上的顺序）。
///
/// Stheno 的证据：`Stheno.dylib` 里有 `_apps` / `_selected` / `_perAppData` / `AppSearcher` /
/// `TrashAppState` 这套数据模型 —— 圆盘里的 App 是一份用户自选的列表，可增可删。
/// 我们只做「有序列表 + 上限」，存在偏好域 com.Aevon 的 `RingApps` 键里。
enum AevonRingStore {
    /// 圆盘上最多放几个。V0.0.20 起是多圈布局：内圈 8 + 中圈 12 + 外圈 16 = 36。
    static let maxCount = 36

    private static let key = "RingApps"
    /// V0.0.31（AevonRingPinnedV31）：最后一份「可信快照」。
    /// 跨进程读 UserDefaults 偶尔会拿到空/残缺快照（用户 Aevon(24) 实测：同一分钟内
    /// 圆盘 App 数在 20/21/22/23 之间漂移、图标排序被打乱）—— 只有设置页真正
    /// 广播「列表改了」时才更新快照，圆盘打开时永远用同一份，位置因此固定并记忆。
    private static let snapshotKey = "RingAppsSnapshot"
    // 本包只有一个域（旧版是 com.Aevon，大写 A）——见 AevonCompat.swift 的说明。
    private static let suite = Aevon.domain
    private static var cached: [String]?

    /// 非空、去重、不超上限 —— 满足才算可信列表
    private static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in raw where !id.isEmpty && !seen.contains(id) {
            seen.insert(id)
            out.append(id)
            if out.count >= maxCount { break }
        }
        return out
    }

    private static func readList(forKey k: String) -> [String] {
        guard let store = UserDefaults(suiteName: suite),
              let raw = store.array(forKey: k) as? [String] else { return [] }
        return sanitize(raw)
    }

    static func bundleIDs() -> [String] {
        // V0.2.63（AevonQuickEditableV263）：首次读之前播种一次截图 / 录屏（只一次）。
        seedQuickActionsIfNeeded()
        if let cached = cached { return cached }
        var list = readList(forKey: key)
        if list.isEmpty { list = readList(forKey: snapshotKey) }
        cached = list
        return list
    }

    /// V0.2.63（AevonQuickEditableV263，用户 Aevon(37) #3「截图和录屏一直存在圆盘里，
    /// 无法通过设置中的应用编辑去添加/移除或者排序」）：
    /// 0.2.62 是把两个动作**强行拼在**列表最前面（内部私有方法），所以设置页里
    /// 根本看不到它们，自然也删不掉。现在改成「一次性播种进 RingApps」——
    /// 播种之后它们就是普通条目：设置页能看见、能删、能拖动排序、删了还能从「+」加回来。
    /// 用 `RingQuickSeeded` 标记保证只播种一次（用户删掉后不会再自己长回来）。
    static func seedQuickActionsIfNeeded() {
        let store = UserDefaults(suiteName: suite)
        if store?.bool(forKey: seedKey) == true { return }
        var list = readList(forKey: key)
        if list.isEmpty { list = readList(forKey: snapshotKey) }
        var seeded = AevonQuickAction.allIDs
        for id in list where !seeded.contains(id) { seeded.append(id) }
        store?.set(sanitize(seeded), forKey: key)
        store?.set(sanitize(seeded), forKey: snapshotKey)
        store?.set(true, forKey: seedKey)
        store?.synchronize()
        cached = sanitize(seeded)
        AevonLog.info("[圆盘] 已把「截图 / 录屏」一次性写进圆盘列表（之后可在设置页增删、排序）"
            + "（AevonQuickEditableV263）")
    }

    private static let seedKey = "RingQuickSeeded"

    /// 设置页广播 prefschanged 后调用（**唯一**的跨进程刷新入口）。
    /// 读到可信列表就更新缓存并写快照；读到空列表时保留旧缓存（防漂移读）。
    ///
    /// V0.3.21（AevonPrefsGateV321）：**列表没变就立刻返回**。
    /// 这条函数挂在 `aevonPrefsChangedHandler` 上，而那个 handler 只要**任何**偏好
    /// 变化就会跑（拖阻尼滑条时每帧一次，16~17ms）。原来每帧都 `set(snapshotKey)`
    /// 一次 —— 那是一次跨进程 cfprefsd 写盘，白扔。现在只有列表真的不一样才落盘。
    /// 判据用 `cached`（进程内权威缓存）对比新读到的列表，相等即跳过。
    static func refreshFromSettings() {
        let list = readList(forKey: key)
        if !list.isEmpty {
            if let current = cached, current == list { return }
            cached = list
            UserDefaults(suiteName: suite)?.set(list, forKey: snapshotKey)
        } else if cached == nil {
            cached = readList(forKey: snapshotKey)
        }
    }

    static func save(_ list: [String]) {
        let out = sanitize(list)
        cached = out
        let store = UserDefaults(suiteName: suite)
        store?.set(out, forKey: key)
        store?.set(out, forKey: snapshotKey)
        store?.synchronize()
        AevonLog.info("[圆盘] 已保存 \(out.count) 个 App：\(out.joined(separator: ", "))")
    }

    /// V0.0.27：设置页改完圆盘列表后会广播 com.aevon.prefschanged。
    /// V0.0.31：改为 `refreshFromSettings()`（带快照与防漂移），只在真正改列表时刷新 ——
    /// 旧版 0.2 秒轮询里盲目清缓存是排序漂移的元凶，禁止改回。
    static func contains(_ bundleID: String) -> Bool {
        return bundleIDs().contains(bundleID)
    }

    /// 加入 / 移出，返回「现在是否在圆盘里」。
    @discardableResult
    static func toggle(_ bundleID: String) -> Bool {
        var list = bundleIDs()
        if let index = list.firstIndex(of: bundleID) {
            list.remove(at: index)
            save(list)
            return false
        }
        guard list.count < maxCount else {
            AevonLog.warn("[圆盘] 已达上限 \(maxCount) 个，忽略加入 \(bundleID)")
            return false
        }
        list.append(bundleID)
        save(list)
        return true
    }

    static func remove(_ bundleID: String) {
        var list = bundleIDs()
        guard let index = list.firstIndex(of: bundleID) else { return }
        list.remove(at: index)
        save(list)
    }

    /// 首次使用：用候选 App 填几个，保证呼出圆盘时不是空的。
    static func seedIfNeeded(from apps: [InstalledApp]) {
        guard bundleIDs().isEmpty, !apps.isEmpty else { return }
        let seed = Array(apps.prefix(10)).map { $0.bundleID }
        save(seed)
        AevonLog.info("[圆盘] 首次使用，已用 \(seed.count) 个 App 预填（可在面板「编辑圆盘」里改）")
    }
}
