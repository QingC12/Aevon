//
//  AevonAppPanel.swift — Aevon, the app chooser behind the disc's hub.
//
//  0.0.56 — 圆盘中心那个四宫格，以前点下去是把「设置」App 推到前台（一个
//  tweak 能诚实做到的唯一一件事）。操作者要的是一个**面板**：所有桌面 App
//  都在里面，点一个就打开。它是圆盘的第二个入口，不是设置页的替身。
//
//  数据只有一个来源：`RingIcons.catalogue()` —— 同一份已经滤掉白图标的表，
//  所以「面板里有、设置里没有」这件事从结构上就不会发生。
//
//  右手单手优先，三条落地：
//
//    · 面板只占屏幕下半部（62 %，上限 620 pt）。顶边落在拇指自然能到的高度，
//      上面还留着上下文 —— 你知道自己刚才在哪个页面。
//    · 主操作全在拇指一侧：关闭钮在面板右上角，字母索引贴着右缘，往下拖标题区
//      就能收起。没有任何一样东西要求换手。
//    · 点击目标大于系统标准：图标 54 pt、单元 88 pt 高，相邻单元之间还有 8 pt
//      空隙 —— 拇指侧面按下去也不会点到隔壁。
//
//  没有输入框。SpringBoard 进程里弹键盘是一条要看系统脸色的路（它不一定有
//  keyboard window），而这里要解决的是「几百个 App 里找到那一个」—— 贴右缘的
//  字母索引比键盘快，而且它就在拇指下面。
//

import UIKit

