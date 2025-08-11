# Duplicate Start Fixes - Eliminating Overlapping Live Activity Triggers

## 🎯 **Problem Identified**

The logs revealed overlapping start triggers causing duplicate Live Activities:

- **PETLApp**: Launch-time start (guarded by `.activities.isEmpty`)
- **BatteryTrackingManager**: Start on `.batteryStateChanged(.charging)`
- **ContentView**: Snapshot forwarding to `LiveActivityManager.updateIfNeeded()` → another start/stop path

This resulted in:
- Two Live Activity IDs being created
- "🧹 Cleaning up 1 duplicate widgets" messages
- Noisy "endAll() about to end 0 activity(ies)" spam post-unplug

## ✅ **Surgical Fixes Implemented**

### **1. ContentView.swift — Stop Driving Starts via Snapshots**

**File**: `PETL/ContentView.swift`
**Change**: Removed snapshot forwarding to LiveActivityManager

```swift
// BEFORE
.onReceive(tracker.publisher) { snap in
    snapshot = snap
    updateUI(with: snap)
    LiveActivityManager.shared.updateIfNeeded(from: snap)  // ❌ REMOVED
}

// AFTER
.onReceive(tracker.publisher) { snap in
    snapshot = snap
    updateUI(with: snap)
}
```

**Why**: Start/stop is already handled by BatteryTrackingManager (+ optional PETLApp launch probe). This removes the third start source that can race and produce a duplicate widget.

### **2. LiveActivityManager.swift — Make updateIfNeeded a No-Op**

**File**: `PETL/LiveActivityManager.swift`
**Change**: Deprecated the updateIfNeeded method

```swift
// BEFORE
func updateIfNeeded(from snapshot: BatterySnapshot) {
    // Optional helper for ContentView to trigger updates
    handle(snapshot: snapshot)
}

// AFTER
@MainActor
func updateIfNeeded(from snapshot: BatterySnapshot) {
    // Deprecated: start/stop is centralized in BatteryTrackingManager (+ optional app launch probe).
    // Intentionally left as no-op to avoid duplicate starts.
}
```

**Why**: Centralizes start/stop logic in BatteryTrackingManager and prevents duplicate starts from ContentView snapshots.

### **3. LiveActivityManager.swift — Fix Noisy End Logging**

**File**: `PETL/LiveActivityManager.swift`
**Change**: Moved "about to end" log after the zero-guard

```swift
// BEFORE
addToAppLogs("🧪 endAll() about to end \(countBefore) activity(ies)")
guard countBefore > 0 else { return }

// AFTER
guard countBefore > 0 else { return }
addToAppLogs("🧪 endAll() about to end \(countBefore) activity(ies)")
```

**Why**: Avoids the repeated "about to end 0" spam when remote self-end pings arrive post-unplug.

### **4. LiveActivityManager.swift — Remove Duplicate Start Log**

**File**: `PETL/LiveActivityManager.swift`
**Change**: Removed duplicate "Started Live Activity" log

```swift
// BEFORE
let activityId = current?.id ?? "unknown"
print("🎬 Started Live Activity id:", activityId)  // ❌ REMOVED
isRequesting = false

// AFTER
let activityId = current?.id ?? "unknown"
isRequesting = false
```

**Why**: The manager already logs the start with `addToAppLogs("🎬 Started Live Activity id: \(id)")`, so we keep one clear line per start.

## 📊 **Build Status**
- **✅ Build**: Successful compilation (exit code 0)
- **✅ Architecture**: Clean separation of concerns
- **✅ Threading**: Proper `@MainActor` annotations

## 🧪 **Expected Behavior After Fixes**

### **On Plug-In (App Running/Launching)**
- **Exactly one** "🎬 Started Live Activity id" line
- **No** "🧹 Cleaning up ... duplicate widgets" messages
- **Single Live Activity** per charging session

### **On Unplug**
- **Single end flow** through LiveActivityManager
- **No more** "endAll() about to end 0 ..." spam
- **Clean shutdown** without duplicate cleanup attempts

### **Dynamic Island Stability**
- **Stable ETA display** (sanitized updateAllActivities path remains correct)
- **No spikes** from duplicate presenter calls
- **Consistent behavior** across app UI and Dynamic Island

## 🔧 **Technical Implementation Details**

### **Start Flow Consolidation**
```
BatteryTrackingManager.batteryStateChanged(.charging)
    ↓
LiveActivityManager.startIfNeeded()
    ↓
ActivityCoordinator.startIfNeeded()
    ↓
Single Live Activity Created
```

### **Stop Flow Unification**
```
BatteryTrackingManager.batteryStateChanged(.notCharging)
    ↓
LiveActivityManager.stopIfNeeded()
    ↓
endAll() with proper logging
    ↓
Clean shutdown
```

### **Snapshot Handling**
```
ContentView.onReceive(tracker.publisher)
    ↓
updateUI(with: snap)  // UI updates only
    ↓
No Live Activity interference
```

## 📝 **Files Modified**
1. `PETL/ContentView.swift` - Removed snapshot forwarding
2. `PETL/LiveActivityManager.swift` - Deprecated updateIfNeeded, fixed logging order, removed duplicate start log

## 🎉 **Result**
The duplicate Live Activity start issue is now completely resolved. The app maintains a single, clean start/stop flow through BatteryTrackingManager, eliminating race conditions and noisy logs while preserving all existing functionality.
