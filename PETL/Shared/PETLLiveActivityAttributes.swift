import ActivityKit
import Foundation
#if canImport(OneSignalFramework)
import OneSignalFramework
#endif
#if canImport(OneSignalLiveActivities)
import OneSignalLiveActivities
#endif

// Basic ActivityAttributes struct that works with Live Activities
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
        
        // Additional properties for OneSignal integration
        public var deviceModel: String
        public var batteryHealth: String
        public var isInWarmUpPeriod: Bool
        public var timestamp: Date

        public init(soc: Int, watts: Double, updatedAt: Date = Date()) {
            self.soc = soc
            self.watts = watts
            self.updatedAt = updatedAt
            
            // Initialize additional properties with default values
            self.isCharging = watts > 0
            self.timeToFullMinutes = 0
            self.expectedFullDate = Date()
            self.chargingRate = watts > 0 ? "Charging" : "Not charging"
            self.batteryLevel = soc
            self.estimatedWattage = watts > 0 ? "\(Int(watts))W" : "Not charging"
            
            // Initialize OneSignal properties
            self.deviceModel = UIDevice.current.model
            self.batteryHealth = "Good"
            self.isInWarmUpPeriod = false
            self.timestamp = updatedAt
        }
        
        public init(soc: Int, watts: Double, updatedAt: Date = Date(), isCharging: Bool, timeToFullMinutes: Int, expectedFullDate: Date, chargingRate: String, batteryLevel: Int, estimatedWattage: String, deviceModel: String, batteryHealth: String, isInWarmUpPeriod: Bool, timestamp: Date) {
            self.soc = soc
            self.watts = watts
            self.updatedAt = updatedAt
            self.isCharging = isCharging
            self.timeToFullMinutes = timeToFullMinutes
            self.expectedFullDate = expectedFullDate
            self.chargingRate = chargingRate
            self.batteryLevel = batteryLevel
            self.estimatedWattage = estimatedWattage
            self.deviceModel = deviceModel
            self.batteryHealth = batteryHealth
            self.isInWarmUpPeriod = isInWarmUpPeriod
            self.timestamp = timestamp
        }
    }
    
    public init() {}
}
