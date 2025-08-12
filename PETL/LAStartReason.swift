import Foundation

// MARK: - Live Activity Start Reasons
enum LAStartReason: String {
    case launch = "LAUNCH-CHARGING"
    case chargeBegin = "CHARGE-BEGIN"
    case replugAfterCooldown = "REPLUG-AFTER-COOLDOWN"
    case snapshot = "BATTERY-SNAPSHOT"
    case debug = "DEBUG"
}
