//
//  Aevon.mm
//  Aevon — Stage 1: settings surface + probe harness. Still ZERO hooks.
//
//  Design invariant (DO NOT BREAK):
//    This dylib must never be able to prevent the device from booting.
//    It only ever touches /var/mobile/Library/Logs/Aevon/* on disk, plus the
//    com.aevon.aevon preference domain through cfprefsd. Zero hooks.
//
//  Gate order (all must pass before anything is executed):
//    G0  panic      file exists  OR  pref "panic"    == true
//    G1  disabled   state.plist  OR  pref "disabled" == true
//    G2  crash-loop breaker (attempts > kMaxAttempts)
//
//  Why the probes live here and not in the settings bundle:
//    The two unknowns blocking P1 (method signature of
//    _scene:interceptUpdateWithNewSettings: and the live scene tree) can only be
//    read from inside the SpringBoard process. Running them here means one
//    install answers every question at once, and the answers are published back
//    through preferences so Settings can show them without a terminal.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import "AevonPaths.h"

extern char **environ;

#ifndef AEVON_STAGE
#define AEVON_STAGE 0
#endif

static NSString *const kAevonVersion = @"0.0.2";

// ---------------------------------------------------------------------------
// Tunables. A false positive only means "tweak switched itself off";
// a false negative means "one more crash loop".
// ---------------------------------------------------------------------------
static const int      kMaxAttempts = 3;
static const double   kCrashWindow = 300.0;
static const double   kStableDelay = 60.0;
static const double   kProbeDelay  = 4.0;    // let SpringBoard settle first
static const NSUInteger kLogCap    = 96 * 1024;

typedef NS_ENUM(NSInteger, AevonGate) {
    AevonGatePass = 0,
    AevonGateBlockedPanic,
    AevonGateBlockedDisabled,
    AevonGateBlockedCrashLoop,
    AevonGateBlockedUnwritable,
};

#pragma mark - Logging

static void AevonLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[Aevon] %@", message);

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kAevonLogDir]) {
        [fm createDirectoryAtPath:kAevonLogDir
      withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:kAevonLogPath error:NULL];
    if (attrs && [attrs fileSize] > kLogCap) {
        [fm removeItemAtPath:kAevonLogPath error:NULL];
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [df stringFromDate:[NSDate date]], kAevonVersion, message];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kAevonLogPath];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {
            // never let logging take the process down
        }
    } else {
        [line writeToFile:kAevonLogPath atomically:NO
                 encoding:NSUTF8StringEncoding error:NULL];
    }
}

#pragma mark - Gates

static AevonGate AevonPassGates(void) {
    // G0 — hard kill switch (file or preference; either one is enough).
    if (AevonPanicActive()) {
        AevonLog(@"gate G0: panic active, standing down (zero hooks)");
        return AevonGateBlockedPanic;
    }

    // G1 — operator/auto disable flag.
    if (AevonDisabledActive()) {
        AevonLog(@"gate G1: disabled, reason=%@",
                 AevonReadState()[@"disabledReason"] ?: @"unknown");
        return AevonGateBlockedDisabled;
    }

    // G2 — crash-loop breaker.
    double now = [NSDate date].timeIntervalSince1970;
    NSMutableDictionary *state = [AevonReadState() mutableCopy];
    double last = [state[@"lastAttempt"] doubleValue];
    int attempts = [state[@"attempts"] intValue];

    if (last <= 0.0 || (now - last) > kCrashWindow) attempts = 0;
    attempts += 1;

    state[@"attempts"] = @(attempts);
    state[@"lastAttempt"] = @(now);
    state[@"version"] = kAevonVersion;
    state[@"lastLoad"] = @(now);

    if (!AevonWriteState(state)) {
        // We cannot count attempts, so we cannot guarantee the breaker works.
        // Fail safe: stand down rather than risk an uncountable crash loop.
        AevonLog(@"gate G2: state not writable, standing down");
        return AevonGateBlockedUnwritable;
    }

    if (attempts > kMaxAttempts) {
        NSMutableDictionary *off = [AevonReadState() mutableCopy];
        off[@"disabled"] = @YES;
        off[@"disabledReason"] = @"auto:crash-loop";
        off[@"disabledAt"] = @(now);
        AevonWriteState(off);
        AevonLog(@"gate G2: %d unstable loads within %.0fs, self-disabled",
                 attempts, kCrashWindow);
        return AevonGateBlockedCrashLoop;
    }

    return AevonGatePass;
}

