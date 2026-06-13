#!/system/bin/sh
# A16 security stack host, run by the `km-stack` init service which is declared
# with `namespace mnt`. Everything here executes inside a PRIVATE mount namespace,
# so mounting the Android-16 vendor over /vendor does NOT corrupt the global
# Android-12 TWRP environment (that ABI mix crashed toybox: setsid/logcat/sh
# segfaulted, see git history). The global /vendor stays TWRP's own.
#
# This script is long-lived: it launches qseecomd/KeyMint/gatekeeper/keystore2 as
# its children and then blocks forever, so the namespace and the HALs stay alive
# for as long as the km-stack service runs. No setsid needed - the HALs are
# children of a NON-oneshot init service, not of a dying oneshot script.
#
# PID namespace is shared (mount ns only), so `ps`/servicemanager see these from
# the outside; binder, /dev/binder, /dev/smcinvoke and dm block devices are global.

LOG=/tmp/hal_stack.log
exec >>"$LOG" 2>&1
echo "===== hal_stack start (uptime $(cat /proc/uptime 2>/dev/null)) ====="

# Belt-and-suspenders: make our mounts private so nothing propagates back to the
# global namespace even if init's namespace setup left propagation shared.
mount --make-rprivate / 2>/dev/null

SYS=/mnt/system_real
mkdir -p "$SYS" 2>/dev/null

pick_src() {
    for d in "$@"; do [ -e "$d" ] && { echo "$d"; return 0; }; done
    return 1
}
SYS_SRC=$(pick_src /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system)
VND_SRC=$(pick_src /dev/block/mapper/vendor_a /dev/block/mapper/vendor_b /dev/block/mapper/vendor)
echo "mapper: system=$SYS_SRC vendor=$VND_SRC"
[ -n "$SYS_SRC" ] && [ -n "$VND_SRC" ] || { echo "FATAL: super not mapped"; exit 1; }

mount_ro() {
    src="$1"; dst="$2"; sentinel="$3"
    [ -e "$dst/$sentinel" ] && { echo "already mounted: $dst"; return 0; }
    [ -d "$dst" ] || mkdir -p "$dst" 2>/dev/null
    for t in erofs ext4 f2fs; do
        mount -t "$t" -o ro "$src" "$dst" 2>/dev/null && { echo "mounted $src -> $dst ($t)"; return 0; }
    done
    echo "FATAL: could not mount $src -> $dst"; return 1
}
# system at a private path; vendor OVER /vendor - safe, we are in our own ns
mount_ro "$SYS_SRC" "$SYS"   "system/bin/bootstrap/linker64" || exit 1
mount_ro "$VND_SRC" /vendor  "bin/qseecomd"                  || exit 1

LINKER="$SYS/system/bin/bootstrap/linker64"
LIBS="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"
# CRITICAL: do NOT export LD_LIBRARY_PATH into this script's environment. Every
# tool we call (ps/grep/logcat/mount/sh) is an Android-12 toybox binary; if it
# inherits the A16 library path it loads a mismatched A16 libc++ and SIGSEGVs.
# THIS was the real cause of the setsid/logcat/qseecomd "Segmentation fault"
# cascade - not the /vendor mount. LD_LIBRARY_PATH is scoped to the bootstrap
# linker exec only, inside a subshell, in launch() below.
export ANDROID_DATA=/data ANDROID_ROOT=/system

QSEECOMD=/vendor/bin/qseecomd
GATEKEEPER=/vendor/bin/hw/android.hardware.gatekeeper-service
KEYMINT=/vendor/bin/hw/android.hardware.security.keymint-service
KEYSTORE2="$SYS/system/bin/keystore2"

echo "----- dependency check -----"
miss=0
for f in "$LINKER" "$QSEECOMD" "$KEYMINT" "$GATEKEEPER" "$KEYSTORE2" \
         "$SYS/system/lib64/libbinder_ndk.so" "$SYS/system/lib64/libc++.so" \
         /vendor/lib64/libQSEEComAPI.so /vendor/lib64/libskeymint10device.so \
         /vendor/lib64/vendor.samsung.hardware.keymint-V3-ndk.so \
         /vendor/lib64/libsec_esek.so /vendor/lib64/libhermes_cred.so; do
    [ -e "$f" ] && echo "  ok   $f" || { echo "  MISS $f"; miss=$((miss + 1)); }
done
echo "dependency check: $miss missing"

# Provisioning: KeyMint reads the DAK keybox from efs; persist holds device data.
mount_byname() {
    name="$1"; dst="$2"
    [ -d "$dst" ] || mkdir -p "$dst" 2>/dev/null
    grep -q " $dst " /proc/mounts 2>/dev/null && return
    for src in /dev/block/by-name/$name /dev/block/bootdevice/by-name/$name \
               /dev/block/platform/soc/1d84000.ufshc/by-name/$name; do
        [ -e "$src" ] || continue
        mount -o ro "$src" "$dst" 2>/dev/null && { echo "mounted $name -> $dst"; return; }
    done
    echo "note: could not mount $name"
}
mount_byname efs /mnt/vendor/efs
mount_byname persist /mnt/vendor/persist

is_running() { ps -A 2>/dev/null | grep -F "$1" | grep -qv grep; }
launch() { # bin tag
    is_running "$1" && { echo "already running: $1"; return; }
    # LD_LIBRARY_PATH is set ONLY for the linker exec, inside a subshell, so the
    # A12 toybox elsewhere in this script never sees the A16 lib path.
    ( LD_LIBRARY_PATH="$LIBS" exec "$LINKER" "$1" ) >"/tmp/halns_$2.log" 2>&1 &
    echo "launched $1 pid $!"
}

# qseecomd first: opens /dev/smcinvoke and loads the TEE trustlets KeyMint needs.
launch "$QSEECOMD" qseecomd
n=0
while [ "$n" -lt 24 ]; do
    logcat -d -s QSEECOMD 2>/dev/null | grep -q "QSEECOM DAEMON RUNNING" && { echo "qseecomd: TEE up (iter $n)"; break; }
    n=$((n + 1)); sleep 0.5
done

launch "$GATEKEEPER" gatekeeper
launch "$KEYMINT" keymint

# Wait for KeyMint to register before bringing keystore2 up (keystore2 SIGSEGV
# crash-loops against an absent/half-registered KeyMint).
n=0; km=0
while [ "$n" -lt 24 ]; do
    if logcat -d 2>/dev/null | grep -q "keymint-service: adding"; then km=1; break; fi
    is_running keymint-service && { km=1; break; }
    n=$((n + 1)); sleep 0.5
done
echo "keymint registered=$km"

if [ "$km" = 1 ] && [ -e "$KEYSTORE2" ]; then
    mkdir -p /data/misc/keystore /metadata/keystore 2>/dev/null
    launch "$KEYSTORE2" keystore2
fi

setprop twrp.keymint.ready "$km"
echo "----- running -----"
ps -A 2>/dev/null | grep -iE "qseecomd|keymint|gatekeeper|keystore2" | grep -v grep
echo "===== hal_stack up; holding namespace alive ====="

# Keep the service (and thus the namespace + HALs) alive forever.
while true; do sleep 3600; done
