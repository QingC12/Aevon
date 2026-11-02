//
//  PanelController.swift — Aevon, one settings sub-page.
//
//  0.0.5 shipped eight rows labelled 窗口与场景 … 监听与系统动作 that could not
//  be opened. They were PSChildPaneSpecifier rows, and this iOS does not give
//  that cell class a selection: the panels existed as plists and as documents,
//  but not as something a finger could reach.
//
//  0.0.6 removes the dependency on the framework's own pane mechanism:
//    · the root rows are plain buttons with an explicit action
//    · this controller is created by us, for a named plist
//    · the rows are loaded through the same explicit call that un-blacked the
//      root page in 0.0.4, so a missing file shows a readable line instead of
//      an empty page
//
//  Writes are real, not cosmetic: every switch/slider lands in the com.aevon
//  domain, the ring keys are mirrored to ring.plist, and a Darwin notification
//  tells SpringBoard to re-read it. That is the whole link between the panel
//  and the thing on the home screen.
//

import UIKit

@objc(AevonPanelController)
final class PanelController: PSListController {

    private let panelID: String
    private let panelTitle: String

    init(panelID: String, title: String) {
        self.panelID = panelID
        self.panelTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("PanelController is created in code only")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = panelTitle
        installRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installRows()
        reload()
    }

    // MARK: Rows

    private func installRows() {
        if let existing = specifiers, existing.count > 0 { return }

        let bundle = Bundle(for: PanelController.self)
        let rows = SpecifierBootstrap.load(named: panelID, target: self, bundle: bundle)
        if (rows?.count ?? 0) > 0 {
            specifiers = rows
        } else {
            specifiers = diagnosticRows(bundle: bundle)
        }
        Log.write("prefs: panel \(panelID) -> \(specifiers?.count ?? 0) rows")
    }

    private func diagnosticRows(bundle: Bundle) -> NSMutableArray {
        let path = bundle.path(forResource: panelID, ofType: "plist") ?? "缺失"
        let group = PSSpecifier.emptyGroup()
        group.setProperty("面板未能加载", forKey: "label")
        group.setProperty("""
            这不是崩溃，是 \(panelID).plist 没被读到。
            bundle: \(bundle.bundlePath)
            plist: \(path)
            """, forKey: "footerText")
        let list = NSMutableArray()
        list.add(group)
        return list
    }

    // MARK: Values

    override func readPreferenceValue(_ specifier: PSSpecifier) -> Any? {
        let key = (specifier.property(forKey: "key") as? String) ?? ""
        if key == "@ring.summary" {
            return RingConfig.load().summary
        }
        if key == "@ring.host" {
            let config = RingConfig.loadRuntime()
            return config.desktop ? "已挂载 · \(config.summary)" : "未挂载（开关关闭）"
        }
        return super.readPreferenceValue(specifier)
    }

    override func setPreferenceValue(_ value: Any?, specifier: PSSpecifier) {
        let key = (specifier.property(forKey: "key") as? String) ?? ""

        // The four shapes are a radio group in the master's UI. Turning one on
        // switches the other three off in the same write, otherwise the ring
        // would be asked to be a circle and a quarter-circle at once and the
        // answer would depend on the order the switches were tapped in.
        if ["RTSIF", "RTSIH", "RTSIQ", "RTSIZ"].contains(key) {
            let on = (value as? NSNumber)?.boolValue ?? false
            if on {
                let store = UserDefaults(suiteName: Aevon.domain)
                for other in ["RTSIF", "RTSIH", "RTSIQ", "RTSIZ"] where other != key {
                    store?.set(false, forKey: other)
                }
                store?.synchronize()
            }
            super.setPreferenceValue(value, specifier: specifier)
            ringChanged(named: key, value: on)
            return
        }

        super.setPreferenceValue(value, specifier: specifier)

        if RingConfig.mirroredKeys.contains(key) {
            ringChanged(named: key, value: (value as? NSNumber)?.boolValue ?? false)
        }
    }

    /// Writes the snapshot *before* posting: the receiver reads the file, so a
    /// notification that arrives early must never see the previous values.
    private func ringChanged(named key: String, value: Bool) {
        let config = RingConfig.load()
        if config.writeSnapshot() {
            Log.write("prefs: \(key)=\(value) -> \(config.summary) "
                      + (config.desktop ? "(desktop on)" : "(desktop off)"))
        }
        notifyPost(Aevon.notePrefs)
        refreshSummaryRow()
    }

    /// Only the summary row is reloaded. A full reload() while a slider is
    /// being dragged would tear the table out from under the finger.
    private func refreshSummaryRow() {
        guard let rows = specifiers else { return }
        for element in rows {
            guard let row = element as? PSSpecifier,
                  let key = row.property(forKey: "key") as? String else { continue }
            if key == "@ring.summary" || key == "@ring.host" {
                if responds(to: NSSelectorFromString("reloadSpecifier:")) {
                    _ = perform(NSSelectorFromString("reloadSpecifier:"), with: row)
                } else {
                    reload()
                    return
                }
            }
        }
    }
}

// MARK: - Row loading, shared with the root page

enum SpecifierBootstrap {

    /// Three attempts, cheapest first, and the last one always returns
    /// something readable:
    ///   1. the classic two-argument loader
    ///   2. the bundle-explicit overload, guarded by responds(to:)
    ///   3. nil — the caller draws its own diagnostic group
    static func load(named name: String, target: PSListController,
                     bundle: Bundle) -> NSMutableArray? {
        var rows = target.loadSpecifiers(fromPlistName: name, target: target)
        if (rows?.count ?? 0) == 0,
           target.responds(to: NSSelectorFromString("loadSpecifiersFromPlistName:target:bundle:")) {
            rows = target.loadSpecifiers(fromPlistName: name, target: target, bundle: bundle)
        }
        return rows
    }
}

// Same reason as RootListController: PreferenceLoader and the root page both
// name this class as a string, so one direct reference keeps it alive.
private let aevonPanelControllerKeepAlive: AnyClass = PanelController.self
