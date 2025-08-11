import Foundation

struct ChargeSample: Codable, Identifiable {
    let id = UUID()
    let ts: Date
    let systemPercent: Int
    let estPercent: Double
    let watts: Double
    let pctPerMin: Double
    let source: String   // "warmupFallback" | "interpolated" | "actualStep"
}

final class ChargingHistoryStore {
    private(set) var samples: [ChargeSample] = []

    func append(_ s: ChargeSample) { samples.append(s) }

    /// Rewrite samples in [from, to] to a simple linear ramp from "fromPercent" to "toPercent".
    func backfillLinear(from: Date, to: Date, fromPercent: Double, toPercent: Double) {
        guard to > from else { return }
        let span = to.timeIntervalSince(from)
        for i in samples.indices {
            let s = samples[i]
            if s.ts >= from && s.ts <= to {
                let t = s.ts.timeIntervalSince(from) / span
                let est = fromPercent + (toPercent - fromPercent) * t
                samples[i] = ChargeSample(ts: s.ts,
                                          systemPercent: s.systemPercent,
                                          estPercent: est,
                                          watts: s.watts,              // keep prior estimate; optional: recompute
                                          pctPerMin: s.pctPerMin,
                                          source: s.source)
            }
        }
    }
}
