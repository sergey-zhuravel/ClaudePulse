//
//  AlertDispatcher.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import Foundation
import UserNotifications

final class AlertDispatcher {
    static let instance = AlertDispatcher()
    private init() {}
    
    /// Levels already dispatched in the current session window.
    private var dispatchedLevels = Set<Int>()
    
    /// Last known reset date — used to detect when a new window starts.
    private var previousResetTimestamp: Date?
    
    // MARK: - Permission
    
    func authorizeAlerts() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    // MARK: - Main entry point
    
    func evaluateAndDispatch(snapshot: QuotaSnapshot) {
        evaluateUsageLevels(snapshot: snapshot)
        detectWindowReset(snapshot: snapshot)
    }
    
    // MARK: - Usage threshold alerts
    
    private func evaluateUsageLevels(snapshot: QuotaSnapshot) {
        // Use windowFraction (rate-limit window), fall back to overallFraction
        let pct = snapshot.hasWindowData ? snapshot.windowFraction : snapshot.overallFraction
        
        let config: [(level: Int, heading: String, detail: String)] = [
            (75, "Halfway through your session",
             "Consider wrapping up long threads. Start fresh conversations for new topics."),
            (80, "Session at 80%",
             "Avoid new long projects or file uploads. Best for: quick questions, short edits, code review."),
            (90, "Session at 90% — act fast",
             "~10% left. Finish your current task and save important outputs before the limit hits."),
            (95, "Almost out",
             "Save your work now. \(snapshot.windowResetLabel ?? "Session resets soon")."),
            (100, "Claude Limit Reached",
             "You've used your full quota. \(snapshot.windowResetLabel ?? "Resets soon").")
        ]
        
        for entry in config {
            let fraction = Double(entry.level) / 100.0
            if pct >= fraction {
                guard !dispatchedLevels.contains(entry.level) else { continue }
                dispatchedLevels.insert(entry.level)
                postLocalAlert(heading: entry.heading, detail: entry.detail, identifier: "claude-tip-\(entry.level)")
            } else {
                dispatchedLevels.remove(entry.level)
            }
        }
    }
    
    private func postLocalAlert(heading: String, detail: String, identifier: String) {
        let payload = UNMutableNotificationContent()
        payload.title = heading
        payload.body  = detail
        payload.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: payload, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    // MARK: - Session reset detection
    
    private func detectWindowReset(snapshot: QuotaSnapshot) {
        guard let newReset = snapshot.windowResetDate else { return }
        
        if let known = previousResetTimestamp, newReset > known.addingTimeInterval(3600) {
            dispatchedLevels.removeAll()
            postLocalAlert(
                heading: "Claude Session Reset",
                detail: "Your usage window has reset. You have a full quota available.",
                identifier: "claude-reset-\(Int(Date().timeIntervalSince1970))"
            )
        }
        
        previousResetTimestamp = newReset
    }
}
