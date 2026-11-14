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
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

/// 0.4.7 — 跨文件的键盘接口。
///
/// 实现在 `Sources/App/AevonKeyboardNative.m`（1:1 复刻母版 `SthenoKeyboard.dylib`）。
/// 这里只留三条：
///   · `AevonKbEarlyInstall` —— 构造函数里只装「两条纯计算钩子」（0.4.52）；
///   · `AevonKbRefreshShell` —— band 翻转时通知它重算 `_hookUIScreen`；
///   · `AevonKbEnsureInstalled` —— band 说「我被托着」时才装其余五条（0.4.10）。
extern void AevonKbEarlyInstall(void);
extern void AevonKbRefreshShell(void);
extern void AevonKbEnsureInstalled(void);

/// 0.4.52 — 「宿主此刻说这个 App 被托着」的唯一取数口（定义在本文件偏后，
/// `AevonBandSetOn` 旁边）。0.4.51 的排版对账曾用 `AevonEverHosted` 代替它，
/// 而那一位置位要靠一次 24 pt 的高度跳变 —— 这一版要拍的恰好是「跳变之前」，
/// 所以必须提前拿到这份声明。
int AevonBandHostedNow(void);

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

/// 0.4.53 — **翻页器主动干预整体退休。**
///
/// 0.0.7x 那一整套（钉行下标 → 算落点 → 写 `contentOffset` → `beginUpdates`
/// 请 App 重建 → 换屏后替它按 `play`）从 0.0.71 起一共十九版，用户的原话是
/// 「这些问题在之前那的多个版本都没有修复」。336 的日志把原因写得很直白：
///
///   13:41:44  page transition h=717 last=932 full=932
///   13:41:46  page inside settle box=717 c0=932 … vid=DDanmakuPlayerView:…430x849
///   13:41:49  page align settle y=717 -> 0 … moves=1
///   13:41:50  page align settle y=717 -> 0 … moves=2
///   …（一直写到）
///   13:41:55  page align settle y=717 -> 0 … moves=8
///
/// 六秒里 App 每一次把视口放回 717，我们就再按回 0 —— 一根滚动条被两只手来回
/// 推八次。那几次 `setContentOffset` 每一次都会打断抖音自己的翻页与吸附，于是：
///
///   · 上滑之后它又回到打开时那一条（它的「当前条目」被我们按回了第 0 行）；
///   · 关掉卡片再全屏，看到的不是刚才那一条（同上，索引与 offset 已经不一致）；
///   · 反复重建单元格 ⇒ 视频层被反复改尺寸 ⇒ 画面出现断层，要杀进程才好。
///
/// 这三条都不是「算得不准」，是**根本不该去按**。翻页器是 App 自己的，它比我们
/// 更清楚下一页在哪；我们连「一页多高」都要靠猜（932 还是 717 取决于它重排到
/// 哪一拍），却还在替它写 offset。0.4.51 退休视频居中时用的是同一条判据：一个
/// 机制连续多版没带来可验证的收益、又只能靠改别人的几何实现，就该撤。
///
/// 所以这里只留一个常量。改回 0 = 整套 0.0.7x 行为原样回来（函数体一个字节都
/// 没删），改回之前请先看 336 那段 `align … moves=8`。
static volatile const int AevonPageRideRetired = 1;

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
    // 0.4.53 — 替 App 按 `play` 随整套干预退休。它只在这一个地方出手，而
    // 「换屏之后画面停住」的真正原因是我们的 offset 写入打断了自己恢复的那一拍
    // （见 `AevonPageRideRetired`）。把方向盘还回去之后，这一手就不需要了。
    if (AevonPageRideRetired) return;
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
/// 0.1.38 — 一次只准花 30 ms，超了就永久闭嘴。0.4.61 改成 250 ms + 本张卡（理由在
/// 下面那段「0.4.61」里，341 的 `remeasure slow 55ms … gone for this boot` 是物证）。
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
///   ② **事中**：记一次耗时。小表第一次跑两三毫秒，照旧用；一旦在**任何**一张
///      表上超过 250 ms，这张牌打掉，**本张卡**内不再赌第二次（`…Dead`，band 上升沿
///      归零）。0.4.61 之前这里是 30 ms + 「本次启动永久」，341 证明那个组合会把
///      「浮窗修好了、全屏没得修」直接做出来。
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
    // 0.4.53 把门槛从 12 屏放到 40 屏，0.4.57 再放到 80 屏并补一道「行数」闸。
    //
    // 12 屏是 0.1.38 在「没有任何耗时读数」的情况下拍的保守值。336 第一次把它
    // 量出来：`page remeasure 2.8ms cls=AWEFeedTableView rows=11`（11 屏的表），
    // `3.3ms rows=8`、`3.0ms rows=11` —— 三毫秒，而 30 ms 的死亡闸一直挂着。
    //
    // 这个保守值正是「开卡之后要等 5~10 s 才排对」的直接原因：卡片是 717，
    // 抖音那张表的内容高 10252 = 14.3 屏 > 12 ⇒ 一次都没敢发，于是顶部那一页
    // 一直停在 932（`inside settle box=717 c0=932 … 430x849`），底部 215 pt 被裁
    // —— 用户说的「点赞栏只显示一半、标题栏不显示」。
    //
    // 0.4.57 为什么还要动它：338 里抖音在卡片里已经到
    // `span=430x27960 box=717` = **39.0 屏**，离 40 只差一步。一旦撞上，0.4.56
    // 那条「每一次滑动都检测」就会静默失效（`cell fit fix … r=0`）。真正防看门狗
    // 的是下面那道 30 ms 实测闸，这一条只是「明显不合理的表不碰」—— 而行数比
    // 内容高更能代表代价：`beginUpdates/endUpdates` 的开销随行数走，而无限 feed
    // 的内容高可以无限长。
    NSInteger rows = [table numberOfSections] > 0 ? [table numberOfRowsInSection:0] : 0;
    if ((box.size.height > 1.0 && span > box.size.height * 80.0) || rows > 400) {
        if (AevonTableRemeasureNotes < 3) {
            AevonTableRemeasureNotes += 1;
            char skip[176];
            snprintf(skip, sizeof(skip), "remeasure skip span=%.0f box=%.0f rows=%ld",
                     span, box.size.height, (long)rows);
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
    // 0.4.61 — 30 ms → 250 ms，且寿命从「本次启动」缩到「本张卡」。
    //
    // 341 把这条闸的代价量出来了，而且是它自己造成的：
    //
    //   15:11:26 page remeasure 3.2ms cls=AWEFeedTableView rows=8
    //   15:11:37 page remeasure 2.3ms cls=AWEFeedTableView rows=8
    //   15:11:39 page remeasure 2.4ms cls=AWEFeedTableView rows=8
    //   15:11:55 page remeasure 3.4ms cls=AWEFeedTableView rows=8
    //   15:12:23 page remeasure slow 55ms cls=AWEFeedTableView gone for this boot   ← 第 5 次
    //
    // 前四次都是 rows=8、两三毫秒；第五次表已经长到 23 屏（`span=21868`），代价
    // 55 ms。**代价随表长走，而 30 ms 是个固定值** —— 表一长必然撞死。撞死之后
    // `AevonTableRemeasure` 直接 `return NO`，而那一刻正是用户要「关掉浮窗、全屏
    // 打开」的时候：浮窗里那次咬牙修好了（55 ms 换来两行变 717），工具却被打坏了，
    // 接下来全屏要修时一次机会都没有。用户看到的就是「浮窗正常、全屏断层」。
    //
    // 55 ms 与那条 10 秒看门狗差 180 倍，它不是风险源；真正要防的是「一次跑十秒」。
    // 250 ms 是 1/40，仍是安全余量，而它够得着「一两屏的长表」这一整类。
    // Dead 也不再是「本次启动永久」——一次撞上贵表就废掉整次启动，代价远大于收益。
    if (cost > 250.0) {
        AevonTableRemeasureDead = 1;
        char slow[176];
        snprintf(slow, sizeof(slow), "remeasure slow %.0fms cls=%s gone for this card",
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

// ===========================================================================
// 0.4.53 — 换屏之后**唯一**还允许做的动作：请 App 把自己的行高重量一遍
// ===========================================================================
//
// 退休 `AevonPageRideRetired` 之后，剩下的真问题只有一个，而且它是 336 里最直白
// 的一条读数：
//
//   13:41:44  page transition h=717 last=932 full=932      ← 卡片已经 717
//   13:41:46  page inside settle box=717 c0=932 … vid=DDanmakuPlayerView:…430x849
//
// 视口是 717，顶部那一页还是 932 高、视频还是 849 高 —— 底部 215 pt 被裁，就是
// 「点赞栏只显示一半、标题栏不显示」。App 自己会重排，但要等到它下一次复用那一页
// （336 里是 5~10 s 之后，还是被我们那八次 offset 写入推着走的）。
//
// 它缺的只是一句「你缓的行高过期了」。`beginUpdates`/`endUpdates` 在 336 里每次
// 只花 2.8~3.3 ms（`page remeasure` 那三行），所以这里把它留成唯一的手段，四道闸：
//
//   ① 一次尺寸变化最多**两拍**，间隔 0.45 s；
//   ② 手指在动 / 惯性中不发（`AevonTableRemeasure` 里那一组判据）；
//   ③ 真花超过 30 ms 就本次启动永久闭嘴（`AevonTableRemeasureDead`）；
//   ④ 量到「页高齐了」立刻收工 —— 不是定时发，是发到对齐为止。
//
// 第二手段只有一条，用在「发完还是不对齐」的那一页上：只重载**那一行**
// （`reloadRowsAtIndexPaths:`），不是整表。用户的抱怨是「打开时排版慢」，而慢的
// 那一页就是视口压着的那一页；重载它一次 ≈ 一次普通的 cell 复用，代价可控，
// 而整表 `reloadData` 会把所有在播的播放器一起重启，那是另一类事故。
//
// ⛔ 这里一行 `setContentOffset` 都没有。退休之后我们不再动用户的落点。
static int AevonSettleTries = 0;
static int AevonSettleReloads = 0;
static CFAbsoluteTime AevonSettleAt = 0.0;
static int AevonSettleNotes = 0;
/// `ride retired off=1` 只报一次（每进程一行）。
static int AevonRideNotes = 0;
static char AevonSettleWhy[] = "settle";

static BOOL AevonPagerAcquire(void);

// 0.4.56 — `AevonLayoutSettle` 的判据要用它，实现在下面（`AevonCellFitTick` 旁边）。
static CGFloat AevonCellOnScreen(UIScrollView *view, CGFloat box, UIView **cellOut);

// 0.4.59 — 「视口这一屏到底有几页、几页不对、有没有谁盖住视口中心」。
//
// 339 把 0.4.56 那条「每一拍量一次」为什么没治好断层写得很直白（14:42:24，
// 关卡那一拍）：
//
//   box=430x932 off=0,21436          ← 视口 932，落点 21436 = 23 × 932（App 自己算的）
//   k0=AWEFeedViewCell:17208,932x430 ← 唯一重建过的行
//   k1=AWEFeedViewCell:16491,717x430 ← 还是卡片里的 717
//   k2=AWEFeedViewCell:14196,717x430
//
// 21436 那一屏**没有任何一行**：最远只到 18140。视口整整空出 2.5 秒，直到 14:42:26
// 表被重建（span 19574 → 34484）才补上 `k2=21436,932x430`。而这两秒半里
// `cell fit` 与 `settle` **一行读数都没有** —— 它们量的都是「视口正中压着的那一页」，
// 找不到就 `cellH = 0`：`cell fit` 直接 `return`（不记账、不动作），`settle` 那边
// `cellH < 200 ⇒ cellOk = YES`（判成「齐了」）。**检查器在真正坏掉的那一刻自己闭眼。**
//
// 所以尺子换成一个结构：要数的是整个视口，不是正中那一格。
typedef struct {
    int n;          // 落在视口里的「一页大小」的格子数（不管高度对不对）
    int bad;        // 其中高度≠视口高的（差 > 40 pt）
    int blind;      // 有格子、但没有一格盖住视口中心 ⇒ 落点落在了所有行之外
    int cvBad;      // 0.4.61 — frame 对了、它自己的 contentView 还按旧高度排的格子数
    CGFloat worst;  // 最离谱那一格的高度（给日志用）
    CGFloat cv;     // contentView 高度：`cvBad>0` 时是最差那一格的，否则是正中那一格的
    UIView *__unsafe_unretained cvCell; // `cvBad>0` 时指向最差的那一格（只读，不持有）
} AevonSpanned;

// 0.4.61 — `cv` 原来只量「盖住视口中心的那一格」，341 证明这留了一个洞：
//
//   15:12:14 page state after change box=430x932 off=0,7423 cell=0,7815,430x932
//            k0=…:7815,932 k1=…:6883,932 k2=…:5951,932
//   15:12:27 page cell fit ok n=2 bad=0 cell=932 worst=0 box=932 cv=932 vid=430x849
//
// 读数全对，用户看到断层。因为 `cv=932` 只是正中那一格的；旁边那一格的
// contentView 可能还停在 717，没有任何一个数会说出来 —— 而「格子对了、里面的
// 内容没跟」正是断层的观感。所以逐格比一次，把最差的那一格连指针一起带出去。

static void AevonSpanMeasure(UIScrollView *view, CGFloat box, AevonSpanned *out,
                             UIView **midOut);

/// 只重载「视口压着、但高度不是视口高」的那一行。返回 1 = 真的重载了一次。
static BOOL AevonTableReloadStaleRow(UITableView *table, CGFloat box) {
    if (table == nil) return NO;
    if ([table window] == nil) return NO;
    if ([table isTracking] || [table isDragging] || [table isDecelerating]) return NO;
    CGFloat y = [table contentOffset].y;
    UIView *bad = nil;
    NSArray *kids = [table subviews];
    NSUInteger limit = kids.count < 12 ? kids.count : 12;
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *kid = [kids objectAtIndex:i];
        CGRect f = [kid frame];
        CGFloat h = f.size.height;
        if (h < box * 0.5 || h > box * 1.5) continue;
        if (CGRectGetMaxY(f) <= y + 2.0) continue;      // 回收池里的旧行
        if (f.origin.y >= y + box - 2.0) continue;      // 整页在视口下面
        if (fabs(h - box) <= 2.0) continue;             // 这一页是干净的
        bad = kid;
        break;
    }
    if (bad == nil) return NO;
    if (![bad isKindOfClass:[UITableViewCell class]]) return NO;
    NSIndexPath *path = [table indexPathForCell:(UITableViewCell *)bad];
    if (path == nil) return NO;
    NSArray *one = [NSArray arrayWithObject:path];
    BOOL ok = NO;
    @try {
        [UIView performWithoutAnimation:^{
            [table reloadRowsAtIndexPaths:one withRowAnimation:UITableViewRowAnimationNone];
        }];
        ok = YES;
    } @catch (NSException *exception) {
        ok = NO;
    }
    if (ok) {
        char body[200];
        snprintf(body, sizeof(body), "settle reload row=%ld,%ld h=%.0f box=%.0f",
                 (long)[path section], (long)[path row],
                 [bad frame].size.height, box);
        AevonPageWrite(body);
    }
    return ok;
}

/// 一拍。`reason` 只是日志里的名字。
static void AevonLayoutSettle(void *context) {
    const char *reason = (const char *)context;
    if (reason == NULL) reason = AevonSettleWhy;
    if (!AevonEverHosted) return;
    if (!AevonPageRideRetired) return;      // 常量改回 0 ⇒ 交还给 0.0.7x 那条路
    UIScrollView *view = AevonPagerGet();
    if (view == nil || [view window] == nil) {
        (void)AevonPagerAcquire();
        view = AevonPagerGet();
    }
    if (view == nil || [view window] == nil) return;
    CGRect box = [view bounds];
    if (box.size.height < 200.0) return;
    int clean = 0;
    int stale = 0;
    int aligned = 0;
    AevonPagerStats(view, box.size.height, &clean, &stale, &aligned);
    UIView *kid = AevonPageKidAt(view, box.size.height, [view contentOffset].y);
    CGFloat top = kid != nil ? [kid frame].size.height : 0.0;
    // 0.4.56 — 判据补上「视口正中那一页」。
    //
    // 338 里 `settle ok … top=717 box=717` 与 `tall cls=AWEFeedViewCell b=430x932`
    // 出现在同一秒：`top` 量的是「子视图里最像一页的那个」，而压着视口的那一页
    // 可以是另一格 —— 判据因此说「齐了」，用户看到的却是底部 215 pt 被裁。
    // 现在两把尺子都要过：子视图页高，与 `visibleCells` 里正中那一格。
    // 0.4.59 — **动作的判据只剩整幅视口**（`bad` / `blind`），`stale` 与 `top`
    // 降级成证词。339 的 14:41:22 是这条改动的理由：
    //
    //   settle again settle n=1 clean=1 stale=1 top=717 cell=932 box=932 r=1
    //
    // 正中那一格已经是 932（用户正看着它），只是表里还留着一行旧的 717，我们就
    // 发了一次整表重量 —— 而那一次正落在「从卡片切回全屏」的当口，是断层出现的
    // 两个时刻之一，却修不了任何用户看得见的东西。
    AevonSpanned span;
    AevonSpanMeasure(view, box.size.height, &span, NULL);
    CGFloat cellH = AevonCellOnScreen(view, box.size.height, NULL);
    BOOL rowsOk = (span.bad == 0 && !span.blind);
    // 判据只看**视口这一屏**：用户看见的是这一屏。`aligned`（内容高是不是视口的
    // 整数倍）取决于整张表都重排完，而抖音在卡片里往往只重排当前页 —— 拿它当
    // 收工条件会让这条通道永远在等一个不会到的状态。它只进日志，不进判据。
    if (rowsOk) {
        if (AevonSettleNotes < 6) {
            AevonSettleNotes += 1;
            char body[240];
            snprintf(body, sizeof(body),
                     "settle ok %s clean=%d stale=%d top=%.0f cell=%.0f box=%.0f al=%d",
                     reason, clean, stale, top, cellH, box.size.height, aligned);
            AevonPageWrite(body);
        }
        AevonSettleTries = 2;               // 对齐了：这一轮不再发
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonSettleAt > 0.0 && now - AevonSettleAt < 0.45) return;
    // ① 先请它重排行高（两次机会）。
    if (AevonSettleTries < 2 && [view isKindOfClass:[UITableView class]]) {
        AevonSettleAt = now;
        AevonSettleTries += 1;
        BOOL did = AevonTableRemeasure((UITableView *)view);
        char body[260];
        snprintf(body, sizeof(body),
                 "settle again %s n=%d clean=%d stale=%d top=%.0f cell=%.0f box=%.0f bad=%d blind=%d r=%d",
                 reason, AevonSettleTries, clean, stale, top, cellH, box.size.height,
                 span.bad, span.blind, did ? 1 : 0);
        AevonPageWrite(body);
        return;
    }
    // ② 两次都发完还是不对 ⇒ 只重载那一行一次。
    //
    // 0.4.59 — 门槛从 `top > 200` 换成「视口里确有坏页」。339 那种落点落在所有行
    // 之外的情形 `top` 是 932（最近的那一行），旧条件会放它进来，然后
    // `AevonTableReloadStaleRow` 按「整页在视口下方」的规则一行都挑不出来 ——
    // 白跑一趟。`blind` 一律交给下一拍继续重量行高，不再走重载。
    if (AevonSettleTries >= 2 && AevonSettleReloads < 1 && span.bad > 0 && !span.blind
        && [view isKindOfClass:[UITableView class]]) {
        AevonSettleAt = now;
        if (AevonTableReloadStaleRow((UITableView *)view, box.size.height)) {
            AevonSettleReloads = 1;
        }
        return;
    }
    if (AevonSettleTries >= 2 && AevonSettleNotes < 6) {
        AevonSettleNotes += 1;
        char body[200];
        snprintf(body, sizeof(body), "settle give up %s clean=%d stale=%d top=%.0f box=%.0f",
                 reason, clean, stale, top, box.size.height);
        AevonPageWrite(body);
    }
}

/// 一次尺寸变化把上面那个计数器全部归零（两个方向各自一轮）。
static void AevonLayoutSettleArm(void) {
    AevonSettleTries = 0;
    AevonSettleReloads = 0;
    AevonSettleAt = 0.0;
}

// ===========================================================================
// 0.4.56 — 每一拍量一次「视口压着的那一页，还是视口那么高吗」
// ===========================================================================
//
// 338 把「滑一会儿它自己就好了」拍成了读数：
//
//   14:18:53  page transition h=717 last=932 full=717      ← 卡片 717，`full` 也对了
//   14:18:54  layout audit n=1 tall cls=AWEFeedViewCell b=430x932 over=215
//   14:18:57  page pager keep box=717 span=430x4302 … pages=6
//
// 那三秒里视口是 717、压在上面那一页是 932（底部 215 pt 被裁、视频 849 高），
// 直到 App 自己把表建起来才按 717 重排。用户说的「滑动之后自动恢复真重排」，
// 恢复的那一刻不是滑动带来的魔法 —— 是那一页终于被复用重建。
//
// 所以这里只做一件事：**每一拍量一次页高**，不齐就请 App 重量行高
// （`AevonTableRemeasure`，338 里实测 2.8 / 5.1 ms）。五道闸：
//
//   ① 只在「这个进程被托管过」之后跑 —— 全屏抖音也跑，用户要求两边一致；
//      从没进过卡片的进程一律不碰（我们没有任何权限理由动它）；
//   ② 手指在动 / 惯性中只记账不动手（`AevonTableRemeasure` 本来也拒发）；
//   ③ 同一个高度连着两次都改不动 ⇒ 收手（`CellFitDead`），别把 App 拖进自激；
//   ④ 每张卡最多 6 次、间隔 ≥ 0.8 s；
//   ⑤ 动作永远只有 `beginUpdates`/`endUpdates` —— 一行 `setContentOffset`
//      都没有，落点归用户。
//
// ⛔ 判据只用「这一页 vs 视口」，不用屏幕高、不用窗口高：两套世界（卡片 717 /
// 全屏 932）用的是同一个算式，所以同一个函数在两个世界里都成立。
static int AevonCellFitNotes = 0;
static int AevonCellFixes = 0;
static int AevonCellFitSame = 0;
static int AevonCellFitDead = 0;
static int AevonCellFitStale = -1;
static int AevonCellFitBeats = 0;
static CGFloat AevonCellFitSeen = 0.0;
static CFAbsoluteTime AevonCellFitAt = 0.0;
/// 0.4.59 — 「格子 frame 对了、它自己的 contentView 还按旧高度排着」的次数与时刻。
static int AevonCellCvFixes = 0;
static CFAbsoluteTime AevonCellCvAt = 0.0;

/// 视口正中压着的那一页有多高。`visibleCells` 优先（表格自己知道谁在屏上，
/// 回收池里的旧行不会混进来）；拿不到就退到「子视图里命中视口中心的那一个」。
/// `cellOut` 只用来在日志里指名道姓（播放器那一层在不在这一格里）。
static NSString *AevonFindPlayer(UIView *root, CGRect *out);

static CGFloat AevonCellOnScreen(UIScrollView *view, CGFloat box, UIView **cellOut) {
    if (cellOut != NULL) *cellOut = nil;
    if (view == nil || box < 1.0) return 0.0;
    CGFloat mid = [view contentOffset].y + box * 0.5;
    // `visibleCells` 只有表格/集合视图有，`UIScrollView` 没有声明它 —— 走
    // `NSSelectorFromString` + `objc_msgSend`，免得 `-Werror` 把「未知选择子」
    // 当成错误。
    SEL visibleSel = NSSelectorFromString(@"visibleCells");
    if ([view respondsToSelector:visibleSel]) {
        NSArray *cells = ((NSArray *(*)(id, SEL))objc_msgSend)(view, visibleSel);
        for (UIView *cell in cells) {
            CGRect frame = [cell frame];
            if (frame.origin.y <= mid && mid < CGRectGetMaxY(frame)) {
                if (cellOut != NULL) *cellOut = cell;
                return frame.size.height;
            }
        }
    }
    UIView *kid = AevonPageKidAt(view, box, [view contentOffset].y);
    if (kid != nil && cellOut != NULL) *cellOut = kid;
    return kid != nil ? [kid frame].size.height : 0.0;
}

/// 视口的整幅读数（见 `AevonSpanned` 上面那段）。只读，不起任何作用。
///
/// `blind` 的判法：表格自己报的 `visibleCells` 非空，却没有一格的 frame 盖住
/// 「offset + box/2」 —— 那就是 339 的 14:42:24：落点 21436、最远的行只到 18140。
/// 这一刻用户看到的是空屏/残影，而旧判据在这里返回 0、被当成「没问题」。
static void AevonSpanMeasure(UIScrollView *view, CGFloat box, AevonSpanned *out,
                             UIView **midOut) {
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    if (midOut != NULL) *midOut = nil;
    if (view == nil || box < 200.0) return;
    CGFloat y = [view contentOffset].y;
    CGFloat mid = y + box * 0.5;
    SEL visibleSel = NSSelectorFromString(@"visibleCells");
    NSArray *cells = nil;
    BOOL authoritative = NO;
    if ([view respondsToSelector:visibleSel]) {
        cells = ((NSArray *(*)(id, SEL))objc_msgSend)(view, visibleSel);
        authoritative = (cells != nil);
    }
    if (cells.count == 0) cells = [view subviews];      // 集合视图没有 visibleCells 时
    NSUInteger limit = cells.count < 24 ? cells.count : 24;
    int sawMid = 0;
    CGFloat worstGap = 0.0;
    CGFloat midCv = 0.0;
    CGFloat worstCv = 0.0;
    CGFloat worstCvGap = 0.0;
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *cell = [cells objectAtIndex:i];
        if (![cell isKindOfClass:[UIView class]]) continue;
        CGRect f = [cell frame];
        CGFloat h = f.size.height;
        // 「一页」只可能落在视口高的一半到一个半之间。
        BOOL page = (h >= box * 0.5 && h <= box * 1.5);
        BOOL covers = (f.origin.y <= mid && mid < CGRectGetMaxY(f));
        if (covers && !sawMid) {
            sawMid = 1;
            if (midOut != NULL) *midOut = cell;
            if ([cell isKindOfClass:[UITableViewCell class]]) {
                midCv = [[(UITableViewCell *)cell contentView] bounds].size.height;
            }
        }
        if (!page) continue;
        if (CGRectGetMaxY(f) <= y + 2.0) continue;      // 整页在视口上面
        if (f.origin.y >= y + box - 2.0) continue;      // 整页在视口下面
        out->n += 1;
        CGFloat gap = fabs(h - box);
        if (gap > 40.0) {
            out->bad += 1;
            if (gap > worstGap) {
                worstGap = gap;
                out->worst = h;
            }
        }
        // 0.4.61 — 逐格比一次「格子 vs 它自己的 contentView」。只看「与视口相交」
        // 的那几格：视口外的行不影响用户看到的东西，追它没有意义。
        if (covers && [cell isKindOfClass:[UITableViewCell class]]) {
            CGFloat inner = [[(UITableViewCell *)cell contentView] bounds].size.height;
            CGFloat d = fabs(inner - h);
            if (d > 40.0) {
                out->cvBad += 1;
                if (d > worstCvGap) {
                    worstCvGap = d;
                    worstCv = inner;
                    out->cvCell = cell;
                }
            }
        }
    }
    // `cv` 的口径：有错配就报最差那一格（配 `cvCell`），否则报正中那一格 —— 后者
    // 是 0.4.59 起的旧口径，保留它，日志里同一个字段才可比。
    if (out->cvBad > 0) out->cv = worstCv;
    else if (midCv > 0.0) out->cv = midCv;
    // 有格子、却没有一格盖住视口中心 ⇒ 落点落在了所有行之外。这是「空屏」而不是
    // 「页高不对」，两种都要修，但日志里必须能分开。
    //
    // `authoritative` 只在「表格自己报的 visibleCells 非空」时为真。退路（走
    // `subviews`）时只认「确实有一页大小的子视图」才算，免得空表、页头这些东西
    // 被当成「落点飞了」。
    if (!sawMid && (authoritative ? cells.count > 0 : out->n > 0)) out->blind = 1;
}

static void AevonCellFitTick(UIScrollView *view) {
    if (view == nil) return;
    if (AevonCellFitDead) return;
    if (!AevonEverHosted) return;
    CGRect box = [view bounds];
    if (box.size.height < 200.0) return;
    AevonSpanned span;
    UIView *cell = nil;
    AevonSpanMeasure(view, box.size.height, &span, &cell);
    CGFloat cellH = (cell != nil) ? [cell frame].size.height : 0.0;
    // ⛔ 这里**不再** `if (cellH < 200) return`。339 的 14:42:24 就是死在这一条上：
    // 落点 21436 落在所有行之外，`AevonCellOnScreen` 找不到正中那一格 ⇒ 返回 0
    // ⇒ 这条通道整整 2.5 秒不记账也不动作，而屏幕上是空的。
    // 现在的判据是整幅视口：`bad`（有格子但高度不对）与 `blind`（没有一格盖住
    // 视口中心）任一成立就算坏。
    BOOL moving = ([view isTracking] || [view isDragging] || [view isDecelerating]);
    BOOL stale = (span.bad > 0 || span.blind);
    AevonCellFitBeats += 1;
    // 状态翻转时报一行；头两拍各报一行（那两拍正是开卡那一段，也是「打开要等
    // 两三秒」唯一能被看见的地方）；之后每 200 拍（≈30 s）报一行「我还在量」，
    // 让下一份日志能证明这条通道整场都在跑，而不是只在开头响了一声。
    BOOL beat = (AevonCellFitBeats % 200) == 0 && AevonCellFitNotes < 20;
    if (AevonCellFitNotes < 24
        && (AevonCellFitStale < 0 || stale != (AevonCellFitStale != 0)
            || AevonCellFitNotes < 2 || beat)) {
        AevonCellFitNotes += 1;
        char line[256];
        char vidText[96];
        vidText[0] = '\0';
        if (cell != nil) {
            CGRect vid = CGRectZero;
            NSString *name = AevonFindPlayer(cell, &vid);
            if (name != nil) {
                snprintf(vidText, sizeof(vidText), " vid=%.16s %.0fx%.0f@%.0f,%.0f",
                         [name UTF8String], vid.size.width, vid.size.height,
                         vid.origin.x, vid.origin.y);
            }
        }
        snprintf(line, sizeof(line),
                 "cell fit %s n=%d bad=%d cell=%.0f worst=%.0f box=%.0f cv=%.0f cvbad=%d%s%s%s",
                 stale ? "stale" : "ok", span.n, span.bad, cellH, span.worst,
                 box.size.height, span.cv, span.cvBad,
                 span.blind ? " blind=1" : "",
                 moving ? " moving=1" : "",
                 vidText);
        AevonPageWrite(line);
    }
    AevonCellFitStale = stale ? 1 : 0;
    if (!stale) {
        AevonCellFitSame = 0;
        // 0.4.59 — 页高对了不等于「画面对了」：339 里
        // `tall cls=UITableViewCellContentView b=430x932 over=215` 与 `cell=717`
        // 同时出现 —— 格子被表格改成了 717，它自己那一层内容还按 932 排着，
        // 于是底部 215 pt 连同标题条一起被裁掉。格子 frame 是对的，唯一的受害者
        // 是内层。这种情况不重排行高（那会白摆一遍版面），只请**这一格**重新
        // 排自己 —— `setNeedsLayout` 不写任何几何，contentView 的 frame 归 cell 管。
        // 0.4.61 — 从「只量正中那一格」扩到「可见格里最差的那一格」。341 的全屏
        // 读数全是 `bad=0 cell=932 cv=932`，而用户看到断层 —— 因为 `cv` 只量了
        // 正中那一格，旁边那一格的 contentView 停在 717 没人看。`cvCell` 就是那一格。
        UIView *cvCell = (span.cvBad > 0 && span.cvCell != nil) ? span.cvCell : cell;
        CGFloat cvFrame = (cvCell != nil) ? [cvCell frame].size.height : 0.0;
        if (cvCell != nil && !moving && span.cv > 200.0
            && fabs(span.cv - cvFrame) > 40.0
            && [cvCell window] != nil && ![cvCell isHidden]) {
            CFAbsoluteTime nowCv = CFAbsoluteTimeGetCurrent();
            if (AevonCellCvAt == 0.0 || nowCv - AevonCellCvAt > 0.8) {
                if (AevonCellCvFixes < 4) {
                    AevonCellCvAt = nowCv;
                    AevonCellCvFixes += 1;
                    [cvCell setNeedsLayout];
                    char cv[200];
                    snprintf(cv, sizeof(cv), "cell cv fix n=%d cv=%.0f cell=%.0f box=%.0f cvbad=%d",
                             AevonCellCvFixes, span.cv, cvFrame,
                             box.size.height, span.cvBad);
                    AevonPageWrite(cv);
                }
            }
        }
        return;
    }
    // 手指还在动：只记账。这时候插一脚只会把同一次布局拉长一倍。
    if (moving) return;
    if (![view isKindOfClass:[UITableView class]]) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonCellFitAt > 0.0 && now - AevonCellFitAt < 0.8) return;
    // 0.4.58 — 与 `settle` 共用节流。
    //
    // 换屏后的四拍（0.30 / 0.85 / 1.40 / 3.00 s）与这条 0.15 s 心跳会撞在同一拍上：
    // 一边刚发完 `beginUpdates/endUpdates`，另一边 100 ms 后再发一次 —— 两次重排
    // 背靠背，用户看到的是同一块版面被摆两遍。这一拍不发，等下一拍再看读数：
    // 如果真没修好，0.8 s 后照发不误。
    if (AevonSettleAt > 0.0 && now - AevonSettleAt < 0.8) return;
    if (AevonCellFixes >= 6) return;
    // 「改不动」的判据也要跟着换：`blind` 时 `cellH` 是 0，拿它比永远「没变」。
    AevonCellFitAt = now;
    AevonCellFixes += 1;
    BOOL did = AevonTableRemeasure((UITableView *)view);
    // 0.4.61 — 「动作没执行」不等于「改了也没用」。
    //
    // 341 的 15:12:23 之后 `AevonTableRemeasure` 被 30 ms 闸永久关掉，此后每一拍
    // 都只会 `r=0`。若那一拍拍样计进「同一高度」，两拍就 `cell fit give up` ——
    // 通道跟着工具一起死，而用户看到的正是「浮窗正常、全屏断层」。所以只有真的
    // 发出过 `beginUpdates/endUpdates`（`did`）才判「改不动」。
    if (did) {
        // 「改不动」的判据也要跟着换：`blind` 时 `cellH` 是 0，拿它比永远「没变」。
        CGFloat witness = span.blind ? -1.0 : (span.worst > 200.0 ? span.worst : cellH);
        if (fabs(witness - AevonCellFitSeen) < 1.0) AevonCellFitSame += 1;
        else AevonCellFitSame = 0;
        AevonCellFitSeen = witness;
        if (AevonCellFitSame >= 2) {
            AevonCellFitDead = 1;
            char stop[200];
            snprintf(stop, sizeof(stop), "cell fit give up cell=%.0f box=%.0f n=%d blind=%d",
                     cellH, box.size.height, AevonCellFixes, span.blind);
            AevonPageWrite(stop);
            return;
        }
    }
    char line[220];
    snprintf(line, sizeof(line), "cell fit fix n=%d bad=%d blind=%d cell=%.0f box=%.0f r=%d",
             AevonCellFixes, span.bad, span.blind, cellH, box.size.height, did ? 1 : 0);
    AevonPageWrite(line);
}

static NSInteger AevonPagerRebuild(const char *reason) {
    UIScrollView *view = AevonPagerGet();
    // 0.4.53 — 这条路上唯一做的事是 `beginUpdates` / `endUpdates`（整表作废行高
    // 缓存）。它本身不改几何，但它是「页不齐就重建」那条自激链的最后一环：
    // `AevonAlignPager` 见页不齐就发它，发完再算落点、写 offset，写歪了又见页不齐。
    // 退休整套干预之后它也不该再被任何人叫起来 —— 唯一还允许的那一次在
    // `AevonLayoutSettle`，它直接调 `AevonTableRemeasure`，有自己的配额与上限。
    if (AevonPageRideRetired) return -1;
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
    // 0.4.53 — 退休。见 `AevonPageRideRetired`：这一条下面每一行都会写
    // `contentOffset`，而那正是 336 里 `align … moves=8` 那只手。
    //
    // 欠账仍然要销：`AevonRemeasurePending` 是「交还整屏的重排等 App 回到前台
    // 再做」的记号，退休之后没人消费它；留着会让以后把常量改回 0 的那一版带着
    // 上一次会话的旧账醒来。
    if (AevonPageRideRetired) {
        AevonRemeasurePending = 0;
        return -1;
    }
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

/// 「差一点」的候选只在最后一次 acquire 里报三行 —— 它就是 340 那 6 秒的答案。
static int AevonPagerMissNotes = 0;

/// 找出「整屏一页」的翻页器并记住它。只在还没认出来的时候跑（一次遍历，
/// 上限 4000 个视图）——认出来之后所有后续判断都只读一个属性。
///
/// 0.4.60 — **准入判据必须吃得下「混装几何」**，这是 340 断层唯一的根。
///
///   14:58:01 page transition h=717 last=932 full=717      ← 卡片已经 717
///   14:58:01 page layout audit n=1 scroll cls=AWEFeedTableView box=430x717 span=9966 off=5736 cell=932
///   14:58:01~06  page state after change pager none       ← 整整 6 秒只有这一句
///   14:58:07 page pager keep box=717 span=430x15774 … pages=22   ← 抖音自己换回 717 才认出来
///
/// 那 6 秒里 `cell fit` **一行读数都没有**：它挂在 `AevonPagerGet()` 之后，而
/// 翻页器是 nil。为什么 nil —— `span=9966`、`box=717` ⇒ `pages=round(13.90)=14`、
/// `slack=9966−14×717=−72`，差 72 pt 落不进下面那条 24 pt 的整数倍判据；抖音
/// 这张表本来就不是分页的（`paging=0`），于是两道门都关着，`AevonPagerAcquire`
/// 每 0.6 s 试一次、连试 8 次全拒。
///
/// 而 9966 恰恰就是「一半行还是 932 的旧高、一半已经是 717」这种混装表的尺寸：
/// 用 932 算它也不是整数倍（`9966/932=10.69`），用 717 算也不是。**「一页多高」
/// 在混装里没有唯一答案，拿它当准入门槛等于在最该修的那一刻把唯一的通道关掉。**
/// 所以准入改成「余量不超过半页」：视口仍然必须占满整窗（`|box−H| ≤ 40`）、
/// 内容仍然必须长过 1.6 屏、页数仍然 ≥ 2，只是不再要求它整除。
static BOOL AevonPagerAcquire(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return NO;
    CGFloat missBox = 0.0;
    CGFloat missSpan = 0.0;
    CGFloat missSlack = 0.0;
    double missPages = 0.0;
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
                        CGFloat slack = span.height - pages * box.height;
                        // 整数倍那条从 8 pt 放宽到 24 pt，理由同上：中间态。
                        BOOL exact = (pages >= 2.0 && fabs(slack) <= 24.0);
                        // 0.4.60 — 混装：见函数头。只放行**表格/集合视图**
                        // （混装页高只可能出现在「一格就是一页」的那两种视图上），
                        // 且余量不足半页 —— 差得比半页还多说明是 `round` 取错了
                        // 方向，那是别的东西，不是混装。
                        BOOL tabular = ([view isKindOfClass:[UITableView class]]
                                        || [view isKindOfClass:[UICollectionView class]]);
                        BOOL ragged = (tabular && pages >= 2.0
                                       && fabs(slack) <= box.height * 0.5);
                        if (exact || ragged || [view isPagingEnabled]) {
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
                                     "inset=%.0f paging=%d pages=%.0f "
                                     "slack=%.0f ragged=%d",
                                     box.height, span.width, span.height,
                                     cell.origin.x, cell.origin.y,
                                     cell.size.width, cell.size.height,
                                     [view contentOffset].y, [view contentInset].top,
                                     [view isPagingEnabled] ? 1 : 0, pages,
                                     slack, (exact || [view isPagingEnabled]) ? 0 : 1);
                            AevonPageWrite(body);
                            return YES;
                        }
                        // 视口对上了、只是页数不整：这是唯一值得记下来的拒绝，
                        // 记第一个就够（后面往往是它的子视图）。
                        if (missBox == 0.0) {
                            missBox = box.height;
                            missSpan = span.height;
                            missSlack = slack;
                            missPages = pages;
                        }
                    }
                }
                NSArray *kids = [node subviews];
                if (kids.count > 0) [todo addObjectsFromArray:kids];
            }
        }
    }
    if (missBox > 0.0 && AevonPagerMissNotes < 3) {
        AevonPagerMissNotes += 1;
        char miss[200];
        snprintf(miss, sizeof(miss),
                 "pager miss box=%.0f span=%.0f pages=%.0f slack=%.0f",
                 missBox, missSpan, missPages, missSlack);
        AevonPageWrite(miss);
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
    if (root == nil) return nil;
    // 0.4.61 — 名字里带 Player 的不一定是画面。
    //
    // 341 的 15:11:26 那一拍挑中的是 `AWEDPlayerProgre 430x200@0,649`（进度条视图），
    // 于是同一份日志里一边写着「播放器只有 200 高」、另一边是
    // `DDanmakuPlayerView 430x849` —— 读数自相矛盾，而真正要看的画面是后者。
    // 一段竖屏画面至少占格子的一半，所以挑第一个「够大」的；都不够大才退回第一个
    // 命中的（保持旧行为，免得在别的 App 上一条都读不出来）。
    CGFloat need = [root bounds].size.height * 0.4;
    NSString *fallback = nil;
    CGRect fallbackRect = CGRectZero;
    NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
    NSUInteger walked = 0;
    while (todo.count > 0 && walked < 400) {
        UIView *node = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        const char *name = class_getName([node class]);
        if (name != NULL && (strstr(name, "Player") != NULL || strstr(name, "Video") != NULL)) {
            CGRect rect = [node convertRect:[node bounds] toView:root];
            if (rect.size.height >= need) {
                if (out != NULL) *out = rect;
                return [NSString stringWithUTF8String:name];
            }
            if (fallback == nil) {
                fallback = [NSString stringWithUTF8String:name];
                fallbackRect = rect;
            }
        }
        NSArray *kids = [node subviews];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }
    if (fallback != nil && out != NULL) *out = fallbackRect;
    return fallback;
}

