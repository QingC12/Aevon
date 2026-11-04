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
//      that process and must not be double-hooked. 0.0.66 made that test three
//      conditions instead of one, and made "no name" count as SpringBoard: a
//      single nil bundle identifier used to be enough to get hooks into the
//      process that draws the home screen.
//    · **This file never rewrites a system measurement, and never forces a
//      layout inside someone else's windows.** 0.0.65 hooked `UIScreen.bounds`
//      / `_referenceBounds` / `_boundsForInterfaceOrientation:` to centre one
//      app's video; the result was a phone that would not open apps, a black
//      home screen and blank widgets. 0.0.67 put `UIScreen.bounds` back behind
//      a mark-file gate and added a once-a-second "re-layout every window"
//      watch; the user's report was the same failure, one release later. Two
//      identical reports is evidence, not bad luck: the price of lying to a
//      process about its screen is the whole device, and the thing bought is
//      one app's video sitting centred. It stays out.
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

/// The scene's settings, however this iOS spells the accessor. `settings` is
/// what `UIScene` answers on 17; `_sceneSettings` and the FBSScene's own
/// `settings` are the older shapes.
static id AevonSceneSettings(UIScene *scene) {
    id settings = AevonTryValue(scene, @"settings");
    if (settings != nil) return settings;
    settings = AevonTryValue(scene, @"_sceneSettings");
    if (settings != nil) return settings;
    id core = AevonTryValue(scene, @"_fbsscene");
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

/// 「别的进程正在演我」。
///
/// 0.0.68 — 判据回到 scene settings 的 `isForeground && !isBackgrounded`。
///
/// 0.0.67 把它换成过名片文件（`hosted.plist`），理由是「真前台 App 也满足这两
/// 条」。那个理由只对**改屏幕尺寸**成立，对这里不成立：两个状态钩子都先把系统
/// 的答案问出来，`state != 2`（不是后台）就原样返回 —— 一个真前台的 App 本来
/// 就是 active，走不到改写那一行。这条判据即便「过宽」，宽出来的那部分是空转，
/// 不会改写任何人。
///
/// 名片还有一个更实际的毛病：它是一次跨进程的文件读，读的是
/// `/var/mobile/Library/Logs/Aevon/`，沙箱里的 App 未必读得到。读不到就等于
/// 「卡里的 App 永远不是前台」，触摸立刻失效 —— 拿一个可能失效的判据去换一个
/// 确定无害的判据，是拿功能换安全感。
static BOOL AevonHosted(void) {
    if (!AevonAppHookAllowed()) return NO;
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
    // 硬件那一半单独给：`nativeBounds / scale` 是这台机器真实的点数尺寸。
    // 0.0.66 起 `bounds` 不再被改写，两列相同只说明「这次没有别人在改它」，
    // 不同则说明这块屏和设备不是一回事 —— 两种情形下这一行都是有用的对照。
    CGRect native = screen != nil ? [screen nativeBounds] : CGRectZero;
    CGFloat scale = screen != nil ? [screen scale] : 0.0;
    char body[400];
    snprintf(body, sizeof(body),
             "%s screen=%.0fx%.0f@%.0f phys=%.0fx%.0f scene=%.0fx%.0f win=%.0fx%.0f "
             "root=%.0fx%.0f safe=%.0f/%.0f",
             tag, box.size.width, box.size.height, scale,
             scale > 0 ? native.size.width / scale : 0.0,
             scale > 0 ? native.size.height / scale : 0.0,
             space.size.width, space.size.height,
             win.size.width, win.size.height,
             view.size.width, view.size.height,
             safe.top, safe.bottom);
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

/// 0.0.69 — 「这块画布比屏幕矮」。
///
/// 量尺原来只在「状态被改写」那条路上安排，而那条路要求 `applicationState == 2`。
/// Aevon(59) 的抖音 13:32:58 打开，整场 0 行 `app: geom`：它是挂起启动后被系统
/// 直接激活的，`applicationState` 从来没回到 2。于是「视频偏上」这件事量不到。
///
/// 判据换成几何本身：承载面的 `coordinateSpace.bounds` 比 `UIScreen` 矮 40 pt 以上，
/// 就说明这个进程正被一块小胖屏演着 —— 真前台 App 的这两者相等，不会命中，
/// 也就不会往日志里写那二十行。答案缓存 1 s：`applicationState` 可能被高频调用，
/// 而画布尺寸一秒内不会变两次。
static BOOL AevonCanvasIsShrunk(void) {
    static BOOL answer = NO;
    static CFAbsoluteTime stamp = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (stamp > 0 && now - stamp < 1.0) return answer;
    stamp = now;
    answer = NO;
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return answer;
    CGRect screen = [[UIScreen mainScreen] bounds];
    if (screen.size.height < 200.0) return answer;
    for (UIScene *scene in [application connectedScenes]) {
        id box = AevonTryValue(AevonTryValue(scene, @"coordinateSpace"), @"bounds");
        if (![box isKindOfClass:[NSValue class]]) continue;
        CGRect rect = CGRectZero;
        [box getValue:&rect size:sizeof(rect)];
        if (rect.size.height > 100.0 && rect.size.height < screen.size.height - 40.0) {
            answer = YES;
            break;
        }
    }
    return answer;
}

/// 每个进程只安排一次，而且一秒最多问一次。
///
/// 这个函数由两个状态钩子的「非后台」那一支调用，而 `applicationState` /
/// `activationState` 在热路径上可能每秒被问上百次 —— 所以节流必须在**这里**，
/// 不能指望调用点。装上之后（`armed`）连时间戳都不再看。
static void AevonGeometryChance(void) {
    static int armed = 0;
    static CFAbsoluteTime stamp = 0;
    if (armed) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (stamp > 0 && now - stamp < 1.0) return;
    stamp = now;
    // 判据只用几何，不用 settings 那一对 —— Aevon(59) 的抖音连 `AevonHosted()`
    // 都没成立过（整场没有 `app: promoted`），拿它当前置条件就永远量不到。
    // 「画布比屏幕矮」是这块卡存在的直接后果，与谁写的 settings 无关。
    if (!AevonCanvasIsShrunk()) return;
    armed = 1;
    AevonScheduleGeometry();
}

/// `UIApplicationStateActive`. UIKit checks this before it lets a window see
/// touches, so this is the flag that has to agree with the picture.
///
/// The original answer is asked first, and anything but "background" is handed
/// back untouched: a foreground app — or one that is merely inactive under a
/// system overlay — keeps the state the system gave it.
///
/// 0.0.69 — 这里付的那次 KVC 扫描现在覆盖所有「正在卡里」的进程，不再只覆盖
/// 后台的那一次：量尺（`AevonCanvasIsShrunk`）要在「已经被激活的卡内 App」上
/// 也能安排，否则抖音那种挂起启动后直接被激活的进程永远量不到。代价是每秒一次
/// 场景遍历（有 1 s 缓存），收益是「视频偏上」终于有读数。
static NSInteger AevonApplicationState(id self, SEL _cmd) {
    NSInteger state = ((NSInteger (*)(id, SEL))AevonOriginalApplicationState)(self, _cmd);
    if (state != 2) {                          // not UIApplicationStateBackground
        // 0.0.69 — 不是后台也要有机会安排量尺。Aevon(59) 的抖音一次都没进过下面
        // 那一支（挂起启动后被系统直接激活），于是「视频偏上」整场没有读数。
        // `AevonGeometryChance` 一秒最多问一次、装上就不再问，热路径不受影响。
        AevonGeometryChance();
        return state;
    }
    if (!AevonHosted()) return state;
    AevonNote("applicationState");
    return 0;                                  // UIApplicationStateActive
}

/// `UISceneActivationStateForegroundActive`. Same reason, one layer down: the
/// scene's own activation state is what a view controller consults when it
/// refuses to handle an event — and `2` is `UISceneActivationStateBackground`.
static NSInteger AevonActivationState(id self, SEL _cmd) {
    NSInteger state = ((NSInteger (*)(id, SEL))AevonOriginalActivationState)(self, _cmd);
    if (state != 2) {
        AevonGeometryChance();
        return state;
    }
    if (!AevonHosted()) return state;
    AevonNote("activationState");
    return 0;                                  // UISceneActivationStateForegroundActive
}

/// 0.0.66 — 这个进程能不能装桥。**宁可不装，也不能装错。**
///
/// 0.0.65 的写法是一行 `[bundle isEqualToString:@"com.apple.springboard"]`，
/// 那行保护有一个致命的空档：`bundle` 是 nil 时（mainBundle 在某些注入环境下
/// 返回 nil，或 roothide 把它指到 .jbroot 里的另一份）消息发出去返回 NO，
/// 于是 SpringBoard 被当成普通 App，装上「把 UIScreen.bounds 换成 scene 尺寸」
/// 那套补丁 —— 桌面按错的屏幕尺寸排版、图标网格与小组件全部作废。一次
/// nil 就够毁掉整个桌面，而这种判据的失效在宿主侧完全看不出来。
///
/// 所以现在是三条并列，任一条命中就退出，且**取不到名字也算命中**：
///   1. bundle id 为 nil / 空   → 无法证明它不是 SpringBoard；
///   2. bundle id 是 springboard；
///   3. 可执行路径或进程名里带 SpringBoard（id 被改名也能挡住）。
static BOOL AevonWorthInjecting(void) {
    NSBundle *main = [NSBundle mainBundle];
    NSString *bundle = [main bundleIdentifier];
    if (bundle.length == 0) return NO;
    if ([bundle isEqualToString:@"com.apple.springboard"]) return NO;
    NSString *path = [main executablePath];
    if (path != nil && [path rangeOfString:@"SpringBoard"].location != NSNotFound) return NO;
    NSString *name = [[NSProcessInfo processInfo] processName];
    if (name != nil && [name isEqualToString:@"SpringBoard"]) return NO;
    return YES;
}

__attribute__((constructor))
static void AevonAppBoot(void) {
    // 第一个注入点已经拥有 SpringBoard 这个进程。两条 reason 都要看：一是
    // 「一个 getter 上挂两个钩子多了一个」，二是 0.0.65 证明装错进程的代价
    // 不是抖动，是整个桌面。
    if (!AevonWorthInjecting()) return;

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

    // 0.0.68 — 这里曾经又一次装上 `UIScreen.bounds`（0.0.67），真机反馈和 0.0.65
    // 一字不差：应用打不开、桌面黑屏、小组件空白。两个版本、同一种故障，说明
    // 问题不在判据松不松，而在**这件事本身**：屏幕尺寸是系统的世界观，不是某个
    // App 的私有变量，替任何一个进程改写它，代价都是整台机器。
    //
    // 一个进程在卡片里被演的时候，需要被纠正的只有两件事：它以为自己在前台
    // （上面两个钩子），以及它该按多大的画布排版（宿主侧的 `bounds` + scene
    // settings，都不进 App 进程）。想在 App 进程里补第三件，先读 MEMORY.md 里
    // 那两轮真机故障，不要再试第三次。
}
