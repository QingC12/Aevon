//
//  AevonPaths.h
//  Shared, header-only path + gate helpers.
//
//  Why this file exists:
//    The tweak runs inside SpringBoard (unsandboxed, may write /var/mobile).
//    The preference bundle runs inside Settings (sandboxed, may be refused).
//    Both must agree on "is Aevon stopped right now?". So the gate state has
//    TWO sources and the answer is the OR of them:
//
//      G0 = panic file exists  OR  pref(panic)   = true
//      G1 = state.disabled     OR  pref(disabled)= true
//
//    The pref side always works from Settings (cfprefsd does the write).
//    The file side always works from SpringBoard. Either one alone is enough
//    to stop the tweak, which is what makes the kill switch dependable.
//
//  Nothing in here installs a hook, spawns a process, or touches a system path.
//

#ifndef AEVON_PATHS_H
#define AEVON_PATHS_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// __attribute__((unused)) because this header is shared by two binaries and
// neither of them uses every constant. Harmless, and it keeps -Wall quiet.
#define AEVON_UNUSED __attribute__((unused))

static AEVON_UNUSED NSString *const kAevonDomain     = @"com.aevon.aevon";
static AEVON_UNUSED NSString *const kAevonStatePath  = @"/var/mobile/Library/Preferences/com.aevon.state.plist";
static AEVON_UNUSED NSString *const kAevonPanicPath  = @"/var/mobile/Library/Preferences/com.aevon.panic";
static AEVON_UNUSED NSString *const kAevonLogDir     = @"/var/mobile/Library/Logs/Aevon";
static AEVON_UNUSED NSString *const kAevonLogPath    = @"/var/mobile/Library/Logs/Aevon/aevon.log";
static AEVON_UNUSED NSString *const kAevonProbeTxt   = @"/var/mobile/Library/Logs/Aevon/probe.txt";
static AEVON_UNUSED NSString *const kAevonProbePlist = @"/var/mobile/Library/Logs/Aevon/probe.plist";

// Darwin notifications: the only channel between Settings and SpringBoard.
static AEVON_UNUSED NSString *const kAevonNoteReprobe   = @"com.aevon.reprobe";
static AEVON_UNUSED NSString *const kAevonNoteRespring  = @"com.aevon.respring";
static AEVON_UNUSED NSString *const kAevonNoteReset     = @"com.aevon.reset";
static AEVON_UNUSED NSString *const kAevonNoteProbeDone = @"com.aevon.probe.done";

#pragma mark - Preferences (works from both processes)

static inline id AevonPrefValue(NSString *key) {
    if (key.length == 0) return nil;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kAevonDomain);
    return v ? (__bridge_transfer id)v : nil;
}

static inline BOOL AevonPrefBool(NSString *key) {
    id v = AevonPrefValue(key);
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return NO;
}

static inline void AevonSetPref(NSString *key, id value) {
    if (key.length == 0) return;
    if (value) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)kAevonDomain);
    } else {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                 (__bridge CFStringRef)kAevonDomain);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kAevonDomain);
}

#pragma mark - State file

static inline NSDictionary *AevonReadState(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kAevonStatePath];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

// Returns NO when the file could not be written. Callers must treat that as
// "I cannot guarantee the breaker works" and fail safe.
static inline BOOL AevonWriteState(NSDictionary *state) {
    NSString *dir = [kAevonStatePath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [state writeToFile:kAevonStatePath atomically:YES];
}

#pragma mark - Gates

static inline BOOL AevonPanicActive(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:kAevonPanicPath]) return YES;
    return AevonPrefBool(@"panic");
}

static inline BOOL AevonDisabledActive(void) {
    if ([AevonReadState()[@"disabled"] boolValue]) return YES;
    return AevonPrefBool(@"disabled");
}

static inline void AevonSetPanic(BOOL on) {
    AevonSetPref(@"panic", on ? @YES : nil);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (on) {
        [fm createDirectoryAtPath:[kAevonPanicPath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSData data] writeToFile:kAevonPanicPath atomically:YES];  // best effort
    } else {
        [fm removeItemAtPath:kAevonPanicPath error:NULL];
    }
}

static inline void AevonSetDisabled(BOOL on, NSString *reason) {
    AevonSetPref(@"disabled", on ? @YES : nil);
    NSMutableDictionary *s = [AevonReadState() mutableCopy];
    s[@"disabled"] = @(on);
    if (on) {
        s[@"disabledReason"] = reason ?: @"manual";
        s[@"disabledAt"] = @([NSDate date].timeIntervalSince1970);
    } else {
        [s removeObjectForKey:@"disabledReason"];
        [s removeObjectForKey:@"disabledAt"];
        s[@"attempts"] = @0;   // re-arming also clears the crash counter
    }
    AevonWriteState(s);
}

static inline NSString *AevonGateDescription(void) {
    if (AevonPanicActive())    return @"已紧急停止（G0）";
    if (AevonDisabledActive()) return @"已暂停注入（G1）";
    NSDictionary *s = AevonReadState();
    if ([s[@"disabledReason"] isEqual:@"auto:crash-loop"]) return @"已自动停用（G2）";
    return @"运行中";
}

#pragma mark - Small helpers

static inline NSString *AevonFormatTime(NSTimeInterval ts) {
    if (ts <= 0) return @"—";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

#endif /* AEVON_PATHS_H */
