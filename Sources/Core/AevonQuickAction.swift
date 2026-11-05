//
//  AevonQuickAction.swift
//  Aevon
//
//  V0.2.62（AevonQuickActionV262，用户 Aevon(36) #2）：
//  「添加系统的截图和录屏功能到圆盘的应用选择中」。
//
//  做法：在圆盘里插入两个「动作」槽 —— 它们不是 App，bundleID 用
//  `aevon.action.screenshot` / `aevon.action.recording` 这两个伪标识；
//  圆盘把它们当成普通图标布局（图标用 SF Symbol 画），选中时不分派给
//  `launchAndOpen`，而是走本文件的 `perform(bundleID:)`。
//
//  截图：优先 `UICreateScreenImage()`（UIKit 私有 C 函数，SpringBoard 里能
//        截到**合成后的整屏**，含所有窗口与会话内容）；取不到再退回私有类
//        `SBScreenShotter`。拿到图后写相册。
//  录屏：ReplayKit 的 `RPScreenRecorder`（SpringBoard 是系统 App，具备录制
//        权限）。开始 / 再点一次停止；停止时把录制结果写相册，失败则记日志。
//
//  纪律：任何一步失败都只记日志、绝不抛异常（圆盘是用户天天点的入口）；
//        不在主线程做重活（截图放到后台队列）。
//

import UIKit
import ReplayKit
import Photos
import AudioToolbox
import AVFoundation

/// 截图保存完成的回调目标（`UIImageWriteToSavedPhotosAlbum` 需要一个 selector）
final class AevonQuickActionSaver: NSObject {
    static let shared = AevonQuickActionSaver()

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            AevonLog.warn("[快捷] 截图保存相册失败：\(error.localizedDescription)（AevonQuickActionV262）")
        } else {
            AevonLog.info("[快捷] 截图已保存到相册（AevonQuickActionV262）")
        }
    }
}

enum AevonQuickAction {
    /// 标记（CI 用：必须落在编译产物里）
    static let markerScreenshot = "AevonQuickScreenshotV262"
    static let markerRecording = "AevonQuickRecordingV262"

    static let screenshotID = "aevon.action.screenshot"
    static let recordingID = "aevon.action.recording"

    static var allIDs: [String] { [screenshotID, recordingID] }

    static func isAction(_ bundleID: String) -> Bool {
        return bundleID == screenshotID || bundleID == recordingID
    }

    static func title(for bundleID: String) -> String? {
        switch bundleID {
        case screenshotID: return "截图"
        case recordingID: return "录屏"
        default: return nil
        }
    }

    static func symbolName(for bundleID: String) -> String? {
        switch bundleID {
        case screenshotID: return "camera.viewfinder"
        case recordingID: return "record.circle"
        default: return nil
        }
    }

