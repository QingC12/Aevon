//
//  ActivateProbe.swift — Aevon, SpringBoard side.
//
//  0.1.88 — 「通知点击 → 浮窗」：**第一次真的改行为**。
//
//  0.1.85 找错了名字（`_activateBundleID:…` 在这台机器上不存在），0.1.86 用只读
//  普查把真名列了出来，0.1.87 按真名装上去、只读、只转发，拿到了一份完整的现场：
//
//      notify: hit op=open      act=#UINotificationResponseAction n=1 req=com.tencent.mqq
//      notify: hit op=trusted   act=#UINotificationResponseAction n=1 req=com.tencent.mqq
//
//  于是这一版有三件事是确定的，不再是猜的：
//
//    · 点通知走 `SBMainWorkspace -_handleOpenApplicationRequest:…`，再进
//      `-_handleTrustedOpenRequestForApplication:…`；
//    · 「这是通知点击」的判据是 `options.__Actions.firstObject` 的类名含
//      `NotificationResponseAction`（同一天从分享面板打开 App 是同样两条，
//      但 `act=- n=0`，两者分得开）；
//    · 目标 bundle id 就在 `request` 自己身上（它就是那个字符串）。
//
//  所以这个替身第一次有了「不原样转发」的分支：认出是通知点击时，SpringBoard 那
//  一段（建 app layout、全屏推前台）整段跳过，改叫 `AevonOpenFromNotification`
//  → `SceneProbe.openCard` → 挂起启动 + 建卡片，和圆盘图标走同一条路。
//
//  危险面随之变大，所以闸也变多了，见 `AevonScene.m` 里 `AevonOpenDecide`：
//
//    闸一 · 开关   `notify.off` 在 ⇒ 一个字节都不改，行为和 0.1.87 完全一样。
//                  这一条每拍都查，不是只在装配那一刻查一次。
//    闸二 · 判据   类名必须含 `NotificationResponseAction`。点图标、分享面板、
//                  系统 URL 都不含，一律照旧全屏。
//    闸三 · 目标   取不到 bundle 或目标是 SpringBoard 自己 ⇒ 不接管。
//
//  0.2.1 — 原来的「闸四 · 兜底」（2.5 秒查卡片、没起来就补调原实现）整段删除。
//  Aevon(169) 证明它是自循环的发动机：补调 ⇒ 原实现再走一遍被接管的入口 ⇒ 再分流 ⇒
//  再建卡 ⇒ 再失败 ⇒ 再补调，每轮附一次 10 秒整的同步 XPC，主线程 2 分 07 秒里停了
//  100 秒。现在一次点击最多一次全屏回落（`openCard` 自己那条），不再回灌原实现。
//
//  装配侧的四道闸（存在 / 逐字节形状 / 归属 / 原实现）与两道时间闸（`notify.armed`
//  180 秒、装载后 3 秒）原样保留 —— 0.1.87 证明了它们能装上，也证明了它们没惹事。
//
//  0.1.89 补的是「点完之后没人收场」：真机日志证明五条通知全部进了浮窗、一次 replay
//  都没有，但通知中心不关、横幅不收。原因不是漏写，是 0.1.88 那个「不转发」的代价 ——
//  收面板与收横幅本来挂在 SpringBoard 那段收尾里。所以分流之后 0.45 秒补一次收尾，
//  实现与闸都在 `AevonScene.m` 的 `AevonNotifyCleanup`；这一侧一行都没动。
//
//  0.1.90 修的是 0.1.89 那次收尾自己的两处错（Aevon(157)）：横幅收了、面板一次都没收，
//  三次 `cover=locked` 一次 `cover=down`。
//
//    · `SBLockScreenManager.isUILocked` **不能当锁屏闸**：通知中心（CoverSheet）就是锁屏
//      那一套 UI，它在屏时这一位本来就是 1 —— 这个闸在唯一该收的场景里恒为真，等于把功能
//      关掉。改用 `isPasscodeLocked`（真要用密码才拦），并配一条更硬的判据见下。
//    · 收面板不能定时，要**等卡片**：真机上分流那一拍到卡片真正在隔着 2~3 秒，0.45 秒
//      就收会露出两三秒空白桌面。改成 0.15 秒一拍、最多 24 拍轮询 `AevonCardIsUpFor()`，
//      卡片在的那一拍收面板。卡片没起来就不收 —— 真锁屏时挂起启动起不来，卡片自然不会
//      出现，锁这件事就不用单独去猜。
//    · 形状闸的比较键写错了：`@?`（块）归一化后与 `@` 不同，于是 `v@:BB@?` 永远不等于
//      候选表里的 `v@:BB@`，六个候选一次都没进过闸。0.1.90 把 `@?` 折叠成 `@`，并把
//      六个候选的真实编码在开机后第一次收尾时打一行 `notify: cover sels …`。
//
//  0.1.91 只调速度，不碰判据。Aevon(158) 证明收面板这条链通了（四次点击四次
//  `cover=ok:`，其中三次 `wait=0`），慢的是 0.45 秒起始延迟 + 0.15 秒节拍：
//
//    · 起始延迟 0.45 → 0.10 秒，节拍 0.15 → 0.04 秒（`AEVON_CLEAN_DELAY` / `_POLL`）。
//    · 冷启动时卡片要等 scene 才占槽（0.1~0.5 秒），干等那半秒就是用户说的「慢」。
//      所以给「卡在路上」单开一个出口：`AevonCardIsComingFor`（`openCard` 进门就登记，
//      3 秒过期）答 1 且已等满 0.3 秒 ⇒ 也收，面板自己那 0.35 秒下滑正好盖住卡片落地。
//    · `openCard` 压根没接手（真锁屏 / 开卡失败）时两位都答 0 ⇒ 一拍都不收，
//      最多问到 3.6 秒 —— 0.1.90 的安全判据原样保留。
//    · 日志多了 `at=`（手指 → 面板开始走，毫秒）与 `f=1`（在「卡在路上」时收的）。
//
//  0.1.92 加了两条新进项，一条动的还是这里，一条在 C 侧：
//
//    · **清通知**（「点开 = 已读」）：分流那一拍取标识，0.60 秒后到
//      `bannerDestination` 等宿主上 withdraw 那一条。取不到就一行都不做。
//      实现与三条「拿不到就什么都不做」都在 `AevonScene.m` 的 `AevonClearNotification`。
//    · **分享面板 → 浮窗**：判据是来源进程 `sharingd`（0.1.87 真机日志里的分享对照行），
//      与通知那条共用 `AevonOpenDecide` 的同一段分流，但**不跑通知那套收尾**（没有面板
//      要收、没有横幅要撤、也没有「这条已读」）。开关是 `share.off`，`notify.off` 仍是总闸。
//
//  0.1.93 是止血版。Aevon(161) 尾部三十五分钟一行日志都没有：手指按在屏幕上，`sendEvent`
//  一次都没再被调用，也没有崩溃、没有重启。这份代码里唯一能在主线程上无限期等下去的
//  是那次手势的第一条 `dragMove` —— 它会走 `lockBand()` → `AevonAppBandLock` → 对十个
//  正在运行的 App 各写一次偏好域（同步 `CFPreferencesSynchronize` + 目录扫描 + 原子落盘），
//  全部压在主线程。cfprefsd 一忙就整机死。写盘与通知已移到串行队列；另外两处「一次开机
//  N 次」的配额（分流 24、收尾 6）改成滑动窗口 —— 真机上它们分别在 12:07 与 01:27 用满，
//  之后浮窗打不开、面板横幅也不再收，用户除了重启没有别的办法。这一侧仍然一行没动。
//

