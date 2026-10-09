import AppKit
import Carbon.HIToolbox

// Harness for Settings › Notch panel's words and choices (2.1). run.sh compiles IslandSettings.swift with
// `IslandSettingsWords` and `IslandShortcutHold` sliced out of IslandSettingsPane.swift. Exit 0 = all green.

var failures = 0
var checks = 0

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(label)" + (d.isEmpty ? "" : "\n       \(d)"))
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    check(a == b, label, "got \(a)\n       want \(b)")
}

func section(_ name: String) { print("\n\(name)") }

typealias W = IslandSettingsWords
typealias K = IslandSettings.Key
typealias SC = IslandSettings.Shortcut

/// The settings a settings.json holding just these keys reads as.
func read(_ root: [String: Any]) -> IslandSettings { IslandSettings.from(root) }

// MARK: - The choices are the settings' own

section("Every pop-up offers exactly the values the settings keep")
eq(W.openDelayChoices.map(\.1), IslandSettings.openDelayChoices, "Waits before opening")
eq(W.closeDelayChoices.compactMap(\.1), IslandSettings.closeDelayChoices, "Stays open after the pointer leaves: the seconds")
check(W.closeDelayChoices.last?.1 == nil && W.closeDelayChoices.last?.0 == "Until I click elsewhere",
      "Stays open: the last choice is Until I click elsewhere")
eq(W.stayPadChoices.map(\.1), IslandSettings.stayPadChoices, "Room to wander")
eq(W.rotateChoices.map(\.1).filter { $0 > 0 }, IslandSettings.rotateChoices, "Move between working graphs: the seconds")
check(W.rotateChoices.last?.1 == 0 && W.rotateChoices.last?.0 == "Don't move", "Move between working graphs: Don't move is 0")
eq(W.nudgeChoices.map(\.1).filter { $0 > 0 }, IslandSettings.nudgeChoices, "The nudge stays for: the seconds")
check(W.nudgeChoices.last?.1 == 0 && W.nudgeChoices.last?.0 == "Until I look", "The nudge stays for: Until I look is 0")
eq(W.keepChoices.map(\.1), IslandSettings.keepFinishedChoices, "Finished graphs stay for")

func covers<E: CaseIterable & Equatable>(_ choices: [(String, E)], _ label: String) {
    let all = Array(E.allCases)
    check(choices.count == all.count && all.allSatisfy { c in choices.filter { $0.1 == c }.count == 1 },
          "\(label): every choice once", "\(choices.map(\.0))")
}
covers(W.openAreaChoices, "Opens when the pointer is on")
covers(W.viewChoices, "Shows")
covers(W.besideChoices, "Beside the notch")
covers(W.onQuestionChoices, "When a graph needs you")
covers(W.afterLastChoices, "After your last answer")
covers(W.screenChoices, "Show it on")
covers(W.noNotchChoices, "On screens without a notch")
covers(W.fullScreenChoices, "In full-screen apps")
eq(W.showsTips.count, W.viewChoices.count, "Shows: one tooltip per segment")

section("The usual settings show the spec's defaults")
let d = IslandSettings.defaults
eq(W.openAreaChoices[W.index(of: d.openArea, in: W.openAreaChoices)].0, "Just the notch", "Opens when the pointer is on")
eq(W.openDelayChoices[W.index(of: d.openDelay, in: W.openDelayChoices)].0, "A moment (0.15 s)", "Waits before opening")
eq(W.closeDelayChoices[W.index(of: d.closeDelay, in: W.closeDelayChoices)].0, "1 second", "Stays open")
eq(d.clickPins, true, "A click keeps it open: on")
eq(d.enabled, true, "Show the notch panel: on")
eq(W.viewChoices[W.index(of: d.view, in: W.viewChoices)].0, "Graphs", "Shows")
eq(W.besideChoices[W.index(of: d.beside, in: W.besideChoices)].0, "Words and a count", "Beside the notch")
eq(W.onQuestionChoices[W.index(of: d.onQuestion, in: W.onQuestionChoices)].0, "Open a little, with the question",
   "When a graph needs you (§14.3)")
