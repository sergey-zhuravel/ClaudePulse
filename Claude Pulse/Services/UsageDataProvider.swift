//
//  UsageDataProvider.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import WebKit
import Combine
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Injected at document START – wraps fetch/XHR before any page JS runs.
// Every response whose URL or body looks usage-related is forwarded to Swift
// via the "usageHandler" message handler.
// ─────────────────────────────────────────────────────────────────────────────
private let kInterceptorScript = """
(function() {
    const _send = (payload) => {
        try { window.webkit.messageHandlers.usageHandler.postMessage(JSON.stringify(payload)); }
        catch(e) {}
    };

    const _tryForward = (text, url) => {
        if (!text || text.length < 10 || text.length > 500000) return;
        // Skip static assets and i18n files
        if (url.indexOf('.js') !== -1 || url.indexOf('.css') !== -1 ||
            url.indexOf('i18n') !== -1 || url.indexOf('statsig') !== -1) return;
        try {
            const json = JSON.parse(text);
            // Capture any API JSON that has at least one numeric value
            if (text.indexOf('{') !== -1 && /:\\s*\\d/.test(text)) {
                _send({ type: 'api', url: url, data: json });
            }
        } catch(e) {}
    };

    // ── fetch wrapper ──────────────────────────────────────────────────────
    const _origFetch = window.fetch;
    window.fetch = function(...args) {
        const url = (args[0] instanceof Request ? args[0].url : String(args[0] || ''));
        return _origFetch.apply(this, args).then(resp => {
            resp.clone().text().then(t => _tryForward(t, url)).catch(()=>{});
            return resp;
        });
    };

    // ── XHR wrapper ────────────────────────────────────────────────────────
    const _origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(m, url, ...rest) {
        this.__url = url;
        return _origOpen.apply(this, [m, url, ...rest]);
    };
    const _origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(...args) {
        this.addEventListener('load', () => _tryForward(this.responseText, this.__url || ''));
        return _origSend.apply(this, args);
    };
})();
"""

