# 构建与安装

目标环境：**roothide 越狱**（bootstrap 在 `/var/containers/Bundle/Application/.jbroot-XXXXXXXX`），
设备 A12 及以上，所以包是 `iphoneos-arm64e`，两个二进制都是 **thin arm64e**，不产出 arm64 切片。

源码语言：**Swift**（一个 3 行的 C 文件负责 dylib 的构造函数，Swift 无法声明）。

## 一、构建（GitHub Actions）

推到 `main` 自动构建**一次**，产物在 **Actions → Artifacts → aevon-deb**。

- 不打 tag，也不建 Release。
- 连续 push 会取消上一次未完成的构建（`concurrency`）。
- **只改 `docs/`、`*.md`、`dist/` 的提交不触发构建**（`paths-ignore`），所以写文档不占构建额度。

```
macOS 14 runner
  ├─ 还原 .theos 缓存（theos + iPhoneOS16.5.sdk，命中时约 10 秒）
  ├─ 首次才 clone roothide/theos + sparse-checkout SDK
  ├─ ldid：优先 $THEOS/bin/ldid → 系统 ldid → brew（下载走独立缓存）
  ├─ preflight：Version 三处一致、Architecture=iphoneos-arm64e、
  │             Makefile 里 ARCHS/roothide 承诺未被改动、swiftc 可用
  ├─ make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
  ├─ 断言只产出 1 个 deb
  ├─ tools/audit-deb.sh   ← 闸门：见下表
  ├─ tools/name-deb.sh    ← 产物改名为 com.Aevon_<version>-arm64e.deb
  └─ upload artifact
```

### 审计闸门（`tools/audit-deb.sh` → `tools/audit-deb.py`）

| 检查 | 断言 |
|---|---|
| control | `Package: com.aevon`、`Architecture: iphoneos-arm64e`、**无 `Description`** |
| 载荷 | 只允许 `Library/MobileSubstrate/DynamicLibraries/`、`Library/PreferenceBundles/AevonPrefs.bundle/`、`Library/PreferenceLoader/Preferences/`；禁止 `var/jb` 前缀与 `usr/` |
| Mach-O | 必须是 **thin**（不是 fat）、`cputype=arm64`、`cpusubtype=arm64e` |
| Swift 实证 | 二进制里必须能找到 `libswiftCore`，否则说明构建退回了 ObjC |
| 设置入口 | `entry.bundle` = `AevonPrefs` = `CFBundleExecutable`；`detail` 以 `RootListController` 结尾；`Root.plist` 引用的 8 个子面板全部存在 |
| 日志契约 | dylib 里必须有 `/var/mobile/Aevon.log` |
| 体积预算 | deb ≤ 520 KB、tweak ≤ 320 KB、bundle ≤ 400 KB（超过即失败） |

体积预算不是目标值，是**棘轮**：功能增加可以，但必须先说明为什么变大。

## 二、本地构建（macOS / Linux）

Windows 上无法编译，必须 macOS 或 Linux + Theos（Swift 工具链来自 Xcode 或 theos 的 linux 工具链）。

```bash
export THEOS=~/theos
export PATH=$THEOS/bin:$PATH

# 只需要一次
git clone --recursive https://github.com/roothide/theos.git $THEOS
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
(cd /tmp/sdks && git sparse-checkout set iPhoneOS16.5.sdk)
cp -R /tmp/sdks/iPhoneOS16.5.sdk $THEOS/sdks/

# 每次
cd Aevon
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
bash ./tools/audit-deb.sh packages/*.deb
bash ./tools/name-deb.sh packages dist
```

产物：`dist/com.Aevon_<version>-arm64e.deb`

> 文件名是 `com.Aevon_…`，包的 id 是 `com.aevon`。dpkg 规定包 id 只能用全小写，
> 两者不能混为一谈；改名逻辑只在 `tools/name-deb.sh` 里，以后不用手写版本号。

## 三、推送前必须先过本地闸门

CI 一次失败要等两分钟；同样的错误在本地几秒钟就能查出来。所以推送**不是**一条
`git push`，而是三步，中间那步是硬性的：

