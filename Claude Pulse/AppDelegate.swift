//
//  AppDelegate.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import AppKit
import SwiftUI
import Combine
import UserNotifications
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusBarItem: NSStatusItem!
    private var floatingPanel: NSPopover!
    private var authController: AuthWindowController?
    private var pollingTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    
    private let dataProvider = UsageDataProvider.instance
    private let alertEngine = AlertDispatcher.instance
    private let updaterController: SPUStandardUpdaterController
    
    private var consumptionLog: [(date: Date, pct: Double)] = []
    
    // MARK: - Polling interval (persisted in UserDefaults)
    
    private var pollingInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: "refreshInterval")
            return stored > 0 ? stored : 120
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "refreshInterval")
            reschedulePolling()
        }
    }
    
    // MARK: - Initialisation
    
    override init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }
    
    // MARK: - Application lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        alertEngine.authorizeAlerts()
        configureStatusBar()
        configurePanel()
        bindDataProvider()
        launchDataFetch()
    }
    
    // MARK: - Status bar
    
    private func configureStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusBarItem.button else { return }
        button.action = #selector(handleBarClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon(snapshot: nil)
    }
    
    @objc private func handleBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            presentContextMenu()
        } else {
            togglePanel()
        }
    }
    
    private func refreshIcon(snapshot: QuotaSnapshot?) {
        guard let button = statusBarItem.button else { return }
        
        let isOutdated = snapshot?.isOutdated ?? false
        
        if let img = NSImage.init(named: "menuIcon") {
            img.size = NSSize(width: 16, height: 16)
            button.image = img
        }
        
        if let label = snapshot?.statusBarText, !label.isEmpty {
            button.title = isOutdated ? " ⚠ \(label)" : " \(label)"
        } else {
            button.title = ""
        }
        
        if let snapshot = snapshot {
            let staleNote = isOutdated ? " · stale" : ""
            button.toolTip = "Claude Pulse · Updated \(snapshot.refreshTimestamp)\(staleNote)"
        } else {
            button.toolTip = "Claude Pulse"
        }
    }
    
    // MARK: - Right-click context menu
    
    private func presentContextMenu() {
        guard let button = statusBarItem.button else { return }
        
        let menu = NSMenu()
        
        // Current usage info or sign-in
        if dataProvider.requiresAuth {
            let signInItem = NSMenuItem(
                title: "Sign In to Claude...",
                action: #selector(openSignIn),
                keyEquivalent: ""
            )
            signInItem.target = self
            menu.addItem(signInItem)
        } else if let snapshot = dataProvider.currentSnapshot {
            let pctStr = "\(Int(snapshot.overallFraction * 100))%"
            let infoItem = NSMenuItem(
                title: "\(snapshot.activeConsumed)/\(snapshot.activeCapacity)  (\(pctStr))",
                action: nil,
                keyEquivalent: ""
            )
            infoItem.isEnabled = false
            menu.addItem(infoItem)

            if snapshot.windowResetDate != nil {
                let resetItem = NSMenuItem(
                    title: "Resets in \(snapshot.resetCountdown)",
                    action: nil,
                    keyEquivalent: ""
                )
                resetItem.isEnabled = false
                menu.addItem(resetItem)
            }

            if snapshot.isOutdated {
                let staleItem = NSMenuItem(title: "⚠  Data may be stale", action: nil, keyEquivalent: "")
                staleItem.isEnabled = false
                menu.addItem(staleItem)
            }
        } else {
            let emptyItem = NSMenuItem(title: "No data yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }
        
        menu.addItem(.separator())
        
        // Refresh interval submenu
        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalSubmenu = NSMenu()
        let choices: [(String, TimeInterval)] = [
            ("30 seconds", 30),
            ("1 minute",   60),
            ("2 minutes",  120),
            ("5 minutes",  300),
            ("10 minutes", 600),
        ]
        for (label, interval) in choices {
            let item = NSMenuItem(title: label, action: #selector(applyPollingInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = abs(pollingInterval - interval) < 1 ? .on : .off
            intervalSubmenu.addItem(item)
        }
        intervalItem.submenu = intervalSubmenu
        menu.addItem(intervalItem)
        
        menu.addItem(.separator())
        
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(triggerRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(invokeUpdateCheck),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)
        
        menu.addItem(.separator())
        
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        
        // Pop up below the status bar button
        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }
    
    @objc private func applyPollingInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        pollingInterval = interval
    }
    
    @objc private func triggerRefresh() {
        dataProvider.reloadData()
    }
    
    @objc private func invokeUpdateCheck() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func openSignIn() {
        showAuthWindow()
    }
    
    // MARK: - Popover
    
    private func configurePanel() {
        let rootView = DashboardView(
            onCheckForUpdates: { [weak self] in
                self?.updaterController.checkForUpdates(nil)
            },
            onSignIn: { [weak self] in
                self?.showAuthWindow()
            }
        ).environmentObject(dataProvider)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true
        
        floatingPanel = NSPopover()
        floatingPanel.contentSize           = NSSize(width: 320, height: 380)
        floatingPanel.behavior              = .transient
        floatingPanel.animates              = true
        floatingPanel.contentViewController = hostingController
    }
    
    private func togglePanel() {
        if floatingPanel.isShown {
            floatingPanel.performClose(nil)
        } else if let button = statusBarItem.button {
            let age = dataProvider.currentSnapshot.map { Date().timeIntervalSince($0.refreshedAt) } ?? 999
            if age > 30 { dataProvider.reloadData() }
            floatingPanel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            floatingPanel.contentViewController?.view.window?.makeKey()
        }
    }
    
    // MARK: - Combine observers
    
    private func bindDataProvider() {
        dataProvider.$currentSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                guard let snapshot = snapshot else {
                    self.refreshIcon(snapshot: nil)
                    return
                }
                // Detect session reset (pct dropped) → clear history
                if snapshot.windowFraction < (self.consumptionLog.last?.pct ?? 0) - 0.01 {
                    self.consumptionLog.removeAll()
                }
                // Append current point, keep last 10
                self.consumptionLog.append((date: Date(), pct: snapshot.windowFraction))
                if self.consumptionLog.count > 10 { self.consumptionLog.removeFirst() }
                
                // Enrich a local copy — never write back to dataProvider.currentSnapshot
                var enriched = snapshot
                enriched.consumptionHistory = self.consumptionLog
                self.refreshIcon(snapshot: enriched)
                self.alertEngine.evaluateAndDispatch(snapshot: enriched)
            }
            .store(in: &subscriptions)
        
        // requiresAuth changes are observed by DashboardView via @Published
    }
    
    // MARK: - Startup + polling timer
    
    private func launchDataFetch() {
        dataProvider.performInitialFetch()
        reschedulePolling()
    }
    
    private func reschedulePolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.dataProvider.reloadData()
        }
    }
    
    // MARK: - Auth window
    
    private func showAuthWindow() {
        floatingPanel.performClose(nil)

        if authController == nil {
            let controller = AuthWindowController()
            controller.onAuthCompleted = { [weak self] in
                DispatchQueue.main.async {
                    self?.authController?.close()
                    self?.authController = nil
                    // Immediately hide sign-in and show loading spinner
                    self?.dataProvider.requiresAuth = false
                    self?.dataProvider.isFetching = true
                    self?.dataProvider.reloadData()
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            authController = controller
        }

        // Switch to regular app so macOS allows window activation
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.authController?.showWindow(nil)
            self?.authController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
