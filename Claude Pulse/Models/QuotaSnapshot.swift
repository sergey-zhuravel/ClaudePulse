//
//  QuotaSnapshot.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import Foundation

struct QuotaSnapshot {
    var planName:         String
    var periodConsumed:   Int        // billing-period total (from DOM)
    var periodCapacity:   Int        // billing-period limit  (from DOM)
    var windowConsumed:   Int = 0   // current rate-limit window (from API interceptor)
    var windowCapacity:   Int = 0   // current rate-limit window (from API interceptor)
    var windowResetDate:  Date?     // near-term reset (session window, from API)
    var periodResetDate:  Date?     // billing period / weekly reset (from DOM parsed date)
    var windowResetText:  String = "" // raw reset string if absolute format
    var periodResetText:  String = "" // raw weekday+time string e.g. "Fri 10:00 AM"
    var sonnetConsumed:   Int = 0   // sonnet-only weekly usage (from DOM)
    var sonnetCapacity:   Int = 0   // sonnet-only weekly limit (from DOM)
    var sonnetResetDate:  Date?     // sonnet-only reset date
    var sonnetResetText:  String = ""
    var userEmail:        String = ""
    var throttleStatus:   String
    var refreshedAt:      Date
    
    // MARK: - Consumption history
    // Rolling window of (timestamp, windowFraction) — max 10 points
    var consumptionHistory: [(date: Date, pct: Double)] = []
    
    // MARK: - Computed
    
    var hasWindowData: Bool { windowCapacity > 0 }
    
    var activeConsumed: Int { hasWindowData ? windowConsumed : periodConsumed }
    var activeCapacity: Int { hasWindowData ? windowCapacity : periodCapacity }
    
    var overallFraction: Double {
        guard activeCapacity > 0 else { return 0 }
        return min(1.0, Double(activeConsumed) / Double(activeCapacity))
    }
    
    var windowFraction: Double {
        guard windowCapacity > 0 else { return 0 }
        return min(1.0, Double(windowConsumed) / Double(windowCapacity))
    }
    
    var periodFraction: Double {
        guard periodCapacity > 0 else { return 0 }
        return min(1.0, Double(periodConsumed) / Double(periodCapacity))
    }

    var sonnetFraction: Double {
        guard sonnetCapacity > 0 else { return 0 }
        return min(1.0, Double(sonnetConsumed) / Double(sonnetCapacity))
    }
    
    var remainingMessages: Int { max(0, activeCapacity - activeConsumed) }
    
    // MARK: - Consumption rate
    
    /// Messages-per-minute consumed based on rolling history.
    /// Returns nil if < 2 points or < 5 minutes of data (too noisy).
    var consumptionRate: Double? {
        guard consumptionHistory.count >= 2 else { return nil }
        let oldest = consumptionHistory.first!
        let newest = consumptionHistory.last!
        let minutes = newest.date.timeIntervalSince(oldest.date) / 60.0
        guard minutes >= 5 else { return nil }
        let consumed = newest.pct - oldest.pct
        guard consumed > 0 else { return nil }
        return consumed / minutes
    }
    
    /// Estimated minutes until session hits 100%, capped at actual windowResetDate.
    var projectedMinutesLeft: Double? {
        guard let rate = consumptionRate, rate > 0 else { return nil }
        let remaining = 1.0 - windowFraction
        let estimated = remaining / rate
        if let reset = windowResetDate {
            let actual = reset.timeIntervalSince(Date()) / 60.0
            guard actual > 0 else { return nil }
            return min(estimated, actual)
        }
        return estimated
    }
    
    /// "~45min left" or "~2h 3m left" — nil if consumption rate unavailable
    var consumptionLabel: String? {
        guard let mins = projectedMinutesLeft else { return nil }
        if mins < 60 { return "~\(Int(mins))min left" }
        let h = Int(mins / 60)
        let m = Int(mins.truncatingRemainder(dividingBy: 60))
        return m > 0 ? "~\(h)h \(m)m left" : "~\(h)h left"
    }
    
    // MARK: - Reset labels
    
