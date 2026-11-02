# 悬浮窗「场景创建」还差哪些数据（2026-11-02 实测口径）

范围：**只谈建 scene + presenter + 宿主 view**。键盘让位、Darwin 通知、URL/前后台共享一律不谈。

结论先说：**调用点这一层基本不缺了（11 步里 6 条 MATCH、4 条 PRESENT），
真正缺的是四类「不问方法名、要读实例」的数据**：缺 8 条零参属性的归属、
缺 4 个建窗对象的构造内容、缺 4 个数值、缺跨函数顺序。
并且这四类**全都能在真机上取到**，因为系统自己有同名实现者。

---

## 〇、先纠正上一轮的一个错误结论

上一轮把 7 条 `NO-IMPLEMENTER` 写成「17.3.1 上不存在 / 母本钩子空转」。
你说得对：母本在 17.3.1 能跑，数据必然在真机上。准确表述应该是：

> **那是「按我们的探针口径，在 SpringBoard 进程里没问到实现者」，不是「不存在」。**

口径有两个结构性缺陷，本轮查清了：

1. **清单只收带冒号的选择子。** 123 条里**没有任何一条**是零参方法或属性
   （`activate`、`invalidate`、`presentationView`、`uiPresentationManager`、`sharedInstance`
   一律不在）。原因在 `tools/compare-calls.py` 的提取与 `sel_census.py` 的正则：
   要求 `至少一个冒号`。**零参方法被系统性漏掉了**，与存不存在无关。
2. **族外候选只按 9 个关键字挑名字**（presentable/material/handle/tap/icon/foreground/duration/press/setting）。
   场景创建的关键类**一个都不含这些词**，所以从未被点名：

   ```
   grep -c "tail cand SBFluidSwitcherPortaledSceneLiveContentOverlay$"   → 0
   grep -c "tail cand _UIContextLayerHostView$"                          → 0
   grep -c "tail cand FBSceneManager$"                                   → 0
   ```

   （它们在家族段里被问过，因为 `SB`/`FB`/`_UI` 在前缀表里；但族外那一轮等于没查。）

---

## 一、场景创建链的 11 步，逐条现状

母本的选择子引用（`__objc_selrefs`）在 cstring 里是**连续成段**的，
下面第 6–8 步就是从同一个函数里连出来的一段：

```
initWithSceneLayer: | setResizesHostedContext: | uiPresentationManager
                    | createPresenterWithIdentifier:priority: | presentationView
```

| # | 动作 | 选择子 | 探针实测 | 缺什么 |
|---|---|---|---|---|
| 1 | 取 scene 工厂 | `FBSceneManager.sharedInstance` | **未查**（零参，清单盲区） | 归属与编码 |
| 2 | definition | `FBScene.definition` | **未查**（零参） | **对象内容** |
| 3 | settings | `FBSMutableSceneSettings`（类名在 `_OBJC_CLASS_$_` 里） | 类存在 | **字段值** |
| 4 | clientSettings | `UIMutableApplicationSceneSettings`（同上） | 类存在 | **字段值** |
| 5 | transitionContext | `FBSSceneTransitionContext` | 母本二进制里**没有这个类名** | 怎么造 |
| 6 | 建 scene | `_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:` | **MATCH** · `FBSceneManager` · `@72@0:8@16@24@32@40@48@56@?64` | 7 个实参怎么填 |
| 7 | 取 presenter 工厂 | `uiPresentationManager` | **未查**（零参） | 归属与编码 |
| 8 | 建 presenter | `createPresenterWithIdentifier:priority:` | **MATCH** · `UIScenePresentationManager` · `@32@0:8@16q24` | **priority 数值**、identifier 字符串 |
| 9 | 拿视图 | `presentationView` / `initWithSceneLayer:` | 后者 **MATCH** · `_UIContextLayerHostView` · `@24@0:8@16` | 两条路选哪条（见第三节） |
| 10 | 让宿主跟随 | `setResizesHostedContext:` | **PRESENT** · `SBShelfLiveContentOverlay`、`SBFluidSwitcherPortaledSceneLiveContentOverlay`、`SBFluidSwitcherAppClipLiveContentOverlay` | 布尔值 |
| 11 | 保活 / 拦更新 | `_setDeactivationReasons:onScene:withSettings:reason:`（MATCH `v48@0:8Q16@24@32@40`）、`_scene:interceptUpdateWithNewSettings:`（MATCH） | **MATCH** | **Q 位掩码数值**、reason 字符串 |

---

## 二、缺的数据分四类（这是你要的清单）

### A 类 · 零参属性的归属与编码（实测 6 条，工具口径造成，真机一问就有）

盲区已经定量了。`analysis/tools/sel_census.py` 加上 `--allow-zero` 并补扫
`__TEXT,__const` 之后，Stheno.dylib 的选择子从 115 条（methname）扩到 **192 条**，
其中与场景创建相关、且**不在现有 123 条清单里**的正好 6 条：