static void AevonScheduleStableReset(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStableDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (AevonDisabledActive()) return;   // never resurrect behind the operator's back
        NSMutableDictionary *state = [AevonReadState() mutableCopy];
        state[@"attempts"] = @0;
        state[@"stableSince"] = @([NSDate date].timeIntervalSince1970);
        AevonWriteState(state);
        AevonLog(@"heartbeat: %.0fs uptime reached, attempt counter cleared", kStableDelay);
    });
}

#pragma mark - Probe kit (read-only, no hooks)

static NSString *AevonEncodingOf(Class cls, NSString *selName) {
    if (!cls || !selName.length) return nil;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!m) return nil;
    const char *enc = method_getTypeEncoding(m);
    return enc ? @(enc) : @"?";
}

// Direct implementors only — inherited copies would list every subclass and
// tell us nothing about which class actually owns the method.
static NSArray<NSString *> *AevonDirectImplementors(NSString *selName, NSUInteger limit) {
    SEL sel = NSSelectorFromString(selName);
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return @[];

    Class *classes = (Class *)calloc((size_t)total, sizeof(Class));
    if (!classes) return @[];
    total = objc_getClassList(classes, total);

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (int i = 0; i < total && out.count < limit; i++) {
        unsigned int n = 0;
        Method *methods = class_copyMethodList(classes[i], &n);
        if (!methods) continue;
        for (unsigned int j = 0; j < n; j++) {
            if (method_getName(methods[j]) == sel) {
                [out addObject:NSStringFromClass(classes[i])];
                break;
            }
        }
        free(methods);
    }
    free(classes);
    return out;
}

static NSArray<NSString *> *AevonScenesDump(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSSet<UIScene *> *scenes = app.connectedScenes;
        [lines addObject:[NSString stringWithFormat:@"场景总数: %lu", (unsigned long)scenes.count]];

        NSInteger idx = 0;
        for (UIScene *scene in scenes) {
            idx++;
            NSString *cls = NSStringFromClass([scene class]);
            NSString *ident = @"?";
            id v = [scene valueForKey:@"_sceneIdentifier"];
            if ([v isKindOfClass:[NSString class]]) ident = v;

            NSUInteger windows = 0;
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windows = ((UIWindowScene *)scene).windows.count;
            }

            NSString *role = @"?";
            @try {
                id r = [scene.session valueForKey:@"role"];
                if ([r isKindOfClass:[NSString class]]) role = r;
            } @catch (__unused NSException *e) {}

            [lines addObject:[NSString stringWithFormat:
                @"%ld. %@  state=%ld  windows=%lu  role=%@\n     id=%@",
                (long)idx, cls, (long)scene.activationState,
                (unsigned long)windows, role, ident]];
        }
    } @catch (NSException *e) {
        [lines addObject:[NSString stringWithFormat:@"场景枚举失败: %@", e.reason]];
    }
    return lines;
}

