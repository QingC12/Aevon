//
//  ActivateProbe.swift — Aevon, SpringBoard side.
//
//  0.4.0 — 这个文件原来是「激活面取证 + URL 分流」的全部装配：
//  `SBMainWorkspace -_handleOpenApplicationRequest:…` 的替身、五道开关闸、
//  180 秒闩、装载后 3 秒的延迟装配、以及十来个 `url.*` / `notify.*` / `share.*`
//  闸函数。整条线服务的是「点通知 / 点分享 → 浮窗」，随 URL 主线一起删除，
//  一句不留。
//
//  只保留一个函数：presenter 的 `presentationContext` 上写
//  `setResizesHostedContext:`。它属于承载层（卡片里的 scene 要不要跟着卡片
//  重排尺寸），与 URL 无关。
//

import Foundation

/// 0.3.5 — 在 presenter 的 `presentationContext` 上写 `setResizesHostedContext:`。
///
/// `setResizesHostedContext:` 的 owner 是 `UIMutableScenePresentationContext`
/// （Aevon(230) 的选主子普查实测：`owner=UIMutableScenePresentationContext v20@0:8B16`），
/// **不是 presenter 本身**。所以生产链里那句
/// `AevonCallSetBool(presenter, "setResizesHostedContext:", true)`
/// 从 0.2.x 起就一直返回 0 —— 返回值被 `_ =` 丢掉，没人看见。
///
/// 正确入口是 `modifyPresentationContext:`（presenter 上，参数 block），
/// block 收到一个可变的 presentation context，在**它**身上写。
///
/// 返回 1 = 调用发生了 / 0 = presenter 不答 `modifyPresentationContext:`。
@discardableResult
@_cdecl("AevonModifyContextSetResize")
public func AevonModifyContextSetResize(_ presenter: AnyObject?, _ selName: UnsafePointer<CChar>?) -> Int32 {
    guard let presenter = presenter, let selName = selName else { return 0 }
    let name = String(cString: selName)
    let modify = NSSelectorFromString("modifyPresentationContext:")
    guard presenter.responds(to: modify) else {
        Log.write("presenter: resize skip why=nomodify")
        return 0
    }
    typealias ModifyFn = @convention(c) (AnyObject, Selector, (AnyObject) -> Void) -> Void
    let fn = unsafeBitCast(presenter.method(for: modify), to: ModifyFn.self)
    fn(presenter, modify, { ctx in
        let setSel = NSSelectorFromString(name)
        guard ctx.responds(to: setSel) else {
            Log.write(String(format: "presenter: resize ctx no setter cls=%@",
                             String(describing: type(of: ctx))))
            return
        }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        let set = unsafeBitCast(ctx.method(for: setSel), to: SetBool.self)
        set(ctx, setSel, true)
        // 写了不等于存住了：读回一次。
        let getSel = NSSelectorFromString("resizesHostedContext")
        var back = "?"
        if ctx.responds(to: getSel) {
            typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
            let get = unsafeBitCast(ctx.method(for: getSel), to: GetBool.self)
            back = get(ctx, getSel) ? "1" : "0"
        }
        // 用完整格式串，不用 `+` 拼接：拼接出来的东西在产物里查不到（audit
        // 断言钉的是字面量），而这一行是「这一刀到底成没成」的唯一证词。
        Log.write(String(format: "presenter: resize ctx cls=%@ read=%@",
                         String(describing: type(of: ctx)), back))
    })
    return 1
}