import Foundation

/// `AevonScene.m` 里的 C 函数，只此一处声明。
@_silgen_name("AevonActivateProbeInstall")
private func AevonActivateProbeInstall()

/// `AevonScene.m` 的分流判定每一拍都要问一次「人关了没有」。
///
/// 只在装配那一刻查一次是不够的：`notify.off` 的语义是「现在别动我的 App 打开」，
/// 而人在发现不对劲之后建这个文件时，钩子已经在内存里跑着了。所以这条查询放在
/// 热路径上 —— 一次 `fileExists` 对一次 App 启动来说可以忽略。
@_cdecl("AevonActivateSwitchOff")
public func AevonActivateSwitchOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.activateOffPath) ? 1 : 0
}

/// 0.1.92 — 分享面板那条路的独立开关。
///
/// 与上面那位同一个理由（热路径上每次都要问一遍），但语义不同：`notify.off` 是
/// 「别动我的 App 打开」的总闸，`share.off` 只关分享这一条。两个任一存在，
/// 分享一律不接管 —— 总闸的语义不能因为多了一个新功能而被稀释。
@_cdecl("AevonShareSwitchOff")
public func AevonShareSwitchOff() -> Int32 {
    let manager = FileManager.default
    if manager.fileExists(atPath: Aevon.activateOffPath) { return 1 }
    return manager.fileExists(atPath: Aevon.shareOffPath) ? 1 : 0
}

