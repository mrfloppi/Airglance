// AirGlance – native macOS menu-bar shell around the Python dashboard backend.
// Starts the bundled backend, shows the dashboard in a WKWebView window,
// and stops the backend when the app quits.

import AppKit
import WebKit
import UserNotifications
import ServiceManagement

let kPort = 47823
let kBase = URL(string: "http://127.0.0.1:\(kPort)/")!
let kPopoverWidth: CGFloat = 540

// MARK: - Language: German if macOS prefers German, otherwise English

let kIsGerman = Locale.preferredLanguages.first?.lowercased().hasPrefix("de") ?? false
let kLang = kIsGerman ? "de" : "en"
func L(_ de: String, _ en: String) -> String { kIsGerman ? de : en }

// MARK: - Backend process

final class Backend {
    private var process: Process?
    private var stopping = false
    let dataDir: URL
    let logURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDir = support.appendingPathComponent("AirGlance", isDirectory: true)
        // one-time move of the data folder from the app's previous names (pre-release builds)
        for old in ["Airlight", "Luftqualitaet"] where !FileManager.default.fileExists(atPath: dataDir.path) {
            let legacy = support.appendingPathComponent(old, isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.moveItem(at: legacy, to: dataDir) }
        }
        let logs = dataDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("server.log")
        trimLog()
    }

    /// Keep the log small: above 2 MB only the last 512 KB are kept.
    private func trimLog() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
              size > 2_000_000, let h = try? FileHandle(forReadingFrom: logURL) else { return }
        h.seek(toFileOffset: UInt64(size - 512_000))
        let tail = h.readDataToEndOfFile()
        try? h.close()
        try? tail.write(to: logURL)
    }

    /// Problem that prevents the backend from starting (embedded Python missing or damaged), else nil.
    var startProblem: String? {
        let python = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3").resolvingSymlinksInPath()
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            return L("Die eingebaute Python-Umgebung fehlt oder ist beschädigt. Bitte AirGlance neu installieren bzw. im Projektordner <code>./build-app.sh</code> ausführen.",
                     "The embedded Python runtime is missing or damaged. Please reinstall AirGlance or run <code>./build-app.sh</code> in the project folder.")
        }
        return nil
    }

    func start() {
        if let problem = startProblem { NSLog("Backend nicht startbar: \(problem)"); return }
        let res = Bundle.main.resourceURL!
        let python = res.appendingPathComponent("python/bin/python3")   // embedded runtime, no system Python needed
        let script = res.appendingPathComponent("backend/server.py")

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()

        let p = Process()
        p.executableURL = python
        p.arguments = [script.path]
        p.currentDirectoryURL = dataDir
        var env = ProcessInfo.processInfo.environment
        env["AQM_DATA_DIR"] = dataDir.path
        env["AQM_PORT"] = String(kPort)
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"   // keep the signed bundle unmodified
        env["AQM_PARENT_PID"] = String(getpid())   // backend exits if the app disappears
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            guard let self, !self.stopping else { return }
            NSLog("Backend beendet (Status \(proc.terminationStatus)) – Neustart in 5 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.start() }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Backend konnte nicht gestartet werden: \(error)")
        }
    }

    func stop() {
        stopping = true
        guard let p = process, p.isRunning else { return }
        p.terminate()  // SIGTERM -> aiohttp shuts down cleanly
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Polls /api/status until the server answers (or a timeout hits).
    func waitUntilReady(timeout: TimeInterval = 30, completion: @escaping (Bool) -> Void) {
        let start = Date()
        func attempt() {
            var req = URLRequest(url: kBase.appendingPathComponent("api/status"))
            req.timeoutInterval = 1
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if (resp as? HTTPURLResponse)?.statusCode == 200 {
                    DispatchQueue.main.async { completion(true) }
                } else if Date().timeIntervalSince(start) > timeout {
                    DispatchQueue.main.async { completion(false) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { attempt() }
                }
            }.resume()
        }
        attempt()
    }
}

