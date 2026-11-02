# 距 1:1 复刻母本悬浮窗还差什么（2026-11-02 实测口径）

结论先说：**按目前探针的数据，不能 1:1 复刻。** 差的东西分两层 —— 一层是调用点确实没查全
（清单只来自 6 个二进制里的 1 个），另一层是即便调用点全了也不够（缺参数内容、缺顺序、
缺 App 侧让位机制）。下面只写实测到的数，不写印象。

一句话概括最硬的那道坎：**母本的浮窗不是「SpringBoard 里多一个窗口」，而是
「在 App 进程里把 UIScreen 的 bounds 改小，腾出来的位置放浮窗，键盘窗口跟着搬」。**
前半句我们在 SpringBoard 里已经能验证，后半句那条链（App 侧注入）我们一条都没验过。

## 一、这次新查出来的事实（之前没做过）

母本的 deb 里不是一个二进制，是**六个 dylib**，注入点各不相同：

| 二进制 | Filter | 说明 |
|---|---|---|
| `Stheno.dylib` | Bundles = `com.apple.springboard` | 我们 123 条清单的唯一来源 |
| `SthenoFix.dylib` | Bundles = `com.apple.springboard` | 只有 NSUserDefaults 一族 |
| `SthenoKb.dylib` | Bundles = `com.apple.springboard` | 只有 `postNotificationName:object:userInfo:` + `isEqualToString:` |
| `SthenoIdentityHandoffRelease.dylib` | Bundles = `com.apple.springboard` | 51 条，含一整套 cover 交换 |
| `SthenoKeyboard.dylib` | Bundles = **`com.apple.UIKit`** | 26 条，键盘与几何换算都在这 |
| `SthenoCamera.dylib` | Executables = `mediaserverd`, `SafariViewService` | 与浮窗无关 |

`SthenoKeyboard` 的过滤器写的是 `com.apple.UIKit`，不是某个 App 的 bundle id ——
按 Substrate 的约定这是「凡加载 UIKit 的进程」。**不管它到底覆盖多少个进程，有一点是确定的：
键盘那条链不是（只）在 SpringBoard 里跑完的。** 我们的探针只在 SpringBoard 里装，所以那 26 条
选择子在本机的归属与类型编码，**一条都没验证过**。

## 二、清单本身是可信的（先证伪自己）

用 `analysis/tools/sel_census.py` 的字符串口径把六个二进制全扫了一遍：

| 二进制 | 选择子形状字符串 |
|---|---|
| `Stheno.dylib` | 124 |
| `SthenoCamera.dylib` | 7 |
| `SthenoFix.dylib` | 9 |
| `SthenoIdentityHandoffRelease.dylib` | 51 |
| `SthenoKb.dylib` | 2 |
| `SthenoKeyboard.dylib` | 26 |
| **六合一去重** | **188** |

- 现有 123 条清单 **123 条全部命中**母本二进制 ⇒ 清单不是编的，没有幻觉条目。
- `Stheno.dylib` 里还有 1 条清单没收：`windowScene:`（带一个冒号，疑似 KVC 键或某个
  Swift `@objc` 方法名，不是 `setWindowScene:`）。
- 六个二进制合计比清单多 **65 条**。

## 三、差的调用点（65 条里真正挡路的）

### 3.1 必补 —— 直接落在建窗 / 几何 / 键盘链上

