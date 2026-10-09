import AppKit

// Harness for the notch panel's model layer (2.1). run.sh compiles the island's pure files with the
// app types they read. Exit 0 = all green. Every name below is made up.

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

// MARK: - Time

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
func at(_ h: Int, _ m: Int = 0) -> Double {
    utc.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: h, minute: m))!.timeIntervalSince1970
}
let T = at(14)          // a Thursday afternoon
let night = at(23)

// MARK: - Fixture builders

func N(_ id: String, _ role: String = "builder", _ status: String = "pending", title: String = "", copyOf: String = "",
       rt: String = "", model: String = "", started: Double? = nil, finished: Double? = nil, visits: Int = 0,
       outcome: String = "", attention: String = "", live: [String: Any]? = nil, loop: [String: Any]? = nil,
       rank: Int? = nil) -> [String: Any] {
    var d: [String: Any] = ["id": id, "role": role, "status": status, "visits": visits, "last_outcome": outcome]
    if !title.isEmpty { d["title"] = title }
    if !copyOf.isEmpty { d["copy_of"] = copyOf }
    if !rt.isEmpty { d["runtime"] = rt; d["model"] = model }
    if let started { d["started_at"] = started }
    if let finished { d["finished_at"] = finished }
    if !attention.isEmpty { d["attention"] = attention }
    if let live { d["live"] = live }
    if let loop { d["loop"] = loop }
    if let rank { d["rank"] = rank }
    return d
}

func E(_ f: String, _ t: String, _ on: String = "done") -> [String: Any] { ["from": f, "to": t, "on": on] }

func G(_ id: String, session: String = "team-a", label: String = "Northwind", title: String, status: String = "running",
       start: Any = "", nodes: [[String: Any]], edges: [[String: Any]], gates: [[String: Any]] = [],
       wall: Double = 26, created: Double = T - 3600, finished: Double? = nil, stop: String = "",
       pause: Bool = false, reason: String = "", held: Int = 0, now: [String: Any]? = nil,
       round: Int = 1, maxRounds: Int = 3, lastError: String = "") -> GGraph {
    var d: [String: Any] = ["id": id, "session": session, "team_label": label, "title": title, "status": status,
                            "start": start, "nodes": nodes, "edges": edges, "gates": gates,
                            "budget": ["wall_min": wall, "max_wall_min": 180, "jobs": 3, "max_jobs": 12],
                            "created_at": created, "stop_reason": stop, "manual_pause": pause,
                            "pause_reason": reason, "held": held, "round": round, "max_rounds": maxRounds]
    if let finished { d["finished_at"] = finished }
    if let now { d["now"] = now }
    if !lastError.isEmpty { d["last_error"] = ["error": lastError] }
    return GGraph(d)
}

// The three shipped designs, as their snapshots carry them (copies expanded).
let writeReviewEdges = [E("draft", "review"), E("review", "me", "win"), E("review", "draft", "fail"),
                        E("review", "me", "abstain"), E("review", "me", "bounded"), E("me", "end", "approved"),
                        E("me", "draft", "rejected")]
func writeReviewNodes(_ s: [String: String] = [:]) -> [[String: Any]] {
    [N("draft", "writer", s["draft"] ?? "done"), N("review", "critic", s["review"] ?? "done"),
     N("me", "human", s["me"] ?? "pending"), N("end", "end", "pending")]
}
let buildVerifyEdges = [E("build", "tests"), E("build", "ship", "blocked"), E("tests", "judge", "win"),
                        E("tests", "build", "fail"), E("tests", "ship", "bounded"), E("judge", "ship", "win"),
                        E("judge", "build", "fail"), E("judge", "ship", "abstain"), E("judge", "ship", "bounded"),
                        E("ship", "end", "approved"), E("ship", "build", "rejected")]
let buildVerifyNodes = [N("build", "builder", "running"), N("tests", "check"), N("judge", "critic"), N("ship", "human"),
                        N("end", "end")]
var fanoutNodes: [[String: Any]] = [N("plan", "researcher", "done")]
    + (1...4).map { N("work#\($0)", "scout", "running", copyOf: "work") }
    + [N("gather", "join", "waiting"), N("synth", "writer"), N("ok", "human"), N("end", "end")]
var fanoutEdges: [[String: Any]] = (1...4).map { E("plan", "work#\($0)") } + (1...4).map { E("work#\($0)", "gather", "*") }
    + [E("gather", "synth", "*"), E("synth", "plan", "route:more"), E("synth", "ok"), E("synth", "ok", "bounded"),
       E("ok", "end", "approved"), E("ok", "synth", "rejected")]

// MARK: - Words.doing (§10.3)

section("W1  tool lines in plain words")
let doingCases: [(String, String?)] = [
    ("Read(src/pong/engine.py)", "Reading engine.py"),
    ("⏺ Read(notes.txt)", "Reading notes.txt"),
    ("Read(file_path: \"/tmp/project/notes.md\")", "Reading notes.md"),
    ("Update(PLAN.md)", "Editing PLAN.md"),
    ("Write(/tmp/project/FAQ.md)", "Editing FAQ.md"),
    ("Edit(src/app.swift)", "Editing app.swift"),
    ("MultiEdit(src/app.swift)", "Editing app.swift"),
    ("Bash(make test)", "Running a command"),
    ("Bash(cd /tmp && rm -rf build)", "Running a command"),
    ("Search(pattern: \"price\", path: \"src\")", "Searching the files"),
    ("Grep(TODO)", "Searching the files"),
    ("Glob(**/*.swift)", "Searching the files"),
    ("WebSearch(\"swift regex\")", "Looking on the web"),
    ("Web Search(\"pricing pages\")", "Looking on the web"),
    ("WebFetch(https://example.com)", "Looking on the web"),
    ("Task(Look through the tests)", "Asking a helper"),
    ("Agent(review the copy)", "Asking a helper"),
]
for (raw, want) in doingCases { eq(Words.doing(raw), want, "\(raw)") }

section("W2  other tool syntax is hidden; sentences pass through")
eq(Words.doing("Skill(release-notes)"), nil, "an unknown tool")
eq(Words.doing("TodoWrite(3 items)"), nil, "a tool the person needn't see")
eq(Words.doing("(hidden: a credential is on the seat's screen)"), nil, "a line hidden for a key on screen")
eq(Words.doing(""), nil, "nothing")
eq(Words.doing("ok"), nil, "too short to mean anything")
eq(Words.doing("Read 3 files (ctrl+o to expand)"), "Read 3 files", "the expand hint comes off")
eq(Words.doing("Checking the test results"), "Checking the test results", "a plain sentence")
eq(Words.doing("- Writing the summary"), "Writing the summary", "a list dash comes off")
eq(Words.doing("-5% load time after the fix"), "-5% load time after the fix", "a minus sign stays")
let long = "Writing the second section about yearly billing and the discount that applies to every plan on the page"
let cut = Words.doing(long) ?? ""
check(cut.count <= 81 && cut.hasSuffix("…") && !cut.contains("  "), "a long sentence is cut at 80 on a word", cut)
check(long.hasPrefix(String(cut.dropLast())), "and keeps its start", cut)

// MARK: - StepPlaces (§10.3)

section("R1  write-review: Your answer is 3 of 3")
var r = StepPlaces.of(G("g1", title: "Doc", start: "draft", nodes: writeReviewNodes(), edges: writeReviewEdges))
eq(r.place["draft"], 1, "draft 1")
eq(r.place["review"], 2, "review 2")
eq(r.place["me"], 3, "me 3")
eq(r.total, 3, "total 3 (the end step isn't counted)")
eq(r.place["end"], nil, "the end step has no place")

section("R2  build-verify: build is 1 of 4, send-backs don't count")
r = StepPlaces.of(G("g2", title: "Fix", start: "build", nodes: buildVerifyNodes, edges: buildVerifyEdges))
eq([r.place["build"], r.place["tests"], r.place["judge"], r.place["ship"]], [1, 2, 3, 4], "build tests judge ship")
eq(r.total, 4, "total 4")

section("R3  fan-out: plan is 1 of 5, copies share 2")
r = StepPlaces.of(G("g3", title: "Fan", start: "plan", nodes: fanoutNodes, edges: fanoutEdges))
eq(r.place["plan"], 1, "plan 1")
eq((1...4).map { r.place["work#\($0)"] }, [2, 2, 2, 2], "the four copies share 2")
eq([r.place["gather"], r.place["synth"], r.place["ok"]], [3, 4, 5], "gather synth ok")
eq(r.total, 5, "total 5 (node order said 8)")

section("R4  a start given as a copied step, and a back edge listed first")
r = StepPlaces.of(G("g4", title: "Copies", start: ["work#1", "work#2"],
                    nodes: [N("work#1", copyOf: "work"), N("work#2", copyOf: "work"), N("check", "critic"), N("end", "end")],
                    edges: [E("check", "work#1", "fail"), E("check", "work#2", "fail"), E("work#1", "check"), E("work#2", "check"),
                            E("check", "end", "win")]))
eq([r.place["work#1"], r.place["work#2"], r.place["check"]], [1, 1, 2], "copies at 1, the check at 2")
eq(r.total, 2, "total 2")

section("R5  no start step, only a cycle: no total, places from the first step")
r = StepPlaces.of(G("g5", title: "Loop", start: "", nodes: [N("scan"), N("gather")], edges: [E("scan", "gather"), E("gather", "scan")]))
eq(r.total, nil, "no total")
eq([r.place["scan"], r.place["gather"]], [1, 2], "scan 1, gather 2")
r = StepPlaces.of(G("g5b", title: "Roots", start: "", nodes: [N("a"), N("b"), N("c")], edges: [E("a", "b"), E("b", "c")]))
eq(r.total, 3, "no start named, but a step nothing points at is the start")

section("R6  the engine's places win (from 1 or from 0)")
r = StepPlaces.of(G("g6", title: "Ranked", start: "a", nodes: [N("a", rank: 1), N("b", rank: 2), N("c", rank: 2), N("end", "end")],
                    edges: [E("a", "b"), E("b", "c")]))
eq([r.place["a"], r.place["b"], r.place["c"]], [1, 2, 2], "engine ranks from 1 used as they are")
eq(r.total, 2, "total from the engine's ranks")
r = StepPlaces.of(G("g6b", title: "Ranked0", start: "a", nodes: [N("a", rank: 0), N("b", rank: 1)], edges: [E("a", "b")]))
eq([r.place["a"], r.place["b"]], [1, 2], "engine ranks from 0 are shifted to count from 1")

// MARK: - IslandSettings (§9, §14.3)

section("S1  defaults")
let d0 = IslandSettings.from([:])
eq(d0, IslandSettings.defaults, "an empty file is the usual settings")
check(d0.enabled && d0.openArea == .notch && d0.openExtraW == 40 && d0.openExtraH == 12, "card 1 area defaults")
check(d0.openDelay == 0.15 && d0.closeDelay == 1 && d0.clickPins, "open 0.15 s, close 1 s, a click keeps it open")
check(d0.view == .graphs && d0.beside == .words && d0.onQuestion == .nudge && d0.quietNight && d0.afterLast == .close,
      "card 2 defaults (a new question opens a little)")
check(d0.stayPad == 8 && d0.rotateSeconds == 5 && d0.keepFinishedMinutes == 30 && d0.screen == .notch
      && d0.noNotch == .happening && d0.fullScreen == .questions && d0.shortcut == nil && !d0.haptic && !d0.hideFromCapture
      && d0.nudgeSeconds == 6, "more settings defaults (the nudge stays 6 s)")

