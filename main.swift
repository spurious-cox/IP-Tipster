// DNSUpdater 1.0.0 — keeps a Dynu dynamic-DNS hostname pointed at this Mac,
// and keeps a running transcript of every IP address change.
//   DNSUpdater            menu-bar app: IP log, Update Now, Settings
//   DNSUpdater --update   one headless update (what the launch agent runs)
//   DNSUpdater --install-agent   write and load the launch agent
import Cocoa
import CryptoKit
import SystemConfiguration
import Darwin

let appVersion = "1.3.0"
let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/DNSUpdater")
let oldSupportDir = home.appendingPathComponent("Library/Application Support/DynuUpdater")
let configURL = supportDir.appendingPathComponent("config.json")
let historyURL = supportDir.appendingPathComponent("history.log")
let stateURL = supportDir.appendingPathComponent("state.json")
let agentLabel = "com.timmccoy.dnsupdater.agent"
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let fm = FileManager.default

// MARK: config and state

struct Config: Codable {
    var username = ""
    var passwordMD5 = ""
    var hostname = ""          // blank = every hostname on the account
    var intervalMinutes = 5

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        passwordMD5 = try c.decodeIfPresent(String.self, forKey: .passwordMD5) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
    }
    enum Keys: String, CodingKey { case username, passwordMD5, hostname, intervalMinutes }
}

struct State: Codable {
    var lastIP = ""; var lastChange = ""; var lastCheck = ""; var lastStatus = ""
    var vpnConnected = false; var vpnLocation = ""; var vpnVersion = ""
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        lastIP = try c.decodeIfPresent(String.self, forKey: .lastIP) ?? ""
        lastChange = try c.decodeIfPresent(String.self, forKey: .lastChange) ?? ""
        lastCheck = try c.decodeIfPresent(String.self, forKey: .lastCheck) ?? ""
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus) ?? ""
        vpnConnected = try c.decodeIfPresent(Bool.self, forKey: .vpnConnected) ?? false
        vpnLocation = try c.decodeIfPresent(String.self, forKey: .vpnLocation) ?? ""
        vpnVersion = try c.decodeIfPresent(String.self, forKey: .vpnVersion) ?? ""
    }
    enum Keys: String, CodingKey { case lastIP, lastChange, lastCheck, lastStatus, vpnConnected, vpnLocation, vpnVersion }
}

func ensureSupportDir() {
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
}

func loadConfig() -> Config {
    ensureSupportDir()
    if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) {
        migrateOldLog()                        // no-op once a history exists
        return c
    }
    // First run: take the settings DynuUpdater had.
    let old = oldSupportDir.appendingPathComponent("config.json")
    if let d = try? Data(contentsOf: old), var c = try? JSONDecoder().decode(Config.self, from: d) {
        c.intervalMinutes = 5
        saveConfig(c)
        migrateOldLog()
        return c
    }
    return Config()
}

func saveConfig(_ c: Config) {
    ensureSupportDir()
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) {
        try? d.write(to: configURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}

func loadState() -> State {
    if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) { return s }
    return State()
}
func saveState(_ s: State) {
    if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
}

