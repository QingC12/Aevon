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

        // The button lives inside Settings, so at the instant it is pressed the
        // app the operator wants to float is guaranteed to be in the background
        // — and a scene in the background pushes no layers to anybody. 0.0.22
        // hosted exactly that: a live presenter, `hosting=yes active=yes`, and
        // one empty sublayer. Six seconds is the window to switch apps, and the
        // scene is chosen when the timer fires rather than when the tap lands.
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
            float(scene)
        }
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
    private static func float(_ scene: NSObject) {
        guard let manager = value(of: scene, "uiPresentationManager") else {
            Log.write("win: no uiPresentationManager")
            return
        }

        // How many layers the scene is offering at all. A suspended background
        // scene offers none; a foreground one offers at least its display
        // layer. Read before anything is built, so the number describes the
        // scene rather than our own work on it.
        let layerManager = value(of: scene, "layerManager")
        Log.write("win: scene layerManager="
                  + (layerManager.map { NSStringFromClass(type(of: $0)) } ?? "nil")
                  + " layers=" + String(count(of: layerManager, "layers")))

        guard let made = AevonCreatePresenter(manager, "com.aevon.float", 0),
              let presenter = made as? NSObject else {
            Log.write("win: no presenter")
            emitNotes(AevonTakeNotes())
            return
        }
        Log.write("win: presenter cls=" + NSStringFromClass(type(of: presenter)))

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

        // Window first, activate second. This is the whole difference from
        // 0.0.20, and the difference between a picture and a black phone.
        guard let host = FloatHost.show(view) else {
            Log.write("win: no window - nothing activated")
            return
        }
        Log.write("win: window up level=" + String(format: "%.0f", host.level))

        mark("APP-activate")
        let ran = AevonCallVoid(presenter, "activate")
        unmark()
        Log.write("win: activate ran=" + (ran == 1 ? "yes" : "no such method"))
        Log.write("win: state hosting=" + flag(AevonBoolOf(presenter, "isHosting"))
                  + " active=" + flag(AevonBoolOf(presenter, "isActive")))
        Log.write("win: view sublayers=" + String(view.layer.sublayers?.count ?? 0))

        // Aevon(22) settled the question the last three versions were asking.
        // The card does hold the picture, and in the same run the rest of the
        // screen went black — because a scene's layers are hosted by one
        // container at a time. Taking them into the card emptied the container
        // SpringBoard had built for the full-screen app, and an empty container
        // draws its own black. The mother ship does not mirror (her symbol
        // table has one `presentationView` and no mirror entry); her shape is
        // "the app lives in the card, the desktop is outside". So the emptied
        // container is taken out of sight — alpha only, recorded, restored on
        // close — and what shows through is whatever SpringBoard still has
        // underneath it.
        demoteFullScreen(scene)

        // One second later, does the scene still consider itself on screen? A
        // hidden full-screen container can make SpringBoard retire the scene,
        // and a retired scene would freeze the card. This is the one reading
        // that tells "the desktop is black" apart from "the scene was put to
        // sleep", and they need opposite fixes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let layers = view.layer.sublayers?.count ?? 0
            Log.write("win: after demote presenter hosting=" + flag(AevonBoolOf(presenter, "isHosting"))
                      + " active=" + flag(AevonBoolOf(presenter, "isActive"))
                      + " sublayers=" + String(layers))
            inspectDesktop()
            recheckAlpha()
            // The card going empty is the one answer that says the scene was
            // retired rather than that the desktop is not drawn. Put the full
            // screen back at once: a frozen card over a hidden picture is the
            // worst of both.
            if layers == 0 {
                restoreFullScreen()
                Log.write("win: card went empty, full screen put back")
            }
        }

        // The counters that separate the three ways a card can be blank, none
        // of which a sublayer count can tell apart:
        //   layers=absent                 the scene has nothing to give
        //   nonHosted>0, hosted=0         layers exist but were not attached
        //   hosted>0 and still blank      geometry, not content
        let container = value(of: view, "hostContainerView")
        Log.write("win: container cls="
                  + (container.map { NSStringFromClass(type(of: $0)) } ?? "nil")
                  + " hosted=" + String(count(of: container, "hostedLayers"))
                  + " nonHosted=" + String(count(of: container, "nonHostedLayers")))

        // It comes down by itself: a window whose only job is to prove the chain
        // has no business staying on screen, and one that stays is one that can
        // be left behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            _ = AevonCallVoid(presenter, "deactivate")
            _ = AevonCallVoid(presenter, "invalidate")
            FloatHost.hide()
            // After the presenter is gone the layers go back to the container
            // SpringBoard built, so it has to be visible again before anyone
            // notices it was taken away.
            restoreFullScreen()
            Log.write("win: closed after 8s")
        }
    }

    // MARK: - Taking the emptied full screen out of sight

    /// A view that carries a scene's picture, and the window SpringBoard keeps
    /// it in.
    private struct Carrier {
        let view: UIView
        let top: UIView
        let window: UIWindow
        let name: String
        let ident: String
    }

    /// One view that was taken out of sight, kept with everything needed to put
    /// it back exactly as it was.
    private struct Saved {
        let view: UIView
        let alpha: CGFloat
        let background: UIColor?
        let name: String
    }

    private static var saved: [Saved] = []
    private static var savedWindow: (window: UIWindow, background: UIColor?,
                                     opaque: Bool, alpha: CGFloat, name: String)?
    private static var savedExtra: [(window: UIWindow, background: UIColor?,
                                     opaque: Bool, name: String)] = []

    /// The classes SpringBoard puts between a window and a scene's picture.
    ///
    /// Deliberately narrow: the desktop, the icon layer and the status bar are
    /// the three things that must survive this, so a name that mentions any of
    /// them is never a candidate — on this phone the desktop showing through is
    /// the entire point of the change.
    private static func isCarrier(_ name: String) -> Bool {
        isAppCarrier(name) || name.contains("_UIScenePresentationView")
    }

    /// Only the three classes SpringBoard uses for an *application* scene.
    ///
    /// `_UIScenePresentationView` is deliberately not in this list: it is also
    /// what the wallpaper is drawn into, and Aevon(24) showed what that costs —
    /// with the operator still in Settings, the search named the wallpaper's
    /// presenter as the only carrier and the run refused to build anything. A
    /// carrier that cannot name its own scene is only trusted when its class is
    /// one of these.
    private static func isAppCarrier(_ name: String) -> Bool {
        return name.contains("SBDeviceApplicationSceneView")
            || name.contains("SBAppContainerView")
            || name.contains("SBSceneContainerView")
    }

    /// What a view says its scene is, in the spellings SpringBoard uses. An
    /// empty answer is not a failure — `_UIScenePresentationView` keeps its
    /// identity on the presenter, not on itself.
    private static func sceneIdentifier(of view: UIView) -> String {
        for key in ["sceneIdentifier", "_sceneIdentifier"] {
            if let text = value(of: view, key) as? String, !text.isEmpty { return text }
        }
        if let handle = value(of: view, "sceneHandle") {
            for key in ["sceneIdentifier", "identifier"] {
                if let text = value(of: handle, key) as? String, !text.isEmpty { return text }
            }
        }
        if let scene = value(of: view, "scene") {
            for key in ["identifier", "sceneIdentifier"] {
                if let text = value(of: scene, key) as? String, !text.isEmpty { return text }
            }
        }
        return ""
    }

    /// The child of the window that contains `node`. Hiding this instead of the
    /// carrier itself is the difference between "the picture is gone" and "the
    /// picture is gone and so is the black parent behind it".
    private static func container(of node: UIView, in window: UIWindow) -> UIView? {
        var current = node
        var steps = 0
        while let parent = current.superview, parent !== window {
            current = parent
            steps += 1
            if steps > 64 { return nil }
        }
        return current.superview === window ? current : nil
    }

    /// Finds the full-screen presentation of the scene we are drawing in the
    /// card and sets its alpha to 0. Nothing is removed, nothing is hidden, no
    /// selector is invented: alpha is a property every UIView has, and it is
    /// put back to its previous value on teardown.
    private static func demoteFullScreen(_ scene: NSObject) {
        let identifier = value(of: scene, "identifier").map { String(describing: $0) } ?? ""
        let wanted = identifier.hasPrefix("sceneID:") ? String(identifier.dropFirst(8)) : identifier
        var bundle = wanted
        if let dash = wanted.range(of: "-default") {
            bundle = String(wanted[..<dash.lowerBound])
        }

        guard let app = sharedApplication() else {
            Log.write("win: no application to search for the full screen")
            return
        }

        var windows = 0
        var matched: Carrier?
        var spare: Carrier?

        for window in app.windows {
            if window is FloatWindow { continue }
            windows += 1
            let windowClass = NSStringFromClass(type(of: window))
            Log.write("win: springboard window " + windowClass
                      + " level=" + String(format: "%.0f", window.windowLevel.rawValue)
                      + " hidden=" + (window.isHidden ? "yes" : "no")
                      + " alpha=" + String(format: "%.1f", window.alpha)
                      + " size=" + String(format: "%.0fx%.0f",
                                          window.bounds.width, window.bounds.height))
            if matched != nil { continue }

            var queue: [UIView] = [window]
            var head = 0
            while head < queue.count && head < 4000 {
                let node = queue[head]
                head += 1
                let name = NSStringFromClass(type(of: node))
                if isCarrier(name), let top = container(of: node, in: window) {
                    let ident = sceneIdentifier(of: node)
                    let carrier = Carrier(view: node, top: top, window: window,
                                          name: name, ident: ident)
                    let hit = !wanted.isEmpty
                        && (ident.contains(wanted) || (!bundle.isEmpty && ident.contains(bundle)))
                    if hit {
                        matched = carrier
                        Log.write("win: presentation carrier " + name
                                  + " ident=" + ident
                                  + " top=" + NSStringFromClass(type(of: top)))
                        break
                    }
                    // A carrier that cannot name its scene is only used when it
                    // is the full screen, because the one thing this step must
                    // never do is take the desktop out of sight.
                    if spare == nil, ident.isEmpty {
                        let area = top.window?.bounds ?? .zero
                        let covers = area.width > 64 && area.height > 64
                            && top.frame.width >= area.width * 0.8
                            && top.frame.height >= area.height * 0.8
                        if covers {
                            spare = carrier
                            Log.write("win: presentation carrier " + name
                                      + " ident=?"
                                      + " top=" + NSStringFromClass(type(of: top)))
                        }
                    }
                }
                queue.append(contentsOf: node.subviews)
            }
        }

        guard let chosen = matched ?? spare else {
            Log.write("win: no full screen container (windows=" + String(windows) + ")")
            return
        }
        if matched == nil {
            Log.write("win: no carrier named the scene, using the only one found")
        }

        let window = chosen.window
        let windowName = NSStringFromClass(type(of: window))
        guard !windowName.contains("HomeScreen"), !windowName.contains("Wallpaper") else {
            Log.write("win: refused to hide a desktop window " + windowName)
            return
        }

        // The matched window's own background goes first: a window that paints
        // black behind its children would keep painting black after the children
        // are gone.
        let background = window.backgroundColor
        let opaqueBefore = window.isOpaque
        savedWindow = (window, background, opaqueBefore, window.alpha, windowName)
        window.backgroundColor = .clear
        window.isOpaque = false
        Log.write("win: window background cleared " + windowName
                  + " opaque=" + (opaqueBefore ? "yes" : "no")
                  + " hadColor=" + (background == nil ? "no" : "yes"))

        // Everything above the desktop goes transparent: the matched window's
        // direct children first, then the children of every other window sitting
        // at the app's own level. 0.0.25 proved why the narrow version cannot
        // work — it took down fifteen views whose top was
        // `SBFluidSwitcherTouchPassThroughScrollView` (430x1398), i.e. the app
        // switcher, and the screen did not change at all.
        //
        // The one fact that makes the wide version safe is on the same log: the
        // home screen is a window of its own at level -2 with three live
        // subviews and three layers (`layers=3`), so emptying the layer above it
        // can only leave the desktop showing. Nothing here touches that window,
        // the wallpaper window, the status bar or the dynamic island.
        var emptied = hideChildren(of: window)

        for other in app.windows {
            if other === window { continue }
            let name = NSStringFromClass(type(of: other))
            if name.contains("Aevon") || name.contains("HomeScreen")
                || name.contains("Wallpaper") || name.contains("SystemAperture")
                || name.contains("StatusBar") || name.contains("TextEffects")
                || name.contains("CoverSheet") || name.contains("ControlCenter")
                || name.contains("Screenshots") || name.contains("Recording")
                || name.contains("AlertItem") || name.contains("Keyboard") { continue }
            let level = other.windowLevel.rawValue
            guard level >= -2, level <= 9, !other.isHidden, other.alpha > 0 else { continue }
            Log.write("win: app layer window " + name
                      + " level=" + String(format: "%.0f", level)
                      + " children=" + String(other.subviews.count))
            emptied += hideChildren(of: other)
            savedExtra.append((other, other.backgroundColor, other.isOpaque, name))
            other.backgroundColor = .clear
            other.isOpaque = false
        }
        Log.write("win: app layer emptied views=" + String(emptied))
    }

    /// Takes every direct child of one window out of sight and returns how many
    /// there were. Direct children rather than a chain: a chain leaves siblings
    /// behind, and a sibling is exactly what an opaque background view is.
    private static func hideChildren(of window: UIWindow) -> Int {
        var count = 0
        for view in window.subviews {
            let name = NSStringFromClass(type(of: view))
            let record = Saved(view: view, alpha: view.alpha,
                               background: view.backgroundColor, name: name)
            saved.append(record)
            view.alpha = 0
            if let background = view.backgroundColor, background != UIColor.clear {
                view.backgroundColor = .clear
            }
            Log.write("win: hidden child " + name
                      + " alpha=" + String(format: "%.1f", record.alpha)
                      + " size=" + String(format: "%.0fx%.0f",
                                          view.frame.width, view.frame.height)
                      + " subs=" + String(view.subviews.count))
            count += 1
        }
        return count
    }

    /// Whether SpringBoard put anything back.
    ///
    /// If the system re-applies its own layout a frame later, every alpha change
    /// this file makes is pointless, and that is worth one line rather than one
    /// more version spent on the same idea.
    private static func recheckAlpha() {
        var reset = 0
        for item in saved where item.view.alpha > 0.5 {
            reset += 1
        }
        Log.write("win: alpha recheck kept=" + String(saved.count - reset)
                  + " reset=" + String(reset))
    }

    /// Puts everything back, newest first. Called on teardown, before this file
    /// forgets what it changed, so a failed run cannot leave a hole in
    /// SpringBoard's hierarchy.
    private static func restoreFullScreen() {
        if let record = savedWindow {
            record.window.alpha = record.alpha
            record.window.backgroundColor = record.background
            record.window.isOpaque = record.opaque
            Log.write("win: window restored " + record.name)
            savedWindow = nil
        }
        for item in saved {
            item.view.alpha = item.alpha
            item.view.backgroundColor = item.background
        }
        if !saved.isEmpty {
            Log.write("win: fullscreen restored layers=" + String(saved.count))
        }
        saved.removeAll()
        for item in savedExtra {
            item.window.backgroundColor = item.background
            item.window.isOpaque = item.opaque
        }
        if !savedExtra.isEmpty {
            Log.write("win: app windows restored count=" + String(savedExtra.count))
        }
        savedExtra.removeAll()
    }

    /// What the desktop looks like right now.
    ///
    /// "The outside is still black" has two very different causes and they need
    /// opposite fixes: the app's picture is still on screen, or the desktop
    /// stopped being drawn at all. A home screen view with no sublayers is the
    /// second one, and no amount of alpha on the app's side would ever fix it.
    private static func inspectDesktop() {
        guard let app = sharedApplication() else { return }
        for window in app.windows {
            let name = NSStringFromClass(type(of: window))
            guard name.contains("HomeScreen") || name.contains("Wallpaper") else { continue }
            let root = window.rootViewController?.view
            let rootClass = window.rootViewController.map {
                NSStringFromClass(type(of: $0))
            } ?? "nil"
            Log.write("win: desktop " + name + " root=" + rootClass
                      + " alpha=" + String(format: "%.1f", root?.alpha ?? -1)
                      + " subviews=" + String(root?.subviews.count ?? -1)
                      + " layers=" + String(root?.layer.sublayers?.count ?? -1))
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
