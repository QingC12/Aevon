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
static long AevonInterceptCalls = 0;
static long AevonSceneLifeCalls = 0;

/// Eight lines of what the hooks actually saw, written as C strings on purpose:
/// these run inside SpringBoard's scene-update path, and formatting an
/// `NSString` there is work nobody asked for. The first four calls per hook are
/// the interesting ones; after that only the counters move.
static char AevonTrace[8][192];
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

/// The first class whose *own* method list contains this selector. Own list, not
/// `class_getInstanceMethod`: hooking a subclass that merely inherits the method
/// is how a hook ends up applied to one app's scene and not the next one's.
static Class AevonClassDeclaring(NSString *selName) {
    SEL target = NSSelectorFromString(selName);
    if (target == NULL) return Nil;
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return Nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (classes == NULL) return Nil;
    total = objc_getClassList(classes, total);
    Class found = Nil;
    for (int i = 0; i < total && found == Nil; i++) {
        unsigned int count = 0;
        Method *list = class_copyMethodList(classes[i], &count);
        if (list == NULL) continue;
        for (unsigned int k = 0; k < count; k++) {
            if (method_getName(list[k]) == target) { found = classes[i]; break; }
        }
        free(list);
    }
    free(classes);
    return found;
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
                void (*original)(id, SEL, unsigned long long, id, id, id) =
                    (void (*)(id, SEL, unsigned long long, id, id, id))slot->original;
                if (original != NULL) {
                    original(manager, slot->sel, use, scene, settings, reason);
                }
            };
            AevonAttach(out, slot, deact,
                        @"_setDeactivationReasons:onScene:withSettings:reason:", block);
        }
    }

    // 2. The interceptor beside it, read-only on this pass: it is installed to
    //    count and to print the shape of what the system proposes, and it
    //    returns exactly what the original returned. Modifying settings here is
    //    the next version's job, once (1) is known to be called at all.
    NSString *interceptName = @"_scene:interceptUpdateWithNewSettings:";
    Class interceptor = AevonClassDeclaring(interceptName);
    if (interceptor == Nil) {
        [out appendString:@"hook intercept: no class declares it\n"];
    } else {
        Method shape = class_getInstanceMethod(interceptor, NSSelectorFromString(interceptName));
        const char *encoding = shape != NULL ? method_getTypeEncoding(shape) : NULL;
        unsigned int arguments = shape != NULL ? method_getNumberOfArguments(shape) : 0;
        [out appendFormat:@"hook intercept cls=%@ types=%s args=%u\n",
         NSStringFromClass(interceptor), encoding != NULL ? encoding : "?", arguments];
        if (shape == NULL || encoding == NULL || encoding[0] != '@' || arguments != 4) {
            [out appendString:@"hook intercept: shape is not (id, id, id) -> id, left alone\n"];
        } else {
            AevonHookSlot *slot = AevonReserve("intercept");
            if (slot == NULL) {
                [out appendString:@"hook intercept: no slot\n"];
            } else {
                id block = ^id(id object, id scene, id settings) {
                    long seen = __sync_fetch_and_add(&AevonInterceptCalls, 1);
                    if (seen < 4) {
                        AevonRawTrace("intercept", "scene=%s settings=%s",
                                      AevonSceneName(scene),
                                      settings != nil ? class_getName(object_getClass(settings)) : "nil");
                    }
                    id (*original)(id, SEL, id, id) =
                        (id (*)(id, SEL, id, id))slot->original;
                    if (original == NULL) return settings;
                    return original(object, slot->sel, scene, settings);
                };
                AevonAttach(out, slot, interceptor, interceptName, block);
            }
        }
    }

    // 3. The scene's own life, counted rather than changed. Two numbers that say
    //    whether the hold above worked: a scene that is still being activated
    //    and never deactivated after the app leaves is a scene that kept its
    //    layers.
    Class sceneClass = NSClassFromString(@"FBScene");
    if (sceneClass == Nil) {
        [out appendString:@"hook scene life: no FBScene\n"];
    } else {
        // C strings, not NSString: a slot keeps this pointer for the life of the
        // process, and an `[labels[i] UTF8String]` would be a dangling pointer the
        // moment the array went away.
        const char *names[2] = {"activateWithTransitionContext:",
                                "deactivateWithTransitionContext:"};
        const char *labels[2] = {"scene-on", "scene-off"};
        for (int i = 0; i < 2; i++) {
            AevonHookSlot *slot = AevonReserve(labels[i]);
            if (slot == NULL) break;
            BOOL on = (i == 0);
            id block = ^(id scene, id context) {
                long seen = __sync_fetch_and_add(&AevonSceneLifeCalls, 1);
                if (seen < 4) {
                    AevonRawTrace(on ? "scene-on" : "scene-off", "scene=%s",
                                  AevonSceneName(scene));
                }
                void (*original)(id, SEL, id) = (void (*)(id, SEL, id))slot->original;
                if (original != NULL) original(scene, slot->sel, context);
            };
            AevonAttach(out, slot, sceneClass,
                        [NSString stringWithUTF8String:names[i]], block);
        }
    }
    return out;
}

/// The counters and the traces, one line each. Called at the two moments when
/// the answer matters: right before the card is built, and right after it is
/// taken down.
NSString *AevonHookSummary(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"hook: live=%d deact_set=%ld stripped=%ld intercept=%ld scene_life=%ld armed=%@\n",
     AevonSlotCount, AevonDeactSetCalls, AevonDeactStripped,
     AevonInterceptCalls, AevonSceneLifeCalls,
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

    id manager = nil;
    Class cls = NSClassFromString(@"UIApplicationSceneDeactivationManager");
    if (cls != Nil) {
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

