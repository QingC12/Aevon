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

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#if defined(__arm64__) || defined(__aarch64__)
#include <mach/arm/thread_status.h>
#endif
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
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
/// 0.0.91 — 「死在哪一步」。signal handler 里只能读一个整数，所以每个可能死人的
/// 函数入口先写一次；崩溃之后日志里的 `step=` 就是「死在哪一行附近」。
/// 声明放在这里（而不是证词那一段），是因为下面的视频/浮层代码都要写它。
static volatile sig_atomic_t AevonStep = 0;
#define AEVON_STEP_NONE   0
#define AEVON_STEP_SCAN   2
#define AEVON_STEP_WRITE  3
#define AEVON_STEP_HOOK   4
#define AEVON_STEP_SHEET  5
#define AEVON_STEP_TICK   6
#define AEVON_STEP_RESOLVE 7

/// 0.0.94 — 「停在哪一句」。
///
/// Aevon(84) 的证据只有一条：20:42:38 之后 App 侧日志 14 秒零输出，随后进程被换掉
/// （`app: boot pid=24262`），而 `app: crash` 一条都没有。`step=` 只说「哪个函数」，
/// 答不出「是不是又一次卡在那句 `setTransform` 里」。所以这一版把粒度压到语句级：
/// 每个可能不返回的地方先写一次 `AevonSub`，看门狗线程在主线程 2 秒不动时把它连同
/// 主线程 PC + 调用栈一起写下来。信号处理器与看门狗都只读这个整数，不碰对象。
static volatile sig_atomic_t AevonSub = 0;
#define AEVON_SUB_NONE     0
#define AEVON_SUB_ORIG     1   // 进 App 自己的 layoutSubviews
#define AEVON_SUB_ORIG_END 2   // App 自己的 layoutSubviews 返回了
#define AEVON_SUB_RESOLVE  3   // 顺下标链取画面
#define AEVON_SUB_TX_BEGIN 4   // CATransaction begin
#define AEVON_SUB_SET      5   // setTransform 那一句
#define AEVON_SUB_TX_END   6   // CATransaction commit
#define AEVON_SUB_COLLECT  7   // 整页/视频区 BFS
#define AEVON_SUB_BAND     8   // 画面区里找那块矩形
#define AEVON_SUB_PICK     9   // 候选循环
#define AEVON_SUB_TICK     10  // 心跳那一拍

/// 排版钩子的重入深度（线程私有）。
///
/// Aevon(78) 那次「滑着滑着卡住、声音还在放」是钩子递归到栈满；0.0.88 加了安装期的
/// 判断，但从没有人量过运行期到底有多深。这一次让它有读数：`d=` 在证词里，
/// 栈溢出（SIGSEGV + 我们的 altstack）也会带着它一起落盘。
static __thread int AevonDepth = 0;
static volatile sig_atomic_t AevonDepthMax = 0;
/// 这段时间里排版钩子被叫了多少次。卡死时这两个数回答的是同一个问题的两半：
/// 「一次没回来」（`hook` 很小、`d` 正常）还是「回来了太多次」（`hook` 上千）。
static volatile sig_atomic_t AevonHookCalls = 0;
/// 正在处理的那一格 / 那块画面，只存尾数，只比较、永不 cast。
static volatile uintptr_t AevonHangCell = 0;
static volatile uintptr_t AevonHangBand = 0;
/// 0.0.94 — 这一次写入是从哪条车道来的：0 = 整页 cell 自己的排版，
/// 1 = 视频区（画面直接父视图）的排版，-1 = 心跳。
/// Aevon(84) 的那一次致命写入只知道是 `via=layout`，分不出车道 —— 下一条 `video band`
/// 行会带 `ln=` 与 `dr=`（写入那一刻翻页器是不是还在拖/惯性滑动），修复才有依据。
static volatile sig_atomic_t AevonVideoLaneNow = -1;
/// 主线程活口。一个 0.25 s 的 `dispatch_after_f` 链每拍 +1，与卡片、翻页器都无关 ——
/// 它要回答的是「主线程还在不在跑这个队列」，不是「某个功能还在不在工作」。
static volatile sig_atomic_t AevonMainBeat = 0;

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
/// 0.0.88 — 上一次问到的 `UIApplicationState`。只用来认「从后台/锁屏回到前台」
/// 这一个边沿：那一下要把画面记账整个作废（见 `AevonApplicationState`）。
static NSInteger AevonStateSeen = -1;
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
    AevonStep = AEVON_STEP_SHEET;
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

/// 0.0.86 — 居中要换**坐标系**：先在卡片里，再跟卡片的正中比。
///
/// 0.0.85 的判据选对了节点（Aevon(76) 里终于有了成功的 `video band v=`），算术
/// 也对，但它在**视频区自己的坐标系**里算：
///
///     want = (regionH - bandH) / 2;    gap = want - rb.origin.y;   // rb 在 region 里
///
/// 只要这块视频区在卡片里不是从 y=0 开始，这个原点偏移就整个漏进了结果 ——
/// 我们以为摆到了正中，屏幕上却还偏上（或者偏下）。Aevon(76) 的两行读数正好
/// 把它照出来，而且不是巧合：
///
///     video band v=TTMetalViewVP h=242 box=717 dy=42 n=1 r=TTPlayerView
///     video band v=TTMetalViewVP h=322 box=717 dy=42 n=1 r=TTPlayerView
///
/// 按 `want - dy` 反推 App 自己的原点：242 → 195.5，322 → 155.5，而
/// `(634 - h) / 2` 分别是 196.0 / 156.0 —— 两个点都对上，说明 App 的排版基准是
/// **634**（整页 717 减去底部那 83 pt 标签栏），而这个基准在它自己的空间里就已经
/// 被用过了。所以「再算准一点」这条路在旧的坐标系里是不可能走通的。
///
/// 这一版只改三件事，改的都是坐标系与落点，选节点那套（排除零件、按面积逐个试、
/// 递归找矩形）原样保留：
///   · `rb` 一律换算到**卡片**坐标系（`convertRect:toView:cell`），中间夹几层、
///     每层原点在哪都不再影响结果；
///   · 落点是**卡片正中**（`(cellH - bandH) / 2`），不再猜「标签栏算不算在里面」；
///   · 祖先里带缩放的跳过（那样位移会被一起放大），带裁切的把位移夹在可见范围内
///     并留一行 `video clip` —— 宁可少挪，不能把画面挪出去变成黑块。
///
/// 守卫不变：铺满整页的竖版不碰、带缩放/旋转的不碰、残差小于 8 pt 不动、平移只用
/// `transform`。每换一页清空记账，并放三行 `video scan`（候选在卡片里的矩形、目标、
/// 缺口）—— 这一版能自查，下一版换判据也靠它。
///
/// 0.0.88 — 「一块画面最多挪 N 次」取消了，改成按频率管（见 `AevonVideoSlot`）：
/// 次数上限会在一次锁屏之后把这块画面永久判死。
/// 0.0.88 — 「挪过几次」这个配额本身就是 bug。
///
/// 0.0.84~0.0.87 用 `hits` 计数：一块画面最多挪 3 次（心跳）/ 8 次（排版），
/// 用完就再也不碰。它防的是「App 每帧重置、我们每帧写」那种对打，代价却是
/// **一次锁屏就把这一块永久判死**：锁屏时 App 被挂起、图层被重建，我们写进去的
/// `transform` 归零（或 App 自己重新摆），可对象还是同一个、`hits` 早已用完 ——
/// 于是从此不再居中，只有重开悬浮窗（`AevonVideoCell` 变化 ⇒ `memset` 记账）
/// 才恢复。这就是 Aevon(78) 说的「锁屏后必须重开浮窗」。
///
/// 换成按**时间**管，而不是按次数：
///   · `wroteTy`/`wroteAt` 记住我们最后一次写进去的位移与时刻；
///   · 到位（`gap < 8`）⇒ 清零 `bounces` 并放掉 `holdUntil`，随时可再来；
///   · 同一次修正 40 ms 内不重复写（同一帧里多个 `layoutSubviews` 只做一次）；
///   · App 把我们写的抹掉了（`ty` 与我们写的不一致）⇒ `bounces += 1`，连续 30
///     次才歇 1 秒再试 —— 真对打的 App 仍然不会被我们拖着每帧写，可只要它停手，
///     下一秒就恢复。
///
/// 一句话：**上限可以是「频率」，不能是「终身」**。
typedef struct {
    void *band;
    int wrote;                  // 写过没有（比 wroteTy == 0 可靠：ty 恰好是 0 也算写过）
    int writes;                 // 一共写了几次（只用来决定要不要写日志）
    CGFloat wroteTy;            // 上一次写进去的 ty
    CFTimeInterval wroteAt;     // 上次写的时刻
    int bounces;                // 连续「写了又被抹掉」的次数
    CFTimeInterval holdUntil;   // 对打太凶时歇一下，到点自动再试
} AevonVideoSlot;

static AevonVideoSlot AevonVideoSlots[3];
static void *AevonVideoCell = NULL;
static int AevonVideoScanLeft = 0;
/// 0.0.89 — 指针尾 4 位。日志里只用来分辨「同一块对象还是换了对象」。
/// 直接对 ObjC 指针做位运算是 `-Wdeprecated-objc-pointer-introspection` 的靶子
/// （CI 用 `-Werror`，run 41819208583 就是挂在这里），先落到 `void *` 再取整数。
static unsigned long AevonPtrTag(const void *p) {
    return (unsigned long)(((uintptr_t)p) & 0xffffUL);
}

