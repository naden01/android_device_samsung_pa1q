#!/system/bin/sh
# Bring up the Android-16 vendor security HALs (qseecomd, KeyMint, Gatekeeper)
# inside the Android-12-based TWRP so /data (FBE v2 + metadata enc, HW-wrapped
# keys) can later be decrypted. The HAL binaries are Android 16; running them on
# TWRP's own A12 libs fails on ABI/namespace, so we run them through the matching
# A16 bootstrap linker with an explicit library path taken from the real (mounted)
# system + vendor partitions, which sidesteps the vendor linker-namespace rules.
#
# RUN ON-DEMAND, not at boot: the super/logical partitions this depends on
# (system_a/vendor_a under /dev/block/mapper) are only mapped once TWRP itself is
# up, and a blocking startup decrypt hangs on the logo. Trigger via
# `setprop twrp.decrypt.run 1` (init starts us) or run directly. Idempotent.

LOG=/tmp/decrypt_hals.log
exec >>"$LOG" 2>&1
echo "===== decrypt_hals start ($(getprop ro.boot.serialno) $(cat /proc/uptime 2>/dev/null)) ====="

SYS=/mnt/system_real
mkdir -p "$SYS" 2>/dev/null

# --- 0. wait for the dynamic partitions to be mapped by TWRP -----------------
# TWRP maps super -> /dev/block/mapper/{system_a,vendor_a,...} during its own
# startup, so when run on-demand they are normally already present; we still poll
# (bounded) in case decrypt is triggered very early.
wait_mapper() {
    dev="$1"; n=0
    while [ "$n" -lt 40 ]; do            # up to ~20s
        [ -e "$dev" ] && return 0
        n=$((n + 1)); sleep 0.5
    done
    return 1
}
SYS_SRC=""
for s in /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system; do
    if wait_mapper "$s"; then SYS_SRC="$s"; break; fi
done
VND_SRC=""
for v in /dev/block/mapper/vendor_a /dev/block/mapper/vendor_b /dev/block/mapper/vendor; do
    if wait_mapper "$v"; then VND_SRC="$v"; break; fi
done
echo "mapper: system=$SYS_SRC vendor=$VND_SRC"
if [ -z "$SYS_SRC" ] || [ -z "$VND_SRC" ]; then
    echo "FATAL: super not mapped yet (system/vendor missing under /dev/block/mapper)"
    ls -la /dev/block/mapper/ 2>/dev/null
    exit 1
fi

# --- 1. mount the real A16 system + vendor -----------------------------------
# system is a full root container: its top-level bin/etc are absolute symlinks
# into /system, so the real payload lives under system/ (system/bin/bootstrap/...).
# vendor is mounted OVER /vendor because the HAL binaries dlopen absolute
# /vendor/lib64 paths and load trustlets from /vendor/firmware*.
mount_ro() {
    src="$1"; dst="$2"; sentinel="$3"
    [ -e "$dst/$sentinel" ] && { echo "already mounted: $dst"; return 0; }
    [ -d "$dst" ] || mkdir -p "$dst" 2>/dev/null
    for t in erofs ext4 f2fs; do
        if mount -t "$t" -o ro "$src" "$dst" 2>/dev/null; then
            echo "mounted $src -> $dst ($t)"; return 0
        fi
    done
    echo "FATAL: could not mount $src -> $dst"; return 1
}
mount_ro "$SYS_SRC" "$SYS" "system/bin/bootstrap/linker64" || exit 1
mount_ro "$VND_SRC" /vendor "bin/qseecomd"                 || exit 1

LINKER="$SYS/system/bin/bootstrap/linker64"
LIBS="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"
export ANDROID_DATA=/data
export ANDROID_ROOT=/system

# --- 2. dependency check ------------------------------------------------------
# Verify the binaries and the critical shared objects (from the live ldd closure)
# are present before we launch, so a missing blob is reported here instead of a
# silent immediate crash. Non-fatal: we log and continue so partial bring-up is
# still observable.
QSEECOMD=/vendor/bin/qseecomd
GATEKEEPER=/vendor/bin/hw/android.hardware.gatekeeper-service
KEYMINT=/vendor/bin/hw/android.hardware.security.keymint-service
KEYSTORE2="$SYS/system/bin/keystore2"   # from the real A16 system dump, not bundled
missing=0
echo "----- dependency check -----"
for f in "$LINKER" "$QSEECOMD" "$KEYMINT" "$GATEKEEPER" "$KEYSTORE2" \
         "$SYS/system/lib64/libbinder_ndk.so" "$SYS/system/lib64/libc++.so" \
         "$SYS/system/lib64/libbinder.so" "$SYS/system/lib64/libutils.so" \
         /vendor/lib64/libQSEEComAPI.so \
         /vendor/lib64/libskeymint10device.so \
         /vendor/lib64/libspukeymintdeviceutils.so \
         /vendor/lib64/vendor.samsung.hardware.keymint-V3-ndk.so \
         /vendor/lib64/android.hardware.security.keymint-V3-ndk.so \
         /vendor/lib64/libsec_esek.so /vendor/lib64/libhermes_cred.so; do
    if [ -e "$f" ]; then echo "  ok   $f"; else echo "  MISS $f"; missing=$((missing + 1)); fi
done
echo "dependency check: $missing missing"

