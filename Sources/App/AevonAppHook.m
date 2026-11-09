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
// 0.1.9 — 停靠标记的 Darwin 通知通道，见下面 `AevonMiniObserve`。
#import <CoreFoundation/CoreFoundation.h>
// 0.1.17 — 键盘租约心跳（`AevonKbObserve`）用 dispatch source，不用 NSTimer：
// 它跑在低优先级队列上，键盘没开的时候一次都不触发。
#import <dispatch/dispatch.h>
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
#define AEVON_STEP_DEFER  7   // 0.0.95 — 延后执行的那一次写入
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
// 0.2.12 — sheet 钩子的语句级位置。Aevon(179) 里微信那次崩溃只有 `step=5`（=sheet），
// 答不出「死在这一段里的哪一句」，所以这里把粒度再压一层。编号从 21 起，与上面那批
// 不重叠：`sub=1..10` 已经有明确的旧含义，混用会让旧日志的判读全错。
#define AEVON_SUB_SHEET_WIN   21   // 取 keyWindow
#define AEVON_SUB_SHEET_ROOT  22   // 取 rootViewController
#define AEVON_SUB_SHEET_CHAIN 23   // 沿 presentedViewController 链上溯
#define AEVON_SUB_SHEET_GEOM  24   // convertRect / bounds（几何读数）
#define AEVON_SUB_SHEET_WRITE 25   // setCenter 那一句（唯一改动 App 的地方）
#define AEVON_SUB_SHEET_AGAIN 26   // 60 ms 后的复看

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

// MARK: - 0.1.2 取证开关（写死在代码里，不进设置界面）

/// 0.1.2 — 这一版只取证，不救人。两个开关都**默认打开**，并且写死在代码里：
/// 多一个界面开关就多一个「这次到底跑的是哪一种」的变量，而这次要回答的问题
/// 只能用一次干净的对跑来问。
///
/// 要回答的问题（用户原话）：「是不是我们改了视频自动居中才让抖音卡死？」
/// 抖音自己的主线程卡在 QuartzCore 的同一个地址 178 秒，我们全程没写过（`w=164s`），
/// 但那只是「这一拍没写」，不等于「我们从来没碰坏它」。所以这一版做两件事：
///
///   · `AevonProbeMainOnly` = 1：钩子体**只在主线程干活**。Aevon(90) 的读数显示
///     主线程已经停了、我们的钩子还在被叫（19 次/秒）—— 说明抖音在**别的线程**上
///     调 `layoutSubviews`，而那些线程上我们会沿 superview 上溯、BFS 扫上百个视图、
///     走下标链、`convertRect:`。其它 App 都在主线程排版，所以只有抖音踩得到。
///   · `AevonProbeQuietBundles`：名单里的 App **只装钩子、数数、什么都不做**。
///     钩子照挂（这样 `off=` 读数才有来源），但扫描、认页、写入、延后写全部跳过。
///     几何一点都不碰 = 最干净的对照组。
///
/// 下一次日志里判据很硬：
///   · 还是卡 → 不是我们的几何改动（`off=`/`quiet=` 也在读数里，能证明开关真的生效了）；
///   · 不卡了 → 就是我们那条写入（或子线程上的扫描），下一步再二分是哪一个。
static const int AevonProbeMainOnly = 1;
static const char *AevonProbeQuietBundles[] = { "com.ss.iphone.ugc.Aweme", NULL };
static int AevonProbeQuiet = -1;             // -1 = 还没判 / 0 = 否 / 1 = 是
static volatile sig_atomic_t AevonProbeOffMain = 0;   // 子线程上进来的钩子次数
static volatile sig_atomic_t AevonProbeQuietN = 0;    // 被静默模式挡下的钩子次数
static int AevonProbeShownOff = 0;
static int AevonProbeShownQuiet = 0;

/// 本进程是不是「只数数、不碰几何」的那一类。
/// 只在第一次调用时读一次 bundle id：之后连字符串比较都不做。
static int AevonProbeQuietNow(void) {
    if (AevonProbeQuiet >= 0) return AevonProbeQuiet;
    AevonProbeQuiet = 0;
    NSString *b = [[NSBundle mainBundle] bundleIdentifier];
    const char *mine = b != nil ? [b UTF8String] : NULL;
    if (mine != NULL) {
        for (int i = 0; AevonProbeQuietBundles[i] != NULL; i++) {
            if (strcmp(mine, AevonProbeQuietBundles[i]) == 0) { AevonProbeQuiet = 1; break; }
        }
    }
    return AevonProbeQuiet;
}

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

/// 0.0.96 — 翻页器里「离视口最近的那几页」，当前页永远排第一。
///
/// 预居中要用：下一页得在它还停在视口外的时候就把画面摆正 —— 用户滑出来时
/// 第一帧就是居中的。不做这一步，那一页只能等 0.57 s 那一拍心跳，跳的过程
/// 全程可见（Aevon(83)~(85) 反复出现的「部分视频从顶部跳到中间」）。
///
/// 只收「一页大小」且离视口不超过 1.6 个页高的子视图：翻页器偶尔会留着更远的
/// 回收页，动它既没人看得见，又白扫一趟。
static int AevonPageKidsNear(UIScrollView *view, CGFloat box, CGFloat y,
                             UIView **out, int max) {
    if (view == nil || out == NULL || max <= 0) return 0;
    int n = 0;
    UIView *cur = AevonPageKidAt(view, box, y);
    if (cur != nil) out[n++] = cur;
    NSArray *kids = [view subviews];
    NSUInteger limit = kids.count < 16 ? kids.count : 16;
    for (NSUInteger i = 0; i < limit && n < max; i++) {
        UIView *kid = [kids objectAtIndex:i];
        if (kid == cur) continue;
        CGRect f = [kid frame];
        if (f.size.height < box * 0.5 || f.size.height > box * 1.5) continue;
        if (fabs(f.origin.y - y) > box * 1.6) continue;
        out[n++] = kid;
    }
    return n;
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
/// 0.1.38 — 一次只准花 30 ms，超了就永久闭嘴。
///
/// 抖音那次不是崩溃，是看门狗强杀：`0x8BADF00D scene-update watchdog …
/// exhausted real time allowance of 10.00 seconds`。`beginUpdates/endUpdates`
/// 要整张表把每一次 cell 动画与递归布局**同步**跑完才会返回，feed 那种量级的
/// 表跑过 10 秒，系统于是判定「这个 scene 十秒没更新」并杀进程。
///
/// 这条函数只是「让页高重新量一次」的辅助手段，值不上一次强杀。三道闸：
///
///   ① **事前**：手势/惯性/编辑中不发（那时布局本来就在跑，插一脚只是把同一次
///      布局拉长一倍）；表格不在窗口上不发；表长超过 12 屏不发 —— 一页高度需
///      要校正的场合都是短表，而长表正是最贵的那一类。
///   ② **事中**：记一次耗时。小表第一次跑一两毫秒，照旧用；一旦在**任何**一张
///      表上超过 30 ms，这张牌打掉，本次启动内不再赌第二次（`…Dead`）。
///   ③ **事后**：异常一律吞掉，绝不把异常带回 App 的布局链。
static int AevonTableRemeasureDead = 0;
static int AevonTableRemeasureNotes = 0;

static BOOL AevonTableRemeasure(UITableView *table) {
    if (table == nil) return NO;
    if (AevonTableRemeasureDead) return NO;
    if ([table numberOfSections] < 1) return NO;
    if ([table window] == nil) return NO;
    if ([table isTracking] || [table isDragging] || [table isDecelerating]) return NO;
    if ([table isEditing]) return NO;
    CGRect box = [table bounds];
    CGFloat span = [table contentSize].height;
    if (box.size.height > 1.0 && span > box.size.height * 12.0) {
        if (AevonTableRemeasureNotes < 3) {
            AevonTableRemeasureNotes += 1;
            char skip[160];
            snprintf(skip, sizeof(skip), "remeasure skip span=%.0f box=%.0f",
                     span, box.size.height);
            AevonPageWrite(skip);
        }
        return NO;
    }
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
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
    BOOL finished = NO;
    @try {
        [UIView performWithoutAnimation:^{
            [table endUpdates];
        }];
        finished = YES;
    } @catch (NSException *two) {
        finished = NO;
    }
    double cost = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
    if (cost > 30.0) {
        AevonTableRemeasureDead = 1;
        char slow[176];
        snprintf(slow, sizeof(slow), "remeasure slow %.0fms cls=%s gone for this boot",
                 cost, class_getName([table class]));
        AevonPageWrite(slow);
    } else if (AevonTableRemeasureNotes < 6) {
        AevonTableRemeasureNotes += 1;
        char took[160];
        snprintf(took, sizeof(took), "remeasure %.1fms cls=%s rows=%ld",
                 cost, class_getName([table class]), (long)[table numberOfRowsInSection:0]);
        AevonPageWrite(took);
    }
    return finished;
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
static void AevonSheetLiftBody(void);

/// 0.2.12 — 「这个异常是不是从我们这句里抛出来的」。
///
/// Aevon(179) 微信那两次崩溃只有 `step=5`（=这个函数），而 `step=` 只说明**最后一个
/// 写它的人是谁**，不说明异常是从谁的栈帧里抛出来的：App 自己的异步代码抛异常时，
/// 我们同样可能是最后一个写 step 的人。这一位就是用来分开这两件事的 ——
/// `app: crash exc … inSheet=1` ⇒ 异常发生在我们这次调用内部（可以 @try 兜住）；
/// `inSheet=0` ⇒ 不是我们这条栈，继续往这条线上修就是白花时间。
static volatile sig_atomic_t AevonInSheet = 0;

static void AevonSheetLift(void) {
    AevonInSheet = 1;
    AevonSheetLiftBody();
    AevonInSheet = 0;
}

/// 60 ms 后的补看。只在「第一次看见这张浮层」时排一次，不递归堆积。
static void AevonSheetLiftAgain(void) {
    AevonLiftSoon = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonLiftSoon = 0;
        AevonSheetLift();
    });
}

static void AevonSheetLiftBody(void) {
    AevonStep = AEVON_STEP_SHEET;
    AevonSub = AEVON_SUB_SHEET_WIN;
    UIWindow *win = AevonKeyWindow();
    if (win == nil) return;
    AevonSub = AEVON_SUB_SHEET_ROOT;
    UIViewController *top = [win rootViewController];
    if (top == nil) return;
    AevonSub = AEVON_SUB_SHEET_CHAIN;
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
    AevonSub = AEVON_SUB_SHEET_GEOM;
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
        AevonSub = AEVON_SUB_SHEET_WRITE;
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
    if (fresh && !AevonLiftSoon) {
        AevonSub = AEVON_SUB_SHEET_AGAIN;
        AevonSheetLiftAgain();
    }
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
    /// 0.0.96 — 预居中（`via=pre`）单独计数。
    ///
    /// 视口外那一次写入不该占掉「前两次」这个日志配额：否则预居中先占满两次，
    /// 真正被用户看见的那一次补正（`via=tick`）反而不会留下读数 —— 下一份日志
    /// 就分不清「预居中生效了」和「还是靠心跳补的」。
    int preWrites;
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

/// 0.0.96 — 预居中的两个状态。
///
/// `AevonTry*` 是「这一页上一次真扫是什么时候」：预居中会把视口上下一页也带进来，
/// 而竖版页（铺满整页、本来就不该居中）每次都空手而归。同一页 1 s 内只真扫一次，
/// 否则两页 × 每 0.57 s 一趟 BFS 就是白烧主线程 —— 0.0.93 的卡屏正是这个形状。
/// 只存尾数、只比较，绝不 cast 回对象（0.0.90 的 SIGSEGV 教训）。
#define AEVON_TRY_SLOTS 4
static uintptr_t AevonTryCell[AEVON_TRY_SLOTS];
static CFTimeInterval AevonTryAt[AEVON_TRY_SLOTS];
/// 提前装钩子（0.0.96 的 B 路）每张卡只做一次；关卡时放回 0。
static int AevonPreHooked = 0;

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
    // 0.0.96 — 预居中的退避与「提前装钩子」跟随卡片生命周期：换一张卡就是新的
    // 翻页器、可能是别的 App 的类，必须重新挂一次。
    memset(AevonTryCell, 0, sizeof(AevonTryCell));
    memset(AevonTryAt, 0, sizeof(AevonTryAt));
    AevonPreHooked = 0;
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

/// 0.0.96 — 槽位从 6 提到 12。
///
/// 这一版要「提前装钩子」：卡片起来后第一拍就把翻页器里所有一页大小 cell 的类、
/// 以及它们最像画面区的那一层挂上。原先 1（页）+ 2（每个候选的类与其父类）× 2 页
/// 正好把 6 格用满，第 3 页开始就一个都装不进去 —— 那会让「提前装」变成「提前
/// 把格子占满、真需要的反而挂不上」。12 格 = 两页各 6，留得住。
#define AEVON_HOOK_SLOTS 12
static AevonLayoutHookSlot AevonLayoutHookSlots[AEVON_HOOK_SLOTS];
static int AevonLayoutHookCount = 0;
/// 0.0.97 — **每个槽位各自的调用次数**。
///
/// Aevon(86) 只告诉我们「钩子 5,500 次/秒」，没告诉我们「是哪一个类在爆」。
/// 5500 次/秒既可能是「一个类在一帧里被排 90 次」（布局不收敛），也可能是
/// 「90 个实例各排 1 次」（正常），这两种修法完全相反。槽位计数是唯一能把
/// 它们分开的读数，代价是每次钩子多一次指针比较。
static volatile int AevonHookSlotN[AEVON_HOOK_SLOTS];
/// 0.0.97 — 钩子**全段**耗时（含 bounds / PagerGet / PageCellOf / CardIsUp）。
///
/// 0.0.95 的 `video load` 只量了 `AevonVideoKnownApply` 那一段，前半段的固定
/// 开销一点没算 —— 于是「video load 一条都没有」被当成了「我们不贵」。
/// 5500 次/秒 × 哪怕 3 µs 也是 1.6% 的一秒，而这几句里有两次 `[view window]`
/// 与一次沿 superview 上溯，远不止 3 µs。
static double AevonHookSpentAll = 0.0;
static double AevonLoadAll = 0.0;
/// 0.0.97 — 最后一次真正写进 App 的时刻。卡死时 `w=` 就是「距上次写入多久」：
/// Aevon(86) 里那次是 116 秒，若下一份日志仍是几十秒以上，就再也不能说
/// 「我们的写入点着了风暴」。
static CFTimeInterval AevonLastWriteAt = 0.0;
/// 0.0.97 — App 把我们写进去的位移抹掉的累计次数。`video band` 只在写的前两次
/// 打日志，之后对打多少次都是静默的；这一行让「一直对打」第一次有读数。
static int AevonBounceN = 0;
static CFTimeInterval AevonBounceAt = 0.0;
/// 0.0.97 — 预居中每拍处理了几页、几页真的成了。Aevon(86) 说「过程更清晰了」，
/// 这一行判的是 A 路到底有没有跑、跑了几页。
static CFTimeInterval AevonPreAt = 0.0;
/// 0.0.97 — 钩子槽位表只打一次。
static int AevonHookTableDone = 0;
/// 0.0.97 — 这一轮 0.5 s 里各出口的次数：快路径 / 真扫。
static int AevonVideoFastN = 0;
static int AevonVideoScanN = 0;
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

/// 0.0.95 — 排版期**写入**的延后执行。
///
/// Aevon(85) 的看门狗把 0.0.94 那条「某一次调用没返回」换成了更硬的形状：8 条
/// `app: hang` 全是 `step=4 sub=1 d=1`（停在 App 的原实现里、不是自我递归），而
/// `hook` 从 59300 涨到 527855 —— **33,468 次排版调用/秒，连续 16 秒，主线程连
/// 一秒的 `alive` 都没跑过**。这 16 秒里 `c=6000 b=f870` 一次没变 ⇒ 我们一次都
/// 没再写：风暴不是我们刷出来的，是我们那一手 `setTransform:` 把它点着的。
///
/// 道理很朴素：App 正在算这一页的布局，我们中途把它要量的那个视图挪走，它
/// 「还得再排一次」的判据就永远成立，于是在同一个调用栈里排到 3 万次/秒。
/// 所以写入**不能发生在排版调用栈里**。现在遇到这种时候只排一个待办，等本轮
/// runloop 末尾（CA 提交前后）再执行 —— 视觉上仍是这一帧，物理上已经不在
/// App 的排版栈里，那个判据看不见我们。
///
/// 全程不存任何视图指针：待办只记「哪个标记」，执行时从当前层级里现找活着的
/// 那一格，再走已有的下标链（`AevonVideoPathResolve`）。
static volatile int AevonDeferQueued = 0;

/// 0.0.95 — 钩子频率熔断。
///
/// 上限只能是「频率」（0.0.88 的按次数配额让锁屏后永久失效）。这里每秒结算一次
/// 钩子调用数：>200 就留一行 `video hook n=/s`（风暴前的爬坡看得见），>2500 就
/// 认「已经是风暴」—— 停写、停扫、跳过整段处理 3 秒，把主线程还回去。3 秒后
/// 自动解除，不永久放弃。
static volatile int AevonHookBurst = 0;
static CFTimeInterval AevonHookBurstAt = 0.0;
static volatile int AevonHookHold = 0;
#define AEVON_HOOK_WARN   200
#define AEVON_HOOK_STORM  2500
#define AEVON_HOOK_HOLD   3.0

static void AevonVideoCenterFor(UIView *cell, UIView *hint, const char *via);
static void AevonLayoutHook(id self, SEL _cmd);
static BOOL AevonVideoKnownApply(UIView *cell, const char *via);
static void AevonVideoDeferNote(void);
static void AevonVideoDeferFlush(void);

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
    double all = AevonLoadAll;
    int fast = AevonVideoFastN;
    int scan = AevonVideoScanN;
    AevonVideoLoadAt = now;
    AevonVideoLoadN = 0;
    AevonVideoLoadSpent = 0.0;
    AevonLoadAll = 0.0;
    AevonVideoFastN = 0;
    AevonVideoScanN = 0;
    // 0.0.97 — 对打单独出声，且**不受 40 ms 门槛限制**。
    //
    // `video band` 只在写的前两次打日志；App 把位移抹掉、我们再写第 37 次的时候，
    // 日志里本来什么都没有 —— 于是「我们一直在和它对着干」这件事从来不可见。
    if (AevonBounceN > 0 && now - AevonBounceAt > 2.0) {
        AevonBounceAt = now;
        char bl[96];
        snprintf(bl, sizeof(bl), "video bounce n=%d", AevonBounceN);
        AevonPageWrite(bl);
        AevonBounceN = 0;
    }
    if (spent < 40.0 && all < 40.0) return;
    // 0.0.97 — `all` 是钩子全段（含前半段固定开销），`spent` 只是 KnownApply。
    // `fast`/`scan` 把「快路径命中」与「真扫一趟」分开：如果 all 大而 fast 占绝大多数，
    // 那就是**次数**的问题而不是**单次**的问题，修法完全不同。
    char line[192];
    snprintf(line, sizeof(line),
             "video load n=%d spent=%.0fms all=%.0fms fast=%d scan=%d",
             n, spent, all, fast, scan);
    AevonPageWrite(line);
}

/// 这个方法是不是**这个类自己**实现的。`class_getInstanceMethod` 会把父类的实现
/// 借给你，改它等于改父类（对 `layoutSubviews` 来说就是改 UIView，整台机器每一层）。
/// 判法只用 `class_addMethod`：它只查这个类自己的方法表，成功就说明「原来只有父类
/// 有」—— 那一次添加正好把继承来的实现钉在了它自己身上。
/// `video`：这个类是不是「画面那一族」。0 只有「页」会用到；1 是画面区/画面本身。
/// 钩子本身挂得很少（最多 6 个类），但 `layoutSubviews` 一秒能响上千次，
/// 所以每响一次的第一件事就是查这个标记 —— 不是画面那一族、也不是页，立刻返回。
static int AevonHookLayout(Class cls, int video) {
    if (cls == Nil || cls == [UIView class] || cls == [NSObject class]) return 0;
    for (int i = 0; i < AevonLayoutHookCount; i++) {
        if (AevonLayoutHookSlots[i].cls == cls) {
            if (video) AevonLayoutHookSlots[i].video = 1;
            return 0;
        }
    }
    if (AevonLayoutHookCount >= AEVON_HOOK_SLOTS) return 0;
    SEL sel = sel_registerName("layoutSubviews");
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return 0;
    const char *types = method_getTypeEncoding(m);
    if (types == NULL) return 0;
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
        if (real == NULL || real == (IMP)AevonLayoutHook) return 0;
        inherited = real;
    }
    if (inherited == NULL) return 0;
    if (class_addMethod(cls, sel, inherited, types)) {
        // 类自己没有实现：刚钉上去的那一条就是「原实现」。
        m = class_getInstanceMethod(cls, sel);
        if (m == NULL) return 0;
    }
    AevonLayoutHookSlots[AevonLayoutHookCount].cls = cls;
    AevonLayoutHookSlots[AevonLayoutHookCount].orig = method_getImplementation(m);
    AevonLayoutHookSlots[AevonLayoutHookCount].video = video ? 1 : 0;
    AevonLayoutHookCount += 1;
    method_setImplementation(m, (IMP)AevonLayoutHook);
    return 1;
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
    // 0.1.2 — **主线程门**。Aevon(90)：主线程已经停了（`alive` 不再出现），我们的
    // 钩子却还在被叫（15 秒里 290 次）—— 那些调用只能来自别的线程。抖音有几层是
    // 自己的渲染容器，会在子线程上排版；而下面这一整段（上溯 superview、BFS 扫视图、
    // 走下标链、`convertRect:`）全是 UIKit 的读，UIKit 的视图树不是线程安全的。
    // 主线程正在 `CA::Transaction::commit` 里的时候，子线程去摸同一棵树，是我方唯一
    // 一条能碰到抖音图层树的路径。这一句把它整条切掉：子线程上只调原实现。
    //
    // 代价为零：钩子里真正的写入（`AevonVideoWrite`）从 0.0.92 起就只认主线程，
    // 而主线程上的 `via=layout` 本来也只占少数（日志里绝大多数是 `via=tick`）。
    if (![NSThread isMainThread]) {
        AevonProbeOffMain += 1;
        if (AevonProbeMainOnly) return;
    }
    // 0.1.2 — 静默对照组：名单里的 App 只数数，不认页、不扫、不写。
    if (AevonProbeQuietNow()) {
        AevonProbeQuietN += 1;
        return;
    }
    if (AevonVideoBusy) return;
    // 0.0.95 — 熔断窗口内什么都不做（原实现照跑，App 的排版不受影响）。
    if (AevonHookHold) return;
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
    if (known) {
        AevonVideoFastN += 1;
        return;
    }
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
    AevonVideoScanN += 1;
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
/// 0.0.95 — 钩子频率熔断（每秒结算一次，只有热的时候才取时间）。
///
/// Aevon(85) 里 `hook` 从 59300 涨到 527855 = 33,468 次/秒，而这一版之前没有任何
/// 常态读数能看出「一次滑动到底多少次」—— 于是「正常」是多少谁也不知道。现在
/// >200 次/秒就留一行，风暴前的爬坡会在下一份日志里第一次显形。
static void AevonHookGuard(void) {
    AevonHookBurst += 1;
    if (((int)AevonHookBurst & 127) != 0) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    double win = now - AevonHookBurstAt;
    if (win < 1.0) return;
    int n = (int)((double)AevonHookBurst / win);
    AevonHookBurst = 0;
    AevonHookBurstAt = now;
    if (n < AEVON_HOOK_WARN) return;
    // 0.0.97 — 槽位表只打一次，与 `top=` 配对就能把「哪个类」对上号。
    if (!AevonHookTableDone) {
        AevonHookTableDone = 1;
        for (int i = 0; i < AevonLayoutHookCount; i++) {
            char tbl[128];
            snprintf(tbl, sizeof(tbl), "video hook slot i=%d v=%d %.28s",
                     i, AevonLayoutHookSlots[i].video,
                     class_getName(AevonLayoutHookSlots[i].cls));
            AevonPageWrite(tbl);
        }
    }
    int topI = -1;
    int topN = 0;
    for (int i = 0; i < AevonLayoutHookCount && i < AEVON_HOOK_SLOTS; i++) {
        if (AevonHookSlotN[i] > topN) { topN = AevonHookSlotN[i]; topI = i; }
    }
    char line[128];
    snprintf(line, sizeof(line), "video hook n=%d/s top=%d:%d", n, topI, topN);
    AevonPageWrite(line);
    if (n < AEVON_HOOK_STORM) return;
    // 已经是风暴：停写、停扫、跳过整段处理 3 秒。这个上限只按**频率**，
    // 3 秒后自动解除 —— 不做终身配额（0.0.88 那次锁屏后永久失效的教训）。
    AevonHookHold = 1;
    AevonVideoPause = now + AEVON_HOOK_HOLD;
    AevonDeferQueued = 0;
    snprintf(line, sizeof(line), "video storm n=%d/s hold=3s", n);
    AevonPageWrite(line);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(AEVON_HOOK_HOLD * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonHookHold = 0;
        AevonHookBurst = 0;
        AevonHookBurstAt = CFAbsoluteTimeGetCurrent();
    });
}

/// 0.0.97 — 这个对象属于哪一个槽位（-1 = 不在表里）。
static int AevonHookSlotOf(Class cls) {
    for (int i = 0; i < AevonLayoutHookCount; i++) {
        if (AevonLayoutHookSlots[i].cls == cls) return i;
    }
    return -1;
}

static void AevonLayoutHook(id self, SEL _cmd) {
    AevonDepth += 1;
    AevonHookCalls += 1;
    // 0.0.97 — 「爆的是哪一个槽位」：一次指针比较，换掉「5,500 次/秒但不知道
    // 是谁」的空白。
    int slot = AevonHookSlotOf(object_getClass(self));
    if (slot >= 0) AevonHookSlotN[slot] += 1;
    if ((int)AevonDepthMax < AevonDepth) AevonDepthMax = AevonDepth;
    AevonHookGuard();
    // 0.0.97 — 全段计时。旧读数只量了 `AevonVideoKnownApply`，前半段的
    // `[view window]` 与 superview 上溯从来没被算进过任何一行。
    CFTimeInterval hookBegan = CFAbsoluteTimeGetCurrent();
    AevonLayoutHookBody(self, _cmd);
    double hookCost = CFAbsoluteTimeGetCurrent() - hookBegan;
    AevonHookSpentAll += hookCost;
    AevonLoadAll += hookCost;
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
    // 0.0.95 — **排版调用栈里一律不写**，改成排一个待办。
    //
    // `AevonDepth > 0` 就是我们正站在某个被钩的 `layoutSubviews` 里（`AevonLayoutHook`
    // 进出各加一）。在这儿改 App 的几何 = 在它量这一页的中途把东西挪走，它「还得
    // 再排一次」的判据永远成立 —— Aevon(85) 的 33,468 次/秒就是这么来的。
    if (AevonDepth > 0) {
        AevonVideoDeferNote();
        return;
    }
    // 熔断窗口内不写（风暴之后自动恢复）。
    if (AevonHookHold) return;
    if (CFAbsoluteTimeGetCurrent() < AevonVideoPause) return;
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
    if (slot->wrote && fabs(t.ty - slot->wroteTy) > 1.0) {
        slot->bounces += 1;
        AevonBounceN += 1;
    }
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
    BOOL pre = (strcmp(via, "pre") == 0);
    if (pre) slot->preWrites += 1;
    else slot->writes += 1;
    slot->wroteTy = t.ty + gap;
    slot->wroteAt = now;
    // 0.0.94 — 这三句是整份日志里唯一会改 App 视图几何的调用。Aevon(84) 里唯一一次
    // `via=layout` 恰好就是死前最后一条读数，所以把「正在改哪一格、哪一块、改到哪
    // 一步」留在全局里，主线程不回来时看门狗能替它念出来。
    AevonHangCell = (uintptr_t)cell;
    AevonHangBand = (uintptr_t)band;
    AevonLastWriteAt = now;
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
    if (slot->writes <= 2 || (pre && slot->preWrites <= 2)) {
        int shown = pre ? slot->preWrites : slot->writes;
        char body[380];
        // 0.0.94 — 加 `ln=`（车道）与 `dr=`（写入那一刻翻页器是否在拖/惯性滑动）。
        // Aevon(84) 的致命写入只有 `via=layout` 一个线索，分不清是「整页那一层」
        // 还是「视频区那一层」，也分不清当时在不在滑动 —— 这两个数就是下一版的判据。
        UIScrollView *pager = AevonPagerGet();
        int drag = (pager != nil && ([pager isDragging] || [pager isDecelerating])) ? 1 : 0;
        snprintf(body, sizeof(body),
                 "video band v=%.24s h=%.0f y=%.0f want=%.0f dy=%.0f n=%d r=%.24s via=%.8s c=%04lx b=%04lx ty=%.0f ln=%d dr=%d",
                 class_getName([band class]), rb.size.height, rb.origin.y,
                 want, gap, shown, rname != NULL ? rname : "?", via,
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

/// 0.0.95 — 从**当前层级**里找出指针尾数匹配的那一格；找不到返回 nil。
///
/// 只把「刚从 `subviews` 里取出来的对象」交出去，绝不去 cast 我们自己存下来的地址 ——
/// 0.0.90 的 SIGSEGV 就是把缓存的裸指针 cast 回对象发消息。
static UIView *AevonLiveCellWithTag(UIScrollView *view, uintptr_t tag) {
    if (view == nil || tag == 0) return nil;
    NSArray *kids = [view subviews];
    NSUInteger limit = kids.count < 16 ? kids.count : 16;
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *kid = [kids objectAtIndex:i];
        if ((uintptr_t)kid == tag) return kid;
    }
    return nil;
}

/// 0.0.95 — 「刚才那次写入被压到本轮末尾」。
static void AevonVideoDeferNote(void) {
    if (AevonDeferQueued) return;
    AevonDeferQueued = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        AevonVideoDeferFlush();
    });
}