section("S2  clamps for every key")
func S(_ k: IslandSettings.Key, _ v: Any) -> IslandSettings { IslandSettings.from([k.rawValue: v]) }
eq(S(.hide, true).enabled, false, "hide_island true hides it")
eq(S(.hide, "yes").enabled, true, "a word isn't a switch: the default")
eq(S(.openArea, "Notch_Words").openArea, .notchWords, "area: case and spaces don't matter")
eq(S(.openArea, "everywhere").openArea, .notch, "area: unknown falls back")
eq(S(.openExtraW, 41).openExtraW, 40, "extra width rounds to its 4 pt step")
eq(S(.openExtraW, 42).openExtraW, 44, "extra width 42 → 44")
eq(S(.openExtraW, 250).openExtraW, 200, "extra width at most 200")
eq(S(.openExtraW, -10).openExtraW, 0, "extra width at least 0")
eq(S(.openExtraH, 13).openExtraH, 14, "extra height rounds to its 2 pt step")
eq(S(.openExtraH, 100).openExtraH, 80, "extra height at most 80")
eq(S(.openDelay, 0.2).openDelay, 0.15, "open delay snaps to the nearest choice")
eq(S(.openDelay, 7).openDelay, 1, "open delay at most 1 s")
eq(S(.openDelay, -3).openDelay, 0, "open delay at least right away")
eq(S(.openDelay, "0.3").openDelay, 0.3, "a number written as text")
eq(S(.openDelay, true).openDelay, 0.15, "true is not a number")
eq(S(.openDelay, 1).openDelay, 1, "JSON's 1 is a number, not true")
eq(S(.closeDelay, -1).closeDelay, nil, "close delay -1 = until a click elsewhere")
eq(S(.closeDelay, -5).closeDelay, nil, "any negative = until a click")
eq(S(.closeDelay, 0).closeDelay, 0.5, "close delay at least half a second")
eq(S(.closeDelay, 100).closeDelay, 10, "close delay at most 10 s")
eq(S(.closeDelay, 2.2).closeDelay, 2, "close delay snaps")
eq(S(.clickPins, false).clickPins, false, "a click keeps it open: off")
eq(S(.clickPins, 0).clickPins, false, "0 is off")
eq(S(.view, "teams").view, .teams, "view teams")
eq(S(.view, "automatic").view, .automatic, "view automatic")
eq(S(.view, 3).view, .graphs, "view: a number falls back")
eq(S(.beside, "count").beside, .count, "beside: just the count")
eq(S(.beside, "needs_me").beside, .needsMe, "beside: only when something needs me")
eq(S(.onQuestion, "open").onQuestion, .open, "a new question opens the whole panel")
eq(S(.onQuestion, "amber").onQuestion, .amber, "only the amber count")
eq(S(.onQuestion, "peek").onQuestion, .nudge, "the old word falls back to the nudge")
eq(S(.quietNight, false).quietNight, false, "quiet at night off")
eq(S(.afterLast, "keep").afterLast, .keep, "keep it open after the last answer")
eq(S(.stayPad, 30).stayPad, 24, "room to wander at most 24")
eq(S(.stayPad, 1).stayPad, 4, "room to wander at least 4")
eq(S(.stayPad, 15).stayPad, 16, "room to wander snaps")
eq(S(.rotate, 0).rotateSeconds, 0, "rotation 0 = don't move")
eq(S(.rotate, -1).rotateSeconds, 0, "negative = don't move")
eq(S(.rotate, 9.5).rotateSeconds, 10, "rotation snaps")
eq(S(.rotate, 60).rotateSeconds, 10, "rotation at most 10 s")
eq(S(.rotate, 1).rotateSeconds, 3, "rotation at least 3 s when it moves")
eq(S(.keepFinished, 1000).keepFinishedMinutes, 240, "finished kept at most 4 hours")
eq(S(.keepFinished, 5).keepFinishedMinutes, 10, "finished kept at least 10 min")
eq(S(.keepFinished, 70).keepFinishedMinutes, 60, "finished kept snaps")
eq(S(.screen, "pointer").screen, .pointer, "the screen with the pointer")
eq(S(.noNotch, "never").noNotch, .never, "no notch: never")
eq(S(.fullScreen, "show").fullScreen, .show, "full screen: always show it")
eq(S(.haptic, true).haptic, true, "trackpad tap on")
eq(S(.hideFromCapture, true).hideFromCapture, true, "leave it out of recordings on")
eq(S(.nudge, 0).nudgeSeconds, 0, "nudge 0 = until I look")
eq(S(.nudge, 7).nudgeSeconds, 6, "nudge snaps")
eq(S(.nudge, 100).nudgeSeconds, 10, "nudge at most 10 s")
eq(S(.nudge, 1).nudgeSeconds, 4, "nudge at least 4 s")

section("S3  the keyboard shortcut")
let cmdShift = Int(IslandSettings.Shortcut.commandMask | IslandSettings.Shortcut.shiftMask)
let sc = S(.shortcut, ["key_code": 34, "modifiers": cmdShift, "display": "⌘⇧I"]).shortcut
check(sc?.keyCode == 34 && sc?.display == "⌘⇧I", "a key with ⌘ is kept", "\(String(describing: sc))")
eq(S(.shortcut, ["key_code": 34, "modifiers": Int(IslandSettings.Shortcut.shiftMask)]).shortcut, nil,
   "⇧ alone would take a letter from typing: refused")
eq(S(.shortcut, ["key_code": "x", "modifiers": cmdShift]).shortcut, nil, "a key code that isn't a number")
eq(S(.shortcut, "cmd+i").shortcut, nil, "a string isn't a shortcut")

section("S4  every value written reads back as the same choice")
var custom = IslandSettings()
custom.enabled = false; custom.openArea = .bigger; custom.openExtraW = 64; custom.openExtraH = 20; custom.openDelay = 0.5
custom.closeDelay = nil; custom.clickPins = false; custom.view = .teams; custom.beside = .needsMe; custom.onQuestion = .amber
custom.quietNight = false; custom.afterLast = .keep; custom.stayPad = 16; custom.rotateSeconds = 0; custom.keepFinishedMinutes = 240
custom.screen = .main; custom.noNotch = .always; custom.fullScreen = .hide
custom.shortcut = IslandSettings.Shortcut(keyCode: 34, modifiers: UInt(cmdShift), display: "⌘⇧I")
custom.haptic = true; custom.hideFromCapture = true; custom.nudgeSeconds = 0
var rootOut: [String: Any] = [:]
for k in IslandSettings.Key.allCases { if let v = custom.value(k) { rootOut[k.rawValue] = v } }
let json = try! JSONSerialization.data(withJSONObject: rootOut)
let back = IslandSettings.from(try! JSONSerialization.jsonObject(with: json) as! [String: Any])
eq(back, custom, "through settings.json and back")

section("S5  set, save and reset apply at once")
var posted = 0
let obs = NotificationCenter.default.addObserver(forName: IslandSettings.didChange, object: nil, queue: nil) { _ in posted += 1 }
AppSettings.root = ["owner_name": "Sam", "hide_island": true]
IslandSettings.reload()
eq(IslandSettings.current.enabled, false, "reads the file")
IslandSettings.set(.openDelay, 0.5)
eq(IslandSettings.current.openDelay, 0.5, "set: applied at once")
check(posted >= 2, "didChange posted", "posted=\(posted)")
let writesBefore = AppSettings.writes
IslandSettings.save(IslandSettings.current)
eq(AppSettings.writes, writesBefore, "save with nothing changed writes nothing")
var s5 = IslandSettings.current
s5.rotateSeconds = 8
IslandSettings.save(s5)
eq(AppSettings.root["island_rotate_s"] as? Double, 8, "save writes the changed key")
eq(AppSettings.root["island_open_delay_s"] as? Double, 0.5, "and keeps the others")
IslandSettings.reset()
eq(IslandSettings.current.openDelay, 0.15, "reset: the usual wait")
eq(IslandSettings.current.rotateSeconds, 5, "reset: the usual rotation")
eq(IslandSettings.current.enabled, false, "reset leaves on/off as the person set it")
eq(AppSettings.root["owner_name"] as? String, "Sam", "reset leaves other settings alone")
NotificationCenter.default.removeObserver(obs)

// MARK: - IslandGeometry (§4.1, §5.1, §8.1, §14.3)

section("G1  the notch's numbers")
let m = NotchMetrics.fake()
eq(m.chin, 34, "chin = safe-area top + 2")
eq(m.notchRect, CGRect(x: 756 - 92.5, y: 982 - 34, width: 185, height: 34), "the notch, hard against the top")
check(abs(m.cornerRadius - 9.6) < 0.001 && m.shoulder == m.cornerRadius, "corner and shoulder from the height", "\(m.cornerRadius)")
eq(m.openMaxHeight, 888, "open: top of the screen to the Dock less 24")
let short = NotchMetrics(screen: CGRect(x: 0, y: 0, width: 800, height: 300), dockTop: 0, notchWidth: 0, safeTop: 0)
eq(short.openMaxHeight, 320, "never under 320")
let nn = NotchMetrics.fake(notch: false)
check(!nn.hasNotch && nn.chin == 28 && nn.notchRect.width == 190, "no notch: a 28 pt tab over a 190 pt area")
let away = NotchMetrics.fake(origin: CGPoint(x: -5000, y: 3000))
eq(away.notchRect.midX, -5000 + 756, "a stand-in screen can sit anywhere (a preview never covers the real notch)")

section("G2  closed: the sides hug their content, within 64 and 150")
var c = IslandGeometry.closed(m, leftContent: 30, rightContent: 100)
eq(c.left.width, 42, "left = content + 6 pt each side")
eq(c.right.width, 112, "right = content + 6 pt each side")
eq(c.silhouette.body.minX, m.notchRect.minX - 42, "the left side sits outside the notch")
eq(c.silhouette.body.maxX, m.notchRect.maxX + 112, "the right side sits outside the notch")
eq(c.silhouette.body.height, 34, "chin tall")
eq(c.silhouette.frame.width, c.silhouette.body.width + 2 * m.shoulder, "the window has room for the shoulders")
c = IslandGeometry.closed(m, leftContent: 200, rightContent: 400)
check(c.left.width == 64 && c.right.width == 150, "capped at 64 and 150", "\(c.left.width) \(c.right.width)")
eq(IslandGeometry.lineTextMax, 138, "the line's text gets at most 138 pt")
c = IslandGeometry.closed(m, leftContent: 0, rightContent: 0)
eq(c.silhouette.body, m.notchRect, "nothing to say: just the notch")
c = IslandGeometry.closed(nn, leftContent: 30, rightContent: 100)
eq(c.silhouette.body.width, 42 + 112 - 6, "no notch: one tab with both parts")
eq(c.silhouette.body.midX, nn.midX, "centred at the top")
eq(c.silhouette.body.height, 28, "28 pt tall")

section("G3  the nudge and the open panel")
let closedS = IslandGeometry.closed(m, leftContent: 30, rightContent: 100).silhouette
var nudge = IslandGeometry.nudge(m, closed: closedS, contentWidth: 500, drop: 120)
eq(nudge.body.height, 34 + 64, "drops at most 64 pt below the chin")
eq(nudge.body.width, 360, "at most 360 wide")
check(nudge.body.minX <= closedS.body.minX && nudge.body.maxX >= closedS.body.maxX, "never narrower than the closed shape")
let wide = IslandGeometry.closed(m, leftContent: 200, rightContent: 400).silhouette
nudge = IslandGeometry.nudge(m, closed: wide, contentWidth: 100, drop: 30)
eq(nudge.body.width, wide.body.width, "a short question keeps the closed width")
eq(nudge.body.height, 34 + 30, "as tall as its two lines")
var open = IslandGeometry.open(m, contentHeight: 300)
eq(open.body.width, 440, "open body 440")
eq(open.frame.width, 474, "plus 17 pt shoulders")
eq(open.body.midX, m.midX, "about the notch")
eq(open.body.maxY, m.top, "hangs from the top")
eq(open.radius, 20, "bottom corners 20")
open = IslandGeometry.open(m, contentHeight: 5000)
eq(open.body.height, 888, "capped above the Dock")
let tf = IslandGeometry.transitionFrame(closedS, open)
check(tf.contains(closedS.frame) && tf.contains(open.frame), "while it changes, the window holds both shapes")

section("G4  where it opens and where it stays open")
let shape = closedS.body
eq(IslandGeometry.openingArea(m, closed: closedS, area: .notch), m.notchRect, "just the notch")
eq(IslandGeometry.openingArea(m, closed: closedS, area: .notchWords), shape, "the notch and the words beside it")
let big = IslandGeometry.openingArea(m, closed: closedS, area: .bigger, extraW: 40, extraH: 12)
check(IslandGeometry.contains(big, CGPoint(x: shape.minX - 39, y: m.top - 1)), "bigger: 40 pt to the side")
check(!IslandGeometry.contains(big, CGPoint(x: shape.minX - 41, y: m.top - 1)), "and no further")
check(IslandGeometry.contains(big, CGPoint(x: m.midX, y: shape.minY - 11)), "12 pt below")
check(!IslandGeometry.contains(big, CGPoint(x: m.midX, y: shape.minY - 13)), "and no further below")
let topRow = CGPoint(x: m.midX, y: m.top)
check(IslandGeometry.contains(m.notchRect, topRow), "the screen's very top row counts")
check(!m.notchRect.contains(topRow), "(NSRect.contains leaves it out, the bug this fixes)")
let stay = IslandGeometry.stayArea(open, pad: 8)
check(stay.minX == open.frame.minX - 8 && stay.minY == open.body.minY - 8 && stay.maxY == m.top, "room to wander on three sides")

section("G5  clicks hit the shape, not the air beside it")
check(IslandGeometry.hits(open, CGPoint(x: m.midX, y: m.top - 100)), "inside")
check(!IslandGeometry.hits(open, CGPoint(x: open.body.minX - 1, y: m.top - 100)), "beside it")
check(!IslandGeometry.hits(open, CGPoint(x: open.body.minX + 1, y: open.body.minY + 1)), "outside a round corner")
check(IslandGeometry.hits(open, CGPoint(x: open.body.minX + 20, y: open.body.minY + 1)), "past the corner")
check(IslandGeometry.hits(open, CGPoint(x: m.midX, y: m.top)), "the top row")

