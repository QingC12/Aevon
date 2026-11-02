#!/bin/sh
#
# name-deb.sh — 交付文件名只在这里生成一次
#
#     com.Aevon_<version>-arm64e.deb
#
# 包的 id 必须是全小写（dpkg 规定），所以 control 里是 com.aevon；
# 交付文件名按你的要求用 com.Aevon。<version> 从 control 读，不手写。
#
# 用法: name-deb.sh <packages 目录> <输出目录>
#
set -eu

SRC="${1:-packages}"
OUT="${2:-dist}"

DEB="$(ls "$SRC"/*.deb 2>/dev/null | head -1)"
if [ -z "${DEB:-}" ]; then
    echo "name-deb: $SRC 里没有 deb" >&2
    exit 1
fi

COUNT="$(ls "$SRC"/*.deb | wc -l | tr -d ' ')"
if [ "$COUNT" != "1" ]; then
    echo "name-deb: 期望正好一个 deb，实际 $COUNT 个" >&2
    exit 1
fi

VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' control)"
if [ -z "$VERSION" ]; then
    echo "name-deb: control 里没有 Version" >&2
    exit 1
fi

mkdir -p "$OUT"
TARGET="$OUT/com.Aevon_${VERSION}-arm64e.deb"
cp "$DEB" "$TARGET"
echo "$TARGET"
