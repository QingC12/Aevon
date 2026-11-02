#!/usr/bin/env bash
#
# audit-deb.sh — 安装包安全闸门
#
# 这是「不能变砖」这条要求里唯一可以机械验证的部分。
# 它把 deb 拆开，逐个文件核对白名单；任何不属于 Aevon 的东西都会让构建失败。
#
# 兼容 macOS 自带的 bash 3.2：不用 mapfile，不用 grep -P。
#
set -euo pipefail

DEB="${1:-}"
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
    echo "usage: $0 <file.deb>" >&2
    exit 2
fi
DEB="$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")"
# Git Bash 下 tar 会把 "C:\..." 当成远程主机，统一成 POSIX 路径。
if command -v cygpath >/dev/null 2>&1; then
    DEB="$(cygpath -u "$DEB")"
fi

WORK="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then
    WORK="$(cygpath -u "$WORK")"
fi
trap 'rm -rf "$WORK"' EXIT

# 拆 ar 容器：有 ar 用 ar，没有就用 python 直接解析（deb 的 ar 格式非常简单）
unpack_ar() {
    if command -v ar >/dev/null 2>&1; then
        ( cd "$2" && ar x "$1" )
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" "$2" <<'PY'
import sys, os
deb, out = sys.argv[1], sys.argv[2]
blob = open(deb, 'rb').read()
if blob[:8] != b'!<arch>\n':
    sys.exit("not an ar archive")
i = 8
while i + 60 <= len(blob):
    hdr = blob[i:i + 60]; i += 60
    name = hdr[0:16].decode('ascii', 'replace').strip()
    try:
        size = int(hdr[48:58].decode('ascii').strip())
    except ValueError:
        break
    data = blob[i:i + size]; i += size
    if i % 2:
        i += 1
    if name in ('/', '//', '/SYM64/'):
        continue
    name = name.rstrip('/')
    if name:
        open(os.path.join(out, os.path.basename(name)), 'wb').write(data)
PY
        return $?
    fi
    return 1
}

if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$DEB" "$WORK/root"
    dpkg-deb -e "$DEB" "$WORK/ctrl"
else
    mkdir -p "$WORK/root" "$WORK/ctrl"
    if ! unpack_ar "$DEB" "$WORK"; then
        echo "FAIL: 既没有 dpkg-deb 也没有 ar/python3，无法拆包" >&2
        exit 3
    fi
    DATA="$(ls "$WORK"/data.tar.* 2>/dev/null | head -1 || true)"
    CTRL="$(ls "$WORK"/control.tar.* 2>/dev/null | head -1 || true)"
    if [ -z "$DATA" ]; then
        echo "FAIL: deb 里找不到 data.tar.*" >&2
        exit 3
    fi
    tar -xf "$DATA" -C "$WORK/root"
    if [ -n "$CTRL" ]; then tar -xf "$CTRL" -C "$WORK/ctrl"; fi
fi

fail=0
note() { printf '  %-5s %s\n' "$1" "$2"; }

# 读 MobileSubstrate 过滤 plist 里的 Filter 列表。二进制/XML 都能处理。
read_bundles() {
    local p="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$p" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as fh:
        d = plistlib.load(fh)
except Exception:
    sys.exit(1)
names = []
flt = d.get("Filter", {}) if isinstance(d, dict) else {}
for key in ("Bundles", "Classes", "Executables"):
    v = flt.get(key)
    if isinstance(v, list):
        names += [str(x) for x in v]
print(" ".join(names))
PY
        return
    fi
    # 没有 python3 时退回文本解析（仅适用于 XML plist）
    grep -o '<string>[^<]*</string>' "$p" 2>/dev/null | sed 's/<[^>]*>//g' | tr '\n' ' '
}

echo "== Aevon package audit =="
echo "file: $DEB"
echo ""

