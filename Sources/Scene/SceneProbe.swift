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

    // MARK: - Window build (0.0.21): the mother ship's route, heard

    /// Four SpringBoard deaths and one black screen taught the same lesson:
    ///   0.0.15  `_createSceneWithDefinition:` — four nils, one of them a block
    ///   0.0.16  `_UIContextLayerHostView initWithSceneLayer:` — the class name
    ///           was right, but the argument was a CALayer where an FBSceneLayer
    ///           is read; 0.0.19 got the encoding, `@24@0:8@16`, so the ABI was
    ///           never the problem
    ///   0.0.20  `-activate` on a presenter of our own, on three live scenes.
    ///           Every one of them went `hosting=no active=no` ->
    ///           `hosting=yes active=yes` with `superview=nil`, and the phone
    ///           went black while SpringBoard kept answering heartbeats.
    ///
    /// The first two were calls that do not exist. The third *does* exist and
    /// works — for the object that owns the view and the window it goes into.
    /// Stheno never makes it: her selector surface
    /// (`analysis/extracts/stheno-selector-surface.txt`) has no `activate`,
    /// `createPresenterWithIdentifier:priority:` sits in `__const` where a hook
    /// target lives, and `analysis/scene-lifecycle-model.md` lists
    /// `UIScenePresentationManagerHook` among her hook groups. She reads the
    /// presenter the system activated for itself.
    ///
    /// So this version reads that presenter, then listens for the next one the
    /// system makes. It creates nothing, activates nothing, moves nothing. A
    /// latch file and two timers make sure the listening stops by itself.
    static func runWindow() {
        reportLastStep()

        guard let manager = AevonSceneManager() as? NSObject else {
            Log.write("win: no manager")
            return
        }
        Log.write("win: begin manager cls=" + NSStringFromClass(type(of: manager)))

        // The method tables 0.0.20 printed are no longer dumped. Every line of
        // them is in `Aevon(19)..log` and in docs/REVERSE-NOTES.md, and a dump
        // that is already on disk costs bytes, seconds and one more chance to
        // touch a class that does not like being asked. What this run needs is
        // the two things the tables cannot answer: who the system's live
        // presenter is, and when the system creates and activates one.

        var foregroundApp: NSObject?
        var seen = 0
        let visit: (Any?) -> Void = { scene in
            guard let scene = scene as? NSObject else { return }
            seen += 1
            let ident = value(of: scene, "identifier").map { String(describing: $0) } ?? "?"
            if seen <= 10 { Log.write("win: s" + String(seen) + " id=" + ident) }
            // App scenes arrive as `sceneID:<bundle id>-default`. The first one
            // that is neither SpringBoard nor Settings is the app the operator
            // opened, and it is the one a floating window would have to host.
            //
            // 0.0.21 stops listing at that one. SpringBoard's scene and the
            // remote keyboard's are out of scope from here on: 0.0.20 activated
            // a presenter on each of them, and taking the presentation of the
            // scene that draws the whole screen is how the phone went black.
            if ident.hasPrefix("sceneID:") && !ident.contains("com.apple.springboard")
                && !ident.contains("com.apple.Preferences") {
                if foregroundApp == nil { foregroundApp = scene }
            }
        }
        AevonEnumerateScenes(manager, visit)
        Log.write("win: scenes=" + String(seen))

        // What an app scene is actually made of. This is the object a floating
        // window would host, so its shape decides whether a layer can be taken
        // from it at all.
        guard let app = foregroundApp else {
            Log.write("win: no app scene in the list this run")
            installHooks()
            return
        }
        dumpScene(app, tag: "APP")

        // 0.0.21 — read the presenter the system already activated, instead of
        // building one and activating it. This is the whole difference between
        // 0.0.20 and the mother ship, and it is free: `activePrioritizedPresenter`
        // and `presentationView` are getters.
        inspectLive(app)

        // Then listen. Nothing below touches a view, a presenter or a window.
        installHooks()
    }

    /// Says which call the previous run was inside when it died, then clears
    /// the marker. A marker that is never cleared is the only witness a
    /// watchdog kill leaves behind.
    ///
    /// 0.0.21 no longer writes new markers from here: the only calls this
    /// version makes are getters, and a getter that kills a process is not the
    /// thing that goes wrong next. The latch file is the new witness, and it
    /// covers the failure 0.0.20 produced — a run that finished, left something
    /// installed, and took the screen with it.
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

    /// 0.0.21 — read the presenter the system already activated.
    ///
    /// 0.0.20 built a presenter of its own and called `-activate` on it. On all
    /// three live scenes the answer was identical: `hosting=no active=no` ->
    /// `hosting=yes active=yes`, sublayers 0 -> 1, host container view absent ->
    /// `_UISceneLayerHostContainerView`, and `superview=nil` the entire time.
    /// The presenter took the scene's layers and put them in a view that
    /// belongs to no window, so nothing was drawn and no touch had a target.
    /// SpringBoard stayed alive — `heartbeat: 60s uptime reached` is in that
    /// log — and the phone was black until it was restarted.
    ///
    /// Stheno never calls `-activate`. Her selector surface has no such entry;
    /// `createPresenterWithIdentifier:priority:` is in `__const`, where a hook
    /// target lives, and `scene-lifecycle-model.md` lists
    /// `UIScenePresentationManagerHook` among her hook groups. She takes the
    /// presenter the system activated for itself. That presenter already
    /// exists in this process — `_UIScenePresenterOwner` sits in the manager's
    /// ivars, and 0.0.20 printed its method table.
    ///
    /// So this walks to it and reads four getters. `activePrioritizedPresenter`
    /// is the owner's own answer to "which of my presenters is the live one";
    /// that is the object whose view a floating window would take, and the only
    /// question left is where the system keeps it.
    private static func inspectLive(_ scene: NSObject) {
        guard let manager = value(of: scene, "uiPresentationManager") else {
            Log.write("win: APP uiPresentationManager absent")
            return
        }
        // An ivar, not a getter: 0.0.20 printed `_scenePresenterOwner` from
        // `_ivarDescription:`, and no method of that name exists.
        guard let owner = AevonGetIvar(manager, "_scenePresenterOwner") as? NSObject else {
            Log.write("win: APP owner ivar absent")
            return
        }
        Log.write("win: APP owner cls=" + NSStringFromClass(type(of: owner)))

        guard let live = value(of: owner, "activePrioritizedPresenter") else {
            // Not a failure: it means the system holds no live presenter for
            // this scene right now, which is itself the reason a float window
            // built on `activate` could only ever steal one.
            Log.write("win: APP owner has no active presenter")
            return
        }
        Log.write("win: APP live presenter cls=" + NSStringFromClass(type(of: live))
                  + " id=" + (value(of: live, "identifier").map { String(describing: $0) } ?? "?"))
        Log.write("win: APP live presenter state"
                  + " hosting=" + flag(AevonBoolOf(live, "isHosting"))
                  + " active=" + flag(AevonBoolOf(live, "isActive"))
                  + " invalidated=" + flag(AevonBoolOf(live, "isInvalidated")))

        guard let view = value(of: live, "presentationView") else {
            Log.write("win: APP live presenter has no presentationView")
            return
        }
        Log.write("win: APP live view cls=" + NSStringFromClass(type(of: view)))
        describe(view, tag: "APP.live")
        // Where the system keeps it. Two levels is enough to tell "pinned under
        // the scene's own view controller" from "inside a wrapper we would have
        // to unwrap", and the window answer says whether it is on screen at all.
        walkParents(view, depth: 3)
    }

    /// The parent chain of a view, plus the window it lives in. `UIView.window`
    /// walks the chain itself and answers nil when the view is detached, which
    /// is exactly the difference 0.0.20 could not see.
    private static func walkParents(_ view: NSObject, depth: Int) {
        guard let ui = view as? UIView else { return }
        var node: UIView? = ui
        var level = 0
        while let current = node, level < depth {
            let f = current.frame
            Log.write("win: parent level " + String(level) + " "
                      + NSStringFromClass(type(of: current))
                      + " frame=" + String(format: "%.0fx%.0f at %.0f,%.0f",
                                           f.size.width, f.size.height,
                                           f.origin.x, f.origin.y)
                      + " subviews=" + String(current.subviews.count))
            node = current.superview
            level += 1
        }
        if let window = ui.window {
            Log.write("win: live view window=" + NSStringFromClass(type(of: window))
                      + " level=" + String(format: "%.1f", window.windowLevel)
                      + " hidden=" + (window.isHidden ? "yes" : "no"))
        } else {
            Log.write("win: live view is not in any window")
        }
    }

    // MARK: - Hooks, and the four ways out

    /// Replaces the two ends of the mother ship's route with calls that forward
    /// everything and write a line. Nothing is created, nothing is activated,
    /// nothing is moved: this version can only observe.
    ///
    /// Four answers to "what if it goes wrong", because 0.0.20's failure was
    /// invisible to every guard this project already had — nothing crashed, the
    /// screen just went black and stayed black:
    ///
    ///   1. a latch file written *before* the first IMP is replaced, deleted
    ///      only after a full revert. Still on disk next time = the last run
    ///      never got out = do not install again.
    ///   2. all-or-nothing inside the C side: if either end of the route fails
    ///      to hand back its original IMP, everything already replaced is put
    ///      back and the answer is 0.
    ///   3. a soft timer: 30 s with no system presenter traffic means the hook
    ///      is not going to hear anything today, so it goes away early.
    ///   4. a hard timer: 90 s and it is reverted whatever happened. A
    ///      replacement left in a system class is the one thing this version
    ///      must never do.
    private static func installHooks() {
        let manager = FileManager.default

        // Pressed twice inside the same 90 s window. The originals are already
        // replaced in this process; replacing a replacement would hand us our
        // own IMP back as the "original" and the route would never come back.
        if AevonHooksLive() > 0 {
            Log.write("win: hooks from this process are still live — request ignored")
            return
        }

        if manager.fileExists(atPath: Aevon.hookLatchPath) {
            Log.write("win: hook latch from the previous run is still on disk"
                      + " — that run never reverted. Not installing.")
            try? manager.removeItem(atPath: Aevon.hookLatchPath)
            Log.write("win: latch cleared; the next request may install again")
            return
        }

        do {
            try "hook\n".write(toFile: Aevon.hookLatchPath, atomically: true, encoding: .utf8)
        } catch {
            Log.write("win: latch not writable — refusing to install")
            return
        }

        let live = AevonInstallHooks()
        // Drained immediately: the install itself writes which selector it
        // refused, and "hooks live=0" alone would not say why.
        drainHooks(AevonTakeHookLog() ?? "")
        guard live > 0 else {
            Log.write("win: hooks not installed (route incomplete) — nothing replaced")
            try? manager.removeItem(atPath: Aevon.hookLatchPath)
            return
        }
        Log.write("win: hooks live=" + String(live)
                  + " soft=30s hard=90s")

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard AevonHooksLive() > 0 else { return }
            let heard = AevonTakeHookLog() ?? ""
            drainHooks(heard)
            if heard.isEmpty {
                revertHooks("soft: no presenter traffic in 30s")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            guard AevonHooksLive() > 0 else { return }
            drainHooks(AevonTakeHookLog() ?? "")
            revertHooks("hard: 90s elapsed")
        }
    }

    /// Puts every original back and clears the latch only when nothing is left
    /// replaced. A revert that reports success while an IMP is still ours would
    /// be worse than not reverting at all.
    private static func revertHooks(_ why: String) {
        let back = AevonRemoveHooks()
        let still = AevonHooksLive()
        if still == 0 {
            try? FileManager.default.removeItem(atPath: Aevon.hookLatchPath)
            Log.write("win: hooks reverted " + String(back) + " — " + why)
        } else {
            Log.write("win: hooks still live=" + String(still)
                      + " after revert — " + why)
        }
    }

    private static func drainHooks(_ text: String) {
        for raw in text.split(separator: "\n") {
            Log.write("win: hook " + raw.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Frame, layer tree and host container of a presentation view. A view that
    /// is not in a window has no superview and its own coordinate space — that
    /// is the difference between "the presenter made a view" and "the presenter
    /// is hosting", and this line is where the difference shows.
    private static func describe(_ view: NSObject, tag: String) {
        guard let ui = view as? UIView else {
            Log.write("win: " + tag + " not a UIView, cls=" + NSStringFromClass(type(of: view)))
            return
        }
        let f = ui.frame
        Log.write("win: " + tag + " frame="
                  + String(format: "%.0fx%.0f at %.0f,%.0f", f.size.width, f.size.height,
                           f.origin.x, f.origin.y)
                  + " hidden=" + (ui.isHidden ? "yes" : "no")
                  + " superview=" + (ui.superview.map { NSStringFromClass(type(of: $0)) } ?? "nil")
                  + " sublayers=" + String(ui.layer.sublayers?.count ?? 0))
        if let host = value(of: view, "hostContainerView") {
            Log.write("win: " + tag + " host container view=" + NSStringFromClass(type(of: host)))
        } else {
            Log.write("win: " + tag + " host container view absent")
        }
        if let context = value(of: view, "currentPresentationContext") {
            Log.write("win: " + tag + " presentation context=" + NSStringFromClass(type(of: context)))
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

    /// What a live scene is made of, in its own words. `_ivarDescription` is the
    /// only reader that works on a FrontBoard object without knowing its shape,
    /// which is exactly the situation: headers are not available, and guessing
    /// a field name is how a probe lies to itself.
    private static func dumpScene(_ scene: NSObject, tag: String) {
        let ident = value(of: scene, "identifier").map { String(describing: $0) } ?? "?"
        Log.write("win: " + tag + " " + NSStringFromClass(type(of: scene)) + " id=" + ident)
        for key in ["definition", "settings", "clientSettings", "uiPresentationManager"] {
            guard let obj = value(of: scene, key) else {
                Log.write("win: " + tag + " " + key + " absent")
                continue
            }
            Log.write("win: " + tag + " " + key + " cls=" + NSStringFromClass(type(of: obj)))
            emitIvars(obj, tag: tag + "." + key)
        }
    }

    private static func emitIvars(_ object: NSObject, tag: String) {
        let sel = NSSelectorFromString("_ivarDescription")
        guard object.responds(to: sel),
              let text = object.perform(sel)?.takeUnretainedValue() as? String else {
            Log.write("win: " + tag + " no ivars")
            return
        }
        var printed = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if printed >= 20 { Log.write("win: " + tag + " …capped"); return }
            Log.write("win: " + tag + " " + line)
            printed += 1
        }
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
