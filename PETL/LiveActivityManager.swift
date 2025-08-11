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
    private var current: Activity<PETLLiveActivityExtensionAttributes>? = nil
    private var isRequesting = false
    
    func startIfNeeded() async -> String? {
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
        
        if current == nil, let existing = Activity<PETLLiveActivityExtensionAttributes>.activities.last {
            current = existing
            print("ℹ️  Rehydrated existing Live Activity id:", existing.id)
            return existing.id
        }
        
        guard UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full else { return nil }
        isRequesting = true
        
        do {
                    let auth = ActivityAuthorizationInfo()
        await MainActor.run {
            addToAppLogs("🔐 areActivitiesEnabled=\(auth.areActivitiesEnabled)")
        }
        
        guard auth.areActivitiesEnabled else {
            await MainActor.run {
                addToAppLogs("🚫 Live Activities disabled at system level")
            }
            return nil
        }
            
            let initialState = await MainActor.run { LiveActivityManager.shared.firstContent() }
            current = try await Activity.request(
                attributes: PETLLiveActivityExtensionAttributes(name: "PETL Charging Activity"),
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
                            addToAppLogs("📡 LiveActivity token len=\(tokenData.count)")
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
                addToAppLogs("❌ Activity.request(.token) failed: \(error.localizedDescription)")
            }
            // Fallback: no push token (card still shows; background updates just won't be remote)
            do {
                let fallbackState = await MainActor.run { LiveActivityManager.shared.firstContent() }
                current = try await Activity.request(
                    attributes: PETLLiveActivityExtensionAttributes(name: "PETL Charging Activity"),
                    content: ActivityContent(state: fallbackState, staleDate: Date().addingTimeInterval(3600)),
                    pushType: nil
                )
                isRequesting = false
                await MainActor.run {
                    addToAppLogs("ℹ️ Started Live Activity without push token (fallback)")
                }
                return current?.id
            } catch {
                isRequesting = false
                await MainActor.run {
                    addToAppLogs("❌ Activity.request(no-push) failed: \(error.localizedDescription)")
                }
                return nil
            }
        }
    }
    
    func stopIfNeeded() async {
        guard let activity = current else { return }
        await activity.end(dismissalPolicy: .immediate)
        current = nil
        print("🛑 Ended Live Activity")
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
        cancellables.forEach { $0.cancel() }
        os_log("📱 LiveActivityManager deinit - cleaned up cancellables")
    }
    
    // MARK: - Private Properties
    private var isActive = false
    private var lastStartAt: Date?
    private var lastEndAt: Date?
    private let minRestartInterval: TimeInterval = 8
    private var forceWarmupNextPush = false
    
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
        dumpActivities("foreground")
        let now = Date()
        if now.timeIntervalSince(lastFGSummaryAt) > 8 {
            logReliabilitySummary("📊 Reliability")
            lastFGSummaryAt = now
        }
        ensureStartedIfChargingNow()
    }
    
    @MainActor
    func stopIfNeeded() async {
        await endAll("external call")
    }
    
    @MainActor
    func endIfActive() async {
        await endAll("charge ended")
    }
    
    @MainActor
    func markNewSession() {
        forceNextPush = true
        lastPush = .distantPast
        lastRichState = nil
        Self.didForceFirstPushThisSession = false
    }
    
    private var didStartThisSession = false
    private var recentStartAt: Date? = nil
    private var retryStartTask: Task<Void, Never>?
    private var forceNextPush = false
    private var lastRichState: PETLLiveActivityExtensionAttributes.ContentState?
    
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
    func updateLiveActivityWithPolicy(state: PETLLiveActivityExtensionAttributes.ContentState) {
        let isForeground = UIApplication.shared.applicationState == .active
        
        if isForeground {
            Task {
                for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
                    await activity.update(using: state)
                }
                addToAppLogs("🔄 Live Activity updated locally (foreground)")
            }
        } else {
            for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
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
                for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
                    await activity.end(dismissalPolicy: .immediate)
                }
                addToAppLogs("🛑 Live Activity ended locally (foreground)")
            }
        } else {
            for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
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
            .sink { [weak self] est in
                guard let self = self else { return }

                let bigDelta = self.lastPushedMinutes.map { abs($0 - (est.minutesToFull ?? 0)) >= 3 } ?? true

                if !Self.didForceFirstPushThisSession {
                    self.updateAllActivities(using: est, force: true)
                    Self.didForceFirstPushThisSession = true
                    self.lastPushedMinutes = est.minutesToFull
                    laLogger.info("⚡ First Live Activity update forced (minutes=\(est.minutesToFull ?? 0))")
                } else if bigDelta {
                    self.updateAllActivities(using: est, force: true)
                    self.lastPushedMinutes = est.minutesToFull
                    laLogger.info("📦 Big delta push (minutes=\(est.minutesToFull ?? 0))")
                } else {
                    self.updateAllActivities(using: est, force: false)
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
                Task { await startIfNeeded() }
            } else {
                osLogger.info("🚫 Remote start ignored (local not charging, seq=\(seq))")
            }

        case "update":
            guard hasLiveActivity else {
                osLogger.info("ℹ️ Remote update ignored (no active activity, seq=\(seq))")
                return
            }
            osLogger.info("🔄 Remote update received (seq=\(seq))")

        case "end":
            if !BatteryTrackingManager.shared.isCharging {
                remoteEndsHonored += 1
                osLogger.info("⏹️ Remote end honored (seq=\(seq))")
                Task { @MainActor in
                    await endAll("OneSignal")
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
                Task { await startIfNeeded() }
            }
        } else {
            endsRequestedLocal += 1
            Task { @MainActor in
                await endAll("local unplug")
                if hasLiveActivity {
                    scheduleEndWatchdog()
                    selfPingsQueued += 1
                    #if DEBUG
                    await OneSignalClient.shared.enqueueSelfEnd(seq: OneSignalClient.shared.bumpSeq())
                    #endif
                }
            }
        }
    }
    #endif

    private func scheduleEndWatchdog() {
        endWatchdogTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let activityCount = Activity<PETLLiveActivityExtensionAttributes>.activities.count
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
    
    private func updateAllActivities(using estimate: ChargeEstimator.ChargeEstimate, force: Bool = false) {
        let now = Date()
        
        let lastETA = lastRichState?.timeToFullMinutes ?? 0
        let currentETA = estimate.minutesToFull ?? 0
        let etaDelta = abs(currentETA - lastETA)
        
        let lastSOC = Double(lastRichState?.batteryLevel ?? 0)
        let currentSOC = estimate.level01
        let socDelta = abs(currentSOC - lastSOC)
        
        let doForce = force || forceNextPush
        let canPush = doForce || 
                     lastPush == nil || 
                     now.timeIntervalSince(lastPush!) >= 60 ||
                     etaDelta >= 2 ||
                     socDelta >= 0.01
        
        guard canPush else { return }

        let rawETA = estimate.minutesToFull ?? 0
        let rawW   = BatteryTrackingManager.shared.currentWatts
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isChg  = BatteryTrackingManager.shared.isCharging
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        let token  = BatteryTrackingManager.shared.tickToken

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

        var etaForDI = displayedETA
        if !isWarm, !forceNextPush, let e = etaForDI, e >= 180, rawW <= 5.0 {
            etaForDI = ETAPresenter.shared.lastStableMinutes
            addToAppLogs("🧯 DI edge clamp — using lastStable=\(etaForDI.map{"\($0)m"} ?? "—")")
        }

        let etaMin = etaForDI ?? 0
        let expectedFullDate = Date().addingTimeInterval(TimeInterval(max(etaMin, 0) * 60))
        
        let state = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Int(estimate.level01 * 100),
            isCharging: isChg,
            chargingRate: ChargingAnalytics.chargingCharacteristic(pctPerMinute: estimate.pctPerMin).0,
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: etaMin,
            expectedFullDate: expectedFullDate,
            deviceModel: DeviceProfileService.shared.profile?.name ?? UIDevice.current.model,
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: estimate.computedAt
        )

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
        let rawETA = analytics.timeToFullMinutes
        let rawW = BatteryTrackingManager.shared.currentWatts
        
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isChg = BatteryTrackingManager.shared.isCharging
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        
        let token = BatteryTrackingManager.shared.tickToken
        let displayedETA = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isChg, isWarmup: isWarm, tickToken: token).minutes
            : rawETA
        
        var etaForDI = displayedETA
        
        if let e = etaForDI, e >= 180, rawW <= 5.0 {
            etaForDI = ETAPresenter.shared.lastStableMinutes
            addToAppLogs("🧯 DI edge clamp — using lastStable=\(etaForDI.map{"\($0)m"} ?? "—")")
        }
        
        let etaMin = etaForDI ?? 0
        let expectedFullDate = Date().addingTimeInterval(TimeInterval(max(etaMin, 0) * 60))
        
        let state = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Int(BatteryTrackingManager.shared.level * 100),
            isCharging: true,
            chargingRate: "Charging",
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: etaMin,
            expectedFullDate: expectedFullDate,
            deviceModel: DeviceProfileService.shared.profile?.name ?? UIDevice.current.model,
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
        
        Task { @MainActor in 
            await pushToAll(state) 
        }
        
        addToAppLogs("📤 DI payload — eta=\(etaForDI.map{"\($0)m"} ?? "—") W=\(String(format:"%.1f", rawW))")
    }
    
    // MARK: - Helpers
    private var hasSystemActive: Bool {
        Activity<PETLLiveActivityExtensionAttributes>.activities.contains {
            $0.activityState == .active
        }
    }
    
    private var hasLiveActivity: Bool {
        for act in Activity<PETLLiveActivityExtensionAttributes>.activities {
            switch act.activityState {
            case .active, .stale: return true
            default: continue
            }
        }
        return false
    }
    
    @MainActor
    private func cleanupDuplicates(keepId: String?) {
        let list = Activity<PETLLiveActivityExtensionAttributes>.activities
        guard list.count > 1 else { return }
        addToAppLogs("🧹 Cleaning up duplicates: \(list.count)")
        for act in list {
            if let keepId, act.id == keepId { continue }
            Task { await act.end(dismissalPolicy: .immediate) }
        }
    }
    
    @MainActor
    func ensureStartedIfChargingNow() {
        let st = UIDevice.current.batteryState
        guard (st == .charging || st == .full), !hasLiveActivity else { return }
        Task { await startIfNeeded() }
    }
    
    @MainActor
    func debugForceStart() async {
        addToAppLogs("🛠️ debugForceStart()")
        do {
            let id = try await Activity.request(
                attributes: PETLLiveActivityExtensionAttributes(name: "PETL Debug"),
                content: ActivityContent(
                    state: firstContent(),
                    staleDate: Date().addingTimeInterval(600)
                ),
                pushType: nil // force local-only; card should still appear
            ).id
            addToAppLogs("✅ debugForceStart created id=\(id.prefix(6))")
        } catch {
            addToAppLogs("❌ debugForceStart failed: \(error.localizedDescription)")
        }
    }
    
    private func updateHasActiveWidget() {
        Task { @MainActor in
            BatteryTrackingManager.shared.hasActiveWidget = hasLiveActivity
        }
    }
    
    @MainActor
    func startIfNeeded() async {
        // 0) Self-heal: if we *think* we're active but the system says otherwise, clear it
        if isActive && !hasLiveActivity {
            laLogger.warning("⚠️ isActive desynced (system has 0). Resetting.")
            isActive = false
        }



        // 1) Cooldown (keep your stability lock)
        if let ended = lastEndAt, Date().timeIntervalSince(ended) < minRestartInterval {
            let remain = Int(minRestartInterval - Date().timeIntervalSince(ended))
            addToAppLogs("⏳ Cooldown — skip start (\(remain)s left)")
            return
        }

        // 2) If the system already has an activity, mark active and bail
        if hasLiveActivity {
            addToAppLogs("ℹ️ System already has a Live Activity — skip start")
            return
        }

        // 3) Hard guard on fresh battery state
        let st = UIDevice.current.batteryState
        guard st == .charging || st == .full else {
            addToAppLogs("ℹ️ Not charging — skip start")
            return
        }

        // 4) Proceed to request via the actor
        let count = Activity<PETLLiveActivityExtensionAttributes>.activities.count
        addToAppLogs("🔍 System activities count before start: \(count)")
        addToAppLogs("🚧 startIfNeeded running…")
        let activityId = await ActivityCoordinator.shared.startIfNeeded()
        if let id = activityId {
            startsSucceeded += 1
            isActive = true
            lastStartAt = Date()
            laLogger.info("🎬 Started Live Activity id: \(id)")
            addToAppLogs("🎬 Started Live Activity")
            cleanupDuplicates(keepId: id)
            dumpActivities("post-start")
            cancelEndWatchdog()
            recentStartAt = Date()
            
            // Schedule background refresh for ongoing updates
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.scheduleRefresh(in: 5) // when session starts
            }
        } else if !hasLiveActivity {
            // Retry once if still charging
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
    func startWarmIfNeeded() async {
        // Make the *first* content act like warmup so it bypasses clamps
        forceWarmupNextPush = true
        await startIfNeeded()
    }
    
    @MainActor
    private func pushToAll(_ state: PETLLiveActivityExtensionAttributes.ContentState) async {
        for activity in Activity<PETLLiveActivityExtensionAttributes>.activities {
            await activity.update(using: state)
        }
        let message = "🔄 push level=\(Int(state.batteryLevel*100)) rate=\(state.chargingRate) time=\(state.timeToFullMinutes) min"
        laLogger.info("\(message)")
    }
    
    @MainActor
    func pushUpdate(reason: String) async {
        guard !Activity<PETLLiveActivityExtensionAttributes>.activities.isEmpty else {
            addToAppLogs("📤 pushUpdate(\(reason)) - no activities to update")
            return
        }
        
        // Check if still charging - if not, end all activities
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        if !isCharging {
            addToAppLogs("🔌 pushUpdate(\(reason)): not charging, ending activities")
            await endAll("not-charging")
            // Cancel background refresh since no activities remain
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.cancelRefresh()
            }
            return
        }
        
        let state = firstContent()
        await pushToAll(state)
        addToAppLogs("📤 pushUpdate(\(reason)) - updated \(Activity<PETLLiveActivityExtensionAttributes>.activities.count) activities")
    }
    
    private func updateAll(with dict: [String: Any]) {
        let etaMin = dict["timeToFullMinutes"] as? Int ?? 0
        let expectedFullDate = Date().addingTimeInterval(TimeInterval(max(etaMin, 0) * 60))
        
        // Use payload time or current time
        let ts = (dict["timestamp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()
        
        let rich = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Int(dict["batteryLevel"] as? Double ?? 0),
            isCharging:   dict["isCharging"]   as? Bool   ?? false,
            chargingRate: dict["chargingRate"] as? String ?? "Standard Charging",
            estimatedWattage: dict["estimatedWattage"] as? String ?? "10W",
            timeToFullMinutes: etaMin,
            expectedFullDate: expectedFullDate,
            deviceModel:  dict["deviceModel"]  as? String ?? "iPhone",
            batteryHealth: dict["batteryHealth"] as? String ?? "Excellent",
            isInWarmUpPeriod: dict["isInWarmUpPeriod"] as? Bool ?? false,
            timestamp: ts
        )

        lastRichState = rich
        Task { @MainActor in await pushToAll(rich) }
    }
    
    @MainActor
    func endAll(_ reason: String) async {
        // Ignore spurious "unplugged" right after a start
        if let ts = lastStartAt, Date().timeIntervalSince(ts) < 3 {
            laLogger.debug("🪫 Ignoring end within 3s of start (flicker)")
            return
        }
        
        // Gate duplicate ends (skip if we ended in the last ~5s) to avoid log spam/races
        if let lastEnd = lastEndAt, Date().timeIntervalSince(lastEnd) < 5 {
            addToAppLogs("🔄 endAll(\(reason)) skipped - ended \(String(format: "%.1f", Date().timeIntervalSince(lastEnd)))s ago")
            return
        }
        
        let activities = Activity<PETLLiveActivityExtensionAttributes>.activities
        addToAppLogs("🧪 endAll(\(reason)) about to end \(activities.count) activity(ies)")

        for act in activities {
            do {
                try await act.end(dismissalPolicy: .immediate)
            } catch {
                addToAppLogs("⚠️ end(\(act.id)) failed: \(error)")
            }
        }

        // Retry until gone (1s, 3s, 7s), then give up
        let backoff: [UInt64] = [1, 3, 7].map { UInt64($0) * 1_000_000_000 }
        for delay in backoff {
            try? await Task.sleep(nanoseconds: delay)
            let remaining = Activity<PETLLiveActivityExtensionAttributes>.activities.count
            addToAppLogs("🧪 endAll() verification: remaining=\(remaining)")
            if remaining == 0 { 
                addToAppLogs("✅ endAll() successful - all activities ended")
                break
            }
        }

        // Failsafe: if still present, push a final "not charging" update and stale it out
        let finalActivities = Activity<PETLLiveActivityExtensionAttributes>.activities
        if !finalActivities.isEmpty {
            addToAppLogs("⚠️ endAll() failsafe: \(finalActivities.count) activities still present, marking as stale")
            
            for act in finalActivities {
                var s = act.content.state
                s.isCharging = false
                s.timeToFullMinutes = 0
                s.expectedFullDate = Date()
                s.timestamp = Date()

                // Mark as stale so the system deprioritizes it immediately
                let content = ActivityContent(state: s, staleDate: Date(), relevanceScore: 0)
                do { 
                    try await act.update(content) 
                    addToAppLogs("✅ Final stale update sent for \(act.id)")
                    // Try ending immediately after stale update
                    try await act.end(dismissalPolicy: .immediate)
                    addToAppLogs("✅ Final end attempt for \(act.id)")
                } catch {
                    addToAppLogs("⚠️ final stale update/end failed for \(act.id): \(error)")
                }
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

        addToAppLogs("🛑 Activity ended - source: \(reason)")
        
        // Cancel background refresh since no activities remain
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.cancelRefresh()
        }
        
        dumpActivities("afterEnd")
        
        addToAppLogs("🧪 post-end activities: \(Activity<PETLLiveActivityExtensionAttributes>.activities.map{ $0.id }.joined(separator: ","))")
    }
    
    private func cancelFailsafeTask() {
        // Implementation for canceling failsafe task
    }
    
    // MARK: - Helper Methods
    func firstContent() -> PETLLiveActivityExtensionAttributes.ContentState {
        let level = Double(UIDevice.current.batteryLevel)
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full

        // Use default values for first content
        let rawETA: Int? = nil
        let rawW = BatteryTrackingManager.shared.currentWatts
        let isWarmFromEstimator = ChargeEstimator.shared.current?.isInWarmup ?? false

        // 🔥 Warmup override just for the first push
        let isWarm = isWarmFromEstimator || forceWarmupNextPush
        if forceWarmupNextPush { forceWarmupNextPush = false }

        let token = BatteryTrackingManager.shared.tickToken
        let initialEta = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(
                rawETA: rawETA,
                watts: rawW,
                sysPct: Int(BatteryTrackingManager.shared.level * 100),
                isCharging: isCharging,
                isWarmup: isWarm,
                tickToken: token
            ).minutes
            : rawETA
        
        let (label, _) = ChargingAnalytics.chargingCharacteristic(pctPerMinute: 1.0) // Default rate

        let etaMin = initialEta ?? 0
        let expectedFullDate = Date().addingTimeInterval(TimeInterval(max(etaMin, 0) * 60))
        
        return PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Int(level * 100),
            isCharging: isCharging,
            chargingRate: label,
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: etaMin,
            expectedFullDate: expectedFullDate,
            deviceModel: DeviceProfileService.shared.profile?.name ?? UIDevice.current.model,
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
    }
    
    private func updateWithCurrentBatteryData() {
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        // Use default values since we don't have access to analytics store here
        let rawETA: Int? = nil
        let rawW = BatteryTrackingManager.shared.currentWatts
        let sysPct = Int(BatteryTrackingManager.shared.level * 100)
        let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false
        
        let token = BatteryTrackingManager.shared.tickToken
        let displayedETA = FeatureFlags.useETAPresenter
            ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarm, tickToken: token).minutes
            : rawETA
        
        let (label, _) = ChargingAnalytics.chargingCharacteristic(pctPerMinute: 1.0) // Default rate
        
        let etaMin = displayedETA ?? 0
        let expectedFullDate = Date().addingTimeInterval(TimeInterval(max(etaMin, 0) * 60))
        
        let contentState = PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: Int(batteryLevel * 100),
            isCharging: isCharging,
            chargingRate: label,
            estimatedWattage: String(format: "%.1fW", rawW),
            timeToFullMinutes: etaMin,
            expectedFullDate: expectedFullDate,
            deviceModel: DeviceProfileService.shared.profile?.name ?? UIDevice.current.model,
            batteryHealth: "Excellent",
            isInWarmUpPeriod: isWarm,
            timestamp: Date()
        )
        
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
        let isCurrentlyCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        if wasCharging && !isCurrentlyCharging {
            os_log("🔄 State mismatch detected - cleaning up")
            Task { @MainActor in
                await endAll("state cleanup")
            }
        }
    }
    
    // MARK: - Debug Helper
    func dumpActivities(_ tag: String) {
        let list = Activity<PETLLiveActivityExtensionAttributes>.activities
        print("💬 \(tag) — \(list.count) activities")
        list.forEach { print("   · \($0.id)  \(String(describing: $0.activityState))") }
    }
    

    
    private func currentPctPerMinuteOrNil() -> Double? {
        return nil
    }
}