// ─────────────────────────────────────────────────────────────────────────────
// Fallback DOM extraction (runs after 2.5 s to let React render).
// ─────────────────────────────────────────────────────────────────────────────
private let kDOMParserScript = """
(function() {
    var r = {
        planType: 'Unknown', messagesUsed: -1, messagesLimit: -1,
        sessionUsed: -1, sessionLimit: -1,
        sonnetUsed: -1, sonnetLimit: -1, sonnetTitle: '',
        designUsed: -1, designLimit: -1, designTitle: '',
        resetDateStr: '', sessionResetStr: '', weeklyResetStr: '', sonnetResetStr: '', designResetStr: '',
        rateLimitStatus: 'Normal', needsLogin: false, source: 'dom',
        userEmail: '', rawText: ''
    };
    try {
        var url = window.location.href;
        if (url.includes('/login') || url.includes('/auth') ||
            document.title.toLowerCase().includes('sign in')) {
            r.needsLogin = true; return JSON.stringify(r);
        }

        // Gather only visible text nodes — skip script/style/noscript entirely
        var body = '';
        try {
            var walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_TEXT,
                { acceptNode: function(node) {
                    var p = node.parentElement;
                    while (p) {
                        var t = p.tagName;
                        if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT') return NodeFilter.FILTER_REJECT;
                        p = p.parentElement;
                    }
                    return node.textContent.trim().length > 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                }}
            );
            var parts = [];
            while (walker.nextNode()) { parts.push(walker.currentNode.textContent.trim()); }
            body = parts.join(' ').replace(/\\s+/g, ' ').trim();
        } catch(e) { body = document.body ? document.body.innerText : ''; }
        // Also check Next.js / React global state for reset info
        var nextData = '';
        try {
            var nd = window.__NEXT_DATA__;
            if (nd) nextData = JSON.stringify(nd).substring(0, 2000);
        } catch(e) {}
        r.rawText = (body.substring(0, 2000) + ' ' + nextData).trim();

        // Plan
        var plans = [[/claude\\s+max|\\bmax\\s+plan/i,'Max'],[/claude\\s+pro|\\bpro\\s+plan/i,'Pro'],
                     [/claude\\s+team|\\bteam\\s+plan/i,'Team'],[/\\bfree\\s+plan|claude\\s+free/i,'Free']];
        for (var p of plans) { if (p[0].test(body)) { r.planType = p[1]; break; } }

        // ── Specific patterns first (most reliable) ──────────────────────
        var specificPatterns = [
            /(\\d+)\\s+of\\s+(\\d+)\\s+(?:usage\\s+)?messages?/i,
            /(\\d+)\\s+messages?\\s+(?:of|out\\s+of)\\s+(\\d+)/i,
            /(\\d+)\\s*\\/\\s*(\\d+)\\s+messages?/i,
            /messages?[:\\s]+(\\d+)\\s*(?:\\/|of)\\s*(\\d+)/i,
        ];
        for (var sp of specificPatterns) {
            var sm = body.match(sp);
            if (sm) {
                r.messagesUsed  = parseInt(sm[1]);
                r.messagesLimit = parseInt(sm[2]);
                break;
            }
        }

        // ── aria progressbar (single authoritative value) ─────────────────
        if (r.messagesLimit <= 0) {
            var bars = Array.from(document.querySelectorAll('[role="progressbar"]'));
            // Use the LAST bar — Claude puts the primary usage bar last
            for (var i = bars.length - 1; i >= 0; i--) {
                var now = bars[i].getAttribute('aria-valuenow');
                var max = bars[i].getAttribute('aria-valuemax');
                if (now !== null && max !== null && parseInt(max) > 0) {
                    r.messagesUsed  = parseInt(now);
                    r.messagesLimit = parseInt(max);
                    break;
                }
            }
        }

        // ── Generic "X / Y" fallback — take the pair with the largest limit
        if (r.messagesLimit <= 0) {
            var allPairs = [];
            var re = /(\\d+)\\s*(?:of|\\/|out of)\\s*(\\d+)/gi, m;
            while ((m = re.exec(body)) !== null) {
                var u = parseInt(m[1]), l = parseInt(m[2]);
                if (l > 0 && u <= l) allPairs.push([u, l]);
            }
            if (allPairs.length > 0) {
                allPairs.sort((a,b) => b[1]-a[1]);   // largest limit first
                r.messagesUsed  = allPairs[0][0];
                r.messagesLimit = allPairs[0][1];
            }
        }

        // ── Progressbars: classify by row label, not by index ──────────────
        // The page now includes a "Usage credits" section with its own bars,
        // and the model-scoped row is named after the model ("Fable", "Sonnet"…),
        // so positional mapping mis-assigns rows.
        var bars = Array.from(document.querySelectorAll('[role="progressbar"]'));
        // [A-Za-z]+ (not \\w+): row text has no space before the percent
        // ("…30 min17% used"), \\w+ would swallow the digits.
        var resetRe = /Resets\\s+(in\\s+\\d+\\s+[A-Za-z]+(?:\\s+\\d+\\s+[A-Za-z]+)?|(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[A-Za-z]*\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM))/;
        var rows = [];
        for (var bi = 0; bi < bars.length; bi++) {
            var now = parseInt(bars[bi].getAttribute('aria-valuenow') || '-1');
            var max = parseInt(bars[bi].getAttribute('aria-valuemax') || '-1');
            if (max <= 0 || now < 0) continue;
            // Climb to the row container: the SMALLEST ancestor whose text
            // includes the "Resets …" label — climbing further reaches the
            // whole section ("Weekly limits … All models … Fable …") and
            // classification would hit the wrong keyword.
            var node = bars[bi], label = '', fallback = '';
            for (var depth = 0; depth < 6 && node.parentElement; depth++) {
                node = node.parentElement;
                var t = (node.textContent || '').replace(/\\s+/g, ' ').trim();
                if (t.length === 0) continue;
                if (t.length >= 220) break;
                fallback = t;
                if (/Resets/i.test(t)) { label = t; break; }
            }
            rows.push({ used: now, limit: max, label: label || fallback });
        }

        var claimed = { session: false, weekly: false, sonnet: false, design: false };
        for (var ri = 0; ri < rows.length; ri++) {
            var lab = rows[ri].label;
            if (/[$]|credit/i.test(lab)) continue;   // "Usage credits" section
            var rm = lab.match(resetRe);
            var resetStr = rm ? rm[1].trim() : '';
            if (!claimed.session && /current\\s+session/i.test(lab)) {
                r.sessionUsed = rows[ri].used; r.sessionLimit = rows[ri].limit;
                if (resetStr) r.sessionResetStr = resetStr;
                claimed.session = true;
            } else if (!claimed.weekly && /all\\s+models/i.test(lab)) {
                r.messagesUsed = rows[ri].used; r.messagesLimit = rows[ri].limit;
                if (resetStr) r.weeklyResetStr = resetStr;
                claimed.weekly = true;
            } else if (!claimed.design && /design/i.test(lab)) {
                r.designUsed = rows[ri].used; r.designLimit = rows[ri].limit;
                if (resetStr) r.designResetStr = resetStr;
                claimed.design = true;
            } else if (!claimed.sonnet && lab.length > 0) {
                // Model-scoped weekly row — titled with the model name
                r.sonnetUsed = rows[ri].used; r.sonnetLimit = rows[ri].limit;
                if (resetStr) r.sonnetResetStr = resetStr;
                var name = lab.split(/Resets/i)[0].replace(/\\d+%\\s*used/ig, '').trim();
                if (name && name.length <= 40) r.sonnetTitle = name;
                claimed.sonnet = true;
            }
        }

        // Positional fallback if labels matched nothing (markup change)
        if (!claimed.session && !claimed.weekly) {
            if (rows.length >= 2) {
                r.sessionUsed  = rows[0].used;  r.sessionLimit  = rows[0].limit;
                r.messagesUsed = rows[1].used;  r.messagesLimit = rows[1].limit;
            } else if (rows.length === 1) {
                r.messagesUsed = rows[0].used;  r.messagesLimit = rows[0].limit;
            }
        }

        // Reset labels fallback: fill only fields the row parsing left empty.
        // Format 1: "Resets in 3 hr 58 min" (relative)
        // Format 2: "Resets Wed 10:59 AM" (absolute day+time)
        var allResets = Array.from(body.matchAll(/Resets\\s+(in\\s+\\d+\\s+[A-Za-z]+(?:\\s+\\d+\\s+[A-Za-z]+)?|(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[A-Za-z]*\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM))/g));
        if (!r.sessionResetStr && allResets.length > 0) r.sessionResetStr = allResets[0][1].trim();
        if (!r.weeklyResetStr  && allResets.length > 1) r.weeklyResetStr  = allResets[1][1].trim();
        if (!r.sonnetResetStr  && allResets.length > 2) r.sonnetResetStr  = allResets[2][1].trim();
        if (!r.designResetStr  && allResets.length > 3) r.designResetStr  = allResets[3][1].trim();

        // Fallback reset date: "Resets on December 25"
        var rd = body.match(/resets?\\s+(?:on\\s+)?([A-Z][a-z]+\\s+\\d{1,2}(?:,?\\s*\\d{4})?)/i);
        if (rd) r.resetDateStr = rd[1].trim();

        if (/rate\\s+limit(?:ed)?/i.test(body)) r.rateLimitStatus = 'Limited';


    } catch(e) { r.error = e.toString(); }
    return JSON.stringify(r);
})();
"""

// ─────────────────────────────────────────────────────────────────────────────
// Extracts email from /settings/account page
// ─────────────────────────────────────────────────────────────────────────────
private let kEmailClickJS = """
(function() {
    var btn = document.querySelector('[data-testid="user-menu-button"]');
    if (!btn) return 'no-button';
    // Dispatch pointer/mouse events to trigger React handlers
    var events = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
    for (var i = 0; i < events.length; i++) {
        btn.dispatchEvent(new PointerEvent(events[i], {bubbles: true, cancelable: true, view: window}));
    }
    return 'clicked';
})();
"""

private let kEmailReadJS = """
(function() {
    var els = document.querySelectorAll('*');
    for (var i = 0; i < els.length; i++) {
        if (els[i].children.length === 0 && els[i].innerHTML) {
            var m = els[i].innerHTML.match(/[\\w.+-]+@[\\w.-]+\\.[a-z]{2,}/);
            if (m) return m[0];
        }
    }
    return '';
})();
"""

private let kEmailCloseJS = """
(function() {
    var btn = document.querySelector('[data-testid="user-menu-button"]');
    if (!btn) return;
    var events = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
    for (var i = 0; i < events.length; i++) {
        btn.dispatchEvent(new PointerEvent(events[i], {bubbles: true, cancelable: true, view: window}));
    }
})();
"""

