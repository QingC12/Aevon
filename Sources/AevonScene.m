//
//  AevonScene.m — the second non-Swift file, and for the same reason.
//
//  Three of the calls this tweak needs carry more arguments than `perform` can
//  express (a block, an integer, a `BOOL` read without the ABI being guessed),
//  so the only honest way to reach them from Swift is objc_msgSend with an exact
//  cast. This file exists for those casts and for nothing else.
//
//  Everything here is guarded: a selector that is not there returns nil (or -1,
//  or 0) instead of trapping. Callers log the answer and stop.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
// 0.1.9 — 停靠标记的 Darwin 通知通道（`CFNotificationCenterGetDarwinNotifyCenter`）。
// Foundation 一般会带进来，显式写一行免得换 SDK 时莫名为空。
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <math.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

// 0.4.0 — 这一栏是 SpringBoard 侧（`Log.swift` / `SceneProbe.swift`）用 `@_cdecl`
// 导出的入口。Swift 的 bridging header 不会进 `.m`，所以在这里各写一行 `extern`：
// 签名必须与那几处逐字一致（`const char *`，可空）。
//
// 只留还在生产链上的五个。0.4.0 把 URL / 通知 / 分享三条链整条删掉之后，原先
// 这里有十几行（`AevonOpenCardDirect` / `AevonCardCloseFor` /
// `AevonModifyContextSetResize` / `AevonActRead` …）已经没有调用点，一并去掉。
extern void AevonLogRaw(const char *line);

// 0.2.36 — 「系统要普通全屏打开这个 App 了，把正在承载它的卡片让开」。
// 只在主线程有效（`closeCard` 动 scene / window）；返回 1 = 真的拆了一张卡。
//
// 0.4.0 — 这里原来还有三条（`AevonCardIsUpFor` / `AevonCardIsComingFor` /
// `AevonOwnFloatScene`）。前两条是 URL 落点链问「卡起来没有」的判据，第三条是
// 自建承载把 scene 挂进卡片的入口 —— 都在这一版删掉的功能里，没有调用点了。
extern int AevonCardYieldForFullscreen(const char *bundle);

/// The scene manager is a singleton with no public door, and its spelling has
/// changed across releases. Resolving it here keeps the class-method dispatch
/// out of Swift, where `AnyClass` + `perform` needs casts that the compiler is
/// free to reject on a different SDK. Returns nil when none of the three names
/// answers; the caller logs that and stops.
id AevonSceneManager(void) {
    Class cls = NSClassFromString(@"FBSceneManager");
    if (cls == Nil) return nil;
    for (NSString *name in @[@"sharedInstance", @"sharedManager", @"defaultManager"]) {
        SEL sel = NSSelectorFromString(name);
        if (![cls respondsToSelector:sel]) continue;
        id got = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
        if (got != nil) return got;
    }
    return nil;
}

/// `enumerateScenesWithBlock:` — the block is the point. Swift closures do not
/// cross `perform` reliably, so the call is spelled out here where the block
/// type is native.
void AevonEnumerateScenes(id manager, void (^block)(id scene)) {
    SEL sel = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if (manager == nil || block == nil || ![manager respondsToSelector:sel]) return;

    void (*call)(id, SEL, void (^)(id)) = (void (*)(id, SEL, void (^)(id)))objc_msgSend;
    call(manager, sel, block);
}

/// 0.2.3 — 「等 scene」那几秒里，这个 App 的进程到底起没起。
///
/// 只回答一个问题：`pid` 有值 = 进程在；`-1` = 进程不在（挂起启动对它没生效）。
/// 它与 scene 列表拼在一起才能把三种失败分开（见 `SceneProbe.probeScenes`）。
///
/// 全部经 `respondsToSelector:` 问过才调用，整段 `@try` —— 这是诊断路上的一个
/// 读数，它不许把进程带走。取不到的每一种情况都折成 `-1`，与「进程不在」同值：
/// 诊断行里少一个区分，好过为了区分去猜一个可能不存在的 selector。
/// 0.2.9 — 把 `SBApplication` 本体拿出来（pid 与「前台/后台」都从它读）。
/// 找不到就返回 nil；调用方一律 `@try` 包住。
static id AevonAppObject(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    Class cls = NSClassFromString(@"SBApplicationController");
    if (cls == Nil) return nil;
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sharedSel]) return nil;
    id shared = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSel);
    if (shared == nil) return nil;
    SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![shared respondsToSelector:appSel]) return nil;
    id app = ((id (*)(id, SEL, id))objc_msgSend)(shared, appSel, bundleID);
    if (app != nil) return app;
    SEL altSel = NSSelectorFromString(@"applicationWithDisplayIdentifier:");
    if ([shared respondsToSelector:altSel]) {
        app = ((id (*)(id, SEL, id))objc_msgSend)(shared, altSel, bundleID);
    }
    return app;
}

int AevonAppPid(NSString *bundleID) {
    if (bundleID.length == 0) return -1;
    @try {
        id app = AevonAppObject(bundleID);
        if (app == nil) return -1;
        SEL pidSel = NSSelectorFromString(@"pid");
        if (![app respondsToSelector:pidSel]) return -2;
        // 标量返回值只走强转过的函数指针读 x0，不用 `perform`（它会把一个
        // `int` 当成对象指针 retain —— 0.1.38 那五次安全模式就是这么来的）。
        return ((int (*)(id, SEL))objc_msgSend)(app, pidSel);
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

/// 0.2.34 — 「这个 App 现在是不是屏上那个全屏 App」。只读 `SBApplication.isFrontmost`。
///
/// 0.2.33 用的是 scene 的 `accessibilitySceneIsForegroundVisible`，真机日志把它
/// 证伪了：桌面在屏时点圆盘里的 QQ（11:14:04），它照样答 1 → 进了 home 分支 →
/// home 又发不出去 → 白等 1.4 秒才建卡。用户看到的就是「又不会回桌面 + 黑屏」。
/// `isFrontmost` 是 SpringBoard 自己的前台位，问它才是问「谁在屏上」。
/// 返回 1 = 是 / 0 = 不是（含进程不在）/ -1 = 读不到。
int AevonAppFrontmost(NSString *bundleID) {
    if (bundleID.length == 0) return -1;
    @try {
        id app = AevonAppObject(bundleID);
        if (app == nil) return 0;
        SEL sel = NSSelectorFromString(@"isFrontmost");
        if (![app respondsToSelector:sel]) return -1;
        return ((BOOL (*)(id, SEL))objc_msgSend)(app, sel) ? 1 : 0;
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

// MARK: - Notes

/// 0.2.35 — 「这个 scene 的 settings 说它在前台吗」。
///
/// 0.2.34 的 `AevonAppFrontmost` 在真机上答不出来：同机日志里
/// `win: pose … front=-1 bg=-1 run=-1 pid=-2` —— `SBApplicationController`
/// 对 `org.coolstar.SileoStore` 返回 nil，于是全屏 QQ 选自己也被判成
/// 「不是前台」，`home first skip` 一写，卡片就把正在全屏的那份 scene 搬走，
/// 全屏页抽空变黑。
///
/// 这个读数是 scene 自己的：`FBScene.settings.isForeground`。系统每次切前台都
/// 会写它（我们的 intercept 钩子读的就是同一个字段，日志里的 `fg=`）。
/// 返回 1 = 前台 / 0 = 后台 / -1 = 读不到（selector 缺失，不猜）。
int AevonSceneForeground(id scene) {
    if (scene == nil) return -1;
    @try {
        SEL settingsSel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:settingsSel]) return -1;
        id settings = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
        if (settings == nil) return -1;
        SEL fgSel = NSSelectorFromString(@"isForeground");
        if (![settings respondsToSelector:fgSel]) return -1;
        return ((BOOL (*)(id, SEL))objc_msgSend)(settings, fgSel) ? 1 : 0;
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

/// Notes are collected here and drained by Swift in one go, so the log gets
/// twenty lines from one crossing instead of twenty. Nothing is written to
/// disk — the caller decides when the moment is safe enough to log.
static NSMutableString *AevonNoteBuffer(void) {
    static NSMutableString *buffer = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ buffer = [NSMutableString new]; });
    return buffer;
}

static void AevonNote(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [AevonNoteBuffer() appendString:line];
    [AevonNoteBuffer() appendString:@"\n"];
}

/// Hands every pending note to the caller and clears the buffer. Called before
/// anything that may take the process down: a note that is still in memory when
/// the process dies is a note that never happened.
NSString *AevonTakeNotes(void) {
    NSMutableString *buffer = AevonNoteBuffer();
    NSString *out = [buffer copy];
    [buffer setString:@""];
    return out;
}

// MARK: - The mother ship's chain (0.0.22)

// Stheno's own scene vocabulary, counted in her binary: `createPresenterWithIdentifier:priority:`
// as a hook target in `__const`, `presentationView` and `initWithSceneLayer:` as
// the objects it hands over. Her `layerManager`, `layers` and `hostManager`
// counts are zero — she never walks the layer tree, she takes a presenter.
//
// 0.0.20 took the same route and stopped one call short of a picture: the
// presenter was activated while its view belonged to no window. So the only
// calls left in this file are the three that route needs.

/// `createPresenterWithIdentifier:priority:` on a UIScenePresentationManager.
/// Returns the presenter, or nil when the manager will not make one.
id AevonCreatePresenter(id manager, NSString *identifier, NSInteger priority) {
    if (manager == nil || identifier == nil) return nil;
    SEL sel = NSSelectorFromString(@"createPresenterWithIdentifier:priority:");
    if (![manager respondsToSelector:sel]) {
        AevonNote(@"presenter: selector absent on %@", NSStringFromClass([manager class]));
        return nil;
    }
    id (*call)(id, SEL, id, NSInteger) = (id (*)(id, SEL, id, NSInteger))objc_msgSend;
    // 0.2.29 — 这一段必须包 @try。
    //
    // 0.2.27 真机（iPhone16,2 / 17.3.1）在「点外部链接以浮窗打开」时把 SpringBoard
    // 带进了安全模式，崩溃栈是：
    //     -[UIScenePresentationManager createPresenterWithIdentifier:priority:]
    //     AevonCreatePresenter + 100
    //     libdispatch _dispatch_client_callout（主线程）
    // 这个调用会抛 NSException（同一 scene 上已有同标识 presenter 等），而 Swift 侧
    // 接不住 ObjC 异常 —— 唯一能兜住的地方就是这里。catch 到就返回 nil，调用方本来
    // 就有 `guard let ... else { "win: no presenter"; return }`，卡片不建，进程还在。
    id presenter = nil;
    @try {
        presenter = call(manager, sel, identifier, priority);
    } @catch (NSException *exception) {
        AevonLogRaw([[NSString stringWithFormat:@"win: presenter threw %@ on %@",
                      exception.reason ?: @"(no reason)", identifier] UTF8String]);
        presenter = nil;
    }
    AevonNote(@"presenter %@ -> %@", identifier,
              presenter ? NSStringFromClass([presenter class]) : @"nil");
    return presenter;
}

/// A BOOL-returning no-argument method, read without guessing the ABI.
/// `performSelector` cannot be used for this: it treats the return as an
/// object pointer, and a BOOL of 1 is not a valid one. -1 means "no such
/// method", which is a different answer from "no".
NSInteger AevonBoolOf(id object, NSString *name) {
    if (object == nil || name == nil) return -1;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return -1;
    BOOL (*call)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return call(object, sel) ? 1 : 0;
}

/// `- (void)name`. 1 when it ran, 0 when the object does not answer it. Void,
/// no arguments — the only shape `activate`, `deactivate` and `invalidate`
/// have. Returning the "did it run" answer here rather than a value matters: a
/// call that never happened and a call that returned nil look identical from
/// Swift.
NSInteger AevonCallVoid(id object, NSString *name) {
    if (object == nil || name == nil) return 0;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return 0;
    void (*call)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    call(object, sel);
    return 1;
}


/// `-launchApplicationWithIdentifier:suspended:` — the mother ship's first step.
///
/// Her binary calls it on `sharedApplication` and the 0.0.13 alignment table
/// found exactly that shape on `UIApplication` (PRESENT, `B28@0:8@16B24`), so the
/// app object is asked first; `LSApplicationWorkspace` carries the same selector
/// on releases where the app object dropped it, and it already opens apps for the
/// ring, so it is the one fallback worth trying. Two answers rather than one,
/// because "there is no such method" and "it refused" lead to different next
/// steps and used to look identical from Swift.
NSInteger AevonLaunchSuspended(id application, NSString *bundleID) {
    if (bundleID == nil || bundleID.length == 0) return 0;
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");

    id targets[2] = {application, nil};
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    if (workspace != Nil) {
        SEL shared = NSSelectorFromString(@"defaultWorkspace");
        if ([workspace respondsToSelector:shared]) {
            targets[1] = ((id (*)(id, SEL))objc_msgSend)((id)workspace, shared);
        }
    }
    for (int index = 0; index < 2; index++) {
        id target = targets[index];
        if (target == nil || ![target respondsToSelector:sel]) continue;
        BOOL (*call)(id, SEL, id, BOOL) = (BOOL (*)(id, SEL, id, BOOL))objc_msgSend;
        BOOL started = call(target, sel, bundleID, YES);
        return started ? 1 : 2;
    }
    return 0;
}

// MARK: - 0.2.13 自建 scene（不再「先全屏、再抢」）

// 这一段回答的是整条链上最后一个「不是我们的东西」：**scene 从哪来**。
//
// 0.2.10 把「QQ 全屏后变黑」定成「那次转发」——转发把目标 App 摆成前台 App，
// 而它的 scene 已经被我们贴进卡片，剩下的那半屏就是黑的。0.2.12 顺着这条线
// 把挂起位写进了 `SBActivationSettings`（`pick=3 flag=1 read=1`，真机读回是 1），
// QQ 仍然先全屏。
//
// 0.2.87 — **这一段当年的推论要拆成两半：一半成立，一半被推翻。**
//   ✅ 成立：`launchApplicationWithIdentifier:suspended:YES` **不是**「不上屏」的
//      开关。它不阻止随后的系统激活，SpringBoard 照样把目标摆成前台 App 演一遍
//      全屏动画。所以拿它当「压住激活」的手段，方向就错了。
//   ⛔ 推翻：由「它不是不上屏的开关」推出「它没用」。母本拿它做的是**预暖** ——
//      复刻方案 P5 的原文是「场景先建好不跑，要显示时再激活」：进程与 scene 提前
//      就绪，随后的激活只是把已经热的东西推上台，全屏那一段因此更短。
//      0.2.87 把它接回 `AevonAuthSwapScheduleMode` 的入口（见 `AevonPrewarmCard`），
//      分享 / 授权 / 普通深链三条路共用一处接线。
//   ⛔ 同样被推翻的还有下面这条推论：由「预暖不压屏」推出「所以要自建 scene」。
//      Aevon(212) 用三次失败（QQ `rsp=0`、支付宝 `timeout`、微信空壳）证明
//      自建 scene 里没有系统那一次激活，业务全部不认。
//
// 开源母本 FrontBoardAppLauncher（TrollOpen 的致谢里点名的那个）走的是另一条：
// 不经 open request、不给 SpringBoard 任何展示机会——
//   RBSProcessIdentity -> FBApplicationProcessLaunchTransaction（launchIntent=4）
//   -> registerProcessForAuditToken:
//   -> FBSMutableSceneDefinition + FBSMutableSceneParameters
//   -> FBSceneManager createSceneWithDefinition:initialParameters:
//   -> scene.uiPresentationManager -> presenter -> presentationView
// 屏幕从头到尾只有我们的卡片，没有第一帧全屏。
//
// 三条纪律落在这里：
//   1. 每个类、每个选择子都先问（`AevonOwnGate`）。少一个就整条放弃，回落老路 ——
//      0.0.15 拿逆向字符串直接调 `_createSceneWithDefinition:` 换来过一次安全模式，
//      这一次不再有「可能存在的名字」。
//   2. 整条包在 `@try/@catch` 里。Swift 接不住 ObjC 异常，这个文件接得住；
//      任何 `unrecognized selector` 都变成一行日志加一次回落，不是一次重启。
//   3. 结构体参数（`auditToken` 8×uint32、`CGRect`、`UIEdgeInsets`）一律走
//      `NSInvocation` 或按声明类型传，绝不用 `performSelector` 碰。返回值超过
//      16 字节的方法（`-auditToken`）也只有 `NSInvocation` 能安全取回。

/// `{uint32_t[8]}`：`RBSProcessHandle -auditToken` 与
/// `FBProcessManager -registerProcessForAuditToken:` 之间的那个结构体。
typedef struct { uint32_t word[8]; } AevonAuditToken;

/// 0 idle / 1 building / 2 ready（等取） / 3 failed
static NSInteger AevonOwnPhase = 0;
static id AevonOwnScene = nil;
static NSString *AevonOwnBundle = nil;
static NSString *AevonOwnIdentity = nil;
/// 这一次开始建的时刻。超时兜底用它 —— 一个永不回调的启动事务会把 phase 冻在
/// 「在建」，那之后自建这条路就永久不再被尝试，而这在日志里看起来只是「没走自建」。
static CFAbsoluteTime AevonOwnAt = 0;
static int AevonOwnNotes = 0;
/// 1 = 屏幕上这张卡的 scene **确实是**我们自己建的那个。
///
/// 不能用「bundle 名对得上」来判断：自建 → 关卡（销毁）→ 用户从桌面全屏打开
/// → 圆盘再开卡（这次复用系统那个 scene），名字还是同一个 bundle，而
/// `destroyScene:` 要的 identity 也还是 `sceneID:<bundle>-default` —— 按名字判
/// 会把系统那个正在显示的 scene 销毁掉，画面直接消失。所以「谁建的」必须由
/// 建它的那一刻记下来，并且在每一次重新决定来源时清掉。
static int AevonOwnHeld = 0;
// 0.2.59 — 预热去重：同一个 bundle 8 s 内只热一次（来回划圆盘不该连开三条启动链）。
static char AevonWarmBundle[64] = {0};
static double AevonWarmAt = 0;

/// 一条现场行，带独立预算。这个工程里每一条现场行都得有自己的计数器：
/// 跟别人共用一个，就会在几次操作之后静默，而静默和「没发生」长得一样。
static void AevonOwnLog(NSString *format, ...) {
    // 40 = 35 条 gate 明细 + 汇总 + 几次调用现场。预算比需要的多留几格：
    // 这条路一次真机要回答的问题全在这几行里，被自己的预算吃掉是最贵的失败。
    if (AevonOwnNotes >= 40) return;
    AevonOwnNotes++;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    // 这个文件是 MRC（Makefile 里没有 `-fobjc-arc`），`alloc` 出来的东西要自己
    // 交回去。`AevonLogRaw` 在 Swift 侧第一句就是 `String(cString:)`，取完即复制，
    // 所以这里 release 之后没有人会再读那段 UTF-8。
    AevonLogRaw([line UTF8String]);
    [line release];
}

// 0.4.0 — 这里原本有一张 `AevonOwnNeeds[]`（RBSProcess / FBProcess 的最小类面，
// 自建承载「自己把 App 拉起来」那一步用的）和它的 `AevonOwnNeed` 结构。
// 自建承载随 URL 链一起删掉之后，这张表没有任何读方 —— `-Werror` 的
// `-Wunused-const-variable` 会在 CI 里直接判死，所以整块拿掉。





/// 建 scene 之前要的那份 settings。每一项都是「让这个 scene 自己就是一块
/// 屏幕」，而不是「从整屏里裁一块」——这是 0.0.65 画布口径的延续：
/// 给系统的是一块 430x717 的屏幕，卡片再把它等比缩小。
/// 这一组行**不走** `AevonOwnLog` 的预算：40 条里 35 条被开机那一遍 gate 明细
/// 占掉，用它写就等于「开机第一次打开 App 时这一行没有」。而尺寸这件事恰恰只有
/// 第一次打开那几拍要对得上。
static int AevonOwnDisplayNotes = 0;
static void AevonOwnDisplayLog(NSString *format, ...) {
    // 0.2.17 — 12 → 36。Aevon(188) 里抖音那一段**一行都没有**：前 3 个 App
    // （设置 / Filza / 电池）每个 3 行就把 12 条用完了，于是最该看的那个 App
    // 什么都没留下。这一族只在自建 scene 时写，36 条够 6~8 个 App。
    // 0.2.46 — 36 → 48。这一版每个 App 多两条（`display cap` 一次 + `own ref`
    // 每 App 一条 + 尺寸变化时的 `display follow`），36 会从「8 个 App」缩到
    // 「5 个 App」。尺寸这条路是本版唯一的主题，不能让它被自己的预算吃掉。
    if (AevonOwnDisplayNotes >= 48) return;
    AevonOwnDisplayNotes += 1;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    AevonLogRaw([line UTF8String]);
    [line release];
}

/// 0.2.46 — 显示覆盖的**第一条路**：`copyWithOverrideBounds:`。
///
/// 为什么换路（这一版的主题）：
///
///   `AevonOwnDisplay` 从 0.2.15 起走的是「`mutableCopy` 一份真机配置，再问副本
///   有没有 `setBounds:`」。真机上两种日志都出现过 ——
///     `win: own display 430x932 -> 430x717`          ← 成了
///     `win: own display keep 430x932 (no setBounds)` ← 没成
///   覆盖没成的那一半，App 里 `UIScreen` 仍然是 932，于是按 `UIScreen` 排版的
///   App（抖音的 feed / 高德的地图）继续按 932 摆内容，画面带着 215 pt 的偏差
///   塞进 717 的窗口 —— 这就是「部分视频不在浮窗正中心」的病根，也是后来那条
///   视频居中补丁存在的原因（补丁治的是症状）。
///
///   TrollOpen 的二进制里有 `copyWithOverrideBounds:`（见
///   `dist/对比-抖音浮窗重排与视频居中-三家逆向-2026-11-09.html` 第五节）。它是
///   `FBSDisplayConfiguration` 家族的**派生**入口：不要求副本可变，直接拿一份
///   改了 bounds 的新配置回来。成功率和语义都比「拷一份再赌它可变」稳。
///
/// 形状闸照旧先问后调：选择子在、参数个数 3、编码里带 `CGRect` —— 三条缺一条
/// 就返回 nil，由调用方走老路。**不猜 ABI**。
///
/// 返回值是 +1 的对象（`copy` 前缀），调用方负责 `autorelease`/`release`。
static id AevonOwnDisplayOverride(id base, CGRect frame) {
    if (base == nil) return nil;
    SEL sel = sel_registerName("copyWithOverrideBounds:");
    if (![base respondsToSelector:sel]) return nil;
    Method method = class_getInstanceMethod(object_getClass(base), sel);
    const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
    unsigned int arguments = method != NULL ? method_getNumberOfArguments(method) : 0;
    if (method == NULL || encoding == NULL || arguments != 3 ||
        strstr(encoding, "CGRect") == NULL) {
        AevonOwnDisplayLog(@"win: own display override skip enc=%s n=%u",
                           encoding != NULL ? encoding : "-", arguments);
        return nil;
    }
    id copy = nil;
    @try {
        copy = ((id (*)(id, SEL, CGRect))objc_msgSend)(base, sel, frame);
    } @catch (NSException *exception) {
        copy = nil;
        AevonOwnDisplayLog(@"win: own display override threw %s",
                           exception.reason != nil ? [exception.reason UTF8String] : "-");
    }
    return copy;
}





/// 0.2.46 — 建 scene 时一次定型「内容参考尺寸」（对比报告第六节第 2 条）。
///
/// 抖音那种 App 的排版入口不是 `UIScreen` 一处：`UIWindowScene` 上还有一份
/// `contentReferenceSize`，是「内容坐标系的参考大小」。0.2.13 起我们建 scene 时
/// 只写了 `setFrame:` + `setDisplayConfiguration:`，这一格一直没写 —— App 拿到的
/// 是默认值，然后自己按最保险的那个数（整屏 932）排，右边那列工具栏就落到 717
/// 之外（Aevon(188) `peers7 … UIView:0,0,430x932`）。
///
/// TrollOpen 的二进制里有这个选择子（`setContentReferenceSize:withContentOrientation:
/// andContainerOrientation:`，同样来自第五节那张表）。这里做的是**和显示配置同一个
/// 数**：display bounds 多大，参考尺寸就多大 —— 两个数一旦不相等，App 内部就会出现
/// 「坐标系 717、屏幕 932」的错位，那比不设更糟。所以调用方传的就是 `frame.size`。
///
/// 形状闸：选择子在、参数 5 个（self/_cmd + 3）、编码里带 `CGSize`。缺一条就跳过 ——
/// 私有的选择子同名不同参是常事，宁可少设一项也不发一个错的结构体进去。
/// 方向两个参数都传 1（竖屏），与 `setInterfaceOrientation:` 同一个约定。
///
/// 返回 1 = 写了；0 = 这个宿主没有这一格（记为事实，不重试）。
static int AevonOwnRefSet(id host, CGSize size, const char *tag) {
    if (host == nil) return 0;
    SEL sel = sel_registerName(
        "setContentReferenceSize:withContentOrientation:andContainerOrientation:");
    if (![host respondsToSelector:sel]) return 0;
    Method method = class_getInstanceMethod(object_getClass(host), sel);
    const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
    unsigned int arguments = method != NULL ? method_getNumberOfArguments(method) : 0;
    if (method == NULL || encoding == NULL || arguments != 5 ||
        strstr(encoding, "CGSize") == NULL) {
        AevonOwnDisplayLog(@"win: own ref skip %s enc=%s n=%u", tag,
                           encoding != NULL ? encoding : "-", arguments);
        return 0;
    }
    @try {
        ((void (*)(id, SEL, CGSize, NSInteger, NSInteger))objc_msgSend)(
            host, sel, size, (NSInteger)1, (NSInteger)1);
    } @catch (NSException *exception) {
        AevonOwnDisplayLog(@"win: own ref threw %s",
                           exception.reason != nil ? [exception.reason UTF8String] : "-");
        return 0;
    }
    AevonOwnDisplayLog(@"win: own ref %.0fx%.0f via=%s", size.width, size.height, tag);
    return 1;
}






/// 0 = 没在跑 / 1 = 在建 / 2 = 建好了（等取） / 3 = 失败。**不消费状态。**
///
/// 拆成「问状态」和「取对象」两个而不是一个带出参的函数，是因为 `id *` 在 Swift
/// 里会被导入成 `AutoreleasingUnsafeMutablePointer`，那是个每一版 SDK 都可能换
/// 写法的形状。两个返回值都是标量/对象，没有指针可猜。
NSInteger AevonOwnState(void) {
    // 超时自阉。启动事务不回调时 phase 会冻在「在建」，而下一张卡会因此以为
    // 「已经有一次在跑」直接落到老路 —— 那是个看不见的永久降级，必须自己结束。
    if (AevonOwnPhase == 1 && AevonOwnAt > 0) {
        double waited = CFAbsoluteTimeGetCurrent() - AevonOwnAt;
        if (waited > 6.0) {
            AevonOwnLog(@"win: own timeout after %.1fs, falling back", waited);
            AevonOwnPhase = 3;
        }
    }
    return AevonOwnPhase;
}

/// 取走建好的 scene（phase 回到 idle）。没有就返回 nil。
id AevonOwnFetch(void) {
    if (AevonOwnPhase != 2 || AevonOwnScene == nil) return nil;
    id scene = AevonOwnScene;
    // 一个 scene 只交给一张卡：第二次 `fetch` 拿到的是「没有」，不是上一次那张。
    AevonOwnScene = nil;
    AevonOwnPhase = 0;
    // 从这一刻起，屏幕上那张卡的 scene 归我们管 —— 关卡要销毁它。
    AevonOwnHeld = 1;
    return scene;
}

/// 这一次卡片**没有**用自建的 scene（复用了系统那个，或者走了老路）。
/// 由 `openCard` 在决定来源之后调一次，否则上一次的「持有」会留到下一次关卡。
void AevonOwnClear(void) {
    AevonOwnHeld = 0;
}

// 0.2.59 — 前向声明：真身在分流那一段（`AevonOpenDecide` 上面），预热要用它。
static BOOL AevonWindowBlacklisted(const char *bundle);

/// 0.2.59 — **预热**：把 App 的进程先拉起来，但不建 scene、不上屏。
///
/// 为什么需要：Aevon(200) 里抖音从圆盘打开是
///   `own start … t=1ms wait=2ms` → **749 ms** → `own scene up` → 又 577 ms 才首帧
/// 那 749 ms 全在「等 App 进程起来」（`app: boot pid=26158` 就落在这一段里）。
/// 它不是我们的开销，但用户量的是「点了到看见」，所以只能把这一段挪到**用户还
/// 在划圆盘**的时候去付：悬停 0.18 s 就开始拉进程，松手选中时进程往往已经在跑，
/// `own start` 的等待就只剩建 scene 那一小截。
///
/// 与 `AevonOwnStart` 的关系：这条**完全不碰** `AevonOwnPhase / AevonOwnScene`。
/// 它只做启动事务，completion 里什么都不建 —— 这样就算预热之后用户没选这个 App，
/// 也不会留下一个「有 scene 没人取」的孤儿把下一次打开顶掉。
///
/// 闸（少一条都会变成为难用户）：
///   · 总闸 `notify.off` 在；
///   · 黑名单里的 App 不预热（那是「别碰我的路」）；
///   · 进程已经在跑 ⇒ 预热没有意义，直接返回；
///   · 同一个 bundle 8 s 内只热一次（来回划不会连开三次）；
///   · `AevonOwnPhase` 不是 idle 时不动（另一条启动链正在跑，别开第二条）。
NSInteger AevonOwnWarm(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length < 3) return 0;
    if (![NSThread isMainThread]) {
        NSString *copy = [bundleID copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonOwnWarm(copy);
            [copy release];
        });
        return 0;
    }
    const char *raw = [bundleID UTF8String];
    if (raw == NULL) return 0;
    if (AevonWindowBlacklisted(raw)) return 0;
    if (AevonOwnPhase == 1 || AevonOwnPhase == 2) return 0;
    // `> 0` 才是「在跑」；`-1/-2` 是「查不到」，那种情况预热正好有用。
    if (AevonAppPid(bundleID) > 0) return 0;
    double now = CFAbsoluteTimeGetCurrent();
    if (strcmp(AevonWarmBundle, raw) == 0 && now - AevonWarmAt < 8.0) return 0;
    snprintf(AevonWarmBundle, sizeof(AevonWarmBundle), "%s", raw);
    AevonWarmAt = now;

    double started = CFAbsoluteTimeGetCurrent();
    NSString *doneBundle = [bundleID copy];
    // `setCompletionBlock:` 把 block 拷到堆上时，MRC 会给捕获的 `doneBundle` 记一次 retain；
    // 那之后这个字符串的寿命就归 block 了（block 执行完释放、或随 transaction 一起释放）。
    // 所以后面对「已交出」的路径**一个字节都不再 release** —— 宁可漏一个小字符串，
    // 也不能在「begin 返回 NO 但 completion 仍然被调」这种实现细节上踩双释放。
    BOOL handedOff = NO;
    @try {
        Class idCls = NSClassFromString(@"RBSProcessIdentity");
        id identity = ((id (*)(id, SEL, id))objc_msgSend)(
            idCls, sel_registerName("identityForEmbeddedApplicationIdentifier:"), bundleID);
        if (identity == nil) { [doneBundle release]; return 0; }

        Class mgrCls = NSClassFromString(@"FBProcessManager");
        id manager = ((id (*)(id, SEL))objc_msgSend)(
            mgrCls, sel_registerName("sharedInstance"));
        if (manager == nil) { [doneBundle release]; return 0; }

        Class ctxCls = NSClassFromString(@"FBMutableProcessExecutionContext");
        Class txnCls = NSClassFromString(@"FBApplicationProcessLaunchTransaction");
        id (^provider)(void) = ^id {
            id context = ((id (*)(id, SEL))objc_msgSend)(ctxCls, sel_registerName("new"));
            if (context == nil) return nil;
            ((void (*)(id, SEL, id))objc_msgSend)(
                context, sel_registerName("setIdentity:"), identity);
            ((void (*)(id, SEL, id))objc_msgSend)(
                context, sel_registerName("setEnvironment:"), @{});
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                context, sel_registerName("setLaunchIntent:"), (NSInteger)4);
            return ((id (*)(id, SEL, id))objc_msgSend)(
                manager, sel_registerName("launchProcessWithContext:"), context);
        };
        // 与 `AevonOwnStart` 同一条理由：MRC 下栈上的 block 会被 `setCompletionBlock:`
        // 拷到堆上，捕获的 `identity` / `manager` 要各存一份 —— 显式 copy，且故意不
        // release（每预热一次漏几十字节，换「不会因为一个不知道有没有 retain 的
        // 初始化器而崩」）。
        id providerHeap = [provider copy];
        id allocated = ((id (*)(id, SEL))objc_msgSend)(txnCls, sel_registerName("alloc"));
        id transaction = allocated != nil
            ? ((id (*)(id, SEL, id, id))objc_msgSend)(
                  allocated, sel_registerName("initWithProcessIdentity:executionContextProvider:"),
                  identity, providerHeap)
            : nil;
        if (transaction == nil) { [doneBundle release]; return 0; }

        void (^done)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                double ms = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
                AevonLogRaw([[NSString stringWithFormat:
                              @"win: warm done b=%@ at=%.0fms pid=%d",
                              doneBundle, ms, AevonAppPid(doneBundle)] UTF8String]);
                [doneBundle release];
            });
        };
        ((void (*)(id, SEL, id))objc_msgSend)(
            transaction, sel_registerName("setCompletionBlock:"), done);
        handedOff = YES;
        if (!AevonCallVoid(transaction, @"begin")) {
            AevonLogRaw([[NSString stringWithFormat:@"win: warm refused b=%@", doneBundle] UTF8String]);
            return 0;
        }
        AevonLogRaw([[NSString stringWithFormat:@"win: warm start b=%@", doneBundle] UTF8String]);
        return 1;
    } @catch (NSException *e) {
        AevonLogRaw([[NSString stringWithFormat:@"win: warm threw b=%@ %s", doneBundle,
                      e.reason != nil ? [e.reason UTF8String] : "-"] UTF8String]);
        if (!handedOff) [doneBundle release];
        return 0;
    }
}