```bash
python3 tools/push-gate.py --list      # 1. 自检 + 看清将要推送的每一个文件
git add -p                             # 2. 只把该入库的文件加入索引（逐块确认）
GH_TOKEN=xxx python3 tools/gh-push.py "message"   # 3. 推送（内部会再跑一次闸门）
```

`gh-push.py` 会自己调用闸门，**闸门不过就直接退出**，不会产生一次注定失败的构建。
确实需要绕过时用 `AEVON_SKIP_GATE=1`，但那是例外，不是捷径。

闸门检查十项，都是「本地能查、CI 才会报」的类别：

| # | 检查 | 它拦住的具体事故 |
|---|---|---|
| 1 | 清单 | 交付报告 HTML、deb、构建产物混进仓库 |
| 2 | 完整性 | 新写的 `.swift` 忘了 `git add`，CI 编译不到它 |
| 3 | 编译覆盖 | 文件在 `Sources/` 里但没进 Makefile 的 `_FILES` |
| 4 | 版本号 | control / Paths / Info.plist / postinst 四处不一致 |
| 5 | 脚本语法 | `tools/*.py` 语法错误 |
| 6 | 面板 plist | 解析失败、根页面过空、八个面板内容雷同 |
| 7 | 按钮动作 | plist 里的 `action:` 没有对应的 `@objc func`（死按钮） |
| 8 | 审计断言 | `audit-deb.py` grep 的字符串在源码里不存在（必失败） |
| 9 | Swift 静态 | 括号不平衡、`try!` / `as!`、SpringBoard 里裸用 `UIApplication.shared` |
| 10 | 生成器同步 | 面板 plist 与 `gen-settings.py` 的输出不一致（改完没重新生成） |

第 8 项是专门为过去那几次「构建失败」加的：审计脚本断言了一个被 strip 掉的
Swift 类型名，或者一段字符串插值，而那种字符串根本不会出现在 release 二进制里。
现在本地就能发现，不必花一次 CI。

### 什么文件可以进仓库

只推「构建必需 + 工程文档」：

```
Makefile  control  .gitignore  .gitattributes  README.md
Aevon.plist  *-Bridging-Header.h
Sources/**           源码
layout/**            打进 deb 的所有文件
tools/**             构建、审计、闸门脚本
.github/workflows/** CI
docs/*.md            工程文档（BUILD / SAFETY / STAGES / REVERSE-NOTES / RESCUE-CARD）
```

**不进仓库**：交付报告 `docs/Aevon-*.html`、`dist/`、`*.deb`、日志、截图、`build/`、
`packages/`、`__pycache__`。前两类已在 `.gitignore` 里；闸门第一项还会再挡一次，
双保险，因为 `gh-push.py` 做的是**全量快照** —— 只要进了索引，就会被推上去。

## 四、从 CI 取回产物

```bash
GH_TOKEN=xxx python3 tools/fetch-deb.py      # 取最近一次成功的构建，落到 dist/ 并自动审计
GH_TOKEN=xxx python3 tools/ci-status.py --logs   # 盯构建；失败时打印关键报错
```

## 五、安装

**前提**：roothide 越狱，已装 ElleKit（roothide 自带）与 PreferenceLoader。

Sileo 里打开 deb 安装。装完**不会**重启桌面（`postinst` 故意不重启），
但会 `killall -9 Preferences`，让「设置」下次打开时重新读取入口 —— 0.0.2 的入口不显示就是这个缓存。

> 0.0.2 → 0.0.3 会换包 id（`com.aevon.aevon` → `com.aevon`）。
> control 里带 `Replaces` / `Conflicts`，dpkg 会先卸旧包再装新包，不会文件冲突。

## 六、回退

Sileo 里卸载 `Aevon`，然后用越狱工具重启一次桌面。

状态文件保留（避免"重装即重新武装"）；要彻底重置就在设置里点「清除崩溃计数」。

## 七、常见构建失败

