//
//  ContentView.swift
//  PETL
//
//  Created by rakesh guduru on 7/27/25.
//

import SwiftUI
import ActivityKit
import OneSignalFramework

import os.log
import Darwin
import Charts
import Combine

// MARK: - Notification Names
extension Notification.Name {
    static let powerDBDidChange = Notification.Name("powerDBDidChange")
}

// Create a logger for on-device logging
let contentLogger = Logger(subsystem: "com.petl.app", category: "content")

// Global log messages array for in-app display
var globalLogMessages: [String] = []

// Centralized logging function for in-app display (rate-limited version in BatteryTrackingManager)
@MainActor
func addToAppLogs(_ message: String) {
    BatteryTrackingManager.shared.addToAppLogs(message)
}

// BatteryTrackingManager and BatteryDataPoint are defined in BatteryTrackingManager.swift

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// ===== BEGIN STABILITY-LOCKED: Single subscription (do not edit) =====
// MARK: - Charts View Model for single subscriber + change-aware reload
@MainActor
final class ChartsVM: ObservableObject {
    @Published var power12h: [PowerSample] = []
    private var dbC: AnyCancellable?
    private var chgC: AnyCancellable?
    private var lastHash: Int = 0       // simple change detection

    init(trackingManager: BatteryTrackingManager) {
        dbC = NotificationCenter.default.publisher(for: .powerDBDidChange)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload(trackingManager) }

        chgC = trackingManager.$isCharging.removeDuplicates()
            .sink { [weak self] _ in self?.reload(trackingManager) }

        reload(trackingManager)
    }
// ===== END STABILITY-LOCKED =====

    func reload(_ tm: BatteryTrackingManager) {
        Task {
            let s = await tm.powerSamplesFromDB(hours: 12)
            // compute a cheap hash to avoid UI updates when identical
            let h = s.count ^ (Int(s.last?.time.timeIntervalSince1970 ?? 0))
            guard h != self.lastHash else { return }
            self.lastHash = h
            self.power12h = s
            tm.addToAppLogs("🔄 PowerChart reload (12h) — \(s.count) samples")
        }
    }
}

struct ContentView: View {
    // Revert from @EnvironmentObject to @ObservedObject on the singleton
    @ObservedObject private var tracker = BatteryTrackingManager.shared
    
    // Live UI frame buffer for real-time chart updates
    @State private var recentSocUI: [ChargeRow] = []
    @StateObject private var analytics = ChargingAnalyticsStore()
    @ObservedObject private var chargeStateStore = ChargeStateStore.shared
    @StateObject private var eta = ETAPresenter()
    @State private var snapshot = BatterySnapshot(level: 0, isCharging: false, timestamp: .now)
    @State private var isActivityRunning: Bool = false
    @State private var currentActivityId: String = ""
    @State private var oneSignalStatus: String = "Initializing..."
    @State private var deviceToken: String = "Not available"
    @State private var logMessages: [String] = []
    @State private var showLogs: Bool = false
    @State private var lastChargingState: Bool = false // Track previous charging state
    @State private var selectedTab = 0
    @State private var activityEmoji: String = ""
    @State private var activityMessage: String = ""
    #if DEBUG
    @State private var lastAxisKey: String = ""
    #endif
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var phase
    
    // Battery stats for the new design
    @State private var estimatedTimeToFull: String = "..."
    @State private var deviceModel: String = "..."
    @State private var batteryCapacity: String = "..."
    @State private var batteryHealth: String = "..."
    @State private var chargingRate: String = "..."
    @State private var estimatedWattage: String = "..."
    
    // Device profile service for eager loading
    @StateObject private var deviceSvc = DeviceProfileService.shared
    

    
    // Ring state variables
    @State private var ringMinutes: Int? = nil
    @State private var ringWatts: Double = 0.0
    @State private var showPause: Bool = false
    

    

    
    @State private var cancellables = Set<AnyCancellable>()
    
    private static var didLogInit = false

