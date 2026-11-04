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
//    · 0.0.71 adds exactly one write into another app's own views: after the
//      window height changes, a full-bleed pager's content offset is re-aligned
//      to a whole page (`round(y / oldPage) * newPage`). That is a scroll
//      position, not a measurement — the app's screen size, safe area, traits
//      and layout are all still the system's own. It runs only in a process we
//      have hosted, and the worst case is one wrong page, which a swipe undoes.
//      The boundary that must not move again is the one 0.0.65 / 0.0.67 crossed:
//      telling a process its screen is a different size.
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
#import <objc/message.h>
#import <objc/runtime.h>

#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

static CFStringRef const AevonDomain = CFSTR("com.aevon");
static CFStringRef const AevonKey = CFSTR("!ring.appHook");

static IMP AevonOriginalApplicationState = NULL;
static IMP AevonOriginalActivationState = NULL;
static int AevonGate = -1;      // -1 unknown, 0 off, 1 on
static int AevonLogged = 0;

/// 这个进程被我们演过（或正在被演）。置上就不再清 —— 关卡之后那一次「交还整屏」
/// 同样需要把翻页器对回去，那正是全屏截图里偏下的来源。定义在这里是因为
/// `AevonCanvasIsShrunk`（几何判据）也要用它。
static int AevonEverHosted = 0;

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

// MARK: - 0.0.70 桥接日志的落点

//
// 这一段是本轮的前置条件，不是修饰。
//
// 在 0.0.70 之前，这个文件与 `AevonGeomWrite` 都写死 `/var/mobile/Aevon.log`。
// 抖音、微信这类 App Store 应用跑在沙盒里，`fopen` 那个路径永远返回 NULL ——
// 于是量尺照跑、读数照扔，一行都留不下。全量日志能作证：所有历史日志里 App 侧
// 只出现过 Filza / Sileo / 设置三个进程，一个沙盒 App 都没有。抖音的「视频贴顶」
// 量了三轮、改了两次都失败，根因不是量尺写得不对，是量尺的答案从来没到过我们手上。
//
// 现在按顺序试两处：宿主那份（未沙盒进程仍然一步到位），以及自己的
// `tmp/aevon-app.log`（沙盒里唯一保证可写的位置，宿主在开卡与关卡时来取，
// 见 AevonScene.m 的 `AevonDrainAppLog`）。
//

/// 选中的落点，进程内只算一次。全失败返回 NULL（那就什么都不写）。
static const char *AevonAppLogPath(void) {
    static char chosen[PATH_MAX];
    static int ready = 0;
    if (ready) return chosen[0] != '\0' ? chosen : NULL;
    ready = 1;
    NSString *tmp = NSTemporaryDirectory();
    NSString *own = tmp.length > 0
        ? [tmp stringByAppendingPathComponent:@"aevon-app.log"] : nil;
    const char *candidates[2];
    candidates[0] = "/var/mobile/Aevon.log";
    candidates[1] = own != nil ? [own fileSystemRepresentation] : NULL;
    for (int i = 0; i < 2; i++) {
        if (candidates[i] == NULL) continue;
        // 试开一次就关：能开说明这个路径在沙盒眼里是允许的。
        int fd = open(candidates[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        close(fd);
        snprintf(chosen, sizeof(chosen), "%s", candidates[i]);
        break;
    }
    return chosen[0] != '\0' ? chosen : NULL;
}

/// 追加一行。涨到 512 KB 就从头写 —— 这个上限只会在「宿主一直没来取」时触发，
/// 一个 App 的 tmp 不该被诊断日志撑满。
static void AevonAppLogWrite(const char *line) {
    const char *path = AevonAppLogPath();
    if (path == NULL || line == NULL) return;
    struct stat info;
    const char *mode = (stat(path, &info) == 0 && info.st_size > 512 * 1024) ? "w" : "a";
    FILE *file = fopen(path, mode);
    if (file == NULL) return;
    fputs(line, file);
    fclose(file);
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
    AevonAppLogWrite(line);
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
    AevonAppLogWrite(line);
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
            // 0.0.72 — 兄弟层改成「原点 + 尺寸」。0.0.71 只印尺寸，于是
            // `AWEFeedTopBarContainer:430x44` 既可能是贴顶的 44 pt 顶栏，
            // 也可能被整体推下去 110 pt —— 而这正是「顶栏底栏不对」与
            // 「视频靠上」之间唯一没被量过的那个量。原点一印，两件事当场分开。
            [peers appendFormat:@"%@:%.0f,%.0f,%.0fx%.0f", name,
             [kid frame].origin.x, [kid frame].origin.y,
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

/// 0.0.71 — 实现在下面（`AevonPageWrite` 那一族），这里只是先声明。
static void AevonPagerReport(const char *reason);
static void AevonPagerWatchArm(void);

static void AevonGeomTick(void *context) {
    AevonDumpGeometry((const char *)context);
    // 「late」那一拍顺带把翻页器与播放器各量一次：断层是打开几秒之后才看得出的，
    // 1.2 s 那一拍量到的还是启动时那一版布局。
    if (context == (void *)AevonGeomLate) AevonPagerReport("late");
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
            // 0.0.71 — 这条判据同时是「我们演过这个进程」的记录点：翻页器的归位
            // 从这里开始生效，没被卡片打开过的 App 永远不会置上这个位。
            AevonEverHosted = 1;
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
    AevonPagerWatchArm();
    AevonScheduleGeometry();
}

// MARK: - 0.0.72 翻页器的位置（断层）

//
// Aevon(61) 是第一次拿到抖音读数的日志（0.0.70 把桥接日志的落点挪进了沙盒）。
// 结论并不是「尺寸不对」：
//
//   app: geom late screen=430x932@3 phys=430x932 scene=430x717 win=430x717 root=430x717
//   app: geom late spine0 UILayoutContainerView 0,0,430x717
//   …
//   app: geom late peers7 n=4 UIView:430x717|AWEFeedTopBarContainer:430x44|UIImageView:430x717
//
// 三次开卡，主脊八层全是 430x717，连页面底图都是 430x717。页面高度等于窗口高度，
// 系统没有欺骗它，我们也没有裁它。0.0.63 起追的那个「两块屏幕」不是这一条的主因。
//
// 「视频贴顶 + 中间断层」的正解在录屏第 27 秒那一帧：**同一个卡片里同时出现了两个
// 帖子** —— 上面是「慢慢来太阳下山 / 辽宁朝阳 / 00:05」的尾巴，下面是「快递员先乘船
// 过江…」的开头，中间是两页的交界。这不是排版，是翻页停在了两页之间。
//
// 位置是怎么错开的：这块卡的画布固定 430x717，但每开一次卡要把 App 的窗口从 932
// 推到 717，关一次又还回 932。翻页器记的是「第 N 页 = N × 当时的窗口高」，那个数
// 不会跟着窗口一起换算 —— 932 与 717 互质的那点余数让 offset 落在两页中间。
//
// 0.0.71 的修法是对的，但它只在两个时刻各试一次（过渡后 0.08 s / 0.45 s），而
// Aevon(62) 的日志把这条路堵死的地方写得很清楚：
//
//   14:22:40 app: page on resize pager=0 fixed=0 raw=1
//   14:22:40 app: page on resize late pager=0 fixed=0 raw=1
//   14:22:40 app: page watch pager=0 fixed=0 raw=1
//
// `raw=1` 说明那个滚动视图在（视口与窗口等高、内容至少两屏），`pager=0` 说明它被
// 判据拒了：那一刻窗口已经变回 932，而单元格还是 717，于是「内容高度必须是页高
// 整数倍」这条**采集**判据当场失效。判据本身没错，错的是拿它当**每次都要重过一遍**
// 的门 —— 同一个翻页器，上一秒刚认过，这一秒不该因为别人的中间态而被忘掉。
//
// 所以这一版三件事：
//
//   ① **记住翻页器**（`AevonPagerStore`，我们自己持有）。认出一次就够，之后窗口
//      怎么变都用同一个对象，判据只在「还没认出来」的时候用。
//   ② **页高从单元格上读**（`AevonCellHeightOf`）。窗口高是「现在多大」，单元格
//      高才是「一页多高」；窗口刚变、单元格还没重排时，两者正好一个是一个不是。
//   ③ **停稳就核一次**（`AevonPagerWatchTick` 里那段守卫）。用户划走、App 自己
//      吸附、窗口尺寸变化，三种原因都会让 offset 停在非整页上；与其猜是哪一种，
//      不如在它停稳 0.6 s 之后看一眼：不是整页就挪回最近的整页。
//
// 这不是改系统的任何测量，只碰这个 App 自己的滚动视图；而且只在它被我们演过之后
// 才碰 —— 没被卡片打开过的 App 一行都不会走到这里。0.0.65 / 0.0.67 拿整台手机的
// 屏幕尺寸去换一个视频的位置，两次都换来「应用打不开、桌面黑屏、小组件空白」；
// 这一次动的是别人自己的滚动条位置，最坏结果是跳错一页，滑一下就能回来。

/// 这个进程被我们演过（或正在被演）。置上就不再清 —— 关卡之后那一次「交还整屏」
/// 同样需要把翻页器对回去，那正是全屏截图里偏下的来源。
static void AevonPageWrite(const char *body) {
    char line[640];
    time_t now = time(NULL);
    struct tm stamp;
    localtime_r(&now, &stamp);
    snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d app: page %s\n",
             stamp.tm_year + 1900, stamp.tm_mon + 1, stamp.tm_mday,
             stamp.tm_hour, stamp.tm_min, stamp.tm_sec, body);
    AevonAppLogWrite(line);
}

/// 认出来的那个翻页器，**由我们自己持有一份**。
///
/// 0.0.71 每次都重新扫一遍，扫到才算数 —— 而关卡那一拍正好是「窗口已经回去、
/// 单元格还没跟上」的中间态，扫描必然落空。认出一次就记住，这一条把整类
/// 「中间态判据失效」都绕开了。
/// 存法按编译方式分两套：这个文件在 Theos 下是手写引用计数，但只要有谁
/// 给 AevonApp 打开 ARC，`[x release]` 就会变成编译错误。`__has_feature`
/// 让两种情况各自成立，而外面的代码只看见 `AevonPagerGet()`。
#if __has_feature(objc_arc)
static __weak UIScrollView *AevonPagerStore = nil;
#else
static UIScrollView *AevonPagerStore = nil;
#endif
static UIScrollView *AevonPagerGet(void) { return AevonPagerStore; }
/// 翻页器记忆里的页高。窗口高度变化时由过渡钩子写成**变化前**的那个高度，
/// 归位之后改写成当前页高 —— 它回答的是「App 现在按几页一步走」。
static CGFloat AevonLastPageHeight = 0.0;
static int AevonTransLogs = 0;
static int AevonAcquireTries = 0;
/// 0.0.73 — 窗口尺寸变化**之前**那一版页高，等归位用。
///
/// 它是这一版的核心：翻页器记的是 `N × 当时的窗口高`，尺寸一变，这个 N 就不再
/// 对应同一条边界。0.0.72 把它寄存在 `AevonLastPageHeight` 里，可那个数会被
/// `AevonPageHeightOf` 用单元格的高度盖掉 —— App 重排完之后单元格正好等于视口，
/// 于是「页高 = 视口高」，`round(y / box) × box` 把 offset 挪到离当前最近的整页，
/// 而当前这一页是错的。所以旧页高必须单独存、单独用，直到真的归位过一次。
static CGFloat AevonOldPage = 0.0;
/// 归位的机会还剩几拍。过渡钩子与「窗口高度变了」各续一次（90 拍 ≈ 13.5 s）：
/// 从「我们还原尺寸」到「App 真的重排完」之间隔着一次挂起——用户点图标的那一刻
/// 才继续，所以这里不能用固定毫秒数。
static int AevonSettleTicks = 0;
/// 归位窗口的真实寿命（每拍都加，不管有没有干活）。90 拍「机会」在
/// 「App 一直不重排」时会永远不消耗，这个计数器负责兜底：90 s 之后无论
/// 如何都撤销，让停稳守卫重新接管。
static int AevonSettleAge = 0;
/// 停稳守卫与窗口高度守卫的几个数（定义在这里，因为过渡钩子也要清它们）。
static CGFloat AevonGuardY = -1.0;
static int AevonGuardHold = 0;
static int AevonWatchTicks = 0;
static CGFloat AevonWatchHeight = 0.0;
static int AevonWatchArmed = 0;
/// 心跳撞上 2400 拍上限之后置 1。过渡钩子可以把它重新叫起来 —— 否则一张用得久
/// 一点的卡，守卫就会在用户还在用的时候自己先停了。
static int AevonWatchDead = 0;
/// 0.0.76 — 「请 App 重排」的次数与上一次的时刻。
///
/// 0.0.80 把上限从 12 收到 4，并且加了一道**它到底管不管用**的判据：
///
/// 0.0.78/0.79 的写法是「只要页高不齐就发」，发到 12 次为止。Aevon(71) 里这段
/// 每次都发、每次都没用（`clean=1 stale=1 top=717 box=717` 连续九条，四秒里一行
/// 都没变），而每一次都是整表重排。**没有验收的发信号，等于把重活挂在定时器上。**
/// 现在连续两次发完页高一点没变，就判这个 App 不吃这一口，本次尺寸变化内不再发。
static int AevonRebuilds = 0;
static CFAbsoluteTime AevonRebuildAt = 0.0;
static int AevonRebuildSame = 0;
static int AevonRebuildDead = 0;
static CGFloat AevonRebuildTop = 0.0;
/// 0.0.78 — 「翻页器比窗口高」这一族的读数次数与上一次的时刻。6 行 × 2.5 s 是
/// 「够看清一次」与「别把日志刷满」的折中；每次尺寸变化重新计数。
static int AevonStuckLines = 0;
static CFAbsoluteTime AevonStuckAt = 0.0;
/// 0.0.77 — 「变化前停在哪一帖」记成**行下标**，不记页码、更不记 pt。
///
/// 为什么页码也不行。Aevon(67) 的四组读数放在一起看只有一个结论：**行原点会从
/// `N × box` 那个格点上漂走**，漂移量正好是「上面还有几行没重排」× (932 − 717)。
///
///   16:02:58 关卡前  box=717 off=13623(19×717) 行=13120 → 视口压在这一行第 503 pt
///   16:02:43 开卡后  box=717 off=10038(14×717)  行=9320(932 高) → 第 718 pt
///   16:02:58 关卡后  box=932 off=14912(16×932)  行=14554 → 第 358 pt
///   16:02:48 卡内    box=717 off=10710          行=10252(932 高) → 第 458 pt
///
/// 四行行原点相对 `N × box` 的偏离依次是 +214 / +214 / −358 / +214 —— 214 = 932 − 717，
/// 也就是「视口上方还有一行仍是旧高度」。所以**任何以 0 为锚的格点算术都必错**：
/// `round(y/box)*box` 落在两页之间，`N × 新页高` 也一样。16:02:58 那一拍更狠 ——
/// 视口正好在 `717 × 19` 上，全屏却是断层，说明连 App 自己吸附用的都是那个已漂移的
/// 格点。这一条把「算得准不准」彻底否掉了：不是精度问题，是坐标系没有共同原点。
///
/// 唯一有共同原点的东西是**那一页自己的 frame**。所以这里记「第几行」（`indexPath`），
/// 每次要用的时候向 App 现问 `rectForRowAtIndexPath:` / `layoutAttributesForItemAtIndexPath:`
/// —— 它答的是「那一页现在在哪」，而不是「按格点应该在哪」。
static NSInteger AevonAnchorSection = -1;
static NSInteger AevonAnchorRow = -1;
static int AevonAnchorSet = 0;
/// 一次尺寸变化里真正写过几次 offset。24 次 ≈ 3.6 s 的节拍，够跟着重排走完；
/// 再多就说明 App 在坚持把 offset 拉回去，继续写只是互相推。
static int AevonAnchorWrites = 0;
/// 「App 把行下标弄丢了」只报一次。
static int AevonAnchorLost = 0;
/// 0.0.81 — **关卡方向的重排要等 App 真的在前台再做。**
///
/// Aevon(72) 把范围收窄到一件事：卡片开着时一切正常，**关掉卡片之后一开全屏就
/// 卡住**（画面不动、滑不动，等几秒或切一次后台才回来），六次开合六次复现。
/// 同一份日志里能点名的只有一处「我们插在关卡那一拍的动作」：
///
///   17:07:40 transition h=932 last=717 full=932      ← 我们把 scene 还成 932
///   17:07:40 anchor keep row=0,1 at=932 frame=717 h=717
///   17:07:40 rebuild watch … box=932 top=932 r=1     ← 紧接着一次整表重排
///   17:07:40 anchor done row=0,1 at=932 h=932         ← 行高被问成了 932
///   17:07:19 background retry door=1 fg=no            ← 同一秒里我们把它推去后台
///
/// `beginUpdates`/`endUpdates` 是一次真正的批量更新（要重问每一行的高度、要跑
/// 一次 CATransaction）。0.0.78 起它落在「窗口刚变、进程马上要被挂起」这一拍上，
/// 0.0.79 起它又变成每次关卡都必然发生（0.0.80 的验收把空转都掐掉了，剩下这
/// 一次是唯一真正需要发的）。而抖音的翻页是等「当前这一帖准备好」才跟手的。
///
/// 所以：**往大走（回整屏）那一拍只记账，不动手**。等用户在 App 里真的回到前台
/// （原始 `applicationState == active`）之后的第一拍再做 —— 那时窗口、进程、
/// 渲染管线都在一起，一次批量更新就是一次普通的重排。
///
/// 往小走（开卡）不变：那一路是 0.0.78 修好的「第一次打开内容尺寸不对」，而且
/// App 就在用户眼前，没有任何东西要挂起。
static int AevonRemeasurePending = 0;
static CGFloat AevonRemeasureTarget = 0.0;
static CFAbsoluteTime AevonRemeasureAt = 0.0;
/// 这一轮「等它真的在前台」说过几次。3 行足够看清一次；再多就只是把日志刷满。
static int AevonRemeasureLogs = 0;
/// 已经等了多少拍。只用来兜底「这个 App 回到前台之后 `applicationState` 仍然是
/// background」那一种（见 `AevonAlignPager` 里 50 拍那段）。
static int AevonRemeasureWaits = 0;
/// 0.0.79 — 换屏**之前**那一页有几个播放器在播，以及这一版替它按过几次 play。
///
/// Aevon(69) 的新故障：抖音在两块屏之间来回切之后，画面停在那一帧，要先点一下
/// （暂停）再点一下（播放）才回来 —— App 的按钮说自己在播、播放器却停着。这种
/// 状态只有一个来源：**「你被挡住了」比「你回来了」多收到一次**（挂起启动、
/// 系统去激活、我们自己那一次 `endUpdates` 都会发前者）。这里不猜是哪一次，
/// 只做一件事：换屏之前记下「本来在播」，换屏之后复看 —— 本来在播、现在停了，
/// 就替它按下 play。用户自己按暂停的那种情况，`AevonPlayBefore` 是 0，不会碰。
static int AevonPlayBefore = 0;
static int AevonPlayNotes = 0;
static int AevonResumes = 0;

static void AevonPagerKeep(UIScrollView *view) {
    if (view == nil) return;
    if (view == AevonPagerStore) return;
    // 换了一个翻页器 = 换了一次使用，配额跟着重新开。
    AevonAnchorWrites = 0;
#if __has_feature(objc_arc)
    AevonPagerStore = view;
#else
    [AevonPagerStore release];
    AevonPagerStore = [view retain];
#endif
}

static void AevonPagerForget(void) {
#if !__has_feature(objc_arc)
    [AevonPagerStore release];
#endif
    AevonPagerStore = nil;
    AevonLastPageHeight = 0.0;
    // 认的翻页器都没了，「上一次尺寸变化」的账也该一起销掉。
    AevonOldPage = 0.0;
    AevonSettleTicks = 0;
    AevonSettleAge = 0;
    // 0.0.77 — 归位窗口关掉，但**行下标留着**：关卡那一拍 `[view window]` 可能
    // 正好是 nil（scene 已经在拆），这里若把「在看哪一帖」也一并抹掉，等用户回到
    // 全屏时就没有落点了 —— 而那正是这条路唯一要服务的时刻。
    AevonAnchorWrites = 0;
    AevonRebuilds = 0;
    AevonRebuildAt = 0.0;
    AevonRebuildSame = 0;
    AevonRebuildDead = 0;
    AevonRebuildTop = 0.0;
    AevonStuckLines = 0;
    AevonStuckAt = 0.0;
}

/// 「一页多高」——从单元格读，不从窗口读。
///
/// 抖音的翻页器是「一个 cell 一屏」：窗口推到 717 之后，cell 会在某一拍跟着变
/// 717；而窗口刚变的那一两拍里，cell 还是 932。窗口高答的是「现在多大」，cell
/// 高答的才是「一页多高」，归位要的是后者。
///
/// 只在 [0.5, 1.5] 倍视口高之间取值：符合这个区间的才可能是「整屏一页」的 cell，
/// 落在区间外的（页头、贴片、浮层）不能拿来算页高。
static CGRect AevonCellFrameOf(UIScrollView *view, CGFloat box) {
    CGRect best = CGRectZero;
    NSArray *kids = [view subviews];
    NSUInteger limit = kids.count < 12 ? kids.count : 12;
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *kid = [kids objectAtIndex:i];
        CGRect f = [kid frame];
        if (f.size.height > box * 0.5 && f.size.height < box * 1.5
            && f.size.height > best.size.height) {
            best = f;
        }
    }
    return best;
}

static CGFloat AevonCellHeightOf(UIScrollView *view, CGFloat box) {
    return AevonCellFrameOf(view, box).size.height;
}

static CGFloat AevonPageHeightOf(UIScrollView *view, CGFloat box) {
    CGFloat cell = AevonCellHeightOf(view, box);
    CGFloat page = cell > 200.0 ? cell : AevonLastPageHeight;
    // 差 8 pt 以内算同一个数：717 与 716 是宿主自己那一手，不是换了一页。
    if (page < 200.0 || fabs(page - box) < 8.0) page = box;
    return page;
}

/// 0.0.81 — **这个 App 自己**（不是我们演给它看的那一面）是不是在前台。
///
/// 必须走原始实现：`AevonApplicationState` 那个钩子会在「scene 说前台、App 说
/// 后台」时把答案改写成 active —— 那正是卡片里应有的答案，也正是这里要排除的
/// 情形。卡片里真实状态是后台，全屏时才是真的 active，这个区别只有原始实现
/// 答得出来。
///
/// 钩子没装上（`AevonOriginalApplicationState == NULL`）时按「在」处理：宁可不
/// 推迟，也不要在一个量不出来的状态上永远不动手。
static BOOL AevonAppIsActive(void) {
    if (AevonOriginalApplicationState == NULL) return YES;
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return YES;
    SEL cmd = sel_registerName("applicationState");
    NSInteger state = ((NSInteger (*)(id, SEL))AevonOriginalApplicationState)(application, cmd);
    return state == 0;                     // UIApplicationStateActive
}

/// 现在的窗口有多高。与心跳用的是同一把尺子（key window 优先），所以两处读数
/// 不会互相打架。
static CGFloat AevonWindowHeight(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return 0.0;
    CGFloat height = 0.0;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)one windows]) {
            CGFloat h = [win bounds].size.height;
            if (h > 200.0 && (height < 200.0 || [win isKeyWindow])) height = h;
        }
    }
    return height;
}