/// 0.3.20 — 「出生即卡尺寸」这条写路的独立开关。
///
/// 与前两位都不同：那两个关的是**接管**（吞不吞这次打开），这一位关的是
/// **写 scene 参数**。`AevonActFrameBirth` 是整个工程里唯一一处「在建 scene 之前
/// 改系统参数」的地方 —— 0.2.92 往不可变 settings 写 frame 直接 trap，
/// SpringBoard 当场重启。所以它值得一个自己的开关。
///
/// 返回 1 = 建了 `birth.off`，这一刀不写（只留只读读数）。
@_cdecl("AevonBirthSwitchOff")
public func AevonBirthSwitchOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.birthOffPath) ? 1 : 0
}

/// 0.3.23 — URL / 分享那条路「要不要真的写出生尺寸」。
///
/// 与 `AevonBirthSwitchOff` 方向相反：那位是**关**（存在即不写），这一位是**开**
/// （存在才写）。理由：URL 路比圆盘路多一个没人验过的变量 —— 系统激活事务会不会
/// 在出生尺寸之后把 scene 摆回整屏。默认干跑只留读数，确认门槛都过再手写打开。
@_cdecl("AevonURLWriteOn")
public func AevonURLWriteOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlWritePath) ? 1 : 0
}

/// 0.3.24 — URL / 分享路「把 scene 收进卡」的关闸（`url.card.off`）。
///
/// Aevon(250)：写 frame 成功了，系统也认了，但装 scene 的窗口还是 430×932 ——
/// 屏幕上就是「上半是 QQ、下半是黑」。这一版补承载；把闸留成**关**的方向
/// （存在即不开卡），出问题时一个空文件就退回 0.3.23 的干跑状态，不必换包。
@_cdecl("AevonURLCardSwitchOff")
public func AevonURLCardSwitchOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlCardOffPath) ? 1 : 0
}

/// 0.3.26 — 「分享型激活要不要拒答」。
///
/// 返回 1 = 拒答（**默认**）：`_activateBundleID:…withResult:` 里不调原函数，
/// 系统因此不会提交激活事务，也就没有那个 430×932 的全屏窗口。目标 App 改由
/// 我们自己的挂起启动拉起、scene 进我们自己的卡 —— 这条路圆盘已经走了一年。
///
/// 返回 0 = 建了 `url.deny.off`：行为退回 0.3.25（放行 → 出生改尺寸 → 卡）。
/// 方向与 `birth.off` / `url.card.off` 一致：**存在即不做**。
@_cdecl("AevonURLDenyOn")
public func AevonURLDenyOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlDenyOffPath) ? 0 : 1
}

/// 0.3.33 — URL 接管范围：只接分享，还是把点链接 / 授权 / 支付也接进来。
///
/// 返回 1（默认）= 全接。判据在 C 侧：带 `__PayloadURL` 且 scheme 不在
/// 「系统必须自己处理」那一组里（`file:` `tel:` `sms:` `prefs:` `itms-*` …）就拒答，
/// 目标 App 由我们拉起、scene 进我们自己的卡 —— 和分享那条路一模一样。
/// 返回 0 = 建了 `url.global.off`，退回 0.3.32（只有 `shareKind == 2` 才接）。
@_cdecl("AevonURLGlobalOn")
public func AevonURLGlobalOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlGlobalOffPath) ? 0 : 1
}

