
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

private let laLogger = Logger(subsystem: "com.gopetl.PETL", category: "liveactivity")
private let osLogger = Logger(subsystem: "com.gopetl.PETL", category: "onesignal")
private let uiLogger = Logger(subsystem: "com.gopetl.PETL", category: "ui")

// Debug log gate for this file: hop to MainActor before touching UI log buffer
@inline(__always) private func LA_log(_ message: String) {
    if FeatureFlags.debugConsoleEnabled {
        Task { @MainActor in
            BatteryTrackingManager.shared.addToAppLogs(message)
        }
    }
}


// MARK: - App State Helper
/// Normalize and clamp ETA so DI/LA can never render "1m".
/// This force-calculates minutes immediately and rewrites text/anchor consistently.
/// Rules:
///  - While charging: any computed minutes <= 1 becomes 2.
///  - If minutes are 0 but we have an expectedFullDate, compute from it.
///  - If expectedFullDate is missing or too soon for the minutes, re-anchor to now+minutes.
///  - timeRemainingText is rewritten to "{minutes}m" to avoid stale "1m" strings.
/// Normalize and clamp ETA so DI/LA can never render "1m".
/// Rules:
///  - While charging: any computed minutes <= 1 becomes 2.
///  - If minutes are 0 but we have an expectedFullDate, compute from it.
///  - If expectedFullDate is missing or too soon for the minutes, re-anchor to now+minutes.
///  - timeRemainingText is rewritten to "{minutes}m".
private func normalizeOneMinuteSpike(_ state: inout PETLLiveActivityAttributes.ContentState) {
    guard state.isCharging else { return }
    let now = Date()
    var minutes = state.timeToFullMinutes
    if minutes <= 0, let end = state.expectedFullDate {
        minutes = Int(ceil(end.timeIntervalSince(now) / 60.0))
    }
    if minutes <= 1 { minutes = 2 }
    state.timeToFullMinutes = minutes
    let requiredAnchor = now.addingTimeInterval(TimeInterval(minutes * 60))
    if state.expectedFullDate == nil || state.expectedFullDate! < requiredAnchor {
        state.expectedFullDate = requiredAnchor
    }
    state.timeRemainingText = "\(minutes)m"
}
/// Force LA/DI to render static minutes exactly like in-app (no OS countdown anchors).
private func forceStaticDisplay(_ state: inout PETLLiveActivityAttributes.ContentState) {
    // Never provide an anchor; we own the label.
    state.expectedFullDate = nil

    // Always provide a concrete label (no em-dash) when charging.
    if state.isCharging {
        let m = max(0, state.timeToFullMinutes)
        if m > 0 {
            let h = m / 60, r = m % 60
            state.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
        } else if state.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.timeRemainingText == "—" {
            state.timeRemainingText = "…"
        }
    } else {
        // When unplugged we keep a dash, but never set an anchor.
        state.timeRemainingText = "—"
    }
}
/// Ensure LA/DI display exactly matches in-app SSOT strings.
/// - Clears ETA and expectedFullDate when not charging.
/// - Clamps "1m" to "2m" while charging.
private func normalizeForLiveActivity(_ inState: PETLLiveActivityAttributes.ContentState) -> PETLLiveActivityAttributes.ContentState {
    var state = inState
    if state.isCharging {
        // Never allow a 1m display while charging
        if state.timeToFullMinutes == 1 {
            state.timeToFullMinutes = 2
            if state.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines) == "1m" {
                state.timeRemainingText = "2m"
            }
        }
    } else {
        // When not charging, never show an ETA or power/rate; keep LA/DI in lockstep with app UI.
        state.timeToFullMinutes = 0
        state.timeRemainingText = "—"
        state.estimatedWattage = "—"
        state.chargingRate = "—"
        state.expectedFullDate = nil
    }
    return state
}

/// Canonical minutes + display label for LA/DI.
/// While charging: never show "—". If we don't have a confident minute yet, show "…".
/// Clamp 0/1 → 2 to avoid 1m dips. Unplugged: 0 + "—".
private func computeDisplayMinutes(
    isCharging: Bool,
    rawMinutes: Int?,
    lastGoodMinutes: Int?,
    cachedMinutes: Int?
) -> (minutes: Int, label: String) {
    guard isCharging else { return (0, "—") }
    let candidate = rawMinutes ?? lastGoodMinutes ?? cachedMinutes
    guard let m0 = candidate else { return (2, "…") }
    let m = max(2, m0)
    return (m, "\(m)m")
}

