import Foundation

// Harness for how a graph reads: the app's GGraph (src/GraphStudioModel.swift, src/GraphWords.swift)
// takes one graph the way `pong graph list --json` and the snapshot send it and says what state it is
// in. Since 2.1 the notch panel reads graphs through this same model, so its closed line, its count
// and its rows go by these answers too.
//
// There is no Swift test target in this repo, so run-island-graphs.sh compiles those two files with
// Stubs.swift and this file. Exit 0 = all green.
//
// Why: the runner pauses graphs at Claude's limits and leaves them "running". The app lists them as
// paused; 2.0's separate island counted them as working, so the two said different things at the
// same time. One model now; these checks keep its answers.

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

/// A graph as the engine sends it (graph_engine.snapshot_fields / snapshot_node), made-up names only.
func graph(status: String = "running", id: String = "g1", title: String = "Site review",
           session: String = "pong-team-3", teamLabel: String = "Shop", goal: String = "",
           manualPause: Bool? = nil, reason: String? = nil, held: Int = 0, stopReason: String = "",
           gates: [[String: Any]] = [], asking: String = "") -> [String: Any] {
    var draft: [String: Any] = ["id": "write_draft", "role": "writer", "status": "running",
                                "live": ["state": "working", "doing": "Writing page 2"]]
    if !asking.isEmpty { draft["attention"] = asking }
    var g: [String: Any] = [
        "id": id, "session": session, "team_label": teamLabel, "status": status, "title": title,
        "created_at": 1_790_000_000.0, "stop_reason": stopReason, "held": held,
        "nodes": [draft, ["id": "review", "role": "critic", "status": "pending"]],
        "edges": [["from": "write_draft", "to": "review", "on": "done"]],
        "gates": gates,
    ]
    if !goal.isEmpty { g["goal_text"] = goal }
    if let manualPause { g["manual_pause"] = manualPause }
    if let reason { g["pause_reason"] = reason }
    return g
}

/// Through JSON, the way the app gets it (numbers and booleans as NSNumber).
func viaJSON(_ g: [String: Any]) -> [String: Any] {
    let d = try! JSONSerialization.data(withJSONObject: g)
    return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
}

func read(_ g: [String: Any]) -> GGraph { GGraph(viaJSON(g)) }

let team = "pong-team-3"
SchedulesPageView.runningTeams = [team]

section("a graph at work")
do {
    let g = read(graph())
    check(g.isRunning && g.isWorking && !g.isPausedNow && !g.waitingOnYou, "running: working, not paused or waiting",
          "working=\(g.isWorking) paused=\(g.isPausedNow) waiting=\(g.waitingOnYou)")
    check(g.isWorkingNow && !g.waitsForTeam && g.pongStatus == .working, "its team is up: at work now, the working marker",
          "\(g.pongStatus)")
    check(g.key == "pong-team-3/g1", "its key is team/graph", g.key)
    let step = g.nodes.first { $0.status == "running" }
    check(step.map { Words.name($0.id) } == "Write draft", "the step at work by name, never its id",
          step.map { Words.name($0.id) } ?? "nil")
    check(step?.liveDoing == "Writing page 2" && step?.liveState == "working", "its latest line, as the engine saw it")
    check(g.teamName == "Shop" && g.displayTitle == "Site review", "its team and its name", "\(g.teamName) / \(g.displayTitle)")
    let noFlag = read(graph(manualPause: false, reason: ""))
    check(noFlag.isWorkingNow && noFlag.pongStatus == .working, "manual_pause false is working")
}

section("a paused graph is paused, not working (2.0)")
do {
    let five = read(graph(manualPause: true, reason: "paused for Claude's 5-hour limit", held: 2))
    check(five.isPausedNow && !five.isWorking && !five.isWorkingNow, "paused at Claude's 5-hour limit: paused, not working",
          "paused=\(five.isPausedNow) working=\(five.isWorking)")
    check(five.pongStatus == .paused, "the paused marker", "\(five.pongStatus)")
    check(five.pausedWords == "Paused for Claude's 5-hour limit", "says why", five.pausedWords)
    check(five.plainStatus == "Paused for Claude's 5-hour limit · 2 waiting to start", "and how many steps wait to start",
          five.plainStatus)
    check(five.stepsHoldStill(teamUp: true), "a pause for Claude's limit holds the steps at work still")
    let week = read(graph(manualPause: true, reason: "paused near Claude's weekly limit"))
    check(week.pausedWords == "Paused near Claude's weekly limit", "near the weekly limit", week.pausedWords)
    let you = read(graph(manualPause: true, reason: "paused by you"))
    check(you.isPausedNow && you.pausedWords == "Paused", "paused by the person: just \"Paused\"", you.pausedWords)
    check(!you.stepsHoldStill(teamUp: true), "the person's own pause lets the steps at work finish")
    let bare = read(graph(manualPause: true))
    check(bare.isPausedNow && bare.pausedWords == "Paused", "no reason given: \"Paused\"")
    SchedulesPageView.runningTeams = []
    let pausedTeamDown = read(graph(manualPause: true, reason: "paused by you"))
    check(pausedTeamDown.pongStatus == .paused && !pausedTeamDown.waitsForTeam,
          "paused with its team stopped: still paused, not \"waits for its team\"")
    SchedulesPageView.runningTeams = [team]
}

