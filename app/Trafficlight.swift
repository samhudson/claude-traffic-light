// Trafficlight: one light per AI agent session, in the macOS menu bar.
//
// A native menu bar app (no Dock icon). The status item shows one dot per
// session; the menu lists them; Settings chooses which agents get lights.
// It holds no logic of its own: sessions come from libexec/trafficlight-state
// and changes go through bin/trafficlight, both covered by the tests.
//
//   Trafficlight                 run in the menu bar
//   trafficlight://settings      open Settings (add ?welcome=1 on first run)
//   Trafficlight --render DIR    write the menu bar image and Settings to DIR as PNG
//   Trafficlight --icon DIR      write an iconset to DIR (for the app icon)

import AppKit
import SwiftUI

let lampRed = Color(red: 1.0, green: 0.27, blue: 0.23)
let lampAmber = Color(red: 1.0, green: 0.84, blue: 0.04)
let lampGreen = Color(red: 0.2, green: 0.84, blue: 0.29)
let night = LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.14, green: 0.15, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
let settingsSize = CGSize(width: 680, height: 640)

// MARK: - Engine bridge

enum Engine {
    static let libexec = Bundle.main.bundleURL.deletingLastPathComponent()
    static var cli: URL {
        if let p = ProcessInfo.processInfo.environment["TRAFFICLIGHT_CLI"] { return URL(fileURLWithPath: p) }
        return libexec.deletingLastPathComponent().appendingPathComponent("bin/trafficlight")
    }
    static var stateScript: URL { libexec.appendingPathComponent("trafficlight-state") }
    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".trafficlight/sessions")

    static func run(_ exe: URL, _ args: [String] = []) async -> (Int32, String, String) {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = exe; p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { done.resume(returning: (127, "", error.localizedDescription)); return }
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                done.resume(returning: (p.terminationStatus, o, e))
            }
        }
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "==> ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sessions (menu bar)

struct Row: Decodable {
    let agent: String, who: String, status: String, label: String, name: String, cwd: String
    let updated: Double
    let detail: String?
}
struct SessionState: Decodable {
    let now: Double
    let rows: [Row]
    let counts: [String: Int]
}

func lampColor(_ status: String) -> NSColor {
    switch status {
    case "working": return NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    case "waiting": return NSColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 1)
    case "error": return NSColor(white: 0.45, alpha: 1)
    default: return NSColor(red: 0.2, green: 0.8, blue: 0.29, alpha: 1)
    }
}

enum StatusArt {
    /// One dot per session, or a small traffic-light outline when there are none.
    static func image(for rows: [Row]) -> NSImage {
        if rows.isEmpty { return idle() }
        let shown = Array(rows.prefix(8)), d: CGFloat = 9, gap: CGFloat = 4
        let width = CGFloat(shown.count) * d + CGFloat(shown.count - 1) * gap
        let img = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            for (i, r) in shown.enumerated() {
                lampColor(r.status).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(i) * (d + gap), y: (18 - d) / 2, width: d, height: d)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static func idle() -> NSImage {
        let img = NSImage(size: NSSize(width: 9, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: 7.5, height: 16.5), xRadius: 2.5, yRadius: 2.5)
            body.lineWidth = 1.3; body.stroke()
            NSColor.black.setFill()
            for y in [3.0, 7.75, 12.5] { NSBezierPath(ovalIn: NSRect(x: 2.5, y: y, width: 4, height: 2.75)).fill() }
            return true
        }
        img.isTemplate = true   // adapts to light and dark menu bars
        return img
    }

