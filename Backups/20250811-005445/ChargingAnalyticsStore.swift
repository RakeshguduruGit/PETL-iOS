import Foundation
import Combine
import os.log

@MainActor
final class ChargingAnalyticsStore: ObservableObject {
    @Published private(set) var timeToFullMinutes: Int? = nil
    @Published private(set) var characteristicLabel: String = "—"
    @Published private(set) var characteristicWatts: String = "—"
    @Published private(set) var hasEverComputed: Bool = false

    // cache for "grace" after unplug so the card doesn't drop to "..."
    private var lastKnownMinutes: Int? = nil
    private var lastKnownLabel: String = "—"
    private var lastKnownWatts: String = "—"
    private var lastPluggedAt: Date? = nil
    private var wasCharging = false

    private var cancellables = Set<AnyCancellable>()
    
    private let uiLogger = Logger(subsystem: "com.petl.app", category: "ui")

    init() {
        ChargeEstimator.shared.estimateSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] est in
                guard let self else { return }
                let m = est.minutesToFull ?? -1
                self.uiLogger.info("📊 UI Estimate: \(m) min, rate=\(String(format: "%.2f", est.pctPerMin))%/min")
                self.ingest(estimate: est)
            }
            .store(in: &cancellables)

        // Optional: seed from lastEstimate if the estimator exposes it
        if let last = ChargeEstimator.shared.lastEstimate {
            ingest(estimate: last)
        }
    }

    private func ingest(estimate est: ChargeEstimator.ChargeEstimate) {
        let now = est.computedAt

        // Compute isActive with an estimator check (covers bouncy state transitions)
        let isCharging = BatteryTrackingManager.shared.isCharging
        let isActive = isCharging || (ChargeEstimator.shared.current != nil)

        // Use canonical watts so card matches LA/DB
        let label = ChargingAnalytics.label(forPctPerMinute: est.pctPerMin)
        let wattsStr = String(format: "%.1fW", BatteryTrackingManager.shared.currentWatts)

        if isCharging && !wasCharging {
            // New plug-in: keep lastKnown values until the first new estimate lands.
            // Just mark the moment for grace timing; do NOT clear the cache here.
            lastPluggedAt = now
        }
        wasCharging = isCharging

        if isActive {
            // 3-way fallback so it never goes nil
            let sysPct = Int(BatteryTrackingManager.shared.level * 100)
            let minutes: Int = {
                if let m = est.minutesToFull { return m }                       // fresh
                if let m = lastKnownMinutes { return m }                        // cache
                return ChargeEstimator.shared.theoreticalMinutesToFull(socPercent: sysPct) // theory
            }()

            timeToFullMinutes = minutes
            characteristicLabel = label
            characteristicWatts = wattsStr
            hasEverComputed = true
            lastKnownMinutes = minutes
            lastKnownLabel = label
            lastKnownWatts = wattsStr
            lastPluggedAt = now
        } else {
            // Truly idle (no active estimator and not charging)
            let withinGrace = (lastPluggedAt.map { est.computedAt.timeIntervalSince($0) < 20 } ?? false)
            if withinGrace, let m = lastKnownMinutes {
                timeToFullMinutes = m
                characteristicLabel = lastKnownLabel
                characteristicWatts = lastKnownWatts
            } else {
                timeToFullMinutes = nil
                characteristicLabel = "—"
                characteristicWatts = "—"
            }
        }
    }
} 