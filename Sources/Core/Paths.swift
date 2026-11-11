//
//  Paths.swift — Aevon
//
//  Compiled into BOTH binaries (SpringBoard tweak + Settings bundle), so the
//  two processes can never disagree about where things live.
//
//  Rules for this file:
//    · Foundation only — no UIKit, no private API.
//    · Every path is absolute and written once, here.
//

import Foundation

public enum Aevon {

    /// Must equal control:Version and the bundle's CFBundleShortVersionString.
    /// The CI preflight fails the build when the three drift apart.
    public static let version = "0.3.42"

    /// Preferences domain. Deliberately independent of the package name:
    /// renaming the package must never lose the operator's gate state.
    public static let domain = "com.aevon"

    /// The one log file the operator is told to look at.
    public static let logPath = "/var/mobile/Aevon.log"

    /// Gate state. NOT under Library/Preferences: a roothide jailbreak
    /// redirects that path per process, so SpringBoard and Settings would
    /// read different copies of the same file.
    public static let stateDir  = "/var/mobile/Library/Logs/Aevon"
    public static let statePath = "/var/mobile/Library/Logs/Aevon/state.plist"
    public static let panicPath = "/var/mobile/Library/Logs/Aevon/panic"

    /// The carrier-shape values, mirrored out of the preferences domain.
    ///
    /// Why a file as well as the domain: on roothide, Library/Preferences is
    /// redirected per process, so Settings and SpringBoard can read two
    /// different copies of "Radius". This path is plain and shared, the same
    /// reason state.plist lives here. Settings writes it on every change,
    /// SpringBoard reads it on every notification.
    public static let ringPath = "/var/mobile/Library/Logs/Aevon/ring.plist"

    /// The operator's own icon list, in their own order. Settings writes it,
    /// SpringBoard reads it. Empty file = "no choice made yet", and the ring
    /// falls back to the automatic list instead of showing nothing.
    public static let appsPath = "/var/mobile/Library/Logs/Aevon/apps.plist"

    /// 0.0.44 — 谁正在被浮窗承载。
    ///
    /// The card's app needs to know one thing no app can learn on its own: that
    /// another process is showing its scene. Scene settings are supposed to say
    /// so and may not arrive in the app's own copy, so the host writes this file
    /// as well; the AevonApp injection (Sources/App/AevonAppHook.m) reads it and
    /// stops reporting "background" to UIKit. Absent file = nobody is hosted.
    public static let hostedPath = "/var/mobile/Library/Logs/Aevon/hosted.plist"

    /// 0.0.39 — where the floating card sits, and how big it is.
    ///
    /// The master keeps this as five values inside `EgdeGestureView` /
    /// `SettingEnv`, not as one frame: `_leftPecent` `_rightPecent`
    /// `_leftHeightPecent` `_rightHeightPecent` and `_edgeWidth`. Two sets, one
    /// per edge, because a card docked on the left and the same card docked on
    /// the right are two different placements and the operator expects each to
    /// come back the way it was left. A stored CGRect cannot express that: it
    /// holds one position for a screen that has two.
    public static let cardPath = "/var/mobile/Library/Logs/Aevon/card.plist"

    /// A request, not a setting: Settings drops this file and posts the prefs
    /// note; SpringBoard deletes it and writes the scene dump to the log. A
    /// file rather than a preference because the two processes disagree about
    /// where the domain lives on roothide, and because "one shot" is exactly
    /// what a file is.
    public static let probePath = "/var/mobile/Library/Logs/Aevon/probe.request"

    /// 0.2.91 — 「上一次死在哪一步」。
    ///
    /// 两份都是**进程被信号带走时才会留在盘上**的标记：正常走完就自己删掉。
    /// 所以开机看到这两行，说明上一次运行没走完，而后面的名字就是断点。
    ///
    /// `last.step` 由 URL 落点那条路写（`url:enter` / `url:target` / `url:branch` /
    /// `url:forward` / `url:rescue`）；`act.step` 由激活探针写，只用在一个会
    /// 解引用私有结构的地方（`_Block_signature`）。Aevon(223) 那三次连崩之所以
    /// 一行线索都没留下，就是因为那一下死在写日志之前。
    public static let urlStepPath = "/var/mobile/Library/Logs/Aevon/last.step"
    public static let actStepPath = "/var/mobile/Library/Logs/Aevon/act.step"


