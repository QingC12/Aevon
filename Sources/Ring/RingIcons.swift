//
//  RingIcons.swift — Aevon, what the carrier shape carries.
//
//  Three sources, tried in order, and the one that wins is reported to the
//  operator instead of being silently swallowed:
//
//    1. LaunchServices   real icons, real order  (private API, but this is a
//                        jailbreak tweak: it is the same service SpringBoard
//                        itself uses)
//    2. filesystem scan  real names, real icons from each .app bundle
//    3. placeholder      nothing readable -> drawn tiles, so the shape can
//                        still be judged instead of showing an empty ring
//
//  Why not just ship the icons: the package would grow by megabytes and go
//  stale. Why not silently fall back: an empty or fake ring looks like a bug
//  in the geometry, and the geometry is exactly what is being reviewed.
//

import UIKit

struct RingApp {
    let bundleID: String
    let name: String
    let icon: UIImage?
}

/// One installed application, before an icon has been drawn for it. Kept
/// separate from RingApp on purpose: the app picker lists hundreds of rows and
/// rendering a 120 pt tile for every one of them would make the panel scroll at
/// 12 fps. The icon is produced only for rows that are actually on screen.
struct InstalledApp {
    let bundleID: String
    let name: String
    let path: String?
}

enum IconSource: String {
    case launchServices = "LaunchServices"
    case filesystem = "文件扫描"
    case placeholder = "占位图标"

    var note: String {
        switch self {
        case .launchServices: return "真实图标，来自 LaunchServices"
        case .filesystem:     return "真实图标，来自 App 包内文件"
        case .placeholder:    return "读不到图标，使用占位色块（形状仍然准确）"
        }
    }
}

enum RingIcons {

    // MARK: Catalogue (every installed app, no icons drawn)

    private static var catalogueCache: [InstalledApp]?
    private static var imageCache: [String: UIImage] = [:]

    /// Every installed app the system will actually launch, sorted by name.
    /// Cached for the life of the process: enumerating LaunchServices takes
    /// ~70 ms and the picker asks for this on every keystroke while searching.
    ///
    /// 0.0.56 — 这张表不再等于「装在这台机器上的全部 App」。操作者的话是
    /// 「移除列表里所有白图标应用，因为它们无法打开」，而白图标正是**打不开**
    /// 这件事在屏幕上的样子：`_applicationIconImageForBundleIdentifier:` 对没有
    /// 图标资源的系统 App 返回一张纯白方块，点它什么也不会发生。判据有两条，
    /// 一条问系统、一条看图：
    ///
    ///   · LaunchServices 自己说不能启动 / 是隐藏项 / 只是占位安装；
    ///   · 图标是一张**几乎全白**的图。
    ///
    /// 两条都不命中就保留 —— 包括取不到图标的那种（那是彩色字母块，不是白图标，
    /// 系统偶尔会在 LS 缓存未建立时这样，删掉它等于删掉一个正常 App）。
    static func catalogue() -> [InstalledApp] {
        if let cached = catalogueCache { return cached }

        let started = Date()
        var items: [InstalledApp] = []
        var prohibit = 0, hidden = 0, placeholder = 0, blank = 0

        for entry in launchServicesApps() {
            if let rejection = entry.rejection {
                switch rejection {
                case "prohibit":    prohibit += 1
                case "hidden":      hidden += 1
                default:            placeholder += 1
                }
                continue
            }
            // 取图标这件事本来要在列表滚动时才做；这里先做一次，因为「白不白」
            // 是筛选项本身。命中的图直接进 `imageCache`，面板和列表后面显示
            // 时不用再取第二遍 —— 总成本没有增加，只是提前付。
            guard let icon = self.icon(for: entry.bundleID, bundlePath: entry.path) else {
                items.append(InstalledApp(bundleID: entry.bundleID,
                                          name: entry.name, path: entry.path))
                continue
            }
            if isBlank(icon) {
                blank += 1
                if blank <= 20 { Log.write("icons: drop blank " + entry.bundleID) }
                continue
            }
            imageCache[entry.bundleID] = icon
            items.append(InstalledApp(bundleID: entry.bundleID,
                                      name: entry.name, path: entry.path))
        }

        if items.isEmpty {
            items = filesystemCatalogue()
        }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        catalogueCache = items

        let dropped = prohibit + hidden + placeholder + blank
        // 每次进程只打一行，而且**无论有没有丢掉东西都打**：这一行是「过滤到底
        // 跑没跑、跑了多久」的唯一证据。只在有丢弃时打，就会在「一个都没删掉」
        // 的那台机器上消失，看起来像功能没生效。
        Log.write(String(format:
            "icons: catalogue kept=%d dropped=%d prohibit=%d hidden=%d placeholder=%d blank=%d in %dms",
            items.count, dropped, prohibit, hidden, placeholder, blank,
            Int(Date().timeIntervalSince(started) * 1000)))
        return items
    }

