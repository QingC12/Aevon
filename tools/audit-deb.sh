#!/bin/sh
#
# audit-deb.sh — 找到 python3，跑 audit-deb.py。
# 逻辑只有一份，CI、本地、手机上跑出来的结论必须一样。
#
set -e

DEB="${1:-}"
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
    echo "usage: $0 <file.deb>" >&2
    exit 2
fi

DIR="$(cd "$(dirname "$0")" && pwd)"

for PY in python3 python; do
    if command -v "$PY" >/dev/null 2>&1; then
        exec "$PY" "$DIR/audit-deb.py" "$DEB"
    fi
done

echo "audit-deb: 找不到 python3" >&2
exit 2