    /// 圆盘图标：V0.2.64（AevonActionIconV264）改成**画成一张完整的图标**
    /// （彩色圆角底 + 白色 SF Symbol）。用户 Aevon(38) #5.4「圆盘中的截图和录屏没有图标」——
    /// 上一版只把 SF Symbol 当图片塞进去，底色是透明的，在白/浅色圆盘底上等于看不见。
    /// 现在自己渲染：底色按动作区分（截图=蓝、录屏=红），符号居中，圆角率与 App 图标一致。
    static func symbolImage(bundleID: String, size: CGFloat) -> UIImage? {
        guard let name = symbolName(for: bundleID), size > 8 else { return nil }
        let side = max(size, 12)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.2237)
            path.addClip()
            let colors: [UIColor]
            switch bundleID {
            case screenshotID:
                colors = [UIColor(red: 0.29, green: 0.52, blue: 1.00, alpha: 1),
                          UIColor(red: 0.13, green: 0.31, blue: 0.86, alpha: 1)]
            case recordingID:
                colors = [UIColor(red: 1.00, green: 0.35, blue: 0.31, alpha: 1),
                          UIColor(red: 0.78, green: 0.12, blue: 0.14, alpha: 1)]
            default:
                colors = [UIColor(white: 0.35, alpha: 1), UIColor(white: 0.18, alpha: 1)]
            }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors.map { $0.cgColor } as CFArray,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient,
                                                     start: CGPoint(x: 0, y: 0),
                                                     end: CGPoint(x: 0, y: side),
                                                     options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
            guard let glyph = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            let glyphSize = glyph.size
            glyph.draw(at: CGPoint(x: (side - glyphSize.width) / 2,
                                   y: (side - glyphSize.height) / 2))
        }
        return image
    }

    // MARK: - 分发

    static func perform(bundleID: String) {
        switch bundleID {
        case screenshotID:
            AevonLog.info("[快捷] 圆盘选择「截图」（AevonQuickScreenshotV262）")
            takeScreenshot()
        case recordingID:
            AevonLog.info("[快捷] 圆盘选择「录屏」（AevonQuickRecordingV262）")
            toggleRecording()
        default:
            break
        }
    }

    // MARK: - 截图

    private typealias CreateScreenImageFunc = @convention(c) () -> Unmanaged<CGImage>?
    private typealias ScreenUIImageFn = @convention(c) (CGFloat) -> Unmanaged<AnyObject>?
    private typealias BoolArgVoidFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void

    /* V0.2.64（AevonQuickShotV264，用户 Aevon(38) #5.4「截图成功但没有提示、
     * 也无法和 Snapper 等工具接力」）：
     *
     * 上一版先试 `SBUIController -_takeScreenshotAndEdit:`，Aevon(38) 日志证明它在
     * 本机**根本不存在**（「本系统既没有 SBUIController 截图方法」），最后落到
     * `UICreateScreenImage` —— 那条在 SpringBoard 里是空壳（能拿到图但抓的是空白）。
     *
     * 改回逆向档案里 ScreenCore 的做法：`_UICreateScreenUIImageWithRotation(0)`，
     * 这是 UIKit 的私有截图函数，返回 UIImage（不经过 CGImage 转换），在 SpringBoard
     * 里能拿到**合成后的整屏**。拿到图之后：
     *   ① 写相册（PHPhotoLibrary，有成功回调，不会「假成功」）；
     *   ② 同时复制到剪贴板 —— Snapper / 长截图这类工具都从剪贴板接图；
     *   ③ 弹一个自己的提示条（SB 里没有系统截图缩略图，只能自己给反馈）。
     */
    /* V0.2.66（AevonSysShotV266，用户 Aevon(39) #9「截图依旧不会联动其他插件」）：
     * 主路改走**系统截图管线** `SBScreenShotter -saveScreenshot:` —— 快门音、缩放
     * 动画、相册落库全部由系统完成，hook 了截图完成事件的插件（Snapper 等）随之联动；
     * 这是 home+电源键那一条真管线（cycript 实锤 `[[SBScreenShotter sharedInstance]
     * saveScreenshot:YES]` 就是系统截图）。装前用 method_getTypeEncoding 自检
     * （0.2.52 安全模式铁律），类或方法不存在、编码不符就回落自抓帧老路。 */
    private static func takeSystemScreenshot() -> Bool {
        /* V0.2.68（AevonShotMgrV268，用户 Aevon(40) #4「截屏依旧无法触发联动」）：
         * Aevon(40) 16:05:04 实锤：`objc_getClass("SBScreenShotter")` 在本机
         * iOS 17.3.1 **返回 nil**（0.2.67 的警告日志），系统截图类早已换代 ——
         * The Apple Wiki（Updating extensions for iOS 9.3.3）明确记载：
         *   "SBScreenShotter has been replaced with SBScreenshotManager.
         *    An instance is available through SpringBoard's screenshotManager
         *    property. Use saveScreenshotsWithCompletion:."
         * 即：单例走 `SpringBoard.screenshotManager` 属性，方法是
         * `-saveScreenshotsWithCompletion:`（侧键+音量上那条真管线，
         * 快门音/闪光/缩略图/相册/第三方插件联动全由系统完成）。
         * 探测链（每一级都打日志，真机一测就能锁定命中级）：
         *   ① SpringBoard.screenshotManager + saveScreenshotsWithCompletion:
         *   ② SBScreenShotter.sharedInstance + saveScreenshot:（0.2.67 老路保留）
         * 两级全空才回落自抓帧。completion 传真空 block 最稳。
         * 装前照旧 method_getTypeEncoding 自检（fail-closed 铁律）。 */
        // 0.0.42 移植适配：SpringBoard 里没有可靠的 UIApplication.shared ——
        // 走运行时取 sharedApplication（本仓库铁律，见 AevonCompat.firstWindowScene）。
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: NSSelectorFromString("sharedApplication")),
              let unmanaged = meta.perform(NSSelectorFromString("sharedApplication")),
              let sb = unmanaged.takeUnretainedValue() as? NSObject else {
            AevonLog.warn("[快捷] sharedApplication 不可达 → 走自抓帧（AevonShotMgrV268）")
            return false
        }
        // 0.1.38 — 不再裸走 KVC。`value(forKey:)` 碰到没声明的键会抛
        // `NSUndefinedKeyException`，而 Swift 接不住 ObjC 异常：这一句写在
        // SpringBoard 里，异常一穿就进安全模式。改读运行时方法表，见 AevonSafe。
        if let mgr = AevonSafe.object(sb, "screenshotManager") {
            let sel = NSSelectorFromString("saveScreenshotsWithCompletion:")
            if let m = class_getInstanceMethod(type(of: mgr), sel),
               let rawTypes = method_getTypeEncoding(m) {
                let types = String(cString: rawTypes)
                // v16@0:8@?16 = (void)(id self, SEL, block)
                if types.hasPrefix("v"), types.contains("@0:8@"), types.contains("@?") {
                    typealias ShotFn = @convention(c) (UnsafeRawPointer, Selector, AnyObject) -> Void
                    let fn = unsafeBitCast(msgSendRaw(), to: ShotFn.self)
                    let done: @convention(block) () -> Void = {}
                    fn(Unmanaged.passUnretained(mgr).toOpaque(), sel,
                       unsafeBitCast(done, to: AnyObject.self))
                    AevonLog.info("[快捷] 截图走系统管线 SBScreenshotManager"
                        + " -saveScreenshotsWithCompletion:（快门/闪光/相册/联动全由系统完成）"
                        + "（AevonShotMgrV268 AevonShotSysV267）")
                    return true
                }
                AevonLog.warn("[快捷] SBScreenshotManager.saveScreenshotsWithCompletion: "
                    + "编码不符（\(types)）→ 试老类（AevonShotMgrV268）")
            } else {
                AevonLog.warn("[快捷] SBScreenshotManager 在但无 saveScreenshotsWithCompletion:"
                    + " → 试老类（AevonShotMgrV268）")
            }
        } else {
            AevonLog.warn("[快捷] SpringBoard.screenshotManager 属性不可达 → 试老类"
                + "（AevonShotMgrV268）")
        }

        // 候选②：SBScreenShotter（0.2.67 原路；本机实测类不存在，保留防 iOS 回换）
        guard let cls = objc_getClass("SBScreenShotter") else {
            AevonLog.warn("[快捷] SBScreenShotter 类不存在 → 走自抓帧（AevonShotMgrV268）")
            return false
        }
        let sharedSel = sel_registerName("sharedInstance")
        typealias MsgSendId = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
            .map { unsafeBitCast($0, to: MsgSendId.self) }
        guard let send = msgSend, let sharedPtr = send(cls as AnyObject, sharedSel) else {
            AevonLog.warn("[快捷] SBScreenShotter sharedInstance 不可达 → 走自抓帧"
                + "（AevonShotMgrV268）")
            return false
        }
        let shared = Unmanaged<AnyObject>.fromOpaque(sharedPtr).takeUnretainedValue()
        let sel = NSSelectorFromString("saveScreenshot:")
        guard let m = class_getInstanceMethod(type(of: shared), sel),
              let rawTypes = method_getTypeEncoding(m) else {
            AevonLog.warn("[快捷] SBScreenShotter 无 saveScreenshot: → 走自抓帧"
                + "（AevonShotMgrV268）")
            return false
        }
        let types = String(cString: rawTypes)
        // v24@0:8@16B24 = (void)(id self, SEL, BOOL)
        guard types.hasPrefix("v"), types.contains("@0:8@"), types.contains("B") else {
            AevonLog.warn("[快捷] SBScreenShotter saveScreenshot: 编码不符（\(types)）→ 走自抓帧"
                + "（AevonShotMgrV268）")
            return false
        }
        typealias ShotFn = @convention(c) (UnsafeRawPointer, Selector, Bool) -> Void
        let fn = unsafeBitCast(msgSendRaw(), to: ShotFn.self)
        fn(sharedPtr, sel, true)
        AevonLog.info("[快捷] 截图走系统管线 SBScreenShotter -saveScreenshot:YES"
            + "（快门/闪光/相册/联动全由系统完成）（AevonShotMgrV268）")
        return true
    }

    private static func msgSendRaw() -> UnsafeMutableRawPointer {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")!
    }

    /* V0.2.71：截图日志限频 —— 自绘兜底录屏每帧都走 captureScreenImage，
     * 12fps 下一秒 12 条会把日志刷爆（Aevon(43) 18:26 段每 125ms 一条就是它在录屏）。 */
    private static var lastCaptureLogAt = CACurrentMediaTime()

    @discardableResult
    static func captureScreenImage() -> UIImage? {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_UICreateScreenUIImageWithRotation") {
            let fn = unsafeBitCast(symbol, to: ScreenUIImageFn.self)
            if let image = fn(0)?.takeUnretainedValue() as? UIImage, image.size.width > 10 {
                let now = CACurrentMediaTime()
                if now - lastCaptureLogAt > 2.0 {
                    lastCaptureLogAt = now
                    AevonLog.info("[快捷] 截图走 _UICreateScreenUIImageWithRotation：\(Int(image.size.width))x\(Int(image.size.height))（AevonQuickShotV264）")
                }
                return image
            }
        }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "UICreateScreenImage") {
            let fn = unsafeBitCast(symbol, to: CreateScreenImageFunc.self)
            if let cg = fn()?.takeUnretainedValue() {
                AevonLog.info("[快捷] 截图走 UICreateScreenImage 兜底（AevonQuickShotV264）")
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    private static func takeScreenshot() {
        // V0.2.66（AevonSysShotV266）：先试系统管线（联动达成）；失败回落自抓帧老路。
        if takeSystemScreenshot() { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = captureScreenImage() else {
                AevonLog.warn("[快捷] 截图失败：系统管线不可用且自抓帧拿不到画面（AevonSysShotV266）")
                DispatchQueue.main.async { AevonQuickToast.show("截图失败") }
                return
            }
            DispatchQueue.main.async {
                UIPasteboard.general.image = image
                AudioServicesPlaySystemSound(1108)   // 快门音（系统的截图音在 SB 里放不出来）
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, error in
                DispatchQueue.main.async {
                    if ok {
                        AevonLog.info("[快捷] 截图已存相册 + 已复制到剪贴板（AevonQuickShotV264）")
                        AevonQuickToast.show("截图已保存 · 已复制")
                    } else {
                        AevonLog.warn("[快捷] 截图存相册失败：\(error?.localizedDescription ?? "未知")"
                            + "（已放进剪贴板）（AevonQuickShotV264）")
                        AevonQuickToast.show("截图已复制（相册保存失败）")
                    }
                }
            })
        }
    }

    // MARK: - 录屏（V0.2.65：自己录，不再碰系统录屏服务）

    private static func toggleRecording() {
        AevonFrameRecorder.shared.toggle()
    }

    /// 给录制器用的抓帧入口（和截图同一条已验证通路）。
    static func captureFrameForRecorder() -> CGImage? {
        return captureScreenImage()?.cgImage
    }

}


