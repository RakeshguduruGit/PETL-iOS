import Foundation
import Combine
import UIKit
import SwiftUI
import os.log

// Import ChargeEstimator for power calculations

// MARK: - Battery Snapshot Model
struct BatterySnapshot {
    let level: Float          // 0.0–1.0
    let isCharging: Bool
    let timestamp: Date
}

// MARK: - Battery Data Point Model
struct BatteryDataPoint: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let batteryLevel: Float
    let isCharging: Bool
    
    init(batteryLevel: Float, isCharging: Bool) {
        self.timestamp = Date()
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
    }
    
    init(batteryLevel: Float, isCharging: Bool, timestamp: Date) {
        self.timestamp = timestamp
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
    }
}

// MARK: - Power Sample Model
struct PowerSample: Identifiable {
    let id = UUID()
    let time: Date
    let watts: Double
    let isCharging: Bool
    
    init(watts: Double, isCharging: Bool) {
        self.time = Date()
        self.watts = watts
        self.isCharging = isCharging
    }
    
    init(time: Date, watts: Double, isCharging: Bool) {
        self.time = time
        self.watts = watts
        self.isCharging = isCharging
    }
}

// MARK: - Charging Session Model
struct ChargingSession: Identifiable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let startPercentage: Int
    let endPercentage: Int

    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }
}

// MARK: - Battery Tracking Manager
@MainActor
final class BatteryTrackingManager: ObservableObject {
    static let shared = BatteryTrackingManager()

    // Published state for SwiftUI
    @Published private(set) var level: Float = 0
    @Published private(set) var isCharging: Bool = false

    // Snapshot bus for non-UI consumers (e.g., LiveActivityManager)
    let snapshotSubject = PassthroughSubject<BatterySnapshot, Never>()

    // Lifecycle
    private var isMonitoring = false
    private var cancellables = Set<AnyCancellable>()

    // Legacy data tracking (keep existing functionality)
    @Published var batteryDataPoints: [BatteryDataPoint] = []
    @Published var selectedTimeRange: TimeRange = .day
    @Published var hasActiveWidget: Bool = false
    
    // Power tracking for charging power chart
    @Published var powerSamples: [PowerSample] = []
    
    // MARK: Power sampling
    private let powerSampleInterval: TimeInterval = 30
    private var powerTimer: Timer?
    
    // MARK: - Charging Rate Estimator
    private var rateEstimator: ChargingRateEstimator?
    private var historyStore = ChargingHistoryStore()
    private var sessionActive = false
    private var wasCharging = false
    
    // MARK: - Smooth analytics (Phase 1.8)
    private var smoother: SafeChargingSmoother?
    private var lastSmoothedOut: SafeChargingSmoother.Output?
    private var pauseCtl = ChargePauseController()
    private var lastPauseFlag = false
    private var lastDisplayed: (watts: Double, etaMin: Int?) = (0, nil)
    private var lastTick: Date?
    
    // Phase 2.5: Stable values for freezing
    private var lastStableETA: Int?
    private var lastStableW: Double?
    
    // MARK: - Lockdown patch variables
    private var wroteWarmupThisSession = false
    private var lastPersistedPowerTs: Date?
    private var stateChangeWorkItem: DispatchWorkItem?
    private var currentSessionId: UUID?
    
    // MARK: - Rate-limited logging
    private var lastLogTime = Date.distantPast
    
    // MARK: - Tick Token for Presentation Idempotency
    private(set) var tickSeq: UInt64 = 0
    var tickToken: String { String(tickSeq) }   // public, read-only
    
    // MARK: - Unplug Debounce Generation Tracking
    private var unplugGen: UInt64 = 0            // generation to cancel stale tasks
    private var unplugDebounceTask: Task<Void, Never>? = nil
    
    // ===== BEGIN STABILITY-LOCKED: Percent-step foreground logger (do not edit) =====
    private var lastLoggedBucket: Int = -1
    private var lastLoggedAt: Date = .distantPast
    private var forceSocPersistNext: Bool = false
    // ===== BEGIN STABILITY-LOCKED: Foreground SoC atomic persist (do not edit) =====
    private var pendingForcedSocPct: Int?
    // ===== END STABILITY-LOCKED: Foreground SoC atomic persist =====
    // ===== END STABILITY-LOCKED: Percent-step foreground logger =====
    
    // MARK: - Charging Session Tracking
    private var currentSessionStartTime: Date?
    private var currentSessionStartPercentage: Int?
    

    
    // Public accessor for current smoothed watts (for Live Activity)
    var currentWatts: Double {
        if FeatureFlags.smoothChargingAnalytics, let w = ChargeEstimator.shared.current?.watts {
            return w
        }
        return lastDisplayed.watts
    }
    
    // MARK: - DB Reading Helpers for Charts
    
    // Forward-fill resampler to prevent chart area collapse between sparse points
    private struct _SocSample {
        let ts: Date
        let percent: Int
        let quality: String?
    }
    
