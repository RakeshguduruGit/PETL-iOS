# OneSignal Framework Setup Guide

## Important: Use Framework, Not Module Import

According to OneSignal documentation, you should **NOT** use `import OneSignal`. Instead, you should:

1. **Add OneSignalXCFramework to your target**
2. **Use the framework directly without imports**

## Current Setup Status

✅ **OneSignal package added to project**  
✅ **OneSignal frameworks linked to Live Activity extension**  
❌ **OneSignal frameworks NOT linked to main app target**  
❌ **Push Notifications capability missing**

## Steps to Fix

### Step 1: Add OneSignal Framework to Main App Target

1. **Open Xcode:** `open PETL.xcodeproj`
2. **Select the PETL target** (main app target)
3. **Go to "General" tab**
4. **Scroll to "Frameworks, Libraries, and Embedded Content"**
5. **Click the "+" button**
6. **Search for "OneSignal"**
7. **Add these frameworks:**
   - ✅ **OneSignalFramework**
   - ✅ **OneSignalExtension** (if available)

### Step 2: Add Push Notifications Capability

1. **For PETL target:** Signing & Capabilities → + Capability → Push Notifications
2. **For PETLLiveActivityExtension target:** Signing & Capabilities → + Capability → Push Notifications

### Step 3: Verify Framework Usage

The code should use OneSignal directly without imports:

```swift
// ✅ Correct - Use framework directly
OneSignal.initialize("your-app-id", withLaunchOptions: launchOptions)
OneSignal.Notifications.requestPermission(...)
OneSignal.User.pushSubscription.observeCurrent(...)

// ❌ Wrong - Don't import OneSignal
import OneSignal
```

### Step 4: Clean and Build

1. **Clean Build Folder:** Cmd+Shift+K
2. **Build:** Cmd+B

## Framework vs Module

- **Framework:** OneSignalXCFramework (correct approach)
- **Module:** `import OneSignal` (incorrect approach)

The framework approach is what OneSignal documentation recommends for Live Activities. 