| 选择子 | 来自 | 为什么非补不可 |
|---|---|---|
| `remoteKeyboardWindowForScreen:create:` | SthenoKeyboard | 键盘浮窗的宿主窗口。**清单里没有任何键盘相关选择子**，这一层是完全空白 |
| `_boundsForInterfaceOrientation:` | SthenoKeyboard | 按界面朝向算可用区域；我们只有 `setInterfaceOrientation:`，没有换算 |
| `intersectionHeightForWindowScene:isLocalMinimumHeightOut:ignoreHorizontalOffset:` | SthenoKeyboard | 在指定 scene 里算可用高度（避让/贴边/分屏），是几何层的真入口 |
| `sceneID:updateWithSettingsDiff:transitionContext:completion:` | SthenoKeyboard | **带 sceneID 的 settings 更新**，与 SpringBoard 侧的 `updateSettings:withTransitionContext:completion:` 不是同一条 |
| `setBounds:` `setTransform:` `setCenter:` `setOpaque:` | SthenoKeyboard / IdentityHandoff | 卡片缩放/旋转/居中的几何写入口；清单里只有 `setFrame:`，只能平移不能缩放旋转 |
| `windowScene:` | Stheno.dylib | 清单唯一漏收的一条 |

### 3.2 待判定 —— 可能是母本自有属性，不是系统 API

`SthenoIdentityHandoffRelease` 那 40 多条里，下面这族名字的风格与母本自己的 ivar 表
（`_preCoverHeavy`、`_validationNanos` 这种）完全一致：

```
setAuthorizedCoverAddress:  setManagerAddress:  setManager:
setPreCoverAddress:  setPreCoverObject:  setPreCoverBytes:  setPreCoverHeavy:
setPostCoverAddress: setPostCoverObject: setPostCoverBytes: setPostCoverHeavy:
setPostCoverCGImageAddress: setPostCoverRegenerated: setPreCGImageAddress:
setSwapPerformed:  setIdentityHandoffAccepted:  setGeneration:  setEventSequence:
setSessionID:  setLifecycleState:  setHelperEnterNanos:  setHelperReturnNanos:
setValidationNanos:  setHosts:  setPreViewsCount:  setAccessibilityElementsHidden:
```

判断依据（还没验）：一个 Swift 类的 `@objc` 存储属性，setter 名字也会进 methname，
长得和系统 API 一模一样。**只有在本机问一遍 `class_getInstanceMethod` 才能分开**：
问到了 ⇒ 是系统 API，得解析；问不到 ⇒ 是母本自有 setter，与「调用点」无关。

这一族的语义（从名字读）：在前后台切换时把 cover（封面）的 CGImage 地址、字节数、
heavy 标记整套换掉，并记录 enter/return/validation 三个纳秒时间戳 —— 看起来是
**反截图/反检测或快照交换**，不是建窗必需。但「不是必需」和「确认不需要」是两件事，
要等 3.2 的问一遍结果。

### 3.3 已知且不挡路

本机 7 条 `NO-IMPLEMENTER`（`docs/REVERSE-NOTES.md` 8.7），一条都不在建窗链上。

## 四、比调用点更硬的三个缺口

调用点补齐只解决「这条消息本机答不答应」。真正卡住 1:1 的是这三样，探针查不到：

1. **参数内容（payload）**
   `_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:`
   的 7 个参数我们只知道类型编码（`@72@0:8@16@24@32@40@48@56@?64`），不知道里面填了哪些 key。
   **选择子对、payload 错，窗口一样出不来或者出在黑框。** 这是第一大缺口。
2. **调用顺序与时机**
   母本 2528 个 Swift 类只还原出 32 个（`stheno-swift-classes.txt`：`total_unique=2528 shown=32`）。
   建窗链顺序（先建 scene 还是先建 window、什么时候 setRootViewController、什么时候
   interceptUpdateWithNewSettings）、手势状态机、保活时机，全在那 96% 里。
3. **App 侧身份与跨进程契约**（本轮已经把契约挖出来了，见第七节）
   SpringBoard 与 App 侧不是靠调用互通的，是靠 **一个 /tmp JSON 文件 + 4 个 Darwin 通知 +
   两个 NSUserDefaults 域**。这些全是字符串常量，**不是选择子**，所以「选择子普查」永远抓不到；
   我们之前既没查过，也就不知道缺。现在有了清单，但它仍然意味着：只装 SpringBoard 侧探针，
   这条链永远动不了。