    init() {
        // Only log once per app launch to avoid spam.
        if !Self.didLogInit {
            addToAppLogs("🚀 ContentView Initialized (pure UI)")
            addToAppLogs("📱 App Version: 1.0")
            addToAppLogs("🔧 Debug Mode: Enabled")

                    // Battery tracking is now handled centrally by BatteryTrackingManager
        addToAppLogs("📊 Battery tracking initialized (centralized)")

            Self.didLogInit = true
        }

        // View-local state still needs to be set every time:
        // Use tracker's published properties directly - no local copies
        lastChargingState = tracker.isCharging
        
        // Initialize charging rate tracking
        previousBatteryLevel = tracker.level
        lastBatteryCheckTime = Date()
        currentChargingRate = 0.0
        
        // Initialize UI state (no manager work here)
        chargingStartTime = nil
        isInWarmUpPeriod = false
        warmUpEndTime = nil
    }
    

    

    
    var body: some View {
        ZStack {
            // Set the entire app background to gray - covering ALL areas
            Color(.systemGray6)
                .ignoresSafeArea(.all, edges: .all)
                .background(Color(.systemGray6))
            
            VStack(spacing: 0) {
                // Content area
                TabView(selection: $selectedTab) {
                    HomeNavigationContent(
                        eta: eta,
                        analytics: analytics,
                        deviceModel: deviceModel,
                        batteryCapacity: batteryCapacity,
                        batteryHealth: batteryHealth,
                        isActivityRunning: isActivityRunning,
                        currentActivityId: currentActivityId,
                        oneSignalStatus: oneSignalStatus,
                        deviceToken: deviceToken,
                        logMessages: $logMessages,
                        showLogs: $showLogs,
                        lastChargingState: lastChargingState,
                        recentSocUI: recentSocUI
                    )
                    .tag(0)
                    
                    HistoryNavigationContent()
                        .tag(1)
                    
                    InfoNavigationContent(
                        isActivityRunning: isActivityRunning,
                        oneSignalStatus: oneSignalStatus,
                        deviceToken: deviceToken,
                        logMessages: $logMessages,
                        showLogs: $showLogs,
                        onStartActivity: startChargingActivity,
                        onStopActivity: endChargingActivity,
                        onUpdateActivity: publishLiveActivityAnalytics
                    )
                    .tag(2)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .onAppear {
                    // Ensure centralized battery monitoring is started
                    BatteryTrackingManager.shared.startMonitoring()
                }
                
                // Debug info logged to console instead of UI
                
                // Custom tab bar
                HStack(spacing: 0) {
                    TabButton(
                        title: "Home",
                        icon: "house",
                        isSelected: selectedTab == 0
                    ) {
                        selectedTab = 0
                    }
                    
                    TabButton(
                        title: "History",
                        icon: "clock",
                        isSelected: selectedTab == 1
                    ) {
                        selectedTab = 1
                    }
                    
                    TabButton(
                        title: "Info",
                        icon: "info.circle",
                        isSelected: selectedTab == 2
                    ) {
                        selectedTab = 2
                    }
                }
                .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                .frame(height: 83)
            }
        }
        .background(Color(.systemGray6))
        .ignoresSafeArea(.all, edges: .all)
        // Removed aggressive polling timers as per blueprint
        // LiveActivityManager handles all Live Activity management
        .onReceive(tracker.publisher) { snap in
            snapshot = snap
            updateUI(with: snap)
        }
        .onReceive(deviceSvc.$profile.compactMap { $0 }) { _ in
            updateBatteryStats()    // NEW: pick up model + capacity as soon as it publishes
        }
        .onReceive(NotificationCenter.default.publisher(for: .petlOrchestratorUiFrame)) { note in
            guard let info = note.userInfo,
                  let soc = info["soc"] as? Int,
                  let ts = info["ts"] as? Date else { return }

            // Keep last 30 minutes, dedupe by 10s buckets to avoid overdraw
            let now = Date()
            let cutoff = now.addingTimeInterval(-30 * 60)

            var buf = recentSocUI.filter { $0.ts >= cutoff.timeIntervalSince1970 }
            let bucket = Date(timeIntervalSince1970: floor(ts.timeIntervalSince1970 / 10.0) * 10.0)
            if !buf.contains(where: { abs($0.ts - bucket.timeIntervalSince1970) < 1 }) {
                buf.append(ChargeRow(ts: bucket.timeIntervalSince1970, sessionId: "", isCharging: true, soc: max(0, soc), watts: nil, etaMinutes: nil, event: .sample, src: "present"))
            }
            buf.sort { $0.ts < $1.ts }
            recentSocUI = buf
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .active {
                // Defensive battery monitoring - ensure it's enabled when app becomes active
                UIDevice.current.isBatteryMonitoringEnabled = true
                
                // Log warning if battery monitoring is disabled after 1 second
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if !UIDevice.current.isBatteryMonitoringEnabled {
                        print("⚠️ WARNING: Battery monitoring disabled after app became active")
                        contentLogger.warning("⚠️ WARNING: Battery monitoring disabled after app became active")
                    }
                }
            }
        }
        .onAppear {
            // Reset internal state first
            isActivityRunning = false
            currentActivityId = ""
            lastChargingState = false
            
            // Reset 5-minute warm-up period tracking
            chargingStartTime = nil
            isInWarmUpPeriod = false
            warmUpEndTime = nil
            
            // Phase 3.1: Subscribe to single source of truth

            
            // Then check actual status
            checkActivityStatus()
            loadOneSignalStatus()
            
            // Ensure device profile is loaded
            Task { await DeviceProfileService.shared.ensureLoaded() }
            updateBatteryStats()        // NEW: ensure first render is populated
            
            // Add initialization logs
            logMessages.append("🚀 PETL Auto App Started")
            logMessages.append("📱 ContentView Initialized")
            logMessages.append("🔌 Auto charging detection enabled")
            logMessages.append("🔄 State reset completed")

        }
    }
    
    private func updateBatteryStats() {
        if let profile = deviceSvc.profile {
            deviceModel = profile.name
            batteryCapacity = "\(profile.capacitymAh)mAh"
        } else {
            deviceModel = UIDevice.current.model
            batteryCapacity = "—"
        }

        // Health estimate (kept as-is)
        batteryHealth = getBatteryHealth()

        if tracker.isCharging {
            chargingRate = getChargingRate()
            estimatedWattage = getEstimatedWattage()
        } else {
            chargingRate = "—"
            estimatedWattage = "—"
        }
    }
    

    
    private func getBatteryHealth() -> String {
        // iOS doesn't provide direct battery health via public APIs
        // This is an estimation based on available data and usage patterns
        
        let currentLevel = Float(chargeStateStore.currentBatteryLevel) / 100.0
        let isChargingState = chargeStateStore.isCharging
        
        // More sophisticated health estimation
        if isChargingState {
            // When charging, estimate based on charging speed and level
            if currentLevel < 0.2 {
                // Fast charging at low levels usually indicates good battery
                return "Excellent (95%+)"
            } else if currentLevel < 0.8 {
                return "Good (85-95%)"
            } else {
                // Trickle charging at high levels
                return "Good (90%+)"
            }
        } else {
            // When not charging, estimate based on current level and typical behavior
            if currentLevel > 0.8 {
                return "Good (90%+)"
            } else if currentLevel > 0.6 {
                return "Fair (80-90%)"
            } else if currentLevel > 0.4 {
                return "Fair (70-80%)"
            } else {
                return "Poor (<70%)"
            }
        }
    }
    
    // MARK: - Advanced Charging Analytics Methods
    
    // Real-time charging rate calculation variables
    @State private var previousBatteryLevel: Float = 0.0
    @State private var lastBatteryCheckTime: Date = Date()
    @State private var currentChargingRate: Double = 0.0 // %/min
    @State private var chargingStartTime: Date? = nil // Track when charging started for 15s elimination
    
    // 5-minute warm-up period tracking for reliable charging rate calculations
    @State private var isInWarmUpPeriod: Bool = false
    @State private var warmUpEndTime: Date? = nil
    
