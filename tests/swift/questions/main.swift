import Foundation

// Harness for the question card's data (run.sh slices the types out of the app and the island).
// Exit 0 = all green.

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

func section(_ name: String) { print("\n\(name)") }

// MARK: - GDetail (the app)

section("D1  points with their files and places")
var d = GDetail.parse([
    ["text": "Edit 19 changes   the quote\non page 2.", "file": "/tmp/UPDATE.md", "where": "Edit 19"],
    ["text": "Two edits remove a client's name.", "file": "", "where": ""],
])
check(d.count == 2, "two points", "\(d)")
check(d.first?.text == "Edit 19 changes the quote on page 2.", "whitespace collapsed", d.first?.text ?? "")
check(d.first?.file == "/tmp/UPDATE.md" && d.first?.location == "Edit 19", "file and where kept")
check(d.last?.file == "" && d.last?.location == "", "a point without a file")

section("D2  a plain string is a point per line; a list of strings a point per item")
d = GDetail.parse("• First fact.\n\n- Second fact.\n-5% revenue is the third.")
check(d.map { $0.text } == ["First fact.", "Second fact.", "-5% revenue is the third."],
      "bullets dropped, a minus sign kept, blank lines skipped", "\(d.map { $0.text })")
d = GDetail.parse(["One.", "", "  Two.  "])
check(d.map { $0.text } == ["One.", "Two."], "list of strings", "\(d.map { $0.text })")

section("D3  the contract's limits")
d = GDetail.parse((1...9).map { "Point \($0)." })
check(d.count == 6, "at most six points", "count=\(d.count)")
d = GDetail.parse([String(repeating: "a", count: 400)])
check(d.first?.text.count == 280 && d.first?.text.hasSuffix("…") == true, "a point is cut at 280 characters",
      "count=\(d.first?.text.count ?? -1)")
d = GDetail.parse((1...6).map { _ in String(repeating: "b", count: 279) })
check(d.reduce(0) { $0 + $1.text.count } <= 1_400 && d.count == 5, "the whole is at most 1,400 characters",
      "count=\(d.count) total=\(d.reduce(0) { $0 + $1.text.count })")
d = GDetail.parse([["text": "x", "where": String(repeating: "w", count: 90)]])
check(d.first?.location.count == 60, "where is cut at 60 characters", "count=\(d.first?.location.count ?? -1)")

section("D4  nothing usable is no points")
check(GDetail.parse(nil).isEmpty, "nil")
check(GDetail.parse(42).isEmpty, "a number")
check(GDetail.parse([["file": "/tmp/x.md"]]).isEmpty, "a point with no text")
check(GDetail.parse("   \n  ").isEmpty, "blank text")

section("D5  one point on its own, as the engine also reads it")
d = GDetail.parse(["text": "Only fact.", "file": "/tmp/A.md", "where": "Summary"])
check(d.map { [$0.text, $0.file, $0.location] } == [["Only fact.", "/tmp/A.md", "Summary"]], "a single {text, file, where}",
      "\(d)")

// MARK: - DetailPoint (the island) reads the same shapes the same way

section("I1  the island parses what the app parses")
let shapes: [Any] = [
    [["text": "Edit 19 changes the quote.", "file": "/tmp/U.md", "where": "Edit 19"]],
    "• First fact.\n- Second fact.",
    (1...9).map { "Point \($0)." },
    [String(repeating: "a", count: 400)],
    (1...6).map { _ in String(repeating: "b", count: 279) },
    [["text": "x", "where": String(repeating: "w", count: 90)]],
    ["text": "Only fact.", "file": "/tmp/A.md", "where": "Summary"],
]
for (i, s) in shapes.enumerated() {
    let app = GDetail.parse(s).map { [$0.text, $0.file, $0.location] }
    let isl = DetailPoint.parse(s).map { [$0.text, $0.file, $0.place] }
    check(app == isl, "shape \(i + 1) matches", "app=\(app) island=\(isl)")
}
check(DetailPoint.attribution("Claude Haiku").hasPrefix("Summary by Claude Haiku from the files"), "Haiku attribution")
check(DetailPoint.attribution("the chat") == "Written by the chat", "chat attribution")
check(DetailPoint.attribution("") == "", "no attribution when nobody said")

