import Foundation
import UIKit

public struct ChargingAnalytics {
    /// Warm-up fallback (equiv. 10W ≈ 1.5%/min)
    public static let warmupPctPerMin: Double = 1.5

    /// Returns total minutes to full based on current % and pct/min rate.
    public static func minutesToFull(
        batteryLevel0to1: Double,
        pctPerMinute: Double?
    ) -> Int? {
        let level = min(max(batteryLevel0to1, 0), 1)
        if level >= 0.999 { return 0 }
        let rate = max(pctPerMinute ?? warmupPctPerMin, 0.1)
        let remainingPct = (1.0 - level) * 100.0
        let minutes = Int(round(remainingPct / rate))
        return max(0, minutes)
    }

    /// Single place to derive display strings (mode + watts) from rate.
    public static func chargingCharacteristic(pctPerMinute: Double?) -> (label: String, watts: String) {
        let rate = pctPerMinute ?? warmupPctPerMin
        switch rate {
        case ..<0.8:  return ("Trickle", "5W")
        case ..<1.4:  return ("Standard Charging", "7.5W")
        case ..<2.2:  return ("Fast Charging", "10W")
        default:      return ("Rapid Charging", "15W")
        }
    }
} 