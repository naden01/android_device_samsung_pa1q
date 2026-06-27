# Orangefox Flags
export ALLOW_MISSING_DEPENDANCIES=true
export TARGET_ARCH=arm64
export OF_FLASHLIGHT_ENABLE=1
export OF_FL_PATH1="/sys/devices/virtual/camera/flash/rear_flash"
export OF_MAINTAINER="Jamie_Naden_Maxim_Archer_Ahmed_Carlo | pa2q"
export TARGET_DEVICE_ALT="pa2q"
export OF_ENABLE_LPTOOLS=1
export OF_USE_LEGACY_BATTERY_SERVICES=1
export OF_SCREEN_H=3120
export FOX_MAINTAINER_PATCH_VERSION="0"

DEVICE_PATH="device/samsung/pa1q"
TWRP_ROOT="bootable/recovery"

# WIP78: fast freeze-free /data size refresh
PATCH_DATA_SIZE="$DEVICE_PATH/patches/0001-fast-data-size.patch"
# WIP85: restore with metadata re-encryption (writes through dm-default-key layer)
PATCH_RESTORE_METADATA="$DEVICE_PATH/patches/0002-restore-metadata-encrypt.patch"

apply_patch() {
    local patch="$1"
    local target="$2"

    if [ ! -f "$patch" ]; then
        echo "Patch not found: $patch (skipping)"
        return
    fi

    # Check if already applied (look for a marker line from the patch in the target file)
    if grep -q "WIP78.*refreshdatasz\|WIP85.*Pre-restore hook" "$target" 2>/dev/null; then
        echo "Patch already applied: $patch"
        return
    fi

    echo "Applying patch: $patch -> $target"
    if patch -p1 -d "$TWRP_ROOT" -N --dry-run < "$patch" >/dev/null 2>&1; then
        patch -p1 -d "$TWRP_ROOT" -N < "$patch"
        echo "  ✓ Applied successfully"
    else
        echo "  ⚠ Patch failed to apply (may already be applied or conflict)"
    fi
}

# Only run if the TWRP source tree exists (we're in a TWRP build environment)
if [ -d "$TWRP_ROOT" ]; then
    echo "pa1q: Applying TWRP patches..."
    apply_patch "$PATCH_DATA_SIZE" "$TWRP_ROOT/gui/action.cpp"
    apply_patch "$PATCH_RESTORE_METADATA" "$TWRP_ROOT/partition.cpp"
else
    echo "pa1q: TWRP source not found, skipping patches"
fi
