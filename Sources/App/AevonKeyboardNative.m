// ===========================================================================
// AevonKeyboardNative.m — 0.4.7 / 0.4.9 / 0.4.10
//
// 键盘的承载面接管。**1:1 复刻 Stheno 母版的 `SthenoKeyboard.dylib`**
// （0.1.23；修复版 final.3 的键盘组件与母版只差 1 处：`0x4de8` 那个「首启打开
// inject.stheno.com」的函数被改成 `ret`，与键盘机制无关）。
//
// 逆向数据：`stheno-逆向分析/final3/analysis/hooks-SthenoKeyboard.md`
//           `stheno-逆向分析/final3/analysis/disasm-SthenoKeyboard-s0.txt`
//
// ---------------------------------------------------------------------------
// 0.4.9 — 补上母版 `0x4f4c` 的第二道闸（Aevon(293) 的真机事故）
// ---------------------------------------------------------------------------
// 0.4.8 的四条钩子本身没问题，坏在**安装入口少了一道 return**。母版：
//
//   _injectApp = _inject()                       // plist Inject，缺省 1
//   if (!_injectApp) return
//   if (!_ringAppsContains(bundleId)) return     // ← 0.4.8 漏了这一条
//
// `SthenoKeyboard.dylib` 的 Filter 也是 `com.apple.UIKit`（注入每个 App），母版
// 之所以安全，全靠第二道闸：名单外的进程**一个类都不碰**，连
// `_UIRemoteKeyboards` 都不去 realize。0.4.8 漏掉之后，`AevonApp.dylib` 在全机
// 每个 UIKit 进程（日志里连 `com.apple.CarPlayApp` 都在装）的 `main()` 之前
// realize 四个 UIKit / FrontBoard 私有类并改它们的 IMP。
//
// Aevon(293) 的证词：90 条 `app: hang`，全部 `gap=-1ms`（主线程心跳一拍未跑
// ⇒ 构造函数没回来），而四条钩子的实际生效行（`bounds ->` / `inter` /
// `win frame` / `shell hook`）**一条都没有**。用户看到的是「点开 App 白屏、
// 桌面小组件不加载」—— 与 0.0.65 / 0.0.67 同一族故障。
//
// 两处修复：
//   ① 补 `_ringAppsContains` 等价闸：读 `com.aevon` 域的 `RingApps`（圆盘名单，
//      用户自选）+ `RingAppsSnapshot` 兜底，不在名单直接 return；
//   ② 构造期不再 `CFPreferencesCopyAppValue`（cfprefsd XPC 不能在 `main()`
//      之前做），改成第一次真正需要时懒读。
//
// ---------------------------------------------------------------------------
// 0.4.10 — 安装闸从「圆盘名单」换成「宿主真的把我托起来了」（Aevon(294)）
// ---------------------------------------------------------------------------
// 0.4.9 补的那道名单闸（`_ringAppsContains`）方向是对的，取数口错了。证据：
//
//   宿主侧 14:36:27 `[圆盘] 选中 QQ (com.tencent.mqq)，打开浮窗并收起圆盘`
//   QQ 侧  14:36:26 `app: kb: native skipped, notinlist`
//
// 同一个 App，在宿主进程里明明在名单上，在**刚起来的 App 进程**里读同一个偏好域
// 却读不到；同一份日志里 Preferences / Filza 两个进程又读到了。⇒ 跨进程偏好域在
// 「刚被拉起的 App 进程」里不是可靠的事实源，拿它当安装闸会把最常用的 App 漏掉
// —— 用户这一版看到的仍然是旧键盘（QQ 里一行 `app: kb:` 的生效读数都没有）。
//
// 换成宿主自己推过来的事实：`AevonBandOn`（走 `com.aevon.band.<bundle>`，
// `AevonAppHook.m` 里那套 0.1.29 起就在跑）。它在 QQ 进程里每次都成立：
//
//   app: band note from host
//   app: band prefs on=1 band=430x717 at 0,215
//
// 这条闸比母版的名单闸**更严**：名单闸回答「这个 App 允不允许被接管」，band
// 回答「这个 App 现在正被接管」。后者为真才装钩子 ⇒ 全屏 App、系统 App、没被
// 托起来的进程一个私有类都不 realize（0.4.8 的白屏正是死在「谁来都 realize」）。
//
// ⛔ 代价（写在这里，下一份日志要能直接判）：卡片建起来之后 0.15 s 才装钩子。
// 用户点输入框远晚于此，但「卡刚出现就立刻弹出键盘」这一类场景第一次可能漏。
//
// ---------------------------------------------------------------------------
// 为什么整条旧实现要删掉
// ---------------------------------------------------------------------------
// 0.1.43 ~ 0.4.6 的做法是：App 认为屏高 932，我们手工把键盘窗摆进「承载面」
// （430×717）那个格子里 —— 改 intersection 返回值、量键盘视图顶边、平移键盘窗、
// 改写键盘通知矩形、给安全区让位、给 `UIKeyboardLayoutGuide` 兜底。七种手段，
// 每一轮都在调参，每一轮都复发。
//
// Aevon(291) 三行读数把它钉死了：
//
//   win: keyboard native on card=430x717 at 0,215 … push=0
//   app: kb: win hold h=358 top=358 sceneY=0 sceneH=717
//   app: kb: lift aligned dy=0 bottom=717 base=744 scene=717 kb=430x717
//
// 键盘窗 `kb=430x717` —— 高度等于**场景**高，底边 `bottom=717` 贴在**场景**底。
// 而真实屏高 932 ⇒ 屏幕 717..932 那 215 pt 没有东西在画（用户看到的白条），
// 键盘整块悬在 401..717 之上盖住输入条。错的不是那几个数，是「App 以为自己在
// 932 的屏上、我们手工把键盘塞进 717 的格子」这个前提本身。
//
// 母版反过来做：**让 App 自己认为屏就是承载面那么高**。`UIScreen -bounds` 返回
// `[_appScene _boundsForInterfaceOrientation:]`（承载面 bounds = 430×717），于是
// UIKit 从布局到 safeArea 到键盘全部按 717 自洽 —— 不需要任何补偿。
//
// ---------------------------------------------------------------------------
// 母版的四条钩子（地址取自 0.1.23 arm64e slice）
// ---------------------------------------------------------------------------
//   0x5128  -[_UIRemoteKeyboards intersectionHeightForWindowScene:
//                                    isLocalMinimumHeightOut:ignoreHorizontalOffset:]
//   0x5230  +[UIRemoteKeyboardWindow remoteKeyboardWindowForScreen:create:]
//   0x5430  -[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:
//                                          transitionContext:completion:]
//   0x54f4  -[UIScreen bounds]
//
// 母版还装了第五条 `+[UIApplication openURL:options:completionHandler:]`（通用链接
// 直开）。Aevon **不装**：URL 落点由 SpringBoard 侧的 `AevonOpenDecide` 单点决定
// （0.4.x 已把整条 URL 链下线），App 侧再钩一次会与它抢同一次打开。这一条不属于
// 键盘机制，缺它不影响键盘。
// ===========================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <limits.h>
#import <sys/stat.h>

