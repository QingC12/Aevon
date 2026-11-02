# 构建与安装

## 一、构建（GitHub Actions，推荐）

仓库是 public，Actions 不消耗额度。推送到 `main` 自动构建，产物在 Actions 的 **Artifacts → aevon-deb**。

打 tag 会自动发 Release：

```bash
git tag v0.0.1 && git push origin v0.0.1
```

构建流程：

```
macOS 14 runner
  ├─ clone theos/theos（递归）
  ├─ sparse-checkout theos/sdks → iPhoneOS16.5.sdk
  ├─ brew install ldid
  ├─ make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
  ├─ tools/audit-deb.sh  ← 安全闸门，不过就红
  └─ upload artifact
```

## 二、本地构建（macOS / Linux）

Windows 上无法编译 tweak，必须用 macOS 或 Linux + Theos。

```bash
export THEOS=~/theos
export PATH=$THEOS/bin:$PATH

# 只需要一次
git clone --recursive https://github.com/theos/theos.git $THEOS
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
(cd /tmp/sdks && git sparse-checkout set iPhoneOS16.5.sdk)
cp -R /tmp/sdks/iPhoneOS16.5.sdk $THEOS/sdks/

# 每次
cd Aevon
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
./tools/audit-deb.sh packages/*.deb
```

产物：`packages/com.aevon.aevon_0.0.1_iphoneos-arm64.deb`

## 三、安装

**前提**：rootless 越狱（Dopamine / palera1n rootless），已装 ElleKit 或 MobileSubstrate。

在设备上（NewTerm / SSH）：

```sh
dpkg -i /var/mobile/com.aevon.aevon_0.0.1_iphoneos-arm64.deb
sbreload
```

或者在 Sileo/Zebra 里添加本地源/直接打开 deb。

> `postinst` **故意不重启 SpringBoard**。装完之后什么都不会发生，直到你手动 `sbreload`。
> 这个空窗期就是留给你确认"panic 文件可写、SSH 可用"的时间。

安装后立刻验证：

```sh
/var/jb/usr/libexec/aevon/aevon-status
```

期望看到：

```
panic flag : absent
state file : /var/mobile/Library/Preferences/com.aevon.state.plist
  attempts = 1
  version  = 0.0.1
```

约 60 秒后再看一次，`attempts` 应该变成 `0`、并出现 `stableSince`。这就是 Stage 0 的验收标准。

## 四、回退

```sh
dpkg -i 旧版.deb          # 降级
# 或
dpkg -r com.aevon.aevon   # 卸载
sbreload
```

状态文件会保留（避免"重装即重新武装"），需要彻底重置用 `aevon-enable`。

## 五、常见构建失败

| 报错 | 原因 | 处理 |
|---|---|---|
| `error: SDK "iphoneos16.5" cannot be located` | SDK 没放对位置 | 确认 `$THEOS/sdks/iPhoneOS16.5.sdk` 存在 |
| `ldid: command not found` | 缺签名工具 | macOS `brew install ldid`，Linux `apt install ldid` |
| `audit: Architecture 应为 iphoneos-arm64` | 忘了 rootless scheme | `make package THEOS_PACKAGE_SCHEME=rootless` |
| `audit: 白名单外文件` | layout 里加了新文件 | 同时更新 `tools/audit-deb.sh` 白名单，这是刻意的二次确认 |
