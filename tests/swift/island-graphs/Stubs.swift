import AppKit
import Foundation

// The few app symbols src/GraphStudioModel.swift and src/GraphWords.swift reach for, so the
// harness compiles the app's own graph model as it is. PongStatus is the real one (run-island-graphs.sh
// slices it out of src/PongTokens.swift); PongUI's time words are faithful copies of the real ones
// (src/PongComponents.swift); the colours are placeholders (nothing here draws).
//
// Nothing here reads ~/.pong: Pong.stateDir is a temp folder, the team list is empty, and which
// teams are up is set by the harness itself.

enum Pong {
    static var stateDir: String { NSTemporaryDirectory() + "island-graphs-harness-unset" }
    static var extraPath: String { "/usr/bin:/bin" }
}

enum UIPreview {
    static let env: [String: String] = [:]
    static let isOn = false
}

enum PairState {
    static func loadPairsDb() -> [String: Any] { [:] }
}

/// The app asks the runner's last look (or the team list) which teams are up; here a check says.
enum SchedulesPageView {
    static var runningTeams: Set<String> = []
}

enum PongColor {
    static let you = NSColor.systemOrange
    static let live = NSColor.systemTeal
    static let fail = NSColor.systemRed
    static let textPrimary = NSColor.white
    static let textSecondary = NSColor.lightGray
    static let textTertiary = NSColor.gray
}

enum PongUI {
    static func ago(_ t: Double, now: Double = Date().timeIntervalSince1970) -> String {
        guard t > 0 else { return "" }
        let s = max(0, Int(now - t))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 86_400 {
            let h = s / 3600, m = (s % 3600) / 60
            return m == 0 || h >= 6 ? "\(h) h ago" : "\(h) h \(m) min ago"
        }
        return dayStamp(t)
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func dayStamp(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