// ===========================================================================
// 日志（与 AevonAppHook.m 同一落点：宿主那份优先，沙盒里退回自己的 tmp）
// ===========================================================================

static const char *AevonKbLogPath(void) {
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
        int fd = open(candidates[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        close(fd);
        snprintf(chosen, sizeof(chosen), "%s", candidates[i]);
        break;
    }
    return chosen[0] != '\0' ? chosen : NULL;
}

static void AevonKbLog(const char *line) {
    const char *path = AevonKbLogPath();
    if (path == NULL || line == NULL) return;
    struct stat info;
    const char *mode = (stat(path, &info) == 0 && info.st_size > 512 * 1024) ? "w" : "a";
    FILE *file = fopen(path, mode);
    if (file == NULL) return;
    fputs(line, file);
    fclose(file);
}

/// 每类读数各有配额：一次输入会反复问交集高度，日志本身不能变成负担。
static volatile int AevonKbInterNotes = 0;
static volatile int AevonKbBoundsNotes = 0;
static volatile int AevonKbWinNotes = 0;
static volatile int AevonKbShellNotes = 0;

// ===========================================================================
// 全局状态 —— 与母版 `0xc320..0xc3b8` 一一对应（地址写在注释里，便于回查）
// ===========================================================================

/// 0xc320 `_heightFraction`，初值 1.0。`_updateHeightFraction`（0x4a00）读
/// `com.nx.stheno.plist` 的 `HeightFraction`；Aevon 读自己域里的同名键。
static double AevonKbHeightFraction = 1.0;

/// 0xc3b8 `_bundleId`。
static NSString *AevonKbBundleId = nil;

/// 0xc3a8 `_injectApp`。母版读 plist 的 `Inject`（缺省 YES）。
/// Aevon 的等价物是下面那个「接管开没开」的开关。
static BOOL AevonKbInjectApp = NO;

/// 0xc3a9 `_init169`。
///
/// ⛔ 名字是作者自己的缩写，**不是**「iPhone X 判定**」。反汇编说得清楚
/// （`_updateInit169` @0x4968）：
///
///   ldr  x0,[0xc328]   ; _one = 1
///   tst  x0, x8, lsl #31
///   cset w8, ne
///   strb w8,[0xc3a9]
///
/// 它测的是 `SettingMask` 的**第 31 位**，也就是「键盘接管这个功能开没开」。
/// （我上一版逆向笔记把它写成「169 ≈ 16:9 高度比」，是错的，已在此更正。）
/// Aevon 的同一件事是偏好里的 `!ring.keyboardNative`（缺省开），由设置面板那
/// 一个开关写。
static BOOL AevonKbTakeOver = NO;

/// 0xc338 `_hookUIScreen`。**同寿命刷新源**：由 `0x5430`（FBSWorkspaceScenesClient
/// 的 settings 回调）每次重算 —— 这正是母版能一直正确的原因，它不是一次性开关。
/// 建键盘窗那一拍它被临时清 0（`0x5230`），为了读到**真**屏幕 bounds。
static BOOL AevonKbHookUIScreen = NO;

/// 0.4.11 — 建键盘窗那一拍的冻结计数器（>0 时 `UIScreen -bounds` 一律返回系统值）。
/// 理由见 `AevonKbBounds` 与 `AevonKbRemoteWindow` 里的注释：Aevon 比母版多一个
/// 写 `AevonKbHookUIScreen` 的线程（band 的 Darwin 通知），必须挡住。
static volatile int AevonKbWinFreeze = 0;

/// 0xc3b0 `_appScene`。缓存承载面那个 `UIWindowScene`。
///
/// 母版是 strong（`0x54f4` 取到之后存进全局槽，覆盖时 release 旧值）。这里同样
/// 用 strong —— 用 `__unsafe_unretained` 在 scene 被销毁后会变成野指针，而这条
/// 路径正好是「App 关掉又打开」时最容易踩到的。
static UIWindowScene *AevonKbAppScene = nil;

/// 0xc378 / 0xc380 / 0xc388 / 0xc390 —— 四条原件槽。
static CGFloat (*AevonKbOrigIntersection)(id, SEL, id, BOOL *, BOOL) = NULL;
static id      (*AevonKbOrigRemoteWindow)(id, SEL, UIScreen *, BOOL) = NULL;
static void    (*AevonKbOrigSceneSettings)(id, SEL, id, id, id, id) = NULL;
static CGRect  (*AevonKbOrigBounds)(id, SEL) = NULL;

// ===========================================================================
// 跨文件事实：本 App 现在是不是被卡片托着
// ===========================================================================

/// `AevonAppHook.m` 里 `AevonBandOn` 是本文件的 static，跨文件只能走 C 符号。
extern int AevonBandHostedNow(void);

/// 母版把「屏幕最前面那个 App」写在 `/tmp/stheno_frontmost.json`（Orion 写），
/// 由 `_upadteFrontMost`（0x45f4）读进 `_frontMost`（0xc330）。
///
/// Aevon 没有那个文件，但同一件事实有另一个来源：宿主推过来的卡片几何
/// （`AevonBandOn`）。两者是同一件事的两面：
///
///   · 被卡片托着 ⇒ 这个 App 不是屏幕上最前的那一个 ⇒ 母版会读到别人的 bundleId
///   · 没被托着   ⇒ 它就是全屏前台                  ⇒ 母版会读到它自己的
///
/// 所以 `[_frontMost isEqualToString:_bundleId]` 在 Aevon 里精确等于
/// `!AevonBandHostedNow()`。这不是简化语义，是同一个判断的另一个取数口 ——
/// 母版取「别人是谁」，我们取「我是不是被托着」，两者互补且都只有两个取值。
static BOOL AevonKbIsFrontMost(void) {
    return AevonBandHostedNow() == 0;
}

/// 0.4.7 — `_hookUIScreen` 的第二个刷新源。
///
/// 母版只有 `0x5430`（scene settings 回调）一个常规刷新源，因为它的 `_frontMost`
/// 来自 `/tmp/stheno_frontmost.json`，那个文件由 Orion 在激活 App 的同一拍写下 ——
/// 时序天然对齐，settings 回调到的时候文件里已经是新值。
///
/// Aevon 的事实源是 `AevonBandOn`，它由宿主一条 Darwin 通知写进来，**不经过
/// scene settings**。所以除了 `0x5430` 那一条，还要在 band 真正翻转时补一次 ——
/// 否则「卡片刚建好、settings 还没更新」那一小段里 `_hookUIScreen` 是旧值，
/// `UIScreen.bounds` 会晚一拍才换成承载面尺寸。
///
/// 这不是新增机制：它写的是母版同一个变量、用的是母版同一个表达式
/// （`![_frontMost isEqualToString:_bundleId]`），只是把「什么时候重算」扩到
/// Aevon 的事实源变更点。

/// 0.4.9 — 懒读闸门（只读一次）。
///
/// 0.4.8 在构造函数里直接 `CFPreferencesCopyAppValue`。那是 `main()` 之前、
/// 主线程上的一次 cfprefsd XPC —— 与「构造期提前 realize UIKit 私有类」是同一类
/// 风险。Aevon(293) 的 90 条 `app: hang` 里 `gap=-1ms` 说明主线程心跳一拍未跑，
/// 构造函数没回来。
///
/// 现在读盘推迟到「第一次真的需要这个值时」：要么 scene settings 回调
/// （`AevonKbUpdateTakeOver`），要么 band 翻转（本函数）。两处都只读一次，
/// 读到的仍是同一个值，行为不变。
static volatile int AevonKbShellRead = 0;

/// 0.4.10 — 安装状态。母版 `_ringAppsContains` 那个位置换成了「这个 App 真的被
/// 托管了吗」，三个状态位：
///   · `AevonKbInstalled` 做过决定了（装成功、开关关掉、springboard 跳过，都算）；
///   · `AevonKbArmed`     已经排了 0.15 s 那一拍，别重复排；
///   · `AevonKbVerdictNotes` 证词预算。
///
/// 为什么要「排一拍再装」而不是收到 band 立刻装：band 通知的回调不保证在主线程，
/// 而装钩子会 `NSClassFromString` 到 UIKit 私有类并改 IMP —— 必须在主队列上、
/// 且在 App 已经跑起来的正常状态里做（理由见文首 0.4.9 那一段）。
static volatile int AevonKbInstalled = 0;
static volatile int AevonKbArmed = 0;
static volatile int AevonKbVerdictNotes = 0;

/// 定义在下面「配置读取」一节；这里只要一份声明（懒读要用它）。
static BOOL AevonKbBridgeEnabled(void);

/// 0.4.10 — 唯一安装入口（下面「安装闸门」一节）。`AevonKbRefreshShell` 先用到它。
void AevonKbEnsureInstalled(void);

void AevonKbRefreshShell(void) {
    // 0.4.10 — 还没装：这里只回答「现在该不该装」，**不读盘**。
    // 构造函数那一拍就会走这一支（`AevonBandObserve` 的首次读值），
    // 所以它必须保持是一次纯内存判断。
    if (!AevonKbInstalled) {
        AevonKbEnsureInstalled();
        return;
    }
    if (!AevonKbShellRead) {
        AevonKbShellRead = 1;
        AevonKbInjectApp = AevonKbBridgeEnabled();
        AevonKbTakeOver = AevonKbInjectApp;
        // 母版 `0x4f78` 那个分支的等价证词：开关关着 ⇒ 四条钩子体全部透传。
        if (!AevonKbInjectApp) AevonKbLog("app: kb: native off, inject=0\n");
    }
    if (!AevonKbTakeOver) return;
    AevonKbHookUIScreen = !AevonKbIsFrontMost();
}

// ===========================================================================
// 配置读取（母版 `_updateInit169` / `_updateHeightFraction`）
// ===========================================================================

static CFStringRef const AevonKbDomain = CFSTR("com.aevon");

/// 母版 `_inject` + `SettingMask` bit31 的合并版：Aevon 用一个开关表达同一件事。
/// 缺省开 —— 它和卡片是一体的功能：关掉它，悬浮窗里的键盘就退回「只露一条工具栏」。
static BOOL AevonKbBridgeEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("!ring.keyboardNative"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? YES : NO;
        }
        CFRelease(value);
    }
    return on;
}

