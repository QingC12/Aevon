# 逆向事实速查（来自母本 Stheno 0.1.23）

本仓库所有设计决策的依据都在这里。数据源：`stheno-逆向分析/`（deb、6 个 dylib、classdump、22 个 section 导出）。

## 一、母本规模

| 项 | 数值 |
|---|---|
| 主库 Swift 类 | 32（其中 21 个是 Hook 类） |
| ObjC 选择子 | 128 |
| 功能键（zh-Hans） | 81 |
| 注入 dylib | 6（主库 + 键盘 + 注入器 + 若干） |

81 个功能键 = 一份现成的需求清单。P7 的设置面板逐键对齐即可。

## 二、承载模型（P1 的核心，不可替换）

```
SpringBoard
 └─ UIScenePresentationManager
     └─ createPresenterWithIdentifier:priority:
         └─ _UIContextLayerHostView   ← 浮窗真正挂载的位置
             └─ 独立 Scene（BackBoard 渲染服务托管）
```

**为什么不能用「在 SpringBoard 里放一个 UIView」替代**：
动画与合成由 BackBoard 渲染服务执行，不经主线程，所以主线程降载时浮窗依然流畅。
一旦换成普通 UIView，后面五层（几何、手势、圆盘、保活、键盘）全部要重写。

二进制命中数（自证，不依赖跨厂商对照）：

- `createPresenterWithIdentifier:priority:` × 4
- `_UIContextLayerHostView` × 4
- `_scene:interceptUpdateWithNewSettings:` × 2
- `_setDeactivationReasons:onScene:withSettings:reason:` × 1

## 三、保活：只改参数，不加写

母本全库 `Assertion` **0 命中**（小写 `assertion` 的 4 处是 Swift 运行时 `$ss17_assertionFailure` 导入符号，与保活无关）。

保活靠的是拦截系统下发的新 settings，在内存里改参数：
**先比对，确实变了才写，写完不复查。**

这条是历史事故的直接结论：每写一次就闪一次，根因就是多余的写回。

## 四、键盘必定要独立桥

- `remoteKeyboardWindowForScreen` × 2 在 `SthenoKeyboard.dylib`
- `KeyboardArbiter` × 4、`BaseKeyboardOffset` × 2、`floatingsHasKeyboard` × 4 在主库

浮窗是独立 Scene，键盘在场景之外，**必须桥接**。母本为此单独出一个注入 UIKit 的库，这不是可选优化。

## 五、跳转链路（P8）

`_openURLCore` 在母本 **0 命中**。走的是：

`__interceptors` + `SS*` 系列开关 + UIKit / SafariViewService 双注入

按 `_openURLCore` 去实现 P8 方向就是错的。

## 六、无法 1:1 的部分

Swift 方法体已被 strip，**不存在逐指令复刻的可能**。
验收口径是：功能 / 交互 / 设置项三层等价 + 双机盲测说不出差别，不承诺帧级一致。

## 七、不复刻的部分

授权体系（`inject.stheno.com` / `validKey`）属于第三方商业资产，不复刻。
81 键里两个激活相关项保留键位、功能隐藏。

## 八、iOS 17.3.1 真机核对（2026-11-02，第二段探针）

设备 iPhone 15 Pro Max / 17.3.1 / roothide。进程内注册类 **99,374** 个，与逆向记录的
99,398 一致（差值来自 respring 后的加载顺序）。

### 8.1 已坐实（归属 + 类型编码都实测）

| 类 | 方法 | encoding | 说明 |
|---|---|---|---|
| `UIScenePresentationManager` | `-createPresenterWithIdentifier:priority:` | `@32@0:8@16q24` | 与逆向一致，呈现入口 |
| `_UIContextLayerHostView` | `-initWithSceneLayer:` | `@24@0:8@16` | 归属由本次实测坐实 |
| `FBSceneManager` | `-enumerateScenesWithBlock:` | `v24@0:8@?16` | 归属坐实 |
| `FBSceneManager` | `-_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:` | `@72@0:8@16@24@32@40@48@56@?64` | **7 参 + 尾部 block**，编码为新数据 |
| `FBScene` | `-deactivateWithTransitionContext:` | `v24@0:8@16` | 归属坐实 |
| `SBDeviceApplicationSceneViewController` | `-initWithSceneHandle:` | `@24@0:8@16` | 承载控制器入口 |
| `SBDeviceApplicationSceneViewController` | `-setSceneResizesHostedContext:` | `v20@0:8B16` | 见 8.3，注意与母本那条不是同一个 |
| `SBDeviceApplicationSceneViewController` | `-sceneContentView` / `-backgroundView` | `@16@0:8` | 真正装内容的 view |

