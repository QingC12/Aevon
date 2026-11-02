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

    /// Settings side. Writing the request file *is* the request: the tweak's
    /// prefs observer sees the notification and runs the dump inside
    /// SpringBoard, which is the only process that has the real scene tree.
    ///
    /// The file's *content* picks the dump. Two dumps instead of one button
    /// because they answer different questions and each has its own blast
    /// radius: the tree walk only reads, the surface walk sends two messages to
    /// FrontBoard.
    static func request(_ mode: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        do {
            try mode.write(toFile: Aevon.probePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// SpringBoard side. The file is deleted before the dump, so a failed run
    /// cannot leave a landmine that fires on every boot.
    @discardableResult
    static func consumeRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: Aevon.probePath) else { return false }
        let mode = (try? String(contentsOfFile: Aevon.probePath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: Aevon.probePath)
        if mode.trimmingCharacters(in: .whitespacesAndNewlines) == "api" {
            runSurface()
        } else {
            run()
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
    private static let surfaceNeedles = [
        "init", "scene", "Scene", "handle", "Handle", "present", "Present",
        "activat", "Activat", "layer", "Layer", "view", "View",
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
