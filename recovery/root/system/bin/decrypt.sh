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
# Re-mount the modem/firmware partition over the A16 /vendor. init mounts apnhlos at
# /vendor/firmware_mnt on `on fs`, but we just mounted the A16 vendor OVER /vendor,
# which SHADOWS it - so KeyMint's TEE trustlet (skeymast.mbn, under
# /vendor/firmware_mnt/image/, per firmware_class.path) becomes unreachable and
# KeyMint fails to open the TEE (shared-secret ret -49). Verified live: re-mounting
# it makes the trustlet load and shared-secret succeed.
# The apnhlos by-name node can appear a beat AFTER we run (auto-start fires at ~8s
# uptime, before ueventd finishes creating it) and it is slot-suffixed
# (apnhlos_a/_b) - so wait briefly (bounded) and probe the real, slot-correct paths.
# A miss here = trustlet unreachable = KeyMint can't open the TEE = mountFstab wedges.
#
# CRITICAL - mount PERMISSIONS: vfat has no on-disk unix perms; it synthesizes them
# from uid/gid/fmask/dmask. A bare `mount -t vfat -o ro` inherits init's umask (0077),
# so skeymast.mbn lands 0700 root:root - and the Samsung keymint_tee HAL runs as user
# *system*, so it CANNOT open the TA: "Failed to open skeymast.mbn" -> nwd_tz_open
# failed -> createOperation returns -49 SECURE_HW_COMMUNICATION_FAILED -> mountFstab
# fails (fail_cause M02R). This is exactly why a hand mount (shell umask 0022) worked
# but the baked one didn't. Mount root:system, group/other-readable to match stock.
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
# Stock fstab.qcom firmware perms (root:system, files 0440) so the system-uid
# keymint_tee HAL can open the TA. Init mounts apnhlos first and owns the vfat sb;
# these opts only take effect if THIS is the first mount (init's mount failed/absent),
# since a second mount of the same device reuses the existing sb's options.
FWOPTS="ro,uid=0,gid=1000,fmask=337,dmask=227,shortname=lower"
mkdir -p /vendor/firmware_mnt 2>/dev/null
n=0
while [ ! -e /vendor/firmware_mnt/image ] && [ "$n" -lt 40 ]; do
    for fw in /dev/block/bootdevice/by-name/apnhlos"$SLOT" \
              /dev/block/bootdevice/by-name/apnhlos \
              /dev/block/by-name/apnhlos"$SLOT" \
              /dev/block/by-name/apnhlos \
              /dev/block/platform/soc/1d84000.ufshc/by-name/apnhlos"$SLOT" \
              /dev/block/platform/soc/1d84000.ufshc/by-name/apnhlos; do
        [ -e "$fw" ] && mount -t vfat -o "$FWOPTS" "$fw" /vendor/firmware_mnt 2>/dev/null && break
    done
    [ -e /vendor/firmware_mnt/image ] && break
    n=$((n + 1)); sleep 0.25
done
echo "apnhlos wait ~$((n * 250))ms slot=${SLOT:-none}"
echo "linker=$([ -e "$LK" ] && echo ok || echo MISS) vendor=$([ -e /vendor/bin/qseecomd ] && echo ok || echo MISS) trustlet=$([ -e /vendor/firmware_mnt/image/skeymast.mbn ] && echo ok || echo MISS)"