`FBSceneManager` 有 `+sharedInstance`，实例答应
`[sceneWithIdentifier:,enumerateScenesWithBlock:,_createSceneWithDefinition:…,createSceneWithDefinition:]`；
按名查 `com.apple.springboard` 拿到 `FBScene`，其答应
`[identifier,specification,clientProcess,settings,definition]`。

### 8.2 否定结论（同样有价值）

- **`SBApplication` 不实现 `-mainSceneHandle`，也不实现 `-sceneHandleForSceneIdentifier:`。**
  3 个样本（`com.apple.FCAuthenticationUI` / `com.apple.Health` / `com.haier.uhome.Uplus`）在
  `responds(to:)` 上完全一致，所以是**类级缺席**，不是样本没跑起来。
  台账里 262 个应用对象全部是 `SBApplication`。
  ⇒ 「从 bundle id 直接取 App 主场景 handle」这条路在 17.3.1 上不成立，要另找入口。
  （这条来自多浮窗项目的方案，不是母本的调用；记下来是为了不再重复试。）
- SpringBoard 进程里的 `UIApplication` 实例子类是 **`SpringBoard`**，它答应
  `[_windowScene,_mainScene,connectedScenes]`，不答应任何 presentation manager 取值器。
  这正是我们圆盘宿主取「第一个 connectedScene」会落到 SystemAperture 场景的原因。

### 8.3 两个容易混淆的选择子（写错过一次）

| 选择子 | 归属 | 备注 |
|---|---|---|
| `setResizesHostedContext:` | 未知（母本 123 条之一） | 17.3.1 上未解析到；候选 `_UIContextLayerHostView`（11 个自有方法只打了 2 个）或 `UIScenePresentationContext` |
| `setSceneResizesHostedContext:` | `SBDeviceApplicationSceneViewController` `v20@0:8B16` | 多一个 `Scene`，是宿主侧那条 |

两者**不能互相顶替**。`tools/compare-calls.py` 上一版把前者归属写成了后者的类，已删。

### 8.4 这一段的覆盖盲区（已修）

第二段探针按关键词过滤方法名，原白名单只有 `init/scene/handle/present/activat/layer/view`，
`setResizesHostedContext:` 一个都不含 ⇒ 即使某个被 dump 的类定义了它，也不会打印，
**读起来像「不存在」**。已补 `Context / host / Host / resiz / Resiz`。
此外类名普查命中 663 个但只打印 80 个、每类方法最多打 90 条 —— 都是刻意的上限，
完整覆盖靠第三段（母本 123 条逐个全进程解析，不过滤）。

### 8.5 与母本的对照状态

123 条里目前**已坐实 5 条、另有 1 条承载关键等待解析**，其余 117 条尚未覆盖 ——
第二段是为「19 个承载类」写的，不是为母本调用表写的。逐条对齐要等第三段 dump，
用 `python tools/compare-calls.py <log>` 出表，退出码 0 才算调用点全部清晰。

### 8.6 123 条里有 5 条不是「调用」，是母本自己的方法

母本类转储（`stheno-classdump-arm64e.txt`，11 个类）的自有方法与那 123 条求交集，得到 5 条：

| 选择子 | 母本里属于 |
|---|---|
| `-init` | `SthenoWindow` |
| `-initWithCoder:` | `SthenoWindow` |
| `-initWithFrame:` | `SthenoWindow` |
| `-initWithWindowScene:` | `SthenoWindow` |
| `-hitTest:withEvent:` | `SthenoWindow` |
| `-gestureRecognizerShouldBegin:` | `FullScreenBackGesture.Coordinator` |

（6 行 / 5 条选择子中的 `-init` 一族按家族计。）

它们出现在 `__objc_methname` 里是因为母本**自己实现或覆写**了它们，不代表它把同名消息
发给了系统类。所以本机查不到它们不是「缺失」，是意料之中 —— 把这两件事混为一谈，
会得到 5 条假缺失。

⇒ **123 − 5 = 118 条真正的系统调用需要逐条解析。**

