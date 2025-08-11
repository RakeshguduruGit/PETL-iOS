//
//  LiveActivityManager.swift
//  PETL
//
//  Created by rakesh guduru on 7/27/25.
//

import Foundation
import ActivityKit
import SwiftUI
import os.log
import BackgroundTasks
import UIKit
import Combine
import OSLog
import OneSignalFramework

private let laLogger = Logger(subsystem: "com.petl.app", category: "liveactivity")
private let osLogger = Logger(subsystem: "com.petl.app", category: "onesignal")
private let uiLogger = Logger(subsystem: "com.petl.app", category: "ui")

// MARK: - App State Helper
private var isForeground: Bool {
    UIApplication.shared.applicationState == .active
}

// MARK: - Activity Coordinator Actor
actor ActivityCoordinator {
    static let shared = ActivityCoordinator()
    private var current: Activity<PETLLiveActivityExtensionAttributes>? = nil
    private var isRequesting = false      // NEW
    
    func startIfNeeded() async -> String? {
        guard !isRequesting else { return nil }   // another call in flight

        // If we still have a pointer, scrub it if that activity isn't actually active
        if let cur = current {
            switch cur.activityState {
            case .active, .stale:
                // real, on-screen activity -> do nothing
                print("ℹ️  startIfNeeded skipped—widget already active.")
                return nil
            default:
                // ended / dismissed / unknown -> clear pointer and proceed
                current = nil
            }
        }
        
        // Rehydrate if the system already has one (e.g. app relaunch)
        if current == nil, let existing = Activity<PETLLiveActivityExtensionAttributes>.activities.last {
            current = existing
            print("ℹ️  Rehydrated existing Live Activity id:", existing.id)
            return existing.id
        }
        
        // Fresh request (make sure device still reports charging)
        guard UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full else { return nil }
        isRequesting = true                    // lock

        do {
            current = try await Activity.request(
                attributes: PETLLiveActivityExtensionAttributes(name: "PETL Charging Activity"),
                content: ActivityContent(state: firstContent(), staleDate: Date().addingTimeInterval(3600)),
                pushType: .token
            )
            let activityId = current?.id ?? "unknown"
            
            // Capture and register the Live Activity push token for background updates
            Task.detached { [weak current] in
                guard let activity = current else { return }
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    Task { @MainActor in
                        addToAppLogs("📡 LiveActivity token len=\(tokenData.count)")
                    }
                    await OneSignalClient.shared.registerLiveActivityToken(activityId: activity.id, tokenHex: hex)
                }
            }
            
            isRequesting = false                   // unlock
            return activityId
        } catch {
            print("❌ Activity.request failed:", error)
            isRequesting = false                   // unlock
            return nil
        }
    }
    
    func stopIfNeeded() async {
        guard let activity = current else { return }
        await activity.end(dismissalPolicy: .immediate)
        current = nil
        print("🛑 Ended Live Activity")
    }
    
    @MainActor
    private func firstContent() -> PETLLiveActivityExtensionAttributes.ContentState {
        let level = Double(UIDevice.current.batteryLevel) // 0.0—1.0
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full

        // Initialize DI with presented values (not raw)
        let rawETA = ChargeEstimator.shared.current?.minutesToFull
        let rawW = BatteryTrackingManager.shared.currentWatts
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        
        let token = BatteryTrackingManager.shared.tickToken
        let initialEta = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarm, tickToken: token).minutes
            : rawETA
        
        let (label, _) = ChargingAnalytics.chargingCharacteristic(pctPerMinute: ChargeEstimator.shared.current?.pctPerMin)

        return PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Float(level),
            isCharging: isCharging,
            chargingRate: label,
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: initialEta ?? 0,
            deviceModel: getDeviceModel(),
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
    }
    

    
    private nonisolated func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        
        // Map to readable names
        let deviceNames: [String: String] = [
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,3": "iPhone 16",
            "iPhone16,4": "iPhone 16 Plus",
            "iPhone16,5": "iPhone 16 Pro",
            "iPhone16,6": "iPhone 16 Pro Max"
        ]
        
        return deviceNames[identifier] ?? "iPhone"
    }
}

