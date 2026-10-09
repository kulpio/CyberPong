import Foundation
import CoreGraphics

// Settings › Notch panel (2.1, spec §9 and §14.3): every key the notch panel reads, its default and
// its range. The values live in ~/.pong/settings.json beside the rest (the app is its only writer,
// through AppSettings); they are clamped on read, so a hand-edited file can't break the panel.
// `IslandSettings.didChange` is posted in-process after every change, and the panel applies it at once.

struct IslandSettings: Equatable {
    /// Every key, as it is written in settings.json.
    enum Key: String, CaseIterable {
        case hide = "hide_island"                     // inverted: true hides the panel (as before 2.1)
        case openArea = "island_open_area"
        case openExtraW = "island_open_extra_w"
        case openExtraH = "island_open_extra_h"
        case openDelay = "island_open_delay_s"
        case closeDelay = "island_close_delay_s"
        case clickPins = "island_click_pins"
        case view = "island_view"
        case beside = "island_beside"
        case onQuestion = "island_on_question"
        case quietNight = "island_quiet_night"
        case afterLast = "island_after_last"
        case stayPad = "island_stay_pad"
        case rotate = "island_rotate_s"
        case keepFinished = "island_keep_finished_min"
        case screen = "island_screen"
        case noNotch = "island_no_notch"
        case fullScreen = "island_fullscreen"
        case shortcut = "island_shortcut"
        case haptic = "island_haptic"
        case hideFromCapture = "island_hide_from_capture"
        case nudge = "island_nudge_s"
    }

    /// Where the pointer has to be for the panel to open (row 2).
    enum OpenArea: String, CaseIterable { case notch, notchWords = "notch_words", bigger }
    /// What the list shows (row 6): Automatic is Graphs while any graph is on, else Teams.
    enum View: String, CaseIterable { case graphs, teams, automatic }
    /// What shows beside the notch while the panel is closed (row 7).
    enum Beside: String, CaseIterable { case words, count, needsMe = "needs_me" }
    /// How a new question shows up (row 8, §14.3): open a little with the question, only the amber
    /// count, or the whole panel.
    enum OnQuestion: String, CaseIterable { case nudge, amber, open }
    /// After the last answer (row 10).
    enum AfterLast: String, CaseIterable { case close, keep }
    /// Which screen it shows on (row 14).
    enum Screen: String, CaseIterable { case notch, main, pointer }
    /// On screens without a notch (row 15).
    enum NoNotch: String, CaseIterable { case happening, always, never }
    /// In full-screen apps (row 16).
    enum FullScreen: String, CaseIterable { case questions, hide, show }

    /// The keyboard shortcut (row 17): a key code and its modifiers (NSEvent.ModifierFlags raw values,
    /// device-independent bits only), with the characters for showing it.
    struct Shortcut: Equatable {
        let keyCode: Int
        let modifiers: UInt
        let display: String

        /// ⌘ ⌥ ⌃ (⇧ alone isn't enough: it would take a letter away from typing).
        static let commandMask: UInt = 1 << 20, optionMask: UInt = 1 << 19, controlMask: UInt = 1 << 18,
                   shiftMask: UInt = 1 << 17

        var asSetting: [String: Any] { ["key_code": keyCode, "modifiers": Int(modifiers), "display": display] }

        init?(keyCode: Int, modifiers: UInt, display: String) {
            let mods = modifiers & (Shortcut.commandMask | Shortcut.optionMask | Shortcut.controlMask | Shortcut.shiftMask)
            guard keyCode >= 0, keyCode < 512,
                  mods & (Shortcut.commandMask | Shortcut.optionMask | Shortcut.controlMask) != 0 else { return nil }
            self.keyCode = keyCode
            self.modifiers = mods
            self.display = String(display.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        }

        init?(_ a: Any?) {
            // checked as numbers before they become integers: a hand-edited 1e30 must not stop the app
            guard let d = a as? [String: Any], let k = IslandSettings.number(d["key_code"]), k >= 0, k < 512,
                  let m = IslandSettings.number(d["modifiers"]), m >= 0, m <= Double(UInt32.max) else { return nil }
            self.init(keyCode: Int(k), modifiers: UInt(m), display: (d["display"] as? String) ?? "")
        }
    }

