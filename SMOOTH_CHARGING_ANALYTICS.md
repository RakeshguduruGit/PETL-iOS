# Smooth Charging Analytics Implementation

## 🎯 **Overview**

This document describes the implementation of smooth charging analytics that addresses iOS's limitation of reporting battery level only in 5% increments. The solution provides continuous, smooth progress estimation while preserving the 10W warm-up fallback, with advanced data gap detection and confidence gating.

## 🔍 **Problem Statement**

### **iOS Battery Reporting Limitations**
- iOS only reports battery level changes in 5% increments (e.g., 20% → 25% → 30%)
- This causes jumpy analytics: flat (0%/min) → spike (high %/min) → flat (0%/min)
- Power estimates and "minutes to full" become inconsistent and unreliable
- Historical charts show stair-step patterns instead of smooth progress

### **Warm-up Period Requirements**
- During initial charging (first 90s), no device data is available
- Must maintain consistent 10W fallback across all outputs
- Cannot use device-derived rates until first real +5% step occurs

### **Charging Stall Detection**
- iPhone thermal throttling causes charging to pause
- Optimized Charging in 75-85% band can stall charging
- ETA spikes (>300 min) or jumps (>3x) indicate charging issues
- Need to freeze ETA/power values during stalls to prevent user confusion

### **Data Gap & Confidence Issues (Phase 2.5+)**
- Stale data can cause "200 min" ETA spikes from old rate estimates
- iOS optimization can cause gaps in sampling (dt > 75s)
- Low trickle power (<6W) with stale steps (>10min) indicates stalled charging
- Need confidence-based gating to prevent unreliable estimates

## 🛠️ **Solution Architecture**

### **1. ChargingRateEstimator**

**Purpose**: Smooths charging analytics between iOS's 5% SOC steps while preserving warm-up fallback.

**Key Components**:
```swift
final class ChargingRateEstimator {
    struct Output {
        let estPercent: Double          // continuous SOC (for charts, time remaining)
        let pctPerMin: Double           // smoothed %/min (for UI + watts)
        let watts: Double               // derived power
        let minutesToFull: Int?         // nil if not charging or invalid
        let source: Source
        let backfill: Backfill?         // non-nil only at the instant of a real +5% step
    }

    enum Source { case warmupFallback, interpolated, actualStep }
    struct Backfill { let fromDate: Date; let toDate: Date; let fromPercent: Double; let toPercent: Double }
}
```

**Tunable Parameters**:
- `alphaEMA: Double = 0.25` - Smoothing factor for %/min (smooth but responsive)
- `warmupMaxSeconds: Int = 90` - Cap warm-up window
- `nominalVoltage: Double = 3.85` - Typical phone pack voltage
- `tickSeconds: Double = 30.0` - Expected tick cadence

### **2. SafeChargingSmoother (Phase 2.5+)**

**Purpose**: Enhanced smoother with data gap detection and confidence gating.

**Key Components**:
```swift
final class SafeChargingSmoother {
    struct Output {
        let estPercent: Double
        let pctPerMin: Double
        let watts: Double
        let minutesToFull: Int?
        let source: Source
        let firstStepThisSession: Bool
        // NEW: Phase 2.5
        let dt: TimeInterval
        let dataGap: Bool
        let lastRealStepAgeSec: Int
        let confidence: Confidence
    }
    
    enum Source { case warmup, interpolated, actualStep }
    enum Confidence { case warmup, seeded, good, staleStep, dataGap }
}
```

**Tunable Parameters (Phase 2.5)**:
- `expectedTick: TimeInterval = 30.0` - Keep in sync with sampler
- `staleStepSec: Int = 600` - If no +5% step for 10m → stale
- `gapFactor: Double = 2.5` - dt > 2.5x expected → data gap

