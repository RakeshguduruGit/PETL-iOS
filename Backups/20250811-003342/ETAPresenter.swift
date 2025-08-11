import Foundation

@MainActor
final class ETAPresenter {
    static let shared = ETAPresenter()
    
    private init() {}
    
    // State
    private var lastStableETA: Int?
    private var lastStableW: Double?
    
    // Public accessor for last stable minutes (for DI edge clamp)
    var lastStableMinutes: Int? { lastStableETA }
    private var lastPct: Int = -1
    private var lastPctChangeAt = Date()

    // Spike quarantine (confirm on 2 consecutive ticks)
    private var spikeCandidateETA: Int?
    private var spikeConfirmTicks = 0

    // NEW: input signature + last output, to ignore duplicate calls
    private struct Sig: Equatable {
        let eta: Int?
        let sys: Int
        let wBucket: Int  // 0.5 W buckets to ignore tiny noise
    }
    private var lastSig: Sig?
    private var lastOutput: Int?
    
    // Idempotency per tick token
    private var lastToken: String?
    private var lastInput: Input?
    private var lastCachedOutput: Output?
    
    private struct Input: Equatable {
        let rawETA: Int?
        let watts: Double
        let sysPct: Int
        let isCharging: Bool
        let isWarmup: Bool
    }
    
    struct Output {
        let minutes: Int?
        let formatted: String
    }

    // OPTIONAL: coarse rate-limit (avoid rapid-fire increments)
    private var lastAdvanceAt: Date = .distantPast
    private let minAdvanceInterval: TimeInterval = 0.9  // ~1 update/sec

    // Tunables
    private let trickleWMax = 5.0            // ≤5W = trickle
    private let spikeEtaMin = 180            // 3h+
    private let confirmTicks = 2             // need 2 consecutive confirmations
    private let staleNoStepSec: TimeInterval = 600 // 10 min

    // Slew limits per tick (minutes)
    private func etaRiseBudget(from base: Int) -> Int { max(2, Int(Double(max(10, base)) * 0.15)) }
    private func etaDropBudget(from base: Int) -> Int { max(3, Int(Double(max(10, base)) * 0.30)) }

    @MainActor
    func resetSession(systemPercent: Int) {
        lastStableETA = nil
        lastStableW = nil
        spikeCandidateETA = nil
        spikeConfirmTicks = 0
        lastPct = systemPercent
        lastPctChangeAt = Date()
        lastSig = nil
        lastOutput = nil
        lastAdvanceAt = .distantPast
        
        // Clear idempotency cache
        lastToken = nil
        lastInput = nil
        lastCachedOutput = nil
    }
    
    func resetForNewSession() {
        lastStableETA = nil
        lastStableW = nil
        spikeCandidateETA = nil
        spikeConfirmTicks = 0
        lastPct = -1
        lastPctChangeAt = Date()
        lastSig = nil
        lastOutput = nil
        lastAdvanceAt = .distantPast
        
        // Clear idempotency cache
        lastToken = nil
        lastInput = nil
        lastCachedOutput = nil
    }

