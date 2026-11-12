// ===========================================================================
// AevonKeyboardNative.m — 0.4.7 / 0.4.9 / 0.4.10 / 0.4.12 / 0.4.13 / 0.4.14 / 0.4.17
//
// 键盘的承载面接管。**1:1 复刻 Stheno 母版的 `SthenoKeyboard.dylib`**
// （0.1.23；修复版 final.3 的键盘组件与母版只差 1 处：`0x4de8` 那个「首启打开
// inject.stheno.com」的函数被改成 `ret`，与键盘机制无关）。
//
// 逆向数据：`stheno-逆向分析/final3/analysis/hooks-SthenoKeyboard.md`
//           `stheno-逆向分析/final3/analysis/disasm-SthenoKeyboard-s0.txt`
//
// ---------------------------------------------------------------------------
// 0.4.17 — 交集返回值改用「量出来的键盘占高」（Aevon(301)）
// ---------------------------------------------------------------------------
// 300/301 两版取证把四个钩子全部洗清了：
//   · `bounds sys=430x717` ⇒ `-bounds` 钩子是空操作（系统原值就等于我们返回的值）；
//   · scene 落点 215 补写成功（`frame drift` 收起时反向）；
//   · 键盘窗 717、root 717、`content`(=`_UIScenePresentationView`) 717 摆在 card 0,0，
//     card 在 215 —— 宿主侧与 App 侧数字完全自洽。
// 唯一对不上的量是**键盘自己**：`orig` 报 316，`UIInputSetHostView` 实占 431。
// 详见本文件 0.4.17 那一段的推导。本版只改这一处返回值，几何一行未动。
//
// ---------------------------------------------------------------------------
// 0.4.14 — 删掉我自己发明的 215 pt「窗下移」（Aevon(298)）
// ---------------------------------------------------------------------------
// 症状与 297 一模一样：键盘只露上半截、下半透明且点不到。
//
// 0.4.13 已经把 `bounds.origin` 归零（298 读数 `bnd=0,0 root=430x717@0,0` 证明
// 那一步真的生效了），症状不变 ⇒ 平移/裁切不在 bounds，而在**窗本身被我们挪了**。
// 298 的第一条读数就是铁证：
//
//   app: kb: win orig=430x717@0,0 … ask=430x717@0,215 frame=430x717@0,215 dy=1
//
// 系统把键盘窗建在 (0,0,430,717) —— **它本来就是对的**：窗底 = 承载面底 = 卡片底
// = 屏幕底 932。`dy=1` 是我在 0.4.12 加的「补偿」：看到原点在 0 就往下搬 215。窗里
// 的键盘视图按**窗底**摆，窗往下搬 215 ⇒ 键盘整个跟着下移 215 ⇒ 越过卡片下沿的
// 215 pt 被裁掉、也点不到。
//
// 母版从来没搬过窗：`0x5230` 竖屏两条分支都是 `setFrame:[UIScreen mainScreen].bounds`
// 一个分量都不改。本版回到那一句。⛔ 纪律：**补偿只能来自母版，不能来自「我觉得
// 应该对齐」** —— 这是第三次在同一个函数里调参数（0.4.10 拽窗顶、0.4.11 改窗高、
// 0.4.12 搬窗底），三次同一个形状。
//
// 同时加一份**只读**取证（`app: kb: tree …`）：若还有一层内部裁切，下一份日志能
// 直接指认是谁，不必再从截图反推。
//
// ---------------------------------------------------------------------------
// 0.4.13 — `setBounds:` 不能带 origin（Aevon(297)）—— **结论仍成立，但不充分**
// ---------------------------------------------------------------------------
// 症状：输入框已经正常（0.4.12 的恒等公式生效），但键盘只显示上半部分、下半透明
// 且无法触摸。
//
// 当时的判断：母版写 `[win setBounds:[win frame]]`，那行能成立是因为母版那一拍
// frame 原点恒为 (0,0) ⇒ bounds.origin 也是 0，等于「只改尺寸」。0.4.12 把窗原点
// 挪到 y=215 之后照抄这一行，bounds.origin 就成了 (0,215) —— 它是**内容坐标系**的
// 偏移，会把窗内所有内容整体上移 215。
//
// 这一条本身没错（bounds.origin 非 0 一定有害），但它不是 297 的全部原因：298 的
// 读数 `bnd=0,0 root=430x717@0,0` 证明归零已经生效，症状却一模一样 ⇒ 真正那一层
// 是 0.4.12 加的「把窗往下搬 215」，见文首 0.4.14 段。
// ⛔ 纪律：**照抄母版的一行语句之前，先确认它依赖的前提（这里是 frame.origin=0）
// 在我们这里也成立。** 归零这一条保留，它是母版语义，不是补偿。
//
// ---------------------------------------------------------------------------
// 0.4.12 — 键盘窗按**承载面高**建（Aevon(296)）—— 高度结论保留，x/y 结论已废
// ---------------------------------------------------------------------------
// 症状：键盘贴到屏幕底了，但只露出上面一截，下半面透明；输入框被抬高。
//
// 截图硬测量（885x1920，932/1920 = 0.4854 pt/px）：
//   卡片顶边 215.0 pt（= `band report 430x717 at 0,215`，精确吻合）
//   键盘内容顶边 573.0 pt（= 932 − 359，**位置已经对了**）
//   键盘在 **717.0 pt 被一条水平线硬切**，717.9 起全宽 #F1F1F1 到 932
// 717 正是 `UIScreen.bounds` 钩后的返回值（承载面高）。
//
// ✅ 仍成立的部分：`H` 必须取**承载面高 717**（不是物理屏高 932），所以
//    `kbH(717) == screenH(717)` ⇒ intersection 公式退化成恒等 = 真值 ⇒ 输入框
//    落回键盘上沿（297 起用户确认输入框正常）。这一条一直有效。
// ⛔ 已废的部分：把窗写到 (0,215,430,717)。母版竖屏分支的 x/y 取自
//    `[UIScreen mainScreen].bounds`，在 Aevon 里就是 (0,0) —— 见 0.4.14。
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
// 0.4.15 — 系统原值只打一次（`-bounds` 没被我们接手的那个数）。配额 1，不刷屏。
static volatile int AevonKbSysNotes = 0;
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