/// 0.3.26 — 卡片起来之后要不要把 URL 补投一次。
///
/// 返回 1 = 投（默认）。拒答让 QQ 由我们拉起，但 URL 没有跟着进 scene，
/// 所以它可能停在首页；补投一次把它带到分享页。补投可能触发新激活，
/// 所以调用方会在 3 秒窗口内放行一次，避免自己把自己再拒一遍。
/// 建了 `url.redeliver.off` 就完全不投。
@_cdecl("AevonURLRedeliverOn")
public func AevonURLRedeliverOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlRedeliverOffPath) ? 0 : 1
}

/// 0.3.27 — 补投能不能走 `openSensitiveURL:`（软路径）。
///
/// 返回 1 只在用户手建 `url.redeliver.soft` 时成立。默认 0：那条路会再提交一次
/// 激活事务，把全屏窗装回来 —— 用户已经把「出现全屏那一帧」列为禁止项。
@_cdecl("AevonURLRedeliverSoftOn")
public func AevonURLRedeliverSoftOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlRedeliverSoftPath) ? 1 : 0
}

/// 0.3.29 — 冷启动「补发」的关闸（`url.shot.off`）。
///
/// 返回 1 = 只投一发（建了 `url.shot.off`）。默认 0：冷启动（拒答那一刻目标进程
/// 不在）多发两发，间隔 1.2 s。理由是 Aevon(252) 的第一次分享 —— 进程 16:07:36
/// 才 boot，URL 16:07:38 送进 scene，QQ 16:07:39 才打完首帧布局，首页恢复把
/// 分享页盖掉了。热启动同一个读数就直接进选好友页，所以多发只给冷启动。
@_cdecl("AevonURLShotOff")
public func AevonURLShotOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlShotOffPath) ? 1 : 0
}

/// 0.3.30 — 要不要把 URL 装进新 scene 的 `transitionContext`。
///
/// 返回 1 = 不装（建了 `url.tctx.off`）。默认 0：装。这是冷启动唯一走过的那条
/// 原生投递口 —— 热启动用 scene action 已经「秒出」，冷启动三发全丢。
@_cdecl("AevonURLTctxOff")
public func AevonURLTctxOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlTctxOffPath) ? 1 : 0
}

/// 0.3.35 — **授权 / 支付那两族要不要接管**（`url.act.on` 存在 = 才接）。
///
/// 默认 0（不接）。Aevon(259) 证明这两族的 URL 不在 `__PayloadURL` 上 ——
/// 它们被系统包成 `UIActivityContinuationAction`，URL 在 action 的
/// `NSUserActivity.webpageURL` 上（`act: url dig hit` 那一行是证据）。
/// 0.3.35 先把 URL 挖出来看清形状；接管要手建 `url.act.on` 再重启桌面。
///
/// 语义与其它闸相反：**存在才做**。
@_cdecl("AevonURLActOn")
public func AevonURLActOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlActOnPath) ? 1 : 0
}

/// 0.3.36 — 存在 = 强制回到 0.3.35 的「吞掉 + 自投」。
@_cdecl("AevonURLSwallowOn")
public func AevonURLSwallowOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlSwallowOnPath) ? 1 : 0
}

/// 0.3.36 — 1 = 接管「活动继续」这一族（默认），0 = 建了关闸文件。
@_cdecl("AevonURLActivityOn")
public func AevonURLActivityOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlActivityOffPath) ? 0 : 1
}

/// 0.3.37 — 1 = 回到 0.3.36 的「放行式接管」（存在才放行）。
///
/// 默认 0：吞掉。Aevon(262) 证明放行必然带回系统那份全屏窗，而我们在
/// 150 ms 后把 scene 搬走，留下的就是一个空的全屏窗 —— 黑。
@_cdecl("AevonURLPassOn")
public func AevonURLPassOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlPassOnPath) ? 1 : 0
}

/// 0.3.37 — 1 = tctx 装上之后仍然补发（存在才补，默认不补）。
@_cdecl("AevonURLPlusOn")
public func AevonURLPlusOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlPlusOnPath) ? 1 : 0
}