/// V0.2.68（AevonReplayRecV268，用户 Aevon(40) #1「为什么不按照系统中的录屏那样记录视频？
/// 系统中录制的视频是 94 帧，播放时很流畅」+ #4「录屏有时候会失败」）
///
/// 用户问到了根上：自绘管线（drawHierarchy 抓帧 → 软编）天生不可能流畅 ——
/// Aevon(40) 实测 18 秒只录到 **31 帧**（约 1.7fps，标称 8fps 全被主线程吃掉），
/// 而且收尾 `status=3 这项操作无法完成`：真凶是 0.2.66 起把 append 扔进
/// `DispatchQueue.global` —— **那是并发队列**，多帧并行 append 时 presentationTime
/// 乱序倒退，AVAssetWriter 直接置 failed，finishWriting 必然 status=3。
///
/// 主路改走 **RPScreenRecorder**（ReplayKit 公开框架，AevonQuickAction.swift 自
/// 0.2.62 就 import 了）：
///   · 逆向档案 `analysis/screencore`（ScreenCore 插件 strings）实锤它就是在
///     SpringBoard 进程里用 `RPScreenRecorder` + start/stop + NSError 回调做系统级
///     录屏 —— 硬件编码、帧率与系统录屏一致，正是用户要的那条管线；
///   · `startCapture(handler:completionHandler:)`（iOS 11+，Apple 文档实锤的
///     Swift 签名：handler = (CMSampleBuffer, RPSampleBufferType, Error?)）收
///     sample buffer（后台线程、硬件帧、零拷贝），串行队列 append 进
///     AVAssetWriter（H.264 硬编）。纯 Swift，无需 delegate 垫片。
///
/// V0.2.72（AevonRecProbe2V272）：录屏探针已改**定向名单**（objc_getClass，零类表
/// 扫描），本体在 Sources/AevonRecProbe.swift。0.2.71 的全类表枚举实锤「点录屏
/// 扫描实锤「点击录屏图标自动注销」（Aevon(44) 崩溃栈 + 0.2.65 Aevon(38) 同款）——
/// **SB 进程全类表枚举永久封印**。

