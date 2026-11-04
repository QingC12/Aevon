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
//    · **This file never rewrites a system measurement.** 0.0.65 hooked
//      `UIScreen.bounds` / `_referenceBounds` / `_boundsForInterfaceOrientation:`
//      to make one app's video sit centred; the damage was a phone where apps
//      would not open, the home screen went black and every widget came up
//      blank, because those three getters were replaced in every process that
//      loads UIKit — including the ones that are not apps. The measured cost of
//      that idea is one whole release; it is not coming back.
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
static IMP AevonOriginalScreenBounds = NULL;
static int AevonGate = -1;      // -1 unknown, 0 off, 1 on
static int AevonLogged = 0;

/// 名片状态翻转时的收尾（0.0.67）。实现在 `AevonGeomWrite` 之后 —— 它要写日志。
static void AevonHostedFlipped(BOOL hosted);

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

/// 这块卡交给系统的逻辑尺寸 —— 也就是 App 真正在排版的画布。
///
/// 读法和 `AevonDumpGeometry` 那条汇总行完全一样（`coordinateSpace.bounds`），
/// 两处必须同源：一处用来测量、一处用来下发给 `UIScreen`，若各读各的，
/// 下一份日志里「量到的」和「改成的」就会是两个数。
static CGRect AevonHostedSpace(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return CGRectZero;
    for (UIScene *scene in [application connectedScenes]) {
        id space = AevonTryValue(scene, @"coordinateSpace");
        id box = AevonTryValue(space, @"bounds");
        if ([box isKindOfClass:[NSValue class]]) {
            CGRect rect = CGRectZero;
            [box getValue:&rect size:sizeof(rect)];
            return rect;
        }
    }
    return CGRectZero;
}

/// 名片读一次，不缓存。调用方负责节流。
///
/// `ts` 是**参考日期秒**（宿主侧 `Date().timeIntervalSinceReferenceDate`），
/// 和这里的 `CFAbsoluteTimeGetCurrent()` 同一把尺子 —— 两边都不必知道 1970。
static BOOL AevonMarkRead(void) {
    NSDictionary *mark = [NSDictionary dictionaryWithContentsOfFile:
                          @"/var/mobile/Library/Logs/Aevon/hosted.plist"];
    if (mark == nil) return NO;
    NSString *bundle = [mark objectForKey:@"bundle"];
    NSNumber *since = [mark objectForKey:@"ts"];
    NSString *mine = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle == nil || mine == nil || since == nil) return NO;
    if (![bundle isEqualToString:mine]) return NO;
    // Ten minutes is the card's own cap; a mark older than that is a process
    // that died holding it, and honouring it would leave an app believing it is
    // on screen forever.
    return (CFAbsoluteTimeGetCurrent() - [since doubleValue]) < 600.0;
}

/// The host's own mark. `Aevon.hostedPath`, written when a card opens and
/// deleted when it closes. Read at most once a second.
///
/// 0.0.67 — 这个函数现在是**唯一**的判据（见 `AevonHosted`），所以它顺带成了
/// 「开卡 / 关卡」这件事在 App 侧的观察点：状态每翻一次，就让 App 按新尺寸重排
/// 一次（`AevonHostedFlipped`）。刷新周期 1 秒，也就是关卡后最多一秒 App 就会
/// 按整屏把自己摆回去。
static BOOL AevonMarkSaysHosted(void) {
    static BOOL answer = NO;
    static CFAbsoluteTime stamp = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (stamp > 0 && now - stamp < 1.0) return answer;
    stamp = now;
    answer = AevonMarkRead();
    AevonHostedFlipped(answer);
    return answer;
}

