#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
push-gate.py — 推送前的本地闸门

CI 一次失败要等两分钟才看得到，而大多数失败在本地几秒钟就能查出来。
这个脚本就是那几秒钟：它不编译，只验证「推上去的东西是否自洽」。

它回答四个问题
  1  清单      哪些文件会被推送？有没有交付报告、deb、构建产物混进来？
  2  完整性    新增的源文件有没有漏掉 `git add`？漏了 CI 就编译不到它。
  3  自洽性    版本号四处一致？Makefile 覆盖了每个源文件？面板动作都有实现？
  4  断言一致  审计脚本 grep 的字符串，源码里真的有吗？

最后一条是这一版新增的重点：之前连续几次构建失败，原因都是
`audit-deb.py` 断言了一个被 strip 掉的 Swift 类型名或一段插值字符串。
那是可以在本地查出来的，不该花一次 CI。

用法:
    python tools/push-gate.py              # 只检查
    python tools/push-gate.py --list       # 检查并打印完整推送清单
    python tools/push-gate.py --quiet      # 只打印失败项（给脚本用）

退出码 0 = 可以推送；1 = 有问题，禁止推送。
"""
import os
import plistlib
import py_compile
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

BUNDLE = "layout/Library/PreferenceBundles/AevonPrefs.bundle"
PANELS = ["Window", "Ring", "Gesture", "Keyboard",
          "Notify", "Jump", "Listen", "Apps"]

# 只有这些东西属于「构建必需」或「工程文档」。其余一律不许进仓库。
ALLOWED_EXACT = {
    "Makefile", "control", ".gitignore", ".gitattributes", "README.md",
    "Aevon.plist", "Aevon-Bridging-Header.h", "AevonPrefs-Bridging-Header.h",
}
ALLOWED_PREFIX = ("Sources/", "layout/", "tools/", ".github/workflows/")
ALLOWED_DOC_PREFIX = ("docs/",)
ALLOWED_DOC_EXT = (".md",)

# 出现即拒绝：这些是成果物，不是源码。
FORBIDDEN = [
    (re.compile(r"\.html?$", re.I), "交付报告 / 网页 —— 只留本地，CI 不需要"),
    (re.compile(r"\.deb$", re.I), "安装包产物"),
    (re.compile(r"^dist/"), "构建输出目录"),
    (re.compile(r"^build/"), "构建输出目录"),
    (re.compile(r"^packages/"), "Theos 打包目录"),
    (re.compile(r"^\.theos/"), "Theos 缓存"),
    (re.compile(r"\.log$", re.I), "运行日志"),
    (re.compile(r"\.(png|jpe?g|gif|webp)$", re.I), "截图 / 证据图"),
    (re.compile(r"(^|/)__pycache__/"), "Python 缓存"),
    (re.compile(r"\.pyc$", re.I), "Python 缓存"),
    (re.compile(r"(^|/)\.DS_Store$"), "macOS 垃圾文件"),
    (re.compile(r"\.(dylib|o|a)$", re.I), "编译中间产物"),
]

failures = []
warnings = []
notes = []


def ok(msg):
    notes.append(("PASS", msg))
    if not QUIET:
        print(f"  [PASS] {msg}")


def bad(msg):
    failures.append(msg)


def warn(msg):
    warnings.append(msg)
    if not QUIET:
        print(f"  [WARN] {msg}")


def section(title):
    if not QUIET:
        print("")
        print(f"== {title}")


def tracked():
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True,
                         check=True).stdout
    return [p.decode("utf-8") for p in out.split(b"\x00") if p]


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# 1  清单：远端会收到的每一个文件
# ---------------------------------------------------------------------------
def check_manifest(files):
    section("1 清单")
    forbidden_hits = []
    unknown = []
    for path in files:
        for pattern, why in FORBIDDEN:
            if pattern.search(path):
                forbidden_hits.append((path, why))
                break
        else:
            if path in ALLOWED_EXACT:
                continue
            if path.startswith(ALLOWED_PREFIX):
                continue
            if path.startswith(ALLOWED_DOC_PREFIX) and path.lower().endswith(ALLOWED_DOC_EXT):
                continue
            unknown.append(path)

    if forbidden_hits:
        for path, why in forbidden_hits:
            bad(f"manifest: 仓库里有不该推的文件 {path}（{why}）"
                f" —— 用 `git rm --cached {path}` 移除")
    if unknown:
        for path in unknown:
            bad(f"manifest: {path} 不属于任何允许的类别，先确认它确实是构建必需")
    if not forbidden_hits and not unknown:
        ok(f"manifest: {len(files)} 个跟踪文件，全部是源码/构建/工具/文档，无成果物")

    # 推送是「全量快照」，所以被忽略的成果物必须确认真的不在索引里
    ignored = subprocess.run(["git", "status", "--ignored", "--porcelain",
                              "--untracked-files=normal"],
                             capture_output=True).stdout.decode("utf-8", "replace")
    ignored_html = [l for l in ignored.splitlines() if l.startswith("!!") and ".html" in l]
    if ignored_html:
        ok(f"manifest: {len(ignored_html)} 份本地报告被 .gitignore 挡住，不会上传")
    return files


def check_untracked(files):
    """新增源文件忘了 git add，CI 就看不到它 —— 这次构建会缺行为，而且不报错。"""
    section("2 完整性")
    tracked_set = set(files)
    missing = []
    for base in ("Sources", "layout", "tools"):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            for name in filenames:
                if name.startswith(".") or name.endswith(".pyc"):
                    continue
                path = os.path.join(dirpath, name).replace("\\", "/")
                if path not in tracked_set:
                    missing.append(path)

    if missing:
        for path in missing:
            bad(f"untracked: {path} 存在于工作区但没进仓库 —— "
                f"CI 看不到它（`git add {path}`）")
    else:
        ok("untracked: 工作区里没有未入库的源文件")

    # 反向：索引里有、磁盘上没有（删除只做了一半）
    gone = [p for p in files if not os.path.exists(p)]
    if gone:
        for path in gone:
            bad(f"missing: {path} 在索引里但磁盘上不存在")
    else:
        ok("missing: 索引里的文件磁盘上都在")


# ---------------------------------------------------------------------------
# 3  Makefile 覆盖
# ---------------------------------------------------------------------------
def check_makefile():
    section("3 编译覆盖")
    makefile = read("Makefile")
    listed = set(re.findall(r"(Sources/[\w/]+\.(?:swift|m))", makefile))
    on_disk = set()
    for dirpath, _dirnames, filenames in os.walk("Sources"):
        for name in filenames:
            if name.endswith((".swift", ".m")):
                on_disk.add(os.path.join(dirpath, name).replace("\\", "/"))

    not_built = sorted(on_disk - listed)
    missing_files = sorted(listed - on_disk)

    if not_built:
        for path in not_built:
            bad(f"makefile: {path} 没有出现在任何 FILES 里 —— 它不会被编译，"
                f"改它等于没改")
    if missing_files:
        for path in missing_files:
            bad(f"makefile: 引用了不存在的 {path} —— make 会直接报错")
    if not not_built and not missing_files:
        ok(f"makefile: {len(on_disk)} 个源文件全部进了某个 target，无悬空引用")


def _makefile_variable(makefile, name):
    """A make variable's file list, continuation lines and $(VAR) expanded."""
    lines = makefile.splitlines()
    raw = None
    for index, line in enumerate(lines):
        if re.match(rf"^{name}\s*:?=", line):
            chunk = [line]
            cursor = index
            while chunk[-1].rstrip().endswith("\\") and cursor + 1 < len(lines):
                cursor += 1
                chunk.append(lines[cursor])
            raw = " ".join(part.rstrip().rstrip("\\") for part in chunk)
            break
    if raw is None:
        return []
    value = raw.split("=", 1)[1]
    for _ in range(3):                      # AE_CORE / AE_RING 一层就够
        expanded = re.sub(r"\$\((\w+)\)",
                          lambda m: " ".join(_makefile_variable(makefile, m.group(1))),
                          value)
        if expanded == value:
            break
        value = expanded
    return re.findall(r"Sources/[\w/]+\.(?:swift|m)", value)


