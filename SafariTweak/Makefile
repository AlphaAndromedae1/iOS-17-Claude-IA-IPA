# Theos build for the Safari tweak. Needs Theos (https://theos.dev) and THEOS set; from this folder:
#   make package FINALPACKAGE=1        (gmake on macOS)
TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless
INSTALL_TARGET_PROCESSES := MobileSafari SafariViewService

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := ClaudeWebSafariFix
ClaudeWebSafariFix_FILES := Tweak.x
ClaudeWebSafariFix_CFLAGS := -fobjc-arc
ClaudeWebSafariFix_FRAMEWORKS := Foundation WebKit

include $(THEOS_MAKE_PATH)/tweak.mk

# The fix itself is Shared/style-fix.js, the same file the app uses; it's compiled into the tweak.
before-all::
	python3 ../scripts/embed-js.py ../Shared/style-fix.js StyleFixJS.h