/// 母版 `_ringAppsContains` 的位置 —— 0.4.10 换成「这个 App 真的被托管了吗」。
/// 状态位与理由写在上面 `AevonKbRefreshShell` 之前那一节，这里只剩下机制。

static void AevonKbNativeInstall(void);

static void AevonKbInstallTick(void *context) {
    (void)context;
    AevonKbArmed = 0;
    if (AevonKbInstalled) return;
    // 排队的这 0.15 s 里卡片被关了 / 又被收回去 ⇒ 不装。下一次宿主开口再排。
    if (AevonBandHostedNow() == 0) {
        if (AevonKbVerdictNotes < 4) {
            AevonKbVerdictNotes += 1;
            AevonKbLog("app: kb: install drop, nothosted\n");
        }
        return;
    }
    AevonKbNativeInstall();
}

/// 唯一的安装入口。宿主每翻一次 band 都会走到这里（`AevonKbRefreshShell`），
/// 构造函数那一拍也会（`AevonBandObserve` 的首次读值）。
void AevonKbEnsureInstalled(void) {
    if (AevonKbInstalled || AevonKbArmed) return;
    if (AevonBandHostedNow() == 0) return;
    AevonKbArmed = 1;
    AevonKbLog("app: kb: install armed (hosted)\n");
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonKbInstallTick);
}

