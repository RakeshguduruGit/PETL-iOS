# OneSignal Integration Verification Guide

## ✅ Current Status
- **Build**: ✅ Successful
- **OneSignal SDK**: ✅ Integrated
- **Live Activity Extension**: ✅ Compiled
- **Device Registration**: ⏳ Pending (needs app to run)

## 🔍 How to Verify OneSignal is Working

### 1. Run the App
1. Open Xcode
2. Select your device/simulator
3. Run the PETL app
4. Grant notification permissions when prompted

### 2. Check OneSignal Status in App
- Look at the "OneSignal Status" section in the app
- Should show "Connected" and display a device token
- If it shows "Not connected", check console logs

### 3. Check Xcode Console Logs
Look for these logs when the app starts:
```
✅ OneSignal Device Token: [token]
User accepted notifications: true
```

### 4. Test Push Notifications
Once the app is running and shows "Connected":

1. **Send a test notification:**
```bash
./test_onesignal_verification.sh
```

2. **Or use OneSignal Dashboard:**
   - Go to [OneSignal Dashboard](https://app.onesignal.com)
   - Select your app
   - Go to "Messages" → "New Push"
   - Send a test message

### 5. Test Live Activity
To test Live Activity functionality:

1. **Manual Test:**
   - Tap "Test OneSignal Push" button in the app
   - Check console for device token
   - Send a notification with `live_activity_action: "start"`

2. **Charging Test:**
   - Plug/unplug your device
   - Watch for Live Activity on lock screen and Dynamic Island
   - Check console logs for charging events

## 🔧 Troubleshooting

### OneSignal Not Connecting
**Symptoms:**
- App shows "Not connected"
- No device token displayed

**Solutions:**
1. Check internet connection
2. Verify OneSignal App ID is correct
3. Check console for OneSignal initialization errors
4. Ensure notification permissions are granted

### Live Activity Not Appearing
**Symptoms:**
- Push notifications work but no Live Activity
- No Dynamic Island or lock screen activity

**Solutions:**
1. **Check Live Activity Capability:**
   - In Xcode, select your app target
   - Go to "Signing & Capabilities"
   - Ensure "Live Activity" is added

2. **Check Info.plist:**
   - Verify `NSSupportsLiveActivities` is set to `true`

3. **Check Console Logs:**
   - Look for Live Activity creation errors
   - Check for permission issues

4. **Test on Physical Device:**
   - Live Activities work best on physical devices
   - Simulator may have limitations

### Push Notifications Not Working
**Symptoms:**
- No notifications received
- OneSignal API returns "not subscribed"

**Solutions:**
1. **Check Device Registration:**
   - Ensure app has run at least once
   - Check OneSignal dashboard for registered devices

2. **Check Permissions:**
   - Go to Settings → PETL → Notifications
   - Ensure notifications are enabled

3. **Check OneSignal Configuration:**
   - Verify App ID and API Key
   - Check OneSignal dashboard for any errors

## 📱 Testing Live Activity

### Method 1: Charging Detection
1. Run the app
2. Plug in your device
3. Watch for Live Activity on lock screen
4. Unplug device - Live Activity should end

### Method 2: Manual Push
1. Get device token from app
2. Send push notification with:
```json
{
  "live_activity_action": "start",
  "custom_data": {
    "emoji": "🔌",
    "message": "Device is charging"
  }
}
```

### Method 3: OneSignal Dashboard
1. Go to OneSignal Dashboard
2. Create a new push notification
3. Add custom data:
   - `live_activity_action`: `start`
   - `custom_data`: `{"emoji": "🔌", "message": "Test"}`
4. Send to your device

## 🐛 Common Issues

### Issue: "Cannot find type 'PETLLiveActivityExtensionAttributes'"
**Solution:** Ensure the Live Activity extension target is properly linked.

### Issue: "OneSignal module not found"
**Solution:** 
1. Clean build folder (Cmd+Shift+K)
2. Rebuild project
3. Check Package Dependencies

### Issue: Live Activity API deprecation warnings
**Solution:** These are warnings, not errors. The app will still work.

### Issue: No Dynamic Island on simulator
**Solution:** Dynamic Island only appears on iPhone 14 Pro and newer. Use a physical device for testing.

## 📊 Expected Behavior

### When Working Correctly:
1. **App Launch:**
   - OneSignal status shows "Connected"
   - Device token is displayed
   - Console shows OneSignal initialization logs

2. **Charging Detection:**
   - Live Activity appears on lock screen
   - Dynamic Island shows activity (on supported devices)
   - Console logs charging events

3. **Push Notifications:**
   - Notifications are received
   - Live Activity updates via OneSignal
   - Console shows notification handling logs

## 🎯 Next Steps

1. **Run the app** on your device
2. **Check OneSignal status** in the app
3. **Test charging detection** by plugging/unplugging
4. **Send test notifications** using the script
5. **Verify Live Activity** appears on lock screen and Dynamic Island

## 📞 Support

If you encounter issues:
1. Check Xcode console for error messages
2. Verify OneSignal dashboard for device registration
3. Test on a physical device (not simulator)
4. Ensure all capabilities are properly configured

---

**Remember:** Live Activities work best on physical devices, especially for Dynamic Island testing. 