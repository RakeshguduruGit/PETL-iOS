import Combine
import Foundation

final class ETAPresenter: ObservableObject {
    // ===== BEGIN STABILITY-LOCKED: ETA smoothing and session steps (do not edit) =====
    private struct StepPoint { let ts: Date; let soc: Int }
    private var stepPoints: [StepPoint] = []
    @Published public private(set) var unifiedEtaMinutes: Int?
    private var lastUnifiedEta: Int?
    private let maxPoints = 6
    // ===== BEGIN STABILITY-LOCKED: Orchestrator ETA preference (do not edit) =====
    private var lastOrchestratorEtaAt: Date = .distantPast
    private let orchestratorPriorityWindow: TimeInterval = 90 // seconds
    // ===== END STABILITY-LOCKED: Orchestrator ETA preference =====
    // ===== END STABILITY-LOCKED: ETA smoothing and session steps =====

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
                self?.lastOrchestratorEtaAt = Date()
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

    // ===== BEGIN STABILITY-LOCKED: ETA ingestion (do not edit) =====
    @MainActor
    public func ingestSnapshot(levelPct: Int, isCharging: Bool, ts: Date = Date()) {
        guard isCharging else {
            stepPoints.removeAll()
            unifiedEtaMinutes = nil
            lastUnifiedEta = nil
            return
        }
        // Append only on SoC change
        if let last = stepPoints.last, last.soc == levelPct { return }
        stepPoints.append(StepPoint(ts: ts, soc: levelPct))
        if stepPoints.count > maxPoints { stepPoints.removeFirst(stepPoints.count - maxPoints) }

        guard stepPoints.count >= 2 else {
            unifiedEtaMinutes = nil
            return
        }
        let pts = stepPoints.suffix(min(3, stepPoints.count))
        guard let first = pts.first, let last = pts.last, last.ts > first.ts else {
            unifiedEtaMinutes = nil
            return
        }
        let dSoc = Double(last.soc - first.soc)
        let dMin = max(1.0, last.ts.timeIntervalSince(first.ts) / 60.0)
        let ratePctPerMin = max(0.01, dSoc / dMin)

        let remainingPct = max(0.0, Double(100 - last.soc))
        var eta = Int((remainingPct / ratePctPerMin).rounded())
        eta = max(1, min(eta, 240))

        // Clamp increases, let decreases flow
        if let prev = lastUnifiedEta, eta > prev {
            eta = min(prev + 2, eta)
        }
        lastUnifiedEta = eta
        // Prefer orchestrator ETA if we've received one within the priority window
        if Date().timeIntervalSince(lastOrchestratorEtaAt) < orchestratorPriorityWindow {
            // Keep clamped internal value for continuity, but don't override orchestrator display yet
            return
        }
        unifiedEtaMinutes = eta
    }
    // ===== END STABILITY-LOCKED: ETA ingestion =====

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
