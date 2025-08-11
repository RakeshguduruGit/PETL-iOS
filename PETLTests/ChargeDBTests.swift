import XCTest
@testable import PETL

final class ChargeDBTests: XCTestCase {
    func testEtaNullRoundTrip() {
        // Insert a row with eta_minutes = NULL
        let now = Date().timeIntervalSince1970
        ChargeDB.shared.insert(.init(
            ts: now, sessionId: "T-NULL-ETA", isCharging: true, soc: 50,
            watts: 10.0, etaMinutes: nil, event: .sample, src: "test"))
        // Read it back
        let rows = ChargeDB.shared.range(from: Date(timeIntervalSince1970: now - 1),
                                         to:   Date(timeIntervalSince1970: now + 1))
        let rec = rows.first { $0.sessionId == "T-NULL-ETA" }
        XCTAssertNotNil(rec)
        XCTAssertNil(rec?.etaMinutes, "eta_minutes should remain nil, not 0")
    }
}
