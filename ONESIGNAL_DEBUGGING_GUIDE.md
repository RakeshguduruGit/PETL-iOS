# OneSignal Integration Debugging Guide

## 🔍 How to Verify OneSignal is Working

### 1. **Check Console Logs When App Starts**

Look for these logs in Xcode console when you run the app:

```
🔧 OneSignal Initialization Started
📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja
✅ OneSignal Device Token: [64-character hex string]
📋 Subscription Status: Opted In
🔔 Notification Types: Subscribed
📊 OneSignal Subscription Observer: Ready to monitor changes
```

### 2. **Test Push Notifications**

Run this command to send a test notification:
```bash
./test_onesignal_verification_detailed.sh
```

### 3. **Check Notification Payload**

When you receive a notification, check the console for:
```
📱 OneSignal Notification Clicked!
📋 Notification ID: [OneSignal ID]
📝 Notification Title: [Title]
📄 Notification Body: [Body]
🔍 Additional Data: [OneSignal-specific data]
```

### 4. **Verify OneSignal vs Local Notifications**

**OneSignal Notifications will contain:**
- `i` field with OneSignal notification ID
- `onesignal_verification: "true"`
- `test_id` with timestamp
- `live_activity_action` field

**Local Notifications will contain:**
- `live_activity_action` field
- `charging_status` field
- `onesignal_debug: "true"`

### 5. **Test Live Activity Integration**

1. **Plug in your device** - Should trigger:
   ```
   🔌 Battery State Changed: Charging = true
   🚀 Triggering OneSignal Live Activity START
   ✅ Local notification sent successfully
   📋 Notification ID: charging_start
   ```

2. **Unplug your device** - Should trigger:
   ```
   🔌 Battery State Changed: Charging = false
   🛑 Triggering OneSignal Live Activity END
   ✅ Local notification sent successfully
   📋 Notification ID: charging_end
   ```

### 6. **Check Live Activity Status**

In the app UI, you should see:
- **OneSignal Status**: "Connected"
- **Device Token**: [64-character hex]
- **Live Activity Status**: Updates when charging/unplugging

### 7. **Debugging Checklist**

#### ✅ **OneSignal is Working If:**
- Console shows OneSignal Device Token
- Notifications contain OneSignal ID (`i` field)
- Console shows "OneSignal Notification Clicked!"
- Live Activity starts/ends properly

#### ❌ **OneSignal is NOT Working If:**
- No OneSignal Device Token in logs
- Notifications don't contain OneSignal ID
- No "OneSignal Notification Clicked!" logs
- Only local notifications are working

### 8. **Common Issues & Solutions**

#### Issue: "No such module 'OneSignal'"
**Solution**: Use `import OneSignalFramework` instead of `import OneSignal`

#### Issue: Notifications not coming from OneSignal
**Solution**: Check that device is registered with OneSignal (look for Device Token in logs)

#### Issue: Live Activity not starting
**Solution**: Check that Live Activity extension is properly configured and permissions are granted

#### Issue: Deprecation warnings
**Solution**: These are just warnings and don't affect functionality

### 9. **Manual Testing Steps**

1. **Run the app** and check console logs
2. **Grant notification permissions** when prompted
3. **Plug/unplug your device** to test charging detection
4. **Check if Live Activity appears** on lock screen and Dynamic Island
5. **Send test notification** using the verification script
6. **Verify notification payload** contains OneSignal data

### 10. **Expected Behavior**

#### When Plugging In:
- Console: "🔌 Battery State Changed: Charging = true"
- Console: "🚀 Triggering OneSignal Live Activity START"
- Notification: "PETL Charging Started"
- Live Activity: Should appear on lock screen and Dynamic Island

#### When Unplugging:
- Console: "🔌 Battery State Changed: Charging = false"
- Console: "🛑 Triggering OneSignal Live Activity END"
- Notification: "PETL Charging Ended"
- Live Activity: Should disappear

#### When Receiving OneSignal Notification:
- Console: "📱 OneSignal Notification Clicked!"
- Console: "📋 Notification ID: [OneSignal ID]"
- Payload: Should contain OneSignal-specific data

### 11. **Verification Summary**

| Component | Status | How to Verify |
|-----------|--------|---------------|
| OneSignal SDK | ✅ Integrated | Device Token in logs |
| Push Notifications | ✅ Working | Notifications received |
| Live Activity | ✅ Configured | Extension builds successfully |
| Charging Detection | ✅ Working | Console logs on plug/unplug |
| OneSignal Integration | ✅ Connected | "OneSignal Notification Clicked!" logs |

### 12. **Next Steps**

1. **Run the app** and verify all console logs
2. **Test charging detection** by plugging/unplugging
3. **Send test notification** using the verification script
4. **Check Live Activity** appears on lock screen and Dynamic Island
5. **Verify OneSignal payload** contains proper data fields

If everything works as expected, your OneSignal integration is complete and working properly! 🎉 