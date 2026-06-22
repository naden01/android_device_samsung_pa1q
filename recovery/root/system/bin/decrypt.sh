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
# WIP65: wipe the log buffers up front. The handshake warm-up poll below is already
# stale-proof via its hs_base count-delta, but the OTHER readiness greps (qseecomd
# "QSEECOM DAEMON RUNNING", keymint "adding", and the ROT "checkRotStr" parse) are plain
# `grep -q` with no baseline - on a RE-RUN in the same boot they'd match the PREVIOUS run's
# lines instantly (a stale ROT read is the dangerous one: it could write a wrong rot value).
# Clearing -b all once here means every grep can only ever see lines this run produced; it
# also resets hs_base to 0 so the count-delta still works unchanged.
logcat -c -b all 2>/dev/null

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

# Read one key=value from a build.prop file ($1=file, $2=key). Prints the value (everything
# after the first '='), or nothing if the file/key is absent. build.prop is flat key=value
# (no sections), so a first-match grep is exact. Used to pull the device's OWN identity off
# the mounted real system/vendor (see the identity block in section 3a) instead of hardcoding
# one model - so the SAME script works across the whole S25 line and survives OS updates.
prop_from() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }

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
# WIP76: reduced from 3s→1s: TWRP is blocked on waitForService(KeyMint) during
# the entire sm-swap window, so no Binder race exists then; 1s covers the
# ~100-300ms post-decrypt TWRP resume with a 3-5x margin.
sleep 1

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
    printf '%s\n' '<manifest version="4.0" type="device" />' > /tmp/vintf_src/manifest.xml
    rm -f /tmp/vintf_src/manifest_sun.xml
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

