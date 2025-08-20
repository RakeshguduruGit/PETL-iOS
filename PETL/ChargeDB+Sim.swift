import Foundation
import OSLog

fileprivate let _simLogger = Logger(subsystem: "com.petl.app", category: "ChargeDB+Sim")

/// Maintains a stable sessionId while charging. Resets on session end.
enum SimSession {
    private static let key = "ChargeDBCurrentSessionId"

    static var currentId: String {
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let s = "sim-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(s, forKey: key)
        return s
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// Reset session id on app's charging session end
extension Notification.Name {
    static let _simSessionEnded = Notification.Name("petl.session.ended") // matches PETLApp extension
}
final class _SimSessionObserver {
    static let shared = _SimSessionObserver()
    private init() {
        NotificationCenter.default.addObserver(forName: ._simSessionEnded, object: nil, queue: .main) { _ in
            _simLogger.info("🔄 Resetting simulated session id (session ended)")
            SimSession.reset()
        }
    }
}
// Ensure the observer is alive
private let _simSessionObserver = _SimSessionObserver.shared

extension ChargeDB {

    /// Insert a simulated SOC sample using the public `append(ChargeRow)` API.
    /// - Parameters:
    ///   - percent: 0...100
    ///   - ts: timestamp
    ///   - quality: "simulated" (or "measured" if you reuse this path later)
    @discardableResult
    func insertSimulatedSoc(percent: Int, at ts: Date, quality: String) -> Bool {
        let row = ChargeRow(
            ts: ts.timeIntervalSince1970,
            sessionId: SimSession.currentId,
            isCharging: true,
            soc: max(0, min(100, percent)),
            watts: nil,                 // SOC-only row
            etaMinutes: nil,            // not used here
            event: .sample,             // <-- If your enum uses a different case, adjust here.
            src: quality                // "simulated"
        )
        _simLogger.info("🪵 append(SOC) \(row.soc)% @\(ts) session=\(row.sessionId, privacy: .public)")
        append(row)
        return true
    }

    /// Insert a simulated Power sample using the public `append(ChargeRow)` API.
    /// - Parameters:
    ///   - watts: charging power
    ///   - ts: timestamp
    ///   - trickle: mark if <10W (purely informational; kept out of row to avoid schema drift)
    ///   - quality: "simulated"
    @discardableResult
    func insertSimulatedPower(watts: Double, at ts: Date, trickle: Bool, quality: String) -> Bool {
        let w = max(0.0, watts)
        let row = ChargeRow(
            ts: ts.timeIntervalSince1970,
            sessionId: SimSession.currentId,
            isCharging: w > 0.0,
            soc: -1,                    // SOC unknown in this row (SOC changes arrive via its own path)
            watts: w,
            etaMinutes: nil,
            event: .sample,             // <-- If your enum uses a different case, adjust here.
            src: quality                // "simulated"
        )
        _simLogger.info("🪵 append(Power) \(w, privacy: .public)W @\(ts) session=\(row.sessionId, privacy: .public)\(trickle ? " (trickle)" : "")")
        append(row)
        return true
    }
}