/// 0.4.59 — **画面那一层**多大。
///
/// 抖音的播放器视图叫 `DDanmakuPlayerView`，它只是容器；真正承载画面的是里面那个
/// 图层。两者尺寸不一致时，用户看到的就是「画面比格子矮一截 / 整体上移 / 底部
/// 一条黑」—— 而 `vid=` 那一行到 339 为止只答得了视图尺寸，答不了画面的。
/// 这正是「断层」剩下唯一没被量过的那一层。
static CGSize AevonFindVideoLayer(UIView *root, NSString **nameOut) {
    if (nameOut != NULL) *nameOut = nil;
    CALayer *start = [root layer];
    if (start == nil) return CGSizeZero;
    Class playerLayer = NSClassFromString(@"AVPlayerLayer");
    NSMutableArray *todo = [NSMutableArray arrayWithObject:start];
    NSUInteger walked = 0;
    while (todo.count > 0 && walked < 400) {
        CALayer *layer = [todo lastObject];
        [todo removeLastObject];
        walked += 1;
        const char *cname = class_getName([layer class]);
        BOOL hit = (playerLayer != Nil && [layer isKindOfClass:playerLayer]);
        if (!hit && cname != NULL
            && (strstr(cname, "PlayerLayer") != NULL || strstr(cname, "VideoLayer") != NULL)) {
            hit = YES;
        }
        if (hit) {
            if (nameOut != NULL && cname != NULL) {
                *nameOut = [NSString stringWithUTF8String:cname];
            }
            return [layer bounds].size;
        }
        NSArray *kids = [layer sublayers];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }
    return CGSizeZero;
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

/// 0.4.51 — **本职退休**（用户 334 明令：它没改善「视频在卡片里偏上」，可以撤）。
///
/// 说清楚它为什么从来没帮上忙，而不是「效果不好」：
///
///   · 它整条链的入口是 `AevonPagerGet()`。那个函数给抖音返回过 `nil` —— 334 里
///     `app: page … pager none` 从开卡到关卡一共 11 条，`app: video` **0 条**。
///   · 原因在 `AevonPagerAcquire` 的门槛：「一页 = 一窗」（`|box − H| ≤ 40`）。抖音
///     的 feed 一页按 932 排、窗口 717，第一步就被挡在外面，后面所有动作
///     （扫画面、写 transform、装 `layoutSubviews` 钩子）一次都没执行过。
///   · 也就是说它不是这次「内容显示不全」的原因 —— 一个从没跑过的函数改不了任何
///     人的排版。它唯一的实际影响是：**它是全工程唯一会在别人 `layoutSubviews`
///     里改几何的入口**（`AevonHookLayout` 只从这里装），而那条路在 0.0.85 制造过
///     33,468 次排版/秒的看门狗强杀。
///
/// 撤法是「关入口」而不是删函数体：下面所有 `video …` 读数串仍留在二进制里
/// （审计按串数验收），但一次都不会被执行。用 `volatile const` 而不是 `#if 0`，
/// 编译器不能把它折成常量、也就不会把整段判成死代码。
static volatile const int AevonVideoCenterRetired = 1;
/// 退休这件事只报一次：判据是日志里出现 `video retired off=1`，而不是「没有
/// `video band`」—— 后者也可能是「这一版没遇到能居中的画面」，两种结论差很远。
static int AevonVideoRetireNotes = 0;

static void AevonVideoCenter(void) {
    if (AevonVideoCenterRetired) {
        if (AevonVideoRetireNotes == 0) {
            AevonVideoRetireNotes = 1;
            AevonPageWrite("video retired off=1");
        }
        return;
    }
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
        // 0.4.53 — 「整套干预已退休」只报一行。它是这一版的验收判据本身：
        // 下一份日志里出现它、且不再有 `align … moves=`，就说明方向盘真的还回去了。
        if (AevonPageRideRetired && AevonRideNotes == 0) {
            AevonRideNotes = 1;
            AevonPageWrite("ride retired off=1");
        }
        // 0.0.79 — 换屏之前记下「本来在播」。**只记，不管**：替它按 play 的那三拍
        // 随干预一起退休（0.4.53）。这一行读数仍然有用 —— 下一份日志里
        // `play note was=1` 而画面确实自己回来了，就证明那些「停住」本来是我们的
        // offset 写入造成的。
        AevonPlayNote();
        // 0.4.53 — 这三拍**照旧排上去，但一拍都不会动手**：`AevonResumeTick` 的
        // 第一行就是 `if (AevonPageRideRetired) return;`。留着调用点有两个用处：
        // 常量改回 0 时整条路原样回来；以及不让这个函数变成「没人调用的静态函数」
        // （`-Wunused-function` 在 `-Werror` 下是编译失败）。
        AevonResumes = 0;
        for (int i = 0; i < 3; i++) {
            int64_t when = (int64_t)((0.5 + 0.85 * (double)i) * NSEC_PER_SEC);
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, when),
                             dispatch_get_main_queue(), (void *)AevonResumeWhy, AevonResumeTick);
        }
        // 先记一张「换算前」的：这一张能回答「App 收到 932↔717 时，它的页是不是
        // 也跟着变了」。
        AevonPageState("on transition");
        AevonAnchorRemember(AevonPagerGet(), before);
        // 0.4.53 — 换屏之后唯一还允许的动作（见 `AevonLayoutSettle`）。
        //
        // 0.4.59 — 前两拍从 0.30 / 0.85 提前到 **0.06 / 0.18**。
        //
        // 339 的 14:41:21~22 把晚的代价拍成了读数：换屏那一刻 App 已经按页下标
        // 把落点算成 2 × 932 = 1864，而行还是卡片里的 717 ⇒ 屏幕上半截是第 2 条
        // 的尾巴、下半截是第 3 条的头，**那一刀就横在窗口中间**。我们要到 0.30 s
        // 才发第一次重量，所以它至少完整地亮了一帧到好几帧。表格自己在同一拍
        // 之内就能把行高换成新值（实测 2.8~5.1 ms），差的就是这声通知早到。
        //
        // 采样时刻：0.06 / 0.18 / 0.34 / 0.90 / 3.00 s。前三拍量到对齐就收工
        // （`AevonSettleTries` 仍然最多发两次），最后一拍只为「慢」留证词 ——
        // 抖音自己的首次构建有时要两三秒，那一段改不到。
        AevonLayoutSettleArm();
        {
            const double ladder[5] = {0.06, 0.18, 0.34, 0.90, 3.00};
            for (int i = 0; i < 5; i++) {
                dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,
                                               (int64_t)(ladder[i] * (double)NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), (void *)AevonSettleWhy,
                                 AevonLayoutSettle);
            }
        }
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

// ---------------------------------------------------------------------------
// 0.4.51 — 卡片里的排版对账（只读 + 一次温和置脏）
// ---------------------------------------------------------------------------
// 334 之后唯一还说不清的事：卡片里打开抖音，内容有时「显示不全」—— 右侧点赞栏
// 只剩一半、视频底部的标题条整条不见。这两个症状是**同一个形状**：整块排版比窗口
// 高。932 的版式放进 717 的窗，底部 215 被裁掉，而点赞栏与标题条恰好都挂在画布
// 底部，于是「一列剩一半、一条全没」。
//
// 我们手上已经能证明的：宿主侧几何全对（`scene=430x717`、`content=430x717@0,0`、
// `scale` 一致），`app: video` 一条都没有（居中那条路从没跑过，见
// `AevonVideoCenterRetired`）⇒ 不是我们挪过谁。剩下的可能只有两种：
//
//   ① App 自己按 932 排了版（窗口/根视图还停在 932）；
//   ② 某一层没跟着窗口变（视口 717，里面的翻页器还是 932）。
//
// 这条探针就是这两句话的判据，两拍（首拍 + 约 2 s）各一遍，**只读**：
//
//   layout audit n=1 win=430x717 scene=430x717 root=430x717
//   layout audit n=1 scroll cls=AWEFeedTableView box=430x932 span=430x10252 off=932
//   layout audit n=1 tall cls=AWEFeedContainerView b=430x932 over=215
//
// `win` 与 `scene` 不一致 ⇒ ①；`scroll box` 比 `win` 高 ⇒ ②，而且 `tall` 指名道姓
// 说出是哪一层。唯一动一下手的地方在最后：`over` 超过 60 pt 时对那一层发一次
// `setNeedsLayout`（**只置脏，绝不 `layoutIfNeeded`** —— 0.0.65/0.0.67 那两次
// 「应用打不开、桌面黑屏」正是「替别人的窗口补一次布局」）。每层一次、每会话最多
// 三条，日志总量 20 行封顶。
//
// 0.4.52 — **采样窗口挪到开卡后的前 1.5 s，四拍。**
//
// 335 之后问题换了一个形状：抖音不再是「一直排错」，而是「打开约 2 s 才排对」。
// 0.4.51 那两拍（首拍 + 1.8 s）落在用户已经在滑的时候（`audit n=1` 出现在
// 13:18:47，开卡后 40 s），拍到的全是「已经对了」的读数 —— 对判「那 2 s 里发生了
// 什么」没有用。现在改成 0 / 0.30 / 0.80 / 1.50 s 四拍，正好盖住用户说的那一段。
//
// 四拍 × 3 行（`win` / `scroll` / 可能的 `tall`）≈ 12~16 行，加上 nudge 也还在
// 20 行以内 —— 一份 941 行的日志不会因为这几行变难读。
#define AEVON_AUDIT_LINES 30
#define AEVON_AUDIT_PASSES 8
/// 八拍的时刻（相对首拍）。第一项必须是 0：它同时用来记 `AevonAuditAt`。
///
/// 0.4.62 — 后四拍（2.5 / 3.5 / 5.0 / 7.0 s）只在**前几拍 `scroll none`** 时启用。
/// 342 的第三次开卡（冷启动）四拍全是 `scroll none`（`walk=74/273/279/279`），
/// 四拍之后这张卡就再没有读数了 —— 而用户看到的断层正好在那之后。
/// 不知道「表什么时候建好、建好时是几 px」，下一版就只能猜。
static const double AevonAuditGap[AEVON_AUDIT_PASSES] = {0.0, 0.30, 0.80, 1.50, 2.50, 3.50, 5.00, 7.00};
static int AevonAuditPass = 0;
/// 0.4.62 — 这一张卡允许几拍。默认 4；第一拍 `scroll none`（表还没建）放到 8。
static int AevonAuditLimit = 4;
static CFTimeInterval AevonAuditAt = 0.0;
static int AevonAuditLines = 0;
static int AevonAuditNudges = 0;
/// 0.4.56 — 上一拍宿主有没有说「被托着」。上升沿 = 新的一张卡。
static int AevonAuditHostedWas = 0;

static const char *AevonAuditCls(UIView *view) {
    if (view == nil) return "none";
    const char *name = class_getName([view class]);
    return name != NULL ? name : "?";
}