/// 0.3.38 — 1 = 冷启动走进程内桥（默认），0 = 建了 `url.bridge.off` 退回老路。
///
/// 「默认开」不是口味问题：0.3.37 的冷启动分享实测停在首页（Aevon(263)），
/// 而热启动同一条 URL 就能进选好友页 —— 差别只剩投递口。桥是唯一还没在
/// 这一族上被试过的口，所以默认交给它；它失败会自己重投 14 次，宿主不再插一层。
@_cdecl("AevonURLBridgeOn")
public func AevonURLBridgeOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlBridgeOffPath) ? 0 : 1
}

/// 0.3.44 — 1 = 冷启动分享不接管（默认），0 = 建了 `url.coldshare.pass.off` 退回建卡。
///
/// 冷启动这条路我们试过五个投递口（tctx 注入、scene action 三发、进程内桥 12 次、
/// 桥失败后补发、延迟到 8 秒后），全部停在 QQ 首页。系统原生那一发是唯一还没被
/// 否定过的通道 —— 它带着 `__PayloadURL` 和 `__PasteSharingToken`，而且由
/// FrontBoard 自己写进新 scene 的 connection options。所以这一族交回系统。
@_cdecl("AevonColdSharePassOn")
public func AevonColdSharePassOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlColdSharePassOffPath) ? 0 : 1
}

/// 0.3.49 — 1 = 冷启动分享走「扣下原始请求、等托管就绪再交回」（实验路），
/// 0 = 默认，交回系统（不接管，全屏，但面板一定会出）。
///
/// 这条实验路在 0.3.45 / 0.3.48 上过两次真机，两次都是同一行
/// `win: card yield seen now=430x932`，QQ 侧零 `app: openurl`。所以默认关；
/// 要再做对照时手建 `url.cold.hold.on`，`url.cold.hold.off` 是它的强关。
@_cdecl("AevonColdHoldOn")
public func AevonColdHoldOn() -> Int32 {
    let fm = FileManager.default
    if fm.fileExists(atPath: Aevon.urlColdHoldOffPath) { return 0 }
    return fm.fileExists(atPath: Aevon.urlColdHoldOnPath) ? 1 : 0
}

/// 0.3.46 — 1 = 托管就绪那一拍**先问桥**（0.3.45 的形状，A/B 用），
/// 0 = 直接交回原始请求（默认，这一版的立场）。
///
/// 两条路的差别只有「投的是什么」：桥送空字典 + 来源 App（QQ 只回
/// `via=app-src rsp=0`），交原件送的是系统自己那份 `__PayloadOptions` /
/// `__PasteSharingToken`。日志上分得开：`act: cold bridge` vs
/// `act: cold replay why=hosted`。
@_cdecl("AevonColdBridgeOn")
public func AevonColdBridgeOn() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlColdBridgeOnPath) ? 1 : 0
}

/// 0.3.49 — 1 = 交回原件之前写 `__ActivateSuspended`（实验，默认关），
/// 0 = 一个字节都不改（默认）。
///
/// Aevon(5)(2) 已经量过：`act: cold replay … susp=1 boxed=0` 之后紧跟
/// `win: card yield seen now=430x932` —— 位写进去了、读得回来，FrontBoard 照样
/// 提交它自己的全屏事务。所以这一格默认关，只作为「换一台设备/换一个系统版本
/// 再验一次」的开关。
@_cdecl("AevonColdSuspOn")
public func AevonColdSuspOn() -> Int32 {
    let fm = FileManager.default
    if fm.fileExists(atPath: Aevon.urlColdSuspOffPath) { return 0 }
    return fm.fileExists(atPath: Aevon.urlColdSuspOnPath) ? 1 : 0
}

/// 0.3.31 — 要不要把 URL 交给**启动那一拍**（`url.launch.off` 存在 = 不带）。
///
/// 默认带。这是冷启动最后一条还没被真机否定的投递口：前两条（scene action、
/// tctx 注入）都已实测无效，而原生分享之所以「一点就进选好友页」，正是因为
/// URL 在启动请求里、由 FrontBoard 自己装进新 scene。
@_cdecl("AevonURLLaunchOff")
public func AevonURLLaunchOff() -> Int32 {
    FileManager.default.fileExists(atPath: Aevon.urlLaunchOffPath) ? 1 : 0
}

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
        // 0.3.5 — 用完整格式串，不用 `+` 拼接：拼接出来的东西在产物里
        // 查不到（audit 断言钉的是字面量），而这一行是「这一刀到底成没成」
        // 的唯一证词。
        Log.write(String(format: "presenter: resize ctx cls=%@ read=%@",
                         String(describing: type(of: ctx)), back))
    })
    return 1
}