section("G6  one path recipe for every shape (so the spring can morph them)")
func elements(_ p: CGPath) -> [Int32] {
    var out: [Int32] = []
    p.applyWithBlock { out.append($0.pointee.type.rawValue) }
    return out
}
let pc = elements(IslandGeometry.path(closedS, in: closedS.frame))
let po = elements(IslandGeometry.path(open, in: open.frame))
let pn = elements(IslandGeometry.path(nudge, in: tf))
check(pc == po && po == pn && pc.count == 9, "closed, nudge and open share the same elements", "\(pc) \(po) \(pn)")
let ob = IslandGeometry.path(open, in: open.frame).boundingBoxOfPath
check(abs(ob.width - open.frame.width) < 0.5 && abs(ob.height - open.body.height) < 0.5, "the open path fills its window", "\(ob)")
// a spring that takes over from one still running starts where the shape is drawn, in the new window
func same(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
}
let unionWin = open.frame.union(closedS.frame).insetBy(dx: -30, dy: -12)
let movedIn = IslandGeometry.path(IslandGeometry.path(closedS, in: closedS.frame), from: closedS.frame, to: unionWin)
let drawnIn = IslandGeometry.path(closedS, in: unionWin)
check(same(movedIn.boundingBoxOfPath, drawnIn.boundingBoxOfPath) && elements(movedIn) == elements(drawnIn),
      "a path moved into a bigger window draws the same place on screen", "\(movedIn.boundingBoxOfPath) \(drawnIn.boundingBoxOfPath)")
let backOut = IslandGeometry.path(drawnIn, from: unionWin, to: closedS.frame)
let drawnOut = IslandGeometry.path(closedS, in: closedS.frame)
check(same(backOut.boundingBoxOfPath, drawnOut.boundingBoxOfPath), "and back", "\(backOut.boundingBoxOfPath) \(drawnOut.boundingBoxOfPath)")

section("G7  a full-screen app, with and without the notch (§8.5)")
// window-server coordinates (y down): a 1710 × 1107 screen with a 33 pt notch and a 34 pt menu bar
let scr = CGRect(x: 0, y: 0, width: 1710, height: 1107)
func full(_ r: CGRect, notch: Bool = true, strip: CGFloat = 34, menuBar: Bool = false) -> Bool {
    IslandGeometry.fillsScreen(r, screen: scr, notch: notch, strip: strip, menuBarShown: menuBar)
}
check(full(scr), "a window over the whole screen")
check(full(CGRect(x: 0, y: 34, width: 1710, height: 1073)), "with a notch: a window under the strip beside the camera")
check(full(CGRect(x: 0, y: 33, width: 1710, height: 1074)), "under a strip as tall as the notch")
check(full(CGRect(x: 0, y: 37, width: 1710, height: 1070), strip: 34), "a menu bar a few points taller than the notch")
check(!full(CGRect(x: 0, y: 34, width: 1710, height: 1073), menuBar: true), "the menu bar showing: a zoomed window, not full screen")
check(!full(CGRect(x: 0, y: 34, width: 1710, height: 1073), notch: false), "no notch: only a window over the whole screen")
check(!full(CGRect(x: 0, y: 34, width: 1700, height: 1073)), "narrower than the screen")
check(!full(CGRect(x: 0, y: 34, width: 1710, height: 1000)), "short of the bottom")
check(!full(CGRect(x: 0, y: 120, width: 1710, height: 987)), "lower than the strip")
let side = CGRect(x: 1710, y: -200, width: 2560, height: 1440)
check(IslandGeometry.fillsScreen(CGRect(x: 1710, y: -200, width: 2560, height: 1440), screen: side, notch: false, strip: 25,
                                 menuBarShown: false), "a screen beside the first, whole")

// MARK: - IslandHover (§8.1-8.3)

let notchArea = m.notchRect
let stayOpen = IslandGeometry.stayArea(IslandGeometry.open(m, contentHeight: 400), pad: 8)
let onNotch = CGPoint(x: m.midX, y: m.top - 10)
let away1 = CGPoint(x: 200, y: 400)

section("H1  a short wait before opening")
var h = IslandHover()
eq(h.pointer(away1, at: 0, openArea: notchArea, stayArea: stayOpen), .hold, "away: nothing")
eq(h.pointer(onNotch, at: 1.0, openArea: notchArea, stayArea: stayOpen), .hold, "on the notch: waits")
eq(h.pointer(onNotch, at: 1.1, openArea: notchArea, stayArea: stayOpen), .hold, "still waiting at 0.1 s")
eq(h.pointer(onNotch, at: 1.16, openArea: notchArea, stayArea: stayOpen), .open, "opens after 0.15 s")
check(h.isOpen, "is open")

section("H2  a fast sweep past the notch restarts the wait")
h = IslandHover()
var x = m.notchRect.minX + 2
_ = h.pointer(CGPoint(x: x, y: m.top - 10), at: 0, openArea: notchArea, stayArea: stayOpen)
x += 60
eq(h.pointer(CGPoint(x: x, y: m.top - 10), at: 0.05, openArea: notchArea, stayArea: stayOpen), .hold, "1,200 pt/s: passing by")
x += 60
eq(h.pointer(CGPoint(x: x, y: m.top - 10), at: 0.10, openArea: notchArea, stayArea: stayOpen), .hold, "still sweeping")
eq(h.waitingSince, nil, "the wait was restarted")
eq(h.pointer(CGPoint(x: x, y: m.top - 10), at: 0.20, openArea: notchArea, stayArea: stayOpen), .hold, "stopped: the wait starts now")
eq(h.pointer(CGPoint(x: x, y: m.top - 10), at: 0.30, openArea: notchArea, stayArea: stayOpen), .hold, "0.1 s after stopping")
eq(h.pointer(CGPoint(x: x, y: m.top - 10), at: 0.36, openArea: notchArea, stayArea: stayOpen), .open, "0.16 s after stopping")
h = IslandHover(rules: .init(openDelay: 0))
_ = h.pointer(CGPoint(x: notchArea.minX - 200, y: m.top - 10), at: 0, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(CGPoint(x: notchArea.minX + 20, y: m.top - 10), at: 0.1, openArea: notchArea, stayArea: stayOpen), .hold,
   "right away still ignores a sweep (2,200 pt/s)")
eq(h.pointer(CGPoint(x: notchArea.minX + 20, y: m.top - 10), at: 0.2, openArea: notchArea, stayArea: stayOpen), .open,
   "and opens the moment the pointer stops")

section("H3  leaving closes after the delay; coming back cancels it")
h = IslandHover()
_ = h.pointer(onNotch, at: 0, openArea: notchArea, stayArea: stayOpen)
_ = h.pointer(onNotch, at: 0.2, openArea: notchArea, stayArea: stayOpen)
check(h.isOpen, "open")
eq(h.pointer(away1, at: 10, openArea: notchArea, stayArea: stayOpen), .hold, "left at 10")
eq(h.pointer(away1, at: 10.5, openArea: notchArea, stayArea: stayOpen), .hold, "half a second later")
eq(h.pointer(onNotch, at: 10.8, openArea: notchArea, stayArea: stayOpen), .hold, "came back")
eq(h.pointer(away1, at: 11, openArea: notchArea, stayArea: stayOpen), .hold, "left again at 11")
eq(h.pointer(away1, at: 11.9, openArea: notchArea, stayArea: stayOpen), .hold, "the delay starts over")
eq(h.pointer(away1, at: 12.0, openArea: notchArea, stayArea: stayOpen), .close, "closes 1 s after leaving")
let edgeOfStay = CGPoint(x: stayOpen.minX + 1, y: stayOpen.minY + 1)
h = IslandHover()
_ = h.forceOpen(at: 0)
_ = h.pointer(onNotch, at: 0.1, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(edgeOfStay, at: 5, openArea: notchArea, stayArea: stayOpen), .hold, "inside the room to wander it stays")

section("H4  never closes while held or pinned")
for (hold, name) in [(IslandHover.Holds.typing, "typing a note"), (.stopArmed, "Stop armed"), (.sending, "an answer sending"),
                     (.menu, "a menu open"), (.receipt, "a receipt showing")] {
    var hh = IslandHover()
    _ = hh.openNow(at: 0)
    _ = hh.pointer(away1, at: 1, openArea: notchArea, stayArea: stayOpen, holds: hold)
    eq(hh.pointer(away1, at: 30, openArea: notchArea, stayArea: stayOpen, holds: hold), .hold, name)
    eq(hh.pointer(away1, at: 31, openArea: notchArea, stayArea: stayOpen), .hold, name + ": the delay starts when it ends")
    eq(hh.pointer(away1, at: 32, openArea: notchArea, stayArea: stayOpen), .close, name + ": then it closes")
}
h = IslandHover()
_ = h.openNow(at: 0)
h.togglePin()
check(h.pinned, "the pin button pins")
eq(h.pointer(away1, at: 60, openArea: notchArea, stayArea: stayOpen), .hold, "pinned: stays")
h.togglePin()
_ = h.pointer(away1, at: 61, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(away1, at: 62, openArea: notchArea, stayArea: stayOpen), .close, "unpinned: closes after the delay")

section("H5  with a question showing it waits at least 3 s")
h = IslandHover()
_ = h.openNow(at: 0)
_ = h.pointer(away1, at: 1, openArea: notchArea, stayArea: stayOpen, questionShowing: true)
eq(h.pointer(away1, at: 2.5, openArea: notchArea, stayArea: stayOpen, questionShowing: true), .hold, "1.5 s: still open")
eq(h.pointer(away1, at: 4.0, openArea: notchArea, stayArea: stayOpen, questionShowing: true), .close, "3 s: closes")
h = IslandHover(rules: .init(closeDelay: 5))
_ = h.openNow(at: 0)
_ = h.pointer(away1, at: 1, openArea: notchArea, stayArea: stayOpen, questionShowing: true)
eq(h.pointer(away1, at: 4.5, openArea: notchArea, stayArea: stayOpen, questionShowing: true), .hold, "a longer delay wins")
eq(h.pointer(away1, at: 6.0, openArea: notchArea, stayArea: stayOpen, questionShowing: true), .close, "after 5 s")

section("H6  until I click elsewhere")
h = IslandHover(rules: .init(closeDelay: nil))
_ = h.openNow(at: 0)
eq(h.pointer(away1, at: 600, openArea: notchArea, stayArea: stayOpen), .hold, "ten minutes away: still open")
eq(h.clickElsewhere(at: 601, holds: .typing), .hold, "a click elsewhere while typing: stays")
eq(h.clickElsewhere(at: 602), .close, "a click elsewhere: closes")
h = IslandHover()
_ = h.clickNotch(at: 0)
eq(h.clickElsewhere(at: 1), .hold, "with a delay, a click elsewhere only lets the pin go")
check(!h.pinned, "pin released")

section("H7  a click opens at once and keeps it open")
h = IslandHover()
eq(h.clickNotch(at: 0), .open, "a click on the closed panel opens it")
check(h.pinned, "and pins it")
eq(h.pointer(away1, at: 30, openArea: notchArea, stayArea: stayOpen), .hold, "pinned: leaving doesn't close")
eq(h.clickNotch(at: 31), .hold, "click again: lets it go")
_ = h.pointer(away1, at: 31.1, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(away1, at: 32.2, openArea: notchArea, stayArea: stayOpen), .close, "then closes after the delay")
h = IslandHover(rules: .init(clickPins: false))
_ = h.clickNotch(at: 0)
check(h.isOpen && !h.pinned, "with the setting off a click opens without pinning")

section("H8  Esc lets the pin go, then closes; it doesn't reopen under the pointer")
h = IslandHover()
_ = h.clickNotch(at: 0)
eq(h.escape(at: 1), .hold, "Esc: pin released")
eq(h.escape(at: 2), .close, "Esc again: closed")
eq(h.pointer(onNotch, at: 2.1, openArea: notchArea, stayArea: stayOpen), .hold, "the pointer is still on the notch")
eq(h.pointer(onNotch, at: 5, openArea: notchArea, stayArea: stayOpen), .hold, "and it stays closed")
_ = h.pointer(away1, at: 6, openArea: notchArea, stayArea: stayOpen)
_ = h.pointer(onNotch, at: 7, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(onNotch, at: 7.2, openArea: notchArea, stayArea: stayOpen), .open, "once it has left and come back, it opens")

