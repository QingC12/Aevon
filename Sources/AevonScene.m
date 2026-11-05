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
#import <math.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
        if (fabs(now.size.width - target.size.width) < 0.5
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
