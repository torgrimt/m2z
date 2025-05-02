#!/bin/bash

# --- Configuration from Environment Variables (with defaults) ---
MQTT_BROKER_HOST="${MQTT_BROKER_HOST:-localhost}"
MQTT_BROKER_PORT="${MQTT_BROKER_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME}"
MQTT_PASSWORD="${MQTT_PASSWORD}"
MQTT_CLIENT_ID="${MQTT_CLIENT_ID:-mqtt-zabbix-bridge-bash-$$}" # $$ adds PID for some uniqueness
MQTT_TOPIC_PATTERN="${MQTT_TOPIC_PATTERN:-zigbee2mqtt/+}" # Example: zigbee2mqtt/DeviceName
MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX="${MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX:-1}" # 0-indexed

ZABBIX_SERVER_HOST="${ZABBIX_SERVER_HOST:-localhost}"
ZABBIX_SERVER_PORT="${ZABBIX_SERVER_PORT:-10051}"
ZABBIX_MONITORED_HOSTNAME="${ZABBIX_MONITORED_HOSTNAME:-MQTT_Bash_Sensors}"

# Zabbix Item Key Templates & JSON fields for extraction
# Placeholder changed from [{}] to __DEVICE_ID__ for robustness
ENABLE_TEMP="${ENABLE_TEMP:-true}"
ZABBIX_KEY_TEMP="${ZABBIX_KEY_TEMP:-z2m.temperature[__DEVICE_ID__]}"
JSON_FIELD_TEMP="${JSON_FIELD_TEMP:-.temperature}"

ENABLE_HUMID="${ENABLE_HUMID:-true}"
ZABBIX_KEY_HUMID="${ZABBIX_KEY_HUMID:-z2m.humidity[__DEVICE_ID__]}"
JSON_FIELD_HUMID="${JSON_FIELD_HUMID:-.humidity}"

ENABLE_PRESSURE="${ENABLE_PRESSURE:-true}"
ZABBIX_KEY_PRESSURE="${ZABBIX_KEY_PRESSURE:-z2m.pressure[__DEVICE_ID__]}"
JSON_FIELD_PRESSURE="${JSON_FIELD_PRESSURE:-.pressure}"

ENABLE_BATTERY="${ENABLE_BATTERY:-true}"
ZABBIX_KEY_BATTERY="${ZABBIX_KEY_BATTERY:-z2m.battery[__DEVICE_ID__]}"
JSON_FIELD_BATTERY="${JSON_FIELD_BATTERY:-.battery}"

ENABLE_LINKQUALITY="${ENABLE_LINKQUALITY:-true}"
ZABBIX_KEY_LINKQUALITY="${ZABBIX_KEY_LINKQUALITY:-z2m.linkquality[__DEVICE_ID__]}"
JSON_FIELD_LINKQUALITY="${JSON_FIELD_LINKQUALITY:-.linkquality}"

ENABLE_VOLTAGE="${ENABLE_VOLTAGE:-true}"
ZABBIX_KEY_VOLTAGE="${ZABBIX_KEY_VOLTAGE:-z2m.voltage[__DEVICE_ID__]}"
JSON_FIELD_VOLTAGE="${JSON_FIELD_VOLTAGE:-.voltage}"

ENABLE_POWER_OUTAGE="${ENABLE_POWER_OUTAGE:-true}"
ZABBIX_KEY_POWER_OUTAGE="${ZABBIX_KEY_POWER_OUTAGE:-z2m.power_outage_count[__DEVICE_ID__]}"
JSON_FIELD_POWER_OUTAGE="${JSON_FIELD_POWER_OUTAGE:-.power_outage_count}"

LOG_LEVEL="${LOG_LEVEL:-INFO}" # DEBUG, INFO, WARN, ERROR

# --- Helper Functions ---
log_msg() {
    local level="$1"
    local message="$2"
    local current_level_num
    local requested_level_num

    case "$LOG_LEVEL" in
        DEBUG) requested_level_num=0 ;;
        INFO)  requested_level_num=1 ;;
        WARN)  requested_level_num=2 ;;
        ERROR) requested_level_num=3 ;;
        *)     requested_level_num=1 ;; 
    esac

    case "$level" in
        DEBUG) current_level_num=0 ;;
        INFO)  current_level_num=1 ;;
        WARN)  current_level_num=2 ;;
        ERROR) current_level_num=3 ;;
        *)     current_level_num=1 ;;
    esac

    if [ "$current_level_num" -ge "$requested_level_num" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $level - $message"
    fi
}