/// 0.0.95 — 本轮 runloop 末尾补上排版期被压下来的写入。
///
/// 只对「记账还在、且那一格现在仍然活着」的页做：格子是从当前层级里现找的，
/// 找得到就顺着下标链取画面（微秒级），找不到就跳过。所以压下来这件事本身
/// 不会制造任何新的失效路径。
static void AevonVideoDeferFlush(void) {
    AevonDeferQueued = 0;
    if (![NSThread isMainThread]) return;
    if (AevonHookHold) return;
    if (!AevonAppHookAllowed()) return;
    if (!AevonCardIsUp()) return;
    AevonStep = AEVON_STEP_DEFER;
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    for (int i = 0; i < AEVON_PAGE_SLOTS; i++) {
        if (AevonVideoPages[i].cell == 0 || AevonVideoPages[i].count <= 0) continue;
        UIView *cell = AevonLiveCellWithTag(view, AevonVideoPages[i].cell);
        if (cell == nil) continue;
        AevonVideoKnownApply(cell, "defer");
    }
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

    // 0.0.88 — 钩子只在**心跳那一路**装，绝不在排版调用栈里装。
    //
    // 0.0.87 是识别出来就当场装，包括排版钩子**自己跑的时候** —— 那是在别人
    // `layoutSubviews` 的执行途中改它的方法表。抖音一页每帧都在排版，边跑边改
    // 方法表，Aevon(78) 那次「滑着滑着卡住」正好是这个时机。
    // 现在：心跳负责装，排版那一路只读几何、只写 transform。
    //
    // 0.0.96 — 条件从 `via == "tick"` 放宽到「只要不是排版路」：预居中给相邻页
    // 识别时走的是 `via == "pre"`，那一页同样需要钩子，否则它滑进视口之后
    // 还是要等下一拍心跳。`hint == nil` 已经保证这里不是排版栈里的那一趟。
    if (hint == nil) {
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

/// 0.0.96 — 「这一页这一次要不要真扫一趟」。
///
/// 预居中把视口上下一页也带进来了，而竖版页（铺满整页、本来就不该居中）每次都
/// 空手而归。同一页 1 s 内只真扫一次：认出来之后走的是快路径（顺下标链取画面，
/// 微秒级），根本不进这道闸。
static BOOL AevonTryAllowed(uintptr_t cell, CFTimeInterval now) {
    if (cell == 0) return NO;
    int freeSlot = -1;
    int oldest = 0;
    for (int i = 0; i < AEVON_TRY_SLOTS; i++) {
        if (AevonTryCell[i] == cell) {
            if (now - AevonTryAt[i] < 1.0) return NO;
            AevonTryAt[i] = now;
            return YES;
        }
        if (AevonTryCell[i] == 0 && freeSlot < 0) freeSlot = i;
        if (AevonTryAt[i] < AevonTryAt[oldest]) oldest = i;
    }
    int slot = freeSlot >= 0 ? freeSlot : oldest;
    AevonTryCell[slot] = cell;
    AevonTryAt[slot] = now;
    return YES;
}

/// 0.0.96 — 一页的补正：记账在就走快路径，没记账才真扫一趟。
///
/// 当前页与相邻页走的是同一条，区别只在「谁先」和日志里的 `via`：
/// `tick` = 用户正在看的这一页（写进去就会被看见），`pre` = 视口外的相邻页
/// （写进去时没人看得见）。这样下一份日志能一眼分出「预居中生效」和
/// 「还是靠心跳补正」—— 不用再靠猜。
static BOOL AevonVideoCenterOne(UIView *cell, const char *via) {
    if (cell == nil) return NO;
    if ([cell bounds].size.height < 200.0) return NO;
    // 0.0.89 — 认过的页只做几何，不再整页扫一遍。画面被 App 摆回去时
    // `AevonVideoWrite` 会补一次（`via=tick`）；真要一直对打，`bounces` 会让我们
    // 先歇一秒，而不是每拍都扫。
    if (AevonVideoKnownApply(cell, via)) return YES;
    // 0.0.93 — 记账还在、只是这一拍没对上：等下一拍，不整页重扫。
    AevonVideoPage *held = AevonVideoPageFind((uintptr_t)cell);
    if (held != NULL && held->count > 0) return NO;
    if (!AevonTryAllowed((uintptr_t)cell, CFAbsoluteTimeGetCurrent())) return NO;
    AevonVideoCenterFor(cell, nil, via);
    // 0.0.97 — 扫完到底有没有认出来，返给心跳去记 `ok=`。
    AevonVideoPage *fresh = AevonVideoPageFind((uintptr_t)cell);
    return (fresh != NULL && fresh->count > 0);
}

/// 0.0.96 — **B 路**：提前装钩子。卡片起来后的第一拍，把翻页器里每一页的类先挂上。
///
/// 原先钩子是「心跳认出画面之后」才装（`hint == nil && via == "tick"` 那一段），
/// 于是每一种新的画面区类，它的**第一页**只能靠心跳补 —— 那一跳就是用户看到的
/// 「从顶部跳到中间」。这里不等识别，只看尺寸：
///   · 一页大小的 cell 类 → 挂「页」钩子（整页排版时认出这一页）；
///   · 每页里最像横版画面区的那一层（宽 ≥ 0.8 页宽、高 80~页高−40、且下面真有
///     画面层）连同它的父类 → 挂「画面」钩子（视频区自己排版时同帧居中）。
///
/// 只装类、一次都不写 —— 写还是由钩子里的 defer 在同一帧完成。每页只挑一层：
/// 多挂一层就多一条每帧入口，0.0.91 的卡屏正是「多挂了一层」换来的。
static void AevonHookPageClasses(UIScrollView *view, CGFloat box, CGFloat y) {
    if (AevonPreHooked) return;
    UIView *near[3] = {nil, nil, nil};
    int n = AevonPageKidsNear(view, box, y, near, 3);
    // 翻页器还没建出页来（刚开卡的那一瞬）：这一拍什么都不做，留到下一拍 ——
    // 提前置位会让它「一次没赶上就永久错过」。
    if (n <= 0) return;
    AevonPreHooked = 1;
    int added = 0;
    for (int i = 0; i < n; i++) {
        UIView *cell = near[i];
        if (cell == nil) continue;
        CGFloat cellW = [cell bounds].size.width;
        CGFloat cellH = [cell bounds].size.height;
        if (cellW < 80.0 || cellH < 200.0) continue;
        added += AevonHookLayout([cell class], 0);
        NSMutableArray *players = [NSMutableArray array];
        AevonCollectPlayers(cell, players);
        BOOL got = NO;
        for (UIView *c in players) {
            if (got) break;
            if (AevonNotPicture(class_getName([c class]))) continue;
            CGRect cr = [c convertRect:[c bounds] toView:cell];
            if (cr.size.width < cellW * 0.8) continue;
            if (cr.size.height < 80.0 || cr.size.height > cellH - 40.0) continue;
            // 它下面没有画面层 ⇒ 不是画面区（可能就是那个播放按钮的容器）。
            if (AevonBandUnder(c) == nil) continue;
            added += AevonHookLayout([c class], 1);
            if ([c superview] != nil) added += AevonHookLayout([[c superview] class], 1);
            got = YES;
        }
    }
    if (added > 0) {
        char body[64];
        snprintf(body, sizeof(body), "video hook pre n=%d", added);
        AevonPageWrite(body);
    }
}

/// 心跳那一份：当前页 + 视口上下各一页。
///
/// 心跳 ≈ 0.57 s 一拍（1/7 s × 4）。只处理当前页时，凡是「画面区自己不排版」或
/// 「画面层晚建」的页，就只能等这一拍 —— 用户看到的是从顶部跳到中间。
/// **A 路（0.0.96）** 把相邻页也处理：下一页在还停在视口外时就已摆正，滑出来
/// 第一帧就是居中的，补正过程没有机会被看见。
static void AevonVideoCenter(void) {
    AevonStep = AEVON_STEP_TICK;
    // 0.0.95 — 熔断的兜底解除：`dispatch_after` 那条路要等主线程空下来才会跑，
    // 而「空下来」正是我们要判的事。心跳只要还能跑，就按时间把它放掉，
    // 避免一次风暴把画面永久判死。
    if (AevonHookHold && CFAbsoluteTimeGetCurrent() >= AevonVideoPause) AevonHookHold = 0;
    AevonVideoLaneNow = -1;
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) return;
    CGRect page = [view bounds];
    if (page.size.height < 200.0) return;
    CGFloat y = [view contentOffset].y;
    UIView *cell = AevonPageKidAt(view, page.size.height, y);
    if (cell == nil) return;
    // 换了一页：上一页的记账（挪过几次、扫过几行）全部作废 —— 画面对象本来就是新的。
    if (AevonVideoCell != (void *)cell) {
        AevonVideoCell = (void *)cell;
        memset(AevonVideoSlots, 0, sizeof(AevonVideoSlots));
        AevonVideoScanLeft = 3;
    }
    // 0.0.91 — 年龄按页算：用得着的那两页各自 +1，到 32 拍各自作废。
    for (int i = 0; i < AEVON_PAGE_SLOTS; i++) {
        if (AevonVideoPages[i].cell == 0) continue;
        AevonVideoPages[i].age += 1;
        if (AevonVideoPages[i].age >= 32) memset(&AevonVideoPages[i], 0, sizeof(AevonVideoPages[i]));
    }
    // 0.0.96 — B 路：先装钩子（每张卡一次），保证「有排版就能同帧」。
    AevonHookPageClasses(view, page.size.height, y);
    // 0.0.96 — A 路：当前页 + 相邻页，当前页天然排第一。
    UIView *near[3] = {nil, nil, nil};
    int n = AevonPageKidsNear(view, page.size.height, y, near, 3);
    int okn = 0;
    for (int i = 0; i < n; i++) {
        if (near[i] == nil) break;
        if (AevonVideoCenterOne(near[i], i == 0 ? "tick" : "pre")) okn += 1;
    }
    // 0.0.97 — 「预居中到底有没有跑、跑了几页、成了几页」。
    //
    // Aevon(86) 说「心跳那个过程现在更清晰了」，而 A 路加进来就是为了让它不可见。
    // 要么预居中根本没拿到相邻页（`pages=1`），要么写进去又被 App 抹了（`ok` 有、
    // 但滑出来还是跳）。这一行是唯一能分开这两种情况的读数。
    CFTimeInterval tickNow = CFAbsoluteTimeGetCurrent();
    if (n > 0 && tickNow - AevonPreAt > 4.0) {
        AevonPreAt = tickNow;
        char body[96];
        snprintf(body, sizeof(body), "video tick pages=%d ok=%d", n, okn);
        AevonPageWrite(body);
    }
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
    //
    // 0.1.2 — **搬走了**，见 `AevonAliveTick`。心跳原先挂在这条 0.15 s 的翻页器
    // 守卫上，而那条链 2400 拍（6 分钟）之后会自己停（`AevonWatchDead`）—— 于是
    // 「卡片开了 6 分钟之后主线程卡死」在这条路上**没有任何证词**，恰好把「卡了
    // 很久才发现」的那种情况漏掉。心跳现在是一条独立链，只做一件事。
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
///
/// 0.2.12 — 补三样东西，为的是回答「微信第一次分享就闪退」：
///   ① `sub=` 与 `inSheet=`：`step=5` 只说最后一个写步骤的人是我们，`inSheet=1`
///      才说明异常发生在我们这次调用的**栈内**（那种可以 @try 兜住，也是该修的地方）；
///   ② 调用栈 14 帧：判据就是栈上有没有 `AevonApp` 这一族帧；
///   ③ 这一路原来只写一行，现在写 15 行 —— 崩溃现场只有一次，宁可多留。
static void AevonExceptionNote(NSException *e) {
    if (e == nil) return;
    char line[420];
    const char *name = [[e name] UTF8String];
    const char *why = [[e reason] UTF8String];
    snprintf(line, sizeof(line), "%ld app: crash exc %s: %s step=%d sub=%d inSheet=%d\n",
             (long)time(NULL), name != NULL ? name : "?",
             why != NULL ? why : "?", (int)AevonStep, (int)AevonSub, (int)AevonInSheet);
    AevonRawNote(line);
    @try {
        NSArray *symbols = [e callStackSymbols];
        if (![symbols isKindOfClass:[NSArray class]] || symbols.count == 0) {
            symbols = [NSThread callStackSymbols];
        }
        NSUInteger limit = [symbols count] < 14 ? [symbols count] : 14;
        for (NSUInteger i = 0; i < limit; i++) {
            id one = [symbols objectAtIndex:i];
            if (![one isKindOfClass:[NSString class]]) continue;
            const char *raw = [(NSString *)one UTF8String];
            if (raw == NULL) continue;
            char frame[300];
            snprintf(frame, sizeof(frame), "%ld app: crash at %lu %.220s\n",
                     (long)time(NULL), (unsigned long)i, raw);
            AevonRawNote(frame);
        }
    } @catch (NSException *exception) {
        AevonRawNote("app: crash stack unavailable\n");
    }
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
/// 0.1.2 — 独立心跳链（1 s 一拍）。
///
/// 与翻页器守卫完全解耦，因为它要回答的问题跟翻页器无关：「这个进程的主队列还
/// 在跑吗」。三点理由：
///   · 原链 2400 拍（6 分钟）后自停，卡片寿命却是 10 分钟 —— 后 4 分钟没有证词；
///   · 原链是 0.15 s 一拍、每 7 拍写一行，节奏受守卫自己的开销影响；
///   · 这一条不需要任何前置条件（翻页器、场景、卡片），构造函数里就能挂上。
///
/// 只在「画布比屏幕矮」（= 正被托管）时写，所以全屏运行时日志不会多一行。
/// 上限 3600 行 ≈ 1 小时，比一张卡的寿命长得多。
static void AevonAliveTick(void *context) {
    (void)context;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonAliveTick);
    CGFloat height = AevonWindowHeight();
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat full = screen != nil ? [screen bounds].size.height : 0.0;
    if (height < 200.0 || full < 200.0) return;
    if (height > full - 40.0) return;
    AevonEverHosted = 1;
    if (AevonAliveLines < 3600) {
        AevonAliveLines += 1;
        char beatLine[64];
        snprintf(beatLine, sizeof(beatLine), "alive t=%d", AevonAliveLines);
        AevonPageWrite(beatLine);
    }
    // 0.1.2 — 两个开关的读数，只在变化时出声。
    // `off=` 是「子线程上调进来的钩子次数」：非 0 就证明抖音确实在子线程排版，
    // 那么 `AevonProbeMainOnly` 就不是保险而是必需。`quiet=` 是静默模式挡下的次数，
    // 用来证明对照组真的生效了 —— 没有它，一次「不卡了」分不清是开关起作用还是
    // 那次本来就不会卡。
    int off = (int)AevonProbeOffMain;
    int quiet = (int)AevonProbeQuietN;
    if (off != AevonProbeShownOff || quiet != AevonProbeShownQuiet) {
        AevonProbeShownOff = off;
        AevonProbeShownQuiet = quiet;
        char probe[96];
        snprintf(probe, sizeof(probe), "probe offmain n=%d quiet n=%d", off, quiet);
        AevonPageWrite(probe);
    }
}

static mach_port_t AevonMainMach = MACH_PORT_NULL;
static void *AevonImageBase = NULL;
static volatile sig_atomic_t AevonMainSeen = -1;
static int AevonHangLines = 0;
static int AevonHangStale = 0;
/// 0.1.2 — 上一拍心跳的时刻。`gap=` 就是「距上一拍多少毫秒」，它与 `w=`（距上次
/// 写几何多少秒）是两个完全不同的钟：Aevon(90) 里 `w=164s` 说明我们 164 秒没写过，
/// 却没有任何读数说明「主线程自己停了多久」—— 只有 `hang` 的行数能反推。
static CFTimeInterval AevonMainBeatAt = 0.0;

/// 主线程的活口链。用 `dispatch_after_f`（不是 block）：这个文件在 Theos 下
/// 没有开 -fblocks，而且这一条链要从构造函数起一直挂着，越简单越好。
static void AevonMainBeatTick(void *context) {
    (void)context;
    AevonMainBeat += 1;
    // 0.1.2 — 记下这一拍的时刻。证词里多一个 `gap=`：上一拍到现在过了多少毫秒。
    // `w=` 是「距上次写几何」，两者一个是心跳一个是写入，不能混着读。
    AevonMainBeatAt = CFAbsoluteTimeGetCurrent();
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonMainBeatTick);
}

/// 0.1.2 — 把一个地址写成 `模块+偏移`。
///
/// Aevon(90) 的栈全是 `192f199f4` 这种裸地址，我只能按「落在哪个镜像 + 调用顺序」
/// 去推形状，推不出函数名。`模块+偏移` 至少让两次卡死能直接对比「是不是同一个
/// 点」，而且在任何一台同版本 iOS 上偏移都是稳定的 —— 裸地址不是（要减基址）。
///
/// arm64e 的代码指针带 PAC 签名，高位的签名必须抹掉再交给 `dladdr`，否则它认不出
/// 那个地址属于哪个镜像（这正是 85/86 两份日志里 `291e6…` 读不出模块的原因）。
static void AevonFmtAddr(char *buf, size_t cap, unsigned long long raw) {
    unsigned long long a = raw & 0xFFFFFFFFFULL;
    if (a == 0) { snprintf(buf, cap, "-"); return; }
    Dl_info info;
    if (dladdr((void *)(uintptr_t)a, &info) != 0 && info.dli_fname != NULL) {
        const char *slash = strrchr(info.dli_fname, '/');
        const char *base = slash != NULL ? slash + 1 : info.dli_fname;
        unsigned long long off = a - (unsigned long long)(uintptr_t)info.dli_fbase;
        snprintf(buf, cap, "%s+0x%llx", base, off);
        return;
    }
    snprintf(buf, cap, "%llx", a);
}

/// 主线程的 PC 与前几层返回地址。
///
/// 只做两件事：`thread_get_state` 读一份寄存器快照，然后顺着帧指针往上走 9 层，
/// 每层用 `vm_read_overwrite` 读（读不到就停，不 cast、不解引用）。
/// 0.1.2 — 每一帧都带模块名与偏移（`AevonFmtAddr`），不再只标最上面那一帧。
static void AevonHangStack(void) {
    if (AevonMainMach == MACH_PORT_NULL) return;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(AevonMainMach, ARM_THREAD_STATE64,
                         (thread_state_t)&st, &cnt) != KERN_SUCCESS) return;
    unsigned long pc = (unsigned long)__darwin_arm_thread_state64_get_pc(st);
    uint64_t fp = __darwin_arm_thread_state64_get_fp(st);
    char one[72];
    char line[820];
    AevonFmtAddr(one, sizeof(one), (unsigned long long)pc);
    int n = snprintf(line, sizeof(line), "%ld app: hang pc=%s",
                     (long)time(NULL), one);
    for (int i = 0; i < 9 && fp != 0; i++) {
        if (n < 0 || n > (int)sizeof(line) - 90) break;
        uint64_t rec[2] = {0, 0};
        vm_size_t got = 0;
        kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
                                             sizeof(rec), (vm_address_t)rec, &got);
        if (kr != KERN_SUCCESS || got != sizeof(rec) || rec[1] == 0) break;
        AevonFmtAddr(one, sizeof(one), (unsigned long long)rec[1]);
        n += snprintf(line + n, sizeof(line) - n, " %s", one);
        // 栈只会朝高地址走。不涨就是走到了别的帧（或者内存已经变了），停。
        if (rec[0] <= fp) break;
        fp = rec[0];
    }
    if (n > 0 && n < (int)sizeof(line) - 2) snprintf(line + n, sizeof(line) - n, "\n");
    AevonRawNote(line);
}

/// 0.1.2 — 全部线程各一行：线程号 + 它此刻停在哪个模块。
///
/// 一条主线程卡在 `CA::Transaction::commit` 的记录，只有在「另一个线程是不是也在
/// 等我们」时才有结论。Aevon(90) 里主线程的 PC 178 秒没变，而我们没有任何读数
/// 说明其它线程在干什么 —— 这条就是补它。只读寄存器，不挂起线程，代价是几十微秒。
static void AevonHangThreads(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) return;
    if (list == NULL) return;
    char line[900];
    char one[72];
    int n = snprintf(line, sizeof(line), "%ld app: hang threads=%d",
                     (long)time(NULL), (int)count);
    for (int i = 0; i < (int)count && i < 10; i++) {
        if (n < 0 || n > (int)sizeof(line) - 90) break;
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(list[i], ARM_THREAD_STATE64,
                             (thread_state_t)&st, &cnt) != KERN_SUCCESS) continue;
        unsigned long pc = (unsigned long)__darwin_arm_thread_state64_get_pc(st);
        AevonFmtAddr(one, sizeof(one), (unsigned long long)pc);
        n += snprintf(line + n, sizeof(line) - n, " t%d=%s", i, one);
    }
    if (n > 0 && n < (int)sizeof(line) - 2) snprintf(line + n, sizeof(line) - n, "\n");
    AevonRawNote(line);
    vm_deallocate(mach_task_self(), (vm_address_t)list,
                  (vm_size_t)(count * sizeof(thread_t)));
}

/// 0.0.97 — 主线程**此刻**停在哪一个模块里。
///
/// Aevon(86) 的 `app: hang pc=` 全是 `291e6…` 这种裸地址，我只知道「不是我们」
/// （我们 base 是 `0x100490000`），分不出是 UIKitCore 还是抖音自己的
/// AwemeCore —— 而这两者意味着完全相反的结论：前者是系统布局不收敛，后者是
/// 抖音自己在循环。`dladdr` 在看门狗线程（不是信号上下文）里调是安全的。
static const char *AevonHangWhere(void) {
    if (AevonMainMach == MACH_PORT_NULL) return "?";
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(AevonMainMach, ARM_THREAD_STATE64,
                         (thread_state_t)&st, &cnt) != KERN_SUCCESS) return "?";
    void *pc = (void *)__darwin_arm_thread_state64_get_pc(st);
    Dl_info info;
    if (dladdr(pc, &info) == 0 || info.dli_fname == NULL) return "?";
    const char *slash = strrchr(info.dli_fname, '/');
    return slash != NULL ? slash + 1 : info.dli_fname;
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
    // 0.1.2 — 8 → 24 行。8 行只够作证 16 秒，而 Aevon(90) 那次卡了 178 秒：写满
    // 之后同一个进程再卡，就一个字都没有了。24 行 = 48 秒，正好覆盖「判死 40 秒」
    // 那一档，也不会把日志撑满（每行 800 字节 × 24 ≈ 19 KB）。
    if (AevonHangLines >= 24) return;
    AevonHangLines += 1;
    int topI = -1;
    int topN = 0;
    for (int i = 0; i < AevonLayoutHookCount && i < AEVON_HOOK_SLOTS; i++) {
        if (AevonHookSlotN[i] > topN) { topN = AevonHookSlotN[i]; topI = i; }
    }
    double sinceWrite = AevonLastWriteAt > 0.0
                        ? (CFAbsoluteTimeGetCurrent() - AevonLastWriteAt) : -1.0;
    // 0.1.2 — 主线程的三个新读数。Aevon(90) 只有「PC 不变」这一条，而「阻塞在等锁」
    // 与「在一个循环里空转」在 PC 上长得一模一样，分不开就没法决定下一步：
    //   cpu=0 且 st=3(waiting)/4(uninterruptible) ⇒ **阻塞**（等锁、等渲染服务器）；
    //   cpu≈100 且 st=1(running)                  ⇒ **自旋**（图层树成环、死循环）。
    // gap= 是「距上一拍心跳多少毫秒」，直接量住主线程停了多久，不用再数 hang 行数
    // 反推。th=/mem= 顺手把「内存压力」和「线程爆炸」这两条旁路排掉。
    int cpu = -1, runState = -1, threads = -1;
    thread_basic_info_data_t tb;
    mach_msg_type_number_t tbc = THREAD_BASIC_INFO_COUNT;
    memset(&tb, 0, sizeof(tb));
    if (AevonMainMach != MACH_PORT_NULL &&
        thread_info(AevonMainMach, THREAD_BASIC_INFO,
                    (thread_info_t)&tb, &tbc) == KERN_SUCCESS) {
        cpu = (int)(tb.cpu_usage / 10);      // 0..1000 → 0..100
        runState = (int)tb.run_state;        // 1 running / 3 waiting / 4 uninterruptible
    }
    thread_act_array_t tlist = NULL;
    mach_msg_type_number_t tcount = 0;
    if (task_threads(mach_task_self(), &tlist, &tcount) == KERN_SUCCESS && tlist != NULL) {
        threads = (int)tcount;
        vm_deallocate(mach_task_self(), (vm_address_t)tlist,
                      (vm_size_t)(tcount * sizeof(thread_t)));
    }
    long memMB = -1;
    task_vm_info_data_t vm;
    mach_msg_type_number_t vmc = TASK_VM_INFO_COUNT;
    memset(&vm, 0, sizeof(vm));
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vmc) == KERN_SUCCESS) {
        memMB = (long)(vm.phys_footprint / (1024 * 1024));
    }
    double gapMs = AevonMainBeatAt > 0.0
                   ? (CFAbsoluteTimeGetCurrent() - AevonMainBeatAt) * 1000.0 : -1.0;
    char line[420];
    snprintf(line, sizeof(line),
             "%ld app: hang step=%d sub=%d d=%d hook=%d cost=%.0fms w=%.0fs top=%d:%d where=%.20s c=%04lx b=%04lx cpu=%d st=%d gap=%.0fms th=%d mem=%ldMB off=%d quiet=%d\n",
             (long)time(NULL), (int)AevonStep, (int)AevonSub, (int)AevonDepthMax,
             (int)AevonHookCalls, AevonHookSpentAll, sinceWrite, topI, topN,
             AevonHangWhere(),
             (unsigned long)(AevonHangCell & 0xffffUL),
             (unsigned long)(AevonHangBand & 0xffffUL),
             cpu, runState, gapMs, threads, memMB,
             AevonProbeOffMain, AevonProbeQuietN);
    AevonRawNote(line);
    AevonHangStack();
    AevonHangThreads();
    // 这一段 2 秒已经结算：下一行数的是新的 2 秒。
    AevonHangStale = 0;
    for (int i = 0; i < AEVON_HOOK_SLOTS; i++) AevonHookSlotN[i] = 0;
    AevonHookSpentAll = 0.0;
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


// MARK: - 0.1.8 停靠小窗的触摸闸门
//
// Aevon(95) 第 1 条，用户的原话：「吸附小窗快速点击时依旧会触发小窗应用内点击
// （尤其是抬手时他才会触发）」。
//
// 「抬手才触发」这句话本身就是判据。UIKit 发一次点击是在 `touchesEnded` 那一拍，
// 所以 App 收到的是**一根完整的手指**：began → moved → ended。也就是说它绕过了
// 宿主侧那条 `sendEvent` 闸门（那一侧 `mini touch down=N eaten=N` 一直是相等的，
// 它吞掉的是 SpringBoard 自己的那一份）。
//
// 三条已经试过、都不行的路，写在这里是为了下一轮不要再走：
//   · `content.isUserInteractionEnabled = false`（0.1.7）—— 承载视图不参与命中，
//     但那份投递根本不经过承载视图的 hit-test；
//   · `shield`（UIControl）—— 只存在于宿主窗口里，宿主窗口对触摸是穿透的；
//   · 几何判据 —— 停靠时 App 的 scene 一直是 430x717，只有承载视图被 transform
//     缩放，App 自己看不出「我被缩小了」。日志里 `app: geom late scene=430x717`
//     在停靠之后照样出现。
//
// 所以闸门必须装在 App 自己的进程里，而它需要知道自己此刻是不是被停靠了 ——
// 这件事只有宿主知道，通道是 App 容器里的 `tmp/aevon-mini`（宿主写、App 读，
// 与 `aevon-app.log` 相反方向，两个方向都已在真机上验证可用）。
//
// 边界：只在**停靠状态**下吞，升回主窗那一拍宿主就把标记删了，所以「升窗后触摸
// 立刻还原」不受影响。文件读不到 = 不是小窗 = 行为与旧版逐字相同。

/// 停靠标记的路径。沙盒里 `NSTemporaryDirectory()` 是唯一保证可写的位置，
/// 宿主按同一规则写（见 `AevonAppMiniFlagSet`）。
static BOOL AevonMiniFlagFile(void) {
    static char path[PATH_MAX];
    static int ready = 0;
    if (!ready) {
        ready = 1;
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length > 0) {
            snprintf(path, sizeof(path), "%s",
                     [[tmp stringByAppendingPathComponent:@"aevon-mini"]
                      fileSystemRepresentation]);
        }
    }
    if (path[0] == '\0') return NO;
    struct stat info;
    return stat(path, &info) == 0 && info.st_size > 0;
}

// MARK: - 0.1.9 Darwin 通知通道（不依赖容器）
//
// 文件通道的缺口是硬的：容器找不到就写不进去。Aevon(96) 的日志里
// `win: mini flag armed com.apple.Preferences (no container)` 出现 25 次、
// `org.coolstar.SileoStore` 24 次 —— 这两个 App 的闸门一次都没装上，用户看到的
// 就是「快速或者慢速点击停靠小窗时还是会触发应用内操作」。
//
// 通知是系统级的（`CFNotificationCenterGetDarwinNotifyCenter`），跨进程不需要任何
// 沙盒权限，容器能不能找到完全不影响。名字按 bundle 分开，两边同一个规则：
// `com.aevon.mini.on.<bundle>` / `com.aevon.mini.off.<bundle>`。
//
// **租约**：on 只在 2.5 秒内有效，宿主每秒续一次（`AevonAppMiniNotify`）。这样
// 桌面崩掉、或者 off 那条通知在通道上丢了，App 最多僵 2.5 秒就自己恢复 ——
// 而不是从此点不动（0.1.8 的文件标记就有这个风险，只是还没被踩到）。

static volatile int AevonMiniLeaseOn = 0;
static CFAbsoluteTime AevonMiniLeaseAt = 0;
static const CFAbsoluteTime AevonMiniLeaseSpan = 2.5;

static void AevonMiniLeaseOnNote(CFNotificationCenterRef __unused center,
                                 void *__unused observer,
                                 CFStringRef __unused name,
                                 const void *__unused object,
                                 CFDictionaryRef __unused userInfo) {
    AevonMiniLeaseOn = 1;
    AevonMiniLeaseAt = CFAbsoluteTimeGetCurrent();
}

static void AevonMiniLeaseOffNote(CFNotificationCenterRef __unused center,
                                  void *__unused observer,
                                  CFStringRef __unused name,
                                  const void *__unused object,
                                  CFDictionaryRef __unused userInfo) {
    AevonMiniLeaseOn = 0;
    AevonMiniLeaseAt = CFAbsoluteTimeGetCurrent();
}

/// 构造函数里调一次。注册两个观察者（on / off），名字带自己的 bundle id。
static void AevonMiniObserve(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return;
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    NSString *on = [NSString stringWithFormat:@"com.aevon.mini.on.%@", bundle];
    NSString *off = [NSString stringWithFormat:@"com.aevon.mini.off.%@", bundle];
    CFNotificationCenterAddObserver(center, NULL, AevonMiniLeaseOnNote,
                                    (__bridge CFStringRef)on, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, AevonMiniLeaseOffNote,
                                    (__bridge CFStringRef)off, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

// MARK: - 0.2.15 分享 payload 直投（宿主写文件 + Darwin 通知，这里交给自己）
//
// 分享到 QQ 一直是「先全屏、再浮窗、浮窗黑屏」。Aevon(185) 拍到的是：宿主一旦
// 把那条 open 请求交回 SpringBoard，SB 立刻把这个 App 的 scene 改成 932 全屏
// （`win: scene frame after=430x932`），卡片那边随即 `sublayers=0`。所以宿主换
// 成「自己把 URL 送到这个进程里」—— 这条路上 SB 不知道有这回事，也就没有全屏。
//
// 通道：`tmp/aevon-open.plist`（宿主写）+ `com.aevon.openurl.<bundle>`（Darwin
// 通知，跨进程不需要沙盒权限，与 `aevon-mini` 同一条路的反向），回执写在
// `tmp/aevon-open-ack`（`ok=1 via=app`）。宿主 1.25 秒收不到回执就退回老路。
//
// 交给谁（0.2.16 把顺序翻过来了）：① 先走 scene 的 `scene:openURLContexts:`
// —— QQ / 微信 / 抖音都是 scene 化的 App，系统对它们根本不调
// `application:openURL:options:`；② scene 不认才退到 AppDelegate。
// `UIOpenURLContext` 没有公开初始化器，`_URL` / `_options` 只能 KVC 现造；
// `_options` 摸不到就让它是空的，URL 这条不跟着废。scene 不认就退到 AppDelegate
// 的三条老入口（0.2.17 补的），全都不认才回 `ok=0`；宿主在 3.5 秒内重投 10 次
// （App 刚起来时 window scene 还没连上，这一拍问不出答案）。回执里带 pid / sc /
// wsc / dlg / rsp，宿主原样打进主日志 —— Aevon(188) 缺的就是这几个数。

static NSString *AevonOpenURLPath(NSString *leaf) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0 || leaf.length == 0) return nil;
    return [tmp stringByAppendingPathComponent:leaf];
}

/// 0.2.42 — `UIOpenURLContext._options` 必须是「长得像 UISceneOpenURLOptions」的对象，
/// 不能是裸字典。
///
/// 微信分享真机崩溃（0.2.39 日志，13:06:49 / 13:06:51 / 13:07:24 三次）：
/// `-[__NSDictionaryM sourceApplication]: unrecognized selector`，栈顶是
/// `AevonApp.dylib +35205 / +33604` → 微信自己的 scene 处理 → 抛
/// NSInvalidArgumentException，随后 sig=6。0.2.16 起我们把 options 字典直接塞进
/// `_options`；系统不校验，但 App 拿到 `context.options` 后按公开 API 读
/// `sourceApplication`，字典不认这一条，于是每次分享都把微信打崩。
///
/// 优先造真的 `UISceneOpenURLOptions`（公有类，没有公有构造器，只能 alloc/init +
/// KVC 写它自己的 ivar）；KVC 摸不到就退回这个替身 —— 它只实现 App 会读的几个
/// getter，形状对，调用方就不会崩。字典只留给 `application:openURL:options:`
/// 那条老入口（那里本来就该是字典）。
@interface AevonOpenURLOptions : NSObject
@property (nonatomic, copy) NSString *sourceApplication;
@property (nonatomic, copy) id annotation;
@property (nonatomic, assign) BOOL openInPlace;
@property (nonatomic, assign) BOOL universalLinksOnly;
// 0.2.50 — Safari 的 `BrowserController` 会读这一项；0.2.49 的替身只实现了前四个，
// 真机日志因此是 `ok=0 via=scene-throw`（每次点击链接都抛，重试 14 次后回落全屏）。
@property (nonatomic, assign) id eventAttribution;
@end

@implementation AevonOpenURLOptions
- (void)dealloc {
    [_sourceApplication release];
    [_annotation release];
    [super dealloc];
}
@end

/// 把「来源 + 就地打开」装进一个形状正确的 options 对象。返回 +1 引用，调用方释放。
/// `real` 带回 1 表示用的是系统类。
static id AevonOpenURLOptionsMake(NSString *source, int *real) {
    if (real != NULL) *real = 0;
    Class cls = NSClassFromString(@"UISceneOpenURLOptions");
    if (cls != Nil) {
        id box = nil;
        @try {
            box = [[cls alloc] init];
            if (source.length > 0) [box setValue:source forKey:@"sourceApplication"];
            [box setValue:[NSNumber numberWithBool:NO] forKey:@"openInPlace"];
            if (real != NULL) *real = 1;
            return box;
        } @catch (NSException *exception) {
            [box release];
        }
    }
    AevonOpenURLOptions *stub = [[AevonOpenURLOptions alloc] init];
    stub.sourceApplication = source.length > 0 ? source : nil;
    stub.openInPlace = NO;
    return stub;
}

/// 0.2.17 — 回执里带上现场：进程、scene 数、窗口场景数、delegate 类名、它认不认
/// `scene:openURLContexts:`（`rsp`）。
///
/// Aevon(188) 八次全都是 `ok=0 via=noscene`，而这一行分不清三种完全不同的处境：
/// ①这个进程一条 scene 都没有（App 还在连，或者它是老式工程）；②有 scene 但
/// delegate 不实现这条选择子；③实现了我却拿不到它。三种的修法完全不同，所以
/// 从这一版起把这四个数写进回执，宿主原样打进主日志。
static void AevonOpenURLAck(BOOL ok, const char *via, int scenes, int windowScenes,
                            const char *dlg, int rsp, int windows, int state) {
    NSString *path = AevonOpenURLPath(@"aevon-open-ack");
    if (path == nil) return;
    NSString *text = [NSString stringWithFormat:
                      @"ok=%d via=%s pid=%d sc=%d wsc=%d wins=%d state=%d dlg=%s rsp=%d\n",
                      ok ? 1 : 0, via != NULL ? via : "-", (int)getpid(),
                      scenes, windowScenes, windows, state,
                      dlg != NULL ? dlg : "-", rsp];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/// 0.2.18 — 「这个进程现在有几条窗口场景」。只在主线程调。
static int AevonOpenURLWindowScenes(void) {
    int n = 0;
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) n += 1;
    }
    return n;
}

/// 等待状态。宿主每 0.35~0.45 秒重投一次，同一条请求会被这里看见很多次，
/// 所以「已经等了多久」必须按**第一次看见**算，不能按次数算。
static CFAbsoluteTime AevonOpenURLWaitAt = 0;
static int AevonOpenURLWaitStep = 0;

static void AevonOpenURLApply(void);

