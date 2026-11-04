//
//  AevonAppHook.m — Aevon 0.0.44, the second injection point.
//
//  Why this file exists at all. A card in SpringBoard hosts another app's
//  scene; SpringBoard paints it, but SpringBoard is *not* that app. Up to
//  0.0.43 every attempt to make the picture usable was made on the host side —
//  the hit test (proved correct: `event hit -> _UISceneLayerHostContainerView`),
//  the foreground settings write (proved landed: `push path=3 wrote=1 fg=1`),
//  the container's own forwarding. All of them worked, and taps inside the card
//  still did nothing.
//
//  The missing half is in the app's own process. An app launched in the
//  background keeps `UIApplication.applicationState == .background` and
//  `UIScene.activationState == .background`, and UIKit drops touch events that
//  arrive in that state — it does not matter that the touches were forwarded
//  correctly, or that the picture is being rendered and even playing audio. The
//  app is awake, drawing, and refusing input because of a flag only it can see.
//
//  0.0.44 answers that flag. The signal is one the host side already writes and
//  the app can read for itself: the scene's own settings say `isForeground = 1`
//  while `applicationState` still says background. That pair can only mean "a
//  window of another process is showing me", because a real foreground app has
//  both agreeing. When the pair disagrees, this file reports the state the
//  picture implies: active.
//
//  Deliberate limits:
//
//    · Nothing runs before the pref allows it ("!ring.appHook", default on).
//    · SpringBoard itself is skipped — the first injection point already covers
//      that process and must not be double-hooked.
//    · Both getters chain to the original. If the hosted pair is not detected,
//      behaviour is exactly the system's own.
//    · One log line per process, and only when a promotion actually happened.
//      Every app on the phone loads this dylib; a logger without a gate would
//      cost more than the feature.
//
//  Not in Swift on purpose: this loads into every app process on the device.
//  The Swift runtime is several megabytes of resident pages that a 40-line
//  state bridge has no use for.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <time.h>
#include <dispatch/dispatch.h>

static CFStringRef const AevonDomain = CFSTR("com.aevon");
static CFStringRef const AevonKey = CFSTR("!ring.appHook");

static IMP AevonOriginalApplicationState = NULL;
static IMP AevonOriginalActivationState = NULL;
static int AevonGate = -1;      // -1 unknown, 0 off, 1 on
static int AevonLogged = 0;

/// The switch in Settings. Absent means on: the feature is the reason the card
/// exists, and a card that cannot be touched is not a feature.
static BOOL AevonAppHookAllowed(void) {
    if (AevonGate >= 0) return AevonGate == 1;
    AevonGate = 1;
    CFPropertyListRef value = CFPreferencesCopyAppValue(AevonKey, AevonDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            AevonGate = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int flag = 0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &flag);
            AevonGate = flag ? 1 : 0;
        }
        CFRelease(value);
    }
    return AevonGate == 1;
}

/// The scene's settings, however this iOS spells the accessor. `settings` is
/// what `UIScene` answers on 17; `_sceneSettings` and the FBSScene's own
/// `settings` are the older shapes. Each read is guarded, because a KVC miss on
/// a private key raises rather than returning nil — and this runs in every app
/// on the phone.
static id AevonTryValue(id object, NSString *key) {
    if (object == nil) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

static id AevonSceneSettings(UIScene *scene) {
    id settings = AevonTryValue(scene, @"settings");
    if (settings != nil) return settings;
    settings = AevonTryValue(scene, @"_sceneSettings");
    if (settings != nil) return settings;
    id core = AevonTryValue(scene, @"_FBSScene");
    if (core == nil) core = AevonTryValue(scene, @"_scene");
    return AevonTryValue(core, @"settings");
}

static BOOL AevonFlag(id object, NSString *key) {
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:[NSNumber class]] && [value boolValue];
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

/// The host's own mark. `Aevon.hostedPath`, written when a card opens and
/// deleted when it closes. Read at most once a second, and only while the app
/// is answering "background", so an idle app pays a stat per second at worst.
///
/// This exists next to the scene-settings test below because the two can
/// disagree: the settings write is a message to FrontBoard and the app's own
/// copy of the settings is a different object. The file is the copy both
/// processes are guaranteed to see the same way.
static BOOL AevonMarkSaysHosted(void) {
    static BOOL answer = NO;
    static CFAbsoluteTime stamp = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (stamp > 0 && now - stamp < 1.0) return answer;
    stamp = now;
    answer = NO;
    NSDictionary *mark = [NSDictionary dictionaryWithContentsOfFile:
                          @"/var/mobile/Library/Logs/Aevon/hosted.plist"];
    if (mark == nil) return answer;
    NSString *bundle = [mark objectForKey:@"bundle"];
    NSNumber *since = [mark objectForKey:@"ts"];
    NSString *mine = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle == nil || mine == nil || since == nil) return answer;
    if (![bundle isEqualToString:mine]) return answer;
    // Ten minutes is the card's own cap; a mark older than that is a process
    // that died holding it, and honouring it would leave an app believing it is
    // on screen forever.
    answer = (now - [since doubleValue]) < 600.0;
    return answer;
}