// MARK: - Live Activity Manager
@MainActor
final class LiveActivityManager {
    
    static let shared = LiveActivityManager()
    
    private static var isConfigured = false
    private static var didForceFirstPushThisSession = false
    
    private init() {}
    
    deinit {
        // Clean cancel on deinit (optional polish)
        cancellables.forEach { $0.cancel() }
        os_log("📱 LiveActivityManager deinit - cleaned up cancellables")
    }
    
    // ===== BEGIN STABILITY-LOCKED: LiveActivity cooldown (do not edit) =====
    // MARK: - Private Properties
    
    private var isActive = false
    private var lastStartAt: Date?
    private var lastEndAt: Date?
    private let minRestartInterval: TimeInterval = 8 // seconds
    
    private var updateTimer: Timer?
    private var failsafeTask: UIBackgroundTaskIdentifier = .invalid
    private var lastUpdateTime: Date = Date()
    private var lastPush: Date? = nil
    private var lastLevelPct: Int = 0
    private var cancellables = Set<AnyCancellable>()
    private var unplugWorkItem: DispatchWorkItem?
    private var chargingStartTime: Date?
    private var totalChargingTime: TimeInterval = 0
    private var lastPushedMinutes: Int?
    private var endWatchdogTimer: DispatchWorkItem?
    var lastRemoteSeq: Int = 0   // for OneSignal dedupe
    // ===== END STABILITY-LOCKED =====

    // MARK: - Reliability counters (QA)
    private var startsRequested = 0
    private var startsSucceeded = 0
    private var endsRequestedLocal = 0
    private var endsSucceeded = 0
    private var remoteEndsHonored = 0
    private var remoteEndsIgnored = 0
    private var watchdogFires = 0
    private var duplicateCleanups = 0
    private var selfPingsQueued = 0

    private func logReliabilitySummary(_ prefix: String = "ℹ️ Reliability") {
        let summary = "\(prefix): startReq=\(self.startsRequested) startOK=\(self.startsSucceeded) " +
                      "endReqLocal=\(self.endsRequestedLocal) endOK=\(self.endsSucceeded) " +
                      "remoteEndOK=\(self.remoteEndsHonored) remoteEndIgnored=\(self.remoteEndsIgnored) " +
                      "watchdog=\(self.watchdogFires) dupCleanups=\(self.duplicateCleanups) selfPings=\(self.selfPingsQueued)"
        laLogger.info("\(summary)")
    }

    private var lastFGSummaryAt: Date = .distantPast

    func onAppWillEnterForeground() {
        BatteryTrackingManager.shared.startMonitoring() // idempotent
        let now = Date()
        if now.timeIntervalSince(lastFGSummaryAt) > 8 {
            logReliabilitySummary("📊 Reliability")
            lastFGSummaryAt = now
        }
    }
    
    @MainActor
    func stopIfNeeded() async {
        endAll("external call")
    }
    
    @MainActor
    func endIfActive() async {
        endAll("charge ended")
    }
    
    @MainActor
    func markNewSession() {
        forceNextPush = true
        lastPush = .distantPast
        lastRichState = nil
        Self.didForceFirstPushThisSession = false   // NEW
    }
    
    /// True after `startIfNeeded()` succeeds during the *current* charging session.
    /// It is cleared the moment we really end the Live Activity (i.e. on unplug).
    private var didStartThisSession = false
    
    // Coalesce near-simultaneous start triggers
    private var recentStartAt: Date? = nil
    private var retryStartTask: Task<Void, Never>?
    private var forceNextPush = false
    
    // MARK: - Private Properties
    private var lastRichState: PETLLiveActivityExtensionAttributes.ContentState?
    
    // Actor-based debounce for tighter control
    private actor ActivityGate {
        var isRequesting = false
        
        func begin() -> Bool {
            if isRequesting { return false }
            isRequesting = true
            return true
        }
        
        func end() { isRequesting = false }
    }
    