/// 兜底：RPScreenRecorder 不可用/启动失败 → 回落自绘管线，但 append 改**专用串行
/// 队列** + 时间戳在 append 队列内现取（单调，永不倒退），status=3 不可能复发。
final class AevonFrameRecorder: NSObject {
    static let shared = AevonFrameRecorder()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var appendQueue: DispatchQueue?
    private var timer: Timer?
    private var outputURL: URL?
    private var startTime = CACurrentMediaTime()
    private var frames = 0
    private var failedFrames = 0
    /// V0.2.73（AevonRecTimebaseV273，用户 Aevon(45) #5「录屏播放明显一卡一卡」）：
    /// **时隙计数器** —— 每拍 tick 消耗一个 1/fps 时隙（无论抓没抓到帧），append 的
    /// PTS = 时隙序号 × 1/fps。Aevon(45) 实锤 79 帧/12.8s ≈ 6fps：Timer 12Hz 被主线程
    /// 截图耗时压到 6fps，且 PTS 按实际抓帧时刻取 → 帧间隔忽大忽小 = 播放卡顿。
    /// 时隙计数自动吸收 Timer 抖动：帧间隔恒为 1/12 的整数倍，视频时长 = ticks/12
    /// = 真实时长，丢帧时隙 = 画面多停一拍而不是时间轴扭曲。
    private var recTickSlot = 0
    private var usingSystem = false
    private var stopRequested = false
    /// V0.2.71（AevonRecAttemptV271）：RP 启动尝试令牌。
    /// Aevon(43) #4 实锤：第一次 startCapture 失败（-5803）→ 0.6s 重试 → 重试的
    /// 「成功」只是同步返回值；13ms 后**第二次尝试的** completionHandler 又报 -5803，
    /// 落进自绘兜底 —— 用户拿到的 73 帧视频（≈7.3fps）就是兜底 8fps 节拍录的。
    /// 现在每次尝试带自增令牌，completionHandler 只认「自己那一拍」；迟到回调一律忽略。
    private var rpAttempt = 0
    /// 主路是否确认活着（首帧已到）。V0.2.71 起日志用它判「主路真起来了」。
    private var rpMainFirstFrame = false
    /// V0.2.71：启动失败重试上限 1 → 3（0.5s / 1.2s / 2.0s 退避）。
    private var rpRetryCount = 0
    // V0.2.76（AevonRecSysRouteV276）：系统录屏路线状态 —— 走通时视频由系统收尾存相册。
    private var systemRecActive = false
    private var sysRecToken = 0
    /* 自绘兜底档参数（V0.2.66/0.2.67 保留：主路失败才走）。
     * V0.2.71（AevonRecFps12V271，用户 Aevon(43) #4「录的视频明显一卡一卡」）：
     * 兜底节拍 8 → 12fps。0.2.68 串行队列后实测能吃满节拍（73 帧/10s ≈ 7.3 ≈ 8fps
     * 打满），说明瓶颈已不在主线程；12fps 换更顺滑的兜底画面，540 宽不变。
     * V0.2.75（AevonRecFps15V275，用户 Aevon(47) #1「帧率依旧很低」）：12 → 15fps
     * ——时隙时基（AevonRecTimebaseV273）下 PTS 与节拍解耦，丢拍只降实际帧数不跳帧；
     * 540 宽 15fps 单帧编码余量实测充足（12fps 稳跑），再高一档画质顺滑度。 */
    private let fps: Double = 15
    private let recMaxWidth: CGFloat = 540

    var isRunning: Bool { writer != nil || usingSystem || systemRecActive }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    private func start() {
        guard !isRunning else { return }
        frames = 0
        failedFrames = 0
        stopRequested = false
        rpRetryCount = 0
        rpMainFirstFrame = false
        outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Aevon-\(Int(Date().timeIntervalSince1970)).mp4")
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        // V0.2.68（AevonRecSerialV268）：append 只走这一条**串行**队列 ——
        // 时间戳永不倒退，status=3 从根上消灭（两条通路共用）。
        appendQueue = DispatchQueue(label: "com.aevon.recorder.append")
        AevonRecProbe.runOnce()
        if startSystemCapture() {
            // V0.2.69（AevonRecBadgeV269，用户 Aevon(41) #8「录屏开始时灵动岛没有
            // 提示…需要其他方式显示正在录屏，不然误触后不知道」）：SB 侧常驻
            // 指示胶囊，点按即停。RP 成功时系统录屏指示器由系统负责，胶囊只补
            // 「正在录的是 Aevon」这个信息。
            AevonRecBadge.show()
            AevonQuickToast.show("开始录屏")
            return
        }
        startOwnCapture()
    }

    // MARK: 主路：RPScreenRecorder（AevonReplayRecV268）