/// 「别的进程正在演我」。
///
/// 0.0.67 — **只剩名片这一条判据。**
///
/// 0.0.44 起的第二个判据是 scene settings 的 `isForeground && !isBackgrounded`，
/// 本意是「名片可能读不到，settings 是内存里的答案」。它有一个致命的重合：
/// **真前台 App 也满足这两条**。0.0.65 拿它去改 `UIScreen` 的尺寸，于是每个
/// 正在前台运行的 App、每个渲染守护进程都被告知「你的屏幕是 430x717」——
/// Aevon(58) 之前那一版的「很多应用打不开、桌面黑屏、小组件空白」就是它。
///
/// 名片没有这个重合：它由宿主在开卡时写、关卡时删，内容里带着 bundle id，
/// 并且只对那一个 App 成立。判据窄一点，代价是「名片写不进去时卡里的 App 不被
/// 当成前台」，收益是永远不会把别人的手机变成砖。名片写入本身是宿主侧的
/// 一次 plist 写盘，日志里一直是 `hosted mark <bundle>` 无 failed。
static BOOL AevonHosted(void) {
    if (!AevonAppHookAllowed()) return NO;
    return AevonMarkSaysHosted();
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

// MARK: - 0.0.67 App 侧：按卡片的尺寸再排一次

//
// Aevon(58) 的头两条是同一件事的两面：
//
//   ① 「悬浮窗一次打开时，内容尺寸不对，必须手动缩放一下才会显示正确的内容排版
//     （例如应用顶栏，底栏等）」
//   ② 「关闭悬浮窗后全屏打开抖音，抖音的整体页面偏下，顶部出现上个视频的底部页面」
//
// 两条都在说**App 不知道自己换了尺寸**。宿主侧的证据是齐的：`scene frame
// after=430x717 wrote=1`、`hosted bounds after=430x717`、`fat scene render=430x717`
// —— 交出去的画布确实矮了。但 App 里 `UIScreen` 还是 430x932，于是凡按屏幕算的
// 东西（抖音的视频层与分页步长）都按 932 算：卡里视频贴在 932 的顶部区域、
// 下半截露灰底；退出后 offset 与页高不匹配、顶上露出上一页的底。
//
// 0.0.65 试过直接改 `UIScreen`，判据是 scene settings 的 `isForeground` —— 那个值
// **对真前台 App 也是 1**，于是每个前台 App、每个渲染守护进程都被告知「你的屏幕
// 是 430x717」，整台机器打不开应用、桌面黑屏、小组件空白。这一版把三个口子都收窄：
//
//   · 判据只认名片。没有卡 = 没有名片 = 一个字节都不改（见 `AevonHosted`）。
//   · 只改 `bounds` 一个 getter。`_referenceBounds` 是 UIKit 算键盘、状态栏、分屏的
//     全局基准，`_boundsForInterfaceOrientation:` 收方向参数而实现无视它 —— 0.0.65
//     连这两个一起改了，那是灾难的另一半。这一版两个都不碰。
//   · SpringBoard 进程根本不装（见 `AevonWorthInjecting`），桌面永远拿真屏幕。
//
// 改完尺寸还不够：App 里「尺寸变了才重算」的那类布局（分页步长、播放器居中、
// 顶栏底栏的约束）只认一次真正的 layout pass。所以名片每翻一次，这里补一次
// 半像素往返 + layoutIfNeeded —— 开卡时让 App 排 717，关卡时让它排回 932。

/// 让每一个 window 走一遍真正的布局。
///
/// 只用 `setNeedsLayout` 是不够的：那只是标记，下一次 runloop 才可能处理，而
/// 抖音这类 App 把页高算在 `viewDidLayoutSubviews` 里、且只在 bounds 变化时才进去。
/// 半像素的往返是「告诉它 bounds 变了」的最便宜写法，两次 setFrame 在同一个
/// runloop 内完成，不会上屏。
static void AevonRelayoutWindows(void) {
    if (![NSThread isMainThread]) return;
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [(UIWindowScene *)one windows]) {
            CGRect f = [w frame];
            [w setFrame:CGRectMake(f.origin.x, f.origin.y, f.size.width, f.size.height + 0.5)];
            [w setFrame:f];
            [w setNeedsLayout];
            [w layoutIfNeeded];
            UIView *root = [[w rootViewController] view];
            [root setNeedsLayout];
            [root layoutIfNeeded];
        }
    }
}

static void AevonRelayoutTick(void *context) {
    (void)context;
    AevonRelayoutWindows();
}

static void AevonRelayoutLater(double seconds) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonRelayoutTick);
}

static void AevonWatchTick(void *context);

static int AevonWatchOn = 0;
static int AevonWatchRounds = 0;

static void AevonWatchSchedule(void) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonWatchTick);
}

