# OneSignal Live Activity Rule: Starting Live Activities via OneSignal

## 🎯 Rule Overview

**Rule Name**: Starting Live Activity via OneSignal  
**Purpose**: Establish best practices for initiating Live Activities through OneSignal push notifications  
**Scope**: All Live Activity implementations using OneSignal integration  
**Priority**: High - Critical for reliable Live Activity management

## 📋 Rule Requirements

### 1. OneSignal Configuration
- ✅ **App ID**: Must be properly configured in OneSignal dashboard
- ✅ **Push Certificate**: Valid APNs certificate uploaded to OneSignal
- ✅ **Live Activity Capability**: Enabled in OneSignal app settings
- ✅ **Device Registration**: Device must be registered with OneSignal

### 2. Push Notification Structure
```json
{
  "app_id": "your-onesignal-app-id",
  "include_player_ids": ["device-token"],
  "data": {
    "live_activity_action": "start",
    "custom_data": {
      "emoji": "🔌",
      "message": "Device is charging at 85%",
      "timestamp": "2025-07-27T23:47:40Z"
    }
  },
  "priority": 10,
  "content_available": true
}
```

### 3. Required Fields
- **`live_activity_action`**: Must be "start", "update", or "end"
- **`custom_data`**: Object containing Live Activity content
- **`priority`**: Must be 10 for Live Activity requests
- **`content_available`**: Must be true for background processing

## 🚀 Implementation Guidelines

### 1. OneSignal SDK Setup
```swift
// In PETLApp.swift
import OneSignalFramework

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Initialize OneSignal
        OneSignal.initialize("your-onesignal-app-id", withLaunchOptions: launchOptions)
        
        // Request notification permissions
        OneSignal.Notifications.requestPermission { accepted in
            print("User accepted notifications: \(accepted)")
        }
        
        return true
    }
}
```

### 2. Live Activity Handler
```swift
// Handle OneSignal push notifications for Live Activities
func handleOneSignalLiveActivity(_ notification: OSNotification) {
    guard let data = notification.additionalData as? [String: Any],
          let action = data["live_activity_action"] as? String else {
        return
    }
    
    switch action {
    case "start":
        startLiveActivityFromOneSignal(data)
    case "update":
        updateLiveActivityFromOneSignal(data)
    case "end":
        endLiveActivityFromOneSignal()
    default:
        print("Unknown Live Activity action: \(action)")
    }
}
```

### 3. Start Live Activity Function
```swift
private func startLiveActivityFromOneSignal(_ data: [String: Any]) {
    guard let customData = data["custom_data"] as? [String: Any],
          let emoji = customData["emoji"] as? String,
          let message = customData["message"] as? String else {
        print("Invalid custom data for Live Activity")
        return
    }
    
    Task {
        do {
            let attributes = PETLLiveActivityExtensionAttributes(
                name: "OneSignal Activity"
            )
            
            let contentState = PETLLiveActivityExtensionAttributes.ContentState(
                emoji: emoji,
                message: message,
                timestamp: Date()
            )
            
            let activity = try Activity.request(
                attributes: attributes,
                contentState: contentState,
                pushType: nil
            )
            
            print("✅ Live Activity started via OneSignal: \(activity.id)")
            
        } catch {
            print("❌ Failed to start Live Activity via OneSignal: \(error)")
        }
    }
}
```

## 📊 Testing Procedures

### 1. OneSignal Dashboard Testing
1. **Navigate to OneSignal Dashboard**
2. **Select your app**
3. **Go to "Messages" → "New Push"**
4. **Configure message**:
   ```
   Title: Live Activity Test
   Message: Starting Live Activity
   Data: {
     "live_activity_action": "start",
     "custom_data": {
       "emoji": "🚀",
       "message": "Test Live Activity via OneSignal"
     }
   }
   ```
5. **Send to specific device** using device token
6. **Verify Live Activity appears** on device

