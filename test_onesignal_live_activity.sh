#!/bin/bash

# PETL OneSignal Live Activity Test Script
# Replace YOUR_REST_API_KEY with your actual OneSignal REST API key

REST_API_KEY="YOUR_REST_API_KEY"
APP_ID="ebc50f5b-0b53-4855-a4cb-313b5038dc0c"

# Function to send Live Activity notification
send_live_activity_notification() {
    local device_token="$1"
    local action="$2"
    local emoji="${3:-🔌}"
    local message="${4:-Device is charging}"
    
    local data="{
      \"live_activity_action\": \"$action\",
      \"custom_data\": {
        \"emoji\": \"$emoji\",
        \"message\": \"$message\"
      }
    }"
    
    curl --location 'https://onesignal.com/api/v1/notifications' \
    --header "Authorization: Basic $REST_API_KEY" \
    --header 'Content-Type: application/json' \
    --data "{
      \"app_id\": \"$APP_ID\",
      \"include_player_ids\": [\"$device_token\"],
      \"contents\": {\"en\": \"Live Activity $action\"},
      \"headings\": {\"en\": \"PETL OneSignal\"},
      \"data\": $data
    }"
}

# Function to start Live Activity
start_live_activity() {
    local device_token="$1"
    local emoji="${2:-🔌}"
    local message="${3:-Device is charging}"
    
    echo "Starting Live Activity via OneSignal..."
    send_live_activity_notification "$device_token" "start" "$emoji" "$message"
}

# Function to update Live Activity
update_live_activity() {
    local device_token="$1"
    local emoji="${2:-🔄}"
    local message="${3:-Activity updated}"
    
    echo "Updating Live Activity via OneSignal..."
    send_live_activity_notification "$device_token" "update" "$emoji" "$message"
}

# Function to end Live Activity
end_live_activity() {
    local device_token="$1"
    
    echo "Ending Live Activity via OneSignal..."
    send_live_activity_notification "$device_token" "end" "🔌" "Device unplugged"
}

# Function to simulate charging events
simulate_charging_event() {
    local device_token="$1"
    local event="$2"
    
    case $event in
        "start")
            start_live_activity "$device_token" "🔌" "Device started charging"
            ;;
        "update")
            update_live_activity "$device_token" "⚡" "Charging in progress"
            ;;
        "end")
            end_live_activity "$device_token"
            ;;
        *)
            echo "Unknown event: $event"
            echo "Valid events: start, update, end"
            ;;
    esac
}

# Main script
echo "PETL OneSignal Live Activity Test Script"
echo "========================================"
echo ""

if [ "$1" = "start" ]; then
    if [ -z "$2" ]; then
        echo "Usage: $0 start <device_token> [emoji] [message]"
        echo "Example: $0 start YOUR_DEVICE_TOKEN 🔌 'Device is charging'"
        exit 1
    fi
    start_live_activity "$2" "$3" "$4"
    
elif [ "$1" = "update" ]; then
    if [ -z "$2" ]; then
        echo "Usage: $0 update <device_token> [emoji] [message]"
        echo "Example: $0 update YOUR_DEVICE_TOKEN ⚡ 'Charging in progress'"
        exit 1
    fi
    update_live_activity "$2" "$3" "$4"
    
elif [ "$1" = "end" ]; then
    if [ -z "$2" ]; then
        echo "Usage: $0 end <device_token>"
        echo "Example: $0 end YOUR_DEVICE_TOKEN"
        exit 1
    fi
    end_live_activity "$2"
    
elif [ "$1" = "simulate" ]; then
    if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: $0 simulate <device_token> <event>"
        echo "Events: start, update, end"
        echo "Example: $0 simulate YOUR_DEVICE_TOKEN start"
        exit 1
    fi
    simulate_charging_event "$2" "$3"
    
else
    echo "Usage:"
    echo "  $0 start <device_token> [emoji] [message]  - Start Live Activity"
    echo "  $0 update <device_token> [emoji] [message]  - Update Live Activity"
    echo "  $0 end <device_token>  - End Live Activity"
    echo "  $0 simulate <device_token> <event>  - Simulate charging event"
    echo ""
    echo "Examples:"
    echo "  $0 start YOUR_DEVICE_TOKEN 🔌 'Device is charging'"
    echo "  $0 update YOUR_DEVICE_TOKEN ⚡ 'Charging in progress'"
    echo "  $0 end YOUR_DEVICE_TOKEN"
    echo "  $0 simulate YOUR_DEVICE_TOKEN start"
    echo ""
    echo "Note: Replace YOUR_REST_API_KEY in this script with your actual OneSignal REST API key"
fi 