    static func dot(_ status: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            lampColor(status).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 9, height: 9)).fill()
            return true
        }
        return img
    }
}

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var state = SessionState(now: 0, rows: [], counts: [:])
    var watcher: DispatchSourceFileSystemObject?
    var timer: Timer?
    var pending = false
    let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        super.init()
        item.button?.image = StatusArt.idle()
        item.button?.toolTip = "trafficlight"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    /// Hooks write a file per session; refresh as soon as the folder changes.
    func watch() {
        try? FileManager.default.createDirectory(at: Engine.sessionsDir, withIntermediateDirectories: true)
        let fd = open(Engine.sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in Task { @MainActor in self?.refreshSoon() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor in self?.pending = false; self?.refresh() }
        }
    }

    func refresh() {
        Task {
            let (status, out, _) = await Engine.run(Engine.stateScript)
            guard status == 0, let data = out.data(using: .utf8),
                  let s = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
            state = s
            item.button?.image = StatusArt.image(for: s.rows)
            item.button?.toolTip = s.rows.isEmpty ? "trafficlight: no sessions" : summary(s)
        }
    }

    func summary(_ s: SessionState) -> String {
        let parts: [(String, String)] = [("waiting", "needs you"), ("working", "working"), ("error", "stopped"), ("done", "done")]
        return parts.compactMap { k, label in s.counts[k].map { "\($0) \(label)" } }.joined(separator: " · ")
    }

    func ago(_ t: Double) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970 - t))
        return s < 60 ? "just now" : s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago"
    }

    func menuNeedsUpdate(_ menu: NSMenu) { build() }

    func build() {
        menu.removeAllItems()
        let head = NSMenuItem()
        let title = NSMutableAttributedString(string: "trafficlight", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if !state.rows.isEmpty {
            title.append(NSAttributedString(string: "   " + summary(state),
                                            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        head.attributedTitle = title; head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        if state.rows.isEmpty {
            let none = NSMenuItem(title: "No agent sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            let hint = NSMenuItem()
            hint.attributedTitle = NSAttributedString(string: "Start one and its light appears here",
                                                      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            hint.isEnabled = false
            menu.addItem(hint)
        }
        for r in state.rows {
            let m = NSMenuItem(title: r.name, action: #selector(openFolder(_:)), keyEquivalent: "")
            m.target = self
            m.image = StatusArt.dot(r.status)
            let t = NSMutableAttributedString(string: r.name + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let sub = "\(r.who) · \(r.label)" + (r.detail.map { " (\($0))" } ?? "") + " · \(ago(r.updated))"
            t.append(NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            m.attributedTitle = t
            m.representedObject = r.cwd
            m.toolTip = r.cwd
            m.isEnabled = !r.cwd.isEmpty
            menu.addItem(m)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit trafficlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func openFolder(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String, !p.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }
    @objc func showSettings() { openSettings() }
}

// MARK: - Settings (which agents get lights)

struct Agent: Identifiable, Decodable {
    let id: String, name: String
    var detected: Bool, installed: Bool
    var symbol: String {
        switch id {
        case "claude": return "sparkle"
        case "codex": return "terminal.fill"
        case "gemini": return "diamond.fill"
        case "cursor": return "cursorarrow.rays"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    @Published var welcome = false
    @Published var agents: [Agent] = []
    @Published var busy: String?
    @Published var error: String?
    @Published var changed = false

    func load() async {
        let (status, out, _) = await Engine.run(Engine.cli, ["_info"])
        guard status == 0, let data = out.data(using: .utf8),
              let list = try? JSONDecoder().decode([Agent].self, from: data) else {
            error = "Couldn't read your agents. Is trafficlight installed?"; return
        }
        agents = list
    }

    func set(_ agent: Agent, on: Bool) async {
        busy = agent.id; error = nil
        defer { busy = nil }
        let (status, _, err) = await Engine.run(Engine.cli, [on ? "install" : "uninstall", agent.id, "--no-app"])
        if status != 0 { error = Engine.clean(err).isEmpty ? "That didn't work (code \(status))." : Engine.clean(err) }
        else { changed = true }
        await load()
    }
}

struct TrafficLightArt: View {
    var fixed: Int? = nil   // 0 red, 1 amber, 2 green, for still renders
    var body: some View {
        TimelineView(.animation) { ctx in
            let lit = fixed ?? Self.lit(ctx.date)
            Canvas { gc, size in Self.draw(gc, size, lit: lit) }
        }
        .aspectRatio(0.5, contentMode: .fit)
    }
    static func lit(_ date: Date) -> Int {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
        return t < 0.33 ? 0 : (t < 0.66 ? 1 : 2)
    }
    static func draw(_ gc: GraphicsContext, _ size: CGSize, lit: Int) {
        let u = size.width / 100
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
        gc.fill(Path(r(44, 160, 12, 40)), with: .color(Color(red: 0.24, green: 0.26, blue: 0.32)))
        let housing = Path(roundedRect: r(14, 4, 72, 160), cornerRadius: 20 * u)
        gc.fill(housing, with: .color(Color(red: 0.2, green: 0.22, blue: 0.27)))
        gc.stroke(housing, with: .color(.white.opacity(0.14)), lineWidth: 1.5 * u)
        let colors = [lampRed, lampAmber, lampGreen]
        for i in 0..<3 {
            let y = 14 + Double(i) * 50
            gc.fill(Path(roundedRect: r(20, y - 4, 60, 8), cornerRadius: 3 * u), with: .color(Color(white: 0.08)))
            let lens = r(26, y + 4, 48, 34), on = i == lit
            if on { gc.fill(Path(ellipseIn: lens.insetBy(dx: -8 * u, dy: -8 * u)), with: .color(colors[i].opacity(0.28))) }
            gc.fill(Path(ellipseIn: CGRect(x: lens.midX - 17 * u, y: lens.midY - 17 * u, width: 34 * u, height: 34 * u)),
                    with: .color(on ? colors[i] : colors[i].opacity(0.16)))
        }
    }
}

struct AgentRow: View {
    let agent: Agent, busy: Bool
    let toggle: (Bool) -> Void
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: agent.symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(agent.installed ? Color.primary : .secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(.system(size: 14, weight: .semibold))
                Text(agent.installed ? "Lights on. New sessions show in your menu bar."
                     : agent.detected ? "Found on this Mac. Turn on to show its sessions."
                     : "Not found on this Mac. You can turn it on before you install it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if busy { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { agent.installed }, set: toggle)).toggleStyle(.switch).labelsHidden().disabled(busy)
        }
        .padding(.vertical, 13).padding(.horizontal, 18)
    }
}

struct SettingsView: View {
    @ObservedObject var s: Settings
    var still = false
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                night
                HStack(spacing: 32) {
                    TrafficLightArt(fixed: still ? 1 : nil).frame(height: 140)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("trafficlight").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                        Text("One light per AI agent session, so you can see\nwho's working, who needs you, and who's done.")
                            .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.72)).lineSpacing(2)
                        HStack(spacing: 18) {
                            Label("working", systemImage: "circle.fill").foregroundStyle(lampRed)
                            Label("needs you", systemImage: "circle.fill").foregroundStyle(lampAmber)
                            Label("done", systemImage: "circle.fill").foregroundStyle(lampGreen)
                        }
                        .font(.system(size: 12, weight: .medium)).padding(.top, 6)
                    }
                    Spacer()
                }
                .padding(.horizontal, 44).padding(.vertical, 28)
            }
            .frame(height: 210)

            VStack(alignment: .leading, spacing: 14) {
                if s.welcome {
                    Label("Welcome. Pick the agents you want lights for. The ones on this Mac are already on.",
                          systemImage: "hand.wave.fill")
                        .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.primary)
                        .padding(.bottom, 4)
                }
                Text("AGENTS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(s.agents.enumerated()), id: \.element.id) { i, agent in
                        AgentRow(agent: agent, busy: s.busy == agent.id) { on in Task { await s.set(agent, on: on) } }
                        if i < s.agents.count - 1 { Divider().padding(.leading, 62) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                Group {
                    if let e = s.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(lampRed)
                    } else {
                        Text(s.changed || s.welcome ? "Restart running agent sessions so they pick up the change."
                                                    : "Cursor and Copilot can't report \"needs you\", so they show red and green only.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12)).padding(.top, 2)
            }
            .padding(.horizontal, 40).padding(.top, 28)
            Spacer(minLength: 20)
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: settingsSize.width, height: settingsSize.height)
        .task { if !still { await s.load() } }
    }
}

// MARK: - Rendering (for review and the app icon)

@MainActor
enum Renderer {
    static func png<V: View>(_ view: V, size: CGSize) -> Data? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func review(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = Settings()
        s.agents = [
            Agent(id: "claude", name: "Claude Code", detected: true, installed: true),
            Agent(id: "codex", name: "Codex", detected: true, installed: true),
            Agent(id: "gemini", name: "Gemini CLI", detected: false, installed: false),
            Agent(id: "cursor", name: "Cursor", detected: true, installed: true),
            Agent(id: "copilot", name: "Copilot (VS Code)", detected: false, installed: false),
        ]
        if let d = png(SettingsView(s: s, still: true).background(Color(nsColor: .windowBackgroundColor)), size: settingsSize) {
            try? d.write(to: dir.appendingPathComponent("settings.png"))
        }
        s.welcome = true
        if let d = png(SettingsView(s: s, still: true).background(Color(nsColor: .windowBackgroundColor)), size: settingsSize) {
            try? d.write(to: dir.appendingPathComponent("settings-welcome.png"))
        }
        // Menu bar images at 4x for review: idle, and a few sessions.
        let rows = ["waiting", "working", "working", "done"].map {
            Row(agent: "claude", who: "Claude Code", status: $0, label: $0, name: "x", cwd: "", updated: 0, detail: nil)
        }
        for (name, img) in [("menubar-idle", StatusArt.idle()), ("menubar-sessions", StatusArt.image(for: rows))] {
            let size = NSSize(width: img.size.width * 4, height: img.size.height * 4)
            let out = NSImage(size: size, flipped: false) { r in
                NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
                img.draw(in: r); return true
            }
            if let t = out.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let p = rep.representation(using: .png, properties: [:]) {
                try? p.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }

    static func iconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tile = ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous).fill(night)
            TrafficLightArt(fixed: 2).padding(.vertical, 120)
        }
        .padding(90)
        guard let data = png(tile, size: CGSize(width: 1024, height: 1024)), let image = NSImage(data: data) else { return }
        for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                           (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
            let out = NSImage(size: NSSize(width: px, height: px))
            out.lockFocus(); image.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); out.unlockFocus()
            if let t = out.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let p = rep.representation(using: .png, properties: [:]) {
                try? p.write(to: dir.appendingPathComponent("icon_\(name).png"))
            }
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var bar: MenuBar?
    let settings = Settings()
    var window: NSWindow?

    func applicationWillFinishLaunching(_ note: Notification) {
        // trafficlight://settings[?welcome=1] reaches the running app.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            Renderer.review(to: URL(fileURLWithPath: args[i + 1])); NSApp.terminate(nil); return
        }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            Renderer.iconset(to: URL(fileURLWithPath: args[i + 1])); NSApp.terminate(nil); return
        }
        // One copy only: if another is already in the menu bar, leave it be.
        let mine = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != mine.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        bar = MenuBar(openSettings: { [weak self] in self?.showSettings(welcome: false) })
        if args.contains("--welcome") { showSettings(welcome: true) } else if args.contains("--settings") { showSettings(welcome: false) }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s),
              url.host == "settings" else { return }
        showSettings(welcome: (url.query ?? "").contains("welcome=1"))
    }

    func showSettings(welcome: Bool) {
        settings.welcome = welcome
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: settingsSize),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isMovableByWindowBackground = true
            w.title = "Trafficlight Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(s: settings, close: { [weak w] in w?.close() }))
            w.center()
            window = w
        }
        Task { await settings.load() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing Settings leaves the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

@main @MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only: never in the Dock
        app.run()
    }
}
