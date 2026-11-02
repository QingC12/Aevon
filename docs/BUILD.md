# 构建与安装

目标环境：**roothide 越狱**（bootstrap 在 `/var/containers/Bundle/Application/.jbroot-XXXXXXXX`），
设备为 arm64e，所以包是 `iphoneos-arm64e`，二进制是 arm64e。

## 一、构建（GitHub Actions）

仓库是 public，Actions 不消耗额度。推送到 `main` 自动构建**一次**，产物在 **Actions → Artifacts → aevon-deb**。

- 不打 tag，也不建 Release：每次构建只出一个 deb，下载后本地留存。
- 连续 push 会取消上一次未完成的构建（`concurrency`），不浪费额度。

```
macOS 14 runner
  ├─ clone roothide/theos（递归）        ← 必须用这个分支，原版 theos 没有 roothide scheme
  ├─ sparse-checkout theos/sdks → iPhoneOS16.5.sdk
  ├─ brew install ldid
  ├─ 校验 control 的 Version 与源码 kAevonVersion 一致、Architecture=iphoneos-arm64e
  ├─ make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
  ├─ 断言只产出 1 个 deb
  ├─ tools/audit-deb.sh  ← 安全闸门：结构 / 白名单 / arm64e / 无 Description
  └─ upload artifact
```

## 二、本地构建（macOS / Linux）

Windows 上无法编译 tweak，必须用 macOS 或 Linux + Theos。

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
./tools/audit-deb.sh packages/*.deb
```

产物：`packages/com.aevon.aevon_0.0.2_iphoneos-arm64e.deb`

## 三、安装

**前提**：roothide 越狱，已装 ElleKit（roothide 自带）与 PreferenceLoader。

在 Sileo / Zebra 里直接打开 deb 安装即可。装完**不会**自动重启桌面（`postinst` 故意不重启）。

> 这个空窗期就是留给你确认"设置里能看到 Aevon 一行"的时间。

## 四、回退

在 Sileo 里卸载 `Aevon`，然后用越狱工具重启一次桌面。

状态文件会保留（避免"重装即重新武装"），需要彻底重置就在设置里点「清除崩溃计数」。

## 五、常见构建失败

| 报错 | 原因 | 处理 |
|---|---|---|
| `error: SDK "iphoneos16.5" cannot be located` | SDK 没放对位置 | 确认 `$THEOS/sdks/iPhoneOS16.5.sdk` 存在 |
| `ldid: command not found` | 缺签名工具 | macOS `brew install ldid`，Linux `apt install ldid` |
| `audit: payload 仍带 var/jb 前缀` | 用了原版 theos，scheme 没生效 | 换成 `roothide/theos` |
| `audit: 不含 arm64e 切片` | ARCHS 没设成 arm64e | `export ARCHS := arm64e` |
| `audit: 白名单外文件` | layout 里加了新文件 | 同时更新 `tools/audit-deb.sh` 白名单，这是刻意的二次确认 |
