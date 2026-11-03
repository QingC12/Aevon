//
//  AevonScene.m — the second non-Swift file, and for the same reason.
//
//  `_createSceneWithDefinition:settings:initialClientSettings:transitionContext:
//  fromRemnant:usingClientProvider:completion:` takes seven arguments. `perform`
//  carries one and `NSInvocation` needs a signature that is not worth guessing,
//  so the only honest way to reach it from Swift is objc_msgSend with an exact
//  cast. This file exists for that cast.
//
//  Everything here is guarded: a selector that is not there returns nil instead
//  of trapping. Callers log the nil and stop.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>

/// Returns the created FBScene, or nil when the manager does not answer.
/// The completion block is the caller's; this function never retains it.
id AevonCreateScene(id manager,
                    id definition,
                    id settings,
                    id clientSettings,
                    id transitionContext,
                    id remnant,
                    id clientProvider,
                    void (^completion)(id scene, id error)) {
    SEL sel = NSSelectorFromString(@"_createSceneWithDefinition:settings:"
                                   @"initialClientSettings:transitionContext:"
                                   @"fromRemnant:usingClientProvider:completion:");
    if (manager == nil || ![manager respondsToSelector:sel]) return nil;

    id (*call)(id, SEL, id, id, id, id, id, id, void (^)(id, id)) =
        (id (*)(id, SEL, id, id, id, id, id, id, void (^)(id, id)))objc_msgSend;
    return call(manager, sel, definition, settings, clientSettings,
                transitionContext, remnant, clientProvider, completion);
}

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

// MARK: - Reading and rebuilding the pieces of a scene definition

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

/// A zero-argument getter, or nil when the object does not answer. This is the
/// only call shape that can be made without knowing the signature first.
id AevonGetGetter(id object, NSString *name) {
    if (object == nil || name == nil) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;
    id (*call)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return call(object, sel);
}

/// Reads an ivar by name, walking the superclasses. FrontBoard keeps its
/// interesting state in ivars with no public getter, so `_identity` is the
/// normal way in, not the exception.
id AevonGetIvar(id object, NSString *name) {
    if (object == nil || name == nil) return nil;
    for (Class cursor = object_getClass(object); cursor != Nil; cursor = class_getSuperclass(cursor)) {
        Ivar ivar = class_getInstanceVariable(cursor, name.UTF8String);
        if (ivar != NULL) return object_getIvar(object, ivar);
    }
    AevonNote(@"ivar %@ absent on %@", name, NSStringFromClass([object class]));
    return nil;
}

/// Writes an ivar by name. Used only on a copy the caller has already proven is
/// a different object from the template — writing through to a live scene's
/// definition renames that scene out from under its owner.
BOOL AevonSetIvar(id object, NSString *name, id value) {
    if (object == nil || name == nil) return NO;
    Class cls = object_getClass(object);
    for (Class cursor = cls; cursor != Nil; cursor = class_getSuperclass(cursor)) {
        Ivar ivar = class_getInstanceVariable(cursor, name.UTF8String);
        if (ivar == NULL) continue;
        object_setIvar(object, ivar, value);
        AevonNote(@"ivar %@ written on %@", name, NSStringFromClass(cls));
        return YES;
    }
    AevonNote(@"ivar %@ absent on %@", name, NSStringFromClass(cls));
    return NO;
}

/// `mutableCopy` and the class of what comes back. An immutable class copies to
/// itself, and that one fact decides whether the copy may be modified at all.
id AevonMutableCopy(id object) {
    if (object == nil || ![object respondsToSelector:@selector(mutableCopy)]) return nil;
    id copy = [object mutableCopy];
    AevonNote(@"copy %@ -> %@", NSStringFromClass([object class]),
              copy ? NSStringFromClass([copy class]) : @"nil");
    return copy;
}

/// Copies, then renames. A new identifier means a new scene identity, and an
/// identity is the one field FrontBoard treats as a primary key: two scenes
/// sharing one is a replacement, not a duplicate.
id AevonRenameIdentity(id template, NSString *identifier) {
    if (template == nil || identifier == nil) return nil;
    id workspace = AevonGetGetter(template, @"workspaceIdentifier");
    AevonNote(@"identity template %@ workspace=%@",
              NSStringFromClass([template class]), workspace ?: @"nil");

    Class cls = NSClassFromString(@"FBSSceneIdentity");
    SEL pair = NSSelectorFromString(@"identityForIdentifier:workspaceIdentifier:");
    if (cls != Nil && [cls respondsToSelector:pair]) {
        id (*call)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        id made = call((id)cls, pair, identifier, workspace);
        if (made != nil) {
            AevonNote(@"identity via +identityForIdentifier:workspaceIdentifier:");
            return made;
        }
    }
    SEL single = NSSelectorFromString(@"identityForIdentifier:");
    if (cls != Nil && [cls respondsToSelector:single]) {
        id (*call)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id made = call((id)cls, single, identifier);
        if (made != nil) {
            AevonNote(@"identity via +identityForIdentifier:");
            return made;
        }
    }

    // Last resort: a copy of the template identity with the name rewritten.
    id copy = AevonMutableCopy(template);
    if (copy != nil && [copy class] != [template class]) {
        if (AevonSetIvar(copy, @"_identifier", identifier)) return copy;
    }
    AevonNote(@"no identity path worked");
    return nil;
}

