#!/usr/bin/env bash
# log_rotation_utils.sh - Common log rotation utilities for Wi-Fi Dashboard
# Source this file in other scripts to enable log rotation
#
# This file should be placed at: /home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh
# Usage: source this file in other scripts, then use the log rotation functions

# Configuration
MAX_LOG_SIZE_MB=${MAX_LOG_SIZE_MB:-10}    # Maximum log file size in MB
KEEP_BACKUPS=${KEEP_BACKUPS:-5}           # Number of backup files to keep
LOG_ROTATION_CHECK_INTERVAL=${LOG_ROTATION_CHECK_INTERVAL:-100}  # Check every N log writes

# Global counter for rotation checks
LOG_WRITE_COUNTER=0

# Function to rotate a log file if it's too large
rotate_log_if_needed() {
    local log_file="$1"
    local max_size_mb="${2:-$MAX_LOG_SIZE_MB}"
    local keep_backups="${3:-$KEEP_BACKUPS}"
    
    # Only check size periodically to avoid too much overhead
    ((LOG_WRITE_COUNTER++))
    if [[ $((LOG_WRITE_COUNTER % LOG_ROTATION_CHECK_INTERVAL)) -ne 0 ]]; then
        return 0
    fi
    
    # Check if log file exists and get its size
    if [[ ! -f "$log_file" ]]; then
        return 0
    fi
    
    # Get file size in MB (using stat or du as fallback)
    local size_mb
    if command -v stat >/dev/null 2>&1; then
        # Linux stat
        local size_bytes=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        size_mb=$((size_bytes / 1024 / 1024))
    else
        # Fallback to du
        size_mb=$(du -m "$log_file" 2>/dev/null | cut -f1 || echo "0")
    fi
    
    # Check if rotation is needed
    if [[ $size_mb -lt $max_size_mb ]]; then
        return 0
    fi
    
    echo "[$(date '+%F %T')] LOG-ROTATION: Log file $log_file is ${size_mb}MB, rotating..."
    
    # Rotate existing backups
    for ((i=keep_backups-1; i>=1; i--)); do
        local old_backup="${log_file}.${i}"
        local new_backup="${log_file}.$((i+1))"
        
        if [[ -f "$old_backup" ]]; then
            if [[ $i -eq $((keep_backups-1)) ]]; then
                # Remove the oldest backup
                rm -f "$old_backup"
                echo "[$(date '+%F %T')] LOG-ROTATION: Removed oldest backup: $old_backup"
            else
                # Move backup to next number
                mv "$old_backup" "$new_backup"
                echo "[$(date '+%F %T')] LOG-ROTATION: Moved $old_backup to $new_backup"
            fi
        fi
    done
    
    # Move current log to .1
    if [[ -f "$log_file" ]]; then
        mv "$log_file" "${log_file}.1"
        echo "[$(date '+%F %T')] LOG-ROTATION: Moved current log to ${log_file}.1"
        
        # Create new empty log file with same permissions
        touch "$log_file"
        chmod 664 "$log_file" 2>/dev/null || true
        
        echo "[$(date '+%F %T')] LOG-ROTATION: Created new log file: $log_file"
        echo "[$(date '+%F %T')] LOG-ROTATION: Rotation completed successfully"
    fi
    
    # Reset counter after rotation
    LOG_WRITE_COUNTER=0
}

# Enhanced logging function with automatic rotation
log_msg_with_rotation() {
    local log_file="$1"
    local message="$2"
    local component="${3:-SYSTEM}"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    
    # Write the log message
    echo "[$(date '+%F %T')] $component: $message" | tee -a "$log_file"
    
    # Check if rotation is needed (only periodically for performance)
    rotate_log_if_needed "$log_file"
}

# Simple function for scripts that want to use their existing log_msg function
enable_log_rotation_for_file() {
    local log_file="$1"
    
    # This can be called after writing to a log file to check rotation
    rotate_log_if_needed "$log_file"
}

# Function to clean up very old backup files (older than X days)
cleanup_old_log_backups() {
    local log_dir="$1"
    local days_to_keep="${2:-30}"
    
    if [[ ! -d "$log_dir" ]]; then
        return 0
    fi
    
    # Find and remove backup files older than specified days
    find "$log_dir" -name "*.log.*" -type f -mtime "+$days_to_keep" -delete 2>/dev/null || true
    
    echo "[$(date '+%F %T')] LOG-CLEANUP: Cleaned backup files older than $days_to_keep days from $log_dir"
}

# Function to get log file size in human readable format
get_log_size() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        echo "0B"
        return
    fi
    
    local size_bytes
    if command -v stat >/dev/null 2>&1; then
        size_bytes=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
    else
        size_bytes=$(wc -c < "$log_file" 2>/dev/null || echo "0")
    fi
    
    # Convert to human readable
    if [[ $size_bytes -lt 1024 ]]; then
        echo "${size_bytes}B"
    elif [[ $size_bytes -lt 1048576 ]]; then
        echo "$((size_bytes / 1024))KB"
    else
        echo "$((size_bytes / 1024 / 1024))MB"
    fi
}

# Function to show log rotation status
show_log_rotation_status() {
    local log_file="$1"
    
    echo "Log rotation status for: $log_file"
    echo "  Current size: $(get_log_size "$log_file")"
    echo "  Max size before rotation: ${MAX_LOG_SIZE_MB}MB"
    echo "  Backup files to keep: $KEEP_BACKUPS"
    echo "  Check interval: every $LOG_ROTATION_CHECK_INTERVAL writes"
    
    # List existing backup files
    local backup_count=0
    for ((i=1; i<=KEEP_BACKUPS; i++)); do
        local backup_file="${log_file}.${i}"
        if [[ -f "$backup_file" ]]; then
            echo "  Backup $i: $(get_log_size "$backup_file")"
            ((backup_count++))
        fi
    done
    
    if [[ $backup_count -eq 0 ]]; then
        echo "  No backup files found"
    fi
}

# Export functions so they can be used by scripts that source this file
export -f rotate_log_if_needed
export -f log_msg_with_rotation  
export -f enable_log_rotation_for_file
export -f cleanup_old_log_backups
export -f get_log_size
export -f show_log_rotation_status