def check_targets():
    section("3b 目标边界")
    makefile = read("Makefile")
    tweak = set(_makefile_variable(makefile, "Aevon_FILES"))
    prefs = set(_makefile_variable(makefile, "AevonPrefs_FILES"))
    if not tweak or not prefs:
        bad("targets: Makefile 里读不出两个 target 的文件清单 —— 这条检查失效了，先修它")
        return

    tweak_only = sorted(tweak - prefs)
    declared = {}
    for path in sorted(tweak | prefs):
        if not path.endswith(".swift"):
            continue
        text = re.sub(r"//[^\n]*", "", read(path))
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
        declared[path] = set(re.findall(
            r"^\s*(?:(?:public|internal|private|fileprivate|open|final)\s+)*"
            r"(?:class|struct|enum|protocol)\s+([A-Za-z_]\w*)", text, re.M))

    # A name the tweak declares and no prefs file declares can only be reached
    # from the tweak. Seeing it on the prefs side is the same class of failure
    # as the missing bridging header: the compiler is right, and it costs a CI.
    foreign = {}
    for path in tweak_only:
        for name in declared.get(path, set()):
            if any(name in declared.get(other, set()) for other in prefs):
                continue
            foreign[name] = path

    hits = []
    for path in sorted(prefs):
        if not path.endswith(".swift"):
            continue
        text = re.sub(r"//[^\n]*", "", read(path))
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
        for name, owner in sorted(foreign.items()):
            if re.search(rf"\b{name}\b", text):
                hits.append((path, name, owner))
    for path, name, owner in hits:
        bad(f"targets: {path} 用了 {name}，而它只编译进 tweak（{owner}）—— "
            f"bundle 会报 cannot find '{name}' in scope")
    if not hits:
        ok(f"targets: prefs 侧没有引用 tweak 独有的 {len(foreign)} 个类型")