section("H9  a close with the pointer still in a bigger area doesn't flicker")
let bigArea = IslandGeometry.openingArea(m, closed: wide, area: .bigger, extraW: 200, extraH: 12)
let tight = IslandGeometry.stayArea(IslandGeometry.open(m, contentHeight: 300), pad: 4)
let besideOpen = CGPoint(x: tight.minX - 20, y: m.top - 10)
check(IslandGeometry.contains(bigArea, besideOpen) && !IslandGeometry.contains(tight, besideOpen), "(a spot in the area, beside the open panel)")
h = IslandHover()
_ = h.pointer(besideOpen, at: 0, openArea: bigArea, stayArea: tight)
_ = h.pointer(besideOpen, at: 0.2, openArea: bigArea, stayArea: tight)
check(h.isOpen, "opened from the bigger area")
_ = h.pointer(besideOpen, at: 0.3, openArea: bigArea, stayArea: tight)
eq(h.pointer(besideOpen, at: 1.4, openArea: bigArea, stayArea: tight), .close, "closes: it is outside the open panel")
eq(h.pointer(besideOpen, at: 2, openArea: bigArea, stayArea: tight), .hold, "and doesn't reopen at once")

section("H10  forced open waits for the pointer, 10 s at most")
h = IslandHover()
eq(h.forceOpen(at: 0), .open, "the map's Island button opens it")
eq(h.pointer(away1, at: 5, openArea: notchArea, stayArea: stayOpen), .hold, "the pointer is far away: held")
eq(h.pointer(away1, at: 9.9, openArea: notchArea, stayArea: stayOpen), .hold, "still held at 9.9 s")
eq(h.pointer(away1, at: 10.1, openArea: notchArea, stayArea: stayOpen), .hold, "released at 10 s: the delay starts")
eq(h.pointer(away1, at: 11.2, openArea: notchArea, stayArea: stayOpen), .close, "then the usual rule closes it")
h = IslandHover()
_ = h.forceOpen(at: 0)
_ = h.pointer(onNotch, at: 3, openArea: notchArea, stayArea: stayOpen)
check(h.forcedUntil == nil, "the pointer arrived: the hold ends")
_ = h.pointer(away1, at: 4, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(away1, at: 5.05, openArea: notchArea, stayArea: stayOpen), .close, "and leaving closes it as usual")

section("H11  the very top row opens it; the shortcut toggles")
h = IslandHover()
_ = h.pointer(topRow, at: 0, openArea: notchArea, stayArea: stayOpen)
eq(h.pointer(topRow, at: 0.2, openArea: notchArea, stayArea: stayOpen), .open, "a pointer thrown against the top opens it")
h = IslandHover()
eq(h.shortcut(at: 0), .open, "the shortcut opens it")
check(h.pinned, "kept open (the pointer is elsewhere)")
eq(h.pointer(away1, at: 30, openArea: notchArea, stayArea: stayOpen), .hold, "stays while the person reads")
eq(h.shortcut(at: 31), .close, "pressed again, closes")
h.reset()
check(!h.isOpen && !h.pinned && !h.disarmed, "reset")

section("H12  a nudge dropped under a resting pointer doesn't open the panel (rule 5, §14.3)")
// as the controller does it: the opening area goes through the gate before IslandHover sees it
let restClosed = IslandGeometry.closed(m, leftContent: 20, rightContent: 90).silhouette
let restArea = IslandGeometry.openingArea(m, closed: restClosed, area: .notchWords)
let nudgeShape = IslandGeometry.nudge(m, closed: restClosed, contentWidth: 300, drop: 46)
let withNudge = restArea.union(nudgeShape.body)
let resting = CGPoint(x: m.midX + 40, y: m.top - 50)   // a browser's tab bar, under the menu bar
check(!IslandGeometry.contains(restArea, resting) && IslandGeometry.contains(withNudge, resting),
      "(the spot is below the closed panel, inside the nudge)")
var gate = IslandAreaGate()
h = IslandHover()
var opened = false
var t = 0.0
func tick(_ p: CGPoint, _ area: CGRect) {
    let a = gate.area(area, pointer: p, panelOpen: h.isOpen)
    if h.pointer(p, at: t, openArea: a, stayArea: stayOpen) == .open { opened = true }
    t += 0.1
}
for _ in 0..<20 { tick(resting, restArea) }
check(!opened, "resting there for 2 s: closed")
for _ in 0..<40 { tick(resting, withNudge) }
check(!opened && gate.shut, "the nudge drops onto it and the pointer never moves: it stays closed for 4 s")
tick(CGPoint(x: resting.x + 3, y: resting.y), withNudge)
for _ in 0..<5 { tick(CGPoint(x: resting.x + 3, y: resting.y), withNudge) }
check(!opened, "moving on the nudge without leaving it: still closed")
tick(CGPoint(x: m.midX + 40, y: m.top - 200), withNudge)
check(!gate.shut, "the pointer left the area: the gate opens")
tick(CGPoint(x: m.midX + 40, y: m.top - 120), withNudge)
for _ in 0..<4 { tick(resting, withNudge) }
check(opened, "pointing at the nudge after that opens it")
// a pointer already on the closed panel when the nudge comes is pointing at it: the usual rules
gate = IslandAreaGate()
h = IslandHover()
opened = false
let onWords = CGPoint(x: restClosed.body.maxX - 20, y: m.top - 10)
tick(away1, restArea)
tick(onWords, restArea)
for _ in 0..<3 { tick(onWords, withNudge) }
check(opened && !gate.shut, "a pointer that came to the closed panel itself still opens it")
// a pointer that arrives together with the nudge has moved: pointing
gate = IslandAreaGate()
h = IslandHover()
opened = false
tick(CGPoint(x: resting.x, y: resting.y - 100), restArea)
tick(resting, withNudge)
for _ in 0..<3 { tick(resting, withNudge) }
check(opened, "a pointer moving onto the nudge as it drops opens it")
// the gate never holds an open panel
gate = IslandAreaGate()
_ = gate.area(restArea, pointer: away1, panelOpen: false)
check(gate.area(withNudge, pointer: away1, panelOpen: true) == withNudge && !gate.shut, "open: the area as it is")
gate.reset()
check(!gate.shut, "reset")
// the panel comes up around a resting pointer (just started): that isn't pointing either
gate = IslandAreaGate()
h = IslandHover()
opened = false
for _ in 0..<10 { tick(onWords, restArea) }
check(!opened && gate.shut, "built with the pointer already in its area: closed until it leaves")
tick(away1, restArea)
tick(onWords, restArea)
for _ in 0..<3 { tick(onWords, restArea) }
check(opened, "after leaving, pointing opens it")
// back after a full-screen app hid it ("Always hide it": the controller tells the gate there is no area)
gate = IslandAreaGate()
h = IslandHover()
opened = false
tick(away1, restArea)
for _ in 0..<5 { tick(onWords, .null) }
for _ in 0..<10 { tick(onWords, restArea) }
check(!opened && gate.shut, "shown again under a resting pointer: closed until it leaves")

// MARK: - IslandModel fixtures

func nowBlock(_ d: [String: Any]) -> [String: Any] { d }

let checkout = G("g_checkout", title: "Checkout fix", start: "find",
    nodes: [N("find", "researcher", "done", title: "Find the cause", started: T - 1500, finished: T - 1140, visits: 1),
            N("fix", "builder", "done", title: "Fix", started: T - 1100, finished: T - 400, visits: 2, outcome: "done"),
            N("tests", "check", "running", title: "Run the tests", rt: "claude", model: "sonnet", started: T - 120, visits: 1,
              live: ["state": "working", "doing": "Bash(make test)", "changed_at": T - 20, "seen_at": T - 5],
              loop: ["id": "fix", "round": 2, "max_iters": 3]),
            N("review", "critic", "waiting", title: "Review"), N("end", "end")],
    edges: [E("find", "fix"), E("fix", "tests"), E("tests", "review", "win"), E("tests", "fix", "fail"),
            E("review", "end", "win"), E("review", "fix", "fail")], wall: 26)
let login = G("g_login", title: "Login form", start: "plan",
    nodes: [N("plan", "researcher", "done", visits: 1),
            N("polish", "builder", "running", title: "Polish the form", rt: "codex", model: "", started: T - 2000, visits: 1,
              live: ["state": "quiet", "doing": "Update(form.css)", "changed_at": T - 14 * 60]),
            N("check", "critic", "pending"), N("end", "end")],
    edges: [E("plan", "polish"), E("polish", "check"), E("check", "end", "win")], wall: 52)
let release = G("g_release", session: "team-b", label: "Juniper", title: "Release notes", start: "gather",
    nodes: [N("gather", "researcher", "done", visits: 1),
            N("draft", "writer", "running", title: "Write the draft", rt: "claude", model: "opus", started: T - 300, visits: 1,
              live: ["state": "working", "doing": "Update(CHANGELOG.md)", "changed_at": T - 180]),
            N("check", "critic"), N("polish", "writer"), N("me", "human"), N("end", "end")],
    edges: [E("gather", "draft"), E("draft", "check"), E("check", "polish", "win"), E("check", "draft", "fail"),
            E("polish", "me"), E("me", "end", "approved")], wall: 18)
let pricingAsk: [String: Any] = ["question": "Is the new pricing page ready to publish?",
                                 "context": ["The review passed on its second round."]]
let pricing = G("g_pricing", title: "Pricing page", start: "draft",
    nodes: writeReviewNodes(["me": "waiting_human"]), edges: writeReviewEdges,
    gates: [["node": "me", "at": T - 12 * 60, "from": "review", "options": ["approved", "rejected"], "ask": pricingAsk]], wall: 40)
let onboarding = G("g_onboard", session: "team-b", label: "Juniper", title: "Onboarding emails", start: "a",
    nodes: [N("a", "writer", "done"), N("b", "writer", "pending"), N("end", "end")], edges: [E("a", "b"), E("b", "end")],
    wall: 64, pause: true, reason: "paused by you", held: 1)
let docs = G("g_docs", session: "team-c", label: "Harbor", title: "Docs refresh", start: "a",
    nodes: [N("a", "writer", "running", started: T - 540), N("end", "end")], edges: [E("a", "end")], wall: 9)
let research = G("g_research", session: "team-b", label: "Juniper", title: "Research sources", start: "",
    nodes: [N("scan", "researcher", "done", visits: 1),
            N("gather", "researcher", "running", title: "Gather the sources", rt: "grok", model: "grok-4.7", started: T - 200, visits: 1,
              live: ["state": "working", "doing": "WebSearch(\"sources\")", "changed_at": T - 40])],
    edges: [E("scan", "gather"), E("gather", "scan", "route:more")], wall: 14)
let help = G("g_help", session: "team-b", label: "Juniper", title: "Help center articles", start: "plan",
    nodes: [N("plan", "researcher", "done", visits: 1),
            N("intro", "writer", "done", title: "Intro", visits: 1),
            N("setup", "writer", "running", title: "Setup", rt: "claude", model: "opus", started: T - 400, visits: 1,
              live: ["state": "working", "doing": "Write(SETUP.md)", "changed_at": T - 70]),
            N("faq", "writer", "running", title: "FAQ", rt: "claude", model: "opus", started: T - 300, visits: 1,
              live: ["state": "working", "doing": "Write(FAQ.md)", "changed_at": T - 60]),
            N("gather", "join", "waiting"), N("review", "critic"), N("end", "end")],
    edges: [E("plan", "intro"), E("plan", "setup"), E("plan", "faq"), E("intro", "gather"), E("setup", "gather"),
            E("faq", "gather"), E("gather", "review"), E("review", "end", "win")], wall: 33)
let pipeline = G("g_pipeline", title: "Build pipeline", start: "build",
    nodes: [N("build", "builder", "done"),
            N("review", "critic", "running", title: "Review", rt: "claude", model: "sonnet", started: T - 600,
              attention: "has stopped: its AI is not running. Open its screen, or run the step again.",
              live: ["state": "no_model", "changed_at": T - 300]),
            N("end", "end")],
    edges: [E("build", "review"), E("review", "end", "win")], wall: 12)
let faster = G("g_faster", session: "team-b", label: "Juniper", title: "Faster search", status: "done",
    start: "a", nodes: [N("a", "builder", "done"), N("end", "end")], edges: [E("a", "end")],
    finished: T - 12 * 60, stop: "win")
let invoice = G("g_invoice", title: "Invoice export", status: "done", start: "a",
    nodes: [N("a", "builder", "cancelled"), N("end", "end")], edges: [E("a", "end")], finished: T - 25 * 60, stop: "cancelled")
let rounds = G("g_rounds", title: "Copy polish", status: "done", start: "a",
    nodes: [N("a", "writer", "done"), N("end", "end")], edges: [E("a", "end")], finished: T - 5 * 60,
    stop: "failed_bounded:rounds")
let broken = G("g_broken", title: "Data import", status: "done", start: "tests",
    nodes: [N("tests", "check", "failed", title: "Run the tests", outcome: "error"), N("end", "end")],
    edges: [E("tests", "end")], finished: T - 8 * 60, stop: "error", lastError: "exit 2")
let chatAsk = GChatAsk(["id": "q_1", "session": "team-a", "architect": "a_1",
                        "question": "Which launch date should I plan the release around?", "created_at": T - 9 * 60])
let architect = GArchitect(["id": "a_1", "session": "team-a", "title": "Launch plan", "runtime": "claude", "model": "opus",
                            "alive": true, "graphs": ["g_1", "g_2", "g_3"]])