# 读 Mach-O 的架构列表（fat 与 thin 都支持）。roothide 要求 arm64e。
macho_archs() {
    python3 - "$1" <<'PY'
import struct, sys
blob = open(sys.argv[1], 'rb').read()
names = {0: 'arm64', 1: 'arm64v8', 2: 'arm64e', 3: 'arm64_32'}
def kind(cputype, sub):
    if cputype != 0x0100000c:
        return None
    return names.get(sub & 0x00ffffff, 'arm64?')
out = []
magic = blob[:4]
if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
    wide = magic == b'\xca\xfe\xba\xbf'
    n = struct.unpack('>I', blob[4:8])[0]
    off = 8
    for _ in range(n):
        cputype, cpusub = struct.unpack('>ii', blob[off:off + 8])
        off += 32 if wide else 20
        k = kind(cputype, cpusub)
        if k:
            out.append(k)
elif magic == b'\xcf\xfa\xed\xfe':
    cputype, cpusub = struct.unpack('<ii', blob[4:12])
    k = kind(cputype, cpusub)
    if k:
        out.append(k)
print(' '.join(out))
PY
}

FILES_TXT="$WORK/files.txt"
( cd "$WORK/root" && find . -type f | sed 's|^\./||' | sort ) > "$FILES_TXT"
COUNT="$(wc -l < "$FILES_TXT" | tr -d ' ')"

if [ "$COUNT" -eq 0 ]; then
    echo "FAIL: 包是空的" >&2
    exit 1
fi

# ---------------------------------------------------------------- 0. 包结构
# roothide 包按 rootful 结构打包，dpkg 自己把文件放随机 jbroot。
# 如果还带 var/jb 前缀，说明 THEOS_PACKAGE_SCHEME 没生效，装上去是错位的。
if grep -q '^var/jb/' "$FILES_TXT"; then
    note FAIL "payload 仍带 var/jb 前缀 → scheme 没生效，roothide 下会装错位置"
    fail=1
else
    note ok "结构: roothide（rootful 布局，无 var/jb 前缀）"
fi

# ---------------------------------------------------------------- 1. 高危目录
# 只有写进这些地方，才真正具备「开不了机」的能力。一个都不许碰。
DENY='^(System|private|Applications|bin|sbin|usr/bin|usr/sbin|usr/lib|Library/LaunchDaemons|Library/LaunchAgents|Library/PreferenceLoader|Library/MobileSubstrate/MobileSubstrate\.dylib)(/|$)'

while IFS= read -r f; do
    norm="${f#var/jb/}"
    # 唯一的例外：我们自己的 PreferenceLoader 入口。
    # 这是 Settings 里出现「Aevon」那一行的必要条件，且它只描述一个 bundle。
    if [ "$norm" = "Library/PreferenceLoader/Preferences/Aevon.plist" ]; then
        continue
    fi
    if printf '%s' "$norm" | grep -Eq "$DENY"; then
        note FAIL "危险路径: $f"
        fail=1
    fi
done < "$FILES_TXT"

# ---------------------------------------------------------------- 2. 文件白名单
is_allowed() {
    case "$1" in
        Library/MobileSubstrate/DynamicLibraries/Aevon.dylib) return 0 ;;
        Library/MobileSubstrate/DynamicLibraries/Aevon.plist) return 0 ;;
        Library/PreferenceLoader/Preferences/Aevon.plist)     return 0 ;;
        usr/libexec/aevon/aevon-disable)   return 0 ;;
        usr/libexec/aevon/aevon-enable)    return 0 ;;
        usr/libexec/aevon/aevon-status)    return 0 ;;
        usr/libexec/aevon/aevon-uninstall) return 0 ;;
        # 设置面板：只允许这一个 bundle 目录，且文件类型受限（见下）
        Library/PreferenceBundles/AevonPrefs.bundle/AevonPrefs)      return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Info.plist)      return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Root.plist)      return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Window.plist)    return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Ring.plist)      return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Gesture.plist)   return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Keyboard.plist)  return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Notify.plist)    return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Jump.plist)      return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Listen.plist)    return 0 ;;
        Library/PreferenceBundles/AevonPrefs.bundle/Apps.plist)      return 0 ;;
        *) return 1 ;;
    esac
}

unknown=0
while IFS= read -r f; do
    norm="${f#var/jb/}"
    if ! is_allowed "$norm"; then
        note FAIL "白名单外文件: $f"
        unknown=1
        fail=1
    fi
done < "$FILES_TXT"
[ "$unknown" -eq 0 ] && note ok "payload 全部在白名单内（$COUNT 个文件）"

# ---------------------------------------------------------------- 3. 注入范围
PLIST_A="$WORK/root/Library/MobileSubstrate/DynamicLibraries/Aevon.plist"
PLIST_B="$WORK/root/var/jb/Library/MobileSubstrate/DynamicLibraries/Aevon.plist"
DYL_A="$WORK/root/Library/MobileSubstrate/DynamicLibraries/Aevon.dylib"
DYL_B="$WORK/root/var/jb/Library/MobileSubstrate/DynamicLibraries/Aevon.dylib"