    private func startSystemCapture() -> Bool {
        let rec = RPScreenRecorder.shared()
        /* V0.2.76（AevonRecSysRouteV276，用户 Aevon(48)「控制中心录屏存在多个版本了，
         * 我们还没有找到具体路线吗？为什么还在自绘路线中？」）：系统录屏路线优先。
         * startCapture 的 -5803 在 SB 进程是本质限制（Aevon(43)~(48) 每版 4+ 连败，
         * 累计 12+），但系统自己的录屏管线就跑在 SB 进程（SBRecordingIndicatorWindow
         * x2 常驻窗口栈实锤），控制中心录屏按钮的入口是私有方法
         * `startSystemRecordingWithMicrophoneEnabled:handler:`（ScreenCore/MangoHello
         * 逆向双实锤 selector 名；两插件均动态调用未写死宿主类 —— 最可能的宿主就是
         * RPScreenRecorder 自身）。shim 里 respondsToSelector 探测命中才发调用，
         * 未命中/抛异常返回 0 → 原有 startCapture 链照旧，行为不变。
         * 回调带令牌：只认本拍的错误（迟到失败不许拉双兜底，0.2.71 教训）。 */
        sysRecToken += 1
        let sysToken = sysRecToken
        var sysStarted = false
        sysStarted = AevonTrySystemRecordingStart(rec) { err in
            DispatchQueue.main.async {
                guard sysToken == self.sysRecToken, !self.stopRequested else { return }
                if let err {
                    AevonLog.warn("[录屏] 系统路线启动失败：\(err.localizedDescription)"
                        + " → 直接落自绘兜底（不再烧 RP 重试预算）"
                        + "（AevonRecSysRouteV276 AevonRecFastFallV275）")
                    if self.systemRecActive {
                        self.systemRecActive = false
                        if self.writer == nil { self.startOwnCapture() }
                    }
                } else {
                    AevonLog.info("[录屏] 系统路线回调：已启动（控制中心同款管线）"
                        + "（AevonRecSysRouteV276）")
                }
            }
        }
        if sysStarted {
            systemRecActive = true
            usingSystem = false   // 不走 RP startCapture 的 sample 回调，帧由系统管线收
            AevonLog.info("[录屏] 系统路线已发起：控制中心同款私有入口命中"
                + "（60fps 硬编、视频由系统收尾存相册；花瓣照常显示、点停走 stopSystemRecording）"
                + "（AevonRecSysRouteV276）")
            return true
        }
        guard rec.isAvailable else {
            AevonLog.warn("[录屏] RPScreenRecorder 不可用（isAvailable=否）→ 走自绘兜底"
                + "（AevonReplayRecV268）")
            return false
        }
        usingSystem = true
        // V0.2.71（AevonRecAttemptV271）：尝试令牌 —— completionHandler 只认自己
        // 那一拍；上一拍迟到的失败回调（Aevon(43) 18:25:59.919 实锤）直接忽略，
        // 不再把已经成功的主路拽下来、更不会再拉起一份自绘兜底。
        rpAttempt += 1
        let attempt = rpAttempt
        rec.startCapture(handler: { [weak self] sample, bufferType, error in
            guard let self, self.usingSystem, !self.stopRequested, attempt == self.rpAttempt else { return }
            if let error {
                AevonLog.warn("[录屏] 系统抓屏帧错误：\(error.localizedDescription)"
                    + "（AevonReplayRecV268）")
                return
            }
            guard bufferType == .video else { return }
            if !self.rpMainFirstFrame {
                self.rpMainFirstFrame = true
                AevonLog.info("[录屏] 主路首帧已到（RP 管线确认存活，帧率与系统一致）"
                    + "（AevonRecAttemptV271）")
            }
            self.appendQueue?.async { [weak self] in
                self?.appendSystemSample(sample)
            }
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard attempt == self.rpAttempt, !self.stopRequested else {
                    if error != nil, attempt != self.rpAttempt {
                        AevonLog.info("[录屏] 忽略第 \(attempt) 拍的迟到失败回调"
                            + "（当前已是第 \(self.rpAttempt) 拍）（AevonRecAttemptV271）")
                    }
                    return
                }
                guard let error else { return }
                // V0.2.69（AevonRecRetryV269）：失败日志带上 domain/code ——
                // 「无法开始录制」没有 code 就定不了因（权限？会话占用？服务冷启动？）。
                let code = (error as NSError).code
                let domain = (error as NSError).domain
                AevonLog.warn("[录屏] RPScreenRecorder 启动失败：\(error.localizedDescription)"
                    + "（domain=\(domain) code=\(code)）（AevonReplayRecV268 AevonRecRetryV269）")
                self.usingSystem = false
                // V0.2.75（AevonRecFastFallV275，用户 Aevon(47) #1「录屏完成的视频帧率
                // 依旧很低」）：Aevon(47) 时序账（21:30:16~21:30:21）——用户点录屏后
                // RP 主路 -5803 三连败，退避 0.5+1.2+2.0 烧掉 **4 秒**才落兜底：用户
                // 以为在录的前 4 秒什么都没录上（花瓣已在转 = 假在录）。SB 进程 -5803
                // 已 7+ 连败 = 本质限制，重试预算砍半：2 次、0.3/0.6s 退避，+0.9s 内
                // 兜底开录，不再让用户对着不转的录制等 4 秒。
                guard self.rpRetryCount < 2 else {
                    self.startOwnCapture()
                    return
                }
                self.rpRetryCount += 1
                let backoff = [0.3, 0.6][self.rpRetryCount - 1]
                AevonLog.info("[录屏] \(String(format: "%.1f", backoff)) 秒后重试主路"
                    + "（第 \(self.rpRetryCount)/2 次）（AevonRecRetryV269 AevonRecAttemptV271 AevonRecFastFallV275）")
                DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
                    guard let self, !self.stopRequested, !self.isRunning else { return }
                    if self.startSystemCapture() {
                        AevonLog.info("[录屏] 主路重试已发起（第 \(self.rpRetryCount) 拍）"
                            + "（AevonRecAttemptV271）")
                    } else {
                        self.startOwnCapture()
                    }
                }
            }
        })
        AevonLog.info("[录屏] 主路启动：RPScreenRecorder 系统级抓屏（硬编、帧率与系统录屏"
            + "一致）（AevonReplayRecV268 AevonRecSerialV268）")
        return true
    }

    // MARK: 主路收帧（ReplayKit 内部队 → 串行 append 队列）

    private func appendSystemSample(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let pb = CMSampleBufferGetImageBuffer(sb) else {
            failedFrames += 1
            return
        }
        // 首帧先建 writer（首帧时 writer 还是 nil，必须在 status 检查之前）。
        if writer == nil {
            guard ensureSystemWriter(pixelBuffer: pb, firstPTS: pts) else { return }
        }
        guard let assWriter = writer, assWriter.status == .writing else { return }
        guard let videoInput = input, videoInput.isReadyForMoreMediaData else {
            failedFrames += 1
            return
        }
        // RP 的 sample buffer 直接喂 input（input 原生接受 CMSampleBuffer，
        // 走 adaptor 那条只收 CVPixelBuffer，还要转格式多一次拷贝）。
        if videoInput.append(sb) {
            frames += 1
        } else {
            failedFrames += 1
            if assWriter.status == .failed, failedFrames <= 2 {
                AevonLog.warn("[录屏] 系统帧 append 失败：\(assWriter.error?.localizedDescription ?? "未知")"
                    + "（AevonReplayRecV268）")
            }
        }
    }

    /// 第一帧到达时才建 writer（RP 帧的尺寸/格式到那时才确定；会话起点 = 首帧 PTS）。
    private func ensureSystemWriter(pixelBuffer: CVPixelBuffer, firstPTS: CMTime) -> Bool {
        if writer != nil { return true }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 16, h > 16, let url = outputURL else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let assWriter: AVAssetWriter
        do {
            assWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            AevonLog.warn("[录屏] 建不了输出文件：\(error.localizedDescription)"
                + "（AevonReplayRecV268）")
            usingSystem = false
            return false
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        // 不钉像素格式（RP 给的帧格式由系统定），只给尺寸。
        let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard assWriter.canAdd(videoInput) else {
            AevonLog.warn("[录屏] 写入器不接受视频轨（AevonReplayRecV268）")
            usingSystem = false
            return false
        }
        assWriter.add(videoInput)
        guard assWriter.startWriting() else {
            AevonLog.warn("[录屏] startWriting 失败：\(assWriter.error?.localizedDescription ?? "未知")"
                + "（AevonReplayRecV268）")
            usingSystem = false
            return false
        }
        assWriter.startSession(atSourceTime: firstPTS)
        writer = assWriter
        input = videoInput
        adaptor = bufferAdaptor
        AevonLog.info("[录屏] 已开始录制（系统抓屏 \(w)x\(h)，再点一次「录屏」结束并存相册）"
            + "（AevonReplayRecV268）")
        return true
    }

    // MARK: 兜底：自绘抓帧（0.2.65 管线，append 改串行队列）

    private func startOwnCapture() {
        guard writer == nil, !usingSystem else { return }
        guard let first = AevonQuickAction.captureFrameForRecorder() else {
            AevonLog.warn("[录屏] 抓不到第一帧，取消录制（AevonOwnRecorderV265）")
            AevonRecBadge.hide()
            AevonQuickToast.show("录屏失败：抓不到画面")
            return
        }
        var w = first.width          // Int（CGImage 像素）
        var h = first.height
        if CGFloat(w) > recMaxWidth {
            let scale = recMaxWidth / CGFloat(w)
            w = Int((CGFloat(w) * scale).rounded(.down) / 2) * 2
            h = Int((CGFloat(h) * scale).rounded(.down) / 2) * 2
        }
        w -= w % 2
        h -= h % 2
        guard w > 16, h > 16 else { return }
        guard let url = outputURL else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let assWriter: AVAssetWriter
        do {
            assWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            AevonLog.warn("[录屏] 建不了输出文件：\(error.localizedDescription)（AevonOwnRecorderV265）")
            AevonRecBadge.hide()
            AevonQuickToast.show("录屏失败：无法建文件")
            return
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard assWriter.canAdd(videoInput) else {
            AevonLog.warn("[录屏] 写入器不接受视频轨（AevonOwnRecorderV265）")
            return
        }
        assWriter.add(videoInput)
        guard assWriter.startWriting() else {
            AevonLog.warn("[录屏] startWriting 失败：\(assWriter.error?.localizedDescription ?? "未知")"
                + "（AevonOwnRecorderV265）")
            AevonRecBadge.hide()
            return
        }
        assWriter.startSession(atSourceTime: .zero)
        writer = assWriter
        input = videoInput
        adaptor = bufferAdaptor
        startTime = CACurrentMediaTime()
        recTickSlot = 0
        let ticker = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        AevonLog.info("[录屏] 开始录制（自绘兜底）：\(w)x\(h) @ \(Int(fps))fps → \(url.lastPathComponent)"
            + "（再点一次「录屏」结束并存相册）"
            + "（AevonOwnRecorderV265 AevonQuickSystemV263 AevonRecLightV266 AevonRecHdV267 AevonRecFps12V271 AevonRecTimebaseV273 AevonRecFps15V275）")
        AevonRecBadge.show()
        AevonQuickToast.show("开始录屏")
    }

    private func tick() {
        // V0.2.73（AevonRecTimebaseV273）：每拍先消耗一个时隙（成败无关），
        // PTS 走时隙轴而不是抓帧时刻轴 —— 帧间隔均匀，播放不再卡。
        recTickSlot += 1
        guard let assWriter = writer, assWriter.status == .writing else { return }
        guard let frame = AevonQuickAction.captureFrameForRecorder() else {
            failedFrames += 1
            return
        }
        let slot = recTickSlot
        // V0.2.68（AevonRecSerialV268）：帧丢进**串行** append 队列 —— 时间戳在队列内
        // 现取（单调），并发乱序导致的 status=3 从根上消灭。
        appendQueue?.async { [weak self] in
            self?.appendOwnFrame(frame, slot: slot)
        }
    }

    private func appendOwnFrame(_ image: CGImage, slot: Int) {
        guard let adaptor, let assWriter = writer, assWriter.status == .writing else { return }
        guard adaptor.assetWriterInput.isReadyForMoreMediaData else {
            failedFrames += 1
            return
        }
        // V0.2.73（AevonRecTimebaseV273）：PTS = 时隙序号 × 1/fps —— 时隙由 tick
        // 按拍分配（Timer 慢了时隙也慢，自动贴住真实时间轴），帧间隔恒定不抖。
        let time = CMTime(seconds: Double(slot) / fps, preferredTimescale: 600)
        guard let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            if let context = CGContext(data: base, width: width, height: height,
                                       bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: bitmapInfo) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: time) {
            frames += 1
        } else {
            failedFrames += 1
        }
    }

    private func stop() {
        // V0.2.76（AevonStopStageV276，用户 Aevon(48)「点花瓣暂停时会自动注销」）：
        // Aevon(48) 22:02:31.404 点按 → 32.509 SpringBoard 重新加载 = 点停即崩；
        // 同版本 21:30:21 那次点停却成功存相册 —— 非确定性崩溃，日志只有最后一条
        // 「花瓣被点按」，无法定位死在哪一步。停止路径分五段打点，复发日志直接
        // 指认崩溃段。同轮把 0.2.72 封印令补到漏网的启动探针上（AevonSealP1V276）。
        AevonLog.info("[录屏] 停止①收到停止请求（AevonStopStageV276）")
        stopRequested = true
        timer?.invalidate()
        timer = nil
        AevonRecBadge.hide()
        // V0.2.76：系统录屏路线 —— stopSystemRecording: 交给系统，视频收尾与
        // 存相册都由系统完成（与控制中心录屏的停止一致）。
        if systemRecActive {
            systemRecActive = false
            sysRecToken += 1
            let ok = AevonTrySystemRecordingStop(RPScreenRecorder.shared())
            AevonLog.info("[录屏] 停止②系统录屏收尾（\(ok ? "已发 stopSystemRecording，视频由系统存相册" : "系统通道未命中")）"
                + "（AevonStopStageV276 AevonRecSysRouteV276）")
            return
        }
        AevonLog.info("[录屏] 停止②自绘收尾开始（\(frames) 帧，失败 \(failedFrames) 帧）（AevonStopStageV276）")
        if usingSystem {
            RPScreenRecorder.shared().stopCapture { _ in }
            usingSystem = false
            AevonLog.info("[录屏] 停止系统抓屏，正在收尾（\(frames) 帧，失败 \(failedFrames) 帧）"
                + "（AevonReplayRecV268）")
        }
        guard let assWriter = writer, let videoInput = input else { return }
        let url = outputURL
        let total = frames
        let missed = failedFrames
        // V0.2.68（AevonRecSerialV268）：markAsFinished / finishWriting 排在 append
        // 队列末尾 —— 飞行中的帧先落地，绝不在收尾后再 append（status=3 的另一半根因）。
        appendQueue?.async { [weak self] in
            guard let self else { return }
            videoInput.markAsFinished()
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            self.outputURL = nil
            AevonLog.info("[录屏] 停止③finishWriting 提交（\(total) 帧）（AevonStopStageV276）")
            if total < 2 {
                AevonLog.warn("[录屏] 只有 \(total) 帧，当成失败处理（AevonReplayRecV268）")
                if let url { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async { AevonQuickToast.show("录屏失败：没抓到足够画面") }
                return
            }
            assWriter.finishWriting {
                let status = assWriter.status
                let failure = assWriter.error?.localizedDescription ?? "未知"
                AevonLog.info("[录屏] 停止④收尾回调 status=\(status.rawValue)（AevonStopStageV276）")
                DispatchQueue.main.async {
                    guard status == .completed, let url else {
                        AevonLog.warn("[录屏] 收尾失败：status=\(status.rawValue) \(failure)"
                            + "（AevonReplayRecV268）")
                        AevonQuickToast.show("录屏保存失败")
                        return
                    }
                    AevonLog.info("[录屏] 停止⑤存相册请求已发（AevonStopStageV276）")
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }, completionHandler: { ok, error in
                        DispatchQueue.main.async {
                            if ok {
                                AevonLog.info("[录屏] 已存相册（\(total) 帧，失败 \(missed) 帧）"
                                    + "（AevonReplayRecV268）")
                                AevonQuickToast.show("录屏已存相册")
                            } else {
                                AevonLog.warn("[录屏] 存相册失败：\(error?.localizedDescription ?? "未知")"
                                    + "（AevonReplayRecV268）")
                                AevonQuickToast.show("录屏已生成（相册保存失败）")
                            }
                        }
                    })
                }
            }
        }
        appendQueue = nil
    }
}