    private func calculateChargingRate() -> Double {
        guard chargeStateStore.isCharging else { return 0.0 }
        
        // During 5-minute warm-up period, return 0.0 to force fallback values
        if isInWarmUpPeriod {
            let remainingWarmUpTime = warmUpEndTime?.timeIntervalSince(Date()) ?? 0
            print("🔋 In warm-up period - \(Int(remainingWarmUpTime))s remaining, using fallback values")
            contentLogger.info("🔋 In warm-up period - \(Int(remainingWarmUpTime))s remaining, using fallback values")
            return 0.0 // Force fallback values during warm-up
        }
        
        // Eliminate first 15 seconds of data to avoid anomalies after long background periods
        if let startTime = chargingStartTime {
            let timeSinceChargingStart = Date().timeIntervalSince(startTime)
            if timeSinceChargingStart < 15.0 {
                print("🔋 Eliminating first 15s of data - \(Int(15.0 - timeSinceChargingStart))s remaining")
                contentLogger.info("🔋 Eliminating first 15s of data - \(Int(15.0 - timeSinceChargingStart))s remaining")
                return currentChargingRate
            }
        }
        
        let currentTime = Date()
        let timeDifference = currentTime.timeIntervalSince(lastBatteryCheckTime)
        
        // iOS updates battery % in 5% increments, so we need at least 60 seconds for meaningful data
        guard timeDifference >= 60.0 else { return currentChargingRate }
        
        let batteryLevelDifference = Double(Float(chargeStateStore.currentBatteryLevel) / 100.0 - previousBatteryLevel)
        
        // Calculate charging rate in %/min
        let chargingRatePerMinute = (batteryLevelDifference * 100.0) / (timeDifference / 60.0)
        
        // Update tracking variables
        previousBatteryLevel = Float(chargeStateStore.currentBatteryLevel) / 100.0
        lastBatteryCheckTime = currentTime
        
        // Smooth the charging rate (average with previous value)
        let smoothedRate = (currentChargingRate + chargingRatePerMinute) / 2.0
        
        // Cap the maximum realistic charging rate to 5.0%/min (very fast charging)
        let cappedRate = min(smoothedRate, 5.0)
        currentChargingRate = max(0.0, cappedRate) // Ensure non-negative
        
        print("🔋 Charging rate calculation: \(batteryLevelDifference * 100)% in \(timeDifference)s = \(cappedRate)%/min (capped)")
        contentLogger.info("🔋 Charging rate calculation: \(batteryLevelDifference * 100)% in \(timeDifference)s = \(cappedRate)%/min (capped)")
        
        return cappedRate
    }
    
    private func getChargingRate() -> String {
        guard tracker.isCharging else { return "Not charging" }
        
        let rate = calculateChargingRate()
        
        // During 5-minute warm-up period, use fallback values (warm-up period IS fallback)
        if isInWarmUpPeriod {
            print("🔋 In warm-up period - using PETL Standard Charging fallback")
            contentLogger.info("🔋 In warm-up period - using PETL Standard Charging fallback")
            return "Standard Charging"
        }
        
        // Use Standard Charging as fallback when no real data available
        if rate <= 0.0 {
            print("🔋 No charging rate data available, using PETL Standard Charging fallback")
            return "Standard Charging"
        }
        
        // Categorize charging rate based on realistic ranges
        if rate >= 3.0 {
            return "Fast Charging"
        } else if rate >= 1.5 {
            return "Standard Charging"
        } else if rate > 0.0 {
            return "Trickle Charging"
        } else {
            return "Standard Charging" // PETL fallback
        }
    }
    
    private func getChargingRatePercentage() -> String {
        guard tracker.isCharging else { return "0%/min" }
        
        let rate = calculateChargingRate()
        return String(format: "%.1f%%/min", rate)
    }
    
    private func getEstimatedWattage() -> String {
        guard tracker.isCharging else { return "Not charging" }
        
        let rate = calculateChargingRate()
        
        // During 5-minute warm-up period, use fallback values (warm-up period IS fallback)
        if isInWarmUpPeriod {
            print("🔋 In warm-up period - using PETL 10W fallback")
            contentLogger.info("🔋 In warm-up period - using PETL 10W fallback")
            return "10W"
        }
        
        // Use 10W fallback when no real data available
        if rate <= 0.0 {
            print("🔋 No charging rate data available, using PETL 10W fallback")
            return "10W"
        }
        
        // When real charging rate data is available, calculate actual wattage
        let capacityString = deviceSvc.profile?.capacitymAh.description ?? "—"
        let capacity = extractCapacityFromString(capacityString) // mAh
        
        // Calculate estimated wattage based on actual charging rate
        // Formula: Wattage = (Charging Rate %/min) * (Battery Capacity mAh) * (Voltage 3.7V) / (60 min * 100%)
        let voltage = 3.7 // Standard lithium-ion battery voltage
        let estimatedWattage = (rate * Double(capacity) * voltage) / (60.0 * 100.0)
        
        // Ensure minimum reasonable wattage (PETL fallback)
        let finalWattage = max(estimatedWattage, 10.0)
        
        print("🔋 Wattage calculation: \(rate)%/min × \(capacity)mAh × \(voltage)V ÷ 6000 = \(finalWattage)W")
        contentLogger.info("🔋 Wattage calculation: \(rate)%/min × \(capacity)mAh × \(voltage)V ÷ 6000 = \(finalWattage)W")
        
        return String(format: "%.0fW", finalWattage)
    }
    
    private func extractCapacityFromString(_ capacityString: String) -> Int {
        // Extract numeric capacity from strings like "3,561 mAh"
        let numbers = capacityString.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        return Int(numbers) ?? 3000 // Default fallback
    }
    

    
    private func calculateTimeToFull() -> String {
        guard tracker.isCharging else { return "Not charging" }
        
        // Handle 100% battery case - show "Full" instead of "0 min"
        if tracker.level >= 0.99 {
            print("🔋 Battery at 100% - showing 'Full' instead of '0 min'")
            contentLogger.info("🔋 Battery at 100% - showing 'Full' instead of '0 min'")
            return "Full"
        }
        
        let remainingPercentage = 1.0 - tracker.level
        let rate = calculateChargingRate()
        
        // During 5-minute warm-up period, use 10W fallback calculation
        if isInWarmUpPeriod {
            print("🔋 In warm-up period - using 10W fallback time calculation")
            contentLogger.info("🔋 In warm-up period - using 10W fallback time calculation")
            
            // Use 10W fallback rate for more accurate warm-up calculation
            let fallbackRate = 1.5 // 10W equivalent charging rate in %/min
            let estimatedMinutes = Int((Double(remainingPercentage) * 100.0) / fallbackRate)
            
            // Apply battery level adjustments
            let levelAdjustment = getBatteryLevelAdjustment(for: tracker.level)
            let adjustedMinutes = Double(estimatedMinutes) * levelAdjustment
            let finalMinutes = Int(adjustedMinutes)
            
            if finalMinutes <= 0 {
                return "0"
            } else {
                return "\(finalMinutes)"
            }
        }
        
        // If no charging rate data available, use PETL fallback calculation
        if rate <= 0.0 {
            print("🔋 No charging rate data available, using PETL fallback time calculation")
            // Use standard charging rate for fallback calculation
            let fallbackRate = 1.0 // Standard charging rate in %/min
            let estimatedMinutes = Int((Double(remainingPercentage) * 100.0) / fallbackRate)
            
            // Apply battery level adjustments
            let levelAdjustment = getBatteryLevelAdjustment(for: tracker.level)
            let adjustedMinutes = Double(estimatedMinutes) * levelAdjustment
            let finalMinutes = Int(adjustedMinutes)
            
            if finalMinutes <= 0 {
                return "0"
            } else {
                return "\(finalMinutes)"
            }
        }
        
        // Time to full = remaining percentage / charging rate per minute
        let estimatedMinutes = Int((Double(remainingPercentage) * 100.0) / rate)
        
        // Apply battery level adjustments (charging slows down at higher levels)
        let levelAdjustment = getBatteryLevelAdjustment(for: tracker.level)
        let adjustedMinutes = Double(estimatedMinutes) * levelAdjustment
        
        let finalMinutes = Int(adjustedMinutes)
        
        print("🔋 Time calculation: \(remainingPercentage * 100)% remaining ÷ \(rate)%/min = \(finalMinutes) minutes")
        contentLogger.info("🔋 Time calculation: \(remainingPercentage * 100)% remaining ÷ \(rate)%/min = \(finalMinutes) minutes")
        
        // Handle very low remaining percentage that could cause rounding to 0
        if remainingPercentage < 0.01 {
            print("🔋 Very low remaining percentage (\(remainingPercentage * 100)%) - showing 'Almost Full'")
            contentLogger.info("🔋 Very low remaining percentage (\(remainingPercentage * 100)%) - showing 'Almost Full'")
            return "Almost Full"
        }
        
        if finalMinutes <= 0 {
            return "0"
        } else {
            return "\(finalMinutes)"
        }
    }
    
