import Foundation
import UIKit

final class ChargePauseController {

    enum Reason: String { case thermal, optimized, spike, unknown }
    struct Status {
        let isPaused: Bool
        let reason: Reason?
        let since: Date?
        let elapsedSec: Int
        let label: String
    }

    // Tunables
    private let spikeEtaAbsCapMin = 300      // suppress > 300 min spikes
    private let spikeEtaJumpX     = 3.0      // or >3x jump versus previous
    private let enterHysteresis   = 4        // ticks to confirm pause
    private let exitHysteresis    = 3        // ticks to confirm resume
    private let optimizedBand     = 75...85  // % band to suspect Optimized Charging
    
    // Phase 2.6: Earlier pause latch in 75–88% trickle
    private let earlyOptimizedBand = 75...88
    private let minNoChangeSec = 60      // sys% unchanged ≥ 60s
    private let trickleWattMax = 4.5     // <= 4.5W counts as trickle
    private let pauseTicksToEnter = 2    // faster latching
    private let pauseTicksToExit  = 2

    // State
    private var paused = false
    private var pausedSince: Date?
    private var pauseTicks = 0
    private var resumeTicks = 0
    private var lastStableEta: Int? = nil
    private var lastEta: Int? = nil
    
    // Phase 2.6: System percent tracking
    private var lastSystemPercent: Int = 0
    private var lastSystemChangeDate: Date?

    // Returns (status, displayedETA) — displayedETA may be frozen while paused
    func evaluate(isCharging: Bool,
                  systemPercent: Int,
                  inWarmup: Bool,
                  smoothedEta: Int?,
                  smoothedWatts: Double,
                  now: Date) -> (Status, Int?) {

        // Warm-up: never mark paused; let existing 10W fallback work.
        guard isCharging, !inWarmup else {
            paused = false; pausedSince = nil; pauseTicks = 0; resumeTicks = 0
            lastStableEta = smoothedEta; lastEta = smoothedEta
            return (Status(isPaused: false, reason: nil, since: nil, elapsedSec: 0, label: "charging"),
                    smoothedEta)
        }

        // Phase 2.6: Track system percent changes
        let sysChanged = systemPercent != lastSystemPercent
        if sysChanged {
            lastSystemChangeDate = now
            lastSystemPercent = systemPercent
        }
        let sinceLastSysChangeSec = Int(now.timeIntervalSince(lastSystemChangeDate ?? now))
        let sysUnchanged = !sysChanged && (sinceLastSysChangeSec >= minNoChangeSec)

        // Heuristics
        let thermal = ProcessInfo.processInfo.thermalState
        let isThermal = (thermal == .serious || thermal == .critical)

        let eta = smoothedEta
        let bigSpike = {
            guard let eta = eta else { return false }
            let jumpX = (lastEta != nil && lastEta! > 0) ? Double(eta) / Double(lastEta!) : 1.0
            return eta >= spikeEtaAbsCapMin || jumpX >= spikeEtaJumpX
        }()

        let inOptimizedBand = optimizedBand.contains(systemPercent)
        let earlyOptimized = !inWarmup &&
                             earlyOptimizedBand.contains(systemPercent) &&
                             sysUnchanged && (smoothedWatts <= trickleWattMax)

        // Determine candidate reason
        var reason: Reason? = nil
        if isThermal { reason = .thermal }
        else if earlyOptimized { reason = .optimized }
        else if bigSpike && inOptimizedBand { reason = .optimized }
        else if bigSpike { reason = .spike }

        // Hysteresis enter/exit (Phase 2.6: faster latching)
        if reason != nil {
            pauseTicks += 1
            resumeTicks = 0
        } else {
            resumeTicks += 1
            pauseTicks = 0
        }

        if !paused, pauseTicks >= pauseTicksToEnter {
            paused = true
            pausedSince = now
        } else if paused, resumeTicks >= pauseTicksToExit {
            paused = false
            pausedSince = nil
        }

        // Freeze ETA while paused; otherwise allow and update lastStableEta
        var displayedEta = eta
        if paused {
            displayedEta = lastStableEta
        } else {
            if let eta = eta { lastStableEta = eta }
        }
        lastEta = eta

        let elapsed = Int(max(0, (pausedSince?.distance(to: now) ?? 0)))
        let label: String
        if paused {
            label = "paused"
        } else {
            label = "charging"
        }

        let status = Status(isPaused: paused,
                            reason: paused ? (reason ?? .unknown) : nil,
                            since: paused ? pausedSince : nil,
                            elapsedSec: elapsed,
                            label: label)
        return (status, displayedEta)
    }
}
