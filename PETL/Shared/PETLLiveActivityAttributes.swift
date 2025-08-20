import ActivityKit
import Foundation

// Base attributes only (temporarily no OneSignal conformance)
public struct PETLLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var soc: Int
        public var watts: Double
        public var updatedAt: Date
        
        // Additional properties for LiveActivity display
        public var isCharging: Bool
        public var timeToFullMinutes: Int
        public var expectedFullDate: Date
        public var chargingRate: String
        public var batteryLevel: Int
        public var estimatedWattage: String
        
        public init(soc: Int, watts: Double, updatedAt: Date = Date(), isCharging: Bool = false, timeToFullMinutes: Int = 0, expectedFullDate: Date = Date(), chargingRate: String = "", batteryLevel: Int = 0, estimatedWattage: String = "") {
            self.soc = soc
            self.watts = watts
            self.updatedAt = updatedAt
            self.isCharging = isCharging
            self.timeToFullMinutes = timeToFullMinutes
            self.expectedFullDate = expectedFullDate
            self.chargingRate = chargingRate
            self.batteryLevel = batteryLevel
            self.estimatedWattage = estimatedWattage
        }
    }
    public init() {}
}

