TARGET := iphone:clang:16.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTBypass

YTBypass_FILES = Tweak.xm AdBlock.xm
YTBypass_CFLAGS = -fobjc-arc
YTBypass_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
