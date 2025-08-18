import Foundation

extension ChargeDB {
    @discardableResult
    func insertSimulatedSoc(percent: Int, at ts: Date, quality: String) -> Bool {
        // Create a ChargeRow for SOC data (no watts for SOC-only samples)
        let row = ChargeRow(
            ts: ts.timeIntervalSince1970,
            sessionId: UUID().uuidString, // Generate new session for simulated data
            isCharging: true, // Simulated data is always during charging
            soc: percent,
            watts: nil, // No power data for SOC-only samples
            etaMinutes: nil,
            event: .sample,
            src: quality
        )
        append(row)
        return true
    }

    @discardableResult
    func insertSimulatedPower(watts: Double, at ts: Date, trickle: Bool, quality: String) -> Bool {
        // Create a ChargeRow for power data
        let row = ChargeRow(
            ts: ts.timeIntervalSince1970,
            sessionId: UUID().uuidString, // Generate new session for simulated data
            isCharging: true, // Simulated data is always during charging
            soc: 0, // We don't have SOC for power-only samples
            watts: watts,
            etaMinutes: nil,
            event: .sample,
            src: quality
        )
        append(row)
        return true
    }
}