**Confidence Rules**:
- `warmup`: During warm-up period
- `seeded`: No real +5% step yet
- `dataGap`: dt > 2.5x expected (75s)
- `staleStep`: No +5% step for 10+ minutes
- `good`: Fresh data, reliable estimates

### **3. ChargingHistoryStore**

**Purpose**: Manages charging history with backfill capabilities for smooth chart rendering.

**Key Features**:
```swift
struct ChargeSample: Codable {
    let ts: Date
    let systemPercent: Int
    let estPercent: Double
    let watts: Double
    let pctPerMin: Double
    let source: String   // "warmupFallback" | "interpolated" | "actualStep"
}

final class ChargingHistoryStore {
    /// Rewrite samples in [from, to] to a simple linear ramp from "fromPercent" to "toPercent".
    func backfillLinear(from: Date, to: Date, fromPercent: Double, toPercent: Double)
}
```

### **4. ChargePauseController (Enhanced Phase 2.6)**

**Purpose**: Detects charging stalls and freezes ETA/power values to prevent user confusion.

**Key Features**:
```swift
final class ChargePauseController {
    enum Reason: String { case thermal, optimized, spike, unknown }
    struct Status {
        let isPaused: Bool
        let reason: Reason?
        let since: Date?
        let elapsedSec: Int
        let label: String
    }
}
```

**Detection Heuristics**:
- **Thermal**: `ProcessInfo.processInfo.thermalState` (serious/critical)
- **Optimized**: ETA spike + battery level in 75-85% band
- **Spike**: ETA > 300 min or >3x jump from previous value
- **Hysteresis**: 4 ticks to pause, 3 ticks to resume (prevents flapping)

**Enhanced Detection (Phase 2.6)**:
- **Early Optimized**: `75-88%` + `sysUnchanged ≥ 60s` + `watts ≤ 4.5W`
- **Faster Latching**: `pauseTicksToEnter = 2`, `pauseTicksToExit = 2`
- **System Tracking**: `lastSystemPercent`, `lastSystemChangeDate`

**Safety Features**:
- Never marks paused during warm-up (preserves 10W fallback)
- Freezes ETA/power to last stable values during pause
- Automatic resume when conditions improve

## 🔄 **Workflow**

### **1. Charging Start**
```swift
// Initialize estimator with device capacity
let mAh = getDeviceBatteryCapacity()
rateEstimator = ChargingRateEstimator(capacitymAh: mAh)
rateEstimator?.begin(systemPercent: Int(UIDevice.current.batteryLevel * 100), now: Date())

// Log: 🔌 Charge begin — warmup (10W) started
```

### **2. During Warm-up Period (≤90s)**
- All outputs use 10W fallback
- No device-derived rates
- Continuous interpolation toward next 5% boundary
- Source: `warmupFallback`

### **3. First Real +5% Step**
```swift
// Compute observed %/min for the last segment
let observedPctPerMin = Double(systemPercent - lastPercent) / mins
// EMA update
emaPctPerMin = (1.0 - alphaEMA) * emaPctPerMin + alphaEMA * observedPctPerMin

// Exit warm-up, snap to real boundary
inWarmup = false
estSOC = Double(systemPercent)
nextBoundary = min(((systemPercent / 5) * 5) + 5, 100)

// Log: 📈 First step seen — warmup ended, seeding EMA
```

### **4. Continuous Interpolation**
```swift
// Live interpolation toward next boundary (no overshoot)
if !justStepped {
    let deltaPct = pctPerMin * (dt/60.0)
    estSOC = min(Double(nextBoundary), max(Double(lastPercent), estSOC + deltaPct))
}
```

### **5. Data Gap & Confidence Detection (Phase 2.5)**
```swift
// Flag last real +5% step
if source == .actualStep { lastRealStep = now }

let sinceStep = Int(now.timeIntervalSince(lastRealStep ?? warmupStart ?? now))
let gap = dt > expectedTick * gapFactor

// Confidence rules
let confidence: Confidence = {
    if source == .warmup { return .warmup }
    if lastRealStep == nil { return .seeded }
    if gap { return .dataGap }
    if sinceStep > staleStepSec { return .staleStep }
    return .good
}()
```

