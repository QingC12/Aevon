//
//  Aevon-Bridging-Header.h — SpringBoard side only.
//
//  The tweak target needs the same private icon selector the settings bundle
//  uses (RingIcons is compiled into both binaries so the two can never draw a
//  different ring). Only that one declaration belongs here: the tweak has no
//  business knowing about PSListController.
//
//  Everything is guarded by responds(to:) at the call site, so a system
//  without this selector falls back to the filesystem scan instead of crashing.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// AevonScene.m — the calls that carry more arguments than `perform` can, plus
/// the two that have to read a non-object return value. Every one of them
/// answers nil / -1 / 0 rather than trapping, and the Swift side treats that as
/// "this system will not do it" and logs it.
void AevonEnumerateScenes(id _Nullable manager, void (^_Nullable block)(id _Nullable scene));
id _Nullable AevonSceneManager(void);
/// 0.2.3 — 「等 scene」现场快照用：这个 bundle 的进程 pid。取不到一律 -1。
int AevonAppPid(NSString *_Nullable bundleID);
/// 0.2.4 — 第二条口径：拦截点记过的、名字含这个 bundle 的 scene。
///
/// `enumerateScenesWithBlock:` 列不出「FrontBoard 已登记、客户端还没连上」的空壳
/// scene，而系统的 settings 推送就是发给那种 scene 的。Aevon(173) 的高德正是这样：
/// 枚举里六秒零命中，hook trace 里同名 scene 被我们改了三次前台。
id _Nullable AevonSeenSceneForBundle(NSString *_Nullable bundle);
/// 拦截点记住了几个 scene（诊断用，不参与判断）。
int AevonSeenCountOf(void);
/// 0.2.4 — 浮窗黑名单。圆盘那条路没有「打开请求」可判，所以名单要能单独问。
/// 键：`windowBlacklistText`（逗号/空格分隔）与 `windowBlacklist`（数组）。
BOOL AevonBlacklistedBundle(NSString *_Nullable bundle);
NSString *_Nullable AevonTakeNotes(void);

/// 0.0.16 / 0.0.22 — the mother ship's route: a scene's `uiPresentationManager`
/// asked for a presenter. A nil answer means "this system will not present it".
id _Nullable AevonCreatePresenter(id _Nullable manager,
                                  NSString *_Nullable identifier,
                                  NSInteger priority);

/// 0.0.18 — a BOOL getter read with the right ABI, -1 for "no such method".
NSInteger AevonBoolOf(id _Nullable object, NSString *_Nullable name);

/// 0.0.20 — run a no-argument void method: 1 for "ran", 0 for "no such method".
/// A call that never happened and a call that returned nil are otherwise
/// indistinguishable from Swift.
NSInteger AevonCallVoid(id _Nullable object, NSString *_Nullable name);

/// 0.0.27 — the mother ship's mechanism, installed as replacements instead of
/// relied on as getters. `AevonHookInstall` answers its own notes (a multi-line
/// string the caller writes to the log, selftest included); the summary is the
/// call counters, which are the only honest answer to "is the hook live".
NSString *AevonHookInstall(void);
NSString *AevonHookSummary(void);

/// Which scene may be held awake. Empty means nothing is held, which is the
/// state before the target is known and the state after the card is taken down.
///
/// 0.0.98 — 一张名单，不再是一个名字。停靠小窗的 scene 也要被守住，否则主窗
/// 一降级，它就从名单里消失，系统下一拍 deactivation 就会把它收走（用户看到
/// 的是「停靠的那个窗黑掉」）。最多 16 个槽，满了拒绝登记并计数。
void AevonHookArm(NSString *_Nullable bundle);
/// `nil` / 空串 = 全部撤回（0.0.97 的语义）。给一个 bundle = 只撤回它。
void AevonHookDisarm(NSString *_Nullable bundle);
/// 名单里现在有谁，逗号分隔；空名单回 `"no"`。
NSString *AevonHookArmedList(void);

