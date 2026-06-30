#!/system/bin/sh
# Pre-restore hook for /data — setup dm-default-key + FBE keys so TWRP Restore
# writes through the metadata-encryption layer (produces ciphertext on sda59).
#
# Called by TWRP partition.cpp Restore_Tar() BEFORE tar.extractTarFork() if:
#   - Mount_Point == "/data"
#   - Crypto_Key_Location contains "metadata_encryption"
#   - /metadata is mounted and has a key dir
#
# Exit 0 = success (dm+FBE ready, TWRP can proceed with restore)
# Exit 1 = failure (TWRP should abort restore)

LOG=/tmp/pre_restore_data.log
exec >>"$LOG" 2>&1
echo "===== pre_restore_data start $(date) ====="

# Is /data mounted on the dm-default-key device? (re-run / idempotency check)
# BUG FIX: the old check `grep " /data .*mapper/userdata"` NEVER matched, for two reasons:
#   1) /proc/mounts field order is `DEVICE MOUNTPOINT FSTYPE`, so the device comes BEFORE
#      " /data " - a pattern that puts mapper/userdata AFTER /data can never hit.
#   2) the device is shown as the RESOLVED node `/dev/block/dm-N`, NOT the symlink name
#      `mapper/userdata`, so matching the literal "mapper/userdata" string fails anyway.
# The only restore-ready state is /data mounted on the dm-default-key device (any /dev/block/dm-*);
# raw sda59 (plaintext) is NOT ready. Parse field 1 (device) and field 2 (mountpoint) properly.
data_on_dm() {
    while read -r _dev _mp _rest; do
        [ "$_mp" = "/data" ] || continue
        case "$_dev" in
            /dev/block/mapper/userdata|/dev/block/dm-*) return 0 ;;  # on dm-default-key = ready
            *) return 1 ;;                                            # on raw sda59 = NOT ready
        esac
    done < /proc/mounts
    return 1
}

# BUG FIX (watcher race): decrypt.sh starts the long-running `decrypt-watcher` service after the
# first successful boot mount. Its job is to auto-REMOUNT /data the instant it sees /data
# unmounted. That directly fights this hook: Step 2 unmounts /data, the watcher immediately
# remounts it on the dm device, and then Step 5b make_f2fs / Step 5c mount hit "In use by the
# system!" / "Device or resource busy" -> hook exits 1 -> restore aborts. Silence the watcher for
# the whole restore; we own /data here. (No restart: it's only a GUI-unmount convenience, and the
# user reboots into Android right after a restore anyway.)
# NOTE: decrypt.sh RE-STARTS the watcher every time it ends with /data mounted (decrypt.sh:548),
# so this must be callable repeatedly - after the idempotency check AND after the decrypt.sh
# retry loop below (warm-TA path mounts /data -> restarts the watcher right before make_f2fs).
stop_watcher() {
    [ "$(getprop init.svc.decrypt-watcher)" = "running" ] || return 0
    echo "stopping decrypt-watcher (it would remount /data and break make_f2fs)"
    setprop ctl.stop decrypt-watcher
    n=0; while [ "$n" -lt 30 ] && [ "$(getprop init.svc.decrypt-watcher)" = "running" ]; do
        n=$((n + 1)); sleep 0.1
    done
    echo "decrypt-watcher state=$(getprop init.svc.decrypt-watcher) (~$((n * 100))ms)"
}
stop_watcher

# If /data is already on the dm-default-key device, the prep is done (re-run safety)
if data_on_dm; then
    echo "/data already on dm-default-key device, FBE keys presumably in place -> OK"
    exit 0
fi

# WIP97: Ensure /metadata is mounted (mount if not)
if ! grep -qE " /metadata " /proc/mounts 2>/dev/null; then
    echo "/metadata not mounted - attempting mount"
    mount /metadata 2>/dev/null || { echo "ERROR: cannot mount /metadata"; exit 1; }
fi
KDIR=/metadata/vold/metadata_encryption/key

