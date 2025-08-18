# PETL SSOT Architecture Cleanup - Implementation Plan

## Overview
Transform PETL from dual-engine architecture to single source of truth (SSOT) with ChargeEstimator as the only computation engine.

## Architecture (After Cleanup)
```
Flow: iOS battery events → BatteryTrackingManager → ChargeEstimator (SSOT) → ChargingSnapshot → ChargeStateStore → UI + Live Activity (+ ChargeDB for charts)
```

## Phase 0: Create Branch
```bash
git checkout -b cleanup/ssot-architecture
```

## Phase 1: File Surgery (DELETE)

### Files to Remove
```bash
# Core duplicates
rm PETL/Shared/Analytics/ChargingRateEstimator.swift
rm PETL/Shared/Analytics/ChargingHistoryStore.swift  
rm PETL/ETAPresenter.swift

# Optional Live Activity files (if not shipping)
rm PETLLiveActivityExtension/PETLLiveActivityExtension.swift
rm PETLLiveActivityExtension/PETLLiveActivityExtensionControl.swift
rm PETLLiveActivityExtension/AppIntent.swift
```

### Code Surgery
**File: PETLLiveActivityExtension/PETLLiveActivityExtensionLiveActivity.swift**
- Remove lines 12-85 (duplicate PETLLiveActivityExtensionAttributes definition)
- Keep only the shared PETLLiveActivityAttributes.swift

## Phase 2: Make ChargeEstimator the SSOT

### Update ChargeEstimator.swift
**Add unified Output struct:**
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

**Add main update method:**
```swift
func update(with raw: BatteryRawData) -> Output {
    // Single computation path
    // Return unified Output
}
```

### Inline SafeChargingSmoother
- Move SafeChargingSmoother logic into ChargeEstimator as private methods
- Keep ChargePauseController as separate helper

## Phase 3: Trim BatteryTrackingManager

### Search & Replace Rules

**Remove ETAPresenter usage:**
```swift
// OLD:
let etaOutput = ETAPresenter.shared.presented(...)
let minutes = etaOutput.minutes

// NEW:
let out = ChargeEstimator.shared.update(with: raw)
let minutes = out.minutesToFull
```

**Remove ChargingRateEstimator usage:**
```swift
// OLD:
let rateOut = ChargingRateEstimator.tick(...)
ChargeEstimator.shared.updateFromRateEstimator(rateOut)

// NEW:
let out = ChargeEstimator.shared.update(with: raw)
```

**Centralize snapshot creation:**
```swift
// OLD: Multiple snapshot creation paths
// NEW: Single path in BatteryTrackingManager
let out = ChargeEstimator.shared.update(with: raw)
let snapshot = ChargingSnapshot(
    socPercent: raw.soc,
    isCharging: raw.isCharging,
    pctPerMinute: out.pctPerMinute,
    watts: out.watts,
    minutesToFull: out.minutesToFull,
    phase: out.phase,
    pause: out.pause,
    analyticsLabel: ChargingAnalytics.label(forPctPerMinute: out.pctPerMinute),
    device: DeviceProfileService.shared.current,
    timestamp: Date()
)
ChargeStateStore.shared.publish(snapshot)
ChargeDB.shared.insertPower(snapshot)
LiveActivityManager.shared.update(from: snapshot)
```

## Phase 4: UI & Live Activity Read from One Place

### ContentView.swift Updates
**Bind to ChargeStateStore:**
```swift
// OLD: Multiple data sources
// NEW: Single source
@StateObject private var chargeStore = ChargeStateStore.shared

// In body:
let snapshot = chargeStore.snapshot
Text("\(snapshot.minutesToFull ?? 0)m")
Text("\(String(format: "%.1f", snapshot.watts))W")
```

### LiveActivityManager.swift Updates
**Map from snapshot:**
```swift
// OLD: Multiple computation paths
// NEW: Single mapper
func update(from snapshot: ChargingSnapshot) {
    let content = SnapshotToLiveActivity.makeContent(from: snapshot)
    // Update Activity with content
}
```

### SnapshotToLiveActivity.swift
**Keep as mapper:**
```swift
// Keep existing mapper logic
static func makeContent(from snapshot: ChargingSnapshot) -> PETLLiveActivityAttributes.ContentState {
    // Map snapshot to ContentState
}
```

## Phase 5: Logging & QA Toggles

### Standardize Logger Categories
```swift
// Add to top of each file:
private let logger = Logger(subsystem: "com.petl.app", category: "battery") // or "estimator", "la", "db", "ui"
```