/// 这张卡上的 scene 是不是我们建的。关卡的动作完全不同：
/// 借来的 scene 要「推回后台」，自建的要**销毁**（`destroyScene:`），
/// 否则它会带着一个 presenter 一直挂在 SpringBoard 里，下一次打开同一个 App
/// 就会跟系统自己那个撞名。
NSInteger AevonOwnIsOwned(NSString *bundleID) {
    if (!AevonOwnHeld) return 0;
    if (bundleID.length == 0) return 0;
    return [bundleID isEqualToString:AevonOwnBundle] ? 1 : 0;
}

/// 0.2.25 — 「回桌面」的三级阶梯。
///
/// 0.2.24 的普查已经回答了「有什么可调」：这台机器上
/// `SBHomeScreenController` 不存在（noclass），`SBSwitcherController` 与
/// `SBFluidSwitcherGestureManager` 没有 sharedInstance（nosel），而
/// `SBMainSwitcherControllerCoordinator -handleHomeButtonPress` 调得到却没有
/// 效果（回读 `isSpringBoardActive=0`）。「名字在」不等于「这一级能用」。
///
/// 于是这一版不再普查，改成三级**按读数推进**的阶梯，一次只差一种做法：
///   1. `SBUIController -handleHomeButtonSinglePressUpForWindowScene:` —— 真机上
///      硬件 home 键走的就是这一条（B24@0:8@16，一个对象参数）；
///   2. `SBMainSwitcherControllerCoordinator
///      -dismissMainSwitcherNoninteractivelyAnimated:` —— 含义是「不经过手势，
///      把主切换器收起」，也就是回到桌面；
///   3. `SBFluidSwitcherViewController -handleHomeButtonPress` —— 从当前页的
///      响应链上把那个 controller 找出来，让它自己处理。
/// 谁生效由 Swift 侧回读 `isSpringBoardActive` 判定；三级都不行才动页面。

/// 0.2.34 — 这个 window scene 是不是「主屏那张」以外的辅助 scene。
///
/// 0.2.33 的真机日志把这一步拍死了：
///   `win: home first open step1 threw -[SBSystemApertureWindowScene
///    isExternalDisplayWindowScene]: unrecognized selector sent to instance …`
/// `connectedScenes` 里第一个 window scene 是 **灵动岛** 那个
/// `SBSystemApertureWindowScene`，把它交给
/// `handleHomeButtonSinglePressUpForWindowScene:` 会在这条内部链上抛异常；
/// `@try` 把异常吞成一句日志，home 一次都没真的发出去
/// （`home first open ready waited=1400ms springboard=0`）。
static BOOL AevonSceneIsAuxiliary(UIScene *scene) {
    if (scene == nil) return YES;
    NSString *name = NSStringFromClass([scene class]);
    if (name.length == 0) return YES;
    if ([name rangeOfString:@"SystemAperture"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"External"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Wallpaper"].location != NSNotFound) return YES;
    return NO;
}

/// SpringBoard 主屏的 window scene。走 `connectedScenes`（`windows` 在
/// iOS 15 起被标成 deprecated，而本工程的 ObjC 把 deprecated 当错误）。
///
/// 0.2.34 — 先剔掉辅助 scene（灵动岛 / 外接屏 / 壁纸），再按 `UIScreen.mainScreen`
/// 认主屏；main 那个且前台活跃的最优先。`AevonHomeStep` 的日志会打出最后挑中
/// 的类名，真机上一眼就能确认它是不是 `SBWindowScene`。
static id AevonSBWindowScene(void) {
    @try {
        id fallback = nil;
        id mainIdle = nil;
        UIScreen *mainScreen = [UIScreen mainScreen];
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (AevonSceneIsAuxiliary(scene)) continue;
            UIWindowScene *window = (UIWindowScene *)scene;
            BOOL onMain = (mainScreen != nil && window.screen == mainScreen);
            if (onMain && scene.activationState == UISceneActivationStateForegroundActive) {
                return scene;
            }
            if (onMain && mainIdle == nil) mainIdle = scene;
            if (fallback == nil) fallback = scene;
        }
        return mainIdle != nil ? mainIdle : fallback;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

/// 只取 `sharedInstance` 这一种单例；取不到返回 nil（调用方记 nosel）。
static id AevonHomeShared(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

/// 0.2.34 — 第 2 级单独抽出来：第 1 级抛异常或挑不到主屏 scene 时要能当场回落。
///
/// `SBMainSwitcherControllerCoordinator -dismissMainSwitcherNoninteractivelyAnimated:`
/// 是「不经过手势把主切换器/全屏页收起」；这个类在新版被改名时，再退到
/// `SBUIController` 那条第 0 级都不带 scene 的 home 键（老系统上一直在）。
static NSString *AevonHomeRunStep2(void) {
    id coordinator = AevonHomeShared(@"SBMainSwitcherControllerCoordinator");
    SEL sel = NSSelectorFromString(@"dismissMainSwitcherNoninteractivelyAnimated:");
    if (coordinator != nil && [coordinator respondsToSelector:sel]) {
        ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(coordinator, sel, YES);
        return @"step2 dismiss-main-switcher YES";
    }
    id ctl = AevonHomeShared(@"SBUIController");
    SEL plain = NSSelectorFromString(@"handleHomeButtonSinglePressUp");
    if (ctl != nil && [ctl respondsToSelector:plain]) {
        ((void (*)(id, SEL))objc_msgSend)(ctl, plain);
        return @"step2 SBUIController single-press-up";
    }
    return @"step2 nosel";
}

/// 0.2.25 — 第 `step` 级回桌面。`page` 只有第 3 级用到（往上走响应链）。
/// 返回一句日志；`nil` = step 不认识。没接上的那一级返回原因，不算失败。
///
/// 0.2.34 — 第 1 级再也不是「抛异常就到此为止」：异常 / 没有主屏 scene 时
/// 当场执行第 2 级，并把两级都写进返回串。0.2.33 的 `step1 threw …` 之后
/// Swift 侧还在原地等 1.4 秒（`springboard=0`），用户看到的就是「不回桌面」。
NSString *AevonHomeStep(int step, id page) {
    @try {
        if (step == 1) {
            id ctl = AevonHomeShared(@"SBUIController");
            SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:");
            id scene = AevonSBWindowScene();
            if (ctl != nil && [ctl respondsToSelector:sel] && scene != nil) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(ctl, sel, scene);
                    return [NSString stringWithFormat:
                            @"step1 SBUIController single-press-up scene=%@",
                            NSStringFromClass([scene class])];
                } @catch (NSException *e) {
                    return [NSString stringWithFormat:@"step1 threw %@ -> %@",
                            e.reason != nil ? e.reason : @"-", AevonHomeRunStep2()];
                }
            }
            NSString *why = @"step1 nosel";
            if (ctl != nil && [ctl respondsToSelector:sel]) why = @"step1 scene nil";
            return [NSString stringWithFormat:@"%@ -> %@", why, AevonHomeRunStep2()];
        }
        if (step == 2) {
            return AevonHomeRunStep2();
        }
        if (step == 3) {
            id node = page;
            int steps = 0;
            while (node != nil && steps < 40) {
                if ([NSStringFromClass([node class]) containsString:@"SBFluidSwitcherViewController"]) break;
                node = [node nextResponder];
                steps += 1;
            }
            SEL sel = NSSelectorFromString(@"handleHomeButtonPress");
            if (node == nil || ![node respondsToSelector:sel]) {
                return @"step3 switcher controller not found";
            }
            ((BOOL (*)(id, SEL))objc_msgSend)(node, sel);
            return @"step3 switcher-controller handleHomeButtonPress";
        }
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"step%d threw %@", step,
                e.reason != nil ? e.reason : @"-"];
    }
    return nil;
}

/// 0.2.24 — 回桌面的**结果读数**：1 = SpringBoard 已经在前台（桌面在屏上），
/// 0 = 还在某个 App 页里，-1 = 读不到。调用方按 1/非 1 决定要不要走兜底。
int AevonSpringboardActive(void) {
    @try {
        id ws = nil;
        Class mainCls = NSClassFromString(@"SBMainWorkspace");
        if (mainCls != Nil && [mainCls respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
            ws = ((id (*)(id, SEL))objc_msgSend)((id)mainCls, NSSelectorFromString(@"sharedInstance"));
        }
        Class wsCls = NSClassFromString(@"SBWorkspace");
        if (ws == nil && wsCls != Nil &&
            [wsCls respondsToSelector:NSSelectorFromString(@"mainWorkspace")]) {
            ws = ((id (*)(id, SEL))objc_msgSend)((id)wsCls, NSSelectorFromString(@"mainWorkspace"));
        }
        if (ws == nil) return -1;
        SEL sel = NSSelectorFromString(@"isSpringBoardActive");
        if (![ws respondsToSelector:sel]) return -1;
        return ((BOOL (*)(id, SEL))objc_msgSend)(ws, sel) ? 1 : 0;
    } @catch (__unused NSException *e) {
        return -1;
    }
}

/// 0.2.38 — 「把自建 scene 原样交给系统」，**不销毁**。
///
/// 0.2.37 的真机把这条路拍死了：用户从卡片里点桌面图标全屏打开**系统设置**时，
/// 卡片让路 → `AevonOwnDestroy` 在系统正要把这张 scene 拉成全屏的那一拍把它
/// destroy 掉，设置直接闪退；其它 App 没那么脆，但也常常要重新建 scene，中间
/// 那一段就是「全屏底部黑」。
/// 让路的语义是**松手**，不是**拆掉**：清掉我们这边的账（`AevonOwnHeld`），
/// scene 留给系统接着用 —— 它的 identity 就是 `sceneID:<bundle>-default`，
/// 正是系统要的那一张。
NSInteger AevonOwnHandOver(NSString *bundleID) {
    if (!AevonOwnHeld) return 0;
    if (bundleID.length == 0) return 0;
    if (![bundleID isEqualToString:AevonOwnBundle]) return 0;
    AevonOwnPhase = 0;
    AevonOwnScene = nil;
    AevonOwnHeld = 0;
    AevonOwnLog(@"win: own handed over %@", AevonOwnIdentity != nil ? AevonOwnIdentity : @"-");
    return 1;
}

/// 销毁自建 scene。返回 1 表示这一句发出去了。
NSInteger AevonOwnDestroy(NSString *bundleID) {
    if (bundleID.length == 0 || AevonOwnIdentity == nil) return 0;
    if (![bundleID isEqualToString:AevonOwnBundle]) return 0;
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    if (mgrCls == Nil) return 0;
    @try {
        id manager = ((id (*)(id, SEL))objc_msgSend)(
            mgrCls, sel_registerName("sharedInstance"));
        if (manager == nil) return 0;
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            manager, sel_registerName("destroyScene:withTransitionContext:"),
            AevonOwnIdentity, nil);
        AevonOwnLog(@"win: own destroyed %@", AevonOwnIdentity);
        AevonOwnPhase = 0;
        AevonOwnScene = nil;
        AevonOwnHeld = 0;
        return 1;
    } @catch (NSException *e) {
        AevonOwnLog(@"win: own destroy threw %s",
                    e.reason != nil ? [e.reason UTF8String] : "-");
        return 0;
    }
}

// MARK: - Reading the real method table (0.0.28)

// 0.0.27 asked for three readings and got `absent` three times:
// `FBSceneLayerManager.layers`, `_UISceneLayerHostContainerView.hostedLayers`
// and the deactivation-reason getter. Those answers were about the *names* in
// this source file, not about the scene, and the difference decided which of
// three fixes came next. Guessing a private accessor twice is two rounds lost,
// so the names come from the runtime from now on: walk the method table, call
// only the no-argument getters whose name mentions a keyword, and print the name
// beside the value. A name that answers is a name that exists; a keyword with no
// hits says the word is not in this class instead of leaving a dash in the log.


// MARK: - Hooks (0.0.27)

// The mother ship's own way in, and why 0.0.21's refusal is worth another look.
// Her binary calls `_setDeactivationReasons:onScene:withSettings:reason:` and
// hooks `_scene:interceptUpdateWithNewSettings:`, and
// `analysis/incident-2026-10-13-black-content-round5.md` has both encodings read
// off a device: `v48@0:8Q16@24@32@40` and the getter beside them.
//
// 0.0.21 installed two replacements and reported both as "refused". Its check was
// `method_getImplementation(m) != replacement`. On arm64e the runtime signs the
// IMP it stores, so a write that worked perfectly reads back as a *different*
// pointer and the code called that a refusal. That is a bad check, not a refused
// write, and the difference is this whole version.
//
// Three consequences, all of them in the code below:
//
//   1. The write goes through `imp_implementationWithBlock`, the documented way
//      to install an IMP on arm64e: the runtime builds and signs the trampoline,
//      so nothing here ever hands a bare function pointer to the dispatch path.
//   2. A pointer comparison can no longer say whether a hook is live, so a
//      30-line self test on a class of our own answers it before SpringBoard is
//      touched at all.
//   3. What says "live" afterwards is a call counter. A hook that is installed
//      and never called is the same thing as no hook, and only the counter can
//      tell them apart.

/// 0.0.52 — six became eight: the three intercept candidates join the
/// deactivation hook, and two spare slots cost five words of static memory.
/// 0.0.54 — seven: one of the three candidates (the hosting view controller)
/// was proved dead on the phone and is gone.
/// 0.2.89 — twelve: the two activation-beat probes (`act-activate` /
/// `act-scene`) each reserve one slot per owning class, and the deact /
/// intercept loops already take up to four. Running out is silent — the
/// loop breaks and the version ships with nothing installed — so the table
/// is sized for the worst case rather than the usual one.
#define AEVON_HOOK_SLOTS 24

typedef struct {
    Class cls;
    SEL sel;
    IMP original;
    IMP replacement;
    const char *label;
} AevonHookSlot;

static AevonHookSlot AevonSlots[AEVON_HOOK_SLOTS];
static int AevonSlotCount = 0;

/// 0.0.98 — 从「一个 bundle」变成「一组 bundle」。
///
/// 0.0.97 及以前这里只有一个名字，整个 tweak 因此只能同时守住一个 scene：
/// 主窗降级成停靠小窗之后，它的 scene 不再出现在名单里，保活钩子一律放行，
/// 系统的 deactivation 第一拍就把它收走 —— 用户看到的是「停靠的那个窗黑掉」。
///
/// 16 槽不是随手取的：V2 的上限是「主窗 1 + 停靠 10」，再加几张正在降级途中的
/// 过渡窗，就需要 16 个位置。每个槽 128 字节，整张表 2 KB，常驻代价可以忽略。
/// 槽满时不覆盖、不淘汰，直接拒绝登记并留下计数 —— 一个没被登记的窗会黑，
/// 而「窗黑」与「名字没登记上」在日志里必须是两件能分开的事。
#define AEVON_ARMED_MAX 16
static char AevonArmed[AEVON_ARMED_MAX][128];
/// 0.2.37 — 每一格是什么时候登记的（`AevonHookArm` 一拍）。只给「卡片给全屏让路」
/// 的年龄闸用：建卡那一两百毫秒里系统本来就会把 scene 从整屏改成卡片尺寸，
/// 那一次不是「系统要全屏接管它」。卡片活过 0.9 秒还收到整屏 frame 才是。
static CFAbsoluteTime AevonArmedAt[AEVON_ARMED_MAX];
/// 0.3.61 — 冷分享静默期里，这一槽被系统的整屏 frame 顶到了几次。
///
/// Aevon(286) 的 5/7 次失败全是同一件事：卡已经出帧，`land: url fire` 之后
/// 系统又对同一个 scene 写了一次 `430x932`，年龄超过 0.40 s ⇒ 被让路判据当成
/// 「用户要全屏」。那一次不是用户操作，是我们自己放过去的那次延迟激活在提交。
///
/// 计数只在 `AevonHookArm` 登记时清零，上限 8：真的跟系统拉锯起来也不能无限改。
static int AevonArmedCount = 0;
static long AevonArmedRefused = 0;

static long AevonDeactSetCalls = 0;
static long AevonDeactStripped = 0;
/// 0.2.57 — 最近一次被清零的 reasons 位掩码。Aevon(198) 里 `deact_set=21`
/// 却有 `stripped=6`：这条钩子被调的 21 次里，15 次 `reasons` 本来就是 0
/// （系统只是在重新声明「可以睡」），真正被我们拦下来的只有 6 次。日志里那个
/// `scene deactivation #26` 数的是前者，所以它既不能说明场景真的被去激活过，
/// 也不能说明我们动过手。留一份原值，「32 / 34 / 2」这几种位分别对应什么处置
/// 才有据可查。
static volatile long AevonDeactReasons = 0;

/// Eight lines of what the hooks actually saw, written as C strings on purpose:
/// these run inside SpringBoard's scene-update path, and formatting an
/// `NSString` there is work nobody asked for. The first four calls per hook are
/// the interesting ones; after that only the counters move.
///
/// Sixteen became twenty-four in 0.0.30: the deactivation hook alone still fills
/// the first eight (four `deact-set`, four `stripped`), and the push traces are
/// the ones this version is read from.
static char AevonTrace[32][192];
static long AevonTraceCount = 0;

static void AevonRawTrace(const char *tag, const char *format, ...) {
    long index = __sync_fetch_and_add(&AevonTraceCount, 1);
    if (index < 0 || index >= (long)(sizeof(AevonTrace) / sizeof(AevonTrace[0]))) return;
    int head = snprintf(AevonTrace[index], sizeof(AevonTrace[index]), "%s ", tag);
    if (head < 0 || head >= (int)sizeof(AevonTrace[index])) return;
    va_list args;
    va_start(args, format);
    vsnprintf(AevonTrace[index] + head, sizeof(AevonTrace[index]) - (size_t)head,
              format, args);
    va_end(args);
}

/// A scene's identifier as a C string, or "?" when it will not name itself.
/// Valid only for the length of the call, which is all any caller here needs.
static const char *AevonSceneName(id scene) {
    if (scene == nil || ![scene respondsToSelector:@selector(identifier)]) return "?";
    id ident = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identifier));
    if (![ident isKindOfClass:[NSString class]]) return "?";
    const char *text = [(NSString *)ident UTF8String];
    return text != NULL ? text : "?";
}