/// 主线程执行：读投递文件 → 调 App 自己的 open URL 入口 → 写回执。
static void AevonOpenURLApply(void) {
    NSString *file = AevonOpenURLPath(@"aevon-open.plist");
    NSData *data = file.length > 0 ? [NSData dataWithContentsOfFile:file] : nil;
    if (data == nil) {
        AevonAppLogWrite("app: openurl no file\n");
        return;
    }
    // 0.2.18 — 有文件，但先问自己一句「我现在有界面吗」。
    //
    // Aevon(188) 里 QQ 在 207 ms 就回了 `ok=0 via=noscene`；那时它刚被我们自建
    // 的 scene 拉起来，UIKit 那边还没把 window scene 连上 —— 问它等于问一个还
    // 没长出来的对象，答案没有信息量，却会被当成「拒绝」。这里最多等 4 秒
    // （每 0.25 秒自己重看一次，期间**不消费文件、不写回执**），界面长出来
    // 再投；真的等不到才照旧往下走（那时 AppDelegate 那三条老入口还在）。
    int liveScenes = AevonOpenURLWindowScenes();
    if (liveScenes == 0) {
        if (AevonOpenURLWaitAt <= 0) AevonOpenURLWaitAt = CFAbsoluteTimeGetCurrent();
        double waited = CFAbsoluteTimeGetCurrent() - AevonOpenURLWaitAt;
        if (waited < 4.0 && AevonOpenURLWaitStep < 16) {
            AevonOpenURLWaitStep += 1;
            // 只在第 1、4、8、12、16 拍留痕：这条路每 0.25 秒跑一次，全打会淹掉日志。
            if (AevonOpenURLWaitStep == 1 || AevonOpenURLWaitStep % 4 == 0) {
                char waitLine[96];
                snprintf(waitLine, sizeof(waitLine), "app: openurl wait n=%d at=%.0fms\n",
                         AevonOpenURLWaitStep, waited * 1000.0);
                AevonAppLogWrite(waitLine);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool { AevonOpenURLApply(); }
            });
            return;
        }
    } else {
        AevonOpenURLWaitAt = 0;
        AevonOpenURLWaitStep = 0;
    }
    [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
    NSError *error = nil;
    id box = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:&error];
    NSString *raw = [box isKindOfClass:[NSDictionary class]]
        ? [box objectForKey:@"url"] : nil;
    NSDictionary *given = [box isKindOfClass:[NSDictionary class]]
        ? [box objectForKey:@"options"] : nil;
    NSString *source = [box isKindOfClass:[NSDictionary class]]
        ? [box objectForKey:@"src"] : nil;
    NSURL *url = raw.length > 0 ? [NSURL URLWithString:raw] : nil;
    if (![url isKindOfClass:[NSURL class]]) {
        AevonAppLogWrite("app: openurl bad plist\n");
        AevonOpenURLAck(NO, "parse", 0, 0, "-", 0, 0, 0);
        return;
    }

    // 系统那次真正的 openURL 交给 App 的 options 里一定有两项公共键：
    // `UIApplicationOpenURLOptionsSourceApplicationKey`（发起方）和
    // `UIApplicationOpenURLOptionsOpenInPlaceKey`。分享链路上前者是
    // `com.tencent.mqq.ShareExtension` —— Aevon(186) 里 QQ 直接回了 NO，
    // 缺这一项是最像的嫌疑；宿主已经把来源送过来了，这里补齐。
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    if ([given isKindOfClass:[NSDictionary class]]) [options addEntriesFromDictionary:given];
    NSString *sourceKey = @"UIApplicationOpenURLOptionsSourceApplicationKey";
    NSString *inPlaceKey = @"UIApplicationOpenURLOptionsOpenInPlaceKey";
    if ([options objectForKey:sourceKey] == nil && source.length > 0) {
        [options setObject:source forKey:sourceKey];
    }
    if ([options objectForKey:inPlaceKey] == nil) {
        [options setObject:[NSNumber numberWithBool:NO] forKey:inPlaceKey];
    }

    UIApplication *app = [UIApplication sharedApplication];
    const char *via = "none";
    BOOL ok = NO;

    // ① 先用 scene 的正门。QQ / 微信 / 抖音都是 scene 化的 App，系统对它们
    //    **根本不会**调 `application:openURL:options:`，只调这条 —— 顺序反过来
    //    就等于拿一条系统从不走的路去问它认不认。`UIOpenURLContext` 没有公开
    //    初始化器：KVC 摸它的 `_URL` / `_options`，摸不到就退到 ②。
    UIScene *target = nil;
    id targetDelegate = nil;
    SEL sceneSel = sel_registerName("scene:openURLContexts:");
    // 0.2.17 — 只读现场：有几个 scene、几个是 UIWindowScene、第一个窗口场景的
    // delegate 类名、它认不认这条选择子。Aevon(188) 缺的就是这四个数。
    int scenes = 0;
    int windowScenes = 0;
    int rsp = 0;
    const char *dlg = "-";
    for (UIScene *scene in app.connectedScenes) {
        scenes += 1;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        windowScenes += 1;
        id d = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("delegate"));
        if (d == nil) continue;
        if (windowScenes == 1) {
            const char *name = object_getClassName(d);
            dlg = name != NULL ? name : "-";
            rsp = [d respondsToSelector:sceneSel] ? 1 : 0;
        }
        if (![d respondsToSelector:sceneSel]) continue;
        if (target == nil) { target = scene; targetDelegate = d; }
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            target = scene;
            targetDelegate = d;
            break;
        }
    }
    Class ctxCls = NSClassFromString(@"UIOpenURLContext");
    if (targetDelegate != nil) {
        id context = nil;
        if (ctxCls == Nil) {
            via = "noctx";
        } else {
            @try {
                context = [[ctxCls alloc] init];
                // 私有 ivar 是 `_URL` / `_options`；KVC 的 key 用 `URL` 才找得到 `_URL`。
                [context setValue:url forKey:@"URL"];
            } @catch (NSException *exception) {
                [context release];
                context = nil;
            }
            if (context != nil) {
                // options 单独接：摸不到就让它空着，URL 这条不能跟着一起废。
                // 0.2.42 — 递出去的是**对象**，不是字典（微信崩溃的根因）。
                int realBox = 0;
                id box = AevonOpenURLOptionsMake(source, &realBox);
                @try {
                    [context setValue:box forKey:@"options"];
                    AevonAppLogWrite(realBox ? "app: openurl ctx opt real\n"
                                             : "app: openurl ctx opt stub\n");
                } @catch (NSException *exception) {
                    AevonAppLogWrite("app: openurl ctx opt miss\n");
                }
                [box release];
            }
            if (context == nil) {
                via = "nokvc";
            } else {
                @try {
                    NSSet *set = [NSSet setWithObject:context];
                    void (*call)(id, SEL, UIScene *, NSSet *) =
                        (void (*)(id, SEL, UIScene *, NSSet *))objc_msgSend;
                    call(targetDelegate, sceneSel, target, set);
                    ok = YES;
                    via = "scene";
                } @catch (NSException *exception) {
                    ok = NO;
                    via = "scene-throw";
                    // 0.2.50 — 之前只记了 `scene-throw`，看不出是哪个选择子。
                    // `reason` 里通常直接带着 App 读的那一项（Aevon(0.2.49) 的
                    // Safari 就缺在 options 上）。
                    NSString *line = [NSString stringWithFormat:
                                      @"app: openurl throw %@ | %@\n",
                                      exception.name != nil ? exception.name : @"-",
                                      exception.reason != nil ? exception.reason : @"-"];
                    AevonAppLogWrite(line.UTF8String);
                }
                [context release];
            }
        }
    } else {
        via = "noscene";
    }

    // ② 老式 App（没有 scene 或者 scene delegate 不认）才走 AppDelegate。
    //
    // 0.2.17 — 一条变三条。Aevon(188) 里 QQ 四次分享全是 `ok=0 via=noscene`：
    // 这个数说明 scene 这条路没走通，而 ② 只有一条入口（`openURL:options:`），
    // 它回 NO 我们就没牌了。可 QQ 这类老工程常见的实现是另外两条更老的选择子
    // （iOS 9 之前是 `openURL:sourceApplication:annotation:`，再早是
    // `handleOpenURL:`）。三条都问一遍，**第一个回 YES 的就停**，不会重复投递。
    if (!ok) {
        id delegate = app.delegate;
        SEL appSel = sel_registerName("application:openURL:options:");
        if (delegate != nil && [delegate respondsToSelector:appSel]) {
            @try {
                BOOL (*call)(id, SEL, UIApplication *, NSURL *, NSDictionary *) =
                    (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))objc_msgSend;
                ok = call(delegate, appSel, app, url, options);
                // 成功才改 via；失败时保留更具体的那个（`noscene` / `nokvc` / `noctx`
                // 比笼统的 `app` 有用得多）。
                if (ok) via = "app";
            } @catch (NSException *exception) {
                ok = NO;
                via = "app-throw";
            }
        }
    }
    if (!ok) {
        id delegate = app.delegate;
        SEL oldSel = sel_registerName("application:openURL:sourceApplication:annotation:");
        if (delegate != nil && [delegate respondsToSelector:oldSel]) {
            @try {
                BOOL (*call)(id, SEL, UIApplication *, NSURL *, NSString *, id) =
                    (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSString *, id))objc_msgSend;
                ok = call(delegate, oldSel, app, url, source, nil);
                if (ok) via = "app-src";
            } @catch (NSException *exception) {
                ok = NO;
                via = "app-src-throw";
            }
        }
    }
    if (!ok) {
        id delegate = app.delegate;
        SEL handleSel = sel_registerName("application:handleOpenURL:");
        if (delegate != nil && [delegate respondsToSelector:handleSel]) {
            @try {
                BOOL (*call)(id, SEL, UIApplication *, NSURL *) =
                    (BOOL (*)(id, SEL, UIApplication *, NSURL *))objc_msgSend;
                ok = call(delegate, handleSel, app, url);
                if (ok) via = "app-handle";
            } @catch (NSException *exception) {
                ok = NO;
                via = "app-handle-throw";
            }
        }
    }

    // 0.2.18 — 再补两个只有 App 进程自己知道的数：
    //   `wins`  = `app.windows` 有几个窗口（有窗口没 scene ⇒ 这 App 不靠 scene 接 URL）；
    //   `state` = `applicationState`（0 活跃 / 1 后台 / 2 未运行中）。
    // Aevon(188) 只有 `ok=0 via=noscene` 一个事实，bundle 名和进程都看不出来，
    // 这一版起每个答案都自带现场。
    // `UIApplication.windows` 在 iOS 15 起被标了 deprecated，而 CI 是 `-Werror`
    // ⇒ 走 KVC 摸同一个属性（运行时行为一模一样，只是不触发弃用警告）。
    int windows = -1;
    @try {
        id list = [app valueForKey:@"windows"];
        if ([list isKindOfClass:[NSArray class]]) windows = (int)[(NSArray *)list count];
    } @catch (NSException *exception) {
        windows = -1;
    }
    int state = (int)[app applicationState];
    char line[224];
    snprintf(line, sizeof(line),
             "app: openurl ok=%d via=%s u=%d opt=%d src=%d sc=%d wsc=%d wins=%d state=%d rsp=%d dlg=%s\n",
             ok ? 1 : 0, via, (int)raw.length, (int)[options count],
             source.length > 0 ? 1 : 0, scenes, windowScenes, windows, state, rsp, dlg);
    AevonAppLogWrite(line);
    // 这一条请求到此结束 ⇒ 等待状态归零，下一条分享从 0 开始算。
    AevonOpenURLWaitAt = 0;
    AevonOpenURLWaitStep = 0;
    AevonOpenURLAck(ok, via, scenes, windowScenes, dlg, rsp, windows, state);
}

static void AevonOpenURLNote(CFNotificationCenterRef __unused center,
                             void *__unused observer,
                             CFStringRef __unused name,
                             const void *__unused object,
                             CFDictionaryRef __unused userInfo) {
    // 通知回调可能落在任意线程，而 delegate 调用必须在主线程。
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            AevonOpenURLApply();
        }
    });
}

/// 构造函数里调一次。名字带自己的 bundle id，与宿主的拼接规则一致。
static void AevonOpenURLObserve(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return;
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    NSString *name = [NSString stringWithFormat:@"com.aevon.openurl.%@", bundle];
    CFNotificationCenterAddObserver(center, NULL, AevonOpenURLNote,
                                    (__bridge CFStringRef)name, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

// MARK: - 0.1.29 深浅色（桌面发，应用收）

/// 把自己所有窗口的样式重设一遍。
///
/// 只改 `overrideUserInterfaceStyle`：它是**样式**，不是几何，也不会让 App
/// 重新排一遍界面；重设之后 UIKit 会把受影响的视图重绘成新的配色。
///
/// 为什么需要别人来推一把：悬浮窗里的 App 走的是「挂起启动 + 宿主缩放摆放」，
/// 系统广播的 trait 变化到得了这个进程，但承载方式让它的窗口不再主动重读一次
/// 样式，于是画面停在启动那一刻的配色（用户原话：「悬浮窗打开的应用不会同步
/// 系统的深色和浅色切换」）。
static void AevonStyleApply(BOOL dark) {
    UIUserInterfaceStyle style = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    // 0.1.30 — `UIApplication.sharedApplication.windows` 从 iOS 15 起弃用，CI 是
    // `-Werror`，一处弃用就整包构建失败（run 42004172613）。改从已连接的场景取
    // 窗口：拿到的仍是同一批窗口，只是换成官方现行入口。
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.overrideUserInterfaceStyle != style) {
                window.overrideUserInterfaceStyle = style;
            }
        }
    }
}

static void AevonStyleNote(CFNotificationCenterRef __unused center,
                           void *__unused observer,
                           CFStringRef name,
                           const void *__unused object,
                           CFDictionaryRef __unused userInfo) {
    NSString *raw = (__bridge NSString *)name;
    AevonStyleApply([raw containsString:@".dark."]);
}

/// 构造函数里调一次，注册 dark / light 两个观察者。
///
/// 两条分开注册而不是遍历一个数组：这个文件在非 ARC 下编译，构造那一拍没有
/// autorelease pool，少造一个临时容器就少一处悬空的机会。
static void AevonStyleObserve(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return;
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    NSString *dark = [NSString stringWithFormat:@"com.aevon.style.dark.%@", bundle];
    NSString *light = [NSString stringWithFormat:@"com.aevon.style.light.%@", bundle];
    CFNotificationCenterAddObserver(center, NULL, AevonStyleNote,
                                    (__bridge CFStringRef)dark, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, AevonStyleNote,
                                    (__bridge CFStringRef)light, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

// MARK: - 0.1.17 键盘在屏（应用侧发送，桌面侧接收）
//
// 软键盘在 iOS 15+ 由前台应用这一侧承载：SpringBoard 的进程里既没有键盘窗口，
// 也收不到 `UIKeyboardWillShowNotification`。所以「键盘开着吗」这件事只能由 App
// 进程报上去，桌面那侧用**租约**判定（3 s，见 `RingHost.keyboardUp`）。
//
// 为什么不用文件：容器找不着的 App 写不进文件（0.1.9 的停靠标记踩过，25 个进程
// 一次都没装上）。Darwin 通知是系统级的，不需要任何沙盒权限。
//
// 为什么每秒续一次：键盘在屏期间每秒 post 一次 `com.aevon.kb.up`，桌面只记
// 「最后一次听到的时间」。App 被杀 / 切走 / 收起那条通知丢了，最多 3 秒触发区
// 就自己回来 —— 不会像写死的布尔那样一旦卡住就永久失灵。
//
// 为什么只看 `keyboardWillChangeFrame`：它一次覆盖弹出、换输入法（高度变化）、
// 收起（endFrame 落到屏幕之下）三种情况；`WillShow` / `WillHide` 的组合在第三方
// 键盘上会漏掉高度变化。
//
// 高度门槛 40 pt：任何真实键盘都比它高，而 `inputAccessoryView` 那种一条工具栏
// 不该被当成「键盘挡住右下角」。

static volatile int AevonKbOn = 0;
/// 0.1.68 — 「键盘现在在屏上吗」，由通知里的**原始**矩形判定。
///
/// `AevonKbOn` 由我们自己的观察者置位，比 UIKit 来问交集晚一步；键盘刚弹起那一拍
/// UIKit 就会问，所以另记一个更早的事实：收到「矩形在屏内」的通知就置 1，收到
/// hide、或矩形落到屏外、或我们自己的状态机判定收起，就清 0。
static volatile int AevonKbNoteActive = 0;
static dispatch_source_t AevonKbTimer = NULL;
/// timer 当前是不是跑着的。`dispatch_resume` / `dispatch_suspend` 必须成对，
/// 用一个显式状态记，比靠 `AevonKbOn` 猜安全。
static volatile int AevonKbTimerRunning = 0;

static void AevonKbPost(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.kb.up"), NULL, NULL, true);
}

/// 0.1.18 — 「键盘收了」单独一条通道。
///
/// 0.1.17 只发 up：桌面那一侧靠 3 秒租约自然过期才知道键盘没了，用户 Aevon(104)
/// 第 1 条的原话是「避让键盘后，键盘关闭时他也需要 1 秒左右才会出现…关键盘后立即
/// 出现」。收起是一个**离散事件**，不该靠租约去猜 —— 发一条 off，桌面立刻把触发区
/// 还回来；App 被杀、切走、通知丢了这些情况仍然由租约兜底（最多 3 秒）。
static void AevonKbPostOff(void) {
    // 0.1.68 — 我们自己的状态机判定「收了」，交集钩子也必须立刻停手，
    // 否则键盘走了它还在返回 316，App 的输入框会一直吊在半空。
    AevonKbNoteActive = 0;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.kb.off"), NULL, NULL, true);
}

/// 心跳只在键盘在屏时跑。
///
/// 不这么写的话，这个 dylib 装进 250 个进程、每个进程一个每秒唤醒的 timer ——
/// 键盘一年也用不到几次的功能，代价是全天候的电。挂起时一次都不醒。
static void AevonKbArm(BOOL on) {
    if (AevonKbTimer == NULL) return;
    if (on && !AevonKbTimerRunning) {
        AevonKbTimerRunning = 1;
        dispatch_resume(AevonKbTimer);
    } else if (!on && AevonKbTimerRunning) {
        AevonKbTimerRunning = 0;
        dispatch_suspend(AevonKbTimer);
    }
}

/// 0.1.47 — 定义在键盘段后部（要用 `AevonKbHostGate` / `AevonKbNativeBounds`）。
static void AevonKbLiftApply(BOOL on);
/// 0.1.48 — 连提三拍的那层壳（见定义处）。定义在键盘段后部。
static void AevonKbLiftRepeat(void);
/// 0.1.49 — 让位判据（读 App 自己的 `keyboardLayoutGuide`）。定义在键盘段后部。
static void AevonKbGuideNote(void);

/// 0.1.56 — 把键盘顶边交给宿主。
///
/// 这一版换了**让位方式**：不再指望 App 自己按键盘通知把内容压上去（微信/QQ
/// 连着四版都没压），改成宿主把承载场景的**高度**收到键盘顶边 —— 场景 215..616，
/// 键盘 616..932 整块落在 App 窗口外面，App 根本不需要知道键盘存在，输入框
/// 天然就在窗口底边（正是原生「键盘弹出、窗口变矮」的形状）。
///
/// 宿主算这一步只需要一个数：键盘顶边在屏幕上的 Y。App 进程这边拿得到
/// （`willChangeFrame` 的 `UIKeyboardFrameEndUserInfoKey` 就是动画结束值），
/// 写一个 6 字节的小文件过去。Darwin 通知不能带载荷，prefs 又会把整个域刷一遍
/// （触摸路径上被禁过），一个独立小文件最省。
static void AevonKbLog(const char *line);
/// 0.1.58 — 键盘视觉实体的顶边（定义在键盘段里 `AevonKbWindowScan` 之后）。
static CGFloat AevonKbVisualTop(void);
/// 0.1.84 — 同一个测量的**三态**版本。`AevonKbVisualTop` 把「窗在屏、这一拍量不到」
/// 折成「沿用上次真值」，上层就分不清「键盘还在」和「键盘走了、只是空壳还没被隐藏」
/// —— Aevon(152) 里每一次真收起都被那个假 573 判成 `settle keep`。所以收起判定
/// 改问这个函数要状态，不再靠数的大小去猜。
enum {
    AevonKbStateGone = 0,   // 窗 hidden / 透明 / 滑出屏底 / 尺寸不对 ⇒ 真的收了
    AevonKbStateShell = 1,  // 窗在屏、这一拍找不到键盘视图 ⇒ 不可测（既不算在，也不算走）
    AevonKbStateTop = 2,    // 真量到顶边
};
static CGFloat AevonKbVisualTopState(int *stateOut);
/// 0.1.59 — 场景几何（都定义在键盘段后部，这里只要前置声明）。
static CGRect AevonKbSceneRectOnScreen(void);
static CGFloat AevonKbSceneHeightNow(void);
/// 0.1.65 — 系统算出来的「键盘遮住场景多少」（`AevonKbIntersection` 的返回值，
/// 写在键盘段后部）。本机稳定 289 ⇒ 键盘顶 643，这是四个 App 唯一一致的锚点。
static CGFloat AevonKbLeadSeen;
/// 0.1.68 — 宿主把场景摆到哪了（屏幕原点 Y，本机 215）。键盘求交要用它：
/// 系统按「窗口在 0」算，我们在 215，差的就是这一个数。
/// 0.1.69 — 写点有两个：`AevonKbSample`（主线程）与 `AevonKbIntersection`
/// （UIKit 问交集的那个线程，**不一定是主线程**）。后者是给 QQ 补的：它的键盘
/// 通知不在主线程投递，`AevonKbSceneRectOnScreen` 因此恒返回 `CGRectNull`，
/// 原点一直读成 0，六个通知全部 shift=0。
static volatile CGFloat AevonKbSceneOriginCache = 0.0;
/// 两次连续一致的交集值（＝键盘结算完）。锚点只认它，不认单次读数。
static CGFloat AevonKbLeadStable;
/// 0.1.66 — 上一次真的改了 App 窗口高度的时刻。`measure=0` 的假读数只出现在
/// 这之后两秒内（见 `AevonKbIdleCheck`），空窗兜底要躲开它。
static CFAbsoluteTime AevonKbFitAt;
/// 0.1.67 — 输入框光标读数（定义在 `AevonKbGuideNote` 之后）。
static void AevonKbCaretNote(void);
static CGFloat AevonKbAnchorValue(CGFloat full);
/// 0.1.77 — 挂 `-[UILayoutGuide layoutFrame]`（定义在键盘段后部）。
static void AevonKbGuideHookInstall(void);
/// 0.1.83 — 键盘管理器自己报的那只键盘窗（定义在交集钩子之前）。换窗要用。
static id AevonKbWindowNow(id keyboardManager);
/// 0.1.78 — 安全区让位（定义在 `AevonKbExtraStore` 之后）。收起时要用，
/// 那里比定义点更靠前。
static void AevonKbSafeRestore(void);
static void AevonKbSafeApply(CGFloat cover);
/// 0.1.72 — 屏幕坐标里的键盘真实上沿（定义在键盘段后部）。
static CGFloat AevonKbTopFixed(CGFloat full);
static CGRect AevonKbNativeBounds(UIScreen *screen);
/// 0.1.57 — **三条通道一起写**，因为 0.1.56 只写了最没希望的那一条。
///
/// Aevon(129) 的证词只有一行，但足够定案：
///
///   kb: top publish ok=0 path=/var/mobile/Aevon.kb      ← 三个 App 各一次
///
/// `/var/mobile` 由 `mobile` 用户持有、`0755`，App 沙盒里没有写权限 —— 0.1.56
/// 把唯一的交货点选在了那儿，于是 `kbtop=0` 恒成立，宿主每次都退回「铺满屏底」，
/// 401 形状一次都没出现过（`win: keyboard fill on card=430x717 at 0,215 kbtop=0`
/// 连了 7 次）。用户看到的「有时在悬浮窗外、有时在内、都不显示输入框」，就是
/// 这条通道时好时坏（`fill off` 之后 `kbtop` 归零、下一拍又读到旧文件）的抖动。
///
/// 现在按可靠性从高到低写三处，宿主也按同样顺序读：
///
///   ① `NSTemporaryDirectory()/aevon-kb` —— App **自己的** data 容器 tmp，
///      沙盒里必然可写；宿主拿得到同一个目录（`AevonAppContainer`：
///      `LSApplicationProxy.dataContainerURL` 或扫 `MCMMetadataIdentifier`，
///      0.1.9 起就在给 band 容器兜底用）。
///   ② `CFPreferencesSetAppValue` 写进 **App 自己的域**（`AevonKbTop`）——
///      走 cfprefsd，App 有权写自己的域；宿主读别人域不受沙盒限制。
///      慢（几十 ms 才落盘），但绝不会失败。
///   ③ `/var/mobile/Aevon.kb` —— 保留，万一某个环境放得下；失败不再当回事。
///
/// 0.1.58 — **通道通了，但送的是错数**。Aevon(130) 里 `door=3`（tmp + prefs 都写成），
/// 可送过来的顶边是 `717 / 744 / 761 / 788`，折成键盘高只有 `215 / 188 / 171 / 144`；
/// 用户肉眼看到的键盘顶一直没动过，就是 616。
///
/// 所以「`UIKeyboardFrameEndUserInfoKey` 里那个 origin.y 就是屏幕坐标的键盘顶」这个
/// 前提也被否掉了 —— 场景被搬到 215 之后，UIKit 报的那块矩形只覆盖屏幕最底一截
/// （717..932），它回答的是「键盘超出场景的那部分」，不是键盘本身。
///
/// 于是本版改成**量**：见 `AevonKbVisualTop`。量到就用量到的，量不到才退回通知帧，
/// 并且加一条硬闸门：键盘高不足 250 pt 的值一律丢弃（717/744/761/788 全在闸门外）。
static void AevonKbTopPublish(CGFloat top) {
    CGFloat measured = AevonKbVisualTop();
    CGFloat value = measured > 200.0 ? measured : top;
    if (value < 200.0 || value > 4000.0) return;
    if (measured < 200.0) {
        // 只有通知帧可用。它在这个环境里不可信，唯一的用处是「键盘真的在屏」时
        // 给一个近似的顶边；所以加一道闸门，宁可读不到（宿主退回铺满屏底），
        // 也不能把 717 这种「只覆盖最底 215 pt」的矩形当成整只键盘。
        CGFloat fullHeight = UIScreen.mainScreen.bounds.size.height;
        if (fullHeight > 400.0 && value > fullHeight - 250.0) return;
    }
    static CGFloat last = -1.0;
    static int logged = 0;
    if (fabs(value - last) < 0.5) return;
    last = value;
    char buf[24];
    int n = snprintf(buf, sizeof(buf), "%.0f", value);
    if (n <= 0) return;
    // ① 自己容器的 tmp。`NSTemporaryDirectory()` 就是 `<容器>/tmp/`。
    int door = 0;
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) {
        NSString *path = [tmp stringByAppendingPathComponent:@"aevon-kb"];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            ssize_t ignored = write(fd, buf, (size_t)n);
            (void)ignored;
            close(fd);
            door |= 1;
        }
    }
    // ② 自己的偏好域。丢到后台队列：`CFPreferencesAppSynchronize` 要等 cfprefsd
    // 回话（几十 ms），放在 `willChangeFrame` 的主线程里就是白送一次掉帧。
    // 文件那一路是即时的，宿主先读它；这一路晚到只是兜底。
    NSString *selfID = [[NSBundle mainBundle] bundleIdentifier];
    if (selfID.length > 0) {
        NSString *payload = [[[NSString alloc] initWithBytes:buf length:(NSUInteger)n
                                                    encoding:NSUTF8StringEncoding] autorelease];
        if (payload.length > 0) {
            door |= 2;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                CFStringRef app = (__bridge CFStringRef)selfID;
                CFPreferencesSetAppValue(CFSTR("AevonKbTop"),
                                         (__bridge CFStringRef)payload, app);
                CFPreferencesAppSynchronize(app);
            });
        }
    }
    // ③ 老路。
    int fd = open("/var/mobile/Aevon.kb", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        ssize_t ignored = write(fd, buf, (size_t)n);
        (void)ignored;
        close(fd);
        door |= 4;
    }
    if (logged < 3) {
        logged += 1;
        char line[160];
        snprintf(line, sizeof(line), "kb: top publish door=%d top=%.0f measure=%d\n",
                 door, value, measured > 200.0 ? 1 : 0);
        AevonKbLog(line);
    }
}

/// 0.1.59 — App **自己的**窗口（不是键盘窗）。
///
/// 键盘窗也叫 `UIWindow`、也在同一个 scene 里，收错一个就是把键盘收短，
/// 那正是本版要避开的故障形状。所以按类排除，再按 key window 优先。
static UIWindow *AevonKbAppWindow(void) {
    if (![NSThread isMainThread]) return nil;
    Class kbClass = objc_getClass("UIRemoteKeyboardWindow");
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (kbClass != Nil && [window isKindOfClass:kbClass]) continue;
            if (window.rootViewController == nil) continue;
            if (window.isKeyWindow) return window;
            if (fallback == nil) fallback = window;
        }
    }
    return fallback;
}

/// 0.1.59 — 把 App 的窗口收到键盘上沿。
///
/// 前八版都在动**承载场景**（搬原点 / 缩高度）。Aevon(131) 证明缩场景这条路走不通：
/// 键盘挂在场景上，场景底边一抬，UIKit 就把键盘顶到场景 358−74=284（屏幕 499），
/// 而场景只画到 573 —— 只有最上面 74 pt 落在画面里，用户看到「键盘只显示工具栏」。
///
/// 于是改成：场景不动（`FloatHost.setKeyboardFill` 恒铺 430×717@215），只收
/// **App 的窗口**。窗口是 App 自己排版的根，收它 App 会按新高度重排一次（原生键盘
/// 就是这么做的），输入框落到窗口底边 = 键盘上沿；键盘在窗口外面，一个像素没动。
///
/// 闸门：只在两次采样相差 < 40 时才落（键盘动画期间每帧都在变，照落就是
/// 「一顿乱跳」）；目标必须 ≥ 240 且 ≤ 场景高 − 60。
///
/// **0.1.63 — 回到这条路，而且只回这一条。**
///
/// 0.1.62 把它整段撤了（理由写在 Aevon(133)：`kb: lead` 第二问给出 289，看起来
/// App 自己会让位）。Aevon(134) 把那个理由否掉了：23 次开键盘、`fill on` 与
/// `fill off` 全部配对、场景也确实搬到了 215（`win: frame drift … wrote=3`），
/// 但 `kb: win keep h=717` 二十三次全是 717 —— 窗口不动，App 就不重排，输入框
/// 一次都没出现。同一份日志里 QQ 的 `kb: lead` 依旧只报 101/74（它问的是
/// 「键盘遮住窗口多少」，不是「窗口该多高」），289 那个值备忘录才给。
///
/// 换句话说：0.1.62 把「App 自己会让位」当成了定论，但三个 App 里只有两个真的
/// 会；QQ 从 0.1.48 到现在一直是 101/74。而 0.1.60 靠这里收窗口 + App 重排，
/// 用户的评价是「接近完美，只是关键盘不还原」。所以本版把 0.1.60 的这一段原样
/// 还回来（含「第一次按 sceneY=0 收成 573、第二次按 215 收成 358」这两拍 ——
/// 两拍是有用的：App 重排两次，输入框才跟到键盘上沿），只把还原那头留给宿主。
/// 0.1.65 — 把「量到的键盘顶」抬到系统认可的那条线。
///
/// 两个独立来源，各答一半：
///
/// · `AevonKbVisualTop()` 在键盘窗里 BFS 找「满宽 + 底贴窗底 + 高 200..460」的
///   **最靠上**那个。它答的是「键盘这块从哪开始」，可键盘窗里存着比键盘本体更高的
///   满宽背景（键盘上方的工具条、App 输入栏的底衬），于是偏上。Aevon(136) 实测
///   三个值互不相同 —— QQ/微信 **573**、抖音 **533**、备忘录 **529**；同一台机器、
///   同一把键盘，却量出三个数，本身就说明它取到的不是同一个东西。
///
/// · `932 − AevonKbLeadSeen` 是系统自己算的交集（`_UIRemoteKeyboards` 的
///   intersection）。这个数**有两个版本**，0.1.65/0.1.66 取错了那一个：
///
///   **316**（≈willShow 那一拍）：本机 = 键盘 616..932，正好是 0.1.56 起一直
///   写在注释里的「键盘 616..932 整块落在窗口外面」。
///   **289**（≈我们收过窗口之后）：932−289=643，比真值低 27 pt。
///
/// 0.1.67 用录屏把这条线钉死了。0.1.63 那段 25 s 录屏（886×1920，932 pt ⇒
/// 比例 2.06）第 330 帧逐行取色，键盘底色 `RGB(229,227,234)` 从 **610 pt**
/// 起一路到底，670 之后才是白色键帽；610 之上是白色聊天面板。也就是说键盘
/// 上沿在 610~616，**不是 643**。
///
/// 于是三个报障全部有同一个解释：App 的输入框贴在**键盘上沿 616**，而我们把
/// 窗口底边收到了 643 —— 输入框整条落在 616..643 这 27 pt 里被键盘盖住。
///
/// · **QQ/微信「输入框不再出现」** —— 0.1.66 把窗口停在 428（底边 643），
///   616..666 那条输入栏整个在键盘下面，一个像素都看不见。
/// · **QQ「输入框显示不全」**（0.1.64）—— 那时停在 358（底边 573），同一条
///   输入栏被窗口底边裁掉，只露最上面一窄条。
/// · **抖音「输入框被抬高、大面积空白」** —— 停在 533（底边），键盘顶在 616，
///   中间 83 pt 是卡片底色；抖音还会自己再让一次位，于是空得更多。
///
/// 只在「两个来源相差 120 pt 以内」时才采用锚点：键盘还没弹完那几拍会报
/// 74 / 101（⇒ 858 / 831），差得远，一律不理，宁可维持原值。
///
/// 所以把「键盘顶在哪」和「这一拍读到多少」拆开：前者一次学到就固定（
/// `AevonKbAnchorValue`），后者只用来判「这次读到的值值不值得信」。
static CGFloat AevonKbAnchorFixed = 0.0;
static CGFloat AevonKbAnchorGuess = 0.0;

/// 键盘顶边在屏幕上的锚点。学到之前用 `整屏高 − 316` 兜底（本机 616）。
///
/// 0.1.67 — 只认 **300..340** 那一段。316 是 willShow 那一拍几何式算出来的
/// （场景高 + 键盘窗高，都不受动画影响），实测对上录屏里的 610~616；289 是
/// **我们收过窗口之后** UIKit 重新结算的值（键盘相对新窗口被裁掉一截），
/// 它比真值低 27 pt —— 0.1.65/0.1.66 就是把它当了真值，窗口收到 643，
/// 输入框整条被键盘盖住。上界放到 340 是为了将来换机型（键盘更高）时还能学。
static CGFloat AevonKbAnchorValue(CGFloat full) {
    if (AevonKbAnchorFixed > 240.0 && AevonKbAnchorFixed < full - 120.0) return AevonKbAnchorFixed;
    CGFloat lead = AevonKbLeadStable;
    if (lead >= 300.0 && lead <= 340.0) {
        CGFloat anchor = full - lead;
        if (anchor > 240.0 && anchor < full - 120.0) {
            AevonKbAnchorFixed = anchor;
            char line[160];
            snprintf(line, sizeof(line), "kb: anchor learned lead=%.0f -> %.0f\n", lead, anchor);
            AevonKbLog(line);
            return anchor;
        }
    }
    if (AevonKbAnchorGuess < 240.0) {
        AevonKbAnchorGuess = full - 316.0;
        char line[160];
        snprintf(line, sizeof(line), "kb: anchor fallback -> %.0f\n", AevonKbAnchorGuess);
        AevonKbLog(line);
    }
    return AevonKbAnchorGuess;
}