    /// 承载层普查跑过没有。内容是这个包的版本号：装新版本会重跑一份，
    /// 单纯重启不会 —— 普查是只读的，但它没有理由在每次开机都占一行日志。
    /// 0.2.80 起，这一份是「Stheno 的 presenter 路能不能走」在真机上的唯一证词。
    public static let presenterStampPath = "/var/mobile/Library/Logs/Aevon/presenter.stamp"

    /// 普查正走到哪个类。写法与 `winStepPath` 同一条纪律：凡是有可能带走进程的
    /// 调用，调用前先把名字落盘 —— 一个只读普查理论上不该崩，但「理论上」不值钱，
    /// 上次 SpringBoard 安全模式就是拿「理论上」换来的。跑完即删。
    public static let presenterStepPath = "/var/mobile/Library/Logs/Aevon/presenter.step"

    /// 0.2.83 — 普查自己的一份账，和 Aevon.log 分开。
    ///
    /// 为什么非分不可：0.2.82 那一轮普查的产出**被装包动作吃掉了**。
    /// `postinst` 从 0.2.21 起就把 `/var/mobile/Aevon.log` 截断（省得每次进
    /// Filza 手动删），而普查是「一个版本只跑一次」；于是「跑过 → 装包清日志
    /// → 重启看到 skip」这条路上，数据在写出来的那一秒就已经注定读不到。
    /// Aevon(214) 正是这一格：13:09:25 的 `census skip version=0.2.82` 说明
    /// 上一次真跑过，而日志从 13:09:23 才开始 —— 前半段不存在了。
    ///
    /// 一份独立文件还有第二个好处：追加、不清空，多次普查可以并排读。
    public static let presenterCensusPath = "/var/mobile/Library/Logs/Aevon/presenter.census"

    /// 手写这个文件 = 下一次开机**无视**版本标记再跑一遍普查，跑完自己删掉。
    /// 存在的理由：普查一旦被任何东西吃掉，重来一次不该再烧一个构建。
    public static let presenterForcePath = "/var/mobile/Library/Logs/Aevon/presenter.force"

    /// The class a scan was looking at when the process stopped. Written before
    /// each class is touched, so it is the one witness that survives a SIGKILL —
    /// a signal handler cannot, and a jetsam kill and one poisonous class leave
    /// the same log otherwise. Raw bytes on purpose (4-byte index + name): a
    /// million writes are cheap, and this runs once per class.
    public static let callStatePath = "/var/mobile/Library/Logs/Aevon/call.state"

    /// Classes that already killed a scan, one per line. Read at the start of
    /// every scan and written at boot from `callStatePath`: a probe that walks
    /// straight back into a class that took SpringBoard down teaches nothing.
    public static let callSkipPath = "/var/mobile/Library/Logs/Aevon/call.skip"

    /// The signal that ended the last walk, four raw bytes, written from the
    /// handler itself. Everything else about these runs is inference: a bad
    /// class, a jetsam kill and a watchdog kill all leave the log ending mid
    /// sentence. A signal number separates the first from the other two, and a
    /// missing file says the process was killed rather than faulted.
    public static let callFaultPath = "/var/mobile/Library/Logs/Aevon/call.fault"

    /// The window probe's own step marker, one short name per line, rewritten
    /// before every call that could take SpringBoard down and deleted once the
    /// call returns. SpringBoard has now died twice on a call we chose from a
    /// string table — 0.0.15 inside `_createSceneWithDefinition:`, 0.0.16 right
    /// after `presentationView`. Both times the log ended between two lines and
    /// the culprit had to be inferred. With this file the next boot says it.
    public static let winStepPath = "/var/mobile/Library/Logs/Aevon/win.step"

