# Aevon 0.3.0 · URL 链路重构方案

> 版本：0.3.0　｜　日期：2026-11-10　｜　状态：**方案定稿，待执行**
> 依据：`stheno-逆向分析/`、`三方逆向/`、`Aevon/docs/URL-OPEN-REVERSE.md`、`Sources/AevonScene.m` 现网代码
> 硬约束：**手机必须能安全使用，不允许开不了机 / 卡开机页**

---

## 一、先看逆向数据说了什么

### 1.1 四家的真实接管点（`docs/URL-OPEN-REVERSE.md` 逐条可复现）

| 插件 | 拦哪一层 | 认不认 scheme |
|---|---|---|
| **Stheno 0.1.23** | `SBMainWorkspace -_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:` | **不认**。二进制里 `weixin`/`mqq`/`alipay` 零命中 |
| **TrollOpen 1.5.2** | `_openURLCore` + 三个 `_handleOpen*Request` | **不认**。靠 `shouldSplit`/`forceNow` |
| **Myrtle 1.5.0** | 手势 + `isUILocked` + 7 秒推断窗口 | **不认**，连 open 请求钩子都没有 |
| **Mango Beta8** | `systemService:handleOpenApplicationRequest:withCompletion:` | **不认** |

**四条结论**：

1. **「授权/支付进小窗」不是 URL 功能。** 后三家在整个二进制里搜不到微信/QQ/支付宝任何 bundle id。它们接的是「**一个 App 即将被启动**」这件事本身 —— 只要这次启动落到自己的窗口容器里，拉起它的是 OAuth 回调、支付 SDK、通知还是桌面图标，都无关紧要。
2. **拦截必须发生在「系统把 scene 摆到屏上」之前。** 三家共同的形状是「窗口在 App 被显示之前就存在」。
3. **`display=(nil)` 是读数，不是下发值。** TrollOpen 的日志格式串是 `display=(nil) shouldSplit=%d`，把入参打出来而已；Aevon 0.2.69 曾照此下发 nil，真机结果是「目标不建 scene + 主屏没有前台 App」。
4. **文件分享只能拦 `_handleOpenApplicationRequest` 这一层** —— 只有它同时拿得到 `__PayloadURL` / `__PayloadOptions`。`_openURLCore` 只有 URL 本体。

### 1.2 Aevon 已经被证伪的三条路（不要再走）

| 方案 | 版本 | 真机证伪读数 |
|---|---|---|
| 吞激活 + 自建 scene + 本地投 URL | 0.2.74–0.2.78 | QQ `rsp=0`、支付宝 `timeout 6342ms`、微信空壳 `cs=0`。**根因：自建 scene 里没有系统那一次激活** |
| definition 带 URL | 0.2.85 | 全 99,452 类扫描，只有 `UISOpenURLAction` 实现 `initWithURL:workspaceOriginatingProcess:`，不是任何 scene definition |
| transitionContext 装 URL | 0.2.86 | `FBSSceneParameters` 21 方法 / 3 ivar，装不下 transitionContext；`setActions:` 在母本 0 命中 |
| `eventOnly` 标志 | 0.2.88 | `evflag=1` + `read=1`，整屏照旧 —— 不是全屏开关 |
| `overrideAppSceneEntityForLaunchingApplication:` | 0.2.74 探针 | 本机只有 `SBInCallPresentationManager` 一个 owner，**这条路不可用** |

**共同教训**：在 SpringBoard 里「先建卡、再把 App 塞进去」这条路，本机（iOS 17.3.1 / arm64e）走不通。

### 1.3 当前 Aevon 是什么形状

0.2.87 起已并轨母版：**放行系统原生激活 → 15 ms 拍一次盯 scene → scene 一登记就收进卡**。四路已统一到 `AevonAuthSwapSchedule`。

