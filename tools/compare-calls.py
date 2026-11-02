#!/usr/bin/env python3
"""调用点核对 —— 母本 123 条调用 与 本机实测 的对齐表。

两侧数据来源不同，所以必须分开说：

  母本侧（expected）  stheno-逆向分析/analysis/extracts/stheno-selector-surface.txt
                      给出的 123 条调用，加上逆向蓝图里已经记下归属/签名的那几条。
  本机侧（actual）    手机上点「核对调用点」产生的 `calls: defined by …` 行，
                      由 SceneProbe.runCalls() 全进程遍历自有方法表得到，
                      不计数继承命中（继承命中会让 3197/3198 个类都"响应"）。

判据只有一条：每一条母本调用都能在本机落到一个明确定义类上，且签名一致。
在这条满足之前不创建任何窗口 —— 落错类的调用比调用不存在的更危险，因为它会
返回一个值，然后你在错的路上继续写。

用法：
  python tools/compare-calls.py /path/to/Aevon.log
  python tools/compare-calls.py /path/to/Aevon.log --md out.md

退出码：0 = 全部对齐；1 = 有缺失或签名不符；2 = 日志里没有可用的 calls: 段。
"""

import os
import re
import sys

# 母本自用选择子的完整集合。顺序即逆向 dump 的字母序。
SELECTORS = [
    "__swift_objectForKeyedSubscript:",
    "_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:",
    "_addAppLayoutToFront:",
    "_applicationIconImageForBundleIdentifier:format:scale:",
    "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:",
    "_didExitWithContext:",
    "_dismissPresentable:withReason:animated:userInfo:",
    "_handleClickAndDragHomeGesture:",
    "_handleDeckSwitcherPanGesture:",
    "_handlePan:",
    "_handlePullGesture:",
    "_handleTapOnView:",
    "_killForReason:andReport:withDescription:completion:",
    "_scene:interceptUpdateWithNewSettings:",
    "_setDeactivationReasons:onScene:withSettings:reason:",
    "addObserverForName:object:queue:usingBlock:",
    "applicationDidFinishLaunching:",
    "applicationProxyForIdentifier:",
    "applicationWithBundleIdentifier:",
    "bezierPathWithRoundedRect:cornerRadius:",
    "client:didUpdateClientSettings:withDiff:transitionContext:",
    "closeAndReturnError:",
    "conformsToProtocol:",
    "containsPoint:",
    "createFileAtPath:contents:attributes:",
    "createPresenterWithIdentifier:priority:",
    "dataWithJSONObject:options:error:",
    "deactivateWithTransitionContext:",
    "dictionaryWithObject:forKey:",
    "displayItemWithType:bundleIdentifier:uniqueIdentifier:",
    "enumerateApplicationsOfType:block:",
    "enumerateScenesWithBlock:",
    "fileExistsAtPath:",
    "fileHandleForWritingAtPath:",
    "frontDisplayDidChange:",
    "functionWithName:",
    "gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:",
    "gestureRecognizer:shouldReceiveEvent:",
    "gestureRecognizer:shouldReceivePress:",
    "gestureRecognizer:shouldReceiveTouch:",
    "gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:",
    "gestureRecognizer:shouldRequireFailureOfGestureRecognizer:",
    "gestureRecognizerShouldBegin:",
    "handleTransitionRequestForGestureComplete:",
    "hasSuffix:",
    "hitTest:withEvent:",
    "iconManager:launchIconForIconView:withActions:",
    "impactOccurredWithIntensity:",
    "initWithArray:",
    "initWithCGImage:scale:orientation:",
    "initWithCoder:",
    "initWithFrame:",
    "initWithImage:",
    "initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:",
    "initWithPath:",
    "initWithSceneLayer:",
    "initWithString:",
    "initWithStyle:",
    "initWithSuiteName:",
    "initWithTarget:",
    "initWithURL:",
    "initWithURL:workspaceOriginatingProcess:",
    "initWithWindowScene:",
    "insertSubview:atIndex:",
    "isApplicationForeground:",
    "isApplicationRunningAsViewService:",
    "isEqual:",
    "isKindOfClass:",
    "isMemberOfClass:",
    "launchApplicationWithIdentifier:suspended:",
    "loadNibNamed:owner:options:",
    "localizedStringForKey:value:table:",
    "locationInView:",
    "materialViewWithRecipe:configuration:initialWeighting:",
    "noteActiveInterfaceOrientationWillChangeToOrientation:",
    "numberWithInt:",
    "objectAtIndexedSubscript:",
    "objectForInfoDictionaryKey:",
    "pathForResource:ofType:",
    "performSelector:",
    "performSelector:withObject:",
    "performSelector:withObject:withObject:",
    "presentPresentable:withOptions:userInfo:",
    "removePersistentDomainForName:",
    "respondsToSelector:",
    "setAnimationSettings:",
    "setAutoresizingMask:",
    "setBackgroundColor:",
    "setCancelsTouchesInView:",
    "setClipsToBounds:",
    "setContentMode:",
    "setContentScaleFactor:",
    "setDateFormat:",
    "setForeground:",
    "setFrame:",
    "setHandleClick:",
    "setHidden:",
    "setImage:",
    "setInterfaceOrientation:",
    "setInterfaceOrientationMode:",
    "setResizesHostedContext:",
    "setRootViewController:",
    "setState:",
    "setUserInteractionEnabled:",
    "setUserInterfaceStyle:",
    "setWindowLevel:",
    "setWindowScene:",
    "settingsWithDuration:timingFunction:",
    "storyboardWithName:bundle:",
    "stringFromDate:",
    "stringWithFormat:",
    "stringWithUTF8String:",
    "touchesBegan:withEvent:",
    "touchesCancelled:withEvent:",
    "touchesEnded:withEvent:",
    "touchesMoved:withEvent:",
    "translationInView:",
    "uninstallApplication:",
    "updateSettings:withTransitionContext:completion:",
    "valueForKey:",
    "velocityInView:",
    "writeData:",
    "zStackParticipantDidChange:",
]