/// 0.0.89 — 读数限流改成**按时间**。
///
/// Aevon(79) 里 `video band none` 出现 58 次 + `video tree` 58 次，而源码里那两行
/// 的自带限流是 `AevonVideoNone < 2`（最多 2 次）。能写 58 次只有一个解释：
/// 每次心跳都命中了「换页」分支（`AevonVideoCell != cell`），把计数清零了。
/// 于是 45 秒里做了 58 次「整页 4000 节点遍历 + 递归 + 两行日志落盘」—— 卡屏的
/// 燃料有一半在这里。限流按时间走（每 2 s 最多一条）就不再受清账影响。
static CFTimeInterval AevonVideoNoneAt = 0.0;
static CFTimeInterval AevonVideoScanAt = 0.0;
/// 0.0.93 — `video miss` 的限流（每 2 s 最多一条）。
static CFTimeInterval AevonVideoMissAt = 0.0;

/// 0.0.89 — 「认一次就记住」。
///
/// Aevon(79) 的手感是「滑着滑着卡住 4 秒」。日志里我们这一侧单次最贵 25 ms
/// （`video slow … spent=25ms`），所以卡的不是单次，是**次数**：排版钩子每 8 ms
/// 就放行一次，每次都要 `AevonCollectPlayers` + `AevonBandUnder` 把整页扫一遍。
///
/// 一块画面在一页里只需要认一次。认出来就把 `(cell, band…)` 记下；之后的
/// `layoutSubviews` 只要发现 cell 还是同一个、band 还挂在它下面，就只做一次
/// `convertRect:` 加一次写 transform —— 两个 ObjC 调用，微秒级，扫零个视图。
/// 换页（cell 变了）或 band 掉出卡片（图层重建）才重新认。
/// 0.0.90 — 记住的是**路径**，不是对象。
///
/// 0.0.89 这里存的是 `void *band`，快路径每帧把它 cast 回 `UIView *` 直接发消息。
/// 这个文件是 MRC（Makefile 里没有 `-fobjc-arc`），存下来的是不 retain 的裸指针；
/// 抖音快速滑动时复用整页 cell，把里面的播放器、画面层摘掉并释放，而 cell 常常
/// 被复用到同一个地址 —— 地址比较照样通过，下一帧 `layoutSubviews`（每秒最多
/// 125 次）对着已析构的对象发消息就是 SIGSEGV。Aevon(80) 两次「只剩白色光晕」
/// 都落在「这一页第一次认出画面」的那一秒，形状完全对得上。
///
/// 现在只记「从 cell 往下第几层、第几个子视图」，每帧从**调用方当场给的** cell
/// 顺着下标现取；取不到、类名不对、矩形不正常就作废重扫。全程只有一个对象是新
/// 鲜的，结构上不可能再有野指针。
#define AEVON_PATH_MAX 8
typedef struct {
    unsigned char depth;                  // 0 = 无效
    unsigned char idx[AEVON_PATH_MAX];    // 自上而下每层在 subviews 里的下标
    char cls[28];                         // 末层类名，取出后再核一次
} AevonVideoPath;

/// 0.0.91 — 记账**每页一格**。
///
/// 0.0.90 只有一格，而翻页器稳态会留着**两格 cell**（Aevon(81) 的日志里
/// `c=e400` 与 `c=3000` 每两秒互相顶掉一次）：A 页认完、心跳落到 B 页就把记账清了，
/// 再回 A 页又要整页重扫 —— 于是 `video scan` / `video known` 每两秒重来一次，
/// 每一次都从 `gap=143` 把画面推回正中，屏幕上就是「视频从顶部慢慢居中」。
///
/// 两格按 cell 指针各记一条路径即可。页指针只做比较，**永不 cast、永不发消息**
/// （它同样是裸指针）。
#define AEVON_PAGE_SLOTS 2
#define AEVON_PATH_SLOTS 2
typedef struct {
    uintptr_t cell;                        // 0 = 空槽
    AevonVideoPath path[AEVON_PATH_SLOTS];
    int count;
    /// 记账的年龄（心跳拍数）。到点就作废重认一次：App 会在同一页里换版式/换层，
    /// 只认一次会永久指着旧的那块画面。32 拍 ≈ 6 s，代价是每 6 秒一次整页扫描。
    int age;
    /// 0.0.93 — 连续「这一帧对不上」的次数。
    ///
    /// 0.0.92 只要有**一次** `AevonVideoKnownApply` 返回 NO 就把整页记账清掉
    /// （`page->count = 0`）。而抖音每换一个视频就重建 Metal 渲染层，重建的那几帧里
    /// 下标链会短暂指不到东西 —— 于是一次抖动就换来一次整页重扫（4000 视图 BFS ×
    /// 候选数），换 10 个视频就是十场这样的风暴，主线程直接被吃干净（Aevon(83)）。
    /// 现在：连续 3 次对不上才认「这条链真的废了」，前两次只当这一帧没赶上。
    int miss;
} AevonVideoPage;

static AevonVideoPage AevonVideoPages[AEVON_PAGE_SLOTS];
static int AevonVideoPageNext = 0;

static AevonVideoPage *AevonVideoPageFind(uintptr_t cell) {
    if (cell == 0) return NULL;
    for (int i = 0; i < AEVON_PAGE_SLOTS; i++) {
        if (AevonVideoPages[i].cell == cell) return &AevonVideoPages[i];
    }
    return NULL;
}

/// 给这一页占一格。两格都满时按轮转顶掉一个 —— 不按指针大小挑，那等于随机。
static AevonVideoPage *AevonVideoPageTake(uintptr_t cell) {
    AevonVideoPage *hit = AevonVideoPageFind(cell);
    if (hit != NULL) return hit;
    AevonVideoPage *slot = &AevonVideoPages[AevonVideoPageNext];
    AevonVideoPageNext = (AevonVideoPageNext + 1) % AEVON_PAGE_SLOTS;
    memset(slot, 0, sizeof(*slot));
    slot->cell = cell;
    return slot;
}

static void AevonVideoKnownForget(void) {
    memset(AevonVideoPages, 0, sizeof(AevonVideoPages));
    AevonVideoPageNext = 0;
}

/// 0.0.89 — 「这一阵子我们吃了主线程多少」。
/// 每 0.5 s 结算一次，只有超过 80 ms（16% 的一秒）才记一行。正常时不出声，
/// 真卡住时下一份日志能直接看到是谁、多少次、多少毫秒 —— 不用再从「日志空白
/// 4 秒」去反推。
static int AevonVideoLoadN = 0;
static double AevonVideoLoadSpent = 0.0;
static CFTimeInterval AevonVideoLoadAt = 0.0;

/// 0.0.92 — 按**页**限流，而不是按画面指针。
///
/// 0.0.89~0.0.91 的去重键是画面指针（`AevonVideoSlot.band`）：抖音每换一个视频
/// 就重建画面层，`b=` 每次都是新对象，于是「40 ms 内只写一次」每次都被重置 ——
/// 同一页一秒钟能被写上百次。Aevon(82) 的卡屏（页面滑不动、点不动）与这条在
/// 时间上重合，而 `video load` 一条都没有（单次都没超过 80 ms）：卡的不是单次，
/// 就是次数。
///
/// 现在三件事一起兜：
///   · 同一页 40 ms 内只写一次 —— 键是 cell 地址，画面重建不影响；
///   · 同一页一秒内写满 40 次就停 0.5 秒（`hold`），自动恢复，**不是永久放弃**；
///   · `video rate n=/s` 每秒一行读数，只在峰值 ≥ 20 时写。
/// 这样即使下一次还卡，日志里也有「一秒写了多少次」这个数，不用再靠猜。
#define AEVON_RATE_SLOTS 3
typedef struct {
    void *cell;
    CFTimeInterval lastAt;
    CFTimeInterval winAt;
    CFTimeInterval hold;
    int winN;
} AevonWriteRate;

static AevonWriteRate AevonWriteRates[AEVON_RATE_SLOTS];
static int AevonWriteN = 0;
static int AevonWritePeak = 0;
static CFTimeInterval AevonWriteAt = 0.0;

/// 这一页现在允许写一次位移吗。返回 NO 时调用方**不要**写，也不要记 slot。
static BOOL AevonWriteAllowed(UIView *cell) {
    if (cell == nil) return NO;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    AevonWriteRate *rate = NULL;
    for (int i = 0; i < AEVON_RATE_SLOTS; i++) {
        if (AevonWriteRates[i].cell == (void *)cell) { rate = &AevonWriteRates[i]; break; }
    }
    if (rate == NULL) {
        for (int i = 0; i < AEVON_RATE_SLOTS; i++) {
            if (AevonWriteRates[i].cell == NULL) { rate = &AevonWriteRates[i]; break; }
        }
    }
    if (rate == NULL) rate = &AevonWriteRates[0];
    if (rate->cell != (void *)cell) {
        memset(rate, 0, sizeof(*rate));
        rate->cell = (void *)cell;
        rate->winAt = now;
    }
    if (now < rate->hold) return NO;
    if (now - rate->lastAt < 0.04) return NO;
    if (now - rate->winAt >= 1.0) { rate->winAt = now; rate->winN = 0; }
    if (rate->winN >= 40) {
        rate->hold = now + 0.5;
        rate->winN = 0;
        rate->winAt = now;
        return NO;
    }
    rate->winN += 1;
    rate->lastAt = now;
    return YES;
}

/// 记一次「真的写了」。每秒结算一次，峰值 ≥ 20 才写一行 ——
/// 这是「卡在次数上还是卡在单次上」的唯一直接读数。
static void AevonWriteCounted(void) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    AevonWriteN += 1;
    if (AevonWriteN > AevonWritePeak) AevonWritePeak = AevonWriteN;
    if (now - AevonWriteAt < 1.0) return;
    int peak = AevonWritePeak;
    AevonWriteAt = now;
    AevonWriteN = 0;
    AevonWritePeak = 0;
    if (peak < 20) return;
    char line[120];
    snprintf(line, sizeof(line), "video rate n=%d/s", peak);
    AevonPageWrite(line);
}

