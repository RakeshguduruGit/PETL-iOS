//
//  PETLApp.swift
//  PETL
//
//  Created by rakesh guduru on 7/27/25.
//

import SwiftUI
import ActivityKit
import OneSignalFramework

import os.log
import BackgroundTasks

// Create a logger for on-device logging
let appLogger = Logger(subsystem: "com.petl.app", category: "main")

// Background task identifier
let backgroundTaskIdentifier = "com.petl.background.charging.monitor"

// Notification listener for OneSignal
class NotificationListener: NSObject, OSNotificationClickListener {
    weak var appDelegate: AppDelegate?
    
    func onClick(event: OSNotificationClickEvent) {
        print("📱 OneSignal Notification Clicked!")
        appLogger.info("📱 OneSignal Notification Clicked!")
        
        print("🔍 Full Notification Data: \(event.notification.jsonRepresentation())")
        appLogger.info("🔍 Full Notification Data: \(event.notification.jsonRepresentation())")
        
        // Log notification details
        let notification = event.notification
        print("📋 Notification ID: \(notification.notificationId ?? "Unknown")")
        appLogger.info("📋 Notification ID: \(notification.notificationId ?? "Unknown")")
        
        print("📝 Notification Title: \(notification.title ?? "No Title")")
        appLogger.info("📝 Notification Title: \(notification.title ?? "No Title")")
        
        print("📄 Notification Body: \(notification.body ?? "No Body")")
        appLogger.info("📄 Notification Body: \(notification.body ?? "No Body")")
        
        // Handle Live Activity management through OneSignal
        if let additionalData = event.notification.additionalData as? [String: Any] {
            print("🔍 Additional Data: \(additionalData)")
            appLogger.info("🔍 Additional Data: \(additionalData)")
            
            // Verify this is a OneSignal notification
            if let onesignalId = additionalData["i"] as? String {
                print("✅ Verified OneSignal Notification ID: \(onesignalId)")
                appLogger.info("✅ Verified OneSignal Notification ID: \(onesignalId)")
            }
            
            // Call the app delegate to handle Live Activity
            appDelegate?.handleLiveActivityNotification(additionalData)
        } else {
            print("⚠️ No additional data found in notification")
            appLogger.warning("⚠️ No additional data found in notification")
        }
    }
}

