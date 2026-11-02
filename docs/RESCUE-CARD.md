# 应急卡（存到手机相册，或打印）

## 出事第一反应：建一个空文件

**路径**

```
/var/mobile/Library/Preferences/com.aevon.panic
```

- Filza / 文件 App → 进 `var/mobile/Library/Preferences/` → 新建空文件 → 命名 `com.aevon.panic`
- 建完重启设备。Aevon 从此**一行代码都不执行**。

---

## 命令版（SSH / NewTerm）

```sh
aevon-disable      # 停用 + 重启桌面
aevon-enable       # 清状态重新开始
aevon-status       # 看当前状态
aevon-uninstall    # 彻底卸载
```

完整路径：`/var/jb/usr/libexec/aevon/`

---

## 进不去桌面（SpringBoard 崩溃循环）

设备**没有变砖**，只是桌面在反复重启。按顺序试：

1. Filza 建上面的 panic 文件 → 重启
2. `iproxy 2222 22` + `ssh root@127.0.0.1 -p 2222` → `aevon-disable`
3. 按住**音量上键**重新越狱 → 安全模式 → Sileo 卸载 Aevon

---

## 连安全模式都进不去

1. 强制重启：音量+ → 音量− → 长按电源键
2. 重新越狱时**按住音量上键**
3. 还不行：电脑上用 Dopamine/palera1n `--force-revert` 后重新越狱

---

## 三条不要做

- 不要 `rm -rf /var/jb`（那是越狱环境本体）
- 不要在崩溃循环中反复"再装一次试试"
- 不要在没确认 SSH 可用之前装下一期