### **6. ETA/Power Gating (Phase 2.5)**
```swift
// Hard freeze cases (no new ETA math)
let mustFreeze = (o.confidence == .dataGap) ||
                 (o.confidence == .staleStep && o.watts < 6.0) || // stale + trickle
                 (pauseCtlCurrentStatus?.isPaused == true)

let etaRaw = o.minutesToFull
let wRaw   = o.watts

// Update lastStable only when not frozen and not warmup
if !mustFreeze && o.source != .warmup {
    lastStableETA = etaRaw ?? lastStableETA
    lastStableW   = wRaw
}

// Choose what we'd display
let displayETA = mustFreeze ? lastStableETA : etaRaw
let displayW   = mustFreeze ? (lastStableW ?? wRaw) : wRaw
```

### **7. Enhanced Pause Detection (Phase 2.6)**
```swift
// Track system percent changes
let sysChanged = systemPercent != lastSystemPercent
if sysChanged {
    lastSystemChangeDate = now
    lastSystemPercent = systemPercent
}
let sinceLastSysChangeSec = Int(now.timeIntervalSince(lastSystemChangeDate ?? now))
let sysUnchanged = !sysChanged && (sinceLastSysChangeSec >= minNoChangeSec)

// Early optimized detection
let earlyOptimized = !inWarmup &&
                     earlyOptimizedBand.contains(systemPercent) &&
                     sysUnchanged && (smoothedWatts <= trickleWattMax)

if earlyOptimized { reason = .optimized }
```

### **8. Pause Detection & Recovery**
```swift
// Evaluate pause conditions
let (status, frozenEta) = pauseCtl.evaluate(
    isCharging: isChargingNow,
    systemPercent: systemPct,
    inWarmup: (out.source == .warmup),
    smoothedEta: out.minutesToFull,
    smoothedWatts: out.watts,
    now: Date()
)

// Log pause events
if status.isPaused && status.elapsedSec == 0 {
    addToAppLogs("⏸ Charging paused — reason=\(status.reason?.rawValue ?? "unknown"); freezing ETA/power")
} else if !status.isPaused && status.elapsedSec > 0 {
    let mins = Int(ceil(Double(status.elapsedSec)/60.0))
    addToAppLogs("▶️ Charging resumed — paused ~\(mins)m; resuming live ETA/power")
}
```

### **9. Historical Backfill**
```swift
// If we just hit a real step, propose a backfill for history smoothing
let backfill: Backfill? = justStepped
? Backfill(
    fromDate: lastChangeDate?.addingTimeInterval(-dt) ?? now,
    toDate: now,
    fromPercent: Double(lastPercent),
    toPercent: Double(systemPercent)
  )
: nil

// Apply backfill to create smooth linear ramps
if let b = out.backfill {
    historyStore.backfillLinear(from: b.fromDate, to: b.toDate, fromPercent: b.fromPercent, toPercent: b.toPercent)
    // Log: 🧵 Backfill X%→Y% from→to
}
```

### **10. Charging End**
```swift
// Snap to system % to avoid drift post-charge
estSOC = Double(lastPercent)
inWarmup = false
rateEstimator = nil

// Log: 🛑 Charge end — estimator cleared
```

## 📊 **Logging Specification**