// MARK: - QuestionWords (the app's card and notification words)

section("Q1  who wrote the details, the same line in the app and the island")
check(QuestionWords.attribution("Claude Haiku")
      == "Summary by Claude Haiku from the files · check the files for the full picture", "Haiku")
check(QuestionWords.attribution("the chat") == "Written by the chat", "the chat")
check(QuestionWords.attribution("CyberPong") == "Written by CyberPong from the step's report", "CyberPong")
check(QuestionWords.attribution("the graph's designer") == "Written by the graph's designer", "the designer")
check(QuestionWords.attribution("the graph's designer and Claude Haiku")
      == "Written by the graph's designer, with points by Claude Haiku from the files · check the files for the full picture",
      "the designer's question, Haiku's points")
check(QuestionWords.attribution("the graph's designer and CyberPong")
      == "Written by the graph's designer, with points from the step's report", "the designer's question, CyberPong's points")
check(QuestionWords.attribution("  ") == "", "nobody said")
for by in ["", "Claude Haiku", "the chat", "CyberPong", "the graph's designer", "the graph's designer and Claude Haiku",
           "the graph's designer and CyberPong", "a helper"] {
    check(QuestionWords.attribution(by) == DetailPoint.attribution(by), "island says the same for '\(by)'",
          "app=\(QuestionWords.attribution(by)) island=\(DetailPoint.attribution(by))")
}

section("Q2  a notification: the question, then why in one line, never the details")
check(QuestionWords.notificationBody(question: "Send the report?", context: ["The reviewer passed it.", "Second."])
      == "Send the report?\nThe reviewer passed it.", "question and the first line")
check(QuestionWords.notificationBody(question: "Send the report?", context: ["  ", "Plan A  is\ncheaper."])
      == "Send the report?\nPlan A is cheaper.", "a blank first line is skipped; one line")
check(QuestionWords.notificationBody(question: "Send the report?", context: []) == "Send the report?", "no context")

section("Q3  a gate's notification waits for its plain words, two minutes at most")
let now0 = 1_791_400_000.0
check(QuestionWords.holdNotification(plainWordsPending: true, openedAt: now0 - 30, now: now0), "30 s old: held")
check(!QuestionWords.holdNotification(plainWordsPending: true, openedAt: now0 - 121, now: now0), "two minutes passed: sent")
check(!QuestionWords.holdNotification(plainWordsPending: false, openedAt: now0 - 5, now: now0), "nothing pending: sent")

// MARK: - GLimits

section("L1  nothing to say")
check(GLimits(nil) == nil, "absent")
check(GLimits([String: Any]()) == nil, "empty")
check(GLimits("ok") == nil, "not an object")

let now = 1_791_400_000.0
section("L2  the 5-hour pause")
var l = GLimits(["state": "paused_5h", "until": now + 3600, "paused": [["session": "t", "graph": "g"]],
                 "usage": ["session_pct": 100, "week_pct": 61.6, "read_at": now - 30], "credits": "off",
                 "note": "Paused at the 5-hour limit."])
check(l?.isPaused == true && l?.paused == 1 && l?.weekPct == 62 && l?.credits == "off", "parsed",
      "\(String(describing: l))")
var w = l?.pausedWords(now: now, clock: { _ in "3:10 pm" })
check(w?.text == "Graphs paused for Claude's 5-hour limit · back at 3:10 pm" && w?.resume == false,
      "back at the reset time, no Resume anyway", "\(String(describing: w))")
w = l?.pausedWords(now: now + 7200, clock: { _ in "3:10 pm" })
check(w?.text == "Graphs paused for Claude's 5-hour limit · back after the reset", "a reset time passed",
      "\(String(describing: w))")
check(l?.weekWords == nil, "no week line while paused")
l = GLimits(["state": "paused_5h", "until": NSNull(), "usage": ["session_pct": 100, "session_reset": now + 1800]])
w = l?.pausedWords(now: now, clock: { _ in "2:40 pm" })
check(w?.text == "Graphs paused for Claude's 5-hour limit · back at 2:40 pm", "no until: the session's reset time",
      "\(String(describing: w))")

