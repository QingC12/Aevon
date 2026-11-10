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

// 0.1.40 — 这两个符号由 Swift 侧（`Log.swift` / `SceneProbe.swift`）用
// `@_cdecl` 导出。Swift 的 bridging header 不会进 `.m`，所以在这里各写一行
// `extern`：签名必须与那两处逐字一致（`const char *`，可空）。
extern void AevonLogRaw(const char *line);
extern void AevonOpenFromNotification(const char *bundleID);
// 0.2.46 — 跳过 openCard 的 home-first，直接建卡。
// 分享那条路先把来源 App 顶回前台，目标已经不占全屏，不需要再按一次 Home。
extern void AevonOpenCardDirect(const char *bundleID);
// 0.1.88 — 两条只读查询，都由 Swift 侧 `@_cdecl` 导出：
//   AevonActivateSwitchOff()  → 1 表示 `notify.off` 在，一个字节都不许改行为；
//   AevonCardIsUpFor(bundle)  → 1 表示这个 App 已经在主悬浮窗/停靠小窗里。
// 后者是**唯一的成功判据**：`openCard` 把 App 拉起来之后场景是异步出现的，
// 用时间猜「起来没起来」会在真机上错判（0.1.84 已经在键盘上付过一次学费）。
extern int AevonActivateSwitchOff(void);
extern int AevonCardIsUpFor(const char *bundle);
// 0.1.91 — 「卡在路上」。`openCard` 一接手就答 1，卡片真正占上槽之前它比
// `AevonCardIsUpFor` 早开口。收面板要靠这一位把「在等卡」那半秒让开。
extern int AevonCardIsComingFor(const char *bundle);
// 0.1.92 — 分享面板那条路的独立开关（`share.off`）。`notify.off` 仍然是总闸：
// 两个文件任一存在，分享一律不接管。
extern int AevonShareSwitchOff(void);
// 0.2.36 — 「系统要普通全屏打开这个 App 了，把正在承载它的卡片让开」。
// 只在主线程有效（`closeCard` 动 scene / window）；返回 1 = 真的拆了一张卡。
extern int AevonCardYieldForFullscreen(const char *bundle);
// 0.2.59 — 「用完就收」：授权交接完成之后把那张卡正常关掉（不是让路）。
// 返回 1 = 真的关了一张卡；0 = 那个 bundle 现在没有卡，调用方什么都不做。
extern int AevonCardCloseFor(const char *bundle);

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

/// 0.2.9 — 「这一拍目标 App 在系统眼里是不是前台」。**只调 BOOL getter**，每次都先问存在性。
///
/// 这是唯一能证明因果的读数：分享那一刻 `forward` 之前 `front=0`、之后 `front=1`，
/// 就把「全屏是那次转发拉起来的」从推断变成实测（Aevon(177) 里那条对照实验只是
/// 「通知打开没有全屏」，还不是同一 App 的前后对比）。
/// 选择子不存在时打 -1，绝不拿 `perform` 去读标量（那条路 0.1.38 崩过五次）。
static void AevonAppPose(const char *phase, id request) {
    static int notes = 0;
    if (notes >= 24) return;
    NSString *bid = nil;
    if ([request isKindOfClass:[NSString class]]) {
        bid = (NSString *)request;
    } else if (request != nil) {
        id shown = nil;
        @try {
            SEL sel = sel_registerName("bundleIdentifier");
            if ([request respondsToSelector:sel]) {
                shown = ((id (*)(id, SEL))objc_msgSend)(request, sel);
            }
        } @catch (__unused NSException *exception) { shown = nil; }
        if ([shown isKindOfClass:[NSString class]]) bid = shown;
    }
    if (bid.length == 0) return;
    notes += 1;
    @try {
        id app = AevonAppObject(bid);
        int front = -1, back = -1, running = -1, pid = -2;
        if (app != nil) {
            SEL f = sel_registerName("isFrontmost");
            if ([app respondsToSelector:f]) {
                front = ((BOOL (*)(id, SEL))objc_msgSend)(app, f) ? 1 : 0;
            }
            SEL b = sel_registerName("isBackgrounded");
            if ([app respondsToSelector:b]) {
                back = ((BOOL (*)(id, SEL))objc_msgSend)(app, b) ? 1 : 0;
            }
            SEL r = sel_registerName("isRunning");
            if ([app respondsToSelector:r]) {
                running = ((BOOL (*)(id, SEL))objc_msgSend)(app, r) ? 1 : 0;
            }
            SEL p = sel_registerName("pid");
            if ([app respondsToSelector:p]) {
                pid = ((int (*)(id, SEL))objc_msgSend)(app, p);
            }
        }
        AevonLogRaw([[NSString stringWithFormat:@"win: pose b=%@ phase=%s front=%d bg=%d run=%d pid=%d",
                      bid, phase != NULL ? phase : "-", front, back, running, pid] UTF8String]);
    } @catch (__unused NSException *exception) {
        AevonLogRaw("win: pose threw");
    }
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

/// `- (void)name:(BOOL)value`. 1 when it ran, 0 when the object does not answer
/// it. Reading the answer back is the caller's job with `AevonBoolOf`: a setter
/// that ran and a setter that stored the other value look the same from here.
NSInteger AevonCallSetBool(id object, NSString *name, BOOL value) {
    if (object == nil || name == nil) return 0;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return 0;
    void (*call)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    call(object, sel, value);
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
static CGRect AevonOwnFrame = { {0, 0}, {0, 0} };
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
static int AevonOwnGateRan = 0;
static NSInteger AevonOwnGateMiss = -1;
static int AevonOwnStartNotes = 0;
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

/// 自建 scene 需要的最小类面。`meta=1` 是类方法。
///
/// 名字全部来自真机普查（0.2.11 的 `surf: scn host` 已经把
/// `createSceneWithDefinition:initialParameters:` 钉在 `FBSceneManager` 上，
/// 形状 `i{@32@0:8@16@24}`），不是从字符串表里猜的。
typedef struct {
    const char *cls;
    const char *sel;
    int meta;
} AevonOwnNeed;

static const AevonOwnNeed AevonOwnNeeds[] = {
    {"RBSProcessIdentity", "identityForEmbeddedApplicationIdentifier:", 1},
    {"RBSProcessPredicate", "predicateMatchingIdentity:", 1},
    {"RBSProcessHandle", "handleForPredicate:error:", 1},
    {"RBSProcessHandle", "auditToken", 0},
    {"FBProcessManager", "sharedInstance", 1},
    {"FBProcessManager", "launchProcessWithContext:", 0},
    {"FBProcessManager", "registerProcessForAuditToken:", 0},
    {"FBMutableProcessExecutionContext", "setIdentity:", 0},
    {"FBMutableProcessExecutionContext", "setEnvironment:", 0},
    {"FBMutableProcessExecutionContext", "setLaunchIntent:", 0},
    {"FBApplicationProcessLaunchTransaction",
        "initWithProcessIdentity:executionContextProvider:", 0},
    {"FBApplicationProcessLaunchTransaction", "setCompletionBlock:", 0},
    {"FBApplicationProcessLaunchTransaction", "begin", 0},
    {"FBSSceneIdentity", "identityForIdentifier:", 1},
    {"FBSSceneClientIdentity", "identityForProcessIdentity:", 1},
    {"FBSMutableSceneDefinition", "definition", 1},
    {"FBSMutableSceneDefinition", "setIdentity:", 0},
    {"FBSMutableSceneDefinition", "setClientIdentity:", 0},
    {"FBSMutableSceneDefinition", "setSpecification:", 0},
    {"UIApplicationSceneSpecification", "specification", 1},
    {"FBSMutableSceneParameters", "parametersForSpecification:", 1},
    {"FBSMutableSceneParameters", "setSettings:", 0},
    {"FBSMutableSceneParameters", "setClientSettings:", 0},
    {"UIMutableApplicationSceneSettings", "setDisplayConfiguration:", 0},
    {"UIMutableApplicationSceneSettings", "setForeground:", 0},
    {"UIMutableApplicationSceneSettings", "setFrame:", 0},
    {"UIMutableApplicationSceneSettings", "setLevel:", 0},
    {"UIMutableApplicationSceneSettings", "setInterfaceOrientation:", 0},
    {"UIMutableApplicationSceneSettings", "setPersistenceIdentifier:", 0},
    {"UIMutableApplicationSceneSettings", "setSafeAreaInsetsPortrait:", 0},
    {"UIMutableApplicationSceneClientSettings", "setInterfaceOrientation:", 0},
    {"FBSceneManager", "sharedInstance", 1},
    {"FBSceneManager", "createSceneWithDefinition:initialParameters:", 0},
    {"FBSceneManager", "destroyScene:withTransitionContext:", 0},
    {"FBScene", "uiPresentationManager", 0},
};

/// 只问不调：返回缺失的条数，0 表示整条路都接得上。
///
/// 「问」是免费的：`respondsToSelector:` 与 `class_getInstanceMethod` 都不会
/// 执行任何东西。这一条路真正的风险全在「调」上，所以先把问的那一半做满。
NSInteger AevonOwnGate(void) {
    if (AevonOwnGateRan) return AevonOwnGateMiss;
    AevonOwnGateRan = 1;
    NSInteger miss = 0;
    int total = (int)(sizeof(AevonOwnNeeds) / sizeof(AevonOwnNeeds[0]));
    for (int i = 0; i < total; i++) {
        Class cls = NSClassFromString([NSString stringWithUTF8String:AevonOwnNeeds[i].cls]);
        SEL sel = sel_registerName(AevonOwnNeeds[i].sel);
        BOOL there = NO;
        if (cls != Nil) {
            there = AevonOwnNeeds[i].meta ? [cls respondsToSelector:sel]
                                         : (class_getInstanceMethod(cls, sel) != NULL);
        }
        if (!there) {
            miss++;
            AevonOwnLog(@"win: own miss %s%s %s",
                        cls == Nil ? "class " : "", AevonOwnNeeds[i].cls,
                        AevonOwnNeeds[i].sel);
        }
    }
    AevonOwnGateMiss = miss;
    // 汇总行走 `AevonLogRaw`，不占预算：它是这条路最重要的一行（0 才敢往下调），
    // 被自己的明细挤掉就等于这一版什么都没回答。（`AevonLogRaw` 收的是 C 字符串，
    // 不是 NSString —— 这一句原本写成了直接传对象。）
    NSString *summary = [[NSString alloc] initWithFormat:@"win: own gate need=%d miss=%ld",
                         total, (long)miss];
    AevonLogRaw([summary UTF8String]);
    [summary release];
    return miss;
}

/// 一个带签名调用的外壳：`-auditToken` 返回 32 字节结构体，arm64 上是间接
/// 返回（stret）。`objc_msgSend` 用错 cast 会直接把返回值当成指针，正是 0.1.38
/// 那五次安全模式的形状；`NSInvocation` 按 `NSMethodSignature` 处理，不存在
/// 「猜 ABI」这一步。
static NSMethodSignature *AevonOwnSignature(id target, SEL sel) {
    if (target == nil) return nil;
    @try {
        return [target methodSignatureForSelector:sel];
    } @catch (NSException *e) {
        AevonOwnLog(@"win: own sig throw %s %s", sel_getName(sel),
                    e.reason != nil ? [e.reason UTF8String] : "-");
        return nil;
    }
}

/// `-registerProcessForAuditToken:` —— 参数是那个 32 字节结构体，只能这么传。
static NSInteger AevonOwnRegisterProcess(id manager, AevonAuditToken token) {
    SEL sel = sel_registerName("registerProcessForAuditToken:");
    NSMethodSignature *sig = AevonOwnSignature(manager, sel);
    if (sig == nil || sig.numberOfArguments < 3) return 0;
    @try {
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        [call setTarget:manager];
        [call setSelector:sel];
        // setArgument 自己会按签名拷贝这段内存，栈上的 token 活过这一句就够了。
        [call setArgument:&token atIndex:2];
        [call invoke];
        return 1;
    } @catch (NSException *e) {
        AevonOwnLog(@"win: own reg throw %s",
                    e.reason != nil ? [e.reason UTF8String] : "-");
        return 0;
    }
}

/// 取 `-auditToken`。返回 1 表示这一格填上了。
static NSInteger AevonOwnAuditToken(id handle, AevonAuditToken *out) {
    if (handle == nil || out == NULL) return 0;
    SEL sel = sel_registerName("auditToken");
    NSMethodSignature *sig = AevonOwnSignature(handle, sel);
    if (sig == nil || sig.methodReturnLength != sizeof(AevonAuditToken)) {
        if (sig != nil) {
            AevonOwnLog(@"win: own token size=%lu want=%lu",
                        (unsigned long)sig.methodReturnLength,
                        (unsigned long)sizeof(AevonAuditToken));
        }
        return 0;
    }
    @try {
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:sig];
        [call setTarget:handle];
        [call setSelector:sel];
        [call invoke];
        memset(out, 0, sizeof(AevonAuditToken));
        [call getReturnValue:out];
        return 1;
    } @catch (NSException *e) {
        AevonOwnLog(@"win: own token throw %s",
                    e.reason != nil ? [e.reason UTF8String] : "-");
        return 0;
    }
}

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

/// 0.2.46 — 「这台机器上显示覆盖做不做得成」，建 scene 之前就能问出来。
///
/// 只问不调：`respondsToSelector:` 与 `class_getInstanceMethod` 不执行任何东西。
/// 唯一一次实际开销是兜底那一路的 `mutableCopy`（要真拷一份才知道副本可不可变），
/// 结果缓存 —— 一台机器一辈子问一次。
///
/// 这一位现在的用途只有一个：日志里回答「为什么这台机器上 App 还是按 932 排」。
/// 决策仍然由 `AevonOwnDisplay` 的实际返回值决定（能力 ≠ 结果）。
static int AevonOwnDisplayCap = -1;
static BOOL AevonOwnDisplayCapable(void) {
    if (AevonOwnDisplayCap >= 0) return AevonOwnDisplayCap != 0;
    AevonOwnDisplayCap = 0;
    id screen = [UIScreen mainScreen];
    SEL getter = sel_registerName("displayConfiguration");
    if (screen != nil && [screen respondsToSelector:getter]) {
        id base = ((id (*)(id, SEL))objc_msgSend)(screen, getter);
        if (base != nil) {
            SEL over = sel_registerName("copyWithOverrideBounds:");
            if ([base respondsToSelector:over]) {
                Method method = class_getInstanceMethod(object_getClass(base), over);
                const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
                if (method != NULL && encoding != NULL &&
                    method_getNumberOfArguments(method) == 3 &&
                    strstr(encoding, "CGRect") != NULL) {
                    AevonOwnDisplayCap = 1;
                }
            }
            if (AevonOwnDisplayCap == 0) {
                id probe = nil;
                @try {
                    probe = [[base mutableCopy] autorelease];
                } @catch (NSException *exception) {
                    probe = nil;
                }
                if (probe != nil &&
                    [probe respondsToSelector:sel_registerName("setBounds:")]) {
                    AevonOwnDisplayCap = 1;
                }
            }
        }
    }
    AevonOwnDisplayLog(@"win: own display cap=%d", AevonOwnDisplayCap);
    return AevonOwnDisplayCap != 0;
}

/// 0.2.46 — 只问不调：`FBUpdateSceneTransaction` 在这台机器上到底长什么样。
///
/// 对比报告第六节第 3 条建议「改尺寸走 `FBUpdateSceneTransaction`」。这一版先用
/// **回执**落地同一个目的（见 `AevonCallSettingsAck` 上面那段为什么不另造事务），
/// 但「这个类在不在、叫什么」是下一版要不要真用的唯一前提，而问一次是免费的。
///
/// 三行日志，一台机器一次：`class=yes/nil` + 三个候选初始化器的 `meta/inst/enc`。
/// 全是 `respondsToSelector:` 与 `method_getTypeEncoding`，没有任何一次调用。
static void AevonOwnTxnProbe(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    Class cls = NSClassFromString(@"FBUpdateSceneTransaction");
    if (cls == Nil) {
        AevonOwnDisplayLog(@"win: own txn class=nil");
        return;
    }
    AevonOwnDisplayLog(@"win: own txn class=yes");
    static const char *names[] = {
        "transactionWithSceneID:settings:transitionContext:",
        "initWithSceneID:settings:transitionContext:",
        "transactionWithScene:settings:transitionContext:",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        SEL sel = sel_registerName(names[i]);
        BOOL meta = [cls respondsToSelector:sel];
        Method inst = class_getInstanceMethod(cls, sel);
        const char *encoding = inst != NULL ? method_getTypeEncoding(inst) : NULL;
        AevonOwnDisplayLog(@"win: own txn %s meta=%d inst=%d enc=%s", names[i],
                           meta ? 1 : 0, inst != NULL ? 1 : 0,
                           encoding != NULL ? encoding : "-");
    }
}

/// 0.2.15 — 「这块屏幕」必须和 frame 一样大。
///
/// 0.2.13/0.2.14 把 scene 的 frame 设成画布 430x717，却把真机的
/// `displayConfiguration`（430x932）原样塞了进去 ⇒ App 里 `UIScreen` 是 932、
/// 窗口是 717。按 scene 排版的 App（QQ / 微信 / 抖音）看不出来，按 `UIScreen`
/// 排版的那个就不行 —— Aevon(185) 高德：
///   `app: geom early scene=430x717 win=430x932 root=430x932`
/// 这就是用户说的「悬浮窗里的尺寸错乱」。
///
/// 做法：拷一份真机配置，把 `bounds` 改成画布大小，`scale` 等其余字段不动
/// （像素尺寸由 scale 推，不另设 —— 名字拿不准的一律不调，宁可少设一项）。
/// `setBounds:` 不存在就用回真机配置，也就是 0.2.14 的行为，不多赌一步。
static id AevonOwnDisplay(CGRect frame) {
    id screen = [UIScreen mainScreen];
    SEL getter = sel_registerName("displayConfiguration");
    if (screen == nil || ![screen respondsToSelector:getter]) return nil;
    id base = ((id (*)(id, SEL))objc_msgSend)(screen, getter);
    if (base == nil) return nil;
    SEL boundsSel = sel_registerName("bounds");
    if (![base respondsToSelector:boundsSel]) return base;
    CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(base, boundsSel);
    if (CGRectEqualToRect(now, frame)) {
        AevonOwnDisplayLog(@"win: own display same %.0fx%.0f",
                           now.size.width, now.size.height);
        return base;
    }

    // 0.2.46 — 主路：派生一份改了 bounds 的配置。
    //
    // 这一条放在最前面，不是为了少写几行，是因为它**不依赖副本可变**：
    //   · 老路赌 `mutableCopy` 出来的对象有 `setBounds:`，真机上赌输过一半；
    //   · 这条路由配置自己派生，成功就有，失败返回 nil，没有「改了一半」的中间态。
    //
    // `copyWithOverrideBounds:` 的语义里 bounds 是**屏幕**的 bounds（原点恒 0），
    // 所以这里剥掉原点：传 215 进去不会把屏幕挪 215，只会把宽高比搞错。
    CGRect screenBounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    id over = AevonOwnDisplayOverride(base, screenBounds);
    if (over != nil) {
        AevonOwnDisplayLog(@"win: own display %.0fx%.0f -> %.0fx%.0f via=override",
                           now.size.width, now.size.height,
                           frame.size.width, frame.size.height);
        return [over autorelease];
    }

    SEL setBounds = sel_registerName("setBounds:");
    id mutable = nil;
    @try {
        mutable = [[base mutableCopy] autorelease];
    } @catch (NSException *exception) {
        mutable = nil;
    }
    if (mutable == nil || ![mutable respondsToSelector:setBounds]) {
        // 只问不调：`mutableCopy` 出来的到底是什么类、另外两个可能的改名
        // （`setNativeBounds:` / `setScale:`）在不在。Aevon(186) 高德仍然是
        // `win=430x932`（它按 `UIScreen` 排版），要修它就得先知道这一格。
        AevonOwnDisplayLog(@"win: own display keep %.0fx%.0f (no setBounds) cls=%s mut=%d"
                           " native=%d scale=%d",
                           now.size.width, now.size.height,
                           mutable != nil ? object_getClassName(mutable) : "nil",
                           mutable != nil ? 1 : 0,
                           [mutable respondsToSelector:sel_registerName("setNativeBounds:")] ? 1 : 0,
                           [mutable respondsToSelector:sel_registerName("setScale:")] ? 1 : 0);
        return base;
    }
    ((void (*)(id, SEL, CGRect))objc_msgSend)(mutable, setBounds, screenBounds);
    AevonOwnDisplayLog(@"win: own display %.0fx%.0f -> %.0fx%.0f via=mutable",
                       now.size.width, now.size.height,
                       frame.size.width, frame.size.height);
    return mutable;
}

/// 0.2.16 — 画布的「刘海那一条」必须是**这台机器此刻的真实值**。
///
/// 0.2.15 把 `setSafeAreaInsetsPortrait:` 显式设成了 0（当时的注释写的就是
/// 「先不猜」）。Aevon(186) 的读数说清了这个「先不猜」的代价：
///   `app: geom early screen=430x932@3 scene=430x717 win=430x717 safe=0/0`
///   微信 `MMTabBar:0,666,430x51`（666+51 正好是 717 的底边）、
///   `MMUINavigationBar:0,0,430x44`（顶边）
/// 而旧路（0.2.12，系统建 scene）同一行是 `safe=59/34`，那时的底栏在 `0,632`。
/// 也就是说：App 的**重排**没错（子视图都在 717 里），错的是它不知道自己头上
/// 还有一条 59、脚下还有一条 34 —— 于是顶栏贴着上沿、底栏贴着下沿，被卡片的圆角
/// 和屏幕边缘吃掉，看起来就是「被裁过的画面」。
///
/// 值从 SpringBoard 自己的窗口上读：它挂在同一个 windowScene 上，`safeAreaInsets`
/// 就是平台算出来的事实（59/34），不是我写死的常量，换机器自动跟上。
/// 一个窗口都读不到就退回 0 —— 宁可露出旧症状，也不编一个数进去。
static UIEdgeInsets AevonOwnSafeInsets(void) {
    SEL selSafe = sel_registerName("safeAreaInsets");
    @try {
        id app = [UIApplication sharedApplication];
        SEL selWins = sel_registerName("windows");
        if (app != nil && [app respondsToSelector:selWins]) {
            NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(app, selWins);
            for (id win in wins) {
                if (win == nil || ![win respondsToSelector:selSafe]) continue;
                UIEdgeInsets in = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(win, selSafe);
                if (in.top > 0.5 || in.bottom > 0.5) {
                    AevonOwnDisplayLog(@"win: own safe top=%.0f bottom=%.0f src=win",
                                       in.top, in.bottom);
                    return in;
                }
            }
        }
        // 第二来源：状态栏高度。SpringBoard 的窗口有可能自己把安全区吃掉
        // （它自己管刘海那一条），那时上面那个循环会全是 0。状态栏高度跟顶
        // 安全区在这个系统上是同一个数，拿它兜住「顶栏被裁」这半边，脚下那
        // 34 拿不到就留 0 —— 记清楚是从哪来的，下一版按日志再定。
        SEL selBar = sel_registerName("statusBarFrame");
        if (app != nil && [app respondsToSelector:selBar]) {
            CGRect bar = ((CGRect (*)(id, SEL))objc_msgSend)(app, selBar);
            if (bar.size.height > 0.5) {
                AevonOwnDisplayLog(@"win: own safe top=%.0f bottom=0 src=statusbar",
                                   bar.size.height);
                return UIEdgeInsetsMake(bar.size.height, 0, 0, 0);
            }
        }
    } @catch (NSException *exception) {
        AevonOwnDisplayLog(@"win: own safe threw %s",
                           exception.reason != nil ? [exception.reason UTF8String] : "-");
    }
    AevonOwnDisplayLog(@"win: own safe 0/0 (no window)");
    return UIEdgeInsetsZero;
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

static id AevonOwnSettings(CGRect frame) {
    Class cls = NSClassFromString(@"UIMutableApplicationSceneSettings");
    if (cls == Nil) return nil;
    id settings = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("new"));
    if (settings == nil) return nil;

    // 显示配置：只读。屏幕本身一个字节都不改（App 进程里改 `UIScreen.bounds`
    // 那条路 0.1.x 用四次黑屏否掉了，这里是 SpringBoard 的一次读 + 一次拷贝）。
    id config = AevonOwnDisplay(frame);
    if (config != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            settings, sel_registerName("setDisplayConfiguration:"), config);
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        settings, sel_registerName("setForeground:"), YES);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(
        settings, sel_registerName("setFrame:"), frame);
    // 0.2.46 — 参考尺寸（见 `AevonOwnRefSet`）。**必须等于 display bounds**，
    // 也就是这里传 `frame.size` 而不是任何「卡片大小」：卡片只是把这块画布等比
    // 缩小画出来，App 的坐标系永远是画布。
    AevonOwnRefSet(settings, frame.size, "settings");
    // level 1 = 普通 App 场景层级。0 是桌面自己的，不要。
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(
        settings, sel_registerName("setLevel:"), (NSInteger)1);
    // 1 = 竖屏。这个数是 `UIInterfaceOrientationPortrait` 的原始值，
    // 与 `Root.plist` 里那个「强制竖屏」是同一个约定。
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(
        settings, sel_registerName("setInterfaceOrientation:"), (NSInteger)1);
    // 每个自建 scene 一个独立的持久化名：不带它，系统会把两次建的 scene
    // 当成同一个（FrontBoardAppLauncher 在这条上也写了同样一行）。
    NSString *token = [[NSUUID UUID] UUIDString];
    ((void (*)(id, SEL, id))objc_msgSend)(
        settings, sel_registerName("setPersistenceIdentifier:"), token);
    // 安全区：真机值（0.2.16）。0.2.15 这里写的是 `UIEdgeInsetsZero`，就是
    // 「所有 App 看起来被裁过」的全部原因 —— 见 `AevonOwnSafeInsets` 上面那段。
    // 仍然先过形状闸：方法在 + 参数编码是 `{UIEdgeInsets=dddd}` + 三个参数，
    // 少一条就不设（不设 = 维持 0，宁可旧症状，也不要发一个错的结构体进去）。
    UIEdgeInsets safe = AevonOwnSafeInsets();
    SEL selSafe = sel_registerName("setSafeAreaInsetsPortrait:");
    Method safeMethod = class_getInstanceMethod(object_getClass(settings), selSafe);
    const char *safeEnc = safeMethod != NULL ? method_getTypeEncoding(safeMethod) : NULL;
    unsigned int safeArgs = safeMethod != NULL ? method_getNumberOfArguments(safeMethod) : 0;
    if (safeMethod != NULL && safeArgs == 3 && safeEnc != NULL &&
        strstr(safeEnc, "UIEdgeInsets") != NULL) {
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(settings, selSafe, safe);
        AevonOwnDisplayLog(@"win: own safe set %.0f/%.0f enc=%s", safe.top, safe.bottom, safeEnc);
    } else {
        AevonOwnDisplayLog(@"win: own safe skip top=%.0f bottom=%.0f enc=%s n=%u",
                           safe.top, safe.bottom, safeEnc != NULL ? safeEnc : "-", safeArgs);
    }
    return settings;
}

/// 真正建 scene 的那一段，在启动事务的 completion 里跑。
/// 返回 scene 或 nil；任何一步不成立都返回 nil，绝不「带着半个对象继续走」。
static id AevonOwnCompose(NSString *bundleID, id processIdentity, CGRect frame) {
    Class defCls = NSClassFromString(@"FBSMutableSceneDefinition");
    Class identCls = NSClassFromString(@"FBSSceneIdentity");
    Class clientCls = NSClassFromString(@"FBSSceneClientIdentity");
    Class specCls = NSClassFromString(@"UIApplicationSceneSpecification");
    Class paramCls = NSClassFromString(@"FBSMutableSceneParameters");
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    Class clientSetCls = NSClassFromString(@"UIMutableApplicationSceneClientSettings");
    if (defCls == Nil || identCls == Nil || clientCls == Nil || specCls == Nil ||
        paramCls == Nil || mgrCls == Nil) {
        AevonOwnLog(@"win: own compose no class");
        return nil;
    }

    // scene 标识：`sceneID:<bundle>-default`。这个拼法在真机上已经见过
    // （`watch()` 里对 `sceneID:` 前缀的处理就是从系统自己的标识反推的），
    // 也是 FrontBoardAppLauncher 用的同一个。
    NSString *identity = [NSString stringWithFormat:@"sceneID:%@-default", bundleID];
    id sceneIdentity = ((id (*)(id, SEL, id))objc_msgSend)(
        identCls, sel_registerName("identityForIdentifier:"), identity);
    id clientIdentity = ((id (*)(id, SEL, id))objc_msgSend)(
        clientCls, sel_registerName("identityForProcessIdentity:"), processIdentity);
    id spec = ((id (*)(id, SEL))objc_msgSend)(
        specCls, sel_registerName("specification"));
    if (sceneIdentity == nil || clientIdentity == nil || spec == nil) {
        AevonOwnLog(@"win: own compose no identity spec=%d ident=%d client=%d",
                    spec != nil, sceneIdentity != nil, clientIdentity != nil);
        return nil;
    }

    id definition = ((id (*)(id, SEL))objc_msgSend)(
        defCls, sel_registerName("definition"));
    if (definition == nil) { AevonOwnLog(@"win: own compose no definition"); return nil; }
    ((void (*)(id, SEL, id))objc_msgSend)(
        definition, sel_registerName("setIdentity:"), sceneIdentity);
    ((void (*)(id, SEL, id))objc_msgSend)(
        definition, sel_registerName("setClientIdentity:"), clientIdentity);
    ((void (*)(id, SEL, id))objc_msgSend)(
        definition, sel_registerName("setSpecification:"), spec);

    id parameters = ((id (*)(id, SEL, id))objc_msgSend)(
        paramCls, sel_registerName("parametersForSpecification:"), spec);
    if (parameters == nil) { AevonOwnLog(@"win: own compose no parameters"); return nil; }
    id settings = AevonOwnSettings(frame);
    if (settings == nil) { AevonOwnLog(@"win: own compose no settings"); return nil; }
    ((void (*)(id, SEL, id))objc_msgSend)(
        parameters, sel_registerName("setSettings:"), settings);

    if (clientSetCls != Nil) {
        id clientSettings = ((id (*)(id, SEL))objc_msgSend)(
            clientSetCls, sel_registerName("new"));
        if (clientSettings != nil) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                clientSettings, sel_registerName("setInterfaceOrientation:"), (NSInteger)1);
            ((void (*)(id, SEL, id))objc_msgSend)(
                parameters, sel_registerName("setClientSettings:"), clientSettings);
        }
    }

    id manager = ((id (*)(id, SEL))objc_msgSend)(
        mgrCls, sel_registerName("sharedInstance"));
    if (manager == nil) { AevonOwnLog(@"win: own compose no manager"); return nil; }

    id scene = ((id (*)(id, SEL, id, id))objc_msgSend)(
        manager, sel_registerName("createSceneWithDefinition:initialParameters:"),
        definition, parameters);
    if (scene == nil) {
        AevonOwnLog(@"win: own compose nil scene");
        return nil;
    }
    // 「建出来了」和「拿得到 presenter」是两件事。拿不到就不算成功 —— 一个没有
    // uiPresentationManager 的 scene 贴不进卡片，只会留下一块永远不会有人看的
    // 画面（0.0.20 的黑屏就是这个形状）。
    id presentation = ((id (*)(id, SEL))objc_msgSend)(
        scene, sel_registerName("uiPresentationManager"));
    if (presentation == nil) {
        AevonOwnLog(@"win: own compose scene without presenter manager");
        return nil;
    }
    AevonOwnLog(@"win: own compose ok scene=%s id=%s", object_getClassName(scene),
                [identity UTF8String]);
    return scene;
}

/// 0.2.17 — 哪些 App 需要「先整屏建、再推到画布」。
///
/// 判据是**它按 `UIScreen` 排自己的内容**（抖音的 feed 容器、高德的地图容器），
/// 而不是「它有多大牌」。名单里每加一个，都要在日志里看到那一版
/// `app: geom early peers… UIView:0,0,430x932` 这种读数才加 —— 没有读数就加，
/// 等于给一个本来排得对的 App 白塞一次尺寸变化。
///
/// 名单只影响**创建时的那一帧**：贴上卡片之后宿主照旧把 frame 推到画布，所以
/// 「卡片多大、内容多大」这条口径一点没变，变的只是 App 收到了那次 resize。
static BOOL AevonOwnStageFirst(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    static const char *names[] = {
        "com.ss.iphone.ugc.Aweme",   // 抖音：Aevon(188) peers6 UIView:0,0,430x932
    };
    const char *raw = [bundleID UTF8String];
    if (raw == NULL) return NO;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(raw, names[i]) == 0) return YES;
    }
    return NO;
}

/// 起进程 + 建 scene。异步，结果落在 `AevonOwnScene`。
///
/// 返回：0 = 参数/闸不过（立刻回落），1 = 已开始（等 `AevonOwnTake`），
/// 2 = 已经有一次在跑（不重入）。
NSInteger AevonOwnStart(NSString *bundleID, CGRect frame, const char *from) {
    if (bundleID.length == 0) return 0;
    // 1 = 在建、2 = 建好了还没被取走。两种都算「有一次在跑」：覆盖 2 会丢掉
    // 上一张卡还没拿到手的那个 scene，而丢掉的 scene 没有人会去 destroy 它。
    if (AevonOwnPhase == 1 || AevonOwnPhase == 2) return 2;
    if (AevonOwnStartNotes >= 12) return 0;
    AevonOwnStartNotes++;
    if (AevonOwnGate() != 0) {
        AevonOwnLog(@"win: own denied miss=%ld from=%s",
                    (long)AevonOwnGateMiss, from != NULL ? from : "-");
        return 0;
    }
    AevonOwnPhase = 1;
    AevonOwnAt = CFAbsoluteTimeGetCurrent();
    AevonOwnScene = nil;
    // 重新开始建 = 上一张卡对「谁建的」这件事的结论作废。
    AevonOwnHeld = 0;
    // MRC：静态格换人的时候把上一位交回去，否则每开一张卡漏一条字符串。
    if (AevonOwnBundle != nil) { [AevonOwnBundle release]; AevonOwnBundle = nil; }
    if (AevonOwnIdentity != nil) { [AevonOwnIdentity release]; AevonOwnIdentity = nil; }
    AevonOwnBundle = [bundleID copy];
    AevonOwnIdentity = [[NSString stringWithFormat:@"sceneID:%@-default", bundleID] copy];
    AevonOwnFrame = frame;
    AevonOwnLog(@"win: own begin b=%@ from=%s frame=%.0fx%.0f", bundleID,
                from != NULL ? from : "-", frame.size.width, frame.size.height);
    // 0.2.46 — 建 scene 之前先回答「这台机器上显示覆盖做不做得成」，只问不调，
    // 一台机器一次。这一行是这一版所有判断的前提：覆盖做不成，App 迟早还会
    // 按 `UIScreen`(932) 排版，那时日志里 `cap=0` 就是第一个该看的字。
    AevonOwnDisplayCapable();
    AevonOwnTxnProbe();

    // 0.2.17 — 「先整屏建、再推到画布」。
    //
    // Aevon(188) 把抖音这一格拍清楚了：自建 scene 从**出生那刻**就是 430x717，
    // 于是抖音的 feed 容器按 `UIScreen`(430x932) 排 ——
    //   app: geom early peers6 n=1 UIView:0,0,430x932
    //   app: geom early peers7 … UIView:0,0,430x932 | AWEFeedTopBarContainer:0,59,430x44
    // 顶栏按安全区排对了，右侧那列工具栏锚在 932 的底部区，落在 717 之外 ⇒ 显示不全。
    //
    // 老路（0.2.12 系统建 scene）同一台机器上是 717 的：
    //   app: geom late peers7 … UIView:430x717|AWEFeedTopBarContainer:430x44|UIImageView:430x717
    // 差别不在「谁建 scene」，在**有没有经历过一次 932→717 的尺寸变化** ——
    // 老路是先把 App 拉起来（整屏），再把窗口推到画布，App 收到那次 resize 才按
    // 新尺寸重建自己的页面。自建 scene 把这两步压成一步，App 一辈子没收到过
    // 那次 resize，就按出生时读到的 `UIScreen` 排了。
    //
    // 所以这里只补那一次「出生整屏」：scene 先按屏建，宿主贴上卡片后照旧把 frame
    // 推到画布（`win: scene frame push door=…`），于是 App 经历一次 932→717，
    // 和老路完全同一个事件序列。**不碰 UIScreen、不碰 App 的任何视图**。
    CGRect composeFrame = frame;
    if (AevonOwnStageFirst(bundleID)) {
        CGRect full = [[UIScreen mainScreen] bounds];
        if (full.size.height > frame.size.height + 8.0 &&
            fabs(full.size.width - frame.size.width) < 8.0) {
            composeFrame = full;
            AevonOwnDisplayLog(@"win: own staged %.0fx%.0f -> %.0fx%.0f b=%@",
                               composeFrame.size.width, composeFrame.size.height,
                               frame.size.width, frame.size.height, bundleID);
        }
    }

    @try {
        Class idCls = NSClassFromString(@"RBSProcessIdentity");
        id identity = ((id (*)(id, SEL, id))objc_msgSend)(
            idCls, sel_registerName("identityForEmbeddedApplicationIdentifier:"), bundleID);
        if (identity == nil) {
            AevonOwnLog(@"win: own no process identity");
            AevonOwnPhase = 3;
            return 0;
        }
        Class predCls = NSClassFromString(@"RBSProcessPredicate");
        id predicate = ((id (*)(id, SEL, id))objc_msgSend)(
            predCls, sel_registerName("predicateMatchingIdentity:"), identity);

        Class mgrCls = NSClassFromString(@"FBProcessManager");
        id manager = ((id (*)(id, SEL))objc_msgSend)(
            mgrCls, sel_registerName("sharedInstance"));
        if (manager == nil) {
            AevonOwnLog(@"win: own no process manager");
            AevonOwnPhase = 3;
            return 0;
        }

        // launchIntent = 4 —— 这一格是「不摆到前台」的全部。母本用它换掉了
        // `launchApplicationWithIdentifier:suspended:` 那条在 iOS 17 上已经
        // 不听 suspended 的老路。
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

        // 母本传的是栈上的 block 字面量。MRC 下这一步不能照抄：那个 block 里
        // 捕获着 `identity`/`manager`，如果 `init…` 只存指针不 copy，栈帧一退
        // 它就是个野指针。显式 copy 到堆，并且**故意不 release** —— 每次开一张
        // 卡漏几十字节，换「不会因为一个不知道有没有 retain 的初始化器而崩」。
        id providerHeap = [provider copy];
        // 0.2.14 — 这里原来是 `objc_msgSend(txnCls, init…)`：把**实例**初始化器
        // 发给了类对象，于是 Aevon(183) 第一句就是
        // `+[FBApplicationProcessLaunchTransaction initWithProcessIdentity:
        //   executionContextProvider:]: unrecognized selector sent to class`
        // —— 整条自建 scene 路一次都没走进去，每次都落回挂起启动，用户看到的
        // 当然还是「先全屏、再浮窗、全屏黑屏」。
        //
        // 闸没拦住它不是闸的错：`class_getInstanceMethod` 问的正是实例方法，
        // 它确实在（`miss=0` 是真的）。错在调用点少了一次 `alloc`。
        id allocated = ((id (*)(id, SEL))objc_msgSend)(txnCls, sel_registerName("alloc"));
        id transaction = allocated != nil
            ? ((id (*)(id, SEL, id, id))objc_msgSend)(
                  allocated, sel_registerName("initWithProcessIdentity:executionContextProvider:"),
                  identity, providerHeap)
            : nil;
        if (transaction == nil) {
            AevonOwnLog(@"win: own no transaction");
            AevonOwnPhase = 3;
            return 0;
        }

        // completion 里只碰全局和 block 自己，不碰 `AevonOwnStart` 的栈。
        // 这个文件是 MRC：block 被 `setCompletionBlock:` 拷到堆上时，
        // 捕获的 `bundleID` / `frame` 已各自复制一份，栈帧早就不在了。
        NSString *doneBundle = [bundleID copy];
        CGRect doneFrame = composeFrame;
        void (^done)(void) = ^{
            // 这个 completion 跑在哪个队列由 FrontBoard 决定，不由我们选。所有
            // 状态变更都搬到主线程：读它的 `pollForScene` 就在主线程上，于是
            // 「phase 已经 2、scene 还是 nil」这种中间态不会被别人看见，
            // 这一层也就不需要一个锁（这个工程里锁过的地方都出过事）。
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    Class handleCls = NSClassFromString(@"RBSProcessHandle");
                    id handle = ((id (*)(id, SEL, id, void *))objc_msgSend)(
                        handleCls, sel_registerName("handleForPredicate:error:"),
                        predicate, NULL);
                    if (handle != nil) {
                        AevonAuditToken token;
                        if (AevonOwnAuditToken(handle, &token)) {
                            AevonOwnRegisterProcess(manager, token);
                        }
                    } else {
                        AevonOwnLog(@"win: own no process handle");
                    }
                    id scene = AevonOwnCompose(doneBundle, identity, doneFrame);
                    AevonOwnPhase = scene != nil ? 2 : 3;
                    AevonOwnScene = scene;
                    // `%s` 不是 `%@`：`object_getClassName()` 返回的是 C 字符串，交给
                    // `%@` 会被当成对象去 retain，第一个字就是野指针。
                    AevonOwnLog(@"win: own done phase=%ld scene=%s", (long)AevonOwnPhase,
                                scene != nil ? object_getClassName(scene) : "nil");
                } @catch (NSException *e) {
                    AevonOwnPhase = 3;
                    AevonOwnScene = nil;
                    AevonOwnLog(@"win: own threw %s",
                                e.reason != nil ? [e.reason UTF8String] : "-");
                }
            });
        };
        ((void (*)(id, SEL, id))objc_msgSend)(
            transaction, sel_registerName("setCompletionBlock:"), done);
        if (!AevonCallVoid(transaction, @"begin")) {
            AevonOwnLog(@"win: own begin refused");
            AevonOwnPhase = 3;
            return 0;
        }
        return 1;
    } @catch (NSException *e) {
        AevonOwnPhase = 3;
        AevonOwnLog(@"win: own threw at start %s",
                    e.reason != nil ? [e.reason UTF8String] : "-");
        return 0;
    }
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
    if (AevonActivateSwitchOff()) return 0;
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
#define AEVON_HOOK_SLOTS 7

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

/// Set once per process when the previous run died inside the push. Two
/// crashes in a row — not one — is what the system calls a safe mode
/// (MultiFloat round 3, `[CONFIRMED]`: crash, auto-retry, crash, safe mode).
/// The second run therefore refuses to try instead of explaining it again.
static volatile int AevonPushBanned = 0;

void AevonBanPush(void) {
    AevonPushBanned = 1;
}

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
static long AevonAckCount = 0;
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
        __sync_fetch_and_add(&AevonAckCount, 1);
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

long AevonSceneAckCount(void) { return AevonAckCount; }

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
static BOOL AevonWriteDisplay(id settings, int slot) {
    if (settings == nil) return NO;
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
    const char *className = object_getClassName(settings);
    if (className == NULL || strstr(className, "Mutable") == NULL) return NO;
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
            && target.size.height < 800
            && (CFAbsoluteTimeGetCurrent() - AevonArmedAt[slot]) > 0.40) {
            __sync_fetch_and_and(&AevonFrameMask, ~(1 << slot));
            AevonArmedAt[slot] = 0;
            AevonLogRaw([[NSString stringWithFormat:
                          @"win: card yield seen b=%s now=%.0fx%.0f want=%.0fx%.0f",
                          AevonArmed[slot],
                          now.size.width, now.size.height,
                          target.size.width, target.size.height] UTF8String]);
            char *name = strdup(AevonArmed[slot]);
            if (name == NULL) return NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (name[0] == '\0') { free(name); return; }
                AevonCardYieldForFullscreen(name);
                free(name);
            });
            return NO;
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
    if (AevonPushBanned) return 0;
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

// MARK: - 0.2.63 落点（landing）
//
//  Aevon(203) 之后的那份对比报告把话说清楚了：Stheno / TrollOpen 从来没有
//  「先全屏、再收进浮窗」这一帧，因为它们**不跟系统抢**——系统照常把 App 拉起来
//  并把 URL 交给它，它们只改「摆在哪」。Aevon 这五版一直在做的是反过来的事：
//  拦下请求、自己建 scene、自己投 URL，投不通就退回全屏，然后再用定时器去追
//  一个已经画出来的全屏帧。
//
//  这一版把那条链砍回一根：**`_openURLCore:display:…` 是系统唯一的 URL 打开
//  入口，它带着一个 `display` 参数**。TrollOpen 就是钩这一个（它的 `URLJump`
//  开关），Aevon 从来没有这个钩子（11-08 的报告里写着「Aevon 没有 URL 钩子」）。
//
//  做法只有一句：要进卡片的那个 App，`display` 传 nil。
//    · URL 仍由系统原生投递 ⇒ 微信的 `NSUserActivity`、QQ 的 SSO 回跳都在；
//    · 系统不把它摆到屏幕上 ⇒ 没有全屏帧，也就没有「下半黑」；
//    · 我们再把那份已经存在的 scene 收进卡片（`AevonOpenCardDirect` 认活 scene）。
//
//  0.2.67 — 那道「进程必须已经在」的闸拆了。Aevon(205) 两次 QQ 文件分享都是
//  `landing: url mqqapi://share/to_fri … run=0 cut=0`：分享时 QQ 还没起进程，
//  于是唯一要修的那一次被这道闸整条放走 —— 系统照常整屏激活、60 ms 后
//  `share swap` 再收卡，用户看到的就是「先全屏、再回落」。
//  现在只剩两条真条件：**主队列 + display 不是 nil**。冷启动没有 scene 的那一
//  种由 `AevonLandCardSchedule` 兜：等 scene 登记，1.5 s 还没等到就自己建一份。
//
//  另一道闸不变：形状不对就不装。私有方法的调用约定猜不得 —— 这一版只认真机
//  读回来的那一份编码（参数序列 `@@B@@@?`），别的一律只记一行、不装钩子。
//
//  0.2.66 — 0.2.65 的闸写的是「两个 BOOL」（`@ B B @ @ @?`），因为按名字以为
//  `display:` 是 BOOL。Aevon(204) 把真机的答案打了出来：
//      `v60@0:8@16@24B32@36@44@?52`
//  六个参数里只有一个 BOOL，而且它在第 3 位 —— 第 2 位的 `display:` 是**对象**。
//  TrollOpen 的字符串表里就摆着同一件事：`display=(nil)`、
//  `displayClass=%@ display=%@ displayBundle=%@ displayIdentifier=%@`。
//  它按对象读 display，并且把 nil 当成一个正常取值。
//  所以「不摆到屏幕上」这一个动作，传的不是 `NO`，是把这个 display 对象传 nil。

typedef void (*AevonURLCoreProc)(id, SEL, id, id, BOOL, id, id, id);

static AevonURLCoreProc AevonURLCoreOriginal = NULL;
static long AevonURLCalls = 0;
static long AevonURLCuts = 0;

/// 0.2.76 — 落点钩子刚刚接管的那个 App。
///
/// 两条链会撞：`_openURLCore:` 在外层（我们这个钩子），它调原实现之后才进
/// `_handleOpenApplicationRequest:`（`AevonOpenDecide` 那个钩子）。于是一次
/// openURL 会同时被「落点」和「分流」看见 —— 落点排一张卡、分流再排一张，
/// 屏幕上就是一大一小两个。
///
/// 规则：**落点接了，分流就让路。** 反过来不成立 —— 授权那一族刻意不由落点接
/// （见下面 `authFamily`），因为它们要的是「吞掉 + 自建」，那件事只有分流会做。
static char AevonLandingClaim[128] = {0};
static double AevonLandingClaimAt = 0;

/// 微 /  QQ / 支付宝 / 云闪付 —— 授权登录与支付这一族。
///
/// 它们**不**走落点：0.2.74 的「吞掉这次激活、卡片自建、URL 本地投递」能省掉
/// 整屏那一帧，而那条链在 `AevonOpenDecide` 里。落点再插一手只会把系统激活
/// 放回来，正好抵消掉它。
static int AevonBundleIsAuthFamily(const char *b) {
    if (b == NULL) return 0;
    // 0.2.79 — 补上 `com.alipay.iphoneclient`。这是支付宝在 App Store 版上的
    // 真 bundle id；`com.eg.android.AlipayGphone` 是 Android 用的那一个，
    // 名单里只写它等于「支付永远认不出来」。Aevon(212) 12:21:28 的支付现场：
    //   notify: share b=com.alipay.iphoneclient src=com.chinaunicom.mobilebusiness
    // 它被当成分享，走了「自建 scene + 投 URL」，然后 `appurl give why=timeout`。
    return strncmp(b, "com.tencent.xin", 15) == 0 ||
           strncmp(b, "com.tencent.mqq", 15) == 0 ||
           strncmp(b, "com.alipay.iphoneclient", 23) == 0 ||
           strncmp(b, "com.eg.android.AlipayGphone", 27) == 0 ||
           strncmp(b, "com.unionpay", 12) == 0;
}

// MARK: - 0.2.76 这条 URL 要去哪个 App（去名单化）
//
//  0.2.63~0.2.75 的判据是一张两个元素的名单：`weixin://` → 微信，`mqq*` → QQ。
//  于是「URL 打开一个 App」这件事只有这两个 App 有资格进卡片，其余全部交给
//  系统整屏 —— 点一条 https、点一个 `alipays://`、从相册分享到别的 App，看到的
//  都是全屏。
//
//  Stheno / TrollOpen 没有名单。报告里那句「它们接管的是**应用启动**这件事本身」
//  落到 URL 上就是这个问题：**这次打开要去哪个 App**。系统回答这个问题的唯一
//  权威是 LaunchServices：
//      `-[LSApplicationWorkspace applicationForOpeningURL:]` → `LSApplicationProxy`
//      → `.bundleIdentifier`
//  它认得 scheme，也认得通用链接归属哪个 App —— 后者正是字符串猜不出来的那一种
//  （微信登录走的 `https://help.wechat.com/app/…` 就属于这里）。
//
//  这一版把名单从「判断」降级成「快路」：命中就省一次查询，没命中就问系统；
//  问不到（没有任何 App 认领这条 URL）才真的不接管，`display` 原样下发。
//
//  三条永远不问：`tel` / `facetime` 是通话界面，整屏是它的正确形态；`file` 是
//  文件 URL，没有「打开它的 App」这回事。这三个连快路都不进，直接返回 nil。

// MARK: - 0.2.77 解析不出来时的那条路
//
// 0.2.76 把「这条 URL 归谁」全押在 LaunchServices 上。Aevon(211) 第一次真机
// 取到读数，那一次是：
//
//   landing: url chinaunicom://safepay/ b=- d=SBApplication a=1 run=0 land=0 n=2
//
// `chinaunicom://` 是联通 App 自己的 scheme（装着的），但两条 LS 路都答了 nil，
// 于是支付回跳整屏。静态证明不了是哪一步断的（类不在 / 选择子不在 / 返回空 /
// 代理拿不到 bundleIdentifier），所以这一版做两件事：
//
//   ① 把失败的那一步记下来 —— `landing: url ls miss step=…`，下份日志直接定位；
//   ② **不再等它**：解析不出来就把这条 URL 记在案上（下面的 pending 三件套），
//      让下一跳——系统已经把目标 App 算好了的那一跳——自己把门牌报出来。
//
// ② 的形状是「不吞」：`AevonOpenDecide` 照常放行（URL 正常交付），只是顺手排
// 一条收卡链（`AevonLandCardSchedule` 背后是 0.2.66 的「scene 是钥匙」）。
// 所以它最坏的结果是「跟现在一样整屏」，不会让 URL 送不到 —— 0.2.69 那次
// `display=nil` 把主屏前台弄丢的教训就在这。

/// 一条解析不出来的 URL，以及它被记下的时刻。一次性：谁消费谁清零。
static char AevonLinkPending[192] = {0};
static double AevonLinkPendingAt = 0;
static int AevonLinkPendingNotes = 0;
static int AevonLSMissNotes = 0;

/// 这些 scheme 不进卡：`tel` / `facetime` 是通话界面（整屏是它的正确形态），
/// `file` 没有「打开它的 App」，`prefs` / `itms-services` 是设置与安装流程 ——
/// 它们出现在屏幕上时用户要的是那件事本身，不是一个窗口。
static int AevonURLIsSystemEntry(const char *raw) {
    if (raw == NULL) return 1;
    if (strncasecmp(raw, "tel:", 4) == 0) return 1;
    if (strncasecmp(raw, "facetime", 8) == 0) return 1;
    if (strncasecmp(raw, "file:", 5) == 0) return 1;
    if (strncasecmp(raw, "prefs:", 6) == 0) return 1;
    if (strncasecmp(raw, "app-prefs:", 10) == 0) return 1;
    if (strncasecmp(raw, "x-apple", 7) == 0) return 1;
    if (strncasecmp(raw, "itms-services:", 14) == 0) return 1;
    if (strncasecmp(raw, "itms-apps:", 10) == 0) return 1;
    return 0;
}

/// https 不走 pending：那一条已经在分流的 `safari` 分支里跑通了（Aevon(211)
/// 11:57:17/24/28/33 四次 `notify: link … kind=safari` → 四张卡）。再插一条
/// 平行的路只会让两条链抢同一张卡。
static int AevonURLIsWeb(const char *raw) {
    if (raw == NULL) return 0;
    return strncasecmp(raw, "http://", 7) == 0 || strncasecmp(raw, "https://", 8) == 0;
}

static void AevonLSMiss(const char *step) {
    if (AevonLSMissNotes >= 6) return;
    AevonLSMissNotes += 1;
    AevonLogRaw([[NSString stringWithFormat:@"landing: url ls miss step=%s", step] UTF8String]);
}

/// `LSApplicationProxy.bundleIdentifier`，守卫后取。
static NSString *AevonProxyBundleID(id proxy) {
    if (proxy == nil) return nil;
    SEL sel = NSSelectorFromString(@"bundleIdentifier");
    if (![proxy respondsToSelector:sel]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(proxy, sel);
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

/// 这条 URL 指向哪个 App。nil = 问不出来。
static NSString *AevonTargetForURLString(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length < 4) return nil;
    const char *raw = text.UTF8String;
    if (raw == NULL) return nil;

    // 快路。这两族不交给 LaunchServices 是有原因的：装了多开 / 企业版时同一个
    // scheme 可能被别的 bundle 抢注，而这两族的落点行为从 0.2.63 起被十几版
    // 真机日志验证过，不该因为一次查询结果变化就换掉。
    if (strncasecmp(raw, "weixin://", 9) == 0) return @"com.tencent.xin";
    if (strncasecmp(raw, "mqq", 3) == 0) return @"com.tencent.mqq";
    if (AevonURLIsSystemEntry(raw)) return nil;

    NSURL *url = [NSURL URLWithString:text];
    if (url == nil || url.scheme.length == 0) return nil;

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass == Nil) { AevonLSMiss("class"); return nil; }
    SEL sharedSel = NSSelectorFromString(@"defaultWorkspace");
    if (![(id)workspaceClass respondsToSelector:sharedSel]) { AevonLSMiss("shared"); return nil; }
    id workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, sharedSel);
    if (workspace == nil) { AevonLSMiss("ws"); return nil; }

    // 主路：单个答案。这条在 SpringBoard 里是进程内缓存，不打 IPC。
    SEL oneSel = NSSelectorFromString(@"applicationForOpeningURL:");
    if ([workspace respondsToSelector:oneSel]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(workspace, oneSel, url);
        NSString *bid = AevonProxyBundleID(proxy);
        if (bid.length > 2) return bid;
        // 0.2.77 — 分开记：`one-nil` 是 LS 没答案，`one-bid` 是对象到手但取不到
        // bundleIdentifier。两者的修法完全不同，日志里不能再长得一样。
        AevonLSMiss(proxy == nil ? "one-nil" : "one-bid");
    } else {
        AevonLSMiss("one-sel");
    }
    // 退路：`applicationsForOpeningURL:` 取第一个。新版系统上主路返回 nil 的
    // 那几种（多候选、通用链接刚装）走这里。
    SEL manySel = NSSelectorFromString(@"applicationsForOpeningURL:");
    if ([workspace respondsToSelector:manySel]) {
        id list = ((id (*)(id, SEL, id))objc_msgSend)(workspace, manySel, url);
        if ([list isKindOfClass:[NSArray class]] && [(NSArray *)list count] > 0) {
            NSString *bid = AevonProxyBundleID([(NSArray *)list objectAtIndex:0]);
            if (bid.length > 2) return bid;
            AevonLSMiss("many-bid");
        } else {
            AevonLSMiss("many-none");
        }
    } else {
        AevonLSMiss("many-sel");
    }
    return nil;
}

/// 从一次打开请求的 action 对象里把 URL 掏出来。
///
/// Aevon(210) 11:42:00 的那一拍是
///   `notify: hit op=open b=- src=- act=#UILinkConnectionAction … url=-`
/// 目标 App 与 URL 都是空，于是 `why=nobundle` 整条放行，用户看到全屏。
/// `UILinkConnectionAction` 是「应用外的一条链接」最纯的形状：URL 装在 action
/// 自己身上，不在 `options` 的任何 `__PayloadURL` 里 —— 所以 `AevonOpenURLOf`
/// 扫遍所有已知键也读不到。
///
/// 读法按对象形状逐级退：`url` / `URL` / `linkURL` 选择子 → `info` 字典同名键。
/// 每一步都先 `respondsToSelector:`（裸 KVC 碰缺键会杀进程，工程硬禁令）。
static NSString *AevonActionURL(id action) {
    if (action == nil) return nil;
    NSArray *names = [NSArray arrayWithObjects:@"url", @"URL", @"linkURL", nil];
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![action respondsToSelector:sel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(action, sel);
        if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
        if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    }
    SEL infoSel = NSSelectorFromString(@"info");
    if ([action respondsToSelector:infoSel]) {
        id info = ((id (*)(id, SEL))objc_msgSend)(action, infoSel);
        if ([info isKindOfClass:[NSDictionary class]]) {
            NSArray *keys = [NSArray arrayWithObjects:
                             @"URL", @"url", @"UILinkConnectionActionURL", nil];
            for (NSString *key in keys) {
                id value = [(NSDictionary *)info objectForKey:key];
                if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
                if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
            }
        }
    }
    return nil;
}

/// 日志里那一段 URL 的「门牌」：scheme://host，最多 40 个字符。
///
/// 0.2.65 只打 scheme，结果 `https` 这一个词什么也说明不了 —— 微信 / QQ 的
/// 登录走的正是 https 通用链接（Aevon(204)：`scheme=https/204`），要认它就
/// 必须看见 host。这里只截断、不解析，也不改任何判断。
static void AevonLandingShape(const char *url, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (url == NULL) { snprintf(out, size, "-"); return; }
    size_t i = 0;
    while (url[i] != '\0' && i + 1 < size && i < 40) {
        char c = url[i];
        if (c == '?' || c == '#' || c == ' ' || c == '\n' || c == '\t') break;
        out[i] = c;
        i += 1;
    }
    out[i] = '\0';
}

/// 把类型编码压成「只有类型、没有偏移」的一串，再跟真机读数逐字比。
///   `v60@0:8@16@24B32@36@44@?52` ⇒ `v@:@@B@@@?`
///
/// 0.2.65 的闸是自己拼了一个「两个 BOOL」的形状再去比，比错了方向：它拒掉的
/// 正是唯一实现这个选择子的类。这里不猜形状，只认那一次真机读回来的字符串。
static void AevonLandingSig(const char *encoding, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (encoding == NULL) return;
    size_t n = 0;
    for (const char *p = encoding; *p != '\0' && n + 2 < size; p++) {
        char c = *p;
        if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '"' || c == '[' ||
            c == ']' || c == '{' || c == '}' || c == '(' || c == ')' || c == '^' ||
            c == '<' || c == '>' || c == '=' || c == 'b' || c == 'n' ||
            c == 'r' || c == 'N' || c == 'o' || c == 'O' || c == 'R' || c == 'V') {
            continue;
        }
        out[n++] = c;
    }
    out[n] = '\0';
}

/// 唯一认的形状：`v @ : @ @ B @ @ @ ?`。
/// 返回 void、self、_cmd，然后 url(@) display(@) animating(B)
/// activationSettings(@) origin(@) withResult(@?)。少一条都不装。
static int AevonLandingEncodingOK(const char *encoding) {
    char sig[32];
    AevonLandingSig(encoding, sig, sizeof(sig));
    return strcmp(sig, "v@:@@B@@@?") == 0 ? 1 : 0;
}

static void AevonLandCardSchedule(const char *target);
static void AevonLandingGuardStart(const char *target);

static void AevonURLCoreReplacement(id self, SEL _cmd, id url, id display,
                                    BOOL animating, id settings, id origin, id result) {
    long seen = __sync_fetch_and_add(&AevonURLCalls, 1);
    NSString *text = nil;
    if ([url isKindOfClass:[NSURL class]]) text = [(NSURL *)url absoluteString];
    else if ([url isKindOfClass:[NSString class]]) text = (NSString *)url;
    const char *raw = text.length > 0 ? text.UTF8String : NULL;
    // 0.2.76 — 目标 App 由 LaunchServices 回答（见 `AevonTargetForURLString`）。
    // 名单只剩「快路」，不再是否决：https 通用链接、`alipays://`、任何第三方
    // 深链，只要系统能说出归谁，这里就说得出来。
    NSString *targetID = AevonTargetForURLString(text);
    const char *target = targetID.length > 2 ? targetID.UTF8String : NULL;

    int running = 0;
    int land = 0;
    if (target != NULL) {
        NSString *bundleID = targetID;
        running = AevonAppPid(bundleID) > 0 ? 1 : 0;
        // 主队列才接手：`AevonOpenCardDirect` 与窗口状态都是主线程的东西，在系统
        // 的工作区队列上读它们会撞上正在拆窗的那一拍。不在主队列就只记录。
        //
        // 不看进程在不在（0.2.67）：分享那一刻微 / QQ 经常还没起进程，而它正是
        // 我们要接的那一次。`running` 只进日志，不再进判断。
        //
        // 0.2.76 — **`display` 不再是前提。**
        //
        // 0.2.63 起这里要求 `display != nil` 才落卡，理由是「系统自己也会传 nil，
        // 那是它已经在按我们要的方式排」。加了通用解析之后这条理由不成立了：
        // 目标 App 是**我们**算出来的，系统那一拍是不是已经把 display 传成 nil
        // 与我们要不要建卡无关 —— 传 nil 只说明它这一拍不摆屏，卡还得我们自己给。
        // 真机读数里 `d=nil` 与 `d=FBSDisplayConfiguration` 两种都出现过，两种都
        // 应该落卡。
        //
        // 唯一新增的否决：目标 App **已经在前台、且不在我们任何一张卡里**。
        // 那是「它本来就在最前面」，把它缩进卡只会打断用户手上这件事；而它若在
        // 卡里，`AevonOpenCardDirect` 会复用那张卡，正是我们要的。
        if ([NSThread isMainThread]) {
            int cardUp = AevonCardIsUpFor(target) == 1 ||
                         AevonCardIsComingFor(target) == 1;
            int front = AevonAppFrontmost(bundleID);
            if (AevonBundleIsAuthFamily(target)) {
                // 0.2.87 — **并轨母版，这一格不再另立门户。**
                //
                // 0.2.5x~0.2.7x 这里写的是「授权 / 支付交给分流那一支（吞掉 +
                // 自建 + 本地投递）。这里放回来只会让系统激活重演一次整屏」。
                //
                // ⛔ 前半句已被 Aevon(212) 证伪：自建 scene 里**没有系统那一次
                //    激活**，QQ 答 `rsp=0`、支付宝 `timeout 6342ms`、微信空壳。
                // ⛔ 后半句是**代价**，不是理由。母版也接受这一小段整屏，它的解法
                //    是把目标提前拉热（`launchApplicationWithIdentifier:suspended:`，
                //    复刻方案 P5 原话「场景先建好不跑，要显示时再激活」），
                //    而不是绕开系统激活。
                //
                // 所以这里只负责「不让卡抢在系统前面」，放不放行仍由分流那一支
                // 统一决定（`why=oauthpass` / `why=linkpass` 都走 `return 0`）。
                if (seen < 6) {
                    AevonLogRaw([[NSString stringWithFormat:
                                  @"landing: url hand b=%s why=auth", target] UTF8String]);
                }
            } else if (front == 1 && !cardUp) {
                if (seen < 6) {
                    AevonLogRaw([[NSString stringWithFormat:
                                  @"landing: url keep b=%s why=front card=0",
                                  target] UTF8String]);
                }
            } else {
                land = 1;
            }
        } else if (seen < 2) {
            AevonLogRaw([[NSString stringWithFormat:@"landing: url offmain b=%s", target] UTF8String]);
        }
    }
    if (land) __sync_fetch_and_add(&AevonURLCuts, 1);
    if (seen < 6 || land) {
        char shape[48];
        AevonLandingShape(raw, shape, sizeof(shape));
        // display 是对象，可能本来就是 nil（系统自己也会传 nil）。只读类名。
        const char *dcls = "-";
        if (display == nil) dcls = "nil";
        else if ((uintptr_t)display > 0x1000) {
            const char *name = object_getClassName(display);
            dcls = name != NULL ? name : "?";
        } else {
            dcls = "scalar";
        }
        AevonLogRaw([[NSString stringWithFormat:
                      @"landing: url %s b=%s d=%s a=%d run=%d land=%d n=%ld",
                      shape, target != NULL ? target : "-", dcls,
                      animating ? 1 : 0, running, land, seen + 1] UTF8String]);
    }

    // 0.2.77 — 解析不出来就把这条 URL 记在案上。
    //
    // 记的是**原始字符串**，而且一个字都不改：`AevonURLCoreOriginal` 拿到的还是
    // 原来那个 `url`，`display` 也照旧 —— 这一段只读，不参与任何判定。真正的
    // 动作用在下一跳（见 `AevonOpenDecide` 的 `urllate`），那一跳上系统已经把
    // 目标 App 算好了，比我们猜得准。
    // 每一拍先把上一拍的记录清掉：只认最近这一次。`_openURLCore:` 会嵌套
    // （原实现自己还会再开一条 URL），后者才是这一拍的真相。
    AevonLinkPendingAt = 0;
    if (target == NULL && raw != NULL && !AevonURLIsWeb(raw) && !AevonURLIsSystemEntry(raw)) {
        snprintf(AevonLinkPending, sizeof(AevonLinkPending), "%s", raw);
        AevonLinkPendingAt = CFAbsoluteTimeGetCurrent();
        if (AevonLinkPendingNotes < 6) {
            AevonLinkPendingNotes += 1;
            AevonLogRaw([[NSString stringWithFormat:@"landing: url pending b=- n=%ld",
                          seen + 1] UTF8String]);
        }
    }

    if (AevonURLCoreOriginal != NULL) {
        // 0.2.70 — **回滚 0.2.69 的 nil display。**
        //
        // 0.2.69 的现场（用户真机）：分享到 QQ 时 QQ 既不建卡也不上屏，主屏的
        // 前台 App 又被撤掉 ⇒ 上滑回桌面失效，连注销都做不到。原因是 nil 的
        // 语义是「打开，但不摆到任何屏幕上」：目标 scene 不会进入可用的前台
        // 状态，建卡那条「等 scene」的链等不到东西；再叠加 0.35 s 后重新激活
        // 来源 App，把目标唯一那次激活也顶掉了。
        //
        // 现在 display 原样下发。全屏帧会露出一瞬，`AevonLandCardSchedule` 的
        // 收卡链紧接着把同一份 scene 收进卡里 —— 用户看到的是闪一下，而不是
        // 一个没有前台 App、手势失效的主屏。**主屏永远有前台 App** 这条优先。
        id forwarded = display;
        // 0.2.76 — 先立牌，再交出去。
        //
        // 原实现会一路走到 `_handleOpenApplicationRequest:`，也就是
        // `AevonOpenDecide` 那个钩子。牌必须在**调用之前**立好，否则分流那一拍
        // 还会以为没人接，照着 `share` / `isWebLink` 再排一张卡。
        if (land) {
            snprintf(AevonLandingClaim, sizeof(AevonLandingClaim), "%s", target);
            AevonLandingClaimAt = CFAbsoluteTimeGetCurrent();
        }
        AevonURLCoreOriginal(self, _cmd, url, forwarded, animating,
                             settings, origin, result);
    }
    if (!land) return;

    // 收卡交给同一条「等 scene」的链：这一栈在系统的工作区事务里，事务没提交
    // 之前建窗会和 FrontBoard 抢同一份 scene（0.0.31 的死锁纪律）。60 ms 的固定
    // 延时在冷启动那一次不够用（QQ 首次起来要一秒多），所以按 scene 登记来。
    AevonLandCardSchedule(target);
    // 0.2.71 — 看门狗：万一这一拍把前台弄丢，1.8 s 后自己拉回来。
    AevonLandingGuardStart(target);
}

// MARK: - 0.2.71 — 落点看门狗
//
// 0.2.69 的现场：一次落点被放行后既没有卡片、也没有全屏 App、桌面也不在前台，
// 系统停在「没有前台」的状态 —— 上滑失效，连注销都做不到。
//
// 逆向 TrollOpenJB 1.5.2 得到的结构是「吞掉 + 自建浮窗」：它的
// `_openURLCore:display:animating:activationSettings:origin:withResult:` 只读
// display / target / origin（日志里 `display=(nil)` 是读数，不是它传出去的值），
// 真正开窗走自己的 `TOS_openFloatingViewForURL`。它敢吞，是因为自建那条路
// 在它自己的进程里一定成功；我们没有这个前提，所以不能照抄「吞」。
//
// 这里只加一条**读后写**：落点放行 1.8 s 后，卡片 / 桌面 / 任意全屏 App 三样
// 一个都没有，就判定这一拍把前台弄丢了，直接用 `LSApplicationWorkspace`
// 把来源 App（没有就目标 App）拉回前台；拉不起来就强建卡。正常路径一个字节
// 都不改，只在最坏情况下保证「手机还能操作」。

static void AevonLandingSourceCopy(char *out, size_t size);

/// 现在有没有**任意**一个 App 在前台。1 = 有 / 0 = 没有 / -1 = 读不到。
/// 只读 `SBApplication.isFrontmost`，与 `AevonAppFrontmost` 同源。
static int AevonAnyAppFrontmost(void) {
    @try {
        Class cls = NSClassFromString(@"SBApplicationController");
        if (cls == Nil) return -1;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:sharedSel]) return -1;
        id ctrl = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSel);
        SEL appsSel = NSSelectorFromString(@"applications");
        if (ctrl == nil || ![ctrl respondsToSelector:appsSel]) return -1;
        id apps = ((id (*)(id, SEL))objc_msgSend)(ctrl, appsSel);
        if (apps == nil || ![apps respondsToSelector:@selector(count)]) return -1;
        SEL fgSel = NSSelectorFromString(@"isFrontmost");
        for (id app in (NSArray *)apps) {
            if ([app respondsToSelector:fgSel] &&
                ((BOOL (*)(id, SEL))objc_msgSend)(app, fgSel)) {
                return 1;
            }
        }
        return 0;
    } @catch (__unused NSException *e) {
        return -1;
    }
}

/// 用系统自己的入口把一个 App 拉回前台。返回 1 表示这句发出去了。
static int AevonLandOpenApp(const char *bundle) {
    if (bundle == NULL || bundle[0] == '\0') return 0;
    @try {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls == Nil) return 0;
        SEL sharedSel = NSSelectorFromString(@"defaultWorkspace");
        if (![cls respondsToSelector:sharedSel]) return 0;
        id ws = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSel);
        if (ws == nil) return 0;
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (![ws respondsToSelector:openSel]) return 0;
        BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(
            ws, openSel, [NSString stringWithUTF8String:bundle]);
        return ok ? 1 : 0;
    } @catch (__unused NSException *e) {
        return 0;
    }
}

static void AevonLandingGuardTick(char *target, int tick) {
    if (target == NULL) return;
    if (target[0] == '\0') { free(target); return; }
    int card = AevonCardIsUpFor(target);
    int board = AevonSpringboardActive();
    int any = AevonAnyAppFrontmost();
    if (card == 1 || board == 1 || any == 1) {
        if (tick >= 4) {
            AevonLogRaw([[NSString stringWithFormat:
                          @"landing: guard ok b=%s tick=%d card=%d board=%d any=%d",
                          target, tick, card, board, any] UTF8String]);
        }
        free(target);
        return;
    }
    if (tick < 9) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AevonLandingGuardTick(target, tick + 1);
        });
        return;
    }
    char src[128];
    AevonLandingSourceCopy(src, sizeof(src));
    AevonLogRaw([[NSString stringWithFormat:
                  @"landing: guard dead b=%s src=%s tick=%d card=%d board=%d any=%d",
                  target, src[0] != '\0' ? src : "-", tick, card, board, any] UTF8String]);
    int ok = 0;
    if (src[0] != '\0' && strcmp(src, target) != 0) ok = AevonLandOpenApp(src);
    if (!ok) ok = AevonLandOpenApp(target);
    AevonLogRaw([[NSString stringWithFormat:
                  @"landing: guard revive b=%s via=%s ok=%d",
                  target, ok ? (src[0] != '\0' ? "src" : "target") : "none", ok] UTF8String]);
    if (ok) { free(target); return; }
    // 拉不起来就强建卡：哪怕内容没投进去，至少给用户一个能关掉的窗口，
    // 不至于停在一块没有任何前台 App 的桌面上。
    AevonLogRaw([[NSString stringWithFormat:@"landing: guard card b=%s", target] UTF8String]);
    AevonOpenCardDirect(target);
    free(target);
}

static void AevonLandingGuardStart(const char *target) {
    if (target == NULL || target[0] == '\0') return;
    char *copy = strdup(target);
    if (copy == NULL) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonLandingGuardTick(copy, 0);
    });
}

/// 装落点钩子，并把两个「还没用上」的入口记进日志（只记，不钩）。
static int AevonLandingInstalled = 0;

static void AevonLandingInstall(NSMutableString *out) {
    if (AevonLandingInstalled) {
        [out appendString:@"landing: already installed in this process\n"];
        return;
    }
    AevonLandingInstalled = 1;
    SEL urlSel = NSSelectorFromString(
        @"_openURLCore:display:animating:activationSettings:origin:withResult:");
    Class owners[4] = { Nil, Nil, Nil, Nil };
    int count = AevonOwnersOf(urlSel, owners, 4);
    [out appendFormat:@"landing: url owners=%d\n", count];
    for (int i = 0; i < count; i++) {
        Method method = class_getInstanceMethod(owners[i], urlSel);
        const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
        [out appendFormat:@"landing: url cls=%@ types=%s\n",
         NSStringFromClass(owners[i]), encoding != NULL ? encoding : "?"];
        if (encoding == NULL || !AevonLandingEncodingOK(encoding)) {
            char sig[32];
            AevonLandingSig(encoding, sig, sizeof(sig));
            [out appendFormat:@"landing: url shape skip (sig=%s args=%d)\n",
             encoding != NULL ? sig : "?",
             encoding != NULL ? AevonObjectArgs(encoding) : -1];
            continue;
        }
        char sig[32];
        AevonLandingSig(encoding, sig, sizeof(sig));
        [out appendFormat:@"landing: url shape ok (sig=%s)\n", sig];
        AevonHookSlot *slot = AevonReserve("landing-url");
        if (slot == NULL) { [out appendString:@"landing: url no slot\n"]; break; }
        AevonHookSlot *mine = slot;
        id block = ^(id host, id target, id display, BOOL animating,
                     id settings, id origin, id result) {
            AevonURLCoreReplacement(host, mine->sel, target, display,
                                    animating, settings, origin, result);
        };
        if (AevonAttach(out, slot, owners[i],
                        @"_openURLCore:display:animating:activationSettings:origin:withResult:",
                        block)) {
            AevonURLCoreOriginal = (AevonURLCoreProc)slot->original;
            [out appendString:@"landing: url hooked\n"];
        }
    }

    // 只记录：Stheno 的激活口、TrollOpen 的实体口在这台系统上到底存不存在。
    // 这两行是下一版要用的证据，不是装饰 —— 报告第 7 节把它们列为「能不能做」
    // 的第一条，而它们的答案只能从运行中的进程里问出来。
    struct { const char *sel; const char *label; } probes[2] = {
        { "_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:", "activate" },
        { "overrideAppSceneEntityForLaunchingApplication:", "entity" },
    };
    for (int i = 0; i < 2; i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:probes[i].sel]);
        Class found[4] = { Nil, Nil, Nil, Nil };
        int n = sel != NULL ? AevonOwnersOf(sel, found, 4) : 0;
        if (n == 0) {
            [out appendFormat:@"landing: %s owners=0\n", probes[i].label];
            continue;
        }
        for (int k = 0; k < n; k++) {
            Method m = class_getInstanceMethod(found[k], sel);
            const char *enc = m != NULL ? method_getTypeEncoding(m) : NULL;
            [out appendFormat:@"landing: %s cls=%@ types=%s\n",
             probes[i].label, NSStringFromClass(found[k]), enc != NULL ? enc : "?"];
        }
    }
}

/// 开机就装。**必须是开机**：`AevonHookInstall` 是建第一张卡时才调的，而落点要
/// 管的恰恰是「第一张卡还不存在」的那一刻（第一次授权、第一次分享）。装晚一步，
/// `_openURLCore` 那一拍已经过去了，这一版就等于没发。
void AevonLandingBoot(void) {
    NSMutableString *out = [NSMutableString string];
    AevonLandingInstall(out);
    // 一行一条：日志是按行读的，把一整段塞进一条会让下一轮的 grep 全部落空。
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        AevonLogRaw([line UTF8String]);
    }
}

/// Installs every hook the mother ship's route needs and returns the notes.
/// Idempotent: a second tap in the same process reports the first install rather
/// than stacking a replacement on top of a replacement.
/// 0.2.32 — 幂等判据从 `AevonSlotCount` 换成独立标志。通知接口的 `nc-cap`
/// 在开机时就占一格，旧判据于是一直为真：deact 与 intercept 从未安装，
/// 0.2.31 日志里的 `hook: live=1 deact_set=0 intercept=0/0` 就是这两个被
/// 跳过的钩子。`live` 只该报告装上了几个，不该兼任「装过没有」。
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
            if (ours && !AevonPushBanned) {
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
    AevonLandingInstall(out);

    return out;
}

/// The counters and the traces, one line each. Called at the two moments when
/// the answer matters: right before the card is built, and right after it is
/// taken down.
NSString *AevonHookSummary(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"hook: live=%d deact_set=%ld stripped=%ld"
     " intercept=%ld/%ld"
     " push=%ld/%ld door=%ld armed=%@ landing=%ld/%ld\n",
     AevonSlotCount, AevonDeactSetCalls, AevonDeactStripped,
     AevonInterceptRewrote, AevonInterceptCalls,
     AevonPushWrote, AevonPushTried, AevonPushPath,
     AevonHookArmedList(), AevonURLCuts, AevonURLCalls];
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

/// 0.0.40 — the count of deactivation attempts, for the card's clock. Exposed as
/// a function rather than a global so Swift reads it the same way it reads
/// everything else in this file, and cannot cache it by accident.
long AevonDeactCount(void) {
    return AevonDeactSetCalls;
}

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

/// 0.2.26 — 回桌面那一刻的连写。写入体与 `AevonWakeScene` 完全相同，只是不走
/// 200 ms 节流：系统在「回桌面」的过渡里会把借来的 scene 判成后台，卡片随之
/// 掉一帧黑。0.2.25 真机的读数 `picture dropped cs=0 ... picture back after
/// 63ms` 里那 63 ms 就是下一拍节流的等待，不是恢复需要的时间。这里按
/// 80 ms 一拍连写几次，把那段空白压到一帧以内。
static long AevonHomeWakeTried = 0;
static const long AevonHomeWakeBudget = 12;

void AevonHomeWakeReset(void) {
    __sync_lock_test_and_set(&AevonHomeWakeTried, 0);
    AevonLastWake = 0;
}

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
    if (AevonPushBanned) return 0;
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

/// 0.2.26 — 只给「回桌面」用的连写入口：没有 200 ms 节流，额度按一次回桌面
/// 重置（`AevonHomeWakeReset`）。其余闸门与 `AevonWakeScene` 一致。
NSInteger AevonHomeWake(id scene) {
    if (scene == nil || !AevonIsArmed()) return 0;
    if (AevonPushBanned) return 0;
    if (![NSThread isMainThread]) return 0;
    if (AevonHookDepth > 0) return 0;
    if (AevonInPush) return 0;
    if (__sync_fetch_and_add(&AevonHomeWakeTried, 1) > AevonHomeWakeBudget) return 0;
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

/// 0.0.72 — 把 scene 的尺寸真正动一下再还回去，幅度由调用者给。
///
/// 0.0.70 用的是固定 -1 pt（717 → 716 → 717）。Aevon(62) 的日志里，那次轻推
/// 之后一条 `app: page transition` 都没有 —— 分不清是「1 pt 没送到 UIKit」还是
/// 「送到了、被我们自己的 8 pt 门滤掉了」。所以这一版两件事一起做：幅度给到
/// 17 pt（0.85 缩放下约 14 px，卡片首帧之前做，看不见），并且把过渡钩子里那道
/// 8 pt 的门从**日志**上拆掉 —— 下一次日志里有没有 `transition h=700`，就是
/// 「这条路通不通」的唯一判据。
///
/// 为什么是 17 pt 而不是 1 pt：UIKit 对 `viewWillTransitionToSize:` 不做幅度过滤，
/// 但 App 自己的排版层会（很多列表控制器在 `fabs(delta) < 一个阈值` 时直接 return，
/// 因为那是键盘或状态栏的高度抖动）。17 pt 跨过了常见的那几个阈值（8 / 10 / 16），
/// 又小到卡片尺寸不变形（画布仍是 717，只是内容按 700 排一拍再按 717 排）。
NSInteger AevonNudgeSceneFrame(id scene, double delta) {
    if (scene == nil) return 0;
    int slot = AevonSlotOfScene(scene);
    if (slot < 0 || !(AevonFrameMask & (1 << slot))) return 0;
    CGRect target = AevonFrameTargets[slot];
    if (target.size.height < 120.0) return 0;
    if (fabs(delta) < 0.5) delta = -17.0;
    AevonFrameTargets[slot] = CGRectMake(target.origin.x, target.origin.y,
                                         target.size.width, target.size.height + delta);
    NSInteger door = AevonPushSceneFrame(scene);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 0.12 s 内关卡了：`AevonSceneFrameClear` 已经把目标抹掉，这里不该再写。
        if (!(AevonFrameMask & (1 << slot))) return;
        AevonFrameTargets[slot] = target;
        AevonPushSceneFrame(scene);
    });
    return door;
}

// MARK: - 通知点击 → 悬浮窗（0.1.45：只普查，不挂钩）
//
// 母本取证（主库 `Stheno.dylib` 的 Swift 侧）：类
// `_TtC6Stheno29UNSUserNotificationServerHook`（Orion 的 Glue 生成物），配套的
// 选择器/常量按二进制顺序是
//    UINotificationResponseAction
//    _dismissPresentable:withReason:animated:userInfo:
//    initWithURL:workspaceOriginatingProcess:
//    UIApplicationLaunchOptionsSourceApplicationKey
//    unlockedEnvironmentMode
//    continuousExposeIdentifier
// 也就是：识别「通知回应」这个 action → 收起当时的 presentable（通知中心/横幅）
// → 用 URL + 来源进程构造一次 workspace 请求。
//
// 0.1.40~0.1.44 在 SpringBoard 侧试过三条路，全部被真机否掉：
//   · `SBMainWorkspace -executeTransitionRequest:` —— 挂上了（`notify: armed`），
//     但 Aevon(117)/Aevon(118) 两份日志里**零调用**（没有 `notify: req`）。
//   · `UNSUserNotificationServer -presentPresentable:withOptions:userInfo:` ——
//     方法名确实在母本 `__objc_methname` 里，但这个类在 SpringBoard 里不存在
//     （`present probe ...=0 hooked=0`）。
//   · `NCNotificationDispatcher` / `SBNotificationBannerDestination` —— 同样不存在。
//
// 所以 0.1.45 起**一个通知钩子都不装**，只做只读普查：0.1.44 的
// `objc_getClassList` 已经列出 SpringBoard 里 70 个含 Notification 的类，其中
// `SBNCNotificationDispatcher`、`SBDashBoardNotificationPresenter`、
// `SBUserNotificationCenter` 都在 —— 这一版把它们的通知相关方法名列出来，
// 下一版按**真实存在的方法名**精确挂，不再按名字赌。
//
// 仍然不自己调 dismiss：`openCard` 把 App 的 scene 推到前台，SpringBoard 会收起
// 通知中心（系统自己的「打开 App 就收起覆盖层」）。真机上如果日志出现
// `notify: open` 而通知中心还挂着，下一版再加显式 `_dismissPresentable:`。

static double AevonNotifyLastAt = 0;
static int AevonNotifyNotes = 0;

static void AevonNotifyLog(NSString *line) {
    if (AevonNotifyNotes >= 12) return;
    AevonNotifyNotes += 1;
    AevonLogRaw(line.UTF8String);
}

/// KVC 取值，任何一步不成立都返回 nil。`@try` 在这里是必须的：`valueForKey:`
/// 碰到没有的键会抛 `NSUndefinedKeyException`，而这条链跑在 SpringBoard 主线程上。
static id AevonNotifyValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    SEL sel = NSSelectorFromString(key);
    if (![object respondsToSelector:sel]) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

/// 从通知 action 上取被点 App 的 bundle id。三个落点按母本用过的顺序试：
/// 启动选项里的来源 App、action 自己的 `application`、以及通知请求的 section。
static NSString *AevonNotifyBundle(id action) {
    id info = AevonNotifyValue(action, @"userInfo");
    if ([info isKindOfClass:[NSDictionary class]]) {
        id source = ((NSDictionary *)info)[@"UIApplicationLaunchOptionsSourceApplicationKey"];
        if ([source isKindOfClass:[NSString class]] && [source length] > 2) return source;
    }
    id application = AevonNotifyValue(action, @"application");
    id bundle = AevonNotifyValue(application, @"bundleIdentifier");
    if ([bundle isKindOfClass:[NSString class]] && [bundle length] > 2) return bundle;
    id request = AevonNotifyValue(action, @"notificationRequest");
    id section = AevonNotifyValue(request, @"sectionIdentifier");
    if ([section isKindOfClass:[NSString class]] && [section length] > 2) {
        // `sectionIdentifier` 通常就是 bundle id；带后缀的（线程分组）截掉。
        NSRange slash = [section rangeOfString:@"/"];
        if (slash.location != NSNotFound) section = [section substringToIndex:slash.location];
        return section;
    }
    return nil;
}

/// 顶层的类名，nil 安全。
static NSString *AevonNotifyCls(id object) {
    if (object == nil) return @"nil";
    return NSStringFromClass([object class]) ?: @"?";
}

// MARK: - 0.1.42 母本那条链：`UNSUserNotificationServer -presentPresentable:withOptions:userInfo:`
//
// 母本主库 `Stheno.dylib` 的证据（arm64e 切片）：
//   · `__objc_methname` 里唯一一条通知相关的方法是 `presentPresentable:withOptions:userInfo:`
//     —— 也就是 Swift 类 `_TtC6Stheno29UNSUserNotificationServerHook` 覆盖的那一个；
//   · `__cstring` 里另有两条 Swift 字面量 `UINotificationResponseAction` 与
//     `_dismissPresentable:withReason:animated:userInfo:`，配合
//     `performSelector:withObject:withObject:` 使用 —— 先认「通知回应」这个 action，
//     再显式收起当时那个 presentable（通知中心 / 横幅）。
//
// 0.1.42 在这一侧挂一条：只挂母本那个类、只挂那个方法，且**先调原实现、再取证**。
// 认不出「通知回应」就什么都不做 —— 宁可这条不生效，也不能在 SpringBoard 主线程上
// 靠猜调用。

static IMP AevonOrigPresent = NULL;
static int AevonNotifyPresentNotes = 0;

/// 在 options / userInfo 这两层字典里找「通知回应」那个 action。
/// 只看两层、只认类名 —— 不猜字段名，也不递归对象图。
static id AevonNotifyFindResponse(id object, int depth) {
    if (object == nil || depth <= 0) return nil;
    if ([AevonNotifyCls(object) rangeOfString:@"NotificationResponse"
                                      options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return object;
    }
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    for (id key in (NSDictionary *)object) {
        id value = ((NSDictionary *)object)[key];
        if ([value isKindOfClass:[NSString class]]) continue;
        if ([AevonNotifyCls(value) rangeOfString:@"NotificationResponse"
                                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return value;
        }
        if ([value isKindOfClass:[NSDictionary class]]) {
            id deep = AevonNotifyFindResponse(value, depth - 1);
            if (deep != nil) return deep;
        }
    }
    return nil;
}

/// `presentPresentable:withOptions:userInfo:` 的替身。**先调原实现**，再取证：
/// 通知要不要弹、怎么弹是系统的事，我们只在它做完之后判断「这是不是一次点击」。
static void AevonNotifyPresent(id self, SEL _cmd, id presentable, id options, id userInfo) {
    if (AevonOrigPresent == NULL) return;
    ((void (*)(id, SEL, id, id, id))AevonOrigPresent)(self, _cmd, presentable, options, userInfo);
    @try {
        if (AevonNotifyPresentNotes < 12) {
            AevonNotifyPresentNotes += 1;
            AevonNotifyLog([NSString stringWithFormat:@"notify: present cls=%@ opt=%@ info=%@",
                            AevonNotifyCls(presentable), AevonNotifyCls(options),
                            AevonNotifyCls(userInfo)]);
        }
        id response = AevonNotifyFindResponse(presentable, 2);
        if (response == nil) response = AevonNotifyFindResponse(options, 2);
        if (response == nil) response = AevonNotifyFindResponse(userInfo, 2);
        if (response == nil) return;
        NSString *bundle = AevonNotifyBundle(response);
        AevonNotifyLog([NSString stringWithFormat:@"notify: response cls=%@ bundle=%@",
                        AevonNotifyCls(response), bundle ?: @"?"]);
        if (bundle.length < 3) return;
        if ([bundle hasPrefix:@"com.apple.springboard"]) return;
        double now = CFAbsoluteTimeGetCurrent();
        if (now - AevonNotifyLastAt < 10.0) return;
        AevonNotifyLastAt = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonOpenFromNotification(bundle.UTF8String);
        });
    } @catch (NSException *exception) {
        AevonNotifyLog([NSString stringWithFormat:@"notify: present threw %@", exception.name]);
    }
}

// MARK: - 0.1.44 通知：先普查，再挂钩
//
// 真机日志（Aevon(117)，0.1.43）：
//   notify: armed
//   notify: present probe UNSUserNotificationServer=0 NCNotificationDispatcher=0
//                            SBNotificationBannerDestination=0 hooked=0
// 三个类在 SpringBoard 里**全部不存在** ⇒ 0.1.42 补的那一路（母本那条
// `presentPresentable:`）连挂都挂不上；而 `SBMainWorkspace -executeTransitionRequest:`
// 虽然挂上了（`armed`），却在整个日志里一次都没被调用过（没有 `notify: req`）。
// 也就是说：通知点击在 iOS 17.3 的 SpringBoard 里既不走那个 transition 方法，
// 也不经过这三个类。
//
// 继续按名字猜就是赌。这一版只做一件事：把 SpringBoard 里真实存在的类名列出来，
// 把关键类上含 transition / activate / notification 的方法名列出来，一次装机
// 拿到全部真名，下一版按真名挂。

static void AevonNotifyCensus(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) {
        AevonLogRaw("notify: census unavailable");
        return;
    }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (list == NULL) return;
    total = objc_getClassList(list, total);
    NSMutableString *hits = [NSMutableString string];
    int count = 0;
    for (int i = 0; i < total && count < 70; i++) {
        const char *name = class_getName(list[i]);
        if (name == NULL || strlen(name) > 70) continue;
        if (strstr(name, "Notification") == NULL && strstr(name, "notification") == NULL) continue;
        [hits appendFormat:@"%s ", name];
        count += 1;
    }
    free(list);
    AevonLogRaw([[NSString stringWithFormat:@"notify: census n=%d %@", count,
                  count > 0 ? hits : @"(none)"] UTF8String]);
}

/// 把某个类（含最多 4 层父类）上方法名里含 `needle` 的前 16 条打出来。只读。
///
/// 0.1.45 — 加父类链：`SBNCNotificationDispatcher` 这类「XXDispatcher」的实际入口
/// 常常在父类里，只列本类会漏掉真正该挂的那一条。
static void AevonNotifyMethods(const char *className, const char *needle) {
    Class cls = objc_getClass(className);
    if (cls == Nil) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: %s absent", className] UTF8String]);
        return;
    }
    NSMutableString *hits = [NSMutableString string];
    int count = 0;
    Class walk = cls;
    int depth = 0;
    while (walk != Nil && depth < 4 && count < 16) {
        unsigned int n = 0;
        Method *methods = class_copyMethodList(walk, &n);
        if (methods != NULL) {
            for (unsigned int i = 0; i < n && count < 16; i++) {
                const char *sel = sel_getName(method_getName(methods[i]));
                if (sel == NULL) continue;
                if (strcasestr(sel, needle) == NULL) continue;
                [hits appendFormat:@"%s ", sel];
                count += 1;
            }
            free(methods);
        }
        walk = class_getSuperclass(walk);
        depth += 1;
    }
    AevonLogRaw([[NSString stringWithFormat:@"notify: %s~%s n=%d %@",
                  className, needle, count, count > 0 ? hits : @"(none)"] UTF8String]);
}

/// 0.1.86 — 定义在文件末尾（普查那一段）。这里先声明：装配这条路在本函数里，
/// 而普查是纯只读的，晚一步再定义不影响阅读顺序。
void AevonActivateSurfaceCensus(void);

/// 0.1.99 — 同上。清通知那两件（取 dispatcher、打能力地图）定义在下面几千行处，
/// 而开机取证要在这里排期。
static id AevonCleanDispatcher(void);
static void AevonClearMap(id dispatcher);

void AevonNotificationOpenInstall(void) {
    static int installed = 0;
    if (installed) return;
    installed = 1;

    // 0.1.45 — **不再挂任何 transition 钩子**。
    //
    // 0.1.40~0.1.44 在这条路上试过三种写法：`executeTransitionRequest:`（0.1.40）、
    // `_executeTransitionRequest:options:validator:` 与 `_executeApplicationTransitionRequest:`
    // 的同族方法、以及在 `UNSUserNotificationServer` 上挂 `presentPresentable:`（0.1.42）。
    // 真机 0.1.44 的结论是硬的：
    //   · `executeTransitionRequest:` 挂上了（`notify: armed`）但整份日志零调用；
    //   · `UNSUserNotificationServer` / `NCNotificationDispatcher` /
    //     `SBNotificationBannerDestination` 三个类在 SpringBoard 里**都不存在**。
    // 再按名字猜就是赌。这一版只把真名查出来。
    AevonLogRaw("notify: census pass, activate probe separate (0.1.86)");

    // 0.1.86 — 激活面普查。**不挂在闩上**：闩管的是「换 IMP」那件危险事，
    // 而普查一行都不改，没有理由让一次历史崩溃把它一起关掉。启动后 10 秒再跑，
    // 让 SpringBoard 自己把镜像加载完，别和开机抢 objc 的类锁。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        AevonActivateSurfaceCensus();
    });

    // 0.1.99 — 清通知的能力地图改挂到**开机**，不再只挂在「点通知」那一拍。
    //
    // 它原来只被 `AevonNotifyCleanup` / `AevonClearNotification` 调用，而这两条路都
    // 要求先点一次通知才进得去。Aevon(161) 之后的三份日志里，用户一次都没点通知 ——
    // 于是「dispatcher 到底取到没有、四个 destination 叫什么、谁支持 withdraw」
    // 这张地图从来没能保存到磁盘。没有它，下一版改清通知只能接着猜。
    //
    // 25 秒的由来：通知栈是懒加载的（真机实测 3 秒时 `NCNotificationDispatcher` 还不存在、
    // 10 秒才出现），而四个 destination 比 dispatcher 更晚。给足余量不影响任何行为 ——
    // 这一段只读，一个字节都不改。
    //
    // 必须在主队列：`AevonCleanDispatcher` 走 `UIApplication.sharedApplication.delegate`，
    // 在后台线程读 UIApplication 是未定义行为。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonClearMap(AevonCleanDispatcher());
    });

    // 第二路（0.1.42 起）保留：只探不猜。类不存在就什么都不发生；真机上存在时
    // 才挂 `UNSUserNotificationServer -presentPresentable:withOptions:userInfo:`。
    SEL present = NSSelectorFromString(@"presentPresentable:withOptions:userInfo:");
    NSArray<NSString *> *candidates = @[@"UNSUserNotificationServer",
                                        @"NCNotificationDispatcher",
                                        @"SBNotificationBannerDestination"];
    NSMutableString *found = [NSMutableString string];
    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name);
        if (cls == Nil) {
            [found appendFormat:@" %@=0", name];
            continue;
        }
        Method m = class_getInstanceMethod(cls, present);
        [found appendFormat:@" %@=%d", name, m != NULL ? 1 : 0];
        if (m == NULL || AevonOrigPresent != NULL) continue;
        if (![name isEqualToString:@"UNSUserNotificationServer"]) continue;  // 只挂母本那个类
        AevonOrigPresent = method_getImplementation(m);
        method_setImplementation(m, (IMP)AevonNotifyPresent);
    }
    NSString *line = [NSString stringWithFormat:@"notify: present probe%@ hooked=%d",
                      found, AevonOrigPresent != NULL ? 1 : 0];
    AevonLogRaw(line.UTF8String);

    // 普查：0.1.44 已经用 `objc_getClassList` 证明存在的类，这一次列它们的
    // 通知相关方法名。下一版按真名精确挂，不再猜。
    AevonNotifyCensus();
    AevonNotifyMethods("SBMainWorkspace", "transition");
    // 0.1.85 — 激活总入口的真名。stheno 的取证结论是
    // `_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:`，
    // 而它出自 iOS 15/16 的那台机器。这一段是「换一台机器还叫这个名字吗」的
    // 唯一答案来源：真的不叫这个，这三行的列表里会有真名。
    AevonNotifyMethods("SBMainWorkspace", "activate");
    AevonNotifyMethods("SBMainWorkspace", "bundle");
    AevonNotifyMethods("SBWorkspace", "activate");
    AevonNotifyMethods("SBWorkspace", "notification");
    AevonNotifyMethods("SBLockScreenManager", "notification");

    AevonNotifyMethods("SBNCNotificationDispatcher", "notification");
    AevonNotifyMethods("SBNCNotificationDispatcher", "present");
    AevonNotifyMethods("SBNCNotificationDispatcher", "dismiss");
    AevonNotifyMethods("SBNCNotificationDispatcher", "action");
    AevonNotifyMethods("SBNCNotificationDispatcher", "tap");

    AevonNotifyMethods("SBDashBoardNotificationPresenter", "present");
    AevonNotifyMethods("SBDashBoardNotificationPresenter", "dismiss");
    AevonNotifyMethods("SBDashBoardNotificationPresenter", "action");

    AevonNotifyMethods("SBUserNotificationCenter", "notification");
    AevonNotifyMethods("SBUserNotificationCenter", "response");
    AevonNotifyMethods("SBUserNotificationCenter", "activate");
}

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

enum { AevonOpenMax = 4 };

typedef struct {
    const char *sel;
    const char *tag;
} AevonOpenTarget;

static const AevonOpenTarget AevonOpenTargets[AevonOpenMax] = {
    {"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:", "open"},
    {"_handleUntrustedOpenRequestForApplication:options:activationSettings:origin:withResult:", "untrusted"},
    {"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:", "trusted"},
    {"_handleUserActionRequest:options:activationSettings:origin:withResult:", "user"},
};

/// 原实现。**只在换 IMP 的前一行赋值**，赋不上就不换 —— 一个拿不到原实现的
/// 替身会把整条 App 激活吞掉，那不是「观察」，是让手机打不开应用。
static IMP AevonOpenOrig[AevonOpenMax] = {NULL, NULL, NULL, NULL};

/// 注册时的 SEL 地址。替身靠它反查「这一拍是四条里的哪条」——比在热路径上
/// `sel_getName` 再比字符串便宜得多。
static SEL AevonOpenSel[AevonOpenMax] = {NULL, NULL, NULL, NULL};

static int AevonOpenPer[AevonOpenMax] = {0, 0, 0, 0};
static int AevonOpenTotal = 0;

/// `options` 的键名只在前三拍打。母本用的是 `__PayloadOptions` / `__Actions` 两个
/// 私有键，而它们出自 iOS 15/16 —— 键名一变，字段就全是 nil，而那与「没有通知
/// 点击」在日志里长得一模一样。这一行是唯一能把两者分开的东西。
static int AevonOpenKeyNotes = 0;

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
static double AevonDivertAt = 0;
static char AevonDivertBundle[64] = {0};

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
static int AevonDivertCount = 0;
static double AevonDivertWindow = 0;
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

static AevonLoopSlot AevonLoopSlots[AEVON_LOOP_SLOTS];
static int AevonLoopNotes = 0;

/// 一次分流真的发生了：给它那个 bundle 记一笔连击。
static void AevonLoopNote(const char *bundle) {
    if (bundle == NULL || bundle[0] == '\0') return;
    double now = CFAbsoluteTimeGetCurrent();
    int slot = -1;
    for (int i = 0; i < AEVON_LOOP_SLOTS; i++) {
        if (strcmp(AevonLoopSlots[i].bundle, bundle) == 0) {
            if (now - AevonLoopSlots[i].at > AEVON_LOOP_WINDOW) AevonLoopSlots[i].streak = 0;
            AevonLoopSlots[i].at = now;
            AevonLoopSlots[i].streak += 1;
            return;
        }
        if (slot < 0 && (AevonLoopSlots[i].bundle[0] == '\0' ||
                         now - AevonLoopSlots[i].at > AEVON_LOOP_WINDOW)) {
            slot = i;
        }
    }
    if (slot < 0) {
        // 四个槽都还热着：挤掉最旧的那一个。挤错不会漏拦 —— 漏掉的只是连击计数。
        slot = 0;
        for (int i = 1; i < AEVON_LOOP_SLOTS; i++) {
            if (AevonLoopSlots[i].at < AevonLoopSlots[slot].at) slot = i;
        }
    }
    snprintf(AevonLoopSlots[slot].bundle, sizeof(AevonLoopSlots[slot].bundle), "%s", bundle);
    AevonLoopSlots[slot].at = now;
    AevonLoopSlots[slot].streak = 1;
}

/// 0 = 放行分流；1 = 全局上限；2 = 同一个 App 连击。
///
/// `bundle` 为 NULL 时只查全局那一把 —— 调用点在解析出目标之前也要先问一次，
/// 否则「解析失败」与「被上限挡住」在日志里长得一样。
static int AevonDivertCapKind(const char *bundle) {
    double now = CFAbsoluteTimeGetCurrent();
    if (AevonDivertWindow <= 0 || now - AevonDivertWindow > AEVON_DIVERT_WINDOW) {
        AevonDivertWindow = now;
        AevonDivertCount = 0;
    }
    if (AevonDivertCount >= AEVON_DIVERT_MAX) return 1;
    if (bundle == NULL || bundle[0] == '\0') return 0;
    for (int i = 0; i < AEVON_LOOP_SLOTS; i++) {
        if (strcmp(AevonLoopSlots[i].bundle, bundle) != 0) continue;
        if (now - AevonLoopSlots[i].at > AEVON_LOOP_WINDOW) return 0;
        if (AevonLoopSlots[i].streak < AEVON_LOOP_MAX) return 0;
        if (AevonLoopNotes < 8) {
            AevonLoopNotes += 1;
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: divert loop b=%s n=%d",
                          bundle, AevonLoopSlots[i].streak] UTF8String]);
        }
        return 2;
    }
    return 0;
}

/// 「认出来了却没分流」的解释行单独计数，不占 `AevonOpenKeyNotes` 的键名预算 ——
/// 两个预算合用一个计数器，先跑完的那个会把另一个静音。
static int AevonDivertNotes = 0;

/// 0.2.7 — 放行侧（`notify: divert pass`）自己的预算。
///
/// 与 `AevonDivertNotes` 分开是必须的：通知路径每点一次都会写一到两行
/// （`capture only` / `clear=noid`），共用 6 条预算的话，第三次点击之后
/// 放行侧就永久静默 —— 分享那条路在 Aevon(175) 里就是这么消失的。
static int AevonPassDivertNotes = 0;

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

/// 0.1.99 — **放行也要说原因**，而且用独立的预算。
///
/// Aevon(167) 里 QQ 那一次分享有一条 `notify: hit op=user … src=…ShareExtension`，
/// 后面紧跟的却是另一条请求的 divert 行 —— 也就是说这条被**放行**了。而同一份日志里
/// Sileo / TrollStore 没有任何一条这样的请求，它们只出小窗不出全屏。全屏的来源因此
/// 高度怀疑就在这条被放行的请求上，但现有代码对 `plain` / `nobundle` 刻意沉默，
/// 于是「为什么放行」这一格永远是空的。
///
/// 预算 40 条、独立计数：它不能和 divert 的解释行共用一个计数器，
/// 否则先跑完的那个会把另一个静音（0.1.93 那次六条配额用尽就是这么来的）。
static int AevonPassNotes = 0;

/// 下面几个取值函数都用 `AevonActRead`，而它写在更下面（读键的实现挨着读键的
/// 注释）。C 里先声明后使用，这一行是声明。
static id AevonActRead(id object, NSString *key);

/// `options` 可能是个裸字典，也可能是个带 `dictionary` 的包装对象。
static id AevonOpenDict(id options) {
    if (options == nil) return nil;
    if ([options isKindOfClass:[NSDictionary class]]) return options;
    id inner = AevonActRead(options, @"dictionary");
    return [inner isKindOfClass:[NSDictionary class]] ? inner : nil;
}

/// 目标 App 的 bundle id。
///
/// 三个取值点按真机顺序排：`request` 自己是字符串（0.1.87 实测就是这一种，它
/// 直接就是 bundle id）→ `request.application.bundleIdentifier`（母本那套对象
/// 形状）→ `request.bundleIdentifier`。全落空返回 nil，调用方据此不接管。
static id AevonOpenBundleOf(id request) {
    if ([request isKindOfClass:[NSString class]]) return request;
    id app = AevonActRead(request, @"application");
    id bundle = app != nil ? AevonActRead(app, @"bundleIdentifier") : nil;
    if (![bundle isKindOfClass:[NSString class]]) {
        bundle = AevonActRead(request, @"bundleIdentifier");
    }
    return [bundle isKindOfClass:[NSString class]] ? bundle : nil;
}

/// 这次「开 App」是谁发起的。
///
/// `__PayloadOptions[UIApplicationLaunchOptionsSourceApplicationKey]`。0.1.88 起
/// 这一格在快照里一直有打印，两种真机结果都见过：
///
///   · 点通知：`src=-` —— 这一层根本没有 `__PayloadOptions` 这个键（Aevon(155)）；
///   · 分享面板：`src=com.apple.sharingd`（Aevon(155) 同一份日志里那句
///     `notify: hit op=open b=- src=com.apple.sharingd act=- n=0 req=org.coolstar.SileoStore`）。
///
/// 0.1.92 起它不再只是日志：分享面板的判据就是这一格。抽成函数是为了让快照与
/// 判据读**同一个地方** —— 两处各写一遍，迟早出现「日志说 sharingd 但没分流」。
static id AevonOpenPayload(id request, id options) {
    id payload = AevonActRead(options, @"__PayloadOptions");
    if (payload == nil) payload = AevonActRead(request, @"__PayloadOptions");
    if (payload == nil) payload = AevonActRead(options, @"payloadOptions");
    return payload;
}

static id AevonOpenSourceApp(id request, id options) {
    id payload = AevonOpenPayload(request, options);
    if (payload == nil) return nil;
    id from = AevonActRead(payload, @"UIApplicationLaunchOptionsSourceApplicationKey");
    return [from isKindOfClass:[NSString class]] ? from : nil;
}

/// `options.__Actions` 的第一个元素 —— 点通知时它就是 `UINotificationResponseAction`。
/// 键名是私有键，换系统版本可能变，所以退路依次是 `request` 和 `actions`。
static id AevonOpenFirstAction(id request, id options) {
    id actions = AevonActRead(options, @"__Actions");
    if (actions == nil) actions = AevonActRead(request, @"__Actions");
    if (actions == nil) actions = AevonActRead(options, @"actions");
    if (![actions isKindOfClass:[NSArray class]]) return nil;
    if ([(NSArray *)actions count] == 0) return nil;
    return [(NSArray *)actions objectAtIndex:0];
}

/// 「这是一次通知点击」唯一的判据。用类名而不是 `respondsToSelector:`：动作对象
/// 的私有选择器在两代系统之间改过名（母本用的 `defaultAction` 在 17 上就没有），
/// 而类名是从 UIKit 自己那儿来的，改它等于改整个通知回应的实现。
static BOOL AevonOpenIsNotificationAction(id action) {
    if (action == nil) return NO;
    const char *name = class_getName([action class]);
    return name != NULL && strstr(name, "NotificationResponseAction") != NULL;
}

/// 「这是一次分享面板的跳转」的第一条判据：来源进程是分享链路。
///
/// 判据不猜名字、也不看 action 数量（分享是 `act=- n=0`，但点图标也是 0）：
/// 只看来源。0.1.87 的真机日志里那句分享对照行是第一条证据 —— `src=com.apple.sharingd`。
/// **取不到来源就一律不开**：`src` 为空时可能是点图标、也可能是别的系统路径，
/// 把它们一起吞掉就是「点图标没反应」，比不做这个功能糟得多。
static BOOL AevonOpenIsShareSource(id request, id options) {
    id from = AevonOpenSourceApp(request, options);
    if (from == nil) return NO;
    const char *raw = [(NSString *)from UTF8String];
    if (raw == NULL) return NO;
    if (strstr(raw, "sharingd") != NULL) return YES;
    // 0.1.97：Aevon(163) 真机把「分享给第三方 App」的另外两条形状也照下来了 ——
    // QQ 走它自己的分享扩展 `src=com.tencent.mqq.ShareExtension`，微信走
    // `src=com.tencent.xin.sharetimeline`。它们不经过 sharingd，所以旧判据一条都没放进来，
    // 表现就是用户看到的「分享文件时全屏打开、没有浮窗」。
    if (strstr(raw, "ShareExtension") != NULL) return YES;
    if (strstr(raw, "sharetimeline") != NULL) return YES;
    return NO;
}

/// 这次打开是 SpringBoard 自己发起的（`src=com.apple.springboard`）。
///
/// 0.2.1 — 「带 payload 就算分享」那条判据必须把这一种来源排掉。Aevon(169) 里
/// 14 条 `notify: share … src=com.apple.springboard pay=payload` 全不是分享：通知
/// 这条链派生出来的后续请求也带着 `__PayloadOptions`，于是被当成分享 —— 既不去
/// 清通知（走的是 share 分支，那一整段都跳过），又每次都白交一次原实现
/// （日志里的 `notify: forward done err`）。
///
/// 真分享的三种来源（`sharingd` / `…ShareExtension` / `…sharetimeline`）在
/// Aevon(162)(163)(165)(167) 四份日志里没有一次是 springboard。
static BOOL AevonOpenSourceIsSpringBoard(id request, id options) {
    id from = AevonOpenSourceApp(request, options);
    if (from == nil) return NO;
    const char *raw = [(NSString *)from UTF8String];
    if (raw == NULL) return NO;
    return strstr(raw, "com.apple.springboard") != NULL;
}

/// 顶层 payload 的三种痕迹任取其一。键都在 `options` 上，`request` 兜一次。
///
/// Aevon(163) 的真机形状（`keys=` 那一格就是 options 的全部键）：
///   · 分享给 QQ：`keys=__PayloadOptions,__PayloadURL,__PasteSharingToken`
///   · 分享给微信：`keys=`（空 —— 所以只能靠来源进程认）
///   · 打开相册：`keys=__LaunchIntent,__LaunchSceneless,__ActivateSuspended,…`
///   · 点桌面图标：没有 `keys=` 这一格
static id AevonOpenAnyValue(id request, id options, NSString *key) {
    id value = AevonActRead(options, key);
    if (value == nil) value = AevonActRead(request, key);
    return value;
}

/// 「这一次打开带没带东西」——`none` / `url` / `paste` / `payload`。
///
/// 这一格同时是日志判据和转发闸：**只有带东西才值得交回系统**（交回去是为了让系统
/// 把文件拷进目标 App 的 Inbox）。0.1.96 用的是
/// `__PayloadOptions[UIApplicationLaunchOptionsURLKey]`，而 Aevon(163) 里 Sileo / Filza
/// 那条路读出来是 `url=0` —— 真正装着东西的是**顶层 `__PayloadURL`**，所以那一版的
/// 转发一次都没触发。
static const char *AevonOpenPayloadKind(id request, id options) {
    if (AevonOpenAnyValue(request, options, @"__PayloadURL") != nil) return "url";
    if (AevonOpenAnyValue(request, options, @"__PasteSharingToken") != nil) return "paste";
    id payload = AevonOpenPayload(request, options);
    if (payload != nil) {
        if (AevonActRead(payload, @"UIApplicationLaunchOptionsURLKey") != nil) return "url";
        return "payload";
    }
    return "none";
}

static BOOL AevonOpenCarriesPayload(id request, id options) {
    return strcmp(AevonOpenPayloadKind(request, options), "none") != 0;
}

/// 0.2.59 — 这条 URL 是不是「登录 / 授权」那一族。
///
/// 为什么要按 URL 认，而不是按 scheme 白名单：微信 / QQ 的 SDK 每一版换一种承载
/// ——`weixin://`、`mqqopensdkapi://`、通用链接 `https://help.wechat.com/app/<appid>/auth/`。
/// Aevon(200) 里微信登录落在最后那一种上：`url=https len=670`，路径里有 `/auth/`。
/// 白名单每漏一条，用户看到的就是「又先全屏了」，所以这里只认**路径里的语义**
/// （`/auth/` `/oauth` `open.weixin.qq.com` …），不认具体域名顺序。
///
/// 只读字符串、不碰对象，返回 0/1。
static int AevonOpenIsAuthURL(NSString *url) {
    if (![url isKindOfClass:[NSString class]] || url.length < 8) return 0;
    NSString *low = [url lowercaseString];
    static const char *marks[] = {
        "/auth/", "/auth?", "/oauth", "oauth2/authorize",
        "mqqopensdkssologin://", "mqqopensdkapi://", "weixin://",
        "open.weixin.qq.com", "help.wechat.com", "graph.qq.com",
    };
    for (size_t i = 0; i < sizeof(marks) / sizeof(marks[0]); i++) {
        NSString *mark = [NSString stringWithUTF8String:marks[i]];
        if ([low rangeOfString:mark].location != NSNotFound) return 1;
    }
    return 0;
}

/// 0.2.59 — 来源是不是微信 / QQ。SSO 回跳只有一个来源：刚处理完授权的那一方。
///
/// ⚠️ 它同时是「微信分享给别的 App」的来源，所以**不能单独当回跳判据**：
/// 分享带 `UIActivityContinuationAction`，回跳没有（Aevon(200) 的两条现场：
/// 回跳 `ac=-`，分享 `ac=#UIActivityContinuationAction`）。两者要一起看。
static int AevonOpenSourceIsSso(id request, id options) {
    NSString *src = AevonOpenSourceApp(request, options);
    if (![src isKindOfClass:[NSString class]] || src.length < 8) return 0;
    if ([src hasPrefix:@"com.tencent.xin"]) return 1;
    if ([src hasPrefix:@"com.tencent.mqq"]) return 1;
    return 0;
}

/// 0.2.60 — **目标**是不是微信 / QQ 本身（含它们的扩展）。
///
/// 与上一条正好相反：上一条问「谁递来的」，这一条问「要打开谁」。
/// 分享给 QQ 的现场是 `b=com.tencent.mqq` + `src=com.tencent.mqq.ShareExtension`
/// —— 送信方与收信方是同一家，那是**分享**；SSO 回跳的收信方永远是第三方 App。
/// 0.2.59 只看了送信方与续接动作，于是所有「分享到 QQ / 微信」都被当成回跳放行，
/// 屏幕上只剩全屏，一张卡都没有（Aevon(201) 的 18:49:06 与 18:50:20 两条）。
static int AevonOpenTargetIsSso(const char *bundle) {
    if (bundle == NULL) return 0;
    return (strncmp(bundle, "com.tencent.xin", 15) == 0 ||
            strncmp(bundle, "com.tencent.mqq", 15) == 0) ? 1 : 0;
}

/// 0.2.50 — 这一次是不是「分享面板递过来的」（`UIActivityContinuationAction`）。
///
/// 真机日志里两类请求长得几乎一样（都带来源 App、都可能带 paste token 和 URL）：
///   · 分享：`act=#UIActivityContinuationAction n=1`（0.2.48/0.2.49 每一次）；
///   · 登录：`act=- n=0`（14:42:31 / 14:55:22 两次微信、QQ 授权）。
/// 只差这一位，0.2.49 用它把 https 通用链接的登录和 https 链接的分享分开：
/// 后者必须原样交给系统（分享内容在系统那次激活里），前者才能本地投递。
static int AevonOpenIsContinuation(id request, id options) {
    id act = AevonOpenFirstAction(request, options);
    if (act == nil) return 0;
    const char *name = object_getClassName(act);
    return (name != NULL && strstr(name, "UIActivityContinuationAction") != NULL) ? 1 : 0;
}

static id AevonActRead(id object, NSString *key);

/// 0.2.53 — 这一次是不是「用户点了一个网页链接」。
///
/// 通用链接（`https://`）会先被系统解析到声明了 Associated Domains 的那个 App：
/// 用户点 GitHub 链接时，SpringBoard 收到的请求目标是 GitHub App，`__PayloadURL`
/// 里没有 URL —— URL 装在 `__UserActivity4LS.webpageURL`，activityType 是
/// `NSUserActivityTypeBrowsingWeb`。0.2.51 把这类请求当普通 App 打开放行，
/// 于是 GitHub App 先整屏弹一下、再由它转去 Safari（用户看到的「多一步跳转」）。
///
/// 只认这一种形状：有 browsing-web 活动，且没有 paste token。分享、深链回调、
/// 从桌面点图标都不会命中。
static int AevonOpenIsBrowsingWeb(id request, id options) {
    id activity = AevonOpenAnyValue(request, options, @"__UserActivity4LS");
    if (activity == nil) {
        id payload = AevonOpenPayload(request, options);
        if (payload != nil) {
            activity = AevonActRead(payload, @"UIApplicationLaunchOptionsUserActivityKey");
        }
    }
    id type = AevonActRead(activity, @"activityType");
    if (![type isKindOfClass:[NSString class]]) return 0;
    return [(NSString *)type isEqualToString:@"NSUserActivityTypeBrowsingWeb"] ? 1 : 0;
}

static void AevonOpenKeysOf(id options, char *out, size_t size);

/// 0.2.51 — 「长得像 URL 的那个值」。
///
/// 0.2.50 的 QQ 授权现场是 `pay=url` 却取不到 URL：它躺在某个我们还没点名的键下面。
/// 0.2.49 猜 `__PayloadURL`、0.2.50 猜 `__UserActivity4LS.webpageURL`，两次都没中；
/// 再猜第三个键名只是把同一件事推迟一版。这里按形状找：只认 NSURL 和带 scheme 的
/// 字符串，最多下潜两层，其它一律不看（来源 bundle id、ticket 之类不会被误取）。
static NSString *AevonOpenScanURL(id container, int depth) {
    if (container == nil || depth > 2) return nil;
    @try {
        if ([container isKindOfClass:[NSURL class]]) {
            return [(NSURL *)container absoluteString];
        }
        if ([container isKindOfClass:[NSString class]]) {
            NSString *text = (NSString *)container;
            if (text.length < 8 || text.length > 4096) return nil;
            const char *raw = text.UTF8String;
            if (raw == NULL) return nil;
            static const char *prefixes[] = {
                "http://", "https://", "weixin://", "weixinapp://", "mqq://",
                "mqqapi://", "mqqopensdk", "mqqwpa://", "wx", NULL
            };
            for (int i = 0; prefixes[i] != NULL; i++) {
                if (strncmp(raw, prefixes[i], strlen(prefixes[i])) == 0) return text;
            }
            return nil;
        }
        if ([container isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)container) {
                NSString *found = AevonOpenScanURL([(NSDictionary *)container objectForKey:key],
                                                   depth + 1);
                if (found != nil) return found;
            }
            return nil;
        }
        if ([container isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)container) {
                NSString *found = AevonOpenScanURL(item, depth + 1);
                if (found != nil) return found;
            }
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return nil;
}

/// 0.2.48 — 这次打开带的那个 URL。`__PayloadURL` 优先，其次
/// `__PayloadOptions[UIApplicationLaunchOptionsURLKey]`（分享那条路已经证明
/// 两种形状都在真机上出现过，见 `AevonForwardHeldURL`）。
///
/// 只读：两个键都经 `AevonOpenAnyValue` / `AevonActRead` 的 `@try` 包着，
/// 取不到就返回 nil，调用方按「不是干路」处理。
static NSString *AevonOpenURLOf(id request, id options) {
    id value = AevonOpenAnyValue(request, options, @"__PayloadURL");
    if (value == nil) {
        id payload = AevonOpenPayload(request, options);
        if (payload != nil) {
            value = AevonActRead(payload, @"UIApplicationLaunchOptionsURLKey");
        }
    }
    if (value == nil) {
        // 0.2.50 — 通用链接（微信 / QQ 登录最常见的那一种）不在 `__PayloadURL`
        // 里：它装成 `__UserActivity4LS`，真 URL 是 `webpageURL`。0.2.49 的 QQ
        // 授权日志 `pay=url` 却没有 `notify: link`，就是漏在这一步。
        id activity = AevonOpenAnyValue(request, options, @"__UserActivity4LS");
        if (activity == nil) {
            id payload = AevonOpenPayload(request, options);
            if (payload != nil) {
                activity = AevonActRead(payload, @"UIApplicationLaunchOptionsUserActivityKey");
            }
        }
        value = AevonActRead(activity, @"webpageURL");
        if (value == nil) value = AevonActRead(activity, @"URL");
        if (value == nil) value = AevonActRead(activity, @"_webpageURL");
    }
    if (value == nil) {
        // 0.2.56 — 分享面板的续接请求（`UIActivityContinuationAction`）会把目标 App 的
        // app link 装进 `__AppLink4LS`（`LSAppLink`）。它既不是字典也不是字符串，
        // 0.2.51 那套「按形状扫」进不到对象内部 —— 微信登录那一条的 `url=-`
        // 可能就漏在这里。`LSAppLink.URL` 是公开属性，KVC 就能读；读不到返回 nil。
        id appLink = AevonOpenAnyValue(request, options, @"__AppLink4LS");
        value = AevonActRead(appLink, @"URL");
        if (value == nil) value = AevonActRead(appLink, @"url");
    }
    if (value == nil) {
        // 0.2.51 — 最后一道：按形状扫。`options` 在真机上就是 `__NSDictionaryM`，
        // 登录链接无论挂在哪一层都会被这一扫找到；`request` 通常只是 bundle id 串，
        // 扫它是为了覆盖对象形状的那几代系统。
        value = AevonOpenScanURL(AevonOpenPayload(request, options), 0);
        if (value == nil) value = AevonOpenScanURL(options, 0);
        if (value == nil) value = AevonOpenScanURL(request, 0);
    }
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    return nil;
}

/// 0.2.5 — 「这是一次通知点击」的第二个判据：`options[@"__LaunchOrigin"]`。
///
/// 老判据只看 `__Actions.firstObject` 的类名。它在**横幅**与**长按/下滑通知**这两条
/// 路上成立，但「通知中心里直接点一条」那一次 `__Actions` 是空的（Aevon(167)/(169)
/// 的 `act=- n=0` 里混着这种），于是被当成 `plain` 原样转发 —— 用户看到的就是
/// 「在通知中心点，全屏打开，没有浮窗」。
///
/// TrollOpen 1.5.2 的实证（三家逆向报告 2026-11-08）：它认的就是这个键，取值是
///   · `SBSLaunchOriginBulletinDestinationBanner`     —— 横幅
///   · `SBSLaunchOriginBulletinDestinationCoverSheet` —— 通知中心 / 锁屏
/// 两个入口同一族，共同片段是 `Bulletin`；只认 `__Actions` 会漏掉后一个。
///
/// 是「或」不是「与」：老判据命中过的那些路一个字节都没改，新增的这一条只把
/// 漏掉的那条补进来。取不到就返回 NO（回到老行为，不猜）。
static BOOL AevonOpenIsNotificationOrigin(id request, id options) {
    id origin = AevonOpenAnyValue(request, options, @"__LaunchOrigin");
    if (![origin isKindOfClass:[NSString class]]) return NO;
    const char *raw = [(NSString *)origin UTF8String];
    if (raw == NULL) return NO;
    return strstr(raw, "Bulletin") != NULL;
}

/// `options` 里有没有某个键。
static BOOL AevonOpenHasKey(id options, NSString *key) {
    id dict = AevonOpenDict(options);
    if (dict == nil) return NO;
    return [(NSDictionary *)dict objectForKey:key] != nil;
}

/// 0.2.38 — 把 `__PasteSharingToken` 的形状打一行出来。
///
/// 这一版它只是诊断：token 类分享仍然整条放行给系统（文件能发，代价是目标 App
/// 全屏）。要把它做成「悬浮窗 + 文件发出」，下一版必须知道这东西能不能字符串化
/// —— 能，就写进我们自己的投递文件、完全绕开系统那次激活。
/// 只读、只打一行、异常一律吞掉：这段跑在 SpringBoard 主线程。
static void AevonPasteTokenProbe(id request, id options, const char *bundle) {
    static int notes = 0;
    if (notes >= 8) return;
    notes += 1;
    @try {
        id token = AevonOpenAnyValue(request, options, @"__PasteSharingToken");
        const char *cls = token != nil ? object_getClassName(token) : "nil";
        NSString *desc = nil;
        if (token != nil && [token respondsToSelector:@selector(description)]) {
            desc = [token description];
            if (desc.length > 120) desc = [desc substringToIndex:120];
        }
        AevonLogRaw([[NSString stringWithFormat:@"notify: paste token b=%s cls=%s desc=%@",
                      bundle != NULL ? bundle : "-", cls,
                      desc != nil ? desc : @"-"] UTF8String]);
    } @catch (__unused NSException *exception) {
        AevonLogRaw("notify: paste token threw");
    }
}

/// 0.2.39 — 「先让系统把这次打开真正做完，再把前台那个 App 收进卡片」。
///
/// 粘贴板分享（`__PasteSharingToken`）和微信那条没有 payload 键的分享都绕不开
/// 一次真正的系统激活：文件是随那次激活过 XPC / 写进接收方容器的。0.2.37 试过
/// 「先建卡、再把原请求交回原实现」，真机把它证伪了（卡片和全屏抢同一份 scene，
/// 卡片黑）。所以反过来：请求原样放行，等目标 App 真的成了前台，再走圆盘同一条
/// 「先回桌面、再贴卡片」。
///
/// 3 秒收手：超时说明这次分享根本没把 App 拉起来（取消 / 失败 / 被系统吞了），
/// 这时开卡只会凭空弹一个窗口，那不是用户要的。
///
/// 这个文件是 MRC：跨 `dispatch_after` 的东西一律拿 `strdup` 的 C 串走，
/// 所有权随块走、块里 `free` —— 与 `AevonBlacklistDrainAt` 同一套写法。
static char AevonPastePromoteBundle[128];
static CFAbsoluteTime AevonPastePromoteAt = 0;

/// 0.2.43 — 「这次分享是从哪个 App 发起的」。
///
/// 用户要的是「卡片浮在发起分享的 App 上方」，而不是落在桌面。openCard 的
/// home-first 只对**目标 App 正占着全屏**这一种情况生效；分享恰好就是这种：
/// 文件必须靠系统那次激活送出去，目标 App 因此成了前台，收起卡片时剩下的
/// 背景只能是桌面（Aevon 0.2.39 真机日志：`background after teardown door=1`）。
///
/// 所以必须在放行之前把来源记下来：hook 这一拍分享面板还开在来源 App 里，
/// 它的 scene `settings.isForeground` 还是 1。目标 App 起来之后这份记录就是
/// 「等卡片贴好、再把来源 App 请回全屏」的唯一线索。
///
/// 只认「前台且不是目标、不是桌面、不是分享服务」的第一条 scene。
static char AevonShareSource[128];
static CFAbsoluteTime AevonShareSourceAt = 0;

/// 0.2.71 — 给落点看门狗读「这次打开是谁发起的」。30 秒窗口与分享那条一致：
/// 超时就不猜，宁可空着让看门狗去拉目标 App。
static void AevonLandingSourceCopy(char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (AevonShareSource[0] == '\0') return;
    if (CFAbsoluteTimeGetCurrent() - AevonShareSourceAt > 30.0) return;
    snprintf(out, size, "%s", AevonShareSource);
}

/// 0.2.44 — 从 scene identifier 里还原**真正的 bundle id**。
///
/// 0.2.43 把整条 scene identifier 当 bundle 传给了
/// `launchApplicationWithIdentifier:suspended:NO`，真机日志里三次全是
/// `notify: share restore … door=2`（系统拒绝）。原因就在这里：
/// 多窗口 App 的 scene 是 `com.apple.DocumentsApp-<UUID>` /
/// `com.apple.mobilesafari-<UUID>`，后缀是 scene 的 UUID，不是 bundle 的一部分。
///
/// 规则只有两条：
///   `sceneID:<bundle>-default`          → 去掉 `sceneID:` 与 `-default`
///   `sceneID:<bundle>-<8>-<4>-<4>-<4>-<12>` → 去掉末尾 37 字节的 `-UUID`
static NSString *AevonSceneBundleName(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return text;
    if ([text hasPrefix:@"sceneID:"]) text = [text substringFromIndex:8];
    if ([text hasSuffix:@"-default"]) {
        return [text substringToIndex:text.length - 8];
    }
    NSUInteger n = text.length;
    if (n < 37) return text;
    if ([text characterAtIndex:n - 37] != '-') return text;
    NSString *tail = [text substringFromIndex:n - 36];
    NSArray<NSString *> *parts = [tail componentsSeparatedByString:@"-"];
    if (parts.count != 5) return text;
    NSUInteger want[5] = {8, 4, 4, 4, 12};
    for (NSUInteger i = 0; i < 5; i++) {
        if (parts[i].length != want[i]) return text;
    }
    return [text substringToIndex:n - 37];
}

static int AevonShareSourceSkip(const char *name) {
    if (name == NULL || name[0] == '\0') return 1;
    if (strcmp(name, "com.apple.springboard") == 0) return 1;
    if (strstr(name, "SharingViewService") != NULL) return 1;
    if (strstr(name, "ShareSheet") != NULL) return 1;
    if (strstr(name, "ViewService") != NULL) return 1;
    // 0.2.49 — 系统自己的 scene 不是 App：真机日志里分享来源被抓成了
    // `SuperHighLevelSystemAperture`（灵动岛），于是「把来源 App 请回全屏」
    // 一路失败（door=2 / ls ok=0），最后只能按 Home 回桌面。
    // 真 App 的 bundle id 一定带点；不带点的名字一律不认。
    if (strchr(name, '.') == NULL) return 1;
    if (strstr(name, "SystemAperture") != NULL) return 1;
    if (strstr(name, "remote-keyboard") != NULL) return 1;
    return 0;
}

/// 从 live scene 里认来源 App。只在主线程调（hook 就在主线程）。
static void AevonShareSourceCapture(const char *target) {
    AevonShareSource[0] = '\0';
    AevonShareSourceAt = 0;
    if (target == NULL || target[0] == '\0') return;
    id manager = AevonSceneManager();
    if (manager == nil) return;
    __block NSString *picked = nil;
    AevonEnumerateScenes(manager, ^(id scene) {
        if (scene == nil || picked != nil) return;
        if (AevonSceneForeground(scene) != 1) return;
        SEL idSel = sel_registerName("identifier");
        if (![scene respondsToSelector:idSel]) return;
        id value = ((id (*)(id, SEL))objc_msgSend)(scene, idSel);
        if (![value isKindOfClass:[NSString class]]) return;
        NSString *text = (NSString *)value;
        text = AevonSceneBundleName(text);
        const char *name = text.UTF8String;
        if (AevonShareSourceSkip(name)) return;
        if (strcmp(name, target) == 0) return;
        picked = text;
    });
    if (picked.length == 0) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: share source none target=%s",
                      target] UTF8String]);
        return;
    }
    snprintf(AevonShareSource, sizeof(AevonShareSource), "%s", picked.UTF8String);
    AevonShareSourceAt = CFAbsoluteTimeGetCurrent();
    AevonLogRaw([[NSString stringWithFormat:@"notify: share source b=%s target=%s",
                  picked.UTF8String, target] UTF8String]);
}

/// 「把来源 App 请回全屏」。
///
/// 只用 SpringBoard 自己的 `launchApplicationWithIdentifier:suspended:NO` ——
/// 母本用同一条选择子做启动（`suspended:YES`），说明它在 iOS 17 上还在；
/// `LSApplicationWorkspace.openApplicationWithBundleID:` 是同步 XPC，0.2.1
/// 的日志里 10 次调用全部 10 秒超时，不能拿来做这一拍。
/// 返回 1 = 系统接了 / 2 = 拒绝 / 0 = 选择子不在 / 3 = 抛异常。
static NSInteger AevonLaunchForeground(NSString *bundleID) {
    if (bundleID.length == 0) return 0;
    Class appCls = NSClassFromString(@"UIApplication");
    if (appCls == Nil) return 0;
    SEL sharedSel = sel_registerName("sharedApplication");
    if (![appCls respondsToSelector:sharedSel]) return 0;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, sharedSel);
    SEL sel = sel_registerName("launchApplicationWithIdentifier:suspended:");
    if (app == nil || ![app respondsToSelector:sel]) return 0;
    @try {
        BOOL (*call)(id, SEL, id, BOOL) = (BOOL (*)(id, SEL, id, BOOL))objc_msgSend;
        return call(app, sel, bundleID, NO) ? 1 : 2;
    } @catch (__unused NSException *exception) {
        return 3;
    }
}

/// `launchApplicationWithIdentifier:suspended:` 拒绝时的备份通道。
///
/// `LSApplicationWorkspace.openApplicationWithBundleID:` 是同步 XPC，0.2.1 的
/// 日志里 10 次全部 10 秒超时，所以只丢到后台队列，不占主线程、也不等它回来。
/// 超时也好、拒绝也好，日志里都会留下 `notify: share restore ls …` 一行。
static void AevonShareRestoreLaunch(const char *bundle, NSInteger door) {
    if (door == 1 || bundle == NULL || bundle[0] == '\0') return;
    char *copy = strdup(bundle);
    if (copy == NULL) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            Class cls = NSClassFromString(@"LSApplicationWorkspace");
            if (cls == Nil) { free(copy); return; }
            id ws = nil;
            for (NSString *name in @[@"defaultWorkspace", @"sharedInstance"]) {
                SEL sel = sel_registerName(name.UTF8String);
                if (![cls respondsToSelector:sel]) continue;
                ws = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
                if (ws != nil) break;
            }
            SEL openSel = sel_registerName("openApplicationWithBundleID:");
            if (ws == nil || ![ws respondsToSelector:openSel]) { free(copy); return; }
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, openSel,
                                                            [NSString stringWithUTF8String:copy]);
            AevonLogRaw([[NSString stringWithFormat:@"notify: share restore ls b=%s ok=%d",
                          copy, ok ? 1 : 0] UTF8String]);
        } @catch (__unused NSException *exception) {
            AevonLogRaw("notify: share restore ls threw");
        }
        free(copy);
    });
}

/// 桌面在屏的那一拍，把来源 App 请回全屏；卡片随后贴上去。
///
/// 0.2.43 等的是「卡片贴好」再恢复，但那时已经晚了：用户看到的是
/// 全屏 → 桌面 → 卡片。0.2.44 改成**一看到 home 落地就恢复** ——
/// `openCard` 的 `afterHome` 只要 `front != 1` 或 `scene_fg != 1` 就继续，
/// 不会被这次激活挡住（日志 `ready waited=500ms springboard=1 scene_fg=1 front=-1`）。
static void AevonShareRestoreTick(char *target, char *source, int tick) {
    if (target == NULL || source == NULL) { free(target); free(source); return; }
    if (source[0] == '\0' || strcmp(source, target) == 0) {
        free(target); free(source);
        return;
    }
    if (AevonCardIsUpFor(source) == 1) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: share restore skip b=%s card=1",
                      source] UTF8String]);
        free(target); free(source);
        return;
    }
    if (AevonSpringboardActive() == 1) {
        NSInteger door = AevonLaunchForeground([NSString stringWithUTF8String:source]);
        AevonLogRaw([[NSString stringWithFormat:@"notify: share restore b=%s after=%dms door=%d",
                      source, tick * 100, (int)door] UTF8String]);
        AevonShareRestoreLaunch(source, door);
        free(target); free(source);
        return;
    }
    if (AevonCardIsUpFor(target) == 1) {
        // 卡片贴好时来源 App 还在屏上 —— 这次根本没发 home，已经是要的样子。
        AevonLogRaw([[NSString stringWithFormat:@"notify: share restore skip b=%s board=0",
                      source] UTF8String]);
        free(target); free(source);
        return;
    }
    if (tick >= 48) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: share restore giveup b=%s tick=%d",
                      source, tick] UTF8String]);
        free(target); free(source);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonShareRestoreTick(target, source, tick + 1);
    });
}

static void AevonShareRestoreSchedule(const char *target) {
    if (target == NULL || target[0] == '\0') return;
    if (AevonShareSource[0] == '\0') return;
    if (CFAbsoluteTimeGetCurrent() - AevonShareSourceAt > 30.0) return;
    if (strcmp(AevonShareSource, target) == 0) return;
    char *t = strdup(target);
    char *s = strdup(AevonShareSource);
    if (t == NULL || s == NULL) { free(t); free(s); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonShareRestoreTick(t, s, 0);
    });
}

/// 0.2.46 — 分享收卡的顺序反过来：**先请来源 App 回前台，再建卡**。
///
/// 0.2.44 的顺序是 `openCard` 的 home-first：按 Home → 桌面 → 建卡 →
/// 再把来源 App 拉回来。真机上这四拍都看得见，用户看到的就是
/// 「QQ 全屏 → 桌面 → 文件列表 → 卡片」一路跳。
///
/// 这里换一条路：目标 App 此刻正占着全屏（文件刚靠系统那次激活送出去），
/// 直接 `launchApplicationWithIdentifier:suspended:NO` 把来源 App 顶回前台，
/// 等目标真的离开前台之后，再用 `homed: true` 建卡。`openCard` 的 home-first
/// 本来就是为了「目标还占着全屏时不许抽 scene」，目标已经退到后台，这道门
/// 既不需要、也不该再按一次 Home。
///
/// 60 ms 一拍：切 App 的动画是异步的，但目标的 `isForeground` 一翻 0 就说明
/// scene 已经可以安全搬走；最长 1.2 s 后退回 0.2.44 的顺序兜底。
///
/// 0.2.47 — 用户要的是「别看见全屏 QQ」。真正不出现全屏只有本地投递一条路，
/// 而 `UISPasteSharingToken` 的 description 只有对象地址（0.2.38 的探针），
/// 这条钥匙不存在；0.2.37「先建卡再交回」也被真机证伪。所以这里只做一件事：
/// 把「QQ 占屏」的这一段压到最短，让它落在分享面板收起的动画里。
static char AevonShareSwapTarget[128];
static CFAbsoluteTime AevonShareSwapAt = 0;

static void AevonShareSwapTick(char *target, char *source, int tick) {
    if (target == NULL || source == NULL) { free(target); free(source); return; }
    if (target[0] == '\0') { free(target); free(source); return; }
    if (AevonCardIsUpFor(target) == 1 || AevonCardIsComingFor(target) == 1) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: share swap skip b=%s tick=%d",
                      target, tick] UTF8String]);
        free(target); free(source);
        return;
    }
    NSString *targetID = [NSString stringWithUTF8String:target];
    NSString *sourceID = [NSString stringWithUTF8String:source];
    if (targetID.length == 0 || sourceID.length == 0) { free(target); free(source); return; }

    if (tick == 0) {
        if (source[0] == '\0') {
            // 没记到来源：退回 0.2.44 的 home-first，行为一字不改。
            AevonOpenFromNotification(target);
            free(target); free(source);
            return;
        }
        // 0.2.72 — 来源已经在卡片里：**不要再把它顶回前台**。
        //
        // 0.2.71 的真机现场（09:41:36）是这一串：
        //   notify: share swap restore b=com.tencent.mqq door=1
        //   win: card yield seen b=com.tencent.mqq now=430x932 want=430x717
        //   win: card yielded to fullscreen b=com.tencent.mqq
        // 授权回跳时 QQ 本来好好待在卡里，这一句把它拉成整屏，卡片随即让路 ——
        // 用户看到的就是「授权完 QQ 突然全屏」。来源已经有卡时不需要它让位：
        // 它不在前台，目标那一份 scene 本来就能被直接接走。
        if (AevonCardIsUpFor(source) == 1) {
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: share swap keep b=%s src=%s",
                          target, source] UTF8String]);
            AevonOpenCardDirect(target);
            free(target); free(source);
            return;
        }
        NSInteger door = AevonLaunchForeground(sourceID);
        AevonLogRaw([[NSString stringWithFormat:@"notify: share swap restore b=%s door=%d",
                      source, (int)door] UTF8String]);
        AevonShareRestoreLaunch(source, door);
        // 0.2.59 — 「来源顶不回来」就别再等那 20 拍。
        //
        // Aevon(200) 的两条文件分享（18:11:58 / 13:46）里来源都是
        // `com.apple.UIKit.OverlayUI.<uuid>`（分享面板的浮层，不是 App），
        // `AevonLaunchForeground` 答 2（拒绝），备份通道 `ok=0` —— 也就是
        // 「永远等不到 sourceBack」。旧版仍然每 60 ms 问一次，问满 20 拍
        // （1.2 秒）才认输，那 1.2 秒里目标 App 一直整屏在屏上；认输之后才回桌面
        // 建卡。用户看到的「先跳全屏一下，然后才出现悬浮窗」就是这 1.2 秒。
        //
        // 门只认 1（真的拉起来了）。不是 1 就地走 giveup 那一套 ——
        // 同一条兜底代码，只是提前 1.2 秒执行，行为一模一样。
        if (door != 1) {
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: share swap nogate b=%s door=%d",
                          source, (int)door] UTF8String]);
            AevonShareRestoreSchedule(target);
            AevonOpenFromNotification(target);
            free(target); free(source);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AevonShareSwapTick(target, source, tick + 1);
        });
        return;
    }

    int targetFront = AevonAppFrontmost(targetID);
    id targetScene = AevonSeenSceneForBundle(targetID);
    int targetFG = (targetScene != nil) ? AevonSceneForeground(targetScene) : -1;
    int sourceFront = AevonAppFrontmost(sourceID);
    id sourceScene = AevonSeenSceneForBundle(sourceID);
    int sourceFG = (sourceScene != nil) ? AevonSceneForeground(sourceScene) : -1;
    int targetGone = (targetFront != 1 && targetFG != 1) ? 1 : 0;
    int sourceBack = (sourceFront == 1 || sourceFG == 1) ? 1 : 0;
    if (targetGone || sourceBack) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: share swap card b=%s after=%dms target_fg=%d src_fg=%d board=%d",
                      target, tick * 60, targetFG, sourceFG, AevonSpringboardActive()]
                      UTF8String]);
        AevonOpenCardDirect(target);
        free(target); free(source);
        return;
    }
    if (tick >= 20) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: share swap giveup b=%s target_fg=%d src_fg=%d tick=%d",
                      target, targetFG, sourceFG, tick] UTF8String]);
        // 兜底：回到 0.2.44 的顺序（先回桌面，再由 afterHome 建卡）。
        AevonShareRestoreSchedule(target);
        AevonOpenFromNotification(target);
        free(target); free(source);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonShareSwapTick(target, source, tick + 1);
    });
}

static void AevonShareSwapSchedule(const char *target) {
    if (target == NULL || target[0] == '\0') return;
    if (AevonShareSource[0] == '\0') { AevonOpenFromNotification(target); return; }
    if (CFAbsoluteTimeGetCurrent() - AevonShareSourceAt > 30.0) {
        AevonOpenFromNotification(target);
        return;
    }
    if (strcmp(AevonShareSource, target) == 0) { AevonOpenFromNotification(target); return; }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (strcmp(AevonShareSwapTarget, target) == 0 && now - AevonShareSwapAt < 3.0) return;
    snprintf(AevonShareSwapTarget, sizeof(AevonShareSwapTarget), "%s", target);
    AevonShareSwapAt = now;
    char *t = strdup(target);
    char *s = strdup(AevonShareSource);
    if (t == NULL || s == NULL) { free(t); free(s); return; }
    AevonShareSwapTick(t, s, 0);
}


/// 0.2.62 — 授权族的「收卡」：系统激活之后，100 ms 内把它变成浮窗。
///
/// 背景（Aevon(203) 第 1 条）：0.2.60 把授权整条交回系统，登录终于能成，但
/// QQ / 微信是**整屏**打开的 —— 用户不接受。而 0.2.59 的「本地投递」又证明
/// 走不通（微信只开主页、QQ 回跳断在半路）。两条都试过的结论只有一句：
///
///   **这一次激活不能被我们吞掉，但激活之后停在哪种形态，是我们说了算的。**
///
/// 所以这里不改「放不放行」，只补「放行之后」。`AevonOpenDecide` 放行 ⇒ 系统
/// 真的把 QQ 拉到前台（SSO 的 XPC 回跳、微信的 NSUserActivity 都成立）⇒ 这张
/// 票在 100 ms 后由 `AevonOpenCardDirect` 收进卡片。用户看到的是「卡片里开着
/// QQ」，而登录流程一步没少。
///
/// 与 `AevonShareSwapTick` 的区别只有一条：**不去顶来源 App**。那条是给分享用
/// 的（分享面板开在来源 App 里，要先把它顶回来才能看见下一屏）；授权时来源 App
/// 正在等 QQ 的 code，把它顶上来只会把 QQ 挤下去。
/// `build` = 0：授权那一族（系统已经放行、激活之后收卡）。等满 6 秒仍没有
///              scene，就自己建一份 —— 0.2.72 真机上「放弃」的结果是
///              `auth swap giveup … build=0` 之后屏幕上什么都没发生，
///              用户点「授权」等于没点。宁可慢，也必须落到卡里。
/// `build` = 1：落点那一族（`display` 已经被切掉，系统不会摆屏）。等不到 scene
///              说明这次激活根本没造出 scene，必须自己建一份，否则就是「点了
///              没反应」。
static void AevonAuthSwapTick(char *target, int tick, int build);

/// 0.2.73 — 第 `tick` 拍对应的真实毫秒数。前四拍是 15 ms，之后 50 ms，
/// 所以 `tick * 50` 从第五拍起就不准了，日志里必须换算。
static int AevonAuthSwapElapsed(int tick) {
    if (tick <= 4) return tick * 15;
    return 60 + (tick - 4) * 50;
}

static void AevonAuthSwapTick(char *target, int tick, int build) {
    if (target == NULL) return;
    if (target[0] == '\0') { free(target); return; }
    if (AevonCardIsUpFor(target) == 1 || AevonCardIsComingFor(target) == 1) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: auth swap skip b=%s tick=%d",
                      target, tick] UTF8String]);
        free(target);
        return;
    }
    NSString *targetID = [NSString stringWithUTF8String:target];
    if (targetID.length == 0) { free(target); return; }
    int live = AevonAppPid(targetID) > 0 ? 1 : 0;
    id scene = AevonSeenSceneForBundle(targetID);
    int fg = (scene != nil) ? AevonSceneForeground(scene) : -1;
    // 收卡的门：scene 已经登记。`tick >= 1`（约 50 ms）是为了让系统那次激活
    // 先落地 —— 抢在它前面建卡会和 SpringBoard 抢同一份 scene，那正是
    // 「卡片黑 + 全屏底部黑」的老路。
    //
    // 0.2.67 — **不再要求 `live`**。Aevon(205) 的两次授权都是
    //   `notify: auth swap giveup b=com.tencent.mqq fg=1 live=0 tick=60`
    // scene 已经在屏上（fg=1），进程号那一位却答 0（`SBApplicationController`
    // 对微 / QQ 常常拿不到 pid）。旧闸把 `live` 当必要条件，于是每一次授权都
    // 在 3 秒后放弃收卡 —— 用户看到的永远是整屏，一次都没被收进来过。
    // scene 自己登记了，就说明这一份已经可以被接管。
    //
    // 也不等 `fg == 1`：QQ 的 scene 在激活过程中会短暂报 0，等它反而会多停在
    // 全屏几百毫秒。
    if (tick >= 1 && scene != nil) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: auth swap card b=%s after=%dms fg=%d live=%d board=%d",
                      target, AevonAuthSwapElapsed(tick), fg, live,
                      AevonSpringboardActive()] UTF8String]);
        AevonOpenCardDirect(target);
        free(target);
        return;
    }
    // 0.2.73 — 授权那一族从 60 拍（3 s）放宽到 120 拍（6 s）。
    // 0.2.72 的两次放弃都发生在 QQ 冷启动期间：`tick=60` 时它的 scene 还没造出来，
    // 而 paste token 在放弃之后才出现。多等 3 秒的代价是用户多看一眼来源 App；
    // 少等的代价是这一次授权完全没被接管。两害相权，等。
    int deadline = build ? 30 : 120;
    if (tick >= deadline) {
        int seen = AevonSeenCountOf();
        int fb = AevonLiveSceneForBundle(targetID) != nil ? 1 : 0;
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: auth swap giveup b=%s fg=%d live=%d tick=%d build=%d seen=%d fb=%d",
                      target, fg, live, tick, build, seen, fb] UTF8String]);
        // 0.2.73 — 两族都建卡。
        //
        // 原来只有 `build=1`（落点）建卡，授权那一族是「松手、让系统全屏」。
        // 真机上这条松手分支的下场是屏幕上**什么都没发生**：系统那次激活没造出
        // scene，我们也不再管，用户点「授权」等于没点。而卡片自己有能力建 scene
        // （`win: own start … door=1` → `own compose ok`），没有理由不用它。
        if (build) {
            AevonLogRaw([[NSString stringWithFormat:
                          @"landing: url build b=%s after=%dms",
                          target, AevonAuthSwapElapsed(tick)] UTF8String]);
        } else {
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: auth swap build b=%s after=%dms seen=%d fb=%d",
                          target, AevonAuthSwapElapsed(tick), seen, fb] UTF8String]);
        }
        AevonOpenCardDirect(target);
        free(target);
        return;
    }
    // 0.2.72 — 前四拍用 15 ms，之后回到 50 ms。
    //
    // `tick >= 1` 那道门是「让系统那次激活先落地」，不是「等 50 毫秒」；
    // 真机上完成的时刻由 scene 登记决定，所以把前四拍的间隔压到 15 ms
    // 只是让「scene 一登记就接走」这件事早 35~135 ms 发生 —— 用户看到的
    // 整屏窗口就是从 50 ms 起算的，这一改直接把那段压掉。
    // 0.2.71 之前的 50 ms 固定节拍会让 `first frame shown` 之后还要多等一拍，
    // 那正是「授权先整屏一下」的观感来源。
    int64_t step = (tick < 4) ? (int64_t)(0.015 * NSEC_PER_SEC)
                              : (int64_t)(0.05 * NSEC_PER_SEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, step),
                   dispatch_get_main_queue(), ^{
        AevonAuthSwapTick(target, tick + 1, build);
    });
}

static char AevonAuthSwapTarget[128];
static CFAbsoluteTime AevonAuthSwapAt = 0;
static int AevonAuthSwapBuild = -1;

/// 最近一次「放行给系统去激活」的授权目标（微 / QQ）与时刻。
static char AevonAuthSeen[128];
static CFAbsoluteTime AevonAuthSeenAt = 0;

/// 这一次「微 / QQ → 第三方 App」是不是刚发生过授权。
/// 30 秒窗口：用户点完授权、在微信里等页面刷完再回来，通常都在这个量级以内。
static int AevonAuthReturnMatched(id source) {
    if (![source isKindOfClass:[NSString class]]) return 0;
    const char *raw = [(NSString *)source UTF8String];
    if (raw == NULL || AevonAuthSeen[0] == '\0') return 0;
    if (CFAbsoluteTimeGetCurrent() - AevonAuthSeenAt > 30.0) return 0;
    return strcmp(raw, AevonAuthSeen) == 0 ? 1 : 0;
}

/// 0.2.87 — 母版 P5 的第一招：`launchApplicationWithIdentifier:suspended:`。
///
/// `Stheno-1比1复刻方案` 把它写成一行的用途是「**场景先建好不跑，要显示时再激活**」，
/// 二进制侧有 cstring 命中（`Stheno.dylib` 2 次）+ 选择子面 1 条，真机侧
/// Aevon(218) 的普查答 `own launchApplicationWithIdentifier:suspended: n=2 |
/// UIApplication ; SpringBoard` —— `SpringBoard` 类自己就实现了它。
///
/// ⛔ 这与 0.2.69 在 settings 上置挂起位是**两件完全不同的事**，那一条已被证伪：
///   挂起位让系统这次激活不上屏 ⇒ 进程不跑 ⇒ SSO 的 XPC 与 NSUserActivity 没人接。
///   预暖是**提前**把进程准备好，随后的激活照常发生，只是目标已经热的。
///
/// 放在 `return 0` 之前同步调用：放行之后系统立刻开始激活，预暖必须赶在它前面。
/// 代价是主线程多一次同步 XPC（日志里的 `ms=` 就是它的实测值）；`door=` 报
/// 1 成功 / 2 拒绝 / 0 没有这个方法。任何值都不阻断放行。
static void AevonPrewarmCard(const char *target) {
    if (target == NULL || target[0] == '\0') return;
    NSString *targetID = [NSString stringWithUTF8String:target];
    if (targetID.length == 0) return;
    // scene 已经登记 ⇒ 目标本来就热着，预暖只会多一次开请求。
    if (AevonSeenSceneForBundle(targetID) != nil) return;
    // 同一个 bundle 60 秒内只预暖一次：连击时系统自己会复用进程。
    static char lastTarget[128] = {0};
    static CFAbsoluteTime lastAt = 0;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    if (strcmp(lastTarget, target) == 0 && started - lastAt < 60.0) return;
    snprintf(lastTarget, sizeof(lastTarget), "%s", target);
    lastAt = started;

    id app = nil;
    Class appCls = objc_getClass("UIApplication");
    if (appCls != Nil) {
        SEL shared = sel_registerName("sharedApplication");
        if ([appCls respondsToSelector:shared]) {
            app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, shared);
        }
    }
    NSInteger door = 0;
    @try {
        door = AevonLaunchSuspended(app, targetID);
    } @catch (__unused NSException *exception) {
        door = 0;
    }
    int elapsed = (int)((CFAbsoluteTimeGetCurrent() - started) * 1000.0);
    AevonLogRaw([[NSString stringWithFormat:@"notify: prewarm b=%s door=%ld ms=%d",
                  target, (long)door, elapsed] UTF8String]);
}

/// 同一个 App 在 3 秒内连来两条（untrusted / user）只排一条等待链。
/// `build` 取 1 的那一条（落点）优先：它背后是「系统不会摆屏」，等不到就得自己建。
static void AevonAuthSwapScheduleMode(const char *target, int build) {
    if (target == NULL || target[0] == '\0') return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // 同一条请求会先排 `build=0`（授权放行），再排 `build=1`（落点切了 display）。
    // 后者更强：它背后是「系统不会摆屏」，等不到 scene 必须自己建。所以同一
    // 个 App 在 3 秒内已经从 0 升到 1 时，允许再排一条，反过来则忽略。
    if (strcmp(AevonAuthSwapTarget, target) == 0 && now - AevonAuthSwapAt < 3.0 &&
        build <= AevonAuthSwapBuild) return;
    // 0.2.87 — 母版那一招。放在这里而不是各个 `return 0` 之前，是因为三条路
    // （分享 / 授权 / 普通深链）最后都汇到这一个调度器上：一处接线三路受益。
    // 必须**同步**跑完再放行 —— `return 0` 之后系统立刻开始激活，预暖要赶在它前面。
    AevonPrewarmCard(target);
    snprintf(AevonAuthSwapTarget, sizeof(AevonAuthSwapTarget), "%s", target);
    AevonAuthSwapAt = now;
    AevonAuthSwapBuild = build;
    char *copy = strdup(target);
    if (copy == NULL) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAuthSwapTick(copy, 0, build);
    });
}

/// 0.2.74 — 记下「刚刚真的发生了一次授权」。
///
/// 授权结果回到第三方 App 时，那一方的那张卡用完就该收（见 `AevonOpenDecide`
/// 的 `authreturn` 分支）；而「微信里点了一个分享链接」也会走同一条形状，只看
/// 形状分不出来，只能靠这几秒内的授权记录。0.2.74 起两条路都要记 —— 吞掉那条
/// 不再经过 `AevonAuthSwapSchedule`，所以抽成独立一格。
static void AevonAuthSeenNote(const char *target) {
    if (target == NULL || target[0] == '\0') return;
    snprintf(AevonAuthSeen, sizeof(AevonAuthSeen), "%s", target);
    AevonAuthSeenAt = CFAbsoluteTimeGetCurrent();
}

static void AevonAuthSwapSchedule(const char *target) {
    AevonAuthSeenNote(target);
    AevonAuthSwapScheduleMode(target, 0);
}

/// 0.2.67 — 落点专用：`display` 已经被切掉，系统不会把 App 摆到屏幕上。
/// 剩下的唯一一件事就是把它的 scene 挂进卡片；没有 scene 就自己建一份。
static void AevonLandCardSchedule(const char *target) {
    AevonAuthSwapScheduleMode(target, 1);
}

static void AevonPastePromoteTick(char *copy, int tick) {
    if (copy == NULL) return;
    if (copy[0] == '\0') { free(copy); return; }
    if (AevonCardIsUpFor(copy) == 1 || AevonCardIsComingFor(copy) == 1) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: paste promote b=%s skip=card tick=%d",
                      copy, tick] UTF8String]);
        free(copy);
        return;
    }
    NSString *target = [NSString stringWithUTF8String:copy];
    if (target.length == 0) { free(copy); return; }
    int front = AevonAppFrontmost(target);
    int board = AevonSpringboardActive();
    int live = AevonAppPid(target) > 0 ? 1 : 0;
    // `front=-1` 是「读不到前台位」（`SBApplicationController` 对某些 App 返回 nil），
    // 不是「不在前台」。scene 自己的 `settings.isForeground` 是第二见证 ——
    // `openCard` 的 home-first 用的就是它（日志里的 `scene_fg=`）。
    id scene = AevonSeenSceneForBundle(target);
    int sceneFG = (scene != nil) ? AevonSceneForeground(scene) : -1;
    // `front=-1` 且 scene 也没记到时，用「进程活着」代替，但多等 0.5 秒，
    // 免得抢在系统摆动画之前把卡贴上去。
    //
    // `board != 1` 是 `openCard` 那条 home-first 的门：桌面在屏时它不会先回桌面，
    // 而「全屏 App 直接贴卡」正是 0.2.30 修掉的那次黑屏。这里提前按同一条门等。
    int up = (front == 1 || sceneFG == 1) ? 1
           : ((front == -1 && sceneFG == -1 && live == 1 && tick >= 8) ? 1 : 0);
    // 0.2.62 — **目标一能接管就接管，不等它先整屏站住。**
    //
    // Aevon(203) 第 4 条：文件分享到 QQ「先全屏打开 QQ，然后变成浮窗」。
    // 旧判据要求 `front == 1`（SpringBoard 已经把它认成前台）才收卡，而那一刻
    // 系统已经把整屏画出来了 —— 用户在 `share swap card … after=60ms` 这行日志
    // 之前，看到的是 QQ 的整屏启动图。改判「进程活着 + scene 已登记」，在系统
    // 刚开始摆动画时就接过来，那一帧还没有内容，接收等于换了个容器。
    //
    // 文件本身不受影响：`__PasteSharingToken` 是系统在激活这一拍交给 QQ 的，
    // 我们在它之后才动 scene；QQ 进程没有被挂起，读剪贴板与收卡互不阻塞。
    if (tick >= 1 && scene != nil && (live == 1 || sceneFG == 1)) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: paste promote card b=%s front=%d board=%d live=%d scene=%d tick=%d",
                      copy, front, board, live, sceneFG, tick] UTF8String]);
        AevonOpenCardDirect(copy);
        free(copy);
        return;
    }
    // 0.2.79 — **先等目标自己的 scene，不要先把来源 App 拉回来。**
    //
    // Aevon(212) 12:20:08 的现场：`paste promote b=com.tencent.mqq front=-1
    // board=0 live=0 scene=1 tick=0` —— 第 0 拍（20 ms）QQ 的进程号还是 0，
    // 旧判据 `up = (front==1||sceneFG==1)` 当场成立，于是立刻
    // `share swap restore`：把文件 App 顶回前台，等 60 ms 再把 QQ 收进卡片。
    // 用户看到的就是「QQ 先整屏 → 闪回文件列表 → 再变小窗」。
    //
    // 现在前 3 拍（≈180 ms）只做一件事：等 `scene` 到位。拿到就直收，一次都不
    // 把来源 App 拉出来。超过 3 拍还没拿到才退回旧路 —— 那条路至少保证内容
    // 送得到。`live` 只参与上面那一格，不单独当条件：`SBApplicationController`
    // 对微 / QQ 常常答 0（0.2.67 的教训），拿它当必要条件会把每一次分享都拖到
    // 超时。
    if (board != 1 && up && tick >= 3) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: paste promote b=%s front=%d board=%d live=%d scene=%d tick=%d",
                      copy, front, board, live, sceneFG, tick] UTF8String]);
        // 0.2.46 — 不再先回桌面。先把来源 App 顶回前台，等目标离开前台之后
        // 再用 `homed: true` 直接建卡；没记到来源时才退回 home-first。
        AevonShareSwapSchedule(copy);
        free(copy);
        return;
    }
    if (tick >= 50) {
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: paste promote b=%s giveup front=%d board=%d live=%d scene=%d tick=%d",
                      copy, front, board, live, sceneFG, tick] UTF8String]);
        free(copy);
        return;
    }
    // 0.2.56 — 60 ms 一拍（原 125 ms）：目标 scene 一翻前台就收卡，
    // 不再多等一个固定节拍。50 拍仍覆盖原来的 3 秒窗口。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonPastePromoteTick(copy, tick + 1);
    });
}

/// 同一次分享会连来两条（op=untrusted / op=user），只许排一条等待链。
static void AevonPastePromoteSchedule(const char *bundle) {
    if (bundle == NULL || bundle[0] == '\0') return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (strcmp(AevonPastePromoteBundle, bundle) == 0 && now - AevonPastePromoteAt < 6.0) return;
    snprintf(AevonPastePromoteBundle, sizeof(AevonPastePromoteBundle), "%s", bundle);
    AevonPastePromoteAt = now;
    // 0.2.43 — 先记账：这一拍分享面板还开在来源 App 里，目标 App 还没顶上来。
    AevonShareSourceCapture(bundle);
    char *copy = strdup(bundle);
    if (copy == NULL) return;
    AevonLogRaw([[NSString stringWithFormat:@"notify: paste promote schedule b=%s", copy] UTF8String]);
    // 0.2.56 — 首拍从 0.20 s 改到 0.02 s：这 0.20 s 不是「等内容就绪」，只是
    // 排队的固定延迟。`AevonPastePromoteTick` 自己会用 `sceneFG / front` 判
    // 「目标是不是真的已经上前台」，不到就继续等 —— 所以提前来问不会抢跑，
    // 只会在目标上前台的那一拍立刻收卡，把用户看到的全屏窗口压到最短。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonPastePromoteTick(copy, 0);
    });
}

/// 0.2.56 — 一条 URL 的形状：scheme 与长度。内容（ticket / code）不进日志。
static void AevonURLShape(NSString *url, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        snprintf(out, size, "-");
        return;
    }
    const char *raw = url.UTF8String;
    size_t i = 0;
    if (raw != NULL) {
        while (raw[i] != '\0' && raw[i] != ':' && i < size - 1) {
            out[i] = raw[i];
            i += 1;
        }
    }
    out[i] = '\0';
    size_t used = strlen(out);
    snprintf(out + used, size - used, "/%d", (int)url.length);
}

/// 0.2.56 — 一个对象的 ivar 名字（只记名字，一个值都不读）。
///
/// 为什么需要：`__PasteSharingToken` 不是一个公开类，0.2.38 的探针只拿到
/// 「类名 + description（对象地址）」。若它身上带着一个粘贴板名字，那就有可能在
/// 本地把登录载荷读出来、完全绕开系统那次全屏激活 —— 但不知道 ivar 叫什么，
/// 下一版还是只能猜。这里只列名字，最多三级父类、六个名字。
static void AevonIvarNamesOf(id object, char *out, size_t size, int maxNames) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (object == nil) { snprintf(out, size, "-"); return; }
    @try {
        size_t used = 0;
        int names = 0;
        Class cls = object_getClass(object);
        for (int level = 0; cls != Nil && level < 3 && names < maxNames; level++) {
            unsigned int count = 0;
            Ivar *list = class_copyIvarList(cls, &count);
            if (list != NULL) {
                for (unsigned int i = 0; i < count && names < maxNames; i++) {
                    const char *name = ivar_getName(list[i]);
                    if (name == NULL) continue;
                    size_t need = strlen(name);
                    if (used + need + 2 >= size) break;
                    if (used > 0) out[used++] = ',';
                    memcpy(out + used, name, need);
                    used += need;
                    out[used] = '\0';
                    names += 1;
                }
                free(list);
            }
            cls = class_getSuperclass(cls);
        }
        if (used == 0) snprintf(out, size, "-");
    } @catch (__unused NSException *exception) {
        snprintf(out, size, "!");
    }
}

/// 0.2.55 — 微信 / QQ 的每一次打开先照一张相。
///
/// 0.2.54 的真机反馈只有一句「QQ 全程悬浮，微信仍会闪一下全屏」，而那一版日志
/// 里没有微信登录那一段 —— 又回到猜。这一行预算独立（40 拍），只读不改：
/// `pay` / `cont` / `share` / `sys` / `front` / `src` / `act` / URL 的 scheme 与长度 /
/// options 的全部键。下一次测试的日志里必然有微信登录的形状。
///
/// `board=` 只在「带 paste token 且不是分享链路」时探一下粘贴板：微信登录如果是
/// 「裸开 App、ticket 放粘贴板」，这是唯一能本地投递的入口。只记 scheme 与长度，
/// 内容（ticket / code）不进日志。
static void AevonSsoProbe(id request, id options, const char *bundle) {
    static int notes = 0;
    if (notes >= 40) return;
    notes += 1;
    @try {
        NSString *url = AevonOpenURLOf(request, options);
        char scheme[20] = "-";
        if (url.length > 0) {
            const char *raw = url.UTF8String;
            size_t i = 0;
            while (raw != NULL && raw[i] != '\0' && raw[i] != ':' && i < sizeof(scheme) - 1) {
                scheme[i] = raw[i];
                i += 1;
            }
            scheme[i] = '\0';
        }
        id src = AevonOpenSourceApp(request, options);
        id action = AevonOpenFirstAction(request, options);
        char keys[136];
        AevonOpenKeysOf(options, keys, sizeof(keys));
        const char *pay = AevonOpenPayloadKind(request, options);
        char board[40] = "-";
        if (strcmp(pay, "paste") == 0 && !AevonOpenIsShareSource(request, options)) {
            @try {
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                NSString *text = pasteboard.URL.absoluteString;
                if (text.length == 0) text = pasteboard.string;
                if (text.length > 0) {
                    const char *rawBoard = text.UTF8String;
                    size_t i = 0;
                    while (rawBoard != NULL && rawBoard[i] != '\0' && rawBoard[i] != ':' &&
                           rawBoard[i] != '\n' && i < sizeof(board) - 12) {
                        board[i] = rawBoard[i];
                        i += 1;
                    }
                    board[i] = '\0';
                    size_t used = strlen(board);
                    snprintf(board + used, sizeof(board) - used, "/%d", (int)text.length);
                }
            } @catch (__unused NSException *exception) {
                snprintf(board, sizeof(board), "threw");
            }
        }
        // 0.2.56 — `__AppLink4LS` 与 `__UserActivity4LS` 的形状。
        //
        // 微信登录（`pay=paste` + `cont=1`）在顶层 options 里既没有 URL，也读不到
        // 粘贴板内容。若 app link / 用户活动里其实装着一条可投递的 URL，这一格会
        // 直接给出 scheme 与长度；`ptk=` 是 token 对象的 ivar 名字 —— 下一版能不能
        // 在本地读出载荷，就看这两个字段。
        id appLink = AevonOpenAnyValue(request, options, @"__AppLink4LS");
        char link[72] = "-";
        if (appLink != nil) {
            id linkValue = AevonActRead(appLink, @"URL");
            NSString *linkText = nil;
            if ([linkValue isKindOfClass:[NSURL class]]) {
                linkText = [(NSURL *)linkValue absoluteString];
            } else if ([linkValue isKindOfClass:[NSString class]]) {
                linkText = (NSString *)linkValue;
            }
            char shape[40];
            AevonURLShape(linkText, shape, sizeof(shape));
            snprintf(link, sizeof(link), "%s:%s", object_getClassName(appLink), shape);
        }
        id activity = AevonOpenAnyValue(request, options, @"__UserActivity4LS");
        char uaText[72] = "-";
        if (activity != nil) {
            id type = AevonActRead(activity, @"activityType");
            if ([type isKindOfClass:[NSString class]] && [(NSString *)type length] > 0) {
                const char *rawType = [(NSString *)type UTF8String];
                snprintf(uaText, sizeof(uaText), "%s", rawType != NULL ? rawType : "-");
            } else {
                snprintf(uaText, sizeof(uaText), "#%s", object_getClassName(activity));
            }
        }
        char tokenKeys[104] = "-";
        id token = AevonOpenAnyValue(request, options, @"__PasteSharingToken");
        if (token != nil) AevonIvarNamesOf(token, tokenKeys, sizeof(tokenKeys), 6);
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: sso b=%s pay=%s cont=%d share=%d sys=%d front=%d src=%@ act=#%s url=%s len=%d board=%s link=%s ua=%s ptk=%s keys=%s",
                      bundle, pay,
                      AevonOpenIsContinuation(request, options),
                      AevonOpenIsShareSource(request, options) ? 1 : 0,
                      AevonOpenSourceIsSpringBoard(request, options) ? 1 : 0,
                      AevonAppFrontmost([NSString stringWithUTF8String:bundle]),
                      [src isKindOfClass:[NSString class]] ? (NSString *)src : @"-",
                      action != nil ? object_getClassName(action) : "-",
                      scheme, (int)url.length, board, link, uaText, tokenKeys,
                      keys[0] != '\0' ? keys : "-"]
                     UTF8String]);
    } @catch (__unused NSException *exception) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: sso b=%s probe=threw",
                      bundle] UTF8String]);
    }
}

/// 0.2.59 — 授权交接完成 ⇒ 0.45 s 后把刚用完的那张卡正常关掉（不是「让路」）。
///
/// 时机取 0.45 s：`appurl ack` 只证明 App 的 `scene:openURLContexts:` 收下了，
/// 它的 SDK 还要把 code 换成 token。0.45 s 是「够它发完请求」的量级，再长用户
/// 就会觉得「授权完了窗口还杵在那儿」。
///
/// `who` 是**递结果的那一方**（微信 / QQ），不是拿到结果的 App —— 要收的是它。
static void AevonAuthCardCloseSoon(NSString *who, const char *why) {
    if (![who isKindOfClass:[NSString class]] || who.length < 8) return;
    NSString *held = [who copy];
    AevonLogRaw([[NSString stringWithFormat:@"notify: auth card close b=%@ why=%s",
                  held, why != NULL ? why : "-"] UTF8String]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonCardCloseFor([held UTF8String]);
        [held release];
    });
}

// MARK: - 0.2.85 方案 S 现场取证（只读，一次）
//
// 方案 S 的链条是：拿 URL → 建 definition → 建 scene → presenter 承载。
// 前两步的参数全部长在**这一拍**的四个对象里：
//
//   request  —— 打开请求本身。`AevonOpenBundleOf` 已经从它取到 bundle，
//               因此 URL 大概率也在这上面，只是名字未知（`url` / `_url` / `URL`）
//   options  —— 这一层用了很久（`__PayloadURL` / `__Actions` / `__LaunchOrigin`）
//   settings —— `activationSettings`。方案 S 第 4 步要把它变成 scene 的 settings，
//               而「能不能直接变」只有看到它的方法表才知道
//   origin   —— `workspaceOriginatingProcess`。母本那个构造器
//               `initWithURL:workspaceOriginatingProcess:` 的第二个参数很可能吃它
//
// 打四样，**只打一次**：
//   ① 每个参数的类名 / 自有方法数 / 父类；
//   ② 十一个 URL 家族名字逐个问。答「有」的**先看返回类型**再决定要不要读 ——
//      只有返回 `@` 才 `performSelector:`（这是纪律：`perform` 只用于返回对象的
//      选择子，标量走别路）。读到 NSString / NSURL 才打值，别的一律只打类名。
//   ③ 自有方法表，每参数最多 42 条、每行 10 条。
//   ④ 0.2.86 —— `__PayloadURL` 与 `__Actions` 里的东西各是什么类、带哪些 ivar。
//
// 为什么只做一次：这是打开请求的热路径，`class_copyMethodList` 会摊开类元数据。
// 一次够用 —— 这四个参数的类不会因为目标 bundle 不同而变。
// 0.2.87 — 保留但停用（调用点在 `AevonOpenDecide` 之前，已改为只写一段说明）。
// `unused` 是为了别让编译器为它报警：它是取证工具，不是生产路径的一部分。
__attribute__((unused))
static void AevonOpenShapeDump(id request, id options, id settings, id origin) {
    static int done = 0;
    if (done) return;
    done = 1;

    id slots[4] = {request, options, settings, origin};
    const char *tags[4] = {"req", "opt", "set", "org"};
    const char *probes[] = {"url", "URL", "_url", "_URL",
                            "initialURL", "_initialURL",
                            "workspaceOriginatingProcess",
                            "_workspaceOriginatingProcess",
                            "bundleIdentifier", "identifier", "requestIdentifier",
                            // 0.2.86 —— 投递容器本身。`transitionContext` 若在这四个
                            // 参数上答得出来，URL 就不必走 definition（它也没有那个位）。
                            "transitionContext", "actions", "specification"};
    const int probeCount = (int)(sizeof(probes) / sizeof(probes[0]));

    for (int index = 0; index < 4; index++) {
        id obj = slots[index];
        if (obj == nil) {
            AevonLogRaw([[NSString stringWithFormat:@"shape: %s nil", tags[index]] UTF8String]);
            continue;
        }
        Class cls = object_getClass(obj);
        uint32_t count = 0;
        Method *list = class_copyMethodList(cls, &count);
        Class parent = class_getSuperclass(cls);
        AevonLogRaw([[NSString stringWithFormat:@"shape: %s cls=%s n=%u super=%s",
                      tags[index], class_getName(cls), count,
                      parent != NULL ? class_getName(parent) : "nil"] UTF8String]);

        NSMutableString *probeLine = [NSMutableString stringWithFormat:@"shape: %s probe",
                                      tags[index]];
        for (int slot = 0; slot < probeCount; slot++) {
            SEL sel = sel_registerName(probes[slot]);
            Method method = class_getInstanceMethod(cls, sel);
            if (method == NULL) {
                [probeLine appendFormat:@" %s=-", probes[slot]];
                continue;
            }
            char *ret = method_copyReturnType(method);
            BOOL objectReturn = (ret != NULL && ret[0] == '@');
            if (ret != NULL) free(ret);
            if (!objectReturn) {
                [probeLine appendFormat:@" %s=!obj", probes[slot]];
                continue;
            }
            id value = nil;
            @try {
                value = [obj performSelector:sel];
            } @catch (__unused NSException *exception) {
                value = nil;
            }
            if ([value isKindOfClass:[NSString class]]) {
                const char *raw = [(NSString *)value UTF8String];
                [probeLine appendFormat:@" %s=str:%s", probes[slot], raw != NULL ? raw : "?"];
            } else if ([value isKindOfClass:[NSURL class]]) {
                const char *raw = [[(NSURL *)value absoluteString] UTF8String];
                [probeLine appendFormat:@" %s=url:%s", probes[slot], raw != NULL ? raw : "?"];
            } else if (value == nil) {
                [probeLine appendFormat:@" %s=nil", probes[slot]];
            } else {
                [probeLine appendFormat:@" %s=#%s", probes[slot], object_getClassName(value)];
            }
        }
        AevonLogRaw([probeLine UTF8String]);

        if (list != NULL) {
            int shown = (int)(count < 42 ? count : 42);
            NSMutableString *row = [NSMutableString string];
            int inRow = 0;
            for (int i = 0; i < shown; i++) {
                if (inRow == 0) {
                    [row setString:[NSString stringWithFormat:@"shape: %s m", tags[index]]];
                }
                const char *name = sel_getName(method_getName(list[i]));
                const char *enc = method_getTypeEncoding(list[i]);
                [row appendFormat:@" %s=%s", name != NULL ? name : "?",
                                   enc != NULL ? enc : "?"];
                inRow++;
                if (inRow == 10 || i == shown - 1) {
                    AevonLogRaw([row UTF8String]);
                    inRow = 0;
                }
            }
            if (shown < (int)count) {
                AevonLogRaw([[NSString stringWithFormat:@"shape: %s m rest=%d",
                              tags[index], (int)count - shown] UTF8String]);
            }
            free(list);
        }
    }
    // 0.2.86 —— 「URL 装在哪个对象上」比「哪个类有哪些方法」更值钱。
    //
    // 母本那条 `initWithURL:workspaceOriginatingProcess:` 造出来的是 `UISOpenURLAction`
    // （BSAction 的子类），而 BSAction 的标准投递容器是 scene 的 transition context。
    // 所以这里把 `__Actions` 逐元素摊开、把每个元素的 ivar 名列出来：若元素正是
    // `UISOpenURLAction`，它身上一定同时躺着 url 与 workspaceOriginatingProcess。
    //
    // 这一段只在请求**真的带了东西**时才跑（`AevonOpenCarriesPayload`）：桌面上
    // 点图标的普通打开不占这一次性预算。0.2.85 把整块挂在 `verdict == 1` 上，
    // 结果 Aevon(218) 两次分享都走 `return 0`，探针一次都没落地 —— 挂错了位置。
    @try {
        id urlValue = AevonOpenAnyValue(request, options, @"__PayloadURL");
        if (urlValue != nil) {
            const char *name = object_getClassName(urlValue);
            int length = [urlValue respondsToSelector:@selector(length)]
                       ? (int)[urlValue length] : -1;
            AevonLogRaw([[NSString stringWithFormat:@"shape: payload url=#%s len=%d",
                          name != NULL ? name : "?", length] UTF8String]);
        } else {
            AevonLogRaw("shape: payload url=nil");
        }
        id actions = AevonOpenAnyValue(request, options, @"__Actions");
        if (actions == nil) {
            AevonLogRaw("shape: actions none");
        } else {
            NSUInteger count = [actions respondsToSelector:@selector(count)]
                             ? [actions count] : 0;
            AevonLogRaw([[NSString stringWithFormat:@"shape: actions cls=%s n=%lu",
                          object_getClassName(actions), (unsigned long)count] UTF8String]);
            for (NSUInteger i = 0; i < count && i < 6; i++) {
                id item = [actions respondsToSelector:@selector(objectAtIndex:)]
                        ? [actions objectAtIndex:i] : nil;
                if (item == nil) continue;
                char vars[120];
                AevonIvarNamesOf(item, vars, sizeof(vars), 8);
                AevonLogRaw([[NSString stringWithFormat:@"shape: act[%lu] cls=%s vars=%s",
                              (unsigned long)i, object_getClassName(item), vars] UTF8String]);
            }
        }
    } @catch (__unused NSException *exception) {
        AevonLogRaw("shape: payload threw");
    }
    AevonLogRaw("shape: dump finished");
}

/// 分流决定。
///   返回 1 → 吞掉，开卡片；
///   返回 2 → 吞掉，不再开（同一次点击的后续链）；
///   返回 0 → 原样转发，行为与 0.1.87 一致。
/// `why` 只用于日志：它把「没分流」的四种原因分开，否则下一份日志里
/// 「一个 notify: divert 都没有」与「分流了但没生效」长得一样。
static int AevonOpenDecide(id request, id options, id settings,
                           char *bundle, size_t size, const char **why) {
    if (bundle == NULL || size == 0) return 0;
    bundle[0] = '\0';
    *why = "-";

    if (AevonActivateSwitchOff()) { *why = "off"; return 0; }
    // 0.2.77 — 两把尺分开问。
    //
    // 全局那一把（60 次 / 60 秒）先问：这时还不知道目标是谁。连击那一把必须等
    // `bundle` 算出来 —— 它认的是「同一个 App 连着来」，没有 bundle 就无从认。
    // Aevon(211) 里支付被掐掉的那一版把两者合成一个数，于是「今天开了 24 个
    // 不同的 App」被当成「坏了」。
    if (AevonDivertCapKind(NULL) == 1) { *why = "cap"; return 0; }

    id target = AevonOpenBundleOf(request);
    // 0.2.76 — **`b=-` 不再等于「不管」。**
    //
    //  Aevon(210) 11:42:00 的那一拍：
    //      notify: hit op=open b=- src=- act=#UILinkConnectionAction …
    //      notify: pass b=- op=open why=nobundle
    //  请求里确实没有 bundle —— 这是一条「应用外的链接」，目标 App 得由系统按
    //  URL 现算。以前这一格直接放行，于是链接整屏打开。
    //
    //  补两步：先把 URL 掏出来（`__PayloadURL` / 通用链接 → action 自身），
    //  再问 LaunchServices 这条 URL 归谁。答出来就照常走下面那套分流，与
    //  「请求里本来就带 bundle」完全同一条路，不新增分支。
    if (target == nil || ![target isKindOfClass:[NSString class]] ||
        [(NSString *)target length] < 3) {
        NSString *viaURL = AevonOpenURLOf(request, options);
        if (viaURL.length == 0) viaURL = AevonActionURL(AevonOpenFirstAction(request, options));
        NSString *resolved = AevonTargetForURLString(viaURL);
        if (resolved != nil) {
            id action = AevonOpenFirstAction(request, options);
            char shape[40];
            AevonURLShape(viaURL, shape, sizeof(shape));
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: bundle from url b=%@ act=#%s shape=%s",
                          resolved,
                          action != nil ? object_getClassName(action) : "-",
                          shape] UTF8String]);
            target = resolved;
        }
    }
    if (target == nil) { *why = "nobundle"; return 0; }
    const char *raw = [(NSString *)target UTF8String];
    if (raw == NULL || strlen(raw) < 3) { *why = "nobundle"; return 0; }
    snprintf(bundle, size, "%s", raw);

    // SpringBoard 自己也有开请求（解锁后回到主屏之类）。吞掉它就是吞掉主屏。
    if (strncmp(bundle, "com.apple.springboard", 21) == 0) { *why = "springboard"; return 0; }

    // 0.2.77 — 连击熔断（第二个尺，需要 bundle）。同一个 App 3 秒内被分走 6 次，
    // 说明我们的分流正在自己喂自己 —— 放过这一条，等它自己散。
    if (AevonDivertCapKind(bundle) == 2) { *why = "loop"; return 0; }

    // 0.2.76 — 落点已经接了，分流让路（见 `AevonLandingClaim`）。
    //
    // 一次 openURL 依次经过两处：`_openURLCore:`（落点钩子，外层）与
    // `_handleOpenApplicationRequest:`（这个钩子，内层）。落点已经把卡排上了，
    // 这里再排一张就是一大一小两个窗口；而这里若按 `share` 吞掉，系统那次激活
    // 也会跟着消失 —— 落点的收卡链等的正是那次激活。两条都不成立，只能让路。
    if (AevonLandingClaim[0] != '\0' && strcmp(AevonLandingClaim, bundle) == 0 &&
        CFAbsoluteTimeGetCurrent() - AevonLandingClaimAt < 2.0) {
        *why = "landing";
        return 0;
    }

    // 0.2.55 — 微信 / QQ 的每一次打开先照一张相（见 `AevonSsoProbe`）。
    if (strncmp(bundle, "com.tencent.xin", 15) == 0 ||
        strncmp(bundle, "com.tencent.mqq", 15) == 0) {
        AevonSsoProbe(request, options, bundle);
    }

    // 0.2.4 — 黑名单：命中就**整条放行**，既不进浮窗也不吞请求。
    //
    // 这条闸必须在判据之前。黑名单的语义是「这个 App 别碰我的路」，它跟「这次是
    // 通知还是分享」无关 —— 放到判据后面，命中的 App 仍会被当成通知吞一次。
    // 放行的写法与 `springboard` / `plain` 相同（返回 0，原实现照常跑），所以
    // 系统怎么打开它，现在就怎么打开，一个字节都没被动过。
    if (AevonWindowBlacklisted(bundle)) { *why = "blacklist"; return 0; }

    // 0.2.77 — 上一跳解析不出来的那条 URL，到这里已经有答案了。
    //
    // `_openURLCore:` 是外层：它手里有 URL，却说不出归谁（Aevon(211)：
    // `chinaunicom://safepay/ b=-`）。这一层的 `bundle` 是系统自己算出来的，
    // 权威得多 —— 借它的答案，不再自己猜一遍。
    //
    // 关键：这里**不吞**。URL 的交付走系统的原路（`display` 早就原样交出去了），
    // 我们只把收卡链排上：`AevonLandCardSchedule` 等 scene 一登记就接管
    // （0.2.66 的「scene 是钥匙」）。最坏的结果与现在一模一样 —— 整屏，
    // 不会让 URL 送不到，也不会像 0.2.69 那样把主屏的前台弄丢。
    if (AevonLinkPendingAt > 0) {
        double age = CFAbsoluteTimeGetCurrent() - AevonLinkPendingAt;
        AevonLinkPendingAt = 0;
        // 三条都与「这是一次新的激活」有关，任何一条不成立就照常往下走：
        //   · `age` —— 超过 0.9 s 的已经与这次打开无关了；
        //   · 已经在最前面的那个不是「被打开的目标」，多半是来源 App 自己回来；
        //   · 已经在卡里的不用再排一次（会撞 `AevonOpenCardDirect` 的复用）。
        if (age < 0.9 && !AevonBundleIsAuthFamily(bundle) &&
            AevonAppFrontmost([NSString stringWithUTF8String:bundle]) != 1 &&
            AevonCardIsUpFor(bundle) != 1 && AevonCardIsComingFor(bundle) != 1) {
            snprintf(AevonLandingClaim, sizeof(AevonLandingClaim), "%s", bundle);
            AevonLandingClaimAt = CFAbsoluteTimeGetCurrent();
            char shape[48];
            AevonLandingShape(AevonLinkPending, shape, sizeof(shape));
            AevonLogRaw([[NSString stringWithFormat:@"notify: link late b=%s age=%dms shape=%s",
                          bundle, (int)(age * 1000.0), shape] UTF8String]);
            AevonLandCardSchedule(bundle);
            *why = "urllate";
            return 0;
        }
    }

    // 0.2.1 — 三条证据先取好，再判路。
    //
    // 0.1.97 那条「带 payload 就算分享」太宽：它把 SpringBoard 自己派生出来的后续
    // 请求也当成分享（Aevon(169) 里 14 次 `src=com.apple.springboard pay=payload`），
    // 于是通知那条路整段跑不到（清通知没做），还每次白交一次原实现。所以这里给
    // 它加一个前提：来源不是 SpringBoard。
    int notifyAct = AevonOpenIsNotificationAction(AevonOpenFirstAction(request, options)) ? 1 : 0;
    int notifyOrg = notifyAct ? 0 : (AevonOpenIsNotificationOrigin(request, options) ? 1 : 0);
    int notifyKind = (notifyAct || notifyOrg) ? 1 : 0;
    int carrier = AevonOpenCarriesPayload(request, options) ? 1 : 0;
    int sysFrom = AevonOpenSourceIsSpringBoard(request, options) ? 1 : 0;

    const char *kind = NULL;
    if (notifyKind) {
        // 两个判据分开写进 `why`，否则「通知中心那条补上了没有」在日志里看不出来：
        // `notify` = 老判据（`__Actions` 类名），`notifyOrigin` = 新判据（`__LaunchOrigin`）。
        kind = notifyAct ? "notify" : "notifyOrigin";
    } else if (!AevonShareSwitchOff() &&
               (AevonOpenIsShareSource(request, options) || (carrier && !sysFrom))) {
        kind = "share";
    }

    // 判据先于「同一次点击的第二条」：先确认这是要接管的那两种之一，再谈它是不是
    // 上一次的后续。顺序反过来，用户在 1.5 秒内点桌面图标也会被当成链条吞掉 ——
    // 那是一个真实的「点了没反应」。
    //
    // 同一次点击的第二条（open → trusted 之间只隔几毫秒）。第一条被吞掉之后
    // 链条通常就断了；真来了也不能再开一次卡片，否则屏幕上一大一小的两个。
    double now = CFAbsoluteTimeGetCurrent();
    int sameChain = (AevonDivertAt > 0 && now - AevonDivertAt < 1.5 &&
                     strcmp(bundle, AevonDivertBundle) == 0);

    // 0.2.49 — 链接 / 登录授权**先于分享判定**。
    //
    // 0.2.48 把它放在 `kind == NULL` 里，真机上两类请求都到不了：应用调
    // `openURL:` 时来源是那个 App（不是 SpringBoard）且带 payload，于是先被上面
    // 的判据归成 `share`；微信 / QQ 的 SSO 深链还常常捎带 `__PasteSharingToken`
    // （Aevon 0.2.48 日志，14:42:31 的 `src=com.midea.msmart.appstore pay=url`），
    // 又被 `paste` 那一支整条放行 ⇒ 先全屏、再回桌面、最后才建卡。
    //
    // 判据只看「带 URL」：从桌面点图标没有 URL，相册里的文件也没有 URL，
    // 误吞它们等于「点了没反应」。Safari 只认 http(s)；微信 / QQ 认它们的
    // SDK 深链族（登录授权、支付、分享回跳）。通知点击不走这一支，那条路还要
    // 清通知，顺序不能动。
    if (!notifyKind) {
        NSString *linkURL = AevonOpenURLOf(request, options);
        int isSafari = strncmp(bundle, "com.apple.mobilesafari", 22) == 0;
        // 0.2.72 — 支付并入授权一族。
        //
        // 逆向对照（FloatingView / Stheno / SplitView）：它们没有一条按 scheme
        // 或 bundle 特判微信 / QQ / 支付宝，接管的是「**应用启动**」这件事本身
        // （`FBSystemService -openApplication:options:withResult:`、
        // `SBMainWorkspace -_activateBundleID:…withResult:`）。所以凡是落到
        // 「系统要激活一个 App」的请求，在它们那里都进同一个窗口；Aevon 这边
        // 对应的就是这一支。支付宝 / 云闪付被支付 SDK 拉起时形状与微信登录
        // 完全相同（带 URL + 来源是第三方 App），漏掉它们等于每次支付都整屏。
        int isOAuth = !isSafari &&
            (strncmp(bundle, "com.tencent.xin", 15) == 0 ||
             strncmp(bundle, "com.tencent.mqq", 15) == 0 ||
             strncmp(bundle, "com.alipay.iphoneclient", 23) == 0 ||
             strncmp(bundle, "com.eg.android.AlipayGphone", 27) == 0 ||
             strncmp(bundle, "com.unionpay", 12) == 0);
        // 0.2.53 — 通用链接被系统解析到了别的 App（GitHub 之类）：改投 Safari。
        // 条件是「browsing-web 活动 + 没有 paste token + 不是分享」，所以只命中
        // 「用户点了一个网页链接」这一种，不会误伤深链回调和分享。
        int isWebLink = (!isSafari && !isOAuth &&
                         AevonOpenIsBrowsingWeb(request, options) == 1 &&
                         AevonOpenAnyValue(request, options, @"__PasteSharingToken") == nil &&
                         AevonOpenIsContinuation(request, options) == 0 &&
                         !AevonOpenIsShareSource(request, options));
        if (isSafari || isOAuth || isWebLink) {
            // 0.2.60 — **授权一律交回系统，一张卡都不建。**
            //
            // 0.2.55~0.2.59 试过「认出来 ⇒ 建卡 + 本地投递」。Aevon(201) 判它
            // 不成立，两种失败各有各的机制，而且都不可绕：
            //
            //   · 微信：登录走的是**通用链接**（`https://help.wechat.com/app/…`），
            //     系统把通用链接交给 App 走的是 `NSUserActivity`，不是
            //     `openURLContexts:`。我们只能投 URL，微信收到后不认，于是只
            //     打开主页（用户报的「没有授权选项」）。日志里 `ack ok=1 via=scene`
            //     同时出现，正说明「投递成功」与「微信照做」是两件事。
            //   · QQ：SSO 是 `mqqOpensdkSSoLogin://SSoLogin/<appid>/`，需要 QQ 真的
            //     被系统激活为前台，回跳才有 XPC 通道把 code 交回去。卡片里的 QQ
            //     拿到的是「被显示」而不是「被激活」，回跳握手断在半路 ——
            //     QQ 显示授权成功、全屏 App 停在授权失败。
            //
            // 这两条都不是我们能在 SpringBoard 里补出来的东西。所以授权这一族
            // 回到「装插件之前」的行为：原样放行、系统自己拉起微信 / QQ、用户
            // 授权完再回到那个 App。代价是授权那一下是全屏，收益是登录真的能成。
            //
            // 判据只用「来源不是分享链路」：分享到微信 / QQ 也带 `weixin://`，
            // 那种必须进卡片（下面那几条分支管），不能被这里截走。
            if (isOAuth && !AevonOpenIsShareSource(request, options)) {
                char shape[40];
                AevonURLShape(linkURL, shape, sizeof(shape));
                // 0.2.79 — **撤掉 0.2.74 的「吞掉 + 自建 scene + 本地投递」。**
                //
                // Aevon(212) 的四条现场把它证伪了，而且每一条都能指到同一处：
                //
                //   · QQ  `appurl ack ok=1 via=app-src … dlg=- rsp=0`
                //         —— URL 投进去了，QQ 的 OpenSDK 一个字都没接。卡片里
                //         没有授权页，用户看到的就是「小窗开着、里面是 QQ 主页」。
                //   · 支付宝 `appurl give why=timeout at=6342ms`
                //         —— 连回执都没有。
                //   · 微信第二次 `own live attach` + `launch state cs=0`
                //         —— 贴到上一张卡留下的空壳 scene，整张卡是黑的。
                //
                // 三条是同一个根：**自建 scene 里没有系统那一次激活**。微 / QQ /
                // 支付宝的授权与支付，全靠系统激活那一拍把 SDK 叫醒，URL 只是
                // 附带品。0.2.55~0.2.59 试过投递，0.2.74~0.2.78 又试了一遍，
                // 两次都是同一个结果：投递成功、业务不认。
                //
                // 所以回到 0.2.60~0.2.73 的路（这条路上登录是成立的，代价是先
                // 整屏一小段）：**请求原样交给系统**，`display` 一个字节都不改；
                // 15 ms 一拍盯着 scene，scene 一登记就收进卡片
                // （`AevonAuthSwapSchedule` → `AevonAuthSwapTick`）。
                // 参考三家的共同做法也是这一条 —— 它们不投 URL，只改落点。
                AevonAuthSeenNote(bundle);
                AevonLogRaw([[NSString stringWithFormat:
                              @"notify: oauth native b=%s src=%@ scheme=%s pay=%s url=%d card=%d",
                              bundle,
                              AevonOpenSourceApp(request, options) != nil
                                  ? (id)AevonOpenSourceApp(request, options) : @"-",
                              shape, AevonOpenPayloadKind(request, options),
                              linkURL.length > 0 ? 1 : 0,
                              (AevonCardIsUpFor(bundle) == 1 ||
                               AevonCardIsComingFor(bundle) == 1) ? 1 : 0]
                             UTF8String]);
                // 微信 / QQ 如果已经在我们某张卡里，先让路（handover）。
                // 不在这一栈里 destroy：`AevonOpenDecide` 跑在
                // `_handleOpenApplicationRequest` 的钩子内，FrontBoard 正持着
                // scene 更新那把锁，0.0.31 的死锁纪律同样适用于 destroy。
                // 「全屏中下黑」的另一半（App 仍按卡片高度排）在 App 侧修：
                // band 被清成 none 的那一刻把窗口还回场景高。
                // 0.2.62 — 放行这一拍**先松手**。
                //
                // Aevon(203) 第 2 条：QQ 整屏打开时下半部分是黑的。这一族请求
                // 在 0.2.61 之前都由 `openCard` 接走，目标是「按 430×717 摆」；
                // 现在改成放行，如果我们还留着那条登记，`intercept` 就会继续把
                // 系统的全屏 settings 改回 717 —— 全屏只画上半截，剩下 215 pt
                // 没有窗口在画，就是黑的。所以「交给系统」这三个字必须包含
                // 「把我们的登记撤掉」，否则等于一边放手一边拽着。
                NSString *targetID = [NSString stringWithUTF8String:bundle];
                if (targetID != nil) {
                    AevonSceneFrameClearBundle(targetID);
                    AevonHookDisarm(targetID);
                }
                if (AevonCardIsUpFor(bundle) == 1) {
                    AevonCardYieldForFullscreen(bundle);
                }
                // 0.2.62 — **放行，但只让它整屏存在一百毫秒。**
                //
                // Aevon(203) 第 1 条：0.2.60 的「授权一律交回系统」把登录修好了，
                // 代价是 QQ / 微信整屏 —— 用户当场退回来。两条路都试过之后，
                // 能同时成立的只剩这一种组合：
                //   · 请求照常交给系统 ⇒ QQ 的 SSO 回跳、微信的 NSUserActivity
                //     都由系统投递（这两条我们自己补不出来，0.2.55~0.2.59 已证）；
                //   · 激活之后立刻收卡 ⇒ 用户看到的是浮窗，不是全屏。
                // 判据在日志里成对出现：`notify: oauth pass …` 紧跟
                // `notify: auth swap card b=… after=100ms`。
                //
                // 0.2.70 — **不要试图压住这次激活。**
                //
                // 0.2.69 曾在这一条请求的 settings 上置挂起位（「照常激活、但不
                // 摆到屏上」）。它的前提不成立：挂起的进程不跑，QQ 的 SSO XPC 与
                // 微信的 NSUserActivity 都没人接；而 0.2.69 的分享那条路已经用
                // 真机证明「让系统激活一个不上屏的目标 = 主屏没有前台 App」。
                // 同样的形状不能再放进授权这条唯一的登录通道。
                //
                // 所以这一版与 0.2.68 完全一致：请求原样交给系统，50 ms 后收卡。
                // 代价仍是「先整屏一小段」（`first frame shown after …` 就是那段
                // 窗口的实测值），但登录一定成立、主屏一定有人接手势。
                AevonAuthSwapSchedule(bundle);
                *why = "oauthpass";
                AevonDivertAt = now;
                snprintf(AevonDivertBundle, sizeof(AevonDivertBundle), "%s", bundle);
                return 0;
            }
            if (linkURL.length == 0) {
                // 登录也可能整条装在 paste token 里（没有 URL）。留一行，下一轮
                // 就能看出「微信登录到底是 url 还是 paste」，不用再靠猜。
                // 0.2.51 — 补上 `keys=`：上一版只知道「没 URL」，不知道 options 里
                // 到底有什么键。这一行能直接把「URL 挂在哪一层」照下来。
                char linkKeys[152];
                AevonOpenKeysOf(options, linkKeys, sizeof(linkKeys));
                // 0.2.58 — 同样补 `card=`：微信登录最常见的那一种（`pay=paste` +
                // `url=none`）走的就是这一支，有没有卡直接决定下一版能不能本地投递。
                int inCardSkip = (AevonCardIsUpFor(bundle) == 1 ||
                                  AevonCardIsComingFor(bundle) == 1) ? 1 : 0;
                AevonLogRaw([[NSString stringWithFormat:
                              @"notify: link skip b=%s scheme=- pay=%s cont=%d url=none card=%d keys=%s",
                              bundle, AevonOpenPayloadKind(request, options),
                              AevonOpenIsContinuation(request, options),
                              inCardSkip,
                              linkKeys[0] != '\0' ? linkKeys : "-"]
                             UTF8String]);
            } else {
                NSString *low = [linkURL lowercaseString];
                const char *scheme = low.UTF8String;
                int web = (strncmp(scheme, "http://", 7) == 0 ||
                           strncmp(scheme, "https://", 8) == 0);
                int wanted = 0;
                if (isSafari || isWebLink) {
                    wanted = web;
                } else {
                    // 0.2.51 — 不再按 scheme 白名单猜。
                    //
                    // 登录走哪条深链由微信 / QQ 的 SDK 决定（`weixin://`、
                    // `mqqopensdkapi://`、通用链接……换一个 SDK 版本就变），
                    // 白名单每漏一条，用户看到的就是「又先全屏了」。真正稳定的分界
                    // 只有两条：
                    //   · `UIActivityContinuationAction` = 分享面板，必须原样交给系统
                    //     （分享内容在系统那次激活里，本地投递顶掉就等于丢内容）；
                    //   · 来源是 sharingd / ShareExtension / sharetimeline = 分享，同理。
                    // 两条都不是、又确实带 URL 的，就是登录授权，可以建卡本地投递。
                    //
                    // 0.2.53 — 再排掉 `file://` / `data:`。QQ 的文件分享走的是
                    // 「带 paste token 的 payload」：`act=-`（没有 continuation），
                    // 来源也是普通 App，只看前两条会和登录一模一样。区别在载荷本身：
                    // 分享的是文件 URL，登录的是网页 / SDK 深链。认错这一条的代价是
                    // 文件根本发不出去。
                    int fileURL = (strncmp(scheme, "file://", 7) == 0 ||
                                   strncmp(scheme, "data:", 5) == 0);
                    // 0.2.59 — 授权链接**不受 `UIActivityContinuationAction` 约束**。
                    //
                    // Aevon(200) 里微信登录那一条是：
                    //   notify: sso b=com.tencent.xin pay=paste cont=1 … url=https len=670
                    //   notify: link skip b=com.tencent.xin scheme=https://help.wechat.com/app/…/auth/…
                    //   notify: pass  b=com.tencent.xin why=paste src=com.midea… 
                    // 也就是说微信的 SDKv2 把登录走成**通用链接 + 续接动作 + paste token**，
                    // 三条特征里两条指向「分享」，于是 `wanted` 判成 0，整条放行 ——
                    // 系统把微信拉成全屏，60 ms 后 `share swap` 再把它收进卡片，
                    // 屏幕上来回跳的就是这两拍。
                    //
                    // 续接动作本来是「分享面板」的标记，但 URL 路径里写着 `/auth/`
                    // 的时候，这次续接装的是**登录页**，不是分享内容：登录只需要那条
                    // URL，本地投递就够，根本不必让系统激活任何东西。
                    int authURL = AevonOpenIsAuthURL(linkURL);
                    wanted = ((AevonOpenIsContinuation(request, options) == 0 || authURL) &&
                              !AevonOpenIsShareSource(request, options) &&
                              !fileURL);
                }
                if (wanted) {
                    if (isWebLink) {
                        // 0.2.53 — 用户点的是网页链接，系统却把它解析给了另一个 App
                        // （GitHub 之类）。把目标改写成 Safari：原请求不再交给系统，
                        // 那个 App 整屏弹一下的中间步骤就不会发生；卡片和 URL 投递
                        // 走的还是同一条路。
                        AevonLogRaw([[NSString stringWithFormat:
                                      @"notify: link retarget from=%s to=safari scheme=%s",
                                      bundle,
                                      scheme != NULL && scheme[0] != '\0' ? scheme : "-"]
                                     UTF8String]);
                        snprintf(bundle, size, "%s", "com.apple.mobilesafari");
                    }
                    // 目标已经整屏在屏上（例如 Safari 正开着，后台某个 App 又发了
                    // 一条链接）：这条请求放它照常走，别为了建卡把用户按回桌面。
                    // `isFrontmost` 只对 SpringBoard 的 `SBApplication` 有效，读不到
                    // 时是 0 / -1，仍然走卡片，不影响正常场景。
                    //
                    // 0.2.58 — 「整屏在屏上」不等于「在我方卡片里」。
                    //
                    // 卡片里的 App 在我们的 scene 里被设成 foreground，SpringBoard 的
                    // `isFrontmost` 对它同样答 1。旧判据把这两种混成一件事，于是
                    // 授权回调（微信 / QQ 处理完 SSO 回到发起登录的那个 App）被当成
                    // 「用户正开着它」，整条放行 —— 系统就把那个 App 从卡片里拽成
                    // 全屏。用户看到的就是「授权时跳一下全屏，然后才回到浮窗」。
                    //
                    // 卡里的那一种不该放行：它本来就该留在卡里。继续往下走会落到
                    // `*why = kind`（oauth / safari）→ 返回 1 → `openCard`。而
                    // `openCard` 对「已是主窗」「在停靠小窗」都有判重，认出来之后
                    // 调的是 `AevonForwardDeliver` 把 URL 投进同一张卡，不重建 scene。
                    int frontNow = AevonAppFrontmost([NSString stringWithUTF8String:bundle]);
                    int inCard = (AevonCardIsUpFor(bundle) == 1 ||
                                  AevonCardIsComingFor(bundle) == 1) ? 1 : 0;
                    if (frontNow == 1 && inCard == 0) {
                        *why = "plain";
                        return 0;
                    }
                    if (frontNow == 1 && inCard == 1) {
                        // 判据：这一行出现 ⇒ 卡里的 App 被 SpringBoard 认成前台，
                        // 旧版正是在这里放行成全屏。
                        AevonLogRaw([[NSString stringWithFormat:
                                      @"notify: link incard b=%s scheme=%s front=%d",
                                      bundle, scheme != NULL && scheme[0] != '\0' ? scheme : "-",
                                      frontNow]
                                     UTF8String]);
                    }
                    // 同一次点击派生出来的第二条：第一条已经把卡和 URL 接过去了，
                    // 这条再吞一次，绝不能让它落回原实现把 App 拉成整屏。
                    if (sameChain) {
                        *why = "linkchain";
                        return 2;
                    }
                    // 0.2.87 — **并轨母版：这一族不再吞掉。**
                    //
                    // 判据来自 Stheno 0.1.23 的二进制（`Stheno.dylib` 2,153,664 B，
                    // 逐条计数见 `stheno-selector-surface.txt` 与 cstring 表）：
                    //   · `_openURLCore` 命中 **0** —— 母版从不拦 URL 打开；
                    //   · `_activateBundleID:requestID:isTrusted:options:source:
                    //     originalSource:withResult:` 命中 **2** —— URL 装在**激活请求的
                    //     options** 里，由系统在激活那一拍投给目标 App；
                    //   · `setActions:` 命中 **0** —— 它不往 scene 的 transitionContext
                    //     里塞 action，所以「definition 带 URL」「transitionContext 带 URL」
                    //     两条路都不是它的路；
                    //   · `createPresenterWithIdentifier:priority:` 命中 **4** ——
                    //     承载层才是它的主场。
                    //
                    // 母版三条路（分享 / 授权 / 普通深链）是同一个形状：**请求原样交给
                    // 系统**，等 scene 登记，再把那份 scene 接进浮窗。我们此前把这一族
                    // 单独吞下来、自建 scene、再用 `AevonForwardDeliver` 本地投 URL ——
                    // 那条路在 Aevon(212) 已证伪（QQ `rsp=0`、支付宝 `timeout 6342ms`、
                    // 微信空壳），根因就是「自建 scene 里没有系统那一次激活」。
                    //
                    // 代价与 `why=oauthpass` 一致：系统会把目标整屏演一小段，我们
                    // 15 ms 一拍盯着，scene 一登记就收卡（`AevonAuthSwapTick`）。
                    *why = (isSafari || isWebLink) ? "safaripass" : "linkpass";
                    // 只记 scheme，不记整条 URL：授权链接里带 ticket / code，
                    // 不该落进日志。
                    char schemeText[16] = {0};
                    size_t slen = 0;
                    while (scheme != NULL && scheme[slen] != '\0' &&
                           scheme[slen] != ':' && slen < sizeof(schemeText) - 1) {
                        schemeText[slen] = scheme[slen];
                        slen += 1;
                    }
                    // 0.2.58 — 补 `card=`：这一格把「整屏在屏上」与「在我方卡片里」
                    // 分开，也是判断上面那条判据有没有生效的唯一读数。
                    AevonLogRaw([[NSString stringWithFormat:
                                  @"notify: link native b=%s kind=%s scheme=%s front=%d card=%d",
                                  bundle, *why, schemeText[0] != '\0' ? schemeText : "-",
                                  frontNow, inCard]
                                 UTF8String]);
                    AevonAuthSwapSchedule(bundle);
                    return 0;
                }
                // 0.2.50 — 没认出来的那一次也留一份形状，下一轮不用再猜：
                // `pay` 是 none / url / paste / payload，`cont` 是分享 action 位。
                // 0.2.51 — 补 `share`（来源是不是分享链路）与 `keys`。
                char skipKeys[152];
                AevonOpenKeysOf(options, skipKeys, sizeof(skipKeys));
                AevonLogRaw([[NSString stringWithFormat:
                              @"notify: link skip b=%s scheme=%s pay=%s cont=%d share=%d keys=%s",
                              bundle,
                              scheme != NULL && scheme[0] != '\0' ? scheme : "-",
                              AevonOpenPayloadKind(request, options),
                              AevonOpenIsContinuation(request, options),
                              AevonOpenIsShareSource(request, options) ? 1 : 0,
                              skipKeys[0] != '\0' ? skipKeys : "-"]
                             UTF8String]);
            }
        }
    }
    // 0.2.67 — 微 / QQ 把「授权结果」送回发起方，**通用链接那一版带续接动作**。
    //
    // Aevon(205) 的现场（21:40:05 / 21:40:24）：
    //   notify: sso b=com.midea.msmart.appstore pay=payload cont=1 share=0 …
    //           src=com.tencent.xin act=#UIActivityContinuationAction url=https len=670
    // 微信正开在屏上（授权页），它把用户送回发起登录的 App，走的是 `https`
    // 通用链接 + `UIActivityContinuationAction`。旧判据把「续接动作」一律当分享
    // 面板，于是这条被收进卡片 —— 屏幕上是「微信整屏 + 美的悬浮窗」，用户报的
    // 「悬浮窗会和全屏应用混乱小窗」就是这一下。
    //
    // 分界不看续接动作，看**收信方**：微 / QQ → 第三方 App 只有两种，
    // 授权回跳与「从微信里把东西分享给某个 App」。两者都该由系统原样交付：
    // 用户点的就是那个 App，把它按进小窗只会让人一愣。真的在传文件的那一种
    // 仍带 `__PasteSharingToken`，继续走下面的 share 路。
    int returnShape = (kind != NULL && strcmp(kind, "share") == 0 &&
                       AevonOpenSourceIsSso(request, options) == 1 &&
                       AevonOpenTargetIsSso(bundle) == 0) ? 1 : 0;
    int returnTokenless = (returnShape &&
        AevonOpenAnyValue(request, options, @"__PasteSharingToken") == nil) ? 1 : 0;
    int returnKnown = 0;
    if (returnShape && !returnTokenless) {
        // 0.2.79 — **带 paste token 的授权回跳也是回跳。**
        //
        // Aevon(212) 12:21:07 的现场：
        //   notify: share source b=com.tencent.xin target=com.tcl.tclplus
        //   notify: paste token b=com.tcl.tclplus cls=UISPasteSharingToken
        //   notify: paste promote schedule b=com.tcl.tclplus
        //   notify: paste promote card b=com.tcl.tclplus …
        // 微信把登录结果塞在粘贴板里送回来，旧判据一句 `token == nil` 就把它
        // 划成了分享，于是 `paste promote` 在 60 ms 后把**发起登录的那个 App**
        // 从全屏收进了卡片 —— 用户报的「发起授权的 App 也变成悬浮窗」就是这一下。
        //
        // 收窄到两条同时成立才认：来源是微 / QQ **本体**（不是 .sharetimeline /
        // .ShareExtension 那些扩展），且 30 秒内真的发生过一次授权。分享面板
        // 递过来的文件两条都不满足，仍然走原来的 `paste` 路。
        NSString *srcExact = AevonOpenSourceApp(request, options);
        int exact = ([srcExact isKindOfClass:[NSString class]] &&
                     ([srcExact isEqualToString:@"com.tencent.xin"] ||
                      [srcExact isEqualToString:@"com.tencent.mqq"])) ? 1 : 0;
        if (exact && AevonAuthReturnMatched(srcExact) == 1) returnKnown = 1;
    }
    if (returnShape && (returnTokenless || returnKnown)) {
        int inCard = (AevonCardIsUpFor(bundle) == 1 ||
                      AevonCardIsComingFor(bundle) == 1) ? 1 : 0;
        // 只有「刚发生过授权」才收递结果那一方的卡；用户只是从微信里点了个
        // 分享链接时，他还在用微信，那张卡不能动。
        int recent = AevonAuthReturnMatched(AevonOpenSourceApp(request, options));
        if (recent) {
            AevonAuthCardCloseSoon(AevonOpenSourceApp(request, options), "return");
        }
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: auth return b=%s src=%@ recent=%d in=%d ptk=%d",
                      bundle,
                      AevonOpenSourceApp(request, options) != nil
                          ? (NSString *)AevonOpenSourceApp(request, options) : @"-",
                      recent, inCard, returnTokenless ? 0 : 1] UTF8String]);
        *why = "authreturn";
        return inCard == 1 ? 1 : 0;
    }

    // 0.2.59 — SSO 回跳：微信 / QQ 处理完授权，把结果送回**发起登录的那个 App**。
    //
    // 它和「分享」在 options 上长得一模一样（`kind=share` + 带 payload + 带 paste
    // token），所以旧版落到下面那条 `paste` 分支：先整条放行给系统（目标 App 被
    // 推成全屏），再排一拍 `paste promote` 把它收进卡片。用户报的两件事都在这一条
    // 上：
    //   · 「QQ 显示授权成功，全屏 App 没登录」—— 回跳被放行之后 60 ms 又被我们
    //     收成卡片，App 在两次激活之间把 SDK 的回调吃掉了；
    //   · 「微信和全屏 App 乱跳小窗」—— 放行那一拍全屏、收卡那一拍又回小窗。
    //
    // 回跳与分享的稳定分界只有一条：**回跳没有续接动作**（Aevon(200) 两条现场，
    // 回跳 `ac=-`，分享 `ac=#UIActivityContinuationAction`）。所以：
    //   · 目标已经在卡里 ⇒ 本地投递（`incard`），App 就在卡里登录，一次激活都不多；
    //   · 目标整屏开着（用户本来就在用那个 App）⇒ **原样放行、不排 promote**。
    //     放行会让系统把 URL 交给它，这正是 SDK 要的；不 promote 才不会在 60 ms
    //     后把它从全屏拽进卡片，登录也就不会断在半路。
    if (kind != NULL && strcmp(kind, "share") == 0 &&
        AevonOpenSourceIsSso(request, options) == 1 &&
        AevonOpenIsContinuation(request, options) == 0 &&
        // 0.2.60 — 收信方必须是**第三方 App**。
        //
        // Aevon(201) 的两条现场（18:49:06 分享给 QQ、18:50:20 分享给微信）：
        //   notify: sso b=com.tencent.mqq … share=1 src=com.tencent.mqq.ShareExtension
        //   notify: link skip b=com.tencent.mqq scheme=mqqapi://share/to_fri?…
        //   notify: auth card close b=com.tencent.mqq.ShareExtension why=callback
        //   notify: pass b=com.tencent.mqq op=user why=callback
        // 送信方和收信方是同一家，这明明是「分享」，却被上一条判成「授权回跳」，
        // 于是整条放行、屏幕只剩全屏 —— 用户报的第 4 条正是它。
        AevonOpenTargetIsSso(bundle) == 0 &&
        !AevonOpenIsShareSource(request, options)) {
        int inCard = (AevonCardIsUpFor(bundle) == 1 ||
                      AevonCardIsComingFor(bundle) == 1) ? 1 : 0;
        // 两条路都要收那一方：授权已经交接完，微信 / QQ 那张卡留着没用。
        // 注意这里收的是**递结果的那一方**，不是拿到结果的 App。
        AevonAuthCardCloseSoon(AevonOpenSourceApp(request, options),
                               inCard == 1 ? "incard" : "callback");
        if (inCard == 1) {
            *why = "incard";
            return 1;
        }
        *why = "callback";
        return 0;
    }

    // 0.2.38 — 粘贴板分享（`__PasteSharingToken`）**不建卡**，整条放行。
    //
    // 0.2.36 放行：文件真的发得出去（token 随系统激活过 XPC），但目标 App 全屏。
    // 0.2.37 改成「先建卡、再把原请求交回原实现」，真机结果是**卡片和全屏一起出现、
    // 卡片黑**：`__ActivateSuspended` 只对冷启动成立，而卡片一建，App 就已经在跑了，
    // 挂起位被系统无视 ⇒ 原实现照常把它拉成全屏，和卡片抢同一份 scene。
    // 也就是说：token 这条路**绕不开一次真正的激活**。这一版先把它恢复成 0.2.36
    // 的行为（文件能发、画面干净），并把 token 的形状打出来 —— 下一版尝试把它
    // 转成本地投递，才可能真的做到「悬浮窗 + 文件发出」同时成立。
    if (kind != NULL && strcmp(kind, "share") == 0 &&
        AevonOpenAnyValue(request, options, @"__PasteSharingToken") != nil) {
        *why = "paste";
        AevonDivertAt = CFAbsoluteTimeGetCurrent();
        snprintf(AevonDivertBundle, sizeof(AevonDivertBundle), "%s", bundle);
        AevonPasteTokenProbe(request, options, bundle);
        // 0.2.39 — 放行代表「文件靠系统这一拍送出去」；这一行代表「等它送到之后，
        // 再把目标 App 从全屏收回卡片」。两条互不阻塞。
        AevonPastePromoteSchedule(bundle);
        return 0;
    }

    // 0.2.39 — 微信（`com.tencent.xin.sharetimeline`）那条分享在上一条判据里
    // 拦不到：Aevon(163) 记下来的形状是 `keys=` 空 —— 它没有 token、也没有 URL，
    // 交接发生在系统那次激活里。0.2.10 的处置是把它整条放行走原生（当时宿主里
    // 会崩在 `MBPublicService`），用户现在要求它也进卡片。
    //
    // 所以按 token 同一条路处理：**原样放行**（保证文件真到），再等前台把它收卡。
    // 只有 `pay=none` 才走这里；带 payload 的分享仍走下面那条「先建卡再交回」，
    // 那条已经能直接把卡建起来。
    if (kind != NULL && strcmp(kind, "share") == 0 &&
        strncmp(bundle, "com.tencent.xin", 15) == 0 &&
        strcmp(AevonOpenPayloadKind(request, options), "none") == 0) {
        *why = "wx";
        AevonDivertAt = CFAbsoluteTimeGetCurrent();
        snprintf(AevonDivertBundle, sizeof(AevonDivertBundle), "%s", bundle);
        AevonPastePromoteSchedule(bundle);
        return 0;
    }

    // 0.2.39 — 这里原来有一条「分享黑名单：命中整条放行」。微信移出后名单为空，
    // 整块随 `AevonShareNativeListed` 一起删掉（见该函数位置上的说明）。


    if (kind == NULL) {
        // 0.2.1 — 系统自己接着那条链发来的、带东西的请求：不建卡，但也不许放它
        // 过去。放过去就是「全屏把 App 拉起来」，而那正是用户 0.1.98 报的那一幕。
        // 只在紧跟在我们自己那次分流（1.5 秒）之内才这么判，免得把解锁回主屏之类
        // 的正常请求一起吞掉。
        if (sameChain && carrier && sysFrom) {
            *why = "syschain";
            return 2;
        }
        // 0.2.36 — 卡片正开着这个 App，而系统现在要「普通全屏启动」它。
        //
        // 必须在这里让路：这一支返回 0 之后**紧接着**就是原实现，系统会立刻把
        // 那个 App 推上前台。卡片不让，系统就和我们抢同一份 scene —— 而 intercept
        // 钩子还在按 430x717 写 frame，真机上就是「卡片黑 + 全屏页底部 215 pt 黑」。
        //
        // 同步拆（`closeCard` → 还 frame → 拆 presenter → 交还后台），所以原实现
        // 拿到 scene 时它已经是干净的整屏尺寸。`why=yield` 是这条路的日志判据。
        if (AevonCardIsUpFor(bundle) == 1) {
            // 0.2.58 — 卡里这个 App 自己发起的那条回调：**不拆卡**。
            //
            // 微信 / QQ 处理完 SSO，会带着 `<app>://oauth?code=…` 回到发起登录的
            // App。这条请求的目标是**第三方 App**（不是微信），所以既不进上面那条
            // `isOAuth` 分支、也没有通知 action，`kind` 一直是 NULL —— 旧做法落到
            // 这里，`AevonCardYieldForFullscreen` 把卡拆掉、把 scene 交还整屏，
            // 于是「授权完跳一下全屏，再被重新收进浮窗」。用户报的就是这一下。
            //
            // 让路的理由（0.2.36）是「卡片和原实现抢同一份 scene ⇒ 卡片黑」。但那条
            // 理由只对「系统要把这个 App 整屏推到前台」成立。带 URL 的回调不是
            // 「用户要全屏看它」，是「有事要告诉它」：把 URL 投进卡里的 App 就够了，
            // 根本不必让系统启动任何东西。
            //
            // 返回 1 之后走的就是「建卡 + 本地投递」那条现成的链：`openCard` 认出
            // 这个 App 已经在卡里，直接 `AevonForwardDeliver`，不重建 scene。
            // 条件是 `carrier` —— 没有 payload 就没有可投的东西，那种情况仍然让路，
            // 否则等于把这次打开吞掉。
            NSString *callbackURL = AevonOpenURLOf(request, options);
            if (callbackURL.length > 0 && carrier) {
                *why = "incard";
                return 1;
            }
            // 0.2.60 — Aevon(201) 的现场：从桌面点卡片里的抖音图标，日志是
            //   win: card yield seen b=com.ss.iphone.ugc.Aweme now=430x932 want=430x717
            //   win: card yielded to fullscreen b=…
            //   win: background after teardown door=0 handover=1
            // 之后 app 侧一直读到 `scene=717`，而屏幕是 932 —— 中下 215 pt 黑。
            // 真因不在让路本身，而在**让路之后 App 还按 430x707 的洞排窗口**：
            // band 没被清掉。所以让路仍是 handover（这一栈里 destroy 会撞锁），
            // 修的是下面 `AevonAppBandSet(.null)` 那一句 + App 侧的对齐。
            int yielded = AevonCardYieldForFullscreen(bundle);
            *why = yielded == 1 ? "yield" : "plain";
            return 0;
        }
        *why = "plain";
        return 0;
    }

    if (sameChain) {
        *why = "chain";
        return 2;
    }

    *why = kind;
    AevonDivertAt = now;
    snprintf(AevonDivertBundle, sizeof(AevonDivertBundle), "%s", bundle);
    return 1;
}

/// 只读取一个键。两条路按从便宜到贵的顺序试：
///   ① `objectForKey:` —— 字典本身；
///   ② `valueForKey:`  —— KVC。`__PayloadOptions` 这种私有键只在 KVC 里答。
/// 任何一步抛异常都返回 nil：这条链跑在 SpringBoard 主线程上，一次
/// `NSUndefinedKeyException` 就是杀进程，不是一行日志。
static id AevonActRead(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    SEL boxed = NSSelectorFromString(@"objectForKey:");
    SEL kvc = NSSelectorFromString(@"valueForKey:");
    @try {
        if ([object respondsToSelector:boxed]) {
            return ((id (*)(id, SEL, id))objc_msgSend)(object, boxed, (id)key);
        }
        if ([object respondsToSelector:kvc]) {
            return ((id (*)(id, SEL, id))objc_msgSend)(object, kvc, (id)key);
        }
    } @catch (NSException *exception) {
        return nil;
    }
    return nil;
}

/// 一个对象的名字：字符串取内容、URL 取 absoluteString、其余取类名（带 `#`
/// 前缀，一眼能分出「这是值」还是「这是类型」）。写进调用方给的槽位，所以
/// 整个快照里没有一次堆分配。
static const char *AevonActName(id object, char *slot, size_t size) {
    if (slot == NULL || size == 0) return "-";
    if (object == nil) {
        snprintf(slot, size, "-");
        return slot;
    }
    @try {
        if ([object isKindOfClass:[NSString class]]) {
            const char *raw = [(NSString *)object UTF8String];
            snprintf(slot, size, "%s", raw != NULL ? raw : "-");
            return slot;
        }
        if ([object isKindOfClass:[NSURL class]]) {
            const char *raw = [[(NSURL *)object absoluteString] UTF8String];
            snprintf(slot, size, "%s", raw != NULL ? raw : "-");
            return slot;
        }
        const char *name = class_getName([object class]);
        snprintf(slot, size, "#%s", name != NULL ? name : "?");
    } @catch (NSException *exception) {
        snprintf(slot, size, "!");
    }
    return slot;
}

/// `_cmd` → 四条里的下标。不是我们的就返回 -1（那种情况下原样转发，什么都不记）。
static int AevonOpenSlot(SEL cmd) {
    for (int i = 0; i < AevonOpenMax; i++) {
        if (AevonOpenSel[i] != NULL && AevonOpenSel[i] == cmd) return i;
    }
    return -1;
}

/// 0.2.7 — `options` 的键名列表，抽成独立函数。
///
/// 原来是写在 `AevonOpenSnapshot` 里的内联循环，且被 `AevonOpenKeyNotes < 3`
/// 卡着只打三拍。分享那条路在真机上通常排在通知之后，等它到的时候那三拍
/// 早被用掉了 —— 于是「分享时 options 里到底有什么键」这件事，在日志里
/// 一次都看不到。Aevon(173) 那次 `keys=` 是空的，不是因为真的没键。
///
/// 抽出来之后有两处调用：快照（配额照旧 3 次）与分享现场行（独立配额）。
static void AevonOpenKeysOf(id options, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    @try {
        id dump = [options isKindOfClass:[NSDictionary class]]
                ? options
                : AevonActRead(options, @"dictionary");
        if (![dump isKindOfClass:[NSDictionary class]]) return;
        size_t used = 0;
        for (id key in (NSDictionary *)dump) {
            if (![key isKindOfClass:[NSString class]]) continue;
            const char *raw = [(NSString *)key UTF8String];
            if (raw == NULL) continue;
            size_t need = strlen(raw);
            if (used + need + 2 >= size) break;
            if (used > 0) out[used++] = ',';
            memcpy(out + used, raw, need);
            used += need;
            out[used] = '\0';
        }
    } @catch (NSException *exception) {
        out[0] = '\0';
    }
}

/// 0.2.7 — 分享现场行。**只读，只写日志。**
///
/// 为什么单独一行、而不是往 `notify: hit` 里加字段：hit 有 32 拍 / 每槽 10 拍
/// 的总预算，分享常常排在第 11 拍之后，根本轮不到。而分享这条路是三家综合
/// （Myrtle 的 rehost + 参数化重试、Mango 的判内容就绪、TrollOpen 的自建 scene）
/// 里唯一还没拿到真机现场的一段 —— 没有这行，下一版还是只能猜。
///
/// 记录：bundle / 来源进程 / payload 类型 / 动作类名 / LaunchOrigin /
///      结果块形状 / 挂起键读回值 / settings 四个能力 / options 全部键。
static int AevonShareNotes = 0;
/// 0.2.8 — 上一次转发真正写进去的 `__ActivateSuspended` 值。
/// 分享现场行原来读的是**原始** options（我们写的是副本），所以恒为 -1；
/// 这个变量记的是写后回读到的真值，`fsusp=` 就是它。
/// 0.2.9 — 只有 `AevonOpenForwardPayload` 写它，任何地方都不再复位：重入会把复位吃掉。
static int AevonForwardSuspLast = -1;

/// 把一个可能是 NSString 也可能是 NSURL 的值变成可读文本。**只读**。
static void AevonOpenValueText(id value, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (value == nil) return;
    @try {
        if ([value isKindOfClass:[NSString class]]) {
            const char *raw = [(NSString *)value UTF8String];
            snprintf(out, size, "%s", raw != NULL ? raw : "-");
            return;
        }
        SEL absSel = sel_registerName("absoluteString");
        if ([value respondsToSelector:absSel]) {
            id text = ((id (*)(id, SEL))objc_msgSend)(value, absSel);
            if ([text isKindOfClass:[NSString class]]) {
                const char *raw = [(NSString *)text UTF8String];
                snprintf(out, size, "%s", raw != NULL ? raw : "-");
                return;
            }
        }
        snprintf(out, size, "<%s>", object_getClassName(value));
    } @catch (NSException *exception) {
        snprintf(out, size, "<threw>");
    }
}

/// 0.2.12 — 「挂起位到底叫什么」。这一版唯一要回答的问题，也是唯一没碰过的一层。
///
/// 0.2.9 的 `win: act dump` 已作废：四个 tag（open / trusted / untrusted / user）
/// 全是 `n=1 _settings=0x1` —— 这个类**只有一个 ivar，就是一个位掩码**，四组做差
/// 在数学上不可能有结果。0.2.11 的 `win: act api` 给了 24 个方法，其中三个正是这里
/// 要用的：
///   · `keyDescriptionForSetting:`                    下标 → 名字（主读数）
///   · `valueDescriptionForFlag:object:ofSetting:`     某下标下某个 flag 值 → 名字
///   · `setFlag:forActivationSetting:` / `flagForActivationSetting:`  写 / 读
///
/// 为什么这一次可能是对的：`__ActivateSuspended` 那个 **options 键** 改了两版都没用，
/// 因为 options 是**输入**，SpringBoard 在进这几个入口之前就已经用
/// `_updateActivationSettings:forRequestWithOptions:clientProcess:application:` 把它
/// 折算成 settings 了（这个选择子本身就是证据）。我们改 options，改的是**已经被读过**
/// 的东西；后续激活逻辑真正读的是第 4 个参数那个 `SBActivationSettings` 对象。
///
/// 挑选原则：只按名字找、只挑一个、只置一位、置完读回。名字与描述里一个
/// suspend / background 都没有就**一位都不置** —— 宁可不生效，也不要盲置到别的语义位
/// （唤醒屏幕、免打扰那些都在同一张表里）。
static int AevonActSuspIndex = -1;
static int AevonActSuspFlag = 0;
static char AevonActSetEnc[32] = "-";
static int AevonActKeyNotes = 0;
/// `notify: forward suspbit` 的独立预算。理由同这个工程里每一条现场行：跟别人共用
/// 一个计数器，就会在几次操作之后静默，而静默看起来跟「没发生」一模一样。
static int AevonSuspBitNotes = 0;

/// `method_getArgumentType` 的第 index 个参数，只取首字符；取不到返回 0。
/// 这是「接线之前先看形状」的最小实现：选择子在不在是一件事，参数是什么类型是另一件。
static char AevonActArgType(Method method, unsigned int index) {
    if (method == NULL) return 0;
    if (index >= method_getNumberOfArguments(method)) return 0;
    char buf[24];
    method_getArgumentType(method, index, buf, sizeof(buf));
    return buf[0];
}

/// 整数族。`@` 不在这里面 —— 把一个整数塞进对象参数是这一层唯一会当场崩的写法。
static int AevonActIsInt(char type) {
    return type == 'q' || type == 'Q' || type == 'i' || type == 'I' ||
           type == 'l' || type == 'L' || type == 's' || type == 'S' ||
           type == 'c' || type == 'C' || type == 'B';
}

static void AevonActSettingNames(id settings) {
    static int done = 0;
    if (done) return;
    if (settings == nil) return;
    done = 1;
    @try {
        Class cls = object_getClass(settings);
        Method setter = class_getInstanceMethod(cls, sel_registerName("setFlag:forActivationSetting:"));
        Method getter = class_getInstanceMethod(cls, sel_registerName("flagForActivationSetting:"));
        const char *eset = setter != NULL ? method_getTypeEncoding(setter) : NULL;
        const char *eget = getter != NULL ? method_getTypeEncoding(getter) : NULL;
        if (eset != NULL && strlen(eset) < sizeof(AevonActSetEnc)) {
            strncpy(AevonActSetEnc, eset, sizeof(AevonActSetEnc) - 1);
            AevonActSetEnc[sizeof(AevonActSetEnc) - 1] = '\0';
        }
        AevonLogRaw([[NSString stringWithFormat:@"win: act enc set=%s get=%s",
                      eset != NULL ? eset : "-", eget != NULL ? eget : "-"] UTF8String]);

        // 三道形状闸。名字问得到 ≠ 参数就是这么收的：`valueDescriptionForFlag:` 的第一个
        // 参数如果其实是对象，我们按整数传进去就是往 SpringBoard 里扔一个野指针 ——
        // 这条线上出过两次安全模式，所以宁可什么都不问，也不猜着调。
        Method keym = class_getInstanceMethod(cls, sel_registerName("keyDescriptionForSetting:"));
        Method valm = class_getInstanceMethod(
            cls, sel_registerName("valueDescriptionForFlag:object:ofSetting:"));
        char keyArg = AevonActArgType(keym, 2);
        char valArg = AevonActArgType(valm, 2);
        char valObj = AevonActArgType(valm, 3);
        char setA = AevonActArgType(setter, 2);
        char setB = AevonActArgType(setter, 3);
        int keyOK = (keym != NULL) && (keyArg == 0 || AevonActIsInt(keyArg));
        int valOK = (valm != NULL) && AevonActIsInt(valArg) && (valObj == 0 || valObj == '@');
        int setOK = (setter != NULL) && AevonActIsInt(setA) && AevonActIsInt(setB);
        AevonLogRaw([[NSString stringWithFormat:
                      @"win: act guard key=%d(%c) val=%d(%c,%c) set=%d(%c,%c)",
                      keyOK, keyArg != 0 ? keyArg : '-', valOK,
                      valArg != 0 ? valArg : '-', valObj != 0 ? valObj : '-',
                      setOK, setA != 0 ? setA : '-', setB != 0 ? setB : '-'] UTF8String]);
        if (!setOK) AevonActSuspIndex = -1;   // 形状不对就不许置位

        int named = 0;
        for (int i = 0; keyOK && i < 32 && AevonActKeyNotes < 20; i++) {
            @try {
                id name = ((id (*)(id, SEL, NSInteger))objc_msgSend)(
                    settings, sel_registerName("keyDescriptionForSetting:"), (NSInteger)i);
                if (![name isKindOfClass:[NSString class]] || [(NSString *)name length] == 0) continue;
                const char *nameraw = [(NSString *)name UTF8String];
                if (nameraw == NULL) continue;
                NSMutableString *desc = [NSMutableString string];
                for (int f = 0; valOK && f < 4; f++) {
                    @try {
                        id text = ((id (*)(id, SEL, NSInteger, id, NSInteger))objc_msgSend)(
                            settings, sel_registerName("valueDescriptionForFlag:object:ofSetting:"),
                            (NSInteger)f, nil, (NSInteger)i);
                        if (![text isKindOfClass:[NSString class]]) continue;
                        const char *raw = [(NSString *)text UTF8String];
                        if (raw == NULL || raw[0] == '\0') continue;
                        [desc appendFormat:@" f%d=%.24s", f, raw];
                        if (AevonActSuspIndex >= 0) continue;
                        NSString *low = [[NSString stringWithUTF8String:raw] lowercaseString];
                        if ([low rangeOfString:@"suspend"].location != NSNotFound ||
                            [low rangeOfString:@"background"].location != NSNotFound) {
                            AevonActSuspIndex = i;
                            AevonActSuspFlag = f;
                        }
                    } @catch (NSException *exception) {
                    }
                }
                // 名字本身也算：`keyDescriptionForSetting:` 直接给出 Suspend 之类时走这条。
                if (AevonActSuspIndex < 0) {
                    NSString *low = [[NSString stringWithUTF8String:nameraw] lowercaseString];
                    if ([low rangeOfString:@"suspend"].location != NSNotFound ||
                        [low rangeOfString:@"background"].location != NSNotFound) {
                        AevonActSuspIndex = i;
                        AevonActSuspFlag = 1;
                    }
                }
                AevonLogRaw([[NSString stringWithFormat:@"win: act key %d \"%.30s\"%@",
                              i, nameraw, desc] UTF8String]);
                AevonActKeyNotes += 1;
                named += 1;
            } @catch (NSException *exception) {
            }
        }
        AevonLogRaw([[NSString stringWithFormat:@"win: act key pick=%d flag=%d n=%d enc=%s",
                      AevonActSuspIndex, AevonActSuspFlag, named, AevonActSetEnc] UTF8String]);
    } @catch (NSException *exception) {
        AevonLogRaw("win: act key threw");
    }
}

/// 一次开机一遍：`SBActivationSettings` 这一族到底有哪些手段。
/// 真 API 名靠 census，不靠 strings —— 三家的 `__objc_selrefs` 里有名字 ≠ 那一版真能调
/// （0.2.8 的 `forceBg=0/0` 就是这么翻掉的）。有了这份全表，下一版接线不用再猜。
static void AevonActApiCensus(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    @try {
        Class cls = objc_getClass("SBActivationSettings");
        if (cls == Nil) {
            AevonLogRaw("win: act api set=absent");
            return;
        }
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        NSMutableArray *names = [[NSMutableArray alloc] init];
        for (unsigned int i = 0; methods != NULL && i < count; i++) {
            const char *raw = sel_getName(method_getName(methods[i]));
            if (raw == NULL) continue;
            [names addObject:[NSString stringWithUTF8String:raw]];
        }
        if (methods != NULL) free(methods);
        [names sortUsingSelector:@selector(compare:)];
        NSString *joined = [names componentsJoinedByString:@","];
        if (joined.length > 1500) joined = [joined substringToIndex:1500];
        AevonLogRaw([[NSString stringWithFormat:@"win: act api set=SBActivationSettings n=%u %@",
                      count, joined] UTF8String]);
        [names release];
    } @catch (NSException *exception) {
        AevonLogRaw("win: act api threw");
    }
}

static void AevonOpenShareNote(id request, id options, id settings,
                               char form, int forwarded) {
    if (AevonShareNotes >= 12) return;
    AevonShareNotes += 1;
    char bundleText[56], sourceText[56], actionText[56], originText[56];
    char keys[200], clsText[48], urlText[100];
    bundleText[0] = sourceText[0] = actionText[0] = originText[0] = clsText[0] = '\0';
    keys[0] = '\0';
    urlText[0] = '\0';
    @try {
        AevonActName(AevonOpenBundleOf(request), bundleText, sizeof(bundleText));
        AevonActName(AevonOpenSourceApp(request, options), sourceText, sizeof(sourceText));
        AevonActName(AevonOpenFirstAction(request, options), actionText, sizeof(actionText));
        AevonActName(AevonOpenAnyValue(request, options, @"__LaunchOrigin"),
                     originText, sizeof(originText));
        AevonOpenKeysOf(options, keys, sizeof(keys));
        const char *cls = settings != nil ? object_getClassName(settings) : NULL;
        snprintf(clsText, sizeof(clsText), "%s", cls != NULL ? cls : "-");
        int setSusp = 0, setFlag = 0, getSusp = 0, getFlag = 0;
        if (settings != nil) {
            setSusp = [settings respondsToSelector:sel_registerName("setActivateSuspended:")] ? 1 : 0;
            setFlag = [settings respondsToSelector:
                       sel_registerName("setFlag:forActivationSetting:")] ? 1 : 0;
            getSusp = [settings respondsToSelector:sel_registerName("activateSuspended")] ? 1 : 0;
            getFlag = [settings respondsToSelector:
                       sel_registerName("flagForActivationSetting:")] ? 1 : 0;
        }
        id susp = [options isKindOfClass:[NSDictionary class]]
                ? [(NSDictionary *)options objectForKey:@"__ActivateSuspended"] : nil;
        int suspVal = [susp isKindOfClass:[NSNumber class]] ? [(NSNumber *)susp intValue] : -1;

        // 0.2.8 — 三个新字段，全部只读：
        //   purl = `__PayloadURL` 的真值。原来只知道「有 payload、类型是 url」，
        //          不知道它是 file://（系统拷进 Inbox 的那种）还是 https://
        //          （UniversalLink），而这两条在「怎么自己送达」上是两条完全不同的路。
        //   pid  = 目标 App 此刻的 pid（-1 = 没在跑 / 取不到）。这一位是本次全屏的
        //          关键变量：`__ActivateSuspended` 只对冷启动成立，App 已经在跑时
        //          它被无视，系统照常前台激活。pid > 0 与 pid < 0 两组现场必须分开读。
        //   seen = 系统的场景登记表里有没有这个 App（1 = 上一拍就能拿到 scene）。
        //          与 pid 并列，回答「是进程没起，还是进程起了但没有 scene」。
        AevonOpenValueText(AevonOpenAnyValue(request, options, @"__PayloadURL"),
                           urlText, sizeof(urlText));
        NSString *bundleName = [NSString stringWithUTF8String:bundleText];
        int pid = AevonAppPid(bundleName);
        int seen = AevonSeenSceneForBundle(bundleName) != nil ? 1 : 0;

        char line[760];
        snprintf(line, sizeof(line),
                 "notify: shareprobe b=%s src=%s pay=%s form=%c fwd=%d origin=%s ac=%s"
                 " susp=%d fsusp=%d set=%s setSusp=%d setFlag=%d getSusp=%d getFlag=%d"
                 " pid=%d seen=%d purl=%s keys=%s",
                 bundleText, sourceText, AevonOpenPayloadKind(request, options),
                 form != 0 ? form : '-', forwarded, originText,
                 actionText[0] != '\0' ? actionText : "-",
                 suspVal, AevonForwardSuspLast, clsText, setSusp, setFlag, getSusp, getFlag,
                 pid, seen, urlText[0] != '\0' ? urlText : "-",
                 keys[0] != '\0' ? keys : "-");
        AevonLogRaw(line);
    } @catch (NSException *exception) {
        AevonLogRaw("notify: shareprobe threw");
    }
}

/// 把这一拍看见的东西拼成一行。**只读**：没有一次 retain、没有一次写盘。
///
/// 字段（下一份日志按这个读）：
///   op    = 四条里的哪一条（open / untrusted / trusted / user）
///   b     = 目标 App 的 bundle id。真机上 `request` 自己就是 bundle id 串
///           （0.1.87 实测 `req=com.tencent.mqq`），对象形状是退路
///   src   = 来源 App。`__PayloadOptions[UIApplicationLaunchOptionsSourceApplicationKey]`
///           —— 0.1.88 实测这一层拿不到（键里没有 `__PayloadOptions`），恒为 `-`
///   act   = `__Actions.firstObject` 的类名 —— 认「通知回应」全靠它
///   n     = `__Actions` 的元素个数
///   url   = 动作对象上 `url` 的 absoluteString（母本用它做 URL 注入）
///   req / opt / set / org = 四个参数的真实类名，决定下一版从哪个对象取字段
///   keys  = `options`（或它的 `dictionary`）的键名，只在前三拍出现
static void AevonOpenSnapshot(int slot, id request, id options,
                              id settings, id origin, char *out, size_t size) {
    if (out == NULL || size < 160) return;
    out[0] = '\0';
    AevonOpenTotal += 1;
    // 0.2.77 — 32 抬到 96（每槽 10 抬到 24）。
    //
    // Aevon(211) 12:00:23 那一拍正是被这 32 掐掉的：支付回跳的激活在场，日志里
    // 却一个字都没有 —— 于是「分流被上限挡住」与「这条链根本没走到」在纸面上
    // 分不开。上限的用意是「别把日志写爆」，不是「少看几拍」。
    if (AevonOpenTotal > 96) {
        if (AevonOpenTotal == 97) snprintf(out, size, "notify: open budget spent n=96");
        return;
    }
    if (slot < 0 || slot >= AevonOpenMax) return;
    if (AevonOpenPer[slot] >= 24) return;
    AevonOpenPer[slot] += 1;
    @try {
        char bundleText[52], sourceText[52], actionText[56], urlText[88];
        char reqText[40], optText[40], setText[40], orgText[40], keys[152];
        keys[0] = '\0';
        urlText[0] = '-';
        urlText[1] = '\0';

        id from = AevonOpenSourceApp(request, options);

        id first = nil;
        int actionCount = 0;
        id actionsRaw = AevonActRead(options, @"__Actions");
        if (actionsRaw == nil) actionsRaw = AevonActRead(request, @"__Actions");
        if (actionsRaw == nil) actionsRaw = AevonActRead(options, @"actions");
        if ([actionsRaw isKindOfClass:[NSArray class]]) {
            actionCount = (int)[(NSArray *)actionsRaw count];
            if (actionCount > 0) first = [(NSArray *)actionsRaw objectAtIndex:0];
        }

        id bundle = AevonOpenBundleOf(request);

        id url = first != nil ? AevonActRead(first, @"url") : nil;
        if (url != nil) AevonActName(url, urlText, sizeof(urlText));

        if (AevonOpenKeyNotes < 3) {
            // 0.2.7 — 循环搬进 `AevonOpenKeysOf`（分享现场行要用同一个口径）。
            AevonOpenKeyNotes += 1;
            AevonOpenKeysOf(options, keys, sizeof(keys));
        }

        snprintf(out, size,
                 "notify: hit op=%s b=%s src=%s act=%s n=%d url=%s req=%s opt=%s set=%s org=%s%s%s",
                 AevonOpenTargets[slot].tag,
                 AevonActName(bundle, bundleText, sizeof(bundleText)),
                 AevonActName(from, sourceText, sizeof(sourceText)),
                 AevonActName(first, actionText, sizeof(actionText)),
                 actionCount, urlText,
                 AevonActName(request, reqText, sizeof(reqText)),
                 AevonActName(options, optText, sizeof(optText)),
                 AevonActName(settings, setText, sizeof(setText)),
                 AevonActName(origin, orgText, sizeof(orgText)),
                 keys[0] != '\0' ? " keys=" : "", keys);
    } @catch (NSException *exception) {
        const char *name = exception.name != nil ? [exception.name UTF8String] : NULL;
        snprintf(out, size, "notify: hit threw %s", name != NULL ? name : "?");
    }
}

// MARK: - 0.1.88 结果块
//
// 这四条方法最后一个参数都是 `@?`（结果块）。原样转发时它是系统自己的事；一旦
// 不转发，这个块就没人调了 —— 而它多半是某个开请求事务的收尾，悬着不落的后
// 果是 SpringBoard 以为「还在开 App」：首页手势失灵、下一次切换排队。两种都
// 比「点了没反应」更难查。
//
// 块的具体形状不知道，也不许猜。这里读块自己的签名（`Block_layout` →
// `descriptor->signature`），只认三种不会再变的形状：
//
//     v12@?0B8        一个 BOOL（成功/失败）        → 传 YES
//     v16@?0@"NSError"8  一个对象（错误，nil 即成功）→ 传 nil
//     v8@?0           一个参数都没有                → 直接调
//
// 其余一律不调，只在日志里写 `result=skip`。宁可留一个悬着的事务，也不拿一个
// 形状不对的块去赌 —— 那是崩溃，不是一行日志。
typedef struct {
    unsigned long reserved;
    unsigned long size;
    const char *signature;
} AevonBlockDesc;

typedef struct {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    AevonBlockDesc *descriptor;
} AevonBlockLayout;

/// 读签名并归一成三种形状之一：'B' / '@' / 'v'，认不出返回 0。
static char AevonOpenResultShape(id result) {
    if (result == NULL) return 0;
    const char *sig = NULL;
    @try {
        AevonBlockDesc *desc = ((AevonBlockLayout *)result)->descriptor;
        if (desc != NULL) sig = desc->signature;
    } @catch (NSException *exception) {
        return 0;
    }
    if (sig == NULL) return 0;
    // 块自己的参数编码形如 `v12@?0B8`：`@?` 是 self，紧跟数字是偏移。
    const char *self = strstr(sig, "@?");
    if (self == NULL) return 0;
    const char *cur = self + 2;
    while (*cur >= '0' && *cur <= '9') cur++;
    if (*cur == '\0') return 'v';
    if (*cur == 'B' || *cur == 'c' || *cur == 'C') return 'B';
    if (*cur == '@') return '@';
    return 0;
}

/// 上一个收过尾的结果块。同一次点击的 open → trusted 两条有可能拿的是**同一个块**，
/// 收两次比悬着更难查（`[transaction invalidate]` 跑第二遍、`resume` 跑两遍）。
static void *AevonLastResult = NULL;

/// 收尾。`shape` 只用于日志：`BOOL` / `nil` / `void` / `skip` / `same` 五种写清楚，
/// 下一份日志才能回答「结果块到底被谁收了尾」。
static void AevonOpenFinishResult(id result, const char **shape) {
    if (result == NULL) { *shape = "none"; return; }
    if ((void *)result == AevonLastResult) { *shape = "same"; return; }
    AevonLastResult = (void *)result;
    char form = AevonOpenResultShape(result);
    @try {
        switch (form) {
            case 'B': ((void (^)(BOOL))result)(YES); *shape = "BOOL"; return;
            case '@': ((void (^)(id))result)(nil); *shape = "nil"; return;
            case 'v': ((void (^)(void))result)(); *shape = "void"; return;
            default: *shape = "skip"; return;
        }
    } @catch (NSException *exception) {
        *shape = "threw";
    }
}

// MARK: - 0.1.89 分流之后的收尾：关通知中心 / 撤横幅
//
// 0.1.88 的真机日志（Aevon(156)）把「浮窗起来了」这件事关账了：五次点通知、五次
// `notify: divert b=…` + `notify: divert card up b=…`，一次 `replay` 都没有。但同一个
// 答复里还剩两条：「通知中心不自动关闭」「横幅不自动收起」。
//
// 这两条不是 bug，是 0.1.88 那个「不转发」的必然代价。正常点通知时，收面板、收横幅
// 这两件事**挂在 SpringBoard 那一段的收尾里**（App 起来 → 面板跟着走）。我们整段跳过
// 了，于是没有任何人去收它们。要补的正是被跳过的那一部分，不是发明新动作。
//
// 两条路都不猜名字，原因很实际：0.1.85 猜 `_activateBundleID:` 白丢了一版，0.1.86 才
// 用只读普查把真名捞回来。所以这里的每个候选都先读 `method_getTypeEncoding`，归一化后
// **逐字符等于**预期才调；不等就只记编码，绝不动手。四个候选全不符时一行都不做
// （= 0.1.88 行为），日志里留下真实编码，下一版按它改。
//
// 横幅那条有现成的实证，不是推的：stheno 复刻线（`stheno-逆向分析/analysis/
// roadmap-0.7-2026-10-17.md`）在这上面连错三版才认清 ——
//   0.7.10：`dismissAllBanners*` 在横幅宿主 `SBNotificationBannerDestination` 上
//           **根本不存在**（log71 能力地图实证），静默空转；
//   0.7.11：改成 fire `dismissTimer`，撞上「它是 OS_dispatch_source、不是 NSTimer」（log72）；
//   0.7.12：改 `dispatch_source_set_timer(_dismissTimer, DISPATCH_TIME_NOW, …)` —— 把系统
//           自己那个 5 秒计时器的触发时间改到「现在」，让它自己的收起处理器跑一遍，
//           只影响当前这一条；log73 关账。
// 所以这里照做：不伪造收起动作，只**提前**执行系统本来就会做的那一次。
//
// 时机：0.1.90 是固定 0.45 秒，0.1.91 改成 0.10 秒起、先问卡片、卡在路上就并行收
// （见 `AevonCleanCoverAfterCard`）。0.45 秒那条的出发点是「点通知这一刻 SpringBoard
// 还在跑一次 open 事务，就地动通知中心有撞断言的历史」（同一份 roadmap 里 0.6.20 的
// 教训）。这个顾虑在 0.1.88 之后已经不成立了：我们把原实现整段跳过，结果块在
// 同一个 runloop 里就收过尾了，没有事务可撞。留 0.10 秒只是给 open 请求的处理函数
// 退出栈帧 —— 那点时间用户看不出来，但足以避开「在自己被调用的那一拍里改别人的状态」。
// 用户 0.1.90 的真机反馈是「会收，但感觉有点慢」，慢的正是这 0.45 - 0.10 = 0.35 秒。

/// 只读一个 getter。不存在、或对象把消息转发到一个会抛的实现上，都返回 nil。
///
/// 双保险不是洁癖：这条链跑在 SpringBoard 主队列上，一次 `doesNotRecognizeSelector`
/// 就是杀进程，不是一行日志。0.7.9 那条线正是这么死的（对 `NSObject` 用 `valueForKey:`
/// 取未定义键 ⇒ 整条 open 请求被丢弃 + 自动重试），所以这里连 `@try` 都不敢省。
static id AevonCleanRead(id object, const char *name) {
    if (object == NULL || name == NULL) return nil;
    SEL sel = sel_registerName(name);
    if (![object respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, sel);
    } @catch (NSException *exception) {
        return nil;
    }
}

/// 把 ObjC 类型编码归一化成「只有类型字符」的形式：
/// `v28@0:8B16B20@?24` → `v@:BB@`。数字（偏移量）、`+`/`-`（栈帧）、引号里的名字全部丢掉。
///
/// 有了它，闸就能写成 `strcmp(compact, "v@:BB@") == 0` —— 一眼能看出「这个选择子收
/// 两个 BOOL 加一个对象」，而不是靠人肉对齐偏移量。
///
/// **`@?`（块）折叠成 `@`，这是 0.1.90 的修正。** 0.1.89 把它单列成两个字符，于是
/// `setCoverSheetPresented:animated:withCompletion:` 的真实编码 `v@:BB@?` 与候选表里
/// 写的 `v@:BB@` 永远不等 —— 六个候选一次都进不去，而日志里只会看到「没装」。
/// 折叠是安全的：块与对象在 ABI 上都是指针，我们的调用点传的是 `[^{} copy]`（堆块），
/// 当 id 传过去本来就成立。这不是放宽闸，是修正一个写错的比较键。
static void AevonCleanCompact(const char *encoding, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (encoding == NULL) return;
    size_t used = 0;
    for (const char *p = encoding; *p != '\0' && used + 3 < size; p++) {
        if (*p >= '0' && *p <= '9') continue;
        if (*p == '+' || *p == '-') continue;
        if (*p == '@' && p[1] == '?') { out[used++] = '@'; p++; continue; }
        if (*p == '"') { p++; while (*p != '\0' && *p != '"') p++; continue; }
        out[used++] = *p;
    }
    out[used] = '\0';
}

/// 这个对象是不是一个 GCD 计时器（`OS_dispatch_source`）？
///
/// 0.7.12 那条线在这里卡过一版：横幅的 `dismissTimer` 看着像计时器，`fire` 上去却
/// 什么也没发生 —— 因为它根本不是 `NSTimer`。所以调用前必须先认类名，认错就是
/// `dispatch_source_set_timer` 打在一个普通对象上。
static BOOL AevonCleanIsSource(id object) {
    if (object == nil) return NO;
    const char *name = class_getName(object_getClass(object));
    if (name == NULL) return NO;
    return strstr(name, "dispatch_source") != NULL;
}

/// 让某一台上「已经排好队的那次收起」立刻发生。
///
/// 只碰名字里同时含 dismiss 与 timer 的 **对象型** ivar（类型编码必须以 `@` 开头，
/// 否则 `object_getIvar` 会把一个标量当指针解引用）。取不到就返回 NO，一个字节都不动。
static BOOL AevonCleanKick(id host, char *how, size_t size) {
    if (how != NULL && size > 0) how[0] = '\0';
    if (host == nil) return NO;

    // ① getter 优先：`dismissTimer` 在 log72 里就是它给出的 OS_dispatch_source。
    id timer = AevonCleanRead(host, "dismissTimer");
    if (!AevonCleanIsSource(timer)) timer = nil;

    // ② getter 不在就扫 ivar。名字匹配 + 类型必须是对象 + 认得出是 GCD 源，三条同时成立。
    if (timer == nil) {
        unsigned int count = 0;
        Ivar *vars = class_copyIvarList([host class], &count);
        for (unsigned int i = 0; vars != NULL && i < count; i++) {
            const char *name = ivar_getName(vars[i]);
            if (name == NULL) continue;
            if (strcasestr(name, "dismiss") == NULL) continue;
            if (strcasecmp(name, "dismissTimer") != 0 && strcasecmp(name, "_dismissTimer") != 0) continue;
            const char *type = ivar_getTypeEncoding(vars[i]);
            if (type == NULL || type[0] != '@') continue;
            id value = object_getIvar(host, vars[i]);
            if (!AevonCleanIsSource(value)) continue;
            timer = value;
            if (how != NULL && size > 0) snprintf(how, size, ":%s", name);
            break;
        }
        if (vars != NULL) free(vars);
    }

    if (timer == nil) return NO;
    // 触发时间 = 现在；间隔给一个「这辈子不会再来」的值，免得把周期改坏。
    dispatch_source_set_timer((dispatch_source_t)(__bridge void *)timer,
                              DISPATCH_TIME_NOW, (uint64_t)1 << 62, 0);
    return YES;
}

/// 横幅。宿主不一定是 `SBNotificationBannerDestination`：这台机器上 dispatcher 有
/// 四个 destination getter，还没验过哪一台真的挂着横幅，所以三个都问一遍，谁先
/// 有计时器就动谁（只动第一台，避免一次点击收两遍）。
static void AevonCleanBanner(id dispatcher, char *out, size_t size) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    if (dispatcher == nil) { snprintf(out, size, "banner=nodispatcher"); return; }

    static const char *getters[3] = {
        "bannerDestination", "dashBoardDestination", "notificationCenterDestination"
    };
    char notes[96];
    notes[0] = '\0';
    for (int i = 0; i < 3; i++) {
        id dest = AevonCleanRead(dispatcher, getters[i]);
        if (dest == nil) {
            size_t used = strlen(notes);
            if (used < sizeof(notes) - 8) snprintf(notes + used, sizeof(notes) - used, " -%d", i);
            continue;
        }
        char how[40];
        if (AevonCleanKick(dest, how, sizeof(how))) {
            snprintf(out, size, "banner=ok:%s%s", getters[i], how);
            return;
        }
    }
    snprintf(out, size, "banner=none%s", notes);
}

/// 通知中心（cover sheet）收起来。
///
/// 候选顺序按「最可能是标准做法」排，不是按名字好写排：`setCoverSheetPresented:animated:
/// withCompletion:` 是这台机器上 presentation manager 的常规入口，`_dismiss…` 是它的私有
/// 快捷路径，无参的 `dismissCoverSheet` 只当最后的兜底。
///
/// 每一步都过形状闸。**候选全不符时一行都不做** —— 那等于退回 0.1.88（面板不关），
/// 而日志里那几条真实编码就是下一版的依据。这比赌一个名字好：赌错轻则无效、重则调用
/// 到一个参数不是这个类型的实现上，那是崩溃。
///
/// 0.1.90 修了两处，都是 0.1.89 真机日志（Aevon(157)）逼出来的：
///
///  ① **`isUILocked` 不能当锁屏闸。** 三次点通知三次 `cover=locked`。通知中心
///     （CoverSheet）本身就是锁屏那一套 UI，它一在屏 `SBLockScreenManager.isUILocked`
///     就是 1 —— 也就是说这个闸在「唯一该收的场景」里恒为真，等于把功能关掉。
///     换成 `isPasscodeLocked`：那一位问的是「要用密码才能进」，只有它才是真的锁。
///     读不到（-1）就不拦 —— 拦不拦的后果不对称：误收只是「面板提前关了」，
///     误拦是「这个功能一辈子不生效」；而误收还有下面那道真正的兜底。
///  ② **收面板不能自己定时，要等卡片。** 0.45 秒时卡片还没起来（真机 divert 18 秒、
///     card up 21 秒），那时收面板会露出两三秒空白桌面。所以改成轮询卡片，
///     卡片一在就收，面板消失与卡片出现同一拍。
///  ③ **0.1.91 — 等卡片这一条留，但不再是唯一出口。** 用户 0.1.90 的真机反馈是
///     「会收，但感觉有点慢」：面板压在卡片后面 0.3~0.5 秒才走。真机日志
///     （Aevon(158)）里四处 `wait=0/1` 说明冷却期内卡片其实早就占了槽，慢的是那个
///     0.45 秒的起始延迟与 0.15 秒的节拍。这一版把起始延迟压到 0.10 秒、节拍压到
///     0.04 秒，并给「卡在路上」单开一个出口 —— 见 `AevonCleanCoverAfterCard`。
static void AevonCleanCover(char *out, size_t size, int dismissFirst) {
    if (out == NULL || size == 0) return;
    out[0] = '\0';
    id cover = AevonShared(@"SBCoverSheetPresentationManager");
    if (cover == nil) { snprintf(out, size, "cover=noclass"); return; }
    NSInteger presented = AevonBoolOf(cover, @"isPresented");
    NSInteger visible = AevonBoolOf(cover, @"isVisible");
    if (presented != 1 && visible != 1) {
        snprintf(out, size, "cover=down p=%ld v=%ld", (long)presented, (long)visible);
        return;
    }
    // 真锁（要密码）才不收。`isUILocked` 在这里不能用，见上面 ①。
    if (AevonBoolOf(AevonShared(@"SBLockScreenManager"), @"isPasscodeLocked") == 1) {
        snprintf(out, size, "cover=skip:passcode");
        return;
    }

    static const struct { const char *sel; const char *shape; } ladder[] = {
        { "setCoverSheetPresented:animated:withCompletion:",       "v@:BB@"  },
        { "setCoverSheetPresented:animated:withCompletion:force:", "v@:BB@B" },
        { "_setCoverSheetPresented:animated:withCompletion:",      "v@:BB@"  },
        { "_dismissCoverSheetAnimated:withCompletion:",            "v@:B@"   },
        { "dismissCoverSheetAnimated:completion:",                 "v@:B@"   },
        { "dismissCoverSheet",                                     "v@:"     },
    };
    enum { ladderCount = sizeof(ladder) / sizeof(ladder[0]) };
    char miss[96];
    miss[0] = '\0';

    // 每个候选的真实编码，一次开机只打一行。0.1.89 最大的浪费是：六个候选一个都没
    // 进过闸，日志里连「编码长什么样」都没有，只能靠下一次装机去猜。这一行买的是
    // 「这一版再不通，下一版不用再装一次机」。
    static int dumped = 0;
    if (!dumped) {
        dumped = 1;
        char table[220];
        size_t used = 0;
        table[0] = '\0';
        for (int i = 0; i < ladderCount && used + 34 < sizeof(table); i++) {
            SEL probe = sel_registerName(ladder[i].sel);
            Method method = class_getInstanceMethod([cover class], probe);
            char compact[24];
            AevonCleanCompact(method != NULL ? method_getTypeEncoding(method) : NULL,
                              compact, sizeof(compact));
            used += snprintf(table + used, sizeof(table) - used, " %d=%s",
                             i, method != NULL ? compact : "-");
        }
        char line[300];
        snprintf(line, sizeof(line), "notify: cover sels%s", table);
        AevonLogRaw(line);
    }

    // 0.2.28 — 候选顺序可翻转。第一次收用默认顺序（标准入口优先）；0.6 秒后
    // 复核发现面板还在时，用 `dismissFirst` 换成 dismiss 专用候选再试一次 ——
    // `setCoverSheetPresented:NO` 在某些现场会被系统吞掉（不抛、不生效），
    // 这正是「点了通知，通知中心没关」的那一类。
    int order[ladderCount];
    int orderCount = 0;
    if (dismissFirst) {
        order[orderCount++] = 3; order[orderCount++] = 4; order[orderCount++] = 5;
        order[orderCount++] = 1; order[orderCount++] = 0; order[orderCount++] = 2;
    } else {
        for (int i = 0; i < ladderCount; i++) order[orderCount++] = i;
    }

    for (int k = 0; k < orderCount; k++) {
        int i = order[k];
        SEL sel = sel_registerName(ladder[i].sel);
        Method method = class_getInstanceMethod([cover class], sel);
        if (method == NULL) continue;
        const char *encoding = method_getTypeEncoding(method);
        if (encoding == NULL) continue;
        char compact[24];
        AevonCleanCompact(encoding, compact, sizeof(compact));
        if (strcmp(compact, ladder[i].shape) != 0) {
            size_t used = strlen(miss);
            if (used < sizeof(miss) - 12) snprintf(miss + used, sizeof(miss) - used, " %s", compact);
            continue;
        }
        // 空块比 nil 安全：有些实现不看就调，nil 调用是跳 0。块不带参数，多传的参数它不理。
        // `copy` 一步不能省：`objc_msgSend` 的形参是 id，不是块，ARC 不会替我们把栈上的
        // 块搬到堆上；搬晚了，被调方存下来再调就是野指针。
        id done = [^{} copy];
        BOOL ran = NO;
        @try {
            switch (i) {
                case 0:
                case 2:
                    ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)
                        (cover, sel, NO, YES, (id)done);
                    ran = YES;
                    break;
                case 1:
                    ((void (*)(id, SEL, BOOL, BOOL, id, BOOL))objc_msgSend)
                        (cover, sel, NO, YES, (id)done, YES);
                    ran = YES;
                    break;
                case 3:
                case 4:
                    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(cover, sel, YES, (id)done);
                    ran = YES;
                    break;
                case 5:
                    ((void (*)(id, SEL))objc_msgSend)(cover, sel);
                    ran = YES;
                    break;
                default:
                    break;
            }
        } @catch (NSException *exception) {
            ran = NO;
        }
        if (ran) { snprintf(out, size, "cover=ok:%s", ladder[i].sel); return; }
    }

    if (miss[0] != '\0') snprintf(out, size, "cover=shape%s", miss);
    else snprintf(out, size, "cover=none");
}

/// 0.2.28 — 收面板之后的复核。
///
/// 0.2.27 及以前 `cover=ok:…` 只是「调用没抛异常」，不是「面板真的走了」。
/// `setCoverSheetPresented:NO` 在某些现场会被系统吞掉，用户看到的就是「点了通知，
/// 通知中心没关」。这里 0.6 秒后复读那两个布尔量，仍在屏就换成 dismiss 专用候选
/// 再试一次 —— 两次结论写进同一行，下一份日志不用再猜是哪一半。
static void AevonCleanCoverFollowUp(void) {
    if (AevonActivateSwitchOff()) return;
    id cover = AevonShared(@"SBCoverSheetPresentationManager");
    if (cover == nil) return;
    NSInteger presented = AevonBoolOf(cover, @"isPresented");
    NSInteger visible = AevonBoolOf(cover, @"isVisible");
    char again[128], line[260];
    again[0] = '\0';
    if (presented != 1 && visible != 1) {
        snprintf(line, sizeof(line), "notify: cover follow p=%ld v=%ld gone",
                 (long)presented, (long)visible);
        AevonLogRaw(line);
        return;
    }
    AevonCleanCover(again, sizeof(again), 1);
    snprintf(line, sizeof(line), "notify: cover follow p=%ld v=%ld %s",
             (long)presented, (long)visible, again);
    AevonLogRaw(line);
}

/// SpringBoard 的通知 dispatcher。只解析一次，解析结果留一份强引用。
///
/// 取法是 0.7 那条线留下的：SpringBoard（`UIApplication.delegate`）→ `notificationDispatcher`
/// → `SBNCNotificationDispatcher` → 各 destination。三个名字都试，谁先答用谁；答不上就
/// 记 `d=-`，本版退回「只有通知中心会被收、横幅照系统原样 5 秒后自己走」。
static id AevonCleanDispatcherRef = nil;
/// 0.1.99 — 「取不到就永远不再取」改掉。
///
/// 原来是 `Tried = 1` 一次性：第一次问没答上，这一整次开机就再也不问了。而通知栈是
/// 懒加载的 —— 0.1.94 的真机读数就是 3 秒时 `NCNotificationDispatcher` 还不存在、
/// 10 秒才出现。现在开机 25 秒会主动问一次；万一那一刻它还没起来，这个一次性标记
/// 就把「之后点通知时再问」的门也一起关上了，清通知会永久失效，而日志里只有一行
/// `d=-`。改成「失败 3 秒后可重试、最多 20 次」。
static CFAbsoluteTime AevonCleanDispatcherAt = 0;
static int AevonCleanDispatcherTries = 0;

static id AevonCleanDispatcher(void) {
    if (AevonCleanDispatcherRef != nil) return AevonCleanDispatcherRef;
    {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (AevonCleanDispatcherAt > 0 && now - AevonCleanDispatcherAt < 3.0) return nil;
        if (AevonCleanDispatcherTries >= 20) return nil;
        AevonCleanDispatcherAt = now;
        AevonCleanDispatcherTries += 1;
    }

    static const char *names[3] = { "notificationDispatcher", "ncDispatcher", "_notificationDispatcher" };
    id found = nil;
    const char *via = "-";
    id delegate = AevonCleanRead([UIApplication sharedApplication], "delegate");
    for (int i = 0; i < 3 && found == nil; i++) {
        found = AevonCleanRead(delegate, names[i]);
        if (found != nil) via = names[i];
    }
    if (found == nil) {
        id lock = AevonShared(@"SBLockScreenManager");
        for (int i = 0; i < 3 && found == nil; i++) {
            found = AevonCleanRead(lock, names[i]);
            if (found != nil) via = names[i];
        }
    }
    if (found != nil) AevonCleanDispatcherRef = found;

    AevonLogRaw([[NSString stringWithFormat:@"notify: hub d=%@ via=%s",
                  found != nil ? NSStringFromClass([found class]) : @"-", via] UTF8String]);
    return found;
}

// MARK: - 0.2.5 清通知的第一条路：截对象
//
// 老路的死结（Aevon(161)/(167)：6/6 `clear=noid`）不是 getter 试得不够，而是
// 「从动作对象反推标识、再拿标识去各宿主里比对」这个思路本身不成立：中间任何一跳
// 改名，整条路就静默落空，而落空与「没有这条通知」在日志里长得一样。
//
// 正解是**截对象**（三家逆向 2026-11-08 实证）：
//   `NCNotificationDispatcher -destination:executeAction:forNotificationRequest:
//    requestAuthentication:withParameters:completion:` 的第三个参数就是
//   `NCNotificationRequest` 本体。TrollOpen 1.5.2 的 `__objc_selrefs` 里既有这个
//   选择子，也有随后要用的 `withdrawNotificationRequest:`（同一次解引用里出现）。
// 于是：钩子顺手登记「这一次被点的请求 + 它所在的 destination」，0.60 秒后直接拿
// 对象去 withdraw —— 不猜标识、不扫列表、不比对。
//
// 三条纪律：
//   · 钩子里**只登记并原样转发**：通知的正常处理（弹 App、回锁屏、收起横幅）完全
//     交给原实现。这一层吞掉一次，用户看到的就是「点了通知没反应」。
//   · 登记用强引用但**带寿命**（4 秒窗，覆盖时先 release）：SpringBoard 常驻，
//     永久持有一个通知请求对象就是一条常驻泄漏。
//   · 动手仍在 0.60 秒后的主队列上（`AevonClearLater`），不在钩子那一拍做任何
//     跨对象操作 —— 那一拍系统正在处理用户的手指。
static id AevonCapRequest = nil;
static id AevonCapDestination = nil;
static double AevonCapAt = 0;
static long AevonCapCalls = 0;

/// 丢掉登记的那一对对象。调用方自己保证在锁外不持有它们。
static void AevonCapDrop(void) {
    @synchronized ([AevonHookProbe class]) {
        [AevonCapRequest release];
        AevonCapRequest = nil;
        [AevonCapDestination release];
        AevonCapDestination = nil;
        AevonCapAt = 0;
    }
}

/// 登记的这一条还新鲜吗。只有「刚被点过」的那一条才允许被拿去清 —— 清的时机是
/// 点击后 0.60 秒，窗给到 4 秒是为了容纳卡片那条路的抖动。
static BOOL AevonCaptureFresh(void) {
    BOOL fresh = NO;
    @synchronized ([AevonHookProbe class]) {
        fresh = (AevonCapRequest != nil &&
                 AevonCapAt > 0 &&
                 CFAbsoluteTimeGetCurrent() - AevonCapAt <= 4.0);
    }
    return fresh;
}

void AevonNotificationCaptureInstall(void);

/// 挂 `NCNotificationDispatcher` 那个入口。通知栈是懒加载的（0.1.94 的真机读数：
/// 3 秒时这个类还不存在、10 秒才出现），所以取不到类就 3 秒后再来一次、最多 20 次
/// —— 与 `AevonCleanDispatcher` 一样的滑动策略，绝不做「一次开机只试一次」。
///
/// 两个类名都试，**子类优先**：0.1.42 的普查把 SpringBoard 里 70 个含 Notification
/// 的类列了一遍，`SBNCNotificationDispatcher` 在、`NCNotificationDispatcher` 当时
/// 报 0；而真正跑起来的是前者（它是后者的子类，0.1.45 的父类链取证）。
/// 先装子类还有一层：`AevonAttach` 对「继承来的方法」走 `class_addMethod`，
/// 于是钩子只落在子类的方法表上，父类那份原样不动 —— 只响一次，不会双调。
void AevonNotificationCaptureInstall(void) {
    static int tries = 0;
    Class cls = Nil;
    static const char *candidates[2] = { "SBNCNotificationDispatcher", "NCNotificationDispatcher" };
    for (int i = 0; i < 2 && cls == Nil; i++) {
        Class c = NSClassFromString([NSString stringWithUTF8String:candidates[i]]);
        if (c == Nil) continue;
        if (class_getInstanceMethod(c, NSSelectorFromString(
                @"destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:")) == NULL) {
            continue;
        }
        cls = c;
    }
    if (cls == Nil) {
        if (tries < 20) {
            tries += 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AevonNotificationCaptureInstall();
            });
        } else {
            AevonLogRaw("notify: capture class missing after 20 tries");
        }
        return;
    }

    NSMutableString *out = [NSMutableString string];
    AevonHookSlot *slot = AevonReserve("nc-cap");
    if (slot == NULL) {
        AevonLogRaw("notify: capture no slot left");
        return;
    }
    __block AevonHookSlot *mine = slot;
    // ⛔ 0.2.5 的形状是错的，真机一次就照出来了（Aevon(174) 第 98 行）：
    //
    //   hook nc-cap cls=NCNotificationDispatcher skipped
    //   types=v60@0:8@16@24@32B40@44@?52 args=5 want=6
    //
    // 真签名是 `destination:executeAction:forNotificationRequest:requestAuthentication:
    // withParameters:completion:`，其中 **`requestAuthentication` 是 BOOL（`B40`）**，
    // 不是对象。0.2.5 按「六个对象」写的 block，形状闸正确地把这一条拒了 ——
    // 闸救了命：按六个 id 去调，parameters 与 completion 会从错位的寄存器里读。
    // 现在的写法逐字节对上那串编码：五个 `@`（self/dest/action/request/params/
    // completion 里去掉 self 是五个）+ 一个 `B`。
    //
    // 对象计数因此是 5（`AevonObjectArgs` 只数 `@`），形状闸照样开着：
    // 换成没有 BOOL 的版本时会以 `args=6 want=5` 被拒，而那一行就是下一版的依据。
    id block = ^(id dispatcher, id destination, id action, id request,
                 BOOL authentication, id parameters, id completion) {
        long n = __sync_fetch_and_add(&AevonCapCalls, 1);
        // 顺序是按选择子名读的（destination / executeAction / forNotificationRequest /
        // requestAuthentication / withParameters / completion），但「读对了名字」不等于
        // 「参数确实在那一格」—— 所以登记前先看类名。不是 `…NotificationRequest` 的
        // 东西一律不登记：宁可这条清不掉，也不能拿别的对象去 withdraw。
        const char *rc = request != nil ? object_getClassName(request) : NULL;
        BOOL isRequest = (rc != NULL && strstr(rc, "NotificationRequest") != NULL);
        if (isRequest && request != nil) {
            @synchronized ([AevonHookProbe class]) {
                if (AevonCapRequest != request) {
                    [AevonCapRequest release];
                    AevonCapRequest = [request retain];
                    [AevonCapDestination release];
                    AevonCapDestination = [destination retain];
                    AevonCapAt = CFAbsoluteTimeGetCurrent();
                }
            }
        }
        // 只打第一次。`AevonRawTrace` 走的是 32 条的环形表（开机那几十条 tick 就填满），
        // 而这个钩子要等到用户点通知才会响 —— 用 trace 等于永远看不到。写一行直写日志
        // 在点击这一拍是可接受的成本（整条通知路径本来就在写日志），而它决定了下一份
        // 真机日志能不能回答「参数顺序猜对了没有」。
        if (n == 0) {
            char capLine[220];
            snprintf(capLine, sizeof(capLine),
                     "notify: capture req=%s dest=%s act=%s ok=%d",
                     rc != NULL ? rc : "-",
                     destination != nil ? object_getClassName(destination) : "-",
                     action != nil ? object_getClassName(action) : "-",
                     isRequest ? 1 : 0);
            AevonLogRaw(capLine);
        }
        void (*original)(id, SEL, id, id, id, BOOL, id, id) =
            (void (*)(id, SEL, id, id, id, BOOL, id, id))mine->original;
        // 深度只在「这一次调用期间」抬着，让守护别在这段里写盘（同 intercept 那条路）。
        __sync_fetch_and_add(&AevonHookDepth, 1);
        if (original != NULL) {
            original(dispatcher, mine->sel, destination, action,
                     request, authentication, parameters, completion);
        }
        __sync_fetch_and_sub(&AevonHookDepth, 1);
    };
    // wantArgs=5：五个对象参数（`requestAuthentication` 是 BOOL，不计）。
    BOOL live = AevonAttachShaped(out, slot, cls,
        @"destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:",
        5, block);
    if (live) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: capture live cls=%@", NSStringFromClass(cls)]
                     UTF8String]);
    } else {
        AevonLogRaw([[NSString stringWithFormat:@"notify: capture failed %@", out] UTF8String]);
    }
}

/// 收尾频率上限。用满之后一律回到 0.1.88 的行为（面板与横幅都不动）。
///
/// 0.1.93 — 同样是「一次开机 6 次」改成滑动窗口。Aevon(161) 里这条上限在
/// **01:27** 就用满了（`notify: clean … n=6`），此后到 12:23 一次都没再收过 ——
/// 用户那天后半程的「面板不收了 / 横幅不收了」不是判据坏了，是配额早用完了。
/// 上限要挡的是「一次坏掉的循环连着收」，不是「今天已经成功过六次」。
static int AevonCleanRuns = 0;
static double AevonCleanWindow = 0;
#define AEVON_CLEAN_MAX 6
#define AEVON_CLEAN_WINDOW 120.0

static BOOL AevonCleanExhausted(void) {
    double now = CFAbsoluteTimeGetCurrent();
    if (AevonCleanWindow <= 0 || now - AevonCleanWindow > AEVON_CLEAN_WINDOW) {
        AevonCleanWindow = now;
        AevonCleanRuns = 0;
    }
    return AevonCleanRuns >= AEVON_CLEAN_MAX;
}

// MARK: - 0.1.92 清掉那条通知（点开 = 已读）
//
// 证据不是推的，是母版线（`stheno-逆向分析/analysis/roadmap-0.7-2026-10-17.md`，真机
// log67~log71）用四版试出来的：
//
//   · 动作对象 `options.__Actions.firstObject` 是 `UINotificationResponseAction`
//     （`BSAction` 子类），内容在 `-info` 那一侧；
//   · 公开链 `action.notificationResponse.notification.request.identifier` 在真机上
//     **取不到**（log68 三次 `UUID=(无)`）。能取到的是**无参只读 getter**：
//     `notificationRequestIdentifier` / `requestIdentifier` / `notificationIdentifier` /
//     `notificationUUID` / `uuid`。**故意不试 `identifier`** —— `BSAction` 自己也有一个
//     36 位标识，抓错了后面的匹配必然落空，而「落空」在这条路上等于静默失效；
//   · 清一条的成功实证是 `SBNotificationBannerDestination -withdrawNotificationRequest:`
//     （log71 ×2，`已清除 … 的 1 条`）。也就是说请求真正挂在 **destination** 上，
//     不在 dispatcher 本身（iOS 17 如此，0.7.9 在 dispatcher 上找了两版没找到）；
//   · 0.7.8 在动作对象上深挖对象图，把整条「点通知」打死了（log69）⇒ 这里**不做图遍历**，
//     只走已知 getter，外加对 getter 返回的数组做一层扫描。深度固定为一层。
//
// 三条「拿不到就什么都不做」：取不到标识 / 找不到请求对象 / 宿主上没有那个方法。
// 三种都只写一行日志，绝不用「清空这个 App 的全部通知」当兜底 —— 那会连没读的一起删掉。
//
// 时机 0.60 秒：0.10 秒那一拍我们还在 open 请求的栈里，收面板那条线已经证明 0.10 秒
// 只够动面板本身；清通知要跨到 destination 里改数据，放在卡片与面板都落定之后更稳
// （母版用 0.45 秒，那一版同时还挂着一个真实的 OpenApplication 事务；我们没有，留到
// 0.60 秒是让轮询那几拍先跑完，不与之抢主队列）。

/// 清通知的频率上限。0.1.93 — 与另外两处一样，从「一次开机 6 次」改成滑动窗口；
/// 理由见 `AevonCleanExhausted`：一次开机型的配额会让功能在某个时刻悄悄永久失效。
///
/// 0.2.28 — 6 → 24。收尾（收面板/收横幅）与清通知各记一次，也就是说一口点
/// 一次通知要吃掉两格：原来的 6 格只够点三次，第四次开始面板不收、通知不清
/// —— 这正是「有的会清、有的不会」里最规律的那一半。24 格 = 每两分钟 12 次点击，
/// 仍然挡得住失控循环，也不会在正常使用里悄悄关掉功能。
static int AevonClearRuns = 0;
static double AevonClearWindow = 0;
#define AEVON_CLEAR_MAX 24
#define AEVON_CLEAR_WINDOW 120.0

static BOOL AevonClearExhausted(void) {
    double now = CFAbsoluteTimeGetCurrent();
    if (AevonClearWindow <= 0 || now - AevonClearWindow > AEVON_CLEAR_WINDOW) {
        AevonClearWindow = now;
        AevonClearRuns = 0;
    }
    return AevonClearRuns >= AEVON_CLEAR_MAX;
}

/// 0.2.28 — 标识归一化。
///
/// 同一个通知在不同投递上把标识放在不同类型里：公开的 `UNNotificationRequest.
/// identifier` 是 NSString，而内部 `identifier` / `uuid` 常是 NSUUID。0.2.27 只接受
/// NSString，读到 NSUUID 时整格被跳过 —— 这就是「有的会清、有的不会」：同一台机器
/// 上不同 App / 不同投递的标识类型不同。这里把两种都折成可比较的字符串
/// （NSUUID → `UUIDString`），其他类型一律不认。
static NSString *AevonClearStringOf(id value) {
    if (value == nil) return nil;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        return text.length > 3 ? text : nil;
    }
    if ([value isKindOfClass:[NSUUID class]]) {
        NSString *text = [(NSUUID *)value UUIDString];
        return text.length > 3 ? text : nil;
    }
    return nil;
}

/// 一个对象上的「通知标识」候选读数。无参、只读，每一步都过 `respondsToSelector` + `@try`。
static NSString *AevonClearIdentifierOf(id object) {
    if (object == nil) return nil;
    static const char *names[5] = {
        "notificationRequestIdentifier", "requestIdentifier",
        "notificationIdentifier", "notificationUUID", "uuid",
    };
    for (int i = 0; i < 5; i++) {
        NSString *value = AevonClearStringOf(AevonCleanRead(object, names[i]));
        if (value != nil) return value;
    }
    return nil;
}

/// 这次要清掉的那一条的标识。先走无参 getter，再走公开链（后者在真机上多半是空，
/// 留着是因为它零风险，且换一代系统可能反过来）。
static NSString *AevonClearIdentifier(id request, id options) {
    id action = AevonOpenFirstAction(request, options);
    if (action == nil) return nil;
    NSString *identifier = AevonClearIdentifierOf(action);
    if (identifier != nil) return identifier;

    id response = AevonCleanRead(action, "notificationResponse");
    id notification = response != nil ? AevonCleanRead(response, "notification") : nil;
    id note = notification != nil ? AevonCleanRead(notification, "request") : nil;
    id raw = note != nil ? AevonCleanRead(note, "identifier") : nil;
    return AevonClearStringOf(raw);
}

/// 0.1.99 — 点通知时的**结构取证**：这条公开链到底断在哪一跳。
///
/// 母版在 iOS 17 上取到过标识（roadmap-0.7 的 log70 打的是
/// `UUID=2064220898762199564_2`），走的就是
/// `action.notificationResponse.notification.request.identifier` 这条公开链；
/// 而真正清成功的那一次落在 `SBNotificationBannerDestination`
/// （log71：`withdrawNotificationRequest:`）。我们现在 6/6 是 `clear=noid` ——
/// 连标识都拿不到，说明链断在 action 这一层，而每份日志都不告诉我们断在哪一跳。
///
/// 这一行只打**类名**：不比较内容、不 retain、不遍历对象图。母版 0.7.9 的教训是
/// 诊断代码本身也可能抛异常（`valueForKey:` 对未定义键必抛），所以整段包在 @try 里，
/// 且 `AevonCleanRead` 只走「先 respondsToSelector、再 objc_msgSend」这一条路。
static void AevonClearProbe(id request, id options) {
    static int notes = 0;
    if (notes >= 6) return;
    notes += 1;
    id action = AevonOpenFirstAction(request, options);
    const char *a = action != nil ? class_getName([action class]) : NULL;
    id l1 = AevonCleanRead(action, "notificationResponse");
    id l2 = l1 != nil ? AevonCleanRead(l1, "notification") : nil;
    id l3 = l2 != nil ? AevonCleanRead(l2, "request") : nil;
    id l4 = l3 != nil ? AevonCleanRead(l3, "identifier") : nil;
    // `-info`：BSAction 的内容在它身上（母版 0.7.8 的结论，也是 0.7.9 的雷区）。
    id info = AevonCleanRead(action, "info");
    id infoDict = info != nil ? AevonCleanRead(info, "infoDictionary") : nil;
    char keys[160];
    keys[0] = '\0';
    if ([infoDict isKindOfClass:[NSDictionary class]]) {
        size_t used = 0;
        for (id key in (NSDictionary *)infoDict) {
            if (![key isKindOfClass:[NSString class]]) continue;
            const char *ks = [(NSString *)key UTF8String];
            if (ks == NULL) continue;
            int n = snprintf(keys + used, sizeof(keys) - used, "%s%s", used > 0 ? "," : "", ks);
            if (n < 0 || (size_t)n >= sizeof(keys) - used) break;
            used += (size_t)n;
        }
    }
    AevonLogRaw([[NSString stringWithFormat:
                  @"notify: clear probe a=%s l1=%s l2=%s l3=%s id=%d info=%s keys=%s n=%d",
                  a != NULL ? a : "-",
                  l1 != nil ? class_getName([l1 class]) : "-",
                  l2 != nil ? class_getName([l2 class]) : "-",
                  l3 != nil ? class_getName([l3 class]) : "-",
                  [l4 isKindOfClass:[NSString class]] ? 1 : 0,
                  info != nil ? class_getName([info class]) : "-",
                  keys[0] != '\0' ? keys : "-", notes]
                 UTF8String]);
}

/// 这个对象是不是那一条请求？只比标识，不碰别的字段。
static BOOL AevonClearRequestMatches(id candidate, NSString *identifier) {
    if (candidate == nil || identifier == nil) return NO;
    NSString *value = AevonClearIdentifierOf(candidate);
    return value != nil && [value isEqualToString:identifier];
}

/// 在某个宿主上找「标识等于 identifier 的请求对象」。
/// 先问「按标识取」（一次到位），再扫三个列表型 getter，最后一张字典。
static id AevonClearFindRequest(id host, NSString *identifier) {
    if (host == nil || identifier == nil) return nil;

    static const char *direct[2] = { "notificationRequestForIdentifier:", "requestForIdentifier:" };
    for (int i = 0; i < 2; i++) {
        SEL sel = sel_registerName(direct[i]);
        Method method = class_getInstanceMethod([host class], sel);
        if (method == NULL) continue;
        char compact[24];
        AevonCleanCompact(method_getTypeEncoding(method), compact, sizeof(compact));
        if (strcmp(compact, "@@:@") != 0) continue;     // 一个对象参数、返回对象
        id got = nil;
        @try {
            got = ((id (*)(id, SEL, id))objc_msgSend)(host, sel, (id)identifier);
        } @catch (NSException *exception) {
            got = nil;
        }
        if (AevonClearRequestMatches(got, identifier)) return got;
    }

    static const char *lists[3] = {
        "notificationRequests", "allNotificationRequests", "presentedNotificationRequests",
    };
    for (int i = 0; i < 3; i++) {
        // 带参数的 section 容器（`notificationRequestsForSectionIdentifier:`）故意不试：
        // 猜 section 等于猜「这个 App 的通知都在这」，猜错就清错别人的。
        id list = AevonCleanRead(host, lists[i]);
        if (![list isKindOfClass:[NSArray class]]) continue;
        for (id item in (NSArray *)list) {
            if (AevonClearRequestMatches(item, identifier)) return item;
        }
    }

    id map = AevonCleanRead(host, "notificationRequestsByIdentifier");
    if ([map isKindOfClass:[NSDictionary class]]) {
        id hit = [(NSDictionary *)map objectForKey:identifier];
        if (hit != nil) return hit;
    }
    return nil;
}

/// 在某个宿主上清一条。四个候选，每个都过「编码逐字符等于 `v@:@`」才调。
static BOOL AevonClearWithdraw(id host, id requestObject, char *how, size_t size) {
    if (host == nil || requestObject == nil) return NO;
    static const char *names[4] = {
        "withdrawNotificationRequest:", "_withdrawNotificationRequest:",
        "removeNotificationRequest:", "clearNotificationRequest:",
    };
    for (int i = 0; i < 4; i++) {
        SEL sel = sel_registerName(names[i]);
        Method method = class_getInstanceMethod([host class], sel);
        if (method == NULL) continue;
        char compact[24];
        AevonCleanCompact(method_getTypeEncoding(method), compact, sizeof(compact));
        if (strcmp(compact, "v@:@") != 0) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(host, sel, requestObject);
            if (how != NULL && size > 0) snprintf(how, size, "%s", names[i]);
            return YES;
        } @catch (NSException *exception) {
            // 这个候选调不通，试下一个。异常不外传：这条链在 SpringBoard 主队列上。
        }
    }
    return NO;
}

/// 0.2.27 — 系统自己的删除口。
///
/// 0.2.26 真机读数：`withdrawNotificationRequest:` 在 `CSNotificationDispatcher`
/// 上**不抛异常**（日志 `via=capture:withdrawNotificationRequest: id=-`），
/// 但通知中心那一条还在 —— 说明内部宿主只撤了横幅/锁屏那一面，没有删投递记录。
/// `UNUserNotificationCenter -removeDeliveredNotificationsWithIdentifiers:`
/// 是同一个投递的公开删除口，通知中心会跟着消失。类不存在就现 dlopen 一次
/// （SpringBoard 不一定加载过 UserNotifications）。
static BOOL AevonClearViaUN(id request, const char *bundle) {
    if (request == nil) return NO;
    // 0.2.28 — 不再「取第一个字符串就走」。四个键分别折成字符串（NSUUID 也认），
    // 一起去问系统：哪个键是真标识由系统答，猜错的那个只是 no-op。
    NSMutableArray<NSString *> *idents = [NSMutableArray array];
    static const char *keys[4] = {
        "notificationIdentifier", "requestIdentifier", "uuid", "identifier",
    };
    for (int i = 0; i < 4; i++) {
        id got = AevonCleanRead(request, keys[i]);
        if (got == nil) continue;
        NSString *text = AevonClearStringOf(got);
        if (text == nil) {
            // 有的版本这一格是 UNNotificationRequest 之类，标识在它里面。
            text = AevonClearStringOf(AevonCleanRead(got, "identifier"));
        }
        if (text != nil && ![idents containsObject:text]) [idents addObject:text];
    }
    if (idents.count == 0) return NO;

    Class cls = NSClassFromString(@"UNUserNotificationCenter");
    if (cls == Nil) {
        void *handle = dlopen("/System/Library/Frameworks/UserNotifications.framework/UserNotifications",
                              RTLD_LAZY);
        if (handle != NULL) cls = NSClassFromString(@"UNUserNotificationCenter");
    }
    if (cls == Nil) return NO;
    SEL cur = sel_registerName("currentNotificationCenter");
    if (![cls respondsToSelector:cur]) return NO;
    id center = ((id (*)(id, SEL))objc_msgSend)((id)cls, cur);
    if (center == nil) return NO;
    SEL remove = sel_registerName("removeDeliveredNotificationsWithIdentifiers:");
    BOOL removed = NO;
    if ([center respondsToSelector:remove]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(center, remove, idents);
            removed = YES;
        } @catch (__unused NSException *e) {
            removed = NO;
        }
    }
    // 0.2.28 — 未决表里也删一遍。不拿它当成功判据：方法不在、或这条已经投递完，
    // 都只是跳过；但「投递了却没进已投递表」的那些正是通知中心里赖着不走的一类。
    SEL pending = sel_registerName("removePendingNotificationRequestsWithIdentifiers:");
    if ([center respondsToSelector:pending]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(center, pending, idents);
        } @catch (__unused NSException *e) {
            // 同上：这条是补刀，不是判据。
        }
    }
    if (bundle != NULL && removed) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: clear b=%s via=un id=%@",
                      bundle, [idents componentsJoinedByString:@","]] UTF8String]);
    }
    return removed;
}

/// 0.2.5 — 用截到的对象清一条。返回 YES 表示这条路真的动了（或确认没有必要再走老路）。
///
/// 三步，缺一不做：
///   ① **归属校验**：`request.sectionIdentifier` 必须就是这次分流的目标 bundle。
///      钩子是全局的（任何 destination 的任何动作都会经过），只靠「4 秒窗」不够
///      —— 用户点通知的同时来了别的动作，没有这一条就会清错 App 的通知。
///   ② **宿主**：先在登记的那个 destination 上调 `withdrawNotificationRequest:`。
///      TrollOpen 的实证是 destination 上就有这个方法（`SBNotificationBannerDestination`
///      一次成功，母版 log71 同样落在它上面）；本体取不到就退回 dispatcher 四格。
///   ③ **只清这一条**：传进去的是截到的那个请求对象本身，不是标识、不是列表。
static BOOL AevonClearFromCapture(const char *bundle, char *how, size_t size) {
    if (bundle == NULL) return NO;
    id request = nil;
    id destination = nil;
    double at = 0;
    @synchronized ([AevonHookProbe class]) {
        request = [AevonCapRequest retain];
        destination = [AevonCapDestination retain];
        at = AevonCapAt;
    }
    if (request == nil) {
        [destination release];
        return NO;
    }

    BOOL cleared = NO;
    BOOL expired = NO;
    @try {
        if (at <= 0 || CFAbsoluteTimeGetCurrent() - at > 4.0) {
            // 过期：不清，也不在这里释放（下一拍 `AevonCapDrop` 会做）。
            expired = YES;
        } else {
            NSString *section = AevonCleanRead(request, "sectionIdentifier");
            if (section == nil) section = AevonCleanRead(request, "sectionID");
            const char *sectionRaw =
                [section isKindOfClass:[NSString class]] ? [(NSString *)section UTF8String] : NULL;
            // 0.2.37 — 归属校验补一条「带后缀」的相等。
            //
            // 用户回的是「部分应用的通知不会自动清理」：这些 App 的 section 不是
            // 裸 bundle，而是 `com.foo.app.<子系统>`（也有反过来的）。0.2.5 起这里
            // 只认逐字相等，于是 `capture:section` 一写、截到的对象就扔掉了，剩下
            // 的标识那条又查不到 → 通知留在中心里。
            //
            // 只在**点号边界**上放宽：`com.foo.app` 与 `com.foo.app.thread` 互认，
            // 但 `com.foo.app` 与 `com.foo.application` 不互认 —— 后者是两个 App。
            BOOL sameSection = NO;
            BOOL prefixed = NO;
            if (sectionRaw != NULL) {
                size_t blen = strlen(bundle);
                size_t slen = strlen(sectionRaw);
                if (strcmp(sectionRaw, bundle) == 0) {
                    sameSection = YES;
                } else if (slen > blen && strncmp(sectionRaw, bundle, blen) == 0
                           && sectionRaw[blen] == '.') {
                    sameSection = YES;
                    prefixed = YES;
                } else if (blen > slen && strncmp(sectionRaw, bundle, slen) == 0
                           && bundle[slen] == '.') {
                    sameSection = YES;
                    prefixed = YES;
                }
            }
            if (sameSection) {
                NSString *ident = AevonCleanRead(request, "identifier");
                const char *identRaw =
                    [ident isKindOfClass:[NSString class]] ? [(NSString *)ident UTF8String] : "-";

                char sel[64];
                sel[0] = '\0';
                if (destination != nil &&
                    AevonClearWithdraw(destination, request, sel, sizeof(sel))) {
                    snprintf(how, size, "capture:%s", sel);
                    cleared = YES;
                } else {
                    id dispatcher = AevonCleanDispatcher();
                    static const char *roles[4] = {
                        "bannerDestination", "dashBoardDestination",
                        "notificationCenterDestination", "lockScreenDestination",
                    };
                    for (int i = 0; i < 4 && !cleared; i++) {
                        id host = AevonCleanRead(dispatcher, roles[i]);
                        if (host == nil) continue;
                        if (AevonClearWithdraw(host, request, sel, sizeof(sel))) {
                            snprintf(how, size, "capture:%s@%s", sel, roles[i]);
                            cleared = YES;
                        }
                    }
                    if (!cleared) {
                        snprintf(how, size, "capture:nowithdraw");
                    }
                }
                // 0.2.27 — 内部 withdraw 之后再补一刀公开删除口。真机上前者
                // 不抛、但通知中心那条还在，所以这里不再拿它的返回值当结论。
                BOOL viaUN = AevonClearViaUN(request, bundle);
                if (viaUN) cleared = YES;
                size_t used = strlen(how);
                if (used + 8 < size) {
                    snprintf(how + used, size - used, " id=%s", identRaw);
                }
                used = strlen(how);
                if (used + 8 < size) {
                    snprintf(how + used, size - used, " un=%d", viaUN ? 1 : 0);
                }
                // 0.2.37 — 这一条是靠「点号边界」认下来的，不是逐字相等。
                used = strlen(how);
                if (prefixed && used + 10 < size) {
                    snprintf(how + used, size - used, " prefix=1");
                }
            } else {
                // 0.2.37 — 把截到的 section 原样打出来：下一次真机日志就能直接看到
                // 是哪个 App 的 section 拼法还没覆盖，不用再猜。
                snprintf(how, size, "capture:section=%s", sectionRaw != NULL ? sectionRaw : "-");
            }
        }
    } @finally {
        [request release];
        [destination release];
    }

    if (cleared || expired) AevonCapDrop();
    return cleared;
}

/// 能力地图。一次开机一行：哪几个宿主上真的有那两个入口。
///
/// 这一行的作用是「下一版不用再装一次机」—— 0.1.89 那次六个候选全没进闸、日志里
/// 连编码长什么样都没有，白丢一版。这里一次把类名、方法在不在、请求列表能读多长写全。
static void AevonClearMap(id dispatcher) {
    // 0.1.99 — dispatcher 取不到时**不打、也不消耗这次机会**。
    //
    // 地图的价值全在四格 destination 上；打一行全 `-` 出去，读日志的人会以为
    // 「四个 destination 都不存在」，而真实原因只是那一次 dispatcher 还没起来。
    // 现在开机 25 秒会主动来一次，点通知那拍还会再来一次，先到先得。
    if (dispatcher == nil) return;
    static int dumped = 0;
    if (dumped) return;
    dumped = 1;
    char line[560];
    size_t used = 0;
    // 0.1.99 — 第一格是 dispatcher 自己的类名。取不到（`-`）是最要紧的一种结果：
    // 它意味着整条清通知链路从入口就断了，后面四格全是 `-` 只是它的后果。
    const char *dcls = dispatcher != nil ? class_getName([dispatcher class]) : NULL;
    used += (size_t)snprintf(line + used, sizeof(line) - used, "notify: clear map d=%s",
                             dcls != NULL ? dcls : "-");
    static const char *roles[4] = {
        "bannerDestination", "dashBoardDestination",
        "notificationCenterDestination", "lockScreenDestination",
    };
    for (int i = 0; i < 4 && used + 60 < sizeof(line); i++) {
        id host = AevonCleanRead(dispatcher, roles[i]);
        if (host == nil) {
            used += (size_t)snprintf(line + used, sizeof(line) - used, " %s=-", roles[i]);
            continue;
        }
        BOOL withdraw = class_getInstanceMethod([host class],
                            sel_registerName("withdrawNotificationRequest:")) != NULL;
        id list = AevonCleanRead(host, "notificationRequests");
        long count = [list isKindOfClass:[NSArray class]] ? (long)[(NSArray *)list count] : -1;
        const char *cls = class_getName([host class]);
        used += (size_t)snprintf(line + used, sizeof(line) - used, " %s=%s w=%d l=%ld",
                                 roles[i], cls != NULL ? cls : "?", withdraw ? 1 : 0, count);
    }
    AevonLogRaw(line);
}

/// 0.2.37 — 这一拍是「补刀」（1.6 秒那次）还是第一拍（0.6 秒）。只影响日志前缀。
static int AevonClearRetry = 0;

/// 真正去做那件事。`bundle` / `identifier` 都是 C 串（跨帧传，自己复制的一份）。
///
/// 0.2.5 — `identifier` 可以是 NULL。老路要靠它去比对，截对象那条路不需要；
/// 而「老路取不到标识」正是 6/6 `clear=noid` 的全部内容 —— 现在那种情况也能清。
static void AevonClearNotification(const char *bundle, const char *identifier) {
    if (bundle == NULL) return;
    if (AevonActivateSwitchOff()) return;
    if (AevonClearExhausted()) return;
    AevonClearRuns += 1;

    char how[96], line[360];
    const char *tag = AevonClearRetry ? " retry" : "";
    how[0] = '\0';

    // ① 截对象先走：不猜标识、不扫列表，是唯一「一定指得到那一条」的做法。
    if (AevonClearFromCapture(bundle, how, sizeof(how))) {
        snprintf(line, sizeof(line), "notify: clear%s b=%s via=%s", tag, bundle, how);
        AevonLogRaw(line);
        return;
    }

    if (identifier == NULL) {
        // 截对象没命中、老路又没有标识 —— 这一条本拍清不掉。记一行说明是哪一半缺的，
        // 下一份日志就不用再靠 `clear=noid` 去猜。
        snprintf(line, sizeof(line), "notify: clear%s b=%s capture=%s id=absent",
                 tag, bundle, how[0] != '\0' ? how : "none");
        AevonLogRaw(line);
        return;
    }

    NSString *want = [NSString stringWithUTF8String:identifier];
    if (want.length < 4) return;

    id dispatcher = AevonCleanDispatcher();
    AevonClearMap(dispatcher);

    // 先 dispatcher 自己（有的系统版本把请求留在它身上），再四个 destination。
    static const char *roles[4] = {
        "bannerDestination", "dashBoardDestination",
        "notificationCenterDestination", "lockScreenDestination",
    };
    for (int i = -1; i < 4; i++) {
        id host = (i < 0) ? dispatcher : AevonCleanRead(dispatcher, roles[i]);
        if (host == nil) continue;
        id requestObject = AevonClearFindRequest(host, want);
        if (requestObject == nil) continue;
        if (AevonClearWithdraw(host, requestObject, how, sizeof(how))) {
            snprintf(line, sizeof(line), "notify: clear b=%s id=%s via=%s sel=%s",
                     bundle, identifier,
                     i < 0 ? "dispatcher" : roles[i], how);
            AevonLogRaw(line);
            return;
        }
    }

    snprintf(line, sizeof(line), "notify: clear b=%s id=%s clear=noreq", bundle, identifier);
    AevonLogRaw(line);
}

/// 排到 0.60 秒之后。字符串自己复制一份带进块里：这个工程按 MRC 编译。
///
/// 0.2.5 — `identifier` 允许为 nil（截对象那条路不需要标识）。这也修掉了一个更隐蔽
/// 的问题：0.1.9x 的调用点是「取到标识才排队」，而真机 6/6 取不到标识 ⇒ 清通知
/// 那整段代码**一次都没被排上**，日志里只有 `clear=noid` 一行，看起来像「清失败」，
/// 其实是「根本没试」。
static void AevonClearLater(const char *bundle, NSString *identifier) {
    if (bundle == NULL) return;
    const char *raw = identifier != nil ? [identifier UTF8String] : NULL;
    // 0.2.37 — 两次：0.60 秒是原来那一拍，1.60 秒是补刀。
    //
    // 用户回「部分应用的通知不会自动清理」，而日志里那条清成功的恰恰是第一拍
    // 就命中的。剩下的多半是「点下去时通知还挂在 banner 手上、0.6 秒时列表里
    // 还没有它」—— 补一刀的成本是一次查表，而 4 秒的截获窗还在有效期内
    // （`AevonClearFromCapture` 每次都会重新校验 `AevonCapAt`）。
    for (int pass = 0; pass < 2; pass++) {
        char *b2 = NULL;
        if (raw != NULL && strlen(raw) >= 4) {
            b2 = strdup(raw);
            if (b2 == NULL) continue;
        }
        char *b1 = strdup(bundle);
        if (b1 == NULL) { free(b2); continue; }
        const double delay = pass == 0 ? 0.60 : 1.60;
        const int retry = pass;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AevonClearRetry = retry;
            AevonClearNotification(b1, b2);
            AevonClearRetry = 0;
            free(b1);
            free(b2);
        });
    }
}

/// 点通知那一刻的绝对时间。只给日志里的 `at=` 用 —— 0.1.90 说「慢了」，那就得有一个
/// 从手指到面板开始走的毫秒数，否则下一版只能靠感觉再调一次。
static double AevonCleanTap = 0;

static int AevonCleanElapsed(void) {
    if (AevonCleanTap <= 0) return -1;
    return (int)((CFAbsoluteTimeGetCurrent() - AevonCleanTap) * 1000.0);
}

/// 等卡片的那条轮询。0.1.91 把节拍从 0.15 秒压到 0.04 秒，并多了一个「卡在路上」的出口。
///
/// 0.1.90 的判据是「卡片真的在（`FloatHost.mainBundle` 置上）才收」，这条留住 —— 它是
/// 唯一不会把用户扔在空桌面上的判据。问题在于它是**唯一**的出口：冷启动时 `openCard`
/// 要先等 scene 出现（真机 0.1~0.5 秒）才占槽，于是面板跟着压 0.5 秒才肯动，用户看到的
/// 就是「点了，等一会儿，通知中心才走」。
///
/// 0.1.91 把「卡在路上」（`AevonCardIsComingFor`，`openCard` 进门就登记）单列成第二个
/// 出口：等满 `AEVON_CLEAN_FORCE` 拍还没占上槽也收。敢这么做的理由是**面板自己那次
/// 下滑要 0.35 秒左右**，卡片落地通常就在这 0.35 秒里 —— 两个动画叠着走，用户看到的
/// 是「面板一走，卡就在」，而不是先空桌面再出卡。0.1.89 之所以在那条路上露出两三秒
/// 空白，是因为它既没有「卡在路上」这一位、也没有卡片这条快路，收的时候卡片连影子
/// 都还没有。
///
/// 第三格照旧不动：`AevonCardIsComingFor` 也答 0（`openCard` 根本没接手、或 3 秒过期）
/// ⇒ 一拍都不收，最多问到 3.6 秒就收手。真锁屏、开卡失败都落在这里。
///
/// 时序（毫秒，从 `divert` 那拍算）：
///   0     `AevonNotifyCleanup` 排进主队列
///   100   第一次问：卡片在 ⇒ 当场收（热启动常见，`at≈100`）
///   100+ 每 40 毫秒再问一次
///   300   还只是「在路上」⇒ 收（`f=1`，冷启动常见）
///   3600  连「在路上」都没有 ⇒ `cover=skip:nocard` 并强制收一次（0.2.28 起）
#define AEVON_CLEAN_DELAY 0.10       // 从手指到第一次问卡片（0.1.90 是 0.45）
#define AEVON_CLEAN_POLL 0.04
#define AEVON_CLEAN_TRIES 90        // 0.04 × 90 = 3.6 秒，与 0.1.90 同一个上限
#define AEVON_CLEAN_FORCE 5         // 5 × 0.04 = 0.2 秒；加上 0.10 秒起始延迟 = 0.30 秒

static void AevonCleanCoverAfterCard(const char *bundle, int tick) {
    if (bundle == NULL || bundle[0] == '\0') return;
    if (AevonActivateSwitchOff()) return;          // 闸：开关每拍都查

    int up = AevonCardIsUpFor(bundle);
    int coming = up ? 1 : AevonCardIsComingFor(bundle);

    if (up || (coming && tick >= AEVON_CLEAN_FORCE)) {
        char cover[128], line[320];
        AevonCleanCover(cover, sizeof(cover), 0);
        // `f=1` 表示这一下是「卡在路上就收了」，不是「卡片已经在」。两者都要留痕：
        // 若用户觉得快是快了但闪了一下，日志里这两格就是分辨它的唯一办法。
        snprintf(line, sizeof(line), "notify: cover b=%s %s wait=%d at=%dms f=%d",
                 bundle, cover, tick, AevonCleanElapsed(), up ? 0 : 1);
        AevonLogRaw(line);
        // 0.2.28 — 0.6 秒后复核。`cover=ok:` 只代表调用没抛，不代表面板走了。
        // 复核只在「这一拍确实调了收面板」后排队，一次点击只有一次。
        if (strncmp(cover, "cover=ok:", 9) == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AevonCleanCoverFollowUp();
            });
        }
        return;
    }
    if (tick >= AEVON_CLEAN_TRIES) {
        // 0.2.28 — 等不到卡片也要收面板。
        //
        // 0.1.90 的判据是「卡片在才收」，那时收早会露出空白桌面；但代价是开卡失败
        // 或卡片被别的东西顶掉时，面板会一直留在屏上 —— 用户说的「点了通知，
        // 通知中心根本不收起」就有这一格。3.6 秒足够卡片起来，起不来时用户已经
        // 等了很久，留一张空桌面好过留一个关不掉的遮罩（真锁屏仍由 passcode 闸拦住）。
        char cover[128], line[320];
        AevonCleanCover(cover, sizeof(cover), 1);
        snprintf(line, sizeof(line), "notify: cover b=%s cover=skip:nocard wait=%d at=%dms %s",
                 bundle, tick, AevonCleanElapsed(), cover);
        AevonLogRaw(line);
        return;
    }

    // 跨帧传字符串：`strdup` 一份带进块里，块自己释放。这个工程按 MRC 编译，
    // 块捕获 `const char *` 不会替你复制内容。
    char *next = strdup(bundle);
    if (next == NULL) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(AEVON_CLEAN_POLL * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonCleanCoverAfterCard(next, tick + 1);
        free(next);
    });
}

/// 分流成功之后补做的那两件收尾。**唯一调用点**是 `AevonOpenHit` 的分流分支，
/// 延迟 0.10 秒、走主队列。
///
/// 横幅当场收（它跟卡片无关，0.1.89 已验过 `banner=ok:bannerDestination`），
/// 面板交给 `AevonCleanCoverAfterCard` 等卡片。
static void AevonNotifyCleanup(const char *bundle) {
    if (AevonActivateSwitchOff()) return;          // 闸一：开关每拍都查
    if (AevonCleanExhausted()) return;
    AevonCleanRuns += 1;

    id dispatcher = AevonCleanDispatcher();
    // 0.1.93 — 把能力地图提前到收尾这一拍。
    //
    // 它原来只挂在 `AevonClearNotification` 里，而那条路要先拿到通知标识才进得去。
    // Aevon(161) 里六次全是 `clear=noid`（标识没取到），于是一次也没走到 ——
    // `notify: clear map` 那行「下一版不用再装一次机」的地图，整整一版都没落盘。
    // 「取不到标识」到底卡在哪一格，日志里因此分不出来。挪到这里：收尾一定会跑。
    AevonClearMap(dispatcher);
    char banner[128], line[360];
    banner[0] = '\0';

    AevonCleanBanner(dispatcher, banner, sizeof(banner));

    const char *dname = dispatcher != nil ? class_getName([dispatcher class]) : "-";
    snprintf(line, sizeof(line), "notify: clean d=%s %s n=%d",
             dname != NULL ? dname : "?", banner, AevonCleanRuns);
    AevonLogRaw(line);

    if (bundle != NULL && bundle[0] != '\0') AevonCleanCoverAfterCard(bundle, 0);
}

/// 0.1.95 — 「带着东西的打开」必须交回系统，只要求它别上全屏。
///
/// 事实链：0.1.92 把分享面板并进分流，Aevon(162) 用户回报「小窗开了，文件没到」。
///   · 分享过来的文件不是「App 自己会去拿」，它是一条 launch option
///     （`__PayloadOptions[UIApplicationLaunchOptionsURLKey]`），要由系统**处理这条
///     打开请求时**把文件拷进目标 App 的 Inbox 并交给 `didFinishLaunching`；
///   · 我们吞掉原实现之后只调 `launchApplicationWithIdentifier:suspended:`，它**不带
///     options** ⇒ 进程起来了、launch option 一个没送到 ⇒ 卡片是空的；
///   · 用户关掉小窗再全屏开一次文件又到了，因为那一次走的是系统原路。
///
/// 母版的做法（roadmap-0.7 的「关键顺序修正」）是把
/// `FBSOpenApplicationOptionKeyActivateSuspended` 写进 options 再走原生打开：
/// **App 不上前台，但 launch options 一个不少**。这里照做，只加这一个键，其余原样复制。
///
/// ⛔ 0.1.95~0.1.97 的错：把**常量名**当键名写进去了
///   （`forKey:@"FBSOpenApplicationOptionKeyActivateSuspended"`）。
///   `FBSOpenApplicationOptionKeyActivateSuspended` 是 FrontBoard 里的 **C 常量**，
///   它的**值**才是要写进字典的那个键 —— `@"__ActivateSuspended"`。
///   写常量名等于塞了一个系统不认识的键：它被原封不动带进请求（Aevon(165) 的回环那行
///   就把它当普通键列了出来），却什么也没约束 ⇒ 原实现照常**前台激活** ⇒
///   卡片和全屏一起来了。同一份日志里系统自己那条相册请求 keys 是
///   `__LaunchIntent,__LaunchSceneless,__ActivateSuspended,…` —— 键名的唯一证据面。
///
/// 只在「分享 + 带 payload」时调用。点通知没有 payload，走了也没东西可送，只会多一次开请求。
static void (^AevonForwardBool)(BOOL) = ^(BOOL ok) {
    AevonLogRaw(ok ? "notify: forward done ok=1" : "notify: forward done ok=0");
};
static void (^AevonForwardObj)(id) = ^(id error) {
    AevonLogRaw(error == nil ? "notify: forward done ok=1" : "notify: forward done err");
};
/// 第三种形状：结果块不带参数（`v8@?0`）。三种形状必须各配一个块 —— 拿 BOOL 块
/// 去顶 void 块，系统按自己的编码调过来，参数寄存器里是什么都不重要，坏在返回约定。
static void (^AevonForwardVoid)(void) = ^{
    AevonLogRaw("notify: forward done ok=1");
};

/// 交回去的那条请求必须能被认出来。
///
/// `_handleOpenApplicationRequest:…` 的原实现会把同一条请求继续交给
/// `_handleTrustedOpenRequestForApplication:…` —— 而那条**也在我们装的四条里**
/// （0.1.87 真机日志就是这么看到落点的）。不认出来，同一条分享会在我们自己的
/// 转发里被分流第二次：第二张卡、第二次转发，最坏是无限套。
///
/// 判据用「对象指针 + 2 秒窗口」，不用线程局部：原实现可能换个队列再往下走，
/// 线程局部在那儿就失效了。只比指针，**不 retain**：请求对象释放之后这次比较
/// 也只是一次整数比较，不会碰已释放的内存。
static __unsafe_unretained id AevonOpenForwardMark = nil;
static CFAbsoluteTime AevonOpenForwardAt = 0;

/// 0.1.99 — 转发前问一次：这次携带的 activation settings 能不能设「挂起」。
///
/// 键名写对之后（0.1.98）Sileo / TrollStore 正常了，QQ / 微信还是全屏。两处差别：
/// 它们走 `op=user` / `op=untrusted`（越狱工具走 `op=open` / `op=trusted`），而且它们
/// 本来就**在后台运行着**。`__ActivateSuspended` 的字面语义是「启动并挂起」——对已在
/// 运行的 App，系统很可能直接走「激活它」，那个键根本用不上。
///
/// SpringBoard 这条路真正的开关也许是第 4 个参数（`SBActivationSettings`）上的某个
/// 选择子。**问是不花钱的**：这里只 `respondsToSelector:`，一个都不调 ——
/// 有结果才在下一版接上去，没结果就把这条排除掉。
static void AevonForwardProbeSettings(id settings) {
    // 0.2.7 — 从「一次开机只记一次」改成「前 12 次都记」。
    //
    // 原来那个 `done` 让这行在开机第一次转发之后永久消失。Aevon(173) 里它确实
    // 出现过一次（`setSusp=0 setFlag=1`），但下一次换一条路进来时，settings 的
    // 类名与能力可能不一样，日志里却什么都没有 —— 而「分享走哪个宿主、宿主上
    // 有没有挂起口」正是本版要回答的问题。
    static int notes = 0;
    if (notes >= 12) return;
    notes += 1;
    const char *cls = settings != nil ? class_getName([settings class]) : NULL;
    int suspSet = 0, flagSet = 0, suspGet = 0, flagGet = 0;
    if (settings != nil) {
        suspSet = [settings respondsToSelector:sel_registerName("setActivateSuspended:")] ? 1 : 0;
        flagSet = [settings respondsToSelector:sel_registerName("setFlag:forActivationSetting:")] ? 1 : 0;
        suspGet = [settings respondsToSelector:sel_registerName("activateSuspended")] ? 1 : 0;
        flagGet = [settings respondsToSelector:sel_registerName("flagForActivationSetting:")] ? 1 : 0;
    }
    AevonLogRaw([[NSString stringWithFormat:
                  @"notify: fwd settings c=%s setSusp=%d setFlag=%d getSusp=%d getFlag=%d n=%d",
                  cls != NULL ? cls : "-", suspSet, flagSet, suspGet, flagGet, notes] UTF8String]);
}

static int AevonOpenForwardPayload(int slot, id self, SEL _cmd, id request, id options,
                                   id settings, id origin, char form) {
    if (slot < 0 || slot >= AevonOpenMax) return 0;
    IMP original = AevonOpenOrig[slot];
    if (original == NULL || form == 0) return 0;
    AevonForwardProbeSettings(settings);
    // 0.2.9 — 转发前后各读一次「系统眼里它是不是前台」。这一对是因果证据：
    // 前 0 后 1 ⇒ 全屏就是这次转发拉起来的；前后都 1 ⇒ 另有其人（得往上追）。
    AevonAppPose("pre", request);

    NSMutableDictionary *forward = options != nil
        ? [options mutableCopy] : [[NSMutableDictionary alloc] init];
    if (forward == nil) return 0;
    [forward setObject:[NSNumber numberWithBool:YES]
                forKey:@"__ActivateSuspended"];
    // 键名的第二道确认：同一份 options 里若已经有别人写的 `__ActivateSuspended`（NO），
    // 上面这一句本身就是覆盖（setObject 不做合并）。这里再读回来落一行日志 ——
    // 「写了」和「写进去了」不是一件事，0.1.95 就是写了、但写的是错的键。
    id susp = [forward objectForKey:@"__ActivateSuspended"];
    // 0.2.8 — 写后回读的真值单独存一份：分享现场行读的是**原始** options（我们改的是
    // 副本），所以那边永远是 -1；这个变量是唯一能证明「挂起键真的进了这一次请求」的东西。
    AevonForwardSuspLast = susp != nil ? [(NSNumber *)susp intValue] : -1;
    AevonLogRaw([[NSString stringWithFormat:@"notify: forward susp=%d keys=%lu",
                  susp != nil ? [(NSNumber *)susp intValue] : -1,
                  (unsigned long)[forward count]] UTF8String]);

    // 0.2.12 — 挂起位写在**第 4 个参数那个 settings 对象**上，不是写在 options 里。
    //
    // 两个层面的区别是这一版的核心判断：options 是输入，SB 进这四个入口之前就已经用
    // `_updateActivationSettings:forRequestWithOptions:clientProcess:application:` 把它
    // 折算成 settings 了（Aevon(181) 的 `win: act api` 里有这条选择子）。也就是说
    // 我们往 options 里加键，加进的是**已经被读过**的东西；0.1.95~0.2.11 六版都无效，
    // 原因就在这里。真正被后续激活逻辑读的是这个对象。
    //
    // 三条硬约束：① 只有名字表里挑出 suspend/background 语义才置（`AevonActSuspIndex`
    // 为 -1 就一位都不置）；② 只置这一条请求并且只置一位；③ 置完立刻读回，读回值
    // 进日志 —— 「写了」和「生效了」不是一件事，这个工程在这上面栽过两次。
    int suspbitRead = -1;
    if (AevonActSuspIndex >= 0 && settings != nil && AevonSuspBitNotes < 8) {
        @try {
            SEL setter = sel_registerName("setFlag:forActivationSetting:");
            SEL getter = sel_registerName("flagForActivationSetting:");
            if ([settings respondsToSelector:setter]) {
                ((void (*)(id, SEL, unsigned long, unsigned long))objc_msgSend)
                    (settings, setter, (unsigned long)AevonActSuspFlag,
                     (unsigned long)AevonActSuspIndex);
                if ([settings respondsToSelector:getter]) {
                    suspbitRead = (int)((unsigned long (*)(id, SEL, unsigned long))objc_msgSend)
                        (settings, getter, (unsigned long)AevonActSuspIndex);
                }
            }
        } @catch (NSException *exception) {
            AevonLogRaw("notify: forward suspbit threw");
        }
        AevonSuspBitNotes += 1;
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: forward suspbit idx=%d flag=%d read=%d enc=%s n=%d",
                      AevonActSuspIndex, AevonActSuspFlag, suspbitRead, AevonActSetEnc,
                      AevonSuspBitNotes] UTF8String]);
    }

    // 结果块要同形状：系统一定会调它一次，形状不对就是当场崩。
    id done = (id)AevonForwardBool;
    if (form == '@') done = (id)AevonForwardObj;
    else if (form == 'v') done = (id)AevonForwardVoid;
    AevonOpenForwardMark = request;
    AevonOpenForwardAt = CFAbsoluteTimeGetCurrent();
    ((void (*)(id, SEL, id, id, id, id, id))original)
        (self, _cmd, request, forward, settings, origin, done);
    AevonAppPose("post", request);
    [forward release];
    return 1;
}

// MARK: - 0.2.14 分享转发延后

/// Swift 侧调用，原型在 bridging header 里；这里再写一行是给这个 `.m` 用的
/// （bridging header 不进 `.m`，`-Wmissing-prototypes` 会把它记成告警，CI 是 `-Werror`）。
void AevonForwardFlush(const char *why);
/// 0.2.15 — 同上，原型也在这里各写一行（bridging header 不进 `.m`）。
void AevonForwardDeliver(const char *why);

/// 「先把请求交回系统，再建卡」这个顺序，是 0.1.95 定的，理由是「裸的挂起启动
/// 会先把 App 拉起来、不带 launch options」。那条理由在**老路**上成立，但它有
/// 一个从没被单独量过的代价：交回系统那一瞬，SpringBoard 就按「用户点了图标」
/// 把目标 App 摆成前台 —— 那是用户看到的全屏，而且它发生在我们的卡片之前。
///
/// Aevon(183) 把这条链一行不落地拍下来了：
///   notify: forward susp=1 keys=4        ← 交回系统
///   notify: forward pass b=com.tencent.mqq op=user
///   notify: open com.tencent.mqq         ← 我们这边才开始建卡
/// 中间那一次前台激活没有人能再收回：等卡片贴上 scene，屏幕上只剩那半截黑。
///
/// 0.2.13 换掉了「怎么打开」（自建 scene、launchIntent=4），可分享这一路连
/// 自建 scene 都没走到 —— 转发先跑，`own start` 才轮上。所以这一版把顺序翻过来：
/// 先让卡片把 process + scene 建起来，再把 payload 投进去。
///
/// 为什么这次可以翻：自建路本来就用 `launchIntent=4` 把进程拉起来了（不带
/// launch options，和挂起启动一样），payload 晚到一点是「运行中的 App 收到一次
/// open URL」，正是 Aevon(183) 里成功那两次的形状（App 已在跑，分享照样进得去）。
///
/// 兜底：1.6 秒还没等到卡片就照原样发出去 —— 慢的 App 不许把分享弄丢。
static int AevonFwdHoldOn = 0;
/// 0.2.48 — 卡片这条路失败时要不要交回系统。
///
/// 分享那条路是 0：Aevon(189) 证明交回 SpringBoard 的代价是「背景全屏变黑」，
/// 用户宁可卡片空着也不要黑屏。链接 / 登录授权这条是 1：它们的功能就是
/// 「把 URL 交给目标 App」，卡片起不来时退回全屏至少还能用（Safari 打开链接、
/// 微信弹出授权页），否则用户点一下「什么都没发生」比全屏严重得多。
static int AevonFwdHoldFallback = 0;
static int AevonFwdHoldSlot = -1;
static char AevonFwdHoldForm = 0;
static id AevonFwdHoldSelf = nil;
static id AevonFwdHoldRequest = nil;
static id AevonFwdHoldOptions = nil;
static id AevonFwdHoldSettings = nil;
static id AevonFwdHoldOrigin = nil;
static NSString *AevonFwdHoldBundle = nil;
static SEL AevonFwdHoldCmd = NULL;
static CFAbsoluteTime AevonFwdHoldAt = 0;
static int AevonFwdHoldNotes = 0;
/// 0.2.17 — 复检计数（定义在 `AevonForwardHoldWatch` 旁边，`AevonForwardHold`
/// 里要把上一张卡的计数清零，所以在这里先声明一格）。
static int AevonForwardWatchN;

static void AevonForwardFlushNow(const char *why);
/// 0.2.17 — 「App 内投递还挂着」。定义在下面 appurl 那一段；转发超时先问这一句。
static int AevonAppOpenBusy(void);

/// 只留一条。第二条分享进来时先把上一条发出去：丢掉一条 = 用户点的那次分享
/// 什么都没发生，比晚一点严重得多。
static int AevonForwardHold(int slot, id self, SEL _cmd, id request, id options,
                            id settings, id origin, char form, NSString *bundle,
                            int fallback) {
    if (slot < 0 || _cmd == NULL || request == nil) return 0;
    if (AevonFwdHoldOn) AevonForwardFlushNow("replaced");
    AevonFwdHoldOn = 1;
    AevonFwdHoldFallback = fallback;
    AevonFwdHoldSlot = slot;
    AevonFwdHoldForm = form;
    AevonFwdHoldCmd = _cmd;
    AevonFwdHoldSelf = [(id)self retain];
    AevonFwdHoldRequest = [(id)request retain];
    AevonFwdHoldOptions = [(id)options retain];
    AevonFwdHoldSettings = [(id)settings retain];
    AevonFwdHoldOrigin = [(id)origin retain];
    AevonFwdHoldBundle = [bundle copy];
    AevonFwdHoldAt = CFAbsoluteTimeGetCurrent();
    AevonForwardWatchN = 0;
    if (AevonFwdHoldNotes < 12) {
        AevonFwdHoldNotes += 1;
        AevonLogRaw([[NSString stringWithFormat:@"notify: forward held slot=%d form=%c",
                      slot, form != 0 ? form : '0'] UTF8String]);
    }
    return 1;
}

static void AevonForwardFlushNow(const char *why) {
    if (!AevonFwdHoldOn) return;
    int slot = AevonFwdHoldSlot;
    char form = AevonFwdHoldForm;
    SEL cmd = AevonFwdHoldCmd;
    id self = AevonFwdHoldSelf;
    id request = AevonFwdHoldRequest;
    id options = AevonFwdHoldOptions;
    id settings = AevonFwdHoldSettings;
    id origin = AevonFwdHoldOrigin;
    // 先清标志再调用：原实现会重入本文件的替身，状态必须先回到「没有待发」，
    // 否则那次重入会以为自己还有一条要发。
    AevonFwdHoldOn = 0;
    AevonFwdHoldFallback = 0;
    AevonFwdHoldSlot = -1;
    AevonFwdHoldCmd = NULL;
    AevonFwdHoldSelf = nil;
    AevonFwdHoldRequest = nil;
    AevonFwdHoldOptions = nil;
    AevonFwdHoldSettings = nil;
    AevonFwdHoldOrigin = nil;
    [AevonFwdHoldBundle release];
    AevonFwdHoldBundle = nil;
    double waited = AevonFwdHoldAt > 0 ? (CFAbsoluteTimeGetCurrent() - AevonFwdHoldAt) : 0;
    AevonFwdHoldAt = 0;
    if (AevonFwdHoldNotes < 12) {
        AevonFwdHoldNotes += 1;
        AevonLogRaw([[NSString stringWithFormat:@"notify: forward flush why=%s after=%.0fms",
                      why != NULL ? why : "-", waited * 1000.0] UTF8String]);
    }
    if (request != nil && cmd != NULL) {
        AevonOpenForwardPayload(slot, self, cmd, request, options, settings, origin, form);
    }
    [self release];
    // `request` **故意不 release**：`AevonOpenForwardPayload` 把它留在
    // `AevonOpenForwardMark` 里，接下来 2 秒内的派生请求要靠这个指针认领，
    // 其中 `adopted` 那条分支会真的去读它的 bundle（`AevonOpenBundleOf`）。
    // 这里是 MRC，release 早了就是 use-after-free —— 一次分享漏一个请求对象
    // 换「不会崩」，这个工程一贯这么选（同 `providerHeap` 那一处）。
    [options release];
    [settings release];
    [origin release];
}

/// 0.2.15 — 这条请求我们自己在 App 里投递成功了 ⇒ 就地销毁，一个字节都不交给
/// SpringBoard。与 `AevonForwardFlushNow` 的关键差别只有一条：不调原实现。
static void AevonForwardDrop(const char *why) {
    if (!AevonFwdHoldOn) return;
    double waited = AevonFwdHoldAt > 0 ? (CFAbsoluteTimeGetCurrent() - AevonFwdHoldAt) : 0;
    id heldSelf = AevonFwdHoldSelf;
    id options = AevonFwdHoldOptions;
    id settings = AevonFwdHoldSettings;
    id origin = AevonFwdHoldOrigin;
    AevonFwdHoldOn = 0;
    AevonFwdHoldFallback = 0;
    AevonFwdHoldSlot = -1;
    AevonFwdHoldCmd = NULL;
    AevonFwdHoldSelf = nil;
    AevonFwdHoldRequest = nil;
    AevonFwdHoldOptions = nil;
    AevonFwdHoldSettings = nil;
    AevonFwdHoldOrigin = nil;
    [AevonFwdHoldBundle release];
    AevonFwdHoldBundle = nil;
    AevonFwdHoldAt = 0;
    if (AevonFwdHoldNotes < 12) {
        AevonFwdHoldNotes += 1;
        AevonLogRaw([[NSString stringWithFormat:@"notify: forward drop why=%s after=%.0fms",
                      why != NULL ? why : "-", waited * 1000.0] UTF8String]);
    }
    [heldSelf release];
    [options release];
    [settings release];
    [origin release];
}

/// 0.2.17 — 转发超时从「1.6 s 一刀」改成「等 App 内投递的结论」。
///
/// Aevon(188) 把这一格拍死了：
///
///   21:32:16 notify: appurl send …                            ← 卡片刚起，App 的窗口还没连上
///   21:32:17 notify: appurl ack ok=0 via=noscene at=207ms
///   21:32:17 notify: appurl retry n=1..4                      ← 我们还在重投
///   21:32:18 notify: forward flush why=timeout after=1675ms   ← 抢跑了
///   21:32:18 notify: forward pass b=com.tencent.mqq …         ← SB 全屏、内容被抢、卡片黑
///
/// App 侧那条链要 3 秒才出结论，1.6 秒的定时器先把它交回 SpringBoard 了。从这一版
/// 起：只要还有一次投递挂着，就每 0.5 s 复检一次，最长 6 s。结论出来之后（成功走
/// `AevonForwardDrop`、失败也走 Drop）这个定时器天然变成空操作。
/// 0.2.18 — 「这次分享没进去」的唯一写法：一行 `share lost` + 就地销毁。
///
/// **绝不交回 SpringBoard**。Aevon(189) 已经证明交回的代价不是「晚一点」而是
/// 「背景全屏变黑」：`notify: forward pass b=com.tencent.mqq` 之后 SB 把这个 App
/// 的 scene 抢去整屏，卡片孤零零浮在黑底上（`win: scene frame after=430x717`
/// 说明卡片自己是好的，黑的是它背后）。
static void AevonForwardLost(const char *why) {
    if (!AevonFwdHoldOn) return;
    double ms = AevonFwdHoldAt > 0 ? (CFAbsoluteTimeGetCurrent() - AevonFwdHoldAt) * 1000.0 : 0;
    AevonLogRaw([[NSString stringWithFormat:@"notify: share lost b=%@ why=%s at=%.0fms",
                  AevonFwdHoldBundle != nil ? AevonFwdHoldBundle : @"-",
                  why != NULL ? why : "-", ms] UTF8String]);
    // 0.2.48 — 链接 / 登录授权卡不住时退回系统全屏：它们的功能是「把 URL 交给
    // 目标 App」，没有卡片也得让 Safari 打开链接、微信弹出授权页。分享那条
    // 仍然是就地销毁（见 `AevonFwdHoldFallback` 上面的说明）。
    if (AevonFwdHoldFallback) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: link fallback b=%@ why=%s",
                      AevonFwdHoldBundle != nil ? AevonFwdHoldBundle : @"-",
                      why != NULL ? why : "-"] UTF8String]);
        AevonForwardFlushNow(why != NULL ? why : "lost");
        return;
    }
    AevonForwardDrop(why != NULL ? why : "lost");
}

/// 0.2.18 — 两种「等」分开算，都不交回系统：
///
///   · 投递**已经发起**（`AevonAppOpenBusy()`）⇒ 等它的结论。App 侧重投最长
///     6.3 秒（14 × 0.45），这里给 7 秒（14 拍）硬上限；超了算卡死（`appurl stuck`）。
///   · 投递**一次都没发起** ⇒ 卡片还在建（或者这条请求根本走不到投递）。
///     4 秒宽限（8 拍）。Aevon(189) 之所以 0 ms 就交回，就是把这个「还没发起」
///     当成「不用等」了。
static void AevonForwardHoldWatch(double waited) {
    if (!AevonFwdHoldOn) return;
    if (AevonAppOpenBusy()) {
        if (waited >= 7.0 || AevonForwardWatchN >= 14) {
            AevonForwardLost("appurl stuck");
            return;
        }
    } else if (waited >= 4.0) {
        AevonForwardLost("no deliver");
        return;
    }
    AevonForwardWatchN += 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonForwardHoldWatch(waited + 0.5);
    });
}

/// 卡片把 scene 贴上（或等超时）时由主线程调用。任意线程调都安全。
void AevonForwardFlush(const char *why) {
    if (!AevonFwdHoldOn) return;
    if ([NSThread isMainThread]) {
        AevonForwardFlushNow(why);
        return;
    }
    char *copy = strdup(why != NULL ? why : "-");
    dispatch_async(dispatch_get_main_queue(), ^{
        AevonForwardFlushNow(copy);
        if (copy != NULL) free(copy);
    });
}

// MARK: - 0.2.15 分享 payload 直投目标 App（不经 SpringBoard）

/// Aevon(185) 把「转发」那一刻拍清楚了：`notify: forward pass b=com.tencent.mqq`
/// 之后紧跟着这几行 ——
///   win: scene frame after=430x932        ← 我们自己建的那个 scene 被改成全屏
///   app: page transition h=932 last=717   ← App 那边同时被拉到 932
///   win: after 1s hosted=-1 sublayers=0   ← 卡片这边什么都没有了
/// 用户看到的就是「QQ 全屏 + 浮窗黑屏」。也就是说：只要这条请求进了 SpringBoard
/// 的打开流程，它就会把**这个 App 的 scene** 摆到前台；我们自己建 scene、把 frame
/// 设成多少都不作数 —— 0.2.13 换「怎么打开」解决不了这一层。
///
/// 所以分享这条不再经过它：宿主把 URL + 原始 options 写进目标 App 容器的
/// `tmp/aevon-open.plist`，再发一声 `com.aevon.openurl.<bundle>`（通道方向与
/// `aevon-mini` 相同，那条已在真机上双向验证过），由 App 进程里我们的 dylib
/// 把这次 open URL 交给自己。回执写在 `tmp/aevon-open-ack`（`ok=1 via=app`）。
/// 1.25 秒没有回执才退回老路（交回 SpringBoard）—— 分享宁可全屏一次，也不许丢。
static int AevonAppOpenNotes = 0;   // 这组行最多 20 条：分享是低频动作，20 条够一轮真机
static int AevonAppOpenPending = 0;

/// 0.2.17 — 给「转发超时」那一边看的只读位。见 `AevonForwardHoldWatch`。
static int AevonAppOpenBusy(void) { return AevonAppOpenPending; }
static int AevonAppOpenTries = 0;
static NSString *AevonAppOpenBundle = nil;
static NSString *AevonAppOpenURL = nil;
static id AevonAppOpenOptions = nil;
static NSString *AevonAppOpenSource = nil;
static CFAbsoluteTime AevonAppOpenAt = 0;
/// 每一轮最多投几次。App 刚被 `launchIntent=4` 拉起来的那一秒里，它的
/// window scene 还没连上、分享路由还没装好 —— Aevon(186) 就是在第 207ms 问的，
/// QQ 的 `application:openURL:options:` 当场回 NO，我们立刻退回转发，
/// 于是又一次全屏+黑屏。8 次 × 0.35s ≈ 3 秒，够它把界面搭起来。
// 0.2.18 — 10 → 14，间隔 0.35 → 0.45。App 侧现在会先等最多 4 秒的「界面长出来」，
// 这段时间它**不写回执**；宿主如果还按 3.5 秒就放弃，那 4 秒的等待等于白等。
// 14 × 0.45 = 6.3 秒，刚好盖住它，且与 `AevonForwardHoldWatch` 的 7 秒硬上限对齐。
static const int AevonAppOpenMaxTries = 14;

static NSString *AevonAppOpenLeaf(NSString *bundleID, NSString *leaf) {
    if (bundleID.length == 0 || leaf.length == 0) return nil;
    NSString *dir = AevonAppContainer(bundleID);
    if (dir.length == 0) return nil;
    return [dir stringByAppendingPathComponent:[@"tmp/" stringByAppendingString:leaf]];
}

/// plist 装得下的形状才留。`options` 里既有 `NSString` 也有私有对象
/// （`__PasteSharingToken` 就不是公开类），装不进去的丢掉并记账 ——
/// 「带了几项 / 丢了几项」是下一轮判「分享内容为什么没到」的唯一线索。
static id AevonAppOpenSafe(id value, int depth, int *dropped) {
    if (value == nil || depth > 3) return nil;
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSData class]] || [value isKindOfClass:[NSDate class]]) {
        return value;
    }
    // 老式 `NSURL` 在 plist 里不合法，转字符串保存。
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            id safe = AevonAppOpenSafe(item, depth + 1, dropped);
            if (safe != nil) [out addObject:safe];
        }
        return out;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)value) {
            if (![key isKindOfClass:[NSString class]]) { *dropped += 1; continue; }
            id safe = AevonAppOpenSafe([(NSDictionary *)value objectForKey:key],
                                       depth + 1, dropped);
            if (safe != nil) [out setObject:safe forKey:key];
            else *dropped += 1;
        }
        return out;
    }
    *dropped += 1;
    return nil;
}

static void AevonAppOpenCheck(void);

static void AevonAppOpenDrop(void) {
    AevonAppOpenPending = 0;
    AevonAppOpenTries = 0;
    AevonAppOpenAt = 0;
    [AevonAppOpenBundle release];
    AevonAppOpenBundle = nil;
    [AevonAppOpenURL release];
    AevonAppOpenURL = nil;
    [AevonAppOpenOptions release];
    AevonAppOpenOptions = nil;
    [AevonAppOpenSource release];
    AevonAppOpenSource = nil;
}

static void AevonAppOpenNext(double gap) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonAppOpenCheck();
    });
}

/// 把「这一次投递」写进目标 App 容器并发一声通知。`send` 与 `retry` 共用：
/// 两处的文件形状必须一模一样，一处改一处忘就是又一轮「为什么它读不到」。
static int AevonAppOpenWrite(void) {
    NSString *plist = AevonAppOpenLeaf(AevonAppOpenBundle, @"aevon-open.plist");
    if (plist == nil || AevonAppOpenURL == nil) return 0;
    NSDictionary *box = [NSDictionary dictionaryWithObjectsAndKeys:
                         AevonAppOpenURL, @"url",
                         AevonAppOpenOptions != nil ? AevonAppOpenOptions : [NSDictionary dictionary],
                         @"options",
                         AevonAppOpenSource != nil ? AevonAppOpenSource : @"", @"src", nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:box
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:NULL];
    if (data == nil) return 0;
    if (![data writeToFile:plist atomically:YES]) return 0;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)[NSString stringWithFormat:@"com.aevon.openurl.%@",
                               AevonAppOpenBundle],
        NULL, NULL, true);
    return 1;
}

/// 1 = 已经发出去（正在等回执） / 0 = 发不出去（调用方立刻走老路）
static int AevonAppOpenSend(NSString *bundleID, NSString *url, id options, NSString *src) {
    if (bundleID.length == 0 || url.length == 0) return 0;
    NSString *plist = AevonAppOpenLeaf(bundleID, @"aevon-open.plist");
    NSString *ack = AevonAppOpenLeaf(bundleID, @"aevon-open-ack");
    if (plist == nil || ack == nil) {
        if (AevonAppOpenNotes < 20) {
            AevonAppOpenNotes += 1;
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: appurl none b=%@ (no container)", bundleID] UTF8String]);
        }
        return 0;
    }
    int dropped = 0;
    id safe = AevonAppOpenSafe(options, 0, &dropped);
    if (safe == nil) safe = [NSDictionary dictionary];
    int kept = [safe isKindOfClass:[NSDictionary class]] ? (int)[(NSDictionary *)safe count] : 0;
    // 上一轮的回执照删：留着会让这一轮读到别人的答案。
    [[NSFileManager defaultManager] removeItemAtPath:ack error:NULL];
    [AevonAppOpenBundle release];
    AevonAppOpenBundle = [bundleID copy];
    [AevonAppOpenURL release];
    AevonAppOpenURL = [url copy];
    [AevonAppOpenOptions release];
    AevonAppOpenOptions = [safe retain];
    [AevonAppOpenSource release];
    AevonAppOpenSource = [src copy];
    AevonAppOpenAt = CFAbsoluteTimeGetCurrent();
    if (AevonAppOpenWrite() == 0) {
        if (AevonAppOpenNotes < 20) {
            AevonAppOpenNotes += 1;
            AevonLogRaw([[NSString stringWithFormat:
                          @"notify: appurl no write b=%@", bundleID] UTF8String]);
        }
        AevonAppOpenDrop();
        return 0;
    }
    AevonAppOpenPending = 1;
    AevonAppOpenTries = 0;
    if (AevonAppOpenNotes < 20) {
        AevonAppOpenNotes += 1;
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: appurl send b=%@ opt=%d/%d src=%@ u=%.48s",
                      bundleID, kept, dropped,
                      src != nil ? src : @"-", [url UTF8String]] UTF8String]);
    }
    AevonAppOpenNext(0.20);
    return 1;
}

static void AevonAppOpenGiveUp(const char *why) {
    if (!AevonAppOpenPending) return;
    double ms = (CFAbsoluteTimeGetCurrent() - AevonAppOpenAt) * 1000.0;
    AevonLogRaw([[NSString stringWithFormat:@"notify: appurl give b=%@ why=%s at=%.0fms",
                  AevonAppOpenBundle != nil ? AevonAppOpenBundle : @"-",
                  why != NULL ? why : "-", ms] UTF8String]);
    AevonAppOpenDrop();
    // 0.2.17 — 这里原来是「退回老路，交回 SpringBoard」。那条路的代价 Aevon(188)
    // 拍得很清楚：SB 把这 App 的 scene 抢去全屏（`app: page transition h=717
    // last=932`），卡片随即黑屏，而用户要的是「背景停在文件分享发起页」。
    // 所以没投进去就**就地销毁**：卡片留着（空的），不抢全屏、不黑屏。
    // 内容这一拍确实没进去 —— 这一行是唯一的诚实记录，也是下一步的诊断入口。
    AevonLogRaw([[NSString stringWithFormat:@"notify: share lost b=%@ why=%s",
                  AevonFwdHoldBundle != nil ? AevonFwdHoldBundle : @"-",
                  why != NULL ? why : "-"] UTF8String]);
    // 0.2.48 — 链接 / 登录授权：App 侧投递失败也要把 URL 交出去（全屏兜底），
    // 否则用户点登录只会得到一张空卡。分享那条保持 0.2.18 的就地销毁。
    if (AevonFwdHoldFallback) {
        AevonLogRaw([[NSString stringWithFormat:@"notify: link fallback b=%@ why=%s",
                      AevonFwdHoldBundle != nil ? AevonFwdHoldBundle : @"-",
                      why != NULL ? why : "-"] UTF8String]);
        AevonForwardFlushNow("appurl fail");
        return;
    }
    AevonForwardDrop("appurl fail");
}

/// 0.2.59 — 授权交接完成 ⇒ 把刚用完的那张卡收掉。
///
/// 判据三条一起看，少一条都会误收：
///   · **送信方**是微信 / QQ（`src=`）—— 只有它们会递 SSO 结果；
///   · **送出去的 URL** 带 `oauth` 或 `code=`（回跳的形状）；
///   · 那一方**真的还有卡**（`AevonCardCloseFor` 自己答 0/1，这里不预判）。
///
/// 与分流那条「回跳」分支互补：走本地投递（`incard`）时回执在这里判，
/// 整屏放行（`callback`）时没有回执，由分流层直接排。两条都收到同一个函数。
static void AevonAuthCardCloseMaybe(void) {
    if (AevonAppOpenURL == nil || AevonAppOpenSource == nil) return;
    if (![AevonAppOpenSource hasPrefix:@"com.tencent.xin"] &&
        ![AevonAppOpenSource hasPrefix:@"com.tencent.mqq"]) return;
    NSString *low = [AevonAppOpenURL lowercaseString];
    if ([low rangeOfString:@"oauth"].location == NSNotFound &&
        [low rangeOfString:@"code="].location == NSNotFound) return;
    AevonAuthCardCloseSoon(AevonAppOpenSource, "ack");
}

/// 回执的三种答案：`ok=1` 收工、`ok=0` 立刻退回老路、文件根本没有就再等一拍。
static void AevonAppOpenCheck(void) {
    if (!AevonAppOpenPending) return;
    NSString *ack = AevonAppOpenLeaf(AevonAppOpenBundle, @"aevon-open-ack");
    NSString *text = ack != nil
        ? [NSString stringWithContentsOfFile:ack encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (text != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:ack error:NULL];
        BOOL ok = [text rangeOfString:@"ok=1"].location != NSNotFound;
        NSString *via = @"?";
        NSRange at = [text rangeOfString:@"via="];
        if (at.location != NSNotFound) {
            NSString *rest = [text substringFromIndex:at.location + at.length];
            NSArray *parts = [rest componentsSeparatedByCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (parts.count > 0) via = [parts objectAtIndex:0];
        }
        double ms = (CFAbsoluteTimeGetCurrent() - AevonAppOpenAt) * 1000.0;
        // 0.2.17 — `sc=` 是 App 侧报的「这个进程有几条 scene」。`sc=0` 加上
        // `ok=0` 不是「它拒绝」，而是「它还没有界面可以接」：App 刚被拉起来的那
        // 一两秒里 window scene 还没连上，问它等于问一个还没长出来的对象。
        // 这种答案不计入「拒绝」，继续重投（Aevon(188) 八次全是这一种）。
        int sc = -1;
        // 0.2.18 — 前面加一个空格：回执里现在紧跟着就有 `wsc=`，而 `wsc=` 里
        // 也含 `sc=` 这三个字符，不带前导空格的查找会看情况抓到错的字段。
        NSRange scAt = [text rangeOfString:@" sc="];
        if (scAt.location != NSNotFound) {
            NSString *rest = [text substringFromIndex:scAt.location + scAt.length];
            sc = rest.intValue;
        }
        NSString *trimmed = [text stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 160) trimmed = [trimmed substringToIndex:160];
        AevonLogRaw([[NSString stringWithFormat:
                      @"notify: appurl ack b=%@ ok=%d via=%@ at=%.0fms [%@]",
                      AevonAppOpenBundle != nil ? AevonAppOpenBundle : @"-",
                      ok ? 1 : 0, via, ms, trimmed] UTF8String]);
        if (ok) {
            // 投递成功 ⇒ 这条请求就地销毁，**绝不**交给 SpringBoard：
            // 交给它就是把 App 的 scene 抢去全屏（这一版唯一要避开的事）。
            AevonAppOpenDrop();
            AevonAuthCardCloseMaybe();
            AevonForwardDrop("appurl ok");
            return;
        }
        // `ok=0` 是「这一拍不认」，不是「永远不认」：Aevon(186) 是在卡片起来后
        // 第 207ms 问的，QQ 的 window scene 还没连上，当然回 NO；我们立刻退回
        // 转发，于是又全屏又黑屏。改成再投几次，三次都在同一个窗口里问同一个
        // 还没长大的进程，答案没有意义。
        AevonAppOpenTries += 1;
        if (AevonAppOpenTries < AevonAppOpenMaxTries) {
            if (AevonAppOpenWrite() == 0) {
                AevonAppOpenGiveUp("write");
                return;
            }
            if (AevonAppOpenNotes < 20) {
                AevonAppOpenNotes += 1;
                AevonLogRaw([[NSString stringWithFormat:
                              @"notify: appurl retry n=%d via=%@",
                              AevonAppOpenTries, via] UTF8String]);
            }
            AevonAppOpenNext(0.45);
            return;
        }
        AevonAppOpenGiveUp(sc == 0 ? "no-ui" : "refused");
        return;
    }
    AevonAppOpenTries += 1;
    if (AevonAppOpenTries < AevonAppOpenMaxTries) {
        // 连回执都没有：可能 App 里我们的 dylib 还没装载完（0.0.x 的装载重试
        // 是 2 秒 × 3），也可能这一拍正好被系统回收。重投比猜快。
        if (AevonAppOpenWrite() == 0) {
            AevonAppOpenGiveUp("write");
            return;
        }
        AevonAppOpenNext(0.45);
        return;
    }
    AevonAppOpenGiveUp("timeout");
}

/// 这条请求还挂在手里时能读到的 URL：顶层 `__PayloadURL` 优先，其次是
/// `__PayloadOptions[UIApplicationLaunchOptionsURLKey]`（两条都在真机上见过）。
static NSString *AevonForwardHeldURL(void) {
    id value = AevonOpenAnyValue(AevonFwdHoldRequest, AevonFwdHoldOptions, @"__PayloadURL");
    if (value == nil) {
        id payload = AevonOpenPayload(AevonFwdHoldRequest, AevonFwdHoldOptions);
        if (payload != nil) {
            value = AevonActRead(payload, @"UIApplicationLaunchOptionsURLKey");
        }
    }
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    // 0.2.55 — 投递这一侧改用和分流判据同一套查找。
    //
    // 0.2.53 的判据已经靠 `AevonOpenScanURL` 在别的层里找到了登录 URL
    // （QQ / 微信的 SSO 深链并不总在 `__PayloadURL`），可这里只读两个老键：
    // 判据认出来了、卡片也建好了，投递却答「没有 URL」→
    // `forward flush why=appurl no url` → 交回系统 → 微信被整屏拉一下。
    // QQ 的 URL 恰好在 `__PayloadURL`（所以它没事），微信这一条不在，正好只闪它。
    // 两边共用 `AevonOpenURLOf`，从此不会再走岔。
    return AevonOpenURLOf(AevonFwdHoldRequest, AevonFwdHoldOptions);
}

/// 卡片把 scene 贴上时由 Swift 侧调用（主线程，或任意线程）。与
/// `AevonForwardFlush` 的区别只有一条：**先试 App 内投递，失败才交回系统。**
void AevonForwardDeliver(const char *why) {
    if (!AevonFwdHoldOn) return;
    if (![NSThread isMainThread]) {
        char *copy = strdup(why != NULL ? why : "-");
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonForwardDeliver(copy);
            if (copy != NULL) free(copy);
        });
        return;
    }
    // 0.2.38 — 粘贴板分享不再走这条投递链：`AevonOpenDecide` 已经把它整条放行
    // （见那一支的注释：token 只能随系统激活过 XPC，而 App 一旦在跑，挂起位就被
    // 无视，必然全屏）。这里不再需要特判。
    NSString *url = AevonForwardHeldURL();
    NSString *bundle = AevonFwdHoldBundle;
    if (url.length == 0 || bundle.length == 0) {
        // 拿不到 URL（分享的是纯粘贴板内容、或者键名变了）⇒ 不额外等，直接走老路。
        AevonForwardFlushNow(why != NULL ? why : "appurl no url");
        return;
    }
    // 来源 App。系统那次真正的 openURL 会带 `UIApplicationOpenURLOptionsSourceApplicationKey`
    // （分享扩展那条是 `com.tencent.mqq.ShareExtension`），我们的 options 里没有这一项
    // —— Aevon(186) 里 QQ 第 207ms 回 NO，最可能就是缺它（也可能是它还没准备好，
    // 两个原因这一版一起治）。值只在宿主这一侧拿得到，所以随投递文件一起送过去。
    id raw = AevonOpenSourceApp(AevonFwdHoldRequest, AevonFwdHoldOptions);
    NSString *src = [raw isKindOfClass:[NSString class]] ? (NSString *)raw : nil;
    if (AevonAppOpenSend(bundle, url, AevonFwdHoldOptions, src) == 1) return;
    AevonForwardFlushNow("appurl no file");
}

/// 替身。**顺序就是这里的全部安全设计**：
///   ① 快照 —— 只读，不改任何参数；
///   ② 分流判定 —— 只有「这一拍是一次通知点击」才改变行为，其余一个字节都不动；
///   ③ 原实现 —— 不分流时原样转发，返回值原样交回；
///   ④ 落盘 —— 异步，写盘那 0.1~0.3 ms 不压在「点开 App」那一拍上。
///
/// 0.1.88 起第 ③ 步前面多了一个分支：判据成立时**不转发**，改叫 `openCard`
/// （`AevonOpenFromNotification` → `RingHost.openFromNotification` → `SceneProbe.openCard`），
/// 由它挂起启动、建卡片、必要时自己全屏兜底。转发与不转发互斥，不会两头都开。
static void AevonOpenHit(id self, SEL _cmd, id request, id options,
                         id settings, id origin, id result) {
    int slot = AevonOpenSlot(_cmd);
    // 0.2.9 — 这里原来每拍先把 `AevonForwardSuspLast` 清成 -1，导致分享现场行的
    // `fsusp=` 恒为 -1：转发时原实现会**重入**本函数（`notify: forward pass … op=user`），
    // 那次重入又把全局清掉了，外层回来读到的就只剩 -1。现在改成只有转发那一处写它，
    // 读的时候连同 `fwd=` 一起看 —— `fwd=0` 时这个字段无意义（沿用上一条的值）。
    char line[640];
    line[0] = '\0';
    char bundle[64];
    bundle[0] = '\0';
    const char *why = "-";
    int verdict = 0;

    // 分流判定只对「我们装上的那四条」做。父类链上万一还有人来，走原样转发。
    //
    // 0.1.95：先认一眼「这条请求是不是我们自己刚交回去的那条」。是的话**只放行**，
    // 一个字节都不改 —— 认不出来的后果见 `AevonOpenForwardMark` 上面那段。
    int passThrough = (request != nil && request == AevonOpenForwardMark &&
                       AevonOpenForwardAt > 0 &&
                       CFAbsoluteTimeGetCurrent() - AevonOpenForwardAt < 2.0);
    // 0.2.7 — 第二道认领：**同一个 App 的第二次请求**也当我们自己人。
    //
    // Aevon(173) 的真机现场（分享给 QQ，一行一行都在）：
    //   notify: forward susp=1 keys=4                      ← op=trusted 那条转发出去
    //   notify: forward pass b=com.tencent.mqq op=user      ← 指针认领成功
    //   notify: divert b=com.tencent.mqq op=untrusted why=share … fwd=1
    //
    // 第三条说明 **op=untrusted 这条又被分流、又转发了一次**。它不是同一个对象
    // ——系统在 trusted → untrusted 之间重建了 request —— 所以指针那条认领拦不住
    // 它。多转发一次就是多调一次原实现，也就是**多一次前台激活**：卡片里一个、
    // 屏幕上又一个，用户看到的就是「小窗 + 全屏」。
    //
    // 三家的共同意识是「这次打开是我自己发起的」（Myrtle 甚至把「打开理由」做成
    // 贯穿到完成回调的参数）。这里用最便宜的形状：**2 秒内 + 同一个 bundle**
    // 就算自己人，认领后立刻把窗口关掉（一次有效），不 retain 任何对象。
    //
    // 只比 bundle 字符串，不碰 payload 类型：分享那条链上后续请求的 payload 会被
    // 系统改写，拿它当条件会刚好把要认的那一条漏掉。
    int adopted = 0;
    if (!passThrough && request != nil && AevonOpenForwardMark != nil &&
        AevonOpenForwardAt > 0 &&
        CFAbsoluteTimeGetCurrent() - AevonOpenForwardAt < 2.0) {
        id mineBundle = AevonOpenBundleOf(AevonOpenForwardMark);
        id nowBundle = AevonOpenBundleOf(request);
        if ([mineBundle isKindOfClass:[NSString class]] &&
            [nowBundle isKindOfClass:[NSString class]] &&
            [(NSString *)mineBundle isEqualToString:(NSString *)nowBundle]) {
            adopted = 1;
        }
    }
    if (passThrough) {
        verdict = 0;
        why = "fwd";
        id pb = AevonOpenBundleOf(request);
        snprintf(line, sizeof(line), "notify: forward pass b=%s op=%s",
                 [pb isKindOfClass:[NSString class]] ? [pb UTF8String] : "-",
                 slot >= 0 ? AevonOpenTargets[slot].tag : "?");
        AevonLogRaw(line);
        line[0] = '\0';
    } else if (adopted) {
        // 认领一次就失效：2 秒窗口留给「打开请求的后续几条」，不留到下一次点击。
        AevonOpenForwardAt = 0;
        AevonOpenForwardMark = nil;
        verdict = 0;
        why = "adopt";
        id pb = AevonOpenBundleOf(request);
        snprintf(line, sizeof(line), "notify: forward adopt b=%s op=%s",
                 [pb isKindOfClass:[NSString class]] ? [pb UTF8String] : "-",
                 slot >= 0 ? AevonOpenTargets[slot].tag : "?");
        AevonLogRaw(line);
        line[0] = '\0';
    } else if (slot >= 0 && AevonOpenOrig[slot] != NULL) {
        @try {
            verdict = AevonOpenDecide(request, options, settings,
                                      bundle, sizeof(bundle), &why);
        } @catch (NSException *exception) {
            verdict = 0;
            why = "threw";
        }
    }

    // 0.2.87 — **停用形状转储。它已经把该答的都答完了，而它问错了对象。**
    //
    // Aevon(219) 的读数（0.2.86 唯一一次真机产出）：
    //   shape: req cls=__NSCFString n=39 super=NSMutableString
    //   shape: req probe … identifier=str:com.tencent.mqq
    //   shape: payload url=#NSURL len=-1
    //   shape: actions none
    //
    // 这两行把结论钉死了：这条路上 `request` 参数是**一个 bundle id 字符串**，
    // 不是 `FBSOpenApplicationRequest` 对象 —— 所以对着它摊 14 个 URL 家族名字
    // 必然全空，那不是「探针口径不对」，是**对象挑错了**。真正带 URL 的只有
    // `options[@"__PayloadURL"]`，而它是一个裸 NSURL，没有伴随任何 BSAction。
    //
    // 再加上母版核对（`setActions:` 与 `_openURLCore` 在 Stheno.dylib 均 0 命中），
    // 「自建 scene 带 URL」整条线关闭。留 42×4 行方法表在热路径上没有意义。
    //
    // 函数本体保留：换一个对象（例如 `FBSystemService` 的 options）它还能用。
    // 启用前先把第一个参数换成真正的 options 字典，别再把 bundle id 递进去。

    if (verdict == 1) {
        AevonDivertCount += 1;
        // 0.2.77 — 连击账本。只记「真的分走了」的那些。
        AevonLoopNote(bundle);
        // `unlock=1` 表示这一拍 SpringBoard 还带着「要不要顺手解锁」的意图。
        // 照样分流，但把它记下来：锁屏点通知若出现「卡片没起来、看门狗补调了
        // 原实现」，这一位就是解释 —— 解锁那一步在卡片这条路上没人做。
        snprintf(line, sizeof(line), "notify: divert b=%s op=%s why=%s unlock=%d n=%d",
                 bundle, slot >= 0 ? AevonOpenTargets[slot].tag : "?", why,
                 AevonOpenHasKey(options, @"__UnlockDevice") ? 1 : 0,
                 AevonDivertCount);
    } else if (verdict == 2) {
        // 吞掉，也不再开卡片。结果块照样要收尾，否则这一次调用会悬着。
        //
        // 0.2.1 — `why` 也打出来：`chain` 是同一次点击的第二条，`syschain` 是
        // SpringBoard 接着我们那条链派生出来、还带着 payload 的那一条（它不再被
        // 当成分享，也不再被放过去全屏打开）。
        const char *chainShape = "none";
        AevonOpenFinishResult(result, &chainShape);
        snprintf(line, sizeof(line), "notify: divert chain b=%s op=%s why=%s result=%s", bundle,
                 slot >= 0 ? AevonOpenTargets[slot].tag : "?", why, chainShape);
    } else if (slot >= 0) {
        AevonOpenSnapshot(slot, request, options, settings, origin, line, sizeof(line));
    }

    // 0.2.12 — 原来这里每拍打一组 `win: act dump`。0.2.9 的形状转储已被证明没有
    // 信息量（四个 tag 全是 `n=1 _settings=0x1`），整块删掉；现在只留一个「一次开机
    // 一遍」的名字表，见 `AevonActSettingNames`。
    AevonActSettingNames(settings);

    if (verdict == 1) {
        // 不转发。SpringBoard 那一段（建 app layout、全屏推前台）整段跳过，改由
        // 卡片那条路自己拉起来。`AevonOpenFromNotification` 自己会切到主队列。
        NSString *target = [NSString stringWithUTF8String:bundle];
        if (target.length > 2) {
            // 结果块：认得出形状就当场收尾 —— 悬着的事务会让 SpringBoard 以为
            // 还在开 App。
            //
            // 0.2.1 — 这里原来还要留一个 `replay`（同形状空块）给 2.5 秒重放用。
            // 重放整段删掉之后它没有消费者了：收尾只用原始块一次。
            char form = AevonOpenResultShape(result);
            const char *shape = "none";
            if (form != 0) {
                AevonOpenFinishResult(result, &shape);
            }
            size_t used = strlen(line);
            if (used + 16 < sizeof(line)) {
                snprintf(line + used, sizeof(line) - used, " result=%s", shape);
            }
            // 0.1.95：分享带 payload ⇒ 先把这条请求按「挂起启动」交回系统，让它把
            // 文件/URL 交给目标 App；卡片照旧由下面那条路建。
            //
            // 0.1.95：分享带 payload ⇒ 这条请求要交回系统，让它把文件/URL 交给
            // 目标 App；卡片照旧由下面那条路建。
            //
            // 0.2.14 — 交回的**时机**挪到卡片之后（`AevonForwardHold`）。0.1.95
            // 那句「顺序不能反过来」是针对老路的：那时卡片靠裸的挂起启动拉进程，
            // 先交回系统就丢了 launch options。现在自建 scene 自己起进程
            // （launchIntent=4），payload 晚到变成「运行中的 App 收到一次 open URL」，
            // 而那正是 Aevon(183) 里成功的两次。
            int forwarded = 0;
            // 0.2.48 — 链接 / 登录授权与分享共用「先建卡、再把 URL 投进 App」这条
            // 链；区别只在失败时的收尾：分享就地销毁，链接退回系统全屏。
            // 0.2.58 — `incard`（卡里那个 App 自己发起的授权 / 深链回调）走同一条
            // 投递链：建卡这一步会被 `openCard` 认成「已经在卡里」，实际只做投递。
            // 0.2.87 — **`safari` / `oauth` 两个值已不再产生。**
            //
            // 这两族在 0.2.87 一并轨母版（`return 1` → 放行 + `AevonAuthSwapSchedule`），
            // `why` 改报 `safaripass` / `linkpass`，所以这个判据里只剩 `incard`
            // 还活着 —— 那是「App 已经在我们的卡里、又收到一条自己的回调 URL」，
            // 目标根本不用被激活，投进同一张卡才是对的。
            // 两个旧值留在字符串里只为让历史日志还能对得上，别再往这里加新路径。
            int linkKind = (strcmp(why, "safari") == 0 || strcmp(why, "oauth") == 0 ||
                            strcmp(why, "incard") == 0);
            if ((strcmp(why, "share") == 0 || linkKind) &&
                AevonOpenCarriesPayload(request, options)) {
                // 不在这里发。先让 `AevonOpenFromNotification` 把卡片的 process +
                // scene 建起来，再把这个请求投回去。超时 1.6 秒兜底。
                forwarded = AevonForwardHold(slot, self, _cmd, request, options,
                                             settings, origin, form,
                                             [NSString stringWithUTF8String:bundle],
                                             linkKind ? 1 : 0);
                size_t at = strlen(line);
                if (at + 12 < sizeof(line)) {
                    snprintf(line + at, sizeof(line) - at, " fwd=%d", forwarded);
                }
                if (forwarded == 1) {
                    // 0.2.18 — 这一行原来是同步的 `AevonForwardHoldWatch(1.6)`，
                    // 而它的第一句就是「投递不忙 ⇒ 立刻 flush」。Aevon(189) 把它拍死了：
                    //
                    //   notify: forward held slot=1 form=@
                    //   notify: forward flush why=timeout after=0ms     ← 0 毫秒
                    //   notify: forward pass b=com.tencent.mqq op=user   ← SB 全屏、背景黑
                    //
                    // 卡片要 100 ms 之后才把 scene 贴上、才调 `AevonForwardDeliver`，
                    // 所以这一拍永远读到「不忙」，0.2.17 的「等投递结论」整段被跳过。
                    // 首拍必须排到卡片之后：1.0 秒。之后由 `AevonForwardHoldWatch`
                    // 自己每 0.5 秒续拍。
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(1.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        AevonForwardHoldWatch(1.0);
                    });
                }
            }
            if (strcmp(why, "oauth") == 0) {
                // ⛔ 0.2.87 — **这一段已经是死代码，保留只为对照。**
                //
                // `why=oauth` 由「普通深链」那一支赋值，而那一支在 0.2.87 改成
                // 放行（`why=linkpass` + `return 0`），所以这里不会再进。
                // 它记录的 0.2.74~0.2.78 那段推理也一并作废：
                //
                // 0.2.74 — 授权 / 支付：**不按 Home、不切前台**，直接建卡。
                //
                // `AevonOpenFromNotification` 走的是 `openFromNotification`，它带
                // home-first：目标在屏上时先按一次 Home 再建卡。授权这条路上
                // 「在屏上」的是发起授权的 App，那一下 Home 正好把用户送回桌面 ——
                // 用户要的「全程保持发起方全屏、不回桌面」就是被这一句破坏的。
                // `AevonOpenCardDirect` 跳过 home-first，卡片自建 scene；发起方
                // 的 scene 我们一个字节都不碰，它继续占着整屏。
                //
                // 0.2.77 — **卡在路上就别再建一次。**
                //
                // Aevon(211) 11:58:28 同一条授权来了两拍（`pay=payload` 与
                // `pay=url`），两拍都走到这里，于是同一个 scene 上建了两次
                // presenter：
                //
                //   win: presenter threw Cannot create a presenter with this
                //        identifier as it's already in use. on com.aevon.float
                //   win: no presenter
                //
                // 第二张卡既没窗也不收尾，而那一下是在 SpringBoard 主线程上抛的
                // 异常。「已经在路上」这件事 `AevonCardIsComingFor` 答得出来，
                // 它本来就是为这一格加的（0.1.91）。
                if (AevonCardIsComingFor(bundle) == 1) {
                    AevonLogRaw([[NSString stringWithFormat:
                                  @"notify: oauth card skip b=%s why=coming", bundle]
                                 UTF8String]);
                } else {
                    AevonLogRaw([[NSString stringWithFormat:
                                  @"notify: oauth card b=%s fwd=%d", bundle, forwarded]
                                 UTF8String]);
                    AevonOpenCardDirect(bundle);
                }
            } else {
                AevonOpenFromNotification(bundle);
            }
            // 0.1.89：这次没转发，SpringBoard 就没有机会去收面板 / 收横幅 —— 那两件
            // 事本来挂在它的收尾里。自己补上。
            // 0.1.90：横幅在这里收，面板不在这里收 —— 面板要等卡片，见
            // `AevonCleanCoverAfterCard`。字符串必须自己复制一份带进块里。
            // 0.1.91：0.45 秒压到 0.10 秒，并且先记下手指这一刻（`at=` 的零点）。
            //
            // 0.1.92：这两件（收面板/收横幅）与清通知**只属于通知那条路**。分享面板
            // 没有面板要收、没有横幅要撤、更没有「这一条已读」这回事 —— 对它照跑一遍
            // 只会去碰不相干的对象。所以按 `why` 分开，而不是把两件事都堆在分流里。
            //
            // 0.1.95：`fwd=1` 表示这条请求已经带着 payload 交回系统（挂起启动），
            // 文件应该会到；`fwd=0` 表示没能交回去，目标 App 只会拿到一张空卡。
            if (strcmp(why, "share") == 0) {
                const char *srcRaw = [AevonOpenSourceApp(request, options) UTF8String];
                AevonLogRaw([[NSString stringWithFormat:@"notify: share b=%@ src=%s pay=%s fwd=%d n=%d",
                              target, srcRaw != NULL ? srcRaw : "-",
                              AevonOpenPayloadKind(request, options), forwarded,
                              AevonDivertCount]
                             UTF8String]);
                // 0.2.7 — 分享现场行（独立配额 12，不受快照那 32 拍影响）。
                AevonOpenShareNote(request, options, settings, form, forwarded);
            } else if (linkKind) {
                // 0.2.48 — 链接 / 登录授权没有面板要收、没有横幅要撤、也没有
                // 「这一条已读」；走通知那套收尾只会去碰不相干的对象。
                AevonLogRaw([[NSString stringWithFormat:
                              @"notify: link card b=%@ kind=%s fwd=%d n=%d",
                              target, why, forwarded, AevonDivertCount] UTF8String]);
            } else {
                // 0.1.99 — 先取证结构（哪一跳断），再按老路取标识。两件事都只读。
                AevonClearProbe(request, options);
                // 0.1.92：清掉这一条 —— 「点开 = 已读」。标识在这一拍就取好（只读几个
                // getter），真正动手排到 0.60 秒之后，见 `AevonClearNotification`。
                //
                // 0.2.5 — 排队条件从「取到标识」改成「取到标识 **或** 截到了对象」。
                // 真机 6/6 是 `clear=noid`，而排队只在取到标识时才发生 ⇒ 清通知那整段
                // 一次都没跑过。截对象那条路不需要标识，所以它必须能单独把这一拍排上。
                NSString *clear = AevonClearIdentifier(request, options);
                BOOL haveId = clear.length > 3;
                BOOL canCapture = AevonCaptureFresh();
                if (haveId || canCapture) {
                    AevonClearLater(bundle, haveId ? clear : nil);
                    if (!haveId && AevonDivertNotes < 6) {
                        AevonDivertNotes += 1;
                        AevonLogRaw([[NSString stringWithFormat:
                                      @"notify: clear b=%@ via=capture only", target] UTF8String]);
                    }
                } else if (AevonDivertNotes < 6) {
                    AevonDivertNotes += 1;
                    AevonLogRaw([[NSString stringWithFormat:@"notify: clear b=%@ clear=noid",
                                  target] UTF8String]);
                }
                AevonCleanTap = CFAbsoluteTimeGetCurrent();
                char *cleanBundle = strdup(bundle);
                if (cleanBundle != NULL) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(AEVON_CLEAN_DELAY * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        AevonNotifyCleanup(cleanBundle);
                        free(cleanBundle);
                    });
                }
            }
            // 0.2.1 — 这里原来是 `AevonOpenWatch(...)`：吞掉 2.5 秒后查一次卡片在不在，
            // 不在就把原实现补调一次。
            //
            // Aevon(169) 证明那条路会**自己喂自己**：补调一次原实现 ⇒ 原实现再走一遍
            // `_handleOpenApplicationRequest:` ⇒ 那条也在接管里 ⇒ 又分流、又建卡、
            // 又失败 ⇒ 又补调。13 次 op=trusted、23 次 replay、10 次全屏兜底，每次兜底
            // 都是 10 秒整的同步 XPC，主线程在 2 分 07 秒里累计停了 100 秒 —— 就是用户
            // 说的「整机卡死，只能等它自己恢复」。母版 Stheno 没有这条：它只在
            // 「失败/排除表命中」时回落一次全屏，不回灌原实现。整段删除。
        }
    } else if (verdict == 0) {
        // 0.1.99 — 放行之前先把「哪一条、为什么、带没带东西」落下来。
        //
        // 这一段是**纯只读**的：只调几个返回对象的 getter（`AevonOpenSourceApp` /
        // `AevonOpenPayloadKind` 内部全部包了 @try）。它必须写在调原实现**之前** ——
        // 原实现一旦拉起 App，后面这一行还要不要打就已经不重要了；而且万一原实现
        // 抛异常，写在后面就永远看不到这行。
        if (slot >= 0 && AevonPassNotes < 40) {
            AevonPassNotes += 1;
            const char *passSrc = [AevonOpenSourceApp(request, options) UTF8String];
            char passBuf[320];
            snprintf(passBuf, sizeof(passBuf),
                     "notify: pass b=%s op=%s why=%s src=%s pay=%s n=%d",
                     bundle[0] != '\0' ? bundle : "-",
                     AevonOpenTargets[slot].tag, why,
                     passSrc != NULL ? passSrc : "-",
                     AevonOpenPayloadKind(request, options), AevonPassNotes);
            char *passCopy = strdup(passBuf);
            if (passCopy != NULL) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    AevonLogRaw(passCopy);
                    free(passCopy);
                });
            }
        }
        IMP original = slot >= 0 ? AevonOpenOrig[slot] : NULL;
        if (original != NULL) {
            ((void (*)(id, SEL, id, id, id, id, id))original)
                (self, _cmd, request, options, settings, origin, result);
        }
        // 「认出来了但没分流」才是需要解释的：开关、上限、取不到目标。
        // `plain`/`nobundle` 是常态（点图标、分享面板），一行都不写。
        //
        // 0.2.7 — 这里原来与通知那两行共用 `AevonDivertNotes < 6`。通知路径每次
        // 点击都会写一到两行，六条预算在第三次点击之后就用光了 —— 之后任何一次
        // 「认出来了却没分流」在日志里都是静默的。分享这条路正是这么丢掉现场的：
        // Aevon(175) 整份日志一条 `notify: pass` 都没有，不是因为没发生，
        // 是因为配额早被通知吃了。两条各自独立计数。
        if (strcmp(why, "plain") != 0 && strcmp(why, "nobundle") != 0 &&
            AevonPassDivertNotes < 20 && line[0] == '\0') {
            AevonPassDivertNotes += 1;
            snprintf(line, sizeof(line), "notify: divert pass b=%s why=%s n=%d",
                     bundle, why, AevonPassDivertNotes);
        }
    }

    if (line[0] != '\0') {
        char *copy = strdup(line);
        if (copy != NULL) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AevonLogRaw(copy);
                free(copy);
            });
        }
    }
}

/// 装配。由 `ActivateProbe.arm()`（`Sources/Scene/ActivateProbe.swift`）在装载后
/// 3 秒调用一次，且只在它的闩放行之后。
///
/// 四道闸按「最便宜且最能提前止损」的顺序排：方法在不在 → 编码是否逐字节等于
/// 真机普查到的那个 → 是不是 SBMainWorkspace 自己实现的 → 拿不拿得到原实现。
/// 任何一道不过都只写一行日志，一次 `method_setImplementation` 都不做。
/// 0.2.7 — 三家综合要用到的能力面，一次开机问一遍。**只问，一个都不调。**
///
/// 这一版不靠猜：`respondsToSelector:` 与 `objc_getClass` 是免费的，问错也不会有
/// 副作用；而「有这个能力」是下一版能不能接线的唯一前提。四项分别对应三家：
///
///   · Myrtle 1.5.0 —— 它和我们的路线最像（`launchApplicationWithIdentifier:suspended:`
///     + 自建窗口 + rehost）。它比我们多的那一件是 `forceBackgrounded:forApp:`：
///     目标 App 已经在后台跑着的时候，**把它的前台身份按回去**，这样原实现被调
///     也不会让屏幕上多出一个全屏。Aevon(173) 里 QQ 分享正是「卡片建了、另一个
///     宿主也在前台」的形态。系统侧承这个动作的通常是 `SBApplicationController`
///     或 `SBApplication` 自己，两个都问。
///   · 母版 Stheno —— `_setDeactivationReasons:onScene:withSettings:reason:`
///     是它改 scene 前后台的第二道门（我们只装了 `_scene:interceptUpdateWithNewSettings:`）。
///   · TrollOpen 1.5.2 —— `SBTransientOverlayWindow` 类与
///     `createSceneWithDefinition:initialParameters:`：那是「App 不自己出 scene」的
///     唯一根治手段（本版不碰，先确认这两样在 iOS 17.3.1 上还在不在）。
///   · Mango Beta8 —— `retryMountBacking:bundleID:retries:` 是它自己的方法名，
///     系统侧没有，所以这里不列；它的思想（判内容、带 retries）已经落到代码里。
static int AevonClassHasMethod(Class cls, const char *name) {
    if (cls == Nil || name == NULL) return -1;   // -1 = 类都不在
    return [cls instancesRespondToSelector:sel_registerName(name)] ? 1 : 0;
}

static void AevonAbilityProbe(void) {
    @try {
        Class appCls = objc_getClass("SBApplication");
        Class ctrlCls = objc_getClass("SBApplicationController");
        Class mgrCls = objc_getClass("SBSceneManager");
        Class mainMgr = objc_getClass("SBMainDisplaySceneManager");
        Class hostCls = objc_getClass("SBTransientOverlayWindow");
        Class txnCls = objc_getClass("FBApplicationProcessLaunchTransaction");
        Class wsCls = objc_getClass("SBMainWorkspace");
        Class sbwsCls = objc_getClass("SBWorkspace");
        Class setCls = objc_getClass("SBActivationSettings");
        Class fbMgrCls = objc_getClass("FBSceneManager");
        Class fluidCls = objc_getClass("SBFluidSwitcherViewController");
        Class coordCls = objc_getClass("SBMainSwitcherControllerCoordinator");

        AevonActApiCensus();

        AevonLogRaw([[NSString stringWithFormat:
                      @"win: ability app forceBg=%d ctrl forceBg=%d app dehost=%d ctrl dehost=%d",
                      AevonClassHasMethod(appCls, "forceBackgrounded:forApp:"),
                      AevonClassHasMethod(ctrlCls, "forceBackgrounded:forApp:"),
                      AevonClassHasMethod(appCls, "dehost"),
                      AevonClassHasMethod(ctrlCls, "dehost")] UTF8String]);
        // 0.2.12 — `openurl=` 这一栏原来是 0，一直看着像「这条路不存在」。Aevon(181)
        // 的全类扫给了答案：`_openURLCore:display:animating:activationSettings:origin:withResult:`
        // 只在类 **`SpringBoard`** 上（`i{v60@0:8@16@24B32@36@44@?52}`），SBMainWorkspace
        // 上没有。所以这一栏改成两个数：`openurl=<mainws>/<springboard>`。
        Class sbAppCls = objc_getClass("SpringBoard");
        AevonLogRaw([[NSString stringWithFormat:
                      @"win: ability scene deact=%d/%d overlay=%d txn=%d openurl=%d/%d",
                      AevonClassHasMethod(mgrCls, "_setDeactivationReasons:onScene:withSettings:reason:"),
                      AevonClassHasMethod(mainMgr, "_setDeactivationReasons:onScene:withSettings:reason:"),
                      hostCls != Nil ? 1 : 0,
                      txnCls != Nil ? 1 : 0,
                      AevonClassHasMethod(wsCls,
                          "_openURLCore:display:animating:activationSettings:origin:withResult:"),
                      AevonClassHasMethod(sbAppCls,
                          "_openURLCore:display:animating:activationSettings:origin:withResult:")]
                     UTF8String]);
        // 0.2.9 — 「把一个已经在跑的 App 按回后台 / 让它不前台激活」这一族到底有哪些手段。
        // 全部只问不调（-1 = 类不在，0 = 类在方法不在，1 = 可调）。0.2.8 的
        // `forceBg=0/0` 已经证明「选择子在 __objc_selrefs 里 ≠ 这一版真能调」，
        // 所以下一版接线之前，必须先把这张表拿到手。
        AevonLogRaw([[NSString stringWithFormat:
                      @"win: ability bg app=%d ctrl=%d mainws=%d sbws=%d set=%d susp=%d fg=%d",
                      AevonClassHasMethod(appCls, "setBackgrounded:"),
                      AevonClassHasMethod(ctrlCls, "setBackgrounded:"),
                      AevonClassHasMethod(wsCls, "setBackgrounded:"),
                      AevonClassHasMethod(sbwsCls, "setBackgrounded:"),
                      AevonClassHasMethod(setCls, "setBackgrounded:"),
                      AevonClassHasMethod(setCls, "setActivateSuspended:"),
                      AevonClassHasMethod(appCls, "setForeground:foregroundvalue:with169type:")]
                     UTF8String]);
        AevonLogRaw([[NSString stringWithFormat:
                      @"win: ability deact2 sbws=%d fbmgr=%d fluid=%d coord=%d",
                      AevonClassHasMethod(sbwsCls, "_setDeactivationReasons:onScene:withSettings:reason:"),
                      AevonClassHasMethod(fbMgrCls, "_setDeactivationReasons:onScene:withSettings:reason:"),
                      AevonClassHasMethod(fluidCls, "_setDeactivationReasons:onScene:withSettings:reason:"),
                      AevonClassHasMethod(coordCls, "_setDeactivationReasons:onScene:withSettings:reason:")]
                     UTF8String]);
    } @catch (NSException *exception) {
        AevonLogRaw("win: ability probe threw");
    }
}

void AevonActivateProbeInstall(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    Class cls = objc_getClass("SBMainWorkspace");
    if (cls == Nil) {
        AevonLogRaw("notify: open absent reason=no-class");
        return;
    }

    unsigned int count = 0;
    Method *own = class_copyMethodList(cls, &count);
    NSMutableString *skip = [NSMutableString string];
    int armed = 0;
    for (int i = 0; i < AevonOpenMax; i++) {
        const char *tag = AevonOpenTargets[i].tag;
        SEL sel = sel_registerName(AevonOpenTargets[i].sel);
        Method method = class_getInstanceMethod(cls, sel);
        if (method == NULL) {
            [skip appendFormat:@"%s=absent ", tag];
            continue;
        }
        const char *encoding = method_getTypeEncoding(method);
        if (encoding == NULL || strcmp(encoding, AEVON_OPEN_SHAPE) != 0) {
            [skip appendFormat:@"%s=shape(%s) ", tag, encoding != NULL ? encoding : "?"];
            continue;
        }
        BOOL owns = NO;
        for (unsigned int k = 0; own != NULL && k < count; k++) {
            if (method_getName(own[k]) == sel) { owns = YES; break; }
        }
        if (!owns) {
            [skip appendFormat:@"%s=inherited ", tag];
            continue;
        }
        IMP original = method_getImplementation(method);
        if (original == NULL) {
            [skip appendFormat:@"%s=no-orig ", tag];
            continue;
        }
        AevonOpenOrig[i] = original;
        AevonOpenSel[i] = sel;
        method_setImplementation(method, (IMP)AevonOpenHit);
        armed += 1;
    }
    free(own);

    AevonLogRaw([[NSString stringWithFormat:@"notify: open armed n=%d/%d shape=%s skip=%@",
                  armed, AevonOpenMax, AEVON_OPEN_SHAPE,
                  skip.length > 0 ? skip : @"-"] UTF8String]);
    // 0.2.7 — 能力面（三家综合的前提）。只问不调，见函数上方那段。
    AevonAbilityProbe();
}

// MARK: - 0.1.86 激活面普查（只读，一次装机能答完）
//
// 0.1.85 的真机答案（Aevon(153)，19:15:21）是一行：
//
//   notify: activate absent reason=no-method
//   notify: SBMainWorkspace~activate n=5 systemService:canActivateApplication:withResult:
//          _keyboardActivate _keyboardActivateEventDown: accessibilityActivate
//          setAccessibilityActivateBlock:
//
// 这五行里没有一条是「拿 bundle id 去激活一个 App」。也就是说母本那个
// `_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:`
// **在这台机器的 SpringBoard 里不存在** —— 不是「没挂上」，是名字不对。
//
// 但 0.1.85 那次列名本身就有个洞：`strcasestr(sel, "activate")` 匹配不到
// `activation`（`activate` 的第七个字符是 `e`，`activation` 那里是 `i`）。
// 凡是叫 `...ApplicationActivation...` 的方法，那一版全都看不见。所以「这台
// 机器没有激活入口」这个结论还不能下 —— 只能说「没有叫 activate 的」。
//
// 这一版把网撒对：
//   · 需词从 `activate` 改成 `activ`（同时覆盖 activate / activation / deactivate）；
//   · 加 `applic` / `launch` 两路，因为激活入口也可能根本不叫 activ*；
//   · **带参数编码**。下一版换 IMP 时要靠它对齐参数个数与类型 —— 0.1.85 的
//     闸二就是在赌这个形状，这次直接量出来。
//   · 全局扫一遍（不限类名）：任何类上同时含 `activ` 与（`bundl`|`applic`）的
//     选择子，以及 `openurl` / `openapplication` / `launchapplication`。母本的
//     正解如果换了宿主类，这一行会把它露出来。
//
// 全部只读：`class_copyMethodList` + `method_getTypeEncoding`，没有一次
// `method_setImplementation`，没有一次 `objc_msgSend` 到系统对象上。跑在全局
// 队列（低优先级），不占 SpringBoard 主线程一拍。

/// 普查的总行数预算。一次装机的证据够用就行；真超了说明关键词选宽了，
/// 那是下一版要收窄的信号，不是把日志撑大。
static int AevonSurfLines = 0;

static void AevonSurfEmit(NSString *line) {
    if (AevonSurfLines >= 46) return;
    AevonSurfLines += 1;
    AevonLogRaw(line.UTF8String);
}

/// 这些类在不在。一行答完 —— 「类不存在」与「类在但方法改了名」是两条
/// 完全不同的下一步，混在一行里会读错。
static void AevonSurfExists(void) {
    static const char *names[] = {
        "SBMainWorkspace", "SBWorkspace", "SBApplicationController",
        "SBLockScreenManager", "SBUIController", "SBSceneManagerCoordinator",
        "SBNCNotificationDispatcher", "SBDashBoardNotificationPresenter",
        "SBUserNotificationCenter", "SBNotificationBannerDestination",
        "NCNotificationDispatcher", "NCNotificationShortLookViewController",
        "NCNotificationLongLookViewController", "NCNotificationRequest",
        "NCNotificationListViewController", "SBLockScreenNotificationListController",
        "SBActivationSettings", "UNSUserNotificationServer"
    };
    NSMutableString *buf = [NSMutableString string];
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class cls = objc_getClass(names[i]);
        [buf appendFormat:@"%s=%d ", names[i], cls != Nil ? 1 : 0];
    }
    AevonSurfEmit([NSString stringWithFormat:@"surf: exists %@", buf]);
}

/// 类族链。一个类的真身常常在父类上（`SBNCNotificationDispatcher` 就是这种），
/// 所以「本类没有这个方法」不等于「这个家族没有」——下一版要不要换宿主类，
/// 全靠这一行。
static void AevonSurfChain(const char *className) {
    Class cls = objc_getClass(className);
    if (cls == Nil) return;
    NSMutableString *buf = [NSMutableString stringWithFormat:@"%s", className];
    Class walk = class_getSuperclass(cls);
    int depth = 0;
    while (walk != Nil && depth < 4) {
        const char *name = class_getName(walk);
        [buf appendFormat:@" > %s", name != NULL ? name : "?"];
        walk = class_getSuperclass(walk);
        depth += 1;
    }
    AevonSurfEmit([NSString stringWithFormat:@"surf: chain %@", buf]);
}

/// 列某个类自己的方法（只本类，不含父类）。`withSig` 时把参数编码一起带上。
///
/// 只本类是有意的：`class_getInstanceMethod` 会沿父类链找，而下一版要换 IMP 的
/// 那一条必须由目标类自己实现，否则改的是父类、连坐所有子类。
static void AevonSurfClass(const char *className, const char *needle,
                           int cap, BOOL withSig) {
    Class cls = objc_getClass(className);
    if (cls == Nil) return;   // `surf: exists` 已经答过，这里不再重复
    unsigned int total = 0;
    Method *list = class_copyMethodList(cls, &total);
    if (list == NULL) return;
    NSMutableString *buf = [NSMutableString string];
    int hits = 0;
    for (unsigned int i = 0; i < total && hits < cap; i++) {
        const char *sel = sel_getName(method_getName(list[i]));
        if (sel == NULL || strcasestr(sel, needle) == NULL) continue;
        if (withSig) {
            const char *enc = method_getTypeEncoding(list[i]);
            [buf appendFormat:@"%s{%s} ", sel, enc != NULL ? enc : "?"];
        } else {
            [buf appendFormat:@"%s ", sel];
        }
        hits += 1;
    }
    free(list);
    if (hits == 0) return;
    AevonSurfEmit([NSString stringWithFormat:@"surf: %s~%s n=%d/%u %@",
                   className, needle, hits, total, buf]);
}

/// 全局扫：不限类名。命中条件写死两条，因为这两条正好对应「通知点击最终要
/// 走的那一步」——(1) 拿 bundle/app 去激活，(2) 拿 URL 去打开。
static void AevonSurfGlobal(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) {
        AevonLogRaw("surf: global unavailable");
        return;
    }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (list == NULL) return;
    total = objc_getClassList(list, total);
    NSMutableString *buf = [NSMutableString string];
    int hits = 0;
    for (int i = 0; i < total && hits < 60; i++) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(list[i], &count);
        if (methods == NULL) continue;
        const char *cls = class_getName(list[i]);
        for (unsigned int j = 0; j < count && hits < 60; j++) {
            const char *sel = sel_getName(method_getName(methods[j]));
            if (sel == NULL || cls == NULL) continue;
            BOOL activates = (strcasestr(sel, "activ") != NULL) &&
                             (strcasestr(sel, "bundl") != NULL ||
                              strcasestr(sel, "applic") != NULL);
            BOOL opens = strcasestr(sel, "openurl") != NULL ||
                         strcasestr(sel, "openapplication") != NULL ||
                         strcasestr(sel, "openrequest") != NULL ||
                         strcasestr(sel, "launchapplication") != NULL;
            if (!activates && !opens) continue;
            [buf appendFormat:@"%s.%s ", cls, sel];
            hits += 1;
            if (buf.length > 1100) {
                AevonSurfEmit([NSString stringWithFormat:@"surf: g n=%d %@", hits, buf]);
                [buf setString:@""];
            }
        }
        free(methods);
    }
    free(list);
    if (buf.length > 0) {
        AevonSurfEmit([NSString stringWithFormat:@"surf: g tail n=%d %@", hits, buf]);
    }
    if (hits == 0) AevonLogRaw("surf: g n=0 (no bundle/url activation selector anywhere)");
}

// MARK: - 0.2.10 自建 scene 的能力面（只读，一次）

//
// 为什么要有这一段：Aevon(179) 把两条路放进同一份日志，同机对照是硬的 ——
// 通知那条路**不转发**，卡片 `keepalive fg=yes` 却不出全屏；分享那条路**转发**，
// 同样 `fg=yes`，出全屏。所以全屏的来源是那次转发（它让主 workspace 把目标 App
// 摆成前台 App，而 scene 正在我们卡里 ⇒ 全屏层是空的，看着就是黑屏），
// **不是**「scene 被激活成前台」。用户据此定档：走 TrollOpen 那条「自建 scene」。
//
// 那一条的调用面极大（0.0.15 / 0.0.16 两次安全模式都出在这条线的裸调上），
// 所以本版只做一件事：把**这个名字面在真机进程里到底存不存在**问清楚，
// 一个对象都不建、一次 `objc_msgSend` 都不发。
//
// 三个问题分开答，因为它们导致三种不同的下一步：
//   ① 类在不在（`scn exists`）—— 不在就是这条路在本进程不可用，得换宿主进程；
//   ② 名字到底叫什么（`scn names`）—— 真 API 名靠 census 不靠 strings，
//      0.2.8 的 `forceBg=0/0` 就是这么翻掉的；
//   ③ 关键选择子落在哪个类、签名什么形状（`scn sel`）—— 下一步要换 IMP 的那一条
//      必须由目标类自己实现，形状不对就是第三次安全模式。
//
// 全部 `class_copyMethodList` / `class_getInstanceMethod` / `method_getTypeEncoding`，
// 没有 `method_setImplementation`、没有 `objc_msgSend`。跑在低优先级全局队列。

/// 独立预算。不能和 `AevonSurfLines` 共用：那边 46 行早被通知那一半用完了，
/// 共用就是「先跑完的静音另一个」—— 0.1.93 六条配额用尽那次就是这么来的。
static int AevonScnLines = 0;

static void AevonScnEmit(NSString *line) {
    if (AevonScnLines >= 46) return;
    AevonScnLines += 1;
    AevonLogRaw(line.UTF8String);
}

/// 这条线上要点名的类。前一半是「自建一个 scene 需要的那套件」，
/// 后一半是「SpringBoard 里现成的场景管理器」—— 两者缺一，路就走不成。
static const char *AevonScnClassNames[] = {
    "FBSMutableSceneDefinition", "FBSSceneDefinition", "FBSSceneIdentity",
    "FBSceneManager", "FBScene", "FBSDisplayConfiguration", "FBSDisplayIdentity",
    "FBProcessManager", "FBSSceneSpecification", "UIApplicationSceneSpecification",
    "SBSceneManagerCoordinator", "SBSceneManager", "SBMainDisplaySceneManager",
    "SBTransientOverlayPresentationManager", "SBTransientOverlayViewController",
    "SBTransientOverlayWindow", "SBDeviceApplicationSceneHandle",
    "SBApplicationSceneHandle", "UIApplicationSceneHandle", "_UIScenePresenter",
    "SBMainWorkspace", "SBWorkspace", "UIWindowScene",
};

#define AEVON_SCN_CLASS_COUNT (sizeof(AevonScnClassNames) / sizeof(AevonScnClassNames[0]))

/// ① 类在不在。拆两行是因为一行二十三个名字会到五百多字节，读的人要滚屏。
static void AevonScnExists(void) {
    NSMutableString *buf = [NSMutableString string];
    for (size_t i = 0; i < AEVON_SCN_CLASS_COUNT; i++) {
        if (i == 12) {
            AevonScnEmit([NSString stringWithFormat:@"surf: scn exists a %@", buf]);
            [buf setString:@""];
        }
        Class cls = objc_getClass(AevonScnClassNames[i]);
        [buf appendFormat:@"%s=%d ", AevonScnClassNames[i], cls != Nil ? 1 : 0];
    }
    AevonScnEmit([NSString stringWithFormat:@"surf: scn exists b %@", buf]);
}

/// ② 名字到底叫什么。全类名扫一遍，命中关键词就列出来 —— 这是唯一不靠猜的
/// 取名方式。关键词选的是「建场景 / 挂覆盖 / 管场景 / 配显示 / 拿凭证」五类。
static void AevonScnNames(void) {
    static const char *keys[] = {
        "SceneDefinition", "SceneSpecification", "TransientOverlay",
        "SceneManager", "DisplayConfiguration", "SceneHandle", "MutableScene",
    };
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) {
        AevonScnEmit(@"surf: scn names unavailable");
        return;
    }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (list == NULL) return;
    total = objc_getClassList(list, total);
    NSMutableString *buf = [NSMutableString string];
    int hits = 0;
    for (int i = 0; i < total && hits < 30; i++) {
        const char *name = class_getName(list[i]);
        if (name == NULL) continue;
        BOOL hit = NO;
        for (size_t k = 0; k < sizeof(keys) / sizeof(keys[0]) && !hit; k++) {
            if (strstr(name, keys[k]) != NULL) hit = YES;
        }
        if (!hit) continue;
        [buf appendFormat:@"%s ", name];
        hits += 1;
        if (hits % 5 == 0) {
            AevonScnEmit([NSString stringWithFormat:@"surf: scn names %d %@", hits, buf]);
            [buf setString:@""];
        }
    }
    if (buf.length > 0) {
        AevonScnEmit([NSString stringWithFormat:@"surf: scn names %d %@", hits, buf]);
    }
    free(list);
    AevonScnEmit([NSString stringWithFormat:@"surf: scn names total=%d", hits]);
}

/// ③ 关键选择子落在哪个类、什么形状。`i=` 是实例方法、`c=` 是类方法，
/// 花括号里是 `method_getTypeEncoding` 的原文 —— 下一步要按它写函数指针。
static void AevonScnSelectors(void) {
    static const char *sels[] = {
        "createSceneWithDefinition:initialParameters:",
        "createRequestWithOptions:displayConfiguration:",
        "sceneWithDefinition:",
        "setSpecification:",
        "setIdentifier:",
        "specification",
        "_openURLCore:display:animating:activationSettings:origin:withResult:",
        "_handleOpenApplicationRequest:options:activationSettings:origin:withResult:",
        "mainDisplaySceneManager",
        "sceneManagerForDisplayIdentifier:",
        "presentedTransientOverlayViewControllers",
        "setFlag:forActivationSetting:",
    };
    int found = 0;
    for (size_t s = 0; s < sizeof(sels) / sizeof(sels[0]); s++) {
        SEL sel = sel_registerName(sels[s]);
        NSMutableString *buf = [NSMutableString string];
        int hits = 0;
        for (size_t c = 0; c < AEVON_SCN_CLASS_COUNT && hits < 4; c++) {
            Class cls = objc_getClass(AevonScnClassNames[c]);
            if (cls == Nil) continue;
            Method inst = class_getInstanceMethod(cls, sel);
            if (inst != NULL) {
                const char *enc = method_getTypeEncoding(inst);
                [buf appendFormat:@"%s i{%s} ", AevonScnClassNames[c], enc != NULL ? enc : "?"];
                hits += 1;
                found += 1;
                continue;
            }
            Method meta = class_getClassMethod(cls, sel);
            if (meta != NULL) {
                const char *enc = method_getTypeEncoding(meta);
                [buf appendFormat:@"%s c{%s} ", AevonScnClassNames[c], enc != NULL ? enc : "?"];
                hits += 1;
                found += 1;
            }
        }
        AevonScnEmit([NSString stringWithFormat:@"surf: scn sel %s n=%d %@",
                      sels[s], hits, hits > 0 ? buf : @"(none)"]);
    }
    AevonScnEmit([NSString stringWithFormat:@"surf: scn sel total=%d", found]);
}

// MARK: - 0.2.11 五个「问不到」的名字，到底在谁身上

//
// 0.2.10 的 `surf: scn sel` 只问了 23 个点名的类，Aevon(180) 里五个名字全答
// `n=0 (none)`：`_openURLCore:display:…`、`sceneWithDefinition:`、`setIdentifier:`、
// `sceneManagerForDisplayIdentifier:`、`presentedTransientOverlayViewControllers`。
//
// 那不是「不存在」，是**问的范围太小**。母版能在同版本系统上跑，它的每条调用点在
// 真机上就必然存在；我们问不到，就是探针的口径漏了 —— 这条纪律已经被同一形状证过
// 两次（零参选择子在 `__TEXT,__const` 里、`clientIdentity` 被大小写过滤掉），
// 这是第三次，所以这次不问「那 23 个类」，问**每一个类**。
//
// 两个问题一起答，因为它们导致两种完全不同的下一步：
//   ① 名字对、宿主不是我们点名的那几个 ⇒ 下一版只换宿主对象，调用面照抄；
//   ② 名字也变了（TrollOpen 那条链在 17.3.1 上可能已经改名）⇒ 按关键词重新取名：
//      同时含 `openurl` 与 `display`/`scene` 的方法名，一个不漏地列出来。
//
// 全部只读：`class_copyMethodList` + `method_getTypeEncoding`，不建对象、不发消息。
// 实例方法与类方法都扫：TrollOpen 的自建链是「建定义 → 建请求 → 建场景」，
// 中间几跳很可能是类方法。

/// 独立预算，理由同 `AevonScnLines`：占别人的行数就是让先跑完的那一半静音另一半。
static int AevonScnHostLines = 0;

static void AevonScnHostEmit(NSString *line) {
    if (AevonScnHostLines >= 44) return;
    AevonScnHostLines += 1;
    AevonLogRaw(line.UTF8String);
}

/// 第三问：**每个类**都有没有这六个名字。每个名字只记前三个宿主 —— 第四个之后
/// 都是子类继承带来的噪声，改 IMP 也永远不该改在继承来的那一条上。
static void AevonScnHosts(void) {
    static const char *sels[] = {
        "_openURLCore:display:animating:activationSettings:origin:withResult:",
        "sceneWithDefinition:",
        "setIdentifier:",
        "sceneManagerForDisplayIdentifier:",
        "presentedTransientOverlayViewControllers",
        "createSceneWithDefinition:initialParameters:",
    };
    const size_t selCount = sizeof(sels) / sizeof(sels[0]);
    SEL targets[8];
    int hitsPer[8] = {0};
    for (size_t s = 0; s < selCount; s++) targets[s] = sel_registerName(sels[s]);

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) {
        AevonScnHostEmit(@"surf: scn host unavailable");
        return;
    }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (list == NULL) return;
    total = objc_getClassList(list, total);
    int totalHits = 0;
    int urlHits = 0;
    for (int i = 0; i < total; i++) {
        Class cls = list[i];
        const char *cname = class_getName(cls);
        if (cname == NULL) continue;
        // pass 0 = 本类实现的实例方法；pass 1 = 元类上的类方法。
        for (int pass = 0; pass < 2; pass++) {
            Class holder = pass == 0 ? cls : object_getClass((id)cls);
            if (holder == Nil) continue;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(holder, &count);
            if (methods == NULL) continue;
            for (unsigned int j = 0; j < count; j++) {
                SEL sel = method_getName(methods[j]);
                const char *sname = sel_getName(sel);
                if (sname == NULL) continue;
                for (size_t s = 0; s < selCount; s++) {
                    if (!sel_isEqual(sel, targets[s])) continue;
                    if (hitsPer[s] >= 3) continue;
                    const char *enc = method_getTypeEncoding(methods[j]);
                    AevonScnHostEmit([NSString stringWithFormat:@"surf: scn host %s %s %c{%s}",
                                      sels[s], cname, pass == 0 ? 'i' : 'c',
                                      enc != NULL ? enc : "?"]);
                    hitsPer[s] += 1;
                    totalHits += 1;
                }
                // 第二问：改名了的话，名字里仍会留着这两个词。
                if (urlHits < 14 && strcasestr(sname, "openurl") != NULL &&
                    (strcasestr(sname, "display") != NULL || strcasestr(sname, "scene") != NULL)) {
                    const char *enc = method_getTypeEncoding(methods[j]);
                    AevonScnHostEmit([NSString stringWithFormat:@"surf: scn urln %s.%s{%s}",
                                      cname, sname, enc != NULL ? enc : "?"]);
                    urlHits += 1;
                }
            }
            free(methods);
        }
    }
    free(list);
    for (size_t s = 0; s < selCount; s++) {
        if (hitsPer[s] == 0) {
            AevonScnHostEmit([NSString stringWithFormat:@"surf: scn host none %s", sels[s]]);
        }
    }
    AevonScnHostEmit([NSString stringWithFormat:@"surf: scn host total=%d urln=%d",
                      totalHits, urlHits]);
}

/// 入口。装配前调用一次；跑在低优先级全局队列上。
void AevonActivateSurfaceCensus(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        AevonLogRaw("surf: begin (0.1.86 read-only)");
        AevonSurfExists();
        AevonSurfChain("SBMainWorkspace");
        AevonSurfChain("SBNCNotificationDispatcher");
        AevonSurfChain("SBDashBoardNotificationPresenter");
        AevonSurfChain("SBLockScreenManager");
        // 工作区：激活总入口最可能在这两个类上。带编码。
        AevonSurfClass("SBMainWorkspace", "activ", 24, YES);
        AevonSurfClass("SBMainWorkspace", "applic", 24, YES);
        AevonSurfClass("SBMainWorkspace", "launch", 16, YES);
        AevonSurfClass("SBWorkspace", "activ", 24, YES);
        AevonSurfClass("SBWorkspace", "applic", 16, YES);
        // 应用控制器：按 bundle id 取 SBApplication 的那一层。
        AevonSurfClass("SBApplicationController", "activ", 12, NO);
        AevonSurfClass("SBApplicationController", "applic", 12, NO);
        AevonSurfClass("SBLockScreenManager", "activ", 16, NO);
        // 通知栈：如果激活入口这条路不通，下一步要挂这里。
        AevonSurfClass("NCNotificationShortLookViewController", "tap", 8, NO);
        AevonSurfClass("NCNotificationShortLookViewController", "handle", 12, NO);
        AevonSurfClass("NCNotificationDispatcher", "action", 12, NO);
        AevonSurfClass("NCNotificationDispatcher", "handle", 12, NO);
        AevonSurfClass("SBNCNotificationDispatcher", "perform", 12, NO);
        AevonSurfClass("SBNCNotificationDispatcher", "request", 12, NO);
        AevonSurfClass("SBDashBoardNotificationPresenter", "perform", 12, NO);
        AevonSurfClass("SBDashBoardNotificationPresenter", "request", 12, NO);
        AevonSurfClass("SBUserNotificationCenter", "request", 12, NO);
        AevonSurfClass("SBUserNotificationCenter", "action", 12, NO);
        AevonSurfGlobal();
        // 0.2.10 — 自建 scene 的能力面。放在通知那一半之后、`surf: end` 之前：
        // 两半各自有预算，谁先跑完都不会把另一半静音。
        AevonScnExists();
        AevonScnNames();
        AevonScnSelectors();
        // 0.2.11 — 0.2.10 那五个问答 none 的名字，改成「全类扫」再问一次。
        AevonScnHosts();
        AevonLogRaw("surf: end");
    });
}