代价是「先整屏一小段」—— 实测首帧 Safari 366–414 ms、微信 1972 ms、QQ 471 ms。0.2.90 加了「出生即卡尺寸」：在 `FBSceneManager _createSceneWithDefinition:…completion:` 里，于**系统建 scene 之前**把 settings 的 frame 改成 `宽×(高−215)`。这是唯一能压掉整屏帧且不违反上述证伪的机制。

---

## 二、现有代码的问题（为什么值得重构）

`Sources/AevonScene.m` 12,005 行，URL 相关约 2,900 行，其中：

| 问题 | 现状 |
|---|---|
| **两套入口** | `AevonURLCoreBody`（`_openURLCore` 钩子）与 `AevonOpenDecide`（`_handleOpenApplicationRequest` 钩子）各自分流，靠 `AevonLandingClaim` 手工避让 |
| **三套收卡调度** | `AevonShareSwapTick` / `AevonAuthSwapTick` / `AevonPastePromoteTick`，节拍、超时、放弃条件各写一遍 |
| **四套放弃兜底** | `share swap giveup` / `auth swap giveup` / `paste promote` / `landing guard` |
| **判据层层叠加** | `kind`（notify/share）× `isSafari/isOAuth/isWebLink` × `carrier/sysFrom/sameChain` × `paste token`/`authreturn`/`incard`，共 6 类标志、20 余分支 |
| **历史补丁堆积** | 0.2.14 / 0.2.36 / 0.2.38 / 0.2.49 / 0.2.53 / 0.2.55…0.2.60 / 0.2.67 / 0.2.72 / 0.2.76…0.2.79 / 0.2.87 十余轮，注释量 ≈ 代码量 |
| **死代码** | `AevonPastePromoteTick` / `AevonShareRestoreTick` / `AevonLandingGuardTick` 三条链仅在特定历史分支可达 |

结果：**每一路都能工作，但没人能说清四路合起来的行为边界**。这是本次重构的真实动因。

---

## 三、0.3.0 方案

### 3.1 统一模型：一个判定 + 一个调度 + 四个来源

把「四路」重写成**一条主干 + 四个入口适配器**：

```
                      ┌─ 入口 1：_openURLCore:（链接 / 深链）
                      ├─ 入口 2：_handleOpenApplicationRequest:（分享 / 通知 / 授权）
   请求 ──► 归一化 ──┤
                      └─ 统一判定 AevonRouteDecide()
                              │
                              ├─ PASS   放行，一个字节不改（黑名单 / 系统入口 / 关闭闸）
                              ├─ CARD   收进浮窗（四路唯一目标）
                              └─ SWALLOW 吞掉（仅「同一次点击的第二条」）
                              │
                      ┌───────┴────────┐
                      │  统一调度       │  AevonCardSettle(target, source, style)
                      │  · 出生即尺寸   │  ← 在 createScene 里改 settings.frame
                      │  · 15ms 轮询    │  ← scene 一登记就收卡
                      │  · 6s 兜底      │  ← 等不到就自己建
                      └────────────────┘
```

**四路只是四个「怎么进到判定」的适配器**，判定与调度只有一份。

### 3.2 四路的判据（收窄到最小必要）

| 路 | 入口 | 识别判据 | 关键动作 |
|---|---|---|---|
| **文件分享** | `_handleOpenApplicationRequest:` | 带 `__PayloadURL` 或 `__PasteSharingToken` 且来源是 sharingd / ShareExtension / sharetimeline；或 `UIActivityContinuationAction` | 放行 → `AevonCardSettle(style=share)` |
| **点击链接** | `_openURLCore:` | URL 是 http(s) 且目标由 LaunchServices 现算；或第三方深链（非 `file:` / `tel:` / `prefs:` / `itms-*`） | 放行 → `AevonCardSettle(style=link)` |
| **应用授权** | `_handleOpenApplicationRequest:` | 目标 ∈ {微信, QQ, 支付宝, 云闪付} 且**没有** paste token（有 token = 分享，不是授权） | 放行 → `AevonCardSettle(style=auth)` + `AevonAuthSeenNote` |
| **支付** | 同授权 | 同授权（逆向证明支付与授权形状相同，不做 scheme 特判） | 同授权 |

