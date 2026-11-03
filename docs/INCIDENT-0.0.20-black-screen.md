# 0.0.20 黑屏事故复盘（2026-11-03 · Aevon(19)）

范围：只讲「点第 4 个按钮 → 整机黑屏 → 只能重启」这一次。根因、证据、以及 0.0.21 的处置。

---

## 一、现象

| 时间 | 事件 |
|---|---|
| 11:07:31 | `boot ok: version 0.0.20, pid 37309` |
| 11:07:54 | 点「建窗取证」，三个场景全部走完，最后一行 `win: KB stopping before window` |
| 11:08:31 | `heartbeat: 60s uptime reached` ← **SpringBoard 进程还活着** |
| 11:11:50 | `boot ok: version 0.0.20, pid 909` ← 手动重启后的新进程 |

中间没有任何崩溃、没有安全模式、没有新的日志行。屏幕全黑，触摸无响应。

**关键判据：没有崩溃却全黑，说明 SpringBoard 在跑但不画。** 这一点决定了排查方向：
不是「哪个调用把进程杀了」，而是「哪个调用把画面拿走了」。

---

## 二、日志里的三张表

三个场景走的是同一条路，而且每一处都**成功**了：

| | APP（抖音） | SB（com.apple.springboard） | KB（remote-keyboard） |
|---|---|---|---|
| activate 前 | `hosting=no active=no` | `hosting=no active=no` | `hosting=no active=no` |
| activate 后 | **`hosting=yes active=yes`** | **`hosting=yes active=yes`** | **`hosting=yes active=yes`** |
| view sublayers | 0 → **1** | 0 → **1** | 0 → **1** |
| host container view | absent → **`_UISceneLayerHostContainerView`** | 同左 | 同左 |
| view superview | **`nil`**（全程） | **`nil`** | **`nil`** |

`superview=nil` 是这次事故的核心事实：presenter 把场景的图层接管了，
挂进了一个**不属于任何窗口**的 view。于是：

- 图层没有落在任何 window 上 ⇒ 不绘制 ⇒ 黑；
- 系统原来的 presenter 失去呈现 ⇒ 连桌面和 App 都不画；
- 没有任何视图可命中 ⇒ 触摸无目标 ⇒ 点不动；
- 代码里从来没有 `deactivate` / `invalidate`（0.0.20 源码里这两个词只出现在注释和选择子清单中），
  ⇒ 这个状态**没有任何路径能回去** ⇒ 只能重启。

---

## 三、母本为什么不黑

`analysis/extracts/stheno-selector-surface.txt` 是 Stheno.dylib 的选择子面，
里面**没有 `activate`**。母本相关的只有：

- `createPresenterWithIdentifier:priority:` ← 落在 `__TEXT,__const`，是 **hook 目标**
- `initWithSceneLayer:`

配套 `analysis/scene-lifecycle-model.md` 第 5 节列出她的 hook 组：
`UIScenePresentationManagerHook`、`UIApplicationSceneDeactivationManagerHook`、`FBSceneHook`。

结论：**母本从不自己建 presenter 再激活它。** 她在系统创建 presenter 的那一刻拦下来，
拿走**系统自己已经激活好**的那个 presenter 的 `presentationView`，放进自己的 `SthenoWindow`。

系统的真实顺序（`analysis/incident-2026-10-13-black-content-round6.md` 第 99-109 行）：

```
self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
[self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) { ... }];
[self.presenter activate];
self.view = self.presenter.presentationView;
```

`activate` 是**视图归属者**自己做的事，它后面紧跟的那一步是「把 view 放进窗口」。
第三方插进来只做前半截，就是抢了别人的画面却无处安放。

---

## 四、0.0.21 的处置

1. **删掉全部 `-activate` 调用**，删掉 `present()` 与 `state()`。
2. **不再碰桌面场景和键盘场景**。顶掉桌面的 presentation 就是整机黑屏，收益为零。
3. **改成读**：`uiPresentationManager` → `_scenePresenterOwner`（ivar）→
   `activePrioritizedPresenter`（零参属性）→ `presentationView` → 父视图链 + 所属 window。
   全部是 getter，一个写操作都没有。
4. **按母本装旁听 hook**：`createPresenterWithIdentifier:priority:` /
   `createPresenterWithIdentifier:` / `activate` / `deactivate` / `invalidate`，
   原实现照调，只多写一行日志。
5. **五重兜底**（这次事故对旧闸门的教训是：崩溃计数看不见黑屏）：
   - latch 文件先落盘、全量还原后才删；残留即上轮没退出 ⇒ 本轮不装
   - C 侧全有或全无：路由两端拿不到原 IMP 就整批回滚，返回 0
   - 写前解页保护（`vm_protect`）、写后回读校验 —— 写不进去就当场放弃，不留半截
   - 软 30 秒：一条系统流量都没有就提前还原
   - 硬 90 秒：无条件还原
   - 还原失败时**保留**原 IMP 句柄并如实上报 `hooks still live=N`，
     而不是把句柄清空（清空等于把「卡住的 hook」变成「永久的 hook」）

---

## 五、下次不要重复的

- 任何让 presenter `hosting` 从 no 变 yes 的调用，**必须**同时保证它的 view 已经在窗口里，
  并且有一个必然执行的 `deactivate`。缺一条就是黑屏。
- 「进程没死」不等于「没事」。崩溃计数、心跳、步骤标记三样都不覆盖「活着但不画」。
- 母本能跑 ⇒ 她的路线存在；但她**不做**的动作，我们做了就是新发明，代价自己付。
