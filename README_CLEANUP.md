# PETL SSOT Architecture Cleanup

## 🎯 Overview

This cleanup transforms PETL from a dual-engine architecture to a **single source of truth (SSOT)** with `ChargeEstimator` as the only computation engine. This eliminates duplicate logic, ensures consistent values across all UI surfaces, and simplifies the codebase.

## 🏗️ Architecture Transformation

### Before (Dual-Engine)
```
iOS Events → BatteryTrackingManager → ChargingRateEstimator + ETAPresenter → Multiple Snapshots → UI + Live Activity
```

### After (SSOT)
```
iOS Events → BatteryTrackingManager → ChargeEstimator (SSOT) → ChargingSnapshot → ChargeStateStore → UI + Live Activity + DB
```

## 📋 Quick Start

### 1. Run the Cleanup Script
```bash
./cleanup_execution_script.sh
```

### 2. Apply Code Updates
Follow these files in order:
- `ChargeEstimator_SSOT_Updates.md` - Make ChargeEstimator the SSOT
- `BatteryTrackingManager_Updates.md` - Update BatteryTrackingManager
- `LiveActivity_Cleanup.md` - Clean up Live Activity extension

### 3. Run QA Checklist
Use `QA_Checklist.md` for comprehensive testing.

## 📁 Files Created

| File | Purpose |
|------|---------|
| `CLEANUP_IMPLEMENTATION_PLAN.md` | Complete implementation plan with phases |
| `cleanup_execution_script.sh` | Automated script to remove duplicate files |
| `ChargeEstimator_SSOT_Updates.md` | Specific updates for ChargeEstimator |
| `BatteryTrackingManager_Updates.md` | Specific updates for BatteryTrackingManager |
| `LiveActivity_Cleanup.md` | Live Activity extension cleanup |
| `QA_Checklist.md` | Comprehensive testing checklist |

## 🗑️ Files Removed

### Core Duplicates
- `PETL/Shared/Analytics/ChargingRateEstimator.swift` - Merged into ChargeEstimator
- `PETL/Shared/Analytics/ChargingHistoryStore.swift` - Replaced by ChargeDB
- `PETL/ETAPresenter.swift` - Logic moved to ChargeEstimator

### Optional Live Activity Files
- `PETLLiveActivityExtension/PETLLiveActivityExtension.swift`
- `PETLLiveActivityExtension/PETLLiveActivityExtensionControl.swift`
- `PETLLiveActivityExtension/AppIntent.swift`

## 🔧 Key Changes

### 1. ChargeEstimator Becomes SSOT
- **Unified Output**: Single `Output` struct with all computed values
- **Single Computation Path**: `update(with:)` method handles all logic
- **No External Dependencies**: Self-contained computation engine
- **Pause Integration**: Uses ChargePauseController for thermal/optimized charging

### 2. BatteryTrackingManager Simplified
- **Single Update Method**: `processBatteryUpdate()` handles all events
- **No Duplicate Logic**: All computation delegated to ChargeEstimator
- **Unified Publishing**: Single snapshot published to all consumers
- **Clean Session Management**: Simple start/end logging

### 3. Live Activity Cleanup
- **Shared Attributes**: Uses shared `PETLLiveActivityAttributes`
- **No Duplicates**: Removed duplicate attributes definition
- **Consistent Values**: Same data source as main UI

## 📊 Benefits

### Correctness
- ✅ **Same numbers everywhere**: Ring, Live Activity, Lock Screen all show identical values
- ✅ **No mixed sources**: UI and Live Activity never mix values from different modules
- ✅ **Consistent behavior**: All surfaces behave identically

### Maintainability
- ✅ **Single computation path**: One place to fix bugs or add features
- ✅ **Reduced complexity**: Eliminated duplicate logic and coordination
- ✅ **Clear data flow**: Linear flow from input to output

### Performance
- ✅ **Reduced CPU**: Single computation instead of multiple engines
- ✅ **Consistent updates**: All consumers get updates simultaneously
- ✅ **Better caching**: Single source enables better optimization