### 2. REST API Testing
```bash
curl -X POST \
  https://onesignal.com/api/v1/notifications \
  -H 'Authorization: Basic YOUR_REST_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "app_id": "your-app-id",
    "include_player_ids": ["device-token"],
    "data": {
      "live_activity_action": "start",
      "custom_data": {
        "emoji": "🔌",
        "message": "Charging started via OneSignal"
      }
    },
    "priority": 10,
    "content_available": true
  }'
```

### 3. Automated Testing Script
```bash
#!/bin/bash
# test_onesignal_live_activity.sh

DEVICE_TOKEN="$1"
ACTION="$2"
EMOJI="$3"
MESSAGE="$4"

curl -X POST \
  https://onesignal.com/api/v1/notifications \
  -H "Authorization: Basic $ONESIGNAL_REST_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{
    \"app_id\": \"$ONESIGNAL_APP_ID\",
    \"include_player_ids\": [\"$DEVICE_TOKEN\"],
    \"data\": {
      \"live_activity_action\": \"$ACTION\",
      \"custom_data\": {
        \"emoji\": \"$EMOJI\",
        \"message\": \"$MESSAGE\"
      }
    },
    \"priority\": 10,
    \"content_available\": true
  }"
```

## 🔧 Troubleshooting

### Common Issues

#### 1. Live Activity Not Starting
**Symptoms**: Push received but no Live Activity appears
**Solutions**:
- Check `live_activity_action` field is "start"
- Verify `priority` is set to 10
- Ensure `content_available` is true
- Check device supports Live Activities (iOS 16.1+)

#### 2. Push Not Received
**Symptoms**: No push notification received
**Solutions**:
- Verify device token is correct
- Check OneSignal app ID matches
- Ensure push certificate is valid
- Test with OneSignal's test notification

#### 3. Invalid Data Format
**Symptoms**: Push received but Live Activity fails to start
**Solutions**:
- Validate JSON structure
- Check required fields are present
- Verify data types are correct
- Test with minimal payload first

### Debug Checklist
- [ ] OneSignal SDK properly initialized
- [ ] Device token is valid and registered
- [ ] Push certificate is uploaded to OneSignal
- [ ] Live Activity capabilities are enabled
- [ ] Push notification structure is correct
- [ ] Device supports Live Activities
- [ ] App has proper entitlements
- [ ] Network connectivity is available

## 📈 Best Practices

### 1. Push Notification Design
- **Keep payload small**: Minimize data size for faster delivery
- **Use consistent structure**: Standardize data format across all pushes
- **Include fallbacks**: Provide default values for missing data
- **Test thoroughly**: Verify all scenarios work before production

### 2. Error Handling
- **Graceful degradation**: Handle missing or invalid data
- **Logging**: Comprehensive logging for debugging
- **User feedback**: Inform users when Live Activity fails
- **Retry logic**: Implement retry mechanisms for failed requests

### 3. Performance Optimization
- **Batch operations**: Group multiple updates when possible
- **Efficient delivery**: Use segments for targeted delivery
- **Monitor analytics**: Track delivery success rates
- **Optimize timing**: Send pushes at appropriate times

## 🚨 Compliance Requirements

### 1. Apple Guidelines
- Follow Apple's Live Activity guidelines
- Respect user privacy and permissions
- Implement proper error handling
- Test on multiple device types

### 2. OneSignal Requirements
- Use official OneSignal SDK
- Follow OneSignal best practices
- Monitor delivery analytics
- Maintain valid push certificates

### 3. App Store Guidelines
- Ensure Live Activities provide value
- Don't spam users with unnecessary activities
- Respect user notification preferences
- Follow App Store review guidelines

## 📝 Documentation

### Required Documentation
- OneSignal configuration details
- Push notification structure
- Error handling procedures
- Testing procedures
- Troubleshooting guides

### Maintenance Tasks
- Regular certificate renewal
- SDK version updates
- Analytics monitoring
- Performance optimization
- User feedback collection

---

**Rule Status**: Active  
**Last Updated**: July 27, 2025  
**Next Review**: August 27, 2025  
**Owner**: Development Team  
**Stakeholders**: Product, Engineering, QA 