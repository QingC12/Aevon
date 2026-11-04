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

#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
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

// MARK: - 0.0.65 「这一版代码在这个进程里吗」
//
// Aevon(57) 里有一个只靠读日志就能下的结论：`app: promoted` 对设置和 Sileo
// 都出现过，对抖音一次都没有 —— 那两次进程是刚启动的，抖音那一个是**旧进程**，
// 它是在这份 dylib 落到磁盘之前起来的，所以本文件根本不在它里面。宿主侧看
// 不出来（scene 照样出现、画面照样有），于是「改了没效果」会被记成 bug。
//
// 这里让每个进程启动时留一张名片（bundle + pid），宿主在开窗前核对一次：
// 名片在、pid 还活着 ⇒ 这个进程有这一版代码；否则说明它是旧进程，宿主先把
// 它结束掉，再用挂起启动重新拉起一个干净的 —— 只有新进程才会带上这里的一切
// （包括下面的屏幕补丁）。
//
// 代价是一行文件写入，发生在进程启动那一下。收益是「有没有装上」不再是猜的。

static NSString *const AevonBridgeDir = @"/var/mobile/Library/Logs/Aevon/bridge";

static void AevonBridgeMark(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return;
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:AevonBridgeDir withIntermediateDirectories:YES
                      attributes:nil error:NULL];
    NSDictionary *mark = @{ @"pid": @(getpid()),
                            @"ts": @([[NSDate date] timeIntervalSince1970]) };
    NSString *path = [AevonBridgeDir stringByAppendingPathComponent:
                      [bundle stringByAppendingPathExtension:@"plist"]];
    [mark writeToFile:path atomically:YES];
}

// MARK: - 0.0.65 屏幕尺寸（App 这一侧）
//
// Aevon(57) 的量尺把问题摊成两行，同一个进程、同一时刻：
//
//   app: geom early screen=430x932@3 scene=430x717 win=430x717 root=430x717
//
// 窗口、根视图、scene 的坐标空间都是 717，而 `UIScreen` 还是 932。也就是说
// **App 里有两块屏幕**：按 scene/window 布局的代码拿到 717（所以顶栏、底栏都
// 排好了），按 `UIScreen` 布局的代码拿到 932（所以抖音的整页、翻页步长、播放器
// 那一层都按 932 算）。一块 932 高的页面塞进 717 的窗口里，必然「视频偏上、
// 下面一截是它自己的底色」，翻页步长又比窗口高 215 pt，于是能看到两段视频。
//
// 母本同一个位置也有一手：她的 App 侧 dylib（SthenoKeyboard，过滤 com.apple.UIKit）
// 的选择子里同时有 `mainScreen` / `bounds` / `_boundsForInterfaceOrientation:` /
// `setBounds:` / `setFrame:` / `setTransform:` —— 她同样在 App 进程里改屏幕。
//
// 做法：只在这块卡里演我时（scene 自己的 settings 说 foreground），把主屏的
// `bounds` / `_referenceBounds` / `_boundsForInterfaceOrientation:` 换成 scene
// 坐标空间的那块尺寸。别的进程、别的时刻，一个字节都不改。
//
// 只改「读」：`nativeBounds`、`scale`、`brightness` 都不动 —— 那些是硬件量，
// 改了只会让画面分辨率对不上。

static IMP AevonOriginalScreenBounds = NULL;
static IMP AevonOriginalScreenRef = NULL;
static IMP AevonOriginalScreenOriented = NULL;
static void AevonGeomWrite(const char *body);   // 定义在下面量尺那一段
static int AevonScreenHits = 0;
static int AevonScreenLogged = 0;
static int AevonScreenBusy = 0;
static CGRect AevonScreenTarget = { { 0, 0 }, { 0, 0 } };
static CFAbsoluteTime AevonScreenStamp = 0;

