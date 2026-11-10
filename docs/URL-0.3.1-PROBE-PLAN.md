# Aevon 0.3.1 取证方案 — 在「App 即将被启动」那一拍接管

> 依据：Aevon(225) 判读 + Stheno.dylib 静态统计
> 原则：**名字必须在本机取证，不猜**
> 目标：找到「能在系统摆屏之前改掉这次启动路由」的那一格

---

## 一、已确证的事实（不再取证）

### 1.1 崩溃与整屏的共同根因

| 现象 | 证据 | 根因 |
|---|---|---|
| 安全模式 | `.ips` 栈顶 `-[FBWorkspace registerHost:settings:...]`，`Aevon.dylib+0x5de4` 调 `createSceneWithDefinition:initialParameters:` | 自建 scene |
| 先全屏 | 四条路全部 `act: frame birth blocked why=immutable` | settings 是不可变 `UIApplicationSceneSettings` |
| 黑底 | `first frame shown after 1097ms`；系统全屏窗由激活事务发，scene 被搬走后无人画 | 同上 |

**三者同源**：我们先让系统把 App 摆到屏上，再把它搬走。只要这个顺序不变，观感就不会变。

### 1.2 Stheno 的真实做法（静态统计，可复核）

```
Stheno.dylib (2,153,664 B) 字符串命中：
  _activateBundleID                              2   ← 只拦激活
  createPresenterWithIdentifier                  4   ← 换承载
  setResizesHostedContext                        2
  uiPresentationManager                          2
  presentationView                               2
  _UIContextLayerHostView                        4
  initWithWindowScene                            2
  ─────────────────────────────────────────────
  _handleOpenApplicationRequest                  0   ← 不拦打开请求
  _openURLCore                                   0   ← 不拦 URL
  overrideAppSceneEntity                         0   ← 不用实体覆盖
  _sceneEntityForLaunching                       0
```

**结论**：Stheno 的站位极窄 —— 只在 `SBMainWorkspace -_activateBundleID:…withResult:` 这一格。它不动 URL、不动打开请求、不动 scene definition，只**换承载**（presenter）。

这解释了它为什么不需要消灭全屏帧：它让系统正常造 scene、正常激活，然后**在 scene 被摆上屏之前**把 presenter 换掉。scene 的 `activationState` 由 scene 本身决定，与占屏面积无关（0.2.90 已确认）。

---

## 二、本机还缺的三件事（必须取证）

### 2.1 `_activateBundleID:` 的 options 里有没有「落点」位

0.2.90 的读数已经量到：

```
act: activate n=2 ... opt=FBSOpenApplicationOptions via=1 keys=2 payload=1
   k=__PayloadOptions|__PayloadURL
```

**`options` 不是字典，是 `FBSOpenApplicationOptions`。** 0.2.89 报 `keys=-1 payload=-1` 是「没读到」，不是「没有」。0.2.90 用 `dictionary` → `payload` 两级取到了两个键。

**要取证的问题**：`FBSOpenApplicationOptions` 上除了 `payload`，还有哪些可写属性？特别是与「scene 归属 / 显示」有关的。

→ 探针：转储 `FBSOpenApplicationOptions` 的**全部**方法名 + ivar 名 + 每个方法的编码。

### 2.2 `_createSceneWithDefinition:` 的 `settings` 有没有可变的另一份

日志显示传进来的是 `UIApplicationSceneSettings`（不可变）。但 `_createSceneWithDefinition:` 的签名里有 **7 个参数**：

```
@72@0:8@16@24@32@40@48@56@?64
  = (self, _cmd, definition, settings, initialClientSettings,
     transitionContext, fromRemnant, usingClientProvider, completion)
```

第 4 个 `transitionContext` 在日志里是 `UIApplicationSceneTransitionContext` —— **它可能是可变的**。

→ 探针：对 `transitionContext` 问类名、方法数、`setActions:` / `setFrame:` / `setResizesHostedContext:` 是否存在。

### 2.3 presenter 在 scene 激活之前能不能建

Stheno 的做法是「scene 建好、activate 之前把 presenter 换掉」。0.2.84 的普查确认：

