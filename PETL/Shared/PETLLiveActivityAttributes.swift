import ActivityKit
#if canImport(OneSignalFramework)
import OneSignalFramework
#endif
#if canImport(OneSignalLiveActivities)
import OneSignalLiveActivities
#endif

public struct PETLLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var soc: Int
        public var watts: Double
        public var updatedAt: Date
        
        public init(soc: Int, watts: Double, updatedAt: Date = Date()) {
            self.soc = soc
            self.watts = watts
            self.updatedAt = updatedAt
        }
    }
    
    public init() {}
}