final class AevonAppPanel: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate,
                          UITextFieldDelegate {

    /// 同一时刻只允许一个面板。`RingHost` 用它判断「面板是否在屏」，
    /// 竖条和右缘手势带据此让路。
    private(set) static var current: AevonAppPanel?

    /// 选中一个 App。参数是 bundle id。
    var onPick: ((String) -> Void)?
    /// 面板关掉了。参数是原因（日志用）。
    var onClose: ((String) -> Void)?

    // MARK: - Views

    private let dim = UIControl()
    private let sheetHost = UIView()
    private let sheet = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let sheen = CAGradientLayer()
    private let grabber = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let scroll = UIScrollView()
    private let indexBar = UIView()
    /// 0.0.57 — 搜索框。放在标题区第二行，也就是抽屉最上面那一条：右手拇指
    /// 不用挪手就能够到，输入时键盘从底部升起来也不会把它盖住。
    private let searchField = UITextField()
    private let searchPlate = UIView()

    // MARK: - Geometry

    /// 0.0.58 — 4 列变 5 列。4 列时一屏只看得到两行半（20 个），拇指要滑
    /// 两三次才翻完一页；5 列 × 70 pt 的行高把同一块高度塞进三行多，一页
    /// 三十个。列再往上加，最左那一列就要伸手去够，所以 5 是这一版的止点。
    private let columnCount = PanelRowView.columns
    private let sideInset: CGFloat = 18
    /// 右侧多留一条，给字母索引。索引压在网格上会挡住最后一列的长名字。
    private let indexLane: CGFloat = 22
    private let columnGap: CGFloat = 8
    /// 88 → 70：图标从 54 降到 44 之后，一格只需要 44 + 6 + 14 ≈ 64，
    /// 留 6 给上下呼吸。行高不跟着降，缩小图标就只是让格子变空。
    private let rowHeight: CGFloat = 70
    private let headerHeight: CGFloat = 26
    /// 0.0.57 — 76 变 118：多出来的 42 是搜索框那一行。抽屉高度没变，列表短
    /// 了一条，但 4 列 × 88 pt 的网格仍然一次能看到两行半。
    private let titleAreaHeight: CGFloat = 118
    private let searchHeight: CGFloat = 38

    // MARK: - 拼音（0.0.58）

    /// 名字 → 拼音拉丁串（大写、无声调）。
    ///
    /// 0.0.57 之前分组只看 `name.first`：中文的第一个字符不在 A–Z 里，于是
    /// 所有中文应用都被扔进「其他」，看起来就像「只有英文会排序」。其实
    /// 排序本身没问题（`localizedStandardCompare` 在中文环境下就是按拼音），
    /// 坏的是**分组键**。
    ///
    /// `applyingTransform(.toLatin:)` 走 ICU：「微信」→「wēi xìn」，再
    /// `stripDiacritics` 去掉声调 →「wei xin」。日文、韩文同样走罗马字。
    /// 已经是拉丁字母的名字原样返回，所以这条对英文没有副作用。
    private static var keyCache: [String: String] = [:]

    static func sortKey(_ name: String) -> String {
        if let cached = keyCache[name] { return cached }
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        let key = latin.uppercased()
        keyCache[name] = key
        return key
    }

    /// 首字母分组键。不是 A–Z 的一律进「#」——emoji 开头的名字仍然归「其他」，
    /// 因为它们确实没有拼音。
    static func indexKey(_ name: String) -> Character {
        guard let first = sortKey(name).first, first >= "A", first <= "Z" else { return "#" }
        return first
    }

    // MARK: - Data

    private struct Section {
        let title: String
        let apps: [InstalledApp]
    }

    private struct Row {
        let isHeader: Bool
        let title: String
        let apps: [InstalledApp]
        var y: CGFloat = 0
        var height: CGFloat = 0
    }

    private var rows: [Row] = []
    private var live: [Int: PanelRowView] = [:]
    private var pool: [PanelRowView] = []
    private var lastWidth: CGFloat = 0
    private var dismissing = false

    /// 0.0.57 — 搜索。`allApps` 是过滤前的那张表，`filterText` 是当前输入。
    /// 两者都在这里，因为「分组视图」与「结果视图」是同一套 rows 的两种排法：
    /// 换一种排法就是换一次 `rows`，不需要第二套渲染流程。
    private var allApps: [InstalledApp] = []
    private var pinnedIDs: Set<String> = []
    private var filterText = ""
    /// 键盘升起时抽屉要跟着长高，否则结果列表有一大截在键盘底下。
    private var keyboardHeight: CGFloat = 0
    /// 抢 key 之前那一扇窗。抢了不还，桌面手势和状态栏的触摸会一起失灵 ——
    /// 那是比「键盘弹不出来」严重得多的故障。
    private weak var priorKey: UIWindow?

    // MARK: - Present

    /// - Returns: 已经显示出来的面板。
    @discardableResult
    static func present(in host: UIView,
                        onPick: @escaping (String) -> Void,
                        onClose: @escaping (String) -> Void) -> AevonAppPanel? {
        if let existing = current {
            // 已经有面板在屏上：直接撤掉再建新的。走 `dismiss` 的话要等 0.24 s
            // 的收起动画，那一下点击会变成「没反应」。
            //
            // 0.1.6 — **先把 `onClose` 叫一遍再摘**。原来这里直接置 nil，宿主的
            // 恢复逻辑（圆盘竖条 / 右缘带的触摸开关）就跟着这次替换一起消失，
            // 之后右侧再也呼不出圆盘，只能重启桌面。
            existing.onClose?("replaced")
            existing.onClose = nil
            existing.onPick = nil
            existing.searchField.resignFirstResponder()
            NotificationCenter.default.removeObserver(
                existing, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            current = nil
            existing.removeFromSuperview()
        }
        let panel = AevonAppPanel(frame: host.bounds)
        panel.onPick = onPick
        panel.onClose = onClose
        panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(panel)
        panel.build()
        current = panel
        panel.animateIn()
        return panel
    }

    // MARK: - Build

    private func build() {
        backgroundColor = .clear

        dim.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.58)
                : UIColor.black.withAlphaComponent(0.26)
        }
        dim.alpha = 0
        dim.addTarget(self, action: #selector(dimTapped), for: .touchUpInside)
        addSubview(dim)

        // 阴影放在这一层，圆角裁剪放在它里面 —— 同一个视图既裁剪又投影，
        // 影子会被一起裁掉（0.0.9 学过的）。
        sheetHost.layer.shadowColor = UIColor.black.cgColor
        sheetHost.layer.shadowOpacity = 0.42
        sheetHost.layer.shadowRadius = 26
        sheetHost.layer.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(sheetHost)

        sheet.layer.cornerRadius = 30
        sheet.layer.cornerCurve = .continuous
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.clipsToBounds = true
        sheetHost.addSubview(sheet)

        blur.frame = sheet.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.addSubview(blur)

        // 顶部一层极淡的白色渐变：把「这是一块玻璃」说清楚。
        //
        // 0.0.58 — 颜色不再写死。CAGradientLayer 的 `colors` 是 CGColor，
        // 它**不是**动态色：写一次就冻住，系统的深浅切换对它无效。浅色下
        // 白 0.14 落在浅底上是一条看不见的白线，深色下它又是唯一的光。
        // 所以颜色进 `applyPalette()`，由 trait 变化重设一次。
        sheen.startPoint = CGPoint(x: 0.5, y: 0)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        sheet.layer.addSublayer(sheen)

        grabber.backgroundColor = UIColor.label.withAlphaComponent(0.22)
        grabber.layer.cornerRadius = 2.5
        sheet.addSubview(grabber)

        titleLabel.text = "选择应用"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .label
        sheet.addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        sheet.addSubview(detailLabel)

        closeButton.setImage(UIImage(systemName: "xmark",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 13,
                                                                                    weight: .semibold)),
                             for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = UIColor.label.withAlphaComponent(0.10)
        closeButton.layer.cornerRadius = 16
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        sheet.addSubview(closeButton)

        // 0.0.57 — 搜索。一块比背景略亮的圆角底，输入框贴在上面：玻璃上直接
        // 放一个裸露的 UITextField，边缘会和背景糊在一起，看不出哪里能点。
        searchPlate.backgroundColor = UIColor.label.withAlphaComponent(0.09)
        searchPlate.layer.cornerRadius = searchHeight / 2
        searchPlate.layer.cornerCurve = .continuous
        sheet.addSubview(searchPlate)

        searchField.font = .systemFont(ofSize: 15)
        searchField.textColor = .label
        searchField.tintColor = .label
        searchField.attributedPlaceholder = NSAttributedString(
            string: "搜索应用",
            attributes: [.foregroundColor: UIColor.secondaryLabel,
                         .font: UIFont.systemFont(ofSize: 15)])
        // SpringBoard 进程里的键盘不做联想：这里输入的是应用名，不是句子。
        // 自动大写会把「微信」之外的一切都变成首字母大写，反而更难匹配。
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged),
                              for: .editingChanged)
        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        glass.tintColor = .secondaryLabel
        glass.contentMode = .scaleAspectFit
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 20))
        glass.frame = CGRect(x: 9, y: 3, width: 14, height: 14)
        holder.addSubview(glass)
        searchField.leftView = holder
        searchField.leftViewMode = .always
        sheet.addSubview(searchField)

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = true
        scroll.indicatorStyle = .default
        scroll.alwaysBounceVertical = true
        sheet.addSubview(scroll)

        indexBar.backgroundColor = .clear
        sheet.addSubview(indexBar)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(sheetPanned(_:)))
        pan.delegate = self
        sheet.addGestureRecognizer(pan)

        applyPalette()
        loadData()
        buildIndex()
    }

    /// 0.0.58 — 深浅两套配色。
    ///
    /// 面板住在 SpringBoard 的窗口里，那扇窗没有写 `overrideUserInterfaceStyle`，
    /// 所以 `traitCollection` 跟着系统走，`.label` / `.secondaryLabel` /
    /// `systemMaterial` 这些动态色自己会变。这张表只管**不会**自己变的那几样：
    /// `CAGradientLayer.colors` 是 CGColor（写一次就冻住）、阴影强度、遮罩浓度。
    ///
    /// 三个数不是调色，是三种故障：浅色下把高光留在 0.14 看不见（玻璃变成
    /// 一块死灰）；浅色下把阴影留在 0.55 会把桌面压成脏边；深色下把遮罩压到
    /// 0.26 则面板浮不起来，背景和它抢同一个亮度。
    private func applyPalette() {
        let dark = traitCollection.userInterfaceStyle == .dark
        sheen.colors = [UIColor.white.withAlphaComponent(dark ? 0.13 : 0.42).cgColor,
                        UIColor.white.withAlphaComponent(0.0).cgColor]
        sheetHost.layer.shadowOpacity = dark ? 0.55 : 0.18
        // 键盘跟面板一起变：从浅色面板上弹出一块深色键盘，那一下比配错色还刺眼。
        searchField.keyboardAppearance = dark ? .dark : .light
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyPalette()
    }

    private func loadData() {
        allApps = RingIcons.catalogue()
        pinnedIDs = Set(AevonRingStore.bundleIDs())
        rebuildGrouped()
    }

    /// 分组视图：圆盘里已有的排第一段，其余按首字母。
    private func rebuildGrouped() {
        let all = allApps
        let saved = pinnedIDs
        // 圆盘里已有的排在第一位：这个面板最常见的用法是「再开一次刚才那个」，
        // 而不是「翻遍三百个找一个新的」。快速动作（截图 / 录屏）不在 catalogue
        // 里，所以不会出现在这一段 —— 面板只管 App。
        let pinned = all.filter { saved.contains($0.bundleID) }
        let rest = all.filter { !saved.contains($0.bundleID) }

        var sections: [Section] = []
        if !pinned.isEmpty {
            sections.append(Section(title: "已在圆盘 · \(pinned.count)", apps: pinned))
        }

        // 按首字母分组。0.0.58 — 中文不再一股脑塞进「其他」：先把名字转成
        // 拉丁（拼音），去掉声调，再取首字母。系统的 `applyingTransform`
        // 走 ICU，一个中文名 ≈ 「wēi xìn」→「wei xin」→ W，和系统通讯录
        // 的索引条是同一套规则。转换结果按 bundleID 缓存，只在打开面板时
        // 算一次 —— 三百个应用逐个转是这一版唯一可能感觉到慢的地方。
        var buckets: [Character: [InstalledApp]] = [:]
        for app in rest {
            let key = AevonAppPanel.indexKey(app.name)
            buckets[key, default: []].append(app)
        }
        for key in buckets.keys.sorted(by: { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }) {
            guard var apps = buckets[key] else { continue }
            apps.sort { a, b in
                let ka = AevonAppPanel.sortKey(a.name)
                let kb = AevonAppPanel.sortKey(b.name)
                if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            sections.append(Section(title: key == "#" ? "其他" : String(key), apps: apps))
        }

        var built: [Row] = []
        for section in sections {
            built.append(Row(isHeader: true, title: section.title, apps: []))
            var index = 0
            while index < section.apps.count {
                let end = Swift.min(index + columnCount, section.apps.count)
                built.append(Row(isHeader: false, title: "",
                                 apps: Array(section.apps[index..<end])))
                index = end
            }
        }
        rows = built

        let total = all.count
        detailLabel.text = "\(total) 个可打开 · \(pinned.count) 个在圆盘"
        Log.write(String(format: "panel: catalogue built rows=%d apps=%d pinned=%d",
                         rows.count, total, pinned.count))
        buildIndex()
        relayoutRows()
    }

    /// 0.0.57 — 结果视图。搜索时把分组整个让开：分组是按字母找的，而用户已经
    /// 在打字了，再套一层「A 段 / B 段」只是把结果切碎。
    ///
    /// 排序里做了一条判断：名字以关键词开头的排前面。输入「微」时「微信」在
    /// 「企业微信」上面 —— 前缀匹配才是「我要找的那个」，包含匹配是「顺带」。
    private func rebuildResults(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { rebuildGrouped(); return }

        var hits = allApps.filter {
            $0.name.lowercased().contains(needle) || $0.bundleID.lowercased().contains(needle)
        }
        hits.sort { a, b in
            let ap = a.name.lowercased().hasPrefix(needle)
            let bp = b.name.lowercased().hasPrefix(needle)
            if ap != bp { return ap }
            // 结果里的次序和分组视图用同一把尺：拼音。否则同一个词在「分组」
            // 和「搜索」两种视图里的相对位置会不一样，找过一次的位置就失效。
            let ka = AevonAppPanel.sortKey(a.name)
            let kb = AevonAppPanel.sortKey(b.name)
            if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        var built: [Row] = []
        if hits.isEmpty {
            built.append(Row(isHeader: true, title: "没有匹配的应用", apps: []))
        } else {
            built.append(Row(isHeader: true, title: "\(hits.count) 个结果", apps: []))
            var index = 0
            while index < hits.count {
                let end = Swift.min(index + columnCount, hits.count)
                built.append(Row(isHeader: false, title: "",
                                 apps: Array(hits[index..<end])))
                index = end
            }
        }
        rows = built
        detailLabel.text = "搜索 \"\(needle)\""
        Log.write(String(format: "panel: search %@ hits=%d", needle, hits.count))
        buildIndex()
        relayoutRows()
        scroll.setContentOffset(.zero, animated: false)
    }

    private func buildIndex() {
        for view in indexBar.subviews { view.removeFromSuperview() }
        // 只给真实存在的字母做索引：二十几个空字母排下来，拇指反而找不到。
        var letters: [String] = []
        for row in rows where row.isHeader {
            letters.append(row.title.hasPrefix("已在圆盘") ? "★" : row.title)
        }
        guard letters.count > 1 else { return }
        for (i, letter) in letters.enumerated() {
            let button = UIButton(type: .custom)
            button.setTitle(letter, for: .normal)
            button.setTitleColor(.secondaryLabel, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 9.5, weight: .semibold)
            button.tag = i
            button.addTarget(self, action: #selector(indexTapped(_:)), for: .touchUpInside)
            indexBar.addSubview(button)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }

        dim.frame = bounds
        // 0.0.56 — 56 % 而不是 62 %：面板顶边落在屏幕 44 % 处，右手拇指不挪手
        // 就能够到右上角的关闭钮。再高一点，那枚按钮就要换手或者伸直手指。
        //
        // 0.0.57 — 键盘升起时抽屉跟着长高。不这样的话，56 % 的抽屉下沿正好在
        // 键盘底下：标题和搜索框看得见，结果一条也看不见。
        let base = Swift.min(bounds.height * 0.56, 560)
        let sheetHeight = keyboardHeight > 0
            ? Swift.min(bounds.height * 0.92, base + keyboardHeight * 0.86)
            : base
        sheetHost.frame = CGRect(x: 0, y: bounds.height - sheetHeight,
                                 width: bounds.width, height: sheetHeight)
        sheet.frame = sheetHost.bounds
        blur.frame = sheet.bounds
        sheetHost.layer.shadowPath = UIBezierPath(roundedRect: sheetHost.bounds,
                                                  byRoundingCorners: [.topLeft, .topRight],
                                                  cornerRadii: CGSize(width: 30, height: 30)).cgPath
        // 手加进 layer 的渐变色不享受 UIView 的隐式动画关闭，改 frame 会自己淡
        // 0.25 秒 —— 那一下在打开面板时看得出来。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.frame = CGRect(x: 0, y: 0, width: sheet.bounds.width, height: 150)
        CATransaction.commit()

        grabber.frame = CGRect(x: (sheet.bounds.width - 36) / 2, y: 8, width: 36, height: 5)
        titleLabel.frame = CGRect(x: sideInset, y: 20, width: 200, height: 26)
        detailLabel.frame = CGRect(x: sideInset, y: 46, width: sheet.bounds.width - 120, height: 16)
        closeButton.frame = CGRect(x: sheet.bounds.width - 16 - 32, y: 22, width: 32, height: 32)

        let searchWidth = sheet.bounds.width - sideInset * 2
        searchPlate.frame = CGRect(x: sideInset, y: 70, width: searchWidth, height: searchHeight)
        searchField.frame = CGRect(x: sideInset + 6, y: 70,
                                   width: searchWidth - 12, height: searchHeight)

        let bottom = Swift.max(safeAreaInsets.bottom, 20)
        scroll.frame = CGRect(x: 0, y: titleAreaHeight,
                              width: sheet.bounds.width,
                              height: Swift.max(0, sheet.bounds.height - titleAreaHeight - bottom * 0.4))
        scroll.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 16 + bottom * 0.6, right: 0)

        let indexTop = titleAreaHeight + 6
        indexBar.frame = CGRect(x: sheet.bounds.width - 18, y: indexTop,
                                width: 16,
                                height: Swift.max(0, scroll.bounds.height - 12))
        layoutIndex()

        if abs(scroll.bounds.width - lastWidth) > 0.5 {
            lastWidth = scroll.bounds.width
            relayoutRows()
        }
    }

    private func layoutIndex() {
        let buttons = indexBar.subviews
        guard !buttons.isEmpty else { return }
        let step = Swift.min(16, indexBar.bounds.height / CGFloat(buttons.count))
        let total = step * CGFloat(buttons.count)
        let top = (indexBar.bounds.height - total) / 2
        for (i, view) in buttons.enumerated() {
            view.frame = CGRect(x: 0, y: top + CGFloat(i) * step, width: indexBar.bounds.width, height: step)
        }
    }

    private func relayoutRows() {
        let width = Swift.max(0, scroll.bounds.width - sideInset * 2 - indexLane)
        var y: CGFloat = 0
        for i in rows.indices {
            rows[i].y = y
            rows[i].height = rows[i].isHeader ? headerHeight : rowHeight
            y += rows[i].height
        }
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: y + 8)

        for (_, view) in live { view.removeFromSuperview() }
        live.removeAll()
        pool.removeAll()
        updateVisibleRows()
    }

    // MARK: - Row recycling

    private func updateVisibleRows() {
        let top = scroll.contentOffset.y
        let bottom = top + scroll.bounds.height

        var needed = Set<Int>()
        for (i, row) in rows.enumerated() where row.y < bottom && row.y + row.height > top {
            needed.insert(i)
        }

        for key in Array(live.keys) where !needed.contains(key) {
            guard let view = live.removeValue(forKey: key) else { continue }
            view.removeFromSuperview()
            // 池子有上限：行高固定，屏幕上最多同时存在七八行，留着更多只是内存。
            if pool.count < 8 { pool.append(view) }
        }

        let width = Swift.max(0, scroll.bounds.width - sideInset * 2 - indexLane)
        for i in needed {
            guard let existing = live[i] else {
                let view = pool.popLast() ?? PanelRowView(frame: .zero)
                configure(view, row: rows[i], width: width)
                live[i] = view
                continue
            }
            existing.frame = CGRect(x: sideInset, y: rows[i].y, width: width, height: rows[i].height)
        }
    }

    private func configure(_ view: PanelRowView, row: Row, width: CGFloat) {
        view.frame = CGRect(x: sideInset, y: row.y, width: width, height: row.height)
        // 先入树再配置：header 分支提前返回，落到后面那句 addSubview 就永远加不上。
        if view.superview !== scroll { scroll.addSubview(view) }
        view.setHeader(row.title, visible: row.isHeader)
        if row.isHeader { return }
        view.setApps(row.apps, target: self, action: #selector(appTapped(_:)))
    }

    // MARK: - Actions

    @objc private func appTapped(_ sender: UIControl) {
        guard let cell = sender as? PanelAppCell else { return }
        openApp(cell.bundleID)
    }

    /// 点格子与回车共用这一条出口：两条路各写一遍，「先取回调再 dismiss」
    /// 这种顺序就会在一条路上对、另一条路上错。
    private func openApp(_ bundleID: String) {
        guard !dismissing, !bundleID.isEmpty else { return }
        AevonFloatMotion.haptic(.light)
        Log.write("panel: picked app " + bundleID)
        // 先取回调再 dismiss —— dismiss 会把 onPick 置 nil，写在后面就永远拿到 nil。
        let pick = onPick
        dismiss(reason: "picked")
        // 0.0.58 — 0.16 s 的等待去掉，改成下一拍。
        //
        // 那 160 ms 是 0.0.56 为「面板收起动画与浮窗第一帧叠在一起」加的。现在
        // 浮窗在冷启动时是 alpha 0 等第一帧的（见 FloatHost），面板收起时它根本
        // 还没显示 —— 叠加不存在了，而 160 ms 是整条链上最便宜就能省掉的一段：
        // 应用启动是串行的，早 160 ms 发出去，第一帧就早 160 ms。
        DispatchQueue.main.async { pick?(bundleID) }
    }

    @objc private func indexTapped(_ sender: UIButton) {
        var seen = -1
        for (i, row) in rows.enumerated() where row.isHeader {
            seen += 1
            guard seen == sender.tag else { continue }
            let y = Swift.max(0, row.y - 4)
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: true)
            AevonFloatMotion.haptic(.light)
            return
        }
    }

    @objc private func closeTapped() {
        dismiss(reason: "close button")
    }

    // MARK: - 搜索（0.0.57）

    @objc private func searchChanged() {
        let text = searchField.text ?? ""
        filterText = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rebuildGrouped()
            scroll.setContentOffset(.zero, animated: false)
        } else {
            rebuildResults(text)
        }
    }

    /// 键盘让开的量。抽屉跟着长高（见 `layoutSubviews`），所以这里只要把数字
    /// 记下来再重排一次。
    @objc private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let inSelf = convert(frame, from: nil)
        let overlap = Swift.max(0, bounds.height - inSelf.minY)
        guard abs(overlap - keyboardHeight) > 1 else { return }
        keyboardHeight = overlap
        Log.write(String(format: "panel: keyboard overlap=%.0f", overlap))
        UIView.animate(withDuration: 0.2) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// 回车 = 打开第一个结果。搜索的全部意义是少点一次，那就不该再要求用户
    /// 从结果里把手指抬起来点一下。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let first = rows.first { !$0.isHeader }?.apps.first
        textField.resignFirstResponder()
        if let app = first { openApp(app.bundleID) }
        return true
    }

    /// 0.0.57 — 这块面板住在 SpringBoard 的窗口里，不是某个 App 的窗口。
    /// 键盘服务认「first responder + key window」两件事，而桌面上这一扇窗未必
    /// 是 key。先让它自己试一次，0.35 秒还没见到键盘再抢 key 重聚焦。
    ///
    /// 不无条件抢：抢 key 的代价是前台 App 会收到 resignActive。为一个可能是
    /// 多虑的问题先付这笔钱，是 0.0.40 那种「防护比故障更坏」的老毛病。
    func textFieldDidBeginEditing(_ textField: UITextField) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.searchField.isFirstResponder,
                  self.keyboardHeight == 0, let window = self.window else { return }
            self.priorKey = window.windowScene?.windows.first { $0.isKeyWindow }
            window.makeKey()
            self.searchField.resignFirstResponder()
            self.searchField.becomeFirstResponder()
            Log.write(String(format: "panel: keyboard retry key=%d",
                             window.isKeyWindow ? 1 : 0))
        }
    }

    @objc private func dimTapped() {
        dismiss(reason: "outside")
    }

    @objc private func sheetPanned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let dy = Swift.max(0, gesture.translation(in: self).y)
            sheetHost.transform = CGAffineTransform(translationX: 0, y: dy)
            dim.alpha = 0.38 * Swift.max(0, 1 - dy / 240)
        case .ended, .cancelled, .failed:
            let dy = Swift.max(0, gesture.translation(in: self).y)
            let fast = gesture.velocity(in: self).y > 600
            if dy > 90 || fast {
                dismiss(reason: "swipe down")
            } else {
                UIView.animate(withDuration: 0.26, delay: 0,
                               usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) {
                    self.sheetHost.transform = .identity
                    self.dim.alpha = 0.38
                }
            }
        default:
            break
        }
    }

    /// 只有从标题区起手的下滑才是「收起」。从列表里起手是滚动 ——
    /// 两者抢同一根手指时，位置比速度更能说明意图。
    ///
    /// `override` 不是抄漏：UIView 自己就实现了这个委托方法，子类再写一遍
    /// 必须显式覆盖 —— 0.0.56 第一次构建就是在这里停下的。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: sheet)
        guard velocity.y > abs(velocity.x) else { return false }
        let point = pan.location(in: sheet)
        // 0.0.57 — 搜索框也在标题区里，但在它上面起手是「选词 / 挪光标」。
        // 这里让它过去，否则想拖一下光标就会把整个面板收起来。
        if searchField.frame.insetBy(dx: -6, dy: -8).contains(point) { return false }
        return point.y < titleAreaHeight + 20
    }

    // MARK: - Show / hide

    private func animateIn() {
        layoutIfNeeded()
        sheetHost.transform = CGAffineTransform(translationX: 0, y: sheetHost.bounds.height)
        UIView.animate(withDuration: 0.42, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction]) {
            self.dim.alpha = 0.38
            self.sheetHost.transform = .identity
        }
    }

    func dismiss(reason: String = "dismiss") {
        guard !dismissing else { return }
        dismissing = true
        if AevonAppPanel.current === self { AevonAppPanel.current = nil }
        let close = onClose
        onClose = nil
        onPick = nil
        // 键盘先收：面板带着 first responder 一起从树上摘掉，键盘会留在原地
        // 一秒钟才自己降下去，看起来像「关不掉」。
        searchField.resignFirstResponder()
        // 抢过的 key 还回去。还的顺序在收键盘之后：反过来的话，键盘会跟着
        // 旧 key 窗口的层级重排一次，看起来是抽了一下。
        if let prior = priorKey, let mine = window, prior !== mine {
            prior.makeKey()
        }
        priorKey = nil
        NotificationCenter.default.removeObserver(
            self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        Log.write("panel: panel closed (" + reason + ")")
        UIView.animate(withDuration: 0.24, delay: 0,
                       options: [.curveEaseIn, .beginFromCurrentState]) {
            self.dim.alpha = 0
            self.sheetHost.transform = CGAffineTransform(translationX: 0,
                                                         y: self.sheetHost.bounds.height)
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            close?(reason)
        }
    }

    // MARK: - Scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleRows()
    }
}

