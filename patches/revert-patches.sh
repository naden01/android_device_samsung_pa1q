#!/bin/bash
# pa1q device tree - REVERT the TWRP source patches (local use, after a build).
#
# Restores the files patched by apply-patches.sh to their pristine state. Because
# bootable/recovery is a git project inside the repo tree, the cleanest and most
# reliable revert is `git checkout -- <file>` (byte-exact, no dependence on patch
# line numbers - this is the part that used to fail with `patch -R`).
#
# Run this AFTER your build (success or failure) to leave the TWRP source tree clean:
#   bash device/samsung/pa1q/patches/revert-patches.sh
#
# On Jenkins this is NOT needed - each job starts from a fresh clone.

_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -n "$ANDROID_BUILD_TOP" ] && [ -d "$ANDROID_BUILD_TOP/bootable/recovery" ]; then
    TOP="$ANDROID_BUILD_TOP"
else
    TOP="$(cd "$_SELF/../../../.." && pwd)"
fi
REC="$TOP/bootable/recovery"

# Files touched by the patches in this dir (keep in sync as patches are added):
#   0001-fast-data-size.patch          -> gui/action.cpp, partitions.hpp, partitionmanager.cpp, gui/gui.cpp
#   0002-format-pre-teardown.patch     -> partitionmanager.cpp
#   0003-restore-metadata-encrypt.patch -> partition.cpp
#   0004-restore-metadata-first.patch   -> partitionmanager.cpp
#   0005-fscrypt-inject-maps.patch      -> partition.cpp
#   0006-staged-fbe-restore.patch       -> partition.cpp, twrpTar.cpp, twrpTar.hpp
#   0007-fbe-restore-pin.patch          -> partition.cpp, gui/action.cpp, gui/objects.hpp
#   0008-fbe-restore-pin-theme.patch    -> gui/theme/common/portrait.xml
FILES="gui/action.cpp partitions.hpp partitionmanager.cpp gui/gui.cpp partition.cpp twrpTar.cpp twrpTar.hpp gui/objects.hpp gui/theme/common/portrait.xml"

if [ ! -d "$REC" ]; then
    echo "pa1q-revert: bootable/recovery not found at '$REC'"
    exit 1
fi

if ! ( command -v git >/dev/null 2>&1 && git -C "$REC" rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    echo "pa1q-revert: '$REC' is not a git work tree - cannot auto-revert."
    echo "             Re-sync it with: repo sync -l bootable/recovery   (or re-clone)."
    exit 1
fi

echo "pa1q-revert: restoring TWRP source files to pristine via git checkout..."
for f in $FILES; do
    if git -C "$REC" checkout -- "$f" 2>/dev/null; then
        echo "  ✓ reverted: bootable/recovery/$f"
    else
        echo "  ⚠ WARN: could not git-checkout '$f' (already clean, or not tracked)"
    fi
done
echo "pa1q-revert: done. Verify with: git -C \"$REC\" status"