/// 一块画面在这张卡里的记账。按指针认；认不出来就占一个空槽，槽满了顶掉 [0]
/// （画面在翻页后本来就是新对象，旧记录留着只会挡住新手）。
static AevonVideoSlot *AevonVideoSlotFor(void *band) {
    for (int i = 0; i < 3; i++) {
        if (AevonVideoSlots[i].band == band) return &AevonVideoSlots[i];
    }
    for (int i = 0; i < 3; i++) {
        if (AevonVideoSlots[i].band == NULL) {
            memset(&AevonVideoSlots[i], 0, sizeof(AevonVideoSlots[i]));
            AevonVideoSlots[i].band = band;
            return &AevonVideoSlots[i];
        }
    }
    memset(&AevonVideoSlots[0], 0, sizeof(AevonVideoSlots[0]));
    AevonVideoSlots[0].band = band;
    return &AevonVideoSlots[0];
}

/// 换页、关窗、窗口尺寸变化：一律把记账清空。留着只会让「上一页挪过几次」这种
/// 与当前毫无关系的状态继续生效。
static void AevonVideoForget(void) {
    memset(AevonVideoSlots, 0, sizeof(AevonVideoSlots));
    memset(AevonWriteRates, 0, sizeof(AevonWriteRates));
    AevonVideoCell = NULL;
    AevonVideoScanLeft = 3;
    AevonVideoKnownForget();
}

/// 两个视图在同一棵树上互为祖先/后代。同一块画面常被「画面区 → 画面」两层同时
/// 命中，两层都挪一次就等于挪了两倍。
static BOOL AevonVideoKin(UIView *a, UIView *b) {
    if (a == nil || b == nil) return NO;
    if (a == b) return YES;
    for (UIView *p = [a superview]; p != nil; p = [p superview]) if (p == b) return YES;
    for (UIView *p = [b superview]; p != nil; p = [p superview]) if (p == a) return YES;
    return NO;
}

/// 从画面往上到卡片，有没有哪一层会裁。裁的话这块画面往下挪就会被切掉一截，
/// 那时把位移夹在可见范围内 —— 少挪一点也比挪成黑块强。
static BOOL AevonVideoClips(UIView *band, UIView *cell, CGFloat *delta) {
    BOOL clipped = NO;
    for (UIView *p = [band superview]; p != nil && p != cell; p = [p superview]) {
        if (![p clipsToBounds]) continue;
        CGRect b = [p bounds];
        CGRect r = [band convertRect:[band bounds] toView:p];
        CGFloat low = b.origin.y - r.origin.y + 8.0;                 // 最多能往上挪这么多（负）
        CGFloat high = CGRectGetMaxY(b) - CGRectGetMaxY(r) - 8.0;    // 最多能往下挪这么多（正）
        CGFloat d = *delta;
        if (d < low) { d = low; clipped = YES; }
        if (d > high) { d = high; clipped = YES; }
        *delta = d;
    }
    return clipped;
}

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
static NSUInteger AevonCollectPlayers(UIView *root, NSMutableArray *out) {
    if (root == nil || out == nil) return 0;
    // 0.0.89 — 广度优先 + 预算 4000，两条都是 Aevon(79) 逼出来的。
    //
    // 旧版是深度优先（数组当栈、`lastObject` 取尾），预算 1600。抖音一页的视图
    // （弹幕层 + 评论区 + 图标 + 各种角标）早就超过 1600，深度优先会先把左边某一棵
    // 子树走到底再回来 —— 日志里那 58 次 `video band none cls=AWEAwemePlayVideoPauseIc`
    // 就是证据：浅层那块全屏大的「暂停图标层」先被收下（面积最大 ⇒ 排第一），
    // 真正的视频区 `DDDanmakuPlayerView:0,0,430x634` 一次都没被走到，
    // 紧跟的 `video tree n=0` 说明连它的子视图都是空的。
    //
    // 广度优先保证「浅层的大容器」先被看见（视频区永远比弹幕/评论浅），
    // 4000 是抖音一页视图数的量级上界。这一条只在「认页」时跑（见
    // `AevonVideoKnown*`），不是每帧，贵一点换「一次就认全」。
    NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
    NSUInteger index = 0;
    while (index < todo.count && index < 4000) {
        UIView *node = [todo objectAtIndex:index];
        index += 1;
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
    return index;
}

/// 视频区里那块「宽度接近视频区、高度矮一截」的矩形。横版画面就是它。
/// 贴顶的优先（用户说的「上移」就是它），没有贴顶的才按面积取。
/// 0.0.89 — 同样改广度优先、预算 3000：视频区里真正那块画面层往往就挂在
/// 视频区的第二三层，深度优先会先钻进弹幕/进度条那一支。
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
    while (walked < todo.count && walked < 3000) {
        NSUInteger at = walked;
        walked += 1;
        UIView *node = [todo objectAtIndex:at];
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

/// 0.0.87 — 居中的**时刻**也是判据的一部分。
///
/// Aevon(77) 把「跳动」这件事说得非常清楚：翻到那一页时 App 自己先把画面摆在
/// `y=94`，我们的心跳那一拍才把它挪到 `y=238` —— 同一秒里 `video scan … gap=143`
/// 紧跟着 `video band … dy=143`，一进一出。屏幕上看到的就是「先按 App 的位置显示，
/// 再跳一下」。摆得对，但摆得晚。
///
/// 所以这一版不只问「摆得对不对」，还问「什么时候摆」。App 要挪画面一定要走
/// `-layoutSubviews`，那就钩住**视频区那一层**的 `layoutSubviews`：在原实现返回之后、
/// CoreAnimation 提交这一帧之前把 transform 写进去，第一帧画出来就是居中的。
/// 心跳那一份留着兜底（钩子没覆盖到的层级、或 App 换了版式），它慢一点但不缺席。
///
/// 两个坑都写在安装函数里：
///   · `class_getInstanceMethod` 可能拿到**父类**的方法。直接 `method_setImplementation`
///     会改掉 UIView 自己的 `layoutSubviews` —— 那是整台机器每一层视图。所以先确认
///     这个方法属于这个类；不属于就先 `class_addMethod` 把继承来的实现钉在它自己
///     身上，再改那一条。
///   · 写 transform 时套一层 `CATransaction` + `setDisableActions:YES`：App 的排版
///     常常发生在动画块里，不关掉隐式动画，我们这一手会被它做成一段滑动 ——
///     那就还是「跳一下」，只是慢镜头。
typedef struct {
    Class cls;
    IMP orig;
    int video;                  // 0 = 只当「页」用，1 = 画面那一族（值得每帧看一眼）
} AevonLayoutHookSlot;

static AevonLayoutHookSlot AevonLayoutHookSlots[6];
static int AevonLayoutHookCount = 0;
static int AevonVideoBusy = 0;
/// 0.0.93 — 扫描的「两条车道 + 一道退避」。
///
/// `AevonVideoLaneAt[0]` 是整页那一层（`cell` 自己排版），`[1]` 是视频区那一层。
/// 拆开是因为 0.0.91 的单一门让整页先到的那一拍把视频区挡在外面，每个视频第一帧
/// 都停在顶部（Aevon(82)）。`AevonVideoScanNext` 是**失败退避**：真扫了一趟、扫不出
/// 东西，0.3 s 内任何车道都不再扫 —— 否则「这一页真没有横版画面」会变成每帧一次
/// 整页 BFS，比不修还狠。
static CFTimeInterval AevonVideoLaneAt[2] = {0.0, 0.0};
static CFTimeInterval AevonVideoScanNext = 0.0;
/// 0.0.88 — 自伤保护：某一次扫描如果贵到会拖帧（> 8 ms），停 2 秒再试。
/// Aevon(78) 那次卡住是主线程被我们吃掉的形状，宁可少居中两秒，也不能卡住手机。
static CFTimeInterval AevonVideoPause = 0.0;

static void AevonVideoCenterFor(UIView *cell, UIView *hint, const char *via);
static void AevonLayoutHook(id self, SEL _cmd);
static BOOL AevonVideoKnownApply(UIView *cell, const char *via);

/// 0.0.89 — 每 0.5 s 结算一次「我们吃了主线程多少」。
/// Aevon(79) 的卡屏只能从「App 侧日志空白 4.5 秒」反推，太绕了。这一行直接把
/// 次数与毫秒写在日志里：`n` 是这段时间排版钩子真正干活（含快路径）的次数，
/// `spent` 是累计毫秒，`%` 是占这半秒的比例。
///
/// 0.0.93 — 门槛 80 ms → 40 ms（8% 的一秒）。Aevon(83) 从头到尾一条 `video load`
/// 都没有，于是「卡屏到底是不是我们吃的」只能靠猜 —— 每次 layout 只花 1~2 ms、
/// 半秒里几十次、合计 60 ms，刚好被 80 的线漏掉，而 60 ms/0.5 s 已经够把滚动拖垮。
/// 门槛降到 40 之后，这种「单次便宜、次数多」的形态会第一次被记下来。
static void AevonVideoLoadReport(void) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - AevonVideoLoadAt < 0.5) return;
    int n = AevonVideoLoadN;
    double spent = AevonVideoLoadSpent;
    AevonVideoLoadAt = now;
    AevonVideoLoadN = 0;
    AevonVideoLoadSpent = 0.0;
    if (spent < 40.0) return;
    char line[160];
    snprintf(line, sizeof(line), "video load n=%d spent=%.0fms=%.0f%%",
             n, spent, spent / 5.0);
    AevonPageWrite(line);
}

