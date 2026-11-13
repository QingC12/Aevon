//
//  SceneProbe.swift — 场景与悬浮窗的落地实现（图标 / 圆盘 → 卡片）。
//
//  0.4.0 — 这个文件以前叫「P0 探针」：除了建卡那条链，它还带一整套只读取证
//  （类与选择子普查、调用表、载体面、presenter 普查、窗口树 dump）。那些代码
//  的真正用途是回答「URL 能不能投进卡片」，而那件事在本版整体下线了，所以
//  探针连同它的字符串表一起删掉 —— 这里只留跑在生产链上的四件事：
//
//    · 图标 / 圆盘 → 悬浮窗（`openCard` … `float`）
//    · 卡片存活期（心跳、保活、复活、首帧、收卡）
//    · 安全闸的运行期快照（`gateSnapshot`）
//    · 上一次运行死在哪一步（`reportPreviousDeath`）
//
//  Rules kept on purpose:
//    · never invoke an unknown selector — only responds(to:) is asked
//    · never create a scene, never touch a scene's settings
//    · every log line is at least 16 bytes so it survives the strip (see
//      tools/push-gate.py: Swift encodes shorter literals as immediates)
//

import Foundation
import UIKit
import ObjectiveC

enum SceneProbe {

    // 0.4.0 — 这一栏原来是一张 120 条的 `callSelectors` 清单加一整套普查
    // （类/选择子/调用表/载体面/presenter），随 URL 链一起删掉了。