# ---------------------------------------------------------------------------
# 4  版本号：四处必须一致，且 preflight 会因此失败
# ---------------------------------------------------------------------------
def version():
    section("4 版本号")
    found = {}
    m = re.search(r"^Version:\s*(\S+)", read("control"), re.M)
    if m:
        found["control"] = m.group(1)
    m = re.search(r'static let version\s*=\s*"([^"]+)"', read("Sources/Core/Paths.swift"))
    if m:
        found["Paths.swift"] = m.group(1)
    try:
        info = plistlib.loads(open(f"{BUNDLE}/Info.plist", "rb").read())
        found["Info.plist"] = info.get("CFBundleShortVersionString")
    except Exception as exc:                                    # noqa: BLE001
        bad(f"version: Info.plist 读不出来：{exc}")
    m = re.search(r'VERSION="([^"]+)"', read("layout/DEBIAN/postinst"))
    if m:
        found["postinst"] = m.group(1)

    names = ["control", "Paths.swift", "Info.plist", "postinst"]
    absent = [n for n in names if n not in found]
    if absent:
        bad(f"version: 这些地方找不到版本号：{', '.join(absent)}")
        return None

    values = set(found.values())
    if len(values) != 1:
        bad("version: 四处版本号不一致 —— " +
            ", ".join(f"{k}={v}" for k, v in found.items()) +
            "；CI preflight 会因此失败")
        return None
    ok(f"version: 四处一致 = {sorted(values)[0]}（本次不改号，除非明确要求）")
    return sorted(values)[0]


# ---------------------------------------------------------------------------
# 5  Python 与 plist 的基本合法性
# ---------------------------------------------------------------------------
def check_python():
    section("5 脚本语法")
    broken = []
    for name in sorted(os.listdir("tools")):
        if not name.endswith(".py"):
            continue
        path = os.path.join("tools", name)
        try:
            py_compile.compile(path, cfile=os.path.join(tempfile.gettempdir(),
                                                        name + "c"), doraise=True)
        except py_compile.PyCompileError as exc:
            broken.append(f"{path}: {exc.msg.splitlines()[0]}")
    if broken:
        for line in broken:
            bad(f"python: {line}")
    else:
        ok("python: tools/*.py 全部通过语法检查")


def check_plists():
    section("6 面板 plist")
    root_path = f"{BUNDLE}/Root.plist"
    try:
        root = plistlib.loads(open(root_path, "rb").read())
    except Exception as exc:                                    # noqa: BLE001
        bad(f"plist: Root.plist 解析失败：{exc}")
        return
    items = root.get("items", [])
    if len(items) < 20:
        bad(f"plist: Root 只有 {len(items)} 行，页面会很空")
    else:
        ok(f"plist: Root {len(items)} 行")

    signatures = {}
    for name in PANELS:
        path = f"{BUNDLE}/{name}.plist"
        if not os.path.exists(path):
            bad(f"plist: 缺少 {name}.plist")
            continue
        try:
            entries = plistlib.loads(open(path, "rb").read()).get("items", [])
        except Exception as exc:                                # noqa: BLE001
            bad(f"plist: {name}.plist 解析失败：{exc}")
            continue
        if len(entries) < 3:
            bad(f"plist: {name} 只有 {len(entries)} 行")
        signatures[name] = tuple(
            (e.get("cell"), e.get("label"), e.get("key"), e.get("action"))
            for e in entries)

    clones = [a for a in signatures for b in signatures
              if a < b and signatures[a] == signatures[b]]
    if clones:
        bad(f"plist: 这些面板内容完全相同：{', '.join(clones)} —— "
            f"面板 plist 大概又被忽略了")
    elif signatures:
        counts = [len(v) for v in signatures.values()]
        ok(f"plist: {len(signatures)} 个面板各不相同，{min(counts)}–{max(counts)} 行")

    # 根页面里每个 openPanel: 必须指明打开哪个面板
    opening = [i for i in items if i.get("action") == "openPanel:"]
    unclear = [i.get("label") for i in opening if not i.get("panel")]
    if unclear:
        bad(f"plist: 这些行要打开面板却没写 panel 键：{unclear}")
    elif opening:
        ok(f"plist: {len(opening)} 行面板入口都带了 panel 键")


