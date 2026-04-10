//
//  DashboardView.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var dataProvider: UsageDataProvider
    
    var onCheckForUpdates: () -> Void = {}
    var onSignIn: () -> Void = {}
    
    private var pollingLabel: String {
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let secs = interval > 0 ? interval : 120
        if secs < 60 { return "\(Int(secs))s" }
        let mins = Int(secs / 60)
        return "\(mins)m"
    }
    
    var body: some View {
        ZStack {
            // Frosted-glass base
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                headerSection
                Divider().opacity(0.4)
                mainContent
                Divider().opacity(0.4)
                footerSection
            }
        }
        .frame(width: 320)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 10) {
            if let img = NSImage.init(named: "menuIcon") {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            
            Text("Claude Pulse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            
            Spacer()
            
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    private func planChip(_ plan: String) -> some View {
        Text(plan.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(planTint(plan))
            .clipShape(Capsule())
    }
    
    private func planTint(_ plan: String) -> Color {
        switch plan.lowercased() {
        case "pro":  return .green
        case "max":  return .purple
        case "team": return .blue
        default:     return .gray
        }
    }
    
    // MARK: - Main scrollable area

    private var mainContent: some View {
        VStack(spacing: 16) {
            if dataProvider.requiresAuth {
                signInPrompt
            } else if dataProvider.currentSnapshot == nil {
                loadingPlaceholder
            } else if let msg = dataProvider.fetchError, dataProvider.currentSnapshot == nil {
                failureView(msg)
            } else {
                if let snapshot = dataProvider.currentSnapshot, snapshot.isOutdated {
                    outdatedBanner
                }
                hintsSection
                quotaBarsSection
            }
        }
        .padding(16)
    }

    // MARK: - Sign in prompt

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Sign in to Claude")
                .font(.system(size: 14, weight: .semibold))

            Text("Log in to your Claude account to start tracking usage limits.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Sign In") {
                onSignIn()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
    
    // MARK: - Stale data banner
    
    private var outdatedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("Data may be outdated")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Spacer()
            Button("Refresh") { dataProvider.reloadData() }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Loading / error states
    
    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Loading usage data…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
    
    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { dataProvider.reloadData() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
    
    // MARK: - Hints section
    
    private var hintsSection: some View {
        Group {
            if let hints = dataProvider.currentSnapshot?.activeHints, !hints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                        HintCardView(hint: hint)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
    }
    
    // MARK: - Bars section
    
    private var quotaBarsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan usage limits")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 14)
            
            if let snapshot = dataProvider.currentSnapshot {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    VStack(spacing: 0) {
                        // Current session bar
                        quotaBarRow(
                            title: "Current session",
                            resetLabel: snapshot.windowResetLabel,
                            consumed: snapshot.windowConsumed,
                            capacity: snapshot.windowCapacity,
                            fraction: snapshot.windowFraction
                        )
                        
                        Divider()
                            .opacity(0.3)
                            .padding(.vertical, 14)
                        
                        // Weekly limits section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Weekly limits")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            quotaBarRow(
                                title: "All models",
                                resetLabel: snapshot.periodResetLabel,
                                consumed: snapshot.periodConsumed,
                                capacity: snapshot.periodCapacity,
                                fraction: snapshot.periodFraction
                            )

                            if snapshot.sonnetCapacity > 0 {
                                quotaBarRow(
                                    title: "Sonnet only",
                                    resetLabel: snapshot.sonnetResetLabel,
                                    consumed: snapshot.sonnetConsumed,
                                    capacity: snapshot.sonnetCapacity,
                                    fraction: snapshot.sonnetFraction
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            dataProvider.isFetching
            ? AnyView(
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            )
            : AnyView(EmptyView())
        )
    }
    
    private func quotaBarRow(
        title: String,
        resetLabel: String?,
        consumed: Int,
        capacity: Int,
        fraction: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let label = resetLabel {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if capacity == 0 {
                        Text("No data")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if capacity > 0 {
                    Text("\(Int(fraction * 100))% used")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            
            if capacity > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barTint(for: fraction))
                            .frame(width: max(8, geo.size.width * CGFloat(fraction)), height: 8)
                            .animation(.spring(response: 0.7, dampingFraction: 0.8), value: fraction)
                    }
                }
                .frame(height: 8)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 8)
            }
        }
    }
    
    private func barTint(for fraction: Double) -> Color {
        switch fraction {
        case 0.8...: return .red
        case 0.5...: return .orange
        default:     return .green
        }
    }
    
    // MARK: - Rate limit card
    
    private func throttleCard(_ snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.throttleStatus == "Limited" ? "bolt.slash.fill" : "bolt.fill")
                .foregroundStyle(snapshot.throttleStatus == "Limited" ? .orange : .green)
                .font(.system(size: 13))
            Text("Rate limit")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(snapshot.throttleStatus)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(snapshot.throttleStatus == "Limited" ? .orange : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    if let snapshot = dataProvider.currentSnapshot {
                        Text("Updated \(snapshot.refreshTimestamp)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Not yet updated")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    dataProvider.reloadData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(dataProvider.isFetching ? .tertiary : .secondary)
                .focusable(false)
                .help("Refresh")
                .disabled(dataProvider.isFetching)

                Button {
                    onCheckForUpdates()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focusable(false)
                .help("Check for Updates")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focusable(false)
                .help("Quit Claude Pulse")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Text("Refreshes every \(pollingLabel)  ·  Right-click icon to change")
                .font(.system(size: 9))
                .foregroundStyle(Color.primary.opacity(0.25))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)

            if let email = dataProvider.currentSnapshot?.userEmail, !email.isEmpty {
                Divider().opacity(0.4)
                Text(email)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }
}
