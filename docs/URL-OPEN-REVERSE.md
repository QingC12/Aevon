# 四个浮窗 / 分屏插件的 URL 打开链路（逆向记录）

样本（私有仓库 `QingC12/Ziyong123`，均为原始 deb）：

| 包 | 版本 | 与 URL 的关系 |
|---|---|---|
| `com.charlieleung.trollopenjb` | 1.5.2 | 显式接管 URL：`_openURLCore` + 三个 `_handleOpen*Request` |
| `com.be-huge.floating-view` | 1.6.0 | **不拦 URL**；拦的是应用启动 `FBSystemService -openApplication:options:withResult:` |
| `com.zengniu.splitview` | 0.7.66 | **不拦 URL**；`SpringBoard applicationDidFinishLaunching:` + 自建窗口 |
| `com.nx.stheno` | 0.1.23 | **不拦 URL**；拦的是激活口 `SBMainWorkspace -_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:` |

> 结论先行：**「授权 / 支付直接小窗」不是 URL 功能。**
> 后三个包在整个二进制里搜不到 `weixin` / `mqq` / `alipay` / `wechat` 任何一个
> bundle id 或 scheme（`strings -a` 全量扫描，0 命中），也搜不到 `_openURLCore`。
> 它们接的是「**一个 App 即将被启动**」这件事本身：只要这次启动落到它们的
> 窗口容器里，那么拉起它的是 OAuth 回调、支付 SDK、通知还是桌面图标，都无关紧要。

方法：`dpkg-deb -x` 解包 → `strings -a` 取 `__cstring` / `__objc_methname` →
`llvm-objdump --macho -d` 全量反汇编（arm64e 切片，19 MB text / 1000 万行）→
按 selector 与日志格式串交叉核对。下文只写**二进制里能直接读到**的名字，
推断处单独标注。

---

## 一、TrollOpenJB 的入口（SpringBoard 进程）

轮询安装的 selector（`__objc_methname` 原文）：

```
_openURLCore:display:animating:activationSettings:origin:withResult:
_handleOpenApplicationRequest:options:activationSettings:origin:withResult:
_handleTrustedOpenRequest:options:activationSettings:origin:withResult:
_handleUntrustedOpenRequest:options:activationSettings:origin:withResult:
```

对应日志格式串（`__cstring`）：

```
SpringBoard _openURLCore:display:animating:activationSettings:origin:withResult:
    url=%@ target=%@ display=(nil) shouldSplit=%d forceNow=%d
SBMainWorkspace _handleOpenApplicationRequest:options:activationSettings:origin:withResult:
    target=%@ source=%@ launchOrigin=%@ window=%.0fms
SBMainWorkspace _handleOpenApplicationRequest banner launch origin bypass
```

推断：`display=(nil)` 是**读数**（把入参 display 打出来），不是它传给系统
的值；真正决定「进不进浮窗」的是 `shouldSplit` / `forceNow`（读偏好），
浮窗由它自己的 `TOS_openFloatingViewForURL` 建，不依赖系统把 scene 摆到屏上。

## 二、它构造 / 读取的 open 选项键

`__objc_methname` + `__cstring` 里出现的 FrontBoard 选项键（全部按 `__` 前缀
原样读取，因为 `FBSOpenApplicationOptions` 的字典键是私有字符串）：

```
__ActivateSuspended        __LaunchIntent          __LaunchSceneless
__PayloadURL               __PayloadOptions        __LaunchOrigin
__Actions                  __UnlockDevice          __PromptUnlockDevice
__DocumentOpen4LS          __AppLink4LS
```

`__ActivateSuspended` 是「只建 scene、不抢前台」的开关；`__PayloadURL` /
`__PayloadOptions` 是文件分享 / 文档打开的载荷。**文件跳转必须走
`_handleOpenApplicationRequest` 这一层才能同时拿到 URL 和载荷**，
`_openURLCore` 只有 URL 本体。

`LSApplicationWorkspace` 侧用到的 selector：

```
openURL:options:completionHandler:
openApplicationWithBundleID:
launchApplicationWithIdentifier:suspended:
applicationProxyForIdentifier:
URLForApplicationToOpenURL:
```

## 三、scene / 窗口侧用到的私有 API