// MARK: - Web view

/// Forwards messages from the page without WKUserContentController retaining the view (avoids a cycle).
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: DashboardView?
    init(_ target: DashboardView) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        target?.onMessage?(action, body["value"])
    }
}

final class DashboardView: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    /// page -> app messages: ("height", Int), ("getState", nil), ("notifications", Bool), ("openWindow", nil) …
    var onMessage: ((String, Any?) -> Void)?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // keeps small UI prefs (open history, chosen monitor)
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(WeakScriptHandler(self), name: "app")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        showMessage(L("Dashboard wird gestartet …", "Starting dashboard …"))
    }

    func showMessage(_ text: String) {
        let html = """
        <html><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        font:14px/1.5 -apple-system;color:#7a7974;background:transparent;padding:0 32px;text-align:center">
        <div>\(text)</div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func send(state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.onAppState && window.onAppState(\(json))")
    }

    func loadDashboard(compact: Bool = false) {
        let query = compact ? "?compact=1&lang=\(kLang)" : "?lang=\(kLang)"
        let url = URL(string: query, relativeTo: kBase)!.absoluteURL
        webView.load(URLRequest(url: url))
    }

    // Links to anything other than the local dashboard (e.g. Amazon login) open in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.navigationType == .linkActivated,
           !(url.host == "127.0.0.1" && url.port == kPort) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // JavaScript confirm()/alert() need native panels in WKWebView, otherwise they silently fail
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: L("Abbrechen", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    // target="_blank" links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

// MARK: - Menu bar icon (traffic light)

/// Status of the menu-bar LED. Colours follow the real device's light:
/// green = good, yellow = moderate, red = poor, purple = connection problem, blue = setup.
enum AirStatus: String { case good, moderate, poor, unknown, offline, setup }

let kLEDColors: [AirStatus: NSColor] = [
    .good: NSColor(srgbRed: 0.13, green: 0.78, blue: 0.37, alpha: 1),      // LED green
    .moderate: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),  // LED yellow
    .poor: NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),      // LED red
    .offline: NSColor(srgbRed: 0.66, green: 0.33, blue: 0.97, alpha: 1),   // LED purple: no current data
    .setup: NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1),     // LED blue: login / setup needed
]

/// Menu-bar icon: slim outline of the air quality monitor; its status LED shows the device colour
/// (hollow when the state is unknown). Sized and weighted like SF Symbols in the menu bar.
func trafficLightImage(_ status: AirStatus) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
        // drawn at render time -> outline adapts to light/dark menu bar
        let ink = NSColor.labelColor
        ink.setStroke()
        let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 15, height: 11), xRadius: 3, yRadius: 3)
        body.lineWidth = 1.0
        body.stroke()
        let grille = NSBezierPath(roundedRect: NSRect(x: 5, y: 8.3, width: 8, height: 2.4), xRadius: 1.2, yRadius: 1.2)
        grille.lineWidth = 0.9
        grille.stroke()
        let led = NSRect(x: 9 - 1.35, y: 5.3 - 1.35, width: 2.7, height: 2.7)
        if let c = kLEDColors[status] {
            c.setFill()
            NSBezierPath(ovalIn: led).fill()
        } else {
            let hollow = NSBezierPath(ovalIn: led.insetBy(dx: 0.35, dy: 0.35))
            hollow.lineWidth = 0.9
            ink.withAlphaComponent(0.6).setStroke()
            hollow.stroke()
        }
        return true
    }
    img.isTemplate = false
    img.accessibilityDescription = "AirGlance"
    return img
}

// MARK: - Traffic-light change notifications

struct Change {
    let monitor: String, metric: String, old: String, new: String, value: Double, direction: String?
}

func statusLabel(_ s: String) -> String {
    kIsGerman ? (["good": "Gut", "moderate": "Mäßig", "poor": "Schlecht"][s] ?? "unbekannt")
              : (["good": "Good", "moderate": "Moderate", "poor": "Poor"][s] ?? "unknown")
}

func num(_ v: Double, _ decimals: Int) -> String {
    let s = String(format: "%.\(decimals)f", v)
    return kIsGerman ? s.replacingOccurrences(of: ".", with: ",") : s
}

/// Short, plain-language notification text: headline + what to do.
func describe(_ c: Change) -> (title: String, body: String) {
    let poor = c.new == "poor"
    let v = c.value
    if c.new == "good" {
        let what: [String: String] = kIsGerman
            ? ["iaq": "Luftqualität", "pm25": "Feinstaub", "pm10": "Grobstaub", "voc": "Ausdünstungen (VOC)",
               "co": "Kohlenmonoxid", "temperature": "Temperatur", "humidity": "Luftfeuchtigkeit"]
            : ["iaq": "Air quality", "pm25": "Fine dust", "pm10": "Coarse dust", "voc": "VOC",
               "co": "Carbon monoxide", "temperature": "Temperature", "humidity": "Humidity"]
        let val: [String: String] = ["iaq": "Score \(num(v, 0))/100", "pm25": "\(num(v, 0)) µg/m³", "pm10": "\(num(v, 0)) µg/m³",
                                     "voc": "Index \(num(v, 0))", "co": "\(num(v, 0)) ppm", "temperature": "\(num(v, 1)) °C",
                                     "humidity": "\(num(v, 0)) %"]
        let name = what[c.metric] ?? c.metric, value = val[c.metric] ?? num(v, 1)
        return (L("✅ \(name) wieder im grünen Bereich", "✅ \(name) back to good"), L("Aktuell \(value).", "Now \(value)."))
    }
    let dot = poor ? "🔴" : "🟡"
    switch c.metric {
    case "iaq":
        return (L("\(dot) Luftqualität \(poor ? "schlecht" : "mäßig")", "\(dot) Air quality \(poor ? "poor" : "moderate")"),
                L("Score \(num(v, 0)) von 100. \(poor ? "Jetzt gründlich lüften." : "Kurz lüften hilft meist.")",
                  "Score \(num(v, 0)) of 100. \(poor ? "Air the room thoroughly now." : "A short airing usually helps.")"))
    case "pm25", "pm10":
        let fine = c.metric == "pm25"
        return (L("\(dot) \(poor ? "Viel" : "Erhöhter") \(fine ? "Feinstaub" : "Grobstaub")",
                  "\(dot) \(poor ? "High" : "Elevated") \(fine ? "fine dust" : "coarse dust")"),
                L("\(num(v, 0)) µg/m³ – Fenster öffnen oder Luftreiniger einschalten.",
                  "\(num(v, 0)) µg/m³ – open a window or switch on an air purifier."))
    case "voc":
        return (L("\(dot) \(poor ? "Viele" : "Mehr") Ausdünstungen in der Luft", "\(dot) \(poor ? "Lots of" : "More") fumes in the air"),
                L("VOC-Index \(num(v, 0)) – z. B. von Reinigungsmitteln, Kochen oder Farbe. Kurz lüften.",
                  "VOC index \(num(v, 0)) – e.g. from cleaning products, cooking or paint. Air the room briefly."))
    case "co":
        return (poor ? L("🔴 Kohlenmonoxid gefährlich hoch", "🔴 Carbon monoxide dangerously high")
                     : L("🟡 Kohlenmonoxid erhöht", "🟡 Carbon monoxide elevated"),
                L("\(num(v, 0)) ppm – sofort lüften und Gasgeräte oder Kamin prüfen.",
                  "\(num(v, 0)) ppm – ventilate now and check gas appliances or the fireplace."))
    case "temperature":
        let hot = c.direction != "low"
        let head = hot ? (poor ? L("Viel zu warm", "Much too warm") : L("Zu warm", "Too warm"))
                       : (poor ? L("Viel zu kalt", "Much too cold") : L("Zu kühl", "Too cool"))
        return ("\(dot) \(head)",
                L("\(num(v, 1)) °C – angenehm sind 19 bis 24 °C.\(hot ? " Heizung runterdrehen oder lüften." : "")",
                  "\(num(v, 1)) °C – 19 to 24 °C is comfortable.\(hot ? " Turn the heating down or air the room." : "")"))
    case "humidity":
        let wet = c.direction != "low"
        return (L("\(dot) Luft \(poor ? "sehr " : "zu ")\(wet ? "feucht" : "trocken")",
                  "\(dot) Air \(poor ? "very " : "too ")\(wet ? "humid" : "dry")"),
                L("\(num(v, 0)) % – ideal sind 40 bis 60 %.\(wet ? " Lüften, sonst droht Schimmel." : "")",
                  "\(num(v, 0)) % – 40 to 60 % is ideal.\(wet ? " Air the room to prevent mould." : "")"))
    default:
        return ("\(dot) \(c.metric): \(statusLabel(c.new))", num(v, 1))
    }
}

/// Detects traffic-light changes per monitor+metric. A new state must show up in two
/// consecutive measurements (≈5–10 min) before it counts, so values hovering
/// around a threshold do not cause a flood of notifications.
final class StatusWatcher {
    private var confirmed: [String: String] = [:]
    private var pending: [String: (status: String, ts: Int)] = [:]
    var onChange: ((Change) -> Void)?

    func check(monitorId: String, monitorName: String, metrics: [String: [String: Any]]) {
        for (metric, m) in metrics {
            let key = monitorId + "|" + metric
            guard let s = m["status"] as? String, s != "unknown",
                  let ts = (m["ts"] as? NSNumber)?.intValue,
                  let value = (m["value"] as? NSNumber)?.doubleValue else { continue }
            guard let old = confirmed[key] else { confirmed[key] = s; continue }   // baseline at start
            if s == old { pending[key] = nil; continue }
            if let p = pending[key], p.status == s {
                if p.ts != ts {   // seen in a second, newer measurement -> confirmed change
                    confirmed[key] = s
                    pending[key] = nil
                    onChange?(Change(monitor: monitorName, metric: metric, old: old, new: s, value: value,
                                     direction: m["direction"] as? String))
                }
            } else {
                pending[key] = (s, ts)
            }
        }
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onClick: (() -> Void)?
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifications") }
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            NSLog("Mitteilungen erlaubt: \(granted)")
        }
    }

    func send(_ c: Change, showMonitor: Bool, force: Bool = false) {
        guard enabled || force else { return }
        let rank = ["good": 0, "moderate": 1, "poor": 2]
        let text = describe(c)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        if showMonitor { content.subtitle = c.monitor }
        if (rank[c.new] ?? 0) > (rank[c.old] ?? 0) { content.sound = .default }
        content.threadIdentifier = c.monitor   // groups notifications per monitor
        let req = UNNotificationRequest(identifier: "aqm-\(c.metric)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { NSLog("Mitteilung fehlgeschlagen: \(error)") }
        }
    }

    /// Plain notification (login needed, monitor offline …); clicking opens `url` if given.
    func sendInfo(title: String, body: String, url: String? = nil) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url { content.userInfo = ["url": url] }
        let req = UNNotificationRequest(identifier: "aqm-info-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // show banners even while the app is active
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let url = (r.notification.request.content.userInfo["url"] as? String).flatMap(URL.init(string:))
        DispatchQueue.main.async { if let url { NSWorkspace.shared.open(url) } else { self.onClick?() } }
        done()
    }
}

func hexColor(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let backend = Backend()
    let popoverView = DashboardView()
    var windowView: DashboardView?
    var window: NSWindow?
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var ready = false
    var timer: Timer?
    let watcher = StatusWatcher()
    var lastHealth: String?   // ok | stale | login_required – for one-off notifications
    var monitorCount = 0
    var contentHeight: CGFloat = 0   // reported by the page (height of its content)
    let notifier = Notifier()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        notifier.setup()
        notifier.onClick = { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.togglePopover()
        }
        watcher.onChange = { [weak self] change in
            guard let self else { return }
            self.notifier.send(change, showMonitor: self.monitorCount > 1)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = trafficLightImage(.unknown)
            b.toolTip = "AirGlance"
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient   // closes when clicking elsewhere, like Control Center
        popover.animates = true
        UserDefaults.standard.removeObject(forKey: "popoverHeight")   // old manual height is no longer used
        popover.contentSize = NSSize(width: kPopoverWidth, height: fittingHeight())
        let vc = NSViewController()
        vc.view = popoverView.webView
        popover.contentViewController = vc
        popoverView.onMessage = { [weak self] action, value in self?.handle(action, value, from: self?.popoverView) }

        if let problem = backend.startProblem {
            popoverView.showMessage("⚠️ " + problem)
            statusItem.button?.toolTip = L("AirGlance: Hintergrunddienst kann nicht starten", "AirGlance: background service cannot start")
            return
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // give Wi-Fi a moment, then fetch fresh values instead of waiting up to 5 min
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.requestRefresh() }
        }
        backend.start()
        backend.waitUntilReady { [weak self] ok in
            guard let self else { return }
            self.ready = ok
            if ok {
                self.popoverView.loadDashboard(compact: true)
                self.windowView?.loadDashboard(compact: false)
                self.updateStatus()
            } else {
                self.popoverView.showMessage(L("Hintergrunddienst startet nicht. Log: ", "Background service does not start. Log: ") + self.backend.logURL.path)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateStatus() }
    }

    func applicationWillTerminate(_ note: Notification) { backend.stop() }

    /// Largest height that still fits between the menu-bar icon and the bottom of the screen.
    /// If the popover gets taller than this, macOS repositions it (it jumps sideways).
    func maxPopoverHeight() -> CGFloat {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return 700 }
        let top = statusItem?.button?.window?.frame.minY ?? visible.maxY
        return max(360, top - visible.minY - 40)   // 40 pt: popover arrow + bottom margin
    }

    /// Popover height that shows the whole content, capped by the space below the menu bar.
    func fittingHeight() -> CGFloat {
        let content = contentHeight > 0 ? contentHeight : 420
        return max(220, min(content, maxPopoverHeight())).rounded()
    }

    /// Follow the page's content height (collapsed = compact, expanded = as tall as the screen allows).
    func applyPopoverHeight() {
        let h = fittingHeight()
        guard abs(popover.contentSize.height - h) > 0.5 else { return }
        let was = popover.animates
        popover.animates = false   // the page animates; we follow it frame by frame
        popover.contentSize = NSSize(width: popover.contentSize.width, height: h)
        popover.animates = was
    }

    // MARK: page -> app bridge

    var appState: [String: Any] {
        ["notifications": notifier.enabled, "autostart": SMAppService.mainApp.status == .enabled]
    }

    func handle(_ action: String, _ value: Any?, from view: DashboardView?) {
        switch action {
        case "height":
            if view === popoverView, let h = (value as? NSNumber)?.doubleValue { contentHeight = CGFloat(h); applyPopoverHeight() }
        case "tooltip": showTooltip(value as? [String: Any], in: view)
        case "tooltipHide": hideTooltip()
        case "getState": view?.send(state: appState)
        case "notifications": notifier.enabled = (value as? Bool) ?? notifier.enabled; broadcastState()
        case "autostart": setLaunchAtLogin((value as? Bool) ?? false)
        case "test": testNotification()
        case "openWindow": openWindow()
        case "reload": reload()
        case "showLog": showLog()
        case "showData": showData()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: native tooltip (a real popover, so it can extend beyond the dashboard window)

    let tipPopover: NSPopover = {
        let p = NSPopover()
        p.behavior = .applicationDefined   // shown/hidden by the page's hover events
        p.animates = false
        return p
    }()

    func showTooltip(_ d: [String: Any]?, in view: DashboardView?) {
        guard let d, let wv = view?.webView, wv.window != nil else { return }
        let n = { (k: String) in CGFloat((d[k] as? NSNumber)?.doubleValue ?? 0) }
        var rect = NSRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
        if !wv.isFlipped { rect.origin.y = wv.bounds.height - rect.maxY }
        let vc = NSViewController()
        vc.view = makeTooltipView(d)
        if tipPopover.isShown { tipPopover.close() }
        tipPopover.contentViewController = vc
        tipPopover.contentSize = vc.view.frame.size
        tipPopover.show(relativeTo: rect, of: wv, preferredEdge: wv.isFlipped ? .maxY : .minY)   // below the tile if there is room
    }

    func hideTooltip() { if tipPopover.isShown { tipPopover.close() } }

    private func makeTooltipView(_ d: [String: Any]) -> NSView {
        let width: CGFloat = 300
        let label = { (text: String, size: CGFloat, color: NSColor, bold: Bool) -> NSTextField in
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
            f.textColor = color
            f.isSelectable = false
            return f
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let info = label(d["info"] as? String ?? "", 12.5, .secondaryLabelColor, false)
        info.preferredMaxLayoutWidth = width
        stack.addArrangedSubview(info)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        for r in (d["rows"] as? [[String: Any]]) ?? [] {
            let current = r["current"] as? Bool ?? false
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = hexColor(r["color"] as? String ?? "#888888").cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10)])
            let name = label(r["label"] as? String ?? "", 12.5, .labelColor, current)
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 62).isActive = true
            let range = label(r["range"] as? String ?? "", 12.5, .labelColor, current)
            range.preferredMaxLayoutWidth = width - 100
            let row = NSStackView(views: [dot, name, range])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            if current {
                row.wantsLayer = true
                row.layer?.cornerRadius = 6
                row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            }
            rows.addArrangedSubview(row)
        }
        stack.addArrangedSubview(rows)

        let source = label(d["source"] as? String ?? "", 11, .tertiaryLabelColor, false)
        source.preferredMaxLayoutWidth = width
        stack.addArrangedSubview(source)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width + 28).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }

    func broadcastState() {
        popoverView.send(state: appState)
        windowView?.send(state: appState)
    }

    // MARK: status icon

    func updateStatus() {
        URLSession.shared.dataTask(with: kBase.appendingPathComponent("api/overview")) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { [weak self] in self?.applyOverview(o) }
        }.resume()
    }

    func applyOverview(_ o: [String: Any]?) {
        guard let button = statusItem.button else { return }
        guard let o else { button.image = trafficLightImage(.unknown); button.toolTip = L("AirGlance: keine Verbindung zum Hintergrunddienst", "AirGlance: no connection to the background service"); return }
        let state = o["status"] as? String ?? ""
        let monitors = (o["monitors"] as? [[String: Any]]) ?? []
        monitorCount = monitors.count
        let rank: [AirStatus: Int] = [.unknown: -1, .offline: -1, .setup: -1, .good: 0, .moderate: 1, .poor: 2]
        var worst = AirStatus.unknown
        var lines: [String] = []
        var allStale = !monitors.isEmpty
        for m in monitors {
            let name = m["name"] as? String ?? "Monitor"
            let metrics = (m["metrics"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
            let stale = m["stale"] as? Bool ?? true
            if !stale { allStale = false }
            let iaq = metrics["iaq"]
            let s = stale ? AirStatus.unknown : AirStatus(rawValue: iaq?["status"] as? String ?? "") ?? .unknown
            if rank[s]! > rank[worst]! { worst = s }
            if stale { lines.append("\(name): " + L("keine aktuellen Messwerte", "no current readings")) }
            else if let v = (iaq?["value"] as? NSNumber)?.doubleValue { lines.append("\(name): \(Int(v))/100 – \(statusLabel(s.rawValue))") }
            if !stale { watcher.check(monitorId: m["id"] as? String ?? name, monitorName: name, metrics: metrics) }
        }
        var tip = lines.isEmpty ? "AirGlance" : lines.joined(separator: "\n")
        let needsLogin = ["login_required", "logging_in", "needs_account"].contains(state)
        if allStale && state == "ok" { worst = .offline }   // like the device's purple light
        if needsLogin { worst = .setup; tip = L("AirGlance: Anmeldung bei Amazon nötig", "AirGlance: Amazon sign-in required") }
        if state == "setup_required" { worst = .setup; tip = L("AirGlance: bitte Monitore auswählen", "AirGlance: choose your monitors") }
        if state == "error" { tip += L("\n(letzter Abruf fehlgeschlagen)", "\n(last update failed)") }
        button.image = trafficLightImage(worst)
        button.toolTip = tip
        healthChanged(needsLogin ? "login_required" : (allStale && state == "ok") ? "stale" : state == "ok" ? "ok" : nil,
                      loginURL: o["login_url"] as? String)
    }

    /// One notification per change of overall health (login needed / monitor offline / back to normal).
    func healthChanged(_ health: String?, loginURL: String?) {
        guard let health, health != lastHealth else { return }
        defer { lastHealth = health }
        guard lastHealth != nil || health != "ok" else { return }   // no "all good" message at start
        switch health {
        case "login_required":
            notifier.sendInfo(title: L("🔑 Bitte erneut bei Amazon anmelden", "🔑 Please sign in to Amazon again"),
                              body: L("Ohne Anmeldung kommen keine neuen Messwerte. Hier klicken zum Anmelden.",
                                      "No new readings without signing in. Click here to sign in."), url: loginURL)
        case "stale":
            notifier.sendInfo(title: L("📡 Monitor sendet keine Daten", "📡 Monitor isn't sending data"),
                              body: L("Seit über 20 Minuten keine neuen Werte. Ist der Monitor eingesteckt und im WLAN?",
                                      "No new readings for over 20 minutes. Is the monitor plugged in and on Wi-Fi?"))
        default:
            if lastHealth == "stale" || lastHealth == "login_required" {
                notifier.sendInfo(title: L("✅ Wieder verbunden", "✅ Connected again"),
                                  body: L("Es kommen wieder aktuelle Messwerte.", "Current readings are coming in again."))
            }
        }
    }

    func requestRefresh() {
        post("api/refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.updateStatus()
            self?.popoverView.webView.evaluateJavaScript("typeof refresh === 'function' && refresh()")
        }
    }

    func post(_ path: String, completion: (() -> Void)? = nil) {
        var req = URLRequest(url: kBase.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-AQM")   // backend rejects POSTs without it (CSRF guard)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: req) { _, _, _ in DispatchQueue.main.async { completion?() } }.resume()
    }

    // MARK: clicks

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            hideTooltip()
            popover.performClose(nil)
        } else {
            popover.contentSize = NSSize(width: kPopoverWidth, height: fittingHeight())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            if ready { popoverView.webView.evaluateJavaScript("document.activeElement && document.activeElement.blur(); typeof refresh === 'function' && refresh()") }
        }
    }

    func showContextMenu() {
        let menu = NSMenu()
        func add(_ de: String, _ en: String, _ symbol: String, _ action: Selector, key: String = "", on: Bool? = nil) {
            let item = menu.addItem(withTitle: L(de, en), action: action, keyEquivalent: key)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let on { item.state = on ? .on : .off }
            if action != #selector(NSApplication.terminate(_:)) { item.target = self }
        }
        add("Dashboard im Fenster öffnen", "Open dashboard in a window", "macwindow", #selector(openWindow))
        add("Monitore & Konto …", "Monitors & account …", "gearshape", #selector(openSettings))
        add("Neu laden", "Reload", "arrow.clockwise", #selector(reload))
        menu.addItem(.separator())
        add("Mitteilungen bei Ampelwechsel", "Notify on traffic-light changes", "bell", #selector(toggleNotifications), on: notifier.enabled)
        add("Test-Mitteilung senden", "Send test notification", "paperplane", #selector(testNotification))
        add("Mit dem System starten", "Start at login", "power", #selector(toggleLaunchAtLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Log anzeigen", "Show log", "doc.text", #selector(showLog))
        add("Datenordner öffnen", "Open data folder", "folder", #selector(showData))
        menu.addItem(.separator())
        add("Von Amazon abmelden …", "Sign out of Amazon …", "rectangle.portrait.and.arrow.right", #selector(logout))
        add("AirGlance beenden", "Quit AirGlance", "xmark.circle", #selector(NSApplication.terminate(_:)), key: "q")
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    @objc func openWindow() {
        popover.performClose(nil)
        if window == nil {
            let view = DashboardView()
            view.onMessage = { [weak self, weak view] action, value in self?.handle(action, value, from: view) }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "AirGlance"
            w.minSize = NSSize(width: 420, height: 480)
            w.contentView = view.webView
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("DashboardWindow")
            if w.frame.origin == .zero { w.center() }
            windowView = view
            window = w
            if ready { view.loadDashboard(compact: false) }
        }
        NSApp.setActivationPolicy(.regular)   // show in Dock / Cmd-Tab while the window is open
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)  // back to menu-bar-only
        window = nil
        windowView = nil
    }

    @objc func reload() {
        popoverView.loadDashboard(compact: true)
        windowView?.loadDashboard(compact: false)
        updateStatus()
    }
    @objc func toggleNotifications() { notifier.enabled.toggle(); broadcastState() }
    @objc func testNotification() {
        notifier.send(Change(monitor: "Test", metric: "temperature", old: "good", new: "moderate", value: 25.3, direction: "high"),
                      showMonitor: false, force: true)
    }

    @objc func openSettings() {
        if !popover.isShown { togglePopover() }
        popoverView.webView.evaluateJavaScript("typeof openSettings === 'function' && openSettings()")
    }

    @objc func toggleLaunchAtLogin() { setLaunchAtLogin(SMAppService.mainApp.status != .enabled) }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        defer { broadcastState() }
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = L("Autostart konnte nicht geändert werden", "Couldn't change start at login")
            a.informativeText = error.localizedDescription + L("\n\nAlternativ: Systemeinstellungen → Allgemein → Anmeldeobjekte.",
                                                                 "\n\nAlternatively: System Settings → General → Login Items.")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func logout() {
        let a = NSAlert()
        a.messageText = L("Von Amazon abmelden?", "Sign out of Amazon?")
        a.informativeText = L("Die App holt danach keine neuen Messwerte mehr, bis du dich wieder anmeldest. Gespeicherte Werte und Monitor-Namen bleiben erhalten.",
                              "The app won't fetch new readings until you sign in again. Saved readings and monitor names are kept.")
        a.addButton(withTitle: L("Abmelden", "Sign out"))
        a.addButton(withTitle: L("Abbrechen", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        post("api/logout") { [weak self] in
            self?.updateStatus()
            self?.popoverView.webView.evaluateJavaScript("typeof refresh === 'function' && refresh()")
            self?.windowView?.webView.evaluateJavaScript("typeof refresh === 'function' && refresh()")
        }
    }
    @objc func showLog() { NSWorkspace.shared.open(backend.logURL) }
    @objc func showData() { NSWorkspace.shared.open(backend.dataDir) }

    // Main menu: only visible while the dashboard window is open; provides Cmd-Q/C/W/R.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Über AirGlance", "About AirGlance"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("AirGlance beenden", "Quit AirGlance"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("Bearbeiten", "Edit"))
        edit.addItem(withTitle: L("Kopieren", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Alles auswählen", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: L("Darstellung", "View"))
        let r = view.addItem(withTitle: L("Neu laden", "Reload"), action: #selector(reload), keyEquivalent: "r"); r.target = self
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: L("Fenster", "Window"))
        win.addItem(withTitle: L("Schließen", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: L("Minimieren", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar app: no Dock icon
app.run()
