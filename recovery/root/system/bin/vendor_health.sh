#!/system/bin/sh
# Vendor partition health check script for TWRP
# This script performs comprehensive vendor partition health checks

LOG_FILE="/tmp/vendor_health.log"
VENDOR_MOUNT="/vendor"
HEALTH_STATUS_FILE="/tmp/vendor_health_status"

echo "$(date): Starting vendor partition health check..." > $LOG_FILE

# Function to check vendor partition health
check_vendor_health() {
    local health_score=100
    local issues=""
    
    echo "$(date): Performing comprehensive vendor health check..." >> $LOG_FILE
    
    # Check 1: Mount status
    if ! mountpoint -q $VENDOR_MOUNT; then
        health_score=$((health_score - 30))
        issues="$issues MOUNT_FAILED"
        echo "$(date): CRITICAL: Vendor partition not mounted!" >> $LOG_FILE
    else
        echo "$(date): ✓ Vendor partition mounted successfully" >> $LOG_FILE
    fi
    
    # Check 2: Read access
    if ! ls $VENDOR_MOUNT >/dev/null 2>&1; then
        health_score=$((health_score - 25))
        issues="$issues READ_ACCESS_DENIED"
        echo "$(date): CRITICAL: Cannot read vendor partition!" >> $LOG_FILE
    else
        echo "$(date): ✓ Vendor partition is readable" >> $LOG_FILE
    fi
    
    # Check 3: Critical directories
    local critical_dirs="bin lib lib64 etc"
    local missing_dirs=0
    for dir in $critical_dirs; do
        if [ ! -d "$VENDOR_MOUNT/$dir" ]; then
            missing_dirs=$((missing_dirs + 1))
            issues="$issues MISSING_$dir"
            echo "$(date): WARNING: Critical directory $dir is missing!" >> $LOG_FILE
        fi
    done
    health_score=$((health_score - (missing_dirs * 5)))
    
    if [ $missing_dirs -eq 0 ]; then
        echo "$(date): ✓ All critical directories present" >> $LOG_FILE
    fi
    
    # Check 4: File count validation
    if [ -d "$VENDOR_MOUNT/bin" ]; then
        local bin_files=$(find "$VENDOR_MOUNT/bin" -type f 2>/dev/null | wc -l)
        if [ $bin_files -lt 10 ]; then
            health_score=$((health_score - 10))
            issues="$issues LOW_BIN_FILES"
            echo "$(date): WARNING: Low number of binary files ($bin_files)" >> $LOG_FILE
        else
            echo "$(date): ✓ Binary files count: $bin_files" >> $LOG_FILE
        fi
    fi
    
    # Check 5: Partition space
    if [ -d "$VENDOR_MOUNT" ]; then
        local free_space=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $4}')
        local total_space=$(df $VENDOR_MOUNT 2>/dev/null | tail -1 | awk '{print $2}')
        local usage_percent=$((100 - (free_space * 100 / total_space)))
        
        if [ $usage_percent -gt 95 ]; then
            health_score=$((health_score - 15))
            issues="$issues HIGH_USAGE"
            echo "$(date): WARNING: High partition usage: ${usage_percent}%" >> $LOG_FILE
        else
            echo "$(date): ✓ Partition usage: ${usage_percent}%" >> $LOG_FILE
        fi
    fi
    
    # Check 6: Block device integrity
    if [ ! -b "/dev/block/platform/soc/1d84000.ufshc/by-name/vendor" ]; then
        health_score=$((health_score - 20))
        issues="$issues BLOCK_DEVICE_MISSING"
        echo "$(date): CRITICAL: Vendor block device not found!" >> $LOG_FILE
    else
        echo "$(date): ✓ Vendor block device exists" >> $LOG_FILE
    fi
    
    # Ensure health score doesn't go below 0
    if [ $health_score -lt 0 ]; then
        health_score=0
    fi
    
    # Determine health status
    local health_status="UNKNOWN"
    if [ $health_score -ge 90 ]; then
        health_status="EXCELLENT"
    elif [ $health_score -ge 75 ]; then
        health_status="GOOD"
    elif [ $health_score -ge 50 ]; then
        health_status="FAIR"
    elif [ $health_score -ge 25 ]; then
        health_status="POOR"
    else
        health_status="CRITICAL"
    fi
    
    # Save health status
    echo "HEALTH_SCORE=$health_score" > $HEALTH_STATUS_FILE
    echo "HEALTH_STATUS=$health_status" >> $HEALTH_STATUS_FILE
    echo "ISSUES=$issues" >> $HEALTH_STATUS_FILE
    echo "TIMESTAMP=$(date)" >> $HEALTH_STATUS_FILE
    
    # Log final results
    echo "$(date): ========================================" >> $LOG_FILE
    echo "$(date): VENDOR PARTITION HEALTH CHECK COMPLETED" >> $LOG_FILE
    echo "$(date): Health Score: $health_score/100" >> $LOG_FILE
    echo "$(date): Health Status: $health_status" >> $LOG_FILE
    echo "$(date): Issues Found: $issues" >> $LOG_FILE
    echo "$(date): ========================================" >> $LOG_FILE
    
    # Log to dmesg for system visibility
    echo "Vendor health check: Score=$health_score, Status=$health_status, Issues=$issues" > /dev/kmsg 2>/dev/null
    
    return $health_score
}

# Run health check
check_vendor_health
health_exit_code=$?

# Exit with health score as exit code (0-100)
exit $health_exit_code
