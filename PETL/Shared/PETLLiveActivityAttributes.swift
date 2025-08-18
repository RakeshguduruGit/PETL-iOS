import ActivityKit
#if canImport(OneSignalFramework)
import OneSignalFramework
#endif
#if canImport(OneSignalLiveActivities)
import OneSignalLiveActivities
#endif

public struct PETLLiveActivityAttributes: ActivityAttributes
#if canImport(OneSignalLiveActivities)
, OneSignalLiveActivityAttributes
#endif
{
    public struct ContentState: Codable, Hashable {
        public var soc: Int
        public var watts: Double
        public var updatedAt: Date
        public init(soc: Int, watts: Double, updatedAt: Date = .now) {
            self.soc = soc
            self.watts = watts
            self.updatedAt = updatedAt
        }
    }
    public init() {}
}
