//
//  AppPickerController.swift — Aevon, the "add an app" page.
//
//  Lists every installed application once, with a search field, and toggles
//  membership. The list is deliberately *all* apps with a check mark rather
//  than "installed minus selected": removing an app is then the same gesture as
//  adding one, and a mistake is one tap away from being undone.
//
//  Icons are produced per visible row only. A phone with 200 apps would
//  otherwise draw 200 tiles (each one a UIGraphicsImageRenderer pass) before
//  the first cell appeared.
//

import UIKit

final class AppPickerController: UIViewController {

    /// Called after every change so the parent list can re-read the file.
    var onChange: (() -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    private let search = UISearchBar(frame: .zero)
    private var all: [InstalledApp] = []
    private var shown: [InstalledApp] = []
    private var selected: Set<String> = []
    private var query = ""

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "添加应用"
        view.backgroundColor = .systemBackground

        search.delegate = self
        search.placeholder = "搜索名称或 bundle id"
        search.searchBarStyle = .minimal
        search.sizeToFit()

        table.dataSource = self
        table.delegate = self
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.keyboardDismissMode = .onDrag
        table.tableHeaderView = search
        view.addSubview(table)

        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))

        // Catalogue first, then the file: one LaunchServices walk, cached in
        // RingIcons for the whole process.
        all = RingIcons.catalogue()
        selected = Set(RingApps.selectedIDs())
        applyFilter()
        Log.write("prefs: picker catalogue \(all.count) apps, selected \(selected.count)")
    }

    @objc private func done() {
        onChange?()
        if let navigation = navigationController {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func applyFilter() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            shown = all
        } else {
            shown = all.filter {
                $0.name.lowercased().contains(needle) || $0.bundleID.lowercased().contains(needle)
            }
        }
        table.reloadData()
    }

    private func toggle(_ item: InstalledApp) {
        if selected.contains(item.bundleID) {
            RingApps.remove(item.bundleID)
            selected.remove(item.bundleID)
            Log.write("prefs: apps remove \(item.bundleID)")
        } else {
            guard selected.count < RingApps.maxCount else {
                alert("已达上限", "最多 \(RingApps.maxCount) 个。先移除一个再添加。")
                return
            }
            RingApps.add(item.bundleID)
            selected.insert(item.bundleID)
            Log.write("prefs: apps add \(item.bundleID)")
        }
        notifyPost(Aevon.notePrefs)
        onChange?()
        table.reloadData()
    }

    private func alert(_ title: String, _ message: String) {
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
        present(sheet, animated: true)
    }
}

// MARK: - Table

extension AppPickerController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return shown.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pick")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "pick")
        let item = shown[indexPath.row]
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.text = item.bundleID
        cell.imageView?.image = RingIcons.image(for: item)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.accessoryType = selected.contains(item.bundleID) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        toggle(shown[indexPath.row])
    }
}

// MARK: - Search

extension AppPickerController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