enum ActivateProbe {

    /// 装上去之后活这么久，就算这个 IMP 本身不是死因。
    ///
    /// 180 秒是权衡，不是证据：一个写错的替换体死在**第一次被调用**上，而
    /// 装完三分钟内正常用机必然会有一次 App 激活。取更长会让「无关的一次
    /// 崩溃」也把这条口子关掉，取更短则可能一次都没验到。
    static let latchSeconds: Double = 180.0

    /// 装载后多久装钩子。2 秒是主屏的存在时间（`RingHost` 用同一个数）。
    static let installDelay: Double = 3.0

    /// 由 `AevonStart` 在 `Gate.evaluate()` 放行之后调用一次。
    static func arm() {
        let manager = FileManager.default

        // 闸四（前半）· 人关的。开关在就一个字节都不碰。
        if manager.fileExists(atPath: Aevon.activateOffPath) {
            Log.write("notify: activate off switch=notify.off")
            return
        }

        // 闸四（后半）· 上一次的闩还在。
        //
        // 0.2.26 — 这里原来一见闩就写 `notify.off`，把「通知/分享改走浮窗」
        // 永久关掉。真机上这不是罕见路径，是必然路径：装完插件要点「重载桌面」，
        // 而重载桌面就是一次新的 SpringBoard 启动；只要它发生在上一次启动后的
        // 180 秒内，新进程就会看见旧闩，于是通知和分享从此全部退回全屏 ——
        // 0.2.25 的日志里那一行 `notify: activate off switch=notify.off` 就是
        // 这么来的，用户从来没手动关过。
        //
        // 现在改成两振出局：第一次看见闩只记一笔并跳过本次装配（给一次干净
        // 启动），第二次启动仍然看见闩才认定「装上去就死」并落开关。一次真正
        // 致命的替换体最多带走两次启动，而一次普通重载再也不会误伤。
        if manager.fileExists(atPath: Aevon.activateArmedPath) {
            try? manager.removeItem(atPath: Aevon.activateArmedPath)
            try? manager.createDirectory(atPath: Aevon.stateDir,
                                         withIntermediateDirectories: true)
            let strikes = (Int((try? String(contentsOfFile: Aevon.activateStrikesPath,
                                             encoding: .utf8)) ?? "") ?? 0) + 1
            try? String(strikes).write(toFile: Aevon.activateStrikesPath,
                                       atomically: true, encoding: .utf8)
            if strikes >= 2 {
                manager.createFile(atPath: Aevon.activateOffPath, contents: Data())
                try? manager.removeItem(atPath: Aevon.activateStrikesPath)
                Log.write("notify: activate latch held twice, notify.off written")
            } else {
                Log.write("notify: activate latch held 1/2, this boot stays native")
            }
            return
        }

        try? manager.createDirectory(atPath: Aevon.stateDir,
                                     withIntermediateDirectories: true)
        try? Aevon.version.write(toFile: Aevon.activateArmedPath,
                                 atomically: true, encoding: .utf8)
        Log.write("notify: activate arm scheduled in \(Int(installDelay))s")

        // 闸六 · 延迟装载。
        DispatchQueue.main.asyncAfter(deadline: .now() + installDelay) {
            AevonActivateProbeInstall()
        }

        // 闸四（收尾）· 松闩。到点还活着，说明装配与这个 IMP 都不致命。
        // 0.2.26 — 同时把「振数」清零：这是唯一能证明正常启动的证据。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + latchSeconds) {
            guard manager.fileExists(atPath: Aevon.activateArmedPath) else { return }
            try? manager.removeItem(atPath: Aevon.activateArmedPath)
            try? manager.removeItem(atPath: Aevon.activateStrikesPath)
            Log.write("notify: activate latch cleared uptime=\(Int(latchSeconds))s")
        }
    }
}