/// Puts the identity on a definition. The setter is preferred over the ivar
/// because a setter may also refresh state derived from it.
BOOL AevonSetIdentity(id definition, id identity) {
    if (definition == nil || identity == nil) return NO;
    SEL sel = NSSelectorFromString(@"setIdentity:");
    if ([definition respondsToSelector:sel]) {
        void (*call)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        call(definition, sel, identity);
        AevonNote(@"setIdentity: accepted by %@", NSStringFromClass([definition class]));
        return YES;
    }
    return AevonSetIvar(definition, @"_identity", identity);
}

/// Every method whose name contains one of the comma-separated keys. This is
/// how "how do I build one of these" gets answered on a system whose headers
/// are not available: ask the class, do not guess.
NSString *AevonClassCensus(NSString *name, NSString *keys) {
    Class cls = NSClassFromString(name);
    if (cls == Nil) {
        AevonNote(@"census %@ absent", name);
        return AevonTakeNotes();
    }
    NSArray<NSString *> *wanted = [keys componentsSeparatedByString:@","];
    AevonNote(@"census %@ super=%@", name, NSStringFromClass(class_getSuperclass(cls)));

    for (int side = 0; side < 2; side++) {
        Class host = (side == 0) ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(host, &count);
        if (methods == NULL) continue;
        for (unsigned int i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            BOOL hit = NO;
            for (NSString *key in wanted) {
                // Case-insensitive on purpose: 0.0.15's census skipped
                // `clientIdentity` because every key was lowercase and the
                // capital I never matched. A census that hides the one setter
                // the definition actually needs is worse than no census.
                if (key.length > 0 &&
                    [sel rangeOfString:key options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    hit = YES; break;
                }
            }
            if (!hit) continue;
            AevonNote(@"  %@ %@", (side == 0 ? @"+" : @"-"), sel);
        }
        free(methods);
    }
    return AevonTakeNotes();
}

#pragma mark - The presenting route (0.0.16)

// 0.0.15 called `_createSceneWithDefinition:...` with four nils and SpringBoard
// died inside it. The mother ship never does that: it has FBSceneManagerHook,
// FBSceneHook and SBMainWorkspaceHook, keeps the app as a system scene, and only
// ever *presents* one. So this side of the file now does what she does —
// `uiPresentationManager` → `createPresenterWithIdentifier:priority:` →
// `presentationView` → `_UIContextLayerHostView initWithSceneLayer:` — and
// nothing else. Building a scene is retired, not deferred.

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

/// `[[_UIContextLayerHostView alloc] initWithSceneLayer:]`. The class is private
/// and its initialiser takes one object, so both steps live here rather than in
/// Swift where `alloc` + a private selector needs casts the compiler may reject.
id AevonLayerHost(id layer) {
    if (layer == nil) return nil;
    Class cls = NSClassFromString(@"_UIContextLayerHostView");
    if (cls == Nil) {
        AevonNote(@"layer host: no _UIContextLayerHostView");
        return nil;
    }
    id alloc = [cls alloc];
    SEL sel = NSSelectorFromString(@"initWithSceneLayer:");
    if (![alloc respondsToSelector:sel]) {
        AevonNote(@"layer host: no initWithSceneLayer:");
        return nil;
    }
    id (*call)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    id view = call(alloc, sel, layer);
    AevonNote(@"layer host -> %@", view ? NSStringFromClass([view class]) : @"nil");
    return view;
}

/// `setResizesHostedContext:`. BOOL in the third register, which is why this is
/// a cast and not `perform`.
BOOL AevonSetResizesHostedContext(id view, BOOL flag) {
    if (view == nil) return NO;
    SEL sel = NSSelectorFromString(@"setResizesHostedContext:");
    if (![view respondsToSelector:sel]) return NO;
    void (*call)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    call(view, sel, flag);
    return YES;
}

/// Answers "does this object have that selector" without calling it. Used to
/// settle `activate` / `invalidate` — two names that were hits=0 in the mother
/// ship and have stayed unresolved ever since, and that must not be *called*
/// just to find out.
BOOL AevonCan(id object, NSString *name) {
    if (object == nil || name == nil) return NO;
    return [object respondsToSelector:NSSelectorFromString(name)];
}

#pragma mark - What the device actually has (0.0.17)

/// Every runtime class whose name contains one of the comma-separated keys.
///
/// Two SpringBoard deaths in a row came from names we read out of another
/// binary's string table and trusted: `_createSceneWithDefinition:` and
/// `_UIContextLayerHostView`. The device is the authority on what exists and
/// what it is called, and asking costs one class-list walk — no message is sent
/// to anything, so no class can misbehave while it is asked.
NSString *AevonFindClasses(NSString *keys, NSInteger limit) {
    if (keys == nil || limit <= 0) return nil;
    NSArray<NSString *> *wanted = [keys componentsSeparatedByString:@","];
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (classes == NULL) return nil;
    total = objc_getClassList(classes, total);

    // One budget per key, not one budget shared by all of them.
    //
    // 0.0.17 asked for LayerHost, SceneLayer, Presentation and Presenter with a
    // limit of 20, and all 20 came back from `present` matching half of UIKit —
    // PassKitUI, PhotosUICore, JetEngine — while `LayerHost` never got a slot.
    // A scan that reports on the loudest keyword and calls it a survey is the
    // exact failure the operator named: the probe was looking wrong, and the
    // conclusion drawn from it would have been "the class is not here".
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *key in wanted) {
        if (key.length == 0) continue;
        NSInteger found = 0;
        for (int i = 0; i < total && found < limit; i++) {
            const char *raw = class_getName(classes[i]);
            if (raw == NULL) continue;
            NSString *name = [NSString stringWithUTF8String:raw];
            if (name == nil) continue;
            if ([name rangeOfString:key options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            [hits addObject:name];
            found += 1;
        }
        if (found == 0) {
            [hits addObject:[NSString stringWithFormat:@"(%@: none)", key]];
        } else if (found >= limit) {
            [hits addObject:[NSString stringWithFormat:@"(%@: capped at %ld)", key, (long)limit]];
        }
    }
    free(classes);
    return [hits componentsJoinedByString:@"\n"];
}

#pragma mark - Locate the mother ship's chain on this device (0.0.18)

// 0.0.16 took `_UIContextLayerHostView` out of another binary's __cstring table,
// trusted it, and killed SpringBoard with — most likely — the right class and
// the wrong argument. The mother ship's own selector chain is short and known:
//
//     initWithSceneLayer:  setResizesHostedContext:  setWindowLevel:
//
// What was never known is *which class* in this process answers them. That can
// be asked without sending a message: `class_getInstanceMethod` walks the
// superclass chain and returns NULL for "no", and nothing in the process can
// misbehave while it is asked. So this function answers "who implements this,
// and does anything implement all of them" before a single call is made.

/// Is this class a UIView, or a subclass of one? Walks the superclass chain by
/// pointer comparison, which needs no message and no name lookup, so it costs
/// nothing per class during a full class-list sweep.
static BOOL AevonIsView(Class cls) {
    if (cls == Nil) return NO;
    Class view = NSClassFromString(@"UIView");
    if (view == Nil) return NO;
    for (Class walk = cls; walk != Nil; walk = class_getSuperclass(walk)) {
        if (walk == view) return YES;
    }
    return NO;
}

/// For each selector: how many classes in this process implement it, and the
/// names of the first `limit` of them, tagged `[view]` when the class is a
/// UIView subclass.
///
/// 0.0.18 printed only the classes implementing *all* the selectors, and the
/// answer was seven Swift value types — `UIKeyboardCandidateViewStyle`,
/// `NTKInterpolatedColorPalette`, `REMAuxiliaryChangeInfoType` — which cannot
/// possibly implement `initWithSceneLayer:`. `class_getInstanceMethod` reports
/// a method for those class objects anyway. The intersection was noise and the
/// useful half — the eleven classes that really do implement it — was reduced
/// to a number. Names now, not a count.
NSString *AevonSelectorHome(NSString *selectors, NSInteger limit) {
    if (selectors == nil) return nil;
    NSArray<NSString *> *names = [selectors componentsSeparatedByString:@","];
    if (names.count == 0 || names.count > 8) return nil;
    if (limit <= 0) limit = 12;

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (classes == NULL) return nil;
    total = objc_getClassList(classes, total);

    NSMutableString *out = [NSMutableString string];
    for (NSString *name in names) {
        if (name.length == 0) continue;
        SEL sel = NSSelectorFromString(name);
        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        NSInteger count = 0;
        for (int i = 0; i < total; i++) {
            if (class_getInstanceMethod(classes[i], sel) == NULL) continue;
            count += 1;
            if ((NSInteger)hits.count >= limit) continue;
            [hits addObject:[NSString stringWithFormat:@"%@%@",
                             AevonIsView(classes[i]) ? @"[view] " : @"",
                             NSStringFromClass(classes[i])]];
        }
        [out appendFormat:@"home %@ %ld", name, (long)count];
        if (count == 0) {
            [out appendString:@"\n  (none on this system)"];
            continue;
        }
        if (count > (NSInteger)hits.count) {
            [out appendFormat:@" (+%ld not shown)", (long)(count - (NSInteger)hits.count)];
        }
        for (NSString *hit in hits) {
            [out appendFormat:@"\n  %@", hit];
        }
    }
    free(classes);
    return out;
}

/// Every method anywhere in the process whose selector mentions a scene layer,
/// a layer host or a context layer, with its real type encoding.
///
/// This is the answer to "Stheno was written for iOS 16 and we are on 17".
/// Copying her `__cstring` table assumes the names survived; this asks iOS 17
/// what it calls things now, and the encodings say what the arguments are
/// (`@"CALayer"` vs a raw struct pointer is the difference between 0.0.16
/// crashing and working).
NSString *AevonLayerNameScan(NSInteger limit) {
    if (limit <= 0) limit = 60;
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (classes == NULL) return nil;
    total = objc_getClassList(classes, total);

    NSMutableString *out = [NSMutableString string];
    NSInteger printed = 0;
    for (int i = 0; i < total; i++) {
        Class cls = classes[i];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        if (methods == NULL) continue;
        for (unsigned int k = 0; k < count; k++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[k]));
            if ([sel rangeOfString:@"SceneLayer"].location == NSNotFound &&
                [sel rangeOfString:@"LayerHost"].location == NSNotFound &&
                [sel rangeOfString:@"ContextLayer"].location == NSNotFound) {
                continue;
            }
            if (printed >= limit) { free(methods); break; }
            const char *enc = method_getTypeEncoding(methods[k]);
            [out appendFormat:@"\n%@%@ -%@ :: %s",
             AevonIsView(cls) ? @"[view] " : @"",
             NSStringFromClass(cls), sel,
             enc ? enc : "?"];
            printed += 1;
        }
        free(methods);
        if (printed >= limit) {
            [out appendFormat:@"\n scan capped at %ld", (long)limit];
            break;
        }
    }
    free(classes);
    return out;
}