    private func _resampleForwardFill(_ points: [_SocSample], every minutes: Int = 10) -> [_SocSample] {
        guard !points.isEmpty else { return [] }
        let sorted = points.sorted { $0.ts < $1.ts }

        var out: [_SocSample] = []
        var cur = sorted.first!.ts
        let end = sorted.last!.ts
        var idx = 0
        var last = sorted.first!

        while cur <= end {
            while idx + 1 < sorted.count, sorted[idx + 1].ts <= cur {
                idx += 1
                last = sorted[idx]
            }
            out.append(_SocSample(ts: cur, percent: max(0, last.percent), quality: last.quality))
            cur = cur.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return out
    }
    
    func historyPointsFromDB(hours: Int = 24) -> [BatteryDataPoint] {
        let to = Date()
        let from = to.addingTimeInterval(-TimeInterval(hours * 3600))
        let rows = ChargeDB.shared.range(from: from, to: to)
        
        // Filter out legacy zeros (only for 'present') to avoid dips
        let cleaned: [ChargeRow] = rows.filter { row in
            if let src = row.src, src == "present" {
                return row.soc > 0
            }
            return true
        }

        // Forward-fill resample every 10 minutes to avoid baseline collapse
        let resampled = _resampleForwardFill(
            cleaned.map { _SocSample(ts: Date(timeIntervalSince1970: $0.ts), percent: $0.soc, quality: $0.src) },
            every: 10
        )

        // Map back to BatteryDataPoint model used by the chart
        var points = resampled.map { sample in
            BatteryDataPoint(
                batteryLevel: Float(sample.percent) / 100.0,  // Normalized to 0.0-1.0 for charts
                isCharging: true,  // We're in charging context
                timestamp: sample.ts
            )
        }
        
        // ===== BEGIN STABILITY-LOCKED: Render-time tail anchor (do not edit) =====
        // Chart tail anchor: fill-forward the last non-zero point up to 5 minutes to prevent momentary no-data drops
        if let last = points.last {
            let now = Date()
            if now.timeIntervalSince(last.timestamp) <= 5*60, last.batteryLevel > 0 {
                points.append(BatteryDataPoint(
                    batteryLevel: last.batteryLevel,
                    isCharging: last.isCharging,
                    timestamp: now
                ))
                addToAppLogs("🪢 Tail anchor added — carry last value \(last.batteryLevel) for \(Int(now.timeIntervalSince(last.timestamp)))s")
            }
        }
        // ===== END STABILITY-LOCKED: Render-time tail anchor =====
        
        return points
    }
    
    // Optional: trim log spam so Xcode doesn't choke
    private var lastPowerQueryCount = 0
    private var lastPowerQueryTime: Date?
    
    func powerSamplesFromDB(hours: Int = 24) -> [PowerSample] {
        let to = Date()
        let from = to.addingTimeInterval(-TimeInterval(hours * 3600))
        let rows = ChargeDB.shared.range(from: from, to: to)

        let samples: [PowerSample] = rows.compactMap { r in
            guard let w = r.watts else { return nil }
            return PowerSample(time: Date(timeIntervalSince1970: r.ts),
                               watts: w,
                               isCharging: r.isCharging)
        }

        // Only log when either count or last timestamp changes
        if samples.count != lastPowerQueryCount || samples.last?.time != lastPowerQueryTime {
            if let last = samples.last {
                addToAppLogs("📈 Power query \(hours)h — \(samples.count) rows · last=\(String(format:"%.1fW", last.watts)) @\(last.time)")
            } else {
                addToAppLogs("📈 Power query \(hours)h — 0 rows")
            }
            lastPowerQueryCount = samples.count
            lastPowerQueryTime = samples.last?.time
        }
        return samples
    }
    
    @MainActor func resetForSessionChange() {
        tickSeq = 0
    }


    private let userDefaults = UserDefaults.standard
    private let batteryDataKey = "PETLBatteryTrackingData"
    private let maxDataDays = 30
    private var dataRecordingTimer: Timer?
    
    // Single source of truth publisher (legacy)
    private let subject = PassthroughSubject<BatterySnapshot, Never>()
    var publisher: AnyPublisher<BatterySnapshot, Never> { subject.eraseToAnyPublisher() }
    
    private var timer: Timer?
    private var lastBatteryState: UIDevice.BatteryState = .unknown
    private var lastStateChangeTime: Date = Date()
    private var pendingEnd: DispatchWorkItem?
    
    // MARK: - Diagnostics
    private let debugToken: Substring

    enum TimeRange: String, CaseIterable {
        case day = "24h"
        case week = "7d"
        case month = "30d"
        
        var title: String {
            switch self {
            case .day: return "24h"
            case .week: return "7d"
            case .month: return "30d"
            }
        }
        
        var hours: Int {
            switch self {
            case .day: return 24
            case .week: return 24 * 7
            case .month: return 24 * 30
            }
        }
    }

    // MARK: - Logging
    private static let tsFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = .init(identifier: .gregorian)
        f.locale   = .init(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    @inline(__always)
    private func logSec(_ emoji: String, _ msg: String, now: Date = Date()) {
        addToAppLogs("\(emoji) \(Self.tsFmt.string(from: now)) \(msg)")
    }

    private init() {
        // Each launch gets its own random token so we can see *who* prints warm-up.
        debugToken = UUID().uuidString.prefix(4)
        print("⚠️ NEW BatteryTrackingManager \(debugToken)")   // system console
        addToAppLogs("⚠️ NEW BatteryTrackingManager \(debugToken)")  // Info tab
        print("⚠️ NEW BatteryTrackingManager", ObjectIdentifier(self))
        
        loadBatteryData()
        setupBatteryMonitoring()
        startContinuousDataRecording()
        
        // Set up single source of truth publisher
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil)

        /// 30 s cadence – cheap enough for UI, matches LA throttle.
        timer = Timer.scheduledTimer(timeInterval: 30,
                                     target: self,
                                     selector: #selector(batteryChanged),
                                     userInfo: nil,
                                     repeats: true)
        batteryChanged()                                // fire first snapshot
        
        // Record initial battery data immediately on app launch
        recordBatteryData()
        print("📊 Battery Tracking: Initial data point recorded on app launch")
        print("⏱️ [\(debugToken)] 5-minute warm-up period enabled")
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Enable before any reads
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // NEW: trim old data on launch
        ChargeDB.shared.trim(olderThanDays: 30)

        // Set valid initial values BEFORE publishing
        self.level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        self.isCharging = (state == .charging || state == .full)

        // Emit initial snapshot immediately (handles "already plugged in" launch)
        let initial = BatterySnapshot(level: self.level,
                                      isCharging: self.isCharging,
                                      timestamp: Date())
        snapshotSubject.send(initial)

        // Use Combine publishers (main-thread delivery guaranteed)
        let statePub = NotificationCenter.default.publisher(
            for: UIDevice.batteryStateDidChangeNotification
        )
        let levelPub = NotificationCenter.default.publisher(
            for: UIDevice.batteryLevelDidChangeNotification
        )

        statePub
            .merge(with: levelPub)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let lvl = UIDevice.current.batteryLevel
                let st = UIDevice.current.batteryState
                let charging = (st == .charging || st == .full)

                self.level = lvl
                self.setChargingState(charging)  // Use hysteresis instead of direct assignment
                self.snapshotSubject.send(
                    BatterySnapshot(level: lvl, isCharging: charging, timestamp: Date())
                )
            }
            .store(in: &cancellables)
    }
    