/// "Another process is showing one of my scenes." The host side writes exactly
/// this pair (`AevonWriteFront` sets isForeground, clears isBackgrounded), so
/// the test costs two KVC reads on a value that is already in memory.
static BOOL AevonHosted(void) {
    if (!AevonAppHookAllowed()) return NO;
    if (AevonMarkSaysHosted()) return YES;
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return NO;
    for (UIScene *scene in [application connectedScenes]) {
        id settings = AevonSceneSettings(scene);
        if (settings == nil) continue;
        if (AevonFlag(settings, @"isForeground") && !AevonFlag(settings, @"isBackgrounded")) {
            return YES;
        }
    }
    return NO;
}

/// One line per process, appended the same way every other Aevon line is
/// written: plain text, one file, tail -f. Timestamped because this file is
/// shared with SpringBoard and the interleaving is the interesting part.
static void AevonNote(const char *what) {
    if (AevonLogged) return;
    AevonLogged = 1;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    time_t now = time(NULL);
    struct tm stamp;
    localtime_r(&now, &stamp);
    char line[320];
    snprintf(line, sizeof(line),
             "%04d-%02d-%02d %02d:%02d:%02d app: promoted %s (%s) — "
             "hosted scene claims foreground, so the app reports active\n",
             stamp.tm_year + 1900, stamp.tm_mon + 1, stamp.tm_mday,
             stamp.tm_hour, stamp.tm_min, stamp.tm_sec,
             [bundle UTF8String] ?: "?", what);
    FILE *file = fopen("/var/mobile/Aevon.log", "a");
    if (file != NULL) {
        fputs(line, file);
        fclose(file);
    }
}

// MARK: - 0.0.63 几何量尺（App 这一侧）
//
// Aevon(55) 里唯一说不清的是抖音：视频在中上、下面一大片纯 #333。宿主侧的读数
// 已经全部一致 —— `win: fat scene ratio=1.667 … render=430x717`、
// `win: scene frame after=430x717`、`win: hosted bounds after=430x717` —— 三行
// 说的是同一件事：窗口确实是 430x717，那片灰不是我们裁出来的。剩下唯一没量过
// 的是 **App 自己怎么理解这块屏幕**：`UIScreen` 还是 430x932 吗？key window
// 多大？播放器那一层挂在哪个坐标里？这三件事只有 App 进程答得出，所以量尺放在
// 这里而不是宿主那一侧。
//
// 只在「这块卡里正在演我」时量（`AevonHosted`），每个进程两次（1.2 s / 3.2 s），
// 一次十行左右。诊断完就撤 —— 这不是常驻功能。

static void AevonGeomWrite(const char *body) {
    char line[512];
    time_t now = time(NULL);
    struct tm stamp;
    localtime_r(&now, &stamp);
    snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d app: geom %s\n",
             stamp.tm_year + 1900, stamp.tm_mon + 1, stamp.tm_mday,
             stamp.tm_hour, stamp.tm_min, stamp.tm_sec, body);
    FILE *file = fopen("/var/mobile/Aevon.log", "a");
    if (file != NULL) {
        fputs(line, file);
        fclose(file);
    }
}

