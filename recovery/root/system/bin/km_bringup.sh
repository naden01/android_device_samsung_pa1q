#!/system/bin/sh
# On-demand orchestrator (oneshot). Starts the stock A16 security HALs - now real
# init services (km-qseecomd, km-keymint) - in the right ORDER: qseecomd first
# (brings up the TEE listener KeyMint needs), then KeyMint once the TEE daemon is
# up. The HALs are init-managed and survive this oneshot exiting.
LOG=/tmp/km_bringup.log
exec >>"$LOG" 2>&1
echo "===== km_bringup start (uptime $(cat /proc/uptime 2>/dev/null)) ====="

# Auto-started at boot, so the super/logical partitions may not be mapped yet -
# TWRP maps them during its own startup. Wait (bounded) for system_a to appear.
# TWRP's Decrypt_Data() blocks in waitForService(KeyMint) meanwhile, so racing is
# safe: it resumes the moment we register KeyMint below.
n=0
while [ "$n" -lt 60 ]; do            # up to ~30s
    [ -e /dev/block/mapper/system_a ] && [ -e /dev/block/mapper/vendor_a ] && break
    n=$((n + 1)); sleep 0.5
done
echo "mapper ready after ~$((n * 500))ms (system_a=$([ -e /dev/block/mapper/system_a ] && echo y || echo n))"

SYS=/mnt/system_real
if [ ! -e "$SYS/system/bin/bootstrap/linker64" ]; then
    mkdir -p "$SYS" 2>/dev/null
    for s in /dev/block/mapper/system_a /dev/block/mapper/system_b /dev/block/mapper/system; do
        [ -e "$s" ] && mount -t erofs -o ro "$s" "$SYS" 2>/dev/null && echo "mounted system_real from $s" && break
    done
fi
# /vendor (A16) holds the HAL binaries/libs/trustlets. runatboot.sh has not mounted
# it this early, so mount it ourselves - else the services can't open /vendor/bin/*.
if [ ! -e /vendor/bin/qseecomd ]; then
    for v in /dev/block/mapper/vendor_a /dev/block/mapper/vendor_b /dev/block/mapper/vendor; do
        [ -e "$v" ] && mount -t erofs -o ro "$v" /vendor 2>/dev/null && echo "mounted /vendor from $v" && break
    done
fi
echo "vendor qseecomd present: $([ -e /vendor/bin/qseecomd ] && echo yes || echo NO)"

echo "starting km-qseecomd..."
setprop ctl.start km-qseecomd
n=0
while [ "$n" -lt 24 ]; do
    logcat -d -s QSEECOMD 2>/dev/null | grep -q "QSEECOM DAEMON RUNNING" && { echo "qseecomd: TEE daemon up (iter $n)"; break; }
    n=$((n + 1)); sleep 0.5
done
echo "km-qseecomd svc: $(getprop init.svc.km-qseecomd)"

echo "starting km-keymint..."
setprop ctl.start km-keymint
n=0; km=0
while [ "$n" -lt 24 ]; do
    logcat -d 2>/dev/null | grep -q "keymint-service: adding" && { km=1; break; }
    n=$((n + 1)); sleep 0.5
done
setprop twrp.keymint.ready "$km"

echo "----- result -----"
echo "qseecomd=$(getprop init.svc.km-qseecomd) keymint=$(getprop init.svc.km-keymint) registered=$km"
ps -A 2>/dev/null | grep -iE "qseecom|keymint" | grep -v grep
echo "===== km_bringup done ====="