/// `-_deactivationReasonsForScene:withSettings:` as a number, `ULLONG_MAX` when
/// this system does not answer it. Zero and "absent" are different facts.
unsigned long long AevonReasonsOf(id _Nullable scene);

/// 0.0.40 — how many times the system has tried to set deactivation reasons on
/// any scene since launch. The counter only ever moves when FrontBoard runs its
/// own update path, so a change during a card's life is the one moment the
/// system is taking the scene away — the moment the picture can go black.
/// Reading it is free; acting on it is one push, which the clock already knows
/// how to do.
long AevonDeactCount(void);

/// 0.0.31 — ask the system to treat this scene as being in front, so its app
/// starts committing frames again. `foreground=YES` and `backgrounded=NO` are
/// written through whichever door the method table actually offers, and the
/// answer is which door that was:
///
///   1  the scene's own `updateSettingsWithBlock:` (the mother ship's door)
///   2  the deactivation manager's `amendSceneSettings:forScene:`
///   3  nothing to do — the scene already says it is in front, no write spent
///   0  no door, wrong thread, inside a hook, throttled, banned, or out of tries
///
/// Main thread only, and never from inside a hook: Aevon(29) called it from
/// `_setDeactivationReasons:` and deadlocked SpringBoard into a safe mode.
NSInteger AevonPushForeground(id _Nullable scene);

/// 0.0.31 — refuse to push for the rest of this process. Called when the
/// previous run died inside the push: one crash is a bug, two in a row is what
/// the system calls a safe mode.
void AevonBanPush(void);

/// 0.0.32 — hand the settings back: `foreground=NO, backgrounded=YES`.
/// A value written by this tweak does not expire when the card comes down, and
/// Aevon(30) is the proof: the card was gone and Douyin was still playing to an
/// empty desktop. Same doors as the push, same main-thread rule.
/// 1 a door opened, 3 already in the background, 0 nothing to write through.
NSInteger AevonPushBackground(id _Nullable scene);

/// 0.0.61 — 小胖屏：把 scene 的**逻辑尺寸**改成卡片里那块承载面的尺寸。
///
/// 这一步是 0.0.60 缺的那一半。改承载视图的 `bounds` 只改了「画在哪块画布上」，
/// 没改「App 以为自己有多大的屏幕」—— 真机上的表现就是 430 宽的排版被 1:1 塞进
/// 377 的框：字大、顶栏偏右、底栏与抖音右侧那一列都在框外。
///
/// `AevonSceneFrameSet` 只是登记目标值，真正写进去有两条路：系统更新 settings 时
/// 由 intercept 钩子顺手改（母本的路线），以及 `AevonPushSceneFrame` 主动推一次
/// （建卡那一拍系统未必正好在更新）。`AevonSceneFrameClear` 之后系统自然写回整屏。
/// 0.0.98 — 画布目标按窗存：`bundle` 指名的那个槽才写。查不到槽（还没登记）
/// 就什么都不写，并让 `AevonFrameOrphanCount` 加一 —— 「这个窗没画布」和
/// 「画布写错窗」是两件必须能分开的事。
void AevonSceneFrameSet(NSString *_Nullable bundle,
                        double x, double y, double width, double height);
void AevonSceneFrameClear(void);
/// 只抹掉一个窗的目标，别的窗不受影响。
void AevonSceneFrameClearBundle(NSString *_Nullable bundle);
/// 当前有几块画布有目标；以及有几处调用点忘了先登记。
long AevonFrameArmedCount(void);
long AevonFrameOrphanCount(void);

/// 主动推一次。返回门编号：3 = transition，1 = 普通，0 = 没写成或没有门。
/// 主线程、且不能从钩子里面调（与 push foreground 同一条纪律）。
NSInteger AevonPushSceneFrame(id _Nullable scene);