// ─────────────────────────────────────────────────────────────────────────────
class UsageDataProvider: NSObject, ObservableObject {
    static let instance = UsageDataProvider()

    @Published var currentSnapshot: QuotaSnapshot?
    @Published var isFetching   = false
    @Published var requiresAuth = false
    @Published var fetchError: String?
    @Published var cliAvailable = false
    @Published var pollingIntervalLabel: String = ""

    var onAuthCompleted: (() -> Void)?

    enum DataSourceType: Equatable {
        case cliAPI
        case webView
    }

    private enum DataSource {
        case cliAPI(accessToken: String, planName: String)
        case webView
    }

    private var activeDataSource: DataSource?

    /// Current data source type for UI decisions (e.g. polling interval choices).
    var activeDataSourceType: DataSourceType? {
        switch activeDataSource {
        case .cliAPI: return .cliAPI
        case .webView: return .webView
        case .none: return nil
        }
    }
    private var dataWebView: WKWebView!
    private(set) var authWebView: WKWebView?
    private var authURLObservation: NSKeyValueObservation?
    private var fetchTimeoutWork: DispatchWorkItem?

    private let targetURL = URL(string: "https://claude.ai/settings/usage")!

    private override init() {
        super.init()
        configureDataWebView()
    }
    
    // MARK: - Setup
    
    private func configureDataWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        // Interceptor runs before any page JS
        let hookScript = WKUserScript(source: kInterceptorScript,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
        config.userContentController.addUserScript(hookScript)
        config.userContentController.add(self, name: "usageHandler")
        
        dataWebView = WKWebView(frame: .zero, configuration: config)
        dataWebView.navigationDelegate = self
        dataWebView.customUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    }
    
    // MARK: - Public API
    
    func performInitialFetch() {
        let didLogOut = UserDefaults.standard.bool(forKey: "didExplicitlyLogOut")
        let lastSource = UserDefaults.standard.string(forKey: "lastAuthSource")

        // Skip CLI auto-login if user explicitly logged out or last session was browser
        if didLogOut || lastSource == "webView" {
            activeDataSource = .webView
            // Still check CLI availability for the sign-in UI (async, won't block)
            refreshCLIAvailability()
            performWebViewFetch()
            return
        }

        // Show cached data immediately while credentials are read in background
        if let cached = loadCLICache() {
            currentSnapshot = cached
        }

        isFetching = true

        // Read credentials off the main thread — Process.waitUntilExit() blocks
        Task.detached(priority: .userInitiated) {
            let json = try? CLICredentialsReader.shared.readCredentials()
            let token = json.flatMap { CLICredentialsReader.shared.extractAccessToken(from: $0) }
            let expired = json.map { CLICredentialsReader.shared.isTokenExpired($0) } ?? true

            await MainActor.run {
                guard let json, let token, !expired else {
                    self.cliAvailable = false
                    self.isFetching = false
                    self.activeDataSource = .webView
                    self.performWebViewFetch()
                    return
                }

                // Validate token with API
                Task {
                    let valid = await ClaudeUsageFetcher.shared.validateToken(accessToken: token)
                    await MainActor.run {
                        self.cliAvailable = valid
                        if valid {
                            let plan = CLICredentialsReader.shared.extractSubscriptionType(from: json)?.capitalized ?? "Pro"
                            self.activeDataSource = .cliAPI(accessToken: token, planName: plan)
                            UserDefaults.standard.set("cliAPI", forKey: "lastAuthSource")
                            NSLog("[ClaudePulse] CLI token validated, fetching via API")
                            Task { await self.fetchUsageViaCLI(accessToken: token, planName: plan) }
                        } else {
                            NSLog("[ClaudePulse] CLI token invalid, falling back to WebView")
                            self.isFetching = false
                            self.activeDataSource = .webView
                            self.performWebViewFetch()
                        }
                    }
                }
            }
        }
    }

    /// Minimum interval between CLI API calls to avoid rate limiting.
    private static let cliMinInterval: TimeInterval = 300
    private var lastCLIFetchDate: Date?
    private var credentialsWatchTimer: Timer?
    private var lastKnownAccessToken: String?
    private var cliBackoffSeconds: TimeInterval = 0
    private static let cliBackoffSteps: [TimeInterval] = [300, 600, 900] // 5m, 10m, 15m
    /// Last values from oauth/usage — the only source of sonnet/design data.
    /// Carried into messages-header results while their reset time is still in the future.
    private var lastSonnetPercentage: Double = 0
    private var lastSonnetResetTime: Date?
    private var lastSonnetDisplayName: String?
    private var lastDesignPercentage: Double = 0
    private var lastDesignResetTime: Date?
    private var lastDesignDisplayName: String?
    private var oauthCooldownUntil: Date?
    private var oauthCooldownStep = 0
    private static let oauthCooldownSteps: [TimeInterval] = [900, 1800, 2700, 3600] // 15m, 30m, 45m, 60m

    /// - Parameter manualRefresh: true when triggered by user action (popover open, refresh button).
    ///   Manual refreshes skip the polling throttle.
    func reloadData(manualRefresh: Bool = false) {
        guard !isFetching, !requiresAuth else { return }

        switch activeDataSource {
        case .cliAPI(_, let plan):
            // Automatic polling respects throttle; manual refresh skips it
            if !manualRefresh {
                let minWait = max(Self.cliMinInterval, cliBackoffSeconds)
                if let last = lastCLIFetchDate,
                   Date().timeIntervalSince(last) < minWait {
                    return
                }
            }
            isFetching = true
            let fallbackPlan = plan
            // Re-read token off main thread
            Task.detached(priority: .userInitiated) {
                let json = try? CLICredentialsReader.shared.readCredentials()
                let freshToken = json.flatMap { CLICredentialsReader.shared.extractAccessToken(from: $0) }
                let expired = json.map { CLICredentialsReader.shared.isTokenExpired($0) } ?? false
                let freshPlan = json.flatMap { CLICredentialsReader.shared.extractSubscriptionType(from: $0)?.capitalized } ?? fallbackPlan

                await MainActor.run {
                    guard let freshToken else {
                        self.isFetching = false
                        return
                    }
                    guard !expired else {
                        // Don't burn a request on a token the API will reject.
                        // Claude Code refreshes it on its next run — watch for that.
                        self.isFetching = false
                        self.handleStaleToken()
                        return
                    }
                    self.activeDataSource = .cliAPI(accessToken: freshToken, planName: freshPlan)
                    self.lastCLIFetchDate = Date()
                    Task { await self.fetchUsageViaCLI(accessToken: freshToken, planName: freshPlan) }
                }
            }
        case .webView, .none:
            isFetching = true
            scheduleFetchTimeout()
            dataWebView.load(URLRequest(url: targetURL))
        }
    }

