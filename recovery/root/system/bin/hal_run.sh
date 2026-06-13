#!/system/bin/sh
# Service wrapper: run a stock Android-16 security HAL inside Android-12 TWRP as a
# PROPER init service. Launched by init (km-qseecomd / km-keymint), so the HAL
# inherits its stock init socket (e.g. qseecomd's notify-topology) and runs under
# the stock user/group - which is why the daemons now persist (a bare
# bootstrap-linker launch from a script gave qseecomd no socket and it did not
# survive).
#
# Mount the real A16 system (for the bootstrap linker + A16 libs), then exec the
# linker on the HAL. LD_LIBRARY_PATH is set ONLY right before exec, so no A12
# toybox ever runs with the A16 lib path (that mismatch SIGSEGV'd setsid/logcat).
SYS=/mnt/system_real
if [ ! -e "$SYS/system/bin/bootstrap/linker64" ]; then
    mkdir -p "$SYS" 2>/dev/null
    for s in /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system; do
        [ -e "$s" ] || continue
        mount -t erofs -o ro "$s" "$SYS" 2>/dev/null && break
    done
fi
# Ensure the A16 vendor is mounted at /vendor (holds the HAL binaries + libs +
# trustlets). At early boot runatboot.sh has not mounted it yet, so do it here -
# otherwise the linker can't even open /vendor/bin/* and the service crash-loops.
if [ ! -e /vendor/bin/qseecomd ]; then
    for v in /dev/block/mapper/vendor_a /dev/block/mapper/vendor_b /dev/block/mapper/vendor; do
        [ -e "$v" ] || continue
        mount -t erofs -o ro "$v" /vendor 2>/dev/null && break
    done
fi
export LD_LIBRARY_PATH="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"
export ANDROID_DATA=/data ANDROID_ROOT=/system
exec "$SYS/system/bin/bootstrap/linker64" "$@"
