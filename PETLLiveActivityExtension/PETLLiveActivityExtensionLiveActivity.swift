//
//  PETLLiveActivityExtensionLiveActivity.swift
//  PETLLiveActivityExtension
//
//  Created by rakesh guduru on 7/27/25.
//

import ActivityKit
import WidgetKit
import SwiftUI

// Live Activity Attributes - must be defined in extension target

struct PETLLiveActivityExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PETLLiveActivityAttributes.self) { context in
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
                    
                    // Right: Time to full (Primary data) - Self-updating timer
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.isCharging && context.state.timeToFullMinutes > 0 {
                            HStack(spacing: 6) {
                                Text(context.state.expectedFullDate, style: .timer)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundColor(.cyan)
                                    .monospacedDigit()
                                Text("to full")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.gray)
                            }
                            .accessibilityLabel("Time to full")
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
                            .frame(width: geometry.size.width * CGFloat(context.state.batteryLevel) / 100.0)
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
                                .trim(from: 0, to: CGFloat(context.state.batteryLevel) / 100.0)
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
                        if context.state.isCharging && context.state.timeToFullMinutes > 0 {
                            Text(context.state.expectedFullDate, style: .timer)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .monospacedDigit()
                        } else {
                            Text("--")
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
                    if context.state.isCharging && context.state.timeToFullMinutes > 0 {
                        HStack {
                            Text("Full in")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.gray)
                            Spacer()
                            Text(context.state.expectedFullDate, style: .timer)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else if context.state.isCharging {
                        Text("Calculating...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.gray)
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





/// Formats time for Lock Screen display (full format)
private func formatTimeForLockScreen(_ timeText: String) -> String {
    // Keep the original format for Lock Screen
    return timeText
}
