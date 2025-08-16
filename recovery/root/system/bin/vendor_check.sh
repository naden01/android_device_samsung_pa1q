#!/system/bin/sh
# Quick vendor partition check script for TWRP startup
# This script performs initial vendor partition validation

LOG_FILE="/tmp/vendor_check.log"
VENDOR_MOUNT="/vendor"

echo "$(date): Starting vendor partition initial check..." > $LOG_FILE

# Wait for vendor partition to be mounted
echo "$(date): Waiting for vendor partition to mount..." >> $LOG_FILE
for i in $(seq 1 10); do
    if mountpoint -q $VENDOR_MOUNT; then
        echo "$(date): Vendor partition mounted successfully" >> $LOG_FILE
        break
    fi
    echo "$(date): Attempt $i: Vendor not mounted yet, waiting..." >> $LOG_FILE
    sleep 2
done

# Check vendor partition status
if mountpoint -q $VENDOR_MOUNT; then
    echo "$(date): Vendor partition is mounted" >> $LOG_FILE
    
    # Get partition info
    local mount_info=$(mount | grep "$VENDOR_MOUNT")
    echo "$(date): Mount info: $mount_info" >> $LOG_FILE
    
    # Check partition size
    local partition_size=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $2}')
    local free_space=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $4}')
    echo "$(date): Partition size: ${partition_size}KB, Free space: ${free_space}KB" >> $LOG_FILE
    
    # Check critical directories
    local critical_dirs="bin lib lib64 etc"
    for dir in $critical_dirs; do
        if [ -d "$VENDOR_MOUNT/$dir" ]; then
            local file_count=$(find "$VENDOR_MOUNT/$dir" -type f 2>/dev/null | wc -l)
            echo "$(date): Directory $dir exists with $file_count files" >> $LOG_FILE
        else
            echo "$(date): WARNING: Critical directory $dir is missing!" >> $LOG_FILE
        fi
    done
    
    # Check vendor partition block device
    if [ -b "/dev/block/platform/soc/1d84000.ufshc/by-name/vendor" ]; then
        echo "$(date): Vendor block device exists" >> $LOG_FILE
    else
        echo "$(date): ERROR: Vendor block device not found!" >> $LOG_FILE
    fi
    
    echo "$(date): Vendor partition check completed successfully" >> $LOG_FILE
else
    echo "$(date): ERROR: Vendor partition failed to mount!" >> $LOG_FILE
    echo "$(date): Available mounts:" >> $LOG_FILE
    mount >> $LOG_FILE 2>&1
fi

# Log to dmesg for system visibility
echo "Vendor check completed: $(tail -10 $LOG_FILE)" > /dev/kmsg 2>/dev/null