static CGFloat AevonKbTopCorrected(CGFloat measured) {
    CGFloat full = AevonKbNativeBounds(nil).size.height;
    if (full < 400.0) return measured;
    CGFloat anchor = AevonKbAnchorValue(full);
    if (anchor < 240.0 || anchor > full - 120.0) return measured;
    // 两个来源差太远 ⇒ 谁都不信，维持量到的那个（量视图在通知里全程有效，
    // 差得远只可能是键盘还没结算完，或锚点还是上一把键盘的）。
    if (measured > 200.0 && fabs(anchor - measured) > 120.0) return measured;
    static int notes = 0;
    if (notes < 10) {
        notes += 1;
        char line[180];
        snprintf(line, sizeof(line), "kb: top anchor measured=%.0f -> %.0f\n",
                 measured, anchor);
        AevonKbLog(line);
    }
    return anchor;
}

static void AevonKbFitWindow(CGFloat top) {
    if (![NSThread isMainThread]) return;
    if (AevonKbOn == 0) return;
    if (top < 240.0 || top > 4000.0) return;
    // 0.1.65 — 先抬到系统认可的那条线（见 `AevonKbTopCorrected`）：量视图偏上，
    // 偏多少取决于 App 在键盘窗里垫了多高的底衬，不能直接用。
    CGFloat raw = top;
    top = AevonKbTopCorrected(top);
    UIWindow *window = AevonKbAppWindow();
    if (window == nil) return;
    CGRect box = AevonKbSceneRectOnScreen();
    CGFloat sceneY = CGRectIsNull(box) ? 0.0 : box.origin.y;
    CGFloat sceneH = AevonKbSceneHeightNow();
    if (sceneH < 200.0) return;
    CGFloat want = top - sceneY;
    if (want < 240.0 || want > sceneH - 60.0) {
        static int rejected = 0;
        if (rejected < 3) {
            rejected += 1;
            char line[180];
            snprintf(line, sizeof(line), "kb: win fit reject want=%.0f top=%.0f sceneY=%.0f sceneH=%.0f\n",
                     want, top, sceneY, sceneH);
            AevonKbLog(line);
        }
        return;
    }
    // 0.1.68 — **不再写窗口。**
    //
    // 0.1.60~0.1.67 的全部精力都花在「把 key window 收到键盘顶边」上，结果是
    // 三件事互相打架：场景 717、窗口 401、键盘矩形按 932 给。收窗口带来的两个
    // 副作用无法消除 ——
    //   · 窗口只剩 401，场景 401..717（屏幕 616..932）没有窗口在画 ⇒ 关键盘后
    //     那一片是黑的（Aevon(138)/(139) 用户三次提到）；
    //   · 窗口底边恰好压在键盘顶边上，App 让位量变成 0，输入框贴着窗口底边，
    //     QQ 那条还比窗口低 9 pt（`kb: caret y=604..625 win=401`）⇒ 被裁。
    //
    // 调研（WWDC23《Keep up with the keyboard》+ 34306/MilkyWayReborn，iOS 17-26）
    // 给的是另一条路：**让 App 以为自己是一个普通窗口，键盘避让交给系统**。
    // 所以这里只把读数留下，窗口高度从此恒等于场景高。
    static CGFloat held = 0.0;
    if (fabs(held - want) < 1.0) return;
    held = want;
    AevonKbFitAt = CFAbsoluteTimeGetCurrent();
    char line[200];
    snprintf(line, sizeof(line),
             "kb: win hold h=%.0f top=%.0f raw=%.0f sceneY=%.0f sceneH=%.0f was=%.0f\n",
             want, top, raw, sceneY, sceneH, window.frame.size.height);
    AevonKbLog(line);
}

/// 收起时把窗口还回场景高。不判 `AevonKbOn`（调用点刚刚把它清成 0）。
static void AevonKbUnfitWindow(void) {
    if (![NSThread isMainThread]) return;
    UIWindow *window = AevonKbAppWindow();
    if (window == nil) return;
    CGFloat sceneH = AevonKbSceneHeightNow();
    if (sceneH < 200.0) return;
    CGRect frame = window.frame;
    if (fabs(frame.size.height - sceneH) < 1.0) return;
    window.frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, sceneH);
    char line[160];
    snprintf(line, sizeof(line), "kb: win unfit h=%.0f scene=%.0f\n", sceneH, sceneH);
    AevonKbLog(line);
}

/// 一次采样：发布顶边 + 稳定时收窗口。三次采样共用，见 `AevonKbEvaluate`。
static CGFloat AevonKbTopPrev = 0.0;

static void AevonKbSample(void) {
    // 0.1.68 — 场景现在摆在屏幕哪一行，写进缓存给交集钩子用（它在别的线程被问）。
    CGRect box = AevonKbSceneRectOnScreen();
    if (!CGRectIsNull(box) && box.origin.y > -1.0 && box.origin.y < 400.0) {
        AevonKbSceneOriginCache = box.origin.y;
    }
    CGFloat top = AevonKbVisualTop();
    AevonKbTopPublish(0.0);
    // 0.1.78 — 学过的 App 在这里把安全区加上。放在采样里而不是通知里：
    // 采样已经是主线程的延后拍（0.15 s 起），不在 `postNotificationName:` 的
    // 调用栈里改布局，不会再引起一轮重排通知。
    CGFloat full = AevonKbNativeBounds(nil).size.height;
    CGFloat fixedTop = AevonKbTopFixed(full);
    if (fixedTop > 200.0 && fixedTop < full - 40.0) {
        AevonKbSafeApply(full - fixedTop);
    }
    if (top > 240.0 && AevonKbTopPrev > 240.0 && fabs(top - AevonKbTopPrev) < 40.0) {
        AevonKbFitWindow(top);
    }
    AevonKbTopPrev = top;
}

/// 0.1.64 — 「收起」要等 0.30 s 再信，因为这条通知可能是我们自己惹出来的。
///
/// 起因（Aevon(135)）：每一条 `kb: win fit` 后面都紧跟一条 `kb: win unfit`，同一秒内：
///
///   kb: win fit h=358 top=573 sceneY=215 sceneH=717 was=717
///   kb: guide win=430x358 top=0 h=0 seen=761
///   kb: win unfit h=717 scene=717
///   app: keyboard gone (bridge)
///
/// 链条是全闭环的：我们把 App 的 key window 收到 358 之后，UIKit 补发一次
/// `UIKeyboardWillChangeFrame`，而它给的 `UIKeyboardFrameEndUserInfoKey` 是
/// **相对新窗口**的 —— 键盘整个落在 358 之下，于是 `frame.size.height > 40` 不成立
/// （或被判出界）⇒ `on = NO` ⇒ 翻成收起 ⇒ `AevonKbUnfitWindow` 把窗口还回 717 ⇒
/// 键盘相对 717 又「在窗口里」⇒ 又一次 up ⇒ 再 fit …… 一个 0.5 s 周期的自激环。
/// 用户看到的是「开键盘时悬浮窗大小自动跳动」、QQ 输入框被连着裁两次而显示不完整。
///
/// 0.1.60 里同一个环也在跑（那份日志同样有 fit 紧跟 unfit 的对），只是当时收起分支
/// 什么都不做（`kbFilled` 从未置真），所以看不出来；0.1.63 把还原修好之后，它才
/// 变成肉眼可见的跳动。所以这不是「还原引入的 bug」，而是还原把旧环照亮了。
///
/// 分开「真收了」与「我们在自激」只有量视图靠得住：`AevonKbVisualTop()` 在键盘窗里
/// BFS，键盘还在屏上就一定能量到（这份日志里 `kb: top publish … measure=1` 全程成立）。
/// 所以所有「收起」一律先压 0.30 s，到点再量一次：
///   · 量到键盘 ⇒ 这条通知是误报，续租、继续开着（`kb: settle keep top=`）；
///   · 量不到   ⇒ 真收了，此时才落状态、才把窗口还回去（`kb: settle gone`）。
/// 代价：真收起时卡片与触发条晚 0.30 s 回来（原来是立刻）。
///
/// 0.1.84 — 「量不到」这句话被拆成两件事（空壳 / 窗真的不在了），因为「量不到」
/// 出现的位置既有「键盘还在重排」也有「键盘已经走了」，一次单点判定分不开；
/// 现在是一个最多九拍的轮询，见 `AevonKbSettleWait`。
static int AevonKbSettleSeq = 0;

/// 任何一次「起来」都作废待定的收起。
static void AevonKbSettleCancel(void) {
    AevonKbSettleSeq += 1;
}

static void AevonKbSettleWait(int seq, int polls, int goneHits);

static void AevonKbSettleOff(void) {
    int seq = AevonKbSettleSeq + 1;
    AevonKbSettleSeq = seq;
    AevonKbSettleWait(seq, 0, 0);
}

/// 0.1.84 — **收起改成一个「到点落地」的轮询，不再是一次判定。**
///
/// Aevon(152) 把「关键盘 5~10 s 才还原」的账算清了。整份日志里 8 次收起，8 次
/// 都是同一个形状：
///
///   kb: hide note gap=1.14 raw=1147 h=386 off=1   ← 真的关了（矩形在屏外）
///   kb: top zero win=430x932@0 hid=0 sub=1 last=573  ← 键盘窗成了空壳
///   kb: settle keep top=573                      ← **573 是缓存值，不是当拍读数**
///   …… 5 秒空白 ……
///   kb: idle zero close hits=3                   ← 1 Hz 心跳凑满三个零
///   kb: settle wait measure=0 retry=0
///   kb: settle gone measure=0 retry=1            ← 0.70 s 后才落地
///
/// `top zero` 那一拍的窗是「满屏、可见、子视图只剩 1」，也就是**空壳**：键盘已经
/// 走了、窗还没来得及被隐藏（日志里 `hid=1` 大约晚 1 s 才出现）。旧版把空壳折成
/// 「上次真值 573」返回，于是 `top > 200` 成立 ⇒ `settle keep` ⇒ 这次收起被作废；
/// 之后只能靠 1 Hz 的 `idle zero close` 三连零兜底，再走 0.70 s 的复量，最坏还要
/// 被下一条假 hide 通知把 seq 顶掉重来（QQ 那一段就是 10 s）。
///
/// 现在三态直说（`AevonKbVisualTopState`）：
///   · TOP   ⇒ 通知是误报，续租、什么都不动（`settle keep`，与旧版一致）；
///   · GONE  ⇒ 窗被隐藏/滑出屏底（且通知也说离屏）⇒ 连量两次就落地，约 0.5 s；
///   · SHELL ⇒ 不可测 ⇒ **不落地也不作废**，0.18 s 后接着量，最多 9 拍（1.7 s）。
///             真收起时 GONE 一般在 1 s 内出现，等不到就按「走了」落地 ——
///             宁可晚 1.7 s 还原，也不能像旧版那样把这次收起整个丢掉。
///
/// 轮询而不是「等 0.3 s 判一次」的理由是：空壳和真收起的窗口期是同一段（约 1 s），
/// 单点采样撞上哪一拍全看运气；连量九拍则一定能撞上 `hid=1` 那一刻。
static void AevonKbSettleWait(int seq, int polls, int goneHits) {
    // 第一拍 = 键盘收起动画（0.25 s）之后；之后每 0.18 s 一拍。
    CFAbsoluteTime wait = (polls == 0) ? 0.30 : 0.18;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (seq != AevonKbSettleSeq) return;   // 期间又起来了 ⇒ 这次「收起」作废
        if (AevonKbOn == 0) return;            // 已经处理过
        int state = AevonKbStateShell;
        CGFloat top = AevonKbVisualTopState(&state);
        char line[210];
        if (state == AevonKbStateTop && top > 200.0) {
            // 键盘还在屏上 ⇒ 通知是误报（几乎都是我们改窗口高惹的）。续租，什么都不动。
            snprintf(line, sizeof(line), "kb: settle keep top=%.0f\n", top);
            AevonKbLog(line);
            AevonKbPost();
            return;
        }
        if (state == AevonKbStateGone) {
            if (goneHits < 1) {
                // 窗被隐藏是硬事实，但键盘收放的一瞬间也可能闪一下 —— 隔 0.18 s
                // 再量一次，两次都 GONE 才落地。
                static int goneNotes = 0;
                if (goneNotes < 24) {
                    goneNotes += 1;
                    snprintf(line, sizeof(line), "kb: settle wait top=%.0f state=%d n=%d\n",
                             top, state, polls);
                    AevonKbLog(line);
                }
                AevonKbSettleWait(seq, polls + 1, goneHits + 1);
                return;
            }
            snprintf(line, sizeof(line), "kb: settle gone top=%.0f state=%d n=%d\n",
                     top, state, polls);
        } else if (polls < 9) {
            // 空壳：这一拍什么都证明不了。不落地也不作废，接着量。
            static int shellNotes = 0;
            if (shellNotes < 24) {
                shellNotes += 1;
                snprintf(line, sizeof(line), "kb: settle wait top=%.0f state=%d n=%d\n",
                         top, state, polls);
                AevonKbLog(line);
            }
            AevonKbSettleWait(seq, polls + 1, 0);
            return;
        } else {
            // 1.7 s 都只见到空壳 ⇒ 按走了处理。判据：`n=9` 且 state=1。
            snprintf(line, sizeof(line), "kb: settle gone top=%.0f state=%d n=%d\n",
                     top, state, polls);
        }
        AevonKbLog(line);
        AevonKbOn = 0;
        AevonKbArm(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonKbLiftRepeat();
        });
        AevonKbPostOff();
        AevonKbTopPrev = 0.0;
        AevonKbUnfitWindow();
        AevonKbSafeRestore();
        AevonRawNote("app: keyboard gone (bridge)\n");
    });
}

static void AevonKbEvaluate(NSDictionary *info) {
    NSValue *value = info[UIKeyboardFrameEndUserInfoKey];
    if (value == nil) return;
    CGRect frame = [value CGRectValue];
    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
    BOOL on = frame.size.height > 40.0 && frame.origin.y < screenHeight - 1.0;
    // 0.1.58 — **不再**用 `frame.origin.y` 当顶边（见 `AevonKbTopPublish` 上面那段：
    // 它报的是「键盘超出场景的那部分」，本机恒为 717 一带）。顶边改成量键盘视图，
    // 而且要在**动画结束之后**量 —— 动画中键盘视图一路从 932 升到 616，中途量到的
    // 每个值都会变成一次卡片重排，那正是用户看到的「一顿乱跳」。
    // 这里只在**状态翻转那一拍**安排三次采样（`AevonKbOn` 还没置 1），值相同的
    // 会被 `AevonKbTopPublish` 自己去重。中途换高度（候选栏收放）不重新采，
    // 因为那只会多一次重排。
    // 0.1.59 — 三次采样交给 `AevonKbSample`：它除了发布顶边，还会在两次读数
    // 稳定（差 < 40）时收一次 App 窗口。0.15 s 那次几乎一定还在动画里，读数与
    // 0.35 s 差得远，于是不落；0.60 s 那次才落地。
    // 0.1.64 — 「收起」不再当场落状态，先压 0.30 s 到点量一次再定。
    // 0.1.66 — **但这条通知不再算「收起」的理由。**
    //
    // Aevon(137) 数出来的是 16 次 fit 配 16 次 unfit，同一秒成对；`kb: lead`
    // 在这一串里反复出现 74 / 101 —— 那正是**我们自己收窗口**之后 UIKit 补发的
    // `willChangeFrame`：它给的 `UIKeyboardFrameEndUserInfoKey` 是相对新窗口算的，
    // 键盘落在窗口下方，`origin.y < screenHeight−1` 不成立 ⇒ `on = NO`。
    // 收一次窗口就换来一次「收起」，于是 0.5 s 一圈地放大缩小，输入框只在一瞬间
    // 露头（用户说的「无法百分百出现输入框」），卡片每收一次还闪一下黑。
    //
    // 所以这条路上 `on = NO` 一律**什么都不做**（连 settle 都不排，否则还是会被
    // 自己排出来的收起打中）。真正的收起只有一个来源：
    // `UIKeyboardWillHideNotification`（见 `AevonKbObserve`），那一条我们改窗口
    // 生成不出来。它到了之后仍然压 0.30 s 再量一次（`AevonKbSettleOff`），
    // 留作「通知到了但键盘其实还在」的保险。
    if (!on) return;
    AevonKbSettleCancel();
    if (AevonKbOn != 0) {
        // 状态没变也要续一次：键盘一直开着的时候，租约靠这一点续命。
        AevonKbPost();
        return;
    }
    AevonKbOn = 1;
    AevonKbArm(YES);
    AevonKbTopPrev = 0.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbSample(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbSample(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbSample(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.95 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbSample(); });
    // 0.1.47 — 键盘窗整体上移，1/3 节见 `AevonKbLiftApply` 上面那段。
    // 推到下一拍：`willChangeFrame` 这一刻 UIKit 还没写完键盘窗的最终几何，
    // 当场写会被紧接着的那次布局覆盖（0.1.34 那条「早半步的写入被抹掉」同形）。
    dispatch_async(dispatch_get_main_queue(), ^{
        AevonKbLiftRepeat();
    });
    AevonKbPost();
    // 0.1.49 — 判据：0.45 s 后（键盘动画 + App 重排都跑完）读一次 App 自己
    // 的键盘布局参考线。它比「我们返回了 316」硬得多 —— 那只是我们说了什么，
    // 这一行才是 App 实际把内容压到哪。顶边 ≈ 401 就是让位真的生效。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbGuideNote(); });
    // 0.1.55 — 再补一次 0.95 s。Aevon(127) 只有 0.45 s 那一行，而那一行正好落在
    // UIKit 的 `keyboardSceneDelegate` 还没把 guide 结算完的时刻（`h=0`）。
    // 两个时刻读数不同 ⇒ 只是先后；两个都 0 ⇒ UIKit 真的没认。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.95 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbGuideNote(); });
    // 0.1.67 — 0.75 s：收窗口（0.60 s 那一拍）之后 App 的重排已经跑完，这时
    // 量到的光标位置才是「用户实际看到的那条输入框」。每个周期一条。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbCaretNote(); });
    // 0.1.69 — 再补一次 1.9 s。
    //
    // 0.75 s 那一条落在 App 自己的滑入动画里：Aevon(140) 里抖音两次读数
    // 516..536 → 543..563，同一只键盘越测越低，说明那一刻还在动。只看动着的
    // 那一条，任何修法都判不了对错。1.9 s 是键盘动画（0.25 s）+ App 重排 +
    // 我们自己的排程之后，稳态值。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbCaretNote(); });
    AevonRawNote("app: keyboard up (bridge)\n");
}

/// 0.1.66 — 真的收起只有这一个来源：`UIKeyboardWillHideNotification`。
///
/// 我们改 App 窗口只会换来 `willChangeFrame`，从来生不出 hide 通知 —— 所以
/// 「谁才是收起」这件事不用猜。到了之后不立刻落状态，仍交给 `AevonKbSettleOff`
/// 压 0.30 s 再量一次：万一是「通知到了、键盘其实还在」，量到就续租。
///
/// **0.1.67 — 这条通知也不全是外来的。** Aevon(138) 数出来 15 次 `win fit` 对应
/// 15 次 `hide note`，全部落在**收完窗口之后一秒内**：收矮 key window 会让 UIKit
/// 重新结算「键盘还在不在这个窗口里」，于是反过来给 App 补一条 hide。真用户
/// 收键盘不可能每次都恰好踩在 fit 后面。所以这里加一道时间闸：距我们上次动
/// 窗口不足 0.8 s 的 hide 一律**否决**（`kb: hide note veto`），真收起交给
/// `AevonKbIdleCheck`（键盘窗连量两次空 ⇒ `kb: idle zero close`）兜底，最多晚
/// 一次心跳。宁可晚 1~2 s 还原，也不能把刚弹起来的输入框又按回去。
static void AevonKbHideNote(NSDictionary *info) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CGFloat gap = (AevonKbFitAt > 0) ? (CGFloat)(now - AevonKbFitAt) : 999.0;
    // 0.1.80 — **先看这条 hide 的原始矩形落到哪里。**
    //
    // Aevon(150) 里 `hide note seen gap=0.97` 出现在键盘弹起后 1 秒、而键盘
    // 一直没走 —— 说明 `UIKeyboardWillHideNotification` 在这套环境里**不代表
    // 键盘离开**（0.1.77 已经发现它每 2~3 s 来一条）。能代表离开的只有它带的
    // 那个矩形：真收起时 `origin.y` 落到屏幕底（932），假的那条还在屏内。
    //
    // 这一行把 raw 和判定结果一起写进日志：下一份日志里 `off=1` 的条数就该
    // 等于用户真的关了几次键盘，`off=0` 的条数就是被拦下的假收起。
    CGFloat full = AevonKbNativeBounds(nil).size.height;
    CGFloat raw = -1.0;
    CGFloat rawH = -1.0;
    NSValue *boxed = [info objectForKey:UIKeyboardFrameEndUserInfoKey];
    if (boxed != nil) {
        CGRect box = [boxed CGRectValue];
        raw = box.origin.y;
        rawH = box.size.height;
    }
    // 三种「键盘离开」的形状都算：矩形落到屏外（932）、退化成零高、或者根本没带矩形。
    BOOL off = (raw < 0.0) || (full < 1.0) || (raw >= full - 8.0) || (rawH > -1.0 && rawH < 1.0);
    static int notes = 0;
    if (notes < 12) {
        notes += 1;
        char line[170];
        snprintf(line, sizeof(line), "kb: hide note gap=%.2f raw=%.0f h=%.0f off=%d\n",
                 gap, raw, rawH, off ? 1 : 0);
        AevonKbLog(line);
    }
    if (AevonKbOn == 0) return;
    if (!off) {
        static int vetoes = 0;
        if (vetoes < 8) {
            vetoes += 1;
            char line[140];
            snprintf(line, sizeof(line), "kb: hide note veto raw=%.0f gap=%.2f\n", raw, gap);
            AevonKbLog(line);
        }
        return;
    }
    AevonKbSettleOff();
}

/// 0.1.66 — 兜底：收起通知万一没送到（交互式下滑收起在某些 App 里只改帧），
/// 键盘窗明确「不在屏上」连来两拍、而且距离上一次收窗口已经过去 2 s，就按收起处理。
///
/// 2 s 这道闸是给 `measure=0` 那个假读数留的：Aevon(137) 里 0 只出现在**刚收完
/// 窗口**的几拍，静置之后量到的都是 573。所以「静置 2 s 且连续两拍为空」不会
/// 被自己惹出来的假读数打中。
///
/// 0.1.84 — **只数「窗真的不在了」，不数空壳。**
///
/// 旧版问 `AevonKbVisualTop()`：空壳会被折成上一次真值 573 ⇒ 不计；可只要那一段
/// 缓存过期，空壳就变成一个「零」被记进连零计数 —— 于是这个兜底既会误触发、又
/// 会在该触发时装死（Aevon(152)：真收起全靠它，等到三连零已经过去 5 s 以上）。
/// 现在问三态：只有 GONE（hidden / 滑出屏底 / 尺寸不对）才算一票，空壳一律不计。
/// 两票就够 —— 空壳不再污染这个计数。
static int AevonKbZeroHits = 0;

static void AevonKbIdleCheck(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (AevonKbOn == 0) return;
        if (CFAbsoluteTimeGetCurrent() - AevonKbFitAt < 2.0) return;
        int state = AevonKbStateShell;
        AevonKbVisualTopState(&state);
        if (state != AevonKbStateGone) {
            AevonKbZeroHits = 0;
            return;
        }
        AevonKbZeroHits += 1;
        if (AevonKbZeroHits < 2) return;
        int hits = AevonKbZeroHits;
        AevonKbZeroHits = 0;
        char line[160];
        snprintf(line, sizeof(line), "kb: idle zero close hits=%d\n", hits);
        AevonKbLog(line);
        AevonKbSettleOff();
    });
}

/// 构造函数里调一次。观察者与心跳都只在**真的弹过键盘**之后才有开销。
static void AevonKbObserve(void) {
    // 0.1.77 — 先把参考线挂上：Safari（以及所有 `keyboardLayoutGuide` 拿不到
    // 真值的 App）只认这条通道，通知矩形对它们一个字都不算（Aevon(148) 七次
    // 采样六次不动）。挂在这里而不是构造函数里，是因为它和键盘的其余钩子同一
    // 生命周期，卸载/重装不会打架。
    AevonKbGuideHookInstall();
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIKeyboardWillChangeFrameNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
        AevonKbEvaluate(note.userInfo);
    }];
    // 0.1.66 — 收起的唯一来源，见 `AevonKbHideNote`。
    [center addObserverForName:UIKeyboardWillHideNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
        AevonKbHideNote(note.userInfo);
    }];
    AevonKbTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    if (AevonKbTimer == NULL) return;
    dispatch_source_set_timer(AevonKbTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                              NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(AevonKbTimer, ^{
        if (AevonKbOn == 0) return;
        AevonKbPost();
        AevonKbIdleCheck();
    });
    // **不 resume。** `dispatch_source_create` 出来就是挂起态，键盘第一次起来时
    // 由 `AevonKbArm(YES)` 放行；在那之前这个进程一次都不醒。
}

/// 此刻是不是停靠小窗。两条通道取或：通知（实时、租约 2.5 s）优先，文件兜冷启动。
static BOOL AevonMiniDockedNow(void) {    if (AevonMiniLeaseOn) {
        if (CFAbsoluteTimeGetCurrent() - AevonMiniLeaseAt < AevonMiniLeaseSpan) return YES;
        // 租约过期 = 心跳断了（宿主没了）或 off 丢了。自己收回，绝不让 App 僵死。
        AevonMiniLeaseOn = 0;
    }
    return AevonMiniFlagFile();
}

/// 0.2 s 缓存。`sendEvent:` 是热路径，一次手势里会有几十条事件；但标记是随
/// 「用户点了小窗」变化的，所以**按下的那一拍强制重读**（一次手势只有一次），
/// 同一根手指的后续事件走缓存。
static BOOL AevonMiniDocked(BOOL force) {
    static CFAbsoluteTime stamp = 0;
    static BOOL answer = NO;
    if (!force) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (stamp > 0 && now - stamp < 0.2) return answer;
    }
    stamp = CFAbsoluteTimeGetCurrent();
    answer = AevonMiniDockedNow();
    return answer;
}

static int AevonMiniSwallowDowns = 0;
static int AevonMiniSwallowEvents = 0;
static int AevonMiniSwallowLines = 0;
static CFAbsoluteTime AevonMiniSwallowAt = 0;

/// 每秒一行证词，与宿主侧 `win: mini touch down=` 对齐。
/// 这一行出现 ⇒ 漏的那份投递**确实**经过 App 的 `sendEvent:`，闸门装对了地方；
/// 一行都不出现而用户仍被点到 ⇒ 它连 `UIApplication` 都不经过，下一手只能往
/// `_UIApplicationHandleEventFromEventQueue` 上走。
static void AevonMiniSwallowNote(BOOL began) {
    if (began) AevonMiniSwallowDowns += 1;
    AevonMiniSwallowEvents += 1;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonMiniSwallowAt == 0) { AevonMiniSwallowAt = now; return; }
    if (now - AevonMiniSwallowAt < 1.0) return;
    int downs = AevonMiniSwallowDowns;
    int events = AevonMiniSwallowEvents;
    AevonMiniSwallowDowns = 0;
    AevonMiniSwallowEvents = 0;
    AevonMiniSwallowAt = now;
    if (downs == 0 || AevonMiniSwallowLines >= 20) return;
    AevonMiniSwallowLines += 1;
    char line[160];
    snprintf(line, sizeof(line), "app: mini touch swallowed down=%d ev=%d\n", downs, events);
    AevonAppLogWrite(line);
}

static IMP AevonOriginalUISendEvent = NULL;

/* ⛔ 0.1.24 — **右缘呼盘：应用侧把同一根手指也收走。**
 *
 * 为什么 SpringBoard 那边吞了不够。Aevon(107) 里 13 次呼盘全部成功、`app touch`
 * 20 次、inset 5~12 全在带内 —— 通道是通的。但用户报「右侧滑动时会触发应用内的
 * 滑动操作」，日志里酷安那一片 `page state after change pager` 就是它。
 *
 * 原因是进程模型，不是判据：这根手指由 backboardd **分别**投递给 SpringBoard 和
 * 前台 App，两边各拿各的一份。SpringBoard 的 `sendEvent` 吞掉的只是它自己那份，
 * App 那份一条不少 —— 它的 `UIPanGestureRecognizer` / 侧滑返回照常跑完。
 *
 * 所以这里补上 App 侧的那一半。判据与宿主侧同源（贴右缘 18 pt × 底部 35 %、
 * `|dx| >= |dy| * 0.7`），只是**起判点从 8 pt 提前到 3 pt**：
 *
 *   · 3 pt 判成左滑 ⇒ 这根手指归我们，从 began 起全吞；
 *   · 3 pt 判成别的东西（竖向 / 向右）⇒ 立刻把扣住的 began 还回去，之后一条不碰；
 *   · 一直没判出来（原地不动）⇒ 抬手时把 began + ended 一起还回去，点击照常。
 *
 * 为什么必须提前到 3 pt：`UIPanGestureRecognizer` 和 `UIScrollView` 的 pan 都在
 * 10 pt 左右 recognize。留在 8 pt 就正好把「能不能动」的判决让给了它们 —— 那
 * 8 pt 的轨迹足够让应用决定「这是一次滚动」。3 pt 时它们还在 .possible。
 *
 * 代价写在这里：贴右缘划的**竖向**手势会丢掉最前面 3 pt 的轨迹。补发之后应用
 * 从原点重新开始跟，用户感觉不到；换来的是一条「不再穿透到应用」的右缘。
 */
static CGPoint AevonEdgeOrigin = { 0, 0 };
static BOOL AevonEdgeWatching = NO;
static BOOL AevonEdgeOwned = NO;
/// 被扣住的那一拍 `began`。判成不是左滑就要还回去，否则应用永远等不到落指。
static UIEvent *AevonEdgeHeld = nil;
static int AevonEdgeNotes = 0;

static void AevonEdgeDrop(void) {
#if !__has_feature(objc_arc)
    [AevonEdgeHeld release];
#endif
    AevonEdgeHeld = nil;
}

static void AevonEdgeKeep(UIEvent *event) {
    AevonEdgeDrop();
#if !__has_feature(objc_arc)
    AevonEdgeHeld = [event retain];
#else
    AevonEdgeHeld = event;
#endif
}

/// 这一根手指是不是从「右缘底部 35 %」起手的。
///
/// 读 `UIScreen.mainScreen.bounds` 而不是窗口：这段代码在每一个 App 进程里跑，
/// 而 App 自己的窗口可能被 transform / 分屏挪过。屏幕尺寸是这个判定唯一需要的
/// 参照 —— **只读，不写**（0.0.65 / 0.0.67 的教训是「改」它，不是「读」它）。
static BOOL AevonEdgeInBand(CGPoint p) {
    CGSize size = [UIScreen mainScreen].bounds.size;
    if (size.width < 1.0 || size.height < 1.0) return NO;
    return p.x >= size.width - 18.0 && p.y >= size.height * 0.65;
}

/// 返回 YES = 这一拍不往上派发。`*replay` 为 YES 表示「扣住的那一拍该还回去」。
static BOOL AevonEdgeTake(UIEvent *event, BOOL *replay) {
    NSSet *touches = [event allTouches];
    // 多指：呼盘只认单指。已经扣住的那一拍必须还回去，否则应用少半截事件。
    if (touches.count != 1) {
        AevonEdgeWatching = NO;
        AevonEdgeOwned = NO;
        *replay = YES;
        return NO;
    }
    UITouch *touch = [touches anyObject];
    CGPoint p = [touch locationInView:nil];
    UITouchPhase phase = touch.phase;

    if (phase == UITouchPhaseBegan) {
        if (!AevonEdgeInBand(p)) {
            AevonEdgeWatching = NO;
            return NO;
        }
        AevonEdgeWatching = YES;
        AevonEdgeOwned = NO;
        AevonEdgeOrigin = p;
        AevonEdgeKeep(event);
        if (AevonEdgeNotes < 20) {
            AevonEdgeNotes += 1;
            char line[128];
            snprintf(line, sizeof(line), "app: edge touch at %.0f,%.0f held\n", p.x, p.y);
            AevonAppLogWrite(line);
        }
        return YES;   // 先扣住，判明方向再说
    }

    if (!AevonEdgeWatching) return NO;
    CGFloat dx = p.x - AevonEdgeOrigin.x;
    CGFloat dy = p.y - AevonEdgeOrigin.y;

    if (phase == UITouchPhaseMoved || phase == UITouchPhaseStationary) {
        if (AevonEdgeOwned) return YES;
        // 3 pt 就够定方向：向左、且横向不输给竖向 * 0.7（单手拇指是斜划）。
        if (dx <= -3.0 && fabs(dx) >= fabs(dy) * 0.7) {
            AevonEdgeOwned = YES;
            AevonEdgeDrop();      // 归我们了，那半截 began 作废
            return YES;
        }
        // 认输要决定性：向右走够 16 pt，或者竖向占优走够 16 pt。
        if (dx >= 16.0 || (fabs(dy) >= 16.0 && fabs(dy) > fabs(dx))) {
            AevonEdgeWatching = NO;
            *replay = YES;
            return NO;
        }
        return YES;               // 还没判出来，继续扣着
    }

    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        BOOL owned = AevonEdgeOwned;
        AevonEdgeWatching = NO;
        AevonEdgeOwned = NO;
        if (owned) {
            AevonEdgeDrop();
            return YES;
        }
        // 原地不动就抬手 = 点击：began 和这一拍一起还回去，tap 照常识别。
        *replay = YES;
        return NO;
    }
    return NO;
}

