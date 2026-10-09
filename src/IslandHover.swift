import Foundation
import CoreGraphics

/// When the notch panel opens and closes (2.1, spec §8.1-8.3), as a pure state machine: pointer
/// samples, clicks, keys and the clock go in; open, close or hold comes out. It never reads the
/// screen, the clock or a setting itself, so tests/swift/island drives it with made-up times.
///
/// Opening: the pointer rests in the opening area for the wait (0.15 s by default). A pointer moving
/// faster than 900 pt/s restarts the wait, so reaching for a menu past the notch never opens it (with
/// "Right away" too: it opens on the first sample that isn't a sweep). A click on the notch opens it at
/// once and, with "A click keeps it open", pins it.
///
/// Closing: once the pointer leaves the open panel and its room to wander, it closes after the close
/// delay (at least 3 s while a question shows); coming back first cancels it. "Until I click elsewhere"
/// never closes on the pointer. Nothing closes it while it is pinned or held (a note or message being
/// typed, Stop armed, an answer sending, a menu it opened, a receipt showing).
///
/// After any close the opening area is disarmed until the pointer has left it, so the panel never
/// opens again under a pointer that is still on the notch (after Esc, the last answer, or a close
/// with the pointer in "A bigger area").
struct IslandHover {
    enum Decision: Equatable { case open, close, hold }

    /// The settings it goes by.
    struct Rules: Equatable {
        var openDelay: Double = 0.15
        /// nil: until a click elsewhere.
        var closeDelay: Double? = 1
        var clickPins = true

        /// Faster than this (points a second), the pointer is passing by, not stopping.
        static let sweepSpeed: Double = 900
        /// With a question showing it waits at least this long after the pointer leaves.
        static let questionMinOpen: Double = 3
        /// How long a forced open (the map's Island button) waits for the pointer to arrive.
        static let forcedGrace: Double = 10

        init(openDelay: Double = 0.15, closeDelay: Double? = 1, clickPins: Bool = true) {
            self.openDelay = openDelay
            self.closeDelay = closeDelay
            self.clickPins = clickPins
        }

        init(_ s: IslandSettings) {
            self.init(openDelay: s.openDelay, closeDelay: s.closeDelay, clickPins: s.clickPins)
        }
    }

    /// What keeps it open whatever the pointer does.
    struct Holds: OptionSet, Equatable {
        let rawValue: Int
        static let typing = Holds(rawValue: 1)      // a note or a message is being typed
        static let stopArmed = Holds(rawValue: 2)   // "Click again to stop"
        static let sending = Holds(rawValue: 4)     // an answer is on its way
        static let menu = Holds(rawValue: 8)        // a menu it opened is showing
        static let receipt = Holds(rawValue: 16)    // a receipt line is showing
    }

    var rules: Rules
    private(set) var isOpen = false
    private(set) var pinned = false
    /// A forced open waits until this time for the pointer to arrive (nil: none).
    private(set) var forcedUntil: Double?
    /// The pointer must leave the opening area before it can open the panel again.
    private(set) var disarmed = false
    /// When the pointer settled in the opening area (nil: it isn't waiting there).
    private(set) var waitingSince: Double?
    /// When the pointer left the open panel (nil: it is on it, or nothing counts down).
    private(set) var leftAt: Double?
    private var last: (p: CGPoint, t: Double)?

    init(rules: Rules = Rules()) { self.rules = rules }

    /// The pointer's speed from the last sample, in points a second (0 for the first, or after a gap).
    private func speed(_ p: CGPoint, _ t: Double) -> Double {
        guard let l = last else { return 0 }
        let dt = t - l.t
        guard dt > 0.001, dt < 0.5 else { return 0 }
        return Double(hypot(p.x - l.p.x, p.y - l.p.y)) / dt
    }