static void AevonHostedAudit(void) {
    // 0.4.52 — 闸从 `AevonEverHosted` 换成「宿主此刻还说这个 App 被托着」。
    // 前者要等一次 24 pt 的高度跳变才置位，而这一版正是要拍「跳变之前」那一段。
    if (!AevonBandHostedNow()) return;
    if (AevonAuditPass >= AevonAuditLimit) return;
    if (AevonAuditLines >= AEVON_AUDIT_LINES) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (AevonAuditPass == 0) {
        AevonAuditAt = now;
    } else if (now - AevonAuditAt < AevonAuditGap[AevonAuditPass]) {
        return;      // 还没到这一拍的时刻
    }

    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return;
    // 主窗优先：`keyWindow` 对「正在显示什么」最有发言权；没有 key（刚从后台
    // 回来那一拍）就退到第一个有尺寸的窗口。两种都要，缺一种就会在中间态
    // 里读到空值、然后一整个会话都没有读数。
    UIWindow *win = nil;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in [(UIWindowScene *)one windows]) {
            if ([candidate isKeyWindow]) { win = candidate; break; }
            if (win == nil && [candidate bounds].size.height > 200.0) win = candidate;
        }
        if (win != nil && [win isKeyWindow]) break;
    }
    if (win == nil) return;

    AevonAuditPass += 1;
    CGFloat winH = [win bounds].size.height;
    CGRect card = [[win windowScene] coordinateSpace].bounds;
    UIViewController *rvc = [win rootViewController];
    UIView *root = nil;
    if (rvc != nil) root = [rvc view];
    if (root == nil && [win.subviews count] > 0) root = [win.subviews objectAtIndex:0];
    if (root == nil) root = win;
    CGRect rb = [root bounds];

    char line[224];
    int used = 0;
    snprintf(line, sizeof(line),
             "layout audit n=%d win=%.0fx%.0f scene=%.0fx%.0f root=%.0fx%.0f",
             AevonAuditPass, [win bounds].size.width, winH,
             card.size.width, card.size.height, rb.size.width, rb.size.height);
    AevonPageWrite(line);
    used += 1;

    // 一遍广度优先走完窗口：顺带把「比窗口高出来的那一层」与「最像翻页器的
    // 滚动视图」挑出来。2500 个视图约 0.3 ms，两拍一共两次，可以忽略。
    NSMutableArray *todo = [NSMutableArray arrayWithObject:root];
    NSUInteger walked = 0;
    UIView *tall = nil;
    CGFloat tallOver = 0.0;
    UIScrollView *pager = nil;
    CGFloat pagerGap = 0.0;
    while (walked < todo.count && walked < 2500) {
        UIView *node = [todo objectAtIndex:walked];
        walked += 1;
        CGRect b = [node bounds];
        CGFloat over = b.size.height - winH;
        if (over > 60.0 && over > tallOver) { tallOver = over; tall = node; }
        if ([node isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)node;
            CGFloat boxH = [sv bounds].size.height;
            CGFloat gap = fabs(boxH - winH);
            // 只认「本来应该是整屏视口」的那一个：差得越小越像。
            if (boxH > 200.0 && gap < 320.0 && [sv contentSize].height > boxH * 1.6
                && (pager == nil || gap < pagerGap)) {
                pager = sv;
                pagerGap = gap;
            }
        }
        NSArray *kids = [node subviews];
        if (kids.count > 0) [todo addObjectsFromArray:kids];
    }

    if (pager != nil) {
        // 0.4.56 — 补一个 `cell=`：`tall` 是从整棵树里挑「最高的一层」，
        // 回收池里的旧行也能被挑中（338 的 `tall cls=AWEFeedViewCell b=430x932`
        // 与 `k0=…:717,717x430` 同时出现就是这么来的）。真正决定用户看到什么的
        // 是「视口正中压着的那一页」，用同一把尺子写进同一行。
        CGFloat cellNow = AevonCellOnScreen(pager, [pager bounds].size.height, NULL);
        snprintf(line, sizeof(line),
                 "layout audit n=%d scroll cls=%.24s box=%.0fx%.0f span=%.0f off=%.0f paging=%d cell=%.0f",
                 AevonAuditPass, AevonAuditCls(pager),
                 [pager bounds].size.width, [pager bounds].size.height,
                 [pager contentSize].height, [pager contentOffset].y,
                 [pager isPagingEnabled] ? 1 : 0, cellNow);
        AevonPageWrite(line);
        used += 1;
    } else {
        snprintf(line, sizeof(line), "layout audit n=%d scroll none walk=%lu",
                 AevonAuditPass, (unsigned long)walked);
        AevonPageWrite(line);
        used += 1;
        // 0.4.62 — 表还没建 ⇒ 把窗口从四拍拉到八拍（到 7 s）。
        //
        // 342 第三次开卡：`scroll none` 四拍全中，四拍之后这张卡一行读数都没有，
        // 而用户报的断层就在那一段。表建好是几 px、那时我们在哪一拍 —— 全都没
        // 记下来，只能靠猜。八拍 24 行仍在配额里（正常情形四拍 12 行不变）。
        if (AevonAuditPass <= 1) AevonAuditLimit = AEVON_AUDIT_PASSES;
    }

    if (tall != nil) {
        snprintf(line, sizeof(line),
                 "layout audit n=%d tall cls=%.28s b=%.0fx%.0f over=%.0f",
                 AevonAuditPass, AevonAuditCls(tall),
                 [tall bounds].size.width, [tall bounds].size.height, tallOver);
        AevonPageWrite(line);
        used += 1;
    }
    // 0.4.54 — 播放器那一层：卡片里它到底多高。
    //
    // 这是「视频断层」唯一的直接读数。336 的 `inside settle box=717 c0=932
    // vid=DDanmakuPlayerView:0,0,430x849` 已经给出过一次答案：**cell 932、
    // 视频 849（= 932 − 83 的标签栏）**，而窗口只有 717 ⇒ 视频比视口高
    // 132 pt，画面被裁、切回全屏时再被拉回去 —— 用户看到的就是那一刀。
    // 849 只可能来自「屏幕高 932」，不可能来自「窗口 717」，所以这一行同时
    // 是 0.4.54 那条几何判据的验收：修好之后这里应当是 **430x634**。
    if (pager != nil && AevonAuditPass <= 2) {
        // 0.4.59 — 挑「盖住视口中心的那一页」，与 `cell fit` 同一把尺子。
        // 旧写法取「第一个高度超过半屏的子视图」，那不是用户看的那一页。
        AevonSpanned sp;
        UIView *page = nil;
        AevonSpanMeasure(pager, [pager bounds].size.height, &sp, &page);
        if (page != nil) {
            CGRect vid = CGRectZero;
            NSString *name = AevonFindPlayer(page, &vid);
            CGSize surface = AevonFindVideoLayer(page, NULL);
            snprintf(line, sizeof(line),
                     "layout audit n=%d vid=%.20s %.0fx%.0f@%.0f,%.0f cv=%.0f pre=%.0fx%.0f",
                     AevonAuditPass, name != nil ? [name UTF8String] : "none",
                     vid.size.width, vid.size.height, vid.origin.x, vid.origin.y,
                     sp.cv, surface.width, surface.height);
            AevonPageWrite(line);
            used += 1;
        }
    }
    // 0.4.54 — 置脏只对**视口自己**，不再对着 `tall` 乱戳。
    //
    // 0.4.52 那一版是按 `tall`（最高的那一层）戳的，判据是「转进窗口坐标后
    // 真在屏上」。337 里三次戳的全是 `UITableViewCellContentView b=430x932`：
    // 它是 cell 的内层，**管不了自己的 frame**（cell 多高由表格决定），戳它
    // 只会让 App 白排一次；而那一拍正好可能在放视频 —— 本版要收的就是这一类
    // 无谓的重排。真正能自己决定尺寸的是滚动视口：它比窗高 60 pt 才说明
    // 「视口没跟上」，那才值得戳一次。
    if (pager != nil && AevonAuditNudges < 3) {
        CGFloat over = [pager bounds].size.height - winH;
        if (over > 60.0 && [pager window] != nil && ![pager isHidden] && [pager alpha] > 0.01) {
            AevonAuditNudges += 1;
            [pager setNeedsLayout];
            snprintf(line, sizeof(line),
                     "layout nudge cls=%.28s over=%.0f win=%.0f n=%d",
                     AevonAuditCls(pager), over, winH, AevonAuditNudges);
            AevonPageWrite(line);
            used += 1;
        }
    }
    AevonAuditLines += used;
}

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
    }
    // 0.4.52 — **下面这两件挪出 `shrunk`。**
    //
    // `shrunk` 的算式是 `[UIScreen bounds] < 全屏 − 40`，而 `-bounds` 已经被我们
    // 改成承载面了 ⇒ 两边都是 717 ⇒ 恒等于假。335 里 `video retired off=1` 一条
    // 都没有，就是因为它挂在这个永远不进的支里（判据因此失效，不是功能失效）。
    // 判据换成「宿主此刻说这个 App 被托着」，与 `-bounds` 的口径无关。
    if (AevonBandHostedNow()) {
        // 0.4.56 — 新的一张卡 = 新的一轮。0.4.55 之前 `AevonAuditLines` 是
        // **全进程总闸**（26 行），338 里第一次开卡（冷启动，正好是最需要读数
        // 的那一次）就把配额烧光了：14:20:04 第二次开卡、14:20:31 关卡那两段
        // `layout audit` **一行都没有**。现在按「宿主刚说它被托着」这个上升沿
        // 归零，每张卡各有自己的四拍。
        if (!AevonAuditHostedWas) {
            AevonAuditHostedWas = 1;
            AevonAuditPass = 0;
            AevonAuditLines = 0;
            AevonAuditNudges = 0;
            AevonAuditLimit = 4;
            AevonCellFitNotes = 0;
            AevonCellFixes = 0;
            AevonCellFitSame = 0;
            AevonCellFitDead = 0;
            AevonCellFitStale = -1;
            AevonCellFitBeats = 0;
            AevonCellFitSeen = 0.0;
            AevonCellFitAt = 0.0;
            AevonCellCvFixes = 0;
            AevonCellCvAt = 0.0;
            // 0.4.60 — 新卡第一拍就去认翻页器。340 的 14:58:01 那张卡是从
            // 「别的 App 全屏」切回来的，`AevonAcquireTries` 带着上一张卡的
            // 计数，要等好几拍才轮到下一次真正的遍历。
            AevonAcquireTries = 0;
            AevonPagerMissNotes = 0;
            // 0.4.61 — 「这张表太贵」这个结论不能带到下一张卡。341 里 15:12:23
            // 那一次 55 ms 把工具永久打掉，紧接着的全屏就一次机会都没有了 ——
            // 用户看到的是「浮窗正常、全屏断层」。现在它是「本张卡」而不是
            // 「本次启动」，每次进卡都重新给一次机会。
            AevonTableRemeasureDead = 0;
            AevonTableRemeasureNotes = 0;
        }
        // 0.0.84 — 横版画面贴顶：每 0.6 s 看一眼「那块矩形在不在容器正中」。
        // 0.4.51 — 退休了（`AevonVideoCenterRetired`）。调用保留一行是为了留个
        // 明确的落点：以后要重开，把那个常量改成 0 就够，不必再把整条链接回来。
        if ((AevonWatchTicks % 4) == 0) AevonVideoCenter();
        // 0.4.51 / 0.4.52 — 卡片里的排版对账，开卡前 1.5 s 四拍。
        AevonHostedAudit();
    } else {
        // 出了卡：下一张卡是新一轮，对账从第一拍重新开始。
        if (AevonAuditHostedWas) {
            AevonAuditHostedWas = 0;
            // 0.4.59 — 关卡也是新一轮。卡片里用掉的次数、以及「同一高度改不动」
            // 那个结论**不能带到全屏**：全屏正是断层出现的另一个时刻，那时这条
            // 通道必须还是活的，否则用户看到的就是「卡片里好了、全屏又坏了」。
            AevonCellFitNotes = 0;
            AevonCellFixes = 0;
            AevonCellFitSame = 0;
            AevonCellFitDead = 0;
            AevonCellFitStale = -1;
            AevonCellFitSeen = 0.0;
            AevonCellFitAt = 0.0;
            AevonCellCvFixes = 0;
            AevonCellCvAt = 0.0;
        }
        AevonAuditPass = 0;
        AevonAuditLimit = 4;
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
        // 翻页器是 App 自己造的，开卡后 1 s 才出现。每 4 拍（0.6 s）找一次，
        // 一直找到 4000 拍（10 分钟，与一张卡的上限同寿）。
        //
        // 0.4.61 — **不降频**。0.4.60 把 40 次之后降到每 40 拍（6 s）一次，341 立刻
        // 报了账：15:12:11 关卡回全屏，`pager keep box=932 …` 直到 **15:12:16**
        // 才出现 —— 中间那五秒 `view == nil`，`cell fit` 一行读数都没有，而用户看到
        // 的断层正是这五秒。一次遍历上限 4000 个视图、实测 0.3 ms，0.6 s 一次是
        // 0.05% 的 CPU，省它没有意义；而「认不出翻页器 = 通道不存在」是致命的。
        if (AevonAcquireTries < 4000) {
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
    // 0.4.56 — 每一拍、两个方向都量一次页高（见 `AevonCellFitTick`）。
    // 放在「手指在动」那条 return 之前：正在滑的那几拍也要记账 —— 用户要的
    // 正是「每一次滑动都检测」。真正的动作仍然等手指离开之后才发。
    AevonCellFitTick(view);
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
/// 0.3.39 — 心跳文件 `tmp/aevon-alive`，内容是 `pid 时间戳`，最多 1.8 s 一次。
///
/// 这是宿主判断「这个 App 现在有没有进程」的唯一可靠依据。原来它读
/// `SBApplicationController` 的 `pid` / `isRunning`，而 Aevon(4)(2) 里 QQ
/// 明明在跑（ack 自带 `pid=53883`），宿主那一侧却每一跳都是
/// `act: float cold=1 pid=-2 run=-1 seen=0 live=0` ⇒ 0.3.38 的进程内桥把
/// **热启动也全接了**，0.3.37 验过的 scene action 一次都没走。
///
/// 为什么不复用 `aevon-app.log` 的修改时间：宿主每次读完就截断，截断本身
/// 也会刷新时间戳，于是「刚死掉的 App」看起来和「活着」一样新。单独一个文件，
/// 只有本进程会写，语义干净。
///
/// 1.8 s 节流：这条链是 1 s 一拍，写一次 40 字节；不给它加节流就是每秒一次
/// 磁盘写，对本进程和闪存都不划算。
static void AevonAliveBeat(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last > 0 && now - last < 1.8) return;
    last = now;
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0) return;
    NSString *file = [tmp stringByAppendingPathComponent:@"aevon-alive"];
    char box[64];
    snprintf(box, sizeof(box), "%d %.0f\n", (int)getpid(), now);
    NSData *data = [NSData dataWithBytes:box length:strlen(box)];
    [data writeToFile:file atomically:NO];
}

static void AevonAliveTick(void *context) {
    (void)context;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonAliveTick);
    AevonAliveBeat();
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

// ============================================================================
// 0.4.0 — 这里原来是「分享 payload 直投」那 550 行：宿主写 `tmp/aevon-open.plist`
// + Darwin 通知，App 侧把 URL 交给自己（`AevonOpenURLOptions` 假对象、
// `scene:openURLContexts:` / `application:openURL:options:` 三条老入口、通用链接
// `continueUserActivity`、以及回执 `aevon-open-ack`）。
//
// 整条随 URL 主线删除。现在没有任何打开请求会进这个进程 —— 浮窗这条路不接管
// URL、不投 URL、不认通知，App 侧只剩「把画布缩小、把画面搬进卡里」。
// ============================================================================
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
//
// ⛔ 0.4.7 — **这一节只剩「在屏 / 离屏」这一个事实，一个几何都不写。**
//
// 0.1.43 ~ 0.4.6 在别处还挂过一整套几何处理（intersection 换算、键盘窗平移、
// 顶边发布、通知矩形改写、安全区让位、参考线兜底、App 窗口收放）。它们全都建立在
// 「App 认为屏高 932」这个前提上做补偿，而 Aevon(291) 把这个前提证伪了：
//
//   win: keyboard native on card=430x717 at 0,215 … push=0
//   app: kb: win hold h=358 top=358 sceneY=0 sceneH=717
//   app: kb: lift aligned dy=0 bottom=717 base=744 scene=717 kb=430x717
//
// 键盘窗高 717、底边贴在**场景**底 717，而真实屏高 932 ⇒ 下面空 215 pt（白条），
// 键盘整块悬在 401..717 盖住输入条。调参调不掉：错的不是那几个数，是「App 以为
// 自己在 932 的屏上、而我们手工把键盘摆进 717 的格子」这个做法本身。
//
// 母版（`SthenoKeyboard.dylib`，见 `stheno-逆向分析/final3/analysis/hooks-SthenoKeyboard.md`）
// 的做法相反：**让 App 自己认为屏就是承载面那么高**（`UIScreen -bounds` 返回
// `[_appScene _boundsForInterfaceOrientation:]`），UIKit 于是按 717 排版，键盘、
// 输入框、safeArea 全部自洽。实现见 `Sources/App/AevonKeyboardNative.m`。

static volatile int AevonKbOn = 0;
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

static void AevonKbEvaluate(NSDictionary *info) {
    // 0.4.10 — 兜底安装点。正常情况下钩子早在开卡那一拍就装好了（band 通知驱动），
    // 走到这里还在「没装 + 被托着」只有一个原因：开卡时那几通通知没收到（宿主写
    // band 早于本进程起来，或者通知恰好丢了一拍）。键盘起来了就得接住，否则这一
    // 次弹键盘一定还是旧形状。`AevonKbEnsureInstalled` 装过 / 排过 / 没被托着时
    // 都是一次内存判断，可以每个键盘事件都问。
    AevonKbEnsureInstalled();
    NSValue *value = info[UIKeyboardFrameEndUserInfoKey];
    if (value == nil) return;
    CGRect frame = [value CGRectValue];
    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
    BOOL on = frame.size.height > 40.0 && frame.origin.y < screenHeight - 1.0;
    if (!on) return;
    if (AevonKbOn != 0) {
        // 状态没变也要续一次：键盘一直开着的时候，租约靠这一点续命。
        AevonKbPost();
        return;
    }
    AevonKbOn = 1;
    AevonKbArm(YES);
    AevonKbPost();
    // 上屏这一拍留一行证词。桌面那侧靠 `com.aevon.kb.up` 的租约判定，这一行是
    // App 侧的对照：没有它，日志里「桌面看到了 up」与「App 发过 up」就分不开。
    AevonRawNote("app: keyboard up (bridge)\n");
}

/// 0.1.66 — 收起的唯一来源。
static void AevonKbHideNote(NSDictionary *info) {
    (void)info;
    AevonKbOn = 0;
    AevonKbArm(NO);
    AevonKbPostOff();
}

static void AevonKbObserve(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIKeyboardWillChangeFrameNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
        AevonKbEvaluate(note.userInfo);
    }];
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

/// 0.4.7 — 跨文件只读这一个事实：本 App 现在被卡片托着吗。
///
/// `AevonKeyboardNative.m` 用它表达母版的 `[_frontMost isEqualToString:_bundleId]`：
/// 被卡片托着 ⇒ 这个 App 不是屏幕上最前的那一个。两者是同一个判断的两个取数口。
int AevonBandHostedNow(void) {
    return AevonBandOn;
}

/// 0.4.7 — **所有**对 `AevonBandOn` 的写入都走这里。
///
/// 它是键盘接管的「本 App 是不是前台最前」的事实源（见 `AevonKeyboardNative.m`
/// 的 `AevonKbRefreshShell`）。漏一个写入点，`UIScreen.bounds` 就晚一拍才换回
/// 真屏尺寸 —— 那一拍正好落在键盘动画的第一帧上，看起来就是「白条晚一步消失」。
static void AevonBandSetOn(int on) {
    int was = AevonBandOn;
    AevonBandOn = on ? 1 : 0;
    AevonKbRefreshShell();
    // 0.4.54 — 冷启动那一段以前**一行读数都没有**。
    //
    // `page transition` 只在窗口真的换尺寸时才触发，而冷启动时窗口从头到尾没变
    // （变的是我们答的数字），于是 `AevonEverHosted` 永远不置位 ⇒ 审计四拍、
    // `page state`、`page inside` 全部静默。337 的第一次开卡就是这个形状：
    // 整段 App 日志只有 15 行 boot/kb，一个 page 字都没有 —— 用户说的「冷启动
    // 2~3 s 才排对」在日志里等于不存在。
    // 现在「宿主说这个 App 被托着」这一刻就是那四拍的起点（0 / 0.30 / 0.80 /
    // 1.50 s），正好盖住那 2~3 s。
    if (on && !was) {
        AevonEverHosted = 1;
        AevonAuditPass = 0;
        AevonPagerWatchArm();
    }
}
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
    if (AevonBandApp == NULL) { AevonBandSetOn(0); return; }
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
            AevonBandSetOn(0);
            AevonBandLock = 0;
            return;
        }
        snprintf(text, sizeof(text), "%s", body.UTF8String);
    }
    if (text[0] == 0 || strcmp(text, "none") == 0) {
        // 0.4.7 — 卡片走了 ⇒ 这个 App 不再是「被托管的一块」。
        //
        // 0.2.60 ~ 0.4.6 在这里调 `AevonKbUnfitWindow()`（把 App 窗口高度收回
        // 932）。那个函数连同整套几何补偿一起删了：Aevon(201) 的「全屏中下黑」
        // 与 0.4.4 的全屏黑边是同一件事 —— App 的窗口被我们摆进承载面的格子里、
        // 而它自己认为屏就是承载面那么高，系统把 scene 扩到 932 之后下半截没有
        // 东西在画。
        //
        // 现在这件事由母版机制接管：`AevonBandSetOn(0)` 会调
        // `AevonKbRefreshShell()`，`UIScreen -bounds` 立即改回真屏尺寸，UIKit
        // 自己把窗口重排 —— 不需要我们伸手。
        AevonBandSetOn(0);
        AevonBandLock = 0;
        return;
    }
    // 9 个数直接扫，不建数组：`sendEvent:` 每次手势都要走这条判定，回调里也
    // 不该留下 autoreleased 容器（构造函数那一拍没有 pool）。
    double v[9] = {0};
    int got = sscanf(text, "%lf %lf %lf %lf %lf %lf %lf %lf %lf",
                     &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8]);
    if (got < 8) { AevonBandSetOn(0); AevonBandLock = 0; return; }
    AevonBandOuter = CGRectMake((CGFloat)v[0], (CGFloat)v[1], (CGFloat)v[2], (CGFloat)v[3]);
    AevonBandHole = CGRectMake((CGFloat)v[4], (CGFloat)v[5], (CGFloat)v[6], (CGFloat)v[7]);
    AevonBandSetOn(AevonBandOuter.size.width >= 1 && AevonBandOuter.size.height >= 1);
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

/// 0.4.66 — 横屏通道的入口在这个文件的后半段（`AevonRotApplyWant`）。宿主把
/// 「转横 / 转竖」写在同一份偏好域里、用同一通 Darwin 通知叫醒我们，所以这里
/// 只提前声明一下，回调里照着叫一声。
static void AevonRotApplyWant(void);
/// 0.4.66 — 同一通 band 里还要答一次「我现在是横的还是竖的」（见 `AevonRotForce`）。
static void AevonRotForce(void);

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
    // 0.4.66 — 同一通通知里宿主可能还夹了一个「转横 / 转竖」（`AevonRotWant`）。
    // 读数与判重都在 `AevonRotApplyWant` 里，这里只负责「来了一通就问一次」。
    AevonRotApplyWant();
    // 0.4.66 — 开卡那一拍宿主会发一次 band：顺手把当前横竖答回去（暖启动的 App
    // 不会再报「变化」，见 `AevonRotForce`）。
    AevonRotForce();
    // 0.4.7 — 这里原本补一拍 `AevonKbLiftApply`（把键盘窗按场景底平移）。
    // 键盘不再由我们摆位：母版让 App 认为屏就是承载面那么高，键盘窗的几何由
    // UIKit 在建窗那一拍自己摆（`AevonKeyboardNative.m` 的 `remoteKeyboardWindowForScreen:`）。
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

// ===========================================================================
// 0.4.66 — 横屏：**App 自己转，宿主跟随。**
// ===========================================================================
//
// 343 的日志把 0.4.65 的假设推翻了。那一版在宿主的 `settings` 里写
// `frame=717x403` 和 `interfaceOrientation=3`，**一个字都没落地**：
//
//     16:57:58  win: orientation -> 3 slot=0 geo=717x403
//     16:58:13  win: frame drift now=430x717@0 want=717x403@0
//     16:57:59  app: page state after change box=430x717   ← 哔哩哔哩从没转
//
// 真正转过去的只有抖音自己点「横屏」那一次（`page sheet
// AWELandscapeNavigationController` 之后 `box=717x430`），因为那是 App 自己调的
// `-[UIWindowScene requestGeometryUpdateWithPreferences:]`。
//
// 所以这条路拆成两半，各做各的：
//   · App 侧（这里）：把「我现在的世界是横的」报给宿主；宿主请求时**替用户
//     按一下那个按钮** —— 同一个 `requestGeometryUpdateWithPreferences:`。
//   · 宿主侧：读到「App 的世界横了」就把卡片切成 16:9 并跟随
//     （`AevonScene.m` 的 `AevonRotSweep` → `FloatHost.setLandscape`）。
//
// ⛔ 不要回到「宿主替 App 转」：那条路要走私有 `_rotateWindowToOrientation:`
// （PullOver-X 自己都先 `respondsToSelector`），而 Aevon 的 scene 被我们改成了
// 小胖屏，宿主写进去的 frame 会被系统的下一次协商覆盖回去，读数上看着写了、
// 行为上什么都没有 —— 这正是 0.4.65 的形状。

static CFStringRef AevonRotDomain(void) {
    static CFStringRef domain = NULL;
    if (domain != NULL) return domain;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (bundle.length == 0) return NULL;
    domain = CFStringCreateCopy(kCFAllocatorDefault, (CFStringRef)bundle);
    return domain;
}

static dispatch_queue_t AevonRotQueue = NULL;
static dispatch_queue_t AevonRotQueueGet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AevonRotQueue = dispatch_queue_create("com.aevon.rot.publish", DISPATCH_QUEUE_SERIAL);
    });
    return AevonRotQueue;
}

/// 上一次报出去的状态：-1 还没报过，0 竖，1 横。只给同一进程内判重。
static int AevonRotSent = -1;
static int AevonRotSentW = 0;
static int AevonRotSentH = 0;
/// 0.4.67 — 上一次报出去的**视频区**。判重也要带上它：同一个横竖、同一块世界，
/// 但播放器换了位置（点下一集、切全屏 ↔ 半屏）时，卡片必须重新对准。
static int AevonRotSentVX = -1;
static int AevonRotSentVY = -1;
static int AevonRotSentVW = -1;
static int AevonRotSentVH = -1;
/// 宿主最近一次要求（`AevonRotWant`）：「已经发过的那一个值」，防重复请求。
static int AevonRotWantSeen = -1;
/// 0.4.70 — 「世界横着、内容已翻回竖排」的锁存。
///
/// 世界被宿主钉住之后（hosted 横屏把 scene frame 推成 717x430，守护循环盯死了
/// 这个值），`world.width > world.height + 40` 在抖音自己退全屏的那一拍**一个字
/// 都不会变** —— 347 里 App 19:36:11 就把信息流翻回了竖排
/// （`page pager keep box=430 span=430x12189`），卡片却在 430x199 上一直挂到
/// 19:36:28 用户手动上滑关卡，17 秒。退全屏只能从内容看出：翻页器
/// （AWEFeedTableView）从横排 717x430 翻回竖排 430 宽。连两拍才落锁（0.6 s）：
/// 进全屏那一拍横版页从第一拍就是横排（347：19:35:50 `page=717 box=717`），
/// 不会误伤入场。
static int AevonRotFeedExit = 0;
// 0.4.72 — 撤掉 0.4.71 的「+1.0s/+2.0s 补发 rot ask」：349 两次都被系统拒
// （BSActionErrorDomain错误1，抖音全屏态的 supportedInterfaceOrientations 不含
// 竖屏），纯噪音。真正能转世界的是宿主看门狗的 settings 写（349：关卡那条
// `screen back door=3` 一写世界当场回竖），phase1 已把看门狗目标翻竖。
static int AevonRotFeedStreak = 0;
/// 0.4.86 — 「抖音横版页在位、世界被它自己请求回竖」这条闸的日志配额（8 行）。
///
/// 363 是这条闸的来历：用户在**竖屏**卡片里点了全屏，抖音自己进了
/// `AWELandscapeNavigationController`，视频 `717x430@0,0` 铺满（`rot follow 1`），
/// 三秒后 App 的 scene 被请求成 430x717 ⇒ `AevonRotProbe` 报 0 ⇒ 我们发布 0 ⇒
/// 宿主 `landscape unpin` + `exit phase2` 把卡片收回竖屏。
/// 也就是说**「世界回竖」在横版播放器在位时不是退出信号**，只是抖音的横屏页
/// 发现 `UIScreen` 还是竖的、顺手请求了一次竖屏几何（硬禁令：不许改 UIScreen）。
/// 判据：链上**现在**有 Landscape 页 ⇒ 保持上一拍的上报（什么都不发），
/// 宿主会继续把 scene 钉在横版画布上。
static int AevonLandHoldNotes = 0;
/// 0.4.87 — 「世界第一次变横」的时刻。只给「刚进横屏那一小段」的退出闸用。
///
/// 364 的那两秒里世界是横的、链上还没有 Landscape 页，两条判据都不成立 ⇒
/// 我们自己把刚点开的全屏报了 0。但「世界横」不能当永久判据：宿主把 scene 钉
/// 在 717x430 之后，App 的世界**永远不会自己回竖** —— 拿它做唯一条件就是
/// 自锁（用户点返回退出横屏，卡片也不再回来）。所以只认「刚变横的 6 秒」：
/// 那正好是抖音回头请求一次竖屏几何的窗口（363/364 都是 2 秒内），窗口之外
/// 仍按老规矩（链上有没有 Landscape 页 + `rot feed exit` 三拍）判退出。
static double AevonRotOnSince = 0;
/// 0.4.88 — 上一次**报出去** on=1 的时刻。
///
/// 365 的 18:33:13 是这一项的来历：`rot follow 1` 之后两秒，`AevonRotWorld()` 读
/// 回 430x717（抖音把 scene frame 请求回竖，宿主 2 pt 后又纠回来），探针在
/// 「世界不横」那一行提前返回 ⇒ on=0 ⇒ 发布 0 ⇒ 宿主 `landscape unpin`。
/// 那一刻**画面上仍是一块 717x430 的横版播放器**（同一份日志 `page state` 里
/// `k1=AWELandscapeMediumVideoPlaye:0,717x430`）。所以 hold 闸不能再问世界，
/// 要问「界面上现在有没有一块横着的横版视图」，而这条时间戳只用来把那次遍历
/// 限制在「刚报过横屏」的 25 秒里（稳态下不花这份钱）。
static double AevonRotLandAt = 0;
/// 0.4.88 — 宿主「要竖」的下降沿时刻（want 1 → 0）。
///
/// hold 闸必须给这条让路：用户点我们的退出钮 / 长按关横屏时，宿主发 want=0，
/// 此时画面上的横版页**还没拆**，闸若照旧扣住，用户就永远退不出去。
static double AevonRotWantOffAt = 0;
/// 0.4.88 — 连续扣住的拍数（0.3 s/拍）。满 60 拍（18 s）强制放行：
/// 「界面上那块横版视图」有可能残留（抖音把播放页从层级里摘掉之前会留一帧），
/// 闸不能靠它锁死一整轮。18 s 远大于任何一次真实转场的 3.8 s。
static int AevonLandHoldTicks = 0;
/// 0.4.83 — 「横版播放器在位、所以不收卡」这条判据的日志配额：只证明这条闸真
/// 生效过，稳态下一行都不写。刷新源 = want 上升沿清零。
static int AevonRotFeedHoldNotes = 0;
/// 0.4.81 — 「这一轮里见过抖音自己的横版页」的锁存。
///
/// 它的**唯一**用途在 0.4.83 里已经具体化成一句话：见过 + 现在链上没有 ⇒ 抖音
/// 自己拆了横版播放器（347 那个状态）。单靠它当门是错的 —— 360 证明它一旦置位，
/// 横屏播放器**在位时** pager 也永远是竖的（`pager=430x717`），拿它当门等于
/// 「一进横屏就判退出」。真正的判据是**现在**链上有没有横版页（`AevonChainHasLandscape`）。
/// 刷新源明确：want 的 0→1 上升沿清零 / 世界回竖清零（见 `AevonRotTick`）。
static int AevonSawLandPage = 0;
/// 心跳计数，只用来把偏好域读值降频（读不受 0.1.35 那条纪律管，但也不必每拍一问）。
static int AevonRotTicks = 0;
/// 0.4.67 — `app: rot probe` 的行数上限。判据变了要能对账，但不能每拍一行。
static int AevonRotProbeNotes = 0;

