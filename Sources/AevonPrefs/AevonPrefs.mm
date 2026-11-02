//
//  AevonPrefs.mm
//  Aevon preference bundle — Stage 1: the full settings surface.
//
//  Design notes
//  ------------
//  1. Every setting row comes from a plist (see tools/gen-settings.py). That
//     keeps the UI and the delivery document generated from one table, so they
//     cannot drift apart.
//  2. The three rows that are *actually* functional (state, G0, G1) are driven
//     by readPreferenceValue:/setPreferenceValue: overrides. They never write a
//     setting into the defaults domain — they act on real files/prefs.
//  3. This bundle is a separate process from SpringBoard. It can be opened even
//     when the tweak has switched itself off, which is the whole point: the kill
//     switch must be reachable from the GUI, not from a terminal.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import "AevonPaths.h"

extern char **environ;

#pragma mark - Private framework surface (declared, not linked)
//
// We deliberately do NOT link Preferences.framework: it is already loaded in the
// Settings process, and linking it would only add an install-time dependency.

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(id)specifier;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (void)setTarget:(id)target;
@end

#pragma mark - Helpers

static NSString *AevonProbeText(void) {
    id v = AevonPrefValue(@"probeText");
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    NSString *s = [NSString stringWithContentsOfFile:kAevonProbeTxt
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    return s.length ? s : nil;
}

static BOOL AevonSpawn(NSString *path, NSArray<NSString *> *args) {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) return NO;

    NSMutableArray *argv = [NSMutableArray arrayWithObject:path];
    [argv addObjectsFromArray:args];

    const char **cargv = (const char **)calloc(argv.count + 1, sizeof(char *));
    if (!cargv) return NO;
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = [argv[i] UTF8String];

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.UTF8String, NULL, NULL, (char **)cargv, environ);
    free(cargv);
    return rc == 0;
}

// Settings runs sandboxed on some jailbreaks, so an exec may simply be refused.
// We try the usual suspects and let the caller decide what to say when all fail.
static BOOL AevonTryRespringExec(void) {
    NSArray<NSArray<NSString *> *> *candidates = @[
        @[@"/var/jb/usr/bin/sbreload"],
        @[@"/usr/bin/sbreload"],
        @[@"/var/jb/usr/bin/killall", @"-9", @"SpringBoard"],
        @[@"/usr/bin/killall", @"-9", @"SpringBoard"],
    ];
    for (NSArray<NSString *> *c in candidates) {
        if (AevonSpawn(c.firstObject, [c subarrayWithRange:NSMakeRange(1, c.count - 1)])) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Read-only report viewer

@interface AevonReportController : UIViewController
@property (nonatomic, copy) NSString *report;
@end

@implementation AevonReportController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"探测报告";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.textContainerInset = UIEdgeInsetsMake(16, 14, 24, 14);
    tv.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    tv.text = self.report.length ? self.report : @"还没有探测报告。";
    [self.view addSubview:tv];
}

@end

#pragma mark - Root controller

@interface AevonRootListController : PSListController
@end

@implementation AevonRootListController

#pragma mark Reading values

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:[NSString class]]) return [super readPreferenceValue:specifier];

    if ([key isEqualToString:@"@status.state"])   return AevonGateDescription();
    if ([key isEqualToString:@"@status.version"]) {
        id v = AevonReadState()[@"version"];
        return v ? v : @"未加载";
    }
    if ([key isEqualToString:@"@status.loads"]) {
        id v = AevonReadState()[@"attempts"];
        return v ? [v stringValue] : @"—";
    }
    if ([key isEqualToString:@"@status.last"]) {
        return AevonFormatTime([AevonReadState()[@"lastLoad"] doubleValue]);
    }

    if ([key isEqualToString:@"!gate.panic"])    return @(AevonPanicActive());
    if ([key isEqualToString:@"!gate.disabled"]) return @(AevonDisabledActive());

    return [super readPreferenceValue:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    if ([key isEqualToString:@"!gate.panic"] || [key isEqualToString:@"!gate.disabled"]) {
        BOOL on = [value boolValue];

        if ([key isEqualToString:@"!gate.panic"]) {
            AevonSetPanic(on);
        } else {
            AevonSetDisabled(on, @"manual:settings");
        }

        // Gates are read at load time, so a running SpringBoard is unaffected
        // until it reloads. Say so instead of pretending it took effect.
        [self reloadSpecifiers];
        return;
    }

    [super setPreferenceValue:value specifier:specifier];
}