FILTER="$PLIST_A"; [ -f "$FILTER" ] || FILTER="$PLIST_B"
DYLIB="$DYL_A";    [ -f "$DYLIB" ]  || DYLIB="$DYL_B"

check_macho_arm64e() {
    local f="$1" label="$2" archs
    [ -f "$f" ] || return 0
    archs="$(macho_archs "$f" 2>/dev/null || true)"
    if printf '%s' "$archs" | grep -q 'arm64e'; then
        note ok "$label 含 arm64e（${archs}）"
    else
        note FAIL "$label 不含 arm64e 切片（${archs:-解析失败}）"
        fail=1
    fi
}

if [ ! -f "$DYLIB" ]; then
    note FAIL "缺少 Aevon.dylib"
    fail=1
elif [ ! -s "$DYLIB" ]; then
    note FAIL "Aevon.dylib 是空文件"
    fail=1
else
    note ok "Aevon.dylib $(wc -c < "$DYLIB" | tr -d ' ') 字节"
    check_macho_arm64e "$DYLIB" "Aevon.dylib"
fi

PREFS_BIN="$WORK/root/Library/PreferenceBundles/AevonPrefs.bundle/AevonPrefs"
check_macho_arm64e "$PREFS_BIN" "AevonPrefs"

if [ ! -f "$FILTER" ]; then
    note FAIL "缺少 Aevon.plist 注入过滤器"
    fail=1
else
    # Theos 打包时会把 plist 转成二进制，不能靠 grep 抽字符串。
    BUNDLES="$(read_bundles "$FILTER" 2>/dev/null || true)"
    BUNDLE_COUNT="$(printf '%s' "$BUNDLES" | wc -w | tr -d ' ')"
    note info "注入目标: ${BUNDLES:-<解析失败>}"
    if printf '%s' "$BUNDLES" | grep -q 'com.apple.springboard'; then
        note ok "包含 SpringBoard"
    else
        note FAIL "过滤器里没有 SpringBoard（或无法解析）"
        fail=1
    fi
    # Stage 0 只允许注入一个进程。扩大范围必须是刻意动作，会同时改阶段号。
    if [ "$BUNDLE_COUNT" -ne 1 ]; then
        note FAIL "Stage 0 只允许注入 1 个进程，当前 $BUNDLE_COUNT 个"
        fail=1
    fi
fi

# ---------------------------------------------------------------- 4. 控制脚本
for s in postinst prerm; do
    f="$WORK/ctrl/$s"
    [ -f "$f" ] || continue
    bad=0
    for pat in 'rm -rf /' 'nvram' 'dpkg --force' 'launchctl' '/System/'; do
        if grep -qF -- "$pat" "$f"; then
            note FAIL "$s 含高危操作: $pat"
            bad=1
            fail=1
        fi
    done
    [ "$bad" -eq 0 ] && note ok "$s 检查通过"
done

# ---------------------------------------------------------------- 5. 元数据
ARCH=""
VER=""
if [ -f "$WORK/ctrl/control" ]; then
    ARCH="$(grep -i '^Architecture:' "$WORK/ctrl/control" | head -1 | awk '{print $2}')"
    VER="$(grep -i '^Version:' "$WORK/ctrl/control" | head -1 | awk '{print $2}')"
fi
if [ "$ARCH" = "iphoneos-arm64e" ]; then
    note ok "Architecture: $ARCH (roothide) version $VER"
else
    note FAIL "Architecture 应为 iphoneos-arm64e（roothide），实际: ${ARCH:-missing}"
    fail=1
fi

# 按要求：control 里不写描述，Sileo 的插件页就不显示描述。
# dpkg-deb 对缺描述只给 warning，不会拒绝打包。
if [ -f "$WORK/ctrl/control" ] && grep -qi '^Description:' "$WORK/ctrl/control"; then
    note FAIL "control 仍有 Description 字段（Sileo 会显示描述）"
    fail=1
else
    note ok "control 无 Description（Sileo 不显示描述）"
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo "AUDIT RESULT: FAIL — 拒绝发布这个包" >&2
    exit 1
fi
echo "AUDIT RESULT: PASS"
