//
//  AppPickerController.swift — Aevon, the disc's "添加 App / 动作" page.
//
//  0.0.42 — a 1:1 port of the archived plugin's `AevonRingAddController.m`.
//  Same plain (non-inset) table, same rule: tap a row to add it, tap again to
//  remove it, checkmark shows membership, a cap alert at 36 — and the two
//  quick actions (截图 / 录屏) pinned at the very top, so they can always be
//  added back after a delete (V0.2.63, the user's own request in that build).
//
//  Every change is written through AevonRingStore and broadcast immediately:
//  the disc on the desktop re-reads the store the next time it is summoned.
//

import UIKit

final class AppPickerController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView(frame: .zero, style: .plain)
    private var apps: [[String: String]] = []
    private var selected: [String] = []
    private var nameCache: [String: String] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "添加 App / 动作"
        view.backgroundColor = .systemBackground

        // V0.2.63（AevonQuickEditableV263）：截图 / 录屏是「动作」，不是装出来的 App。
        // 放在列表最前面，删掉之后还能从「+」加回来。
        let actions: [[String: String]] = [
            ["id": AevonQuickAction.screenshotID, "name": "截图（系统）"],
            ["id": AevonQuickAction.recordingID,  "name": "录屏（系统）"],
        ]
        apps = actions + RingIcons.catalogue().map {
            ["id": $0.bundleID, "name": $0.name]
        }
        selected = AevonRingStore.bundleIDs()

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 54
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(table)
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return apps.count
    }

    private func name(for bundleID: String) -> String {
        if let cached = nameCache[bundleID], !cached.isEmpty { return cached }
        let name = RingIcons.item(for: bundleID)?.name ?? bundleID
        nameCache[bundleID] = name
        return name
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AevonRingAddCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "AevonRingAddCell")
        let app = indexPath.row < apps.count ? apps[indexPath.row] : [:]
        let bundleID = app["id"] ?? ""
        let name = app["name"] ?? bundleID
        cell.textLabel?.text = name
        cell.detailTextLabel?.text = bundleID
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        let icon = AevonAppIcon.image(bundleID: bundleID, size: 30)
            ?? RingIcons.placeholder(named: name)
        cell.imageView?.image = icon
        cell.accessoryType = selected.contains(bundleID) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < apps.count else { return }
        guard let bundleID = apps[indexPath.row]["id"], !bundleID.isEmpty else { return }

        if let index = selected.firstIndex(of: bundleID) {
            selected.remove(at: index)
        } else {
            guard selected.count < AevonRingStore.maxCount else {
                let alert = UIAlertController(
                    title: "已达上限",
                    message: "圆盘最多放 \(AevonRingStore.maxCount) 个 App，先在列表里移除几个。",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
                present(alert, animated: true)
                return
            }
            selected.append(bundleID)
        }
        AevonRingStore.save(selected)
        notifyPost(Aevon.notePrefs)
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}
