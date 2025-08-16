#!/system/bin/sh
# Quick vendor partition check script for TWRP startup
# This script performs initial vendor partition validation without blocking boot

LOG_FILE="/tmp/vendor_check.log"
VENDOR_MOUNT="/vendor"

echo "$(date): Starting vendor partition initial check..." > $LOG_FILE

# Quick non-blocking check - don't wait for vendor
if mountpoint -q $VENDOR_MOUNT; then
    echo "$(date): Vendor partition already mounted" >> $LOG_FILE
    # Quick status check
    local mount_info=$(mount | grep "$VENDOR_MOUNT")
    echo "$(date): Mount info: $mount_info" >> $LOG_FILE
    
    # Check partition size quickly
    local partition_size=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $2}')
    local free_space=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $4}')
    echo "$(date): Partition size: ${partition_size}KB, Free space: ${free_space}KB" >> $LOG_FILE
    
    echo "$(date): Vendor partition check completed successfully" >> $LOG_FILE
else
    echo "$(date): Vendor partition not mounted yet - will check later" >> $LOG_FILE
    # Don't block boot - just log and continue
fi

# Log to dmesg for system visibility
echo "Vendor check completed: $(tail -5 $LOG_FILE)" > /dev/kmsg 2>/dev/null
