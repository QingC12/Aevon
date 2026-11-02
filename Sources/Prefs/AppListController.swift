//
//  AppListController.swift — Aevon, the operator's own icon list.
//
//  This build adds what the settings could not do before: choose which apps the
//  shape carries, drop the ones that should not be there, and put them in a
//  specific order. The list is the thing SpringBoard reads, so a change here
//  is visible on the desktop without a respring.
//
//  Why a plain table view and not a PSSpecifier page: reordering and swipe-to-
//  delete are table-view behaviours. Re-implementing them on top of the
//  Preferences cell machinery would mean writing drag bookkeeping by hand for
//  no gain, and the whole point of this release is that the panel stops being
//  a picture of settings.
//
//  Everything is written through RingApps, which is the single source of truth
//  for both binaries. No local copy of the list is ever kept in memory between
//  appearances — the file is read back, so Settings and SpringBoard cannot
//  drift.
//

import UIKit

final class AppListController: UIViewController {

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var ids: [String] = []
    private let emptyLabel = UILabel()

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "应用与排序"
        view.backgroundColor = .systemGroupedBackground

        table.dataSource = self
        table.delegate = self
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.backgroundColor = .clear
        table.keyboardDismissMode = .onDrag
        view.addSubview(table)

        emptyLabel.text = """
        还没有选择任何 App。
        现在托盘显示系统自动挑选的前 12 个。
        点右上角「+」从已安装应用里添加,
        或用手指拖动右侧把手调整顺序。
        """
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        table.backgroundView = emptyLabel

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self,
                            action: #selector(addApps)),
            UIBarButtonItem(title: "排序", style: .plain, target: self,
                            action: #selector(toggleEditing)),
        ]

        reloadList()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from the picker: re-read the file, never a cached array.
        reloadList()
    }

    // MARK: Data

    private func reloadList() {
        ids = RingApps.selectedIDs()
        if ids.isEmpty {
            table.backgroundView = emptyLabel
        } else {
            table.backgroundView = nil
        }
        table.reloadData()
        updateEditButton()
    }

    private var showsClearRow: Bool {
        return !ids.isEmpty && !table.isEditing
    }

    private func updateEditButton() {
        let item = navigationItem.rightBarButtonItems?.last
        item?.title = table.isEditing ? "完成" : "排序"
        item?.isEnabled = !ids.isEmpty
    }

    @objc private func toggleEditing() {
        table.setEditing(!table.isEditing, animated: true)
        table.reloadData()          // the clear row comes and goes with the mode
        updateEditButton()
    }

    @objc private func addApps() {
        let picker = AppPickerController()
        picker.onChange = { [weak self] in
            self?.reloadList()
        }
        if let navigation = navigationController {
            navigation.pushViewController(picker, animated: true)
        } else {
            present(UINavigationController(rootViewController: picker), animated: true)
        }
    }

    /// One write path, so "changed something" can never forget to tell the
    /// desktop.
    private func committed(_ ids: [String], _ what: String, reloadNow: Bool = true) {
        let ok = RingApps.save(ids)
        self.ids = RingApps.selectedIDs()
        notifyPost(Aevon.notePrefs)
        Log.write("prefs: apps \(what) -> \(self.ids.count) \(ok ? "" : "(write failed)")")

        if reloadNow {
            // Delete needs the table and the model to agree before the batch
            // ends, otherwise UIKit counts a row that no longer exists.
            table.reloadData()
            updateEditButton()
        } else {
            // A move has already happened on screen; only the model needs to
            // catch up, and doing that mid-batch is how rows end up misplaced.
            DispatchQueue.main.async { [weak self] in self?.reloadList() }
        }
    }

    private func confirmClear() {
        let sheet = UIAlertController(
            title: "恢复为自动列表？",
            message: "当前选择的 \(ids.count) 个 App 与顺序会被清空，托盘改回系统自动挑选。",
            preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        sheet.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            RingApps.reset()
            self?.reloadList()
            notifyPost(Aevon.notePrefs)
            Log.write("prefs: apps cleared, back to automatic")
        })
        present(sheet, animated: true)
    }
}

// MARK: - Table

extension AppListController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { return 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return ids.count + (showsClearRow ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let capacity = RingConfig.load().capacity
        return "顺序即托盘顺序：第一个 App 落在起始角上，其余顺时针排。"
             + "当前形状最多显示 \(capacity) 个，列表最多可存 \(RingApps.maxCount) 个。"
             + "改动立即作用到桌面，不需要重载。"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "app")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "app")

        guard indexPath.row < ids.count else {
            cell.textLabel?.text = "恢复为自动列表"
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
            cell.detailTextLabel?.text = nil
            cell.imageView?.image = nil
            cell.selectionStyle = .default
            cell.showsReorderControl = false
            return cell
        }

        let id = ids[indexPath.row]
        let item = RingIcons.item(for: id) ?? InstalledApp(bundleID: id, name: id, path: nil)
        cell.textLabel?.textAlignment = .natural
        cell.textLabel?.textColor = .label
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.text = item.bundleID
        cell.imageView?.image = RingIcons.image(for: item)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.selectionStyle = .none
        cell.showsReorderControl = true
        return cell
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return indexPath.row < ids.count
    }

    func tableView(_ tableView: UITableView,
                   moveRowAt sourceIndexPath: IndexPath,
                   to destinationIndexPath: IndexPath) {
        var updated = ids
        guard sourceIndexPath.row < updated.count else { return }
        let id = updated.remove(at: sourceIndexPath.row)
        updated.insert(id, at: Swift.min(destinationIndexPath.row, updated.count))
        committed(updated, "reorder \(sourceIndexPath.row)->\(destinationIndexPath.row)",
                  reloadNow: false)
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < ids.count else { return }
        let id = ids[indexPath.row]

        // Update the model, then delete exactly that row. Calling reloadData()
        // inside a swipe's commit block makes UIKit compare two different row
        // counts inside one batch — that is an assertion, not a redraw.
        var updated = ids
        updated.remove(at: indexPath.row)
        ids = updated
        let ok = RingApps.save(updated)
        notifyPost(Aevon.notePrefs)
        Log.write("prefs: apps remove \(id) -> \(ids.count) \(ok ? "" : "(write failed)")")

        tableView.deleteRows(at: [indexPath], with: .automatic)
        // The footer (capacity) and the empty view come from the model, so a
        // deferred reload keeps them honest without touching this batch.
        DispatchQueue.main.async { [weak self] in self?.reloadList() }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row >= ids.count else { return }
        confirmClear()
    }
}