## 五、所以现在能做什么、不能做什么

| 目标 | 现在能不能 |
|---|---|
| 在 SpringBoard 里建一个独立 scene + presenter + 宿主 view，把一块自己的内容显示成浮窗 | **能**（建窗链 8 条 MATCH、106 条 PRESENT，全绿） |
| 浮窗里放一个 App 的实时画面（不是静态快照） | **不能**，缺 App 侧注入（`SthenoKeyboard` 那条线）与 `remoteKeyboardWindowForScreen:create:` 的归属 |
| 让 App 给浮窗让出高度（母本的做法是改 App 眼里的屏幕） | **不能**，缺 `UIScreen -_boundsForInterfaceOrientation:` 改写 + `HeightFraction` |
| 浮窗跟着设备旋转/分屏正确换算几何 | **不能**，缺 `_boundsForInterfaceOrientation:` 与 `intersectionHeightForWindowScene:…` |
| 用 SystemAperture presentable 当浮窗壳 | **不能且不必**，本机无实现者（8.7） |
| 复刻母本的「cover 交换」行为 | **待判定**，先分它是自有 setter 还是系统 API（3.2） |

## 六、把这些补上的最短路径（不需要 IDA）

1. **探针加目标（SpringBoard 侧就能验的部分）**
   把 3.1 的 6 条 + 3.2 的 25 条一起塞进 `callTargets`，跑一遍家族的 9827 类 + 族外候选。
   3.2 那族如果全部 `n=0`，就当场判定「母本自有 setter」，从缺口里划掉；如果命中，
   就白拿归属与编码。**一次装机同时解决「补调用点」和「区分自有/系统」两件事。**
2. **App 侧探针（要单独一版，风险与收益都要先说清）**
   键盘链的关键选择子必须在一个真的 App 进程里问，SpringBoard 里问不到正确答案。
   最小做法：只做「问归属 + 写日志」不做任何 hook，注入面只写 `com.apple.UIKit` 一个过滤。
   这一步会引入「探针进 App」的新风险，不在本版范围内。
3. **payload 与顺序（最难，也最值钱）**
   不靠静态反汇编的替代路径：在**系统自己**建 scene 的时候把 4 个参数 `description` 打出来
   （比如舞台/画中画/横幅），照抄它填的 key。这属于下一阶段的设计，不是本版探针。

## 七、跨进程契约（本轮已挖到，全部来自字符串，实测清单）

`SthenoKeyboard.dylib` 与 `SthenoKb.dylib` 的可读串已经把母本 App 侧的做法交代清楚：

| 载体 | 名字 | 用途 |
|---|---|---|
| /tmp 文件 | `/tmp/stheno_frontmost.json` | 前后台状态共享（两个二进制都读它） |
| Darwin 通知 | `com.nx.SthenoKeyboard` | App ↔ SpringBoard 键盘链 |
| Darwin 通知 | `com.apple.UIKit.remote-keyboard` | 键盘仲裁 |
| Darwin 通知 | `com.nx.sthenoRespring` / `com.nx.sthenoSettings` | 注销 / 设置变更 |
| 配置域 | `com.nx.stheno` / `com.nx.stheno.perapp` | 全局配置 / **分应用配置**（`sthenoPerApp`） |
| 私有框架 | `/System/Library/PrivateFrameworks/KeyboardArbiter.framework/KeyboardArbiter` | 母本 **dlopen** 了键盘仲裁框架 |
| UIKit 通知 | `_UIKeyboardWillShow/HideNotification`、`_UIKeyboardFrameEndUserInfoKey` | 键盘几何来源 |

App 侧的做法（从符号名读，`_hookUIScreen` / `_injectApp` / `_updateHeightFraction` /
`_boundsForInterfaceOrientation:` / `_ringAppsContains` / `_upadteFrontMost` / `_init169`）：

