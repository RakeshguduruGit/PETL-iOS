import Foundation
import UIKit

enum ChargingAnalytics {
    static func chargingCharacteristic(pctPerMinute ppm: Double) -> (String, String) {
        let label: String =
            (ppm >= 1.0) ? "Fast" :
            (ppm >= 0.6) ? "Normal" :
            (ppm >= 0.3) ? "Slow" : "Trickle"

        let watts = max(0.0, 10.0 * (ppm / 1.0)) // 1.0 %/min ≈ 10W baseline
        return (label, String(format: "%.1fW", watts))
    }
} 