/// 真写进 settings 的次数。系统每次把 frame 写成整屏、我们每次又写回小胖屏，
/// 这个数就会一直涨；它停在 1 说明系统认了，没有再覆盖。
long AevonFrameWriteCount(void);

/// scene 现在的逻辑尺寸。读不到返回全零（日志里和「真的失败了」不会混）。
CGRect AevonSceneFrameOf(id _Nullable scene);

/// 0.0.70 — 卡里那个 App 自己写下的读数，取回来。
///
/// 桥接在 App 进程里量几何，但 App Store 应用跑在沙盒里，`/var/mobile/Aevon.log`
/// 对它们不可写（全量日志里 App 侧只出现过 Filza / Sileo / 设置三个进程就是证据）。
/// 桥接现在退到自己的 `tmp/aevon-app.log`，这两条负责把那份取回来并进主日志。
///
/// 返回并入的行数：-2 找不到容器、-3 内容不是 UTF-8、0 没有新内容。
NSInteger AevonDrainAppLog(NSString *_Nullable bundleID, long cap);

/// 0.1.2 — 同一趟读取的「原文」版本。
///
/// 宿主每 2 秒把 App 的日志读走并清空，原先只数行数 —— 于是抖音自己写下的
/// `app: hang`（"我的主线程 2 秒没动了"）在宿主侧一个字都看不见，Aevon(90) 里
/// 整整 85 秒没人发现卡死。这一条把原文交回来，宿主用它可以做两件事：
/// 把证词转写进主日志（两条时间轴对齐），以及数「卡了多久」。
///
/// 返回 nil = 找不到容器 / 不是 UTF-8；空串 = 没有新内容。副作用（并入主日志 +
/// 清空原文件）与 `AevonDrainAppLog` 完全一致，两个函数不要同时调。
NSString *_Nullable AevonDrainAppLogText(NSString *_Nullable bundleID, long cap);

/// 那份文件在哪。取不到容器返回 nil —— 日志里要能区分「没写」和「没找到」。
NSString *_Nullable AevonAppLogPathOf(NSString *_Nullable bundleID);

/// 0.1.8 — 停靠标记：宿主往 **App 自己的沙盒** 里写一个字节，App 侧读它。
///
/// Aevon(95) 第 1 条：点停靠小窗时 App 里还是会触发一次点击，而且**在抬手那一拍**。
/// 我们这一侧 `sendEvent` 每一下都吞了（`mini touch down=N eaten=N`），说明送进
/// App 进程的是**另一份**触摸，绕过了 SpringBoard 的事件派发。
///
/// 三条已经试过、都不行的路：`content.isUserInteractionEnabled = false`（承载视图
/// 不参与命中，但那份投递不经过它）、`shield`（只存在于宿主窗口里）、几何判据
/// （停靠时 App 的 scene 一直是 430x717，只有承载视图被 transform 缩放，App 自己
/// 看不出「我被缩小了」）。
///
/// 唯一还剩的一层是 App 自己的 `-[UIApplication sendEvent:]`。它要知道自己此刻
/// 是不是被停靠成小窗 —— 这件事只能由宿主告诉它。通道用 App 容器里的一个文件：
/// 宿主能写（非沙盒），App 能读自己的 `NSTemporaryDirectory()`，两个方向都已被
/// `aevon-app.log` 证明可用。
///
/// `AevonAppMiniFlagSet(bundle, YES)` 写 `1`，`NO` 删除文件。返回**哪几条通道真成了**：
/// 0 = 都失败，1 = 只有 Darwin 通知，2 = 通知 + 文件，3 = 只写了文件。
/// （0.1.9 起才这样返回 —— 日志靠它一眼分清闸门到底装没装上。）
///
/// 0.1.9 — 加了第二条通道：**Darwin 通知**。文件那条有个绕不过去的缺口，Aevon(96)
/// 的日志里 `(no container)` 出现 49 次（设置 25 / Sileo 24）—— 容器找不到就写不进
/// 去，那些 App 的闸门一次都没装上。通知是系统级的，不依赖容器、不需要沙盒权限，
/// 只要 App 进程还活着就收得到。两条通道各自独立，任一条成就成立。
int AevonAppMiniFlagSet(NSString *_Nullable bundleID, BOOL mini);