    /// 0.0.21 — the latch a hook leaves behind, and the reason 0.0.20 cannot
    /// happen twice. Written *before* an IMP is replaced and deleted only after
    /// every one of them is put back. If it is still on disk at the next
    /// request, the last run either died inside the hook or was killed with it
    /// installed, and the answer is to not install it again — a hook that
    /// survives its own run is the one failure mode a crash counter cannot see,
    /// because nothing crashed. 0.0.20 left three live scenes' presenters
    /// activated with no way back and the phone went black while SpringBoard
    /// kept answering heartbeats.

    /// 0.1.85 — 通知点击观察器的两道闩。
    ///
    /// `armed` 在装配**之前**写、活到 180 秒才摘。它还在 = 上一次装上去之后
    /// 没活到摘闩，那一次 SpringBoard 的死因不必再猜：就是这条钩子。
    ///
    /// `off` 是那个结论的落点，也是操作者的手动开关。它存在时一个字节都不碰；
    /// 自动落下之后要重新取证，删掉这个文件再重启即可。用文件而不是偏好域，
    /// 理由与 `state.plist` 相同：roothide 会按进程重定向 Library/Preferences，
    /// 而这个判断必须在任何进程里都读到同一份。
    public static let activateArmedPath = "/var/mobile/Library/Logs/Aevon/notify.armed"
    public static let activateOffPath   = "/var/mobile/Library/Logs/Aevon/notify.off"
    /// 0.2.26 — 连续几次启动看见旧闩。`1` 只跳过一次装配，`2` 才落 `notify.off`；
    /// 普通重载桌面也会留下旧闩，一振就关会把这个功能永久误伤（0.2.25 的真机日志）。
    public static let activateStrikesPath = "/var/mobile/Library/Logs/Aevon/notify.strikes"

    /// 0.1.92 — 分享面板那条路自己的开关。与 `notify.off` 分开是因为两者风险不同：
    /// 「分享文件给别的 App」带交接，出问题时往往只是「打开是空的」，而通知那条是
    /// 「点了没反应」；把两条路绑在一个开关上，想收一条就得把另一条也关掉。
    /// **`notify.off` 仍然是总闸**：两个任一存在，分享一律不接管。
    public static let shareOffPath      = "/var/mobile/Library/Logs/Aevon/share.off"

    /// 0.3.20 — 「出生即卡尺寸」这条写路的独立开关。
    ///
    /// 语义与前两个不同：`notify.off` / `share.off` 关的是**接管**，这一位关的是
    /// **写 scene 参数**。它是整个工程里唯一一处「在建 scene 之前改系统参数」的地方，
    /// 出事就是黑屏 / 安全模式（0.2.92 那次就是往不可变 settings 写 frame）。
    ///
    /// 所以它默认**不存在 = 允许写**，但操作者一旦建了它，`AevonActFrameBirth`
    /// 立刻一个字节都不写，只保留只读读数。取证阶段把这一位建上，就能在不改行为的
    /// 前提下看清「门槛过不过、副本拿不拿得到」。
    public static let birthOffPath      = "/var/mobile/Library/Logs/Aevon/birth.off"

    /// 0.3.22 — 开机全量普查的「已经查过」标记（内容是查过的那一版版本号）。
    ///
    /// 0.3.21 的 Aevon(247) 有 1869 行，其中 890 行是 `carrier:` / `presenter:` 两轮
    /// 普查 —— 每次重启都把 99307 个类扫一遍、把结果重打一遍。名字第一次查出来是
    /// 情报，第六十次查出来就是噪声：真机排障的时候，真正要看的那几行（`act: frame
    /// birth`、`win: state hosting`）被埋在一千行类名方法名中间。
    ///
    /// 语义：**同一版只查一次**。内容等于当前版本号就整个跳过，只留一行
    /// `presenter: census skip`；版本一变自动重查（新版本可能有新类名要看）。
    public static let censusDonePath    = "/var/mobile/Library/Logs/Aevon/census.done"
    /// 想再查一遍（不改版本号）就手写这个文件：存在即强制查，查完自己删。
    public static let censusForcePath   = "/var/mobile/Library/Logs/Aevon/census.force"

