# PETL Project Rules & Development Guidelines

## 🚀 **Current Project Status**

✅ **Build Status**: Successfully compiles with no errors  
✅ **App Status**: Stable and ready for development  
✅ **Architecture**: Well-established with clear component separation  
✅ **Documentation**: Comprehensive and up-to-date  

## 📋 **Recent Updates (August 2024)**

### **Compilation Issues Resolved**
- ✅ **Fixed ViewBuilder Error**: Removed problematic `addToAppLogs` call from SwiftUI ViewBuilder context
- ✅ **Updated onChange Syntax**: Updated to iOS 17+ compatible syntax with two parameters
- ✅ **Build Success**: App now compiles successfully with exit code 0
- ✅ **Stable State**: All core functionality working as expected

### **Previous Architecture Changes**
- **SST Revert**: Successfully reverted Single Source of Truth implementation for stability
- **Smooth Analytics**: Implemented continuous charging rate estimation between iOS's 5% SOC steps
- **Live Activity Integration**: Added Dynamic Island and Lock Screen support
- **Background Monitoring**: OneSignal integration for reliable background operation

## 🏗️ **Architecture Overview**

### **Core Components**

#### **BatteryTrackingManager**
- **Purpose**: Centralized battery state management
- **Responsibilities**: 
  - Monitor battery level and charging state changes
  - Emit snapshots to other components
  - Manage battery monitoring lifecycle
- **Key Features**:
  - Singleton pattern for global access
  - Combine publishers for reactive updates
  - Comprehensive logging with debug tokens

#### **ChargingRateEstimator**
- **Purpose**: Smooths analytics between iOS's 5% SOC steps
- **Responsibilities**:
  - Interpolate between 5% battery level steps
  - Calculate charging rate and power consumption
  - Provide time-to-full estimates
- **Key Features**:
  - EMA smoothing for stable estimates
  - 10W warm-up fallback during initial charging
  - Data gap detection and confidence gating

#### **ChargingHistoryStore**
- **Purpose**: Manages charging history with backfill capabilities
- **Responsibilities**:
  - Store charging samples with timestamps
  - Backfill historical data for smooth charts
  - Provide data for analytics and debugging
- **Key Features**:
  - Linear ramp backfill for smooth visualization
  - Codable data structure for persistence
  - Source tracking for data quality

#### **LiveActivityManager**
- **Purpose**: Handles Live Activity lifecycle and updates
- **Responsibilities**:
  - Start and end Live Activities
  - Update Live Activity content
  - Manage background monitoring
- **Key Features**:
  - Multiple fallback mechanisms for reliable ending
  - Throttling to prevent spam
  - Comprehensive error handling

#### **OneSignalClient**
- **Purpose**: Background monitoring and push notification integration
- **Responsibilities**:
  - Handle push notifications
  - Manage background task execution
  - Provide self-ping backup mechanism
- **Key Features**:
  - REST API implementation for self-pings
  - Background task registration
  - Comprehensive error handling and logging

### **Data Flow Architecture**

```
BatteryTrackingManager
    ↓ (snapshots)
ChargingRateEstimator
    ↓ (analytics)
ChargingAnalyticsStore
    ↓ (UI state)
ContentView
    ↓ (user interactions)
LiveActivityManager
    ↓ (background)
OneSignalClient
```

## 🔧 **Development Guidelines**

### **Code Quality Standards**

#### **SwiftUI Best Practices**
- Use `@ObservedObject` for singleton managers
- Avoid `@EnvironmentObject` for complex state management
- Keep ViewBuilder contexts clean (no side effects)
- Use proper onChange syntax for iOS 17+ compatibility

#### **Error Handling**
- Always handle potential failures gracefully
- Log errors with appropriate detail
- Provide fallback mechanisms for critical operations
- Use comprehensive logging for debugging

#### **Performance Considerations**
- Minimize UI updates during battery monitoring
- Use appropriate debouncing for frequent events
- Implement proper cleanup in deinit methods
- Monitor memory usage in background scenarios

### **Testing & Debugging**

#### **QA Testing Mode**
Enable comprehensive testing with:
```swift
// Via launch argument
-QA_TEST_MODE

// Via UserDefaults
UserDefaults.standard.set(true, forKey: "QA_TEST_MODE")
```

