# PETL SSOT Architecture - QA Checklist

## Pre-Testing Setup
- [ ] Run cleanup script: `./cleanup_execution_script.sh`
- [ ] Apply ChargeEstimator updates from `ChargeEstimator_SSOT_Updates.md`
- [ ] Apply BatteryTrackingManager updates from `BatteryTrackingManager_Updates.md`
- [ ] Apply Live Activity cleanup from `LiveActivity_Cleanup.md`
- [ ] Build project: `xcodebuild -project PETL.xcodeproj -scheme PETL build`
- [ ] Install on device/simulator

---

## A. Correctness Tests

### A1. Snapshot Invariants
- [ ] **Not charging state**: When `isCharging = false`:
  - [ ] `minutesToFull` is `nil`
  - [ ] `watts` is `0.0` (or `nil`)
  - [ ] `phase` is `"idle"`
  - [ ] `pause` is `false`

### A2. Minutes Monotonicity
- [ ] **Decreasing ETA**: While charging, `minutesToFull` decreases over time
- [ ] **Jitter tolerance**: Allow ±1 minute jitter between updates
- [ ] **No negative values**: `minutesToFull` is never negative
- [ ] **Reasonable bounds**: `minutesToFull` is never > 480 (8 hours)

### A3. Phase Transitions
- [ ] **Warmup → Active**: Transitions from `"warmup"` to `"active"` after 10min or 5% increase
- [ ] **Active → Trickle**: Transitions to `"trickle"` at 80% SOC
- [ ] **No backward jumps**: Never goes from `"trickle"` back to `"active"` or `"warmup"`
- [ ] **Idle state**: Shows `"idle"` when not charging

### A4. Pause Handling
- [ ] **Thermal pause**: Pause activates during thermal throttling
- [ ] **Optimized charging**: Pause activates during optimized charging phases
- [ ] **Pause clears**: Pause clears when conditions normalize
- [ ] **Pause state**: `pause` field correctly reflects current state

### A5. Same Numbers Everywhere
- [ ] **Ring vs Live Activity**: ContentView ring minutes == Live Activity minutes
- [ ] **Ring vs Live Activity**: ContentView watts == Live Activity watts
- [ ] **Ring vs Lock Screen**: Ring values == Lock screen Live Activity values
- [ ] **Dynamic Island**: All Dynamic Island states show same key values
- [ ] **Label consistency**: "Fast/Normal/Slow/Trickle" matches in UI & Live Activity

### A6. 5% SOC Steps
- [ ] **Clean transitions**: ETA snaps cleanly across each 5% SOC change
- [ ] **No spikes**: No ETA spikes > 3 minutes during transitions
- [ ] **Smooth interpolation**: Values interpolate smoothly between 5% steps
- [ ] **Boundary snapping**: Values snap to actual boundaries at 5% steps

### A7. Database Writes
- [ ] **One sample per event**: DB writes exactly one sample per battery event
- [ ] **Tick policy**: DB writes follow the configured tick interval (30s default)
- [ ] **No duplicates**: No duplicate timestamps in database
- [ ] **Schema integrity**: Database schema is created correctly

---

## B. Live Activity / Dynamic Island Tests

### B1. Lifecycle Management
- [ ] **Starts on plug**: Live Activity starts when charging begins
- [ ] **Re-starts on replug**: Live Activity re-starts if replugged within cooldown period
- [ ] **Ends on unplug**: Live Activity ends when charging stops
- [ ] **No duplicates**: Only one Live Activity exists at a time
- [ ] **Cooldown respect**: Respects cooldown period between activities

### B2. Update Frequency
- [ ] **5% steps**: Updates when battery level changes by 5%
- [ ] **Minutes changes**: Updates when `Δminutes ≥ 1`
- [ ] **Watts changes**: Updates when `Δwatts ≥ 0.5`
- [ ] **Minimum interval**: Respects minimum 10-second update interval
- [ ] **Not too frequent**: Updates ≤ 6/min to avoid throttling

### B3. Layout Rendering
- [ ] **Lock screen minimal**: Minimal layout renders without truncation
- [ ] **Lock screen compact**: Compact layout renders without truncation
- [ ] **Lock screen expanded**: Expanded layout renders without truncation
- [ ] **Dynamic Island minimal**: Minimal state shows key fields
- [ ] **Dynamic Island bubble**: Bubble state shows key fields
- [ ] **Dynamic Island expanded**: Expanded state shows key fields

### B4. Asset Loading
- [ ] **Logo loads**: PETLLogoLiveActivity loads correctly in extension
- [ ] **Background loads**: WidgetBackground loads correctly
- [ ] **No missing assets**: No asset loading errors in console
- [ ] **Correct sizing**: Assets display at correct sizes

### B5. Background Push (if enabled)
- [ ] **APNs headers**: Correct APNs headers for Live Activity updates
- [ ] **Push delivery**: Live Activity updates via push notifications
- [ ] **Background updates**: Updates work when app is in background
- [ ] **Error handling**: Failed pushes are logged and handled gracefully

---

## C. Persistence & Charts Tests

### C1. Database Schema
- [ ] **Schema creation**: `ChargeDB.ensureSchema()` runs once on first launch
- [ ] **Version storage**: Schema version is stored and checked
- [ ] **Migration handling**: Schema migrations work correctly
- [ ] **No corruption**: Database file is not corrupted

### C2. Power Bars Chart
- [ ] **Continuous data**: Power bars show continuous data without gaps
- [ ] **Foreground/background**: No gaps when app goes to background and returns
- [ ] **Time windows**: Last 12h and 24h windows show expected data
- [ ] **Data accuracy**: Chart values match stored database values
- [ ] **Performance**: Chart renders smoothly without lag