/// 母版 `_updateHeightFraction`（0x4a00）：先把 1.0 写回去，再读 plist 覆盖。
/// `HeightFraction` 的语义是「键盘高度占屏高的比例」，1.0 = 不缩放。
static void AevonKbUpdateHeightFraction(void) {
    AevonKbHeightFraction = 1.0;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("HeightFraction"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = 0.0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number)) {
                if (number > 0.0 && number < 8.0) AevonKbHeightFraction = number;
            }
        }
        CFRelease(value);
    }
}

/// 母版 `_updateInit169` + `_upadteFrontMost` 的合并入口，由 `0x5430` 每次调用。
///
/// ⛔ 与母版的唯一差别：**加 0.5 s 节流**。
///
/// 母版每收到一次 scene settings 更新就读一次 plist 文件。Aevon 不能照抄这一点：
/// 我们自己就会改 scene settings（`AevonWriteFrame` → `updateSettings:`），那些
/// 提交会再触发这个回调 —— 不节流就是「改 settings → 回调 → 读盘 → 再改」的自激。
/// 节流只减少读取次数，读到的仍是同一个值，行为不变。
static void AevonKbUpdateTakeOver(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last > 0 && now - last < 0.5) return;
    last = now;
    AevonKbInjectApp = AevonKbBridgeEnabled();
    AevonKbTakeOver = AevonKbInjectApp;
    // 已经在这里读过一次，`AevonKbRefreshShell` 不必再读（0.4.9）。
    AevonKbShellRead = 1;
}

