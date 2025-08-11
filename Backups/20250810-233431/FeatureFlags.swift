import Foundation

enum FeatureFlags {
    static let smoothChargingAnalytics = false
    
    /// Phase-1: live smoothing for power/rate/time (no chart changes yet)
    static let smoothAnalyticsP1 = true
    
    /// Phase 1.7: pause detection (logs only, no UI change)
    static let pauseDetectionP1 = true
    
    /// Phase 2.0: ETA/Power governor + stall freeze
    static let governorP2 = true
    
    /// Phase 3.0: ETA presenter for UI layer spike prevention
    static let useETAPresenter = true
    
    /// Phase 3.0: ETA quarantine with spike detection and slew limiting
    static let etaQuarantineP3 = true
}
