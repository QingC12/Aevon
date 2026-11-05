//
//  SceneProbe.swift — Aevon, the P0 probe for 窗口与场景.
//
//  Why look before building anything: the master's floating window is not a view
//  stuck into SpringBoard, it is its own UIScene built through
//  UIScenePresentationManager. Whether this iOS still exposes that surface, and
//  with exactly which signatures, cannot be guessed — a wrong type encoding is a
//  SpringBoard crash, and a wrong assumption about how the app's scene relates
//  to the carrier costs the whole phase. So this file only *looks*:
//
//    · which classes exist             NSClassFromString, nothing instantiated
//    · which selectors they answer     + the real method_getTypeEncoding
//    · what the live scene tree is     every scene, every window, right now
//    · whether a carrier-shaped view   _UIContextLayerHostView / *Presentation*
//      is already somewhere in it
//
//  Rules kept on purpose:
//    · never invoke an unknown selector — only responds(to:) is asked
//    · never create a scene, never touch a scene's settings
//    · one shot per request, so a respring cannot replay an old dump
//
//  Everything printed goes to /var/mobile/Aevon.log with a "scene: " prefix,
//  and every line is at least 16 bytes so it survives the strip (see
//  tools/push-gate.py: Swift encodes shorter literals as immediates).
//

import Foundation
import UIKit
import ObjectiveC

enum SceneProbe {

    // MARK: - Trigger

