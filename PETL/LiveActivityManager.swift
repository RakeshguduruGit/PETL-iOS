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
#if DEBUG
import OneSignalFramework
#endif

private let laLogger = Logger(subsystem: "com.petl.app", category: "liveactivity")
#if DEBUG
private let osLogger = Logger(subsystem: "com.petl.app", category: "onesignal")
#endif
private let uiLogger = Logger(subsystem: "com.petl.app", category: "ui")

// MARK: - App State Helper
private var isForeground: Bool {
    UIApplication.shared.applicationState == .active
}

// MARK: - Activity Coordinator Actor
actor ActivityCoordinator {
    static let shared = ActivityCoordinator()
    private var current: Activity<PETLLiveActivityAttributes>? = nil
    private var isRequesting = false
    
    func startIfNeeded(reason: String) async -> String? {
        guard !isRequesting else { return nil }
        
        if let cur = current {
            switch cur.activityState {
            case .active, .stale:
                print("ℹ️  startIfNeeded skipped—widget already active.")
                return nil
            default:
                current = nil
            }
        }
        
        if current == nil, let existing = Activity<PETLLiveActivityAttributes>.activities.last {
            current = existing
            print("ℹ️  Rehydrated existing Live Activity id:", existing.id)
            return existing.id
        }
        
        let isCharging = await MainActor.run { ChargeStateStore.shared.isCharging }
        guard isCharging else { return nil }
        isRequesting = true
        
        do {
                    let auth = ActivityAuthorizationInfo()
        await MainActor.run {
            BatteryTrackingManager.shared.addToAppLogs("🔐 areActivitiesEnabled=\(auth.areActivitiesEnabled)")
        }
        
        guard auth.areActivitiesEnabled else {
            await MainActor.run {
                BatteryTrackingManager.shared.addToAppLogs("🚫 Live Activities disabled at system level")
            }
            return nil
        }
            
            let initialState = await LiveActivityManager.shared.firstContent()
            current = try await Activity.request(
                attributes: PETLLiveActivityAttributes(),
                content: ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(3600)),
                pushType: .token
            )
            let activityId = current?.id ?? "unknown"

            // Listen for token & log it (restores your 📡 lines)
            if let activity = current {
                Task { // not detached; keep it tied to our task tree
                    for await tokenData in activity.pushTokenUpdates {
                        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                        await MainActor.run {
                            BatteryTrackingManager.shared.addToAppLogs("📡 LiveActivity token len=\(tokenData.count)")
                        }
                        #if DEBUG
                        await OneSignalClient.shared.enterLiveActivity(activityId: activity.id, tokenHex: hex)
                        #endif
                    }
                }
            }

            isRequesting = false
            return activityId

        } catch {
            await MainActor.run {
                BatteryTrackingManager.shared.addToAppLogs("❌ Activity.request(.token) failed: \(error.localizedDescription)")
            }
            // Fallback: no push token (card still shows; background updates just won't be remote)
            do {
                let fallbackState = await LiveActivityManager.shared.firstContent()
                current = try await Activity.request(
                    attributes: PETLLiveActivityAttributes(),
                    content: ActivityContent(state: fallbackState, staleDate: Date().addingTimeInterval(3600)),
                    pushType: nil
                )
                isRequesting = false
                await MainActor.run {
                    BatteryTrackingManager.shared.addToAppLogs("ℹ️ Started Live Activity without push token (fallback)")
                }
                return current?.id
            } catch {
                isRequesting = false
                await MainActor.run {
                    BatteryTrackingManager.shared.addToAppLogs("❌ Activity.request(no-push) failed: \(error.localizedDescription)")
                }
                return nil
            }
        }
    }
    
    func stopIfNeeded() async {
        guard let activity = current else { return }
        await activity.end(activity.content, dismissalPolicy: .immediate)
        current = nil
        print("🛑 Ended Live Activity")
    }
    

    

}

// MARK: - Live Activity Manager
@MainActor
final class LiveActivityManager {
    
    static let shared = LiveActivityManager()
    
    // Add near top of class
    private var updatesBlocked = false
    
    // Relaxed gating state for periodic LA updates
    private var lastAllowedUpdateAt: Date = .distantPast
    private var lastAllowedWatts: Double = -1
    private var lastAllowedETA: Int = -1
    private let minUpdateInterval: TimeInterval = 30 // seconds
    private let minWattsDelta: Double = 0.5
    private let minEtaDeltaMinutes: Int = 2
    private var lastContentState: PETLLiveActivityAttributes.ContentState?
    
    // ===== BEGIN STABILITY-LOCKED: LA sequencing (do not edit) =====
    private var lastSeq: Int = 0
    // ===== END STABILITY-LOCKED: LA sequencing =====
    