    private func getDeviceChargingAdjustment(for deviceIdentifier: String) -> Double {
        // Device-specific charging efficiency adjustments
        let deviceAdjustments: [String: Double] = [
            // iPhone 16 series - optimized charging (including alternative identifiers)
            "iPhone17,1": 0.85, // iPhone 16 Pro (alternative identifier)
            "iPhone17,2": 0.85, // iPhone 16 Pro Max (alternative identifier)
            "iPhone16,3": 0.9, // iPhone 16
            "iPhone16,4": 0.9, // iPhone 16 Plus
            "iPhone16,5": 0.85, // iPhone 16 Pro (more efficient)
            "iPhone16,6": 0.85, // iPhone 16 Pro Max (more efficient)
            
            // iPhone 15 series
            "iPhone15,2": 0.9, // iPhone 15 Pro
            "iPhone15,3": 0.9, // iPhone 15 Pro Max
            "iPhone15,4": 0.95, // iPhone 15
            "iPhone15,5": 0.95, // iPhone 15 Plus
            
            // iPhone 14 series
            "iPhone14,2": 0.95, // iPhone 14 Pro
            "iPhone14,3": 0.95, // iPhone 14 Pro Max
            "iPhone14,6": 1.0,  // iPhone 14
            "iPhone14,7": 1.0,  // iPhone 14 Plus
            
            // iPhone 13 series
            "iPhone14,4": 1.05, // iPhone 13 mini
            "iPhone14,5": 1.0,  // iPhone 13
        ]
        
        return deviceAdjustments[deviceIdentifier] ?? 1.0
    }
    
    private func getBatteryLevelAdjustment(for batteryLevel: Float) -> Double {
        // Charging slows down as battery level increases
        if batteryLevel < 0.2 {
            return 1.0 // Full speed at low levels
        } else if batteryLevel < 0.5 {
            return 1.1 // Slightly slower
        } else if batteryLevel < 0.8 {
            return 1.3 // Slower charging
        } else if batteryLevel < 0.9 {
            return 1.8 // Much slower
        } else {
            return 2.5 // Very slow trickle charging
        }
    }
    
    private func startChargingActivity() {
        // Delegate to LiveActivityManager
        LiveActivityManager.shared.handleRemotePayload(["batteryState": "charging"])
        
        // Update UI state
        DispatchQueue.main.async {
            self.isActivityRunning = true
            self.logMessages.append("🔌 Live Activity start requested")
        }
    }
    
    private func endChargingActivity() {
        // Delegate to LiveActivityManager
        LiveActivityManager.shared.handleRemotePayload(["batteryState": "unplugged"])
        
        // Update UI state
        DispatchQueue.main.async {
            self.isActivityRunning = false
            self.currentActivityId = ""
            self.logMessages.append("🔌 Live Activity end requested")
        }
    }
    
    private func checkActivityStatus() {
        // Check if there's an active Live Activity
        let activities = Activity<PETLLiveActivityAttributes>.activities
        print("🔍 Checking Live Activity status...")
        print("📊 Found \(activities.count) active Live Activities")
        
        if let activity = activities.first {
            currentActivityId = activity.id
            isActivityRunning = true
            
            // Update UI with current activity state
            // Note: Activity state is now managed through the new data structure
            
            print("✅ Live Activity is running: \(activity.id)")
            print("📱 Activity content: \(activityEmoji) - \(activityMessage)")
        } else {
            // No activities found, ensure UI reflects this
            isActivityRunning = false
            currentActivityId = ""
            print("❌ No Live Activity is currently running")
        }
    }
    