static BOOL AevonIsArmed(void) {
    return AevonArmedCount > 0;
}

/// 这个 scene 归不归我们管 —— 逐个槽比对。
///
/// 0.0.98 之前这里只有一个名字，`strstr` 一次就是全部答案；现在必须走完整张表，
/// 否则第二个窗永远不算「我的」，保活与 frame 写入都会漏掉它。
static int AevonSlotOfScene(id scene) {
    if (AevonArmedCount <= 0) return -1;
    const char *name = AevonSceneName(scene);
    if (name == NULL || name[0] == '\0' || strcmp(name, "?") == 0) return -1;
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] == '\0') continue;
        if (strstr(name, AevonArmed[i]) != NULL) return i;
    }
    return -1;
}

static BOOL AevonSceneIsMine(id scene) {
    return AevonSlotOfScene(scene) >= 0;
}

// MARK: - 第二条口径：拦截点登记（0.2.4）

/// 名字表。`AEVON_SEEN_MAX` 个槽，够放下「同时开着的一批 App」；满了就不再收，
/// 因为这张表只是 `enumerateScenesWithBlock:` 的补集，不是全量清单。
#define AEVON_SEEN_MAX 16
static char AevonSeenName[AEVON_SEEN_MAX][96];
/// 与名字同槽的**弱**引用。裸指针在这里是错的：scene 由系统持有并销毁，而我们
/// 每一拍都要读它的 `identifier` —— 存裸指针的那一版会在 App 退出后变成悬空指针，
/// 下一次读名字就是一次跨进程的野指针访问。弱引用在销毁时自动置 nil，正好。
static id AevonSeenWeak[AEVON_SEEN_MAX];
static int AevonSeenCount = 0;

/// 从拦截点顺手记下这个 scene。
///
/// 0.2.4 — 为什么需要第二条口径。Aevon(173) 里高德那六行现场是这样的：
///
///     win: wait scene 1s app=-1 n=5 com.apple.UIKit.remote-keyboard|com.apple.springboard|…
///
/// 六行里从头到尾没有 autonavi，看起来像「scene 压根没建」。但同一时段的 hook
/// trace 里有 `sceneID:com.autonavi.amap-default`，`mine=1 fg=0 amend=1` ——
/// 系统已经在给它推 settings，而且被我们改了三次前台。两件事只能同时成立在一个
/// 前提下：**scene 已经建了，只是 `enumerateScenesWithBlock:` 列不出它**。
/// 那一类 scene 是「FrontBoard 侧已登记、客户端还没连上」的空壳，而拦截方法的
/// 入参正是它 —— 系统把 settings 交给它，就说明它存在。
///
/// 所以这里不判断归不归我们管：只要名字是 `sceneID:` 开头、不是 SpringBoard 自己
/// 的，就记下来。归谁管由 `AevonSlotOfScene` 在真正的建卡路径上决定。
/// 0.3.1 — 三条取证线的前向声明。`AevonSeenNote` 在文件很靠前的位置，
/// 而线 C 的实现跟着 `AevonActFrameBirth` 一起放（那里才有 scene 相关的上下文）。

static void AevonSeenNote(id scene) {
    if (scene == nil) return;
    const char *name = AevonSceneName(scene);
    if (name == NULL || name[0] == '\0' || strcmp(name, "?") == 0) return;
    if (strncmp(name, "sceneID:", 8) != 0) return;
    if (strstr(name, "com.apple.springboard") != NULL) return;

    int slot = -1;
    for (int i = 0; i < AevonSeenCount; i++) {
        if (strcmp(AevonSeenName[i], name) == 0) { slot = i; break; }
    }
    if (slot < 0) {
        if (AevonSeenCount < AEVON_SEEN_MAX) {
            slot = AevonSeenCount++;
            strlcpy(AevonSeenName[slot], name, sizeof(AevonSeenName[slot]));
        } else {
            // 满了先回收：弱引用为 nil 说明那个 scene 已经销毁，名字留着只会
            // 永久占坑。16 个槽用完就再也收不进新的 = 又一次「一次开机 N 次」
            // 那种配额错误（0.1.93 的教训），所以必须是可回收的。
            for (int i = 0; i < AEVON_SEEN_MAX; i++) {
                if (objc_loadWeak(&AevonSeenWeak[i]) != nil) continue;
                slot = i;
                strlcpy(AevonSeenName[slot], name, sizeof(AevonSeenName[slot]));
                break;
            }
            if (slot < 0) return;
        }
    }
    objc_storeWeak(&AevonSeenWeak[slot], scene);
    // 0.3.1 — 线 C：第一次看见这个 scene 的那一刻，正是「已建、还没上屏」。
    // 挂在这里而不是 completion 里，是因为 completion 那个 block 由系统持有、
    // 我们只在钩子里见过它的指针，包装它等于改行为；而 `AevonSeenNote` 是
    // 系统自己把 scene 交出来的第一个只读窗口，足够回答「presenter 能不能建」。
    // 0.3.10 — G 线**不挂在这里**了。`AevonSeenNote` 的唯一调用点是 intercept
    // 钩子，而那只在建卡时装；URL 清除后不建卡 ⇒ 这里永远不跑（Aevon(235) 实测）。
    // G 线改由 `AevonProbeP1Scan` 开机自枚举，见那里。
}

/// 拦截点记过的、名字含这个 bundle 的 scene。没有就返回 nil。
///
/// `objc_loadWeak` 而不是 `objc_loadWeakRetained`：调用点在主线程、拿到就立刻用，
/// 中间没有别的释放机会；而 `+1` 的那一版在 MRC 下要么漏 release（每次开窗漏一个
/// scene 引用），要么依赖 autorelease pool 的深度 —— 两条都比这里多一个失败面。
/// 0.2.73 — 直接问 `FBSceneManager`：「这个 bundle 现在有活着的 scene 吗」。
///
/// 0.2.72 真机，两次授权都是这一行结束的：
///
///     notify: auth swap giveup b=com.tencent.mqq fg=-1 live=0 tick=60 build=0
///
/// 而同一分钟 QQ 的 paste token 已经出现（`notify: paste token b=com.tcl.tclplus`
/// 紧接 `notify: share source b=com.tencent.mqq`）—— 进程在跑、scene 在，只是它
/// **没有从我们的拦截点经过**：冷启动那一次 settings 更新早于这次登记，之后
/// 又没有第二次更新，于是 `AevonSeenNote` 永远没记到它。
///
/// 「我们没看到」被当成了「它不存在」，收卡就必然放弃。这里补一条不依赖拦截
/// 的读数：枚举系统的 scene 账本，按 identifier 找。它只读，且只在主线程调用。
/// 先声明：定义在下面（`AevonSceneForeground` 之后更远的 `AevonContentStateOf`）。
/// `AevonLiveSceneForBundle` 要用它给同一个 bundle 的多份 scene 打分。
long AevonContentStateOf(id scene);

static id AevonLiveSceneForBundle(NSString *bundle) {
    if (bundle == nil || [bundle length] == 0) return nil;
    const char *text = [bundle UTF8String];
    if (text == NULL || text[0] == '\0') return nil;
    id manager = AevonSceneManager();
    if (manager == nil) return nil;
    __block id found = nil;
    __block int foundScore = -1;
    __block int shells = 0;
    AevonEnumerateScenes(manager, ^(id scene) {
        if (scene == nil) return;
        const char *name = AevonSceneName(scene);
        if (name == NULL || strcmp(name, "?") == 0) return;
        if (strstr(name, text) == NULL) return;
        // 0.2.79 — 同一份 bundle 可能有好几份 scene（自建那张拆掉之后还会在
        // 账本里留一会儿）。以前取第一份，正好取到空壳：Aevon(212) 12:21:06
        // 的微信就是 `cs=0` + `natural=430x932`，贴上去整张卡是黑的。
        // 这里按「前台运行 / 前台可见 / 有内容 / settings 前台位」打分，
        // 全为 0 就当作只有空壳，交回 nil —— 调用方会走自建那条路。
        int score = 0;
        if (AevonBoolOf(scene, @"accessibilitySceneIsRunningInForeground") == 1) score += 4;
        if (AevonBoolOf(scene, @"accessibilitySceneIsForegroundVisible") == 1) score += 4;
        long state = AevonContentStateOf(scene);
        if (state >= 2) score += 2;
        else if (state == 1) score += 1;
        if (AevonSceneForeground(scene) == 1) score += 2;
        if (score == 0) shells += 1;
        if (score > foundScore) { foundScore = score; found = scene; }
    });
    if (foundScore <= 0) return nil;
    if (shells > 0) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"win: live scene pick b=%@ best=%d shells=%d",
                      bundle, foundScore, shells] UTF8String]);
    }
    return found;
}

id AevonSeenSceneForBundle(NSString *bundle) {
    if (bundle == nil || [bundle length] == 0) return nil;
    const char *text = [bundle UTF8String];
    if (text == NULL || text[0] == '\0') return nil;
    for (int i = 0; i < AevonSeenCount; i++) {
        if (strstr(AevonSeenName[i], text) == NULL) continue;
        id scene = objc_loadWeak(&AevonSeenWeak[i]);
        if (scene == nil) continue;
        // 0.2.79 — **空壳不交。** 与 `AevonLiveSceneForBundle` 同一把尺：
        // 前台运行 / 前台可见 / 有内容 / settings 前台位，四条全是 0 就是空壳。
        // 12:21:06 的微信就是被这一格交出去的（`cs=0`），整张卡黑。
        if (AevonBoolOf(scene, @"accessibilitySceneIsRunningInForeground") == 0 &&
            AevonBoolOf(scene, @"accessibilitySceneIsForegroundVisible") == 0 &&
            AevonContentStateOf(scene) == 0 &&
            AevonSceneForeground(scene) != 1) {
            continue;
        }
        return scene;
    }
    // 0.2.73 — 表里查不到不等于没有 scene（见上面那段真机现场）。
    return AevonLiveSceneForBundle(bundle);
}

/// 表里现在记了几个 —— 日志用，不参与任何判断。
int AevonSeenCountOf(void) { return AevonSeenCount; }

/// 追加一个名字。已经在表里的不重复登记（同一个 App 被再选一次会走到这里）。
void AevonHookArm(NSString *bundle) {
    if (bundle == nil) return;
    const char *text = [bundle UTF8String];
    if (text == NULL || text[0] == '\0') return;
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] == '\0') continue;
        if (strcmp(AevonArmed[i], text) == 0) return;
    }
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] != '\0') continue;
        strlcpy(AevonArmed[i], text, sizeof(AevonArmed[i]));
        AevonArmedAt[i] = CFAbsoluteTimeGetCurrent();
        __sync_fetch_and_add(&AevonArmedCount, 1);
        return;
    }
    __sync_fetch_and_add(&AevonArmedRefused, 1);
}

/// 撤回一个名字。`nil` / 空串 = 全部撤回 —— 那是 0.0.97 之前的语义，留在最后
/// 一个参数位置上，好让还没改完的调用点不会悄悄变成空操作。
void AevonHookDisarm(NSString *bundle) {
    if (bundle == nil || [bundle length] == 0) {
        for (int i = 0; i < AEVON_ARMED_MAX; i++) {
            AevonArmed[i][0] = '\0';
            AevonArmedAt[i] = 0;
            }
        AevonArmedCount = 0;
        return;
    }
    const char *text = [bundle UTF8String];
    if (text == NULL) return;
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] == '\0') continue;
        if (strcmp(AevonArmed[i], text) != 0) continue;
        AevonArmed[i][0] = '\0';
        AevonArmedAt[i] = 0;
        if (AevonArmedCount > 0) __sync_fetch_and_sub(&AevonArmedCount, 1);
    }
}

/// 表里现在有谁，逗号分隔。日志用。
NSString *AevonHookArmedList(void) {
    if (AevonArmedCount <= 0) return @"no";
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] == '\0') continue;
        if ([out length] > 0) [out appendString:@","];
        [out appendFormat:@"%s", AevonArmed[i]];
    }
    return [out length] > 0 ? out : @"no";
}

/// A `BOOL` getter read with the ABI it has, as a number, `-1` for "no such
/// method". C, not Swift, because this runs inside the settings path.
static int AevonFlagOf(id object, const char *name) {
    if (object == nil || name == NULL) return -1;
    SEL sel = sel_registerName(name);
    if (![object respondsToSelector:sel]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel) ? 1 : 0;
}


// MARK: - Pushing a scene into the foreground (0.0.30)

/// 0.0.29 installed the interceptor the mother ship's route is built on, and the
/// device answered `wrote=yes back=… exact`, and then ran for eight seconds with
/// `intercept=0`. A hook that is installed and never called is the same thing as
/// no hook, and Aevon(28) proved it: the same scene reported `layers=2`,
/// `hostedLayers=2`, `nonHostedLayers=0`, a card that was still black, and
/// settings that said `isForeground=no isBackgrounded=yes`.
///
/// So the settings are pushed rather than awaited. The scene object is already
/// in hand; the question is only by which door, and the doors are read off the
/// method table before any of them is used. A door whose encoding does not match
/// is stepped past, not guessed at.

/// The deactivation manager, captured from the first argument of the one hook
/// the device has actually called. `AevonReasonsOf` spent two versions printing
/// `absent` because it looked for a singleton that this system does not vend;
/// the instance was arriving in that hook all along.
static id AevonDeactManager = nil;

static long AevonPushTried = 0;
static long AevonPushWrote = 0;
/// 1 = pushed through the scene's own update method, 2 = through the
/// manager's amendment entry, 0 = no door opened.
static long AevonPushPath = 0;
/// 0.2.57 — 上一次 `AevonPushSceneFrame` 返回 0 的**原因**。
///
/// Aevon(198) 里这条函数有五个不同的 0：键盘每一拍都是 `push=0`、补推四次
/// 全 `0`，最后一行只写 `kb push late gave up door=0` —— 从这行读不出是「已经
/// 等于目标，不用写」还是「被钩子挡了，五次都没进去」。前者应当立刻收手，
/// 后者应当继续等，而当时的代码分不开，只能两者都按同一个次数硬扛。
///
/// 现在每个返回点先落一格原因：
///   0 写成了            1 scene 是 nil        2 不在主线程
///   3 在钩子里（深度）   4 上一次推送还没收尾  5 这一格没登记
///   6 scene 没有 settings 7 已经是目标，不必写 8 写了但没有门
static volatile int AevonPushWhy = 0;
int AevonPushSceneFrameWhy(void) { return AevonPushWhy; }
static CFAbsoluteTime AevonLastPush = 0;
/// Re-entry is not theoretical: the amendment entry calls back into the
/// deactivation setter this file hooks, and that hook pushes again.
static volatile int AevonInPush = 0;

// MARK: - 小胖屏：scene 的逻辑尺寸（0.0.61）

/// 0.0.61 — 卡片要的是「App 按这个尺寸重新排一版」，不是「把整屏画面裁进这个框」。
///
/// 0.0.60 只改了承载视图的 `bounds`。真机日志证明那一步确实生效了 ——
/// `win: hosted bounds after=377x628 asked=377x628` —— 可画面还是 430 宽的排版被
/// 1:1 塞进 377 的框里：字大、顶栏偏右、底栏与抖音右侧那一列全落在框外。
/// 原因是两套几何只改了一套：`bounds` 是**视图**的尺寸，App 排版看的是 scene 自己
/// 的 `settings.frame`。
///
/// 这一版把 frame 写进 settings，走 0.0.53 已经在真机上响过的那条门
/// （`_scene:interceptUpdateWithNewSettings:`，Aevon(52) 的 `intercept=6/22`）。
/// 写的是**可变副本**：只对 `*Mutable*` 类调 setter，对不可变对象调 setter 在系统
/// 里是抛异常，而这里的异常没人接。
/// 0.0.98 — 画布目标从「一块」变成「每槽一块」。
///
/// 一个全局 `AevonFrameTarget` 只够一个窗用：第二个窗一旦开出来，两个 scene 会
/// 抢同一份目标，谁的 settings 后到谁就把另一个窗的画布改成自己的尺寸 —— 真机上
/// 的表现是「新窗开了，旧窗的画面忽然变成另一个 App 的排版」。所以目标必须按槽
/// 存，写入前先按 scene 找到它自己那一格。
static volatile int AevonFrameMask = 0;             ///< 位 i = 槽 i 有目标
static CGRect AevonFrameTargets[AEVON_ARMED_MAX];
/// 0.2.46 — 槽 i 上一次拿到回执的时刻（0 = 没有回执）。定义必须在这一格：
/// `AevonSceneFrameSet` 会在登记新目标时把它清掉，而那一段在 ack 那一族之前。
static CFAbsoluteTime AevonAckAt[AEVON_ARMED_MAX];
static long AevonFrameWrites = 0;
static long AevonFrameOrphans = 0;                  ///< 没登记就来设尺寸的次数

/// bundle 在登记表里的槽号，-1 = 没登记。
static int AevonSlotOfBundle(NSString *bundle) {
    if (bundle == nil || [bundle length] == 0) return -1;
    const char *text = [bundle UTF8String];
    if (text == NULL) return -1;
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] == '\0') continue;
        if (strcmp(AevonArmed[i], text) == 0) return i;
    }
    return -1;
}

/// 目标尺寸 = 卡片里那块承载面的尺寸。小于 80 pt 的一律当「没设」，防止一次
/// 布局没算完的读数把 scene 缩成一条。
///
/// 0.0.98 — 多一个 `bundle`：说的是「这一块画布归谁」。调用顺序上它一定在
/// `AevonHookArm` 之后，所以查不到槽只有一个含义 —— 有一处调用点忘了登记。
/// 那时宁可什么都不写并留下计数，也不要挑一个槽去覆盖别人的画布。
void AevonSceneFrameSet(NSString *bundle, double x, double y, double width, double height) {
    int slot = AevonSlotOfBundle(bundle);
    if (slot < 0) {
        __sync_fetch_and_add(&AevonFrameOrphans, 1);
        return;
    }
    if (width < 80.0 || height < 80.0) {
        __sync_fetch_and_and(&AevonFrameMask, ~(1 << slot));
        return;
    }
    AevonFrameTargets[slot] = CGRectMake((CGFloat)x, (CGFloat)y,
                                         (CGFloat)width, (CGFloat)height);
    // 0.2.46 — 新目标作废上一张回执：回执证的是「旧目标被收下」，
    // 拿它去停「新目标」的补推就会有一拍没人推。
    AevonAckAt[slot] = 0;
    __sync_fetch_and_or(&AevonFrameMask, 1 << slot);
}

/// 全部撤销。关最后一个窗、或这台系统上我们不该再管任何画布时用。
void AevonSceneFrameClear(void) {
    __sync_lock_test_and_set(&AevonFrameMask, 0);
}

/// 单个槽撤销：那个 App 的窗没了，它那一格就不该再被写。
void AevonSceneFrameClearBundle(NSString *bundle) {
    int slot = AevonSlotOfBundle(bundle);
    if (slot < 0) return;
    __sync_fetch_and_and(&AevonFrameMask, ~(1 << slot));
}

long AevonFrameWriteCount(void) { return AevonFrameWrites; }
long AevonFrameOrphanCount(void) { return AevonFrameOrphans; }
long AevonFrameArmedCount(void) {
    int mask = AevonFrameMask;
    long n = 0;
    for (int i = 0; i < AEVON_ARMED_MAX; i++) if (mask & (1 << i)) n += 1;
    return n;
}

/// 读 scene 现在的逻辑尺寸。读不到返回全零 —— 全零在日志里一看就知道是「没读到」，
/// 不会和一次真的失败混在一起。
CGRect AevonSceneFrameOf(id scene) {
    if (scene == nil) return CGRectZero;
    SEL settingsSel = sel_registerName("settings");
    if (![scene respondsToSelector:settingsSel]) return CGRectZero;
    id settings = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    if (settings == nil) return CGRectZero;
    SEL getter = sel_registerName("frame");
    if (![settings respondsToSelector:getter]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(settings, getter);
}

/// Non-zero while one of the hooked system callbacks is on the stack.
///
/// This is the whole of 0.0.31. `_setDeactivationReasons:onScene:withSettings:reason:`
/// runs on FrontBoard's scene-update path, which is holding the lock that
/// `updateSettings…` needs. Aevon(29) wrote the settings from inside that
/// callback, printed `push path=1 wrote=1 fg=1`, showed a picture — and then
/// stopped printing anything at all until the watchdog replaced SpringBoard
/// 7 s later (pid 3271 -> 3305). The same lock, taken twice, is a deadlock, and
/// a deadlocked SpringBoard is a safe mode.
///
/// The mother ship never writes from a callback. She runs a keepalive clock on
/// the main thread (rounds 12/13), writes only the values that differ (round
/// 14), and stops after three failures in a row (round 13). That is what
/// 0.0.31 copies, and this counter is the gate that keeps the copy honest.
static volatile int AevonHookDepth = 0;

// 0.4.0 — `AevonPushBanned` / `AevonBanPush` 删除。
//
// 它们原本是「上一次死在 push 里 ⇒ 这一次一次都不推」的保险丝，唯一的置位方是
// `SceneProbe.reportLastStep` 读到 `win.step == "WIN-PUSH"`。而 `reportLastStep`
// 从 0.3.0 起就没有任何调用者（`float` 里的 `mark()` 一直只在写，没人读），
// 也就是说这条保险丝在这一版之前已经是断的 —— 删掉它不改变任何行为，
// 只是把三处 `if (AevonPushBanned) return 0;` 的死条件一起收走。

/// `foreground = front, backgrounded = !front` on whatever settings object is
/// offered, with each setter asked for before it is used. Returns whether
/// anything was actually written — a class without these setters is a fact worth
/// a trace line, not a crash.
///
/// 0.0.32 made this a two-way switch. Aevon(30) proved the push works and the
/// same readout proved what it leaves behind: `win: closed after 8s` and then
/// `beat 32 fg=yes` — the card was gone, the presenter invalidated, and the
/// scene still said "I am in front", so Douyin kept playing to an empty desktop.
/// A settings value written by us does not expire with the card; it has to be
/// put back.
static BOOL AevonWriteFront(id settings, BOOL front) {
    if (settings == nil) return NO;
    BOOL wrote = NO;
    const char *ons[2] = {"setForeground:", "_setForeground:"};
    const char *offs[2] = {"setBackgrounded:", "_setBackgrounded:"};
    for (int i = 0; i < 2; i++) {
        SEL sel = sel_registerName(ons[i]);
        if (![settings respondsToSelector:sel]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel, front);
        wrote = YES;
    }
    for (int i = 0; i < 2; i++) {
        SEL sel = sel_registerName(offs[i]);
        if (![settings respondsToSelector:sel]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, sel, !front);
        wrote = YES;
    }
    return wrote;
}

/// A method that takes a block and returns nothing, called with the block the
/// caller built. `@?` in the encoding is the part that matters: it is the only
/// evidence that the third argument really is a settings block and not, say, an
/// object that would be messaged as one.
static BOOL AevonCallBlockMethod(id target, NSString *name, void (^block)(id)) {
    if (target == nil || name == nil || block == nil) return NO;
    SEL sel = NSSelectorFromString(name);
    if (sel == NULL || ![target respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    if (method == NULL) return NO;
    const char *encoding = method_getTypeEncoding(method);
    unsigned int arguments = method_getNumberOfArguments(method);
    if (encoding == NULL || encoding[0] != 'v' || strstr(encoding, "@?") == NULL) return NO;
    if (arguments == 4) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, block, nil);
        return YES;
    }
    if (arguments == 3) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, sel, block);
        return YES;
    }
    return NO;
}

/// `- (void)updateSettings:(id)` — one object, no block. Kept as the fallback
/// door for the day the transition overload disappears; see the note there for
/// why it stopped being the first choice.
static BOOL AevonCallSettings(id target, id settings) {
    if (target == nil || settings == nil) return NO;
    SEL sel = sel_registerName("updateSettings:");
    if (![target respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    if (method == NULL) return NO;
    const char *encoding = method_getTypeEncoding(method);
    if (encoding == NULL || encoding[0] != 'v') return NO;
    if (strstr(encoding, "@?") != NULL) return NO;
    if (method_getNumberOfArguments(method) != 3) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, settings);
    return YES;
}

/// The transition-context doors, 0.4.2's own order — `updateSettings:
/// withTransitionContext:completion:` first, the two-argument overload second,
/// both with a nil context. This file used to refuse the whole family because
/// Stheno 0.3.0 died passing nil into it (round 3, twice); Aevon 0.4.2 has run
/// this exact call — nil context included — on this phone for two hundred
/// builds, so the death was the caller's, not the door's.
///
/// The door matters for one reason the beat log finally named: a settings
/// write through the plain `updateSettings:` changes the dictionary the
/// keepalive reads back (`beat fg=yes`) but never crosses the scene bridge as
/// a scene update, so the app process keeps the activation state it was born
/// with — a suspended launch stays suspended, and every touch the bridge
/// forwards into the picture dies in a background scene. The transition
/// pipeline is what turns a dictionary edit into a lifecycle the app acts on.
///
/// Answers 3 when a transition door opened, 0 when neither exists.
static NSInteger AevonCallSettingsTransition(id target, id settings) {
    if (target == nil || settings == nil) return 0;
    SEL three = sel_registerName("updateSettings:withTransitionContext:completion:");
    if ([target respondsToSelector:three]) {
        Method method = class_getInstanceMethod(object_getClass(target), three);
        const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
        // v@:0 1@"FBSceneTransitionContext" 2@"?" — the completion must be
        // an object-nullable block slot, the context an object slot.
        if (encoding != NULL && encoding[0] == 'v' && method_getNumberOfArguments(method) == 5) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(target, three, settings, nil, nil);
            return 3;
        }
    }
    SEL two = sel_registerName("updateSettings:withTransitionContext:");
    if ([target respondsToSelector:two]) {
        Method method = class_getInstanceMethod(object_getClass(target), two);
        const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
        if (encoding != NULL && encoding[0] == 'v' && method_getNumberOfArguments(method) == 4) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(target, two, settings, nil);
            return 3;
        }
    }
    return 0;
}

