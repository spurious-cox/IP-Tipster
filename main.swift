// DNSUpdater 1.0.0 — keeps a Dynu dynamic-DNS hostname pointed at this Mac,
// and keeps a running transcript of every IP address change.
//   DNSUpdater            menu-bar app: IP log, Update Now, Settings
//   DNSUpdater --update   one headless update (what the launch agent runs)
//   DNSUpdater --install-agent   write and load the launch agent
import Cocoa
import CryptoKit

let appVersion = "1.0.0"
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

struct State: Codable { var lastIP = ""; var lastChange = ""; var lastCheck = ""; var lastStatus = "" }

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

// MARK: the update

/// One update call. Returns the line for the log and whether it was a success.
@discardableResult
func runUpdate() -> String {
    let cfg = loadConfig()
    var state = loadState()
    let now = stamp.string(from: Date())
    func finish(_ text: String) -> String {
        appendHistory("\(now)  \(text)")
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
        let ip = body.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
        if ip != state.lastIP {
            let was = state.lastIP.isEmpty ? "?" : state.lastIP
            state.lastIP = ip; state.lastChange = now
            return finish("\(ip)  CHANGED from \(was)")
        }
        return finish("\(ip)  unchanged")
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
    let changesOnly = NSButton(checkboxWithTitle: "Only changes and errors", target: nil, action: nil)
    var timer: Timer?
    var lastShown = ""

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "DNSUpdater — IP log"
        window.minSize = NSSize(width: 520, height: 240)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DNSUpdaterLog")
        if !window.setFrameUsingName("DNSUpdaterLog") { window.center() }
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
        changesOnly.frame = NSRect(x: 12, y: 6, width: 260, height: 22)
        changesOnly.autoresizingMask = [.maxXMargin, .maxYMargin]
        changesOnly.state = .on
        changesOnly.target = self; changesOnly.action = #selector(refresh)
        content.addSubview(changesOnly)
        let open = NSButton(title: "Open Log File", target: self, action: #selector(openFile))
        open.frame = NSRect(x: 780 - 132, y: 4, width: 120, height: 26)
        open.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(open)
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

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = loadConfig()                       // brings DynuUpdater's settings and log across, once
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
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

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
    app.setActivationPolicy(.accessory)
    app.run()
}