    var resetCountdown: String {
        guard let windowResetDate else { return "—" }
        let secs = windowResetDate.timeIntervalSince(Date())
        guard secs > 0 else { return "Soon" }
        let totalMins = Int(secs / 60)
        let h = totalMins / 60
        let m = totalMins % 60
        let days = h / 24
        if days > 0  { return "\(days)d \(h % 24)h" }
        if h > 0     { return "\(h)h \(m)m" }
        if m > 0     { return "\(m)m" }
        return "< 1m"
    }
    
    var windowResetLabel: String? {
        if let date = windowResetDate {
            let secs = date.timeIntervalSince(Date())
            if secs <= 0 { return "Resets soon" }
            let totalMins = Int(secs / 60)
            let h = totalMins / 60
            let m = totalMins % 60
            if h > 0 { return "Resets in \(h) hr \(m) min" }
            if m > 0 { return "Resets in \(m) min" }
            return "Resets in < 1 min"
        }
        if !windowResetText.isEmpty { return "Resets \(windowResetText)" }
        return nil
    }

    var periodResetLabel: String? {
        if !periodResetText.isEmpty { return "Resets \(periodResetText)" }
        guard let date = periodResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Resets \(f.string(from: date))"
    }

    var sonnetResetLabel: String? {
        if !sonnetResetText.isEmpty { return "Resets \(sonnetResetText)" }
        guard let date = sonnetResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "Resets \(f.string(from: date))"
    }
    
    var refreshTimestamp: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: refreshedAt)
    }
    
    // MARK: - Status bar text
    var statusBarText: String {
        let sessionStr: String?
        if hasWindowData {
            sessionStr = "\(Int(windowFraction * 100))%"
        } else {
            sessionStr = nil
        }
        let wPct = periodCapacity > 0 ? "\(Int(periodFraction * 100))%" : nil
        switch (sessionStr, wPct) {
        case let (s?, w?): return "\(s) | \(w)"
        case let (s?, nil): return s
        case let (nil, w?): return w
        default: return ""
        }
    }
    
    // MARK: - Hints
    
    struct UsageHint {
        let symbol: String
        let content: String
        let commands: [HintAction]
    }
    
    struct HintAction {
        let title: String
        let clipboardValue: String
    }
    
    var activeHints: [UsageHint] {
        let pct = windowFraction * 100
        var hints: [UsageHint] = []
        
        if pct >= 20 {
            hints.append(UsageHint(
                symbol: "arrow.triangle.2.circlepath",
                content: "Start a new conversation for each new topic to keep context small and responses fast.",
                commands: []
            ))
        }
        
        if pct >= 40 {
            hints.append(UsageHint(
                symbol: "bolt.fill",
                content: "Compress your session to free up context. Copy the prompt and send it in your current conversation:",
                commands: [
                    HintAction(
                        title: "claude.ai",
                        clipboardValue: "Please summarize our conversation so far in under 200 words so we can continue efficiently."
                    ),
                    HintAction(
                        title: "/compact",
                        clipboardValue: "/compact"
                    )
                ]
            ))
        }
        
        if pct >= 60 {
            hints.append(UsageHint(
                symbol: "doc.fill",
                content: "Avoid re-uploading large files. Reference content already shared earlier in the conversation.",
                commands: []
            ))
        }
        
        if pct >= 75 {
            hints.append(UsageHint(
                symbol: "checkmark.circle.fill",
                content: "Wrap up long threads. Save important outputs before your session resets.",
                commands: []
            ))
        }
        
        if pct >= 85 {
            hints.append(UsageHint(
                symbol: "exclamationmark.triangle.fill",
                content: "Best for short tasks now: quick questions, code review, short edits. Avoid starting new long projects.",
                commands: []
            ))
        }
        
        if pct >= 95 {
            hints.append(UsageHint(
                symbol: "xmark.octagon.fill",
                content: "Almost out. Save your work now. \(windowResetLabel ?? "Session resets soon").",
                commands: []
            ))
        }
        
        return hints
    }
    
    // MARK: - Outdated
    
    var isOutdated: Bool {
        Date().timeIntervalSince(refreshedAt) > 600
    }
}
