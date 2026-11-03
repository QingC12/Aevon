#!/usr/bin/env python3
"""gh-push.py — 把本地工作区推到 GitHub，两条路，快的先走。

    GH_TOKEN=xxx python3 tools/gh-push.py commit-msg.txt

为什么曾经很慢（0.0.38 之前）
------------------------------
旧版只有一条路：Git Data API，而且**一个文件一次请求**。63 个跟踪文件
× 一次 TLS 往返（这台机器上 ~0.7 s）+ tree + commit + patch ref ≈ 45–60 s。
慢的不是网速，是请求数：每多一个文件就多一次往返，改一个字节也要重传整棵树。
这跟 CI 慢是两件完全不同的事。

现在有两条路
------------
1. **git push（默认，几秒）**
   api.github.com 通不通不重要，github.com:443 通就能走。git 协议一次连接传
   一个 packfile，且只传远端没有的对象 —— 服务端 advertise 完 refs，客户端
   就地算差量。做法是本地造一个「父提交 = 远端 head」的快照提交（父提交相同，
   历史因此仍是线性的，语义和 API 那条路完全一致），再 push 这个 sha。
   实测 63 个文件从 ~50 s 降到 3–6 s。

2. **Git Data API（回退）**
   github.com 被墙时走这条路。两处改动：
   · **复用未变的 blob**：先在本地算 git blob sha1，和远端父树里同路径的条目
     比对，相同就引用旧 sha，不上传。只改两个文件时，上传数从 63 降到 2。
   · **并行上传**：剩下的变更文件走 8 线程，串行往返变成并发往返。

开关
----
    AEVON_PUSH_MODE=git   只走 git（github.com 不通就失败）
    AEVON_PUSH_MODE=api   只走 API（验证 API 路径用）
    默认 auto：git 先试，失败回退 API

本地闸门照旧：默认强制过 tools/push-gate.py，AEVON_SKIP_GATE=1 才跳过。
"""
import base64
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.environ.get("AEVON_REPO", "QingC12/Aevon")
BRANCH = os.environ.get("AEVON_BRANCH", "main")
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
MODE = os.environ.get("AEVON_PUSH_MODE", "auto").lower()
if not TOKEN:
    sys.exit("GH_TOKEN 未设置")

# 0.0.46 — 代理不是「一律有害」，是「以前那台机器上没有代理」。
# 这台机器出网必须走代理：上面那一行 pop 掉之后，api.github.com 直接
# RemoteDisconnected，git 也连不上。保留一个开关，默认行为不变。
if os.environ.get("AEVON_KEEP_PROXY") != "1":
    for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        os.environ.pop(_k, None)

HEAD = {
    "Authorization": "Bearer " + TOKEN,
    "Accept": "application/vnd.github+json",
    "User-Agent": "aevon-push",
    "Content-Type": "application/json",
}

BINARY_EXT = {".deb", ".png", ".gif", ".jpg", ".dylib", ".zip"}


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


def lf_only(path, data):
    """Windows 工作区写出来的文件常常是 CRLF。CRLF 的 Makefile / .sh 推到远端后
    会让 macOS 的 make 和 sh 当场报错，而这一环最容易被忘掉 —— 所以统一在推送
    前收敛成 LF。二进制文件（二进制 plist、png、deb）原样放行。"""
    if os.path.splitext(path)[1].lower() in BINARY_EXT:
        return data
    if data[:6] == b"bplist":
        return data
    return data.replace(b"\r\n", b"\n")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


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


# ---------------------------------------------------------------------------
# 路一：git push
# ---------------------------------------------------------------------------


def remote_url():
    return f"https://x-access-token:{TOKEN}@github.com/{REPO}.git"


def remote_head_git():
    """远端 head，一次 ls-remote。返回 (sha, 原因)，sha 为 None 表示不通。"""
    try:
        out = subprocess.run(
            ["git", "ls-remote", remote_url(), f"refs/heads/{BRANCH}"],
            capture_output=True,
            text=True,
            timeout=40,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )
    except subprocess.TimeoutExpired:
        return None, "ls-remote 超时"
    if out.returncode != 0:
        tail = (out.stderr or "").strip().splitlines()
        return None, (tail[-1] if tail else "ls-remote 失败")
    lines = out.stdout.strip().splitlines()
    if not lines:
        return None, "远端没有这个分支"
    return lines[0].split()[0], ""