**关键简化**：
- 删掉 `isWebLink` 的「改投 Safari」特判 —— 那是 0.2.53 为 GitHub 链接加的特例，现在统一走「目标由 LS 算 + 落卡」，改投反而增加分支。
- 删掉 `paste token` 与 `authreturn` 的六层嵌套 —— 授权回跳与分享回跳统一由「来源是否 SSO 本体 + 30s 内有无授权记录」两条件判定。
- 删掉 `sameChain` 之外的 `chain` 分支。

### 3.3 统一调度 `AevonCardSettle`

替代现有三条 Tick：

| 阶段 | 动作 | 判据 |
|---|---|---|
| **T+0** | 记录 `AevonCardTarget` + `AevonCardAt`（供 createScene 用） | 目标非空 |
| **T+0** | 放行原请求（`return 0`） | — |
| **建 scene 时** | `AevonActFrameBirth` 把 frame 改成 `宽×(高−215)` | settings 类名含 `Mutable` **且** frame ≥ 400×900 |
| **T+15ms×4** | 查 `AevonSeenSceneForBundle` | scene 已登记 → 收卡 |
| **T+60ms 起 50ms 步进** | 同上 | 同上 |
| **T+6s** | 兜底：`AevonOpenCardDirect` 自建卡 | 仍未拿到 scene |
| **任意时刻** | 卡已存在 / 卡在途中 | 直接 skip，不重复建 |

**与现有 `AevonAuthSwapTick` 的差别**：只有一处 —— 把三个 Tick 的节拍/超时/兜底合并成一份实现，`style` 只影响日志标签与 30s 授权记录的写入。

### 3.4 安全闸（一条不减）

| 闸 | 位置 | 作用 |
|---|---|---|
| `AevonActivateSwitchOff()` | 判定第一行 | `notify.off` 存在 ⇒ 全部 PASS |
| `AevonShareSwitchOff()` | 分享路 | `share.off` 存在 ⇒ 分享 PASS |
| 黑名单 | 判定早期 | 命中 ⇒ PASS |
| `AevonDivertCapKind` | 判定早期 | 全局 60/60s、同 App 3s/6 次 ⇒ PASS |
| SpringBoard 自身 | 判定早期 | 目标 = springboard ⇒ PASS |
| `AevonSettingsMutable()` | createScene 写 frame 前 | 不可变 settings ⇒ **不写**，跳过（0.2.92 的 trap 教训） |
| `@try` 兜底 | 所有钩子体 | 抛异常 ⇒ 等价于没钩过 |
| `last.step` 落盘 | 钩子体内 | 崩溃前留证 |

**新增一条**：`AevonCardSettle` 的兜底自建卡前，检查 `AevonSpringboardActive()`；SpringBoard 不在前台 ⇒ 不建卡（防止锁屏/关机瞬间抢窗口）。

### 3.5 版本号：0.3.0（六处同步）

| 位置 | 现值 | 新值 |
|---|---|---|
| `control` | `Version: 0.2.92` | `0.3.0` |
| `Sources/Core/Paths.swift` | `version = "0.2.92"` | `0.3.0` |
| `layout/.../AevonPrefs.bundle/Info.plist` | `CFBundleShortVersionString` / `CFBundleVersion` | `0.3.0` |
| `layout/DEBIAN/postinst` | `VERSION="0.2.92"` | `0.3.0` |
| `Root.plist` 页脚 | `Aevon 0.2.92 · …` | `Aevon 0.3.0 · …` |

后续版本依次递增：0.3.1、0.3.2…（小版本号，不跳大版本）。

---

## 四、执行顺序（每步可独立回退）