/// 这块卡里正在演我的那块屏幕有多大。0.4 秒一次缓存：`bounds` 是 App 里被
/// 调用最频繁的 getter 之一，每一帧都去翻 connectedScenes 是不行的。
static CGRect AevonHostedScreenSize(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonScreenStamp > 0 && now - AevonScreenStamp < 0.4) return AevonScreenTarget;
    AevonScreenStamp = now;
    AevonScreenTarget = CGRectZero;
    if (AevonScreenBusy) return AevonScreenTarget;   // 递归自保
    AevonScreenBusy = 1;
    UIApplication *application = [UIApplication sharedApplication];
    if (application != nil) {
        for (UIScene *scene in [application connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            id settings = AevonSceneSettings(scene);
            if (settings == nil) continue;
            if (!(AevonFlag(settings, @"isForeground") && !AevonFlag(settings, @"isBackgrounded"))) continue;
            id value = AevonTryValue(AevonTryValue(scene, @"coordinateSpace"), @"bounds");
            if (![value isKindOfClass:[NSValue class]]) continue;
            CGRect box = CGRectZero;
            [value getValue:&box size:sizeof(box)];
            if (box.size.width > 100 && box.size.height > 200) {
                box.origin = CGPointZero;
                AevonScreenTarget = box;
            }
            break;
        }
    }
    AevonScreenBusy = 0;
    return AevonScreenTarget;
}

/// 主屏 + 宿主尺寸都成立时，把答案换掉。`got` 是系统给的原值，用来判断
/// 「本来就一样」—— 一样的场合一个字节都不改，真前台的 App 因此完全不受影响。
///
/// `depth` 是自保：`[UIScreen mainScreen]` 与读 scene 的坐标空间都可能绕回
/// `bounds`，而这一层一旦递归就是启动即死循环。进一次、答一次，再问就直接用
/// 系统的原值。
static int AevonScreenDepth = 0;

static BOOL AevonScreenRewrite(id screen, CGRect got, CGRect *out) {
    if (AevonScreenDepth > 0) return NO;
    if (!AevonAppHookAllowed()) return NO;
    AevonScreenDepth = 1;
    BOOL answer = NO;
    if (screen == [UIScreen mainScreen]) {
        CGRect want = AevonHostedScreenSize();
        if (want.size.width > 100 && want.size.height > 200
            && (fabs(want.size.width - got.size.width) > 2
                || fabs(want.size.height - got.size.height) > 2)) {
            *out = want;
            answer = YES;
        }
    }
    AevonScreenDepth = 0;
    if (!answer) return NO;
    AevonScreenHits++;
    if (!AevonScreenLogged) {
        AevonScreenLogged = 1;
        char body[160];
        snprintf(body, sizeof(body), "screen %.0fx%.0f -> %.0fx%.0f (hosted scene)",
                 got.size.width, got.size.height, out->size.width, out->size.height);
        AevonGeomWrite(body);
    }
    return YES;
}

static CGRect AevonScreenBounds(id self, SEL _cmd) {
    CGRect got = ((CGRect (*)(id, SEL))AevonOriginalScreenBounds)(self, _cmd);
    CGRect want;
    if (AevonScreenRewrite(self, got, &want)) return want;
    return got;
}

static CGRect AevonScreenRefBounds(id self, SEL _cmd) {
    CGRect got = ((CGRect (*)(id, SEL))AevonOriginalScreenRef)(self, _cmd);
    CGRect want;
    if (AevonScreenRewrite(self, got, &want)) return want;
    return got;
}