send_to_zabbix() {
    local item_host="$1"
    local item_key="$2"
    local item_value="$3"

    if [ -z "$item_value" ] || [ "$item_value" == "null" ]; then
        log_msg "DEBUG" "SEND_TO_ZABBIX: Skipping Zabbix send for Key='$item_key', value is null or empty."
        return
    fi

    log_msg "DEBUG" "SEND_TO_ZABBIX: Preparing to send: Host='$item_host', Key='$item_key', Value='$item_value'"
    
    local zabbix_sender_cmd=(
        "zabbix_sender"
        -z "$ZABBIX_SERVER_HOST"
        -p "$ZABBIX_SERVER_PORT"
        -s "$item_host"
        -k "$item_key"
        -o "$item_value"
    )

    log_msg "DEBUG" "SEND_TO_ZABBIX: Executing: ${zabbix_sender_cmd[*]}"
    
    local output
    output=$( "${zabbix_sender_cmd[@]}" 2>&1 ) 
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [[ "$output" == *"failed: 0"* ]]; then
        log_msg "INFO" "SEND_TO_ZABBIX: Successfully sent: Key='$item_key', Value='$item_value'. Output: $output"
    else
        log_msg "ERROR" "SEND_TO_ZABBIX: Failed to send: Key='$item_key', Value='$item_value'. ExitCode: $exit_code, Output: $output"
    fi
}

process_metric() {
    local device_id="$1"
    local json_payload="$2"
    local enable_flag="$3"
    local key_template="$4"
    local json_field="$5"
    local metric_name="$6" 

    if [ "$enable_flag" != "true" ]; then
        log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Processing disabled."
        return
    fi

    local value
    value=$(echo "$json_payload" | jq -r "$json_field // \"\"") # Get value or empty string if null/not found

    if [ -n "$value" ] && [ "$value" != "null" ]; then
        log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Device ID to use for substitution: '$device_id'"
        log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Key template before substitution: '$key_template'"
        
        if [ "$LOG_LEVEL" == "DEBUG" ]; then
            log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Hexdump of key_template pre-subst:"
            printf "%s" "$key_template" | od -An -t c -t x1
            log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Hexdump of device_id pre-subst:"
            printf "%s" "$device_id" | od -An -t c -t x1
        fi
        
        local final_key
        # Using Bash parameter expansion with the new placeholder __DEVICE_ID__
        final_key="${key_template//__DEVICE_ID__/$device_id}"
        
        log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Key template after Bash substitution: '$final_key'"
        if [ "$LOG_LEVEL" == "DEBUG" ]; then
            log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Hexdump of final_key post-subst:"
            printf "%s" "$final_key" | od -An -t c -t x1
        fi
        
        log_msg "DEBUG" "PROCESS_METRIC ($metric_name): Extracted '$value' for '$device_id'. Sending with Zabbix key '$final_key'."
        send_to_zabbix "$ZABBIX_MONITORED_HOSTNAME" "$final_key" "$value"
    else
        log_msg "DEBUG" "PROCESS_METRIC ($metric_name): No value found (field: $json_field) for device '$device_id' in payload: $json_payload"
    fi
}

# --- Sanity Checks ---
if ! command -v mosquitto_sub &> /dev/null; then
    log_msg "ERROR" "mosquitto_sub command not found. Please install mosquitto-clients."
    exit 1
fi
if ! command -v jq &> /dev/null; then
    log_msg "ERROR" "jq command not found. Please install jq."
    exit 1
fi
if ! command -v zabbix_sender &> /dev/null; then
    log_msg "ERROR" "zabbix_sender command not found. Please install zabbix-sender."
    exit 1
fi
if ! command -v awk &> /dev/null; then 
    log_msg "ERROR" "awk command not found. Please install awk (usually gawk)."
    exit 1
fi
if ! command -v od &> /dev/null; then # Added od check for hexdumps
    log_msg "ERROR" "od command not found. Please install coreutils (provides od)."
    exit 1
fi
if [ -z "$ZABBIX_MONITORED_HOSTNAME" ]; then
    log_msg "ERROR" "ZABBIX_MONITORED_HOSTNAME is not set. This is required."
    exit 1
fi