/// 0.0.77 — 视口顶压着的那一页（子视图），不是「最高的那个」。
///
/// `AevonCellFrameOf` 取的是「最高的一个」，用来答「一页多高」足够；但归位要的是
/// 「用户正看着哪一页」，那是**包含视口顶**的那一个。混装时两者常常不是同一个 ——
/// 一页 932、一页 717，最高的是 932 那页，而用户看的是 717 那页。
static UIView *AevonPageKidAt(UIScrollView *view, CGFloat box, CGFloat y) {
    UIView *best = nil;
    CGFloat bestGap = 0.0;
    int bestInside = 0;
    NSArray *kids = [view subviews];
    NSUInteger limit = kids.count < 16 ? kids.count : 16;
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *kid = [kids objectAtIndex:i];
        CGRect f = [kid frame];
        // 只认「一页大小」的子视图：页头、贴片、滚动条不是页。
        if (f.size.height < box * 0.5 || f.size.height > box * 1.5) continue;
        int inside = (f.origin.y <= y + 0.5 && y < CGRectGetMaxY(f)) ? 1 : 0;
        CGFloat gap = fabs(f.origin.y - y);
        if (best == nil || (inside && !bestInside)
            || (inside == bestInside && gap < bestGap)) {
            best = kid;
            bestGap = gap;
            bestInside = inside;
        }
    }
    return best;
}

/// 0.0.79 — 数一页里「在播」与「停着」的播放器。
///
/// 只走公开属性：`AVPlayerLayer.player`、`AVPlayer.rate`。类名从
/// `NSClassFromString` 取，不为此新链一个 AVFoundation —— 这个 dylib 装进每一
/// 个 App 进程，多一条依赖就多一次「某个进程加载失败」的机会。
///
/// 返回值是**正在播**的个数；`pausedOut` 是停着的个数，`firstOut` 是第一个停着的
/// 播放器（要 play 的就是它）。`-1` 表示这台系统上没有 AVPlayerLayer 这个类。
static int AevonPlayerScan(UIView *root, int *pausedOut, id *firstOut) {
    if (pausedOut != NULL) *pausedOut = 0;
    if (firstOut != NULL) *firstOut = nil;
    if (root == nil) return 0;
    Class layerClass = NSClassFromString(@"AVPlayerLayer");
    if (layerClass == Nil) return -1;
    int playing = 0;
    // 只走**图层树**，不走视图树：视图树的每一层在图层树里都有对应的一份，走两遍
    // 只会把同一个播放器数两次。预算 3000 个层 —— 一次开卡只跑三拍，而一个 feed
    // 页的层数是几千的量级，这个上限刚好翻得完又不会为它卡一帧。
    CALayer *start = [root layer];
    if (start == nil) return 0;
    NSMutableArray *todo = [NSMutableArray arrayWithObject:start];
    int budget = 3000;
    while (todo.count > 0 && budget > 0) {
        CALayer *layer = [todo lastObject];
        [todo removeLastObject];
        budget -= 1;
        if ([layer isKindOfClass:layerClass]) {
            id player = nil;
            NSNumber *rate = nil;
            @try {
                player = [layer valueForKey:@"player"];
                rate = [player valueForKey:@"rate"];
            } @catch (NSException *exception) {
                (void)exception;
            }
            if (player != nil) {
                if ([rate isKindOfClass:[NSNumber class]] && [rate doubleValue] > 0.01) {
                    playing += 1;
                } else {
                    if (pausedOut != NULL) *pausedOut += 1;
                    if (firstOut != NULL && *firstOut == nil) *firstOut = player;
                }
            }
        }
        NSArray *kids = [layer sublayers];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }
    return playing;
}

/// 换屏之前的那一拍：记下「视口压着的这一页」里有几个在播。
///
/// 只看这一页，不看整棵窗口：抖音会预加载相邻几页，那些播放器本来就该是停的，
/// 对它们 play 会让两条音轨一起响。而用户正在看的那一页，换屏前后是同一页
/// （行下标把它钉住了），所以「这一页之前在播」是一个能跨过换屏的判据。
static void AevonPlayNote(void) {
    AevonPlayBefore = 0;
    UIScrollView *view = AevonPagerGet();
    if (view == nil) return;
    CGRect box = [view bounds];
    UIView *kid = AevonPageKidAt(view, box.size.height, [view contentOffset].y);
    if (kid == nil) return;
    int paused = 0;
    int playing = AevonPlayerScan(kid, &paused, NULL);
    AevonPlayBefore = playing > 0 ? playing : 0;
    // 一行就够：`was=0` 说明我们这次不打算管（用户本来就停着，或者这一页上没有
    // AVPlayerLayer）；`was=1 paused=2` 说明看得见播放器、其中两个是停的。
    if (AevonPlayNotes < 8) {
        AevonPlayNotes += 1;
        char body[160];
        snprintf(body, sizeof(body), "play note was=%d paused=%d",
                 AevonPlayBefore, paused);
        AevonPageWrite(body);
    }
}

/// 换屏之后的几拍：本来在播、现在停了，就替它按一下 play。
///
/// 三拍（0.5 / 1.2 / 2.2 s）而不是一拍：App 的「停」与「该回来了」不一定在同一
/// 帧里发生，第一拍撞见停着的播放器也可能只是它自己还没开始缓冲。每拍先看
/// 有没有已经播起来的 —— 有一台在播就收工，绝不与 App 抢方向盘。
///
/// 上限 3 次：真机上「点一下暂停再点一下」就恢复，说明播放器本身是好的，
/// 需要按三次以上就说明这不是「少了一次 play」，再按也只是重复。
static void AevonResumeTick(void *context) {
    const char *reason = (const char *)context;
    if (!AevonEverHosted) return;
    if (AevonPlayBefore <= 0) return;
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    CGRect box = [view bounds];
    UIView *kid = AevonPageKidAt(view, box.size.height, [view contentOffset].y);
    if (kid == nil) return;
    int paused = 0;
    id first = nil;
    int playing = AevonPlayerScan(kid, &paused, &first);
    if (playing < 0) {
        AevonPlayBefore = 0;
        AevonPageWrite("resume mute no AVPlayerLayer");
        return;
    }
    if (playing > 0) {
        AevonPlayBefore = 0;
        char body[140];
        snprintf(body, sizeof(body), "resume ok %s playing=%d", reason, playing);
        AevonPageWrite(body);
        return;
    }
    if (first == nil) {
        AevonPlayBefore = 0;
        char body[140];
        snprintf(body, sizeof(body), "resume gone %s playing=0 paused=0", reason);
        AevonPageWrite(body);
        return;
    }
    if (AevonResumes >= 3) return;
    SEL play = sel_registerName("play");
    if (![first respondsToSelector:play]) return;
    AevonResumes += 1;
    ((void (*)(id, SEL))objc_msgSend)(first, play);
    char body[180];
    snprintf(body, sizeof(body), "resume play %s was=%d paused=%d n=%d",
             reason, AevonPlayBefore, paused, AevonResumes);
    AevonPageWrite(body);
}