# WIP97: If key is missing, try to restore /metadata from backup (if available in same folder)
if [ ! -e "$KDIR/keymaster_key_blob" ]; then
    echo "metadata encryption key missing at $KDIR/keymaster_key_blob"

    # Parse backup folder from recent recovery.log "Restore folder:" line
    BACKUP_FOLDER=$(grep "Restore folder:" /tmp/recovery.log 2>/dev/null | tail -1 | sed 's/.*Restore folder: *//' | tr -d "'")

    if [ -n "$BACKUP_FOLDER" ]; then
        echo "Searching for metadata backup in: $BACKUP_FOLDER"

        # Look for metadata backup image (flashimg format: metadata.*.win*)
        META_BACKUP=$(ls "$BACKUP_FOLDER"/metadata.*.win* 2>/dev/null | head -1)

        if [ -n "$META_BACKUP" ] && [ -f "$META_BACKUP" ]; then
            echo "Found metadata backup: $META_BACKUP"
            echo "Restoring /metadata partition (this provides the encryption key)..."

            # Unmount /metadata before raw write
            umount /metadata 2>/dev/null

            # Restore metadata partition (raw block write)
            META_BLOCK=/dev/block/bootdevice/by-name/metadata
            if echo "$META_BACKUP" | grep -q '\.win[0-9]*$'; then
                # Compressed backup - decompress while writing
                pigz -d -c "$META_BACKUP" 2>&1 | dd of="$META_BLOCK" bs=1M 2>&1 | tail -3
            else
                # Uncompressed
                dd if="$META_BACKUP" of="$META_BLOCK" bs=1M 2>&1 | tail -3
            fi
            sync

            # Remount /metadata to see restored key
            mount /metadata 2>/dev/null || { echo "ERROR: cannot remount /metadata after restore"; exit 1; }

            if [ -e "$KDIR/keymaster_key_blob" ]; then
                echo "SUCCESS: metadata key restored from backup"
            else
                echo "ERROR: metadata backup restored but key still missing at $KDIR"
                exit 1
            fi
        else
            echo "WARN: no metadata backup found in $BACKUP_FOLDER"
            echo "      This is Scenario B (data-only restore after Format Data)."
            echo ""
            echo "SOLUTION: Boot Android once to generate fresh encryption keys, then return"
            echo "          to TWRP and restore /data. Android will create the metadata key,"
            echo "          and the FBE keys from your backup will work with it."
            echo ""
            echo "If you did NOT run Format Data before this restore, the existing metadata"
            echo "key should be present. Check /metadata mount and re-run decrypt.sh."
            exit 1
        fi
    else
        echo "ERROR: cannot determine backup folder (recovery.log parse failed)"
        exit 1
    fi
fi

# WIP98: Full teardown before decrypt.sh so vold can (re)create the dm-default-key
# device under the current /metadata key. The boot-time decrypt.sh already created a
# dm-default-key device named "userdata" (dm-N over sda59) keyed with the OLD metadata
# key, and TWRP's wipe remounted /data on the RAW sda59 while leaving that dm device
# orphaned in the device-mapper table. vold's create_crypto_blk_dev then fails with
# "Could not create default-key device userdata" (DM_DEV_CREATE EBUSY) -> mountFstab
# fails -> /data stays on raw sda59 -> restore writes plaintext -> bootloop. So we must
# drop the /sdcard bind, unmount /data, AND delete the orphan dm device first; then
# decrypt.sh recreates it cleanly under the (possibly just-restored) key. Mirrors the
# format_pre.sh teardown (proven live 2026-06-24).

# 1) drop the /sdcard bind (orphan mount TWRP doesn't track; it pins the dm device)
echo "Step 1: checking /sdcard mount..."
if grep -qE " /sdcard " /proc/mounts 2>/dev/null; then
    echo "/sdcard is mounted, unmounting..."
    umount /sdcard 2>&1 && echo "umount /sdcard ok" || echo "umount /sdcard failed (continuing)"
else
    echo "/sdcard not mounted, skip"
fi

