#!/bin/bash

echo "🔍 Checking OneSignal Setup in PETL Project..."
echo "=============================================="

# Check if project file exists
if [ ! -f "PETL.xcodeproj/project.pbxproj" ]; then
    echo "❌ Error: PETL.xcodeproj not found in current directory"
    exit 1
fi

echo "✅ Found PETL.xcodeproj"

# Check for OneSignal in project file
echo ""
echo "📦 Checking for OneSignal in project dependencies..."

if grep -q "OneSignal" PETL.xcodeproj/project.pbxproj; then
    echo "✅ OneSignal found in project file"
else
    echo "❌ OneSignal not found in project file"
fi

# Check for OneSignal import in Swift files
echo ""
echo "📝 Checking for OneSignal imports in Swift files..."

if grep -r "import OneSignal" PETL/ 2>/dev/null; then
    echo "✅ OneSignal import found in Swift files"
else
    echo "❌ OneSignal import not found in Swift files"
fi

# Check for OneSignal initialization
echo ""
echo "🔧 Checking for OneSignal initialization..."

if grep -r "OneSignal.initialize" PETL/ 2>/dev/null; then
    echo "✅ OneSignal initialization found"
else
    echo "❌ OneSignal initialization not found"
fi

# Check for Push Notifications capability
echo ""
echo "📱 Checking for Push Notifications capability..."

if grep -q "aps-environment" PETL.xcodeproj/project.pbxproj; then
    echo "✅ Push Notifications capability found"
else
    echo "❌ Push Notifications capability not found"
fi

echo ""
echo "🎯 Next Steps:"
echo "1. Open Xcode and verify OneSignal is added to both targets"
echo "2. Clean build folder (Cmd+Shift+K)"
echo "3. Build the project (Cmd+B)"
echo "4. If errors persist, re-add OneSignal package to both targets"

echo ""
echo "📋 For detailed verification, see: verify_onesignal_setup.md" 