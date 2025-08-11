import UIKit
import Combine

struct DeviceProfile {
    let rawIdentifier: String
    let name: String
    let capacitymAh: Int
    let chip: String?
}

final class DeviceProfileService: ObservableObject {
    static let shared = DeviceProfileService()
    @Published private(set) var profile: DeviceProfile?

    @MainActor func ensureLoaded() async {
        if profile != nil { return }
        let raw = rawModelIdentifier()
        addToAppLogs("🆔 Device identifier: \(raw)")
        let friendly = getFriendlyName(for: raw)
        let mah = getCapacity(for: raw)
        profile = .init(rawIdentifier: raw, name: friendly, capacitymAh: mah, chip: nil)
        addToAppLogs("🧬 Device profile ready: \(friendly) \(mah)mAh")
    }
    
    private func getFriendlyName(for identifier: String) -> String {
        let deviceNames: [String: String] = [
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,3": "iPhone 16",
            "iPhone16,4": "iPhone 16 Plus",
            "iPhone16,5": "iPhone 16 Pro",
            "iPhone16,6": "iPhone 16 Pro Max",
            "iPhone17,1": "iPhone 16 Pro"
        ]
        return deviceNames[identifier] ?? "Unknown Device"
    }
    
    private func getCapacity(for identifier: String) -> Int {
        let capacities: [String: Int] = [
            "iPhone14,2": 3095, // iPhone 13 Pro
            "iPhone14,3": 4352, // iPhone 13 Pro Max
            "iPhone14,4": 2406, // iPhone 13 mini
            "iPhone14,5": 3240, // iPhone 13
            "iPhone14,6": 2018, // iPhone SE (3rd generation)
            "iPhone14,7": 3274, // iPhone 14
            "iPhone14,8": 4323, // iPhone 14 Plus
            "iPhone15,2": 3200, // iPhone 14 Pro
            "iPhone15,3": 4323, // iPhone 14 Pro Max
            "iPhone15,4": 3349, // iPhone 15
            "iPhone15,5": 4383, // iPhone 15 Plus
            "iPhone16,1": 3274, // iPhone 15 Pro
            "iPhone16,2": 4441, // iPhone 15 Pro Max
            "iPhone16,3": 3561, // iPhone 16
            "iPhone16,4": 4476, // iPhone 16 Plus
            "iPhone16,5": 3561, // iPhone 16 Pro
            "iPhone16,6": 4676, // iPhone 16 Pro Max
            "iPhone17,1": 3561  // iPhone 16 Pro
        ]
        return capacities[identifier] ?? 3000 // Default fallback
    }
    
    private func rawModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}
