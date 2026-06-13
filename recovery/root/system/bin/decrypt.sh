#!/system/bin/sh
# Decrypt /data on the Android-12 TWRP base by running the FULL Android-16 security
# stack from the mounted firmware dump - all ONE version, so keystore2 <-> KeyMint
# actually work (the wall on A12 was: A16 KeyMint can't register in the A12
# servicemanager). Proven live on 2026-06-13: keystore2 connected to KeyMint with
# no NAME_NOT_FOUND panic. This bakes those exact steps + the A16 vold driver.
#
# Trigger on-demand once TWRP is up:  setprop twrp.decrypt.run 1
#
# Order: mount dump -> VINTF overlay -> stop A12 sm/keystore2 -> start A16
# servicemanager + qseecomd + KeyMint + keystore2 + vold (init services below,
# which create the sockets these daemons need) -> drive the metadata decrypt via
# the matched A16 vdc.
LOG=/tmp/decrypt.log
exec >>"$LOG" 2>&1
echo "===== decrypt start (uptime $(cat /proc/uptime 2>/dev/null)) ====="

SYS=/decrypt
LK="$SYS/system/bin/bootstrap/linker64"
LIBS="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"

# Run an A16 CLI tool via the bootstrap linker. LD_LIBRARY_PATH is scoped to the
# subshell/exec ONLY - if any A12 toybox (timeout, sh, logcat) inherits the A16 lib
# path it loads a mismatched A16 libc++ and SIGSEGVs (this exact bug made vdc/service
# "segfault"; they are fine without the poisoning).
lrun() { ( export LD_LIBRARY_PATH="$LIBS" ANDROID_DATA=/data ANDROID_ROOT=/system; exec "$LK" "$@" ); }

# 0. wait (bounded) for TWRP to map the super partitions. This now auto-runs at
#    boot, so system_a/vendor_a may not exist yet when it first fires.
n=0
while [ "$n" -lt 80 ]; do
    [ -e /dev/block/mapper/system_a ] && [ -e /dev/block/mapper/vendor_a ] && break
    n=$((n + 1)); sleep 0.5
done
echo "mapper wait ~$((n * 500))ms (system_a=$([ -e /dev/block/mapper/system_a ] && echo y || echo n) vendor_a=$([ -e /dev/block/mapper/vendor_a ] && echo y || echo n))"
# let the TWRP GUI finish its own startup before we stop the A12 servicemanager
# (we swap in the A16 one) so the swap does not race TWRP's init.
sleep 3

# 1. mount the real A16 system + vendor (idempotent)
if [ ! -e "$LK" ]; then
    mkdir -p "$SYS" 2>/dev/null
    for s in /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system; do
        [ -e "$s" ] && mount -t erofs -o ro "$s" "$SYS" 2>/dev/null && break
    done
fi
if [ ! -e /vendor/bin/qseecomd ]; then
    for v in /dev/block/mapper/vendor_a /dev/block/mapper/vendor_b /dev/block/mapper/vendor; do
        [ -e "$v" ] && mount -t erofs -o ro "$v" /vendor 2>/dev/null && break
    done
fi
echo "linker=$([ -e "$LK" ] && echo ok || echo MISS) vendor=$([ -e /vendor/bin/qseecomd ] && echo ok || echo MISS)"

# 2. VINTF overlay: the A16 servicemanager returns "NULL VINTF MANIFEST" without a
#    base /vendor/etc/vintf/manifest.xml. /vendor has the real keymint fragment but
#    no base manifest, and /vendor is RO erofs -> bind a writable copy of the vintf
#    dir (keeps the real fragments) with a minimal base manifest added.
if [ ! -e /vendor/etc/vintf/manifest.xml ]; then
    rm -rf /tmp/vintf_src; mkdir -p /tmp/vintf_src
    cp -a /vendor/etc/vintf/. /tmp/vintf_src/ 2>/dev/null
    printf '%s\n' '<manifest version="8.0" type="device" />' > /tmp/vintf_src/manifest.xml
    mount --bind /tmp/vintf_src /vendor/etc/vintf && echo "vintf overlay bound"
fi

# 3. keystore2 prereqs: DB dir, and it blocks/aborts without boot_completed/apexd
mkdir -p /tmp/misc/keystore /metadata/keystore /data/vendor/keymaster 2>/dev/null
# DAK keybox provisioning KeyMint reads (from the stock keymint.rc)
mkdir -p /mnt/vendor/efs/DAK 2>/dev/null
setprop sys.boot_completed 1
setprop apexd.status activated

# 4. hand /dev/binder to the A16 servicemanager: stop the A12 one (+ A12 keystore2).
#    ctl.stop leaves them stopped (only crashes auto-restart), so the A16 sm can
#    claim the context-manager slot.
setprop ctl.stop keystore2
setprop ctl.stop servicemanager
sleep 2

# 5. bring up the matched A16 stack in order via init (services + their sockets are
#    declared in init.recovery.qcom.rc).
start_svc() { setprop ctl.start "$1"; echo "ctl.start $1"; }

start_svc decrypt-servicemanager
sleep 2
start_svc decrypt-qseecomd
n=0; while [ "$n" -lt 24 ]; do
    logcat -d -s QSEECOMD 2>/dev/null | grep -q "QSEECOM DAEMON RUNNING" && { echo "qseecomd: TEE up"; break; }
    n=$((n + 1)); sleep 0.5
done
start_svc decrypt-keymint
n=0; while [ "$n" -lt 24 ]; do
    logcat -d 2>/dev/null | grep -q "keymint-service: adding" && { echo "keymint registered"; break; }
    n=$((n + 1)); sleep 0.5
done
start_svc decrypt-keystore2
sleep 3
start_svc decrypt-vold
sleep 4

echo "----- service states -----"
for s in decrypt-servicemanager decrypt-qseecomd decrypt-keymint decrypt-keystore2 decrypt-vold; do
    echo "  init.svc.$s = $(getprop init.svc.$s)"
done
echo "----- running A16 procs -----"; ps -A 2>/dev/null | grep -iE "linker64" | grep -v grep

# 6. drive the metadata decrypt via the matched A16 vdc -> vold (IVold.mountFstab
#    runs fscrypt_mount_metadata_encrypted: KeyMint unwraps the keymaster_key_blob
#    in /metadata/vold/metadata_encryption -> dm-default-key -> mount /data).
USERDATA=$(ls /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata \
              /dev/block/platform/soc/1d84000.ufshc/by-name/userdata 2>/dev/null | head -1)
echo "----- decrypt: userdata=$USERDATA -----"
echo "[vdc cryptfs mountFstab]"; lrun "$SYS/system/bin/vdc" cryptfs mountFstab "$USERDATA" /data 2>&1
sleep 3
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "SUCCESS: /data mounted"; grep -E " /data " /proc/mounts
else
    echo "/data not mounted yet - vdc command form may need adjusting; trying volume mount"
    lrun "$SYS/system/bin/vdc" volume mount "$USERDATA" 2>&1
    sleep 2
    grep -E " /data " /proc/mounts || echo "/data still not mounted"
fi
echo "===== decrypt done ====="