/// 0.2.46 — 回执：这次 settings 更新系统**收下了**，不用再赌四拍重推
/// （对比报告第六节第 3 条）。
///
/// 报告原话是「改尺寸走 `FBUpdateSceneTransaction`，拿到客户端回执」。这里没有
/// 另造一个 `FBUpdateSceneTransaction` 实例，理由写在下面这段之后 —— 拿回执这件事
/// 本身不需要新事务类，`updateSettings:withTransitionContext:completion:` 的
/// 第五个参数就是回执口。
///
/// 为什么不去手工构造 `FBUpdateSceneTransaction`：
///   · 它是一个**事务**，正常由 `FBScene` 自己在 settings 提交时创建；我们绕过
///     scene 自己造一个，等于同一个 scene 上跑两条更新链，谁赢按提交顺序，没有
///     任何文档能保证 —— 这个工程里「猜私有初始化器」的账（0.2.13）已经付过一次；
///   · 我们要的东西只是「送没送到」，而它恰好就是这个 completion block。
/// 所以：**用回执，不造事务**。日志里认 `win: scene ack slot=`。
///
/// block 写成无参（`void(^)(void)`）：系统回调时带了什么参数都落不到我们的签名上，
/// ARM64 下多余参数只是没人读；写成 `^(NSError *)` 才是在猜回调形状。
///
/// `AevonAckAt` 的定义在 `AevonFrameTargets` 旁边（`AevonSceneFrameSet` 要清它）。
// 0.4.0 — `AevonAckCount`（回执总数的只读出口）随 `AevonSceneAckCount` 一起删除：
// 没有任何调用方。真正还在用的是 `AevonAckAt[]`（每槽时间戳，回答「这个 App 的
// scene 更新拿到过回执没有」）与 `AevonAckNotes`（前 24 条写现场）。
static long AevonAckNotes = 0;

static NSInteger AevonCallSettingsAck(id target, id settings, int slot) {
    if (target == nil || settings == nil) return 0;
    if (slot < 0 || slot >= AEVON_ARMED_MAX) return 0;
    SEL three = sel_registerName("updateSettings:withTransitionContext:completion:");
    if (![target respondsToSelector:three]) return 0;
    Method method = class_getInstanceMethod(object_getClass(target), three);
    const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
    if (method == NULL || encoding == NULL || encoding[0] != 'v' ||
        method_getNumberOfArguments(method) != 5) return 0;
    void (^ack)(void) = ^{
        AevonAckAt[slot] = CFAbsoluteTimeGetCurrent();
        // 自己的预算：前 24 条写现场，之后只计数。这条不是「每拍都要看」的行，
        // 它的用途是证明「门后面真的有人接」。
        if (__sync_fetch_and_add(&AevonAckNotes, 1) < 24) {
            NSString *line = [[NSString alloc] initWithFormat:
                              @"win: scene ack slot=%d", slot];
            AevonLogRaw([line UTF8String]);
            [line release];
        }
    };
    // MRC：block 被系统 retain 起之前必须在堆上，否则回调时栈帧早没了。
    // 故意不 release —— 每一拍漏几十字节，换「不会因为一个不知道谁 retain 的
    // completion 而崩」。
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(target, three, settings, nil,
                                                  [ack copy]);
    return 3;
}

/// 某个 App 的 scene 更新拿到过回执没有。Swift 侧用它决定还要不要补推。
int AevonSceneFrameAcked(const char *bundle) {
    if (bundle == NULL) return 0;
    NSString *name = [NSString stringWithUTF8String:bundle];
    int slot = AevonSlotOfBundle(name);
    if (slot < 0) return 0;
    return AevonAckAt[slot] > 0 ? 1 : 0;
}

/// 0.2.46 — 推 frame 的时候，把 `displayConfiguration` 一起推上去。
///
/// 这一条是「真重排」的核心，也是对比报告第一节那条病因的正解：
///
///   建 scene 时我们把 display 改成了画布（430x717），可**之后每次推 frame 都只写
///   `setFrame:`，display 再没跟上过**。键盘态把 scene 推到 430x932 时，App 的
///   `UIScreen` 仍是 717 —— 于是「窗口 932、屏幕 717」的错位又反过来了；而从
///   整屏建（staged）的那条路进来的 App 更是从头到尾都拿着 932 的 `UIScreen`。
///   按 `UIScreen` 排版的 App（抖音 feed / 高德地图）因此永远按那个错的数摆内容，
///   剩下的偏差只能靠 App 进程里的补丁一点点挪回来 —— 补丁是症状。
///
/// 只在**尺寸真的变了**的时候写：
///   · 键盘态是「尺寸不变、原点变 215」，那一次不换屏幕（换一次 display 就是一次
///     全量重排，比省下的偏差贵得多）；
///   · 交给我们托管的 scene frame 只有两档（画布 717 / 键盘态 932），卡片缩放
///     不改 scene frame，所以这条路上不会出现「拖一下写几十次」。
/// 再叠一道 0.20 s 的节流：两个档位来回切时，0.2 s 内的第二次不再换屏幕。
///
/// 返回 1 = 这次真的换了屏幕。
static CFAbsoluteTime AevonDisplayAt[AEVON_ARMED_MAX];

/// 这份 scene 设置能不能写。**全工程只有这一个口径。**
///
/// iOS 的 scene 设置是「不可变基类 + Mutable 子类」两件套：
/// `FBSceneSettings` / `FBMutableSceneSettings`、`UIApplicationSceneSettings` /
/// `UIMutableApplicationSceneSettings`。往**不可变**那份调 setter，FrontBoard 内部
/// 不是抛 `NSException`，而是直接 `BSLogAssert` → `__builtin_trap()`
/// （Aevon(224) 的崩溃报告：`EXC_BREAKPOINT / SIGTRAP`，栈顶
/// `-[FBSSettings _setValue:forSetting:]`）。
///
/// ⛔ **trap 抓不住** —— `@try` 对它无效。唯一活路是事前判类型，所以这道闸必须
/// 出现在每一次写之前，不能靠外层兜。0.0.98 就把它写进了 `AevonWriteFrame`，
/// 0.2.90 新加的「出生即卡尺寸」自己数了一遍 `respondsToSelector:` 就动手，
/// 于是漏了 —— 代价是一次安全模式（点备忘录里的链接跳 Safari，那次 settings 是
/// `UIApplicationSceneSettings`；而 QQ / 微信卡一直是 `UIMutableApplicationSceneSettings`，
/// 所以这条路从来没被踩到）。
static BOOL AevonSettingsMutable(id settings) {
    if (settings == nil) return NO;
    const char *name = object_getClassName(settings);
    if (name == NULL) return NO;
    return strstr(name, "Mutable") != NULL;
}

static BOOL AevonWriteDisplay(id settings, int slot) {
    if (settings == nil) return NO;
    if (!AevonSettingsMutable(settings)) return NO;
    if (slot < 0 || slot >= AEVON_ARMED_MAX) return NO;
    if (!(AevonFrameMask & (1 << slot))) return NO;
    CGRect target = AevonFrameTargets[slot];
    SEL getter = sel_registerName("displayConfiguration");
    SEL setter = sel_registerName("setDisplayConfiguration:");
    if (![settings respondsToSelector:getter] ||
        ![settings respondsToSelector:setter]) return NO;
    id now = ((id (*)(id, SEL))objc_msgSend)(settings, getter);
    if (now == nil) return NO;
    SEL boundsSel = sel_registerName("bounds");
    if (![now respondsToSelector:boundsSel]) return NO;
    CGRect current = ((CGRect (*)(id, SEL))objc_msgSend)(now, boundsSel);
    if (fabs(current.size.width - target.size.width) < 0.5 &&
        fabs(current.size.height - target.size.height) < 0.5) return NO;
    CFAbsoluteTime at = CFAbsoluteTimeGetCurrent();
    if (AevonDisplayAt[slot] > 0 && at - AevonDisplayAt[slot] < 0.20) {
        AevonOwnDisplayLog(@"win: display follow skip slot=%d dt=%.0fms",
                           slot, (at - AevonDisplayAt[slot]) * 1000.0);
        return NO;
    }
    id copy = AevonOwnDisplayOverride(
        now, CGRectMake(0, 0, target.size.width, target.size.height));
    if (copy == nil) {
        AevonOwnDisplayLog(@"win: display follow no door %.0fx%.0f slot=%d",
                           target.size.width, target.size.height, slot);
        return NO;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(settings, setter, copy);
    [copy release];
    // 参考尺寸跟着一起走（0.2.46）：建 scene 时写的那一份是「出生尺寸」，
    // 之后 frame 变了它不会自己跟 —— 三个数（frame / display / 参考尺寸）必须
    // 一直是同一个，否则 App 内部就有一处按旧尺寸排版。
    AevonOwnRefSet(settings, target.size, "follow");
    AevonDisplayAt[slot] = at;
    AevonOwnDisplayLog(@"win: display follow %.0fx%.0f -> %.0fx%.0f slot=%d",
                       current.size.width, current.size.height,
                       target.size.width, target.size.height, slot);
    return YES;
}

/// 0.3.61 — 冷分享窗口的判定（定义在 0.3.58 那一段，这里只是提前声明：
/// 让路判据在它之前，C 里不能先用后定义）。

/// 0.3.61 — **让路之后把屏幕也还回去。**
///
/// Aevon(286) 的黑底就是这么来的：出生那一拍我们把 scene 写成 717，QQ 按 717
/// 建了自己的窗口（`app: geom early … scene=430x932 win=430x717`）；让路之后
/// 我们只把 **frame** 写回 932（`win: scene frame after=430x932`），
/// `displayConfiguration` 还是 717 —— App 的 `UIScreen` 没变，分享面板照旧按
/// 717 排，下面 215 pt 没人画。
///
/// 所以让路这一拍要同时把 display 和参考尺寸写回整屏。三个数（frame / display /
/// 参考尺寸）必须一直是同一个，这条纪律在 0.2.46 就定过，这里只是把它补到
/// 「交还系统」这一侧。
static void AevonYieldDisplayBack(id settings, CGSize screen, const char *bundle) {
    if (settings == nil) return;
    if (!AevonSettingsMutable(settings)) return;
    SEL getter = sel_registerName("displayConfiguration");
    SEL setter = sel_registerName("setDisplayConfiguration:");
    if (![settings respondsToSelector:getter] ||
        ![settings respondsToSelector:setter]) return;
    id now = ((id (*)(id, SEL))objc_msgSend)(settings, getter);
    if (now == nil) return;
    SEL boundsSel = sel_registerName("bounds");
    if (![now respondsToSelector:boundsSel]) return;
    CGRect current = ((CGRect (*)(id, SEL))objc_msgSend)(now, boundsSel);
    if (fabs(current.size.width - screen.width) < 0.5 &&
        fabs(current.size.height - screen.height) < 0.5) return;
    id copy = AevonOwnDisplayOverride(now, CGRectMake(0, 0, screen.width, screen.height));
    if (copy == nil) return;
    ((void (*)(id, SEL, id))objc_msgSend)(settings, setter, copy);
    [copy release];
    AevonOwnRefSet(settings, screen, "yield");
    AevonLogRaw([[NSString stringWithFormat:
                  @"win: card yield display back %.0fx%.0f -> %.0fx%.0f b=%s",
                  current.size.width, current.size.height,
                  screen.width, screen.height,
                  bundle != NULL ? bundle : "-"] UTF8String]);
}

/// 把目标尺寸写进一份 settings。返回「这一次真的写了」。
///
/// 先读再比：已经是目标值就不写。这是 0.0.34 定下的 delta-first —— 一次什么都没
/// 改变的写入同样要付一次重排，而重排就是一次闪。
///
/// 0.0.98 — 目标由 `slot` 点名，不再读全局。调用方必须已经用它自己的 scene 查出
/// 槽号；查不出槽就不写（那说明这份 settings 不属于任何一个我们登记的窗）。
static BOOL AevonWriteFrame(id settings, int slot) {
    if (settings == nil) return NO;
    if (slot < 0 || slot >= AEVON_ARMED_MAX) return NO;
    if (!(AevonFrameMask & (1 << slot))) return NO;
    CGRect target = AevonFrameTargets[slot];
    if (!AevonSettingsMutable(settings)) return NO;
    SEL setter = sel_registerName("setFrame:");
    if (![settings respondsToSelector:setter]) return NO;
    SEL getter = sel_registerName("frame");
    if ([settings respondsToSelector:getter]) {
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(settings, getter);
        // 0.2.37 — **系统要整屏接管卡片里这个 App 了，卡片该让路。**
        //
        // 用户现场（0.2.36）：悬浮窗开着 QQ → 回桌面 → 点桌面 QQ 图标。系统把
        // 我们 hosted 的 scene 挪进全屏窗口，日志里全屏页 `430x932` 而 scene 仍
        // 被这里改回 `430x717` —— 这就是「悬浮窗黑 + 全屏底部 215 pt 黑」。
        //
        // 那条打开请求没有走到 `AevonOpenDecide` 的 plain 分支（0.2.36 的
        // `why=yield` 一次都没出现），所以门必须开在 scene 这一侧：系统往一个
        // **已经稳定承载卡片的 scene** 写整屏 frame，就是接管本身。
        //
        // 三个前提缺一不可：
        //   · `AevonInPush == 0`：只认系统的更新。我们自己推 717 时 now 就是
        //     整屏（刚建卡那一拍），那一趟绝不能触发；
        //   · 年龄 > 0.40 s：建卡那两百毫秒里系统本来就会先给整屏再被我们改小；
        //     0.2.37 用的 0.9 s 太大 —— 用户「开卡 → 马上点桌面图标」时那一拍
        //     会被挡住，表现就是这次让路「有概率」不生效、双黑照旧。
        //     `AevonInPush` 已经排除了我们自己的推帧，0.40 s 只是给首帧留的余量。
        //   · 目标高度 < 800 且新 frame > 850：卡片最大也就 719，整屏 932。
        //
        // 命中之后先撤掉 frame 目标（不再抢），再异步拆卡 —— 这里在 settings
        // 更新路径里，同步拆卡会重入，只能排到主队列下一拍。
        if (AevonInPush == 0
            && now.size.height > 850
            && target.size.height < 800) {
            CFAbsoluteTime age = CFAbsoluteTimeGetCurrent() - AevonArmedAt[slot];
            // 0.4.0 — 0.3.61 那段「冷分享静默期」整块删除。它存在的唯一理由是
            // 「我们自己放过去的那次延迟激活会在 2~3 秒后提交一次 430x932」，
            // 而延迟激活属于 URL 投递链，这一版没有那条链。剩下的就是原来那条
            // 让路判据：卡片活过 0.40 s 还收到整屏 frame，就是系统要接管它。
            if (age > 0.40) {
                __sync_fetch_and_and(&AevonFrameMask, ~(1 << slot));
                AevonArmedAt[slot] = 0;
                AevonLogRaw([[NSString stringWithFormat:
                              @"win: card yield seen b=%s now=%.0fx%.0f want=%.0fx%.0f age=%.2f",
                              AevonArmed[slot],
                              now.size.width, now.size.height,
                              target.size.width, target.size.height, age] UTF8String]);
                // 让路之后 App 的窗口是按 717 建的，只还 frame 不还屏幕的话，
                // 全屏页只剩上面 717 有内容（用户截图那条 215 pt 黑底）。
                AevonYieldDisplayBack(settings, now.size, AevonArmed[slot]);
                char *name = strdup(AevonArmed[slot]);
                if (name == NULL) return NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (name[0] == '\0') { free(name); return; }
                    AevonCardYieldForFullscreen(name);
                    free(name);
                });
                return NO;
            }
        }
        // 0.1.51 — **原点也要比。**
        //
        // 0.1.50 让宿主把场景随卡片搬到屏幕 215（`(0,215,430,717)`，尺寸一点没改，
        // 只挪原点），结果 Aevon(123) 的日志里四条全是
        // `win: frame drift now=430x717@0 want=430x717@215 door=0` —— 一次都没写成。
        // 根因就在这里：delta-first 只比了 `size`，尺寸相同就判「不用写」，
        // 原点这一趟差事从来没上路，`door=0` 是它必然的答案，不是门坏了。
        //
        // 补上原点之后，同一个目标值才会真的落下一次 `setFrame:`。尺寸没变，
        // 所以 App 不需要按新尺寸重排 —— 这正是搬原点这条路存在的全部理由。
        if (fabs(now.origin.x - target.origin.x) < 0.5
            && fabs(now.origin.y - target.origin.y) < 0.5
            && fabs(now.size.width - target.size.width) < 0.5
            && fabs(now.size.height - target.size.height) < 0.5) {
            return NO;
        }
    }
    ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, setter, target);
    __sync_fetch_and_add(&AevonFrameWrites, 1);
    return YES;
}

/// 主动把 frame 推一次。intercept 只在系统更新 settings 时给机会，建卡那一拍
/// 系统未必正好在更新，所以这里不等它。
///
/// 返回用过的门（3 = transition，1 = 普通），0 = 没写成或没有门。
NSInteger AevonPushSceneFrame(id scene) {
    // 0.2.57 — 每个返回点先落一格原因，见 `AevonPushWhy` 那张表。
    AevonPushWhy = 1;
    if (scene == nil) return 0;
    AevonPushWhy = 2;
    if (![NSThread isMainThread]) return 0;
    AevonPushWhy = 3;
    if (AevonHookDepth > 0) return 0;
    AevonPushWhy = 4;
    if (AevonInPush) return 0;
    AevonPushWhy = 5;
    int slot = AevonSlotOfScene(scene);
    if (slot < 0 || !(AevonFrameMask & (1 << slot))) return 0;
    AevonPushWhy = 6;
    SEL settingsSel = sel_registerName("settings");
    if (![scene respondsToSelector:settingsSel]) return 0;
    id current = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    id candidate = [current mutableCopy];
    if (candidate == nil) candidate = current;
    AevonInPush = 1;
    BOOL wrote = AevonWriteFrame(candidate, slot);
    // 0.2.46 — 屏幕跟着窗口走（见 `AevonWriteDisplay`）。**放在写门之前**：
    // 一次 `updateSettings:withTransitionContext:` 提交的是这一份 candidate，
    // display 这一格必须在提交之前就在里面，否则 App 收到的是「新 frame + 旧屏幕」，
    // 又要多一次重排来纠正。
    //
    // 这里**不**跟着 `wrote` 走：`wrote=0` 只说明 frame 已经等于目标，而 display
    // 可能还停在旧尺寸（staged 建出来的 scene 就是这种状态 —— frame 被系统改对
    // 了、屏幕没跟上）。`AevonWriteDisplay` 自己判重，尺寸一样就返回 0，稳态下
    // 一个字节都不花。
    BOOL screen = AevonWriteDisplay(candidate, slot);
    NSInteger path = 0;
    if (wrote || screen) {
        // 0.2.46 — 先走带回执的那条门（第 5 个参数不再传 nil），失败再退回
        // 0.0.43 那条同签名的无回执门。两条门的形状闸一样，差别只有回执。
        path = AevonCallSettingsAck(scene, candidate, slot);
        if (path == 0) path = AevonCallSettingsTransition(scene, candidate);
        if (path == 0 && AevonCallSettings(scene, candidate)) path = 1;
    }
    AevonInPush = 0;
    // 只有屏幕、没有 frame 的那一次也算「写成了」：它是 staged 之后的那一次
    // display 纠正，调用方（`pushSceneLater` / 守护循环）要看见它真的落了地。
    //
    // 0.2.57 — `7` 与 `8` 是两种完全不同的「0」：`7` 说明 frame 与屏幕都已经
    // 等于目标（一次 settings 也没花），调用方应当立刻收手；`8` 是值写进了
    // candidate 却没有门把它交出去，下一次还得再试。分不开这两个数，补推就
    // 只能按次数硬扛 —— Aevon(198) 里四次全撞在同一格上。
    AevonPushWhy = (wrote || screen) ? (path != 0 ? 0 : 8) : 7;
    return (wrote || screen) ? path : 0;
}

/// One attempt at "you are in front". Answers the door it used so the log can
/// say where the chain stops:
///
///   3  a transition-context door — the one that crosses the scene bridge and
///      gives the app a lifecycle to act on (0.0.43, 0.4.2's own order)
///   1  the scene's own `updateSettingsWithBlock:` / `updateSettings:`
///   2  the deactivation manager's `amendSceneSettings:forScene:`
///   4  nothing to do — the scene already says it is in front, no write spent
///   0  no door, wrong thread, inside a hook, throttled, banned, or out of tries
///
/// `4` used to be `3`; the transition door took that number, and "already in
/// front" had to move out of its way rather than share it.
///
/// The transition door is first because 0.0.42 settled where content touch
/// dies: not in the hit test (`event hit -> _UISceneLayerHostContainerView`
/// in Aevon(41)), not in the band — in the app's belief about its own state.
/// The plain doors kept SpringBoard's copy of the settings foreground while
/// the app process, launched suspended, never heard about it.
///
/// `updateSettingsWithBlock:` is first because it is the one door the mother
/// ship used on this phone (`P0 已发 updateSettingsWithBlock（foreground=YES /
/// level=1 / portrait）`, round 7) and because it is asynchronous: it returns
/// before the update lands, which is what makes a main-thread clock the right
/// caller and a hooked system callback the wrong one.
NSInteger AevonPushForeground(id scene) {
    if (scene == nil || !AevonIsArmed()) return 0;
    // FrontBoard objects assert on the main thread. The mother ship's first
    // safe mode (round 3) was this exact mistake, made twice; blueprint v2 put
    // it in one line: "SpringBoard 对这类 UIKit/FrontBoard 对象普遍有必须主线程的断言".
    if (![NSThread isMainThread]) return 0;
    // Never from inside a hook. See AevonHookDepth: Aevon(29) died here.
    if (AevonHookDepth > 0) return 0;
    if (AevonInPush) return 0;
    if (__sync_fetch_and_add(&AevonPushTried, 1) > 40) return 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - AevonLastPush < 0.2) return 0;
    AevonLastPush = now;
    AevonInPush = 1;

    long attempt = AevonPushTried;
    SEL settingsSel = sel_registerName("settings");
    id current = nil;
    // 0.1.35 — **类名在拿到的当下就抄走，之后一辈子不再碰 `current`。**
    //
    // 2026-11-05 18:31:31 的安全模式就是这一行：`[scene settings]` 返回的是
    // +0（autoreleased）对象，而我们下面用三条路把新 settings 写进同一个
    // scene —— 系统落盘时会把旧的那一份释放掉。`current` 只是一个不带所有权的
    // 指针，于是后面那句 `class_getName(object_getClass(current))` 读到的
    // 是一块已经回收的内存（崩溃报告：`EXC_BAD_ACCESS / SIGBUS 0x105`，
    // faulting frame `object_getClass +28` ← `AevonPushForeground +500`，
    // 寄存器 x2 还停在 `__NSCFBoolean`，正是上一个 `AevonFlagOf` 留下的）。
    //
    // 结论：凡是「写完之后还要读一眼」的量，必须在写之前抄成自己的值。
    // 类名进栈上缓冲，前后台状态进两个 int，`current` 从写入那一刻起不再出现。
    char settingsName[96] = "nil";
    int wasFront = -1;
    int wasBack = -1;
    if ([scene respondsToSelector:settingsSel]) {
        current = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
        if (current != nil) {
            const char *name = class_getName(object_getClass(current));
            if (name != NULL) {
                snprintf(settingsName, sizeof(settingsName), "%s", name);
            }
            wasFront = AevonFlagOf(current, "isForeground");
            wasBack = AevonFlagOf(current, "isBackgrounded");
        }
    }

    // Delta first. Round 14 of the mother ship settled this: a write that
    // changes nothing still costs a re-layout, and a re-layout is a flicker.
    // A scene already in front gets no write at all, and the caller is told so
    // with 3 rather than 0 — "nothing to do" and "no door" are different facts.
    if (wasFront == 1 && wasBack == 0) {
        if (attempt < 8) {
            AevonRawTrace("push", "front, no write settings=%s", settingsName);
        }
        AevonInPush = 0;
        return 4;
    }

    // A mutable copy is tried first because a copy cannot be rejected by a class
    // that only accepts its own kind; the original is the fallback for settings
    // that are already mutable.
    id candidate = [current mutableCopy];
    if (candidate == nil) candidate = current;
    BOOL inlineWrite = AevonWriteFront(candidate, YES);

    void (^amend)(id) = [^(id settings) {
        AevonWriteFront(settings, YES);
    } copy];

    NSInteger path = AevonCallSettingsTransition(scene, candidate);
    if (path == 0) {
        if (AevonCallBlockMethod(scene, @"updateSettingsWithBlock:", amend)
            || AevonCallSettings(scene, candidate)) {
            path = 1;
        } else if (AevonDeactManager != nil) {
            id manager = AevonDeactManager;
            SEL amendSel = NSSelectorFromString(@"amendSceneSettings:forScene:");
            if (candidate != nil && [manager respondsToSelector:amendSel]) {
                Method method = class_getInstanceMethod(object_getClass(manager), amendSel);
                const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
                unsigned int arguments = method != NULL ? method_getNumberOfArguments(method) : 0;
                if (encoding != NULL && encoding[0] == 'v' && arguments == 4) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(manager, amendSel,
                                                              candidate,
                                                              scene);
                    path = 2;
                }
            }
        }
    }

    if (path != 0) {
        __sync_fetch_and_add(&AevonPushWrote, 1);
        AevonPushPath = path;
    }
    if (attempt < 8) {
        // 0.1.35 — 这里以前读的是 `current`，也就是崩溃点（见函数开头那段）。
        // 现在只报**写之前**抄下来的那份读数：它描述的正是「系统原来是怎样」，
        // 而这一行本来就是给下一次读日志的人看这个的。
        AevonRawTrace("push", "path=%ld wrote=%d wasf=%d settings=%s", path,
                      inlineWrite ? 1 : 0, wasFront, settingsName);
    }
    AevonInPush = 0;
    return path;
}

/// 0.0.50 — `level` 是我们唯一会写进去、系统不会自己纠正回来的一格。写过就
/// 得自己收回去，否则卡片关掉之后那个 scene 还停在「前台档」。定义在文件下面，
/// 因为它的伙伴（`AevonWriteLevelIdle` / `AevonWakeScene`）都在那里。
static void AevonWriteLevelIdle(id settings);
static volatile int AevonLevelForced = 0;

