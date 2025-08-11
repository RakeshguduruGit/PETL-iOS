#!/bin/bash

# Comprehensive OneSignal Verification Script
# This script helps verify that push notifications are actually coming from OneSignal

echo "🔍 OneSignal Integration Verification"
echo "===================================="

# Your OneSignal credentials
ONESIGNAL_APP_ID="ebc50f5b-0b53-4855-a4cb-313b5038dc0c"
ONESIGNAL_API_KEY="os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja"

echo "📱 OneSignal App ID: $ONESIGNAL_APP_ID"
echo "🔑 API Key: ${ONESIGNAL_API_KEY:0:20}..."
echo ""

# Test 1: Check OneSignal API connectivity
echo "🧪 Test 1: Checking OneSignal API connectivity..."
API_RESPONSE=$(curl -s -X GET \
  "https://onesignal.com/api/v1/apps/$ONESIGNAL_APP_ID" \
  -H "Authorization: Basic $ONESIGNAL_API_KEY" \
  -H "Content-Type: application/json")

if echo "$API_RESPONSE" | grep -q "id"; then
    echo "✅ OneSignal API is accessible"
    echo "📊 App Name: $(echo "$API_RESPONSE" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)"
else
    echo "❌ OneSignal API connection failed"
    echo "Response: $API_RESPONSE"
fi
echo ""

# Test 2: Send a test notification with OneSignal-specific data
echo "🧪 Test 2: Sending test notification with OneSignal verification data..."
TEST_RESPONSE=$(curl -s -X POST \
  https://onesignal.com/api/v1/notifications \
  -H "Authorization: Basic $ONESIGNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "app_id": "'$ONESIGNAL_APP_ID'",
    "included_segments": ["All"],
    "headings": {"en": "🔍 OneSignal Verification Test"},
    "contents": {"en": "This notification contains OneSignal-specific data for verification"},
    "data": {
      "onesignal_verification": "true",
      "test_timestamp": "'$(date +%s)'",
      "test_id": "verification_'$(date +%s)'",
      "live_activity_action": "start",
      "custom_data": {
        "emoji": "🔍",
        "message": "OneSignal verification test",
        "verification": "true"
      }
    },
    "ios_sound": "default",
    "priority": 10
  }')

echo "📤 Test notification sent"
echo "📋 Response: $TEST_RESPONSE"
echo ""

# Test 3: Check for OneSignal-specific headers and data
echo "🧪 Test 3: OneSignal notification verification checklist..."
echo "When you receive the notification, check for these OneSignal indicators:"
echo ""
echo "✅ OneSignal-specific data in notification payload:"
echo "   - 'onesignal_verification': 'true'"
echo "   - 'test_id': should contain timestamp"
echo "   - 'live_activity_action': 'start'"
echo ""
echo "✅ OneSignal notification ID in payload:"
echo "   - Look for 'i' field in additionalData (OneSignal notification ID)"
echo ""
echo "✅ OneSignal server headers:"
echo "   - Notification should come from OneSignal servers"
echo "   - Check X-OneSignal headers if available"
echo ""

# Test 4: Verify device registration
echo "🧪 Test 4: Checking device registration status..."
echo "In your app console logs, look for:"
echo "✅ OneSignal Device Token (64-character hex string)"
echo "✅ Subscription Status: Opted In"
echo "✅ Notification Types: 1 (subscribed)"
echo "✅ OneSignal Subscription ID"
echo ""

# Test 5: Manual verification steps
echo "🧪 Test 5: Manual verification steps..."
echo ""
echo "1. Run the app and check console logs for:"
echo "   🔧 OneSignal Initialization Started"
echo "   📱 OneSignal App ID: [your app id]"
echo "   ✅ OneSignal Device Token: [64-char hex]"
echo "   📋 Subscription Status: Opted In"
echo "   🔔 Notification Types: 1"
echo ""
echo "2. When you receive a notification, check console for:"
echo "   📱 OneSignal Notification Clicked!"
echo "   📋 Notification ID: [OneSignal ID]"
echo "   ✅ Verified OneSignal Notification ID: [ID]"
echo ""
echo "3. Verify notification payload contains:"
echo "   - OneSignal-specific data fields"
echo "   - 'i' field with OneSignal notification ID"
echo "   - Custom data for Live Activity"
echo ""

echo "🎯 Verification Summary:"
echo "========================"
echo "✅ If you see OneSignal Device Token in logs → OneSignal is connected"
echo "✅ If notification contains OneSignal ID → Notification is from OneSignal"
echo "✅ If console shows 'OneSignal Notification Clicked!' → OneSignal is working"
echo "✅ If Live Activity starts/ends → OneSignal integration is complete"
echo ""
echo "❌ If you don't see OneSignal Device Token → Check OneSignal setup"
echo "❌ If notifications don't contain OneSignal data → May be local notifications"
echo "❌ If no 'OneSignal Notification Clicked!' logs → Check notification listener"
echo ""

echo "📝 Next Steps:"
echo "1. Run the app and check console logs"
echo "2. Plug/unplug your device to trigger notifications"
echo "3. Check if notifications contain OneSignal verification data"
echo "4. Verify Live Activity starts and ends properly"
echo ""
echo "🔍 For detailed debugging, check the console logs in Xcode" 