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
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

// 0.1.40 — 这两个符号由 Swift 侧（`Log.swift` / `SceneProbe.swift`）用
// `@_cdecl` 导出。Swift 的 bridging header 不会进 `.m`，所以在这里各写一行
// `extern`：签名必须与那两处逐字一致（`const char *`，可空）。
extern void AevonLogRaw(const char *line);
extern void AevonOpenFromNotification(const char *bundleID);
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

// MARK: - Notes

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
    id presenter = call(manager, sel, identifier, priority);
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
static int AevonArmedCount = 0;
static long AevonArmedRefused = 0;

static long AevonDeactSetCalls = 0;
static long AevonDeactStripped = 0;

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
        __sync_fetch_and_add(&AevonArmedCount, 1);
        return;
    }
    __sync_fetch_and_add(&AevonArmedRefused, 1);
}

/// 撤回一个名字。`nil` / 空串 = 全部撤回 —— 那是 0.0.97 之前的语义，留在最后
/// 一个参数位置上，好让还没改完的调用点不会悄悄变成空操作。
void AevonHookDisarm(NSString *bundle) {
    if (bundle == nil || [bundle length] == 0) {
        for (int i = 0; i < AEVON_ARMED_MAX; i++) AevonArmed[i][0] = '\0';
        AevonArmedCount = 0;
        return;
    }
    const char *text = [bundle UTF8String];
    if (text == NULL) return;
    for (int i = 0; i < AEVON_ARMED_MAX; i++) {
        if (AevonArmed[i][0] == '\0') continue;
        if (strcmp(AevonArmed[i], text) != 0) continue;
        AevonArmed[i][0] = '\0';
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
    if (scene == nil) return 0;
    if (![NSThread isMainThread]) return 0;
    if (AevonHookDepth > 0) return 0;
    if (AevonInPush) return 0;
    int slot = AevonSlotOfScene(scene);
    if (slot < 0 || !(AevonFrameMask & (1 << slot))) return 0;
    SEL settingsSel = sel_registerName("settings");
    if (![scene respondsToSelector:settingsSel]) return 0;
    id current = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    id candidate = [current mutableCopy];
    if (candidate == nil) candidate = current;
    AevonInPush = 1;
    BOOL wrote = AevonWriteFrame(candidate, slot);
    NSInteger path = 0;
    if (wrote) {
        path = AevonCallSettingsTransition(scene, candidate);
        if (path == 0 && AevonCallSettings(scene, candidate)) path = 1;
    }
    AevonInPush = 0;
    return wrote ? path : 0;
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
    return wrote;
}


static AevonHookSlot *AevonReserve(const char *label) {
    if (AevonSlotCount >= AEVON_HOOK_SLOTS) return NULL;
    AevonHookSlot *slot = &AevonSlots[AevonSlotCount++];
    memset(slot, 0, sizeof(*slot));
    slot->label = label;
    return slot;
}

/// Installs one replacement and says in the notes exactly what happened. The
/// IMP that comes back from `imp_implementationWithBlock` is the runtime's own,
/// which is why the read-back can differ from it on arm64e and still be live —
/// the counter, not this number, is the answer.
static BOOL AevonAttach(NSMutableString *out, AevonHookSlot *slot,
                        Class cls, NSString *selName, id block) {
    if (out == nil || slot == NULL || cls == Nil || selName == nil || block == nil) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (sel == NULL) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) {
        [out appendFormat:@"hook %s: no method\n", slot->label];
        return NO;
    }

    IMP previous = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    if (replacement == NULL) {
        [out appendFormat:@"hook %s: no trampoline\n", slot->label];
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
    BOOL wrote = AevonAttach(out, slot, cls, selName, block);
    if (!wrote) AevonRelease(slot);
    return wrote;
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

/// Installs every hook the mother ship's route needs and returns the notes.
/// Idempotent: a second tap in the same process reports the first install rather
/// than stacking a replacement on top of a replacement.
NSString *AevonHookInstall(void) {
    NSMutableString *out = [NSMutableString string];
    if (AevonSlotCount > 0) {
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

    // 1. The one the whole route rests on. `_setDeactivationReasons:` is how
    //    SpringBoard decides whether a scene may sleep; stripping the reasons of
    //    exactly one bundled scene is the mother ship's mechanism, and it is the
    //    only thing that keeps a backgrounded app drawing.
    Class deact = NSClassFromString(@"UIApplicationSceneDeactivationManager");
    if (deact == Nil) {
        [out appendString:@"hook deact-set: no UIApplicationSceneDeactivationManager\n"];
    } else {
        AevonHookSlot *slot = AevonReserve("deact-set");
        if (slot == NULL) {
            [out appendString:@"hook deact-set: no slot\n"];
        } else {
            id block = ^(id manager, unsigned long long reasons, id scene,
                         id settings, id reason) {
                long seen = __sync_fetch_and_add(&AevonDeactSetCalls, 1);
                // The instance this file spent two versions failing to find is
                // the first argument of the one hook the device does call.
                if (AevonDeactManager == nil) AevonDeactManager = manager;
                BOOL mine = AevonSceneIsMine(scene);
                if (seen < 4) {
                    AevonRawTrace("deact-set", "reasons=%llu mine=%d scene=%s",
                                  reasons, mine ? 1 : 0, AevonSceneName(scene));
                }
                unsigned long long use = reasons;
                if (mine && reasons != 0) {
                    use = 0;
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
                    (void (*)(id, SEL, unsigned long long, id, id, id))slot->original;
                if (original != NULL) {
                    original(manager, slot->sel, use, scene, settings, reason);
                }
                __sync_fetch_and_sub(&AevonHookDepth, 1);
            };
            AevonAttach(out, slot, deact,
                        @"_setDeactivationReasons:onScene:withSettings:reason:", block);
        }
    }

    // 2. The mother ship's real door, on the class she actually hooked.
    //
    //    `SBMainDisplaySceneManager` is a subclass of `SBSceneManager`, and
    //    0.0.29 patched the parent: `intercept=0` for eight seconds, twice. A
    //    subclass that overrides a method never runs the parent's IMP, so a
    //    patch on the parent is a patch on a method nothing calls. Both classes
    //    are tried here, and the log says which one owns a method with the right
    //    shape — that single line is the whole question 0.0.29 could not answer.
    //
    //    The amendment happens *before* the original runs: whatever the original
    //    does with the settings — apply them itself, or hand them back to its
    //    caller to apply — it does it to the version we changed.
    for (NSString *className in @[@"SBMainDisplaySceneManager", @"SBSceneManager"]) {
        Class mgr = NSClassFromString(className);
        if (mgr == Nil) {
            [out appendFormat:@"hook intercept: no %@\n", className];
            continue;
        }
        AevonHookSlot *slot = AevonReserve("intercept");
        if (slot == NULL) {
            [out appendString:@"hook intercept: no slot\n"];
            break;
        }
        __block AevonHookSlot *mine = slot;
        id block = ^(id manager, id scene, id settings) {
            long seen = __sync_fetch_and_add(&AevonInterceptCalls, 1);
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
        AevonAttachShaped(out, slot, mgr, @"_scene:interceptUpdateWithNewSettings:", 2, block);
    }

    return out;
}

/// The counters and the traces, one line each. Called at the two moments when
/// the answer matters: right before the card is built, and right after it is
/// taken down.
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

/// 0.0.40 — the count of deactivation attempts, for the card's clock. Exposed as
/// a function rather than a global so Swift reads it the same way it reads
/// everything else in this file, and cannot cache it by accident.
long AevonDeactCount(void) {
    return AevonDeactSetCalls;
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

static IMP AevonSendEventOriginal = NULL;

static void AevonSendEventReplacement(id self, SEL _cmd, UIEvent *event) {
    if (AevonSendEventOriginal == NULL) return;

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

/// App 的数据容器。`LSApplicationProxy` 在 SpringBoard 里是现成的；取不到就扫
/// 容器目录的元数据（每份都记着 bundle id）。两条路都失败返回 nil。
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
            if ([info isKindOfClass:[NSDictionary class]]
                && [[info objectForKey:@"MCMMetadataIdentifier"] isEqualToString:bundleID]) {
                return dir;
            }
        }
    }
    return nil;
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
int AevonAppMiniFlagsClearAll(void) {    NSString *armed = AevonMiniArmedPath();
    NSString *text = [NSString stringWithContentsOfFile:armed
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    int count = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        if (AevonAppMiniFlagSet(line, NO)) count += 1;
    }
    if (armed != nil) [[NSFileManager defaultManager] removeItemAtPath:armed error:NULL];
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
    CFStringRef app = (__bridge CFStringRef)bundleID;
    CFPreferencesSetAppValue(CFSTR("AevonBand"), (__bridge CFStringRef)body, app);
    CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    // 容器那条兜底只给卡片自己那个 App 做：`AevonAppContainer` 要过一次
    // LSApplicationProxy 加目录扫描，广播时对每个前台 App 都做一次就是白花。
    if (owner) {
        NSString *dir = AevonAppContainer(bundleID);
        if (dir != nil) {
            NSString *path = [dir stringByAppendingPathComponent:@"tmp/aevon-band"];
            if (off) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            } else {
                [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }
    }
    NSString *name = [NSString stringWithFormat:@"com.aevon.band.%@", bundleID];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, true);
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
// 母本那个 `_activateBundleID:...` 确实不存在 —— 这台机器把「开一个 App」拆成了上面
// 四条，而且**参数形状逐字相同**：5 个参数（request / options / activationSettings /
// origin / 结果块），帧长 56，返回 void，最后一个是 `@?` 块。四条都在 SBMainWorkspace
// 自己的方法表里（`n=16/170`），不是从父类继承来的。
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
//   闸三 · 目标      bundle 必须是从 `request` 直接取到的非空串，且不是 SpringBoard 自己；
//   闸四 · 兜底      吞掉之后 2.5 秒查一次 `AevonCardIsUpFor()`；卡片没起来就把原实现
//                    **补调一次**（这是「点了没反应」这个最坏结果唯一的出口）。
//
// 为什么敢吞：`openCard` 自己已经有一条全屏兜底（`ring: card route declined` →
// `LSApplicationWorkspace openApplicationWithBundleID:`）。闸四补的是它兜不住的那
// 一段 —— 挂起启动成功但卡片没建成，那时既没有卡片也没有全屏。
//
// 为什么必须查而不是等：真机上场景是异步出现的，`openCard` 的轮询最长会走满
// 若干拍。用一个固定延时判「成了没成」正是 0.1.84 键盘那一版的错法（拿时间当
// 证据），所以这里判的是**卡片在不在**，不是「过了多久」。

/// 上一次分流的时刻与目标。同一次点击会连着走 open → trusted 两条，第一条被吞掉
/// 之后第二条通常不会再来（链条在替身里就断了）；真来了也不能再开一次卡片。
static double AevonDivertAt = 0;
static char AevonDivertBundle[64] = {0};

/// 一次开机最多分流几次。真机上「点了通知却什么都没有」是最难受的失败，所以
/// 宁可少分几次 —— 用满之后一律回到 0.1.87 的行为。
static int AevonDivertCount = 0;
#define AEVON_DIVERT_MAX 24

/// 「认出来了却没分流」的解释行单独计数，不占 `AevonOpenKeyNotes` 的键名预算 ——
/// 两个预算合用一个计数器，先跑完的那个会把另一个静音。
static int AevonDivertNotes = 0;

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

/// `options` 里有没有某个键。
static BOOL AevonOpenHasKey(id options, NSString *key) {
    id dict = AevonOpenDict(options);
    if (dict == nil) return NO;
    return [(NSDictionary *)dict objectForKey:key] != nil;
}

/// 分流决定。
///   返回 1 → 吞掉，开卡片；
///   返回 2 → 吞掉，不再开（同一次点击的后续链）；
///   返回 0 → 原样转发，行为与 0.1.87 一致。
/// `why` 只用于日志：它把「没分流」的四种原因分开，否则下一份日志里
/// 「一个 notify: divert 都没有」与「分流了但没生效」长得一样。
static int AevonOpenDecide(id request, id options,
                           char *bundle, size_t size, const char **why) {
    if (bundle == NULL || size == 0) return 0;
    bundle[0] = '\0';
    *why = "-";

    if (AevonActivateSwitchOff()) { *why = "off"; return 0; }
    if (AevonDivertCount >= AEVON_DIVERT_MAX) { *why = "cap"; return 0; }

    id target = AevonOpenBundleOf(request);
    if (target == nil) { *why = "nobundle"; return 0; }
    const char *raw = [(NSString *)target UTF8String];
    if (raw == NULL || strlen(raw) < 3) { *why = "nobundle"; return 0; }
    snprintf(bundle, size, "%s", raw);

    // SpringBoard 自己也有开请求（解锁后回到主屏之类）。吞掉它就是吞掉主屏。
    if (strncmp(bundle, "com.apple.springboard", 21) == 0) { *why = "springboard"; return 0; }

    // 判据先于「同一次点击的第二条」：先确认这是一次通知回应，再谈它是不是
    // 上一次的后续。顺序反过来，用户在 1.5 秒内点桌面图标也会被当成链条吞掉 ——
    // 那是一个真实的「点了没反应」。
    if (!AevonOpenIsNotificationAction(AevonOpenFirstAction(request, options))) {
        *why = "plain";
        return 0;
    }

    // 同一次点击的第二条（open → trusted 之间只隔几毫秒）。第一条被吞掉之后
    // 链条通常就断了；真来了也不能再开一次卡片，否则屏幕上一大一小的两个。
    double now = CFAbsoluteTimeGetCurrent();
    if (AevonDivertAt > 0 && now - AevonDivertAt < 1.5 &&
        strcmp(bundle, AevonDivertBundle) == 0) {
        *why = "chain";
        return 2;
    }

    *why = "notify";
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
    if (AevonOpenTotal > 32) {
        if (AevonOpenTotal == 33) snprintf(out, size, "notify: open budget spent n=32");
        return;
    }
    if (slot < 0 || slot >= AevonOpenMax) return;
    if (AevonOpenPer[slot] >= 10) return;
    AevonOpenPer[slot] += 1;
    @try {
        char bundleText[52], sourceText[52], actionText[56], urlText[88];
        char reqText[40], optText[40], setText[40], orgText[40], keys[152];
        keys[0] = '\0';
        urlText[0] = '-';
        urlText[1] = '\0';

        id payload = AevonActRead(options, @"__PayloadOptions");
        if (payload == nil) payload = AevonActRead(request, @"__PayloadOptions");
        if (payload == nil) payload = AevonActRead(options, @"payloadOptions");
        id from = payload != nil
                ? AevonActRead(payload, @"UIApplicationLaunchOptionsSourceApplicationKey")
                : nil;

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
            id dump = [options isKindOfClass:[NSDictionary class]]
                    ? options
                    : AevonActRead(options, @"dictionary");
            if ([dump isKindOfClass:[NSDictionary class]]) {
                AevonOpenKeyNotes += 1;
                size_t used = 0;
                for (id key in (NSDictionary *)dump) {
                    if (![key isKindOfClass:[NSString class]]) continue;
                    const char *raw = [(NSString *)key UTF8String];
                    if (raw == NULL) continue;
                    size_t need = strlen(raw);
                    if (used + need + 2 >= sizeof(keys)) break;
                    if (used > 0) keys[used++] = ',';
                    memcpy(keys + used, raw, need);
                    used += need;
                    keys[used] = '\0';
                }
            }
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

/// 三个空块，形状各一种。补调原实现时用它们顶替**已经收过尾**的结果块：原实现
/// 照旧会调一次，而这一次什么都不做。
static void (^AevonNoopBool)(BOOL) = ^(BOOL ok) { (void)ok; };
static void (^AevonNoopObj)(id) = ^(id value) { (void)value; };
static void (^AevonNoopVoid)(void) = ^{ };

static id AevonOpenNoopFor(char form) {
    switch (form) {
        case 'B': return (id)AevonNoopBool;
        case '@': return (id)AevonNoopObj;
        case 'v': return (id)AevonNoopVoid;
        default: return nil;
    }
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

/// 吞掉之后的兜底看门狗。
/// 吞掉 SpringBoard 的开请求，最坏的结果是「点了通知什么也没发生」。`openCard`
/// 自己有一条全屏兜底，但它兜不住「挂起启动成功、卡片没建成」那一段 —— 那时既
/// 没有卡片也没有全屏。所以 2.5 秒后查一次**卡片在不在**：不在就把原实现补调
/// 一次，让这一下退化成 0.1.87 的行为。补调只发生一次，且只在没有卡片时。
///
/// 2.5 秒是给的余量，不是判据：`openCard` 里 `pollForScene` 要等场景出现，真机
/// 上通常 0.3~1 秒；判据是 `AevonCardIsUpFor()` 的返回值。拿时间当判据正是
/// 0.1.84 键盘那一版的错法。
static void AevonOpenWatch(id self, SEL cmd, id request, id options,
                           id settings, id origin, id replayResult,
                           IMP original, NSString *bundle) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        const char *want = [bundle UTF8String];
        if (want == NULL) return;
        if (AevonCardIsUpFor(want)) {
            AevonLogRaw([[NSString stringWithFormat:@"notify: divert card up b=%@", bundle]
                         UTF8String]);
            return;
        }
        AevonLogRaw([[NSString stringWithFormat:@"notify: divert replay b=%@", bundle]
                     UTF8String]);
        @try {
            if (original != NULL) {
                ((void (*)(id, SEL, id, id, id, id, id))original)
                    (self, cmd, request, options, settings, origin, replayResult);
            }
        } @catch (NSException *exception) {
            AevonLogRaw([[NSString stringWithFormat:@"notify: divert replay threw %@",
                          exception.name != nil ? exception.name : @"?"] UTF8String]);
        }
    });
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
static void AevonCleanCover(char *out, size_t size) {
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

    for (int i = 0; i < ladderCount; i++) {
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

/// SpringBoard 的通知 dispatcher。只解析一次，解析结果留一份强引用。
///
/// 取法是 0.7 那条线留下的：SpringBoard（`UIApplication.delegate`）→ `notificationDispatcher`
/// → `SBNCNotificationDispatcher` → 各 destination。三个名字都试，谁先答用谁；答不上就
/// 记 `d=-`，本版退回「只有通知中心会被收、横幅照系统原样 5 秒后自己走」。
static id AevonCleanDispatcherRef = nil;
static int AevonCleanDispatcherTried = 0;

static id AevonCleanDispatcher(void) {
    if (AevonCleanDispatcherRef != nil) return AevonCleanDispatcherRef;
    if (AevonCleanDispatcherTried) return nil;
    AevonCleanDispatcherTried = 1;

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

/// 一次分流最多收几次。用满之后一律回到 0.1.88 的行为（面板与横幅都不动）。
static int AevonCleanRuns = 0;
#define AEVON_CLEAN_MAX 6

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
///   3600  连「在路上」都没有 ⇒ `cover=skip:nocard`，不动手
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
        AevonCleanCover(cover, sizeof(cover));
        // `f=1` 表示这一下是「卡在路上就收了」，不是「卡片已经在」。两者都要留痕：
        // 若用户觉得快是快了但闪了一下，日志里这两格就是分辨它的唯一办法。
        snprintf(line, sizeof(line), "notify: cover b=%s %s wait=%d at=%dms f=%d",
                 bundle, cover, tick, AevonCleanElapsed(), up ? 0 : 1);
        AevonLogRaw(line);
        return;
    }
    if (tick >= AEVON_CLEAN_TRIES) {
        char line[240];
        snprintf(line, sizeof(line), "notify: cover b=%s cover=skip:nocard wait=%d at=%dms",
                 bundle, tick, AevonCleanElapsed());
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
    if (AevonCleanRuns >= AEVON_CLEAN_MAX) return;
    AevonCleanRuns += 1;

    id dispatcher = AevonCleanDispatcher();
    char banner[128], line[360];
    banner[0] = '\0';

    AevonCleanBanner(dispatcher, banner, sizeof(banner));

    const char *dname = dispatcher != nil ? class_getName([dispatcher class]) : "-";
    snprintf(line, sizeof(line), "notify: clean d=%s %s n=%d",
             dname != NULL ? dname : "?", banner, AevonCleanRuns);
    AevonLogRaw(line);

    if (bundle != NULL && bundle[0] != '\0') AevonCleanCoverAfterCard(bundle, 0);
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
    char line[640];
    line[0] = '\0';
    char bundle[64];
    bundle[0] = '\0';
    const char *why = "-";
    int verdict = 0;

    // 分流判定只对「我们装上的那四条」做。父类链上万一还有人来，走原样转发。
    if (slot >= 0 && AevonOpenOrig[slot] != NULL) {
        @try {
            verdict = AevonOpenDecide(request, options, bundle, sizeof(bundle), &why);
        } @catch (NSException *exception) {
            verdict = 0;
            why = "threw";
        }
    }

    if (verdict == 1) {
        AevonDivertCount += 1;
        // `unlock=1` 表示这一拍 SpringBoard 还带着「要不要顺手解锁」的意图。
        // 照样分流，但把它记下来：锁屏点通知若出现「卡片没起来、看门狗补调了
        // 原实现」，这一位就是解释 —— 解锁那一步在卡片这条路上没人做。
        snprintf(line, sizeof(line), "notify: divert b=%s op=%s why=%s unlock=%d n=%d",
                 bundle, slot >= 0 ? AevonOpenTargets[slot].tag : "?", why,
                 AevonOpenHasKey(options, @"__UnlockDevice") ? 1 : 0,
                 AevonDivertCount);
    } else if (verdict == 2) {
        // 吞掉，也不再开卡片。结果块照样要收尾，否则这一次调用会悬着。
        const char *chainShape = "none";
        AevonOpenFinishResult(result, &chainShape);
        snprintf(line, sizeof(line), "notify: divert chain b=%s op=%s result=%s", bundle,
                 slot >= 0 ? AevonOpenTargets[slot].tag : "?", chainShape);
    } else if (slot >= 0) {
        AevonOpenSnapshot(slot, request, options, settings, origin, line, sizeof(line));
    }

    if (verdict == 1) {
        // 不转发。SpringBoard 那一段（建 app layout、全屏推前台）整段跳过，改由
        // 卡片那条路自己拉起来。`AevonOpenFromNotification` 自己会切到主队列。
        NSString *target = [NSString stringWithUTF8String:bundle];
        if (target.length > 2) {
            // 结果块：认得出形状就当场收尾 —— 悬着的事务会让 SpringBoard 以为
            // 还在开 App。收尾之后补调原实现时必须换一个同形状的空块，
            // 否则同一个块会被收两次。
            char form = AevonOpenResultShape(result);
            const char *shape = "none";
            id replay = result;
            if (form != 0) {
                AevonOpenFinishResult(result, &shape);
                id noop = AevonOpenNoopFor(form);
                if (noop != nil) replay = noop;
            }
            size_t used = strlen(line);
            if (used + 16 < sizeof(line)) {
                snprintf(line + used, sizeof(line) - used, " result=%s", shape);
            }
            AevonOpenFromNotification(bundle);
            // 0.1.89：这次没转发，SpringBoard 就没有机会去收面板 / 收横幅 —— 那两件
            // 事本来挂在它的收尾里。自己补上。
            // 0.1.90：横幅在这里收，面板不在这里收 —— 面板要等卡片，见
            // `AevonCleanCoverAfterCard`。字符串必须自己复制一份带进块里。
            // 0.1.91：0.45 秒压到 0.10 秒，并且先记下手指这一刻（`at=` 的零点）。
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
            AevonOpenWatch(self, _cmd, request, options, settings, origin, replay,
                           AevonOpenOrig[slot], target);
        }
    } else if (verdict == 0) {
        IMP original = slot >= 0 ? AevonOpenOrig[slot] : NULL;
        if (original != NULL) {
            ((void (*)(id, SEL, id, id, id, id, id))original)
                (self, _cmd, request, options, settings, origin, result);
        }
        // 「认出来了但没分流」才是需要解释的：开关、上限、取不到目标。
        // `plain`/`nobundle` 是常态（点图标、分享面板），一行都不写。
        if (strcmp(why, "plain") != 0 && strcmp(why, "nobundle") != 0 &&
            AevonDivertNotes < 6 && line[0] == '\0') {
            AevonDivertNotes += 1;
            snprintf(line, sizeof(line), "notify: divert pass b=%s why=%s", bundle, why);
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
        AevonLogRaw("surf: end");
    });
}