    func presented(rawETA: Int?, watts: Double, sysPct: Int, isCharging: Bool, isWarmup: Bool, tickToken: String) -> Output {
        let now = Date()
        
        // Idempotency: same tick? just return cached result.
        if tickToken == lastToken, let out = lastCachedOutput { 
            return out 
        }
        
        // Build an input fingerprint for quarantine/spike logic
        let input = Input(rawETA: rawETA, watts: watts, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarmup)
        
        // NEW: Check for duplicate input signature
        let sig = Sig(eta: rawETA, sys: sysPct, wBucket: Int((watts * 2.0).rounded())) // 0.5W buckets
        if sig == lastSig {
            let result = lastOutput ?? rawETA
            let output = Output(minutes: result, formatted: result.map { "\($0)m" } ?? "—")
            return output
        }
        lastSig = sig
        
        // OPTIONAL: Rate limit to avoid rapid-fire increments
        if Date().timeIntervalSince(lastAdvanceAt) < minAdvanceInterval {
            let result = lastOutput ?? rawETA
            let output = Output(minutes: result, formatted: result.map { "\($0)m" } ?? "—")
            return output
        }
        lastAdvanceAt = now
        
        if sysPct != lastPct { lastPct = sysPct; lastPctChangeAt = now }

        // ---- Fresh-session seeding & warmup bypass ----
        if isWarmup {
            // On first warmup ticks we unconditionally adopt the raw ETA (if present)
            // and clear any spike/quarantine state so we don't clamp toward an old value.
            spikeCandidateETA = nil
            spikeConfirmTicks = 0

            if let e = rawETA {
                lastStableETA = e
                lastStableW = watts
                lastOutput = e

                let out = Output(minutes: e, formatted: "\(e)m")
                lastToken = tickToken
                lastInput = input
                lastCachedOutput = out
                logETA("seed", eta: e, watts: watts, reason: "warmup/new-session")
                return out
            } else {
                // No ETA yet on warmup: explicitly clear output so we don't show old minutes
                lastStableETA = nil
                lastStableW = watts
                lastOutput = nil
                let out = Output(minutes: nil, formatted: "—")
                lastToken = tickToken
                lastInput = input
                lastCachedOutput = out
                logETA("seed", eta: nil, watts: watts, reason: "warmup/no-raw")
                return out
            }
        }

        // Pass-through when not charging
        guard isCharging else {
            if let e = rawETA { lastStableETA = e }
            lastStableW = watts
            lastOutput = rawETA
            let output = Output(minutes: rawETA, formatted: rawETA.map { "\($0)m" } ?? "—")
            return output
        }

        // If no ETA yet, show last stable (or —)
        guard let eta = rawETA else { 
            lastOutput = lastStableETA
            let output = Output(minutes: lastStableETA, formatted: lastStableETA.map { "\($0)m" } ?? "—")
            return output
        }

        // Detect "seeded/unknown" situation via no % change for a while
        let noStepSec = now.timeIntervalSince(lastPctChangeAt)
        let seededOrStale = noStepSec >= staleNoStepSec

        // ----- Spike quarantine: big upward ETA while trickling -----
        let haveStable = (lastStableETA != nil)
        let bigUp = haveStable && eta >= max(spikeEtaMin, (lastStableETA! * 2)) // ≥3h OR ≥2× last
        let trickle = watts <= trickleWMax

        if FeatureFlags.etaQuarantineP3, bigUp, trickle {
            if spikeCandidateETA == eta {
                spikeConfirmTicks += 1
            } else {
                spikeCandidateETA = eta
                spikeConfirmTicks = 1
            }

            // Freeze until confirmed
            if spikeConfirmTicks < confirmTicks {
                logETA("quarantine", eta: lastStableETA, watts: watts, reason: "cand=\(eta)m ticks=\(spikeConfirmTicks)")
                lastOutput = lastStableETA
                let output = Output(minutes: lastStableETA, formatted: lastStableETA.map { "\($0)m" } ?? "—")
                return output
            }

            // Confirmed spike - apply slew limit
            logETA("acceptSpike", eta: eta, watts: watts, reason: "confirmed after \(spikeConfirmTicks) ticks")
            let clamped = lastStableETA.map { base in
                let budget = etaRiseBudget(from: base)
                let allowed = base + budget
                return min(eta, allowed)
            } ?? eta

            if clamped != eta {
                logETA("slewClamp", eta: clamped, watts: watts, reason: "base→\(eta); clamped")
            }

            lastStableETA = clamped
            lastStableW = watts
            lastOutput = clamped
            let output = Output(minutes: clamped, formatted: "\(clamped)m")
            return output
        }

        // ----- Normal slew limiting -----
        if let stable = lastStableETA {
            let delta = eta - stable
            let budget = delta > 0 ? etaRiseBudget(from: stable) : etaDropBudget(from: stable)
            let clamped = stable + (delta > 0 ? min(delta, budget) : max(delta, -budget))

            if clamped != eta {
                logETA("slewClamp", eta: clamped, watts: watts, reason: "\(stable)→\(eta); clamped")
            }

            lastStableETA = clamped
            lastStableW = watts
            lastOutput = clamped
            let output = Output(minutes: clamped, formatted: "\(clamped)m")
            return output
        }

        // First stable reading
        lastStableETA = eta
        lastStableW = watts
        lastOutput = eta
        let output = Output(minutes: eta, formatted: "\(eta)m")
        
        // Cache exactly once per tick:
        self.lastToken = tickToken
        self.lastInput = input
        self.lastCachedOutput = output
        
        // Log at most once per tick (so those dozens of `slewClamp` lines collapse to one)
        addToAppLogs("⏱️ ETA[presenter] \(output.formatted) W=\(String(format:"%.1f", watts)) t=\(tickToken)")
        
        return output
    }

    private func logETA(_ phase: String, eta: Int?, watts: Double, reason: String) {
        let etaText = eta.map { "\($0)m" } ?? "—"
        addToAppLogs("⏱️ ETA[presenter/\(phase)] = \(etaText) W=\(String(format:"%.1f", watts)) \(reason)")
    }
}