func md5(_ s: String) -> String {
    Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

let stamp: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()

// MARK: history log (the transcript)

func appendHistory(_ line: String) {
    ensureSupportDir()
    let text = line + "\n"
    if let h = try? FileHandle(forWritingTo: historyURL) {
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    } else {
        try? text.write(to: historyURL, atomically: true, encoding: .utf8)
    }
    // Keep it from growing without limit: past 3 MB keep the newest 15,000 lines.
    if let size = (try? fm.attributesOfItem(atPath: historyURL.path))?[.size] as? Int, size > 3_000_000,
       let all = try? String(contentsOf: historyURL, encoding: .utf8) {
        let lines = all.split(separator: "\n", omittingEmptySubsequences: true)
        try? (lines.suffix(15000).joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
    }
}

/// Bring DynuUpdater's old log across, as change lines.
func migrateOldLog() {
    guard !fm.fileExists(atPath: historyURL.path),
          let all = try? String(contentsOf: oldSupportDir.appendingPathComponent("dynu.log"), encoding: .utf8) else { return }
    let iso = ISO8601DateFormatter()
    var out: [String] = []
    var last = ""
    var lastKey = ""
    for line in all.split(separator: "\n") {
        let parts = line.components(separatedBy: "  ")
        guard parts.count >= 2, let date = iso.date(from: parts[0]) else { continue }
        let rest = parts.dropFirst().joined(separator: "  ")
        var entry: String
        var key = parts[0] + rest
        if let r = rest.range(of: "good "), let end = rest.range(of: ")", range: r.upperBound..<rest.endIndex) {
            let ip = String(rest[r.upperBound..<end.lowerBound])
            key = parts[0] + ip
            if key == lastKey { continue }      // both updaters wrote the same second
            entry = ip == last ? "\(ip)  unchanged" : "\(ip)  CHANGED from \(last.isEmpty ? "?" : last)"
            last = ip
        } else {
            if key == lastKey { continue }
            entry = rest
        }
        lastKey = key
        out.append("\(stamp.string(from: date))  \(entry)")
    }
    if !out.isEmpty {
        let keep = out.suffix(15000)
        try? (keep.joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
        var s = loadState()
        s.lastIP = last
        saveState(s)
    }
}

// MARK: ExpressVPN

/// ExpressVPN has no command-line tool here, so its state is read from the system:
/// a tunnel (utun) interface that has an IPv4 address means a VPN is up, and the
/// location is the one ExpressVPN last picked (first of its recentLocations).
func vpnConnectedNow() -> Bool {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return false }
    defer { freeifaddrs(list) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        let name = String(cString: cur.pointee.ifa_name)
        if name.hasPrefix("utun"), let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) { return true }
        p = cur.pointee.ifa_next
    }
    return false
}

func vpnLocationNow() -> String {
    CFPreferencesAppSynchronize("com.expressvpn.ExpressVPN" as CFString)
    let v = CFPreferencesCopyAppValue("recentLocations" as CFString, "com.expressvpn.ExpressVPN" as CFString)
    return ((v as? [String])?.first) ?? ""
}

func vpnVersionNow() -> String {
    (Bundle(path: "/Applications/ExpressVPN.app")?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
}

/// Write a line to the log when ExpressVPN connects, disconnects, changes
/// location or is updated since the last look.
func logVPNEvents(_ state: inout State, now: String) {
    let connected = vpnConnectedNow()
    let location = vpnLocationNow()
    let version = vpnVersionNow()
    func note(_ t: String) { appendHistory("\(now)  \(t)") }
    if !state.vpnVersion.isEmpty, !version.isEmpty, version != state.vpnVersion {
        note("ExpressVPN updated: \(state.vpnVersion) -> \(version)  (CHANGED)")
    }
    if connected && !state.vpnConnected {
        note("VPN connected: \(location.isEmpty ? "location unknown" : location)  (CHANGED)")
    } else if !connected && state.vpnConnected {
        note("VPN disconnected  (CHANGED)")
    } else if connected && location != state.vpnLocation && !location.isEmpty {
        note("VPN location changed: \(state.vpnLocation.isEmpty ? "?" : state.vpnLocation) -> \(location)  (CHANGED)")
    }
    state.vpnConnected = connected
    state.vpnLocation = location
    if !version.isEmpty { state.vpnVersion = version }
}

/// One process at a time: the menu-bar app and the launch agent can both check.
func withLock<T>(_ body: () -> T) -> T {
    ensureSupportDir()
    let fd = open(supportDir.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return body()
}

/// The newest IP address in the log, for when the saved state has lost it.
func lastIPInHistory() -> String {
    guard let all = try? String(contentsOf: historyURL, encoding: .utf8) else { return "" }
    for line in all.split(separator: "\n").reversed() {
        let f = line.components(separatedBy: "  ")
        if f.count >= 2, f[1].range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return f[1] }
    }
    return ""
}

// MARK: the update

/// One update call. Returns the line for the log and whether it was a success.
@discardableResult
func runUpdate() -> String { withLock { runUpdateLocked() } }

func runUpdateLocked() -> String {
    let cfg = loadConfig()
    var state = loadState()
    if state.lastIP.isEmpty || state.lastIP == "?" { state.lastIP = lastIPInHistory() }
    let now = stamp.string(from: Date())
    logVPNEvents(&state, now: now)
    func finish(_ text: String, log: Bool = true) -> String {
        if log { appendHistory("\(now)  \(text)") }
        state.lastCheck = now; state.lastStatus = text
        saveState(state)
        return text
    }
    guard !cfg.username.isEmpty, !cfg.passwordMD5.isEmpty else {
        return finish("ERROR: no credentials configured (open Settings)")
    }
    var comps = URLComponents(string: "https://api.dynu.com/nic/update")!
    if !cfg.hostname.isEmpty { comps.queryItems = [URLQueryItem(name: "hostname", value: cfg.hostname)] }
    var req = URLRequest(url: comps.url!, timeoutInterval: 20)
    let auth = Data("\(cfg.username):\(cfg.passwordMD5)".utf8).base64EncodedString()
    req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
    req.setValue("DNSUpdater/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")

    var body = ""; var status = 0; var failed = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if err != nil { failed = true }
        status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        body = String(data: data ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 30)

    if failed { return finish("ERROR: no response") }
    if status >= 500 { return finish("ERROR: Dynu server error (\(status))") }
    if body.isEmpty { return finish("ERROR: empty response from Dynu") }
    let word = body.split(separator: " ").first.map(String.init) ?? body
    switch word {
    case "good", "nochg":
        guard let ip = body.split(separator: " ").dropFirst().first.map(String.init) else {
            // Dynu sometimes answers "nochg" with no address; that is no change.
            return finish("\(state.lastIP.isEmpty ? "?" : state.lastIP)  unchanged", log: false)
        }
        if ip != state.lastIP {
            let was = state.lastIP.isEmpty ? "?" : state.lastIP
            state.lastIP = ip; state.lastChange = now
            return finish("\(ip)  CHANGED from \(was)")
        }
        return finish("\(ip)  unchanged", log: false)     // an unchanged IP is not logged
    case "badauth":  return finish("ERROR: bad authentication (check username/password)")
    case "notfqdn":  return finish("ERROR: hostname not a valid FQDN")
    case "nohost":   return finish("ERROR: no such hostname on account")
    case "abuse":    return finish("ERROR: account blocked for abuse")
    default:         return finish("ERROR: Dynu said \"\(body)\"")
    }
}

// MARK: launch agent

func installAgent(minutes: Int) {
    let exe = Bundle.main.executablePath ?? "/Applications/DNSUpdater.app/Contents/MacOS/DNSUpdater"
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exe, "--update"],
        "RunAtLoad": true,
        "StartInterval": max(1, minutes) * 60,
        "StandardOutPath": supportDir.appendingPathComponent("agent.log").path,
        "StandardErrorPath": supportDir.appendingPathComponent("agent.log").path,
    ]
    ensureSupportDir()
    try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    (plist as NSDictionary).write(to: agentURL, atomically: true)
    let uid = String(getuid())
    func launchctl(_ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    launchctl(["bootout", "gui/\(uid)/\(agentLabel)"])
    launchctl(["bootstrap", "gui/\(uid)", agentURL.path])
}

// MARK: windows

final class LogWindow: NSObject {
    let window: NSWindow
    let text = NSTextView()
    let changesOnly = NSButton(checkboxWithTitle: "Changes and errors only", target: nil, action: nil)
    var timer: Timer?
    var lastShown = ""

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "DNSUpdater — IP log"
        window.minSize = NSSize(width: 340, height: 240)
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34, width: 780, height: 446))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        content.addSubview(scroll)
        changesOnly.frame = NSRect(x: 12, y: 6, width: 200, height: 22)
        changesOnly.autoresizingMask = [.maxXMargin, .maxYMargin]
        changesOnly.state = .on
        changesOnly.target = self; changesOnly.action = #selector(refresh)
        content.addSubview(changesOnly)
        let open = NSButton(title: "Open Log", target: self, action: #selector(openFile))
        open.frame = NSRect(x: 780 - 100, y: 4, width: 90, height: 26)
        open.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(open)
    }

    /// The screen ExpressVPN's main window is on (its saved frame), else the main screen.
    func expressVPNScreen() -> NSScreen {
        CFPreferencesAppSynchronize("com.expressvpn.ExpressVPN" as CFString)
        if let str = CFPreferencesCopyAppValue("NSWindow Frame MainWindow" as CFString,
                                               "com.expressvpn.ExpressVPN" as CFString) as? String {
            let n = str.split(separator: " ").compactMap { Double($0) }
            if n.count >= 4 {
                let centre = NSPoint(x: n[0] + n[2] / 2, y: n[1] + n[3] / 2)
                if let s = NSScreen.screens.first(where: { $0.frame.contains(centre) || $0.visibleFrame.contains(centre) }) { return s }
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    static let frameKey = "DNSUpdaterLogFrame"

    /// Where you left it: the saved frame, wherever that is, as long as it is
    /// still on a connected screen. The first time (or if that screen is gone)
    /// it opens centred on ExpressVPN's screen.
    func placeAtStartup() {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let r = NSRectFromString(saved)
            if r.width >= 340, r.height >= 240,
               NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) }) {
                window.setFrame(r, display: true)
                observeFrame()
                return
            }
        }
        let vis = expressVPNScreen().visibleFrame
        let size = NSSize(width: min(780, vis.width), height: min(480, vis.height))
        window.setFrame(NSRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        observeFrame()
    }

    func observeFrame() {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let w = self?.window else { return }
                UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: LogWindow.frameKey)
            }
        }
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            if self?.window.isVisible == true { self?.refresh() }
        }
    }

    @objc func refresh() {
        guard let all = try? String(contentsOf: historyURL, encoding: .utf8) else {
            text.string = "No updates recorded yet."; return
        }
        var lines = all.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if changesOnly.state == .on { lines = lines.filter { $0.contains("CHANGED") || $0.contains("ERROR") } }
        let shown = lines.suffix(3000).joined(separator: "\n")
        if shown == lastShown { return }
        lastShown = shown
        let clip = text.enclosingScrollView!.contentView
        let atBottom = clip.bounds.maxY >= (text.frame.height - 24)
        text.string = shown.isEmpty ? "Nothing to show." : shown
        if atBottom { text.scrollToEndOfDocument(nil) }
    }

    @objc func openFile() { NSWorkspace.shared.open(historyURL) }
}

