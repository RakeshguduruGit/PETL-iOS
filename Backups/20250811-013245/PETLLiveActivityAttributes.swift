import ActivityKit
import Foundation

public struct PETLLiveActivityExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var batteryLevel: Int
        public var isCharging: Bool
        public var chargingRate: String
        public var estimatedWattage: String
        public var timeToFullMinutes: Int
        public var expectedFullDate: Date
        public var deviceModel: String
        public var batteryHealth: String
        public var isInWarmUpPeriod: Bool

        // Canonical field name
        public var timestamp: Date

        // Back-compat decoder so older pushes with `computedAt` won't crash
        enum CodingKeys: String, CodingKey {
            case batteryLevel, isCharging, chargingRate, estimatedWattage,
                 timeToFullMinutes, expectedFullDate, deviceModel, batteryHealth,
                 isInWarmUpPeriod, timestamp, computedAt
        }

        public init(
            batteryLevel: Int, isCharging: Bool, chargingRate: String,
            estimatedWattage: String, timeToFullMinutes: Int, expectedFullDate: Date,
            deviceModel: String, batteryHealth: String, isInWarmUpPeriod: Bool,
            timestamp: Date
        ) {
            self.batteryLevel = batteryLevel
            self.isCharging = isCharging
            self.chargingRate = chargingRate
            self.estimatedWattage = estimatedWattage
            self.timeToFullMinutes = timeToFullMinutes
            self.expectedFullDate = expectedFullDate
            self.deviceModel = deviceModel
            self.batteryHealth = batteryHealth
            self.isInWarmUpPeriod = isInWarmUpPeriod
            self.timestamp = timestamp
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            batteryLevel = try c.decode(Int.self, forKey: .batteryLevel)
            isCharging = try c.decode(Bool.self, forKey: .isCharging)
            chargingRate = try c.decode(String.self, forKey: .chargingRate)
            estimatedWattage = try c.decode(String.self, forKey: .estimatedWattage)
            timeToFullMinutes = try c.decode(Int.self, forKey: .timeToFullMinutes)
            expectedFullDate = try c.decode(Date.self, forKey: .expectedFullDate)
            deviceModel = try c.decode(String.self, forKey: .deviceModel)
            batteryHealth = try c.decode(String.self, forKey: .batteryHealth)
            isInWarmUpPeriod = try c.decode(Bool.self, forKey: .isInWarmUpPeriod)
            // accept either `timestamp` or legacy `computedAt`
            timestamp = (try? c.decodeIfPresent(Date.self, forKey: .timestamp))
                     ?? (try? c.decodeIfPresent(Date.self, forKey: .computedAt))
                     ?? Date()
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(batteryLevel, forKey: .batteryLevel)
            try c.encode(isCharging, forKey: .isCharging)
            try c.encode(chargingRate, forKey: .chargingRate)
            try c.encode(estimatedWattage, forKey: .estimatedWattage)
            try c.encode(timeToFullMinutes, forKey: .timeToFullMinutes)
            try c.encode(expectedFullDate, forKey: .expectedFullDate)
            try c.encode(deviceModel, forKey: .deviceModel)
            try c.encode(batteryHealth, forKey: .batteryHealth)
            try c.encode(isInWarmUpPeriod, forKey: .isInWarmUpPeriod)
            try c.encode(timestamp, forKey: .timestamp)
        }
    }

    // Fixed non-changing properties about your activity go here!
    public var name: String
    
    public init(name: String) {
        self.name = name
    }
}
