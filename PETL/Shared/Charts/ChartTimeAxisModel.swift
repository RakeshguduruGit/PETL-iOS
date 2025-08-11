import Foundation

struct ChartTimeAxisModel {
    let domain: ClosedRange<Date>
    let tickStepHours: Int

    init(historyDates: [Date]) {
        let now = Date()
        let lower: Date
        let upper: Date
        if let first = historyDates.first, let last = historyDates.last {
            if first == last {
                lower = first.addingTimeInterval(-1800)
                upper = last.addingTimeInterval(1800)
            } else {
                lower = first
                upper = last
            }
        } else {
            lower = now.addingTimeInterval(-4 * 3600)
            upper = now
        }

        let spanHrs = upper.timeIntervalSince(lower) / 3600
        let step: Int =
            spanHrs <= 24 ? 4 :
            spanHrs <= 72 ? 8 :
            spanHrs <= 7*24 ? 12 : 24
        self.tickStepHours = step
        self.domain = ChartTimeAxisModel.align(lower...upper, stepHours: step)
    }

    private static func align(_ raw: ClosedRange<Date>, stepHours: Int) -> ClosedRange<Date> {
        let cal = Calendar.current
        func floorToHour(_ d: Date) -> Date {
            var c = cal.dateComponents([.year,.month,.day,.hour], from: d)
            c.minute = 0; c.second = 0
            if let h = c.hour { c.hour = (h / stepHours) * stepHours }
            return cal.date(from: c) ?? d
        }
        func ceilToHour(_ d: Date) -> Date {
            let f = floorToHour(d)
            return f == d ? d : cal.date(byAdding: .hour, value: stepHours, to: f) ?? d
        }
        return floorToHour(raw.lowerBound)...ceilToHour(raw.upperBound)
    }
}