# (类, 签名) 都要核对：逆向资料把归属写死了的调用
EXACT = {
    # 逆向与真机两侧一致（2026-11-02 第二段探针 run 实测）
    "createPresenterWithIdentifier:priority:": ("UIScenePresentationManager", "@32@0:8@16q24"),
    # 以下四条：归属由 2026-11-02 第二段探针在 iOS 17.3.1 上实测坐实
    "initWithSceneLayer:": ("_UIContextLayerHostView", "@24@0:8@16"),
    "enumerateScenesWithBlock:": ("FBSceneManager", "v24@0:8@?16"),
    "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:"
    "fromRemnant:usingClientProvider:completion:":
        ("FBSceneManager", "@72@0:8@16@24@32@40@48@56@?64"),
    "deactivateWithTransitionContext:": ("FBScene", "v24@0:8@16"),
    # 逆向蓝图 §3.1 记的归属（本次 dump 没有覆盖到该类，故仅作逆向侧期望）
    "applicationWithBundleIdentifier:": ("SBApplicationController", "@24@0:8@16"),
}

# 只核对签名，不要求归属：逆向资料记了签名、但没坐实归属类
ENCODING_ONLY = {
    "_scene:interceptUpdateWithNewSettings:": "v32@0:8@16@24",
    "_setDeactivationReasons:onScene:withSettings:reason:": "v48@0:8Q16@24@32@40",
}

# 承载关键，但两侧都没有归属基线 —— 实测出来是什么就记什么，不预设，
# 但必须在表里显眼，因为这几条决定浮窗能不能立起来。
#
# 特别记一笔：`setResizesHostedContext:` 与真机上存在的
# `SBDeviceApplicationSceneViewController -setSceneResizesHostedContext:`（多一个 Scene）
# 是**两个不同的选择子**，不能互相顶替。上一版本工具把前者的归属写成了后者所在的类，
# 那是错的，已删掉 —— 错误的基线比没有基线更糟，它会把正确答案报成 OWNER-DIFF。
CARRIER_CRITICAL = {
    "setResizesHostedContext:",
    "createPresenterWithIdentifier:priority:",
    "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:"
    "fromRemnant:usingClientProvider:completion:",
    "initWithWindowScene:",
    "setWindowScene:",
    "setWindowLevel:",
    "presentPresentable:withOptions:userInfo:",
    "_dismissPresentable:withReason:animated:userInfo:",
    "client:didUpdateClientSettings:withDiff:transitionContext:",
    "updateSettings:withTransitionContext:completion:",
    "deactivateWithTransitionContext:",
}