### Gate Verbose Logs
```swift
// OLD: Unconditional logging
// NEW: QA-gated
if QAConfig.enabled {
    logger.debug("Detailed debug info")
}
```

## Phase 6: Config & Assets

### Extension Info.plist
```xml
<key>NSSupportsLiveActivities</key>
<true/>
```

### Asset Sharing
- Add PETLLogoLiveActivity to extension asset catalog
- Or share with target membership

### Entitlements
```xml
<!-- Debug -->
<key>aps-environment</key>
<string>development</string>

<!-- Release (add) -->
<key>aps-environment</key>
<string>production</string>
```

## Phase 7: Tests & Smoke Script

### Unit Tests
```swift
// Add to PETLTests/
class ChargeEstimatorTests: XCTestCase {
    func testPhaseTransitions() { /* warmup→active→trickle */ }
    func testMinutesMonotonic() { /* decreases while charging */ }
    func testPauseHandling() { /* thermal/optimized charging */ }
}
```

### UI Test
```swift
// Add to PETLTests/
class UITests: XCTestCase {
    func testRingAndLAMatch() {
        // Assert ring minutes == Live Activity minutes
        // Assert ring watts == Live Activity watts
    }
}
```

## Search & Replace Commands

### Remove ETAPresenter Imports
```bash
find . -name "*.swift" -exec sed -i '' 's/import.*ETAPresenter//g' {} \;
```

### Remove ChargingRateEstimator Imports  
```bash
find . -name "*.swift" -exec sed -i '' 's/import.*ChargingRateEstimator//g' {} \;
```

### Remove ChargingHistoryStore Imports
```bash
find . -name "*.swift" -exec sed -i '' 's/import.*ChargingHistoryStore//g' {} \;
```

## QA Checklist (Copy/Paste)

### A. Correctness
- [ ] Snapshot invariants: isCharging=false ⇒ minutesToFull=nil, watts=0, phase=idle
- [ ] minutesToFull decreases monotonically while charging (allow ±1 jitter)
- [ ] phase transitions: warmup → normal → trickle (no backward jumps)
- [ ] pause set for thermal/optimized charging; clears on resume
- [ ] Same numbers everywhere: ContentView ring minutes == Live Activity minutes
- [ ] ContentView watts == Live Activity watts
- [ ] Label ("Fast/Normal/Slow/Trickle") matches in UI & LA
- [ ] 5% SOC steps: ETA snaps cleanly across each 5% change (no spikes > 3 min)
- [ ] DB writes exactly one sample per event/tick policy

### B. Live Activity / Island
- [ ] Starts on plug, re-starts on replug within cooldown, ends on unplug
- [ ] Updates on (a) 5% steps, (b) Δminutes ≥ 1, (c) Δwatts ≥ 0.5, min interval ≥ 10s
- [ ] Lock screen: minimal/compact/expanded layouts render without truncation
- [ ] Dynamic Island: minimal/bubble/expanded all show same key fields
- [ ] Asset (logo) loads in extension
- [ ] Background push (if enabled): correct APNs headers; LA updates

### C. Persistence & Charts
- [ ] ChargeDB.ensureSchema() runs once; schema version stored
- [ ] Power bars show continuous data; no gaps across foreground/background
- [ ] Query windows (last 12h / 24h) return expected row counts

### D. Performance
- [ ] CPU avg while charging < 3% in foreground, < 1% background
- [ ] LA updates ≤ 6/min; DB writes ≤ 6/min
- [ ] SQLite file size growth ≤ 2MB/day at default sampling
- [ ] Memory stable; no retain cycles (Activity/manager/closures)

### E. Stability / Lifecycle
- [ ] App kill/relaunch rehydrates last snapshot correctly
- [ ] Foreground gate: no LA updates while app inactive
- [ ] No duplicate Activities after replug
- [ ] Error handling: DB write failures & Activity update failures logged and recovered

### F. Config & Release
- [ ] Extension deployment target (Live Activities supported) set on both targets
- [ ] aps-environment = development for Debug; production before TestFlight
- [ ] Remove unused targets/files before archive (size check)

## Definition of Done
- [ ] Project builds with no warnings
- [ ] Deleted files are gone; no dead imports
- [ ] One code path produces minutes & watts
- [ ] Ring, Island, Lock screen all show identical values
- [ ] Charts load from DB after a 10–15 min charging session
- [ ] QA checklist A–F passes

## Execution Time Estimate
- Phase 1 (File Surgery): 5 minutes
- Phase 2-4 (Code Updates): 20 minutes  
- Phase 5-6 (Config): 5 minutes
- Phase 7 (Tests): 10 minutes
- **Total: ~40 minutes**
