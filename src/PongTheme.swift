import AppKit

/// Dual-accent orchestration UI.
/// Electric blue = orchestrator working · Magenta = secondary energy · Orange = human needed.
enum PongTheme {
    // Void
    static let bg = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)
    static let bgElevated = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)
    static let bgHover = NSColor(calibratedRed: 0.14, green: 0.13, blue: 0.20, alpha: 1)
    static let bgInput = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.11, alpha: 1)
    static let bgFooter = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1)
    static let bgMetric = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.14, alpha: 1)

    // Text
    static let textPrimary = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let textSecondary = NSColor(calibratedWhite: 0.58, alpha: 1)
    static let textTertiary = NSColor(calibratedWhite: 0.40, alpha: 1)

    // Borders
    static let border = NSColor(calibratedWhite: 1, alpha: 0.07)
    static let borderStrong = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let borderAccent = NSColor(calibratedRed: 0.25, green: 0.75, blue: 1.0, alpha: 0.45)

    // Accents — electric blue + magenta (Image #3 energy)
    static let blue = NSColor(calibratedRed: 0.15, green: 0.78, blue: 1.0, alpha: 1)       // orchestrator live
    static let blueSoft = NSColor(calibratedRed: 0.15, green: 0.78, blue: 1.0, alpha: 0.18)
    static let blueGlow = NSColor(calibratedRed: 0.15, green: 0.78, blue: 1.0, alpha: 0.45)
    static let magenta = NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.75, alpha: 1)   // secondary
    static let magentaSoft = NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.75, alpha: 0.16)
    static let orange = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.18, alpha: 1)     // human needed
    static let orangeSoft = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.18, alpha: 0.18)

    // Legacy aliases used across UI
    static let accent = blue
    static let accentSoft = blueSoft
    static let accentGlow = blueGlow
    static let accentInk = NSColor.white
    static let live = blue
    static let liveSoft = blueSoft
    static let warn = orange
    static let warnSoft = orangeSoft
    static let danger = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.40, alpha: 1)
    static let idle = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let idleSoft = NSColor(calibratedWhite: 0.40, alpha: 0.12)

    static let tabSelected = blueSoft
    static let tabIdle = NSColor.clear

    static let radiusCard: CGFloat = 16
    static let radiusPill: CGFloat = 8
    static let radiusBtn: CGFloat = 10

    enum SystemSignal {
        case idle
        case orchestratorWorking  // blue glow
        case humanNeeded          // orange glow
    }

    static func applyCard(_ v: NSView, elevated: Bool = true, accentBorder: Bool = false) {
        v.wantsLayer = true
        v.layer?.backgroundColor = (elevated ? bgElevated : bgInput).cgColor
        v.layer?.cornerRadius = radiusCard
        v.layer?.borderWidth = 1
        v.layer?.borderColor = (accentBorder ? borderAccent : border).cgColor
    }

    static func applyMetricCard(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.backgroundColor = bgMetric.cgColor
        v.layer?.cornerRadius = 14
        v.layer?.borderWidth = 1
        v.layer?.borderColor = border.cgColor
    }

    static func applyFloating(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.backgroundColor = bgElevated.withAlphaComponent(0.94).cgColor
        v.layer?.cornerRadius = 18
        v.layer?.borderWidth = 1
        v.layer?.borderColor = border.cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.45
        v.layer?.shadowRadius = 24
        v.layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func statusKind(_ raw: String) -> (label: String, color: NSColor, soft: NSColor) {
        let t = raw.lowercased()
        if t.contains("human") || t.contains("takeover") || t.contains("ask") || t.contains("wait") {
            return ("HUMAN", orange, orangeSoft)
        }
        if t.contains("busy") || t.contains("running") || t.contains("live") || t.contains("notified") || t.contains("active") {
            return ("RUNNING", blue, blueSoft)
        }
        if t.contains("hide") || t.contains("hidden") {
            return ("HIDDEN", orange, orangeSoft)
        }
        if t.contains("fail") || t.contains("error") {
            return ("FAILED", danger, NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.40, alpha: 0.15))
        }
        if t.contains("job") {
            return ("ACTIVE", magenta, magentaSoft)
        }
        return ("IDLE", idle, idleSoft)
    }

    /// Dual-dot menu bar icon (blue = orchestrator, orange/magenta = human/secondary).
    static func menuIcon(signal: SystemSignal, size: CGFloat = 18, phase: CGFloat = 1) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let r: CGFloat = size * 0.22
            let y = rect.midY
            let x1 = rect.midX - r * 1.15
            let x2 = rect.midX + r * 1.15

            func glow(_ c: NSColor, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
                let g = NSBezierPath(ovalIn: NSRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
                c.withAlphaComponent(alpha).setFill()
                g.fill()
            }

            let leftColor: NSColor
            let rightColor: NSColor
            let glowA: CGFloat
            switch signal {
            case .idle:
                leftColor = idle
                rightColor = idle
                glowA = 0
            case .orchestratorWorking:
                leftColor = blue
                rightColor = magenta.withAlphaComponent(0.85)
                glowA = 0.25 + 0.35 * phase
            case .humanNeeded:
                leftColor = blue.withAlphaComponent(0.55)
                rightColor = orange
                glowA = 0.3 + 0.4 * phase
            }

            if glowA > 0.01 {
                glow(leftColor, center: CGPoint(x: x1, y: y), radius: r * 2.2, alpha: glowA)
                glow(rightColor, center: CGPoint(x: x2, y: y), radius: r * 2.2, alpha: glowA)
            }

            leftColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x1 - r, y: y - r, width: r * 2, height: r * 2)).fill()
            rightColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x2 - r, y: y - r, width: r * 2, height: r * 2)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Derive menu signal from snapshot / pairs.
    static func signalFromState() -> SystemSignal {
        let pairs = PairState.listPairs()
        if pairs.isEmpty { return .idle }

        // Human takeover or open jobs with human status
        let snapPath = Pong.stateDir + "/snapshot.json"
        let snap = Pong.loadJSON(snapPath)
        if let teams = snap["teams"] as? [[String: Any]] {
            for t in teams {
                let workers = (t["workers"] as? [[String: Any]]) ?? []
                for w in workers {
                    let h = ((w["status_hint"] as? String) ?? "").lowercased()
                    if h.contains("human") || h.contains("takeover") { return .humanNeeded }
                }
                let open = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
                for j in open {
                    let st = ((j["status"] as? String) ?? "").lowercased()
                    if st.contains("human") { return .humanNeeded }
                    if st == "notified" || st == "running" || st == "queued" {
                        // has work — orchestrator side active
                        return .orchestratorWorking
                    }
                }
            }
        }
        // Any live team = orchestrator presence
        return .orchestratorWorking
    }
}