/// 0.4.21 — 建键盘窗那一拍「读真值」的计数器（>0 时 `UIScreen -bounds` **一律返回
/// 系统值**，即物理屏 430x932）。
///
/// 这条方向在 0.4.11~0.4.20 之间被搞反过两次，两次的病根是同一个：我们把
/// `displayConfiguration` 改成了卡片尺寸，于是「系统值」本身只剩 717，只能靠
/// 把承载面喂给建窗来凑。0.4.21 把 display 还给系统之后，系统值就是真屏 932，
/// 母版那句 `_hookUIScreen = 0` 才恢复它本来的语义。
///
/// 仍然需要冻结：band 的 Darwin 通知回调不保证主线程，能在读之前把旗子翻掉。
static volatile int AevonKbWinReal = 0;

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
///
/// ⛔ 0.4.12 — **Aevon 不读这个键，恒 1.0。**
///
/// 母版读的是自己域里的 `HeightFraction`，没有别人用这个名字；Aevon 的设置面板
/// 用的是同一个键名表达**浮窗首帧高度**（`gen-settings.py` 的「尺寸 / 高度」滑条，
/// 缺省 0.63）。照母版去读，用户一动那个滑条，键盘的 inset 就会被乘 0.63 —— 在
/// 0.4.12 的几何下（`kbH == screenH`，公式退化成恒等）那等于让键盘盖住输入条。
///
/// 1.0 就是母版的缺省值，所以行为与本条存在时完全一致；只是不再跟着滑条抖。
static void AevonKbUpdateHeightFraction(void) {
    AevonKbHeightFraction = 1.0;
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
    // 0.4.21 — 建键盘窗那一拍 `AevonKbWinReal > 0`：**读真值**。
    //
    // 这一条 0.4.12 曾反着写过（冻结期读承载面），当时的理由是「窗底要落在屏底
    // 932、root 又要 717，两根尺子只能统一成 717」。那个理由成立的前提是
    // `displayConfiguration` 已经被我们改成 717 —— 前提本身是错的，见
    // `AevonWriteDisplay` 里 0.4.21 那一段。display 还给系统之后，母版那句
    // `_hookUIScreen = 0`（读真屏）就是唯一的正确解：窗 932、root 932、
    // 键盘内容 501..932，全部落在真屏里。
    if (AevonKbWinReal > 0) {
        if (AevonKbOrigBounds != NULL) return AevonKbOrigBounds(self, _cmd);
        return CGRectZero;
    }
    if (AevonKbTakeOver && AevonKbHookUIScreen) {
        if (AevonKbAppScene == nil) {
            AevonKbAppScene = AevonKbMainScene();
        }
        if (AevonKbAppScene != nil) {
            CGRect box = AevonKbSceneBounds(AevonKbAppScene);
            if (!CGRectIsEmpty(box)) {
                // 0.4.15 — 系统原值只打一次：它回答「我们到底改掉了什么」。
                // `-bounds` 是计算属性，`AevonKbOrigBounds` 就是系统原实现，只读。
                // 与下面那行并排看：`sys` 的 origin 若也是 (0,0)，说明 215 这个偏移
                // 从头到尾不在 `UIScreen` 上，键盘贴 0..717 就是必然。
                if (AevonKbSysNotes == 0) {
                    AevonKbSysNotes = 1;
                    if (AevonKbOrigBounds != NULL) {
                        CGRect sysBox = AevonKbOrigBounds(self, _cmd);
                        char sline[224];
                        snprintf(sline, sizeof(sline),
                                 "app: kb: bounds sys=%.0fx%.0f@%.0f,%.0f (hook off)\n",
                                 sysBox.size.width, sysBox.size.height,
                                 sysBox.origin.x, sysBox.origin.y);
                        AevonKbLog(sline);
                    }
                }
                // 0.4.15 — origin 一起打。0.4.14 只打了尺寸，于是「App 认为屏幕从
                // 哪一点开始」这件事从来没被记录过 —— 而键盘窗是按 `-bounds` 摆的，
                // 若它的原点恒为 (0,0)，键盘就永远贴在 0..717，离屏底 215。
                if (AevonKbBoundsNotes < 6) {
                    AevonKbBoundsNotes += 1;
                    char line[224];
                    snprintf(line, sizeof(line),
                             "app: kb: bounds -> %.0fx%.0f@%.0f,%.0f (hosted=%d)\n",
                             box.size.width, box.size.height,
                             box.origin.x, box.origin.y,
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
// 0.4.17 — 键盘在这一块屏上的**真实占高**
// ===========================================================================
//
// 301 的现场（Preferences，键盘带 accessory）：
//
//   app: kb: inter orig=316 screen=717 kb=717 hf=1.00 -> 316      ← 公式给 316
//   app: kb: tree UIInputSetHostView f=0,286,430x431               ← 键盘真占 431
//   app: kb: tree   UIView           f=0,0,430x361                 ← 键区只有 361
//   app: kb: tree     UIKBInputBackdropView f=0,0,430x431          ← 背景 431 被父级裁到 361
//   app: kb: tree   UIKeyboardDockView      f=0,0,430x431          ← 底部 70 只剩按钮，没有背景
//
// 拿三份日志并排，缺口的量不固定，缺口的方向却永远是「公式 < 真实」或「公式 > 真实」
// 由 `kbH` 决定：
//
//   299 (0.4.14) 公式 316 / 真实 386 ⇒ 少 70   ⇒ 键盘盖住输入框
//   301 (0.4.16) 公式 316 / 真实 431 ⇒ 少 115  ⇒ 盖住 + 底部 70 透明
//   296 (0.4.11) 公式 458 / 真实 386 ⇒ 多 72   ⇒ 输入框被抬高
//
// ⚠ 这不是母版公式写错了，而是母版公式的**前提**在我们这里不成立：母版的 `orig`
// 与 `kbH` 同源（都来自物理 932 那个世界），所以 `(orig*S/W)+W−S` 那一段是它的
// 换算项；Aevon 从 0.2.46 起把 display 改成卡片尺寸，`screenH` 与 `kbH` 双双变成
// 717 ⇒ 公式恒等 ⇒ `orig` 被原样透传，可它仍然是 932 的口径（316）。
// 换句话说：**母版四个钩子到这个配置下已经数学恒等，坏的是喂进去的量。**
//
// 所以这里不再猜系数，只量一个客观量：键盘窗内部 `InputSetHostView` 的顶边。
//   footprint = screenH − (窗 frame.y + host 在窗内的 y)
// 窗底与屏底对齐时它等于 host 的高度；不对齐时它仍然是「键盘遮住了屏幕多少」。
// 只用公开的 view 接口（`subviews` / `convertRect:toView:` / `frame`），不调任何
// 私有选择子、不写任何几何 ⇒ 量错最多是数值不对，不会杀进程。
//
// ⛔ **0.4.23：上面那整段前提已经不成立，这个测量不再参与任何决策。**
// 0.4.21 把 display 还给系统之后 `kbH` 回到 932，母版公式重新成立，而且它量的是
// 「这一刻」的键盘 —— 键盘升起与候选条到达是两个时刻，用「此刻」的值去答一个
// 一次性的问句，就会漏掉后来那 45 pt。现在这里**只打日志**，inset 的唯一来源是
// 母版公式。保留它是因为日志里 `formula=` 与 `meas=` 并排能直接看出余量够不够；
// 哪天母版公式真的不够了，这份读数就是第一个证据，而不是又一轮猜系数。
static UIView *AevonKbFindHostView(UIView *root, int depth) {
    if (root == nil || depth < 0) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if (cls != nil && [cls rangeOfString:@"InputSetHost"].location != NSNotFound) {
        return root;
    }
    NSArray *subs = [root subviews];
    NSUInteger count = [subs count];
    for (NSUInteger i = 0; i < count && i < 8; i++) {
        UIView *found = AevonKbFindHostView([subs objectAtIndex:i], depth - 1);
        if (found != nil) return found;
    }
    return nil;
}

static CGFloat AevonKbMeasuredCoverage(id keyboardWindow, CGFloat screenHeight,
                                       CGFloat *outHostY, CGFloat *outHostH) {
    if (outHostY != NULL) *outHostY = 0.0;
    if (outHostH != NULL) *outHostH = 0.0;
    if (keyboardWindow == nil || ![keyboardWindow isKindOfClass:[UIView class]]) return 0.0;
    if (screenHeight < 1.0) return 0.0;
    UIView *win = (UIView *)keyboardWindow;
    UIView *host = AevonKbFindHostView(win, 3);
    if (host == nil) return 0.0;
    CGRect inWindow = [host convertRect:[host bounds] toView:win];
    if (outHostY != NULL) *outHostY = inWindow.origin.y;
    if (outHostH != NULL) *outHostH = inWindow.size.height;
    if (inWindow.size.height < 8.0) return 0.0;
    // 口径 = 「窗底到键盘顶」，**对窗的 origin 免疫**。
    //
    // 旧写法 `screenHeight − (win.y + host.y)` 默认「窗底 = App 世界底」，0.4.20 把窗
    // 挪到 215 之后这条就不成立了（会算出 216，而键盘实占 431）。
    // 现在的写法只依赖一条事实：**键盘窗的底边就是屏幕底边**。0.4.21 起窗是
    // `[main bounds]` = 物理屏 (0,0,430,932)，键盘内容贴窗底 501..932
    // ⇒ footprint = 932 − 501 = 431，与 scene 空间里的占高（717 − 286）同值。
    CGRect winFrame = [win frame];
    CGFloat footprint = winFrame.size.height - inWindow.origin.y;
    if (footprint < 8.0 || footprint > screenHeight + 1.0) return 0.0;
    return footprint;
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
// （717），而 `kbH` 读的是键盘窗 frame。母版里这两个数不同源（717 vs 932），公式正是
// 为这个差而存在的。
//
// ⛔ 0.4.17 起这个差在 Aevon 里**恒为 0**（display 被改成卡片尺寸后，键盘窗也是 717），
// 于是母版公式退化成恒等、`orig` 原样透传。301 已证 `orig` 是 932 那个世界的口径
// （316），透传进 717 的世界就短了 115 —— 这就是「键盘盖住输入框」。所以本版在公式
// 之后加一道「量出来的占高」，见上面 0.4.17 那一段。公式本身**一个字符没改**。
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

    // 0.4.23 — **删掉 0.4.17 加的「量出来的占高优先」，回到母版公式一个出口。**
    //
    // 0.4.17 加那一层，是为了修「kbH=717 的世界」。那时 display 被我改成卡片尺寸，
    // `keyboardHeight` 与 `screenHeight` 双双是 717 ⇒ 母版公式退化成恒等、`orig`
    // 被原样透传成 316，比真实 386 少 70 ⇒ 键盘盖住输入框。旧世界里除了测量没有别的路。
    //
    // 0.4.21 把 display 还给系统之后，**那个前提不存在了**：`keyboardHeight` 回到
    // 物理 932，母版公式重新开始工作 —— `(316 × 717 ÷ 932) + 932 − 717 = 458`，
    // 而 458 > 431（真实占高）。母版公式的哲学本来就是「宁可留白，不盖内容」，
    // 富余的 27 pt 正好覆盖候选条后到时把键盘顶高的那一段。
    //
    // 反过来，0.4.17 那一层在现在**是有害的**：它量的是「此刻」的键盘，而键盘升起
    // 和候选条到达是两个时刻。第一次量到 386（无候选条），App 就按 386 排完版；
    // 等候选条把键盘顶到 431，App 不再重排 ⇒ 输入框被盖 45 pt。307 现场：
    //
    //   inter … formula=458 meas=386 -> 386   ← 第一次，报了无候选条的值
    //   inter … formula=458 meas=431 -> 431   ← 候选条到了，App 已经不看了
    //
    // `formula` 从头到尾是 458 没变过，它只看 `orig`（键区高），一次到位；
    // 候选条怎么变都落在那 27 pt 余量里，根本不需要 App 重排。
    //
    // 所以整层删掉。它属于「为旧地基打的补丁」，旧地基 0.4.21 已经拆了。
    //
    // ⛔ 教训：**换了地基，要回头审所有「为旧地基打的补丁」。** 0.4.21 拆地基时
    // 我只删了自己记得的那几条补偿，0.4.17 这条留在原地，又烧了一版才看出来。
    CGFloat chosen = answer;
    // 只读取证：量出来的真实占高仍然打日志，方便对照公式的余量够不够。
    // **它不参与决策** —— 这一版起 inset 只有一个来源。
    CGFloat hostY = 0.0;
    CGFloat hostH = 0.0;
    CGFloat measured = AevonKbMeasuredCoverage(keyboardWindow, screenHeight, &hostY, &hostH);
    if (measured > screenHeight) measured = screenHeight;

    if (AevonKbInterNotes < 10) {
        AevonKbInterNotes += 1;
        char line[288];
        snprintf(line, sizeof(line),
                 "app: kb: inter orig=%.0f screen=%.0f kb=%.0f hf=%.2f formula=%.0f meas=%.0f host=%.0f,%.0f -> %.0f\n",
                 orig, screenHeight, keyboardHeight, AevonKbHeightFraction,
                 answer, measured, hostY, hostH, chosen);
        AevonKbLog(line);
    }
    return chosen;
}

// ===========================================================================
// 0.4.14 — 键盘窗视图树取证（**只读，不改任何几何**）
// ===========================================================================
//
// 0.4.11 / 0.4.12 / 0.4.13 三版都死在同一处：屏幕 717 那条硬切线。而三版的读数
// （`win frame=` / `bnd=` / `root=`）每次都显示「我们写的三层几何完全正确」——
// 说明裁切或平移发生在**窗口内部某一层**，不在我们下笔的那几层。
//
// 这组读数只做一件事：把键盘窗真实的视图树按层打出来（类名 / frame / bounds.origin /
// clipsToBounds / 子视图数），并附上 window 自身、它所在的 windowScene、以及 App 主窗
// 的矩形。下一份日志就能指认「是谁把内容裁在 717」，不用再从截图反推。
//
// 配额：每进程 3 次、深度 3、总行 20。一次输入会话最多三屏，日志不会变负担。
static volatile int AevonKbTreeDumps = 0;
static UIWindow *AevonKbTreeTarget = nil;

static void AevonKbDumpView(UIView *view, int depth, int *budget) {
    if (view == nil || budget == NULL || *budget <= 0 || depth > 3) return;
    *budget -= 1;
    CGRect frame = view.frame;
    CGRect bounds = view.bounds;
    NSUInteger count = [[view subviews] count];
    char line[240];
    snprintf(line, sizeof(line),
             "app: kb: tree %*s%s f=%.0f,%.0f,%.0fx%.0f b=%.0f,%.0f,%.0fx%.0f cl=%d n=%d\n",
             depth * 2, "", class_getName([view class]),
             frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
             bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
             [view clipsToBounds] ? 1 : 0, (int)count);
    AevonKbLog(line);
    for (UIView *child in [view subviews]) {
        AevonKbDumpView(child, depth + 1, budget);
    }
}

static void AevonKbDumpChain(UIWindow *window, const char *why) {
    if (window == nil || why == NULL) return;
    if (AevonKbTreeDumps >= 3) return;
    AevonKbTreeDumps += 1;
    char line[256];
    CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
    CGRect wb = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(bounds));
    snprintf(line, sizeof(line),
             "app: kb: tree %s win=%.0fx%.0f@%.0f,%.0f bnd=%.0f,%.0f,%.0fx%.0f lvl=%.0f\n",
             why, wf.size.width, wf.size.height, wf.origin.x, wf.origin.y,
             wb.origin.x, wb.origin.y, wb.size.width, wb.size.height,
             ((CGFloat (*)(id, SEL))objc_msgSend)(window, @selector(windowLevel)));
    AevonKbLog(line);

    UIWindowScene *scene = ((id (*)(id, SEL))objc_msgSend)(window, @selector(windowScene));
    if (scene != nil) {
        // 0.4.15 — scene 的**物理落点**（origin 才是关键）。
        //
        // 0.4.14 只试了 `-_frame`，`UIWindowScene` 没有这条选择子 ⇒ 每份日志都是
        // `scene=0x0@0,0`，等于什么都没读到。而「键盘悬空 215 + 下面透明」这个形状，
        // 唯一还没被排除的变量就是它：App 的承载面到底住在屏幕 0..717 还是 215..932。
        //
        // 三级回落，全部先 `respondsToSelector:` 再读（问是免费的，裸调会杀进程）：
        //   ① `-uiSettings` → `-frame`        （UIScene 私有，最常见）
        //   ② `-_scene` → `-settings` → `-frame`（FBScene 这一层，兜底）
        //   ③ `-_frame`                        （0.4.14 那条，多半不答）
        // 日志里带 `src=` 指明哪一级命中，拿不到就写 `none` —— 不拿 0 冒充。
        CGRect sf = CGRectZero;
        const char *src = "none";
        SEL uiSel = NSSelectorFromString(@"uiSettings");
        SEL frameSel = NSSelectorFromString(@"frame");
        if ([scene respondsToSelector:uiSel]) {
            id us = ((id (*)(id, SEL))objc_msgSend)(scene, uiSel);
            if (us != nil && [us respondsToSelector:frameSel]) {
                sf = ((CGRect (*)(id, SEL))objc_msgSend)(us, frameSel);
                src = "ui";
            }
        }
        if (src[0] == 'n') {
            SEL fbsSel = NSSelectorFromString(@"_scene");
            SEL setSel = NSSelectorFromString(@"settings");
            if ([scene respondsToSelector:fbsSel]) {
                id fb = ((id (*)(id, SEL))objc_msgSend)(scene, fbsSel);
                if (fb != nil && [fb respondsToSelector:setSel]) {
                    id st = ((id (*)(id, SEL))objc_msgSend)(fb, setSel);
                    if (st != nil && [st respondsToSelector:frameSel]) {
                        sf = ((CGRect (*)(id, SEL))objc_msgSend)(st, frameSel);
                        src = "fbs";
                    }
                }
            }
        }
        if (src[0] == 'n') {
            SEL plain = NSSelectorFromString(@"_frame");
            if ([scene respondsToSelector:plain]) {
                sf = ((CGRect (*)(id, SEL))objc_msgSend)(scene, plain);
                src = "raw";
            }
        }
        CGRect cb = CGRectZero;
        id space = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(coordinateSpace));
        if (space != nil) {
            cb = ((CGRect (*)(id, SEL))objc_msgSend)(space, @selector(bounds));
        }
        snprintf(line, sizeof(line),
                 "app: kb: tree %s scene=%.0fx%.0f@%.0f,%.0f src=%s co=%.0fx%.0f@%.0f,%.0f\n",
                 why, sf.size.width, sf.size.height, sf.origin.x, sf.origin.y, src,
                 cb.size.width, cb.size.height, cb.origin.x, cb.origin.y);
        AevonKbLog(line);
    }

    // 0.4.16 — 键盘窗在**屏幕坐标空间**里的绝对矩形。
    //
    // 300 已经证到：`-bounds` 的系统原值就是 430x717（我们的钩子是空操作）、
    // scene 落点最终确实是 215、root=窗=717 —— 三个数全对而画面悬空。于是只剩
    // 「内容最终被摆在哪」这一个变量。`UIScreen.coordinateSpace` 是公开的空间，
    // 跨窗口换算正是它的用途；万一 UIKit 拒绝跨空间，`convertRect:toCoordinateSpace:`
    // 会抛 NSException，所以整段包在 @try 里 —— 取证不许杀进程。
    //
    // 判据：`abs` 的 y = 215 ⇒ App 的世界确实从物理 215 开始，键盘贴底是对的，
    // 病根在别处；y = 0 或 331 ⇒ App 的世界从物理 0 开始，键盘悬空 215 是必然。
    {
        Class scrClass = (Class)objc_getClass("UIScreen");
        id scr = nil;
        if (scrClass != Nil && [(id)scrClass respondsToSelector:@selector(mainScreen)]) {
            scr = ((id (*)(id, SEL))objc_msgSend)((id)scrClass, @selector(mainScreen));
        }
        SEL spaceSel = NSSelectorFromString(@"coordinateSpace");
        if (scr != nil && [scr respondsToSelector:spaceSel]) {
            id space = ((id (*)(id, SEL))objc_msgSend)(scr, spaceSel);
            if (space != nil) {
                CGRect absBox = CGRectZero;
                BOOL ok = NO;
                @try {
                    absBox = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(
                        window, @selector(convertRect:toCoordinateSpace:), wb, space);
                    ok = YES;
                } @catch (NSException *e) {
                    (void)e;
                    ok = NO;
                }
                if (ok) {
                    snprintf(line, sizeof(line),
                             "app: kb: tree %s abs=%.0fx%.0f@%.0f,%.0f\n",
                             why, absBox.size.width, absBox.size.height,
                             absBox.origin.x, absBox.origin.y);
                } else {
                    snprintf(line, sizeof(line), "app: kb: tree %s abs=err\n", why);
                }
                AevonKbLog(line);
            }
        }
    }

    // App 主窗：它的尺寸就是 App 认为的屏幕。与键盘窗并排看，才知道谁短了。
    Class appClass = (Class)objc_getClass("UIApplication");
    id app = nil;
    if (appClass != Nil && [(id)appClass respondsToSelector:@selector(sharedApplication)]) {
        app = ((id (*)(id, SEL))objc_msgSend)((id)appClass, @selector(sharedApplication));
    }
    if (app != nil && [app respondsToSelector:@selector(windows)]) {
        NSArray *all = ((id (*)(id, SEL))objc_msgSend)(app, @selector(windows));
        for (id item in all) {
            if (item == window) continue;
            CGRect mf = ((CGRect (*)(id, SEL))objc_msgSend)(item, @selector(frame));
            snprintf(line, sizeof(line),
                     "app: kb: tree %s main=%.0fx%.0f@%.0f,%.0f %s\n",
                     why, mf.size.width, mf.size.height, mf.origin.x, mf.origin.y,
                     class_getName([item class]));
            AevonKbLog(line);
            break;
        }
    }

    UIViewController *root = ((id (*)(id, SEL))objc_msgSend)(window,
                                                            @selector(rootViewController));
    UIView *top = window;
    if (root != nil) {
        UIView *rv = [root view];
        if (rv != nil) top = rv;
    }
    int budget = 20;
    AevonKbDumpView(top, 0, &budget);
}

static void AevonKbDumpTick(void *context) {
    (void)context;
    AevonKbDumpChain(AevonKbTreeTarget, "settled");
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
    // 0.4.21 — 建窗这一拍读**真值**（母版 `_hookUIScreen = 0`）。
    //
    // 0.4.11~0.4.20 在这里读的是承载面（717），因为当时 `displayConfiguration` 已被
    // 我们改成 717，「系统值」本身就不存在了。0.4.21 把 display 还给系统之后，
    // 这一拍读到的就是物理屏 (0,0,430,932) —— 母版那句的语义完整回来了。
    AevonKbWinReal += 1;
    UIScreen *main = [UIScreen mainScreen];
    CGAffineTransform scale = CGAffineTransformMakeScale(1, 1);

    // 系统建好这一拍的原框 —— **只用于证词，不参与计算**（0.4.14 起）。
    CGRect orig = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));

    // 0.4.14 / 0.4.21 — **窗就用 `[main bounds]`，一个分量都不改。**
    //
    // 母版两条竖屏分支（`0x5280` / `0x52d8`）合起来只有一句话：把窗设成
    // `[UIScreen mainScreen].bounds`（`_hookUIScreen` 关着那一拍读到的矩形）。
    // 0.4.21 的世界里这一拍读到的是**物理屏** (0,0,430,932)，语义与母版逐字相同：
    // 「键盘窗 = App 的整个屏幕」。
    CGRect box = [main bounds];          // 真值 ⇒ 物理屏 (0,0,430,932)
    CGFloat width = box.size.width;
    CGFloat height = box.size.height;

    CGRect asked = CGRectZero;
    // ⛔ 0.4.20 在这里加过一个 `shiftY = 物理屏高 − 承载面高 = 215`，把窗挪到 215..932。
    //
    // 它修掉了「悬空」（窗底终于贴到屏底），代价是窗的**下半 215 pt 被推出了 App 的
    // 世界** —— 0.4.20 的世界只有 717 高，所以那 215 pt 直接越界，系统裁掉 ⇒
    // 用户 305 报的「贴着底部、但下半透明」。位移不是解法，它只是把「键盘不该被塞进
    // 一个 717 高的世界」这件事换了个方向又证明了一遍。0.4.21 整段删掉。
    int dy = 0;                          // 恒 0：证实词用，几何上不再有任何位移
    if (AevonKbIsFrontMost()
        || (AevonKbAppScene != nil && [AevonKbAppScene interfaceOrientation] == 1)) {
        // 竖屏（母版 0x5280 / 0x52d8 两路的合并语义）：窗 = 整个物理屏。
        asked = CGRectMake(box.origin.x, box.origin.y, width, height);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setFrame:), asked);
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
        // ⛔ 0.4.13 — bounds **只给尺寸，origin 必须是 (0,0)**。
        //
        // 母版原文是 `[win setBounds:[win frame]]`，那行能成立是因为母版这一拍
        // `_hookUIScreen = 0`、系统原框原点恒为 (0,0) ⇒ `frame.origin` 是 0，
        // `bounds.origin` 也就是 0 —— 等价于「只改尺寸」。
        //
        // 0.4.12 把窗原点挪到 y=215（让窗底对齐屏底），照抄这一行就把
        // `bounds.origin` 写成了 (0,215)。bounds.origin 是**内容坐标系**的偏移，
        // 于是窗里所有内容整体上移 215：本该渲染在屏幕 573..932 的键盘画到了
        // 358..717，717 以下既没有像素、也不接收触摸 —— 这就是 Aevon(297) 的
        // 「只显示上半部分、下半透明无法触摸」。窗自己的 frame 仍是 215..932，
        // 所以从 `win frame=` 那行完全看不出异常。
        //
        // 正确写法：bounds 尺寸 = frame 尺寸、origin 归零。与母版语义等价
        // （母版 origin 本来就是 0），不是新机制。
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setBounds:),
                                                 CGRectMake(0, 0,
                                                            now.size.width,
                                                            now.size.height));
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
            // root view 的高度必须等于窗的高度，否则它就是那把裁刀
            // （0.4.11 的 `win frame=430x932@0,0` + root 717 ⇒ 键盘切在屏幕 717）。
            CGRect want = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(bounds));
            ((void (*)(id, SEL, CGRect))objc_msgSend)(view, @selector(setFrame:), want);
        }
    }
    AevonKbWinReal -= 1;
    AevonKbHookUIScreen = YES;

    if (AevonKbWinNotes < 6) {
        AevonKbWinNotes += 1;
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
        char line[320];
        snprintf(line, sizeof(line),
                 "app: kb: win frame=%.0fx%.0f@%.0f,%.0f scale=%.1f hosted=%d\n",
                 now.size.width, now.size.height, now.origin.x, now.origin.y,
                 scale.a, 1 - (int)AevonKbIsFrontMost());
        AevonKbLog(line);
        // 0.4.21 — 各数分开写，下一份日志能直接指出是哪一环断的：
        //   orig  系统建好这一拍的原框（期望 430x932@0,0）
        //   host  我们要求窗的宽×高（期望 430x932 = 物理屏）
        //   phys  物理屏高（与 host 同源，0.4.21 起两者应当相等）
        //   ask   我们要求窗口多大（期望 430x932@0,0）
        //   frame 系统最终给的框（比 ask 矮 ⇒ 被夹；`dy` 恒 0，恒等式证词）
        // 0.4.13 — 再补两个：
        //   bnd   **窗的 bounds.origin，必须是 0,0**（非 0 ⇒ 整窗内容被平移，Aevon(297)）
        //   root  root view 的 frame，尺寸必须等于 frame、origin 必须是 0,0
        CGRect bnd = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(bounds));
        CGRect rvf = CGRectZero;
        if (root != nil) {
            UIView *probe = [root view];
            if (probe != nil) {
                rvf = ((CGRect (*)(id, SEL))objc_msgSend)(probe, @selector(frame));
            }
        }
        CGRect nativeBox = [main nativeBounds];
        CGFloat nativeScale = [main nativeScale];
        CGFloat phys = nativeScale > 0.0 ? nativeBox.size.height / nativeScale : height;
        snprintf(line, sizeof(line),
                 "app: kb: win orig=%.0fx%.0f@%.0f,%.0f host=%.0fx%.0f phys=%.0f ask=%.0fx%.0f@%.0f,%.0f frame=%.0fx%.0f@%.0f,%.0f dy=%d bnd=%.0f,%.0f root=%.0fx%.0f@%.0f,%.0f\n",
                 orig.size.width, orig.size.height, orig.origin.x, orig.origin.y,
                 width, height, phys,
                 asked.size.width, asked.size.height, asked.origin.x, asked.origin.y,
                 now.size.width, now.size.height, now.origin.x, now.origin.y,
                 dy, bnd.origin.x, bnd.origin.y,
                 rvf.size.width, rvf.size.height, rvf.origin.x, rvf.origin.y);
        AevonKbLog(line);
    }
    // 0.4.14 — 0.55 s 后打一次「落地态」的视图树。键盘窗由 UIKit 长期持有，
    // 这个静态槽只是记「打哪一扇窗」，不增加它的生命周期。
    if (AevonKbTreeDumps < 3) {
        AevonKbTreeTarget = (UIWindow *)window;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(0.55 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, AevonKbDumpTick);
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