1. 注入 App 进程，hook `UIScreen` 的私有 `-_boundsForInterfaceOrientation:`；
2. 按配置里的 `HeightFraction`（`_heightFraction` / `IntersectionHeightFraction`）把 App
   眼里的屏幕高度**改小** —— 空出来的位置就是浮窗；
3. 用 `intersectionHeightForWindowScene:isLocalMinimumHeightOut:ignoreHorizontalOffset:`
   算可用高度，`sceneID:updateWithSettingsDiff:transitionContext:completion:` 更新 scene 设置；
4. 用 `remoteKeyboardWindowForScreen:create:` 拿键盘窗口，`setBounds:` / `setTransform:`
   把它搬到浮窗下方；
5. 前后台靠 `/tmp/stheno_frontmost.json` + `com.nx.SthenoKeyboard` 通知同步，
   并用 `_ringAppsContains` 判断这个 App 是否在圆盘列表里。

**这条路和「在 SpringBoard 里建个 scene 挂个 view」是两码事。** 我们目前的探针只证明前者可行，
后者（让 App 让位、键盘跟随、分应用配置）一条都没验过。

## 八、母本的 hook 面（顺带的解释）

`Stheno.dylib` 里有 21 个 `_TtC6Stheno…Hook` 类：`SpringBoardHook`、`FBSceneHook`、
`FBSceneManagerHook`、`FBSystemServiceHook`、`SBMainWorkspaceHook`、`SBMainDisplaySceneManagerHook`、
`SBApplicationHook`、`SBApplicationControllerHook`、`SBIconControllerHook`、`SBGrabberTongueHook`、
`SBReachabilityManagerHook`、`SBReachabilityGestureRecognizerHook`、`SBFluidSwitcherGestureManagerHook`、
`_SBFluidSwitcherPanGestureRecognizerHook`、`SBDeviceApplicationSceneViewControllerHook`、
`UIApplicationHook`、`UIApplicationSceneDeactivationManagerHook`、`UIStatusBarWindowHook`、
`UIScenePresentationManagerHook`、`BNContentViewControllerHook`、`UNSUserNotificationServerHook`。

这些类**自己声明**了被 hook 的方法（`…Hook5_Glue8OrigType` / `SuprType` 成对出现），
所以它们的名字也会进 `__objc_methname` —— 这正是 8.7 里那 6 条「本机无实现者」的来源：
母本按 iOS 16 时代的名字声明了 hook，17.3.1 上 Apple 侧没有同名实现，钩子空转。

⇒ 反过来说：**123 条清单里混着「要调的系统 API」和「母本自己的 hook 声明」两种东西**，
我们只对后者做了 5 条的剔除（`OWN_METHODS`）。

想把这条界线划干净，得把这 21 个 Hook 类的方法名挖出来再求一次交集。这件事**不是顺手活**，
本轮试过两个现成工具，都在这份二进制上卡住：

| 工具 | 结果 |
|---|---|
| `analysis/tools/objc_classdump.py` | 找到 111 个 class 结构，`chained-fixups resolved: 0 pointers` ⇒ 名字一条没解出来 |
| `analysis/tools/objc_dump2.py` | `ok=11 fail=0`，只解出 11 个类（就是 `stheno-classdump-arm64e.txt` 那 11 个，全是 ObjC 可见的小类） |

原因：这是 arm64e + `LC_DYLD_CHAINED_FIXUPS` 的 Swift 二进制，classlist 里的指针是编码过的，
要先按 `dyld_chained_starts_in_image` 逐页解码才能读到 `class_ro_t`。**缺口是工具，不是数据。**
把它补上是纯静态、零设备风险的活，但成本是一个解析器，不是一次 grep。

好消息是：真正需要区分的那几条（hook 声明 vs 系统 API）已经由 8.7 的 7 条
`NO-IMPLEMENTER` 间接回答了 —— 「本机没有同名实现」本身就是「这是母本自己的声明」的强证据。
