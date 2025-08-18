#!/bin/bash

# PETL Xcode Project Fixes
# Fixes deployment target, Info.plist generation, and OneSignal dependencies

set -e  # Exit on any error

echo "🔧 Starting PETL Xcode Project Fixes"
echo "===================================="

# Backup the original project file
echo "📦 Creating backup..."
cp PETL.xcodeproj/project.pbxproj PETL.xcodeproj/project.pbxproj.backup
echo "✅ Backup created: PETL.xcodeproj/project.pbxproj.backup"

# Fix 1: Set deployment target to 16.2 for all configurations
echo ""
echo "🎯 Fix 1: Setting deployment target to iOS 16.2..."

# Project level - Debug configuration
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 18.5;/IPHONEOS_DEPLOYMENT_TARGET = 16.2;/g' PETL.xcodeproj/project.pbxproj

# Project level - Release configuration  
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 18.5;/IPHONEOS_DEPLOYMENT_TARGET = 16.2;/g' PETL.xcodeproj/project.pbxproj

# App target - Debug configuration
sed -i '' '/FA7BF7982E36E88900B48A29 \/\* Debug \*\//,/};/ s/GENERATE_INFOPLIST_FILE = YES;/GENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.2;/' PETL.xcodeproj/project.pbxproj

# App target - Release configuration
sed -i '' '/FA7BF7992E36E88900B48A29 \/\* Release \*\//,/};/ s/GENERATE_INFOPLIST_FILE = YES;/GENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.2;/' PETL.xcodeproj/project.pbxproj

# Extension target - Debug configuration
sed -i '' '/FA7BF7B92E36EB7500B48A29 \/\* Debug \*\//,/};/ s/GENERATE_INFOPLIST_FILE = YES;/GENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.2;/' PETL.xcodeproj/project.pbxproj

# Extension target - Release configuration
sed -i '' '/FA7BF7BA2E36EB7500B48A29 \/\* Release \*\//,/};/ s/GENERATE_INFOPLIST_FILE = YES;/GENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.2;/' PETL.xcodeproj/project.pbxproj

echo "✅ Deployment target set to iOS 16.2 for all configurations"

# Fix 2: Remove autogen Info.plist keys from app target
echo ""
echo "🗑️  Fix 2: Removing autogen Info.plist keys from app target..."

# Remove INFOPLIST_KEY_* lines from app target Debug configuration
sed -i '' '/FA7BF7982E36E88900B48A29 \/\* Debug \*\//,/};/ {
    /INFOPLIST_KEY_NSSupportsLiveActivities = YES;/d
    /INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;/d
    /INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;/d
    /INFOPLIST_KEY_UILaunchScreen_Generation = YES;/d
    /INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";/d
    /INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";/d
}' PETL.xcodeproj/project.pbxproj

# Remove INFOPLIST_KEY_* lines from app target Release configuration
sed -i '' '/FA7BF7992E36E88900B48A29 \/\* Release \*\//,/};/ {
    /INFOPLIST_KEY_NSSupportsLiveActivities = YES;/d
    /INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;/d
    /INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;/d
    /INFOPLIST_KEY_UILaunchScreen_Generation = YES;/d
    /INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";/d
    /INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";/d
}' PETL.xcodeproj/project.pbxproj

echo "✅ Autogen Info.plist keys removed from app target"

# Fix 3: Remove OneSignal from extension target
echo ""
echo "🔌 Fix 3: Removing OneSignal from extension target..."

# Remove OneSignal framework files from extension target's Frameworks build phase
sed -i '' '/FA7BF79E2E36EB7300B48A29 \/\* Frameworks \*\//,/};/ {
    /FA7BF7CE2E36F19000B48A29 \/\* OneSignalInAppMessages in Frameworks \*\//d
    /FA7BF7CC2E36F19000B48A29 \/\* OneSignalFramework in Frameworks \*\//d
    /FA7BF7CA2E36F19000B48A29 \/\* OneSignalExtension in Frameworks \*\//d
    /FA7BF7D02E36F19000B48A29 \/\* OneSignalLocation in Frameworks \*\//d
}' PETL.xcodeproj/project.pbxproj

# Remove OneSignal package dependencies from extension target
sed -i '' '/FA7BF7A02E36EB7300B48A29 \/\* PETLLiveActivityExtensionExtension \*\//,/};/ {
    /FA7BF7C92E36F19000B48A29 \/\* OneSignalExtension \*\//d
    /FA7BF7CB2E36F19000B48A29 \/\* OneSignalFramework \*\//d
    /FA7BF7CD2E36F19000B48A29 \/\* OneSignalInAppMessages \*\//d
    /FA7BF7CF2E36F19000B48A29 \/\* OneSignalLocation \*\//d
}' PETL.xcodeproj/project.pbxproj

echo "✅ OneSignal removed from extension target"

# Verify the fixes
echo ""
echo "🔍 Verifying fixes..."

echo "📱 Deployment targets:"
grep -n "IPHONEOS_DEPLOYMENT_TARGET" PETL.xcodeproj/project.pbxproj

echo ""
echo "📋 Info.plist generation:"
grep -n "GENERATE_INFOPLIST_FILE" PETL.xcodeproj/project.pbxproj

echo ""
echo "🔌 OneSignal in extension (should be empty):"
grep -n "OneSignal" PETL.xcodeproj/project.pbxproj | grep -i "ExtensionExtension" || echo "✅ No OneSignal found in extension target"

echo ""
echo "🎉 Xcode project fixes completed!"
echo ""
echo "Next steps:"
echo "1. Open Xcode and clean build folder (Product → Clean Build Folder)"
echo "2. Build each target to verify no errors"
echo "3. Test on iOS 16.2+ simulator/device"
echo "4. Archive to verify extension size reduction"
echo ""
echo "Changes made:"
echo "✅ Deployment target: 18.5 → 16.2 (enables iOS 16.2+ support)"
echo "✅ Info.plist generation: YES → NO (uses existing plist files)"
echo "✅ Removed autogen keys from app target"
echo "✅ Removed OneSignal from extension target"
echo ""
echo "If you need to revert:"
echo "cp PETL.xcodeproj/project.pbxproj.backup PETL.xcodeproj/project.pbxproj"