    /// 0.2.75 — 闸关那一刻的现场快照。
    ///
    /// 为什么单独留一份：用户报「闸门无法制止」时，日志能证明的只有「我们还在
    /// 吞触摸」（`win: touch in=17 eat=3`），证明不了「停手之后屏上还剩什么」。
    /// 这一行加上随后那份窗口计数，下次就能一眼分清「闸是真的停干净了」和
    /// 「闸只停了触摸、窗口还盖着」—— 这两件事在用户感受上完全不一样。
    ///
    /// 只读：不实例化未知类、不改任何 scene 的 settings、不开窗。
    static func gateSnapshot(why: String, cards: Int) {
        guard let application = sharedApplication() else {
            Log.write("probe: gate snapshot why=" + why + " no app in this process")
            return
        }
        var windowScenes = 0
        var active = 0
        var windows = 0
        for scene in application.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScenes += 1
            if scene.activationState == .foregroundActive { active += 1 }
            windows += windowScene.windows.count
        }
        // 两次拼接而不是一次长的：这一整个文件的教训是类型检查超时，
        // 0.2.57 与 0.0.30 各丢过一次构建（见 `runTail` 上面那段注释）。
        let live = " cards=" + String(cards)
            + " wscene=" + String(windowScenes)
            + " active=" + String(active)
        let rest = " windows=" + String(windows)
            + " ring=" + (RingHost.shared.isEnabled ? "up" : "down")
        Log.write("probe: gate snapshot why=" + why + live + rest)
    }

    /// 0.0.33 — whether a card is on screen right now. The hook has to stay
    /// armed for as long as one is: a disarmed hook lets the system put the
    /// scene back to sleep underneath a card that is still showing it, which is
    /// the black card of 0.0.28 arriving by a different road.
    private static var cardUp = false


    // MARK: - 0.0.38 图标 → 悬浮窗

    /// Where the ring's icon ends up. One tap, no Settings, no six second wait,
    /// and no swipe to the desktop.
    ///
    /// The manual flow is slow for a reason that is not a bug: the card is only
    /// built once the app has *left* the screen, because a scene's layers can
    /// only be hosted by one container at a time (0.0.24—0.0.26 took them while
    /// the app was full screen and the phone went black). Her route removes the
    /// departure entirely — `launchApplicationWithIdentifier:suspended:` starts
    /// the app without giving it the screen, so the scene exists, the desktop is
    /// still the backdrop, and the card is the only thing that ever hosts the
    /// layers.
    ///
    /// Everything after the launch is the chain that already works: arm the hold,
    /// wait for the scene to exist, then `float`. `float` pushes the scene to
    /// "in front" on its first beat, which is the same door 0.0.32 proved on a
    /// scene that had genuinely gone to the background.
    ///
    /// `fallback` is called when this route cannot even start: a suspended launch
    /// that never produces a scene would otherwise be a tap that does nothing,
    /// and a dead control on the home screen is worse than a full-screen app.
    static func openCard(_ bundleID: String, homed: Bool = false,
                         fallback: @escaping (String) -> Void) {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("placeholder.") else { return }
        // 0.2.0 — 这条链路的起点时刻。Aevon(168) 的 22:30:26~44 有 18 秒主线程
        // 连续不通（6 条 `win: main stall ~3000ms`），而那一段里同时有三件事在跑：
        // 全屏兜底的 `ring: launch`、等 scene 的 40 ms 轮询、以及建卡里的系统调用。
        // 三个时间戳（本函数的 `wait=`、`t=`、`scene up after`）就是用来把它分开的。
        let openedAt = CFAbsoluteTimeGetCurrent()
        // 0.4.0 — 0.3.36 那道「放行式接管」的令牌门整块删除。
        //
        // 它唯一的写入方是 `_openURLCore` 的放行分支：系统自己会提交这次激活，
        // 所以 `openCard` 要跳过 Home 与挂起启动。这一版没有放行式接管，
        // `AevonPassSkipFlag` 永远是 0 —— 那条路在下面三处留下的 `|| passDoor`
        // 一并去掉，行为回到「按卡片的规矩来」。
        // 0.1.91 — 「这张卡正在建」的登记。必须在**第一个** return 之前：
        // 收面板那条路要用它区分「卡在路上，可以先收」与「根本没有卡，不许收」。
        // 0.4.0 — `AevonCardTargetArm`（「出生即卡尺寸」的窗口扳机）随 URL 落点链删除。
        // 它是 `AevonActFrameBirth` 唯一的调用者，而那个函数只服务「接管一次打开请求
        // 时把新 scene 的初始 frame 直接写成交付尺寸」。这一版不接管任何打开请求，
        // 卡片尺寸走 `AevonWriteFrame` 那条既有写路。
        // 0.1.29 — 圆盘选中的图标**已经在停靠小窗里**：把它升回主悬浮窗，
        // 不要再开一张。
        //
        // 用户原话：「如果圆盘选中的图标已经在停靠小窗中了，那么再次选择圆盘
        // 图标时停靠的小窗应该自动还原成主悬浮窗。」
        //
        // 放在 `if cardUp` 之外是有意的：「主窗关掉了、只剩几张小窗」是常见局面，
        // 那时 `cardUp` 是 false，走旧路会给同一个 App 再开一张卡 —— 屏幕上一大
        // 一小两个同样的 App，正是用户要避免的。升窗这一条路自己会处理「谁给谁
        // 让位」（`performUndock` → `demoteMain(except:)`）。
        if let docked = FloatHost.dockedHost(of: bundleID) {
            Log.write("win: icon " + bundleID + " is docked, promoting it")
            docked.promoteFromRing()
            return
        }
        // 0.0.98 — 已经有主窗时，先把它降级成停靠小窗，再开新的。
        //
        // 0.0.97 及以前这里是 `guard !cardUp else { log("ignored, a card is already
        // up"); return }` —— 用户说的「主悬浮窗打开时，再次通过圆盘选中图标后没有
        // 任何反应」就是这一行。它甚至在日志里承认了自己是故意的，所以四份日志里
        // 这件事长得像「圆盘坏了」。
        //
        // 降级只改几何（缩到边缘），不换宿主、不拆 scene：旧窗的对象还留在它自己
        // 那份 `FloatHost` 上，新的主窗拿到的是另一个空槽。见 `FloatHost.takeMainSlot`。
        if cardUp {
            // 同一个 App 再选一次：不降级也不重开。否则点两下就把它自己挤成小窗。
            if hostedBundle == bundleID || FloatHost.mainBundle == bundleID {
                Log.write("win: icon " + bundleID + " is already the main card, ignored")
                return
            }
            // 0.0.99 — **先问有没有槽，再决定降不降级**。
            //
            // 0.0.98 的顺序是反的，这是 Aevon(87) 那个「第三个 App → 不显示悬浮窗、
            // 只剩白色光晕」的全部原因：两个槽都在用时，`demoteMain()` 先把主窗缩成
            // 小窗，然后 `FloatHost.show` 才发现没槽，于是新窗开不出来、旧窗已经被
            // 缩小，屏幕上只剩停靠小窗和一圈手势环。槽位现在是 11 个，正常用不到
            // 这条；但拒绝必须发生在动手之前，否则下一次槽满还是同一个画面。
            guard FloatHost.hasFreeSlot() else {
                Log.write(String(format: "win: no free slot, %@ declined before demote", bundleID))
                return
            }
            let side = FloatHost.demoteMain()
            if side == "none" {
                // 主窗的宿主已经不在（恰好刚被关掉）：把标志复位，按「没有卡」继续。
                // 不复位的话下面 `FloatHost.show` 会找不到空槽，这一下就真的没反应了。
                Log.write("win: demote found no card, treating as none")
                cardUp = false
                AevonRingGrip.cardUp = false
            } else {
                // 一整条字面量，不拼：`win: demote ` 只有 12 字节，拼接串会被
                // 编译器编成立即数，二进制里 grep 不到 —— 闸门会拦，也确实拦对了。
                Log.write(String(format: "win: demote old=%@ side=%@ new=%@",
                                 hostedBundle ?? "?", side, bundleID))
            }
        }

        // 0.2.32 — 「先回桌面」进门第一拍；0.2.33 收紧成「只有目标就是屏上那个」；
        // 0.2.34 换成 `SBApplication.isFrontmost`；0.2.35 再补一个 scene 自己的读数。
        //
        // 这道门只为解决一件事：目标 App 的 scene 正被全屏页占着，直接搬进卡片
        // 会把全屏页抽空（黑）。目标不是屏上那个时，它要么在后台、要么没起进程，
        // 建卡借的是另一份 scene，一个 home 都不该发（0.2.32 的回归）。
        //
        // 0.2.35 — `isFrontmost` 在真机上答不出来。同机日志里
        // `win: pose … front=-1 bg=-1 run=-1 pid=-2`：`SBApplicationController` 对
        // Sileo 返回 nil，`AevonAppObject` 空手 → 全屏 QQ 选自己也被判成「不是
        // 前台」→ `home first skip` → 卡片搬走正在全屏的那份 scene → 黑屏。
        // 现在两个读数任一为 1 即可：`isFrontmost`（认得出来时最准）或
        // `FBScene.settings.isForeground`（scene 自己报的前台位，系统每次切前台都写，
        // 即 intercept 日志里的 `fg=`）。两个都读不到才按「不是」处理。
        //
        // 位置也从函数入口挪到了这里：上面两段（已在停靠小窗 / 已经是主窗）都直接
        // return，那时目标 App 的 scene 由我们自己的窗口承载、`isForeground` 也是 1，
        // 留在入口会把「点一下已在卡片里的 App」误判成全屏而白发一次 home。
        // 0.3.33 — **判据换成「屏上那个全屏 App 是不是它」。**
        //
        // 0.2.32–0.3.32 用的是「目标 scene 报前台」（`isFrontmost` 或
        // `settings.isForeground`）。但挂起启动出来的 scene 同样报前台 ——
        // Aevon(257) 每一条 `deny card` 后面都紧跟 `win: home first step1 …`，
        // 用户看到的就是「卡出现之前桌面闪一下」，而那一次的目标 App 从头到尾
        // 没占过屏。这一下 Home 是白发的。
        //
        // 真正需要 Home 的只有一种局面：**目标 App 就是屏上那个全屏页**
        // （圆盘在全屏 App 里点它自己）。那时把 scene 搬进卡片会抽空全屏页 ⇒ 黑。
        // 其余局面（来源 App 全屏、目标是另一个 App）都不该动 Home —— 卡片是
        // level 101 的独立窗口，本来就浮得在来源 App 之上，这正是用户要的效果。
        // 0.4.3 — **判过一次就是判过了。**
        //
        // 这一行是「桌面第二页开卡 → 被拽回第一页」的根。
        //
        // 0.4.2 把 `frontSceneBundle()` 改成「SpringBoard 可见 且 没有 App scene
        // 报可见」才认定桌面，于是这里的门判对了 —— Aevon(289) 的
        // `12:34:56 win: home first skip why=front b=com.ss.iphone.ugc.Aweme
        // front=com.apple.springboard` 就是它。但 `homed` 是**入参**，跳过之后
        // 没有任何人把它变成 true，于是 310 / 363 两处照样把 `homed: false`
        // 交给 `pollForScene`，那边的老门（576 行）再判一次 —— 而那时
        // `AevonLaunchSuspended` 已经把 scene 建出来了，`frontSceneBundle()`
        // 这一次答的是目标 App，于是白发一下 `AevonHomeStep(1, nil)`：
        //
        //   12:34:56 win: home first step1 SBUIController single-press-up …
        //   12:34:57 win: home first ready waited=500ms springboard=1 front=-1 …
        //
        // 用户看到的就是「在第二页开卡，桌面自己回到第一页」。
        // 下面所有分支走完都算「home 这件事已经处理过」，所以用一个局部量带下去。
        var homeDone = homed
        if !homed {
            let front = frontSceneBundle()
            if front != bundleID {
                // 屏上不是目标 ⇒ 不需要 Home，但**这件事已经判过了**。
                homeDone = true
                Log.write("win: home first skip why=front b=" + bundleID
                          + " front=" + (front ?? "-"))
            } else {
                // 只有「目标就是屏上那个」才走到这里，它的 scene 一定在手里；
                // 取不到也不影响（下面几个读数各自会答 -1）。
                let target = sceneFor(bundleID)
                let step = AevonHomeStep(1, nil)
                Log.write("win: home first open " + (step ?? "step nil") + " b=" + bundleID)
                var waited = 0
                // 0.3.52 — **这一下有可能按空。**
                //
                // 0.3.51 固定在 2.5 s 之后按 Home，那一次 App 的进场动画早就走完
                // 了，`single-press-up` 一定有人接（Aevon(273) `ready waited=500ms
                // springboard=1`）。0.3.52 把时机提到「目标刚成了屏上那一个」，
                // 正撞在激活过渡里 —— 这一下有可能被系统当成「启动途中」丢掉。
                // 丢掉之后如果没有兜底，1.4 s 一到就会把**还在全屏的那张 scene**
                // 搬进卡（0.2.46 那种「卡浮在黑屏上」的形状）。
                //
                // 所以只在「到点了但目标仍是前台」这一格补按一次，多给 0.5 s。
                // 补按之后仍然不成立就照旧建卡 —— 与改动前完全一致，不会更糟。
                var homeRetried = false
                func afterHome() {
                    let active = AevonSpringboardActive()
                    let fgNow = AevonSceneForeground(target)
                    let frontNow = AevonAppFrontmost(bundleID)
                    // 0.5 s = home 过渡本身走完；1.4 s = 「系统没接这一下」的上限。
                    // 任一读数说明「已经离开全屏」即可；前 0.5 秒照样不建卡 ——
                    // 那正是 0.2.30 修掉黑屏的间隔。
                    if waited >= 28 && frontNow == 1 && !homeRetried {
                        homeRetried = true
                        waited = 18
                        Log.write("win: home first retry why=still-front b=" + bundleID)
                        _ = AevonHomeStep(1, nil)
                    } else if ((active == 1 || fgNow != 1 || frontNow != 1) && waited >= 10) || waited >= 28 {
                        Log.write(String(format: "win: home first open ready waited=%ldms springboard=%ld scene_fg=%ld front=%ld",
                                         waited * 50, Int(active), Int(fgNow), Int(frontNow)))
                        openCard(bundleID, homed: true, fallback: fallback)
                        return
                    }
                    waited += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { afterHome() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { afterHome() }
                return
            }
        }

        // 0.0.50 — 母本的两招，这一条路上一直只有半招。
        //
        // `AevonHookInstall()` 从 0.0.27 起只在 `runWindow()` 里被调过，而那条
        // 路是「手动装钩子 → 6 秒内切回目标 App」的探针流程；从 0.0.38 起真正
        // 在用的是这条路（圆盘图标 → 挂起启动 → 建卡片）。于是 Aevon(48) 的
        // 每一份日志里都是 `hook: live=0 deact_set=0 stripped=0` ——
        // `_setDeactivationReasons:onScene:withSettings:reason:` 这条母本赖以
        // 让被承载的 scene 不睡下去的钩子，在这条路上**从来没装上过**。
        // 0.0.35 的日志证明它在真机上装得上也拦得住（`live=4 deact_set=119
        // stripped=32`），缺的只是这一行调用。
        //
        // 放在启动之前：钩子必须在 scene 出现之前就位，否则第一轮切换就已经
        // 错过了。装不上也不影响开窗 —— 自证失败时它只会往日志写一行。
        emitNotes(AevonHookInstall())
        // 先认人，再拉应用：钩子里判「是不是我这一场」只看这个 id，而 scene
        // 是启动那一瞬才出现的 —— 先装钩子、先报名字，两边都不会抢在前面。
        // 启动失败就撤回，免得留一个没有浮窗的「保活名单」。
        AevonHookArm(bundleID)

        // 0.0.66 — 「旧进程就先杀掉它」那条路撤了（随 0.0.65 的屏幕补丁一起）。
        // 它要读一张名片文件才知道进程新旧，而名片写不进去时判据永远不成立，
        // 后果是**每次开窗先结束那个 App**。旧进程最大的坏处只是这一版的改动
        // 没生效，那是可以容忍的；把 App 弄成打不开是不可容忍的。

        // 0.2.0 — 「挂起启动」这一句也是同步的（它要 FrontBoard 先承认这次打开）。
        // 与 `ring: launch done` 同一个用途：把 3 秒卡顿锁到具体一跳到。`wait=` 是
        // 从 `openCard` 进门算起的全部开销（含钩子装配、AevonHookArm、降级），
        // `t=` 只是这一句本身。
        // 0.2.13 — **换来源**。这是从 0.2.10 一路查下来最后剩下的那一格。
        //
        // 0.2.10 把「QQ 全屏后变黑」定成「那次转发」；0.2.12 把挂起位真的写进
        // `SBActivationSettings`（真机读回 `read=1`）—— QQ 仍然先全屏。两次都
        // 是对的读数、错的位置：**问题不在我们怎么改这次打开，而在我们压根不该
        // 走「打开」这条路**。
        //
        // `launchApplicationWithIdentifier:suspended:` 在 iOS 17 上只负责把进程
        // 拉起来，SpringBoard 照样按「用户点了图标」把 App 摆成前台演一遍全屏
        // 动画；等我们把 scene 贴进卡片，屏幕上剩下的就是那半截黑。
        //
        // 自建 scene 不给它这个机会：自己起进程（launchIntent=4，不进前台）、
        // 自己建 scene、自己在自己的窗口里挂 presenter。屏幕从头到尾只有卡片。
        // 路线来自开源母本 FrontBoardAppLauncher（TrollOpen 致谢里点名的那个），
        // 不是从字符串表里猜的；每一类每一选择子都先经过 `AevonOwnGate` 的问，
        // 整条包在 ObjC 的 `@try` 里 —— 缺一样就退回 0.2.12 那条路，行为一字不改。
        let ownAt = CFAbsoluteTimeGetCurrent()
        // 「已经有一个活 scene」就不自建：那会跟系统自己那个 scene 撞同一个
        // identity（`sceneID:<bundle>-default`）。
        //
        // 0.2.14 — 这一格原来还会落下去走挂起启动，于是 Aevon(183) 的第二次分享
        // （`own start door=-1 live=1` 紧跟着 `icon launch … door=1`）又多了一次
        // 「把 App 摆成前台」的全屏。已经有活 scene 的时候根本没有启动的必要：
        // `sceneFor` 用的就是下面那一步的同一个判据，所以「已经找到」等价于
        // 「下一拍会立刻贴上」。这里直接贴，一个启动请求都不发。
        let alreadyLive = sceneFor(bundleID) != nil
        if alreadyLive {
            Log.write(String(format: "win: own live attach %@ t=%ldms wait=%ldms",
                             bundleID, Int((CFAbsoluteTimeGetCurrent() - ownAt) * 1000),
                             Int((CFAbsoluteTimeGetCurrent() - openedAt) * 1000)))
            mark("OWN-live")
            markHosted(bundleID)
            // 0.2.34 — `homed` 必须一路带下去。0.2.33 在这里丢了它：`openCard`
            // 已经等过一次 home，`pollForScene` 的老门又判一次 scene 可见、
            // 再等 1.4 秒 —— 真机日志里 QQ 那次就是连着两组 `home first …`。
            pollForScene(bundleID, ticks: 0, start: Date(), homed: homeDone,
                         fallback: fallback)
            return
        }
        // ⛔ 0.3.1 — **自建 scene 整条下线。**
        //
        // Aevon(225) 的崩溃报告把它判死了。栈（faultingThread 0）：
        //   libdispatch _dispatch_main_queue_drain
        //   Aevon.dylib +0x5de4
        //   FrontBoard -[FBSceneManager createSceneWithDefinition:initialParameters:]
        //   FrontBoard -[FBSceneWorkspace _createSceneWithDefinition:...]
        //   FrontBoard -[FBScene initWithDefiniton:remnant:settings:...]
        //   FrontBoard -[FBScene _activateWithTransitionContext:error:]
        //   FrontBoard -[FBWorkspace registerHost:settings:...error:]   ← EXC_BREAKPOINT
        //
        // 崩点就是我们自己调 `createSceneWithDefinition:initialParameters:` 那一行。
        // 触发场景是支付宝付完回跳联通 App（`chinaunicom://safepay/...`）：联通当时
        // 没有活 scene（`listed scene all shell n=1 best=0`），于是走了这一格。
        //
        // 另外 0.2.74~0.2.78 早就用真机证伪了这条路的**业务**面（QQ `rsp=0`、
        // 支付宝 `timeout 6342ms`、微信空壳 `cs=0`）：自建 scene 里没有系统那一次
        // 激活，授权/支付 SDK 不认。既然既危险又没用，就不该留。
        //
        // 现在退回「挂起启动 + 等系统 scene」：`launchApplicationWithIdentifier:
        // suspended:` 只把进程拉起来，不给它建 scene 的机会；scene 由系统在真正
        // 激活时造，我们只等、只贴。一个私有构造器都不碰。
        _ = ownAt
        let launchAt = CFAbsoluteTimeGetCurrent()
        // 0.3.33 — **「带 URL 的启动」整条撤掉。**
        //
        // 0.3.31 在主进程里调 `SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions`
        // 直接把 SpringBoard 打进安全模式（两份 .ips 完全一样：`_splitOptions…+64` →
        // `objc_retain` 拿到 0x1）；0.3.32 把同样的调用搬进 fork 出来的孩子进程，
        // Aevon(257) 两个孩子都是 `sig=11` —— fork 之后 objc/CF 的锁与 port 全都
        // 不可用，这条路换任何参数都是同一个段错误，没有第二种结果。
        //
        // 同一份日志也给出了真正生效的那条：`act: tctx put ok=1` 之后 QQ 冷热两次
        // 都真进了选好友页。0.3.30 的 transitionContext 注入一直是对的，只是被
        // 0.3.31/0.3.32 的启动路盖住了。所以现在只有一条启动：纯挂起 + 事后注入。
        //
        // 顺带省下 0.3.32 那两个候选的 fork/等待（冷启动实测快了约 0.7 s）。
        let door = AevonLaunchSuspended(sharedApplication(), bundleID)
        Log.write(String(format: "win: own retired %@ door=%ld t=%ldms wait=%ldms",
                         bundleID, door,
                         Int((CFAbsoluteTimeGetCurrent() - launchAt) * 1000),
                         Int((CFAbsoluteTimeGetCurrent() - openedAt) * 1000)))
        guard door == 1 else {
            AevonHookDisarm(bundleID)
            fallback("own retired door=" + String(door))
            return
        }
        mark("OWN-retired")
        markHosted(bundleID)
        pollForScene(bundleID, ticks: 0, start: Date(), homed: homeDone, fallback: fallback)
    }

    // MARK: - 0.0.44 hosted mark

    /// Who the card is showing. `Aevon.hostedPath` is the copy the app reads;
    /// the static is only here so the log can say whose mark was cleared.
    private static var hostedBundle: String?

    // 0.4.0 — 0.1.91 的「卡在路上」登记（`markPending` / `cardIsComing`）随
    // URL 落点链删除：它唯一的读方是通知中心那套「等卡起来再收面板」，
    // 而通知接管在本版整体下线了。`openCard` 里那次登记调用一并去掉。

    private static func markHosted(_ bundleID: String) {
        hostedBundle = bundleID
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "bundle": bundleID,
            // Reference-date seconds: the same clock the app-side reader compares
            // against, so neither side has to know about 1970.
            "ts": Date().timeIntervalSinceReferenceDate,
        ]
        let ok = (payload as NSDictionary).write(toFile: Aevon.hostedPath, atomically: true)
        Log.write("win: hosted mark " + bundleID + (ok ? "" : " (write failed)"))
    }

    /// 0.0.70 — 把卡里那个 App 自己写下的读数取回来，并进主日志。
    ///
    /// 这一步之前不存在，所以抖音的量尺跑了三轮、改了两次都没成：`fopen`
    /// `/var/mobile/Aevon.log` 在沙盒里必然失败，读数被我们自己丢掉了。
    ///
    /// 0.1.2 — 不再只数行数。Aevon(90) 里抖音自己写了 8 条 `app: hang`
    /// （「我的主线程 2 秒没动了」），宿主每 2 秒把它们读走、数了个 `lines=2`、
    /// 然后丢掉 —— 于是卡死在前 85 秒里，我们这边一条证词都没有，最后靠
    /// 「场景死了」才发现。现在这一趟顺带做三件事：
    ///   · 数 hang 行，把第一条转写成一条 `win:` 行（两条时间轴从此能对齐）；
    ///   · 记下最后一条 `alive` 的时刻（主队列还有没有在跑）；
    ///   · 看见 hang 就排 5 次快照（每 2 秒一次），把宿主侧的现场也留一份。
    /// 只记录，不做任何恢复动作 —— 这一版是在查「为什么会卡」。
    private static var hangLines = 0
    private static var lastAliveAt = Date.distantPast
    private static var snapsLeft = 0

    private static func drainAppLog(_ tag: String, quiet: Bool = false) {
        guard let bundle = hostedBundle else { return }
        let text = AevonDrainAppLogText(bundle, 400) ?? ""
        var lines = 0
        var hangs = 0
        var alive = false
        for row in text.split(separator: "\n") {
            lines += 1
            if row.contains("app: hang step=") {
                hangs += 1
                if hangs == 1 {
                    Log.write("win: app hang echo " + String(row.suffix(160)))
                }
            } else if row.contains("app: page alive") {
                alive = true
            } else if row.contains("probe offmain") || row.contains("probe mode") {
                // 开关到底有没有生效，靠这两行；它们每次只变一次，不会刷屏。
                Log.write("win: app " + String(row))
            }
        }
        // 0.0.91 — 每 2 秒那一趟是常态，没有新行就不出声，否则日志会被
        // 一分钟 30 行「lines=0」灌满。
        if quiet && lines <= 0 { return }
        Log.write("win: app log lines=" + String(lines) + " from " + tag
                  + " file=" + (AevonAppLogPathOf(bundle) ?? "none"))
        if alive { lastAliveAt = Date() }
        guard hangs > 0 else { return }
        hangLines += hangs
        Log.write("win: app hung n=" + String(hangs) + " total=" + String(hangLines)
                  + " silent=" + String(Int(Date().timeIntervalSince(lastAliveAt))) + "s")
        if snapsLeft == 0 {
            snapsLeft = 5
            scheduleHungSnaps(bundle, tag)
        }
    }

    /// 卡死期间的宿主侧现场：每 2 秒一条，5 条为止。
    ///
    /// App 那侧只能证明「它的主线程停了」；「我们这边看着是什么样」一条都没有 ——
    /// Aevon(90) 里唯一的证据是 40 拍一次的 `keepalive`，粒度 8 秒，而且它全程
    /// 显示一切正常。这一组把窗口压到 2 秒，并且和 hang 同一时刻开始。
    private static func scheduleHungSnaps(_ bundle: String, _ tag: String) {
        guard snapsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard snapsLeft > 0 else { return }
            snapsLeft -= 1
            hungSnap(tag, bundle)
            if snapsLeft > 0 { scheduleHungSnaps(bundle, tag) }
        }
    }

    private static func hungSnap(_ tag: String, _ bundle: String) {
        let scene = sceneFor(bundle)
        // 0.1.38 — `contentState` 走整数 ABI，不再走 `perform`。
        //
        // 这一列是「App 看着卡住」的现场，而它自己把 SpringBoard 打死了：
        // `contentState` 返回的是枚举整数，`perform` 把它当对象交回来，Swift
        // 随即 retain 指针 0x2 ⇒ 安全模式。诊断代码绝不允许成为崩溃原因，
        // 所以这里改成按返回类型编码调 IMP；读不到仍是 -1，与「读到 0」分得开。
        let cs = scene.map { integer(of: $0, "contentState") } ?? -1
        let fg = scene.flatMap { value(of: $0, "settings") }
            .map { AevonBoolOf($0, "isForeground") } ?? -1
        Log.write(String(format: "win: hung snap %@ cs=%d fg=%d up=%d",
                         tag, cs, fg, cardUp ? 1 : 0))
    }

    /// 0.0.91 — 被托管的 App 进程死了，卡片只剩外壳（Aevon(80) 与 Aevon(81) 的
    /// 「白色光晕」）。关掉它，0.6 秒后用同一个 bundle 重开一张。
    ///
    /// 120 秒内只允许一次：死因若是内存，重开只会在同一个坑里再死一遍；而
    /// 「每 0.6 秒重开一次」会让整台手机变成幻灯片。宁可让用户手动重开，
    /// 也不能自己变成一个循环。
    private static var lastReviveAt = Date.distantPast

    static func reviveCard(_ bundleID: String) {
        let gap = Date().timeIntervalSince(lastReviveAt)
        guard gap > 120 else {
            Log.write("win: revive suppressed, last one " + String(Int(gap)) + "s ago")
            return
        }
        lastReviveAt = Date()
        Log.write("win: revive bundle=" + bundleID + " after 0.6s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !cardUp else {
                Log.write("win: revive skipped, a card is already up")
                return
            }
            openCard(bundleID) { why in
                Log.write("win: revive gave up " + why)
            }
        }
    }

    private static func clearHosted() {
        guard let bundleID = hostedBundle else { return }
        hostedBundle = nil
        try? FileManager.default.removeItem(atPath: Aevon.hostedPath)
        Log.write("win: hosted mark cleared for " + bundleID)
    }

    /// 0.0.99 — 只清「确实是我这一张」的那份记号。
    ///
    /// `clearHosted()` 是无条件的：多窗之后关掉停靠小窗会顺手抹掉主窗那份
    /// `hosted.plist`，那个 App 下一拍就不认为自己在浮窗里了。
    private static func clearHosted(_ bundleID: String) {
        guard !bundleID.isEmpty else { clearHosted(); return }
        if let current = hostedBundle, current != bundleID {
            Log.write("win: hosted mark kept for " + current + " (closing " + bundleID + ")")
            return
        }
        clearHosted()
    }

    /// 6 秒内找 scene。
    ///
    /// 0.0.58 — 前 30 拍从 250 ms 压到 60 ms。原来那 250 ms 是「一秒看四次」，
    /// 而场景从挂起启动到出现通常只要 120~300 ms —— 也就是**第一次看见它，
    /// 平均已经晚了 125 ms，最坏 250 ms**，这段时间卡片还没建，屏幕上什么都
    /// 没有。挂起启动本身已经把「等 App 进程」这一段省掉了，剩下的这一拍就
    /// 成了整条链上最贵的一段延迟。
    ///
    /// 1.8 秒之后退回 250 ms：那时候还没 scene，就是真没起来，没必要每秒查
    /// 十七次到第六秒。
    ///
    /// 0.2.3 — 4 秒 → 6 秒，并且**每秒写一行现场**（`win: wait scene`）。
    /// Aevon(172) 里高德两次都是「挂起启动 1 ms 成功、4 秒零 scene」，而微信
    /// 591 ms、小红书 633 ms、汽水音乐 962 ms 都正常 —— 说明这不是「慢」，是
    /// 高德这一类根本不按挂起启动建 scene。4 秒这个数字从来没有依据，只是当年
    /// 拍的；而缺少现场让「进程没起」和「进程起了没 scene」分不开。诊断行同时
    /// 报 App 的 pid 与 manager 里全部 scene 标识，一次就能分清三种情况：
    /// pid=-1 = 进程没起；pid 有值但列表里没有它 = 起了没 scene；列表里有但
    /// 名字不含 bundle id = 我们的匹配口径错了。
    private static func pollForScene(_ bundleID: String, ticks: Int, start: Date,
                                     retried: Int = 0,
                                     homed: Bool = false,
                                     fallback: @escaping (String) -> Void) {
        // 0.4.0 — 这里原本排在系统 scene 之前问一次自建承载：「2 建好了」接过
        // 它、「3 失败」落一次老路（`AevonLaunchSuspended` 兜底）。
        // 建 scene 的生产者 `AevonOwnStart` 在 0.3.1 下线、这一版把
        // `AevonOwnState` / `AevonOwnFetch` 一起删掉，那两种答案都不可达：
        // 两个分支从来没有进去过。`fell` 这个递归参数只服务于「失败只落一次」，
        // 分支删掉之后它恒等于 `false`，四代调用点一并去掉。
        // 现在唯一的来源就是下面那个 `sceneFor(bundleID)`。
        if let scene = sceneFor(bundleID) {
            // 0.2.30 — **先回桌面，再建卡**。这是「全屏黑屏 + 浮窗黑闪」的根因修复。
            //
            // 0.2.23~0.2.29 的顺序都是「先挂卡、0.05~0.12 s 后再发 home」：
            //   ① 挂卡那一拍把 App 的 scene 从全屏页里搬进卡片，全屏页立刻变空
            //      —— 操作者先看到**一整屏黑**，然后桌面才进来把黑盖掉；
            //   ② home 的过渡会把借来的 scene 判成后台，层掉一次
            //      （`win: picture dropped`），60~200 ms 后才回来 —— 卡片里那一下黑。
            // 快照盖帧只能盖住 ②，盖不住 ①，而且用户已经明确不要这种做法。
            //
            // 把顺序反过来，两个黑都不存在：
            //   发 home 时 scene 还完整地摆在页里，过渡演的就是这个 App；
            //   等桌面真的在屏（`isSpringboardActive == 1`，再留 0.4 s 让过渡走完）
            //   之后才回到这条等待链，建卡时 App 已经在后台 —— 那正是
            //   「后台 App → 浮窗」这条一直在用、从没黑过的路。
            // 所以这里不拍快照、不盖任何视图，只是把时序放到正确的位置。
            // 0.2.34 — 判据与 `openCard` 那道门同一口径：`SBApplication.isFrontmost`。
            // scene 可见位对后台 scene 也答 1（0.2.33 真机日志里桌面在屏时它仍然
            // 答 1），拿它判「目标是不是屏上那个」会把每一次都带进 home 分支。
            // 0.2.35 — 再补 scene 自己的 `settings.isForeground`：`isFrontmost` 在
            // 这台机器上对不少 App 答 -1/0（`SBApplicationController` 认不出 bundle），
            // 全屏 QQ 选自己也会被漏掉。两个读数任一为 1 即可。
            // 0.3.33 — 与 `openCard` 那道门同一个口径：只有「目标就是屏上那个
            // 全屏页」才发 Home。`sceneFG`（scene 自己报前台）在这一格用不了 ——
            // 挂起启动出来的 scene 一样答 1，Aevon(257) 的每一次 `deny card` 都被
            // 它带进 Home 分支，那就是用户看到的「卡出现前桌面闪一下」。
            if !homed, frontSceneBundle() == bundleID {
                unmark()
                let step = AevonHomeStep(1, nil)
                Log.write("win: home first " + (step ?? "step nil") + " b=" + bundleID)
                var waited = 0
                func afterHome() {
                    let active = AevonSpringboardActive()
                    let front = AevonAppFrontmost(bundleID)
                    let fgNow = AevonSceneForeground(scene)
                    // 0.5 s = home 过渡本身走完；1.4 s = 「系统没接这一下」的上限。
                    // 0.2.34 — `front != 1` 也算走完：桌面在屏时 `isSpringboardActive`
                    // 不一定会回 1（卡片窗口存在时它就是 0），只看它每次都要等满。
                    // 0.2.35 — scene 前台位回落同样算「已经离开全屏」。
                    // 前 0.5 秒照样不建卡 —— 那正是 0.2.30 修掉黑屏的间隔。
                    if ((active == 1 || front != 1 || fgNow != 1) && waited >= 10) || waited >= 28 {
                        Log.write(String(format: "win: home first ready waited=%ldms springboard=%ld front=%ld scene_fg=%ld",
                                         waited * 50, Int(active), Int(front), Int(fgNow)))
                        pollForScene(bundleID, ticks: 0, start: start,
                                     retried: retried, homed: true,
                                     fallback: fallback)
                        return
                    }
                    waited += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { afterHome() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { afterHome() }
                return
            }
            unmark()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Log.write("win: icon scene up after " + String(ms) + "ms ticks=" + String(ticks))
            emitNotes(AevonTakeNotes())
            float(scene, bundleID: bundleID, holdFirst: homed)
            // A hold with no card under it is a scene that never sleeps again.
            //
            // 0.0.98 — 判据从「有没有卡」换成「这个 App 是不是当前主窗」。旧主窗
            // 降级之后 `cardUp` 一直是 true，用它判等于不管新卡起没起来都算成功，
            // 那样一条失败会被记成一次成功，下次再去查就是「日志里没有异常」。
            guard FloatHost.mainBundle == bundleID else {
                AevonHookDisarm(bundleID)
                // 0.2.2 — 建卡成功但主窗没落在这次请求的 App 上（被前一张卡抢了）。
                //
                // 这条闸只管一件事：**别回落全屏**。真正的失败照旧走 `fallback`；
                // 但系统界面（锁屏 / 通知中心 / 控制中心）盖着的时候不走 —— 兜底
                // 会把 App 全屏打开，锁屏上点一条通知变成解锁后蹦出一个全屏 App，
                // 正是用户明确否掉的结果。遮挡从来不是「没关系」的理由（0.2.0 的
                // 错就在这儿），它只是「宁可什么都不发生，也不要全屏」。
                if AevonSystemCovered() {
                    Log.write("win: icon card closed by cover, no fallback")
                    return
                }
                Log.write("win: icon card did not come up, hold released")
                fallback("card did not come up")
                return
            }
            return
        }
        // 0.4.0 — 这一段原本是「每秒一行现场」的节流（`probed` / `seen` 两个
        // 计数器，只服务 `probeScenes`）。探针随本版删除，两个计数器与
        // `probed:` 这个递归参数一并去掉。
        // 0.2.4 —— 挂起启动不是「叫一次就成」的。
        //
        // 母版取宿主是 `obtainHostViewForBundle:frame:maxAttempts:delay:with169:completion:`
        // —— 名字里那两个参数就是「次数」和「间隔」，它默认会重试。我们到 0.2.3 为止
        // 只叫一次，然后原地干等六秒。Aevon(173) 的高德到第九秒才出现 scene，单次
        // 请求在那一刻早就过期了，等再久也不会自己补上。
        //
        // 这里每 2 秒补叫一次、最多三次（第 2 / 4 / 6 秒），连同总等待从 6 秒放到
        // 12 秒，就是母版那对参数在本项目的落点。每次 1~17 ms（真机实测），不是
        // `openApplicationWithBundleID:` 那种 10 秒 XPC，留在主线程上可以接受。
        var again = retried
        if again < 3, Date().timeIntervalSince(start) >= Double(again + 1) * 2.0 {
            again += 1
            let door = AevonLaunchSuspended(sharedApplication(), bundleID)
            Log.write(String(format: "win: icon relaunch %@ try=%ld door=%ld t=%ldms",
                             bundleID, again, door,
                             Int(Date().timeIntervalSince(start) * 1000)))
        }
        guard Date().timeIntervalSince(start) < 12.0 else {
            unmark()
            AevonHookDisarm(bundleID)
            // 0.2.1 — 这一条出口原来不看遮挡，于是锁屏上点一条通知会走到全屏兜底。
            // Aevon(169) 里 10 次 `ring: launch` 全是这么来的：每次都是 10 秒整的
            // 同步 XPC，主线程在 2 分 07 秒里停了 100 秒。另一个出口
            // （`card did not come up`）早就有这道闸，这里补上同一道。
            if AevonSystemCovered() {
                Log.write("win: icon card gave up under cover, no fallback")
                return
            }
            Log.write("win: icon " + bundleID + " produced no scene")
            // 字符串必须长过 15 字节：Swift 把 ≤15 字节的字面量编成立即数，
            // 不进二进制常量区，audit 就断言不到（`no scene in 12s` 正好 15，
            // 0.2.4 第一次构建就是栽在这条上）。
            fallback("no scene after 12s and 3 retries")
            return
        }
        // 0.0.59 — 60 → 40 ms。枚举一次 scene manager 只有几个对象，成本远小于
        // 这一拍白等的时间；前 30 拍（1.2 s）覆盖了「scene 该出现」的全部窗口。
        let gap: Double = ticks < 30 ? 0.04 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            pollForScene(bundleID, ticks: ticks + 1, start: start,
                         retried: again, homed: homed, fallback: fallback)
        }
    }

    // 0.4.0 — 这里原本是 `probeScenes`：「等 scene」这条路上每秒一行的现场快照
    // （`win: wait scene %lds app=%d n=%ld hook=%d ...`），最多 12 行。
    // 纯探针 —— 只读 scene manager、只写日志，不参与任何判定。它的调用点是
    // `pollForScene` 主循环里 `elapsed > seen` 那一支，随函数一起删。
    //
    // 「进程没起 / 起了没 scene / 匹配口径错」这三种失败现在由
    // `win: launch state cs=%ld layers=%ld seen=%ld held=%ld` 与
    // `win: listed scene all shell b=` 两行分开，不再需要这条每秒快照。

    /// The scene that answers to this bundle id. Matched on the identifier
    /// rather than on the app object: `sceneID:com.x.y-default` is the one
    /// spelling every release has used, and the scene manager is the only door
    /// that lists scenes across processes.
    ///
    /// 0.2.4 — 两条口径。先问 manager（健康的那一类：已连上客户端），再问拦截点
    /// 登记表（`sceneID:` 名字出现过、系统推过 settings，但 manager 列不出来）。
    ///
    /// Aevon(173) 把这两类分开了：高德六行现场里 manager 一个都不给，而 hook
    /// 0.3.22 — `win: listed scene all shell` 的节流表（bundle → 上次落笔时刻）。
    /// 只为一件事服务：把 40 ms 轮询打出来的同一句重复压成一行。见 `listedScene`。
    private static var listedMissAt: [String: CFAbsoluteTime] = [:]

    /// trace 里同名 scene 被改了三次前台 —— 它存在，只是没连上客户端。用第一条
    /// 口径能保证「正常 App 拿到的永远是健康 scene」，第二条只在第一条空手时兜底，
    /// 并且把它的三项读数写进日志：`running=0 visible=0` 就是那种空壳，建出来
    /// 大概率是一张黑卡，日志里要看得见这件事。
    private static func sceneFor(_ bundleID: String) -> NSObject? {
        if let scene = listedScene(bundleID) { return scene }
        guard let raw = AevonSeenSceneForBundle(bundleID) else { return nil }
        guard let seen = raw as? NSObject else { return nil }
        // 0.2.7 — Mango 的 `pollSceneContentThenFade:remaining:`：判**内容**就绪，
        // 不判「对象存在」。
        //
        // 0.2.4 起第二条口径能拿到「FrontBoard 已登记、客户端还没连上」的空壳，
        // 拿到就直接建卡 —— 建出来的是一张黑卡（用户看到的就是「小窗是黑的」）。
        // 空壳的两个读数都是 0：`accessibilitySceneIsRunningInForeground` 与
        // `accessibilitySceneIsForegroundVisible`。两个都 0 就**不返回**，让
        // `pollForScene` 继续等（重试与 12 秒上限都不动）；只要有一个是 1 就照旧。
        //
        // 这条只影响「manager 列不出来、只有 hook 表认识」的那一类 scene ——
        // 正常 App 全走第一条口径，一个字节都没变。
        let running = AevonBoolOf(seen, "accessibilitySceneIsRunningInForeground")
        let visible = AevonBoolOf(seen, "accessibilitySceneIsForegroundVisible")
        let shell = (running == 0 && visible == 0)
        Log.write("win: scene from hook table " + bundleID
                  + " seen=" + String(AevonSeenCountOf())
                  + " running=" + flag(running)
                  + " visible=" + flag(visible)
                  + (shell ? " shell=1 (deferred, no black card)" : ""))
        if shell { return nil }
        return seen
    }

    /// 第一条口径：manager 枚举。所有正常建卡的 App 都走这条。
    ///
    /// 0.2.79 — **同一个 bundle 可能有好几份 scene，取分数最高的那一份。**
    ///
    /// Aevon(212) 12:21:06 的现场（微信第二次授权）：
    ///   win: own live attach com.tencent.xin t=0ms wait=0ms
    ///   win: launch state cs=0 layers=-1 seen=0 held=1
    ///   win: first frame shown after 112ms (first frame)
    /// 拿到的是一张 `contentState = 0`、`natural = 430x932` 的空壳 —— 12:20:40
    /// 那次授权收卡时 `own handed over` 留下的那一份（没有 presenter、微信的窗口
    /// 也已经跟着卡没了）。旧代码取枚举顺序里的**第一个**，正好取到它，于是整张
    /// 卡是黑的。用户报的「微信悬浮窗第二次变黑」就是这一行。
    ///
    /// 现在给每一份打分：前台可见 4、前台运行 4、有内容 2/1、settings 前台位 2。
    /// 全部分数为 0 就是「只有空壳」—— 返回 nil，让 `openCard` 走自建那条路
    /// （那条路在 12:20:39 是成功的：`own compose ok` → `first frame 158ms`）。
    /// 0.3.33 — **「现在屏上那个全屏 App 是谁」**（不靠 `SBApplication`）。
    ///
    /// 回桌面那一步（0.2.30）本来是为了「目标 App 正全屏时别把全屏页抽空 ⇒ 黑」。
    /// 它原来的判据是「目标 scene 自己报前台」，但 `settings.isForeground` 对
    /// **挂起启动出来的 scene 同样答 1** —— 于是每一次拒答 + 建卡都白发一次 Home，
    /// 用户看到的正是「卡片出现之前桌面闪一下」（Aevon(257) 每条 `deny card` 后面
    /// 紧跟 `win: home first step1 …`）。
    ///
    /// `SBApplication` 那条路在这台机器上根本答不出来（`isFrontmost` 对
    /// Everything 都答 -1，`AevonAppObject` 常常空手），所以换一个不用它的口径：
    /// 枚举 `FBSceneManager` 里 `settings.isForeground == 1` 的 scene，从
    /// `sceneID:<bundle>-<…>` 里取 bundle。这就是「屏幕当前属于谁」，和
    /// 「谁有 scene」是两件事。
    ///
    /// 返回 nil = 枚举不出来（manager 空 / 没有前台 scene），调用方按「不是目标」
    /// 处理 —— 宁可少发一次 Home（卡片直接浮上去，这正是用户要的），也不要凭空
    /// 把桌面叫出来。
    private static func frontSceneBundle() -> String? {
        guard let manager = AevonSceneManager() as? NSObject else { return nil }
        var best: String?
        var bestRank = -1
        // 0.4.2 — **桌面在屏时，屏幕属于 SpringBoard，不属于任何 App。**
        //
        // 用户报的「在桌面第二页呼出圆盘、选中图标开卡之后桌面跳回第一页」，
        // 就是这里判错了：桌面在屏时，目标 App 的 scene 仍然答 `isForeground=1`
        // （挂起启动出来的 scene 更是从第一拍就答 1），而它的
        // `accessibilitySceneIsForegroundVisible` / `contentState` 排名比
        // SpringBoard 的图标 scene 高，于是这个函数返回的是**目标 App**。
        // 调用方看到「目标就是屏上那个」⇒ 发 `AevonHomeStep(1)` ⇒ 系统收桌面
        // ⇒ 图标界面回第一页。
        //
        // 判据用 SpringBoard 自己的可见位：它在屏 = 桌面真的在用户眼前，
        // 那一拍去按 Home 没有任何意义（我们已经在家了）。App 全屏时
        // SpringBoard 的图标 scene 不可见，这一条不会误伤 0.2.30 那个
        // 「全屏 App → 卡片，先把 scene 从全屏页里让出来」的修复。
        var springboardUp = false
        var appVisible = false
        AevonEnumerateScenes(manager) { scene in
            guard let scene = scene as? NSObject else { return }
            let settings = value(of: scene, "settings")
            guard (settings.map { AevonBoolOf($0, "isForeground") } ?? 0) == 1 else { return }
            let ident = value(of: scene, "identifier").map { String(describing: $0) } ?? ""
            var name = ident
            if let r = name.range(of: "sceneID:") { name = String(name[r.upperBound...]) }
            // `sceneID:com.tencent.mqq-default` / `sceneID:com.x.y-<UUID>`：bundle
            // 一定在第一个 `-` 之前。
            if let dash = name.firstIndex(of: "-") { name = String(name[..<dash]) }
            guard name.contains(".") else { return }
            let visible = AevonBoolOf(scene, "accessibilitySceneIsForegroundVisible") == 1
            if name.hasPrefix("com.apple.springboard") {
                if visible { springboardUp = true }
            } else if visible {
                appVisible = true
            }
            var rank = 0
            if visible { rank += 2 }
            if AevonContentStateOf(scene) >= 2 { rank += 1 }
            if rank > bestRank { bestRank = rank; best = name }
        }
        // 双向约束：只有「SpringBoard 可见、且没有任何 App 的 scene 报可见」才
        // 认定桌面在屏。全屏 App 里 `appVisible` 会被那一个 App 立起来，这一条
        // 因此不会把 0.2.30 的「先回桌面再建卡」误关掉。
        return (springboardUp && !appVisible) ? "com.apple.springboard" : best
    }


    private static func listedScene(_ bundleID: String) -> NSObject? {
        guard let manager = AevonSceneManager() as? NSObject else { return nil }
        var best: NSObject?
        var bestScore = -1
        var count = 0
        AevonEnumerateScenes(manager) { scene in
            guard let scene = scene as? NSObject else { return }
            let identifier = value(of: scene, "identifier").map { String(describing: $0) } ?? ""
            guard identifier.contains(bundleID) else { return }
            count += 1
            var score = 0
            if AevonBoolOf(scene, "accessibilitySceneIsRunningInForeground") == 1 { score += 4 }
            if AevonBoolOf(scene, "accessibilitySceneIsForegroundVisible") == 1 { score += 4 }
            let state = AevonContentStateOf(scene)
            if state >= 2 { score += 2 } else if state == 1 { score += 1 }
            if (value(of: scene, "settings").map { AevonBoolOf($0, "isForeground") } ?? -1) == 1 {
                score += 2
            }
            if score > bestScore {
                bestScore = score
                best = scene
            }
        }
        if bestScore <= 0 {
            // 0.3.22 — 等 scene 的这段时间这里是 40 ms 一轮的轮询，同一句话会连打
            // 八到十遍（Aevon(247) 里正好 8 行 `n=0 best=-1`）。结论只有一条，
            // 记一次就够：同 bundle 五秒窗口内只落第一行，后面的次数从「等到了」
            // 或「没等到」那条收尾记录上能看出来。
            let now = CFAbsoluteTimeGetCurrent()
            if now - (listedMissAt[bundleID] ?? 0) > 5.0 {
                listedMissAt[bundleID] = now
                Log.write("win: listed scene all shell b=" + bundleID
                          + " n=" + String(count) + " best=" + String(bestScore))
            }
            return nil
        }
        return best
    }

    /// The system's own answer to "may this scene go to sleep", as a number.

    /// `absent` means the method is not there, which is not the same as 0.
    private static func reasonsOf(_ scene: NSObject) -> String {
        let value = AevonReasonsOf(scene)
        return value == UInt64.max ? "absent" : String(value)
    }

    // 0.4.0 — 这里原本是 `target(_ manager:)`：从 scene manager 里挑「前台那个
    // scene」的整套打分（四条读数 + 前六条候选逐条落日志 + 后台兜底）。
    //
    // 它在这个包里**一个调用方都没有** —— 挑 scene 的活早就是 `sceneFor(bundleID)`
    // 在干（按 bundle 精确匹配，见下），`target` 只在 0.0.2x 的「从一堆 scene 里
    // 猜哪个能用」那个年代被用过。`-Osize` 每次都把它连同四条日志一起剥掉，审计
    // 于是报 `win: scene candidate` / `win: enumerating scenes` / `nothing to float`
    // 三条串不在包里。整函数删除。

    private static func float(_ scene: NSObject, bundleID: String? = nil,
                              holdFirst: Bool = false) {
        guard let manager = value(of: scene, "uiPresentationManager") else {
            Log.write("win: no uiPresentationManager")
            return
        }

        // How many layers the scene is offering at all: a suspended background
        // scene offers none, a foreground one at least its display layer. One
        // number, read before anything is built, so it describes the scene and
        // not our own work on it. 0.0.27-0.0.29 needed five method-table dumps
        // around this line to learn the getter names; the names are known now,
        // and `hosted=2` at the container is the reading that decides anything.
        let layerManager = value(of: scene, "layerManager")
        Log.write("win: scene layerManager layers="
                  + String(count(of: layerManager, "layers")))

        guard let made = AevonCreatePresenter(manager, "com.aevon.float", 0),
              let presenter = made as? NSObject else {
            Log.write("win: no presenter")
            emitNotes(AevonTakeNotes())
            return
        }
        Log.write("win: presenter cls=" + NSStringFromClass(type(of: presenter)))

        // The one call both reference implementations make and this tweak never
        // did. `setResizesHostedContext:` (blueprint 2.1, marked there as the
        // ★★★ of the chain) tells the presenter to resize the scene's hosted
        // context to the presenter instead of expecting the presenter to be the
        // scene's own size. Without it a card that is a fifth of the screen is
        // asking a full-screen surface to shrink itself, and an unshrunk surface
        // in a cropped view is not necessarily a picture.
        //
        // ⛔ 0.3.5 — **这一句从 0.2.x 起就是静默失效的。**
        //
        // Aevon(230) 的选主子普查（同一天日志，20:42:11）写得很直接：
        //   presenter: selector setResizesHostedContext: owner=UIMutableScenePresentationContext
        //   presenter: selector modifyPresentationContext: owner=_UIScenePresenter
        // `setResizesHostedContext:` **不在 presenter 上**，所以
        // `AevonCallSetBool(presenter, …)` 恒返回 0；而这里写的是 `_ =`，
        // 返回值被丢掉 —— 于是「没调成」和「调成了」在日志里长得一模一样。
        // 同一个形状在 Aevon(230) 的探针里表现为四路全部 `resize=-1`。
        //
        // 正确入口：`modifyPresentationContext:`（presenter，参数 block），
        // block 收到 `UIMutableScenePresentationContext`，在它身上写。
        AevonModifyContextSetResize(presenter, "setResizesHostedContext:")

        guard let raw = value(of: presenter, "presentationView"),
              let view = raw as? UIView else {
            Log.write("win: no presentationView")
            emitNotes(AevonTakeNotes())
            return
        }
        Log.write("win: view cls=" + NSStringFromClass(type(of: view))
                  + " attached=" + (view.superview == nil ? "no" : "yes")
                  + " natural=" + String(format: "%.0fx%.0f",
                                         view.bounds.width, view.bounds.height))

        // 0.0.33 — the card stops being a probe and becomes furniture, so the
        // teardown is no longer "the thing that happens after eight seconds": it
        // is a function with three callers (the close button, the ten minute cap,
        // and anything added later). Growing it in place was how 0.0.30 ended up
        // with a push nobody could move.
        //
        // The order is the 0.0.32 fix and stays untouched —
        //   stop the clock   (so nothing pushes forward after the hand-back)
        //   write the scene back to the background
        //   dismantle the presenter
        //   hide the window, disarm, and read the settings back
        // — with `closed` as the re-entry gate: the button and the cap can fire
        // within a frame of each other, and a second hand-back on a presenter
        // that is already invalid is exactly the kind of call that costs a phone.
        var stopped = false
        var closed = false
        // 0.2.36 — 这一次拆卡是不是「给系统全屏让路」。只影响下面那条 0.35 s 的
        // 后台补写：让路时系统紧接着就会自己激活这个 App，补写会把刚拉起来的
        // 全屏再按回后台（0.0.82 注释里 Aevon(73) 撞的就是这一拍，只是那次是
        // 用户手动点图标）。让路是有意的，所以跳过。
        var yielding = false
        // 0.2.36 — 这张卡在 `FloatHost.cardClosers` 里的键。用 `bundleID`（这张卡
        // 自己的），不用 `hostedBundle` —— 多窗之后后者是「最后登记的那个 App」。
        let yieldKey = bundleID ?? hostedBundle ?? ""
        func closeCard(_ reason: String) {
            if closed { return }
            closed = true
            stopped = true
            // 0.2.36 — 出口表在拆的第一拍就摘：让路那条路是同步调用，摘掉之后
            // 同一张卡不会被第二次 `closeCard` 碰到（`closed` 之外的保险）。
            if !yieldKey.isEmpty { FloatHost.cardClosers[yieldKey] = nil }
            // 0.0.55 — 先把空闲熄屏还原，再做别的。反过来的话，中间任何一次
            // 提前 return（deactivate 抛异常、presenter 已失效）都会让断言留在
            // 系统里 —— 浮窗关掉之后手机不再自动锁屏，比不修更糟。
            let idleRelease = AevonIdleTimerEnd()
            Log.write("win: idle timer released mask=" + String(idleRelease)
                      + " kicks=" + String(AevonIdleTimerCount()))
            // 0.0.61 — 逻辑尺寸要还回去。我们写过的东西不会随卡片消失而失效
            // （和 0.0.32 的 foreground 是同一条教训）：不还，那个 App 从此是
            // 377 pt 宽的排版，回到桌面自己打开也是，直到它自己被系统重开。
            // 0.0.98 — 只还自己那一格。
            //
            // 0.0.97 及以前这里写的是「设一个整屏目标 → 推一次 → 全部清掉」，
            // 因为当时只有一块画布。多窗之后那样做会把**另一个窗**的画布目标
            // 一起抹掉：关掉主窗，停靠的那个窗就再也不会被写回它自己的尺寸，
            // 表现是「关一个窗，另一个窗的画面忽然按整屏重排」。
            // 0.0.99 — 还的是**这张卡自己的**那一格，不是 `hostedBundle`。
            //
            // `hostedBundle` 是单值：多窗之后它记的是「最后被登记的那个 App」，
            // 于是关掉停靠小窗时会把主窗的 bundle 当成自己的（Aevon(87) 里
            // `hosted mark cleared for com.apple.DocumentsApp` 出现在关别的窗那一拍）。
            // `bundleID` 是这个 scene 自己的，唯一正确。
            let closingBundle = bundleID ?? hostedBundle ?? ""
            // 0.4.0 — 这里原本有一个 `owned`（「这张卡的 scene 是不是我们自己建的」），
            // 它决定关卡做哪件事：借来的要 `AevonPushBackground` 推回后台，自建的
            // 要 `destroyScene:`。自建 scene 在 0.3.1 就下线了，`AevonOwnIsOwned`
            // 在 0.4.0 删除，它恒为 false —— 下面每一处都只剩「借来的」那一支，
            // 逐处化简，行为一个字节都不变。
            // 0.2.38 — 「让路」= 松手，不是拆掉。自建 scene 也不再销毁：
            // 0.2.37 在系统正要把这张 scene 拉成全屏的那一拍 destroy 它，
            // 设置 App 直接闪退，其它 App 常常变成「全屏底部黑」。
            //
            // 0.2.79 — **授权收尾不交还，照旧销毁。**
            //
            // Aevon(212) 12:20:40 的现场：
            //   win: card closed after auth b=com.tencent.xin
            //   win: own handed over sceneID:com.tencent.xin-default
            //   win: background after teardown door=1 own=1 handover=1
            // 那一拍 `yielding` 是之前让路留下的，于是走出了 handover：scene
            // 留在系统账本里（`natural=430x932`、没有 presenter），微信的窗口
            // 却已经跟着卡一起没了。12:21:06 第二次授权 `own live attach` 贴上
            // 去，`launch state cs=0` —— 用户看到的就是「第二次微信是黑的」。
            //
            // 授权这条路永远不会有「系统接着把这张 scene 拉成全屏」的下文：
            // 用户要的是回发起方。交还没有任何收益。
            let handover = yielding && reason != "auth done"
            // 让路时也要真的写一次整屏：系统接下来要的就是这张 932，提前给它，
            // 接管那一拍就不会出现「717 摆在 932 窗口里」。
            //
            // 0.4.4 — **交还改成「强制 + 校验 + 阶梯补写」，落地之前不清掩码。**
            //
            // 旧代码这里先 `AevonSceneFrameSet(932)` 再 `AevonPushSceneFrame`，
            // 然后**立刻**清掩码。而 `AevonPushSceneFrame` 的 0 有两个含义：
            // 「不用写」与「写了但三道门都没开」（`wrote` 计数会涨，值也确实改了
            // 那份 settings，可系统没收到）。把它当成「不用写」，后面的清掩码就
            // 把最后一次补救机会也撤掉了 —— 那个 App 从此在系统眼里还是 717，
            // 回到全屏就是用户截图里那条 215 pt 黑。
            //
            // 现在：写、回读、门没开就 0.15 / 0.45 / 0.90 s 各补一次，落地即止；
            // 掩码在补写阶梯收尾时才清（`restoreScreenBack`）。
            let restoreDoor = AevonScreenBack(closingBundle.isEmpty ? nil : closingBundle,
                                              scene)
            Log.write("win: scene frame restored door=" + String(restoreDoor)
                      + " wrote=" + String(AevonFrameWriteCount()))
            restoreScreenBack(closingBundle: closingBundle, scene: scene,
                              restoredDoor: restoreDoor)
            _ = AevonCallVoid(presenter, "deactivate")
            _ = AevonCallVoid(presenter, "invalidate")
            // 0.0.68 — 顺序回到「先拆 presenter，再摘卡片」。0.0.67 把它提到
            // `deactivate` 之前，理由是 `FloatHost.hide()` 要复位承载视图；那个
            // 复位已经删了（见 `FloatHost.teardown`），提前的唯一理由也就不在了，
            // 而「在系统对象还活着的时候动那棵树」正是这一版要撤的东西。
            // 0.0.98 — 按名字拆自己那一块。多窗之后「拆唯一那个宿主」会让关掉
            // 主窗时连带干掉停靠小窗。
            FloatHost.hide(bundle: closingBundle)
            // 0.2.60 — 卡片没了，这块区域立刻还给 App。
            //
            // `reportBand` 在 `card` 还在时会把旧几何再报一遍（关窗这一拍
            // `card` 尚未置空），Aevon(201) 里 `app: band prefs on=1
            // band=430x707` 在关卡之后还继续出现就是它。这里显式清一次：
            // App 收到 `none` 会把窗口还回场景高，全屏那一页才不会只剩上半截。
            if !closingBundle.isEmpty {
                _ = AevonAppBandSet(closingBundle, CGRect.null, .zero)
            }
            // 0.2.24 — 借前台 scene 时藏掉的那一页要还回去。放在拆完 presenter
            // 之后、交还后台之前：此刻 scene 还在我们手里，页面还空着，先还原
            // 才不会让系统在中间那一瞬去画一张空页。
            restoreHiddenPage()
            // 0.2.24 — 那一页已经在上一条还回去了，这里没有别的还原动作。
            // 0.0.82 — 交还后台这一拍搬到拆完 presenter 之后。
            //
            // Aevon(73) 里每一张卡关掉都是同一个形状：`background door=1 fg=yes`
            // （写了、没落地），0.6 s 后 `background retry door=1 fg=no`（这次落地
            // 了）。两次之间那 0.6 s 就是「关掉浮窗后不能立刻打开全屏抖音」的全部
            // 原因：用户在那一秒里点图标，系统刚把 App 拉起来，我们那一次补写又
            // 把它按回后台 —— 看着就是「点了没反应」。
            //
            // 第一次写不进去，是因为写的时候 presenter 还活着（`deactivate` 还没
            // 调），场景的归属权还在我们手里。拆完 presenter 再写，一次就够；
            // 下面那条 0.35 s 的补写留着，万一这一次也没落地。
            // 0.4.0 — 关卡动作只剩一种：`AevonPushBackground(scene)`。自建 scene
            // 的两个收尾（交还 `AevonOwnHandOver` / 销毁 `AevonOwnDestroy`）随 0.3.1
            // 的下线一起失效，函数在这一版删掉。`handover` 只留在日志里 —— 它还能
            // 区分「让路」与「正常关卡」，是关卡时序唯一的读数。
            let door = AevonPushBackground(scene)
            Log.write("win: background after teardown door=" + String(door)
                      + (handover ? " handover=1" : ""))
            // 0.0.70 — 关卡这一拍把 App 写的读数取回来。必须在 `clearHosted()`
            // 之前：那个函数会把 `hostedBundle` 清空，之后就不知道去哪个容器里取了。
            drainAppLog("on close")
            // 0.0.75 — 关卡之后**再来一次**，4 秒后。
            //
            // Aevon(65) 里最要命的那一段没有任何读数：App 在关卡后 3 拍
            // （0.4 / 1.5 / 2.6 s）写下的 `state` 全是旧几何，而它真正按 932
            // 重排是在用户回到全屏那一刻 —— 之后一条记录都没有，所以「断层」
            // 只能靠录屏猜。这一次的 `snap clean` / `state` 会落在这 4 秒里。
            //
            // 用局部变量记住 bundle：`clearHosted()` 下面就把静态的那一份清了。
            // 如果这 4 秒内又开了一张同一个 App 的卡，这一份读数属于新的一次，
            // 让给新卡（`hostedBundle == b` 就跳过）。
            // 0.0.99 — 名字取自这张卡自己（见上面 `closingBundle` 那段）。
            // 0.0.69 — presenter 拆掉之后再交一次整屏尺寸。
            //
            // 原话（0.0.69）：上面那次推发生在承载面还在的时候，那时 App 的窗口
            // 还是 717 —— 它可能把这次 settings 变化当成「卡片里的重排」而不是
            // 「回到整屏」。Aevon(58) 的「关窗后全屏打开抖音整体偏下」就是 App
            // 带着 717 的排版回到桌面的样子。
            //
            // 0.4.4 — 这一段搬去 `restoreScreenBack`：0.30 s 只补一次不够（那一次
            // 也可能「写了没门」），而且它只认时间、不认落地。现在的阶梯是
            // 0.15 / 0.45 / 0.90 s，用 `AevonScreenBack` 强制提交并回读，
            // 落地即止、收尾才清掩码。判据（`frame restore skipped`）原样搬了过去。
            // 0.0.55 — 卡片没了，右缘带重新接触摸。
            AevonRingGrip.cardUp = false
            RingHost.shared.setEdgeActive(true)
            // 0.0.98 — 只把自己从名单里摘掉。多窗时全部清空会把停靠小窗的保活
            // 一起撤掉，那个窗下一拍就会被系统收走。
            AevonHookDisarm(closingBundle.isEmpty ? nil : closingBundle)
            clearHosted(closingBundle)
            let closedBundle = closingBundle.isEmpty ? nil : closingBundle
            if let b = closedBundle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    if hostedBundle == b { return }
                    let lines = AevonDrainAppLog(b, 400)
                    Log.write("win: app log lines=" + String(lines) + " from after card closed"
                              + " file=" + (AevonAppLogPathOf(b) ?? "none"))
                }
            }

            // 0.0.98 — 关掉一块之后，屏幕上可能还留着停靠小窗。`cardUp` 的语义
            // 是「还有没有至少一块卡」，所以问宿主，不无条件写 false。写 false 的
            // 后果是下一个 `openCard` 认为没有主窗可降级，直接去抢空槽。
            let stillUp = !FloatHost.mainBundle.isEmpty
            cardUp = stillUp
            emitNotes(AevonHookSummary())
            let back = value(of: scene, "settings").map { AevonBoolOf($0, "isForeground") } ?? -1
            Log.write("win: card closed by " + reason + ", background door=" + String(door)
                      + " fg=" + flag(back) + " live=" + (stillUp ? "yes" : "no"))
            // A hand-back that did not land is the same defect one layer down:
            // the app would spend the rest of the session believing it is in
            // front. One retry, a third of a second later, and then the log says so.
            //
            // 0.0.82 — 0.6 s 改成 0.35 s，并且加了 `!cardUp`：Aevon(73) 里那 0.6 s
            // 与「用户关掉卡片立刻点图标」撞在一起，补写把刚被系统拉起来的 App
            // 又按回后台。窗口越短越不会撞上；真撞上（新卡已经开出来）就不补了
            // —— 那时 scene 属于新的一张卡，再写后台就是错的。
            if back != 0 && !yielding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    // 0.0.98 — 判据按名字，不按「有没有卡」。多窗时 `cardUp` 大概
                    // 率还是 true（停靠小窗还在），用它判等于这条补写永远不执行；
                    // 要防的仍然是「0.35 s 内又开了同一个 App」，那只能按 bundle 判。
                    let armed = AevonHookArmedList()
                    if !closingBundle.isEmpty, armed != "no", armed.contains(closingBundle) {
                        return
                    }
                    let again = AevonPushBackground(scene)
                    let now = value(of: scene, "settings").map {
                        AevonBoolOf($0, "isForeground")
                    } ?? -1
                    Log.write("win: background retry door=" + String(again)
                              + " fg=" + flag(now))
                }
            }
        }

        // 0.0.59 — 「要不要等第一帧」改成两条判据，不再只看 contentState。
        //
        // `contentState` 是 scene 对「我有内容」的自答，它比「这一帧到了屏幕上」
        // 早：Aevon(58) 的那一闪，就是卡片照着它露出来、画面却还在路上。
        //
        //   ① contentState == 2 —— 必要，不充分；
        //   ② scene.layerManager.layers —— 这个 scene 递交了几个层。挂起启动的
        //      冷 scene 是 0，此时 contentState 说什么都不算数。-1 是探针读不到，
        //      不能当成「没有层」，否则卡片永远不出来。
        //
        // `seen` 只是读数，不参与判断：热启动回来的 App 同样 seen=0（它在后台），
        // 若拿它当条件，快速通道永远不会被走到，热启动也要白等 100 ms。
        var awaiting = false
        if bundleID != nil {
            let state = AevonContentStateOf(scene)
            let layers = count(of: value(of: scene, "layerManager"), "layers")
            let seen = AevonBoolOf(scene, "accessibilitySceneIsForegroundVisible")
            awaiting = (state != 2) || (layers == 0) || holdFirst
            Log.write(String(format: "win: launch state cs=%ld layers=%ld seen=%ld held=%ld",
                             state, layers, seen, awaiting ? 1 : 0))
        }

        // Window first, activate second. This is the whole difference from
        // 0.0.20, and the difference between a picture and a black phone.
        // 0.0.65 — 没有 `onReshape` 了：画布在开窗那一刻定死（屏宽 × 5:3），
        // 之后角拖动只做等比例缩放，没有任何路径会再改 scene 的 frame。
        guard let host = FloatHost.show(view, bundle: bundleID ?? hostedBundle ?? "",
                                        awaitingFrame: awaiting,
                                        onClose: { reason in closeCard(reason) }) else {
            // 0.0.99 — 失败必须**拆掉刚建的这个 presenter**。
            //
            // 这是 Aevon(87) 那个「卡屏 + 只剩白色光晕」的第二层原因，也是更深
            // 的那一层：`AevonCreatePresenter(manager, "com.aevon.float", 0)` 已经
            // 在这个 scene 上建好了一个 presenter，`FloatHost.show` 却在之后才
            // 因为没槽返回 nil。那个 presenter 于是**留在了 scene 上**，既没有
            // `deactivate` 也没有 `invalidate`。
            //
            // 日志把后果记得很清楚：22:26:35 第一次建好 presenter 后被拒；22:27:19
            // 用户再选同一个 App，日志停在 `scene layerManager layers=-1` 之后再
            // 也没有下一行 —— 同一个 scene 上第二次创建同标识的 presenter，主线程
            // 就卡在那儿。用户看到的就是「卡屏」，之后屏幕上只剩一圈手势环。
            //
            // 顺序与 `closeCard` 一致：先停手再交还，最后才拆。反过来的话，
            // 被 invalidate 的 presenter 还挂着一个「我还在承载」的断言。
            _ = AevonCallVoid(presenter, "deactivate")
            _ = AevonCallVoid(presenter, "invalidate")
            if let b = bundleID {
                AevonHookDisarm(b)
                clearHosted(b)
            }
            Log.write("win: no window - presenter released")
            // 0.2.0 — 这一格要还回去。
            //
            // `FloatHost.show` 在最后一行发现窗口没露出来就返回 nil，但那时
            // `takeMainSlot()` 已经占走了一格、`host.window` 也赋过值 —— 调用方
            // 手里没有宿主对象，谁也拆不掉它。Aevon(168) 的槽号就这么从 0 漏到 5，
            // 11 个槽漏满之后圆盘点任何图标都「没反应」，而且那些幽灵宿主还会
            // 继续认领热区吃手指。
            FloatHost.abandonTakenSlot()
            return
        }
        // 0.2.36 — 卡片真的上屏了，才把「怎么关它」登记出去。
        //
        // 登记点必须在 `FloatHost.show` 成功之后：失败那条路会自己拆 presenter，
        // 从不调 `closeCard`，提前登记就是留一个指向空槽的出口。
        if !yieldKey.isEmpty {
            FloatHost.cardClosers[yieldKey] = { reason in
                yielding = true
                closeCard(reason)
            }
        }
        cardUp = true
        // 0.0.55 — 卡片在屏时右缘带闭嘴（与浮窗外侧手势环在右下角重叠）。
        AevonRingGrip.cardUp = true
        RingHost.shared.setEdgeActive(false)
        Log.write("win: window up level=" + String(format: "%.0f", host.level))

        // 0.0.61 — 把 scene 的逻辑尺寸主动推一次。intercept 钩子只在系统更新
        // settings 时给机会，建卡这一拍它未必正好在更新，所以两条路都走。
        //
        // 这一步是「小胖屏」和「整屏缩小」的分界：只改承载视图的 bounds 时，
        // App 仍然按 430 pt 排版，377 的框只是把它裁了一截（Aevon(52) 的现场：
        // 字大、顶栏偏右、底栏与抖音右侧那一列全在框外）。
        let frameDoor = AevonPushSceneFrame(scene)
        Log.write("win: scene frame push door=" + String(frameDoor)
                  + " wrote=" + String(AevonFrameWriteCount()))
        // 两次回读。0.25 s 那次回答「系统收下了没有」，1.2 s 那次回答「它有没有
        // 被系统改回去」—— scene 重排比视图慢，两个时刻读数不同时，先后就是方向。
        for delay in [0.25, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let got = AevonSceneFrameOf(scene)
                Log.write(String(format: "win: scene frame after=%.0fx%.0f wrote=%ld",
                                 got.width, got.height, AevonFrameWriteCount()))
            }
        }

        // 0.0.55 — 浮窗期间禁止空闲熄屏。卡片真的起来了才 hold：`show` 失败
        // 的时候这张卡没有任何东西在播，压住锁屏只是替用户关掉了省电。
        let idleMask = AevonIdleTimerBegin()
        Log.write("win: idle timer held mask=" + String(idleMask)
                  + " saved=" + (idleMask & 4 != 0 ? "app" : "none"))

        mark("APP-activate")
        let ran = AevonCallVoid(presenter, "activate")
        unmark()
        Log.write("win: activate ran=" + (ran == 1 ? "yes" : "no such method"))
        Log.write("win: state hosting=" + flag(AevonBoolOf(presenter, "isHosting"))
                  + " active=" + flag(AevonBoolOf(presenter, "isActive")))
        Log.write("win: view sublayers=" + String(view.layer.sublayers?.count ?? 0))
        // 0.0.69 — 尺寸要在 presenter 接管之后再交一次，见 `reassertCanvas`
        // 上面那段：写在 `activate` 之前的那一次不算「App 的窗口变了」。
        host.reassertCanvas()

        // 0.2.30 — 这一段原来是「回桌面」的三级阶梯（0.2.25~0.2.29）。
        //
        // 它发得太晚了：卡片已经把这个 App 的 scene 从全屏页里搬走，全屏页
        // 从这一拍起就是黑的，而 home 还要再等 0.12 s 才发。操作者看到的第一屏
        // 黑就是这么来的；home 过渡本身又把借来的 scene 判成后台，层掉一次，
        // 那是卡片里那一下黑。0.2.27 的 `holdPicture` 只能盖后者。
        //
        // 0.2.30 把这件事整体前移到 `pollForScene`：scene 还在全屏页里、画面
        // 完整的时候发 home，桌面真的在屏之后才回到这里建卡。所以这里不再
        // 需要任何回桌面动作，也不需要快照。

        // 0.0.59 — 首帧交给自己的观察器，不再等保活时钟。
        //
        // 保活时钟稳态 200 ms 一拍（掉画才收紧到 60 ms），而冷启动时 fg 是我们
        // 自己写的 1、content 又是 2，`calm` 成立 —— 于是首帧判定平均晚 100 ms、
        // 最坏 200 ms。这段时间卡片是透明的，操作者看到的就是「点了没反应，然后
        // 突然闪一下」。
        if awaiting { watchFirstFrame(host, scene: scene) }

        // 0.0.31 — the push moves off the hook and onto a clock.
        //
        // 0.0.30 wrote the settings from inside `_setDeactivationReasons:`,
        // which is FrontBoard's own scene-update path. Aevon(29) is what that
        // costs: `push path=1 wrote=1 fg=1`, a card with a picture in it, and
        // then not one more line until the watchdog replaced SpringBoard seven
        // seconds later (pid 3271 -> 3305). The same lock, taken twice.
        //
        // The mother ship never writes from a callback. She runs a keepalive
        // clock on the main thread (rounds 12/13), writes only values that
        // differ (round 14), and stops after three failures in a row (round
        // 13) — so that is what this does. One beat per 250 ms for the life of
        // the card, a delta check inside the push, and `WIN-PUSH` on disk only
        // while a beat is in flight so a death inside it is named next launch.
        var keep: (() -> Void)!
        var beat = 0
        var misses = 0
        // 0.1.34 — 上一次见到的解锁计数。变了解锁了一次，退避计数要归零。
        var seenRevive = host.reviveTick
        var wrote = 0
        var marked = false
        // 0.0.50 — 掉画的记账。`dropped` 是画面开始黑的那一拍，0 = 现在有画；
        // `wakes` 是这一轮卡片里唤醒通道真正写出去的次数。
        var dropped = 0
        var droppedAt = Date()
        var wakes = 0
        // 0.2.54 — 这张卡到底见过画面没有。
        //
        // `contentState` 在这条路上是爬着上来的：0（还没准备好）→ 1（已连接、
        // 还没出首帧）→ 2（有画）。旧判据只排掉 2，等于把 `cs=1` 也算成「掉画」，
        // 而冷启动那 500 ms 里它一直是 1。
        //
        // Aevon(197) 的开卡现场：`beat 3 / 4 / 5` 全在读 `cs=1`，于是
        // `picture dropped cs=1` 这个假警报后面紧跟两次 `AevonWakeScene`
        // （`wake=1`、`wake=2`）—— 往一个**还没画过第一帧**的 scene 推 settings。
        // 那两次提交正好夹在 `scene deactivation #3/#4/#5` 与
        // `first frame shown after 527ms` 中间，是本轮最可疑的一段。
        //
        // 加这一格之后：`cs=1` 在首帧之前不再算掉画，唤醒配额留给真的掉下去
        // （`cs=0`，0.2.25 回桌面那次读到的就是这个数）。注意判据只排「还没出过
        // 首帧的 1」，不是把冷启动整段关掉 —— `cs=0` 那一路的兜底必须留着。
        // 这也是 `watchFirstFrame` 一直在用的口径（它认的是 `cs==2`），
        // 两个模块从此对同一件事只有一个答案。
        var sawContent = false
        // 0.0.91 — 「画面掉了、而且再也没回来」连续几拍。两拍就够：一拍可能是
        // 切换的中间态，两拍（稳态 0.2 s 一拍）就是真的没了。
        var deadBeats = 0
        // 0.0.40 — Aevon(38): the picture goes black for a moment whenever the
        // screen changes owner (desktop → app, app → desktop). Two candidates,
        // and they need different fixes: the scene really is being taken away
        // (then the clock is too slow and has to push sooner), or it is not and
        // the gap is in the compositor (then no write will help). This counter is
        // the one thing that tells them apart — it moves only when the system runs
        // its own deactivation path.
        var deact = AevonDeactStrippedCount()
        // 0.0.55 — 上次重打空闲计时的时间。20 秒 ≪ 系统最短的「自动锁定 30 秒」，
        // 又不会每秒烧一次私有 API（旧版 V0.2.49 定的频率，原样保留）。
        var idleAt = Date()
        var idleProbe = 0
        // 0.0.63 — 逻辑尺寸的看门狗。0.0.61/0.0.62 只在开窗后 0.25 s / 1.2 s
        // 各回读一次，卡片活着的那几分钟里 scene 有没有被系统改回整屏，日志里
        // 从来没有答案。这里两秒对一次账：对不上就重写一次，前四次各记一行
        // （`win: frame drift now=… want=…`）—— 有这一行，「内容只在刚打开时
        // 是对的」就不再是靠猜的。
        var drifts = 0
        // 0.1.51 — 原点这条路要是系统不认，不能每拍硬推。
        //
        // `settings.frame` 的尺寸历来有效（关窗还原就在用它），原点是从 0.1.50
        // 才开始用的，真机没验过。键盘态每拍查一次账，如果连续 8 拍「写了还是
        // 0」，就说明 FrontBoard 不接原点 —— 那时停手，只把尺寸对账留着，让画面
        // 退回 0.1.49 的形状，而不是每 200 ms 推一次 scene 更新（那是会抖的）。
        var originMisses = 0
        var originParked = false
        // The clock has to be able to stop from the outside, and 0.0.33 gives it
        // a second reason to: the card no longer disappears on a timer, so the
        // only thing that ends this loop is `closeCard` setting `stopped`.
        keep = {
            if stopped { return }
            beat += 1
            // 0.1.35 — 手指在宿主手里时，这一拍整段让路。
            //
            // 200 ms 一拍的那一堆读数全在主线程上：`reapplyPlacement` 要一次
            // scene settings、`AevonSystemCovered()` 打三个单例、`AevonContentStateOf`
            // 与 `AevonSceneLevel` 再各取一次。它们单独都不贵，但拖动把同一根
            // 主线程占满的时候，每 200 ms 插一次就是可感的顿一下 —— 用户说的
            // 「好多了，但依旧不流畅」。手势最多一秒（见 `FloatHost.liveUntil`），
            // 让路一秒不会漏掉任何需要及时反应的事：掉画会在 1 秒后照常接上，
            // 而这一秒里本来就不该有一次写 settings。
            if FloatHost.gestureLive {
                if !stopped {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { keep() }
                }
                return
            }
            // 0.2.2 — 这一拍照 0.2.0 是「盖着就收卡片」，整段删掉。
            //
            // 母版 Stheno 的二进制里 `isUILocked` 出现 0 次：它压根不管锁屏、
            // 通知中心、控制中心盖不盖，卡片建了就活着。我们 0.1.31 加了「整层
            // 隐藏」（Aevon(168) 证明它会自锁成永真，整台手机再也不出浮窗），
            // 0.2.0 改成「盖着就收卡」，而 Aevon(171) 证明后者同样错：
            //
            //   12:25:34 点微信通知 → 挂起启动成功 → 598 ms 拿到 scene →
            //   卡片完整建好（slot taken / band window up / window up level=101
            //   / activate ran=yes）→ `win: card closed at once (system cover up)`
            //   → 全拆。同一秒 `notify: cover … at=347ms` 说明面板其实早就收了。
            //
            // 判据里第一条 `SBLockScreenManager.isUILocked == 1` 在「点通知」
            // 这一刻**必然为真**（那次点击自带 `unlock=1` 的解锁标志），所以这条闸
            // 在通知路径上 100% 命中 —— 它和「点通知出浮窗」在逻辑上互斥，不是
            // 数值调不好的问题。遮挡只能当「失败时不回落全屏」的兜底闸（见
            // `pollForScene` 两个出口），不能当收卡条件。
            // 0.0.55 — 空闲熄屏的续命拍。放在节拍最前面：这一条与画面、与
            // settings 都没有关系，后面的任何一个 guard 都不该把它挡掉。
            if Date().timeIntervalSince(idleAt) >= 20 {
                idleAt = Date()
                let idleMask = AevonIdleTimerKick()
                if idleProbe < 8 {
                    idleProbe += 1
                    Log.write("win: idle timer kick mask=" + String(idleMask)
                              + " n=" + String(AevonIdleTimerCount()))
                }
            }
            // 0.1.34 — 解锁了一次：退避计数归零 + 重挂承载面。
            //
            // V110 的日志死在这里：锁屏前 `misses` 已经攒到 3、`wakes` 也用完了，
            // 解锁后 `cs` 一直是 0（`keepalive beat … cs=0` 一直到日志末），
            // 时钟照常一拍一拍地写，但一次都没有再试过推前台 —— 用户看到的就是
            // 「必须重新打开悬浮窗」。这三个计数是为「系统暂时不给」设计的，
            // 解锁是一次全新的开始，不该继承锁屏期间那三次失败。
            if host.reviveTick != seenRevive {
                seenRevive = host.reviveTick
                misses = 0
                wakes = 0
                dropped = 0
                deadBeats = 0
                // 不等下面那套「fg 不等于 1 才推」的存量判断：解锁后我们要的是
                // 一次**主动**的重新接上，而不是再等一拍看系统脸色。
                //
                // 0.1.35 — 这一句就是 2026-11-05 18:31 那次安全模式的位置。
                // `AevonPushForeground` 里读一个已经释放的 settings（根因与修法
                // 写在那个函数开头）。这里补上死亡标记：万一它还是死在这，
                // 下一次启动会看到 `win: previous run died at WIN-PUSH` 并把推前台
                // 整条禁掉 —— 少一个功能，好过一次安全模式。
                if !marked { mark("WIN-PUSH"); marked = true }
                _ = AevonPushForeground(scene)
                _ = AevonWakeScene(scene)
                host.reviveCanvas()
                Log.write("win: revive after unlock tick=" + String(seenRevive))
            }
            let live = value(of: scene, "settings")
            let fg = live.map { AevonBoolOf($0, "isForeground") } ?? -1
            let bg = live.map { AevonBoolOf($0, "isBackgrounded") } ?? -1
            // 0.0.73 — 承载面的位置每拍看一次。系统每次写 scene settings 都会把
            // `_UIScenePresentationView` 的 `frame` 重设成 scene 的 frame（原点 0,0、
            // transform 单位阵），卡片于是按 1:1 裁掉右侧与底栏 —— Aevon(63) 的
            // 「第一次打开内容尺寸不对、必须手动缩放一下」就是这一条。解释与量出来
            // 的数在 `FloatHost.reapplyPlacement`。这里只是让它自己回来：稳态
            // 200 ms 一拍，差 0.4% 就重写，值只在被抹掉的那几拍才写日志。
            _ = host.reapplyPlacement("beat")
            // 0.0.63 — 逻辑尺寸的看门狗，稳态两秒一次（10 拍 × 200 ms）。目标值
            // 记在 FloatHost 里（开窗与换比例时更新），真实值当场从 scene 的
            // settings 读 —— 对不上就重写一次，前四次各记一行。
            //
            // 0.1.50 — 两处改动：①目标从「尺寸」变成「矩形」，原点也参与对账
            // （键盘态场景要跟卡片一起下移到 215）；②键盘态改成每拍查，因为
            // 键盘弹起只有 0.25 s，等到第 10 拍（2 s）时用户早就看见画面在错的
            // 位置上闪过了。
            if beat % 10 == 0 || host.isKeyboardFilled || host.isKeyboardSettling {
                if !host.isKeyboardFilled {
                    // 键盘收起 ⇒ 原点归零这一趟必须重新允许，否则「写过 215 又被
                    // 判成不认」的标志会一直拦着还原。
                    originMisses = 0
                    originParked = false
                }
                let want = host.canvasFrame
                if want.height > 200 {
                    let got = AevonSceneFrameOf(scene)
                    // 0.4.4 — **「原点被拒」不再一闩到底。**
                    //
                    // 0.1.51 起这里是 `originParked ? got.origin.y : want.origin.y`：
                    // 连续 8 次推不动原点就当成「这个系统不收原点」，之后整个键盘
                    // 会话内再也不试。可那 8 次全是「写了没门」的形状（见
                    // `AevonPushSceneFrameStrict` 上面 Aevon(290) 的现场）——
                    // 不是系统拒绝，是我们没把门敲开。闩上之后卡片在 215、场景在 0
                    // 就一直错着，正是用户报的那条横带。
                    //
                    // 现在闩只降速不放弃：每 30 拍（约 3 s）再试一次真原点。
                    let retryOrigin = !originParked || beat % 30 == 0
                    let wantOrigin = retryOrigin ? want.origin.y : got.origin.y
                    if got.width > 0,
                       abs(got.width - want.width) > 1 || abs(got.height - want.height) > 1
                        || abs(got.origin.y - wantOrigin) > 1 {
                        let door = AevonPushSceneFrame(scene)
                        // 原点要不要判「系统不收」：只看「目标原点非 0，回读还是旧值」。
                        if retryOrigin, abs(want.origin.y) > 1,
                           abs(got.origin.y - want.origin.y) > 1 {
                            originMisses += 1
                            if originMisses == 8, !originParked {
                                originParked = true
                                Log.write("win: frame origin rejected misses="
                                          + String(originMisses) + " door=" + String(door))
                            }
                        } else {
                            originMisses = 0
                        }
                        if drifts < 4 {
                            drifts += 1
                            // 0.1.51 — 补 `wrote` / `armed` 两个计数。0.1.50 的
                            // `door=0` 有两种完全不同的含义：目标没登记（armed=0，
                            // 我们自己的错）或登记了但判「不用写」（wrote 不涨）。
                            // 只看 door 分不清，那一次就白烧了一版。
                            Log.write(String(format: "win: frame drift now=%.0fx%.0f@%.0f want=%.0fx%.0f@%.0f door=%ld wrote=%ld armed=%ld",
                                             got.width, got.height, got.origin.y,
                                             want.width, want.height, want.origin.y, door,
                                             AevonFrameWriteCount(), AevonFrameArmedCount()))
                        }
                    }
                }
            }
            // 0.2.0 — 这里原来每拍调一次 `FloatHost.setSystemCovered(AevonSystemCovered())`。
            // 那套「整层隐藏」已经整段删除（见 FloatHost 里那段注释）。
            // 0.2.2 — 搬到这一拍开头的那次「盖着就收卡片」也删了：点通知这一刻
            // `isUILocked` 必然为真，它把每一次通知→浮窗都自己拆了（Aevon(171)）。
            // 这一拍现在只读数，不因遮挡做任何拆除。
            //
            // 0.2.6 — 「盖着」不再当**拆除**的理由，改当**让开**的理由。用户报的是
            // 「悬浮窗又在通知中心和控制中心出现了」：卡片窗口 level=101 确实压在
            // 面板之下那一层，但面板是半透明/带模糊的，卡片会从缝里透出来，而且在
            // 控制中心那种整屏模糊里它就是一整块浮在上面。
            //
            // 判据用 `AevonSystemPanelUp()`：只问 CoverSheet / ControlCenter，
            // **不问 `isUILocked`** —— 后者在点通知那一刻恒真，拿它做让开判据会让
            // 每一次「通知 → 浮窗」先隐身到真正解锁为止，那就是 0.2.2 那条路的变形。
            // 而 CoverSheet 本身就是锁屏界面，锁屏时 `isPresented` 为真，已经覆盖。
            //
            // 动手是 alpha（见 `FloatHost.stepAside`）：不关窗、不拆 scene、不动几何，
            // 面板退掉后一次赋值就回来。时序上也不会闪 —— 收面板在 0.10~0.35 秒，
            // 卡片要到 ~0.5 秒才建好，建好时 `isPresented` 已经是假。
            FloatHost.stepAside(AevonSystemPanelUp())
            // 0.0.50 — 画面本身的两个读数。`fg` 是我们自己写进去的，切换 App
            // 时它不变；`contentState` 才是「现在有没有画」，`level` 是母本那
            // 三件套里的第二件。Aevon(48) 的四份日志里 fg 一次没掉过，所以黑
            // 从来不是这条时钟看见的。
            let content = AevonContentStateOf(scene)
            let level = AevonSceneLevel(scene)
            // 0.0.91 — 每拍都要这个数（不只是写日志那一拍）：`cs=0 且
            // sublayers=0` 是「进程不在了」的形状 —— 只剩外壳、里面没有层。
            let sublayers = view.layer.sublayers?.count ?? 0
            // 0.0.59 — 首帧不在这里露。原来这一行是 `if content == 2 { reveal }`，
            // 而它是 200 ms 一拍 —— 冷启动的「先出现再闪」有一半时长就是这一拍
            // 攒出来的。现在交给 `watchFirstFrame`（50 ms 一拍、连续两拍确认）。
            // Read before the push, so the line below describes what the system
            // did rather than what this turn did.
            let attempts = AevonDeactStrippedCount()
            if attempts != deact {
                deact = attempts
                // 0.2.57 — 三处改动，都是为了这一行能直接读。
                //
                // ① 数换成「真正被清零的次数」。旧数 `AevonDeactCount()` 数的是
                //    钩子被调了几次，其中一大半 `reasons` 本来就是 0（系统在重新
                //    声明「可以睡」）。Aevon(198) 里 45 秒就涨到 26，同一秒还会
                //    打印两遍，看上去像场景被反复收走 —— 实际被拦下的只有 6 次。
                // ② 带 `reasons=`：32 / 34 / 2 这几种位对应不同的系统动作。
                // ③ 带 `b=`：多窗时两张卡的 watcher 读的是**同一个**全局计数，都会
                //    各打一行，于是同一个 `#10` 出现两次。补上 bundle 之后，
                //    「两台是同一件事」和「两台各是各的」一眼可分。
                //
                // 0.2.57 — 先落成三个局部量再拼。这一整段在 `keep` 那个大闭包里，
                // 直接写成一长串 `+`（里面还夹着 `??`）会让 Swift 的类型检查器
                // 在 2185 行超时 —— CI 上就是栽在这里，不是逻辑错。
                let whyReasons = Int(AevonDeactLastReasons())
                let whoBundle = bundleID ?? "-"
                let deactLine = "win: scene deactivation #" + String(attempts)
                    + " fg=" + flag(fg) + " cs=" + String(content)
                    + " sub=" + String(sublayers) + " wake=" + String(wakes)
                    + " reasons=" + String(whyReasons) + " b=" + whoBundle
                Log.write(deactLine)
            }
            var door = 0
            if fg == 1 {
                misses = 0
            } else if misses < 3 {
                if !marked { mark("WIN-PUSH"); marked = true }
                door = AevonPushForeground(scene)
                // 0.0.43 — door 3 is the transition-context write, the one that
                // crosses the scene bridge; it counts as a write like 1 and 2.
                // Door 4 means "already front, nothing spent": neither a write
                // nor a miss, which is exactly what the old 3 was to this clock.
                if door == 1 || door == 2 || door == 3 {
                    wrote += 1
                } else if door == 0 {
                    misses += 1
                }
            }
            if fg == 1 && marked {
                unmark()
                marked = false
            }
            // 0.0.50 — 掉画判定。`beat >= 2` 是因为第一拍上挂起启动的 scene
            // 本来就是 0，那不是掉画，是还没来得及画。
            //
            // 掉下去的那一刻记一行，回来的那一刻记一行带毫秒数 —— 下一份日志
            // 就能直接回答「黑了多少毫秒」，不用再靠肉眼对时间戳。
            var wake = 0
            // 0.2.54 — 先记账再判掉画。见 `sawContent` 那一段：冷启动的
            // `cs=1` 是过渡态，不是黑。
            if content == 2 { sawContent = true }
            // 只排掉「还没出过首帧、读数停在 1」这一种。`cs=0` 照旧算掉画 ——
            // 那时 scene 是真的没准备好，写一次 settings 把它推起来是这条兜底
            // 本来要做的事，不能跟着 `cs=1` 一起被关掉。判据窄一格，兜底少丢一件。
            let transitional = (content == 1 && !sawContent)
            if beat >= 3, content >= 0, content != 2, !transitional {
                if dropped == 0 {
                    dropped = beat
                    droppedAt = Date()
                    let one = String(format: "%.1f", level)
                    // 0.2.54 — 补 `sub=`。「cs 掉下去」有两种完全不同的病：
                    // 有层（进程活着，只是没渲染）与零层（进程没了）。旧行只有
                    // cs 与 fg，两者分不开，而它们的处置正好是两条路 —— 前者
                    // 写 settings 有用，后者只能关卡重开。
                    Log.write("win: picture dropped cs=" + String(content)
                              + " lvl=" + one + " fg=" + flag(fg)
                              + " sub=" + String(sublayers))
                }
                // 0.0.52 — 唤醒从「掉画期间每拍都写」降成**兜底**：一段黑最多
                // 三次，其余拍只读数。母本的做法是事前改参数（AevonScene.m 的
                // intercept 段），它成功的时候这里一次都不该被走到；它没成功的
                // 时候，反复重申也只是在重提交同一个值 —— 0.0.49 的日志里三次
                // 掉画各写了一笔，黑还是 60/63/313 ms，多写的那几拍并不会更早。
                if wakes < 3 {
                    wake = AevonWakeScene(scene)
                    if wake != 0 { wakes += 1 }
                }
            } else if dropped != 0 {
                let ms = Int(Date().timeIntervalSince(droppedAt) * 1000)
                Log.write("win: picture back after " + String(ms) + "ms"
                          + " beats=" + String(beat - dropped)
                          + " wakes=" + String(wakes))
                dropped = 0
                // 0.0.51 — 这一段黑结束了，额度还回去。配额若是整场会话共用，
                // 切几十次 App 之后就用完了，那时候这段黑就又没人管 —— 一次
                // 修复不应该自带保质期。
                AevonWakeReset()
            }
            // 0.0.91 — 「掉下去之后**再也没回来**」和「掉一下又回来」是两件事。
            //
            // 前者在 Aevon(80)/Aevon(81) 里都是同一个形状：`cs=0`、`sublayers=0`、
            // App 侧日志停在某一秒，而卡片窗口、圆角、投影全在 —— 用户看到的就是
            // 「浮窗消失，只留一圈白色光晕」。掉画的兜底（写 settings）救不回它：
            // settings 管的是「这个场景该不该睡」，管不了「进程还在不在」。
            //
            // 于是：连续两拍确认，然后关卡、0.6 秒后用同一个 bundle 重开。
            //
            // 0.2.54 — 门从 `dropped != 0` 换成 `sawContent`。它们本来指同一件
            // 事（「曾经有过画」），但 `dropped` 会在 `picture back` 那一刻归零，
            // 而进程死掉时画面回来这一行往往压根不写 —— 用 `dropped` 当门，等于
            // 让判据依赖另一段代码有没有跑到。`sawContent` 是这张卡自己的记忆，
            // 不欠任何人的时序。
            if beat >= 6, sawContent, content == 0, sublayers == 0 {
                deadBeats += 1
            } else {
                deadBeats = 0
            }
            if deadBeats >= 2, let deadBundle = bundleID {
                Log.write("win: scene dead cs=0 layers=0 beats=" + String(deadBeats)
                          + " bundle=" + deadBundle)
                closeCard("scene dead")
                reviveCard(deadBundle)
                return
            }
            // Eight beats up front say how the first push went; after that one
            // line in four is enough to see the card settle or fail. Two lets,
            // because one long concatenation is a type-checker timeout (0.0.30
            // lost a build to exactly that).
            //
            // 0.0.33 — the card can now stay all afternoon, so the tail thins
            // out again at ten seconds a line. A clock that writes 14,400 lines
            // an hour is a log nobody can read and a file the operator has to
            // clear.
            var due = false
            if beat <= 8 {
                due = true
            } else if beat <= 40 {
                due = beat % 4 == 0
            } else {
                due = beat % 40 == 0
            }
            if due {
                let state = " fg=" + flag(fg)
                    + " bg=" + flag(bg)
                    + " door=" + String(door)
                    + " wrote=" + String(wrote)
                    + " misses=" + String(misses)
                let layers = String(sublayers)
                let shape = " cs=" + String(content)
                    + " lvl=" + String(format: "%.1f", level)
                    + " wake=" + String(wakes)
                // 0.0.52 — 两个拦截点的计数跟在后面。切一次 App，`ic` 动了说明
                // 系统真的把 settings 交给我们改；`iw` 动了说明那一笔已经被改成
                // 前台档。两个都不动，就是两个候选选择子在真机上一条都不走 ——
                // 那是下一版的起点，不是猜测。
                let gates = " ic=" + String(AevonInterceptCount())
                    + "/" + String(AevonInterceptWrites())
                Log.write("win: keepalive beat " + String(beat) + state
                          + " reasons=" + reasonsOf(scene)
                          + " sublayers=" + layers + shape + gates)
            }
            // 0.0.91 — 每 2 秒把 App 侧日志取回来一次。
            //
            // 0.0.90 只在「开卡 +4 秒」与「关卡」两个时刻取，所以进程一死，
            // 死前那几行必然留在它自己的 tmp 里、下一次开卡才被读走 ——
            // 三轮都指不出死因，一半原因在这里。稳态 0.2 s 一拍 ⇒ 10 拍 = 2 s。
            if beat % 10 == 0 {
                drainAppLog("beat", quiet: true)
            }
            // The clock runs for the life of the card, not for eight seconds.
            // `stopped` is the only exit, and `closeCard` is the only thing that
            // sets it.
            //
            // 0.0.40 — 250 ms is a quarter of a second of black whenever the
            // scene is not in front, and that is exactly the length of the gap
            // Aevon(38) describes. While anything is off the beat tightens to
            // 60 ms, so the recovery costs a few frames instead of a blink. The
            // steady state keeps the old interval: a clock that writes 16 lines a
            // second forever is a log nobody can read.
            //
            // 0.0.50 — 判据从 `fg` 换成 `contentState`：没有画也按「不在前台」
            // 处理。稳态从 250 ms 收到 200 ms，掉画期间仍然是 60 ms。
            let calm = (fg == 1 && content == 2)
            let wait: Double = calm ? 0.2 : 0.06
            if !stopped {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { keep() }
            } else if marked {
                unmark()
            }
        }
        // 0.2.2 — 这里 0.2.0 是「建卡末步再问一次遮挡，盖着就 `closeCard`」，
        // 整段删掉。理由与保活时钟那处相同（见那里）：点通知这一刻 `isUILocked`
        // 必然为真，于是每一次「通知 → 浮窗」都在建好之后立刻被自己拆掉，
        // 用户看到的就是「不全屏、也不出窗」。
        //
        // 母版没有这道闸。锁屏画面由 CoverSheet 窗口盖着（层级远高于卡片的 101），
        // 卡片在那儿露不出来；解锁后自然显现 —— 不需要我们收。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { keep() }

        // 0.4.0 — 「托管就绪」这一格整块删除（原来 60 行）。它唯一的作用是等
        // `hostedLayers >= 1` 之后调 `AevonColdCardReady`，告诉 C 侧的冷启动分享
        // 那条链「现在可以把扣着的请求投进去了」。这一版没有那条链。

        // Nothing on this screen is hidden any more. 0.0.24 hid one view,
        // 0.0.25 hid the wrong window, 0.0.26 emptied every app-level window and
        // the operator got a black phone that eight seconds of restoring did not
        // bring back: a scene's layers are hosted by one container at a time, so
        // a card that holds them leaves the full-screen container empty, and an
        // empty container paints its own black. The mother ship solves this by
        // never being in that position — the app is in the background and the
        // desktop is the backdrop — so what is left here is one reading, one
        // second later, of whether a kept-alive scene really is still drawing.
        // One reading, one second in, of whether a kept-alive scene is really
        // still drawing — the difference between a card that works and 0.0.28's
        // black one. The container's hosted count is on the same line, because
        // `hosted=0` and `hosted=2` are the two answers this line exists for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let container = value(of: view, "hostContainerView") ?? view.subviews.first {
                NSStringFromClass(type(of: $0)).contains("HostContainer")
            }
            Log.write("win: after 1s hosted=" + String(count(of: container, "hostedLayers"))
                      + " nonHosted=" + String(count(of: container, "nonHostedLayers"))
                      + " sublayers=" + String(view.layer.sublayers?.count ?? 0)
                      + " reasons=" + reasonsOf(scene)
                      + " hosting=" + flag(AevonBoolOf(presenter, "isHosting")))
        }

        // 0.0.33 — no more eight second death. The card stays until the operator
        // closes it, drags it or resizes it; the teardown that used to be this
        // timer is `closeCard` above, called by the button.
        //
        // 0.4.50 — **十分钟上限整段删除。**
        //
        // 0.0.33 留了 `asyncAfter(600)` + `closeCard("ten minute cap")`，理由是
        // 「一张忘了关的卡会让 App 一直前台渲染、耗电」。用户 2026-11-13 报的
        // 第 2 条正是它：「悬浮窗播放抖音时，一段时间后抖音悬浮窗会自动关闭」。
        // 对播放视频这件事来说 10 分钟不是上限，是**一半**：一个稍长的视频就会
        // 演到一半被我们拆掉，而且拆得不留痕迹（日志里只有一行 cap）。
        //
        // 这张卡的所有权应当只有操作者：关窗按钮、拖出屏幕、放大缩小，以及
        // `scene dead`（画面真的没了，那时留着只是一块黑）。母版 Stheno 也从不
        // 按时间拆卡 —— 它整份二进制里没有任何以秒计的收卡计时器。
        //
        // 想找回旧行为：把这一段恢复成
        //   DispatchQueue.main.asyncAfter(deadline: .now() + 600.0) {
        //       closeCard("ten minute cap")
        //   }
    }

    /// The one witness a kill leaves behind: which call the process was inside.
    /// A getter never kills, but `activate` is not a getter, and this is the only
    /// way the next run can name it instead of inferring it from where the log
    /// stops.
    private static func mark(_ step: String) {
        try? step.write(toFile: Aevon.winStepPath, atomically: true, encoding: .utf8)
    }

    private static func unmark() {
        try? FileManager.default.removeItem(atPath: Aevon.winStepPath)
    }


    /// Drains the C-side note buffer into the log, one line each. Called before
    /// every call that could end the process: an undrained note is lost work.
    private static func emitNotes(_ text: String?, cap: Int = 40) {
        guard let text = text, !text.isEmpty else { return }
        var printed = 0
        for raw in text.split(separator: "\n") {
            if printed >= cap { Log.write("win: …notes truncated at " + String(cap)); return }
            Log.write("win: " + raw.trimmingCharacters(in: .whitespaces))
            printed += 1
        }
    }

    /// -1 is "no such method", which is a different answer from 0.
    private static func flag(_ value: Int) -> String {
        switch value {
        case 1:  return "yes"
        case 0:  return "no"
        default: return "absent"
        }
    }

    /// Object-returning getter, and **only** an object-returning one.
    ///
    /// 0.1.38 — this is the call that put the phone into safe mode, five times
    /// in one afternoon. `hungSnap` asked for `contentState`, which returns
    /// `FBSceneContentState`: a plain integer (2 = ready). `perform(_:)` hands
    /// that back as an `id`, and the very next retain — `swift_unknownObjectRetain`
    /// — dereferences pointer 0x2. The crash report says exactly that:
    /// `EXC_BAD_ACCESS / SIGSEGV, KERN_INVALID_ADDRESS at 0x2`, on SpringBoard's
    /// main thread. `responds(to:)` cannot help: it answers "does it have this
    /// selector", never "what does it return".
    ///
    /// The rule now lives in `AevonSafe`, which every binary shares, so the two
    /// halves cannot drift apart again.
    private static func value(of object: NSObject, _ key: String) -> NSObject? {
        AevonSafe.object(object, key)
    }

    /// The first real character of a method's return type, or nil when the
    /// method cannot be found. Qualifiers (`r` const, `n` in, `o` out, `N` inout,
    /// `R` byref, `V` oneway) may sit in front of it and are skipped.
    ///
    /// Deliberately class-only: an object that answers through message
    /// forwarding has no method here, and refusing is the right answer for a
    /// probe — one missing column beats one dead SpringBoard.
    private static func returnKind(_ object: NSObject, _ sel: Selector) -> Character? {
        guard let method = class_getInstanceMethod(type(of: object), sel),
              let types = method_getTypeEncoding(method) else { return nil }
        var body = Substring(String(cString: types))
        while let first = body.first, "rnNoORV".contains(first) { body = body.dropFirst() }
        return body.first
    }

    /// A scalar-returning getter, read through the ABI instead of `perform`.
    ///
    /// Every integer return comes back in x0 on arm64, so one `UInt64`-shaped
    /// call covers `Q q I i L l C c S s B`; the width is then cut by the
    /// encoding so a 32-bit return cannot pick up junk from the high half.
    /// Structs, floats and objects are refused — -1 stays "could not read",
    /// which is a different answer from 0.
    private static func integer(of object: NSObject, _ key: String) -> Int {
        let sel = NSSelectorFromString(key)
        guard object.responds(to: sel),
              let method = class_getInstanceMethod(type(of: object), sel),
              let kind = returnKind(object, sel) else { return -1 }
        guard "QqIiLlCcSsB".contains(kind) else { return -1 }
        let call = unsafeBitCast(method_getImplementation(method),
                                 to: (@convention(c) (AnyObject, Selector) -> UInt64).self)
        let wide = call(object, sel)
        switch kind {
        case "Q", "q", "L", "l": return Int(bitPattern: UInt(truncatingIfNeeded: wide))
        case "I": return Int(wide & 0xFFFF_FFFF)
        case "i": return Int(Int32(truncatingIfNeeded: wide))
        case "S": return Int(wide & 0xFFFF)
        case "s": return Int(Int16(truncatingIfNeeded: wide))
        case "C", "B": return Int(wide & 0xFF)
        case "c": return Int(Int8(truncatingIfNeeded: wide))
        default: return -1
        }
    }

    /// Answers -1 for "no such method" and -1 for "not a list", which keeps a
    /// missing counter from reading as an empty one: `layers=0` is a fact about
    /// the scene, `layers=absent` is a fact about the probe.
    private static func count(of object: NSObject?, _ key: String) -> Int {
        guard let object = object, let list = value(of: object, key) as? NSArray else {
            return -1
        }
        return list.count
    }

    /// Called once at boot, before anything else touches the runtime. If the
    /// last scan left a marker, the class named in it is the one that stopped
    /// the process — a fault, a deadlock or a jetsam kill all leave the same
    /// log, and only this file tells them apart. The name is then added to the
    /// skip list, so the next scan steps over it and the dump keeps growing
    /// across runs instead of dying in the same place forever.
    static func reportPreviousDeath() {
        let manager = FileManager.default
        // Before anything else, and before the early return below: a fault can
        // arrive while the walk is still naming classes, and the number of the
        // signal is the one fact that does not have to be inferred from where
        // the log stops. No file at all is also an answer — the process was
        // killed, not faulted, and that is a different bug in a different place.
        if let fault = manager.contents(atPath: Aevon.callFaultPath), fault.count >= 4 {
            var value: UInt32 = 0
            for offset in 0..<4 {
                value |= UInt32(fault[offset]) << (8 * UInt32(offset))
            }
            let names: [UInt32: String] = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
                                          10: "SIGBUS", 11: "SIGSEGV"]
            Log.write("calls: previous run faulted with signal " + String(value)
                      + " " + (names[value] ?? "unrecognised"))
            try? manager.removeItem(atPath: Aevon.callFaultPath)
        }
        guard manager.fileExists(atPath: Aevon.callStatePath) else { return }
        defer { try? manager.removeItem(atPath: Aevon.callStatePath) }
        guard let data = manager.contents(atPath: Aevon.callStatePath), data.count > 4 else {
            Log.write("calls: previous scan died without naming a class")
            return
        }
        // Byte by byte rather than `withUnsafeBytes { load(as:) }`: a marker
        // that dies on an alignment trap would be a new reason to respring.
        var index: UInt32 = 0
        for offset in 0..<4 {
            index |= UInt32(data[offset]) << (8 * UInt32(offset))
        }
        let name = String(decoding: data.dropFirst(4), as: UTF8.self)
        guard !name.isEmpty, !name.contains("\n") else {
            Log.write("calls: previous scan died at " + String(index) + " unnamed")
            return
        }
        Log.write("calls: previous scan died at " + String(index) + " " + name)
        // Which image the name belongs to. `JSExport` is a name; the framework
        // it comes from is the answer to "why is this one different".
        if let cls = NSClassFromString(name), let image = class_getImageName(cls) {
            Log.write("calls: that class lives in " + String(cString: image))
        }
        // 0.4.0 — 后面那段「把这个类写进 `call.skip` 跳过名单」删除了。
        // 跳过名单唯一的消费者是 `runCalls` 那套逐类试调，普查本身已经不存在，
        // 再写一份没人读的名单只是多一次文件写。
    }

    // MARK: - 0.0.59 首帧观察器

    /// 首帧什么时候到，由这个 50 ms 的心跳回答，不再等保活时钟。
    ///
    /// 三条判据，缺一条都不 reveal：
    ///   ① `contentState == 2` —— scene 自答「有内容」；
    ///   ② `layerManager.layers != 0` —— 层真的递交了（0 = 一个都没有；-1 = 探针
    ///      读不到，不能当成没有，否则卡片永远不出来）；
    ///   ③ 连续两拍都成立 —— 多出来的那一拍就是「这一帧已经上屏」的余量。
    ///      0.0.58 缺的正是这个余量：它照着 contentState 立刻淡入，淡入的前半
    ///      段画面还是黑的，后半段画面才来，一次渐变里夹一次跳变成了一闪。
    ///
    /// 观察器在 reveal、超时或卡片消失时自己停 —— SpringBoard 的主线程上不该
    /// 留一个永久心跳。
    private static func watchFirstFrame(_ host: FloatHost, scene: NSObject) {
        let started = Date()
        var beats = 0
        var ready = 0
        func tick() {
            if !host.waitingForFrame { return }
            beats += 1
            let content = AevonContentStateOf(scene)
            let layers = count(of: value(of: scene, "layerManager"), "layers")
            let drawn = (content == 2) && (layers != 0)
            ready = drawn ? ready + 1 : 0
            if ready >= 2 {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write(String(format: "win: first frame watch beats=%ld cs=%ld layers=%ld waited_ms=%ld",
                                 beats, content, layers, ms))
                host.revealContent("first frame")
                // 0.0.74 — 两次轻推撤掉了。
                //
                // 0.0.72/0.0.73 为了让 App 重排推了两次 17 pt（-17 → 还原 → +17 →
                // 还原），代价是操作者看得见的两次「跳一下」：Aevon(64) 的原话是
                // 「悬浮窗的内容会自己跳动，然后完成重排」。而 Aevon(64) 的日志证明
                // 这两推是多余的 —— 开卡时 App 自己就收到了
                // `app: page transition h=717 last=932`，之后 `app: geom` 里
                // scene / win / root / 顶栏 / 底栏 全部已经是 717 版的坐标。
                //
                // 「第一次打开内容尺寸不对」真正的病根是承载面被系统按 `scene.frame`
                // 重设（0.0.73 的 `placement put back`），那一条照旧，而且它只写
                // `transform` 与 `center`，不引起重排，所以完全看不见。
                for delay in [0.02, 0.35, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak host] in
                        guard let host = host, host.isUp else { return }
                        _ = host.reapplyPlacement("after first frame")
                    }
                }
                // 桥接的读数在 App 进程里写，1.2 s / 3.2 s 各一次 —— 4 s 后来取。
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    drainAppLog("after first frame")
                }
                return
            }
            // 3.2 s 与 `FloatHost.show` 里的 3 s 兜底错开 0.2 s：谁先到都行，
            // 但两边都不要在已经露出之后继续跑。
            if Date().timeIntervalSince(started) > 3.2 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick() }
        }
        // 第一拍也要让出去：`activate` 刚发完，同一 runloop 里读到的 layers 一定
        // 还是旧值。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick() }
    }

    // MARK: - 0.2.25 空的 app-switcher 页

    /// 被藏起来的那一页，以及它原来的 alpha / 交互开关。关卡时原样还回去 ——
    /// 不还，用户关掉卡片之后那张页还是空的。
    private static var hiddenPage: (view: UIView, alpha: CGFloat, touch: Bool)?







    /// 关卡时把那一页还回去。没有藏过就什么都不做。
    private static func restoreHiddenPage() {
        guard let saved = hiddenPage else { return }
        saved.view.alpha = saved.alpha
        saved.view.isUserInteractionEnabled = saved.touch
        hiddenPage = nil
        Log.write("win: empty page restored "
                  + NSStringFromClass(type(of: saved.view)))
    }


    // MARK: - Runtime helpers

    /// Same guard as RingHost: `UIApplication.shared` is force-unwrapped, and a
    /// probe must never be the reason a phone crashes.
    private static func sharedApplication() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: selector),
              let unmanaged = meta.perform(selector),
              let application = unmanaged.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        return application
    }

}