// MARK: - 0.1.29 主窗四边热区（应用侧扣住）
//
// 用户原话：「在全屏应用中操作主悬浮窗的四边手势时有概率触发全屏 app 的操作
// （例如上滑关闭悬浮窗手势，上滑后，悬浮窗关闭，全屏 app 会向下滑动）」。
//
// 和右缘呼盘（0.1.24）是同一个物理事实：backboardd 把同一根手指**分别**投递给
// SpringBoard 和前台 App。宿主侧把手势识别器吃掉，只解决了自己那一份。
//
// 数据来自桌面写进本进程容器 `tmp/aevon-band` 的 8 个整数（外框 + 卡片的
// x/y/w/h），通知 `com.aevon.band.<bundle>` 只是「去读那个文件」的铃铛。
//
// **不做方向判定**：带内起手 = 整根归宿主。那一片在屏幕上本来就是卡片外侧的
// 热区，App 在它下面；而且宿主的动作（吸附 / 拖动 / 上滑关）已经执行了，App 再
// 收到一份就是一次重复响应。

static CGRect AevonBandOuter = {{0, 0}, {0, 0}};
static CGRect AevonBandHole  = {{0, 0}, {0, 0}};
static volatile int AevonBandOn = 0;
static BOOL AevonBandWatching = NO;
static int AevonBandNotes = 0;
static int AevonBandProof = 0;
/// 0.1.35 — 几何判不中的次数。第一次能回答「进来了但被否掉」而不是「没进来」。
static int AevonBandRejects = 0;
/// 0.1.39 — 「起手落在环带里，但还没归宿主」的证词预算。
static int AevonBandWatches = 0;
/// 0.1.39 — 这一根手指起手时落在环带里（**只是候选**，不等于归宿主）。
///
/// 0.1.37/0.1.38 把「起手落在环带里」直接当成「归宿主」，于是整条环带 54 pt
/// 变成死区：用户在卡片周围的 App 画面上点一下、滑一下，全被吞掉，两边都没
/// 反应。用户的原话是「部分 App 的手势失效，无法点击，滑动」。候选与接管必须
/// 分开：候选只说明「等会儿可能轮到宿主」，接管要等宿主真的开口（那把锁）。
static int AevonBandCandidate = 0;
/// 0.1.39 — 候选期间主动读过几次锁。前 8 拍够用，之后交给通知。
static int AevonBandPeeks = 0;
/// 0.1.36 — 擦高亮的那一次还排在主队列上（防止一串通知把遍历排成好几遍）。
static volatile int AevonBandClearing = 0;
/// 0.1.34 — 「这根手指归宿主」。拖动 / 缩放期间为 1（见 `AevonAppBandLock`）。
static volatile int AevonBandLock = 0;
/// 上面那把锁是什么时候打开的（3 秒租约，见 `AevonBandHeld`）。
static CFAbsoluteTime AevonBandLockAt = 0;
/// 自己那一格偏好域，构造函数里算一次。
static CFStringRef AevonBandApp = NULL;

/// 读一次值。
///
/// 0.1.34 — 换了来源：`CFPreferences`（宿主写我们的域，我们读自己的域）。
///
/// 前两版都没通，但**原因不同**：0.1.29 读容器里的文件，而宿主取不到容器
/// （V109/V110 的 `win: mini flag armed … no file`），文件从来没写进去；
/// 0.1.31 把数字编进通知名，却要求我们注册 `NULL` 收全系统的 Darwin 通知 ——
/// 那条通不通，日志分不开（值读空就足以让 `app: band touch at` 一条都不出现）。
/// 这一版值走偏好域、名字固定，并且分别留了 `app: band note` 与
/// `app: band prefs` 两行证词：下一份日志能直接回答是哪一段断的。
///
/// 找不到 / 内容不完整 ⇒ 关掉（宁可不吞，也不能让一块区域死掉）。
static void AevonBandReload(void) {
    if (AevonBandApp == NULL) { AevonBandOn = 0; return; }
    // 0.1.39 — **不再 `CFPreferencesSynchronize`。**
    //
    // 这一句会把整个偏好域同步刷盘，而它原来挂在每次触摸的起手上（见下面
    // `AevonBandTake` 的旧注释）。全机所有 App 的每一次点击都要过这条路径，
    // 那就是用户这一版报的「让手机卡顿」。读值不需要刷盘：宿主的写已经在
    // 自己的进程里提交过，cfprefsd 手上就是最新的。
    // 这个文件是 MRC（Theos 默认不开 ARC），所以不碰 `CFBridgingRelease`：
    // 取出来的 CF 值自己释放，中间只用一块栈上的 C 字符串。
    CFStringRef value = CFPreferencesCopyAppValue(CFSTR("AevonBand"), AevonBandApp);
    char text[128] = {0};
    Boolean read = NO;
    if (value != NULL) {
        read = CFStringGetCString(value, text, sizeof(text) - 1, kCFStringEncodingUTF8);
        CFRelease(value);
    }
    if (!read || text[0] == 0) {
        // 兜底：容器里那份文件（宿主取得到容器时两条路会各写一份）。偏好域这条
        // 是主路 —— 它不依赖容器，而 V109/V110 两次失败的共同点正是取不到容器。
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aevon-band"];
        NSString *body = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (body.length == 0) {
            AevonBandOn = 0;
            AevonBandLock = 0;
            return;
        }
        snprintf(text, sizeof(text), "%s", body.UTF8String);
    }
    if (text[0] == 0 || strcmp(text, "none") == 0) {
        AevonBandOn = 0;
        AevonBandLock = 0;
        return;
    }
    // 9 个数直接扫，不建数组：`sendEvent:` 每次手势都要走这条判定，回调里也
    // 不该留下 autoreleased 容器（构造函数那一拍没有 pool）。
    double v[9] = {0};
    int got = sscanf(text, "%lf %lf %lf %lf %lf %lf %lf %lf %lf",
                     &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8]);
    if (got < 8) { AevonBandOn = 0; AevonBandLock = 0; return; }
    AevonBandOuter = CGRectMake((CGFloat)v[0], (CGFloat)v[1], (CGFloat)v[2], (CGFloat)v[3]);
    AevonBandHole = CGRectMake((CGFloat)v[4], (CGFloat)v[5], (CGFloat)v[6], (CGFloat)v[7]);
    AevonBandOn = (AevonBandOuter.size.width >= 1 && AevonBandOuter.size.height >= 1);
    BOOL locked = (got >= 9 && v[8] >= 0.5);
    // 0.1.36 — 每读到一个「锁着」就把租约往后推，不再只在 0→1 那一次起表。
    //
    // 3 秒租约的本意是「宿主没来得及解锁时自己收回」，可 0.1.34/0.1.35 只在
    // 锁初次成立那一下起表：一次慢拖（用户按住 0.25 s 才开闸，再慢慢上滑）超过
    // 3 秒，租约中途到期，`AevonBandHeld` 把锁抹掉 —— 那一根剩下的半截就漏给
    // App 了。锁着就一直续，这才是「宿主还在说这根归我」的意思。
    if (locked) AevonBandLockAt = CFAbsoluteTimeGetCurrent();
    AevonBandLock = locked ? 1 : 0;
    // 判据：这一行出现 ⇒ 通道真的通了（值、来源、锁都在里面）。没有它而用户
    // 还被透传，问题就不在这条通道上，别再改这里。
    if (AevonBandProof < 12) {
        AevonBandProof += 1;
        char line[192];
        snprintf(line, sizeof(line),
                 "app: band prefs on=%d band=%.0fx%.0f at %.0f,%.0f lock=%d\n",
                 (int)AevonBandOn, AevonBandOuter.size.width, AevonBandOuter.size.height,
                 AevonBandOuter.origin.x, AevonBandOuter.origin.y, (int)AevonBandLock);
        AevonAppLogWrite(line);
    }
}

/// 0.1.39 — 只读「锁」这一个数，不动几何、不写日志。
///
/// 起手那一拍现在放行了（见 `AevonBandTake`），「归不归宿主」就完全由宿主那把
/// 锁说了算。Darwin 通知通常十几毫秒就到，但拖动开始后的头一两拍移动事件可能
/// 抢在通知前面 —— 那时读一次偏好域就能接上，而不是整场手势都漏给 App。
///
/// 只有「起手落在环带里」的手势才会走到这里（`AevonBandCandidate`），而且最多
/// 前 8 拍；普通点击一次都不读。
static void AevonBandPeekLock(void) {
    if (AevonBandApp == NULL) { AevonBandLock = 0; return; }
    CFStringRef value = CFPreferencesCopyAppValue(CFSTR("AevonBand"), AevonBandApp);
    if (value == NULL) { AevonBandLock = 0; return; }
    char text[128] = {0};
    Boolean read = CFStringGetCString(value, text, sizeof(text) - 1, kCFStringEncodingUTF8);
    CFRelease(value);
    if (!read) return;
    double v[9] = {0};
    int got = sscanf(text, "%lf %lf %lf %lf %lf %lf %lf %lf %lf",
                     &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8]);
    if (got < 9) { AevonBandLock = 0; return; }
    BOOL locked = (v[8] >= 0.5);
    if (locked) AevonBandLockAt = CFAbsoluteTimeGetCurrent();
    AevonBandLock = locked ? 1 : 0;
}

/// 0.1.36 — 把 App 里已经亮起来的那一项擦掉。
///
/// **0.1.35 这里只认 `UIControl`，所以它在真机上一次都没生效过。**
///
/// 用户的原话是「APP 内的选项出现选中背景，但是不会触发选中功能」——那正是
/// `touchesBegan` 起来了、`moved`/`ended` 被我们吞掉的形状。而列表里的行没有
/// 一个是 `UIControl`：设置那一页是 `PSTableCell`（继承 `UITableViewCell`），
/// Sileo 那一类列表是 cell 或 SwiftUI 的宿主视图。`isKindOfClass:[UIControl
/// class]` 在这个树上永远为假，高亮就留在屏幕上，直到下一次有人点它。
///
/// 三家（`UIControl` / `UITableViewCell` / `UICollectionViewCell`）都有
/// `setHighlighted:`，那就按消息问，不按类问。谁没有就跳过。
///
/// `depth` 是防病态树：真实页面十几层，卡在 40 层足够，再深也不可能是列表行。
static void AevonBandDropHighlights(UIView *view, int depth) {
    if (view == nil || depth > 40) return;
    if ([view respondsToSelector:@selector(setHighlighted:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(view, @selector(setHighlighted:), NO);
    }
    for (UIView *child in view.subviews) AevonBandDropHighlights(child, depth + 1);
}

static void AevonBandDropAllHighlights(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            AevonBandDropHighlights(window, 0);
        }
    }
}

static void AevonBandNote(CFNotificationCenterRef __unused center,
                          void *__unused observer,
                          CFStringRef name,
                          const void *__unused object,
                          CFDictionaryRef __unused userInfo) {
    if (name == NULL) return;
    // 精确注册之后这里只会被我们自己那一格叫醒，不必再比前缀。
    if (AevonBandNotes < 12) {
        AevonBandNotes += 1;
        AevonAppLogWrite("app: band note from host\n");
    }
    AevonBandReload();
    // 0.1.50 — 卡片几何变了（键盘态把卡片摆到屏幕下半部 215..932），键盘上移
    // 的基准「场景底边」也跟着变。这里补一拍重算：键盘弹出那一瞬间宿主还没把
    // 卡片摆好，`kb: lift` 会先按旧几何算出一个非零位移，通知到了就得拉回来。
    dispatch_async(dispatch_get_main_queue(), ^{ AevonKbLiftApply(AevonKbOn != 0); });
    // 0.1.36 — 只要锁是开的就擦一次，不再要求「这一次是 0→1」。
    //
    // 0.1.34/0.1.35 的写法是 `if (wasLocked || !AevonBandLock) return;`：锁在上
    // 一通通知里已经是 1，这一通就什么都不做。可 `.began` 是**每一次手势**单独
    // 漏进来的，上一次擦过不代表下一次没亮 —— 一次拖完紧接着上滑关闭，第二根
    // 手指点亮的那一行就没人擦。
    //
    // 用 `AevonBandClearing` 把并发的几通通知压成一遍遍历：锁着的时候连着来
    // 两三通是常态（几何 + 锁各一发），每通都走一遍整棵树是白花。
    if (!AevonBandLock) return;
    if (AevonBandClearing) return;
    AevonBandClearing = 1;
    // Darwin 通知的回调**不保证在主线程**，而下面要动 UIView：必须跳回主队列。
    // 跳一拍不损失什么 —— 这一行本来就是在 `touchesBegan` 之后才可能执行到，
    // 目的只是把那一拍点亮的高亮擦掉。
    dispatch_async(dispatch_get_main_queue(), ^{
        AevonBandDropAllHighlights();
        AevonBandClearing = 0;
    });
}

static void AevonBandObserve(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return;
    // 0.1.34 — 名字**固定**，两端精确匹配。上一版注册 `NULL` 想收全系统的
    // Darwin 通知，但那条路在两份日志里都分不出通没通；精确名不需要赌。
    AevonBandApp = CFStringCreateCopy(kCFAllocatorDefault, (__bridge CFStringRef)bundle);
    NSString *name = [NSString stringWithFormat:@"com.aevon.band.%@", bundle];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, AevonBandNote,
                                    (__bridge CFStringRef)name, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    // 构造函数可能晚于第一份数据（宿主先开卡、App 进程后起），先读一次。
    AevonBandReload();
}

/// 0.1.34 — 锁带 3 秒租约。
///
/// 跨进程的状态位必须能自己收回：宿主崩了、手势被系统抢走、`dragEnd` 没走到，
/// 任何一次漏解都会让这个 App **永久**吃掉所有单指触摸 —— 那比透传严重得多，
/// 用户只能重启那个 App。三秒 ≈ 一次拖动的最长合理时长。
static BOOL AevonBandHeld(void) {
    if (!AevonBandLock) return NO;
    if (CFAbsoluteTimeGetCurrent() - AevonBandLockAt < 3.0) return YES;
    AevonBandLock = 0;
    return NO;
}

/// 这一点归宿主吗。卡片内部不算（那是 App 的画面），右缘那 18 pt 也不算
/// —— 那块归呼圆盘（0.1.24），两个闸门抢同一根手指时先出声的赢。
static BOOL AevonBandHolds(CGPoint p) {
    if (!AevonBandOn) return NO;
    if (!CGRectContainsPoint(AevonBandOuter, p)) return NO;
    if (CGRectContainsPoint(AevonBandHole, p)) return NO;
    if (AevonEdgeInBand(p)) return NO;
    return YES;
}

static BOOL AevonBandTake(UIEvent *event) {
    NSSet *touches = [event allTouches];
    if (touches.count != 1) {
        AevonBandWatching = NO;
        AevonBandCandidate = 0;
        return NO;
    }
    UITouch *touch = [touches anyObject];

    // 0.1.39 — **起手这一拍不吞。**
    //
    // 0.1.37/0.1.38 在 `.began` 直接按几何定案：落点在外环 54 pt 的带子里就算
    // 「归宿主」，`return YES`。问题是那条环带**盖在全屏 App 的画面上** ——
    // 用户在卡片周围点一下、滑一下，这一整根就被吞了，宿主又只在真的拖动 /
    // 上滑时才有动作，于是两边都没反应。日志（Aevon(113)）里那段
    // `com.mlgm.ilog` 连着十条 `band touch at 229,225 held` 全是这样丢的，
    // 用户的原话是「部分 App 的手势失效，无法点击，滑动」。
    //
    // 所以起手只**记候选**（`AevonBandCandidate`），不接管。接管的条件只有一个：
    // 宿主自己开口说「这根归我」—— 也就是那把锁。
    if (touch.phase == UITouchPhaseBegan) {
        CGPoint p = [touch locationInView:nil];
        BOOL inside = AevonBandHolds(p);
        AevonBandCandidate = inside ? 1 : 0;
        AevonBandWatching = NO;
        AevonBandPeeks = 0;
        if (inside) {
            if (AevonBandWatches < 8) {
                AevonBandWatches += 1;
                char line[160];
                snprintf(line, sizeof(line),
                         "app: band touch at %.0f,%.0f watch\n", p.x, p.y);
                AevonAppLogWrite(line);
            }
        } else if (AevonBandOn && AevonBandRejects < 8) {
            // 0.1.35 — 判不中的时候把**为什么**写下来。上一份日志里
            // `app: band touch at` 是 0，而这条带子的值明明是对的（`app: band
            // prefs on=1 band=368x536 at 23,185`），分不出是「这一拍没进来」
            // 还是「进来了但被几何否掉」。每个进程前 8 条，够对一次位置。
            AevonBandRejects += 1;
            char line[160];
            snprintf(line, sizeof(line),
                     "app: band miss at %.0f,%.0f outer=%.0fx%.0f@%.0f,%.0f hole=%.0fx%.0f\n",
                     p.x, p.y,
                     AevonBandOuter.size.width, AevonBandOuter.size.height,
                     AevonBandOuter.origin.x, AevonBandOuter.origin.y,
                     AevonBandHole.size.width, AevonBandHole.size.height);
            AevonAppLogWrite(line);
        }
        // 放行：这一根先按 App 自己的意思走。Tap 会在抬手时正常触发；真的
        // 拖动 / 上滑由下面几拍在锁到手后接管。
        return NO;
    }

    if (!AevonBandWatching) {
        if (!AevonBandCandidate) return NO;
        // 候选期间主动读几次锁：Darwin 通知通常十几毫秒就到，但拖动开始后的
        // 头一两拍移动事件可能抢在它前面。只在前 8 拍读，之后完全靠通知。
        if (AevonBandPeeks < 8) {
            AevonBandPeeks += 1;
            AevonBandPeekLock();
        }
        if (!AevonBandHeld()) return NO;
        // 宿主开口了：这一根从这一刻起归它。App 刚才已经收到 `.began`（可能
        // 亮了一行），这里把那一拍点亮的擦掉，后面的 `moved` / `ended` 全吞。
        AevonBandWatching = YES;
        if (AevonBandNotes < 20) {
            AevonBandNotes += 1;
            CGPoint p = [touch locationInView:nil];
            char line[160];
            snprintf(line, sizeof(line), "app: band touch at %.0f,%.0f held\n", p.x, p.y);
            AevonAppLogWrite(line);
        }
        if (!AevonBandClearing) {
            AevonBandClearing = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                AevonBandDropAllHighlights();
                AevonBandClearing = 0;
            });
        }
    }
    if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
        AevonBandWatching = NO;
        AevonBandCandidate = 0;
    }
    return YES;
}

static void AevonAppSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (AevonOriginalUISendEvent == NULL) return;
    // 只拦触摸事件。远程控制、运动事件这些和停靠无关，原样放行。
    NSSet *touches = [event allTouches];
    if (touches.count == 0) {
        ((void (*)(id, SEL, UIEvent *))AevonOriginalUISendEvent)(self, _cmd, event);
        return;
    }
    BOOL began = NO;
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan) { began = YES; break; }
    }
    // 停靠小窗优先：用户看得见的那块先拿手指。
    if (AevonMiniDocked(began)) {
        AevonMiniSwallowNote(began);
        return;
    }
    // 0.1.29 — 主窗四边热区。排在右缘之前是因为它在带内起手就定案（不判方向、
    // 不用 replay），而 `AevonEdgeTake` 会扣住 began 再还回去 —— 两条都在一块时
    // 让「立刻定案」的先答，不会出现半截还回去又被吞的错位。
    if (AevonBandTake(event)) return;
    // 0.1.24 — 右缘呼盘：同一根手指在 App 这一份也要收走。
    BOOL replay = NO;
    if (AevonEdgeTake(event, &replay)) return;
    if (replay && AevonEdgeHeld != nil) {
        UIEvent *held = AevonEdgeHeld;
        AevonEdgeHeld = nil;
#if !__has_feature(objc_arc)
        [held retain];   // 重放期间不被 autorelease pool 收走
#endif
        ((void (*)(id, SEL, UIEvent *))AevonOriginalUISendEvent)(self, _cmd, held);
#if !__has_feature(objc_arc)
        [held release];
#endif
    }
    ((void (*)(id, SEL, UIEvent *))AevonOriginalUISendEvent)(self, _cmd, event);
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

// MARK: - 0.1.43 键盘：只留 intersection 的纯换算
//
// ## 母本取证（`SthenoKeyboard.dylib`，arm64e 切片，init @0x506c）
//
//   ```
//   0x50b4  _inject()            读 com.nx.stheno.plist 的 Inject（缺省 YES）
//   0x50c4  _ringAppsContains()  本 App 在 plist 的 Apps 名单里才继续；先排除 springboard
//   0x50d0  _UIRemoteKeyboards  -intersectionHeightForWindowScene:isLocalMinimumHeightOut:ignoreHorizontalOffset:  → 0x5284
//   0x510c  UIRemoteKeyboardWindow -remoteKeyboardWindowForScreen:create:                                          → 0x5390
//   0x5140  FBSWorkspaceScenesClient -sceneID:updateWithSettingsDiff:transitionContext:completion:                 → 0x55a4
//   0x516c  UIScreen -bounds                                                                                        → 0x567c
//   0x5194  UIApplication -openURL:options:completionHandler:                                                       → 0x571c
//   ```
//
// 关键在 `_ringAppsContains`：Filter 里的 `Bundles: com.apple.UIKit` 只是母本
// 「注入所有带 UIKit 的进程」的通用写法，**不是键盘进程**；真正的闸门是「这个 App
// 现在正被浮起来」。Aevon 里对应的判据是 `AevonBandOn`（宿主把卡片几何推过来时置 1）。
//
// ## 0.1.40 / 0.1.41 为什么一次都没跑
//
// 那两版按 `bundleIdentifier == com.apple.UIKit` 判 ⇒ 真机上永远不成立，
// Aevon(116) 的日志里连一行 `kb:` 都没有。
//
// ## 0.1.42 为什么黑屏
//
// 改对了位置（装进每个 App 进程），但同时装了两条**写几何**的钩子：
//
//   · `UIScreen -bounds`：在 App 进程里换掉屏幕尺寸，整个 App 的布局基准就变了。
//     0.0.65 / 0.0.67 两次「App 打不开、桌面黑屏」就是这一类；这条的执行体里还要
//     问 `nativeBounds`，本身带递归风险。
//   · `UIRemoteKeyboardWindow -remoteKeyboardWindowForScreen:create:`：把键盘窗
//     撑成整屏再居中，等于给整屏盖一块不透明的键盘窗 —— 键盘没弹出来时这个窗口
//     也在，于是「无论悬浮窗还是全屏打开，所有 App 都黑屏」。
//
// 两条在 0.1.43 全部撤掉。留下的是母本真正起作用的那一条：**`intersectionHeight`
// 的纯换算**。它不写任何几何、不改任何窗口尺寸，只把系统问「键盘该占多高」的那个
// 数换回整屏基准 —— 键盘尺寸由系统自己按这个数出图，改坏了最坏也只是键盘高度不对。
//
// ## 闸门（`AevonKbHostGate`）
//
// `AevonBandOn` + 开关没关 + **卡片外框明显小于屏幕**。第三条是 0.1.43 新加的：
// 0.1.42 的黑屏说明 `AevonBandOn` 会在「全屏打开」时仍停在 1（宿主清得比 App 启动晚），
// 所以再加一道看得见的几何判据。宁可不动，也不动全屏 App。

/// 键盘原生尺寸的开关。缺省开 —— 它和卡片是一体的功能：关掉它，悬浮窗里的
/// 键盘就退回「只露一条工具栏」。
static int AevonKbNativeGate = -1;

static BOOL AevonKbNativeAllowed(void) {
    if (AevonKbNativeGate >= 0) return AevonKbNativeGate == 1;
    AevonKbNativeGate = 1;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("!ring.keyboardNative"),
                                                       AevonDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            AevonKbNativeGate = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
        }
        CFRelease(value);
    }
    return AevonKbNativeGate == 1;
}

/// 0.1.43 — 全段只剩这一个原始实现。
static IMP AevonOrigIntersection = NULL;

/// 0.1.65 — 系统最近一次算出的「键盘遮住场景多少」（本机 289 ⇒ 键盘顶 643）。
/// 由 `AevonKbIntersection` 写入，`AevonKbTopCorrected` 读它来校正量视图的偏差。
/// 只保留 200..500 的合理值：键盘收起时系统报 0，场景没搬那拍报 74/101。
static CGFloat AevonKbLeadSeen = 0.0;

/// 日志配额。一次输入会反复问交点高度，证词只留前几条 —— 写日志本身就可能
/// 把键盘帧率拖下来。
static volatile int AevonKbLeadNotes = 0;
static volatile int AevonKbMissNotes = 0;

/// 0.1.55 — 键盘**实体**顶边在屏幕上的 Y（本机 616）。
///
/// `UIKeyboardDidShowNotification` 的 `UIKeyboardFrameEndUserInfoKey.origin.y` 原值。
/// 只取 `DidShow` —— `WillChangeFrame` 在弹出动画里每帧都发（Aevon(124) 记过
/// 502/573/674/775 四个值），拿它当基准会把让位量算成动画中间态。`DidShow` 是
/// 动画结束后那一次，值稳定。
///
/// 为什么要它：Aevon(127) 里系统给的 `answer` 稳定值是 **289**（键盘顶 643），
/// 而备忘录弹出的瞬间给过 **316**（键盘顶 616）。两个数差 27，说明系统在某些
/// 时刻会少算一截。让位量一旦少给，输入框就压在键盘下面 —— 这是微信/QQ
/// 「永远看不见输入框」的最后一层。所以这里留一份实测顶边，`AevonKbIntersection`
/// 用它兜一层底（只往大了取）。
static volatile CGFloat AevonKbTopSeen = 0.0;

/// 0.1.70 — 结算后的键盘顶边（屏幕坐标），整个进程只降不升。
///
/// 键盘是从屏幕下方滑上来的，`origin.y` 一路上降到最后那个数：动画途中的读数
/// （721 / 761 / 788 / 818）全在最终值**上面**，所以「见过的最小顶边」就是
/// 结算值，不需要等动画、也不读任何视图几何。
///
/// 注意这**不是**键盘像素的真实上沿（616）。各 App 通知里报的是它自己认为的
/// 键盘矩形顶，实测：QQ 639 · 微信 601 · 抖音 611 —— 与真实上沿的差由
/// `AevonKbNoteCalibration` 抹平，别在这里硬凑 616。
///
/// 0.1.71 — 跨会话**不清零**（见 `AevonKbPostNote` 里的推导）。`WillShow` 也
/// 不能当会话边界：同一个键盘会连发两轮 WillChangeFrame/WillShow，第二轮一
/// 重置就把第一轮结算好的值抹掉。
static volatile CGFloat AevonKbTopSettled = 0.0;

/// 0.1.71 — `kb: top settle kept` 的日志配额（同一个 App 一个进程里只会写几条）。
static volatile int AevonKbTopSettleNotes = 0;

/// 0.1.70 — 每个 App 自己的输入条会额外吃掉的高度（实测标定，屏幕 pt）。
///
/// 0.1.71 起这三个数不再靠手调，而是由 `kb: caret … bar=` 与 `kb: inter true=`
/// 两点解一元一次方程得到，推导写在函数体里。这里只留「为什么会有这个量」：
///
/// 这几个 App 都用同一个公式算避让 —— `让位量 = UIScreen 高 − 键盘顶`，然后把
/// 自己的输入条底边贴到 `窗口底 − 让位量`。我们的场景是 `430×717@215`，窗口高
/// 717 而屏幕高 932，于是「窗口底 − 让位量」比真实键盘顶**低 215**；0.1.69 把
/// 通知平移 215 本来是想补这一刀，结果 App 在平移前后各算了一次：
///
///   抖音先收到未平移的（顶 533 ⇒ 让位 184），又收到平移的（顶 318 ⇒ 让位 399），
///   两次**累加** ⇒ 717−583＝134 ⇒ 屏幕 215+134＝**349**，与日志 `bar=329..349`
///   完全一致；用户看到的就是「输入框被抬高」。
///
/// 所以 0.1.70 之后只做一件事：把「顶边」挪到一个能让**输入条底边正好落在
/// 键盘上沿**的位置，挪多少由实测反解。抖音 0 因为它把工具栏算进了键盘矩形，
/// 铺完正好 —— 不要给它加任何非零标定。
/// 0.1.72 — 每个 App 通知里那颗「键盘矩形顶」的**结算值**，按 App 钉死。
///
/// 返回 0 表示「不认识这台机器」，调用方退回通知原值（行为同 0.1.71）。
///
/// 为什么不再从通知取：Aevon(143) 把这条路彻底证伪了。同一个键盘，`origin.y`
/// 在一次弹出动画里是**先降后回弹**的，中途会出现比结算值更小的过冲帧：
///   微信 761 → 663 → 565 → 788 → 467    （结算值 601，565 与 467 都是过冲）
///    QQ   761 → 637 → 513               （结算值 639，513 是过冲）
/// 只要判据里带「取最小」，就一定会取到过冲帧；而 `truth` 每少 1，输入框就抬
/// 1 pt（三条实测式子的斜率都是 −1）—— 于是每开一次键盘就抬一档，三个过冲值
/// 轮转就是用户说的「3 档一循环」。
///
/// 所以这个量不能用任何「采样 + 归约」的办法得到，只能**钉死**。三个值都是
/// 143/142 两份日志里同一 App 反复出现过的结算值，与真机上沿 616 的关系由
/// `AevonKbNoteCalibration` 抹平；换机型/横屏时返回 0，退回原逻辑。
/// 0.1.73 — 这个函数的返回值**语义改了**：不再是「该 App 通知里报的顶边」，而是
/// **屏幕坐标下键盘真正的上沿**。Aevon(144) 把三种坐标混在一起了，先分清：
///
///   屏幕坐标（0..932）        —— 键盘真实上沿 616（中文键盘，含候选栏）
///   窗口/场景坐标（0..717）   —— 同一个上沿在这里是 401（= 616 − 215）
///
/// 我们的场景是 `430×717@215`（窗口高 717、在屏幕上从 215 开始）。App 用
/// `窗口高 − 键盘顶` 算让位，这个式子里**两个量必须同坐标系**；而 UIKit 发出来的
/// `UIKeyboardFrameEndUserInfoKey` 是**屏幕坐标**。于是微信/QQ 算出来的让位量
/// 恒少 215，输入框就整条沉进键盘 —— Aevon(144) 的两个读数把这一点钉死了：
///
///   微信  bar 底 638（屏幕）  键盘上沿 616  ⇒ 只差 22，几乎看不见
///   QQ    bar 底 740（屏幕）  键盘上沿 616  ⇒ 差 124，完全看不见
///   抖音  bar 底 427          键盘上沿 533  ⇒ 在键盘上方 106，正常
///
/// 抖音为什么没事：它把工具栏算进了键盘矩形，通知里报的顶边（611）本身就接近
/// 屏幕坐标的真值，再用 `窗口高 − 611` 也不会掉到键盘里。
///
/// 于是这里只回答一件事：**这块键盘在屏幕上从哪一行开始**。
///   616 —— QQ / 微信（中文键盘，含候选栏；`kb: top anchor measured=573 -> 616` 实测）
///   611 —— 抖音（它自报的结算值，与它自己的工具栏口径一致）
///
/// 换成窗口坐标由 `AevonKbNoteCalibration` 统一减，不再在这里混着减。
static CGFloat AevonKbTopFixed(CGFloat full) {
    // 只认本机这块 430×932 竖屏。别的尺寸键盘高度不同，钉死的值会错，宁可不用。
    if (fabs(full - 932.0) > 4.0) return 0.0;
    if (fabs(AevonKbNativeBounds(nil).size.width - 430.0) > 4.0) return 0.0;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle == nil) return 0.0;
    if ([bundle isEqualToString:@"com.tencent.mqq"]) return 616.0;
    if ([bundle isEqualToString:@"com.tencent.xin"]) return 616.0;
    if ([bundle isEqualToString:@"com.ss.iphone.ugc.Aweme"]) return 611.0;
    // 0.1.75 — **表外 App 不再返回 0。**
    //
    // 键盘上沿是「这一把键盘在屏幕上从哪一行开始」，与是哪个 App 无关：中文键盘
    // 就是 616、抖音那把（含它自己的工具栏）就是 611。返回 0 等于说「不知道」，
    // 于是 `AevonKbIntersection` 退回 `AevonKbTopSettled` —— 那是动画途中的值
    // （Aevon(146) 的 Safari：701 → 570 → 440），`truth` 随之在 231 / 362 / 492
    // 之间跳，输入框跟着上下跳。这就是「表外 App 表现怪」的直接原因，不是它们
    // 各自有什么私有公式。
    //
    // 改成返回锚点值：本机中文键盘即 616（`full − 316`，与三家同一行），truth
    // 恒定为 316，插入点位置不再随通知的到达时机变。锚点若能学到真实 `lead`
    // （300~340）会自己更新，换键盘高度也能跟。
    return AevonKbAnchorValue(full);
}

/// 0.1.75 — **每个 App 自己学到的额外让位量**（屏幕 pt）。
///
/// 为什么需要它：表外 App 分成两类，从代码上看不出来 ——
///
///   会 convert 的（绝大多数，苹果文档要求）—— 它们把通知里的屏幕坐标自己换算
///     成窗口坐标，我们**什么都不用做**，给了真值就正确。
///   不 convert 的（QQ / 微信就是这种）—— 它们直接拿 `origin.y` 当窗口坐标用，
///     让位量恒少「场景原点」215 pt，输入框整条沉进键盘。
///
/// 这两类没有可靠的静态判据（类名、是否 Swift、是否用 UIScrollView 都不作数），
/// 但**运行时能直接看出来**：键盘起来 1.9 s 后量一次输入框自己的矩形，底边到底
/// 在键盘上沿之上还是之下，一切都清楚了。被盖就说明是第二类，差多少补多少，
/// 按 Bundle 记到偏好域里，下一次开键盘直接生效。
///
/// 这就避免了「把每个 App 装一遍挨个调」：任何一个 App（包括以后新装的）第一次
/// 打开键盘时被盖，我们自己会量到并记住，第二次就是对的。
static volatile CGFloat AevonKbExtraCal = 0.0;
static volatile int AevonKbExtraLoaded = 0;

/// 从 App 自己的偏好域读回学习值。构造函数里调一次即可（读的是本地缓存，不阻塞）。
static void AevonKbExtraLoad(void) {
    if (AevonKbExtraLoaded) return;
    AevonKbExtraLoaded = 1;
    NSString *selfID = [[NSBundle mainBundle] bundleIdentifier];
    if (selfID.length == 0) return;
    CFPropertyListRef boxed = CFPreferencesCopyAppValue(CFSTR("AevonKbExtra2"),
                                                        (__bridge CFStringRef)selfID);
    if (boxed == NULL) return;
    if (CFGetTypeID(boxed) == CFNumberGetTypeID()) {
        double value = 0.0;
        if (CFNumberGetValue((CFNumberRef)boxed, kCFNumberDoubleType, &value)) {
            // 合理区间：0 表示「不需要额外让位」，320 已超过整只键盘高度。
            if (value >= -8.0 && value <= 340.0) AevonKbExtraCal = (CGFloat)value;
        }
    }
    CFRelease(boxed);
}