#pragma mark Lifecycle

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];   // status rows are live data, refresh on entry
}

#pragma mark Actions

- (void)clearAttempts:(__unused PSSpecifier *)specifier {
    NSMutableDictionary *s = [AevonReadState() mutableCopy];
    s[@"attempts"] = @0;
    [s removeObjectForKey:@"disabledReason"];
    if (AevonDisabledActive()) s[@"disabled"] = @NO;
    AevonWriteState(s);
    AevonSetPref(@"disabled", nil);
    notify_post(kAevonNoteReset.UTF8String);   // SpringBoard clears its own copy too
    [self reloadSpecifiers];
    [self aevonAlert:@"已清除" message:@"崩溃计数归零。若之前是自动停用，现在可以重载桌面重新加载。"];
}

- (void)respring:(__unused PSSpecifier *)specifier {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"重载桌面"
                                            message:@"桌面会重启约 5–10 秒。若 Aevon 已停止，重启后不会加载任何 hook。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"重载" style:UIAlertActionStyleDestructive
                                        handler:^(__unused UIAlertAction *a) {
        [weakSelf aevonRequestRespring];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)reprobe:(__unused PSSpecifier *)specifier {
    notify_post(kAevonNoteReprobe.UTF8String);

    // The probe runs in SpringBoard and publishes back through preferences.
    // 1.2s is generous for an in-process scan; if nothing came back we say so
    // rather than spinning.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self reloadSpecifiers];
        NSString *t = AevonProbeText();
        if (t.length) {
            [self aevonAlert:@"探测完成" message:[NSString stringWithFormat:
                @"已更新，共 %lu 行。", (unsigned long)[t componentsSeparatedByString:@"\n"].count]];
        } else {
            [self aevonAlert:@"没有响应"
                     message:@"桌面里没有 Aevon 在运行（可能处于 G0/G1 停止状态），"
                             @"所以探针无法执行。请先关闭闸门并重载桌面。"];
        }
    });
}

- (void)showProbe:(__unused PSSpecifier *)specifier {
    NSString *t = AevonProbeText();
    if (!t.length) {
        [self aevonAlert:@"还没有报告" message:@"点「重新探测」即可生成，不需要重启。"];
        return;
    }
    AevonReportController *vc = [[AevonReportController alloc] init];
    vc.report = t;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)copyProbe:(__unused PSSpecifier *)specifier {
    NSString *t = AevonProbeText();
    if (!t.length) {
        [self aevonAlert:@"还没有报告" message:@"先点「重新探测」。"];
        return;
    }
    [UIPasteboard generalPasteboard].string = t;
    [self aevonAlert:@"已复制" message:@"报告已放进剪贴板，可直接粘到任何地方。"];
}

#pragma mark Small utilities

- (void)aevonAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:title message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)aevonRequestRespring {
    // Preferred path: ask the tweak itself (it lives in SpringBoard and is not
    // sandboxed). It works whenever Aevon is active, which covers every case
    // except "I just turned it off and want it back", where exec is the fallback.
    notify_post(kAevonNoteRespring.UTF8String);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Still alive means the in-process request did not land.
        if (!AevonTryRespringExec()) {
            [self aevonAlert:@"无法自动重载"
                     message:@"当前环境不允许从设置里重启桌面。"
                             @"请用越狱工具自带的重启按钮，或手动注销一次。"];
        }
    });
}

@end
