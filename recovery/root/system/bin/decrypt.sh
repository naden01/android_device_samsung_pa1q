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
# TA-SPEED EXPERIMENT (WIP50): the skeymast trustlet derives its build_type by PARSING the
# `type` field of ro.build.fingerprint (confirmed in the .mbn: "build_type->data : %s" +
# "Failed to get build type"; libskeymint10device.so reads ro.build.fingerprint). In the TWRP
# env that fingerprint is the eng/test-keys TWRP one (".../:eng/test-keys") -> the TA runs its
# slow ENG init path (~43s cold-load). The device's REAL ROM is user/release-keys. Feed the
# genuine device fingerprint so the TA parses build_type=user and (hypothesis) takes the fast
# production init. Lock-state enforcement is keyed on ro.boot.verifiedbootstate / SetRot
# boot_state_color (UNTOUCHED here), not build_type, so the lenient unlocked-device key path
# (begin ret 0 despite compromized) should be preserved. Also fix the bogus 2099-12-31
# security_patch placeholders to the real 2026-04-05 (libspukeymint.so reads both). REVERT this
# block if /data stops mounting (user TA path is stricter) or the TA time is unchanged (then the
# 43s is the unlock-state floor, not build_type).
"$RP" ro.build.fingerprint samsung/pa1qxxx/qssi_64:16/BP4A.251205.006/S931BXXU9CZDP:user/release-keys 2>/dev/null
"$RP" ro.build.type user 2>/dev/null
"$RP" ro.build.tags release-keys 2>/dev/null
"$RP" ro.build.version.security_patch 2026-04-05 2>/dev/null
"$RP" ro.vendor.build.security_patch 2026-04-05 2>/dev/null
echo "props: release=$(getprop ro.build.version.release) dm_fmt=$(getprop ro.crypto.dm_default_key.options_format.version) set_dun=$(getprop ro.crypto.set_dun)"
echo "ta-speed: fp=$(getprop ro.build.fingerprint) type=$(getprop ro.build.type) sec_patch=$(getprop ro.build.version.security_patch)"

# 4. hand /dev/binder to the A16 servicemanager: stop the A12 one (+ A12 keystore2).
#    ctl.stop leaves them stopped (only crashes auto-restart), so the A16 sm can
#    claim the context-manager slot.
setprop ctl.stop keystore2
setprop ctl.stop servicemanager
# poll until the A12 servicemanager is actually gone (frees /dev/binder) - not a fixed sleep
n=0; while [ "$n" -lt 30 ] && [ "$(getprop init.svc.servicemanager)" = "running" ]; do
    n=$((n + 1)); sleep 0.1
done

# 5. bring up the matched A16 stack via init. Replaced the conservative fixed `sleep`s with
#    readiness polls (proceed the instant each service is up) for a faster cold start.
start_svc() { setprop ctl.start "$1"; echo "ctl.start $1"; }
# wait (bounded) for an init service to report running
wait_run() { n=0; while [ "$n" -lt 80 ] && [ "$(getprop init.svc.$1)" != "running" ]; do
    n=$((n + 1)); sleep 0.1; done; }

start_svc decrypt-servicemanager
# A16 sm sets servicemanager.ready=true once it owns the context manager - wait on that
n=0; while [ "$n" -lt 60 ] && [ "$(getprop servicemanager.ready)" != "true" ]; do
    n=$((n + 1)); sleep 0.1
done
echo "sm ready=$(getprop servicemanager.ready) (~$((n * 100))ms)"

# apexservice stub - MUST be up before keystore2 (keystore2 blocks on
# waitForService("apexservice") during startup).
start_svc decrypt-apexservice
wait_run decrypt-apexservice

start_svc decrypt-qseecomd
n=0; while [ "$n" -lt 48 ]; do
    logcat -d -s QSEECOMD 2>/dev/null | grep -q "QSEECOM DAEMON RUNNING" && { echo "qseecomd: TEE up"; break; }
    n=$((n + 1)); sleep 0.25
done

# === TEMP SPU-HYPOTHESIS TEST (WIP51 - REVERT AFTER) ========================
# Bring the Samsung SPU (SPSS secure coprocessor) UP before the hwvault/skeymast TAs
# cold-load, to test whether skeymast's ~43s init is an SPU-probe timeout. The SPU is
# absent in recovery only because spss_utils.ko is not auto-loaded; loading it + starting
# the spss remoteproc boots spss1p.mdt (verified live: PBL_DONE/SW_INIT_DONE/attached).
# RISK: an UNSERVICED SPU watchdog hard-resets the device after a while. GUARD: a one-shot
# marker on /metadata, SET BEFORE the risky op, so a reset cannot bootloop recovery - the
# next boot sees the marker, skips the SPU, and decrypts normally. The result is written to
# /metadata (survives the reset). To re-run: `rm /metadata/spu_test.done`.
if [ ! -e /metadata/spu_test.done ]; then
    : > /metadata/spu_test.done
    echo "[SPU test] loading spss_utils.ko + starting SPU (uptime $(cat /proc/uptime))" | tee /metadata/spu_test.log
    insmod /vendor/lib/modules/spss_utils.ko 2>&1
    SPSS=""
    for r in /sys/class/remoteproc/remoteproc*; do
        grep -qi spss "$r/name" 2>/dev/null && SPSS="$r" && break
    done
    if [ -n "$SPSS" ]; then
        echo start > "$SPSS/state" 2>&1
        sleep 2
        st=$(cat "$SPSS/state" 2>/dev/null); fw=$(cat "$SPSS/firmware" 2>/dev/null)
        echo "[SPU test] state=$st fw=$fw" | tee -a /metadata/spu_test.log
    else
        echo "[SPU test] no spss remoteproc found" | tee -a /metadata/spu_test.log
    fi
