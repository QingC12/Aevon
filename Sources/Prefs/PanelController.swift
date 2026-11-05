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
import ObjectiveC

@objc(AevonPanelController)
final class PanelController: PSListController {

    private let panelID: String
    private let panelTitle: String

    init(panelID: String, title: String) {
        self.panelID = panelID
        self.panelTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    /// 0.1.38 — 返 nil，不 `fatalError`：设置面板被 nib 反序列化时宁可空一页，
    /// 也不该把 Preferences 进程打死。
    required init?(coder: NSCoder) {
        return nil
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = panelTitle
        installRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installRows()   // always: a panel must show its own plist, every time
        reload()
    }

    // MARK: Rows

    /// Loads this panel's plist into `specifiers`.
    ///
    /// 0.0.6 kept an early return here — "rows already exist, nothing to do" —
    /// copied from the root page. That was right for the root page and wrong
    /// for every panel: Preferences pre-populates a freshly pushed controller
    /// with its own rows, so the return fired, our plist was never read, and
    /// all eight panels showed the same handful of switches. The rows are now
    /// always replaced, and the counts are logged so the next report can tell
    /// "preloaded" from "loaded" without guessing.
    /// Which panel's rows are currently installed. Without it, every return
    /// from a sub-page rebuilt the table from the top: the switch you just
    /// flipped comes back into view, but so does the scroll position, and a
    /// panel you had scrolled halfway down jumps back to the top.
    private var installedPanel: String?

    private func installRows() {
        let bundle = Bundle(for: PanelController.self)
        let preloaded = specifiers?.count ?? 0

        let rows = SpecifierBootstrap.load(named: panelID, target: self, bundle: bundle)
        let loaded = rows?.count ?? 0

        let samePanel = (installedPanel == panelID && loaded == preloaded && loaded > 0)
        if loaded > 0 {
            if !samePanel {
                specifiers = rows
                installedPanel = panelID
            }
        } else if preloaded == 0 {
            // Nothing loaded and nothing pre-filled: draw the diagnostic rather
            // than an empty page. Once rows exist, never replace them with it.
            specifiers = diagnosticRows(bundle: bundle)
            installedPanel = nil
        }
        // loaded == 0 && preloaded > 0 keeps what the framework gave us: a page
        // with the wrong rows still beats a page with none.

        // Plain concatenation, no interpolation: this exact literal is what
        // tools/audit-deb.py looks for to prove PanelController is in the
        // bundle at all. A marker that the optimiser can rewrite is not a
        // marker.
        Log.write("prefs: panel loader v1 " + panelID
                  + " loaded=" + String(loaded)
                  + " preloaded=" + String(preloaded)
                  + " final=" + String(specifiers?.count ?? 0)
                  + (samePanel ? " kept" : " installed"))
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
            // Says what this side knows: the switch state and the geometry the
            // host will read. It cannot claim "mounted" — only SpringBoard's
            // log line can prove that.
            return config.desktop
                ? "开关已开启 · \(config.summary)"
                : "开关已关闭（桌面无握把）"
        }
        if key == "@ring.apps" {
            return "已选 \(AevonRingStore.bundleIDs().count) / 上限 \(AevonRingStore.maxCount)（设置内编辑）"
        }
        if key == "@ring.star" {
            return "收藏随圆盘本体移交旧版实现（0.0.42），不再单独计数"
        }
        return super.readPreferenceValue(specifier)
    }

    override func setPreferenceValue(_ value: Any?, specifier: PSSpecifier) {
        let key = (specifier.property(forKey: "key") as? String) ?? ""

        super.setPreferenceValue(value, specifier: specifier)

        if RingConfig.mirroredKeys.contains(key) {
            ringChanged(named: key, value: value)
        }
    }

    // MARK: Actions

    /// The Ring panel's own buttons. In 0.0.6 this panel shipped a preview
    /// button whose action only the root controller implemented, so it was
    /// another row that looked alive and did nothing.
    @objc func previewRing(_ specifier: PSSpecifier) {
        RingActions.preview(from: self)
    }

    @objc func editApps(_ specifier: PSSpecifier) {
        RingActions.editApps(from: self)
    }

    /// 窗口与场景 · 探针. Runs in SpringBoard, not here: see SceneActions.
    @objc func sceneProbe(_ specifier: PSSpecifier) {
        SceneActions.probeScene(from: self)
    }

    /// 窗口与场景 · 接口面探针. The dump that decides how P1 is built.
    @objc func sceneSurface(_ specifier: PSSpecifier) {
        SceneActions.probeSurface(from: self)
    }

    /// 窗口与场景 · 调用点核对. Every call the master makes, resolved to the
    /// class that defines it here. Runs in SpringBoard, never in this bundle.
    @objc func sceneCalls(_ specifier: PSSpecifier) {
        SceneActions.probeCalls(from: self)
    }

    /// 窗口与场景 · 建窗取证. Reads a live scene, then builds one from a copy of
    /// it. The only button here that writes to FrontBoard.
    @objc func sceneWindow(_ specifier: PSSpecifier) {
        SceneActions.probeWindow(from: self)
    }

    /// Keys driven by a slider. A drag produces a value per touch event, so
    /// these are coalesced; a switch produces exactly one and is written at
    /// once.
    /// 0.1.24 — 竖条那三个键（`!ring.barY` / `!ring.barLength` / `!ring.barWidth`）
    /// 随滑块一起下线。表里留一个已经不存在的滑块名，只是让 `setPreferenceValue`
    /// 每次多查一次集合。
    private static let sliderKeys: Set<String> = [
        "Radius", "IconWidth", "RotationAngle", "LastIconAngle",
        "DampingFraction", "INTENSITY", "Speed",
    ]

    private var lastWrite = Date.distantPast
    private var flushItem: DispatchWorkItem?

    /// Writes the snapshot *before* posting: the receiver reads the file, so a
    /// notification that arrives early must never see the previous values.
    ///
    /// A drag would otherwise write the file and post a Darwin notification on
    /// every touch event — a hundred atomic writes a second into /var/mobile,
    /// which is exactly the kind of thing that makes a slider feel sticky. The
    /// rate is capped, and a trailing write makes sure the value the finger
    /// stopped on is the value that lands.
    private func ringChanged(named key: String, value: Any?) {
        let isSlider = PanelController.sliderKeys.contains(key)
        if isSlider, Date().timeIntervalSince(lastWrite) < 0.08 {
            flushItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.flushRing(key: key, value: value)
            }
            flushItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
            return
        }
        flushRing(key: key, value: value)
    }

    private func flushRing(key: String, value: Any?) {
        flushItem?.cancel()
        flushItem = nil
        lastWrite = Date()

        let config = RingConfig.load()
        if config.writeSnapshot() {
            Log.write("prefs: \(key)=\(value.map { "\($0)" } ?? "nil") -> \(config.summary) "
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
            if key == "@ring.summary" || key == "@ring.host"
                || key == "@ring.apps" {
                let sel = NSSelectorFromString("reloadSpecifier:")
                // 0.1.38 — 不再用 `perform(_:with:)`。它把返回值当对象交给自动
                // 释放池，而 `reloadSpecifier:` 返回 void：那一格寄存器里是上一
                // 条指令留下的垃圾，被 autorelease 就是一次野指针。按真实签名
                // 调 IMP，返回值根本不碰。
                if responds(to: sel), let method = class_getInstanceMethod(type(of: self), sel) {
                    typealias Reload = @convention(c) (AnyObject, Selector, AnyObject) -> Void
                    let call = unsafeBitCast(method_getImplementation(method), to: Reload.self)
                    call(self, sel, row)
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
