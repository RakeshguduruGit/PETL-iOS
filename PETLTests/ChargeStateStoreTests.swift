import XCTest
@testable import PETL

final class ChargeStateStoreTests: XCTestCase {
    
    @MainActor
    func testETAIsClearedWhenNotCharging() {
        // Create a test snapshot with ETA
        let deviceProfile = DeviceProfile(
            rawIdentifier: "iPhone16,1",
            name: "iPhone 16 Pro",
            capacitymAh: 3500,
            chip: "A18 Pro"
        )
        
        var snap = ChargingSnapshot(
            ts: Date(),
            socPercent: 50,
            state: .charging,
            watts: 15.0,
            ratePctPerMin: 2.5,
            etaMinutes: 42, // Has ETA
            device: deviceProfile
        )
        
        // Test 1: ETA should be cleared when state is unplugged
        snap = snap.copy(etaMinutes: 42) // Ensure ETA is set
        snap = snap.copy(state: .unplugged) // Change to unplugged
        
        ChargeStateStore.shared.apply(snap)
        XCTAssertNil(ChargeStateStore.shared.snapshot.etaMinutes, "ETA should be nil when unplugged")
        
        // Test 2: ETA should be cleared when state is full
        snap = snap.copy(etaMinutes: 42) // Ensure ETA is set
        snap = snap.copy(state: .full) // Change to full
        
        ChargeStateStore.shared.apply(snap)
        XCTAssertNil(ChargeStateStore.shared.snapshot.etaMinutes, "ETA should be nil when full")
        
        // Test 3: ETA should be cleared when state is unknown
        snap = snap.copy(etaMinutes: 42) // Ensure ETA is set
        snap = snap.copy(state: .unknown) // Change to unknown
        
        ChargeStateStore.shared.apply(snap)
        XCTAssertNil(ChargeStateStore.shared.snapshot.etaMinutes, "ETA should be nil when unknown")
        
        // Test 4: ETA should be preserved when charging
        snap = snap.copy(etaMinutes: 42) // Ensure ETA is set
        snap = snap.copy(state: .charging) // Change to charging
        
        ChargeStateStore.shared.apply(snap)
        XCTAssertEqual(ChargeStateStore.shared.snapshot.etaMinutes, 42, "ETA should be preserved when charging")
    }
    
    @MainActor
    func testSnapshotCopyHelper() {
        let deviceProfile = DeviceProfile(
            rawIdentifier: "iPhone16,1",
            name: "iPhone 16 Pro",
            capacitymAh: 3500,
            chip: "A18 Pro"
        )
        
        let original = ChargingSnapshot(
            ts: Date(),
            socPercent: 50,
            state: .charging,
            watts: 15.0,
            ratePctPerMin: 2.5,
            etaMinutes: 42,
            device: deviceProfile
        )
        
        // Test copy helper preserves all fields except etaMinutes
        let copied = original.copy(etaMinutes: nil)
        
        XCTAssertEqual(copied.ts, original.ts)
        XCTAssertEqual(copied.socPercent, original.socPercent)
        XCTAssertEqual(copied.state, original.state)
        XCTAssertEqual(copied.watts, original.watts)
        XCTAssertEqual(copied.ratePctPerMin, original.ratePctPerMin)
        XCTAssertEqual(copied.device.rawIdentifier, original.device.rawIdentifier)
        XCTAssertNil(copied.etaMinutes)
        XCTAssertEqual(original.etaMinutes, 42) // Original unchanged
    }
}