let fixedClock: (Double) -> String = { _ in "3:45 pm" }
let up: Set<String> = ["team-a", "team-b"]
let names = ["team-a": "Northwind", "team-b": "Juniper", "team-c": "Harbor"]

func input(_ graphs: [GGraph], asks: [GChatAsk] = [], architects: [GArchitect] = [], limits: GLimits? = nil,
           runner: Bool? = true, engineOff: Bool = false, teams: [IslandTeamInput] = [], now: Double = T) -> IslandInput {
    var i = IslandInput()
    i.graphs = graphs
    i.asks = asks
    i.architects = architects
    i.limits = limits
    i.runnerOK = runner
    i.engineOff = engineOff
    i.runningTeams = up
    i.teamNames = names
    i.teams = teams
    i.now = now
    i.clock = fixedClock
    i.calendar = utc
    return i
}

func model(_ i: IslandInput, _ s: IslandSettings = IslandSettings(), flags: IslandModel.Flags = .init()) -> IslandModel {
    var mm = IslandModel()
    mm.update(i, settings: s, flags: flags)
    return mm
}

func row(_ st: IslandState, _ name: String) -> IslandGraphRow? { st.graphRows.first { $0.name == name } }

// MARK: - IslandModel: the closed panel (§4.2, §4.3)

section("M1  quiet: just the notch")
var mm = model(input([faster]))
check(mm.closed.isEmpty, "nothing running, nothing waiting: nothing beside the notch", "\(mm.closed)")
eq(mm.state.countQuiet, "All quiet.", "the open panel says all quiet")
eq(mm.state.countLine, [], "and no count items")
eq(mm.state.emptyTitle, "Nothing needs you.", "empty title")
eq(mm.state.emptyLine, "No graphs running. 1 finished today.", "empty line")
eq(mm.closed.accessibilityLabel, "CyberPong: nothing needs you.", "VoiceOver")

section("M2  one graph at work: the ring alone and the graph's name with its step")
mm = model(input([checkout]))
eq(mm.closed.marks, [IslandMark(status: .working, count: nil)], "the ring, no count for one graph")
eq(mm.closed.line?.text, "Checkout fix · 3/4", "name · step 3 of 4")
eq(mm.closed.line?.name, "Checkout fix", "the name is the part that may be cut")
eq(mm.closed.line?.tail, "· 3/4", "the tail is never cut")
eq(mm.closed.line?.tone, .normal, "primary and secondary")
eq(mm.closed.accessibilityLabel, "CyberPong: 1 graph working.", "VoiceOver: one sentence")

section("M3  several at work: the count, and the line takes turns every 5 s")
var flags = IslandModel.Flags()
mm = model(input([checkout, release, login]))
eq(mm.closed.marks, [IslandMark(status: .working, count: 3)], "ring and count 3")
eq(mm.state.rotation.map { $0.text }, ["Checkout fix · 3/4", "Release notes · 2/5", "Login form · quiet 14 min"],
   "the turns, in order")
eq(mm.closed.line?.text, "Checkout fix · 3/4", "the first")
mm.tick(now: T + 4.9, flags: flags)
eq(mm.closed.line?.text, "Checkout fix · 3/4", "not yet at 4.9 s")
mm.tick(now: T + 5, flags: flags)
eq(mm.closed.line?.text, "Release notes · 2/5", "the next at 5 s")
flags.pointerOverClosed = true
mm.tick(now: T + 10, flags: flags)
eq(mm.closed.line?.text, "Release notes · 2/5", "holds still while the pointer is on it")
flags.pointerOverClosed = false
mm.tick(now: T + 14, flags: flags)
eq(mm.closed.line?.text, "Release notes · 2/5", "a full turn after the pointer leaves")
mm.tick(now: T + 15, flags: flags)
let quietLine = mm.closed.line
eq(quietLine?.text, "Login form · quiet 14 min", "a quiet step takes its turn")
eq(quietLine?.tone, .quiet, "in tertiary")
var dontMove = IslandSettings(); dontMove.rotateSeconds = 0
mm = model(input([checkout, release]), dontMove)
mm.tick(now: T + 60, flags: .init())
eq(mm.closed.line?.text, "Checkout fix · 3/4", "\"Don't move\" holds the first")

section("M4  the rotation keeps its order; a graph that changes state moves to the end")
mm = model(input([checkout, release, login]))
mm.update(input([release, login, checkout], now: T + 1), settings: IslandSettings(), flags: .init())
eq(mm.rotation.order, ["g:team-a/g_checkout:work", "g:team-b/g_release:work", "g:team-a/g_login:quiet"],
   "the same graphs in another order: the order stays")
let releaseQuiet = G("g_release", session: "team-b", label: "Juniper", title: "Release notes", start: "gather",
    nodes: [N("gather", "researcher", "done"),
            N("draft", "writer", "running", title: "Write the draft", rt: "claude", model: "opus", started: T - 3000,
              live: ["state": "quiet", "changed_at": T - 1200]), N("end", "end")],
    edges: [E("gather", "draft"), E("draft", "end")])
mm.update(input([checkout, releaseQuiet, login], now: T + 2), settings: IslandSettings(), flags: .init())
eq(mm.rotation.order.last, "g:team-b/g_release:quiet", "the graph that went quiet comes back at the end")

section("M5  total unknown: step 2")
mm = model(input([research]))
eq(mm.closed.line?.text, "Research sources · step 2", "no total yet")

section("M6  needs you: amber, the oldest first, nothing moves")
mm = model(input([checkout, release, login, pricing], asks: [chatAsk], architects: [architect]))
eq(mm.closed.marks, [IslandMark(status: .needsYou, count: 2), IslandMark(status: .working, count: 3, still: true)],
   "◆ 2 and the ring held still with its count")
eq(mm.closed.line?.text, "Pricing page needs you", "the oldest question (12 min before the chat's 9)")
eq(mm.closed.line?.tone, .you, "amber")
mm.tick(now: T + 30, flags: .init())
eq(mm.closed.line?.text, "Pricing page needs you", "a question line never rotates")
check(mm.closed.accessibilityLabel.hasPrefix("CyberPong: 2 things need you. Pricing page needs you, waiting 12 minutes."),
      "VoiceOver: one sentence", mm.closed.accessibilityLabel)
check(mm.closed.accessibilityLabel.contains("3 graphs working."), "with the graphs working", mm.closed.accessibilityLabel)
mm = model(input([checkout], asks: [chatAsk], architects: [architect]))
eq(mm.closed.line?.text, "Launch plan asks you", "a chat's question")
mm = model(input([pipeline]))
eq(mm.closed.line?.text, "Build pipeline needs you", "a step asking")
eq(mm.state.needs.first?.kind, .step, "counted as a step asking")
eq(mm.state.needs.first?.text, "Review has stopped: its AI is not running", "in plain words, without the button's words")

section("M7  graph runner off (only while a graph runs) and engine off")
mm = model(input([checkout], runner: false))
eq(mm.closed.line?.text, "Graph runner off", "runner off")
eq(mm.closed.line?.tone, .fail, "red")
eq(mm.closed.marks, [IslandMark(status: .failed, count: nil)], "✕")
mm = model(input([faster], runner: false))
check(mm.closed.isEmpty && mm.state.banners.isEmpty, "with nothing running it says nothing")
mm = model(input([checkout, pricing], runner: false))
eq(mm.closed.line?.text, "Pricing page needs you", "needs you beats the runner")
mm = model(input([], engineOff: true))
eq(mm.closed.line?.text, "Engine off", "engine off")
eq(mm.state.banners.first?.kind, .engineOff, "with its banner")

section("M8  Claude's limit")
let l5 = GLimits(["state": "paused_5h", "until": T + 6000, "paused": ["g_c2"]])
let checkoutLimit = G("g_c2", title: "Checkout fix", start: "a", nodes: [N("a", "builder", "running"), N("end", "end")],
                      edges: [E("a", "end")], pause: true, reason: "paused for Claude's 5-hour limit")
let onboardLimit = G("g_o2", session: "team-b", label: "Juniper", title: "Onboarding emails", start: "a",
                     nodes: [N("a", "writer", "running"), N("end", "end")], edges: [E("a", "end")], pause: true,
                     reason: "paused for Claude's 5-hour limit")
mm = model(input([checkoutLimit, onboardLimit], limits: l5))
eq(mm.closed.line?.text, "Paused · back 3:45 pm", "paused · back at the time")
eq(mm.closed.marks, [IslandMark(status: .paused, count: 2)], "‖ 2")
eq(mm.state.banners.first?.text, "Graphs paused for Claude's 5-hour limit · back at 3:45 pm.", "the banner")
eq(mm.state.banners.first?.sub, "They go on by themselves.", "they go on by themselves")
eq(mm.state.banners.first?.action, nil, "no button: it lifts by itself")
eq(row(mm.state, "Checkout fix")?.line2, "Paused for Claude's 5-hour limit · goes on by itself at 3:45 pm", "the row")
mm = model(input([research, checkoutLimit], limits: l5))
eq(mm.state.rotation.map { $0.text }, ["Research sources · step 2", "Paused · back 3:45 pm"], "in the rotation beside a working graph")
eq(mm.closed.marks, [IslandMark(status: .working, count: nil)], "the ring for the graph at work")
let lw = GLimits(["state": "paused_week", "until": T + 86400 * 3, "usage": ["week_pct": 97]])
let weekly = G("g_w", title: "Checkout fix", start: "a", nodes: [N("a", "builder", "running"), N("end", "end")],
               edges: [E("a", "end")], pause: true, reason: "paused near Claude's weekly limit")
mm = model(input([weekly], limits: lw))
eq(mm.closed.line?.text, "Paused · weekly limit", "the weekly limit")
eq(mm.state.banners.first?.text, "This week's Claude use is at 97% · graphs paused · back 3:45 pm", "its banner")
eq(mm.state.banners.first?.action, "Resume anyway", "with Resume anyway")
eq(row(mm.state, "Checkout fix")?.line2, "Paused near Claude's weekly limit", "its row")
mm = model(input([checkout], limits: GLimits(["state": "ok", "usage": ["week_pct": 84]])))
eq(mm.state.footerWeek, "Claude this week: 84%", "the week at 84% in the footer")

section("M9  paused by you; waits for its team")
mm = model(input([onboarding]))
eq(mm.closed.line?.text, "Paused by you · Onboarding emails", "paused by you")
eq(mm.closed.line?.head, "Paused by you · ", "the head is never cut; the name may be")
eq(mm.closed.marks, [IslandMark(status: .paused, count: nil)], "‖")
mm = model(input([docs]))
eq(mm.closed.line?.text, "Docs refresh · team stopped", "waits for its team")
eq(mm.closed.marks, [IslandMark(status: .pending, count: nil)], "○")
eq(mm.closed.line?.tone, .quiet, "tertiary")
mm = model(input([docs, onboarding]))
eq(mm.closed.line?.text, "Paused by you · Onboarding emails", "paused by you comes before waits for its team")
mm = model(input([docs, checkout]))
eq(mm.closed.line?.text, "Checkout fix · 3/4", "a graph at work comes before both")

section("M10  a graph that just finished: a 3-second note that never covers a question")
mm = model(input([checkout, release]))
let checkoutDone = G("g_checkout", title: "Checkout fix", status: "done", start: "find",
                     nodes: [N("find", "researcher", "done"), N("end", "end")], edges: [E("find", "end")],
                     finished: T + 1, stop: "win")
mm.update(input([checkoutDone, release], now: T + 2), settings: IslandSettings(), flags: .init())
eq(mm.closed.line?.text, "Checkout fix · passed", "passed")
eq(mm.closed.marks, [IslandMark(status: .done, count: nil)], "✓")
mm.tick(now: T + 4.9, flags: .init())
eq(mm.closed.line?.text, "Checkout fix · passed", "still at 2.9 s")
mm.tick(now: T + 5.1, flags: .init())
eq(mm.closed.line?.text, "Release notes · 2/5", "then back")
for (stop, tail, mark) in [("cancelled", "stopped", PongStatus.stopped), ("failed_bounded:rounds", "failed", .failed)] {
    var m2 = model(input([checkout]))
    let g2 = G("g_checkout", title: "Checkout fix", status: "done", start: "find", nodes: [N("find"), N("end", "end")],
               edges: [E("find", "end")], finished: T + 1, stop: stop)
    m2.update(input([g2], now: T + 1), settings: IslandSettings(), flags: .init())
    eq(m2.closed.line?.text, "Checkout fix · " + tail, tail)
    eq(m2.closed.marks.first?.status, mark, tail + " mark")
}
mm = model(input([checkout, pricing]))
mm.update(input([checkoutDone, pricing], now: T + 2), settings: IslandSettings(), flags: .init())
eq(mm.closed.line?.text, "Pricing page needs you", "needs you beats the finished note")
mm = model(input([checkoutDone]))
eq(mm.closed.line, nil, "a graph finished before the panel started gets no note")