| 报错 | 原因 | 处理 |
|---|---|---|
| `SDK "iphoneos16.5" cannot be located` | SDK 没放对位置 | 确认 `$THEOS/sdks/iPhoneOS16.5.sdk` 存在 |
| `error: unable to find utility "swiftc"` | 缺 Swift 工具链 | macOS 装 Xcode（不是 CLT）；Linux 用 theos 自带工具链 |
| `ldid: command not found` | 缺签名工具 | macOS `brew install ldid`，Linux `apt install ldid` |
| `audit: unexpected path` | layout 里加了白名单外的文件 | 先想清楚该不该进包，再改白名单（刻意的二次确认） |
| `audit: cpusubtype=0` | 产出成了 arm64 | `Makefile` 的 `ARCHS` 被改动 |
| `audit: no libswiftCore` | 源码退回 ObjC | 检查 `_FILES` 里的 `.swift` |
| `audit: over budget` | 体积超预算 | 先看是哪一项变大，再决定删功能还是抬预算 |

## 八、窗口与场景：先核对调用点，再谈浮窗

浮窗不是塞进桌面的视图，是自建承载者去装 App 已有的场景。这套接口全是私有 API，
**类名、归属类、类型编码三样里错一样就是 SpringBoard 崩**，所以这一阶段只做测量。
设置 → Aevon → 窗口与场景 → 探针，三个按钮，都在 SpringBoard 里跑，都只读：

| 按钮 | 日志前缀 | 回答什么 | 请求文件内容 |
|---|---|---|---|
| 转储场景与窗口 | `scene:` | 类在不在、活体场景与窗口清单、承载视图在哪 | `tree` |
| 转储承载接口面 | `scene2:` | 指定类的方法表与真实签名、App 的场景句柄 | `api` |
| 核对调用点 | `calls:` | 母本 123 条调用，各自落在哪个类、签名是什么 | `calls` |

`tools/compare-calls.py` 把第三段的 dump 和逆向基准逐条对齐：

```bash
python tools/compare-calls.py /path/to/Aevon.log          # 只看结论
python tools/compare-calls.py /path/to/Aevon.log --md t.md # 附全量表格
```

判定有五种，含义不同，**不能混着读**：

| 判定 | 意思 | 该怎么办 |
|---|---|---|
| `MATCH` | 归属类与签名都和逆向记录一致 | 这条可以照着写 |
| `PRESENT` | 本机有定义，逆向只记了调用、没记归属 | 本次实测即新基准，需回填逆向资料 |
| `OWNER-DIFF` | 归属类不是逆向记的那个 | 先解释清楚再写；落错类会返回一个值，然后在错路上继续走 |
| `ENCODING-DIFF` | 签名不一致 | 按旧签名调用必崩 |
| `ABSENT` | 本机没有任何类定义它（dump 明确写了 `n=0`） | 这条路在这台 iOS 上不存在 |
| `NOT-IN-DUMP` | dump 里没有这一行 | **不是结论**：日志截断了，重跑一次 |

最后一条是刻意的：把「没有这一行」也算成 `ABSENT`，会得到「118 条调用在这台
iOS 上不存在」这种极具说服力又完全错误的答案。工具遇到 `NOT-IN-DUMP` 直接退出
并拒绝给结论（退出码 2）。

退出码：`0` 全部对齐 / `1` 有未对齐 / `2` 日志本身不可用。
**在退出码 0 之前不创建任何窗口** —— 这是定档的顺序，不是建议。

### 8.1 第三段探针为什么搬到了后台线程（0.0.7 的崩溃）

0.0.7 点「核对调用点」六秒后 SpringBoard 崩溃进安全模式，日志停在
`calls: definition begin … classes=99379`，**一行结果都没有**。

三件事在日志里长得一模一样：主线程被杀、内存被杀、某一个类有毒。原来的实现三个都占：

1. 扫 9.9 万个类是在**主线程**上分批跑的；
2. 每扫 600 个类才让出 10 ms，期间一次进度都不写；
3. 只有全部扫完才输出，所以中途死掉等于什么都没留下。

0.0.8 改了三处，一一对应：

| 改动 | 治哪个 | 判据 |
|---|---|---|
| 扫描搬到 `DispatchQueue(label:qos:.utility)` | 主线程被杀 / 主线程死锁 | 主线程不再参与，SpringBoard 不会被拖走 |
| 每 250 个类一个 `autoreleasepool`，并写一行 `calls: scan reached <i> <类名> rss=<N>mb` | 内存被杀 / 某个类有毒 | 最后一行进度就是死亡位置；rss 一路爬=内存，平稳=某类 |
| 结束行带 `upto=A of B` 与 `secs=` | 半截 dump 被当成结论 | 工具见 `upto < of` 直接拒绝下判断 |

