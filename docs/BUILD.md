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

## 三、从 CI 取回产物

```bash
GH_TOKEN=xxx python3 tools/fetch-deb.py      # 取最近一次成功的构建，落到 dist/ 并自动审计
GH_TOKEN=xxx python3 tools/ci-status.py --logs   # 盯构建；失败时打印关键报错
```

## 四、安装

**前提**：roothide 越狱，已装 ElleKit（roothide 自带）与 PreferenceLoader。

Sileo 里打开 deb 安装。装完**不会**重启桌面（`postinst` 故意不重启），
但会 `killall -9 Preferences`，让「设置」下次打开时重新读取入口 —— 0.0.2 的入口不显示就是这个缓存。

> 0.0.2 → 0.0.3 会换包 id（`com.aevon.aevon` → `com.aevon`）。
> control 里带 `Replaces` / `Conflicts`，dpkg 会先卸旧包再装新包，不会文件冲突。

## 五、回退

Sileo 里卸载 `Aevon`，然后用越狱工具重启一次桌面。

状态文件保留（避免"重装即重新武装"）；要彻底重置就在设置里点「清除崩溃计数」。

## 六、常见构建失败

| 报错 | 原因 | 处理 |
|---|---|---|
| `SDK "iphoneos16.5" cannot be located` | SDK 没放对位置 | 确认 `$THEOS/sdks/iPhoneOS16.5.sdk` 存在 |
| `error: unable to find utility "swiftc"` | 缺 Swift 工具链 | macOS 装 Xcode（不是 CLT）；Linux 用 theos 自带工具链 |
| `ldid: command not found` | 缺签名工具 | macOS `brew install ldid`，Linux `apt install ldid` |
| `audit: unexpected path` | layout 里加了白名单外的文件 | 先想清楚该不该进包，再改白名单（刻意的二次确认） |
| `audit: cpusubtype=0` | 产出成了 arm64 | `Makefile` 的 `ARCHS` 被改动 |
| `audit: no libswiftCore` | 源码退回 ObjC | 检查 `_FILES` 里的 `.swift` |
| `audit: over budget` | 体积超预算 | 先看是哪一项变大，再决定删功能还是抬预算 |
