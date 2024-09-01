#!/bin/bash
# Script checks if the system should be suspended based on various conditions.
# The script is intended to be run periodically (standard 5 minutes) using a cron job or systemd timer.
# The script can take up 3-4 seconds to complete, depending on number of network interfaces.
# Criteria 1: Clock within 07:00-14:30 or 00:00-05:00 on weekdays and idle for at least 1 hour
# Criteria 2: Clock within 22:00-07:00 on weekends and idle for at least 1 hour
# Criteria 3: No active audio streams detected at idle check
# Criteria 4: Network activity below threshold on specified interfaces at idle check
# The script will prompt the user before suspending the system.
# Dependencies: xprintidle, pactl (from the pulseaudio-utils package), ifstat, zenity, mpstat (from sysstat package)

export DISPLAY=:0
export XAUTHORITY=$HOME/.Xauthority

# Log file location
LOG_FILE="$HOME/powerprofile/logs/$(date '+%Y-%m-%d')_powerprofile.log"

# Time intervals in milliseconds
HOUR_MS=3600000  # 1 hour in milliseconds
TWO_HOUR_MS=7200000  # 2 hours in milliseconds

# Network activity threshold in kilobytes per second
NETWORK_THRESHOLD=20

# CPU usage threshold (in percentage)
CPU_THRESHOLD=10

# Network interfaces to monitor
INTERFACES=("eth0" "nordlynx")

# Function to log messages
log_message() {
    local MESSAGE=$1
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" >> $LOG_FILE
}

# Get current idle time
IDLE_TIME=$(xprintidle)

# Check for active audio streams using PulseAudio
ACTIVE_STREAMS=$(pactl list short sink-inputs | wc -l)

# Initialize flags (1 = do not suspend, 0 = allow suspend)
FLAG_STREAM=1  # Default to not suspend due to assumed active streams
FLAG_IDLE=1    # Default to not suspend due to insufficient idle time
FLAG_NETWORK=1  # Default to not suspend due to assumed network activity
FLAG_CPU=1  # Default to not suspend due to assumed high CPU usage

# Set FLAG_STREAM to 0 if there are no active streams
if [[ $ACTIVE_STREAMS -eq 0 ]]; then
    FLAG_STREAM=0  # No active streams detected, allow suspend based on this condition
fi

# Get current day and time
CURRENT_DAY=$(date +%u)  # Day of the week (1=Monday, 7=Sunday)
CURRENT_TIME=$((10#$(date +%H%M)))  # Current time in HHMM format

# Check idle time against thresholds based on the day and time
# Weekdays (Monday to Friday)
if [[ $CURRENT_DAY -ge 1 && $CURRENT_DAY -le 5 ]]; then
    if [[ ($CURRENT_TIME -ge 700 && $CURRENT_TIME -le 1430) || ($CURRENT_TIME -le 500) ]]; then
        if [[ $IDLE_TIME -ge $HOUR_MS ]]; then
            FLAG_IDLE=0  # System has been idle long enough, allow suspend
        fi
    fi
# Weekends (Saturday and Sunday)
elif [[ $CURRENT_DAY -ge 6 && $CURRENT_DAY -le 7 ]]; then
    if [[ $CURRENT_TIME -ge 2200 || $CURRENT_TIME -le 700 ]]; then
        if [[ $IDLE_TIME -ge $HOUR_MS ]]; then
            FLAG_IDLE=0  # System has been idle long enough, allow suspend
        fi
    fi
fi

# Check network activity on each interface
for INTERFACE in "${INTERFACES[@]}"; do

    # Get the download speed in KB/s (use awk to parse the output)
    DOWNLOAD_SPEED=$(ifstat -i "$INTERFACE" 1 1 | awk 'NR==3 {print $1}')
    # Check if download speed is a valid number. Default to 0 if invalid.
    if ! [[ "$DOWNLOAD_SPEED" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        DOWNLOAD_SPEED=0
    fi

    # Check if download speed exceeds the threshold
    if [[ -n "$DOWNLOAD_SPEED" ]] && (( $(echo "$DOWNLOAD_SPEED > $NETWORK_THRESHOLD" | bc -l) )); then
        FLAG_NETWORK=1  # Significant network activity detected, do not suspend
        echo "Significant network activity detected on $INTERFACE: $DOWNLOAD_SPEED KB/s. Not suspending."
        break  # Stop checking further interfaces
    else
        FLAG_NETWORK=0  # Set to allow suspension if no significant network activity
    fi
done

# Get CPU idle percentage
CPU_IDLE=$(mpstat 1 1 | awk '/Average:/ {print $12}')
if ! [[ "$CPU_IDLE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    CPU_IDLE=0
fi
if (( $(echo "100 - $CPU_IDLE > $CPU_THRESHOLD" | bc -l) )); then
    FLAG_CPU=1  # High CPU usage, do not suspend
else
    FLAG_CPU=0  # Low CPU usage, allow suspension
fi

# Debug log. Can be removed when script is properly tested.
#log_message "Idle time: $IDLE_TIME ms, FLAG_IDLE: $FLAG_IDLE, FLAG_STREAM: $FLAG_STREAM"

# Suspend the system if no active stream and idle time exceeds the threshold
if [[ $FLAG_STREAM -eq 0 && $FLAG_IDLE -eq 0 && $FLAG_NETWORK -eq 0 ]]; then
    log_message "Preparing to suspend the system. Waiting 5 minutes."
    
    # Show a Zenity dialog with a timeout and cancel option
    zenity --question --text="The system will suspend in 5 minutes due to inactivity. Click Cancel to prevent this." --timeout=290

    # Check if the user canceled the dialog
    if [[ $? -eq 1 ]]; then
        log_message "User canceled the suspension."
    else
        # Re-check idle time before suspending
        IDLE_TIME=$(xprintidle)
        log_message "Re-checked idle time: $IDLE_TIME ms"
        if [[ $IDLE_TIME -ge $HOUR_MS ]]; then
            log_message "System suspending due to inactivity."
            sudo systemctl suspend || log_message "Failed to suspend system."
        else
            log_message "Idle time not sufficient for suspension after delay."
        fi
    fi
else
    log_message "System not suspended. FLAG_STREAM: $FLAG_STREAM, FLAG_IDLE: $FLAG_IDLE, FLAG_NETWORK: $FLAG_NETWORK, FLAG_CPU: $FLAG_CPU"
fi
