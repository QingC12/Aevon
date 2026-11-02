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

/// `createPresenterWithIdentifier:priority:` — one object plus one int64.
id AevonCreatePresenter(id manager, id identifier, long long priority) {
    SEL sel = NSSelectorFromString(@"createPresenterWithIdentifier:priority:");
    if (manager == nil || ![manager respondsToSelector:sel]) return nil;

    id (*call)(id, SEL, id, long long) = (id (*)(id, SEL, id, long long))objc_msgSend;
    return call(manager, sel, identifier, priority);
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

/// The selector exists on this OS and answers the given argument count.
/// Used by the probe to say "not there" instead of "I did not look".
BOOL AevonAnswers(id object, NSString *name, NSInteger arguments) {
    if (object == nil || name == nil) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return NO;
    if (arguments < 0) return YES;
    return [[object methodSignatureForSelector:sel] numberOfArguments] == (NSUInteger)(arguments + 2);
}
