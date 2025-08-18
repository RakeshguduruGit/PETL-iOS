import Foundation
import Combine
import UIKit

// MARK: - Central Charge State Store
@MainActor
final class ChargeStateStore: ObservableObject {
    static let shared = ChargeStateStore()
    
    @Published private(set) var snapshot: ChargingSnapshot
    
    private init() {
        // Initialize with a default snapshot
        let deviceProfile = DeviceProfile(
            rawIdentifier: "Unknown",
            name: "Unknown Device",
            capacitymAh: 3000,
            chip: nil
        )
        
        self.snapshot = ChargingSnapshot(
            ts: Date(),
            socPercent: 0,
            state: ChargingState.unknown,
            watts: nil,
            ratePctPerMin: nil,
            etaMinutes: nil,
            device: deviceProfile
        )
    }
    
    /// Apply a new charging snapshot - this is the only way to update the canonical state
    func apply(_ next: ChargingSnapshot) {
        let enforced = next.clearingETAIfNotCharging()
        
        // Runtime assert to catch any SSOT breaches
        #if DEBUG
        assert(enforced.state == .charging || enforced.etaMinutes == nil,
               "SSOT breach: ETA must be nil when not charging")
        #else
        if enforced.state != .charging && enforced.etaMinutes != nil {
            BatteryTrackingManager.shared.addToAppLogs("❌ SSOT breach (release) — clearing ETA")
            // TODO: increment a lightweight metric if you have one
        }
        #endif
        
        self.snapshot = enforced
    }
    
    /// Get the current device profile from the snapshot
    var currentDevice: DeviceProfile {
        snapshot.device
    }
    
    /// Get the current charging state
    var currentState: ChargingState {
        snapshot.state
    }
    
    /// Get the current battery level as a percentage
    var currentBatteryLevel: Int {
        snapshot.socPercent
    }
    
    /// Get the current charging watts
    var currentWatts: Double? {
        snapshot.watts
    }
    
    /// Get the current charging rate as percentage per minute
    var currentRatePctPerMin: Double? {
        snapshot.ratePctPerMin
    }
    
    /// Get the current ETA in minutes
    var currentETAMinutes: Int? {
        snapshot.etaMinutes
    }
    
    /// Check if currently charging
    var isCharging: Bool {
        snapshot.state == .charging
    }
    
    /// Check if battery is full
    var isFull: Bool {
        snapshot.state == .full
    }
    
    /// Check if unplugged
    var isUnplugged: Bool {
        snapshot.state == .unplugged
    }
}
