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
    static func request() -> Bool {
        try? FileManager.default.createDirectory(atPath: Aevon.stateDir,
                                                 withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        do {
            try stamp.write(toFile: Aevon.probePath, atomically: true, encoding: .utf8)
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
        try? FileManager.default.removeItem(atPath: Aevon.probePath)
        run()
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
        var hits: [String] = []
        for name in probeResponses where object.responds(to: NSSelectorFromString(name)) {
            hits.append(name)
        }
        return "[" + hits.joined(separator: ",") + "]"
    }
}