section("M11  beside the notch: words, just the count, only when something needs me")
var countOnly = IslandSettings(); countOnly.beside = .count
mm = model(input([checkout, release]), countOnly)
check(mm.closed.line == nil && mm.closed.marks == [IslandMark(status: .working, count: 2)], "just the count")
var needsMe = IslandSettings(); needsMe.beside = .needsMe
mm = model(input([checkout, release]), needsMe)
check(mm.closed.isEmpty, "only when something needs me: folded while nothing does")
mm = model(input([checkout, pricing]), needsMe)
eq(mm.closed.line?.text, "Pricing page needs you", "and shows when something does")

section("M12  Teams view: the line follows a busy team; the count still counts graphs")
let northwind = IslandTeamInput(session: "team-a", name: "Northwind", running: true, status: .working,
    plainLine: "Lead: Claude Opus · 2 helpers · 1 graph needs you · 2 working",
    members: [.init(isLead: true, ai: "Claude Opus", status: .working, word: "Working", doing: "Checking the test results"),
              .init(isLead: false, ai: "Claude Sonnet", status: .working, word: "Working", graphTitle: "Checkout fix", stepName: "Run the tests"),
              .init(isLead: false, ai: "Codex", status: .pending, word: "Idle")],
    lastMessage: "The tests pass. Review starts next.", lastMessageAt: T - 4 * 60)
let harbor = IslandTeamInput(session: "team-c", name: "Harbor", running: false, status: .stopped,
    plainLine: "Lead: Claude Sonnet · 1 helper · stopped · 1 graph waits for it",
    members: [.init(isLead: true, ai: "Claude Sonnet", status: .stopped, word: "Stopped")])
var teamsView = IslandSettings(); teamsView.view = .teams
mm = model(input([checkout, login, release], teams: [northwind, harbor]), teamsView)
eq(mm.closed.line?.text, "Northwind · 2 AIs working", "a busy team")
eq(mm.closed.marks, [IslandMark(status: .working, count: 3)], "the count still counts graphs")
let leadOnly = IslandTeamInput(session: "team-a", name: "Northwind", running: true, status: .working, plainLine: "",
    members: [.init(isLead: true, ai: "Claude Opus", status: .working, word: "Working", doing: "Writing the plan")])
mm = model(input([checkout], teams: [leadOnly]), teamsView)
eq(mm.closed.line?.text, "Northwind · lead is writing the plan", "the lead alone, in its own words")
var auto = IslandSettings(); auto.view = .automatic
eq(model(input([checkout]), auto).state.view, .graphs, "automatic: Graphs while a graph is on")
eq(model(input([faster]), auto).state.view, .teams, "automatic: Teams when none is")
mm = model(input([checkout, pricing], teams: [northwind]), teamsView)
eq(mm.closed.line?.text, "Pricing page needs you", "questions show the same in both views")

section("M13  the nudge of a new question (§14.3)")
mm = model(input([checkout]))
check(mm.closed.nudge == nil, "nothing new yet")
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init())
var n1 = mm.closed.nudge
eq(n1?.title, "Is the new pricing page ready to publish?", "the question itself")
eq(n1?.source, "Northwind › Pricing page", "and where it comes from")
eq(n1?.until, T + 7, "for 6 seconds")
eq(mm.announcement, "Pricing page needs you: Is the new pricing page ready to publish?", "VoiceOver says it once")
eq(mm.closed.line?.text, "Pricing page needs you", "the amber line under it")
mm.tick(now: T + 6.9, flags: .init())
check(mm.closed.nudge != nil, "still there at 5.9 s")
eq(mm.announcement, nil, "said only once")
mm.tick(now: T + 7, flags: .init())
check(mm.closed.nudge == nil, "folds back after 6 s")
eq(mm.closed.marks.first, IslandMark(status: .needsYou, count: 1), "the amber count stays")

mm = model(input([checkout]))
mm.update(input([checkout, pricing, pipeline], asks: [chatAsk], architects: [architect], now: T + 1),
          settings: IslandSettings(), flags: .init())
n1 = mm.closed.nudge
eq(n1?.source, "Pricing page needs you · and 2 more", "several at once: one nudge")
eq(n1?.key, "team-a/g_pricing#me", "it opens at the oldest")
let research2 = G("g_r2", title: "Research two", start: "a", nodes: [N("a", "human", "waiting_human"), N("end", "end")],
                  edges: [E("a", "end")], gates: [["node": "a", "at": T + 2, "ask": ["question": "Keep these sources?"]]])
mm.update(input([checkout, pricing, pipeline, research2], asks: [chatAsk], architects: [architect], now: T + 3),
          settings: IslandSettings(), flags: .init())
eq(mm.closed.nudge?.source, "Pricing page needs you · and 3 more", "one more joins the nudge on show")
eq(mm.closed.nudge?.until, T + 9, "and its time starts again")

mm = model(input([checkout, pricing]))
check(mm.closed.nudge == nil, "questions already there when the panel starts don't nudge")
mm.update(input([checkout, pricing, research2], now: T + 3), settings: IslandSettings(), flags: .init())
eq(mm.closed.nudge?.title, "Keep these sources?", "a new question nudges while an older one waits")
eq(mm.closed.line?.text, "Research two needs you", "the words beside the notch name the nudged question")
mm.tick(now: T + 9, flags: .init())
check(mm.closed.nudge == nil, "the nudge folds back")
eq(mm.closed.line?.text, "Pricing page needs you", "then the oldest question again")

// at launch the panel reads the feed before its first good read (empty): that read is no baseline
var boot = input([]); boot.loaded = false
mm = model(boot)
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init())
check(mm.closed.nudge == nil && mm.arrived.isEmpty && mm.announcement == nil,
      "launch: what the first good read finds doesn't nudge", "\(String(describing: mm.closed.nudge))")
eq(mm.closed.line?.text, "Pricing page needs you", "launch: the amber line still shows the oldest question")
var bootOpen = IslandSettings(); bootOpen.onQuestion = .open
var mo = model(boot, bootOpen)
mo.update(input([checkout, pricing], now: T + 1), settings: bootOpen, flags: .init())
check(mo.arrived.isEmpty, "launch: nothing opens the whole panel")
mm.update(input([checkout, pricing, research2], now: T + 3), settings: IslandSettings(), flags: .init())
eq(mm.closed.nudge?.title, "Keep these sources?", "a question after the first good read nudges")
// a failed first read (and a failed one later, which keeps the last good graphs) takes no baseline either
var failed = input([]); failed.loaded = false
mm = model(failed)
mm.update(failed, settings: IslandSettings(), flags: .init())
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init())
check(mm.closed.nudge == nil && mm.arrived.isEmpty, "a failed first read, then a good one: no nudge")
var failedLater = input([checkout, pricing], now: T + 2); failedLater.loaded = false
mm.update(failedLater, settings: IslandSettings(), flags: .init())
check(mm.closed.nudge == nil && mm.arrived.isEmpty, "a failed read later: nothing new")
mm.update(input([checkout, pricing, research2], now: T + 3), settings: IslandSettings(), flags: .init())
eq(mm.arrived.map { $0.key }, ["team-a/g_r2#a"], "after it, only the question that is new nudges")

var nightModel = model(input([checkout], now: night))
nightModel.update(input([checkout, pricing], now: night + 1), settings: IslandSettings(), flags: .init())
check(nightModel.closed.nudge == nil && nightModel.arrived.isEmpty, "quiet at night: no nudge, nothing opens")
eq(nightModel.closed.marks.first?.status, .needsYou, "the amber count still shows")
var noQuiet = IslandSettings(); noQuiet.quietNight = false
nightModel = model(input([checkout], now: night), noQuiet)
nightModel.update(input([checkout, pricing], now: night + 1), settings: noQuiet, flags: .init())
check(nightModel.closed.nudge != nil, "with quiet at night off, it nudges at 11 pm")

var amberOnly = IslandSettings(); amberOnly.onQuestion = .amber
mm = model(input([checkout]), amberOnly)
mm.update(input([checkout, pricing], now: T + 1), settings: amberOnly, flags: .init())
check(mm.closed.nudge == nil && mm.arrived.count == 1, "only the amber count: no nudge (the new one is still reported)")
var openWhole = IslandSettings(); openWhole.onQuestion = .open
mm = model(input([checkout]), openWhole)
mm.update(input([checkout, pricing], now: T + 1), settings: openWhole, flags: .init())
check(mm.closed.nudge == nil && mm.arrived.first?.key == "team-a/g_pricing#me", "open the whole panel: the controller opens at it")

mm = model(input([checkout]))
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init(panelOpen: true))
check(mm.closed.nudge == nil, "no nudge while the panel is open")
mm = model(input([checkout]))
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init(nudgeAllowed: false))
check(mm.closed.nudge == nil, "no nudge in a full-screen app set to hide it")

var untilLook = IslandSettings(); untilLook.nudgeSeconds = 0
mm = model(input([checkout]), untilLook)
mm.update(input([checkout, pricing], now: T + 1), settings: untilLook, flags: .init())
mm.tick(now: T + 600, flags: .init())
check(mm.closed.nudge != nil && mm.closed.nudge?.until == nil, "until I look: it waits")
mm.nudgeLooked()
check(mm.closed.nudge == nil, "the pointer visited it: gone")

mm = model(input([checkout]))
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init())
mm.update(input([checkout], now: T + 2), settings: IslandSettings(), flags: .init())
check(mm.closed.nudge == nil, "answered elsewhere: the nudge folds away")
mm.update(input([checkout, pricing], now: T + 3), settings: IslandSettings(), flags: .init())
mm.tick(now: T + 3.5, flags: .init(panelOpen: true))
check(mm.closed.nudge == nil, "the panel opened: the nudge has done its job")

// MARK: - IslandModel: the open panel (§5)

section("O1  the count line")
mm = model(input([checkout, release, login, pricing, onboarding, docs], asks: [chatAsk], architects: [architect]))
eq(mm.state.countLine.map { $0.words }, ["2 need you", "3 working", "1 paused", "1 waits for its team"], "every item")
eq(mm.state.countLine.first?.dim, false, "amber lit")
check(mm.state.countLine[1].still, "the ring holds still while anything needs you")
mm = model(input([checkout]))
eq(mm.state.countLine.map { $0.words }, ["0 need you", "1 working"], "the amber item shows at 0")
eq(mm.state.countLine.first?.dim, true, "dimmed")
mm = model(input([docs, G("g_d2", session: "team-c", label: "Harbor", title: "Docs two", start: "a",
                          nodes: [N("a", "writer", "running"), N("end", "end")], edges: [E("a", "end")])]))
eq(mm.state.countLine.last?.words, "2 wait for their teams", "plural")

section("O2  needs you: oldest first, the focused card is the first that can be one")
mm = model(input([pipeline, pricing], asks: [chatAsk], architects: [architect]))
eq(mm.state.needs.map { $0.kind }, [.question, .chat, .step], "pricing 12 min, the chat 9 min, the step 5 min")
eq(mm.state.focusIndex, 0, "the pricing question is the focused card")
eq(mm.state.needs[1].rowText, "Launch plan chat asks: Which launch date should I plan the release around?", "a chat's row")
eq(mm.state.needs[1].waited(now: T), "9 min", "waiting 9 min")
eq(mm.state.needs[2].rowText, "Build pipeline · Review has stopped: its AI is not running", "a step's row")
mm = model(input([pipeline]))
eq(mm.state.focusIndex, nil, "a step asking can't be a card")
check(mm.state.compact, "rows go compact while anything waits")
let justNow = IslandNeed(kind: .question, key: "k", graphKey: "g", chatKey: "", session: "s", nodeId: "", subject: "S",
                         text: "Q?", source: "", openedAt: T - 20)
eq(justNow.waited(now: T), "just now", "just now for 30 s")

section("O3  every graph row's words (§5.5)")
mm = model(input([checkout, release, login, research, help, pipeline, onboarding, docs, pricing, faster, invoice, rounds, broken]))
var rw = row(mm.state, "Checkout fix")!
eq(rw.line2, "Step 3 of 4 · Run the tests", "working: step and name (Fix was sent back, not this step)")
eq(rw.line2Meta, "Claude Sonnet · round 2 of 3", "the AI and the round, in tertiary")
eq(rw.line3, "Running a command", "what it is doing")
eq(rw.line3Age, "20 s ago", "and how long ago")
eq(rw.track, [.done, .done, .now, .ahead], "the track")
eq(rw.fraction, "3/4", "3/4")
eq(rw.time, "26 min", "time spent")
eq(rw.marker, .working, "the ring")
check(rw.canPause && !rw.canResume, "hover: Pause")
eq(rw.sentBack, 0, "this step wasn't sent back")
let sentBackGraph = G("g_sb", title: "Brochure", start: "draft",
    nodes: [N("draft", "writer", "running", title: "Draft", started: T - 60, visits: 2,
              live: ["state": "working", "doing": "Update(BROCHURE.md)", "changed_at": T - 30]),
            N("review", "critic", "done", visits: 1, outcome: "fail"), N("me", "human"), N("end", "end")],
    edges: writeReviewEdges)