`tools/compare-calls.py` 现在会先打印**最后一次进度**，再判断：

- 只有 begin、没有 end，且没有结果行 → 打印死亡位置，退出码 2；
- 有 end 但 `upto < of` → `[PARTIAL]`，退出码 2，明确说「排在后面的 n=0 不是结论」；
- 两者都没有问题 → 才进入六种判定的对齐表。

这一条是刻意的：一份扫了一半的 dump，比没有 dump 危险得多，因为它会把「还没扫到」
印成 `n=0`，而 `n=0` 的读法是「这台 iOS 上不存在」。

### 8.2 0.0.8 还是死了，所以这次先让探针能说出自己死在哪（0.0.9）

0.0.8 的日志比 0.0.7 更短，也更有信息量：

```
20:59:27 prefs: scene probe requested -> calls ok
20:59:27 calls: definition begin v1 targets=123 classes=99374
20:59:33 boot ok: version 0.0.8, pid 34326
```

搬后台线程之后**连一行 `scan reached` 都没有**，而那一行本来在第一个 250 类
之后就该出现。两条线索因此成立：

1. 第一条 250 类的块都没跑完 —— 耗时以毫秒计，六秒不是扫描时长，是 respring 时长；
2. 「主线程被杀」这个假设被排除（扫描已经不在主线程），剩下的是**某个类有毒**、
   **内存被杀**、以及**与 SpringBoard 自己的类实现过程撞车**（请求到达时是开机后
   12 秒，进程正在 realize 类、attach 方法表；这时去读同一个类的 method list 是
   典型的 use-after-free）。

0.0.9 不再猜，改成让探针**自己留下证据**：

| 改动 | 治哪个 | 判据（下次日志里看什么） |
|---|---|---|
| 每个类动手之前写 4 字节序号 + 类名到 `call.state`（一次 open，`lseek`+`write`+`ftruncate`，不走 Log 也不分配） | 无论怎么死都能知道停在哪 | 下次开机第一行 `calls: previous scan died at <i> <类名>` |
| 开机读 `call.state`，把那个类写进 `call.skip`，扫描时跳过 | 同样的死法不会重来 | `skip=N`；每跑一次就多排除一个类 |
| `SB*`/`FB*`/`UI*`/`_UI*` 家族排到队首，走完就输出 `calls: phase1 by …` | 后半个进程死掉不连累结论 | `calls: phase1 done hits=… of 123` |
| 扫描延后 6 秒启动 | 与类的 realize/attach 撞车 | 日志里 begin 与 phase1 的 secs |
| 每块读一次 rss，>220MB 停 | 内存被杀 | 结束行的 `stopped at the memory ceiling` |
| `_NSZombie_` 类直接跳过 | 僵尸类是运行时按需新建的，最可能正在被写 | `skip=` 计数 |
| `calls: ordering walk over N classes` 单独一行 | 主线程那一遍（9.9 万个类名）死掉，和后台扫描死掉分开 | 日志停在这一行 = 死的是排序，不是扫描 |

结论仍然是原来那条：`tools/compare-calls.py` 退出码 0 之前不创建任何窗口。
新增的 `phase1` 段**不是结论**（后面的类也可能是归属），工具只在没有结束行时
才拿它出来，并且一样退出码 2。

### 8.3 内存储是「峰值」，不是「现在用的」（0.0.9 第一次真机跑完的收获）

0.0.9 上机两次，「核对调用点」都不再进安全模式，但两次都以同一行结束：

```
calls: definition end v2 missing=103 capped=1 upto=250 of 99482 skip=1 secs=6 stopped at the memory ceiling
```

`upto=250` —— 正好是第一个分块的边界，一次都没有输出 `scan reached`。原因是我把
内存闸写成了绝对值：

```swift
if residentMegabytes() > 220 { ... }     // 错
```

`getrusage(RUSAGE_SELF).ru_maxrss` 是**进程生命周期内的峰值**，不是当前占用。
SpringBoard 开机后的峰值本来就几百 MB，所以这个闸在第一个分块就恒真 ——
它没在防 runaway，它在无条件停机。

