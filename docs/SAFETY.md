# 安全架构与应急救援

> 目标只有一句：**无论 Aevon 的代码写错到什么程度，都不允许出现「开不了机 / 卡白苹果 / 丢失越狱环境」。**

为了做到这一点，安全不是靠"小心一点"，而是靠四件可验证的事：

1. 包体里**物理上不存在**能改系统的文件（构建闸门强制校验）；
2. 失效开关是**文件存在性**，任何文件管理器都能建；
3. 崩溃循环由 dylib **自己数**，数到 3 次自己永久停用；
4. 恢复路径**不依赖 SpringBoard**，也不依赖 Aevon 自身。

---

## 一、为什么这个设计不会变砖

真正能把设备搞到"开不了机"的操作只有三类：

| 类型 | 例子 | Aevon 是否具备 |
|---|---|---|
| 改系统分区文件 | 替换 `/System/Library/...`、改 `MobileSubstrate.dylib` | **否**，包体白名单外一律构建失败 |
| 装开机自启的守护进程 | `/Library/LaunchDaemons/*.plist` 写坏、死循环 | **否**，从不安装任何 LaunchDaemon / LaunchAgent |
| 破坏越狱环境本身 | 动 `/var/jb` 的 dpkg 数据库、动 bootstrap | **否**，只往两个目录写自己的文件 |

Aevon 只做一件事：**作为 SpringBoard 的一个动态库被加载**。

SpringBoard 崩了会由 launchd 立刻重启，设备仍然在运行，SSH / 越狱环境 / 其他插件全部不受影响。**这是"最坏情况"的天花板**——最多是桌面重启，不是开不了机。

`tools/audit-deb.sh` 就是这个天花板的机械保证：它在 CI 里跑，任何越界文件直接让构建失败，坏包根本到不了你手机上。

---

## 二、五道闸门

### G0 · 硬开关（panic 文件）

```sh
touch /var/mobile/Library/Preferences/com.aevon.panic
```

只要这个文件存在，dylib 的构造函数第一行就返回：**不装任何 hook、不起任何 timer、不创建任何窗口**。

- 不需要终端：Filza / 文件 App 里新建一个空文件即可；
- 不需要重装、不需要卸载、不需要越狱工具；
- 这是整条链路上最可靠的一环，因为它只依赖文件系统。

### G1 · 自禁用标记（state.plist）

```xml
<key>disabled</key><true/>
```

`/var/mobile/Library/Preferences/com.aevon.state.plist` 里的这个键一旦为真，启动时直接退出。这是给"已知有问题但还没查清"的场景用的：比 G0 更"正式"，会记录 `disabledReason`。

### G2 · 崩溃循环断路器

dylib 每次加载做的第一件事，是把自己这次的加载写进 `attempts` 计数：

- 加载后 **60 秒**仍然存活 → 计数清零（说明这次是正常的）；
- 加载后 60 秒内 SpringBoard 又崩了 → 下次加载时计数 +1；
- 5 分钟窗口内累计 **超过 3 次** → 写入 `disabled=true`、`disabledReason=auto:crash-loop`，从此永久不再加载。
- 如果 state 文件**写不进去**（权限异常等）→ 同样**放弃加载**（fail-safe），因为计数器失效就不能保证断路器有效。

关键点：计数是在"任何其他代码之前"写入的。哪怕后面 P1 的场景挂载把 SpringBoard 直接搞崩，这个计数也已经落盘了。

### G3 · 构建闸门（CI 强制）

`tools/audit-deb.sh` 会对每个 deb 做五项检查，任一失败即**拒绝发布**：

1. 高危目录零容忍：`System/`、`private/`、`bin/`、`usr/bin/`、`usr/lib/`、`Library/LaunchDaemons/`、`Library/LaunchAgents/`、`PreferenceLoader/`、`MobileSubstrate.dylib`；
2. 逐文件白名单：只允许 5 个路径（dylib、过滤 plist、4 个救援脚本）；
3. 注入范围：Stage 0 只允许注入 `com.apple.springboard` **一个**进程，多一个就失败；
4. 控制脚本：`postinst`/`prerm` 里出现 `rm -rf /`、`nvram`、`launchctl`、`dpkg --force`、`/System/` 即失败；
5. 架构必须是 `iphoneos-arm64`（rootless），避免装到错误环境。