/// V0.2.64（AevonQuickShotV264）：SpringBoard 里没有系统截图缩略图，自己给一条提示。
/// 用户 Aevon(38) #5.4：「截图成功了，但是没有提示」—— 存相册是静默的，
/// 这里在屏幕底部弹一条 1.6 秒的提示条（不接管触摸，不挡浮窗）。
final class AevonQuickToast {
    private static var window: UIWindow?
    private static let tag = 0x7A37

    static func show(_ text: String) {
        DispatchQueue.main.async {
            guard Thread.isMainThread else { return }
            var overlay = window
            if overlay == nil { overlay = AevonHostWindow.makeOverlayWindow() }
            guard let panel = overlay else { return }
            window = panel
            panel.isHidden = false
            panel.frame = UIScreen.main.bounds
            panel.windowLevel = AevonWindowLevels.overlay + 2
            guard let host = panel.rootViewController?.view else { return }
            host.subviews.filter { $0.tag == tag }.forEach { $0.removeFromSuperview() }

            let screen = UIScreen.main.bounds
            let label = UILabel()
            label.tag = tag
            label.text = text
            label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 2
            label.backgroundColor = UIColor(white: 0.08, alpha: 0.86)
            label.layer.cornerRadius = 14
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            let maxWidth = screen.width - 64
            let fitting = label.sizeThatFits(CGSize(width: maxWidth, height: 200))
            let width = min(max(fitting.width + 36, 132), maxWidth)
            let height = max(fitting.height + 20, 44)
            label.frame = CGRect(x: (screen.width - width) / 2,
                                 y: screen.height - height - 120,
                                 width: width, height: height)
            host.addSubview(label)

            label.alpha = 0
            label.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction],
                           animations: {
                label.alpha = 1
                label.transform = .identity
            }, completion: { _ in
                UIView.animate(withDuration: 0.28, delay: 1.5,
                               options: [.curveEaseIn, .allowUserInteraction],
                               animations: {
                    label.alpha = 0
                    label.transform = CGAffineTransform(translationX: 0, y: -6)
                }, completion: { _ in
                    label.removeFromSuperview()
                })
            })
        }
    }
}