**QA Mode Features**:
- **Debounce**: 0.0s (immediate response for torture testing)
- **Watchdog**: 25s (faster fallback for testing)
- **Reliability Metrics**: Track all Live Activity lifecycle events
- **Comprehensive Logging**: Detailed Info tab logs for debugging

#### **Reliability Metrics**
Monitor these key ratios for system health:
- `startReq` / `startOK`: Start request vs success ratio
- `endReqLocal` / `endOK`: Local end request vs success ratio
- `remoteEndOK` / `remoteEndIgnored`: Remote command handling
- `watchdog`: Fallback timer fires (should be rare)
- `selfPings`: Self-ping backup mechanism usage

### **Logging Standards**

#### **Log Categories**
- **`main`**: App lifecycle and initialization
- **`content`**: UI state changes and user interactions
- **`liveactivity`**: All Live Activity lifecycle events
- **`onesignal`**: Remote push handling and self-pings
- **`battery`**: Battery monitoring and analytics

#### **Log Format**
```swift
// Standard format with emoji and context
addToAppLogs("🔋 Battery level: \(level)% charging: \(isCharging)")
print("📱 Live Activity started: \(activityId)")
```

## 📚 **Documentation Requirements**

### **Required Updates**
When making changes, update these files:
1. **COMPREHENSIVE_CHANGES_SUMMARY.md**: Major implementation changes
2. **CURRENT_STATE.md**: Current app status and architecture
3. **README.md**: High-level overview and setup instructions
4. **PROJECT_RULES.md**: This file for development guidelines
5. **Component-specific docs**: For new or modified components

### **Documentation Standards**
- Keep all documentation current with implementation
- Include code examples for complex features
- Document breaking changes clearly
- Maintain consistent formatting and structure

## 🚨 **Critical Rules**

### **Never Remove Unconditional Logs**
- Unconditional logs form the diagnostic contract
- They are essential for production debugging
- Only DEBUG logs may be silenced in release builds

### **Maintain Architecture Separation**
- Keep components loosely coupled
- Use proper dependency injection
- Avoid circular dependencies
- Maintain clear data flow

### **Test Thoroughly**
- Use QA testing mode for reliability validation
- Test Live Activity scenarios on physical devices
- Monitor reliability metrics during development
- Validate background behavior thoroughly

### **Handle Edge Cases**
- Always provide fallback mechanisms
- Handle network failures gracefully
- Implement proper cleanup for background tasks
- Consider battery and performance implications

## 🎯 **Success Metrics**

### **Reliability Targets**
- **Live Activity Start Success**: >95%
- **Live Activity End Success**: >98%
- **Background Monitoring**: Continuous operation
- **Battery Analytics**: Accurate within 5% margin

### **Performance Targets**
- **UI Responsiveness**: <100ms for state updates
- **Memory Usage**: <50MB in background
- **Battery Impact**: <1% per hour in background
- **Startup Time**: <2 seconds cold start

## 📋 **Development Checklist**

### **Before Making Changes**
- [ ] Understand the current architecture
- [ ] Identify all affected components
- [ ] Plan comprehensive testing strategy
- [ ] Document expected outcomes
- [ ] Consider background/foreground scenarios

### **During Implementation**
- [ ] Test changes incrementally
- [ ] Validate build success after each change
- [ ] Check for duplicate declarations
- [ ] Verify UI consistency
- [ ] Test background transitions

### **After Implementation**
- [ ] Run comprehensive tests
- [ ] Update documentation
- [ ] Validate user experience
- [ ] Monitor for regressions
- [ ] Test multiple usage cycles

## 🔍 **Common Issues & Solutions**

### **Build Errors**
- **ViewBuilder Errors**: Don't call functions with side effects in ViewBuilder contexts
- **Deprecation Warnings**: Update to latest iOS APIs
- **Duplicate Declarations**: Search for existing implementations before adding

### **Runtime Issues**
- **Live Activity Not Starting**: Check battery state and background capabilities
- **Memory Leaks**: Ensure proper cleanup in deinit methods
- **Background Failures**: Verify OneSignal configuration and entitlements

### **Performance Issues**
- **UI Lag**: Minimize updates during battery monitoring
- **High Memory Usage**: Implement proper cleanup for background tasks
- **Battery Drain**: Optimize background monitoring frequency

---

**Last Updated**: August 2024  
**Status**: Stable, Buildable, and Ready for Development 