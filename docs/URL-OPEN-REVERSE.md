# 四个浮窗 / 分屏插件的 URL 打开链路（逆向记录）

样本（私有仓库 `QingC12/Ziyong123`，均为原始 deb）：

| 包 | 版本 | 与 URL 的关系 |
|---|---|---|
| `com.charlieleung.trollopenjb` | 1.5.2 | **唯一显式接管 URL 的样本**：`_openURLCore` + 三个 `_handleOpen*Request` |
| `com.be-huge.floating-view` | 1.6.0 | 不拦 URL；从图标 / 通知入口建浮窗，`FBSceneManager` 自建 scene |
| `com.zengniu.splitview` | 0.7.66 | 不拦 URL；分屏布局 |
| `com.nx.stheno` | 0.1.23 | 不拦 URL；scene 生命周期与激活口（母本） |

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
4. **本次 0.2.71 只做安全网**：落点放行后 1.8 s，若卡片 / 桌面 / 任意全屏
   App 三样都没有，判定前台已丢，直接用 `LSApplicationWorkspace
   openApplicationWithBundleID:` 拉回来源 App（没有就目标），仍不行就强建卡。
   正常路径零改动，保证最坏情况下手机可操作。

## 七、复现命令

```bash
# 解包
dpkg-deb -x pkg.deb out/

# 选择器 / 字符串
strings -a TrollOpenJB.dylib | grep -E '_openURLCore|OpenApplicationRequest|ActivateSuspended'

# 反汇编（arm64e 切片，输出约 250 MB）
llvm-objdump --macho --arch-name=arm64e -d --no-show-raw-insn TrollOpenJB.dylib > tojb.dis
```