static void AevonRotPostNow(const char *text) {
    @autoreleasepool {
        if (text == NULL) return;
        CFStringRef domain = AevonRotDomain();
        if (domain == NULL) return;
        NSString *value = [NSString stringWithUTF8String:text];
        if (value == nil) return;
        CFPreferencesSetAppValue(CFSTR("AevonRotState"), (CFStringRef)value, domain);
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        // 0.4.67 — **容器文件是这条路的主路**，偏好域只是顺带写的一份。
        //
        // 344 证明「App 写自己域、宿主读同名域」在 roothide 下对不上：band 那条
        // 方向能通，靠的正是宿主另写了一份 `tmp/aevon-band`（见 `AevonScene.m` 的
        // `AevonBandPublishNow`），而这里的 CFPreferences 一份都没被宿主读到 ——
        // 整份日志 `win: rot follow` 零行。反过来同理：宿主写进我们域的
        // `AevonRotWant` 我们也读不到，所以 `app: rot ask` 同样零行。
        // 现在两个方向都按 band 那一套来：**文件存数据，通知只当铃铛。**
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aevon-rot-state"];
        [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.aevon.rot"), NULL, NULL, true);
    }
}

// ===========================================================================
// 0.4.67 — 判据从「世界尺寸」换成「屏幕上那一块横版视频」。
// ===========================================================================
//
// 344 的读数把 0.4.66 的前提也推翻了。那一版假设「用户点全屏 ⇒ App 自己转
// ⇒ keyWindow.bounds 变成 717x430」，可那份日志从头到尾 `box=430x717`：
//
//   17:42:51  app: page sheet AWELandscapeNavigationController h=430 top=0 box=430
//   17:42:51  app: page transition h=430 last=932 full=717
//   17:42:52  app: page on resize late player none
//
// 抖音的「全屏」不是旋转世界：它**在竖屏世界里开一个横屏播放页**，视频横排
// 铺在中间，`keyWindow.bounds` 一个字都不变。于是 `width > height + 40` 这条
// 判据在这条路上永远为 0 —— 用户看到的就是「视频横了、悬浮窗还是小胖屏」。
//
// 现在的判据三选一（前一条成立就停）：
//   · 世界真的横了（真旋转的 App，B 站这类）—— 与 0.4.66 相同；
//   · 树里量到一块「横版视频」—— 宽 ≥ 0.70 世界宽、宽 > 高×1.2、面积 ≥ 0.12
//     世界宽²、类名含 Player/Video 或 layer 是 AVPlayerLayer。三条门槛缺一不可：
//     344 里 B 站竖版有一个 `BBStoryVideoPrev 144x81@143,454`（宽>高！），
//     只按形状判会把它当横版，卡片永远切不过去；
//   · 浮层链上出现类名含 `Landscape` 的控制器（`AWELandscapeNavigationController`
//     就是这个）—— 这时量不到视频区，退化成「世界正中一块 16:9」。
//
// 视频区（在 keyWindow 坐标里）**一路带到宿主**：卡片要的是「一块播放视频的
// 窗」，不是「把 App 的横屏界面端上来」。有了这块矩形，卡片只平移不缩放，
// 正好框住画面。

/// 树里找那一块横版视频。找到返回 YES 并写 `out`（keyWindow 坐标）。
static BOOL AevonRotFindVideo(UIWindow *win, CGRect *out) {
    if (win == nil || out == NULL) return NO;
    CGSize world = [win bounds].size;
    CGFloat minW = world.width * 0.70;
    CGFloat minArea = world.width * world.width * 0.12;
    Class avl = NSClassFromString(@"AVPlayerLayer");
    NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
    CGFloat bestArea = 0;
    CGRect best = CGRectNull;
    NSUInteger walked = 0;
    while ([stack count] > 0 && walked < 1400) {
        UIView *node = [stack lastObject];
        [stack removeLastObject];
        walked += 1;
        if ([node isHidden] || [node alpha] < 0.05) continue;
        NSArray *kids = [node subviews];
        NSUInteger n = [kids count];
        for (NSUInteger i = 0; i < n && i < 40; i++) [stack addObject:[kids objectAtIndex:i]];
        CGRect b = [node bounds];
        if (b.size.width < minW || b.size.height < 40.0) continue;
        if (b.size.width <= b.size.height * 1.2) continue;
        BOOL named = NO;
        const char *cn = class_getName([node class]);
        if (cn != NULL && (strstr(cn, "Player") != NULL || strstr(cn, "Video") != NULL)) {
            named = YES;
        }
        if (!named && avl != Nil && [[node layer] isKindOfClass:avl]) named = YES;
        if (!named) continue;
        CGRect r = [node convertRect:b toView:win];
        CGFloat area = r.size.width * r.size.height;
        if (area < minArea) continue;
        if (area > bestArea) { bestArea = area; best = r; }
    }
    if (CGRectIsNull(best)) return NO;
    *out = best;
    return YES;
}

// 0.4.68 — `AevonRotFindLandscape` 已删。
//
// 它找的是「presented 链里类名带 Landscape 的控制器」，即 344 那条
// `page sheet AWELandscapeNavigationController`。但 345 显示**它和方向无关**：
// 抖音在竖屏世界里照样有这个控制器（点全屏前就摸得到），而真正转置的那一拍
// `world` 从 430x717 变成 717x430，本来就是可读的。留一条会误判、又不提供新
// 信息的判据，只会在下一次「错的离谱」里继续当主犯。

/// 一次判定。`why` 只用于日志（`world` / `none`）。
/// 只回答一件事：**App 自己把世界转过去了没有。**
///
/// 0.4.68 — 判据收回到「世界转置」这一条，`video` / `page` 两条全删。
///
/// 345 是这两条判据的死刑判决书：抖音竖屏信息流里有一个 `430x200` 的横版元素
/// （16:9 视频卡、直播推荐位一类），`AevonRotFindVideo` 的形状门槛
/// （宽 ≥ 0.70 世界宽、宽 > 高×1.2、面积达标）它一条不落地全过 —— 于是**开卡
/// 第一秒**卡片就被切成 430x242，而画布还是 430x717（`card landscape 1
/// canvas=430x717 card=430x242`），用户看到的是竖屏信息流被裁成中间一条横条。
/// 那一秒之后到 18:04:41 之间，同一块 `vid=430x200` 的 y 从 649 滚到 -282，
/// 每一拍都触发一次「重对准」—— 卡片跟着信息流滚动一路抖。
///
/// 真正该看的那一拍反而被吞了：18:04:41 抖音点全屏，`world=717x430`（真转置，
/// 它自己开了 `AWELandscapeNavigationController`、`box=717x430`），但我们因为
/// 卡片**早就是** landscape，`AevonCardLandscapeEnter` 的 `guard !isLandscapeCard`
/// 把这一拍挡在门外，只留下 `aim` 没有 `card landscape 1`。
///
/// 结论：**形状证明不了旋转。** 世界宽高比是唯一不会被竖屏内容骗到的量 ——
/// 一个 430x717 的世界里出现一块 430x200 的黑矩形，那是内容，不是方向。
/// `video` 仍然照旧量出来、照旧上报，但它只用来在日志里指出「视频在哪」，
/// 不参与判定。判定只剩一行：`world.width > world.height + 40`。
static BOOL AevonRotProbe(CGRect *video, char *why, size_t wyn) {
    if (why != NULL && wyn > 0) snprintf(why, wyn, "none");
    if (video != NULL) *video = CGRectNull;
    UIWindow *win = AevonKeyWindow();
    if (win == nil) {
        if (why != NULL && wyn > 0) snprintf(why, wyn, "nowin");
        return NO;
    }
    CGSize world = [win bounds].size;
    // 40 pt 的余量：分屏、键盘、浮层都可能让「宽高很接近」，只认真的横。
    if (world.width <= world.height + 40.0) return NO;
    if (video != NULL) {
        CGRect vr = CGRectNull;
        if (AevonRotFindVideo(win, &vr)) *video = vr;
    }
    if (why != NULL && wyn > 0) snprintf(why, wyn, "world");
    return YES;
}

/// 0.4.70 — 世界横着的时候，翻页器是不是已经翻回竖排。
///
/// 抖音退全屏不转世界：它把横版播放页拆掉、信息流按 430 宽重排（347：
/// 19:36:11 `page state after change box=430x430 span=430x12189`，而窗口还是
/// 717x430）。翻页器宽 < 世界宽 − 40 就是这个状态。找不到翻页器返回 NO ——
/// 退化成旧行为（用户手动关卡），绝不拿「量不到」当「已退出」。
static BOOL AevonRotFeedPortrait(UIWindow *win) {
    UIScrollView *pager = AevonPagerGet();
    if (pager == nil || [pager window] == nil) return NO;
    if (win != nil && [pager window] != win) return NO;
    CGFloat pw = [pager bounds].size.width;
    CGFloat ww = [win bounds].size.width;
    if (pw < 16.0 || ww < 16.0) return NO;
    return pw < ww - 40.0;
}

/// 报一次「我横不横、世界多大、横的那块视频在哪」。没变就什么都不做。
///
/// 值写成 `"1 430 717 0 237 430 242"`：横竖、世界宽高、视频区 x/y/w/h。
/// 后五个只是给宿主算「窗口对准哪里」用的 —— 卡片尺寸仍由宿主自己的画布算，
/// 不靠这里的数（两边各记一份尺寸是 0.2.39 那一类事故的形状）。
/// 0.4.69 — 世界方向翻转之后，App 的 UIKit 要花 2~3 s 才把翻页器排进新方向
/// （346：19:12:22 世界回 `430x717`，`box=717` 到 19:12:25 才跟上，列表里混着
/// `717x430` 的旧横版 cell）。`AevonLayoutSettle` 那条路被 `AevonPageRideRetired`
/// 退休了，`AevonRemeasurePending` 置了也会被它清零 —— 所以这里直接排两拍
/// `AevonTableRemeasure`（0.9 s / 2.2 s，等系统先把 scene 重排完），它自带
/// 250 ms 死亡闸与行数门槛，安全。
static void AevonRotRefitSchedule(int w, int h) {
    static int runs = 0;
    if (runs >= 12) return;              // 全进程上限 ≈ 6 次翻转，之后靠系统自己排
    runs += 1;
    int n = runs;
    for (int k = 0; k < 2; k++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((k == 0 ? 0.9 : 2.2) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIScrollView *pager = AevonPagerGet();
            if (pager == nil || [pager window] == nil) return;
            if (![pager isKindOfClass:[UITableView class]]) return;
            if ([pager isTracking] || [pager isDragging] || [pager isDecelerating]) return;
            BOOL did = AevonTableRemeasure((UITableView *)pager);
            if (n <= 12) {
                char line[128];
                snprintf(line, sizeof(line), "app: rot refit n=%d world=%dx%d r=%d",
                         n, w, h, did ? 1 : 0);
                AevonPageWrite(line);
            }
        });
    }
}

static void AevonRotPublish(BOOL on, CGSize world, CGRect video) {
    int w = (int)(world.width + 0.5);
    int h = (int)(world.height + 0.5);
    int vx = 0, vy = 0, vw = 0, vh = 0;
    if (!CGRectIsNull(video) && video.size.width > 8.0 && video.size.height > 8.0) {
        vx = (int)(video.origin.x + 0.5);
        vy = (int)(video.origin.y + 0.5);
        vw = (int)(video.size.width + 0.5);
        vh = (int)(video.size.height + 0.5);
    }
    int flag = on ? 1 : 0;
    int prevFlag = AevonRotSent;         // 赋值前读：翻转检测要用它
    if (AevonRotSent == flag && AevonRotSentW == w && AevonRotSentH == h
        && AevonRotSentVX == vx && AevonRotSentVY == vy
        && AevonRotSentVW == vw && AevonRotSentVH == vh) {
        return;
    }
    AevonRotSent = flag;
    if (flag == 1) AevonRotLandAt = CFAbsoluteTimeGetCurrent();
    AevonRotSentW = w;
    AevonRotSentH = h;
    AevonRotSentVX = vx;
    AevonRotSentVY = vy;
    AevonRotSentVW = vw;
    AevonRotSentVH = vh;
    // 方向真的翻了一面（`-1` 是开卡握手不算）：排两拍重排，把旧方向的 cell
    // 请出去。346 里退出全屏后用户看到的「没恢复小胖屏」就是这几秒混装。
    if (prevFlag != flag && prevFlag >= 0) {
        AevonRotRefitSchedule(w, h);
    }
    char text[64];
    snprintf(text, sizeof(text), "%d %d %d %d %d %d %d", flag, w, h, vx, vy, vw, vh);
    char *copy = strdup(text);
    if (copy == NULL) return;
    dispatch_async(AevonRotQueueGet(), ^{
        AevonRotPostNow(copy);
        free(copy);
    });
}

/// 能承载旋转的那个 `UIWindowScene`。优先按键窗认，认不到退回第一个。
static UIWindowScene *AevonRotScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return nil;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (fallback == nil) fallback = ws;
        for (UIWindow *window in ws.windows) {
            if (window.isKeyWindow) return ws;
        }
    }
    return fallback;
}

static CGSize AevonRotWorld(void) {
    UIWindowScene *ws = AevonRotScene();
    if (ws == nil) return CGSizeZero;
    for (UIWindow *window in ws.windows) {
        if (window.isKeyWindow) return window.bounds.size;
    }
    if ([ws respondsToSelector:@selector(coordinateSpace)]) {
        id space = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(coordinateSpace));
        if (space != nil) {
            CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(space, @selector(bounds));
            return rect.size;
        }
    }
    return CGSizeZero;
}

/// 替用户按一下那个「横屏」按钮。
///
/// 这是 iOS 15+ 唯一公开的旋转入口。参数是 `UIWindowSceneGeometryPreferencesIOS`
/// （类名只在运行期存在，所以走 `objc_getClass` + 判选择子），蒙版给
/// 「左右都行」而不是只给右：App 的界面朝哪边由系统和设备决定，我们只表达
/// 「要横」。失败一律只有一行日志，不改任何几何 —— 猜一个形状出来就是 0.4.65
/// 那种「看着转了、其实没转」的样子。
static void AevonSioNudgeAll(void);
/// 0.4.78 — `requestGeometryUpdate` 在本工程里的失败次数。355 里两种蒙版
/// （横 24 / 竖 2）、十几发、每一发都是 `BSActionErrorDomain错误1` —— 请求
/// 根本没走到 VC 协商那一层，再发只是刷日志。满两次自动退场，留一行
/// `rot ask retired` 作证；守门 VC 那条路不依赖它。
static int AevonRotAskFails = 0;
static void AevonRotAsk(BOOL on) {
    // ⛔ 同 `AevonRotForce`：这条路上全是 UIKit（`connectedScenes` / `windows` /
    // `requestGeometryUpdate`），只在主线程成立。放到函数最前面，所有调用点
    // 都不用各记一遍这条纪律。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotAsk(on);
        });
        return;
    }
    if (AevonRotAskFails >= 2) {
        static int noted = 0;
        if (!noted) {
            noted = 1;
            AevonAppLogWrite("app: rot ask retired n=2\n");
        }
        return;
    }
    UIWindowScene *ws = AevonRotScene();
    if (ws == nil) {
        AevonAppLogWrite("app: rot ask scene none\n");
        return;
    }
    Class prefsCls = objc_getClass("UIWindowSceneGeometryPreferencesIOS");
    SEL reqSel = sel_registerName("requestGeometryUpdateWithPreferences:errorHandler:");
    if (prefsCls == Nil || ![ws respondsToSelector:reqSel]) {
        AevonAppLogWrite("app: rot ask no selector\n");
        return;
    }
    // 先让全链每个 VC 表个态：0.4.76 — 353 实锤系统协商问的是容器链叶子
    // （TabBar→selected→Nav→top→presented），0.4.75 只叫 root 不够 —— hook
    // 挂了根、叶子仍答 portrait，ask 照样被拒。沿叶子走链逐个叫，顺带把
    // 老接口 `attemptRotationToDeviceOrientation` 兜底叫一遍（deprecated
    // 但 iOS 16 仍会触发一次重算）。
    AevonSioNudgeAll();
    {
        SEL legacy = sel_registerName("attemptRotationToDeviceOrientation");
        Method lm = class_getClassMethod([UIViewController class], legacy);
        if (lm != NULL) {
            ((void (*)(id, SEL))objc_msgSend)([UIViewController class], legacy);
        }
    }
    // 0.4.76 — scene 状态读数：353 里 hook 到叶子级后错误升级成
    // `BSActionErrorDomain错误1`（VC 检查过了、事务层被拒，当时抖音刚退全屏
    // 1 秒、页面在狂刷 layout）。下一步取证要看事务被拒那一拍 scene 是否
    // 前台活跃、有没有 key 窗 —— 事务拒绝若与活跃态相关，读数直接定位。
    char sline[96];
    snprintf(sline, sizeof(sline), "app: rot scene act=%ld win=%lu\n",
             (long)ws.activationState, (unsigned long)ws.windows.count);
    AevonAppLogWrite(sline);
    NSUInteger mask = on
        ? (UIInterfaceOrientationMaskLandscapeRight | UIInterfaceOrientationMaskLandscapeLeft)
        : UIInterfaceOrientationMaskPortrait;
    id (*initFn)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
    id prefs = initFn([prefsCls alloc],
                      sel_registerName("initWithInterfaceOrientations:"), mask);
    if (prefs == nil) {
        AevonAppLogWrite("app: rot ask no prefs\n");
        return;
    }
    char line[96];
    snprintf(line, sizeof(line), "app: rot ask %d mask=%lu\n",
             on ? 1 : 0, (unsigned long)mask);
    AevonAppLogWrite(line);
    ((void (*)(id, SEL, id, id))objc_msgSend)(ws, reqSel, prefs, ^(NSError *error) {
        char note[192];
        snprintf(note, sizeof(note), "app: rot ask failed %s\n",
                 (error != nil && error.localizedDescription != nil)
                     ? [error.localizedDescription UTF8String] : "-");
        AevonAppLogWrite(note);
        if (error != nil) AevonRotAskFails += 1;
    });
#if !__has_feature(objc_arc)
    [prefs release];
#endif
}

/// 0.4.77 — 长按切横的真通路：**把协商路径上每一个可能回答方向的节点
/// 全部临时改成「答放行」**，再把链上的类名摊在日志里。
///
/// 353 + 354 两次判决，把「挂哪个节点」这条猜测打死了：
/// ① 0.4.75 挂根链顶层（`AWENormalModeTabBarController`）→ ask 仍
///    「受支持：portrait」；
/// ② 0.4.76 走链到叶子挂（`AWEFeedCellViewController`）→ ask 仍
///    「受支持：portrait」（354 · 12:15:15，`rot scene act=0 win=2` 前台活跃）。
/// 结论：协商回答的不是根、也不是最后一个子 VC，而是链**中间某个 override**，
/// 或 AppDelegate 的 `application:supportedInterfaceOrientationsForWindow:`
/// （视频类 App 把「当前允许什么方向」收在 App 级是常见写法）。再猜一个类
/// 就又是一版空跑 —— 这一版把整条链 + App 方向门全部换掉，并打一行
/// `rot chain cls=a>b>c` 作为下一版的证词。
///
/// 0.4.75 那次「挂 `AWELandscapeNavigationController` 后错误升级成
/// BSActionErrorDomain 1」不代表 hook 生效：那个类是抖音自己的全屏播放器，
/// 原生就答横屏 —— 错误变化来自「当时它就是 presented 顶层」，不是我们的手。
/// 这解释了为什么 hook 换实现从没影响过「受支持：portrait」这个报错。
///
/// 窗口纪律不变：只在 `AevonRotWantSeen == 1` 期间答放行，want=0 一到立刻
/// 按逆序还原（Method 级登记，基类继承拿到的同一个 Method 只换一次）。
#define AEVON_ROT_HOOK_MAX 16
static Method AevonHookMs[AEVON_ROT_HOOK_MAX];
static IMP AevonHookOld[AEVON_ROT_HOOK_MAX];
static int AevonHookN = 0;

static IMP AevonHookOrigFor(Method m) {
    if (m == NULL) return NULL;
    int i;
    for (i = 0; i < AevonHookN; i++) {
        if (AevonHookMs[i] == m) return AevonHookOld[i];
    }
    return NULL;
}

static NSUInteger AevonHookSIO(id self, SEL _cmd) {
    if (AevonRotWantSeen == 1) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    }
    IMP orig = AevonHookOrigFor(class_getInstanceMethod([self class], _cmd));
    if (orig != NULL) {
        return ((NSUInteger (*)(id, SEL))orig)(self, _cmd);
    }
    return UIInterfaceOrientationMaskPortrait;
}

static BOOL AevonHookAutorotate(id self, SEL _cmd) {
    if (AevonRotWantSeen == 1) return YES;
    IMP orig = AevonHookOrigFor(class_getInstanceMethod([self class], _cmd));
    if (orig != NULL) {
        return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    }
    return YES;
}