/// 三拍共用的那一句：日志里 `resume …` 后面跟的就是它。
static char AevonResumeWhy[] = "after switch";

/// 把一个「页」换算成它的行下标。`UITableView` / `UICollectionView` 各一套，
/// 都不是就放弃 —— 那就只剩 `frame` 可用，也就是 0.0.76 之前的处境。
static BOOL AevonKidIndexPath(UIScrollView *view, UIView *kid,
                              NSInteger *sectionOut, NSInteger *rowOut) {
    if (kid == nil) return NO;
    NSIndexPath *path = nil;
    if ([view isKindOfClass:[UITableView class]]
        && [kid isKindOfClass:[UITableViewCell class]]) {
        path = [(UITableView *)view indexPathForCell:(UITableViewCell *)kid];
    } else if ([view isKindOfClass:[UICollectionView class]]
               && [kid isKindOfClass:[UICollectionViewCell class]]) {
        path = [(UICollectionView *)view indexPathForCell:(UICollectionViewCell *)kid];
    }
    if (path == nil) return NO;
    if (sectionOut != NULL) *sectionOut = [path section];
    if (rowOut != NULL) *rowOut = [path item];
    return YES;
}

/// 向 App 现问「这一页现在在哪」。
///
/// `rectForRowAtIndexPath:` 报的是排版结果 —— 它把上面每一页当前的高度加起来，
/// 所以那个数里自动含有「还没重排的 215」，不需要我们知道上面有几行是旧的。
static BOOL AevonIndexPathRect(UIScrollView *view, NSInteger section, NSInteger row,
                               CGRect *out) {
    if (section < 0 || row < 0) return NO;
    NSIndexPath *path = [NSIndexPath indexPathForItem:row inSection:section];
    if ([view isKindOfClass:[UITableView class]]) {
        CGRect r = [(UITableView *)view rectForRowAtIndexPath:path];
        if (r.size.height < 120.0) return NO;
        if (out != NULL) *out = r;
        return YES;
    }
    if ([view isKindOfClass:[UICollectionView class]]) {
        UICollectionViewLayoutAttributes *attributes =
            [(UICollectionView *)view layoutAttributesForItemAtIndexPath:path];
        if (attributes == nil) return NO;
        CGRect r = [attributes frame];
        if (r.size.height < 120.0) return NO;
        if (out != NULL) *out = r;
        return YES;
    }
    return NO;
}

/// 0.0.77 — 尺寸变化那一拍：把「用户在看哪一帖」钉成行下标。
///
/// 必须在这一拍做，因为这是唯一还能看见旧几何的时刻 —— 之后 `bounds` 就变了，
/// 视口顶落在哪一页只能靠猜。钉住之后无论 App 怎么重排、怎么自己吸附，我们都
/// 能回到同一帖：`AevonIndexPathRect` 会跟着它的行原点一起走。
static void AevonAnchorRemember(UIScrollView *view, CGFloat box) {
    AevonAnchorSet = 0;
    AevonAnchorSection = -1;
    AevonAnchorRow = -1;
    AevonAnchorWrites = 0;
    if (view == nil || box < 200.0) return;
    CGFloat y = [view contentOffset].y;
    UIView *kid = AevonPageKidAt(view, box, y);
    NSInteger section = -1;
    NSInteger row = -1;
    BOOL ok = AevonKidIndexPath(view, kid, &section, &row);
    char body[220];
    snprintf(body, sizeof(body),
             "anchor keep row=%ld,%ld at=%.0f page=%.0f box=%.0f frame=%.0f h=%.0f ok=%d",
             (long)section, (long)row, y, box, [view bounds].size.height,
             kid != nil ? [kid frame].origin.y : -1.0,
             kid != nil ? [kid frame].size.height : 0.0, ok ? 1 : 0);
    AevonPageWrite(body);
    if (!ok) return;
    AevonAnchorSection = section;
    AevonAnchorRow = row;
    AevonAnchorSet = 1;
}

/// 0.0.76 — 页高到底齐不齐。
///
/// 0.0.75 的 `state` 行里已经有 `clean=/stale=` 两个数，但它只是读数，判据还在
/// 后面按「哪条公式更可信」去挑。Aevon(66) 把那个挑法判死了：
///
///   15:48:25 page settle snap clean y=1864 -> 2151 at=2151 clean=2 stale=1
///   15:48:25 page settle scroll y=2151 -> 1864 page=932 box=932 cell=932 stale
///
/// 同一秒里两行互相打脸：第一行把视口摆到「真的按 932 重排过的那一页」上（对的），
/// 第二行又把它按 `round(y/932)*932` 挪走（错的）。**两条公式同时在写同一个 offset，
/// 后一条必然覆盖前一条**，而混装几何里 `N × 932` 落点正好在两页之间 —— 断层是我们
/// 自己按出来的，不是 App 留下的。
///
/// 所以判据从「选公式」改成「开不开工」：页高不齐就一帧 offset 都不写，只请 App
/// 重排（`AevonPagerRebuild`）。三个数一次算完，两处读数（state / rebuild）共用。
/// 0.0.80 — 只数**压着视口的那几页**，不数已经被回收、躺在视口外面的旧页。
///
/// Aevon(71) 把这条判据的错误写在了时间戳上：
///
///   16:57:24 state box=430x717 off=0,0 k0=AWEFeedViewCell:932,932x430 k2=…:0,717x430
///   16:57:24 rebuild settle … clean=1 stale=1 top=717 box=717      ← 每 0.25 s 一次
///   16:57:27 同上，连续 9 条
///
/// 视口是 0–717，`k2`（0,717 高）正压在视口上，是最干净的一页；`k0` 在 y=932，
/// 整页都在视口**下面**，是刚才那一轮复用留下的、还没被重新量过的旧行。它不影响
/// 任何人看到的东西 —— 用户滑到它时它会被重建、按当下高度量一次。
///
/// 旧判据把它算成 `stale`，于是 `stale>0` 永远成立，`AevonPagerRebuild` 就去作废
/// 行高缓存（`beginUpdates/endUpdates` = 整表重排）。一次开卡 12 次、每 0.25 s
/// 一次，连续三秒 —— 这三秒里 App 主线程在反复重排整张表：画面不动、滑动不响应。
/// 切后台之所以能救回来，是因为窗口一脱离，`AevonPagerWatchTick` 的 `[view window]`
/// 那道门就关了，风暴自己停下。
static void AevonPagerStats(UIScrollView *view, CGFloat box,
                            int *cleanOut, int *staleOut, int *alignedOut) {
    int clean = 0;
    int stale = 0;
    CGFloat y = [view contentOffset].y;
    NSArray *kids = [view subviews];
    NSUInteger limit = kids.count < 12 ? kids.count : 12;
    for (NSUInteger i = 0; i < limit; i++) {
        CGRect f = [[kids objectAtIndex:i] frame];
        CGFloat h = f.size.height;
        // 「一页」只可能落在视口高的一半到一个半之间：页头、贴片、滚动条不是页。
        if (h < box * 0.5 || h > box * 1.5) continue;
        // 整页都在视口上边 / 下边：回收池里的旧行，不在这一屏里，不算数。
        if (CGRectGetMaxY(f) <= y + 2.0) continue;
        if (f.origin.y >= y + box - 2.0) continue;
        if (fabs(h - box) <= 2.0) clean += 1;
        else stale += 1;
    }
    // 内容高度是不是视口的整数倍。混装时它一定不是 —— `8102 = 10 × 717 + 932`。
    CGFloat inBox = round([view contentSize].height / box);
    int aligned = (inBox >= 2.0
                   && fabs([view contentSize].height - inBox * box) <= 24.0) ? 1 : 0;
    if (cleanOut != NULL) *cleanOut = clean;
    if (staleOut != NULL) *staleOut = stale;
    if (alignedOut != NULL) *alignedOut = aligned;
}

/// 0.0.76 — 唯一允许的动作：**请 App 自己把它自己的页重新排一遍**。
///
/// 为什么这件事必须由 App 来做。0.0.71 到 0.0.75 五版都在算 offset，而 Aevon(66)
/// 的读数证明算不出来：关窗之后 App 只把「当前这一页」放大到 932，其余页还是 717，
/// 而它们的**起点仍是按 717 排的**（`k0=3585 k1=2868`，前一页 932 高却只隔 717）。
/// 于是同一屏上必然叠着两页：摆在 `3585` 上，`2868` 那一页的尾巴仍然压在上面 215 pt；
/// 摆在 `2868` 上，反过来的那 215 pt 又露在下面。**这个几何里没有干净的落点**，
/// 不是公式挑得不对。
///
/// App 自己知道怎么重排 —— 它把当前页改成 932 的那一次，用的就是当前 bounds。
/// 缺的只是「其余页也过一遍」这个信号。这里发的正是那个信号，而且用的是系统的
/// 标准说法，不是替它排版：
///
///   · 翻页器是 `UICollectionView` → 让它的 layout 作废（`invalidateLayout`）。
///     系统会在下一次布局里重新问代理要每一页的位置，页高自然跟着 bounds 走。
///   · 不是 → 只 `setNeedsLayout`，让翻页器自己的 `layoutSubviews` 决定。
///
/// **只置脏，不逼它当场排完。** 0.0.65 / 0.0.67 的两次真机事故（应用打不开、桌面
/// 黑屏、小组件空白）里，第二个动作正是「替别人的窗口补一次 layoutIfNeeded」，
/// 所以这一版连 `layoutIfNeeded` 都不出现：谁排、什么时候排，仍然是 App 自己的事。
/// 0.0.78 — 请表格把**行高缓存**作废，而不是只让它重画。
///
/// Aevon(68) 的关卡那一拍把 0.0.76/0.0.77 的前提推翻了：
///
///   16:17:56 page anchor keep row=0,4 at=3513 page=717 box=717 frame=3513 h=717 ok=1
///   16:17:56 page align on resize y=3728 -> 3513 row=3513 h=717 box=932
///   16:17:56 page state after change box=430x932 off=0,3513 k1=AWEFeedViewCell:3513,717x430
///   16:18:00 page state after change box=430x932 off=0,3513 k1=AWEFeedViewCell:3513,717x430
///
/// 我们把视口摆在「那一帖」的行原点上（3513，没算错），可**那一行本身还是 717 高**，
/// 而视口已经是 932 —— 于是下面必然露出 215 pt 的下一条（932 − 717）。四秒过去，
/// `k1` 还是 `717x430`：`setNeedsLayout` 让表格**重画**了，但没有重新问「这一行该
/// 多高」。屏幕中间那条缝不是我们算错位置，是行高没跟着窗口走。
///
/// 为什么之前以为它会自己跟：同一份日志里 `16:17:51 inside settle … c1=717 b=430x717`
/// 那一行说明它**确实会**变成 717 —— 但只在单元格被重新创建（划走再划回、复用到）
/// 的时候。已有的行，高度被 UITableView 缓存在内部表里，`setNeedsLayout` 不碰它。
///
/// 系统的标准说法是 `beginUpdates` / `endUpdates`：它作废行高缓存并重新问一遍
/// 「这一行多高」，**不重建单元格、不动数据源**（所以正在播的那一帧不会重来）。
/// 这两句包在 `performWithoutAnimation:` 里，改高度不带动画；外面套 `@try` ——
/// 万一 App 正好在自己的更新里，抛异常的是我们，不该是它。
static BOOL AevonTableRemeasure(UITableView *table) {
    if (table == nil) return NO;
    if ([table numberOfSections] < 1) return NO;
    BOOL began = NO;
    @try {
        [UIView performWithoutAnimation:^{
            [table beginUpdates];
        }];
        began = YES;
    } @catch (NSException *one) {
        began = NO;
    }
    if (!began) return NO;
    @try {
        [UIView performWithoutAnimation:^{
            [table endUpdates];
        }];
        return YES;
    } @catch (NSException *two) {
        return NO;
    }
}

static NSInteger AevonPagerRebuild(const char *reason) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return -1;
    if ([view isTracking] || [view isDragging] || [view isDecelerating]) return -1;
    CGRect box = [view bounds];
    if (box.size.height < 200.0) return -1;
    int clean = 0;
    int stale = 0;
    int aligned = 0;
    AevonPagerStats(view, box.size.height, &clean, &stale, &aligned);
    // 已经齐了：不是重建的对象。
    if (stale == 0 && aligned) return 0;
    // 0.0.80 — 上一次发完、这一拍再看，页高一点没动 ⇒ 这口它不吃，别再发。
    if (AevonRebuildDead) return -1;
    if (AevonRebuilds >= 4) return -1;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // 0.35 s 的间隔：App 的重排本身要一两帧，连发只是把同一次重排排队。
    if (AevonRebuildAt > 0.0 && now - AevonRebuildAt < 0.35) return -1;
    // 发之前先量：视口那一页现在多高。上一次发的效果只会在**这一次**的读数里出现，
    // 所以验收点天然落在这里，不需要额外的延时拍。
    UIView *probe = AevonPageKidAt(view, box.size.height, [view contentOffset].y);
    CGFloat beforeTop = probe != nil ? [probe frame].size.height : 0.0;
    if (AevonRebuildTop > 200.0 && beforeTop > 200.0
        && fabs(beforeTop - AevonRebuildTop) < 1.0 && stale > 0) {
        AevonRebuildSame += 1;
    } else {
        AevonRebuildSame = 0;
    }
    if (AevonRebuildSame >= 2) {
        AevonRebuildDead = 1;
        char stop[220];
        snprintf(stop, sizeof(stop), "rebuild stop n=%d top=%.0f box=%.0f stale=%d",
                 AevonRebuildSame, beforeTop, box.size.height, stale);
        AevonPageWrite(stop);
        return -1;
    }
    AevonRebuildAt = now;
    AevonRebuilds += 1;
    AevonRebuildTop = beforeTop;

    BOOL collection = [view isKindOfClass:[UICollectionView class]];
    BOOL table = [view isKindOfClass:[UITableView class]];
    NSString *layoutName = @"-";
    CGSize item = CGSizeZero;
    if (collection) {
        UICollectionViewLayout *layout = [(UICollectionView *)view collectionViewLayout];
        if (layout != nil) {
            layoutName = NSStringFromClass([layout class]);
            // `itemSize` 不是每个 layout 都声明：KVC 取值，取不到就留 0。
            id size = AevonTryValue(layout, @"itemSize");
            if ([size isKindOfClass:[NSValue class]]) {
                [size getValue:&item size:sizeof(item)];
            }
            [layout invalidateLayout];
        }
    }
    // 0.0.78 — 表格走「作废行高缓存」这条路；`setNeedsLayout` 只够让它重画。
    BOOL remeasured = table ? AevonTableRemeasure((UITableView *)view) : NO;
    [view setNeedsLayout];
    // 视口顶压着的那一行现在有多高。这一列是 0.0.78 唯一的判据：
    // 它在下一次日志里变成 932（关卡后）或 717（开卡后），就说明这条信号送到了。
    UIView *topKid = AevonPageKidAt(view, box.size.height, [view contentOffset].y);
    char body[420];
    snprintf(body, sizeof(body),
             "rebuild %s cls=%s<%s> cv=%d tbl=%d layout=%s item=%.0fx%.0f "
             "clean=%d stale=%d span=%.0f box=%.0f top=%.0f r=%d",
             reason, class_getName([view class]),
             class_getName(class_getSuperclass([view class])),
             collection ? 1 : 0, table ? 1 : 0, [layoutName UTF8String],
             item.width, item.height, clean, stale,
             [view contentSize].height, box.size.height,
             topKid != nil ? [topKid frame].size.height : 0.0,
             remeasured ? 1 : 0);
    AevonPageWrite(body);
    return 1;
}