/// 这个方法是不是**这个类自己**实现的。`class_getInstanceMethod` 会把父类的实现
/// 借给你，改它等于改父类（对 `layoutSubviews` 来说就是改 UIView，整台机器每一层）。
/// 判法只用 `class_addMethod`：它只查这个类自己的方法表，成功就说明「原来只有父类
/// 有」—— 那一次添加正好把继承来的实现钉在了它自己身上。
/// `video`：这个类是不是「画面那一族」。0 只有「页」会用到；1 是画面区/画面本身。
/// 钩子本身挂得很少（最多 6 个类），但 `layoutSubviews` 一秒能响上千次，
/// 所以每响一次的第一件事就是查这个标记 —— 不是画面那一族、也不是页，立刻返回。
static void AevonHookLayout(Class cls, int video) {
    if (cls == Nil || cls == [UIView class] || cls == [NSObject class]) return;
    for (int i = 0; i < AevonLayoutHookCount; i++) {
        if (AevonLayoutHookSlots[i].cls == cls) {
            if (video) AevonLayoutHookSlots[i].video = 1;
            return;
        }
    }
    if (AevonLayoutHookCount >= 6) return;
    SEL sel = sel_registerName("layoutSubviews");
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    const char *types = method_getTypeEncoding(m);
    if (types == NULL) return;
    IMP inherited = method_getImplementation(m);
    // 0.0.88 — 这里藏着一个能让主线程当场卡死的坑。
    //
    // 父类先被钩过之后，`class_getInstanceMethod(sub, sel)` 拿到的是**父类那条
    // Method**，而它的 implementation 此刻已经是 `AevonLayoutHook`。原样
    // `class_addMethod` 钉到子类上，再把它记成「原实现」——钩子一跑就会去调
    // 自己，一层层自我递归到栈满。抖音那种「播放器 → 播放视图 → 视频层」三层
    // 同名的类最容易踩，Aevon(78) 的「滑动中卡一次、声音还在放、等一会儿自己
    // 恢复」就是这个形状：主线程陷在递归里，音频线程照常跑。
    //
    // 所以先问一句「这个 implementation 是不是我们自己」，是的话就往上找父类
    // 槽里记的真实现；找不到就放弃钩这个类，什么都不改。
    if (inherited == (IMP)AevonLayoutHook) {
        IMP real = NULL;
        for (Class p = class_getSuperclass(cls); p != Nil && real == NULL;
             p = class_getSuperclass(p)) {
            for (int i = 0; i < AevonLayoutHookCount; i++) {
                if (AevonLayoutHookSlots[i].cls == p) { real = AevonLayoutHookSlots[i].orig; break; }
            }
        }
        if (real == NULL || real == (IMP)AevonLayoutHook) return;
        inherited = real;
    }
    if (inherited == NULL) return;
    if (class_addMethod(cls, sel, inherited, types)) {
        // 类自己没有实现：刚钉上去的那一条就是「原实现」。
        m = class_getInstanceMethod(cls, sel);
        if (m == NULL) return;
    }
    AevonLayoutHookSlots[AevonLayoutHookCount].cls = cls;
    AevonLayoutHookSlots[AevonLayoutHookCount].orig = method_getImplementation(m);
    AevonLayoutHookSlots[AevonLayoutHookCount].video = video ? 1 : 0;
    AevonLayoutHookCount += 1;
    method_setImplementation(m, (IMP)AevonLayoutHook);
}

/// 这一类是不是「画面那一族」。子类继承父类的槽也要认（App 常在播放器外面
/// 再套一层自己的子类）。
static BOOL AevonLayoutHookWants(Class cls) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        for (int i = 0; i < AevonLayoutHookCount; i++) {
            if (AevonLayoutHookSlots[i].cls == c) return AevonLayoutHookSlots[i].video != 0;
        }
    }
    return NO;
}

/// 从 `cls` 往上找我们记过的原实现。子类继承过去的实现也要能找到，否则
/// 钩子里调不到 App 自己的排版代码，等于把这一层排版吞了。
static IMP AevonLayoutOriginalFor(Class cls) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        for (int i = 0; i < AevonLayoutHookCount; i++) {
            if (AevonLayoutHookSlots[i].cls == c) return AevonLayoutHookSlots[i].orig;
        }
    }
    return NULL;
}

/// 要不要管这一次排版：只有「卡片在屏」时管。全屏时窗口就是整屏，画面本来
/// 就装得下，插手只是白花 CPU。
static BOOL AevonCardIsUp(void) {
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat full = screen != nil ? [screen bounds].size.height : 0.0;
    if (full < 200.0) return NO;
    CGFloat height = AevonWindowHeight();
    return (height > 200.0 && height < full - 40.0);
}

/// 这个视图属于哪一页：`view` 的直接子视图里、包含它的那一个。
static UIView *AevonPageCellOf(UIView *node, UIScrollView *view) {
    UIView *p = node;
    int steps = 0;
    while (p != nil && steps < 16) {
        if ([p superview] == view) return p;
        if (p == (UIView *)view) return nil;
        p = [p superview];
        steps += 1;
    }
    return nil;
}

static void AevonLayoutHookBody(id self, SEL _cmd) {
    AevonStep = AEVON_STEP_HOOK;
    AevonSub = AEVON_SUB_ORIG;
    IMP orig = AevonLayoutOriginalFor(object_getClass(self));
    if (orig != NULL) ((void (*)(id, SEL))orig)(self, _cmd);
    AevonSub = AEVON_SUB_ORIG_END;
    if (AevonVideoBusy) return;
    if (![self isKindOfClass:[UIView class]]) return;
    // 0.0.88 — 便宜的门全部排在扫描之前，而且第一道门就是「你到底是不是我们管的类」。
    //
    // 这个钩子装在 App 的若干个类上，滑动时每帧响好几次；一旦往下走就要遍历子树
    // 找「画面区 + 画面」。抖音一页里有上千个视图，每帧扫几遍就是几百毫秒的空白 ——
    // Aevon(78) 那次「滑着滑着卡住、音频还在放、等一会儿自己恢复」就是这个形状。
    //
    // 所以第一问不是尺寸、不是状态：**这一类的槽里 `video` 是 1 吗**（画面区/画面
    // 本身），或者它是不是整页那一层（`cell == node`，页的排版要赶在复用/开卡那一帧）。
    // 其余几百层视图在这儿就返回了，代价是两个指针的比较。
    UIView *node = (UIView *)self;
    if ([node bounds].size.width < 120.0 || [node bounds].size.height < 120.0) return;
    BOOL videoLayer = AevonLayoutHookWants(object_getClass(node));
    AevonVideoLaneNow = videoLayer ? 1 : 0;
    UIScrollView *view = AevonPagerGet();
    // 没有翻页器（还没认出来）就什么都不做：这里每帧都在跑，不能自己去认。
    if (view == nil || [view window] == nil) return;
    UIView *cell = AevonPageCellOf(node, view);
    if (cell == nil) return;
    if (!videoLayer && cell != node) return;
    // 这一层必须铺到卡片的八成宽，否则它不是画面那一族（省掉整棵子树的遍历）。
    if ([node bounds].size.width < [cell bounds].size.width * 0.8) return;
    if (!AevonAppHookAllowed()) return;
    if (!AevonCardIsUp()) return;
    // 0.0.91 — 认过的页**先写，而且不受 8 ms 门限制**。
    //
    // Aevon(81) 里 `video band` 几乎都是 `via=tick`、每次 `gap` 都是 142/143：
    // 纠正落在心跳上（0.6 s 一拍），而 App 早在自己那一帧里把画面摆在了 y=94 ——
    // 于是这 143 pt 的位移每次都被看见，用户说的「从顶部居中」就是它。
    //
    // 8 ms 门本来是给「整页扫描」用的（一帧只放行一个视图，防止同帧几个视图
    // 各扫一遍整页）。认过的页只做几次取下标 + 一次 convertRect，微秒级；
    // 同帧七个视图各自走一次也仍然免费。让它们全部通过，画面层才能在**它自己
    // 那一拍**里、在 CoreAnimation 提交之前就被摆好 —— 用户看不到它动。
    AevonVideoBusy = 1;
    CFTimeInterval began = CFAbsoluteTimeGetCurrent();
    BOOL known = AevonVideoKnownApply(cell, "layout");
    AevonVideoBusy = 0;
    AevonVideoLoadN += 1;
    AevonVideoLoadSpent += CFAbsoluteTimeGetCurrent() - began;
    AevonVideoLoadReport();
    if (known) return;
    // 0.0.93 — 记账还在、只是这一帧对不上：**不扫**，下一帧再 resolve。
    //
    // 这是这一版最关键的一句。`AevonVideoKnownApply` 返回 NO 有两种情况：
    //   · 这一页从来没认过（`count == 0`）—— 该扫；
    //   · 认过，只是这一帧的下标链指不到东西 —— **不该扫**。
    // 抖音每换一个视频就重建 Metal 渲染层，重建的那几帧正好落进第二种。0.0.92
    // 不分这两种，一律往下走进整页扫描：滑动一秒钟能对不上几十帧，每帧一次
    // 4000 视图 BFS + 候选 × 3000 —— Aevon(83) 的「连滑 10 个视频必定卡死」
    // 就是这些扫描叠出来的。`miss` 容错负责把「真废了」和「这一帧没赶上」分开。
    AevonVideoPage *resolved = AevonVideoPageFind((uintptr_t)cell);
    if (resolved != NULL && resolved->count > 0) return;

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now < AevonVideoPause) return;                 // 上一次太贵，歇一下
    // 0.0.93 — 两条车道各一个 8 ms 门，互不阻挡。
    //
    // 0.0.92 只有整页那一路走门、视频区每次都扫，方向是对的（视频区那层要先认），
    // 但没给失败留退避 —— 于是「每一帧把视频区 130 个视图走一遍」变成了常态。
    // 现在：视频区自己那一次照旧优先（8 ms ≈ 半帧，够它每帧来一次），
    // 真扫空之后统一歇 0.3 s。
    int lane = videoLayer ? 1 : 0;
    if (now < AevonVideoScanNext) return;
    if (now - AevonVideoLaneAt[lane] < 0.008) return;
    AevonVideoLaneAt[lane] = now;
    AevonVideoBusy = 1;
    AevonVideoCenterFor(cell, videoLayer ? node : nil, "layout");
    AevonVideoBusy = 0;
    AevonVideoLoadN += 1;
    AevonVideoLoadSpent += CFAbsoluteTimeGetCurrent() - began;
    AevonVideoLoadReport();
    // 0.0.89 — 扫完没认出来，就把下一次扫排到 0.3 s 之后。
    // 0.0.93 — 这条退避现在对**所有**车道生效（0.0.92 只挂在整页那一路，
    // 视频区那条不受限，于是空页的每一次排版都要把视频区走一遍）。
    AevonVideoPage *fresh = AevonVideoPageFind((uintptr_t)cell);
    if (fresh == NULL || fresh->count == 0) AevonVideoScanNext = now + 0.292;
    // 自伤保护：一次扫描贵过 8 ms 就不是「一帧内的判断」了，停 2 秒再试。
    // 卡住主线程的代价比画面偏上大得多 —— 这一条是给下一次意外留的刹车，
    // 不是给已知场景用的。
    CFTimeInterval spent = CFAbsoluteTimeGetCurrent() - now;
    if (spent > 0.008) {
        AevonVideoPause = now + 2.0;
        char line[140];
        snprintf(line, sizeof(line), "video slow %.20s spent=%.0fms hold=2s",
                 class_getName(object_getClass(node)), spent * 1000.0);
        AevonPageWrite(line);
    }
}

