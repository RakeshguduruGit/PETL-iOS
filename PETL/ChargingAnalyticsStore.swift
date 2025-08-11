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

        // derive characteristic from the unified rate
        let label = ChargingAnalytics.label(forPctPerMinute: est.pctPerMin)
        let wattsStr = String(format: "%.1fW", BatteryTrackingManager.shared.currentWatts)

        // Check if charging based on BatteryTrackingManager (not from estimate)
        let isCharging = BatteryTrackingManager.shared.isCharging

        if isCharging && !wasCharging {
            // New plug-in: drop any previous grace so we never show old minutes.
            lastKnownMinutes = nil
            lastKnownLabel = "—"
            lastKnownWatts = "—"
            lastPluggedAt = now
        }
        wasCharging = isCharging

        if isCharging {
            // update live + cache for grace period
            timeToFullMinutes = est.minutesToFull
            characteristicLabel = label
            characteristicWatts = wattsStr
            hasEverComputed = true
            lastKnownMinutes = est.minutesToFull
            lastKnownLabel = label
            lastKnownWatts = wattsStr
            lastPluggedAt = now
        } else {
            // not charging: show the last known values for a short grace window
            // so the card doesn't flicker to "..."
            let withinGrace = (lastPluggedAt == nil) ? false : (now.timeIntervalSince(lastPluggedAt!) < 20)
            if withinGrace, let m = lastKnownMinutes {
                timeToFullMinutes = m
                characteristicLabel = lastKnownLabel
                characteristicWatts = lastKnownWatts
            } else {
                // truly not charging and grace expired: blank out
                timeToFullMinutes = nil
                characteristicLabel = "—"
                characteristicWatts = "—"
            }
        }
    }
} 