# Live Activity Presentation Fix - "250 min" Dynamic Island Issue Resolution

## 🎯 **Problem Identified**

The logs revealed the exact root cause of the "250 min" issue appearing in the Dynamic Island:

- **Single real tick** at 18:15:22.800, then next at 18:15:53.109
- **Dozens of ETA presenter calls** between ticks: `⏱️ ETA[presenter/slewClamp]` lines showing progression: 17→250 → 19m → 21m → 24m → … → 174m → 122m → 86m → 61m → 43m → 31m → 22m
- **Multiple UI surfaces** (ring, info card, Live Activity, previews) calling ETAPresenter within the same tick
- **Internal glide state advancement** causing the Dynamic Island to "race ahead" and briefly show quarantined candidates
- **Different input sources**: Live Activity was getting 10W instead of 3.5W smoothed watts, weakening quarantine logic

This was a **presentation idempotency problem**, not an analytics issue.

## 🔧 **Surgical Fix Implemented**

### **1. Presentation Idempotency (Previous Fix)**
- ✅ **BatteryTrackingManager**: Added tick sequence token with monotonically increasing sequence
- ✅ **ETAPresenter**: Made idempotent per token with caching mechanism
- ✅ **ContentView**: Updated both ETAPresenter calls to use tick token
- ✅ **LiveActivityManager**: Updated ETAPresenter call to use tick token

### **2. Live Activity Input Source Fix (New Fix)**

#### **Problem**: Live Activity was using wrong input sources
- **App UI**: Used `BatteryTrackingManager.shared.currentWatts` (smoothed 3.5W)
- **Live Activity**: Used `ChargeEstimator.shared.current?.watts` (10W during warmup)

#### **Solution**: Force Live Activity to use the same input sources as app UI

**A. Updated `publishLiveActivityAnalytics` function:**
```swift
// 1) Get raw inputs from the same place as the app (NO 10W after warmup)
let rawETA = analytics.timeToFullMinutes
let rawW = BatteryTrackingManager.shared.currentWatts  // <- must be the SMOOTHED watts from estimator

// 2) Present once, same quarantine/slew logic as UI
let token = BatteryTrackingManager.shared.tickToken
let displayedETA = FeatureFlags.useETAPresenter
    ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isChg, isWarmup: isWarm, tickToken: token).minutes
    : rawETA

// 3) Use displayedETA for DI/Live Activity payloads
var etaForDI = displayedETA

// 4) Add a cheap guardrail in LA (just in case)
if let e = etaForDI, e >= 180, rawW <= 5.0 {
    // quarantine at DI edge as a second safety net
    etaForDI = ETAPresenter.shared.lastStableMinutes
    addToAppLogs("🧯 DI edge clamp — using lastStable=\(etaForDI.map{"\($0)m"} ?? "—")")
}
```

**B. Updated `firstContent` function (initial Live Activity payload):**
```swift
// Initialize DI with presented values (not raw)
let rawETA = ChargeEstimator.shared.current?.minutesToFull
let rawW = BatteryTrackingManager.shared.currentWatts
let sysPct = Int(BatteryTrackingManager.shared.level * 100)
let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false

let token = BatteryTrackingManager.shared.tickToken
let initialEta = FeatureFlags.useETAPresenter
    ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarm, tickToken: token).minutes
    : rawETA
```

**C. Updated `updateWithCurrentBatteryData` function:**
```swift
// Use presented values (not raw)
let rawETA = ChargeEstimator.shared.current?.minutesToFull
let rawW = BatteryTrackingManager.shared.currentWatts
let sysPct = Int(BatteryTrackingManager.shared.level * 100)
let isWarm = ChargeEstimator.shared.current?.isInWarmup ?? false

let token = BatteryTrackingManager.shared.tickToken
let displayedETA = FeatureFlags.useETAPresenter
    ? ETAPresenter.shared.presented(rawETA: rawETA, watts: rawW, sysPct: sysPct, isCharging: isCharging, isWarmup: isWarm, tickToken: token).minutes
    : rawETA
```

### **3. Added Public Accessors**

**A. BatteryTrackingManager:**
```swift
// Public accessor for current smoothed watts (for Live Activity)
var currentWatts: Double { lastDisplayed.watts }
```

**B. ETAPresenter:**
```swift
// Public accessor for last stable minutes (for DI edge clamp)
var lastStableMinutes: Int? { lastStableETA }
```

### **4. Enhanced Logging**

**A. DI payload logging:**
```swift
// 4) Log DI payload for parity check
addToAppLogs("📤 DI payload — eta=\(etaForDI.map{"\($0)m"} ?? "—") W=\(String(format:"%.1f", rawW))")
```

**B. DI edge clamp logging:**
```swift
if let e = etaForDI, e >= 180, rawW <= 5.0 {
    // quarantine at DI edge as a second safety net
    etaForDI = ETAPresenter.shared.lastStableMinutes
    addToAppLogs("🧯 DI edge clamp — using lastStable=\(etaForDI.map{"\($0)m"} ?? "—")")
}
```

## ✅ **Expected Results**

### **Before Fix:**
- App UI: `⏱️ ETA[presenter/slewClamp] = 40m W=3.5`
- Live Activity: `📤 LiveActivity render ETA=250m · W=10.0` (different!)

### **After Fix:**
- App UI: `⏱️ ETA[presenter/slewClamp] = 40m W=3.5`
- Live Activity: `📤 DI payload — eta=40m W=3.5` (same!)

### **Edge Case Protection:**
- If Live Activity would have spiked: `🧯 DI edge clamp — using lastStable=40m`

## 🔍 **Why This Fix Works**

1. **Single Source of Truth**: Live Activity now uses exactly the same input sources as the app UI
2. **Same Presenter Logic**: Both app and Live Activity go through the same ETAPresenter with identical quarantine/slew logic
3. **Idempotent Per Tick**: Multiple UI surfaces calling the presenter within the same tick now return cached results
4. **Edge Case Protection**: Additional guardrail at the Live Activity edge for extra safety
5. **Consistent Logging**: New log format makes it easy to verify parity between app and Live Activity

## 📋 **Files Modified**

1. **BatteryTrackingManager.swift**
   - Added `currentWatts` public accessor
   - Added tick sequence token system

2. **ETAPresenter.swift**
   - Added `lastStableMinutes` public accessor
   - Implemented idempotency per tick token

3. **LiveActivityManager.swift**
   - Updated `publishLiveActivityAnalytics` to use correct input sources
   - Updated `firstContent` to use presenter for initial payload
   - Updated `updateWithCurrentBatteryData` to use presenter
   - Added DI edge clamp protection
   - Enhanced logging for parity verification

4. **ContentView.swift**
   - Updated ETAPresenter calls to use tick token

## 🎯 **Verification**

To verify the fix is working, look for these log patterns:

1. **Matching ETA values**: App and Live Activity should show the same ETA
2. **Matching watts**: Both should show the same smoothed watts (e.g., 3.5W, not 10W)
3. **No more "250 min"**: Live Activity should never show quarantined candidates
4. **Edge clamp logs**: If protection triggers, you'll see `🧯 DI edge clamp` logs

## 🚀 **Build Status**

✅ **Build succeeds** with exit code 0  
✅ **All compilation errors resolved**  
✅ **Ready for testing**  

This surgical fix maintains all existing analytics, quarantine, and warm-up logic while ensuring presentation consistency across all UI surfaces.