static BOOL AevonWritable(NSString *dir) {
    NSString *probe = [dir stringByAppendingPathComponent:@".aevon-wtest"];
    NSData *d = [@"ok" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = [d writeToFile:probe atomically:YES];
    if (ok) [[NSFileManager defaultManager] removeItemAtPath:probe error:NULL];
    return ok;
}

static NSString *AevonBuildProbeReport(void) {
    NSMutableString *s = [NSMutableString string];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    UIDevice *dev = [UIDevice currentDevice];
    [s appendFormat:@"Aevon 探测报告\n"];
    [s appendFormat:@"生成: %@\n", [df stringFromDate:[NSDate date]]];
    [s appendFormat:@"版本: %@   进程: pid %d\n", kAevonVersion, getpid()];
    [s appendFormat:@"系统: %@ %@\n\n", dev.systemName, dev.systemVersion];

    [s appendString:@"[环境]\n"];
    NSString *jbroot = AevonBootstrapRoot();
    [s appendFormat:@"  越狱根（jbroot）    : %@\n", jbroot ?: @"未检测到"];
    [s appendFormat:@"  环境类型            : %@\n",
        ([jbroot.lastPathComponent hasPrefix:@".jbroot"]) ? @"roothide（随机路径）"
                                                          : (jbroot ? @"rootless（/var/jb）" : @"未知")];
    [s appendFormat:@"  日志目录可写        : %@\n",
        AevonWritable(kAevonLogDir) ? @"是" : @"否"];
    [s appendFormat:@"  状态文件            : %@\n\n", kAevonStatePath];

    [s appendString:@"[承载模型 · 方法签名]\n"];
    struct { const char *cls; const char *sel; } probe[] = {
        {"UIWindowScene", "_scene:interceptUpdateWithNewSettings:"},
        {"UIScene",       "_scene:interceptUpdateWithNewSettings:"},
        {"UIWindowScene", "_setDeactivationReasons:onScene:withSettings:reason:"},
        {"UIScene",       "_setDeactivationReasons:onScene:withSettings:reason:"},
        {"UIScenePresentationManager", "createPresenterWithIdentifier:priority:"},
        {"UIScenePresentationManager", "createPresenterWithIdentifier:"},
        {"UIWindowScene", "remoteKeyboardWindowForScreen:"},
        {"UIWindowScene", "_setShouldDeactivate:"},
        {"UIWindowScene", "setAnimationSettings:"},
    };
    for (size_t i = 0; i < sizeof(probe) / sizeof(probe[0]); i++) {
        NSString *selStr = @(probe[i].sel);
        Class c = NSClassFromString(@(probe[i].cls));
        NSString *enc = AevonEncodingOf(c, selStr);
        if (!c) {
            [s appendFormat:@"  %-28s %@ → 类不存在\n", probe[i].cls, selStr];
        } else if (enc) {
            [s appendFormat:@"  %-28s %@\n      ✓ %@\n", probe[i].cls, selStr, enc];
        } else {
            [s appendFormat:@"  %-28s %@\n      ✗ 未实现\n", probe[i].cls, selStr];
        }
    }
    [s appendFormat:@"  _UIContextLayerHostView 类     : %@\n",
        NSClassFromString(@"_UIContextLayerHostView") ? @"存在" : @"不存在"];
    [s appendFormat:@"  BSAnimationSettings 类        : %@\n\n",
        NSClassFromString(@"BSAnimationSettings") ? @"存在" : @"不存在"];

    [s appendString:@"[谁定义了这些方法]\n"];
    for (NSString *sel in @[@"_scene:interceptUpdateWithNewSettings:",
                            @"_setDeactivationReasons:onScene:withSettings:reason:",
                            @"remoteKeyboardWindowForScreen:",
                            @"createPresenterWithIdentifier:priority:"]) {
        NSArray *who = AevonDirectImplementors(sel, 6);
        [s appendFormat:@"  %@\n      %@\n", sel,
            who.count ? [who componentsJoinedByString:@", "] : @"（无）"];
    }
    [s appendString:@"\n"];

    [s appendString:@"[场景树]\n"];
    for (NSString *line in AevonScenesDump()) {
        [s appendFormat:@"  %@\n", line];
    }
    [s appendFormat:@"\n"];

    [s appendString:@"[判定]\n"];
    Class ws = NSClassFromString(@"UIWindowScene");
    BOOL hasIntercept = AevonEncodingOf(ws, @"_scene:interceptUpdateWithNewSettings:") != nil;
    [s appendFormat:@"  P1 直连是否可行 : %@\n",
        hasIntercept ? @"可以，签名见上（P1 开工前用它定 hook 返回值）"
                     : @"UIWindowScene 上没有该方法，需要另找承载入口"];
    [s appendFormat:@"  P1 父子关系线索 : 见场景树 windows 计数，App 主场景 windows=1 即已挂载\n"];

    return s;
}

static void AevonRunProbes(BOOL announce) {
    @autoreleasepool {
        NSString *report = AevonBuildProbeReport();

        [[NSFileManager defaultManager] createDirectoryAtPath:kAevonLogDir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [report writeToFile:kAevonProbeTxt atomically:YES
                   encoding:NSUTF8StringEncoding error:NULL];

        // Also publish through preferences: Settings is sandboxed on some
        // jailbreaks and cannot read /var/mobile directly. cfprefsd always works.
        AevonSetPref(@"probeText", report);
        AevonSetPref(@"probeTime", @([NSDate date].timeIntervalSince1970));

        AevonLog(@"probe: report generated (%lu lines)", (unsigned long)
                 [report componentsSeparatedByString:@"\n"].count);

        if (announce) notify_post(kAevonNoteProbeDone.UTF8String);
    }
}

#pragma mark - Darwin notifications (the Settings <-> SpringBoard channel)

static void AevonRespringNow(void) {
    for (NSArray<NSString *> *c in AevonRespringCandidates()) {
        NSString *path = c.firstObject;
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) continue;

        NSMutableArray *argv = [NSMutableArray arrayWithObject:path];
        [argv addObjectsFromArray:[c subarrayWithRange:NSMakeRange(1, c.count - 1)]];
        const char **cargv = (const char **)calloc(argv.count + 1, sizeof(char *));
        if (!cargv) continue;
        for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = [argv[i] UTF8String];
        pid_t pid = 0;
        int rc = posix_spawn(&pid, path.UTF8String, NULL, NULL, (char **)cargv, environ);
        free(cargv);
        if (rc == 0) {
            AevonLog(@"respring requested via %@", path);
            return;
        }
    }
    AevonLog(@"respring request failed: no usable helper");
}

static void AevonNoteCallback(__unused CFNotificationCenterRef center,
                              __unused void *observer,
                              CFStringRef name,
                              __unused const void *object,
                              __unused CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;

    if ([n isEqualToString:kAevonNoteReprobe]) {
        AevonRunProbes(YES);
    } else if ([n isEqualToString:kAevonNoteRespring]) {
        AevonRespringNow();
    } else if ([n isEqualToString:kAevonNoteReset]) {
        NSMutableDictionary *st = [AevonReadState() mutableCopy];
        st[@"attempts"] = @0;
        [st removeObjectForKey:@"disabledReason"];
        AevonWriteState(st);
        AevonLog(@"reset: attempt counter cleared from Settings");
    }
}

static void AevonObserveCommands(void) {
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *n in @[kAevonNoteReprobe, kAevonNoteRespring, kAevonNoteReset]) {
        CFNotificationCenterAddObserver(c, NULL, AevonNoteCallback,
                                        (__bridge CFStringRef)n, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

#pragma mark - Entry point

__attribute__((constructor))
static void AevonConstructor(void) {
    @autoreleasepool {
        if (AevonPassGates() != AevonGatePass) {
            return;  // absolutely nothing installed
        }

        AevonLog(@"boot ok: stage %d, version %@, pid %d",
                 AEVON_STAGE, kAevonVersion, getpid());

        AevonObserveCommands();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProbeDelay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            AevonRunProbes(NO);
        });

        // ------------------------------------------------------------------
        // Stage 1: still zero hooks. This build exists so the whole settings
        // surface is reachable from the GUI and so one install answers every
        // P1 question at once.
        // ------------------------------------------------------------------
#if AEVON_STAGE >= 2
        // P1 (scene mounting) is added here, never above the gate check.
#endif

        AevonScheduleStableReset();
    }
}
