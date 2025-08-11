import Foundation
import Combine
import os.log

@MainActor
final class ChargeEstimator {
    static let shared = ChargeEstimator(); private init() {}

    struct Current {
        let computedAt: Date
        let level01: Double
        let watts: Double
        let isInWarmup: Bool
        let phase: Phase
    }
    enum Phase: String { case warmup, active, trickle }

    struct ChargeEstimate {
        let computedAt: Date
        let pctPerMin: Double
        let minutesToFull: Int?
        let level01: Double
    }

    let estimateSubject = PassthroughSubject<ChargeEstimate, Never>()

    // Session state
    private var sessionId: UUID?
    private var capacity_mAh: Int = 3000
    private var pNom: Double = 10.0

    private var startPct: Int = -1
    private var lastPct: Int = -1
    private var lastPctChangeAt: Date = .distantPast

    private var window: [(dt: TimeInterval, dPct: Double, endSOC: Int, at: Date)] = []
    private var lastETA: Int? = nil
    private var alpha: Double = 1.0

    private let warmupMinSec: TimeInterval = 10 * 60
    private let warmupMinPct: Double = 5.0
    private let windowTargetSec: TimeInterval = 15 * 60
    private let trickleStartPct: Int = 80

    private(set) var current: Current?

    // MARK: API
    func startSession(device: DeviceProfile, sessionId sid: UUID?, startPct sp: Int, at: Date = Date(), nominalPowerW: Double = 10.0) {
        self.sessionId = sid ?? UUID()
        self.capacity_mAh = max(600, device.capacitymAh)
        self.pNom = max(1.0, nominalPowerW)
        self.startPct = sp
        self.lastPct = sp
        self.lastPctChangeAt = at
        self.window.removeAll()
        self.alpha = 1.0
        self.lastETA = nil
        recompute(now: at, sysPct: sp)
    }

    func noteBattery(levelPercent: Int, at: Date = Date()) {
        guard sessionId != nil else { return }
        let p = min(max(levelPercent, 0), 100)
        if lastPct < 0 {
            lastPct = p; lastPctChangeAt = at
            recompute(now: at, sysPct: p)
            return
        }
        if p > lastPct {
            let dt = max(1.0, at.timeIntervalSince(lastPctChangeAt))
            let dPct = Double(p - lastPct)
            window.append((dt: dt, dPct: dPct, endSOC: p, at: at))
            while windowSpanSec > windowTargetSec, window.count > 1 { _ = window.removeFirst() }
            lastPct = p; lastPctChangeAt = at
        }
        recompute(now: at, sysPct: p)
    }

    func tickPeriodic(at: Date = Date()) {
        guard sessionId != nil else { return }
        let p = lastPct >= 0 ? lastPct : Int((current?.level01 ?? 0) * 100.0)
        recompute(now: at, sysPct: p)
    }

    func endSession(at: Date = Date()) {
        sessionId = nil
        window.removeAll()
        current = nil
        lastETA = nil
        alpha = 1.0
    }

    // MARK: Internals
    private var windowSpanSec: TimeInterval {
        guard let first = window.first, let last = window.last else { return 0 }
        return last.at.timeIntervalSince(first.at)
    }
    private var sumDeltaPct: Double { window.reduce(0) { $0 + $1.dPct } }

    private func recompute(now: Date, sysPct: Int) {
        let theory1pct = theoreticalMinutesPer1pct(atSOC: sysPct)
        let inWarmup = (windowSpanSec < warmupMinSec) || (sumDeltaPct < warmupMinPct)
        let inTrickle = sysPct >= trickleStartPct

        let t_meas = medianMinutesPer1pct()
        let t_eff = (inWarmup || t_meas == nil) ? theory1pct : max(0.1, t_meas!)

        var etaTheory = Double(max(0, 100 - sysPct)) * theory1pct
        if inTrickle { etaTheory *= 1.7 }

        var etaEmp = Double(max(0, 100 - sysPct)) * t_eff
        if inTrickle { etaEmp *= 1.3 }

        alpha = clamp01(alpha - decayStep())
        let blended = inWarmup ? etaTheory : (alpha * etaTheory + (1 - alpha) * etaEmp)

        let etaRounded = Int(round(blended))
        let etaClamped: Int? = {
            guard let last = lastETA else { return etaRounded }
            return (etaRounded > last + 2) ? (last + 2) : etaRounded
        }()
        lastETA = etaClamped

        // Effective power: ratio of theoretical 1% mins vs measured
        let pEff: Double = {
            if let t_meas, t_meas > 0 { return pNom * (theory1pct / t_meas) }
            return pNom
        }()

        current = Current(
            computedAt: now,
            level01: Double(sysPct) / 100.0,
            watts: max(0, pEff),
            isInWarmup: inWarmup,
            phase: inTrickle ? .trickle : (inWarmup ? .warmup : .active)
        )

        let ppm = 60.0 / max(0.1, t_eff)
        estimateSubject.send(.init(
            computedAt: now,
            pctPerMin: ppm,
            minutesToFull: etaClamped,
            level01: Double(sysPct) / 100.0
        ))
    }

    private func theoreticalMinutesPer1pct(atSOC soc: Int) -> Double {
        // Capacity Wh with gross→net efficiency
        let k_eff = 0.75
        let capWh = (Double(capacity_mAh) * 3.85 / 1000.0) * k_eff
        let base = (capWh / pNom) * 60.0 / 100.0
        let mult: Double = (soc < 60) ? 1.0 : (soc < 80 ? 1.2 : 2.5)
        return base * mult
    }

    private func medianMinutesPer1pct() -> Double? {
        guard !window.isEmpty else { return nil }
        let values = window.map { ($0.dt / max($0.dPct, 0.0001)) / 60.0 }.sorted()
        let n = values.count
        let low = Int(Double(n) * 0.15), high = Int(Double(n) * 0.85)
        let trimmed = (low < high) ? Array(values[low..<high]) : values
        let m = trimmed.count
        return m % 2 == 0 ? (trimmed[m/2 - 1] + trimmed[m/2]) / 2.0 : trimmed[m/2]
    }

    private func decayStep() -> Double { 1.0 / (12.0 * 60.0) } // ~12 min to fade-in empirics
    private func clamp01(_ x: Double) -> Double { min(1.0, max(0.0, x)) }
} 