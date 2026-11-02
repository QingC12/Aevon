//
//  Aevon.mm
//  Aevon — Stage 0 safety skeleton
//
//  Design invariant (DO NOT BREAK):
//    This dylib must never be able to prevent the device from booting.
//    It only ever touches /var/mobile/Library/{Preferences,Logs}/com.aevon.*
//    and it installs ZERO hooks at Stage 0.
//
//  Gate order (all must pass before anything is executed):
//    G0  panic file        /var/mobile/Library/Preferences/com.aevon.panic
//    G1  auto-disable flag  state.plist -> disabled = true
//    G2  crash-loop breaker state.plist -> attempts > kMaxAttempts
//
//  If any gate blocks, this constructor returns without doing anything.
//  That means: no hooks, no swizzles, no timers, no windows. Zero effect.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

#ifndef AEVON_STAGE
#define AEVON_STAGE 0
#endif

static NSString *const kAevonVersion = @"0.0.1";

// ---------------------------------------------------------------------------
// Paths. Under a rootless jailbreak the process still sees the real /var,
// so these are absolute device paths, not jailbreak-root-relative ones.
// ---------------------------------------------------------------------------
static NSString *const kPrefsDir  = @"/var/mobile/Library/Preferences";
static NSString *const kStatePath = @"/var/mobile/Library/Preferences/com.aevon.state.plist";
static NSString *const kPanicPath = @"/var/mobile/Library/Preferences/com.aevon.panic";
static NSString *const kLogDir    = @"/var/mobile/Library/Logs/Aevon";
static NSString *const kLogPath   = @"/var/mobile/Library/Logs/Aevon/aevon.log";

// ---------------------------------------------------------------------------
// Tunables. Keep these conservative: a false positive only means "tweak
// switched itself off", a false negative means "one more crash loop".
// ---------------------------------------------------------------------------
static const int      kMaxAttempts   = 3;      // consecutive unstable loads
static const double   kCrashWindow   = 300.0;  // seconds; older attempts expire
static const double   kStableDelay   = 60.0;   // seconds alive => considered OK
static const unsigned long long kLogCap = 96ULL * 1024ULL;

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
    if (![fm fileExistsAtPath:kLogDir]) {
        [fm createDirectoryAtPath:kLogDir withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:kLogPath error:NULL];
    if (attrs && [attrs fileSize] > kLogCap) {
        [fm removeItemAtPath:kLogPath error:NULL];
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [df stringFromDate:[NSDate date]], kAevonVersion, message];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {
            // never let logging take the process down
        }
    } else {
        [line writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
}

#pragma mark - State

static NSMutableDictionary *AevonLoadState(void) {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if ([raw isKindOfClass:[NSDictionary class]]) {
        return [raw mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

static BOOL AevonSaveState(NSDictionary *state) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kPrefsDir]) {
        [fm createDirectoryAtPath:kPrefsDir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return [state writeToFile:kStatePath atomically:YES];
}

#pragma mark - Gates

// Returns YES when it is safe to continue. Writes the attempt counter as the
// very first side effect so that a crash *after* this point is still counted
// on the next load.
static BOOL AevonPassGates(AevonGate *gateOut) {
    AevonGate gate = AevonGatePass;
    NSFileManager *fm = [NSFileManager defaultManager];

    // G0 — hard kill switch. Any file manager can create this file.
    if ([fm fileExistsAtPath:kPanicPath]) {
        *gateOut = AevonGateBlockedPanic;
        AevonLog(@"gate G0: panic file present, standing down (zero hooks)");
        return NO;
    }

    NSMutableDictionary *state = AevonLoadState();

    // G1 — operator/auto disable flag.
    if ([state[@"disabled"] boolValue]) {
        *gateOut = AevonGateBlockedDisabled;
        AevonLog(@"gate G1: disabled=%@ reason=%@",
                 @YES, state[@"disabledReason"] ?: @"unknown");
        return NO;
    }

    // G2 — crash-loop breaker.
    double now = [NSDate date].timeIntervalSince1970;
    double last = [state[@"lastAttempt"] doubleValue];
    int attempts = [state[@"attempts"] intValue];

    if (last <= 0.0 || (now - last) > kCrashWindow) {
        attempts = 0;  // previous failure window expired, start clean
    }
    attempts += 1;

    state[@"attempts"] = @(attempts);
    state[@"lastAttempt"] = @(now);
    state[@"version"] = kAevonVersion;
    state[@"lastLoad"] = @(now);

    BOOL saved = AevonSaveState(state);
    if (!saved) {
        // We cannot count attempts, so we cannot guarantee the breaker works.
        // Fail safe: log and stand down rather than risk an uncountable loop.
        *gateOut = AevonGateBlockedUnwritable;
        AevonLog(@"gate G2: state not writable, standing down to avoid an uncountable crash loop");
        return NO;
    }

    if (attempts > kMaxAttempts) {
        NSMutableDictionary *off = AevonLoadState();
        off[@"disabled"] = @YES;
        off[@"disabledReason"] = @"auto:crash-loop";
        off[@"disabledAt"] = @(now);
        AevonSaveState(off);
        *gateOut = AevonGateBlockedCrashLoop;
        AevonLog(@"gate G2: %d unstable loads within %.0fs, self-disabled", attempts, kCrashWindow);
        return NO;
    }

    *gateOut = AevonGatePass;
    return YES;
}

// Once we survive long enough in a live SpringBoard, the counter is cleared.
// Nothing breaks if this never fires — it only means gate G2 keeps a shorter
// memory of past attempts.
static void AevonScheduleStableReset(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStableDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary *state = AevonLoadState();
        if ([state[@"disabled"] boolValue]) {
            return;  // never resurrect ourselves behind the operator's back
        }
        state[@"attempts"] = @0;
        state[@"stableSince"] = @([NSDate date].timeIntervalSince1970);
        AevonSaveState(state);
        AevonLog(@"heartbeat: %.0fs uptime reached, attempt counter cleared", kStableDelay);
    });
}

#pragma mark - Entry point

__attribute__((constructor))
static void AevonConstructor(void) {
    @autoreleasepool {
        AevonGate gate = AevonGatePass;
        if (!AevonPassGates(&gate)) {
            return;  // absolutely nothing installed
        }

        AevonLog(@"boot ok: stage %d, version %@, pid %d",
                 AEVON_STAGE, kAevonVersion, getpid());

        // ------------------------------------------------------------------
        // Stage 0: intentionally empty. The only job of this build is to prove
        // that injection works and that every gate behaves, without touching
        // SpringBoard's behaviour in any way.
        // ------------------------------------------------------------------
#if AEVON_STAGE >= 1
        // P1 (scene mounting) is added here, never above the gate check.
#endif

        AevonScheduleStableReset();
    }
}
