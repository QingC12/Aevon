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
#import <objc/runtime.h>

#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
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
static int AevonAlignFixes = 0;
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
/// 停稳守卫与窗口高度守卫的几个数（定义在这里，因为过渡钩子也要清它们）。
static CGFloat AevonGuardY = -1.0;
static int AevonGuardHold = 0;
static int AevonWatchTicks = 0;
static CGFloat AevonWatchHeight = 0.0;
static int AevonWatchArmed = 0;
/// 心跳撞上 2400 拍上限之后置 1。过渡钩子可以把它重新叫起来 —— 否则一张用得久
/// 一点的卡，守卫就会在用户还在用的时候自己先停了。
static int AevonWatchDead = 0;

static void AevonPagerKeep(UIScrollView *view) {
    if (view == nil) return;
    if (view == AevonPagerStore) return;
    // 换了一个翻页器 = 换了一次使用，配额跟着重新开。
    AevonAlignFixes = 0;
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

/// 把 offset 挪到最近的整页上：`round(y / 旧页高) × 新页高`。
///
/// 用旧页高取整，不是新页高。932→717 时 offset 是 `3 × 932 = 2796`，按新页高
/// 取整得到 `4 × 717 = 2868`（**甩到下一页**），按旧页高取整才是 `3 × 717 = 2151`
/// （停在同一页）。用户的眼睛认的是「第几帖」，不是「第几个像素」。
///
/// 0.0.73 — 两条新判据，都是 Aevon(63) 的日志逼出来的：
///
///   ① **视口必须已经等于窗口**（±8 pt）。窗口已经是 932、滚动视图还是 717 的那
///      几拍里，`round(y / 717) × 717` 算出来就是它自己，看着「已经对齐」，其实
///      什么都没做 —— 0.0.72 的 `pager=0 fixed=0 raw=1` 就是这个形状。
///   ② **页高优先用 `AevonOldPage`**，只要它还和当前视口不一样。App 重排完之后
///      单元格必然跟着变成 932，再「从单元格读」就等于用新页高取整 —— 又回到
///      第 1 段那个错。
///
/// 返回 1 改了一个，0 已经在整页上，-1 没有可改的对象（或还没到时候）。
static NSInteger AevonAlignPager(const char *reason) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil) return -1;
    if ([view window] == nil) return -1;
    CGFloat box = [view bounds].size.height;
    CGFloat full = AevonWindowHeight();
    // App 还没跟上这一次尺寸变化：先把机会留着，下一拍再说。
    if (full > 200.0 && fabs(box - full) > 8.0) return -1;
    CGSize span = [view contentSize];
    CGFloat y = [view contentOffset].y;
    if (box < 200.0 || span.height < box * 1.2) return -1;
    // ③ 先问一句：它已经站在**新**基准的整页上了吗？这一步让整条路变成幂等的。
    //
    // 过渡钩子里已经就地换算过一次时（`y = k × 932`），旧页高那一条会把它再换算
    // 成下一页 —— `932 / 717 = 1.3`，`round` 之后就是 2。所以「已经对齐」必须
    // 先判，而且判据只能用新的视口高度。
    if (fabs(y - round(y / box) * box) <= 1.5) {
        AevonOldPage = 0.0;
        AevonSettleTicks = 0;
        return 0;
    }
    CGFloat page = AevonPageHeightOf(view, box);
    if (AevonOldPage > 200.0 && fabs(AevonOldPage - box) > 8.0) page = AevonOldPage;
    if (page < 200.0) return -1;
    CGFloat target = round(y / page) * box;
    CGFloat cap = span.height - box;
    if (cap < 0.0) cap = 0.0;
    if (target < 0.0) target = 0.0;
    if (target > cap) target = cap;
    if (fabs(target - y) <= 1.5) {
        // 已经在整页上：这一次尺寸变化不需要我们做什么，申请作废。
        AevonOldPage = 0.0;
        AevonSettleTicks = 0;
        return 0;
    }
    // 60 次是「够用」与「别打架」的折中：一次使用里用户可能划上百下，错位都要
    // 能修；而如果 App 自己坚持把 offset 拉回去，再多的次数也只是互相推。
    if (AevonAlignFixes >= 60) return -1;
    [view setContentOffset:CGPointMake([view contentOffset].x, target) animated:NO];
    AevonAlignFixes += 1;
    // 挪完就是「按这个页高一步一页」，下一次核对的基准跟着换。
    AevonLastPageHeight = box;
    AevonOldPage = 0.0;
    AevonSettleTicks = 0;
    char body[300];
    snprintf(body, sizeof(body),
             "%s scroll y=%.0f -> %.0f page=%.0f box=%.0f cell=%.0f span=%.0f",
             reason, y, target, page, box, AevonCellHeightOf(view, box), span.height);
    AevonPageWrite(body);
    return 1;
}

