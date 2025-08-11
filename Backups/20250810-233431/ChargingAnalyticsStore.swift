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
        // Subscribe to ChargeEstimator's estimates
        ChargeEstimator.shared.estimateSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] estimate in 
                self?.uiLogger.info("📊 UI Estimate: \(estimate.minutesToFull) min, rate=\(String(format: "%.1f", estimate.pctPerMin))%/min")
                self?.ingest(estimate: estimate) 
            }
            .store(in: &cancellables)

        // Seed immediately from current estimate
        if let current = ChargeEstimator.shared.current {
            ingest(estimate: current)
        }
    }

    private func ingest(estimate est: ChargeEstimate) {
        let now = est.computedAt

        // derive characteristic from the unified rate
        let (label, watts) = ChargingAnalytics.chargingCharacteristic(pctPerMinute: est.pctPerMin)

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
            characteristicWatts = watts
            hasEverComputed = true
            lastKnownMinutes = est.minutesToFull
            lastKnownLabel = label
            lastKnownWatts = watts
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