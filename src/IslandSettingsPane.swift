import AppKit
import Carbon.HIToolbox

// Settings › Notch panel (2.1, spec §9 and §14.3). What the pane says and offers (IslandSettingsWords,
// plain values tests/swift/island-settings checks), its rows (IslandSettingsRows, built from the setup's
// row and card views), the keyboard-shortcut recorder, "Try it here" (a drawn menu bar and notch that
// runs the panel's own IslandHover on IslandGeometry's shapes, with the settings as they are now) and
// [Show me] (the real opening area drawn on the screen for 3 s). Every change is written through
// IslandSettings at once; the panel follows `IslandSettings.didChange`.

/// The pane's words and choices. Plain values only (no views): tests/swift/island-settings slices
/// this enum out of the file and checks it.
enum IslandSettingsWords {
    /// A row's title and the line under it.
    struct Row: Equatable {
        let title: String
        let line: String
    }

    static let paneLine = "The panel beside your Mac's notch: your questions and what each graph is doing."
    static let generalTitle = "Notch panel"
    static let generalLine = "Settings for the panel beside the notch"
    static let card1 = "Notch panel"
    static let card2 = "What it shows"
    static let applyNote = "Changes apply at once."
    static let resetNote = "Back to the usual settings. Changes apply at once."
    static let resetTitle = "Reset to the usual settings"
    static let showMe = "Show me"
    static let showMeTip = "Draws the area on your screen for 3 seconds"
    static func moreTitle(_ n: Int) -> String { "More settings (\(n))" }

    // Card 1: the owner's asks
    static let show = Row(title: "Show the notch panel",
                          line: "Questions and working graphs beside the Mac's notch. Off removes it everywhere, the map's Island button too.")
    static let openArea = Row(title: "Opens when the pointer is on",
                              line: "Where the pointer has to be for the panel to open.")
    static let bigger = Row(title: "Bigger area", line: "Extra room around the notch.")
    static let wait = Row(title: "Waits before opening", line: "A quick swipe past the notch never opens it.")
    static let stay = Row(title: "Stays open after the pointer leaves",
                          line: "It stays open while you type, and waits at least 3 seconds while a question is showing.")
    static let clickPins = Row(title: "A click keeps it open",
                               line: "Click the notch to keep the panel open. Click again, press Esc or click elsewhere to let it close.")

    // Card 2: what it shows
    static let shows = Row(title: "Shows",
                           line: "Your graphs step by step, or your teams and their AIs. The same switch is at the top of the panel. Questions always come first.")
    static let showsTips = ["Your graphs step by step", "Your teams and their AIs", "Graphs while any graph is on, else Teams"]
    static let beside = Row(title: "Beside the notch", line: "What shows next to the notch while the panel is closed.")
    static let onQuestion = Row(title: "When a graph needs you", line: "How a new question shows up.")
    static let quiet = Row(title: "Quiet at night", line: "From 10 pm to 8 am nothing pops up. The amber count still shows.")
    static let afterLast = Row(title: "After your last answer", line: "“That's everything.” then…")

    // More settings (folded)
    static let room = Row(title: "Room to wander",
                          line: "How far the pointer can stray from the open panel before it starts to close.")
    static let rotate = Row(title: "Move between working graphs every",
                            line: "It stops while the pointer is on it, and never moves away from a question.")
    static let nudge = Row(title: "The nudge stays for",
                           line: "How long a new question shows, open a little below the notch. Until I look: until the pointer goes to it.")
    /// The nudge's line while "When a graph needs you" isn't set to show it.
    static let nudgeUnused = "Only with “Open a little, with the question” under When a graph needs you."
    static let keep = Row(title: "Finished graphs stay in the panel for", line: "")
    static let screen = Row(title: "Show it on", line: "With the lid closed it moves to the main screen.")
    static let noNotch = Row(title: "On screens without a notch", line: "A small black tab at the top of the screen.")
    static let fullScreen = Row(title: "In full-screen apps", line: "")
    static let shortcut = Row(title: "Keyboard shortcut", line: "Opens the panel at the oldest question, from any app.")
    static let haptic = Row(title: "Tap the trackpad when you open it",
                            line: "Only when you open it yourself. Needs a Force Touch trackpad.")
    static let capture = Row(title: "Leave it out of screen recordings",
                             line: "Asks screen sharing and recordings to leave it out. Some apps still show it.")

    // MARK: The choices each pop-up offers (title, value written)

    static let openAreaChoices: [(String, IslandSettings.OpenArea)] = [
        ("Just the notch", .notch), ("The notch and the words beside it", .notchWords), ("A bigger area", .bigger),
    ]
    static let openDelayChoices: [(String, Double)] = [
        ("Right away", 0), ("A moment (0.15 s)", 0.15), ("0.3 seconds", 0.3), ("Half a second", 0.5), ("1 second", 1),
    ]
    /// nil: until a click elsewhere (written as -1).
    static let closeDelayChoices: [(String, Double?)] = [
        ("Half a second", 0.5), ("1 second", 1), ("2 seconds", 2), ("3 seconds", 3), ("5 seconds", 5),
        ("10 seconds", 10), ("Until I click elsewhere", nil),
    ]
    static let viewChoices: [(String, IslandSettings.View)] = [("Graphs", .graphs), ("Teams", .teams), ("Automatic", .automatic)]
    static let besideChoices: [(String, IslandSettings.Beside)] = [
        ("Words and a count", .words), ("Just the count", .count), ("Only when something needs me", .needsMe),
    ]
    static let onQuestionChoices: [(String, IslandSettings.OnQuestion)] = [
        ("Open a little, with the question", .nudge), ("Only turn the count amber", .amber), ("Open the whole panel", .open),
    ]
    static let afterLastChoices: [(String, IslandSettings.AfterLast)] = [("Close the panel", .close), ("Keep it open", .keep)]
    static let stayPadChoices: [(String, CGFloat)] = [
        ("Tight (4 pt, as before)", 4), ("A little (8 pt)", 8), ("More (16 pt)", 16), ("Lots (24 pt)", 24),
    ]
    /// 0: don't move.
    static let rotateChoices: [(String, Double)] = [
        ("3 seconds", 3), ("5 seconds", 5), ("8 seconds", 8), ("10 seconds", 10), ("Don't move", 0),
    ]
    /// 0: until the pointer goes to it.
    static let nudgeChoices: [(String, Double)] = [("4 seconds", 4), ("6 seconds", 6), ("10 seconds", 10), ("Until I look", 0)]
    static let keepChoices: [(String, Int)] = [("10 minutes", 10), ("30 minutes", 30), ("1 hour", 60), ("4 hours", 240)]
    static let screenChoices: [(String, IslandSettings.Screen)] = [
        ("The screen with the notch", .notch), ("The main screen", .main), ("The screen with the pointer", .pointer),
    ]
    static let noNotchChoices: [(String, IslandSettings.NoNotch)] = [
        ("While something's happening", .happening), ("Always", .always), ("Never", .never),
    ]
    static let fullScreenChoices: [(String, IslandSettings.FullScreen)] = [
        ("Hide it, but show questions", .questions), ("Always hide it", .hide), ("Always show it", .show),
    ]

    /// Which choice shows a value (the first that equals it; the first choice when none does).
    static func index<T: Equatable>(of v: T, in choices: [(String, T)]) -> Int {
        choices.firstIndex { $0.1 == v } ?? 0
    }

    /// A number shows as the nearest choice (settings.json is clamped to the choices on read, so this
    /// is the same one).
    static func index(of v: Double, in choices: [(String, Double)]) -> Int {
        choices.indices.min { abs(choices[$0].1 - v) < abs(choices[$1].1 - v) } ?? 0
    }

    /// What a points field holds after typing: a number (an optional "pt" after it), clamped to the
    /// range and rounded to its step; anything else keeps the value it had.
    static func points(_ text: String, was: CGFloat, range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
        let t = text.lowercased().replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Double(t), d.isFinite else { return was }
        return IslandSettings.stepped(CGFloat(d), range, step)
    }

    static func pointsText(_ v: CGFloat) -> String { String(Int(v.rounded())) }

    // MARK: The keyboard shortcut

    static let shortcutNone = "None"
    static let shortcutRecord = "Record shortcut"
    static let shortcutListening = "Press the keys…"
    static let shortcutClear = "Clear"
    static let shortcutTip = "Press Record shortcut, then the keys. Esc stops without changing it."

    /// The F keys (macOS key codes F1–F20): one of ⌘ ⌥ ⌃ is enough with these.
    static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let escapeKey = 53