final class SettingsWindow: NSObject {
    let window: NSWindow
    let user = NSTextField(), pass = NSSecureTextField(), host = NSTextField()
    let interval = NSPopUpButton()
    let onSave: () -> Void
    static let choices = [1, 2, 5, 10, 15, 30, 60]

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "DNSUpdater Settings"
        window.isReleasedWhenClosed = false
        func row(_ label: String, _ field: NSView, _ y: CGFloat) {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 16, y: y + 3, width: 110, height: 20); l.alignment = .right
            field.frame = NSRect(x: 134, y: y, width: 270, height: 24)
            window.contentView!.addSubview(l); window.contentView!.addSubview(field)
        }
        row("Dynu username", user, 184)
        row("Password", pass, 150)
        row("Hostname", host, 116)
        host.placeholderString = "blank = all hostnames"
        pass.placeholderString = "leave blank to keep the saved one"
        row("Check every", interval, 82)
        interval.addItems(withTitles: Self.choices.map { $0 == 1 ? "1 minute" : "\($0) minutes" })
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"; save.frame = NSRect(x: 316, y: 16, width: 88, height: 30)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x: 222, y: 16, width: 88, height: 30)
        window.contentView!.addSubview(save); window.contentView!.addSubview(cancel)
    }

    func show() {
        let c = loadConfig()
        user.stringValue = c.username; pass.stringValue = ""; host.stringValue = c.hostname
        let idx = Self.choices.firstIndex(of: c.intervalMinutes) ?? 2
        interval.selectItem(at: idx)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func save() {
        var c = loadConfig()
        c.username = user.stringValue.trimmingCharacters(in: .whitespaces)
        c.hostname = host.stringValue.trimmingCharacters(in: .whitespaces)
        if !pass.stringValue.isEmpty { c.passwordMD5 = md5(pass.stringValue) }
        c.intervalMinutes = Self.choices[max(0, interval.indexOfSelectedItem)]
        saveConfig(c)
        installAgent(minutes: c.intervalMinutes)
        window.orderOut(nil)
        onSave()
    }
    @objc func cancel() { window.orderOut(nil) }
}