let sbRow = row(model(input([sentBackGraph])).state, "Brochure")!
eq(sbRow.line2, "Step 1 of 3 · Draft · sent back once", "a step the work went back to says so")
eq(sbRow.sentBack, 1, "sent back once")
eq(sbRow.track, [.now, .ahead, .ahead], "and its track eases back: the review ahead again")
eq(rw.accessibilityLabel, "Checkout fix, Northwind. Working: Run the tests, step 3 of 4, Claude Sonnet, round 2 of 3. Running a command, 20 seconds ago. 26 minutes.",
   "VoiceOver reads the row as one group")
rw = row(mm.state, "Release notes")!
eq(rw.line2, "Step 2 of 5 · Write the draft", "release: step 2 of 5")
eq(rw.line2Meta, "Claude Opus", "no round before the work has gone round")
eq(rw.line3, "Editing CHANGELOG.md", "editing")
eq(rw.line3Age, "3 min ago", "older than 2 minutes shows its age")
rw = row(mm.state, "Login form")!
eq(rw.marker, .stale, "quiet: the dashed circle")
check(rw.titleDim, "its title in secondary")
eq(rw.line2, "Step 2 of 3 · Polish the form", "the same second line")
eq(rw.line2Meta, "Codex", "its AI")
eq(rw.line3, "No news for 14 min", "no news for 14 min")
eq(rw.action, .watch, "[Watch]")
rw = row(mm.state, "Research sources")!
eq(rw.line2, "Step 2 · Gather the sources", "total unknown: step 2")
eq(rw.line2Meta, "Grok 4.7", "Grok 4.7")
eq(rw.line3, "Looking on the web", "looking on the web")
eq(rw.track, [.done, .now], "a track as far as it is known")
rw = row(mm.state, "Help center articles")!
eq(rw.line2, "Step 2 of 4 · Setup, FAQ at once", "steps at once")
eq(rw.line3, "1 of 3 done · Editing FAQ.md", "how many of them are done, and the newest's doing line")
rw = row(mm.state, "Build pipeline")!
eq(rw.marker, .needsYou, "its AI isn't running: amber")
eq(rw.line2, "Needs you: Review has stopped: its AI is not running", "in words")
eq(rw.action, .openScreen, "[Open its screen]")
rw = row(mm.state, "Onboarding emails")!
eq(rw.line2, "Paused by you · 1 step waiting to start", "paused by you")
check(rw.canResume && rw.action == .resume, "[Resume]")
eq(rw.marker, .paused, "‖")
rw = row(mm.state, "Docs refresh")!
eq(rw.line2, "Waits for its team to start", "waits for its team")
eq(rw.action, .startTeam, "[Start team]")
eq(rw.marker, .pending, "○")
check(row(mm.state, "Pricing page") == nil, "a graph at a question isn't listed again")
rw = row(mm.state, "Faster search")!
check(rw.oneLine && rw.line2 == "Finished · passed" && rw.time == "12 min ago" && rw.marker == .done, "finished, passed",
      "\(rw.line2) \(rw.time)")
rw = row(mm.state, "Invoice export")!
check(rw.line2 == "Stopped by you" && rw.marker == .stopped, "stopped by you")
rw = row(mm.state, "Copy polish")!
check(rw.line2 == "Stopped · out of rounds" && rw.marker == .failed && rw.action == .openGraph, "out of rounds", rw.line2)
rw = row(mm.state, "Data import")!
check(rw.line2 == "Failed · Run the tests hit an error" && rw.action == .openGraph, "failed", rw.line2)
eq(mm.state.graphGroups.map { $0.title }, ["Working", "Paused or waiting", "Finished · last 30 min"], "the three groups")
eq(mm.state.graphGroups.last?.foldTitle, "Show 4 finished", "finished folded")
eq(mm.state.graphGroups[0].rows.map { $0.name },
   ["Checkout fix", "Release notes", "Login form", "Research sources", "Help center articles", "Build pipeline"], "working, in order")
var keep10 = IslandSettings(); keep10.keepFinishedMinutes = 10
mm = model(input([faster, invoice, rounds, broken]), keep10)
eq(mm.state.graphGroups.last?.rows.map { $0.name }, ["Copy polish", "Data import"], "finished kept for 10 min")
eq(mm.state.graphGroups.last?.title, "Finished · last 10 min", "and says so")

section("O4  the engine's own words win when it sends them")
let withNow = G("g_now", title: "Checkout fix", start: "find",
    nodes: [N("find", "researcher", "done"), N("tests", "check", "running", started: T - 100), N("end", "end")],
    edges: [E("find", "tests"), E("tests", "end")],
    now: ["state": "working", "step": "tests", "step_name": "Run the tests", "step_n": 3, "steps": 4, "runtime": "claude",
          "model": "sonnet", "doing": "Bash(make test)", "doing_plain": "Running the tests", "doing_changed_at": T - 20,
          "round": 2, "rounds": 3, "sent_back": 2])
mm = model(input([withNow]))
rw = row(mm.state, "Checkout fix")!
eq(rw.line2, "Step 3 of 4 · Tests · sent back 2 times", "place, total and send-backs from the engine")
eq(rw.line2Meta, "Claude Sonnet · round 2 of 3", "its AI and round")
eq(rw.line3, "Running the tests", "its plain doing line")
let titled = G("g_t", title: "Titled", start: "a",
    nodes: [N("a", "builder", "running", title: "Run the tests", started: T - 100,
              live: ["state": "working", "doing": "Bash(make)", "doing_plain": "Running make", "changed_at": T - 5])],
    edges: [])
eq(row(model(input([titled])).state, "Titled")?.line3, "Running make", "a step's own plain doing line from the engine")
eq(row(model(input([titled])).state, "Titled")?.line3Age, "just now", "just now")

section("O5  no doing line yet; between steps; the graph runner off")
let started = G("g_s", title: "Fresh", start: "a",
    nodes: [N("a", "builder", "running", title: "Build", started: T - 240)], edges: [])
eq(row(model(input([started])).state, "Fresh")?.line3, "Started 4 min ago", "started 4 min ago")
let between = G("g_b", title: "Between", start: "find",
    nodes: [N("find", "researcher", "done", finished: T - 30), N("fix", "builder", "ready", title: "Fix"), N("check", "critic"),
            N("end", "end")],
    edges: [E("find", "fix"), E("fix", "check"), E("check", "end")])
rw = row(model(input([between])).state, "Between")!
eq(rw.line2, "Step 1 of 3 done · moving to Fix", "between steps")
eq(rw.line3, nil, "no third line")
eq(rw.track, [.done, .ahead, .ahead], "its track")
eq(model(input([between])).closed.line?.text, "Between · 1/3", "the closed line still names the place")
eq(row(model(input([between], runner: false)).state, "Between")?.line2, "Waits for the graph runner", "with the runner off")

section("O6  a graph's step list")
rw = row(model(input([checkout])).state, "Checkout fix")!
eq(rw.steps.map { "\($0.number) \($0.name) · \($0.words)" },
   ["01 Find the cause · finished", "02 Fix · sent back once · finished", "03 Run the tests · running a command · Claude Sonnet",
    "04 Review · waiting for the steps before it"], "numbered in place order, in the Steps list's words")
eq(rw.steps.map { $0.time }, ["6 min", "11 min", "2 min", ""], "with their times")
eq(rw.steps.map { $0.status }, [.done, .done, .working, .pending], "and their markers")
let longGraph = G("g_long", title: "Long", start: "s1",
    nodes: (1...11).map { N("s\($0)", "builder", $0 == 1 ? "running" : "pending") }, edges: (1..<11).map { E("s\($0)", "s\($0 + 1)") })
rw = row(model(input([longGraph])).state, "Long")!
check(rw.steps.count == 8 && rw.moreSteps == 3, "at most 8, then how many more", "\(rw.steps.count) \(rw.moreSteps)")

section("O7  problems that aren't questions")
let withError = G("g_err", title: "Checkout fix", start: "a",
    nodes: [N("a", "builder", "done"), N("tests", "check", "failed", title: "Run the tests"), N("end", "end")],
    edges: [E("a", "tests"), E("tests", "end")])
mm = model(input([withError]))
eq(mm.state.problems.map { $0.title }, ["Run the tests hit an error"], "a red card")
eq(mm.state.problems.first?.line, "Checkout fix · Northwind", "with its graph and team")
eq(mm.state.needsCount, 0, "not counted amber")

section("O8  the Teams view's rows (§5.6)")
mm = model(input([checkout, pricing, login, docs], asks: [chatAsk], architects: [architect], teams: [northwind, harbor]))
let nw = mm.state.teamRows[0]
eq(nw.members.map { $0.text }, ["Lead · Claude Opus — checking the test results",
                                "Helper 1 · Claude Sonnet — Checkout fix › Run the tests", "Helper 2 · Codex — idle"],
   "members numbered in the order shown, with what each is doing")
eq(nw.lastMessage, "Lead, 4 min ago: The tests pass. Review starts next.", "the lead's latest message")
eq(nw.chips.map { $0.text }, ["Checkout fix 3/4", "Pricing page ◆", "Login form 2/3"], "graph chips")
eq(nw.chips.map { $0.needsYou }, [false, true, false], "the one at a question is marked")
eq(nw.graphs, "3 graphs", "3 graphs")
eq(nw.accessibilityLabel, "Northwind. Lead: Claude Opus, 2 helpers, 1 graph needs you, 2 working.", "VoiceOver")
let hb = mm.state.teamRows[1]
check(hb.stopped && hb.members.isEmpty && hb.marker == .stopped, "a stopped team offers Start team")
eq(hb.chips.map { $0.text }, ["Docs refresh"], "its graph waits for it")
eq(mm.state.chatRows, [IslandChatRow(key: "team-a/a_1", title: "Launch plan chat",
                                     line: "Claude Opus · 3 graphs · asked you a question", live: true)], "the chat row")
mm = model(input([checkout]))
eq(mm.state.teamsEmptyTitle, "No teams yet.", "no teams")
let noDoing = IslandTeamInput(session: "team-a", name: "Northwind", running: true, status: .working, plainLine: "",
    members: [.init(isLead: true, ai: "", status: .working, word: "Working"), .init(isLead: false, ai: "Codex", status: .needsYou, word: "Needs you")])
mm = model(input([], teams: [noDoing]))
eq(mm.state.teamRows[0].members.map { $0.text }, ["Lead — working", "Helper 1 · Codex — needs you"],
   "without the engine's doing lines: the plain word")

// MARK: - Plain words only (§2, §13.3)

section("C1  checker fixes: the engine's doing table, hand-edited numbers, stop reasons in words")
eq(Words.doing("notes - list_files (MCP)(path: \"/tmp/project\")"), nil, "an MCP tool is tool text: hidden")
eq(Words.doing("mcp__notes__list_files(path: \"/tmp\")"), nil, "a tool name in lower case is tool text too")
eq(Words.doing("⏺ Update Todos"), "Updating its to-do list", "the to-do list, as the engine says it")
eq(Words.doing("Read 3 files (ctrl+o to see all)"), "Read 3 files", "every fold hint comes off")
eq(Words.doing("checking (3 of 5) files"), "checking (3 of 5) files", "a sentence with brackets stays")
eq(S(.shortcut, ["key_code": 1e30, "modifiers": cmdShift]).shortcut, nil, "a huge key code is refused, not a crash")
eq(S(.shortcut, ["key_code": 34, "modifiers": 1e30]).shortcut, nil, "huge modifiers are refused, not a crash")
eq(S(.keepFinished, 1e30).keepFinishedMinutes, 240, "a huge keep-finished reads as the longest choice")
eq(S(.keepFinished, -5).keepFinishedMinutes, 10, "a negative one as the shortest")
eq(Words.outcome("failed_bounded:wall"), "Out of time", "a graph past its time budget")
eq(Words.outcome("failed_bounded:no_progress"), "Failed the same way twice", "a step failing the same way twice")
func ended(_ stop: String, lastError: String = "") -> GGraph {
    G("g_end_" + stop.replacingOccurrences(of: ":", with: "-"), title: "Ended graph", status: "done", start: "tests",
      nodes: [N("tests", "check", stop.hasPrefix("error") ? "failed" : "done", title: "Run the tests",
                outcome: stop.hasPrefix("error") ? "error" : "done"), N("end", "end")],
      edges: [E("tests", "end")], finished: T - 60, stop: stop, lastError: lastError)
}
for (stop, want) in [("failed_bounded:no_progress", "Stopped · failed the same way twice"),
                     ("failed_bounded:wall", "Stopped · out of time"), ("failed_bounded:jobs", "Stopped · out of jobs"),
                     ("error:tests", "Failed · Run the tests hit an error")] {
    let g = ended(stop)
    eq(g.pongStatus, .failed, "\(stop): the graph failed")
    eq(g.plainStatus, want, "\(stop): in words")
}
let errored = row(model(input([ended("error:tests")])).state, "Ended graph")
check(errored?.state == .failed && errored?.marker == .failed && errored?.line2 == "Failed · Run the tests hit an error",
      "a graph that ended on a step's error is a failed row, not a finished one", String(describing: errored?.line2))