# 母本**自己的类**实现的方法（analysis/extracts/stheno-classdump-arm64e.txt，11 个类）。
#
# 这些选择子出现在母本的 __objc_methname 里，是因为它自己实现或覆写了它们，
# 不代表它调用了系统类的同名方法。所以它们的 n=0 不是缺失，是意料之中。
# 5 条：SthenoWindow 的 -init 系列与 -hitTest:withEvent:，
#       FullScreenBackGesture.Coordinator 的 -gestureRecognizerShouldBegin:。
#
# 注意 `initWithWindowScene:` 同时是母本自有**和**承载关键（建窗口的入场券）：
# 两个标记并存，不能因为归到自有方法就把它从承载判定里摘出去。
OWN_METHODS = {
    "gestureRecognizerShouldBegin:",
    "hitTest:withEvent:",
    "initWithCoder:",
    "initWithFrame:",
    "initWithWindowScene:",
}

BEGIN = "calls: definition begin"
END = "calls: definition end"
# Log.write 会在正文前加「时间戳 [版本] 」，所以不能锚行首，只能 search。
# 锚行首的写法会把一份完整 dump 全部判成截断 —— 实测踩到过。
LINE = re.compile(r"calls: defined by (.+?) n=(\d+)(.*)$")
# 0.0.9 起扫描分两段：SB/FB/UI 家族先走完，把结果印成 phase1，再走剩下的。
# phase1 不是结论（后面的类也可能定义同一个选择子），但它证明「第一段活着」，
# 并且在第二段把 SpringBoard 带走时是唯一能用的数据。
PHASE1 = re.compile(r"calls: phase1 by (.+?) n=(\d+)(.*)$")
# 启动时对上一次死亡的回读：类名 + 序号。这条比任何猜测都硬。
DEATH = re.compile(r"calls: previous scan died at (\d+) (\S+)")
SKIP = re.compile(r"skip=(\d+)")


PROGRESS = re.compile(r"calls: scan reached (\d+) (\S+) rss=(-?\d+)mb")
COVERAGE = re.compile(r"upto=(\d+) of (\d+)")


def parse(path):
    """取日志里最后一段 dump：begin 之后、end 之前。

    另外几样东西也一起取：
      · 最后一次 `calls: scan reached` 进度行 —— 死掉时能说出停在哪；
      · 结束行里的 `upto=X of Y` 和 `skip=N`；
      · `phase1` 段（第一段的结果，第二段死掉时唯一的凭据）；
      · `previous scan died at <i> <name>` —— 上一次扫描的死亡标记回读，
        这是唯一能区分「某个类有毒」和「被系统杀掉」的证据。
    """
    dump, inside, found_any = {}, False, False
    progress = None
    coverage = None
    scoped = False
    phase1 = {}
    deaths = []
    skip = 0
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            hit_death = DEATH.search(line)
            if hit_death:
                deaths.append((int(hit_death.group(1)), hit_death.group(2)))
                continue
            if BEGIN in line:
                dump, inside, found_any = {}, True, True
                phase1 = {}
                hit_skip = SKIP.search(line)
                if hit_skip:
                    skip = int(hit_skip.group(1))
                continue
            if END in line:
                inside = False
                hit = COVERAGE.search(line)
                if hit:
                    coverage = (int(hit.group(1)), int(hit.group(2)))
                    # 0.0.11 起，扫描到家族边界就自己停 —— 那个 `upto < of`
                    # 是我们选的，不是被杀的。两者的读法完全相反，所以必须
                    # 在结束行里标出来，不能靠工具去猜。
                    scoped = "scope=phase1" in line
                hit_skip = SKIP.search(line)
                if hit_skip:
                    skip = int(hit_skip.group(1))
                continue
            hit_progress = PROGRESS.search(line)
            if hit_progress:
                progress = (int(hit_progress.group(1)), hit_progress.group(2),
                            int(hit_progress.group(3)))
                continue
            hit_phase = PHASE1.search(line)
            if hit_phase:
                owners = []
                for chunk in hit_phase.group(3).strip().split():
                    if "|" in chunk:
                        name, encoding = chunk.split("|", 1)
                        owners.append((name.rstrip("+-"), encoding))
                phase1[hit_phase.group(1)] = (int(hit_phase.group(2)), owners)
                continue
            if not inside:
                continue
            hit = LINE.search(line)
            if not hit:
                continue
            selector, count, rest = hit.group(1), int(hit.group(2)), hit.group(3).strip()
            owners = []
            for chunk in rest.split():
                if "|" in chunk:
                    name, encoding = chunk.split("|", 1)
                    owners.append((name.rstrip("+-"), encoding))
            dump[selector] = (count, owners)
    return dump, found_any, progress, coverage, phase1, deaths, skip, scoped


