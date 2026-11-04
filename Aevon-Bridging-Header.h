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
void AevonHookArm(NSString *_Nullable bundle);
void AevonHookDisarm(void);

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
void AevonSceneFrameSet(double x, double y, double width, double height);
void AevonSceneFrameClear(void);

/// 主动推一次。返回门编号：3 = transition，1 = 普通，0 = 没写成或没有门。
/// 主线程、且不能从钩子里面调（与 push foreground 同一条纪律）。
NSInteger AevonPushSceneFrame(id _Nullable scene);

/// 真写进 settings 的次数。系统每次把 frame 写成整屏、我们每次又写回小胖屏，
/// 这个数就会一直涨；它停在 1 说明系统认了，没有再覆盖。
long AevonFrameWriteCount(void);

/// scene 现在的逻辑尺寸。读不到返回全零（日志里和「真的失败了」不会混）。
CGRect AevonSceneFrameOf(id _Nullable scene);

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

/// 0.0.65 — 开窗前的「这个进程有没有这一版代码」核对。
///
/// 返回 0 什么都不做（没在跑，或者名片对得上）；1 结束了一个旧进程并等到它
/// 退出；2 结束了但没等到；3 查不到 pid，什么都没做。只有 1/2 之后才值得写一行
/// 日志，因为只有那时候「冷启动」这个词是真的。
NSInteger AevonColdStartReady(NSString *_Nullable bundleID);

/// 0.0.28 — the accessor names come from the runtime instead of this source

@interface UIImage (AevonPrivateIcons)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                                       format:(NSInteger)format
                                                        scale:(CGFloat)scale
    NS_SWIFT_NAME(aevonAppIcon(bundleID:format:scale:));
@end

NS_ASSUME_NONNULL_END
