#!/system/bin/sh
# Vendor partition status display script for TWRP
# This script shows current vendor partition monitoring status

echo "=========================================="
echo "VENDOR PARTITION MONITORING STATUS"
echo "=========================================="

# Check if monitoring is active
if getprop vendor.twrp.monitoring >/dev/null 2>&1; then
    echo "✓ Monitoring: ACTIVE"
else
    echo "✗ Monitoring: INACTIVE"
fi

# Check vendor partition mount status
if mountpoint -q /vendor; then
    echo "✓ Vendor: MOUNTED"
    
    # Show partition info
    if [ -d /vendor ]; then
        local total_space=$(df /vendor 2>/dev/null | tail -1 | awk '{print $2}')
        local free_space=$(df /vendor 2>/dev/null | tail -1 | awk '{print $4}')
        local used_space=$((total_space - free_space))
        local usage_percent=$((used_space * 100 / total_space))
        
        echo "  Total: ${total_space}KB"
        echo "  Used: ${used_space}KB (${usage_percent}%)"
        echo "  Free: ${free_space}KB"
    fi
else
    echo "✗ Vendor: NOT MOUNTED"
fi

# Show monitoring logs
echo ""
echo "RECENT MONITORING LOGS:"
echo "-----------------------"

if [ -f "/tmp/vendor_monitor.log" ]; then
    echo "Monitor Log (last 10 lines):"
    tail -10 /tmp/vendor_monitor.log 2>/dev/null || echo "  No recent monitor logs"
else
    echo "  Monitor log not found"
fi

if [ -f "/tmp/vendor_check.log" ]; then
    echo ""
    echo "Check Log (last 5 lines):"
    tail -5 /tmp/vendor_check.log 2>/dev/null || echo "  No recent check logs"
else
    echo "  Check log not found"
fi

if [ -f "/tmp/vendor_health.log" ]; then
    echo ""
    echo "Health Log (last 5 lines):"
    tail -5 /tmp/vendor_health.log 2>/dev/null || echo "  No recent health logs"
else
    echo "  Health log not found"
fi

# Show health status if available
if [ -f "/tmp/vendor_health_status" ]; then
    echo ""
    echo "CURRENT HEALTH STATUS:"
    echo "----------------------"
    cat /tmp/vendor_health_status 2>/dev/null
fi

# Show running processes
echo ""
echo "RUNNING MONITORING PROCESSES:"
echo "-----------------------------"
if pgrep -f "vendor_monitor" >/dev/null; then
    echo "✓ Vendor monitor: RUNNING"
    pgrep -f "vendor_monitor" | while read pid; do
        echo "  PID: $pid"
    done
else
    echo "✗ Vendor monitor: NOT RUNNING"
fi

if pgrep -f "vendor_check" >/dev/null; then
    echo "✓ Vendor check: RUNNING"
    pgrep -f "vendor_check" | while read pid; do
        echo "  PID: $pid"
    done
else
    echo "✗ Vendor check: NOT RUNNING"
fi

if pgrep -f "vendor_health" >/dev/null; then
    echo "✓ Vendor health: RUNNING"
    pgrep -f "vendor_health" | while read pid; do
        echo "  PID: $pid"
    done
else
    echo "✗ Vendor health: NOT RUNNING"
fi

echo ""
echo "=========================================="