    // MARK: - Public sign-in methods

    /// Sign in using Claude Code CLI credentials with server-side validation.
    func signInViaCLI() {
        UserDefaults.standard.set(false, forKey: "didExplicitlyLogOut")
        UserDefaults.standard.set("cliAPI", forKey: "lastAuthSource")
        isFetching = true

        Task.detached(priority: .userInitiated) {
            let json = try? CLICredentialsReader.shared.readCredentials()
            let token = json.flatMap { CLICredentialsReader.shared.extractAccessToken(from: $0) }
            let expired = json.map { CLICredentialsReader.shared.isTokenExpired($0) } ?? true

            await MainActor.run {
                guard let json, let token, !expired else {
                    self.isFetching = false
                    self.fetchError = "Could not read CLI credentials. Run `claude login` first."
                    return
                }

                Task {
                    let valid = await ClaudeUsageFetcher.shared.validateToken(accessToken: token)
                    await MainActor.run {
                        if valid {
                            let plan = CLICredentialsReader.shared.extractSubscriptionType(from: json)?.capitalized ?? "Pro"
                            self.activeDataSource = .cliAPI(accessToken: token, planName: plan)
                            Task { await self.fetchUsageViaCLI(accessToken: token, planName: plan) }
                        } else {
                            self.isFetching = false
                            self.cliAvailable = false
                            self.fetchError = "CLI token is no longer valid. Run `claude login` to refresh."
                        }
                    }
                }
            }
        }
    }

    /// Sign in via browser (WebView). Call this then present the auth window.
    func signInViaWebView() {
        UserDefaults.standard.set(false, forKey: "didExplicitlyLogOut")
        UserDefaults.standard.set("webView", forKey: "lastAuthSource")
        activeDataSource = .webView
    }