section("L3  the weekly stop")
l = GLimits(["state": "paused_week", "until": NSNull(), "paused": [], "usage": ["week_pct": 97]])
w = l?.pausedWords(now: now, clock: { _ in "" })
check(w?.text == "This week's Claude use is at 97% · graphs paused" && w?.resume == true, "offers Resume anyway",
      "\(String(describing: w))")
l = GLimits(["state": "paused_week"])
check(l?.pausedWords(now: now, clock: { _ in "" })?.text == "This week's Claude use passed your limit · graphs paused",
      "no usage read")
l = GLimits(["state": "paused_week", "until": now + 2 * 86_400, "usage": ["week_pct": 97]])
w = l?.pausedWords(now: now, clock: { _ in "Thursday 11:00" })
check(w?.text == "This week's Claude use is at 97% · graphs paused · back Thursday 11:00" && w?.resume == true,
      "says when the weekly reset lifts it", "\(String(describing: w))")
l = GLimits(["state": "paused_week", "until": NSNull(), "usage": ["week_pct": 98, "week_reset": now + 3600]])
check(l?.pausedWords(now: now, clock: { _ in "4:00 PM" })?.text == "This week's Claude use is at 98% · graphs paused · back 4:00 PM",
      "no until: the week's reset time")
l = GLimits(["state": "paused_week", "until": now - 60, "usage": ["week_pct": 98]])
check(l?.pausedWords(now: now, clock: { _ in "x" })?.text == "This week's Claude use is at 98% · graphs paused",
      "a reset time already passed says nothing about when")

section("L4  the quiet week line")
l = GLimits(["state": "ok", "usage": ["week_pct": 84, "week_reset": "2026-10-09T08:00:00Z"]])
check(l?.pausedWords(now: now, clock: { _ in "" }) == nil, "nothing paused")
check(l?.weekWords == "Claude this week: 84%", "84% shows", l?.weekWords ?? "nil")
check(l?.weekReset == ISO8601DateFormatter().date(from: "2026-10-09T08:00:00Z")?.timeIntervalSince1970, "an ISO reset time reads")
l = GLimits(["state": "ok", "usage": ["week_pct": 79]])
check(l?.weekWords == nil, "79% stays quiet")

// MARK: - The card's file row and where a tall card stops (fix round 1)

section("F1  a file a point already links isn't repeated in the file row")
let row = QuestionWords.fileRow(["/p/PLAN.md", "/p/notes/REVIEW.md", "/p/./data.csv"], linked: ["/p/PLAN.md", "/p/data.csv"])
check(row == ["/p/notes/REVIEW.md"], "linked files leave the row (paths compared standardized)", "\(row)")
check(QuestionWords.fileRow(["/p/PLAN.md"], linked: []) == ["/p/PLAN.md"], "nothing linked: every file")

section("F2  a file link says the file's name, with its folder only when two share a name")
check(QuestionWords.fileTitles(["/Users/x/proj/PLAN.md", "/tmp/a/REVIEW.md"]) == ["PLAN.md", "REVIEW.md"], "names only")
check(QuestionWords.fileTitles(["/a/one/PLAN.md", "/a/two/PLAN.md"]) == ["PLAN.md — one", "PLAN.md — two"], "twins say their folder")

section("F3  a card taller than its place stops between two lines, never through one")
let spans: [(top: Double, bottom: Double)] = [(20, 36), (48, 70), (78, 96), (100, 120), (130, 148)]
check(QuestionWords.cleanCut(spans, limit: 110, floor: 40) == 100, "a cut through a line moves up to where that line starts",
      "\(QuestionWords.cleanCut(spans, limit: 110, floor: 40))")
check(QuestionWords.cleanCut([(20, 36), (48, 70), (60, 96), (100, 120)], limit: 90, floor: 40) == 48,
      "overlapping pieces (a link under its point) move the cut above both",
      "\(QuestionWords.cleanCut([(20, 36), (48, 70), (60, 96), (100, 120)], limit: 90, floor: 40))")
check(QuestionWords.cleanCut(spans, limit: 125, floor: 40) == 125, "a limit already in a gap stays")
check(QuestionWords.cleanCut(spans, limit: 60, floor: 55) == 60, "no gap above the floor: the limit itself")
check(QuestionWords.cleanCut([], limit: 80, floor: 0) == 80, "nothing to cut")

