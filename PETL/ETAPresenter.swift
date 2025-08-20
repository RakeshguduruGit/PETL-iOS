import Combine
import Foundation

final class ETAPresenter: ObservableObject {
    // Unified ETA from orchestrator ticks; always prefer this when available
    @Published private(set) var unifiedEtaMinutes: Int? = nil

    // Housekeeping
    private var cancellables = Set<AnyCancellable>()
    private var lastSocChangeAt: Date = .distantPast
    private var lastEtaFromDelta: Int? = nil

    init() {
        // Prefer orchestrator-provided ETA to avoid drift during 5% plateaus
        NotificationCenter.default.publisher(for: .petlOrchestratorTick)
            .compactMap { $0.userInfo?["etaMin"] as? Int }
            .map { max(1, min($0, 240)) } // clamp to 1..240 minutes to prevent blow-ups
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] eta in
                self?.unifiedEtaMinutes = eta
            }
            .store(in: &cancellables)

        // Track SOC movement so we can freeze fallback ETA if the system stalls reporting
        NotificationCenter.default.publisher(for: .petlOrchestratorTick)
            .compactMap { $0.userInfo?["soc"] as? Int }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastSocChangeAt = Date()
            }
            .store(in: &cancellables)
    }

    /// Fallback ETA if no orchestrator value has been seen yet.
    /// - Parameters:
    ///   - socNow: current % (0..100)
    ///   - socThen: prior % at the start of the window
    ///   - dtMinutes: elapsed minutes
    /// - Returns: clamped minutes (1..240) or last known fallback
    func fallbackEtaFromDelta(socNow: Int, socThen: Int, dtMinutes: Double) -> Int? {
        guard dtMinutes > 0 else { return lastEtaFromDelta }
        let delta = max(0, socNow - socThen)
        let ratePctPerMin = Double(delta) / dtMinutes // %/min

        // If there has been no SoC movement for a while, freeze rather than ballooning ETA
        if ratePctPerMin <= 0.01 { // ≤~1% per 100 min ~ extremely slow/plateau
            if Date().timeIntervalSince(lastSocChangeAt) >= 8 * 60 {
                return lastEtaFromDelta // keep prior value during stalls
            }
        }

        let remaining = max(0, 100 - socNow)
        let eta = ratePctPerMin > 0 ? Int((Double(remaining) / ratePctPerMin).rounded()) : (lastEtaFromDelta ?? 0)
        let clamped = max(1, min(eta, 240))
        lastEtaFromDelta = clamped
        return clamped
    }

    /// Text representation that always prefers the orchestrator ETA.
    var etaText: String {
        if let m = unifiedEtaMinutes { return Self.format(minutes: m) }
        if let m = lastEtaFromDelta { return Self.format(minutes: m) }
        return "—"
    }

    private static func format(minutes: Int) -> String {
        if minutes < 90 { return "\(minutes)m" }
        return String(format: "%.1fh", Double(minutes) / 60.0)
    }
}