    /// 0.3.23 — URL / 分享激活时「真的写出生尺寸」的开关。
    ///
    /// 0.3.21 证明 `frame birth` 在圆盘那条路上真能写进去（`wrote-copy`，两张卡
    /// 都上屏）；但 URL 那条路从来没接过扳机 —— Aevon(248) 里 QQ 分享那次
    /// `act: activate ... payload=1` 到 `act: scene id=sceneID:com.tencent.mqq-default`
    /// 只隔 39 ms，中间没有任何 `act: arm`，于是 QQ 照旧整屏。
    ///
    /// 写 scene 参数是全工程唯一一处「在建 scene 之前改系统参数」的地方，URL 这条
    /// 路上还多一个没人验过的风险：**系统激活事务会不会在出生尺寸之后又把 scene
    /// 摆回整屏**。所以这一版默认**不写**，只干跑（`act: frame birth dry=1`，
    /// 记下「本来要写成什么、走的是副本还是直写」）。看完那一行确认门槛都过，
    /// 手写 `touch …/url.write` 再测一次，不用换包。
    public static let urlWritePath      = "/var/mobile/Library/Logs/Aevon/url.write"

    /// 0.3.24 — URL / 分享路「把 scene 收进卡」的**关**闸。
    ///
    /// Aevon(250) 给出了这个项目的关键读数：`url.write` 打开后，QQ 的 scene 真的
    /// 变成了 430×717（`act: frame birth wrote=1 … after=430x717 by=wrote-copy`），
    /// 系统也接受了，没有回弹成 932 —— 但屏幕上看到的是「像全屏又不是全屏，
    /// 下半屏是黑的」。原因很直接：scene 缩了，**装它的那个窗口没缩**。那个
    /// 430×932 的窗口是 FrontBoard 为「全屏激活」发的，我们的卡从头到尾没有出现
    /// （整份日志里 `win:` 那一段在 14:55 期间一行都没有）。
    ///
    /// 所以这一版补的是「承载」：分享激活之后延迟一次 `openCard`，让 QQ 的 scene
    /// 挂到我们自己的卡窗口上。既然 0.3.8 以来第一次真的要动 URL 路的窗口，
    /// 就留一个反向闸：这个文件在 ⇒ 只落一行 `act: url card skip`，不开卡，
    /// 行为退回 0.3.23。语义与 `birth.off` / `notify.off` 一致：**存在即不做**。
    public static let urlCardOffPath   = "/var/mobile/Library/Logs/Aevon/url.card.off"

    /// 0.3.26 — **在激活那一拍答「不开」**的总闸（`url.deny.off` 存在 = 不拒答）。
    ///
    /// 0.3.8 之后所有版本（含 0.3.21–0.3.25）都是在系统已经答了「开」之后再去改：
    /// 改 scene 尺寸、建卡、发 Home。全屏那一帧来自 FrontBoard 提交激活时建的那个
    /// 窗口，**它在我们的代码跑起来之前就存在**，所以撤销永远看得见 —— 0.3.21 已经
    /// 是这条路能写的最早一拍（scene 出生），它仍然看得见。
    ///
    /// 0.3.26 换了问法：不让系统提交。在 `_activateBundleID:…withResult:` 里对
    /// 「分享型」激活（带 `__PayloadURL` + `__PasteSharingToken`）**不调原函数**，
    /// 于是没有激活事务 ⇒ 没有全屏窗口 ⇒ 那一帧在原理上不存在。
    ///
    /// 反悔只需一个空文件：`touch …/url.deny.off` 再重启桌面，行为退回 0.3.25。
    /// 语义与 `birth.off` 一致：**存在即不做**。
    public static let urlDenyOffPath   = "/var/mobile/Library/Logs/Aevon/url.deny.off"

