import UIKit

@MainActor
final class AppForegroundGate {
    static let shared = AppForegroundGate()

    private var pendingReason: LAStartReason?
    private var observer: NSObjectProtocol?

    var isActive: Bool {
        // any scene in foregroundActive OR whole app active
        if UIApplication.shared.applicationState == .active { return true }
        return UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }

    func runWhenActive(reason: LAStartReason, _ work: @escaping () -> Void) {
        if isActive {
            work()
            return
        }
        // coalesce: keep the latest reason
        pendingReason = reason
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let r = self.pendingReason
                    self.pendingReason = nil
                    if let obs = self.observer {
                        NotificationCenter.default.removeObserver(obs)
                        self.observer = nil
                    }
                    if r != nil { work() /* wrapper will use r again below */ }
                }
            }
        }
    }
}