// ===========================================================================
// `_mainScene`（母版 0x4bf8）
// ===========================================================================
//
// 反汇编语义：
//   for (scene in [UIApplication sharedApplication].connectedScenes) {
//       if (![scene isKindOfClass:[UIWindowScene class]]) continue;
//       if ([scene activationState] != 0) continue;        // 0 = foregroundActive
//       for (window in [scene windows]) if ([window isKeyWindow]) return scene;
//   }
//   return nil;
static UIWindowScene *AevonKbMainScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return nil;
    for (id object in [app connectedScenes]) {
        if (![object isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *scene = (UIWindowScene *)object;
        if ([scene activationState] != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in [scene windows]) {
            if ([window isKeyWindow]) return scene;
        }
    }
    return nil;
}

/// `-[UIWindowScene _boundsForInterfaceOrientation:]` —— 私有。返回承载面的矩形
/// （宿主把 scene frame 摆成 430×717@0,215 时，这里就是 430×717）。
typedef CGRect (*AevonKbBoundsForOrientationIMP)(id, SEL, long);

static CGRect AevonKbSceneBounds(UIWindowScene *scene) {
    if (scene == nil) return CGRectZero;
    SEL sel = NSSelectorFromString(@"_boundsForInterfaceOrientation:");
    if (sel == NULL || ![scene respondsToSelector:sel]) return CGRectZero;
    AevonKbBoundsForOrientationIMP fn =
        (AevonKbBoundsForOrientationIMP)[scene methodForSelector:sel];
    if (fn == NULL) return CGRectZero;
    return fn(scene, sel, (long)[scene interfaceOrientation]);
}

// ===========================================================================
// 钩子 4：`-[UIScreen bounds]`（母版 0x54f4，156 B）
// ===========================================================================
//
// ⛔ 这是 Aevon 历史上最危险的一条：0.0.65 / 0.0.67 两次装它都换来「App 打不开、
// 桌面黑屏、小组件空白」，0.1.42 又试一次仍然黑屏。三次事故的共同点是**在没有
// 承载面的时候也改写**，以及**写了存储**。
//
// 母版这一版是安全的，原因有三条，缺一条都不行：
//   ① 它**只换返回值**，不写 `UIScreen` 的任何 ivar（`bounds` 是计算属性，
//      `_boundsForInterfaceOrientation:` 也只是读）；
//   ② 两道闸同时成立才动：`_init169`（功能位）与 `_hookUIScreen`（本 App 不是
//      前台最前）。`_hookUIScreen` 由 settings 回调刷新，不是一次性开关；
//   ③ 拿不到承载 scene 就**原样返回系统值**（`if (_appScene)`）。
//
// Aevon 照抄三条，一个都不省。另外这个文件只编进 `AevonApp.dylib`（App 进程），
// 而 `AevonApp.plist` 的 Filter 排除了 SpringBoard —— 桌面进程里根本没有这条代码。
static CGRect AevonKbBounds(id self, SEL _cmd) {
    // 0.4.11 — `AevonKbWinFreeze`：建键盘窗那一拍**必须**读到真屏高度。
    //
    // 母版只写 `_hookUIScreen = 0` 就够了，因为它有两个前提：
    //   ① `_upadteFrontMost` 只在 `0x5430`（scene settings 回调）里跑，与建窗同一线程；
    //   ② 没有第二个写 `_hookUIScreen` 的地方。
    // Aevon 多了一个写者：band 的 Darwin 通知回调（不保证主线程）。宿主在**键盘弹起
    // 那一拍**正好会发 band（日志里 `win: band report 430x717 at 0,215` 就在
    // `keyboard native on` 旁边），于是它可以在 `_hookUIScreen = 0` 与 `[main bounds]`
    // 之间把这面旗子翻回 1 ⇒ 读到的是承载面的 717 ⇒ 键盘窗按 717 建 ⇒ 键盘的「底」
    // 落在屏幕 y=717 而不是 932 ⇒ 悬空 215 pt、下方一条白（Aevon(295) 的形状）。
    //
    // 冻结计数器把这一拍变成原子的：期间无论谁来写旗子，本函数都按「关」处理。
    if (AevonKbWinFreeze == 0 && AevonKbTakeOver && AevonKbHookUIScreen) {
        if (AevonKbAppScene == nil) {
            AevonKbAppScene = AevonKbMainScene();
        }
        if (AevonKbAppScene != nil) {
            CGRect box = AevonKbSceneBounds(AevonKbAppScene);
            if (!CGRectIsEmpty(box)) {
                if (AevonKbBoundsNotes < 6) {
                    AevonKbBoundsNotes += 1;
                    char line[192];
                    snprintf(line, sizeof(line),
                             "app: kb: bounds -> %.0fx%.0f (hosted=%d)\n",
                             box.size.width, box.size.height,
                             1 - (int)AevonKbIsFrontMost());
                    AevonKbLog(line);
                }
                return box;
            }
        }
    }
    if (AevonKbOrigBounds != NULL) return AevonKbOrigBounds(self, _cmd);
    return CGRectZero;
}

// ===========================================================================
// 钩子 1：`-[_UIRemoteKeyboards intersectionHeightForWindowScene:
//             isLocalMinimumHeightOut:ignoreHorizontalOffset:]`（母版 0x5128，264 B）
// ===========================================================================
//
// 反汇编逐条（0x5128..0x5208）：
//
//   orig = orig_impl(self, _cmd, scene, out, ignore)      ; d8 = d9 = d0
//   sameApp = [_frontMost isEqualToString:_bundleId]
//   kbWin   = [self keyboardWindow]
//   if (sameApp || !kbWin) return orig                    ; 分支到 0x520c 时 d9 仍是 orig
//   _updateHeightFraction()
//   if ([scene interfaceOrientation] != 1) return 0        ; d9 在这里才被清零
//   screenH = [UIScreen mainScreen].bounds.size.height     ; 注意：此刻 bounds **已被钩**
//   kbH     = [kbWin frame].size.height
//   return (orig * screenH / kbH) * _heightFraction + kbH - screenH
//
// 指令对应：0x51f4 `fmul d0,d8,d9` / 0x51f8 `fdiv d0,d0,d3` /
//           0x5204 `fmadd d0,d0,d1,d3` / 0x5208 `fsub d9,d0,d9`。
//
// 这条钩子的输入量里有一件容易看漏的事：`screenH` 读的是**钩过的** `UIScreen.bounds`
// （717），而 `kbH` 读的是键盘窗 frame（932，由 0x5230 在建窗时纠正过）。
// 两个数不同源 —— 公式正是为这个差而存在的。照抄，不要「统一」它们。
static CGFloat AevonKbIntersection(id self, SEL _cmd, id scene, BOOL *isLocal, BOOL ignore) {
    CGFloat orig = 0.0;
    if (AevonKbOrigIntersection != NULL) {
        orig = AevonKbOrigIntersection(self, _cmd, scene, isLocal, ignore);
    }
    BOOL sameApp = AevonKbIsFrontMost();
    id keyboardWindow = ((id (*)(id, SEL))objc_msgSend)(self,
                                                       NSSelectorFromString(@"keyboardWindow"));
    if (sameApp || keyboardWindow == nil) return orig;

    AevonKbUpdateHeightFraction();
    long orientation = ((long (*)(id, SEL))objc_msgSend)(scene,
                                                        @selector(interfaceOrientation));
    if (orientation != 1) return 0.0;

    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(keyboardWindow, @selector(frame));
    CGFloat keyboardHeight = frame.size.height;
    if (keyboardHeight < 1.0 || screenHeight < 1.0) return orig;

    CGFloat answer = (orig * screenHeight / keyboardHeight) * (CGFloat)AevonKbHeightFraction
                   + keyboardHeight - screenHeight;

    if (AevonKbInterNotes < 10) {
        AevonKbInterNotes += 1;
        char line[224];
        snprintf(line, sizeof(line),
                 "app: kb: inter orig=%.0f screen=%.0f kb=%.0f hf=%.2f -> %.0f\n",
                 orig, screenHeight, keyboardHeight, AevonKbHeightFraction, answer);
        AevonKbLog(line);
    }
    return answer;
}

// ===========================================================================
// 钩子 2：`+[UIRemoteKeyboardWindow remoteKeyboardWindowForScreen:create:]`
//         （母版 0x5230，512 B）
// ===========================================================================
//
//   win = orig_impl(cls, _cmd, screen, create)
//   if (!win) return nil
//   root = [win rootViewController]
//   _hookUIScreen = 0                        ← 先关自己的 bounds 钩子，读真值
//   main = [UIScreen mainScreen]
//   if (sameApp) {
//       [win setFrame:[main bounds]]; [win setBounds:[win frame]]; scale = (1,1)
//   } else if (_appScene.interfaceOrientation == 1) {
//       H = [main bounds].size.height
//       [win setFrame:(x, y, w, H)]; [win setBounds:[win frame]]; scale = (1,1)
//   } else {
//       H = [main bounds].size.height; W = [main bounds].size.width
//       [win setFrame:(-0.5H + 0.5W, 0, H, H)]; [win setBounds:(0,0,H,H)]; scale = (0,0)
//   }
//   [root.view setTransform:scale]
//   _hookUIScreen = 1
//   return win
//
// 要点（别自作聪明去「优化」）：
//   · **只在建窗这一拍**写几何。之后键盘位置由系统自己摆，母版不介入。
//   · 竖屏两条分支的差别只有一样：sameApp 用原 bounds 的四个分量，非 sameApp
//     保留 x/y/w、只把高改成 H。二者在真屏上等价 —— 它就是「确保键盘窗是真屏尺寸」。
//   · 横屏把内容 scale 到 0（不显示）。这是母版的选择，不是 bug。
static id AevonKbRemoteWindow(id self, SEL _cmd, UIScreen *screen, BOOL create) {
    id window = nil;
    if (AevonKbOrigRemoteWindow != NULL) {
        window = AevonKbOrigRemoteWindow(self, _cmd, screen, create);
    }
    if (window == nil) return nil;

    UIViewController *root = ((id (*)(id, SEL))objc_msgSend)(window,
                                                            @selector(rootViewController));
    // 母版在这里直接读 `_appScene`。它由 `0x54f4`（bounds 钩子）懒填充，正常情况
    // 下早就不是 nil 了；但「建键盘窗」这一拍如果恰好还没问过 `bounds`（后台 App
    // 第一次被托起来、或者 scene 刚换过），`_appScene` 会是 nil ⇒ 走进下面那个
    // 横屏分支 ⇒ `setTransform:` scale 到 0 ⇒ **键盘整块不显示**。
    //
    // 这里只是把母版在 `0x54f4` 里做的那件事提前做一次（同一个 `_mainScene`），
    // 不是新机制。取不到仍然保持 nil，走母版原路。
    if (AevonKbAppScene == nil) {
        AevonKbAppScene = AevonKbMainScene();
    }
    // 0.4.11 — 冻结 + 关旗子，两个一起。冻结挡住并发写者（band 通知线程、scene
    // settings 回调），关旗子是母版原作者的动作。只关旗子不冻结 ⇒ Aevon(295) 的
    // `win frame=430x717@0,0`：读到的是承载面高，键盘窗按承载面建，键盘的「底」
    // 落在屏幕 y=717 而不是 932 ⇒ 悬空 215 pt、下方一条白。
    AevonKbWinFreeze += 1;
    AevonKbHookUIScreen = NO;
    UIScreen *main = [UIScreen mainScreen];
    CGAffineTransform scale = CGAffineTransformMakeScale(1, 1);

    CGRect box = [main bounds];          // 冻结态 ⇒ 一定是**系统值**
    CGFloat readH = box.size.height;
    // 兜底：若这一读仍等于承载面高（说明有别的钩子/系统把 bounds 压成了场景尺寸），
    // 就用物理屏高（`nativeBounds / nativeScale` = 430×932）。母版这一拍的目的就是
    // 「拿到真屏高度给键盘窗」，物理屏高就是那个数的定义本身。
    CGRect native = [main nativeBounds];
    CGFloat nativeScale = [main nativeScale];
    CGFloat physicalH = nativeScale > 0.0 ? native.size.height / nativeScale : readH;
    int fallback = 0;
    if (physicalH > readH + 1.0) {
        readH = physicalH;
        fallback = 1;
    }
    CGFloat height = readH;
    CGFloat width = box.size.width;

    CGRect asked = CGRectZero;
    if (AevonKbIsFrontMost()
        || (AevonKbAppScene != nil && [AevonKbAppScene interfaceOrientation] == 1)) {
        // 竖屏两条分支（母版 0x5230 的 0x5280 / 0x52d8）：窗口 = 真屏尺寸。
        asked = CGRectMake(box.origin.x, box.origin.y, width, height);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setFrame:), asked);
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setBounds:), now);
    } else {
        // 横屏：母版把内容 scale 到 0（不显示）。
        asked = CGRectMake(-0.5 * height + 0.5 * width, 0.0, height, height);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setFrame:), asked);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setBounds:),
                                                 CGRectMake(0, 0, height, height));
        scale = CGAffineTransformMakeScale(0, 0);
    }

    if (root != nil) {
        UIView *view = [root view];
        if (view != nil) {
            ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(view,
                                                                @selector(setTransform:),
                                                                scale);
        }
    }
    AevonKbWinFreeze -= 1;
    AevonKbHookUIScreen = YES;

    if (AevonKbWinNotes < 6) {
        AevonKbWinNotes += 1;
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
        char line[224];
        snprintf(line, sizeof(line),
                 "app: kb: win frame=%.0fx%.0f@%.0f,%.0f scale=%.1f hosted=%d\n",
                 now.size.width, now.size.height, now.origin.x, now.origin.y,
                 scale.a, 1 - (int)AevonKbIsFrontMost());
        AevonKbLog(line);
        // 0.4.11 — 三个数分开写，下一份日志能直接指出是哪一环断的：
        //   ask  我们要求窗口多大（= 真屏高，母版语义）
        //   real 冻结后读到的屏高 / fallback 为 1 说明读到的是场景尺寸
        //   frame 系统最终给窗口多大（比 ask 小 ⇒ 窗口被场景夹住了，问题不在公式）
        snprintf(line, sizeof(line),
                 "app: kb: win ask=%.0fx%.0f real=%.0fx%.0f frame=%.0fx%.0f fb=%d\n",
                 asked.size.width, asked.size.height, width, height,
                 now.size.width, now.size.height, fallback);
        AevonKbLog(line);
    }
    return window;
}

