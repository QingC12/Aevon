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

echo "== Aevon package audit =="
echo "file: $DEB"
echo ""

FILES_TXT="$WORK/files.txt"
( cd "$WORK/root" && find . -type f | sed 's|^\./||' | sort ) > "$FILES_TXT"
COUNT="$(wc -l < "$FILES_TXT" | tr -d ' ')"

if [ "$COUNT" -eq 0 ]; then
    echo "FAIL: 包是空的" >&2
    exit 1
fi

# ---------------------------------------------------------------- 1. 高危目录
# 只有写进这些地方，才真正具备「开不了机」的能力。一个都不许碰。
DENY='^(System|private|Applications|bin|sbin|usr/bin|usr/sbin|usr/lib|Library/LaunchDaemons|Library/LaunchAgents|Library/PreferenceLoader|Library/MobileSubstrate/MobileSubstrate\.dylib)(/|$)'

while IFS= read -r f; do
    norm="${f#var/jb/}"
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
        usr/libexec/aevon/aevon-disable)   return 0 ;;
        usr/libexec/aevon/aevon-enable)    return 0 ;;
        usr/libexec/aevon/aevon-status)    return 0 ;;
        usr/libexec/aevon/aevon-uninstall) return 0 ;;
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

if [ ! -f "$DYLIB" ]; then
    note FAIL "缺少 Aevon.dylib"
    fail=1
elif [ ! -s "$DYLIB" ]; then
    note FAIL "Aevon.dylib 是空文件"
    fail=1
else
    note ok "Aevon.dylib $(wc -c < "$DYLIB" | tr -d ' ') 字节"
    if command -v lipo >/dev/null 2>&1; then
        note info "arch: $(lipo -archs "$DYLIB" 2>/dev/null || echo unknown)"
    fi
fi

if [ ! -f "$FILTER" ]; then
    note FAIL "缺少 Aevon.plist 注入过滤器"
    fail=1
else
    BUNDLES="$(grep -o '<string>[^<]*</string>' "$FILTER" | sed 's/<[^>]*>//g' | tr '\n' ' ')"
    BUNDLE_COUNT="$(printf '%s' "$BUNDLES" | wc -w | tr -d ' ')"
    note info "注入目标: $BUNDLES"
    if printf '%s' "$BUNDLES" | grep -q 'com.apple.springboard'; then
        note ok "包含 SpringBoard"
    else
        note FAIL "过滤器里没有 SpringBoard"
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
if [ -f "$WORK/ctrl/control" ]; then
    ARCH="$(grep -i '^Architecture:' "$WORK/ctrl/control" | head -1 | awk '{print $2}')"
fi
if [ "$ARCH" = "iphoneos-arm64" ]; then
    note ok "Architecture: $ARCH (rootless)"
else
    note FAIL "Architecture 应为 iphoneos-arm64，实际: ${ARCH:-missing}"
    fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo "AUDIT RESULT: FAIL — 拒绝发布这个包" >&2
    exit 1
fi
echo "AUDIT RESULT: PASS"