eq(d.quietNight, true, "Quiet at night: on")
eq(W.afterLastChoices[W.index(of: d.afterLast, in: W.afterLastChoices)].0, "Close the panel", "After your last answer")
eq(W.stayPadChoices[W.index(of: d.stayPad, in: W.stayPadChoices)].0, "A little (8 pt)", "Room to wander")
eq(W.rotateChoices[W.index(of: d.rotateSeconds, in: W.rotateChoices)].0, "5 seconds", "Move between working graphs")
eq(W.nudgeChoices[W.index(of: d.nudgeSeconds, in: W.nudgeChoices)].0, "6 seconds", "The nudge stays for")
eq(W.keepChoices[W.index(of: d.keepFinishedMinutes, in: W.keepChoices)].0, "30 minutes", "Finished graphs stay for")
eq(W.screenChoices[W.index(of: d.screen, in: W.screenChoices)].0, "The screen with the notch", "Show it on")
eq(W.noNotchChoices[W.index(of: d.noNotch, in: W.noNotchChoices)].0, "While something's happening", "On screens without a notch")
eq(W.fullScreenChoices[W.index(of: d.fullScreen, in: W.fullScreenChoices)].0, "Hide it, but show questions", "In full-screen apps")
eq(d.haptic, false, "Tap the trackpad: off")
eq(d.hideFromCapture, false, "Leave it out of screen recordings: off")
check(d.shortcut == nil, "Keyboard shortcut: none")

section("A choice written as Settings writes it reads back as the same choice")
for (i, c) in W.openDelayChoices.enumerated() {
    eq(W.index(of: read([K.openDelay.rawValue: c.1]).openDelay, in: W.openDelayChoices), i, "Waits before opening: \(c.0)")
}
for (i, c) in W.closeDelayChoices.enumerated() {
    eq(W.index(of: read([K.closeDelay.rawValue: c.1 ?? -1]).closeDelay, in: W.closeDelayChoices), i, "Stays open: \(c.0)")
}
for (i, c) in W.stayPadChoices.enumerated() {
    eq(W.index(of: read([K.stayPad.rawValue: Double(c.1)]).stayPad, in: W.stayPadChoices), i, "Room to wander: \(c.0)")
}
for (i, c) in W.rotateChoices.enumerated() {
    eq(W.index(of: read([K.rotate.rawValue: c.1]).rotateSeconds, in: W.rotateChoices), i, "Move between graphs: \(c.0)")
}
for (i, c) in W.nudgeChoices.enumerated() {
    eq(W.index(of: read([K.nudge.rawValue: c.1]).nudgeSeconds, in: W.nudgeChoices), i, "The nudge stays for: \(c.0)")
}
for (i, c) in W.keepChoices.enumerated() {
    eq(W.index(of: read([K.keepFinished.rawValue: c.1]).keepFinishedMinutes, in: W.keepChoices), i, "Finished stay: \(c.0)")
}
for (i, c) in W.openAreaChoices.enumerated() {
    eq(W.index(of: read([K.openArea.rawValue: c.1.rawValue]).openArea, in: W.openAreaChoices), i, "Opens when: \(c.0)")
}
for (i, c) in W.onQuestionChoices.enumerated() {
    eq(W.index(of: read([K.onQuestion.rawValue: c.1.rawValue]).onQuestion, in: W.onQuestionChoices), i, "When a graph needs you: \(c.0)")
}
for (i, c) in W.fullScreenChoices.enumerated() {
    eq(W.index(of: read([K.fullScreen.rawValue: c.1.rawValue]).fullScreen, in: W.fullScreenChoices), i, "Full screen: \(c.0)")
}

section("A hand-edited value shows as the nearest choice")
eq(W.openDelayChoices[W.index(of: read([K.openDelay.rawValue: 0.2]).openDelay, in: W.openDelayChoices)].0,
   "A moment (0.15 s)", "0.2 s reads as A moment")
eq(W.closeDelayChoices[W.index(of: read([K.closeDelay.rawValue: -5]).closeDelay, in: W.closeDelayChoices)].0,
   "Until I click elsewhere", "a minus close delay reads as Until I click elsewhere")
eq(W.closeDelayChoices[W.index(of: read([K.closeDelay.rawValue: 99]).closeDelay, in: W.closeDelayChoices)].0,
   "10 seconds", "99 s reads as 10 seconds")
eq(W.rotateChoices[W.index(of: read([K.rotate.rawValue: -3]).rotateSeconds, in: W.rotateChoices)].0,
   "Don't move", "a minus rotation reads as Don't move")
eq(W.nudgeChoices[W.index(of: read([K.nudge.rawValue: 7]).nudgeSeconds, in: W.nudgeChoices)].0, "6 seconds", "7 s reads as 6 seconds")
eq(W.stayPadChoices[W.index(of: read([K.stayPad.rawValue: 100]).stayPad, in: W.stayPadChoices)].0, "Lots (24 pt)", "100 pt reads as Lots")
eq(W.openAreaChoices[W.index(of: read([K.openArea.rawValue: "huge"]).openArea, in: W.openAreaChoices)].0,
   "Just the notch", "an unknown area reads as Just the notch")
