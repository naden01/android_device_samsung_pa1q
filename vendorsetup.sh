#!/bin/bash
# Auto-apply device-tree patches to the TWRP source tree at lunch time.
# Runs once per lunch; idempotent (won't double-apply).

# ── OrangeFox build-environment variables ─────────────────────────────────────
# Sourced by breakfast → read by OrangeFox_A12.sh → passed as -D flags to clang.
export OF_SCREEN_H=2340                     # S25 FHD+ 2340×1080
export OF_STATUS_H=72
export OF_MAINTAINER="Jamie_Naden_Maxim_Archer_Ahmed_Carlo | pa1q"
export FOX_MAINTAINER_PATCH_VERSION="0"
export OF_FLASHLIGHT_ENABLE=1
export OF_FL_PATH1="/sys/devices/virtual/camera/flash/rear_flash"
export TARGET_DEVICE_ALT="pa1q"
export OF_ENABLE_LPTOOLS=1
export OF_USE_LEGACY_BATTERY_SERVICES=1
export OF_SUPPORT_OZIP_DECRYPTION=1
export OF_ALLOW_DISABLE_NAVBAR=1
export OF_DEFAULT_TIMEZONE="CET-1;CEST,M3.5.0,M10.5.0"
# S25 (API 36) - bypass OrangeFox HIDL FBE stack (crashes before display init)
export OF_SKIP_FBE_DECRYPTION_SDKVERSION=36
export ALLOW_MISSING_DEPENDANCIES=true
export FOX_USE_SAMSUNG_SPECIAL=1
export FOX_VANILLA_BUILD=1
export FOX_VENDOR_BOOT_RECOVERY=1
# ──────────────────────────────────────────────────────────────────────────────


