#!/bin/bash
# pa1q device tree - apply TWRP source patches at build time.
#
# Called from vendorsetup.sh (which `. build/envsetup.sh` sources automatically,
# locally AND on the official Jenkins builder). Applies the patches under this
# directory to bootable/recovery BEFORE compilation.
#
# SAFETY: this NEVER fails the build. If a patch is already applied it is skipped;
# if it cannot be applied (upstream drift) it is WARNed and skipped, and the build
# continues WITHOUT the fix rather than aborting. On the frozen twrp-12.1 manifest
# the context is stable so it applies cleanly; the guards are belt-and-suspenders.
#
# REVERT (local, after a build): run patches/revert-patches.sh - it restores the
# touched files to pristine via `git checkout` (bootable/recovery is a git project
# in a repo tree). On Jenkins no revert is needed: every job is a fresh clone.

# Resolve the Android build top. vendorsetup.sh lives at
# <TOP>/device/samsung/pa1q/vendorsetup.sh, so this script is three dirs deep + /patches.
_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -n "$ANDROID_BUILD_TOP" ] && [ -d "$ANDROID_BUILD_TOP/bootable/recovery" ]; then
    TOP="$ANDROID_BUILD_TOP"
else
    # patches dir is <TOP>/device/samsung/pa1q/patches -> go up 4
    TOP="$(cd "$_SELF/../../../.." && pwd)"
fi
REC="$TOP/bootable/recovery"

if [ ! -d "$REC" ]; then
    echo "pa1q-patch: WARN bootable/recovery not found at '$REC' - skipping (build continues)"
    return 0 2>/dev/null || exit 0
fi

for patch in "$_SELF"/*.patch; do
    [ -e "$patch" ] || continue
    name="$(basename "$patch")"

    # 1) idempotency: each patch carries a UNIQUE marker string that, once present
    #    in bootable/recovery, means it is already applied -> skip. Keyed per-patch
    #    (not one global grep) so a second patch is not skipped just because the
    #    first one is in. marker = "<grep target>:<file under $REC to grep>".
    case "$name" in
        0001-fast-data-size.patch)      marker="Update_Data_Size_Fast:partitionmanager.cpp" ;;
        0002-format-pre-teardown.patch) marker="format_pre.sh:partitionmanager.cpp" ;;
        0003-restore-metadata-encrypt.patch) marker="WIP85:partition.cpp" ;;
        0004-restore-metadata-first.patch) marker="WIP97:partitionmanager.cpp" ;;
        0005-fscrypt-inject-maps.patch)  marker="inject_fbe_maps:partition.cpp" ;;
        0006-staged-fbe-restore.patch)   marker="WIP110:partition.cpp" ;;
        *)                              marker="" ;;
    esac
    if [ -n "$marker" ]; then
        mtext="${marker%%:*}"; mfile="${marker##*:}"
        if grep -rq "$mtext" "$REC/$mfile" 2>/dev/null; then
            echo "pa1q-patch: '$name' already applied - skipping"
            continue
        fi
    fi

    # 2) preferred: git apply (clean, exact). --recount ignores the @@ line counts and
    #    recomputes them from the hunk body, so a hand-edited patch with imperfect counts
    #    still applies as long as the context lines match. --check first so a bad patch
    #    never half-applies.
    if command -v git >/dev/null 2>&1 && git -C "$REC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if git -C "$REC" apply --recount --check "$patch" >/dev/null 2>&1; then
            git -C "$REC" apply --recount "$patch" && { echo "pa1q-patch: '$name' applied (git apply)"; continue; }
        fi
    fi

    # 3) fallback: patch(1) with fuzz - tolerates whitespace/context drift.
    if command -v patch >/dev/null 2>&1; then
        if patch -p1 -d "$REC" --fuzz=3 --forward --dry-run < "$patch" >/dev/null 2>&1; then
            patch -p1 -d "$REC" --fuzz=3 --forward < "$patch" >/dev/null 2>&1 \
                && { echo "pa1q-patch: '$name' applied (patch --fuzz)"; continue; }
        fi
    fi

    # 4) could not apply - WARN, do NOT fail the build.
    echo "pa1q-patch: WARN could not apply '$name' (upstream drift?) - building WITHOUT this fix"
done

return 0 2>/dev/null || exit 0