// ===========================================================================
// 钩子 3：`-[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:
//             transitionContext:completion:]`（母版 0x5430，196 B）
// ===========================================================================
//
//   _updateInit169();
//   _upadteFrontMost();
//   _hookUIScreen = ![_frontMost isEqualToString:_bundleId];
//   return orig_impl(...);
//
// 它是 `_hookUIScreen` 的**常规刷新源**。母版真正的功力在这一条：开关不是装钩子
// 时算一次，而是每次 scene settings 变化都重算 —— 「同寿命刷新源」，所以它永远
// 跟得上「这个 App 现在是不是被浮起来的」。
static void AevonKbSceneSettings(id self, SEL _cmd, id sceneID, id diff,
                                 id transitionContext, id completion) {
    AevonKbUpdateTakeOver();
    AevonKbHookUIScreen = !AevonKbIsFrontMost();
    if (AevonKbShellNotes < 6) {
        AevonKbShellNotes += 1;
        char line[160];
        snprintf(line, sizeof(line), "app: kb: shell hook=%d takeOver=%d\n",
                 (int)AevonKbHookUIScreen, (int)AevonKbTakeOver);
        AevonKbLog(line);
    }
    if (AevonKbOrigSceneSettings != NULL) {
        AevonKbOrigSceneSettings(self, _cmd, sceneID, diff, transitionContext, completion);
    }
}

