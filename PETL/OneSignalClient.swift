import Foundation
import os.log
import OneSignalFramework

final class OneSignalClient {
    static let shared = OneSignalClient()
    private init() {}

    private let osLogger = Logger(subsystem: "com.petl.app", category: "onesignal")

    // Keep this in DEBUG only. In prod, send from your backend.
    // Store these in Info.plist or Build Settings (never hardcode).
    private var restAPIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "ONESIGNAL_REST_API_KEY") as? String ?? ""
    }
    private var appId: String {
        Bundle.main.object(forInfoDictionaryKey: "ONESIGNAL_APP_ID") as? String ?? ""
    }
    private var playerId: String {
        // Your app already logs the device token; use the same value source you display in logs.
        UserDefaults.standard.string(forKey: "OneSignalPlayerID") ?? ""
    }

    private(set) var seq: Int = 0
    func bumpSeq() -> Int { seq &+= 1; return seq }

    /// Sends a silent self "end" ping using OneSignal REST.
    func enqueueSelfEnd(seq: Int) {
        guard !restAPIKey.isEmpty, !appId.isEmpty, !playerId.isEmpty else {
            osLogger.error("❌ OneSignal REST not configured (missing key/appId/playerId). Skipping self end (seq=\(seq)).")
            return
        }

        osLogger.info("📦 Enqueue self end (seq=\(seq))")

        let url = URL(string: "https://api.onesignal.com/notifications")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.addValue("Basic \(restAPIKey)", forHTTPHeaderField: "Authorization")

        // Silent notification (content_available: true) with our action + seq
        let body: [String: Any] = [
            "app_id": appId,
            "include_player_ids": [playerId],
            "content_available": true,
            "priority": 10,
            "data": [
                "live_activity_action": "end",
                "seq": seq
            ]
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                self.osLogger.error("❌ Self end request failed (seq=\(seq)): \(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code >= 200 && code < 300 {
                self.osLogger.info("📬 Self end queued (seq=\(seq)) [HTTP \(code)]")
            } else {
                self.osLogger.error("❌ Self end HTTP \(code) (seq=\(seq))")
            }
        }.resume()
    }
    
    @MainActor
    func registerLiveActivityToken(activityId: String, tokenHex: String) {
        // TODO(cursor): send to your backend; or store as a OneSignal tag if your pipeline uses it.
        OneSignal.User.addTag(key: "la_token", value: tokenHex)
        OneSignal.User.addTag(key: "la_activity_id", value: activityId)
        addToAppLogs("✅ Registered LiveActivity token")
    }
    
    func enqueueLiveActivityUpdate(
        minutesToFull: Int,
        batteryLevel01: Double,
        wattsString: String,
        isCharging: Bool,
        isWarmup: Bool
    ) {
        // TODO: call your backend or OneSignal's Live Activity API
        // with the activityId + push token + content-state.
        osLogger.info("📦 LA remote update queued (m=\(minutesToFull), lvl=\(batteryLevel01), w=\(wattsString), chg=\(isCharging), warm=\(isWarmup))")
    }
} 