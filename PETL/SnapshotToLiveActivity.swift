import Foundation
import ActivityKit

// MARK: - Snapshot to Live Activity Mapper
struct SnapshotToLiveActivity {
    
    /// Convert a ChargingSnapshot to Live Activity ContentState
    /// This is the ONLY way to build ContentState - ensures consistency
    static func makeContent(from snapshot: ChargingSnapshot) -> PETLLiveActivityAttributes.ContentState {
        let now = Date()
        
        // Format charging rate
        let chargingRate: String
        if let rate = snapshot.ratePctPerMin {
            chargingRate = String(format: "%.1f%%/min", rate)
        } else {
            chargingRate = "—"
        }
        
        // Format estimated wattage
        let estimatedWattage: String
        if let watts = snapshot.watts {
            estimatedWattage = String(format: "%.1fW", watts)
        } else {
            estimatedWattage = "—"
        }
        
        // Determine if in warm-up period (first few minutes of charging)
        let isInWarmUpPeriod = snapshot.state == .charging && 
            snapshot.watts != nil && 
            snapshot.watts! < 5.0 // Less than 5W indicates warm-up
        
        // Belt-and-suspenders: ignore non-nil ETA if not charging
        let safeETAMinutes: Int
        if snapshot.state == .charging {
            safeETAMinutes = snapshot.etaMinutes ?? 0
        } else {
            safeETAMinutes = 0 // Force zero ETA when not charging
        }
        
        // Minute-snap for consistent timing between app and Live Activity
        let base = Date()
        let snappedNow = Calendar.current.date(bySetting: .second, value: 0, of: base) ?? base
        let expectedFullDate = snappedNow.addingTimeInterval(TimeInterval(safeETAMinutes * 60))
        
        return PETLLiveActivityAttributes.ContentState(
            batteryLevel: snapshot.socPercent,
            isCharging: snapshot.state == .charging,
            chargingRate: chargingRate,
            estimatedWattage: estimatedWattage,
            timeToFullMinutes: safeETAMinutes,
            expectedFullDate: expectedFullDate,
            deviceModel: snapshot.device.modelIdentifier,
            batteryHealth: "Good", // TODO: Add battery health tracking
            isInWarmUpPeriod: isInWarmUpPeriod,
            timestamp: snapshot.ts
        )
    }
    
    /// Get the current content state from the central store
    @MainActor
    static func currentContent() -> PETLLiveActivityAttributes.ContentState {
        return makeContent(from: ChargeStateStore.shared.snapshot)
    }
}
