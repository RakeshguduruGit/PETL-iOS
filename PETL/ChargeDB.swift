import SQLite3
import Foundation

enum ChargeEvent: String { case sample, session_start, session_end }

struct ChargeRow {
    let ts: TimeInterval        // seconds since 1970
    let sessionId: String
    let isCharging: Bool
    let soc: Int                // 0..100
    let watts: Double?          // nil for markers
    let etaMinutes: Int?        // optional
    let event: ChargeEvent
    let src: String?
}

final class ChargeDB {
    static let shared = ChargeDB()
    private var db: OpaquePointer?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("charge.db").path
        sqlite3_open(path, &db)
        ensureSchema()
    }
    
    private func notifyDBChangedCoalesced() {
        notifyQ.async {
            let now = Date()
            guard now.timeIntervalSince(self.lastNotify) > self.minNotifyInterval else { return }
            self.lastNotify = now
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .powerDBDidChange, object: nil)
            }
        }
    }

    private func ensureSchema() {
        _ = exec("""
          CREATE TABLE IF NOT EXISTS charge_log(
            ts REAL NOT NULL,
            session_id TEXT NOT NULL,
            is_charging INTEGER NOT NULL,
            soc INTEGER NOT NULL,
            watts REAL,
            eta_minutes INTEGER,
            event TEXT NOT NULL,
            src TEXT
          );
          CREATE UNIQUE INDEX IF NOT EXISTS idx_charge_log_session_ts
          ON charge_log(session_id, ts);
          CREATE INDEX IF NOT EXISTS idx_ts ON charge_log(ts);
          CREATE INDEX IF NOT EXISTS idx_session ON charge_log(session_id);
        """)
        
        // Check if watts column exists
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA table_info(charge_log)", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        
        var hasWatts = false
        while sqlite3_step(st) == SQLITE_ROW {
            let colName = String(cString: sqlite3_column_text(st, 1))
            if colName == "watts" {
                hasWatts = true
                break
            }
        }
        
        if !hasWatts {
            _ = exec("ALTER TABLE charge_log ADD COLUMN watts REAL;")
            Task { @MainActor in
                addToAppLogs("🧱 DB migration — added watts column")
            }
        }
    }

    // MARK: - Thread-safe notification coalescing
    private let notifyQ = DispatchQueue(label: "db.notify.queue")
    private var lastNotify = Date.distantPast
    private let minNotifyInterval: TimeInterval = 1.0

    @discardableResult
    @available(*, unavailable, message: "Use BatteryTrackingManager persist path.")
    public func insertPower(ts: Date, session: UUID?, soc: Int, isCharging: Bool, watts: Double) -> Int64 {
        fatalError("stability-locked: Use BatteryTrackingManager.persistPowerSample instead")
    }
    
    // Internal method for BatteryTrackingManager only
    internal func _insertPowerLocked(ts: Date, session: UUID?, soc: Int, isCharging: Bool, watts: Double) -> Int64 {
        let sid = session?.uuidString ?? ""
        // store quantized seconds consistently
        let tsSec = floor(ts.timeIntervalSince1970)

        // Use INSERT OR IGNORE to prevent duplicates
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO charge_log(ts,session_id,is_charging,soc,watts,eta_minutes,event,src) VALUES (?,?,?,?,?,?,?,?)", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, tsSec)
        sqlite3_bind_text(st, 2, sid, -1, nil)
        sqlite3_bind_int(st, 3, isCharging ? 1 : 0)
        sqlite3_bind_int(st, 4, Int32(soc))
        sqlite3_bind_double(st, 5, watts)
        sqlite3_bind_null(st, 6) // eta_minutes
        sqlite3_bind_text(st, 7, ChargeEvent.sample.rawValue, -1, nil)
        sqlite3_bind_text(st, 8, "power_tick", -1, nil)
        sqlite3_step(st)
        
        let rowid = sqlite3_last_insert_rowid(db)
        
        // ===== BEGIN STABILITY-LOCKED: DB notify (do not edit) =====
        // Notify only when a row was actually inserted
        if sqlite3_changes(db) > 0 {
            notifyQ.async {
                let now = Date()
                guard now.timeIntervalSince(self.lastNotify) > self.minNotifyInterval else { return }
                self.lastNotify = now
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .powerDBDidChange, object: nil)
                }
            }
        }
        // ===== END STABILITY-LOCKED =====
        return rowid
    }

    func countPowerSamples(hours: Int) -> Int {
        let to = Date()
        let from = to.addingTimeInterval(-TimeInterval(hours * 3600))
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM charge_log WHERE ts BETWEEN ? AND ? AND watts IS NOT NULL", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
        if sqlite3_step(st) == SQLITE_ROW {
            return Int(sqlite3_column_int(st, 0))
        }
        return 0
    }

    @discardableResult private func exec(_ sql: String) -> Int32 {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let e = err { print("SQL ERR", String(cString: e)); sqlite3_free(e) }
        return rc
    }

    func append(_ r: ChargeRow) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO charge_log(ts,session_id,is_charging,soc,watts,eta_minutes,event,src) VALUES (?,?,?,?,?,?,?,?)", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, r.ts)
        sqlite3_bind_text(st, 2, r.sessionId, -1, nil)
        sqlite3_bind_int(st, 3, r.isCharging ? 1 : 0)
        sqlite3_bind_int(st, 4, Int32(r.soc))
        if let w = r.watts { sqlite3_bind_double(st, 5, w) } else { sqlite3_bind_null(st, 5) }
        if let e = r.etaMinutes { sqlite3_bind_int(st, 6, Int32(e)) } else { sqlite3_bind_null(st, 6) }
        sqlite3_bind_text(st, 7, r.event.rawValue, -1, nil)
        if let s = r.src { sqlite3_bind_text(st, 8, s, -1, nil) } else { sqlite3_bind_null(st, 8) }
        sqlite3_step(st)
    }

    func trim(olderThanDays days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        _ = exec("DELETE FROM charge_log WHERE ts < \(cutoff)")
    }

    func range(from: Date, to: Date) -> [ChargeRow] {
        var out: [ChargeRow] = []; var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts,session_id,is_charging,soc,watts,eta_minutes,event,src FROM charge_log WHERE ts BETWEEN ? AND ? AND (src != 'present' OR soc > 0) ORDER BY ts ASC", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
        while sqlite3_step(st) == SQLITE_ROW {
            let ts = sqlite3_column_double(st, 0)
            let sid = String(cString: sqlite3_column_text(st,1))
            let chg = sqlite3_column_int(st,2) == 1
            let soc = Int(sqlite3_column_int(st,3))
            let watts = sqlite3_column_type(st,4) == SQLITE_NULL ? nil : sqlite3_column_double(st,4)
            let eta = sqlite3_column_type(st,5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st,5))
            let ev  = ChargeEvent(rawValue: String(cString: sqlite3_column_text(st,6))) ?? .sample
            let src = sqlite3_column_type(st,7) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(st,7))
            out.append(.init(ts: ts, sessionId: sid, isCharging: chg, soc: soc, watts: watts, etaMinutes: eta, event: ev, src: src))
        }
        return out
    }

    // Optional: one-time migration from legacy UserDefaults
    func migrateLegacyIfNeeded() {
        // At the start of migrateFromLegacy() …
        let migratedFlagKey = "chargeDB_migrated_v1"
        if UserDefaults.standard.bool(forKey: migratedFlagKey) { return }
        
        let key = "PETLBatteryTrackingData"
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        struct Legacy: Codable { let timestamp: Date; let batteryLevel: Float; let isCharging: Bool }
        if let rows = try? JSONDecoder().decode([Legacy].self, from: data) {
            let sid = UUID().uuidString
            for r in rows {
                append(.init(ts: r.timestamp.timeIntervalSince1970,
                             sessionId: sid,
                             isCharging: r.isCharging,
                             soc: Int(round(r.batteryLevel * 100)),
                             watts: nil,
                             etaMinutes: nil,
                             event: .sample,
                             src: "legacy"))
            }
            UserDefaults.standard.removeObject(forKey: key)
            Task { @MainActor in
                addToAppLogs("🗄️ Migrated \(rows.count) legacy history rows to DB")
            }
        }
        
        // … after successful migration:
        UserDefaults.standard.set(true, forKey: migratedFlagKey)
    }
}
