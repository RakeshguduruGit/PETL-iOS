# BatteryTrackingManager SSOT Updates

## Overview
Update BatteryTrackingManager to use ChargeEstimator as the single source of truth and remove all duplicate computation logic.

## 1. Remove Imports

**File: PETL/BatteryTrackingManager.swift**

Remove these imports if they exist:
```swift
// Remove these lines:
// import ChargingRateEstimator
// import ETAPresenter
// import ChargingHistoryStore
```

## 2. Remove Instance Variables

Remove these instance variables that are no longer needed:
```swift
// Remove these lines:
// private var rateEstimator: ChargingRateEstimator?
// private var etaPresenter: ETAPresenter?
// private var historyStore: ChargingHistoryStore?
```

## 3. Centralize Snapshot Creation

Replace all existing snapshot creation logic with this single path:

```swift
private func processBatteryUpdate(batteryLevel: Int, isCharging: Bool) {
    let now = Date()
    
    // Single source of truth computation
    let raw = BatteryRawData(soc: batteryLevel, isCharging: isCharging, timestamp: now)
    let out = ChargeEstimator.shared.update(with: raw)
    
    // Create unified snapshot
    let snapshot = ChargingSnapshot(
        socPercent: raw.soc,
        isCharging: raw.isCharging,
        pctPerMinute: out.pctPerMinute,
        watts: out.watts,
        minutesToFull: out.minutesToFull,
        phase: out.phase.rawValue,
        pause: out.pause,
        analyticsLabel: ChargingAnalytics.label(forPctPerMinute: out.pctPerMinute),
        device: DeviceProfileService.shared.current,
        timestamp: out.computedAt
    )
    
    // Publish to all consumers
    ChargeStateStore.shared.publish(snapshot)
    ChargeDB.shared.insertPower(snapshot)
    LiveActivityManager.shared.update(from: snapshot)
    
    // Log the update
    if QAConfig.enabled {
        logger.debug("🔋 Battery update: \(batteryLevel)% charging=\(isCharging) ETA=\(out.minutesToFull?.description ?? "nil")m W=\(String(format:"%.1f", out.watts))")
    }
}
```

## 4. Update Battery Event Handlers

Replace all battery event handlers to use the centralized method:

```swift
// Replace existing battery event handlers with:
func batteryLevelDidChange(_ level: Int) {
    processBatteryUpdate(batteryLevel: level, isCharging: UIDevice.current.isCharging)
}

func batteryStateDidChange(_ state: UIDevice.BatteryState) {
    let isCharging = (state == .charging || state == .full)
    processBatteryUpdate(batteryLevel: Int(UIDevice.current.batteryLevel * 100), isCharging: isCharging)
}
```

## 5. Update Timer Tick

Replace the timer tick method:

```swift
@objc private func timerTick() {
    let batteryLevel = Int(UIDevice.current.batteryLevel * 100)
    let isCharging = UIDevice.current.isCharging
    
    processBatteryUpdate(batteryLevel: batteryLevel, isCharging: isCharging)
}
```

## 6. Remove Initialization Code

Remove any initialization code for the deleted classes:

```swift
// Remove these lines from init() or setup methods:
// rateEstimator = ChargingRateEstimator(capacitymAh: device.capacitymAh)
// etaPresenter = ETAPresenter.shared
// historyStore = ChargingHistoryStore()
```

## 7. Update Session Management

Replace session start/end logic:

```swift
private func startChargingSession() {
    // ChargeEstimator handles session management internally
    // Just log the start
    if QAConfig.enabled {
        logger.debug("🔌 Charging session started")
    }
}

private func endChargingSession() {
    ChargeEstimator.shared.endSession()
    
    // Create final snapshot (not charging)
    let batteryLevel = Int(UIDevice.current.batteryLevel * 100)
    processBatteryUpdate(batteryLevel: batteryLevel, isCharging: false)
    
    if QAConfig.enabled {
        logger.debug("🔌 Charging session ended")
    }
}
```

## 8. Add Logger

Add this at the top of the file:
```swift
private let logger = Logger(subsystem: "com.petl.app", category: "battery")
```

## 9. Complete Updated Structure

The final BatteryTrackingManager should have:

1. **Single computation path**: `processBatteryUpdate()`
2. **No duplicate logic**: All computation delegated to ChargeEstimator
3. **Unified publishing**: Single snapshot published to all consumers
4. **Clean session management**: Simple start/end logging
5. **QA-gated logging**: Verbose logs only when QA enabled

## 10. Search & Replace Commands

Run these commands to find and replace old patterns:

```bash
# Find ETAPresenter usage
grep -r "ETAPresenter" PETL/BatteryTrackingManager.swift

# Find ChargingRateEstimator usage  
grep -r "ChargingRateEstimator" PETL/BatteryTrackingManager.swift

# Find ChargingHistoryStore usage
grep -r "ChargingHistoryStore" PETL/BatteryTrackingManager.swift
```

## 11. Verification Checklist

After updates, verify:

- [ ] No references to ETAPresenter, ChargingRateEstimator, or ChargingHistoryStore
- [ ] Single `processBatteryUpdate()` method handles all battery events
- [ ] All battery events call the centralized method
- [ ] Snapshot creation uses ChargeEstimator output only
- [ ] All consumers (UI, Live Activity, DB) get the same snapshot
- [ ] QA-gated logging is in place
- [ ] Session management is simplified

## 12. Testing

Add this test to verify SSOT behavior:

```swift
func testBatteryTrackingManagerSSOT() {
    let manager = BatteryTrackingManager.shared
    
    // Simulate battery event
    manager.batteryLevelDidChange(50)
    
    // Verify all consumers get same data
    let snapshot = ChargeStateStore.shared.snapshot
    let dbSnapshot = ChargeDB.shared.latestSnapshot
    let laSnapshot = LiveActivityManager.shared.currentSnapshot
    
    XCTAssertEqual(snapshot.minutesToFull, dbSnapshot?.minutesToFull)
    XCTAssertEqual(snapshot.watts, laSnapshot?.watts)
}
```