let wasRunning = G("g_end_error-tests", title: "Ended graph", start: "tests",
                   nodes: [N("tests", "check", "running", title: "Run the tests", started: T - 100), N("end", "end")],
                   edges: [E("tests", "end")])
var endModel = model(input([wasRunning]))
endModel.update(input([ended("error:tests")], now: T + 1), settings: IslandSettings(), flags: .init())
eq(endModel.closed.line?.text, "Ended graph · failed", "its 3-second note says failed")
eq(endModel.closed.marks, [IslandMark(status: .failed, count: nil)], "with the red cross")

// between steps: the engine names the step that comes next
let betweenNext = G("g_between", title: "Release notes", start: "draft",
    nodes: [N("draft", "writer", "done", title: "Write the draft", finished: T - 30), N("review", "critic", "waiting", title: "Review"),
            N("end", "end")], edges: [E("draft", "review"), E("review", "end", "win")],
    now: ["state": "between_steps", "step": "draft", "step_n": 1, "steps": 2, "next_name": "Review"])
eq(row(model(input([betweenNext])).state, "Release notes")?.line2, "Step 1 of 2 done · moving to Review", "moving to the next step")

// the last copy still at work keeps the count; copies of one step are named once
let lastCopy = G("g_last", title: "Help pages", start: "plan",
    nodes: [N("plan", "researcher", "done"), N("w#1", "writer", "done", title: "Write", copyOf: "w"),
            N("w#2", "writer", "done", title: "Write", copyOf: "w"),
            N("w#3", "writer", "running", title: "Write", copyOf: "w", rt: "claude", model: "opus", started: T - 300,
              live: ["state": "working", "doing": "Write(FAQ.md)", "changed_at": T - 60]), N("end", "end")],
    edges: [E("plan", "w#1"), E("plan", "w#2"), E("plan", "w#3"), E("w#1", "end"), E("w#2", "end"), E("w#3", "end")],
    now: ["state": "working", "step": "w#3", "step_n": 2, "steps": 2, "at_once": 1, "at_once_names": ["Write"],
          "at_once_done": 2, "doing": "Write(FAQ.md)", "doing_plain": "Editing FAQ.md", "doing_changed_at": T - 60])
let lc = row(model(input([lastCopy])).state, "Help pages")
eq(lc?.line3, "2 of 3 done · Editing FAQ.md", "the last copy at work: 2 of 3 done")
let threeCopies = G("g_three", title: "Help pages", start: "plan",
    nodes: [N("plan", "researcher", "done")] + (1...3).map {
        N("w#\($0)", "writer", "running", title: "Write", copyOf: "w", rt: "claude", model: "opus", started: T - 300) } + [N("end", "end")],
    edges: [E("plan", "w#1"), E("plan", "w#2"), E("plan", "w#3"), E("w#1", "end"), E("w#2", "end"), E("w#3", "end")],
    now: ["state": "working", "step": "w#3", "step_n": 2, "steps": 2, "at_once": 3, "at_once_names": ["Write"], "at_once_done": 0])
eq(row(model(input([threeCopies])).state, "Help pages")?.line2, "Step 2 of 2 · Write · 3 at once", "three copies of one step")
// without the engine's names: copies go by their own names, without their numbers, once each
func copies(_ titles: [String]) -> GGraph {
    G("g_copies", title: "Copies", start: "plan",
      nodes: [N("plan", "researcher", "done")] + titles.enumerated().map { i, t in
        N("w#\(i + 1)", "writer", "running", title: t, copyOf: "w", rt: "claude", model: "opus", started: T - 300) } + [N("end", "end")],
      edges: [E("plan", "w#1"), E("plan", "w#2"), E("plan", "w#3"), E("w#1", "end"), E("w#2", "end"), E("w#3", "end")])
}
eq(row(model(input([copies(["Intro", "Setup", "FAQ"])])).state, "Copies")?.line2, "Step 2 of 2 · Intro, Setup, FAQ at once",
   "copies with names of their own: no numbers")
eq(row(model(input([copies(["Write", "Write", "Write"])])).state, "Copies")?.line2, "Step 2 of 2 · Write · 3 at once",
   "copies of one step without the engine's names: named once")

// a step that hit an error with nothing else at work: the row says so, its place in red
let failedStep = G("g_failed_step", title: "Checkout fix", start: "find",
    nodes: [N("find", "researcher", "done", finished: T - 900), N("fix", "builder", "done", finished: T - 300, visits: 2),
            N("tests", "check", "failed", title: "Run the tests", outcome: "error"), N("review", "critic"), N("end", "end")],
    edges: [E("find", "fix"), E("fix", "tests"), E("tests", "review", "win"), E("review", "end", "win")])
rw = row(model(input([failedStep])).state, "Checkout fix")!
eq(rw.line2, "Step 3 of 4 · Run the tests hit an error", "not \"Step 2 of 4 done\"")
eq(rw.marker, .failed, "a red ✕")
eq(rw.track, [.done, .done, .failed, .ahead], "its place in red")
eq(rw.fraction, "3/4", "the failed step's place")
eq(row(model(input([failedStep], runner: false)).state, "Checkout fix")?.line2, "Step 3 of 4 · Run the tests hit an error",
   "the error comes before the graph runner")
let fm = model(input([failedStep]))
eq(fm.state.workingCount, 0, "not counted as working")
check(fm.state.countQuiet.isEmpty, "not \"All quiet.\" with a problem showing", fm.state.countQuiet)
eq(fm.closed.line?.text, "Checkout fix · hit an error", "beside the notch: what holds it")
eq(fm.closed.line?.tone, .fail, "in red")
eq(fm.closed.marks.map { $0.status }, [.failed], "with the red ✕, not a turning ring")

// the lead's words beside the notch only when they read after "is" and fit
func leadDoing(_ d: String) -> IslandTeamInput {
    IslandTeamInput(session: "team-a", name: "Northwind", running: true, status: .working, plainLine: "",
                    members: [.init(isLead: true, ai: "Claude Opus", status: .working, word: "Working", doing: d)])
}
eq(model(input([checkout], teams: [leadDoing("I'll check the tests now.")]), teamsView).closed.line?.text,
   "Northwind · 1 AI working", "a sentence that isn't an -ing phrase counts the AIs")
eq(model(input([checkout], teams: [leadDoing("Editing island-2-mockup.html")]), teamsView).closed.line?.text,
   "Northwind · 1 AI working", "too long to sit beside the notch: counts the AIs")
eq(IslandWords.lowerFirst("I'll check the tests"), "I'll check the tests", "\"I\" keeps its capital")
eq(IslandWords.lowerFirst("Checking the tests"), "checking the tests", "a sentence's first word drops it")

// Claude's limit holds the graphs but none reads as limit-paused: the pause sign, never the ring
mm = model(input([], limits: l5))
eq(mm.closed.line?.text, "Paused · back 3:45 pm", "only the limit to say")
eq(mm.closed.marks, [IslandMark(status: .paused, count: nil)], "with the pause sign")
// the person's own reason with "week" in it is their pause, not Claude's weekly limit
let nextWeek = G("g_nw", title: "Onboarding emails", start: "a", nodes: [N("a", "writer", "done"), N("b", "writer"), N("end", "end")],
                 edges: [E("a", "b"), E("b", "end")], pause: true, reason: "back next week")
eq(row(model(input([nextWeek])).state, "Onboarding emails")?.state, .pausedByYou, "\"back next week\" is paused by you")

// a long command mid-turn, nothing new on screen for 15 min: at work, not quiet (the engine's rule)
let longRun = G("g_long", title: "Data import", start: "load",
    nodes: [N("load", "builder", "running", title: "Load the rows", rt: "claude", model: "sonnet", started: T - 1200,
              live: ["state": "working", "busy": true, "doing": "Bash(make import)", "changed_at": T - 900]), N("end", "end")],
    edges: [E("load", "end")])
eq(row(model(input([longRun])).state, "Data import")?.state, .working, "busy for 15 min with a still screen: working")

// VoiceOver hears a new question with "Only turn the count amber" too, and one joining a nudge
mm = model(input([checkout]), amberOnly)
mm.update(input([checkout, pricing], now: T + 1), settings: amberOnly, flags: .init())
eq(mm.announcement, "Pricing page needs you: Is the new pricing page ready to publish?", "said without a nudge")
mm = model(input([checkout]))
mm.update(input([checkout, pricing], now: T + 1), settings: IslandSettings(), flags: .init())
mm.update(input([checkout, pricing, research2], now: T + 3), settings: IslandSettings(), flags: .init())
eq(mm.announcement, "Research two needs you: Keep these sources?", "the one that joined is said, not the first again")
var nightSay = model(input([checkout], now: night))
nightSay.update(input([checkout, pricing], now: night + 1), settings: IslandSettings(), flags: .init())
eq(nightSay.announcement, nil, "nothing at night")

section("B1  no engine words, ids or underscores in anything the model says")
let banned = try! NSRegularExpression(pattern: #"\b(node|nodes|gate|gates|edge|edges|rubric|claim|claims|critic|seat|seats|loop|loops|wiring|pill|ear|lens|ticker|w\d+|c\d)\b|_|Quit Pong Island"#,
                                      options: [.caseInsensitive])
let skip: Set<String> = ["key", "graphKey", "chatKey", "session", "nodeId", "order", "currentKey", "seen"]
func strings(_ v: Any, _ label: String? = nil, into out: inout [String]) {
    if let l = label, skip.contains(l) { return }
    if let s = v as? String { out.append(s); return }
    for c in Mirror(reflecting: v).children { strings(c.value, c.label, into: &out) }
}
var everything: [String] = []
var scenes: [IslandModel] = []
scenes.append(model(input([checkout, release, login, research, help, pipeline, onboarding, docs, pricing, faster, invoice, rounds, broken],
                          asks: [chatAsk], architects: [architect], teams: [northwind, harbor])))
scenes.append(model(input([checkoutLimit, onboardLimit], limits: l5, runner: false)))
scenes.append(model(input([weekly], limits: lw, engineOff: true)))
scenes.append(model(input([checkout, release], teams: [northwind, leadOnly]), teamsView))
var nudged = model(input([checkout]))
nudged.update(input([checkout, pricing, pipeline], asks: [chatAsk], architects: [architect], now: T + 1), settings: IslandSettings(), flags: .init())
scenes.append(nudged)
scenes.append(model(input(["failed_bounded:no_progress", "failed_bounded:wall", "failed_bounded:jobs", "error:tests",
                           "failed_check", "no_edge:fail"].map { ended($0) } + [betweenNext, lastCopy, threeCopies, nextWeek])))
for s in scenes {
    strings(s.state, into: &everything)
    strings(s.closed, into: &everything)
    if let a = s.announcement { everything.append(a) }
}
check(everything.count > 200, "(read \(everything.count) strings)")
var bad: [String] = []
for s in everything {
    let range = NSRange(s.startIndex..., in: s)
    if banned.firstMatch(in: s, range: range) != nil { bad.append(s) }
    // "runner" only as the app's own "graph runner"
    if s.lowercased().replacingOccurrences(of: "graph runner", with: "").contains("runner") { bad.append(s) }
}
check(bad.isEmpty, "every string is plain words", bad.joined(separator: "\n       "))

section("B2  tooltips are on screen too: none in the panel's or its question card's code says an engine word")
// tooltips aren't drawn text, so the scans above never read them: read the words off the lines that set one
let srcDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../src").standardized.path
let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
var tips: [String] = []
for f in ["QuestionCard.swift", "IslandViews.swift", "IslandController.swift", "IslandSettingsPane.swift"] {
    guard let text = try? String(contentsOfFile: srcDir + "/" + f, encoding: .utf8) else {
        check(false, "read src/\(f)", srcDir)
        continue
    }
    for line in text.components(separatedBy: "\n") where line.contains("toolTip")
        && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
        let ns = line as NSString
        for m in literal.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            tips.append(ns.substring(with: m.range(at: 1)))
        }
    }
}
check(tips.count >= 15, "(read \(tips.count) tooltips)")
var badTips: [String] = []
for s in tips {
    if banned.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { badTips.append(s) }
    if s.lowercased().replacingOccurrences(of: "graph runner", with: "").contains("runner") { badTips.append(s) }
}
check(badTips.isEmpty, "every tooltip is plain words", badTips.joined(separator: "\n       "))

// MARK: -

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
