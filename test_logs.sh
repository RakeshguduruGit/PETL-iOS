#!/bin/bash

echo "🔍 PETL App Log Testing Guide"
echo "=============================="
echo ""

echo "📱 How to View Logs in Xcode:"
echo "1. Open Xcode and run your PETL app"
echo "2. Go to View → Debug Area → Activate Console (or press Cmd+Shift+C)"
echo "3. In the console, click the filter button (funnel icon)"
echo "4. Select 'PETL' from the process list"
echo ""

echo "🔍 Expected Logs When App Starts:"
echo "✅ '🚀 PETL App Started - You should see this log!'"
echo "✅ '📱 ContentView Initialized - This should appear in logs!'"
echo "✅ '🔧 OneSignal Initialization Started'"
echo "✅ '📱 OneSignal App ID: [your app id]'"
echo ""

echo "🔍 If You Don't See Logs:"
echo "1. Make sure you're looking at the correct console (PETL process)"
echo "2. Check that the app is actually running"
echo "3. Try cleaning the build (Product → Clean Build Folder)"
echo "4. Restart Xcode if needed"
echo ""

echo "🧪 Test Steps:"
echo "1. Run the app in Xcode"
echo "2. Check console for the test logs above"
echo "3. Plug/unplug your device to test charging detection"
echo "4. Look for battery state change logs"
echo ""

echo "📋 Quick Commands:"
echo "- Clean Build: Product → Clean Build Folder"
echo "- Show Console: Cmd+Shift+C"
echo "- Filter Logs: Click funnel icon in console"
echo "" 