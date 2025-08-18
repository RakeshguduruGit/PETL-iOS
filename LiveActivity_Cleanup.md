# Live Activity Extension Cleanup

## Overview
Remove duplicate attributes definition and ensure Live Activity uses shared PETLLiveActivityAttributes.

## 1. Remove Duplicate Attributes

**File: PETLLiveActivityExtension/PETLLiveActivityExtensionLiveActivity.swift**

Remove lines 12-85 (the duplicate `PETLLiveActivityExtensionAttributes` definition).

**Lines to delete:**
```swift
// DELETE THIS ENTIRE BLOCK (lines 12-85):
public struct PETLLiveActivityExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // ... all the ContentState definition
    }
    
    public var name: String
    public init(name: String) {
        self.name = name
    }
}
```

**Keep only:**
```swift
import ActivityKit
import WidgetKit
import SwiftUI

struct PETLLiveActivityExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PETLLiveActivityAttributes.self) { context in
            // ... rest of the widget implementation
        }
    }
}
```

## 2. Update Import

Add this import at the top of the file:
```swift
import ActivityKit
import WidgetKit
import SwiftUI
// Add this line to import the shared attributes:
import PETL  // This imports the shared PETLLiveActivityAttributes
```

## 3. Update ActivityConfiguration

Change the ActivityConfiguration to use the shared attributes:

```swift
// OLD:
ActivityConfiguration(for: PETLLiveActivityExtensionAttributes.self) { context in

// NEW:
ActivityConfiguration(for: PETLLiveActivityAttributes.self) { context in
```

## 4. Update Context Usage

Update all references to use the shared attributes:

```swift
// OLD:
context.state.batteryLevel
context.state.isCharging
// etc.

// NEW: (should be the same, but verify field names match)
context.state.batteryLevel
context.state.isCharging
// etc.
```

## 5. Verify Shared Attributes

**File: PETL/Shared/PETLLiveActivityAttributes.swift**

Ensure this file contains the canonical attributes definition:

```swift
import ActivityKit

public struct PETLLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var batteryLevel: Int
        public var isCharging: Bool
        public var chargingRate: String
        public var estimatedWattage: String
        public var timeToFullMinutes: Int
        public var expectedFullDate: Date
        public var deviceModel: String
        public var batteryHealth: String
        public var isInWarmUpPeriod: Bool
        public var timestamp: Date
        
        // ... rest of the implementation
    }
    
    public var name: String
    
    public init(name: String) {
        self.name = name
    }
}
```

## 6. Update LiveActivityManager

**File: PETL/LiveActivityManager.swift**

Ensure LiveActivityManager uses the shared attributes:

```swift
// Verify this import exists:
import ActivityKit

// Verify Activity creation uses shared attributes:
let attributes = PETLLiveActivityAttributes(name: "PETL Charging")
```

## 7. Update SnapshotToLiveActivity

**File: PETL/SnapshotToLiveActivity.swift**

Ensure the mapper uses the shared attributes:

```swift
// Verify this method signature:
static func makeContent(from snapshot: ChargingSnapshot) -> PETLLiveActivityAttributes.ContentState {
    // ... mapping logic
}
```

## 8. Remove Optional Files

If not shipping these files, remove them:

```bash
rm PETLLiveActivityExtension/PETLLiveActivityExtension.swift
rm PETLLiveActivityExtension/PETLLiveActivityExtensionControl.swift
rm PETLLiveActivityExtension/AppIntent.swift
```

## 9. Update Extension Info.plist

**File: PETLLiveActivityExtension/Info.plist**

Ensure Live Activities support is enabled:

```xml
<key>NSSupportsLiveActivities</key>
<true/>
```

## 10. Verify Asset Sharing

**File: PETLLiveActivityExtension/Assets.xcassets/**

Ensure the extension has access to required assets:

1. PETLLogoLiveActivity.imageset
2. WidgetBackground.colorset
3. Any other assets used by the Live Activity

## 11. Complete Verification Checklist

After cleanup, verify:

- [ ] No duplicate attributes definition in Live Activity extension
- [ ] Extension imports and uses shared PETLLiveActivityAttributes
- [ ] ActivityConfiguration uses shared attributes
- [ ] All context.state references work correctly
- [ ] LiveActivityManager creates activities with shared attributes
- [ ] SnapshotToLiveActivity maps to shared ContentState
- [ ] Extension Info.plist has NSSupportsLiveActivities = true
- [ ] Required assets are available in extension
- [ ] Optional files are removed (if not shipping)

## 12. Testing

Test the Live Activity extension:

```bash
# Build the extension
xcodebuild -project PETL.xcodeproj -scheme PETLLiveActivityExtension -destination 'platform=iOS Simulator,name=iPhone 15' build

# Verify no compilation errors
```

## 13. Manual Testing Checklist

- [ ] Live Activity starts when charging begins
- [ ] Live Activity updates with battery level changes
- [ ] Live Activity shows correct ETA and watts
- [ ] Live Activity ends when charging stops
- [ ] Dynamic Island displays correctly
- [ ] Lock screen Live Activity displays correctly
- [ ] No duplicate activities created
- [ ] Assets load correctly in extension

## 14. Common Issues & Fixes

**Issue: "Cannot find PETLLiveActivityAttributes in scope"**
- Fix: Ensure the extension target includes the shared file in target membership

**Issue: "Duplicate type definition"**
- Fix: Remove the duplicate attributes definition from the extension file

**Issue: "Missing assets in extension"**
- Fix: Add assets to extension asset catalog or share with target membership

**Issue: "Activity creation fails"**
- Fix: Verify Info.plist has NSSupportsLiveActivities = true
