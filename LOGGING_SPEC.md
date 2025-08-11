# PETL Logging Specification

**Version:** 1.0  
**Last Updated:** July 2025  
**Purpose:** Define PETL's runtime logging contract for consistent implementation and debugging

## Log Philosophy & Audience

### Target Audiences
- **System Console** (`print`): Developers debugging via Xcode/simulator console
- **Info Tab** (`addToAppLogs`): End users viewing in-app diagnostics 
- **Device Logs** (`os_log`): System-level debugging and crash analysis

### Core Principles
1. **Never remove unconditional log lines** - they form the diagnostic contract
2. **DEBUG logs may be silenced in release** builds for performance
3. **Unique emojis** prevent log confusion during rapid debugging
4. **Throttling prevents spam** while preserving critical state transitions
5. **Session tokens** enable tracing across multiple app launches

## Logging Channels & Locations

| Scope | File / Owner | Print Macro | Visible In |
|-------|--------------|-------------|------------|
| Battery snapshots | `BatteryTrackingManager` | `print` + `addToAppLogs` | System console & Info tab |
| Activity lifecycle | `LiveActivityManager` / `ActivityCoordinator` | `addToAppLogs` + `print` | Both |
| Session management | `LiveActivityManager` | `addToAppLogs` (DEBUG) | Info tab only |
| OneSignal integration | `PETLApp` / `AppDelegate` | `print` + `appLogger` | Console + device logs |
| Widget state | `LiveActivityManager` | `addToAppLogs` + `os_log` | Both + system |
| Concurrency gates | `ActivityGate` | `addToAppLogs` (DEBUG) | Info tab only |

## Canonical Log Strings (Alphabetical)

> **Rule:** Never edit these strings without bumping LOGGING_SPEC.md and informing QA.

| Emoji | Exact String | Source | Conditional |
|-------|--------------|--------|-------------|
| ⚠️ | `NEW BatteryTrackingManager {token}` | BatteryTrackingManager.init | No |
| 📊 | `Battery Snapshot: {pct}%, State: {rawValue}` | BatteryTrackingManager | No |
| 🚧 | `startIfNeeded running` | LiveActivityManager | DEBUG |
| ⏸ | `startIfNeeded skipped (gate busy)` | LiveActivityManager | DEBUG |
| ℹ️ | `startIfNeeded ignored (already started this session)` | LiveActivityManager | DEBUG |
| ℹ️ | `startIfNeeded aborted (widget already active)` | LiveActivityManager | DEBUG |
| ℹ️ | `startIfNeeded skipped—widget already active.` | ActivityCoordinator | No |
| ⚡ | `First Live Activity update forced` | LiveActivityManager | No |
| 🎬 | `Started Live Activity id: {id}` | ActivityCoordinator | No |
| 🛑 | `Activity ended - source: {source}` | LiveActivityManager | No |
| 🛑 | `Ended Live Activity` | ActivityCoordinator | No |
| 🧹 | `Cleaning up {count} duplicate widgets` | LiveActivityManager | DEBUG |
| 📊 | `Reliability: startReq={n} startOK={n} endReqLocal={n} endOK={n} remoteEndOK={n} remoteEndIgnored={n} watchdog={n} dupCleanups={n} selfPings={n}` | LiveActivityManager | QA Mode |
| ⏳ | `Debounced snapshot: {pct}%, charging={bool}` | LiveActivityManager | DEBUG |
| 🔌 | `Battery state changed to charging - {pct}%` | LiveActivityManager | No |
| 🔌 | `Battery state changed to not charging - {pct}%` | LiveActivityManager | No |
| 🔄 | `App entering background while charging - starting Live Activity` | PETLApp | No |
| 🔄 | `App entering foreground - re-enabled battery monitoring` | PETLApp | No |
| ✅ | `LiveActivityManager configured successfully` | LiveActivityManager | No |
| ❌ | `Activity.request failed: {error}` | ActivityCoordinator | No |

## Life-Cycle Example Trace