```
createPresenterWithIdentifier:priority:  → UIScenePresentationManager  @32@0:8@16q24
modifyPresentationContext:               → _UIScenePresenter（参数是 block） v24@0:8@?16
setResizesHostedContext:                 → UIMutableScenePresentationContext + 5 个 SB overlay
```

→ 探针：在 `_createSceneWithDefinition:` 的 **completion 里**（scene 已建、尚未上屏那一拍）问：
   - `scene.uiPresentationManager` 拿不拿得到
   - `createPresenterWithIdentifier:priority:` 能不能在那一刻建
   - `setResizesHostedContext:YES` 能不能写进去

---

## 三、探针设计（只读，一次装机能答完）

### 3.1 三条取证线

| 线 | 挂点 | 问什么 | 输出 |
|---|---|---|---|
| **A** | `FBSystemService -_activateBundleID:…withResult:` 替身内 | `options` 类名+全部方法+编码；`dictionary`/`payload` 两级；`setXxx:` 类方法是否存在 | `probe: actopt cls=… n=… | <方法表>` |
| **B** | `FBSceneManager -_createSceneWithDefinition:…completion:` 替身内 | 第 4 参 `transitionContext` 类名+方法+编码；`setActions:` 存在否；`scene` 的 `uiPresentationManager` 拿到否 | `probe: tctx cls=… n=… | <方法表>` |
| **C** | `_createSceneWithDefinition:` 的 completion block 内 | scene 已建、未上屏那一拍：`createPresenterWithIdentifier:priority:` 返回值；`setResizesHostedContext:` 写后读 | `probe: pres birth ok=… cls=… resize=…` |

### 3.2 安全约束（一条不减）

- 全部**只读**：只 `class_copyMethodList` / `method_getTypeEncoding` / `respondsToSelector` / `class_getInstanceMethod`，**零 `method_setImplementation`**（除了已装的两个取证钩子）；
- 每一行日志前先 `AevonActStep()` 落盘（崩溃也有话说）；
- 每个探针体包在 `@try` 里；
- 不调用任何未经确认的 `objc_msgSend`（先问 `respondsToSelector`）；
- 自建 scene 已用 `volatile` 硬开关关闭（`AevonOwnStart` 第一行 return 0）。

### 3.3 判据（下一版决策表）

| 探针读数 | 结论 | 下一版动作 |
|---|---|---|
| A 里出现与「scene 归属 / 显示」相关的可写属性 | options 能改落点 | 在 `_activateBundleID:` 替身里改 options 再尾调原实现 |
| B 里 `transitionContext` 可变且有 `setActions:` | transitionContext 能装路由 | 在 `_createSceneWithDefinition:` 里改 transitionContext |
| C 里 completion 中 `createPresenter` 成功 + `setResizesHostedContext` 可写 | 能在上屏前换承运人 | 照 Stheno 的做法：completion 里建 presenter |
| 三条全否 | 本机做不到「零全屏」 | 诚实交付：保留现状，把「整屏一帧」写进设置页说明 |

---

## 四、与 Stheno 的差距（诚实对照）

| 维度 | Stheno | Aevon 现状 |
|---|---|---|
| 拦截层 | `_activateBundleID:` | `_handleOpenApplicationRequest:` + `_openURLCore:` |
| 拦截后动作 | **换 presenter**（scene 照建） | **先放行，再收卡** |
| 全屏帧 | 无（presenter 换在摆屏前） | 有（scene 已上屏才搬） |
| 自建 scene | 无 | 有（本次崩溃源，已关闭） |
| URL 处理 | 不拦 | 拦 |

**Aevon 比 Stheno 多拦了一层 URL**，但少了最关键的那一步：换 presenter。

---

## 五、本次不做什么

1. **不改任何判定条件** —— 四路的识别逻辑（`__PayloadURL` / paste token / 授权族名单 / 黑名单）保持 0.3.0 原样。
2. **不加新私有 API** —— 只增加「问」的代码，不加「调」的代码。
3. **不动圆盘 / 手势 / 键盘 / 保活** —— 那些在 0.3.0 里一条没改，本次也不碰。
4. **不做「先建卡再塞 App」** —— 0.2.74~0.2.78 已证伪，不再回头。
