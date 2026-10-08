import AppKit
import Foundation

// Stubs for the six-and-change symbols CronSchedule reaches for. Everything
// here is either a faithful copy of the real implementation (loadJSON /
// writeJSON / pongPrefix) or a recorder (log / sh), so what the harness sees is
// what the app would emit.
//
// Pong.stateDir points at a TEMP DIR. Nothing in this harness may read or write
// ~/.pong/cron-schedules.json or fire a live cron.

enum Pong {
    /// Set by the harness to a fresh temp dir. Never ~/.pong.
    static var stateDirOverride = NSTemporaryDirectory() + "cron-harness-unset"
    static var stateDir: String { stateDirOverride }

    // --- recorders -------------------------------------------------------
    static var logLines: [String] = []
    static var shScripts: [String] = []
    /// What the fake shell answers. Default: the control plane refused.
    static var shResponder: (String) -> String = { _ in "" }

    static func log(_ msg: String) {
        logLines.append(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func sh(_ script: String) -> String {
        shScripts.append(script)
        return shResponder(script)
    }

    // --- faithful copies from src/MenuBarApp.swift ------------------------
    static func loadJSON(_ path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    static func writeJSON(_ path: String, _ dict: [String: Any]) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func reset() {
        logLines = []
        shScripts = []
        shResponder = { _ in "" }
    }
}

enum SessionArchive {
    /// Copy of src/SessionArchive.swift pongPrefix() minus the app-bundle probe
    /// (there is no bundle in a command-line harness).
    static func pongPrefix() -> String {
        let home = NSHomeDirectory()
        return """
        export PATH="\(home)/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        export PYTHONPATH="\(home)/.pong/lib${PYTHONPATH:+:$PYTHONPATH}"
        """
    }
}

enum PairState {
    static var activePath: String { Pong.stateDir + "/active-pair.json" }
    static func listPairs() -> [String] { [] }
    static func loadPairsDb() -> [String: Any] { Pong.loadJSON(Pong.stateDir + "/pairs.json") }
}

enum Workers {
    static func list(from entry: [String: Any]) -> [[String: Any]] {
        (entry["workers"] as? [[String: Any]]) ?? []
    }
}

struct Seat3D {
    let id: String
    let role: String
}

enum PongTheme {
    static let blue = NSColor.systemBlue
    static let violet = NSColor.systemPurple
    static let amber = NSColor.systemOrange
    static let magenta = NSColor.systemPink
}
