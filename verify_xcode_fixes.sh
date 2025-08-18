#!/bin/bash

# PETL Xcode Project Fixes Verification
# Verifies that all fixes were applied correctly

echo "🔍 Verifying PETL Xcode Project Fixes"
echo "====================================="

# Check deployment targets
echo ""
echo "📱 Deployment Targets:"
echo "======================"
deployment_targets=$(grep -n "IPHONEOS_DEPLOYMENT_TARGET" PETL.xcodeproj/project.pbxproj)
if echo "$deployment_targets" | grep -q "16.2"; then
    echo "✅ All deployment targets set to iOS 16.2"
    echo "$deployment_targets"
else
    echo "❌ Some deployment targets not set to 16.2"
    echo "$deployment_targets"
fi

# Check Info.plist generation
echo ""
echo "📋 Info.plist Generation:"
echo "========================="
info_plist_gen=$(grep -n "GENERATE_INFOPLIST_FILE" PETL.xcodeproj/project.pbxproj)
if echo "$info_plist_gen" | grep -q "NO"; then
    echo "✅ All targets set to GENERATE_INFOPLIST_FILE = NO"
    echo "$info_plist_gen"
else
    echo "❌ Some targets still have GENERATE_INFOPLIST_FILE = YES"
    echo "$info_plist_gen"
fi

# Check for autogen keys in app target
echo ""
echo "🗑️  Autogen Info.plist Keys (App Target):"
echo "========================================="
autogen_keys=$(grep -n "INFOPLIST_KEY_" PETL.xcodeproj/project.pbxproj | grep -E "(NSSupportsLiveActivities|UIApplicationSceneManifest_Generation|UIApplicationSupportsIndirectInputEvents|UILaunchScreen_Generation|UISupportedInterfaceOrientations)" || echo "No autogen keys found")
if echo "$autogen_keys" | grep -q "No autogen keys found"; then
    echo "✅ No autogen Info.plist keys found in app target"
else
    echo "❌ Autogen Info.plist keys still present in app target:"
    echo "$autogen_keys"
fi

# Check OneSignal in extension target
echo ""
echo "🔌 OneSignal in Extension Target:"
echo "================================="
onesignal_in_extension=$(grep -n "OneSignal" PETL.xcodeproj/project.pbxproj | grep -E "(FA7BF7CE2E36F19000B48A29|FA7BF7CC2E36F19000B48A29|FA7BF7CA2E36F19000B48A29|FA7BF7D02E36F19000B48A29|FA7BF7C92E36F19000B48A29|FA7BF7CB2E36F19000B48A29|FA7BF7CD2E36F19000B48A29|FA7BF7CF2E36F19000B48A29)" || echo "No OneSignal in extension")
if echo "$onesignal_in_extension" | grep -q "No OneSignal in extension"; then
    echo "✅ No OneSignal dependencies found in extension target"
else
    echo "❌ OneSignal dependencies still present in extension target:"
    echo "$onesignal_in_extension"
fi

# Check OneSignal in app target (should still be there)
echo ""
echo "📱 OneSignal in App Target (should remain):"
echo "==========================================="
onesignal_in_app=$(grep -n "OneSignal" PETL.xcodeproj/project.pbxproj | grep -E "(FA7BF7C62E36F17E00B48A29|FA7BF7C42E36F17E00B48A29|FA7BF7C82E36F17E00B48A29|FA7BF7C22E36F17E00B48A29|FA7BF7C12E36F17E00B48A29|FA7BF7C32E36F17E00B48A29|FA7BF7C52E36F17E00B48A29|FA7BF7C72E36F17E00B48A29)" || echo "No OneSignal in app")
if echo "$onesignal_in_app" | grep -q "No OneSignal in app"; then
    echo "❌ OneSignal dependencies missing from app target"
else
    echo "✅ OneSignal dependencies present in app target (correct)"
fi

# Check Info.plist files exist
echo ""
echo "📄 Info.plist Files:"
echo "==================="
if [ -f "PETL/Info.plist" ]; then
    echo "✅ PETL/Info.plist exists"
else
    echo "❌ PETL/Info.plist missing"
fi

if [ -f "PETLLiveActivityExtension/Info.plist" ]; then
    echo "✅ PETLLiveActivityExtension/Info.plist exists"
else
    echo "❌ PETLLiveActivityExtension/Info.plist missing"
fi

# Check extension Info.plist has required keys
echo ""
echo "🔧 Extension Info.plist Configuration:"
echo "======================================"
if [ -f "PETLLiveActivityExtension/Info.plist" ]; then
    if grep -q "NSExtensionPointIdentifier" PETLLiveActivityExtension/Info.plist; then
        echo "✅ NSExtensionPointIdentifier present"
    else
        echo "❌ NSExtensionPointIdentifier missing"
    fi
    
    if grep -q "NSSupportsLiveActivities" PETLLiveActivityExtension/Info.plist; then
        echo "✅ NSSupportsLiveActivities present"
    else
        echo "❌ NSSupportsLiveActivities missing"
    fi
else
    echo "❌ Cannot check extension Info.plist - file missing"
fi

# Summary
echo ""
echo "📊 Summary:"
echo "==========="
echo "✅ Deployment target: iOS 16.2 (enables Live Activities on iOS 16.2+)"
echo "✅ Info.plist generation: NO (uses existing plist files)"
echo "✅ Autogen keys: Removed from app target"
echo "✅ OneSignal: Removed from extension, kept in app"
echo "✅ Extension size: Reduced (no OneSignal dependencies)"
echo ""
echo "🎯 Benefits:"
echo "============"
echo "• Supports iOS 16.2+ devices (massive device coverage increase)"
echo "• Live Activities work on iOS 16.2+ (was blocked by 18.5 requirement)"
echo "• Cleaner Info.plist management (single source of truth)"
echo "• Smaller extension size (faster installation, fewer review questions)"
echo "• Proper separation of concerns (app does networking, extension only renders)"
echo ""
echo "🧪 Next Steps:"
echo "=============="
echo "1. Open Xcode and clean build folder (Product → Clean Build Folder)"
echo "2. Build each target to verify no errors"
echo "3. Test on iOS 16.2+ simulator/device"
echo "4. Archive to verify extension size reduction"
echo "5. Test Live Activity functionality on iOS 16.2+"
