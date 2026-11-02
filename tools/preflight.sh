#!/bin/sh
# preflight.sh — 装 Aevon 之前先在设备上跑一遍
#
#   用法（设备上，root）:
#       sh /var/mobile/preflight.sh
#
# 它做三件事：确认环境是 roothide（或 rootless）、确认救援通道可用、把当前状态存一份快照。
# 任何一项不对，就别装。
set -u

# roothide 的 bootstrap 在随机路径，不能写死 /var/jb。
JB=""
for d in /var/containers/Bundle/Application/.jbroot-*; do
    if [ -d "$d" ]; then JB="$d"; break; fi
done
if [ -z "$JB" ] && [ -d /var/jb ]; then
    JB="/var/jb"
fi

if [ -n "$JB" ]; then
    export PATH="$JB/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
fi

OUT_DIR="/var/mobile/Library/Logs/Aevon"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASELINE="$OUT_DIR/baseline-$STAMP.txt"
problems=0

say()  { printf '  %-6s %s\n' "$1" "$2"; }
bad()  { problems=$((problems + 1)); say "BAD" "$1"; }

echo "== Aevon preflight =="
echo "date: $(date)"
echo ""

# 1. 越狱环境
if [ -z "$JB" ]; then
    bad "没找到 .jbroot-* 也没有 /var/jb，装 iphoneos-arm64e 包不会生效"
else
    case "$JB" in
        *.jbroot-*) say ok "roothide 环境: $JB" ;;
        *)          say ok "rootless 环境: $JB" ;;
    esac
fi

# 2. 注入器
if [ -n "$JB" ] && { [ -d "$JB/usr/lib/ellekit" ] || [ -f "$JB/usr/lib/libellekit.dylib" ]; }; then
    say ok "ElleKit 存在"
elif [ -n "$JB" ] && [ -f "$JB/usr/lib/libsubstrate.dylib" ]; then
    say ok "MobileSubstrate 存在"
else
    bad "没找到 ElleKit / MobileSubstrate，注入不会生效"
fi

# 3. 动态库目录
DL="$JB/Library/MobileSubstrate/DynamicLibraries"
if [ -n "$JB" ] && [ -d "$DL" ]; then
    say ok "注入目录存在，现有 $(ls -1 "$DL" 2>/dev/null | grep -c '\.dylib$') 个 dylib"
else
    bad "$DL 不存在"
fi

# 4. dpkg 健康
if command -v dpkg >/dev/null 2>&1; then
    if dpkg -l >/dev/null 2>&1; then
        say ok "dpkg 数据库可读"
    else
        bad "dpkg -l 失败，包管理已经有问题，先修好再装"
    fi
else
    bad "找不到 dpkg"
fi

# 5. 空间
AVAIL="$(df -k /var 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "${AVAIL:-}" ] && [ "$AVAIL" -gt 51200 ]; then
    say ok "/var 可用 $((AVAIL / 1024)) MB"
else
    bad "/var 可用空间不足 50 MB"
fi

# 6. 救援通道：状态目录必须可写（panic 文件与 state.plist 都落在这里）
P="$OUT_DIR/.probe"
mkdir -p "$OUT_DIR" 2>/dev/null
if ( : > "$P" ) 2>/dev/null; then
    rm -f "$P"
    say ok "救援目录可写（$OUT_DIR）"
else
    bad "$OUT_DIR 不可写，救援开关会失效，禁止安装"
fi

# 7. SSH（可选但强烈建议）
if [ -x /usr/sbin/sshd ] || { [ -n "$JB" ] && [ -x "$JB/usr/sbin/sshd" ]; }; then
    say ok "sshd 已安装"
else
    say warn "没装 OpenSSH，出事就只能靠 Filza 建 panic 文件了"
fi

# 8. 快照
mkdir -p "$OUT_DIR" 2>/dev/null
{
    echo "# Aevon baseline $STAMP"
    echo "## uname"; uname -a
    echo "## jbroot"; echo "$JB"
    echo "## dpkg -l"; dpkg -l 2>/dev/null
    echo "## dynamic libraries"; ls -l "$DL" 2>/dev/null
    echo "## aevon state"; ls -l "$OUT_DIR" 2>/dev/null
} > "$BASELINE" 2>/dev/null
say ok "快照已存: $BASELINE"

echo ""
if [ "$problems" -eq 0 ]; then
    echo "PREFLIGHT: PASS — 可以安装"
    exit 0
fi
echo "PREFLIGHT: FAIL — 有 $problems 项不满足，先解决再装"
exit 1