// MARK: - Words (steps, reports, outcomes)

section("W1  the person's own step is never called Me")
check(Words.name("me") == "Your answer" && Words.name("Me") == "Your answer", "me → Your answer")
check(Words.isYourAnswer("human") && !Words.isYourAnswer("review"), "who counts as the person")
check(Words.name("final-review") == "Final review" && Words.name("c1.arch") == "c1.arch", "other names as before")

section("W2  a step's report without its verdict word")
check(Words.report("win: The plan is ready.") == "The plan is ready.", "win:")
check(Words.report("FAIL — totals are wrong") == "Totals are wrong", "FAIL —, and the rest reads as a sentence")
check(Words.report("passed: ok") == "Ok", "passed: is not pass + ed")
check(Words.report("route:fix: send it back") == "Send it back", "a route word")
check(Words.report("Passengers: 4 more") == "Passengers: 4 more", "a word that only starts like a verdict stays")
check(Words.report("done") == "done", "a verdict with nothing after it stays")
check(Words.report("The plan is ready.") == "The plan is ready.", "no verdict: unchanged")
check(Words.report("done-ness is fine") == "done-ness is fine" && Words.report("error-free run: 3 files") == "error-free run: 3 files",
      "a hyphen inside a word is not a verdict's dash")
check(Words.report("fail - totals are wrong") == "Totals are wrong", "a spaced hyphen still is")
check(Words.report("abstain — Jev was not asked; a person decides") == "Jev was not asked; a person decides", "Jev's abstain")

section("W3  outcomes in words")
check(Words.outcome("win") == "Passed" && Words.outcome("fail") == "Didn't pass" && Words.outcome("rejected") == "Sent back",
      "verdicts")
check(Words.outcome("route:fix-it") == "Chose Fix it", "a route")
check(Words.outcome("") == "", "nothing")
check(Words.outcome("abstain") == "Left it to you" && Words.outcome("cancelled") == "Stopped by you", "Jev left it to you; stopped")
check(Words.outcome("failed_bounded:rounds") == "Out of rounds" && Words.outcome("no_edge:review") == "No next step after Review",
      "a graph's stop reasons", Words.outcome("failed_bounded:rounds") + " / " + Words.outcome("no_edge:review"))
// the Plan view's edge and step words (fix round 2): never a raw verdict
for raw in ["win", "fail", "abstain", "error", "rejected", "timeout", "lost"] {
    let said = Words.outcome(raw).lowercased()
    check(!said.isEmpty && said != raw, "'\(raw)' is said in words: '\(said)'")
}

section("W4  a failure toast: the engine's own line only when it is already a sentence")
check(Words.engineSentence("error: Its terminal has closed.") == "Its terminal has closed.", "an error: line that is a sentence")
check(Words.engineSentence("{\"ok\": false, \"note\": \"There is no terminal to open yet.\"}") == "There is no terminal to open yet.",
      "a JSON reply's note")
check(Words.engineSentence("{\"ok\": false, \"error\": \"The team isn't running.\", \"note\": \"x\"}") == "The team isn't running.",
      "a JSON reply's error first")
check(Words.engineSentence(EngineCheck.noPythonMessage) == EngineCheck.noPythonMessage, "the no-Python sentence")
check(Words.engineSentence("error: g_1a2b is done — nothing to pause") == nil, "an id and no stop: not a sentence")
check(Words.engineSentence("error: 'rejected' is not an answer this gate takes (it takes: approved)") == nil, "lower case first")
check(Words.engineSentence("error: KeyError: 'x'") == nil, "an exception name")
check(Words.engineSentence("error: RuntimeError: Something broke.") == nil, "an exception name, even with a stop")
check(Words.engineSentence("error: Pass --extend 1 to allow one more round.") == nil, "a flag")
check(Words.engineSentence("error: Read /Users/x/.pong/state.json first.") == nil, "a path")
check(Words.engineSentence("usage: pong goal resume [-h]\npong: error: the following arguments are required: --id") == nil,
      "argparse's refusal")
check(Words.engineSentence("Traceback (most recent call last):\n  File \"x\", line 1\nValueError: bad") == nil, "a traceback")
check(Words.engineSentence("") == nil && Words.engineSentence("   ") == nil, "nothing said")
check(Words.engineSentence("{\"ok\": false}") == nil, "a JSON reply with no words")