/// 0.1.9 — 只发通知、不碰文件。宿主每秒给小窗续一次租约用。
///
/// App 侧把「收到 on」当成**租约**（2.5 s 内有效）：桌面崩掉 / off 丢了，租约自己
/// 过期，那个 App 就不会永久点不动。心跳本身只是一次 CFNotification 广播。
void AevonAppMiniNotify(NSString *_Nullable bundleID, BOOL mini);

/// 0.1.8 — 启动时按名单撤掉上一次留下的停靠标记，返回清掉的个数。
///
/// 桌面进程崩掉 / 被强杀时，App 容器里的标记会留着 —— 那个 App 从此收不到
/// 任何触摸，用户看到的是「这个 App 点不动了」。构造函数第一拍调用一次。
int AevonAppMiniFlagsClearAll(void);

/// 0.1.29 — 主窗四边热区的屏幕矩形，交给 App 进程做「同一根手指也收走」。
///
/// 用户原话：「在全屏应用中操作主悬浮窗的四边手势时有概率触发全屏 app 的操作
/// （例如上滑关闭悬浮窗手势，上滑后，悬浮窗关闭，全屏 app 会向下滑动）」。
///
/// 原因和右缘呼盘（0.1.24）完全一样：backboardd 把同一根手指**分别**投递给
/// SpringBoard 和前台 App，宿主侧吞掉自己那份不影响 App 那份。所以要把这块
/// 矩形告诉 App 进程，让它在自己 `sendEvent:` 里也扣住带内的触摸。
///
/// 用 Darwin 通知而不是文件：容器找不到就写不进去（0.1.9 在 25 个进程上踩过）。
/// 矩形本身编码进通知名，形如
/// `com.aevon.band.<bundle>.<x>_<y>_<w>_<h>_<hx>_<hy>_<hw>_<hh>`（整数点数），
/// 传 `CGRectNull` 表示「没有主窗，撤掉」。调用点是每一次手势结束 / 布局落定，
/// 不是每帧 —— 拖动的中间帧不发，那时手指已经归宿主了。
/// 0.1.34 — 数据改走 `CFPreferences`（宿主写目标 App 的域，App 读自己的域），
/// 通知名固定成 `com.aevon.band.<bundle>`，两端精确匹配。传 `CGRectNull` 表示
/// 「没有主窗，撤掉」。调用点是每一次手势结束 / 布局落定，不是每帧。
///
/// 0.1.35 — **返回写给了几个进程**。V111 的日志把上一版的缺口指出来了：
/// 值只写给了卡片里的那个 App，而真正接到那根手指的是**全屏那个 App** ——
/// 它一条都没有，所以 `app: band touch at` 一直是 0、手势百分百透传。现在广播
/// 到「卡片 + 所有正在运行的 App」，这个返回值就是「发给了几家」，写进日志。
NSInteger AevonAppBandSet(NSString *_Nullable bundleID, CGRect band, CGRect hole);

/// 0.1.34 — 「这根手指归宿主」：拖动 / 缩放开始时打开，抬手关掉。
///
/// 用户报的是「移动悬浮窗时 App 内的选项出现选中态，但不触发功能」——
/// `touchesBegan` 已经进了 App（高亮），后续被宿主吃掉，`ended` 永远等不到。
/// App 侧收到锁就擦一次高亮，并整根吞到抬手（自带 3 秒租约，宿主没了也能自愈）。
void AevonAppBandLock(NSString *_Nullable bundleID, BOOL locked);

