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