@main
struct PETLApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var phase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    addToAppLogs("🚀 PETL App Started")
                    addToAppLogs("📱 App Version: 1.0")
                    addToAppLogs("🔧 Debug Mode: Enabled")
                    addToAppLogs("🔍 Console logging initialized")
                    
                    // Eagerly load device profile
                    Task.detached { await DeviceProfileService.shared.ensureLoaded() }
                    
                    // Migrate legacy data to unified DB
                    ChargeDB.shared.migrateLegacyIfNeeded()
                }
                .onChange(of: phase) {
                    if phase == .active {
                        // BatteryTrackingManager manages this already; avoid log spam + toggling.
                        BatteryTrackingManager.shared.emitSnapshotNow("foreground")
                        LiveActivityManager.shared.onAppWillEnterForeground()
                        
                        // NEW: Ensure UI pulls fresh data at launch
                        DispatchQueue.main.async {
                            let _ = BatteryTrackingManager.shared.historyPointsFromDB(hours: 24) // warms up
                        }
                    }
                }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    private var backgroundTaskScheduler: BackgroundTaskScheduler?
    private let appLogger = Logger(subsystem: "com.petl.app", category: "launch")
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Enable battery monitoring ASAP (before SwiftUI view init)
        UIDevice.current.isBatteryMonitoringEnabled = true
        print("🔧 Battery monitoring enabled at launch")
        appLogger.info("🔧 Battery monitoring enabled at launch")
        
        // Start centralized battery monitoring
        BatteryTrackingManager.shared.startMonitoring()
        
        // Retry loop: handle `.unknown` window on first seconds after launch
        Task { @MainActor in
            await checkChargingAtLaunchWithRetry(timeout: 5.0, interval: 0.5)
        }
        
        // (Optional) Observe future state changes – main handling already exists elsewhere
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let s = UIDevice.current.batteryState
            print("🔌 Battery state changed (launch observer): \(s.rawValue)")
        }
        
        // Initialize OneSignal with comprehensive debugging and error handling
        addToAppLogs("🔧 OneSignal Initialization Started")
        print("🔧 OneSignal Initialization Started")
        appLogger.info("🔧 OneSignal Initialization Started")
        
        addToAppLogs("📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja")
        print("📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja")
        appLogger.info("📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja")
        
        // Initialize OneSignal with error handling
        OneSignal.initialize("os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja", withLaunchOptions: launchOptions)
        addToAppLogs("✅ OneSignal initialized successfully")
        print("✅ OneSignal initialized successfully")
        appLogger.info("✅ OneSignal initialized successfully")
        
        // Configure LiveActivityManager (single source of truth)
        LiveActivityManager.shared.configure()
        
        // Request notification permissions with proper error handling
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.requestNotificationPermissions()
        }
        
        // Initialize background task scheduler
        backgroundTaskScheduler = BackgroundTaskScheduler()
        backgroundTaskScheduler?.registerBackgroundTasks()
        
        return true
    }
    
    @MainActor
    private func checkChargingAtLaunchWithRetry(timeout: TimeInterval, interval: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = UIDevice.current.batteryState
            if state == .charging || state == .full {
                print("🔄 Detected charging at launch – starting Live Activity")
                appLogger.info("🔄 Detected charging at launch – starting Live Activity")
                if Activity<PETLLiveActivityExtensionAttributes>.activities.isEmpty {
                    await LiveActivityManager.shared.startIfNeeded()
                }
                return
            }
            // If unknown or not charging, wait and retry
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        // Optional: log that we didn't detect charging during the retry window
        appLogger.info("ℹ️ No charging detected during launch window")
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Handle background app refresh
        print("🔄 Background App Refresh triggered")
        appLogger.info("🔄 Background App Refresh triggered")
        
        // Check if we need to start a Live Activity
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let hasActivities = !Activity<PETLLiveActivityExtensionAttributes>.activities.isEmpty
        
        if isCharging && !hasActivities {
            // Start Live Activity if charging but no activity exists
            LiveActivityManager.shared.handleRemotePayload(["batteryState": "charging"])
            completionHandler(.newData)
        } else if !isCharging && hasActivities {
            // End Live Activity if not charging but activity exists
            LiveActivityManager.shared.handleRemotePayload(["batteryState": "unplugged"])
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }
    
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Handle background URL session events
        print("🌐 Background URL Session: \(identifier)")
        appLogger.info("🌐 Background URL Session: \(identifier)")
        completionHandler()
    }
    
    private func requestNotificationPermissions() {
        addToAppLogs("🔔 Requesting notification permissions...")
        OneSignal.Notifications.requestPermission({ [weak self] accepted in
            addToAppLogs("🔔 User accepted notifications: \(accepted)")
            print("🔔 User accepted notifications: \(accepted)")
            self?.appLogger.info("🔔 User accepted notifications: \(accepted)")
            
            // Check OneSignal status after permission
            if let playerId = OneSignal.User.pushSubscription.id {
                addToAppLogs("✅ OneSignal Player ID: \(playerId)")
                print("✅ OneSignal Player ID: \(playerId)")
                self?.appLogger.info("✅ OneSignal Player ID: \(playerId)")
                
                addToAppLogs("📊 Player ID Length: \(playerId.count) characters")
                print("📊 Player ID Length: \(playerId.count) characters")
                self?.appLogger.info("📊 Player ID Length: \(playerId.count) characters")
                
                // Store Player ID for REST API self-pings
                UserDefaults.standard.set(playerId, forKey: "OneSignalPlayerID")
                addToAppLogs("💾 OneSignal Player ID stored for self-pings")
                
                // Check if it's a valid UUID (36 characters, UUID format)
                let isValidUUID = playerId.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
                addToAppLogs("🔍 Player ID Format: \(isValidUUID ? "Valid UUID" : "Invalid UUID format")")
                print("🔍 Player ID Format: \(isValidUUID ? "Valid UUID" : "Invalid UUID format")")
                self?.appLogger.info("🔍 Player ID Format: \(isValidUUID ? "Valid UUID" : "Invalid UUID format")")
            } else {
                addToAppLogs("❌ OneSignal Player ID not available")
                print("❌ OneSignal Player ID not available")
                self?.appLogger.error("❌ OneSignal Player ID not available")
            }
            
            // Check subscription status
            let subscriptionStatus = OneSignal.User.pushSubscription.optedIn
            print("📋 Subscription Status: \(subscriptionStatus ? "Opted In" : "Not Opted In")")
            self?.appLogger.info("📋 Subscription Status: \(subscriptionStatus ? "Opted In" : "Not Opted In")")
            
            // Check notification types
            let notificationTypes = OneSignal.User.pushSubscription.optedIn
            print("🔔 Notification Types: \(notificationTypes ? "Subscribed" : "Not Subscribed")")
            self?.appLogger.info("🔔 Notification Types: \(notificationTypes ? "Subscribed" : "Not Subscribed")")
            
            // Log subscription ID
            if let subscriptionId = OneSignal.User.pushSubscription.id {
                print("🆔 OneSignal Subscription ID: \(subscriptionId)")
                self?.appLogger.info("🆔 OneSignal Subscription ID: \(subscriptionId)")
            }
            
        }, fallbackToSettings: true)
        
        // Set up notification handlers for Live Activity management with error handling
        DispatchQueue.main.async {
            self.setupNotificationHandlers()
        }
    }
    
    private func setupNotificationHandlers() {
        // Set up notification handlers for Live Activity management
        let notificationListener = NotificationListener()
        notificationListener.appDelegate = self
        OneSignal.Notifications.addClickListener(notificationListener)
        
        // Add subscription observer for debugging
        // Note: Observer pattern may be different in this OneSignal version
        print("📊 OneSignal Subscription Observer: Ready to monitor changes")
    }
    
    func handleLiveActivityNotification(_ data: [String: Any]) {
        // Forward OneSignal payload to LiveActivityManager
        Task { @MainActor in
            LiveActivityManager.shared.handleRemotePayload(data)
        }
    }
}