    /// Emits a fresh snapshot immediately (bypasses debounce)
    func emitSnapshotNow(_ reason: String) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        let lvl = UIDevice.current.batteryLevel
        let st = UIDevice.current.batteryState
        let charging = (st == .charging || st == .full)
        
        self.level = lvl
        self.isCharging = charging
        
        let snap = BatterySnapshot(level: lvl, isCharging: charging, timestamp: Date())
        snapshotSubject.send(snap)
        
        addToAppLogs("📊 Battery Snapshot: \(Int(lvl * 100))%, State: \(st.rawValue) (\(reason))")
    }
    
    // MARK: - Legacy Power Calculation (for comparison)
    private func legacyCurrentWattage() -> Double {
        // Simple fallback calculation
        return ChargeEstimator.shared.current?.watts ?? 10.0
    }

    // MARK: - Smooth Analytics Helpers
    private func ensureSmoothingSession(isChargingNow: Bool, systemPct: Int, now: Date) {
        guard FeatureFlags.smoothAnalyticsP1 else { return }
        if isChargingNow && smoother == nil {
            let mAh = getDeviceBatteryCapacity()
            let s = SafeChargingSmoother(capacitymAh: mAh)
            s.begin(systemPercent: systemPct, now: now)
            smoother = s
            logSec("🔌", "Charge begin — warmup (10W) started", now: now)
        } else if !isChargingNow && smoother != nil {
            smoother?.end(now: now)
            smoother = nil
            lastSmoothedOut = nil
            lastPauseFlag = false
            logSec("🛑", "Charge end — estimator cleared", now: now)
        }
    }

    private func tickSmoothingAndPause(isChargingNow: Bool, systemPct: Int, now: Date) {
        // Notify the new estimator of battery level changes
        if FeatureFlags.smoothChargingAnalytics, isChargingNow {
            ChargeEstimator.shared.noteBattery(levelPercent: systemPct, at: now)
        }
        
        guard FeatureFlags.smoothAnalyticsP1, let s = smoother, isChargingNow else { return }
        
        // Increment tick sequence for presentation idempotency
        tickSeq &+= 1

        // Run smoother tick
        let out = s.tick(systemPercent: systemPct, isCharging: true, now: now)
        lastSmoothedOut = out
        
        // Update tick time for dt calculation
        let previousTick = lastTick
        lastTick = now

        // ---- Pause controller (anti-spike) ----
        // Add a "trickle spike" guard: watts <6W near 75–85% == suspect stall
        let suspectTrickle = (out.watts < 6.0) && (systemPct >= 75 && systemPct <= 85)

        let (status, frozenEta) = pauseCtl.evaluate(
            isCharging: true,
            systemPercent: systemPct,
            inWarmup: (out.source == .warmup),
            smoothedEta: out.minutesToFull,
            smoothedWatts: out.watts,
            now: now
        )

        // If trickle suspected, treat like a spike (freeze via controller on next ticks)
        if suspectTrickle && !status.isPaused {
            logSec("🧊", "Trickle detected near \(systemPct)% (W=\(String(format:"%.1f", out.watts))) — will freeze ETA/power if spike persists", now: now)
        }

        // Transition logs (once)
        if status.isPaused && !lastPauseFlag {
            logSec("⏸", "Charging paused — reason=\(status.reason?.rawValue ?? "unknown"); freezing ETA/power", now: now)
        } else if !status.isPaused && lastPauseFlag {
            let mins = Int(ceil(Double(status.elapsedSec)/60.0))
            logSec("▶️", "Charging resumed — paused ~\(mins)m; resuming live ETA/power", now: now)
        }
        lastPauseFlag = status.isPaused

        // ---- High-fidelity tick log (seconds, power, ETA) ----
        let etaStr: String = {
            if let e = out.minutesToFull { return "\(e)m" }
            if let e = frozenEta { return "\(e)m(frozen)" }
            return "-"
        }()
        
        // Phase 1.8: Enhanced tick log with seconds and dt
        let dt = previousTick?.timeIntervalSince(now) ?? 0
        let dtStr = String(format: "%.1fs", abs(dt))
        logSec("🕒", String(format:"Tick %@ — sys=%d%% est=%.1f%% src=%@ rate=%.1f%%/min watts=%.1fW eta=%@ dt=%@ paused=%@ reason=%@ thermal=%@ 🎫 t=%@", 
                           Self.tsFmt.string(from: now),
                           systemPct,
                           out.estPercent,
                           out.source == .warmup ? "warmup" : (out.source == .actualStep ? "step" : "interpolated"),
                           out.pctPerMin,
                           out.watts,
                           etaStr,
                           dtStr,
                           status.isPaused ? "true" : "false",
                           status.reason?.rawValue ?? "none",
                           ProcessInfo.processInfo.thermalState == .nominal ? "nominal" : "elevated",
                           tickToken), now: now)

        // Phase 2.5: Gate ETA/power on confidence (no UI change yet)
        let o = out // shorthand
        // 1) Hard freeze cases (no new ETA math)
        let mustFreeze = (o.confidence == .dataGap) ||
                         (o.confidence == .staleStep && o.watts < 6.0) || // stale + trickle
                         (status.isPaused == true)

        let etaRaw = o.minutesToFull
        let wRaw   = o.watts

        // 2) Update lastStable only when not frozen and not warmup
        if !mustFreeze && o.source != .warmup {
            lastStableETA = etaRaw ?? lastStableETA
            lastStableW   = wRaw
        }

        // 3) Choose what we'd display (Phase 2.1 flip will use this)
        let displayETA = mustFreeze ? lastStableETA : etaRaw
        let displayW   = mustFreeze ? (lastStableW ?? wRaw) : wRaw
        lastDisplayed = (displayW, displayETA)
        
        // MARK: - SSOT: Build and apply canonical charging snapshot
        buildAndApplySnapshot(
            systemPct: systemPct,
            isChargingNow: isChargingNow,
            displayW: displayW,
            displayETA: displayETA,
            out: out,
            now: now
        )
        

        


        // 4) High-fidelity logs (seconds)
        logSec("🕒", String(format: "Tick %@ — sys=%d%% est=%.1f%% src=%@ rate=%.2f%%/min watts=%.1fW eta=%@ dt=%@ conf=%@ gap=%@ 🎫 t=%@",
                           Self.tsFmt.string(from: now),
                           systemPct, o.estPercent,
                           String(describing: o.source),
                           o.pctPerMin, o.watts,
                           displayETA.map { "\($0)m" } ?? "-",
                           dtStr,
                           String(describing: o.confidence),
                           o.dataGap ? "true" : "false",
                           tickToken), now: now)

        // Runtime SSOT guard (helps catch future regressions)
        #if DEBUG
        if FeatureFlags.smoothChargingAnalytics, let ce = ChargeEstimator.shared.current {
            let diff = abs(currentWatts - ce.watts)
            if diff > 0.2 {
                addToAppLogs("🧭 SSOT WARN — watts diverged; BTM=\(String(format:"%.2f", currentWatts)) vs CE=\(String(format:"%.2f", ce.watts))")
            }
        }
        #endif

        // Phase 2.7: ETA source + timestamp in logs (debug clarity)
        if let eta = displayETA {
            if mustFreeze {
                logSec("🧊", String(format:"ETA frozen — %dm (reason=%@)", eta, freezeReasonText(o)), now: now)
            } else {
                logSec("⚙️", String(format:"ETA live — %dm (src=%@, conf=%@, dt=%.1fs)", eta, String(describing: o.source), String(describing: o.confidence), o.dt), now: now)
            }
        }
        
        if mustFreeze {
            addToAppLogs("🧊 \(Self.tsFmt.string(from: now)) Freeze — reason=\(freezeReasonText(o)) displayW=\(String(format:"%.1f", displayW)) ETA=\(displayETA.map{"\($0)m"} ?? "-")")
        }
        
        // ===== BEGIN STABILITY-LOCKED: Power persistence (do not edit) =====
        // MARK: - Power persistence (called at the end of tick)
        let now = Date()
        let tsSec = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)) // quantize to 1s
        let soc = Int(level * 100)
        
        // Use new ChargeEstimator's effective watts if available, otherwise fall back to legacy
        let w: Double
        if FeatureFlags.smoothChargingAnalytics, let current = ChargeEstimator.shared.current {
            w = current.watts
        } else {
            w = lastDisplayed.watts
        }
        
        let isWarmup = FeatureFlags.smoothChargingAnalytics ? 
            (ChargeEstimator.shared.current?.isInWarmup ?? false) : 
            (lastSmoothedOut?.confidence == .warmup)

        if isChargingNow && w.isFinite {
            if isWarmup {
                if wroteWarmupThisSession == false {
                    _ = ChargeDB.shared._insertPowerLocked(
                        ts: tsSec, session: currentSessionId, soc: soc, isCharging: true, watts: w
                    )
                    wroteWarmupThisSession = true
                    addToAppLogs("💾 DB.power insert (warmup-once) — \(String(format:"%.1fW", w))")
                }
                return  // <<< critical: prevents generic insert in same tick
            }

            // measured/smoothed path (throttle)
            if shouldPersist(now: tsSec, lastTs: lastPersistedPowerTs, minGapSec: 5) {
                _ = ChargeDB.shared._insertPowerLocked(
                    ts: tsSec, session: currentSessionId, soc: soc, isCharging: true, watts: w
                )
                lastPersistedPowerTs = tsSec
                wroteWarmupThisSession = false
                addToAppLogs("💾 DB.power insert — \(String(format:"%.1fW", w))")
            }
        } else {
            addToAppLogs("⚠️ Skipped power save — charging=\(isChargingNow) watts=\(w)")
        }
        // ===== END STABILITY-LOCKED =====
        
        // Quick sanity check for power samples
        if isChargingNow {
            let count24h = ChargeDB.shared.countPowerSamples(hours: 24)
            if count24h == 0 {
                addToAppLogs("🚫 No power samples in last 24h while charging — check schema/write path")
            }
        }

    }
    
    // MARK: - SSOT: Build and apply canonical charging snapshot
    private func buildAndApplySnapshot(
        systemPct: Int,
        isChargingNow: Bool,
        displayW: Double,
        displayETA: Int?,
        out: SafeChargingSmoother.Output?,
        now: Date
    ) {
        // Get current device profile
        let deviceService = DeviceProfileService.shared
        let modelIdentifier = deviceService.rawModelIdentifier()
        let capacitymAh = deviceService.getCapacity(for: modelIdentifier)
        
        let deviceProfile = DeviceProfile(
            rawIdentifier: modelIdentifier,
            name: "Unknown Device", // TODO: Get friendly name from DeviceProfileService
            capacitymAh: capacitymAh,
            chip: nil
        )
        
        // Determine charging state
        let chargingState: ChargingState
        if isChargingNow {
            if systemPct >= 100 {
                chargingState = .full
            } else {
                chargingState = .charging
            }
        } else {
            chargingState = .unplugged
        }
        
        // Get rate percentage per minute from smoother output
        let ratePctPerMin: Double?
        if let smootherOutput = out {
            ratePctPerMin = smootherOutput.pctPerMin
        } else {
            ratePctPerMin = nil
        }
        
        // Build the canonical snapshot
        let snapshot = ChargingSnapshot(
            ts: now,
            socPercent: systemPct,
            state: chargingState,
            watts: displayW.isFinite ? displayW : nil,
            ratePctPerMin: ratePctPerMin,
            etaMinutes: displayETA,
            device: deviceProfile
        )
        
        // Apply to central store
        ChargeStateStore.shared.apply(snapshot)
        
        // Log the snapshot application
        addToAppLogs("📊 SSOT Snapshot applied — \(systemPct)% \(chargingState.rawValue) \(displayW.isFinite ? String(format:"%.1fW", displayW) : "nil") \(displayETA.map{"\($0)m"} ?? "nil")")
    }
    
    // MARK: - SSOT: Build basic snapshot (when smooth analytics disabled)
    private func buildBasicSnapshot(systemPct: Int, isChargingNow: Bool, now: Date) {
        // Get current device profile
        let deviceService = DeviceProfileService.shared
        let modelIdentifier = deviceService.rawModelIdentifier()
        let capacitymAh = deviceService.getCapacity(for: modelIdentifier)
        
        let deviceProfile = DeviceProfile(
            rawIdentifier: modelIdentifier,
            name: "Unknown Device", // TODO: Get friendly name from DeviceProfileService
            capacitymAh: capacitymAh,
            chip: nil
        )
        
        // Determine charging state
        let chargingState: ChargingState
        if isChargingNow {
            if systemPct >= 100 {
                chargingState = .full
            } else {
                chargingState = .charging
            }
        } else {
            chargingState = .unplugged
        }
        
        // Build basic snapshot without advanced analytics
        let snapshot = ChargingSnapshot(
            ts: now,
            socPercent: systemPct,
            state: chargingState,
            watts: nil, // No watts data in basic mode
            ratePctPerMin: nil, // No rate data in basic mode
            etaMinutes: nil, // No ETA in basic mode
            device: deviceProfile
        )
        
        // Apply to central store
        ChargeStateStore.shared.apply(snapshot)
        
        // Log the basic snapshot application
        addToAppLogs("📊 SSOT Basic snapshot applied — \(systemPct)% \(chargingState.rawValue)")
    }

    // MARK: - Battery Monitoring Setup
    private func setupBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // Listen for app state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    // MARK: - Continuous Data Recording
    private func startContinuousDataRecording() {
        // Start timer to record data every minute
        dataRecordingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordBatteryData()
            }
        }
        print("📊 Battery Tracking: Started continuous data recording (every 60 seconds)")
    }
    
    private func stopContinuousDataRecording() {
        dataRecordingTimer?.invalidate()
        dataRecordingTimer = nil
        print("📊 Battery Tracking: Stopped continuous data recording")
    }
    
    // MARK: - Single Source of Truth Publisher
    @objc private func batteryChanged() {
        let newState = UIDevice.current.batteryState
        let now = Date()
        
        // Centralized debouncing with 7-second grace period
        batteryStateChanged()
        
        let snap = BatterySnapshot(level: UIDevice.current.batteryLevel,
                                   isCharging: newState == .charging || newState == .full,
                                   timestamp: now)
        subject.send(snap)
        addToAppLogs("📊 Battery Snapshot: \(Int(snap.level * 100))%, State: \(newState.rawValue)")
        print("📊 Battery Snapshot: \(Int(snap.level * 100))%, State: \(newState.rawValue)")
        
        // Phase 1.8: Guaranteed smoothing session management
        let systemPct = Int((UIDevice.current.batteryLevel * 100).rounded())
        let isChargingNow = (newState == .charging || newState == .full)

        // Start/stop session if needed
        ensureSmoothingSession(isChargingNow: isChargingNow, systemPct: systemPct, now: now)

        // Tick smoothing & pause on every snapshot
        tickSmoothingAndPause(isChargingNow: isChargingNow, systemPct: systemPct, now: now)
        
        // SSOT: Build snapshot even when smooth analytics is disabled
        if !FeatureFlags.smoothChargingAnalytics {
            buildBasicSnapshot(systemPct: systemPct, isChargingNow: isChargingNow, now: now)
        }
    }
    
    // MARK: - 7-second debounce
    @objc private func batteryStateChanged() {
        switch UIDevice.current.batteryState {
        case .charging:
            pendingEnd?.cancel()
            pendingEnd = nil
            // LiveActivityManager drives start/stop via its snapshot subscription.
            startPowerSamplingIfNeeded()
            handleChargingTransition(isCharging: true)

        default:     // .unplugged, .full, .unknown
            pendingEnd?.cancel()
            // LiveActivityManager handles stop + watchdog via snapshots/self-ping.
            pendingEnd = nil
            stopPowerSampling()
            handleChargingTransition(isCharging: false)
        }
    }
    
    // MARK: - Charging Session Management
    private var endDebounce: DispatchWorkItem?

    private func handleChargingTransition(isCharging: Bool) {
        if FeatureFlags.smoothChargingAnalytics {
            // Transition: NOT charging → charging
            if isCharging && !wasCharging {
                endDebounce?.cancel()                    // cancel a pending end
                beginEstimatorIfNeeded(systemPercent: Int(UIDevice.current.batteryLevel * 100))
                sessionActive = true
            }
            
            // Transition: charging → NOT charging
            if !isCharging && wasCharging {
                endDebounce?.cancel()
                handleUnplugDetected()
            }
            
            wasCharging = isCharging
            tickEstimator(systemPercent: Int(UIDevice.current.batteryLevel * 100), isCharging: isCharging)
        } else {
            // Legacy behavior - no estimator usage
            wasCharging = isCharging
        }
    }
    
    private func resetPowerSmoothing(_ reason: String) {
        lastDisplayed = (0, nil)
        lastSmoothedOut = nil
        lastPauseFlag = false
        wroteWarmupThisSession = false
        lastPersistedPowerTs = nil
        addToAppLogs("🧽 Reset power smoothing — \(reason)")
    }
    
    // MARK: - Session lifecycle
    func handleChargeBegan() {
        guard currentSessionId == nil else { return }    // avoid double-begin
        currentSessionId = UUID()
        resetPowerSmoothing("charge-begin")
        NotificationCenter.default.post(name: .powerDBDidChange, object: nil)
    }
    
    func handleChargeEnded() {
        guard let sid = currentSessionId else { return } // avoid double-end
        resetPowerSmoothing("charge-end")
        // Optional: write a single 0W end marker so chart clearly drops
        _ = ChargeDB.shared._insertPowerLocked(ts: Date(), session: sid, soc: Int(level * 100), isCharging: false, watts: 0.0)
        // Note: Live Activity ending is now handled by the unplug debounce system
        NotificationCenter.default.post(name: .powerDBDidChange, object: nil)
        currentSessionId = nil
    }

    private func beginEstimatorIfNeeded(systemPercent: Int) {
        guard FeatureFlags.smoothChargingAnalytics else { return }
        let now = Date()
        Task { @MainActor in
            await DeviceProfileService.shared.ensureLoaded()
            let profile = DeviceProfileService.shared.profile
                ?? DeviceProfile(rawIdentifier: UIDevice.current.model,
                                 name: UIDevice.current.model,
                                 capacitymAh: 3000,
                                 chip: nil)
            ChargeEstimator.shared.startSession(
                device: profile,
                startPct: systemPercent,
                at: now
            )
        }
    }
    
    private func endEstimatorIfNeeded() {
        guard FeatureFlags.smoothChargingAnalytics else { return }
        ChargeEstimator.shared.endSession(at: Date())
        addToAppLogs("🛑 Charge end — estimator cleared")
    }
    
    func handleUnplugDetected() {
        unplugGen &+= 1
        let gen = unplugGen
        unplugDebounceTask?.cancel()
        unplugDebounceTask = Task { [weak self] in
            guard let self else { return }
            // Debounce window
            try? await Task.sleep(nanoseconds: 800_000_000)

            // Abort if superseded by a newer state change
            guard gen == self.unplugGen else {
                addToAppLogs("🔁 Debounce superseded — newer state change")
                return
            }
            // Confirm still unplugged
            guard self.isCharging == false else {
                addToAppLogs("🔁 Debounce canceled — device back to charging")
                return
            }

            addToAppLogs("🧯 Unplug confirmed (debounced) — ending active activity")
            await LiveActivityManager.shared.endActive("UNPLUG-DEBOUNCED")
            ChargeEstimator.shared.endSession(at: Date())
            addToAppLogs("🛑 Charge end — estimator cleared")
            
            // Update SSOT with unplugged state (ETA will be automatically cleared by store)
            await self.buildAndApplySnapshot(
                systemPct: Int(self.level * 100),
                isChargingNow: false,
                displayW: 0.0,
                displayETA: nil,
                out: nil,
                now: Date()
            )
            addToAppLogs("🧹 ETA cleared in SSOT — unplugged state")
        }
    }
    
    // Call this on .charging transition (replug)
    func handleReplugDetected() {
        unplugGen &+= 1   // invalidates any pending unplug end
        unplugDebounceTask?.cancel()
        unplugDebounceTask = nil
        addToAppLogs("🔁 Replug detected — canceled unplug debounce")
    }
    
    private func tickEstimator(systemPercent: Int, isCharging: Bool) {
        guard FeatureFlags.smoothChargingAnalytics else { return }
        if isCharging {
            ChargeEstimator.shared.tickPeriodic(at: Date())
        } else {
            ChargeEstimator.shared.endSession(at: Date())
        }
    }
    
    // MARK: - App State Handlers
    @objc private func appDidBecomeActive() {
        recordBatteryData()
        startContinuousDataRecording()
    }
    
    @objc private func appWillEnterForeground() {
        recordBatteryData()
        startContinuousDataRecording()
    }
    
    @objc private func appDidEnterBackground() {
        // Keep recording in background for Live Activity support
        print("📊 Battery Tracking: App entered background, continuing data recording for Live Activity")
        
        // NEW: trim old data on background
        ChargeDB.shared.trim(olderThanDays: 30)
    }
    
    // MARK: - Data Recording
    func recordBatteryData() {
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        // Only record if battery level is valid (not -1) AND device is charging, OR if we need to force SOC persist
        guard batteryLevel >= 0 && (isCharging || forceSocPersistNext) else { return }
        
        // Allow one-shot forced persist from the foreground step logger
        let forcedSoc = self.pendingForcedSocPct
        
        // Reset the force flag before writing so we only force once
        let shouldForceSoc = forceSocPersistNext
        forceSocPersistNext = false
        
        let dataPoint = BatteryDataPoint(batteryLevel: batteryLevel, isCharging: isCharging)
        batteryDataPoints.append(dataPoint)
        
        // Keep only the most recent 30 days of data
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(maxDataDays * 24 * 3600))
        batteryDataPoints = batteryDataPoints.filter { $0.timestamp >= cutoffDate }
        
        saveBatteryData()
        print("📊 Battery Tracking: Recorded charging data \(Int(batteryLevel * 100))% at \(dataPoint.timestamp)")
        
        // Also record power sample for charging power chart
        recordPowerSample()
        
        // If this was a forced SOC persist, log it
        if shouldForceSoc {
            addToAppLogs("🪵 Request DB.soc (step/guard) — \(Int(batteryLevel * 100))% [foreground]")
        }
        
        // ===== BEGIN STABILITY-LOCKED: SoC insertion section (do not edit) =====
        // SoC insertion section - use existing pattern through dbSinks
        let shouldWriteSoc = isCharging || (forcedSoc != nil)

        if shouldWriteSoc {
            // consume the pending value so we only force once
            let socToPersist = forcedSoc ?? Int(batteryLevel * 100)
            self.pendingForcedSocPct = nil
            self.forceSocPersistNext = false
            
            if socToPersist > 0 {
                // Use existing dbSinks pattern for SoC insertion
                addToAppLogs("🪵 DB.soc request (atomic) — \(socToPersist)% [foreground]")
            }
        }
        // ===== END STABILITY-LOCKED: SoC insertion section =====
        

    }
    
    // ===== BEGIN STABILITY-LOCKED: Percent-step foreground logger (do not edit) =====
    /// Log an SoC DB row on integer % step changes, or at most every 15 minutes while in foreground.
    /// This does NOT touch the DB directly; it sets a flag and routes through recordBatteryData().
    @MainActor
    func logPercentStepToDB(now: Date = Date()) {
        let socPct = max(1, ChargeStateStore.shared.currentBatteryLevel)  // never write 0
        let bucket = socPct            // set to (socPct/5*5) if you prefer 5% buckets
        let timeGuard: TimeInterval = 15 * 60

        let shouldWrite = (bucket != lastLoggedBucket) || (now.timeIntervalSince(lastLoggedAt) >= timeGuard)
        guard shouldWrite else { return }

        lastLoggedBucket = bucket
        lastLoggedAt = now

        // capture exact SoC seen for atomic DB persist
        self.pendingForcedSocPct = socPct
        // keep any existing force flag, e.g.: self.forceSocPersistNext = true
        // Route through the *existing* DB write path
        addToAppLogs("🪵 Request DB.soc (step/guard) — \(socPct)% [foreground]")
        forceSocPersistNext = true
        recordBatteryData()            // this will see the flag and persist via the normal insert path
    }
    // ===== END STABILITY-LOCKED: Percent-step foreground logger =====
    

    
    // MARK: - Power Sample Recording
    func recordPowerSample() {
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        
        // Calculate estimated wattage based on current charging rate
        let watts = calculateCurrentWattage()
        
        let powerSample = PowerSample(watts: watts, isCharging: isCharging)
        powerSamples.append(powerSample)
        
        // Keep only the most recent 24 hours of power data for chart
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(24 * 3600))
        powerSamples = powerSamples.filter { $0.time >= cutoffDate }
        
        print("⚡ Power Tracking: Recorded \(String(format: "%.1f", watts))W at \(powerSample.time)")
    }
    
    // MARK: - Wattage Calculation
    private func calculateCurrentWattage() -> Double {
        guard isCharging else { return 0.0 }
        
        // Phase 1.9: Use 10W only during warm-up; never after
        guard let estimate = ChargeEstimator.shared.current else { return 10.0 }
        
        if estimate.isInWarmup {
            return 10.0 // Strict 10W during warm-up
        } else {
            return max(0.0, estimate.watts) // No floor after warm-up
        }
    }
    
    // MARK: - Device Battery Capacity Helper
    private func getDeviceBatteryCapacity() -> Int {
        if let p = DeviceProfileService.shared.profile {
            return p.capacitymAh
        }
        // Fallback until profile loads
        return 3000
    }
    
    // Phase 2.5: Freeze reason helper
    private func freezeReasonText(_ o: SafeChargingSmoother.Output) -> String {
        if o.confidence == .dataGap { return "data_gap(dt=\(Int(o.dt))s)" }
        if o.confidence == .staleStep && o.watts < 6.0 { return "stale_step+\(Int(o.lastRealStepAgeSec))s_lowW" }
        return "paused_or_unknown"
    }
    
    // MARK: - Power Sampling
    @MainActor func startPowerSamplingIfNeeded() {
        guard isCharging else { stopPowerSampling(); return }
        stopPowerSampling()
        // immediate sample on start
        Task { await recordPowerSample(reason: "start") }
        powerTimer = Timer.scheduledTimer(withTimeInterval: powerSampleInterval, repeats: true) { [weak self] _ in
            Task { await self?.recordPowerSample(reason: "timer") }
        }
    }
    
    @MainActor func stopPowerSampling() {
        powerTimer?.invalidate()
        powerTimer = nil
    }
    
    @MainActor func recordPowerSample(reason: String) async {
        // Phase 1.8: Enhanced power tracking with smoothing
        let systemPct = Int((UIDevice.current.batteryLevel * 100).rounded())
        let isChargingNow = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
        tickSmoothingAndPause(isChargingNow: isChargingNow, systemPct: systemPct, now: Date())

        // Use ChargeEstimator for power samples
        let watts = ChargeEstimator.shared.current?.watts ?? 10.0
        let s = PowerSample(watts: max(0, watts), isCharging: isCharging)
        powerSamples.append(s)
        // Keep last 24h
        let cutoff = Date().addingTimeInterval(-24*3600)
        powerSamples.removeAll { $0.time < cutoff }
        
        // Phase 1.8: Structured power tracking log (no more "(start)" spam)
        let d = lastDisplayed
        let etaStr = d.etaMin.map{"\($0)m"} ?? "-"
        let srcStr = lastSmoothedOut?.source == .warmup ? "warmup" : (lastSmoothedOut?.source == .actualStep ? "step" : "interpolated")
        logSec("⚡", String(format:"Power = %.1fW · eta=%@ · src=%@", 
                           d.watts,
                           etaStr,
                           srcStr),
               now: Date())
    }
    
    // MARK: - Data Management
    // NEW: no-op (or guard with a feature flag)
    private let useLegacyCache = false
    private func saveBatteryData() {
        guard useLegacyCache else { return }
        if let data = try? JSONEncoder().encode(batteryDataPoints) {
            userDefaults.set(data, forKey: batteryDataKey)
        }
    }
    
    private func loadBatteryData() {
        if let data = userDefaults.data(forKey: batteryDataKey),
           let points = try? JSONDecoder().decode([BatteryDataPoint].self, from: data) {
            batteryDataPoints = points
            print("📊 Battery Tracking: Loaded \(points.count) data points")
        }
    }
    
    // MARK: - Filtered Data for Charts
    func getFilteredData() -> [BatteryDataPoint] {
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(selectedTimeRange.hours * 3600))
        return batteryDataPoints.filter { $0.timestamp >= cutoffDate }
    }
    
    // MARK: - Chart Data Processing
    func getChartData() -> [BatteryDataPoint] {
        // NEW: Use DB instead of in-memory data
        return historyPointsFromDB(hours: 24)
    }
    
    // MARK: - Statistics
    func getBatteryStatistics() -> (min: Float, max: Float, average: Float) {
        let data = getFilteredData()
        guard !data.isEmpty else { return (0, 0, 0) }
        
        let levels = data.map { $0.batteryLevel }
        let min = levels.min() ?? 0
        let max = levels.max() ?? 0
        let average = levels.reduce(0, +) / Float(levels.count)
        
        return (min, max, average)
    }
    
    // MARK: - Charging History for Charts
    func getChargingHistory() -> [ChargeSample] {
        // Return 24-hour data for charts
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(24 * 3600))
        return historyStore.samples.filter { $0.ts >= cutoffDate }
    }
    
    // MARK: - Mock Data Generation (for testing) - CHARGING ONLY
    func generateMockData() {
        let calendar = Calendar.current
        let now = Date()
        
        var mockData: [BatteryDataPoint] = []
        
        // Generate 24 hours of mock charging data only
        for hour in 0..<24 {
            let timestamp = calendar.date(byAdding: .hour, value: -hour, to: now) ?? now
            
            // Only simulate charging periods (gaps will show when not charging)
            let isCharging: Bool
            
            if hour < 8 {
                // Night charging (8 hours) - RECORD DATA
                isCharging = true
            } else if hour < 16 {
                // Day usage (8 hours) - NO DATA (gap)
                isCharging = false
                continue // Skip recording, this creates a gap
            } else {
                // Evening charging (8 hours) - RECORD DATA
                isCharging = true
            }
            
            // Only record when charging
            if isCharging {
                let baseLevel = 0.2 + Float(hour % 8) * 0.1 // Simulate charging progression
                let dataPoint = BatteryDataPoint(batteryLevel: max(0, min(1, baseLevel)), isCharging: isCharging)
                mockData.append(dataPoint)
            }
        }
        
        batteryDataPoints = mockData
        saveBatteryData()
        print("📊 Battery Tracking: Generated \(mockData.count) charging-only mock data points")
    }
    
    // MARK: - Cleanup
    func clearAllData() {
        batteryDataPoints.removeAll()
        userDefaults.removeObject(forKey: batteryDataKey)
        print("📊 Battery Tracking: Cleared all data")
    }
    
    // MARK: - Unified DB Cleanup
    func performNightlyCleanup() {
        ChargeDB.shared.trim(olderThanDays: 30)
        addToAppLogs("🗄️ Nightly cleanup: trimmed DB to 30 days")
    }
    
    // MARK: - Power Persistence Helpers
    private func shouldPersist(now: Date, lastTs: Date?, minGapSec: TimeInterval) -> Bool {
        guard let lastTs else { return true }
        return now.timeIntervalSince(lastTs) >= minGapSec
    }
    
    // ===== BEGIN STABILITY-LOCKED: charge-state hysteresis (do not edit) =====
    // MARK: - State hysteresis so flaps don't spam
    private func setChargingState(_ newState: Bool) {
        stateChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isCharging != newState else { return }
            
            // Call unplug/replug handlers before state change
            if !newState {
                // Transitioning to not charging (unplug detected)
                self.handleUnplugDetected()
            } else {
                // Transitioning to charging (replug detected)
                self.handleReplugDetected()
            }
            
            // Track charging session changes
            let oldChargingState = self.isCharging
            self.isCharging = newState
            
            if newState != oldChargingState {
                if newState {
                    // Started charging
                    self.currentSessionStartTime = Date()
                    self.currentSessionStartPercentage = Int(UIDevice.current.batteryLevel * 100)
                } else if let start = self.currentSessionStartTime,
                          let startPct = self.currentSessionStartPercentage {
                    // Ended charging - log session (DB persistence will be added later)
                    let session = ChargingSession(
                        id: UUID(),
                        startTime: start,
                        endTime: Date(),
                        startPercentage: startPct,
                        endPercentage: Int(UIDevice.current.batteryLevel * 100)
                    )
                    self.addToAppLogs("📊 Charging session ended: \(session.durationMinutes)m (\(session.startPercentage)% → \(session.endPercentage)%)")
                    self.currentSessionStartTime = nil
                    self.currentSessionStartPercentage = nil
                }
            }
            
            if newState {
                self.handleChargeBegan()
            } else {
                self.handleChargeEnded()
            }
        }
        stateChangeWorkItem = work
        // was 0.5s; 0.9s reduces quick flaps without feeling laggy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
    // ===== END STABILITY-LOCKED =====
    
    // MARK: - Rate-limited logging
    func addToAppLogs(_ s: String) {
        let now = Date()
        // allow at most 10 logs/sec (100ms min)
        guard now.timeIntervalSince(lastLogTime) > 0.1 else { return }
        lastLogTime = now
        
        // append `s` to your UI-bound log array with a max count (e.g., 500)
        let timestamp = Date().formatted(date: .omitted, time: .shortened)
        let logEntry = "[\(timestamp)] \(s)"
        globalLogMessages.append(logEntry)
        
        // Keep only last 500 messages to prevent memory issues
        if globalLogMessages.count > 500 {
            globalLogMessages.removeFirst(globalLogMessages.count - 500)
        }
        
        // Also log to system logger
        contentLogger.info("\(s)")
    }
    
    func addToAppLogsCritical(_ s: String) {
        // no rate limit; this MUST print
        let timestamp = Date().formatted(date: .omitted, time: .shortened)
        let logEntry = "[\(timestamp)] \(s)"
        globalLogMessages.append(logEntry)
        if globalLogMessages.count > 500 {
            globalLogMessages.removeFirst(globalLogMessages.count - 500)
        }
        contentLogger.info("\(s)")
    }
    
    // Note: Session persistence will be implemented later to avoid stability guardrail issues
    // For now, sessions are logged but not persisted to DB
}

extension BatteryTrackingManager {
    private static let bgLog = Logger(subsystem: "com.gopetl.PETL", category: "bg")

    func recordBackgroundLog(soc: Int, watts: Double) {
        Self.bgLog.info("📝 BG log — soc=\(soc) watts=\(watts) @\(Date().timeIntervalSince1970)")
        // If you have a history/DB pipeline, append here (source: .push)
    }
} 
