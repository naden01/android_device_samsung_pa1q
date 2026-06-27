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
PATCH_RESTORE_METADATA="$DEVICE_PATH/patches/0002-restore-metadata-encrypt.patch"

apply_patch() {
    local patch="$1"
    local target="$2"

    if [ ! -f "$patch" ]; then
        echo "❌ FATAL: Patch not found: $patch"
        echo "========================================"
        echo "  BUILD FAILED: Required patch missing"
        echo "  This build MUST NOT be released!"
        echo "========================================"
        exit 1
    fi

    # Check if already applied (look for a marker line from the patch in the target file)
    if grep -q "WIP78.*refreshdatasz\|WIP82.*format_pre\.sh\|WIP85.*Pre-restore hook" "$target" 2>/dev/null; then
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
    apply_patch "$PATCH_DATA_SIZE" "$TWRP_ROOT/partitions.hpp"
    apply_patch "$PATCH_FORMAT_TEARDOWN" "$TWRP_ROOT/partitionmanager.cpp"
    apply_patch "$PATCH_RESTORE_METADATA" "$TWRP_ROOT/partition.cpp"
else
    echo "pa1q: TWRP source not found, skipping patches"
fi
