#!/bin/bash

echo "🔧 OneSignal Module Fix Script"
echo "=============================="

# Check if we're in the right directory
if [ ! -f "PETL.xcodeproj/project.pbxproj" ]; then
    echo "❌ Error: PETL.xcodeproj not found in current directory"
    exit 1
fi

echo "✅ Found PETL.xcodeproj"

# Check for OneSignal in project file
echo ""
echo "📦 Checking OneSignal in project dependencies..."
if grep -q "OneSignal" PETL.xcodeproj/project.pbxproj; then
    echo "✅ OneSignal found in project file"
else
    echo "❌ OneSignal not found in project file"
fi

# Check for OneSignal imports
echo ""
echo "📝 Checking OneSignal imports..."
if grep -r "import OneSignal" PETL/ 2>/dev/null; then
    echo "✅ OneSignal imports found"
else
    echo "❌ No OneSignal imports found"
fi

# Check for OneSignal frameworks in project
echo ""
echo "🔍 Checking for OneSignal frameworks in project..."
if grep -q "OneSignalFramework" PETL.xcodeproj/project.pbxproj; then
    echo "✅ OneSignalFramework found in project"
else
    echo "❌ OneSignalFramework not found in project"
fi

echo ""
echo "🎯 Next Steps:"
echo "1. Open Xcode: open PETL.xcodeproj"
echo "2. Select PETL target (main app)"
echo "3. Go to General tab"
echo "4. Scroll to 'Frameworks, Libraries, and Embedded Content'"
echo "5. Click '+' and add OneSignalFramework"
echo "6. Clean build folder (Cmd+Shift+K)"
echo "7. Build (Cmd+B)"

echo ""
echo "📋 If the above doesn't work:"
echo "1. Go to Package Dependencies"
echo "2. Right-click on onesignal-ios-sdk"
echo "3. Select 'Add to Target'"
echo "4. Choose PETL target" 