    /// A key's name as menus show it.
    static func keyName(_ keyCode: Int, _ characters: String?) -> String {
        let named: [Int: String] = [
            36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        if let n = named[keyCode] { return n }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.isEmpty ? "Key \(keyCode)" : c
    }

    /// "⌥⌘J": the modifiers in the order menus show them, then the key.
    static func shortcutText(keyCode: Int, modifiers: UInt, characters: String?) -> String {
        typealias S = IslandSettings.Shortcut
        var t = ""
        if modifiers & S.controlMask != 0 { t += "⌃" }
        if modifiers & S.optionMask != 0 { t += "⌥" }
        if modifiers & S.shiftMask != 0 { t += "⇧" }
        if modifiers & S.commandMask != 0 { t += "⌘" }
        return t + keyName(keyCode, characters)
    }

    /// Why a combination can't be the shortcut, in words for the person; nil when it can. A shortcut
    /// works from any app, so it must not take keys people type or use every day: with a letter, a
    /// number or another key it needs two of ⌘ ⌥ ⌃ (⌘ with one key is the app in front's, ⌥ types a
    /// character, ⌃ moves around in text); an F key needs one. A few that macOS keeps are refused too.
    static func shortcutRefusal(keyCode: Int, modifiers: UInt) -> String? {
        typealias S = IslandSettings.Shortcut
        let cmd = modifiers & S.commandMask != 0, opt = modifiers & S.optionMask != 0, ctl = modifiers & S.controlMask != 0
        let shift = modifiers & S.shiftMask != 0
        let held = [cmd, opt, ctl].filter { $0 }.count
        if keyCode == escapeKey { return "Esc stops recording, so it can't be the shortcut." }
        if held == 0 { return "Hold ⌘, ⌥ or ⌃ with the key." }
        if held < 2, !functionKeys.contains(keyCode) {
            return "Hold two of ⌘, ⌥ and ⌃ with that key: apps already use it with one."
        }
        // macOS's own: emoji and input sources (Space), lock the screen (Q), full screen (F), show or
        // hide the Dock (D), hide the other apps (H)
        let kept: [(Int, Bool, Bool, Bool)] = [(49, true, false, true), (49, false, true, true), (12, true, false, true),
                                                (3, true, false, true), (2, true, true, false), (4, true, true, false)]
        if !shift, kept.contains(where: { $0.0 == keyCode && $0.1 == cmd && $0.2 == opt && $0.3 == ctl }) {
            return "macOS already uses that one. Try another."
        }
        return nil
    }

    // MARK: Try it here

    static let tryTitle = "Try it here"
    static let tryLine = "Point at the notch below. It follows the settings above and the room to wander under More settings."
    static let tryAreas = "Show the areas"
    static let opensHere = "Opens here"
    static let roomLabel = "Room to wander"
    static let stageLabel = "A practice notch. Point at it, or press Space, to open the panel."

    /// What the practice notch is doing.
    enum TryState: Equatable { case off, idle, waiting, sweeping, disarmed, open, pinned, untilClick, closing, closed }

    /// "0.15 s", "half a second", "1 second", "10 seconds".
    static func seconds(_ d: Double) -> String {
        if abs(d - 0.5) < 0.001 { return "half a second" }
        if d < 0.5 { return String(format: "%g s", d) }
        if abs(d - 1) < 0.001 { return "1 second" }
        return String(format: "%g seconds", d)
    }

    /// The line under the practice notch.
    static func tryStatus(_ st: TryState, _ s: IslandSettings) -> String {
        switch st {
        case .off: return "The notch panel is off, so nothing shows beside the notch."
        case .idle:
            switch s.openArea {
            case .notch: return "Point at the notch."
            case .notchWords: return s.beside == .words ? "Point at the notch or the words beside it." : "Point at the notch."
            case .bigger: return "Point at the notch or near it."
            }
        case .waiting: return "Waiting \(seconds(s.openDelay))…"
        case .sweeping: return "Moving fast: it waits for the pointer to settle, so a swipe past the notch doesn't open it."
        case .disarmed: return "Closed. Move off the notch, then point at it again."
        case .open: return "Open. Move the pointer away to close it."
        case .pinned: return "Open and kept open. Click the notch again, press Esc or click elsewhere to let it close."
        case .untilClick: return "Open. It stays until you click elsewhere."
        case .closing: return "Closing in \(seconds(s.closeDelay ?? 1))… come back to keep it open."
        case .closed: return "Closed. Point at the notch again."
        }
    }

    // MARK: Show me

    /// Whether an area touches the top of any real screen (a preview's [Show me] never draws there:
    /// the owner's own panel sits at the notch).
    static func touchesRealTop(_ area: CGRect, screens: [CGRect], band: CGFloat = 80) -> Bool {
        screens.contains { s in
            area.intersects(CGRect(x: s.minX, y: s.maxY - band, width: s.width, height: band))
        }
    }
}

// MARK: - The rows

/// The window the pane is in: it writes a setting (and redraws the pane when its rows change with it)
/// and shows the area.
protocol IslandSettingsHost: AnyObject {
    /// Write one setting at once (nil: back to its default). `redraw` when the pane's rows change with it.
    func islandWrite(_ key: IslandSettings.Key, _ value: Any?, redraw: Bool)
    /// [Show me]: the area on the screen and in "Try it here", for 3 s.
    func islandShowMe()
    var islandWindow: NSWindow? { get }
}

enum IslandSettingsRows {
    private typealias W = IslandSettingsWords

    /// A pop-up in the app's colours, as wide as its longest choice; `pick` gets the chosen value.
    static func popUp<T>(_ choices: [(String, T)], selected: Int, label: String, keep: inout [AnyObject],
                         _ pick: @escaping (T) -> Void) -> NSPopUpButton {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        for (t, _) in choices { pop.addItem(withTitle: t) }
        pop.selectItem(at: max(0, min(choices.count - 1, selected)))
        pop.setAccessibilityLabel(label)
        PongTheme.stylePopUp(pop)
        let widest = choices.map { ($0.0 as NSString).size(withAttributes: [.font: PongType.control]).width }.max() ?? 80
        pop.setFrameSize(NSSize(width: min(260, ceil(widest) + 40), height: 28))
        let box = ClosureBox { [weak pop] in
            guard let pop else { return }
            let i = pop.indexOfSelectedItem
            guard i >= 0, i < choices.count else { return }
            PongTheme.stylePopUpItemTitles(pop)
            pick(choices[i].1)
        }
        keep.append(box)
        pop.target = box
        pop.action = #selector(ClosureBox.fire)
        return pop
    }

    static func toggle(_ on: Bool, label: String, keep: inout [AnyObject], _ fn: @escaping (Bool) -> Void) -> NSSwitch {
        let s = NSSwitch()
        s.state = on ? .on : .off
        s.setAccessibilityLabel(label)
        let box = ClosureBox { [weak s] in fn(s?.state == .on) }
        keep.append(box)
        s.target = box
        s.action = #selector(ClosureBox.fire)
        return s
    }

    private static func row(_ w: W.Row, line: String? = nil, _ controls: [NSView], keep: [AnyObject]) -> SetupRowView {
        let r = SetupRowView(mark: .none, title: w.title, line: line ?? w.line, controls: controls)
        r.retained = keep
        return r
    }

    /// "pt each side": a unit after a number field.
    private static func unit(_ s: String) -> NSTextField {
        let l = PongUI.label(s, PongType.secondary, PongColor.textSecondary)
        let w = ceil((s as NSString).size(withAttributes: [.font: PongType.secondary]).width) + 6
        l.frame = NSRect(x: 0, y: 0, width: w, height: 16)
        return l
    }

    /// A points field for "A bigger area": clamped to its range and step when it is left.
    private static func pointsField(_ v: CGFloat, key: IslandSettings.Key, range: ClosedRange<CGFloat>, step: CGFloat,
                                    label: String, host: IslandSettingsHost, keep: inout [AnyObject]) -> SetupField {
        final class Ref { weak var field: SetupField? }
        let ref = Ref()
        let f = SetupRows.numberField(W.pointsText(v), width: 48, label: label, row: &keep) { [weak host] text in
            let was = key == .openExtraW ? IslandSettings.current.openExtraW : IslandSettings.current.openExtraH
            let n = W.points(text, was: was, range: range, step: step)
            // the field shows what was kept (a number past the range, or not a number at all)
            if ref.field?.field.stringValue != W.pointsText(n) { ref.field?.field.stringValue = W.pointsText(n) }
            host?.islandWrite(key, Double(n), redraw: false)
        }
        ref.field = f
        keep.append(ref)
        f.field.toolTip = "\(Int(range.lowerBound))–\(Int(range.upperBound)) pt"
        return f
    }