/// 0.4.4 — 交还整屏的补写阶梯。
///
/// 关卡那一拍写完**不算完**：`AevonPushSceneFrame` 的 0 有两个含义，「不用写」
/// 和「写了但三道门都没开」。旧代码把 0 当「不用写」，随后立刻清掩码 —— 于是
/// 「写了没门」的那一趟之后既没有补写、也没有目标了，那个 App 在系统眼里永远
/// 是 717：回到全屏时只剩上面 717 有内容，下面 215 pt 是窗口的黑色
/// （Aevon(290) 用户截图，黑边精确起在 717）。
///
/// 三级阶梯（0.15 / 0.45 / 0.90 s）各强制提交一次（`AevonScreenBack`：frame +
/// display + 参考尺寸一起、不吃节流、不判重、不吃登记表），**落地即止**；最后一拍
/// 无论如何清掩码 —— 不清，intercept 钩子会一直按我们登记的目标改它，那个 App
/// 就再也拿不回整屏。
///
/// 三拍是**各自独立**排的，不是「上一拍失败才排下一拍」：`AevonScreenBack` 幂等，
/// 而递推会把时间叠成 0.15 → 0.60 → 1.50 s，比用户手里的动作还慢。
///
/// 判据沿用 0.0.98：按名字看这个 App 有没有被重新登记。0.0.75 起这里是
/// `!cardUp`，多窗之后「有卡」不等于「这个 App 又被打开了」，关掉主窗而留着一个
/// 停靠小窗时那条整屏恢复会被无谓地跳过；真正要防的「0.3 s 内重开同一个 App」
/// 必须按名字判，不能按数量判。
private func restoreScreenBack(closingBundle: String, scene: NSObject?,
                               restoredDoor: Int = -1) {
    // 0.4.54 — 交还已经**穿过 scene 桥**（`restoredDoor == 3`）而且回读就是整屏：
    // 三拍补写一次都不发。
    //
    // 337 每一次关卡都是这个形状：
    //   `screen back … door=3 frame=430x717@0 want=430x932`   ← 真的写了
    //   `scene frame restored door=3 wrote=2`                ← 桥也过了
    //   `screen back … door=3 frame=430x932@0 want=430x932`  ← 已经是整屏了
    //   `frame restore again door=3 step=1 / step=2 / step=3` ← 却又强制提交三次
    // `AevonScreenBack` 是「不吃节流、不判重、不吃登记表」的强制提交：对同一个
    // 值再敲三次门，App 就要再收三次 settings、再排三次版 —— 而用户看到的
    // 「从悬浮窗切回全屏时视频断层」正落在这一段里。0.4.4 那条阶梯是为
    // 「写了没门」（door=0）准备的，桥已经过了就没有它的用武之地。
    // 保留：`door` 不是 3、或回读不是整屏 —— 阶梯原样跑。
    if restoredDoor == 3, let scene = scene {
        let got = AevonSceneFrameOf(scene)
        let full = UIScreen.main.bounds.size
        if full.height > 200.0,
           got.height >= full.height - 1.0, got.width >= full.width - 1.0 {
            Log.write("win: frame restore settled door=3 (ladder skipped)")
            clearFrameTarget(closingBundle)
            return
        }
    }
    let ladders: [Double] = [0.15, 0.45, 0.90]
    for (index, delay) in ladders.enumerated() {
        let step = index + 1
        let last = step == ladders.count
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak scene] in
            guard let scene = scene else {
                if last { clearFrameTarget(closingBundle) }
                return
            }
            let armed = AevonHookArmedList()
            if !closingBundle.isEmpty, armed != "no", armed.contains(closingBundle) {
                if last {
                    Log.write("win: frame restore skipped, " + closingBundle + " reopened")
                }
                return
            }
            // 0.4.56 — 「已经是整屏了」这一问必须**每一拍都问**。
            //
            // 0.4.54 只在进阶梯之前问了一次，而那一问发生在 `AevonScreenBack`
            // 刚写完、模型还没回读到的几十毫秒里 —— 338 里三次关卡全是
            // `screen back … frame=430x932@0 want=430x932`（已经是整屏）却照样
            // `frame restore again step=1/2/3`，同一个值被强制提交三次。
            // `AevonScreenBack` 不吃节流、不判重，每提交一次 App 就要再收一次
            // settings、再排一次版 —— 切回全屏那一刀「视频断层」正落在这里。
            if restoredDoor == 3 {
                let got = AevonSceneFrameOf(scene)
                let full = UIScreen.main.bounds.size
                if full.height > 200.0,
                   got.height >= full.height - 1.0, got.width >= full.width - 1.0 {
                    Log.write("win: frame restore settled door=3 step=" + String(step)
                              + " (already full)")
                    clearFrameTarget(closingBundle)
                    return
                }
            }
            let door = AevonScreenBack(closingBundle.isEmpty ? nil : closingBundle, scene)
            if last || door > 0 { clearFrameTarget(closingBundle) }
            Log.write("win: frame restore again door=" + String(door)
                      + " step=" + String(step))
        }
    }
}

