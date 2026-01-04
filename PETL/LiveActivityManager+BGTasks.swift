import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

// Provide a safe no-op registration hook for LiveActivityManager in the app target.
// This prevents accidental duplicate BGTask registrations if other modules call into it.
extension LiveActivityManager {
    @MainActor
    func registerBackgroundTasks() {
        // Intentionally no-op. All BGTask registrations are centralized in BackgroundTaskManager.
        // Keeping this method avoids linker errors if call sites exist, and documents ownership.
    }
}
