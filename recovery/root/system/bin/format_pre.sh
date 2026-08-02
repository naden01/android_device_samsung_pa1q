#!/system/bin/sh
# pa1q: pre-Format-Data teardown. Runs from TWRP's Format_Data() BEFORE
# dat->Wipe_Encryption() (which calls delete_crypto_blk_dev + mkfs).
#
# WHY: decrypt.sh mounts the dm-default-key device (mapper/userdata = dm-N over
# the raw userdata block, e.g. sda59) at /data, and ALSO bind-mounts /sdcard ->
# /data/media/0 (WIP77, for Internal Storage access). TWRP's Format unmounts its
# own /data but does NOT know about our /sdcard bind, so the dm device stays held
# -> delete_crypto_blk_dev fails ("Error deleting crypto block device") -> the raw
# block is still "In use by the system!" -> make_f2fs aborts (ERROR 255).
#
# This frees the raw block deterministically: drop the /sdcard bind, unmount /data,
# then tear down the dm-default-key device. Proven live 2026-06-24: sda59 holders
# go to NONE after `dmctl delete userdata`, and mkfs then succeeds. Every step is
# best-effort (|| true) so a missing mount never blocks the format.
#
# After format the user reboots into the ROM (FBE recreates /data/media); a later
# in-recovery decrypt re-runs decrypt.sh which recreates dm + /data + /sdcard.

LOG=/tmp/format_pre.log
exec >>"$LOG" 2>&1
echo "===== format_pre start ====="

# 1) drop the orphan Internal Storage bind (the mount TWRP doesn't track)
# WIP167: the bind moved from /sdcard to "/Internal Storage" (decrypt.sh / remount_data).
# This umount is NOT cosmetic - the bind pins the dm-default-key device, and leaving it
# behind is exactly what made mkfs on sda59 fail with "In use by the system!" (the bug
# WIP82 was written for). The check uses `mountpoint -q`, NOT grep of /proc/mounts: the
# kernel escapes the space there as \040 ("/dev/block/dm-8 /Internal\040Storage f2fs ..."),
# so a plain grep for " /Internal Storage " can never match. /sdcard is still handled for
# older sessions / a stale bind left by a pre-WIP167 boot.
for _mp in "/Internal Storage" /sdcard; do
    if mountpoint -q "$_mp" 2>/dev/null; then
        umount "$_mp" 2>&1 && echo "umount '$_mp' ok" || echo "umount '$_mp' failed (continuing)"
    fi
done

# 2) unmount /data (TWRP also tries this; doing it here is idempotent)
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    umount /data 2>&1 && echo "umount /data ok" || echo "umount /data failed (continuing)"
fi

# 3) tear down the dm-default-key device so the raw userdata block is released.
#    dmctl ships in the A16 dump used by decrypt.sh; vdc is the fallback.
DMCTL=/decrypt/system/bin/dmctl
if [ -e /dev/block/mapper/userdata ]; then
    if [ -x "$DMCTL" ]; then
        LD_LIBRARY_PATH=/decrypt/system/lib64:/decrypt/system/bin "$DMCTL" delete userdata 2>&1 \
            && echo "dmctl delete userdata ok" || echo "dmctl delete userdata failed (continuing)"
    fi
fi

# 4) report the raw block holders (empty = free for mkfs)
DEV=$(ls -l /dev/block/by-name/userdata 2>/dev/null | sed 's#.*/##')
[ -z "$DEV" ] && DEV=$(ls -l /dev/block/bootdevice/by-name/userdata 2>/dev/null | sed 's#.*/##')
if [ -n "$DEV" ] && [ -d "/sys/block/${DEV%%[0-9]*}/$DEV/holders" ]; then
    h=$(ls "/sys/block/${DEV%%[0-9]*}/$DEV/holders" 2>/dev/null | tr '\n' ' ')
    [ -z "$h" ] && echo "userdata block ($DEV) holders: NONE -> free for mkfs" \
                || echo "userdata block ($DEV) holders: $h (still held!)"
fi
echo "===== format_pre done ====="