/// 只抹掉这一次交还的目标（`closingBundle` 为空 = 全局）。
private func clearFrameTarget(_ closingBundle: String) {
    if closingBundle.isEmpty {
        AevonSceneFrameClear()
    } else {
        AevonSceneFrameClearBundle(closingBundle)
    }
}

/// 0.4.65 — App 自己请求横屏了（见 `AevonScene.m` 的 `AevonLandscapeAsk`）。
///
/// 只做一件事：把承载它的那张卡从竖版切到 16:9 视频窗。返回 1 = 真切了，
/// 0 = 没有这张卡。
///
/// 0.4.67 — 多带一块「视频区」（App 世界的坐标，见 `AevonRotFindVideo`）。
/// 卡片拿它对准画面；全零 = 没量到，退化成世界正中。
///
/// ⛔ 不在这里改 scene：`setLandscape` 自己会算卡片几何。两处各写一份，
/// 结果一定是「卡片横了、App 还是竖的」。
@_cdecl("AevonCardLandscapeEnter")
public func AevonCardLandscapeEnter(_ bundle: UnsafePointer<CChar>?,
                                    _ vx: Double, _ vy: Double,
                                    _ vw: Double, _ vh: Double) -> Int32 {
    guard let bundle = bundle else { return 0 }
    let identifier = String(cString: bundle)
    guard identifier.count > 2 else { return 0 }
    guard Thread.isMainThread else { return 0 }
    guard let host = FloatHost.host(of: identifier) else { return 0 }
    // 0.4.67 — 不再「已经是横的就早退」：同一集里播放器换了位置也要重新对准，
    // 判重交给 `setLandscape`（尺寸与视频区都没变才早退）。
    let video = (vw > 8 && vh > 8)
        ? CGRect(x: vx, y: vy, width: vw, height: vh) : CGRect.null
    host.setLandscape(true, video: video)
    Log.write(String(format: "win: card landscape entered by app vid=%.0fx%.0f@%.0f,%.0f b=%@",
                     vw, vh, vx, vy, identifier))
    return 1
}

