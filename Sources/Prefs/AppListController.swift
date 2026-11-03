//
//  AppListController.swift — Aevon, the disc app editor (圆盘 App).
//
//  0.0.42 — a 1:1 port of the archived plugin's `AevonRingEditorController.m`
//  (the user's own code, V0.0.27 → V0.3.x). Same title, same bar buttons,
//  same numbered rows, same reorder / swipe-delete / cap, same footer text —
//  translated from ObjC to Swift because this bundle is Swift, in the same
//  file order, with the same comments where they explain a decision.
//
//  Why a plain table view and not a PSSpecifier page (from the original):
//  specifier arrays and the preference array are two sets of indices, drag
//  reordering needs its own mapping, and PSListController has no edit-mode
//  entry. A UIViewController + UITableView keeps behaviour fully controllable.
//
//  Storage goes through AevonRingStore — the exact store the disc reads — and
//  every change is broadcast to SpringBoard immediately, no respring.
//

import UIKit

final class AppListController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var items: [String] = []
    private var nameCache: [String: String] = [:]

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "圆盘 App"
        view.backgroundColor = .systemBackground

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 56
        table.allowsSelectionDuringEditing = false
        table.setEditing(false, animated: false)
        if #available(iOS 15.0, *) {
            table.sectionHeaderTopPadding = 0
        }
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(table)

        updateBarButtons()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadFromPrefs()
    }

    private func reloadFromPrefs() {
        items = AevonRingStore.bundleIDs()
        table.reloadData()
    }

    // MARK: Bar buttons

    /// 非编辑态：右上 `+`（添加）与「编辑」；编辑态：右上只留「完成」，左上关闭隐藏
    private func updateBarButtons() {
        let edit = UIBarButtonItem(title: table.isEditing ? "完成" : "编辑",
                                   style: .plain, target: self,
                                   action: #selector(toggleEditing))

        if table.isEditing {
            navigationItem.rightBarButtonItems = [edit]
            navigationItem.leftBarButtonItem = nil
            return
        }

        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self,
                                  action: #selector(openAdd))
        navigationItem.rightBarButtonItems = [add, edit]
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                           target: self,
                                                           action: #selector(closeEditor))
    }

    @objc private func closeEditor() {
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigationController?.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func toggleEditing() {
        table.setEditing(!table.isEditing, animated: true)
        updateBarButtons()
    }

    @objc private func openAdd() {
        let add = AppPickerController()
        navigationController?.pushViewController(add, animated: true)
    }

    // MARK: Names

    private func name(for bundleID: String) -> String {
        if let cached = nameCache[bundleID], !cached.isEmpty { return cached }
        // V0.2.63（AevonQuickEditableV263）：截图 / 录屏是「动作」不是 App，
        // LSApplicationProxy 查不到，这里给它们一个正常名字。
        if bundleID == AevonQuickAction.screenshotID {
            nameCache[bundleID] = "截图（系统）"
            return "截图（系统）"
        }
        if bundleID == AevonQuickAction.recordingID {
            nameCache[bundleID] = "录屏（系统）"
            return "录屏（系统）"
        }
        let name = RingIcons.item(for: bundleID)?.name ?? bundleID
        nameCache[bundleID] = name
        return name
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AevonRingEditorCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "AevonRingEditorCell")
        let bundleID = indexPath.row < items.count ? items[indexPath.row] : ""
        let name = self.name(for: bundleID)
        cell.textLabel?.text = "\(indexPath.row + 1). \(name)"
        cell.detailTextLabel?.text = bundleID
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        let icon = AevonAppIcon.image(bundleID: bundleID, size: 32)
            ?? letterIcon(name: name, bundleID: bundleID, size: 32)
        cell.imageView?.image = icon
        cell.showsReorderControl = true
        return cell
    }

    /// 名字首字的色块图标（取不到原生图标时的兜底）——原版逐行照搬。
    private func letterIcon(name: String, bundleID: String, size: CGFloat) -> UIImage {
        let size = max(size, 8)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size),
                                               format: format)
        return renderer.image { _ in
            var hasher = UInt(bitPattern: bundleID.hashValue)
            hasher = hasher &* 31 &+ 0x9E37
            let hue = CGFloat(hasher % 360) / 360.0
            UIColor(hue: hue, saturation: 0.55, brightness: 0.78, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                         cornerRadius: size * 0.24).fill()
            let letter = String(name.prefix(1))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.52, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = (letter as NSString).size(withAttributes: attrs)
            (letter as NSString).draw(at: CGPoint(x: (size - textSize.width) / 2,
                                                  y: (size - textSize.height) / 2),
                                      withAttributes: attrs)
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView,
                   editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .delete
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < items.count else { return }
        items.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        AevonRingStore.save(items)
        notifyPost(Aevon.notePrefs)
    }

    func tableView(_ tableView: UITableView,
                   moveRowAt sourceIndexPath: IndexPath,
                   to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.row < items.count else { return }
        let moved = items.remove(at: sourceIndexPath.row)
        let target = Swift.min(destinationIndexPath.row, items.count)
        items.insert(moved, at: target)
        AevonRingStore.save(items)
        notifyPost(Aevon.notePrefs)
    }

    func tableView(_ tableView: UITableView,
                   titleForFooterInSection section: Int) -> String? {
        return "共 \(items.count) 个（上限 \(AevonRingStore.maxCount)）。"
             + "点右上「编辑」后，按住右侧把手上下拖动即可排序，左滑删除。"
    }
}
