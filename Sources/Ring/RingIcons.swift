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

    /// - Parameter limit: hard cap, so a phone with 300 apps cannot make the
    ///   preview feel hung. The ring never shows more than 12 anyway.
    static func load(limit: Int = 12) -> (apps: [RingApp], source: IconSource) {
        let fromLS = launchServicesApps()
        if !fromLS.isEmpty {
            var apps: [RingApp] = []
            var real = 0
            for item in fromLS.prefix(limit) {
                if let icon = icon(for: item.bundleID, bundlePath: item.path) {
                    real += 1
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
            items.append(LSItem(bundleID: rawID, name: name, path: path))
        }

        // Stable order: LaunchServices returns installation order, which
        // changes after every update and makes screenshots incomparable.
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Filesystem

    private static func filesystemApps(limit: Int) -> [RingApp] {
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

        var apps: [RingApp] = []
        for path in bundles {
            guard apps.count < limit else { break }
            guard let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any],
                  let bundleID = info["CFBundleIdentifier"] as? String else { continue }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? bundleID
            apps.append(RingApp(bundleID: bundleID,
                                name: name,
                                icon: icon(for: bundleID, bundlePath: path) ?? placeholderIcon(name)))
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
