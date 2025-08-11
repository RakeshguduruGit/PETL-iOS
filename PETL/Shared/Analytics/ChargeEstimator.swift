import Foundation
import Combine

public struct ChargeEstimate {
    public let snapshotID: Int
    public let level01: Double
    public let pctPerMin: Double
    public let minutesToFull: Int
    public let isInWarmup: Bool     // NEW
    public let watts: Double        // NEW
    public let computedAt: Date
}

@MainActor
public final class ChargeEstimator: ObservableObject {
    public static let shared = ChargeEstimator()

    public private(set) var current: ChargeEstimate?
    public let estimateSubject = PassthroughSubject<ChargeEstimate, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var lastSample: (level: Float, t: Date)?
    private var snapshotSeq = 0

    // Tunables (ONE place)
    private let warmupPctPerMin = ChargingAnalytics.warmupPctPerMin   // e.g. 1.5
    private let minDeltaMinutes = 0.3                                  // ignore < ~18s jitter
    private let rounding: (Double) -> Int = { Int(($0).rounded()) }    // SAME rounding

    private init() {
        // Subscribe to BatteryTrackingManager's snapshots
        BatteryTrackingManager.shared.snapshotSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.ingest(snapshot: s) }
            .store(in: &cancellables)

        // Seed immediately to avoid first-frame "—"
        let s = BatterySnapshot(level: BatteryTrackingManager.shared.level,
                                isCharging: BatteryTrackingManager.shared.isCharging,
                                timestamp: Date())
        ingest(snapshot: s)
    }

    private func ingest(snapshot s: BatterySnapshot) {
        let now = s.timestamp

        // Estimate pct/min
        var pctPerMin: Double? = nil
        if let prev = lastSample {
            let dtMin = now.timeIntervalSince(prev.t) / 60.0
            if dtMin > minDeltaMinutes {
                let dPct = Double((s.level - prev.level) * 100.0)
                pctPerMin = dPct / dtMin
            }
        }
        lastSample = (s.level, now)

        // Use shared helper + unified rounding
        let rate = max(pctPerMin ?? warmupPctPerMin, 0.1)
        let minutes = ChargingAnalytics.minutesToFull(
            batteryLevel0to1: Double(s.level),
            pctPerMinute: rate
        ) ?? 0

        snapshotSeq += 1
        let estimate = ChargeEstimate(
            snapshotID: snapshotSeq,
            level01: Double(s.level),
            pctPerMin: rate,
            minutesToFull: rounding(Double(minutes)),
            isInWarmup: false, // Legacy mode - will be updated by rate estimator
            watts: 10.0,       // Legacy mode - will be updated by rate estimator
            computedAt: now
        )
        current = estimate
        estimateSubject.send(estimate)
    }
    
    // MARK: - Rate Estimator Integration
    public func updateFromRateEstimator(_ out: ChargingRateEstimator.Output) {
        guard FeatureFlags.smoothChargingAnalytics else { return }
        
        let est = ChargeEstimate(
            snapshotID: snapshotSeq + 1,
            level01: out.estPercent / 100.0,
            pctPerMin: out.pctPerMin,
            minutesToFull: out.minutesToFull ?? 0,
            isInWarmup: out.source == .warmupFallback,
            watts: out.watts,
            computedAt: Date()
        )
        self.current = est
        estimateSubject.send(est)
    }
} 