    private static var isConfigured = false
    private static var didForceFirstPushThisSession = false
    
    private init() {}
    
    deinit {
        cancellables.forEach { $0.cancel() }
        os_log("📱 LiveActivityManager deinit - cleaned up cancellables")
    }
    
    // MARK: - Private Properties
    private var isActive = false
    private var lastStartAt: Date?
    private var lastEndAt: Date?
    private let minRestartInterval: TimeInterval = 8
    private var forceWarmupNextPush = false
    
    // MARK: - Activity ID Tracking
    private var currentActivityID: String? // authoritative pointer
    @MainActor private var isEnding = false
    
    // MARK: - Activity Registration
    private func register(_ activity: Activity<PETLLiveActivityAttributes>, reason: String) {
        currentActivityID = activity.id
        addToAppLogs("🧷 Track id=\(String(activity.id.suffix(4))) reason=\(reason)")
        attachObservers(activity)
    }
    
    private func attachObservers(_ activity: Activity<PETLLiveActivityAttributes>) {
        Task.detached { [weak self] in
            for await state in activity.activityStateUpdates {
                await MainActor.run {
                    laLogger.info("📦 state=\(String(describing: state)) id=\(String(activity.id.suffix(4)))")
                }
                // When the system/user ends or dismisses it, forget our pointer.
                switch state {
                case .ended, .dismissed, .stale:
                    await MainActor.run { [weak self] in
                        if self?.currentActivityID == activity.id {
                            self?.currentActivityID = nil
                            laLogger.info("🧹 cleared currentActivityID (state=\(String(describing: state)))")
                        }
                    }
                default:
                    break
                }
            }
        }
    }
    
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
    var lastRemoteSeq: Int = 0
    
    // MARK: - Reliability counters
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
        BatteryTrackingManager.shared.startMonitoring()
        // Self-heal every foreground entry
        if isActive && !hasLiveActivity { isActive = false }
        if hasLiveActivity { isActive = true }
        
        // Reattach to existing activity if charging, otherwise cleanup
        if BatteryTrackingManager.shared.isCharging {
            reattachIfNeeded()
        } else {
            // Startup recovery: if there's any system activity but currentActivityID == nil, call endAll
            let systemActivities = Activity<PETLLiveActivityAttributes>.activities
            if !systemActivities.isEmpty && currentActivityID == nil {
                addToAppLogs("🔄 Startup recovery: \(systemActivities.count) system activities but no tracked ID")
                Task { @MainActor in
                    await endAll("STARTUP-RECOVERY")
                }
            }
        }
        
