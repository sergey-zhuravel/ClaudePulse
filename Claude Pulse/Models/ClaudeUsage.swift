//
//  ClaudeUsage.swift
//  Claude Pulse
//
//  Usage data from OAuth API — session (5h), weekly (7d), and sonnet limits.
//

import Foundation

struct ClaudeUsage {
    var sessionPercentage: Double
    var sessionResetTime: Date

    var weeklyPercentage: Double
    var weeklyResetTime: Date

    var sonnetPercentage: Double
    var sonnetResetTime: Date?

    var lastUpdated: Date

    var effectiveSessionPercentage: Double {
        sessionResetTime < Date() ? 0.0 : sessionPercentage
    }
}

// MARK: - Date helper

extension Date {
    func nextMonday1259pm(in timezone: TimeZone = .current) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = timezone

        var components = calendar.dateComponents([.year, .month, .day, .weekday], from: self)
        let currentWeekday = components.weekday ?? 1
        let daysUntilMonday = currentWeekday == 2 ? 7 : (9 - currentWeekday) % 7

        guard let nextMonday = calendar.date(byAdding: .day, value: daysUntilMonday, to: self) else {
            return self
        }

        components = calendar.dateComponents([.year, .month, .day], from: nextMonday)
        components.hour = 12
        components.minute = 59
        components.second = 0

        return calendar.date(from: components) ?? self
    }
}