static void AevonRestoreLevel(id settings) {
    if (settings == nil || !AevonLevelForced) return;
    if (!AevonSettingsMutable(settings)) return;
    SEL setter = sel_registerName("setLevel:");
    if (![settings respondsToSelector:setter]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(settings, setter, 0.0);
    AevonLevelForced = 0;
}

/// Put the scene back where the card found it: `foreground=NO, backgrounded=YES`.
///
/// Aevon(30) is the reason this exists. The card came down, the presenter was
/// invalidated, the hook was disarmed — and the next beat still read `fg=yes`,
/// so Douyin kept playing to a desktop with nothing on it. Disarming a hook
/// stops us contradicting the system; it does not undo a value already written.
/// The settings have to be handed back.
///
/// Answers 1 when a door opened, 3 when the scene was already in the background,
/// 0 when there was nothing to write through.
NSInteger AevonPushBackground(id scene) {
    if (scene == nil) return 0;
    if (![NSThread isMainThread]) return 0;
    if (AevonHookDepth > 0) return 0;

    SEL settingsSel = sel_registerName("settings");
    id current = nil;
    if ([scene respondsToSelector:settingsSel]) {
        current = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    }
    if (AevonFlagOf(current, "isForeground") == 0
        && AevonFlagOf(current, "isBackgrounded") == 1
        && !AevonLevelForced) {
        return 3;
    }
    id candidate = [current mutableCopy];
    if (candidate == nil) candidate = current;
    AevonWriteFront(candidate, NO);
    AevonRestoreLevel(candidate);
    void (^amend)(id) = [^(id settings) {
        AevonWriteFront(settings, NO);
        AevonRestoreLevel(settings);
    } copy];
    // The hand-back goes through the same transition door the push came in
    // through: a background write that stops at the dictionary leaves the app
    // process believing it is in front, which is Aevon(30)'s Douyin playing to
    // an empty desktop, one bridge crossing later.
    if (AevonCallSettingsTransition(scene, candidate) == 3) return 1;
    if (AevonCallBlockMethod(scene, @"updateSettingsWithBlock:", amend)) return 1;
    if (AevonCallSettings(scene, candidate)) return 1;
    return 0;
}


// MARK: - 事前改参数（0.0.52）

// 0.0.51 之前所有防黑闪的努力都是「事后补写」：轮询发现画面掉了，再把 settings
// 写回前台。Aevon(49) 的日志把这条路的结构下限摊得很清楚 —— 掉画 60 / 63 / 313
// 毫秒，而 60 与 63 正好等于守护自己的检测周期：黑的起点永远在「我们看见」之前。
// 换更短的周期没用，那只会让日志更密，不会让黑变短。
//
// 母本的路线相反：`_scene:interceptUpdateWithNewSettings:`。系统把「即将生效的
// settings」交给这个方法，它在交给系统之前就把它改成自己要的样子 —— 没有「掉下去」
// 这一步，也就没有要追的那一段。
//
// 0.0.29 装过它，实测 intercept=0（一次没被调用）。原因有两个，0.0.53 一起处理：
//   · 装在了 `SBSceneManager`（父类）上，而母本的类表里是
//     `_TtC6Stheno29SBMainDisplaySceneManagerHook`（**子类**）—— 子类自己的
//     Method 被替换才轮得到，父类的 IMP 在子类重写之后根本不会执行。
//   · 形状守卫把参数个数数错了（见下面的 `AevonObjectArgs`），两个类都没装上。
//
// 0.0.54 — 删掉第三个候选点 `SBDeviceApplicationSceneViewController`。0.0.53 的
// 真机日志里 `client=0` 走完全场，而且那个类自己的 110 个方法里没有一个名字带
// clientSettings —— 母本挂它是因为她还有别的用途，我们这里它一次都没被调用过。
// 一个永远不响的钩子不是保险，是每次都多读一遍方法表、多占一个槽的空转。
//
// 现在装两个候选类，形状不合就**不装**并如实记一行 —— 一次参数错位的调用是
// SpringBoard 的崩溃，不是一行日志。

static long AevonInterceptCalls = 0;
static long AevonInterceptRewrote = 0;

/// 类型编码里的对象参数个数。`v32@0:8@16@24` → 2（三个 `@` 里第一个是 self）。
/// -1 表示不是 void 返回或编码读不出来，调用方据此跳过，不做任何猜测。
///
/// 0.0.53 — 这里原来是 `count - 2`，注释却写着「→ 2」。真机上
/// `v32@0:8@16@24` 被数成 1、判定形状不符，于是 `SBMainDisplaySceneManager` 与
/// `SBSceneManager` 两个候选**一个都没装**（Aevon(50)：58 条节拍全是 `ic=0/0`）。
/// 一个只会拒绝的看门狗，比没有看门狗更坏：它把「装错参数会崩」换成了「永远不装」，
/// 而且看起来一切正常。self 也在 `@` 里，参数个数只能是 `count - 1`。
static int AevonObjectArgs(const char *encoding) {
    if (encoding == NULL || encoding[0] != 'v') return -1;
    int count = 0;
    for (const char *p = encoding; *p != '\0'; p++) {
        if (*p == '@') count += 1;
    }
    return count >= 1 ? count - 1 : -1;
}

/// `settings.level` 读在 settings 对象上（不是 scene 上）。读不到回 -1。
static double AevonLevelOf(id settings) {
    if (settings == nil) return -1;
    SEL getter = sel_registerName("level");
    if (![settings respondsToSelector:getter]) return -1;
    return ((double (*)(id, SEL))objc_msgSend)(settings, getter);
}

/// 把「即将生效的 settings」改成前台档，在系统用它之前。
///
/// 返回位掩码：1 写了 foreground、2 写了 level、4 写了 idle，0 没有要改的，
/// -1 这个对象不可变（`FBSMutableSceneSettings` 才可写，别的类一律不碰）。
///
/// 不可变就返回而不是硬写：对一个不可变 settings 调 setter 在系统里是抛异常，
/// 而这里的异常没有人接 —— 那就是 SpringBoard 的一次自杀。
static int AevonAmendSettings(id settings, int slot) {
    if (settings == nil) return 0;
    const char *className = object_getClassName(settings);
    if (className == NULL || strstr(className, "Mutable") == NULL) return -1;

    int wrote = 0;
    if (AevonFlagOf(settings, "isForeground") == 0 && AevonWriteFront(settings, YES)) {
        wrote |= 1;
    }
    double level = AevonLevelOf(settings);
    if (level >= 0.0 && level <= 2.0 && level != 1.0) {
        SEL setter = sel_registerName("setLevel:");
        if ([settings respondsToSelector:setter]) {
            ((void (*)(id, SEL, double))objc_msgSend)(settings, setter, 1.0);
            wrote |= 2;
            // 写过的 level 要有人收回去：关窗时 `AevonRestoreLevel` 只在这个
            // 标记立着的时候才动手，不立就是留给 scene 一个永久的前台档。
            AevonLevelForced = 1;
        }
    }
    if (AevonFlagOf(settings, "idleModeEnabled") == 1) {
        SEL setter = sel_registerName("setIdleModeEnabled:");
        if ([settings respondsToSelector:setter]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setter, NO);
            wrote |= 4;
        }
    }
    // 0.0.61 — 位 8：这一次把 scene 的逻辑尺寸改成了小胖屏的尺寸。
    //
    // 挂在这里而不是新开一个钩子，是因为这条门已经被证明会响：Aevon(52) 的日志
    // 里 `intercept=6/22`、`mine=1 amend=1`，说明系统每次更新 settings 都把它
    // 交到我们手上，而我们在系统用之前就改完了它。母本用的是同一个方法。
    if (AevonWriteFrame(settings, slot)) wrote |= 8;
    // 0.2.46 — 位 16：这一次顺手把「屏幕」也对上了（见 `AevonWriteDisplay`）。
    //
    // 挂在同一个地方的理由和位 8 完全一样：这条门已经证明会响（`intercept=6/22`），
    // 而且它改的是**系统马上要用的那一份** settings，不需要我们再发一次更新。
    // 系统自己把 frame 写成整屏时（0.2.37 的让路场景），`AevonWriteFrame` 会退让，
    // 但 display 这里只在尺寸真的不同时才写，且带 0.20 s 节流 —— 让路那一拍
    // 最多多一次屏幕纠正，不会变成每帧一条更新。
    if (AevonWriteDisplay(settings, slot)) wrote |= 16;
    return wrote;
}


static AevonHookSlot *AevonReserve(const char *label) {
    if (AevonSlotCount >= AEVON_HOOK_SLOTS) return NULL;
    AevonHookSlot *slot = &AevonSlots[AevonSlotCount++];
    memset(slot, 0, sizeof(*slot));
    slot->label = label;
    return slot;
}

/// 0.2.32 — 谁真的实现了这个选择子。
///
/// 0.2.31 的日志把「钩子没响」钉在一个数字上：`hook: live=1 deact_set=0
/// intercept=0/0`。那一格 live 不是 deact —— 通知接口的 `nc-cap` 在开机时就
/// 占了一格，而 `AevonHookInstall` 拿 `AevonSlotCount > 0` 当「本进程已经装过」
/// 的判据，于是 deact 与 intercept **一次都没被尝试**。判据换成独立标志之后，
/// 剩下的问题是这两个选择子挂在哪个类上 —— 那不能再靠类名猜（iOS 换过实现者）。
/// 把 ObjC 全类表走一遍，谁的方法表里有这个选择子，谁就是实现者。
static int AevonOwnersOf(SEL sel, Class *owners, int limit) {
    if (sel == NULL || owners == NULL || limit <= 0) return 0;
    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return 0;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)capacity);
    if (classes == NULL) return 0;
    int total = objc_getClassList(classes, capacity);
    if (total > capacity) total = capacity;
    int found = 0;
    for (int i = 0; i < total && found < limit; i++) {
        Class cls = classes[i];
        if (cls == Nil) continue;
        unsigned int count = 0;
        Method *list = class_copyMethodList(cls, &count);
        if (list == NULL) continue;
        BOOL owns = NO;
        for (unsigned int j = 0; j < count; j++) {
            if (method_getName(list[j]) == sel) { owns = YES; break; }
        }
        free(list);
        if (!owns) continue;
        BOOL dup = NO;
        for (int k = 0; k < found; k++) {
            if (owners[k] == cls) { dup = YES; break; }
        }
        if (!dup) owners[found++] = cls;
    }
    free(classes);
    return found;
}

/// Installs one replacement and says in the notes exactly what happened. The
/// IMP that comes back from `imp_implementationWithBlock` is the runtime's own,
/// which is why the read-back can differ from it on arm64e and still be live —
/// the counter, not this number, is the answer.
static void AevonRelease(AevonHookSlot *slot);

static BOOL AevonAttach(NSMutableString *out, AevonHookSlot *slot,
                        Class cls, NSString *selName, id block) {
    if (out == nil || slot == NULL || cls == Nil || selName == nil || block == nil) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (sel == NULL) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) {
        [out appendFormat:@"hook %s: no method\n", slot->label];
        AevonRelease(slot);
        return NO;
    }

    IMP previous = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    if (replacement == NULL) {
        [out appendFormat:@"hook %s: no trampoline\n", slot->label];
        AevonRelease(slot);
        return NO;
    }

    BOOL owns = NO;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; list != NULL && i < count; i++) {
        if (method_getName(list[i]) == sel) { owns = YES; break; }
    }
    free(list);

    BOOL wrote = NO;
    if (owns) {
        method_setImplementation(method, replacement);
        wrote = YES;
    } else {
        wrote = class_addMethod(cls, sel, replacement, method_getTypeEncoding(method));
    }

    slot->cls = cls;
    slot->sel = sel;
    slot->original = previous;
    slot->replacement = replacement;

    IMP back = method_getImplementation(class_getInstanceMethod(cls, sel));
    [out appendFormat:@"hook %s cls=%@ wrote=%@ back=%p want=%p %@\n",
     slot->label, NSStringFromClass(cls), wrote ? @"yes" : @"no",
     (void *)back, (void *)replacement,
     back == replacement ? @"exact" : @"signed-or-trampolined"];
    return wrote;
}

/// A candidate that was never installed must not be counted as live: `hook: live=N`
/// is the one number that says how many replacements the process is running, and
/// a skipped candidate is not one of them. Only the slot reserved last is ever
/// handed back, which is why this is a pop and not a splice.
static void AevonRelease(AevonHookSlot *slot) {
    if (slot == NULL) return;
    if (AevonSlotCount > 0 && &AevonSlots[AevonSlotCount - 1] == slot) {
        AevonSlotCount -= 1;
    }
}

/// Same install, but only when the method really takes `wantArgs` objects.
///
/// The encoding is read off the running system rather than assumed: the whole
/// 0.0.29 intercept sat in this file for two versions without ever being called
/// because the *class* was wrong, and calling a private method with the wrong
/// arity is a worse failure than not calling it. A shape that does not match is
/// reported with the characters it actually has, so the next version can write
/// the branch against a reading instead of a guess.
static BOOL AevonAttachShaped(NSMutableString *out, AevonHookSlot *slot,
                              Class cls, NSString *selName, int wantArgs,
                              id block) {
    if (out == nil || slot == NULL || selName == nil) return NO;
    if (cls == Nil) {
        [out appendFormat:@"hook %s: no class %@\n", slot->label, selName];
        AevonRelease(slot);
        return NO;
    }
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (method == NULL) {
        [out appendFormat:@"hook %s: no method on %@\n", slot->label, NSStringFromClass(cls)];
        AevonRelease(slot);
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    int args = AevonObjectArgs(encoding);
    if (args != wantArgs) {
        [out appendFormat:@"hook %s cls=%@ skipped types=%s args=%d want=%d\n",
         slot->label, NSStringFromClass(cls),
         encoding != NULL ? encoding : "?", args, wantArgs];
        AevonRelease(slot);
        return NO;
    }
    [out appendFormat:@"hook %s shape cls=%@ types=%s args=%d\n",
     slot->label, NSStringFromClass(cls), encoding, args];
    return AevonAttach(out, slot, cls, selName, block);
}

// The self test. A class of our own, a method that returns its argument plus
// one, and a replacement that adds a hundred: 102 means the whole path works —
// the write, the call, and calling the original through the saved IMP. Anything
// else means the rest of this file would be guessing, and the caller is told.
@interface AevonHookProbe : NSObject
- (NSInteger)aevonProbeAddOne:(NSInteger)value;
@end

@implementation AevonHookProbe
- (NSInteger)aevonProbeAddOne:(NSInteger)value { return value + 1; }
@end

static IMP AevonProbeOriginal = NULL;
static SEL AevonProbeSelector = NULL;

static NSInteger AevonProbeSelfTest(void) {
    AevonProbeSelector = @selector(aevonProbeAddOne:);
    Method method = class_getInstanceMethod([AevonHookProbe class], AevonProbeSelector);
    if (method == NULL) return -1;
    AevonProbeOriginal = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^NSInteger(id object, NSInteger value) {
        NSInteger (*call)(id, SEL, NSInteger) =
            (NSInteger (*)(id, SEL, NSInteger))AevonProbeOriginal;
        if (call == NULL) return value;
        return call(object, AevonProbeSelector, value) + 100;
    });
    if (replacement == NULL) return -2;
    method_setImplementation(method, replacement);
    AevonHookProbe *probe = [[AevonHookProbe alloc] init];
    NSInteger (*call)(id, SEL, NSInteger) = (NSInteger (*)(id, SEL, NSInteger))objc_msgSend;
    NSInteger got = call(probe, AevonProbeSelector, 1);
    method_setImplementation(method, AevonProbeOriginal);
    return got;
}

// ============================================================================
// 0.4.0 — 这一段原来有 400 行：URL 归谁（LaunchServices 快路 + 失败记录）、
// 解析不出来时的 pending 三件套、`AevonURLDefer` 的延迟交回结构、以及一整排
// URL 落点计数（`AevonActHits` / `AevonDeny*` / `AevonDeliver*` / `AevonFwdHold*`）。
// 全部随 URL 主线删除。
//
// 一并删掉的还有 `AevonPassSkipFlag`：它只服务 0.3.36 的「放行式接管」——
// 系统自己会开那次 App，`openCard` 看到它就跳过 Home 与挂起启动。这一版没有
// 放行式接管，没有谁会把它置 1，那两道门在 `SceneProbe.openCard` 里也跟着删了。
// ============================================================================

static int AevonSceneHooksInstalled = 0;

NSString *AevonHookInstall(void) {
    NSMutableString *out = [NSMutableString string];
    if (AevonSceneHooksInstalled) {
        [out appendString:@"hook: already installed in this process\n"];
        return out;
    }

    NSInteger selfTest = AevonProbeSelfTest();
    [out appendFormat:@"hook: selftest got=%ld want=102 %@\n", (long)selfTest,
     selfTest == 102 ? @"ok" : @"FAILED"];
    // The self test is not decoration. If our own thirty-line class cannot be
    // replaced, then five replacements on SpringBoard's scene path would be five
    // chances to crash it for nothing, and the run would have to be explained
    // from a log that stops mid-sentence. The answer this version wants is
    // either "the mechanism works" or "it does not", and both of them are in
    // that one number.
    if (selfTest != 102) {
        [out appendString:@"hook: not installing anything - the write path did not prove itself\n"];
        return out;
    }

    AevonSceneHooksInstalled = 1;

    // 1. The one the whole route rests on. `_setDeactivationReasons:` is how
    //    SpringBoard decides whether a scene may sleep; stripping the reasons of
    //    exactly one bundled scene is the mother ship's mechanism, and it is the
    //    only thing that keeps a backgrounded app drawing.
    //
    //    0.2.32 — 目标类不再按名字猜。登录日志里 0.0.35 曾经 `deact_set=119`，
    //    但 0.2.31 这一格是 0；类名在这台系统上还能不能对上，只有方法表知道。
    //    按选择子扫全类表，谁实现谁挨钩，扫到几个就写几个。
    SEL deactSel = NSSelectorFromString(@"_setDeactivationReasons:onScene:withSettings:reason:");
    Class deactOwners[4] = { Nil, Nil, Nil, Nil };
    int deactCount = AevonOwnersOf(deactSel, deactOwners, 4);
    [out appendFormat:@"hook deact-set: scan owners=%d\n", deactCount];
    if (deactCount == 0) {
        [out appendString:@"hook deact-set: no class owns _setDeactivationReasons:onScene:withSettings:reason:\n"];
    }
    for (int i = 0; i < deactCount; i++) {
        Class owner = deactOwners[i];
        Method method = class_getInstanceMethod(owner, deactSel);
        const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
        if (encoding == NULL || strcmp(encoding, "v48@0:8Q16@24@32@40") != 0) {
            [out appendFormat:@"hook deact-set: skip cls=%@ types=%s\n",
             NSStringFromClass(owner), encoding != NULL ? encoding : "?"];
            continue;
        }
        AevonHookSlot *slot = AevonReserve("deact-set");
        if (slot == NULL) {
            [out appendString:@"hook deact-set: no slot\n"];
            break;
        }
        AevonHookSlot *mine = slot;
        id block = ^(id manager, unsigned long long reasons, id scene,
                     id settings, id reason) {
            long seen = __sync_fetch_and_add(&AevonDeactSetCalls, 1);
            // The instance this file spent two versions failing to find is
            // the first argument of the one hook the device does call.
            if (AevonDeactManager == nil) AevonDeactManager = manager;
            BOOL ours = AevonSceneIsMine(scene);
            if (seen < 4) {
                AevonRawTrace("deact-set", "reasons=%llu mine=%d scene=%s",
                              reasons, ours ? 1 : 0, AevonSceneName(scene));
            }
            unsigned long long use = reasons;
            if (ours && reasons != 0) {
                use = 0;
                AevonDeactReasons = (long)reasons;
                if (__sync_fetch_and_add(&AevonDeactStripped, 1) < 4) {
                    AevonRawTrace("stripped", "%llu->0 scene=%s",
                                  reasons, AevonSceneName(scene));
                }
            }
            // Keeping the scene awake is half of it, and it is the half that
            // stays here. Aevon(28) had it working — `stripped=8` — and a
            // black card, because the app had been told it was in the
            // background and had stopped drawing.
            //
            // The other half used to be written right here, inside this
            // callback, and Aevon(29) is the price: `push path=1 wrote=1
            // fg=1`, a card with a picture in it, and then silence until the
            // watchdog replaced the process. This body runs on FrontBoard's
            // scene-update path, which holds the lock that `updateSettings…`
            // needs, so writing from here takes it twice. The push lives on
            // the main-thread keepalive clock in SceneProbe now; all this
            // hook does is announce that it is on the stack so nothing else
            // can write through it.
            __sync_fetch_and_add(&AevonHookDepth, 1);
            void (*original)(id, SEL, unsigned long long, id, id, id) =
                (void (*)(id, SEL, unsigned long long, id, id, id))mine->original;
            if (original != NULL) {
                original(manager, mine->sel, use, scene, settings, reason);
            }
            __sync_fetch_and_sub(&AevonHookDepth, 1);
        };
        AevonAttach(out, slot, owner,
                    @"_setDeactivationReasons:onScene:withSettings:reason:", block);
    }

    // 2. The mother ship's real door, on the class(es) that actually implement it.
    //
    //    `SBMainDisplaySceneManager` is a subclass of `SBSceneManager`, and
    //    0.0.29 patched the parent: `intercept=0` for eight seconds, twice. A
    //    subclass that overrides a method never runs the parent's IMP, so a
    //    patch on the parent is a patch on a method nothing calls. Both names
    //    are no longer assumed: the selector is scanned for, and every owner is
    //    hooked — a subclass with its own IMP and its parent both need one.
    //
    //    The amendment happens *before* the original runs: whatever the original
    //    does with the settings — apply them itself, or hand them back to its
    //    caller to apply — it does it to the version we changed.
    SEL interceptSel = NSSelectorFromString(@"_scene:interceptUpdateWithNewSettings:");
    Class interceptOwners[4] = { Nil, Nil, Nil, Nil };
    int interceptCount = AevonOwnersOf(interceptSel, interceptOwners, 4);
    [out appendFormat:@"hook intercept: scan owners=%d\n", interceptCount];
    if (interceptCount == 0) {
        [out appendString:@"hook intercept: no class owns _scene:interceptUpdateWithNewSettings:\n"];
    }
    for (int i = 0; i < interceptCount; i++) {
        Class owner = interceptOwners[i];
        AevonHookSlot *slot = AevonReserve("intercept");
        if (slot == NULL) {
            [out appendString:@"hook intercept: no slot\n"];
            break;
        }
        AevonHookSlot *mine = slot;
        id block = ^(id manager, id scene, id settings) {
            long seen = __sync_fetch_and_add(&AevonInterceptCalls, 1);
            // 0.2.4 — 第二条口径：系统每推一次 settings，就说明这个 scene 真的在。
            // 这一行必须在 `AevonSlotOfScene` 之前 —— 记的是「存在」，判断归谁管
            // 是后面的事，两件事分开才不会因为没 arm 就漏掉一个真实存在的 scene。
            AevonSeenNote(scene);
            int mineSlot = AevonSlotOfScene(scene);
            BOOL ours = mineSlot >= 0;
            int wasFront = AevonFlagOf(settings, "isForeground");
            int amended = 0;
            if (ours) {
                amended = AevonAmendSettings(settings, mineSlot);
                if (amended > 0) __sync_fetch_and_add(&AevonInterceptRewrote, 1);
            }
            if (seen < 6) {
                AevonRawTrace("intercept", "mine=%d fg=%d amend=%d cls=%s scene=%s",
                              ours ? 1 : 0, wasFront, amended,
                              object_getClassName(settings), AevonSceneName(scene));
            }
            void (*original)(id, SEL, id, id) =
                (void (*)(id, SEL, id, id))mine->original;
            // 这里只改对象、不调 `updateSettings`，所以没有 0.0.31 那个重入；
            // 深度计数照旧抬一下，好让守护在这一次调用期间什么都不写。
            __sync_fetch_and_add(&AevonHookDepth, 1);
            if (original != NULL) original(manager, mine->sel, scene, settings);
            __sync_fetch_and_sub(&AevonHookDepth, 1);
        };
        AevonAttachShaped(out, slot, owner, @"_scene:interceptUpdateWithNewSettings:", 2, block);
    }

    // 3. 落点（0.2.63）—— 报告里的方案 A：不跟系统抢，只改它摆在哪。

    return out;
}

/// The counters and the traces, one line each. Called at the two moments when
/// the answer matters: right before the card is built, and right after it is
/// taken down.
///
/// 0.4.0 — `landing=%ld/%ld` 与整条 `act: hits …` 一并删除：那些计数属于 URL
/// 落点链（`AevonLand*` / 卡目标窗口），这一版没有那条链，每次都是 0。留着它们
/// 不但没用，还会在裁剪时把实参和格式串拆散 —— `landing=%ld/%ld` 后面一个实参
/// 都没有，读的是栈垃圾。
NSString *AevonHookSummary(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"hook: live=%d deact_set=%ld stripped=%ld"
     " intercept=%ld/%ld"
     " push=%ld/%ld door=%ld armed=%@\n",
     AevonSlotCount, AevonDeactSetCalls, AevonDeactStripped,
     AevonInterceptRewrote, AevonInterceptCalls,
     AevonPushWrote, AevonPushTried, AevonPushPath,
     AevonHookArmedList()];
    long total = AevonTraceCount;
    long limit = (long)(sizeof(AevonTrace) / sizeof(AevonTrace[0]));
    if (total > limit) total = limit;
    for (long i = 0; i < total; i++) {
        if (AevonTrace[i][0] == '\0') continue;
        [out appendFormat:@"hook trace %ld %s\n", i, AevonTrace[i]];
    }
    return out;
}

/// 0.0.52 — 拦截点的两个计数，给守护的节拍行用。
///
/// 这两个数比任何解释都直接：`ic` 是系统把 settings 交给拦截方法的次数（0 就是
/// 「这个选择子在这台系统上不走」），`iw` 是其中真的被我们改成前台档的次数。
/// 切一次 App，哪个数动了，哪条路就是活的。
long AevonInterceptCount(void) { return AevonInterceptCalls; }
long AevonInterceptWrites(void) { return AevonInterceptRewrote; }