eq(W.index(of: 0.31, in: W.openDelayChoices), 2, "a number between choices: the nearest")

// MARK: - A bigger area's fields

section("The points fields keep a number in range, on its step")
let wr = IslandSettings.extraWRange, ws = IslandSettings.extraWStep
let hr = IslandSettings.extraHRange, hs = IslandSettings.extraHStep
eq(W.points("40", was: 12, range: wr, step: ws), 40, "40 stays 40")
eq(W.points("41", was: 12, range: wr, step: ws), 40, "41 rounds to the 4 pt step")
eq(W.points("43", was: 12, range: wr, step: ws), 44, "43 rounds up to 44")
eq(W.points("300", was: 12, range: wr, step: ws), 200, "300 is cut to 200")
eq(W.points("-5", was: 12, range: wr, step: ws), 0, "a minus number is 0")
eq(W.points(" 24 pt ", was: 12, range: wr, step: ws), 24, "“24 pt” reads as 24")
eq(W.points("lots", was: 12, range: wr, step: ws), 12, "words keep the value it had")
eq(W.points("", was: 40, range: wr, step: ws), 40, "an empty field keeps the value it had")
eq(W.points("1e30", was: 40, range: wr, step: ws), 200, "a huge number is cut to 200")
eq(W.points("13", was: 12, range: hr, step: hs), 14, "below: 13 rounds to the 2 pt step")
eq(W.points("95", was: 12, range: hr, step: hs), 80, "below: 95 is cut to 80")
eq(W.pointsText(40), "40", "a field shows whole points")

// MARK: - The keyboard shortcut

section("A shortcut reads as menus write it")
let cmd = SC.commandMask, opt = SC.optionMask, ctl = SC.controlMask, shift = SC.shiftMask
eq(W.shortcutText(keyCode: 38, modifiers: cmd | opt, characters: "j"), "⌥⌘J", "⌥⌘J")
eq(W.shortcutText(keyCode: 96, modifiers: ctl, characters: nil), "⌃F5", "⌃F5")
eq(W.shortcutText(keyCode: 49, modifiers: ctl | opt | cmd, characters: " "), "⌃⌥⌘Space", "⌃⌥⌘Space")
eq(W.shortcutText(keyCode: 19, modifiers: shift | cmd | ctl, characters: "2"), "⌃⇧⌘2", "⌃⇧⌘2: ⌃ ⌥ ⇧ ⌘ order")
eq(W.shortcutText(keyCode: 126, modifiers: opt | cmd, characters: nil), "⌥⌘↑", "an arrow")
eq(W.keyName(250, ""), "Key 250", "a key with no name")

section("A shortcut that would take keys people use is refused, with words")
let refusedCases: [(Int, UInt, String)] = [
    (38, 0, "J alone"), (38, cmd, "⌘J (the app in front's)"), (38, opt, "⌥J (types a character)"),
    (38, ctl, "⌃J (moves in text)"), (38, cmd | shift, "⇧⌘J (still one of ⌘ ⌥ ⌃)"), (96, 0, "F5 alone"),
    (49, ctl | cmd, "⌃⌘Space (emoji)"), (49, ctl | opt, "⌃⌥Space (input sources)"), (12, ctl | cmd, "⌃⌘Q (lock screen)"),
    (3, ctl | cmd, "⌃⌘F (full screen)"), (2, opt | cmd, "⌥⌘D (the Dock)"), (4, opt | cmd, "⌥⌘H (hide others)"),
    (53, opt | cmd, "⌥⌘Esc"),
]
for (code, mods, label) in refusedCases {
    let why = W.shortcutRefusal(keyCode: code, modifiers: mods)
    check(why != nil && !(why ?? "").isEmpty, "refused: \(label)", why ?? "accepted")
}
let acceptedCases: [(Int, UInt, String)] = [
    (38, cmd | opt, "⌥⌘J"), (38, cmd | ctl, "⌃⌘J"), (38, opt | ctl, "⌃⌥J"), (96, cmd, "⌘F5"), (96, opt, "⌥F5"),
    (122, ctl, "⌃F1"), (49, cmd | opt, "⌥⌘Space"), (12, cmd | opt, "⌥⌘Q"), (38, cmd | opt | shift, "⌥⇧⌘J"),
]
for (code, mods, label) in acceptedCases {
    let why = W.shortcutRefusal(keyCode: code, modifiers: mods)
    check(why == nil, "accepted: \(label)", why ?? "")
    check(SC(keyCode: code, modifiers: mods, display: label) != nil, "accepted by the setting too: \(label)")
}
let written = SC(keyCode: 38, modifiers: cmd | opt, display: "⌥⌘J")!
eq(SC(read([K.shortcut.rawValue: written.asSetting]).shortcut?.asSetting), written, "a recorded shortcut reads back the same")