    private func loadOneSignalStatus() {
        // Get OneSignal device token using the framework
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
    
    private func updateUI(with snap: BatterySnapshot) {
        let newChargingState = snap.isCharging
        let newBatteryLevel = snap.level
        
        print("🔋 UI Update from Snapshot - Level: \(Int(newBatteryLevel * 100))%, Charging: \(newChargingState)")
        contentLogger.info("🔋 UI Update from Snapshot - Level: \(Int(newBatteryLevel * 100))%, Charging: \(newChargingState)")
        
        // Always check current activity status first
        checkActivityStatus()
        
        // Track charging start/end for 5-minute warm-up period
        if newChargingState != lastChargingState {
            print("🔄 Charging state changed: \(lastChargingState) → \(newChargingState)")
            contentLogger.info("🔄 Charging state changed: \(lastChargingState) → \(newChargingState)")
            
            if newChargingState {
                // Started charging - track start time and warm-up period
                chargingStartTime = Date()
                warmUpEndTime = chargingStartTime?.addingTimeInterval(300) // 5 minutes = 300 seconds
                isInWarmUpPeriod = true
                
                // Reset charging rate tracking variables
                previousBatteryLevel = newBatteryLevel
                lastBatteryCheckTime = Date()
                currentChargingRate = 0.0
                
                print("🔋 Charging started - 5-minute warm-up period begins")
                contentLogger.info("🔋 Charging started - 5-minute warm-up period begins")
                
                // Start Live Activity
                startChargingActivity()
                let stateMessage = "🔌 Started charging - Live Activity started (5min warm-up)"
                logMessages.append(stateMessage)
            } else {
                // Stopped charging - reset warm-up tracking
                chargingStartTime = nil
                warmUpEndTime = nil
                isInWarmUpPeriod = false
                
                print("🔋 Charging stopped - warm-up period reset")
                contentLogger.info("🔋 Charging stopped - warm-up period reset")
                
                // End Live Activity
                endChargingActivity()
                let stateMessage = "🔌 Stopped charging - Live Activity ended"
                logMessages.append(stateMessage)
            }
            lastChargingState = newChargingState
        } else if newChargingState && !isActivityRunning {
            // We're charging but no activity is running (app restart scenario)
            print("🔌 Charging detected but no activity running - starting now")
            contentLogger.info("🔌 Charging detected but no activity running - starting now")
            logMessages.append("🔌 Charging detected but no activity running - starting now")
            startChargingActivity()
        }
        
        // Check if warm-up period has ended
        if isInWarmUpPeriod, let warmUpEnd = warmUpEndTime, Date() >= warmUpEnd {
            isInWarmUpPeriod = false
            print("🔋 5-minute warm-up period ended - real charging rate calculations enabled")
            contentLogger.info("🔋 5-minute warm-up period ended - real charging rate calculations enabled")
        }
        
        // Use tracker directly - no local copies
        // isCharging and batteryLevel are now read from tracker.isCharging and tracker.level
        
        // Update battery stats for the new design
        updateBatteryStats()
        
        // Add data point to tracking manager
        BatteryTrackingManager.shared.recordBatteryData()
        
        // Update Live Activity whenever it's running (charging or not),
        // because this is now the only place that owns analytics.
        if isActivityRunning {
            publishLiveActivityAnalytics()
            
            // During warm-up period, update more frequently to ensure proper values
            if isInWarmUpPeriod {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.isActivityRunning && self.tracker.isCharging {
                        self.publishLiveActivityAnalytics()
                    }
                }
            }
        }
    }
    
    fileprivate func publishLiveActivityAnalytics() {
        // Delegate to LiveActivityManager with current battery data
        // DEBUG guardrail for legacy ETA usage
        #if DEBUG
        if estimatedTimeToFull != "..." {
            addToAppLogs("🚫 SST VIOLATION — legacy ETA path read \(estimatedTimeToFull). UI must use displayedPublisher.")
            assertionFailure("SST: UI must use displayedPublisher for ETA")
        }
        #endif
        
        let contentState: [String: Any] = [
            "batteryLevel": Double(tracker.level),
            "isCharging": tracker.isCharging,
            "chargingRate": analytics.characteristicLabel,
            "estimatedWattage": analytics.characteristicWatts,
            "timeToFull": eta.unifiedEtaMinutes.map { "\($0)" } ?? "—",
            "deviceModel": deviceModel,
            "batteryHealth": batteryHealth,
            "isInWarmUpPeriod": isInWarmUpPeriod
        ]
        
        LiveActivityManager.shared.handleRemotePayload([
            "content-state": contentState
        ])
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? "\(icon).fill" : icon)
                    .font(.system(size: 17))
                    .foregroundColor(isSelected ? .blue : .secondary)
                
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .blue : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 83)
        .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
    }
}

// MARK: - SwiftUI Content Views (Updated for UIKit Integration)
struct HomeNavigationContent: View {
    @ObservedObject private var tracker = BatteryTrackingManager.shared
    @ObservedObject private var chargeStateStore = ChargeStateStore.shared
    @ObservedObject var eta: ETAPresenter
    @ObservedObject var analytics: ChargingAnalyticsStore
    let deviceModel: String
    let batteryCapacity: String
    let batteryHealth: String
    let isActivityRunning: Bool
    let currentActivityId: String
    let oneSignalStatus: String
    let deviceToken: String
    @Binding var logMessages: [String]
    @Binding var showLogs: Bool
    let lastChargingState: Bool
    let recentSocUI: [ChargeRow] // Live UI frame buffer
    
    @Environment(\.colorScheme) var colorScheme
    #if DEBUG
    @State private var lastAxisKey: String = ""
    #endif
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // Top spacing - reduced by 25px to move content up
                    Spacer(minLength: 35)
                    
                    // PETL Logo - always show to prevent layout shift
                    if tracker.isCharging {
                        // Visible PETL logo when connected
                        Image("PETLLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 110)
                            .foregroundColor(Color(.secondaryLabel))
                    } else {
                        // Invisible PETL logo with exact same dimensions to prevent layout shift
                        Image("PETLLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 110)
                            .opacity(0) // Make it completely invisible
                    }
                    
                    // Spacing after logo - always consistent
                    Spacer(minLength: 24)
                    
                    // Battery Ring Section - fixed size for iPhone 16 Pro
                    ZStack {
                        // Background ring
                        Circle()
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12), lineWidth: 20)
                            .frame(width: 175, height: 175)
                            .rotationEffect(.degrees(-90))
                        
                        // Foreground ring (battery level) - follows PETL spec with smooth animation
                        if chargeStateStore.isCharging {
                            Circle()
                                .trim(from: 0, to: CGFloat(Float(chargeStateStore.currentBatteryLevel) / 100.0))
                                .stroke(Color(red: 0.29, green: 0.87, blue: 0.5), lineWidth: 20) // Green when charging
                                .frame(width: 175, height: 175)
                                .rotationEffect(.degrees(-90))
                                .animation(.none, value: chargeStateStore.currentBatteryLevel) // Remove animation to prevent CADisplay errors
                                .onAppear {
                                    // No animation initialization to avoid CADisplay link notifications
                                }
                        } else {
                            // When not charging, hide the green ring (0% fill) as per spec
                            Circle()
                                .trim(from: 0, to: 0) // 0% fill = hidden
                                .stroke(Color(red: 0.29, green: 0.87, blue: 0.5), lineWidth: 20)
                                .frame(width: 175, height: 175)
                                .rotationEffect(.degrees(-90))
                        }
                        
                        // Center content - fixed positioning
                        VStack(spacing: 0) {
                            // Top line text - follows PETL spec - same height for both states
                            if chargeStateStore.isCharging {
                                Text("iPhone 100% in")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color(.label))
                                    .tracking(0.2)
                                    .frame(height: 10)
                            } else {
                                Text("Connect")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color(.label))
                                    .tracking(0.2)
                                    .frame(height: 10)
                            }
                            
                            // Spacer to push time estimate to center
                            Spacer(minLength: 0)
                                .frame(height: 2)
                            