/// AppDelegate 的方向门。签名比 VC 的多两个参数，只返回蒙版、参数不读。
static NSUInteger AevonHookAppOrient(id self, SEL _cmd, id app, id window) {
    if (AevonRotWantSeen == 1) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    }
    IMP orig = AevonHookOrigFor(class_getInstanceMethod([self class], _cmd));
    if (orig != NULL) {
        return ((NSUInteger (*)(id, SEL, id, id))orig)(self, _cmd, app, window);
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

/// 把一个 (类, 选择子) 的实现临时换掉。Method 级去重：继承自基类的同一个
/// Method 只记一次 —— 否则第二个类会把自己换过的 IMP 当成「原实现」存下来，
/// 还原时把我们的 hook 又装回去。
static void AevonHookTake(Class cls, SEL sel, IMP imp) {
    if (cls == Nil) return;
    if (AevonHookN >= AEVON_ROT_HOOK_MAX) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    int i;
    for (i = 0; i < AevonHookN; i++) {
        if (AevonHookMs[i] == m) return;
    }
    AevonHookOld[AevonHookN] = method_setImplementation(m, imp);
    AevonHookMs[AevonHookN] = m;
    AevonHookN += 1;
}

/// Method 是否已在我们手里（`AevonHookTake` 过的同一个 Method）。
static BOOL AevonHookHas(Method m) {
    int i;
    if (m == NULL) return NO;
    for (i = 0; i < AevonHookN; i++) {
        if (AevonHookMs[i] == m) return YES;
    }
    return NO;
}

/// 沿 UIKit 的协商路径收集链上的类（presented 优先，容器往下钻）。
/// 353/354 的教训：回答可能来自链上任意一层，所以返回整条链而不只是叶。
/// 沿 presented 链**跨过**我们自己的守门 VC。
///
/// ⛔ 0.4.83 — 0.4.82 在 `AevonOrientChain` / `AevonOrientLeaf` 里遇到 keeper 是
/// 直接 `next = nil`（“跳过”），那等于把链**从这里剪断**，然后退到「往下钻子
/// VC」的分支。可抖音的横屏播放器恰恰是 **present 到 keeper 之上**的 ——
/// 360：`rot look sheet cls=AWELandscapeNavigationController from=AWEFeedRootViewController`，
/// keeper 在顶层时 UIKit 会把这次 presentation 转投给 keeper。
/// 于是「链上有没有横版页」在 keeper 在场时会永远答 NO ⇒ 0.4.83 那条
/// 「横版播放器在位就别收卡」的闸会失效。正确处理：keeper 本身不入链，但**穿过去**。
static UIViewController *AevonSkipKeeper(UIViewController *next) {
    int hops = 0;
    while (next != nil && hops < 4) {
        NSString *nn = NSStringFromClass([next class]);
        if ([nn rangeOfString:@"AevonRotKeeper"].location == NSNotFound) return next;
        next = [next presentedViewController];
        hops += 1;
    }
    return nil;
}

static int AevonOrientChain(UIViewController *start, Class *out, int cap) {
    UIViewController *v = start;
    int n = 0;
    int hops = 0;
    while (v != nil && hops < 10) {
        Class c = [v class];
        int i, dup = 0;
        for (i = 0; i < n; i++) {
            if (out[i] == c) { dup = 1; break; }
        }
        if (!dup && n < cap) out[n++] = c;
        // 0.4.82 — keeper 不入链（它是空壳）；0.4.83 — 但要跨过去，见 `AevonSkipKeeper`。
        UIViewController *next = AevonSkipKeeper([v presentedViewController]);
        if (next == nil && [v isKindOfClass:[UITabBarController class]]) {
            next = [(UITabBarController *)v selectedViewController];
        }
        if (next == nil && [v isKindOfClass:[UINavigationController class]]) {
            next = [(UINavigationController *)v topViewController];
        }
        if (next == nil) {
            NSArray *kids = [v childViewControllers];
            if (kids.count > 0) next = [kids lastObject];
        }
        if (next == nil || next == v) break;
        v = next;
        hops += 1;
    }
    return n;
}

/// 协商链**最深那一层**，返回实例而不是类。
///
/// 0.4.82 — 取证必须从视频区那层起扫。359 的 `rot look ctl` 从
/// `[keyWindow rootViewController].view` 起扫，1200 个节点的预算全花在
/// `UILayoutContainerView > UITransitionView > …` 这条外壳上，最后只捞到
/// 9 个 tabbar 控件，视频区的全屏入口一个都没进 —— 0.4.74 的 7 连 tap miss
/// 八成也是同一个坑（不是没有那个按钮，是根本没扫到）。
///
/// 遍历规则与 `AevonOrientChain` 逐条对齐（presented 优先，再容器），在这里
/// 只把「收类」换成「收实例」。
static UIViewController *AevonOrientLeaf(UIViewController *start) {
    UIViewController *v = start;
    int hops = 0;
    while (v != nil && hops < 12) {
        // 与 `AevonOrientChain` 同一把闸：keeper 不入链、但要跨过去。
        UIViewController *next = AevonSkipKeeper([v presentedViewController]);
        if (next == nil && [v isKindOfClass:[UITabBarController class]]) {
            next = [(UITabBarController *)v selectedViewController];
        }
        if (next == nil && [v isKindOfClass:[UINavigationController class]]) {
            next = [(UINavigationController *)v topViewController];
        }
        if (next == nil) {
            NSArray *kids = [v childViewControllers];
            if (kids.count > 0) next = [kids lastObject];
        }
        if (next == nil || next == v) break;
        v = next;
        hops += 1;
    }
    return v;
}

/// 把 setNeedsUpdate 沿协商路径全叫一遍：不只 presented 链，容器
/// （TabBar→selected、Nav→top）也逐层叫 —— 系统缓存的是链上那层的答案。
static void AevonSioNudgeAll(void) {
    UIWindow *kw = AevonKeyWindow();
    if (kw == nil) return;
    UIViewController *v = [kw rootViewController];
    SEL nudge = sel_registerName("setNeedsUpdateOfSupportedInterfaceOrientations");
    int hops = 0;
    while (v != nil && hops < 12) {
        if ([v respondsToSelector:nudge]) {
            ((void (*)(id, SEL))objc_msgSend)(v, nudge);
        }
        // 0.4.82 — 同 `AevonOrientChain`：keeper 只是空壳，nudge 它没有意义。
        // 0.4.83 — 但必须跨过去：抖音的横屏页在 keeper 之上，那一层才需要表态。
        UIViewController *next = AevonSkipKeeper([v presentedViewController]);
        if (next == nil && [v isKindOfClass:[UITabBarController class]]) {
            next = [(UITabBarController *)v selectedViewController];
        }
        if (next == nil && [v isKindOfClass:[UINavigationController class]]) {
            next = [(UINavigationController *)v topViewController];
        }
        v = next;
        hops += 1;
    }
}

static void AevonOrientHookRestoreQuiet(void) {
    int i;
    for (i = AevonHookN - 1; i >= 0; i--) {
        method_setImplementation(AevonHookMs[i], AevonHookOld[i]);
    }
    AevonHookN = 0;
}

static void AevonOrientHookInstall(void) {
    // ⛔ 全是 UIKit / objc runtime，只主线程（调用点在 ApplyWant 主线程段）。
    // 0.4.79 — 两条静默 return 都补一行证词：356 的日志里 `rot hook` 一行都没有，
    // 而第一版判断只能靠「有 show、没 hook」这个缺席来推时序，太吃力。
    UIWindow *kw = AevonKeyWindow();
    UIViewController *top = [kw rootViewController];
    if (top == nil) {
        AevonAppLogWrite("app: rot hook skip why=root\n");
        return;
    }
    Class chain[10];
    int n = AevonOrientChain(top, chain, 10);
    if (n <= 0) {
        AevonAppLogWrite("app: rot hook skip why=chain\n");
        return;
    }
    // AppDelegate 的方向门：视频类 App 常把它当真正的总闸。
    Class appCls = [[[UIApplication sharedApplication] delegate] class];
    SEL appSel = @selector(application:supportedInterfaceOrientationsForWindow:);
    Method appM = (appCls != Nil) ? class_getInstanceMethod(appCls, appSel) : NULL;
    // 链上每层与 App 门都还挂着 ⇒ 只叫系统重算（页面没换、缓存老了）。
    BOOL allDone = YES;
    int i;
    for (i = 0; i < n; i++) {
        if (!AevonHookHas(class_getInstanceMethod(chain[i],
                                                  @selector(supportedInterfaceOrientations)))) {
            allDone = NO;
            break;
        }
    }
    if (appM != NULL && !AevonHookHas(appM)) allDone = NO;
    if (allDone) {
        AevonSioNudgeAll();
        return;
    }
    // 链换了（用户切了页面）：先整批还原，再按新链重挂。
    AevonOrientHookRestoreQuiet();
    for (i = 0; i < n; i++) {
        AevonHookTake(chain[i], @selector(supportedInterfaceOrientations), (IMP)AevonHookSIO);
        AevonHookTake(chain[i], @selector(shouldAutorotate), (IMP)AevonHookAutorotate);
    }
    // 基类兜底：链上没 override 的 VC 会继承 UIViewController 的实现，
    // 这一换让「任何 VC」在窗口期都答放行（窗口由 WantSeen 把守）。
    AevonHookTake([UIViewController class],
                  @selector(supportedInterfaceOrientations), (IMP)AevonHookSIO);
    AevonHookTake([UIViewController class],
                  @selector(shouldAutorotate), (IMP)AevonHookAutorotate);
    if (appM != NULL) {
        AevonHookTake(appCls, appSel, (IMP)AevonHookAppOrient);
    }
    AevonSioNudgeAll();
    // 证词：链上类名摊开（下一版若仍被拒，这两行告诉我们协商的是谁）。
    char buf[400];
    int off = 0;
    for (i = 0; i < n && off < (int)sizeof(buf) - 64; i++) {
        NSString *name = NSStringFromClass(chain[i]);
        const char *c = name.length > 0 ? [name UTF8String] : "-";
        if (i == 0) {
            off += snprintf(buf + off, sizeof(buf) - off, "%s", c);
        } else {
            off += snprintf(buf + off, sizeof(buf) - off, ">%s", c);
        }
    }
    char line[512];
    snprintf(line, sizeof(line), "app: rot chain cls=%s\n", buf);
    AevonAppLogWrite(line);
    NSString *leafName = NSStringFromClass(chain[n - 1]);
    snprintf(line, sizeof(line), "app: rot hook cls=%s\n",
             leafName.length > 0 ? [leafName UTF8String] : "-");
    AevonAppLogWrite(line);
    snprintf(line, sizeof(line), "app: rot hook n=%d app=%d\n",
             AevonHookN, appM != NULL ? 1 : 0);
    AevonAppLogWrite(line);
}

static void AevonOrientHookRestore(void) {
    if (AevonHookN == 0) return;
    char line[96];
    snprintf(line, sizeof(line), "app: rot hook restore n=%d\n", AevonHookN);
    AevonAppLogWrite(line);
    AevonOrientHookRestoreQuiet();
    AevonSioNudgeAll();
}

/// 0.4.79 — **App 级方向门现在到底答什么。**
///
/// 356 的血案：present 守门 VC 那一拍，App 级方向门还是抖音原生的「只竖屏」，
/// 而守门 VC 只答横屏 ⇒ 交集为空 ⇒ UIKit 抛出
/// `UIApplicationInvalidInterfaceOrientation: Supported orientations has no common
/// orientation with the application` ⇒ SIGABRT ⇒ 抖音进程被杀（用户看到的是
/// 「长按左下中段就闪退、悬浮窗没了、只能重新打开」）。
///
/// 所以 present 之前必须先问这一句：**门开了才敢立 VC**。两个来源按 UIKit 自己
/// 的优先级排：AppDelegate 实现了 `application:supportedInterfaceOrientationsForWindow:`
/// 就问它（我们 hook 的正是它），否则读 Info.plist。
static NSUInteger AevonAppOrientNow(UIWindow *win) {
    id del = [[UIApplication sharedApplication] delegate];
    SEL sel = @selector(application:supportedInterfaceOrientationsForWindow:);
    if (del != nil && [del respondsToSelector:sel]) {
        return ((NSUInteger (*)(id, SEL, id, id))objc_msgSend)(
            del, sel, [UIApplication sharedApplication], win);
    }
    NSArray *list = [[NSBundle mainBundle]
                     objectForInfoDictionaryKey:@"UISupportedInterfaceOrientations"];
    if (![list isKindOfClass:[NSArray class]]) return UIInterfaceOrientationMaskPortrait;
    NSUInteger mask = 0;
    for (NSString *one in list) {
        if (![one isKindOfClass:[NSString class]]) continue;
        if ([one isEqualToString:@"UIInterfaceOrientationPortrait"]) {
            mask |= UIInterfaceOrientationMaskPortrait;
        } else if ([one isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
            mask |= UIInterfaceOrientationMaskPortraitUpsideDown;
        } else if ([one isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) {
            mask |= UIInterfaceOrientationMaskLandscapeLeft;
        } else if ([one isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) {
            mask |= UIInterfaceOrientationMaskLandscapeRight;
        }
    }
    return mask ? mask : UIInterfaceOrientationMaskPortrait;
}

/// 1 = App 门此刻含横屏（`AevonRotKeeperShow` 里设，keeper 的两个方向方法读）。
/// 为什么走这个全局而不是让 keeper 每次自己去问 AppDelegate：UIKit 在
/// presentation 落地时会**同步**问 keeper 的 `supportedInterfaceOrientations`
/// 与 `preferredInterfaceOrientationForPresentation`，在那里面回调 App 的
/// delegate 是给系统塞一次重入；而且 keeper 的 `self.view.window` 那一刻还不
/// 存在，传 nil 会问出另一套答案。进门之前算一次，两个方法只读结果。
static int AevonRotKeeperDoorOpen = 0;

/// 1 = 「present 守门 VC」这条路已被判死（UIKit **真抛过**方向异常），不再尝试。
/// ⛔ 0.4.80 — 只有异常能置这个位。357 把「门关着」这条判死线证伪了：那次门关
/// 是因为 hook 还没装上（首次请求落在冷启动第 2 秒，`rot hook skip why=root`
/// + `rot keeper wait n=1`），1.2 s 后 hook 装成（`rot hook n=5 app=1`）门就开了；
/// 可 0.4.79 把「门关」也写进这个粘性位，同一轮里 `hold` 之后再也不 present
/// ⇒ 长按完全没反应、世界永远竖着。
/// ⛔ 粘性开关必须有同寿命刷新源：只由 `AevonRotWantSeen` 的 0 → 1 上升沿清零。
static int AevonRotKeeperDead = 0;

/// 0.4.78 — **透明横屏守门 VC：复刻抖音自己那条路。**
///
/// 355 把「让 App 转横」这条线判决完了：
/// ① `rot chain` 摊出十层类名（TabBar → …Nav → feed → cell → playInteraction），
///    `rot hook n=5 app=1` 说明整条链 + AppDelegate 的方向门**全部**换成了
///    「答放行」；
/// ② 即便如此，`rot ask 1 mask=24` 仍然 `BSActionErrorDomain错误1` —— 而且
///    `rot ask 0 mask=2`（请求**竖屏**）报的是同一个错。**请求根本没走到 VC
///    协商那一层**，所以方向回答换多少层都是白换；
/// ③ 13:05:58 用户手点抖音全屏：`card landscape entered by app vid=717x430@0,0`
///    + `rot follow 1 world=717x430` —— App 自己把世界转过去了，而同一份日志
///    里紧挨着的是 `page sheet AWELandscapeNavigationController`。
///
/// 把 ③ 和 ② 放一起只剩一条解释：**能转世界的不是 `requestGeometryUpdate`，
/// 是「present 一个只支持横屏的全屏 VC」**。UIKit 在 presentation 落地时按
/// presented VC 的 `supportedInterfaceOrientations` /
/// `preferredInterfaceOrientationForPresentation` 自己去要一次几何更新，那条
/// 请求从 UIKit 内部发出 —— 抖音的全屏播放器走的就是它，我们直接发的那条却
/// 一律被拒（四版、十几次、两种蒙版）。
///
/// 所以这一版不再猜「该 hook 谁」，改成**造一个和抖音全屏播放器同构的东西**：
/// 背景全透明、`OverFullScreen`、只答横屏的 VC。want=1 时 present 它，世界被
/// UIKit 转过去；want=0 时 dismiss，世界转回竖。抖音的播放器是「看得见的那个」，
/// 我们这个是「看不见的那个」，对系统来说同一类东西。
///
/// ⚠️ 触摸必须穿透：presented 那一层容器会把落在自己身上的触摸吃掉，横屏后
/// 视频就拖不动了。容器里只有我们这一个透明视图，所以 `viewDidAppear` 里把
/// **容器**的交互整体关掉，命中测试继续往下走到承载页（见 `passthru` 那行）。
@interface AevonRotKeeper : UIViewController
@end

@implementation AevonRotKeeper
- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    v.backgroundColor = [UIColor clearColor];
    v.opaque = NO;
    v.userInteractionEnabled = NO;
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = v;
#if !__has_feature(objc_arc)
    [v release];
#endif
}
- (BOOL)shouldAutorotate {
    return YES;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // ⛔ 0.4.79 防崩第一道（356 血案）：App 级方向门若不含横屏，这里**绝不能**
    // 再答横屏。UIKit 在 presentation 落地时检查「presented ∩ application」，
    // 交集为空就抛 `UIApplicationInvalidInterfaceOrientation` 把进程带走。
    // 门没开就答竖屏 —— present 会成，世界不转，下一拍闸再来一次。
    // ⛔ 返回类型必须写 `UIInterfaceOrientationMask`：写成 `NSUInteger` 会被
    // `-Werror,-Wmismatched-return-types` 判死（0.4.78 CI 实测）。
    if (AevonRotKeeperDoorOpen != 1 || AevonRotWantSeen != 1) {
        return UIInterfaceOrientationMaskPortrait;
    }
    return UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    // ⛔ 必须落在 `supportedInterfaceOrientations` 里，否则是**另一个**异常
    // （"preferredInterfaceOrientationForPresentation must return a supported
    // orientation"）。所以这一问跟上面同一把闸，同生同死。
    if (AevonRotKeeperDoorOpen != 1 || AevonRotWantSeen != 1) {
        return UIInterfaceOrientationPortrait;
    }
    return UIInterfaceOrientationLandscapeRight;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UIView *host = self.view.superview;
    if (host == nil) return;
    // ⛔ 只关「转场容器」这一层。若 superview 直接是 window（某些 presentation
    // 风格会这样），关掉它等于全 App 没触摸 —— 那比不能拖视频严重得多，宁可
    // 放弃穿透也不动 window。
    BOOL isWindow = [host isKindOfClass:[UIWindow class]];
    if (!isWindow) host.userInteractionEnabled = NO;
    NSString *name = NSStringFromClass([host class]);
    char line[160];
    snprintf(line, sizeof(line), "app: rot keeper passthru cls=%s off=%d\n",
             name.length > 0 ? [name UTF8String] : "-", isWindow ? 0 : 1);
    AevonAppLogWrite(line);
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    UIView *host = self.view.superview;
    if (host != nil && ![host isKindOfClass:[UIWindow class]]) {
        host.userInteractionEnabled = YES;
    }
}
@end

static AevonRotKeeper *AevonRotKeeperVC = nil;
/// 本轮 want=1 的证词配额（`wait` / `block` 各最多 3 行）：追击每 0.35 s 一拍，
/// 不限就把日志灌满。
static int AevonRotKeeperWaitNotes = 0;
static int AevonRotKeeperBlockNotes = 0;
/// 追击拍数与本轮是否已补发过直发请求（`AevonRotPursue`）。
static int AevonRotPursueTick = 0;
static int AevonRotPursueAsked = 0;
/// 0.4.81 — 本轮已经把残留 keeper 撤掉重建过几次（每轮清零，上限 4）。
static int AevonRotKeeperRebuilds = 0;
/// 重建那一拍要从 `AevonRotKeeperShow` 里撤自己，Hide 定义在后面。
static void AevonRotKeeperHide(void);

/// 0.4.81 — **取证：抖音自己的「横屏全屏」入口到底叫什么。**
///
/// 358 第一次让世界真转横了（`rot turn ok n=1 world=717x430`），但抖音信息流
/// 不跟着重排（同一拍 `scroll box=430x430`、`tall cell 430x932`）—— 内容挤在
/// 左边 430 pt，右边一片空。用户要的效果只有它自己的横版播放器能给：手点全屏
/// 那一拍 `page sheet AWELandscapeNavigationController` +
/// `AWELandscapeMediumVideoPlayer` 铺满 717x430（358 的 14:24:08 那段）。
///
/// 0.4.74 试过按类名找按钮 tap，352 七连 miss。这次不再猜，只打三样证据：
///   ① 链上每个类（含父类两层）名字带 fullscreen / landscape / enterFull 的方法；
///   ② 视频区里所有 UIControl 的类名与位置 —— 那个按钮到底是什么类；
///   ③ hook `presentViewController:animated:completion:` —— 用户手点全屏时
///      打调用栈，直接看是谁调起来的。
/// 全是只读：一个几何都不改，一个方法都不调。
static const char *const AevonLookWords[] = {
    "fullscreen", "FullScreen", "landscape", "Landscape",
    "enterFull", "switchScreen", "rotateTo",
    // 0.4.84 — `pinch` 这一族是这版加的。359 只所以能看到 `pinch_enableLandscape`
    // 是因为它名字里带 Landscape；真正的**手势 handler** 多半只叫 `pinch*`
    // （例如 `- handlePinch:` / `- pinchGestureChanged:`），不含 landscape 就
    // 从来没被打出来过。361 已经排除按钮、只剩捏合这一条路，词表必须补全，
    // 否则下一版还得靠猜。
    "pinch", "Pinch",
    // 0.4.86 — 363 的 `rot look who` 已经把 `autoEnterLandscapeFeed` 点出来了，
    // 说明「自动进入」这一族在抖音里是单独命名的（不带 Landscape 前缀的写法
    // 也有），词表补上它们，下一版才不用再靠反查地址。
    "autoEnter", "AutoEnter", "enterLandscape", "EnterLandscape",
    "enterFeed", "EnterFeed"
};

/// 打一个类**自己**实现的方法里命中关键词的那些（不含父类，父类由调用方逐层走）。
static void AevonRotLookClass(Class c, int *budget) {
    if (c == Nil || budget == NULL || *budget <= 0) return;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    if (ms == NULL) return;
    NSString *cn = NSStringFromClass(c);
    const char *cname = (cn.length > 0) ? [cn UTF8String] : "-";
    unsigned int i;
    for (i = 0; i < n && *budget > 0; i++) {
        const char *sel = sel_getName(method_getName(ms[i]));
        if (sel == NULL) continue;
        int hit = 0;
        size_t k;
        for (k = 0; k < sizeof(AevonLookWords) / sizeof(AevonLookWords[0]); k++) {
            if (strstr(sel, AevonLookWords[k]) != NULL) { hit = 1; break; }
        }
        if (!hit) continue;
        // argc=2 表示只有 self/_cmd（无参）—— 下一版真要调它，只有这种能瞎调。
        char line[256];
        snprintf(line, sizeof(line), "app: rot look cls=%s sel=%s argc=%u\n",
                 cname, sel, (unsigned)method_getNumberOfArguments(ms[i]));
        AevonAppLogWrite(line);
        *budget -= 1;
    }
    free(ms);
}

/// 0.4.82 — 「全屏」入口的类名线索。
///
/// ⛔ 359 的 `rot look ctl` 扫完整棵 `rootVC.view` 只捞到 9 个 UIControl、全是
/// tabbar ⇒ 视频区那个全屏图标**不是 UIControl**。抖音互动层大量用「自定义
/// UIView + UITapGestureRecognizer」，按 UIControl 找永远找不到（0.4.74 的
/// 7 连 tap miss 就是这么来的）。所以这一版按**类名**找，并且要求调用方从
/// leaf VC 的 view 起扫（见 `AevonOrientLeaf`）。
static const char *const AevonPaneWords[] = {
    "FullScreen", "fullScreen", "Fullscreen", "Landscape", "landscape",
    "SwitchScreen", "Expand", "Zoom"
};

/// 类名像不像「全屏入口」。只有强特征才算候选，因为 0.4.82 的 auto 会**真的
/// 去点它** —— 宁可漏一次，也不能误触点赞/评论。
static BOOL AevonPaneStrong(NSString *cn) {
    if (cn.length == 0) return NO;
    if ([cn rangeOfString:@"FullScreen"].location != NSNotFound) return YES;
    if ([cn rangeOfString:@"fullScreen"].location != NSNotFound) return YES;
    if ([cn rangeOfString:@"Fullscreen"].location != NSNotFound) return YES;
    if ([cn rangeOfString:@"Landscape"].location != NSNotFound) return YES;
    if ([cn rangeOfString:@"landscape"].location != NSNotFound) return YES;
    if ([cn rangeOfString:@"SwitchScreen"].location != NSNotFound) return YES;
    return NO;
}

/// 走一遍视图树：类名命中词表的打一行 `rot look pane`（带位置、是不是
/// UIControl、有几个手势 —— 这三样决定下一版能不能点中），强特征的收进 `out`。
/// `visited` 是总访问上限：抖音的视图树几千个节点，只在预算内走。
static void AevonRotLookPanes(UIView *v, int depth, int *budget, int *visited,
                              UIView **out, int cap, int *outN, BOOL verbose) {
    if (v == nil || budget == NULL || visited == NULL) return;
    if (*budget <= 0 || *visited <= 0 || depth > 22) return;
    *visited -= 1;
    NSString *cn = NSStringFromClass([v class]);
    if (cn.length > 0) {
        const char *c = [cn UTF8String];
        int hit = 0;
        size_t k;
        for (k = 0; k < sizeof(AevonPaneWords) / sizeof(AevonPaneWords[0]); k++) {
            if (strstr(c, AevonPaneWords[k]) != NULL) { hit = 1; break; }
        }
        if (hit) {
            CGRect r = [v convertRect:[v bounds] toView:nil];
            BOOL ctl = [v isKindOfClass:[UIControl class]];
            NSUInteger g = [v gestureRecognizers].count;
            if (verbose) {
                // 0.4.83 — `kid=` 是这版加的：`AWELandscapeFeedEntryView` 只有
                // 81x29，光看类名分不清它是「提示条」还是「按钮」。子视图类名一眼
                // 就能判（UIImageView = 图标、UILabel = 文案、无子视图 = 纯热区）。
                char kid[160];
                size_t used = 0;
                kid[0] = 0;
                NSArray *ks = [v subviews];
                NSUInteger ki;
                for (ki = 0; ki < ks.count && ki < 4 && used + 40 < sizeof(kid); ki++) {
                    NSString *kc = NSStringFromClass([[ks objectAtIndex:ki] class]);
                    if (kc.length == 0) continue;
                    int wrote = snprintf(kid + used, sizeof(kid) - used, "%s%s",
                                         used > 0 ? "/" : "", [kc UTF8String]);
                    if (wrote > 0 && (size_t)wrote < sizeof(kid) - used) {
                        used += (size_t)wrote;
                    } else {
                        break;
                    }
                }
                // 0.4.84 — `win=/hid=/a=/ten=` 是这版加的。361 的 `miss n=0` 与
                // 用户「视频中没有全屏按钮」是同一条证据的两面：这个 view 转横
                // 那一拍是 `0,0 90x32`，但**没在 window 上**（`v.window == nil`），
                // 1.6 s 后连 dump 都扫不到 ⇒ 它既不是用户能看见的按钮，也不是
                // 可以留到下一拍再点的入口。可见性必须和位置一起记，否则下次还是
                // 只能靠猜。`ten=` 是第一个 tap 手势的 enabled（0 就是手势被关了，
                // 那种情况下 `_targets` 摸到了也不会生效）。
                int ten = -1;
                for (UIGestureRecognizer *gg in [v gestureRecognizers]) {
                    if ([gg isKindOfClass:[UITapGestureRecognizer class]]) {
                        ten = gg.enabled ? 1 : 0;
                        break;
                    }
                }
                char line[420];
                snprintf(line, sizeof(line),
                         "app: rot look pane cls=%s %.0f,%.0f %.0fx%.0f ctl=%d tap=%lu int=%d"
                         " win=%d hid=%d a=%.1f ten=%d kid=%s\n",
                         c, r.origin.x, r.origin.y, r.size.width, r.size.height,
                         ctl ? 1 : 0, (unsigned long)g, v.userInteractionEnabled ? 1 : 0,
                         v.window != nil ? 1 : 0, v.hidden ? 1 : 0,
                         (double)v.alpha, ten,
                         used > 0 ? kid : "-");
                AevonAppLogWrite(line);
                *budget -= 1;
            }
            // ⛔ 0.4.83 — **尺寸不能当门槛**：360 的 `AWELandscapeFeedEntryView` 在
            // 转入横那一拍是 `0,0 0x0`，0.4.82 的 `w>=12 && h>=12` 把它整条筛掉，
            // 于是 `rot land auto miss n=0` —— 明明抓到了入口，却当没有。
            // 0x0 也照点：我们调的是手势的 target/action（`_targets`），不经过
            // hit-test，尺寸只影响手指，不影响这一发。
            //
            // ⛔ 0.4.84 — **`v.window != nil` 这道门槛同样是错的**，而且它是
            // 361 `miss n=0` 的直接原因：同一拍 dump 明明打出
            // `AWELandscapeFeedEntryView 0,0 90x32 ctl=0 tap=1`，auto 三轮却
            // 一个候选都没收到 —— 差别只有这一句。抖音在转场里先建 view、后上窗，
            // 「还没上窗」恰恰是它已经在路上的证据，不是不该点的理由。
            // 走 gesture target/action 本来就不经过 hit-test，window 在不在都
            // 不影响这一发；真正会失效的是手势 enabled，那一点由 `ten=` 记着。
            if (out != NULL && outN != NULL && *outN < cap && AevonPaneStrong(cn)) {
                // 只在同一拍里用（auto 扫完立刻点），不跨时间保存：非 ARC 下
                // 裸指针存起来就会悬垂。
                out[*outN] = v;
                *outN += 1;
            }
        }
    }
    for (UIView *s in [v subviews]) {
        AevonRotLookPanes(s, depth + 1, budget, visited, out, cap, outN, verbose);
        if (*budget <= 0 || *visited <= 0) return;
    }
}

/// 0.4.82 — 把「AwemeCore + 偏移」翻译成 `- [类 选择子]`。
///
/// 359 的 `rot look stack` 只能给出最近的**导出**符号
/// （`AWEAwemeModelSetUGCTopicOuterInnerIsCaseShow + 2245212`）—— 一个无关的
/// 函数名加两兆偏移，看不出是谁 present 了 `AWELandscapeNavigationController`。
/// 这一版改走 objc 元数据：遍历所有类的方法表，取 `imp <= addr` 里**最接近**
/// 的那一个，命中者就是调用者所在的方法。
///
/// 只做一次（`done` 闸）：全表几万条，主线程上不该反复扫；副作用只是读元数据。
/// ⛔ 两道收窄，缺一个就会指到系统库里同地址段的方法上：
///   ① `off < 65536` —— 单个方法体不会比这更大；
///   ② 类名不能是系统类（UI / NS / CA / _ 开头）。
static void AevonRotNameAddr(void *addr) {
    static int done = 0;
    if (done || addr == NULL) return;
    done = 1;
    uintptr_t target = (uintptr_t)addr;
    Class bestCls = Nil;
    SEL bestSel = NULL;
    uintptr_t bestImp = 0;
    unsigned int cn = 0;
    Class *classes = objc_copyClassList(&cn);
    if (classes == NULL) return;
    unsigned int i, j;
    for (i = 0; i < cn; i++) {
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(classes[i], &mn);
        if (ms == NULL) continue;
        for (j = 0; j < mn; j++) {
            uintptr_t imp = (uintptr_t)method_getImplementation(ms[j]);
            if (imp <= target && imp > bestImp) {
                bestImp = imp;
                bestCls = classes[i];
                bestSel = method_getName(ms[j]);
            }
        }
        free(ms);
    }
    free(classes);
    if (bestCls == Nil || bestSel == NULL) return;
    if (target - bestImp >= 65536) return;
    NSString *name = NSStringFromClass(bestCls);
    if (name.length == 0) return;
    if ([name hasPrefix:@"UI"] || [name hasPrefix:@"NS"]
        || [name hasPrefix:@"CA"] || [name hasPrefix:@"_"]) return;
    char line[320];
    snprintf(line, sizeof(line), "app: rot look who cls=%s sel=%s off=%ld\n",
             [name UTF8String], sel_getName(bestSel), (long)(target - bestImp));
    AevonAppLogWrite(line);
}

/// `presentViewController:animated:completion:` 的原实现，以及它的替身。
/// 替身只干一件事：被 present 的类名带 Landscape（且不是我们自己的 keeper）时，
/// 把调用栈打出来 —— 那就是「用户手点全屏」触发的抖音内部路径。
typedef void (*AevonPresIMP)(id, SEL, id, BOOL, id);
static AevonPresIMP AevonPresOld = NULL;

/// 0.4.86 — 上一次「抖音自己进横屏播放器」时，那一侧的控制器实例。
///
/// 363 的 `rot look who` 已经把调用者钉死了：
///   `rot look who cls=AWEPlayInteractionLandscapeFeedController sel=autoEnterLandscapeFeed off=11736`
/// 也就是说 `AWELandscapeNavigationController` 是**从这个方法里**被 present 的。
/// 这个方法没有参数（argc=2），只要拿到实例就能直接叫抖音进横屏 —— 不用点那个
/// 根本不存在的按钮，也不用伪造手势。
///
/// 但 present 的发起者是 `AWEFeedRootViewController`（`rot look sheet ... from=`），
/// 所以 present 钩子里**多数时候抓不到**这个 controller。真正的主路是
/// `AevonFindInstance` 现场在对象图里找；这里存一份只是「用户手点过一次全屏之后
/// 就能复用」的兜底。非 ARC：手动 retain / release。
static id AevonLandPresenter = nil;

static void AevonLandPresentersNote(id obj) {
    if (obj == nil) return;
    NSString *cn = NSStringFromClass([obj class]);
    if (cn.length == 0) return;
    if ([cn rangeOfString:@"LandscapeFeedController"].location == NSNotFound) return;
    if (obj == AevonLandPresenter) return;
    id old = AevonLandPresenter;
    AevonLandPresenter = [obj retain];
    if (old != nil) [old release];
    char line[192];
    snprintf(line, sizeof(line), "app: rot land have cls=%s\n", [cn UTF8String]);
    AevonAppLogWrite(line);
}

static void AevonPresNew(id self, SEL _cmd, id vc, BOOL animated, id completion) {
    @autoreleasepool {
        // 0.4.86 — 万一 presenter 本身就是那个「横屏互动控制器」，留一份。
        AevonLandPresentersNote(self);
        NSString *cn = (vc != nil) ? NSStringFromClass([vc class]) : nil;
        if (cn.length > 0
            && ([cn rangeOfString:@"Landscape"].location != NSNotFound
                || [cn rangeOfString:@"landscape"].location != NSNotFound)
            && [cn rangeOfString:@"Aevon"].location == NSNotFound) {
            // 0.4.82 — `from=` 是这版新加的：抖音自己 present 全屏时，发起者
            // 就是「切横之后该叫谁」的答案，比调用栈里那串偏移好读得多。
            NSString *from = (self != nil) ? NSStringFromClass([self class]) : nil;
            char head[288];
            snprintf(head, sizeof(head), "app: rot look sheet cls=%s from=%s\n",
                     [cn UTF8String], from.length > 0 ? [from UTF8String] : "-");
            AevonAppLogWrite(head);
            NSArray *st = [NSThread callStackSymbols];
            NSUInteger cap = MIN(st.count, (NSUInteger)14);
            NSUInteger i;
            for (i = 0; i < cap; i++) {
                NSString *s = st[i];
                char line[320];
                snprintf(line, sizeof(line), "app: rot look stack %s\n",
                         (s.length > 0) ? [s UTF8String] : "-");
                AevonAppLogWrite(line);
            }
            // 栈帧 [0] 是替身自己，[1] 才是调用 present 的那一方（抖音）。
            NSArray *ra = [NSThread callStackReturnAddresses];
            if (ra.count > 1) {
                AevonRotNameAddr((void *)[ra[1] unsignedLongLongValue]);
            }
        }
    }
    if (AevonPresOld != NULL) {
        AevonPresOld(self, _cmd, vc, animated, completion);
    }
}

static void AevonLookInstallPresent(void) {
    static int done = 0;
    if (done) return;
    Method m = class_getInstanceMethod([UIViewController class],
                                       @selector(presentViewController:animated:completion:));
    if (m == NULL) return;
    AevonPresOld = (AevonPresIMP)method_setImplementation(m, (IMP)AevonPresNew);
    done = 1;
}

/// 长按那一拍打证据。两半各有自己的闸：
///   · 类方法列表（`rot look cls=`）进程内**只打一次** —— 链不换、方法表不会变；
///   · 控件树（`rot look pane=`）每轮最多 2 次 —— 359 只在竖屏那一拍打过（从
///     `rootViewController.view` 起、只收 UIControl），视频区的全屏入口一个都
///     没进预算。0.4.82 改成「竖屏打一次、世界转横后从 leaf VC 再打一次」。
static int AevonRotLookClsDone = 0;
static int AevonRotLookPaneRuns = 0;

static void AevonRotLookDump(BOOL withPanes) {
    if (![NSThread isMainThread]) return;
    UIWindow *kw = AevonKeyWindow();
    UIViewController *top = [kw rootViewController];
    if (top == nil) return;
    if (AevonRotLookClsDone == 0) {
        AevonRotLookClsDone = 1;
        Class chain[10];
        int n = AevonOrientChain(top, chain, 10);
        // 0.4.86 — 36 → 64。363 的清单里 `AWEPlayInteractionViewController`
        // **自己的方法一条都没打出来**（预算被前几个类的父类那几轮吃光了），
        // 而「竖屏怎么进横屏」最可能就写在它身上。
        int budget = 64;
        int i, lv;
        for (i = 0; i < n && budget > 0; i++) {
            Class c = chain[i];
            // 自己 + 两层父类：抖音的实现常落在中间那层基类上（352 的 tap 就是
            // 在子类里找错了层）。到 UIViewController 就停，那不是抖音的代码。
            // i==0 是叶子，只走自己这一层：它才是「用户点全屏」直接作用的对象。
            int levels = (i == 0) ? 1 : 3;
            for (lv = 0; lv < levels && c != Nil && budget > 0; lv++) {
                if (c == [UIViewController class] || c == [NSObject class]) break;
                AevonRotLookClass(c, &budget);
                c = class_getSuperclass(c);
            }
        }
        AevonAppLogWrite("app: rot look cls end\n");
        // present 钩子尽早装：用户点全屏可能就在几秒后。
        AevonLookInstallPresent();
    }
    if (withPanes && AevonRotLookPaneRuns < 2) {
        AevonRotLookPaneRuns += 1;
        UIViewController *leaf = AevonOrientLeaf(top);
        UIView *root = (leaf != nil) ? leaf.view : top.view;
        if (root == nil) return;
        NSString *ln = NSStringFromClass([leaf class]);
        char head[192];
        snprintf(head, sizeof(head), "app: rot look pane start leaf=%s\n",
                 ln.length > 0 ? [ln UTF8String] : "-");
        AevonAppLogWrite(head);
        // 预算比 0.4.81 宽得多：从 leaf 起扫，节点全花在视频区；depth 22 是
        // 「cell → contentView → 互动层 → 容器 → 按钮」这五层的富余量。
        int budget = 72;
        int visited = 7000;
        AevonRotLookPanes(root, 0, &budget, &visited, NULL, 0, NULL, YES);
        AevonAppLogWrite("app: rot look end\n");
    }
}

/// 链上有没有抖音自己的横版页（`AWELandscapeNavigationController` 那一路）。
/// 只读：走一遍容器链读类名，代价等同 `AevonOrientChain`。
static BOOL AevonChainHasLandscape(void) {
    // 0.4.87 — 扫**全部** window，不再只看 keyWindow。
    //
    // 364（18:17:13 竖屏点全屏）已经在 `page sheet AWELandscapeNavigationController
    // h=430` 里看见横版页了，可同一轮 `rot land hold` 却没能在 18:17:15 之前成立
    // —— 横版页是 present 出来的，它挂的那个 window 不一定是 `AevonKeyWindow()`
    // 选中的那一个（那里按 `isKeyWindow` 挑，浮层窗往往不是 key）。链上少看一眼，
    // 就把「刚点开的全屏」当成了「App 自己退回竖屏」。
    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) return NO;
    for (UIScene *one in [application connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)one windows]) {
            UIViewController *top = [win rootViewController];
            if (top == nil) continue;
            Class chain[12];
            int n = AevonOrientChain(top, chain, 12);
            int i;
            for (i = 0; i < n; i++) {
                NSString *nm = NSStringFromClass(chain[i]);
                if (nm.length == 0) continue;
                if ([nm rangeOfString:@"Landscape"].location != NSNotFound) return YES;
            }
        }
    }
    return NO;
}