### C3. Query Performance
- [ ] **12h window**: Returns expected row count for last 12 hours
- [ ] **24h window**: Returns expected row count for last 24 hours
- [ ] **Query speed**: Queries complete in < 100ms
- [ ] **Memory usage**: Chart queries don't cause memory spikes

---

## D. Performance Tests

### D1. CPU Usage
- [ ] **Foreground charging**: CPU avg < 3% while charging in foreground
- [ ] **Background charging**: CPU avg < 1% while charging in background
- [ ] **Idle state**: CPU avg < 0.5% when not charging
- [ ] **No spikes**: No CPU spikes > 10% for more than 1 second

### D2. Update Frequency
- [ ] **Live Activity updates**: ≤ 6 updates per minute
- [ ] **Database writes**: ≤ 6 writes per minute
- [ ] **UI updates**: UI updates smoothly without stuttering
- [ ] **Timer efficiency**: Timer ticks don't cause performance issues

### D3. Storage Growth
- [ ] **SQLite growth**: Database file grows ≤ 2MB per day at default sampling
- [ ] **No bloat**: No unnecessary data accumulation
- [ ] **Cleanup**: Old data is cleaned up appropriately
- [ ] **File size**: Total app storage doesn't grow excessively

### D4. Memory Management
- [ ] **No retain cycles**: No memory leaks in Activity/manager/closures
- [ ] **Stable memory**: Memory usage remains stable over time
- [ ] **Background memory**: Memory usage drops in background
- [ ] **No leaks**: Memory usage doesn't grow indefinitely

---

## E. Stability / Lifecycle Tests

### E1. App Lifecycle
- [ ] **Kill/relaunch**: App rehydrates last snapshot correctly after kill/relaunch
- [ ] **Background/foreground**: App handles background/foreground transitions
- [ ] **Memory warnings**: App handles memory warnings gracefully
- [ ] **System updates**: App continues working after system updates

### E2. Foreground Gate
- [ ] **No LA updates when inactive**: Live Activity doesn't update when app is inactive
- [ ] **Resumes on foreground**: Live Activity updates resume when app becomes active
- [ ] **Gate respect**: Foreground gate is respected consistently
- [ ] **No bypass**: No Live Activity updates bypass the gate

### E3. Activity Management
- [ ] **No duplicates**: No duplicate Activities after replug
- [ ] **Clean termination**: Activities terminate cleanly
- [ ] **State consistency**: Activity state is consistent with app state
- [ ] **Error recovery**: Failed Activity operations are recovered

### E4. Error Handling
- [ ] **DB write failures**: Database write failures are logged and handled
- [ ] **Activity update failures**: Activity update failures are logged and handled
- [ ] **Push failures**: Push notification failures are logged and handled
- [ ] **Graceful degradation**: App continues working despite failures

---

## F. Configuration & Release Tests

### F1. Deployment Targets
- [ ] **Extension target**: Live Activity extension deployment target supports Live Activities
- [ ] **Main target**: Main app deployment target is appropriate
- [ ] **Compatibility**: Both targets are compatible with each other

### F2. Entitlements
- [ ] **Debug environment**: `aps-environment = development` for Debug builds
- [ ] **Release environment**: `aps-environment = production` for Release builds
- [ ] **Live Activities**: Live Activities entitlement is present
- [ ] **Push notifications**: Push notification entitlement is present (if used)

### F3. Build Configuration
- [ ] **No warnings**: Project builds with no warnings
- [ ] **No errors**: Project builds with no errors
- [ ] **Archive size**: App archive size is reasonable
- [ ] **No unused files**: No unused files in final build

---

## Test Execution Instructions

### Manual Testing
1. **Setup**: Install app on device/simulator
2. **Charging session**: Connect charger and monitor for 10-15 minutes
3. **Unplug/replug**: Test unplug and replug scenarios
4. **Background**: Test background/foreground transitions
5. **Thermal**: Test thermal throttling scenarios (if possible)
6. **Memory**: Test memory pressure scenarios

### Automated Testing
```bash
# Run unit tests
xcodebuild -project PETL.xcodeproj -scheme PETL -destination 'platform=iOS Simulator,name=iPhone 15' test

# Run UI tests
xcodebuild -project PETL.xcodeproj -scheme PETL -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:PETLTests/UITests
```

### Performance Testing
```bash
# Monitor CPU usage
instruments -t Time\ Profiler -D trace.trace PETL.app

# Monitor memory usage
instruments -t Allocations -D trace.trace PETL.app
```

---

## Pass/Fail Criteria

### Must Pass (Critical)
- All tests in sections A1-A7 (Correctness)
- All tests in sections B1-B3 (Live Activity lifecycle and rendering)
- All tests in sections C1-C2 (Database and charts)
- All tests in sections D1-D2 (Performance - CPU and updates)
- All tests in sections E1-E2 (Stability - lifecycle and foreground gate)

### Should Pass (Important)
- All tests in sections B4-B5 (Assets and push)
- All tests in sections D3-D4 (Storage and memory)
- All tests in sections E3-E4 (Activity management and error handling)
- All tests in sections F1-F3 (Configuration and build)

### Pass Rate Target
- **Critical tests**: 100% pass rate required
- **Important tests**: 95% pass rate required
- **Overall**: 98% pass rate required for release

---

## Issue Tracking

For each failed test:
1. **Document**: Record the specific failure
2. **Reproduce**: Ensure the failure is reproducible
3. **Investigate**: Identify the root cause
4. **Fix**: Implement the fix
5. **Verify**: Re-run the test to confirm fix
6. **Regression**: Ensure fix doesn't break other tests