    /// 0.3.33 — **URL 接管范围**的关闸（`url.global.off` 存在 = 只接分享）。
    ///
    /// 0.3.26–0.3.32 的拒答只认「分享型」（带 `__PasteSharingToken` 的那一类）。
    /// Aevon(257) 里 QQ 冷热两次分享都进了选好友页，但其他 App 的分享、以及点链接
    /// 跳转 / 授权回跳 / 支付回跳全都还是全屏 —— 它们落在 `shareKind == 1` 上。
    ///
    /// 0.3.33 默认把这四类全接（边界由 `AevonURLWorthDeny` 划：电话/短信/设置/
    /// App Store 这些系统必须自己处理的 scheme 一律放行）。这个闸是**一键退回**：
    /// `touch …/url.global.off` + 重启桌面，行为立刻回到「只有分享进浮窗」。
    ///
    /// 语义与其它闸一致：**存在即不做**。
    public static let urlGlobalOffPath = "/var/mobile/Library/Logs/Aevon/url.global.off"

    /// 0.3.26 — 卡片起来之后「把 URL 补投一次」的关闸（存在 = 不投）。
    ///
    /// 拒答之后 QQ 的进程由我们自己的挂起启动拉起（`AevonLaunchSuspended`，
    /// 圆盘那条路一直在用），scene 进我们的卡 —— 但 **URL 没有跟着进去**，
    /// 所以它可能停在 QQ 首页而不是分享页。这一位负责在卡上屏之后补投一次。
    ///
    /// 补投本身可能触发一次新的激活（那就又是全屏）。所以：补投窗口内来的
    /// 那一次激活我们**放行一次**（`act: pass why=redeliver`），避免自锁打转；
    /// 如果日志里看到放行之后整屏又出现了，`touch …/url.redeliver.off` 去掉补投。
    public static let urlRedeliverOffPath = "/var/mobile/Library/Logs/Aevon/url.redeliver.off"

    /// 0.3.27 — 补投的**软**路径开关：`openSensitiveURL:`。
    ///
    /// 默认不存在 = 不走。原因在 Aevon(2) 那份日志里：0.3.26 的补投虽然因为
    /// 读错类型（`__PayloadURL` 是 `NSURL`，不是 `NSString`）没投出去，但它要走的
    /// 正是这条路 —— 而这条路会再触发一次 `_activateBundleID`，也就是再提交一次
    /// 激活事务，把 0.3.26 刚刚拆掉的那扇 430×932 全屏窗装回去。
    ///
    /// 所以主路换成「scene action」（无事务、无窗口），软路径只在硬路径明确
    /// 不可用时、且用户手建本文件之后才跑。
    public static let urlRedeliverSoftPath = "/var/mobile/Library/Logs/Aevon/url.redeliver.soft"

    /// 0.3.29 — 冷启动「补发」的关闸（`url.shot.off` 存在 = 只投一发）。
    ///
    /// Aevon(252) 定了两件事：后续几次分享真的进了选好友页（`has=1/1`，构造器对了），
    /// 但每一次都要等 3 s —— 那 3 s 是 0.3.26 排的固定 2.6 s 定时器，不是 QQ 慢；
    /// 而第一次分享停在首页是因为 QQ 那次是冷启动（`app: boot pid=50788` 在
    /// 我们投递的前 2 s），首页恢复把分享页盖掉了。
    ///
    /// 所以这一版把投递改成「scene 一挂上就投」，并对冷启动多发两发（间隔 1.2 s）。
    /// 多发的代价是可能叠出第二个分享面板，所以留一个随时能关的空文件：
    /// 建了它 ⇒ 冷启动也只投一发，行为退回 0.3.28（除了不再等 3 s）。
    public static let urlShotOffPath     = "/var/mobile/Library/Logs/Aevon/url.shot.off"