// ===========================================================================
// 安装（母版 0x4f4c）
// ===========================================================================
//
// 母版顺序：bundleId → _inject → _ringAppsContains → 五条 addHook →
//           notify_register_dispatch → 状态初始化。
//
// Aevon 的第二道闸换成「宿主真的托起来了」（0.4.10，理由见文首）：调用点只有
// `AevonKbEnsureInstalled`，而它先看 `AevonBandHostedNow()`。所以进到本函数时
// 这个 App **已经**在卡片里，不必再判名单。

/// 装一条实例方法。返回**原件**（装不上返回 NULL）。
///
/// 用 `method_setImplementation` 的返回值取原件，而不是先 `method_getImplementation`
/// 再写 —— 后者在「同一进程里这条方法已经被别人换过」时拿到的是别人那一版，
/// 我们的 return 路径就会跳过它。母版用 Orion 的 `addHook` 拿原件，行为等价。
static IMP AevonKbInstallInstance(Class cls, SEL sel, IMP replacement) {
    if (cls == Nil || sel == NULL) return NULL;
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) return NULL;
    return method_setImplementation(method, replacement);
}

static IMP AevonKbInstallClass(Class cls, SEL sel, IMP replacement) {
    if (cls == Nil || sel == NULL) return NULL;
    Method method = class_getClassMethod(cls, sel);
    if (method == NULL) return NULL;
    return method_setImplementation(method, replacement);
}