/// 0.0.74 — 把翻页器此刻的形状一次说完。
///
/// Aevon(64) 的日志证明了一件互相矛盾的事：换算**写对了**，断层**还在**。
/// 关卡那一拍写的是 `transition scroll y=2151 -> 2796`，2796 = 3 × 932，一个干净
/// 的整页；而录屏里那个帖子只露出 168 pt（932 - 764），下面接着下一个帖子。
/// 只有两种可能：写完 2796 之后 App 又把它挪到了别处，或者它的「一页」根本不是
/// 932。这两件事互斥，而手上一条能分辨它们的读数都没有。
///
/// 这一行就是那个读数。`kids` 是页本身（抖音的翻页器是一屏一个子视图），
/// `k0/k1/k2` 带原点与高度 —— `0.0x932 / 932.0x932` 与 `0.0x764 / 764.0x764`
/// 会把两个世界当场分开，不用再猜。
static void AevonPageState(const char *reason) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) {
        char body[120];
        snprintf(body, sizeof(body), "state %s pager none", reason);
        AevonPageWrite(body);
        return;
    }
    CGRect box = [view bounds];
    CGSize span = [view contentSize];
    CGPoint off = [view contentOffset];
    CGRect cell = AevonCellFrameOf(view, box.size.height);
    NSArray *kids = [view subviews];
    NSUInteger n = kids.count < 4 ? kids.count : 4;
    // 0.0.75 — 数一遍「几种页高同时存在」。Aevon(65) 已经把答案写在算术里：
    // span=8102 = 10 × 717 + 932 —— 十一页里只有一页按新高度重排过，其余十页
    // 还是旧高度。这个数不再靠人算，直接印出来。
    int cleanN = 0;
    int staleN = 0;
    for (NSUInteger i = 0; i < kids.count && i < 12; i++) {
        CGFloat h = [[kids objectAtIndex:i] frame].size.height;
        if (h < 120.0) continue;
        if (fabs(h - box.size.height) <= 2.0) cleanN += 1;
        else if (AevonOldPage > 200.0 && fabs(h - AevonOldPage) <= 2.0) staleN += 1;
    }
    char body[720];
    int at = snprintf(body, sizeof(body),
                      "state %s box=%.0fx%.0f span=%.0fx%.0f off=%.0f,%.0f "
                      "cell=%.0f,%.0f,%.0fx%.0f kids=%lu clean=%d stale=%d",
                      reason, box.size.width, box.size.height,
                      span.width, span.height, off.x, off.y,
                      cell.origin.x, cell.origin.y, cell.size.width, cell.size.height,
                      (unsigned long)kids.count, cleanN, staleN);
    for (NSUInteger i = 0; i < n; i++) {
        if (at < 0 || at > (int)sizeof(body) - 60) break;
        UIView *kid = [kids objectAtIndex:i];
        CGRect f = [kid frame];
        // 类名也带上：下一次如果还要判断「这到底是 UICollectionView 的 cell 还是
        // 自己写的复用视图」，答案就在这一列里，不必再猜一轮。
        at += snprintf(body + at, sizeof(body) - (size_t)at, " k%lu=%.28s:%.0f,%.0fx%.0f",
                       (unsigned long)i, class_getName([kid class]),
                       f.origin.y, f.size.height, f.size.width);
    }
    AevonPageWrite(body);
}

/// 0.0.82 — 「整屏画布」这条路**撤掉了**。0.0.79 装过它，Aevon(72) 撤了。
///
/// 当时的理由是成立的：哔哩哔哩竖版那一页就是 932 高（`BBStoryPortraitCardCell:0,0,430x932`），
/// 5:3 的卡只有 717，右侧那一列按钮的下半截必然在框外。于是 0.0.79 让 App 在
/// 自己的 tmp 里写一个记号（`aevon-full`），宿主下一次开卡时给整屏画布，卡片按
/// 整屏比例缩 —— 整页看得见。
///
/// 问题不在判据，在**记号的寿命**：一次判定变成了一条永久的政策。0.0.81 的分账
/// （卡片恒 5:3、画布按等比装进去）把它变成了看得见的东西 —— Aevon(73) 的读数：
///
///   win: fat scene ratio=1.667 screen=430x932 render=430x932 full=1 ... card=366x610
///   win: scale factor=0.655 shown=282x610 fill=366x610
///   win: letterbox side=42pt flat=1 canvas=430x932
///
/// 430×932 装进 366×610，两边各让 42 pt：卡片是 5:3 的，画面是 9:19.5 的，
/// 中间那条黑边就是「这个 App 被一份旧记号按整屏排版」的形状。用户的原话是
/// 「虽然悬浮窗的尺寸是 5:3，但是内容却是 16:9，并且两边存在黑边」，并且给了
/// 判决：**主页面按 5:3 真重排**优先于「竖版那一页显示不全」。
///
/// 所以这里不再留记号，也不再有第二个画布来源：画布恒等于卡片的形状（5:3），
/// App 就按 717 排。`stuck` 那几行读数留着（它仍然在量、仍然在置脏），只是不再
/// 换画布 —— 竖版那一页被切掉的 215 pt 是产品形状的账，不拿整台机器的观感去换。

/// 0.0.78 — 「App 没跟上」这一族：翻页器比窗口还高。
///
/// Aevon(68) 的哔哩哔哩竖版把这一类摊开了：
///
///   16:19:23 app: geom early screen=430x932 scene=430x717 win=430x717 root=430x717
///   16:19:23 app: geom early peers3 n=1 UIScrollView:0,0,430x932
///   16:19:23 app: geom early peers6 UIView:0,0,430x838|BBStoryBaseTableView:0,0,430x932
///
/// 窗口、根视图、导航容器全是 717，翻页器却是 932 —— 比窗口高出 215。它不是「行高
/// 没跟上」，是**翻页器自己的 frame 还按整屏排着**。于是卡片只看得见它上面 717 pt，
/// 下面那 215 pt 连画都没画进我们的场景（竖版故事右侧那一列按钮正好长在这一截里）。
///
/// 这条路上没有可以「算」的余地：内容就那么多，窗口就那么高。能做的是两件便宜事，
/// 都不改任何尺寸：
///   ① 把翻页器上面三层**置脏**（`setNeedsLayout`，不逼它排版）—— 若它的 frame 是
///      autolayout 排出来的，下一帧自己就变成 717，归位流程当场接上；
///   ② 记一行 `stuck …`，并列出「底边落在窗口以下」的叶子视图。下一份日志里
///      `box` 变成 717 就是①成立；一直 932 则说明这个 App 是按 `UIScreen` 高度硬排
///      的，5:3 的卡装不下它 —— 那是产品形状的账，不是判据的账。
static void AevonStuckReport(const char *reason, CGFloat box, CGFloat full) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    if (AevonStuckLines >= 6) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonStuckAt > 0.0 && now - AevonStuckAt < 2.5) return;
    AevonStuckAt = now;
    AevonStuckLines += 1;

    // ① 只置脏，不逼排版：谁排、什么时候排，仍然是 App 自己的事。
    UIView *owner = view;
    for (int i = 0; i < 3; i++) {
        owner = [owner superview];
        if (owner == nil) break;
        [owner setNeedsLayout];
    }

    UIView *kid = AevonPageKidAt(view, box, [view contentOffset].y);
    char body[360];
    snprintf(body, sizeof(body),
             "stuck %s box=%.0f full=%.0f cls=%s<%s> span=%.0f kid=%.0f n=%d",
             reason, box, full, class_getName([view class]),
             class_getName(class_getSuperclass([view class])),
             [view contentSize].height,
             kid != nil ? [kid frame].size.height : 0.0, AevonStuckLines);
    AevonPageWrite(body);
    if (kid == nil) return;

    // ② 被切掉的是谁：在翻页器坐标里，底边落在窗口以下的叶子视图。
    NSMutableArray *todo = [NSMutableArray arrayWithObject:kid];
    NSMutableString *list = [NSMutableString string];
    NSUInteger walked = 0;
    int found = 0;
    while (todo.count > 0 && walked < 800 && found < 5) {
        UIView *node = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        NSArray *kids = [node subviews];
        for (NSUInteger i = 0; i < kids.count && i < 24; i++) {
            [todo addObject:[kids objectAtIndex:i]];
        }
        if (kids.count > 0) continue;
        if (node == kid) continue;
        CGRect r = [node convertRect:[node bounds] toView:view];
        if (r.size.width < 12.0 || r.size.height < 12.0) continue;
        if (CGRectGetMaxY(r) <= full + 2.0) continue;
        found += 1;
        [list appendFormat:@" %.24s:%.0f,%.0f,%.0fx%.0f",
         class_getName([node class]), r.origin.x, r.origin.y,
         r.size.width, r.size.height];
    }
    if (list.length == 0) return;
    char cut[520];
    snprintf(cut, sizeof(cut), "stuck cut%s (below the window)", [list UTF8String]);
    AevonPageWrite(cut);
}

/// 0.0.80 — App 自己弹出来的浮层有多高，以及它被切掉的那一截里有什么。
///
/// Aevon(71) 的第二件事：卡片里点抖音的「分享」，只看得见联系人头像，底部的
/// 发送按钮不见了。这类面板是**从屏幕底边往上**摆的（`y = 屏幕高 − 面板高`），
/// 而卡片交给 App 的是 717 高的画布 —— 932 − 717 = 215，正好是底部那一截。
/// 面板按 932 摆、被 717 的窗口裁掉下面 215，按钮就活在被裁掉的那一截里。
///
/// 这一版不去动它（把面板往上推是替 App 排版，改画布又会让卡片变窄），只把两件
/// 事量清楚：**是哪一层、多高、被切掉的叶子视图在什么位置**。下一版才有得选。
static int AevonSheetLines = 0;
static char AevonSheetSeen[96] = {0};
static CGFloat AevonSheetH = 0.0;

static UIWindow *AevonKeyWindow(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return nil;
    UIWindow *best = nil;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)one windows]) {
            if ([win bounds].size.height < 200.0) continue;
            if (best == nil || [win isKeyWindow]) best = win;
        }
    }
    return best;
}

static void AevonSheetReport(void) {
    if (AevonSheetLines >= 6) return;
    UIWindow *win = AevonKeyWindow();
    if (win == nil) return;
    UIViewController *top = [win rootViewController];
    if (top == nil) return;
    int hops = 0;
    while ([top presentedViewController] != nil && hops < 6) {
        top = [top presentedViewController];
        hops += 1;
    }
    if (hops == 0) return;                 // 没有浮层，这条路不开口
    UIView *sheet = [top view];
    if (sheet == nil) return;
    CGRect r = [sheet convertRect:[sheet bounds] toView:win];
    if (r.size.height < 200.0) return;
    NSString *name = NSStringFromClass([top class]);
    const char *cls = name.length > 0 ? [name UTF8String] : "-";
    CGFloat winH = [win bounds].size.height;
    // 同一层、同一高度只记一次：浮层开着的时候这条时钟还在跑。
    if (strncmp(AevonSheetSeen, cls, sizeof(AevonSheetSeen) - 1) == 0
        && fabs(r.size.height - AevonSheetH) < 2.0) {
        return;
    }
    strncpy(AevonSheetSeen, cls, sizeof(AevonSheetSeen) - 1);
    AevonSheetSeen[sizeof(AevonSheetSeen) - 1] = '\0';
    AevonSheetH = r.size.height;
    AevonSheetLines += 1;
    char body[300];
    snprintf(body, sizeof(body), "sheet %.32s h=%.0f top=%.0f box=%.0f",
             cls, r.size.height, r.origin.y, winH);
    AevonPageWrite(body);
    if (CGRectGetMaxY(r) <= winH + 40.0) return;

    // 被切掉的是谁：在窗口坐标里，底边落在窗口以下的叶子视图。
    NSMutableArray *todo = [NSMutableArray arrayWithObject:sheet];
    NSMutableString *list = [NSMutableString string];
    NSUInteger walked = 0;
    int found = 0;
    while (todo.count > 0 && walked < 900 && found < 5) {
        UIView *node = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        NSArray *kids = [node subviews];
        for (NSUInteger i = 0; i < kids.count && i < 24; i++) {
            [todo addObject:[kids objectAtIndex:i]];
        }
        if (kids.count > 0) continue;
        CGRect leaf = [node convertRect:[node bounds] toView:win];
        if (leaf.size.width < 12.0 || leaf.size.height < 12.0) continue;
        if (CGRectGetMaxY(leaf) <= winH + 2.0) continue;
        found += 1;
        [list appendFormat:@" %.24s:%.0f,%.0f,%.0fx%.0f",
         class_getName([node class]), leaf.origin.x, leaf.origin.y,
         leaf.size.width, leaf.size.height];
    }
    if (list.length == 0) return;
    char cut[520];
    snprintf(cut, sizeof(cut), "sheet cut%s (below the window)", [list UTF8String]);
    AevonPageWrite(cut);
}