三处改动（0.0.10）：

| 改动 | 理由 |
|---|---|
| `let baseMB = residentMegabytes()`，闸改成 `rss - baseMB > 200` | 峰值只能比，不能当阈值；比的是「这次扫描把峰值推高了多少」 |
| 进度行**挪到**内存闸之前 | 0.0.9 那次闸先 break，所以日志里连一个 rss 数字都没有 —— 有数字才有得争 |
| 删掉 `guard !callQueue.isEmpty` 分支 | 空队列本来就走 `upto=0 of 0`，这个分支永远不成立，白占体积 |

顺带一条实测结论：`skip=1` 不是黑名单，是 `_NSZombie_*` 那一个类 ——
0.0.9 之前不可能有 `call.skip` 文件（那版才第一次写它），所以那个 1 只可能来自
僵尸类分支。**这台设备的 SpringBoard 进程里有僵尸类**，也就是说
`class_copyMethodList` 随时可能撞上「正在被新建的类」—— 与 0.0.7/0.0.8 的死法吻合。

### 8.4 答案拿到了，却因为分块跨过边界而没打印（0.0.10 → 0.0.11）

0.0.10 的日志是第一次「扫描活下来了、但什么都没输出」：

```
21:27:58 begin v2 targets=123 classes=99372 phase1=9826 skip=2
21:28:05 scan reached 9750 NSKeyValueFastMutableOrderedSet1 rss=368mb
21:28:12 boot ok: version 0.0.10, pid 34913
21:28:12 calls: previous scan died at 9827 __NSGenericDeallocHandler
```

三件事同时成立，每一件都可以单独读错：

1. **rss 全段 367~368 MB 一条线** —— 内存闸没触发，这轮不是内存问题。
2. **首启 6 秒延迟生效**（begin 到第一个 `scan reached` 正好 7 秒），撞车假设排除。
3. **死在 9827，而边界是 9826** —— 家族段 9826 个类全部走完、一次没崩；死的那个类是
   **越过边界后的第二个类**，名字带 `__` 前缀（运行时铸造的辅助类，跟
   `_NSZombie_` 一类东西）。

**真正的 bug 是我自己的**：分块固定 250 个，跨过边界的那一块从 9750 走到 10000，
而 `phase1` 的打印挂在「块结束」上 —— 于是 9826 个类的答案已经全部握在手里，
却在走到 10000 之前被杀，一行都没落地。**收集成功不等于证据成立**，打印点必须
和被测量的边界对齐。

0.0.11 三处改动：

| 改动 | 理由 | 判据 |
|---|---|---|
| 分块终点改成 `min(cursor+250, stop)`，`stop = min(phase1, ceiling)` | 没有哪一块跨过边界，边界自身就是块边界 | 日志里必有 `calls: phase1 done hits=… of 123` |
| 默认只走家族段（`scope=phase1`，9826 / 99372） | 越界第一个类就带走进程，而 9826 已被两次证明安全；尾巴另有办法（定点核对，见下） | 结束行 `upto=9826 of 99372`，`upto < of` 是**选的**不是**被害的** |
| `call.skip` 加版本戳（`!0.0.11`） | 0.0.9 是**干净停**（内存闸）却留着死亡标记，0.0.10 开机把它当死亡学了进去，`skip=2` 里有一个是假的。假跳过 = 表里的静默漏判 | 换版本自动作废，不用手工清 |

`tools/compare-calls.py` 跟着认 `scope=phase1`：

- `upto < of` 且带 `scope=phase1` → **不再**报 `[PARTIAL]`，改报 `[scope=phase1]`；
- `n=0` 记 **OUT-OF-SCOPE**（「不在这几个家族里」）而不是 ABSENT（「本机没有」），
  并且一样计入未对齐数 —— 没扫到不能当没定义。

**为什么不再硬啃 9.9 万个类**：越界后的类正在被运行时铸造，两次实证都能带走进程；
而 123 条选择子全是 `SB*/FB*/UI*/NS*/LS*/CA*` 的调用，家族段就是它们该在的地方。
剩下的少数 OUT-OF-SCOPE 走**定点核对**（拿逆向记录里的归属类名直接问
`class_getInstanceMethod`），那是几十个类的事，不是九万个。