| # | 步骤 | 判据 | 风险 |
|---|---|---|---|
| 1 | 备份当前 `AevonScene.m` 到 `build/bak-0.3.0-pre/` | 文件存在、字节数一致 | 无 |
| 2 | 升版本号六处 + 审计断言同步 | `grep 0.2.92` 全库为 0 | 无 |
| 3 | 删旧 URL 链（`AevonShareSwapTick` / `AevonPastePromoteTick` / `AevonShareRestore*` / `AevonLandingGuard*` / `AevonOpenDecide` 旧分支），留 `# gone` 反向断言 | audit 反向断言 PASS | 中 |
| 4 | 写 `AevonRouteDecide` + `AevonCardSettle` | 编译过、符号在 | 中 |
| 5 | 接四路适配器 | 四路各有独立日志锚点 | 中 |
| 6 | 本地 `push-gate.py` 十项 | 全 PASS | 无 |
| 7 | 推 CI，等绿 | run success + AUDIT PASS | 低 |
| 8 | 取回 deb，验证 | 版本 / 体积 / hash / 细包字面量 / Mach-O | 无 |

**回退**：任一步失败 ⇒ `git checkout` 回退源码 + 重装 0.2.92 包（已在 dist 保留）。

---

## 五、验证清单（构建物层面）

| 检查 | 期望 |
|---|---|
| `control` Version | `0.3.0` |
| `Architecture` | `iphoneos-arm64e` |
| 载荷白名单 | 只有 dylib / PreferenceBundle / PreferenceLoader |
| Mach-O | thin、cputype=arm64、cpusubtype=arm64e |
| `libswiftCore` | 存在（证明 Swift 未退回 ObjC） |
| 体积 | deb ≤ 520 KB |
| 旧锚点 | `notify: share swap` / `paste promote` / `landing guard` grep 为 0 |
| 新锚点 | `route: decide` / `card settle` / `route: share` / `route: link` / `route: auth` 各命中 ≥1 |
| 断言数 | ≥ 646（不得减少） |

---

## 六、真机验收（交付后由用户执行）

装包 → **重启手机**（不是 respring）→ 按序执行：

| # | 操作 | 期望日志 | 期望观感 |
|---|---|---|---|
| 1 | 备忘录点 http 链接 | `route: link` + `card settle` + `act: frame birth wrote=1` | 直接进卡，**不再全屏** |
| 2 | 文件 App 分享到 QQ | `route: share` + `card settle` | 卡里出现 QQ，文件已发出 |
| 3 | 美的 App 微信登录 | `route: auth` + `auth swap card` | 卡里完成授权，回跳正常 |
| 4 | 联通 App 跳支付宝支付 | `route: auth pay=1` | 卡里出现支付宝收银台 |
| 5 | 桌面点图标 | 无 `route:` 行 | 全屏打开，行为不变 |
| 6 | 打开 `notify.off` 后再做 1–4 | `route: off` | 全部全屏，与未装插件一致 |

**任一步出现安全模式** ⇒ 发 `.ips` + `last.step`，回退 0.2.92。

---

## 七、诚实边界

1. **「完全不出现全屏帧」取决于 `AevonActFrameBirth` 是否命中。** 若某 App 的 settings 是不可变类（0.2.92 的 Safari 就是），我们**跳过写入**（安全优先），那一路仍会全屏一小段 —— 这是刻意的取舍，不是缺陷。
2. **0.3.0 不解决「首帧耗时」**（Safari 366ms / 微信 1972ms）。那由 App 自身冷启动决定，插件无法压缩。
3. **本次不引入新的私有 API。** 全部沿用 0.2.87–0.2.92 已在真机验证过的三个钩子：`_openURLCore`、`_handleOpenApplicationRequest`×4、`_createSceneWithDefinition:…completion:`。
4. **重构的收益是「可维护 + 行为边界清楚」**，不是「四路从不能用到能用」—— 四路在 0.2.92 已经能用，只是代码不可读。
5. **真机验收未做。** 本次只到「构建物验证」这一层，真机由用户执行。