/// 0.0.94 — 钩子的外壳只做两件事：数深度、数次数。
///
/// Aevon(84) 里「14 秒零输出」有两种形状，读数不一样：
///   · **一次没回来** —— `hook` 是几十、`d` 是 1；
///   · **回来了太多次** —— `hook` 上千、`d` 涨到几十（又一次自我递归）。
/// 看门狗把这两个数写在 `app: hang` 那一行里，就不再需要靠猜。
static void AevonLayoutHook(id self, SEL _cmd) {
    AevonDepth += 1;
    AevonHookCalls += 1;
    if ((int)AevonDepthMax < AevonDepth) AevonDepthMax = AevonDepth;
    AevonLayoutHookBody(self, _cmd);
    AevonDepth -= 1;
}

/// 0.0.89 — 写一块画面。抽出来是因为现在有两条路要写它：
/// 「刚认出来那一趟」（tick/layout 首次识别，顺带写读数）与「已经认过的页」
/// （排版钩子每帧都能撞上，只做几何，不遍历）。
static void AevonVideoWrite(UIView *band, UIView *cell, CGRect rb,
                            const char *rname, const char *via) {
    AevonStep = AEVON_STEP_WRITE;
    if (band == nil || cell == nil) return;
    // 0.0.92 — 只在主线程写。
    //
    // `CATransaction begin/commit` 是**线程私有**的：在子线程开一个、在主线程提交
    // 另一个，事务栈就错位了。`layoutSubviews` 按说只在主线程，但抖音有几层是
    // 自己的渲染容器，一旦有一条从别处进来，错位的事务会让整个 App 的 UI 更新
    // 停住 —— 而进程还活着（Aevon(82) 的「页面点不动、日志每秒还在写」正是这个形状）。
    // 这一句的代价是一次 TLS 读；收益是这条路不可能再把事务栈弄坏。
    if (![NSThread isMainThread]) return;
    CGFloat cellH = [cell bounds].size.height;
    CGFloat want = (cellH - rb.size.height) / 2.0;
    CGFloat gap = want - rb.origin.y;
    AevonVideoSlot *slot = AevonVideoSlotFor((void *)band);
    if (fabs(gap) < 8.0) {          // 已经在卡片正中
        slot->wrote = 0;
        slot->bounces = 0;
        slot->holdUntil = 0.0;
        return;
    }
    CGAffineTransform t = [band transform];
    // 缩放 / 旋转 / 横向位移都不是我们写的：那是 App 自己的动画，别抢。
    if (fabs(t.a - 1.0) > 0.01 || fabs(t.d - 1.0) > 0.01 || fabs(t.tx) > 0.5) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now < slot->holdUntil) return;
    // App 把我们上次写进去的位移抹掉了（`ty` 和我们写的不一样）：这一次是「对打」。
    // 连错 30 次（约 1 s 的密集排版）才歇 1 秒 —— 歇完自动再试，**不是永久放弃**。
    // 0.0.84~0.0.87 的 `hits` 是终身配额，一次锁屏就能把这块画面判死。
    if (slot->wrote && fabs(t.ty - slot->wroteTy) > 1.0) slot->bounces += 1;
    if (slot->bounces >= 30) {
        slot->bounces = 0;
        slot->holdUntil = now + 1.0;
        return;
    }
    // 同一帧里连着的几次 `layoutSubviews`、两块候选各写一次：40 ms 内只写一次。
    if (now - slot->wroteAt < 0.04) return;
    BOOL clip = AevonVideoClips(band, cell, &gap);
    if (fabs(gap) < 8.0) return;
    // 0.0.92 — 按**页**限流（上面那道是按画面指针的，画面一重建就重置了）。
    // 放在几何检查之后：白算的这一次不该占配额。
    if (!AevonWriteAllowed(cell)) return;
    slot->wrote = 1;
    slot->writes += 1;
    slot->wroteTy = t.ty + gap;
    slot->wroteAt = now;
    // 0.0.94 — 这三句是整份日志里唯一会改 App 视图几何的调用。Aevon(84) 里唯一一次
    // `via=layout` 恰好就是死前最后一条读数，所以把「正在改哪一格、哪一块、改到哪
    // 一步」留在全局里，主线程不回来时看门狗能替它念出来。
    AevonHangCell = (uintptr_t)cell;
    AevonHangBand = (uintptr_t)band;
    // 关掉隐式动画：App 的排版常常发生在动画块里，不关的话我们这一手会被它
    // 做成一段滑动，看上去还是「跳一下」，只是慢镜头。
    AevonSub = AEVON_SUB_TX_BEGIN;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    AevonSub = AEVON_SUB_SET;
    [band setTransform:CGAffineTransformMakeTranslation(0, slot->wroteTy)];
    AevonSub = AEVON_SUB_TX_END;
    [CATransaction commit];
    AevonSub = AEVON_SUB_NONE;
    AevonWriteCounted();
    if (clip) {
        char line[210];
        snprintf(line, sizeof(line), "video clip %.20s moved=%.0f need=%.0f n=%d",
                 class_getName([band class]), gap, want - rb.origin.y, slot->writes);
        AevonPageWrite(line);
    }
    // 每块画面只记头两次：钩子那条路如果每帧都要补（App 每帧重置 transform），
    // 写日志只会把真正有用的读数冲掉。
    //
    // 0.0.89 — 行尾加 `c=`/`b=`/`ty=`：
    //   · `c=` 是页（cell）指针尾 4 位，`b=` 是画面指针尾 4 位。同一秒里两次写入
    //     如果 `c=` 一样而 `y=` 变回去了，就是 **App 把我们的位移抹掉**（对打）；
    //     如果 `c=` 变了，那是换页 —— Aevon(79) 里正是分不清这两者，才只能靠猜。
    //   · `ty=` 是**写之前**画面自己的位移。App 若用 transform 摆位置，这个数不为 0。
    if (slot->writes <= 2) {
        char body[380];
        // 0.0.94 — 加 `ln=`（车道）与 `dr=`（写入那一刻翻页器是否在拖/惯性滑动）。
        // Aevon(84) 的致命写入只有 `via=layout` 一个线索，分不清是「整页那一层」
        // 还是「视频区那一层」，也分不清当时在不在滑动 —— 这两个数就是下一版的判据。
        UIScrollView *pager = AevonPagerGet();
        int drag = (pager != nil && ([pager isDragging] || [pager isDecelerating])) ? 1 : 0;
        snprintf(body, sizeof(body),
                 "video band v=%.24s h=%.0f y=%.0f want=%.0f dy=%.0f n=%d r=%.24s via=%.8s c=%04lx b=%04lx ty=%.0f ln=%d dr=%d",
                 class_getName([band class]), rb.size.height, rb.origin.y,
                 want, gap, slot->writes, rname != NULL ? rname : "?", via,
                 AevonPtrTag(cell),
                 AevonPtrTag(band), t.ty, (int)AevonVideoLaneNow, drag);
        AevonPageWrite(body);
    }
}

/// 0.0.90 — 把「cell 里的一块画面」翻译成一条子视图下标链。
///
/// 只在**认页那一趟**跑（每页一次），所以这里用 `indexOfObjectIdenticalTo:`
/// 这种 O(n) 找兄弟下标是可以接受的：认完之后每帧只走 `AevonVideoPathResolve`，
/// 一次只碰一层的 `subviews`。
static BOOL AevonVideoPathOf(UIView *cell, UIView *band, AevonVideoPath *out) {
    if (cell == nil || band == nil || out == nil || band == cell) return NO;
    unsigned char back[AEVON_PATH_MAX];
    int depth = 0;
    UIView *node = band;
    while (node != nil && node != cell && depth < AEVON_PATH_MAX) {
        UIView *parent = [node superview];
        if (parent == nil) return NO;
        NSUInteger at = [[parent subviews] indexOfObjectIdenticalTo:node];
        if (at == NSNotFound || at > 250) return NO;
        back[depth] = (unsigned char)at;
        depth += 1;
        node = parent;
    }
    if (node != cell || depth == 0) return NO;
    memset(out, 0, sizeof(*out));
    out->depth = (unsigned char)depth;
    for (int i = 0; i < depth; i++) out->idx[i] = back[depth - 1 - i];
    const char *name = class_getName([band class]);
    snprintf(out->cls, sizeof(out->cls), "%s", name != NULL ? name : "?");
    return YES;
}