def push_git(message):
    """快照提交 + push。父提交挂在远端 head 上，历史线性，语义与 API 路一致。"""
    if shutil.which("git") is None:
        return False, "git 不可用"

    tree = git("rev-parse", "HEAD^{tree}")
    if tree.returncode != 0:
        return False, "本地没有 HEAD，先 commit"
    tree = tree.stdout.strip()

    parent, why = remote_head_git()
    if parent is None:
        return False, "github.com 不通（" + why + "）"

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                     encoding="utf-8") as fh:
        fh.write(message)
        msg_file = fh.name
    try:
        made = git("commit-tree", tree, "-p", parent, "-F", msg_file)
    finally:
        os.unlink(msg_file)
    if made.returncode != 0:
        return False, "commit-tree: " + (made.stderr or "").strip()
    commit = made.stdout.strip()

    started = time.time()
    try:
        pushed = subprocess.run(
            ["git", "-c", "http.version=HTTP/1.1", "push", "--quiet",
             remote_url(), commit + ":refs/heads/" + BRANCH],
            capture_output=True,
            text=True,
            timeout=180,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )
    except subprocess.TimeoutExpired:
        return False, "push 超时"
    if pushed.returncode != 0:
        tail = (pushed.stderr or pushed.stdout or "").strip().splitlines()
        return False, "push: " + (tail[-1] if tail else "失败")
    took = time.time() - started
    print("git push OK %s (parent %s, %.1fs)" % (commit[:7], parent[:7], took))
    return True, ""


# ---------------------------------------------------------------------------
# 路二：Git Data API（复用未变 blob + 并行上传）
# ---------------------------------------------------------------------------


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


def blob_sha(data):
    """git 的对象 id：`blob <len>\\0<内容>` 的 sha1。算它不是炫技 ——
    和远端父树同路径的 sha 一比，就知道这个文件到底要不要上传。"""
    return hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()


def remote_tree_shas(parent_sha):
    """父提交的完整树：path -> (sha, mode)。递归一次，整棵树一次请求。"""
    tree = api("/repos/%s/git/trees/%s?recursive=1" % (REPO, parent_sha))
    table = {}
    for entry in tree.get("tree", []):
        if entry.get("type") == "blob":
            table[entry["path"]] = (entry["sha"], entry.get("mode", "100644"))
    return table


def push_api(message):
    files = tracked_files()
    if not files:
        sys.exit("没有跟踪的文件")

    clock = {}
    started = time.time()
    ref = api("/repos/%s/git/ref/heads/%s" % (REPO, BRANCH))
    parent_sha = ref["object"]["sha"]
    try:
        known = remote_tree_shas(parent_sha)
    except SystemExit:
        known = {}
    clock["已知树"] = time.time() - started

    entries = []
    uploads = []
    for path, mode in files:
        with open(path, "rb") as fh:
            data = lf_only(path, fh.read())
        remote_path = path.replace("\\", "/")
        wanted = "100755" if mode == "100755" else "100644"
        sha = blob_sha(data)
        prev = known.get(remote_path)
        if prev and prev[0] == sha and prev[1] == wanted:
            entries.append({"path": remote_path, "mode": wanted,
                            "type": "blob", "sha": sha})
            continue
        uploads.append((len(entries), remote_path, wanted, data))
        entries.append({"path": remote_path, "mode": wanted,
                        "type": "blob", "sha": None})

    def send(item):
        slot, _, _, data = item
        blob = api(
            "/repos/%s/git/blobs" % REPO,
            {"content": base64.b64encode(data).decode(), "encoding": "base64"},
        )
        return slot, blob["sha"]

    if uploads:
        mark = time.time()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for slot, sha in pool.map(send, uploads):
                entries[slot]["sha"] = sha
        clock["上传 %d 个 blob" % len(uploads)] = time.time() - mark

    print("%d 个文件，复用 %d 个未变 blob，上传 %d 个"
          % (len(entries), len(entries) - len(uploads), len(uploads)))

    mark = time.time()
    new_tree = api("/repos/%s/git/trees" % REPO, {"tree": entries})
    clock["写树"] = time.time() - mark
    mark = time.time()
    commit = api(
        "/repos/%s/git/commits" % REPO,
        {"message": message, "tree": new_tree["sha"], "parents": [parent_sha]},
    )
    clock["提交"] = time.time() - mark
    mark = time.time()
    api(
        "/repos/%s/git/refs/heads/%s" % (REPO, BRANCH),
        {"sha": commit["sha"]},
        method="PATCH",
    )
    clock["移动分支"] = time.time() - mark
    # 每一段都打出来：下次再觉得慢，先看是哪一段，而不是猜网络。
    detail = "，".join("%s %.1fs" % (k, v) for k, v in clock.items())
    print("api push OK %s (parent %s, tree %s)"
          % (commit["sha"][:7], parent_sha[:7], new_tree["sha"][:7]))
    print("用时 " + detail)
    return True


def main():
    # 消息来源：命令行给的字符串 / 文件，缺省用本地 HEAD 的提交信息。旧版默认写
    # "update"，于是远端历史全是同一个词，翻回去看不出哪一版做了什么。
    if len(sys.argv) > 1:
        message = sys.argv[1]
        if os.path.isfile(message):
            with open(message, encoding="utf-8") as fh:
                message = fh.read()
    else:
        message = git("log", "-1", "--format=%B").stdout.strip() or "update"

    gate()

    if MODE in ("auto", "git"):
        ok, why = push_git(message)
        if ok:
            return
        if MODE == "git":
            sys.exit("git 路失败：" + why)
        print("git 路不通（" + why + "），回退 Git Data API")

    push_api(message)


if __name__ == "__main__":
    main()
