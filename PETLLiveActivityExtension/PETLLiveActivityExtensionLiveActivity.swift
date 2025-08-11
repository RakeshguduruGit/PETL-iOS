//
//  PETLLiveActivityExtensionLiveActivity.swift
//  PETLLiveActivityExtension
//
//  Created by rakesh guduru on 7/27/25.
//

import ActivityKit
import WidgetKit
import SwiftUI

// Local copy of the attributes for the extension
struct PETLLiveActivityExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        public var batteryLevel: Float
        public var isCharging: Bool
        public var chargingRate: String
        public var estimatedWattage: String
        public var timeToFullMinutes: Int
        public var deviceModel: String
        public var batteryHealth: String
        public var isInWarmUpPeriod: Bool
        public var timestamp: Date
        
        public init(batteryLevel: Float, isCharging: Bool, chargingRate: String, estimatedWattage: String, timeToFullMinutes: Int, deviceModel: String, batteryHealth: String, isInWarmUpPeriod: Bool, timestamp: Date) {
            self.batteryLevel = batteryLevel
            self.isCharging = isCharging
            self.chargingRate = chargingRate
            self.estimatedWattage = estimatedWattage
            self.timeToFullMinutes = timeToFullMinutes
            self.deviceModel = deviceModel
            self.batteryHealth = batteryHealth
            self.isInWarmUpPeriod = isInWarmUpPeriod
            self.timestamp = timestamp
        }
    }

    // Fixed non-changing properties about your activity go here!
    public var name: String
    
    public init(name: String) {
        self.name = name
    }
}

struct PETLLiveActivityExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PETLLiveActivityExtensionAttributes.self) { context in
            // Fresh Live Activity Card following Apple HIG Guidelines
            VStack(spacing: 8) {
                // Header with essential info
                HStack {
                    // Left: App branding with logo
                    HStack(spacing: 8) {
                        Image("PETLLogoLiveActivity")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                            .shadow(color: .green.opacity(0.6), radius: 2, x: 0, y: 0)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PETL")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("Charging")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.gray)
                        }
                    }
                    
                    Spacer()
                    
                    // Right: Time to full (Primary data)
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.timeToFullMinutes > 0 {
                            Text("\(context.state.timeToFullMinutes) min")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(.cyan)
                        } else {
                            Text("--")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(.cyan)
                        }
                        
                        if !context.state.chargingRate.isEmpty && context.state.chargingRate != "Not charging" {
                            Text(context.state.chargingRate)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.cyan)
                        }
                    }
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.green, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * CGFloat(context.state.batteryLevel))
                            .animation(.none, value: context.state.batteryLevel) // Remove animation to prevent CADisplay errors
                    }
                }
                .frame(height: 8)
                
                // Essential charging info
                HStack(spacing: 16) {
                    // Battery Ring (replaces percentage display)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.gray)
                        
                        // Battery Ring
                        ZStack {
                            // Background ring
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                .frame(width: 28, height: 28)
                                .rotationEffect(.degrees(-90))
                            
                            // Foreground ring (battery level)
                            Circle()
                                .trim(from: 0, to: CGFloat(context.state.batteryLevel))
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.22, green: 1.0, blue: 0.08),
                                            Color(red: 0.0, green: 1.0, blue: 1.0)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .frame(width: 28, height: 28)
                                .rotationEffect(.degrees(-90))
                                .animation(.none, value: context.state.batteryLevel) // Remove animation to prevent CADisplay errors
                        }
                    }
                    
                    Spacer()
                    
                    if !context.state.estimatedWattage.isEmpty && context.state.estimatedWattage != "Not charging" {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Power")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.gray)
                            Text(context.state.estimatedWattage)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.8))
            )

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded view through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Image("PETLLogoLiveActivity")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                        
                        Text("PETL")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        if context.state.isCharging {
                            Text("\(context.state.timeToFullMinutes) min")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            Text("\(context.state.timeToFullMinutes) min")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                }
                
                DynamicIslandExpandedRegion(.center) {
                    if context.state.isCharging {
                        VStack(spacing: 2) {
                            Text("Charging")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.green)
                            
                            Text(context.state.chargingRate)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    } else {
                        Text("Not Charging")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                    }
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isCharging {
                        HStack {
                            Text("Full in")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(context.state.timeToFullMinutes) min")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else {
                        Text("Connect to charge")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            } compactLeading: {
                if context.state.isCharging {
                    // Logo only on the left (HIG compliant)
                    Image("PETLLogoLiveActivity")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 18)
                        .foregroundColor(.primary)
                } else {
                    // Logo only on the left when not charging
                    Image("PETLLogoLiveActivity")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 18)
                        .foregroundColor(.secondary)
                }
            } compactTrailing: {
                if context.state.isCharging {
                    // Time in Xm format on the right (HIG compliant)
                    Text("\(context.state.timeToFullMinutes)m")
                        .font(.caption)
                        .fontWeight(.medium)
                } else {
                    // Show minutes even when not charging (no percent fallback)
                    Text("\(context.state.timeToFullMinutes)m")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } minimal: {
                if context.state.isCharging {
                    // Logo only in minimal view (HIG compliant)
                    Image("PETLLogoLiveActivity")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 16)
                        .foregroundColor(.primary)
                } else {
                    // Logo only in minimal view when not charging
                    Image("PETLLogoDynamic")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 8)
                        .foregroundColor(.secondary)
                }
            }
            .widgetURL(URL(string: "petl://activity"))
            .keylineTint(Color.green)
        }
    }
}