fi
# === END TEMP SPU TEST =====================================================

# Start Weaver (hermes) NOW - early, in parallel with the keymint TA warm-up below, so its
# hwvault TA cold-loads CONCURRENTLY with skeymast instead of serially after the mount. Uses a
# tmpfs gatekeeper dir (/tmp/hermes_gk) so it does NOT need /data/vendor (DE-locked until
# de_keyinstall runs) - which also kills the old chdir-fail + 5s init-restart race. Only needs
# qseecomd (TEE) + the eSE, both ready here. IWeaver stays up via its hermes_secnvm socket.
mkdir -p /tmp/hermes_gk /mnt/vendor/efs/hermes 2>/dev/null
start_svc decrypt-hermes

start_svc decrypt-keymint
n=0; while [ "$n" -lt 48 ]; do
    logcat -d 2>/dev/null | grep -q "keymint-service: adding" && { echo "keymint registered"; break; }
    n=$((n + 1)); sleep 0.25
done
# keystore2's shared-secret handshake triggers the skeymast TA load - start it immediately so
# the 43s TZ load begins ASAP (no fixed sleep).
start_svc decrypt-keystore2
# bootctl HAL must register BEFORE vold (mountFstab waits on IBootControl/default).
start_svc decrypt-bootctl

# WAIT for the KeyMint skeymast TA to finish loading into TrustZone (the ~43s cold-load floor;
# keymint_swd "Tl initialization done"). vold.mountFstab has a ~35s timeout on its key op, so it
# MUST hit a warm TA. This poll exits the instant the shared-secret handshake completes.
echo "waiting for KeyMint TA warm-up (shared-secret handshake)..."
w=0
while [ "$w" -lt 90 ]; do
    logcat -d -b all 2>/dev/null | grep -qE "computeSharedSecret: ret 0|Shared secret negotiation concluded" && break
    w=$((w + 1)); sleep 1
done
echo "keymint TA warm after ~${w}s (handshake $([ "$w" -lt 90 ] && echo seen || echo TIMEOUT))"
# TA-SPEED EXPERIMENT readout: confirm which build_type the trustlet parsed from the fingerprint
echo "ta build_type seen by trustlet: $(logcat -d -b all 2>/dev/null | grep -oE "build_type->data : [a-z]+" | tail -1)"
# === TEMP SPU-HYPOTHESIS readout (WIP51) - persist the decisive metric to /metadata =====
# skeymast cold-init time WITH the SPU up. If ~43s -> SPU is NOT the cause (abandon). If a
# few seconds -> SPU is the cause (invest in the full SPU userspace stack). Also record the
# hwvault SPU wrap result (was strongbox_wrap err -1000 with the SPU down -> 0 if usable).
spu_now=$(for r in /sys/class/remoteproc/remoteproc*; do grep -qi spss "$r/name" 2>/dev/null && cat "$r/state" 2>/dev/null && break; done)
hv_spu=$(logcat -d -b all 2>/dev/null | grep -E "wrap_using_spu|strongbox_wrap" | tail -1)
{
  echo "keymint_TA_warm=~${w}s  (was ~43s with SPU down)"
  echo "skeymast_tz_window: $(logcat -d -b all 2>/dev/null | grep -E "keymint_tee.*tz open success|tz_app_init:131" | head -2 | tr '\n' '|')"
  echo "spu_state_at_keymint=${spu_now:-<none>}"
  echo "hwvault_spu=${hv_spu:-<no spu log>}"
} >> /metadata/spu_test.log 2>/dev/null
echo "[SPU test] metric written to /metadata/spu_test.log"
start_svc decrypt-vold
wait_run decrypt-vold

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

# 6a. FBE layer - install the systemwide DE key (next domino after the metadata mount).
# The metadata mount only unlocks the block layer; /data/misc + /data/system_de/0 are
# still per-file (FBE) encrypted (zero fscrypt keys in the keyring). The systemwide DE
# key is hardware-wrapped (mode wrappedkey_v0); de_keyinstall asks the A16 KeyMint to
# convert /data/unencrypted/key into a per-boot ephemeral wrapped key and installs it via
# FS_IOC_ADD_ENCRYPTION_KEY. NON-DESTRUCTIVE (keyring-only, per-boot, nothing on disk) and
# independent of the metadata key restored below. We do NOT run init_user0 here - that is
# only safe once the DE key is confirmed in (else vold regenerates the real user-0 keys).
# Requires KeyMint up; runs via the A16 bootstrap linker so it can reach the A16 binder.
if grep -qE " /data " /proc/mounts 2>/dev/null \
   && [ -e /data/unencrypted/key/keymaster_key_blob ] \
   && [ -x /system/bin/de_keyinstall ]; then
    # Weaver (hermes) was started early (in the stack section, parallel with the keymint TA),
    # so its hwvault TA is already warming/warm by now. de_keyinstall installs all 3 FBE layers
    # (systemwide DE + user-0 DE + user-0 CE); the CE step uses IWeaver. Report its state.
    echo "weaver: init.svc.decrypt-hermes=$(getprop init.svc.decrypt-hermes) (running => IWeaver up)"
    echo "----- FBE: install DE+CE keys (de_keyinstall: all three layers) -----"
    lrun /system/bin/de_keyinstall 2>&1
    echo "fscrypt keyring now: $(cat /proc/keys 2>/dev/null | grep -c fscrypt) key(s)"
else
    echo "FBE DE-key install skipped (no /data, no key material, or binary missing)"
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