                            // Middle line content - follows PETL spec
                            if chargeStateStore.isCharging {
                                // Use unified ETA from ETAPresenter
                                if let minutes = eta.unifiedEtaMinutes {
                                    if minutes == 0 {
                                        Text("Full")
                                            .font(.system(size: 57, weight: .regular))
                                            .foregroundColor(Color(.label))
                                            .tracking(-0.25)
                                            .frame(height: 64)
                                    } else {
                                        // Show number with baseline-aligned "min"
                                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                                            Text("\(minutes)")
                                                .font(.system(size: 57, weight: .regular))
                                                .foregroundColor(Color(.label))
                                                .tracking(-0.25)
                                                .monospacedDigit()
                                            
                                            Text("min")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(Color(.secondaryLabel))
                                        }
                                        .frame(height: 64)
                                    }
                                } else {
                                    Text("—")
                                        .font(.system(size: 57, weight: .regular))
                                        .foregroundColor(Color(.label))
                                        .tracking(-0.25)
                                        .frame(height: 64)
                                }
                            } else {
                                // Show PETL logo in the center when not connected - moved up 10px for perfect centering
                                Image("PETLLogo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 80, height: 64)
                                    .foregroundColor(Color(.label))
                                    .offset(y: -20)
                            }
                            
                            // Spacer to push "Minutes" to bottom
                            Spacer(minLength: 0)
                                .frame(height: -3)
                            
                            // Bottom line text - follows PETL spec (removed since unit is now inline)
                            EmptyView()
                                .frame(height: 16)
                        }
                        .offset(y: tracker.isCharging ? 0 : 10) // Move everything down 10px when not connected
                    }
                    
                    // Spacing after battery ring
                    Spacer(minLength: 26)
                    
                    // Battery History Chart Section
                    VStack(spacing: 0) {
                        // 25px gap from battery ring
                        Spacer(minLength: 25)
                        
                        // Battery Chart (placeholder for now)
                        BatteryChartView(recentSocUI: recentSocUI)
                        
                        // 25px gap to device information card
                        Spacer(minLength: 25)
                    }
                    
                    // Device Information Card - fixed size for iPhone 16 Pro
                    VStack(spacing: 0) {
                        // Section Title
                        HStack {
                            Text("Device Information")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(.secondaryLabel))
                                .tracking(-0.08)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        
                        // Device Row
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color(.separator))
                            HStack {
                                Text("Device")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.label))
                                    .tracking(-0.43)
                                Spacer()
                                Text(tracker.isCharging ? deviceModel : "...")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .tracking(-0.43)
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        }
                        
                        // Battery Capacity Row
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color(.separator))
                            HStack {
                                Text("Battery Capacity")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.label))
                                    .tracking(-0.43)
                                Spacer()
                                Text(tracker.isCharging ? batteryCapacity : "...")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .tracking(-0.43)
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        }
                        
                        // Battery Health Row
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color(.separator))
                            HStack {
                                Text("Estimated Battery Health")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.label))
                                    .tracking(-0.43)
                                Spacer()
                                Text(tracker.isCharging ? batteryHealth : "...")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .tracking(-0.43)
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        }
                    }
                    .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                    .cornerRadius(26)
                    .frame(width: 362)
                    .frame(height: 191)
                    
                    // Spacing between cards - increased to 25px minimum
                    Spacer(minLength: 25)
                    
                    // Charging Analytics Card - fixed size for iPhone 16 Pro
                    VStack(spacing: 0) {
                        // Section Title
                        HStack {
                            Text("Charging Analytics")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(.secondaryLabel))
                                .tracking(-0.08)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        
                        // Charging Rate Row
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color(.separator))
                            HStack {
                                Text("Charging Rate")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.label))
                                    .tracking(-0.43)
                                Spacer()
                                Text(tracker.isCharging ? analytics.characteristicLabel : "...")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .tracking(-0.43)
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        }
                        
                        // Estimated Wattage Row
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color(.separator))
                            HStack {
                                Text("Estimated Wattage")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.label))
                                    .tracking(-0.43)
                                Spacer()
                                Text(tracker.isCharging ? analytics.characteristicWatts : "...")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .tracking(-0.43)
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        }
                        
                        // Time to Full Charge Row
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color(.separator))
                            HStack {
                                Text("Time to Full Charge")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.label))
                                    .tracking(-0.43)
                                Spacer()
                                Text(chargeStateStore.isCharging ? eta.etaText : "...")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .tracking(-0.43)
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                        }
                    }
                    .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                    .cornerRadius(26)
                    .frame(width: 362)
                    .frame(height: 191) // Standard height for 3 rows
                    
                    // Bottom spacing for tab bar
                    Spacer(minLength: 100)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Charging Power Chart
struct ChargingPowerChart: View {
    let samples: [PowerSample]
    let minGapSeconds: TimeInterval = 5*60 // new session if samples are >5 min apart
    
