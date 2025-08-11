# 📱 Viewing Logs on Your iPhone

## 🔍 **Method 1: In-App Log Viewer**

1. **Run the PETL app** on your iPhone
2. **Scroll down** to find the "App Logs" section
3. **Tap "Show"** to display the log viewer
4. **Tap "Add Test Log"** to add a test message
5. **Check the logs** in the scrollable area

## 🔍 **Method 2: Console App (Mac)**

1. **Connect your iPhone** to your Mac
2. **Open Console app** on your Mac
3. **Select your iPhone** from the left sidebar
4. **Filter by "PETL"** in the search box
5. **Look for logs** with these prefixes:
   - `🔧 OneSignal Initialization Started`
   - `📱 OneSignal App ID:`
   - `✅ OneSignal Device Token:`
   - `🔌 Battery State Changed:`
   - `📱 OneSignal Notification Clicked!`

## 🔍 **Method 3: Xcode Console**

1. **Open Xcode** and run the app
2. **Press Cmd+Shift+C** to open console
3. **Click the filter button** (funnel icon)
4. **Select "PETL"** from the process list
5. **Look for the logs** in the console

## 🔍 **Method 4: Device Logs (iOS 15+)**

1. **Go to Settings** → **Privacy & Security**
2. **Scroll down** to **Analytics & Improvements**
3. **Tap "Analytics Data"**
4. **Search for "PETL"** or "com.petl.app"
5. **View the log files** (if any)

## 🧪 **Test Steps:**

1. **Run the app** and check the in-app log viewer
2. **Plug/unplug your device** to trigger battery logs
3. **Send a test notification** using the verification script
4. **Check for OneSignal logs** in the console

## 📋 **Expected Logs:**

### When App Starts:
```
🚀 PETL App Started - You should see this log!
📱 ContentView Initialized - This should appear in logs!
🔧 OneSignal Initialization Started
📱 OneSignal App ID: [your app id]
✅ OneSignal Device Token: [64-char hex]
```

### When Charging/Unplugging:
```
🔌 Battery State Changed: [state]
🔋 Battery Level: [percentage]%
⚡ Is Charging: [true/false]
🔌 Device started/stopped charging - triggering OneSignal notification
```

### When Receiving Notifications:
```
📱 OneSignal Notification Clicked!
📋 Notification ID: [OneSignal ID]
📝 Notification Title: [Title]
📄 Notification Body: [Body]
🔍 Additional Data: [OneSignal data]
```

## ❌ **If You Don't See Logs:**

1. **Check the in-app log viewer** first
2. **Make sure the app is running**
3. **Try the "Add Test Log" button**
4. **Check Xcode console** with proper filtering
5. **Restart the app** if needed

## 🎯 **Quick Test:**

1. **Open the app**
2. **Scroll to "App Logs" section**
3. **Tap "Show"**
4. **Tap "Add Test Log"**
5. **You should see the test message appear**

This will confirm that logging is working on your device! 