    /// 0.3.30 — 「把 URL 装进新 scene 的 transitionContext」的关闸
    /// （`url.tctx.off` 存在 = 不装，退回 0.3.29 的 scene action）。
    ///
    /// Aevon(253) 把冷/热这件事说清楚了：热启动「秒出选好友页」，冷启动连发三发
    /// （贯穿整个启动过程）一发都不认。差别不在时间，在**投递口** —— 原生 URL
    /// 激活是把 `UIOpenURLAction` 装进新 scene 的 transitionContext 交给 App 的
    /// （0.3.23 在 QQ 分享那次的 `createScene` 里亲眼看到 `n=1`），而 0.3.26 把
    /// 那次激活拒掉了，所以那个「装好 URL 的 tctx」从来没被造出来。
    ///
    /// 这一版在 `createScene` 那一拍把同一个类、同一个容器、同一个 `setActions:`
    /// 补上。装成功就**不再**走 scene action（`act: deliver skip why=tctx`）。
    /// 出问题建这个空文件即可退回 0.3.29 的行为，不必换包。
    public static let urlTctxOffPath     = "/var/mobile/Library/Logs/Aevon/url.tctx.off"

    /// 0.3.35 — **授权 / 支付那两族要不要接**（`url.act.on` 存在 = 才接，默认不接）。
    ///
    /// Aevon(259) 的两条现场是同一个形状：`act: activate … payload=0
    /// k=__Actions|__PayloadOptions|…`，落点侧 `act=#UIActivityContinuationAction
    /// url=-`。也就是说这两族跳转被系统包成了「活动继续」，URL 不在 `__PayloadURL`
    /// 上，要翻 `__Actions` 里那个 `NSUserActivity` 的 `webpageURL`。
    ///
    /// 0.3.35 只把 URL 挖出来记一行（`act: url dig hit`），**不接管**：授权/支付
    /// 接错的代价是「登录点不动、支付跳不了」，比「又是全屏」严重得多。等这一版
    /// 日志确认了 URL 的形状，手建这个文件 + 重启桌面，这两族才进入接管范围。
    ///
    /// 语义与 `url.global.off` 相反：**存在才做**。
    public static let urlActOnPath       = "/var/mobile/Library/Logs/Aevon/url.act.on"

    /// 0.3.36 — **放行式接管**的关闸（存在 = 回到「吞掉 + 自己投」的 0.3.35 行为）。
    ///
    /// Aevon(260) 把「自己投」这条路彻底判死了：四次冷启动分享，每次都是
    /// 3 发 scene action + 1 发 5.0 s 晚发（`deliver late r=1 age=5156`，
    /// 落在 QQ 自己 `geom late` 之后），`sendActions` 全部 `ok=1`，
    /// QQ 四次全停首页。也就是说这不是时机问题 —— 是我们造的 action
    /// （`initWithURL:openURLOptions:nil workspaceOriginatingProcess:nil responder:nil`）
    /// 冷启动那条路根本不认。
    ///
    /// 剩下唯一没试过的、也是系统自己的路：**别吞**。让 `_openURLCore` 原样放行，
    /// URL 由 FrontBoard 自己写进新 scene 的 connection options —— 那正是「原生分享」
    /// 的定义。我们要的浮窗由 `createScene` 改初始 frame + 事后把 scene 搬进
    /// presenter 保证，与这条 URL 通道互不相干。
    public static let urlSwallowOnPath   = "/var/mobile/Library/Logs/Aevon/url.swallow.on"

    /// 0.3.36 — 「活动继续」（`UIActivityContinuationAction`）这一族要不要接管。
    ///
    /// Aevon(259)/(260) 的授权与支付两次激活都是 `payload=0` + 落点侧
    /// `act=#UIActivityContinuationAction` + `url=-`：URL 根本不在 payload 上，
    /// 被系统包成一次「继续某个 activity」。0.3.35 的 `act: url dig` 翻了
    /// `__Actions` 也没挖到（`dig miss … shape=UIActivityContinuationAction`）。
    ///
    /// 挖不到 URL 不等于接管不了：bundle id 是现成的，而放行式接管**不需要**
    /// URL —— 系统自己会把它送进 App。所以这一族也按放行接管处理，代价为零。
    /// 建 `url.activity.off` 可以把这一族退回去（继续全屏）。
    public static let urlActivityOffPath = "/var/mobile/Library/Logs/Aevon/url.activity.off"