/// 0.1.57 — App 进程里键盘实体顶边的 Y（屏幕坐标，本机 616），拿不到返回 0。
///
/// 「键盘顶边」只有 App 进程知道（`UIRemoteKeyboardWindow` 长在 App 的 scene 里），
/// 「窗口改多高」只有宿主做得动，所以这个数必须跨进程走一趟。App 写、宿主读，
/// 三条路：App 容器 `tmp/aevon-kb` → `/var/mobile/Aevon.kb` → App 偏好域 `AevonKbTop`。
CGFloat AevonAppKbTop(NSString *_Nullable bundleID);

/// 0.1.29 — 系统换了深浅色。
///
/// 悬浮窗里的 App 是另一个进程的 scene：系统切换时它自己那条 trait 更新链在我们
/// 这套「挂起启动 + 宿主缩放摆放」的方式下不一定走得到。桌面侧盯住
/// `traitCollection`，变化时发这一条，App 侧把窗口的 `overrideUserInterfaceStyle`
/// 重设一遍。只改样式，不改几何，不会让 App 重新布局。
void AevonAppStyleNotify(NSString *_Nullable bundleID, BOOL dark);

/// 0.1.31 — 锁屏 / 通知中心 / 控制中心是不是正盖在屏幕上。
///
/// 判据是 SpringBoard 自己的三个单例（`SBLockScreenManager.isUILocked`、
/// `SBCoverSheetPresentationManager.isPresented/isVisible`、
/// `SBControlCenterController.isVisible`），与右缘那条带用的是同一组，只是那条
/// 在 `RingHost` 里是 private。卡片层要靠它整层让开 —— 用户报的是「主悬浮窗和
/// 停靠小窗会出现在控制中心、通知中心、锁屏解锁后没上滑的那个页面上」。
BOOL AevonSystemCovered(void);

/// 0.2.6 — 只问「通知中心 / 控制中心 / 锁屏覆盖层在屏吗」，**不含 `isUILocked`**。
/// 卡片让开（alpha 0）用这一条；`AevonSystemCovered` 留着当失败出口的闸，
/// 两者差的那一条正是「点通知那一刻 `isUILocked` 必真」的教训（Aevon(171)）。
BOOL AevonSystemPanelUp(void);

/// 0.0.72 — 把 scene 的尺寸真正动一下再还回去，幅度由调用者给。
///
/// 只改承载视图的 bounds 不会让 App 重排：视图变了、scene 没变。冷启的抖音
/// （`icon scene up after 1085ms`）内容贴顶、同进程第二次开（`0ms`）正常，
/// 差别就是「有没有走完一次真正的窗口尺寸变化」。
///
/// 0.0.70 用的是固定 1 pt；Aevon(62) 的日志里那一推之后一条 `app: page
/// transition` 都没有，说明 1 pt 多半没被当成「窗口变了」。现在由调用者给幅度
/// （开卡用 -17，1 s 后再 +17），返回门编号，0 = 没有可推的目标。
NSInteger AevonNudgeSceneFrame(id _Nullable scene, double delta);

/// 0.0.50 — 画面到底在不在。`AevonContentStateOf` 读的是 `FBScene.contentState`
/// （2 = ready 有画，0 = 没准备好 ⇒ 黑，-1 = 没有这个方法），`AevonSceneLevel`
/// 读 `settings.level`（1 前台档 / 0 后台档 / -1 读不到）。
///
/// 这两个数是 Aevon(48) 之后唯一的判据。`settings.isForeground` 是我们自己写
/// 进去的，切换 App 时从来不变 —— 四份日志里它一次没掉过，所以那条守护在这
/// 件事上四版都没动过。
long AevonContentStateOf(id _Nullable scene);
double AevonSceneLevel(id _Nullable scene);

/// 0.0.52 — 两个拦截点的计数。`AevonInterceptCount` 是系统把 settings 交给
/// `_scene:interceptUpdateWithNewSettings:` 的次数（0 = 这个选择子在这台系统上
/// 不走），`AevonInterceptWrites` 是其中真被改成前台档的次数。
///
/// 节拍行里的 `ic=/iw=` 就是它们：切一次 App 哪个数动了，哪条路就是活的。
long AevonInterceptCount(void);
long AevonInterceptWrites(void);