/// 0.4.65 — App 退出横屏（见 `AevonScene.m` 的 `AevonLandscapeExit`）。
///
/// 与进入对称：只切卡片，几何由 `setLandscape(false)` 一处算。
@_cdecl("AevonCardLandscapeExit")
public func AevonCardLandscapeExit(_ bundle: UnsafePointer<CChar>?) -> Int32 {
    guard let bundle = bundle else { return 0 }
    let identifier = String(cString: bundle)
    guard identifier.count > 2 else { return 0 }
    guard Thread.isMainThread else { return 0 }
    guard let host = FloatHost.host(of: identifier) else { return 0 }
    guard host.isLandscapeCard else { return 0 }
    host.setLandscape(false)
    Log.write("win: card landscape left by app b=" + identifier)
    return 1
}

/// 0.2.36 — 「系统要全屏打开这个 App 了，把正在承载它的卡片让开」。
///
/// 只在 `AevonOpenDecide` 的 `plain` 那一支调用：那里是**系统原实现之前**，
/// 所以同步拆卡来得及。卡片拆完时 `closeCard` 已经把 scene 的 frame 目标写回
/// 整屏（`win: scene frame restored`），系统接着拉起的就是一份干净的 scene。
///
/// 返回 1 = 真的拆了一张卡；0 = 这个 App 没有卡片（绝大多数打开请求都是这个）。
/// 非主线程一律答 0：`closeCard` 动的是 scene / window，必须有主线程。
@_cdecl("AevonCardYieldForFullscreen")
public func AevonCardYieldForFullscreen(_ bundle: UnsafePointer<CChar>?) -> Int32 {
    guard let bundle = bundle else { return 0 }
    let identifier = String(cString: bundle)
    guard identifier.count > 2 else { return 0 }
    guard Thread.isMainThread else { return 0 }
    // 0.4.2 — **停靠小窗里的 App 被系统整屏激活：升成主窗，不要关掉。**
    //
    // 用户报的是 QQ：它停在小窗里，点「QQ 登录」跳到 QQ 时，应该自动变回主
    // 悬浮窗。这条函数是这条路上唯一的观测点（`AevonWriteFrame` 的让路判据：
    // 我们的小窗目标高度 < 800，系统写进来的整屏 frame > 850，两条同时成立
    // 就是「系统要这个 App 上屏」）。原来它一律 `close(...)` —— 把卡拆掉，
    // 用户的观感是「小窗没了，也没变成主窗」。
    //
    // 升窗走 `promoteFromRing()`：它自己会处理「谁给谁让位」
    // （`performUndock` → `demoteMain(except:)`），与圆盘选中已经停靠的
    // 图标是同一条路，不需要第二套几何。
    if let docked = FloatHost.dockedHost(of: identifier) {
        Log.write("win: docked card promoted for fullscreen launch b=" + identifier)
        docked.promoteFromRing()
        return 1
    }
    guard let close = FloatHost.cardClosers[identifier] else { return 0 }
    Log.write("win: card yielded to fullscreen b=" + identifier)
    close("fullscreen launch")
    return 1
}


// 0.4.0 — 这里原本是 `AevonCardCloseNamed`：授权收尾那一拍按 bundle 收卡
// （`Log.write("win: card closed after auth b=…")` + `close("auth done")`）。
// 它的调用方是 URL 落点链里「授权回来 → 收掉那张卡」那一步，随 URL 链一起删掉
// 之后，这个 `private` 函数零调用方 —— `-Osize` 直接剥掉，审计报
// `win: card closed after auth b=` 不在包里。函数删除。
//
// 让路那条 `AevonCardYieldForFullscreen` 不一样：它由 ObjC 侧
// `AevonScene.m` 在 `AevonOpenDecide` 的 `plain` 分支里 `extern` 调用，还在用。