    /// 0.3.37 — **放行式接管的开闸**（存在 = 回到 0.3.36 的「放行 + 抢 scene」）。
    ///
    /// 0.3.36 让放行成为默认，Aevon(262) 当场复现了 0.3.25 的形状：
    /// `act: float sw=0` → `act: float card` → 系统那份全屏窗被抽空 → 黑。
    /// 原因不新：**放行 = 系统提交自己的全屏激活事务**，我们再 150 ms 后
    /// 把 scene 搬进卡，等于对已提交的事务做撤销；撤销看得见，就是那一帧黑。
    ///
    /// 所以默认回到「吞掉」：不提交，就没有全屏窗可撤。吞掉之后 URL 由
    /// transitionContext 那一份交给 App（0.3.32 冷启动能出分享页的正是这条路）。
    /// 要复现 0.3.36 的放行形状时手建这个文件，不必换包。
    public static let urlPassOnPath      = "/var/mobile/Library/Logs/Aevon/url.pass.on"

    /// 0.3.37 — **tctx 装上之后还补不补发**（存在 = 回到 0.3.34 的 2.2 s + 5 s 补发）。
    ///
    /// Aevon(257)（0.3.32）冷启动能出分享页，Aevon(259)（0.3.34）不能，
    /// 两次的 `tctx put ok=1 had=0` 一模一样；唯一差别是 0.3.34 去掉了
    /// 「tctx 成功就收手」，2.2 s 后又发了 `sendActions:`。那几发之后 QQ 回首页。
    /// 也就是说冷启动那一份 action 送第二次不是「加固」，是**把已有的一次打开
    /// 再打开一次**，App 用首页响应第二次。
    ///
    /// 默认不再补发（= 0.3.32 的形状）。要再做「补发是否无害」的实验时建这个文件。
    public static let urlPlusOnPath      = "/var/mobile/Library/Logs/Aevon/url.plus.on"

    /// 0.3.38 — **冷启动的投递口**：存在 = 不用进程内桥，退回 transitionContext。
    ///
    /// 默认用桥。依据是 Aevon(263)：同一份日志里冷启动两次都是
    /// `tctx put ok=1 had=0` + 卡片 108 ms 出帧 + QQ 停首页，热启动两次
    /// `deliver ok=1 send=sendActions` 秒进选好友页；Aevon(259)（0.3.34）
    /// 冷启动在 tctx 之后补的三发 scene action（第 3/4/5 发全在首帧之后）
    /// 同样无效。两条事后投递在冷启动上都被判死 ⇒ 换第三条：
    /// 写目标 App 容器的 `tmp/aevon-open.plist` + Darwin 通知，由 App 进程里
    /// 那支 dylib 直接调 `scene:openURLContexts:` / `application:openURL:options:`。
    /// 那条桥 0.2.x 就在真机上双向验过（回执 `ok=1 via=app`）。
    public static let urlBridgeOffPath   = "/var/mobile/Library/Logs/Aevon/url.bridge.off"

    /// 0.3.31 — 「带着 URL 的挂起启动」的关闸（存在 = 不带走 URL，退回 0.3.30）。
    ///
    /// Aevon(254) 把前两条投递口都判完了：0.3.29 的三发 scene action 全部落在
    /// 启动窗口里（`deny 02` → `boot 03` → 三发 `03/04/06`、`geom late 06`），
    /// 0.3.30 的 tctx 注入在 QQ 那张 scene 出生那一拍装上了（`put ok=1 had=0`），
    /// QQ 照样停首页。也就是说**我们装的那份它不认**。
    ///
    /// 剩下唯一和原生分享完全同形的做法，是把 URL 交给启动请求本身
    /// （`SBSLaunchApplicationWithIdentifierAndURL[AndLaunchOptions]`）：
    /// action 由 FrontBoard 自己装进新 scene，我们一份都不碰。成功之后补投与
    /// tctx 注入都会自动让路（`act: deliver skip why=launch`）。
    public static let urlLaunchOffPath   = "/var/mobile/Library/Logs/Aevon/url.launch.off"

