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

# Metadata must be mounted and contain the encryption key
if ! grep -qE " /metadata " /proc/mounts 2>/dev/null; then
    echo "ERROR: /metadata not mounted - cannot read encryption key"
    exit 1
fi
KDIR=/metadata/vold/metadata_encryption/key
if [ ! -e "$KDIR/keymaster_key_blob" ]; then
    echo "ERROR: $KDIR/keymaster_key_blob missing - no metadata encryption key"
    exit 1
fi

# Unmount /data if it's on the raw block (sda59) - we'll remount on the dm device
if grep -qE " /data .*sda59" /proc/mounts 2>/dev/null; then
    echo "Unmounting /data (currently on raw sda59)"
    umount /data 2>/dev/null || { echo "ERROR: failed to unmount /data"; exit 1; }
fi

# Run the decrypt.sh A16 stack to setup dm-default-key. The full decrypt.sh does:
#   - mounts /decrypt (system_a) + /vendor
#   - brings up A16 servicemanager/qseecomd/keymint/keystore2/bootctl/vold
#   - calls `vdc cryptfs mountFstab` which builds dm-default-key and mounts /data on it
# We need ONLY the mountFstab part; the stack should already be up from an earlier
# manual decrypt (or we start it now). Idempotent.
if ! /system/bin/decrypt.sh; then
    echo "ERROR: decrypt.sh failed to setup dm-default-key"
    exit 1
fi

# Verify /data is now on the mapper device
if ! grep -qE " /data .*mapper/userdata" /proc/mounts 2>/dev/null; then
    echo "ERROR: /data not on mapper/userdata after decrypt.sh"
    grep " /data " /proc/mounts
    exit 1
fi

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