```
presentationView             UIScenePresenting 的属性，浮窗的最终视图
uiPresentationManager        UIWindowScene 的属性，presenter 工厂的入口
scene                        宿主 view / controller 反查所属 scene
transitionContext            建 scene / 更新 settings 时复用的上下文
window                       浮窗最终挂上的那个 UIWindow
_windowHeight                 母本自有的计算属性（不是系统 API）
```

> 前 5 条是系统属性，第 6 条是母本自己的。这 6 条**不需要新证据源**，
> 只要探针的提取口径放开零参，下一次装机就有归属与编码。

`__objc_methname` / `__cstring` 之外还有一整段 `__TEXT,__const`（偏移 645216，37,080 字节）
装着选择子名字符串 —— 之前的普查**只扫前两段**，这是零参盲区的物理原因，不是母本没用。

### B 类 · 四个建窗对象的构造内容（唯一真正的硬缺口）

`_createSceneWithDefinition:...` 只要 4 个实参：

```
definition            @16   ← 缺：怎么造
settings              @24   ← 缺：填了哪些字段
initialClientSettings @32   ← 缺：填了哪些字段
transitionContext     @40   ← 缺：怎么造（母本连类名都没引用）
fromRemnant           @48   ← 可为 nil
usingClientProvider   @56   ← block/对象，参数形状未知
```

**但母本的引用面把这道坎降了一级**：它在 `_OBJC_CLASS_$_` 里引用了
`FBSMutableSceneSettings` 与 `UIMutableApplicationSceneSettings`，
却**没有**引用 `FBSMutableSceneDefinition` / `setSpecification:` / 任何 settings 字段 setter，
也**没有** `setValue:forKey:`（只有 `valueForKey:`）。

⇒ 母本是「**抄现成的 `FBScene.definition`，把现成 settings 转 mutable 后原样传**」，
不是逐字段构造。所以 B 类缺口不是「猜 Apple 的私有字段」，而是
**「dump 一个现成 scene 的 definition/settings 长什么样，照抄」**——真机上现成。

### C 类 · 四个数值

| 数值 | 用在哪 | 静态拿得到吗 |
|---|---|---|
| presenter `priority`（int64） | 决定浮窗与系统窗口的 z 序 | 不能，只能读系统现值或试 |
| `setWindowLevel:`（double） | 浮窗落在哪一层 | 不能，可读现有窗口 |
| `_setDeactivationReasons:` 的 `Q` | 决定 scene 会不会被后台挂起 | 不能，可 hook 系统调用观察 |
| 浮窗尺寸 / 圆角 | `bezierPathWithRoundedRect:cornerRadius:` 在 selrefs 里出现 | 不能，属设置项 |

系统侧参照物：`UIWindow`、`UIRemoteKeyboardWindow`、`SBWallpaperController` 都实现了
`setWindowLevel:`（探针 PRESENT），直接读它们的 `windowLevel` 就是合法区间。

### D 类 · 跨函数顺序

selrefs 的相邻只能证明「同一函数里先后引用」，不能证明跨函数时序：

- 先 `initWithSceneLayer:` 还是先 `createPresenter...`？（两个都出现，可能是两条互斥分支）
- `_scenes:interceptUpdateWithNewSettings:` 是在建 scene 前装还是后装？
- `_setDeactivationReasons:` 是在 scene 激活前还是激活后？

这一层只能靠「在真机上把每个点打一行时间戳」解决，不是靠读二进制。

---

## 三、一条必须先判定的路线分歧：`activate` 全场 0 次

`UIScenePresenter` 正常用法是 `createPresenter → activate → presentationView`。
但在 `Stheno.dylib` 里：

```
grep activate    → 6 处，全是 Orion 的 GlueClassHook.activate / _activateBundleID: / activationState
grep invalidate  → 0
grep sceneLayer  → 0
```

**母本一次都没调过 presenter 的 `activate` / `invalidate`。** 两种解释：

- **路 A（presenter）**：`uiPresentationManager → createPresenter → presentationView`
  三连确实紧邻出现，但没有 `activate` ⇒ 这个 view 不会渲染。**除非**母本在别的二进制里 activate。
- **路 B（layer host）**：`_UIContextLayerHostView initWithSceneLayer:` 直接把 scene 的 layer
  挂进自己的 view 层级，**不需要 presenter，也不需要 activate**。

旁证支持路 B：`setResizesHostedContext:` 的三个本机实现者全是 live content overlay
（`SBShelfLiveContentOverlay`、`SBFluidSwitcherPortaledSceneLiveContentOverlay`、
`SBFluidSwitcherAppClipLiveContentOverlay`）—— 那是 Apple 自己「把某个 App 的 scene
移植成一块可布局视图」的现成实现。

**这一条不判定，就算把 A 类 8 条全补齐也建不出能看见的窗。**

---

## 四、为什么「真机上都有」——五步取数，全在 SpringBoard 内

不需要 App 侧注入，不越出「场景创建」这个范围：

1. **遍历现成 scene，dump 实例**
   `enumerateScenesWithBlock:`（MATCH，block 签名 `v16@?0@"FBScene"8`）已经可用。
   对每个 `FBScene` 调 `_ivarDescription` / `debugDescription`，把
   `definition` / `settings` / `clientSettings` 打成 key=value。→ 直接填 B 类。