/// 卡开着的时候每秒看一眼名片还在不在。
///
/// 关卡之后 App 在后台，`applicationState` / `UIScreen.bounds` 都可能不再被调用,
/// 光靠「下次有人问我」等不到翻转。这个时钟就是那个「有人」：名片没了就重排一次
/// 然后停表。900 拍 = 15 分钟，盖住卡片自己的十分钟上限。
static void AevonWatchArm(void) {
    if (AevonWatchOn) return;
    AevonWatchOn = 1;
    AevonWatchRounds = 0;
    AevonWatchSchedule();
}

static void AevonWatchTick(void *context) {
    (void)context;
    AevonWatchRounds += 1;
    if (AevonMarkRead()) {
        if (AevonWatchRounds < 900) {
            AevonWatchSchedule();
            return;
        }
        AevonWatchOn = 0;
        return;
    }
    AevonWatchOn = 0;
    AevonRelayoutWindows();
    AevonGeomWrite("win released, relayout for the real screen");
}

/// 名片状态翻了一次。`known < 0` 是进程第一次读，不算翻转 —— 那种情况由
/// constructor 里的两次延时重排兜住。
static void AevonHostedFlipped(BOOL hosted) {
    static int last = -1;
    int now = hosted ? 1 : 0;
    if (last == now) return;
    int known = last;
    last = now;
    if (known < 0) {
        if (now == 1) AevonWatchArm();
        return;
    }
    if (now == 1) {
        // 开卡：0.05 s 赶上这一拍，0.50 s 兜住「window 还没建」的那个窗口。
        AevonRelayoutLater(0.05);
        AevonRelayoutLater(0.50);
        AevonWatchArm();
        AevonGeomWrite("hosted, relayout for the card canvas");
        return;
    }
    AevonRelayoutLater(0.05);
    AevonRelayoutLater(0.60);
    AevonGeomWrite("released, relayout for the real screen");
}

/// `UIScreen.bounds`，只在有卡的时候换成卡片的画布尺寸。
///
/// 这是「两块屏幕」这件事在 App 侧唯一的开关：抖音按 `UIScreen` 摆视频和分页，
/// 窗口 717 而屏幕 932，视频就贴在 932 的坐标里。让两者说同一个数，偏上、断层、
/// 退出后错位一起消失 —— 不是去追每一条错误布局。
///
/// 取不到画布（`< 80`）或没有名片时原样返回，落地就是系统自己的答案。
static CGRect AevonScreenBounds(id self, SEL _cmd) {
    CGRect box = ((CGRect (*)(id, SEL))AevonOriginalScreenBounds)(self, _cmd);
    if (!AevonHosted()) return box;
    CGRect space = AevonHostedSpace();
    if (space.size.width < 80.0 || space.size.height < 80.0) return box;
    return CGRectMake(0.0, 0.0, space.size.width, space.size.height);
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

    // 0.0.67 — `UIScreen.bounds` 回来了，但只回来一个 getter，而且只在有名片时改。
    //
    // 0.0.66 把它连 `_referenceBounds` / `_boundsForInterfaceOrientation:` 一起删，
    // 理由是 0.0.65 的真机故障。那个判决对「三个一起改 + 判据是 isForeground」
    // 成立，对「只改 bounds + 判据是名片」不成立 —— 后者命中的一定是那个正在
    // 卡片里演我的 App，而它此刻的窗口本来就是 717，让屏幕也说 717 是把两个数
    // 对齐，不是把别人的屏幕换掉。
    //
    // 仍需 `AevonWorthInjecting`：SpringBoard 根本不进这个函数（见 constructor
    // 第一行），所以桌面、图标网格、小组件永远读真屏幕。
    Method bounds = class_getInstanceMethod([UIScreen class], sel_registerName("bounds"));
    if (bounds != NULL) {
        AevonOriginalScreenBounds = method_getImplementation(bounds);
        method_setImplementation(bounds, (IMP)AevonScreenBounds);
    }

    // 开卡前就已经启动的进程（比如上一轮留下来的）也要排一次：constructor 跑在
    // App 建 window 之前，这里只能延时排两拍，兜住首次打开的「内容尺寸不对」。
    if (AevonMarkRead()) {
        AevonRelayoutLater(0.50);
        AevonRelayoutLater(1.50);
        AevonWatchArm();
    }
}
