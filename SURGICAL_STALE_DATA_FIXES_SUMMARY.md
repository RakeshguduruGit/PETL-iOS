# Surgical Stale Data Fixes Implementation Summary

## ✅ **BUILD STATUS: SUCCESSFUL**
All compilation errors have been resolved and the project builds successfully with no errors.

## 🎯 **Overview**
Successfully implemented surgical fixes to eliminate the two major issues identified in the logs:
1. **Duplicate warmup inserts at session start** - causing both generic and warmup-once paths to insert 10W
2. **Reload storm (tons of Power query 12h lines)** - causing UI jank/freezes

## 🔧 **Key Fixes Implemented**

### 1. **Warmup Persistence - Truly "Once"**
- **Problem**: Both generic path and warmup-once path were inserting 10W
- **Solution**: Added early return after warmup persistence to prevent generic path execution
- **Implementation**:
  ```swift
  if isWarmup {
      // PERSIST WARMUP ONLY ONCE, THEN RETURN
      if wroteWarmupThisSession == false {
          _ = ChargeDB.shared.insertPower(ts: now, session: currentSessionId, soc: soc, isCharging: true, watts: w)
          wroteWarmupThisSession = true
          addToAppLogs("💾 DB.power insert (warmup-once) — \(String(format:"%.1fW", w))")
      }
      return   // <<< IMPORTANT: prevents generic path from also inserting 10W
  }
  ```

### 2. **Throttled Power Persistence**
- **Problem**: Excessive power writes causing database spam
- **Solution**: Added 5-second minimum gap between power writes for measured/smoothed values
- **Implementation**:
  ```swift
  // Not warmup → measured/smoothed
  // Throttle writes to avoid spam (e.g., min 5s between rows)
  if shouldPersist(now: now, lastTs: lastPersistedPowerTs, minGapSec: 5) {
      _ = ChargeDB.shared.insertPower(ts: now, session: currentSessionId, soc: soc, isCharging: true, watts: w)
      lastPersistedPowerTs = now
      wroteWarmupThisSession = false
      addToAppLogs("💾 DB.power insert — \(String(format:"%.1fW", w))")
  }
  ```

### 3. **Session Lifecycle Guards**
- **Problem**: Multiple charge begin/end calls causing duplicate session management
- **Solution**: Added guards to prevent double-begin and double-end scenarios
- **Implementation**:
  ```swift
  private func handleChargeBegan() {
      guard currentSessionId == nil else { return }    // <-- guard double-begin
      currentSessionId = UUID()
      resetPowerSmoothing("charge-begin")
      NotificationCenter.default.post(name: .powerDBDidChange, object: nil)
  }

  private func handleChargeEnded() {
      guard let sid = currentSessionId else { return } // <-- guard double-end
      resetPowerSmoothing("charge-end")
      // write a single 0W marker to close the session cleanly
      _ = ChargeDB.shared.insertPower(
          ts: Date(), session: sid, soc: Int((UIDevice.current.batteryLevel * 100).rounded()), isCharging: false, watts: 0.0
      )
      NotificationCenter.default.post(name: .powerDBDidChange, object: nil)
      currentSessionId = nil
  }
  ```

### 4. **Database Duplicate Prevention**
- **Problem**: Potential duplicate rows from multiple insert attempts
- **Solution**: Added unique index and INSERT OR IGNORE
- **Implementation**:
  ```sql
  CREATE UNIQUE INDEX IF NOT EXISTS idx_charge_log_session_ts
  ON charge_log(session_id, ts);
  ```
  ```swift
  // INSERT OR IGNORE prevents duplicates if two paths accidentally try identical rows
  sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO charge_log(ts,session_id,is_charging,soc,watts,eta_minutes,event,src) VALUES (?,?,?,?,?,?,?,?)", -1, &st, nil)
  ```

