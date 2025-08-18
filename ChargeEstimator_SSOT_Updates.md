# ChargeEstimator SSOT Updates

## Overview
Transform ChargeEstimator into the single source of truth for all charging computations.

## 1. Add Unified Output Struct

**File: PETL/Shared/Analytics/ChargeEstimator.swift**

Add this struct after the existing `Current` and `ChargeEstimate` structs:

```swift
struct Output {
    let pctPerMinute: Double
    let watts: Double  
    let minutesToFull: Int?
    let phase: Phase
    let pause: Bool
    let computedAt: Date
}

enum Phase: String { 
    case idle = "idle"
    case warmup = "warmup" 
    case active = "active"
    case trickle = "trickle"
}
```

## 2. Add Main Update Method

Add this method to the `ChargeEstimator` class:

```swift
func update(with raw: BatteryRawData) -> Output {
    let now = Date()
    
    // Handle not charging case
    guard raw.isCharging else {
        return Output(
            pctPerMinute: 0.0,
            watts: 0.0,
            minutesToFull: nil,
            phase: .idle,
            pause: false,
            computedAt: now
        )
    }
    
    // Start session if needed
    if sessionId == nil {
        startSession(device: DeviceProfileService.shared.current, startPct: raw.soc, at: now)
    }
    
    // Update with battery data
    noteBattery(levelPercent: raw.soc, at: now)
    
    // Get current estimate
    guard let estimate = lastEstimate, let current = current else {
        return Output(
            pctPerMinute: 0.0,
            watts: 0.0,
            minutesToFull: nil,
            phase: .warmup,
            pause: false,
            computedAt: now
        )
    }
    
    // Check for pause conditions
    let pause = ChargePauseController.shared.shouldPause(
        socPercent: raw.soc,
        watts: current.watts,
        phase: current.phase
    )
    
    return Output(
        pctPerMinute: estimate.pctPerMin,
        watts: current.watts,
        minutesToFull: estimate.minutesToFull,
        phase: current.phase,
        pause: pause,
        computedAt: now
    )
}
```

## 3. Add BatteryRawData Struct

Add this struct to the top of the file (after imports):

```swift
struct BatteryRawData {
    let soc: Int
    let isCharging: Bool
    let timestamp: Date
}
```

## 4. Remove updateFromRateEstimator Method

Delete the entire `updateFromRateEstimator` method as it's no longer needed.

## 5. Update Phase Mapping

Update the phase mapping in the `recompute` method to use the new enum:

```swift
// Replace the existing phase assignment with:
let phase: Phase = inTrickle ? .trickle : (inWarmup ? .warmup : .active)
```

## 6. Add Pause Integration

Add this import at the top:
```swift
import Foundation
import Combine
import os.log
```

And add pause checking in the main update method (already included in step 2).

## Complete Updated ChargeEstimator Structure

The final ChargeEstimator should have:

1. **Input**: `BatteryRawData` (soc, isCharging, timestamp)
2. **Output**: `Output` struct with all computed values
3. **Single computation path**: `update(with:)` method
4. **No external dependencies**: Self-contained computation
5. **Pause integration**: Uses ChargePauseController for thermal/optimized charging

## Usage in BatteryTrackingManager

Replace all existing computation logic with:

```swift
let raw = BatteryRawData(soc: batteryLevel, isCharging: isCharging, timestamp: Date())
let out = ChargeEstimator.shared.update(with: raw)

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
```

## Testing

Add these test cases to verify SSOT behavior:

```swift
func testSSOTOutput() {
    let raw = BatteryRawData(soc: 50, isCharging: true, timestamp: Date())
    let out = ChargeEstimator.shared.update(with: raw)
    
    XCTAssertNotNil(out.minutesToFull)
    XCTAssertGreaterThan(out.watts, 0)
    XCTAssertEqual(out.phase, .warmup) // or .active depending on conditions
    XCTAssertFalse(out.pause) // unless thermal conditions
}
```