static void AevonKbNativeInstall(void) {
    // 无论后面装成没装成，这一进程只做这一次决定。
    AevonKbInstalled = 1;
    AevonKbBundleId = [[[NSBundle mainBundle] bundleIdentifier] copy] ?: @"";
    // 母版 `_ringAppsContains` 的第一条就是排除 springboard（0x4f4c 的 0x4f9c
    // 分支）。AevonApp.dylib 的 Filter 是 `com.apple.UIKit`，它**也会**加载进
    // SpringBoard —— 进程内的 `AevonWorthInjecting()` 已经三重排除了那个进程，
    // 这里再挡一道：`UIScreen.bounds` 装进桌面的代价是整台机器黑屏，不值得
    // 只靠上游那一处判据。
    if ([AevonKbBundleId isEqualToString:@"com.apple.springboard"]) {
        AevonKbLog("app: kb: native skipped, springboard\n");
        return;
    }
    // 开关（母版 `_inject` + `SettingMask` bit31）。这里已经是主队列、App 跑起来
    // 之后了，读盘安全 —— 0.4.9 那条「构造期不读盘」的约束仍然成立：构造函数
    // 走的是 `AevonKbRefreshShell` 的 `!AevonKbInstalled` 那一支，纯内存判断。
    AevonKbInjectApp = AevonKbBridgeEnabled();
    AevonKbTakeOver = AevonKbInjectApp;
    AevonKbShellRead = 1;
    if (!AevonKbInjectApp) {
        AevonKbLog("app: kb: native off, inject=0\n");
        return;
    }
    // 装钩子这一拍按当前事实算一次，与母版 `0x5050` 的
    // `_hookUIScreen = ![_frontMost isEqualToString:_bundleId]` 同一表达式。
    // 走到这一拍 band 必然是「托着」（`AevonKbEnsureInstalled` 的闸），所以这里是
    // 真值 ⇒ 装上就立刻接管，不用等下一次 settings 回调。之后由
    // `AevonKbSceneSettings` 与 `AevonKbRefreshShell` 持续校正。
    AevonKbHookUIScreen = !AevonKbIsFrontMost();

    int installed = 0;
    int mask = 0;

    Class keyboards = NSClassFromString(@"_UIRemoteKeyboards");
    SEL intersectionSel = NSSelectorFromString(@"intersectionHeightForWindowScene:"
                                               @"isLocalMinimumHeightOut:"
                                               @"ignoreHorizontalOffset:");
    IMP oldIntersection = AevonKbInstallInstance(keyboards, intersectionSel,
                                                 (IMP)AevonKbIntersection);
    if (oldIntersection != NULL) {
        AevonKbOrigIntersection = (CGFloat (*)(id, SEL, id, BOOL *, BOOL))oldIntersection;
        installed += 1;
        mask |= 1 << 0;
    }

    Class keyboardWindow = NSClassFromString(@"UIRemoteKeyboardWindow");
    SEL remoteWindowSel = NSSelectorFromString(@"remoteKeyboardWindowForScreen:create:");
    IMP oldRemote = AevonKbInstallClass(keyboardWindow, remoteWindowSel,
                                        (IMP)AevonKbRemoteWindow);
    if (oldRemote != NULL) {
        AevonKbOrigRemoteWindow = (id (*)(id, SEL, UIScreen *, BOOL))oldRemote;
        installed += 1;
        mask |= 1 << 1;
    }

    Class scenesClient = NSClassFromString(@"FBSWorkspaceScenesClient");
    SEL settingsSel = NSSelectorFromString(@"sceneID:updateWithSettingsDiff:"
                                           @"transitionContext:completion:");
    IMP oldSettings = AevonKbInstallInstance(scenesClient, settingsSel,
                                             (IMP)AevonKbSceneSettings);
    if (oldSettings != NULL) {
        AevonKbOrigSceneSettings = (void (*)(id, SEL, id, id, id, id))oldSettings;
        installed += 1;
        mask |= 1 << 2;
    }

    IMP oldBounds = AevonKbInstallInstance([UIScreen class], @selector(bounds),
                                           (IMP)AevonKbBounds);
    if (oldBounds != NULL) {
        AevonKbOrigBounds = (CGRect (*)(id, SEL))oldBounds;
        installed += 1;
        mask |= 1 << 3;
    }

    char line[192];
    snprintf(line, sizeof(line), "app: kb: native on installed=%d mask=0x%x bundle=%s\n",
             installed, mask, [AevonKbBundleId UTF8String] ?: "?");
    AevonKbLog(line);
}