/// 0.4.88 — 界面上**此刻**有没有一块横着的横版视图（`*Landscape*` 且宽 > 高）。
///
/// 为什么不能再问世界：365 的 18:33:13，`AevonRotWorld()` 读回 430x717
/// （抖音把 scene frame 请求回竖），探针在第一行就返回 NO，可同一份日志的
/// `page state after change` 里明明写着 `k1=AWELandscapeMediumVideoPlaye:0,717x430`
/// —— 播放器在屏幕上，世界不横。0.4.86/0.4.87 两道闸（链上有没有 Landscape 页、
/// 世界刚变横的 6 秒）都依赖容器链或世界，两个都不是"现在有没有画面"。
///
/// 判据就一句：**视图树上有一块类名带 Landscape、且自己宽 > 高 + 40 的视图**。
/// 宽高比是硬的：抖音的横版播放器是 717x430，竖版信息流里的同名 cell 也是横的，
/// 但那种只在翻页器里躺着（宿主横屏时正常形态），同样算"横版视图在位" —— 这
/// 正是我们要的答案：**只要它还在，就别报 0**。
///
/// 代价：一次调用最多 1200 个节点，只在「刚报过横屏 25 秒内、且这一拍要报 0」
/// 时调用（`AevonRotTick` 那一段），稳态一次都不走。
static BOOL AevonLandUILive(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return NO;
    CGFloat screenLong = 0;
    for (UIScene *one in [app connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)one;
        SEL csSel = sel_registerName("coordinateSpace");
        if (![ws respondsToSelector:csSel]) continue;
        id space = ((id (*)(id, SEL))objc_msgSend)(ws, csSel);
        if (space == nil) continue;
        CGRect cb = ((CGRect (*)(id, SEL))objc_msgSend)(space, sel_registerName("bounds"));
        CGFloat s = (cb.size.width > cb.size.height) ? cb.size.width : cb.size.height;
        if (s > screenLong) screenLong = s;
    }
    if (screenLong < 200.0) screenLong = 932.0;
    CGFloat need = screenLong * 0.5;
    int budget = 1200;
    for (UIScene *one in [app connectedScenes]) {
        if (![one isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)one windows]) {
            if (win.hidden) continue;
            NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
            NSUInteger head = 0;
            while (head < [queue count] && budget > 0) {
                UIView *v = queue[head];
                head += 1;
                budget -= 1;
                if (v.hidden || v.alpha < 0.01) continue;
                CGRect b = [v bounds];
                if (b.size.width > b.size.height + 40.0 && b.size.width >= need) {
                    const char *cn = class_getName(object_getClass(v));
                    if (cn != NULL && strstr(cn, "Landscape") != NULL) return YES;
                }
                NSArray *kids = [v subviews];
                NSUInteger n = [kids count];
                NSUInteger i;
                for (i = 0; i < n && budget > 0; i++) {
                    [queue addObject:[kids objectAtIndex:i]];
                    budget -= 1;
                }
            }
        }
    }
    return NO;
}
///
/// 360 的 `rot look who` 已经把调用者反查出来了：
///   `rot look who cls=AWEPlayInteractionLandscapeFeedController
///                sel=realEnterLandscapeFeedWithEnterMethod: off=11304`
/// 它带一个显式参数（`argc=3` = self + _cmd + 1），值就是「从哪儿进来的」那个
/// 枚举（手点 / 捏合 …）。这一版只**记下这个值再原样调回去**：万一自动点全屏
/// 还是点不中，下一版就拿确切的值直接调这个方法，不必再猜。
/// 替身里除了一行日志什么都不做，异常路径不存在。
typedef void (*AevonLandEnterIMP)(id, SEL, long);
static AevonLandEnterIMP AevonLandEnterOld = NULL;

static void AevonLandEnterNew(id self, SEL _cmd, long method) {
    static int notes = 0;
    if (notes < 4) {
        notes += 1;
        NSString *cn = (self != nil) ? NSStringFromClass([self class]) : nil;
        // 0.4.84 — 361 的 `method=11511957048` = `0x2ae2a8638`，是堆地址 ⇒ 这个
        // 入参**不是整数枚举，是对象**（`NSNumber`/`NSString` 包着的 enterMethod）。
        // 之前按 `%ld` 打只留下一个地址，等于白记。这里按对象读出 description：
        // 以后要直接调这个方法，需要的就是这个值。
        // 保护：只有看起来像堆对象的指针才去问（iOS 上 malloc 段以 0x1/0x2/0x3
        // 开头）；`@try` 兜 NSException，非法指针会崩，所以先用地址段收窄。
        char desc[96];
        desc[0] = 0;
        if (method > 0x100000000L) {
            id arg = (id)method;
            @try {
                NSString *d = [arg description];
                if (d.length > 0) {
                    snprintf(desc, sizeof(desc), "%.64s", [d UTF8String]);
                }
            } @catch (NSException *e) {
                desc[0] = 0;
            }
        }
        char line[288];
        snprintf(line, sizeof(line), "app: rot land enter method=%ld desc=%s cls=%s\n",
                 method, desc[0] != 0 ? desc : "-",
                 cn.length > 0 ? [cn UTF8String] : "-");
        AevonAppLogWrite(line);
    }
    if (AevonLandEnterOld != NULL) AevonLandEnterOld(self, _cmd, method);
}

static void AevonLandEnterHookInstall(void) {
    static int done = 0;
    if (done) return;
    Class c = objc_getClass("AWEPlayInteractionLandscapeFeedController");
    if (c == Nil) return;
    Method m = class_getInstanceMethod(c,
                                       sel_registerName("realEnterLandscapeFeedWithEnterMethod:"));
    if (m == NULL) return;
    AevonLandEnterOld = (AevonLandEnterIMP)method_setImplementation(m, (IMP)AevonLandEnterNew);
    done = 1;
}

/// 0.4.84 — 横屏入口的**第二套证词：捏合**。
///
/// 361 把「按钮」这条路彻底判死了：用户明说「视频中没有点击全屏按钮」，而
/// `AWELandscapeFeedEntryView` 三处证据都不支持它是个可点的按钮：
///   · 转横那两拍 `0,0 90x32`，`v.window == nil`（0.4.83 的收集门槛正是死在这里）；
///   · 1.6 s 后连 dump 都扫不到（`rot land auto miss n=0` ×3）；
///   · 用户肉眼看不到。
/// 与此同时 359 的 `rot look cls` 早就点名了另一条路 —— `AWEAwemeBaseViewController`
/// 上三个 `pinch_*` 方法 + `configBeforEnterToLandscapeFeedWithShouldCheck:fromPinch:`，
/// 后者的 `fromPinch:` 直说「从捏合进来的」。361 的 16:29:04 也确实进了横屏播放器
/// （`rot land enter` + `AWELandscapeNavigationController` + `vid=717x430@0,0`），
/// 但那一拍我们没有任何钩子能看到是**谁**把他叫进去的。
///
/// 这一版只装**只读**记录（记完原样调回去），不调任何抖音方法、不改状态。
/// 目的：用户再捏一次，日志就能给出完整顺序与参数 —— 0.4.85 才有资格谈「替他捏」。
/// 四个点按「转场前 → 转场中 → 进场 → 退场」排：
///   `pinch_configBeforeEnterLandscapeWithCurrentModel:` (argc=3，带 model)
///   `configBeforEnterToLandscapeFeedWithShouldCheck:fromPinch:` (argc=4，两个 BOOL)
///   `playInteractionWillEnterLandscape` (argc=2)
///   `playInteractionDidExitLandscape` (argc=2)
typedef void (*AevonPinchCfgIMP)(id, SEL, id);
typedef void (*AevonPinchBool2IMP)(id, SEL, intptr_t, intptr_t);
typedef void (*AevonPlayPhaseIMP)(id, SEL);
typedef void (*AevonPinchGestIMP)(id, SEL, id);
typedef void (*AevonPinchDestIMP)(id, SEL, long);

static AevonPinchCfgIMP AevonPinchCfgOld = NULL;
static AevonPinchBool2IMP AevonPinchBool2Old = NULL;
static AevonPlayPhaseIMP AevonPlayWillOld = NULL;
static AevonPlayPhaseIMP AevonPlayExitOld = NULL;
static AevonPinchGestIMP AevonPinchBeginOld = NULL;
static AevonPinchGestIMP AevonPinchChangeOld = NULL;
static AevonPinchGestIMP AevonPinchHandleOld = NULL;
static AevonPinchDestIMP AevonPinchDestOld = NULL;

/// 0.4.85 — 装上的钩子条数，直接打进日志。
/// 362 的「整份日志一条 `rot pinch` 都没有」有**两种**互斥解释：用户没捏，
/// 或者钩子压根没命中（`method_setImplementation` 只改基类那一份，子类
/// 覆写就走不到 —— 这是老陷阱）。没有这个计数，就永远分不清是哪一种，
/// 下一版只能继续猜。
static int AevonPinchHookN = 0;

static void AevonPinchLog(const char *what, id self, long a0, long a1, id obj) {
    NSString *cn = (self != nil) ? NSStringFromClass([self class]) : nil;
    NSString *on = (obj != nil) ? NSStringFromClass([obj class]) : nil;
    char line[288];
    snprintf(line, sizeof(line), "app: rot pinch call sel=%s a0=%ld a1=%ld obj=%s cls=%s\n",
             what, a0, a1, on.length > 0 ? [on UTF8String] : "-",
             cn.length > 0 ? [cn UTF8String] : "-");
    AevonAppLogWrite(line);
}

static void AevonPinchCfgNew(id self, SEL _cmd, id model) {
    @autoreleasepool {
        AevonPinchLog("pinch_config", self, 0, 0, model);
    }
    if (AevonPinchCfgOld != NULL) AevonPinchCfgOld(self, _cmd, model);
}

static void AevonPinchBool2New(id self, SEL _cmd, intptr_t shouldCheck, intptr_t fromPinch) {
    @autoreleasepool {
        AevonPinchLog("config_before_enter", self, (long)shouldCheck, (long)fromPinch, nil);
    }
    if (AevonPinchBool2Old != NULL) AevonPinchBool2Old(self, _cmd, shouldCheck, fromPinch);
}

static void AevonPlayWillNew(id self, SEL _cmd) {
    @autoreleasepool {
        AevonPinchLog("play_will_enter", self, 0, 0, nil);
    }
    if (AevonPlayWillOld != NULL) AevonPlayWillOld(self, _cmd);
}

static void AevonPlayExitNew(id self, SEL _cmd) {
    @autoreleasepool {
        AevonPinchLog("play_did_exit", self, 0, 0, nil);
    }
    if (AevonPlayExitOld != NULL) AevonPlayExitOld(self, _cmd);
}

/// 0.4.85 — 捏合手势本体上的每一个回调都要看见。
///
/// 362 的 `rot look cls` 已经把 `AWEAwemeBaseViewController` 的整个 flexPinch
/// 族摊开了：`flexPinchGesture`（拿手势）、`flexPinch_addGestureIfNeeded`、
/// `flexPinch_gestureBegin:` / `flexPinch_gestureChanged:` /
/// `flexPinch_didEndPinchAnimationWithDestinationType:`。
/// 最后那个带 `DestinationType` —— **这就是「捏完之后去哪」的枚举**，
/// 只有真捏一次才看得到值。0.4.84 装的四个钩子里没有它，这是漏的。
static void AevonPinchGestLog(const char *what, id self, id g) {
    NSString *cn = (self != nil) ? NSStringFromClass([self class]) : nil;
    NSString *gn = (g != nil) ? NSStringFromClass([g class]) : nil;
    long st = -1;
    double sc = 0.0;
    unsigned long nt = 0;
    BOOL isGest = (g != nil) && [g isKindOfClass:[UIGestureRecognizer class]];
    if (isGest) {
        st = (long)[(UIGestureRecognizer *)g state];
        nt = (unsigned long)[(UIGestureRecognizer *)g numberOfTouches];
    }
    if (g != nil && [g isKindOfClass:[UIPinchGestureRecognizer class]]) {
        sc = (double)[(UIPinchGestureRecognizer *)g scale];
    }
    char line[288];
    snprintf(line, sizeof(line),
             "app: rot pinch g=%s gcls=%s state=%ld scale=%.2f n=%lu cls=%s\n",
             what, (gn.length > 0) ? [gn UTF8String] : "-", st, sc, nt,
             (cn.length > 0) ? [cn UTF8String] : "-");
    AevonAppLogWrite(line);
}

static void AevonPinchBeginNew(id self, SEL _cmd, id g) {
    @autoreleasepool {
        AevonPinchGestLog("begin", self, g);
    }
    if (AevonPinchBeginOld != NULL) AevonPinchBeginOld(self, _cmd, g);
}

static void AevonPinchChangeNew(id self, SEL _cmd, id g) {
    @autoreleasepool {
        // changed 每帧都来一次，全打会把日志刷爆 —— 只在整数级 scale 变化时记。
        static double lastScale = 0.0;
        double sc = 0.0;
        if (g != nil && [g isKindOfClass:[UIPinchGestureRecognizer class]]) {
            sc = (double)[(UIPinchGestureRecognizer *)g scale];
        }
        if (sc >= lastScale + 0.1 || sc <= lastScale - 0.1 || lastScale == 0.0) {
            lastScale = sc;
            AevonPinchGestLog("changed", self, g);
        }
    }
    if (AevonPinchChangeOld != NULL) AevonPinchChangeOld(self, _cmd, g);
}

/// `handlePinchGesture:` 是捏合的总入口（`flexPinch_*` 是它的内部分支），
/// 单独留一个回调而不是复用 begin：两者的原实现不是同一个 IMP，
/// 共用槽会在回调时调到错的那一份。
static void AevonPinchHandleNew(id self, SEL _cmd, id g) {
    @autoreleasepool {
        AevonPinchGestLog("handle", self, g);
    }
    if (AevonPinchHandleOld != NULL) AevonPinchHandleOld(self, _cmd, g);
}

/// `flexPinch_didEndPinchAnimationWithDestinationType:` —— 捏合动画收尾时
/// 抖音自己说「这次捏到哪去了」。**这是全链路唯一一个把目的地写成数字的地方**，
/// 也是 0.4.86 敢直接驱动的唯一依据。
static void AevonPinchDestNew(id self, SEL _cmd, long dest) {
    @autoreleasepool {
        NSString *cn = (self != nil) ? NSStringFromClass([self class]) : nil;
        char line[224];
        snprintf(line, sizeof(line), "app: rot pinch dest=%ld cls=%s\n",
                 dest, (cn.length > 0) ? [cn UTF8String] : "-");
        AevonAppLogWrite(line);
    }
    if (AevonPinchDestOld != NULL) AevonPinchDestOld(self, _cmd, dest);
}

/// 0.4.85 — 装一个钩子，**按类逐个查**。
///
/// 0.4.84 只对 `AWEAwemeBaseViewController` 做过一次 `class_getInstanceMethod`。
/// 这有两个坑：①如果某个子类（比如叶子 `AWEPlayInteractionViewController`）
/// 覆写了同名方法，它会有一份独立的 Method，基类那一份改了也走不到；②反过来，
/// 如果方法只在父类，只查一次基类是对的。所以正确做法是**把链上每个类都查一遍**
/// ——`class_getInstanceMethod` 会返回该类的**最深实现**，重复查到的同一个
/// Method 用 `cur == newImp` 判掉，既不漏也不重复装。
static int AevonPinchHookOne(Class c, const char *selName, IMP newImp, IMP *oldSlot) {
    if (c == Nil || selName == NULL) return 0;
    Method m = class_getInstanceMethod(c, sel_registerName(selName));
    if (m == NULL) return 0;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return 0;
    if (oldSlot != NULL && *oldSlot != NULL && *oldSlot != cur) {
        // 已经有**另一个类**实现过同一个选择子。再装就得能分别调回各自的原实现，
        // 而我们只有一个槽 ⇒ 这里宁可不装（漏一条日志），也不能让 A 类的实例
        // 调到 B 类的实现上 —— 那是会改行为的事故，不是漏记。
        return 0;
    }
    if (oldSlot != NULL) *oldSlot = cur;
    method_setImplementation(m, newImp);
    return 1;
}

typedef struct {
    const char *sel;
    IMP newImp;
    IMP *oldSlot;
} AevonPinchSpec;

static void AevonPinchHookInstall(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    static const char *const kClasses[] = {
        "AWEAwemeBaseViewController",
        "AWEPlayInteractionViewController",
        "AWEFeedCellViewController",
        "AWEFeedTableViewController",
        "AWEFeedContainerViewController",
        "AWEFeedRootViewController",
        "AWEHPChannelPageViewController"
    };
    AevonPinchSpec specs[8];
    int ns = 0;
    specs[ns].sel = "flexPinch_gestureBegin:";
    specs[ns].newImp = (IMP)AevonPinchBeginNew;
    specs[ns].oldSlot = (IMP *)&AevonPinchBeginOld;
    ns += 1;
    specs[ns].sel = "flexPinch_gestureChanged:";
    specs[ns].newImp = (IMP)AevonPinchChangeNew;
    specs[ns].oldSlot = (IMP *)&AevonPinchChangeOld;
    ns += 1;
    specs[ns].sel = "flexPinch_didEndPinchAnimationWithDestinationType:";
    specs[ns].newImp = (IMP)AevonPinchDestNew;
    specs[ns].oldSlot = (IMP *)&AevonPinchDestOld;
    ns += 1;
    specs[ns].sel = "handlePinchGesture:";
    specs[ns].newImp = (IMP)AevonPinchHandleNew;
    specs[ns].oldSlot = (IMP *)&AevonPinchHandleOld;
    ns += 1;
    specs[ns].sel = "pinch_configBeforeEnterLandscapeWithCurrentModel:";
    specs[ns].newImp = (IMP)AevonPinchCfgNew;
    specs[ns].oldSlot = (IMP *)&AevonPinchCfgOld;
    ns += 1;
    specs[ns].sel = "configBeforEnterToLandscapeFeedWithShouldCheck:fromPinch:";
    specs[ns].newImp = (IMP)AevonPinchBool2New;
    specs[ns].oldSlot = (IMP *)&AevonPinchBool2Old;
    ns += 1;
    specs[ns].sel = "playInteractionWillEnterLandscape";
    specs[ns].newImp = (IMP)AevonPlayWillNew;
    specs[ns].oldSlot = (IMP *)&AevonPlayWillOld;
    ns += 1;
    specs[ns].sel = "playInteractionDidExitLandscape";
    specs[ns].newImp = (IMP)AevonPlayExitNew;
    specs[ns].oldSlot = (IMP *)&AevonPlayExitOld;
    ns += 1;

    int hit = 0;
    int miss = 0;
    int i, k;
    for (i = 0; i < ns; i++) {
        int got = 0;
        for (k = 0; k < (int)(sizeof(kClasses) / sizeof(kClasses[0])); k++) {
            Class c = objc_getClass(kClasses[k]);
            if (c == Nil) continue;
            got += AevonPinchHookOne(c, specs[i].sel, specs[i].newImp, specs[i].oldSlot);
        }
        if (got > 0) hit += 1;
        else miss += 1;
    }
    AevonPinchHookN = hit;
    char line[192];
    snprintf(line, sizeof(line), "app: rot pinch hook n=%d miss=%d\n", AevonPinchHookN, miss);
    AevonAppLogWrite(line);
}

/// 0.4.85 — 本轮是否已经排过「替用户捏合」的三拍。
/// `AevonRotApplyWant` 的 want 上升沿清零 —— 不放在 `AevonRotPinchTry` 里
/// 自排程，是为了让三拍的时间点集中在一处（`AevonRotPursue` 的 land 分支），
/// 与点击那档并列，读日志时两条线的时序一眼能对上。
static int AevonRotPinchScheduled = 0;

/// 从视图树上找一枚真的捏合手势（`flexPinchGesture` 拿不到时的兜底）。
static UIGestureRecognizer *AevonFindPinch(UIView *v, int depth) {
    if (v == nil || depth > 22) return nil;
    for (UIGestureRecognizer *g in [v gestureRecognizers]) {
        if ([g isKindOfClass:[UIPinchGestureRecognizer class]]) return g;
    }
    for (UIView *s in [v subviews]) {
        UIGestureRecognizer *r = AevonFindPinch(s, depth + 1);
        if (r != nil) return r;
    }
    return nil;
}

/// 0.4.85 — **替用户捏一次**。
///
/// 到 362 为止，能试的两条路都走完了：
///   · 按钮（`AWELandscapeFeedEntryView`）：362 全程 `0,0 0x0 ctl=0 tap=1
///     win=0 hid=1`，六轮 `how=tap ok=0` —— 它是个隐藏的零尺寸空壳，
///     从来没在 window 上，连手指都碰不到。**这条路到此为止，不再试。**
///   · 六轮自动点 + 5 秒等待：已经证明等布局结算再点是白等。
/// 剩下的唯一入口就是捏合（`configBeforEnterToLandscapeFeedWithShouldCheck:
/// fromPinch:` 的方法名里写着 `fromPinch`）。
///
/// 做法是**驱动抖音自己那枚手势**，而不是猜某个方法名去调：
///   ① 先问它要：`flexPinchGesture`（argc=2，返回手势对象）；
///   ② 拿不到就从视图树上找真的 `UIPinchGestureRecognizer`；
///   ③ 改 `scale`（KVC 写 `_scale`，只读属性的唯一入口），再用私有的
///      `setState:` 走 Began → Changed → Ended —— **UIKit 自己会去调
///      target/action**，等于抖音收到了一个真的捏合。我们不碰它任何方法。
///
/// 三道闸（这一版宁可不灵，也不许出乱子）：
///   ① 只在「世界已经横 + 链上没有横版页」时动手；
///   ② 每轮最多三拍（1.8 / 2.2 / 2.6，全部「张开」），排程在
///      `AevonRotPursue` 的 land 分支（1.6 / 3.1 / 5.0 s），三拍全失败就收手；
///      三次都用「张开」不用「捏小」—— 捏小是抖音的**双列**入口
///      （`awe_pinchToC2Feed`），会把界面切成双列，那是副作用。
///   ③ 每步 `@try`，任一步抛异常就记 `throw` 停手，不改几何、不改状态。
static void AevonRotPinchTry(int round) {
    if (![NSThread isMainThread]) {
        int r0 = round;
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotPinchTry(r0);
        });
        return;
    }
    if (AevonRotWantSeen != 1) return;
    CGSize w = AevonRotWorld();
    if (w.width <= w.height + 40.0) return;
    if (AevonChainHasLandscape()) {
        AevonSawLandPage = 1;
        AevonAppLogWrite("app: rot pinch seen\n");
        return;
    }
    UIWindow *kw = AevonKeyWindow();
    UIViewController *top = (kw != nil) ? [kw rootViewController] : nil;
    if (top == nil) return;
    UIViewController *leaf = AevonOrientLeaf(top);
    if (leaf == nil) return;

    // ① 抖音自己那枚手势。`flexPinchGesture` 是 getter，拿到的才是**真的**
    // target 载体；另外 new 一个没有 target，驱动它等于往空气里捏。
    UIGestureRecognizer *g = nil;
    SEL gsel = sel_registerName("flexPinchGesture");
    if ([leaf respondsToSelector:gsel]) {
        @try {
            id own = ((id (*)(id, SEL))objc_msgSend)(leaf, gsel);
            if (own != nil && [own isKindOfClass:[UIGestureRecognizer class]]) {
                g = (UIGestureRecognizer *)own;
            }
        } @catch (NSException *e) {
            g = nil;
        }
    }
    if (g == nil) g = AevonFindPinch(leaf.view, 0);
    NSString *ln = NSStringFromClass([leaf class]);
    if (g == nil) {
        char line[224];
        snprintf(line, sizeof(line), "app: rot pinch miss why=nogesture leaf=%s\n",
                 (ln.length > 0) ? [ln UTF8String] : "-");
        AevonAppLogWrite(line);
        return;
    }
    NSString *gn = NSStringFromClass([g class]);
    UIView *gv = [g view];
    NSString *vn = (gv != nil) ? NSStringFromClass([gv class]) : nil;
    @try {
        NSArray *ts = [g valueForKey:@"_targets"];
        char line[352];
        snprintf(line, sizeof(line),
                 "app: rot pinch look cls=%s state=%ld en=%d view=%s targets=%lu leaf=%s\n",
                 (gn.length > 0) ? [gn UTF8String] : "-",
                 (long)[g state], [g isEnabled] ? 1 : 0,
                 (vn.length > 0) ? [vn UTF8String] : "-",
                 (unsigned long)ts.count,
                 (ln.length > 0) ? [ln UTF8String] : "-");
        AevonAppLogWrite(line);
    } @catch (NSException *e) {
        AevonAppLogWrite("app: rot pinch look throw\n");
    }

    // ② 驱动。`scale` 是只读属性，KVC 会落到 `_scale` ivar 上；写不进去也
    // 不要紧 —— 抖音的 handler 至少会看到 state 变了。
    static const double kScale[3] = {1.8, 2.2, 2.6};
    int idx = (round >= 1 && round <= 3) ? (round - 1) : 0;
    double target = kScale[idx];
    BOOL fired = NO;
    @try {
        @try {
            [g setValue:@(target) forKey:@"scale"];
        } @catch (NSException *e2) {
            // 只读 ivar 不在就跳过：state 变化仍然会分发。
        }
        SEL ss = sel_registerName("setState:");
        if ([g respondsToSelector:ss]) {
            ((void (*)(id, SEL, long))objc_msgSend)(g, ss, 1);   // Began
            ((void (*)(id, SEL, long))objc_msgSend)(g, ss, 2);   // Changed
            ((void (*)(id, SEL, long))objc_msgSend)(g, ss, 3);   // Ended
            fired = YES;
        }
    } @catch (NSException *e) {
        AevonAppLogWrite("app: rot pinch throw\n");
        return;
    }
    char line[256];
    snprintf(line, sizeof(line), "app: rot pinch fire round=%d scale=%.2f ok=%d world=%.0fx%.0f\n",
             round, target, fired ? 1 : 0, w.width, w.height);
    AevonAppLogWrite(line);
}

