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

# If /data is already mounted on the mapper device, we're done (re-run safety)
if grep -qE " /data .*mapper/userdata" /proc/mounts 2>/dev/null; then
    echo "/data already on dm-mapper, FBE keys presumably in place -> OK"
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
echo "Step 5: running decrypt.sh to recreate dm-default-key under current metadata key..."
if ! /system/bin/decrypt.sh 2>&1 | tail -20; then
    echo "ERROR: decrypt.sh failed to setup dm-default-key (exit $?)"
    echo "See /tmp/decrypt.log for vold mountFstab error"
    exit 1
fi

# Verify /data is now on the mapper device
echo "Step 6: verifying /data is on mapper/userdata..."
grep " /data " /proc/mounts || echo "ERROR: /data not mounted at all"
if ! grep -qE " /data .*mapper/userdata" /proc/mounts 2>/dev/null; then
    echo "ERROR: /data not on mapper/userdata after decrypt.sh"
    grep " /data " /proc/mounts
    exit 1
fi
echo "/data successfully mounted on dm-default-key device"

# Install FBE keys (DE+CE) so libtar's FS_IOC_SET_ENCRYPTION_POLICY succeeds.
# de_keyinstall reads /data/unencrypted/key (systemwide DE) + /data/misc/vold/user_keys
# (user-0 DE+CE) and installs all three layers into the kernel fscrypt keyring.
# Non-destructive (keyring-only, per-boot).
if [ -x /system/bin/de_keyinstall ]; then
    echo "Installing FBE keys (de_keyinstall)"
    SYS=/decrypt
    LK="$SYS/system/bin/bootstrap/linker64"
    LIBS="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"
    ( export LD_LIBRARY_PATH="$LIBS" ANDROID_DATA=/data ANDROID_ROOT=/system
      exec "$LK" /system/bin/de_keyinstall ) 2>&1 | tail -20
    # Don't fail restore if FBE key install partially fails - the metadata layer is
    # the critical one (re-encrypts data under the current key). FBE policy restore
    # may warn but TWRP libtar ignores fscrypt_policy_set errors anyway.
else
    echo "WARN: /system/bin/de_keyinstall not found - FBE keys NOT installed"
    echo "      libtar will fail to set FBE policies, but metadata layer IS encrypted"
fi

echo "===== pre_restore_data done: /data on dm-mapper, ready for tar restore ====="
exit 0