    var body: some View {
        VStack(spacing: 12) {
            // Chart
            if #available(iOS 16.0, *) {
                Chart {
                    // Draw one continuous line per "charging session"
                    ForEach(sessions) { session in
                        ForEach(session.samples) { s in
                            LineMark(
                                x: .value("Time", s.time),
                                y: .value("Power (W)", s.watts),
                                // This is the key: add a series dimension so lines DO NOT connect across sessions
                                series: .value("Session", session.id.uuidString)
                            )
                            .interpolationMethod(.linear)
                            
                            AreaMark(
                                x: .value("Time", s.time),
                                y: .value("Power (W)", s.watts),
                                series: .value("Session", session.id.uuidString)
                            )
                            .foregroundStyle(.green.opacity(0.18))
                        }
                    }
                }
                // Y axis
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: yTicks) { value in
                        AxisValueLabel {
                            Text("\(Int((value.as(Double.self) ?? 0)))W")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(.secondaryLabel))
                        }
                        AxisGridLine()
                    }
                }

                // X axis (match the history chart): ticks at >= 4h spacing, aligned to steps
                .chartXScale(domain: alignedDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: tickStepHours)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let d = value.as(Date.self) {
                                if tickStepHours >= 24 {
                                    Text(d, format: .dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated)))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(.secondaryLabel))
                                } else {
                                    Text(d, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(.secondaryLabel))
                                }
                            }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("Charging Power Over Time")
            } else {
                Text("Charts require iOS 16+")
                    .foregroundColor(.gray)
                    .frame(height: 180)
            }
            
            // Legend and last updated
            HStack {
                // Legend
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    
                    Text("Charging Power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(.secondaryLabel))
                }
                
                Spacer()
                
                // Last updated
                Text("Last updated: \(formatLastUpdated())")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
    }
    
    // MARK: - Sessions (prevents lines across unplugged gaps)
    private var sessions: [PowerSession] {
        var out: [PowerSession] = []
        var cur: [PowerSample] = []
        var lastTime: Date?

        for s in samples.sorted(by: { $0.time < $1.time }) {
            guard s.isCharging else {                 // break on unplugged
                if !cur.isEmpty { out.append(.init(samples: cur)); cur.removeAll() }
                lastTime = nil
                continue
            }
            if let lt = lastTime, s.time.timeIntervalSince(lt) > minGapSeconds {
                if !cur.isEmpty { out.append(.init(samples: cur)); cur.removeAll() }
            }
            cur.append(s)
            lastTime = s.time
        }
        if !cur.isEmpty { out.append(.init(samples: cur)) }
        return out
    }

    // MARK: - X Axis helpers (keeps labels ≥ 4h apart)
    private var rawDomain: ClosedRange<Date> {
        guard let first = samples.first?.time, let last = samples.last?.time else {
            let now = Date()
            return now.addingTimeInterval(-4*3600)...now
        }
        return first == last ? first.addingTimeInterval(-1800)...last.addingTimeInterval(1800) : first...last
    }

    private var tickStepHours: Int {
        let spanHrs = rawDomain.upperBound.timeIntervalSince(rawDomain.lowerBound) / 3600
        if spanHrs <= 24 { return 4 }
        if spanHrs <= 72 { return 8 }
        if spanHrs <= 7*24 { return 12 }
        return 24
    }

    private var alignedDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let lb = floorToHour(rawDomain.lowerBound, step: tickStepHours, cal)
        let ub = ceilToHour(rawDomain.upperBound,  step: tickStepHours, cal)
        return lb...ub
    }

    private func floorToHour(_ d: Date, step: Int, _ cal: Calendar) -> Date {
        var c = cal.dateComponents([.year,.month,.day,.hour], from: d)
        c.minute = 0; c.second = 0
        if let h = c.hour { c.hour = (h / step) * step }
        return cal.date(from: c) ?? d
    }
    private func ceilToHour(_ d: Date, step: Int, _ cal: Calendar) -> Date {
        let f = floorToHour(d, step: step, cal)
        return f == d ? d : cal.date(byAdding: .hour, value: step, to: f) ?? d
    }

    // MARK: - Y Axis helpers
    private var maxW: Double {
        sessions.flatMap(\.samples).map(\.watts).max() ?? 15
    }
    private var yDomain: ClosedRange<Double> {
        let upper = max(10, ceil((maxW * 1.1) / 5.0) * 5.0)  // round up to nearest 5W
        return 0 ... upper
    }
    private var yTicks: [Double] {
        let upper = yDomain.upperBound
        let step = upper <= 20 ? 5.0 : 10.0
        return stride(from: 0.0, through: upper, by: step).map { $0 }
    }
    
    private func formatLastUpdated() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}

// MARK: - Power Session Model
private struct PowerSession: Identifiable {
    let id = UUID()
    let samples: [PowerSample]
}

// MARK: - Simple Battery Chart
struct SimpleBatteryChart: View {
    @ObservedObject var trackingManager: BatteryTrackingManager
    let axis: ChartTimeAxisModel
    let recentSocUI: [ChargeRow] // Live UI frame buffer
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 12) {
            // Chart
            if #available(iOS 16.0, *) {
                // Merge DB history with live UI frames for real-time chart updates
                let history = trackingManager.historyPointsFromDB(hours: 24)
                let cutoff = Date().addingTimeInterval(-30 * 60)
                let historic = history.filter { $0.timestamp < cutoff }
                
                // Merge historic DB data with recent live UI frames
                let recent = recentSocUI.map { row in
                    BatteryDataPoint(
                        batteryLevel: Float(row.soc) / 100.0,
                        isCharging: row.isCharging,
                        timestamp: Date(timeIntervalSince1970: row.ts)
                    )
                }
                let series = (historic + recent).sorted { $0.timestamp < $1.timestamp }
                
                Chart(series) { dataPoint in
                    LineMark(
                        x: .value("Time", dataPoint.timestamp),
                        y: .value("Battery", dataPoint.batteryLevel * 100)
                    )
                    .foregroundStyle(Color(red: 0.29, green: 0.87, blue: 0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, lineCap: .round))
                    
                    AreaMark(
                        x: .value("Time", dataPoint.timestamp),
                        y: .value("Battery", dataPoint.batteryLevel * 100)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.29, green: 0.87, blue: 0.5).opacity(0.3),
                                Color(red: 0.29, green: 0.87, blue: 0.5).opacity(0.1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                // Y axis: 0–100 with clear ticks
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: Array(stride(from: 0, through: 100, by: 20))) { value in
                        AxisValueLabel {
                            Text("\(Int((value.as(Double.self) ?? 0)))%")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(.secondaryLabel))
                        }
                        AxisGridLine()
                    }
                }
                
                // X axis: hour-based ticks with minimum 4-hour spacing
                .chartXScale(domain: axis.domain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: axis.tickStepHours)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                if axis.tickStepHours >= 24 {
                                    Text(date, format: .dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated)))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(.secondaryLabel))
                                } else {
                                    Text(date, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(.secondaryLabel))
                                }
                            }
                        }
                    }
                }
                .frame(height: 200)

            } else {
                Text("Charts require iOS 16+")
                    .foregroundColor(.gray)
                    .frame(height: 200)
            }
            
            // Legend and last updated
            HStack {
                // Legend
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.29, green: 0.87, blue: 0.5))
                        .frame(width: 8, height: 8)
                    
                    Text("Battery Level")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(.secondaryLabel))
                }
                
                Spacer()
                
                // Last updated
                Text("Last updated: \(formatLastUpdated())")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
    }
    

    
    private func formatLastUpdated() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: Date())
    }
}



