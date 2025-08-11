import Foundation

/// Minimal, file-safe smoother used only after warm-up.
/// No public API surface; can be removed without ripple effects.
final class SafeChargingSmoother {

    struct Output {
        let estPercent: Double
        let pctPerMin: Double
        let watts: Double
        let minutesToFull: Int?
        let source: Source
        let firstStepThisSession: Bool
        // NEW:
        let dt: TimeInterval
        let dataGap: Bool
        let lastRealStepAgeSec: Int
        let confidence: Confidence
    }
    enum Source { case warmup, interpolated, actualStep }
    enum Confidence { case warmup, seeded, good, staleStep, dataGap }

    private let capacityAh: Double
    private let alphaEMA: Double
    private let warmupMaxSeconds: Int
    private let nominalVoltage: Double

    // tunables
    private let expectedTick: TimeInterval = 30.0    // keep in sync with sampler
    private let staleStepSec: Int = 10 * 60          // if no +5% step for 10m → stale
    private let gapFactor: Double = 2.5              // dt > 2.5x expected → data gap

    private var estSOC: Double = 0
    private var emaPctPerMin: Double = 0
    private var lastPercent: Int = 0
    private var nextBoundary: Int = 0
    private var lastChangeDate: Date?
    private var warmupStart: Date?
    private var inWarmup: Bool = true

    // state
    private var lastTick: Date?
    private var lastRealStep: Date? // set when we see an actual +5%

    init(capacitymAh: Int,
         alphaEMA: Double = 0.25,
         warmupMaxSeconds: Int = 90,
         nominalVoltage: Double = 3.85) {
        self.capacityAh = max(0.5, Double(capacitymAh)) / 1000.0
        self.alphaEMA = alphaEMA
        self.warmupMaxSeconds = warmupMaxSeconds
        self.nominalVoltage = nominalVoltage
    }

    func begin(systemPercent: Int, now: Date) {
        lastPercent = max(0, min(100, systemPercent))
        estSOC = Double(lastPercent)
        inWarmup = true
        warmupStart = now
        lastChangeDate = now
        nextBoundary = min(((lastPercent / 5) * 5) + 5, 100)
        lastTick = now
        lastRealStep = nil
    }

    func end(now: Date) {
        estSOC = Double(lastPercent) // snap to system
        inWarmup = false
        warmupStart = nil
        lastChangeDate = nil
        lastTick = now
        lastRealStep = nil
    }

    func tick(systemPercent: Int, isCharging: Bool, now: Date) -> Output {
        let pct = max(0, min(100, systemPercent))
        let dt = now.timeIntervalSince(lastTick ?? now)
        lastTick = now

        // Not charging → steady, no ETA
        guard isCharging else {
            estSOC = Double(pct)
            lastPercent = pct
            return Output(estPercent: estSOC, pctPerMin: 0, watts: 0, minutesToFull: nil, source: .interpolated, firstStepThisSession: false, dt: dt, dataGap: false, lastRealStepAgeSec: 0, confidence: .good)
        }

        // Warm-up window (strict 10W), but also cap by max warm-up seconds
        if inWarmup {
            let elapsed = now.timeIntervalSince(warmupStart ?? now)
            if elapsed >= Double(warmupMaxSeconds) {
                inWarmup = false // end warm-up timeout even if iOS hasn't stepped yet
            } else {
                let pctPerMin = wattsToPctPerMin(10.0)
                // Interpolate toward next boundary but never overshoot
                estSOC = min(Double(nextBoundary), max(Double(lastPercent), estSOC + pctPerMin * (elapsed/60.0)))
                let minutes = pctPerMin > 0 ? Int(((100.0 - estSOC) / pctPerMin).rounded()) : nil
                return Output(estPercent: estSOC, pctPerMin: pctPerMin, watts: 10.0, minutesToFull: minutes, source: .warmup, firstStepThisSession: false, dt: dt, dataGap: false, lastRealStepAgeSec: 0, confidence: .warmup)
            }
        }

        var firstStep = false
        var source: Source = .interpolated
        var pctPerMin: Double = 0
        var watts: Double = 0
        var minutesToFull: Int? = nil

        if pct >= lastPercent + 5 {
            // Real +5% step observed
            firstStep = (lastPercent % 5 == 0) && (inWarmup == false) && (emaPctPerMin == 0)
            source = .actualStep
            let mins = max(0.5, now.timeIntervalSince(lastChangeDate ?? now) / 60.0)
            let observed = Double(pct - lastPercent) / mins
            emaPctPerMin = ema(emaPctPerMin, observed, alpha: alphaEMA)
            lastChangeDate = now
            lastPercent = pct
            estSOC = Double(pct) // snap to boundary
            nextBoundary = min(((pct / 5) * 5) + 5, 100)
            pctPerMin = clamp(emaPctPerMin, 0.05, 3.0)
            watts = pctPerMinToWatts(pctPerMin)
            minutesToFull = etaMinutes(est: estSOC, pctPerMin: pctPerMin)
        } else {
            // Continuous interpolation toward next boundary using EMA
            let dtMin = max(1.0/60.0, (now.timeIntervalSince(lastChangeDate ?? now))/60.0)
            let r = clamp(emaPctPerMin > 0 ? emaPctPerMin : 0.5, 0.05, 3.0) // seed gently if EMA=0
            estSOC = min(Double(nextBoundary), max(Double(lastPercent), estSOC + r * dtMin))
            pctPerMin = r
            watts = pctPerMinToWatts(r)
            minutesToFull = etaMinutes(est: estSOC, pctPerMin: r)
        }

        // Flag last real +5% step
        if source == .actualStep { lastRealStep = now }

        let sinceStep = Int(now.timeIntervalSince(lastRealStep ?? warmupStart ?? now))
        let gap = dt > expectedTick * gapFactor

        // Confidence rules
        let confidence: Confidence = {
            if source == .warmup { return .warmup }
            if lastRealStep == nil { return .seeded }                   // no real step yet
            if gap { return .dataGap }
            if sinceStep > staleStepSec { return .staleStep }
            return .good
        }()

        return Output(
            estPercent: estSOC,
            pctPerMin: pctPerMin,
            watts: watts,
            minutesToFull: minutesToFull,
            source: source,
            firstStepThisSession: firstStep,
            dt: dt,
            dataGap: gap,
            lastRealStepAgeSec: sinceStep,
            confidence: confidence
        )
    }

    // MARK: - Helpers
    private func ema(_ prev: Double, _ x: Double, alpha: Double) -> Double { (1 - alpha) * prev + alpha * x }
    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
    private func pctPerMinToWatts(_ r: Double) -> Double { 0.6 * capacityAh * r * nominalVoltage }
    private func wattsToPctPerMin(_ w: Double) -> Double {
        let denom = max(0.1, 0.6 * capacityAh * nominalVoltage)
        return w / denom
    }
    private func etaMinutes(est: Double, pctPerMin: Double) -> Int? {
        guard pctPerMin > 0 else { return nil }
        return Int(((100.0 - est) / pctPerMin).rounded())
    }
}