## 🧪 Testing Strategy

### Automated Testing
```bash
# Run cleanup script
./cleanup_execution_script.sh

# Build and test
xcodebuild -project PETL.xcodeproj -scheme PETL build
xcodebuild -project PETL.xcodeproj -scheme PETL test
```

### Manual Testing
1. **Charging Session**: 10-15 minute charging session
2. **Unplug/Replug**: Test lifecycle scenarios
3. **Background/Foreground**: Test app transitions
4. **Thermal Scenarios**: Test thermal throttling (if possible)

### QA Checklist
Use `QA_Checklist.md` for comprehensive testing covering:
- **Correctness**: Snapshot invariants, phase transitions, same numbers everywhere
- **Live Activity**: Lifecycle, updates, rendering, assets
- **Performance**: CPU usage, update frequency, memory management
- **Stability**: App lifecycle, error handling, foreground gate

## 🚨 Critical Invariants

### Snapshot Invariants
- `isCharging = false` ⇒ `minutesToFull = nil`, `watts = 0`, `phase = "idle"`
- `minutesToFull` decreases monotonically while charging (allow ±1 jitter)
- Phase transitions: `warmup` → `active` → `trickle` (no backward jumps)

### Same Numbers Everywhere
- ContentView ring minutes == Live Activity minutes
- ContentView watts == Live Activity watts
- All Dynamic Island states show same key values

### Performance Limits
- CPU avg < 3% while charging in foreground
- Live Activity updates ≤ 6/min
- Database writes ≤ 6/min

## 🔍 Troubleshooting

### Common Issues

**Build Errors After Cleanup**
```bash
# Check for dead imports
grep -r "ChargingRateEstimator\|ETAPresenter\|ChargingHistoryStore" PETL/

# Remove dead imports
find . -name "*.swift" -exec sed -i '' '/import.*ChargingRateEstimator/d' {} \;
```

**Live Activity Not Updating**
- Verify `NSSupportsLiveActivities = true` in Info.plist
- Check for duplicate attributes definition
- Ensure shared attributes are imported correctly

**Different Values in UI vs Live Activity**
- Verify single `processBatteryUpdate()` path in BatteryTrackingManager
- Check that all consumers get same snapshot
- Ensure ChargeEstimator is the only computation engine

### Debug Commands
```bash
# Check for duplicate files
find . -name "*ChargingRateEstimator*" -o -name "*ETAPresenter*" -o -name "*ChargingHistoryStore*"

# Check for dead imports
grep -r "import.*ChargingRateEstimator\|import.*ETAPresenter\|import.*ChargingHistoryStore" .

# Verify build
xcodebuild -project PETL.xcodeproj -scheme PETL build 2>&1 | grep -E "(error|warning)"
```

## 📈 Success Metrics

### Must Achieve (100%)
- [ ] Project builds with no warnings
- [ ] Same numbers in UI and Live Activity
- [ ] No duplicate computation engines
- [ ] All QA checklist critical tests pass

### Should Achieve (95%+)
- [ ] Performance targets met
- [ ] All QA checklist important tests pass
- [ ] No regression in functionality
- [ ] Clean, maintainable codebase

## 🎉 Definition of Done

- [ ] **Cleanup script executed** without errors
- [ ] **Code updates applied** from all markdown files
- [ ] **Project builds** with no warnings or errors
- [ ] **QA checklist passed** (98%+ pass rate)
- [ ] **Manual testing completed** (10-15 min charging session)
- [ ] **Performance verified** (CPU < 3%, updates ≤ 6/min)
- [ ] **Same numbers everywhere** (UI == Live Activity == Lock Screen)

## 📞 Support

If you encounter issues during the cleanup:

1. **Check the troubleshooting section** above
2. **Review the QA checklist** for specific test failures
3. **Verify the architecture** matches the "After" diagram
4. **Ensure single computation path** in BatteryTrackingManager

The cleanup is designed to be **reversible** - you can always revert to the backup branch if needed.

---

**Ready to execute?** Start with `./cleanup_execution_script.sh` and follow the implementation plan!
