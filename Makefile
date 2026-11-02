export TARGET := iphone:clang:16.5:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Aevon
Aevon_FILES := Sources/Aevon.mm
Aevon_CFLAGS := -fobjc-arc -Wall -DAEVON_STAGE=0
Aevon_FRAMEWORKS := Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
