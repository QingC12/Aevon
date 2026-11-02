#!/usr/bin/env python3
"""gh-push.py — 在 github.com:443 被墙、只剩 api.github.com 可用时推送提交。

git 的 smart HTTP 必须连 github.com，而 API 走的是 api.github.com。
两者在很多网络环境下可达性不一样，这个脚本用 Git Data API
(blob -> tree -> commit -> ref) 完成一次完整推送。

用法:
    GH_TOKEN=xxx python3 tools/gh-push.py "commit message"

行为: 以**本地工作区的当前已跟踪文件**为准做全量快照，
父提交取远端当前 head，因此远端历史是线性的、内容总是与本地一致。
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.environ.get("AEVON_REPO", "QingC12/Aevon")
BRANCH = os.environ.get("AEVON_BRANCH", "main")
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
if not TOKEN:
    sys.exit("GH_TOKEN 未设置")

for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
    os.environ.pop(_k, None)

HEAD = {
    "Authorization": "Bearer " + TOKEN,
    "Accept": "application/vnd.github+json",
    "User-Agent": "aevon-push",
    "Content-Type": "application/json",
}


def api(path, data=None, method=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        "https://api.github.com" + path, data=body, method=method, headers=HEAD
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise SystemExit(f"API {e.code} on {path}: {detail}")


BINARY_EXT = {".deb", ".png", ".gif", ".jpg", ".dylib", ".zip"}


def lf_only(path, data):
    """Windows 工作区写出来的文件常常是 CRLF。CRLF 的 Makefile / .sh 推到远端后
    会让 macOS 的 make 和 sh 当场报错，而这一环最容易被忘掉 —— 所以统一在推送
    前收敛成 LF。二进制文件（二进制 plist、png、deb）原样放行。"""
    if os.path.splitext(path)[1].lower() in BINARY_EXT:
        return data
    if data[:6] == b"bplist":
        return data
    return data.replace(b"\r\n", b"\n")


def tracked_files():
    # -z 是关键：不加的话 git 会把非 ASCII 路径转义成 "\344\272..."，
    # 中文文档名会直接 open() 失败。NUL 分隔的原始字节没有这个问题。
    out = subprocess.run(
        ["git", "ls-files", "-s", "-z"], capture_output=True, check=True
    ).stdout
    files = []
    for entry in out.split(b"\x00"):
        if not entry.strip():
            continue
        meta, path = entry.split(b"\t", 1)
        files.append((path.decode("utf-8"), meta.split()[0].decode()))
    return files


def gate():
    """推送前的本地闸门。它不编译，只验证「要推的东西是否自洽」。

    之前连续几次 CI 失败，原因都是本地就能查出来的：审计断言了一个被 strip
    掉的类型名、清单里混进了交付报告。等 CI 两分钟才发现，成本高且没必要。
    所以这里默认强制先过闸门 —— 想过也过不去，除非显式设置 AEVON_SKIP_GATE=1。
    """
    if os.environ.get("AEVON_SKIP_GATE") == "1":
        print("!! 跳过本地闸门（AEVON_SKIP_GATE=1）—— 失败风险自负")
        return
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "push-gate.py")
    result = subprocess.run([sys.executable, script, "--quiet"], cwd=os.getcwd())
    if result.returncode != 0:
        sys.exit("\n本地闸门未通过，已停止推送。先修好上面列出的项，再推。")


def main():
    message = sys.argv[1] if len(sys.argv) > 1 else "update"
    gate()

    files = tracked_files()
    if not files:
        sys.exit("没有跟踪的文件")

    ref = api(f"/repos/{REPO}/git/ref/heads/{BRANCH}")
    parent_sha = ref["object"]["sha"]
    parent = api(f"/repos/{REPO}/git/commits/{parent_sha}")

    tree = []
    for path, mode in files:
        with open(path, "rb") as fh:
            data = lf_only(path, fh.read())
            blob = api(
                f"/repos/{REPO}/git/blobs",
                {"content": base64.b64encode(data).decode(), "encoding": "base64"},
            )
        tree.append(
            {
                "path": path.replace("\\", "/"),
                "mode": "100755" if mode == "100755" else "100644",
                "type": "blob",
                "sha": blob["sha"],
            }
        )
    print(f"上传 {len(tree)} 个 blob")

    new_tree = api(f"/repos/{REPO}/git/trees", {"tree": tree})
    commit = api(
        f"/repos/{REPO}/git/commits",
        {"message": message, "tree": new_tree["sha"], "parents": [parent_sha]},
    )
    api(
        f"/repos/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": commit["sha"]},
        method="PATCH",
    )
    print(f"pushed {commit['sha'][:7]}  (parent {parent_sha[:7]}, tree {new_tree['sha'][:7]})")


if __name__ == "__main__":
    main()