/// 0.0.50 — 画面掉下去之后的唯一一件事：把 scene 重新说成前台，顺带写
/// `level = 1 / idleModeEnabled = NO`（母本那一组三件套）。
///
/// 不做「已经是前台就不写」的早退 —— 画面黑的时候 `fg` 恰恰还是 1，那条早退
/// 正是守护四版一次都没动的原因。只由 `contentState != 2` 触发，上限 8 次、
/// 间隔 200 ms。返回 1/2/3 表示走了哪条门，0 表示没门可走或被节流。
NSInteger AevonWakeScene(id _Nullable scene);
/// 0.2.26 — 回桌面那一秒的连写：同一段写入体，不走 200 ms 节流。额度由
/// `AevonHomeWakeReset` 在每次回桌面前重置。
NSInteger AevonHomeWake(id _Nullable scene);
void AevonHomeWakeReset(void);
long AevonWakeCount(void);

/// 0.0.51 — 画面回来的那一刻把这一段的额度还回去，下一段黑重新从满格起。
/// 按整场会话计的额度会在几十次切换之后用完，那之后修好的东西自己就过期了。
void AevonWakeReset(void);

/// 0.0.55 — 浮窗期间禁止空闲熄屏（移植自旧版 AevonNoAutoLockV248/V249 + AevonIdleRelV269）。
///
/// `Begin` 记下 `isIdleTimerDisabled` 的原值并打第一拍；`Kick` 每 20 秒一次
/// （`resetIdleTimer` + `resetIdleTimerAndUndim:` + 断言 acquire）；
/// `End` 释放断言并写回原值 —— 只放断言不写回、或只写回不放断言，都是旧版踩过的坑。
///
/// 返回位掩码：1 = resetIdleTimer，2 = resetIdleTimerAndUndim:，
/// 4 = isIdleTimerDisabled 写入，8 = 断言通道命中，16 = 私有 reset 变体。
/// mask 恒为 4 就是「这台机器上协调器一个都没找到」，只能靠 UIApplication 兜底。
NSInteger AevonIdleTimerBegin(void);
NSInteger AevonIdleTimerKick(void);
NSInteger AevonIdleTimerEnd(void);
/// 这一张卡片里 kick 被调用了几次（判据：卡片开满一分钟应该 ≥ 3）。
long AevonIdleTimerCount(void);

/// 0.0.28 — `- (void)name:(BOOL)`. 1 for "ran", 0 for "no such setter".
NSInteger AevonCallSetBool(id _Nullable object, NSString *_Nullable name, BOOL value);

/// 0.0.38 — 承载形状的图标直接开悬浮窗，靠的是母本自己的第一步：
/// `-launchApplicationWithIdentifier:suspended:`，把应用拉起来但不占屏幕。
/// Encoded `B28@0:8@16B24`, read off this phone in 0.0.13's alignment table
/// where it answers on `UIApplication` (PRESENT). The scene exists, the desktop
/// stays in front, and the card has something to present — which is the whole
/// reason the manual flow needed a six second wait and a swipe home.
///
///   1  started suspended
///   2  the method is there and said no
///   0  no such method on UIApplication or LSApplicationWorkspace
NSInteger AevonLaunchSuspended(id _Nullable application, NSString *_Nullable bundleID);

// MARK: - 0.2.13 自建 scene

// 这一组是整条链上第一次「scene 不是系统给的」。路线来自开源母本
// FrontBoardAppLauncher，每一样东西都先问再说（`AevonOwnGate`），整条包在
// ObjC 的 `@try` 里。四个入口的分工：
//   AevonOwnGate  只问不调，返回缺多少样（0 = 这条路接得上）
//   AevonOwnStart 起进程 + 建 scene（异步），返回 0/1/2
//   AevonOwnState / AevonOwnFetch  轮询那一格：0 没在跑 / 1 在建 / 2 建好了 / 3 失败
//   AevonOwnDestroy / AevonOwnIsOwned  关卡时走哪一半

