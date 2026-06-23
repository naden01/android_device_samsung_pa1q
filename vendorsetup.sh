# Orangefox Flags
export ALLOW_MISSING_DEPENDANCIES=true
export TARGET_ARCH=arm64
export OF_FLASHLIGHT_ENABLE=1
export OF_FL_PATH1="/sys/devices/virtual/camera/flash/rear_flash"
export OF_MAINTAINER="Jamie_Naden_Maxim_Archer_Ahmed_Carlo | pa3q"
export TARGET_DEVICE_ALT="pa3q"
export OF_ENABLE_LPTOOLS=1
export OF_USE_LEGACY_BATTERY_SERVICES=1
export OF_SCREEN_H=2340
export FOX_MAINTAINER_PATCH_VERSION="0"

# Apply our TWRP source patches at build time (safe: never fails the build; see
# patches/apply-patches.sh). Sourced so it sees ANDROID_BUILD_TOP from envsetup.
if [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/patches/apply-patches.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]:-$0}")/patches/apply-patches.sh"
fi