    /// Card 1: on or off, where the pointer opens it, the wait, how long it stays open, a click pins.
    static func card1(_ s: IslandSettings, host: IslandSettingsHost) -> [SetupRowView] {
        var rows: [SetupRowView] = []
        var k: [AnyObject] = []
        rows.append(row(W.show, [toggle(s.enabled, label: W.show.title, keep: &k) { [weak host] on in
            host?.islandWrite(.hide, !on, redraw: false)
        }], keep: k))

        k = []
        let area = popUp(W.openAreaChoices, selected: W.index(of: s.openArea, in: W.openAreaChoices),
                         label: W.openArea.title, keep: &k) { [weak host] v in
            host?.islandWrite(.openArea, v.rawValue, redraw: true)   // "A bigger area" adds its row
        }
        let showMe = PongButton(title: W.showMe, style: .secondary)
        showMe.toolTip = W.showMeTip
        showMe.onPress = { [weak host] in host?.islandShowMe() }
        rows.append(row(W.openArea, [area, showMe], keep: k))

        if s.openArea == .bigger {
            k = []
            let w = pointsField(s.openExtraW, key: .openExtraW, range: IslandSettings.extraWRange, step: IslandSettings.extraWStep,
                                label: "Extra room each side, in points", host: host, keep: &k)
            let h = pointsField(s.openExtraH, key: .openExtraH, range: IslandSettings.extraHRange, step: IslandSettings.extraHStep,
                                label: "Extra room below, in points", host: host, keep: &k)
            let r = row(W.bigger, [w, unit("pt each side"), h, unit("pt below")], keep: k)
            // a part of the row above it
            r.wantsLayer = true
            r.layer?.backgroundColor = PongColor.hover.cgColor
            rows.append(r)
        }

        k = []
        rows.append(row(W.wait, [popUp(W.openDelayChoices, selected: W.index(of: s.openDelay, in: W.openDelayChoices),
                                       label: W.wait.title, keep: &k) { [weak host] v in
            host?.islandWrite(.openDelay, v, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.stay, [popUp(W.closeDelayChoices, selected: W.index(of: s.closeDelay, in: W.closeDelayChoices),
                                       label: W.stay.title, keep: &k) { [weak host] v in
            host?.islandWrite(.closeDelay, v ?? -1, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.clickPins, [toggle(s.clickPins, label: W.clickPins.title, keep: &k) { [weak host] on in
            host?.islandWrite(.clickPins, on, redraw: false)
        }], keep: k))
        return rows
    }

    /// Card 2: Graphs or Teams, what shows beside the notch, a new question, quiet at night, after the
    /// last answer.
    static func card2(_ s: IslandSettings, host: IslandSettingsHost) -> [SetupRowView] {
        var rows: [SetupRowView] = []
        let seg = PongSegmented(W.viewChoices.map(\.0), tips: W.showsTips)
        seg.select(W.index(of: s.view, in: W.viewChoices))
        seg.setAccessibilityLabel(W.shows.title)
        seg.setFrameSize(seg.fittingSize)
        // on a raised card the raised track would vanish: a darker well shows where the segments are
        seg.layer?.backgroundColor = PongColor.base.cgColor
        seg.onChange = { [weak host] i in
            guard i >= 0, i < W.viewChoices.count else { return }
            host?.islandWrite(.view, W.viewChoices[i].1.rawValue, redraw: false)
        }
        rows.append(row(W.shows, [seg], keep: []))

        var k: [AnyObject] = []
        rows.append(row(W.beside, [popUp(W.besideChoices, selected: W.index(of: s.beside, in: W.besideChoices),
                                         label: W.beside.title, keep: &k) { [weak host] v in
            host?.islandWrite(.beside, v.rawValue, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.onQuestion, [popUp(W.onQuestionChoices, selected: W.index(of: s.onQuestion, in: W.onQuestionChoices),
                                             label: W.onQuestion.title, keep: &k) { [weak host] v in
            host?.islandWrite(.onQuestion, v.rawValue, redraw: true)   // "The nudge stays for" follows it
        }], keep: k))

        k = []
        rows.append(row(W.quiet, [toggle(s.quietNight, label: W.quiet.title, keep: &k) { [weak host] on in
            host?.islandWrite(.quietNight, on, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.afterLast, [popUp(W.afterLastChoices, selected: W.index(of: s.afterLast, in: W.afterLastChoices),
                                            label: W.afterLast.title, keep: &k) { [weak host] v in
            host?.islandWrite(.afterLast, v.rawValue, redraw: false)
        }], keep: k))
        return rows
    }

    /// More settings (folded).
    static func more(_ s: IslandSettings, host: IslandSettingsHost) -> [SetupRowView] {
        var rows: [SetupRowView] = []
        var k: [AnyObject] = []
        rows.append(row(W.room, [popUp(W.stayPadChoices, selected: W.index(of: s.stayPad, in: W.stayPadChoices),
                                       label: W.room.title, keep: &k) { [weak host] v in
            host?.islandWrite(.stayPad, Double(v), redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.rotate, [popUp(W.rotateChoices, selected: W.index(of: s.rotateSeconds, in: W.rotateChoices),
                                         label: W.rotate.title, keep: &k) { [weak host] v in
            host?.islandWrite(.rotate, v, redraw: false)
        }], keep: k))

        k = []
        let nudgeOn = s.onQuestion == .nudge
        let nudge = popUp(W.nudgeChoices, selected: W.index(of: s.nudgeSeconds, in: W.nudgeChoices),
                          label: W.nudge.title, keep: &k) { [weak host] v in
            host?.islandWrite(.nudge, v, redraw: false)
        }
        nudge.isEnabled = nudgeOn
        rows.append(row(W.nudge, line: nudgeOn ? W.nudge.line : W.nudgeUnused, [nudge], keep: k))

        k = []
        rows.append(row(W.keep, [popUp(W.keepChoices, selected: W.index(of: s.keepFinishedMinutes, in: W.keepChoices),
                                       label: W.keep.title, keep: &k) { [weak host] v in
            host?.islandWrite(.keepFinished, v, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.screen, [popUp(W.screenChoices, selected: W.index(of: s.screen, in: W.screenChoices),
                                         label: W.screen.title, keep: &k) { [weak host] v in
            host?.islandWrite(.screen, v.rawValue, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.noNotch, [popUp(W.noNotchChoices, selected: W.index(of: s.noNotch, in: W.noNotchChoices),
                                          label: W.noNotch.title, keep: &k) { [weak host] v in
            host?.islandWrite(.noNotch, v.rawValue, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.fullScreen, [popUp(W.fullScreenChoices, selected: W.index(of: s.fullScreen, in: W.fullScreenChoices),
                                             label: W.fullScreen.title, keep: &k) { [weak host] v in
            host?.islandWrite(.fullScreen, v.rawValue, redraw: false)
        }], keep: k))

        let rec = IslandShortcutRecorder(s.shortcut, host: host)
        rows.append(row(W.shortcut, rec.controls, keep: [rec]))

        k = []
        rows.append(row(W.haptic, [toggle(s.haptic, label: W.haptic.title, keep: &k) { [weak host] on in
            host?.islandWrite(.haptic, on, redraw: false)
        }], keep: k))

        k = []
        rows.append(row(W.capture, [toggle(s.hideFromCapture, label: W.capture.title, keep: &k) { [weak host] on in
            host?.islandWrite(.hideFromCapture, on, redraw: false)
        }], keep: k))
        return rows
    }

    /// A fold: a chevron and a title ("More settings (10)", "Try it here").
    static func fold(_ title: String, open: Bool, font: NSFont = PongType.control, color: NSColor = PongColor.textSecondary,
                     _ fn: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .inline
        b.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.contentTintColor = color
        b.attributedTitle = NSAttributedString(string: " " + title, attributes: [.font: font, .foregroundColor: color])
        b.setAccessibilityLabel(title)
        b.setAccessibilityExpanded(open)
        b.toolTip = open ? "Fold it away" : "Show it"
        let box = ClosureBox(fn)
        objc_setAssociatedObject(b, &foldKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        b.target = box
        b.action = #selector(ClosureBox.fire)
        b.sizeToFit()
        b.setFrameSize(NSSize(width: b.frame.width + 4, height: 22))
        return b
    }

    private static var foldKey = 0
}

// MARK: - The keyboard shortcut

/// While Settings records a shortcut, the panel's own shortcut doesn't open the panel. Carbon hands a hot
/// key's press to the app before any window or key monitor sees it, so without this the recorder could
/// never hear the shortcut there is now: pressing it would open the panel, which takes the keyboard from
/// Settings and so ends the recording. For as long as a recording lasts, a handler sits in front of the
/// panel's (Carbon asks the newest handler first) and gives the panel's presses to the recorder; other
/// hot keys pass by. tests/swift/island-settings slices this enum out of the file and sends it made-up presses.
enum IslandShortcutHold {
    /// The panel's hot key ("CNPL", as IslandController.registerShortcut registers it).
    static let signature = OSType(0x434E_504C)
    private static var handler: EventHandlerRef?
    private static var onPress: (() -> Void)?

    /// A recording holds the shortcut now.
    static var isOn: Bool { handler != nil }

    /// Until `release()`, a press of the panel's shortcut goes to `onPress` (on the main thread, just after
    /// the press) and not to the panel.
    static func hold(_ onPress: @escaping () -> Void) {
        release()
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let upp: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, id.signature == IslandShortcutHold.signature, IslandShortcutHold.isOn else {
                return OSStatus(eventNotHandledErr)
            }
            // after the press: the recorder's answer removes this handler
            DispatchQueue.main.async { IslandShortcutHold.onPress?() }
            return noErr
        }
        if InstallEventHandler(GetApplicationEventTarget(), upp, 1, &spec, nil, &handler) != noErr { handler = nil }
    }

    /// The recording ended: the shortcut opens the panel again.
    static func release() {
        if let h = handler { RemoveEventHandler(h) }
        handler = nil
        onPress = nil
    }
}

/// Row 17's control: the shortcut now, [Record shortcut], and [Clear] once there is one. While it records,
/// the next key press in Settings becomes the shortcut (Esc or a click stops it without a change).
final class IslandShortcutRecorder: NSObject {
    /// True while a shortcut is being recorded. Meanwhile the panel's own shortcut doesn't open the panel
    /// (IslandShortcutHold): pressing it keeps it as the shortcut and ends the recording.
    static private(set) var isRecording = false

    private typealias W = IslandSettingsWords
    private let shownLabel: NSTextField
    private let record = PongButton(title: IslandSettingsWords.shortcutRecord, style: .secondary)
    private let clear = PongButton(title: IslandSettingsWords.shortcutClear, style: .quiet)
    private let hasShortcut: Bool
    private weak var host: IslandSettingsHost?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var recording = false

    var controls: [NSView] { hasShortcut ? [shownLabel, record, clear] : [shownLabel, record] }

    init(_ current: IslandSettings.Shortcut?, host: IslandSettingsHost) {
        self.host = host
        hasShortcut = current != nil
        let text = current.map { $0.display.isEmpty ? W.shortcutNone : $0.display } ?? W.shortcutNone
        shownLabel = PongUI.label(text, current == nil ? PongType.secondary : PongType.bodyStrong,
                                  current == nil ? PongColor.textTertiary : PongColor.textPrimary)
        shownLabel.alignment = .right
        let font = current == nil ? PongType.secondary : PongType.bodyStrong
        shownLabel.frame = NSRect(x: 0, y: 0, width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8, height: 18)
        shownLabel.setAccessibilityLabel("Keyboard shortcut: " + (current == nil ? "none" : text))
        super.init()
        record.toolTip = W.shortcutTip
        record.onPress = { [weak self] in
            guard let self else { return }
            if self.recording { self.stop() } else { self.start() }
        }
        clear.toolTip = "No keyboard shortcut"
        clear.onPress = { [weak self] in
            self?.stop()
            self?.host?.islandWrite(.shortcut, nil, redraw: true)
        }
    }

    deinit { stop() }

    private func start() {
        guard !recording else { return }
        recording = true
        Self.isRecording = true
        record.title = W.shortcutListening
        record.setAccessibilityLabel("Recording: press the keys for the shortcut. Esc stops.")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self, self.recording, e.window === self.host?.islandWindow else { return e }
            self.take(e)
            return nil
        }
        // a click anywhere but the button stops recording (the button's own press toggles it)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, self.recording else { return e }
            if e.window === self.record.window, let hit = e.window?.contentView?.hitTest(e.locationInWindow),
               hit === self.record || hit.isDescendant(of: self.record) {
                return e
            }
            self.stop()
            return e
        }
        if let w = host?.islandWindow {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w,
                                                                    queue: .main) { [weak self] _ in self?.stop() }
        }
        // the shortcut there is now never reaches the key monitor (Carbon takes it first): pressed, it is
        // what the person chose, so it stays and the recording ends
        IslandShortcutHold.hold { [weak self] in self?.stop() }
    }

    private func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        keyMonitor = nil
        clickMonitor = nil
        resignObserver = nil
        guard recording else { return }
        recording = false
        Self.isRecording = false
        IslandShortcutHold.release()
        record.title = W.shortcutRecord
        record.setAccessibilityLabel(W.shortcutRecord)
    }

    private func take(_ e: NSEvent) {
        let code = Int(e.keyCode)
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        typealias S = IslandSettings.Shortcut
        let mods = UInt(flags) & (S.commandMask | S.optionMask | S.controlMask | S.shiftMask)
        if code == W.escapeKey && mods == 0 {
            stop()
            return
        }
        if let why = W.shortcutRefusal(keyCode: code, modifiers: mods) {
            Toast.show(why, warn: true, in: host?.islandWindow)
            return
        }
        // the key without Shift or Option, as its keycap reads ("2", not "@" or "™")
        let chars = e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers
        let text = W.shortcutText(keyCode: code, modifiers: mods, characters: chars)
        guard let sc = IslandSettings.Shortcut(keyCode: code, modifiers: mods, display: text) else {
            Toast.show("Hold ⌘, ⌥ or ⌃ with the key.", warn: true, in: host?.islandWindow)
            return
        }
        stop()
        host?.islandWrite(.shortcut, sc.asSetting, redraw: true)
    }
}

// MARK: - Try it here

/// "Try it here" (spec §9): the fold, "Show the areas", the practice notch and the line saying what
/// it is doing.
final class IslandTryItCard: NSView {
    private typealias W = IslandSettingsWords
    var onFold: ((Bool) -> Void)?
    var onAreas: ((Bool) -> Void)?
    let stage = IslandTryItStage()
    let isOpen: Bool
    private var foldButton: NSButton!
    private let lineLabel = PongUI.label(IslandSettingsWords.tryLine, PongType.secondary, PongColor.textSecondary, lines: 3)
    private let areasLabel = PongUI.label(IslandSettingsWords.tryAreas, PongType.secondary, PongColor.textSecondary)
    private let areas = NSSwitch()
    private let statusLabel = PongUI.label("", PongType.secondary, PongColor.textSecondary, lines: 2)
    private var boxes: [AnyObject] = []

    init(open: Bool, showAreas: Bool) {
        isOpen = open
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PongColor.raised.cgColor
        layer?.cornerRadius = PongRadius.card
        foldButton = IslandSettingsRows.fold(W.tryTitle, open: open, font: PongType.bodyStrong, color: PongColor.textPrimary) { [weak self] in
            guard let self else { return }
            self.onFold?(!self.isOpen)
        }
        addSubview(foldButton)
        addSubview(lineLabel)
        areas.state = showAreas ? .on : .off
        areas.setAccessibilityLabel(W.tryAreas)
        let box = ClosureBox { [weak self] in
            guard let self else { return }
            let on = self.areas.state == .on
            self.stage.showAreas = on
            self.onAreas?(on)
        }
        boxes.append(box)
        areas.target = box
        areas.action = #selector(ClosureBox.fire)
        stage.showAreas = showAreas
        stage.onStatus = { [weak self] s in self?.statusLabel.stringValue = s }
        if open {
            addSubview(areasLabel)
            addSubview(areas)
            addSubview(stage)
            addSubview(statusLabel)
        }
        statusLabel.stringValue = stage.status
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(W.tryTitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Lays the card out at `width`; returns its height.
    @discardableResult
    func fit(width W: CGFloat) -> CGFloat {
        var y: CGFloat = 12
        foldButton.frame.origin = NSPoint(x: 12, y: y - 2)
        if isOpen {
            let sw = areas.fittingSize
            areas.frame = NSRect(x: W - 16 - sw.width, y: y + (18 - sw.height) / 2, width: sw.width, height: sw.height)
            let lw = ceil(areasLabel.attributedStringValue.size().width) + 4
            areasLabel.frame = NSRect(x: areas.frame.minX - 8 - lw, y: y + 1, width: lw, height: 16)
        }
        y += 24
        let lineW = W - 32
        let r = lineLabel.attributedStringValue.boundingRect(with: NSSize(width: lineW - 4, height: 200), options: [.usesLineFragmentOrigin])
        let lh = min(52, ceil(r.height) + 2)
        lineLabel.frame = NSRect(x: 16, y: y, width: lineW, height: lh)
        y += lh
        guard isOpen else { return y + 12 }
        y += 10
        stage.frame = NSRect(x: 16, y: y, width: W - 32, height: IslandTryItStage.height)
        y += IslandTryItStage.height + 8
        statusLabel.frame = NSRect(x: 16, y: y, width: W - 32, height: 34)
        y += 34 + 6
        setFrameSize(NSSize(width: W, height: y))
        return y
    }
}

/// The practice notch: a slice of a menu bar with a notch, the closed panel beside it and a small open
/// panel. The pointer goes through the panel's own `IslandHover` with the opening area and the room to
/// wander from `IslandGeometry`, read from the settings as they are now, so it opens, waits and closes
/// exactly as the panel does. Drawn with layers, y up (as the geometry counts), at 1 pt = 1 pt.
final class IslandTryItStage: NSView {
    private typealias W = IslandSettingsWords
    static let height: CGFloat = 236
    /// The demo's open panel: two graphs' worth (the real one is as tall as what it holds).
    private static let openHeight: CGFloat = 168

    var onStatus: ((String) -> Void)?
    var showAreas = false { didSet { refreshZones() } }
    private(set) var status = ""

    private var s = IslandSettings.current
    private var hover = IslandHover(rules: .init(IslandSettings.current))
    private var m = NotchMetrics.fake()
    private var closedLayout = IslandClosedLayout(silhouette: .zero, left: .zero, right: .zero)
    private var openShape = IslandSilhouette.zero
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var clickMonitor: Any?
    private var observer: NSObjectProtocol?
    private var last: (p: CGPoint, t: Double)?
    private var sweeping = false
    /// When the pointer last swept fast over the opening area.
    private var sweptAt: Double = -100
    private var closedAt: Double = -100
    private var flashUntil: Double = 0
    private var flashing = false
    /// Focus that came from a click (no ring), not from the keyboard.
    private var clickFocus = false

    private let root = CALayer()
    private let wall = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let menuBar = CALayer()
    private let menuLeft = CATextLayer()
    private let menuRight = CATextLayer()
    private let notch = CAShapeLayer()
    private let shape = CAShapeLayer()
    private let leftGroup = CALayer()
    private let ring = CAShapeLayer()
    private let count = CATextLayer()
    private let line = CATextLayer()
    private let openGroup = CALayer()
    private let openZone = CAShapeLayer()
    private let openLabel = CATextLayer()
    private let stayZone = CAShapeLayer()
    private let stayLabel = CATextLayer()
    private let focusRing = CALayer()

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        root.masksToBounds = true
        root.cornerRadius = 8
        root.backgroundColor = NSColor(calibratedRed: 0.106, green: 0.153, blue: 0.2, alpha: 1).cgColor
        layer = root
        wantsLayer = true
        for l in [wall, glow, menuBar, menuLeft, menuRight, notch, shape, leftGroup, line, openGroup,
                  openZone, openLabel, stayZone, stayLabel, focusRing] as [CALayer] {
            root.addSublayer(l)
        }
        leftGroup.addSublayer(ring)
        leftGroup.addSublayer(count)
        // the wallpaper: the mockup's dusk blues and browns, a lighter haze at the top left
        wall.colors = [hex(0x1B2733), hex(0x272431), hex(0x30281F)]
        wall.locations = [0, 0.62, 1]
        wall.startPoint = CGPoint(x: 0.35, y: 1)
        wall.endPoint = CGPoint(x: 0.65, y: 0)
        glow.type = .radial
        glow.colors = [hex(0x24384A), hex(0x24384A, 0)]
        glow.startPoint = CGPoint(x: 0.12, y: 1)
        glow.endPoint = CGPoint(x: 0.8, y: -0.3)
        menuBar.backgroundColor = hex(0x090B0F, 0.38)
        menuRight.alignmentMode = .right
        notch.fillColor = NSColor.black.cgColor
        shape.fillColor = NSColor.black.cgColor
        ring.fillColor = nil
        ring.strokeColor = PongColor.live.cgColor
        ring.lineWidth = 1.5
        ring.lineCap = .round
        openZone.strokeColor = PongColor.live.cgColor
        openZone.fillColor = PongColor.tintLive.withAlphaComponent(0.6).cgColor
        openZone.lineWidth = 1
        stayZone.strokeColor = PongColor.textTertiary.cgColor
        stayZone.fillColor = nil
        stayZone.lineWidth = 1
        stayZone.lineDashPattern = [4, 3]
        openLabel.string = attr(W.opensHere, PongType.meta, PongColor.live)
        stayLabel.string = attr(W.roomLabel, PongType.meta, PongColor.textSecondary)
        stayLabel.alignmentMode = .right
        focusRing.borderColor = PongColor.live.cgColor
        focusRing.borderWidth = 2
        focusRing.cornerRadius = 8
        focusRing.isHidden = true
        openGroup.opacity = 0
        observer = NotificationCenter.default.addObserver(forName: IslandSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(W.stageLabel)
        rebuild()
        // a preview can show it open (`PONG_PREVIEW_TRYIT=open`), as a click on the notch opens it, or
        // walk a made-up pointer over it (`walk`)
        let previewAsk = UIPreview.isOn ? (UIPreview.env["PONG_PREVIEW_TRYIT"] ?? "") : ""
        if previewAsk.contains("open"), s.enabled {
            _ = hover.clickNotch(at: CACurrentMediaTime())
            rebuild()
        }
        updateStatus(nil, CACurrentMediaTime())
        if previewAsk.contains("walk") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.previewWalk() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        timer?.invalidate()
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// Tab reaches it only with keyboard navigation on (so it never takes the window's first focus).
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { rebuild() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopTicking()
            removeClickMonitor()
        }
    }

    // MARK: Areas, as the panel has them

    private var openArea: CGRect {
        IslandGeometry.openingArea(m, closed: closedLayout.silhouette, area: s.openArea, extraW: s.openExtraW, extraH: s.openExtraH)
    }

    private var stayArea: CGRect { IslandGeometry.stayArea(openShape, pad: s.stayPad) }

    /// Nothing beside the notch: the shape is the camera housing itself.
    private var bare: Bool { !s.enabled || s.beside == .needsMe }

    /// The notch drawn as a shape (the same nine-part path, so the open panel grows out of it).
    private var notchShape: IslandSilhouette {
        IslandSilhouette(body: CGRect(x: m.notchRect.minX, y: m.top - m.safeTop, width: m.notchWidth, height: m.safeTop),
                         shoulder: 0, radius: 10)
    }

    private var closedShape: IslandSilhouette { bare ? notchShape : closedLayout.silhouette }

    // MARK: Drawing

    private func hex(_ v: Int, _ a: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a).cgColor
    }

    private func attr(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
    }

    /// The text cut at the end, with "…", to fit `width`. (A text layer's own truncation draws nothing at
    /// all for some attributed strings, so every layer here gets text that already fits.)
    private func fit(_ a: NSAttributedString, _ width: CGFloat) -> NSAttributedString {
        guard a.length > 1, ceil(a.size().width) + 1 > width else { return a }
        var n = a.length
        while n > 1 {
            n -= 1
            let m = NSMutableAttributedString(attributedString: a.attributedSubstring(from: NSRange(location: 0, length: n)))
            while m.length > 0, m.string.hasSuffix(" ") || m.string.hasSuffix("·") {
                m.deleteCharacters(in: NSRange(location: m.length - 1, length: 1))
            }
            guard m.length > 0 else { break }
            m.append(NSAttributedString(string: "…", attributes: m.attributes(at: m.length - 1, effectiveRange: nil)))
            if ceil(m.size().width) + 1 <= width { return m }
        }
        return NSAttributedString()
    }

    /// A one-line text layer centred on `midY`.
    private func place(_ t: CATextLayer, _ a: NSAttributedString, x: CGFloat, midY: CGFloat, width: CGFloat) {
        let f = (a.length > 0 ? a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil) ?? PongType.body
        let h = ceil(f.ascender - f.descender) + 1
        t.truncationMode = .none
        t.string = fit(a, max(0, width))
        t.contentsScale = scale
        t.frame = CGRect(x: x, y: round(midY - h / 2), width: max(0, width), height: h)
    }

    private func text(_ a: NSAttributedString, x: CGFloat, midY: CGFloat, width: CGFloat, in parent: CALayer,
                      align: CATextLayerAlignmentMode = .left) {
        let t = CATextLayer()
        t.alignmentMode = align
        place(t, a, x: x, midY: midY, width: width)
        parent.addSublayer(t)
    }

    /// The working ring: three quarters of a circle, 1.5 pt, cyan.
    private func ringPath(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let c = r.insetBy(dx: r.width * 0.19, dy: r.height * 0.19)
        p.addArc(center: CGPoint(x: c.midX, y: c.midY), radius: c.width / 2, startAngle: .pi / 2,
                 endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
        return p
    }

    private func ringLayer(_ r: CGRect) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = ringPath(r)
        l.fillColor = nil
        l.strokeColor = PongColor.live.cgColor
        l.lineWidth = 1.5
        l.lineCap = .round
        l.contentsScale = scale
        return l
    }

    /// The closed line: the graph's name in primary, its tail in secondary.
    private var closedLine: NSAttributedString {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let a = NSMutableAttributedString(attributedString: attr("Checkout fix", f, PongColor.textPrimary))
        a.append(attr(" · 3/4", f, PongColor.textSecondary))
        return a
    }

    private func rebuild() {
        let b = bounds
        guard b.width > 40, b.height > 40 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wall.frame = b
        glow.frame = b
        focusRing.frame = b
        m = NotchMetrics(screen: b, dockTop: b.minY, notchWidth: 185, safeTop: 32)
        menuBar.frame = CGRect(x: 0, y: b.maxY - m.chin, width: b.width, height: m.chin)
        notch.path = IslandGeometry.path(notchShape, in: b)

        // the closed panel: the marker and count on the left, the line on the right (as "Beside the notch" says)
        let showLeft = s.enabled && s.beside != .needsMe
        let showRight = s.enabled && s.beside == .words
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let countA = attr("3", countFont, PongColor.textPrimary)
        let countW = ceil(countA.size().width)
        let lineA = closedLine
        let lineW = min(IslandGeometry.lineTextMax, ceil(lineA.size().width))
        closedLayout = IslandGeometry.closed(m, leftContent: showLeft ? 16 + 3 + countW : 0,
                                             rightContent: showRight ? lineW : 0)
        let midY = m.top - m.chin / 2
        let lr = closedLayout.left
        leftGroup.frame = lr
        leftGroup.isHidden = !showLeft
        ring.path = ringPath(CGRect(x: IslandGeometry.sidePad, y: (lr.height - 16) / 2, width: 16, height: 16))
        ring.contentsScale = scale
        place(count, countA, x: IslandGeometry.sidePad + 19, midY: lr.height / 2, width: countW + 2)
        // 2 pt to spare: the tail ("· 3/4") is never cut
        place(line, lineA, x: closedLayout.right.minX + IslandGeometry.sidePad, midY: midY, width: lineW + 2)
        line.isHidden = !showRight

        // the menu bar's own words, where the closed panel leaves room
        let menuFont = NSFont.systemFont(ofSize: 13)
        let menuInk = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88)
        let leftRoom = closedShape.frame.minX - 14 - 12
        // whole menu titles only, as many as fit before the closed panel
        let left = NSMutableAttributedString(attributedString: attr("Finder", NSFont.systemFont(ofSize: 13, weight: .bold), menuInk))
        for item in ["File", "Edit", "View"] {
            let more = NSMutableAttributedString(attributedString: left)
            more.append(attr("    " + item, menuFont, menuInk))
            guard ceil(more.size().width) + 2 <= leftRoom else { break }
            left.setAttributedString(more)
        }
        place(menuLeft, left, x: 14, midY: midY, width: ceil(left.size().width) + 2)
        menuLeft.isHidden = ceil(left.size().width) + 2 > leftRoom
        let clock = attr("2:58 pm", NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), menuInk)
        let cw = ceil(clock.size().width) + 2
        place(menuRight, clock, x: b.maxX - 14 - cw, midY: midY, width: cw)
        menuRight.isHidden = b.maxX - 14 - cw < closedShape.frame.maxX + 12

        // the open panel, as wide as the real one where the strip allows
        let ow = min(IslandGeometry.openBody, b.width - 2 * IslandGeometry.openShoulder - 8)
        let oh = min(Self.openHeight, b.height - 40)
        openShape = IslandSilhouette(body: CGRect(x: m.midX - ow / 2, y: m.top - oh, width: ow, height: oh),
                                     shoulder: IslandGeometry.openShoulder, radius: IslandGeometry.openRadius)
        buildOpenContent()

        shape.path = IslandGeometry.path(hover.isOpen ? openShape : closedShape, in: b)
        shape.isHidden = false
        openGroup.opacity = hover.isOpen ? 1 : 0
        line.opacity = hover.isOpen ? 0 : 1
        let menu = menuShows(open: hover.isOpen)
        menuLeft.opacity = menu.left
        menuRight.opacity = menu.right
        for l in [notch, shape, openZone, stayZone] { l.contentsScale = scale }
        for t in [openLabel, stayLabel] { t.contentsScale = scale }
        CATransaction.commit()
        refreshZones()
    }

    /// Two made-up graphs at work, as the open panel lists them (spec §5.5).
    private func buildOpenContent() {
        openGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        let body = openShape.body
        openGroup.frame = root.bounds
        let x0 = body.minX + 12, x1 = body.maxX - 12
        // the top band: Graphs | Teams right of the notch, where it fits
        let bandMid = m.top - m.chin / 2
        let segW: CGFloat = 108, segH: CGFloat = 22
        if body.maxX - 8 - (m.notchRect.maxX + 8) >= segW {
            let track = CALayer()
            track.frame = CGRect(x: m.notchRect.maxX + 8, y: bandMid - segH / 2, width: segW, height: segH)
            track.backgroundColor = PongColor.raised.cgColor
            track.cornerRadius = PongRadius.control
            openGroup.addSublayer(track)
            let sel = CALayer()
            sel.frame = CGRect(x: track.frame.minX + 2, y: track.frame.minY + 2, width: 56, height: segH - 4)
            sel.backgroundColor = PongColor.overlay.cgColor
            sel.cornerRadius = PongRadius.control - 1
            openGroup.addSublayer(sel)
            text(attr("Graphs", NSFont.systemFont(ofSize: 12, weight: .semibold), PongColor.textPrimary),
                 x: sel.frame.minX, midY: bandMid, width: sel.frame.width, in: openGroup, align: .center)
            text(attr("Teams", NSFont.systemFont(ofSize: 12, weight: .medium), PongColor.textSecondary),
                 x: sel.frame.maxX, midY: bandMid, width: track.frame.maxX - sel.frame.maxX - 2, in: openGroup, align: .center)
        }
        // the count line
        var y = m.top - m.chin - 14
        openGroup.addSublayer(ringLayer(CGRect(x: x0, y: y - 6, width: 12, height: 12)))
        let sec = PongType.secondary
        text(attr("3 working", sec, PongColor.textSecondary), x: x0 + 16, midY: y, width: 80, in: openGroup)
        let pause = CAShapeLayer()
        let px = x0 + 96
        let pp = CGMutablePath()
        pp.addRect(CGRect(x: px + 2, y: y - 4.5, width: 2.5, height: 9))
        pp.addRect(CGRect(x: px + 7.5, y: y - 4.5, width: 2.5, height: 9))
        pause.path = pp
        pause.fillColor = PongColor.textSecondary.cgColor
        pause.contentsScale = scale
        openGroup.addSublayer(pause)
        text(attr("1 paused", sec, PongColor.textSecondary), x: px + 16, midY: y, width: 80, in: openGroup)
        // two rows: marker, name, team, time; then the step track and what it is doing
        let rows: [(String, String, String, [Int], String, String)] = [
            ("Checkout fix", "Northwind", "26 min", [2, 2, 1, 0], "Running a command", " · 20 s ago"),
            ("Help center articles", "Juniper", "33 min", [2, 1, 0, 0], "2 of 3 done · Writing FAQ.md", " · 1 min ago"),
        ]
        y -= 14
        for (name, team, time, track, doing, age) in rows {
            let l1 = y - 14, l2 = y - 34
            openGroup.addSublayer(ringLayer(CGRect(x: x0, y: l1 - 8, width: 16, height: 16)))
            let nameA = attr(name, PongType.bodyStrong, PongColor.textPrimary)
            let nw = min(ceil(nameA.size().width) + 2, x1 - x0 - 140)
            text(nameA, x: x0 + 24, midY: l1, width: nw, in: openGroup)
            text(attr(team, sec, PongColor.textTertiary), x: x0 + 24 + nw + 6, midY: l1, width: 90, in: openGroup)
            text(attr(time, PongType.meta, PongColor.textTertiary), x: x1 - 60, midY: l1, width: 60, in: openGroup, align: .right)
            var tx = x0 + 24
            for seg in track {
                let t = CALayer()
                t.frame = CGRect(x: tx, y: l2 - 2, width: 10, height: 4)
                t.cornerRadius = 1
                t.backgroundColor = seg == 2 ? PongColor.textSecondary.withAlphaComponent(0.6).cgColor
                    : (seg == 1 ? PongColor.live.cgColor : PongColor.mark.cgColor)
                openGroup.addSublayer(t)
                tx += 12
            }
            // a narrow strip cuts what it is doing, never its age (a doing line always says how old it is)
            let ageA = attr(age, sec, PongColor.textTertiary)
            let room = x1 - tx - 6
            let doingA = NSMutableAttributedString(attributedString: fit(attr(doing, sec, PongColor.textSecondary),
                                                                         max(0, room - ceil(ageA.size().width) - 1)))
            doingA.append(ageA)
            text(doingA, x: tx + 6, midY: l2, width: room, in: openGroup)
            y -= 48
        }
    }

    /// The opening area and the room to wander: with "Show the areas", or for 3 s after [Show me].
    private func refreshZones() {
        let on = s.enabled && (showAreas || CACurrentMediaTime() < flashUntil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let a = openArea
        openZone.path = CGPath(rect: a.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        // open, only the room to wander counts (the opening area is under the panel)
        openZone.isHidden = !on || a.isEmpty || hover.isOpen
        place(openLabel, attr(W.opensHere, PongType.meta, PongColor.live), x: a.minX + 2, midY: a.minY - 9, width: 120)
        openLabel.isHidden = openZone.isHidden
        let st = stayArea
        stayZone.path = CGPath(rect: st.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        stayZone.isHidden = !on || !hover.isOpen
        place(stayLabel, attr(W.roomLabel, PongType.meta, PongColor.textSecondary), x: st.maxX - 122, midY: st.minY - 9, width: 120)
        stayLabel.alignmentMode = .right
        stayLabel.isHidden = stayZone.isHidden
        CATransaction.commit()
    }

    /// The menu bar's words the shape would cover in part go while it does (half a word under the
    /// open panel read as a cut-off "Fin").
    private func menuShows(open: Bool) -> (left: Float, right: Float) {
        let f = (open ? openShape : closedShape).frame
        return (menuLeft.frame.maxX <= f.minX ? 1 : 0, menuRight.frame.minX >= f.maxX ? 1 : 0)
    }

    // MARK: Motion (spec §8.7)

    private func setShape(_ to: IslandSilhouette, opening: Bool) {
        let new = IslandGeometry.path(to, in: bounds)
        let old = shape.presentation()?.path ?? shape.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = new
        CATransaction.commit()
        guard !PongMotion.reduced, let old else { return }
        // open: spring 0.42 s, damping 0.8; close: 0.36 s, damping 0.9
        let response = opening ? 0.42 : 0.36, zeta = opening ? 0.8 : 0.9
        let w = 2 * Double.pi / response
        let a = CASpringAnimation(keyPath: "path")
        a.fromValue = old
        a.toValue = new
        a.mass = 1
        a.stiffness = CGFloat(w * w)
        a.damping = CGFloat(2 * zeta * w)
        a.duration = a.settlingDuration
        shape.add(a, forKey: "path")
    }

    private func fade(_ l: CALayer, to: Float, duration: Double, delay: Double = 0) {
        let from = l.presentation()?.opacity ?? l.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.opacity = to
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        l.add(a, forKey: "fade")
    }

    private func showOpen() {
        let reduced = PongMotion.reduced
        setShape(openShape, opening: true)
        fade(line, to: 0, duration: 0.1)
        let menu = menuShows(open: true)
        fade(menuLeft, to: menu.left, duration: 0.1)
        fade(menuRight, to: menu.right, duration: 0.1)
        fade(openGroup, to: 1, duration: 0.15, delay: reduced ? 0 : 0.08)
        installClickMonitor()
        refreshZones()
    }

    private func showClosed() {
        let reduced = PongMotion.reduced
        setShape(closedShape, opening: false)
        fade(openGroup, to: 0, duration: 0.1)
        fade(line, to: 1, duration: 0.15, delay: reduced ? 0 : 0.3)
        let menu = menuShows(open: false)
        fade(menuLeft, to: menu.left, duration: 0.15, delay: reduced ? 0 : 0.3)
        fade(menuRight, to: menu.right, duration: 0.15, delay: reduced ? 0 : 0.3)
        removeClickMonitor()
        closedAt = CACurrentMediaTime()
        refreshZones()
    }

    private func apply(_ d: IslandHover.Decision) {
        switch d {
        case .open: showOpen()
        case .close: showClosed()
        case .hold: break
        }
    }

    // MARK: The pointer

    /// Where the pointer is on the strip, or nil when it is somewhere else (another window over it
    /// counts as somewhere else).
    private func pointer() -> CGPoint? {
        if let p = walkPoint { return p }
        guard let w = window, w.isVisible else { return nil }
        let screenPoint = NSEvent.mouseLocation
        let p = convert(w.convertPoint(fromScreen: screenPoint), from: nil)
        guard visibleRect.contains(p),
              NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == w.windowNumber else { return nil }
        return p
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let p = pointer()
        guard s.enabled else {
            if hover.isOpen {
                hover.reset()
                showClosed()
            }
            updateStatus(p, now)
            stopTicking()
            return
        }
        // a pointer off the strip is far away: the panel's rules see it leave
        let q = p ?? CGPoint(x: -10_000, y: -10_000)
        // speed only between two looks on the strip: coming onto it from that far point is no sweep
        // (the words said "Moving fast" each time the pointer came down onto the notch from above)
        if let l = last, let p, now - l.t > 0.001, now - l.t < 0.5 {
            sweeping = Double(hypot(p.x - l.p.x, p.y - l.p.y)) / (now - l.t) > IslandHover.Rules.sweepSpeed
        } else {
            sweeping = false
        }
        last = p.map { (p: $0, t: now) }
        if sweeping, !hover.isOpen, IslandGeometry.contains(openArea, q) { sweptAt = now }
        apply(hover.pointer(q, at: now, openArea: openArea, stayArea: stayArea))
        let flash = now < flashUntil
        if flash != flashing {
            flashing = flash
            refreshZones()
        }
        updateStatus(p, now)
        let busy = p != nil || hover.waitingSince != nil || flash || now - closedAt < 2.6 || now - sweptAt < 0.7
            || (hover.isOpen && !hover.pinned && s.closeDelay != nil)
        if !busy { stopTicking() }
    }

    private func startTicking() {
        guard timer == nil, window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func updateStatus(_ p: CGPoint?, _ now: Double) {
        let st: W.TryState
        if !s.enabled {
            st = .off
        } else if hover.isOpen {
            if hover.pinned { st = .pinned } else if s.closeDelay == nil { st = .untilClick } else if hover.leftAt != nil { st = .closing } else { st = .open }
        } else {
            // a sweep's words stay a moment, so the wait it restarts doesn't flicker in between
            let inArea = p.map { IslandGeometry.contains(openArea, $0) } ?? false
            if inArea && hover.disarmed {
                st = .disarmed
            } else if now - sweptAt < 0.6 {
                st = .sweeping
            } else if hover.waitingSince != nil {
                st = .waiting
            } else if now - closedAt < 2.5 {
                st = .closed
            } else {
                st = .idle
            }
        }
        let t = W.tryStatus(st, s)
        guard t != status else { return }
        status = t
        setAccessibilityValue(t)
        onStatus?(t)
        if let start = walkStart { walkLog.append(String(format: "%.2f  ", now - start) + t) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { startTicking(); tick() }
    override func mouseMoved(with event: NSEvent) { startTicking(); tick() }
    override func mouseExited(with event: NSEvent) { startTicking(); tick() }

    override func mouseDown(with event: NSEvent) {
        // it takes the keys (Esc lets a pin go), but a click shows no focus ring
        clickFocus = true
        window?.makeFirstResponder(self)
        clickFocus = false
        click(convert(event.locationInWindow, from: nil))
    }

    /// A click on the strip: on the notch or the closed panel it opens it (kept open with "A click
    /// keeps it open"); on the open panel's notch it keeps it open or lets it go; beside the open panel
    /// it is a click elsewhere.
    private func click(_ p: CGPoint) {
        guard s.enabled else { return }
        let now = CACurrentMediaTime()
        let onNotch = IslandGeometry.hits(closedLayout.silhouette, p) || IslandGeometry.contains(m.notchRect, p)
        if !hover.isOpen {
            apply(onNotch ? hover.clickNotch(at: now) : hover.clickElsewhere(at: now))
        } else if onNotch {
            apply(hover.clickNotch(at: now))
        } else if !IslandGeometry.hits(openShape, p) {
            apply(hover.clickElsewhere(at: now))
        }
        updateStatus(pointer(), now)
        startTicking()
    }

    /// While it is open, a click anywhere else in CyberPong counts as a click elsewhere.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.window === self.window, self.bounds.contains(self.convert(e.locationInWindow, from: nil)) { return e }
            let now = CACurrentMediaTime()
            self.apply(self.hover.clickElsewhere(at: now))
            self.updateStatus(self.pointer(), now)
            self.startTicking()
            return e
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    // MARK: Keyboard and VoiceOver

    override func becomeFirstResponder() -> Bool {
        focusRing.isHidden = clickFocus
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusRing.isHidden = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        let now = CACurrentMediaTime()
        switch Int(event.keyCode) {
        case 53:   // Esc, as the panel: lets a pin go, else closes
            apply(hover.escape(at: now))
        case 49, 36, 76:   // Space or Return opens it (kept open) and closes it
            press()
        default:
            super.keyDown(with: event)
            return
        }
        updateStatus(pointer(), now)
        startTicking()
    }

    private func press() {
        guard s.enabled else { return }
        let now = CACurrentMediaTime()
        apply(hover.isOpen ? hover.closeNow() : hover.clickNotch(at: now))
        updateStatus(pointer(), now)
        startTicking()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    // MARK: Settings and [Show me]

    private func settingsChanged() {
        let now = IslandSettings.current
        guard now != s else { return }
        s = now
        hover.rules = .init(now)
        if !now.enabled, hover.isOpen { hover.reset() }
        rebuild()
        updateStatus(pointer(), CACurrentMediaTime())
        startTicking()
    }

    /// [Show me]: the areas on the strip for 3 s.
    func flashAreas() {
        flashUntil = CACurrentMediaTime() + 3
        flashing = true
        refreshZones()
        startTicking()
    }

    // MARK: Preview walk

    /// A preview's made-up pointer (`PONG_PREVIEW_TRYIT=walk`): it rests on the notch, leaves, sweeps fast
    /// across it, then clicks the notch and clicks elsewhere. Each line the strip shows is written to
    /// tryit-walk.txt beside the shots, so the open and close rules can be checked without a real pointer.
    private var walkPoint: CGPoint?
    private var walkStart: Double?
    private var walkLog: [String] = []

    private func previewWalk() {
        let n = m.notchRect
        let notchPoint = CGPoint(x: n.midX, y: n.midY)
        let away = CGPoint(x: bounds.minX + 24, y: bounds.minY + 24)
        // a made-up pointer jumps between its places: only the sweep below is meant to count as fast
        var plan: [(Double, (IslandTryItStage) -> Void)] = [
            (0.0, { $0.walkPoint = away }),
            (0.5, { $0.last = nil; $0.walkPoint = notchPoint }),   // rests on the notch: opens after the wait
            (1.5, { $0.last = nil; $0.walkPoint = away }),         // leaves: closes after the close delay
        ]
        // a sweep across the notch at about 2,400 pt/s: it never opens
        for i in 0...12 {
            let x = n.minX - 80 + CGFloat(i) * (n.width + 160) / 12
            plan.append((3.5 + Double(i) * 0.012, { $0.walkPoint = CGPoint(x: x, y: n.midY) }))
        }
        plan.append((3.7, { $0.walkPoint = away }))
        plan.append((6.5, { $0.click(notchPoint) }))    // a click on the notch: open, kept open
        plan.append((8.5, { $0.click(away) }))          // a click elsewhere lets it go
        plan.append((11.0, { st in
            let path = (UIPreview.shotDir as NSString).appendingPathComponent("tryit-walk.txt")
            try? (st.walkLog.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            st.walkPoint = nil
            st.walkStart = nil
        }))
        walkStart = CACurrentMediaTime()
        walkLog = ["0.00  " + status]
        for (at, step) in plan {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self else { return }
                step(self)
                self.startTicking()
                self.tick()
            }
        }
    }
}

// MARK: - Show me

/// [Show me] (spec §8.1): the real opening area on the real screen for 3 s — a cyan 1 pt outline, a
/// `tintLive` fill at 60% and "Opens here" under it. It never takes a click. A preview draws it only
/// inside its stand-in frame (never at the real notch, where the owner's own panel is).
enum IslandShowMe {
    /// The panel's place now, from the panel itself once it runs: its screen's notch and its closed
    /// shape (a preview's is its stand-in frame). Without it, the screen the settings pick and a closed
    /// shape the usual size (a marker and a count, and a graph's line).
    static var panelPlace: (() -> (metrics: NotchMetrics, closed: IslandSilhouette)?)?
    static let seconds: Double = 3

    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    /// Counts the shows: a fade-out that ends after [Show me] was pressed again leaves the new one up.
    private static var shown = 0

    /// Draws the area; false when there is nowhere to draw it.
    @discardableResult
    static func show(_ s: IslandSettings = IslandSettings.current) -> Bool {
        guard let place = place(s) else { return false }
        let area = IslandGeometry.openingArea(place.metrics, closed: place.closed, area: s.openArea,
                                              extraW: s.openExtraW, extraH: s.openExtraH)
        guard area.width > 0, area.height > 0 else { return false }
        if UIPreview.isOn, IslandSettingsWords.touchesRealTop(area, screens: NSScreen.screens.map(\.frame)) { return false }
        let labelH: CGFloat = 22
        let frame = CGRect(x: area.minX, y: area.minY - labelH, width: max(area.width, 96), height: area.height + labelH)
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(frame, display: false)
        if let v = p.contentView as? AreaView {
            v.frame = CGRect(origin: .zero, size: frame.size)
            v.area = CGRect(x: 0, y: labelH, width: area.width, height: area.height)
            v.needsDisplay = true
        }
        p.alphaValue = 0
        if UIPreview.isOn {
            // a preview's windows stay behind everything
            p.level = .normal
            p.orderBack(nil)
        } else {
            p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PongMotion.reduced ? 0 : 0.15
            p.animator().alphaValue = 1
        }
        hideWork?.cancel()
        shown += 1
        let mine = shown
        let w = DispatchWorkItem { [weak p] in
            guard let p, mine == shown else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = PongMotion.reduced ? 0 : 0.2
                p.animator().alphaValue = 0
            }, completionHandler: { if mine == shown { p.orderOut(nil) } })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Showing where the panel opens, for 3 seconds.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return true
    }

    private static func place(_ s: IslandSettings) -> (metrics: NotchMetrics, closed: IslandSilhouette)? {
        if let p = panelPlace?() { return p }
        if UIPreview.isOn { return nil }   // a preview has no stand-in frame of its own here
        guard let screen = screen(s.screen) else { return nil }
        let m = NotchMetrics.of(screen)
        let closed = IslandGeometry.closed(m, leftContent: 27, rightContent: 110).silhouette
        return (m, closed)
    }

    /// The screen "Show it on" picks: the one with the notch (else the main one, as with the lid
    /// closed), the main one (with the menu bar), or the one with the pointer.
    static func screen(_ choice: IslandSettings.Screen) -> NSScreen? {
        let screens = NSScreen.screens
        switch choice {
        case .notch: return screens.first { NotchMetrics.of($0).hasNotch } ?? screens.first
        case .main: return screens.first
        case .pointer:
            let p = NSEvent.mouseLocation
            return screens.first { IslandGeometry.contains($0.frame, p) } ?? screens.first
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isExcludedFromWindowsMenu = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = AreaView(frame: .zero)
        return p
    }

    private final class AreaView: NSView {
        var area: CGRect = .zero

        override func draw(_ dirtyRect: NSRect) {
            guard area.width > 0 else { return }
            PongColor.tintLive.withAlphaComponent(0.6).setFill()
            area.fill()
            PongColor.live.setStroke()
            let edge = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
            let label = NSAttributedString(string: IslandSettingsWords.opensHere,
                                           attributes: [.font: PongType.meta, .foregroundColor: PongColor.live])
            let sz = label.size()
            let pill = NSRect(x: area.minX, y: area.minY - 20, width: ceil(sz.width) + 12, height: 18)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + (pill.height - sz.height) / 2))
        }
    }
}
