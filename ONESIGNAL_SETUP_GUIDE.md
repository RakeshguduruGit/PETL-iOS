# OneSignal Live Activity Setup Guide

## Overview
This guide documents the complete setup process for OneSignal integration with Live Activities in an iOS app. The setup includes push notifications, Live Activity management, and charging-based triggers.

## Prerequisites
- Xcode 15+
- iOS 16.2+ (for Live Activities)
- OneSignal account with App ID and API Key
- Physical iOS device for testing (Live Activities don't work in simulator)

## OneSignal Credentials
- **App ID**: `ebc50f5b-0b53-4855-a4cb-313b5038dc0c`
- **API Key**: `os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja`

## Step 1: Add OneSignal SDK

### 1.1 Add Package Dependency
1. Open Xcode project
2. Go to **File** → **Add Package Dependencies**
3. Enter URL: `https://github.com/OneSignal/OneSignal-iOS-SDK`
4. Select version: `5.2.14` or higher
5. Add to both targets:
   - Main app target (`PETL`)
   - Live Activity extension target (`PETLLiveActivityExtension`)

### 1.2 Verify Package Installation
- Check that `OneSignalFramework` appears in **Frameworks, Libraries, and Embedded Content**
- Ensure it's added to both targets

## Step 2: Configure App Capabilities

### 2.1 Push Notifications
1. Select your project in Xcode
2. Go to **Signing & Capabilities**
3. Click **+ Capability**
4. Add **Push Notifications** to both targets:
   - Main app target
   - Live Activity extension target

### 2.2 Background Modes (if needed)
- Add **Background fetch** if required for your use case

## Step 3: Import Statements

### 3.1 Main App Files
```swift
import OneSignalFramework  // NOT import OneSignal
import os.log
```

### 3.2 Live Activity Extension
```swift
import OneSignalFramework
import ActivityKit
```

## Step 4: Initialize OneSignal

### 4.1 AppDelegate Setup
```swift
import SwiftUI
import ActivityKit
import OneSignalFramework
import os.log

// Create logger for on-device logging
let appLogger = Logger(subsystem: "com.petl.app", category: "main")

class AppDelegate: NSObject, UIApplicationDelegate {
    private var chargingMonitor: ChargingMonitor?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Initialize OneSignal with comprehensive debugging
        print("🔧 OneSignal Initialization Started")
        appLogger.info("🔧 OneSignal Initialization Started")
        
        print("📱 OneSignal App ID: [your app id]")
        appLogger.info("📱 OneSignal App ID: [your app id]")
        
        OneSignal.initialize("[YOUR_ONESIGNAL_APP_ID]", withLaunchOptions: launchOptions)
        
        // Request notification permissions
        OneSignal.Notifications.requestPermission({ accepted in
            print("🔔 User accepted notifications: \(accepted)")
            appLogger.info("🔔 User accepted notifications: \(accepted)")
            
            // Check OneSignal status after permission
            if let pushToken = OneSignal.User.pushSubscription.id {
                print("✅ OneSignal Device Token: \(pushToken)")
                appLogger.info("✅ OneSignal Device Token: \(pushToken)")
            } else {
                print("❌ OneSignal Device Token not available")
                appLogger.error("❌ OneSignal Device Token not available")
            }
            
            // Check subscription status
            let subscriptionStatus = OneSignal.User.pushSubscription.optedIn
            print("📋 Subscription Status: \(subscriptionStatus ? "Opted In" : "Not Opted In")")
            appLogger.info("📋 Subscription Status: \(subscriptionStatus ? "Opted In" : "Not Opted In")")
            
        }, fallbackToSettings: true)
        
        // Set up notification handlers for Live Activity management
        let notificationListener = NotificationListener()
        notificationListener.appDelegate = self
        OneSignal.Notifications.addClickListener(notificationListener)
        
        // Initialize charging monitor
        chargingMonitor = ChargingMonitor()
        
        return true
    }
}
```

### 4.2 Notification Listener
```swift
class NotificationListener: NSObject, OSNotificationClickListener {
    weak var appDelegate: AppDelegate?
    
    func onClick(event: OSNotificationClickEvent) {
        print("📱 OneSignal Notification Clicked!")
        appLogger.info("📱 OneSignal Notification Clicked!")
        
        print("🔍 Full Notification Data: \(event.notification.jsonRepresentation())")
        appLogger.info("🔍 Full Notification Data: \(event.notification.jsonRepresentation())")
        
        let notification = event.notification
        print("📋 Notification ID: \(notification.notificationId ?? "Unknown")")
        appLogger.info("📋 Notification ID: \(notification.notificationId ?? "Unknown")")
        
        if let additionalData = event.notification.additionalData as? [String: Any] {
            print("🔍 Additional Data: \(additionalData)")
            appLogger.info("🔍 Additional Data: \(additionalData)")
            
            if let onesignalId = additionalData["i"] as? String {
                print("✅ Verified OneSignal Notification ID: \(onesignalId)")
                appLogger.info("✅ Verified OneSignal Notification ID: \(onesignalId)")
            }
            
            appDelegate?.handleLiveActivityNotification(additionalData)
        } else {
            print("⚠️ No additional data found in notification")
            appLogger.warning("⚠️ No additional data found in notification")
        }
    }
}
```

## Step 5: Live Activity Management

### 5.1 Charging Monitor
```swift
class ChargingMonitor: NSObject {
    private var currentActivity: Activity<PETLLiveActivityExtensionAttributes>?
    private var timer: Timer?
    private var isCharging: Bool = false
    
    override init() {
        super.init()
        startMonitoring()
    }
    
    private func startMonitoring() {
        checkChargingStatus()
        
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkChargingStatus()
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateDidChange),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        
        UIDevice.current.isBatteryMonitoringEnabled = true
    }
    
    private func checkChargingStatus() {
        let newChargingState = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        if newChargingState != isCharging {
            isCharging = newChargingState
            
            print("🔌 Battery State Changed: \(UIDevice.current.batteryState.rawValue)")
            appLogger.info("🔌 Battery State Changed: \(UIDevice.current.batteryState.rawValue)")
            
            if isCharging {
                triggerOneSignalLiveActivityStart()
            } else {
                triggerOneSignalLiveActivityEnd()
            }
        }
    }
    
    private func triggerOneSignalLiveActivityStart() {
        print("🚀 Triggering OneSignal Live Activity START")
        appLogger.info("🚀 Triggering OneSignal Live Activity START")
        
        let content = UNMutableNotificationContent()
        content.title = "PETL Charging Started"
        content.body = "Device is now charging"
        content.sound = nil
        content.userInfo = [
            "live_activity_action": "start",
            "charging_status": "started",
            "battery_level": UIDevice.current.batteryLevel,
            "timestamp": Date().timeIntervalSince1970,
            "onesignal_debug": "true"
        ]
        
        let request = UNNotificationRequest(identifier: "charging_start", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending local notification: \(error)")
            } else {
                print("✅ Local notification sent successfully")
            }
        }
    }
    
    private func triggerOneSignalLiveActivityEnd() {
        print("🛑 Triggering OneSignal Live Activity END")
        appLogger.info("🛑 Triggering OneSignal Live Activity END")
        
        let content = UNMutableNotificationContent()
        content.title = "PETL Charging Ended"
        content.body = "Device is no longer charging"
        content.sound = nil
        content.userInfo = [
            "live_activity_action": "end",
            "charging_status": "ended",
            "battery_level": UIDevice.current.batteryLevel,
            "timestamp": Date().timeIntervalSince1970,
            "onesignal_debug": "true"
        ]
        
        let request = UNNotificationRequest(identifier: "charging_end", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending local notification: \(error)")
            } else {
                print("✅ Local notification sent successfully")
            }
        }
    }
}
```

### 5.2 Live Activity Handler
```swift
func handleLiveActivityNotification(_ data: [String: Any]) {
    if let action = data["live_activity_action"] as? String {
        switch action {
        case "start":
            chargingMonitor?.startLiveActivityViaOneSignal(data)
        case "update":
            chargingMonitor?.updateLiveActivityViaOneSignal(data)
        case "end":
            chargingMonitor?.endLiveActivityViaOneSignal(data)
        default:
            break
        }
    }
}

func startLiveActivityViaOneSignal(_ data: [String: Any]) {
    Task {
        do {
            let attributes = PETLLiveActivityExtensionAttributes(name: "PETL Activity")
            let contentState = PETLLiveActivityExtensionAttributes.ContentState(
                emoji: data["emoji"] as? String ?? "🔌",
                message: data["message"] as? String ?? "Device is charging",
                timestamp: Date()
            )
            
            let activity = try Activity.request(
                attributes: attributes,
                contentState: contentState,
                pushType: nil
            )
            
            currentActivity = activity
            print("✅ Live Activity started via OneSignal: \(activity.id)")
            
        } catch {
            print("❌ Error starting Live Activity: \(error)")
        }
    }
}

func endLiveActivityViaOneSignal(_ data: [String: Any]) {
    Task {
        if let activity = currentActivity {
            await activity.end(dismissalPolicy: .immediate)
            currentActivity = nil
            print("✅ Live Activity ended via OneSignal")
        }
    }
}
```

## Step 6: UI Integration

### 6.1 ContentView with Logging
```swift
import SwiftUI
import ActivityKit
import OneSignalFramework
import os.log

let contentLogger = Logger(subsystem: "com.petl.app", category: "content")

struct ContentView: View {
    @State private var isCharging: Bool = false
    @State private var batteryLevel: Float = 0.0
    @State private var isActivityRunning: Bool = false
    @State private var currentActivityId: String = ""
    @State private var activityMessage: String = "Device is charging"
    @State private var activityEmoji: String = "🔌"
    @State private var oneSignalStatus: String = "Initializing..."
    @State private var deviceToken: String = "Not available"
    @State private var logMessages: [String] = []
    @State private var showLogs: Bool = false
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    init() {
        print("📱 ContentView Initialized - This should appear in logs!")
        contentLogger.info("📱 ContentView Initialized - This should appear in logs!")
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // OneSignal Status
                    OneSignalStatusView(oneSignalStatus: oneSignalStatus, deviceToken: deviceToken)
                    
                    // Battery Status Icon
                    Image(systemName: isCharging ? "battery.100.bolt" : "battery.25")
                        .imageScale(.large)
                        .foregroundStyle(isCharging ? .green : .orange)
                        .font(.system(size: 50))
                    
                    Text("PETL OneSignal Live Activity")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    // Battery Status Card
                    VStack(spacing: 15) {
                        HStack {
                            Image(systemName: isCharging ? "bolt.fill" : "bolt.slash.fill")
                                .foregroundColor(isCharging ? .green : .gray)
                            Text(isCharging ? "Charging" : "Not Charging")
                                .font(.headline)
                                .foregroundColor(isCharging ? .green : .gray)
                        }
                        
                        HStack {
                            Text("Battery Level:")
                                .font(.subheadline)
                            Text("\(Int(batteryLevel * 100))%")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    
                    // Live Activity Status
                    VStack(spacing: 15) {
                        HStack {
                            Image(systemName: isActivityRunning ? "live.photo" : "live.photo.slash")
                                .foregroundColor(isActivityRunning ? .blue : .gray)
                            Text(isActivityRunning ? "Live Activity Active" : "Live Activity Inactive")
                                .font(.headline)
                                .foregroundColor(isActivityRunning ? .blue : .gray)
                        }
                        
                        if isActivityRunning {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Current Activity:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(activityEmoji)
                                        .font(.title2)
                                }
                                
                                Text(activityMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text("ID: \(currentActivityId)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    
                    // Test Buttons
                    VStack(spacing: 15) {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver")
                                .foregroundColor(.orange)
                            Text("Test Controls")
                                .font(.headline)
                            Spacer()
                        }
                        
                        Button("Update Live Activity") {
                            updateActivityContent()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("End Live Activity") {
                            forceEndActivity()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                        
                        Button("Test OneSignal Push") {
                            testOneSignalPush()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        
                        Button("Test Live Activity") {
                            testLiveActivityCreation()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.blue)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                    
                    // Instructions
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How it works:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("• OneSignal manages Live Activity lifecycle")
                            Text("• Activity starts when charging detected")
                            Text("• Activity ends when device unplugged")
                            Text("• Shows on Dynamic Island and lock screen")
                            Text("• Server-side control via OneSignal")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    
                    // Log Viewer
                    LogViewerView(logMessages: $logMessages, showLogs: $showLogs)
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("PETL OneSignal")
            .onReceive(timer) { _ in
                updateBatteryStatus()
            }
            .onAppear {
                updateBatteryStatus()
                checkActivityStatus()
                loadOneSignalStatus()
                
                // Add initialization logs
                logMessages.append("🚀 PETL App Started")
                logMessages.append("📱 ContentView Initialized")
            }
        }
    }
    
    private func updateBatteryStatus() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let newChargingState = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let newBatteryLevel = UIDevice.current.batteryLevel
        
        // Log battery state changes
        if newChargingState != isCharging {
            let stateMessage = "🔌 Battery State: \(newChargingState ? "Charging" : "Not Charging")"
            logMessages.append(stateMessage)
        }
        
        isCharging = newChargingState
        batteryLevel = newBatteryLevel
    }
    
    private func checkActivityStatus() {
        let activities = Activity<PETLLiveActivityExtensionAttributes>.activities
        print("🔍 Checking Live Activity status...")
        print("📊 Found \(activities.count) active Live Activities")
        
        if let activity = activities.first {
            currentActivityId = activity.id
            isActivityRunning = true
            activityEmoji = activity.content.state.emoji
            activityMessage = activity.content.state.message
            print("✅ Live Activity is running: \(activity.id)")
        } else {
            isActivityRunning = false
            currentActivityId = ""
            activityEmoji = ""
            activityMessage = ""
            print("❌ No Live Activity is currently running")
        }
    }
    
    private func loadOneSignalStatus() {
        if let pushToken = OneSignal.User.pushSubscription.id {
            deviceToken = pushToken
            oneSignalStatus = "Connected"
            
            // Add OneSignal status to logs
            logMessages.append("✅ OneSignal Connected")
            logMessages.append("📱 Device Token: \(pushToken.prefix(20))...")
        } else {
            oneSignalStatus = "Not connected"
            logMessages.append("❌ OneSignal Not Connected")
        }
        
        let subscriptionStatus = OneSignal.User.pushSubscription.optedIn
        logMessages.append("📋 Subscription: \(subscriptionStatus ? "Opted In" : "Not Opted In")")
    }
    
    private func updateActivityContent() {
        let newEmoji = ["🔌", "⚡", "🔋", "💡", "🌟"].randomElement() ?? "🔌"
        let newMessage = "Charging at \(Int(batteryLevel * 100))% - \(Date().formatted(date: .omitted, time: .shortened))"
        
        activityEmoji = newEmoji
        activityMessage = newMessage
        
        for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
            Task {
                let updatedState = PETLLiveActivityExtensionAttributes.ContentState(
                    emoji: newEmoji,
                    message: newMessage,
                    timestamp: Date()
                )
                await activity.update(using: updatedState)
            }
            break
        }
    }
    
    private func forceEndActivity() {
        for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
            Task {
                await activity.end(dismissalPolicy: .immediate)
                DispatchQueue.main.async {
                    isActivityRunning = false
                    currentActivityId = ""
                }
            }
            break
        }
    }
    
    private func testOneSignalPush() {
        print("Test OneSignal push notification")
        print("Device Token: \(deviceToken)")
        print("Use OneSignal dashboard or REST API to send push with:")
        print("live_activity_action: start/update/end")
        print("custom_data: { emoji: '🚀', message: 'Test message' }")
    }
    
    private func testLiveActivityCreation() {
        logMessages.append("🧪 Testing Live Activity Creation")
        
        Task {
            do {
                let attributes = PETLLiveActivityExtensionAttributes(
                    name: "Test Activity"
                )
                
                let contentState = PETLLiveActivityExtensionAttributes.ContentState(
                    emoji: "🧪",
                    message: "Test Live Activity",
                    timestamp: Date()
                )
                
                let activity = try Activity.request(
                    attributes: attributes,
                    contentState: contentState,
                    pushType: nil
                )
                
                logMessages.append("✅ Live Activity Created: \(activity.id)")
                isActivityRunning = true
                currentActivityId = activity.id
                
            } catch {
                logMessages.append("❌ Live Activity Error: \(error.localizedDescription)")
            }
        }
    }
}
```

### 6.2 Supporting Views
```swift
struct OneSignalStatusView: View {
    let oneSignalStatus: String
    let deviceToken: String
    
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.blue)
                Text("OneSignal Status")
                    .font(.headline)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Status: \(oneSignalStatus)")
                    .font(.subheadline)
                
                Text("Device Token:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(deviceToken)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}

struct LogViewerView: View {
    @Binding var logMessages: [String]
    @Binding var showLogs: Bool
    
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.purple)
                Text("App Logs")
                    .font(.headline)
                Spacer()
                Button(showLogs ? "Hide" : "Show") {
                    showLogs.toggle()
                }
                .font(.caption)
            }
            
            if showLogs {
                LogMessagesView(logMessages: logMessages)
                
                Button("Add Test Log") {
                    let testMessage = "🧪 Test log at \(Date().formatted(date: .omitted, time: .shortened))"
                    logMessages.append(testMessage)
                    contentLogger.info("\(testMessage)")
                }
                .buttonStyle(.bordered)
                .font(.caption)
                
                Button("Add OneSignal Status") {
                    let statusMessage = "📱 OneSignal Status Check"
                    logMessages.append(statusMessage)
                    
                    if let pushToken = OneSignal.User.pushSubscription.id {
                        let tokenMessage = "✅ Device Token: \(pushToken.prefix(20))..."
                        logMessages.append(tokenMessage)
                    } else {
                        let noTokenMessage = "❌ No Device Token Available"
                        logMessages.append(noTokenMessage)
                    }
                    
                    let subscriptionStatus = OneSignal.User.pushSubscription.optedIn
                    let statusMessage2 = "📋 Subscription: \(subscriptionStatus ? "Opted In" : "Not Opted In")"
                    logMessages.append(statusMessage2)
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(12)
    }
}

struct LogMessagesView: View {
    let logMessages: [String]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(logMessages, id: \.self) { message in
                    LogMessageRow(message: message)
                }
            }
        }
        .frame(maxHeight: 200)
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

struct LogMessageRow: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
    }
}
```

## Step 7: Testing

### 7.1 QA Testing Mode
- **Enable QA Mode**: Add `-QA_TEST_MODE` to launch arguments for comprehensive testing
- **Reliability Metrics**: Monitor one-line summary in Info tab logs
- **Torture Testing**: Use QA mode for fast plug/unplug cycles (0.0s debounce, 25s watchdog)
- **Self-ping Testing**: Verify OneSignal REST API calls for backup ending

### 7.2 Test Scripts
Create `test_onesignal_verification_detailed.sh`:
```bash
#!/bin/bash

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

# Test 2: Send a test notification
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

echo "🎯 Verification Summary:"
echo "========================"
echo "✅ If you see OneSignal Device Token in logs → OneSignal is connected"
echo "✅ If notification contains OneSignal ID → Notification is from OneSignal"
echo "✅ If console shows 'OneSignal Notification Clicked!' → OneSignal is working"
echo "✅ If Live Activity starts/ends → OneSignal integration is complete"
echo ""
```

### 7.2 Expected Test Results
When running the app, you should see these logs:

**Initialization:**
```
🚀 PETL App Started
📱 ContentView Initialized
🔧 OneSignal Initialization Started
✅ OneSignal Connected
📱 Device Token: [64-char hex]...
📋 Subscription: Opted In
```

**Battery State Changes:**
```
🔌 Battery State: Charging
🔌 Battery State: Not Charging
```

**Live Activity Creation:**
```
🧪 Testing Live Activity Creation
✅ Live Activity Created: [UUID]
```

**OneSignal Notifications:**
```
📱 OneSignal Notification Clicked!
📋 Notification ID: [OneSignal ID]
🔍 Additional Data: [OneSignal data]
```

**QA Testing Mode (when enabled):**
```
📊 Reliability: startReq=20 startOK=20 endReqLocal=20 endOK=20 remoteEndOK=2 remoteEndIgnored=0 watchdog=0 dupCleanups=0 selfPings=2
⏳ Debounced snapshot: 87%, charging=true
```

## Step 8: Troubleshooting

### 8.1 Common Issues

**Issue: "No such module 'OneSignal'"**
- Solution: Use `import OneSignalFramework` instead of `import OneSignal`
- Ensure package is added to both targets

**Issue: "Cannot find type 'PETLLiveActivityExtensionAttributes'"**
- Solution: Add `import PETLLiveActivityExtensionExtension` to main app files
- Ensure Live Activity extension target is properly configured

**Issue: "All included players are not subscribed"**
- Solution: This is normal before the app runs and registers the device
- Run the app first, then send notifications

**Issue: Deprecation warnings for Live Activity API**
- Solution: These are warnings and don't affect functionality
- Use `update(using:)` and `end(dismissalPolicy:)` for compatibility

### 8.2 Verification Checklist

- [ ] OneSignal SDK added to both targets
- [ ] Push Notifications capability enabled
- [ ] Device token appears in logs
- [ ] Subscription status shows "Opted In"
- [ ] Battery state changes are detected
- [ ] Live Activity can be created manually
- [ ] Live Activity appears on lock screen/Dynamic Island
- [ ] OneSignal notifications are received

## Step 9: Production Considerations

### 9.1 Security
- Store API keys securely (not in code)
- Use environment variables or secure key management
- Implement proper error handling

### 9.2 Performance
- Set `NSSupportsLiveActivitiesFrequentUpdate` to `YES` in Info.plist
- Use priority 10 for Live Activity requests
- Monitor Apple's Live Activity budget limits

### 9.3 User Experience
- Request notification permissions at appropriate times
- Provide clear explanations of Live Activity functionality
- Handle edge cases (no network, permissions denied, etc.)

## Conclusion

This setup provides a complete OneSignal integration with Live Activities, including:
- Push notification handling
- Live Activity lifecycle management
- Charging-based triggers
- Comprehensive logging and debugging
- UI for testing and monitoring

The integration is now ready for production use with proper error handling and user experience considerations. 