section("a graph waiting on the person needs you, paused or not")
do {
    let atGate = read(graph(gates: [["node": "me", "at": 1_790_000_100.0]]))
    check(atGate.waitingOnYou && !atGate.isWorking && !atGate.isWorkingNow, "at a question: waiting, not working")
    check(atGate.pongStatus == .needsYou && atGate.plainStatus == "Needs your answer", "the needs-you marker; the person's step is not named",
          atGate.plainStatus)
    let named = read(graph(gates: [["node": "final_review", "at": 1_790_000_100.0]]))
    check(named.plainStatus == "Needs your answer: Final review", "a question step with its own name says it", named.plainStatus)
    let pausedAtGate = read(graph(manualPause: true, reason: "paused by you", gates: [["node": "me"]]))
    check(pausedAtGate.waitingOnYou && !pausedAtGate.isPausedNow && pausedAtGate.pongStatus == .needsYou,
          "paused but at a question: needs you, not paused")
    let asking = read(graph(asking: "is asking: \u{201c}Trust this folder?\u{201d} Open its screen to answer."))
    check(asking.waitingOnYou && !asking.isWorking && asking.pongStatus == .needsYou, "a step asking on its screen: needs you")
    check(asking.plainStatus.hasPrefix("Needs you: Write draft is asking"), "says which step asks", asking.plainStatus)
    SchedulesPageView.runningTeams = []
    let gateTeamDown = read(graph(gates: [["node": "me"]]))
    check(gateTeamDown.pongStatus == .needsYou && !gateTeamDown.waitsForTeam,
          "at a question with its team stopped: needs you first")
    SchedulesPageView.runningTeams = [team]
}

section("a graph whose team is stopped waits for it, never cyan")
do {
    SchedulesPageView.runningTeams = []
    let g = read(graph())
    check(g.isWorking && !g.isWorkingNow, "the engine's state is running; not at work now")
    check(g.waitsForTeam && g.pongStatus == .pending, "waits for its team, with the waiting marker", "\(g.pongStatus)")
    check(g.plainStatus == "Waits for its team to start", "in words", g.plainStatus)
    check(g.stepsHoldStill(teamUp: false), "its steps hold still")
    SchedulesPageView.runningTeams = ["pong-team-9"]
    check(read(graph()).waitsForTeam, "another team up doesn't count")
    SchedulesPageView.runningTeams = [team]
}

section("only running graphs are at work")
do {
    let passed = read(graph(status: "done", stopReason: "win"))
    check(!passed.isRunning && !passed.isWorking && passed.pongStatus == .done, "a finished graph: done")
    check(passed.plainStatus == "Finished · passed", "finished, passed", passed.plainStatus)
    let stopped = read(graph(status: "cancelled", stopReason: "cancelled"))
    check(stopped.pongStatus == .stopped && stopped.plainStatus == "Stopped by you", "a stopped graph", stopped.plainStatus)
    let rounds = read(graph(status: "done", stopReason: "failed_bounded:rounds"))
    check(rounds.pongStatus == .failed && rounds.plainStatus == "Stopped · out of rounds", "out of rounds", rounds.plainStatus)
    let leftover = read(graph(status: "done", stopReason: "win", gates: [["node": "me"]]))
    check(!leftover.waitingOnYou && leftover.pongStatus == .done, "a question left on a finished graph doesn't need you")
    let pausedDone = read(graph(status: "done", manualPause: true, reason: "paused by you", stopReason: "win"))
    check(!pausedDone.isPausedNow, "a pause flag left on a finished graph isn't a pause")
    let untitled = read(graph(title: "", goal: "Compare the three price lists and write a one-page summary for the review"))
    check(untitled.displayTitle == "Compare the three price lists and write a one-page summary f",
          "no title: the start of its goal (60 characters)", untitled.displayTitle)
}

section("pausedWords says why in the app's words")
do {
    let cases: [(String, String)] = [
        ("", "Paused"), ("paused by you", "Paused"), ("Paused by you", "Paused"), ("  paused by you  ", "Paused"),
        ("paused for Claude's 5-hour limit", "Paused for Claude's 5-hour limit"),
        (" paused near Claude's weekly limit\n", "Paused near Claude's weekly limit"),
        ("held for review", "Paused"), ("paused", "Paused"),
    ]
    for (reason, want) in cases {
        let got = read(graph(manualPause: true, reason: reason)).pausedWords
        check(got == want, "\(reason.debugDescription) -> \"\(want)\"", "got \"\(got)\"")
    }
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