# 2. VINTF overlay: the A16 servicemanager returns "NULL VINTF MANIFEST" without a
#    base /vendor/etc/vintf/manifest.xml. /vendor has the real keymint fragment but
#    no base manifest, and /vendor is RO erofs -> bind a writable copy of the vintf
#    dir (keeps the real fragments) with a minimal base manifest added.
if [ ! -e /vendor/etc/vintf/manifest.xml ]; then
    rm -rf /tmp/vintf_src; mkdir -p /tmp/vintf_src
    cp -a /vendor/etc/vintf/. /tmp/vintf_src/ 2>/dev/null
    printf '%s\n' '<manifest version="8.0" type="device" />' > /tmp/vintf_src/manifest.xml
    # Strip the StrongBox KeyMint declaration. StrongBox is a discrete secure element
    # (Samsung SPU) that is NOT powered/available in recovery, so IKeyMintDevice/strongbox
    # never registers. While it stays DECLARED in VINTF, keystore2 at startup iterates it,
    # fails to get the device (NAME_NOT_FOUND), and treats that as FATAL: "Terminating due
    # to KeyMint not accepting module info, blocking boot" -> SIGABRT crash-loop ->
    # vold.mountFstab wedges forever. Undeclaring it makes keystore2 skip StrongBox (as on
    # TEE-only devices). The metadata key is TEE (TRUSTED_ENVIRONMENT), which works - so
    # StrongBox is not needed for the decrypt, and it cannot work in recovery anyway.
    rm -f /tmp/vintf_src/manifest/strongbox_qc_km_v300_manifest.xml
    for f in /tmp/vintf_src/manifest/*.xml; do
        [ -e "$f" ] || continue
        grep -q '<instance>strongbox</instance>' "$f" 2>/dev/null \
            && grep -qi keymint "$f" 2>/dev/null && rm -f "$f"
    done
    mount --bind /tmp/vintf_src /vendor/etc/vintf && echo "vintf overlay bound (strongbox stripped)"
fi

# 3. keystore2 prereqs: DB dir, and it blocks/aborts without boot_completed/apexd
mkdir -p /tmp/misc/keystore /metadata/keystore /data/vendor/keymaster 2>/dev/null
# DAK keybox provisioning KeyMint reads (from the stock keymint.rc)
mkdir -p /mnt/vendor/efs/DAK 2>/dev/null
setprop sys.boot_completed 1
setprop apexd.status activated

# 3a. version props the A16 stack reads - set BEFORE KeyMint/vold start (KeyMint reads
#     the OS version at init, vold reads ro.crypto at mountFstab). These are write-once
#     ro. props, so use resetprop to force them in place. Verified live 2026-06-14.
RP=/system/bin/resetprop
# anti-rollback: the /data metadata key was created under Android 16 (key os_version
# 160000). KeyMint's TA refuses a key NEWER than the reported OS - the A12 base reports
# 120000 -> swd_key_upgrade returns -38 ("key newer than system") and read_key fails.
# ro.build.version.release feeds os_version; force 16 so 160000 == 160000.
"$RP" ro.build.version.release 16 2>/dev/null || setprop ro.build.version.release 16
# legacy-mode: vold rejects the v2 wrapped-key options ("metadata_encryption options
# cannot be set in legacy mode") unless the dm-default-key options format is v2 and DUN
# is on. Unset in recovery -> vold falls back to legacy(v1) and bails (length 0).
"$RP" ro.crypto.dm_default_key.options_format.version 2 2>/dev/null || setprop ro.crypto.dm_default_key.options_format.version 2
"$RP" ro.crypto.set_dun true 2>/dev/null || setprop ro.crypto.set_dun true
echo "props: release=$(getprop ro.build.version.release) dm_fmt=$(getprop ro.crypto.dm_default_key.options_format.version) set_dun=$(getprop ro.crypto.set_dun)"

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
# apexservice stub - MUST be up before keystore2, which blocks on
# waitForService("apexservice") during startup (real apexd can't run in recovery).
# Registers the name + answers getActivePackages() empty so keystore2 finishes init
# and registers IKeystoreService. Verified live 2026-06-14: that wait was the wall.
start_svc decrypt-apexservice
sleep 1
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
# bootctl HAL must be registered BEFORE vold: mountFstab unconditionally does
# waitForService("android.hardware.boot.IBootControl/default") and blocks forever if
# it's absent (cp_needsCheckpoint, independent of the fstab checkpoint= flag).
start_svc decrypt-bootctl
sleep 1
start_svc decrypt-vold
sleep 4

echo "----- service states -----"
for s in decrypt-servicemanager decrypt-qseecomd decrypt-keymint decrypt-keystore2 decrypt-bootctl decrypt-vold; do
    echo "  init.svc.$s = $(getprop init.svc.$s)"
done
echo "----- running A16 procs -----"; ps -A 2>/dev/null | grep -iE "linker64" | grep -v grep

# 6. drive the metadata decrypt via the matched A16 vdc -> vold (IVold.mountFstab
#    runs fscrypt_mount_metadata_encrypted: KeyMint unwraps the keymaster_key_blob
#    in /metadata/vold/metadata_encryption -> dm-default-key -> mount /data).
USERDATA=$(ls /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata \
              /dev/block/platform/soc/1d84000.ufshc/by-name/userdata 2>/dev/null | head -1)
echo "----- decrypt: userdata=$USERDATA -----"
# A16 vdc dropped raw commands; cryptfs mountFstab now needs 6 args:
#   cryptfs mountFstab <blkDevice> <mountPoint> <isZoned:bool> <userDevices>
# (verified live: the 4-arg form -> "Raw commands are no longer supported").
echo "[vdc cryptfs mountFstab - 6 args]"
lrun "$SYS/system/bin/vdc" cryptfs mountFstab "$USERDATA" /data false "" 2>&1
sleep 3
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "SUCCESS: /data mounted"; grep -E " /data " /proc/mounts
else
    echo "/data not mounted - check decrypt.log for the vold mountFstab error"
fi
echo "===== decrypt done ====="
