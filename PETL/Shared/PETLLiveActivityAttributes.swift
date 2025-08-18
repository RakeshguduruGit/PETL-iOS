import Foundation
import ActivityKit

// Live Activity attributes used by both the app and the extension.
public struct PETLLiveActivityExtensionAttributes: ActivityAttributes, Sendable {

    // Dynamic content rendered on the Island/Lock Screen.
    public struct ContentState: Codable, Hashable, Sendable {
        public var batteryLevel: Int                // 0...100
        public var isCharging: Bool
        public var chargingRate: String             // e.g., "10.0 W"
        public var estimatedWattage: String         // e.g., "10.0W"
        public var timeToFullMinutes: Int           // ETA minutes (>=0)
        public var expectedFullDate: Date           // ETA absolute date
        public var deviceModel: String              // e.g., "iPhone17,1"
        public var batteryHealth: String            // e.g., "100%"
        public var isInWarmUpPeriod: Bool
        public var timestamp: Date                  // snapshot timestamp

        public init(
            batteryLevel: Int,
            isCharging: Bool,
            chargingRate: String,
            estimatedWattage: String,
            timeToFullMinutes: Int,
            expectedFullDate: Date,
            deviceModel: String,
            batteryHealth: String,
            isInWarmUpPeriod: Bool,
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
    }

    // Static attributes (rarely change while activity is active).
    public var name: String

    public init(name: String) {
        self.name = name
    }
}
