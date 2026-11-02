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
        try? FileManager.default.removeItem(atPath: Aevon.probePath)
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "api":   runSurface()
        case "calls": runCalls()
        default:      run()
        }
        return true
    }

    // MARK: - What to ask about

    /// Classes the master's carrier is built out of (all A-level evidence from
    /// the reverse notes), plus the two system-level ones that tell us whether
    /// SpringBoard still has a scene manager at all.
    private static let probeClasses = [
        "UIScenePresentationManager",
        "UIScenePresentation",
        "_UIContextLayerHostView",
        "SBDeviceApplicationSceneViewController",
        "SBDeviceApplicationSceneView",
        "SBDeviceApplicationSceneHandle",
        "FBSceneManager",
        "FBScene",
        "FBSMutableSceneSettings",
        "SBFluidSwitcherViewController",
        "SBMainWorkspace",
        "SBSceneManager",
        "SBWindowScene",
        "UIApplicationSceneDeactivationManager",
    ]

    /// Selectors worth having a type encoding for. The first two decide whether
    /// P1 is buildable at all; the rest are the ones the master hooks.
    private static let probeSelectors = [
        "createPresenterWithIdentifier:priority:",
        "initWithWindowScene:",
        "setWindowScene:",
        "_scene:interceptUpdateWithNewSettings:",
        "_setDeactivationReasons:onScene:withSettings:reason:",
        "enumerateScenesWithBlock:",
        "initWithSceneLayer:",
        "setWindowLevel:",
    ]

    /// asked of live objects: presence only, never called.
    private static let probeResponses = [
        "_sceneIdentifier", "_bundleIdentifier", "identifier", "settings",
        "clientSettings", "definition", "sceneHandle", "displayConfiguration",
    ]

    // MARK: - Running

    static func run() {
        Log.write("scene: probe begin")
        dumpClasses()
        dumpLiveTree()
        Log.write("scene: probe end")
    }

    private static func dumpClasses() {
        for name in probeClasses {
            guard let cls = NSClassFromString(name) else {
                Log.write("scene: class missing " + name)
                continue
            }
            Log.write("scene: class found " + name + " chain=" + chain(of: cls))
            for selector in probeSelectors {
                guard let types = encoding(cls, selector) else { continue }
                Log.write("scene: selector enc " + name + " " + selector + " " + types)
            }
        }
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
            Log.write("scene: accepts " + name + " " + accepted(scene))

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

    // MARK: - Surface probe (what P1 would actually have to call)

    /// The first dump answered "the classes exist". It could not answer the
    /// only question that matters for building: *which* selector turns an app's
    /// scene into a view I can hold. So this dump walks the runtime instead of a
    /// hand-written list — `_UIScenePresenter` and friends never appear in a
    /// strings dump, because Swift only ever names them through selectors.
    private static let censusNeedles = [
        "Presenter", "Presentation", "SceneSpecification", "SceneDefinition",
        "SceneParameters", "ContextLayer", "SceneLayer",
    ]

    /// Classes worth a full method list: both carrier controllers, both carrier
    /// views, all three handle classes, and the presentation pair.
    private static let surfaceClasses = [
        "SBDeviceApplicationSceneViewController",
        "SBApplicationSceneViewController",
        "SBSceneViewController",
        "SBApplicationSceneView",
        "SBSceneView",
        "SBDeviceApplicationSceneHandle",
        "SBApplicationSceneHandle",
        "SBSceneHandle",
        "_UIContextLayerHostView",
        "_UIScenePresentationView",
        "UIScenePresentationManager",
        "UIWindowScene",
        "FBSceneManager",
        "FBScene",
        "FBSMutableSceneDefinition",
        "FBSMutableSceneParameters",
        "FBSSceneSpecification",
        "FBSSceneIdentity",
        "FBSSceneClientIdentity",
    ]

    /// A full method list would be unreadable and mostly irrelevant; this keeps
    /// only the selectors that could possibly be part of the carrier.
    ///
    /// "Context" / "Host" / "resiz" were added after the first real run: the
    /// master's `setResizesHostedContext:` matches none of the original needles,
    /// so a class that defines it printed as if it did not — a gap that reads
    /// as a negative result. The 123-selector dump does not filter at all, but
    /// this one should still not lie.
    private static let surfaceNeedles = [
        "init", "scene", "Scene", "handle", "Handle", "present", "Present",
        "activat", "Activat", "layer", "Layer", "view", "View",
        "Context", "host", "Host", "resiz", "Resiz",
    ]

    private static let applicationSelectors = [
        "_scenePresentationManager", "scenePresentationManager", "_presentationManager",
        "_windowScene", "_mainScene", "_sceneManager", "connectedScenes",
    ]

    private static let applicationSceneSelectors = [
        "bundleIdentifier", "mainSceneHandle", "sceneHandleForSceneIdentifier:",
        "mainSceneIdentifier", "sceneIdentifier", "sceneHandles", "displayIdentity",
        "processState",
    ]

    private static let fbsManagerSelectors = [
        "sharedInstance", "sharedManager", "sceneWithIdentifier:", "enumerateScenesWithBlock:",
        "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:",
        "createSceneWithDefinition:",
    ]

    private static let sceneSurfaceSelectors = [
        "identifier", "specification", "layers", "clientProcess", "settings",
        "definition", "definitionIdentifier",
    ]

    static func runSurface() {
        Log.write("scene2: api probe begin")
        censusClasses()
        for name in surfaceClasses { dumpMethods(name) }
        dumpApplicationIvars()
        dumpInstalledApps()
        // Last on purpose: this is the only part that sends a message to
        // FrontBoard, so if anything here is unwelcome the data above survives.
        dumpFrontBoardScenes()
        Log.write("scene2: api probe end")
    }

    /// Every class in the process whose name looks like part of a scene carrier.
    /// Capped: SpringBoard carries thousands of classes and this walks them on
    /// the main thread.
    private static func censusClasses() {
        let classes = allClasses()
        guard !classes.isEmpty else { return }
        var matched = 0
        var printed = 0
        var owners: [String] = []
        for cls in classes {
            let name = NSStringFromClass(cls)
            guard censusNeedles.contains(where: { name.contains($0) }) else { continue }
            matched += 1
            if printed < 80 {
                printed += 1
                let parent = class_getSuperclass(cls).map { NSStringFromClass($0) } ?? "nil"
                Log.write("scene2: class census " + name + " <- " + parent)
            }
            if owners.count < 6, name.contains("Presenter") || name.contains("Specification") {
                owners.append(name)
            }
        }
        Log.write("scene2: census total " + String(matched) + " of " + String(classes.count))
        for name in owners { dumpMethods(name) }
    }

    /// `objc_copyClassList` hands back an autoreleasing pointer, which cannot be
    /// freed without a conversion Swift will not make; `objc_getClassList` into
    /// our own buffer is the same information with an owner. The first call is
    /// how you ask how big it has to be.
    private static func allClasses() -> [AnyClass] {
        let total = objc_getClassList(nil, 0)
        guard total > 0 else { return [] }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buffer.deallocate() }
        let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), total)
        guard count > 0 else { return [] }
        return (0..<Int(count)).map { buffer[$0] }
    }

    private static func dumpMethods(_ name: String) {
        guard let cls = NSClassFromString(name) else {
            Log.write("scene2: class missing " + name)
            return
        }
        dumpMethods(cls, label: name, prefix: "-")
        if let meta = object_getClass(cls) {
            dumpMethods(meta, label: name, prefix: "+")
        }
    }

    private static func dumpMethods(_ cls: AnyClass, label: String, prefix: String) {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return }
        var printed = 0
        for index in 0..<Int(count) {
            let method = methods[index]
            let selector = NSStringFromSelector(method_getName(method))
            guard surfaceNeedles.contains(where: { selector.contains($0) }) else { continue }
            if printed >= 90 { break }
            printed += 1
            let types = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            Log.write("scene2: method sel " + label + " " + prefix + selector + " " + types)
        }
        free(methods)
        Log.write("scene2: method total " + label + prefix + " " + String(count)
                  + " printed " + String(printed))
    }

    /// Workspace is the one place SpringBoard would keep a presentation manager
    /// for its own windows. Ivars are read through `object_getIvar`, and only
    /// when the type encoding says object — reading a CGRect as an object is a
    /// crash, not a curiosity.
    private static func dumpApplicationIvars() {
        guard let application = sharedApplication() else { return }
        Log.write("scene2: app accepts " + matrix(application, applicationSelectors))
        dumpIvars(of: application, needles: ["scene", "present"])
    }

    private static func dumpInstalledApps() {
        guard let cls = NSClassFromString("SBApplicationController") as? NSObject.Type else {
            Log.write("scene2: class missing SBApplicationController")
            return
        }
        let shared = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: shared),
              let controller = cls.perform(shared)?.takeUnretainedValue() as? NSObject else {
            Log.write("scene2: no SBApplicationController instance")
            return
        }
        let listSelector = NSSelectorFromString("allApplications")
        guard controller.responds(to: listSelector),
              let list = controller.perform(listSelector)?.takeUnretainedValue() as? NSArray else {
            Log.write("scene2: no allApplications")
            return
        }
        Log.write("scene2: apps total " + String(list.count))
        for index in 0..<Swift.min(3, list.count) {
            guard let app = list[index] as? NSObject else { continue }
            var bundle = "?"
            let bundleSelector = NSSelectorFromString("bundleIdentifier")
            if app.responds(to: bundleSelector),
               let value = app.perform(bundleSelector)?.takeUnretainedValue() as? String {
                bundle = value
            }
            Log.write("scene2: app bundle " + bundle + " "
                      + NSStringFromClass(type(of: app)))
            Log.write("scene2: app accepts " + matrix(app, applicationSceneSelectors))
            dumpIvars(of: app, needles: ["scene", "present"])
        }
    }

    /// FrontBoard's facade, without ever handing it a block. An earlier draft
    /// called `enumerateScenesWithBlock:`, which needs the Swift closure
    /// bit-cast into an ObjC block — a trick that either compiles and works or
    /// compiles and crashes, with no way to tell locally. The method list plus
    /// one guarded `sceneWithIdentifier:` answers the same question for free.
    private static func dumpFrontBoardScenes() {
        guard let cls = NSClassFromString("FBSceneManager") as? NSObject.Type else {
            Log.write("scene2: fbs manager absent")
            return
        }
        Log.write("scene2: fbs manager class " + matrix(cls, fbsManagerSelectors))
        let shared = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: shared),
              let manager = cls.perform(shared)?.takeUnretainedValue() as? NSObject else {
            Log.write("scene2: fbs manager has no instance")
            return
        }
        Log.write("scene2: fbs manager found " + NSStringFromClass(type(of: manager)))
        Log.write("scene2: fbs manager accepts " + matrix(manager, fbsManagerSelectors))

        let lookup = NSSelectorFromString("sceneWithIdentifier:")
        guard manager.responds(to: lookup) else {
            Log.write("scene2: fbs manager cannot look up")
            return
        }
        // SpringBoard's own scene is the one identifier we can name without
        // enumerating; it is also the scene a floating window would live on.
        guard let scene = manager.perform(lookup, with: "com.apple.springboard")?
                .takeUnretainedValue() as? NSObject else {
            Log.write("scene2: fbs springboard scene absent")
            return
        }
        Log.write("scene2: fbs scene found " + NSStringFromClass(type(of: scene)) + " "
                  + matrix(scene, sceneSurfaceSelectors))
    }

    // MARK: - Call table (the master's own calls, asked of iOS 17.3.1)

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
    private static var callStart = Date()

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
        callTargets = Set(callSelectors.split(separator: "\n").map(String.init))
        callHits = [:]
        callQueue = allClasses()
        callCursor = 0
        callStart = Date()
        Log.write("calls: definition begin v1 targets=" + String(callTargets.count)
                  + " classes=" + String(callQueue.count))
        guard !callQueue.isEmpty else {
            Log.write("calls: definition end v1 empty")
            return
        }
        scanStep()
    }

    /// Walked in slices, on the main thread. A single pass over ~99k classes is
    /// read-only, but it is also long enough to be visible as a hitch, and the
    /// watchdog does not care that the work is honest.
    private static func scanStep() {
        let total = callQueue.count
        let end = min(callCursor + 600, total)
        while callCursor < end {
            let cls = callQueue[callCursor]
            callCursor += 1
            collectMethods(of: cls, meta: false)
            collectMethods(of: cls, meta: true)
        }
        if callCursor < total {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { scanStep() }
            return
        }
        emitCallTable()
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

    private static func emitCallTable() {
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
        Log.write("calls: definition end v1 missing=" + String(missing)
                  + " capped=" + String(multi)
                  + " secs=" + String(Int(Date().timeIntervalSince(callStart))))
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

    /// Instance or class method, whichever exists, as the runtime spells it.
    private static func encoding(_ cls: AnyClass, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        if let method = class_getInstanceMethod(cls, selector),
           let types = method_getTypeEncoding(method) {
            return String(cString: types)
        }
        if let meta = object_getClass(cls), let method = class_getClassMethod(meta, selector),
           let types = method_getTypeEncoding(method) {
            return String(cString: types)
        }
        return nil
    }

    /// "Class <- Super <- NSObject": tells us at a glance whether a class is
    /// still the UIKit/FrontBoard one the master knew.
    private static func chain(of cls: AnyClass) -> String {
        var names: [String] = []
        var cursor: AnyClass? = cls
        var hops = 0
        while let current = cursor, hops < 6 {
            names.append(NSStringFromClass(current))
            cursor = class_getSuperclass(current)
            hops += 1
        }
        return names.joined(separator: "<-")
    }

    /// Which of the interesting selectors a live object answers. Presence only:
    /// calling an unknown getter can hand back a struct and crash the caller.
    private static func accepted(_ object: NSObject) -> String {
        return matrix(object, probeResponses)
    }

    private static func matrix(_ object: NSObject, _ names: [String]) -> String {
        var hits: [String] = []
        for name in names where object.responds(to: NSSelectorFromString(name)) {
            hits.append(name)
        }
        return "[" + hits.joined(separator: ",") + "]"
    }

    /// Same question asked of a class instead of an instance: `+sharedInstance`
    /// and friends are what tell us whether a facade is reachable at all.
    private static func matrix(_ cls: NSObject.Type, _ names: [String]) -> String {
        var hits: [String] = []
        for name in names where cls.responds(to: NSSelectorFromString(name)) {
            hits.append(name)
        }
        return "[" + hits.joined(separator: ",") + "]"
    }

    /// Instance variables up the whole chain, objects only. `class_copyIvarList`
    /// stops at the class it was asked about, so an ivar declared on the base
    /// class of `SBApplication` would otherwise be invisible.
    private static func dumpIvars(of object: NSObject, needles: [String]) {
        var cursor: AnyClass? = type(of: object)
        var hops = 0
        while let current = cursor, hops < 4 {
            let owner = NSStringFromClass(current)
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                var printed = 0
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    guard let pointer = ivar_getName(ivar) else { continue }
                    let name = String(cString: pointer)
                    let lowered = name.lowercased()
                    guard needles.contains(where: { lowered.contains($0) }) else { continue }
                    if printed >= 40 { break }
                    printed += 1
                    var note = " type=?"
                    if let typePointer = ivar_getTypeEncoding(ivar) {
                        let encoding = String(cString: typePointer)
                        if encoding.hasPrefix("@") {
                            let value = object_getIvar(object, ivar)
                            note = value.map { " obj=" + String(describing: Swift.type(of: $0)) }
                                ?? " obj=nil"
                        } else {
                            note = " type=" + encoding
                        }
                    }
                    Log.write("scene2: app ivar " + owner + "." + name + note)
                }
                free(ivars)
            }
            cursor = class_getSuperclass(current)
            hops += 1
        }
    }
}