    /// 一张**几乎全白**的图标。0.0.56 的新判据，就是操作者说的「白图标」。
    ///
    /// 做法是把它画进 12×12 的位图再数像素：几百个 App 全量做一遍也只是一次
    /// 缩略重绘（不是解码原图），而「白」这个判断不需要更多精度。
    ///
    /// 阈值取 97 % 而不是 100 %：真正的白方块是纯 #FFFFFF，允许一点点边缘噪点；
    /// 而任何有图案的图标 —— 哪怕白底 —— 图案都会占到 3 % 以上。取不到 CGImage
    /// 时返回 false（判不了就当它不是白图，不能凭猜测删 App）。
    private static func isBlank(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }

        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: side, height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }

        var opaque = 0
        var white = 0
        var index = 0
        while index < pixels.count {
            // 圆角图标四角是透明的；透明像素不参与「白不白」的统计。
            if pixels[index + 3] >= 128 {
                opaque += 1
                if pixels[index] >= 236, pixels[index + 1] >= 236, pixels[index + 2] >= 236 {
                    white += 1
                }
            }
            index += 4
        }
        guard opaque > 0 else { return true }
        return white * 100 >= opaque * 97
    }

    /// Called after the operator adds or removes an app in the picker, so the
    /// next panel is not built from a stale list.
    static func invalidateCatalogue() {
        catalogueCache = nil
    }

    static func item(for bundleID: String) -> InstalledApp? {
        return catalogue().first { $0.bundleID == bundleID }
    }

    /// The real icon when the system will give us one, a stable tile otherwise.
    /// Never nil: a missing icon must not be able to produce a blank slot.
    static func image(for item: InstalledApp) -> UIImage {
        if let cached = imageCache[item.bundleID] { return cached }
        let image = icon(for: item.bundleID, bundlePath: item.path)
            ?? placeholderIcon(item.name)
        imageCache[item.bundleID] = image
        return image
    }

    static func placeholder(named name: String) -> UIImage {
        return placeholderIcon(name)
    }

    /// The real icon or nil — the seam `AevonAppIcon` (the old plugin's icon
    /// adapter) needs: the ring menu's letter-tile fallback only fires when
    /// this returns nil, while `image(for:)` never does. The raw query, not
    /// the cache: a cached tile may be the placeholder, and the placeholder
    /// must read as "no real icon" here.
    static func realIcon(for item: InstalledApp) -> UIImage? {
        return icon(for: item.bundleID, bundlePath: item.path)
    }

    /// A ring-ready app from a bare bundle identifier.
    static func ringApp(for bundleID: String) -> RingApp {
        if let item = item(for: bundleID) {
            return RingApp(bundleID: item.bundleID, name: item.name, icon: image(for: item))
        }
        // Still installed as far as the operator is concerned, just not in the
        // catalogue any more (deleted, or LaunchServices hid it). Keep the id
        // so the row can be identified and removed instead of silently
        // becoming a different app.
        return RingApp(bundleID: bundleID,
                       name: bundleID,
                       icon: placeholderIcon(bundleID))
    }

    /// - Parameter limit: hard cap, so a phone with 300 apps cannot make the
    ///   preview feel hung. The ring never shows more than 12 anyway.
    ///
    /// 0.0.56 — 走 `catalogue()`，不再自己读一遍 LaunchServices：同一个东西
    /// 有两个来源，就一定会有一天两边不一样（预览里有、列表里没有）。
    static func load(limit: Int = 12) -> (apps: [RingApp], source: IconSource) {
        let filtered = catalogue()
        if !filtered.isEmpty {
            var apps: [RingApp] = []
            var real = 0
            for item in filtered.prefix(limit) {
                if let icon = self.icon(for: item.bundleID, bundlePath: item.path) {
                    real += 1
                    imageCache[item.bundleID] = icon
                    apps.append(RingApp(bundleID: item.bundleID, name: item.name, icon: icon))
                } else {
                    apps.append(RingApp(bundleID: item.bundleID,
                                        name: item.name,
                                        icon: placeholderIcon(item.name)))
                }
            }
            return (apps, real > 0 ? .launchServices : .placeholder)
        }

        let fromDisk = filesystemApps(limit: limit)
        if !fromDisk.isEmpty {
            return (fromDisk, .filesystem)
        }

        // Last resort: a ring of tiles. Deterministic names, so the shape and
        // the animation can still be reviewed frame by frame.
        let names = ["Safari", "微信", "相册", "设置", "音乐", "地图", "邮件", "相机"]
        let apps = names.prefix(limit).map { name -> RingApp in
            RingApp(bundleID: "placeholder." + name, name: name, icon: placeholderIcon(name))
        }
        return (Array(apps), .placeholder)
    }

    // MARK: LaunchServices

    private struct LSItem {
        let bundleID: String
        let name: String
        let path: String?
        /// LaunchServices 自己的判决（0.0.56）。nil = 没意见，这一项留在列表里。
        /// 三个值分别是「禁止启动 / 隐藏项 / 只是占位安装」。
        let rejection: String?
    }

    private static func launchServicesApps() -> [LSItem] {
        guard let meta = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return []
        }
        let workspaceSelector = NSSelectorFromString("defaultWorkspace")
        guard meta.responds(to: workspaceSelector),
              let unmanagedWorkspace = meta.perform(workspaceSelector),
              let workspace = unmanagedWorkspace.takeUnretainedValue() as? NSObject else {
            return []
        }

        let listSelector = NSSelectorFromString("allInstalledApplications")
        guard let unmanagedList = workspace.perform(listSelector),
              let proxies = unmanagedList.takeUnretainedValue() as? [AnyObject] else {
            return []
        }

        var items: [LSItem] = []
        items.reserveCapacity(proxies.count)

        for proxy in proxies {
            guard let object = proxy as? NSObject,
                  object.responds(to: NSSelectorFromString("bundleIdentifier")),
                  let rawID = object.perform(NSSelectorFromString("bundleIdentifier"))?
                      .takeUnretainedValue() as? String,
                  !rawID.isEmpty else { continue }

            var name = rawID
            for key in ["localizedName", "itemName"] {
                if let value = object.perform(NSSelectorFromString(key))?
                    .takeUnretainedValue() as? String, !value.isEmpty {
                    name = value
                    break
                }
            }

            var path: String?
            if let url = object.perform(NSSelectorFromString("bundleURL"))?
                .takeUnretainedValue() as? URL {
                path = url.path
            }
            items.append(LSItem(bundleID: rawID, name: name, path: path,
                                rejection: rejectionReason(of: object)))
        }

        // Stable order: LaunchServices returns installation order, which
        // changes after every update and makes screenshots incomparable.
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 三条 LaunchServices 判据，回答「这个 App 点了会不会有反应」。
    ///
    /// 都是 `LSApplicationProxy` 上的私有属性，任何一个取不到就当没有意见 ——
    /// 系统的私有 API 改一次名字不该让整张列表变空。
    private static func rejectionReason(of proxy: NSObject) -> String? {
        if boolean(proxy, "isLaunchProhibited") == true { return "prohibit" }
        if boolean(proxy, "isPlaceholder") == true { return "placeholder" }
        if let tags = proxy.perform(NSSelectorFromString("appTags"))?
            .takeUnretainedValue() as? [String], tags.contains("hidden") {
            return "hidden"
        }
        return nil
    }

    /// `perform` 的返回值永远是对象：BOOL 会被装箱成 NSNumber，所以先按
    /// NSNumber 读，再退到 Bridged Bool。
    private static func boolean(_ object: NSObject, _ selectorName: String) -> Bool? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let value = object.perform(selector)?.takeUnretainedValue() else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return nil
    }

    // MARK: Filesystem

    /// Bundle paths reachable without LaunchServices. Used both as a fallback
    /// for the ring and as the picker's catalogue when the private API is not
    /// there, so the two can never offer different sets of apps.
    private static func bundlePaths() -> [String] {
        var bundles: [String] = []

        for root in ["/Applications", "/var/containers/Bundle/Application"] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                continue
            }
            for entry in entries.prefix(400) {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    bundles.append(path)
                    continue
                }
                // <UUID>/<Name>.app — one more level on iOS 8 and later
                guard let inner = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                    continue
                }
                for child in inner where child.hasSuffix(".app") {
                    bundles.append(path + "/" + child)
                }
            }
        }
        return bundles
    }

    private static func filesystemCatalogue() -> [InstalledApp] {
        var items: [InstalledApp] = []
        for path in bundlePaths() {
            guard let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any],
                  let bundleID = info["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else { continue }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? bundleID
            items.append(InstalledApp(bundleID: bundleID, name: name, path: path))
        }
        return items
    }

    private static func filesystemApps(limit: Int) -> [RingApp] {
        var apps: [RingApp] = []
        for item in filesystemCatalogue() {
            guard apps.count < limit else { break }
            apps.append(RingApp(bundleID: item.bundleID,
                                name: item.name,
                                icon: image(for: item)))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Icons

    /// Written once, read by the settings row, so a failed icon lookup is a
    /// number the operator can quote instead of a mystery.
    private static var placeholderCache: [String: UIImage] = [:]

    private static func icon(for bundleID: String, bundlePath: String?) -> UIImage? {
        if let image = springBoardIcon(bundleID) { return image }
        if let path = bundlePath, let image = bundledIcon(path) { return image }
        return nil
    }

    /// `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`
    /// lives in UIKit and is what SpringBoard itself renders icons with.
    /// Guarded: on a build without it the selector simply is not called.
    private static func springBoardIcon(_ bundleID: String) -> UIImage? {
        let selector = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        guard UIImage.responds(to: selector) else { return nil }
        return UIImage.aevonAppIcon(bundleID: bundleID,
                                    format: 0,
                                    scale: UIScreen.main.scale)
    }

    /// Fallback for apps that still ship a flat PNG next to their binary.
    /// Assets.car-only apps return nil here and land on the placeholder.
    private static func bundledIcon(_ bundlePath: String) -> UIImage? {
        let candidates = [
            "AppIcon60x60@3x.png", "AppIcon60x60@2x.png",
            "Icon-60@3x.png", "Icon-60@2x.png",
            "AppIcon76x76@2x~ipad.png", "Icon-72@2x.png",
        ]
        for name in candidates {
            let path = bundlePath + "/" + name
            if let image = UIImage(contentsOfFile: path) { return image }
        }
        return nil
    }

    private static func placeholderIcon(_ name: String) -> UIImage {
        if let cached = placeholderCache[name] { return cached }

        let side: CGFloat = 120
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        // Stable hash: String.hashValue is seeded per process, so the same app
        // would get a different colour after every respring.
        let seed = name.unicodeScalars.reduce(0) { ($0 + Int($1.value) * 7) % 360 }
        let hue = CGFloat(seed) / 360

        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.2237)
            UIColor(hue: hue, saturation: 0.42, brightness: 0.72, alpha: 1).setFill()
            path.fill()

            let letter = name.first.map(String.init) ?? "?"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.46, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = letter as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (side - textSize.width) / 2,
                                  y: (side - textSize.height) / 2),
                      withAttributes: attributes)
        }
        placeholderCache[name] = image
        return image
    }
}
