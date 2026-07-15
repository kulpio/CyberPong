import AppKit
import Foundation

/// Native menu bar for Hermes_Pairing.
/// Custom bolt icon; blue↔orange glow when any hermes-pair session is active.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var projectRoot: String = ""
    private var timer: Timer?
    private var glowPhase: CGFloat = 0
    private var boltBlue: NSImage?
    private var boltOrange: NSImage?
    private var boltTemplate: NSImage?
    private var hasActivePair = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let marker = Bundle.main.resourcePath.map({ $0 + "/project_root" }),
           let root = try? String(contentsOfFile: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            projectRoot = root
        } else {
            projectRoot = NSString("~/DigitalBrain/Boreal/tools/hermes-claude-app").expandingTildeInPath
        }

        loadIcons()
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = boltTemplate
        button.image?.isTemplate = true
        // Fallback text if image missing
        if button.image == nil {
            button.title = "⚡"
        }
        button.toolTip = "Hermes_Pairing"
        button.appearsDisabled = false
        // Keep a strong reference so menu bar extra is not deallocated
        statusItem.isVisible = true
        rebuildMenu()

        // Poll sessions + animate glow (main runloop)
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // Defer panel so status item paints first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.openPanel()
        }
    }

    private func loadIcons() {
        let res = Bundle.main.resourcePath ?? ""
        func img(_ name: String, template: Bool, size: CGFloat = 18) -> NSImage? {
            let path = res + "/" + name
            guard let i = NSImage(contentsOfFile: path) else { return nil }
            i.size = NSSize(width: size, height: size)
            i.isTemplate = template
            return i
        }
        boltTemplate = img("menubar-template.png", template: true)
        boltBlue = img("bolt-blue.png", template: false)
        boltOrange = img("bolt-orange.png", template: false)
        // fallback SF Symbol
        if boltTemplate == nil, let sf = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Zap") {
            sf.isTemplate = true
            boltTemplate = sf
        }
    }

    private func pairSessions() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmux")
        p.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("hermes-claude") || $0.hasPrefix("hermes-pair")
        }
    }

    private func tick() {
        let sessions = pairSessions()
        let active = !sessions.isEmpty
        if active != hasActivePair {
            hasActivePair = active
            rebuildMenu()
        }
        guard let button = statusItem.button else { return }
        if active, let blue = boltBlue, let orange = boltOrange {
            glowPhase += 0.06
            if glowPhase > .pi * 2 { glowPhase -= .pi * 2 }
            // 0...1 sine blend hermes blue → claude orange
            let t = (sin(glowPhase) + 1) / 2
            button.image = blend(blue: blue, orange: orange, t: t)
            button.image?.isTemplate = false
        } else {
            button.image = boltTemplate
            button.image?.isTemplate = true
        }
    }

    private func blend(blue: NSImage, orange: NSImage, t: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            blue.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1 - t)
            orange.draw(in: rect, from: .zero, operation: .sourceOver, fraction: t)
            return true
        }
        img.isTemplate = false
        return img
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item("Open control panel", #selector(openPanel)))
        menu.addItem(.separator())

        let sessions = pairSessions()
        if sessions.isEmpty {
            let idle = NSMenuItem(title: "No active pairs", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        } else {
            for s in sessions {
                let sub = NSMenu()
                let rejoin = NSMenuItem(title: "Bring to front", action: #selector(rejoinNamed(_:)), keyEquivalent: "")
                rejoin.target = self
                rejoin.representedObject = s
                sub.addItem(rejoin)
                let kill = NSMenuItem(title: "Kill pair", action: #selector(killNamed(_:)), keyEquivalent: "")
                kill.target = self
                kill.representedObject = s
                sub.addItem(kill)
                let row = NSMenuItem(title: "● \(s)", action: nil, keyEquivalent: "")
                row.submenu = sub
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("New pair", #selector(newPair)))
        menu.addItem(item("Refresh", #selector(refreshMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hermes_Pairing", #selector(quit)))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func refreshMenu() { rebuildMenu() }

    @objc func openPanel() {
        let py = "\(projectRoot)/venv/bin/python"
        let scriptInstalled = "/Applications/Hermes_Pairing.app/Contents/Resources/hermes_pairing.py"
        let script = FileManager.default.fileExists(atPath: scriptInstalled)
            ? scriptInstalled : "\(projectRoot)/src/hermes_pairing.py"
        let exe = FileManager.default.isExecutableFile(atPath: py) ? py : "/usr/bin/python3"
        // avoid stacking many windows
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "hermes_pairing.py --window-only"]
        try? pkill.run()
        pkill.waitUntilExit()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = [script, "--window-only"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    @objc func newPair() {
        let sessions = pairSessions()
        var n = 1
        var name = "hermes-pair-1"
        while sessions.contains(name) || (n == 1 && sessions.contains("hermes-claude")) {
            n += 1
            name = "hermes-pair-\(n)"
        }
        // migrate: first pair can still be hermes-claude for compat
        if sessions.isEmpty { name = "hermes-claude" }
        runShell("""
        tmux new-session -d -s \(name) -n Hermes
        tmux new-window -t \(name):1 -n Claude
        tmux send-keys -t \(name):1 'cd ~ && claude' Enter
        osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t \(name)"'
        """)
        notify("New pair", name)
        rebuildMenu()
    }

    @objc func rejoinNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runShell("""
        osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t \(name)"'
        """)
    }

    @objc func killNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runShell("tmux kill-session -t \(name) 2>/dev/null || true")
        notify("Killed", name)
        rebuildMenu()
    }

    @objc func quit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "hermes_pairing.py"]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }

    private func runShell(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func notify(_ title: String, _ msg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"\(title)\""]
        try? p.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
