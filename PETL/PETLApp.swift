//
//  PETLApp.swift
//  PETL
//
//  Created by rakesh guduru on 7/27/25.
//

import SwiftUI

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(OneSignalFramework)
import OneSignalFramework   // SPM v5+
#elseif canImport(OneSignal)
import OneSignal            // legacy Pods
#endif


import OSLog
import BackgroundTasks

// Create a logger for on-device logging
let appLogger = Logger(subsystem: "com.petl.app", category: "main")

// Background task identifiers
let backgroundTaskIdentifier = "com.petl.background.charging.monitor"
private let refreshId = "com.petl.refresh"

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
                .task {
                    if #available(iOS 16.2, *) {
                        startLiveActivityTokenWatcher()
                    }
                }
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
                .onChange(of: phase) { newPhase in
                    if newPhase == .active {
                        // BatteryTrackingManager manages this already; avoid log spam + toggling.
                        BatteryTrackingManager.shared.emitSnapshotNow("foreground")
                        LiveActivityManager.shared.onAppWillEnterForeground()
                        
                        // Ensure UI pulls fresh data at launch
                        DispatchQueue.main.async {
                            _ = BatteryTrackingManager.shared.historyPointsFromDB(hours: 24) // warms up
                        }
                        
                        if ChargingSessionManager.shared.isChargingActive {
                            PETLOrchestrator.shared.startForegroundLoop()
                        }
                    } else if newPhase == .background {
                        // Stop FG loop and ask iOS for a new BG refresh window
                        PETLOrchestrator.shared.stopForegroundLoop()
                        appDelegate.scheduleRefresh(in: 5)
                        appDelegate.debugDumpPendingBGRequests(context: "on background")
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
        
        // Start session manager and observe lifecycle
        ChargingSessionManager.shared.start()
        NotificationCenter.default.addObserver(forName: .petlSessionStarted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                addToAppLogs("⚡️ Charging session STARTED")
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "charging"]) // idempotent start/update
                if UIApplication.shared.applicationState == .active {
                    PETLOrchestrator.shared.startForegroundLoop()
                }
                self?.scheduleRefresh(in: 5) // seed BG cadence
            }
        }
        NotificationCenter.default.addObserver(forName: .petlSessionEnded, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                addToAppLogs("🛑 Charging session ENDED — stopping loops & Live Activity")
                PETLOrchestrator.shared.stopForegroundLoop()
                self?.cancelRefresh()
                await LiveActivityManager.shared.endAll("session-end")
            }
        }
        
        // Retry loop: handle `.unknown` window on first seconds after launch
        Task { @MainActor in
            await checkChargingAtLaunchWithRetry(timeout: 5.0, interval: 0.5)
        }
        
        // (Optional) Observe future state changes – main handling already exists elsewhere
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let s = ChargeStateStore.shared.currentState
                print("🔌 Battery state changed (launch observer): \(s.rawValue)")
            }
        }
        
        // Initialize OneSignal with comprehensive debugging and error handling
        addToAppLogs("🔧 OneSignal Initialization Started")
        print("🔧 OneSignal Initialization Started")
        appLogger.info("🔧 OneSignal Initialization Started")
        
        addToAppLogs("📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja")
        print("📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja")
        appLogger.info("📱 OneSignal App ID: os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja")
        
        // Initialize OneSignal with error handling
        #if canImport(OneSignalFramework)
        OneSignal.initialize("os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja", withLaunchOptions: launchOptions)
        #elseif canImport(OneSignal)
        OneSignal.initialize("os_v2_app_5pcq6wylknefljglge5vaog4bqpztakc6b3u3zmjovaetx7lszdlq4hgpzjllbtrn3iwdjp75l46ids5faaj7im6iaqbxn5ubxhahja", withLaunchOptions: launchOptions)
        #endif
        addToAppLogs("✅ OneSignal initialized successfully")
        print("✅ OneSignal initialized successfully")
        appLogger.info("✅ OneSignal initialized successfully")
        
        // Setup OneSignal Live Activity bridge (TEMP DISABLED)
        // #if canImport(OneSignalLiveActivities) || canImport(OneSignalFramework) || canImport(OneSignal)
        // OneSignal.LiveActivities.setup(PETLLiveActivityAttributes.self)
        // #endif
        
        // Configure LiveActivityManager (single source of truth)
        LiveActivityManager.shared.configure()
        
        // Request notification permissions with proper error handling
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.requestNotificationPermissions()
        }
        
        // Initialize background task scheduler
        backgroundTaskScheduler = BackgroundTaskScheduler()
        backgroundTaskScheduler?.registerBackgroundTasks()
        
        // Register background refresh tasks (our AppDelegate-managed identifier)
        registerBackgroundTasks()
        
        // Kick off the first BG refresh window; handleRefresh(task:) will reschedule itself.
        scheduleRefresh(in: 5) // use 30 if you want to be gentler
        
        // QA validation
        if FeatureFlags.qaOrchestratorValidation {
            PETLOrchestrator.shared.validateConfiguration()
        }
        
        // Wire orchestrator DB sinks to real ChargeDB APIs
        PETLOrchestrator.shared.dbSinks.insertSoc = { pct, ts in
            _ = ChargeDB.shared.insertSimulatedSoc(percent: pct, at: ts, quality: "present")
            addToAppLogs("🪵 DB.soc ← \(pct)% @\(ts) [present]")
        }
        PETLOrchestrator.shared.dbSinks.insertPower = { watts, ts in
            _ = ChargeDB.shared.insertSimulatedPower(watts: watts, at: ts, trickle: watts < 10.0, quality: "present")
            addToAppLogs(String(format: "🪵 DB.power ← %.1fW @%@ [present]", watts, ts as CVarArg))
        }
        PETLOrchestrator.shared.dbSinks.recomputeAnalytics = {
            addToAppLogs("🧮 DB.analytics.recompute(10m) requested")
        }
        
        return true
    }
    
    @MainActor
    private func checkChargingAtLaunchWithRetry(timeout: TimeInterval, interval: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = ChargeStateStore.shared.currentState
            if state == .charging || state == .full {
                addToAppLogs("🔄 Detected charging at launch – starting Live Activity")
                if Activity<PETLLiveActivityAttributes>.activities.isEmpty {
                    // Start Live Activity directly (no need for ETAPresenter)
                    await LiveActivityManager.shared.startActivity(reason: .chargeBegin)
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

        Task { @MainActor in
            // Always tick once during BG fetch so charts/DB stay current
            await PETLOrchestrator.shared.backgroundRefreshTick(reason: "bg-fetch")

            let isCharging = ChargeStateStore.shared.isCharging
            let hasActivities = !Activity<PETLLiveActivityAttributes>.activities.isEmpty

            if isCharging && !hasActivities {
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "charging"])
                completionHandler(.newData)
            } else if !isCharging && hasActivities {
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "unplugged"])
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
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
    
    // Silent push entrypoint (content-available:1)
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {

        let aps = userInfo["aps"] as? [String: Any]
        let isSilent = (aps?["content-available"] as? Int) == 1
        guard isSilent else {
            completionHandler(.noData)
            return
        }

        let soc = (userInfo["soc"] as? Int) ?? -1
        let watts = (userInfo["watts"] as? Double) ?? 0.0
        appLogger.info("📩 Silent push — soc=\(soc) watts=\(watts)")

        Task {
            // If device is not charging, end activities and log, then stop.
            if !ChargeStateStore.shared.isCharging {
                addToAppLogs("🧯 Silent push while unplugged — ending Live Activity")
                await LiveActivityManager.shared.endAll("server-push-unplugged")
                BatteryTrackingManager.shared.recordBackgroundLog(soc: soc, watts: watts)
                completionHandler(.noData)
                return
            }

            // Update Live Activity from server state
            let newState = PETLLiveActivityAttributes.ContentState(
                soc: max(0, soc),
                watts: max(0.0, watts),
                updatedAt: Date()
            )
            for activity in Activity<PETLLiveActivityAttributes>.activities {
                await activity.update(using: newState)
            }

            // Seed orchestrator so local countdown between pushes stays accurate
            await PETLOrchestrator.shared.seedFromServer(soc: soc, watts: watts)

            BatteryTrackingManager.shared.recordBackgroundLog(soc: soc, watts: watts)
            completionHandler(.newData)
        }
    }
    
    // MARK: - Background Refresh Support
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
            self.handleRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    func scheduleRefresh(in minutes: Int = 5) {
        let req = BGAppRefreshTaskRequest(identifier: refreshId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
        do { 
            try BGTaskScheduler.shared.submit(req)
            Task { @MainActor in addToAppLogs("✅ BG refresh scheduled for \(minutes) minutes") }
            self.debugDumpPendingBGRequests(context: "after scheduleRefresh")
        } catch { 
            Task { @MainActor in addToAppLogs("⚠️ BG submit failed: \(error)") }
        }
    }
    
    func cancelRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)
        Task { @MainActor in addToAppLogs("🛑 BG refresh cancelled") }
    }
    
    func debugDumpPendingBGRequests(context: String) {
        BGTaskScheduler.shared.getPendingTaskRequests { reqs in
            Task { @MainActor in
                addToAppLogs("🧾 Pending BG requests (\(context)): \(reqs.count)")
                for r in reqs {
                    let when = r.earliestBeginDate?.description ?? "nil"
                    addToAppLogs(" • id=\(r.identifier) earliest=\(when)")
                }
            }
        }
    }
    
    func handleRefresh(task: BGAppRefreshTask) {
        scheduleRefresh(in: 5) // schedule the next one

        task.expirationHandler = {
            Task { @MainActor in addToAppLogs("⏳ BG refresh expired") }
        }

        Task { @MainActor in
            addToAppLogs("🔧 BG refresh fired")
            
            await PETLOrchestrator.shared.backgroundRefreshTick(reason: "bg-refresh")
            task.setTaskCompleted(success: true)
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

        Task { @MainActor in
            // Ensure one orchestrator tick per BG wake so DB & charts advance
            await PETLOrchestrator.shared.backgroundRefreshTick(reason: "bg-scheduler")

            let isCharging = ChargeStateStore.shared.isCharging
            let hasActivities = !Activity<PETLLiveActivityAttributes>.activities.isEmpty

            if isCharging && !hasActivities {
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "charging"])
            } else if !isCharging && hasActivities {
                LiveActivityManager.shared.handleRemotePayload(["batteryState": "unplugged"])
            }
            task.setTaskCompleted(success: true)
        }

        // NEW: enforce retention during BG refresh
        ChargeDB.shared.trim(olderThanDays: 30)
    }
    
    func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Background task scheduled for 5 minutes")
            appLogger.info("✅ Background task scheduled for 5 minutes")
        } catch {
            print("❌ Failed to schedule background task: \(error)")
            appLogger.error("❌ Failed to schedule background task: \(error)")
        }
    }
}