    /// One look at the pointer (every tick of the pointer watch). `openArea` is where it opens the
    /// panel (with the nudge showing, the nudge too); `stayArea` the open panel plus its room to wander.
    mutating func pointer(_ p: CGPoint, at t: Double, openArea: CGRect, stayArea: CGRect,
                          holds: Holds = [], questionShowing: Bool = false) -> Decision {
        let v = speed(p, t)
        last = (p, t)
        guard isOpen else {
            guard IslandGeometry.contains(openArea, p) else {
                waitingSince = nil
                disarmed = false
                return .hold
            }
            guard !disarmed else { return .hold }
            if v > Rules.sweepSpeed {
                waitingSince = nil   // a sweep starts the wait again
                return .hold
            }
            let since = waitingSince ?? t
            waitingSince = since
            guard t - since >= rules.openDelay - 1e-9 else { return .hold }
            open()
            return .open
        }
        let inside = IslandGeometry.contains(stayArea, p)
        if let until = forcedUntil {
            // held open until the pointer arrives once, or the grace runs out
            if inside || t >= until { forcedUntil = nil } else { leftAt = nil; return .hold }
        }
        if inside || pinned || !holds.isEmpty {
            leftAt = nil
            return .hold
        }
        guard let delay = rules.closeDelay else { leftAt = nil; return .hold }   // until a click elsewhere
        let wait = questionShowing ? max(delay, Rules.questionMinOpen) : delay
        let since = leftAt ?? t
        leftAt = since
        guard t - since >= wait - 1e-9 else { return .hold }
        close()
        return .close
    }

    /// A click on the notch or the closed panel: open at once (pinned with "A click keeps it open").
    /// On the open panel's notch it pins it, or lets a pinned one go.
    mutating func clickNotch(at t: Double) -> Decision {
        guard isOpen else {
            open()
            pinned = rules.clickPins
            return .open
        }
        if pinned { pinned = false } else if rules.clickPins { pinned = true }
        leftAt = nil
        return .hold
    }

    /// A click anywhere outside the panel: it lets a pin go; with "Until I click elsewhere" it closes
    /// (unless something holds it, like a note being typed).
    mutating func clickElsewhere(at t: Double, holds: Holds = []) -> Decision {
        guard isOpen else { return .hold }
        pinned = false
        forcedUntil = nil
        guard rules.closeDelay == nil, holds.isEmpty else { return .hold }
        close()
        return .close
    }

    /// Esc (after the panel has cancelled an armed Stop): lets a pin go, else closes.
    mutating func escape(at t: Double) -> Decision {
        guard isOpen else { return .hold }
        if pinned {
            pinned = false
            leftAt = nil
            return .hold
        }
        close()
        return .close
    }

    /// The pin button.
    mutating func togglePin() {
        guard isOpen else { return }
        pinned.toggle()
        leftAt = nil
    }

    /// The keyboard shortcut: opens the panel, kept open until Esc, a click elsewhere or the shortcut
    /// again (the pointer is somewhere else, so leaving can't be the signal); pressed again, closes it.
    mutating func shortcut(at t: Double) -> Decision {
        if isOpen {
            close()
            return .close
        }
        open()
        pinned = true
        return .open
    }

    /// Opened by the person's act elsewhere: the map's Island button, or "Open the whole panel" for a
    /// new question. Held open until the pointer has been on it once, or 10 s; then the usual rules.
    mutating func forceOpen(at t: Double) -> Decision {
        forcedUntil = t + Rules.forcedGrace
        leftAt = nil
        guard !isOpen else { return .hold }
        open()
        return .open
    }

    /// Opened by a click on the nudge (the person's own act): open now, the usual rules after.
    mutating func openNow(at t: Double) -> Decision {
        guard !isOpen else { return .hold }
        open()
        return .open
    }

    /// Closed from inside: after the last answer, "Hide the notch panel", or a row that opened a graph.
    mutating func closeNow() -> Decision {
        guard isOpen else { return .hold }
        close()
        return .close
    }

    /// Back to closed with nothing pending (the panel was turned off, or moved to another screen).
    mutating func reset() {
        isOpen = false
        pinned = false
        forcedUntil = nil
        disarmed = false
        waitingSince = nil
        leftAt = nil
        last = nil
    }

    private mutating func open() {
        isOpen = true
        waitingSince = nil
        leftAt = nil
        disarmed = false
    }

    private mutating func close() {
        isOpen = false
        pinned = false
        forcedUntil = nil
        leftAt = nil
        waitingSince = nil
        disarmed = true
    }
}