# --- Main Logic ---
log_msg "INFO" "MAIN: MQTT to Zabbix bridge (Bash) starting..."
log_msg "INFO" "MAIN: Connecting to MQTT Broker: $MQTT_BROKER_HOST:$MQTT_BROKER_PORT"
log_msg "INFO" "MAIN: Subscribing to topic pattern: $MQTT_TOPIC_PATTERN"
log_msg "INFO" "MAIN: Zabbix Server: $ZABBIX_SERVER_HOST:$ZABBIX_SERVER_PORT"
log_msg "INFO" "MAIN: Zabbix Monitored Hostname: $ZABBIX_MONITORED_HOSTNAME"
log_msg "INFO" "MAIN: Device ID will be extracted from topic segment index: $MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX"

MQTT_CMD_ARGS=(-h "$MQTT_BROKER_HOST" -p "$MQTT_BROKER_PORT" -t "$MQTT_TOPIC_PATTERN" -F "%t %p" --quiet -i "$MQTT_CLIENT_ID")

if [ -n "$MQTT_USERNAME" ]; then
    MQTT_CMD_ARGS+=(-u "$MQTT_USERNAME")
fi
if [ -n "$MQTT_PASSWORD" ]; then
    MQTT_CMD_ARGS+=(-P "$MQTT_PASSWORD")
fi

while true; do
    mosquitto_sub "${MQTT_CMD_ARGS[@]}" | while IFS= read -r line || [ -n "$line" ]; do 
        log_msg "DEBUG" "MAIN_LOOP: Raw line from mosquitto_sub: '$line'"

        if echo "$line" | grep -Eq '^[[:space:]]*$'; then
            log_msg "DEBUG" "MAIN_LOOP: Received empty or whitespace-only line from mosquitto_sub, skipping."
            continue
        fi

        topic="${line%% *}" 
        payload="${line#* }"

        if [[ "$topic" == "$payload" ]] && ! [[ "$line" == *" "* ]]; then 
            log_msg "DEBUG" "MAIN_LOOP: Line appeared to have no spaces. Assuming Topic: '$topic', and Payload is empty."
            payload="" 
        fi
        
        log_msg "INFO" "MAIN_LOOP: Parsed: Topic='${topic}', Payload='${payload}'"

        device_id=$(echo "$topic" | awk -F/ -v idx="$((MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX + 1))" '{print $idx}')

        if [ -z "$device_id" ]; then
            if [ -z "$topic" ]; then 
                 log_msg "WARN" "MAIN_LOOP: Topic string was empty after parsing. Original line: '$line'. Skipping message."
            else
                 log_msg "WARN" "MAIN_LOOP: Could not extract Device ID from topic '$topic' using segment index $MQTT_TOPIC_DEVICE_ID_SEGMENT_INDEX. Original line: '$line'. Skipping message."
            fi
            continue
        fi
        log_msg "DEBUG" "MAIN_LOOP: Extracted Device ID: '$device_id'"

        if ! echo "$payload" | jq -e . > /dev/null 2>&1; then
            log_msg "WARN" "MAIN_LOOP: Payload for topic '$topic' is not valid JSON. Payload: '$payload'. Skipping."
            continue
        fi

        process_metric "$device_id" "$payload" "$ENABLE_TEMP" "$ZABBIX_KEY_TEMP" "$JSON_FIELD_TEMP" "Temperature"
        process_metric "$device_id" "$payload" "$ENABLE_HUMID" "$ZABBIX_KEY_HUMID" "$JSON_FIELD_HUMID" "Humidity"
        process_metric "$device_id" "$payload" "$ENABLE_PRESSURE" "$ZABBIX_KEY_PRESSURE" "$JSON_FIELD_PRESSURE" "Pressure"
        process_metric "$device_id" "$payload" "$ENABLE_BATTERY" "$ZABBIX_KEY_BATTERY" "$JSON_FIELD_BATTERY" "Battery"
        process_metric "$device_id" "$payload" "$ENABLE_LINKQUALITY" "$ZABBIX_KEY_LINKQUALITY" "$JSON_FIELD_LINKQUALITY" "LinkQuality"
        process_metric "$device_id" "$payload" "$ENABLE_VOLTAGE" "$ZABBIX_KEY_VOLTAGE" "$JSON_FIELD_VOLTAGE" "Voltage"
        # Corrected typo from device__id to device_id
        process_metric "$device_id" "$payload" "$ENABLE_POWER_OUTAGE" "$ZABBIX_KEY_POWER_OUTAGE" "$JSON_FIELD_POWER_OUTAGE" "PowerOutageCount"

    done
    log_msg "WARN" "MAIN: mosquitto_sub process ended. Retrying connection in 5 seconds..."
    sleep 5
done