**顺带瘦身**：第二段探针（`scene2:` 类普查 / 方法表 / 已装应用场景句柄 / FrontBoard
门面）数据已全部落在 `docs/REVERSE-NOTES.md`，源码删掉 12.5 KB（含专用数组与
`dumpIvars`、无人调用的 `matrix` 类重载），腾出体积给调用点这一路。面板上的按钮
保留 —— 删行会改面板，而面板不是这轮要测的东西 —— 按下只会写一行
`scene2: retired in 0.0.11`。

### 8.5 家族段跑通了：114 / 123（0.0.11 第一次真机成功，0.0.12 放开全程）

0.0.11 的日志（`Aevon(9)`）终于是成功形态：

```
21:49:31 begin v2 targets=123 classes=99373 phase1=9827 scope=phase1 skip=1
21:49:38 phase1 done hits=114 of 123 scanned=9827 secs=6
21:49:38 definition end v2 missing=9 capped=33 upto=9827 of 99373 scope=phase1 skip=1 secs=6
```

- **没有再进安全模式**，9827 个家族类不到 1 秒走完（`secs=6` 里 6 秒是延迟）；
- **114 条有主**，9 条 `n=0`；`compare-calls.py` 判定 **8 MATCH / 106 PRESENT / 9 OUT-OF-SCOPE**，
  0 条 OWNER-DIFF、0 条 ENCODING-DIFF；
- **承载关键的那条坐实了**：`createPresenterWithIdentifier:priority:` → `UIScenePresentationManager`
  `@32@0:8@16q24`，与逆向记录一致（MATCH）。

9 条 OUT-OF-SCOPE 的共同点：逆向记录里没有归属（`逆向: -`），所以不能靠「比对」解决，
只能靠「找到谁定义它」：`_dismissPresentable:…`、`presentPresentable:withOptions:userInfo:`、
`_handleTapOnView:`、`gestureRecognizer:shouldReceivePress:`、
`iconManager:launchIconForIconView:withActions:`、`isApplicationForeground:`、
`materialViewWithRecipe:configuration:initialWeighting:`、`setHandleClick:`、
`settingsWithDuration:timingFunction:`。

它们的类名多半落在家族前缀之外（`MTMaterialView` = CoreMaterial、`BNPresentable` = BannerKit …）。
0.0.12 因此放开两件事：

| 改动 | 理由 |
|---|---|
| 走全程（`scope=full`，99373 个类），不再封顶在边界 | 家族答案在边界处已经落盘、不会丢；9.9 万类实测约几秒，没有理由不扫 |
| 跳过所有 `__` 前缀类（原来只跳 `_NSZombie_`） | 两次带走进程的 `__NSGenericDeallocHandler` 正是这一类；它们是运行时铸造的，123 条选择子不可能住在里面 |
| 每 1 万个类落一次「只有行、没有结束行」的检查点（`emitRows`） | 尾巴里若还有毒类，损失上限是 1 万个类，而不是整趟白跑 |

`scope=full` 之后 `upto < of` 重新是**真截断**，`compare-calls.py` 恢复 `[PARTIAL]` 判定与退出 2；
只有 `upto == of` 才可能给出对齐结论。

### 8.6 死的不是某个类，是「刚越界的那一小片」——所以不再走尾（0.0.13）

0.0.12 第二次在同一个位置被带走，而这次名字换了：

| 版本 | 家族边界 | 死亡标记 | 位置 |
|---|---|---|---|
| 0.0.10 | 9826 | `__NSGenericDeallocHandler` | 边界后第 1 个 |
| 0.0.11 | 9827 | —（停在边界，活） | — |
| 0.0.12 | 9827 | `JSExport` | 边界后第 2 个 |

**同一个类有毒，名字不会变。** 变了，说明毒不是某个类，而是「刚跨出家族段那一
小片」——它们不是 UIKit 家族的类，而是运行时铸造/桥接的那一类（`__` 前缀只是
其中一个子集，`Object`、`JSExport` 都不是 `__` 开头）。按 skip 表一个名字一个
名字跳，等于一次 respring 换一个类，九万个类没有尽头。