def check_actions():
    """plist 里的 action 必须有 @objc 方法接住，否则就是一行死按钮。"""
    section("7 按钮动作")
    actions = set()
    for name in ["Root"] + PANELS:
        path = f"{BUNDLE}/{name}.plist"
        if not os.path.exists(path):
            continue
        for entry in plistlib.loads(open(path, "rb").read()).get("items", []):
            if entry.get("action"):
                actions.add(entry["action"])

    sources = ""
    for name in sorted(os.listdir("Sources/Prefs")):
        if name.endswith(".swift"):
            sources += read(os.path.join("Sources/Prefs", name))

    if not actions:
        warn("actions: 一个按钮都没有？")
        return
    dead = []
    for action in sorted(actions):
        base = action.rstrip(":")
        if not re.search(r"@objc[^\n]*\n?[^\n]*func\s+" + re.escape(base) + r"\s*\(",
                         sources):
            dead.append(action)
    if dead:
        for action in dead:
            bad(f"actions: {action} 没有对应的 @objc func —— 点了不会有反应")
    else:
        ok(f"actions: {len(actions)} 个动作全部有实现")


# ---------------------------------------------------------------------------
# 8  审计断言 vs 源码：这是前几次构建失败的唯一来源
# ---------------------------------------------------------------------------
def check_audit_tokens():
    section("8 审计断言")
    audit = read("tools/audit-deb.py")

    # 源码文本：Swift / C / 头文件原样读；plist 走 plistlib 再转成文本，
    # 因为仓库里的面板 plist 是二进制格式，直接按字节搜 `openPanel:` 搜不到。
    parts = []
    for base in ("Sources", "layout"):
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in filenames:
                path = os.path.join(dirpath, name)
                if name.endswith((".swift", ".m", ".h")):
                    parts.append(read(path))
                elif name.endswith(".plist"):
                    try:
                        parts.append(repr(plistlib.loads(open(path, "rb").read())))
                    except Exception:                            # noqa: BLE001
                        parts.append(read(path))
    blob = "\n".join(parts)

    tokens = set()
    # 前一个字符不能是标识符的一部分：否则 `bad(f"..."` 里那个 b 会被当成
    # 字节串前缀，把整段代码吞进 token 里。
    for literal in re.findall(r'(?<![A-Za-z0-9_])b"((?:[^"\\\n]|\\.)*)"', audit):
        try:
            token = literal.encode().decode("unicode_escape")
        except UnicodeDecodeError:
            token = literal
        if len(token) < 5:
            continue
        if token.startswith(("Library/", "DEBIAN/", "usr/", "var/jb", "!<")):
            continue
        tokens.add(token)

    missing = sorted(t for t in tokens if t not in blob)
    if missing:
        for token in missing:
            bad(f"audit: 断言了「{token}」，但源码里找不到这个字符串 —— "
                f"release 二进制里也不会有，CI 必失败")
    else:
        ok(f"audit: {len(tokens)} 条内容断言全部能在源码里找到")

    # Swift 把 ≤15 字节的字符串字面量编成立即数塞进指令，字节流里根本没有。
    # 所以「ring: trash 」这种短标记在 dylib 里 grep 不到，审计必挂 —— 而且
    # 本地看不出、只在 CI 里挂。这条把它挡在推送之前：标记必须够长。
    for token in sorted(tokens):
        if token.startswith(("ring: ", "prefs: ", "scene: ", "scene2: ")) and len(token.encode()) < 16:
            bad(f"audit: 标记「{token}」只有 {len(token.encode())} 字节，"
                f"Swift 会把它编成立即数，二进制里搜不到 —— 至少再加几个字")