        dumpActivities("foreground")
        let now = Date()
        if now.timeIntervalSince(lastFGSummaryAt) > 8 {
            logReliabilitySummary("📊 Reliability")
            lastFGSummaryAt = now
        }
        ensureStartedIfChargingNow()
    }
    
    @MainActor
    func reattachIfNeeded() {
        guard currentActivityID == nil else { return }
        // if exactly one PETL activity exists, adopt it; if many, pick the most recent
        if let a = Activity<PETLLiveActivityAttributes>.activities.last {
            currentActivityID = a.id
            BatteryTrackingManager.shared.addToAppLogsCritical("🧷 Reattached active id=\(String(a.id.suffix(4))) on launch")
        }
    }
    
    @MainActor
    func stopIfNeeded() async {
        await endActive("external call")
    }
    
    @MainActor
    func endIfActive() async {
        await endActive("charge ended")
    }
    
    @MainActor
    func markNewSession() {
        forceNextPush = true
        lastPush = .distantPast
        lastRichState = nil
        Self.didForceFirstPushThisSession = false
        // ===== BEGIN STABILITY-LOCKED: LA sequencing reset (do not edit) =====
        lastSeq = 0
        lastRemoteSeq = 0
        // ===== END STABILITY-LOCKED: LA sequencing reset =====
    }
    
    private var didStartThisSession = false
    private var recentStartAt: Date? = nil
    private var retryStartTask: Task<Void, Never>?
    private var forceNextPush = false
    private var lastRichState: PETLLiveActivityAttributes.ContentState?
    
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
    
    // MARK: - Update Policy
    @MainActor
    func updateLiveActivityWithPolicy(state: PETLLiveActivityAttributes.ContentState) {
        let isForeground = UIApplication.shared.applicationState == .active
        
        if isForeground {
            Task {
                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    await activity.update(using: state)
                }
                addToAppLogs("🔄 Live Activity updated locally (foreground)")
            }
        } else {
            for activity in Activity<PETLLiveActivityAttributes>.activities {
                #if DEBUG
                OneSignalClient.shared.updateLiveActivityRemote(activityId: activity.id, state: state)
                #endif
            }
            addToAppLogs("📡 Live Activity update queued remotely (background)")
        }
    }
    
    @MainActor
    func endLiveActivityWithPolicy() {
        let isForeground = UIApplication.shared.applicationState == .active
        
        if isForeground {
            Task {
                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    await activity.end(activity.content, dismissalPolicy: .immediate)
                }
                addToAppLogs("🛑 Live Activity ended locally (foreground)")
            }
        } else {
            for activity in Activity<PETLLiveActivityAttributes>.activities {
                #if DEBUG
                OneSignalClient.shared.endLiveActivityRemote(activityId: activity.id)
                #endif
            }
            addToAppLogs("📡 Live Activity end queued remotely (background)")
        }
    }
    
    // MARK: - Public API
    func configure() {
        guard !Self.isConfigured else { return }
        Self.isConfigured = true
        laLogger.info("🔧 LiveActivityManager configured")

        BatteryTrackingManager.shared.startMonitoring()

        ChargeEstimator.shared.estimateSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }

                let bigDelta = self.lastPushedMinutes.map { abs($0 - (ChargeStateStore.shared.currentETAMinutes ?? 0)) >= 3 } ?? true

                if !Self.didForceFirstPushThisSession {
                    self.updateAllActivities(force: true)
                    Self.didForceFirstPushThisSession = true
                    self.lastPushedMinutes = ChargeStateStore.shared.currentETAMinutes
                    laLogger.info("⚡ First Live Activity update forced (minutes=\(ChargeStateStore.shared.currentETAMinutes ?? 0))")
                } else if bigDelta {
                    self.updateAllActivities(force: true)
                    self.lastPushedMinutes = ChargeStateStore.shared.currentETAMinutes
                    laLogger.info("📦 Big delta push (minutes=\(ChargeStateStore.shared.currentETAMinutes ?? 0))")
                } else {
                    self.updateAllActivities(force: false)
                }
            }
            .store(in: &cancellables)

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
        
        // Authorization sanity check
        let info = ActivityAuthorizationInfo()
        addToAppLogs("🔐 LA perms — enabled=\(info.areActivitiesEnabled)")
        
        // Sync in-memory flag with system on cold start
        self.isActive = self.hasLiveActivity
        self.dumpActivities("after configure")
        self.ensureStartedIfChargingNow()
    }
    
    #if DEBUG
    func handleRemotePayload(_ json: [AnyHashable: Any]) {
        // Sequence guard: ignore duplicates/out-of-order payloads
        if let seqAny = json["seq"],
           let seq = (seqAny as? Int) ?? Int((seqAny as? String) ?? "") {
            if seq <= lastSeq {
                addToAppLogs("↪️ Drop LA payload (seq=\(seq) <= lastSeq=\(lastSeq))")
                return
            }
            lastSeq = seq
        }
        
        // Optional: Filter sim payloads to keep LA clean
        if json["simWatts"] != nil {
            addToAppLogs("↪️ Drop LA payload — simWatts present")
            return
        }
        
        // 1. Parse watts and ETA from payload
        let payloadWatts: Double = {
            if let w = json["watts"] as? Double { return w }
            if let s = json["watts"] as? String, let v = Double(s) { return v }
            if let v = json["simWatts"] as? Double { return v } // optional alt
            return 0.0
        }()

        let payloadEtaMinutes: Int = {
            if let e = json["timeToFullMinutes"] as? Int { return e }
            if let s = json["timeToFullMinutes"] as? String, let v = Int(s) { return v }
            return 0
        }()

        // 2. Relaxed gate: allow update if meaningful change or periodic time has passed
        let now = Date()
        let etaMinutes = max(0, payloadEtaMinutes)
        let wattsValue = max(0.0, payloadWatts)
        let timeOK = now.timeIntervalSince(lastAllowedUpdateAt) >= minUpdateInterval
        let wattsOK = abs(wattsValue - lastAllowedWatts) >= minWattsDelta
        let etaOK = abs(etaMinutes - lastAllowedETA) >= minEtaDeltaMinutes

        if !(timeOK || wattsOK || etaOK) {
            addToAppLogs("🚫 Ignoring remote payload — LA updates blocked (dt=\(Int(now.timeIntervalSince(lastAllowedUpdateAt)))s, dW=\(String(format: "%.1f", abs(wattsValue - lastAllowedWatts)))W, dETA=\(abs(etaMinutes - lastAllowedETA))m)")
            return
        }

        // Passing gate — record and proceed
        lastAllowedUpdateAt = now
        lastAllowedWatts = wattsValue
        lastAllowedETA = etaMinutes
        
        // Sanitize zeros while charging by falling back to last known values
        let chargingNow = ChargeStateStore.shared.isCharging
        var wattsForUpdate = max(0.0, payloadWatts)
        var etaForUpdate   = max(0,    payloadEtaMinutes)
        if chargingNow {
            if wattsForUpdate == 0, let last = lastContentState { wattsForUpdate = max(last.watts, 5.0) }
            if etaForUpdate   == 0, let last = lastContentState { etaForUpdate   = max(last.timeToFullMinutes, 1) }
        }
        // Clamp ETA increases (allow decreases freely)
        if let prevETA = lastContentState?.timeToFullMinutes, etaForUpdate > prevETA {
            etaForUpdate = min(prevETA + 2, etaForUpdate)
        }
        addToAppLogs("🟦 LA update allowed — watts=\(String(format: "%.1f", wattsForUpdate))W eta=\(etaForUpdate)m")
        
        guard let action = json["live_activity_action"] as? String else { return }
        let seq = (json["seq"] as? Int) ?? 0

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
                Task { 
                    await self.startActivity(reason: .snapshot)
                }
            } else {
                osLogger.info("🚫 Remote start ignored (local not charging, seq=\(seq))")
            }

        case "update":
            guard hasLiveActivity else {
                osLogger.info("ℹ️ Remote update ignored (no active activity, seq=\(seq))")
                return
            }
            osLogger.info("🔄 Remote update received (seq=\(seq))")
            
            // Build content state from sanitized values
            let contentState = PETLLiveActivityAttributes.ContentState(
                soc: ChargeStateStore.shared.currentBatteryLevel,
                watts: wattsForUpdate,
                updatedAt: Date(),
                isCharging: chargingNow,
                timeToFullMinutes: etaForUpdate,
                expectedFullDate: Date().addingTimeInterval(Double(etaForUpdate * 60)),
                chargingRate: String(format: "%.1fW", wattsForUpdate),
                batteryLevel: Int(Double(ChargeStateStore.shared.currentBatteryLevel) / 100.0),
                estimatedWattage: String(format: "%.1fW", wattsForUpdate)
            )
            
            // Update Live Activity
            let isForeground = UIApplication.shared.applicationState == .active
            if isForeground {
                Task {
                    for activity in Activity<PETLLiveActivityAttributes>.activities {
                        await activity.update(using: contentState)
                    }
                }
            } else {
                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    #if DEBUG
                    OneSignalClient.shared.updateLiveActivityRemote(activityId: activity.id, state: contentState)
                    #endif
                }
            }
            
            // Persist the state we just sent
            self.lastContentState = contentState

        case "end":
            if !BatteryTrackingManager.shared.isCharging {
                remoteEndsHonored += 1
                osLogger.info("⏹️ Remote end honored (seq=\(seq))")
                Task { @MainActor in
                    await endAll("server-push-unplugged")
                }
            } else {
                remoteEndsIgnored += 1
                osLogger.info("🚫 Remote end ignored (local charging, seq=\(seq))")
            }

        default: break
        }
    }
    
    // MARK: - Private Methods
    private func handle(snapshot s: BatterySnapshot) {
        if s.isCharging {
            startsRequested += 1
            if !hasLiveActivity {
                Task { 
                    await self.startActivity(reason: .snapshot)
                }
            }
        } else {
            // Note: Unplug handling is now done by the bullet-proof debounce system in BatteryTrackingManager
            // No direct endAll calls here to avoid race conditions
        }
    }
    #endif

    private func scheduleEndWatchdog() {
        endWatchdogTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let activityCount = Activity<PETLLiveActivityAttributes>.activities.count
            if self.hasLiveActivity && activityCount > 0 {
                self.watchdogFires += 1
                addToAppLogs("⏱️ End watchdog fired; \(activityCount) activity(ies) still present, enqueueing final end self-ping")
                #if DEBUG
                OneSignalClient.shared.enqueueSelfEnd(seq: OneSignalClient.shared.bumpSeq())
                #endif
            }
        }
        endWatchdogTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + QA.watchdogSeconds, execute: item)
    }

    private func cancelEndWatchdog() {
        endWatchdogTimer?.cancel()
        endWatchdogTimer = nil
    }
    
    private func updateAllActivities(force: Bool = false) {
        let now = Date()
        
        // Get current snapshot
        let snapshot = ChargeStateStore.shared.snapshot
        
        let lastETA = lastRichState?.timeToFullMinutes ?? 0
        let currentETA = snapshot.etaMinutes ?? 0
        let etaDelta = abs(currentETA - lastETA)
        
        let lastSOC = Double(lastRichState?.batteryLevel ?? 0)
        let currentSOC = Double(snapshot.socPercent) / 100.0
        let socDelta = abs(currentSOC - lastSOC)
        
        let doForce = force || forceNextPush
        let canPush = doForce || 
                     lastPush == nil || 
                     now.timeIntervalSince(lastPush!) >= 60 ||
                     etaDelta >= 2 ||
                     socDelta >= 0.01
        
        guard canPush else { return }

        // Use SSOT mapper to build content state
        let state = SnapshotToLiveActivity.makeContent(from: snapshot)

        updateLiveActivityWithPolicy(state: state)
        
        lastRichState = state
        lastPush = now
        forceNextPush = false
    }
    
    @MainActor
    func updateIfNeeded(from snapshot: BatterySnapshot) {
        // Deprecated: start/stop is centralized in BatteryTrackingManager
    }
    
    func publishLiveActivityAnalytics(_ analytics: ChargingAnalyticsStore) {
        // Use SSOT store for all data
        let snapshot = ChargeStateStore.shared.snapshot
        let state = SnapshotToLiveActivity.makeContent(from: snapshot)
        
        Task { @MainActor in 
            await pushToAll(state) 
        }
        
        addToAppLogs("📤 DI payload — eta=\(snapshot.etaMinutes.map{"\($0)m"} ?? "—") W=\(snapshot.watts.map{String(format:"%.1f", $0)} ?? "—")")
    }
    
    // MARK: - Helpers
    private var hasSystemActive: Bool {
        Activity<PETLLiveActivityAttributes>.activities.contains {
            $0.activityState == .active
        }
    }
    
    private var hasLiveActivity: Bool {
        for act in Activity<PETLLiveActivityAttributes>.activities {
            switch act.activityState {
            case .active, .stale: return true
            default: continue
            }
        }
        return false
    }
    
    @MainActor
    private func cleanupDuplicates(keepId: String?) {
        let list = Activity<PETLLiveActivityAttributes>.activities
        guard list.count > 1 else { return }
        addToAppLogs("🧹 Cleaning up duplicates: \(list.count)")
        for act in list {
            if let keepId, act.id == keepId { continue }
            Task { await act.end(act.content, dismissalPolicy: .immediate) }
        }
    }
    
    @MainActor
    func ensureStartedIfChargingNow() {
        guard ChargeStateStore.shared.isCharging, !hasLiveActivity else { return }
        Task { 
            await self.startActivity(reason: .launch)
        }
    }
    
    @MainActor
    func debugForceStart() async {
        addToAppLogs("🛠️ debugForceStart()")
        await startActivity(reason: .debug)
    }
    
    private func updateHasActiveWidget() {
        Task { @MainActor in
            BatteryTrackingManager.shared.hasActiveWidget = hasLiveActivity
        }
    }
    
    @MainActor
    func startIfNeeded() async {
        await startActivity(reason: .chargeBegin)
    }
    
    // MARK: - Unified Start

    @MainActor
    private func startActivity(seed seededMinutes: Int, sysPct: Int, reason: LAStartReason) {
        addToAppLogs("🧵 startActivity(seed) reason=\(reason.rawValue) mainThread=\(Thread.isMainThread) seed=\(seededMinutes) sysPct=\(sysPct)")

        let auth = ActivityAuthorizationInfo()
        if auth.areActivitiesEnabled == false {
            addToAppLogs("🚫 Skip start — LIVE-ACTIVITIES-DISABLED")
            return
        }

        let before = Activity<PETLLiveActivityAttributes>.activities.count
        addToAppLogs("🔍 System activities count before start: \(before)")
        if before > 0 {
            addToAppLogs("⏭️ Skip start — ALREADY-ACTIVE")
            return
        }

        let minutes = max(seededMinutes, ChargeStateStore.shared.currentETAMinutes ?? 0)
        addToAppLogs("⛽️ seed-\(minutes) sysPct=\(sysPct)")

        let attrs = PETLLiveActivityAttributes()
        // Use SSOT mapper to build content state
        let snapshot = ChargingSnapshot(
            ts: Date(),
            socPercent: sysPct,
            state: ChargingState.charging,
            watts: ChargeStateStore.shared.currentWatts,
            ratePctPerMin: ChargeStateStore.shared.currentRatePctPerMin,
            etaMinutes: minutes,
            device: ChargeStateStore.shared.currentDevice
        )
        let state = SnapshotToLiveActivity.makeContent(from: snapshot)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))

        // Try with push token first; if it fails, fallback to no-push.
        do {
            let activity = try Activity<PETLLiveActivityAttributes>.request(attributes: attrs, content: content, pushType: .token)
            BatteryTrackingManager.shared.addToAppLogsCritical("🎬 Started Live Activity id=\(String(activity.id.suffix(4))) reason=\(reason.rawValue) (push=on)")
            register(activity, reason: reason.rawValue)
            observePushToken(activity) // safe logger capture below
        } catch {
            // If the only problem is foreground, defer instead of fallback
            let nsErr = error as NSError
            if nsErr.localizedDescription.localizedCaseInsensitiveContains("foreground") {
                BatteryTrackingManager.shared.addToAppLogsCritical("🕒 Deferring start — app not foreground (reason=\(reason.rawValue))")
                AppForegroundGate.shared.runWhenActive(reason: reason) { [weak self] in
                    Task { @MainActor in await self?.startActivity(reason: reason) }
                }
                return
            }

            BatteryTrackingManager.shared.addToAppLogsCritical("⚠️ Push start failed (\(nsErr.localizedDescription)) — falling back to no-push")
            do {
                let activity = try Activity<PETLLiveActivityAttributes>.request(attributes: attrs, content: content)
                BatteryTrackingManager.shared.addToAppLogsCritical("🎬 Started Live Activity id=\(String(activity.id.suffix(4))) reason=\(reason.rawValue) (push=off)")
                register(activity, reason: reason.rawValue)
            } catch {
                BatteryTrackingManager.shared.addToAppLogsCritical("❌ Start failed (no-push): \(error.localizedDescription)")
                return
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            let after = Activity<PETLLiveActivityAttributes>.activities.count
            BatteryTrackingManager.shared.addToAppLogsCritical("✅ post-request system count=\(after) tracked=\(String(currentActivityID?.suffix(4) ?? "nil"))")
        }
    }

    // Capture logger outside the Task to avoid actor mistakes.
    private func observePushToken(_ activity: Activity<PETLLiveActivityAttributes>) {
        Task.detached {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    addToAppLogs("📡 LiveActivity token len=\(hex.count)")
                }
            }
        }
    }

    // Wrapper that computes seed/sysPct then delegates
