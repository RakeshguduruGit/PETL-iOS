#!/bin/bash

# PETL SSOT Architecture Cleanup - Execution Script
# Run this script to execute the complete cleanup plan

set -e  # Exit on any error

echo "🚀 Starting PETL SSOT Architecture Cleanup"
echo "=========================================="

# Phase 0: Create branch
echo "📝 Phase 0: Creating cleanup branch..."
git checkout -b cleanup/ssot-architecture
echo "✅ Branch created: cleanup/ssot-architecture"

# Phase 1: File Surgery
echo ""
echo "🗑️  Phase 1: Removing duplicate files..."

# Remove core duplicate files
echo "Removing ChargingRateEstimator.swift..."
rm -f PETL/Shared/Analytics/ChargingRateEstimator.swift

echo "Removing ChargingHistoryStore.swift..."
rm -f PETL/Shared/Analytics/ChargingHistoryStore.swift

echo "Removing ETAPresenter.swift..."
rm -f PETL/ETAPresenter.swift

# Optional: Remove unused Live Activity files
echo "Removing optional Live Activity files..."
rm -f PETLLiveActivityExtension/PETLLiveActivityExtension.swift
rm -f PETLLiveActivityExtension/PETLLiveActivityExtensionControl.swift
rm -f PETLLiveActivityExtension/AppIntent.swift

echo "✅ Phase 1 complete: Duplicate files removed"

# Phase 2: Remove dead imports
echo ""
echo "🧹 Phase 2: Cleaning up imports..."

# Remove dead imports from all Swift files
echo "Removing ETAPresenter imports..."
find . -name "*.swift" -exec sed -i '' '/import.*ETAPresenter/d' {} \;

echo "Removing ChargingRateEstimator imports..."
find . -name "*.swift" -exec sed -i '' '/import.*ChargingRateEstimator/d' {} \;

echo "Removing ChargingHistoryStore imports..."
find . -name "*.swift" -exec sed -i '' '/import.*ChargingHistoryStore/d' {} \;

echo "✅ Phase 2 complete: Dead imports removed"

# Phase 3: Check for build errors
echo ""
echo "🔨 Phase 3: Checking build status..."
if xcodebuild -project PETL.xcodeproj -scheme PETL -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | grep -q "error:"; then
    echo "❌ Build errors detected. Please fix before continuing."
    echo "Common fixes:"
    echo "  - Remove references to deleted classes"
    echo "  - Update BatteryTrackingManager to use ChargeEstimator only"
    echo "  - Remove duplicate attributes in Live Activity extension"
    exit 1
else
    echo "✅ Build successful - no immediate errors"
fi

echo ""
echo "🎉 Cleanup script completed!"
echo ""
echo "Next steps:"
echo "1. Review and update BatteryTrackingManager.swift to use ChargeEstimator as SSOT"
echo "2. Remove duplicate attributes block in PETLLiveActivityExtensionLiveActivity.swift"
echo "3. Update ChargeEstimator to provide unified Output struct"
echo "4. Run the QA checklist from CLEANUP_IMPLEMENTATION_PLAN.md"
echo ""
echo "Files removed:"
echo "  - ChargingRateEstimator.swift"
echo "  - ChargingHistoryStore.swift" 
echo "  - ETAPresenter.swift"
echo "  - PETLLiveActivityExtension.swift (optional)"
echo "  - PETLLiveActivityExtensionControl.swift (optional)"
echo "  - AppIntent.swift (optional)"
echo ""
echo "Ready for manual code updates in Phase 2-4 of the implementation plan."
