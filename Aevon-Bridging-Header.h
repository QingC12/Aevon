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
/// `AevonAppMiniFlagSet(bundle, YES)` 写 `1`，`NO` 删除文件。返回是否真的写成了
/// （容器找不到 = NO，此时日志里要有痕迹，不然分不清「没开」和「没写成」）。
BOOL AevonAppMiniFlagSet(NSString *_Nullable bundleID, BOOL mini);

/// 0.1.8 — 启动时按名单撤掉上一次留下的停靠标记，返回清掉的个数。
///
/// 桌面进程崩掉 / 被强杀时，App 容器里的标记会留着 —— 那个 App 从此收不到
/// 任何触摸，用户看到的是「这个 App 点不动了」。构造函数第一拍调用一次。
int AevonAppMiniFlagsClearAll(void);

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

NS_ASSUME_NONNULL_END
