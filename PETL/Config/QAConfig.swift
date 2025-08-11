import Foundation

enum QA {
    /// Turn on via:
    /// 1) Launch arg: -QA_TEST_MODE
    /// 2) UserDefaults bool: QA_TEST_MODE = true
    static var enabled: Bool {
        if UserDefaults.standard.bool(forKey: "QA_TEST_MODE") { return true }
        if ProcessInfo.processInfo.arguments.contains("-QA_TEST_MODE") { return true }
        return false
    }

    /// Battery state debounce (seconds)
    static var debounceSeconds: Double { enabled ? 0.0 : 1.2 }

    /// Watchdog timeout (seconds) before sending the fallback self-ping
    static var watchdogSeconds: Double { enabled ? 25.0 : 75.0 }
} 