/// Enforce the LA/DI display contract right before pushing UI state.
/// - Ensures minutes/label are consistent and guards the anchor date so the OS cannot "overtake" us.
private func applyDisplayContract(
    _ state: inout PETLLiveActivityAttributes.ContentState,
    lastPushedMinutes: Int?,
    cachedMinutes: Int?
) {
    // 1) Canonical minutes + label
    let (m, label) = computeDisplayMinutes(
        isCharging: state.isCharging,
        rawMinutes: (state.timeToFullMinutes > 0) ? state.timeToFullMinutes : nil,
        lastGoodMinutes: lastPushedMinutes,
        cachedMinutes: (cachedMinutes ?? 0) > 0 ? cachedMinutes : nil
    )
    state.timeToFullMinutes = m
    state.timeRemainingText = label

    // 2) Anchor safety: keep countdown from dipping into 1m between pushes
    if state.isCharging, m > 0 {
        let now = Date()
        let minAnchor = now.addingTimeInterval(Double(m * 60))
        if state.expectedFullDate == nil || state.expectedFullDate! < minAnchor {
            // A tiny headroom keeps OS rendering behind our minutes
            state.expectedFullDate = minAnchor.addingTimeInterval(30)
        }
    } else {
        // Unplugged display contract
        state.expectedFullDate = nil
        state.estimatedWattage = "—"
        state.chargingRate     = "—"
    }

    // 3) Never let "1m" survive while charging (belt & suspenders)
    if state.isCharging && state.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines) == "1m" {
        state.timeRemainingText = "2m"
        state.timeToFullMinutes = max(2, state.timeToFullMinutes)
    }
}
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
            current = try Activity.request(
                attributes: PETLLiveActivityAttributes(),
                content: ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(3600)),
                pushType: .token
            )
            let activityId = current?.id ?? "unknown"

            // Listen for token & log it (restores your 📡 lines)
            if let activity = current {
                Task {
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
                current = try Activity.request(
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
    
    // Prevent duplicate BGTaskScheduler.register() calls (which crash at runtime)
    private static var didRegisterBG = false
    // Thread-safe registration lock to prevent concurrent registrations
    private static let laRegistrationQueue = DispatchQueue(label: "com.gopetl.PETL.la.bgtask.registration", attributes: .concurrent)
    private static var isRegisteringBG = false
    private static let laRegistrationKey = "petl.la.bg.registered" // Persistent registration flag
    // Add near top of class
    private var updatesBlocked = false
    // Battery monitoring double-start guard
    private var didStartMonitoring = false
    
    // Relaxed gating state for periodic LA updates
    private var lastAllowedUpdateAt: Date = .distantPast
    private var lastAllowedWatts: Double = -1
    private var lastAllowedETA: Int = -1
    /// Foreground: allow faster cadence (≥20s). Background: be conservative (≥60s).
    private var minUpdateInterval: TimeInterval {
        let fg = UIApplication.shared.applicationState == .active
        return fg ? max(20, QA.fgSampleSeconds) : 60
    }
    private let minWattsDelta: Double = 0.4
    private var minEtaDeltaMinutes: Int { QA.enabled ? 1 : 2 }
    private var lastContentState: PETLLiveActivityAttributes.ContentState?
    private var lastGoodMetricsAt: Date? = nil
    // Sticky numeric ETA: once we show a number, keep it visible briefly to avoid dash flicker on brief SSOT blips
    private var lastDisplayedMinutes: Int = 0
    private var lastDisplayedAt: Date = .distantPast
    private var stickyMinutesTTL: TimeInterval { return 60 } // seconds
    // Track last background time to clamp DI timer just after backgrounding
    private var lastBackgroundAt: Date? = nil
    /// Within a few seconds of backgrounding, suppress UI minute drops to 0/“—”
    private func inDisplayBGGrace() -> Bool {
        guard let t = lastBackgroundAt else { return false }
        return Date().timeIntervalSince(t) < 20.0
    }
    // Piggyback power DB writes from LA updates (throttled)
    private var lastPowerPiggyAt: Date = .distantPast
    // Warm-start: prefer in-app ETA for first few minutes after LA/DI launches
    private var warmStartUntil: Date? = nil
    private func inWarmStartWindow() -> Bool {
        if let until = warmStartUntil { return Date() < until }
        return false
    }
    private func warmStartMinutesFallback() -> Int {
        // Priority for warm-start ETA (most recent → least recent)
        // 1) Live SSOT ETA (most accurate, real-time)
        if let m = ChargeStateStore.shared.currentETAMinutes, m > 1 {
            addToAppLogsIfEnabled("🟩 Warm-start: using live SSOT ETA=\(m)m")
            return m
        }
        // 2) Last pushed/displayed minutes (recent, known-good)
        if let last = (self.lastPushedDisplayMinutes ?? self.lastPushedMinutes), last > 1 {
            addToAppLogsIfEnabled("🟩 Warm-start: using last pushed ETA=\(last)m")
            return last
        }
        // 3) Cached minutes (may be stale, use with caution)
        let cached = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
        if cached > 1 {
            addToAppLogsIfEnabled("🟩 Warm-start: using cached ETA=\(cached)m")
            return cached
        }
        // 4) Conservative baseline (avoid showing 0m/—)
        addToAppLogsIfEnabled("🟩 Warm-start: using baseline ETA=2m")
        return 2
    }
    
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

    // Ensure LA/DI never regress to older content states
    private var lastPushedContentTimestamp: Date = .distantPast
    
    // MARK: - Activity Registration
    private func register(_ activity: Activity<PETLLiveActivityAttributes>, reason: String) {
        currentActivityID = activity.id
        addToAppLogsIfEnabled("🧷 Track id=\(String(activity.id.suffix(4))) reason=\(reason)")
        attachObservers(activity)
    }
    /// Returns true if we should push an LA update based on time/metric deltas.
    private func shouldAllowUpdate(nextWatts: Double, nextETA: Int, reason: String) -> Bool {
        let now = Date()
        let dtOK = now.timeIntervalSince(lastAllowedUpdateAt) >= minUpdateInterval
        let dW = abs(nextWatts - lastAllowedWatts)
        let dWOK = dW >= minWattsDelta
        // Suppress 1-minute ETA deltas to avoid flicker and spurious cadence triggers
        let rawDE = abs(nextETA - lastAllowedETA)
        let allowOneMin = (reason == "local" || reason == "policy-fg")
        let dE = (rawDE == 1 && !allowOneMin) ? 0 : rawDE
        let dEOK = dE >= minEtaDeltaMinutes
        if !(dtOK || dWOK || dEOK) {
            addToAppLogsIfEnabled("🚫 Gate(\(reason)) — dt=\(Int(now.timeIntervalSince(lastAllowedUpdateAt)))s dW=\(String(format: "%.1f", dW))W dETA=\(dE)m")
            return false
        }
        lastAllowedUpdateAt = now
        lastAllowedWatts = nextWatts
        lastAllowedETA = nextETA
        return true
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
    // MARK: - BG Task Helpers (ensures we always end the task)
    private var laBGTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBG(_ name: String) {
        if laBGTask != .invalid {
            UIApplication.shared.endBackgroundTask(laBGTask)
            laBGTask = .invalid
        }
        laBGTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endBG()
        }
    }

    private func endBG() {
        if laBGTask != .invalid {
            UIApplication.shared.endBackgroundTask(laBGTask)
            laBGTask = .invalid
        }
    }
    
    private var failsafeTask: UIBackgroundTaskIdentifier = .invalid
    private var lastUpdateTime: Date = Date()
    private var lastPush: Date? = nil
    private var lastLevelPct: Int = 0
    private var cancellables = Set<AnyCancellable>()
    private var unplugWorkItem: DispatchWorkItem?
    /// Treat tiny/brief watt readings as noise; require this to consider "charging" true
    private let minChargingWattsThreshold: Double = 0.6
    /// Dynamic debounce for unplug detection: longer in the first few minutes and during BG grace
    private func currentUnplugDebounceSeconds() -> Double {
        let sessionAge = Date().timeIntervalSince(self.sessionStartAt ?? .distantPast)
        // Default 3s, but 5s for the first 5 minutes to avoid early-session flaps
        var seconds: Double = (sessionAge < 300) ? 5.0 : 3.0
        // If we just backgrounded (scene churn), be even more conservative
        if inDisplayBGGrace() { seconds = max(seconds, 6.0) }
        return seconds
    }
    private var chargingStartTime: Date?
    private var totalChargingTime: TimeInterval = 0
    private var lastPushedMinutes: Int?
    /// Last ETA (minutes) that we actually displayed (already mapped by SnapshotToLiveActivity)
    private var lastPushedDisplayMinutes: Int? = nil
    private var endWatchdogTimer: DispatchWorkItem?
    var lastRemoteSeq: Int = 0
    // MARK: - BG Task Ids & Scheduling State
    private let refreshTaskId = "com.gopetl.PETL.liveactivity.refresh"
    private let processingTaskId = "com.gopetl.PETL.liveactivity.processing"
    private let cleanupTaskId = "com.gopetl.PETL.liveactivity.cleanup"
    private var bgRefreshScheduled = false
    private var bgProcessingScheduled = false
    
    // MARK: - Reliability counters
    private var startsRequested = 0
    // Warm-up window start time for the current charging session
    private var sessionStartAt: Date? = nil
    private var startsSucceeded = 0
    private var endsRequestedLocal = 0
    private var endsSucceeded = 0
    private var remoteEndsHonored = 0
    private var remoteEndsIgnored = 0
    private var watchdogFires = 0
    private var duplicateCleanups = 0
    private var selfPingsQueued = 0

    // Guard against transient 0m spikes while still charging
    private var finalStateStrikes: Int = 0
    private var finalStateWindowBeganAt: Date? = nil
    


    /// Fill in transient zero metrics using the most recent good values for a short window.
    private func sanitizedForZeroGaps(_ state: PETLLiveActivityAttributes.ContentState) -> PETLLiveActivityAttributes.ContentState {
        // SSOT: Do not mutate minutes/date/watts; presenter/mapper already format placeholders.
        return state
    }

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
                LA_log("🔄 Startup recovery: \(systemActivities.count) system activities but no tracked ID")
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
        // If we’re foregrounded, charging, and have no active LA, allow immediate restart
        if ChargeStateStore.shared.isCharging && !hasLiveActivity {
            updatesBlocked = false
            addToAppLogsIfEnabled("🔓 FG resume — unblocked updates for potential re-start")
        }
    }
    @objc private func _appDidEnterBackground() {
        lastBackgroundAt = Date()
        addToAppLogsIfEnabled("📥 App entered background — BG grace window started")

        // Proactively enqueue a remote self‑tick so LA/DI can update while app is suspended
        if hasLiveActivity && ChargeStateStore.shared.isCharging {
            #if DEBUG
            OneSignalClient.shared.enqueueSelfTick(seq: OneSignalClient.shared.bumpSeq())
            addToAppLogsIfEnabled("📡 Enqueued BG self‑tick (remote)")
            #endif
        }
    }

    @objc private func _appWillEnterForeground() {
        lastBackgroundAt = nil
        endBG() // ensure no stray BG task survives foreground transition
        addToAppLogsIfEnabled("📤 App will enter foreground — BG grace cleared")
    }
    
    @MainActor
    func reattachIfNeeded() {
        guard currentActivityID == nil else { return }
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
        updatesBlocked = false // allow updates for the new session
        forceWarmupNextPush = true
        lastPush = .distantPast
        lastRichState = nil
        Self.didForceFirstPushThisSession = false
        // ===== BEGIN STABILITY-LOCKED: LA sequencing reset (do not edit) =====
        lastSeq = 0
        lastRemoteSeq = 0
        lastAllowedUpdateAt = .distantPast
        lastAllowedWatts = -1
        lastAllowedETA = -1
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
    
    // MARK: - Piggyback Persistence
    /// Piggyback a periodic power DB write, throttled (~1/min), for Charging Power History.
    private func piggybackPowerWrite(_ source: String) {
        // Only write when actually charging and history writes enabled
        guard FeatureFlags.historyWritesEnabled, ChargeStateStore.shared.isCharging else { return }
        let now = Date()
        // Throttle to ~1/min to keep DB clean and charts smooth
        if now.timeIntervalSince(lastPowerPiggyAt) >= 55 {
            BatteryTrackingManager.shared.persistPowerFromExternal(source: source)
            lastPowerPiggyAt = now
        }
    }
    // Prefer "Full" instead of a dash or 0m when near/full charge with trickle power
    private func applyFullLabelIfNeeded(_ state: inout PETLLiveActivityAttributes.ContentState) {
        // Consider device "full" when SoC >= 99% and watts are near-zero or SSOT marks full
        let ssotFull = (ChargeStateStore.shared.snapshot.state == .full)
        if state.soc >= 99 && (state.watts < 1.0 || ssotFull) {
            state.isCharging = true // keep UI in 'charging style' to avoid unplug dash
            state.timeToFullMinutes = max(0, state.timeToFullMinutes)
            state.expectedFullDate = nil
            state.timeRemainingText = "Full"
            addToAppLogsIfEnabled("✅ Full-label guard — soc=\(state.soc)% watts=\(String(format: "%.1f", state.watts))W → 'Full'")
        }
    }
    // MARK: - Update Policy
    @MainActor
    func updateLiveActivityWithPolicy(state: PETLLiveActivityAttributes.ContentState) {
        let isForeground = UIApplication.shared.applicationState == .active
        var clamped = state
        if !clamped.isCharging && (ChargeStateStore.shared.isCharging || clamped.watts > 0.2) {
            clamped.isCharging = true
            addToAppLogsIfEnabled("🧲 Guard(policy) — forced isCharging=true (w=\(String(format: "%.1f", clamped.watts))W, store=\(ChargeStateStore.shared.isCharging))")
        }
        normalizeOneMinuteSpike(&clamped)
        // Warm-start: prefer in-app ETA for the first few minutes to avoid dashed labels
        if inWarmStartWindow(), clamped.isCharging {
            let wm = warmStartMinutesFallback()
            clamped.timeToFullMinutes = max(2, wm)
            let h = wm / 60, r = wm % 60
            clamped.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(wm)m"
            clamped.expectedFullDate = nil
            addToAppLogsIfEnabled("🟩 Warm-start seed (policy) — ETA=\(wm)m")
        }
        // Enforce identical display contract in policy path
        clamped = normalizeForLiveActivity(clamped)
        forceStaticDisplay(&clamped)
        // Seed minutes/watts to avoid '—' during warmup/scene churn and ensure stable label
        if clamped.isCharging {
            if clamped.timeToFullMinutes <= 0 {
                let cachedEta = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
                if cachedEta > 1 { clamped.timeToFullMinutes = cachedEta }
            }
            if clamped.watts <= 0 {
                let liveWatts = BatteryTrackingManager.shared.currentWatts
                if liveWatts > 0 {
                    clamped.watts = liveWatts
                } else {
                    let cachedW = UserDefaults.standard.double(forKey: "petl.lastWatts")
                    if cachedW > 0 { clamped.watts = cachedW }
                }
            }
            // Ensure a non-empty timeRemainingText while charging
            let labelEmpty = clamped.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if labelEmpty {
                if clamped.timeToFullMinutes > 0 {
                    let m = clamped.timeToFullMinutes
                    let h = m / 60, r = m % 60
                    clamped.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
                } else {
                    clamped.timeRemainingText = "…"
                }
            }
            // Also seed display strings so templates don't render "—"
            if clamped.isCharging {
                // Estimated wattage label
                let wattStr = (clamped.watts > 0) ? String(format: "%.1fW", clamped.watts) : ""
                if clamped.estimatedWattage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || clamped.estimatedWattage == "—" {
                    clamped.estimatedWattage = wattStr
                }
                // Charging rate label — prefer SSOT rate if available
                let ssotRate = ChargeStateStore.shared.snapshot.ratePctPerMin ?? 0
                if clamped.chargingRate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || clamped.chargingRate == "—" {
                    clamped.chargingRate = (ssotRate > 0) ? String(format: "%.2f%%/min", ssotRate) : ""
                }
            }
        }
       // Enforce the universal display contract for policy-driven pushes
       // Map near/full state to a stable "Full" label so DI never sees 0m/— at the top
       applyFullLabelIfNeeded(&clamped)
       // Enforce the universal display contract right before update
       applyDisplayContract(
           &clamped,
           lastPushedMinutes: self.lastPushedDisplayMinutes ?? self.lastPushedMinutes,
           cachedMinutes: {
               let v = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
               return v > 0 ? v : nil
           }()
       )
        // Enforce static minutes in policy path: never provide an anchor to the system
        clamped.expectedFullDate = nil
        if clamped.isCharging {
            let trimmed = clamped.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "—" || trimmed == "0m" {
                let m = max(2, clamped.timeToFullMinutes)
                let h = m / 60, r = m % 60
                clamped.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
            }
        }
        // Foreground cadence gate to prevent excessive local updates
        if isForeground {
            let nextW = max(0.0, clamped.watts)
            let nextE = max(0, clamped.timeToFullMinutes)
            if !shouldAllowUpdate(nextWatts: nextW, nextETA: nextE, reason: "policy-fg") {
                return
            }
        }
        lastContentState = clamped
        if clamped.watts > 0 && clamped.timeToFullMinutes > 0 { lastGoodMetricsAt = Date() }

        // Keep sticky minutes warm whenever we have a numeric ETA
        if clamped.timeToFullMinutes > 0 {
            self.lastDisplayedMinutes = clamped.timeToFullMinutes
            self.lastDisplayedAt = Date()
        }

        if isForeground {
            Task {
                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    // staleDate reduced from 600s to 60s to force iOS to request updates more frequently
                    let content = ActivityContent(state: clamped, staleDate: Date().addingTimeInterval(60))
                    await activity.update(content)
                    // ✅ Remote UPDATE — Vercel → OneSignal
                    Task {
                        await LiveActivityRemoteClient.update(
                            activityId: activity.id,
                            state: LiveActivityRemoteClient.ContentState(
                                soc: clamped.soc,
                                watts: clamped.watts,
                                timeToFullMinutes: clamped.timeToFullMinutes,
                                isCharging: clamped.isCharging
                            ),
                            ttlSeconds: 120
                        )
                    }
                    self.lastPushedDisplayMinutes = clamped.timeToFullMinutes
                    UserDefaults.standard.set(clamped.timeToFullMinutes, forKey: "petl.lastEtaMin")
                }
                addToAppLogsIfEnabled("🔄 Live Activity updated locally (foreground)")
                // Piggyback a power sample write for Charging Power History
                self.piggybackPowerWrite("la-fg")
            }
        } else {
            Task {
                beginBG("petl.la.update")
                defer { endBG() }

                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    let content = ActivityContent(state: clamped, staleDate: Date().addingTimeInterval(600))
                    await activity.update(content)
                    Task { await LiveActivityRemoteClient.update(activityId: activity.id, state: LiveActivityRemoteClient.ContentState(soc: clamped.soc, watts: clamped.watts, timeToFullMinutes: clamped.timeToFullMinutes, isCharging: clamped.isCharging), ttlSeconds: 120) }
                    #if DEBUG
                    // Best-effort remote echo; local update above is the source of truth
                    OneSignalClient.shared.updateLiveActivityRemote(activityId: activity.id, state: clamped)
                    #endif
                }
                // Piggyback a power sample write for Charging Power History (BG)
                self.piggybackPowerWrite("la-bg")
            }
            addToAppLogsIfEnabled("📡 Live Activity update attempted in background")
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
                addToAppLogsIfEnabled("🛑 Live Activity ended locally (foreground)")
            }
        } else {
            Task {
                beginBG("petl.la.end")
                defer { endBG() }

                // Try to end locally first while we have BG time
                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    // Preserve the last shown label to avoid a dash flash on end
                    var preserved = activity.content.state
                    preserved.updatedAt = Date()
                    preserved.isCharging = false
                    preserved.expectedFullDate = nil
                    // Keep last numeric minutes/label; do NOT set to "—" here
if preserved.soc >= 99 && (preserved.watts < 1.0 || ChargeStateStore.shared.snapshot.state == .full) {
    preserved.timeRemainingText = "Full"
    preserved.timeToFullMinutes = 0
}
                    let content = ActivityContent(state: preserved, staleDate: nil)
                    await activity.update(content)
                    await activity.end(content, dismissalPolicy: .immediate)
                }

                // ✅ Remote END — OneSignal direct call (works in DEBUG, production relies on Vercel)
                for activity in Activity<PETLLiveActivityAttributes>.activities {
                    OneSignalClient.shared.endLiveActivityRemote(activityId: activity.id)
                }
                // 🚀 Remote END — Vercel → OneSignal using captured IDs
                let capturedActivityIds = Activity<PETLLiveActivityAttributes>.activities.map { $0.id }
                for activityId in capturedActivityIds {
                    Task { await LiveActivityRemoteClient.end(activityId: activityId, immediate: true) }
                }
                addToAppLogsIfEnabled("📤 Sent remote /end for \(capturedActivityIds.count) activities (BG policy)")
            }
            addToAppLogsIfEnabled("📡 Live Activity end queued (local+remote) while in background")
        }
    }
    
    // MARK: - Remote (Silent Push) Entry Points
    /// Call from OneSignalClient when a *data-only* (content-available:1) push arrives.
    /// Expected payload keys:
    ///   live_activity_action: "tick" | "end" | "done" | "unplugged"
    ///   watts: Double? ; timeToFullMinutes: Int?
    ///   seq: Int? monotonic sequencing (optional)
    nonisolated func handleSilentPush(_ json: [AnyHashable: Any]) {
        Task { @MainActor in
            self._handleSilentPushOnMain(json)
        }
    }

    @MainActor
    private func _handleSilentPushOnMain(_ json: [AnyHashable: Any]) {
        guard FeatureFlags.remoteLASnapshotsEnabled else {
            addToAppLogsIfEnabled("⏸️ Silent push ignored — remote LA snapshots disabled")
            return
        }
        let action = (json["live_activity_action"] as? String) ?? "tick"
        addToAppLogsIfEnabled("📬 Silent push — action=\(action) keys=\(json.keys)")

        switch action {
        case "unplugged", "done", "end":
            // Treat as immediate end signal. Do not wait for local polling.
            Task { @MainActor in
                await self.endAll("server-push-\(action)")
                // Stop background cadence after end.
                if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                    appDelegate.cancelRefresh()
                    appDelegate.cancelProcessing()
                }
                self.cancelRefresh()
                self.cancelProcessing()
            }

        case "tick":
            // Check system battery state directly (not SSOT) to avoid stale state after extended periods
            let currentBatteryState = UIDevice.current.batteryState
            let isCurrentlyCharging = (currentBatteryState == .charging || currentBatteryState == .full)
            
            // If we get a tick while not charging, treat it as a stale push and end immediately.
            if !isCurrentlyCharging {
                addToAppLogsIfEnabled("🔌 Silent tick while not charging (system state) — ending LA/DI")
                Task { @MainActor in
                    await self.endAll("push-not-charging")
                    // Cancel background tasks since we're not charging
                    self.cancelRefresh()
                    self.cancelProcessing()
                }
                return
            }
            // 1) Persist SoC + power via BTM helper (throttled internally).
            if FeatureFlags.historyWritesEnabled {
                BatteryTrackingManager.shared.handleSilentTick()
            } else {
                addToAppLogsIfEnabled("🗂️ History writes disabled — skipping sample (push)")
            }
            // 2) Compose live activity content from SSOT and push (production-safe path).
            var state = self.firstContent()
            state = normalizeForLiveActivity(state)
            Task { @MainActor in
                await self.pushToAll(state)
                self.lastPushedDisplayMinutes = state.timeToFullMinutes
            }
            // 3) Keep BG heartbeats rolling to continue chart updates (only while charging).
            // Reuse system state check from above to avoid stale SSOT state after extended periods
            if isCurrentlyCharging {
                self.scheduleRefresh(in: 20)
                self.scheduleProcessing(in: 45)
            } else {
                // Not charging - cancel tasks and end LA
                self.cancelRefresh()
                self.cancelProcessing()
                Task { @MainActor in
                    await self.endAll("push-tick-not-charging")
                }
            }

        default:
            addToAppLogsIfEnabled("ℹ️ Silent push ignored — unknown action '\(action)'")
        }
    }

    // MARK: - Public API
    @MainActor
    func configure() {
        guard !Self.isConfigured else { return }
        Self.isConfigured = true
        laLogger.info("🔧 LiveActivityManager configured")

        // Push policy driven by ETA changes and periodic snapshots
        #if ESTIMATOR
        ChargeEstimator.shared.estimateSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] (est: ChargeEstimator.ChargeEstimate) in
                guard let self = self else { return }

                let bigDelta = self.lastPushedMinutes
                    .map { abs($0 - (ChargeStateStore.shared.currentETAMinutes ?? 0)) >= 3 }
                    ?? true

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
        #endif

        BatteryTrackingManager.shared.snapshotSubject
            .receive(on: RunLoop.main)
            .debounce(for: .seconds(QA.debounceSeconds), scheduler: RunLoop.main)
            .sink { [weak self] snap in
                guard let self = self else { return }
                laLogger.debug("⏳ Debounced snapshot: \(Int(snap.level * 100))%, charging=\(snap.isCharging)")
                self.handle(snapshot: snap)
                self.updateAllActivities(force: false)
            }
            .store(in: &cancellables)

        ensureBatteryMonitoring()
        // IMPORTANT: Register BG tasks immediately to avoid submission-before-registration crashes.
        self.registerBackgroundTasks()
        // Defer only the persisted state restore (safe to delay)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.restorePersistedChargingState()
        }

        // ✅ Kick off / stop background heartbeats immediately.
        // If the user launches and swipes away quickly, delayed tasks may never run.
        if ChargeStateStore.shared.isCharging {
            self.scheduleRefresh(in: 20)      // BG app refresh cadence (~20 min)
            self.scheduleProcessing(in: 45)   // BG processing cadence (~45 min)
        } else {
            self.cancelRefresh()
            self.cancelProcessing()
        }

        // Light remote nudge: try immediately, then retry once shortly after start.
        Task { @MainActor in
            if ChargeStateStore.shared.isCharging {
                if self.hasLiveActivity {
                    OneSignalClient.shared.enqueueSelfTick(seq: OneSignalClient.shared.bumpSeq())
                    addToAppLogsIfEnabled("📡 Warm-start remote tick enqueued (LA/DI BG updates)")
                } else {
                    // Give ActivityKit a moment to reflect a just-started activity
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if self.hasLiveActivity {
                        OneSignalClient.shared.enqueueSelfTick(seq: OneSignalClient.shared.bumpSeq())
                        addToAppLogsIfEnabled("📡 Warm-start remote tick enqueued (LA/DI BG updates, retry)")
                    }
                }
            }
        }

        // Authorization sanity check
        let info = ActivityAuthorizationInfo()
        addToAppLogsIfEnabled("🔐 LA perms — enabled=\(info.areActivitiesEnabled)")

        // Sync in-memory flag with system on cold start
        self.isActive = self.hasLiveActivity
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.dumpActivities("after configure")
            self.ensureStartedIfChargingNow()
        }

        // App lifecycle observers for background/foreground
        // App lifecycle observers for background/foreground
        NotificationCenter.default.addObserver(self, selector: #selector(_appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    func handleRemotePayload(_ json: [AnyHashable: Any]) {
        // Sequence guard: ignore duplicates/out-of-order payloads
        if let seqAny = json["seq"],
           let seq = (seqAny as? Int) ?? Int((seqAny as? String) ?? "") {
            if seq <= lastSeq {
                addToAppLogsIfEnabled("↪️ Drop LA payload (seq=\(seq) <= lastSeq=\(lastSeq))")
                return
            }
            lastSeq = seq
        }

        // Persist a sample for charts/analytics on every honored remote update path.
        if FeatureFlags.historyWritesEnabled {
            self.piggybackPowerWrite("la-push-remote")
        }
        
        // Optional: Filter sim payloads to keep LA clean
        if json["simWatts"] != nil {
            addToAppLogsIfEnabled("↪️ Drop LA payload — simWatts present")
            return
        }
        
        // 1. Parse watts and ETA from payload
        let payloadWatts: Double = {
            if let w = json["watts"] as? Double { return w }
            if let s = json["watts"] as? String, let v = Double(s) { return v }
            if let v = json["simWatts"] as? Double { return v }
            return 0.0
        }()

        let payloadEtaMinutes: Int = {
            if let e = json["timeToFullMinutes"] as? Int { return e }
            if let s = json["timeToFullMinutes"] as? String, let v = Int(s) { return v }
            return 0
        }()
        
        // Sanitize zeros while charging by falling back to last known or SSOT snapshot
        let chargingNow = ChargeStateStore.shared.isCharging
        var wattsForUpdate = max(0.0, payloadWatts)
        var etaForUpdate   = max(0,    payloadEtaMinutes)
        if chargingNow {
            if wattsForUpdate <= 0 {
                if let last = lastContentState, last.watts > 0 { wattsForUpdate = last.watts }
                else if let sW = ChargeStateStore.shared.snapshot.watts, sW > 0 { wattsForUpdate = sW }
                else if BatteryTrackingManager.shared.currentWatts > 0 { wattsForUpdate = BatteryTrackingManager.shared.currentWatts }
            }
            if etaForUpdate <= 0 {
                if let last = lastContentState, last.timeToFullMinutes > 0 { etaForUpdate = last.timeToFullMinutes }
                else if let sETA = ChargeStateStore.shared.snapshot.etaMinutes, sETA > 0 { etaForUpdate = sETA }
                else if let liveETA = ChargeStateStore.shared.currentETAMinutes, liveETA > 0 { etaForUpdate = liveETA }
            }
        }
        // Clamp ETA increases (allow decreases freely)
        if let prevETA = lastContentState?.timeToFullMinutes, etaForUpdate > prevETA {
            etaForUpdate = min(prevETA + 2, etaForUpdate)
        }
        // Removed pre-send log that could mislead debugging
        
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

            // Warm-up suppression for remote updates: avoid 0W/0m during first seconds
            if ChargeStateStore.shared.isCharging, let t0 = self.sessionStartAt {
                let warm = Date().timeIntervalSince(t0)
                if warm < 10, (wattsForUpdate <= 0 || etaForUpdate <= 1) {
                    if let last = self.lastContentState, last.timeToFullMinutes > 1 {
                        // Reuse last good state
                        var fallback = last
                        fallback.updatedAt = Date()
                        let isForeground = UIApplication.shared.applicationState == .active
                        if isForeground {
                            Task { @MainActor in
                                for activity in Activity<PETLLiveActivityAttributes>.activities {
                                    let content = ActivityContent(state: fallback, staleDate: Date().addingTimeInterval(600))
                                    await activity.update(content)
                                }
                            }
                        } else {
                            for activity in Activity<PETLLiveActivityAttributes>.activities {
                                #if DEBUG
                                OneSignalClient.shared.updateLiveActivityRemote(activityId: activity.id, state: fallback)
                                #endif
                            }
                        }
                        self.lastContentState = fallback
                        addToAppLogsIfEnabled("⏳ LA warmup(remote) — reused last good state (\(String(format: "%.1f", fallback.watts))W, \(fallback.timeToFullMinutes)m)")
                        return
                    } else {
                        addToAppLogsIfEnabled("⏳ LA warmup(remote) — suppressed 0W/1m push (<10s)")
                        return
                    }
                }
            }

            // Build a fresh snapshot using payload overrides (if >0), then map via SSOT
            let s0 = ChargeStateStore.shared.snapshot
            let snap = ChargingSnapshot(
                ts: Date(),
                socPercent: s0.socPercent,
                state: s0.state,
                watts: (wattsForUpdate > 0 ? wattsForUpdate : s0.watts),
                ratePctPerMin: s0.ratePctPerMin,
                etaMinutes: (etaForUpdate > 0 ? etaForUpdate : s0.etaMinutes),
                device: s0.device
            )
            var contentState = SnapshotToLiveActivity.makeContent(from: snap)
            normalizeOneMinuteSpike(&contentState)
            contentState = normalizeForLiveActivity(contentState)
            let nextW = max(0.0, contentState.watts)
            let etaForGate = max(0, contentState.timeToFullMinutes)
            if !shouldAllowUpdate(nextWatts: nextW, nextETA: etaForGate, reason: "remote") {
                return
            }

            addToAppLogsIfEnabled("🟨 LA compose (remote SSOT) — watts=\(String(format: "%.1f", contentState.watts))W eta=\(contentState.timeToFullMinutes)m (payloadW=\(String(format: "%.1f", payloadWatts)) eta=\(payloadEtaMinutes))")
            Task { @MainActor in
                await self.pushToAll(contentState)
                self.lastPushedDisplayMinutes = contentState.timeToFullMinutes
                addToAppLogsIfEnabled("🟦 LA update sent — watts=\(String(format: "%.1f", contentState.watts))W eta=\(contentState.timeToFullMinutes)m")
            }

        case "end":
            let st = UIDevice.current.batteryState
            let sysCharging = (st == .charging || st == .full)
            if !sysCharging {
                remoteEndsHonored += 1
                osLogger.info("⏹️ Remote end honored (seq=\(seq))")
                Task { @MainActor in
                    await endAll("server-push-unplugged")
                    // Stop background cadence after end.
                    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                        appDelegate.cancelRefresh()
                        appDelegate.cancelProcessing()
                    }
                    self.cancelRefresh()
                    self.cancelProcessing()
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
        // Prefer SSOT charging flag, but also treat > threshold watts as charging (noise guard)
        let watts = ChargeStateStore.shared.snapshot.watts ?? 0
        let isActuallyCharging = s.isCharging || watts >= minChargingWattsThreshold

        if isActuallyCharging {
            // Cancel any pending unplug end; we are charging again
            unplugWorkItem?.cancel(); unplugWorkItem = nil

            startsRequested += 1
            if !hasLiveActivity {
                self.sessionStartAt = Date()
                Task { await self.startActivity(reason: .snapshot) }
            }
        } else {
            // Debounce unplug for a few seconds to avoid false ends during scene churn
            // If we just backgrounded or recently had good metrics, don't even start a debounce
            let recentlyGood = (lastGoodMetricsAt.map { Date().timeIntervalSince($0) < 18 } ?? false)
            if inDisplayBGGrace() || recentlyGood {
                // Treat as noise; wait for a stable next snapshot
                BatteryTrackingManager.shared.addToAppLogs("⏸️ Unplug ignored during BG-grace/recent-good window")
            } else {
                unplugWorkItem?.cancel(); unplugWorkItem = nil
                let delay = currentUnplugDebounceSeconds()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    let w = ChargeStateStore.shared.snapshot.watts ?? 0
                    let stillUnplugged = (ChargeStateStore.shared.isCharging == false) && (w < self.minChargingWattsThreshold)
                    if stillUnplugged {
                        Task { @MainActor in
                            await self.endAll("debounced-unplug")
                        }
                    } else {
                        BatteryTrackingManager.shared.addToAppLogs("↩️ Unplug debounce canceled — charging resumed (w=\(String(format: "%.1f", w))W)")
                    }
                }
                unplugWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        // Push an update opportunistically when a fresh snapshot arrives
        self.updateAllActivities(force: false)
    }

    private func scheduleEndWatchdog() {
        endWatchdogTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let activityCount = Activity<PETLLiveActivityAttributes>.activities.count
            if self.hasLiveActivity && activityCount > 0 {
                self.watchdogFires += 1
                addToAppLogsIfEnabled("⏱️ End watchdog fired; \(activityCount) activity(ies) still present, enqueueing final end self-ping")
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

        // If we're not charging and there is no active activity, skip any LA work entirely.
        if !ChargeStateStore.shared.isCharging && Activity<PETLLiveActivityAttributes>.activities.isEmpty {
            addToAppLogsIfEnabled("⏭️ Skip LA update — not charging and no active activities")
            return
        }

        // Get current snapshot
        let snapshot = ChargeStateStore.shared.snapshot

        let lastETA = lastRichState?.timeToFullMinutes ?? 0
        let currentETA = snapshot.etaMinutes ?? 0
        let etaDelta = abs(currentETA - lastETA)

        let lastSOC = Double(lastRichState?.soc ?? 0) / 100.0
        let currentSOC = Double(snapshot.socPercent) / 100.0
        let socDelta = abs(currentSOC - lastSOC)

        let doForce = force || forceNextPush
        let canPush = doForce ||
                     lastPush == nil ||
                     now.timeIntervalSince(lastPush!) >= 300 ||  // 5 minutes
                     etaDelta >= 2 ||
                     socDelta >= 0.01

        guard canPush else { return }

        // Use SSOT mapper to build content state and guard zeros
        var state = SnapshotToLiveActivity.makeContent(from: snapshot)
        // Guard: avoid transient not-charging mapping during scene churn when power is flowing
        if !state.isCharging && (ChargeStateStore.shared.isCharging || state.watts > 0.2) {
            state.isCharging = true
            addToAppLogsIfEnabled("🧲 Guard(updateAll) — forced isCharging=true (w=\(String(format: "%.1f", state.watts))W, store=\(ChargeStateStore.shared.isCharging))")
        }
        normalizeOneMinuteSpike(&state)
        // Warm-start: force minutes/label from in-app ETA to prevent "—"/"1m"
        if inWarmStartWindow(), state.isCharging {
            let wm = warmStartMinutesFallback()
            state.timeToFullMinutes = max(2, wm)
            let h = wm / 60, r = wm % 60
            state.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(wm)m"
            state.expectedFullDate = nil
            BatteryTrackingManager.shared.addToAppLogs("🟩 Warm-start seed — ETA=\(wm)m applied at start")
        }
        state = normalizeForLiveActivity(state)
applyFullLabelIfNeeded(&state)
        forceStaticDisplay(&state)
        applyDisplayContract(
            &state,
            lastPushedMinutes: self.lastPushedDisplayMinutes ?? self.lastPushedMinutes,
            cachedMinutes: {
                let v = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
                return v > 0 ? v : nil
            }()
        )
        addToAppLogsIfEnabled("📊 updateAllActivities: soc=\(state.soc)% watts=\(String(format: "%.1f", state.watts))W rate=\(state.chargingRate) eta=\(state.timeToFullMinutes)m text='\(state.timeRemainingText)' expectedFullDate=\(String(describing: state.expectedFullDate))")
        addToAppLogsIfEnabled("🧪 LA compose (pre) — text='\(state.timeRemainingText)' eta=\(state.timeToFullMinutes)m watts=\(String(format: "%.1f", state.watts))")
        // Gate on the mapped display ETA (not raw SSOT). Suppress 1m deltas entirely for gating/logs.
        let etaForGate = max(0, state.timeToFullMinutes)
        let prevDisplay = self.lastPushedDisplayMinutes ?? self.lastPushedMinutes
        let rawDelta = prevDisplay.map { abs($0 - etaForGate) } ?? 0
        let gateDelta = (rawDelta == 1) ? 0 : rawDelta
        addToAppLogsIfEnabled("🧰 Gate(using displayETA=\(etaForGate)m, prev=\(prevDisplay ?? -1)) rawΔ=\(rawDelta)m → gateΔ=\(gateDelta)m")
        // Apply unified cadence gate unless explicitly forced
        if !doForce {
            let nextW = max(0.0, state.watts)
            if !shouldAllowUpdate(nextWatts: nextW, nextETA: etaForGate, reason: "local") {
                return
            }
        }
        addToAppLogsIfEnabled("🟨 LA compose (SSOT) — watts=\(String(format: "%.1f", state.watts))W eta=\(state.timeToFullMinutes)m")
        Task { @MainActor in
            await pushToAll(state)
            self.lastPushedDisplayMinutes = state.timeToFullMinutes
            UserDefaults.standard.set(state.timeToFullMinutes, forKey: "petl.lastEtaMin")
            
            // Trigger background calculation update whenever LA is updated
            BatteryTrackingManager.shared.performBackgroundCalculationTick()
        }
        lastRichState = state
        lastContentState = state
        if state.watts > 0 && state.timeToFullMinutes > 0 {
            lastGoodMetricsAt = Date()
        }
        lastPush = now
        forceNextPush = false
    }
    
    @MainActor
    func updateIfNeeded(from snapshot: BatterySnapshot) {
        // Deprecated: start/stop is centralized in BatteryTrackingManager
    }
    
    /// Updates Live Activity from background (called by silent push)
    @MainActor
    func updateActivityFromBackground() async {
        addToAppLogsIfEnabled("🔄 Background LA update triggered by silent push")
        
        // Get current battery data from SSOT
        let currentSoc = ChargeStateStore.shared.currentBatteryLevel
        let currentWatts = ChargeStateStore.shared.snapshot.watts ?? 0.0
        let currentETA = ChargeStateStore.shared.currentETAMinutes ?? 0
        let currentRate = ChargeStateStore.shared.snapshot.ratePctPerMin ?? 0.0
        
        addToAppLogsIfEnabled("📊 BG update from SSOT: soc=\(currentSoc)% watts=\(String(format: "%.1f", currentWatts))W eta=\(currentETA)m rate=\(String(format: "%.2f", currentRate))%%/min")
        
        // Also log from ChargingAnalyticsStore for comparison
        let analyticsETA = ChargingAnalyticsStore.shared.timeToFullMinutes ?? 0
        let analyticsWatts = ChargingAnalyticsStore.shared.estimatedWatts()
        addToAppLogsIfEnabled("📊 BG update from Analytics: eta=\(analyticsETA)m watts=\(String(format: "%.1f", analyticsWatts))W")
        
        // Use pushUpdate to ensure fresh calculations are used and remote updates are sent
        await pushUpdate(reason: "silent-push")
    }
    
    func publishLiveActivityAnalytics(_ analytics: ChargingAnalyticsStore) {
        // Use SSOT store for all data
        var state = SnapshotToLiveActivity.currentContent()
        // Guard: analytics path can also see scene churn; force charging if power present
        if !state.isCharging && (ChargeStateStore.shared.isCharging || state.watts > 0.2) {
            state.isCharging = true
            addToAppLogsIfEnabled("🧲 Guard(analytics) — forced isCharging=true (w=\(String(format: "%.1f", state.watts))W, store=\(ChargeStateStore.shared.isCharging))")
        }
        normalizeOneMinuteSpike(&state)
        state = normalizeForLiveActivity(state)
        forceStaticDisplay(&state)
        applyDisplayContract(
            &state,
            lastPushedMinutes: self.lastPushedDisplayMinutes ?? self.lastPushedMinutes,
            cachedMinutes: {
                let v = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
                return v > 0 ? v : nil
            }()
        )
        // Keep sticky minutes warm on analytics-driven pushes
        if state.timeToFullMinutes > 0 {
            self.lastDisplayedMinutes = state.timeToFullMinutes
            self.lastDisplayedAt = Date()
        }
        // Gate on display ETA; suppress 1m deltas
        let etaForGate = max(0, state.timeToFullMinutes)
        let prevDisplay = self.lastPushedDisplayMinutes ?? self.lastPushedMinutes
        let rawDelta = prevDisplay.map { abs($0 - etaForGate) } ?? 0
        let gateDelta = (rawDelta == 1) ? 0 : rawDelta
        addToAppLogsIfEnabled("🧰 Gate(analytics) using displayETA=\(etaForGate)m (prev=\(prevDisplay ?? -1)) rawΔ=\(rawDelta)m → gateΔ=\(gateDelta)m")
        // let guarded = sanitizedForZeroGaps(state)
        
        // Cadence gate for analytics-driven pushes
        let nextW = max(0.0, state.watts)
        if !shouldAllowUpdate(nextWatts: nextW, nextETA: etaForGate, reason: "analytics") {
            return
        }
        Task { @MainActor in
            await pushToAll(state)
            self.lastPushedDisplayMinutes = state.timeToFullMinutes
        }
        BatteryTrackingManager.shared.emitSnapshotNow("analytics-bridge")
        addToAppLogsIfEnabled("📤 DI payload — eta=\(state.timeToFullMinutes > 0 ? "\(state.timeToFullMinutes)m" : "—") W=\(state.watts > 0 ? String(format:"%.1f", state.watts) : "—")")
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
        addToAppLogsIfEnabled("🧹 Cleaning up duplicates: \(list.count)")
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
        // Coalesce first-frame state: re-check after 120ms to avoid cold UIDevice misreport
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run {
                guard let self = self else { return }
                let lvl = UIDevice.current.batteryLevel
                let st  = UIDevice.current.batteryState
                let ch  = (st == .charging || st == .full)
                let w: Double? = FeatureFlags.smoothChargingAnalytics ? ({
                    let wv = ChargingAnalyticsStore.shared.estimatedWatts()
                    return (wv.isFinite && wv > 0) ? wv : nil
                })() : nil
                // If the first frame said unplugged but now we see power, correct it
                if let wv = w, !ch, wv > 0.5 {
                    addToAppLogsIfEnabled("🔁 First-frame coalesce — correcting unplugged→charging (w=\(String(format: "%.1f", wv)))")
                    ChargeStateStore.shared.applySystemRead(level01: lvl, isCharging: true, watts: w, ts: Date())
                    BatteryTrackingManager.shared.emitSnapshotNow("firstFrameCoalesce")
                    // Clear any pending unplug debounce once power evidence is seen
                    self.unplugWorkItem?.cancel(); self.unplugWorkItem = nil
                }
            }
        }
    }
    
    @MainActor
    func debugForceStart() async {
        addToAppLogsIfEnabled("🛠️ debugForceStart()")
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
        addToAppLogsIfEnabled("🧵 startActivity(seed) reason=\(reason.rawValue) mainThread=\(Thread.isMainThread) seed=\(seededMinutes) sysPct=\(sysPct)")

        let auth = ActivityAuthorizationInfo()
        if auth.areActivitiesEnabled == false {
            addToAppLogsIfEnabled("🚫 Skip start — LIVE-ACTIVITIES-DISABLED")
            return
        }

        let before = Activity<PETLLiveActivityAttributes>.activities.count
        addToAppLogsIfEnabled("🔍 System activities count before start: \(before)")
        if before > 0 {
            addToAppLogsIfEnabled("⏭️ Skip start — ALREADY-ACTIVE")
            return
        }

        let minutes = max(seededMinutes, ChargeStateStore.shared.currentETAMinutes ?? 0)
        addToAppLogsIfEnabled("⛽️ seed-\(minutes) sysPct=\(sysPct)")

        let attrs = PETLLiveActivityAttributes()

        // Build a first-frame state via unified path to guarantee static label & no anchors
        var state = firstContent()
        state = normalizeForLiveActivity(state)
        forceStaticDisplay(&state)

        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))

        // Try with push token first; if it fails, fallback to no-push.
        do {
            let activity = try Activity<PETLLiveActivityAttributes>.request(attributes: attrs, content: content, pushType: .token)
            BatteryTrackingManager.shared.addToAppLogsCritical("🎬 Started Live Activity id=\(String(activity.id.suffix(4))) reason=\(reason.rawValue) (push=on)")
            register(activity, reason: reason.rawValue)
            observePushToken(activity, initialState: state)
            // Force the first UI push shortly after start so LA/DI never shows a dash
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000) // ~0.12s after request
                self.updateAllActivities(force: true)
                Self.didForceFirstPushThisSession = true
                self.lastPushedDisplayMinutes = ChargeStateStore.shared.currentETAMinutes
                addToAppLogsIfEnabled("⚡ First Live Activity push forced (post-start, push)")
            }
        } catch {
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
                // Force the first UI push shortly after start in no-push mode as well
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    self.updateAllActivities(force: true)
                    Self.didForceFirstPushThisSession = true
                    self.lastPushedDisplayMinutes = ChargeStateStore.shared.currentETAMinutes
                    addToAppLogsIfEnabled("⚡ First Live Activity push forced (post-start, no-push)")
                }
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
    private func observePushToken(
        _ activity: Activity<PETLLiveActivityAttributes>,
        initialState: PETLLiveActivityAttributes.ContentState
    ) {
        Task.detached { [activityId = activity.id] in
            var didSendStart = false

            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()

                await MainActor.run {
                    // cache for diagnostics / fallback
                    UserDefaults.standard.set(hex, forKey: "live_activity_push_token")
                    addToAppLogsIfEnabled("🔑 LiveActivity APNs token len=\(hex.count)")
                }

                // Send START to Vercel exactly once, when we have a real token.
                if !didSendStart && !hex.isEmpty {
                    didSendStart = true

                    await LiveActivityRemoteClient.start(
                        activityId: activityId,
                        laPushTokenHex: hex,
                        state: LiveActivityRemoteClient.ContentState(
                            soc: initialState.soc,
                            watts: initialState.watts,
                            timeToFullMinutes: initialState.timeToFullMinutes,
                            isCharging: initialState.isCharging
                        )
                    )

                    await MainActor.run {
                        addToAppLogsIfEnabled("🚀 Remote START sent (token acquired) id=\(String(activityId.suffix(4)))")
                    }
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

        // 2) Cooldown (keep your stability lock), but allow FG/charging relaunch after ~3s if no LA exists
        if let ended = lastEndAt {
            let dt = Date().timeIntervalSince(ended)
            let canBypass = AppForegroundGate.shared.isActive && ChargeStateStore.shared.isCharging && !hasLiveActivity && dt >= 3
            if !canBypass && dt < minRestartInterval {
                let remain = Int(minRestartInterval - dt)
                BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — COOLDOWN (\(remain)s left)")
                return
            } else if canBypass {
                BatteryTrackingManager.shared.addToAppLogsCritical("✅ Cooldown bypassed — FG charging relaunch (dt=\(Int(dt))s)")
            }
        }

        // 3) If the system already has an activity, mark active and bail
        if hasLiveActivity {
            BatteryTrackingManager.shared.addToAppLogsCritical("⏭️ Skip start — ALREADY-ACTIVE")
            unplugWorkItem?.cancel(); unplugWorkItem = nil
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
                    await self?.startActivity(reason: reason)
                }
            }
            return
        }

        // Ensure any prior endAll() block is lifted for this fresh session
        updatesBlocked = false

        // 🆕 CLEAR STALE CACHE: If live ETA differs significantly from cache, update cache
        if let liveETA = ChargeStateStore.shared.currentETAMinutes, liveETA > 1 {
            let cachedETA = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
            if abs(liveETA - cachedETA) > 5 {
                UserDefaults.standard.set(liveETA, forKey: "petl.lastEtaMin")
                addToAppLogsIfEnabled("🧹 Cleared stale cache ETA (\(cachedETA)m) → live ETA (\(liveETA)m)")
            }
        }
        // 6) Call the unified start method
        // 🆕 Smart ETA warm-start seed
        let sysPct = ChargeStateStore.shared.currentBatteryLevel
        var seed = 2  // conservative baseline

        // 0) Prefer live ChargeEstimator ETA during warm-up (strongest real-time signal)
        if let cur = ChargeEstimator.shared.current, cur.watts.isFinite, cur.watts > 0 {
            let ratePctPerMin: Double = {
                let r = UserDefaults.standard.double(forKey: "petl.lastRatePctPerMin")
                if r.isFinite, r > 0 { return r }
                return 0
            }()
            if ratePctPerMin.isFinite, ratePctPerMin > 0 {
                let remaining = max(0, 100 - sysPct)
                let eta = Int(ceil(Double(remaining) / ratePctPerMin))
                if eta > 1 {
                    seed = eta
                    addToAppLogsIfEnabled("🟩 Warm-start: using ChargeEstimator ETA=\(eta)m (live)")
                }
            }
        }

        // 1) Fallback to live SSOT ETA
        if seed <= 2, let m = ChargeStateStore.shared.currentETAMinutes, m > 1 {
            seed = m
            addToAppLogsIfEnabled("🟩 Warm-start: using live SSOT ETA=\(m)m")
        }

        // 2) Fallback to last pushed ETA
        if seed <= 2, let last = (self.lastPushedDisplayMinutes ?? self.lastPushedMinutes), last > 1 {
            seed = last
            addToAppLogsIfEnabled("🟩 Warm-start: using last pushed ETA=\(last)m")
        }

        // 3) Fallback to cached ETA
        if seed <= 2 {
            let cached = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
            if cached > 1 {
                seed = cached
                addToAppLogsIfEnabled("🟩 Warm-start: using cached ETA=\(cached)m")
            }
        }

        // 4) Final fallback baseline (avoid showing dashes)
        if seed <= 2 {
            addToAppLogsIfEnabled("🟩 Warm-start: using baseline ETA=2m")
            seed = 2
        }
        // Begin a warm-start window where we trust in-app ETA to avoid dashed/empty labels
        self.warmStartUntil = Date().addingTimeInterval(180) // 3 minutes
        BatteryTrackingManager.shared.addToAppLogs("🧷 Warm-start ETA window active (3m)")
        #if DEBUG
        // Nudge a remote tick shortly after start so DI converges, without blocking local display
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000) // ~0.8s
            if self.inWarmStartWindow(), ChargeStateStore.shared.isCharging {
                // Local forced update to keep UI hot
                self.updateAllActivities(force: true)
                addToAppLogsIfEnabled("📡 Warm-start local tick")
                // Remote nudge so LA/DI keeps updating when we’re backgrounded
                #if DEBUG
                OneSignalClient.shared.enqueueSelfTick(seq: OneSignalClient.shared.bumpSeq())
                addToAppLogsIfEnabled("📡 Warm-start remote tick enqueued")
                #endif
            }
        }
        #endif
        BatteryTrackingManager.shared.addToAppLogsCritical("➡️ delegating to seeded start reason=\(reason.rawValue)")
        lastStartAt = Date()
        self.sessionStartAt = Date() // warm-up begins at first explicit start
        // New session starting: cancel any pending unplug debounces
        unplugWorkItem?.cancel(); unplugWorkItem = nil
        startActivity(seed: seed, sysPct: sysPct, reason: reason)

        // Schedule background cadence immediately (do not wait for system activity list to reflect the start).
        if ChargeStateStore.shared.isCharging {
            self.scheduleRefresh(in: 5)
            self.scheduleProcessing(in: 10)
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.scheduleRefresh(in: 5)
                appDelegate.scheduleProcessing(in: 10)
            }
        }

        // Post-start bookkeeping: re-check shortly after to allow ActivityKit to materialize.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if self.hasLiveActivity {
                self.startsSucceeded += 1
                self.isActive = true
                self.cleanupDuplicates(keepId: Activity<PETLLiveActivityAttributes>.activities.first?.id ?? "")
                self.dumpActivities("post-start")
                self.cancelEndWatchdog()
                self.recentStartAt = Date()
            } else {
                addToAppLogsIfEnabled("⚠️ post-start: system still shows 0 activities; keeping BG cadence scheduled")
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
        // Diagnostic: log what text is being pushed
        addToAppLogsIfEnabled("🔬 LA pre-push — text='\(state.timeRemainingText)' eta=\(state.timeToFullMinutes)m watts=\(String(format: "%.1f", state.watts))")
        addToAppLogsIfEnabled("🟢 Countdown disabled — using static minutes only")
        // Ensure we have background time if app is not active
        let appIsFG = UIApplication.shared.applicationState == .active
        if !appIsFG { beginBG("petl.la.push") }
        defer { if !appIsFG { endBG() } }
        // Check if updates are blocked (e.g., during dismissal) - do this early
        if updatesBlocked {
            addToAppLogsIfEnabled("🚫 LA update blocked (already ended)")
            return
        }
        // Create mutable copy and assign fresh timestamp to ensure monotonic updates
        // This prevents accidental drops when SSOT content changes but timestamp doesn't advance
        var out = state
        out.updatedAt = Date()
        // Monotonic guard: ignore stale or equal-timestamp states (now using fresh timestamp)
        if out.updatedAt <= lastPushedContentTimestamp {
            addToAppLogsIfEnabled("⏭️ Ignored stale LA update ts=\(out.updatedAt.timeIntervalSince1970)")
            return
        }
        normalizeOneMinuteSpike(&out)
        // Sticky numeric label: if we recently showed a number, keep it instead of showing a dash for brief SSOT unplug states
        if !out.isCharging {
            let since = Date().timeIntervalSince(self.lastDisplayedAt)
            if since < stickyMinutesTTL && self.lastDisplayedMinutes > 1 {
                out.isCharging = true // display style
                out.timeToFullMinutes = self.lastDisplayedMinutes
                let h = out.timeToFullMinutes / 60, r = out.timeToFullMinutes % 60
                out.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(out.timeToFullMinutes)m"
                addToAppLogsIfEnabled("🧷 Sticky minutes kept — \(out.timeToFullMinutes)m (since=\(Int(since))s)")
            }
        }
        // Preserve label across brief BG/scene churn even if mapper says unplugged
        if out.isCharging == false {
            let recentlyGood = (lastGoodMetricsAt.map { Date().timeIntervalSince($0) < 18 } ?? false)
            if inDisplayBGGrace() || recentlyGood {
                if let prev = (self.lastPushedDisplayMinutes ?? self.lastPushedMinutes), prev > 1 {
                    // Treat as still-charging for UI purposes to avoid a dash flash
                    out.isCharging = true
                    out.timeToFullMinutes = prev
                    let h = prev / 60, r = prev % 60
                    out.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(prev)m"
                    addToAppLogsIfEnabled("⏳ Guard(push) — preserved minutes during BG/scene churn (prev=\(prev)m)")
                } else {
                    // If we have no previous minutes at all, prefer placeholder over dash
                    out.timeRemainingText = "…"
                    out.timeToFullMinutes = max(out.timeToFullMinutes, 2)
                    addToAppLogsIfEnabled("⏳ Guard(push) — placeholder used instead of dash during BG/scene churn")
                }
            }
        }
        // Map near/full state to a stable "Full" label so DI never sees 0m/— at the top
        applyFullLabelIfNeeded(&out)
        // Enforce the universal display contract right before update
   applyDisplayContract(
       &out,
       lastPushedMinutes: self.lastPushedDisplayMinutes ?? self.lastPushedMinutes,
       cachedMinutes: {
           let v = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
           return v > 0 ? v : nil
       }()
   )
        
        // During scene churn (esp. right after background), avoid dropping to 0/“—” while still charging.
        if out.isCharging && (out.timeToFullMinutes <= 1) {
            let recentlyGood = (lastGoodMetricsAt.map { Date().timeIntervalSince($0) < 18 } ?? false)
            if inDisplayBGGrace() || recentlyGood {
                if let prev = (self.lastPushedDisplayMinutes ?? self.lastPushedMinutes), prev > 1 {
                    // Reuse last good minutes to keep LA/DI stable
                    out.timeToFullMinutes = prev
                    if prev > 0 {
                        let h = prev / 60, r = prev % 60
                        out.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(prev)m"
                    }
                    addToAppLogsIfEnabled("⏳ Guard(push) — reused last good ETA \(prev)m during BG/scene churn")
                } else {
                    // Fall back to warmup placeholder if we have no prior minutes
                    out.timeRemainingText = "…"
                    out.timeToFullMinutes = max(out.timeToFullMinutes, 2)
                    addToAppLogsIfEnabled("⏳ Guard(push) — warmup placeholder during BG/scene churn")
                }
            }
        }
      // Final fail-safe: never allow a dash while charging; prefer "Full" at high SoC
      if out.isCharging {
          let trimmed = out.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines)
          let looksDashed = trimmed.isEmpty || trimmed == "—" || trimmed == "0m"
          if out.soc >= 99 && (out.watts < 1.0 || ChargeStateStore.shared.snapshot.state == .full) {
              out.timeRemainingText = "Full"
              out.timeToFullMinutes = 0
              out.expectedFullDate = nil
              addToAppLogsIfEnabled("🧩 Guard(push) — coerced to 'Full' at high SoC")
          } else if looksDashed {
              let m = max(2, out.timeToFullMinutes)
              let h = m / 60, r = m % 60
              out.timeToFullMinutes = m
              out.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
              addToAppLogsIfEnabled("🧩 Guard(push) — synthesized minutes to avoid dash label")
          }
      }
        // Additional guard: always clear any anchor so LA/DI mirrors the in-app label exactly
        if out.expectedFullDate != nil {
            addToAppLogsIfEnabled("🚧 Guard(push) — clearing expectedFullDate to keep static minutes")
            out.expectedFullDate = nil
        }
        addToAppLogsIfEnabled("🔎 LA mid-push — text='\(out.timeRemainingText)' eta=\(out.timeToFullMinutes)m")
        addToAppLogsIfEnabled("🟨 LA compose (local) — watts=\(String(format: "%.1f", out.watts))W eta=\(out.timeToFullMinutes)m")
        let targets = Activity<PETLLiveActivityAttributes>.activities
        guard !targets.isEmpty else {
            addToAppLogsIfEnabled("⏭️ No active activities — skipped LA push")
            return
        }
        for activity in targets {
            var safe = out

            // --- FINAL FAIL-SAFE: if charging but no valid label/minutes, synthesize numeric fallback
            if safe.isCharging {
                let trimmed = safe.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines)
                let empty = trimmed.isEmpty || trimmed == "—"
                if empty || safe.timeToFullMinutes <= 0 {
                    var m = safe.timeToFullMinutes
                    if m <= 0 {
                        // Try cached ETA first
                        m = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
                    }
                    if m <= 0 {
                        // Try cached pct/min rate (same logic as analytics fallback)
                        let rate = UserDefaults.standard.double(forKey: "petl.lastRatePctPerMin")
                        if rate > 0 {
                            let rem = max(0, 100 - safe.soc)
                            m = max(2, Int(ceil(Double(rem) / rate)))
                        }
                    }
                    if m <= 0 {
                        // Conservative baseline (1%/min)
                        let rem = max(0, 100 - safe.soc)
                        m = max(2, rem)
                    }
                    safe.timeToFullMinutes = m
                    let h = m / 60, r = m % 60
                    safe.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
                }
            }

            if safe.isCharging && safe.timeToFullMinutes <= 0 {
                // Belt and suspenders: keep UI consistent during the first frames of warmup.
                safe.timeRemainingText = "…"
            }
            // Ensure static, fully-formed label with no countdown anchor for each activity
            forceStaticDisplay(&safe)
            let content = ActivityContent(state: safe, staleDate: Date().addingTimeInterval(600))
            // Insert diagnostic log before updating activity
            addToAppLogsIfEnabled("📤 LA push final — '\(safe.timeRemainingText)' (\(safe.timeToFullMinutes)m, \(String(format: "%.1f", safe.watts))W)")
            await activity.update(content)
            // ✅ Remote UPDATE — Vercel → OneSignal
            Task {
                await LiveActivityRemoteClient.update(
                    activityId: activity.id,
                    state: LiveActivityRemoteClient.ContentState(
                        soc: safe.soc,
                        watts: safe.watts,
                        timeToFullMinutes: safe.timeToFullMinutes,
                        isCharging: safe.isCharging
                    ),
                    ttlSeconds: 120
                )
            }
            if safe.timeToFullMinutes > 0 {
                self.lastDisplayedMinutes = safe.timeToFullMinutes
                self.lastDisplayedAt = Date()
            }
        }
        addToAppLogsIfEnabled("🔄 LA push — soc=\(out.soc)% watts=\(String(format: "%.1f", out.watts))W eta=\(out.timeToFullMinutes)m")
        self.lastContentState = out
        let message = "🔄 push level=\(out.soc)% rate=\(out.chargingRate) time=\(out.timeToFullMinutes) min"
        laLogger.info("\(message)")

        // Record the latest successful push timestamp
        lastPushedContentTimestamp = out.updatedAt

        // Track last good metrics to bridge brief gaps later
        if out.watts > 0 && out.timeToFullMinutes > 0 {
            lastGoodMetricsAt = Date()
        }
        // Piggyback a periodic power write tied to LA pushes
        self.piggybackPowerWrite("la-push")
    }
    
    @MainActor
    func pushUpdate(reason: String) async {
        guard !Activity<PETLLiveActivityAttributes>.activities.isEmpty else {
            addToAppLogsIfEnabled("📤 pushUpdate(\(reason)) - no activities to update")
            return
        }
        
        // Check if still charging - if not, end all activities
        let isCharging = ChargeStateStore.shared.isCharging
        if !isCharging {
        addToAppLogsIfEnabled("🔌 pushUpdate(\(reason)): not charging, ending activities")
            await endAll("not-charging")
            // Cancel background refresh since no activities remain
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.cancelRefresh()
                appDelegate.cancelProcessing()
            }
            self.cancelRefresh()
            self.cancelProcessing()
            return
        }
        
        var state = firstContent()
        state = normalizeForLiveActivity(state)
        await pushToAll(state)
        self.lastPushedDisplayMinutes = state.timeToFullMinutes
        addToAppLogsIfEnabled("📤 pushUpdate(\(reason)) - updated \(Activity<PETLLiveActivityAttributes>.activities.count) activities")
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
            watts: nil,
            ratePctPerMin: nil,
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
        addToAppLogsIfEnabled("🧯 Ending all Live Activities — reason=\(reason)")
        unplugWorkItem?.cancel(); unplugWorkItem = nil
        updatesBlocked = true
        let capturedActivityIds = Activity<PETLLiveActivityAttributes>.activities.map { $0.id }
        addToAppLogsIfEnabled("📦 Captured \(capturedActivityIds.count) activity IDs for remote end")
        #if canImport(ActivityKit)
        for activity in Activity<PETLLiveActivityAttributes>.activities {
            // Preserve last shown label/minutes so the system doesn't render a dash before dismissal
            var preserved = activity.content.state
            preserved.updatedAt = Date()
            preserved.isCharging = false
            preserved.expectedFullDate = nil
            let finalContent = ActivityContent(state: preserved, staleDate: nil)
            await activity.update(finalContent)
            await activity.end(finalContent, dismissalPolicy: .immediate)
            addToAppLogsIfEnabled("✅ LA end OK id=\(activity.id.prefix(6))")
        }
        #endif

        // 🚀 Remote END — Vercel → OneSignal using captured IDs
        for activityId in capturedActivityIds {
            Task { await LiveActivityRemoteClient.end(activityId: activityId, immediate: true) }
        }

        // ✅ Remote END — OneSignal direct call (works in DEBUG, production relies on Vercel)
        // Use captured IDs instead of activities list (which may be empty after local end)
        for activityId in capturedActivityIds {
            OneSignalClient.shared.endLiveActivityRemote(activityId: activityId)
        }

        // Retry until gone (1s, 3s, 7s), then give up
        let backoff: [UInt64] = [1, 3, 7].map { UInt64($0) * 1_000_000_000 }
        for delay in backoff {
            try? await Task.sleep(nanoseconds: delay)
            let remaining = Activity<PETLLiveActivityAttributes>.activities.count
            addToAppLogsIfEnabled("🧪 endAll() verification: remaining=\(remaining)")
            if remaining == 0 {
                addToAppLogsIfEnabled("✅ endAll() successful - all activities ended")
                break
            }
        }

        // Failsafe: if still present, push a final "not charging" update and stale it out
        let finalActivities = Activity<PETLLiveActivityAttributes>.activities
        if !finalActivities.isEmpty {
            addToAppLogsIfEnabled("⚠️ endAll() failsafe: \(finalActivities.count) activities still present, marking as stale")
            for act in finalActivities {
                var s = act.content.state
                s.isCharging = false
                // Preserve the last numeric label/minutes; do not zero-out to avoid a dash
                s.expectedFullDate = nil
                // Mark as stale so the system deprioritizes it immediately
                let updatedContent = ActivityContent(state: s, staleDate: Date(), relevanceScore: 0)
                await act.update(updatedContent)
                addToAppLogsIfEnabled("✅ Final stale update sent for \(act.id)")
                // Try ending immediately after stale update
                await act.end(updatedContent, dismissalPolicy: .immediate)
                addToAppLogsIfEnabled("✅ Final end attempt for \(act.id)")
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

        addToAppLogsIfEnabled("🛑 Activity ended - source: \(reason)")

        // Cancel background refresh since no activities remain
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.cancelRefresh()
            appDelegate.cancelProcessing()
        }
        self.cancelRefresh()
        self.cancelProcessing()
        dumpActivities("afterEnd")
        addToAppLogsIfEnabled("🧪 post-end activities: \(Activity<PETLLiveActivityAttributes>.activities.map{ $0.id }.joined(separator: ","))")
    }
    
    private func cancelFailsafeTask() {
        // Implementation for canceling failsafe task
    }
    
    func firstContent() -> PETLLiveActivityAttributes.ContentState {
        var raw = SnapshotToLiveActivity.currentContent()
        // Guard: if SSOT says charging or watts > 0, force charging to avoid "—" on first frame
        if !raw.isCharging && (ChargeStateStore.shared.isCharging || raw.watts > 0.2) {
            raw.isCharging = true
            addToAppLogsIfEnabled("🧲 Guard(firstContent) — forced isCharging=true (w=\(String(format: "%.1f", raw.watts))W, store=\(ChargeStateStore.shared.isCharging))")
        }
        normalizeOneMinuteSpike(&raw)
        applyFullLabelIfNeeded(&raw)
        // Warm-start: override minutes/label during the first few minutes after start
        if inWarmStartWindow(), raw.isCharging {
            let wm = warmStartMinutesFallback()
            raw.timeToFullMinutes = max(2, wm)
            let h = wm / 60, r = wm % 60
            raw.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(wm)m"
            raw.expectedFullDate = nil
            addToAppLogsIfEnabled("🟩 Warm-start seed (firstContent) — ETA=\(wm)m")
        }
        // Seed from last good metrics to avoid '—' on first frame while charging
        if raw.isCharging {
            if raw.timeToFullMinutes <= 0 {
                let cachedEta = UserDefaults.standard.integer(forKey: "petl.lastEtaMin")
                if cachedEta > 1 {
                    raw.timeToFullMinutes = cachedEta
                    let h = cachedEta / 60, r = cachedEta % 60
                    raw.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(cachedEta)m"
                }
            }
            if raw.watts <= 0 {
                let isCharging = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
                let systemPct = Int((UIDevice.current.batteryLevel * 100).rounded())

                if isCharging {
                    // 1) Prefer live estimator watts during warm-up
                    let liveWatts = BatteryTrackingManager.shared.currentWatts
                    if liveWatts.isFinite && liveWatts > 0 {
                        raw.watts = liveWatts
                        BatteryTrackingManager.shared.addToAppLogs("🔥 Using live estimator watts=\(String(format: "%.1f", liveWatts))W for firstContent")
                    } else {
                        // 2) Smart baseline by SoC: 10W below 80%, 5W at/above 80% (trickle)
                        if systemPct >= 80 {
                            raw.watts = 5.0
                            BatteryTrackingManager.shared.addToAppLogs("🔥 Using 5W trickle baseline for firstContent (soc=\(systemPct)% ≥ 80%)")
                        } else {
                            raw.watts = 10.0
                            BatteryTrackingManager.shared.addToAppLogs("🔥 Using 10W warm-up baseline for firstContent (soc=\(systemPct)% < 80%)")
                        }
                    }
                }
                else {
                    // Not charging — try cached watts, else 0
                    let cachedW = UserDefaults.standard.double(forKey: "petl.lastWatts")
                    if cachedW.isFinite && cachedW > 0 {
                        raw.watts = cachedW
                    } else {
                        raw.watts = 0.0
                    }
                }
            }
            if raw.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if raw.timeToFullMinutes > 0 {
                    let m = raw.timeToFullMinutes
                    let h = m / 60, r = m % 60
                    raw.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
                } else {
                    raw.timeRemainingText = "…"
                }
            }
            // Seed display strings on first frame
            if raw.isCharging {
                let wattStr = (raw.watts > 0) ? String(format: "%.1fW", raw.watts) : ""
                if raw.estimatedWattage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || raw.estimatedWattage == "—" {
                    raw.estimatedWattage = wattStr
                }
                let ssotRate = ChargeStateStore.shared.snapshot.ratePctPerMin ?? 0
                if raw.chargingRate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || raw.chargingRate == "—" {
                    raw.chargingRate = (ssotRate > 0) ? String(format: "%.2f%%/min", ssotRate) : ""
                }
            }
        }
        // --- FAIL-SAFE in firstContent(): if charging but no numeric label/minutes, synthesize before return
        if raw.isCharging {
            let trimmed = raw.timeRemainingText.trimmingCharacters(in: .whitespacesAndNewlines)
            let empty = trimmed.isEmpty || trimmed == "—"
            if empty || raw.timeToFullMinutes <= 0 {
                var m = raw.timeToFullMinutes
                if m <= 0 { m = UserDefaults.standard.integer(forKey: "petl.lastEtaMin") }
                if m <= 0 {
                    let rate = UserDefaults.standard.double(forKey: "petl.lastRatePctPerMin")
                    if rate > 0 {
                        let rem = max(0, 100 - raw.soc)
                        m = max(2, Int(ceil(Double(rem) / rate)))
                    }
                }
                if m <= 0 {
                    let rem = max(0, 100 - raw.soc)
                    m = max(2, rem)
                }
                raw.timeToFullMinutes = m
                let h = m / 60, r = m % 60
                raw.timeRemainingText = (h > 0) ? "\(h)h \(r)m" : "\(m)m"
            }
        }
        // Seed sticky minutes on first-frame if we already have a numeric ETA
        if raw.timeToFullMinutes > 0 {
            self.lastDisplayedMinutes = raw.timeToFullMinutes
            self.lastDisplayedAt = Date()
        }
        forceStaticDisplay(&raw)
        lastContentState = raw
        if raw.watts > 0 && raw.timeToFullMinutes > 0 { lastGoodMetricsAt = Date() }
        addToAppLogsIfEnabled("📤 firstContent final — '\(raw.timeRemainingText)' (\(raw.timeToFullMinutes)m, \(String(format: "%.1f", raw.watts))W)")
        addToAppLogsIfEnabled("🧰 firstContent() → clamped ETA=\(raw.timeToFullMinutes)m text='\(raw.timeRemainingText)' (countdown anchor cleared)")
        return raw
    }
    
    private func updateWithCurrentBatteryData() {
        // Use SSOT mapper to get content from current snapshot
        var contentState = SnapshotToLiveActivity.currentContent()
        normalizeOneMinuteSpike(&contentState)
        // Enforce static display before pushing updates
        Task { @MainActor in
            var safe = contentState
            safe = normalizeForLiveActivity(safe)
            forceStaticDisplay(&safe)
            for activity in Activity<PETLLiveActivityAttributes>.activities {
                let content = ActivityContent(state: safe, staleDate: Date().addingTimeInterval(600))
                await activity.update(content)
            }
            os_log("✅ Live Activity updated with SSOT snapshot data (static)")
        }
    }
    
    private func ensureBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }
    // MARK: - BG Preflight
    private func canSubmitBG(identifier: String) -> Bool {
        // Check Info.plist permits this identifier
        let permitted = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]) ?? []
        if !permitted.contains(identifier) {
            addToAppLogsIfEnabled("🚫 BG submit blocked — identifier not permitted in Info.plist: \(identifier)")
            return false
        }
        // Ensure registration happened (guarded internally)
        if !Self.didRegisterBG {
            addToAppLogsIfEnabled("ℹ️ BG submit requested before registration; registering now")
            registerBGTask()
        }
        return true
    }
    // MARK: - Background Scheduling Helpers
    func scheduleRefresh(in minutes: Int) {
        // CRITICAL: Always ensure registration before scheduling to prevent crashes
        // Even if flag says registered, it might be stale, so we need to verify
        // But we can't re-register if already registered (crashes), so we check flag first
        // If flag is not set, register now. If flag is set but registration is stale,
        // we'll catch the error and re-register.
        if !Self.didRegisterBG && !UserDefaults.standard.bool(forKey: Self.laRegistrationKey) {
            addToAppLogsIfEnabled("⚠️ LA BG refresh schedule called before registration — registering now")
            registerBGTask()
            // Give registration a moment to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.scheduleRefresh(in: minutes)
            }
            return
        }
        
        guard canSubmitBG(identifier: refreshTaskId) else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        do {
            try BGTaskScheduler.shared.submit(req)
            bgRefreshScheduled = true
            addToAppLogsIfEnabled("✅ BG refresh scheduled in \(minutes)m")
        } catch {
            // Check if error indicates handler not registered (stale flag case)
            let errorDesc = error.localizedDescription.lowercased()
            if errorDesc.contains("no launch handler") || errorDesc.contains("not registered") || errorDesc.contains("not permitted") {
                addToAppLogsIfEnabled("⚠️ Stale LA BG registration detected — clearing flag and retrying")
                Self.didRegisterBG = false
                UserDefaults.standard.set(false, forKey: Self.laRegistrationKey)
                // Retry registration
                registerBGTask()
                // Retry submission after a short delay to ensure registration completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    do {
                        try BGTaskScheduler.shared.submit(req)
                        self.bgRefreshScheduled = true
                        addToAppLogsIfEnabled("✅ BG refresh scheduled after stale flag recovery")
                    } catch {
                        addToAppLogsIfEnabled("❌ BG refresh schedule failed after retry: \(error.localizedDescription)")
                    }
                }
            } else {
                addToAppLogsIfEnabled("❌ BG refresh schedule failed: \(error.localizedDescription)")
            }
        }
    }
    
    func cancelRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskId)
        bgRefreshScheduled = false
        addToAppLogsIfEnabled("🪵 BG refresh canceled")
    }

    func scheduleProcessing(in minutes: Int) {
        // CRITICAL: Always ensure registration before scheduling to prevent crashes
        // Even if flag says registered, it might be stale, so we need to verify
        // But we can't re-register if already registered (crashes), so we check flag first
        // If flag is not set, register now. If flag is set but registration is stale,
        // we'll catch the error and re-register.
        if !Self.didRegisterBG && !UserDefaults.standard.bool(forKey: Self.laRegistrationKey) {
            addToAppLogsIfEnabled("⚠️ LA BG processing schedule called before registration — registering now")
            registerBGTask()
            // Give registration a moment to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.scheduleProcessing(in: minutes)
            }
            return
        }
        
        guard canSubmitBG(identifier: processingTaskId) else { return }
        let req = BGProcessingTaskRequest(identifier: processingTaskId)
        req.earliestBeginDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        req.requiresExternalPower = false
        req.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(req)
            bgProcessingScheduled = true
            addToAppLogsIfEnabled("✅ BG processing scheduled in \(minutes)m")
        } catch {
            // Check if error indicates handler not registered (stale flag case)
            let errorDesc = error.localizedDescription.lowercased()
            if errorDesc.contains("no launch handler") || errorDesc.contains("not registered") || errorDesc.contains("not permitted") {
                addToAppLogsIfEnabled("⚠️ Stale LA BG registration detected — clearing flag and retrying")
                Self.didRegisterBG = false
                UserDefaults.standard.set(false, forKey: Self.laRegistrationKey)
                // Retry registration
                registerBGTask()
                // Retry submission after a short delay to ensure registration completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    do {
                        try BGTaskScheduler.shared.submit(req)
                        self.bgProcessingScheduled = true
                        addToAppLogsIfEnabled("✅ BG processing scheduled after stale flag recovery")
                    } catch {
                        addToAppLogsIfEnabled("❌ BG processing schedule failed after retry: \(error.localizedDescription)")
                    }
                }
            } else {
                addToAppLogsIfEnabled("❌ BG processing schedule failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelProcessing() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskId)
        bgProcessingScheduled = false
        addToAppLogsIfEnabled("🪵 BG processing canceled")
    }

    /// Called by BG tasks; pushes if last push is stale or metrics changed.
    private func updateIfStale(reason: String) async {
        let now = Date()
        let stale = (lastPush == nil) || now.timeIntervalSince(lastPush!) >= 300 // 5 min
        let snapshot = ChargeStateStore.shared.snapshot
        let eta = snapshot.etaMinutes ?? 0
        let soc = snapshot.socPercent
        let etaChanged = (lastRichState?.timeToFullMinutes ?? -1) != eta
        let socMoved   = (lastRichState?.soc ?? -1) != soc
        if stale || etaChanged || socMoved {
            await pushUpdate(reason: reason)
        } else {
            addToAppLogsIfEnabled("⏸️ BG tick — no meaningful change (\(reason))")
        }
    }
    // MARK: - Public BG Registration
    /// Public wrapper to ensure BG tasks are registered before any scheduling.
    @MainActor
    func registerBackgroundTasks() {
        registerBGTask()
    }

    @available(*, deprecated, message: "Use registerBackgroundTasks()")
    @MainActor
    func ensureBGRegisteredPublic() {
        registerBackgroundTasks()
    }

    private func registerBGTask() {
        let defaults = UserDefaults.standard
        
        // CRITICAL: Use barrier queue to prevent concurrent registrations (BGTaskScheduler crashes if called concurrently)
        Self.laRegistrationQueue.sync(flags: .barrier) {
            // Prevent concurrent registration attempts
            if Self.isRegisteringBG {
                addToAppLogsIfEnabled("⚠️ LA BG register — registration already in progress, skipping")
                return
            }
            
            let wasRegistered = Self.didRegisterBG || defaults.bool(forKey: Self.laRegistrationKey)
            if wasRegistered {
                addToAppLogsIfEnabled("♻️ LA BG register — flag indicates registered, verifying with BGTaskScheduler...")
            }
            
            // Mark as registering BEFORE calling BGTaskScheduler to prevent race conditions
            Self.isRegisteringBG = true
            defer { Self.isRegisteringBG = false }
            
            // IMPORTANT: We attempt registration even if the flag says "registered" because:
            // 1. The flag can be stale (e.g., after app reinstall, iOS clears registrations but flag persists)
            // 2. BGTaskScheduler.register() returns true if already registered (safe, no crash)
            // 3. Only if registration fails (returns false) do we clear the flag
            // NOTE: If already registered with the same closure instance, register() returns true safely.
            // If registered with a different closure, it will crash, but that shouldn't happen if we
            // always use the same code path (which we do).
            
            // CRITICAL: Set registration flag BEFORE calling BGTaskScheduler.register() to prevent race conditions
            // If another thread calls this method while we're registering, it will see the flag and skip
            Self.didRegisterBG = true
            defaults.set(true, forKey: Self.laRegistrationKey)
            
            // WARNING: BGTaskScheduler.register() will CRASH if called multiple times with the same identifier
            // even if the handler closures are functionally identical (Swift creates new closure instances)
            // That's why we check the flag above and set it before registration
            let refreshRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            task.expirationHandler = { addToAppLogsIfEnabled("⏳ BG refresh expired"); task.setTaskCompleted(success: false) }
            Task { @MainActor in
                self.beginBG("petl.la.bg-refresh")
                UIDevice.current.isBatteryMonitoringEnabled = true
                // Check system battery state directly to avoid stale SSOT state after extended periods
                let currentBatteryState = UIDevice.current.batteryState
                let isCurrentlyCharging = (currentBatteryState == .charging || currentBatteryState == .full)
                
                if isCurrentlyCharging && self.hasLiveActivity {
                    // ✅ Trigger fresh analytics calculation before LA update
                    BatteryTrackingManager.shared.performBackgroundCalculationTick()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.updateIfStale(reason: "bg-refresh")
                } else if !isCurrentlyCharging && self.hasLiveActivity {
                    await self.endAll("bg-refresh-not-charging")
                }
                // Only reschedule if actually charging (reuse system state check from above)
                // Do NOT use hasLiveActivity as fallback - if LA exists but not charging, it should end
                if isCurrentlyCharging {
                    self.scheduleRefresh(in: 20) // keep heartbeat going
                } else {
                    self.cancelRefresh()
                    // If LA still exists but not charging, end it
                    if self.hasLiveActivity {
                        Task { @MainActor in
                            await self.endAll("bg-refresh-not-charging-system")
                        }
                    }
                }
                self.endBG()
                task.setTaskCompleted(success: true)
            }
        }

        let processingRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            task.expirationHandler = { addToAppLogsIfEnabled("⏳ BG processing expired"); task.setTaskCompleted(success: false) }
            Task { @MainActor in
                self.beginBG("petl.la.bg-processing")
                UIDevice.current.isBatteryMonitoringEnabled = true
                // Check system battery state directly to avoid stale SSOT state after extended periods
                let currentBatteryState = UIDevice.current.batteryState
                let isCurrentlyCharging = (currentBatteryState == .charging || currentBatteryState == .full)
                
                if isCurrentlyCharging && self.hasLiveActivity {
                    // ✅ Trigger fresh analytics calculation before LA update
                    BatteryTrackingManager.shared.performBackgroundCalculationTick()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.updateIfStale(reason: "bg-processing")
                } else if !isCurrentlyCharging && self.hasLiveActivity {
                    // Not charging but LA still exists - end it
                    await self.endAll("bg-processing-not-charging")
                }
                // Only reschedule if actually charging (reuse system state check from above)
                // Do NOT use hasLiveActivity as fallback - if LA exists but not charging, it should end
                if isCurrentlyCharging {
                    self.scheduleProcessing(in: 45) // Space out next processing window
                } else {
                    self.cancelProcessing()
                    // If LA still exists but not charging, end it
                    if self.hasLiveActivity {
                        Task { @MainActor in
                            await self.endAll("bg-processing-not-charging-system")
                        }
                    }
                }
                self.endBG()
                task.setTaskCompleted(success: true)
            }
        }

        let cleanupRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: cleanupTaskId,
            using: nil
        ) { task in
            self.handleFailsafeTask(task as! BGProcessingTask)
        }

            // Verify all registrations succeeded
            let allRegistered = refreshRegistered && processingRegistered && cleanupRegistered
            if allRegistered {
                // All tasks registered successfully
                os_log("✅ LA background tasks registered (%{public}@, %{public}@, %{public}@)", refreshTaskId, processingTaskId, cleanupTaskId)
                LA_log("✅ LA BG handlers registered — refresh + processing + cleanup")
            } else {
                // Registration failed - clear flags so we can retry next launch
                Self.didRegisterBG = false
                defaults.set(false, forKey: Self.laRegistrationKey)
                os_log("❌ LA BG task registration failed (refresh: %d, processing: %d, cleanup: %d)", refreshRegistered, processingRegistered, cleanupRegistered)
                LA_log("❌ LA BG task registration failed")
                LA_log("⚠️ Cleared LA registration flag — will retry next launch")
            }
        }
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
        let request = BGProcessingTaskRequest(identifier: cleanupTaskId)
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
        
        addToAppLogsIfEnabled("📤 Live Activity Push Token: \(hex.prefix(20))...")
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
    
    private func currentPctPerMinuteOrNil() -> Double? { return nil }
}