# 2) unmount /data (whether on raw sda59 or the dm device)
echo "Step 2: checking /data mount..."
grep " /data " /proc/mounts || echo "/data not mounted"
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "/data is mounted, unmounting..."
    umount /data 2>&1 && echo "umount /data ok" || echo "umount /data failed (continuing)"
else
    echo "/data not mounted, skip"
fi

# 3) tear down the orphan dm-default-key device so vold can recreate it under the
#    current metadata key. dmctl ships in the A16 dump used by decrypt.sh.
echo "Step 3: checking dm-default-key device..."
ls -la /dev/block/mapper/userdata 2>&1 || echo "userdata dm device not found"
DMCTL=/decrypt/system/bin/dmctl
echo "DMCTL path: $DMCTL, exists: $([ -x "$DMCTL" ] && echo yes || echo no)"
if [ -e /dev/block/mapper/userdata ] && [ -x "$DMCTL" ]; then
    echo "Deleting orphan dm device userdata..."
    LD_LIBRARY_PATH=/decrypt/system/lib64:/decrypt/system/bin "$DMCTL" delete userdata 2>&1 \
        && echo "dmctl delete userdata ok" || echo "dmctl delete userdata failed (exit $?)"
else
    echo "Skip dmctl: userdata not exists or dmctl not executable"
fi

# 4) confirm the raw userdata block is free (no holders = ready for fresh dm)
echo "Step 4: final /data mount check..."
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "ERROR: /data still mounted after teardown - cannot proceed"
    grep " /data " /proc/mounts
    exit 1
else
    echo "/data unmounted, ready for decrypt.sh"
fi

# Run the decrypt.sh A16 stack to setup dm-default-key. The full decrypt.sh does:
#   - mounts /decrypt (system_a) + /vendor
#   - brings up A16 servicemanager/qseecomd/keymint/keystore2/bootctl/vold
#   - calls `vdc cryptfs mountFstab` which builds dm-default-key and mounts /data on it
# We need ONLY the mountFstab part; the stack should already be up from an earlier
# manual decrypt (or we start it now). Idempotent.
#
# WIP100: decrypt.sh will FAIL to mount /data if sda59 contains f2fs metadata encrypted
# under a DIFFERENT key (e.g., after restore /metadata changed the key but TWRP's
# "Wiping Data" did not reformat sda59 - it only rm'd files). So we SKIP the mount
# part (tell decrypt.sh to setup dm only) and format+mount ourselves.
echo "Step 5: running decrypt.sh to recreate dm-default-key (skip mount)..."
# BUG FIX (cold-TA): the FIRST decrypt.sh after a fresh TWRP boot hits a cold KeyMint TA -
# `vdc cryptfs mountFstab` returns Status(-8) and the dm-default-key device is NOT built. A
# second run (TA now warm) builds it. So retry decrypt.sh until mapper/userdata appears (up to
# 3 attempts). Without this, the very first restore after a reboot always fails at Step 5b.
attempt=0
while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    echo "decrypt.sh attempt $attempt..."
    /system/bin/decrypt.sh 2>&1 | tail -20
    if [ -e /dev/block/mapper/userdata ]; then
        echo "dm-default-key device present after attempt $attempt"
        break
    fi
    echo "WARN: mapper/userdata absent after attempt $attempt (cold TA?) - retrying"
    # the watcher may have been (re)started by decrypt.sh's tail end - silence it again
    stop_watcher
    sleep 1
done

# decrypt.sh restarts the watcher whenever it ends with /data mounted (warm-TA path). Silence it
# again NOW, unconditionally, before we unmount + make_f2fs - otherwise it races a remount back in
# the ~0.1s between our umount and make_f2fs and we hit "In use by the system!" anyway.
stop_watcher

# WIP100: Format /data THROUGH the dm device so the new f2fs superblock is encrypted
# under the CURRENT metadata key. TWRP's "Wiping Data" only rm'd files; it left the
# old superblock encrypted under the OLD key -> mountFstab saw garbage -> failed.
echo "Step 5b: formatting /data through dm-default-key (NEW key encrypts superblock)..."
if [ ! -e /dev/block/mapper/userdata ]; then
    echo "ERROR: /dev/block/mapper/userdata not created by decrypt.sh"
    exit 1
