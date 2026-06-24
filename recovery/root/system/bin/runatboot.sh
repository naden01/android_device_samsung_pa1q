#!/system/bin/sh
# Auto-mount every partition TWRP and the recovery HALs need, at boot.
#
# Everything here is best-effort and READ-ONLY: a failure must never block
# startup, and we never touch /data or /metadata - those are owned by the FBE
# decrypt flow (see decrypt_hals.sh). TWRP will remount anything rw on demand
# when the user actually operates on it from the UI.

LOG=/tmp/runatboot.log
exec >>"$LOG" 2>&1
echo "===== runatboot start ====="

UFS=/dev/block/platform/soc/1d84000.ufshc/by-name

# already_mounted <mount_point>
already_mounted() {
    grep -q " $1 " /proc/mounts 2>/dev/null
}

# mnt_fstab <mount_point>
# Mount a partition that TWRP already knows from its fstab (the logical
# system-class partitions). Proven to resolve via the recovery fstab.
mnt_fstab() {
    mp="$1"
    already_mounted "$mp" && { echo "already mounted: $mp"; return; }
    [ -d "$mp" ] || mkdir -p "$mp" 2>/dev/null
    if mount -o ro "$mp" 2>/dev/null; then
        echo "mounted (fstab) $mp"
    else
        echo "note: could not mount $mp"
    fi
}

# mnt_dev <by-name> <mount_point>
# Mount a physical partition by its by-name block device, read-only. Tries the
# UFS path used across this tree, then the generic by-name aliases.
mnt_dev() {
    name="$1"; mp="$2"
    already_mounted "$mp" && { echo "already mounted: $mp"; return; }
    [ -d "$mp" ] || mkdir -p "$mp" 2>/dev/null
    for src in "$UFS/$name" /dev/block/by-name/"$name" \
               /dev/block/bootdevice/by-name/"$name"; do
        [ -e "$src" ] || continue
        if mount -o ro "$src" "$mp" 2>/dev/null; then
            echo "mounted $name -> $mp"
            return
        fi
    done
    echo "note: could not mount $name -> $mp"
}

# --- Logical, read-only system-class partitions (super / dm-mapper) ---------
mnt_fstab /system
mnt_fstab /vendor
mnt_fstab /odm
mnt_fstab /product
mnt_fstab /system_ext
mnt_fstab /system_dlkm
mnt_fstab /vendor_dlkm

# --- Physical utility partitions (read-only) --------------------------------
mnt_dev cache   /cache

echo "===== runatboot done ====="