# ---------------------------------------------------------------------------
# 9  Swift 静态检查（只抓过去真出现过的那几类）
# ---------------------------------------------------------------------------
def check_swift():
    section("9 Swift 静态")
    problems = []
    for dirpath, _dirnames, filenames in os.walk("Sources"):
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name).replace("\\", "/")
            text = read(path)

            stripped = re.sub(r"//[^\n]*", "", text)
            stripped = re.sub(r'""".*?"""', '""', stripped, flags=re.S)
            stripped = re.sub(r'"(?:\\.|[^"\\])*"', '""', stripped)
            for open_ch, close_ch, label in (("{", "}", "大括号"),
                                             ("(", ")", "圆括号"),
                                             ("[", "]", "方括号")):
                delta = stripped.count(open_ch) - stripped.count(close_ch)
                if delta:
                    problems.append(f"{path}: {label}不平衡 {delta:+d}")

            for pattern, why in (
                (r"\btry!", "try! 在系统进程里崩溃即桌面重启"),
                (r"\bas!\s", "as! 强转失败会崩"),
                (r"UIApplication\.shared\b", "SpringBoard 里没有可靠的 shared"),
            ):
                for line in stripped.splitlines():
                    if re.search(pattern, line):
                        problems.append(f"{path}: {why} —— {line.strip()[:70]}")

    if problems:
        for line in problems:
            bad(f"swift: {line}")
    else:
        ok("swift: 括号平衡，无 try! / as! / UIApplication.shared 裸用")


# ---------------------------------------------------------------------------
# 10  设置生成器幂等：plist 是不是从生成器「新鲜」出来的
# ---------------------------------------------------------------------------
def check_generator():
    section("10 生成器同步")
    paths = sorted(os.path.join(BUNDLE, n) for n in os.listdir(BUNDLE)
                   if n.endswith(".plist"))
    before = {}
    for path in paths:
        with open(path, "rb") as fh:
            before[path] = fh.read()

    result = subprocess.run([sys.executable, "tools/gen-settings.py"],
                            capture_output=True)
    if result.returncode != 0:
        bad("generator: tools/gen-settings.py 跑不通 —— " +
            result.stderr.decode("utf-8", "replace").strip().splitlines()[-1:][0])
        return

    changed = []
    for path in paths:
        with open(path, "rb") as fh:
            if fh.read() != before[path]:
                changed.append(path)
    if changed:
        for path in changed:
            bad(f"generator: {path} 与生成器输出不一致（已重新生成，需要提交）")
    else:
        ok("generator: 面板 plist 与生成器输出一致（无漂移）")


# ---------------------------------------------------------------------------
def print_manifest(files, ver):
    if not LIST:
        return
    print("")
    print("== 将要推送的文件（gh-push 是全量快照，以下即远端最终内容）")
    groups = {"源码": [], "布局/plist": [], "工具链": [], "文档": [], "其它": []}
    for path in files:
        if path.startswith("Sources/"):
            groups["源码"].append(path)
        elif path.startswith("layout/"):
            groups["布局/plist"].append(path)
        elif path.startswith("tools/") or path in ALLOWED_EXACT:
            groups["工具链"].append(path)
        elif path.startswith("docs/") or path.lower().endswith(".md"):
            groups["文档"].append(path)
        else:
            groups["其它"].append(path)
    for label, items in groups.items():
        if not items:
            continue
        print(f"  {label}（{len(items)}）")
        for path in items:
            print(f"    {path}")


def main():
    files = tracked()
    check_manifest(files)
    check_untracked(files)
    check_makefile()
    check_targets()
    ver = version()
    check_python()
    check_plists()
    check_actions()
    check_audit_tokens()
    check_swift()
    check_generator()

    if not QUIET:
        print_manifest(files, ver)
    print("")

    # 失败原因永远打印 —— 一个只说「不行」不说为什么的闸门，最后一定会被
    # 绕过。--quiet 只是不刷 PASS 行和清单。
    if failures:
        for msg in failures:
            print(f"  [FAIL] {msg}")
        print("")
        print(f"  gate: 版本号 {ver or '未知'}，仓库 {len(files)} 个文件")
        print(f"PUSH-GATE: FAIL — {len(failures)} 项，禁止推送")
        return 1
    if not QUIET:
        print("PUSH-GATE: PASS — 可以推送构建")
    return 0


QUIET = "--quiet" in sys.argv
LIST = "--list" in sys.argv

if __name__ == "__main__":
    sys.exit(main())
