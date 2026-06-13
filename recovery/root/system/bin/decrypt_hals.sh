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
# /dev/block/mapper. The partition is erofs and `mount` will NOT auto-probe it,
# so the fs type is given explicitly (fallback to ext4/f2fs for other builds).
# NOTE: the mounted tree is a full root container - its top-level `bin`/`etc`
# are absolute symlinks into /system, so the real A16 payload lives one level
# down under system/ (system/bin/bootstrap/linker64, system/lib64/...).
if [ ! -e "$SYS/system/bin/bootstrap/linker64" ]; then
    for src in /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system; do
        [ -e "$src" ] || continue
        for t in erofs ext4 f2fs; do
            mount -t "$t" -o ro "$src" "$SYS" 2>/dev/null && \
                echo "mounted real system from $src ($t)" && break 2
        done
    done
fi

LINKER="$SYS/system/bin/bootstrap/linker64"
if [ ! -e "$LINKER" ]; then
    echo "FATAL: A16 bootstrap linker not found at $LINKER (real system not mounted?)"
    echo "mapper devices:"; ls -la /dev/block/mapper/ 2>/dev/null
    echo "contents of $SYS:"; ls -la "$SYS" 2>/dev/null
    exit 1
fi

# A16 libs: bootstrap bionic first, then real system, then the (already mounted)
# A16 vendor partition. This is the matching ABI set, isolated from TWRP's libs.
LIBS="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"
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

# --- readiness gate -------------------------------------------------------
# init (post-fs) blocks on this script via exec_start, so we must RETURN, not
# hang. Wait (bounded) until KeyMint is up and stable, publish twrp.keymint.ready,
# then exit. The backgrounded HALs above keep running after we return. On timeout
# we still publish ready=0 so init proceeds and TWRP boots (just without decrypt)
# instead of hanging on the logo.
KM_RE="android.hardware.security.keymint|keymint"
ready=0
stable=0
i=0
while [ "$i" -lt 20 ]; do          # up to ~10s (20 * 0.5s)
    if [ -x /system/bin/service ]; then
        # Strong signal: KeyMint AIDL instance actually registered with servicemanager
        if /system/bin/service check android.hardware.security.keymint.IKeyMintDevice/default 2>/dev/null | grep -q ": found"; then
            ready=1; break
        fi
    else
        # Fallback (no `service` tool in image): process alive and stable for 3 checks
        if ps -A 2>/dev/null | grep -iE "$KM_RE" | grep -qv grep; then
            stable=$((stable + 1))
            [ "$stable" -ge 3 ] && { ready=1; break; }
        else
            stable=0
        fi
    fi
    i=$((i + 1))
    sleep 0.5
done
setprop twrp.keymint.ready "$ready"

echo "----- running procs -----"
ps -A 2>/dev/null | grep -iE "qseecomd|keymint|gatekeeper" | grep -v grep
if [ -x /system/bin/service ]; then km_check=aidl; else km_check=proc-stable; fi
echo "keymint readiness=$ready waited=$((i * 500))ms check=$km_check"
echo "===== decrypt_hals done ====="