/// 花瓣点按转发目标（AevonRecFlowerV272）。
private final class AevonFlowerTapTarget: NSObject {
    @objc func tapped() {
        AevonLog.info("[录屏] 花瓣被点按 → 停止录制（AevonRecFlowerV272）")
        AevonFrameRecorder.shared.toggle()
    }
}

/// V0.2.69（AevonRecBadgeV269，用户 Aevon(41) #8）：录屏常驻指示器。
///
/// V0.2.72（AevonRecFlowerV272，用户 Aevon(44) #2「改成一个青色的花瓣悬浮在屏幕
/// 左上侧（距顶部约 25%，不贴左缘），动态随录制时间旋转（速度不要太快），花瓣
/// 周围有柔和光晕（不要太亮太夺目），点击花瓣结束录屏，花瓣消失」）：
/// 红胶囊退役，换「青色花瓣」—— 4 片椭圆花瓣组成的花层绕中心慢速旋转（8s/圈），
/// 底下叠一层青色低透明度光晕圆做呼吸脉冲（3s 往返，不夺目）；点击花瓣 = 停止
/// 录制，花瓣淡出消失。仍直接挂在 overlay 窗口上（0.2.71 已证 root.view 关交互
/// 挂法永远点不了）。
final class AevonRecBadge {
    private static var window: UIWindow?
    private static var flower: UIView?
    private static let tag = 0x7A52
    /// 点按转发目标（UITapGestureRecognizer 的 target 必须是对象，static 方法挂它转发）。
    private static let tapTarget = AevonFlowerTapTarget()

    /// 青色主色（系统 teal 区间，柔和不刺眼）。
    private static let teal = UIColor(red: 0.18, green: 0.77, blue: 0.71, alpha: 1)