/// 0.0.82 — 分享面板：把「屏幕底边」和「窗口底边」之间那一段让出来。
///
/// Aevon(71)/(72)/(73) 三轮都是同一句：卡里点抖音「分享」，只看得见联系人头像，
/// 底部的发送按钮不在。0.0.80 量清楚了一件事 —— 面板不是没画，是被窗口切掉了：
///
///   app: page sheet DUXSheetNavigationController h=932 top=0 box=717
///   app: page sheet cut UILabel:376,853,76x14 UIImageView:425,822,21x24 … (below the window)
///
/// 面板的 view 是 **430×932**（App 按 `UIScreen` 高排的），窗口只有 717。它从
/// y=0 一直铺到 932，所以被切掉的正好是最后 215 pt —— 而这类面板是**从屏幕底边
/// 往上摆**的，底部那一截就是按钮行（786…867，读数里全在那里）。
///
/// 不做的事先写明：不去改 `UIScreen`（0.0.65 / 0.0.67 两次事故），也不把窗口拉
/// 成 932（那等于整屏画布，Aevon(73) 已经判过）。这里只做一件事 —— **把这一张
/// 浮层整体往上抬 `溢出` 这么多**，让它自己的底边和窗口的底边对齐。
///
/// 为什么这是划算的：抬之前看不见的是 y∈[717, 932]，抬之后看不见的是 y∈[0, 215]，
/// 面积一样，但后者是这类面板的空白/遮罩区，前者是按钮。这不是替 App 排版，是
/// 把「屏幕差 215」这件事补在唯一能补的一层上 —— 而且只碰这一张浮层，卡片、
/// 画布、别的窗口一个都不动。
///
/// 三条守卫，任何一条不成立就什么都不做（最坏情况就是今天这样）：
///   · 只有「本来就比窗口高」的面板才归我们管（矮面板本就该露在窗口里）；
///   · 上一眼和这一眼底边一致（面板停稳）才动手，入场动画途中不碰；
///   · 一张浮层最多抬 4 次 —— App 自己把 frame 改回去时补一次，改不回来就算了。
///
/// 0.0.83 — 慢了一秒，是节拍问题，不是判据问题。
///
/// Aevon(74) 的读数是：
///
///   17:46:46  app: page sheet DUXSheetNavigationController h=932 top=0 box=717
///   17:46:47  app: page sheet lift by=215 h=932 box=717 n=1
///
/// 中间那一秒，用户看见的是「只有联系人头像、没有发送按钮」的半截面板，然后它
/// 自己往上跳一下。三个 0.6 叠出来的：心跳 0.15 s 但只在**每 4 拍**看一次浮层
/// （0.6 s，0.0.82 写的），又要**连续两拍**底边一致（再 0.6 s）。0.6 + 0.6 ≈ 1 s，
/// 和读数一模一样。
///
/// 这一版把那两个 0.6 都拿掉，换成「看一眼 → 隔 60 ms 再看一眼」：
///   · 浮层扫描并入每一拍心跳（读一条 `presentedViewController` 链，便宜）；
///   · 第一次看见只记录，60 ms 后补看一次（面板的真几何在这段时间里就定了），
///     两眼底边一致立刻抬 —— 最坏 0.15 + 0.06 ≈ 0.2 s，通常 60~90 ms；
///   · 抬完还复看：App 若把 frame 又改回去（或我们抬过头），按**残差**再抬/回落
///     一次，所以「抬多少」不再是一次性下注，而是会收敛的。
///
/// 抬的时机仍在面板的入场动画之内，所以它落位时已经是正确的高度 —— 用户看到的
/// 是「面板长出来就在对的位置」，而不是「长出来、停一下、再跳上去」。
static int AevonLiftCount = 0;
static void *AevonLiftSheet = NULL;
static CGFloat AevonLiftSeen = 0.0;
static double AevonLiftSight = 0.0;
static int AevonLiftSoon = 0;

static void AevonSheetLift(void);

/// 60 ms 后的补看。只在「第一次看见这张浮层」时排一次，不递归堆积。
static void AevonSheetLiftAgain(void) {
    AevonLiftSoon = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonLiftSoon = 0;
        AevonSheetLift();
    });
}

static void AevonSheetLift(void) {
    UIWindow *win = AevonKeyWindow();
    if (win == nil) return;
    UIViewController *top = [win rootViewController];
    if (top == nil) return;
    int hops = 0;
    while ([top presentedViewController] != nil && hops < 6) {
        top = [top presentedViewController];
        hops += 1;
    }
    if (hops == 0) {
        // 没有浮层：这一张结束了，下一张从头开始数。
        AevonLiftSheet = NULL;
        AevonLiftCount = 0;
        AevonLiftSeen = 0.0;
        AevonLiftSight = 0.0;
        return;
    }
    UIView *sheet = [top view];
    if (sheet == nil) return;
    BOOL fresh = (AevonLiftSheet != (void *)sheet);
    if (fresh) {
        AevonLiftSheet = (void *)sheet;
        AevonLiftCount = 0;
        AevonLiftSeen = 0.0;
        AevonLiftSight = [NSProcessInfo processInfo].systemUptime;
        // 抬之前先把原始位置量下来：0.0.82 那一行 `sheet cut` 是这一整套的唯一
        // 证据，抬得越快它越容易被跳过，所以在「第一次看见」这一拍就记一次。
        AevonSheetReport();
    }
    if (AevonLiftCount >= 4) return;
    CGRect r = [sheet convertRect:[sheet bounds] toView:win];
    CGFloat winH = [win bounds].size.height;
    if (winH < 200.0 || r.size.height < 200.0) return;
    // 只认「本来就比窗口高」的面板。半高的活动面板底边本来就在窗口里，抬它是
    // 替 App 排版，不是补差。
    if (r.size.height < winH + 8.0) return;
    CGFloat over = CGRectGetMaxY(r) - winH;
    // 超过 320 pt 说明这不是「差一截」（真机读数是 215）。
    if (fabs(over) > 320.0) return;
    // 第一次只往上抬（下面被切掉了）；已经抬过的才允许按残差回落 —— 那是
    // 「我们或 App 自己抬过了头」，同样要收敛，否则面板顶部会被切掉。
    if (AevonLiftCount == 0 && over < 8.0) {
        AevonLiftSeen = over;
        return;
    }
    if (!fresh && fabs(over - AevonLiftSeen) < 2.0) {
        if (fabs(over) < 8.0) {           // 已经对齐了，收手
            AevonLiftSeen = over;
            return;
        }
        CGPoint center = [sheet center];
        [sheet setCenter:CGPointMake(center.x, center.y - over)];
        AevonLiftCount += 1;
        AevonLiftSeen = over;
        double spent = [NSProcessInfo processInfo].systemUptime - AevonLiftSight;
        char body[180];
        snprintf(body, sizeof(body), "sheet lift by=%.0f h=%.0f box=%.0f n=%d in=%.2fs",
                 over, r.size.height, winH, AevonLiftCount, spent);
        AevonPageWrite(body);
        return;
    }
    AevonLiftSeen = over;
    if (fresh && !AevonLiftSoon) AevonSheetLiftAgain();
}

/// 0.0.84 — 抬得再早一点：不等心跳，从「要呈现了」这一声开始看。
///
/// 0.0.83 把节拍从 1 s 压到 0.06~0.2 s，靠的是心跳（0.15 s 一拍）。但心跳的相位
/// 是随机的：面板可能在第 0.14 s 才被第一拍撞见，那一次抬就落在动画的后半段，
/// 看上去仍然是「先出来、再抬一下」。把「呈现」自己接过来，就能从 t=0 起看 ——
/// 面板的入场动画大约 0.35 s，下面这四拍全在它里面，所以抬的动作发生在用户看见
/// 完整面板之前。心跳那一份继续留着当兜底（这一声没接住时它仍然会补齐）。
static void (*AevonOriginalPresent)(UIViewController *, SEL, UIViewController *, BOOL,
                                    void (^)(void));
static int AevonBurstLeft = 0;

static void AevonSheetBurstTick(void *context) {
    (void)context;
    if (AevonBurstLeft > 0) AevonBurstLeft -= 1;
    AevonSheetLift();
}

static void AevonSheetBurst(void) {
    if (AevonBurstLeft > 0) return;          // 一轮没跑完就不再排第二轮
    AevonBurstLeft = 4;
    static const double steps[4] = {0.0, 0.016, 0.033, 0.055};
    for (int i = 0; i < 4; i++) {
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(steps[i] * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, AevonSheetBurstTick);
    }
}

static void AevonPresentHook(UIViewController *self, SEL _cmd, UIViewController *vc,
                             BOOL animated, void (^completion)(void)) {
    if (AevonOriginalPresent != NULL) {
        AevonOriginalPresent(self, _cmd, vc, animated, completion);
    }
    if (vc == nil) return;
    if (!AevonAppHookAllowed()) return;
    AevonSheetBurst();
}

/// 把 offset 挪到最近的整页上。
///
/// 0.0.73 的写法是 `round(y / 旧页高) × 新页高`：先用「变化前的窗口高」取整，
/// 再乘上新高度。算式本身没毛病（932→717 时 `3 × 932 = 2796` 变成 `3 × 717 =
/// 2151`，停在同一帖），但它有两个前提：**App 真的按新高度重排过**，而且**我们
/// 那一次写入没有被它自己覆盖**。Aevon(64) 里两个前提至少破了一个。
///
/// 0.0.74 把判据换成从内容自己身上读，不再依赖记忆：
///
///   ① **页高只取「内容真的按这个高度切」的那个数**。`span` 是 `box` 的整数倍
///      （±24）时，一页就是 `box` —— 这时候 `round(y / box) × box` 是唯一正确的
///      答案，任何「旧页高」的参与都会把它推歪（932/717 = 1.3，取整就跳到下一
///      页）。`span` 不是整数倍时，才退回去用旧页高/单元格，那是「App 还没
///      重排完」的中间态。
///
///   ② **窗口不再被一次「已对齐」清掉**。0.0.73 一见 `y` 落在整页上就
///      `AevonSettleTicks = 0`，把后面所有机会一起注销 —— 而 App 的覆盖恰恰
///      发生在那之后的一两百毫秒里。现在窗口只按时拍递减，每拍都复看一次：
///      对齐就什么都不做，被挪走了就再挪回来。这就是「有时会自己恢复、有时
///      不会」变成「一定会」的那一条。
///
/// 返回 1 改了一个，0 已经在整页上，-1 没有可改的对象（或还没到时候）。
static NSInteger AevonAlignPager(const char *reason) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil) return -1;
    if ([view window] == nil) return -1;
    // 手指还在动就别动它。归位是「补一刀」，不是「抢方向盘」。
    if ([view isTracking] || [view isDragging] || [view isDecelerating]) return -1;
    // 0.0.81 — 交还整屏的那一段：App 还是后台（我们刚把它推下去，或者用户还没
    // 回到它），这一拍**一行都不写**。见 `AevonRemeasurePending` 的注释 ——
    // 0.0.78 起那次「整表重排」正好压在挂起前的一拍上，Aevon(72) 六次开合六次
    // 卡屏。回到前台的第一拍把这件事记完就接着走，中间不多一次机会也不多一次
    // 重排。
    if (AevonRemeasurePending) {
        if (!AevonAppIsActive()) {
            AevonRemeasureWaits += 1;
            // 50 拍 ≈ 7.5 s 的运行时间（挂起期间不数）。正常情形用户一秒内就
            // 回来了；到 50 还不回来只有一种解释：这个 App 的 `applicationState`
            // 在回到前台之后仍然是 background（Aevon(72) 17:07:26 那行 `promoted`
            // 就是这个形状）。那时候再等下去就是永不动手，这一版的修复会变成
            // 一条新的「关窗后断层」—— 宁可写一行说清楚，然后照常做。
            if (AevonRemeasureWaits < 50) {
                if (AevonRemeasureLogs < 3) {
                    AevonRemeasureLogs += 1;
                    char body[220];
                    snprintf(body, sizeof(body),
                             "hold reason=%s wait active n=%d box=%.0f target=%.0f",
                             reason, AevonRemeasureWaits,
                             [view bounds].size.height, AevonRemeasureTarget);
                    AevonPageWrite(body);
                }
                return -1;
            }
            AevonRemeasurePending = 0;
            AevonPageWrite("resume stale app stays background, acting anyway");
        } else {
            AevonRemeasurePending = 0;
            char body[220];
            snprintf(body, sizeof(body), "resume active box=%.0f target=%.0f after=%.1fs",
                     [view bounds].size.height, AevonRemeasureTarget,
                     AevonRemeasureAt > 0.0
                         ? CFAbsoluteTimeGetCurrent() - AevonRemeasureAt : 0.0);
            AevonPageWrite(body);
        }
    }
    CGFloat box = [view bounds].size.height;
    CGFloat full = AevonWindowHeight();
    // App 还没跟上这一次尺寸变化：先把机会留着，下一拍再说。
    // 0.0.78 — 差得远（> 40 pt）且内容比窗口高，是另一族：翻页器按整屏排着不肯
    // 缩回来。这条分支记一行读数、把它的所有者置脏，然后照旧返回 —— 它没有可以
    // 「算」的落点，能做的只是请它自己改。
    if (full > 200.0 && fabs(box - full) > 8.0) {
        if (box > full + 40.0) AevonStuckReport(reason, box, full);
        return -1;
    }
    CGSize span = [view contentSize];
    CGFloat y = [view contentOffset].y;
    if (box < 200.0 || span.height < box * 1.2) return -1;
    // 视口还是旧尺寸：这一次尺寸变化还没走到翻页器身上。**等它**，别拿旧几何
    // 算出一个「已经对齐」然后把这拍机会烧掉 —— 0.0.74 的 `off=0,2151 / box=717`
    // 就是这个形状，一烧就是 90 拍（13.5 s），而 App 往往几秒之后才重排。
    if (AevonOldPage > 200.0 && fabs(box - AevonOldPage) < 8.0) return -1;

    // ⓪ 请 App 把页重排一遍（只置脏、不逼它排版）。
    //
    // 0.0.76 在这里**一请就收工**，视口留在两页之间等 App 慢慢排 —— Aevon(67) 里
    // `16:02:44~46` 那一串 `state … clean=1 stale=2 off=0,10038` 就是这段等待的样子：
    // 页在 4 s 之后确实排好了，可这 4 s 用户看到的正是断层。
    // 0.0.77 把两件事拆开同时做：「请它重排」管**页高**，「摆到那一页开头」管**落点**。
    int cleanPages = 0;
    int stalePages = 0;
    int boxedNow = 0;
    AevonPagerStats(view, box, &cleanPages, &stalePages, &boxedNow);
    if (stalePages > 0 || !boxedNow) AevonPagerRebuild(reason);
    // 0.0.78 — `beginUpdates/endUpdates` 会当场重排，内容高度与 offset 都可能已经
    // 变了。下面每一条判据都要用**重排之后**的数，所以在这里重新读一遍：拿重排前
    // 的 `y` 去比 `gap`，会把「刚被它挪走的视口」当成「已经压在页首」，于是行高变
    // 了、落点没跟，白等一个 90 拍的窗口。
    span = [view contentSize];
    y = [view contentOffset].y;

    // ① 落点只有一个来源：**那一页自己的原点**。
    //
    // 两个来源按优先级取：钉住的行下标（尺寸变化那一拍记下的那一帖，最准）、
    // 压住视口顶的那一页（用户自己滑到别处时用）。**没有任何算术**：
    // `round(y/box)*box` 与 `N × 新页高` 都写在「0 是格点原点」这个假设上，而
    // Aevon(67) 的四组读数证明那个假设不成立（见文件头 `AevonAnchorSection`）。
    CGRect row = CGRectZero;
    int anchored = 0;
    if (AevonAnchorSet
        && AevonIndexPathRect(view, AevonAnchorSection, AevonAnchorRow, &row)) {
        anchored = 1;
    } else {
        UIView *kid = AevonPageKidAt(view, box, y);
        if (kid == nil) return -1;
        row = [kid frame];
    }
    if (row.size.height < 120.0) return -1;
    BOOL cleanRow = fabs(row.size.height - box) <= 2.0;
    CGFloat cap = span.height - box;
    if (cap < 0.0) cap = 0.0;
    CGFloat target = row.origin.y;
    if (target < 0.0) target = 0.0;
    if (target > cap) target = cap;
    CGFloat gap = fabs(y - target);

    // 已经压在这一页的开头：这一拍什么都不写。
    if (gap <= 1.5) {
        // 只有当「页高也等于视口」时才算收工 —— 否则页高还在往新高度上赶，
        // 下几拍它的原点和高度都还会动，得继续跟着。
        if (cleanRow) {
            AevonOldPage = 0.0;
            if (anchored) {
                AevonAnchorSet = 0;
                char body[200];
                snprintf(body, sizeof(body),
                         "anchor done row=%ld,%ld at=%.0f h=%.0f box=%.0f",
                         (long)AevonAnchorSection, (long)AevonAnchorRow, target,
                         row.size.height, box);
                AevonPageWrite(body);
            }
        }
        return 0;
    }
    // 没有钉住行下标时才用「三屏」这道门：那是用户自己滑到了别处，追太远就是
    // 抢方向盘。钉住了就没有这道门 —— 上方每重排一行，这一页的起点就上移 215，
    // 几十行就是十几屏，而它仍然是同一帖。
    if (!anchored && gap > box * 3.0) return -1;
    // 40 次 ≈ 6 s 的节拍：够跟着重排收尾走完。再多就说明 App 在坚持把 offset
    // 拉回去，继续写只是两边互相推。
    if (AevonAnchorWrites >= 40) {
        if (AevonAnchorLost == 0) {
            AevonAnchorLost = 1;
            char body[160];
            snprintf(body, sizeof(body), "align capped moves=%d at=%.0f gap=%.0f",
                     AevonAnchorWrites, y, gap);
            AevonPageWrite(body);
        }
        return -1;
    }
    [view setContentOffset:CGPointMake([view contentOffset].x, target) animated:NO];
    AevonAnchorWrites += 1;
    AevonLastPageHeight = cleanRow ? box : AevonLastPageHeight;
    // 被挪走过一次，就再给一轮机会：App 很可能在重排完成的当口又挪一次。
    if (AevonSettleTicks < 30) AevonSettleTicks = 30;
    char body[320];
    snprintf(body, sizeof(body),
             "align %s y=%.0f -> %.0f row=%.0f h=%.0f box=%.0f anchor=%d "
             "clean=%d span=%.0f moves=%d",
             reason, y, target, row.origin.y, row.size.height, box, anchored,
             cleanPages, span.height, AevonAnchorWrites);
    AevonPageWrite(body);
    return 1;
}