    private let gate = ActivityGate()
    

    
    // MARK: - Public API ----------------------------------------------------
    
    func configure() {
        guard !Self.isConfigured else { return }
        Self.isConfigured = true
        laLogger.info("🔧 LiveActivityManager configured")

        BatteryTrackingManager.shared.startMonitoring()

        // Subscribe to unified estimate stream (single-source)
        ChargeEstimator.shared.estimateSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] est in
                guard let self = self else { return }

                let bigDelta = self.lastPushedMinutes.map { abs($0 - est.minutesToFull) >= 3 } ?? true

                if !Self.didForceFirstPushThisSession {
                    self.updateAllActivities(using: est, force: true)
                    Self.didForceFirstPushThisSession = true
                    self.lastPushedMinutes = est.minutesToFull
                    laLogger.info("⚡ First Live Activity update forced (minutes=\(est.minutesToFull))")
                } else if bigDelta {
                    // push early for meaningful changes
                    self.updateAllActivities(using: est, force: true)
                    self.lastPushedMinutes = est.minutesToFull
                    laLogger.info("📦 Big delta push (minutes=\(est.minutesToFull))")
                } else {
                    self.updateAllActivities(using: est, force: false)
                }
            }
            .store(in: &cancellables)

                            // Subscribe to battery snapshots for start/stop authority
                    BatteryTrackingManager.shared.snapshotSubject
                        .receive(on: RunLoop.main)
                        .debounce(for: .seconds(QA.debounceSeconds), scheduler: RunLoop.main)
                        .sink { [weak self] snap in
                            guard let self = self else { return }
                            laLogger.debug("⏳ Debounced snapshot: \(Int(snap.level * 100))%, charging=\(snap.isCharging)")
                            self.handle(snapshot: snap)
                        }
                        .store(in: &cancellables)

        ensureBatteryMonitoring()
        registerBGTask()
        restorePersistedChargingState()
    }
    
    func handleRemotePayload(_ json: [AnyHashable: Any]) {
        guard let action = json["live_activity_action"] as? String else { return }
        let seq = (json["seq"] as? Int) ?? 0

        // de-dupe
        if seq <= lastRemoteSeq {
            osLogger.debug("↩️ Dropped duplicate/old push (seq=\(seq))")
            return
        }
        lastRemoteSeq = seq

        switch action {
        case "start":
            if BatteryTrackingManager.shared.isCharging {
                if let t = recentStartAt, Date().timeIntervalSince(t) < 1.5 {
                    osLogger.info("⏳ Remote start ignored (debounce)")
                    return
                }
                osLogger.info("▶️ Remote start honored (seq=\(seq))")
                Task { await startIfNeeded() }
            } else {
                osLogger.info("🚫 Remote start ignored (local not charging, seq=\(seq))")
            }

        case "update":
            guard hasLiveActivity else {
                osLogger.info("ℹ️ Remote update ignored (no active activity, seq=\(seq))")
                return
            }
            // If you also include minutes/rate/level in data, you can build a ContentState and push here
            // Otherwise just let ChargeEstimator drive; remote updates are optional.
            osLogger.info("🔄 Remote update received (seq=\(seq))")
            // LiveActivityManager.shared.updateAllActivities(using: currentEst, force: true) // optional

        case "end":
            if !BatteryTrackingManager.shared.isCharging {
                remoteEndsHonored += 1
                osLogger.info("⏹️ Remote end honored (seq=\(seq))")
                endAll("OneSignal")
            } else {
                remoteEndsIgnored += 1
                osLogger.info("🚫 Remote end ignored (local charging, seq=\(seq))")
            }

        default: break
        }
    }
    
    // MARK: - Private -------------------------------------------------------
    
    // MARK: - Authoritative start/stop from local battery state + self-ping backup
    
    private func handle(snapshot s: BatterySnapshot) {
        if s.isCharging {
            startsRequested += 1
            Task { await startIfNeeded() }
        } else {
            endsRequestedLocal += 1
            // end locally first, then schedule watchdog only if needed
            Task { @MainActor in
                await endAll("local unplug")
                // Only schedule watchdog if activities still exist after local end
                if hasLiveActivity {
                    scheduleEndWatchdog()
                    selfPingsQueued += 1
                    OneSignalClient.shared.enqueueSelfEnd(seq: OneSignalClient.shared.bumpSeq())
                }
            }
        }
    }

    private func scheduleEndWatchdog() {
        endWatchdogTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Re-check if activities still exist before firing
            let activityCount = Activity<PETLLiveActivityExtensionAttributes>.activities.count
            if self.hasLiveActivity && activityCount > 0 {
                self.watchdogFires += 1
                addToAppLogs("⏱️ End watchdog fired; \(activityCount) activity(ies) still present, enqueueing final end self-ping")
                OneSignalClient.shared.enqueueSelfEnd(seq: OneSignalClient.shared.bumpSeq())
            }
        }
        endWatchdogTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + QA.watchdogSeconds, execute: item)
    }

    private func cancelEndWatchdog() {
        endWatchdogTimer?.cancel()
        endWatchdogTimer = nil
    }
    
    private func updateAllActivities(using estimate: ChargeEstimate, force: Bool = false) {
        let now = Date()
        
        // Enhanced force criteria: ≥2 min delta OR SOC changed by ≥1% OR standard 60s throttle
        let lastETA = lastRichState?.timeToFullMinutes ?? 0
        let currentETA = estimate.minutesToFull
        let etaDelta = abs(currentETA - lastETA)
        
        let lastSOC = lastRichState?.batteryLevel ?? 0.0
        let currentSOC = estimate.level01
        let socDelta = abs(Double(currentSOC) - Double(lastSOC))
        
        let doForce = force || forceNextPush
        let canPush = doForce || 
                     lastPush == nil || 
                     now.timeIntervalSince(lastPush!) >= 60 ||
                     etaDelta >= 2 ||
                     socDelta >= 0.01
        
        guard canPush else { return }

        // ---- Inputs (same as UI) ----
        let rawETA = estimate.minutesToFull
        let rawW   = BatteryTrackingManager.shared.currentWatts   // <- smoothed watts
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isChg  = BatteryTrackingManager.shared.isCharging
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        let token  = BatteryTrackingManager.shared.tickToken

        // ---- Sanitize via ETAPresenter (single source of truth) ----
        let displayedETA = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(
                rawETA: rawETA,
                watts: rawW,
                sysPct: sysPct,
                isCharging: isChg,
                isWarmup: isWarm,
                tickToken: token
            ).minutes
            : rawETA

        // ---- Edge clamp at DI just in case (same rule as elsewhere) ----
        var etaForDI = displayedETA
        if !isWarm, !forceNextPush, let e = etaForDI, e >= 180, rawW <= 5.0 {
            etaForDI = ETAPresenter.shared.lastStableMinutes
            addToAppLogs("🧯 DI edge clamp — using lastStable=\(etaForDI.map{"\($0)m"} ?? "—")")
        }

        // ---- Build content (merge any last rich state) ----
        var merged = lastRichState ?? firstContent()
        merged.batteryLevel       = Float(estimate.level01)
        merged.isCharging         = isChg
        merged.estimatedWattage   = String(format: "%.1fW", rawW)
        merged.timeToFullMinutes  = etaForDI ?? 0
        merged.timestamp          = estimate.computedAt

        // Existing: local update
        Task { @MainActor in 
            await pushToAll(merged)
            forceNextPush = false
        }
        lastPush = now

        // NEW: if not foreground, enqueue a remote update (server or OneSignal)
        if !isForeground {
            OneSignalClient.shared.enqueueLiveActivityUpdate(
                minutesToFull: merged.timeToFullMinutes,
                batteryLevel01: Double(merged.batteryLevel),
                wattsString: merged.estimatedWattage,
                isCharging: merged.isCharging,
                isWarmup: merged.isInWarmUpPeriod
            )
        }
    }
    
    @MainActor
    func updateIfNeeded(from snapshot: BatterySnapshot) {
        // Deprecated: start/stop is centralized in BatteryTrackingManager (+ optional app launch probe).
        // Intentionally left as no-op to avoid duplicate starts.
    }
    
    func publishLiveActivityAnalytics(_ analytics: ChargingAnalyticsStore) {
        // 1) Get raw inputs from the same place as the app (NO 10W after warmup)
        let rawETA = analytics.timeToFullMinutes
        let rawW = BatteryTrackingManager.shared.currentWatts  // <- must be the SMOOTHED watts from estimator
        
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isChg = BatteryTrackingManager.shared.isCharging
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        
        // 2) Present once, same quarantine/slew logic as UI
        let token = BatteryTrackingManager.shared.tickToken
        let displayedETA = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isChg, isWarmup: isWarm, tickToken: token).minutes
            : rawETA
        
        // 3) Use displayedETA for DI/Live Activity payloads
        var etaForDI = displayedETA
        
        // 4) Add a cheap guardrail in LA (just in case)
        if let e = etaForDI, e >= 180, rawW <= 5.0 {
            // quarantine at DI edge as a second safety net
            etaForDI = ETAPresenter.shared.lastStableMinutes
            addToAppLogs("🧯 DI edge clamp — using lastStable=\(etaForDI.map{"\($0)m"} ?? "—")")
        }
        
        let state = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Float(BatteryTrackingManager.shared.level),
            isCharging: true,
            chargingRate: "Charging",
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: etaForDI ?? 0,
            deviceModel: "", batteryHealth: "",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
        
        // update activities with 'state' (existing code)
        Task { @MainActor in await pushToAll(state) }
        
        // 4) Log DI payload for parity check
        addToAppLogs("📤 DI payload — eta=\(etaForDI.map{"\($0)m"} ?? "—") W=\(String(format:"%.1f", rawW))")
    }
    
    // MARK: - Helpers
    /// Strict check for system-active activities only
    private var hasSystemActive: Bool {
        Activity<PETLLiveActivityExtensionAttributes>.activities.contains {
            $0.activityState == .active
        }
    }
    
    /// Returns true only if a widget is truly still on-screen.
    /// Also cleans up duplicate widgets automatically.
    private var hasLiveActivity: Bool {
        let list = Activity<PETLLiveActivityExtensionAttributes>.activities

        // 1️⃣ If more than one, keep the newest and end the rest
        if list.count > 1 {
            #if DEBUG
            addToAppLogs("🧹 Cleaning up \(list.count - 1) duplicate widgets")
            #endif
            list.dropLast().forEach { act in
                Task { await act.end(dismissalPolicy: .immediate) }
            }
        }

        guard let act = list.last else { return false }

        switch act.activityState {
        case .active, .stale:
            #if DEBUG
            let running = list.map { "\($0.id.prefix(4))-\(String(describing: $0.activityState))" }
            laLogger.debug("💭 activity list: \(running)")
            #endif
            return true                       // real widget on-screen
        case .dismissed:
            // grace window: allow a new widget 2 s after dismissal
            // Since we can't access _endDate directly, we'll treat dismissed as immediately inactive
            // This allows quick re-plug scenarios to work properly
            #if DEBUG
            addToAppLogs("⏰ Dismissed widget - treating as inactive for quick re-plug")
            #endif
            return false                      // treat as gone immediately
        default:
            return false
        }
    }
    
    /// Updates the singleton's hasActiveWidget property
    private func updateHasActiveWidget() {
        Task { @MainActor in
            BatteryTrackingManager.shared.hasActiveWidget = hasLiveActivity
        }
    }
    
    /// Starts a Live Activity unless one is already active.
    @MainActor
    func startIfNeeded() async {
        // ===== BEGIN STABILITY-LOCKED: LiveActivity cooldown (do not edit) =====
        // already running?
        guard !isActive else {
            addToAppLogs("ℹ️ Live Activity already active — skip start")
            return
        }
        // recently ended? enforce cooldown to avoid flappy restarts
        if let ended = lastEndAt, Date().timeIntervalSince(ended) < minRestartInterval {
            let remain = Int(minRestartInterval - Date().timeIntervalSince(ended))
            addToAppLogs("⏳ Live Activity cooldown — skip start (\(remain)s left)")
            return
        }
        // ===== END STABILITY-LOCKED =====
        
        // Coalesce near-simultaneous triggers (launch probe, remote "start", snapshot)
        if let t = recentStartAt, Date().timeIntervalSince(t) < 1.5 {
            retryStartTask?.cancel()
            retryStartTask = Task { [weak self] in
                // try again shortly; if still charging and no activity, start
                try? await Task.sleep(nanoseconds: 1_700_000_000) // 1.7s
                guard let self else { return }
                if BatteryTrackingManager.shared.isCharging,
                   !self.hasSystemActive {
                    await self.startIfNeeded()  // will pass debounce by now
                }
            }
            laLogger.debug("⏳ startIfNeeded debounced; scheduled retry")
            return
        }
        
        // Hard guard: read FRESH battery state (not cached flag)
        let st = UIDevice.current.batteryState
        let isChargingNow = (st == .charging || st == .full)
        guard isChargingNow else {
            addToAppLogs("ℹ️ startIfNeeded skipped—local not charging (fresh)")
            return
        }
        
        guard !hasLiveActivity else {
            laLogger.debug("ℹ️ startIfNeeded aborted (widget already active)")
            return
        }
        laLogger.info("🚧 startIfNeeded running")
        
        let activityId = await ActivityCoordinator.shared.startIfNeeded()
        if let id = activityId {
            startsSucceeded += 1
            isActive = true
            // ===== BEGIN STABILITY-LOCKED: LiveActivity cooldown (do not edit) =====
            lastStartAt = Date()
            // ===== END STABILITY-LOCKED =====
            laLogger.info("🎬 Started Live Activity")
            addToAppLogs("🎬 Started Live Activity")
            cancelEndWatchdog()
            recentStartAt = Date()
        } else if !hasLiveActivity {
            // Retry once after a short delay, only if still charging
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                let st = UIDevice.current.batteryState
                guard st == .charging || st == .full, !self.hasLiveActivity else { return }
                if let retryId = await ActivityCoordinator.shared.startIfNeeded() {
                    self.startsSucceeded += 1
                    self.isActive = true
                    addToAppLogs("🎬 Started Live Activity id: \(retryId) (retry)")
                    self.recentStartAt = Date()
                }
            }
        }
    }
    
    @MainActor
    private func pushToAll(_ state: PETLLiveActivityExtensionAttributes.ContentState) async {
        for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
            await activity.update(using: state)
        }
        let message = "🔄 push level=\(Int(state.batteryLevel*100)) rate=\(state.chargingRate) time=\(state.timeToFullMinutes) min"
        laLogger.info("\(message)")
    }
    
    private func updateAll(with dict: [String: Any]) {
        // 1. Convert dictionary → ContentState
        let rich = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Float(dict["batteryLevel"] as? Double ?? 0),
            isCharging:   dict["isCharging"]   as? Bool   ?? false,
            chargingRate: dict["chargingRate"] as? String ?? "Standard Charging",
            estimatedWattage: dict["estimatedWattage"] as? String ?? "10W",
            timeToFullMinutes: dict["timeToFullMinutes"] as? Int ?? 0,
            deviceModel:  dict["deviceModel"]  as? String ?? "iPhone",
            batteryHealth: dict["batteryHealth"] as? String ?? "Excellent",
            isInWarmUpPeriod: dict["isInWarmUpPeriod"] as? Bool ?? false,
            timestamp:    Date()
        )

        // 2. Cache & push
        lastRichState = rich
        Task { @MainActor in await pushToAll(rich) }
    }
    
    @MainActor
    private func endAll(_ src: String) {
        // Query activities for the SAME attributes type you used at start
        let list = Activity<PETLLiveActivityExtensionAttributes>.activities
        let countBefore = list.count

        guard countBefore > 0 else {
            // nothing to end
            return
        }
        
        #if DEBUG
        addToAppLogs("🧪 endAll() about to end \(countBefore) activity(ies)")
        #endif

        // 1) End with 'immediate' dismissal policy (no grace period)
        Task {
            for a in list {
                do {
                    let endState = PETLLiveActivityExtensionAttributes.ContentState(
                        batteryLevel: BatteryTrackingManager.shared.level,
                        isCharging: false,
                        chargingRate: "Not charging",
                        estimatedWattage: "0W",
                        timeToFullMinutes: 0, // won't be shown; we are ending
                        deviceModel: getDeviceModel(),
                        batteryHealth: "Excellent",
                        isInWarmUpPeriod: false,
                        timestamp: Date()
                    )
                    try await a.end(ActivityContent(state: endState, staleDate: nil), dismissalPolicy: .immediate)
                } catch {
                    addToAppLogs("❌ Activity.end failed: \(error.localizedDescription)")
                }
            }

            // 2) Give the system a tick to process the dismissal, then verify
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            let remaining = Activity<PETLLiveActivityExtensionAttributes>.activities.count
            #if DEBUG
            addToAppLogs("🧪 endAll() verification: remaining=\(remaining)")
            #endif

            // 3) If anything is still present, schedule the watchdog/self-ping fallback
            if remaining > 0 {
                scheduleEndWatchdog()  // your existing watchdog
            } else {
                cancelEndWatchdog()    // make sure we clear any pending watchdog
            }

            // 4) Reset your session flags only when we've truly ended
            self.didStartThisSession = false
            self.isActive = false
            // ===== BEGIN STABILITY-LOCKED: LiveActivity cooldown (do not edit) =====
            lastEndAt = Date()
            // ===== END STABILITY-LOCKED =====
            // hasLiveActivity is computed from actual activity state, no need to set it
            
            // Cancel any pending retry tasks
            retryStartTask?.cancel()
            retryStartTask = nil
            recentStartAt = nil
            
            // Clear the actor's stale pointer and reset first-push throttle
            await ActivityCoordinator.shared.stopIfNeeded()
            Self.didForceFirstPushThisSession = false
            self.lastPush = nil
            self.lastPushedMinutes = nil

            addToAppLogs("🛑 Activity ended - source: \(src)") // canonical per spec
            
            // Debug: dump activities after end
            dumpActivities("afterEnd")
            
            // Post-end diagnostic
            addToAppLogs("🧪 post-end activities: \(Activity<PETLLiveActivityExtensionAttributes>.activities.map{ $0.id }.joined(separator: ","))")
        }
        cancelFailsafeTask()
    }
    
    // MARK: - Helper Methods
    
    private func firstContent() -> PETLLiveActivityExtensionAttributes.ContentState {
        let level = Double(UIDevice.current.batteryLevel) // 0.0—1.0
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full

        // Initialize DI with presented values (not raw)
        let rawETA = ChargeEstimator.shared.current?.minutesToFull
        let rawW = BatteryTrackingManager.shared.currentWatts
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        
        let token = BatteryTrackingManager.shared.tickToken
        let initialEta = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarm, tickToken: token).minutes
            : rawETA
        
        let (label, _) = ChargingAnalytics.chargingCharacteristic(pctPerMinute: ChargeEstimator.shared.current?.pctPerMin)

        return PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Float(level),
            isCharging: isCharging,
            chargingRate: label,
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: initialEta ?? 0,
            deviceModel: getDeviceModel(),
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
    }
    

    
    private func updateWithCurrentBatteryData() {
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        // Use presented values (not raw)
        let rawETA = ChargeEstimator.shared.current?.minutesToFull
        let rawW = BatteryTrackingManager.shared.currentWatts
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        
        let token = BatteryTrackingManager.shared.tickToken
        let displayedETA = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarm, tickToken: token).minutes
            : rawETA
        
        let (label, _) = ChargingAnalytics.chargingCharacteristic(pctPerMinute: ChargeEstimator.shared.current?.pctPerMin)
        
        let contentState = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            chargingRate: label,
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: displayedETA ?? 0,
            deviceModel: getDeviceModel(),
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
        
        // Update all activities immediately
        Task { @MainActor in
            for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
                await activity.update(using: contentState)
            }
            os_log("✅ Live Activity updated with current battery data")
        }
    }
    
    private func ensureBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }
    
    private func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.petl.liveactivity.cleanup",
            using: nil
        ) { task in
            self.handleFailsafeTask(task as! BGProcessingTask)
        }
        
        os_log("✅ Background task registered")
    }
    
    private func handleFailsafeTask(_ task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        endAll("failsafe")
        task.setTaskCompleted(success: true)
    }
    
    private func scheduleFailsafeEnd(after seconds: TimeInterval) {
        let request = BGProcessingTaskRequest(identifier: "com.petl.liveactivity.cleanup")
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            os_log("✅ Failsafe task scheduled for %.0f seconds", seconds)
        } catch {
            os_log("❌ Failed to schedule failsafe task: %@", error.localizedDescription)
        }
    }
    
    private func cancelFailsafeTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.petl.liveactivity.cleanup")
    }
    
    private func uploadPushToken(_ token: Data?) {
        guard let token = token else {
            os_log("❌ No push token available")
            return
        }
        
        let hex = token.map { String(format: "%02hhx", $0) }.joined()
        os_log("📤 Uploading push token: %@", hex)
        
        // Store the push token for Live Activity updates
        // OneSignal automatically handles push token management
        // This token is used for server-side Live Activity control
        UserDefaults.standard.set(hex, forKey: "live_activity_push_token")
        
        // Log token for debugging and server integration
        addToAppLogs("📤 Live Activity Push Token: \(hex.prefix(20))...")
        print("📤 Live Activity Push Token: \(hex)")
        
        // Note: OneSignal handles the actual server communication
        // This token can be used by your server to send Live Activity updates
        // via OneSignal's Live Activity API
    }
    
    /// Retrieves the stored push token for server-side Live Activity updates
    func getStoredPushToken() -> String? {
        return UserDefaults.standard.string(forKey: "live_activity_push_token")
    }
    
    /// Checks if a valid push token is available for Live Activity updates
    func hasValidPushToken() -> Bool {
        guard let token = getStoredPushToken() else { return false }
        return token.count == 64 && token.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
    }
    
    private func persist(charging: Bool) {
        UserDefaults.standard.set(charging, forKey: "last_charging_state")
        os_log("💾 Persisted charging state: %@", charging ? "true" : "false")
    }
    
    private func restorePersistedChargingState() {
        let wasCharging = UserDefaults.standard.bool(forKey: "last_charging_state")
        let isCurrentlyCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        if wasCharging && !isCurrentlyCharging {
            // State mismatch - clean up
            os_log("🔄 State mismatch detected - cleaning up")
            endAll("state cleanup")
        }
    }
    
    // MARK: - Debug Helper
    
    func dumpActivities(_ tag: String) {
        let list = Activity<PETLLiveActivityExtensionAttributes>.activities
        print("💬 \(tag) — \(list.count) activities")
        list.forEach { print("   · \($0.id)  \(String(describing: $0.activityState))") }
    }
    
    private func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        
        // Map to readable names
        let deviceNames: [String: String] = [
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,3": "iPhone 16",
            "iPhone16,4": "iPhone 16 Plus",
            "iPhone16,5": "iPhone 16 Pro",
            "iPhone16,6": "iPhone 16 Pro Max"
        ]
        
        return deviceNames[identifier] ?? "iPhone"
    }
    
    /// Returns current charging rate in %/minute, or nil if not available
    private func currentPctPerMinuteOrNil() -> Double? {
        // For now, return nil to use warm-up fallback
        // This can be enhanced to get actual rate from BatteryTrackingManager
        return nil
    }
} 