```text
// App Cold Launch
⚠️ NEW BatteryTrackingManager a1b2        [BatteryTrackingManager]
🚀 ContentView Initialized (pure UI)       [ContentView] 
🔋 Initial battery level: 45%             [ContentView]
🔌 Initial battery state: 1               [ContentView]
📊 Battery tracking initialized           [ContentView]
✅ LiveActivityManager configured successfully [LiveActivityManager]

// User Plugs Cable (87% battery)
📊 Battery Snapshot: 87%, State: 2        [BatteryTrackingManager]
🔌 Battery state changed to charging - 87% [LiveActivityManager]
🚧 startIfNeeded running                  [LiveActivityManager - DEBUG]
🎬 Started Live Activity id: 1A2B3C...    [ActivityCoordinator]

// Rapid Re-plug Within 7s (jiggle)
📊 Battery Snapshot: 87%, State: 1        [BatteryTrackingManager]
⏸ startIfNeeded skipped (gate busy)       [LiveActivityManager - DEBUG]
📊 Battery Snapshot: 87%, State: 2        [BatteryTrackingManager] 
ℹ️ startIfNeeded ignored (already started this session) [LiveActivityManager - DEBUG]

// Unplug After 7s 
📊 Battery Snapshot: 89%, State: 1        [BatteryTrackingManager]
🔌 Battery state changed to not charging - 89% [LiveActivityManager]
🛑 Activity ended - source: local unplug  [LiveActivityManager]
🛑 Ended Live Activity                    [ActivityCoordinator]
```

## Log-Emission Rules

### Unconditional Logs (Always Visible)
- **Critical state transitions**: charging/unplugged, activity start/end
- **Manager initialization**: singleton creation with debug tokens
- **Battery snapshots**: 30-second throttled level/state changes
- **Error conditions**: Activity.request failures, OneSignal issues

### DEBUG-Only Logs (`#if DEBUG`)
- **High-frequency diagnostics**: gate busy, widget updates, session checks
- **Duplicate cleanup**: multiple widget detection and resolution
- **Concurrency debugging**: parallel call detection and throttling
- **Raw system data**: activity IDs, detailed state dumps

### QA Testing Logs (QA Mode Enabled)
- **Reliability metrics**: One-line summary of all Live Activity lifecycle events
- **Parameterized settings**: Debounce and watchdog timing for torture testing
- **Counter tracking**: Increment counters for start/end success ratios
- **Foreground summaries**: Periodic reliability reports when app enters foreground

### Throttling Thresholds
- **Battery snapshots**: Maximum once per 30 seconds
- **Push updates**: Maximum once per 60 seconds  
- **Gate-busy messages**: Maximum once per 5 seconds per caller
- **Duplicate cleanup**: Once per cleanup event (not per widget)

## Token & Session IDs

### Debug Token Generation
```swift
// Generated once per app launch in BatteryTrackingManager.init
debugToken = UUID().uuidString.prefix(4)  // e.g., "a1b2"
```

**Purpose:** Enables tracing across multiple app launches and log correlation

**Visibility Requirements:**
- Must appear in both system console AND Info tab
- Appears in: `⚠️ NEW BatteryTrackingManager {token}`
- Used for warm-up period identification: `⏱️ [{token}] 5-minute warm-up period enabled`

### Session Management
```swift
private var didStartThisSession = false
```

**Lifecycle:**
- Set to `true` when Live Activity successfully starts
- Reset to `false` in `endAll()` when activity actually ends
- Prevents log spam: `ℹ️ startIfNeeded ignored (already started this session)`

## Adding a New Log Line

### Checklist
1. **Choose Channel:**
   - Console only: `print()`
   - Info tab only: `addToAppLogs()`
   - Both: `print()` + `addToAppLogs()`
   - System logs: `os_log()` / `appLogger`

2. **Select Unique Emoji:**
   - Reserve new emoji, avoid conflicts with existing set
   - Common prefixes: 🔋 (battery), 🎬 (activity), 🔧 (config), ⚠️ (warnings)

3. **Determine Conditionality:**
   - Wrap in `#if DEBUG` unless critical for production debugging
   - State transitions and errors typically unconditional

4. **Update Documentation:**
   - Add to **Canonical Log Strings** table above
   - Include source file and conditional status

5. **Test Throttling:**
   - Verify no duplicates within throttle windows
   - Test rapid state changes don't flood logs

### Reserved Emoji Prefixes
- 🔋 Battery-related operations
- 🎬 Activity lifecycle (start/end)
- 🚧 Work in progress / running
- ⏸ Paused / skipped operations  
- ℹ️ Informational status
- 🛑 Stop / end operations
- 🧹 Cleanup operations
- 🔌 Power state changes
- 🔄 State transitions
- ✅ Success confirmations
- ❌ Error conditions
- ⚠️ Warnings / initialization