/// 0.2.57 — 真正被我们清零掉的次数（`reasons != 0` 那一种）。这是「场景被
/// 要求去激活、而我们把要求撤掉了」的计数，不是「钩子被调了几次」。
long AevonDeactStrippedCount(void) {
    return __sync_fetch_and_add(&AevonDeactStripped, 0);
}

/// 0.2.57 — 最近一次被清零的 reasons 位掩码（Aevon(198) 里见到 32 / 34 / 2）。
int AevonDeactLastReasons(void) {
    return (int)AevonDeactReasons;
}

/// The system's own answer to "may this scene go to sleep". `ULLONG_MAX` means
/// the method is not there, which is not the same answer as zero.
unsigned long long AevonReasonsOf(id scene) {
    if (scene == nil) return ULLONG_MAX;
    SEL getter = NSSelectorFromString(@"_deactivationReasonsForScene:withSettings:");
    SEL setter = NSSelectorFromString(@"_setDeactivationReasons:onScene:withSettings:reason:");

    id manager = AevonDeactManager;
    Class cls = NSClassFromString(@"UIApplicationSceneDeactivationManager");
    // The captured instance first: this system vends no singleton under any of
    // the three names below, which is why two versions printed `absent` for a
    // method the census could see.
    if (manager == nil && cls != Nil) {
        for (NSString *name in @[@"sharedInstance", @"sharedManager", @"defaultManager"]) {
            SEL sel = NSSelectorFromString(name);
            if (![cls respondsToSelector:sel]) continue;
            id got = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
            if (got != nil) { manager = got; break; }
        }
    }
    // No class door? The scene manager keeps one, and an ivar walk is the runtime
    // fact rather than a guess at a name.
    if (manager == nil) {
        id holder = AevonSceneManager();
        if (holder != nil) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList([holder class], &count);
            for (unsigned int i = 0; ivars != NULL && i < count; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type == NULL || type[0] != '@') continue;
                id value = object_getIvar(holder, ivars[i]);
                if (value != nil && [value respondsToSelector:setter]) { manager = value; break; }
            }
            free(ivars);
        }
    }
    if (manager == nil || ![manager respondsToSelector:getter]) return ULLONG_MAX;

    id settings = nil;
    if ([scene respondsToSelector:@selector(settings)]) {
        settings = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings));
    }
    unsigned long long (*call)(id, SEL, id, id) =
        (unsigned long long (*)(id, SEL, id, id))objc_msgSend;
    return call(manager, getter, scene, settings);
}


// MARK: - 画面到底在不在（0.0.50）

//
//  Aevon(48) 的日志把 0.0.40 留下的那个选择题答完了，而且答案和当时写的
//  两种都不是：桌面↔全屏 App 的每一轮，`keepalive beat` 一行不少，`fg=yes`
//  从头到尾没变过，`wrote` 一直是 1 — 也就是说那段黑**根本不经过 settings**。
//  我们四版都在盯 `settings.isForeground`，而这个值在切换 App 时从来不变：
//  它是我们自己写进去的，系统不负责把它改写回来。守护因此一次都没反应，画面
//  是等系统自己把 scene 接回去才恢复的 —— 用户看到的「闪黑一下」就是这段没人
//  管的空窗。
//
//  该盯的是 `FBScene.contentState`：2 = ready（有画），0 = 没准备好（黑）。
//  MultiFloat 的第八轮日志里这个数就是判据（`contentState=2` 有画面，
//  `contentState=0` 黑）。它掉下去的那一刻才是「画面掉了」，而它回来的那一刻
//  才是「画面回来了」，两者都能写成一行日志，不用再猜。

/// `FBScene.contentState`. 2 = ready, 0 = 还没准备好. -1 = 没有这个方法.
long AevonContentStateOf(id scene) {
    if (scene == nil) return -1;
    SEL sel = sel_registerName("contentState");
    if (![scene respondsToSelector:sel]) return -1;
    long (*call)(id, SEL) = (long (*)(id, SEL))objc_msgSend;
    return call(scene, sel);
}

/// `scene.settings.level` — 母本那三件套里的第二件（`foreground / level /
/// idleModeEnabled`）。1 = 前台档, 0 = 后台档。读不到回 -1。
double AevonSceneLevel(id scene) {
    if (scene == nil) return -1;
    SEL settingsSel = sel_registerName("settings");
    if (![scene respondsToSelector:settingsSel]) return -1;
    id settings = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    if (settings == nil) return -1;
    SEL levelSel = sel_registerName("level");
    if (![settings respondsToSelector:levelSel]) return -1;
    double (*call)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
    return call(settings, levelSel);
}

/// 母本写 settings 时一直带着 `level = 1` 与 `idleModeEnabled = NO`，而这个
/// 文件从 0.0.30 起只写 foreground/backgrounded。两件都按 respondsToSelector
/// 走，没有 setter 就跳过 —— 一个不存在的 selector 是一个事实，不是一次崩溃。
///
/// `level` 先读再写，而且只在一个合理的 level（0…2）上写：这个 getter 的
/// 类型是这版假设出来的 CGFloat，万一 ABI 不是它，读回来会是一个离谱的数，
/// 那时候宁可不写 —— 一笔类型写错的 settings，比不写更糟。
static void AevonWriteLevelIdle(id settings) {
    if (settings == nil) return;
    if (!AevonSettingsMutable(settings)) return;
    SEL getter = sel_registerName("level");
    BOOL sane = NO;
    if ([settings respondsToSelector:getter]) {
        double current = ((double (*)(id, SEL))objc_msgSend)(settings, getter);
        sane = (current >= 0.0 && current <= 2.0);
    }
    if (sane) {
        SEL setter = sel_registerName("setLevel:");
        if ([settings respondsToSelector:setter]) {
            ((void (*)(id, SEL, double))objc_msgSend)(settings, setter, 1.0);
            AevonLevelForced = 1;
        }
    }
    SEL idle = sel_registerName("setIdleModeEnabled:");
    if ([settings respondsToSelector:idle]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, idle, NO);
    }
}

static long AevonWakeTried = 0;
static long AevonWakeWrote = 0;
static CFAbsoluteTime AevonLastWake = 0;

long AevonWakeCount(void) { return AevonWakeWrote; }

/// 画面回来的那一刻把额度还回去。
///
/// 0.0.51 — 额度是「这一段黑」的闸门，不是整场会话的。按整场算的那一份在
/// 真机上一会儿就烧完了：一台手机一天切几十次 App，而每一次掉画都会连打几拍。
void AevonWakeReset(void) {
    __sync_lock_test_and_set(&AevonWakeTried, 0);
    // 同时把上一次的时间戳抹掉，否则新一段黑的头一拍会被上一段的 200 ms 挡住
    // —— 那正是最需要写的一次。
    AevonLastWake = 0;
}

/// 画面掉下去之后的唯一一件事：把 scene 重新说成「在前台」。
///
/// 它和 `AevonPushForeground` 的差别只有两处，两处都必要：
///   · 不做「已经是前台就不写」的早退 —— 画面黑的时候 `fg` 恰恰还是 1，
///     那条早退正是守护这四版一次都没动的原因（返回 4，零写入）。
///   · 一起写 `level = 1 / idleModeEnabled = NO`，母本那一组三件套。
///
/// 只由 `contentState != 2` 触发，上限 8 次、间隔 200 ms：写得比这更勤就是
/// 0.0.40 之后被否掉的那种「定时重申」，每一次重申都是一次重提交。
///
/// 0.0.54 — 额度从 60 压到 8。0.0.53 的真机日志里 41 条节拍、`wake=0` 到底：
/// 事前拦截装好之后，这条兜底一次都不该被用到。60 是给「还没修好」留的余量，
/// 留着它只会在真出问题时把一次黑屏变成一段密集改写 —— 8 次（约 1.6 秒）足够
/// 撑过一次真正的掉画，又不会在错误的方向上硬撑整场。
static const long AevonWakeBudget = 8;



/// 真正的写入体。调用方负责全部闸门 —— 两个入口的闸门只差「节流 / 额度」。
static NSInteger AevonWakeWrite(id scene) {
    AevonInPush = 1;

    SEL settingsSel = sel_registerName("settings");
    id current = nil;
    if ([scene respondsToSelector:settingsSel]) {
        current = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    }
    id candidate = [current mutableCopy];
    if (candidate == nil) candidate = current;
    AevonWriteFront(candidate, YES);
    AevonWriteLevelIdle(candidate);

    void (^amend)(id) = [^(id settings) {
        AevonWriteFront(settings, YES);
        AevonWriteLevelIdle(settings);
    } copy];

    NSInteger path = AevonCallSettingsTransition(scene, candidate);
    if (path == 0) {
        if (AevonCallBlockMethod(scene, @"updateSettingsWithBlock:", amend)
            || AevonCallSettings(scene, candidate)) {
            path = 1;
        }
    }
    if (path != 0) __sync_fetch_and_add(&AevonWakeWrote, 1);
    AevonInPush = 0;
    return path;
}

NSInteger AevonWakeScene(id scene) {
    if (scene == nil || !AevonIsArmed()) return 0;
    if (![NSThread isMainThread]) return 0;
    if (AevonHookDepth > 0) return 0;
    if (AevonInPush) return 0;
    // 0.0.51 — 计数的位置挪到节流之后。原来它排在节流前面，掉画期间每 60 ms
    // 一拍都会自增：一次真正的写入要吃掉四拍，60 次的额度三秒就烧完，此后这
    // 一次会话里再也不会唤醒 —— 修好的东西自己会过期，这比不修更糟。
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - AevonLastWake < 0.2) return 0;
    if (__sync_fetch_and_add(&AevonWakeTried, 1) > AevonWakeBudget) return 0;
    AevonLastWake = now;
    return AevonWakeWrite(scene);
}



// MARK: - 浮窗的手指入口（0.0.48）

//
//  四份日志（Aevon(43)-(46)）说的是同一件事：卡片外面没有一个触摸进过我们的
//  任何窗口。`win: event hit` 整场只有 ✕ 那一条（0.0.44-0.0.46），独立的 band
//  窗口那版 `win: band probe` 也只有 ✕ 那一条（0.0.47）—— 而卡片里的 ✕ 一直
//  好用。所以「窗口会不会被问到」这件事本身不可靠，环的宽度、位置、层级都不是
//  瓶颈；0.0.44 到 0.0.47 四轮改的都是那一层。
//
//  `-[UIApplication sendEvent:]` 是唯一一个不管命中哪个窗口都会经过的地方。浮窗
//  的四个边（移动 / 缩放 / 上滑关闭 / 点吸附）从这里拿手指，判断和动作全在 Swift
//  （FloatHost.rawTouch），这里只做三件事：取唯一那根手指、报位置和相位、被吃掉
//  就不往下传。
//
extern int AevonFloatTouch(int phase, double x, double y, double stamp);
/// 0.1.4 — 多指时那条窄入口：只问停靠小窗，不碰主窗。
extern int AevonFloatTouchMini(int phase, double x, double y, double stamp);
/// 0.1.23 — 右缘呼盘。同一件事的第二次证明：窗口级的 `sendEvent`（0.1.22）
/// 在 Aevon(106) 里**一次都没被调用**，而这一层一直是通的 —— 浮窗的五个手势
/// 就是证据。定义在 `RingHost.swift` 末尾（`@_cdecl`）。
extern int AevonRingEdgeTouch(int phase, double x, double y);

/// 0.2.75 — 运行期闸快照。定义在 `Sources/Core/Gate.swift` 末尾（`@_cdecl`）。
///
/// 这个工程没有 Umbrella header，所以跨语言只有 C 符号这一条路 —— 与上面
/// `AevonRingEdgeTouch` / 下面 `AevonFloatTouch` 是同一个约定。
extern int AevonGateOff(void);

static IMP AevonSendEventOriginal = NULL;

static void AevonSendEventReplacement(id self, SEL _cmd, UIEvent *event) {
    if (AevonSendEventOriginal == NULL) return;

    // 0.2.75 — 闸关：**一个字节都不看**，原样交回系统。
    //
    // Aevon(207) 里用户把 G0 与 G1 都打开，`win: touch in=17 eat=3` 照样在吞。
    // 原因是 `AevonInstallTouchTap` 用 `dispatch_once` 装钩子，装完永不复查；
    // 闸又只在 `Gate.evaluate()` 那一次跑过。于是「紧急停止」只改了设置界面
    // 上的一行字。
    //
    // 现在每个触摸先问一句内存里的 Bool（`Gate.refreshRuntime` 在收到
    // `com.aevon.gate` 时更新它）。放在最前面而不是放进 `AevonFloatTouch`：
    // 那条路只覆盖单指与多指两个分支，而 `allTouches` / `locationInView:`
    // 这些调用本身也不该在停手之后发生。
    if (AevonGateOff()) {
        ((void (*)(id, SEL, UIEvent *))AevonSendEventOriginal)(self, _cmd, event);
        return;
    }

    BOOL eaten = NO;
    NSSet *touches = [event allTouches];
    // 多指一律不接：浮窗的五个手势都是单指，而两根手指同时按下的那一瞬吞掉
    // 事件表，就是在替系统决定缩放手势的生死。
    if ([touches count] == 1) {
        UITouch *touch = [touches anyObject];
        // 相位原样交过去，包括 Stationary：那一条也得跟着吞，否则 UIKit 会收到
        // 一根它从没见过的「静止的」手指。
        CGPoint point = [touch locationInView:nil];
        eaten = AevonFloatTouch((int)[touch phase], point.x, point.y,
                                [touch timestamp]) != 0;
        // 0.1.23 — 浮窗没吃掉，再问右缘呼盘。
        //
        // 放在浮窗**之后**：小窗真的压在右缘上时，那根手指该归小窗（用户看得见
        // 的那个东西优先）。`AevonFloatTouch` 在手指不在任何卡上时立刻回 0，
        // 所以正常情况这里只是一次矩形判断。
        if (!eaten) {
            eaten = AevonRingEdgeTouch((int)[touch phase], point.x, point.y) != 0;
        }
    } else if ([touches count] > 1) {
        // 0.1.4 — 多指仍然不交给主窗（上面那条纪律没变），但**停靠小窗要看一眼**：
        // 只要有一根手指真的落在小窗里，那一下就必须被吞，否则会透给 App。
        // 用户第三次报「透传还在」，而 Aevon(92) 里 `down`/`eaten` 一直相等 ——
        // 那不是小窗边界的问题，是这些事件根本没进过单指那条路。
        // `AevonFloatTouchMini` 在手指不落在任何小窗里时立刻回 0，所以主窗的
        // 缩放手势（多指）一点都没被碰到。
        for (UITouch *touch in touches) {
            CGPoint point = [touch locationInView:nil];
            if (AevonFloatTouchMini((int)[touch phase], point.x, point.y,
                                    [touch timestamp]) != 0) {
                eaten = YES;
                break;
            }
        }
    }
    if (!eaten) {
        ((void (*)(id, SEL, UIEvent *))AevonSendEventOriginal)(self, _cmd, event);
    }
}

/// 由 Swift 的 AevonStart 调一次。装不上就什么都不做：没有这个入口，浮窗只是
/// 退回「四周手势不灵」，而不是把 SpringBoard 的触摸弄坏。
void AevonInstallTouchTap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method method = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
        if (method == NULL) return;
        AevonSendEventOriginal = method_getImplementation(method);
        method_setImplementation(method, (IMP)AevonSendEventReplacement);
    });
}

// MARK: - 浮窗期间禁止空闲熄屏（0.0.55，移植自旧版 AevonNoAutoLockV248/V249 + AevonIdleRelV269）

//
//  Aevon(23)：「用浮窗播放抖音视频时，手机会根据系统的锁屏时间来暗屏和锁屏」。
//  浮窗里放视频时手指不碰屏幕，系统照常按「自动锁定」暗屏 → 锁屏 → 视频停。
//
//  0.0.55 — 从旧版 `AevonSceneDriverShim.m` 1:1 移植（那一版在 17.3.1 上实测有效，
//  日志里 mask 一路带 8 = 断言通道命中）。三条通道，按强度排列：
//
//    1. `acquireIdleTimerDisableAssertionForReason:` —— 拿一条「空闲计时器禁用」断言，
//       这是最硬的一条；拿到的对象必须**留着并在关窗时释放**，否则浮窗关掉之后
//       手机不再按设置自动暗屏（旧版 Aevon(41) #7 的真凶，只取不放）。
//    2. `resetIdleTimer` 一族 —— 每调一次等于告诉系统「用户又动了」，计时重新起表。
//       调用方 20 秒一次（≪ 系统最短的自动锁定 30 秒），本文件自己不计时。
//    3. `UIApplication.isIdleTimerDisabled = YES` —— 兜底。SpringBoard 进程里这一笔
//       不进 SpringBoard 自己的空闲计时器，所以它只能当第三条，不能当第一条。
//
//  全链 `@try`，任何一步不存在就往下走；私有 API 改名不会崩，只会让 mask 少一位。

static id gAevonIdleAssertions[8];
static int gAevonIdleAssertionCount = 0;
static BOOL gAevonIdleSavedKnown = NO;
static BOOL gAevonIdleSavedValue = NO;
static long gAevonIdleKicks = 0;

long AevonIdleTimerCount(void) { return gAevonIdleKicks; }

static NSArray<NSString *> *AevonIdleCoordinatorNames(void) {
    return @[@"SBIdleTimerGlobalCoordinator",
             @"SBIdleTimerCoordinatorHelper",
             @"SBIdleTimerGlobalStateMonitor",
             @"SBIdleTimerPolicyAggregator",
             @"SBLockScreenIdleTimer",
             @"SBIdleTimerAggregator"];
}

static NSArray<NSString *> *AevonIdleFactoryNames(void) {
    return @[@"sharedInstance", @"sharedCoordinator", @"globalCoordinator", @"shared"];
}

/// 所有能拿到的协调器实例。同一对象只出现一次。
static NSArray *AevonIdleCoordinators(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in AevonIdleCoordinatorNames()) {
        Class cls = NSClassFromString(name);
        if (cls == Nil) continue;
        for (NSString *factory in AevonIdleFactoryNames()) {
            SEL sel = NSSelectorFromString(factory);
            if (![cls respondsToSelector:sel]) continue;
            id object = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
            if (object != nil && ![out containsObject:object]) [out addObject:object];
        }
    }
    return out;
}

/// `UIApplication.sharedApplication`，取不到回 nil（SpringBoard 里这是非可选属性，
/// 直接点会崩；这一条和旧版同一条理由）。
static id AevonIdleApplication(void) {
    Class cls = NSClassFromString(@"UIApplication");
    if (cls == Nil) return nil;
    SEL sel = NSSelectorFromString(@"sharedApplication");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

/// 记下 `isIdleTimerDisabled` 的原值。只记一次，关窗时写回这个值 ——
/// 不假设用户设置里自动锁定是开还是关。
static void AevonIdleRememberOriginal(void) {
    if (gAevonIdleSavedKnown) return;
    id app = AevonIdleApplication();
    if (app == nil) return;
    SEL getter = NSSelectorFromString(@"isIdleTimerDisabled");
    if (![app respondsToSelector:getter]) return;
    gAevonIdleSavedValue = ((BOOL (*)(id, SEL))objc_msgSend)(app, getter);
    gAevonIdleSavedKnown = YES;
}

/// 三条通道各打一拍。返回位掩码：1 = resetIdleTimer，2 = resetIdleTimerAndUndim:，
/// 4 = isIdleTimerDisabled 写成功，8 = 拿到断言，16 = 走了下划线的私有 reset 变体。
NSInteger AevonIdleTimerKick(void) {
    NSInteger mask = 0;
    @try {
        for (id coordinator in AevonIdleCoordinators()) {
            for (NSString *name in @[@"resetIdleTimer", @"_resetIdleTimer",
                                     @"resetIdleTimerAndCancelPrevious",
                                     @"_resetIdleTimerAndCancelPrevious",
                                     @"_updateIdleTimer", @"_resetIdleTimerIfNecessary"]) {
                SEL sel = NSSelectorFromString(name);
                if (![coordinator respondsToSelector:sel]) continue;
                ((void (*)(id, SEL))objc_msgSend)(coordinator, sel);
                mask |= [name hasPrefix:@"_"] ? 16 : 1;
            }
            SEL undim = NSSelectorFromString(@"resetIdleTimerAndUndim:");
            if ([coordinator respondsToSelector:undim]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(coordinator, undim, YES);
                mask |= 2;
            }
            // 断言通道：同一个 reason 反复取是幂等的，返回的对象也一样，所以这里
            // 先查表再存 —— 每 20 秒存一个进去就是无限增长。
            SEL assertSel = NSSelectorFromString(@"acquireIdleTimerDisableAssertionForReason:");
            if ([coordinator respondsToSelector:assertSel]) {
                id assertion = ((id (*)(id, SEL, id))objc_msgSend)(coordinator, assertSel,
                                                                  @"AevonFloat");
                mask |= 8;
                if (assertion != nil && gAevonIdleAssertionCount < 8) {
                    BOOL known = NO;
                    for (int i = 0; i < gAevonIdleAssertionCount; i++) {
                        if (gAevonIdleAssertions[i] == assertion) { known = YES; break; }
                    }
                    if (!known) {
                        gAevonIdleAssertions[gAevonIdleAssertionCount++] = (id)CFRetain((CFTypeRef)assertion);
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        // 私有 API 抛异常：继续走兜底，绝不上抛。
    }
    @try {
        id app = AevonIdleApplication();
        SEL setter = NSSelectorFromString(@"setIdleTimerDisabled:");
        if (app != nil && [app respondsToSelector:setter]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(app, setter, YES);
            mask |= 4;
        }
    } @catch (NSException *exception) {
    }
    __sync_fetch_and_add(&gAevonIdleKicks, 1);
    return mask;
}

/// 卡片起来的同一刻：记原值 → 打第一拍。返回第一拍的 mask。
NSInteger AevonIdleTimerBegin(void) {
    AevonIdleRememberOriginal();
    return AevonIdleTimerKick();
}

/// 卡片关掉：释放断言 → 写回原值。两件事缺一不可 ——
/// 只放断言不写回，UIApplication 那一位还留着 YES；只写回不放断言，
/// SpringBoard 的空闲计时器仍被禁着（旧版 AevonIdleRelV269 的原话）。
NSInteger AevonIdleTimerEnd(void) {
    NSInteger mask = 0;
    @try {
        for (int i = 0; i < gAevonIdleAssertionCount; i++) {
            id assertion = gAevonIdleAssertions[i];
            gAevonIdleAssertions[i] = nil;
            if (assertion == nil) continue;
            for (NSString *name in @[@"invalidate", @"releaseAssertion", @"relinquish",
                                     @"release", @"cancel"]) {
                SEL sel = NSSelectorFromString(name);
                if (![assertion respondsToSelector:sel]) continue;
                ((void (*)(id, SEL))objc_msgSend)(assertion, sel);
                mask |= 1;
                break;
            }
            CFRelease((CFTypeRef)assertion);
        }
        gAevonIdleAssertionCount = 0;
    } @catch (NSException *exception) {
    }
    // 协调器兜底：方法名同时带 IdleTimer 与 ssertion、且以 release/relinquish 开头。
    @try {
        for (id coordinator in AevonIdleCoordinators()) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(object_getClass(coordinator), &count);
            for (unsigned int i = 0; methods != NULL && i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                if (name.length < 12) continue;
                BOOL timer = [name rangeOfString:@"dleTimer"].location != NSNotFound;
                BOOL assertion = [name rangeOfString:@"ssertion"].location != NSNotFound;
                BOOL release = [name hasPrefix:@"release"] || [name hasPrefix:@"relinquish"]
                    || [name rangeOfString:@"releaseAssertion"].location != NSNotFound
                    || [name rangeOfString:@"relinquishAssertion"].location != NSNotFound;
                if (!(timer && assertion && release)) continue;
                SEL sel = NSSelectorFromString(name);
                if (![coordinator respondsToSelector:sel]) continue;
                NSMethodSignature *sig = [coordinator methodSignatureForSelector:sel];
                if (sig == nil || sig.numberOfArguments > 2) continue;
                ((void (*)(id, SEL))objc_msgSend)(coordinator, sel);
                mask |= 2;
            }
            if (methods != NULL) free(methods);
        }
    } @catch (NSException *exception) {
    }
    @try {
        id app = AevonIdleApplication();
        SEL setter = NSSelectorFromString(@"setIdleTimerDisabled:");
        if (app != nil && [app respondsToSelector:setter]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(app, setter,
                                                    gAevonIdleSavedKnown ? gAevonIdleSavedValue : NO);
            mask |= 4;
        }
    } @catch (NSException *exception) {
    }
    gAevonIdleSavedKnown = NO;
    return mask;
}


// MARK: - 0.0.70 沙盒 App 的读数取回

//
// 桥接在 App 进程里写日志，但 App Store 应用跑在沙盒里，`/var/mobile/Aevon.log`
// 对它们不可写 —— `fopen` 返回 NULL，量尺照跑、读数照扔。全量日志能作证：所有
// 历史日志里 App 侧只出现过 Filza / Sileo / 设置三个进程。抖音的「视频贴顶」
// 因此量了三轮、一份读数都没到手。
//
// 桥接现在退到自己的 `tmp/aevon-app.log`，这里负责取回来并进主日志。取不到不算
// 错（宿主未必有读别人容器的权限），但会把路径写进日志 —— 那份文件用户可以从
// Filza 里直接拿出来。
//

/// 0.1.94 — 目录扫描的**结果**缓存，而不是「每问一次扫一遍」。
///
/// 0.1.93 把广播挪去后台队列之后，主线程上还剩一条同类路：停靠 / 取消停靠那一拍
/// 会走 `AevonAppMiniFlagSet` → `AevonAppContainer`。`LSApplicationProxy` 答得上
/// 时它是一步；答不上时（真机日志里 `mini flag armed … (no container)` 出现过 25
/// 次，设置与 Sileo 各二十来次）就退到扫目录：四个根、每层几百个目录、每个再读一份
/// metadata plist。一次几十到几百毫秒，正好落在用户松手那一刻的主线程上。
///
/// 这里改成「扫一次、留一份 bundle→dir 的表，十秒内复用」。几个事实支撑这个做法：
///   · 同一个 App 的容器路径在一次开机里不变（装/卸 App 才会变）；
///   · 这张表只增不减地覆盖所有容器，一次扫描能回答所有 bundle，而不是每问一次
///     为某一个 bundle 从头扫一遍；
///   · 十秒的窗口足够让「刚装完的 App」在下一拍被看见，又不会把一次拖动里的十几次
///     询问变成十几次扫描。
///
/// 锁是必须的：`AevonBandPublishNow` 在后台队列上也会问容器（卡片自己那个 App 的
/// 文件兜底）。表换出去时是**不可变快照**，并且留一代再释放（见下面 `gAevonContainerPrev`）。
static NSDictionary *gAevonContainerMap = nil;
/// 上一代快照。换表时**留一代**再释放：读的人拿到的是一个裸指针，若正好撞上
/// 另一次扫描把整张表换掉，那个指针就悬空了。留一代之后，任何在飞的读者至少还有
/// 十秒的余量 —— 而这里的读者只做「拼一个路径、立刻用」，是微秒级的事。
///
/// 不用 `autorelease` 是因为 `AevonAppMiniFlagsClearAll` 是在构造函数那一拍被调的，
/// 那条路上没有 autorelease pool（这个工程的注释里记着这个坑）。
static NSDictionary *gAevonContainerPrev = nil;
static CFAbsoluteTime gAevonContainerAt = 0;
static NSString *gAevonContainerLock = nil;
#define AEVON_CONTAINER_TTL 10.0

/// 调用方必须已经持有 `gAevonContainerLock`。
static NSDictionary *AevonContainerMapLocked(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gAevonContainerMap != nil && now - gAevonContainerAt < AEVON_CONTAINER_TTL) {
        return gAevonContainerMap;
    }
    NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
    NSFileManager *manager = [NSFileManager defaultManager];
    // 0.1.9 — 只扫 Application 那一层是不够的：Aevon(96) 的日志里
    // `win: mini flag armed com.apple.Preferences (no container)` 出现 25 次、
    // `org.coolstar.SileoStore` 24 次，而 `com.apple.DocumentsApp` 一次都没失败 ——
    // 前两个正是不住在 `Data/Application` 里的那一类（系统 App 的容器在 `Data/System`，
    // 部分带插件容器的 App 在 `PluginKitPlugin`）。容器取不到 ⇒ 文件写不进去 ⇒
    // App 侧那条闸门根本没装，用户看到的就是「点了小窗 App 还是动」。
    NSArray<NSString *> *roots = @[@"/var/mobile/Containers/Data/Application",
                                   @"/var/mobile/Containers/Data/System",
                                   @"/var/containers/Data/System",
                                   @"/var/mobile/Containers/Data/PluginKitPlugin"];
    for (NSString *one in roots) {
        for (NSString *name in [manager contentsOfDirectoryAtPath:one error:NULL]) {
            NSString *dir = [one stringByAppendingPathComponent:name];
            NSString *meta = [dir stringByAppendingPathComponent:
                              @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:meta];
            if (![info isKindOfClass:[NSDictionary class]]) continue;
            id identifier = [info objectForKey:@"MCMMetadataIdentifier"];
            // 同一 bundle 有多个容器时（插件容器），保留先扫到的那个 —— 与 0.1.9
            // 那次「逐个根目录按顺序找、找到就返回」的顺序一致。
            if ([identifier isKindOfClass:[NSString class]]
                && [map objectForKey:identifier] == nil) {
                [map setObject:dir forKey:identifier];
            }
        }
    }
    [gAevonContainerPrev release];
    gAevonContainerPrev = gAevonContainerMap;   // 已经是 +1，直接移交给「上一代」
    gAevonContainerMap = [map copy];            // 不可变快照：换出去之后没人能改它
    gAevonContainerAt = now;
    [map release];
    return gAevonContainerMap;
}

/// App 的数据容器。`LSApplicationProxy` 在 SpringBoard 里是现成的；取不到就查
/// 上面那张表（原来是逐次扫目录）。两条路都失败返回 nil。
static NSString *AevonAppContainer(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass != Nil) {
        SEL factory = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if ([proxyClass respondsToSelector:factory]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, factory, bundleID);
            if (proxy != nil) {
                SEL getter = NSSelectorFromString(@"dataContainerURL");
                if ([proxy respondsToSelector:getter]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(proxy, getter);
                    if ([url isKindOfClass:[NSURL class]]) return [(NSURL *)url path];
                }
            }
        }
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAevonContainerLock = [[NSString alloc] initWithString:@"com.aevon.container.map"];
    });
    @synchronized (gAevonContainerLock) {
        // 表在十秒后会被整张换掉；读的人在锁内取到指针就够了 —— 上一代快照在我们
        // 手里多留了一份，所以即使紧接着有人换表，这个指针也不会悬空。
        return [AevonContainerMapLocked() objectForKey:bundleID];
    }
}

