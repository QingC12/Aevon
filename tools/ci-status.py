#!/usr/bin/env python3
"""CI 状态查看器 — 从命令行盯 Actions，不用打开浏览器。

用法:
    GH_TOKEN=xxx python3 tools/ci-status.py            # 等最新一次跑完
    GH_TOKEN=xxx python3 tools/ci-status.py --logs     # 失败时直接打印日志

只读 GitHub API，不含任何凭据。国内网络下 api.github.com 常被代理挡住，
这里默认绕开 http_proxy 直连。
"""
import os
import sys
import json
import time
import urllib.request
import urllib.error

REPO = os.environ.get("AEVON_REPO", "QingC12/Aevon")
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""

# 0.0.46 — 同 gh-push：这台机器出网必须走代理，留开关，默认行为不变。
if os.environ.get("AEVON_KEEP_PROXY") != "1":
    for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        os.environ.pop(_k, None)

HEAD = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "aevon-ci",
}
if TOKEN:
    HEAD["Authorization"] = "Bearer " + TOKEN


class _StripAuth(urllib.request.HTTPRedirectHandler):
    """日志下载会 302 到对象存储，那边的签名 URL 不接受我们的 Authorization。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        r = super().redirect_request(req, fp, code, msg, headers, newurl)
        if r is not None and "api.github.com" not in newurl:
            r.headers = {k: v for k, v in r.headers.items() if k.lower() != "authorization"}
        return r


OPENER = urllib.request.build_opener(_StripAuth)


def api(path):
    req = urllib.request.Request("https://api.github.com" + path, headers=HEAD)
    with OPENER.open(req, timeout=40) as r:
        return json.loads(r.read())


def fetch_logs(job_id):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/actions/jobs/{job_id}/logs", headers=HEAD
    )
    with OPENER.open(req, timeout=90) as r:
        return r.read().decode("utf-8-sig", "replace")


def main():
    want_logs = "--logs" in sys.argv
    runs = api(f"/repos/{REPO}/actions/runs?per_page=1")["workflow_runs"]
    if not runs:
        print("no workflow runs yet")
        return 1
    run = runs[0]
    rid = run["id"]
    print(f"run {rid}  {run['head_branch']}  {run['head_sha'][:7]}  {run['status']}")

    for _ in range(60):
        r = api(f"/repos/{REPO}/actions/runs/{rid}")
        if r["status"] == "completed":
            break
        time.sleep(10)
    print(f"status={r['status']} conclusion={r['conclusion']}")

    jobs = api(f"/repos/{REPO}/actions/runs/{rid}/jobs")["jobs"]
    for j in jobs:
        print(f"\nJOB {j['name']}: {j['conclusion']}")
        for s in j["steps"]:
            if s["conclusion"] not in ("success", "skipped", None):
                print(f"  [{s['number']:2d}] {s['name']}: {s['conclusion']}")

    if want_logs and r["conclusion"] != "success":
        for j in jobs:
            if j["conclusion"] == "success":
                continue
            txt = fetch_logs(j["id"])
            import re
            txt = re.sub(r"\x1b\[[0-9;]*m", "", txt)
            txt = re.sub(r"\d{4}-\d\d-\d\dT[\d:.]+Z ", "", txt)
            lines = [l for l in txt.splitlines() if l.strip()]
            keep = [l for l in lines if any(
                k in l for k in ("error:", "Error", "FAIL", "AUDIT", "warning:", "undefined", "not found"))]
            print("\n".join(keep[-60:]))
    return 0 if r["conclusion"] == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