/// 从这一帧的 cell 顺着下标链把画面取回来。任何一步对不上就返回 nil ——
/// 这里**只**会对刚拿到的 `subviews` 数组里的对象发消息，拿不到就不发。
static UIView *AevonVideoPathResolve(UIView *cell, const AevonVideoPath *path) {
    if (cell == nil || path == NULL) return nil;
    if (path->depth == 0 || path->depth > AEVON_PATH_MAX) return nil;
    UIView *node = cell;
    for (int i = 0; i < path->depth; i++) {
        NSArray *kids = [node subviews];
        if (path->idx[i] >= kids.count) return nil;
        node = [kids objectAtIndex:path->idx[i]];
    }
    const char *name = class_getName([node class]);
    if (name == NULL || strcmp(name, path->cls) != 0) return nil;
    return node;
}

/// 0.0.90 — 这一页认过没有；认过就直接写，不再遍历。
///
/// 失效判据四条，任一不成立就丢掉记账、让调用方去重扫：
///   · 下标链还能从**这一帧的** cell 取回一个对象（不是上次那个对象）；
///   · 取回来的类名还是当初那个（同一格被换成别的东西）；
///   · 矩形还有正常尺寸、且没有变成铺满整页（App 换了版式 ⇒ 竖版不居中的规矩照旧）；
///   · 不隐藏、不透明为 0（同一页里换视频时旧那块会被隐藏）。
/// 返回值只表示「记账还能用」，不代表这一帧一定写了 transform。
static BOOL AevonVideoKnownApply(UIView *cell, const char *via) {
    if (cell == nil) return NO;
    AevonStep = AEVON_STEP_RESOLVE;
    AevonSub = AEVON_SUB_RESOLVE;
    AevonVideoPage *page = AevonVideoPageFind((uintptr_t)cell);
    if (page == NULL || page->count <= 0) return NO;
    CGFloat cellH = [cell bounds].size.height;
    CGFloat cellW = [cell bounds].size.width;
    if (cellH < 200.0) return NO;
    BOOL alive = NO;
    for (int i = 0; i < page->count && i < AEVON_PATH_SLOTS; i++) {
        UIView *band = AevonVideoPathResolve(cell, &page->path[i]);
        if (band == nil) continue;
        if ([band isHidden] || [band alpha] < 0.01) continue;
        CGRect rb = [band convertRect:[band bounds] toView:cell];
        if (rb.size.width < cellW * 0.5 || rb.size.height < 80.0) continue;
        if (rb.size.height > cellH - 40.0) continue;
        alive = YES;
        AevonVideoWrite(band, cell, rb,
                        class_getName([[band superview] class]), via);
    }
    if (alive) {
        page->miss = 0;
        return YES;
    }
    // 0.0.93 — 连续 3 次对不上才清账。
    //
    // 一次失败就 `page->count = 0` 是 Aevon(83) 卡屏的扳机：抖音换视频时画面层
    // 会重建，重建的那几帧下标链指不到东西，于是「清账 → 整页 BFS → 重认 →
    // 下一帧又对不上 → 再清账」每换一个视频都要跑几十轮。滑到第 10 个视频，
    // 主线程就再也缓不过来。
    page->miss += 1;
    if (page->miss < 3) return NO;
    int misses = page->miss;
    page->miss = 0;
    // 只作废这一页：另一页的账与它无关，一起清掉就又回到「每两秒重扫」。
    page->count = 0;
    memset(page->path, 0, sizeof(page->path));
    // 判据：真清账才留一行（每 2 s 最多一条）。卡屏时靠它区分
    // 「我们一直在重扫」和「我们其实什么都没干」。
    CFTimeInterval missNow = CFAbsoluteTimeGetCurrent();
    if (missNow - AevonVideoMissAt > 2.0) {
        AevonVideoMissAt = missNow;
        char body[120];
        snprintf(body, sizeof(body), "video miss n=%d c=%04lx",
                 misses, AevonPtrTag(cell));
        AevonPageWrite(body);
    }
    return NO;
}

static void AevonVideoCenterFor(UIView *cell, UIView *hint, const char *via) {
    AevonStep = AEVON_STEP_SCAN;
    if (cell == nil) return;
    CGFloat cellH = [cell bounds].size.height;
    if (cellH < 200.0) return;

    NSMutableArray *players = [NSMutableArray array];
    // 排版钩子里只扫被排版的那一层（视频区自己，几十个视图），不扫整页 ——
    // 钩子每帧都可能跑，整页扫一遍会把滚动拖卡。
    AevonSub = AEVON_SUB_COLLECT;
    NSUInteger walked = AevonCollectPlayers(hint != nil ? hint : cell, players);
    if (players.count == 0) {
        // 钩子挂在「画面的直接父视图」上时，这一层可能只是个容器（类名里没有
        // Player / Video）。它本身也可能是视频区，就拿它当候选试一次 ——
        // `AevonBandUnder` 的门槛（120×200）会挡住真正的小容器。
        if (hint == nil) return;
        [players addObject:hint];
    }

    UIView *pickBand[2] = {nil, nil};
    UIView *pickRegion[2] = {nil, nil};
    CGRect pickRect[2] = {CGRectZero, CGRectZero};
    int picked = 0;

    // 两轮：先只试「不是零件」的候选；全都不行再把零件也算进来（个别 App 的播放器
    // 名字里就带 Button/Icon，宁可多试一轮也不漏）。最多认两块（画面区 + 画面本身）。
    for (int pass = 0; pass < 2 && picked < 2; pass++) {
        for (UIView *candidate in players) {
            if (picked >= 2) break;
            if (pass == 0 && AevonNotPicture(class_getName([candidate class]))) continue;
            BOOL dup = NO;
            for (int i = 0; i < picked; i++) {
                if (pickRegion[i] == candidate || pickBand[i] == candidate) dup = YES;
                // 同一棵子树上的两层只认一次：都挪就等于挪两倍。
                if (AevonVideoKin(candidate, pickRegion[i])) dup = YES;
            }
            if (dup) continue;
            // 只认「铺在这张卡上」的那块画面区：小窗、画中画、列表里的小预览一律放过，
            // 否则会把某个角落的小播放器搬到卡片正中。
            CGFloat cellW = [cell bounds].size.width;
            AevonSub = AEVON_SUB_PICK;
            CGRect cr = [candidate convertRect:[candidate bounds] toView:cell];
            if (cr.size.width < cellW * 0.8 || cr.size.height < cellH * 0.35) continue;
            AevonSub = AEVON_SUB_BAND;
            UIView *band = AevonBandUnder(candidate);
            if (band == nil) continue;
            BOOL kin = NO;
            for (int i = 0; i < picked; i++) if (AevonVideoKin(band, pickBand[i])) kin = YES;
            if (kin) continue;

            // 关键：换算到**卡片**坐标系。中间夹几层、每层原点在哪，都不再进结果。
            CGRect rb = [band convertRect:[band bounds] toView:cell];
            CGFloat bandH = [band bounds].size.height;
            CGFloat scale = bandH > 1.0 ? rb.size.height / bandH : 1.0;
            CGFloat want = (cellH - rb.size.height) / 2.0;
            CGFloat gap = want - rb.origin.y;

            // 每个候选一行：在卡片里的矩形、目标、缺口。这一版能自查，下一版换判据
            // 也靠它（0.0.85 缺的就是「原点到底在哪」这一个数）。只在心跳那一路上写：
            // 排版钩子每帧都可能跑，把读数也写进去会把日志冲掉。
            if (hint == nil && AevonVideoScanLeft > 0
                && CFAbsoluteTimeGetCurrent() - AevonVideoScanAt > 0.25) {
                AevonVideoScanLeft -= 1;
                AevonVideoScanAt = CFAbsoluteTimeGetCurrent();
                char body[220];
                snprintf(body, sizeof(body),
                         "video scan %.20s r=%.0f,%.0f,%.0fx%.0f want=%.0f gap=%.0f",
                         class_getName([candidate class]),
                         rb.origin.x, rb.origin.y, rb.size.width, rb.size.height, want, gap);
                AevonPageWrite(body);
            }
            if (rb.size.height < 80.0) continue;
            // 铺满整页（竖版）：这就是它该有的样子，居中反而会裁掉一截。
            if (rb.size.height > cellH - 40.0) continue;
            // 祖先带缩放：我们写的是画面自己的位移，会被一起放大。
            if (fabs(scale - 1.0) > 0.02) continue;
            if (fabs(gap) > 320.0) continue;

            pickBand[picked] = band;
            pickRegion[picked] = candidate;
            pickRect[picked] = rb;
            picked += 1;
        }
    }

    if (picked == 0) {
        // 钩子那一路上只扫了一层，找不到画面是正常的（画面区可能在它上层），
        // 把「没找到」写成结论会误导下一轮 —— 所以只有心跳那一份才记这一行。
        //
        // 0.0.89 — 限流按时间（每 2 s 最多一条），不再是次数。
        // Aevon(79) 里这两行写了 58 次，而当时的门是「最多 2 次」：每次心跳都
        // 走「换页清账」把计数清零，于是 45 秒写了 58 对。改按时间之后，清账
        // 清不掉时间戳，同一段空白最多留一条。`walk=` 记下这一趟走了多少个视图
        // —— 下一份日志里如果它一直顶在 4000，就是预算还不够，不是判据写错。
        CFTimeInterval noneNow = CFAbsoluteTimeGetCurrent();
        if (hint == nil && noneNow - AevonVideoNoneAt > 2.0) {
            AevonVideoNoneAt = noneNow;
            UIView *first = [players objectAtIndex:0];
            char body[220];
            snprintf(body, sizeof(body),
                     "video band none cls=%.24s h=%.0f box=%.0f walk=%lu c=%04lx",
                     class_getName([first class]),
                     [first bounds].size.height,
                     [first superview] != nil ? [[first superview] bounds].size.height : 0.0,
                     (unsigned long)walked,
                     AevonPtrTag(cell));
            AevonPageWrite(body);
            AevonVideoTree(first);
        }
        return;
    }

    // 0.0.91 — 认出来就记下**路径**（不是对象），写进**这一页自己的格子**。
    // 翻页器留着两格 cell，两页各记各的，谁也不会把谁顶掉。
    AevonVideoPage *page = AevonVideoPageTake((uintptr_t)cell);
    int kept = 0;
    if (page != NULL) {
        page->count = 0;
        page->age = 0;
        memset(page->path, 0, sizeof(page->path));
        for (int i = 0; i < picked && kept < AEVON_PATH_SLOTS; i++) {
            if (!AevonVideoPathOf(cell, pickBand[i], &page->path[kept])) continue;
            kept += 1;
        }
        page->count = kept;
    }
    // 认一次一行：`d=` 是链的层数，`n=` 是记住几块。链建不起来时 `n=0`，
    // 那一页就继续走「每次重扫」的老路 —— 不会崩，只会慢。
    if (hint == nil) {
        char body[120];
        snprintf(body, sizeof(body), "video known n=%d d=%d c=%04lx",
                 kept, kept > 0 ? (int)page->path[0].depth : 0,
                 AevonPtrTag(cell));
        AevonPageWrite(body);
    }

    // 0.0.88 — 钩子只在心跳那一路装（`via == "tick"`，0.6 s 一次）。
    //
    // 0.0.87 是识别出来就当场装，包括排版钩子**自己跑的时候** —— 那是在别人
    // `layoutSubviews` 的执行途中改它的方法表。抖音一页每帧都在排版，边跑边改
    // 方法表，Aevon(78) 那次「滑着滑着卡住」正好是这个时机。
    // 现在：心跳负责装，排版那一路只读几何、只写 transform。钩子晚装 0.6 s，
    // 代价只是第一页可能跳一下，之后每一页都在同一帧里对齐。
    if (hint == nil && strcmp(via, "tick") == 0) {
        AevonHookLayout([cell class], 0);
        for (int i = 0; i < picked; i++) {
            // 0.0.92 — 画面**自己**的类不再挂（0.0.91 加的，已撤）。
            //
            // 挂它的理由是「画面层常在自己的 layoutSubviews 里定位置」，但代价是
            // 一个 Metal 渲染层每帧都会响，而它下面根本没有可找的矩形（
            // `AevonBandUnder` 在 Metal 层里恒为 nil）。Aevon(82) 的卡屏
            // （页面滑不动、点不动）与这一条新增的入口在时间上重合，先撤掉。
            // 真正需要的是「视频区那一层不再被 8 ms 门挡住」—— 那一条已经改好，
            // 一盏灯照一个房间就够。
            AevonHookLayout([[pickBand[i] superview] class], 1);
            AevonHookLayout([pickRegion[i] class], 1);
        }
    }

    for (int i = 0; i < picked; i++) {
        AevonVideoWrite(pickBand[i], cell, pickRect[i],
                        class_getName([pickRegion[i] class]), via);
    }
}

