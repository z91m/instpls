target = iphone:latest:14.0
ARCHS = arm64

TWEAK_NAME = instpls
instpls_FILES = Tweak.xm

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tweak.mk