/// 桥接那份日志的路径。取不到容器返回 nil —— 日志里要能区分「没写」和「没找到」。
NSString *AevonAppLogPathOf(NSString *bundleID) {
    NSString *dir = AevonAppContainer(bundleID);
    if (dir == nil) return nil;
    return [dir stringByAppendingPathComponent:@"tmp/aevon-app.log"];
}

/// 0.1.57 — App 那个进程里键盘实体顶边的 Y（屏幕坐标，本机 616），拿不到返回 0。
///
/// 为什么要在宿主这边读文件而不是让 App 自己把窗口改矮：改窗口是宿主的事
/// （`FBScene.settings.frame` 只有 SpringBoard 写得动），而「键盘顶边」这个数
/// 只有 App 进程有（`UIRemoteKeyboardWindow` 在 App 的 scene 里，不在 SpringBoard）。
/// 所以必然是一次跨进程交付。
///
/// 0.1.56 把交货点选在 `/var/mobile/Aevon.kb`，三个 App 全是
/// `kb: top publish ok=0` —— `/var/mobile` 是 `mobile:wheel 0755`，App 沙盒写不进。
/// 这一版按「App 容器 tmp → 老路径 → App 偏好域」三条路读，与 App 那侧的写法一一对应。
///
/// 容器路径做了缓存：`AevonAppContainer` 最坏要扫一遍
/// `/var/mobile/Containers/Data/Application`（几百个目录，每个读一次 metadata plist），
/// 而这个函数每次键盘弹起、每一拍心跳都会被问。
CGFloat AevonAppKbTop(NSString *bundleID) {
    if (bundleID.length == 0) return 0.0;
    static NSMutableDictionary<NSString *, NSString *> *dirs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dirs = [[NSMutableDictionary alloc] init]; });
    NSString *dir = nil;
    @synchronized (dirs) {
        dir = dirs[bundleID];
    }
    if (dir == nil) {
        dir = AevonAppContainer(bundleID);
        if (dir.length > 0) {
            @synchronized (dirs) {
                if (dirs.count < 24) [dirs setObject:dir forKey:bundleID];
            }
        }
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (dir.length > 0) [paths addObject:[dir stringByAppendingPathComponent:@"tmp/aevon-kb"]];
    [paths addObject:@"/var/mobile/Aevon.kb"];
    for (NSString *path in paths) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding error:NULL];
        if (text.length == 0) continue;
        double value = text.doubleValue;
        // 键盘顶边只可能落在「屏幕上半部偏下」：本机 616（无候选栏）/ 643（带候选栏）。
        // 小于 200 或大于 4000 的一律当没读到，免得把内容顶飞。
        if (value > 200.0 && value < 4000.0) return (CGFloat)value;
    }
    // 兜底：App 自己的偏好域（`AevonKbTop`）。cfprefsd 会慢几十毫秒，但不会失败。
    CFStringRef app = (__bridge CFStringRef)bundleID;
    CFPropertyListRef stored = CFPreferencesCopyAppValue(CFSTR("AevonKbTop"), app);
    double value = 0.0;
    if (stored != NULL) {
        if (CFGetTypeID(stored) == CFStringGetTypeID()) {
            value = [(__bridge NSString *)stored doubleValue];
        } else if (CFGetTypeID(stored) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)stored, kCFNumberDoubleType, &value);
        }
        CFRelease(stored);
    }
    if (value > 200.0 && value < 4000.0) return (CGFloat)value;
    return 0.0;
}

/// 0.1.8 — 停靠标记的落点：App 容器里的 `tmp/aevon-mini`。
///
/// 取不到容器返回 nil（此时 App 侧读不到文件 ⇒ 判成「不是小窗」，行为与旧版一致，
/// 不会把主窗的触摸吃掉）。
static NSString *AevonAppMiniFlagPath(NSString *bundleID) {
    NSString *dir = AevonAppContainer(bundleID);
    if (dir == nil) return nil;
    return [dir stringByAppendingPathComponent:@"tmp/aevon-mini"];
}

/// 0.1.8 — 标记名单。桌面进程崩掉时，App 容器里的标记不会被撤掉，那个 App
/// 从此收不到任何触摸（用户看到的是「这个 App 点不动了」）。所以写标记时顺手
/// 记一笔，下次启动按名单清干净。
static NSString *AevonMiniArmedPath(void) {
    return @"/var/mobile/Library/Logs/Aevon/mini-armed.txt";
}

/// 0.1.9 — 实时通道：Darwin 通知。
///
/// 文件通道有个绕不过去的缺口：**取不到容器就写不进去**。Aevon(96) 的日志里
/// `(no container)` 出现 49 次（设置 25 / Sileo 24），那些 App 的闸门一次都没装上，
/// 用户看到的就是「点小窗 App 还是动」。Darwin 通知是系统级的，跨进程不需要任何
/// 沙盒权限，也不依赖容器能不能找到 —— 只要那个 App 进程还活着就一定收得到。
///
/// 名字按 bundle 分开，App 侧在构造函数里注册自己那两个。
void AevonAppMiniNotify(NSString *bundleID, BOOL mini) {
    if (bundleID.length == 0) return;
    NSString *name = [NSString stringWithFormat:@"com.aevon.mini.%@.%@",
                      mini ? @"on" : @"off", bundleID];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name,
                                         NULL, NULL, true);
}

/// 0.1.8 — 写 / 删停靠标记。见 `Aevon-Bridging-Header.h` 里那段说明。
///
/// 写在 `placeDock`（降级成小窗）与 `performUndock`（升回主窗）、拆窗三处。
/// 调用频率是「一次停靠一次」，用文件而不是常驻内存，是因为跨进程只有文件这一
/// 条确定可用的路。
///
/// 0.1.9 — 返回值改成「哪几条通道真成了」：0 = 都失败，1 = 只有通知，
/// 2 = 通知 + 文件。日志靠它一眼分清「闸门到底装没装上」。
int AevonAppMiniFlagSet(NSString *bundleID, BOOL mini) {
    int mask = 0;
    if (bundleID.length == 0) return 0;
    // 通知先发：它是唯一不依赖容器的通道，也是最实时的那一条。
    AevonAppMiniNotify(bundleID, mini);
    mask |= 1;

    NSString *path = AevonAppMiniFlagPath(bundleID);
    if (path == nil) return mask;
    if (!mini) {
        if ([[NSFileManager defaultManager] removeItemAtPath:path error:NULL]) mask |= 2;
        return mask;
    }
    NSData *mark = [@"1\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (![mark writeToFile:path atomically:YES]) return mask;
    mask |= 2;
    NSString *armed = AevonMiniArmedPath();
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtPath:[armed stringByDeletingLastPathComponent]
       withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *line = [[bundleID stringByAppendingString:@"\n"]
                    dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:armed];
    if (handle == nil) {
        [line writeToFile:armed atomically:YES];
    } else {
        @try {
            [handle seekToEndOfFile];
            [handle writeData:line];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    }
    return mask;
}

/// 0.1.8 — 启动时把上一次留下的标记全撤掉。返回清掉的个数（写进启动日志）。
/// 0.1.94 — **没清掉的条目要留在名单里。**
///
/// 原来这里无论成败，最后都把 `mini-armed.txt` 整个删掉。可是「这一条没清掉」恰恰
/// 是最需要下一次开机再试的情形：容器没找到、文件被锁、App 那一刻的沙盒还没起来。
/// 名单一删，那条标记就再也没人管 —— 而它的后果是那个 App **永久**收不到落在小窗
/// 那一块的单指触摸，用户只能重装或者等我们想起来。
///
/// 现在的判据是**结果**而不是返回值：调完之后再问一次「那个文件还在不在」。还在就
/// 把它写回名单；`AevonAppMiniFlagSet` 的位掩码只说明「哪条通道发了」，不说明
/// 「App 那边真的解锁了」。
int AevonAppMiniFlagsClearAll(void) {    NSString *armed = AevonMiniArmedPath();
    NSString *text = [NSString stringWithContentsOfFile:armed
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    int count = 0;
    int stuckN = 0;
    NSMutableString *stuck = [[NSMutableString alloc] init];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        AevonAppMiniFlagSet(line, NO);
        NSString *path = AevonAppMiniFlagPath(line);
        if (path != nil && [manager fileExistsAtPath:path]) {
            [stuck appendFormat:@"%@\n", line];
            stuckN += 1;
            continue;
        }
        count += 1;
    }
    if (stuckN > 0) {
        [stuck writeToFile:armed atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        char line[96];
        snprintf(line, sizeof(line), "win: mini flag clear stuck n=%d keep", stuckN);
        AevonLogRaw(line);
    } else if (armed != nil) {
        [manager removeItemAtPath:armed error:NULL];
    }
    [stuck release];
    return count;
}

// MARK: - 0.1.31 系统界面盖着吗

/// `sharedInstanceIfExists`，取不到就是 nil。
static id AevonShared(NSString *className) {
    Class meta = NSClassFromString(className);
    if (meta == Nil) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstanceIfExists");
    if (![meta respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(meta, sel);
}

/// 只取 NSNumber 型的布尔，别的一律当 NO。`valueForKey:` 碰到没有的键会抛，
/// 所以先 `respondsToSelector:`。
static BOOL AevonTruthy(id object, NSString *key) {
    if (object == nil) return NO;
    if (![object respondsToSelector:NSSelectorFromString(key)]) return NO;
    id value = [object valueForKey:key];
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

/// 0.1.31 — 锁屏 / 通知中心 / 控制中心是不是正盖在屏幕上。
///
/// 三个单例与 `RingHost.computeSystemOverlay` 同一组判据，只是那边是 private：
/// 右缘那条带早就靠它让开了，卡片这一层一直没跟。
BOOL AevonSystemCovered(void) {
    if (AevonBoolOf(AevonShared(@"SBLockScreenManager"), @"isUILocked") == 1) return YES;
    id cover = AevonShared(@"SBCoverSheetPresentationManager");
    if (AevonTruthy(cover, @"isPresented") || AevonTruthy(cover, @"isVisible")) return YES;
    id center = AevonShared(@"SBControlCenterController");
    if (AevonTruthy(center, @"isVisible") || AevonTruthy(center, @"isPresented")) return YES;
    return NO;
}

/// 0.2.6 — 通知中心 / 控制中心 / 锁屏覆盖层在屏吗（**故意不含 `isUILocked`**）。
///
/// 与 `AevonSystemCovered` 只差第一条，而这一条差别就是全部：
/// `SBLockScreenManager.isUILocked` 在「点通知那一刻」必然为真（那次点击自带
/// `unlock=1`），拿它当「让卡片让开」的判据，每一次「通知 → 浮窗」都会先隐身一段，
/// 等真正解锁才出现 —— 那正是 0.2.2 已经判过死刑的那条路（Aevon(171)）的变形。
///
/// 而 CoverSheet 本身就是锁屏界面：锁屏时 `isPresented` 为真、解锁后为假。
/// 也就是说这一个判据已经覆盖了锁屏，不需要 `isUILocked` 参与。
///
/// 用 `AevonBoolOf`（IMP 直读）而不是 `AevonTruthy`（KVC）：后者对没有的键会抛，
/// 而这条函数是在卡片保活时钟上每 0.2 秒跑一次的 —— 一次抛异常就是杀进程。
BOOL AevonSystemPanelUp(void) {
    id cover = AevonShared(@"SBCoverSheetPresentationManager");
    if (AevonBoolOf(cover, @"isPresented") == 1 || AevonBoolOf(cover, @"isVisible") == 1) return YES;
    id center = AevonShared(@"SBControlCenterController");
    if (AevonBoolOf(center, @"isVisible") == 1 || AevonBoolOf(center, @"isPresented") == 1) return YES;
    return NO;
}

// MARK: - 0.1.93 主线程看门狗

/// 主线程最后一次应答的时刻（`CFAbsoluteTimeGetCurrent`）。
/// 后台队列读、主线程写，一个 `double` 的撕裂读最坏也只是差一拍，不影响判断。
static double AevonMainBeat = 0;
static char *AevonStallVersion = NULL;

/// 从**后台线程**直接写一行日志。
///
/// 不能借 `AevonLogRaw`/`Log.write`：那条路里有一个共享的 `DateFormatter`，
/// 它没有线程安全保证，而这里恰恰是在主线程被卡住的时候用 —— 拿它去写日志，
/// 最坏的情况是把「卡住」升级成「崩掉」，那会把线索一起带走。
/// 所以自己取时间、自己 `open/write/close`：全部是 async-signal-safe 的那一套。
static void AevonStallLog(const char *text) {
    if (text == NULL) return;
    time_t now = time(NULL);
    struct tm part;
    localtime_r(&now, &part);
    char stamp[24] = {0};
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &part);
    char line[360];
    int n = snprintf(line, sizeof(line), "%s [%s] %s\n", stamp,
                     AevonStallVersion != NULL ? AevonStallVersion : "?", text);
    if (n <= 0) return;
    int fd = open("/var/mobile/Aevon.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    size_t left = strnlen(line, sizeof(line));
    const char *cur = line;
    while (left > 0) {
        ssize_t done = write(fd, cur, left);
        if (done <= 0) break;
        cur += done;
        left -= (size_t)done;
    }
    close(fd);
}

void AevonMainStallWatchdogStart(const char *version) {
    static int started = 0;
    if (started) return;
    started = 1;
    if (version != NULL && AevonStallVersion == NULL) AevonStallVersion = strdup(version);
    AevonMainBeat = CFAbsoluteTimeGetCurrent();

    dispatch_queue_t queue = dispatch_queue_create("com.aevon.pulse.monitor", DISPATCH_QUEUE_SERIAL);
    if (queue == NULL) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (timer == NULL) return;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        double now = CFAbsoluteTimeGetCurrent();
        double gap = now - AevonMainBeat;
        // 2.5 秒：正常的一次建卡动画是 0.44 秒，一次 prefs 批量写也就几十毫秒。
        // 超过 2.5 秒没应答就不叫「慢」了，叫「卡住」。
        if (gap > 2.5) {
            char text[200];
            snprintf(text, sizeof(text), "win: main stall %.0fms (no main beat %.1fs ago)",
                     gap * 1000.0, gap);
            AevonStallLog(text);
            // 报过一次就把尺子挪到现在：卡住期间每 ~3 秒报一行，既证明它一直卡着，
            // 又能在恢复时从最后一行算出卡了多久。
            AevonMainBeat = now;
        }
        // 探针。主线程空闲时这一拍什么也不做；被卡住时它排在队列里，
        // 一恢复就落地，心跳随之复活。
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonMainBeat = CFAbsoluteTimeGetCurrent();
        });
    });
    dispatch_resume(timer);
}

// MARK: - 0.1.29 主窗四边热区 → 应用侧

/// 0.1.29 — 主窗手势环的矩形，交给 App 进程做「同一根手指也收走」。
///
/// 用户原话：「在全屏应用中操作主悬浮窗的四边手势时有概率触发全屏 app 的操作
/// （例如上滑关闭悬浮窗手势，上滑后，悬浮窗关闭，全屏 app 会向下滑动）」。
///
/// 原因和右缘呼盘（0.1.24）完全一样：backboardd 把同一根手指**分别**投递给
/// SpringBoard 和前台 App，宿主侧吞掉自己那份不影响 App 那份。
///
/// 通道照抄停靠标记那一套（`AevonAppMiniFlagSet`）：**文件存数据 + 固定名通知**。
/// 为什么不能把矩形编进通知名 —— `CFNotificationCenterAddObserver` 的 name 是
/// 精确匹配，App 侧预知不到那串数字，只能注册 `NULL`（收下系统所有 Darwin 通知）
/// 再自己过滤，那个代价不值得。文件那一条的唯一缺口是「取不到容器」，此时退化为
/// 旧行为（会透传），不会把 App 弄坏。
///
/// 文件名 `aevon-band`，内容 8 个整数：band 的 x/y/w/h，然后是卡片的 x/y/w/h。
/// 传 `CGRectNull` 删除它 —— 卡片没了而 App 还被扣着一片区域，就是「这个 App
/// 有一块点不动」，这是这条通道唯一会伤到用户的失败模式。
static CGRect AevonBandShown = {{0, 0}, {0, 0}};
static CGRect AevonBandHoleShown = {{0, 0}, {0, 0}};
static NSString *AevonBandOwner = nil;
static BOOL AevonBandLocked = NO;

/// 0.1.34 — 数据走 `CFPreferences`，通知只当铃铛（名字**固定**）。
///
/// 前两版各押了一条路，都被真机日志压住了：
///
///   · 0.1.29 用容器里的文件。V109/V110 的 `win: mini flag armed … notify only,
///     no file` 说明 `AevonAppContainer` 在目标 App 上取不到容器 —— 文件从来
///     没写进去，App 侧读到的永远是空。
///   · 0.1.31 把 8 个数编进通知名，绕开容器。但那就要求 App 侧注册 `NULL`
///     收下所有 Darwin 通知，而这条路通不通，两份日志**都分不开**（App 侧
///     读到空值就已经能让 `app: band touch at` 一条都不出现）。
///
/// 所以这一版不赌：值走偏好域（系统为跨进程传值准备的那条，不依赖容器），
/// 名字固定成 `com.aevon.band.<bundle>`（两端精确匹配，不依赖通配）。文件那条
/// 留着当兜底。App 侧新增两行证词把「通知到没到」和「值读到没」分开。
/// 0.1.93 — **这条广播必须离开主线程。**
///
/// Aevon(161) 是一份「主线程死了」的日志：12:23:38 用户按住卡片左下角开始缩放
/// （`win: resize canvas=…`、`win: raw touch grab zone=bottom-left`），12:23:39
/// 还有一条 `win: touch in=40 eat=2`，之后三十五分钟里**一行日志都没有** ——
/// 没有崩溃、没有 `boot ok`、没有触摸、连每秒一次的结算行都停了。手指一直落在
/// 屏幕上，`sendEvent` 却一次都没再被调用：主线程被卡在某个同步调用里。
///
/// 卡在哪：那次手势的第一条 `dragMove` 会走 `lockBand()` → `AevonAppBandLock`
/// → 对**十个正在运行的 App** 各写一次偏好域。每个 App 一次
/// `CFPreferencesSetAppValue` + 一次 `CFPreferencesSynchronize`，后者是**同步**
/// 打给 cfprefsd、要等它把整个域刷到磁盘才回来；卡片自己那个还多一次
/// `AevonAppContainer`（LSApplicationProxy + 目录扫描）与一次 `atomic:YES` 落盘
/// （临时文件 + rename）；最后每条还带一个 `deliverImmediately:YES` 的达尔文通知。
/// 一次广播 ≈ 20 次跨进程往返 + 1 次磁盘写，全部压在主线程上。cfprefsd 只要在
/// 忙（别家 App 正在写同一个域），这一趟就无限期等下去。
///
/// 这条纪律 `MEMORY.md` 里早写着「触摸路径上不许 CFPreferencesSynchronize」，
/// 0.1.35 加广播时漏在了外面 —— 单次看着只慢几毫秒，撞上就是整机死。
///
/// 所以：正文在主线程算好（它只读几个静态量，不花时间），真正的写盘与通知
/// 一律丢进一条串行队列。串行保证「锁」与「矩形」的先后不被调换；每条带着
/// 自己那一刻的完整快照，晚到也只是晚到，不会写错值。
static dispatch_queue_t AevonBandQueue = NULL;

static dispatch_queue_t AevonBandQueueGet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AevonBandQueue = dispatch_queue_create("com.aevon.band.publish", DISPATCH_QUEUE_SERIAL);
    });
    return AevonBandQueue;
}

/// 真正的写入。只在 `AevonBandQueue` 上跑，参数全是 C 串（块跨队列存活，
/// 这个工程按 MRC 编译，捕获 `NSString *` 的去留不由自己决定）。
static void AevonBandPublishNow(const char *bundleID, const char *body, int owner, int off) {
    @autoreleasepool {
        if (bundleID == NULL || body == NULL) return;
        NSString *bid = [NSString stringWithUTF8String:bundleID];
        NSString *text = [NSString stringWithUTF8String:body];
        if (bid.length == 0 || text == nil) return;
        CFStringRef app = (__bridge CFStringRef)bid;
        CFPreferencesSetAppValue(CFSTR("AevonBand"), (__bridge CFStringRef)text, app);
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        // 容器那条兜底只给卡片自己那个 App 做：`AevonAppContainer` 要过一次
        // LSApplicationProxy 加目录扫描，广播时对每个前台 App 都做一次就是白花。
        if (owner) {
            NSString *dir = AevonAppContainer(bid);
            if (dir != nil) {
                NSString *path = [dir stringByAppendingPathComponent:@"tmp/aevon-band"];
                if (off) {
                    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                } else {
                    [text writeToFile:path atomically:YES
                            encoding:NSUTF8StringEncoding error:NULL];
                }
            }
        }
        NSString *name = [NSString stringWithFormat:@"com.aevon.band.%@", bid];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name, NULL, NULL, true);
    }
}