def verdicts(dump, scoped=False):
    """每一行的判定。

    关键区分：`n=0` 是 dump 明确告诉我们「本机没人定义它」，那是结论；
    而 dump 里根本没有这一行，是**日志被截断**，不是结论。把两者混成一个
    ABSENT，就会得到「118 条调用在这台 iOS 上不存在」这种极具说服力、
    又完全错误的答案 —— 所以后者单独记 NOT-IN-DUMP，并且让工具失败。
    """
    rows = []
    for selector in SELECTORS:
        if selector not in dump:
            rows.append(("NOT-IN-DUMP", selector, "-", "-", ""))
            continue

        count, owners = dump[selector]
        names = [name for name, _ in owners]
        encodings = [encoding for _, encoding in owners]

        if count == 0:
            # 家族外的类这次根本没扫，n=0 只说明「不在这几个家族里」。
            # 记成 ABSENT 就是拿没扫当没定义 —— 正是这个工具存在的理由。
            rows.append(("OUT-OF-SCOPE" if scoped else "ABSENT", selector, "-", "-", ""))
            continue

        if selector in EXACT:
            want_class, want_enc = EXACT[selector]
            if want_class not in names:
                rows.append(("OWNER-DIFF", selector, want_class, " ".join(names), want_enc))
            elif want_enc and want_enc not in encodings:
                rows.append(("ENCODING-DIFF", selector, want_enc, " ".join(encodings), want_enc))
            else:
                rows.append(("MATCH", selector, want_class, want_enc, want_enc))
            continue

        if selector in ENCODING_ONLY:
            want_enc = ENCODING_ONLY[selector]
            if want_enc in encodings:
                rows.append(("MATCH", selector, want_enc, want_enc, want_enc))
            else:
                rows.append(("ENCODING-DIFF", selector, want_enc, " ".join(encodings), want_enc))
            continue

        rows.append(("PRESENT", selector, " ".join(names[:3]), " ".join(encodings[:3]), ""))
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    md_out = sys.argv[sys.argv.index("--md") + 1] if "--md" in sys.argv else None

    if not os.path.isfile(path):
        print("找不到日志文件：%s" % path)
        return 2

    dump, found_any, progress, coverage, phase1, deaths, skip, scoped = parse(path)
    if deaths:
        # 上一次扫描的死亡标记。有名字就是某个类有毒；只有序号没有名字，
        # 说明连类名都没写下去 —— 那是被系统在标记前就杀掉了。
        print("上一次扫描死在：第 %d 个类 %s（这次启动已写进跳过表）"
              % (deaths[-1][0], deaths[-1][1]))
    if skip:
        # skip 是「故意没扫的类」总数：死亡标记黑名单 + `_NSZombie_*`（运行时
        # 按需新建，扫它等于在读一张正在被写的方法表）。两者都不该成为任何选择子
        # 的归属，所以它们相关的 n=0 要打折扣。
        print("本次故意跳过 %d 个类（黑名单 + _NSZombie_）—— 它们不会成为任何选择子的归属"
              "（相关的 n=0 要打折扣）。" % skip)
    if progress:
        print("最后一次进度：扫到第 %d 个类（%s），rss=%d MB"
              % (progress[0], progress[1], progress[2]))

    if not found_any:
        print("日志里没有 calls: 段 —— 请求没到 SpringBoard，或转储还没跑完。")
        return 2

    # 第二段把 SpringBoard 带走时，只有第一段（SB/FB/UI 家族）的数据。
    # 它不能当结论用（后面的类也可能是归属），但足够判断「有没有死路」。
    if not dump and phase1:
        rows = verdicts(phase1, True)
        counts = {}
        for verdict, selector, want, got, enc in rows:
            counts[verdict] = counts.get(verdict, 0) + 1
        print("\n[PHASE1-ONLY] 只拿到第一段 %d 条 —— 第二段没有结束行。" % len(phase1))
        for name in ("MATCH", "PRESENT", "OWNER-DIFF", "ENCODING-DIFF", "ABSENT"):
            if name in counts:
                print("  %-14s %3d" % (name, counts[name]))
        absent = [row[0] for row in rows
                  if row[0] == "ABSENT" and row[1] not in OWN_METHODS]
        dead = [row[0] for row in rows if row[0] in ("OWNER-DIFF", "ENCODING-DIFF")]
        if absent:
            print("  第一段里就没有定义的：%s" % ", ".join(absent[:6]))
        print("  这些是「至少在 SB/FB/UI 家族里成立」的部分结论，不是对齐结论。")
        return 2

    if not dump:
        print("找到了 calls: 段但一行也解析不出来 —— 转储中途断了，重跑一次。")
        return 2

    # 扫到一半就结束的 dump，比没有 dump 更危险：它会把「还没扫到」印成 n=0，
    # 而 n=0 的读法是「这台 iOS 上没有它」。所以先拦这一种。
    if scoped and coverage and coverage[0] < coverage[1]:
        print("\n[scope=phase1] 这一趟只走家族段（%d / %d 个类），是我们自己停的；"
              "越过边界的类这次不参与判定。" % (coverage[0], coverage[1]))
        print("  所以下面 n=0 的读法是「不在这几个家族里」，不是「本机没有它」。")

    if coverage and coverage[0] < coverage[1] and not scoped:
        print("\n[PARTIAL] 这一趟只扫了 %d / %d 个类就停了 —— 排在后面的 n=0 不是结论。"
              % (coverage[0], coverage[1]))
        print("  看结束行末尾的 reason：`three minute limit` 是时间上限，"
              "`memory ceiling` 是内存闸（我们自己停的），两个都没有才是被系统杀掉的。")
        print("  被系统杀掉时，下一次启动会在日志里写出「previous scan died at」那一行。")
        return 2

    rows = verdicts(dump, scoped)
    buckets = {}
    for verdict, selector, want, got, enc in rows:
        buckets.setdefault(verdict, []).append((selector, want, got, enc))

    own = len([s for s in SELECTORS if s in OWN_METHODS])
    print("调用点核对 · 母本 %d 条（其中 %d 条是母本自己实现的方法），本机 dump 覆盖 %d 条"
          % (len(SELECTORS), own,
             len(SELECTORS) - len(buckets.get("NOT-IN-DUMP", []))))
    for name in ("MATCH", "PRESENT", "OWNER-DIFF", "ENCODING-DIFF", "ABSENT",
                 "OUT-OF-SCOPE", "NOT-IN-DUMP"):
        if name in buckets:
            print("  %-14s %3d" % (name, len(buckets[name])))

    # 截断先于一切结论：日志不全时，其它四类判定都不可信。
    if "NOT-IN-DUMP" in buckets:
        print("\n[NOT-IN-DUMP] dump 里没有这些行 —— 日志被截断了，不是调用不存在")
        print("  这一段的 begin/end 之间应当有 %d 行，实际只解析出 %d 行。"
              % (len(SELECTORS), len(dump)))
        print("  先重跑一次（按钮 → 等十几秒 → 重新导出日志），再谈对齐。")
        if progress:
            print("  这一趟死在：第 %d 个类（%s），rss=%d MB"
                  % (progress[0], progress[1], progress[2]))
        for selector, want, got, enc in buckets["NOT-IN-DUMP"][:5]:
            print("  缺行: %s" % selector)
        return 2

    for name, note, limit in (
            ("ABSENT", "本机无人定义 —— 这条路走不通", 20),
            ("OWNER-DIFF", "归属类与逆向记录不一致 —— 必须先解释清楚", 20),
            ("ENCODING-DIFF", "签名与逆向记录不一致 —— 照旧签名调用会崩", 20)):
        if name in buckets:
            print("\n[%s] %s" % (name, note))
            for selector, want, got, enc in buckets[name][:limit]:
                print("  %s%s" % (selector, "   [母本自有方法，n=0 是意料之中]"
                                  if selector in OWN_METHODS else ""))
                print("     逆向: %s" % (want or "-"))
                print("     本机: %s" % (got or "-"))
            if len(buckets[name]) > limit:
                print("  ...另有 %d 条，见 md" % (len(buckets[name]) - limit))

    if "PRESENT" in buckets:
        rows_present = sorted(buckets["PRESENT"],
                              key=lambda row: (row[0] not in CARRIER_CRITICAL, row[0]))
        critical = sum(1 for row in rows_present if row[0] in CARRIER_CRITICAL)
        print("\n[PRESENT] 本机有定义，逆向只记了调用、没记归属（这次实测即为新基准）")
        print("  其中承载关键 %d 条，逐条列出；其余只报前 8 条。" % critical)
        shown = 0
        for selector, want, got, enc in rows_present:
            star = selector in CARRIER_CRITICAL
            if not star and shown >= 8:
                continue
            shown += 0 if star else 1
            print("  %s %s -> %s" % ("*" if star else " ", selector, want))
        rest = len(rows_present) - shown - critical
        if rest > 0:
            print("  ...其余 %d 条见 md" % rest)

    if "OUT-OF-SCOPE" in buckets:
        print("\n[OUT-OF-SCOPE] 家族段里没人定义这 %d 条 —— 它们可能在家族外，"
              "也可能是本机真没有。这一趟不下结论。" % len(buckets["OUT-OF-SCOPE"]))
        for selector, want, got, enc in buckets["OUT-OF-SCOPE"][:20]:
            print("  %s" % selector)
            print("     逆向: %s" % (EXACT.get(selector, ("-", ""))[0] or "-"))

    own_absent = len([row for row in buckets.get("ABSENT", []) if row[0] in OWN_METHODS])
    absent = len(buckets.get("ABSENT", [])) - own_absent
    hard = (absent + len(buckets.get("OWNER-DIFF", [])) + len(buckets.get("ENCODING-DIFF", []))
            + len(buckets.get("OUT-OF-SCOPE", [])))
    print("\n结论：%s" % ("全部对齐，可以等指令做浮窗" if hard == 0
                         else "%d 条还没有对上的证据，浮窗还不能开始" % hard))
    if own_absent:
        print("  （另有 %d 条 ABSENT 属于母本自有方法，不计入未对齐）" % own_absent)

    if md_out:
        with open(md_out, "w", encoding="utf-8") as handle:
            handle.write("| 判定 | 调用 | 母本自有 | 逆向记录 | 本机实测 |\n"
                         "|---|---|---|---|---|\n")
            for verdict, selector, want, got, enc in rows:
                handle.write("| %s | `%s` | %s | %s | %s |\n"
                             % (verdict, selector, "是" if selector in OWN_METHODS else "",
                                want or "-", got or "-"))
        print("表格已写入 %s" % md_out)
    return 0 if hard == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