    /// SpringBoard side. The file is deleted before the dump, so a failed run
    /// cannot leave a landmine that fires on every boot. Settings writes it
    /// (SceneActions), because the request must not drag this file's whole
    /// carrier surface into the preferences bundle.
    @discardableResult
    static func consumeRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: Aevon.probePath) else { return false }
        let mode = (try? String(contentsOfFile: Aevon.probePath, encoding: .utf8)) ?? ""
        // Deleted before anything runs. The 0.0.7 attempt proved why that order
        // matters: the scan took SpringBoard down and this file was already
        // gone, so the crash could not replay itself on the next launch.
        try? FileManager.default.removeItem(atPath: Aevon.probePath)
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "api":    runSurface()
        case "calls":  runCalls()
        case "window": runWindow()
        default:       run()
        }
        return true
    }

    // MARK: - What to ask about

    // MARK: - Running

    /// "转储场景与窗口" — the live tree only.
    ///
    /// The class/selector encoding half of this dump (`dumpClasses`) was retired
    /// in 0.0.14: every line it printed is already written up in
    /// docs/REVERSE-NOTES.md, and the dylib is 1.2 KB over its 320 KB budget
    /// while a window build needs that room more. The button stays, because the
    /// tree walk is still the cheapest way to see what SpringBoard owns.
    static func run() {
        Log.write("scene: probe begin")
        dumpLiveTree()
        Log.write("scene: probe end")
    }

    /// Live scene tree + every window on it + a search for carrier-shaped views.
    /// All of this is public API except the `responds(to:)` audit, which only
    /// asks questions.
    private static func dumpLiveTree() {
        guard let application = sharedApplication() else {
            Log.write("scene: no UIApplication in this process")
            return
        }
        let scenes = application.connectedScenes
        Log.write("scene: live scenes " + String(scenes.count))

        for scene in scenes {
            let name = NSStringFromClass(type(of: scene))
            let identifier = scene.session.persistentIdentifier
            let state = String(scene.activationState.rawValue)
            let delegate = scene.delegate.map { String(describing: type(of: $0)) } ?? "none"
            Log.write("scene: live " + name + " id=" + identifier + " state=" + state
                      + " delegate=" + delegate)
            Log.write("scene: accepts " + name + " "
                      + accepted(scene, ["definition", "settings", "clientSettings"]))

            guard let windowScene = scene as? UIWindowScene else { continue }
            let bounds = windowScene.screen.bounds
            Log.write("scene: geometry " + String(Int(bounds.width)) + "x"
                      + String(Int(bounds.height))
                      + " orient=" + String(windowScene.interfaceOrientation.rawValue)
                      + " windows=" + String(windowScene.windows.count))
            for window in windowScene.windows {
                dumpWindow(window)
                walkCarriers(in: window, scene: name)
            }
        }
    }

    private static func dumpWindow(_ window: UIWindow) {
        let name = NSStringFromClass(type(of: window))
        let root = window.rootViewController.map { String(describing: type(of: $0)) } ?? "none"
        let bounds = window.bounds
        Log.write("scene: window level " + String(Int(window.windowLevel.rawValue)) + " " + name
                  + " hidden=" + (window.isHidden ? "yes" : "no")
                  + " key=" + (window.isKeyWindow ? "yes" : "no")
                  + " size=" + String(Int(bounds.width)) + "x" + String(Int(bounds.height))
                  + " root=" + root)
    }

    /// Depth-first over one window's view tree, printing only names that look
    /// like a scene carrier. Capped: SpringBoard's tree is large and this runs
    /// on the main thread.
    private static func walkCarriers(in window: UIWindow, scene: String) {
        var stack: [(view: UIView, depth: Int)] = [(window, 0)]
        var visited = 0
        var printed = 0
        while let entry = stack.popLast() {
            visited += 1
            if visited > 4000 { break }
            let name = NSStringFromClass(type(of: entry.view))
            if name.contains("ContextLayer") || name.contains("Presentation")
                || name.contains("SceneView") || name.contains("SceneHost") {
                if printed < 40 {
                    printed += 1
                    Log.write("scene: carrier view " + name + " depth=" + String(entry.depth)
                              + " scene=" + scene)
                }
            }
            if entry.depth < 14 {
                for subview in entry.view.subviews {
                    stack.append((subview, entry.depth + 1))
                }
            }
        }
    }

    // MARK: - Surface probe (retired in 0.0.11)

    /// Everything this dump measured — the class census, the method tables, the
    /// installed-app scene handles, FrontBoard's facade — is already written up
    /// in docs/REVERSE-NOTES.md. It was costing more of the shared 320 KB than
    /// the call table, which still has unanswered questions, so it is gone.
    /// The button stays: removing a row changes the panel, and the panel is not
    /// what is being measured here.
    static func runSurface() {
        Log.write("scene2: retired in 0.0.11, data in docs/REVERSE-NOTES.md")
    }

    // MARK: - Call table (the master's own calls, asked of iOS 17.3.1)

    /// `objc_copyClassList` hands back an autoreleasing pointer, which cannot be
    /// freed without a conversion Swift will not make; `objc_getClassList` into
    /// our own buffer is the same information with an owner. The first call is
    /// how you ask how big it has to be.
    ///
    /// The second call can return a number larger than the buffer — the runtime
    /// documents it, because classes can be created between the two calls — and
    /// reading that many entries means reading pointers past the end of a
    /// malloc block. Wrapped in `min`, which is the whole fix: a stale pointer
    /// looks exactly like a class until you ask it for a method list.
    private static func allClasses() -> [AnyClass] {
        let total = objc_getClassList(nil, 0)
        guard total > 0 else { return [] }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buffer.deallocate() }
        let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), total)
        guard count > 0 else { return [] }
        return (0..<Int(min(count, total))).map { buffer[$0] }
    }


    /// Every selector the reverse notes found in Stheno's `__objc_methname`,
    /// one per line, minus the three entries in that dump that only look like
    /// selectors: an https URL, a dyld rpath, and a stray type encoding.
    ///
    /// One string literal rather than an array of literals because Swift stores
    /// it as a single cstring, and this file shares a 320 KB budget with the
    /// carrier. Sorted, so a diff between two dumps is a real diff.
    private static let callSelectors = """
__swift_objectForKeyedSubscript:
_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:
_addAppLayoutToFront:
_applicationIconImageForBundleIdentifier:format:scale:
_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:
_didExitWithContext:
_dismissPresentable:withReason:animated:userInfo:
_handleClickAndDragHomeGesture:
_handleDeckSwitcherPanGesture:
_handlePan:
_handlePullGesture:
_handleTapOnView:
_killForReason:andReport:withDescription:completion:
_scene:interceptUpdateWithNewSettings:
_setDeactivationReasons:onScene:withSettings:reason:
addObserverForName:object:queue:usingBlock:
applicationDidFinishLaunching:
applicationProxyForIdentifier:
applicationWithBundleIdentifier:
bezierPathWithRoundedRect:cornerRadius:
client:didUpdateClientSettings:withDiff:transitionContext:
closeAndReturnError:
conformsToProtocol:
containsPoint:
createFileAtPath:contents:attributes:
createPresenterWithIdentifier:priority:
dataWithJSONObject:options:error:
deactivateWithTransitionContext:
dictionaryWithObject:forKey:
displayItemWithType:bundleIdentifier:uniqueIdentifier:
enumerateApplicationsOfType:block:
enumerateScenesWithBlock:
fileExistsAtPath:
fileHandleForWritingAtPath:
frontDisplayDidChange:
functionWithName:
gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:
gestureRecognizer:shouldReceiveEvent:
gestureRecognizer:shouldReceivePress:
gestureRecognizer:shouldReceiveTouch:
gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:
gestureRecognizer:shouldRequireFailureOfGestureRecognizer:
gestureRecognizerShouldBegin:
handleTransitionRequestForGestureComplete:
hasSuffix:
hitTest:withEvent:
iconManager:launchIconForIconView:withActions:
impactOccurredWithIntensity:
initWithArray:
initWithCGImage:scale:orientation:
initWithCoder:
initWithFrame:
initWithImage:
initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:
initWithPath:
initWithSceneLayer:
initWithString:
initWithStyle:
initWithSuiteName:
initWithTarget:
initWithURL:
initWithURL:workspaceOriginatingProcess:
initWithWindowScene:
insertSubview:atIndex:
isApplicationForeground:
isApplicationRunningAsViewService:
isEqual:
isKindOfClass:
isMemberOfClass:
launchApplicationWithIdentifier:suspended:
loadNibNamed:owner:options:
localizedStringForKey:value:table:
locationInView:
materialViewWithRecipe:configuration:initialWeighting:
noteActiveInterfaceOrientationWillChangeToOrientation:
numberWithInt:
objectAtIndexedSubscript:
objectForInfoDictionaryKey:
pathForResource:ofType:
performSelector:
performSelector:withObject:
performSelector:withObject:withObject:
presentPresentable:withOptions:userInfo:
removePersistentDomainForName:
respondsToSelector:
setAnimationSettings:
setAutoresizingMask:
setBackgroundColor:
setCancelsTouchesInView:
setClipsToBounds:
setContentMode:
setContentScaleFactor:
setDateFormat:
setForeground:
setFrame:
setHandleClick:
setHidden:
setImage:
setInterfaceOrientation:
setInterfaceOrientationMode:
setResizesHostedContext:
setRootViewController:
setState:
setUserInteractionEnabled:
setUserInterfaceStyle:
setWindowLevel:
setWindowScene:
settingsWithDuration:timingFunction:
storyboardWithName:bundle:
stringFromDate:
stringWithFormat:
stringWithUTF8String:
touchesBegan:withEvent:
touchesCancelled:withEvent:
touchesEnded:withEvent:
touchesMoved:withEvent:
translationInView:
uninstallApplication:
updateSettings:withTransitionContext:completion:
valueForKey:
velocityInView:
writeData:
zStackParticipantDidChange:
"""

    private struct CallOwner {
        let name: String
        let encoding: String
    }

    /// A dictionary of tuples would do the same job, but a named type means the
    /// `??` fallback site needs no type inference — and that site cannot be
    /// compiled on this machine, only in CI. `count` is every definition found;
    /// `owners` is capped, because a selector like `addSubview:` has dozens and
    /// the log is read by a human.
    private struct CallHit {
        var count: Int
        var owners: [CallOwner]
    }

    private static var callTargets = Set<String>()
    private static var callHits: [String: CallHit] = [:]
    private static var callQueue: [AnyClass] = []
    private static var callCursor = 0
    private static var callCeiling = 0
    private static var callStart = Date()
    private static var callBusy = false
    private static var callEdge = 0
    private static var callPhaseDone = false
    private static var callSkipped = 0
    private static var callStateFD: Int32 = -1

    /// The second attempt runs off the main thread. The first one walked the
    /// same classes in 600-class slices on the main thread and SpringBoard died
    /// six seconds in, before a single line of output was written — and from
    /// the log alone a killed main thread, a jetsam kill and one bad class look
    /// exactly the same. Going off-thread removes the first; `calls: scan
    /// reached` lines remove the guesswork about the other two.
    ///
    /// It also starts six seconds late on purpose. The request reaches
    /// SpringBoard about twelve seconds after boot, which is exactly when the
    /// process is still realising classes and attaching method lists on its own
    /// threads. Walking a method list while `attachCategories` is rewriting the
    /// same class is a use-after-free, and a probe has no business being the
    /// reason a phone resprings a third time.
    private static let callWorker = DispatchQueue(label: "com.aevon.calls", qos: .utility)

    /// Candidate families first, everything else second. This is not a filter —
    /// every class is still walked. It is an ordering: the master's own
    /// selectors land on SpringBoard (`SB*`), FrontBoard (`FB*`), UIKit
    /// (`UI*`, `_UI*`) and the Foundation/LaunchServices classes the master
    /// calls by name (`NS*`, `LS*`), so if the walk dies again the classes that
    /// matter have already been read and `phase1` lines record what they said.
    private static let callPriorityPrefixes = ["SB", "FB", "_UI", "UI", "NS", "LS", "CA", "BK", "XB", "SpringBoard"]

    /// SpringBoard side, third dump. The first two answered "does the class
    /// exist" and "what does this named class answer". Neither answers the
    /// question that decides whether P1 can be written at all: for each
    /// selector the master *actually uses*, which class on this iOS defines it,
    /// and with which type encoding.
    ///
    /// Ownership is the part that moves between releases — `setResizesHostedContext:`
    /// is on the carrier controller here, not on `_UIScenePresenter` — so it is
    /// measured, never assumed. A selector with `n=0` is the strongest possible
    /// negative: nobody in the process defines it, so it cannot be called.
    static func runCalls() {
        if callBusy {
            Log.write("calls: scan already running, request ignored")
            return
        }
        callTargets = Set(callSelectors.split(separator: "\n").map(String.init))
        callHits = [:]
        callCursor = 0
        callPhaseDone = false
        callSkipped = 0
        // Never walk a class that already took SpringBoard down. The list is
        // written at boot from the last death marker, so this is what turns
        // "the probe kills the phone" into "the probe gets one class further
        // every run".
        let poison = loadSkipList()
        let classes = allClasses()
        // Its own line: the ordering pass names every class on the main thread,
        // and if the log ends here the walk is not what died — this is.
        Log.write("calls: ordering walk over " + String(classes.count) + " classes")
        var head: [AnyClass] = []
        for cls in classes {
            let name = NSStringFromClass(cls)
            if poison.contains(name) {
                callSkipped += 1
                continue
            }
            // `_NSZombie_<X>` classes are minted on demand the first time an
            // object of class X is freed, and `__`-prefixed classes are minted
            // by the runtime itself. Walking one while that same class is still
            // being built is the cleanest way to fault on a method list that is
            // half attached — and no selector of ours lives there. The class
            // that ended two runs, `__NSGenericDeallocHandler`, is one of these.
            if name.hasPrefix("__") || name.hasPrefix("_NSZombie_") {
                callSkipped += 1
                continue
            }
            if priorityRank(of: name) < callPriorityPrefixes.count {
                head.append(cls)
            }
        }
        callQueue = head
        callEdge = head.count
        // `of` counts every class the process has, not just the ones this pass
        // touches. Dropping the tail from the queue would have made the end line
        // read `upto = of` and the dump look complete while ninety thousand
        // classes had never been read at all — the one lie this file exists to
        // avoid. The tail is not kept: only its size is needed.
        callCeiling = classes.count - callSkipped
        callStart = Date()
        installFaultWitness()
        Log.write("calls: definition begin v2 targets=" + String(callTargets.count)
                  + " classes=" + String(callCeiling)
                  + " phase1=" + String(callEdge)
                  + " scope=phase1"
                  + " skip=" + String(callSkipped))
        // The tail is never walked any more. 0.0.10 and 0.0.12 both died one or
        // two classes into it — different class each time, same position — so
        // the tail is not where a bad class lives, it is where classes the
        // runtime has not finished building live. It is read by name only, in
        // runTail(), and only for the selectors the walk could not answer.
        // No empty-queue guard: an empty queue simply walks nothing and the end
        // line reports `upto=0 of 0`. The guard that used to stand here cost
        // bytes in a binary that has none to spare and could never fire.
        callBusy = true
        callWorker.asyncAfter(deadline: .now() + 6.0) { scanAll() }
    }

    private static func priorityRank(of name: String) -> Int {
        for (index, prefix) in callPriorityPrefixes.enumerated() where name.hasPrefix(prefix) {
            return index
        }
        return callPriorityPrefixes.count
    }

    /// Installed for the length of one scan, and only one scan. Everything this
    /// file has learned about the deaths so far is inference from where the log
    /// stops: a poisonous class, a jetsam kill and a watchdog kill all end it
    /// mid sentence. A signal number splits the first from the other two, and a
    /// missing `call.fault` file after a death says the process was killed
    /// rather than faulted — which is a different bug in a different place.
    private static func installFaultWitness() {
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            _ = signal(sig, aevonFaultWitness)
        }
    }

    /// One class per marker write, index and name raw. `lseek` + `write` +
    /// `ftruncate` on a handle that is opened once: no allocation, no bridge,
    /// no log line, and it survives the SIGKILL that a signal handler cannot.
    private static func mark(_ cls: AnyClass, index: Int) {
        // `class_getName` is imported non-optional in this SDK, so there is no
        // optional to bind here — the guard is on the handle only.
        guard callStateFD >= 0 else { return }
        let name = class_getName(cls)
        let length = strlen(name)
        var slot = UInt32(truncatingIfNeeded: index)
        _ = lseek(callStateFD, 0, SEEK_SET)
        withUnsafeBytes(of: &slot) { _ = write(callStateFD, $0.baseAddress, 4) }
        _ = write(callStateFD, UnsafeRawPointer(name), length)
        _ = ftruncate(callStateFD, off_t(4 + length))
    }

    /// Straight through, on the worker queue, one autorelease pool per 250
    /// classes. There is nothing to yield to here — the run loop belongs to
    /// somebody else — and the pool is the part that matters: `NSStringFromSelector`
    /// runs once per method in the process, and without a pool those strings
    /// pile up until the process ends.
    private static func scanAll() {
        var reason = ""
        // Growth from here, never an absolute number. `ru_maxrss` is a *peak*,
        // and SpringBoard's peak is already hundreds of megabytes at boot — so
        // "stop above 220 MB" fired on the very first chunk and the 0.0.9 dump
        // ended at class 250 with `stopped at the memory ceiling`, twice.
        let baseMB = residentMegabytes()
        // The walk stops at the family boundary. Not because the answer ends
        // there — because the last two runs that walked past it died one and two
        // classes later. 0.0.10 died at 9827 `__NSGenericDeallocHandler`, 0.0.12
        // at 9828 `JSExport`: different class, same position, so the poison is
        // not a class but the neighbourhood, and stepping over one name at a
        // time would take a respring per name.
        let stop = callEdge > 0 ? callEdge : callCeiling
        callStateFD = open(Aevon.callStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if callStateFD < 0 {
            Log.write("calls: death marker unavailable, walking without it")
        }
        while callCursor < stop {
            // A probe that never finishes is a probe that cannot be trusted to
            // leave the phone alone. Three minutes is far past the expected few,
            // and past it we stop and say so in the end line — a partial dump
            // the reader can see is worth more than a process that never ends.
            if Date().timeIntervalSince(callStart) > 180 {
                reason = " stopped on the three minute limit"
                break
            }
            autoreleasepool {
                let end = min(callCursor + 250, stop)
                while callCursor < end {
                    let cls = callQueue[callCursor]
                    mark(cls, index: callCursor)
                    callCursor += 1
                    collectMethods(of: cls, meta: false)
                    collectMethods(of: cls, meta: true)
                }
            }
            if !callPhaseDone, callEdge > 0, callCursor >= callEdge {
                callPhaseDone = true
                emitPhase1()
            }
            let rss = residentMegabytes()
            // The progress line comes first, on purpose: when the ceiling broke
            // the run at class 250 there was no number in the log to argue with,
            // because the break was checked before the write.
            if callCursor < stop {
                Log.write("calls: scan reached " + String(callCursor) + " "
                          + NSStringFromClass(callQueue[callCursor])
                          + " rss=" + String(rss) + "mb")
            }
            // Each method name costs a bridged string and the pool returns
            // them, but a jetsam kill looks exactly like a bad class in the
            // log, so a runaway is checked for rather than trusted.
            if rss - baseMB > 200 {
                reason = " stopped at the memory ceiling"
                break
            }
        }
        emitCallTable(reason: reason)
        if callStateFD >= 0 {
            _ = close(callStateFD)
            callStateFD = -1
        }
        // Only a run that reached the end may erase the witness. A stopped run
        // keeps it, so the next boot can name the class instead of guessing.
        if reason.isEmpty {
            try? FileManager.default.removeItem(atPath: Aevon.callStatePath)
        }
        // Same thread, same pool discipline: the tail pass asks a few hundred
        // named classes nine questions, and it is the only part of this file
        // that realizes a class it did not walk.
        runTail()
    }

    /// Everything the first half found, printed the moment the boundary is
    /// crossed. The final table repeats it — this block exists so that a death
    /// in the second half costs the tail of the process, not the whole answer.
    private static func emitPhase1() {
        var found = 0
        for selector in callTargets.sorted() {
            guard let hit = callHits[selector] else { continue }
            found += 1
            var line = "calls: phase1 by " + selector + " n=" + String(hit.count)
            for owner in hit.owners {
                line += " " + owner.name + "|" + owner.encoding
            }
            Log.write(line)
        }
        Log.write("calls: phase1 done hits=" + String(found) + " of " + String(callTargets.count)
                  + " scanned=" + String(callCursor)
                  + " secs=" + String(Int(Date().timeIntervalSince(callStart))))
    }

    /// Own methods only, instance and class side separately. Inherited hits are
    /// deliberately not counted: on a previous run 3197 of 3198 classes
    /// "answered" `responds(to:)` for a selector only one class defined, which
    /// is exactly the kind of evidence that reads as success and means nothing.
    ///
    /// The name comes through `NSStringFromSelector`, the same call the second
    /// dump already compiles, rather than through `sel_getName` + `String(cString:)`.
    /// One extra bridge per method, but this file cannot be compiled here and a
    /// known-good spelling is worth more than a known-marginal saving.
    private static func collectMethods(of cls: AnyClass, meta: Bool) {
        // Two statements rather than one ternary: a ternary mixing AnyClass and
        // AnyClass? is legal but reads as a coin flip when nobody can compile
        // this locally.
        let holder: AnyClass? = meta ? object_getClass(cls) : cls
        guard let holder = holder else { return }
        var count: UInt32 = 0
        guard let list = class_copyMethodList(holder, &count) else { return }
        defer { free(list) }
        let side = meta ? "+" : "-"
        let ownerName = NSStringFromClass(cls) + side
        for index in 0..<Int(count) {
            let name = NSStringFromSelector(method_getName(list[index]))
            guard callTargets.contains(name) else { continue }
            let encoding = method_getTypeEncoding(list[index]).map { String(cString: $0) } ?? "?"
            var hit = callHits[name] ?? CallHit(count: 0, owners: [])
            hit.count += 1
            if hit.owners.count < 10 {
                if !hit.owners.contains(where: { $0.name == ownerName }) {
                    hit.owners.append(CallOwner(name: ownerName, encoding: encoding))
                }
            }
            callHits[name] = hit
        }
    }

    /// Resident size, so the next log can tell a memory kill from a bad class:
    /// a number that climbs steadily means the walk itself is the problem, a
    /// flat number means it died on one particular class.
    private static func residentMegabytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int(usage.ru_maxrss) / (1024 * 1024)
    }

    /// The rows, and only the rows. Checkpoints call this without the end line
    /// on purpose: the end line is what tells the reader the dump is complete,
    /// and a checkpoint is by definition not complete. tools/compare-calls.py
    /// collects rows until it sees the end line, so the last end line wins and
    /// the checkpoints simply look like a table that grew.
    private static func emitRows() -> (Int, Int) {
        var missing = 0
        var multi = 0
        for selector in callTargets.sorted() {
            guard let hit = callHits[selector] else {
                missing += 1
                Log.write("calls: defined by " + selector + " n=0")
                continue
            }
            if hit.count > hit.owners.count { multi += 1 }
            var line = "calls: defined by " + selector + " n=" + String(hit.count)
            for owner in hit.owners {
                line += " " + owner.name + "|" + owner.encoding
            }
            Log.write(line)
        }
        return (missing, multi)
    }

    private static func emitCallTable(reason: String) {
        let (missing, multi) = emitRows()
        // `upto` is not decoration: a scan that stopped early makes every
        // `n=0` above it a lie, and tools/compare-calls.py refuses to read a
        // partial dump as a verdict for exactly that reason. `skip` is the same
        // warning from the other side — classes dropped on purpose cannot be
        // the owner of anything either. `scope=phase1` says the stop was chosen,
        // not suffered: `upto` below `of` by design, and `n=0` here means "not
        // one of the families", which the tool reads as out of scope rather
        // than absent. runTail() below is what closes those last few.
        Log.write("calls: definition end v2 missing=" + String(missing)
                  + " capped=" + String(multi)
                  + " upto=" + String(callCursor) + " of " + String(callCeiling)
                  + " scope=phase1"
                  + " skip=" + String(callSkipped)
                  + " secs=" + String(Int(Date().timeIntervalSince(callStart)))
                  + reason)
    }

    /// The selectors the family walk could not answer, asked of the classes it
    /// died reaching — without walking them.
    ///
    /// Three runs died one or two classes into the non-family tail, a different
    /// class each time, so skipping the poisonous name was never going to work:
    /// ninety thousand classes at one respring per name. What those names have
    /// in common is not poison, it is that the runtime builds them — bridged,
    /// minted, or not finished. `class_getName` reads ro data and realizes
    /// nothing, so reading all ninety thousand names is safe; the danger is only
    /// in asking for a method table. So: read every name, keep the ones whose
    /// name says something about the selectors still missing, and ask only
    /// those. A few hundred classes instead of ninety thousand, and a name that
    /// does not match is a name this pass cannot speak for.
    private static let tailKeywords = ["presentable", "material", "handle", "tap",
                                       "icon", "foreground", "duration", "press",
                                       "setting"]

    private static func runTail() {
        var missing: [String] = []
        for selector in callTargets.sorted() where callHits[selector] == nil {
            missing.append(selector)
        }
        guard !missing.isEmpty else {
            callBusy = false
            Log.write("calls: tail not needed, every selector has an owner")
            return
        }
        let poison = loadSkipList()
        let started = Date()
        var candidates = 0
        var owned = 0
        callStateFD = open(Aevon.callStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        for cls in allClasses() {
            let text = String(cString: class_getName(cls))
            // Family classes answered nothing with their method tables already
            // read, `__`-minted ones are the classes that die, and a class that
            // already killed a run stays killed. None of them is a candidate.
            if priorityRank(of: text) < callPriorityPrefixes.count { continue }
            if text.hasPrefix("__") || text.hasPrefix("_NSZombie_") { continue }
            if poison.contains(text) { continue }
            let lower = text.lowercased()
            var wanted = false
            for keyword in tailKeywords where lower.contains(keyword) {
                wanted = true
                break
            }
            guard wanted else { continue }
            candidates += 1
            // The same marker the walk uses: if this class is the one that
            // faults, the next boot names it, the skip list steps over it, and
            // every line printed before it is already on disk.
            mark(cls, index: candidates)
            Log.write("calls: tail cand " + text)
            for selector in missing {
                let sel = NSSelectorFromString(selector)
                var side = "-"
                var method = class_getInstanceMethod(cls, sel)
                if method == nil {
                    method = class_getClassMethod(cls, sel)
                    side = "+"
                }
                guard let method = method else { continue }
                let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
                owned += 1
                Log.write("calls: tail owns " + text + side + " " + selector + " " + encoding)
            }
        }
        if callStateFD >= 0 {
            _ = close(callStateFD)
            callStateFD = -1
        }
        // This pass either finished or did not exist; there is no half state
        // worth keeping, and a leftover marker reads as a death next boot.
        try? FileManager.default.removeItem(atPath: Aevon.callStatePath)
        callBusy = false
        Log.write("calls: tail done names=" + String(candidates) + " owned=" + String(owned)
                  + " missing=" + String(missing.count)
                  + " secs=" + String(Int(Date().timeIntervalSince(started))))
    }

    private static func loadSkipList() -> Set<String> {
        guard let text = try? String(contentsOfFile: Aevon.callSkipPath, encoding: .utf8) else {
            return []
        }
        // The list belongs to the build that learned it. 0.0.9 stopped cleanly
        // at class 250 but kept its marker, so 0.0.10 booted, called that a
        // death, and learned a class that never killed anything — a bogus skip
        // is a silent false negative in the table below. A version stamp makes
        // the list expire by itself instead of being trusted forever.
        var lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard lines.first == "!" + Aevon.version else { return [] }
        lines.removeFirst()
        return Set(lines)
    }

    // MARK: - Floating window (0.0.22): the mother ship's chain, end to end

    /// Stheno's own scene vocabulary, counted in her binary rather than borrowed
    /// from somebody else's project: `createPresenterWithIdentifier:priority:`,
    /// `presentationView`, `initWithSceneLayer:` and `_UIContextLayerHostView`
    /// are the scene symbols she carries, while `layerManager`, `layers` and
    /// `hostManager` appear exactly zero times in both the const and the
    /// cstring section. Her route is one presenter plus one window — never a
    /// layer walk.
    ///
    /// 0.0.20 walked that chain and stopped one step short. It activated the
    /// presenter and never put the view into a window: `hosting=yes active=yes`
    /// with `superview=nil`, the scene's layers hosted by nothing that draws,
    /// and the phone black until it was restarted.
    ///
    /// This version takes the missing step, in the only order that cannot
    /// repeat it:
    ///   presenter -> presentationView -> window -> activate
    /// The window is on screen and already holds the view before a single layer
    /// is claimed, so there is never a moment where the scene is hosted by
    /// nobody. SpringBoard's own scene and the keyboard's are not touched:
    /// taking the desktop's presentation is what blacked the screen.
    static func runWindow() {
        reportLastStep()

        // 0.0.27 puts the mother ship's mechanism in place before anything else
        // happens, because the last three versions were solving a problem she
        // does not have. Her route is in the reverse notes, with the encodings
        // read off this phone: a `UIApplicationSceneDeactivationManager` whose
        // `_setDeactivationReasons:onScene:withSettings:reason:` is how the
        // system decides whether a scene may go to sleep, and a scene that is
        // allowed to stay awake keeps drawing after the app has left the screen.
        // Hiding SpringBoard's views was never needed; the desktop is already
        // underneath, it was only covered by a full-screen app that is now gone.
        mark("hook-install")
        emitNotes(AevonHookInstall())
        unmark()
        Log.write("win: armed, building in 6s (switch to the target app now)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            // Asked again on purpose: a manager captured six seconds ago is a
            // stale reference to something the system may have rebuilt.
            guard let manager = AevonSceneManager() as? NSObject else {
                Log.write("win: no manager")
                return
            }
            guard let scene = target(manager) else {
                Log.write("win: no app scene in the list this run")
                return
            }
            watch(scene)
        }
    }

    /// The three classes the next decision is chosen from, named by the runtime
    /// rather than by this file. 0.0.27 looked for
    /// `_scene:interceptUpdateWithNewSettings:` on `FBScene` and found it on
    /// `SBSceneManager` with a different shape, so the hook that the mother ship
    /// keeps a scene awake with went uninstalled by a guess. One line per class
    /// is cheaper than the round it costs to discover the same thing twice.
    private static var censusDone = false
    /// 0.0.33 — whether a card is on screen right now. The hook has to stay
    /// armed for as long as one is: a disarmed hook lets the system put the
    /// scene back to sleep underneath a card that is still showing it, which is
    /// the black card of 0.0.28 arriving by a different road.
    private static var cardUp = false

    /// Holds the scene open and builds the card the moment the operator leaves
    /// it.
    ///
    /// The order matters and it is the reverse of 0.0.22—0.0.26. Those versions
    /// built a card while the app was full screen, which is the one moment a
    /// scene's layers cannot be in two places: the card took them and the screen
    /// went black. Here the app is asked to stay alive *before* it leaves, and
    /// the card is only built once it has, so the layers have exactly one home
    /// and the desktop is what shows around it.
    private static func watch(_ scene: NSObject) {
        let identifier = value(of: scene, "identifier").map { String(describing: $0) } ?? ""
        var bundle = identifier.hasPrefix("sceneID:")
            ? String(identifier.dropFirst(8)) : identifier
        if let dash = bundle.range(of: "-default") {
            bundle = String(bundle[..<dash.lowerBound])
        }
        guard !bundle.isEmpty else {
            Log.write("win: the target scene will not name itself, nothing to hold")
            return
        }
        // The marker is written before the hold and cleared after it, so a
        // process that dies anywhere in between names the step on the next
        // launch instead of leaving the log to be read backwards. It is the one
        // call in this file that changes what SpringBoard does to a scene, and
        // it deserves the witness the hook route never got to use.
        mark("APP-hold")
        AevonHookArm(bundle)
        Log.write("win: holding " + bundle
                  + " reasons=" + reasonsOf(scene)
                  + " layers=" + String(count(of: value(of: scene, "layerManager"), "layers")))
        Log.write("win: now swipe up to the desktop - the card follows")

        // 250 ms is four looks per second: fast enough to catch the moment the
        // app stops being the front scene, slow enough that twenty seconds of
        // waiting costs nothing. Twenty seconds is the ceiling because a run
        // that never gets an answer has to end by itself.
        var poll: (() -> Void)!
        var ticks = 0
        var sawFront = false
        poll = {
            ticks += 1
            let running = AevonBoolOf(scene, "accessibilitySceneIsRunningInForeground")
            let visible = AevonBoolOf(scene, "accessibilitySceneIsForegroundVisible")
            let settings = value(of: scene, "settings")
            let foreground = settings.map { AevonBoolOf($0, "isForeground") } ?? -1
            let front = running == 1 || visible == 1 || foreground == 1
            if front { sawFront = true }
            // The card is built on the way *out* of the app and never before.
            // 0.0.24—0.0.26 built it while the app was still full screen and took
            // the scene's layers away from it, which is the black phone. So a run
            // that never saw this scene in front builds nothing at all: three
            // unreadable answers must not be read as "the operator already left".
            let left = sawFront && !front
            guard left || ticks >= 80 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
                return
            }
            guard left else {
                Log.write("win: never saw it leave the front, nothing built"
                          + " running=" + flag(running)
                          + " visible=" + flag(visible)
                          + " fg=" + flag(foreground))
                AevonHookDisarm(bundle)
                unmark()
                return
            }
            Log.write("win: left the app at " + String(ticks * 250) + "ms"
                      + " running=" + flag(running)
                      + " visible=" + flag(visible)
                      + " fg=" + flag(foreground)
                      + " reasons=" + reasonsOf(scene))
            emitNotes(AevonHookSummary())
            float(scene)
            // 0.0.33 — this used to be the teardown, because the card came down
            // after eight seconds. It is not one any more: the card stays, and a
            // disarmed hook under a live card is the 0.0.28 black screen with a
            // different cause. What is left here is the safety net for a card
            // that never came up at all — with a card on screen, `closeCard` is
            // the only thing that disarms.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if cardUp { return }
                AevonHookDisarm(bundle)
                unmark()
                emitNotes(AevonHookSummary())
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
    }

    // MARK: - 0.0.38 图标 → 悬浮窗

    /// Where the ring's icon ends up. One tap, no Settings, no six second wait,
    /// and no swipe to the desktop.
    ///
    /// The manual flow is slow for a reason that is not a bug: the card is only
    /// built once the app has *left* the screen, because a scene's layers can
    /// only be hosted by one container at a time (0.0.24—0.0.26 took them while
    /// the app was full screen and the phone went black). Her route removes the
    /// departure entirely — `launchApplicationWithIdentifier:suspended:` starts
    /// the app without giving it the screen, so the scene exists, the desktop is
    /// still the backdrop, and the card is the only thing that ever hosts the
    /// layers.
    ///
    /// Everything after the launch is the chain that already works: arm the hold,
    /// wait for the scene to exist, then `float`. `float` pushes the scene to
    /// "in front" on its first beat, which is the same door 0.0.32 proved on a
    /// scene that had genuinely gone to the background.
    ///
    /// `fallback` is called when this route cannot even start: a suspended launch
    /// that never produces a scene would otherwise be a tap that does nothing,
    /// and a dead control on the home screen is worse than a full-screen app.
    static func openCard(_ bundleID: String, fallback: @escaping (String) -> Void) {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("placeholder.") else { return }
        // 0.0.98 — 已经有主窗时，先把它降级成停靠小窗，再开新的。
        //
        // 0.0.97 及以前这里是 `guard !cardUp else { log("ignored, a card is already
        // up"); return }` —— 用户说的「主悬浮窗打开时，再次通过圆盘选中图标后没有
        // 任何反应」就是这一行。它甚至在日志里承认了自己是故意的，所以四份日志里
        // 这件事长得像「圆盘坏了」。
        //
        // 降级只改几何（缩到边缘），不换宿主、不拆 scene：旧窗的对象还留在它自己
        // 那份 `FloatHost` 上，新的主窗拿到的是另一个空槽。见 `FloatHost.takeMainSlot`。
        if cardUp {
            // 同一个 App 再选一次：不降级也不重开。否则点两下就把它自己挤成小窗。
            if hostedBundle == bundleID || FloatHost.mainBundle == bundleID {
                Log.write("win: icon " + bundleID + " is already the main card, ignored")
                return
            }
            // 0.0.99 — **先问有没有槽，再决定降不降级**。
            //
            // 0.0.98 的顺序是反的，这是 Aevon(87) 那个「第三个 App → 不显示悬浮窗、
            // 只剩白色光晕」的全部原因：两个槽都在用时，`demoteMain()` 先把主窗缩成
            // 小窗，然后 `FloatHost.show` 才发现没槽，于是新窗开不出来、旧窗已经被
            // 缩小，屏幕上只剩停靠小窗和一圈手势环。槽位现在是 11 个，正常用不到
            // 这条；但拒绝必须发生在动手之前，否则下一次槽满还是同一个画面。
            guard FloatHost.hasFreeSlot() else {
                Log.write(String(format: "win: no free slot, %@ declined before demote", bundleID))
                return
            }
            let side = FloatHost.demoteMain()
            if side == "none" {
                // 主窗的宿主已经不在（恰好刚被关掉）：把标志复位，按「没有卡」继续。
                // 不复位的话下面 `FloatHost.show` 会找不到空槽，这一下就真的没反应了。
                Log.write("win: demote found no card, treating as none")
                cardUp = false
                AevonRingGrip.cardUp = false
            } else {
                // 一整条字面量，不拼：`win: demote ` 只有 12 字节，拼接串会被
                // 编译器编成立即数，二进制里 grep 不到 —— 闸门会拦，也确实拦对了。
                Log.write(String(format: "win: demote old=%@ side=%@ new=%@",
                                 hostedBundle ?? "?", side, bundleID))
            }
        }

        // 0.0.50 — 母本的两招，这一条路上一直只有半招。
        //
        // `AevonHookInstall()` 从 0.0.27 起只在 `runWindow()` 里被调过，而那条
        // 路是「手动装钩子 → 6 秒内切回目标 App」的探针流程；从 0.0.38 起真正
        // 在用的是这条路（圆盘图标 → 挂起启动 → 建卡片）。于是 Aevon(48) 的
        // 每一份日志里都是 `hook: live=0 deact_set=0 stripped=0` ——
        // `_setDeactivationReasons:onScene:withSettings:reason:` 这条母本赖以
        // 让被承载的 scene 不睡下去的钩子，在这条路上**从来没装上过**。
        // 0.0.35 的日志证明它在真机上装得上也拦得住（`live=4 deact_set=119
        // stripped=32`），缺的只是这一行调用。
        //
        // 放在启动之前：钩子必须在 scene 出现之前就位，否则第一轮切换就已经
        // 错过了。装不上也不影响开窗 —— 自证失败时它只会往日志写一行。
        emitNotes(AevonHookInstall())
        // 先认人，再拉应用：钩子里判「是不是我这一场」只看这个 id，而 scene
        // 是启动那一瞬才出现的 —— 先装钩子、先报名字，两边都不会抢在前面。
        // 启动失败就撤回，免得留一个没有浮窗的「保活名单」。
        AevonHookArm(bundleID)

        // 0.0.66 — 「旧进程就先杀掉它」那条路撤了（随 0.0.65 的屏幕补丁一起）。
        // 它要读一张名片文件才知道进程新旧，而名片写不进去时判据永远不成立，
        // 后果是**每次开窗先结束那个 App**。旧进程最大的坏处只是这一版的改动
        // 没生效，那是可以容忍的；把 App 弄成打不开是不可容忍的。

        let door = AevonLaunchSuspended(sharedApplication(), bundleID)
        Log.write("win: icon launch " + bundleID + " suspended door=" + String(door))
        guard door == 1 else {
            AevonHookDisarm(bundleID)
            fallback("suspended door=" + String(door))
            return
        }

        mark("ICON-launch")
        // Armed before the wait, not after it: a scene that appears and is
        // allowed to sleep in the same half second is a scene found already cold.
        // (0.0.50 arms one line earlier, before the launch, for the same reason
        // one step further out.)
        // 0.0.44 — tell the app itself. The card can forward touches all day;
        // an app that believes it is in the background drops them before they
        // reach a window. This is the one signal that does not depend on the
        // scene settings crossing into the app's own copy.
        markHosted(bundleID)
        pollForScene(bundleID, ticks: 0, start: Date(), fallback: fallback)
    }

    // MARK: - 0.0.44 hosted mark

    /// Who the card is showing. `Aevon.hostedPath` is the copy the app reads;
    /// the static is only here so the log can say whose mark was cleared.
    private static var hostedBundle: String?

    private static func markHosted(_ bundleID: String) {
        hostedBundle = bundleID
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "bundle": bundleID,
            // Reference-date seconds: the same clock the app-side reader compares
            // against, so neither side has to know about 1970.
            "ts": Date().timeIntervalSinceReferenceDate,
        ]
        let ok = (payload as NSDictionary).write(toFile: Aevon.hostedPath, atomically: true)
        Log.write("win: hosted mark " + bundleID + (ok ? "" : " (write failed)"))
    }

    /// 0.0.70 — 把卡里那个 App 自己写下的读数取回来，并进主日志。
    ///
    /// 这一步之前不存在，所以抖音的量尺跑了三轮、改了两次都没成：`fopen`
    /// `/var/mobile/Aevon.log` 在沙盒里必然失败，读数被我们自己丢掉了。
    ///
    /// 0.1.2 — 不再只数行数。Aevon(90) 里抖音自己写了 8 条 `app: hang`
    /// （「我的主线程 2 秒没动了」），宿主每 2 秒把它们读走、数了个 `lines=2`、
    /// 然后丢掉 —— 于是卡死在前 85 秒里，我们这边一条证词都没有，最后靠
    /// 「场景死了」才发现。现在这一趟顺带做三件事：
    ///   · 数 hang 行，把第一条转写成一条 `win:` 行（两条时间轴从此能对齐）；
    ///   · 记下最后一条 `alive` 的时刻（主队列还有没有在跑）；
    ///   · 看见 hang 就排 5 次快照（每 2 秒一次），把宿主侧的现场也留一份。
    /// 只记录，不做任何恢复动作 —— 这一版是在查「为什么会卡」。
    private static var hangLines = 0
    private static var lastAliveAt = Date.distantPast
    private static var snapsLeft = 0

    private static func drainAppLog(_ tag: String, quiet: Bool = false) {
        guard let bundle = hostedBundle else { return }
        let text = AevonDrainAppLogText(bundle, 400) ?? ""
        var lines = 0
        var hangs = 0
        var alive = false
        for row in text.split(separator: "\n") {
            lines += 1
            if row.contains("app: hang step=") {
                hangs += 1
                if hangs == 1 {
                    Log.write("win: app hang echo " + String(row.suffix(160)))
                }
            } else if row.contains("app: page alive") {
                alive = true
            } else if row.contains("probe offmain") || row.contains("probe mode") {
                // 开关到底有没有生效，靠这两行；它们每次只变一次，不会刷屏。
                Log.write("win: app " + String(row))
            }
        }
        // 0.0.91 — 每 2 秒那一趟是常态，没有新行就不出声，否则日志会被
        // 一分钟 30 行「lines=0」灌满。
        if quiet && lines <= 0 { return }
        Log.write("win: app log lines=" + String(lines) + " from " + tag
                  + " file=" + (AevonAppLogPathOf(bundle) ?? "none"))
        if alive { lastAliveAt = Date() }
        guard hangs > 0 else { return }
        hangLines += hangs
        Log.write("win: app hung n=" + String(hangs) + " total=" + String(hangLines)
                  + " silent=" + String(Int(Date().timeIntervalSince(lastAliveAt))) + "s")
        if snapsLeft == 0 {
            snapsLeft = 5
            scheduleHungSnaps(bundle, tag)
        }
    }

    /// 卡死期间的宿主侧现场：每 2 秒一条，5 条为止。
    ///
    /// App 那侧只能证明「它的主线程停了」；「我们这边看着是什么样」一条都没有 ——
    /// Aevon(90) 里唯一的证据是 40 拍一次的 `keepalive`，粒度 8 秒，而且它全程
    /// 显示一切正常。这一组把窗口压到 2 秒，并且和 hang 同一时刻开始。
    private static func scheduleHungSnaps(_ bundle: String, _ tag: String) {
        guard snapsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard snapsLeft > 0 else { return }
            snapsLeft -= 1
            hungSnap(tag, bundle)
            if snapsLeft > 0 { scheduleHungSnaps(bundle, tag) }
        }
    }

    private static func hungSnap(_ tag: String, _ bundle: String) {
        let scene = sceneFor(bundle)
        let cs = scene.flatMap { value(of: $0, "contentState") as? NSNumber }?.intValue ?? -1
        let fg = scene.flatMap { value(of: $0, "settings") }
            .map { AevonBoolOf($0, "isForeground") } ?? -1
        Log.write(String(format: "win: hung snap %@ cs=%d fg=%d up=%d",
                         tag, cs, fg, cardUp ? 1 : 0))
    }

    /// 0.0.91 — 被托管的 App 进程死了，卡片只剩外壳（Aevon(80) 与 Aevon(81) 的
    /// 「白色光晕」）。关掉它，0.6 秒后用同一个 bundle 重开一张。
    ///
    /// 120 秒内只允许一次：死因若是内存，重开只会在同一个坑里再死一遍；而
    /// 「每 0.6 秒重开一次」会让整台手机变成幻灯片。宁可让用户手动重开，
    /// 也不能自己变成一个循环。
    private static var lastReviveAt = Date.distantPast

    static func reviveCard(_ bundleID: String) {
        let gap = Date().timeIntervalSince(lastReviveAt)
        guard gap > 120 else {
            Log.write("win: revive suppressed, last one " + String(Int(gap)) + "s ago")
            return
        }
        lastReviveAt = Date()
        Log.write("win: revive bundle=" + bundleID + " after 0.6s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !cardUp else {
                Log.write("win: revive skipped, a card is already up")
                return
            }
            openCard(bundleID) { why in
                Log.write("win: revive gave up " + why)
            }
        }
    }

    private static func clearHosted() {
        guard let bundleID = hostedBundle else { return }
        hostedBundle = nil
        try? FileManager.default.removeItem(atPath: Aevon.hostedPath)
        Log.write("win: hosted mark cleared for " + bundleID)
    }

    /// 0.0.99 — 只清「确实是我这一张」的那份记号。
    ///
    /// `clearHosted()` 是无条件的：多窗之后关掉停靠小窗会顺手抹掉主窗那份
    /// `hosted.plist`，那个 App 下一拍就不认为自己在浮窗里了。
    private static func clearHosted(_ bundleID: String) {
        guard !bundleID.isEmpty else { clearHosted(); return }
        if let current = hostedBundle, current != bundleID {
            Log.write("win: hosted mark kept for " + current + " (closing " + bundleID + ")")
            return
        }
        clearHosted()
    }

    /// 4 秒内找 scene。
    ///
    /// 0.0.58 — 前 30 拍从 250 ms 压到 60 ms。原来那 250 ms 是「一秒看四次」，
    /// 而场景从挂起启动到出现通常只要 120~300 ms —— 也就是**第一次看见它，
    /// 平均已经晚了 125 ms，最坏 250 ms**，这段时间卡片还没建，屏幕上什么都
    /// 没有。挂起启动本身已经把「等 App 进程」这一段省掉了，剩下的这一拍就
    /// 成了整条链上最贵的一段延迟。
    ///
    /// 1.8 秒之后退回 250 ms：那时候还没 scene，就是真没起来，没必要每秒查
    /// 十七次到第四秒。
    private static func pollForScene(_ bundleID: String, ticks: Int, start: Date,
                                     fallback: @escaping (String) -> Void) {
        if let scene = sceneFor(bundleID) {
            unmark()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Log.write("win: icon scene up after " + String(ms) + "ms ticks=" + String(ticks))
            emitNotes(AevonTakeNotes())
            float(scene, bundleID: bundleID)
            // A hold with no card under it is a scene that never sleeps again.
            //
            // 0.0.98 — 判据从「有没有卡」换成「这个 App 是不是当前主窗」。旧主窗
            // 降级之后 `cardUp` 一直是 true，用它判等于不管新卡起没起来都算成功，
            // 那样一条失败会被记成一次成功，下次再去查就是「日志里没有异常」。
            guard FloatHost.mainBundle == bundleID else {
                AevonHookDisarm(bundleID)
                Log.write("win: icon card did not come up, hold released")
                fallback("card did not come up")
                return
            }
            return
        }
        guard Date().timeIntervalSince(start) < 4.0 else {
            unmark()
            AevonHookDisarm(bundleID)
            Log.write("win: icon " + bundleID + " produced no scene")
            fallback("no scene in 4s")
            return
        }
        // 0.0.59 — 60 → 40 ms。枚举一次 scene manager 只有几个对象，成本远小于
        // 这一拍白等的时间；前 30 拍（1.2 s）覆盖了「scene 该出现」的全部窗口。
        let gap: Double = ticks < 30 ? 0.04 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            pollForScene(bundleID, ticks: ticks + 1, start: start, fallback: fallback)
        }
    }

    /// The scene that answers to this bundle id. Matched on the identifier
    /// rather than on the app object: `sceneID:com.x.y-default` is the one
    /// spelling every release has used, and the scene manager is the only door
    /// that lists scenes across processes.
    private static func sceneFor(_ bundleID: String) -> NSObject? {
        guard let manager = AevonSceneManager() as? NSObject else { return nil }
        var found: NSObject?
        AevonEnumerateScenes(manager) { scene in
            guard found == nil, let scene = scene as? NSObject else { return }
            let identifier = value(of: scene, "identifier").map { String(describing: $0) } ?? ""
            if identifier.contains(bundleID) { found = scene }
        }
        return found
    }

    /// The system's own answer to "may this scene go to sleep", as a number.

    /// `absent` means the method is not there, which is not the same as 0.
    private static func reasonsOf(_ scene: NSObject) -> String {
        let value = AevonReasonsOf(scene)
        return value == UInt64.max ? "absent" : String(value)
    }

    /// The scene a floating window would host.
    ///
    /// 0.0.21 picked 抖音 while Settings was in front, simply because it was the
    /// first scene that was neither SpringBoard nor Settings. A background scene
    /// is exactly the case where a presenter has nothing to show, so the choice
    /// is made by the scene's own settings now, and the fallback says in the log
    /// that it fell back.
    private static func target(_ manager: NSObject) -> NSObject? {
        var front: NSObject?
        var frontName = "?"
        var spare: NSObject?
        var spareName = "?"
        var seen = 0
        var listed = 0
        let visit: (Any?) -> Void = { scene in
            guard let scene = scene as? NSObject else { return }
            seen += 1
            let ident = value(of: scene, "identifier").map { String(describing: $0) } ?? "?"
            guard ident.hasPrefix("sceneID:"),
                  !ident.contains("com.apple.springboard"),
                  !ident.contains("com.apple.Preferences") else { return }
            listed += 1
            if spare == nil { spare = scene; spareName = ident }

            // Four independent answers to "is this scene in front". 0.0.22
            // asked `settings` alone and got -1 back from both spellings —
            // which is how a background scene came to be hosted: the question
            // failed, not the scene. The accessibility pair is what FBScene
            // declares for exactly this question, so it is read first; the
            // settings readings are kept because a disagreement between the
            // four is worth seeing in the log rather than averaging away.
            let running = AevonBoolOf(scene, "accessibilitySceneIsRunningInForeground")
            let visible = AevonBoolOf(scene, "accessibilitySceneIsForegroundVisible")
            let settings = value(of: scene, "settings")
            let foreground = settings.map { AevonBoolOf($0, "isForeground") } ?? -1
            let plain = settings.map { AevonBoolOf($0, "foreground") } ?? -1
            if listed <= 6 {
                Log.write("win: scene candidate " + ident
                          + " running=" + flag(running)
                          + " visible=" + flag(visible)
                          + " fg=" + flag(foreground) + "/" + flag(plain)
                          + " settings=" + (settings.map { NSStringFromClass(type(of: $0)) } ?? "nil"))
            }
            guard front == nil else { return }
            if running == 1 || visible == 1 || foreground == 1 || plain == 1 {
                front = scene
                frontName = ident
            }
        }
        AevonEnumerateScenes(manager, visit)
        Log.write("win: enumerating scenes " + String(seen) + " apps=" + String(listed))
        if let scene = front {
            Log.write("win: target " + frontName + " foreground=yes")
            return scene
        }
        // Aevon(24) made the shape of this case unmistakable: the operator stayed
        // in Settings, and 6 seconds later Settings was full screen while the
        // card sat black. A background scene pushes no layers to anybody, so the
        // card cannot hold a picture no matter what is activated. Falling back to
        // "the best available scene" only ever produced that black card, so the
        // run now says so and builds nothing.
        if spare != nil {
            Log.write("win: target " + spareName + " is in the background, nothing to float")
        } else {
            Log.write("win: no app scene at all this run")
        }
        return nil
    }

    /// The chain, in the mother ship's order, with the one step she never has to
    /// take because the system takes it for her.
    private static func float(_ scene: NSObject, bundleID: String? = nil) {
        guard let manager = value(of: scene, "uiPresentationManager") else {
            Log.write("win: no uiPresentationManager")
            return
        }

        // How many layers the scene is offering at all: a suspended background
        // scene offers none, a foreground one at least its display layer. One
        // number, read before anything is built, so it describes the scene and
        // not our own work on it. 0.0.27-0.0.29 needed five method-table dumps
        // around this line to learn the getter names; the names are known now,
        // and `hosted=2` at the container is the reading that decides anything.
        let layerManager = value(of: scene, "layerManager")
        Log.write("win: scene layerManager layers="
                  + String(count(of: layerManager, "layers")))

        guard let made = AevonCreatePresenter(manager, "com.aevon.float", 0),
              let presenter = made as? NSObject else {
            Log.write("win: no presenter")
            emitNotes(AevonTakeNotes())
            return
        }
        Log.write("win: presenter cls=" + NSStringFromClass(type(of: presenter)))

        // The one call both reference implementations make and this tweak never
        // did. `setResizesHostedContext:` (blueprint 2.1, marked there as the
        // ★★★ of the chain) tells the presenter to resize the scene's hosted
        // context to the presenter instead of expecting the presenter to be the
        // scene's own size. Without it a card that is a fifth of the screen is
        // asking a full-screen surface to shrink itself, and an unshrunk surface
        // in a cropped view is not necessarily a picture.
        _ = AevonCallSetBool(presenter, "setResizesHostedContext:", true)

        guard let raw = value(of: presenter, "presentationView"),
              let view = raw as? UIView else {
            Log.write("win: no presentationView")
            emitNotes(AevonTakeNotes())
            return
        }
        Log.write("win: view cls=" + NSStringFromClass(type(of: view))
                  + " attached=" + (view.superview == nil ? "no" : "yes")
                  + " natural=" + String(format: "%.0fx%.0f",
                                         view.bounds.width, view.bounds.height))

        // 0.0.33 — the card stops being a probe and becomes furniture, so the
        // teardown is no longer "the thing that happens after eight seconds": it
        // is a function with three callers (the close button, the ten minute cap,
        // and anything added later). Growing it in place was how 0.0.30 ended up
        // with a push nobody could move.
        //
        // The order is the 0.0.32 fix and stays untouched —
        //   stop the clock   (so nothing pushes forward after the hand-back)
        //   write the scene back to the background
        //   dismantle the presenter
        //   hide the window, disarm, and read the settings back
        // — with `closed` as the re-entry gate: the button and the cap can fire
        // within a frame of each other, and a second hand-back on a presenter
        // that is already invalid is exactly the kind of call that costs a phone.
        var stopped = false
        var closed = false
        func closeCard(_ reason: String) {
            if closed { return }
            closed = true
            stopped = true
            // 0.0.55 — 先把空闲熄屏还原，再做别的。反过来的话，中间任何一次
            // 提前 return（deactivate 抛异常、presenter 已失效）都会让断言留在
            // 系统里 —— 浮窗关掉之后手机不再自动锁屏，比不修更糟。
            let idleRelease = AevonIdleTimerEnd()
            Log.write("win: idle timer released mask=" + String(idleRelease)
                      + " kicks=" + String(AevonIdleTimerCount()))
            // 0.0.61 — 逻辑尺寸要还回去。我们写过的东西不会随卡片消失而失效
            // （和 0.0.32 的 foreground 是同一条教训）：不还，那个 App 从此是
            // 377 pt 宽的排版，回到桌面自己打开也是，直到它自己被系统重开。
            // 0.0.98 — 只还自己那一格。
            //
            // 0.0.97 及以前这里写的是「设一个整屏目标 → 推一次 → 全部清掉」，
            // 因为当时只有一块画布。多窗之后那样做会把**另一个窗**的画布目标
            // 一起抹掉：关掉主窗，停靠的那个窗就再也不会被写回它自己的尺寸，
            // 表现是「关一个窗，另一个窗的画面忽然按整屏重排」。
            // 0.0.99 — 还的是**这张卡自己的**那一格，不是 `hostedBundle`。
            //
            // `hostedBundle` 是单值：多窗之后它记的是「最后被登记的那个 App」，
            // 于是关掉停靠小窗时会把主窗的 bundle 当成自己的（Aevon(87) 里
            // `hosted mark cleared for com.apple.DocumentsApp` 出现在关别的窗那一拍）。
            // `bundleID` 是这个 scene 自己的，唯一正确。
            let closingBundle = bundleID ?? hostedBundle ?? ""
            let screenSize = UIScreen.main.bounds.size
            if !closingBundle.isEmpty {
                AevonSceneFrameSet(closingBundle, 0, 0,
                                   Double(screenSize.width), Double(screenSize.height))
            }
            let restoreDoor = AevonPushSceneFrame(scene)
            if closingBundle.isEmpty {
                AevonSceneFrameClear()
            } else {
                AevonSceneFrameClearBundle(closingBundle)
            }
            Log.write("win: scene frame restored door=" + String(restoreDoor)
                      + " wrote=" + String(AevonFrameWriteCount()))
            _ = AevonCallVoid(presenter, "deactivate")
            _ = AevonCallVoid(presenter, "invalidate")
            // 0.0.68 — 顺序回到「先拆 presenter，再摘卡片」。0.0.67 把它提到
            // `deactivate` 之前，理由是 `FloatHost.hide()` 要复位承载视图；那个
            // 复位已经删了（见 `FloatHost.teardown`），提前的唯一理由也就不在了，
            // 而「在系统对象还活着的时候动那棵树」正是这一版要撤的东西。
            // 0.0.98 — 按名字拆自己那一块。多窗之后「拆唯一那个宿主」会让关掉
            // 主窗时连带干掉停靠小窗。
            FloatHost.hide(bundle: closingBundle)
            // 0.0.82 — 交还后台这一拍搬到拆完 presenter 之后。
            //
            // Aevon(73) 里每一张卡关掉都是同一个形状：`background door=1 fg=yes`
            // （写了、没落地），0.6 s 后 `background retry door=1 fg=no`（这次落地
            // 了）。两次之间那 0.6 s 就是「关掉浮窗后不能立刻打开全屏抖音」的全部
            // 原因：用户在那一秒里点图标，系统刚把 App 拉起来，我们那一次补写又
            // 把它按回后台 —— 看着就是「点了没反应」。
            //
            // 第一次写不进去，是因为写的时候 presenter 还活着（`deactivate` 还没
            // 调），场景的归属权还在我们手里。拆完 presenter 再写，一次就够；
            // 下面那条 0.35 s 的补写留着，万一这一次也没落地。
            let door = AevonPushBackground(scene)
            Log.write("win: background after teardown door=" + String(door))
            // 0.0.70 — 关卡这一拍把 App 写的读数取回来。必须在 `clearHosted()`
            // 之前：那个函数会把 `hostedBundle` 清空，之后就不知道去哪个容器里取了。
            drainAppLog("on close")
            // 0.0.75 — 关卡之后**再来一次**，4 秒后。
            //
            // Aevon(65) 里最要命的那一段没有任何读数：App 在关卡后 3 拍
            // （0.4 / 1.5 / 2.6 s）写下的 `state` 全是旧几何，而它真正按 932
            // 重排是在用户回到全屏那一刻 —— 之后一条记录都没有，所以「断层」
            // 只能靠录屏猜。这一次的 `snap clean` / `state` 会落在这 4 秒里。
            //
            // 用局部变量记住 bundle：`clearHosted()` 下面就把静态的那一份清了。
            // 如果这 4 秒内又开了一张同一个 App 的卡，这一份读数属于新的一次，
            // 让给新卡（`hostedBundle == b` 就跳过）。
            // 0.0.99 — 名字取自这张卡自己（见上面 `closingBundle` 那段）。
            // 0.0.69 — presenter 拆掉之后再交一次整屏尺寸。
            //
            // 上面那次 `AevonPushSceneFrame` 发生在承载面还在的时候，那时 App 的
            // 窗口还是 717 —— 它可能把这次 settings 变化当成「卡片里的重排」而
            // 不是「回到整屏」。Aevon(58) 的「关窗后全屏打开抖音整体偏下、顶上
            // 露出上一页的底」就是 App 带着 717 的排版回到桌面的样子。
            //
            // 这一次只写 scene 的 frame（我们本来就拥有这个量），不碰任何视图，
            // 0.30 s 后执行，此时 presenter 已经 invalidate。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak scene] in
                // 0.0.98 — 判据从「有没有卡」换成「这一个 App 有没有被重新登记」。
                //
                // 0.0.75 起这里写的是 `!cardUp`，当时「有卡」就等于「那个 App 又被
                // 打开了」。多窗之后 `cardUp` 变成「至少还有一个窗」，关掉主窗而
                // 留着一个停靠小窗时，这条保留的整屏恢复会被无谓地跳过；反过来
                // 真正要防的「0.3 s 内重开同一个 App」也必须按名字判，不能按数量判。
                guard let scene = scene else { return }
                let armed = AevonHookArmedList()
                if !closingBundle.isEmpty, armed != "no", armed.contains(closingBundle) {
                    Log.write("win: frame restore skipped, " + closingBundle + " reopened")
                    return
                }
                let full = UIScreen.main.bounds.size
                if !closingBundle.isEmpty {
                    AevonSceneFrameSet(closingBundle, 0, 0,
                                       Double(full.width), Double(full.height))
                }
                let door = AevonPushSceneFrame(scene)
                if closingBundle.isEmpty {
                    AevonSceneFrameClear()
                } else {
                    AevonSceneFrameClearBundle(closingBundle)
                }
                Log.write("win: frame restore again door=" + String(door))
            }
            // 0.0.55 — 卡片没了，右缘带重新接触摸。
            AevonRingGrip.cardUp = false
            RingHost.shared.setEdgeActive(true)
            // 0.0.98 — 只把自己从名单里摘掉。多窗时全部清空会把停靠小窗的保活
            // 一起撤掉，那个窗下一拍就会被系统收走。
            AevonHookDisarm(closingBundle.isEmpty ? nil : closingBundle)
            clearHosted(closingBundle)
            let closedBundle = closingBundle.isEmpty ? nil : closingBundle
            if let b = closedBundle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    if hostedBundle == b { return }
                    let lines = AevonDrainAppLog(b, 400)
                    Log.write("win: app log lines=" + String(lines) + " from after card closed"
                              + " file=" + (AevonAppLogPathOf(b) ?? "none"))
                }
            }

            // 0.0.98 — 关掉一块之后，屏幕上可能还留着停靠小窗。`cardUp` 的语义
            // 是「还有没有至少一块卡」，所以问宿主，不无条件写 false。写 false 的
            // 后果是下一个 `openCard` 认为没有主窗可降级，直接去抢空槽。
            let stillUp = !FloatHost.mainBundle.isEmpty
            cardUp = stillUp
            emitNotes(AevonHookSummary())
            let back = value(of: scene, "settings").map { AevonBoolOf($0, "isForeground") } ?? -1
            Log.write("win: card closed by " + reason + ", background door=" + String(door)
                      + " fg=" + flag(back) + " live=" + (stillUp ? "yes" : "no"))
            // A hand-back that did not land is the same defect one layer down:
            // the app would spend the rest of the session believing it is in
            // front. One retry, a third of a second later, and then the log says so.
            //
            // 0.0.82 — 0.6 s 改成 0.35 s，并且加了 `!cardUp`：Aevon(73) 里那 0.6 s
            // 与「用户关掉卡片立刻点图标」撞在一起，补写把刚被系统拉起来的 App
            // 又按回后台。窗口越短越不会撞上；真撞上（新卡已经开出来）就不补了
            // —— 那时 scene 属于新的一张卡，再写后台就是错的。
            if back != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    // 0.0.98 — 判据按名字，不按「有没有卡」。多窗时 `cardUp` 大概
                    // 率还是 true（停靠小窗还在），用它判等于这条补写永远不执行；
                    // 要防的仍然是「0.35 s 内又开了同一个 App」，那只能按 bundle 判。
                    let armed = AevonHookArmedList()
                    if !closingBundle.isEmpty, armed != "no", armed.contains(closingBundle) {
                        return
                    }
                    let again = AevonPushBackground(scene)
                    let now = value(of: scene, "settings").map {
                        AevonBoolOf($0, "isForeground")
                    } ?? -1
                    Log.write("win: background retry door=" + String(again)
                              + " fg=" + flag(now))
                }
            }
        }

        // 0.0.59 — 「要不要等第一帧」改成两条判据，不再只看 contentState。
        //
        // `contentState` 是 scene 对「我有内容」的自答，它比「这一帧到了屏幕上」
        // 早：Aevon(58) 的那一闪，就是卡片照着它露出来、画面却还在路上。
        //
        //   ① contentState == 2 —— 必要，不充分；
        //   ② scene.layerManager.layers —— 这个 scene 递交了几个层。挂起启动的
        //      冷 scene 是 0，此时 contentState 说什么都不算数。-1 是探针读不到，
        //      不能当成「没有层」，否则卡片永远不出来。
        //
        // `seen` 只是读数，不参与判断：热启动回来的 App 同样 seen=0（它在后台），
        // 若拿它当条件，快速通道永远不会被走到，热启动也要白等 100 ms。
        var awaiting = false
        if bundleID != nil {
            let state = AevonContentStateOf(scene)
            let layers = count(of: value(of: scene, "layerManager"), "layers")
            let seen = AevonBoolOf(scene, "accessibilitySceneIsForegroundVisible")
            awaiting = (state != 2) || (layers == 0)
            Log.write(String(format: "win: launch state cs=%ld layers=%ld seen=%ld held=%ld",
                             state, layers, seen, awaiting ? 1 : 0))
        }

        // Window first, activate second. This is the whole difference from
        // 0.0.20, and the difference between a picture and a black phone.
        // 0.0.65 — 没有 `onReshape` 了：画布在开窗那一刻定死（屏宽 × 5:3），
        // 之后角拖动只做等比例缩放，没有任何路径会再改 scene 的 frame。
        guard let host = FloatHost.show(view, bundle: bundleID ?? hostedBundle ?? "",
                                        awaitingFrame: awaiting,
                                        onClose: { reason in closeCard(reason) }) else {
            // 0.0.99 — 失败必须**拆掉刚建的这个 presenter**。
            //
            // 这是 Aevon(87) 那个「卡屏 + 只剩白色光晕」的第二层原因，也是更深
            // 的那一层：`AevonCreatePresenter(manager, "com.aevon.float", 0)` 已经
            // 在这个 scene 上建好了一个 presenter，`FloatHost.show` 却在之后才
            // 因为没槽返回 nil。那个 presenter 于是**留在了 scene 上**，既没有
            // `deactivate` 也没有 `invalidate`。
            //
            // 日志把后果记得很清楚：22:26:35 第一次建好 presenter 后被拒；22:27:19
            // 用户再选同一个 App，日志停在 `scene layerManager layers=-1` 之后再
            // 也没有下一行 —— 同一个 scene 上第二次创建同标识的 presenter，主线程
            // 就卡在那儿。用户看到的就是「卡屏」，之后屏幕上只剩一圈手势环。
            //
            // 顺序与 `closeCard` 一致：先停手再交还，最后才拆。反过来的话，
            // 被 invalidate 的 presenter 还挂着一个「我还在承载」的断言。
            _ = AevonCallVoid(presenter, "deactivate")
            _ = AevonCallVoid(presenter, "invalidate")
            if let b = bundleID {
                AevonHookDisarm(b)
                clearHosted(b)
            }
            Log.write("win: no window - presenter released")
            return
        }
        cardUp = true
        // 0.0.55 — 卡片在屏时右缘带闭嘴（与浮窗外侧手势环在右下角重叠）。
        AevonRingGrip.cardUp = true
        RingHost.shared.setEdgeActive(false)
        Log.write("win: window up level=" + String(format: "%.0f", host.level))

        // 0.0.61 — 把 scene 的逻辑尺寸主动推一次。intercept 钩子只在系统更新
        // settings 时给机会，建卡这一拍它未必正好在更新，所以两条路都走。
        //
        // 这一步是「小胖屏」和「整屏缩小」的分界：只改承载视图的 bounds 时，
        // App 仍然按 430 pt 排版，377 的框只是把它裁了一截（Aevon(52) 的现场：
        // 字大、顶栏偏右、底栏与抖音右侧那一列全在框外）。
        let frameDoor = AevonPushSceneFrame(scene)
        Log.write("win: scene frame push door=" + String(frameDoor)
                  + " wrote=" + String(AevonFrameWriteCount()))
        // 两次回读。0.25 s 那次回答「系统收下了没有」，1.2 s 那次回答「它有没有
        // 被系统改回去」—— scene 重排比视图慢，两个时刻读数不同时，先后就是方向。
        for delay in [0.25, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let got = AevonSceneFrameOf(scene)
                Log.write(String(format: "win: scene frame after=%.0fx%.0f wrote=%ld",
                                 got.width, got.height, AevonFrameWriteCount()))
            }
        }

        // 0.0.55 — 浮窗期间禁止空闲熄屏。卡片真的起来了才 hold：`show` 失败
        // 的时候这张卡没有任何东西在播，压住锁屏只是替用户关掉了省电。
        let idleMask = AevonIdleTimerBegin()
        Log.write("win: idle timer held mask=" + String(idleMask)
                  + " saved=" + (idleMask & 4 != 0 ? "app" : "none"))

        mark("APP-activate")
        let ran = AevonCallVoid(presenter, "activate")
        unmark()
        Log.write("win: activate ran=" + (ran == 1 ? "yes" : "no such method"))
        Log.write("win: state hosting=" + flag(AevonBoolOf(presenter, "isHosting"))
                  + " active=" + flag(AevonBoolOf(presenter, "isActive")))
        Log.write("win: view sublayers=" + String(view.layer.sublayers?.count ?? 0))
        // 0.0.69 — 尺寸要在 presenter 接管之后再交一次，见 `reassertCanvas`
        // 上面那段：写在 `activate` 之前的那一次不算「App 的窗口变了」。
        host.reassertCanvas()

        // 0.0.59 — 首帧交给自己的观察器，不再等保活时钟。
        //
        // 保活时钟稳态 200 ms 一拍（掉画才收紧到 60 ms），而冷启动时 fg 是我们
        // 自己写的 1、content 又是 2，`calm` 成立 —— 于是首帧判定平均晚 100 ms、
        // 最坏 200 ms。这段时间卡片是透明的，操作者看到的就是「点了没反应，然后
        // 突然闪一下」。
        if awaiting { watchFirstFrame(host, scene: scene) }

        // 0.0.31 — the push moves off the hook and onto a clock.
        //
        // 0.0.30 wrote the settings from inside `_setDeactivationReasons:`,
        // which is FrontBoard's own scene-update path. Aevon(29) is what that
        // costs: `push path=1 wrote=1 fg=1`, a card with a picture in it, and
        // then not one more line until the watchdog replaced SpringBoard seven
        // seconds later (pid 3271 -> 3305). The same lock, taken twice.
        //
        // The mother ship never writes from a callback. She runs a keepalive
        // clock on the main thread (rounds 12/13), writes only values that
        // differ (round 14), and stops after three failures in a row (round
        // 13) — so that is what this does. One beat per 250 ms for the life of
        // the card, a delta check inside the push, and `WIN-PUSH` on disk only
        // while a beat is in flight so a death inside it is named next launch.
        var keep: (() -> Void)!
        var beat = 0
        var misses = 0
        var wrote = 0
        var marked = false
        // 0.0.50 — 掉画的记账。`dropped` 是画面开始黑的那一拍，0 = 现在有画；
        // `wakes` 是这一轮卡片里唤醒通道真正写出去的次数。
        var dropped = 0
        var droppedAt = Date()
        var wakes = 0
        // 0.0.91 — 「画面掉了、而且再也没回来」连续几拍。两拍就够：一拍可能是
        // 切换的中间态，两拍（稳态 0.2 s 一拍）就是真的没了。
        var deadBeats = 0
        // 0.0.40 — Aevon(38): the picture goes black for a moment whenever the
        // screen changes owner (desktop → app, app → desktop). Two candidates,
        // and they need different fixes: the scene really is being taken away
        // (then the clock is too slow and has to push sooner), or it is not and
        // the gap is in the compositor (then no write will help). This counter is
        // the one thing that tells them apart — it moves only when the system runs
        // its own deactivation path.
        var deact = AevonDeactCount()
        // 0.0.55 — 上次重打空闲计时的时间。20 秒 ≪ 系统最短的「自动锁定 30 秒」，
        // 又不会每秒烧一次私有 API（旧版 V0.2.49 定的频率，原样保留）。
        var idleAt = Date()
        var idleProbe = 0
        // 0.0.63 — 逻辑尺寸的看门狗。0.0.61/0.0.62 只在开窗后 0.25 s / 1.2 s
        // 各回读一次，卡片活着的那几分钟里 scene 有没有被系统改回整屏，日志里
        // 从来没有答案。这里两秒对一次账：对不上就重写一次，前四次各记一行
        // （`win: frame drift now=… want=…`）—— 有这一行，「内容只在刚打开时
        // 是对的」就不再是靠猜的。
        var drifts = 0
        // The clock has to be able to stop from the outside, and 0.0.33 gives it
        // a second reason to: the card no longer disappears on a timer, so the
        // only thing that ends this loop is `closeCard` setting `stopped`.
        keep = {
            if stopped { return }
            beat += 1
            // 0.0.55 — 空闲熄屏的续命拍。放在节拍最前面：这一条与画面、与
            // settings 都没有关系，后面的任何一个 guard 都不该把它挡掉。
            if Date().timeIntervalSince(idleAt) >= 20 {
                idleAt = Date()
                let idleMask = AevonIdleTimerKick()
                if idleProbe < 8 {
                    idleProbe += 1
                    Log.write("win: idle timer kick mask=" + String(idleMask)
                              + " n=" + String(AevonIdleTimerCount()))
                }
            }
            let live = value(of: scene, "settings")
            let fg = live.map { AevonBoolOf($0, "isForeground") } ?? -1
            let bg = live.map { AevonBoolOf($0, "isBackgrounded") } ?? -1
            // 0.0.73 — 承载面的位置每拍看一次。系统每次写 scene settings 都会把
            // `_UIScenePresentationView` 的 `frame` 重设成 scene 的 frame（原点 0,0、
            // transform 单位阵），卡片于是按 1:1 裁掉右侧与底栏 —— Aevon(63) 的
            // 「第一次打开内容尺寸不对、必须手动缩放一下」就是这一条。解释与量出来
            // 的数在 `FloatHost.reapplyPlacement`。这里只是让它自己回来：稳态
            // 200 ms 一拍，差 0.4% 就重写，值只在被抹掉的那几拍才写日志。
            _ = host.reapplyPlacement("beat")
            // 0.0.63 — 逻辑尺寸的看门狗，稳态两秒一次（10 拍 × 200 ms）。目标值
            // 记在 FloatHost 里（开窗与换比例时更新），真实值当场从 scene 的
            // settings 读 —— 对不上就重写一次，前四次各记一行。
            if beat % 10 == 0 {
                let want = host.canvas
                if want.height > 200 {
                    let got = AevonSceneFrameOf(scene)
                    if got.width > 0,
                       abs(got.width - want.width) > 1 || abs(got.height - want.height) > 1 {
                        let door = AevonPushSceneFrame(scene)
                        if drifts < 4 {
                            drifts += 1
                            Log.write(String(format: "win: frame drift now=%.0fx%.0f want=%.0fx%.0f door=%ld",
                                             got.width, got.height,
                                             want.width, want.height, door))
                        }
                    }
                }
            }
            // 0.0.50 — 画面本身的两个读数。`fg` 是我们自己写进去的，切换 App
            // 时它不变；`contentState` 才是「现在有没有画」，`level` 是母本那
            // 三件套里的第二件。Aevon(48) 的四份日志里 fg 一次没掉过，所以黑
            // 从来不是这条时钟看见的。
            let content = AevonContentStateOf(scene)
            let level = AevonSceneLevel(scene)
            // 0.0.91 — 每拍都要这个数（不只是写日志那一拍）：`cs=0 且
            // sublayers=0` 是「进程不在了」的形状 —— 只剩外壳、里面没有层。
            let sublayers = view.layer.sublayers?.count ?? 0
            // 0.0.59 — 首帧不在这里露。原来这一行是 `if content == 2 { reveal }`，
            // 而它是 200 ms 一拍 —— 冷启动的「先出现再闪」有一半时长就是这一拍
            // 攒出来的。现在交给 `watchFirstFrame`（50 ms 一拍、连续两拍确认）。
            // Read before the push, so the line below describes what the system
            // did rather than what this turn did.
            let attempts = AevonDeactCount()
            if attempts != deact {
                deact = attempts
                Log.write("win: scene deactivation #" + String(attempts)
                          + " fg=" + flag(fg))
            }
            var door = 0
            if fg == 1 {
                misses = 0
            } else if misses < 3 {
                if !marked { mark("WIN-PUSH"); marked = true }
                door = AevonPushForeground(scene)
                // 0.0.43 — door 3 is the transition-context write, the one that
                // crosses the scene bridge; it counts as a write like 1 and 2.
                // Door 4 means "already front, nothing spent": neither a write
                // nor a miss, which is exactly what the old 3 was to this clock.
                if door == 1 || door == 2 || door == 3 {
                    wrote += 1
                } else if door == 0 {
                    misses += 1
                }
            }
            if fg == 1 && marked {
                unmark()
                marked = false
            }
            // 0.0.50 — 掉画判定。`beat >= 2` 是因为第一拍上挂起启动的 scene
            // 本来就是 0，那不是掉画，是还没来得及画。
            //
            // 掉下去的那一刻记一行，回来的那一刻记一行带毫秒数 —— 下一份日志
            // 就能直接回答「黑了多少毫秒」，不用再靠肉眼对时间戳。
            var wake = 0
            if beat >= 3, content >= 0, content != 2 {
                if dropped == 0 {
                    dropped = beat
                    droppedAt = Date()
                    let one = String(format: "%.1f", level)
                    Log.write("win: picture dropped cs=" + String(content)
                              + " lvl=" + one + " fg=" + flag(fg))
                }
                // 0.0.52 — 唤醒从「掉画期间每拍都写」降成**兜底**：一段黑最多
                // 三次，其余拍只读数。母本的做法是事前改参数（AevonScene.m 的
                // intercept 段），它成功的时候这里一次都不该被走到；它没成功的
                // 时候，反复重申也只是在重提交同一个值 —— 0.0.49 的日志里三次
                // 掉画各写了一笔，黑还是 60/63/313 ms，多写的那几拍并不会更早。
                if wakes < 3 {
                    wake = AevonWakeScene(scene)
                    if wake != 0 { wakes += 1 }
                }
            } else if dropped != 0 {
                let ms = Int(Date().timeIntervalSince(droppedAt) * 1000)
                Log.write("win: picture back after " + String(ms) + "ms"
                          + " beats=" + String(beat - dropped)
                          + " wakes=" + String(wakes))
                dropped = 0
                // 0.0.51 — 这一段黑结束了，额度还回去。配额若是整场会话共用，
                // 切几十次 App 之后就用完了，那时候这段黑就又没人管 —— 一次
                // 修复不应该自带保质期。
                AevonWakeReset()
            }
            // 0.0.91 — 「掉下去之后**再也没回来**」和「掉一下又回来」是两件事。
            //
            // 前者在 Aevon(80)/Aevon(81) 里都是同一个形状：`cs=0`、`sublayers=0`、
            // App 侧日志停在某一秒，而卡片窗口、圆角、投影全在 —— 用户看到的就是
            // 「浮窗消失，只留一圈白色光晕」。掉画的兜底（写 settings）救不回它：
            // settings 管的是「这个场景该不该睡」，管不了「进程还在不在」。
            //
            // 于是：连续两拍确认，然后关卡、0.6 秒后用同一个 bundle 重开。
            if beat >= 6, content == 0, sublayers == 0, dropped != 0 {
                deadBeats += 1
            } else {
                deadBeats = 0
            }
            if deadBeats >= 2, let deadBundle = bundleID {
                Log.write("win: scene dead cs=0 layers=0 beats=" + String(deadBeats)
                          + " bundle=" + deadBundle)
                closeCard("scene dead")
                reviveCard(deadBundle)
                return
            }
            // Eight beats up front say how the first push went; after that one
            // line in four is enough to see the card settle or fail. Two lets,
            // because one long concatenation is a type-checker timeout (0.0.30
            // lost a build to exactly that).
            //
            // 0.0.33 — the card can now stay all afternoon, so the tail thins
            // out again at ten seconds a line. A clock that writes 14,400 lines
            // an hour is a log nobody can read and a file the operator has to
            // clear.
            var due = false
            if beat <= 8 {
                due = true
            } else if beat <= 40 {
                due = beat % 4 == 0
            } else {
                due = beat % 40 == 0
            }
            if due {
                let state = " fg=" + flag(fg)
                    + " bg=" + flag(bg)
                    + " door=" + String(door)
                    + " wrote=" + String(wrote)
                    + " misses=" + String(misses)
                let layers = String(sublayers)
                let shape = " cs=" + String(content)
                    + " lvl=" + String(format: "%.1f", level)
                    + " wake=" + String(wakes)
                // 0.0.52 — 两个拦截点的计数跟在后面。切一次 App，`ic` 动了说明
                // 系统真的把 settings 交给我们改；`iw` 动了说明那一笔已经被改成
                // 前台档。两个都不动，就是两个候选选择子在真机上一条都不走 ——
                // 那是下一版的起点，不是猜测。
                let gates = " ic=" + String(AevonInterceptCount())
                    + "/" + String(AevonInterceptWrites())
                Log.write("win: keepalive beat " + String(beat) + state
                          + " reasons=" + reasonsOf(scene)
                          + " sublayers=" + layers + shape + gates)
            }
            // 0.0.91 — 每 2 秒把 App 侧日志取回来一次。
            //
            // 0.0.90 只在「开卡 +4 秒」与「关卡」两个时刻取，所以进程一死，
            // 死前那几行必然留在它自己的 tmp 里、下一次开卡才被读走 ——
            // 三轮都指不出死因，一半原因在这里。稳态 0.2 s 一拍 ⇒ 10 拍 = 2 s。
            if beat % 10 == 0 {
                drainAppLog("beat", quiet: true)
            }
            // The clock runs for the life of the card, not for eight seconds.
            // `stopped` is the only exit, and `closeCard` is the only thing that
            // sets it.
            //
            // 0.0.40 — 250 ms is a quarter of a second of black whenever the
            // scene is not in front, and that is exactly the length of the gap
            // Aevon(38) describes. While anything is off the beat tightens to
            // 60 ms, so the recovery costs a few frames instead of a blink. The
            // steady state keeps the old interval: a clock that writes 16 lines a
            // second forever is a log nobody can read.
            //
            // 0.0.50 — 判据从 `fg` 换成 `contentState`：没有画也按「不在前台」
            // 处理。稳态从 250 ms 收到 200 ms，掉画期间仍然是 60 ms。
            let calm = (fg == 1 && content == 2)
            let wait: Double = calm ? 0.2 : 0.06
            if !stopped {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { keep() }
            } else if marked {
                unmark()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { keep() }

        // Nothing on this screen is hidden any more. 0.0.24 hid one view,
        // 0.0.25 hid the wrong window, 0.0.26 emptied every app-level window and
        // the operator got a black phone that eight seconds of restoring did not
        // bring back: a scene's layers are hosted by one container at a time, so
        // a card that holds them leaves the full-screen container empty, and an
        // empty container paints its own black. The mother ship solves this by
        // never being in that position — the app is in the background and the
        // desktop is the backdrop — so what is left here is one reading, one
        // second later, of whether a kept-alive scene really is still drawing.
        // One reading, one second in, of whether a kept-alive scene is really
        // still drawing — the difference between a card that works and 0.0.28's
        // black one. The container's hosted count is on the same line, because
        // `hosted=0` and `hosted=2` are the two answers this line exists for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let container = value(of: view, "hostContainerView") ?? view.subviews.first {
                NSStringFromClass(type(of: $0)).contains("HostContainer")
            }
            Log.write("win: after 1s hosted=" + String(count(of: container, "hostedLayers"))
                      + " nonHosted=" + String(count(of: container, "nonHostedLayers"))
                      + " sublayers=" + String(view.layer.sublayers?.count ?? 0)
                      + " reasons=" + reasonsOf(scene)
                      + " hosting=" + flag(AevonBoolOf(presenter, "isHosting")))
        }

        // 0.0.33 — no more eight second death. The card stays until the operator
        // closes it, drags it or resizes it; the teardown that used to be this
        // timer is `closeCard` above, called by the button.
        //
        // One cap remains. A card that is never closed holds a backgrounded app
        // in the foreground for as long as it lives: it renders, it plays audio,
        // it drains the battery, and the only thing on screen that would say so
        // is the card itself. Ten minutes is long enough to be a window and
        // short enough that forgetting one costs nothing, and it names itself in
        // the log so a card that vanished was not a crash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600.0) {
            closeCard("ten minute cap")
        }
    }

    /// The one witness a kill leaves behind: which call the process was inside.
    /// A getter never kills, but `activate` is not a getter, and this is the only
    /// way the next run can name it instead of inferring it from where the log
    /// stops.
    private static func mark(_ step: String) {
        try? step.write(toFile: Aevon.winStepPath, atomically: true, encoding: .utf8)
    }

    private static func unmark() {
        try? FileManager.default.removeItem(atPath: Aevon.winStepPath)
    }

    /// Says which call the previous run was inside when it died, then clears
    /// the marker. A marker that is never cleared is the only witness a
    /// watchdog kill leaves behind.
    ///
    /// 0.0.22 writes one marker again, because it makes one call that is not a
    /// getter: `-activate`. A marker that is never cleared is the only witness a
    /// kill leaves behind, and it is the difference between "died inside
    /// activate" and "died somewhere after the last line" — 0.0.16 cost a whole
    /// round to that difference.
    private static func reportLastStep() {
        let path = Aevon.winStepPath
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let step = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !step.isEmpty {
                Log.write("win: previous run died at " + step)
            }
            // One crash is a bug; the second one in the same place is a safe
            // mode. The card comes up without a picture this run, the log says
            // why, and the operator's phone does not go down a second time to
            // prove a point already made once.
            if step == "WIN-PUSH" {
                AevonBanPush()
                Log.write("win: push banned for this run - the previous one died inside it")
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Drains the C-side note buffer into the log, one line each. Called before
    /// every call that could end the process: an undrained note is lost work.
    private static func emitNotes(_ text: String?, cap: Int = 40) {
        guard let text = text, !text.isEmpty else { return }
        var printed = 0
        for raw in text.split(separator: "\n") {
            if printed >= cap { Log.write("win: …notes truncated at " + String(cap)); return }
            Log.write("win: " + raw.trimmingCharacters(in: .whitespaces))
            printed += 1
        }
    }

    /// -1 is "no such method", which is a different answer from 0.
    private static func flag(_ value: Int) -> String {
        switch value {
        case 1:  return "yes"
        case 0:  return "no"
        default: return "absent"
        }
    }

    private static func value(of object: NSObject, _ key: String) -> NSObject? {
        let sel = NSSelectorFromString(key)
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    /// Answers -1 for "no such method" and -1 for "not a list", which keeps a
    /// missing counter from reading as an empty one: `layers=0` is a fact about
    /// the scene, `layers=absent` is a fact about the probe.
    private static func count(of object: NSObject?, _ key: String) -> Int {
        guard let object = object, let list = value(of: object, key) as? NSArray else {
            return -1
        }
        return list.count
    }

    /// Called once at boot, before anything else touches the runtime. If the
    /// last scan left a marker, the class named in it is the one that stopped
    /// the process — a fault, a deadlock or a jetsam kill all leave the same
    /// log, and only this file tells them apart. The name is then added to the
    /// skip list, so the next scan steps over it and the dump keeps growing
    /// across runs instead of dying in the same place forever.
    static func reportPreviousDeath() {
        let manager = FileManager.default
        // Before anything else, and before the early return below: a fault can
        // arrive while the walk is still naming classes, and the number of the
        // signal is the one fact that does not have to be inferred from where
        // the log stops. No file at all is also an answer — the process was
        // killed, not faulted, and that is a different bug in a different place.
        if let fault = manager.contents(atPath: Aevon.callFaultPath), fault.count >= 4 {
            var value: UInt32 = 0
            for offset in 0..<4 {
                value |= UInt32(fault[offset]) << (8 * UInt32(offset))
            }
            let names: [UInt32: String] = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
                                          10: "SIGBUS", 11: "SIGSEGV"]
            Log.write("calls: previous run faulted with signal " + String(value)
                      + " " + (names[value] ?? "unrecognised"))
            try? manager.removeItem(atPath: Aevon.callFaultPath)
        }
        guard manager.fileExists(atPath: Aevon.callStatePath) else { return }
        defer { try? manager.removeItem(atPath: Aevon.callStatePath) }
        guard let data = manager.contents(atPath: Aevon.callStatePath), data.count > 4 else {
            Log.write("calls: previous scan died without naming a class")
            return
        }
        // Byte by byte rather than `withUnsafeBytes { load(as:) }`: a marker
        // that dies on an alignment trap would be a new reason to respring.
        var index: UInt32 = 0
        for offset in 0..<4 {
            index |= UInt32(data[offset]) << (8 * UInt32(offset))
        }
        let name = String(decoding: data.dropFirst(4), as: UTF8.self)
        guard !name.isEmpty, !name.contains("\n") else {
            Log.write("calls: previous scan died at " + String(index) + " unnamed")
            return
        }
        Log.write("calls: previous scan died at " + String(index) + " " + name)
        // Which image the name belongs to. `JSExport` is a name; the framework
        // it comes from is the answer to "why is this one different".
        if let cls = NSClassFromString(name), let image = class_getImageName(cls) {
            Log.write("calls: that class lives in " + String(cString: image))
        }
        var poison = loadSkipList()
        poison.insert(name)
        var text = "!" + Aevon.version + "\n"
        for entry in poison.sorted() { text += entry + "\n" }
        try? text.write(toFile: Aevon.callSkipPath, atomically: true, encoding: .utf8)
        Log.write("calls: skip list now holds " + String(poison.count) + " classes")
    }

    // MARK: - 0.0.59 首帧观察器

    /// 首帧什么时候到，由这个 50 ms 的心跳回答，不再等保活时钟。
    ///
    /// 三条判据，缺一条都不 reveal：
    ///   ① `contentState == 2` —— scene 自答「有内容」；
    ///   ② `layerManager.layers != 0` —— 层真的递交了（0 = 一个都没有；-1 = 探针
    ///      读不到，不能当成没有，否则卡片永远不出来）；
    ///   ③ 连续两拍都成立 —— 多出来的那一拍就是「这一帧已经上屏」的余量。
    ///      0.0.58 缺的正是这个余量：它照着 contentState 立刻淡入，淡入的前半
    ///      段画面还是黑的，后半段画面才来，一次渐变里夹一次跳变成了一闪。
    ///
    /// 观察器在 reveal、超时或卡片消失时自己停 —— SpringBoard 的主线程上不该
    /// 留一个永久心跳。
    private static func watchFirstFrame(_ host: FloatHost, scene: NSObject) {
        let started = Date()
        var beats = 0
        var ready = 0
        func tick() {
            if !host.waitingForFrame { return }
            beats += 1
            let content = AevonContentStateOf(scene)
            let layers = count(of: value(of: scene, "layerManager"), "layers")
            let drawn = (content == 2) && (layers != 0)
            ready = drawn ? ready + 1 : 0
            if ready >= 2 {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write(String(format: "win: first frame watch beats=%ld cs=%ld layers=%ld waited_ms=%ld",
                                 beats, content, layers, ms))
                host.revealContent("first frame")
                // 0.0.74 — 两次轻推撤掉了。
                //
                // 0.0.72/0.0.73 为了让 App 重排推了两次 17 pt（-17 → 还原 → +17 →
                // 还原），代价是操作者看得见的两次「跳一下」：Aevon(64) 的原话是
                // 「悬浮窗的内容会自己跳动，然后完成重排」。而 Aevon(64) 的日志证明
                // 这两推是多余的 —— 开卡时 App 自己就收到了
                // `app: page transition h=717 last=932`，之后 `app: geom` 里
                // scene / win / root / 顶栏 / 底栏 全部已经是 717 版的坐标。
                //
                // 「第一次打开内容尺寸不对」真正的病根是承载面被系统按 `scene.frame`
                // 重设（0.0.73 的 `placement put back`），那一条照旧，而且它只写
                // `transform` 与 `center`，不引起重排，所以完全看不见。
                for delay in [0.02, 0.35, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak host] in
                        guard let host = host, host.isUp else { return }
                        _ = host.reapplyPlacement("after first frame")
                    }
                }
                // 桥接的读数在 App 进程里写，1.2 s / 3.2 s 各一次 —— 4 s 后来取。
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    drainAppLog("after first frame")
                }
                return
            }
            // 3.2 s 与 `FloatHost.show` 里的 3 s 兜底错开 0.2 s：谁先到都行，
            // 但两边都不要在已经露出之后继续跑。
            if Date().timeIntervalSince(started) > 3.2 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick() }
        }
        // 第一拍也要让出去：`activate` 刚发完，同一 runloop 里读到的 layers 一定
        // 还是旧值。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick() }
    }

    // MARK: - Runtime helpers

    /// Same guard as RingHost: `UIApplication.shared` is force-unwrapped, and a
    /// probe must never be the reason a phone crashes.
    private static func sharedApplication() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: selector),
              let unmanaged = meta.perform(selector),
              let application = unmanaged.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        return application
    }

    /// Which of `names` a live object answers. Presence only: calling an unknown
    /// getter can hand back a struct and crash the caller.
    private static func accepted(_ object: NSObject, _ names: [String]) -> String {
        var hits: [String] = []
        for name in names where object.responds(to: NSSelectorFromString(name)) {
            hits.append(name)
        }
        return "[" + hits.joined(separator: ",") + "]"
    }
}

/// The signal handler itself, at file scope because `signal()` wants a C
/// function pointer and a static method is a question mark at the point of
/// conversion. Nothing here allocates: the fault may have happened inside
/// malloc, and a handler that allocates turns one crash into a hang.
///
/// It writes and then gets out of the way — restore the default action, raise
/// the same signal, and let the system finish what it started. A probe that
/// swallows a real crash is worse than one that causes it.
private func aevonFaultWitness(_ signo: Int32) {
    let fd = open(Aevon.callFaultPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        var slot = UInt32(truncatingIfNeeded: signo)
        withUnsafeBytes(of: &slot) { _ = write(fd, $0.baseAddress, 4) }
        _ = close(fd)
    }
    _ = signal(signo, SIG_DFL)
    _ = raise(signo)
}
