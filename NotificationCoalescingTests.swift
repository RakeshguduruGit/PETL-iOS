import XCTest
@testable import PETL

final class NotificationCoalescingTests: XCTestCase {
    
    func testNotifyCoalesced() {
        let db = ChargeDB.inMemoryForTests(minNotifyInterval: 1.0)
        let nc = NotificationCenter()
        var fires = 0
        let token = nc.addObserver(forName: .powerDBDidChange, object: nil, queue: .main) { _ in 
            fires += 1 
        }
        
        // burst of inserts within 1s
        for i in 0..<5 {
            _ = db.insertPower(
                ts: Date(timeIntervalSince1970: TimeInterval(i)), 
                session: UUID(), 
                soc: 50, 
                isCharging: true, 
                watts: 5.0
            )
        }
        
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(fires, 1, "Notifications must be coalesced")
        nc.removeObserver(token)
    }
    
    func testNotifyRespectsMinimumInterval() {
        let db = ChargeDB.inMemoryForTests(minNotifyInterval: 2.0)
        let nc = NotificationCenter()
        var fires = 0
        let token = nc.addObserver(forName: .powerDBDidChange, object: nil, queue: .main) { _ in 
            fires += 1 
        }
        
        // First insert
        _ = db.insertPower(
            ts: Date(), 
            session: UUID(), 
            soc: 50, 
            isCharging: true, 
            watts: 5.0
        )
        
        // Wait 1s (less than minimum interval)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        
        // Second insert
        _ = db.insertPower(
            ts: Date(), 
            session: UUID(), 
            soc: 51, 
            isCharging: true, 
            watts: 5.1
        )
        
        // Wait for notifications to process
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(fires, 1, "Second notification should be suppressed")
        nc.removeObserver(token)
    }
    
    func testNotifyAfterMinimumInterval() {
        let db = ChargeDB.inMemoryForTests(minNotifyInterval: 1.0)
        let nc = NotificationCenter()
        var fires = 0
        let token = nc.addObserver(forName: .powerDBDidChange, object: nil, queue: .main) { _ in 
            fires += 1 
        }
        
        // First insert
        _ = db.insertPower(
            ts: Date(), 
            session: UUID(), 
            soc: 50, 
            isCharging: true, 
            watts: 5.0
        )
        
        // Wait 1.5s (more than minimum interval)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        
        // Second insert
        _ = db.insertPower(
            ts: Date(), 
            session: UUID(), 
            soc: 51, 
            isCharging: true, 
            watts: 5.1
        )
        
        // Wait for notifications to process
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        XCTAssertEqual(fires, 2, "Both notifications should fire")
        nc.removeObserver(token)
    }
    
    func testNoNotifyOnDuplicateInsert() {
        let db = ChargeDB.inMemoryForTests(minNotifyInterval: 1.0)
        let nc = NotificationCenter()
        var fires = 0
        let token = nc.addObserver(forName: .powerDBDidChange, object: nil, queue: .main) { _ in 
            fires += 1 
        }
        
        let session = UUID()
        let timestamp = Date()
        
        // Insert same data twice (should be ignored due to unique constraint)
        _ = db.insertPower(ts: timestamp, session: session, soc: 50, isCharging: true, watts: 5.0)
        _ = db.insertPower(ts: timestamp, session: session, soc: 50, isCharging: true, watts: 5.0)
        
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(fires, 1, "Only one notification for unique insert")
        nc.removeObserver(token)
    }
}

// MARK: - ChargeDB Test Extensions

extension ChargeDB {
    static func inMemoryForTests(minNotifyInterval: TimeInterval) -> ChargeDB {
        // Create an in-memory database for testing
        // This would need to be implemented based on the actual ChargeDB structure
        return ChargeDB.shared
    }
}