// MARK: - Try it here

section("The practice notch says what it is doing")
var s = IslandSettings.defaults
eq(W.tryStatus(.waiting, s), "Waiting 0.15 s…", "waiting: the wait in seconds")
s.closeDelay = 2
eq(W.tryStatus(.closing, s), "Closing in 2 seconds… come back to keep it open.", "closing: the close delay")
s.closeDelay = 0.5
eq(W.tryStatus(.closing, s), "Closing in half a second… come back to keep it open.", "closing: half a second")
s.openArea = .notch
eq(W.tryStatus(.idle, s), "Point at the notch.", "idle, just the notch")
s.openArea = .notchWords
eq(W.tryStatus(.idle, s), "Point at the notch or the words beside it.", "idle, the notch and the words")
s.beside = .count
eq(W.tryStatus(.idle, s), "Point at the notch.", "idle, the notch and the words, with only a count beside it")
s.openArea = .bigger
eq(W.tryStatus(.idle, s), "Point at the notch or near it.", "idle, a bigger area")
eq(W.seconds(0.15), "0.15 s", "0.15 s")
eq(W.seconds(0.3), "0.3 s", "0.3 s")
eq(W.seconds(1), "1 second", "1 second")
eq(W.seconds(10), "10 seconds", "10 seconds")

// MARK: - Show me in a preview

section("A preview's [Show me] never draws at the top of a real screen")
let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
check(W.touchesRealTop(CGRect(x: 663, y: 948, width: 185, height: 34), screens: [laptop, external]), "the real notch's area")
check(W.touchesRealTop(CGRect(x: 2400, y: 1050, width: 190, height: 30), screens: [laptop, external]), "the top of a second screen")
check(!W.touchesRealTop(CGRect(x: -6000, y: -6000, width: 185, height: 34), screens: [laptop, external]), "a stand-in frame far off screen")
check(!W.touchesRealTop(CGRect(x: 400, y: 500, width: 185, height: 34), screens: [laptop, external]),
      "a stand-in frame inside a window, away from the top")

// MARK: - Plain words only

section("No word the app keeps off screen")
let rows: [W.Row] = [W.show, W.openArea, W.bigger, W.wait, W.stay, W.clickPins, W.shows, W.beside, W.onQuestion, W.quiet,
                     W.afterLast, W.room, W.rotate, W.nudge, W.keep, W.screen, W.noNotch, W.fullScreen, W.shortcut,
                     W.haptic, W.capture]
eq(rows.count - 6 - 5, 10, "More settings holds 10 rows (the spec's 9 and The nudge stays for)")
var strings: [String] = rows.flatMap { [$0.title, $0.line] }
strings += [W.paneLine, W.generalTitle, W.generalLine, W.card1, W.card2, W.applyNote, W.resetNote, W.resetTitle, W.showMe,
            W.showMeTip, W.moreTitle(10), W.nudgeUnused, W.shortcutNone, W.shortcutRecord, W.shortcutListening, W.shortcutClear,
            W.shortcutTip, W.tryTitle, W.tryLine, W.tryAreas, W.opensHere, W.roomLabel, W.stageLabel]
strings += W.showsTips
strings += W.openAreaChoices.map(\.0) + W.openDelayChoices.map(\.0) + W.closeDelayChoices.map(\.0) + W.viewChoices.map(\.0)
strings += W.besideChoices.map(\.0) + W.onQuestionChoices.map(\.0) + W.afterLastChoices.map(\.0) + W.stayPadChoices.map(\.0)
strings += W.rotateChoices.map(\.0) + W.nudgeChoices.map(\.0) + W.keepChoices.map(\.0) + W.screenChoices.map(\.0)
strings += W.noNotchChoices.map(\.0) + W.fullScreenChoices.map(\.0)
let states: [W.TryState] = [.off, .idle, .waiting, .sweeping, .disarmed, .open, .pinned, .untilClick, .closing, .closed]
for st in states {
    for area in IslandSettings.OpenArea.allCases {
        var t = IslandSettings.defaults
        t.openArea = area
        strings.append(W.tryStatus(st, t))
    }
}
strings += (refusedCases + acceptedCases).compactMap { W.shortcutRefusal(keyCode: $0.0, modifiers: $0.1) }
let banned = try! NSRegularExpression(pattern: "\\b(node|gate|edge|rubric|claim|critic|seat|loop|wiring|runner|pill|ear|lens|ticker|pipeline|json|w\\d+|c\\d)\\b|_",
                                      options: [.caseInsensitive])