/// 找出「整屏一页」的翻页器并记住它。只在还没认出来的时候跑（一次遍历，
/// 上限 4000 个视图）——认出来之后所有后续判断都只读一个属性。
static BOOL AevonPagerAcquire(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return NO;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)one windows]) {
            CGFloat H = [win bounds].size.height;
            if (H < 200.0) continue;
            NSMutableArray *todo = [NSMutableArray arrayWithObject:win];
            NSUInteger walked = 0;
            while (todo.count > 0 && walked < 4000) {
                UIView *node = [todo lastObject];
                [todo removeLastObject];
                walked += 1;
                if ([node isKindOfClass:[UIScrollView class]]) {
                    UIScrollView *view = (UIScrollView *)node;
                    CGSize box = [view bounds].size;
                    CGSize span = [view contentSize];
                    // 0.0.72 — 视口与窗口的容差 12 → 40。窗口刚变的那一拍，
                    // 滚动视图可能还差着十几 pt 没跟上，而它就是我们记着的
                    // 那一个；40 pt 只放行「同一块屏」，放不进别的列表。
                    if (fabs(box.height - H) <= 40.0 && span.height >= box.height * 1.6) {
                        CGFloat pages = round(span.height / box.height);
                        // 整数倍那条从 8 pt 放宽到 24 pt，理由同上：中间态。
                        BOOL exact = (pages >= 2.0
                                      && fabs(span.height - pages * box.height) <= 24.0);
                        if (exact || [view isPagingEnabled]) {
                            AevonPagerKeep(view);
                            AevonLastPageHeight = AevonPageHeightOf(view, box.height);
                            char body[400];
                            // 单元格连同原点一起记：`cell=0,0,430x717` 与
                            // `cell=0,110,430x717` 是两件完全不同的事 —— 后者说明
                            // 页面整体被往下挪了 110 pt（Aevon(62) 的抖音），
                            // 而这正是「顶栏底栏不对」唯一缺的那个数。
                            CGRect cell = AevonCellFrameOf(view, box.height);
                            snprintf(body, sizeof(body),
                                     "pager keep box=%.0f span=%.0fx%.0f "
                                     "cell=%.0f,%.0f,%.0fx%.0f off=%.0f "
                                     "inset=%.0f paging=%d pages=%.0f",
                                     box.height, span.width, span.height,
                                     cell.origin.x, cell.origin.y,
                                     cell.size.width, cell.size.height,
                                     [view contentOffset].y, [view contentInset].top,
                                     [view isPagingEnabled] ? 1 : 0, pages);
                            AevonPageWrite(body);
                            return YES;
                        }
                    }
                }
                NSArray *kids = [node subviews];
                if (kids.count > 0) [todo addObjectsFromArray:kids];
            }
        }
    }
    return NO;
}

/// 播放器那一层：`bounds` 尺寸 + 填充方式 + 片源尺寸。
///
/// 它回答的是另一个可能：「视频贴顶」也可能是播放器只占了一条，剩下的是背景。
/// `b=430x717 grav=resizeAspectFill src=1080x1920` 说明画面本来就铺满整页，剩下的
/// 只能是翻页位置；`b=430x242` 则是播放器自己的尺寸不对，两件事的修法完全不同。
///
/// 抖音用的不是 AVPlayerLayer（`player none` 已经连读三次），所以这一行对它是空的；
/// 留着是给微信、小红书这一类真的用 `videoGravity` 的 App。
static void AevonDumpPlayers(const char *reason) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return;
    SEL gravitySel = NSSelectorFromString(@"videoGravity");
    NSInteger players = 0;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)one windows]) {
            CALayer *root = [win layer];
            if (root == nil) continue;
            NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
            NSUInteger guard = 0;
            while (todo.count > 0 && guard < 20000 && players < 2) {
                CALayer *layer = [todo lastObject];
                [todo removeLastObject];
                guard += 1;
                if ([layer respondsToSelector:gravitySel]) {
                    CGSize box = [layer bounds].size;
                    NSString *gravity = nil;
                    @try {
                        gravity = [layer valueForKey:@"videoGravity"];
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                    CGSize src = CGSizeZero;
                    @try {
                        id player = [layer valueForKey:@"player"];
                        id item = [player valueForKey:@"currentItem"];
                        id size = [item valueForKey:@"presentationSize"];
                        if ([size isKindOfClass:[NSValue class]]) {
                            [size getValue:&src size:sizeof(src)];
                        }
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                    players += 1;
                    char body[220];
                    snprintf(body, sizeof(body), "%s player b=%.0fx%.0f grav=%s src=%.0fx%.0f",
                             reason, box.width, box.height,
                             [gravity isKindOfClass:[NSString class]]
                                 ? [gravity UTF8String] : "?",
                             src.width, src.height);
                    AevonPageWrite(body);
                }
                NSArray *kids = [layer sublayers];
                if (kids.count > 0) [todo addObjectsFromArray:kids];
            }
        }
    }
    if (players == 0) {
        char body[120];
        snprintf(body, sizeof(body), "%s player none", reason);
        AevonPageWrite(body);
    }
}

/// 0.0.76 — 「卡片里那个视频为什么贴到顶栏上」。
///
/// 这是第二件事，和断层不是同一个量。断层的读数是**页与页之间**的位置，而这一件
/// 发生在**页里面**：`state` 行已经证明卡片里的十一页全是 717（`span=7887 =
/// 11 × 717`，`k1=AWEFeedViewCell:0,717x430`）—— 页是对的，那么「视频上移」只可能
/// 是这一页的内容自己排错了高度，或者被一个变换压过。
///
/// 所以这一行把页**拆开**量：单元格自己的 frame 与 bounds 是否是同一个数（不是就
/// 说明它带着 transform）、它里面面积最大的那个子视图多大、以及整棵树里第一个
/// 类名带 Player / Video 的视图在页坐标系里的位置。
///
/// 判读很直接：
///   · `c0=717 inner=...430x932`  ⇒ 页是 717，内容还是按 932 排的 —— 复用没重排；
///   · `t=0.77,...`               ⇒ 页被缩放过，坐标全被这个比例改写过；
///   · `vid=...:0,0,430x717`      ⇒ 播放器铺满整页，视频本身没问题，问题在页位置。
///
/// 只量前两页（可见的那两页就是用户看到的全部），一次进程最多 8 行。
static int AevonInsideLines = 0;
static CFAbsoluteTime AevonInsideAt = 0.0;

static NSString *AevonFindPlayer(UIView *root, CGRect *out) {
    NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
    NSUInteger walked = 0;
    while (todo.count > 0 && walked < 400) {
        UIView *node = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        const char *name = class_getName([node class]);
        if (name != NULL && (strstr(name, "Player") != NULL || strstr(name, "Video") != NULL)) {
            *out = [node convertRect:[node bounds] toView:root];
            return [NSString stringWithUTF8String:name];
        }
        NSArray *kids = [node subviews];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }
    return nil;
}

static void AevonPagerInside(const char *reason) {
    if (AevonInsideLines >= 8) return;
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonInsideAt > 0.0 && now - AevonInsideAt < 3.0) return;
    CGRect box = [view bounds];
    if (box.size.height < 200.0) return;
    NSArray *kids = [view subviews];
    NSMutableString *body = [NSMutableString string];
    int done = 0;
    for (NSUInteger i = 0; i < kids.count && done < 2; i++) {
        UIView *cell = [kids objectAtIndex:i];
        CGRect f = [cell frame];
        if (f.size.height < box.size.height * 0.5) continue;
        // 面积最大的那一层子视图：抖音的播放器/封面就在这一层里。
        UIView *big = nil;
        CGFloat area = -1.0;
        for (UIView *kid in [cell subviews]) {
            CGRect kf = [kid frame];
            CGFloat a = kf.size.width * kf.size.height;
            if (a > area) { area = a; big = kid; }
        }
        CGRect vid = CGRectZero;
        NSString *vidName = AevonFindPlayer(cell, &vid);
        CGAffineTransform t = [cell transform];
        [body appendFormat:@"%sc%lu=%.0f b=%.0fx%.0f t=%.2f,%.0f,%.0f inner=%s:%.0f,%.0f,%.0fx%.0f",
         done > 0 ? " " : "", (unsigned long)i, f.size.height,
         [cell bounds].size.width, [cell bounds].size.height, t.a, t.tx, t.ty,
         big != nil ? class_getName([big class]) : "nil",
         big != nil ? [big frame].origin.x : 0.0,
         big != nil ? [big frame].origin.y : 0.0,
         big != nil ? [big bounds].size.width : 0.0,
         big != nil ? [big bounds].size.height : 0.0];
        if (done == 0) {
            [body appendFormat:@" vid=%s:%.0f,%.0f,%.0fx%.0f",
             vidName != nil ? [vidName UTF8String] : "none",
             vid.origin.x, vid.origin.y, vid.size.width, vid.size.height];
        }
        done += 1;
    }
    if (done == 0) return;
    AevonInsideAt = now;
    AevonInsideLines += 1;
    char line[560];
    snprintf(line, sizeof(line), "inside %s box=%.0f %s",
             reason, box.size.height, [body UTF8String]);
    AevonPageWrite(line);
}

static void AevonPagerReport(const char *reason) {
    if (!AevonAppHookAllowed()) return;
    if (AevonPagerGet() == nil || [AevonPagerGet() window] == nil) AevonPagerAcquire();
    AevonAlignPager(reason);
    AevonDumpPlayers(reason);
    AevonPagerInside(reason);
}

/// 0.0.85 — 「只有部分视频贴在卡片顶边」：换**选节点的判据**。
///
/// 0.0.84 的思路没错（画面那块矩形被钉在容器顶上，把它挪到正中），但选错了节点，
/// Aevon(75) 一行读数就把它照出来了：
///
///     app: page video band none cls=AWEAwemePlayVideoPauseIc h=717 box=717
///
/// 全页大（717）的「暂停图标层」面积最大，被当成了播放器；真正的视频区
/// `DDanmakuPlayerView:0,0,430x634`（`inside settle` 那一行一直在报）从头到尾
/// 没被看过一眼。所以「找不到那块矩形」是判据造成的必然结果，和画面怎么排无关 ——
/// 这也是为什么这一版之前，日志里一条成功的 `video band v=` 都**没有**过。
///
/// 三个新判据：
///   · 候选要排除「画面身上的零件」：类名里带 Pause / Icon / Button / Progress /
///     Mask / Overlay / Cover 之类的一律不是画面（`AevonNotPicture`）；
///   · 候选按面积从大到小**逐个**试，不是只看最大的那一个；
///   · 找那块矩形要**递归**往深处走（画面外面常套一层容器），宽度按候选自己的
///     宽度算 —— 只看直接子视图会漏掉整整一代。
///
/// 居中的口径也改了：不是「在直接父视图里居中」，而是在**视频区**（候选自己）里
/// 居中。Aevon(75) 的数是视频区 430×634、16:9 画面 430×242，两个数一减 `dy=196`
/// —— 这就是「上下黑边一样宽」。区域比整页还高时（整页播放器那一族）退回上一层
/// 容器，否则会把画面推到标签栏底下。
///
/// 守卫不变：铺满的竖版不碰、带缩放/旋转的不碰、残差小于 12 pt 不动、一块画面
/// 最多挪 3 次、平移只用 `transform`（App 重排会重写 `center`/`frame`，一般不碰
/// transform）。
static void *AevonVideoNode = NULL;
static int AevonVideoHits = 0;
static int AevonVideoNotes = 0;