# --- 3. provisioning partitions ----------------------------------------------
# KeyMint reads provisioning (DAK keybox) from efs; persist holds device data.
mount_byname() {
    name="$1"; dst="$2"
    [ -d "$dst" ] || mkdir -p "$dst" 2>/dev/null
    grep -q " $dst " /proc/mounts 2>/dev/null && { echo "already mounted: $dst"; return; }
    for src in /dev/block/by-name/$name /dev/block/bootdevice/by-name/$name \
               /dev/block/platform/soc/1d84000.ufshc/by-name/$name; do
        [ -e "$src" ] || continue
        mount -o ro "$src" "$dst" 2>/dev/null && echo "mounted $name -> $dst" && return
    done
    echo "note: could not mount $name"
}
mount_byname efs /mnt/vendor/efs
mount_byname persist /mnt/vendor/persist

# --- 4. launch the HALs -------------------------------------------------------
# Each HAL's stdout/stderr is captured to its own log so crashes are debuggable.
# (HAL fatal output also goes to logcat/kmsg via liblog; these files catch the
# rest.) Skip a HAL that is already running so the script is idempotent.
is_running() { ps -A 2>/dev/null | grep -F "$1" | grep -qv grep; }
start_hal() {
    bin="$1"; name="$2"; tag="$3"
    if [ ! -e "$bin" ]; then echo "skip $name: $bin missing"; return 1; fi
    if is_running "$name"; then echo "skip $name: already running"; return 0; fi
    # setsid: detach into a NEW session/process group. This script runs as a
    # oneshot init service, and modern init (A12+) sends SIGKILL to the whole
    # oneshot process group when the script exits ("Untracked pid N received
    # signal 9" in dmesg killed KeyMint). setsid moves the HAL out of that group
    # so it survives the script returning. Confirmed: without it the HALs die the
    # instant decrypt_hals.sh finishes.
    LD_LIBRARY_PATH="$LIBS" setsid "$LINKER" "$bin" >"/tmp/hal_$tag.log" 2>&1 &
    echo "started $name ($bin) pid $! (detached via setsid)"
}

# qseecomd first: it opens /dev/smcinvoke and loads the TEE trustlets KeyMint
# needs. Wait until it reports the daemon is running (or times out) before
# starting KeyMint, otherwise KeyMint races the TEE bring-up.
start_hal "$QSEECOMD" qseecomd qseecomd
n=0
while [ "$n" -lt 20 ]; do
    if logcat -d -s QSEECOMD 2>/dev/null | grep -q "QSEECOM DAEMON RUNNING"; then
        echo "qseecomd: TEE daemon up"; break
    fi
    [ -e /dev/smcinvoke ] && grep -q smcinvoke /proc/*/maps 2>/dev/null && break
    n=$((n + 1)); sleep 0.5
done

start_hal "$GATEKEEPER" gatekeeper gatekeeper
start_hal "$KEYMINT" keymint keymint

# --- 5. readiness -------------------------------------------------------------
# KeyMint must register ALL of its AIDL instances (KeyMintDevice, SecureClock,
# SharedSecret, RemotelyProvisionedComponent); keystore2 dereferences the lot, so
# a half-registered/dead service is what crash-loops keystore2. Confirm the
# process stays alive AND publish the prop the decrypt step will gate on.
KM_RE="android.hardware.security.keymint|keymint-service"
ready=0; stable=0; n=0
while [ "$n" -lt 24 ]; do            # up to ~12s
    if [ -x /system/bin/service ]; then
        if /system/bin/service check android.hardware.security.keymint.IKeyMintDevice/default 2>/dev/null | grep -q ": found"; then
            ready=1; break
        fi
    else
        if ps -A 2>/dev/null | grep -iE "$KM_RE" | grep -qv grep; then
            stable=$((stable + 1)); [ "$stable" -ge 4 ] && { ready=1; break; }
        else
            stable=0
        fi
    fi
    n=$((n + 1)); sleep 0.5
done
setprop twrp.keymint.ready "$ready"

# --- 6. keystore2 (from the real A16 system dump, not bundled) -----------------
# keystore2 is the system component vold's metadata decrypt talks to; it forwards
# key ops to the now-registered KeyMint. Run it from the mounted real system via
# the bootstrap linker, same pattern as the vendor HALs. Only start it once
# KeyMint is up - keystore2 dereferences KeyMint on init and crash-loops (SIGSEGV)
# if KeyMint is absent or half-registered (observed earlier).
if [ "$ready" = 1 ] && [ -e "$KEYSTORE2" ]; then
    mkdir -p /data/misc/keystore /metadata/keystore 2>/dev/null
    start_hal "$KEYSTORE2" keystore2 keystore2
    sleep 2
else
    echo "keystore2: skipped (KeyMint ready=$ready, bin exists=$([ -e "$KEYSTORE2" ] && echo yes || echo no))"
fi

echo "----- running security procs -----"
ps -A 2>/dev/null | grep -iE "qseecomd|keymint|gatekeeper|keystore2" | grep -v grep
echo "----- keymint instances logged -----"
logcat -d 2>/dev/null | grep -iE "keymint-service: adding|SecureClock|SharedSecret|RemotelyProvisioned" | tail -n 8
if [ -x /system/bin/service ]; then km_check=aidl; else km_check=proc-stable; fi
echo "keymint readiness=$ready check=$km_check missing_deps=$missing"
echo "===== decrypt_hals done ====="
