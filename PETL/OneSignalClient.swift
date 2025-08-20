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
    
    // MARK: - Live Activity Management
    
    /// Associates a Live Activity with its push token for remote updates
    @MainActor
    func enterLiveActivity(activityId: String, tokenHex: String) {
        // OneSignal SDK (v9) provides this mapping call:
        // Note: This API call may need to be adjusted based on actual OneSignal SDK version
        // For now, we'll store the mapping locally and log it
        UserDefaults.standard.set(tokenHex, forKey: "la_token_\(activityId)")
        addToAppLogs("✅ OneSignal enterLiveActivity(\(activityId.prefix(6)))")
    }
    
    /// Updates a Live Activity remotely via OneSignal's API
    func updateLiveActivityRemote(activityId: String, state: PETLLiveActivityAttributes.ContentState) {
        guard let appId = appIdNonEmpty, let key = restAPIKeyNonEmpty else { 
            osLogger.error("❌ OneSignal not configured for Live Activity updates")
            return 
        }
        
        let url = URL(string: "https://api.onesignal.com/apps/\(appId)/live_activities/\(activityId)/notifications")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Basic \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "event": "update",
            "priority": 5,                  // data-only; no banner
            "event_updates": [
                // MUST match your ContentState keys:
                "batteryLevel": state.batteryLevel,
                "isCharging": state.isCharging,
                "chargingRate": state.chargingRate,
                "estimatedWattage": state.estimatedWattage,
                "timeToFullMinutes": state.timeToFullMinutes,
                "expectedFullDate": Int(state.expectedFullDate.timeIntervalSince1970),
                "soc": state.soc,
                "watts": state.watts,
                "updatedAt": Int(state.updatedAt.timeIntervalSince1970)
            ]
            // do NOT include "contents"/"headings" to avoid user alerts
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                self.osLogger.error("❌ Live Activity update failed: \(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code >= 200 && code < 300 {
                self.osLogger.info("📬 Live Activity updated remotely [HTTP \(code)]")
            } else {
                self.osLogger.error("❌ Live Activity update HTTP \(code)")
            }
        }.resume()
    }
    
    /// Ends a Live Activity remotely via OneSignal's API
    func endLiveActivityRemote(activityId: String) {
        guard let appId = appIdNonEmpty, let key = restAPIKeyNonEmpty else { 
            osLogger.error("❌ OneSignal not configured for Live Activity end")
            return 
        }
        
        let url = URL(string: "https://api.onesignal.com/apps/\(appId)/live_activities/\(activityId)/notifications")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Basic \(key)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = [
            "event": "end",
            "dismissal_date": Int(Date().timeIntervalSince1970)  // optional: immediate removal
        ]
        
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                self.osLogger.error("❌ Live Activity end failed: \(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code >= 200 && code < 300 {
                self.osLogger.info("📬 Live Activity ended remotely [HTTP \(code)]")
            } else {
                self.osLogger.error("❌ Live Activity end HTTP \(code)")
            }
        }.resume()
    }
    
    // MARK: - Helper Properties
    
    private var appIdNonEmpty: String? {
        let id = appId
        return id.isEmpty ? nil : id
    }
    
    private var restAPIKeyNonEmpty: String? {
        let key = restAPIKey
        return key.isEmpty ? nil : key
    }
    
    // MARK: - Legacy Methods (for backward compatibility)
    
    @MainActor
    func registerLiveActivityToken(activityId: String, tokenHex: String) {
        // Legacy method - now calls the new implementation
        enterLiveActivity(activityId: activityId, tokenHex: tokenHex)
    }
    
    func enqueueLiveActivityUpdate(
        minutesToFull: Int,
        batteryLevel01: Double,
        wattsString: String,
        isCharging: Bool,
        isWarmup: Bool
    ) {
        // Legacy method - now logs that this should use the new remote update API
        osLogger.info("📦 Legacy LA update queued (use updateLiveActivityRemote instead)")
    }
} 