#!/system/bin/sh
# decrypt-watch.sh - persistent TWRP daemon that keeps /data mountable from the GUI.
#
# Our A16 decrypt mounts /data on the decrypted dm-default-key device
# (/dev/block/mapper/userdata). TWRP's own GUI "Mount Data" / "Decrypt" buttons use
# TWRP's built-in logic (raw userdata partition / built-in FBE), which on this A16
# device FAIL: the raw mount is "Device or resource busy" (our dm device holds
# userdata) and the built-in decrypt SIGABRTs. So when the user taps those buttons,
# TWRP logs a mount/decrypt failure but /data stays unmounted.
#
# This watcher tails the TWRP recovery log for a NEW failure line (tracked by byte
# offset, so pre-existing/old lines never re-fire) and, only then, restores /data:
# a fast re-mount of the already-decrypted dm device, or a full decrypt re-run if that
# device is gone. It does NOTHING on a plain unmount - it acts only when the user
# actually asked to mount/decrypt and TWRP failed, so it never fights an intentional
# unmount.
LOG=/tmp/recovery.log
exec >>/tmp/decrypt-watch.log 2>&1
echo "===== decrypt-watch start (uptime $(cat /proc/uptime 2>/dev/null)) ====="

# Arm from the CURRENT end of the log so pre-existing boot-time failures are ignored.
pos=$(wc -c < "$LOG" 2>/dev/null); [ -z "$pos" ] && pos=0

while true; do
    sleep 1
    [ -e "$LOG" ] || continue
    cur=$(wc -c < "$LOG" 2>/dev/null); [ -z "$cur" ] && cur=0
    [ "$cur" -lt "$pos" ] && pos=0          # log truncated/rotated -> rearm
    [ "$cur" -le "$pos" ] && continue       # nothing new appended
    new=$(tail -c +$((pos + 1)) "$LOG" 2>/dev/null)
    pos=$cur
    # Only a FRESH GUI mount/decrypt failure for /data triggers us.
    echo "$new" | grep -qE "Failed to mount '/data'|Unable to mount '/data'|Failed to decrypt data" || continue
    # If something already mounted /data, nothing to do.
    grep -qE " /data " /proc/mounts 2>/dev/null && continue
    echo "[uptime $(cut -d. -f1 /proc/uptime 2>/dev/null)] GUI /data mount/decrypt failure -> restoring"
    # Fast path: the decrypted dm device is still mapped -> just mount it.
    if [ -e /dev/block/mapper/userdata ] && mount -t f2fs /dev/block/mapper/userdata /data 2>&1; then
        echo "  -> re-mounted /data from /dev/block/mapper/userdata"
        continue
    fi
    # Fallback: decrypted device gone -> re-run the full decrypt via its init service.
    # `start decrypt` on an already-running service is a no-op, so this cannot double-run.
    echo "  -> dm device gone; re-triggering full decrypt"
    setprop twrp.decrypt.run 0
    setprop twrp.decrypt.run 1
done