    static func show() {
        DispatchQueue.main.async {
            guard Thread.isMainThread else { return }
            var panel = window
            if panel == nil { panel = AevonHostWindow.makeOverlayWindow() }
            guard let overlay = panel else { return }
            window = overlay
            overlay.isHidden = false
            overlay.frame = UIScreen.main.bounds
            overlay.windowLevel = AevonWindowLevels.overlay + 2
            overlay.subviews.filter { $0.tag == tag }.forEach { $0.removeFromSuperview() }

            let screen = UIScreen.main.bounds
            let side: CGFloat = 88
            let container = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
            container.tag = tag
            container.isUserInteractionEnabled = true
            container.backgroundColor = .clear
            // 左上：距顶约 25% 屏高，x 取屏宽 14%（不贴左缘）。
            container.center = CGPoint(x: screen.width * 0.14, y: screen.height * 0.25)

            // ① 光晕层：大圆，青色低透明 + 呼吸脉冲（3s 往返，柔和）。
            let halo = CAShapeLayer()
            // V0.2.74（AevonRecFlowerV274）：花瓣收小，光晕 76→60 同步收。
            let haloRect = CGRect(x: (side - 60) / 2, y: (side - 60) / 2, width: 60, height: 60)
            halo.path = UIBezierPath(ovalIn: haloRect).cgPath
            halo.fillColor = teal.withAlphaComponent(0.10).cgColor
            halo.strokeColor = teal.withAlphaComponent(0.18).cgColor
            halo.lineWidth = 1.5
            container.layer.addSublayer(halo)
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.45
            breath.toValue = 1.0
            breath.duration = 3.0
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(breath, forKey: "aevon.halo.breath")

            // ② 花瓣层：6 片「一角贴花心」的花瓣绕中心转（8s/圈，慢速）。
            // V0.2.76（AevonRecPetal6V276，用户 Aevon(48)「花瓣的数量可以再增加几片，
            // 现在的 4 片有点少」）：4 → 6 片，60° 均分；瓣长 21→19 防六瓣拥挤。
            // V0.2.74（AevonRecFlowerV274，用户 Aevon(46) #3「花瓣太大了，应该是花瓣
            // 一角贴近中心圆点」）：椭圆版花瓣整条底边压在花心上（底宽 22pt 一坨挤在
            // 中心圆点周围），视觉臃肿。改贝塞尔花瓣形：尖端（一角）收在中心圆点上，
            // 向外鼓成圆头花瓣，整体收小（长 30→21、宽 11→8）。side 88 不动，保点按热区。
            let petalHost = CALayer()
            petalHost.frame = CGRect(x: 0, y: 0, width: side, height: side)
            petalHost.position = CGPoint(x: side / 2, y: side / 2)
            let petalLen: CGFloat = 19   // 花瓣长（花心尖端 → 圆头）
            let petalWide: CGFloat = 8   // 花瓣最宽处半宽
            for i in 0..<6 {
                let petal = CAShapeLayer()
                // V0.2.75（AevonPetalCenterV275，用户 Aevon(47) #2「应该是四个花瓣围在
                // 一起，而不是围着一个角转」）：0.2.74 的旋转绕错了点 —— CAShapeLayer
                // 没设 bounds 时 anchorPoint 落在 layer 坐标 (0,0)（= petalHost 左上角），
                // CATransform3DMakeRotation 全部绕那个角转，四瓣散成一圈「围着一个角」。
                // 修法：显式设 bounds + position，让 anchorPoint 恰好落在花心
                //（layer 坐标 (side/2, side/2) 对齐 petalHost 中心），旋转绕花心。
                petal.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                petal.position = CGPoint(x: side / 2, y: side / 2)
                // 花瓣 = 尖端在花心 (side/2, side/2)、长轴竖直向外的对称贝塞尔形，
                // 再整体绕花心转 i*90°。
                let path = UIBezierPath()
                path.move(to: CGPoint(x: side / 2, y: side / 2))
                path.addCurve(to: CGPoint(x: side / 2, y: side / 2 - petalLen),
                              controlPoint1: CGPoint(x: side / 2 - petalWide, y: side / 2 - petalLen * 0.42),
                              controlPoint2: CGPoint(x: side / 2 - petalWide * 0.55, y: side / 2 - petalLen))
                path.addCurve(to: CGPoint(x: side / 2, y: side / 2),
                              controlPoint1: CGPoint(x: side / 2 + petalWide * 0.55, y: side / 2 - petalLen),
                              controlPoint2: CGPoint(x: side / 2 + petalWide, y: side / 2 - petalLen * 0.42))
                path.close()
                petal.path = path.cgPath
                petal.fillColor = teal.withAlphaComponent(0.85).cgColor
                petal.strokeColor = teal.withAlphaComponent(0.95).cgColor
                petal.lineWidth = 1
                petal.transform = CATransform3DMakeRotation(CGFloat(i) * .pi / 3, 0, 0, 1)
                petalHost.addSublayer(petal)
            }
            container.layer.addSublayer(petalHost)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 8.0
            spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            petalHost.add(spin, forKey: "aevon.flower.spin")

            // ③ 中心小圆芯（盖住四瓣交汇处，颜色略深）。
            let core = CAShapeLayer()
            let coreRect = CGRect(x: side / 2 - 5.5, y: side / 2 - 5.5, width: 11, height: 11)
            core.path = UIBezierPath(ovalIn: coreRect).cgPath
            core.fillColor = UIColor(red: 0.10, green: 0.55, blue: 0.52, alpha: 1).cgColor
            container.layer.addSublayer(core)

            // ④ 点花瓣 = 停止录制。
            let tap = UITapGestureRecognizer(target: tapTarget,
                                             action: #selector(AevonFlowerTapTarget.tapped))
            container.addGestureRecognizer(tap)
            overlay.addSubview(container)
            flower = container

            container.alpha = 0
            UIView.animate(withDuration: 0.25) { container.alpha = 1 }
            AevonLog.info("[录屏] 花瓣指示器已显示（青色花瓣 · 六瓣围花心 · 左上 25% · 慢旋 · 柔光晕 · 点按即停）"
                + "（AevonRecBadgeV269 AevonRecBadge2V271 AevonRecFlowerV272 AevonRecFlowerV274 AevonPetalCenterV275 AevonRecPetal6V276）")
        }
    }

    static func hide() {
        DispatchQueue.main.async {
            guard Thread.isMainThread else { return }
            guard let v = flower else { return }
            // 停掉两层动画再淡出，避免收窗时动画层残影。
            v.layer.sublayers?.forEach { $0.removeAllAnimations() }
            UIView.animate(withDuration: 0.25, animations: { v.alpha = 0 },
                           completion: { _ in
                               v.removeFromSuperview()
                               if flower === v { flower = nil }
                               window?.isHidden = true
                           })
        }
    }
}