fi
# BUG FIX ("In use by the system!"): on a WARM TA, decrypt.sh's own mountFstab can succeed and
# leave /data mounted on the dm device. make_f2fs on a mounted device then fails with "In use by
# the system!" and the subsequent mount fails with "Device or resource busy". Unmount /data first
# (the watcher is silenced above, so it won't race a remount back in). data_on_dm at the top
# already returned for the genuine "already prepared" case, so any mount here is stale and safe to
# drop before we reformat under the current key.
if grep -qE " /data " /proc/mounts 2>/dev/null; then
    echo "/data is mounted before make_f2fs - unmounting (decrypt.sh mounted it on a warm TA)"
    umount /data 2>&1 && echo "umount /data ok" || echo "umount /data failed"
fi
# Format through the mapper device (NOT raw sda59) so kernel encrypts with current key
if ! /system/bin/make_f2fs -O encrypt,extra_attr,compression,verity /dev/block/mapper/userdata 2>&1 | tail -10; then
    echo "ERROR: make_f2fs failed on dm-default-key device"
    exit 1
fi
echo "make_f2fs completed on dm-default-key device"

# Mount /data on the dm device.
# CRITICAL: the 'inlinecrypt' option is MANDATORY. The FBE keys on this device are
# HW-wrapped (mode wrappedkey_v0), and FS_IOC_ADD_ENCRYPTION_KEY with FLAG_HW_WRAPPED
# returns errno=95 (EOPNOTSUPP "not supported on transport endpoint") if /data is NOT
# mounted with inline crypto. Without it the staged de_keyinstall in Restore_Tar cannot
# install DK -> /data/misc stays locked -> extractGlob fails on the first encrypted dir
# -> ERROR 255. The live vold mountFstab path always includes inlinecrypt; this manual
# mount must match it. (Proven: errno=95 disappears the moment /data has inlinecrypt.)
echo "Step 5c: mounting /data on dm-default-key (with inlinecrypt for HW-wrapped FBE)..."
if ! mount -t f2fs -o rw,lazytime,seclabel,nosuid,nodev,noatime,inlinecrypt /dev/block/mapper/userdata /data 2>&1; then
    echo "ERROR: mount /data on dm-default-key failed"
    exit 1
fi

# Verify /data is now on the dm-default-key device (use the robust field-parsing check, NOT a
# literal "mapper/userdata" string match - /proc/mounts shows the resolved /dev/block/dm-N node)
echo "Step 6: verifying /data is on the dm-default-key device..."
grep " /data " /proc/mounts || echo "ERROR: /data not mounted at all"
if ! data_on_dm; then
    echo "ERROR: /data not on dm-default-key device after mount"
    grep " /data " /proc/mounts
    exit 1
fi
echo "/data successfully mounted on dm-default-key device"

# WIP110: FBE keys are NO LONGER installed here. /data was just formatted (empty), so the key
# material (/data/unencrypted/key, /data/misc/.../user_keys, spblob, locksettings.db) is NOT on
# disk yet - it lives in the backup tar and is extracted later. A de_keyinstall call here always
# failed with "missing key material" and left the keyring empty, which then broke the main restore
# (libtar applies an fscrypt policy to each dir, but writing into a policy'd dir with no key in the
# keyring fails ENOKEY -> "tar_extract_file failed" -> ERROR 255). The keys are now loaded by the
# STAGED preload in partition.cpp::Restore_Tar() (WIP110): it extracts the key material from the
# tar in dependency order (unencrypted -> DK, misc -> DE0, system_de+locksettings -> CE0), running
# de_keyinstall after each stage, BEFORE the full extract. So this hook only has to leave /data
# mounted on the dm-default-key device, which it has done above.

echo "===== pre_restore_data done: /data on dm-mapper, ready for staged tar restore ====="
exit 0