/// One selector, one class: does it answer, with what encoding, and which class
/// in the chain actually defines it. Used to settle `initWithSceneLayer:`'s
/// argument type without calling it.
NSString *AevonSelectorInfo(NSString *className, NSString *selectors) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return [NSString stringWithFormat:@"info %@ absent", className];
    NSMutableString *out = [NSMutableString string];
    for (NSString *name in [selectors componentsSeparatedByString:@","]) {
        if (name.length == 0) continue;
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, sel);
        if (method == NULL) {
            [out appendFormat:@"info %@ -%@ :: absent\n", className, name];
            continue;
        }
        const char *enc = method_getTypeEncoding(method);
        Class owner = Nil;
        for (Class walk = cls; walk != Nil; walk = class_getSuperclass(walk)) {
            unsigned int n = 0;
            Method *ms = class_copyMethodList(walk, &n);
            BOOL found = NO;
            for (unsigned int i = 0; i < n; i++) {
                if (method_getName(ms[i]) == sel) { found = YES; break; }
            }
            if (ms != NULL) free(ms);
            if (found) { owner = walk; break; }
        }
        [out appendFormat:@"info %@ -%@ :: %s from %@\n", className, name,
         enc ? enc : "?",
         owner ? NSStringFromClass(owner) : @"?"];
    }
    return out;
}


NSString *AevonFullCensus(NSString *name, NSInteger limit) {
    Class cls = NSClassFromString(name);
    if (cls == Nil) return [NSString stringWithFormat:@"full %@ absent", name];
    if (limit <= 0) limit = 40;

    NSMutableString *out = [NSMutableString stringWithFormat:@"full %@ super=%@ own=%u",
                            name, NSStringFromClass(class_getSuperclass(cls)),
                            (unsigned)class_getInstanceSize(cls)];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods != NULL) {
        NSInteger printed = 0;
        for (unsigned int i = 0; i < count && printed < limit; i++) {
            [out appendFormat:@"\n  - %@", NSStringFromSelector(method_getName(methods[i]))];
            printed += 1;
        }
        if ((NSInteger)count > printed) [out appendString:@"\n  …capped"];
        free(methods);
    }
    return out;
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