/// 心跳那一份：找「用户正看着的那一页」，交给 `AevonVideoCenterFor`。
/// `via=tick` 在这份日志里意味着**没赶上排版的时刻** —— 屏幕上会跳一下。
static void AevonVideoCenter(void) {
    AevonStep = AEVON_STEP_TICK;
    AevonVideoLaneNow = -1;
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    CGRect page = [view bounds];
    if (page.size.height < 200.0) return;
    UIView *cell = AevonPageKidAt(view, page.size.height, [view contentOffset].y);
    if (cell == nil) return;
    // 换了一页：上一页的记账（挪过几次、扫过几行）全部作废 —— 画面对象本来就是新的。
    if (AevonVideoCell != (void *)cell) {
        AevonVideoCell = (void *)cell;
        memset(AevonVideoSlots, 0, sizeof(AevonVideoSlots));
        AevonVideoScanLeft = 3;
    }
    // 0.0.91 — 年龄按页算：只用得着的那两页各自 +1，到 32 拍各自作废。
    for (int i = 0; i < AEVON_PAGE_SLOTS; i++) {
        if (AevonVideoPages[i].cell == 0) continue;
        AevonVideoPages[i].age += 1;
        if (AevonVideoPages[i].age >= 32) memset(&AevonVideoPages[i], 0, sizeof(AevonVideoPages[i]));
    }
    // 0.0.89 — 认过的页心跳也只做几何，不再整页扫一遍。
    // 画面被 App 摆回去时 `AevonVideoWrite` 会补一次（`via=tick`）；真要一直对打，
    // `bounces` 会让我们先歇一秒，而不是每拍都扫。
    if (AevonVideoKnownApply(cell, "tick")) return;
    // 0.0.93 — 记账还在、只是这一拍没对上：等下一拍，不整页重扫。
    // 与排版钩子里那条同一理由（换视频重建画面层的那几帧链会短暂指不到东西）。
    AevonVideoPage *held = AevonVideoPageFind((uintptr_t)cell);
    if (held != NULL && held->count > 0) return;
    AevonVideoCenterFor(cell, nil, "tick");
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

/// 0.0.91 — `app: alive` 已经写了几行（上限 600 ≈ 10 分钟）。
static int AevonAliveLines = 0;

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
    // 0.0.91 — 每秒一行「我还活着」。
    //
    // 0.0.90 的日志里抖音三分钟换了三个 pid，而 App 侧除了 `app: boot` 一行
    // 什么都没有 —— 死亡时刻只能靠「上一行读数」去猜。被托管期间每秒写一行，
    // 进程若是被系统 SIGKILL（内存/看门狗，这种杀法谁都拦不住、也写不下证词），
    // 这一行就会停在某一秒上，下一次 `app: boot` 就是它的死亡时刻。
    // 上限 600 行 ≈ 10 分钟，正好是一张卡的最长寿命。
    if (shrunk && (AevonWatchTicks % 7) == 0 && AevonAliveLines < 600) {
        AevonAliveLines += 1;
        char beatLine[64];
        snprintf(beatLine, sizeof(beatLine), "alive t=%d", AevonAliveLines);
        AevonPageWrite(beatLine);
    }
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
        // 0.0.88 — 锁屏回来这一下要重新开始记账。
        //
        // Aevon(78)：「开着悬浮窗锁屏，解锁之后画面不再居中，必须重开浮窗才恢复」。
        // 锁屏时 App 被挂起、图层被重建，我们写进去的 `transform` 归零；而 0.0.87
        // 的配额是**按次数**记的（这块画面最多挪 8 次），早就用完了 —— 记账不清，
        // 就再也不会写第二次。重开浮窗之所以能恢复，只是因为它把记账 memset 了。
        //
        // 现在：回到前台就当什么都没发生过（`AevonVideoForget`），并把可能已经
        // 撞到 2400 拍上限而停掉的心跳叫回来。配额也已改成按时间管（见
        // `AevonVideoSlot`），两道一起兜住「锁屏之后自己恢复」。
        if (state == 0 && AevonStateSeen != 0) {
            BOOL had = (AevonVideoCell != NULL);
            AevonVideoForget();
            AevonVideoLaneAt[0] = 0.0;
            AevonVideoLaneAt[1] = 0.0;
            AevonVideoScanNext = 0.0;
            AevonVideoPause = 0.0;
            if (AevonWatchDead) AevonPagerWatchArm();
            if (had) AevonPageWrite("video reset on foreground");
        }
        AevonStateSeen = state;
        // 0.0.69 — 不是后台也要有机会安排量尺。Aevon(59) 的抖音一次都没进过下面
        // 那一支（挂起启动后被系统直接激活），于是「视频偏上」整场没有读数。
        // `AevonGeometryChance` 一秒最多问一次、装上就不再问，热路径不受影响。
        AevonGeometryChance();
        return state;
    }
    AevonStateSeen = state;
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

// MARK: - 0.0.91 进程死亡的证词

/// 落盘用的路径，构造函数里定一次。之后崩溃时只走 open/write/close：
/// signal handler 里不能碰 NSString、stdio、malloc —— 那些正是崩溃现场最不可靠
/// 的东西，用它们写日志的结果往往是「什么都没写出来」。
static char AevonCrashPath[PATH_MAX];

