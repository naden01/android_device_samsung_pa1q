#!/bin/bash
# Auto-apply device-tree patches to the TWRP source tree at lunch time.
# Runs once per lunch; idempotent (won't double-apply).

DEVICE_PATH="device/samsung/pa1q"
TWRP_ROOT="bootable/recovery"

# WIP78: fast freeze-free /data size refresh
PATCH_DATA_SIZE="$DEVICE_PATH/patches/0001-fast-data-size.patch"
# WIP82: format data pre-teardown (umount /sdcard + dmctl delete userdata)
PATCH_FORMAT_TEARDOWN="$DEVICE_PATH/patches/0002-format-pre-teardown.patch"
# WIP85: restore with metadata re-encryption (writes through dm-default-key layer)
PATCH_RESTORE_METADATA="$DEVICE_PATH/patches/0003-restore-metadata-encrypt.patch"
# WIP97: restore /metadata before /data (metadata-encryption key dependency)
PATCH_RESTORE_METADATA_FIRST="$DEVICE_PATH/patches/0004-restore-metadata-first.patch"
# WIP107(redo): inject live FBE key ids into libtar policy maps (native policy backup/restore)
PATCH_FSCRYPT_INJECT="$DEVICE_PATH/patches/0005-fscrypt-inject-maps.patch"
# WIP110: staged FBE-key preload during restore (extract key material + de_keyinstall per layer
# BEFORE the full extract, so the keyring is populated when libtar applies fscrypt policies)
PATCH_STAGED_RESTORE="$DEVICE_PATH/patches/0006-staged-fbe-restore.patch"
# WIP112: lockscreen PIN/password for restore (GUI prompt + passthrough to de_keyinstall) and
# backup gate (refuse /data backup while the CE layer is still locked)
PATCH_FBE_PIN="$DEVICE_PATH/patches/0007-fbe-restore-pin.patch"
PATCH_FBE_PIN_THEME="$DEVICE_PATH/patches/0008-fbe-restore-pin-theme.patch"

apply_patch() {
    local patch="$1"
    local target="$2"
    local marker="$3"

    if [ ! -f "$patch" ]; then
        echo "❌ FATAL: Patch not found: $patch"
        echo "========================================"
        echo "  BUILD FAILED: Required patch missing"
        echo "  This build MUST NOT be released!"
        echo "========================================"
        exit 1
    fi

    # Check if already applied via THIS patch's unique marker. Must be per-patch:
    # several patches share a target file (partitionmanager.cpp <- 0002 AND 0004), so a
    # combined grep would see another patch's marker and wrongly skip this one.
    if [ -n "$marker" ] && grep -q "$marker" "$target" 2>/dev/null; then
        echo "✓ Patch already applied: $patch"
        return
    fi

    echo "Applying patch: $patch -> $target"
    if patch -p1 -d "$TWRP_ROOT" -N --dry-run < "$patch" >/dev/null 2>&1; then
        patch -p1 -d "$TWRP_ROOT" -N < "$patch"
        if [ $? -eq 0 ]; then
            echo "  ✓ Applied successfully"
        else
            echo "❌ FATAL: Patch application failed: $patch"
            echo "========================================"
            echo "  BUILD FAILED: Critical patch error"
            echo "  This build MUST NOT be released!"
            echo "========================================"
            exit 1
        fi
    else
        echo "❌ FATAL: Patch dry-run failed: $patch"
        echo "========================================"
        echo "  BUILD FAILED: Patch conflicts detected"
        echo "  File: $target"
        echo "  This build MUST NOT be released!"
        echo "========================================"
        echo ""
        echo "Detailed error:"
        patch -p1 -d "$TWRP_ROOT" -N --dry-run < "$patch" 2>&1 | head -20
        exit 1
    fi
}

# Only run if the TWRP source tree exists (we're in a TWRP build environment)
if [ -d "$TWRP_ROOT" ]; then
    echo "pa1q: Applying TWRP patches..."
    apply_patch "$PATCH_DATA_SIZE" "$TWRP_ROOT/partitions.hpp" "Update_Data_Size_Fast"
    apply_patch "$PATCH_FORMAT_TEARDOWN" "$TWRP_ROOT/partitionmanager.cpp" "format_pre\.sh"
    apply_patch "$PATCH_RESTORE_METADATA" "$TWRP_ROOT/partition.cpp" "WIP85.*Pre-restore hook"
    apply_patch "$PATCH_RESTORE_METADATA_FIRST" "$TWRP_ROOT/partitionmanager.cpp" "WIP97:partitionmanager\.cpp"
    apply_patch "$PATCH_FSCRYPT_INJECT" "$TWRP_ROOT/partition.cpp" "inject_fbe_maps"
    apply_patch "$PATCH_STAGED_RESTORE" "$TWRP_ROOT/partition.cpp" "WIP110"
    apply_patch "$PATCH_FBE_PIN" "$TWRP_ROOT/partition.cpp" "WIP112"
    apply_patch "$PATCH_FBE_PIN_THEME" "$TWRP_ROOT/gui/theme/common/portrait.xml" "fbe_restore_pin"
else
    echo "pa1q: TWRP source not found, skipping patches"
fi