static CGRect AevonScreenOriented(id self, SEL _cmd, NSInteger orientation) {
    CGRect got = ((CGRect (*)(id, SEL, NSInteger))AevonOriginalScreenOriented)(self, _cmd, orientation);
    CGRect want;
    if (AevonScreenRewrite(self, got, &want)) return want;
    return got;
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
    // `[UIApplication windows]` 在 iOS 15 起是废弃 API，而这份文件是按 -Werror
    // 编的（0.0.63 第一轮就是这么挂的：一条 deprecated 警告等于构建失败）。
    // 从 windowScene 拿窗口，两条路都还在系统里。
    UIWindow *key = nil;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        NSArray *wins = [(UIWindowScene *)one windows];
        for (UIWindow *w in wins) {
            if ([w isKeyWindow]) { key = w; break; }
        }
        if (key == nil && wins.count > 0) key = [wins objectAtIndex:0];
        if (key != nil) break;
    }
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
    // 硬件那一半单独给：`[screen bounds]` 现在可能已经是补丁后的值，
    // `nativeBounds / scale` 才是这台机器真实的点数尺寸。两列并排，「补丁生效
    // 了没有」就不需要再推导。
    CGRect native = screen != nil ? [screen nativeBounds] : CGRectZero;
    CGFloat scale = screen != nil ? [screen scale] : 0.0;
    char body[400];
    snprintf(body, sizeof(body),
             "%s screen=%.0fx%.0f@%.0f phys=%.0fx%.0f scene=%.0fx%.0f win=%.0fx%.0f "
             "root=%.0fx%.0f safe=%.0f/%.0f hits=%d",
             tag, box.size.width, box.size.height, scale,
             scale > 0 ? native.size.width / scale : 0.0,
             scale > 0 ? native.size.height / scale : 0.0,
             space.size.width, space.size.height,
             win.size.width, win.size.height,
             view.size.width, view.size.height,
             safe.top, safe.bottom, AevonScreenHits);
    AevonGeomWrite(body);
    if (rootView == nil) return;
    // 0.0.65 — 只量两层不够。上一版停在 `UITransitionView / UIDropShadowView`，
    // 那是 UIKit 的外壳，抖音的播放器在它下面好几层。这里改走「主脊」：从根视图
    // 开始，每一层挑面积最大的那个子视图往下走八层，同时把这一层的兄弟类名
    // 列一行 —— 既看得到深度，也看得到分叉。
    UIView *node = rootView;
    for (int level = 0; level < 8 && node != nil; level++) {
        CGRect f = [node frame];
        snprintf(body, sizeof(body), "%s spine%d %s %.0f,%.0f,%.0fx%.0f",
                 tag, level, class_getName([node class]),
                 f.origin.x, f.origin.y, f.size.width, f.size.height);
        AevonGeomWrite(body);
        NSArray *kids = [node subviews];
        if (kids.count == 0) break;
        NSMutableString *peers = [NSMutableString string];
        UIView *best = nil;
        CGFloat area = -1;
        NSUInteger limit = kids.count < 10 ? kids.count : 10;
        for (NSUInteger i = 0; i < limit; i++) {
            UIView *kid = [kids objectAtIndex:i];
            if (i > 0) [peers appendString:@"|"];
            NSString *name = [NSString stringWithUTF8String:class_getName([kid class])] ?: @"?";
            [peers appendFormat:@"%@:%.0fx%.0f", name,
             [kid frame].size.width, [kid frame].size.height];
            CGFloat a = [kid frame].size.width * [kid frame].size.height;
            if (a > area) { area = a; best = kid; }
        }
        snprintf(body, sizeof(body), "%s peers%d n=%lu %s",
                 tag, level, (unsigned long)kids.count, [peers UTF8String]);
        AevonGeomWrite(body);
        node = best;
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

    // 0.0.65 — 名片（宿主靠它判断「这个进程有没有这一版代码」）。
    if (AevonAppHookAllowed()) AevonBridgeMark();

    // 0.0.65 — 屏幕补丁。三个都是私有/半私有 getter：`bounds` 是 App 最常用的
    // 那个，`_referenceBounds` 与 `_boundsForInterfaceOrientation:` 是它下面的两层
    // （有的代码绕开 `bounds` 直接问这两层，母本的选择子表里也正好有第三个）。
    // 有哪个不存在就跳哪个，不写死「一定有」。
    Method bounds = class_getInstanceMethod([UIScreen class], sel_registerName("bounds"));
    if (bounds != NULL) {
        AevonOriginalScreenBounds = method_getImplementation(bounds);
        method_setImplementation(bounds, (IMP)AevonScreenBounds);
    }
    Method reference = class_getInstanceMethod([UIScreen class],
                                               sel_registerName("_referenceBounds"));
    if (reference != NULL) {
        AevonOriginalScreenRef = method_getImplementation(reference);
        method_setImplementation(reference, (IMP)AevonScreenRefBounds);
    }
    Method oriented = class_getInstanceMethod([UIScreen class],
                                              sel_registerName("_boundsForInterfaceOrientation:"));
    if (oriented != NULL) {
        AevonOriginalScreenOriented = method_getImplementation(oriented);
        method_setImplementation(oriented, (IMP)AevonScreenOriented);
    }
}