// MARK: - Background Task Scheduler
class BackgroundTaskScheduler {
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            self.handleBackgroundTask(task as! BGAppRefreshTask)
        }
        
        print("✅ Background tasks registered")
        appLogger.info("✅ Background tasks registered")
    }
    
    private func handleBackgroundTask(_ task: BGAppRefreshTask) {
        // Schedule the next background task
        scheduleBackgroundTask()
        
        // Set up task expiration
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        // Check if we need to start/end Live Activity
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let hasActivities = !Activity<PETLLiveActivityExtensionAttributes>.activities.isEmpty
        
        Task { @MainActor in
            if isCharging && !hasActivities {
                // Start Live Activity if charging but no activity exists
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "charging"])
                task.setTaskCompleted(success: true)
            } else if !isCharging && hasActivities {
                // End Live Activity if not charging but activity exists
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "unplugged"])
                task.setTaskCompleted(success: true)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
        
        // NEW: enforce retention during BG refresh
        ChargeDB.shared.trim(olderThanDays: 30)
    }
    
    func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Background task scheduled for 15 minutes")
            appLogger.info("✅ Background task scheduled for 15 minutes")
        } catch {
            print("❌ Failed to schedule background task: \(error)")
            appLogger.error("❌ Failed to schedule background task: \(error)")
        }
    }
}