### 5. **UI Reload Storm Prevention**
- **Problem**: Multiple subscribers causing reload storms
- **Solution**: Single subscriber with nil checks to prevent duplicate subscriptions
- **Implementation**:
  ```swift
  .onAppear {
      if powerDBCancellable == nil {
          powerDBCancellable = NotificationCenter.default
              .publisher(for: .powerDBDidChange)
              .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
              .sink { _ in reloadPowerSamplesAsync() }
      }
      if chargingCancellable == nil {
          chargingCancellable = trackingManager.$isCharging
              .removeDuplicates()
              .sink { _ in reloadPowerSamplesAsync() }
      }
      reloadPowerSamplesAsync()
  }
  .onDisappear {
      powerDBCancellable?.cancel(); powerDBCancellable = nil
      chargingCancellable?.cancel(); chargingCancellable = nil
  }
  ```

### 6. **Log Spam Reduction**
- **Problem**: Excessive "Power query 12h" logs choking Xcode
- **Solution**: Only log when count or last timestamp changes
- **Implementation**:
  ```swift
  // Only log when either count or last timestamp changes
  if samples.count != lastPowerQueryCount || samples.last?.time != lastPowerQueryTime {
      if let last = samples.last {
          addToAppLogs("📈 Power query \(hours)h — \(samples.count) rows · last=\(String(format:"%.1fW", last.watts)) @\(last.time)")
      } else {
          addToAppLogs("📈 Power query \(hours)h — 0 rows")
      }
      lastPowerQueryCount = samples.count
      lastPowerQueryTime = samples.last?.time
  }
  ```

## 🎯 **Expected Results After These Fixes**

### **At Charge Begin:**
- ✅ One `💾 DB.power insert (warmup-once)` at 10W, then measured values
- ✅ No second 10W insert from generic path
- ✅ Clean session start with fresh UUID

### **At Charge End:**
- ✅ One 0W marker to clearly close the session
- ✅ Session resets completely
- ✅ Next begin starts a fresh session

### **Live Activity:**
- ✅ Exactly one start per session
- ✅ Exactly one end per unplug
- ✅ No duplicate management calls

### **Power Queries:**
- ✅ Single burst on begin/end, not a machine-gun stream
- ✅ Reduced log spam for better Xcode performance
- ✅ UI no longer freezes from excessive reloads

### **Database:**
- ✅ No duplicate rows from multiple insert attempts
- ✅ Clean session boundaries with 0W markers
- ✅ Efficient throttling prevents spam

## 🔍 **Technical Details**

### **Session Management Variables Added:**
```swift
private var currentSessionId: UUID?
private var wroteWarmupThisSession = false
private var lastPersistedPowerTs: Date?
private var lastPowerQueryCount = 0
private var lastPowerQueryTime: Date?
```

### **Helper Methods Added:**
```swift
private func shouldPersist(now: Date, lastTs: Date?, minGapSec: TimeInterval) -> Bool {
    guard let lastTs else { return true }
    return now.timeIntervalSince(lastTs) >= minGapSec
}
```

### **Database Schema Updates:**
- Removed PRIMARY KEY constraint from `ts` column
- Added unique index on `(session_id, ts)` combination
- Changed to `INSERT OR IGNORE` for duplicate prevention

## 🚀 **Performance Improvements**

1. **Reduced Database Writes**: 5-second throttling prevents excessive inserts
2. **Eliminated Reload Storms**: Single subscriber pattern prevents UI freezes
3. **Cleaner Logs**: Reduced spam for better debugging experience
4. **Session Isolation**: Clear boundaries prevent state carryover
5. **Duplicate Prevention**: Database-level protection against race conditions

## ✅ **Verification Steps**

To verify the fixes are working:

1. **Launch app** and check logs for clean startup
2. **Plug in charger** - should see one warmup insert, then measured values
3. **Unplug charger** - should see one 0W marker and session reset
4. **Replug charger** - should start fresh session with new UUID
5. **Check UI responsiveness** - no more freezes during state changes
6. **Monitor logs** - reduced spam, cleaner output

The implementation addresses all the root causes identified in the logs while maintaining the existing functionality and visual design.
