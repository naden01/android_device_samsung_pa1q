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

# /metadata mount: with TWRP crypto disabled (BoardConfig) TWRP no longer mounts
# /metadata at startup, but the entire metadata-encryption key dir lives there - and so
# does our pristine snapshot/restore. Mount it ourselves (idempotent), else every key
# read/write below silently lands in tmpfs and the decrypt + boot-safety restore fail.
if ! grep -qE " /metadata " /proc/mounts 2>/dev/null; then
    MD=$(ls /dev/block/by-name/metadata /dev/block/bootdevice/by-name/metadata 2>/dev/null | head -1)
    [ -n "$MD" ] && mount -t f2fs "$MD" /metadata 2>/dev/null
    grep -qE " /metadata " /proc/mounts 2>/dev/null && echo "/metadata mounted ($MD)" \
        || echo "WARN: /metadata NOT mounted - decrypt/key-restore will fail"
fi

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
# WARM UP the KeyMint TA before vold. The skeymast trustlet COLD-loads into TrustZone
# on the first KeyMint call and that takes ~40s in recovery (eng build, first-time TA
# load: keymint_swd "Tl initialization done"). keystore2's shared-secret handshake
# triggers it. vold.mountFstab has a ~35s timeout on its key op, so without this it
# gives up microseconds before the TA is warm - keystore2 logs "create_operation
# Success TEE" but vold has already returned "decryptWithKeystoreKey fail" / M02R.
# Wait (bounded) for the handshake to complete = TA loaded, then vold hits a warm TA
# and the op returns immediately.
echo "waiting for KeyMint TA warm-up (shared-secret handshake)..."
w=0
while [ "$w" -lt 90 ]; do
    logcat -d -b all 2>/dev/null | grep -qE "computeSharedSecret: ret 0|Shared secret negotiation concluded" && break
    w=$((w + 1)); sleep 1
done
echo "keymint TA warm after ~${w}s (handshake $([ "$w" -lt 90 ] && echo seen || echo TIMEOUT))"
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
# ROT SYNC (Samsung anti-tamper). vold's KeyStorage::checkRotStr compares the device's
# CURRENT Root of Trust against the ROT saved in the key dir when /data was last
# encrypted. Flashing a custom recovery blows the Knox sw-fuse, which flips ROT
# integrity_flag bit 0x10 (saved 0x07 -> current 0x17), so checkRotStr fails ("ROT value
# was invalid") -> decryptWithKeystoreKey fail -> /data won't mount, even though KeyMint
# itself returns the key (begin ret 0; ROT is NOT enforced TA-side, only here). The ROT
# is a vold-side gate, not key material, so syncing the saved value to current is safe
# and lets the real decrypt proceed (verified live 2026-06-14: /data then mounts).
# A probe mountFstab makes KeyStorage log the current ROT; parse + write it to the key
# dir's `rot` (+ sec_backup, + a one-time .orig backup). Idempotent: once synced the
# probe just mounts /data and we skip.
KDIR=/metadata/vold/metadata_encryption/key
BDIR=/metadata/sec_backup/metadata_encryption/key
# PRISTINE SNAPSHOT (boot-safety). Decrypting mutates the metadata key dir: vold's
# mountFstab makes KeyMint upgrade keymaster_key_blob (and we rewrite rot/integrity).
# Real Android cannot use those mutated bytes on its next boot -> bootloop. So before we
# touch ANYTHING, snapshot the whole key dir as it was last written by real Android. The
# guard captures it ONCE (the first decrypt after a fresh setup, i.e. the bytes Android
# needs); it is regenerated automatically after a Format Data (which wipes /metadata).
PSNAP=/metadata/_pristine_metakey
if [ ! -e "$PSNAP/.captured" ] && ! grep -qE " /data " /proc/mounts 2>/dev/null; then
    rm -rf "$PSNAP" 2>/dev/null; mkdir -p "$PSNAP"
    cp -a "$KDIR" "$PSNAP/primary" 2>/dev/null
    cp -a "$BDIR" "$PSNAP/backup"  2>/dev/null
    touch "$PSNAP/.captured"
    echo "[pristine key snapshot captured -> $PSNAP]"
fi
if [ -e "$KDIR/rot" ] && ! grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "[ROT sync: probe mountFstab to read current device ROT]"
    lrun "$SYS/system/bin/vdc" cryptfs mountFstab "$USERDATA" /data false "" >/dev/null 2>&1
    if ! grep -qE " /data " /proc/mounts 2>/dev/null; then
        cur=$(logcat -d -b all 2>/dev/null | grep "checkRotStr current rot value" | tail -1 | sed 's/.*value : *//' | tr -dc '0-9a-fA-F')
        if [ "${#cur}" = "32" ]; then
            esc=$(echo "$cur" | sed 's/\(..\)/\\x\1/g')
            [ -e "$KDIR/rot.orig" ] || cp -a "$KDIR/rot" "$KDIR/rot.orig" 2>/dev/null
            [ -e "$BDIR/rot.orig" ] || cp -a "$BDIR/rot" "$BDIR/rot.orig" 2>/dev/null
            printf "$esc" > "$KDIR/rot"
            [ -d "$BDIR" ] && printf "$esc" > "$BDIR/rot"
            echo "ROT synced to current device value: $cur"
        else
            echo "ROT sync: could not parse current ROT (decrypt may fail on checkRotStr)"
        fi
    fi
fi

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

# CRITICAL boot-safety - ALWAYS restore the pristine metadata key before exit, whether or
# not the mount succeeded. By this point the dir is mutated regardless: the ROT-sync probe
# wrote the TWRP-context ROT (0x17) and vold's mountFstab made KeyMint upgrade
# keymaster_key_blob (+ rewrite sec_backup/integrity). Real Android at boot computes 0x07
# and cannot use the upgraded blob -> key-unwrap fails -> /data won't mount -> BOOTLOOP ->
# "Format Data". If /data mounted here, dm-default-key is already set up in-kernel and vold
# does not re-read these files until the next mount, so restoring them does NOT disturb the
# live mount. Android then boots on the bytes it wrote and does its own valid upgrade.
if [ -e "$PSNAP/.captured" ]; then
    for f in keymaster_key_blob rot secdiscardable encrypted_key version encrypt_done; do
        [ -e "$PSNAP/primary/$f" ] && cp -a "$PSNAP/primary/$f" "$KDIR/$f" 2>/dev/null
    done
    for f in keymaster_key_blob rot integrity secdiscardable encrypted_key version encrypt_done; do
        [ -e "$PSNAP/backup/$f" ] && cp -a "$PSNAP/backup/$f" "$BDIR/$f" 2>/dev/null
    done
    rm -f "$KDIR/rot.orig" "$BDIR/rot.orig" 2>/dev/null   # not part of the pristine dir
    echo "pristine metadata key restored (rot=$(xxd -p "$KDIR/rot" 2>/dev/null | tr -d '\n')) -> Android boot safe"
else
    echo "WARN: no pristine snapshot captured - cannot guarantee a clean Android boot"
fi
echo "===== decrypt done ====="