#if canImport(ActivityKit)
@available(iOS 16.2, *)
fileprivate func startLiveActivityTokenWatcher() {
    Task.detached(priority: TaskPriority.background) {
        // 1) Pick up activities that already exist at launch
        for activity in Activity<PETLLiveActivityAttributes>.activities {
            Task.detached(priority: TaskPriority.background) {
                for await tokenData in activity.pushTokenUpdates {
                    let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
                    print("🔑 LiveActivity APNs token=\(tokenHex)")
                    #if false // TEMP DISABLED to unblock build
                    OneSignal.LiveActivities.enter(activity.id, withToken: tokenHex) { _ in
                        print("📡 OneSignal enter OK id=\(activity.id.prefix(6))")
                    } withFailure: { error in
                        print("❌ OneSignal enter error: \(error?.localizedDescription ?? "unknown")")
                    }
                    #endif
                }
            }
            Task.detached(priority: TaskPriority.background) {
                for await state in activity.activityStateUpdates {
                    if case .ended = state {
                        #if false // TEMP DISABLED to unblock build
                        OneSignal.LiveActivities.exit(activity.id) { _ in
                            print("📡 OneSignal exit OK id=\(activity.id.prefix(6))")
                        } withFailure: { error in
                            print("❌ OneSignal exit error: \(error?.localizedDescription ?? "unknown")")
                        }
                        #endif
                    }
                }
            }
        }
        // 2) Observe activities created after launch
        for await activity in Activity<PETLLiveActivityAttributes>.activityUpdates {
            Task.detached(priority: TaskPriority.background) {
                for await tokenData in activity.pushTokenUpdates {
                    let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
                    print("🔑 LiveActivity APNs token=\(tokenHex)")
                    #if false // TEMP DISABLED to unblock build
                    OneSignal.LiveActivities.enter(activity.id, withToken: tokenHex) { _ in
                        print("📡 OneSignal enter OK id=\(activity.id.prefix(6))")
                    } withFailure: { error in
                        print("❌ OneSignal enter error: \(error?.localizedDescription ?? "unknown")")
                    }
                    #endif
                }
            }
            Task.detached(priority: TaskPriority.background) {
                for await state in activity.activityStateUpdates {
                    if case .ended = state {
                        #if false // TEMP DISABLED to unblock build
                        OneSignal.LiveActivities.exit(activity.id) { _ in
                            print("📡 OneSignal exit OK id=\(activity.id.prefix(6))")
                        } withFailure: { error in
                            print("❌ OneSignal exit error: \(error?.localizedDescription ?? "unknown")")
                        }
                        #endif
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Charging Session Manager
final class ChargingSessionManager {
    static let shared = ChargingSessionManager()
    enum State: String { case idle, probing, active, trickle, managedCharging, ending, ended }
    private(set) var state: State = .idle
    var hysteresisSeconds: TimeInterval = 8
    private var probeTimer: Timer?
    var isChargingActive: Bool { [.active, .trickle, .managedCharging].contains(state) }

    @MainActor
    func start() {
        if !UIDevice.current.isBatteryMonitoringEnabled { UIDevice.current.isBatteryMonitoringEnabled = true }
        NotificationCenter.default.addObserver(self, selector: #selector(onBatteryStateChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        evaluate(initial: true)
    }

    @MainActor
    @objc private func onBatteryStateChanged() { evaluate(initial: false) }

    @MainActor
    private func evaluate(initial: Bool) {
        let isCharging = ChargeStateStore.shared.isCharging
        switch ChargeStateStore.shared.currentState {
        case .charging, .full:
            if state == .idle || state == .ended {
                transition(to: .probing)
                probeTimer?.invalidate()
                probeTimer = Timer.scheduledTimer(withTimeInterval: hysteresisSeconds, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    if ChargeStateStore.shared.isCharging {
                        self.transition(to: .active)
                        NotificationCenter.default.post(name: .petlSessionStarted, object: nil)
                    } else {
                        self.transition(to: .idle)
                    }
                }
            }
        case .unplugged:
            if isChargingActive || state == .probing {
                transition(to: .ending)
                NotificationCenter.default.post(name: .petlSessionEnded, object: nil)
                transition(to: .ended)
            } else {
                transition(to: .idle)
            }
        default:
            if initial { transition(to: .idle) }
        }
    }

    @MainActor
    private func transition(to new: State) {
        guard state != new else { return }
        addToAppLogs("🔄 Session transition: \(state.rawValue) → \(new.rawValue)")
        state = new
    }
}

// MARK: - PETL Orchestrator
final class PETLOrchestrator {
    static let shared = PETLOrchestrator()
    
    // Configuration
    var foregoundTickSeconds: TimeInterval = 60
    var backgroundAcceptanceSeconds: TimeInterval = 90 // faster BG adoption for server-driven model
    var capacityWhEffective: Double = 12.0 // Default iPhone capacity
    @MainActor
    func seedFromServer(soc: Int, watts: Double) async {
        let clamped = max(0, min(100, soc))
        socSim = Double(clamped)
        hasInitializedFromMeasured = true
        lastTickAt = Date() // reset integration window
        addToAppLogs("🪄 Seeded from server — soc=\(clamped)% watts=\(String(format: "%.1f", watts))")
    }


    // Simulation state & reliability gate
    private var socSim: Double = 0.0
    private var reliabilityCandidate: (value: Int, count: Int, firstSeen: Date)?
    private var hasInitializedFromMeasured = false
    
    // State
    private var foregroundTimer: DispatchSourceTimer?
    private var lastTickAt: Date = .distantPast
    
    // DB sinks (to be wired)
    struct DBSinks {
        var insertSoc: ((Int, Date) -> Void)?
        var insertPower: ((Double, Date) -> Void)?
        var recomputeAnalytics: (() -> Void)?
    }
    var dbSinks = DBSinks()
    
    @MainActor
    func startForegroundLoop() {
        guard foregroundTimer == nil else { return }
        // Seed from current measured level to avoid flashing 0 in UI
        let seed = ChargeStateStore.shared.currentBatteryLevel
        if seed > 0 {
            socSim = Double(seed)
            hasInitializedFromMeasured = true
        }
        foregroundTimer = DispatchSource.makeTimerSource(queue: .main)
        foregroundTimer?.schedule(deadline: .now(), repeating: foregoundTickSeconds)
        foregroundTimer?.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.tick(kind: .fg, reason: "foreground-timer")
            }
        }
        foregroundTimer?.resume()
        addToAppLogs("🔄 FG loop started (\(Int(foregoundTickSeconds))s)")
    }
    
    @MainActor
    func stopForegroundLoop() {
        foregroundTimer?.cancel()
        foregroundTimer = nil
        addToAppLogs("🛑 FG loop stopped")
    }
    
    @MainActor
    func backgroundRefreshTick(reason: String) async {
        if !hasInitializedFromMeasured {
            let seed = ChargeStateStore.shared.currentBatteryLevel
            if seed > 0 {
                socSim = Double(seed)
                hasInitializedFromMeasured = true
            }
        }
        await tick(kind: .bg, reason: reason)
    }
    
    @MainActor
    private func tick(kind: TickKind, reason: String) async {
        let now = Date()
        let defaultDT: TimeInterval = (kind == .fg) ? foregoundTickSeconds : backgroundAcceptanceSeconds
        let dt = max(1.0, lastTickAt == .distantPast ? defaultDT : now.timeIntervalSince(lastTickAt))
        lastTickAt = now

        // Gate: only work while charging
        guard ChargingSessionManager.shared.isChargingActive else {
            addToAppLogs("⛔️ \(kind == .fg ? "FG" : "BG") tick suppressed — not charging")
            return
        }

        // 1) Read current status + measured SoC (0-100)
        let isCharging = ChargeStateStore.shared.isCharging
        var measuredSoc = ChargeStateStore.shared.currentBatteryLevel
        measuredSoc = max(0, min(100, measuredSoc))
        // Initialize from measured once; avoid flashing 0 if iOS hasn't reported yet
        if !hasInitializedFromMeasured {
            if measuredSoc > 0 {
                socSim = Double(measuredSoc)
                hasInitializedFromMeasured = true
            } else {
                addToAppLogs("⏳ Skipping tick publish — waiting for first non-zero measured SOC")
                return
            }
        }

        // 2) Reliability gate — accept 5% steps only after 2 confirmations spaced apart
        var usedMeasured = false
        if acceptIfReliable(newValue: measuredSoc, kind: kind, now: now) {
            // Gentle course-correct (±1%) toward measured
            let error = Double(measuredSoc) - socSim
            let correction = max(-1.0, min(1.0, error))
            socSim += correction
            usedMeasured = true
        }

        let quality = usedMeasured ? "measured" : "simulated"

        // 3) Simulate power and integrate SoC between measurements
        let watts = estimatedWatts(for: Int(round(socSim)), isCharging: isCharging)
        if isCharging {
            let dE_Wh = watts * dt / 3600.0
            let dSoC = dE_Wh / max(0.1, capacityWhEffective) * 100.0
            socSim = min(100.0, socSim + dSoC)
        }
        let trickle = watts < 10.0

        // 4) Compute ETA based on current rate (floor to 1 minute to avoid rounding-to-zero flips)
        let ratePctPerMin = (watts / max(0.1, capacityWhEffective)) * (100.0 / 60.0)
        let remPct = max(0.0, 100.0 - socSim)
        let rawEta = ratePctPerMin > 0 ? remPct / ratePctPerMin : .infinity
        let etaMinutes = max(1.0, rawEta)  // <- floor at 1 minute

        // Only end if unplugged or actually full (not on momentary ETA=0)
        // Only end from FG ticks to avoid BG thrash on momentary stalls
        if kind == .fg, (!isCharging || socSim >= 100.0) {
            addToAppLogs("🏁 Session completed or not charging — ending activity")
            NotificationCenter.default.post(name: .petlSessionEnded, object: nil)
            // Best-effort: also end live activities immediately
            await LiveActivityManager.shared.endAll("session-end")
            return
        }

        // 5) Fan-out to Live Activity and UI
        // Clamp ETA for UI sanity (mirror ETAPresenter clamping)
        let clampedETA = Int(min(max(etaMinutes.rounded(), 1), 240))
        let contentState = PETLLiveActivityAttributes.ContentState(
            soc: Int(round(socSim)),
            watts: watts,
            updatedAt: now,
            isCharging: true,
            timeToFullMinutes: clampedETA,
            expectedFullDate: now.addingTimeInterval(Double(clampedETA) * 60.0),
            chargingRate: String(format: "%.1fW", watts),
            batteryLevel: Int(round(socSim)),
            estimatedWattage: String(format: "%.1fW", watts)
        )

        for activity in Activity<PETLLiveActivityAttributes>.activities {
            await activity.update(using: contentState)
        }
        // Also route a lightweight payload for consumers that look at payload keys (idempotent)
        await LiveActivityManager.shared.handleRemotePayload([
            "simSoc": Int(round(socSim)),
            "simWatts": watts,
            "trickle": trickle,
            "quality": quality,
            "reason": reason
        ])

        NotificationCenter.default.post(name: .petlOrchestratorTick, object: nil, userInfo: [
            "soc": Int(round(socSim)),
            "watts": watts,
            "trickle": trickle,
            "kind": (kind == .fg ? "fg" : "bg"),
            "etaMin": clampedETA,
            "quality": quality,
            "etaSource": "sim",
            "ts": now
        ])

        // Post specific simulated sample notifications for DB consumers
        NotificationCenter.default.post(name: .petlSimulatedSocSample, object: nil, userInfo: [
            "soc": Int(round(socSim)),
            "quality": quality,
            "ts": now
        ])
        
        NotificationCenter.default.post(name: .petlSimulatedPowerSample, object: nil, userInfo: [
            "watts": watts,
            "trickle": trickle,
            "quality": quality,
            "ts": now
        ])

        addToAppLogs("🧮 \(kind == .fg ? "FG" : "BG") tick — soc=\(Int(round(socSim)))% watts=\(String(format: "%.1f", watts))\(trickle ? " (trickle)" : "") ETA=\(Int(etaMinutes.rounded()))m [\(quality)] {src=sim}")
        addToAppLogs("📤 LiveActivity update requested — soc=\(Int(round(socSim))) watts=\(String(format: "%.1f", watts)) kind=\(kind == .fg ? "fg" : "bg")")

        // 6) Optional DB sinks
        if hasInitializedFromMeasured {
            dbSinks.insertSoc?(Int(round(socSim)), now)
            dbSinks.insertPower?(watts, now)
            dbSinks.recomputeAnalytics?()
        }
    }

    // Accept a new 5% boundary only after 2 confirmations spaced in time
    private func acceptIfReliable(newValue: Int, kind: TickKind, now: Date) -> Bool {
        if kind == .bg {
            reliabilityCandidate = nil
            return true
        }
        // snap to nearest 5% boundary to avoid 1-2% noise
        let snapped = max(0, min(100, (newValue / 5) * 5))
        if let c = reliabilityCandidate, c.value == snapped {
            let count = c.count + 1
            let minGap = (kind == .fg) ? max(90.0, foregoundTickSeconds * 1.5) : backgroundAcceptanceSeconds
            if now.timeIntervalSince(c.firstSeen) >= minGap && count >= 2 {
                reliabilityCandidate = nil
                return true
            } else {
                reliabilityCandidate = (snapped, count, c.firstSeen)
                return false
            }
        } else {
            reliabilityCandidate = (snapped, 1, now)
            return false
        }
    }
    
    // Thermal-aware wattage estimate with SoC bands; returns 0 if not charging
    private func estimatedWatts(for soc: Int, isCharging: Bool) -> Double {
        guard isCharging else { return 0.0 }
        let base: Double = 10.0
        let band: Double
        switch soc {
        case ..<20:  band = 1.0
        case 20..<50: band = 1.0
        case 50..<80: band = 0.75
        default:      band = 0.5
        }
        let thermal: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = 1.0
        case .fair:    thermal = 0.9
        case .serious: thermal = 0.75
        case .critical:thermal = 0.6
        @unknown default: thermal = 0.9
        }
        return max(5.0, base * band * thermal)
    }
    
    @MainActor
    func validateConfiguration() {
        addToAppLogs("🧪 QA: Orchestrator cfg — FG=\(Int(foregoundTickSeconds))s BGWindow=\(Int(backgroundAcceptanceSeconds))s capWh=\(capacityWhEffective) useSim=true")
        addToAppLogs("🧪 QA: DB sinks — soc=\(dbSinks.insertSoc != nil) power=\(dbSinks.insertPower != nil) analytics=\(dbSinks.recomputeAnalytics != nil)")
        addToAppLogs("🧪 QA: Battery monitoring=\(UIDevice.current.isBatteryMonitoringEnabled)")
    }
    
    enum TickKind { case fg, bg }
}

extension Notification.Name {
    static let petlSessionStarted = Notification.Name("petl.session.started")
    static let petlSessionEnded   = Notification.Name("petl.session.ended")
    static let petlOrchestratorTick = Notification.Name("petl.orchestrator.tick")
    static let petlSimulatedSocSample = Notification.Name("petl.simulated.soc.sample")
    static let petlSimulatedPowerSample = Notification.Name("petl.simulated.power.sample")
}
