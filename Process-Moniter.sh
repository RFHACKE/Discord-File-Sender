#!/bin/bash

# Default values for configuration
LOG_FILE="/var/log/oom_monitor.log" # Log file for this script's activities
LAST_READ_LOG_TIMESTAMP_FILE="/tmp/oom_monitor_last_timestamp.txt" # Stores timestamp of last successful read
OOM_NOTIFICATION_SENT_FLAG="/tmp/oom_notification_sent_flag.txt" # Flag to prevent duplicate notifications for the same event


WEBHOOK_URL="" # This will be set by the -h flag

# --- Usage function ---
usage() {
    echo "Usage: $0 -h <webhook_url>"
    echo "  -h <webhook_url>  The webhook URL to send notifications to via file_sender.sh."
    exit 1
}

# --- Argument Parsing ---
while getopts "h:" opt; do
    case "$opt" in
        h)
            WEBHOOK_URL="$OPTARG"
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

# Check if webhook URL is provided
if [ -z "$WEBHOOK_URL" ]; then
    echo "Error: Webhook URL is required." | tee -a "$LOG_FILE"
    usage
fi

# --- Function to send notification ---
send_oom_notification() {
    local message="$1"
    local timestamp="$2"
    local process_info="$3"

    echo "$(date +'%Y-%m-%d %H:%M:%S'): Sending OOM notification: $message" >> "$LOG_FILE"

    # Create a temporary file with details
    local temp_oom_details_file=$(mktemp)
    echo "OOM Killer Event Detected!" > "$temp_oom_details_file"
    echo "Timestamp: $timestamp" >> "$temp_oom_details_file"
    echo "Message: $message" >> "$temp_oom_details_file"
    echo "Process Details: $process_info" >> "$temp_oom_details_file"
    echo "Monitoring time (PKT): $(date +'%Y-%m-%d %H:%M:%S %Z')" >> "$temp_oom_details_file"
    echo "Location: Hetzner Vps" >> "$temp_oom_details_file"

    
        file_sender.sh -f "$temp_oom_details_file" -n "OOM_Killer_Alert_$(date +%Y%m%d%H%M%S)" \
            -m "Process Killed by OOM Killer on $(hostname)" -h "$WEBHOOK_URL"
    
    rm -f "$temp_oom_details_file"
}

# --- Main Logic ---
echo "$(date +'%Y-%m-%d %H:%M:%S'): OOM Monitor starting with webhook: $WEBHOOK_URL" >> "$LOG_FILE"

# Get the last read timestamp, or default to a safe past value
LAST_TIMESTAMP=$(cat "$LAST_READ_LOG_TIMESTAMP_FILE" 2>/dev/null || echo "1970-01-01 00:00:00")

# Use journalctl to get kernel messages since the last timestamp, specifically looking for OOM killer events
journalctl --since="$LAST_TIMESTAMP" -t kernel -g "Killed process" -g "Out of memory" | while IFS= read -r line; do
    # Skip lines that are not clearly OOM killer related, or if it's just a general memory warning
    if echo "$line" | grep -q "Out of memory: Killed process"; then
        # Extract timestamp from the journalctl output (e.g., "Jun 21 08:27:40 hostname kernel: ")
        # Adjust this awk command based on your journalctl output format if needed
        TIMESTAMP=$(echo "$line" | awk '{print $1" "$2" "$3}') 
        
        # Check if this particular event has already been notified
        EVENT_HASH=$(echo "$line" | sha256sum | awk '{print $1}')
        if grep -q "$EVENT_HASH" "$OOM_NOTIFICATION_SENT_FLAG" 2>/dev/null; then
            echo "$(date +'%Y-%m-%d %H:%M:%S'): Skipping already notified OOM event: $line" >> "$LOG_FILE"
            continue
        fi

        echo "$(date +'%Y-%m-%d %H:%M:%S'): Found OOM event: $line" >> "$LOG_FILE"

        # Try to extract the process name and PID if available in the log line
        PROCESS_INFO=$(echo "$line" | grep -oP 'Killed process \d+ \((.*?)\).*?anon-rss:\d+kB' || echo "Details not easily parsed from log line.")
        
        send_oom_notification "$line" "$TIMESTAMP" "$PROCESS_INFO"
        echo "$EVENT_HASH" >> "$OOM_NOTIFICATION_SENT_FLAG" # Mark as sent
    fi
done

# Update the last read timestamp for the next run
date "+%Y-%m-%d %H:%M:%S" > "$LAST_READ_LOG_TIMESTAMP_FILE"
echo "$(date +'%Y-%m-%d %H:%M:%S'): OOM Monitor finished. Last read timestamp updated." >> "$LOG_FILE"