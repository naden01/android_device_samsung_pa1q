#!/system/bin/sh
# Vendor partition monitoring script for TWRP
# This script monitors the vendor partition and logs any changes

LOG_FILE="/tmp/vendor_monitor.log"
VENDOR_MOUNT="/vendor"
CHECK_INTERVAL=30

# Create log file
echo "$(date): Vendor monitoring started" > $LOG_FILE

# Function to check vendor partition status
check_vendor_status() {
    local timestamp=$(date)
    
    # Only check if vendor is mounted
    if ! mountpoint -q $VENDOR_MOUNT; then
        echo "$timestamp: Vendor not mounted yet - skipping check" >> $LOG_FILE
        return 0
    fi
    
    local mount_status=$(mount | grep "$VENDOR_MOUNT" 2>/dev/null)
    local partition_size=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $2}')
    local free_space=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $4}')
    local inode_usage=$(df -i $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $5}')
    
    echo "$timestamp: Vendor mount status: $mount_status" >> $LOG_FILE
    echo "$timestamp: Partition size: ${partition_size}KB, Free space: ${free_space}KB" >> $LOG_FILE
    echo "$timestamp: Inode usage: $inode_usage" >> $LOG_FILE
    
    # Check for any new files in vendor
    if [ -d "$VENDOR_MOUNT" ]; then
        local file_count=$(find $VENDOR_MOUNT -type f 2>/dev/null | wc -l)
        echo "$timestamp: Total files in vendor: $file_count" >> $LOG_FILE
    fi
    
    # Check vendor partition integrity
    if [ -b "/dev/block/platform/soc/1d84000.ufshc/by-name/vendor" ]; then
        echo "$timestamp: Vendor partition block device exists" >> $LOG_FILE
    else
        echo "$timestamp: WARNING: Vendor partition block device not found!" >> $LOG_FILE
    fi
    
    echo "----------------------------------------" >> $LOG_FILE
}

# Function to check for vendor partition corruption
check_vendor_integrity() {
    local timestamp=$(date)
    
    # Check if vendor is mounted and accessible
    if ! mountpoint -q $VENDOR_MOUNT; then
        echo "$timestamp: Vendor not mounted yet - skipping integrity check" >> $LOG_FILE
        return 0
    fi
    
    # Check if we can read vendor directory
    if ! ls $VENDOR_MOUNT >/dev/null 2>&1; then
        echo "$timestamp: ERROR: Cannot read vendor partition!" >> $LOG_FILE
        return 1
    fi
    
    # Check for critical vendor files
    local critical_files="bin lib lib64 etc"
    for dir in $critical_files; do
        if [ -d "$VENDOR_MOUNT/$dir" ]; then
            echo "$timestamp: Critical directory $dir exists" >> $LOG_FILE
        else
            echo "$timestamp: WARNING: Critical directory $dir missing!" >> $LOG_FILE
        fi
    done
    
    return 0
}

# Main monitoring loop
echo "$(date): Starting vendor partition monitoring..." >> $LOG_FILE

# Initial check - non-blocking
check_vendor_status
check_vendor_integrity

# Continuous monitoring in background
while true; do
    sleep $CHECK_INTERVAL
    
    # Check if TWRP is still running
    if ! pgrep -f "recovery" >/dev/null; then
        echo "$(date): TWRP recovery stopped, exiting monitor" >> $LOG_FILE
        break
    fi
    
    # Perform checks
    check_vendor_status
    check_vendor_integrity
    
    # Log to dmesg for system visibility
    echo "Vendor monitor: $(tail -5 $LOG_FILE | grep -v "----------------------------------------")" > /dev/kmsg 2>/dev/null
done

echo "$(date): Vendor monitoring stopped" >> $LOG_FILE