static void AevonBandPublish(NSString *bundleID, BOOL owner) {
    if (bundleID.length == 0) return;
    BOOL off = CGRectIsNull(AevonBandShown) || AevonBandShown.size.width < 1
               || AevonBandShown.size.height < 1;
    // 9 个数：8 个矩形量 + 1 个「这根手指归宿主」的锁。锁只加不减一行代码，
    // 因为拖动一开始 App 那份 `touchesBegan` 已经落地了，晚了就只剩清高亮。
    NSString *body = off
        ? @"none"
        : [NSString stringWithFormat:@"%.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %d",
           AevonBandShown.origin.x, AevonBandShown.origin.y,
           AevonBandShown.size.width, AevonBandShown.size.height,
           AevonBandHoleShown.origin.x, AevonBandHoleShown.origin.y,
           AevonBandHoleShown.size.width, AevonBandHoleShown.size.height,
           AevonBandLocked ? 1 : 0];
    char *bid = strdup([bundleID UTF8String]);
    char *text = strdup([body UTF8String]);
    if (bid == NULL || text == NULL) { free(bid); free(text); return; }
    int isOwner = owner ? 1 : 0;
    int isOff = off ? 1 : 0;
    dispatch_async(AevonBandQueueGet(), ^{
        AevonBandPublishNow(bid, text, isOwner, isOff);
        free(bid);
        free(text);
    });
}

/// 0.1.35 — **这条带子必须发给「真正会收到那根手指的进程」，不是卡片里的那个。**
///
/// V111 的日志把这件事揭开了：`app: band note from host` 29 条、`app: band
/// prefs on=1 band=368x536 at 23,185` 33 条 —— 通道完全通了，矩形与宿主
/// `win: band report` 一字不差；可 `app: band touch at` 仍然是 **0**。
///
/// 也就是说：拿着正确矩形的那个进程，一次都没收到过触摸。收触摸的是**全屏
/// 那个 App** —— 用户开卡时桌面上还有一个满屏 App 在跑（这正是他每一份日志都
/// 在描述的场景：「在全屏应用中打开悬浮后…」）。backboardd 把同一根手指分别
/// 投给 SpringBoard 与**当前前台**进程，而卡片里的 App 只是「scene 被我们
/// 推到前台」，它并不在触摸投递的名单上。
///
/// 所以广播：卡片那个 + 所有正在运行的 App。写偏好域对这几个 bundle 各一次，
/// 每次只多一次 cfprefsd 往返；不这么做，这条通道在真机上就是永远 0。
static NSArray *AevonBandRunningBundles(void) {
    Class cls = NSClassFromString(@"SBApplicationController");
    if (cls == Nil) return nil;
    SEL shared = NSSelectorFromString(@"sharedInstanceIfExists");
    if (![cls respondsToSelector:shared]) return nil;
    id controller = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    if (controller == nil) return nil;
    SEL running = NSSelectorFromString(@"runningApplications");
    if (![controller respondsToSelector:running]) return nil;
    id apps = ((id (*)(id, SEL))objc_msgSend)(controller, running);
    if (apps == nil) return nil;
    NSMutableArray *out = [NSMutableArray array];
    id list = apps;
    if ([apps respondsToSelector:NSSelectorFromString(@"allObjects")]) {
        list = ((id (*)(id, SEL))objc_msgSend)(apps, NSSelectorFromString(@"allObjects"));
    }
    if (![list respondsToSelector:NSSelectorFromString(@"count")]) return out;
    SEL countSel = NSSelectorFromString(@"count");
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(list, countSel);
    if (count == 0 || count > 64) return out;
    SEL objectAt = NSSelectorFromString(@"objectAtIndex:");
    if (![list respondsToSelector:objectAt]) return out;
    SEL bundleSel = NSSelectorFromString(@"bundleIdentifier");
    for (NSUInteger i = 0; i < count; i++) {
        id app = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(list, objectAt, i);
        if (app == nil || ![app respondsToSelector:bundleSel]) continue;
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(app, bundleSel);
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) [out addObject:bid];
    }
    return out;
}

/// 上一次真写过的那一批（撤销时要逐个撤，否则留在某个 App 里就是一块死区）。
static NSMutableArray *AevonBandReached = nil;

static NSArray *AevonBandTargets(NSString *bundleID, BOOL includeReached) {
    NSMutableArray *list = [NSMutableArray array];
    if (bundleID.length > 0) [list addObject:bundleID];
    NSArray *running = AevonBandRunningBundles();
    for (NSString *bid in running) {
        if (![list containsObject:bid]) [list addObject:bid];
    }
    if (includeReached) {
        for (NSString *bid in AevonBandReached) {
            if (![list containsObject:bid]) [list addObject:bid];
        }
    }
    return list;
}

NSInteger AevonAppBandSet(NSString *bundleID, CGRect band, CGRect hole) {
    if (AevonBandOwner == nil || ![AevonBandOwner isEqualToString:bundleID ?: @""]) {
        AevonBandOwner = [bundleID copy];
    }
    AevonBandShown = band;
    AevonBandHoleShown = hole;
    // 0.1.36 — 这里**不再**把锁抹成 NO。
    //
    // 0.1.34/0.1.35 每次都写 `AevonBandLocked = NO`，而 `reportBand` 不只在
    // 抬手那一拍被调到：开卡、拆窗、几何落定都会走一遍。只要其中任何一次落在
    // 一次手势中途，写出去的正文就是 `… 0`，App 那边的锁被解开，剩下的
    // `moved` / `ended` 原样漏进去 —— 而 App 已经吞了起手，收到的是一根
    // 「半根手指」。锁只由 `AevonAppBandLock` 开关，几何上报不许动它。
    BOOL off = CGRectIsNull(band) || band.size.width < 1 || band.size.height < 1;
    // 卡片没了就没有「这一块归宿主」可言，锁也必须一起撤 —— 否则下一张开卡
    // 的上报会带着上一位留下的 `1`，App 那边会把整块区域吞到租约过期。
    if (off) AevonBandLocked = NO;
    NSArray *list = AevonBandTargets(bundleID, off);
    for (NSString *bid in list) {
        AevonBandPublish(bid, [bid isEqualToString:bundleID]);
    }
    AevonBandReached = off ? nil : [list mutableCopy];
    return (NSInteger)list.count;
}

/// 0.1.34 — 「这根手指归宿主管辖」。
///
/// 用户第 2 条的后半句：「移动悬浮窗时也会触发 APP 内的触摸操作（APP 内的选项
/// 出现选中影响，但是不会触发选中功能）」。那正是 App 收到了 `touchesBegan`
/// （高亮），而后续的 `moved` / `ended` 被宿主的拖动吃掉 —— 高亮再也等不到
/// 抬手，于是留在屏幕上。
///
/// 宿主一开拖就打开这把锁：App 侧收到即清一次高亮、并且整根吞到抬手为止。
///
/// 0.1.35 — 锁同样要广播。拿着这份状态却收不到触摸，等于没写。
void AevonAppBandLock(NSString *bundleID, BOOL locked) {
    if (AevonBandOwner != nil && bundleID.length > 0
        && ![AevonBandOwner isEqualToString:bundleID]) return;
    if (AevonBandLocked == locked) return;
    AevonBandLocked = locked;
    NSArray *list = AevonBandTargets(bundleID, YES);
    for (NSString *bid in list) {
        AevonBandPublish(bid, [bid isEqualToString:bundleID]);
    }
}

// MARK: - 0.1.29 深浅色 → 应用侧

/// 系统换了深浅色时通知 App 进程重设窗口样式。
///
/// 只传一个方向（dark / light），不传具体数值：App 侧只需要知道「现在该是哪个」。
void AevonAppStyleNotify(NSString *bundleID, BOOL dark) {
    if (bundleID.length == 0) return;
    NSString *name = [NSString stringWithFormat:@"com.aevon.style.%@.%@",
                      dark ? @"dark" : @"light", bundleID];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name,
                                         NULL, NULL, true);
}

/// 0.1.2 — 同一趟读取，但把原文交还给调用者。
///
/// Aevon(90) 的教训：抖音在自己的日志里写了 8 条 `app: hang`，宿主每 2 秒把它们
/// 读走、只数了个行数（`app log lines=2`），然后丢掉。于是「App 自己说它卡了」
/// 这条最硬的证词在宿主侧完全不可见 —— 85 秒之后才靠「场景死了」发现。
///
/// 返回 nil = 找不到容器 / 不是 UTF-8；空串 = 没有新内容。无论哪种，主日志的并入
/// 与清空都照旧发生（这一步不能因为返回值不同而分叉）。
NSString *AevonDrainAppLogText(NSString *bundleID, long cap) {
    NSString *path = AevonAppLogPathOf(bundleID);
    if (path == nil) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) return nil;
    NSString *prefix = [NSString stringWithFormat:@"applog[%@]: ", bundleID];
    NSMutableString *out = [NSMutableString string];
    NSMutableString *kept = [NSMutableString string];
    NSInteger lines = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        if (cap > 0 && lines >= cap) break;
        [out appendString:prefix];
        [out appendString:line];
        [out appendString:@"\n"];
        [kept appendString:line];
        [kept appendString:@"\n"];
        lines += 1;
    }
    if (lines == 0) {
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        return @"";
    }
    NSData *payload = [out dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open("/var/mobile/Aevon.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const char *bytes = (const char *)payload.bytes;
        size_t left = payload.length;
        while (left > 0) {
            ssize_t done = write(fd, bytes, left);
            if (done <= 0) break;
            bytes += done;
            left -= (size_t)done;
        }
        close(fd);
    }
    [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    return kept;
}

/// 把 App 侧写下的读数并进主日志。返回并入的行数：
/// -2 = 找不到容器，-3 = 内容不是 UTF-8，0 = 没有新内容（正常情形）。
/// 取完就清空，下一次开卡不会把旧的再并一遍。
NSInteger AevonDrainAppLog(NSString *bundleID, long cap) {
    NSString *text = AevonDrainAppLogText(bundleID, cap);
    if (text == nil) return AevonAppLogPathOf(bundleID) == nil ? -2 : -3;
    if (text.length == 0) return 0;
    NSInteger lines = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) lines += 1;
    }
    return lines;
}



/// 0.1.99 — 同上。清通知那两件（取 dispatcher、打能力地图）定义在下面几千行处，
/// 而开机取证要在这里排期。


// MARK: - 0.1.87 激活入口观察器（只读，四方法同形）
//
// 0.1.86 的真机普查（Aevon(154)，19:27:53）把真名一次答完了：
//
//   surf: chain SBMainWorkspace > SBWorkspace > NSObject
//   surf: SBMainWorkspace~activ n=16/170
//     _handleOpenApplicationRequest:options:activationSettings:origin:withResult:              {v56@0:8@16@24@32@40@?48}
//     _handleUntrustedOpenRequestForApplication:options:...                                     {v56@0:8@16@24@32@40@?48}
//     _handleTrustedOpenRequestForApplication:options:...                                       {v56@0:8@16@24@32@40@?48}
//     _handleUserActionRequest:options:activationSettings:origin:withResult:                    {v56@0:8@16@24@32@40@?48}
//
// ⛔ 0.1.87 当年在这里写的是「母本那个 `_activateBundleID:...` 确实不存在」。
//    **这条结论是错的，0.2.87 推翻。**
//
// Aevon(219) 的全类普查（99452 个类 × 自有方法表）读到的是：
//
//   carrier: own _activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:
//            n=1 | FBSystemService v68@0:8@16@24B32@36@44@52@?60
//
// 它**存在**，只是不在 `SBMainWorkspace` 上，而在 **`FBSystemService`** 上；
// 参数不是 5 个而是 7 个：bundleID(@16) / requestID(@24) / isTrusted(B32) /
// **options(@36)** / source(@44) / originalSource(@52) / withResult(@?60)。
// 母本二进制里这条命中 2 次，`FBSystemService` 字符串命中 14 次，还有一个
// `FBSystemServiceHook` 钩子类 —— 三处独立证据指向同一格。
//
// 当年只在 SBWorkspace 那一支里找，找到的是另一族「按信任分叉」的入口，于是把
// 「我这一支没有」误记成「这台机器没有」。这正是「探针找不到 ≠ 不存在」的样本。
//
// 两个层要分开：`SBMainWorkspace` 这四条是「SpringBoard 收到打开请求之后怎么办」，
// `FBSystemService` 那条是「FrontBoard 怎么把一个 App 激活起来」。
// **URL 装在后者的 options 里**，这就是母版从不自己投 URL 的原因 —— 系统会投。
//
// 为什么四条一起装：现在还说不准点通知走哪一条。`_handleOpenApplicationRequest:` 像
// 总入口，trusted / untrusted 像按信任分叉，`_handleUserActionRequest:` 像「用户动作」
// （URL 与通知回应都属于用户动作）。分开装要装四次机，而四条形状相同、替身相同，
// 一次装四个、每条各写一行命中，一份日志就能答「到底走哪条」。
//
// 安全设计这次比 0.1.85 更硬，因为名字不是猜的：
//   闸一 · 存在性 四条逐个查，缺哪条记哪条，不影响其余；
//   闸二 · 形状   **逐字节等于** `v56@0:8@16@24@32@40@?48` 才装。这一版没有任何 ABI
//                 推算：字符串不等就是不装，并把真实编码写进日志，下一版按它改；
//   闸三 · 归属   `class_copyMethodList` 确认是 SBMainWorkspace 自己实现的；
//   闸四 · 闩     Swift 侧的 `notify.armed`（180 秒）；
//   闸五 · 预算   四条合计 32 行、每条 10 行，用满就闭嘴（钩子留着，不再取证）；
//   闸六 · 延迟   装载后 3 秒。
// 替身只做三件事：读一遍参数 → 原样转发 → 异步落盘。不改参数、不拦调用、不改返回值。
//
// 判据一句话：`notify: hit op=<哪条>` 的 op 就是分支名；b / src / act / url 就是母本
// 当年那三个字段在这台机器上的真值；req / opt / set / org 是四个参数的真实类名 ——
// 它们决定下一版从哪个对象里取「这是不是一次通知点击」。
// 四条一次都不命中，才轮到通知栈（`NCNotificationDispatcher -destination:executeAction:
// forNotificationRequest:...`，0.1.86 已确认存在）。

/// 四条共用的参数编码，逐字取自真机普查。写成宏是因为它同时在两道闸（比较）和
/// 日志（判据）里出现 —— 三处必须逐字一致。
#define AEVON_OPEN_SHAPE "v56@0:8@16@24@32@40@?48"




/// 原实现。**只在换 IMP 的前一行赋值**，赋不上就不换 —— 一个拿不到原实现的
/// 替身会把整条 App 激活吞掉，那不是「观察」，是让手机打不开应用。

/// 注册时的 SEL 地址。替身靠它反查「这一拍是四条里的哪条」——比在热路径上
/// `sel_getName` 再比字符串便宜得多。


/// `options` 的键名只在前三拍打。母本用的是 `__PayloadOptions` / `__Actions` 两个
/// 私有键，而它们出自 iOS 15/16 —— 键名一变，字段就全是 nil，而那与「没有通知
/// 点击」在日志里长得一模一样。这一行是唯一能把两者分开的东西。

// MARK: - 0.1.88 分流：通知点击不再全屏打开
//
// 0.1.87 的真机日志（Aevon(155)，19:37:47）把三件事一次答完了：
//
//   notify: hit op=open    b=- src=- act=#UINotificationResponseAction n=1 url=- req=com.tencent.mqq …
//   notify: hit op=open    … keys=__Actions,__PromptUnlockDevice,__LaunchOrigin,__LaunchImage,__UnlockDevice
//   notify: hit op=trusted b=- src=- act=#UINotificationResponseAction n=1 url=- req=com.tencent.mqq …
//
//   ① 点通知确实走 `_handleOpenApplicationRequest:`，再进 `_handleTrustedOpenRequestForApplication:`；
//   ② `act=#UINotificationResponseAction` 就是「这是通知点击」的判据 —— 同一天从
//      sharingd 分享面板打开 Sileo 也是这两条，但 `act=- n=0`，两者在日志里分得开；
//   ③ `req` **本身就是 bundle id 字符串**（`com.tencent.mqq`），不是带 `application`
//      的对象 —— 0.1.87 的 `b=-` 就是按对象取值取空了，不是没有值。
//
// 有了这三条，「通知 → 浮窗」的识别部分不需要再取证。剩下的是动作：SpringBoard
// 收到这个请求会自己把 App 全屏推上前台，所以要么跟着它走，要么**不交给它**。
// 这一版选后者 —— 和母本同一条思路（它 hook 的也是这一层，接管之后自己排布局），
// 只是 Aevon 的布局早就有了（`openCard` / `FloatHost`），不必再写一套。
//
// 于是替身第一次有了「不原样转发」的分支。它被四道闸夹住：
//
//   闸一 · 开关      `notify.off` 在 ⇒ 一个字节都不改，和 0.1.87 完全一样；
//   闸二 · 判据      `__Actions.firstObject` 的类名必须含 `NotificationResponseAction`。
//                    分享面板、URL、点图标都不含，一律照旧全屏；
//   闸三 · 目标      bundle 必须是从 `request` 直接取到的非空串，且不是 SpringBoard 自己。
//
// 0.2.1 — 原来的「闸四 · 兜底」整段删掉了：吞掉之后 2.5 秒查一次卡片、没起来就把原
// 实现补调一次。Aevon(169) 证明它会**自己喂自己** —— 补调会让原实现再走一遍同样被
// 接管的入口，于是又分流、又建卡、又失败、又补调，每轮还带一次 10 秒整的同步 XPC。
// 母版 Stheno 没有这一条：它只在「失败/排除表命中」时回落一次全屏，不回灌原实现。
//
// 现在最坏的结果是「卡片没建起来，这一下没有反应」，而不是「整机卡住等它自己恢复」。
// 全屏兜底只剩 `openCard` 那条 `ring: card route declined`，一次点击最多一次。

/// 上一次分流的时刻与目标。同一次点击会连着走 open → trusted 两条，第一条被吞掉
/// 之后第二条通常不会再来（链条在替身里就断了）；真来了也不能再开一次卡片。

/// 分流频率上限。真机上「点了通知却什么都没有」是最难受的失败，所以宁可少分几次。
///
/// 0.1.93 — 这里原来是「**一次开机**最多 24 次」。Aevon(161) 把它照出来了：
/// 十二小时里 n 一路加到最后一次 `n=23`（12:07:08），再点一条就是第 24 次，
/// 之后整台机器上所有通知、所有分享都会走 `why=cap` 原样转发 —— 浮窗再也打不开，
/// 而用户看不出任何原因，只能重启。上限的用意是「万一分流逻辑坏了，别一直吞」，
/// 而「坏」是**当下**的事，不是「今天失败过 24 次」的事。
///
/// 所以换成滑动窗口：24 次 / 10 分钟。窗口一过自动归零，不需要重启。
///
/// 0.2.77 — **这个形状本身错了，24 次也是错的。**
///
/// Aevon(211) 的读数：11:57:05 起三分钟里用户正常开了 24 次卡 —— Safari 四次、
/// Sileo 一次、QQ 分享一次、微信登录两次、QQ 登录两次、TCL 登录两次 ——
/// 12:00:17 走到支付那一步正好是第 25 次，于是
///
///     notify: pass b=- op=untrusted why=cap src=com.chinaunicom.mobilebusiness
///     notify: pass b=- op=user      why=cap src=com.alipay.iphoneclient
///
/// 联通与支付宝整屏，之后每一次打开都 `why=cap`，要等窗口滑过去才恢复。
/// **支付小窗是被自己的保险丝掐掉的**，不是支付这条链有 bug。
///
/// 保险丝要拦的从来不是「多」，是「同一条反复」：我们的分流自己又触发一次打开，
/// 再被自己分流。那件事的形状是**同一个 bundle 在几百毫秒里连着来**；而十分钟里
/// 来了二十几个**不同**的 App，那是一台手机的正常用法，不是故障。
///
/// 所以换两把尺：
///   · 每个 bundle 一条 3 秒 / 6 次的连击计数 —— 只有这一种算「坏了」；
///   · 全局上限抬到 60 次 / 60 秒 —— 真跑飞了一秒一次也够撞上，正常用撞不到。
#define AEVON_DIVERT_MAX 60
#define AEVON_DIVERT_WINDOW 60.0

#define AEVON_LOOP_SLOTS 4
#define AEVON_LOOP_MAX 6
#define AEVON_LOOP_WINDOW 3.0

typedef struct {
    char bundle[56];
    double at;
    int streak;
} AevonLoopSlot;



// MARK: - 浮窗黑名单（0.2.4）

/// 名单里的 App **不进浮窗，也不拦它的打开请求** —— 一切按系统原生走。
///
/// 这是母版与四家同行唯一一致的产品化逃生门：TrollOpen 的
/// `TOBJJumpSplitExcludedApplications`、Mango 的 `urlOpenInSplit`、Myrtle 的
/// `URLJUMPBLACKLIST`，都带一张名单，出问题的 App 进名单就回原生。
/// Aevon 到 0.2.3 为止一张都没有 —— 于是任何一个在我们这条路上走不通的 App
/// （Aevon(173) 的高德）都只能「什么都不发生」，用户没有任何自救手段。
///
/// 读两个键，字符串优先（面板的文本框写 `windowBlacklistText`，手改 plist 的
/// 写 `windowBlacklist` 数组）：
///
///   `windowBlacklistText` — 逗号 / 空格 / 换行分隔的 bundle id
///   `windowBlacklist`     — 字符串数组
///
/// **只在一次打开请求上读一次**，不进逐帧路径：`CFPreferencesCopyAppValue` 是一次
/// IPC 往返，Aevon(90) 那条「每次点击都卡」的教训就是把它放进了触摸路径。
/// 判据按 `strstr` 做包含匹配，不是逐字相等 —— 名单里写 `com.autonavi` 就该把
/// `com.autonavi.amap` 一起盖住，那是使用者写字时的自然预期。
static BOOL AevonWindowBlacklisted(const char *bundle) {
    if (bundle == NULL || bundle[0] == '\0') return NO;
    CFStringRef domain = CFSTR("com.aevon");

    CFPropertyListRef list = CFPreferencesCopyAppValue(CFSTR("windowBlacklist"), domain);
    if (list != NULL) {
        BOOL hit = NO;
        CFTypeID kind = CFGetTypeID(list);
        if (kind == CFArrayGetTypeID()) {
            CFArrayRef array = (CFArrayRef)list;
            CFIndex count = CFArrayGetCount(array);
            for (CFIndex i = 0; i < count && !hit; i++) {
                CFTypeRef item = CFArrayGetValueAtIndex(array, i);
                if (item == NULL || CFGetTypeID(item) != CFStringGetTypeID()) continue;
                const char *text = [(__bridge NSString *)item UTF8String];
                if (text != NULL && text[0] != '\0' && strstr(bundle, text) != NULL) hit = YES;
            }
        } else if (kind == CFStringGetTypeID()) {
            const char *text = [(__bridge NSString *)list UTF8String];
            if (text != NULL && strstr(text, bundle) != NULL) hit = YES;
        }
        CFRelease(list);
        if (hit) return YES;
    }

    CFPropertyListRef text = CFPreferencesCopyAppValue(CFSTR("windowBlacklistText"), domain);
    if (text != NULL) {
        BOOL hit = NO;
        if (CFGetTypeID(text) == CFStringGetTypeID()) {
            const char *raw = [(__bridge NSString *)text UTF8String];
            if (raw != NULL && strstr(raw, bundle) != NULL) hit = YES;
        }
        CFRelease(text);
        if (hit) return YES;
    }
    return NO;
}

/// 0.2.39 — 分享黑名单整块删除（用户要求：微信的文件分享也进卡片）。
///
/// 0.2.10 加这张表，是因为 Aevon(179) 里微信分享进卡片后两次崩在
/// `-[MBPublicService provideFileSystem]: unrecognized selector`（`step=5` 落在
/// 我们 App 侧 sheet 钩子所在的函数）。当时它还托管在**别人的 scene** 上；现在
/// 承载已换成自建 scene，崩溃的现场条件不在了，名单的临时使命结束。
///
/// 一并删掉的还有 `AevonBlacklistDrain`（2s / 7s 去目标容器捞 `aevon-app.log`）：
/// 它唯一的调用点就是下面那条黑名单分支。微信的日志现在和别的 App 一样，在
/// 开卡 / 关卡时随 `applog[com.tencent.xin]` 进主日志。
///
/// 若同形状的崩溃再次出现：把 `com.tencent.xin` 的判断加回 `AevonOpenDecide`
///（`kind == "share"` 之后的 `return 0`）即可，不需要恢复这张表。

/// Swift 侧的同一张名单。圆盘点图标那条路不经过 `AevonOpenDecide`（它没有
/// 「打开请求」可判），所以名单必须能单独问一次；否则名单里的 App 从圆盘点
/// 仍然会被塞进卡片，而名单的语义是「这个 App 别碰我的路」。
BOOL AevonBlacklistedBundle(NSString *bundle) {
    if (bundle == nil || [bundle length] == 0) return NO;
    const char *text = [bundle UTF8String];
    if (text == NULL) return NO;
    return AevonWindowBlacklisted(text);
}
// ============================================================================
// 0.4.0 — 这份文件到这里就结束了。
//
// 0.3.61 时它是 18,189 行，后面跟着 URL 主干（`AevonRouteDecide` / `AevonDeckStart`
// / `AevonCardSettle`）、通知链、分享转发、授权族、以及十几组只读普查。这些全部
// 随 URL 主线一起删除，一个字不留。现在这里只剩浮窗本身需要的那几样：
//
//   · scene / presenter 的**查询**（`AevonSceneManager` / `AevonLiveSceneForBundle` / …）
//   · 卡片承载的**写路**（`AevonWriteFrame` / `AevonPushSceneFrame` / `AevonWriteDisplay`）
//   · 键盘上沿与遮挡（`AevonAppKbTop` / `AevonSystemCovered` / `AevonSystemPanelUp`）
//   · 触摸注入与主线程看门狗（`AevonSendEventReplacement` / `AevonMainStallWatchdogStart`）
//   · 黑名单与设置读写（`AevonWindowBlacklisted` / `AevonBlacklistedBundle` / band）
//
// 钩子只剩两个：`_scene:interceptUpdateWithNewSettings:`（卡片尺寸）与
// `__setDeactivationReasons:withReason:`（让路时那一拍）。装配入口 `AevonHookInstall`，
// 自检 `AevonProbeSelfTest` —— 两者都不碰任何 `openURL` / 打开请求。
// ============================================================================