@MainActor
func startActivity(reason: LAStartReason) async {
    // 0) Thrash guard to prevent back-to-back starts
    if let t = lastStartAt, Date().timeIntervalSince(t) < 2 {
        BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — THRASH-GUARD (<2s since last)")
        return
    }

    // 1) Self-heal: if we *think* we're active but the system says otherwise, clear it
    if isActive && !hasLiveActivity {
        laLogger.warning("⚠️ isActive desynced (system has 0). Resetting.")
        isActive = false
    }

    // 2) Cooldown (keep your stability lock)
    if let ended = lastEndAt, Date().timeIntervalSince(ended) < minRestartInterval {
        let remain = Int(minRestartInterval - Date().timeIntervalSince(ended))
        BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — COOLDOWN (\(remain)s left)")
        return
    }

    // 3) If the system already has an activity, mark active and bail
    if hasLiveActivity {
        BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — ALREADY-ACTIVE")
        return
    }

    // 4) Hard guard on fresh battery state
    guard ChargeStateStore.shared.isCharging else {
        BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — NOT-CHARGING")
        return
    }

    // 5) Foreground gate
    if AppForegroundGate.shared.isActive == false {
        BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — NOT-FOREGROUND (deferring \(reason.rawValue))")
        AppForegroundGate.shared.runWhenActive(reason: reason) { [weak self] in
            Task { @MainActor in
                // recheck minimal thrash guard if you want
                await self?.startActivity(reason: reason)
            }
        }
        return
    }

    // 6) Call the unified start method
    let sysPct = ChargeStateStore.shared.currentBatteryLevel
    let seed = ChargeStateStore.shared.currentETAMinutes ?? 0
    BatteryTrackingManager.shared.addToAppLogsCritical("➡️ delegating to seeded start reason=\(reason.rawValue)")
    lastStartAt = Date()
    startActivity(seed: seed, sysPct: sysPct, reason: reason)
    
    // 6) Update state after successful start
    if hasLiveActivity {
        startsSucceeded += 1
        isActive = true
        lastStartAt = Date()  // Set for thrash guard
        cleanupDuplicates(keepId: Activity<PETLLiveActivityAttributes>.activities.first?.id ?? "")
        dumpActivities("post-start")
        cancelEndWatchdog()
        recentStartAt = Date()
        
        // Schedule background refresh for ongoing updates
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.scheduleRefresh(in: 5) // when session starts
            appDelegate.scheduleProcessing(in: 10) // longer windows when plugged in
        }
    }
}
    
    @MainActor
    func startWarmIfNeeded() async {
        // Make the *first* content act like warmup so it bypasses clamps
        forceWarmupNextPush = true
        await startActivity(reason: .chargeBegin)
    }
    
    @MainActor
    private func pushToAll(_ state: PETLLiveActivityAttributes.ContentState) async {
        if updatesBlocked {
            addToAppLogs("🚫 LA update blocked (already ended)")
            return
        }
        
        // Defensive end: if effectively complete, end to avoid "counting up"
        if state.timeToFullMinutes <= 1 {
            updatesBlocked = true
            addToAppLogs("🏁 LA final state detected (≤1m) — ending now")
            #if canImport(ActivityKit)
            for activity in Activity<PETLLiveActivityAttributes>.activities {
                let final = PETLLiveActivityAttributes.ContentState(
                    soc: state.soc,
                    watts: 0.0,
                    updatedAt: Date(),
                    isCharging: false,
                    timeToFullMinutes: 0,
                    expectedFullDate: Date(),
                    chargingRate: "0.0W",
                    batteryLevel: state.batteryLevel,
                    estimatedWattage: "0.0W"
                )
                await activity.update(using: final)
                await activity.end(activity.content, dismissalPolicy: .immediate)
                addToAppLogs("✅ LA end OK id=\(activity.id.prefix(6))")
            }
            #endif
            return
        }
        
        for activity in Activity<PETLLiveActivityAttributes>.activities {
            await activity.update(using: state)
        }
        self.lastContentState = state
        let message = "🔄 push level=\(Int(state.batteryLevel*100)) rate=\(state.chargingRate) time=\(state.timeToFullMinutes) min"
        laLogger.info("\(message)")
    }
    
    @MainActor
    func pushUpdate(reason: String) async {
        guard !Activity<PETLLiveActivityAttributes>.activities.isEmpty else {
            addToAppLogs("📤 pushUpdate(\(reason)) - no activities to update")
            return
        }
        
        // Check if still charging - if not, end all activities
        let isCharging = ChargeStateStore.shared.isCharging
        if !isCharging {
            addToAppLogs("🔌 pushUpdate(\(reason)): not charging, ending activities")
            await endAll("not-charging")
            // Cancel background refresh since no activities remain
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.cancelRefresh()
                appDelegate.cancelProcessing()
            }
            return
        }
        
        let state = firstContent()
        await pushToAll(state)
        addToAppLogs("📤 pushUpdate(\(reason)) - updated \(Activity<PETLLiveActivityAttributes>.activities.count) activities")
    }
    
    private func updateAll(with dict: [String: Any]) {
        // Create a snapshot from the dictionary data
        let deviceProfile = DeviceProfile(
            rawIdentifier: dict["deviceModel"] as? String ?? "iPhone",
            name: "Unknown Device",
            capacitymAh: 3000,
            chip: nil
        )
        
        let snapshot = ChargingSnapshot(
            ts: (dict["timestamp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date(),
            socPercent: Int(dict["batteryLevel"] as? Double ?? 0),
            state: (dict["isCharging"] as? Bool ?? false) ? ChargingState.charging : ChargingState.unplugged,
            watts: nil, // Not available in dict
            ratePctPerMin: nil, // Not available in dict
            etaMinutes: dict["timeToFullMinutes"] as? Int,
            device: deviceProfile
        )
        
        let rich = SnapshotToLiveActivity.makeContent(from: snapshot)

        lastRichState = rich
        Task { @MainActor in await pushToAll(rich) }
    }
    
    @MainActor
    func endActive(_ reason: String) async {
        if isEnding {
            BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip end — already ending")
            return
        }
        isEnding = true
        defer { isEnding = false }

        if let id = currentActivityID,
           let a = Activity<PETLLiveActivityAttributes>.activities.first(where: { $0.id == id }) {
            BatteryTrackingManager.shared.addToAppLogsCritical("🧪 endActive(\(reason)) id=\(String(id.suffix(4)))")
            await a.end(a.content, dismissalPolicy: .immediate)
            BatteryTrackingManager.shared.addToAppLogsCritical("✅ end done id=\(String(id.suffix(4)))")
            // clear pointer if gone
            if Activity<PETLLiveActivityAttributes>.activities.first(where: { $0.id == id }) == nil {
                currentActivityID = nil
            }
        } else {
            await endAll("FALLBACK-\(reason)")
        }
    }
    
    @MainActor
    func endAll(_ reason: String) async {
        addToAppLogs("🧯 Ending all Live Activities — reason=\(reason)")
        updatesBlocked = true
        #if canImport(ActivityKit)
        for activity in Activity<PETLLiveActivityAttributes>.activities {
            let final = PETLLiveActivityAttributes.ContentState(
                soc: 0,
                watts: 0.0,
                updatedAt: Date(),
                isCharging: false,
                timeToFullMinutes: 0,
                expectedFullDate: Date(),
                chargingRate: "0.0W",
                batteryLevel: 0,
                estimatedWattage: "0.0W"
            )
            await activity.update(using: final)
            await activity.end(activity.content, dismissalPolicy: .immediate)
            addToAppLogs("✅ LA end OK id=\(activity.id.prefix(6))")
        }
        #endif

        // Retry until gone (1s, 3s, 7s), then give up
        let backoff: [UInt64] = [1, 3, 7].map { UInt64($0) * 1_000_000_000 }
        for delay in backoff {
            try? await Task.sleep(nanoseconds: delay)
            let remaining = Activity<PETLLiveActivityAttributes>.activities.count
            addToAppLogs("🧪 endAll() verification: remaining=\(remaining)")
            if remaining == 0 {
                addToAppLogs("✅ endAll() successful - all activities ended")
                break
            }
        }

        // Failsafe: if still present, push a final "not charging" update and stale it out
        let finalActivities = Activity<PETLLiveActivityAttributes>.activities
        if !finalActivities.isEmpty {
            addToAppLogs("⚠️ endAll() failsafe: \(finalActivities.count) activities still present, marking as stale")
            for act in finalActivities {
                var s = act.content.state
                s.isCharging = false
                s.timeToFullMinutes = 0
                s.expectedFullDate = Date()
                // Mark as stale so the system deprioritizes it immediately
                let content = ActivityContent(state: s, staleDate: Date(), relevanceScore: 0)
                await act.update(using: s)
                addToAppLogs("✅ Final stale update sent for \(act.id)")
                // Try ending immediately after stale update
                await act.end(content, dismissalPolicy: .immediate)
                addToAppLogs("✅ Final end attempt for \(act.id)")
            }
        }

        self.didStartThisSession = false
        self.isActive = false
        lastEndAt = Date()

        retryStartTask?.cancel()
        retryStartTask = nil
        recentStartAt = nil

        await ActivityCoordinator.shared.stopIfNeeded()
        Self.didForceFirstPushThisSession = false
        self.lastPush = nil
        self.lastPushedMinutes = nil
        // ===== BEGIN STABILITY-LOCKED: LA sequencing reset (do not edit) =====
        lastSeq = 0
        lastRemoteSeq = 0
        // ===== END STABILITY-LOCKED: LA sequencing reset =====

        addToAppLogs("🛑 Activity ended - source: \(reason)")

        // Cancel background refresh since no activities remain
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.cancelRefresh()
        }

        dumpActivities("afterEnd")
        addToAppLogs("🧪 post-end activities: \(Activity<PETLLiveActivityAttributes>.activities.map{ $0.id }.joined(separator: ","))")
    }
    
    private func cancelFailsafeTask() {
        // Implementation for canceling failsafe task
    }
    
    // MARK: - Helper Methods
    func firstContent() -> PETLLiveActivityAttributes.ContentState {
        // Use SSOT mapper to get content from current snapshot
        return SnapshotToLiveActivity.currentContent()
    }
    
    private func updateWithCurrentBatteryData() {
        // Use SSOT mapper to get content from current snapshot
        let contentState = SnapshotToLiveActivity.currentContent()
        
        Task { @MainActor in
            for activity in Activity<PETLLiveActivityAttributes>.activities {
                await activity.update(using: contentState)
            }
            os_log("✅ Live Activity updated with SSOT snapshot data")
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
        
        Task { @MainActor in
            await endAll("failsafe")
        }
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
    
    private func uploadPushToken(_ token: Data?) {
        guard let token = token else {
            os_log("❌ No push token available")
            return
        }
        
        let hex = token.map { String(format: "%02hhx", $0) }.joined()
        os_log("📤 Uploading push token: %@", hex)
        
        UserDefaults.standard.set(hex, forKey: "live_activity_push_token")
        
        addToAppLogs("📤 Live Activity Push Token: \(hex.prefix(20))...")
        print("📤 Live Activity Push Token: \(hex)")
    }
    
    func getStoredPushToken() -> String? {
        return UserDefaults.standard.string(forKey: "live_activity_push_token")
    }
    
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
        let isCurrentlyCharging = ChargeStateStore.shared.isCharging
        
        if wasCharging && !isCurrentlyCharging {
            os_log("🔄 State mismatch detected - cleaning up")
            Task { @MainActor in
                await endAll("state cleanup")
            }
        }
    }
    
    // MARK: - Debug Helper
    func dumpActivities(_ tag: String) {
        let list = Activity<PETLLiveActivityAttributes>.activities
        print("💬 \(tag) — \(list.count) activities")
        list.forEach { print("   · \($0.id)  \(String(describing: $0.activityState))") }
    }
    

    
    private func currentPctPerMinuteOrNil() -> Double? {
        return nil
    }
}