// MARK: the menu-bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let ipItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let checkItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let logWin = LogWindow()
    lazy var settingsWin = SettingsWindow { [weak self] in self?.refreshMenu() }

    var store: SCDynamicStore?
    var debounce: Timer?

    /// React to network changes (a VPN coming up or going down, a new location)
    /// without waiting for the next scheduled check.
    func watchNetwork() {
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        guard let st = SCDynamicStoreCreate(nil, "DNSUpdater" as CFString, { _, _, info in
            guard let info = info else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                me.debounce?.invalidate()
                me.debounce = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in me.updateNow() }
            }
        }, &ctx) else { return }
        SCDynamicStoreSetNotificationKeys(st, nil,
            ["State:/Network/Global/IPv4", "State:/Network/Interface/.*/IPv4"] as CFArray)
        if let src = SCDynamicStoreCreateRunLoopSource(nil, st, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        store = st
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        _ = loadConfig()
        // The log starts empty every time the app starts (the 5-minute background
        // check, which is a separate run, never clears it).
        ensureSupportDir()
        try? "".write(to: historyURL, atomically: true, encoding: .utf8)
        watchNetwork()                       // brings DynuUpdater's settings and log across, once
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            if let img = NSImage(systemSymbolName: "network", accessibilityDescription: "DNSUpdater") {
                img.isTemplate = true; b.image = img
            } else { b.title = "DNS" }
        }
        let menu = NSMenu(); menu.delegate = self
        ipItem.isEnabled = false; checkItem.isEnabled = false
        menu.addItem(ipItem); menu.addItem(checkItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Update Now", action: #selector(updateNow), keyEquivalent: "u").target = self
        menu.addItem(withTitle: "Show IP Log…", action: #selector(showLog), keyEquivalent: "l").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DNSUpdater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refreshMenu()
        logWin.placeAtStartup()
        logWin.show()                          // shown at login, on ExpressVPN's screen
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    // Closing the log window must not quit; clicking the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { logWin.show() }
        return true
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show IP Log…", action: #selector(showLog), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DNSUpdater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    func refreshMenu() {
        let s = loadState()
        ipItem.title = s.lastIP.isEmpty ? "IP: not yet known" : "IP: \(s.lastIP)"
        checkItem.title = s.lastCheck.isEmpty ? "No update yet" : "Last check: \(s.lastCheck)  —  \(s.lastStatus.hasPrefix("ERROR") ? s.lastStatus : "ok")"
        item.button?.toolTip = ipItem.title
    }

    @objc func updateNow() {
        DispatchQueue.global().async { _ = runUpdate(); DispatchQueue.main.async { self.refreshMenu(); if self.logWin.window.isVisible { self.logWin.refresh() } } }
    }
    @objc func showLog() { logWin.show() }
    @objc func showSettings() { settingsWin.show() }
}

// MARK: entry point

let args = CommandLine.arguments
if args.contains("--update") {
    let line = runUpdate()
    print(line)
    exit(line.hasPrefix("ERROR") ? 1 : 0)
} else if args.contains("--install-agent") {
    let c = loadConfig()
    installAgent(minutes: c.intervalMinutes)
    print("agent installed, every \(c.intervalMinutes) min")
    exit(0)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)       // a Dock icon, so macOS can assign the app to a desktop
    app.run()
}
