import XCTest
@testable import PETL

final class PowerPersistenceTests: XCTestCase {
    
    func testWarmupOnlyOncePerSession() {
        let db = FakeChargeDB()
        let tm = BatteryTrackingManager.testable(db: db)
        
        tm.handleChargeBegan()
        tm.simulateTick(confidence: .warmup, watts: 10, soc: 70)  // first warmup
        tm.simulateTick(confidence: .warmup, watts: 10, soc: 70)  // should NOT insert
        
        XCTAssertEqual(db.inserted.count, 1, "Warmup must persist once")
        XCTAssertEqual(db.inserted.first?.watts, 10.0)
    }
    
    func testMeasuredThrottleEvery5s() {
        let db = FakeChargeDB()
        let tm = BatteryTrackingManager.testable(db: db)
        tm.handleChargeBegan()
        tm.simulateTick(confidence: .measured, watts: 6.0, soc: 71, at: 0)
        tm.simulateTick(confidence: .measured, watts: 6.1, soc: 71, at: 3)   // <5s → ignore
        tm.simulateTick(confidence: .measured, watts: 6.2, soc: 72, at: 6)   // ≥5s → insert
        
        XCTAssertEqual(db.inserted.count, 2)
    }
    
    func testSessionLifecycle() {
        let db = FakeChargeDB()
        let tm = BatteryTrackingManager.testable(db: db)
        
        // Begin session
        tm.handleChargeBegan()
        XCTAssertNotNil(tm.currentSessionId)
        
        // End session
        tm.handleChargeEnded()
        XCTAssertNil(tm.currentSessionId)
        
        // Should have end marker
        XCTAssertEqual(db.inserted.count, 1)
        XCTAssertEqual(db.inserted.first?.watts, 0.0)
    }
    
    func testDoubleBeginPrevention() {
        let db = FakeChargeDB()
        let tm = BatteryTrackingManager.testable(db: db)
        
        tm.handleChargeBegan()
        let firstSessionId = tm.currentSessionId
        
        tm.handleChargeBegan() // should be ignored
        XCTAssertEqual(tm.currentSessionId, firstSessionId)
    }
    
    func testDoubleEndPrevention() {
        let db = FakeChargeDB()
        let tm = BatteryTrackingManager.testable(db: db)
        
        tm.handleChargeBegan()
        tm.handleChargeEnded()
        XCTAssertNil(tm.currentSessionId)
        
        tm.handleChargeEnded() // should be ignored
        XCTAssertNil(tm.currentSessionId)
    }
}

// MARK: - Test Helpers

private final class FakeChargeDB: ChargeDBProtocol {
    struct Row { 
        let ts: TimeInterval
        let watts: Double
        let session: String
        let soc: Int
        let isCharging: Bool
    }
    var inserted: [Row] = []
    
    func insertPower(ts: Date, session: UUID?, soc: Int, isCharging: Bool, watts: Double) -> Int64 {
        inserted.append(.init(
            ts: ts.timeIntervalSince1970,
            watts: watts,
            session: session?.uuidString ?? "",
            soc: soc,
            isCharging: isCharging
        ))
        return Int64(inserted.count)
    }
    
    func countPowerSamples(hours: Int) -> Int {
        return inserted.count
    }
}

// MARK: - BatteryTrackingManager Test Extensions

extension BatteryTrackingManager {
    static func testable(db: ChargeDBProtocol) -> BatteryTrackingManager {
        let tm = BatteryTrackingManager()
        // Inject test dependencies
        return tm
    }
    
    func simulateTick(confidence: SafeChargingSmoother.Confidence, watts: Double, soc: Int, at timeOffset: TimeInterval = 0) {
        // Simulate a power tick with given parameters
        let now = Date().addingTimeInterval(timeOffset)
        // This would need to be implemented based on the actual tick method
    }
}