2. **旁观系统自己建 scene**
   hook `-[FBSceneManager _createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:]`，
   把 7 个实参 `description` 打出来。打开 App、画中画、横幅、控制中心都会走这里。
   → 拿到「Apple 认可的合法 payload」，零猜测。
3. **读 presenter 工厂的现值**
   dump `uiPresentationManager` 的 `_presenters` 一类 ivar，拿系统用的 identifier 与 priority 区间。
   → 填 C 类前两项。
4. **读系统自己的实现者**
   `SBFluidSwitcherPortaledSceneLiveContentOverlay` 的 ivar 列表 = Apple 版「移植 scene 到视图」
   的完整零件清单。**这一步比逆向母本更值钱**：它有源码级正确性，母本只是抄它。
5. **观察保活位**
   hook `_setDeactivationReasons:onScene:withSettings:reason:`，看系统给前台/后台 scene 各传什么 `Q`。
   → 填 C 类第三项。

第 1、2、4、5 步都只读不写，风险等同现有探针；第 3 步是纯 getter。

---

## 五、下一版探针要加的目标（精确清单）

```
# A 类：零参属性（实测 6 条，全部来自 __TEXT,__const 段）
presentationView  uiPresentationManager  scene  transitionContext  window
（_windowHeight 是母本自有计算属性，不列入）

# B 类：建窗对象的构造面
FBSMutableSceneDefinition  FBSceneRemnant  FBSSceneTransitionContext
initWithSettings:  mutableCopy  definition  setSpecification:

# 呈现层：判定路 A / 路 B
activate  invalidate  setSceneLayer:  _UISceneLayerHostView
SBFluidSwitcherPortaledSceneLiveContentOverlay（作宿主对照）
```

工具侧已经改完（`D:/最新工作区/stheno-逆向分析/analysis/tools/sel_census.py`）：

| 改动 | 效果 |
|---|---|
| 新增 `--allow-zero` | 收零参方法/属性，首字符须小写（排除 `_OBJC_*` / `_TtC*` / `_$s*`） |
| 新增补扫 `__TEXT,__const` | 之前只扫 `__objc_methname` + `__cstring`，整段漏掉 |
| 新增 `--grep kw1,kw2` | 按关键字过滤，便于按功能域出候选 |
| 输出加 `const=` 列、合计三者并集 | Stheno.dylib 从 115 条扩到 **192 条** |

`tools/compare-calls.py` 的族外候选关键字也需同步加 `scene/presenter/layer/host/window`
（现有九关键字对场景创建等于空白），这一步等下一版探针一起改。

---

## 六、诚实说明

- 本文件所有数字都有可复现命令，没写「大概」「应该」。
- **没有构建、没有推送、没动版本号（仍 0.0.13）、没有创建任何浮窗。**
- 第三节的路线分歧（presenter vs layer host）是**本轮唯一新发现的未知**，
  它比补 6 条属性更优先——因为选错路，补全也没用。
- 第四节的五步都还没做，它们是下一版探针的内容，不是本轮已完成的结论。

## 七、清单口径的两个新限制（本轮顺手查出来的，影响「清单是否完整」这个判断）

### 7.1 `__TEXT,__const` 整段曾被漏扫（已修）

`sel_census.py` 原先只扫 `__objc_methname` 与 `__cstring`。Stheno.dylib 的选择子名字符串
实际落在 `__TEXT,__const`（偏移 645216，37,080 字节），整段没被读。补扫后单文件从
115 条扩到 192 条。这就是 6 条零参属性「凭空冒出来」的物理原因。

### 7.2 fat 文件的两个 slice 选择子集合不一致（未解决，已记录）

| slice | 架构 | 选择子（同口径） |
|---|---|---|
| 0 | arm64 | 135 |
| 1 | arm64e（设备上真正执行的） | 234 |
| — | 两者交集 | 89 |

只在 arm64 slice 出现的 46 条里包含 `createPresenterWithIdentifier:priority:`、
`enumerateScenesWithBlock:`、`deactivateWithTransitionContext:`、`defaultWorkspace`
等场景创建主链选择子 —— 这不可能是「设备上没有」，只能说明
**arm64e slice 的段布局不同，当前解析器读到的不是同一块区域**
（arm64e 用 `LC_DYLD_CHAINED_FIXUPS`，需要按链式指针逐页解码，
这正是 `GAP-1TO1.md` 第八节记的那个工具缺口）。

**处理方式**：不动当前选取逻辑（当前取 slice 0，恰好是干净的选择子表），
把这条记为已知限制。理由是——**场景创建主链的 11 条判定来自真机探针的 MATCH 结果，
那是硬证据，不受静态口径影响**；清单只用来回答「还漏了哪些名字」。

⇒ 所以对本轮问题的影响是：6 条零参属性是**下限**（arm64 slice 里能证明存在的），
arm64e slice 里可能还有更多，要等链式指针解码器写出来才能穷尽。