section("W5  the island words a refusal the same way")
let refusals = ["error: Its terminal has closed.", "{\"ok\": false, \"note\": \"There is no terminal to open yet.\"}",
                "error: g_1 is done — nothing to pause", "error: KeyError: 'x'", "usage: x\npong: error: required: --id",
                "Its terminal couldn't be found just now.", "", "{\"ok\": false, \"error\": \"The team isn't running.\"}"]
for r in refusals {
    check(Words.engineSentence(r) == PongCheck.sentence(r), "same for '\(r.prefix(40).replacingOccurrences(of: "\n", with: " ⏎ "))'",
          "app=\(Words.engineSentence(r) ?? "nil") island=\(PongCheck.sentence(r) ?? "nil")")
}

section("W6  a refused answer that trying again won't fix says what it is")
// the engine's own refusals (graph_engine._answer / resume, asks.answer), as GraphActions passes them on
let spent = "error: me: that would be round 5 of this gate's 4. Answer rejected, or allow one more round: "
    + "pong -s team-a goal resume --id g_1 --node me --outcome approved --note 'keep it' --extend 1"
check(QuestionWords.answerRefusal(spent).map { $0.moreRounds } == true, "spent rounds: one more can be allowed")
check(QuestionWords.answerRefusal(spent)?.words == "Its rounds are spent: allow one more round to send your answer.",
      "spent rounds: the island's words", QuestionWords.answerRefusal(spent)?.words ?? "nil")
check(Words.engineSentence(spent) == nil, "spent rounds: the engine's line is not shown (it carries the note)")
check(QuestionWords.answerRefusal("error: me: one more round needs 3 job(s) and only 1 are left under max_jobs 9. "
                                  + "Allow one more round (raises max_jobs too): pong -s t goal resume --extend 1")?.moreRounds == true,
      "out of jobs for one more round: one more can be allowed")
for closed in ["error: me is not an open gate (open: none)", "error: g_1 is done — nothing to resume",
               "error: question q_1 is already answered", "error: no question 'q_9' on team-a"] {
    let r = QuestionWords.answerRefusal(closed)
    check(r?.moreRounds == false && r?.words == "This question isn't open any more, so your answer wasn't sent.",
          "closed: '\(closed.prefix(44))'", r?.words ?? "nil")
}
check(QuestionWords.answerRefusal("error: 'x' is not an answer this gate takes (it takes: approved)") == nil,
      "any other refusal: the card's own plain words")
check(QuestionWords.answerRefusal("") == nil, "nothing said")
for said in [spent, "error: me is not an open gate (open: none)", "error: question q_1 is already withdrawn",
             "error: 'x' is not an answer this gate takes (it takes: approved)", ""] {
    let app = QuestionWords.answerRefusal(said), island = PongCheck.answerRefusal(said)
    check(app?.words == island?.words && app?.moreRounds == island?.moreRounds, "the island says the same for '\(said.prefix(36))'",
          "app=\(app?.words ?? "nil") island=\(island?.words ?? "nil")")
}

section("W7  why Jev has no opinion: a sentence in the words Settings uses, never red engine text")
let noKey = "No Jev key on this Mac, or Jev is switched off in Settings › Limits & keys."
check(Words.jevNotAsked("Jev is not available (no TypeSafe key, or turned off)") == noKey, "an older engine's no-key line",
      Words.jevNotAsked("Jev is not available (no TypeSafe key, or turned off)"))
check(Words.jevNotAsked("no TypeSafe key") == noKey, "the client's own no-key line")
check(Words.jevNotAsked(noKey) == noKey, "a line that already is a sentence passes as it is")
check(Words.jevNotAsked("Jev is turned off in ~/.pong/jev.json") == "Jev is switched off in Settings › Limits & keys.",
      "switched off, without a path")
check(Words.jevNotAsked("a client-facing graph: Jev is not asked unless the topology sets jev.client_ok")
      == "This graph's work goes to a client, so it isn't sent to Jev.", "a client's graph, without the setting's name")
