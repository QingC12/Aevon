# ---------------------------------------------------------------------------
# Aevon — roothide, arm64e only, Swift.
#
# Everything that "must never change again" is pinned here rather than in CI,
# so a future edit cannot silently reintroduce an arm64 slice or a rootless
# layout:
#
#   ARCHS = arm64e            A12 and newer. No arm64 slice is ever produced.
#   THEOS_PACKAGE_SCHEME      roothide: bootstrap lives in .jbroot-XXXXXXXX,
#                             packages install to plain /Library and /usr.
#   FINALPACKAGE=1            strip + optimise. CI always passes it.
# ---------------------------------------------------------------------------
export TARGET := iphone:clang:16.5:15.0
export ARCHS := arm64e
export THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

# Shared, platform-free core. The same files are compiled into both
# binaries, so SpringBoard and Settings can never disagree about paths/gates.
# 0.0.42 joins the old plugin's quick actions (screenshot / recording) to the
# core, because the disc's two action slots live in the editor and the menu —
# both binaries — and AevonCompat is the seam layer the ported files call into.
AE_CORE := Sources/Core/Paths.swift Sources/Core/Log.swift Sources/Core/Gate.swift \
           Sources/Core/CardLayout.swift Sources/Core/AevonMotion.swift \
           Sources/Core/AevonCompat.swift Sources/Core/AevonQuickAction.swift \
           Sources/Core/AevonRecProbe.swift

# The disc is the archived plugin's implementation, moved over 1:1 in 0.0.42
# (AevonRingMenu + keyframes + unfold + spring + store) and compiled into BOTH
# binaries: the settings preview and the home-screen host must render the same
# shape from the same code, or "it looks different on the desktop" becomes
# unfalsifiable. RingModel keeps only the cross-process config plumbing;
# RingIcons is still the catalogue/icon source both sides share.
AE_RING := Sources/Ring/RingModel.swift Sources/Ring/RingIcons.swift \
           Sources/Ring/AevonRingStore.swift Sources/Ring/AevonRingMenu.swift \
           Sources/Ring/AevonHoverKeyframes.swift Sources/Ring/AevonRingUnfold.swift \
           Sources/Ring/AevonSpring.swift

# ---------------------------------------------------------------------------
# SpringBoard tweak. One C file (the load-time constructor Swift cannot
# declare), the rest Swift.
# ---------------------------------------------------------------------------
TWEAK_NAME := Aevon AevonApp
Aevon_FILES := Sources/AevonBoot.m Sources/AevonScene.m Sources/Boot.swift $(AE_CORE) $(AE_RING) \
               Sources/Ring/RingHost.swift Sources/Ring/AevonAppPanel.swift \
               Sources/Scene/SceneProbe.swift \
               Sources/Scene/FloatHost.swift
Aevon_FRAMEWORKS := Foundation UIKit ReplayKit Photos AVFoundation AudioToolbox
# Swift metadata is the bulk of a Swift dylib; dead-strip keeps it honest.
# `-x` drops the local symbol table at link time. A Swift object carries one
# mangled name per declaration (`_$s5Aevon...`), and those names are pure weight
# in an injected library nothing debugs: 0.0.15 went 330,064 -> see BUILD.md.
Aevon_LDFLAGS := -Wl,-dead_strip -Wl,-x
# -Osize, not -O. The dylib sits 1.2 KB over a hard 320 KB budget and the window
# build needs that room. This trades a little speed for bytes, which is the right
# way round for code that runs once per button press. Deleting source does not
# help: 46 lines came out in 0.0.14 and the file shrank by 64 bytes, because the
# weight is type metadata, not instructions.
Aevon_SWIFTFLAGS := -Osize

# ---------------------------------------------------------------------------
# App-side bridge (0.0.44). A second injection point, deliberately separate:
#
#   Aevon     → SpringBoard only (Aevon.plist) — the host, the card, the disc
#   AevonApp  → every process that loads UIKit (AevonApp.plist) — the state
#               bridge that makes a hosted app accept the touches the card
#               forwards to it
#
# Splitting them is not tidiness. The SpringBoard binary carries the scene
# machinery, the disc and the preference reader; loading that into 250 app
# processes would multiply the resident cost of the tweak by 250 and give every
# app a second chance to run SpringBoard-only code. This one is 200 lines of
# ObjC with no Swift runtime behind it, which is the only shape that is fair to
# load everywhere.
# ---------------------------------------------------------------------------
AevonApp_FILES := Sources/App/AevonAppHook.m
AevonApp_FRAMEWORKS := Foundation UIKit
AevonApp_LDFLAGS := -Wl,-dead_strip -Wl,-x

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------------------------------------------------------------------
# Preference bundle (Swift).
#
# PSListController lives in Preferences.framework, which is already loaded in
# the Settings process. It is declared in AevonPrefs-Bridging-Header.h and
# resolved at runtime, so the bundle is linked with dynamic_lookup instead of
# adding an install-time dependency on the framework.
# ---------------------------------------------------------------------------
BUNDLE_NAME := AevonPrefs

AevonPrefs_FILES := $(AE_CORE) $(AE_RING) \
                    Sources/Ring/RingPreviewController.swift \
                    Sources/Prefs/RingActions.swift \
                    Sources/Prefs/SceneActions.swift \
                    Sources/Prefs/AppListController.swift \
                    Sources/Prefs/AppPickerController.swift \
                    Sources/Prefs/PanelController.swift \
                    Sources/Prefs/RootListController.swift
AevonPrefs_INSTALL_PATH := /Library/PreferenceBundles
AevonPrefs_FRAMEWORKS := Foundation UIKit ReplayKit Photos AVFoundation AudioToolbox
AevonPrefs_LDFLAGS := -Wl,-undefined,dynamic_lookup -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/bundle.mk

# Settings caches the entry list per process; this only runs on `make install`.
after-install::
	install.exec "killall -9 Preferences" || true