    // Card 1 — the owner's asks
    var enabled = true
    var openArea = OpenArea.notch
    /// "A bigger area": extra room each side and below the words beside the notch.
    var openExtraW: CGFloat = 40
    var openExtraH: CGFloat = 12
    /// Seconds before it opens (0 = right away).
    var openDelay: Double = 0.15
    /// Seconds it stays open after the pointer leaves; nil = until a click elsewhere.
    var closeDelay: Double? = 1
    var clickPins = true
    // Card 2 — what it shows
    var view = View.graphs
    var beside = Beside.words
    var onQuestion = OnQuestion.nudge
    var quietNight = true
    var afterLast = AfterLast.close
    // More settings
    /// How far the pointer may stray from the open panel before it starts to close.
    var stayPad: CGFloat = 8
    /// Seconds between working graphs in the closed line; 0 = don't move.
    var rotateSeconds: Double = 5
    var keepFinishedMinutes = 30
    var screen = Screen.notch
    var noNotch = NoNotch.happening
    var fullScreen = FullScreen.questions
    var shortcut: Shortcut?
    var haptic = false
    var hideFromCapture = false
    /// Seconds the nudge of a new question stays (§14.3); 0 = until the pointer visits it.
    var nudgeSeconds: Double = 6

    // The choices each pop-up offers. A value between two choices reads as the nearest one.
    static let openDelayChoices: [Double] = [0, 0.15, 0.3, 0.5, 1]
    static let closeDelayChoices: [Double] = [0.5, 1, 2, 3, 5, 10]
    static let stayPadChoices: [CGFloat] = [4, 8, 16, 24]
    static let rotateChoices: [Double] = [3, 5, 8, 10]           // and 0: don't move
    static let keepFinishedChoices: [Int] = [10, 30, 60, 240]
    static let nudgeChoices: [Double] = [4, 6, 10]               // and 0: until I look
    static let extraWRange: ClosedRange<CGFloat> = 0...200, extraWStep: CGFloat = 4
    static let extraHRange: ClosedRange<CGFloat> = 0...80, extraHStep: CGFloat = 2

    /// The usual settings.
    static let defaults = IslandSettings()

    /// The values in a settings.json root, each clamped to its range; anything unreadable is the default.
    static func from(_ root: [String: Any]) -> IslandSettings {
        var s = IslandSettings()
        func v(_ k: Key) -> Any? { root[k.rawValue] }
        if let hide = flag(v(.hide)) { s.enabled = !hide }
        if let a = choice(v(.openArea), OpenArea.self) { s.openArea = a }
        if let w = number(v(.openExtraW)) { s.openExtraW = stepped(CGFloat(w), extraWRange, extraWStep) }
        if let h = number(v(.openExtraH)) { s.openExtraH = stepped(CGFloat(h), extraHRange, extraHStep) }
        if let d = number(v(.openDelay)) { s.openDelay = nearest(max(0, d), openDelayChoices) }
        if let d = number(v(.closeDelay)) { s.closeDelay = d < 0 ? nil : nearest(d, closeDelayChoices) }
        if let b = flag(v(.clickPins)) { s.clickPins = b }
        if let c = choice(v(.view), View.self) { s.view = c }
        if let c = choice(v(.beside), Beside.self) { s.beside = c }
        if let c = choice(v(.onQuestion), OnQuestion.self) { s.onQuestion = c }
        if let b = flag(v(.quietNight)) { s.quietNight = b }
        if let c = choice(v(.afterLast), AfterLast.self) { s.afterLast = c }
        if let p = number(v(.stayPad)) { s.stayPad = nearest(CGFloat(p), stayPadChoices) }
        if let r = number(v(.rotate)) { s.rotateSeconds = r <= 0 ? 0 : nearest(r, rotateChoices) }
        if let m = number(v(.keepFinished)) {
            // clamped before it becomes an integer (Int(1e30) would stop the app)
            s.keepFinishedMinutes = nearest(Int(min(1e6, max(0, m)).rounded()), keepFinishedChoices)
        }
        if let c = choice(v(.screen), Screen.self) { s.screen = c }
        if let c = choice(v(.noNotch), NoNotch.self) { s.noNotch = c }
        if let c = choice(v(.fullScreen), FullScreen.self) { s.fullScreen = c }
        s.shortcut = Shortcut(v(.shortcut))
        if let b = flag(v(.haptic)) { s.haptic = b }
        if let b = flag(v(.hideFromCapture)) { s.hideFromCapture = b }
        if let n = number(v(.nudge)) { s.nudgeSeconds = n <= 0 ? 0 : nearest(n, nudgeChoices) }
        return s
    }

