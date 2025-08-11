import Foundation
import UIKit

enum ChargingAnalytics {
    static func label(forPctPerMinute ppm: Double) -> String {
        return (ppm >= 1.0) ? "Fast" :
               (ppm >= 0.6) ? "Normal" :
               (ppm >= 0.3) ? "Slow" : "Trickle"
    }
    
    // Optional (not used by the store anymore): physics-based conversion if needed elsewhere
    static func watts(fromPctPerMinute ppm: Double, capacitymAh: Int) -> Double {
        let capWh = Double(capacitymAh) * 3.85 / 1000.0 * 0.75
        return ppm * capWh * 0.6
    }
} 