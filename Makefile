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

# Shared, platform-free core. The same three files are compiled into both
# binaries, so SpringBoard and Settings can never disagree about paths/gates.
AE_CORE := Sources/Core/Paths.swift Sources/Core/Log.swift Sources/Core/Gate.swift \
           Sources/Core/GripLayout.swift

# The ring's model + icons + view are compiled into BOTH binaries on purpose:
# the settings preview and the home-screen host must render the same shape from
# the same numbers, or "it looks different on the desktop" becomes
# unfalsifiable.
#
# RingApps joins them in 0.1.0: the icon list is written by Settings and read by
# SpringBoard, and both sides have to resolve it the same way.
AE_RING := Sources/Ring/RingModel.swift Sources/Ring/RingIcons.swift \
           Sources/Ring/RingApps.swift Sources/Ring/RingView.swift

# ---------------------------------------------------------------------------
# SpringBoard tweak. One C file (the load-time constructor Swift cannot
# declare), the rest Swift.
# ---------------------------------------------------------------------------
TWEAK_NAME := Aevon
Aevon_FILES := Sources/AevonBoot.m Sources/Boot.swift $(AE_CORE) $(AE_RING) \
               Sources/Ring/RingHost.swift Sources/Scene/SceneProbe.swift
Aevon_FRAMEWORKS := Foundation UIKit
# Swift metadata is the bulk of a Swift dylib; dead-strip keeps it honest.
Aevon_LDFLAGS := -Wl,-dead_strip

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
AevonPrefs_FRAMEWORKS := Foundation UIKit
AevonPrefs_LDFLAGS := -Wl,-undefined,dynamic_lookup -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/bundle.mk

# Settings caches the entry list per process; this only runs on `make install`.
after-install::
	install.exec "killall -9 Preferences" || true