extension PETLLiveActivityExtensionAttributes {
    fileprivate static var preview: PETLLiveActivityExtensionAttributes {
        PETLLiveActivityExtensionAttributes(name: "PETL Charging")
    }
}

extension PETLLiveActivityExtensionAttributes.ContentState {
    fileprivate static var charging: PETLLiveActivityExtensionAttributes.ContentState {
        PETLLiveActivityExtensionAttributes.ContentState(
            batteryLevel: 0.65,
            isCharging: true,
            chargingRate: "Fast Charging",
            estimatedWattage: "20W",
            timeToFullMinutes: 45,
            deviceModel: "iPhone 16 Pro",
            batteryHealth: "Excellent (95%+)",
            isInWarmUpPeriod: false,
            timestamp: Date()
        )
     }
     
     fileprivate static var notCharging: PETLLiveActivityExtensionAttributes.ContentState {
         PETLLiveActivityExtensionAttributes.ContentState(
             batteryLevel: 0.35,
             isCharging: false,
             chargingRate: "Not charging",
             estimatedWattage: "0W",
             timeToFullMinutes: 0,
             deviceModel: "iPhone 16 Pro",
             batteryHealth: "Excellent (95%+)",
             isInWarmUpPeriod: false,
             timestamp: Date()
         )
     }
     
     fileprivate static var warmUp: PETLLiveActivityExtensionAttributes.ContentState {
         PETLLiveActivityExtensionAttributes.ContentState(
             batteryLevel: 0.45,
             isCharging: true,
             chargingRate: "Standard Charging",
             estimatedWattage: "10W",
             timeToFullMinutes: 75,
             deviceModel: "iPhone 16 Pro",
             batteryHealth: "Excellent (95%+)",
             isInWarmUpPeriod: true,
             timestamp: Date()
         )
     }
}

#Preview("Notification", as: .content, using: PETLLiveActivityExtensionAttributes.preview) {
   PETLLiveActivityExtensionLiveActivity()
} contentStates: {
    PETLLiveActivityExtensionAttributes.ContentState.charging
    PETLLiveActivityExtensionAttributes.ContentState.notCharging
    PETLLiveActivityExtensionAttributes.ContentState.warmUp
}



/// Formats time for Lock Screen display (full format)
private func formatTimeForLockScreen(_ timeText: String) -> String {
    // Keep the original format for Lock Screen
    return timeText
}