顺带修掉一个真 bug：`objc_getClassList` 的第二次调用可以返回**大于缓冲区**的数字
（运行时文档明写，因为两次调用之间可以有新类），而代码按 `0..<count` 去读，就是
从 malloc 块尾巴外面读指针。读到的那东西长得像类，直到你问它要方法表 —— 形状和
「某个类有毒」完全一样。改成 `min(count, total)`。

0.0.13 的做法：**尾巴一次都不走，只读名字。**

| 改动 | 理由 | 判据 |
|---|---|---|
| `stop = callEdge`，`scope=phase1` 恢复 | 9827 个家族类已连续三次证明安全，114 条每次都拿得到 | 结束行 `upto=9827 of 98965 scope=phase1` |
| `callCeiling = classes.count - callSkipped`（不再保留 tail 数组） | `of` 必须仍然是「进程里有几个类」，否则 `upto == of` 会让半截 dump 看起来完整 | `of` 仍是九万多 |
| 族外候选点名：遍历 9.8 万个类**只调 `class_getName`**，名字命中 `presentable/material/handle/tap/icon/foreground/duration/press/setting` 的才留 | `class_getName` 只读 ro 数据、不 realize，是安全的；危险只在要方法表 | `calls: tail cand <类名>` |
| 对候选逐个 `class_getInstanceMethod` / `class_getClassMethod` 问「仍然缺主的那几条」 | 缺哪条问哪条，不写死清单 | `calls: tail owns <类>+ <sel> <编码>` |
| 每问一个候选之前写死亡标记；开机把死者写进 skip 表 | 候选也可能有毒，但一个 respring 只丢一个候选，之前打印的行已经在盘上 | 下次开机 `previous scan died at <i> <类名>` |
| 给 SIGSEGV/SIGBUS/SIGILL/SIGABRT/SIGTRAP 装见证：handler 只写 4 字节信号号，然后恢复默认、重新 raise | 日志每次都停在句中，「毒类 / jetsam / 看门狗」三种死法长得一样；信号号把它们分开，**没有 call.fault 文件**说明是被杀的 | `calls: previous run faulted with signal 11 SIGSEGV` |
| 开机回读时顺手打印死亡类的**所属镜像** | `JSExport` 是名字，`JavaScriptCore` 才是答案 | `calls: that class lives in …` |

`tools/compare-calls.py` 跟着改口径：

- 族外候选给出的归属记 **PRESENT-TAIL**，不与 `PRESENT` 合并 —— 一个是「整个家族
  的方法表读过」，一个是「只问了名字像它的那几百个类」，混起来就是把窄证据冒充宽证据；
- 家族段 `n=0` 且族外候选也没问出来、**且候选点名确实跑完**（见到 `tail done`）时才
  升级成 **NO-IMPLEMENTER**（「本机很可能根本没人实现」），否则仍是 `OUT-OF-SCOPE`；
- NO-IMPLEMENTER 照旧计入未对齐数，退出码不为 0，最后一行的措辞是「这 N 条要不要
  当作结论，你点头才算」—— 工具不替操作者签发结论；
- md 表用 `newline="\n"` 写，Windows 的 CRLF 会把每次重生成变成整文件 diff。

**已知边界**：`class_getInstanceMethod` 会沿继承链返回，所以族外候选报出的类可能
是「继承者」而不是「定义者」。那 9 条在家族段全为 0，所以任何命中都是真实定义，
但归属类名要按「继承链上的一员」来读。

### 8.7 0.0.13 真机跑完：无崩溃，尾巴收口（2026-11-02 22:14）

第一次把「家族段 + 族外点名」两头都跑到底，全程**没有安全模式、没有崩溃信号**：

```
calls: ordering walk over 99378 classes
calls: definition begin v2 targets=123 classes=98965 phase1=9827 scope=phase1 skip=413
calls: phase1 done hits=114 of 123 scanned=9827 secs=7
calls: definition end v2 missing=9 capped=33 upto=9827 of 98965 scope=phase1 skip=413 secs=7
calls: tail owns BSAnimationSettings+ settingsWithDuration:timingFunction: @32@0:8d16@24
…（共 6 条族外归属）
calls: tail done names=4411 owned=6 missing=9 secs=4
```