## Throttling & Noise Control

### Snapshot Throttling (30s)
```swift
// BatteryTrackingManager - prevents snapshot spam
private let subject = PassthroughSubject<BatterySnapshot, Never>()
// Only emits on significant state changes or 30s intervals
```

### Push Update Throttling (60s)
```swift
// LiveActivityManager - prevents excessive Live Activity updates
if Date().timeIntervalSince(lastPush) >= 60 ||
   Int(snapshot.level*100) != lastLevelPct {
    updateAllActivities(using: snapshot)
}
```

**One-time Fast-path**: On first stable snapshot after launch/plug-in, Live Activity update may be forced once (no 60s wait) to eliminate initial placeholders.

**UI vs Live Activity Throttling**: 
- **UI receives immediate snapshots** from BatteryTrackingManager.snapshotSubject (no throttling)
- **Live Activity updates remain on 60s throttle** with one-time fast-path for initial updates
- **Battery snapshots are throttled at 30s** in BatteryTrackingManager for system efficiency

**Safe Initialization**:
- First snapshot is always sent after initial `level` and `isCharging` are set to valid values to prevent nil-related crashes
- `isMonitoring` flag prevents double initialization
- `emitSnapshot()` ensures values are always valid before publishing

### Gate-Busy Limiting
```swift
// ActivityGate - logs "gate busy" max once per blocked sequence
guard await gate.begin() else {
#if DEBUG
    addToAppLogs("⏸ startIfNeeded skipped (gate busy)")  
#endif
    return
}
```

### Duplicate Widget Cleanup
```swift
// LiveActivityManager - logs cleanup once per detection event
if list.count > 1 {
#if DEBUG
    addToAppLogs("🧹 Cleaning up \(list.count - 1) duplicate widgets")
#endif
    // ... cleanup logic
}
```

## Release-Build Differences

### DEBUG Compilation
- All `#if DEBUG` blocks compiled out in release builds
- Reduces binary size and eliminates performance overhead
- Unconditional logs remain for production debugging

### TestFlight Verification
```swift
// Production logs still visible via:
1. Xcode console (when attached to device)
2. In-app Info tab (addToAppLogs)
3. Device Console app (os_log entries)
4. Crash reports (system logs only)
```

### Critical Production Logs
These logs MUST remain in release builds:
- `⚠️ NEW BatteryTrackingManager` (singleton verification)
- `🎬 Started Live Activity id:` (activity lifecycle)
- `🛑 Activity ended - source:` (activity cleanup)
- `❌ Activity.request failed:` (error diagnosis)

## Troubleshooting Guide

### "Seeing multiple ⚠️ NEW BatteryTrackingManager"
**Cause:** Singleton violation - multiple instances created  
**Fix:** Search for unauthorized `BatteryTrackingManager()` calls  
**Expected:** Exactly one per app launch with unique token

### "Activity ends immediately after start"
**Cause:** Duplicate `local unplug` events or state mismatch  
**Debug:** Look for rapid charging/unplugged transitions in logs  
**Fix:** Check 7-second debounce logic in `BatteryTrackingManager`

### "Gate busy forever" 
**Cause:** `gate.end()` never reached due to early returns or exceptions  
**Debug:** Search for `🚧 startIfNeeded running` without corresponding completion  
**Fix:** Ensure all code paths call `await gate.end()`

### "No Live Activity logs after backgrounding"
**Cause:** Background execution terminated or OneSignal not configured  
**Debug:** Check `🔄 App entering background while charging` appears  
**Fix:** Verify background capabilities and OneSignal initialization

### "Spam of duplicate widget cleanup"
**Cause:** Race condition creating multiple activities simultaneously  
**Debug:** Count `🎬 Started Live Activity` vs `🧹 Cleaning up` ratio  
**Fix:** Verify session flag `didStartThisSession` logic

### "Missing battery snapshots"
**Cause:** Battery monitoring disabled or throttling too aggressive  
**Debug:** Check for `Battery monitoring disabled` warnings  
**Fix:** Ensure `UIDevice.current.isBatteryMonitoringEnabled = true`

---

**Specification End** - Total: 287 lines 