    /// The value each key is written with (what Settings writes for this choice).
    func value(_ k: Key) -> Any? {
        switch k {
        case .hide: return !enabled
        case .openArea: return openArea.rawValue
        case .openExtraW: return Double(openExtraW)
        case .openExtraH: return Double(openExtraH)
        case .openDelay: return openDelay
        case .closeDelay: return closeDelay ?? -1
        case .clickPins: return clickPins
        case .view: return view.rawValue
        case .beside: return beside.rawValue
        case .onQuestion: return onQuestion.rawValue
        case .quietNight: return quietNight
        case .afterLast: return afterLast.rawValue
        case .stayPad: return Double(stayPad)
        case .rotate: return rotateSeconds
        case .keepFinished: return keepFinishedMinutes
        case .screen: return screen.rawValue
        case .noNotch: return noNotch.rawValue
        case .fullScreen: return fullScreen.rawValue
        case .shortcut: return shortcut?.asSetting
        case .haptic: return haptic
        case .hideFromCapture: return hideFromCapture
        case .nudge: return nudgeSeconds
        }
    }

    // MARK: Reading and writing (main thread)

    /// Posted in-process after any notch-panel setting changes.
    static let didChange = Notification.Name("PongIslandSettingsDidChange")

    private static var cached: IslandSettings?
    private static var fileDate: Date?
    private static var lookedAt: Date = .distantPast

    /// The settings now: read from settings.json, then kept. The pointer watch reads this every tick, so
    /// it looks at the file's date at most every 2 s and reads it again only when it changed (a change
    /// made elsewhere, or by hand, applies within a couple of seconds; one through `set` at once).
    static var current: IslandSettings {
        let now = Date()
        if now.timeIntervalSince(lookedAt) >= 2 {
            lookedAt = now
            let date = (try? FileManager.default.attributesOfItem(atPath: AppSettings.path))?[.modificationDate] as? Date
            if date != fileDate {
                fileDate = date
                if let was = cached {
                    let fresh = from(AppSettings.load())
                    cached = fresh
                    // told after this read returns, so a reader of `current` never runs inside it
                    if fresh != was { DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) } }
                }
            }
        }
        if let c = cached { return c }
        let s = from(AppSettings.load())
        cached = s
        return s
    }

    /// Read settings.json again (Settings opened, or the file was changed by hand) and tell the panel
    /// when anything differs.
    static func reload() {
        let was = cached
        cached = from(AppSettings.load())
        if cached != was { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Write one setting (nil removes the key: its default applies again) and apply it at once.
    static func set(_ k: Key, _ value: Any?) {
        AppSettings.set(k.rawValue, value)
        cached = from(AppSettings.load())
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Write a whole set of choices (only the keys that differ from what is saved).
    static func save(_ s: IslandSettings) {
        let now = current
        let changed = Key.allCases.filter { !same(now.value($0), s.value($0)) }
        guard !changed.isEmpty else { return }
        AppSettings.update { root in
            for k in changed {
                if let v = s.value(k) { root[k.rawValue] = v } else { root.removeValue(forKey: k.rawValue) }
            }
        }
        cached = from(AppSettings.load())
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// "Reset to the usual settings": every notch-panel key goes back to its default. Whether the panel
    /// shows at all (row 1) is left as the person set it.
    static func reset() {
        AppSettings.update { root in
            for k in Key.allCases where k != .hide { root.removeValue(forKey: k.rawValue) }
        }
        cached = from(AppSettings.load())
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Clamps (plain values; tests/swift/island checks them)

    /// A JSON true or false; a number counts as one (1 = on). Anything else: nil (the default applies).
    static func flag(_ a: Any?) -> Bool? {
        guard let n = a as? NSNumber else { return nil }
        return n.boolValue
    }

    /// A JSON number, or a string holding one; a true or false is not a number (JSON's 1 and true both
    /// arrive as an NSNumber: the boolean type tells them apart).
    static func number(_ a: Any?) -> Double? {
        if let n = a as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = a as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        return nil
    }

    static func choice<E: RawRepresentable>(_ a: Any?, _: E.Type) -> E? where E.RawValue == String {
        guard let s = a as? String else { return nil }
        return E(rawValue: s.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func nearest<T: BinaryFloatingPoint>(_ x: T, _ choices: [T]) -> T {
        choices.min { abs($0 - x) < abs($1 - x) } ?? x
    }

    static func nearest(_ x: Int, _ choices: [Int]) -> Int {
        choices.min { abs($0 - x) < abs($1 - x) } ?? x
    }

    /// Clamped to the range and rounded to its step.
    static func stepped(_ x: CGFloat, _ r: ClosedRange<CGFloat>, _ step: CGFloat) -> CGFloat {
        let c = min(r.upperBound, max(r.lowerBound, x))
        return min(r.upperBound, (c / step).rounded() * step)
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x as NSObject, let y as NSObject): return x.isEqual(y)
        default: return false
        }
    }
}