读法：

| 行 | 数字 | 含义 |
|---|---|---|
| `phase1 done hits=114 of 123` | 114 | 家族段（9827 个 SB/FB/UI/NS/LS/CA/BK/XB 类）里问到的条数，与 0.0.11 / 0.0.12 完全一致，稳定 |
| `missing=9` | 9 | 家族段没问到的条数（其中 2 条后来在族外命中） |
| `tail done names=4411 owned=6 missing=9` | 4411 / 6 | 只读名字挑出 4411 个候选，问出 6 条归属；`missing=9` 是不变量（进尾巴时的缺数），不是剩下的缺数 |
| 无 `previous scan died` / 无 `faulted with signal` | — | 0.0.12 那个「越界即死」的问题被「不读尾巴方法表」彻底绕开 |

`tools/compare-calls.py` 的判定：**MATCH 8 / PRESENT 106 / PRESENT-TAIL 2 / NO-IMPLEMENTER 7**，
退出码 1（因为有 7 条 NO-IMPLEMENTER）。那 7 条逐条定性写在
`docs/REVERSE-NOTES.md` 8.7：一条是母本自己的 delegate 方法，六条是母本想 hook 但
17.3.1 上确实不存在的私有方法，**一条都不在建窗链上**。

对齐表落在 `docs/calls-align-0.0.13.md`（125 行，123 条 + 表头 2 行）。

这轮**不构建**：结论已经到手，版本号留在 0.0.13 不动。

### 8.8 0.0.14 建窗取证：场景建出来了没有（2026-11-02 23:00）

第一次把「读现成场景」和「拿副本建一个」放进同一次按键。两阶段，顺序不能换：
阶段 1 的产物就是阶段 2 的输入。

```
win: begin manager cls=FBSceneManager
win: scenes=N
win: s1 FBScene id=…
win: s1.definition cls=…      ← 逐 ivar，最多 20 行
win: s1.settings cls=…
win: s1.clientSettings cls=…
win: s1.uiPresentationManager cls=…
win: calling _createSceneWithDefinition: now
win: created …  或  win: create failed err=…
```

三条读法：

| 日志末尾 | 结论 |
|---|---|
| `win: created` | 场景建出来了，下一步才是 presenter + window |
| `win: create failed err=` | 系统明确拒绝，错误串指 payload 还是 identifier |
| `calling …` 之后断档 | 调用本身炸了，配 `previous scan died` / `faulted with signal` 一起读 |
| `win: aborted: id would collide` | 安全闸主动放弃：没有 identifier setter，共用会顶掉原场景 |

**为什么先读再建**：母本二进制里没有 `FBSMutableSceneDefinition`、没有
`setSpecification:`、没有任何 settings 字段 setter，只有 `valueForKey:` ——
它自己也是抄现成场景。所以「dump 一个活的 definition 照抄」不是捷径，是同一个方法。

**体积这一课**（记下来，别再走一遍）：

- 删 46 行源码（`dumpClasses` + `chain` + `matrix` + `encoding`）**只减 64 字节**。
  Swift dylib 的重量在类型元数据，不在指令。
- `Aevon_SWIFTFLAGS := -Osize` 一加上，328,848 → **312,496**（-16,352 B，5%）。
  这是唯一有效的杠杆。
- 因此 0.0.14 的 dylib 回到 95% 预算内。

**烧的 run**：5 个。1 个信息量 + 4 个修复：

1. `Info.plist` 被 plistlib 存成二进制，CI 用 `grep "<string>$V</string>"` 找 XML 标签 → 直接 fail。
   **教训：这个文件必须是 FMT_XML，其它 plist 是 FMT_BINARY，不能一刀切。**
2. dylib 328,912 > 327,680。
3. 审计断言用了 `win: scenes=`，而这个字面量在二进制里找不到（拼接被优化）→ 断言改成纯字面量 `win: no template`。
4. `-Osize`。

**没做的**：不建 presenter、不建 window、不设 deactivation reasons。
`activate` 在母本二进制里 hits=0 这件事仍未解，它是下一版的分岔点。