    /// Pre-0.0.3 locations. Read on upgrade so a stop stays a stop.
    public static let legacyDomain    = "com.aevon.aevon"
    public static let legacyStatePath = "/var/mobile/Library/Preferences/com.aevon.state.plist"
    public static let legacyPanicPath = "/var/mobile/Library/Preferences/com.aevon.panic"

    /// Darwin notifications — the only channel from Settings into SpringBoard.
    /// One notification, verb in preferences: a dropped notification then
    /// cannot silently swallow a respring, and the callback never has to
    /// parse the notification name.
    public static let noteCommand    = "com.aevon.command"
    public static let commandRespring = "respring"
    public static let commandReset    = "reset"

    /// "A setting changed, re-read it." Sent after every write from Settings,
    /// and also posted by the tweak so a second Settings window stays honest.
    /// The payload is not in the notification: whoever receives it reads the
    /// snapshot file, which is written *before* this is posted.
    public static let notePrefs      = "com.aevon.prefs"

    /// 0.2.75 — 「安全闸动了，立刻复查」。
    ///
    /// 为什么不能复用上面两条：`noteCommand` 的回调第一句就是
    /// `takePendingCommand()`，没有挂起命令就直接返回；`notePrefs` 的回调只刷
    /// 圆盘与探针，从来不问闸。两道闸是「现在就必须停手」的语义，值一次单独的
    /// 通道，读的是同一个 `Gate.refreshRuntime()`。
    ///
    /// Aevon(207) 的现场：`22:07:17 settings: G0 emergency stop -> on` 之后
    /// `win: touch in=` 照常计数、`ring:` 照常响应 —— 开关确实写进了偏好域，但
    /// SpringBoard 这一侧从头到尾没收到过任何通知，而闸本身又只在加载时判定
    /// 一次。两道保险同时失效，用户看到的就是「闸门都无法制止」。
    public static let noteGate       = "com.aevon.gate"
}

// MARK: - Darwin notifications

// notify.h is not part of the Swift Darwin overlay; declare the one symbol we
// use instead of pulling a bridging header into the tweak target.
@_silgen_name("notify_post")
func aevonNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

public func notifyPost(_ name: String) {
    _ = name.withCString { aevonNotifyPost($0) }
}

// MARK: - Jailbreak root

/// roothide keeps its bootstrap in a randomised directory:
///   /var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX
/// rootless keeps it at /var/jb. Neither is hardcoded: look once, cache.
public enum JailbreakRoot {
    public static let path: String? = {
        let base = "/var/containers/Bundle/Application"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for name in names.sorted() where name.hasPrefix(".jbroot-") {
                return base + "/" + name
            }
        }
        if FileManager.default.fileExists(atPath: "/var/jb") { return "/var/jb" }
        return nil
    }()
}

// MARK: - Process spawning

public enum Spawn {

    /// Runs one argv with posix_spawn. Returns false when the binary is
    /// missing or the sandbox refuses the exec — never throws, never loops.
    @discardableResult
    public static func run(_ argv: [String]) -> Bool {
        guard let path = argv.first, !path.isEmpty else { return false }
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }

        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                if let pointer = pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
        }

        var pid = pid_t(0)
        let result: Int32 = pointers.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return posix_spawn(&pid, path, nil, nil,
                               UnsafeMutablePointer(mutating: base), environ)
        }
        return result == 0
    }

    /// Bootstrap helpers first: on roothide they are the real ones.
    public static var respringCommands: [[String]] {
        var out: [[String]] = []
        if let root = JailbreakRoot.path {
            out.append([root + "/usr/bin/sbreload"])
            out.append([root + "/usr/bin/killall", "-9", "SpringBoard"])
        }
        out.append(["/usr/bin/sbreload"])
        out.append(["/usr/bin/killall", "-9", "SpringBoard"])
        return out
    }

    /// True when one of the candidates actually started.
    @discardableResult
    public static func respring() -> Bool {
        for command in respringCommands {
            if run(command) { return true }
        }
        return false
    }
}