static void AevonRawNote(const char *line) {
    if (AevonCrashPath[0] == '\0' || line == NULL) return;
    int fd = open(AevonCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t wrote = write(fd, line, strlen(line));
    (void)wrote;
    close(fd);
}

/// `app: crash sig=<n>` —— 段错误/abort/bus/ill/fpe 都走这里。
///
/// 写完把信号还原成默认再重新抛：这是**证词**，不是兜底。吞掉异常会让 App 带着
/// 坏状态继续跑，比死一次更糟。
///
/// 0.0.94 — 行尾加 `d=`（重入深度）。Aevon(84) 那次进程被换掉却没有 `app: crash`，
/// 两种可能各占一半：**栈溢出**（信号在已经爆掉的栈上投递，处理器跑不起来）与
/// **被系统杀掉**（SIGKILL 谁都拦不住）。装上 altstack 之后前者一定会落到这一行上，
/// `d=` 就是递归深度的实测值 —— 大数 = 又一次钩子自我递归，小数字 = 不是这条路。
static void AevonSignalNote(int sig) {
    char line[200];
    snprintf(line, sizeof(line), "%ld app: crash sig=%d step=%d sub=%d d=%d\n",
             (long)time(NULL), sig, (int)AevonStep, (int)AevonSub, AevonDepth);
    AevonRawNote(line);
    signal(sig, SIG_DFL);
    raise(sig);
}

/// `app: crash exc <名字>: <原因>` —— Objective-C 异常。
/// 这一路不在 signal 上下文里，取字符串是安全的。
static void AevonExceptionNote(NSException *e) {
    if (e == nil) return;
    char line[320];
    const char *name = [[e name] UTF8String];
    const char *why = [[e reason] UTF8String];
    snprintf(line, sizeof(line), "%ld app: crash exc %s: %s step=%d\n",
             (long)time(NULL), name != NULL ? name : "?",
             why != NULL ? why : "?", (int)AevonStep);
    AevonRawNote(line);
}

/// 0.0.94 — 栈溢出时用的备用栈。
///
/// 栈爆了之后再往那个栈上投递信号，处理器连自己的栈帧都放不下 —— 于是什么都没写，
/// 我们只看到「pid 换了、没有证词」。`SA_ONSTACK` + 一块独立的 64 KB 把这条路补上：
/// 溢出会变成一行 `app: crash sig=11 d=<爆炸前的深度>`。
static char AevonAltStack[64 * 1024];

static void AevonInstallAltStack(void) {
    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = AevonAltStack;
    ss.ss_size = sizeof(AevonAltStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
}

static void AevonInstallCrashNotes(void) {
    const char *path = AevonAppLogPath();
    if (path != NULL) snprintf(AevonCrashPath, sizeof(AevonCrashPath), "%s", path);
    NSSetUncaughtExceptionHandler(&AevonExceptionNote);
    AevonInstallAltStack();
    int sigs[5] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE};
    for (int i = 0; i < 5; i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = AevonSignalNote;
        sigemptyset(&sa.sa_mask);
        // 交付前先把处理器还原成默认：`raise` 之后仍然按系统的规矩死，
        // 不改变任何人（包括系统的崩溃报告）看到的结局。
        // 0.0.94 — `SA_ONSTACK`：只有段错误与总线错误会由「栈已经不够用」引起，
        // 其余三个照旧用主栈（用备用栈反而拿不到现场）。
        sa.sa_flags = SA_RESETHAND;
        if (sigs[i] == SIGSEGV || sigs[i] == SIGBUS) sa.sa_flags |= SA_ONSTACK;
        sigaction(sigs[i], &sa, NULL);
    }
}

// MARK: - 0.0.94 卡死（不是崩溃）的证词

/// Aevon(84) 里最难解释的一件事：App 侧日志 14 秒零输出（`alive` 每秒一行，
/// 从 t=11 直接断掉），宿主侧 `keepalive cs=2 sublayers=1` 却一切正常，随后
/// `app: boot` 换了 pid，而 `app: crash` 一条都没有。
///
/// 这不可能是「慢」：`video load`（每 0.5 s 结算一次、门槛 40 ms）全程 0 条，
/// 说明没有任何半秒被我们吃掉 40 ms 以上。只剩一种形状 —— **某一次调用没返回**。
///
/// 所以这一版加一个与主线程无关的看门狗线程：主线程每 0.25 s 给 `AevonMainBeat`
/// 加一；看门狗每 0.5 s 看一次，连续 4 次没变（2 s）就把「停在哪一句 + 主线程 PC +
/// 调用栈」写下来。写的时候主线程不用做任何事 —— 这正是 Aevon(84) 缺的那一块：
/// 主线程不吭声的时候，谁能替它说话。
static mach_port_t AevonMainMach = MACH_PORT_NULL;
static void *AevonImageBase = NULL;
static volatile sig_atomic_t AevonMainSeen = -1;
static int AevonHangLines = 0;
static int AevonHangStale = 0;

/// 主线程的活口链。用 `dispatch_after_f`（不是 block）：这个文件在 Theos 下
/// 没有开 -fblocks，而且这一条链要从构造函数起一直挂着，越简单越好。
static void AevonMainBeatTick(void *context) {
    (void)context;
    AevonMainBeat += 1;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonMainBeatTick);
}

/// 主线程的 PC 与前几层返回地址。
///
/// 只做两件事：`thread_get_state` 读一份寄存器快照，然后顺着帧指针往上走 9 层，
/// 每层用 `vm_read_overwrite` 读（读不到就停，不 cast、不解引用）。
/// 拿到的是裸地址，所以构造时把本 dylib 的基址也写一行 `app: base=` ——
/// 落到 `[base, base+size)` 里的帧就是**我们自己**的代码，其余是抖音/UIKit。
static void AevonHangStack(void) {
    if (AevonMainMach == MACH_PORT_NULL) return;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(AevonMainMach, ARM_THREAD_STATE64,
                         (thread_state_t)&st, &cnt) != KERN_SUCCESS) return;
    unsigned long pc = (unsigned long)__darwin_arm_thread_state64_get_pc(st);
    uint64_t fp = __darwin_arm_thread_state64_get_fp(st);
    char line[420];
    int n = snprintf(line, sizeof(line), "%ld app: hang pc=%lx",
                     (long)time(NULL), pc);
    for (int i = 0; i < 9 && fp != 0; i++) {
        if (n < 0 || n > (int)sizeof(line) - 24) break;
        uint64_t rec[2] = {0, 0};
        vm_size_t got = 0;
        kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
                                             sizeof(rec), (vm_address_t)rec, &got);
        if (kr != KERN_SUCCESS || got != sizeof(rec) || rec[1] == 0) break;
        n += snprintf(line + n, sizeof(line) - n, " %lx", (unsigned long)rec[1]);
        // 栈只会朝高地址走。不涨就是走到了别的帧（或者内存已经变了），停。
        if (rec[0] <= fp) break;
        fp = rec[0];
    }
    if (n > 0 && n < (int)sizeof(line) - 2) snprintf(line + n, sizeof(line) - n, "\n");
    AevonRawNote(line);
}

static void AevonHangWatchFire(void) {
    int beat = (int)AevonMainBeat;
    if (beat != (int)AevonMainSeen) {
        // 主线程在动：这个窗口是健康的，计数从头再来。
        AevonMainSeen = beat;
        AevonHangStale = 0;
        AevonDepthMax = 0;
        AevonHookCalls = 0;
        return;
    }
    AevonHangStale += 1;
    if (AevonHangStale < 4) return;       // 4 × 0.5 s 不动才算卡住
    if (AevonHangLines >= 8) return;      // 一张卡最多留 8 行，够看趋势，不够撑满日志
    AevonHangLines += 1;
    char line[240];
    snprintf(line, sizeof(line),
             "%ld app: hang step=%d sub=%d d=%d hook=%d c=%04lx b=%04lx\n",
             (long)time(NULL), (int)AevonStep, (int)AevonSub, (int)AevonDepthMax,
             (int)AevonHookCalls, (unsigned long)(AevonHangCell & 0xffffUL),
             (unsigned long)(AevonHangBand & 0xffffUL));
    AevonRawNote(line);
    AevonHangStack();
    // 这一段 2 秒已经结算：下一行数的是新的 2 秒。
    AevonHangStale = 0;
}

static void *AevonHangWatchLoop(void *arg) {
    (void)arg;
    for (;;) {
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 500 * 1000 * 1000;
        nanosleep(&ts, NULL);
        AevonHangWatchFire();
    }
    return NULL;
}

static void AevonInstallHangWatch(void) {
    // 构造函数跑在主线程上，所以这里拿到的就是这个进程的主线程。
    AevonMainMach = pthread_mach_thread_np(pthread_self());
    Dl_info info;
    if (dladdr((void *)&AevonInstallHangWatch, &info) != 0) AevonImageBase = info.dli_fbase;
    if (AevonImageBase != NULL) {
        char line[120];
        snprintf(line, sizeof(line), "%ld app: base=%lx\n",
                 (long)time(NULL), (unsigned long)AevonImageBase);
        AevonRawNote(line);
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t th;
    if (pthread_create(&th, &attr, AevonHangWatchLoop, NULL) == 0) {
        //  watchdog 起得来才有读数；起不来就在主线程上跑同一条链（会被卡死一起带走，
        //  但至少不会假装自己在工作）。
    }
    pthread_attr_destroy(&attr);
}


/// 0.0.90 — 每个进程一行证词。
///
/// Aevon(80) 两次「只剩白色光晕」只能靠 `geom early/late` 出现两对来反推
/// 「换了进程」，而 `geom` 要等开卡之后才有。这一行写在构造函数第一句，
/// 一个进程一行 —— 下一份日志数一下 `app: boot` 有几行，就知道这中间死过几次。
static void AevonBootNote(void) {
    time_t now = time(NULL);
    struct tm stamp;
    localtime_r(&now, &stamp);
    char line[160];
    snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d app: boot pid=%d\n",
             stamp.tm_year + 1900, stamp.tm_mon + 1, stamp.tm_mday,
             stamp.tm_hour, stamp.tm_min, stamp.tm_sec, (int)getpid());
    AevonAppLogWrite(line);
}

__attribute__((constructor))
static void AevonAppBoot(void) {
    // 第一个注入点已经拥有 SpringBoard 这个进程。两条 reason 都要看：一是
    // 「一个 getter 上挂两个钩子多了一个」，二是 0.0.65 证明装错进程的代价
    // 不是抖动，是整个桌面。
    if (!AevonWorthInjecting()) return;
    AevonBootNote();
    // 0.0.91 — 死亡证词。Aevon(81) 里抖音 3 分钟换了三个 pid，而日志里除了
    // `app: boot` 一行什么都没有：进程死得太快，我们连「它怎么死的」都答不出。
    AevonInstallCrashNotes();
    // 0.0.94 — Aevon(84) 换了一种死法：**不吭声 14 秒再被换掉**，既没有崩，
    // 也没有任何读数。上面那一组只会在「真的崩了」时落盘，所以再挂一条看门狗：
    // 主线程 2 秒不动就由另一条线程替它说话，写「停在哪一句 + PC + 调用栈」。
    AevonInstallHangWatch();
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 4)),
                     dispatch_get_main_queue(), NULL, AevonMainBeatTick);

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