// MARK: - Battery Chart View
struct BatteryChartView: View {
    @ObservedObject var trackingManager = BatteryTrackingManager.shared
    @StateObject private var vm = ChartsVM(trackingManager: BatteryTrackingManager.shared)
    @Environment(\.colorScheme) var colorScheme
    let recentSocUI: [ChargeRow] // Live UI frame buffer
    #if DEBUG
    @State private var lastAxisKey: String = ""
    #endif
    
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                // --- Battery (24h) ---
                VStack(alignment: .leading, spacing: 12) {
                    Text("Charging History")
                        .font(.title3).bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                    SimpleBatteryChart(trackingManager: trackingManager, axis: createHistoryAxis(), recentSocUI: recentSocUI)
                        .frame(minHeight: 220)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                .cornerRadius(26)
                .frame(width: 362)

                // --- Power (12h Bars) ---
                VStack(alignment: .leading, spacing: 12) {
                    Text("Charging Power History")
                        .font(.title3).bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                    ChargingPowerBarsChart(
                        samples: vm.power12h,
                        axis: createPowerAxis()
                    )
                    .frame(minHeight: 220)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(colorScheme == .dark ? Color(.systemGray5) : Color(hex: "#ffffff"))
                .cornerRadius(26)
                .frame(width: 362)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .onAppear {
            // ChartsVM handles all subscriptions automatically
        }
    }
    
    // MARK: - Axis helpers
    private func createHistoryAxis() -> ChartTimeAxisModel {
        // Merge DB history with live UI frames for real-time chart updates
        let history = trackingManager.historyPointsFromDB(hours: 24)
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let historic = history.filter { $0.timestamp < cutoff }
        
        // Merge historic DB data with recent live UI frames
        let recent = recentSocUI.map { row in
            BatteryDataPoint(
                batteryLevel: Float(row.soc) / 100.0,
                isCharging: row.isCharging,
                timestamp: Date(timeIntervalSince1970: row.ts)
            )
        }
        let series = (historic + recent).sorted { $0.timestamp < $1.timestamp }
        
        return ChartTimeAxisModel(historyDates: series.map { $0.timestamp })
    }

    private func createPowerAxis() -> ChartTimeAxisModel {
        return ChartTimeAxisModel(historyDates: vm.power12h.map(\.time)) // use VM data
    }
    
    // ChartsVM handles all data loading and change detection
}

struct HistoryNavigationContent: View {
    var body: some View {
        VStack {
            Text("History")
                .font(.largeTitle)
                .foregroundColor(.primary)
            Spacer()
        }
    }
}

struct InfoNavigationContent: View {
    @ObservedObject private var tracker = BatteryTrackingManager.shared
    let isActivityRunning: Bool
    let oneSignalStatus: String
    let deviceToken: String
    @Binding var logMessages: [String]
    @Binding var showLogs: Bool
    let onStartActivity: () -> Void
    let onStopActivity: () -> Void
    let onUpdateActivity: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("PETL Info")
                .font(.largeTitle)
                .foregroundColor(.primary)
            
            #if DEBUG
            // Debug section
            VStack(spacing: 15) {
                Text("Debug Controls")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Button("Start Live Activity") {
                    print("🔧 Manual Live Activity start requested")
                    onStartActivity()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Stop Live Activity") {
                    print("🔧 Manual Live Activity stop requested")
                    onStopActivity()
                }
                .buttonStyle(.bordered)
                
                Button("Test PETL Data") {
                    print("🔧 Testing PETL data in Live Activity")
                    onUpdateActivity()
                }
                .buttonStyle(.bordered)
                
                Button("Force Start Live Activity") {
                    Task { @MainActor in
                        await LiveActivityManager.shared.startActivity(reason: .debug)
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button("End All Live Activities") {
                    Task { @MainActor in
                        await LiveActivityManager.shared.endAll("DEBUG-END-ALL")
                    }
                }
                .buttonStyle(.bordered)
                
                // Status display
                VStack(alignment: .leading, spacing: 8) {
                    Text("Status:")
                        .font(.headline)
                    
                    Text("Charging: \(tracker.isCharging ? "Yes" : "No")")
                    Text("Live Activity Active: \(isActivityRunning ? "Yes" : "No")")
                    Text("Battery Level: \(Int(tracker.level * 100))%")
                    Text("OneSignal: \(oneSignalStatus)")
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }
            #endif
            
            #if DEBUG
            // Log Viewer
            LogViewerView(logMessages: .constant(globalLogMessages), showLogs: $showLogs)
            #endif
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Helper Functions
extension HomeNavigationContent {
    // Helper functions removed as they're no longer needed
}

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

#if DEBUG
struct DebugControls: View {
    var body: some View {
        VStack(spacing: 8) {
            Button("Force Start Live Activity") {
                Task { @MainActor in
                    await LiveActivityManager.shared.startActivity(reason: .debug)
                }
            }
            Button("End All Live Activities") {
                Task { @MainActor in
                    await LiveActivityManager.shared.endAll("DEBUG-END-ALL")
                }
            }
        }.padding(.vertical, 8)
    }
}

struct LogViewerView: View {
    @Binding var logMessages: [String]
    @Binding var showLogs: Bool
    @State private var showingCopyAlert = false
    
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.purple)
                Text("App Logs")
                    .font(.headline)
                Spacer()
                
                if showLogs {
                    Button(action: copyLogsToClipboard) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                
                Button(showLogs ? "Hide" : "Show") {
                    showLogs.toggle()
                }
                .font(.caption)
            }
            
            if showLogs {
                EnhancedLogMessagesView(logMessages: logMessages)
                
                HStack(spacing: 10) {
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
                    
                    Button("Clear Logs") {
                        logMessages.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(12)
        .alert("Logs Copied", isPresented: $showingCopyAlert) {
            Button("OK") { }
        } message: {
            Text("All logs have been copied to clipboard")
        }
    }
    
    private func copyLogsToClipboard() {
        let allLogs = logMessages.joined(separator: "\n")
        UIPasteboard.general.string = allLogs
        showingCopyAlert = true
    }
}
#else
struct LogViewerView: View {
    @Binding var logMessages: [String]
    @Binding var showLogs: Bool
    
    var body: some View {
        EmptyView()
    }
}
#endif

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

struct EnhancedLogMessagesView: View {
    let logMessages: [String]
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with log count
            HStack {
                Text("Logs (\(logMessages.count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer()
                Text("Latest at top")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray5))
            
            // Log content area
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(logMessages.enumerated().reversed()), id: \.offset) { index, message in
                        EnhancedLogMessageRow(
                            message: message,
                            index: logMessages.count - index,
                            isEven: index % 2 == 0
                        )
                    }
                }
            }
            .frame(maxHeight: 400) // Much larger viewing window
            .background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground))
        }
        .background(colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
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

struct EnhancedLogMessageRow: View {
    let message: String
    let index: Int
    let isEven: Bool
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Log number
            Text("#\(index)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(.tertiaryLabel))
                .frame(width: 30, alignment: .leading)
            
            // Message content
            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(.label))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            isEven ?
                (colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground)) :
                (colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6))
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color(.separator)),
            alignment: .bottom
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(BatteryTrackingManager.shared)
}