`initWithWindowScene:` 要特别记一笔：它既是母本自有方法（`SthenoWindow` 用它建窗口），
又是承载关键（`tools/compare-calls.py` 的 `CARRIER_CRITICAL`）。两个身份同时成立，
不能因为归入自有方法就把它从承载判定里摘掉。

`tools/compare-calls.py` 的 `OWN_METHODS` 集合就是这 5 条：标记出来、不计入硬失败，
但照常输出它的实测归属。

### 8.7 最后 7 条：本机没有实现者（0.0.13 真机跑完，2026-11-02）

0.0.13 第一次把「家族段 + 族外点名」两头都跑到底：`phase1 done hits=114 of 123 scanned=9827 secs=7`，
接着 `tail done names=4411 owned=6 missing=9 secs=4`，全程无崩溃、无安全模式。

| 判定 | 数量 | 含义 |
|---|---|---|
| MATCH | 8 | 归属 + 类型编码都与逆向记录一致 |
| PRESENT | 106 | 本机有定义，逆向只记了调用（这次的实测即为新基准） |
| PRESENT-TAIL | 2 | 只能在族外候选里问到（`BSAnimationSettings` 一族、`MTMaterialView` 一族） |
| NO-IMPLEMENTER | 7 | 家族段 + 4411 个族外候选都问过，没人实现 |

家族段覆盖的前缀是 `SB / FB / _UI / UI / NS / LS / CA / BK / XB / SpringBoard`（9827 个类），
族外候选是「名字里带 presentable/material/handle/tap/icon/foreground/duration/press/setting」
的 4411 个类。这两片加起来覆盖了这 7 条所有可能的宿主，所以「没人实现」是**实测结论**，
不是没扫到。

那 7 条分两类，都不在建窗链上：

**一类：母本自己的 delegate 方法（selref 来自定义，不是调用）**

| 选择子 | 依据 |
|---|---|
| `gestureRecognizer:shouldReceivePress:` | `UIGestureRecognizerDelegate` 的可选方法，Apple 侧几乎无人实现；母本有 `FullScreenBackGesture.Coordinator` 这个 delegate，与 `gestureRecognizerShouldBegin:` 同类 |

**二类：母本想 hook / 想调的私有方法，17.3.1 上确实没有**

| 选择子 | 依据 |
|---|---|
| `iconManager:launchIconForIconView:withActions:` | 母本有 `SBIconControllerHook`；`SBIconController`、`SBHIconManager`、`SBIconView` 都在家族段扫过，无人有此方法 |
| `isApplicationForeground:` | 母本有 `SBApplicationHook`；`SBApplication` 在家族段，无此方法 |
| `setHandleClick:` | 母本有 `SBGrabberTongueHook`；`SBGrabberTongue` 在家族段（且 `_handlePullGesture:` 已命中），无此 setter |
| `_handleTapOnView:` | 名字属 SB 私有面，`SBIconView` / `SBHIconManager` / `SBFluidSwitcherGestureManager` 都无 |
| `presentPresentable:withOptions:userInfo:` | `SBSystemAperture*` 全族在家族段，无 |
| `_dismissPresentable:withReason:animated:userInfo:` | 同上；且它是这 7 条里**唯一**出现在 `__TEXT,__cstring` 的，说明母本是用 `NSSelectorFromString` 动态取它（配合 `respondsToSelector:` 做防御性调用），不是静态消息发送 |

**结论**：建窗链（`initWithWindowScene:` → `createPresenterWithIdentifier:priority:` →
`setResizesHostedContext:` → `setWindowLevel:` → scene 创建/更新链）上的调用**全部 MATCH 或 PRESENT**，
7 条 NO-IMPLEMENTER 一条都不在链上。

**顺带的两个副产品**：
1. `presentPresentable:` 两条在本机无实现者 ⇒ **SystemAperture presentable 路线在 17.3.1 上走不通**，
   这与「浮窗不该挂 SystemAperture 场景」的旧结论互相印证，不是巧合。
2. 二类那 6 条意味着母本对应的钩子在 17.3.1 上是**空转**的（hook 注册了但 Apple 侧没有实现者）。
   如果我们照抄这些 hook，得到的是一段永不触发的代码 —— 该换成我们已经在用的入口
   （系统手势管线注册 + 自己的 window/scene 链），不要复刻。