### **Canonical Log Lines**
```swift
// On plug-in
addToAppLogs("🔌 Charge begin — warmup (10W) started")

// First +5% step
addToAppLogs("📈 First step seen — warmup ended, seeding EMA")

// Every real step
addToAppLogs("📊 Step +5% in X min — EMA now Y %/min")

// On each tick (DEBUG)
addToAppLogs("⚙️ RateEstimator source=\(out.source) est=\(estPercent.rounded())% rate=\(pctPerMin.rounded())%/min power=\(watts.rounded())W m2f=\(minutesToFull ?? -1)")

// On backfill
addToAppLogs("🧵 Backfill \(Int(b.fromPercent))%→\(Int(b.toPercent))% \(b.fromDate)→\(b.toDate)")

// On pause detection
addToAppLogs("⏸ Charging paused — reason=\(status.reason?.rawValue ?? "unknown"); freezing ETA/power")

// On pause recovery
addToAppLogs("▶️ Charging resumed — paused ~\(mins)m; resuming live ETA/power")

// On unplug
addToAppLogs("🛑 Charge end — estimator cleared")
```

### **Enhanced Logging (Phase 2.5+)**
```swift
// High-fidelity tick logs with seconds
logSec("🕒", String(format: "Tick %@ — sys=%d%% est=%.1f%% src=%@ rate=%.2f%%/min watts=%.1fW eta=%@ dt=%.1fs conf=%@ gap=%@",
                   Self.tsFmt.string(from: now),
                   systemPct, o.estPercent,
                   String(describing: o.source),
                   o.pctPerMin, o.watts,
                   displayETA.map { "\($0)m" } ?? "-",
                   o.dt,
                   String(describing: o.confidence),
                   o.dataGap ? "true" : "false"))

// ETA source + timestamp logs (Phase 2.7)
if let eta = displayETA {
    if mustFreeze {
        logSec("🧊", String(format:"ETA frozen — %dm (reason=%@)", eta, freezeReasonText(o)))
    } else {
        logSec("⚙️", String(format:"ETA live — %dm (src=%@, conf=%@, dt=%.1fs)", eta, String(describing: o.source), String(describing: o.confidence), o.dt))
    }
}

// Freeze reason helper
private func freezeReasonText(_ o: SafeChargingSmoother.Output) -> String {
    if o.confidence == .dataGap { return "data_gap(dt=\(Int(o.dt))s)" }
    if o.confidence == .staleStep && o.watts < 6.0 { return "stale_step+\(Int(o.lastRealStepAgeSec))s_lowW" }
    return "paused_or_unknown"
}
```

## ⚙️ **Configuration**

### **Tunable Parameters**
```swift
// Default values (safe for production)
warmupMaxSeconds = 90      // Keep 10W up to 90s if no step yet
alphaEMA = 0.25            // Smooth but responsive
tickSeconds = 30           // Matches your sampling cadence
nominalVoltage = 3.85      // Fine to leave fixed

// Safety rails
pctPerMin ∈ [0.05, 3.0]   // Prevent unrealistic rates

// Phase 2.5: Data gap detection
expectedTick = 30.0        // Keep in sync with sampler
staleStepSec = 600         // If no +5% step for 10m → stale
gapFactor = 2.5           // dt > 2.5x expected → data gap

// Phase 2.6: Enhanced pause detection
earlyOptimizedBand = 75...88  // % band to suspect Optimized Charging
minNoChangeSec = 60           // sys% unchanged ≥ 60s
trickleWattMax = 4.5         // <= 4.5W counts as trickle
pauseTicksToEnter = 2        // faster latching
pauseTicksToExit = 2
```

### **Device Capacity Lookup**
```swift
private func getDeviceBatteryCapacity() -> Int {
    let deviceModel = UIDevice.current.model
    if deviceModel.contains("iPhone") {
        return 3000 // Typical iPhone capacity
    } else if deviceModel.contains("iPad") {
        return 8000 // Typical iPad capacity
    } else {
        return 3000 // Default fallback
    }
}
```

## 🔧 **Integration Points**