```
FBSceneManager
SBSceneManagerCoordinator
SBApplicationController
SBDeviceApplicationSceneHandle
_UIScenePresenter / UIScenePresentationManager
_createApplicationSceneTransitionContextFromContext:entity:
initWithDeviceApplicationSceneHandle:layoutRole:
addAppLayoutForDisplayItem:windowScene:completion:
overrideAppSceneEntityForLaunchingApplication:
hasOverrideAppSceneEntityForLaunchingApplication:
_setDeactivationReasons:onScene:withSettings:reason:
setFlag:forActivationSetting:
```

`overrideAppSceneEntityForLaunchingApplication:` 是**只出现在这个样本里的
入口**：它让 SpringBoard 把「即将启动的 App」挂到调用方给的 workspace
entity（也就是浮窗所在的 window scene），而不是主屏。Stheno 里没有、
FloatingView 里也没有 —— 这是 TrollOpenJB 能把 URL 打开成浮窗而不闪全屏的
最可能落点（推断，未在真机验证）。

## 四、授权回跳的处理

字符串里有成对的 route 记录：

```
open-route pair record mode=reverse source=%@ target=%@
open-route pair close  ...
open-route pair expired
```

推断：每次浮窗打开记一条 `source → target`；当 target 反过来打开 source
（OAuth / SSO 回跳）时，命中 reverse 记录，关掉浮窗、把 source 请回前台。
这解释了它为什么敢「吞掉」URL —— 回跳不依赖 SpringBoard 的那次激活。

## 五、启动来源（launch origin）常量

```
SBSLaunchOriginActionButton
SBSLaunchOriginShortcutItem
SBSLaunchOriginSpotlight
SBSLaunchOriginBulletinDestinationBanner
SBSLaunchOriginBulletinDestinationCoverSheet
```

`banner launch origin bypass` 说明它把通知横幅那一路单独放行，避免和浮窗
抢同一次激活。

## 五点五、其余三个包真正的接管点（本轮新增，逐条可复现）

### FloatingView 1.6.0

`__objc_methname` 原文：

```
openApplication:options:withResult:
serviceForClientIdentifier:
requesterIdentifier
setBundleIdentifierToLaunch:
pidForApplication:
revokePresentablesWithIdentification:reason:options:animated:userInfo:error:
presentAnimated:
```

`__objc_cfstring` / 链接常量里带 `FBSystemService`、`FBSystemServiceOpenApplicationRequest`、
`FBSOpenApplicationOptions`，以及全套选项键：

```
_FBSOpenApplicationOptionKeyPayloadURL      _FBSOpenApplicationOptionKeyPayloadOptions
_FBSOpenApplicationOptionKeyLaunchOrigin    _FBSOpenApplicationOptionKeyActions
_FBSOpenApplicationOptionKeyDocumentOpen4LS _FBSOpenApplicationOptionKeyAppLink4LS
_FBSOpenApplicationOptionKeyActivateSuspended
_FBSOpenApplicationOptionKeyUnlockDevice    _FBSOpenApplicationOptionKeyPromptUnlockDevice
SBSLaunchOriginShortcutItem
```

`FBSystemService` 是**所有**应用启动请求（URL / 通知 / App 间跳转 / 图标）在
FrontBoard 侧的唯一总入口：`-openApplication:options:withResult:`。在这里
`options` 里已经带 `PayloadURL`，所以 OAuth 的 URL 也能读到 —— 但它不需要读，
它只需要把「这次启动」交给自己的窗口容器。

### Stheno 0.1.23

Swift 类名（`_TtC6Stheno…`）里同时存在：

```
SBMainWorkspaceHook      FBSystemServiceHook
SBApplicationHook        UIApplicationHook
```

`__objc_methname` 原文：

```
_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:
```

这是 `SBMainWorkspace` 的激活函数 —— 比 `_handleOpenApplicationRequest`
更靠里一层，所有 workspace 级激活最终都汇到这里。Stheno 的浮窗不是
「打开之后抢过来」，是「激活时就换成自己的 scene」。

### SplitView 0.7.66

链接到 `Apelin`（它自己的 hook 引擎）并 hook
`-[SpringBoard applicationDidFinishLaunching:]`；自有方法（日志与选择子原文）：

```
canOpenBundleIdentifier:
canOpenNotificationBundleIdentifier:mode:
prepareBundleIdentifier:switcherLaunch:whenReady:
prepareNotificationBundleIdentifier:mode:whenReady:
prepareSwitcherBundleIdentifier:whenReady:
openBundleIdentifier:whenReady:
presentNotificationWindow:mode:
launchApplicationWithIdentifier:suspended:
applicationWithBundleIdentifier:
newSceneViewWithReferenceSize:…
```

