import ActivityKit
import Foundation

extension Notification.Name {
    static let powerDBDidChange = Notification.Name("powerDBDidChange")
}

public struct PETLLiveActivityExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        public var batteryLevel: Float
        public var isCharging: Bool
        public var chargingRate: String
        public var estimatedWattage: String
        public var timeToFullMinutes: Int
        public var deviceModel: String
        public var batteryHealth: String
        public var isInWarmUpPeriod: Bool
        public var timestamp: Date
        
        public init(batteryLevel: Float, isCharging: Bool, chargingRate: String, estimatedWattage: String, timeToFullMinutes: Int, deviceModel: String, batteryHealth: String, isInWarmUpPeriod: Bool, timestamp: Date) {
            self.batteryLevel = batteryLevel
            self.isCharging = isCharging
            self.chargingRate = chargingRate
            self.estimatedWattage = estimatedWattage
            self.timeToFullMinutes = timeToFullMinutes
            self.deviceModel = deviceModel
            self.batteryHealth = batteryHealth
            self.isInWarmUpPeriod = isInWarmUpPeriod
            self.timestamp = timestamp
        }
    }

    // Fixed non-changing properties about your activity go here!
    public var name: String
    
    public init(name: String) {
        self.name = name
    }
} 