/// 0.4.86 — 在对象图里找第一个「类名等于 want」的实例。
///
/// 为什么需要它：363 把「长按转横之后视频不跟转」的缺口钉到了**方法级**——
///   `rot look who cls=AWEPlayInteractionLandscapeFeedController sel=autoEnterLandscapeFeed off=11736`
/// 这是抖音自己进横屏播放器时走的那个方法（用户竖屏点全屏 = `rot land enter ... desc=click`
/// 之后同一拍就出现这条）。方法无参（argc=2），拿到实例就能直接叫它进横屏。
///
/// 但那个控制器不在 VC 链上（363 的 `rot chain` 十层里没有它），所以只能搜对象图：
/// 子 VC → ivar（只走 `@` 类型，block 跳过）→ view 子树。有预算上限，找不到就返回 nil，
/// 绝不无限递归（抖音的对象图几万个节点）。
static id AevonFindInstance(Class want, id root, int depth, int *budget) {
    if (want == Nil || root == nil || budget == NULL || *budget <= 0) return nil;
    if (depth > 8) return nil;
    *budget -= 1;
    if ([root class] == want) return root;
    @try {
        if ([root isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)root;
            for (UIViewController *k in [vc childViewControllers]) {
                id hit = AevonFindInstance(want, k, depth + 1, budget);
                if (hit != nil) return hit;
            }
            UIViewController *pre = [vc presentedViewController];
            if (pre != nil) {
                id hit = AevonFindInstance(want, pre, depth + 1, budget);
                if (hit != nil) return hit;
            }
        }
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList([root class], &n);
        if (ivars != NULL) {
            unsigned int i;
            for (i = 0; i < n && *budget > 0; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (enc == NULL || enc[0] != '@') continue;
                if (enc[1] == '?') continue;      // block
                id v = object_getIvar(root, ivars[i]);
                if (v == nil || v == root) continue;
                if ([v class] == want) { free(ivars); return v; }
                id hit = AevonFindInstance(want, v, depth + 1, budget);
                if (hit != nil) { free(ivars); return hit; }
            }
            free(ivars);
        }
        if ([root isKindOfClass:[UIView class]]) {
            for (UIView *s in [(UIView *)root subviews]) {
                id hit = AevonFindInstance(want, s, depth + 1, budget);
                if (hit != nil) return hit;
            }
        }
    } @catch (NSException *e) {
        return nil;
    }
    return nil;
}

/// 0.4.86 — **转横之后，直接叫抖音自己进横屏播放器。**
///
/// 三条已判死的路（都留了证词，这一版不再靠它们）：
///   · 按类名找按钮（0.4.74 的 7 连 miss、0.4.82 的六轮 ok=0）；
///   · `AWELandscapeFeedEntryView` 的手势 target（362 `hid=1 win=0 0x0`，
///     `_targets` 摸不到 ⇒ 它不在界面里）；
///   · 伪造 `UIPinchGestureRecognizer` 的 state（363 三拍全 `ok=1`，
///     抖音一条 `flexPinch_gestureBegin:` 都没收到 —— 无活跃触摸时 UIKit 直接忽略）。
///
/// 剩下唯一有方法级证据的入口就是 `autoEnterLandscapeFeed`。
/// 它属于 `AWEPlayInteractionLandscapeFeedController` —— 那个 controller 竖屏时
/// 不在链上，但 `AWELandscapeFeedEntryView`（它的一部分）一直存在于控件树里
/// （363 `0,0 90x32 win=0 hid=0`）⇒ controller 本身大概率也已经被建好了，只是没上屏。
/// 所以现场搜一遍对象图；搜不到就记 `miss`，什么都不做。
static void AevonRotAutoEnter(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotAutoEnter();
        });
        return;
    }
    if (AevonRotWantSeen != 1) return;
    CGSize w = AevonRotWorld();
    if (w.width <= w.height + 40.0) return;
    if (AevonChainHasLandscape()) {
        AevonAppLogWrite("app: rot auto enter seen\n");
        return;
    }
    id inst = nil;
    NSString *how = @"find";
    Class want = objc_getClass("AWEPlayInteractionLandscapeFeedController");
    if (want != Nil) {
        UIWindow *kw = AevonKeyWindow();
        UIViewController *top = (kw != nil) ? [kw rootViewController] : nil;
        int budget = 900;
        if (top != nil) inst = AevonFindInstance(want, top, 0, &budget);
    }
    if (inst == nil && AevonLandPresenter != nil) {
        inst = AevonLandPresenter;
        how = @"saved";
    }
    if (inst == nil) {
        AevonAppLogWrite("app: rot auto enter miss\n");
        return;
    }
    SEL sel = sel_registerName("autoEnterLandscapeFeed");
    NSString *cn = NSStringFromClass([inst class]);
    char line[224];
    @try {
        if (![inst respondsToSelector:sel]) {
            snprintf(line, sizeof(line), "app: rot auto enter nosel cls=%s\n",
                     cn.length > 0 ? [cn UTF8String] : "-");
            AevonAppLogWrite(line);
            return;
        }
        snprintf(line, sizeof(line), "app: rot auto enter fire cls=%s how=%s\n",
                 cn.length > 0 ? [cn UTF8String] : "-", [how UTF8String]);
        AevonAppLogWrite(line);
        ((void (*)(id, SEL))objc_msgSend)(inst, sel);
    } @catch (NSException *e) {
        AevonAppLogWrite("app: rot auto enter throw\n");
    }
}

/// 0.4.83 — 候选打分。360 的证据是**两头都出现过**：
///   · 16:08:44 / 16:08:46 两次 dump：`AWELandscapeFeedEntryView 0,0 0x0` ——
///     名字对、尺寸是 0（0.4.82 就是被 `w>=12 && h>=12` 筛成 `miss n=0`）；
///   · 16:09:04 / 16:09:06：同一个类变成 `175,871 81x29` / `175,1158 81x29` ——
///     尺寸对，但那两个 y 都在 717 高的窗口之外（属于别的 cell）。
/// ⇒ 名字和尺寸各给一分权重，取最高的那个：名字像入口 +2，有尺寸 +1。
/// 0x0 也照点：我们调的是手势的 `_target/action`，不经过 hit-test，
/// 尺寸只影响手指，不影响这一发。
static int AevonLandPaneScore(UIView *v) {
    NSString *cn = NSStringFromClass([v class]);
    if (cn.length == 0) return -1;
    CGRect r = [v convertRect:[v bounds] toView:nil];
    BOOL entry = ([cn rangeOfString:@"Entry"].location != NSNotFound);
    BOOL sized = (r.size.width >= 12 && r.size.height >= 12);
    return (entry ? 2 : 0) + (sized ? 1 : 0);
}

/// 0.4.82 — **世界转横之后，替用户按一次「全屏」。**
///
/// 359 的证据链已经完整：
///   · 世界能真转横，并且**站住了**（`rot turn ok n=1 world=717x430`，之后一路
///     `rot turn ok n=0` 到用户自己长按退出，全程没有一条 `rot feed exit`
///     —— 0.4.81 堵的两条自毁路都成了）；
///   · 但抖音信息流在横屏世界下**不重排**（同拍 `scroll box=430x430`、
///     `page state box=430x430`）：内容仍按 430 宽排版，右边 287 pt 空着；
///   · 用户手点全屏那一拍：`page sheet AWELandscapeNavigationController h=430
///     top=0 box=430` —— 它自己的横版播放器起来了，视频才铺满。
/// ⇒ 剩下的缺口只有一个：把「手点」换成自动。
///
/// 360 拿到的入口（这一版全部按它改）：
///   `rot look pane cls=AWELandscapeFeedEntryView 175,871 81x29 ctl=0 tap=1 int=1`
///   —— 类名直说「横屏信息流入口」，非 UIControl、挂 1 个 tap 手势。
///   0.4.82 只在 1.6 s 那一拍扫一次，而那一刻它是 `0,0 0x0`（尺寸门槛把它筛掉）
///   ⇒ `miss n=0`。0.4.83 去掉尺寸门槛、改三轮。
///
/// ⛔ 0.4.84 — 361 把原因定死了：这个入口**只存在于转场窗口里**（转横那一两秒）。
/// 三处证据：转横那两拍 `0,0 90x32` 但 `v.window == nil`；1.6 s 后三轮全
/// `miss n=0`；用户肉眼「视频中没有点击全屏按钮」。
/// ⇒ 第 1 拍就在转横**同一拍**跑，后面 0.35 / 0.8 / 1.6 / 3.0 / 5.0 s 兜底。
///
/// 三条硬约束（宁可不灵，也不许出乱子）：
///   ① 一轮 want 最多点**六拍**，每拍先查链上有没有横版页，
///      进了就 `seen` 收手 —— 绝不点第二下（第二下可能把刚起来的全屏点回去）；
///   ② 只点类名带 FullScreen / Landscape / SwitchScreen 的强特征视图
///      （`AevonPaneStrong`）—— 宁可漏，不能误触点赞/评论/分享；
///   ③ 任何一步失败都只是「没点成」：不改几何、不改状态。
static void AevonRotLandAuto(int round) {
    if (![NSThread isMainThread]) {
        int r0 = round;
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotLandAuto(r0);
        });
        return;
    }
    if (AevonRotWantSeen != 1) return;
    CGSize w = AevonRotWorld();
    if (w.width <= w.height + 40.0) {
        AevonAppLogWrite("app: rot land auto skip world=portrait\n");
        return;
    }
    if (AevonChainHasLandscape()) {
        // 已经在横版播放器里了 —— 这一轮不用点，也别再点（点第二下可能退出）。
        AevonSawLandPage = 1;
        AevonAppLogWrite("app: rot land auto seen\n");
        return;
    }
    // 0.4.83 — 横屏入口方法的取证钩子（只记参数后原样调回去，幂等）。
    AevonLandEnterHookInstall();
    // 0.4.84 — 同上，捏合那条路的只读记录；两个安装都有 done 闸，重复调无害。
    AevonPinchHookInstall();
    UIWindow *kw = AevonKeyWindow();
    UIViewController *top = (kw != nil) ? [kw rootViewController] : nil;
    if (top == nil) return;
    UIViewController *leaf = AevonOrientLeaf(top);
    UIView *root = (leaf != nil) ? leaf.view : top.view;
    if (root == nil) return;
    NSString *ln = NSStringFromClass([leaf class]);
    char head[192];
    snprintf(head, sizeof(head), "app: rot land auto start leaf=%s round=%d\n",
             ln.length > 0 ? [ln UTF8String] : "-", round);
    AevonAppLogWrite(head);
    // 现场扫、现场点：非 ARC 下把 view 指针存到下一拍就是悬垂。
    // 10 而不是 6：横屏世界里每个 cell 都可能带一个 EntryView（360 里至少
    // 三个 cell 各有一个），槽位太少会连候选都装不下。
    UIView *hits[10];
    int hn = 0;
    int budget = 1000000;   // 纯收集模式不打日志，总量由 visited 控（7000 节点）
    int visited = 7000;
    AevonRotLookPanes(root, 0, &budget, &visited, hits, 10, &hn, NO);
    if (hn == 0) {
        char line[128];
        snprintf(line, sizeof(line), "app: rot land auto miss n=%d round=%d\n", hn, round);
        AevonAppLogWrite(line);
        return;
    }
    // 按分数从高到低排（同分保持树上顺序）—— 第一个点不中就换下一个。
    int order[10];
    int i, j;
    for (i = 0; i < hn; i++) order[i] = i;
    for (i = 0; i < hn; i++) {
        int top1 = i;
        for (j = i + 1; j < hn; j++) {
            if (AevonLandPaneScore(hits[order[j]]) > AevonLandPaneScore(hits[order[top1]])) {
                top1 = j;
            }
        }
        if (top1 != i) {
            int t = order[i];
            order[i] = order[top1];
            order[top1] = t;
        }
    }
    for (i = 0; i < hn; i++) {
        UIView *v = hits[order[i]];
        NSString *cn = NSStringFromClass([v class]);
        const char *c = (cn.length > 0) ? [cn UTF8String] : "-";
        char line[256];
        if ([v isKindOfClass:[UIControl class]]) {
            snprintf(line, sizeof(line), "app: rot land auto fire cls=%s how=ctl\n", c);
            AevonAppLogWrite(line);
            @try {
                [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            } @catch (NSException *e) {
                AevonAppLogWrite("app: rot land auto throw ctl\n");
            }
            break;
        }
        // 不是 UIControl：抖音互动层用「自定义 view + tap 手势」，target/action
        // 挂在私有 ivar 上，只能 KVC 摸。摸不到就换下一个候选。
        UIGestureRecognizer *tap = nil;
        for (UIGestureRecognizer *g in [v gestureRecognizers]) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) { tap = g; break; }
        }
        if (tap == nil) {
            snprintf(line, sizeof(line), "app: rot land auto skip cls=%s why=notap\n", c);
            AevonAppLogWrite(line);
            continue;
        }
        BOOL fired = NO;
        @try {
            NSArray *ts = [tap valueForKey:@"_targets"];
            for (id t in ts) {
                id target = [t valueForKey:@"_target"];
                NSValue *sv = [t valueForKey:@"_action"];
                SEL act = (sv != nil) ? (SEL)[sv pointerValue] : NULL;
                if (target == nil || act == NULL) continue;
                if (![target respondsToSelector:act]) continue;
                ((void (*)(id, SEL, id))objc_msgSend)(target, act, tap);
                fired = YES;
                break;
            }
        } @catch (NSException *e) {
            fired = NO;
        }
        CGRect vr = [v convertRect:[v bounds] toView:nil];
        snprintf(line, sizeof(line),
                 "app: rot land auto fire cls=%s how=tap ok=%d at=%.0f,%.0f %.0fx%.0f\n",
                 c, fired ? 1 : 0, vr.origin.x, vr.origin.y, vr.size.width, vr.size.height);
        AevonAppLogWrite(line);
        if (fired) break;
    }
}

/// 把守门 VC 立起来。presenter 取 key window 的 presented 链顶层 —— present
/// 到非顶层会被 UIKit 转投到顶层，日志里就分不清是谁presented的。
static void AevonRotKeeperShow(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotKeeperShow();
        });
        return;
    }
    // ⛔ 0.4.79/0.4.80 — 只有 UIKit 真抛过方向异常才算判死：一个字都不做。
    // 356 里同一份日志连崩三次（信息流、安全模式页各来一遍），重试没有意义。
    // 「门关着」不进这里（357：那只是 hook 还没装上），交给追击再走一遍。
    if (AevonRotKeeperDead == 1) return;
    if (AevonRotKeeperVC != nil) {
        if (AevonRotKeeperVC.presentingViewController != nil) {
            CGSize kw0 = AevonRotWorld();
            BOOL land0 = (kw0.width > kw0.height + 40.0);
            // ⛔ 0.4.81 — **残留 keeper 是死的。** 世界转横靠的是 present 那一拍
            // UIKit 自己发出的几何请求；同一个 keeper 再 nudge 一百次也不会再要
            // 一次。358 的第二次长按就是照这个形状卡死的：`rot chain cls=
            // AWENormalModeTabBarController>AevonRotKeeper` —— 链到 keeper 就停，
            // 抖音真实那十层连探都没探到，`rot turn n=1..6` 世界全程 430x717。
            // 所以「世界还是竖的」+「keeper 已在场」⇒ 它必须是上一轮的残留：
            // 撤掉，让下一拍（0.35 s）重新 present 一次，换一次新的几何请求。
            // 上限 4 次/轮：抖音在长转场里会一直 present 失败，无限重建就是无限 present。
            if (!land0 && AevonRotKeeperRebuilds < 4) {
                AevonRotKeeperRebuilds += 1;
                char rl[96];
                snprintf(rl, sizeof(rl), "app: rot keeper rebuild n=%d\n",
                         AevonRotKeeperRebuilds);
                AevonAppLogWrite(rl);
                // `AevonRotKeeperHide` 会清追击拍数（退出那条路要它清零），
                // 重建这条路上不能清 —— 清了追击上限就永远不会到，六拍变无限。
                int tick0 = AevonRotPursueTick;
                AevonRotKeeperHide();
                AevonRotPursueTick = tick0;
                return;
            }
            // 已经挂着（且要么世界已横、要么重建配额用完）：只叫系统重算一遍
            // （窗口期页面可能换过，缓存老了）。
            // ⛔ 走 `sel_registerName`：这个选择子 iOS 16 才有，直接写消息发送
            // 会触发 `-Wunguarded-availability`（TARGET 是 15.0），CI 当错误。
            SEL nudge = sel_registerName("setNeedsUpdateOfSupportedInterfaceOrientations");
            if ([AevonRotKeeperVC respondsToSelector:nudge]) {
                ((void (*)(id, SEL))objc_msgSend)(AevonRotKeeperVC, nudge);
            }
            return;
        }
        // 被抖音换页一并带走了（presenting 变 nil）：放掉，下面重建。
#if !__has_feature(objc_arc)
        [AevonRotKeeperVC release];
#endif
        AevonRotKeeperVC = nil;
    }
    UIWindow *kw = AevonKeyWindow();
    UIViewController *from = [kw rootViewController];
    int hops = 0;
    while (from != nil && hops < 10) {
        UIViewController *p = [from presentedViewController];
        if (p == nil || p.isBeingDismissed) break;
        from = p;
        hops += 1;
    }
    // present 的三条前置：有 VC、它的 view 已经在窗上、它自己不在转场里。
    // ⛔ 0.4.80 — 这里不自己排队重试了：追击（`AevonRotPursue`）每 0.35 s 会再叫
    // 一次；两套定时器叠在一起，只会在抖音长转场里堆出十几发 present。
    if (from == nil || from.view.window == nil
        || from.isBeingPresented || from.isBeingDismissed) {
        if (AevonRotKeeperWaitNotes < 3) {
            AevonRotKeeperWaitNotes += 1;
            char line[96];
            snprintf(line, sizeof(line), "app: rot keeper wait n=%d\n",
                     AevonRotKeeperWaitNotes);
            AevonAppLogWrite(line);
        }
        return;
    }
    // ⛔ 0.4.79 防崩第二道（356 血案）：present 之前先问 App 级方向门。
    // 门里没有横屏 ⇒ 此刻 present 一个只答横屏的 VC **必**抛
    // `UIApplicationInvalidInterfaceOrientation` ⇒ SIGABRT ⇒ 抖音被杀。
    // 宁可这一拍不转，也不能把进程带走。
    NSUInteger appMask = AevonAppOrientNow(kw);
    NSUInteger landMask = UIInterfaceOrientationMaskLandscapeLeft |
                          UIInterfaceOrientationMaskLandscapeRight;
    if ((appMask & landMask) == 0) {
        AevonRotKeeperDoorOpen = 0;
        // ⛔ 0.4.80 — **不设判死位**。357：门关是因为 hook 还没装上（首次请求落在
        // 冷启动第 2 秒，`rot hook skip why=root`），装好之后门就开了。`hookn=`
        // 就是用来一眼分开「根本没 hook」和「有 hook 但门仍答竖屏」的取证读数。
        if (AevonRotKeeperBlockNotes < 3) {
            AevonRotKeeperBlockNotes += 1;
            char note[176];
            snprintf(note, sizeof(note),
                     "app: rot keeper block appmask=%lu hookn=%d n=%d\n",
                     (unsigned long)appMask, AevonHookN, AevonRotKeeperBlockNotes);
            AevonAppLogWrite(note);
        }
        return;
    }
    // 门开了：keeper 的两个方向方法照这个值答横屏（也是防崩第一道的数据源）。
    AevonRotKeeperDoorOpen = 1;
    AevonRotKeeper *k = [[AevonRotKeeper alloc] init];
    k.modalPresentationStyle = UIModalPresentationOverFullScreen;
    k.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    AevonRotKeeperVC = k;
    NSString *fromName = NSStringFromClass([from class]);
    char line[192];
    snprintf(line, sizeof(line), "app: rot keeper show from=%s\n",
             fromName.length > 0 ? [fromName UTF8String] : "-");
    AevonAppLogWrite(line);
    // ⛔ 0.4.79 防崩第三道：UIKit 的方向兼容检查抛的是 **NSException**，不是
    // 崩溃信号 —— 非 ARC 下 `@try/@catch` 接得住，接住了进程就活着。
    // 356 三次 `crash sig=6` 全是被这个异常带走的（前两道闸都在它之前，正常
    // 情况下到不了这里）。
    @try {
        [from presentViewController:k animated:NO completion:^{
            // 落地了才说明这拍成功；失败的那几秒由追击继续推。
        }];
    } @catch (NSException *e) {
        AevonRotKeeperDoorOpen = 0;
        AevonRotKeeperDead = 1;
        AevonRotKeeperVC = nil;
#if !__has_feature(objc_arc)
        [k release];
#endif
        NSString *why = (e.reason != nil) ? e.reason : @"-";
        char note[256];
        snprintf(note, sizeof(note), "app: rot keeper abort %s\n", [why UTF8String]);
        AevonAppLogWrite(note);
    }
}

/// 撤掉守门 VC。dismiss 之后 UIKit 按底层（已还原成竖屏的）层级再要一次几何。
static void AevonRotKeeperHide(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotKeeperHide();
        });
        return;
    }
    AevonRotKeeper *k = AevonRotKeeperVC;
    if (k == nil) return;
    // 先关门再 dismiss：keeper 在退出转场里还会被问一次方向，那时它必须答
    // 竖屏（`WantSeen` 已经是 0，这里把第一道闸的数据源也一起归零）。
    AevonRotKeeperDoorOpen = 0;
    AevonRotKeeperVC = nil;
    AevonRotPursueTick = 0;
    AevonRotKeeperWaitNotes = 0;
    AevonRotKeeperBlockNotes = 0;
    UIViewController *p = k.presentingViewController;
    if (p != nil) {
        [p dismissViewControllerAnimated:NO completion:nil];
    }
    AevonAppLogWrite("app: rot keeper hide\n");
#if !__has_feature(objc_arc)
    [k release];
#endif
    AevonSioNudgeAll();
}

/// 0.4.80 — **切横追击：每 0.35 s 重走一遍「装 hook → 问门 → 立 keeper」，
/// 最多 6 拍（≈2.1 s），世界一转横立刻收手。**
///
/// 为什么必须有这一层（357 的全部证据）：
/// 首次请求落在抖音冷启动第 2 秒 —— `rot hook skip why=root`（root VC 还没建）、
/// `rot keeper wait n=1`（没有可 present 的顶层）、`rot keeper block appmask=2`
/// （门当然答竖屏）。1.2 s 后那次重试才把 hook 装成（`rot hook n=5 app=1`），
/// 可 0.4.79 的判死位是粘性的 ⇒ 整轮再没试过第二次 ⇒ 长按零反应。
/// 这版把「一次成不成」换成「看着世界量」：只要世界还是竖的，就继续推。
///
/// ⛔ 上限是硬要求：抖音在长转场里 present 会一直失败，无限追 = 无限 present。
/// 0.4.83 — 「自动点全屏」本轮已排几拍（want 上升沿清零）＋ 轮次令牌（排队时
/// 捕获，`want` 一翻旧拍自己作废，见 `AevonRotPursue` 的 land 分支）。
static int AevonRotLandAutoN = 0;
static int AevonRotLandAutoCycle = 0;

static void AevonRotPursue(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotPursue();
        });
        return;
    }
    if (AevonRotWantSeen != 1) return;
    CGSize w = AevonRotWorld();
    BOOL land = (w.width > w.height + 40.0);
    char line[144];
    if (land) {
        // 判据：这一行出现就等于「世界真转了」，视频由 App 自己按横版重排。
        snprintf(line, sizeof(line), "app: rot turn ok n=%d world=%.0fx%.0f\n",
                 AevonRotPursueTick, w.width, w.height);
        AevonAppLogWrite(line);
        // 0.4.82 — 两件事都放在「世界已经横了」这一拍：
        //   ① 控件树第二次取证（这次从 leaf VC 起扫、连非 UIControl 一起看）；
        //   ② 排自动点全屏。
        // 359 证明抖音在横屏世界下**不会**自己进横版播放器，这一下是唯一的缺口。
        //
        // ⛔ 0.4.84 — **第一拍就在转场里**，不再等 1.6 s。
        // 361 把 0.4.83 的假设证伪了：`AWELandscapeFeedEntryView` 只在转横
        // 那两秒里存在于控件树上（dump 16:28:17/18 两次都是 `0,0 90x32`），
        // 等到 1.6 / 2.8 / 4.0 s 三轮进来，它连扫都扫不到了 ⇒ `miss n=0` ×3。
        // 也就是说这个入口**是转场过程的一部分**，要么当场点，要么永远点不到。
        // 六拍：第 0 拍在这一拍同步跑，其余 0.35 / 0.8 / 1.6 / 3.0 / 5.0 s。
        // 每拍进来先查「链上有没有横版页」，进了就 `seen` 收手，绝不点第二下
        // （第二下可能把抖音刚起来的全屏又点回去）。
        // `cycle` 是轮次令牌：want 一翻（用户长按退出/重进），旧的拍全部作废。
        AevonRotLookDump(YES);
        if (AevonRotLandAutoN == 0) {
            AevonRotLandAutoN = 6;
            int cycle = ++AevonRotLandAutoCycle;
            // ★ 0.4.86 — **主路：叫抖音自己进横屏。**
            // 363 `rot look who cls=AWEPlayInteractionLandscapeFeedController
            // sel=autoEnterLandscapeFeed` 是全项目第一个**方法级**证据：
            // 用户手点全屏时，`AWELandscapeNavigationController` 就是这个方法 present 的。
            // 两拍：0.5 s（抖音自己的转场已结算）/ 1.8 s（controller 可能是懒建的）。
            // `AevonRotAutoEnter` 内部先查链上有没有横版页，进了就 `seen` 收手。
            static const double kEnterAt[2] = {0.5, 1.8};
            int e;
            for (e = 0; e < 2; e++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(kEnterAt[e] * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (cycle != AevonRotLandAutoCycle) return;
                    AevonRotAutoEnter();
                });
            }
            // ② 对照实验：点两拍那个「按钮」（362 `hid=1 win=0 0x0`、363 同形，
            // 六轮 `ok=0` 已经把它判死）。留着只因为 miss 没有副作用，而万一
            // 抖音哪天改回真按钮，日志会立刻告诉我们 —— 比再猜一版便宜。
            AevonRotLandAuto(1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (cycle != AevonRotLandAutoCycle) return;
                AevonRotLandAuto(2);
            });
        }
        // 0.4.85 — **与点击并行的第二条线：替用户捏。**
        // 362 已经把那枚「按钮」判死了（全程 `hid=1 win=0 0x0`，六轮 ok=0），
        // 但点击那六拍照旧留着 —— 它 miss 没有副作用，而且这是唯一的对照实验
        // （万一某天抖音改回真按钮，日志会立刻告诉我们）。
        // 捏合三拍：1.6 / 3.1 / 5.0 s，scale 递增 1.8 / 2.2 / 2.6，全部「张开」。
        // 为什么不是更早：0.8 s 前抖音自己的转场动画还没结算完，那时改手势
        // 状态可能被它自己的 animator 盖掉（361 的 16:29:04 那次是转横后
        // 十几秒才自己进去的）。三次都失败也不再试 —— 见交付页的判读表。
        if (AevonRotPinchScheduled == 0) {
            AevonRotPinchScheduled = 1;
            static const double kPinchAt[3] = {1.6, 3.1, 5.0};
            int i;
            for (i = 0; i < 3; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(kPinchAt[i] * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    AevonRotPinchTry(i + 1);
                });
            }
        }
        return;
    }
    if (AevonRotPursueTick >= 6) {
        snprintf(line, sizeof(line), "app: rot turn end n=%d world=%.0fx%.0f\n",
                 AevonRotPursueTick, w.width, w.height);
        AevonAppLogWrite(line);
        return;
    }
    AevonRotPursueTick += 1;
    // ① 装 hook（root 没建好就会 skip，下一拍再来）；② 才立 keeper。
    // ⛔ 这个顺序是 356 闪退换来的硬约束，不许调（见 `AevonRotApplyWant` want==1 段）。
    AevonOrientHookInstall();
    // 0.4.84 — 捏合入口的只读记录，越早越好：抖音这套 `pinch_*` 可能在
    // 「准备进横屏」时就被调，晚一拍就漏。装的是只读替身，不影响任何行为。
    AevonPinchHookInstall();
    // 0.4.81 — 取证放在「hook 已经装上」那一拍：冷启动第 2 秒时链是空的
    // （357 `rot hook skip why=root`），那一拍 dump 出来什么都看不到。
    // 0.4.82 — 这一拍只打类方法列表（`withPanes=NO`）：竖屏这时的控件树跟
    // 不切横没区别，359 的 9 个 tabbar 控件就是这么来的。控件树等世界转横
    // 之后在 `land` 分支再打。
    if (AevonHookN >= 3) AevonRotLookDump(NO);
    AevonRotKeeperShow();
    snprintf(line, sizeof(line),
             "app: rot turn n=%d world=%.0fx%.0f door=%d hookn=%d\n",
             AevonRotPursueTick, w.width, w.height,
             AevonRotKeeperDoorOpen, AevonHookN);
    AevonAppLogWrite(line);
    // 第二拍补一次直发请求：keeper 在场时校验对象变成顶层那个「答横屏」的 VC，
    // 这一发有机会放行（355 判死的失败是**没有 keeper** 时测的）。
    if (AevonRotPursueTick == 2 && AevonRotPursueAsked == 0) {
        AevonRotPursueAsked = 1;
        AevonRotAsk(YES);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonRotPursue();
    });
}

