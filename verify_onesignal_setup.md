# OneSignal Setup Verification Guide

## Step 1: Check Package Dependencies

1. Open your Xcode project
2. Go to **Project Navigator** → **Package Dependencies**
3. Verify that `OneSignal-iOS-SDK` is listed
4. Click on it and check that both targets are selected:
   - ✅ **PETL** (main app)
   - ✅ **PETLLiveActivityExtension** (extension)

## Step 2: Check Target Dependencies

### For Main App Target (PETL):
1. Select the **PETL** target
2. Go to **General** tab
3. Scroll to **Frameworks, Libraries, and Embedded Content**
4. Verify that `OneSignalFramework` is listed

### For Live Activity Extension:
1. Select the **PETLLiveActivityExtension** target
2. Go to **General** tab
3. Scroll to **Frameworks, Libraries, and Embedded Content**
4. Verify that `OneSignalFramework` is listed

## Step 3: Check Build Settings

### For Main App Target:
1. Select **PETL** target
2. Go to **Build Settings**
3. Search for "Framework Search Paths"
4. Verify OneSignal paths are included

### For Extension Target:
1. Select **PETLLiveActivityExtension** target
2. Go to **Build Settings**
3. Search for "Framework Search Paths"
4. Verify OneSignal paths are included

## Step 4: Test Build

Run this command to test the build:
```bash
xcodebuild -project PETL.xcodeproj -scheme PETL -destination 'platform=iOS,id=YOUR_DEVICE_ID' clean build
```

## Troubleshooting

### If you still get "no such module 'OneSignal'":

1. **Clean Build Folder:**
   - Xcode → Product → Clean Build Folder
   - Or Cmd+Shift+K

2. **Reset Package Cache:**
   - File → Packages → Reset Package Caches

3. **Re-add OneSignal:**
   - Remove OneSignal from Package Dependencies
   - Re-add it using the URL: `https://github.com/OneSignal/OneSignal-iOS-SDK`
   - Make sure to select both targets

4. **Check Target Membership:**
   - In Project Navigator, select your Swift files
   - In the File Inspector (right panel), check that the correct target is selected

## Expected Files Structure

After proper setup, you should see:
```
PETL/
├── PETL/
│   ├── PETLApp.swift (imports OneSignal)
│   └── ContentView.swift
└── PETLLiveActivityExtension/
    └── PETLLiveActivityExtensionLiveActivity.swift
```

## OneSignal Configuration

Make sure your `PETLApp.swift` has:
```swift
import OneSignal

// In AppDelegate
OneSignal.initialize("YOUR_ONESIGNAL_APP_ID", withLaunchOptions: launchOptions)
```

## Push Notifications Capability

Ensure both targets have Push Notifications capability:
1. Select each target
2. Go to **Signing & Capabilities**
3. Click **+ Capability**
4. Add **Push Notifications** 