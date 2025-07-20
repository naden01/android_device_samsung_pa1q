LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),pa2q)
include $(call all-subdir-makefiles,$(LOCAL_PATH))
endif
