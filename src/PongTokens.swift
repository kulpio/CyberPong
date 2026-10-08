import AppKit

// Sodium & Neon (1.9): the one palette, type scale and spacing.
// Spec: docs/design/2026-09-redesign/design-language.md §2. Night only.
//
// One colour, one job: amber = needs you, cyan = machines at work,
// magenta = the architect, red = failed. Everything else is neutral.

private func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
             green: CGFloat((v >> 8) & 0xFF) / 255,
             blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

enum PongColor {
    // Rooms, darkest first
    static let void = hex(0x07090C)            // deck, terminals, scrims
    static let frame = hex(0x090C10)           // sidebar, rail
    static let base = hex(0x0B0F14)            // content, window bar
    static let raised = hex(0x121821)          // cards, chips
    static let overlay = hex(0x1A212C)         // popovers, ⌘K, toasts, selected row
    static let selectedMuted = hex(0x151B24)   // selection in an inactive window
    static let selectedOnOverlay = hex(0x222B38)
    static let field = hex(0x0F141B)           // text fields

    // Text
    static let textPrimary = hex(0xECE7DC)     // sodium white
    static let textSecondary = hex(0xAAB2BE)
    static let textTertiary = hex(0x8C96A5)
    static let textDisabled = hex(0x586270)
    static let terminalText = hex(0xDCE2EA)

    // States over any surface
    static let hover = hex(0xECE7DC, 0.04)
    static let pressed = hex(0xECE7DC, 0.07)

    // Lines
    static let hairline = hex(0xECE7DC, 0.08)  // dividers, never boxes
    static let mark = hex(0x3A4556)            // registration marks, idle deck edges
    static let control = hex(0x6B778B)         // field and button edges
    static let controlHover = hex(0x7D889B)
    static let controlDisabled = hex(0x2A3342)

    // The primary button ("Wallace white")
    static let ink = hex(0xECE7DC)
    static let inkHover = hex(0xF7F3EA)
    static let inkPressed = hex(0xD6D0C4)
    static let onInk = hex(0x0B0F14)

    // Secondary button
    static let secondaryFill = hex(0x161D27)
    static let secondaryHover = hex(0x1C2430)
    static let secondaryPressed = hex(0x222B38)

    // Signals: one colour, one job
    static let you = hex(0xF5A524)             // needs you, only
    static let live = hex(0x4CD6E0)            // working, links, focus
    static let architect = hex(0xFF6EC7)       // the architect, only
    static let fail = hex(0xFF7A6E)            // failed, destructive
    static let failHover = hex(0xFF8A7F)
    static let failPressed = hex(0xE86A5F)

    // Tints behind a signal
    static let tintYou = hex(0x221915)         // the question card
    static let tintFail = hex(0x231A1D)
    static let tintLive = hex(0x112126)
    static let tintArchitect = hex(0x211824)

    // Deck fog only
    static let fogTeal = hex(0x0E3B44)
    static let fogHaze = hex(0xC8641E)

    // Terminal ANSI (all ≥5.4:1 on void)
    static let ansiRed = hex(0xFF7A6E)
    static let ansiGreen = hex(0x8FD6A0)
    static let ansiYellow = hex(0xF5C451)
    static let ansiBlue = hex(0x7AA7FF)
    static let ansiWhite = hex(0xAAB2BE)
    static let ansiBrightBlack = hex(0x7A8699)
}

/// Five SF sizes, one expanded eyebrow, Plex Mono for data. Nothing under 11 pt.
enum PongType {
    static let floor: CGFloat = 11

    static func sf(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: max(floor, size), weight: weight)
    }

    static var title: NSFont { sf(22, .semibold) }          // page title
    static var question: NSFont { sf(17, .semibold) }       // questions, sheet titles
    static var body: NSFont { sf(13) }
    static var bodyStrong: NSFont { sf(13, .semibold) }     // row titles
    static var control: NSFont { sf(13, .medium) }          // buttons, sidebar
    static var secondary: NSFont { sf(12) }                 // subtitles, status lines
    static var meta: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    static var metaStrong: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }

    /// Capitals, at most three words.
    static var eyebrow: NSFont { .systemFont(ofSize: 11, weight: .semibold, width: .expanded) }
    static let eyebrowKern: CGFloat = 0.88

    static var data: NSFont { PongTheme.mono(12, weight: .regular) }      // files, paths, Details
    static var terminal: NSFont { PongTheme.mono(13, weight: .regular) }

    /// An eyebrow label's text: capitals with the tracking the spec asks for.
    static func eyebrowString(_ s: String, color: NSColor = PongColor.textTertiary) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [
            .font: eyebrow, .foregroundColor: color, .kern: eyebrowKern,
        ])
    }
}

/// The 4 pt grid.
enum PongSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let section: CGFloat = 32
    static let rowPad: CGFloat = 12
    static let cardPad: CGFloat = 16
    static let questionPad: CGFloat = 20

    static let windowBar: CGFloat = 52
    static let sidebarRow: CGFloat = 32
    static let listRow: CGFloat = 52
    static let listRowOneLine: CGFloat = 36
    static let activityRow: CGFloat = 28
    static let control: CGFloat = 28
    static let controlLarge: CGFloat = 32
    static let controlSmall: CGFloat = 24
}

enum PongRadius {
    static let badge: CGFloat = 4
    static let control: CGFloat = 6     // buttons, fields, selections
    static let card: CGFloat = 10       // cards, popovers, toasts
    static let palette: CGFloat = 14    // ⌘K
}

/// Motion explains a change: ≤400 ms, off under Reduce Motion.
enum PongMotion {
    static let fast: TimeInterval = 0.12
    static let base: TimeInterval = 0.20
    static let exit: TimeInterval = 0.15
    static let panel: TimeInterval = 0.24
    static let spin: TimeInterval = 1.6

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }
    static var easeIn: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1) }
    static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1) }
}

/// Every state has a shape, a colour and a word (§2.4).
enum PongStatus {
    case needsYou, working, done, failed, stopped, stale, paused, pending

    var word: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .stale: return "Quiet"
        case .paused: return "Paused"
        case .pending: return "Waiting"
        }
    }

    var color: NSColor {
        switch self {
        case .needsYou: return PongColor.you
        case .working: return PongColor.live
        case .done, .paused: return PongColor.textSecondary
        case .failed: return PongColor.fail
        case .stopped, .stale, .pending: return PongColor.textTertiary
        }
    }

    /// SF Symbol name; `working` is drawn as a ring by `StatusMarkerView`.
    var symbol: String {
        switch self {
        case .needsYou: return "diamond.fill"
        case .working: return "circle.dotted"
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .stopped: return "stop.fill"
        case .stale: return "circle.dashed"
        case .paused: return "pause.fill"
        case .pending: return "circle"
        }
    }
}