/// 缺失项条数，0 表示整条自建路都接得上。只问不调。
NSInteger AevonOwnGate(void);

/// 起进程（launchIntent=4，不进前台）并建 scene。
/// 返回 0 = 闸不过（调用方必须回落老路）、1 = 已开始、2 = 已有一次在跑。
NSInteger AevonOwnStart(NSString *_Nullable bundleID, CGRect frame, const char *_Nullable from);

/// 0 = 没在跑 / 1 = 在建 / 2 = 建好了（等取） / 3 = 失败。不消费状态。
NSInteger AevonOwnState(void);

/// 取走建好的 scene（状态回到 idle）。没有就返回 nil。
id _Nullable AevonOwnFetch(void);

// MARK: - 0.2.14 分享转发延后
//
// 分享那条请求（带 payload）不再在分流里立刻交回系统：先建卡、等 scene 到位，
// 再由这里投出去。原因见 `AevonForwardHold` 上面那段 —— 交回系统那一瞬
// SpringBoard 就把目标 App 摆成前台，那正是用户看到的「先全屏」。
//
// `why` 只进日志（`notify: forward flush why=…`）。任意线程调都安全，没有待发
// 请求时什么都不做；不调用也不会丢分享（1.6 秒超时会自己发）。
void AevonForwardFlush(const char *_Nullable why);

// 0.2.15 — 卡片的 scene 就位时调这个，**不要**直接调 `AevonForwardFlush`：
// 它先试「把这次 open URL 直接投进目标 App」（宿主写 `tmp/aevon-open.plist` +
// Darwin 通知，App 侧调自己的 `application:openURL:options:`），拿到 `ok=1`
// 就整条销毁、一个字节都不交给 SpringBoard —— 交给它就等于把我们自建的 scene
// 抢去全屏（Aevon(185)：`win: scene frame after=430x932` + 卡片黑屏）。
// 1.25 秒没回执才退回 `AevonForwardFlush` 那条老路，分享不会丢。
void AevonForwardDeliver(const char *_Nullable why);

/// 这一次卡片没有用自建的 scene（复用系统那个 / 走了老路）—— 关卡时不许销毁。
void AevonOwnClear(void);

/// 1 = 这张卡上的 scene 是自建的（关卡要销毁，不是推回后台）。
NSInteger AevonOwnIsOwned(NSString *_Nullable bundleID);

/// 销毁自建 scene。返回 1 表示这一句发出去了。
NSInteger AevonOwnDestroy(NSString *_Nullable bundleID);

/// 0.2.38 — 让路时把自建 scene **原样交给系统**（不销毁）。返回 1 = 账清了。
/// 0.2.37 在让路时调 `AevonOwnDestroy`，系统正要把这张 scene 拉成全屏，
/// 设置 App 就是这样闪退的；其它 App 则是「全屏底部黑」。
NSInteger AevonOwnHandOver(NSString *_Nullable bundleID);

/// 0.2.25 — 回桌面的三级阶梯，一次只调用一级（1 = 硬件 home 键那条、
/// 2 = 收起主切换器、3 = 切换器 controller 的 home 处理）。`page` 只有第 3 级
/// 用到（沿响应链找 controller）。返回实际调用了谁，或没接上的原因。
NSString *_Nullable AevonHomeStep(int step, id _Nullable page);

/// 0.2.24 — 回桌面的结果读数：1 = 桌面已经在屏上，0 = 还在 App 页里，-1 = 读不到。
/// 调用方按「不是 1」决定要不要走藏空页的兜底 —— 不信返回值，信读数。
int AevonSpringboardActive(void);

