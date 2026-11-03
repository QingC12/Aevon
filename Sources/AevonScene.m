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
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

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

#define AEVON_HOOK_SLOTS 6

typedef struct {
    Class cls;
    SEL sel;
    IMP original;
    IMP replacement;
    const char *label;
} AevonHookSlot;

static AevonHookSlot AevonSlots[AEVON_HOOK_SLOTS];
static int AevonSlotCount = 0;

/// The bundle id the operator chose, or empty. The hook body compares this
/// against a scene's own identifier, so no scene is ever held open by accident.
static char AevonArmed[128];

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
static char AevonTrace[24][192];
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
    return AevonArmed[0] != '\0';
}

static BOOL AevonSceneIsMine(id scene) {
    if (!AevonIsArmed()) return NO;
    const char *name = AevonSceneName(scene);
    return name != NULL && strstr(name, AevonArmed) != NULL;
}

void AevonHookArm(NSString *bundle) {
    if (bundle == nil) return;
    const char *text = [bundle UTF8String];
    if (text == NULL) return;
    strlcpy(AevonArmed, text, sizeof(AevonArmed));
}

void AevonHookDisarm(void) {
    AevonArmed[0] = '\0';
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

/// `- (void)updateSettings:(id)` — one object, no block. The transition-context
/// variant is deliberately absent from this file: the mother ship's 0.3.0 passed
/// it a nil context and SpringBoard died on the spot (round 3, `[CONFIRMED]`,
/// twice, line for line), which is also why `_createTransitionContext` exists.
/// A door that needs a context and does not get one is not a door.
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

/// One attempt at "you are in front". Answers the door it used so the log can
/// say where the chain stops:
///
///   1  the scene's own `updateSettingsWithBlock:`
///   2  the deactivation manager's `amendSceneSettings:forScene:`
///   3  nothing to do — the scene already says it is in front, no write spent
///   0  no door, wrong thread, inside a hook, throttled, banned, or out of tries
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
    if ([scene respondsToSelector:settingsSel]) {
        current = ((id (*)(id, SEL))objc_msgSend)(scene, settingsSel);
    }

    // Delta first. Round 14 of the mother ship settled this: a write that
    // changes nothing still costs a re-layout, and a re-layout is a flicker.
    // A scene already in front gets no write at all, and the caller is told so
    // with 3 rather than 0 — "nothing to do" and "no door" are different facts.
    if (AevonFlagOf(current, "isForeground") == 1 && AevonFlagOf(current, "isBackgrounded") == 0) {
        if (attempt < 8) {
            AevonRawTrace("push", "front, no write settings=%s",
                          current != nil ? class_getName(object_getClass(current)) : "nil");
        }
        AevonInPush = 0;
        return 3;
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

    NSInteger path = 0;
    if (AevonCallBlockMethod(scene, @"updateSettingsWithBlock:", amend)
        || AevonCallSettings(scene, candidate)) {
        path = 1;
    } else if (AevonDeactManager != nil) {
        id manager = AevonDeactManager;
        SEL amendSel = NSSelectorFromString(@"amendSceneSettings:forScene:");
        if ([manager respondsToSelector:amendSel]) {
            Method method = class_getInstanceMethod(object_getClass(manager), amendSel);
            const char *encoding = method != NULL ? method_getTypeEncoding(method) : NULL;
            unsigned int arguments = method != NULL ? method_getNumberOfArguments(method) : 0;
            if (encoding != NULL && encoding[0] == 'v' && arguments == 4) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(manager, amendSel,
                                                          candidate != nil ? candidate : current,
                                                          scene);
                path = 2;
            }
        }
    }

    if (path != 0) {
        __sync_fetch_and_add(&AevonPushWrote, 1);
        AevonPushPath = path;
    }
    if (attempt < 8) {
        AevonRawTrace("push", "path=%ld wrote=%d fg=%d settings=%s", path,
                      inlineWrite ? 1 : 0,
                      AevonFlagOf(candidate != nil ? candidate : current, "isForeground"),
                      current != nil ? class_getName(object_getClass(current)) : "nil");
    }
    AevonInPush = 0;
    return path;
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
        && AevonFlagOf(current, "isBackgrounded") == 1) {
        return 3;
    }
    id candidate = [current mutableCopy];
    if (candidate == nil) candidate = current;
    AevonWriteFront(candidate, NO);
    void (^amend)(id) = [^(id settings) {
        AevonWriteFront(settings, NO);
    } copy];
    if (AevonCallBlockMethod(scene, @"updateSettingsWithBlock:", amend)) return 1;
    if (AevonCallSettings(scene, candidate)) return 1;
    return 0;
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

    return out;
}

/// The counters and the traces, one line each. Called at the two moments when
/// the answer matters: right before the card is built, and right after it is
/// taken down.
NSString *AevonHookSummary(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"hook: live=%d deact_set=%ld stripped=%ld"
     " push=%ld/%ld door=%ld armed=%@\n",
     AevonSlotCount, AevonDeactSetCalls, AevonDeactStripped,
     AevonPushWrote, AevonPushTried, AevonPushPath,
     AevonIsArmed() ? [NSString stringWithUTF8String:AevonArmed] : @"no"];
    long total = AevonTraceCount;
    long limit = (long)(sizeof(AevonTrace) / sizeof(AevonTrace[0]));
    if (total > limit) total = limit;
    for (long i = 0; i < total; i++) {
        if (AevonTrace[i][0] == '\0') continue;
        [out appendFormat:@"hook trace %ld %s\n", i, AevonTrace[i]];
    }
    return out;
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