/// 类名里带这些字样的是画面身上的零件，不是画面。
static BOOL AevonNotPicture(const char *name) {
    if (name == NULL) return YES;
    static const char *bad[] = {"Pause", "Icon", "Button", "Control", "Progress",
                                "Slider", "Tip", "Badge", "Mask", "Overlay",
                                "Cover", "Label", "Hud", "Guide", "Panel", "Toast"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        if (strstr(name, bad[i]) != NULL) return YES;
    }
    return NO;
}

/// 页里所有「类名带 Player / Video」的视图，按面积从大到小。
/// 不用 `sortUsingComparator:`：这个 dylib 装进每一个 App 进程，能少一条运行库
/// 依赖就少一条；候选只有个位数，双重循环反而更省。
static void AevonCollectPlayers(UIView *root, NSMutableArray *out) {
    if (root == nil || out == nil) return;
    NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
    NSUInteger walked = 0;
    while (todo.count > 0 && walked < 1600) {
        UIView *node = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        const char *name = class_getName([node class]);
        if (name != NULL
            && (strstr(name, "Player") != NULL || strstr(name, "Video") != NULL)) {
            CGRect b = [node bounds];
            if (b.size.width >= 120.0 && b.size.height >= 120.0) [out addObject:node];
        }
        NSArray *kids = [node subviews];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }
    NSUInteger total = out.count;
    for (NSUInteger i = 0; i < total; i++) {
        for (NSUInteger j = i + 1; j < total; j++) {
            UIView *a = [out objectAtIndex:i];
            UIView *b = [out objectAtIndex:j];
            CGFloat aa = [a bounds].size.width * [a bounds].size.height;
            CGFloat bb = [b bounds].size.width * [b bounds].size.height;
            if (bb > aa) [out exchangeObjectAtIndex:i withObjectAtIndex:j];
        }
    }
}

/// 视频区里那块「宽度接近视频区、高度矮一截」的矩形。横版画面就是它。
/// 贴顶的优先（用户说的「上移」就是它），没有贴顶的才按面积取。
static UIView *AevonBandUnder(UIView *region) {
    if (region == nil) return nil;
    CGFloat w = [region bounds].size.width;
    CGFloat h = [region bounds].size.height;
    if (w < 120.0 || h < 200.0) return nil;
    NSMutableArray *todo = [NSMutableArray arrayWithObject:region];
    NSUInteger walked = 0;
    UIView *top = nil;
    CGFloat topArea = -1.0;
    UIView *any = nil;
    CGFloat anyArea = -1.0;
    while (todo.count > 0 && walked < 1200) {
        UIView *node = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        if (node != region) {
            CGRect b = [node bounds];
            if (b.size.width >= w * 0.9 && b.size.height >= 100.0
                && b.size.height <= h - 40.0) {
                CGFloat area = b.size.width * b.size.height;
                if ([node frame].origin.y <= 8.0 && area > topArea) {
                    topArea = area;
                    top = node;
                }
                if (area > anyArea) { anyArea = area; any = node; }
            }
        }
        NSArray *kids = [node subviews];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }
    return top != nil ? top : any;
}

/// 什么都找不到时的那一行：候选有几个、各自多大，以及第一个候选肚子里直接躺着
/// 的那几个子视图。下一轮要换判据，靠的就是这一行 —— 0.0.84 缺的正是它
/// （只写了一个被误选成播放器的「暂停图标层」）。
static void AevonVideoTree(UIView *root) {
    if (root == nil) return;
    NSMutableString *list = [NSMutableString string];
    NSArray *kids = [root subviews];
    NSUInteger limit = kids.count < 8 ? kids.count : 8;
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *kid = [kids objectAtIndex:i];
        CGRect f = [kid convertRect:[kid bounds] toView:root];
        [list appendFormat:@"|%.18s:%.0f,%.0f,%.0fx%.0f",
         class_getName([kid class]), f.origin.x, f.origin.y, f.size.width, f.size.height];
    }
    char body[560];
    snprintf(body, sizeof(body), "video tree b=%.0fx%.0f n=%lu%s",
             [root bounds].size.width, [root bounds].size.height,
             (unsigned long)kids.count, [list UTF8String]);
    AevonPageWrite(body);
}

static void AevonVideoCenter(void) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    CGRect page = [view bounds];
    if (page.size.height < 200.0) return;
    UIView *cell = AevonPageKidAt(view, page.size.height, [view contentOffset].y);
    if (cell == nil) return;

    NSMutableArray *players = [NSMutableArray array];
    AevonCollectPlayers(cell, players);
    if (players.count == 0) return;

    UIView *band = nil;
    UIView *region = nil;
    UIView *firstTry = nil;
    // 两轮：先只试「不是零件」的候选；全都不行再把零件也算进来（个别 App 的播放器
    // 名字里就带 Button/Icon，宁可多试一轮也不漏）。
    for (int pass = 0; pass < 2 && band == nil; pass++) {
        for (UIView *candidate in players) {
            const char *name = class_getName([candidate class]);
            if (pass == 0 && AevonNotPicture(name)) continue;
            if (firstTry == nil) firstTry = candidate;
            UIView *found = AevonBandUnder(candidate);
            if (found != nil) { band = found; region = candidate; break; }
        }
    }
    if (band == nil || region == nil) {
        if (AevonVideoNotes < 6 && firstTry != nil) {
            AevonVideoNotes += 1;
            char body[170];
            snprintf(body, sizeof(body), "video band none cls=%.24s h=%.0f box=%.0f",
                     class_getName([firstTry class]),
                     [firstTry bounds].size.height,
                     [firstTry superview] != nil ? [[firstTry superview] bounds].size.height : 0.0);
            AevonPageWrite(body);
            AevonVideoTree(firstTry);
        }
        return;
    }
    if (AevonVideoNode != (void *)band) {
        AevonVideoNode = (void *)band;
        AevonVideoHits = 0;
    }
    CGAffineTransform t = [band transform];
    // 缩放 / 旋转 / 横向位移都不是我们写的：那是 App 自己的动画，别抢。
    if (fabs(t.a - 1.0) > 0.01 || fabs(t.d - 1.0) > 0.01 || fabs(t.tx) > 0.5) return;
    // `convertRect:` 出来的是**含我们加过的那一段位移**的矩形，所以不用像 0.0.84
    // 那样再减 `t.ty` —— 减一次会把上一刀的位移又算进去。
    CGRect rb = [band convertRect:[band bounds] toView:region];
    CGFloat regionH = [region bounds].size.height;
    CGFloat cellH = [cell bounds].size.height;
    // 视频区比整页还高（整页播放器那一族）：退回上一层「比整页矮」的容器，否则
    // 算出来的正中会落到标签栏底下。
    if (regionH > cellH - 40.0) {
        UIView *up = [band superview];
        while (up != nil && [up bounds].size.height > cellH - 40.0) up = [up superview];
        if (up != nil && [up bounds].size.height >= rb.size.height + 40.0) {
            region = up;
            regionH = [region bounds].size.height;
            rb = [band convertRect:[band bounds] toView:region];
        }
    }
    if (regionH < rb.size.height + 40.0) return;
    CGFloat want = (regionH - rb.size.height) / 2.0;
    CGFloat gap = want - rb.origin.y;
    if (fabs(gap) < 12.0) return;
    if (AevonVideoHits >= 3) return;
    AevonVideoHits += 1;
    [band setTransform:CGAffineTransformMakeTranslation(0, t.ty + gap)];
    char body[240];
    snprintf(body, sizeof(body), "video band v=%.24s h=%.0f box=%.0f dy=%.0f n=%d r=%.24s",
             class_getName([band class]), rb.size.height, regionH, gap, AevonVideoHits,
             class_getName([region class]));
    AevonPageWrite(body);
}

/// 0.0.74 — 状态读数的一次性节拍。0.4 / 1.5 / 2.6 s 各一次：App 的重排、内容
/// 重载、翻页器重新吸附各在不同的一拍上，只记一张必然撞在中间态上。
static char AevonStateLate[] = "after change";
static int AevonStateLines = 0;

static void AevonStateTick(void *context) {
    (void)context;
    if (!AevonEverHosted) return;
    if (AevonStateLines >= 260) return;
    AevonStateLines += 1;
    AevonPageState((const char *)context);
}

static char AevonPagerEarly[] = "on resize";
static char AevonPagerLate[] = "on resize late";

static void AevonPagerTick(void *context) {
    const char *reason = (const char *)context;
    if (!AevonEverHosted) return;
    if (AevonPagerGet() == nil || [AevonPagerGet() window] == nil) {
        if (AevonPagerGet() != nil) AevonAcquireTries = 0;
        AevonPagerAcquire();
    }
    AevonAlignPager(reason);
    // 只有最后一拍才量播放器：它比找滚动视图贵得多（要下到图层树），而两次之间
    // 只要有一份读数就够。
    if (context == (void *)AevonPagerLate) AevonDumpPlayers(reason);
}

static IMP AevonOriginalViewTransition = NULL;

/// `-[UIViewController viewWillTransitionToSize:withTransitionCoordinator:]`
///
/// 这是 App 自己知道「窗口尺寸变了」的唯一标准时机：卡片把 scene 从 932 推到 717
/// （或还回去）时，根视图控制器一定会收到它。
///
/// 0.0.72 — 三处改动，都是 Aevon(62) 逼出来的：
///
///   ① 8 pt 的门拆成两条：**归位**仍然要跨过 8 pt（1 pt 的抖动不是换页），但
///      **日志**不再被它挡住。0.0.71 的 1 pt 轻推到底有没有被 App 看见，日志里
///      一条 `transition` 都没有 —— 分不清「没送到」和「送到了但被自己滤掉了」。
///   ② 每一拍都重设 `AevonLastPageHeight = before`，并且把守卫的停稳计数清零，
///      让它在这一拍之后 0.6 s 就能复核。
///   ③ 一次尺寸变化排 6 拍（0.05 → 1.35 s）。窗口尺寸不是原子事件：cell 重排、
///      内容重载、翻页器重新吸附各在不同的一拍上发生，只试一次必然撞在中间态上
///      —— 0.0.71 的 `pager=0` 就是这么来的。
static void AevonViewTransition(id self, SEL _cmd, CGSize size, id coordinator) {
    UIViewController *vc = (UIViewController *)self;
    // 旧高度必须在**调用原实现之前**取：这一拍 view 还是旧的尺寸，而它正是
    // 翻页器记「第 N 页」时用的那个数。
    CGFloat before = 0.0;
    if ([vc isViewLoaded]) {
        UIView *view = [vc view];
        UIWindow *win = [view window];
        // 只认根视图控制器：子控制器也会收到这个回调，用它们的高度算页高会把
        // 一次尺寸变化算成好几种比例。
        if (win != nil && [win rootViewController] == vc) {
            before = [view bounds].size.height;
        }
    }
    if (AevonOriginalViewTransition != NULL) {
        ((void (*)(id, SEL, CGSize, id))AevonOriginalViewTransition)(self, _cmd, size, coordinator);
    }
    if (before < 200.0) return;
    if (fabs(before - size.height) < 0.5) return;
    if (!AevonAppHookAllowed()) return;
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat full = screen != nil ? [screen bounds].size.height : 0.0;
    // 「被缩小」这件事本身就是证据，不必等前面先量过一次 —— 第一次开卡时没人
    // 告诉过我们这是不是卡，但 `new < 屏幕 - 40` 已经说明了。
    if (full > 200.0 && size.height < full - 40.0) {
        AevonEverHosted = 1;
        // 每开一面卡就续一次命：心跳是「进程内只装一次」的，而 2400 拍只够
        // 6 分钟；不重置的话，用得久一点，守卫就自己先停了。
        AevonWatchTicks = 0;
    }
    if (!AevonEverHosted) return;
    // 0.0.73 — 只有「真的换了屏」才算尺寸变化。开卡 / 关卡是 932↔717（215 pt），
    // 而 `scene nudge` 是 17 pt、宿主那一手是 1 pt：后者是催 App 重排用的抖动，
    // 拿它当页高基准会把 offset 换成 734 再换回来，白折腾一圈还可能攒出取整误差。
    BOOL real = fabs(before - size.height) >= 40.0;
    AevonLastPageHeight = before;
    if (real) {
        AevonOldPage = before;
        AevonSettleTicks = 90;
        AevonSettleAge = 0;
        AevonWatchTicks = 0;
        // 0.0.77 — 「用户在看哪一帖」不在这里记，也不在这拍写 offset。
        // 行下标要在翻页器还活着的时候取（见下面 `AevonAnchorRemember`），
        // 而 offset 要等 App 把那一页摆到新位置上才知道该是多少。
        // 每一次真的换屏都重新给配额：一张卡开一次、关一次，各两次重排足够。
        AevonRebuilds = 0;
        AevonRebuildAt = 0.0;
        AevonRebuildSame = 0;
        AevonRebuildDead = 0;
        AevonRebuildTop = 0.0;
        AevonAnchorLost = 0;
        AevonStuckLines = 0;
        AevonStuckAt = 0.0;
        // 0.0.81 — 往大走 = 交还整屏：这一路的重排要等 App 真的回到前台再做
        // （见 `AevonRemeasurePending`）。往小走 = 开卡：App 就在用户眼前，
        // 照旧立刻做，那一路是 0.0.78 修好的「第一次打开内容尺寸不对」。
        if (size.height > before + 40.0) {
            AevonRemeasurePending = 1;
            AevonRemeasureTarget = size.height;
            AevonRemeasureAt = CFAbsoluteTimeGetCurrent();
            AevonRemeasureLogs = 0;
            AevonRemeasureWaits = 0;
        } else {
            AevonRemeasurePending = 0;
            AevonRemeasureTarget = 0.0;
        }
        // 心跳撞过 2400 拍上限就自己停了，这里把它叫回来 —— 关卡之后要归位的那
        // 一半，全靠这个心跳。
        AevonPagerWatchArm();
    }
    AevonGuardY = -1.0;
    AevonGuardHold = 0;
    AevonAcquireTries = 0;
    // 40 行足够覆盖十几次开卡/关卡；再多就是有人在按着屏幕拉窗口，那不是这一段
    // 要回答的问题。
    if (AevonTransLogs < 40) {
        AevonTransLogs += 1;
        char body[180];
        snprintf(body, sizeof(body), "transition h=%.0f last=%.0f full=%.0f",
                 size.height, before, full);
        AevonPageWrite(body);
    }
    // 0.0.77 — **这一拍不再写 offset**，只把「在看哪一帖」钉成行下标。
    //
    // 关卡之后 App 几十毫秒内就被挂起，挂在 dispatch_after 上的拍子确实轮不到跑；
    // 但「这一拍算一个正确的 offset」本来就不可能成立：新页高下的行原点要等 App
    // 排完才有。Aevon(67) 的 `transition scroll y=13623 -> 17708` 落进
    // `off=0,14912 / 行 14554` 就是这件事的形状 —— 19 × 932 没算错，行不在那儿。
    if (real) {
        if (AevonPagerGet() == nil || [AevonPagerGet() window] == nil) AevonPagerAcquire();
        // 0.0.79 — 换屏之前记下「本来在播」，换屏之后三拍复看（见 `AevonPlayNote`）。
        // 必须在 `AevonAlignPager` 之前：它会把视口挪到那一页的开头，挪的过程本身
        // 就可能让 App 停掉播放 —— 那时候再记，「本来在播」就已经看不见了。
        AevonPlayNote();
        AevonResumes = 0;
        for (int i = 0; i < 3; i++) {
            int64_t when = (int64_t)((0.5 + 0.85 * (double)i) * NSEC_PER_SEC);
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, when),
                             dispatch_get_main_queue(), (void *)AevonResumeWhy, AevonResumeTick);
        }
        // 先记一张「换算前」的：这一张能回答「App 收到 932↔717 时，它的页是不是
        // 也跟着变了」。之后每一拍都在回答「行下标还在不在同一页上」。
        AevonPageState("on transition");
        AevonAnchorRemember(AevonPagerGet(), before);
        for (int i = 0; i < 5; i++) {
            int64_t when = (int64_t)((0.4 + 1.1 * (double)i) * NSEC_PER_SEC);
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, when),
                             dispatch_get_main_queue(), (void *)AevonStateLate, AevonStateTick);
        }
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), (void *)AevonStateLate, AevonStateTick);
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), (void *)AevonStateLate, AevonStateTick);
    }
    for (int i = 0; i < 5; i++) {
        int64_t when = (int64_t)((0.05 + 0.22 * (double)i) * NSEC_PER_SEC);
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, when),
                         dispatch_get_main_queue(), (void *)AevonPagerEarly, AevonPagerTick);
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.35 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), (void *)AevonPagerLate, AevonPagerTick);
}