/// 0.0.73 — 尺寸刚变的那一拍就地换算，不等 App 重排。
///
/// 过渡钩子里视口还是旧的（717），新高度在 `size.height` 里（932），而翻页器的
/// offset 是按旧页高算的 —— 这三件事在同一时刻都已知，所以**不需要**等 App 重排
/// 就能写出正确的那一个数：`round(y / 旧页高) × 新高度`。
///
/// 为什么非要在这一拍做：关卡之后我们立刻 `AevonPushBackground` + `deactivate`，
/// App 几十毫秒内就被挂起，挂在 `dispatch_after` 上的归位根本轮不到跑（0.0.71 /
/// 0.0.72 两份日志里，关卡那一拍都只有一行 `transition`，一条 `scroll` 都没有）。
/// 而这一行回调是在 App 进程里同步发生的 —— 写下去就已经生效。
///
/// 唯一的让步是内容还短：`contentSize` 此刻仍是 `8 × 717`，页码大的时候目标会
/// 超出可滚范围，`setContentOffset:` 会被 UIKit 夹住。夹住也不丢：`AevonOldPage`
/// 还留着，App 重排完之后心跳那一路会再补一次。
static void AevonConvertForTransition(CGFloat oldPage, CGFloat newHeight) {
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    if (oldPage < 200.0 || newHeight < 200.0) return;
    if (fabs(oldPage - newHeight) < 8.0) return;
    CGFloat y = [view contentOffset].y;
    CGFloat target = round(y / oldPage) * newHeight;
    if (fabs(target - y) <= 1.5) return;
    if (AevonAlignFixes >= 60) return;
    CGSize span = [view contentSize];
    CGFloat box = [view bounds].size.height;
    CGFloat cap = span.height - box;
    if (cap < 0.0) cap = 0.0;
    if (target < 0.0) target = 0.0;
    BOOL pinched = (target > cap);
    if (pinched) target = cap;
    [view setContentOffset:CGPointMake([view contentOffset].x, target) animated:NO];
    AevonAlignFixes += 1;
    char body[280];
    snprintf(body, sizeof(body),
             "transition scroll y=%.0f -> %.0f page=%.0f box=%.0f next=%.0f%s",
             y, target, oldPage, box, newHeight, pinched ? " pinched" : "");
    AevonPageWrite(body);
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

static void AevonPagerReport(const char *reason) {
    if (!AevonAppHookAllowed()) return;
    if (AevonPagerGet() == nil || [AevonPagerGet() window] == nil) AevonPagerAcquire();
    AevonAlignPager(reason);
    AevonDumpPlayers(reason);
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
        AevonWatchTicks = 0;
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
    // 0.0.73 — 就在这一拍把 offset 换成新基准。关卡的几十毫秒之后 App 就被挂起，
    // 挂在 dispatch_after 上的那些拍子根本轮不到跑（0.0.71/0.0.72 两份日志里关卡
    // 那一拍只有 transition、一条 scroll 都没有），而这一句是在 App 进程里同步
    // 发生的 —— 写下去就已经生效。
    if (real) {
        if (AevonPagerGet() == nil || [AevonPagerGet() window] == nil) AevonPagerAcquire();
        AevonConvertForTransition(before, size.height);
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

    // 窗口高度变了（过渡钩子没响的那一类 App、或者系统自己去改的）：上一拍的
    // 高度就是翻页器记忆里的页高。24 pt 容差躲开宿主自己 717→716→717 那一手。
    if (AevonWatchHeight < 200.0) {
        AevonWatchHeight = height;
        if (AevonPagerGet() == nil) AevonPagerAcquire();
        AevonAlignPager("watch first");
        return;
    }
    if (fabs(height - AevonWatchHeight) > 24.0) {
        // 0.0.73 — 旧页高单独存一份，而且续 90 拍机会。过渡钩子没响的那一类
        // App（根控制器不是标准容器）与「挂起之后系统自己去改」都只走这条路。
        AevonOldPage = AevonWatchHeight;
        AevonSettleTicks = 90;
        AevonLastPageHeight = AevonWatchHeight;
        AevonWatchHeight = height;
        AevonWatchTicks = 0;
        AevonGuardY = -1.0;
        AevonGuardHold = 0;
        if (AevonPagerGet() == nil) AevonPagerAcquire();
        AevonAlignPager("watch");
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
        return;
    }
    // 0.0.73 — 归位窗口。卡片在屏 / 不在屏都要成立：关卡之后我们把窗口还回
    // 932，App 会在几十毫秒内被 `AevonPushBackground` + `deactivate` 挂起，
    // 过渡钩子里排的 6 拍根本轮不到跑；等用户点图标回来时，这里才是第一个
    // 能干活的地方。90 拍是「机会」不是「时长」——挂起期间不消耗。
    if (AevonSettleTicks > 0) {
        AevonSettleTicks -= 1;
        AevonAlignPager("settle");
        if (AevonSettleTicks == 0) AevonOldPage = 0.0;
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
    AevonAlignPager("guard");
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