日志格式串：

```
ZNS launch selector unavailable or ABI changed; waiting for application launch notification
card launch declined: no checked Home layout dismissal API
fullscreen launch rejected: %{public}@
```

也就是说它**自己发起启动**（`launchApplicationWithIdentifier:suspended:` 走后台，
再自建 scene），系统那次前台激活根本不存在，自然没有「先全屏再回落」。

### 三个包的共同点

| 共同点 | 含义 |
|---|---|
| 不认 scheme / bundle | 没有 OAuth / 支付的专项分支，靠「启动即入窗」天然覆盖 |
| 拦在启动之前 | 窗口 / scene 在 App 被显示**之前**就存在 |
| 自己拥有 scene | 不是把系统已经摆到屏上的 scene 抢过来，而是从 born 起就托管 |

## 六、对 Aevon 的结论

1. **不能在 `_openURLCore` 里只把 display 传 nil**：0.2.69 已证明结果是
   「目标不建 scene + 主屏没有前台 App」。TrollOpenJB 的 `display=(nil)` 是
   日志读数，不是它下发的值。
2. **文件分享的正确拦截点是 `_handleOpenApplicationRequest`**：只有这一层
   同时拿得到 `__PayloadURL` / `__PayloadOptions`，`_openURLCore` 拿不到。
3. **要「不闪全屏」只有两条路**：
   - `overrideAppSceneEntityForLaunchingApplication:` 把启动实体改成浮窗的
     window scene（TrollOpenJB 的路线，改动大，需真机验证 selector 存在）；
   - 「吞掉 + 自建 scene + App 内投递 URL」（Aevon 0.2.15 的分享路线），
     代价是文件载荷可能丢，且授权回跳需要 route pair 兜底。
4. **0.2.71 的安全网保留**：落点放行后 1.8 s，若卡片 / 桌面 / 任意全屏
   App 三样都没有，判定前台已丢，直接用 `LSApplicationWorkspace
   openApplicationWithBundleID:` 拉回来源 App（没有就目标），仍不行就强建卡。

## 六点五、0.2.72 按本轮数据做的三处修改

1. **不再把「来源 App」顶回全屏**（`AevonShareSwapTick`）。
   0.2.71 真机 09:41:36 的现场是：

   ```
   notify: share swap restore b=com.tencent.mqq door=1
   win: card yield seen b=com.tencent.mqq now=430x932 want=430x717
   win: card yielded to fullscreen b=com.tencent.mqq
   ```

   授权回跳那一刻 QQ 本来就在卡里，是 Aevon 自己把它拉成整屏、再让卡片让路。
   现在：来源已经有卡时直接 `AevonOpenCardDirect(目标)`，那一次全屏不再存在。
   对应日志 `notify: share swap keep b=<目标> src=<来源>`。

2. **授权卡的接管节拍 50 ms → 15 ms（前四拍）**。
   参考包是「启动前就建窗」，Aevon 的模型是「启动后接管」，能压缩的只有这段
   延迟。`tick >= 1` 那道门保留（它要的是「系统激活已落地」，不是固定时长），
   但前四拍改成 15 ms，`scene` 一登记就接走。

3. **支付并入授权一族**：`com.eg.android.AlipayGphone`、`com.unionpay`。
   逆向数据里三个包都没有任何支付专项分支 —— 它们不需要，因为拦的是启动。
   Aevon 拦的是 URL，就必须显式列出目标 App，否则支付 SDK 拉起支付宝那一下
   会整屏。

4. **仍然做不到的部分（诚实记录）**：Aevon 没有自己的 scene 工厂
   （`AevonOwnStart` 在真机 `door=-1`），所以「启动前就建窗」这条路当前不可用；
   0.2.72 是把「启动后接管」压到最短，不是把模型换成参考包那一种。
   要彻底消除首帧整屏，需要在 `FBSystemService -openApplication:options:withResult:`
   上先建卡、再放行 —— 那是下一步，不是本次范围。

## 七、复现命令

```bash
# 解包
dpkg-deb -x pkg.deb out/

# 选择器 / 字符串
strings -a TrollOpenJB.dylib | grep -E '_openURLCore|OpenApplicationRequest|ActivateSuspended'

# 反汇编（arm64e 切片，输出约 250 MB）
llvm-objdump --macho --arch-name=arm64e -d --no-show-raw-insn TrollOpenJB.dylib > tojb.dis
```
