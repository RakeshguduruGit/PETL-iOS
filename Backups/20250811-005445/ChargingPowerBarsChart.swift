import SwiftUI
import Charts

// Uses your existing PowerSample model: time: Date, watts: Double, isCharging: Bool
struct ChargingPowerBarsChart: View {
    let samples: [PowerSample]                  // parent passes already-fetched samples
    let axis: ChartTimeAxisModel                // parent passes axis (domain + tick step)

    // Bar width constraints
    let minBarWidthSec: TimeInterval = 10       // floor so very fast sampling still shows
    let maxBarWidthSec: TimeInterval = 180      // cap so bars don't become too wide

    var body: some View {
        VStack(spacing: 12) {
            // MARK: Chart
            if #available(iOS 16.0, *) {
                Chart {
                    ForEach(chargingSamples) { s in
                        RectangleMark(
                            xStart: .value("Start", s.time.addingTimeInterval(-barHalfWidth)),
                            xEnd:   .value("End",   s.time.addingTimeInterval( barHalfWidth)),
                            yStart: .value("Base",  0.0),
                            yEnd:   .value("Power (W)", s.watts)
                        )
                        .foregroundStyle(barColor(for: s.watts))
                        .cornerRadius(2)
                    }
                }
                .frame(height: 180)

                // Y axis: 0 → 15 (expand to 25 only if needed; >25 rounds to next 5)
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(values: yTicks) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            Text("\(Int((value.as(Double.self) ?? 0)))W")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(.secondaryLabel))
                        }
                    }
                }

                // X axis from shared axis model
                .chartXScale(domain: axis.domain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: axis.tickStepHours)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let d = value.as(Date.self) {
                                if axis.tickStepHours >= 24 {
                                    Text(d, format: .dateTime
                                            .month(.abbreviated)
                                            .day()
                                            .hour(.defaultDigits(amPM: .abbreviated)))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(.secondaryLabel))
                                } else {
                                    Text(d, format: .dateTime
                                            .hour(.defaultDigits(amPM: .abbreviated)))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(.secondaryLabel))
                                }
                            }
                        }
                    }
                }
                .accessibilityLabel("Charging Power (Watts) Over Time")
            } else {
                Text("Charts require iOS 16+")
                    .foregroundColor(.gray)
                    .frame(height: 180)
            }

            // MARK: Legend + Last updated (matches backup layout)
            HStack {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.blue.opacity(0.75)).frame(width: 12, height: 8)
                    Rectangle().fill(Color.green.opacity(0.85)).frame(width: 12, height: 8)
                    Rectangle().fill(Color.orange.opacity(0.85)).frame(width: 12, height: 8)
                    Rectangle().fill(Color.red.opacity(0.85)).frame(width: 12, height: 8)
                }
                Text("Power (W)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.secondaryLabel))

                Spacer()

                Text("Last updated: \(formatLastUpdated(lastSampleTime))")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
    }

    // MARK: - Filtering / ordering
    private var chargingSamples: [PowerSample] {
        samples.filter { $0.isCharging }.sorted { $0.time < $1.time }
    }

    // MARK: - Bar width (median sample interval → clamped)
    private var inferredInterval: TimeInterval {
        let times = chargingSamples.map(\.time)
        guard times.count >= 2 else { return 60 }
        let diffs = zip(times.dropFirst(), times).map { $0.0.timeIntervalSince($0.1) }
        let sorted = diffs.sorted()
        return sorted[sorted.count/2] // median
    }
    private var barHalfWidth: TimeInterval {
        max(minBarWidthSec, min(maxBarWidthSec, inferredInterval * 0.45))
    }

    // MARK: - Y axis dynamic range
    private var maxObservedW: Double {
        chargingSamples.map(\.watts).max() ?? 0
    }
    private var yTop: Double {
        if maxObservedW <= 15 { return 15 }
        if maxObservedW <= 25 { return 25 }
        return ceil(maxObservedW / 5.0) * 5.0
    }
    private var yDomain: ClosedRange<Double> { 0 ... yTop }
    private var yTicks: [Double] {
        Array(stride(from: 0.0, through: yTop, by: 5.0))
    }

    // MARK: - Color ramp (blue → green → orange → red)
    private func barColor(for watts: Double) -> some ShapeStyle {
        switch watts {
        case ..<7.5:     return Color.blue.opacity(0.75)
        case ..<12.5:    return Color.green.opacity(0.85)
        case ..<17.5:    return Color.orange.opacity(0.85)
        default:         return Color.red.opacity(0.85)
        }
    }

    private var lastSampleTime: Date? { samples.last?.time }
    
    private func formatLastUpdated(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }
} 