// MARK: - One row of the grid

private final class PanelRowView: UIView {

    /// 一行的格子数。`AevonAppPanel.columnCount` 读的就是这里 —— 布局只认
    /// 一个来源，两处各写一个 5 早晚会变成 5 和 4。
    static let columns = 5

    private let titleLabel = UILabel()
    private var cells: [PanelAppCell] = []
    private var headerMode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        addSubview(titleLabel)
        titleLabel.isHidden = true

        for _ in 0..<PanelRowView.columns {
            let cell = PanelAppCell(frame: .zero)
            cell.isHidden = true
            addSubview(cell)
            cells.append(cell)
        }
    }

    /// 0.1.38 — 同上：反序列化路径上宁可返回 nil，也不要终止进程。
    required init?(coder: NSCoder) { return nil }

    func setHeader(_ title: String, visible: Bool) {
        headerMode = visible
        titleLabel.isHidden = !visible
        titleLabel.text = title
        for cell in cells { cell.isHidden = true }
        setNeedsLayout()
    }

    func setApps(_ apps: [InstalledApp], target: Any?, action: Selector) {
        headerMode = false
        titleLabel.isHidden = true
        for (i, cell) in cells.enumerated() {
            guard i < apps.count else {
                cell.isHidden = true
                cell.bundleID = ""
                continue
            }
            let app = apps[i]
            cell.isHidden = false
            cell.bundleID = app.bundleID
            cell.iconView.image = RingIcons.image(for: app)
            cell.label.text = app.name
            cell.removeTarget(nil, action: nil, for: .touchUpInside)
            cell.addTarget(target, action: action, for: .touchUpInside)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if headerMode {
            titleLabel.frame = CGRect(x: 2, y: bounds.height - 20, width: bounds.width, height: 16)
            return
        }
        let count = CGFloat(cells.count)
        let gap: CGFloat = 8
        let width = (bounds.width - gap * (count - 1)) / count
        for (i, cell) in cells.enumerated() {
            cell.frame = CGRect(x: CGFloat(i) * (width + gap), y: 0,
                                width: width, height: bounds.height)
        }
    }
}

// MARK: - One app tile

private final class PanelAppCell: UIControl {

    let iconView = UIImageView()
    let label = UILabel()
    var bundleID = ""

    /// 0.0.58 — 54 → 44。5 列的格宽是 (335 − 32) / 5 ≈ 60，图标 54 在 60 的
    /// 格子里只留 3 pt 边，横向挤成一条。44 让每格两侧各留 8，视觉上才是
    /// 一排并列的图标，而不是一条被切开的色带。
    private static let side: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        label.font = .systemFont(ofSize: 9.5, weight: .regular)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.82
        label.isUserInteractionEnabled = false
        addSubview(label)
    }

    /// 0.1.38 — 同上：反序列化路径上宁可返回 nil，也不要终止进程。
    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.iconView.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.90, y: 0.90)
                    : .identity
                self.alpha = self.isHighlighted ? 0.75 : 1
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = PanelAppCell.side
        iconView.frame = CGRect(x: (bounds.width - side) / 2, y: 6, width: side, height: side)
        label.frame = CGRect(x: 0, y: side + 9, width: bounds.width, height: 13)
    }
}