    /// Log out — clears data, resets auth state, prevents CLI auto-login on next start.
    func logOut() {
        activeDataSource = nil
        currentSnapshot = nil
        requiresAuth = true
        isFetching = false
        cancelFetchTimeout()
        stopCredentialsWatcher()
        cliBackoffSeconds = 0
        lastCLIFetchDate = nil
        oauthCooldownStep = 0
        oauthCooldownUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.cliCacheKey)
        UserDefaults.standard.removeObject(forKey: "lastAuthSource")
        UserDefaults.standard.set(true, forKey: "didExplicitlyLogOut")
    }

    /// Checks if CLI credentials exist locally (no API call — fast, safe for UI).
    func refreshCLIAvailability() {
        Task.detached(priority: .utility) {
            let json = try? CLICredentialsReader.shared.readCredentials()
            let hasValid = json.flatMap { CLICredentialsReader.shared.extractAccessToken(from: $0) } != nil
                && !(json.map { CLICredentialsReader.shared.isTokenExpired($0) } ?? true)
            await MainActor.run { self.cliAvailable = hasValid }
        }
    }

    // MARK: - CLI API

    private func fetchUsageViaCLI(accessToken: String, planName: String) async {
        // oauth/usage is authoritative (and free) — always prefer it.
        // /v1/messages costs a real message and starts a 5h window, so it is
        // only a fallback while oauth/usage is on 429 cooldown.
        var endpoint: ClaudeUsageFetcher.Endpoint = .oauthUsage
        let cooldown: Date? = await MainActor.run { self.oauthCooldownUntil }
        if let cd = cooldown, Date() < cd {
            endpoint = .messagesHeaders
        }

        NSLog("[ClaudePulse] Fetching via %@", endpoint == .oauthUsage ? "oauth/usage" : "messages headers")

        do {
            var usage = try await ClaudeUsageFetcher.shared.fetchUsage(accessToken: accessToken, endpoint: endpoint)

            await MainActor.run {
                if endpoint == .oauthUsage {
                    // Remember sonnet/design — the messages fallback can't provide them
                    self.lastSonnetPercentage = usage.sonnetPercentage
                    self.lastSonnetResetTime = usage.sonnetResetTime
                    self.lastSonnetDisplayName = usage.sonnetDisplayName
                    self.lastDesignPercentage = usage.designPercentage
                    self.lastDesignResetTime = usage.designResetTime
                    self.lastDesignDisplayName = usage.designDisplayName
                    self.oauthCooldownStep = 0
                    self.oauthCooldownUntil = nil
                } else {
                    // Carry sonnet/design from the last oauth response, but only
                    // while their reset time is still in the future — carrying
                    // past-reset values is how quotas got frozen at stale highs.
                    if let reset = self.lastSonnetResetTime, reset > Date() {
                        usage.sonnetPercentage = self.lastSonnetPercentage
                        usage.sonnetResetTime = reset
                        usage.sonnetDisplayName = self.lastSonnetDisplayName
                    }
                    if let reset = self.lastDesignResetTime, reset > Date() {
                        usage.designPercentage = self.lastDesignPercentage
                        usage.designResetTime = reset
                        usage.designDisplayName = self.lastDesignDisplayName
                    }
                }

                self.currentSnapshot = self.convertToSnapshot(usage: usage, planName: planName)
                self.isFetching = false
                self.requiresAuth = false
                self.fetchError = nil
                self.cliBackoffSeconds = 0
                self.stopCredentialsWatcher()
                self.saveCLICache(usage: usage, planName: planName)
            }
        } catch let error as UsageFetchError {
            if case .rateLimited = error {
                if endpoint == .oauthUsage {
                    // oauth/usage hit 429 — progressive cooldown, immediately try messages
                    await MainActor.run {
                        let step = min(self.oauthCooldownStep, Self.oauthCooldownSteps.count - 1)
                        let cooldown = Self.oauthCooldownSteps[step]
                        self.oauthCooldownUntil = Date().addingTimeInterval(cooldown)
                        self.oauthCooldownStep += 1
                        NSLog("[ClaudePulse] oauth/usage rate limited, cooldown %.0fm, falling back to messages", cooldown / 60)
                    }
                    await fetchUsageViaCLI(accessToken: accessToken, planName: planName)
                } else {
                    // Both endpoints exhausted — backoff
                    await MainActor.run {
                        self.isFetching = false
                        let stepIndex = Self.cliBackoffSteps.firstIndex(where: { $0 > self.cliBackoffSeconds }) ?? (Self.cliBackoffSteps.count - 1)
                        self.cliBackoffSeconds = Self.cliBackoffSteps[stepIndex]
                        self.lastCLIFetchDate = Date()
                        NSLog("[ClaudePulse] Both endpoints rate limited, next retry in %.0fs", self.cliBackoffSeconds)
                        self.startCredentialsWatcher()
                    }
                }
            } else if case .httpError(let code) = error, code == 401 || code == 403 {
                // Token rejected (typically expired after sleep) — wait for
                // Claude Code to refresh it instead of failing silently forever.
                NSLog("[ClaudePulse] CLI API auth error %d — waiting for token refresh", code)
                await MainActor.run {
                    self.isFetching = false
                    self.handleStaleToken()
                }
            } else {
                NSLog("[ClaudePulse] CLI API fetch failed: %@", error.localizedDescription)
                await MainActor.run {
                    self.isFetching = false
                    self.fetchError = error.localizedDescription
                }
            }
        } catch {
            NSLog("[ClaudePulse] CLI API fetch failed: %@", error.localizedDescription)
            await MainActor.run {
                self.isFetching = false
                self.fetchError = error.localizedDescription
            }
        }
    }

    /// Token is expired or rejected — surface a clear hint and watch for
    /// Claude Code rewriting the credentials (file or Keychain).
    private func handleStaleToken() {
        fetchError = "Claude Code session expired. It refreshes automatically the next time you use Claude Code."
        startCredentialsWatcher()
    }

    // MARK: - Credentials watcher

    /// Watches for Claude Code refreshing its OAuth token. Compares the token
    /// value itself via CLICredentialsReader, which covers both storage
    /// locations (~/.claude/.credentials.json and the macOS Keychain — newer
    /// Claude Code versions use only the Keychain, so file mtime is not enough).
    private func startCredentialsWatcher() {
        guard credentialsWatchTimer == nil else { return }
        NSLog("[ClaudePulse] Started credentials watcher")

        // Capture the current token as the baseline (off main — Keychain read spawns a subprocess)
        Task.detached(priority: .utility) {
            let json = try? CLICredentialsReader.shared.readCredentials()
            let token = json.flatMap { CLICredentialsReader.shared.extractAccessToken(from: $0) }
            await MainActor.run { self.lastKnownAccessToken = token }
        }

        credentialsWatchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task.detached(priority: .utility) {
                guard let json = try? CLICredentialsReader.shared.readCredentials(),
                      let token = CLICredentialsReader.shared.extractAccessToken(from: json),
                      !CLICredentialsReader.shared.isTokenExpired(json) else { return }
                let plan = CLICredentialsReader.shared.extractSubscriptionType(from: json)?.capitalized ?? "Pro"

                await MainActor.run {
                    guard token != self.lastKnownAccessToken else { return }
                    NSLog("[ClaudePulse] Credentials changed — token refreshed, retrying")
                    self.lastKnownAccessToken = token
                    self.cliBackoffSeconds = 0
                    self.lastCLIFetchDate = nil
                    self.fetchError = nil
                    self.stopCredentialsWatcher()
                    self.activeDataSource = .cliAPI(accessToken: token, planName: plan)
                    self.isFetching = true
                    Task { await self.fetchUsageViaCLI(accessToken: token, planName: plan) }
                }
            }
        }
    }

    private func stopCredentialsWatcher() {
        credentialsWatchTimer?.invalidate()
        credentialsWatchTimer = nil
    }

    // MARK: - CLI response cache

    private static let cliCacheKey = "cliUsageCache"

    private func saveCLICache(usage: ClaudeUsage, planName: String) {
        let cache: [String: Any] = [
            "sessionPercentage": usage.sessionPercentage,
            "sessionResetTime": usage.sessionResetTime.timeIntervalSince1970,
            "weeklyPercentage": usage.weeklyPercentage,
            "weeklyResetTime": usage.weeklyResetTime.timeIntervalSince1970,
            "sonnetPercentage": usage.sonnetPercentage,
            "sonnetResetTime": usage.sonnetResetTime?.timeIntervalSince1970 ?? 0,
            "sonnetDisplayName": usage.sonnetDisplayName ?? "",
            "designPercentage": usage.designPercentage,
            "designResetTime": usage.designResetTime?.timeIntervalSince1970 ?? 0,
            "designDisplayName": usage.designDisplayName ?? "",
            "planName": planName,
            "savedAt": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(cache, forKey: Self.cliCacheKey)
    }

    /// Loads cached CLI usage if available and less than 1 hour old.
    func loadCLICache() -> QuotaSnapshot? {
        guard let cache = UserDefaults.standard.dictionary(forKey: Self.cliCacheKey),
              let savedAt = cache["savedAt"] as? TimeInterval,
              Date().timeIntervalSince1970 - savedAt < 3600 // 1 hour max
        else { return nil }

        let usage = ClaudeUsage(
            sessionPercentage: cache["sessionPercentage"] as? Double ?? 0,
            sessionResetTime: Date(timeIntervalSince1970: cache["sessionResetTime"] as? TimeInterval ?? 0),
            weeklyPercentage: cache["weeklyPercentage"] as? Double ?? 0,
            weeklyResetTime: Date(timeIntervalSince1970: cache["weeklyResetTime"] as? TimeInterval ?? 0),
            sonnetPercentage: cache["sonnetPercentage"] as? Double ?? 0,
            sonnetResetTime: {
                let ts = cache["sonnetResetTime"] as? TimeInterval ?? 0
                return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            }(),
            sonnetDisplayName: (cache["sonnetDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            designPercentage: cache["designPercentage"] as? Double ?? 0,
            designResetTime: {
                let ts = cache["designResetTime"] as? TimeInterval ?? 0
                return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            }(),
            designDisplayName: (cache["designDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            lastUpdated: Date(timeIntervalSince1970: savedAt)
        )
        let planName = cache["planName"] as? String ?? "Pro"
        return convertToSnapshot(usage: usage, planName: planName)
    }

    private func performWebViewFetch() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let hasClaude = cookies.contains { $0.domain.contains("claude") }
            DispatchQueue.main.async {
                if hasClaude {
                    self.isFetching = true
                    self.scheduleFetchTimeout()
                    self.dataWebView.load(URLRequest(url: self.targetURL))
                } else {
                    self.requiresAuth = true
                }
            }
        }
    }

    private func convertToSnapshot(usage: ClaudeUsage, planName: String) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(
            planName: planName,
            periodConsumed: Int(usage.effectiveWeeklyPercentage.rounded()),
            periodCapacity: 100,
            windowResetDate: usage.sessionResetTime,
            throttleStatus: "Normal",
            refreshedAt: Date()
        )
        snapshot.windowConsumed = Int(usage.effectiveSessionPercentage.rounded())
        snapshot.windowCapacity = 100
        snapshot.periodResetDate = usage.weeklyResetTime
        if usage.effectiveSonnetPercentage > 0 || usage.sonnetResetTime.map({ $0 > Date() }) == true {
            snapshot.sonnetConsumed = Int(usage.effectiveSonnetPercentage.rounded())
            snapshot.sonnetCapacity = 100
            snapshot.sonnetResetDate = usage.sonnetResetTime
            if let name = usage.sonnetDisplayName, !name.isEmpty {
                snapshot.sonnetTitle = name
            }
        }
        if usage.effectiveDesignPercentage > 0 || usage.designResetTime.map({ $0 > Date() }) == true {
            snapshot.designConsumed = Int(usage.effectiveDesignPercentage.rounded())
            snapshot.designCapacity = 100
            snapshot.designResetDate = usage.designResetTime
            if let name = usage.designDisplayName, !name.isEmpty {
                snapshot.designTitle = name
            }
        }
        if let email = CLICredentialsReader.shared.readEmail() {
            snapshot.userEmail = email
        }
        return snapshot
    }

    /// Resets `isFetching` and retries once if no response arrives within 15 seconds.
    private var fetchRetryCount = 0

    private func scheduleFetchTimeout() {
        fetchTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isFetching else { return }
            self.dataWebView.stopLoading()
            self.isFetching = false

            if self.fetchRetryCount < 2 {
                self.fetchRetryCount += 1
                NSLog("[ClaudePulse] Fetch timeout — retry %d", self.fetchRetryCount)
                self.isFetching = true
                self.dataWebView.load(URLRequest(url: self.targetURL))
                self.scheduleFetchTimeout()
            } else {
                NSLog("[ClaudePulse] Fetch timeout — giving up after retries")
                self.fetchRetryCount = 0
                self.fetchError = "Could not load usage data. Try refreshing manually."
            }
        }
        fetchTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func cancelFetchTimeout() {
        fetchTimeoutWork?.cancel()
        fetchTimeoutWork = nil
        fetchRetryCount = 0
    }
    
    func buildAuthWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = dataWebView.customUserAgent
        authWebView = wv

        // Observe URL changes via KVO — catches client-side navigation (React router)
        authURLObservation = wv.observe(\.url, options: .new) { [weak self] webView, _ in
            guard let self, let url = webView.url?.absoluteString else { return }
            if !url.contains("/login") && !url.contains("/auth") && url.contains("claude.ai") {
                self.authURLObservation = nil
                DispatchQueue.main.async { self.onAuthCompleted?() }
            }
        }

        wv.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        return wv
    }
    
    // MARK: - Email extraction

    private func fetchEmailIfNeeded() {
        guard currentSnapshot?.userEmail.isEmpty ?? true else { return }

        // Step 1: Click the user menu button to open popup
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.dataWebView.evaluateJavaScript(kEmailClickJS) { _, _ in
                // Step 2: Try reading email with retries
                self.readEmailWithRetry(attemptsLeft: 5)
            }
        }
    }

    private func readEmailWithRetry(attemptsLeft: Int) {
        guard attemptsLeft > 0 else {
            dataWebView.evaluateJavaScript(kEmailCloseJS) { _, _ in }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.dataWebView.evaluateJavaScript(kEmailReadJS) { result, _ in
                let email = result as? String ?? ""
                if !email.isEmpty {
                    self.dataWebView.evaluateJavaScript(kEmailCloseJS) { _, _ in
                        DispatchQueue.main.async {
                            self.currentSnapshot?.userEmail = email
                        }
                    }
                } else {
                    self.readEmailWithRetry(attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    // MARK: - DOM extraction (fallback)

    // Cumulative seconds from didFinish. Cold-start React renders progressbars
    // late; we probe repeatedly until we see data instead of giving up at 5 s.
    // Final delay stays under the 15 s scheduleFetchTimeout safety net.
    private static let domParseDelays: [TimeInterval] = [2.5, 4.5, 7.0, 10.0, 13.5]

    private func executeDOMParsing() {
        scheduleDOMParseAttempt(index: 0)
    }

    private func scheduleDOMParseAttempt(index: Int) {
        let delays = Self.domParseDelays
        guard index < delays.count else { return }
        let isFinal = (index == delays.count - 1)
        let wait = index == 0 ? delays[0] : delays[index] - delays[index - 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.attemptDOMParse(isFinal: isFinal) { foundData in
                guard !foundData, !isFinal else { return }
                self?.scheduleDOMParseAttempt(index: index + 1)
            }
        }
    }

    private func attemptDOMParse(isFinal: Bool, completion: @escaping (Bool) -> Void) {
        dataWebView.evaluateJavaScript(kDOMParserScript) { [weak self] result, error in
            guard let self else { completion(false); return }
            guard let s = result as? String,
                  let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else {
                NSLog("[ClaudePulse] DOM parsing failed: %@", error?.localizedDescription ?? "nil result")
                if isFinal {
                    DispatchQueue.main.async {
                        self.isFetching = false
                        self.cancelFetchTimeout()
                    }
                }
                completion(false)
                return
            }

            // Auth required — stop retrying, hand off to the existing flow.
            if j["needsLogin"] as? Bool == true {
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.cancelFetchTimeout()
                    self.processDOMPayload(j)
                }
                completion(true)
                return
            }

            let hasData = Self.domPayloadHasData(j)
            if hasData || isFinal {
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.cancelFetchTimeout()
                    self.processDOMPayload(j)
                }
            }
            completion(hasData)
        }
    }

    private static func domPayloadHasData(_ j: [String: Any]) -> Bool {
        let keys = ["messagesLimit", "sessionLimit", "sonnetLimit", "designLimit"]
        for k in keys {
            if let v = j[k] as? Int, v > 0 { return true }
        }
        return false
    }
    
    // MARK: - Parsing
    
    /// Called from the fetch/XHR interceptor via message handler.
    private func processAPIPayload(_ json: [String: Any]) {
        
        // ── Try to find session/window usage counts
        let candidates: [(used: Any?, limit: Any?, reset: Any?)] = [
            (json["messages_used"],   json["messages_limit"],   json["reset_at"]),
            (json["usage_count"],     json["usage_limit"],      json["resets_at"]),
            (json["count"],           json["limit"],            json["reset_time"]),
        ]
        
        // Also look one level deep
        var nested: [String: Any] = [:]
        for (_, v) in json {
            if let sub = v as? [String: Any] {
                nested.merge(sub) { a, _ in a }
                if let arr = v as? [[String: Any]], let first = arr.first {
                    nested.merge(first) { a, _ in a }
                }
            }
        }
        let nestedCandidates: [(used: Any?, limit: Any?, reset: Any?)] = [
            (nested["messages_used"],  nested["messages_limit"],  nested["reset_at"]),
            (nested["messages_used"],  nested["messages_limit"],  nested["resets_at"]),
            (nested["used"],           nested["limit"],           nested["reset_at"]),
            (nested["used"],           nested["limit"],           nested["resets_at"]),
            (nested["count"],          nested["limit"],           nested["reset_time"]),
        ]
        
        for c in (candidates + nestedCandidates) {
            let used  = extractInt(c.used)
            let limit = extractInt(c.limit)
            guard let u = used, let l = limit, l > 0, u <= l else { continue }
            
            let parsedReset = parseTimestamp(c.reset)
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // API interceptor fires before DOM extraction (which waits 2.5 s).
                // API responses contain the current rate-limit window → session fields.
                var snapshot = self.currentSnapshot ?? QuotaSnapshot(
                    planName: "Unknown", periodConsumed: u, periodCapacity: l,
                    windowResetDate: parsedReset, throttleStatus: "Normal", refreshedAt: Date()
                )
                snapshot.windowConsumed  = u
                snapshot.windowCapacity  = l
                // Only accept windowResetDate as session reset if it's in the future
                // AND within 6 hours — anything longer is a billing/subscription reset,
                // not the rate-limit window (Claude's session window is max 5h).
                if let rd = parsedReset, rd > Date(),
                   rd.timeIntervalSince(Date()) <= 6 * 3600 {
                    snapshot.windowResetDate = rd
                }
                snapshot.refreshedAt    = Date()
                self.currentSnapshot  = snapshot
                self.isFetching       = false
                self.cancelFetchTimeout()
                self.requiresAuth     = false
            }
            return
        }
    }
    
    private func processDOMPayload(_ j: [String: Any]) {
        if j["needsLogin"] as? Bool == true { requiresAuth = true; currentSnapshot = nil; return }
        
        let planName         = j["planType"]        as? String ?? "Unknown"
        let periodConsumed   = j["messagesUsed"]    as? Int    ?? 0
        let periodCapacity   = j["messagesLimit"]   as? Int    ?? 0
        let windowConsumed   = j["sessionUsed"]     as? Int    ?? 0
        let windowCapacity   = j["sessionLimit"]    as? Int    ?? 0
        let sonnetConsumed   = j["sonnetUsed"]      as? Int    ?? 0
        let sonnetCapacity   = j["sonnetLimit"]     as? Int    ?? 0
        let designConsumed   = j["designUsed"]      as? Int    ?? 0
        let designCapacity   = j["designLimit"]     as? Int    ?? 0
        let throttleStatus   = j["rateLimitStatus"]  as? String ?? "Normal"
        let resetDateStr     = j["resetDateStr"]     as? String ?? ""
        let sessionResetStr  = j["sessionResetStr"]  as? String ?? ""
        let weeklyResetStr   = j["weeklyResetStr"]   as? String ?? ""
        let sonnetResetStr   = j["sonnetResetStr"]   as? String ?? ""
        let designResetStr   = j["designResetStr"]   as? String ?? ""
        let userEmail        = j["userEmail"]         as? String ?? ""

        var windowResetDate: Date?
        var periodResetDate: Date?
        var sonnetResetDate: Date?
        var designResetDate: Date?
        
        // 1. Absolute date string: "resets on December 25" → billing-period / weekly reset
        if !resetDateStr.isEmpty {
            let fmts = ["MMMM d, yyyy", "MMMM d", "MMM d, yyyy", "MMM d"]
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
            for fmt in fmts {
                df.dateFormat = fmt
                if let d = df.date(from: resetDateStr) {
                    let comps = Calendar.current.dateComponents([.month, .day], from: d)
                    periodResetDate = Calendar.current.nextDate(
                        after: Date(), matching: comps,
                        matchingPolicy: .nextTimePreservingSmallerComponents) ?? d
                    break
                }
            }
        }
        
        // 2. Parse reset strings — each can be relative ("2 hr 30 min") or absolute ("Fri 10:00 AM")
        if !sessionResetStr.isEmpty {
            windowResetDate = resolveRelativeInterval(sessionResetStr)
        }

        if !weeklyResetStr.isEmpty && periodResetDate == nil {
            periodResetDate = resolveRelativeInterval(weeklyResetStr)
        }

        if !sonnetResetStr.isEmpty {
            sonnetResetDate = resolveRelativeInterval(sonnetResetStr)
        }

        if !designResetStr.isEmpty {
            designResetDate = resolveRelativeInterval(designResetStr)
        }
        
        _ = j["rawText"]
        
        var snapshot = currentSnapshot ?? QuotaSnapshot(
            planName: planName, periodConsumed: periodConsumed, periodCapacity: periodCapacity,
            windowResetDate: windowResetDate, throttleStatus: throttleStatus, refreshedAt: Date()
        )
        if snapshot.planName == "Unknown" || snapshot.planName.isEmpty { snapshot.planName = planName }
        if periodCapacity > 0 {
            snapshot.periodConsumed  = periodConsumed
            snapshot.periodCapacity  = periodCapacity
        }
        // First progressbar = current session window; second = billing period.
        // Only write if DOM found two bars (windowCapacity > 0).
        if windowCapacity > 0 {
            snapshot.windowConsumed  = windowConsumed
            snapshot.windowCapacity  = windowCapacity
        }
        if sonnetCapacity > 0 {
            snapshot.sonnetConsumed = sonnetConsumed
            snapshot.sonnetCapacity = sonnetCapacity
            if let title = j["sonnetTitle"] as? String, !title.isEmpty {
                snapshot.sonnetTitle = title
            }
        }
        if designCapacity > 0 {
            snapshot.designConsumed = designConsumed
            snapshot.designCapacity = designCapacity
            if let title = j["designTitle"] as? String, !title.isEmpty {
                snapshot.designTitle = title
            }
        }
        if let rd = windowResetDate { snapshot.windowResetDate = rd }
        if let wd = periodResetDate { snapshot.periodResetDate = wd; snapshot.periodResetText = "" }
        if let sd = sonnetResetDate { snapshot.sonnetResetDate = sd; snapshot.sonnetResetText = "" }
        if let dd = designResetDate { snapshot.designResetDate = dd; snapshot.designResetText = "" }
        // Store raw text for absolute day+time formats (e.g. "Fri 10:00 AM")
        // These couldn't be parsed to Date by resolveRelativeInterval
        let isAbsolute = { (s: String) -> Bool in s.range(of: #"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"#, options: .regularExpression) != nil }
        if !sessionResetStr.isEmpty && windowResetDate == nil && isAbsolute(sessionResetStr) {
            snapshot.windowResetText = sessionResetStr
        }
        if !weeklyResetStr.isEmpty && isAbsolute(weeklyResetStr) { snapshot.periodResetText = weeklyResetStr }
        if !sonnetResetStr.isEmpty && isAbsolute(sonnetResetStr) { snapshot.sonnetResetText = sonnetResetStr }
        if !designResetStr.isEmpty && isAbsolute(designResetStr) { snapshot.designResetText = designResetStr }
        if !userEmail.isEmpty { snapshot.userEmail = userEmail }
        snapshot.throttleStatus = throttleStatus
        snapshot.refreshedAt = Date()
        
        NSLog("[ClaudePulse] DOM parsed: session %d/%d (%@), weekly %d/%d (%@), scoped '%@' %d/%d (%@), design '%@' %d/%d (%@)",
              windowConsumed, windowCapacity, sessionResetStr,
              periodConsumed, periodCapacity, weeklyResetStr,
              j["sonnetTitle"] as? String ?? "", sonnetConsumed, sonnetCapacity, sonnetResetStr,
              j["designTitle"] as? String ?? "", designConsumed, designCapacity, designResetStr)

        currentSnapshot = snapshot
        fetchError      = nil
        requiresAuth    = false

        // Fetch email from account page if not yet known
        if snapshot.userEmail.isEmpty {
            fetchEmailIfNeeded()
        }
    }
    
    // MARK: - Helpers
    
    private func extractInt(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    
    /// Recursively searches a JSON dict for any reset date field and returns the nearest future one.
    private func locateResetTimestamp(in json: [String: Any]) -> Date? {
        let resetKeys = ["reset_at", "resets_at", "reset_time"]
        var found: [Date] = []
        
        func search(_ dict: [String: Any], depth: Int) {
            guard depth < 4 else { return }
            for (key, val) in dict {
                if resetKeys.contains(key), let d = parseTimestamp(val) { found.append(d) }
                if let sub = val as? [String: Any] { search(sub, depth: depth + 1) }
                if let arr = val as? [[String: Any]] { arr.forEach { search($0, depth: depth + 1) } }
            }
        }
        search(json, depth: 0)
        
        let now = Date()
        return found.filter { $0 > now }.min()
    }
    
    /// Parses strings like "2 hours", "30 minutes", "1 day", "2h 30m", "45 mins"
    /// into an absolute Date offset from now.
    private func resolveRelativeInterval(_ s: String) -> Date? {
        var totalSeconds: Double = 0
        let lower = s.lowercased()
        
        // Match patterns like "2 hours", "30 minutes", "1 day", "45 mins", "2h", "30m"
        let pattern = #"(\d+)\s*(day|hour|hr|min|h|d|m)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        guard !matches.isEmpty else { return nil }
        
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: lower),
                  let unitRange  = Range(match.range(at: 2), in: lower),
                  let value = Double(lower[valueRange])
            else { continue }
            let unit = String(lower[unitRange])
            switch unit {
            case "d", "day":          totalSeconds += value * 86400
            case "h", "hr", "hour":  totalSeconds += value * 3600
            case "m", "min":         totalSeconds += value * 60
            default: break
            }
        }
        
        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(totalSeconds)
    }
    
    private func parseTimestamp(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        // ISO 8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

// MARK: - WKNavigationDelegate

extension UsageDataProvider: WKNavigationDelegate {
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let s = url.absoluteString
        
        if webView === dataWebView {
            NSLog("[ClaudePulse] didFinish URL: %@", s)
            if s.contains("/login") || s.contains("/auth") || s.contains("?next=") {
                DispatchQueue.main.async { self.isFetching = false; self.cancelFetchTimeout(); self.requiresAuth = true; self.currentSnapshot = nil }
            } else if s.contains("settings/usage") {
                executeDOMParsing()
            } else if s.contains("claude.ai") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.dataWebView.load(URLRequest(url: self.targetURL))
                }
            } else {
                // Unexpected URL — don't leave isFetching stuck
                NSLog("[ClaudePulse] Unexpected URL after navigation: %@", s)
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.cancelFetchTimeout()
                }
            }
        } else if webView === authWebView {
            if !s.contains("/login") && !s.contains("/auth") {
                DispatchQueue.main.async { self.onAuthCompleted?() }
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === dataWebView {
            DispatchQueue.main.async { self.isFetching = false; self.cancelFetchTimeout(); self.fetchError = error.localizedDescription }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        if webView === dataWebView {
            DispatchQueue.main.async { self.isFetching = false; self.cancelFetchTimeout(); self.fetchError = error.localizedDescription }
        }
    }
}

// MARK: - WKScriptMessageHandler

extension UsageDataProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let d = body.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return }
        
        // Unwrap the interceptor envelope: { type, url, data }
        if let data = j["data"] as? [String: Any] {
            processAPIPayload(data)
        }
    }
}