/// 记住学习值。写盘丢到后台队列：`CFPreferencesSetAppValue` 之后 cfprefsd 会有
/// 几十 ms 的回话等待，而这里是在主线程的输入框采样里调的，不能卡那一拍。
static void AevonKbExtraStore(CGFloat value) {
    AevonKbExtraCal = value;
    NSString *selfID = [[NSBundle mainBundle] bundleIdentifier];
    if (selfID.length == 0) return;
    CFStringRef app = (CFStringRef)CFRetain((__bridge CFStringRef)selfID);
    double payload = (double)value;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberDoubleType, &payload);
        if (num != NULL) {
            CFPreferencesSetAppValue(CFSTR("AevonKbExtra2"), num, app);
            CFRelease(num);
        }
        CFRelease(app);
    });
}

// MARK: - 0.1.78 安全区让位（第四条通道，只给「学出来确实被盖」的 App）

/// 前三条通道（通知矩形 / 交集 / 键盘布局参考线）对 Safari 全部无效：
/// Aevon(149) 里 `out` 从 424 改到 616、`inter true=316 sys=101`、
/// `guide fill h=316 top=401` 三样全对，而 Safari 的地址栏胶囊
/// （`UnifiedField`）一直停在 `bar=713..758`（屏幕坐标，键盘上沿 616）——
/// 一像素没动。它既不读通知矩形，也不读参考线的**返回值**。
///
/// 这三条通道有个共同点：**都在改「告诉 App 什么」，而不是改「App 的可用区域」**。
/// 而 App 把输入框摆在窗口底边时，唯一它一定服从的量是它自己的安全区。
/// 所以这一条通道直接改那个：
///
///   rootViewController.additionalSafeAreaInsets.bottom += 键盘遮住的高度
///
/// 效果等同「原生键盘把窗口撑矮」：可用区从 0..717 变成 0..401，任何把内容摆在
/// 可用区底部的 App（Safari 的底栏胶囊正是这一类）都必须上移 316 —— 上移到
/// 屏幕 616，正好在键盘上沿。
///
/// 为什么可以改：它是**本进程里、App 自己的**视图控制器上的公开属性，
/// 不碰 `UIScreen`、不碰窗口几何、不碰系统返回值 —— 与前三次黑屏的那类改动
/// 无关。收起时按存档原样还回（`AevonKbSafeRestore`），失败也只是「没效果」，
/// 不会留下错位。
///
/// 三道闸门，缺一不可：
///   ① 只在**学过**的 Bundle 上生效（`AevonKbSafe`，默认 0）—— 会自己让位的
///      App 一个字节都不碰，否则就是 0.1.69 的「让两次」；
///   ② 只在键盘在屏时写（`AevonKbOn`），收起立刻还原；
///   ③ 学习判据与 `extra` 那条完全一样：1.9 s 稳态量到输入框底边仍在键盘上沿
///      之下，才认为这个 App 不会让位。
static volatile int AevonKbSafeFlag = -1;      // -1 未读，0 不需要，1 需要
static volatile int AevonKbSafeOn = 0;         // 本会话有没有写过
static volatile CGFloat AevonKbSafeSaved = -1.0;   // 原始 bottom，写之前存一次
/// 0.1.83 — 连着几次采样「写进去了还被盖」。两次就撤销安全区（见 `AevonKbCaretNote`）。
static volatile int AevonKbSafeStuck = 0;
/// 0.1.83 — 这个 App 已经被判过「不吃安全区」。本进程内不再尝试，否则
/// 「升级 → 无效 → 撤销 → 下一拍又升级」会变成一个 0.7 s 的布局抖动环。
static volatile int AevonKbSafeBanned = 0;

static void AevonKbSafeLoad(void) {
    if (AevonKbSafeFlag >= 0) return;
    AevonKbSafeFlag = 0;
    NSString *selfID = [[NSBundle mainBundle] bundleIdentifier];
    if (selfID.length == 0) return;
    CFPropertyListRef boxed = CFPreferencesCopyAppValue(CFSTR("AevonKbSafe"),
                                                        (__bridge CFStringRef)selfID);
    if (boxed == NULL) return;
    if (CFGetTypeID(boxed) == CFNumberGetTypeID()) {
        int value = 0;
        if (CFNumberGetValue((CFNumberRef)boxed, kCFNumberIntType, &value) && value == 1) {
            AevonKbSafeFlag = 1;
        }
    }
    CFRelease(boxed);
}

static void AevonKbSafeStore(int on) {
    AevonKbSafeFlag = on ? 1 : 0;
    NSString *selfID = [[NSBundle mainBundle] bundleIdentifier];
    if (selfID.length == 0) return;
    CFStringRef app = (CFStringRef)CFRetain((__bridge CFStringRef)selfID);
    int payload = on ? 1 : 0;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &payload);
        if (num != NULL) {
            CFPreferencesSetAppValue(CFSTR("AevonKbSafe"), num, app);
            CFRelease(num);
        }
        CFRelease(app);
    });
}

/// App 自己的根视图控制器。取不到返回 nil（`keyWindow` 优先，退回第一个有 VC 的）。
static UIViewController *AevonKbRootVC(void) {
    if (![NSThread isMainThread]) return nil;
    UIViewController *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *vc = window.rootViewController;
            if (vc == nil) continue;
            if (window.isKeyWindow) return vc;
            if (fallback == nil) fallback = vc;
        }
    }
    return fallback;
}

/// 把「键盘遮住的这一段」加进安全区。重复调用幂等（存的是**原始** bottom）。
static void AevonKbSafeApply(CGFloat cover) {
    if (![NSThread isMainThread]) return;
    AevonKbSafeLoad();
    if (AevonKbSafeFlag != 1) return;
    if (AevonKbOn == 0) return;
    if (cover < 40.0) return;
    UIViewController *vc = AevonKbRootVC();
    if (vc == nil) return;
    UIEdgeInsets now = vc.additionalSafeAreaInsets;
    if (AevonKbSafeSaved < 0.0) AevonKbSafeSaved = now.bottom;
    CGFloat want = AevonKbSafeSaved + cover;
    BOOL already = AevonKbSafeOn != 0 && fabs(now.bottom - want) < 1.0;
    if (already) return;
    UIEdgeInsets next = now;
    next.bottom = want;
    vc.additionalSafeAreaInsets = next;
    AevonKbSafeOn = 1;
    char line[200];
    snprintf(line, sizeof(line),
             "kb: safe inset bottom=%.0f was=%.0f cover=%.0f\n",
             want, AevonKbSafeSaved, cover);
    AevonKbLog(line);
}

static void AevonKbSafeRestore(void) {
    if (AevonKbSafeOn == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ AevonKbSafeRestore(); });
        return;
    }
    AevonKbSafeOn = 0;
    CGFloat saved = AevonKbSafeSaved;
    AevonKbSafeSaved = -1.0;
    UIViewController *vc = AevonKbRootVC();
    if (vc == nil || saved < 0.0) return;
    UIEdgeInsets now = vc.additionalSafeAreaInsets;
    UIEdgeInsets next = now;
    next.bottom = saved;
    vc.additionalSafeAreaInsets = next;
    char line[160];
    snprintf(line, sizeof(line), "kb: safe inset restored bottom=%.0f\n", saved);
    AevonKbLog(line);
}

static CGFloat AevonKbNoteCalibration(void) {
    AevonKbExtraLoad();
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle == nil) return 0.0;
    // 0.1.73 — 这个量**不再是「每个 App 的输入条厚度」那种拟合值**，它是一个几何量：
    // 场景原点在屏幕上的 y（本机 215）。减掉它，通知里的键盘顶就从屏幕坐标变成
    // 窗口坐标，App 的 `窗口高 − 键盘顶` 才两个量同系。
    //
    // 前面六个版本的弯路值得记一笔，免得再走回去：
    //   0.1.67~0.1.70  把它当成「各 App 多铺的那一截」（52 / 90 / 54 / 243 反复调），
    //                  每次都能用两份日志解出一个「唯一解」，换一份日志就崩 ——
    //                  因为那些方程本身是在拟合噪声，不是在描述几何。
    //   0.1.71         键盘顶「只降不升」⇒ 取到动画过冲帧 ⇒ 每开一次键盘抬一档。
    //   0.1.72         顶边钉死，truth 恒定了，但**基准仍然是屏幕坐标**，所以
    //                  QQ/微信的让位量恒少 215，输入框整条沉进键盘。
    //
    // 0.1.73 只做一件事：把基准统一。同一份 Aevon(144) 日志里三个 App 的读数
    // 一摆就清楚了 —— 抖音正常的那条 `bar` 底 427 用的是屏幕坐标，微信沉下去
    // 的那条 638 也是屏幕坐标，两者差的就是「App 以为窗口底在哪一行」。
    //
    // 抖音给 0：它自报的顶边 611 本来就是屏幕坐标、且与它自己的工具栏口径一致，
    // 减 215 反而会让它对不上（0.1.70 已实测正常，不动）。
    // 0.1.74 — 215 → 260：补上「输入条下面那一行工具按钮」。
    //
    // Aevon(145) 把三种界面摆在一起，缺的那一截才现形。`bar` 是屏幕坐标，
    // 键盘真实上沿 616，于是「露多少」可以直接算：
    //
    //   抖音            bar 底 427   ⇒ 在键盘上方 189，正常
    //   QQ「我的电脑」  bar 底 556   ⇒ 上方 60，正常（用户确认）
    //   QQ 群内         bar 底 596   ⇒ 上方 20，**被盖**
    //   微信            bar 底 604   ⇒ 上方 12，**只露一点点**
    //
    // 注意 `bar` 量的是 `NTBaseAIO.NTAIOInputRichAndTextView` / `MMTextView`
    // 自己的矩形 —— 那只是**文本输入区**，它下面还有一行按钮（表情/图片/语音）。
    // 用户看到的「输入条被盖住」盖的正是那一行：文本区在 616 以上，按钮行在下面。
    // QQ「我的电脑」没有那一行，所以同一个 App 里的两种界面表现不同。
    //
    // 斜率是实测的（0.1.72 → 0.1.73，`out` 与 `bar` 底同时变）：
    //   微信 out 435→401（−34）· bar 638→604（−34）  ⇒ 1.00，一对一
    //   QQ   out 585→401（−184）· bar 740→596（−144）⇒ 0.78
    // 要把微信从 604 抬到 ~558、QQ 群从 596 抬到 ~558，反解 `out` 要再降 45：
    //   out = 616 − 260 = 356 ⇒ 微信 604−45 = 559、QQ 群 596−35 = 561，都在 616 上方 55+
    // QQ「我的电脑」同时从 556 抬到 ~521，仍远在键盘上方，不影响它的「正常」。
    //
    // ⚠️ 260 这个数只由两条实测斜率反解，没有第三点验证。抖音仍然是 0 ——
    // 它本来就正常，且它对 `out` 的依赖方式与这两个不同。
    // 抖音：它自己把工具栏算进键盘矩形，口径与别人不同，本机实测它**不用任何
    // 换算**就是对的（`out=611 cal=0 fixed=611` ⇒ `bar` 底 427）。别给它加减法。
    if ([bundle isEqualToString:@"com.ss.iphone.ugc.Aweme"]) return 0.0;
    CGFloat extra = AevonKbExtraCal;
    // 场景原点：屏幕坐标 → 窗口坐标的那一截。缓存没写就先按本机竖屏兜底。
    CGFloat full = AevonKbNativeBounds(nil).size.height;
    CGFloat origin = AevonKbSceneOriginCache;
    if (origin < 1.0 || origin > 400.0) origin = (fabs(full - 932.0) < 4.0) ? 215.0 : 0.0;
    // QQ / 微信：不 convert，基准要减掉 215；另外它们的输入条下面还有一行工具
    // 按钮（表情/图片/语音），实测要多让 45 才能整行露出，故 215 + 45 = 260。
    if ([bundle isEqualToString:@"com.tencent.mqq"]
        || [bundle isEqualToString:@"com.tencent.xin"]) {
        return origin + 45.0 + extra;
    }
    // 表外 App：默认 0 —— 它们自己会 convert，给了真值就正确。只有被量到「确实
    // 被盖」时才靠 `AevonKbExtraCal` 补上（见 `AevonKbCaretNote` 末尾的学习段）。
    //
    // 0.1.80 — 删掉 0.1.77 的「走 guide 的就不再加通知补偿」。那条分支的前提是
    // `AevonKbGuideFilled` 会被置位，而 0.1.80 起参考线不再喂值（理由写在
    // `AevonKbGuideFrame`），标志永远不会亮 —— 留着只会让下一版读代码的人
    // 以为还有第二条通道在生效。
    return extra;
}

static void AevonKbLog(const char *line) {
    if (line == NULL) return;
    AevonAppLogWrite(line);
}

/// 换算过程的四个数。判据全靠这一行：`h`（系统给的原始交点高）、`screen`（屏高）、
/// `kbwin`（键盘窗高）、`scene`（承载场景自己的高度）四个数一比，就知道母本那条
/// 式子在这台机器上算出什么，下一版按真数调，不再靠推。
///
/// 0.1.44 加 `scene`：Aevon(117) 的 `app: geom early` 显示承载时
/// `scene=430x717`（屏是 430x932），键盘是在这个 717 高的画布里排的 ——
/// 「只露一条工具栏」很可能出在这里，不是出在屏幕尺寸上。
static void AevonKbLeadNote(double h, double screen, double full, double kbwin, double scene,
                            double out, int took) {
    if (AevonKbLeadNotes >= 12) return;
    AevonKbLeadNotes += 1;
    char line[260];
    snprintf(line, sizeof(line),
             "kb: lead h=%.1f screen=%.1f full=%.1f base=%.1f scene=%.1f -> %.1f took=%d\n",
             h, screen, full, kbwin, scene, out, took);
    AevonKbLog(line);
}

/// 本机的整屏尺寸（pt）。母本用的是 `-_boundsForInterfaceOrientation:`；那是私有
/// 方法，这里用公开的 `nativeBounds / nativeScale` 得到同一个数，拿不到就退回
/// 430×932 的物理基准，绝不返回一个猜出来的更大值。
static CGRect AevonKbNativeBounds(UIScreen *screen) {
    if (screen == nil) screen = [UIScreen mainScreen];
    CGRect native = screen.nativeBounds;
    CGFloat scale = screen.nativeScale;
    if (scale > 0.01 && native.size.width > 1 && native.size.height > 1) {
        return CGRectMake(0, 0, native.size.width / scale, native.size.height / scale);
    }
    return CGRectMake(0, 0, 430, 932);
}

/// 键盘窗口实例。
///
/// 0.1.44 — 0.1.43 的真机日志（Aevon(117)）里 `kb: no keyboard window` 一共出现
/// 六次（设置 3 次、QQ 3 次），也就是说键盘一次都没被换算过。原因是取值链：
/// 上一版走的是 `[_UIRemoteKeyboards activeInstance]`，而 `activeInstance` 在
/// `_UIRemoteKeyboards` 上是**实例方法**；对类对象问 `+respondsToSelector:`
/// 恒为 NO ⇒ mgr 恒为 nil ⇒ 恒返回 nil。
///
/// 母本不是这么取的：`0x52fc mov x0, x23`（x23 = self，钩子的第一个参数，也就是
/// manager 自己）紧接着 `bl keyboardWindow` 桩。所以这里也优先用 self，拿不到
/// 再退回类方法。
static id AevonKbWindowNow(id keyboardManager) {
    SEL win = sel_registerName("keyboardWindow");
    if (keyboardManager != nil && [keyboardManager respondsToSelector:win]) {
        id window = ((id (*)(id, SEL))objc_msgSend)(keyboardManager, win);
        if (window != nil) return window;
    }
    static Class kb = Nil;
    if (kb == Nil) kb = objc_getClass("_UIRemoteKeyboards");
    if (kb == Nil) return nil;
    SEL active = sel_registerName("activeInstance");
    if (![kb respondsToSelector:active]) return nil;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(kb, active);
    if (mgr == nil || ![mgr respondsToSelector:win]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(mgr, win);
}

/// 闸门：卡片承载中 + 开关没关 + **卡片外框明显小于屏幕**。
///
/// 第三条是 0.1.43 补的。0.1.42 的黑屏说明 `AevonBandOn` 不够：它是「宿主写过
/// 卡片几何」的意思，卡片关掉之后可能还停在 1（宿主清得比 App 启动晚），于是
/// 全屏打开的 App 也进了改几何的分支。换成看得见的东西：外框必须比屏幕小一截。
static BOOL AevonKbHostGate(void) {
    if (AevonBandOn == 0) return NO;
    if (!AevonKbNativeAllowed()) return NO;
    CGSize screen = AevonKbNativeBounds(nil).size;
    if (screen.width < 1 || screen.height < 1) return NO;
    if (AevonBandOuter.size.width < 1 || AevonBandOuter.size.height < 1) return NO;
    return (AevonBandOuter.size.width <= screen.width - 8.0)
        || (AevonBandOuter.size.height <= screen.height - 8.0);
}

// ===== 0.1.47 — 键盘「整体上移」，让它在卡片里整块可见 =====
//
// Aevon(119) 的日志把几何钉死了：
//
//   kb: lead h=101.0 screen=717.0 full=932.0 kbwin=932.0 scene=717.0 -> 316.0 took=3
//
// `kbwin=932` ⇒ `UIRemoteKeyboardWindow` 是一个**整屏高**的窗口（430×932），键盘
// 内容贴它自己的底部，即 616..932。`scene=717` ⇒ 承载场景只有 717 高，渲染只放行
// 到 717。两句话合起来就是看得见的部分：616..717 = **101 pt**，正好是截图里那三行
// （工具栏 + 表情行 + 一行键）。
//
// 换算（`intersectionHeight` 返回 316）只决定「App 该让出多少」，**决定不了键盘
// 画在哪** —— 0.1.45 改它零变化，已经证伪。
//
// 真正的修法只有一条：把键盘窗自己往上搬，让它的底边压在场景底边上，内容整块
// 落进场景。视频（Stheno 分屏）里键盘在浮窗之外按原生尺寸显示，视觉结果一致。
//
// ⛔ 为什么是 `transform` 而不是 frame / bounds：0.1.42 改过键盘窗的几何（把它
// 撑成整屏），真机结果是「所有 App 打开时黑屏，无论悬浮窗还是全屏」。平移只碰
// `transform`，窗口自己的 bounds 一像素都不动。这条纪律与「改几何只碰
// bounds/center/transform」同源，但更严格：连 bounds 都不碰。

static volatile int AevonKbLiftNotes = 0;

/// intersection 钩子里取到的键盘窗（真机证实非空：`kb: lead … kbwin=932`）。
///
/// 0.1.47 只靠扫 `connectedScenes[].windows` 找 `UIRemoteKeyboardWindow`，
/// Aevon(120) 的日志里连一条 `kb: lift` 都没有 —— 说明那条扫法一个都没扫到，
/// 函数在取窗处静默返回，整版等于没做。这里把 intersection 钩子那只留住：
/// 扫不到就用它。retain 住不放 —— 一个窗口对象而已，换来的是一条永远不会
/// 指向野指针的引用（窗口被回收时对象仍在，写 transform 是无害的空操作）。
static UIView *AevonKbKeptWindow = nil;
static int AevonKbKeptSource = 0;   // 1 = intersection 钩子给的，2 = 扫场景给的
/// 0.1.80 — 最近一次**真的量到**的键盘顶边（屏幕坐标）。
///
/// 只用来回答一个问题：「窗还在屏上、可这一拍量不到」时，键盘到底还在不在。
/// Aevon(150) 的 31 条 `top zero` 全是这个形状（满屏、可见、sub=1），而它们
/// 前后 0.75 s 的读数都是 573/616 —— 键盘一直在。缓存在这里，量不到时把它
/// 还回去，上层就不会再把「重排空窗」读成「键盘收了」。
static CGFloat AevonKbLastTop = 0.0;

/// 键盘窗本体。App 进程里它是 `UIRemoteKeyboardWindow` 的实例，挂在承载场景的
/// `windows` 数组里。**只用运行时事实取**：类名比对 + 数组遍历，不问任何可能抛
/// 异常的东西（`valueForKey:` 那条路在 0.1.39 已经杀过一次进程）。
///
/// 0.1.44 的教训在这里复用：`_UIRemoteKeyboards +activeInstance` 是**实例**方法，
/// 对类对象问 `respondsToSelector:` 恒为 NO ⇒ 那条取值链恒返回 nil。所以这里
/// 不用管理器，直接扫窗口。
/// 0.1.83 — **进程里的全部窗口，不只是「本 App 那个场景的」。**
///
/// Aevon(151) 把这条路量死了：一次会话里 24 次 `kb: caret … kb=0`（QQ / 微信 /
/// 抖音 / 酷安全部），而同一时段用户在这些 App 里正常打字 —— 键盘明明在屏上，
/// 我们却一次都没量到过它。
///
/// 原因是 `connectedScenes` 里根本不含键盘那只窗所在场景（键盘在 iOS 17 有自己
/// 的 window scene），所以 `scene.windows` 永远是空的。0.1.82 新增的「必须还在
/// 窗口栈里」那道闸门因此**恒假**，每次测量都当场返回 -1（＝收起）——
/// `caret kb=0`、`idle zero close`、`settle gone`、卡片缩回去又张开，
/// 全都是它的下游。
///
/// `+[UIWindow _allWindowsIncludingInternalWindows:onlyVisibleWindows:]` 是
/// 进程级的窗口总表（UIKit 自己用它做命中测试与快照），跨场景、含内部窗口。
/// 拿不到就退回老的两条路，行为与 0.1.79 一致 —— 绝不让一条私有接口的缺失
/// 变成「键盘永远不在」。
static NSArray *AevonKbAllWindows(void) {
    static int supported = -1;
    if (supported == -1) {
        Class w = objc_getClass("UIWindow");
        SEL s = sel_registerName("_allWindowsIncludingInternalWindows:onlyVisibleWindows:");
        supported = (w != Nil && class_respondsToSelector(object_getClass(w), s)) ? 1 : 0;
    }
    if (supported == 1) {
        SEL s = sel_registerName("_allWindowsIncludingInternalWindows:onlyVisibleWindows:");
        id boxed = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(objc_getClass("UIWindow"), s, YES, NO);
        if ([boxed isKindOfClass:[NSArray class]] && [(NSArray *)boxed count] > 0) return boxed;
    }
    NSMutableArray *fallback = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) [fallback addObject:window];
    }
    return fallback;
}

/// 键盘窗的候选池 + 打分。**不再「第一只就是它」。**
///
/// 同一个进程里可以同时存在两只 `UIRemoteKeyboardWindow`：上一轮会话留下来的
/// （`hidden=1`、子视图已被拆空）和这一轮在用的。0.1.82 之前取「第一只」，
/// 拿到哪只全看数组顺序 —— 于是有时量到 573、有时量到 0，日志里那 31 条
/// `top zero win=430x932@0 hid=0 sub=1` 和这份日志里 13 条 `kb: gone hid=1`
/// 是同一件事的两种形状。
///
/// 打分只看「像不像在画的键盘」：没隐藏 > 不透明 > 尺寸对。全为 0 分时返回
/// 第一只（与老行为一致，至少不会把「有窗」变成「没窗」）。
static UIView *AevonKbWindowPick(int *poolOut, int *visibleOut) {
    Class keyboardClass = objc_getClass("UIRemoteKeyboardWindow");
    if (keyboardClass == Nil) return nil;
    if (![NSThread isMainThread]) return nil;
    UIView *best = nil;
    int bestScore = -1;
    int pool = 0;
    int visible = 0;
    NSArray *all = AevonKbAllWindows();
    for (id cand in all) {
        if (![cand isKindOfClass:keyboardClass]) continue;
        UIWindow *win = (UIWindow *)cand;
        pool += 1;
        int score = 0;
        if (!win.hidden) score += 4;
        if (win.alpha > 0.05) score += 2;
        CGSize box = win.bounds.size;
        if (box.width > 200.0 && box.height > 200.0) score += 1;
        if (score >= 6) visible += 1;
        if (score > bestScore) { bestScore = score; best = win; }
    }
    if (poolOut != NULL) *poolOut = pool;
    if (visibleOut != NULL) *visibleOut = visible;
    return best;
}

static UIView *AevonKbWindowScan(void) {
    return AevonKbWindowPick(NULL, NULL);
}

/// 0.1.58 — 键盘**视觉实体**的顶边（屏幕坐标，本机 616；带候选栏 643）。取不到返回 0。
///
/// Aevon(130) 把「不能再信通知帧」这件事钉死了。三个 App 的
/// `UIKeyboardFrameEndUserInfoKey.origin.y` 报出来的是 `717 / 744 / 761 / 788`，
/// 折成键盘高只有 `215 / 188 / 171 / 144`，而 `kb: guide … seen=717/788` 两次采样
/// 都是同一批数 —— 那不是动画中间帧，是这套环境里 UIKit 报的键盘矩形只覆盖
/// 屏幕最底一截（717..932，正好是场景底边 717 往下 215 pt）。
///
/// 换句话说：场景被搬到 215 之后，`UIKeyboardFrameEndUserInfoKey` 回答的是
/// 「键盘超出场景的那部分」，不是「键盘在哪」。拿它当顶边，卡片底边就永远
/// 落在 717/744/761/788 —— 全都比真实键盘顶 616 低，键盘照样盖住输入框。
///
/// 所以这里改成**量**。键盘窗（`UIRemoteKeyboardWindow`，本机 430×932、底边
/// 贴屏幕底 932）里那块真键盘是可见的：宽≈窗宽、底边≈窗底、高在 200..460 之间。
/// 取最靠上的那个（完整键盘 316 比只剩候选栏时高）。整条链只读 `bounds`/`frame`，
/// 不碰任何 UIKit 的几何返回值。
/// 0.1.80 — 返回值分成三种，**这是这一版最要紧的一处**。
///
///   > 0  屏幕坐标的键盘顶边（真的量到了）
///     0  窗在屏、也不是透明的，但这一拍没找到键盘视图 —— **重排中的空壳**
///   < 0  这只窗根本不是「在屏的键盘」：nil / hidden / 透明 / 尺寸不对 / 已经不在
///        场景的窗口栈里
///
/// 0.1.78 把前两种都返回 0，于是「这一拍没量到」被上层当成了「键盘收了」。
/// Aevon(150) 把这件事钉死了：31 条 `kb: top zero win=430x932@0 hid=0 sub=1`
/// —— **每一条的窗都是满屏、可见、没隐藏**，只有子视图数掉到 1（`UIWindow`
/// 本来就只有 `UIInputSetContainerView` 一个子视图，重排时它下面那一层还没接上）。
/// 也就是说这 31 次「量不到」没有一次是键盘真的走了，可它们各自触发了一次
/// `settle gone`（22 次）→ `app: keyboard gone` → `fill off`。
static CGFloat AevonKbTopInWindow(UIView *keyboardWindow) {
    if (keyboardWindow == nil) return -1.0;
    CGRect box = keyboardWindow.bounds;
    CGFloat winW = box.size.width;
    CGFloat winH = box.size.height;
    // 0.1.78 — **键盘窗不总是满屏高。**
    //
    // 旧判据是 `winH < 400 ⇒ 返回 0`，等于默认它恒为 430×932。Aevon(149) 证明
    // 这个默认是错的：每个键盘周期里 0.75 s 那一次量到 573（窗 430×932），
    // 1.9 s 那一次量到 0，而同一刻连第一响应者都找不到
    // （`kb: caret none … scout=413` —— 413 个节点是空壳窗的量级）。那一刻
    // `isKeyWindow` 落在了键盘窗上，而它的 `bounds` 已经收成 430×316。旧判据把
    // 「窗变小」读成了「键盘没了」。
    //
    // 30 次假收起里每一次都跟着一条 `measure=0`，每一次 `settle gone` 后面
    // 一秒又被心跳重新张开 —— 用户看到的就是「先缩小再放大」和「不还原」。
    // 所以高度闸门放到 120：完整键盘 316、只剩候选栏 291、带工具栏 401 全过。
    if (winW < 200.0 || winH < 120.0) return -1.0;
    // 0.1.83 — **「窗藏起来了」不再自成一证。**
    //
    // Aevon(151) 里 13 条 `kb: gone hid=1 alpha=1.00 win=430x932` 和 24 次
    // `caret … kb=0` 同时成立，而用户在 QQ / 抖音里照常打字 —— 说明我们手里
    // 这只窗不是正在画的那一只（上一轮会话留下的空壳）。只看 `hidden` 就等于
    // 让「拿到了旧窗」变成「键盘没了」。
    //
    // 现在要**两条互相独立的事实**同时成立才认收起：
    //   ① 窗本身 hidden / 透明 / 滑出屏幕底；
    //   ② 最近一条键盘通知也把矩形判成离屏（`AevonKbNoteActive == 0`）。
    // 只有①成立时，语义是「这一拍不可测」，交给 `AevonKbVisualTop` 沿用上次真值。
    BOOL noteActive = (AevonKbNoteActive != 0);
    if (keyboardWindow.hidden || keyboardWindow.alpha < 0.05) {
        if (noteActive) return 0.0;
        // 0.1.80 — **这一行是「真收起」的唯一证词**。
        //
        // 旧版把这条与「量不到」混在一起返回 0，日志里根本分不清是哪种，
        // 于是 0.1.78 只能靠猜。现在真收起有自己的一行，下一次日志里
        // `kb: gone` 的出现次数就该和用户真的关了几次键盘一一对应。
        static int goneNotes = 0;
        if (goneNotes < 8) {
            goneNotes += 1;
            int pool = 0;
            int visible = 0;
            AevonKbWindowPick(&pool, &visible);
            char line[200];
            snprintf(line, sizeof(line),
                     "kb: gone hid=%d alpha=%.2f win=%.0fx%.0f pool=%d vis=%d\n",
                     keyboardWindow.hidden ? 1 : 0, keyboardWindow.alpha, winW, winH,
                     pool, visible);
            AevonKbLog(line);
        }
        return -1.0;
    }
    // 0.1.78 — 窗自己在屏幕上的原点：满屏时 0，收短时 616。返回值要加它。
    //
    // `windowScene` 是 `UIWindow` 的属性，不是 `UIView` 的（0.1.78 第一版直接
    // `keyboardWindow.windowScene` 被 CI 拦在编译期：property 'windowScene' not
    // found on object of type 'UIView *'）。这里按类判断一次。
    CGFloat originY = keyboardWindow.frame.origin.y;
    UIWindowScene *owner = nil;
    if ([keyboardWindow isKindOfClass:[UIWindow class]]) {
        owner = ((UIWindow *)keyboardWindow).windowScene;
    } else {
        owner = keyboardWindow.window.windowScene;
    }
    if (owner != nil) {
        CGRect onScreen = [keyboardWindow convertRect:keyboardWindow.bounds
                                    toCoordinateSpace:owner.screen.coordinateSpace];
        if (onScreen.size.height > 1.0) originY = onScreen.origin.y;
    }
    // 0.1.80 — **窗被推到屏幕底以下 = 收起**。
    //
    // 除了 hidden，另一种收法是「整只窗往下滑出屏幕」：形状还是 430×932，
    // 只是原点变成 932 以上。这条和 hidden 一样是几何事实，不需要看子视图。
    // 阈值放到「屏高 − 80」：正常键盘态窗原点是 0，只有真的滑出去才会过线。
    CGFloat screenH = AevonKbNativeBounds(nil).size.height;
    if (screenH > 400.0 && originY > screenH - 80.0) {
        if (noteActive) return 0.0;   // 同上：一条事实不够，交给上次真值
        static int slidNotes = 0;
        if (slidNotes < 8) {
            slidNotes += 1;
            char line[150];
            snprintf(line, sizeof(line), "kb: gone slid win=%.0fx%.0f@%.0f\n",
                     winW, winH, originY);
            AevonKbLog(line);
        }
        return -1.0;
    }
    // 广度优先，最多 4 层、160 个视图：键盘的宿主视图链很短
    // （`UIInputSetContainerView` → `UIInputSetHostView` → `_UIKeyboardView`），
    // 不需要更深的遍历，也不该在键盘通知里做无界递归。
    NSMutableArray *queue = [NSMutableArray arrayWithObject:keyboardWindow];
    NSMutableArray *levels = [NSMutableArray arrayWithObject:@0];
    NSUInteger head = 0;
    CGFloat best = 0.0;
    BOOL found = NO;
    while (head < queue.count && head < 160) {
        UIView *view = queue[head];
        NSInteger level = [levels[head] integerValue];
        head += 1;
        if (level >= 4) continue;
        for (UIView *child in view.subviews) {
            CGRect frame = [child convertRect:child.bounds toView:keyboardWindow];
            if (frame.size.width >= winW * 0.85
                && frame.size.height > 120.0 && frame.size.height < 460.0
                && fabs(CGRectGetMaxY(frame) - winH) < 6.0) {
                if (!found || frame.origin.y < best) { best = frame.origin.y; found = YES; }
            }
            [queue addObject:child];
            [levels addObject:@(level + 1)];
        }
    }
    if (!found) {
        static int zeros = 0;
        if (zeros < 8) {
            zeros += 1;
            char line[200];
            snprintf(line, sizeof(line),
                     "kb: top zero win=%.0fx%.0f@%.0f hid=%d sub=%lu last=%.0f\n",
                     winW, winH, originY,
                     keyboardWindow.hidden ? 1 : 0,
                     (unsigned long)keyboardWindow.subviews.count,
                     AevonKbLastTop);
            AevonKbLog(line);
        }
        return 0.0;
    }
    // 0.1.78 — 返回值改成**屏幕坐标**。
    //
    // 窗满屏（430×932@0）时窗内坐标与屏幕坐标恰好相等，573 这个历史读数一位
    // 都不变；窗收短（430×316@616）时窗内坐标是 0，按老约定会被当成「量不到」。
    // 加上窗自己的原点，两种形状给出同一个数（616），上层的一切标定都不用动。
    return originY + best;
}

