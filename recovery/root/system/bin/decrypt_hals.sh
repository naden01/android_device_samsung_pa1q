#!/system/bin/sh
# Bring up the Android-16 vendor security HALs (qseecomd, KeyMint, Gatekeeper)
# inside the Android-12-based TWRP so /data (FBE v2 + metadata enc, HW-wrapped
# keys) can be decrypted. The HAL binaries are Android 16; running them on
# TWRP's own A12 libs fails on ABI/namespace. So we run them with the matching
# A16 libs+linker taken from the real (mounted) system and vendor partitions,
# launched through the bootstrap dynamic linker with an explicit library path,
# which sidesteps the vendor linker-namespace restriction.

LOG=/tmp/decrypt_hals.log
exec >>"$LOG" 2>&1
echo "===== decrypt_hals start ====="

SYS=/mnt/system_real
mkdir -p "$SYS" 2>/dev/null

# Locate the real A16 system partition (logical/super). TWRP maps these under
# /dev/block/mapper. Try the active slot first, then the bare name.
if [ ! -e "$SYS/bin/bootstrap/linker64" ]; then
    for src in /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system; do
        [ -e "$src" ] || continue
        mount -o ro "$src" "$SYS" 2>/dev/null && echo "mounted real system from $src" && break
    done
fi

LINKER="$SYS/bin/bootstrap/linker64"
if [ ! -e "$LINKER" ]; then
    echo "FATAL: A16 bootstrap linker not found at $LINKER (real system not mounted?)"
    echo "mapper devices:"; ls -la /dev/block/mapper/ 2>/dev/null
    exit 1
fi

# A16 libs: bootstrap bionic first, then real system, then the (already mounted)
# A16 vendor partition. This is the matching ABI set, isolated from TWRP's libs.
LIBS="$SYS/lib64/bootstrap:$SYS/lib64:$SYS/lib64/vndk-sp:/vendor/lib64:/vendor/lib64/hw"
export ANDROID_DATA=/data
export ANDROID_ROOT=/system

start_hal() {
    bin="$1"; name="$2"
    if [ ! -e "$bin" ]; then echo "skip $name: $bin missing"; return; fi
    LD_LIBRARY_PATH="$LIBS" "$LINKER" "$bin" &
    echo "started $name ($bin) pid $!"
}

# KeyMint reads provisioning (DAK keybox) from /mnt/vendor/efs; persist holds
# device data. Best-effort, read-only - missing/empty is non-fatal for decrypt.
mount_byname() {
    name="$1"; dst="$2"
    [ -d "$dst" ] || mkdir -p "$dst" 2>/dev/null
    for src in /dev/block/by-name/$name /dev/block/bootdevice/by-name/$name \
               /dev/block/platform/soc/1d84000.ufshc/by-name/$name; do
        [ -e "$src" ] || continue
        mount -o ro "$src" "$dst" 2>/dev/null && echo "mounted $name -> $dst" && return
    done
    echo "note: could not mount $name"
}
mount_byname efs /mnt/vendor/efs
mount_byname persist /mnt/vendor/persist

# qseecomd first: it bootstraps the TEE / loads trustlets that KeyMint needs.
start_hal /vendor/bin/qseecomd qseecomd
sleep 1
start_hal /vendor/bin/hw/android.hardware.gatekeeper-service gatekeeper
start_hal /vendor/bin/hw/android.hardware.security.keymint-service keymint

sleep 2
echo "----- running procs -----"
ps -A 2>/dev/null | grep -iE "qseecomd|keymint|gatekeeper" | grep -v grep
echo "===== decrypt_hals done ====="
