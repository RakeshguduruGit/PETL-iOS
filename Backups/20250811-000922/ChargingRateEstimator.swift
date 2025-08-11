import Foundation

/// Smooths charging % and power between iOS's 5% SOC steps.
/// Keeps 10W during warm-up. Provides live outputs + hints for backfilling.
public final class ChargingRateEstimator {

    public struct Output {
        public let estPercent: Double          // continuous SOC (for charts, time remaining)
        public let pctPerMin: Double           // smoothed %/min (for UI + watts)
        public let watts: Double               // derived power
        public let minutesToFull: Int?         // nil if not charging or invalid
        public let source: Source
        public let backfill: Backfill?         // non-nil only at the instant of a real +5% step
        
        public init(estPercent: Double, pctPerMin: Double, watts: Double, minutesToFull: Int?, source: Source, backfill: Backfill?) {
            self.estPercent = estPercent
            self.pctPerMin = pctPerMin
            self.watts = watts
            self.minutesToFull = minutesToFull
            self.source = source
            self.backfill = backfill
        }
    }

    public enum Source { case warmupFallback, interpolated, actualStep }
    public struct Backfill { 
        public let fromDate: Date
        public let toDate: Date
        public let fromPercent: Double
        public let toPercent: Double
        
        public init(fromDate: Date, toDate: Date, fromPercent: Double, toPercent: Double) {
            self.fromDate = fromDate
            self.toDate = toDate
            self.fromPercent = fromPercent
            self.toPercent = toPercent
        }
    }

    // MARK: - Tunables
    private let alphaEMA: Double            // smoothing for %/min (e.g. 0.25)
    private let warmupMaxSeconds: Int       // cap warm-up window (e.g. 90s)
    private let nominalVoltage: Double      // 3.85 typical phone pack
    private let capacityAh: Double          // from device table, mAh/1000
    private let tickSeconds: Double         // expected tick cadence (e.g. 30s)

    // MARK: - State
    private var estSOC: Double              = 0
    private var emaPctPerMin: Double        = 0
    private var lastPercent: Int            = 0
    private var lastChangeDate: Date?
    private var lastTick: Date?
    private var warmupStart: Date?
    private var inWarmup: Bool              = true
    private var nextBoundary: Int           = 0  // next multiple of 5

    init(capacitymAh: Int,
         alphaEMA: Double = 0.25,
         warmupMaxSeconds: Int = 90,
         nominalVoltage: Double = 3.85,
         tickSeconds: Double = 30.0)
    {
        self.capacityAh = Double(capacitymAh) / 1000.0
        self.alphaEMA = alphaEMA
        self.warmupMaxSeconds = warmupMaxSeconds
        self.nominalVoltage = nominalVoltage
        self.tickSeconds = tickSeconds
    }

    // Call when charging starts
    func begin(systemPercent: Int, now: Date) {
        lastPercent = systemPercent
        estSOC = Double(systemPercent)
        warmupStart = now
        inWarmup = true
        lastChangeDate = now
        nextBoundary = min(((systemPercent / 5) * 5) + 5, 100)
        lastTick = now
    }

    // Call when unplugged or charging stops
    func end(now: Date) {
        // Snap to system % to avoid drift post-charge
        estSOC = Double(lastPercent)
        inWarmup = false
        lastChangeDate = nil
        lastTick = now
    }

    /// Main tick. Provide current system % and whether device is charging.
    func tick(systemPercent: Int, isCharging: Bool, now: Date) -> Output {
        guard isCharging else {
            estSOC = Double(systemPercent)
            return Output(estPercent: estSOC, pctPerMin: 0, watts: 0, minutesToFull: nil, source: .interpolated, backfill: nil)
        }

        let dt = max(1.0, now.timeIntervalSince(lastTick ?? now))
        lastTick = now

        var justStepped = false
        if systemPercent != lastPercent && systemPercent >= lastPercent + 5 {
            // Real iOS +5% step observed
            justStepped = true
            // Compute observed %/min for the last segment
            if let t0 = lastChangeDate {
                let mins = max(0.5, now.timeIntervalSince(t0)/60.0)
                let observedPctPerMin = Double(systemPercent - lastPercent) / mins
                // EMA update
                emaPctPerMin = (1.0 - alphaEMA) * emaPctPerMin + alphaEMA * observedPctPerMin
            } else {
                // First step gives us the initial EMA seed
                emaPctPerMin = 5.0 / max(0.5, now.timeIntervalSince(warmupStart ?? now)/60.0)
            }

            // Exit warm-up on first step
            inWarmup = false
            lastChangeDate = now
            lastPercent = systemPercent
            estSOC = Double(systemPercent) // snap to the real boundary
            nextBoundary = min(((systemPercent / 5) * 5) + 5, 100)
        }

        // Compute rate
        let pctPerMin: Double
        let watts: Double
        if inWarmup {
            // STRICT: use 10W for ALL outputs during warm-up
            watts = 10.0
            pctPerMin = Self.ratePctPerMin(fromWatts: watts, capacityAh: capacityAh, voltage: nominalVoltage)
        } else {
            pctPerMin = clamp(emaPctPerMin, min: 0.05, max: 3.0) // safety rails
            watts = Self.watts(fromPctPerMin: pctPerMin, capacityAh: capacityAh, voltage: nominalVoltage)
        }

        // Live interpolation toward next boundary (no overshoot)
        if !justStepped {
            let deltaPct = pctPerMin * (dt/60.0)
            estSOC = min(Double(nextBoundary), max(Double(lastPercent), estSOC + deltaPct))
        }

        let remaining = max(0.0, 100.0 - estSOC)
        let minutesToFull = pctPerMin > 0 ? Int((remaining / pctPerMin).rounded()) : nil

        // If we just hit a real step, propose a backfill for history smoothing
        let backfill: Backfill? = justStepped
        ? Backfill(
            fromDate: lastChangeDate?.addingTimeInterval(-dt) ?? now, // previous tick time
            toDate: now,
            fromPercent: Double(lastPercent),
            toPercent: Double(systemPercent)
          )
        : nil

        return Output(estPercent: estSOC,
                      pctPerMin: pctPerMin,
                      watts: watts,
                      minutesToFull: minutesToFull,
                      source: inWarmup ? .warmupFallback : (justStepped ? .actualStep : .interpolated),
                      backfill: backfill)
    }

    // MARK: - Helpers

    private static func watts(fromPctPerMin r: Double, capacityAh: Double, voltage: Double) -> Double {
        // r [%/min] -> I [A] = 0.6 * capacityAh * r;  P = I * V
        return 0.6 * capacityAh * r * voltage
    }

    private static func ratePctPerMin(fromWatts watts: Double, capacityAh: Double, voltage: Double) -> Double {
        // Inverse of above: r = P / (0.6 * C * V)
        let denom = max(0.1, 0.6 * capacityAh * voltage)
        return watts / denom
    }

    private func clamp(_ v: Double, min lo: Double, max hi: Double) -> Double {
        return Swift.max(lo, Swift.min(hi, v))
    }
}