### G4 · 阶段闸门（人为，但写死验收标准）

每一期（P0…P9）都产出可独立安装、可独立回退的 deb，并且**必须真机通过验收才允许开下一期**。
见 [`STAGES.md`](STAGES.md)。

---

## 三、应急救援（按严重程度排序，从轻到重）

### 级别 0 · 一切正常，只是想关掉

```sh
/var/jb/usr/libexec/aevon/aevon-disable
```

作用：写 panic 文件 + 重启 SpringBoard。**10 秒内回到干净状态。**

### 级别 1 · 桌面能用，但 Aevon 一加载就崩

不需要你做任何事——G2 会自动在第 3 次失败后停用它。想手动立刻确认：

```sh
touch /var/mobile/Library/Preferences/com.aevon.panic
killall -9 SpringBoard
```

### 级别 2 · 桌面起不来（SpringBoard 崩溃循环）

设备**没有变砖**，只是桌面在反复重启。三条路任选，都不需要 Aevon 参与：

1. **Filza 建文件**：进 `var/mobile/Library/Preferences/` → 新建空文件 `com.aevon.panic` → 重启设备。
2. **SSH / USB 终端**（见下节）：执行 `aevon-disable`。
3. **安全模式**：Dopamine 用户按住**音量上键**重新越狱 → 进入无插件安全模式 → 在 Sileo 里卸载 Aevon。

只要 panic 文件在，Aevon 下一次加载就是零行为，桌面必然恢复。

### 级别 3 · 连安全模式都进不去

这一档已经和 Aevon 无关了（我们的包体改不到能造成这种结果的地方），但流程还是给全：

- 强制重启（音量+、音量−、长按电源）；
- 用 Dopamine 重新越狱时按住音量上键；
- 仍失败 → 用电脑上的 Dopamine/palera1n 走 recovery，或 `--force-revert` 后重越狱；
- 越狱环境重装后再 `dpkg -r com.aevon.aevon`。

---

## 四、SSH / USB 通道（建议现在就配好，出事再配就晚了）

**前提**：设备已装 OpenSSH，且改过 root 密码（默认 `alpine`，务必改）。

Windows：

```powershell
# 1. 装 usbmuxd 工具（含 iproxy）
#    scoop install libimobiledevice  或  brew install libimobiledevice
# 2. 端口转发 2222 -> 设备 22
iproxy 2222 22
# 3. 另开一个窗口
ssh root@127.0.0.1 -p 2222
```

进设备后：

```sh
aevon-status          # 一眼看清是否生效、为什么停用
aevon-disable         # 立刻停用
aevon-enable          # 清状态重新开始
aevon-uninstall       # 卸载
```

如果没装 OpenSSH，装一个（Sileo 搜 OpenSSH），这是所有救援里性价比最高的一件事。

---

## 五、安装前的固定动作

每次装新 deb 之前做这四步，不要跳：

1. **体检 + 快照**（把仓库里的 `tools/preflight.sh` 拷到设备上，root 执行）：
   ```sh
   sh /var/mobile/preflight.sh
   ```
   它会检查 rootless 环境、ElleKit/Substrate、dpkg 健康、可用空间、**panic 文件是否真的可写**，并把当前状态存成 `/var/mobile/Library/Logs/Aevon/baseline-*.txt`。
   最后一行不是 `PREFLIGHT: PASS` 就不要装。

2. **确认安全模式可用**：装任何东西之前先试一次"按住音量上键重新越狱"，确认你能进去。

3. **保留上一版 deb**：仓库 Release 里每个 tag 都有，回退就是 `dpkg -i 旧包.deb`。

4. **一次只装一个阶段**：不要"顺手"把 P2 和 P3 一起推上去。

---

## 六、设计红线（后续所有阶段都必须遵守）

- 不安装 LaunchDaemon / LaunchAgent；
- 不写 `/System`、不写 `/usr/lib`、不改 `MobileSubstrate.dylib`；
- 不在 `postinst` / `prerm` 里重启 SpringBoard（激活永远是人的决定）；
- 不 hook 任何"启动早期"的进程（launchd、backboardd 需要单独评审后才可加入）；
- 所有新 hook 必须写在闸门检查**之后**；
- 任何阶段只要 `audit-deb.sh` 不过，就不发布。
