TARGET := iphone:clang:16.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = RedditApp Reddit
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedditLegacy
RedditLegacy_FILES = Tweak.x
RedditLegacy_CFLAGS = -fobjc-arc
# Log upload and all diagnostics are development only: release with make RELEASE=1.
ifneq ($(RELEASE),1)
RedditLegacy_CFLAGS += -DRL_DEV=1
else
# Logos still emits the Diagnostics hooks, which a release build never activates.
RedditLegacy_CFLAGS += -Wno-unused-function
endif
RedditLegacy_FRAMEWORKS = UIKit Foundation
# Leaves build identifiers out of the binary.
RedditLegacy_LDFLAGS = -Wl,-no_uuid,-no_source_version,-no_function_starts,-no_data_in_code_info
RedditLegacy_CODESIGN_FLAGS = -S -Itweak

include $(THEOS_MAKE_PATH)/tweak.mk
