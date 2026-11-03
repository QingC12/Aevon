#!/usr/bin/env python3
"""fetch-deb.py — 把 CI 产出的 deb 取回本地 dist/

用法:
    GH_TOKEN=xxx python3 tools/fetch-deb.py

只读 GitHub API：找到 main 上最近一次成功的构建，下载 artifact 里的 deb，
解压到 dist/，再用 tools/audit-deb.sh 复核一遍。
"""
import io
import json
import os
import subprocess
import sys
import urllib.request
import zipfile

REPO = os.environ.get("AEVON_REPO", "QingC12/Aevon")
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
if not TOKEN:
    sys.exit("GH_TOKEN 未设置")

# 0.0.46 — 同 gh-push：这台机器出网必须走代理，留开关，默认行为不变。
if os.environ.get("AEVON_KEEP_PROXY") != "1":
    for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        os.environ.pop(_k, None)

HEAD = {
    "Authorization": "Bearer " + TOKEN,
    "Accept": "application/vnd.github+json",
    "User-Agent": "aevon-fetch",
}


class _StripAuth(urllib.request.HTTPRedirectHandler):
    """artifact 会 302 到对象存储，那边的签名 URL 不接受我们的 Authorization。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        r = super().redirect_request(req, fp, code, msg, headers, newurl)
        if r is not None and "api.github.com" not in newurl:
            r.headers = {k: v for k, v in r.headers.items() if k.lower() != "authorization"}
        return r


OPENER = urllib.request.build_opener(_StripAuth)


def api(path):
    req = urllib.request.Request("https://api.github.com" + path, headers=HEAD)
    with OPENER.open(req, timeout=60) as r:
        return json.loads(r.read())


def main():
    runs = api(f"/repos/{REPO}/actions/runs?branch=main&per_page=10")["workflow_runs"]
    run = next((r for r in runs if r["conclusion"] == "success"), None)
    if run is None:
        sys.exit("最近 10 次里没有成功的构建")
    print(f"run {run['id']}  {run['head_sha'][:7]}  {run['created_at']}")

    arts = api(f"/repos/{REPO}/actions/runs/{run['id']}/artifacts")["artifacts"]
    art = next((a for a in arts if a["name"] == "aevon-deb"), None)
    if art is None:
        sys.exit("这个 run 没有 aevon-deb 产物")

    req = urllib.request.Request(art["archive_download_url"], headers=HEAD)
    with OPENER.open(req, timeout=180) as r:
        payload = r.read()
    print(f"artifact {art['size_in_bytes']:,} B (zip)")

    os.makedirs("dist", exist_ok=True)
    wanted = None
    with zipfile.ZipFile(io.BytesIO(payload)) as zf:
        for name in zf.namelist():
            if name.endswith(".deb"):
                wanted = os.path.join("dist", os.path.basename(name))
                with open(wanted, "wb") as fh:
                    fh.write(zf.read(name))
                break
    if wanted is None:
        sys.exit("zip 里没有 deb")

    print(f"saved {wanted}  ({os.path.getsize(wanted):,} B)")
    return subprocess.call(["bash", "tools/audit-deb.sh", wanted])


if __name__ == "__main__":
    sys.exit(main())
