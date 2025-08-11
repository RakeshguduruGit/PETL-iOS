#!/bin/bash

# OneSignal Test Script
# This script helps verify OneSignal integration and sends test notifications

echo "🔍 OneSignal Integration Test"
echo "=============================="

# Your OneSignal credentials
ONESIGNAL_APP_ID="ebc50f5b-0b53-4855-a4cb-313b5038dc0c"
ONESIGNAL_API_KEY="os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja"

echo "📱 OneSignal App ID: $ONESIGNAL_APP_ID"
echo "🔑 API Key: ${ONESIGNAL_API_KEY:0:20}..."

# Test 1: Send a basic notification
echo ""
echo "🧪 Test 1: Sending basic notification..."
curl -X POST \
  https://onesignal.com/api/v1/notifications \
  -H "Authorization: Basic $ONESIGNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "app_id": "'$ONESIGNAL_APP_ID'",
    "included_segments": ["All"],
    "contents": {"en": "🧪 OneSignal Test Notification"},
    "headings": {"en": "PETL Test"},
    "data": {
      "live_activity_action": "start",
      "custom_data": {
        "emoji": "🔌",
        "message": "Test Live Activity Start"
      }
    }
  }'

echo ""
echo ""

# Test 2: Send Live Activity start notification
echo "🧪 Test 2: Sending Live Activity start notification..."
curl -X POST \
  https://onesignal.com/api/v1/notifications \
  -H "Authorization: Basic $ONESIGNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "app_id": "'$ONESIGNAL_APP_ID'",
    "included_segments": ["All"],
    "contents": {"en": "🔌 Device charging detected"},
    "headings": {"en": "PETL Live Activity"},
    "data": {
      "live_activity_action": "start",
      "custom_data": {
        "emoji": "🔌",
        "message": "Device is now charging"
      }
    }
  }'

echo ""
echo ""

# Test 3: Send Live Activity update notification
echo "🧪 Test 3: Sending Live Activity update notification..."
curl -X POST \
  https://onesignal.com/api/v1/notifications \
  -H "Authorization: Basic $ONESIGNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "app_id": "'$ONESIGNAL_APP_ID'",
    "included_segments": ["All"],
    "contents": {"en": "🔄 Live Activity updated"},
    "headings": {"en": "PETL Update"},
    "data": {
      "live_activity_action": "update",
      "custom_data": {
        "emoji": "🔄",
        "message": "Activity updated via OneSignal"
      }
    }
  }'

echo ""
echo ""

# Test 4: Send Live Activity end notification
echo "🧪 Test 4: Sending Live Activity end notification..."
curl -X POST \
  https://onesignal.com/api/v1/notifications \
  -H "Authorization: Basic $ONESIGNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "app_id": "'$ONESIGNAL_APP_ID'",
    "included_segments": ["All"],
    "contents": {"en": "🔋 Device unplugged"},
    "headings": {"en": "PETL Live Activity"},
    "data": {
      "live_activity_action": "end",
      "custom_data": {
        "emoji": "🔋",
        "message": "Device is no longer charging"
      }
    }
  }'

echo ""
echo ""
echo "✅ Test notifications sent!"
echo ""
echo "📋 Verification Steps:"
echo "1. Check your device for the test notifications"
echo "2. Look for Live Activity on lock screen and Dynamic Island"
echo "3. Check Xcode console for OneSignal logs"
echo "4. Verify device token is displayed in the app"
echo ""
echo "🔧 Troubleshooting:"
echo "- Make sure app is running in foreground"
echo "- Check notification permissions are granted"
echo "- Verify Live Activity capability is enabled"
echo "- Look for console logs about OneSignal events" 