check(Words.jevNotAsked("unreachable: URLError") == "Jev couldn't be reached.", "unreachable")
check(Words.jevNotAsked("HTTP 401: bad key") == "Jev refused the key." && Words.jevNotAsked("HTTP 502") == "Jev's service had a problem.",
      "HTTP answers")
check(Words.jevNotAsked("") == "Jev didn't answer.", "nothing said")
for raw in ["refused: x_y", "bad questions: q1", "invalid answer: p_a", "unavailable: 3 failed calls in a row; not calling for another 600 s"] {
    let said = Words.jevNotAsked(raw)
    check(said.range(of: #"[_:/]|HTTP|Error"#, options: .regularExpression) == nil && said.hasSuffix("."),
          "'\(raw.prefix(30))' reads as a plain sentence", said)
}

// MARK: - RunState (a graph on a stopped team)

section("R1  a running graph whose team is stopped is not working: it waits for the team")
check(RunState.working(running: true, waitingOnYou: false, paused: false, teamUp: true), "team up: working")
check(!RunState.working(running: true, waitingOnYou: false, paused: false, teamUp: false), "team stopped: not working")
check(RunState.waitsForTeam(running: true, waitingOnYou: false, paused: false, teamUp: false), "team stopped: waits for it")
check(!RunState.waitsForTeam(running: true, waitingOnYou: false, paused: false, teamUp: true), "team up: doesn't wait")
check(!RunState.waitsForTeam(running: true, waitingOnYou: false, paused: true, teamUp: false)
      && !RunState.working(running: true, waitingOnYou: false, paused: true, teamUp: true), "paused: neither, it is listed as paused")
check(!RunState.waitsForTeam(running: true, waitingOnYou: true, paused: false, teamUp: false), "a question: it needs you first")
check(!RunState.working(running: false, waitingOnYou: false, paused: false, teamUp: true)
      && !RunState.waitsForTeam(running: false, waitingOnYou: false, paused: false, teamUp: false), "finished: neither")

section("R2  which steps at work hold still")
check(RunState.holdStill(running: true, waitingOnYou: false, paused: false, pauseReason: "", teamUp: false),
      "team stopped, not paused: held still (no spinner)")
check(!RunState.holdStill(running: true, waitingOnYou: false, paused: false, pauseReason: "", teamUp: true), "at work: not held")
check(!RunState.holdStill(running: true, waitingOnYou: false, paused: true, pauseReason: "paused by you", teamUp: true),
      "the person's own pause: steps at work finish")
check(RunState.holdStill(running: true, waitingOnYou: false, paused: true, pauseReason: "paused for Claude's 5-hour limit", teamUp: true),
      "a pause for Claude's limit: held still")
check(RunState.holdStill(running: true, waitingOnYou: false, paused: true, pauseReason: "paused by you", teamUp: false),
      "paused and the team stopped: held still")
check(!RunState.holdStill(running: false, waitingOnYou: false, paused: false, pauseReason: "", teamUp: false), "finished: nothing to hold")

// MARK: - The engine checks (no Python, the graph runner, Resume anyway)

section("E1  a launcher that runs whatever python3 is on PATH")
check(EngineCheck.launchesPathPython("#!/usr/bin/env bash\nexport PYTHONPATH=x\nexec python3 -m pong.cli.main \"$@\"\n"),
      "the app's ~/bin/pong")
check(EngineCheck.launchesPathPython("#!/bin/sh\nexec /usr/bin/env python3 -m pong.cli.main \"$@\""), "through env")
check(!EngineCheck.launchesPathPython("#!/bin/sh\nexec /opt/homebrew/bin/python3 -m pong.cli.main \"$@\""),
      "a launcher that names its interpreter")
check(!EngineCheck.launchesPathPython("#!/bin/sh\n# exec python3 is what we used to do\nexec /x/py -m pong"), "a comment is not a command")
check(EngineCheck.launchesPathPython("#!/usr/bin/env python3\nimport sys\n") && EngineCheck.launchesPathPython("#!/usr/bin/python3\n"),
      "a Python script run by whatever python3 is on PATH, or by Apple's")
check(!EngineCheck.launchesPathPython("#!/opt/homebrew/opt/python@3.12/bin/python3.12\nimport sys\n"),
      "a script that names its own interpreter (pip's entry point)")
check(!EngineCheck.launchesPathPython("#!/usr/bin/env bash\necho hi\n"), "a shell script that never runs python")

section("E1b the island reads a launcher the same way, and says the same thing when there is no Python")
let launchers = ["#!/usr/bin/env bash\nexport PYTHONPATH=x\nexec python3 -m pong.cli.main \"$@\"\n",
                 "#!/bin/sh\nexec /usr/bin/env python3 -m pong.cli.main \"$@\"",
                 "#!/bin/sh\nexec /opt/homebrew/bin/python3 -m pong.cli.main \"$@\"",
                 "#!/bin/sh\n# exec python3 is what we used to do\nexec /x/py -m pong",
                 "#!/usr/bin/env python3\nimport sys\n", "#!/usr/bin/python3\n",
                 "#!/opt/homebrew/opt/python@3.12/bin/python3.12\nimport sys\n", "#!/usr/bin/env bash\necho hi\n",
                 "#!/usr/bin/env bash\nif ! xcode-select -p >/dev/null 2>&1; then exit 1; fi\nexec python3 -m pong.cli.main \"$@\"\n"]
for (i, s) in launchers.enumerated() {
    check(EngineCheck.launchesPathPython(s) == PongCheck.launchesPathPython(s), "launcher \(i + 1): the island agrees")
}
check(PongCheck.noPythonMessage == EngineCheck.noPythonMessage, "the same no-Python sentence")

section("E2  the graph runner's state from graph list")
check(EngineCheck.runnerOK(["ok": false, "installed": false, "running": false, "last_beat_s": NSNull()]) == false, "off")
check(EngineCheck.runnerOK(["ok": true, "installed": true]) == true, "on")
check(EngineCheck.runnerOK(nil) == nil && EngineCheck.runnerOK(NSNull()) == nil && EngineCheck.runnerOK(["installed": true]) == nil,
      "an engine that didn't say")

section("E3  what Resume anyway says: never the engine's raw output")
var rr = EngineReply.resume(code: 2, out: "", err: "error: IsADirectoryError: [Errno 21] Is a directory: '/Users/x/.pong/limits-state.json.lock'")
check(!rr.ok && rr.words == "Couldn't resume the graphs. Try again in a moment.", "an exception becomes plain words", rr.words)
rr = EngineReply.resume(code: 0, out: "{\"ok\": true, \"note\": \"Nothing was paused for a limit.\"}", err: "")
check(rr.ok && rr.words == "Nothing was paused for a limit.", "the engine's own note", rr.words)
rr = EngineReply.resume(code: 0, out: "{\"ok\": false, \"note\": \"Claude is still at its limit.\"}", err: "")
check(!rr.ok && rr.words == "Claude is still at its limit.", "a refusal with a note says the note", rr.words)
rr = EngineReply.resume(code: 127, out: "", err: EngineCheck.noPythonMessage)
check(!rr.ok && rr.words == EngineCheck.noPythonMessage, "no Python: already plain")
rr = EngineReply.resume(code: -1, out: "", err: "")
check(!rr.ok && !rr.words.isEmpty, "a timeout still says something")
// Turn on's words are the setup's own (RunnerInstall.words): tests/swift/setup checks them

section("E4  a loop in the words its steps use: never its id, never \"done\"")
var lp = GLoop(["id": "me", "kind": "person", "round": 2, "max_iters": 4, "status": "running"])
check(lp.label == "Your answer · round 2 of 4", "a person's loop named for them", lp.label)
lp = GLoop(["id": "sign_off", "kind": "person", "round": 1, "max_iters": 3, "status": "done"])
check(lp.label == "Sign off · round 1 of 3 · your answer · finished", "a person's loop with its own name, finished", lp.label)
lp = GLoop(["id": "draft", "kind": "agent", "round": 0, "max_iters": 4, "status": "bounded"])
check(lp.label == "Draft · round 1 of 4 · out of rounds", "rounds spent; round 0 reads as the first", lp.label)
lp = GLoop(["id": "check", "kind": "agent", "round": 3, "max_iters": 0, "status": "running"])
check(lp.label == "Check · round 3", "no cap: no \"of 0\"", lp.label)

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED (\(failures))")
    exit(1)
}
print("OK")
exit(0)
