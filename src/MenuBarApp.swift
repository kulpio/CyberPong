import AppKit
import Foundation

// Native menu-bar presence for Hermes_Pairing.
// Python control window is opened on demand (framework Python is flaky for status items).

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let projectRoot: String
    private let pythonApp: String

    override init() {
        // Prefer installed Resources marker; fall back to known project path
        let marker = Bundle.main.resourcePath.map { $0 + "/project_root" }
        if let marker, let root = try? String(contentsOfFile: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            projectRoot = root
        } else {
            projectRoot = NSString("~/DigitalBrain/Boreal/tools/hermes-claude-app").expandingTildeInPath
        }
        pythonApp = "/Applications/Hermes_Pairing.app"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only — no Dock clutter

        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        if let button = statusItem.button {
            // SF Symbol: reliable system lightning icon
            if let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Hermes_Pairing") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                button.image = img.withSymbolConfiguration(config)
                button.image?.isTemplate = true
            }
            // Always keep a short title so the item is never zero-width / invisible
            button.title = "⚡"
            button.toolTip = "Hermes_Pairing — Hermes ↔ Claude"
            button.appearsDisabled = false
        }

        let menu = NSMenu()
        menu.addItem(makeItem("Open control panel", #selector(openPanel)))
        menu.addItem(.separator())
        menu.addItem(makeItem("New pair", #selector(newPair)))
        menu.addItem(makeItem("Link two Terminals", #selector(linkTerminals)))
        menu.addItem(makeItem("Rejoin pair", #selector(rejoin)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Hermes_Pairing", #selector(quit)))
        statusItem.menu = menu

        // Open the control window once so the user sees something useful
        openPanel()
    }

    private func makeItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func openPanel() {
        // Launch Python UI (window) without replacing this status item process
        let py = "\(projectRoot)/venv/bin/python"
        let script = "\(projectRoot)/src/hermes_pairing.py"
        // Prefer installed resources if present
        let installed = "/Applications/Hermes_Pairing.app/Contents/Resources/hermes_pairing.py"
        let runScript = FileManager.default.fileExists(atPath: installed) ? installed : script
        let runPy: String
        if FileManager.default.isExecutableFile(atPath: py) {
            runPy = py
        } else {
            runPy = "/usr/bin/python3"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: runPy)
        task.arguments = [runScript, "--window-only"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    @objc func newPair() {
        runShell("""
        tmux kill-session -t hermes-claude 2>/dev/null || true
        tmux new-session -d -s hermes-claude -n Hermes
        tmux new-window -t hermes-claude:1 -n Claude
        tmux send-keys -t hermes-claude:1 'cd ~ && claude' Enter
        osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t hermes-claude"'
        """)
        notify("New pair", "Terminal opening…")
    }

    @objc func linkTerminals() {
        // Open control panel — linking needs the hover flow
        openPanel()
        notify("Link Terminals", "Use the control panel button")
    }

    @objc func rejoin() {
        runShell("""
        osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t hermes-claude 2>/dev/null || echo No pair — use New pair"'
        """)
        notify("Rejoin", "Bringing Terminal forward")
    }

    @objc func quit() {
        // Also stop window-only python helpers if any
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