/// 0.4.80 — 本进程的启动墙钟（`CFAbsoluteTime`）。判「宿主那条请求是不是上一轮
/// 留下的」用。取不到就返回 0（调用点一律把请求当新的）：吞掉真请求比多转一次
/// 严重得多。
static CFAbsoluteTime AevonRotProcStart(void) {
    static CFAbsoluteTime cached = -1;
    if (cached >= 0) return cached;
    cached = 0;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0 && size > 0) {
        struct timeval tv = info.kp_proc.p_starttime;
        if (tv.tv_sec > 0) {
            // 978307200 = 1970-01-01 与 2001-01-01 的秒差。
            cached = (CFAbsoluteTime)tv.tv_sec
                     + (CFAbsoluteTime)tv.tv_usec / 1000000.0 - 978307200.0;
        }
    }
    return cached;
}

/// 读一次宿主要求（`AevonRotWant`）。值和上一次一样就什么都不做。
static void AevonRotApplyWant(void) {
    // 0.4.78 — 整条路（present / dismiss / method_setImplementation / UIKit 查询）
    // 只认主线程。判重之前就切，否则「非主线程那一通被 dispatch 走、判重又把
    // 重投进来的那一通吞掉」＝ App 侧零动作零日志（0.4.67 踩过一次）。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotApplyWant();
        });
        return;
    }
    char text[32] = {0};
    Boolean ok = NO;
    CFStringRef domain = AevonRotDomain();
    if (domain != NULL) {
        CFStringRef value = CFPreferencesCopyAppValue(CFSTR("AevonRotWant"), domain);
        if (value != NULL) {
            ok = CFStringGetCString(value, text, sizeof(text) - 1, kCFStringEncodingUTF8);
            CFRelease(value);
        }
    }
    if (!ok || text[0] == '\0') {
        // 0.4.67 — 与 `AevonRotPostNow` 对称的那一半：宿主也写一份容器文件
        // （`tmp/aevon-rot`）。344 里 `app: rot ask` 零行，就是缺了这一半 ——
        // 宿主写进我们偏好域的 `AevonRotWant` 在本进程读不到。
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aevon-rot"];
        NSString *body = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (body.length == 0) return;
        snprintf(text, sizeof(text), "%s", [body UTF8String]);
    }
    if (text[0] == '\0') return;
    int want = (text[0] == '1') ? 1 : 0;
    // ⛔ 0.4.80 — **陈旧请求守卫**。357 的物证：抖音 13:56:14 冷启动，13:56:16 就读到
    // want=1（紧接着 `rot hook skip why=root` + `rot keeper wait n=1`），而用户真正
    // 的长按在 13:56:23 —— 那个 1 是**上一轮会话**留下的（宿主只在长按里写这个值，
    // 没有任何地方会清）。0.4.79 因为这些尝试全都失败而无害；0.4.80 的追击会真的
    // 把它转起来 ⇒ 卡片一开就自己变横。所以：请求文件的 mtime 早于本进程启动
    // = 不是给这一轮的，丢掉。
    if (want == 1) {
        NSString *rp = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:@"aevon-rot"];
        struct stat st;
        CFAbsoluteTime started = AevonRotProcStart();
        if (started > 0 && stat([rp fileSystemRepresentation], &st) == 0) {
            CFAbsoluteTime asked = (CFAbsoluteTime)st.st_mtimespec.tv_sec
                + (CFAbsoluteTime)st.st_mtimespec.tv_nsec / 1000000000.0 - 978307200.0;
            if (asked < started - 0.2) {
                static CFAbsoluteTime noted = 0;
                if (noted < started) {
                    noted = started;
                    char line[128];
                    snprintf(line, sizeof(line), "app: rot want stale age=%.1f\n",
                             started - asked);
                    AevonAppLogWrite(line);
                }
                return;
            }
        }
    }
    // 0.4.74 — 判重放宽：351 里 10:37:55 的一次 ask 把 `AevonRotWantSeen` 置 1，
    // 10:37:59 用户的长按（want=1）被 `want == WantSeen` 直接吞掉 —— App 侧零
    // 动作零日志。切横的重试条件改成「同一状态 1.2 s 内不重发」（限频防
    // band 通知连发），超过就真的再试一次。
    static CFAbsoluteTime AevonWantTryAt = 0;
    CFAbsoluteTime fsNow = CFAbsoluteTimeGetCurrent();
    int retry = (fsNow - AevonWantTryAt > 1.2);
    if (want == AevonRotWantSeen && !retry) return;
    int wantOld = AevonRotWantSeen;
    AevonRotWantSeen = want;
    // 0.4.88 — 宿主松手（want 1 → 0）那一刻记下来：hold 闸要在这之后的 4 s 里让路。
    if (want == 0 && wantOld == 1) AevonRotWantOffAt = CFAbsoluteTimeGetCurrent();
    AevonWantTryAt = fsNow;
    // ⛔ 0.4.79 — `AevonRotKeeperDead` 的同寿命刷新源：want 的 0 → 1 上升沿。
    // 一次长按是一轮新尝试（进程内最多被 @try/@catch 兜一次），但不许在
    // 同一轮里反复撞同一堵墙 —— 356 就是这样连崩三次的。
    if (want == 1 && wantOld == 0) {
        AevonRotKeeperDead = 0;
        AevonRotPursueTick = 0;
        AevonRotPursueAsked = 0;
        AevonRotKeeperWaitNotes = 0;
        AevonRotKeeperBlockNotes = 0;
        AevonRotKeeperRebuilds = 0;
        AevonSawLandPage = 0;
        // 0.4.82 — 「自动点全屏」这轮还没排过；控件树取证也重新给两次配额。
        // `AevonRotLookClsDone` 不在这里清：类方法表不会因为一次长按而变。
        // 0.4.83 — 令牌 +1 让上一轮还没跑的三拍全部作废（否则用户在 1 s 内
        // 反复长按，几张卡片会同时收到「点全屏」）。
        AevonRotLandAutoN = 0;
        AevonRotLandAutoCycle += 1;
        // 0.4.85 — 捏合那条路同理：新一轮从「一次都没捏」重来。
        AevonRotPinchScheduled = 0;
        AevonRotFeedHoldNotes = 0;
        AevonLandHoldNotes = 0;
        AevonRotLookPaneRuns = 0;
    }
    // ⛔ 0.4.79 — 0.4.78 在这里就 `AevonRotKeeperShow()`，那一行是 356 闪退的
    // 直接原因：守门 VC 立在 `AevonOrientHookInstall()` **之前**，present 那一刻
    // App 级方向门还是抖音原生的「只竖屏」，与只答横屏的 keeper 交集为空 ⇒
    // UIKit 抛 `UIApplicationInvalidInterfaceOrientation` ⇒ SIGABRT ⇒ 进程被杀
    // （日志里只有 `rot keeper show`、没有 `rot hook n=`，就是这条时序的铁证）。
    // 现在只在这里立，顺序固定为 **先装 hook → 再 show**（见下面 want==1 段）。
    // 已经在这个状态上就不再发：`requestGeometryUpdate` 每发一次都要走一趟系统
    // 协商，重复发等于让窗口闪一下。
    // ⛔ 0.4.80 — 「已发过同一状态」不再等于「已经到位」：发过 1 而世界仍是竖的
    // （上一次转失败、或发布之后又被系统掰回竖）时，长按必须还能再推一轮，
    // 否则就是「按了没反应」的另一种成因。
    if (AevonRotSent == want && !retry) {
        CGSize w0 = AevonRotWorld();
        BOOL land0 = (w0.width > w0.height + 40.0);
        if ((want == 1) == land0) return;
    }
    // 0.4.70 — 再要转横先把上一轮的退出锁存清掉，否则「长按切竖再切横」的第二
    // 次请求会被锁存吞成又一次退出。
    if (want == 1) {
        AevonRotFeedExit = 0;
        AevonRotFeedStreak = 0;
    }
    // 0.4.70 — 宿主要求回竖、而世界还钉在横屏：App 的 `requestGeometryUpdate`
    // 会被宿主的守护循环写回（347：`frame drift now=430x717 want=717x430
    // door=3 wrote=2`），问了也白问。直接报「全屏已退」—— 宿主收到 0 会把
    // scene frame、画布、卡片一起收回去，与「抖音自己退全屏」同一条路。
    if (want == 0) {
        // 0.4.75 — 先还原 0.4.74 的方向回答窗口（`supportedInterfaceOrientations`
        // 换回原实现 + 全链 setNeedsUpdate）：系统重算后 VC 重答 portrait，
        // 世界自己转回竖 —— 不再需要等宿主解钉或抖音自己退。
        AevonOrientHookRestore();
        // 0.4.78 — 再撤守门 VC：它一撤，底层那份「答竖屏」的层级接管，UIKit
        // 按它再要一次几何，世界转回竖。
        AevonRotKeeperHide();
        CGSize w2 = AevonRotWorld();
        if (w2.width > w2.height + 40.0) {
            AevonRotFeedExit = 1;
            AevonRotFeedStreak = 2;
            AevonRotPublish(NO, w2, CGRectNull);
            return;
        }
        return;
    }
    // 0.4.80 — 切横主路：交给追击，一拍拍推着量。
    //
    // ⛔ 追击内部的那个顺序仍是硬约束、不许调（356 闪退换来的）：
    //   ① `AevonOrientHookInstall()`：整条协商链 + AppDelegate 方向门换成「答放行」；
    //   ② `AevonRotKeeperShow()`：才 present 那个只答横屏的透明 VC。
    // 调过来就是「present 时门还没开 ⇒ 交集为空 ⇒ UIKit 抛异常杀进程」。
    //
    // 为什么不能只试一次（357）：首次请求落在抖音冷启动第 2 秒，那一刻
    // `rot hook skip why=root` + `rot keeper wait n=1`，门必然答竖屏；
    // 1.2 s 后 hook 才装成（`rot hook n=5 app=1`），而 0.4.79 的判死位是粘性的
    // ⇒ 整轮再没 present 过 ⇒ 长按零反应、世界永远 430x717。
    // 0.4.77 的整链 hook 保留：它保证世界转过去后，底下十层不会立刻把方向掰回竖。
    AevonRotPursueTick = 0;
    AevonRotPursueAsked = 0;
    AevonRotKeeperRebuilds = 0;
    AevonRotPursue();
}

/// 0.4.87 — 「世界此刻还横着」= 横屏仍然成立。见 `AevonRotTick` 里那段 364 的现场。
///
/// 364（18:17:13 竖屏点全屏）：`rot follow 1 world=717x430 vid=717x430@0,0` 之后
/// 两秒，抖音回头请求一次竖屏几何，`AevonRotProbe` 立刻答不出视频区（`vid=0x0`）
/// ⇒ on=0。那一拍链上 `AWELandscapeNavigationController` 还没排进来，0.4.86 的
/// 闸（只看链上有没有 Landscape 页）放它过去了 ⇒ 宿主 `rot follow 0` → unpin →
/// scene 被推回 430x717，而 App 的 window 已经是 717x430 —— 呈现层只显示左边
/// 430 pt，右边 287 pt 就是用户报的「右边空白」。
///
/// ⇒ 只要**世界自己还横着**（宽 > 高 + 40，与全工程同一个判据），退出就一律不算数。
static BOOL AevonRotWorldSideways(CGSize world) {
    return world.width > world.height + 40.0;
}

/// 0.4.87 — 维护「世界第一次变横」的时刻，并回答「是不是刚进去的那几秒」。
/// 见 `AevonRotOnSince` 上那段：窗口之外不能拿「世界横」当退出判据，否则自锁。
static BOOL AevonRotFreshLandscape(CGSize world) {
    if (!AevonRotWorldSideways(world)) {
        AevonRotOnSince = 0;
        return NO;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (AevonRotOnSince == 0) AevonRotOnSince = now;
    return (now - AevonRotOnSince) < 6.0;
}

/// 0.4.66 — 宿主刚给这张卡发过 band：**把当前横竖重报一次**，判重放行。
///
/// 为什么需要这一下：`AevonRotPublish` 只报「变化」。一个**暖启动**的 App
/// （进程还活着、已经报过一次竖版）在新卡片打开时不会再报，宿主那侧刚把
/// 「没有读数」写进槽里，就永远等不到 —— 卡片会以竖版画布承载一个横版世界。
/// 所以开卡那一拍由宿主发 band 叫醒我们，我们答一次当前值，握手成立。
///
/// 限流 0.8 s：band 在拖动过程中会被反复发布，每来一通就写一次偏好域 + 刷盘
/// 是不必要的；而「开卡」这件事本身不会 0.8 s 内来两次。
static void AevonRotForceNow(void) {
    CGSize world = AevonRotWorld();
    if (world.width <= 16 || world.height <= 16) return;
    CGRect video = CGRectNull;
    char why[12] = {0};
    BOOL on = AevonRotProbe(&video, why, sizeof(why));
    AevonRotSent = -1;
    // 0.4.87 — 与 `AevonRotTick` 同一条闸：开卡握手也不许把「刚横过来的世界」
    // 报成竖屏（`band` 在切横那一拍会被宿主反复发，这条路上的 0 一样会收卡）。
    // 0.4.88 — 与心跳同一组三条判据（含视图树那条），否则 band 这条旁路会把
    // 心跳刚扣住的 0 从这里漏出去。
    {
        BOOL chainHas = AevonChainHasLandscape();
        BOOL fresh = AevonRotFreshLandscape(world);
        BOOL landUI = NO;
        CFAbsoluteTime gateNow = CFAbsoluteTimeGetCurrent();
        BOOL recently = (AevonRotLandAt > 0 && (gateNow - AevonRotLandAt) < 25.0);
        BOOL hostOff = (AevonRotWantOffAt > 0 && (gateNow - AevonRotWantOffAt) < 4.0);
        if (!on && recently && !hostOff) landUI = AevonLandUILive();
        if (!on && (landUI || chainHas || fresh)) return;
    }
    AevonRotPublish(on, world, video);
}

static void AevonRotForce(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last > 0 && now - last < 0.8) return;
    last = now;
    // ⛔ Darwin 通知的回调**不保证在主线程**（`AevonBandNote` 上面那段写过这条），
    // 而 `AevonRotWorld` 要读 `window.bounds` —— UIKit 的属性只在主线程安全。
    if ([NSThread isMainThread]) {
        AevonRotForceNow();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonRotForceNow();
        });
    }
}

/// 0.3 s 一拍：**读数 + 上报**，顺带每 10 拍看一次宿主要求（≈3 s）。
///
/// 只读两个属性（键窗 bounds），不遍历、不改几何。上报本身有判重，稳态下
/// 一拍的开销就是两次属性访问。
static void AevonRotTick(void) {
    static int busy = 0;
    if (busy) return;
    busy = 1;
    CGSize world = AevonRotWorld();
    if (world.width > 16 && world.height > 16) {
        // 0.4.87 — 时间戳从「世界第一次变横」起算，不是从「on 掉下来」那一刻
        // 起算（那样用户真退出也要白等 6 秒）。364 是 18:17:13 变横、18:17:15
        // 就来了错误的 0，差 2 s ⇒ 落在窗口里。
        if (AevonRotWorldSideways(world)) {
            if (AevonRotOnSince == 0) AevonRotOnSince = CFAbsoluteTimeGetCurrent();
        } else {
            AevonRotOnSince = 0;
        }
        BOOL on = NO;
        BOOL hold = NO;
        CGRect video = CGRectNull;
        // 只在被卡片托着的时候走视图树：这一条心跳挂在**所有**被注入的 App 上，
        // 微信、QQ 这些没开卡的进程每 0.3 s 走一遍树是白花（树还都不小）。
        // 用户点全屏必然发生在卡片里，托管状态是充分条件。
        if (AevonBandHostedNow() != 0) {
            @autoreleasepool {
                char why[12] = {0};
                on = AevonRotProbe(&video, why, sizeof(why));
                // ★ 0.4.86 — **横版播放器在位时，「世界回竖」不是退出信号。**
                //
                // 363（17:35:38，竖屏卡片里用户手点全屏）：
                //   `rot land enter ... desc=click` → `rot look sheet cls=AWELandscapeNavigationController`
                //   → `win: rot follow 1 world=717x430 vid=717x430@0,0` → `card landscape entered by app`
                //   → 三秒后 `frame drift now=430x717 want=717x430`（App 请求了竖屏几何）
                //   → `win: rot follow 0 world=717x430` → `landscape unpin` → `exit phase2`。
                // 也就是我们自己把用户刚点开的横屏收掉了。抖音的横屏页之所以回头请求
                // 一次竖屏，是因为 `UIScreen.bounds` 始终是竖的（硬禁令，不许改）——
                // 它「觉得不合法」，但画面本身是铺满的（`vid=717x430@0,0`）。
                //
                // ⇒ 判据（0.4.88 起三条，任一成立就扣住、一个字节都不上报）：
                //   ① 视图树上**此刻**有一块横着的横版视图（`AevonLandUILive`）——
                //      365 的 18:33:13 只有这一条能答对：世界读到 430x717、
                //      链上也还没有 Landscape 页，可播放器就在屏幕上；
                //   ② 链上现在有 Landscape 页；
                //   ③ 世界刚横过来那 6 秒（抖音回头请求竖屏几何的窗口）。
                // 让路条件：宿主刚发过 want=0（用户点了退出钮 / 长按关横屏），
                // 以及连续扣住满 60 拍（18 s）—— 后者防「残留视图锁死一轮」。
                BOOL chainHas = AevonChainHasLandscape();
                BOOL fresh = AevonRotFreshLandscape(world);
                BOOL landUI = NO;
                {
                    CFAbsoluteTime gateNow = CFAbsoluteTimeGetCurrent();
                    BOOL recently = (AevonRotLandAt > 0 && (gateNow - AevonRotLandAt) < 25.0);
                    BOOL hostOff = (AevonRotWantOffAt > 0 && (gateNow - AevonRotWantOffAt) < 4.0);
                    if (!on && recently && !hostOff && AevonLandHoldTicks < 60) {
                        landUI = AevonLandUILive();
                    }
                }
                if (!on && (landUI || chainHas || fresh)) {
                    hold = YES;
                    AevonLandHoldTicks += 1;
                    AevonRotFeedExit = 0;
                    AevonRotFeedStreak = 0;
                    AevonSawLandPage = 1;
                    if (AevonLandHoldNotes < 8) {
                        AevonLandHoldNotes += 1;
                        char hl[192];
                        snprintf(hl, sizeof(hl),
                                 "app: rot land hold world=%.0fx%.0f vid=%.0fx%.0f why=%s gate=%s n=%d\n",
                                 world.width, world.height,
                                 video.size.width, video.size.height,
                                 why[0] != 0 ? why : "-",
                                 landUI ? "ui" : (chainHas ? "chain" : "fresh"),
                                 AevonLandHoldTicks);
                        AevonAppLogWrite(hl);
                    }
                } else {
                    AevonLandHoldTicks = 0;
                }
                // 0.4.70 — 世界横着、翻页器已翻回竖排：App 自己退了全屏，而世界
                // 被宿主钉住，探针永远看不到。连两拍落锁；锁到世界真回竖（探针
                // 返回 NO）才清，中途翻页器横竖来回不翻锁 —— 否则宿主收世界的
                // 那 1 s 里锁被清掉，flag 又弹回 1，卡片横竖来回打摆。
                if (!hold) {
                if (!on) {
                    AevonRotFeedExit = 0;
                    AevonRotFeedStreak = 0;
                    // 世界回竖 = 这一轮横屏结束，重新开始判「见没见过横版页」。
                    AevonSawLandPage = 0;
                } else if (AevonRotFeedPortrait(AevonKeyWindow())) {
                    // ⛔ 0.4.83 — **同一个「pager 竖」有两种完全相反的含义，先分清：**
                    //   · 抖音横版播放器在位（链上有类名带 Landscape 的页）⇒ 底层信息流
                    //     本来就还是竖的，这是**正常形态**，不是「App 退了」。
                    //     360 的铁证：`rot look sheet cls=AWELandscapeNavigationController`
                    //     之后 `vid=717x430@0,0` 正铺满，同一拍 pager 是 430x717 ⇒
                    //     0.4.81 的判据把**成功**读成失败，0.6 s 后自己收卡。
                    //   · 播放器已经拆掉 ⇒ 这才是 347 那个「抖音退全屏不转世界」。
                    // ⇒ 判据顺序必须是「先问链上有没有横版页」；0.4.81 那个
                    //   `AevonSawLandPage` 锁存只回答「见过」，回答不了「现在还在不在」，
                    //   拿它当门等于**一进横屏就永久判退出**。
                    if (AevonChainHasLandscape()) {
                        AevonSawLandPage = 1;
                        AevonRotFeedStreak = 0;
                        if (AevonRotFeedHoldNotes < 6) {
                            AevonRotFeedHoldNotes += 1;
                            AevonAppLogWrite("app: rot feed hold land page\n");
                        }
                    } else if (!AevonSawLandPage) {
                        // 358：长按转横成功那一拍 `rot turn ok n=1 world=717x430`，
                        // 链上只有信息流（十个类，没有一个 Landscape），而抖音信息流
                        // 在横屏世界下就是不重排（`scroll box=430x430`、`cell 430x932`）
                        // ⇒ 采信 = 「刚转成功就自己报 0」，宿主 0.3 s 内收卡回竖。
                        AevonRotFeedStreak = 0;
                    } else {
                        // 见过横版页、现在链上没有了 ⇒ 抖音自己拆了播放器。
                        // 3 拍（0.9 s）而不是 2 拍：拆页那一瞬 pager 可能还没排回来。
                        AevonRotFeedStreak += 1;
                        if (AevonRotFeedStreak >= 3 && AevonRotFeedExit == 0) {
                            AevonRotFeedExit = 1;
                            UIScrollView *pg = AevonPagerGet();
                            CGRect pb = pg != nil ? [pg bounds] : CGRectZero;
                            char fl[128];
                            snprintf(fl, sizeof(fl),
                                     "app: rot feed exit world=%.0fx%.0f pager=%.0fx%.0f\n",
                                     world.width, world.height,
                                     pb.size.width, pb.size.height);
                            AevonAppLogWrite(fl);
                        }
                    }
                } else {
                    AevonRotFeedStreak = 0;
                }
                if (AevonRotFeedExit) {
                    on = NO;
                    snprintf(why, sizeof(why), "feed");
                }
                // 只看变化：稳态下一行都不写（0.15 s 一条 `page state` 那种日志
                // 已经让 344 有 900 行了，这条通道不能再刷）。
                static int lastOn = -1;
                static CGRect lastVid = {{0, 0}, {0, 0}};
                if (on != lastOn || !CGSizeEqualToSize(video.size, lastVid.size)
                    || fabs(video.origin.y - lastVid.origin.y) > 2.0
                    || fabs(video.origin.x - lastVid.origin.x) > 2.0) {
                    lastOn = on ? 1 : 0;
                    lastVid = CGRectIsNull(video) ? CGRectMake(0, 0, 0, 0) : video;
                    if (AevonRotProbeNotes < 12) {
                        AevonRotProbeNotes += 1;
                        char line[160];
                        snprintf(line, sizeof(line),
                                 "app: rot probe on=%d world=%.0fx%.0f vid=%.0fx%.0f@%.0f,%.0f why=%s\n",
                                 on ? 1 : 0, world.width, world.height,
                                 video.size.width, video.size.height,
                                 video.origin.x, video.origin.y,
                                 why[0] != 0 ? why : "-");
                        AevonAppLogWrite(line);
                    }
                }
                }   // if (!hold)
            }
        } else {
            // 40 pt 的余量：分屏 / 键盘 / 浮层都可能让「宽高很接近」，只认真的横。
            on = world.width > world.height + 40;
        }
        // 0.4.86 — `hold` 时**一个字都不发**：宿主那侧的状态就是上一拍的 on=1，
        // 它会把 scene 继续钉在横版画布上（`frame drift` → 重写）。发了 0 就等于
        // 替用户关掉他刚点开的全屏（363 就是这么收回的）。
        if (!hold) AevonRotPublish(on, world, video);
    }
    AevonRotTicks += 1;
    if (AevonRotTicks % 10 == 1) AevonRotApplyWant();
    busy = 0;
}

static void AevonRotStart(void) {
    static int started = 0;
    if (started) return;
    started = 1;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    if (timer == NULL) return;
    uint64_t interval = (uint64_t)(0.30 * NSEC_PER_SEC);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        AevonRotTick();
    });
    dispatch_resume(timer);
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
    // 0.4.52 — **构造函数里唯一装的两条钩子**（`-UIScreen bounds` / `nativeBounds`）。
    //
    // 位置刻意放在这里：`AevonWorthInjecting()` 已经过了（这是名单内 App 的进程），
    // 崩了/卡了都有上面那两组证词兜底，而 `main()` 还没开始 —— App 读第一眼尺寸
    // 之前钩子就已经在，它不会再有「先按 932 排一版、再按 717 重排」那一段。
    // 335 的 `page transition h=717 last=932 full=932` 就是那一段的读数，抖音为它
    // 付了 2 s（重建十页 feed）。
    //
    // 为什么不是七条、为什么这两条安全：见 `AevonKeyboardNative.m` 的
    // `AevonKbEarlyInstall` 上面那一段（0.4.8 白屏的边界在那里，别越）。
    AevonKbEarlyInstall();
    // 0.4.66 — 横屏那条通道的心跳（0.3 s，见 `AevonRotTick`）。挂在构造这一拍，
    // 因为「App 自己转过去」可能发生在卡片建好之前的任何一帧（冷启动直接进
    // 横屏播放就是这种），晚建一次就漏一次。
    AevonRotStart();
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
    // 0.1.17 — 键盘在屏的那一声。软键盘属于应用这一侧，桌面要等这里报才知道
    // （见上面 `AevonKbObserve`）。
    AevonKbObserve();
    // 0.4.7 / 0.4.9 — 键盘承载面接管（`Sources/App/AevonKeyboardNative.m`）。
    //
    // 1:1 复刻母版 `SthenoKeyboard.dylib` 的四条钩子：`_UIRemoteKeyboards`
    // 的交集高度、`+UIRemoteKeyboardWindow remoteKeyboardWindowForScreen:create:`、
    // `FBSWorkspaceScenesClient` 的 settings 回调、`UIScreen -bounds`。
    // 核心是最后一条 —— 让 App 自己认为屏就是承载面那么高，UIKit 从此按 717
    // 排版，键盘、输入框、safeArea 全部自洽，不再需要任何补偿。
    //
    // 0.1.43 ~ 0.4.6 那套「intersection 换算 + 键盘窗平移 + 顶边发布 + 通知矩形
    // 改写 + 安全区让位 + 参考线兜底 + 窗口收放」已整条删除，理由见
    // `AevonKeyboardNative.m` 文件头。
    //
    // ⛔ 0.4.9 / 0.4.10 — **构造函数里一条钩子都不装，这里也不再排。**
    //
    // Aevon(293) 里 0.4.8 一装就白屏：90 条 `app: hang` 全部 `gap=-1ms`，即
    // `AevonMainBeatTick`（挂在主队列上、0.25 s 后第一拍）一次都没跑过 —— 构造
    // 函数没回来。装钩子要 `NSClassFromString` 拿 `_UIRemoteKeyboards` /
    // `UIRemoteKeyboardWindow` / `FBSWorkspaceScenesClient` 并 `[UIScreen class]`，
    // 这些在 `main()` 之前 realize 就是拿 objc runtimeLock 去跑 UIKit 的
    // `+initialize`；里面只要有一处 `dispatch_sync` 到主队列，主队列还没被 runloop
    // 服务，主线程就自己等自己。
    //
    // 0.4.9 把它挪到「构造之后 0.15 s」—— 白屏没了，但**装得太早**：那时的闸是
    // 圆盘名单，而名单在刚起来的 App 进程里读不到（Aevon(294)：宿主日志里
    // `选中 QQ (com.tencent.mqq)`，QQ 进程里却是 `native skipped, notinlist`），
    // 于是最常用的 App 根本没装钩子，键盘原样坏着。
    //
    // 0.4.10 改成**由 band 驱动**：`AevonBandObserve()` 在上面已经注册好并读过
    // 一次；从这一刻起，宿主每次说「这个 App 被托着」（`AevonBandSetOn(1)`）都会
    // 经 `AevonKbRefreshShell` → `AevonKbEnsureInstalled` 排一次安装（0.15 s、
    // 主队列）。没被托起来的进程一次类查找都不做 —— 比名单闸更严，也是 0.4.8
    // 白屏的根因所在。
    //
    // 不再需要在这里主动调任何东西：`AevonBandObserve()` 的首次读值就会走同一条路。

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
