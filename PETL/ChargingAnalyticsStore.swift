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

        // Guarantee minutes while active. If est.minutesToFull == nil, fall back to last known (or theory) so we never show "—" mid-charge
        let minutes: Int = {
            if let m = est.minutesToFull { return m }
            if let m = lastKnownMinutes { return m }
            // last resort: theory (should almost never run once estimator is fixed)
            return ChargeEstimator.shared.theoreticalMinutesToFull(
                socPercent: Int((est.level01 * 100).rounded())
            )
        }()

        if isCharging && !wasCharging {
            // New plug-in: drop any previous grace so we never show old minutes.
            lastKnownMinutes = nil
            lastKnownLabel = "—"
            lastKnownWatts = "—"
            lastPluggedAt = now
        }
        wasCharging = isCharging

        if isActive {
            timeToFullMinutes = minutes
            characteristicLabel = label
            characteristicWatts = wattsStr
            hasEverComputed = true
            lastKnownMinutes = minutes
            lastKnownLabel = label
            lastKnownWatts = wattsStr
            if isCharging && lastPluggedAt == nil { lastPluggedAt = est.computedAt }
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