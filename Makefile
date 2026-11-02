export TARGET := iphone:clang:16.5:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Aevon
Aevon_FILES := Sources/Aevon.mm
Aevon_CFLAGS := -fobjc-arc -Wall -DAEVON_STAGE=0
Aevon_FRAMEWORKS := Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------------------------------------------------------------------
# Preference bundle.
#
# We do NOT link Preferences.framework: PSListController is declared in
# AevonPrefs.mm and resolved at runtime inside the Settings process, which
# already has the framework loaded. Fewer link-time dependencies, fewer ways
# for the bundle to fail to load.
# ---------------------------------------------------------------------------
BUNDLE_NAME := AevonPrefs
AevonPrefs_FILES := Sources/AevonPrefs/AevonPrefs.mm
AevonPrefs_INSTALL_PATH := /Library/PreferenceBundles
AevonPrefs_CFLAGS := -fobjc-arc -Wall -I$(THEOS_PROJECT_DIR)/Sources
AevonPrefs_FRAMEWORKS := Foundation UIKit

include $(THEOS_MAKE_PATH)/bundle.mk

# Settings caches bundles aggressively; this only runs on `make install`.
after-install::
	install.exec "killall -9 Preferences" || true
