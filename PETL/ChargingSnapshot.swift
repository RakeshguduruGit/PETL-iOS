import Foundation
import UIKit

// MARK: - Charging State Enum
enum ChargingState: String, Codable, CaseIterable {
    case unplugged = "unplugged"
    case charging = "charging"
    case full = "full"
    case unknown = "unknown"
    
    init(from batteryState: UIDevice.BatteryState) {
        switch batteryState {
        case .charging:
            self = .charging
        case .full:
            self = .full
        case .unplugged:
            self = .unplugged
        case .unknown:
            self = .unknown
        @unknown default:
            self = .unknown
        }
    }
}

// MARK: - Device Profile (imported from DeviceProfileService)
// Using the existing DeviceProfile from DeviceProfileService.swift

// MARK: - Canonical Charging Snapshot
struct ChargingSnapshot: Equatable, Sendable, Codable {
    let ts: Date
    let socPercent: Int              // 0…100
    let state: ChargingState
    let watts: Double?               // instantaneous
    let ratePctPerMin: Double?       // smoothed
    let etaMinutes: Int?             // ETAPresenter result with 3-way fallback applied centrally
    let device: DeviceProfile
    
    init(
        ts: Date,
        socPercent: Int,
        state: ChargingState,
        watts: Double?,
        ratePctPerMin: Double?,
        etaMinutes: Int?,
        device: DeviceProfile
    ) {
        self.ts = ts
        self.socPercent = max(0, min(100, socPercent)) // Clamp to valid range
        self.state = state
        self.watts = watts
        self.ratePctPerMin = ratePctPerMin
        self.etaMinutes = etaMinutes
        self.device = device
    }
    
    // Convenience initializer for creating from system state
    init(
        socPercent: Int,
        state: ChargingState,
        watts: Double?,
        ratePctPerMin: Double?,
        etaMinutes: Int?,
        device: DeviceProfile
    ) {
        self.init(
            ts: Date(),
            socPercent: socPercent,
            state: state,
            watts: watts,
            ratePctPerMin: ratePctPerMin,
            etaMinutes: etaMinutes,
            device: device
        )
    }
}

// MARK: - SSOT ETA Enforcement
extension ChargingSnapshot {
    /// Returns `self` if charging; otherwise a copy with etaMinutes = nil.
    func clearingETAIfNotCharging() -> ChargingSnapshot {
        guard state == .charging else {
            return copy(etaMinutes: nil)
        }
        return self
    }

    /// Minimal copy helper for just ETA. (include all other fields unchanged.)
    func copy(etaMinutes: Int?) -> ChargingSnapshot {
        return ChargingSnapshot(
            ts: self.ts,
            socPercent: self.socPercent,
            state: self.state,
            watts: self.watts,
            ratePctPerMin: self.ratePctPerMin,
            etaMinutes: etaMinutes,
            device: self.device
        )
    }
    
    /// Copy helper for state changes (useful for testing)
    func copy(state: ChargingState) -> ChargingSnapshot {
        return ChargingSnapshot(
            ts: self.ts,
            socPercent: self.socPercent,
            state: state,
            watts: self.watts,
            ratePctPerMin: self.ratePctPerMin,
            etaMinutes: self.etaMinutes,
            device: self.device
        )
    }
}