// "island" names only the map's Island button; everything else says "notch panel"
let islandWord = try! NSRegularExpression(pattern: "\\bisland\\b(?! button)", options: [.caseInsensitive])
for t in strings {
    let r = NSRange(t.startIndex..., in: t)
    check(banned.firstMatch(in: t, range: r) == nil && islandWord.firstMatch(in: t, range: r) == nil, "plain: \(t)")
}
for t in rows.map(\.title) { check(t.count <= 40, "a short title: \(t)") }
for t in strings where !t.isEmpty { check(t.trimmingCharacters(in: .whitespaces) == t, "no stray spaces: \(t)") }

section("While a shortcut is recorded, the panel's own shortcut doesn't open the panel")
// a made-up press of a hot key, sent to this process's own handlers (nothing is registered with the system)
func pressHotKey(_ signature: OSType) -> OSStatus {
    var event: EventRef?
    guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                      EventAttributes(kEventAttributeNone), &event) == noErr, let e = event else { return -1 }
    defer { ReleaseEvent(e) }
    var id = EventHotKeyID(signature: signature, id: 1)
    SetEventParameter(e, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      MemoryLayout<EventHotKeyID>.size, &id)
    let status = SendEventToEventTarget(e, GetApplicationEventTarget())
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the recorder hears it just after the press
    return status
}
// stands in for IslandController's handler: installed first, like the app's, and it takes every press
var panelOpened = 0
var recorderHeard = 0
var hotKeySpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
var panelHandler: EventHandlerRef?
let panelUPP: EventHandlerUPP = { _, _, _ in panelOpened += 1; return noErr }
check(InstallEventHandler(GetApplicationEventTarget(), panelUPP, 1, &hotKeySpec, nil, &panelHandler) == noErr,
      "(the panel's stand-in handler is in)")
eq(IslandShortcutHold.signature, OSType(0x434E_504C), "the hold knows the panel's hot key (\"CNPL\")")
_ = pressHotKey(IslandShortcutHold.signature)
check(panelOpened == 1 && recorderHeard == 0, "not recording: the shortcut opens the panel")
IslandShortcutHold.hold { recorderHeard += 1 }
check(IslandShortcutHold.isOn, "recording holds the shortcut")
_ = pressHotKey(IslandShortcutHold.signature)
check(panelOpened == 1 && recorderHeard == 1, "recording: the press goes to the recorder, the panel stays shut",
      "panel \(panelOpened), recorder \(recorderHeard)")
_ = pressHotKey(OSType(0x5445_5354))   // "TEST": some other hot key of the app's
check(panelOpened == 2 && recorderHeard == 1, "another hot key passes by the hold", "panel \(panelOpened), recorder \(recorderHeard)")
IslandShortcutHold.hold { recorderHeard += 10 }
_ = pressHotKey(IslandShortcutHold.signature)
check(panelOpened == 2 && recorderHeard == 11, "holding again replaces the first hold (one handler, the newest recorder)",
      "panel \(panelOpened), recorder \(recorderHeard)")
IslandShortcutHold.release()
check(!IslandShortcutHold.isOn, "the recording ended: the hold is let go")
_ = pressHotKey(IslandShortcutHold.signature)
check(panelOpened == 3 && recorderHeard == 11, "after recording: the shortcut opens the panel again",
      "panel \(panelOpened), recorder \(recorderHeard)")
// as in the app: the recorder's answer (stop()) lets the hold go from inside its own call
IslandShortcutHold.hold { recorderHeard += 100; IslandShortcutHold.release() }
_ = pressHotKey(IslandShortcutHold.signature)
check(!IslandShortcutHold.isOn && panelOpened == 3 && recorderHeard == 111,
      "the recorder's answer ends the hold, and the press still didn't open the panel",
      "on \(IslandShortcutHold.isOn), panel \(panelOpened), recorder \(recorderHeard)")
_ = pressHotKey(IslandShortcutHold.signature)
check(panelOpened == 4 && recorderHeard == 111, "the next press opens the panel", "panel \(panelOpened), recorder \(recorderHeard)")
IslandShortcutHold.release()
check(!IslandShortcutHold.isOn, "letting go twice is harmless")
if let h = panelHandler { RemoveEventHandler(h) }

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
