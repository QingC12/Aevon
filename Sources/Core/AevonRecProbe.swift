/// V0.2.72（AevonRecProbe2V272）：录屏入口探测改**定向名单**。
///
/// V0.2.71 血泪实锤（Aevon(44)「点击录屏图标时自动注销」+ 崩溃栈 main.async →
/// _CF_forwarding_prep_0 → swift_dynamicCast）：**objc_copyClassList 全类表扫描
/// 本身就致命** —— 遍历触发全部类的 +initialize，某 SB 私有类的 initialize 里
/// 消息转发 + Swift dynamicCast 直接 SIGTRAP，SpringBoard 整个退出。这与
/// 0.2.65 Aevon(38)「一点录屏就注销」是同一个坑 —— 当时结论「不再遍历类表」，
/// 0.2.71 我以「只扫不调」为由重踩，**此路线永久封印：任何情况下不许在
/// SB 进程枚举全类表**。
///
/// 替代 = objc_getClass 定向名单：只查运行时注册表（**不触发 +initialize**），
/// 候选类名来自 ScreenCore/Mango 逆向档案与 iOS 17 私有框架命名惯例，
/// 逐个查 respondsToSelector(startSystemRecordingWithMicrophoneEnabled:handler:)。
/// 一个都没命中就打「全部未命中」，下一轮换名单继续。
import ObjectiveC.runtime
import ReplayKit

enum AevonRecProbe {
    private static var done = false
    /// 候选宿主类名单（反向档案 + iOS 17 命名惯例；命中即日志定档）。
    /// V0.2.76（AevonRecSysRouteV276）：主路已直接试 RPScreenRecorder 的私有方法，
    /// 本名单继续作为「宿主在别处」的取证网逐轮扩。
    private static let candidates: [String] = [
        "SBSystemRecordingController",
        "SBSystemRecordingManager",
        "SBSystemRecordingService",
        "SBScreenRecordingController",
        "SBScreenRecordingManager",
        "SBScreenRecordingService",
        "SBCCScreenRecordingModule",
        "SBRecordingIndicatorController",
        "SBRecordingEnvironment",
        "SBRecordingSessionController",
        "SCScreenRecordingController",
        "SCScreenRecordingManager",
        "SCRecordingManager",
        "SCRecordingController",
        "SCSystemRecordingController",
        "SCSystemRecordingManager",
        "SBRecordingController",
        "SBRecordingManager",
        "CCUIRecordingModule",
        "CCUIScreenRecordingModule",
        "CCUISCRecordingModule",
        "RPScreenRecordingManager",
        "RPRecordingConnection",
        "UIStatusBarSystemRecordingIndictorView", // Apple 拼写错误的官名，顺带验证
        "UIStatusBarSystemRecordingIndicatorView",
    ]
    static func runOnce() {
        guard !done else { return }
        done = true
        DispatchQueue.main.async {
            let target = "startSystemRecordingWithMicrophoneEnabled:handler:"
            let sel = NSSelectorFromString(target)
            var hits: [String] = []
            // V0.2.76（AevonRecSysRouteV276）：先查 RPScreenRecorder 实例自己 ——
            // 私有方法最可能就挂在它身上（respondsToSelector 不触发 +initialize，安全）。
            let rec = RPScreenRecorder.shared()
            if rec.responds(to: sel) {
                hits.append("RPScreenRecorder(-)")
            }
            for name in candidates {
                guard let cls = NSClassFromString(name) else { continue }
                if class_respondsToSelector(object_getClass(cls), sel) {
                    hits.append("\(name)(+)")
                } else if class_respondsToSelector(cls, sel) {
                    hits.append("\(name)(-)")
                }
            }
            AevonLog.info("[录屏] 探针(定向)：\(target) 命中 \(hits.count) 个 → "
                + (hits.isEmpty ? "名单全部未命中（下一轮换名单）"
                                 : hits.joined(separator: " | "))
                + "（历史链 AevonRecProbeV271 类表扫描版已被本定向版取代）"
                + "（AevonRecProbe2V272）")
        }
    }
}