# WIP52: mount the REAL efs + persist (provisioning) at the vendor paths the skeymast TA
# reads at init. PROVEN via the Android-vs-recovery split: in normal Android the trustlet
# cold-loads in ~47ms; in TWRP it takes ~43s. The difference is the environment - TWRP does
# NOT mount efs/persist at /mnt/vendor/* (only an empty tmpfs), so the TA's secure-storage /
# keybox read at tz_app_init retries/times out (~43s). efs (sda6) holds DAK/GAK_*/SAK_* +
# attestation blobs; persist (sda5) holds secnvm. Mount READ-ONLY so we never mutate the
# device's real provisioning. Safe: a plain ext4 RO mount (verified live - no crash, unlike
# the QCE driver which NoC-faulted). Must be in place BEFORE decrypt-keymint starts below.
for spec in efs:/mnt/vendor/efs persist:/mnt/vendor/persist; do
    name=${spec%%:*}; mp=${spec##*:}
    mkdir -p "$mp" 2>/dev/null
    if ! grep -q " $mp " /proc/mounts 2>/dev/null; then
        dev=$(ls /dev/block/by-name/$name /dev/block/bootdevice/by-name/$name 2>/dev/null | head -1)
        [ -n "$dev" ] && mount -t ext4 -o ro "$dev" "$mp" 2>/dev/null \
            && echo "efs-prov: mounted $name ($dev) ro -> $mp" \
            || echo "efs-prov: could not mount $name"
    fi
done
echo "efs-prov: /mnt/vendor/efs/DAK = [$(ls /mnt/vendor/efs/DAK 2>/dev/null | tr '\n' ' ')]"
# DAK keybox provisioning KeyMint reads (only matters if efs above is NOT the real RO mount)
mkdir -p /mnt/vendor/efs/DAK 2>/dev/null
setprop sys.boot_completed 1
setprop apexd.status activated

# 3a. version props the A16 stack reads - set BEFORE KeyMint/vold start (KeyMint reads
#     the OS version at init, vold reads ro.crypto at mountFstab). These are write-once
#     ro. props, so use resetprop to force them in place. Verified live 2026-06-14.
RP=/system/bin/resetprop
# anti-rollback: the /data metadata key is created under the device's CURRENT OS version
# (e.g. Android 16 -> key os_version 160000). KeyMint's TA refuses a key NEWER than the
# reported OS - the A12 base reports 120000 -> swd_key_upgrade returns -38 ("key newer than
# system") and read_key fails. ro.build.version.release feeds os_version. Read the REAL
# release off the device's own mounted system (so an OTA to a newer Android keeps working -
# a hardcoded "16" would WEDGE the mount after the user updates: key 170000 > reported 16).
SYS_BP=/decrypt/system/build.prop
VEN_BP=/vendor/build.prop
REL=$(prop_from "$SYS_BP" ro.build.version.release)
if [ -n "$REL" ]; then "$RP" ro.build.version.release "$REL" 2>/dev/null
else echo "WARN: ro.build.version.release not found in $SYS_BP - leaving as-is"; fi
# legacy-mode: vold rejects the v2 wrapped-key options ("metadata_encryption options
# cannot be set in legacy mode") unless the dm-default-key options format is v2 and DUN
# is on. Unset in recovery -> vold falls back to legacy(v1) and bails (length 0). These two
# describe the /data ENCRYPTION FORMAT (v2 hardware-wrapped), not the OS - identical across
# the whole S25 generation and unaffected by OS updates, so they stay fixed (nothing to read).
"$RP" ro.crypto.dm_default_key.options_format.version 2 2>/dev/null || setprop ro.crypto.dm_default_key.options_format.version 2
"$RP" ro.crypto.set_dun true 2>/dev/null || setprop ro.crypto.set_dun true
# DEVICE IDENTITY (was WIP50, hardcoded to pa1q/S931B). The skeymast trustlet derives its
# build_type by PARSING the `type` field of ro.build.fingerprint (confirmed in the .mbn:
# "build_type->data : %s"; libskeymint10device.so reads ro.build.fingerprint). In the TWRP env
# that fingerprint is the eng/test-keys TWRP one -> the TA runs its slow ENG init (~43s cold-
# load). The device's REAL ROM is user/release-keys. Feed the genuine fingerprint so the TA
# parses build_type=user and takes the fast production init. Lock-state enforcement is keyed on
# ro.boot.verifiedbootstate / SetRot (UNTOUCHED here), not build_type, so the lenient unlocked
# key path is preserved. Read it ALL off the device's own mounted system/vendor: Samsung has no
# literal ro.build.fingerprint in build.prop, the real value is ro.system.build.fingerprint.
# This is what makes one script serve the entire S25 line (pa1q/pa3q/...) and survive OTAs - no
# fallbacks: a missing value is SKIPPED (kept current) + logged, never overwritten with a guess.
FP=$(prop_from "$SYS_BP" ro.system.build.fingerprint)
BTYPE=$(prop_from "$SYS_BP" ro.system.build.type)
BTAGS=$(prop_from "$SYS_BP" ro.system.build.tags)
SPATCH=$(prop_from "$SYS_BP" ro.build.version.security_patch)
VPATCH=$(prop_from "$VEN_BP" ro.vendor.build.security_patch)
if [ -n "$FP" ]; then "$RP" ro.build.fingerprint "$FP" 2>/dev/null
else echo "WARN: ro.system.build.fingerprint not found in $SYS_BP - TA may take slow ENG init"; fi
[ -n "$BTYPE" ]  && "$RP" ro.build.type "$BTYPE" 2>/dev/null
[ -n "$BTAGS" ]  && "$RP" ro.build.tags "$BTAGS" 2>/dev/null
[ -n "$SPATCH" ] && "$RP" ro.build.version.security_patch "$SPATCH" 2>/dev/null
[ -n "$VPATCH" ] && "$RP" ro.vendor.build.security_patch "$VPATCH" 2>/dev/null
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
    # MUST use `-b all` (like the keymint poll below) - `logcat -d -s QSEECOMD` silently
    # matches NOTHING here, so this poll used to run to its full 12s timeout even though
    # qseecomd prints "QSEECOM DAEMON RUNNING" within ~3.5s. That dead 12s was the single
    # biggest chunk of the in-GUI decrypt latency (WIP54).
    logcat -d -b all 2>/dev/null | grep -q "QSEECOM DAEMON RUNNING" && { echo "qseecomd: TEE up (~$((n * 250))ms)"; break; }
    n=$((n + 1)); sleep 0.25
done
[ "$n" -ge 48 ] && echo "qseecomd: poll TIMEOUT (proceeding anyway)"

# Start Weaver (hermes) NOW - early, in parallel with the keymint TA warm-up below, so its
# hwvault TA cold-loads CONCURRENTLY with skeymast instead of serially after the mount. Uses a
# tmpfs gatekeeper dir (/tmp/hermes_gk) so it does NOT need /data/vendor (DE-locked until
# de_keyinstall runs) - which also kills the old chdir-fail + 5s init-restart race. Only needs
# qseecomd (TEE) + the eSE, both ready here. IWeaver stays up via its hermes_secnvm socket.
mkdir -p /tmp/hermes_gk /mnt/vendor/efs/hermes 2>/dev/null
# WIP65: kill any stale hermesd before (re)starting. decrypt-hermes is `disabled` so init
# never auto-starts it - but on a RE-RUN the PREVIOUS run's instance is still alive (and the
# very first start of a session crash-loops once on "delete all credentials for first boot"
# -> Check failed status=-3). A leftover instance keeps /dev/k250a (the eSE) and the
# hermes_secnvm socket held, so the new one comes up degraded. ctl.stop forces init to the
# stopped state (it will NOT auto-restart a ctl.stopped service, which also breaks any crash
# loop); we poll until it's actually gone, then start a single clean instance. No-op if none
# was running. Mirrors the keystore2/servicemanager stop-then-start handoff above.
setprop ctl.stop decrypt-hermes
n=0; while [ "$n" -lt 20 ] && [ "$(getprop init.svc.decrypt-hermes)" = "running" ]; do
    n=$((n + 1)); sleep 0.1
done
start_svc decrypt-hermes

# VINTF-overlay readiness gate for KeyMint (WIP70, fixes the early SIGABRT cascade). The A16
# servicemanager (637) must FINISH reading the VINTF manifest BEFORE keymint tries to register
# IKeyMintDevice/default - else keymint's addService gets status=-3 (manifest not found) ->
# SIGABRT. servicemanager.ready=true means sm owns /dev/binder, but it reads VINTF *lazily* on
# the first getTransport or during init service registration - so "ready" alone is not enough.
# Wait for a marker that proves sm HAS read /vendor/etc/vintf: the "Multiple same specifications"
# line sm logs when it sees the duplicate strongbox entry we deliberately left in the overlay
# fragments (the real strongbox fragment is stripped, but if *any* VINTF file has the pattern
# we'll match). Bounded to 60x0.1s=6s; degrade-safe (a miss just risks the -3, init will respawn).
n=0
while [ "$n" -lt 60 ]; do
    logcat -d -b all 2>/dev/null | grep -q "Multiple same specifications" && break
    n=$((n + 1)); sleep 0.1
done
[ "$n" -ge 60 ] && echo "WARN: VINTF readiness poll timeout - keymint may crash on -3"
echo "VINTF overlay ready for keymint registration (~$((n * 100))ms)"

start_svc decrypt-keymint
# WIP76: old poll ("keymint-service: adding") fired on the FIRST-CRASH instance too:
# keymint logs "adding..." then immediately hits CHECK(status=-3) SIGABRT (VINTF race).
# That false-positive made decrypt.sh proceed with a dead keymint → init entered its 5s
# backoff → keystore2/vold stalled for ~5s waiting for a service that wasn't there.
# Fix A: use "Adding SKeymint X.0 services is done" — only logged after ALL addService()
#        calls succeed; never appears on the crashed first instance.
# Fix B: if init enters restarting state, bypass the 5s backoff with an immediate stop+start.
n=0; while [ "$n" -lt 80 ]; do
    logcat -d -b all 2>/dev/null | grep -q "Adding SKeymint.*services is done" && {
        echo "keymint fully registered (~$((n * 100))ms)"; break; }
    if [ "$(getprop init.svc.decrypt-keymint)" = "restarting" ]; then
        setprop ctl.stop decrypt-keymint
        m=0; while [ "$m" -lt 15 ]; do
            s=$(getprop init.svc.decrypt-keymint)
            { [ "$s" != "running" ] && [ "$s" != "restarting" ]; } && break
            m=$((m+1)); sleep 0.05; done
        setprop ctl.start decrypt-keymint
        echo "keymint: first-crash detected, bypassed 5s backoff, restarted"
    fi
    n=$((n+1)); sleep 0.1
done
[ "$n" -ge 80 ] && echo "WARN: keymint poll timeout"
# keystore2's shared-secret handshake triggers the skeymast TA load - start it immediately so
# the 43s TZ load begins ASAP (no fixed sleep).
# Fresh-window baseline: count handshake markers ALREADY in the ring buffer, so the poll
# below waits for a NEW handshake from THIS keystore2 start - not a stale hit from a prior
# decrypt run. (The WIP64 revert traced a false "warm after ~0s" to exactly such a stale
# `logcat -d -b all` match. Count-delta also degrades safe: a wrapped/evicted baseline just
# times out into the vold attempt, never a false-early "warm".)
HS_RE="computeSharedSecret: ret 0|Shared secret negotiation concluded"
hs_base=$(logcat -d -b all 2>/dev/null | grep -cE "$HS_RE")
start_svc decrypt-keystore2
# bootctl HAL must register BEFORE vold (mountFstab waits on IBootControl/default).
start_svc decrypt-bootctl

# WAIT for the KeyMint skeymast TA to finish loading into TrustZone (the ~43s cold-load floor;
# keymint_swd "Tl initialization done"). vold.mountFstab has a ~35s timeout on its key op, so it
# MUST hit a warm TA. This poll exits the instant the shared-secret handshake completes.
echo "waiting for KeyMint TA warm-up (shared-secret handshake)..."
w=0
while [ "$w" -lt 300 ]; do
    # break only when a NEW handshake line appears past the baseline (stale-match proof)
    [ "$(logcat -d -b all 2>/dev/null | grep -cE "$HS_RE")" -gt "$hs_base" ] && break
    w=$((w + 1)); sleep 0.2
done
echo "keymint TA warm after ~$((w / 5))s (handshake $([ "$w" -lt 300 ] && echo seen || echo TIMEOUT))"
# TA-SPEED EXPERIMENT readout: build_type the trustlet parsed from the fingerprint this run.
# The trustlet logs "build type : user" (with a space) during cold TA load at tz_app_init.
# On a warm TA (already loaded earlier this boot) no new line appears -> the grep finds nothing
# -> empty output (which is diagnostic, not an error: it means the TA is reused, not cold).
echo "ta build_type seen by trustlet: $(logcat -d -b all 2>/dev/null | grep -oE "build type : [a-z]+" | tail -1 | sed 's/build type : //')"
start_svc decrypt-vold
wait_run decrypt-vold

# Wait for the cascade-started services to stabilize (first keymint start
# from vendor rc can crash+respawn before decrypt-keymint takes over cleanly).
sleep 1
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
# ROT-CACHE (speed): the current device ROT is STABLE across boots (hardware ROT + fuse
# state don't change on the same firmware). The probe mountFstab below is a full vold+KeyMint
# op that runs ONLY to make vold log the current ROT - so cache it on /metadata the first time
# and skip the probe on every subsequent boot. Cache is invalidated (deleted) after the real
# mountFstab if /data fails to mount (=> stale ROT, e.g. boot-state changed), so it self-heals.
ROTCACHE=/metadata/_rot_cache
if [ -e "$KDIR/rot" ] && ! grep -qE " /data " /proc/mounts 2>/dev/null; then
    cur=""
    if [ -s "$ROTCACHE" ]; then
        c=$(tr -dc '0-9a-fA-F' < "$ROTCACHE" 2>/dev/null)
        [ "${#c}" = "32" ] && cur="$c" && echo "[ROT sync: cached value $cur - probe skipped]"
    fi
    if [ -z "$cur" ]; then
        echo "[ROT sync: probe mountFstab to read current device ROT]"
        lrun "$SYS/system/bin/vdc" cryptfs mountFstab "$USERDATA" /data false "" >/dev/null 2>&1
        if ! grep -qE " /data " /proc/mounts 2>/dev/null; then
            cur=$(logcat -d -b all 2>/dev/null | grep "getRotStr rot value" | tail -1 | sed 's/.*value : *//' | tr -dc '0-9a-fA-F')
            [ "${#cur}" = "32" ] && printf '%s' "$cur" > "$ROTCACHE"
        fi
    fi
    if [ "${#cur}" = "32" ]; then
        esc=$(echo "$cur" | sed 's/\(..\)/\\x\1/g')
        [ -e "$KDIR/rot.orig" ] || cp -a "$KDIR/rot" "$KDIR/rot.orig" 2>/dev/null
        [ -e "$BDIR/rot.orig" ] || cp -a "$BDIR/rot" "$BDIR/rot.orig" 2>/dev/null
        printf "$esc" > "$KDIR/rot"
        [ -d "$BDIR" ] && printf "$esc" > "$BDIR/rot"
        echo "ROT set to current device value: $cur"
    else
        echo "ROT sync: could not determine current ROT (decrypt may fail on checkRotStr)"
    fi
fi

# A16 vdc dropped raw commands; cryptfs mountFstab now needs 6 args:
#   cryptfs mountFstab <blkDevice> <mountPoint> <isZoned:bool> <userDevices>
# (verified live: the 4-arg form -> "Raw commands are no longer supported").
echo "[vdc cryptfs mountFstab - 6 args]"
lrun "$SYS/system/bin/vdc" cryptfs mountFstab "$USERDATA" /data false "" 2>&1
# mountFstab is synchronous (vdc blocks on vold), so /data is up the instant it returns -
# poll instead of a fixed sleep 3 (exits in ~ms; bounded fallback for a slow cold mount).
m=0; while [ "$m" -lt 30 ]; do grep -qE " /data " /proc/mounts 2>/dev/null && break; m=$((m + 1)); sleep 0.1; done
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "SUCCESS: /data mounted (~$((m * 100))ms)"; grep -E " /data " /proc/mounts
    # WIP63: tell TWRP (crypto now compiled in) that /data is ALREADY decrypted on the dm device.
    # On its next Setup_Data_Partition scan TWRP reads ro.crypto.fs_crypto_blkdev and sets
    # Decrypted_Block_Device = this dm -> TW_IS_ENCRYPTED=0 (no "Decrypt Data" button) and
    # Update_Size statfs's the dm -> the real storage size (not 0MB). ro.* is write-once so use
    # resetprop. The crypto flags also make TWRP mark /data encrypted at startup, which stops the
    # boot-time "Failed to mount '/data' (Invalid argument)" noise (it no longer tries the raw mount).
    "$RP" ro.crypto.fs_crypto_blkdev /dev/block/mapper/userdata 2>/dev/null \
        || setprop ro.crypto.fs_crypto_blkdev /dev/block/mapper/userdata
    echo "ro.crypto.fs_crypto_blkdev=$(getprop ro.crypto.fs_crypto_blkdev) (TWRP sees /data decrypted -> size + no button)"
else
    echo "/data not mounted - check decrypt.log for the vold mountFstab error"
    # a failed mount with a cached ROT means the cache is stale -> drop it so next boot re-probes
    rm -f "$ROTCACHE" 2>/dev/null
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

# FREE /data for the TWRP GUI "Unmount" checkbox. keystore2's only job here was the
# initial shared-secret handshake that WARMS the KeyMint skeymast TA; that is done by now
# and the TA stays warm TZ-side for the rest of the session. But the A16 keystore2 keeps
# the device's REAL /data/misc/keystore/persistent.sqlite OPEN (fd RW) - and that single
# fd is the ONLY thing pinning /data, so TWRP's GUI Unmount Data fails with EBUSY ("Device
# or resource busy"). Stopping keystore2 now releases that fd: /data then has ZERO holders,
# so the GUI checkbox unmounts it cleanly with no error. The remount watcher's de_keyinstall
# talks to KeyMint DIRECTLY (not via keystore2) and KeyMint/hermesd stay up, so a later GUI
# "Mount" (-> watcher -> remount_data) still re-installs all three FBE layers fine. Verified
# live 2026-06-18: after ctl.stop, lsof shows /data unheld while keymint(755)/hermesd(753)
# stay alive. Bonus: stopping it sooner shrinks the window the recovery keystore2 holds the
# real keystore DB open RW. (Re-running decrypt restarts keystore2 in the stack section.)
if [ "$(getprop init.svc.decrypt-keystore2)" = "running" ]; then
    setprop ctl.stop decrypt-keystore2
    echo "keystore2 stopped (frees /data for GUI unmount; TA already warm, de_keyinstall reaches KeyMint directly)"
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

# Auto-remount watcher: start it ONLY now, after the first successful mount, so it baselines
# out every boot-time mount failure already in recovery.log. From here on, if the user unmounts
# /data via the TWRP GUI and then presses Mount (which TWRP can't do for A16 FBE), the watcher
# remounts the persistent dm-default-key device + re-installs the FBE keys (CE from the cached
# SP if it was unlocked). No reboot needed. See remount_watcher / remount_data.
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    setprop ctl.start decrypt-watcher
    echo "remount watcher started (decrypt-watcher)"
fi
echo "===== decrypt done ====="
