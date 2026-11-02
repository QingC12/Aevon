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