/// 0.1.80 — **0 现在只有一个含义：键盘窗不在屏上。**
///
/// 0.1.78 想靠「两次独立测量都为 0」拦住假收起，Aevon(150) 证明这条路走不通：
/// 22 次 `settle gone` 里 retry 全是 1（0.40 s 复量也跑了），**两次都是 0** ——
/// 因为那个 0 不是抖动，是键盘每次弹起约 1 s 后都会出现的一段稳定空窗
/// （`top zero win=430x932@0 hid=0 sub=1`，31/31 一模一样）。多量几次只是把
/// 同一个错答案抄两遍。
///
/// 所以判据改成问**窗**，不再问子视图遍历：
///
///   窗 hidden / 透明 / 尺寸不对 / 已不在窗口栈  ⇒ 真的收了 ⇒ GONE
///   窗在屏、只是这一拍没量到子视图            ⇒ 不可测     ⇒ SHELL
///   遍历量到那块键盘                          ⇒ 真的在     ⇒ TOP
///
/// 后两种情况下还回去的数字是「上一次真的量到的顶边」，不是常量 —— 带候选栏时
/// 它是 643，只有主键盘时是 616，两种形状都不会被抹平。**但那个数字不能用来判
/// 收起**：Aevon(152) 里 8 次真收起全被它判成「键盘还在」（详见 `AevonKbSettleWait`），
/// 所以收起只认 `stateOut`，数字只给「现在键盘顶在哪」这种画几何的调用点用。
static CGFloat AevonKbVisualTopState(int *stateOut) {
    if (stateOut != NULL) *stateOut = AevonKbStateShell;
    if (![NSThread isMainThread]) return 0.0;
    UIView *kept = AevonKbKeptWindow;
    CGFloat best = AevonKbTopInWindow(kept);
    if (best > 1.0) {
        AevonKbLastTop = best;
        if (stateOut != NULL) *stateOut = AevonKbStateTop;
        return best;
    }
    // 0.1.83 — **再试两条来源，量到了就换窗。**
    //
    // 手里那只（`AevonKbKeptWindow`，多半是交集钩子给的）量不到时，可能是
    // 这一拍还没结算，也可能它根本是上一轮会话的空壳。Aevon(151) 里后者已经
    // 被证实：同一只窗连着 3 次量到 0、同时 13 条 `kb: gone hid=1`，而键盘
    // 在屏上。只靠 `connectedScenes` 里的 `UIRemoteKeyboardWindow` 重扫是
    // 换不了窗的 —— 键盘窗不在那些场景里（见 `AevonKbAllWindows`）。
    // 所以这里多问一次键盘管理器自己（`_UIRemoteKeyboards.activeInstance`），
    // 它手上那只才是正在画的那一只。
    UIView *candidates[2] = { AevonKbWindowScan(), (UIView *)AevonKbWindowNow(nil) };
    for (int i = 0; i < 2; i++) {
        UIView *cand = candidates[i];
        if (cand == nil || cand == kept) continue;
        CGFloat again = AevonKbTopInWindow(cand);
        if (again > 1.0) {
            [AevonKbKeptWindow release];
            AevonKbKeptWindow = [cand retain];
            AevonKbKeptSource = 2;
            char line[180];
            snprintf(line, sizeof(line), "kb: adopt top=%.0f hud=%d win=%.0fx%.0f src=%d\n",
                     again, cand.hidden ? 1 : 0,
                     cand.bounds.size.width, cand.bounds.size.height, i);
            AevonKbLog(line);
            AevonKbLastTop = again;
            if (stateOut != NULL) *stateOut = AevonKbStateTop;
            return again;
        }
        // 这只窗在屏、只是这一拍没量到 ⇒ 是空窗，不是「收了」。
        if (again == 0.0 && best < 0.0) best = 0.0;
    }
    // 三处都判「不在屏上」⇒ 真的收了。
    if (best < 0.0) {
        if (stateOut != NULL) *stateOut = AevonKbStateGone;
        return 0.0;
    }
    // 窗在屏、量不到 ⇒ 空壳。**状态要如实报出去。**
    //
    // 0.1.84 — 这里只回答「不可测」。旧版把它折成一个「上次真值」的数字返回，
    // 上层拿 `top > 200` 当「键盘还在」⇒ Aevon(152) 里每一次真收起都被判成
    // `settle keep top=573`（573 = 缓存值，不是任何一次当拍读数）⇒ 收起被作废，
    // 只剩 1 Hz 的 `idle zero close` 三连零兜底 ⇒ 用户量到 5~10 s 才还原。
    if (AevonKbLastTop > 200.0) return AevonKbLastTop;
    return 0.0;
}

/// 只要一个数（老调用点：光标、参考线、发布）。**收起判定一律改用上面那个三态版**，
/// 因为「沿用上次真值」这个便利恰恰会抹掉「键盘已经走了」这件事。
static CGFloat AevonKbVisualTop(void) {
    return AevonKbVisualTopState(NULL);
}

/// 承载场景的高（本机 717）。取不到返回 0。
static CGFloat AevonKbSceneHeightNow(void) {    if (![NSThread isMainThread]) return 0.0;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowed = (UIWindowScene *)scene;
        UISceneActivationState state = windowed.activationState;
        if (state != UISceneActivationStateForegroundActive &&
            state != UISceneActivationStateForegroundInactive) continue;
        CGSize size = windowed.coordinateSpace.bounds.size;
        if (size.width > 100.0 && size.height > 200.0) return size.height;
    }
    return 0.0;
}

/// 0.1.52 — **承载场景在屏幕坐标里的矩形**（原点 + 尺寸）。
///
/// 换掉 0.1.51 的 `AevonKbWindowTopNow()`。那个函数读主窗的 `frame.origin.y`，
/// 可 App 的窗口恒坐在**场景坐标空间**的 (0,0)：宿主把场景搬到 215 之后，窗口
/// 自己并不知道位置变了，`top` 一直是 0 —— Aevon(124) 的日志
/// `kb: lift applied dy=-215 bottom=932 base=717 scene=717 top=0` 就是它。
/// 于是 `sceneBottom` 算成 717，键盘又被上移 215，浮到屏幕中间
/// （日志里场景已经搬到 215..932），这就是「键盘直接悬空」。
///
/// 场景在屏幕哪一段，能问出来的只有**坐标转换**：把窗口 bounds 转到 screen 的
/// 坐标空间，出来的矩形已经包含场景原点。搬成时是 (0,215,430,717)、没搬时是
/// (0,0,430,717)，两个都是运行时事实，不含推断。
///
/// ⛔ 只做坐标转换，**不读 `UIScreen -bounds` 去改任何返回值** —— 0.0.65 /
/// 0.0.67 / 0.1.42 / 0.1.46 四次黑屏全在改那个返回值上。
/// 取不到就返回 `CGRectNull`，由调用方按序回落。
static CGRect AevonKbSceneRectOnScreen(void) {
    if (![NSThread isMainThread]) return CGRectNull;
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
    UIWindow *picked = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowed = (UIWindowScene *)scene;
        UISceneActivationState state = windowed.activationState;
        if (state != UISceneActivationStateForegroundActive &&
            state != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *cand in windowed.windows) {
            if (cand.bounds.size.height < 200.0) continue;
            // 键盘窗自己撑满整屏（932），排除 —— 它也是本进程里的一个 UIWindow，
            // 拿它去转坐标等于量键盘自己，原点永远是屏幕顶。
            if (cand.bounds.size.height >= screenH - 8.0) continue;
            if (cand.isKeyWindow) { picked = cand; break; }
            if (picked == nil) picked = cand;
        }
        if (picked != nil) break;
    }
    if (picked == nil || picked.windowScene == nil) return CGRectNull;
    UIScreen *screen = picked.windowScene.screen;
    if (screen == nil) return CGRectNull;
    CGRect box = [picked convertRect:picked.bounds toCoordinateSpace:screen.coordinateSpace];
    if (box.size.height < 200.0 || box.size.width < 100.0) return CGRectNull;
    return box;
}

/// 宿主那张卡片在**屏幕上的底边**。取不到返回 -1。
///
/// 0.1.50 — 场景可以被宿主整体搬到屏幕下半部（`settings.frame` 带原点），此时
/// `coordinateSpace.bounds` 仍是 430×717、原点仍是 0，**它答不出场景在屏幕的哪
/// 一段**。能答出来的是宿主推过来的卡片矩形（`AevonBandOuter`，屏幕坐标，
/// 实测就是 `card.frame`：`win: band report 430x696 at 0,129 hole=335x566`，
/// 内缩 47.5 才是 hole）。键盘态卡片是 `(0, 215, 430, 717)`，底边 932 ——
/// 与键盘窗底边严丝合缝，于是上移量自动得 0。
///
/// 这是本版唯一依赖外部输入的量，所以拿不到就退 −1，由调用方回落到
/// 「场景高」那套旧算法（不改变 0.1.48 的既有行为）。
static CGFloat AevonKbBandBottomEdge(void) {
    if (AevonBandOn == 0) return -1.0;
    if (AevonBandOuter.size.width < 1.0 || AevonBandOuter.size.height < 1.0) return -1.0;
    CGFloat bottom = CGRectGetMaxY(AevonBandOuter);
    return bottom > 200.0 ? bottom : -1.0;
}

/// 键盘在屏时把键盘窗整体上移，**让它的底边正好压在场景底边上**。
///
/// 0.1.47 写的是 `场景高 − 键盘窗高`（= −215），前提是「键盘窗底边本来就在场景
/// 底」。Aevon(120) 的实测把这个前提否掉了：截图 1290×2796（430×932@3x）量到
/// 键盘可见 744..932、卡片 215..932 ⇒ 键盘顶在场景 529、底在 845，比场景底低
/// **128 pt**。所以正确上移量是 −128，不是 −215；而那一版 `kb: lift` 一条日志
/// 都没有 ⇒ 取窗就失败了，连这个错的数都没写进去。
///
/// 所以改成**由实测底边反推**：`dy = 场景高 − (center.y + bounds.height/2)`。
/// `center` 与 `bounds` 都不受 `transform` 影响，于是：
///   · 每次算出来是同一个数（写绝对值，不累加）；
///   · 键盘窗底边本来就在场景底时自动得 0，什么都不做；
///   · UIKit 中途把它挪走，下一拍算出来的就是新的补偿量。
static void AevonKbLiftApply(BOOL on) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ AevonKbLiftApply(on); });
        return;
    }
    UIView *keyboardWindow = AevonKbKeptWindow;
    int source = AevonKbKeptSource;
    if (keyboardWindow == nil) {
        keyboardWindow = AevonKbWindowScan();
        source = keyboardWindow != nil ? 2 : 0;
    }
    CGFloat sceneHeight = AevonKbSceneHeightNow();
    // 0.1.53 — 基准**优先用宿主推来的卡片底边（band）**，坐标转换降为备用。
    //
    // 0.1.52 把坐标转换放在第一位，结果是一条抖动链（Aevon(125) 备忘录）：
    //
    //   kb: lift applied dy=-215 base=717 top=0    ← 场景还没搬完，转换给 0..717
    //   kb: lift applied dy=-215 base=717 top=0
    //   kb: lift aligned dy=0    base=932 top=215  ← 场景搬到位，键盘又搬回 0
    //
    // 场景原点由**宿主**写进 `settings.frame`，写入到生效差好几拍。在这几拍里
    // 坐标转换读到的是旧位置 ⇒ 键盘被搬 −215，等场景搬好又搬回 0 —— 用户看到的
    // 「打开键盘时抖动」就是这一来一回。
    //
    // band 是宿主主动推过来的**意图**：键盘态卡片就是 `215..932`，底边 932，
    // 与场景搬没搬没关系。用它算 `932 − 932 = 0`，键盘从一开始就不搬，只等
    // 场景自己搬到位（200 ms 内），全程没有第二次动作。
    CGFloat bandBottom = AevonKbBandBottomEdge();
    CGRect sceneBox = AevonKbSceneRectOnScreen();
    CGFloat convBottom = CGRectIsNull(sceneBox) ? 0.0 : CGRectGetMaxY(sceneBox);
    CGFloat sceneTop = CGRectIsNull(sceneBox) ? -1.0 : sceneBox.origin.y;
    if (!CGRectIsNull(sceneBox) && sceneHeight < 200.0) sceneHeight = sceneBox.size.height;
    CGFloat sceneBottom = 0.0;
    if (bandBottom > 200.0) {
        // 宿主的意图优先：它说键盘态卡片铺到 932，那就按 932 算。
        sceneBottom = bandBottom;
    } else if (convBottom > 200.0) {
        // 没有 band（卡片还没上报 / 不是悬浮窗态）才用本进程量到的真值。
        sceneBottom = convBottom;
    }
    if (sceneBottom < 200.0) sceneBottom = sceneHeight;
    if (keyboardWindow == nil || sceneBottom < 200.0) {
        if (AevonKbLiftNotes < 8) {
            AevonKbLiftNotes += 1;
            char skip[200];
            snprintf(skip, sizeof(skip), "kb: lift skip win=%d scene=%.0f base=%.0f src=%d\n",
                     keyboardWindow != nil ? 1 : 0, sceneHeight, sceneBottom, source);
            AevonKbLog(skip);
        }
        return;
    }
    CGSize size = keyboardWindow.bounds.size;
    CGFloat bottom = keyboardWindow.center.y + size.height * 0.5;
    BOOL usable = on && AevonKbHostGate() && size.height > 200.0;
    // 0.1.54 — **一个微米都不搬**。
    //
    // 搬键盘是 0.1.48 的补丁：那时场景恒在 `0..717`，键盘底边 932 在场景外，
    // 只能把键盘整体提上来（−215）。0.1.50 起改走「场景原点搬到 215」，键盘底边
    // 932 与场景底边严丝合缝，**搬的理由已经不存在**。
    //
    // 而 Aevon(126) 证明这条路径现在只会害人：
    //   kb: lift applied dy=-170 bottom=932 base=762 scene=717 top=0
    //   kb: lift aligned dy=0    bottom=932 base=932 …
    // 第一拍算出的 `base=762` 是 App 冷启动时持久化的旧 band（`373x543 at 32,219`
    // 的底边），它比真实值小 170 ⇒ 键盘被提上去 170；宿主的新 band 一到，又搬回
    // 0。用户看到的「开关键盘时悬浮窗布局跳动」就是这一来一回，而中间那几拍键盘
    // 悬在半空。
    //
    // 键盘态下宿主的契约是硬的：卡片 `(0, 215, 430, 717)`、场景同矩形 ⇒ 键盘窗
    // 原生 616..932 整块落在场景内。所以这里恒写 identity —— 它同时负责把历史
    // 版本可能留下的平移**清掉**（`transform` 是绝对值，写 identity 就是复位）。
    CGFloat dy = 0.0;
    // 每次都写**绝对值**（不是累加）：UIKit 在键盘布局时会重设这个窗口的
    // `transform`，重复通知必须能把状态重新拉回来。
    keyboardWindow.transform = CGAffineTransformIdentity;
    if (AevonKbLiftNotes < 10) {
        AevonKbLiftNotes += 1;
        char line[240];
        snprintf(line, sizeof(line),
                 "kb: lift %s dy=%.0f bottom=%.0f base=%.0f scene=%.0f top=%.0f kb=%.0fx%.0f src=%d\n",
                 (dy == 0.0) ? (usable ? "aligned" : "off") : "applied",
                 dy, bottom, sceneBottom, sceneHeight, sceneTop, size.width, size.height, source);
        AevonKbLog(line);
    }
}

/// 键盘窗的 `transform` 会被 UIKit 在布局时重置。写进去之后连提三拍
/// （0 / 80 / 240 ms）：哪一拍被抹掉，后面那拍都会补回来。三次都是绝对值，
/// 重复写同一个平移量没有副作用。
///
/// 0.1.50 — 补两拍（700 / 1500 ms）：宿主把卡片摆到 215..932、场景跟着搬过去
/// 之后，App 会再排一次版，UIKit 在那期间会重置键盘窗的 `transform`。前五拍
/// 全是绝对值，重复写同一个数没有副作用。
static void AevonKbLiftRepeat(void) {
    AevonKbLiftApply(AevonKbOn != 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbLiftApply(AevonKbOn != 0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbLiftApply(AevonKbOn != 0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.70 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbLiftApply(AevonKbOn != 0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbLiftApply(AevonKbOn != 0); });
}

/// 0.1.49 — 让位判据：App 主窗口的 `keyboardLayoutGuide.layoutFrame`。
///
/// 这一行回答的是 0.1.48 唯一没有取证的那件事 —— `intersectionHeight` 返回 316
/// 之后，**App 到底有没有真的把内容让出 316**。日志里 `-> 316.0` 只证明我们说了，
/// 不证明它被消费了。参考线是 UIKit 自己算给 App 用的，App 的输入框就贴在它的
/// 上沿：`top≈401` 说明让位生效（输入框会被摆在 401 之上）；`top≈0 / h≈0` 说明
/// 参考线还没动，那么卡片再怎么摆都没用，下一版只能改场景高度。
///
/// 只问 `respondsToSelector:` + 读 `layoutFrame`，不调任何可能抛异常的路径。
static volatile int AevonKbGuideNotes = 0;
/// 0.1.67 — 光标/输入框读数最多打几条（每个键盘周期最多一条，够了）。
static volatile int AevonKbCaretNotes = 0;

static void AevonKbGuideNote(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ AevonKbGuideNote(); });
        return;
    }
    if (AevonKbGuideNotes >= 8) return;
    UIWindow *found = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *cand in ((UIWindowScene *)scene).windows) {
            if (cand.isKeyWindow) { found = cand; break; }
        }
        if (found != nil) break;
    }
    if (found == nil) return;
    SEL guideSel = sel_registerName("keyboardLayoutGuide");
    if (![found respondsToSelector:guideSel]) return;
    id guide = ((id (*)(id, SEL))objc_msgSend)(found, guideSel);
    if (guide == nil) return;
    SEL frameSel = sel_registerName("layoutFrame");
    if (![guide respondsToSelector:frameSel]) return;
    CGRect box = ((CGRect (*)(id, SEL))objc_msgSend)(guide, frameSel);
    AevonKbGuideNotes += 1;
    char line[220];
    snprintf(line, sizeof(line), "kb: guide win=%.0fx%.0f top=%.0f h=%.0f seen=%.0f\n",
             found.bounds.size.width, found.bounds.size.height,
             box.origin.y, box.size.height, (double)AevonKbTopSeen);
    AevonKbLog(line);
}

// MARK: - 0.1.77 键盘布局参考线（`UIKeyboardLayoutGuide`）兜底

/// 表外 App 的最后一条通道。
///
/// Aevon(148) 里 Safari 的读数把「靠通知矩形调它」这条路彻底否掉了：
///
///   kb: note rect raw=701 out=616 cal=0 fixed=616 nh=316   ← 值全对
///   kb: inter true=316 sys=101 origin=215 sceneH=717       ← 交集也对
///   kb: caret cls=UnifiedField y=725..746 win=717 kb=513 bar=713..758
///   kb: caret cls=UnifiedField y=725..746 win=717 kb=513 bar=713..758   （学完 192 之后）
///
/// `out` 从 616 改到 424，输入条底边**一 pt 没动**（七次采样里六次都是 758，
/// 只有一次 543）。也就是说 Safari 的地址栏既不读 `UIKeyboardFrameEndUserInfoKey`，
/// 也不读 `intersectionHeightForWindowScene:`。它读的是**第三条通道**：
///
///   kb: guide win=430x717 top=0 h=0
///
/// 键盘布局参考线的高度**恒为 0**。这条线本该由 UIKit 按「键盘窗与本窗口的交集」
/// 自己算，可我们的 App 跑在别人（宿主）的场景里，UIKit 根本没把这只键盘和这个窗口
/// 关联起来 —— 这也是微信 0.1.56 那一版 `keyboardLayoutGuide` 一直是 `h=0` 的同一个
/// 原因（见 `AevonKbGuideNote` 上面的长注释）。
///
/// 所以这一版把这条线**自己喂上**：`layoutFrame` 原本高度不足 1 pt 时，按
/// 「窗口底边往上 cover pt」返回一个真值。只在下面三个条件同时成立时动手：
///
///   ① 原值高度 < 1 pt —— 已经拿到真值的 App 一个字节都不碰；
///   ② 键盘确实在屏（`AevonKbNoteActive != 0`）；
///   ③ 该 App **不**在我们已校准的名单里（QQ / 微信 / 抖音）。
///
/// ③ 是这一版最要紧的一条：前两个 App 现在靠通知矩形已经摆对了，抖音的口径本来
/// 就不同；它们若也读到这条线，会**在已经正确的让位之上再让一次**（正是 0.1.69
/// 「让两次」那个坑）。名单外（Safari / 酷安 / 贴吧 …）才是这条线唯一该服务的人。
static CGRect (*AevonKbGuideOrig)(id, SEL);
static Class AevonKbGuideClass;

static CGRect AevonKbGuideFrame(id self, SEL _cmd) {
    CGRect box = AevonKbGuideOrig != NULL ? AevonKbGuideOrig(self, _cmd) : CGRectZero;
    // 0.1.80 — **停止喂值。**（0.1.77 起这条通道一直是「假设」，从没被证实过）
    //
    // Aevon(150) 把代价摆出来了：Safari 的输入框这次出来了（安全区那条通道），
    // 而酷安的输入框**整套消失**。同一个键盘会话里，酷安拿到的让位是三份叠加：
    //
    //   kb: note rect raw=761 out=407 cal=209 fixed=616 nh=525   ← ① 通知矩形平移 209
    //   kb: guide fill h=316 own=430x717 cover=316               ← ② 参考线补 316
    //   kb: safe inset bottom=316 was=0 cover=316                ← ③ 安全区再加 316
    //   kb: caret cls=CoolMarket.KAAttributedTextView bar=681..775
    //
    // ①+②+③ 一共 841 pt，一根底部工具栏从 775 被顶到卡片上沿之外 —— 那就是
    // 「输入框消失了」。聊天类 App 读通知矩形、现代控件读参考线、WebKit 读安全区，
    // 三份让位本来就是给三种不同的 App 准备的，同时生效就是 0.1.69「让两次」的
    // 加强版。
    //
    // 三者里只有安全区是 UIKit 的**公开约定**（App 一定按它排版），而且 Safari
    // 已经证明它有用。所以留安全区，撤参考线 —— 这条通道从来没有一份日志能证明
    // 「喂了之后 bar 上移」，却有酷安这份反证。
    return box;
}

static void AevonKbGuideHookInstall(void) {
    if (AevonKbGuideOrig != NULL) return;
    if (AevonKbGuideClass == Nil) AevonKbGuideClass = NSClassFromString(@"UIKeyboardLayoutGuide");
    Class cls = NSClassFromString(@"UILayoutGuide");
    if (cls == Nil) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("layoutFrame"));
    if (m == NULL) return;
    AevonKbGuideOrig = (CGRect (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)AevonKbGuideFrame);
}

/// 0.1.67 — **输入框到底在哪一行**（屏幕坐标），每个键盘周期打一条。
///
/// 这一条是为了不再靠猜。前面所有关于「窗口该收多高」的争论都缺同一个量：
/// App 自己把输入框摆到了屏幕的哪个 y。有了这个数，判据就变成一句话 ——
/// 输入框底边 ≤ 键盘顶边 ⇒ 看得见；否则就是被键盘盖住。
///
/// 取法是唯一稳的：从 key window 往下深度优先找 `isFirstResponder` 且符合
/// `UITextInput` 的那个视图，读它的 `selectedTextRange.end` 处的
/// `caretRectForPosition:`，再转换到屏幕坐标空间。光标就是人眼看到的那条竖线。
///
/// 走整棵树是因为 App 没有公开的「当前焦点」入口；节点数封顶 6000，一次
/// 键盘周期只走一次（0.75 s 那一拍），开销可以忽略。
static UIView *AevonKbFirstTextInput(UIView *root, int *budget) {
    if (root == nil || budget == NULL || *budget <= 0) return nil;
    *budget -= 1;
    if (root.isFirstResponder && [root conformsToProtocol:@protocol(UITextInput)]) return root;
    for (UIView *kid in root.subviews) {
        UIView *hit = AevonKbFirstTextInput(kid, budget);
        if (hit != nil) return hit;
    }
    return nil;
}

static void AevonKbCaretNote(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ AevonKbCaretNote(); });
        return;
    }
    if (AevonKbCaretNotes >= 24) return;
    UIWindow *found = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *cand in ((UIWindowScene *)scene).windows) {
            if (cand.isKeyWindow) { found = cand; break; }
        }
        if (found != nil) break;
    }
    if (found == nil) return;
    CGFloat kbTop = AevonKbVisualTop();
    int budget = 6000;
    UIView *input = AevonKbFirstTextInput(found, &budget);
    AevonKbCaretNotes += 1;
    char line[220];
    if (input == nil) {
        snprintf(line, sizeof(line), "kb: caret none win=%.0f kb=%.0f scout=%d\n",
                 found.bounds.size.height, kbTop, 6000 - budget);
        AevonKbLog(line);
        return;
    }
    id<UITextInput> field = (id<UITextInput>)input;
    CGRect caret = CGRectNull;
    UITextRange *range = field.selectedTextRange;
    if (range != nil) caret = [field caretRectForPosition:range.end];
    CGRect box = CGRectNull;
    CGRect bar = CGRectNull;
    if (found.windowScene != nil) {
        box = [input convertRect:caret toCoordinateSpace:found.windowScene.screen.coordinateSpace];
        // 0.1.69 — 光标之外再给一条**输入框自己那一条**的屏幕矩形。
        //
        // 0.1.67/0.1.68 只有光标，于是「输入框被挡住」只能靠光标推：光标在
        // 604..625 时到底是「输入框整体在下面」还是「输入框在上面、只有光标
        // 冒出去」，两种情形给出的修法完全相反。`bar` 就是 `UITextView` /
        // `UITextField` 自己的矩形，底边 ≤ 键盘顶 ⇒ 看得见。
        bar = [input convertRect:input.bounds toCoordinateSpace:found.windowScene.screen.coordinateSpace];
    }
    snprintf(line, sizeof(line),
             "kb: caret cls=%s y=%.0f..%.0f x=%.0f win=%.0f kb=%.0f bar=%.0f..%.0f\n",
             NSStringFromClass([input class]).UTF8String,
             CGRectIsNull(box) ? -1.0 : box.origin.y,
             CGRectIsNull(box) ? -1.0 : CGRectGetMaxY(box),
             CGRectIsNull(box) ? -1.0 : box.origin.x,
             found.bounds.size.height, kbTop,
             CGRectIsNull(bar) ? -1.0 : bar.origin.y,
             CGRectIsNull(bar) ? -1.0 : CGRectGetMaxY(bar));
    AevonKbLog(line);
    // 0.1.75 — **自学习：这一步就是「不用逐个 App 标定」的答案。**
    //
    // 键盘起来 0.75 s / 1.9 s 各量一次，量到的是**输入框自己的矩形**（屏幕坐标，
    // 任何 App 都能量，`AevonKbFirstTextInput` 只认 `isFirstResponder` +
    // `UITextInput`，不认类名）。把它和键盘可见上沿一比，这个 App 属于哪一类立刻
    // 就清楚了 —— 不需要知道它是 ObjC 还是 Swift、用不用 UIScrollView：
    //
    //   底边 < 上沿 − 8  ⇒ 它自己换算对了，什么都不做（绝大多数 App）
    //   底边 ≥ 上沿 − 8  ⇒ 它把 `origin.y` 直接当窗口坐标用了，让位少了；
    //                      少的正是「底边 − 目标」，记住这个数，下次开键盘补上
    //
    // 目标是「上沿 − 50」而不是「上沿」：输入条下面通常还有一行工具按钮
    // （表情 / 图片 / 语音），QQ 群和微信被盖的就是那一行（Aevon(145)）。
    //
    // 记录按 Bundle 存进 App 自己的偏好域（`AevonKbExtra`），进程重启仍在。
    if (!CGRectIsNull(bar)) {
        CGFloat fullH = AevonKbNativeBounds(nil).size.height;
        CGFloat kbVisible = AevonKbTopFixed(fullH);
        if (kbVisible < 1.0) kbVisible = fullH - 316.0;
        CGFloat target = kbVisible - 50.0;
        CGFloat bottom = CGRectGetMaxY(bar);
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        // 抖音口径不同（它把工具栏算进键盘矩形，`cal` 恒 0），不参与学习。
        BOOL skip = [bid isEqualToString:@"com.ss.iphone.ugc.Aweme"];
        AevonKbSafeLoad();
        if (!skip && bottom > 100.0 && target > 200.0) {
            CGFloat need = bottom - target;
            CGFloat cur = AevonKbExtraCal;
            // 0.1.80 — **一次只开一条通道，而且要有复量做证词。**
            //
            // 0.1.78 的升级条件是「①补过（cur ≥ 60）却还差 60 以上」，判据本身
            // 没错，错在**①补过的证据是上一个键盘会话留下的**：酷安这次进来
            // `cur` 已经是 209（上一轮学的），于是它当场跳到 ②，而这一拍的
            // `need=209` 是**还没看到①效果之前**量的。三条通道（通知 / 参考线 /
            // 安全区）就这样在同一秒里全打开了。
            //
            // 现在把「先补①、0.70 s 后复量、仍被盖才升级②」写成一条真正的时间
            // 顺序：① 只在本会话第一次量到被盖时补一次，补完立刻排一次复量；
            // 复量那一拍读到的 `bar` 才是判决书 —— 它要么被①救回来了（`need`
            // 掉到 60 以下，什么都不做），要么证明这个 App 不读通知矩形，才轮到②。
            // ② 生效后再复量一次，仍被盖就只记 `kb: learn stuck`，不再叠第三条。
            if (AevonKbSafeBanned == 0 && AevonKbSafeFlag == 1) {
                // 已经在走安全区：只观测，两次都还没用就撤销（见下）。
                //
                // 0.1.83 — **安全区不是万能，补过没用必须退回通知矩形那条。**
                //
                // Aevon(151) 的酷安把这条路的死法写全了：`safe inset bottom=316`
                // 写了两次，`bar` 一直是 `826..920`（一像素没动），每一次采样都是
                // `kb: learn stuck safe=1 … need=354`；而 `safeOnly` 会把通知矩形
                // 那条整体让开（`note rect raw=761 out=761`，一个字节都没改）——
                // 两条通道同时不干活，输入框整条留在 920，被键盘盖死。
                //
                // 判据用「补过之后还差 60 以上」连着两次采样成立，就撤安全区、
                // 把它记成「不吃这一套」，下一份通知立刻回到 `out = 616 − cal`
                // （酷安 cal=209 ⇒ out=407，App 让位 310，输入框从 920 抬到 610）。
                if (need > 60.0) {
                    AevonKbSafeStuck += 1;
                    char stuck[220];
                    snprintf(stuck, sizeof(stuck),
                             "kb: learn stuck safe=1 bar=%.0f target=%.0f need=%.0f hit=%d\n",
                             bottom, target, need, AevonKbSafeStuck);
                    AevonKbLog(stuck);
                    if (AevonKbSafeStuck >= 2) {
                        AevonKbSafeStuck = 0;
                        AevonKbSafeBanned = 1;
                        AevonKbSafeRestore();
                        AevonKbSafeStore(0);
                        char give[220];
                        snprintf(give, sizeof(give),
                                 "kb: learn safe gave up bar=%.0f target=%.0f need=%.0f cal=%.0f\n",
                                 bottom, target, need, cur);
                        AevonKbLog(give);
                        // 下一份通知会按通知矩形重写；0.70 s 后再量一次留证词。
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     (int64_t)(0.70 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{ AevonKbCaretNote(); });
                    }
                } else {
                    AevonKbSafeStuck = 0;
                }
            } else if (cur < 15.0) {
                // ① 这一轮还没补过 ⇒ 按差额补通知矩形，然后**等复量**。
                if (need > 15.0 && need < 340.0) {
                    AevonKbExtraStore(need);
                    char learn[200];
                    snprintf(learn, sizeof(learn),
                             "kb: learn bar=%.0f target=%.0f need=%.0f extra=%.0f -> %.0f\n",
                             bottom, target, need, cur, need);
                    AevonKbLog(learn);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.70 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ AevonKbCaretNote(); });
                }
            } else if (need > 60.0) {
                // ② ① 补过（`cur ≥ 15`）却还差 60 以上 ⇒ 它不读通知矩形，换安全区。
                // 判据不能用 `need > cur + 15`：Aevon(149) 里 Safari 的 `need` 与
                // `cur` 都是 192（补多少就原样剩多少），用「增量」判永远不触发 ——
                // 那正是它连着三版没被救回来的原因。
                //
                // 0.1.83 — 已经被判过「不吃安全区」的 App 不再升级：否则
                // 「升级 → 无效 → 撤销 → 下一拍又升级」是个 0.7 s 的布局抖动环。
                // 这时只留一条读得懂的证据行，不再动任何几何。
                if (AevonKbSafeBanned != 0) {
                    static int banned = 0;
                    if (banned < 4) {
                        banned += 1;
                        char nb[220];
                        snprintf(nb, sizeof(nb),
                                 "kb: learn give up bar=%.0f target=%.0f need=%.0f cal=%.0f\n",
                                 bottom, target, need, cur);
                        AevonKbLog(nb);
                    }
                } else {
                    AevonKbSafeStore(1);
                    AevonKbSafeApply(fullH - kbVisible);
                    AevonKbSafeStuck = 0;
                    char learn[220];
                    snprintf(learn, sizeof(learn),
                             "kb: learn safe=1 bar=%.0f target=%.0f need=%.0f extra=%.0f cover=%.0f\n",
                             bottom, target, need, cur, fullH - kbVisible);
                    AevonKbLog(learn);
                    // 0.70 s 后再量一次：这一次的 `bar` 就是「安全区那条通道到底
                    // 有没有用」的唯一证词，和上一行落在同一份日志里。
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.70 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ AevonKbCaretNote(); });
                }
            }
            // `need ≤ 60` 一律当「已经看得见」：误差 60 pt 以内是多让一行工具条
            // 的量级，再追下去只会把输入框推到卡片上沿之外（酷安就是这样消失的）。
        }
    }
}