/// 0.2.34 — 「这个 App 现在是不是屏上那个全屏 App」。1 = 是 / 0 = 不是 /
/// -1 = 读不到。`openCard` 的「先回桌面」只用它当判据：0.2.33 用的 scene
/// 可见位对后台 scene 也答 1，真机上把桌面在屏的那一次也带进了 home 分支。
int AevonAppFrontmost(NSString *_Nullable bundleID);
// 0.2.35 — `FBScene.settings.isForeground`：这个 scene 自己报的前台位。
// 1 = 前台 / 0 = 后台 / -1 = 读不到。`isFrontmost` 在真机上答不出时靠它。
int AevonSceneForeground(id _Nullable scene);

// 0.0.65 的 `AevonColdStartReady` 已随该功能一起删除（0.0.66）：它靠「名片文件
// 写上 pid」判断进程新旧，而名片写不进去时（沙箱、目录权限、装包顺序）判据就永远
// 不成立 —— 于是每次开窗都先结束那个 App 再拉起来。一次写失败换来「App 打不开」，
// 这个代价与收益完全不成比例，整条路撤掉。旧进程只会让这一版的改动不生效，
// 不会让 App 坏掉，那是一种可以被容忍的失败。

/// 0.0.28 — the accessor names come from the runtime instead of this source

@interface UIImage (AevonPrivateIcons)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                                       format:(NSInteger)format
                                                        scale:(CGFloat)scale
    NS_SWIFT_NAME(aevonAppIcon(bundleID:format:scale:));
@end

// ---------------------------------------------------------------------------
// 0.1.40 — 通知点击开浮窗。
//
// `AevonScene.m` 里挂 `SBMainWorkspace -executeTransitionRequest:` 一个钩子，C 侧
// 更稳（IMP 当函数指针用，编译器不会在转换处打问号），Swift 侧只留入口与日志。
//
// 0.1.41 — 键盘那一半的 Swift 入口删了。`AevonKeyboardHostInstall` 在
// SpringBoard 里遍历窗口树、把「类名带 Keyboard」的视图按全屏 bounds 摆正，
// 0.1.40 真机第一下点输入框就在那里进了安全模式（`__NSMallocBlock__
// countByEnumeratingWithState:`）。母本 `SthenoKb.dylib`（注入 SpringBoard）的
// 导入表里没有 UIView / UIWindow / UIScreen，选择器只有 `isEqualToString:` 与
// `postNotificationName:object:userInfo:` —— 母本在 SpringBoard 侧只转发通知，
// 从不碰键盘视图。键盘几何全部在键盘进程（`AevonAppHook.m` 的 `AevonKbNative*`）。
// ---------------------------------------------------------------------------

/// C 侧的直写日志。`AevonNote` 是缓冲，事件型的证词不能等下一次排空。
void AevonLogRaw(const char *_Nullable line);

/// SpringBoard 侧：挂 `SBMainWorkspace -executeTransitionRequest:`，认通知回应。
void AevonNotificationOpenInstall(void);

/// 0.2.5 — 清通知的「截对象」入口：挂 `NCNotificationDispatcher` 的
/// `-destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:`，
/// 把被点击的那条 `NCNotificationRequest` 连同它所在的 destination 登记下来，
/// 供 0.60 秒后的 `AevonClearNotification` 直接 withdraw。
/// 通知栈是懒加载的，取不到类会自己 3 秒后再试（上限 20 次），调用方只叫一次。
void AevonNotificationCaptureInstall(void);

/// 0.1.93 — 主线程看门狗。后台队列每秒问主线程一次;主线程被卡住时它从后台
/// 直接往日志里写一行 `win: main stall …ms`（不走 `Log.write`,那条路的
/// `DateFormatter` 不是线程安全的）。`version` 只用于日志前缀。
void AevonMainStallWatchdogStart(const char *_Nullable version);

/// Swift 侧的实现（`SceneProbe.swift`）：拿 bundle id 走圆盘同一条开卡路。
void AevonOpenFromNotification(const char *_Nullable bundleID);

NS_ASSUME_NONNULL_END