### **BatteryTrackingManager Integration**
```swift
// MARK: - Charging Rate Estimator
private var rateEstimator: ChargingRateEstimator?
private var historyStore = ChargingHistoryStore()

// Phase 2.5: Stable values for freezing
private var lastStableETA: Int?
private var lastStableW: Double?

// On battery state change (plug-in)
rateEstimator = ChargingRateEstimator(capacitymAh: mAh)
rateEstimator?.begin(systemPercent: Int(UIDevice.current.batteryLevel * 100), now: Date())

// On power sample recording
let out = estimator.tick(systemPercent: Int(UIDevice.current.batteryLevel * 100),
                        isCharging: isCharging,
                        now: Date())

// Use outputs for UI + Live Activity + logs
let estPercent = out.estPercent
let pctPerMin = out.pctPerMin
let watts = out.watts
let minutesToFull = out.minutesToFull
```

### **Chart Integration**
```swift
// Replace systemPercent with estPercent for smooth charts
// old: let y = sample.systemPercent
// new: let y = sample.estPercent

// Power chart already uses watts from estimator
// During warm-up: 10W
// After warm-up: smoothed watts from EMA
```

## 🎯 **Benefits Achieved**

### **1. Smooth Live UI**
- No more zero → spike → zero patterns
- Continuous progress indication
- Stable "time to full" estimates

### **2. Preserved Warm-up**
- 10W fallback exactly as requested
- No device data used during warm-up
- Consistent behavior across all outputs

### **3. Clean Historical Charts**
- Backfilled segments show smooth linear ramps
- No more stair-step patterns
- Accurate historical representation

### **4. Edge Case Handling**
- **Optimized Charging**: EMA naturally decays when no steps occur
- **Thermal Throttling**: Longer step times reduce EMA automatically
- **Unplug During Warm-up**: Estimator cleared, no drift

### **5. Data Gap & Confidence Protection (Phase 2.5+)**
- **"200 min" ETA Prevention**: Data gap detection stops updating ETA when sampler is late
- **Stale Data Protection**: 10-minute stale step detection prevents using old rate estimates
- **Trickle Detection**: Low power (<6W) with stale steps triggers freezing
- **Earlier Pause Latch**: 2-tick hysteresis at 75-88% with ≤4.5W triggers faster freezing

## 🧪 **Testing Considerations**

### **QA Testing Mode**
- All existing QA testing infrastructure preserved
- New analytics don't interfere with Live Activity testing
- Comprehensive logging for debugging

### **Edge Cases to Test**
1. **Plug in at 95%** - Should handle near-full charging
2. **Unplug during warm-up** - Should clear estimator cleanly
3. **Long charging sessions** - Should maintain smooth progress
4. **Thermal throttling** - Should adapt to slower charging
5. **Optimized charging** - Should handle 80% pauses gracefully
6. **Data gaps** - Should freeze ETA when dt > 75s
7. **Stale steps** - Should freeze when no +5% step for 10+ minutes
8. **Trickle charging** - Should detect low power + stale data

## 📈 **Performance Impact**

### **Memory Usage**
- Minimal: Only stores current estimator state
- Historical samples managed by existing infrastructure

### **CPU Usage**
- Lightweight: Simple EMA calculations
- No complex algorithms or heavy processing

### **Battery Impact**
- Negligible: Uses existing 30-second sampling cadence
- No additional background processing

## 🔮 **Future Enhancements**

### **Potential Improvements**
1. **Device-specific tuning**: Different parameters per device model
2. **Adaptive EMA**: Adjust smoothing based on charging characteristics
3. **Machine learning**: Predict charging patterns for better estimates
4. **User preferences**: Allow users to adjust sensitivity

### **Monitoring & Analytics**
1. **Estimator accuracy**: Track predicted vs actual step times
2. **Warm-up effectiveness**: Measure warm-up period duration
3. **User satisfaction**: Monitor UI smoothness metrics
4. **Data gap frequency**: Track how often gaps occur
5. **Freeze effectiveness**: Measure how often ETA freezing prevents confusion

---

**Smooth Charging Analytics** - Making battery charging analytics fluid and reliable with advanced data gap detection and confidence gating. 🔋⚡