/// 一行汇总 + 两层视图。汇总回答「App 以为屏幕多大」，视图那几行回答「播放器
/// 和底栏各自在哪个坐标里」—— 抖音那个「视频在中上、下面是纯 #333」只要类名
/// 和 frame 对得上，就不必再猜。
static void AevonDumpGeometry(const char *tag) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return;
    UIScreen *screen = [UIScreen mainScreen];
    CGRect box = screen != nil ? [screen bounds] : CGRectZero;
    NSArray *windows = [application windows];
    UIWindow *key = nil;
    for (UIWindow *one in windows) {
        if ([one isKeyWindow]) { key = one; break; }
    }
    if (key == nil && windows.count > 0) key = [windows objectAtIndex:0];
    CGRect win = key != nil ? [key frame] : CGRectZero;
    UIEdgeInsets safe = key != nil ? [key safeAreaInsets] : UIEdgeInsetsZero;
    UIViewController *root = key != nil ? [key rootViewController] : nil;
    UIView *rootView = root != nil ? [root view] : nil;
    CGRect view = rootView != nil ? [rootView frame] : CGRectZero;
    CGRect space = CGRectZero;
    for (UIScene *one in [application connectedScenes]) {
        id value = AevonTryValue(AevonTryValue(one, @"coordinateSpace"), @"bounds");
        if ([value isKindOfClass:[NSValue class]]) {
            [value getValue:&space size:sizeof(space)];
            break;
        }
    }
    char body[400];
    snprintf(body, sizeof(body),
             "%s screen=%.0fx%.0f@%.0f scene=%.0fx%.0f win=%.0fx%.0f "
             "root=%.0fx%.0f safe=%.0f/%.0f",
             tag, box.size.width, box.size.height,
             screen != nil ? [screen scale] : 0,
             space.size.width, space.size.height,
             win.size.width, win.size.height,
             view.size.width, view.size.height,
             safe.top, safe.bottom);
    AevonGeomWrite(body);
    if (key == nil) return;
    NSArray *subs = [key subviews];
    UIView *biggest = nil;
    CGFloat area = -1;
    NSUInteger count = subs.count < 8 ? subs.count : 8;
    for (NSUInteger i = 0; i < count; i++) {
        UIView *one = [subs objectAtIndex:i];
        CGRect f = [one frame];
        snprintf(body, sizeof(body), "%s sub=%lu %s %.0f,%.0f,%.0fx%.0f",
                 tag, (unsigned long)i, class_getName([one class]),
                 f.origin.x, f.origin.y, f.size.width, f.size.height);
        AevonGeomWrite(body);
        CGFloat a = f.size.width * f.size.height;
        if (a > area) { area = a; biggest = one; }
    }
    if (biggest == nil) return;
    NSArray *kids = [biggest subviews];
    NSUInteger kids2 = kids.count < 6 ? kids.count : 6;
    for (NSUInteger i = 0; i < kids2; i++) {
        UIView *one = [kids objectAtIndex:i];
        CGRect f = [one frame];
        snprintf(body, sizeof(body), "%s in=%s:%lu %s %.0f,%.0f,%.0fx%.0f",
                 tag, class_getName([biggest class]), (unsigned long)i,
                 class_getName([one class]),
                 f.origin.x, f.origin.y, f.size.width, f.size.height);
        AevonGeomWrite(body);
    }
}

/// 不用 block：这个文件是编进每个 App 的纯 ObjC，`dispatch_after` 的函数指针
/// 版本同样便宜，而且不必指望构建参数里一定开着 `-fblocks`。
///
/// 两个标签用可写的静态数组而不是字符串字面量：`(void *)"early"` 那一下是
/// `const char *` → `void *`，编译器会因 -Wcast-qual 报警，而这两个字每台机器
/// 只写两次，不值得为省几个字节换一条警告。
static char AevonGeomEarly[] = "early";
static char AevonGeomLate[] = "late";

static void AevonGeomTick(void *context) {
    AevonDumpGeometry((const char *)context);
}

static void AevonScheduleGeometry(void) {
    static int scheduled = 0;
    if (scheduled) return;
    scheduled = 1;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), (void *)AevonGeomEarly, AevonGeomTick);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.2 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), (void *)AevonGeomLate, AevonGeomTick);
}

/// `UIApplicationStateActive`. UIKit checks this before it lets a window see
/// touches, so this is the flag that has to agree with the picture.
///
/// The original answer is asked first, and anything but "background" is handed
/// back untouched: a foreground app — or one that is merely inactive under a
/// system overlay — keeps the state the system gave it. Only the backgrounded
/// case with a hosted scene is rewritten, which is why the KVC scan below is
/// also paid only in that case.
static NSInteger AevonApplicationState(id self, SEL _cmd) {
    NSInteger state = ((NSInteger (*)(id, SEL))AevonOriginalApplicationState)(self, _cmd);
    if (state != 2) return state;              // not UIApplicationStateBackground
    if (AevonHosted()) {
        AevonNote("applicationState");
        AevonScheduleGeometry();
        return 0;                              // UIApplicationStateActive
    }
    return state;
}

/// `UISceneActivationStateForegroundActive`. Same reason, one layer down: the
/// scene's own activation state is what a view controller consults when it
/// refuses to handle an event — and `2` is `UISceneActivationStateBackground`.
static NSInteger AevonActivationState(id self, SEL _cmd) {
    NSInteger state = ((NSInteger (*)(id, SEL))AevonOriginalActivationState)(self, _cmd);
    if (state != 2) return state;
    if (AevonHosted()) {
        AevonNote("activationState");
        AevonScheduleGeometry();
        return 0;                              // UISceneActivationStateForegroundActive
    }
    return state;
}

__attribute__((constructor))
static void AevonAppBoot(void) {
    // SpringBoard has the first injection point, which owns this process. Two
    // hooks on one getter is one hook too many.
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundle isEqualToString:@"com.apple.springboard"]) return;

    // Both getters, both chained: a process that is not hosted keeps the
    // system's answers byte for byte.
    Method state = class_getInstanceMethod([UIApplication class],
                                          sel_registerName("applicationState"));
    if (state != NULL) {
        AevonOriginalApplicationState = method_getImplementation(state);
        method_setImplementation(state, (IMP)AevonApplicationState);
    }
    Method activation = class_getInstanceMethod([UIScene class],
                                               sel_registerName("activationState"));
    if (activation != NULL) {
        AevonOriginalActivationState = method_getImplementation(activation);
        method_setImplementation(activation, (IMP)AevonActivationState);
    }
}