/// 母本 0x5284 的原式：`(原值 × 屏幕高 ÷ 键盘窗高) × 1.0 + 键盘窗高 − 屏幕高`。
/// 1.0 是母本的 `_heightFraction` 缺省值。
///
/// 0.1.44 真机证明这个式子在本机退化成原值：`screen` 与 `kbwin` 都是 932，第一项
/// 等于原值，后面的 `+932−932` 又抵消。所以 0.1.45 起 `屏幕高` 取「承载场景的高」
/// （717），并另算一条无缩放时的平移式，两条取大。见函数体中段的说明。
///
/// 只往「变大」的方向走：算出来比原值小、或者超出场景高，就不采用。宁可不动，
/// 也不把键盘算成一个负数高度。
static double AevonKbIntersection(id self, SEL _cmd, id scene, BOOL *isLocal, BOOL ignore) {
    double answer = ((double (*)(id, SEL, id, BOOL *, BOOL))AevonOrigIntersection)(self, _cmd,
                                                                                  scene, isLocal, ignore);
    if (AevonOrigIntersection == NULL) return answer;
    if (!AevonKbHostGate()) return answer;
    id window = AevonKbWindowNow(self);
    if (window == nil) {
        if (AevonKbMissNotes < 3) {
            AevonKbMissNotes += 1;
            char line[200];
            SEL win = sel_registerName("keyboardWindow");
            Class kbCls = objc_getClass("_UIRemoteKeyboards");
            snprintf(line, sizeof(line),
                     "kb: no keyboard window self=%.44s win=%d cls_active=%d\n",
                     self != nil ? object_getClassName(self) : "-",
                     (self != nil && [self respondsToSelector:win]) ? 1 : 0,
                     (kbCls != Nil
                      && [kbCls respondsToSelector:sel_registerName("activeInstance")]) ? 1 : 0);
            AevonKbLog(line);
        }
        return answer;
    }
    // 0.1.48 — 这只窗是运行时给的真对象（`kbwin` 就是从它身上量的），留住给
    // `AevonKbLiftApply` 用：那条扫场景的路在 Aevon(120) 里一个都没扫到。
    if ((UIView *)window != AevonKbKeptWindow) {
        [(UIView *)window retain];
        [AevonKbKeptWindow release];
        AevonKbKeptWindow = (UIView *)window;
        AevonKbKeptSource = 1;
    }
    CGFloat fullHeight = AevonKbNativeBounds(nil).size.height;
    CGFloat keyboardHeight = ((UIView *)window).bounds.size.height;
    // 0.1.52 — 删掉 0.1.51 在这里加的「屏幕底 − 键盘顶」分支。
    //
    // 那个分支读 `UIKeyboardFrameEndUserInfoKey.origin.y`。键盘弹出/收起是**动画**，
    // `willChangeFrame` 每帧都发一次，这个值在动画途中一路变。Aevon(124) 的日志里
    // 同一个键盘会话中出现过 502 / 573 / 674 / 775 四个值 ⇒ 让位量被算成
    // 430 / 359 / 258 / 157，内容被推到屏幕中间。而下面的老式子在同一次里稳稳给
    // 316（`kb: lead h=101.0 … -> 316.0 took=3`）—— 0.1.51 的新分支每次都把它覆盖掉。
    //
    // 老式子的两个输入（场景高、键盘窗高）都是几何量，不受动画中间态影响；
    // 场景被搬到 215 之后它依然给 316（搬的只是原点，两个高都没变），正是要的数。
    // 所以这里只保留老式子，一条分支就够。
    CGFloat sceneHeight = -1;
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        sceneHeight = ((UIWindowScene *)scene).coordinateSpace.bounds.size.height;
    }
    // 0.1.45 — 母本式里的 `屏幕高` 到底是什么。
    //
    // 真机（Aevon(118)，0.1.44）把四个数打出来了：
    //   kb: lead h=74.0 screen=932.0 kbwin=932.0 scene=717.0 -> 932.0 took=2
    // `screen` 与 `kbwin` 相等 ⇒ `h×screen÷kbwin` 这一项等于 `h`，整个式子退化成
    // 原值，只能走兜底返回 932 —— 也就是说换算一次都没生效。
    //
    // 母本的 `screenH` 之所以不是整屏：它还装了 `UIScreen -bounds`（0x567c），在有
    // 卡片时返回 `[scene _boundsForInterfaceOrientation:]`，也就是**承载场景的
    // bounds 430×717**。那条钩子会改掉 App 的整个布局基准（0.1.42 的黑屏路径），
    // 这里不装 —— 直接在键盘求值这一刻取调用方 scene 的高度，效果等价，副作用为零。
    CGFloat screenHeight = (sceneHeight > 40 && sceneHeight < fullHeight - 8)
                         ? sceneHeight : fullHeight;
    if (screenHeight < 1 || keyboardHeight < 40) return answer;
    // 0.1.56 — **这个返回值从此不需要我们动手**。
    //
    // 让位量这件事，0.1.48~0.1.55 连试了七版：搬键盘（输入框被盖）、搬场景原点
    // （键盘悬空）、缩放换算（458.1，内容悬在键盘上方 142 pt）、通知坐标换算
    // （微信/QQ 三版一次没让对）。Aevon(128) 最后一行证词是 `kb: guide h=0` ×2 ——
    // 那个 App 的键盘让位参考线根本没被驱动，我们返回多少都不影响它。
    //
    // 所以这一版换的是**问题本身**：宿主把承载场景的高收到键盘顶边
    // （430×401@215，底边正好 616），键盘 616..932 整块落在 App 窗口外面。
    // 窗口与键盘不相交 ⇒ 系统给的 `answer` 天然是 0，App 按 0 让位、
    // 按 401 的高度排版，输入框就在窗口底边 = 屏幕 616 = 键盘上沿。
    //
    // 这里只留一行读数。`answer` 应该是 0；如果下一份日志里它还是 289/316，
    // 说明场景没被收下来（宿主侧 `kbtop` 读到 0 → 退回铺满屏底），那不是这里的事。
    // 0.1.68 — 只要「键盘在屏」（通知说过）或「我们的状态机说在屏」，就往下算真实
    // 交集。两个信号取或：前者更早（UIKit 在弹起那一拍就会来问），后者更久（收起
    // 时兜底），任一成立都不会把键盘判成不在。
    if (AevonKbOn == 0 && AevonKbNoteActive == 0) return answer;
    // 0.1.65 — 留一份给 `AevonKbTopCorrected`（只接受 200..500 的合理值）。
    // 0.1.66 — 再分一层：**两次连续一致**才算「结算完」（`AevonKbLeadStable`）。
    //
    // 收过窗口之后这里还会被问一次，答案是 74/101（键盘相对新窗口的遮拦量），
    // 那是我们自己造成的，不能拿去当锚点。0.1.67 把稳定值的窗口收到 **300..340**：
    // 316（键盘 616..932）是几何式算出来的真值，289（键盘 643..932）是收过窗口
    // 之后 UIKit 重新结算的**偏小值** —— 0.1.65/0.1.66 让 289 混进了稳定值，
    // 锚点被锁成 643，输入框整条被键盘盖住。
    if (answer > 200.0 && answer < 500.0) {
        if (fabs((CGFloat)answer - AevonKbLeadSeen) < 1.5
            && answer >= 300.0 && answer <= 340.0) {
            AevonKbLeadStable = (CGFloat)answer;
        }
        AevonKbLeadSeen = (CGFloat)answer;
    }
    AevonKbLeadNote(answer, screenHeight, fullHeight, AevonKbBandBottomEdge(),
                    sceneHeight, answer, 0);
    // 0.1.68 — 把**真实交集**还回去。
    //
    // 调用方是 UIKit 自己（`UIKeyboardSceneDelegate` 拿它算 `keyboardLayoutGuide`、
    // 也算 App 的让位量）。系统给的 `answer` 是拿「它以为的窗口位置」求交：
    // 本机窗口 0..717、键盘 616..932 ⇒ 101。但窗口在屏幕上实际被摆到了
    // 215..932，真实交集是 316。差的那 215 就是「输入框被键盘盖住」的全部原因 ——
    // Aevon(139) 里 QQ 的 `kb: lead h=101.0` 正是这个数。
    //
    // 真实交集 =（场景原点 + 场景高）− 键盘顶。三个量都是几何量，不受动画影响：
    // 场景原点取缓存（宿主搬完场景时写入），没有缓存就按「场景贴屏底」反推
    // `整屏高 − 场景高`。返回的是「键盘遮住这个窗口多少」，不是「键盘多高」。
    //
    // 0.1.70 — 键盘顶取「本会话见过的最小通知顶边」，不读视图、不用动画帧。
    //
    // 0.1.68 取 `DidShow` 那一条（761/788/806 —— 它在动画中途就发了），0.1.69
    // 改读视图几何（同一会话读到 501/528/573 三个数 —— 调用线程与时机不同结果
    // 不同）。两条都不稳，而**不稳定本身就是这三个报障的根源**：让位量每变一次，
    // App 就重排一次，最后停在哪个值全看运气。
    //
    // `AevonKbTopSettled` 是「本会话见过的最小 origin.y」：键盘只会从屏幕下方
    // 往上滑，动画途中的读数全在结算值上面，所以取最小＝取结算值。这个量在
    // 通知线程上就能算，不碰主线程要求，也不受动画影响。
    //
    // 再减掉该 App 自己那条输入条的高度（`AevonKbNoteCalibration`）—— 它们把
    // 「键盘顶」当输入条上边再往下铺一条，底边于是多出自身高度。三条通道（通知
    // 矩形、这里的让位量）从此说同一个数。
    //
    // 0.1.71 — 这个返回值**不再等于真实键盘高度**，别再拿它跟 316 对账。
    //
    // 实测（Aevon(142)）两个 App 的输入条位置对 `truth` 都是 1:1 跟随：
    //   QQ   caret底 = 963 − truth   微信 caret底 = 1190 − truth（142；143 因 cal 变而为 1037）
    // 斜率精确为 −1，方向也没错，只是截距不同。
    //
    // 0.1.72 — 顶边改由 `AevonKbTopFixed` 钉死，不再读任何通知/视图/采样。
    //
    // Aevon(143) 证明「取最小」这条路是错的：动画里的 `origin.y` 会**过冲**
    // （微信 565/467、QQ 513，都比结算值更小），取最小必然取到过冲帧，truth 于是
    // 每开一次键盘涨一档（微信 414→512→610→708→717），输入框阶梯上移、三档一循环。
    // 顶边一旦恒定，truth 就恒定，输入框也就恒定 —— 这是本版唯一的目标。
    CGFloat cal = AevonKbNoteCalibration();
    CGFloat fixedTop = AevonKbTopFixed(fullHeight);
    CGFloat kbTop = fixedTop;
    if (kbTop < 1.0) {
        // 不认识的机型/尺寸：退回通知结算值，再退回系统锚点。
        kbTop = AevonKbTopSettled;
        if (kbTop < 200.0 || kbTop > fullHeight - 60.0) kbTop = AevonKbAnchorValue(fullHeight);
        fixedTop = kbTop;
    }
    // 0.1.73 — 两个通道分别对应两个坐标系，别再混：
    //
    //   truth（还给 UIKit 的让位量）—— **屏幕基准**：`整屏底 − 键盘真实上沿`。
    //                          只由 fixedTop 决定，与 cal 无关。616 ⇒ 316（QQ/微信），
    //                          611 ⇒ 321（抖音，与 0.1.72 一字不差）。
    //   通知矩形（给 App 的 origin.y）—— **窗口坐标**：`fixedTop − 场景原点`。
    //                          616 − 215 ⇒ 401，App 算 `717 − 401 = 316` 正好。
    //
    // 两条通道在 App 眼里是同一个数（316），所以它不会因为两条不一致而重排第二次；
    // 而 0.1.70 那次「累加」是因为同一条通道先后给了未平移/平移两个值，现在这里是
    // **绝对写**（见 `AevonKbPostNote`），同一通道全程只有一个值。
    CGFloat sceneOrigin = AevonKbSceneOriginCache;
    if (sceneOrigin < 1.0 && fullHeight > sceneHeight) sceneOrigin = fullHeight - sceneHeight;
    // 0.1.69 — 顺手把原点缓存补上：`AevonKbSceneOriginY`（平移通知那一路）要在
    // 任何线程上都读得到，而它自己那条「转坐标」的路要求主线程，QQ 的通知不在
    // 主线程投递 ⇒ 恒返回 0 ⇒ 只有 QQ 收不到平移（Aevon(140)：六个通知全 shift=0）。
    if (sceneOrigin > 1.0 && sceneOrigin < 400.0) AevonKbSceneOriginCache = sceneOrigin;
    kbTop -= cal;
    CGFloat kbHeight = fullHeight - kbTop;
    CGFloat truth = (sceneOrigin + sceneHeight) - fixedTop;
    if (truth < 0.0) truth = 0.0;
    if (truth > sceneHeight) truth = sceneHeight;
    static int interNotes = 0;
    static CGFloat lastTruth = -1.0;
    static CGFloat lastHeight = -1.0;
    if ((fabs(truth - lastTruth) > 1.0 || fabs(kbHeight - lastHeight) > 1.0)
        && interNotes < 14) {
        interNotes += 1;
        lastTruth = truth;
        lastHeight = kbHeight;
        char line[220];
        snprintf(line, sizeof(line),
                 "kb: inter true=%.0f sys=%.0f origin=%.0f sceneH=%.0f top=%.0f kbH=%.0f\n",
                 truth, answer, sceneOrigin, sceneHeight, kbTop, kbHeight);
        AevonKbLog(line);
    }
    return truth;
}
/// 场景原点在屏幕上的 Y（本机 215），取不到返回 0。
///
/// ⚠️ 0.1.56 起**不再拿它改任何通知的坐标**（0.1.53~0.1.55 用它平移键盘 frame，
/// 微信/QQ 一次都没让对）。这个函数现在只服务一行读数，留在日志里是为了
/// 「场景到底搬到哪了」还能对账。
// 0.1.70 — 通知不再按场景原点平移（见 `AevonKbPostNote` 的注释），这条函数暂时
// 没有调用点。留着是因为它记录了 0.1.53~0.1.55 与 0.1.69 两轮踩过的坑（三条
// 回退路径为什么都不该优先），下一版若要恢复平移可直接接回来。
static CGFloat AevonKbSceneOriginY(void) __attribute__((unused));
static CGFloat AevonKbSceneOriginY(void) {
    // 0.1.69 — **缓存优先，且不要求主线程。**
    //
    // 下面那条「把 key window 的 bounds 转到屏幕坐标系」的路要求主线程，而 QQ 的
    // 键盘通知不在主线程投递 ⇒ `AevonKbSceneRectOnScreen` 直接返回 `CGRectNull`
    // ⇒ 原点算成 0 ⇒ 只有 QQ 收不到平移。Aevon(140) 的读数把这条钉死了：
    //   com.tencent.mqq  六个通知全部 shift=0
    //   其余三个 App（备忘录/微信/抖音）后四条 shift=215
    // 而 QQ 的 `kb: lead h=101.0`（＝717−616）正是「按屏幕坐标算避让」的产物。
    //
    // 缓存由 `AevonKbIntersection` 写入，值是 `整屏高 − 场景高`，纯几何、任何线程
    // 都读得到。所以先看它。
    CGFloat cached = AevonKbSceneOriginCache;
    if (cached > 1.0 && cached < 400.0) return cached;
    // 0.1.54 — 顺序**反过来**：坐标转换优先，band 只在「卡片真的贴屏底」时兜底。
    //
    // 0.1.53 是 band 优先，Aevon(126) 把它证伪了：
    //   kb: note shift=45 name=UIKeyboardWillShowNotification
    // 45 是 `旧 band 底边 762 − 场景高 717`。App 侧手里那张 `AevonBandOuter` 在
    // App 冷启动时是持久化的旧值 `373x543 at 32,219`（`app: band prefs on=1`），
    // 宿主的新几何是跨进程推过来的，WillShow 那一刻往往还没到。于是键盘通知被
    // 平移 45 而不是 215：App 算出 `717 − (616−45) = 146`，只让 146，输入框被
    // 键盘盖住 45 —— 正是「时有时无」。
    //
    // 坐标转换是本进程的实时事实：场景没搬时给 0，搬到位给 215，中间态给中间值。
    // 它跟 `intersectionHeight` 收到的那个 `h` 是同一时刻的量，两者天然自洽。
    CGRect box = AevonKbSceneRectOnScreen();
    if (!CGRectIsNull(box)) {
        CGFloat off = box.origin.y;
        if (off > 1.0 && off < 400.0) return off;
    }
    CGFloat bandBottom = AevonKbBandBottomEdge();
    CGFloat sceneH = AevonKbSceneHeightNow();
    CGFloat fullH = AevonKbNativeBounds(nil).size.height;
    // band 兜底加一条硬闸门：**底边必须贴着屏幕底**才采信。
    //
    // 键盘态卡片是 `(0, 215, 430, 717)`，底边 932 = 屏底；非键盘态的 band 底边
    // 还带着环带外扩（Aevon(126)：`430x692 at 0,144`，底边 836）或干脆是旧值
    // （762）。拿它们减场景高，得到的是 45 / 119 这种既不是 0 也不是 215 的中间
    // 数 —— 就是上面那条 `shift=45`。
    if (bandBottom > 200.0 && sceneH > 200.0 && fullH > 200.0
        && bandBottom >= fullH - 2.0) {
        CGFloat off = bandBottom - sceneH;
        if (off > 1.0 && off < 400.0) return off;
    }
    return 0.0;
}

// ===== 0.1.53 — 键盘通知里的坐标换算 =====
//
// **这是「微信 / QQ 不显示输入框」的真正根因**，前六版一直没找到。
//
// 场景原点被宿主搬到 215 之后，App 的窗口坐标系原点在屏幕 215，而系统广播的
// `UIKeyboardFrameEndUserInfoKey` 是**屏幕坐标**（顶边 616）。两者差 215。
//
//   · 用 `keyboardLayoutGuide` 的 App：UIKit 内部自己处理，不受影响；
//   · 自己按 frame 算避让的 App：算出 `717 − 616 = 101`，只让出 101，
//     输入框被键盘盖住 215 pt —— **完全看不见**。
//
// 日志把这一条钉死了：`kb: guide win=430x717 top=0 h=0` —— 微信和 QQ 的
// layoutGuide 根本没被驱动，说明它们不走 UIKit 那条路，而是自己读 frame。
//
// 时间线也吻合：0.1.48 之前场景原点恒为 0（frame 616 是对的，输入框正常），
// 0.1.50 起才开始搬场景，也正是用户第一次报「输入框不见了」的那一版。
//
// 所以这里把广播里的 keyboard frame 从屏幕坐标换成场景坐标（减 215）。
// ⛔ 只在「卡片态 + 键盘在屏 + 场景原点真的 > 0」时才改；任何一个条件不成立就
// 原样透传。改的是通知里的**值**，不碰任何视图几何。
static void (*AevonOrigPostNote)(id, SEL, NSNotificationName, id, NSDictionary *);
static volatile int AevonKbNoteNotes = 0;

static BOOL AevonKbIsKeyboardNote(NSNotificationName name) {
    if (name == nil) return NO;
    return [name isEqualToString:UIKeyboardWillChangeFrameNotification]
        || [name isEqualToString:UIKeyboardDidChangeFrameNotification]
        || [name isEqualToString:UIKeyboardWillShowNotification]
        || [name isEqualToString:UIKeyboardDidShowNotification]
        || [name isEqualToString:UIKeyboardWillHideNotification]
        || [name isEqualToString:UIKeyboardDidHideNotification];
}

static void AevonKbPostNote(id self, SEL _cmd, NSNotificationName name, id object, NSDictionary *info) {
    NSMutableDictionary *shifted = nil;
    // 0.1.68 — 去掉 `AevonKbOn != 0` 这一条：它是我们自己的观察者置的，比通知
    // 的投递晚一步，留着会让**每个键盘周期的第一条**通知漏过去。现在判据只有
    // 「是本进程 + 这个 App 正被托管」，键盘在不在屏上由 `AevonKbNoteActive`
    // 单独记，两件事分开。
    if (info != nil && AevonKbHostGate() && AevonKbIsKeyboardNote(name)) {
        // 0.1.70 — 键盘顶只认**见过的最小值**。
        //
        // 键盘从屏幕下方滑上来，`origin.y` 一路上降：932 → 906 → 806 → 761 → 601。
        // 动画途中的读数全在最终值上面，所以「取最小」＝取结算值，不需要等动画、
        // 也不读任何视图几何。0.1.68 取 `DidShow` 那一条（读到 761/788/806 ——
        // 它在动画中途就发了），0.1.69 改读视图（读到 501/528/573 三个数 ——
        // 调用时机不同结果不同），都不稳。
        //
        // 门槛 `> 350` 是为了滤掉「键盘已收、origin.y 落到 401/318」的读数
        // 和 0 值；`< full` 滤掉完全收起的 932。
        //
        // 0.1.71 — **没有「新会话」这回事了**，值跨会话保留（推导见下）。既不能
        // 用 `WillShow` 当边界（同一个键盘会连发两轮，第二轮一重置就把第一轮
        // 结算好的值抹掉），也不能用 `AevonKbNoteActive == 0` —— Aevon(142) 的
        // QQ 就是被它坑的：第一次结算 639、第二次结算 666。
        NSValue *endValue = [info objectForKey:UIKeyboardFrameEndUserInfoKey];
        if (endValue != nil) {
            CGRect raw = [endValue CGRectValue];
            CGFloat full = AevonKbNativeBounds(nil).size.height;
            if (raw.size.height > 40.0 && raw.origin.y > 350.0 && raw.origin.y < full - 1.0) {
                // 0.1.71 — **不再在会话开头清零，只降不升。**
                //
                // 0.1.70 的写法是「`AevonKbNoteActive == 0` 就当成新会话、把
                // `AevonKbTopSettled` 清 0」。Aevon(142) 证明这会让同一个 App
                // 在两次会话里拿到不同的顶边：QQ 第一次结算 639、第二次 666
                // （它弹不弹候选栏差 27 pt），truth 于是 345 → 318 → 318。
                // 而 App 侧是 1:1 跟随的（`caret底 + truth = 963` 两处采样严丝
                // 合缝），truth 少 27，输入条就往下沉 27 —— 618 → 645，正好从
                // 「压在键盘上沿、看得见」掉成「整条埋进键盘、看不见」。
                //
                // 键盘只会从屏幕下方往上滑，所以「历史最小」永远是一个已结算过
                // 的真实顶边；用它做基准，同一个 App 在本次进程存活期间只会得
                // 到一个数，App 不会因为值变了而重排第二次。
                CGFloat settled = AevonKbTopSettled;
                // 3 pt 容差：同一种键盘结算后会有 1~2 pt 抖动，不重复刷日志。
                BOOL take = (settled < 1.0 || raw.origin.y < settled - 3.0);
                if (take) AevonKbTopSettled = raw.origin.y;
                if (AevonKbTopSettleNotes < 8
                    && (take || fabs(raw.origin.y - settled) > 3.0)) {
                    AevonKbTopSettleNotes += 1;
                    char line[200];
                    // `take=0` 说明这次读数比已结算的更大、被挡住了 —— 这一行
                    // 正是「只降不升」在起作用的证词，不要只记成功的那些。
                    snprintf(line, sizeof(line),
                             "kb: top settle kept=%.0f raw=%.0f was=%.0f take=%d\n",
                             AevonKbTopSettled, raw.origin.y, settled, take ? 1 : 0);
                    AevonKbLog(line);
                }
                AevonKbTopSeen = raw.origin.y;
            }
        }
        // 0.1.68 — 先按**原始矩形**判一次「键盘在不在屏上」，这是 UIKit 问交集
        // 那一刻能用到的最早信号（见 `AevonKbNoteActive`）。下面平移之后再判就
        // 全是窗口坐标，判据会跟着漂。
        NSValue *rawEnd = [info objectForKey:UIKeyboardFrameEndUserInfoKey];
        if ([name isEqualToString:UIKeyboardWillHideNotification]
            || [name isEqualToString:UIKeyboardDidHideNotification]) {
            AevonKbNoteActive = 0;
        } else if (rawEnd != nil) {
            CGRect raw = [rawEnd CGRectValue];
            CGFloat full = AevonKbNativeBounds(nil).size.height;
            if (raw.origin.y >= full - 1.0) AevonKbNoteActive = 0;
            else if (raw.size.height > 40.0) AevonKbNoteActive = 1;
        }
        // 0.1.72 — **顶边按 App 钉死，绝对写，不叠加。**
        //
        // 0.1.70 只做了「减掉输入条高度」，顶边仍从通知取；0.1.71 又加了「取最小」，
        // 结果取到了动画的过冲帧（微信 565/467、QQ 513，都比结算值更小），
        // truth 每开一次键盘涨一档 ⇒ 输入框阶梯上移、三档一循环（Aevon(143)）。
        //
        // 现在两条来源合一：`raw` 用 `AevonKbTopFixed`（本机实测结算值），
        // 再减 `AevonKbNoteCalibration`。写的是**绝对值** `rect.origin.y = target - cal`，
        // 不是 `-=`：同一会话里多条通知重复到达时不会累加（0.1.69 的教训）。
        CGFloat cal = AevonKbNoteCalibration();
        CGFloat full = AevonKbNativeBounds(nil).size.height;
        CGFloat fixedTop = AevonKbTopFixed(full);
        // 0.1.78 — 安全区通道生效时，**通知矩形整体让开**。
        //
        // 两条通道各管一种 App：读通知矩形的走 ①，读安全区的走 ②。同时写就是
        // 0.1.69 的「让两次」—— 输入框被顶到屏幕中间，比被盖住还难看。
        // Safari 是唯一已知走 ② 的（前三条通道它一条都不读）。
        AevonKbSafeLoad();
        BOOL safeOnly = (AevonKbSafeFlag == 1);
        CGFloat rawTop = endValue != nil ? [endValue CGRectValue].origin.y : -1.0;
        CGFloat target = fixedTop > 0.0 ? fixedTop : rawTop;
        CGFloat outTop = rawTop;
        CGFloat outH = -1.0;
        if (!safeOnly && target > 0.0 && (fixedTop > 0.0 || fabs(cal) > 0.5)) {
            NSMutableDictionary *copy = [[NSMutableDictionary alloc] initWithDictionary:info];
            BOOL moved = NO;
            NSArray *keys = @[UIKeyboardFrameBeginUserInfoKey, UIKeyboardFrameEndUserInfoKey];
            for (NSString *key in keys) {
                NSValue *boxed = [copy objectForKey:key];
                if (boxed == nil) continue;
                CGRect rect = [boxed CGRectValue];
                if (rect.size.height < 40.0) continue;
                // 0.1.80 — **收起的那一帧一个字节都不改。**
                //
                // 上面这条平移的用意是「让 App 以为键盘比它看到的更靠上」。
                // 可它没有方向：收起时 `origin.y` 落到屏幕底（932），照样会被
                // 改写成 356/611 —— 等于把一条「键盘走了」的通知改成了「键盘
                // 来了」，而且高度还按 `full − 356` 补成 576，比屏幕还高。
                //
                // Aevon(150) 的证词：每个键盘周期里 `hide note` 都出现在弹起后
                // 约 1 秒（gap=0.97 / 1.10 / 1.02），紧跟一条 `top zero` 和
                // `caret none` —— App 收到「键盘又来了」就会重排/重开输入会话，
                // 那正是「放大时闪一下」和「关键盘不还原」的共同上游。
                if (rect.origin.y >= full - 8.0) {
                    static int offNotes = 0;
                    if (offNotes < 8) {
                        offNotes += 1;
                        char line[160];
                        snprintf(line, sizeof(line), "kb: note off raw=%.0f name=%.32s\n",
                                 rect.origin.y, [(NSString *)name UTF8String]);
                        AevonKbLog(line);
                    }
                    continue;
                }
                rect.origin.y = target - cal;
                // 0.1.76 — **高度必须跟着一起改。**
                //
                // 0.1.72 起只写 `origin.y`，矩形就变成「从 356 开始、高度仍是
                // 系统给的 446」—— 一条底边落到 802 的矩形，它描述的已经不是
                // 一块贴着屏幕底的键盘了。凡是拿 `rect.height` 或
                // `CGRectGetMaxY(rect)` 算让位的 App 都会算错，而且错得没法自
                // 学习补救：Safari（WebKit）就是这一种，Aevon(147) 里它的网页
                // 输入框一直不躲，`kb: learn` 学到 192 反而把它推得更高。
                //
                // 正确的矩形是「从 target−cal 一直铺到屏幕底」，高度由这个关系
                // 反算。抖音 `611/0 ⇒ 321`、QQ 微信 `356/260 ⇒ 576`，与日志里
                // 的 `kbH=` 完全一致 —— 说明这条一直是我们自己对，只是没写回
                // 矩形里。
                CGFloat kbBottom = full;
                CGFloat kbRectH = kbBottom - rect.origin.y;
                if (kbRectH > 40.0) rect.size.height = kbRectH;
                if ([key isEqualToString:UIKeyboardFrameEndUserInfoKey]) {
                    outTop = rect.origin.y;
                    outH = rect.size.height;
                }
                [copy setObject:[NSValue valueWithCGRect:rect] forKey:key];
                moved = YES;
            }
            if (moved) shifted = copy;
            else [copy release];
        }
        if (AevonKbNoteNotes < 8) {
            AevonKbNoteNotes += 1;
            char line[260];
            snprintf(line, sizeof(line),
                     "kb: note rect raw=%.0f out=%.0f cal=%.0f fixed=%.0f nh=%.0f name=%.40s\n",
                     rawTop, outTop, cal, fixedTop, outH, [(NSString *)name UTF8String]);
            AevonKbLog(line);
        }
    }
    if (shifted != nil) {
        AevonOrigPostNote(self, _cmd, name, object, shifted);
        [shifted release];
        return;
    }
    AevonOrigPostNote(self, _cmd, name, object, info);
}

/// 构造函数里调一次。只装 `intersectionHeight` 这一条 —— 它是母本五条钩子里
/// 唯一「只换返回值、不碰几何」的一条。问不到这个方法就什么都不装，行为退回
/// 系统自带。
static void AevonKbNativeInstall(void) {
    static int installed = 0;
    if (installed) return;   // 二次安装会把 `AevonOrig*` 覆盖成我们自己的钩子（自递归）
    installed = 1;
    int interOK = 0;
    Class keyboards = objc_getClass("_UIRemoteKeyboards");
    if (keyboards != Nil) {
        SEL sel = sel_registerName("intersectionHeightForWindowScene:isLocalMinimumHeightOut:"
                                   "ignoreHorizontalOffset:");
        Method m = class_getInstanceMethod(keyboards, sel);
        if (m != NULL) {
            AevonOrigIntersection = method_getImplementation(m);
            method_setImplementation(m, (IMP)AevonKbIntersection);
            interOK = 1;
        }
    }
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    char line[220];
    snprintf(line, sizeof(line), "kb: armed pid=%d inter=%d bundle=%.60s\n",
             (int)getpid(), interOK, [bundle UTF8String]);
    AevonKbLog(line);
    // 0.1.53 装上的键盘通知观察钩子。0.1.56 起它**只读不改**（不再平移 frame），
    // 作用是留一行 `kb: note keep=…` 证词 + 顺手记 `DidShow` 的实体顶边。
    int noteOK = 0;
    Method post = class_getInstanceMethod([NSNotificationCenter class],
                                          sel_registerName("postNotificationName:object:userInfo:"));
    if (post != NULL) {
        AevonOrigPostNote = (void (*)(id, SEL, NSNotificationName, id, NSDictionary *))
                            method_getImplementation(post);
        method_setImplementation(post, (IMP)AevonKbPostNote);
        noteOK = 1;
    }
    char noteLine[160];
    snprintf(noteLine, sizeof(noteLine), "kb: note hook=%d\n", noteOK);
    AevonKbLog(noteLine);
    // 0.1.47 — 键盘窗上移要在**布局完成之后**再确认一次。
    //
    // `willChangeFrame` 只报「将要变成什么」，UIKit 在它之后还会给键盘窗写一次
    // frame —— 而写 frame 会把 `transform` 一起重置成 identity。所以再加一条
    // `didChangeFrame`：那时几何已经定稿，写进去的东西这一轮不会再被抹掉。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidChangeFrameNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        AevonKbLiftRepeat();
    }];
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
    // 0.1.2 — 独立心跳链（1 s）。原先挂在 0.15 s 的翻页器守卫上，那条链 6 分钟后
    // 自停 ⇒ 卡片后半程没有证词。这一条从构造起就一直挂着。
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonAliveTick);
    // 0.1.2 — 开关状态写一行。没有这一行，一份日志分不清「开关开着但没用」和
    // 「开关根本没被编译进去」—— 这是 A/B 实验最容易翻车的地方。
    {
        NSString *b = [[NSBundle mainBundle] bundleIdentifier];
        char mode[160];
        snprintf(mode, sizeof(mode), "probe mode mainOnly=%d quiet=%d bundle=%.60s\n",
                 AevonProbeMainOnly, AevonProbeQuietNow(),
                 b != nil ? [b UTF8String] : "-");
        AevonRawNote(mode);
    }

    // 0.1.8 — 停靠小窗的触摸闸门（见上面那一整段）。装在 App 自己的进程里，
    // 因为漏的那一份投递只经过这里。装不上不算错：行为退回旧版（会透传），
    // 日志里没有 `app: mini touch swallowed` 就说明这条路没通。
    Method sendEvent = class_getInstanceMethod([UIApplication class],
                                               sel_registerName("sendEvent:"));
    if (sendEvent != NULL) {
        AevonOriginalUISendEvent = method_getImplementation(sendEvent);
        method_setImplementation(sendEvent, (IMP)AevonAppSendEvent);
    }
    // 0.1.9 — 通知通道的观察者。注册在 `sendEvent` 之前之后都行，但必须早于第一次
    // 触摸；构造函数是唯一有保证的时机。
    AevonMiniObserve();
    // 0.1.29 — 主窗四边热区（同上那段）；构造函数里先读一次，宿主的卡片可能
    // 早于这个进程起来。
    AevonBandObserve();
    // 0.1.29 — 深浅色。桌面上每切一次就发一条，这里把窗口样式重设一遍。
    AevonStyleObserve();
    // 0.2.15 — 分享 payload 直投（见上面那一整段）。宿主在卡片 scene 就位之后
    // 才发，所以这里注册得早不早无所谓，但必须早于第一次分享。
    AevonOpenURLObserve();
    // 0.1.17 — 键盘在屏的那一声。软键盘属于应用这一侧，桌面要等这里报才知道
    // （见上面 `AevonKbObserve`）。
    AevonKbObserve();
    // 0.1.43 — 键盘交点高度的换算（见上面 `AevonKbNativeInstall`）。每个 App 进程
    // 都装，钩子体内用 `AevonKbHostGate`（卡片承载中 + 外框小于屏幕）决定动不动；
    // 不承载时逐字节返回系统原值。0.1.42 那两条写几何的钩子已撤（黑屏）。
    AevonKbNativeInstall();

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