// MARK: - 0.0.72 停稳守卫

//
// 0.0.71 只有「过渡」与「窗口高度变化」两个触发点，而 Aevon(62) 的录屏说明错位
// 还有第三个来源：**用户自己划走之后**。翻页器按什么数吸附，是 App 自己的选择
// （它可能记着 932，也可能记着 717），我们既不该猜也不该改它的实现 —— 只要在
// 它停稳之后看一眼：offset 是不是整页？不是就挪回去。
//
// 判据三条，都很便宜：
//   · 0.15 s 一拍，只读一个 `contentOffset.y`；
//   · 手指还在动（tracking / dragging / decelerating）就不管；
//   · 连续 4 拍（0.6 s）都没变，才算「停稳」。
//
// 这一条同时覆盖 0.0.71 漏掉的两个场景：关卡之后（App 回到 932，offset 还是
// `N × 717`）与开卡之后（offset 还是 `N × 932`）。两者都是「停稳了，但不是整页」。

static void AevonPagerWatchTick(void *context) {
    (void)context;
    AevonWatchTicks += 1;
    // 2400 拍 = 6 分钟。卡片有十分钟上限，这个守卫比它先停 —— 停在别人家里
    // 的一个心跳，代价不该由这个 App 付。停了之后过渡钩子可以把它叫回来
    // （`AevonPagerWatchArm`），否则一张用得久一点的卡，守卫会在中途自己死掉，
    // 而关卡之后要归位的那一半正好落在死掉之后。
    if (AevonWatchTicks > 2400) {
        AevonWatchDead = 1;
        return;
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonPagerWatchTick);

    UIScreen *screen = [UIScreen mainScreen];
    CGFloat full = screen != nil ? [screen bounds].size.height : 0.0;
    if (full < 200.0) return;
    // 与 `AevonAlignPager` 用同一把尺子：两处各写一遍循环，迟早会出现「心跳
    // 说还在卡里、归位说窗口已经对了」这种自相矛盾的读数。
    CGFloat height = AevonWindowHeight();
    if (height < 200.0) return;
    BOOL shrunk = (height < full - 40.0);
    if (shrunk) AevonEverHosted = 1;
    if (!AevonEverHosted) return;
    // 0.0.80 — 1.5 s 一拍看一次「有没有浮层」。只在卡片在屏时看：全屏时窗口就是
    // 932，浮层本来就装得下，量它是白跑。
    if (shrunk) {
        // 0.0.83 — 抬浮层改成**每一拍都看**。0.0.82 是每 4 拍（0.6 s）看一次、
        // 还要连续两拍底边一致，两个 0.6 叠起来正好是 Aevon(74) 里那 1 秒
        // （`sheet` 在 17:46:46、`lift` 在 17:46:47）。扫描只是走一条
        // `presentedViewController` 链 + 一次 `convertRect:`，比一帧便宜得多。
        // `sheet` 那两行读数不再靠定期采样，改由「第一次看见这张浮层」触发
        // （见 `AevonSheetLift` 的 fresh 分支）。
        AevonSheetLift();
        // 0.0.84 — 横版画面贴顶：每 0.6 s 看一眼「那块矩形在不在容器正中」。
        // 它只在卡片里、只在「高度明显小于容器」时动手，铺满的竖版视频一律不碰。
        if ((AevonWatchTicks % 4) == 0) AevonVideoCenter();
    }

    // 窗口高度变了（过渡钩子没响的那一类 App、或者系统自己去改的）：上一拍的
    // 高度就是翻页器记忆里的页高。24 pt 容差躲开宿主自己 717→716→717 那一手。
    if (AevonWatchHeight < 200.0) {
        AevonWatchHeight = height;
        if (AevonPagerGet() == nil) AevonPagerAcquire();
        AevonAlignPager("watch first");
        return;
    }
    if (fabs(height - AevonWatchHeight) > 24.0) {
        // 0.0.81 — 方向要在覆盖之前读出来：`AevonWatchHeight` 下面立刻就被
        // 改成新的高度，之后再比就永远是「没变」。
        BOOL grew = (height > AevonWatchHeight + 24.0);
        // 0.0.73 — 旧页高单独存一份，而且续 90 拍机会。过渡钩子没响的那一类
        // App（根控制器不是标准容器）与「挂起之后系统自己去改」都只走这条路。
        AevonOldPage = AevonWatchHeight;
        AevonSettleTicks = 90;
        AevonSettleAge = 0;
        AevonLastPageHeight = AevonWatchHeight;
        AevonWatchHeight = height;
        AevonWatchTicks = 0;
        AevonGuardY = -1.0;
        AevonGuardHold = 0;
        AevonRebuilds = 0;
        AevonRebuildAt = 0.0;
        AevonRebuildSame = 0;
        AevonRebuildDead = 0;
        AevonRebuildTop = 0.0;
        AevonStuckLines = 0;
        AevonStuckAt = 0.0;
        // 0.0.81 — 过渡钩子没响的那一类 App 只有这里能看出方向：窗口变高 =
        // 交还整屏 ⇒ 重排往后推（同 `AevonRemeasurePending`）；变矮 = 开卡，
        // 照旧立刻做。
        if (grew) {
            AevonRemeasurePending = 1;
            AevonRemeasureTarget = height;
            AevonRemeasureAt = CFAbsoluteTimeGetCurrent();
            AevonRemeasureLogs = 0;
            AevonRemeasureWaits = 0;
        } else {
            AevonRemeasurePending = 0;
            AevonRemeasureTarget = 0.0;
        }
        UIScrollView *seen = AevonPagerGet();
        if (seen != nil) {
            CGFloat seenBox = [seen bounds].size.height;
            if (seenBox < 200.0) seenBox = AevonOldPage;
            AevonAnchorRemember(seen, seenBox);
        }
        if (AevonPagerGet() == nil) AevonPagerAcquire();
        AevonAlignPager("watch");
        // 0.0.74 — 关卡之后 App 被挂起，过渡钩子里排的那几拍不跑；用户点图标
        // 回到全屏时，这里才是「App 已经按 932 重排完」的第一个观测点。
        // 0.0.75 — 5 拍而不是 3 拍：加上的 6 s / 12 s 两拍是给「关卡之后用户
        // 过一会儿才回到全屏」那一段的。Aevon(65) 里关卡后只剩 3 拍（0.4 / 1.5 /
        // 2.6 s），拍完 App 还是旧几何，而它真正重排发生在用户回来那一刻 —— 那
        // 一刻没有任何读数，正是「断层查了五轮」一直缺的那一段。
        for (int i = 0; i < 5; i++) {
            int64_t when = (int64_t)((0.4 + 1.1 * (double)i) * NSEC_PER_SEC);
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, when),
                             dispatch_get_main_queue(), (void *)AevonStateLate, AevonStateTick);
        }
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), (void *)AevonStateLate, AevonStateTick);
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), (void *)AevonStateLate, AevonStateTick);
        return;
    }

    UIScrollView *view = AevonPagerGet();
    if (view == nil) {
        // 翻页器是 App 自己造的，开卡后 1 s 才出现。每 4 拍找一次，最多 40 次
        // （6 s）—— 再往后要么是还不该有，要么是这一版认不出来，继续找只是
        // 每 0.6 s 白遍历一遍视图树。
        if (AevonAcquireTries < 40) {
            AevonAcquireTries += 1;
            if ((AevonAcquireTries & 3) == 1) AevonPagerAcquire();
        }
        return;
    }
    if ([view window] == nil) {
        // 换了一面卡，或者 App 自己换掉了翻页器：忘掉，重新认。
        AevonPagerForget();
        AevonAcquireTries = 0;
        return;
    }
    if ([view isTracking] || [view isDragging] || [view isDecelerating]) {
        AevonGuardHold = 0;
        // 用户自己动了手 = 他要看哪一帖由他决定。行下标作废，剩下的交给
        // 「压住视口顶的那一页」那条路。
        AevonAnchorSet = 0;
        return;
    }
    // 0.0.73 — 归位窗口。卡片在屏 / 不在屏都要成立：关卡之后我们把窗口还回
    // 932，App 会在几十毫秒内被 `AevonPushBackground` + `deactivate` 挂起，
    // 过渡钩子里排的 6 拍根本轮不到跑；等用户点图标回来时，这里才是第一个
    // 能干活的地方。90 拍是「机会」不是「时长」——挂起期间不消耗。
    if (AevonSettleTicks > 0) {
        // 0.0.74 — 只有「这一拍真的读到了东西」才消耗机会。读不到（视口还没
        // 跟上、翻页器不在窗口里）不算用过，否则中间态会把整个窗口白烧掉。
        // 0.0.75 — 「读到了、但那还是旧几何」也算没到（`AevonAlignPager` 现在
        // 对这种情形直接返回 -1），于是窗口能一直撑到 App 真正重排完。
        NSInteger did = AevonAlignPager("settle");
        if (did >= 0) AevonSettleTicks -= 1;
        // 0.0.76 — 几何已经齐了的那几拍，顺带把「页里面」量一次：卡片里那个
        // 「视频上移」只在页高正确的时候才看得清，混装时量到的是断层。
        if (did == 0) AevonPagerInside("settle");
        // 0.0.81 — 等前台的那一段不计寿命：那 90 s 是「App 不肯重排」的兜底，
        // 不是「用户还没回来」的。把它算进去，用户过一分钟才回全屏就再也
        // 接不上这一次尺寸变化了。
        if (!AevonRemeasurePending) AevonSettleAge += 1;
        if (AevonSettleAge > 600) {          // 90 s 硬上限
            AevonSettleTicks = 0;
            AevonSettleAge = 0;
            AevonOldPage = 0.0;
            // 0.0.77 — 窗口到期就把行下标一起丢掉：留着它，停稳守卫会一直把
            // 视口往「很久以前那一帖」上拽，而用户早就划到别处去了。
            AevonAnchorSet = 0;
            AevonPageWrite("settle gave up after 90s");
        }
        if (AevonSettleTicks == 0) {
            AevonOldPage = 0.0;
            AevonAnchorSet = 0;
        }
        return;
    }
    // 停稳守卫只在卡片在屏时跑：否则这个 App 从此在桌面上被我们一直管着
    // offset —— 那不是这张卡该有的权限。
    if (!shrunk) return;
    CGFloat y = [view contentOffset].y;
    if (fabs(y - AevonGuardY) > 1.0) {
        AevonGuardY = y;
        AevonGuardHold = 0;
        return;
    }
    AevonGuardHold += 1;
    if (AevonGuardHold < 4) return;
    AevonGuardY = -1.0;
    AevonGuardHold = 0;
    // 停稳且几何齐的时候，正是「页里面」唯一量得清的时刻。
    if (AevonAlignPager("guard") == 0) AevonPagerInside("guard");
}

static void AevonPagerWatchArm(void) {
    if (AevonWatchArmed && !AevonWatchDead) return;
    AevonWatchArmed = 1;
    AevonWatchDead = 0;
    AevonWatchTicks = 0;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonPagerWatchTick);
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

    // 0.0.71 — 窗口尺寸变化的那一声。装不上不算错：日志里没有 `app: page
    // transition` 就说明这条路没通，下一轮改用别的入口，而不是接着猜。
    SEL transitionSel = sel_registerName("viewWillTransitionToSize:withTransitionCoordinator:");
    Method transition = class_getInstanceMethod([UIViewController class], transitionSel);
    if (transition != NULL) {
        AevonOriginalViewTransition = method_getImplementation(transition);
        method_setImplementation(transition, (IMP)AevonViewTransition);
    }

    // 0.0.84 — 「有东西要盖上来」这一声。分享面板抬高要发生在用户看见它之前，
    // 而心跳的相位是随机的（最坏 0.15 s 后才撞见，再加一次确认），所以直接接住
    // 呈现本身。装不上不算错：心跳那一份仍然会把面板抬好，只是慢一点。
    SEL presentSel = sel_registerName("presentViewController:animated:completion:");
    Method present = class_getInstanceMethod([UIViewController class], presentSel);
    if (present != NULL) {
        const char *encoding = method_getTypeEncoding(present);
        // 最后一个参数必须是 block（`@?`）。签名对不上就宁可不装 —— 这个钩子
        // 装错一次就是「所有弹出的控制器都少一个 completion」，不是抖动。
        if (encoding != NULL && strstr(encoding, "@?") != NULL) {
            AevonOriginalPresent =
                (void (*)(UIViewController *, SEL, UIViewController *, BOOL, void (^)(void)))
                method_getImplementation(present);
            method_setImplementation(present, (IMP)AevonPresentHook);
        }
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
