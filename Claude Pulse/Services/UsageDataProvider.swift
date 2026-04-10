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
        sonnetUsed: -1, sonnetLimit: -1,
        resetDateStr: '', sessionResetStr: '', weeklyResetStr: '', sonnetResetStr: '',
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

        // aria progressbars: session (0), all models (1), sonnet only (2)
        var bars = Array.from(document.querySelectorAll('[role="progressbar"]'));
        if (bars.length >= 3) {
            r.sessionUsed   = parseInt(bars[0].getAttribute('aria-valuenow')||'0');
            r.sessionLimit  = parseInt(bars[0].getAttribute('aria-valuemax')||'0');
            r.messagesUsed  = parseInt(bars[1].getAttribute('aria-valuenow')||'0');
            r.messagesLimit = parseInt(bars[1].getAttribute('aria-valuemax')||'0');
            r.sonnetUsed    = parseInt(bars[2].getAttribute('aria-valuenow')||'0');
            r.sonnetLimit   = parseInt(bars[2].getAttribute('aria-valuemax')||'0');
        } else if (bars.length >= 2) {
            r.sessionUsed  = parseInt(bars[0].getAttribute('aria-valuenow')||'0');
            r.sessionLimit = parseInt(bars[0].getAttribute('aria-valuemax')||'0');
            r.messagesUsed = parseInt(bars[bars.length-1].getAttribute('aria-valuenow')||'0');
            r.messagesLimit= parseInt(bars[bars.length-1].getAttribute('aria-valuemax')||'0');
        } else if (bars.length === 1) {
            r.messagesUsed = parseInt(bars[0].getAttribute('aria-valuenow')||'0');
            r.messagesLimit= parseInt(bars[0].getAttribute('aria-valuemax')||'0');
        }

        // Reset labels: collect ALL "Resets ..." occurrences in page order
        // Format 1: "Resets in 3 hr 58 min" (relative)
        // Format 2: "Resets Wed 10:59 AM" (absolute day+time)
        var allResets = Array.from(body.matchAll(/Resets\\s+(in\\s+\\d+\\s+\\w+(?:\\s+\\d+\\s+\\w+)?|(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\\w*\\s+\\d{1,2}:\\d{2}\\s*(?:AM|PM))/g));
        if (allResets.length > 0) r.sessionResetStr = allResets[0][1].trim();
        if (allResets.length > 1) r.weeklyResetStr  = allResets[1][1].trim();
        if (allResets.length > 2) r.sonnetResetStr  = allResets[2][1].trim();

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
    
    var onAuthCompleted: (() -> Void)?
    
    private var dataWebView: WKWebView!
    private(set) var authWebView: WKWebView?
    private var authURLObservation: NSKeyValueObservation?
    
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
        // Check if we have claude.ai cookies before loading
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let hasClaude = cookies.contains { $0.domain.contains("claude") }
            DispatchQueue.main.async {
                if hasClaude {
                    self.isFetching = true
                    self.dataWebView.load(URLRequest(url: self.targetURL))
                } else {
                    self.requiresAuth = true
                }
            }
        }
    }
    
    func reloadData() {
        guard !isFetching, !requiresAuth else { return }
        isFetching = true
        // Keep current snapshot visible during reload — only update on new data
        dataWebView.load(URLRequest(url: targetURL))
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
    
    private func executeDOMParsing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.dataWebView.evaluateJavaScript(kDOMParserScript) { result, _ in
                guard let self,
                      let s = result as? String,
                      let d = s.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return }
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.processDOMPayload(j)
                }
            }
        }
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
        let throttleStatus   = j["rateLimitStatus"]  as? String ?? "Normal"
        let resetDateStr     = j["resetDateStr"]     as? String ?? ""
        let sessionResetStr  = j["sessionResetStr"]  as? String ?? ""
        let weeklyResetStr   = j["weeklyResetStr"]   as? String ?? ""
        let sonnetResetStr   = j["sonnetResetStr"]   as? String ?? ""
        let userEmail        = j["userEmail"]         as? String ?? ""

        var windowResetDate: Date?
        var periodResetDate: Date?
        var sonnetResetDate: Date?
        
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
        }
        if let rd = windowResetDate { snapshot.windowResetDate = rd }
        if let wd = periodResetDate { snapshot.periodResetDate = wd; snapshot.periodResetText = "" }
        if let sd = sonnetResetDate { snapshot.sonnetResetDate = sd; snapshot.sonnetResetText = "" }
        // Store raw text for absolute day+time formats (e.g. "Fri 10:00 AM")
        // These couldn't be parsed to Date by resolveRelativeInterval
        let isAbsolute = { (s: String) -> Bool in s.range(of: #"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"#, options: .regularExpression) != nil }
        if !sessionResetStr.isEmpty && windowResetDate == nil && isAbsolute(sessionResetStr) {
            snapshot.windowResetText = sessionResetStr
        }
        if !weeklyResetStr.isEmpty && isAbsolute(weeklyResetStr) { snapshot.periodResetText = weeklyResetStr }
        if !sonnetResetStr.isEmpty && isAbsolute(sonnetResetStr) { snapshot.sonnetResetText = sonnetResetStr }
        if !userEmail.isEmpty { snapshot.userEmail = userEmail }
        snapshot.throttleStatus = throttleStatus
        snapshot.refreshedAt = Date()
        
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
            if s.contains("/login") || s.contains("/auth") || s.contains("?next=") {
                DispatchQueue.main.async { self.isFetching = false; self.requiresAuth = true; self.currentSnapshot = nil }
            } else if s.contains("settings/usage") {
                executeDOMParsing()
            } else if s.contains("claude.ai") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.dataWebView.load(URLRequest(url: self.targetURL))
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
            DispatchQueue.main.async { self.isFetching = false; self.fetchError = error.localizedDescription }
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        if webView === dataWebView {
            DispatchQueue.main.async { self.isFetching = false; self.fetchError = error.localizedDescription }
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
