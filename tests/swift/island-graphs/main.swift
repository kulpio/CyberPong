import Foundation

// Standalone harness for the island's graph lines: GraphLine.from reads one graph of a team's
// snapshot the way the app reads it (GGraph.isWorking / isPausedNow / waitingOnYou / pausedWords).
//
// There is no Swift test target in this repo, so run-island-graphs.sh slices `struct GraphLine` out of
// island/PongIsland.swift and compiles it with this file. Exit 0 = all green.
//
// Why: the runner pauses graphs at Claude's limits and leaves them "running". The app lists them as
// paused; the island counted them as working, so the two said different things at the same time.

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

/// A graph as `pong snapshot` writes it (work_graph.snapshot_block + graph_engine.snapshot_fields).
func graph(status: String = "running", id: String = "g1", title: String = "Site review",
           manualPause: Bool? = nil, reason: String? = nil,
           gates: [[String: Any]] = [], attention: [[String: Any]] = []) -> [String: Any] {
    var g: [String: Any] = [
        "id": id, "status": status, "title": title, "created_at": 1_790_000_000.0,
        "nodes": [["id": "write_draft", "status": "running", "live": ["doing": "Writing page 2"]],
                  ["id": "review", "status": "pending"]],
        "gates": gates, "attention": attention,
    ]
    if let manualPause { g["manual_pause"] = manualPause }
    if let reason { g["pause_reason"] = reason }
    return g
}

/// Through JSON, the way the island gets it (numbers and booleans as NSNumber).
func viaJSON(_ g: [String: Any]) -> [String: Any] {
    let d = try! JSONSerialization.data(withJSONObject: g)
    return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
}

section("a graph at work")
do {
    let l = GraphLine.from(viaJSON(graph()), session: "pong-team-3", teamName: "Shop")
    check(l != nil, "a running graph gets a line")
    check(l?.working == true && l?.paused == false && l?.waiting == false, "it is working, not paused or waiting",
          "working=\(String(describing: l?.working)) paused=\(String(describing: l?.paused))")
    check(l?.id == "pong-team-3/g1", "its id is session/graph", "id: \(l?.id ?? "nil")")
    check(l?.step == "Write draft", "the step by name", "step: \(l?.step ?? "nil")")
    check(l?.doing == "Writing page 2", "its latest line", "doing: \(l?.doing ?? "nil")")
    check(l?.teamName == "Shop" && l?.title == "Site review", "its team and title")
    let noFlag = GraphLine.from(viaJSON(graph(manualPause: false, reason: "")), session: "s", teamName: "s")
    check(noFlag?.working == true, "manual_pause false is working")
}

section("a paused graph is paused, not working (2.0)")
do {
    let five = GraphLine.from(viaJSON(graph(manualPause: true, reason: "paused for Claude's 5-hour limit")),
                              session: "s", teamName: "s")
    check(five?.paused == true && five?.working == false, "paused at Claude's 5-hour limit: paused, not working",
          "paused=\(String(describing: five?.paused)) working=\(String(describing: five?.working))")
    check(five?.pausedWords == "Paused for Claude's 5-hour limit", "says why, the way the app does",
          "words: \(five?.pausedWords ?? "nil")")
    let week = GraphLine.from(viaJSON(graph(manualPause: true, reason: "paused near Claude's weekly limit")),
                              session: "s", teamName: "s")
    check(week?.pausedWords == "Paused near Claude's weekly limit", "near the weekly limit",
          "words: \(week?.pausedWords ?? "nil")")
    let you = GraphLine.from(viaJSON(graph(manualPause: true, reason: "paused by you")), session: "s", teamName: "s")
    check(you?.paused == true && you?.pausedWords == "Paused", "paused by the person: just \"Paused\"",
          "words: \(you?.pausedWords ?? "nil")")
    let bare = GraphLine.from(viaJSON(graph(manualPause: true)), session: "s", teamName: "s")
    check(bare?.paused == true && bare?.pausedWords == "Paused", "no reason given: \"Paused\"")
}

section("a graph waiting on the person needs you, paused or not")
do {
    let gate: [String: Any] = ["node": "your_answer", "at": 1_790_000_100.0]
    let atGate = GraphLine.from(viaJSON(graph(gates: [gate])), session: "s", teamName: "s")
    check(atGate?.waiting == true && atGate?.working == false, "at a question: waiting, not working (it counts under need you)")
    let pausedAtGate = GraphLine.from(viaJSON(graph(manualPause: true, reason: "paused by you", gates: [gate])),
                                      session: "s", teamName: "s")
    check(pausedAtGate?.waiting == true && pausedAtGate?.paused == false,
          "paused but at a question: needs you (the app's isPausedNow leaves it out too)")
    let att: [String: Any] = ["node": "write_draft", "seat": "c1.b", "what": "is asking: \u{201c}Trust this folder?\u{201d}"]
    let asking = GraphLine.from(viaJSON(graph(attention: [att])), session: "s", teamName: "s")
    check(asking?.waiting == true && asking?.working == false, "a step asking on its screen: waiting (the app's waitingOnYou)")
}

section("only running graphs get a line")
do {
    check(GraphLine.from(viaJSON(graph(status: "done")), session: "s", teamName: "s") == nil, "a finished graph: none")
    check(GraphLine.from(viaJSON(graph(status: "cancelled")), session: "s", teamName: "s") == nil, "a stopped graph: none")
    check(GraphLine.from(viaJSON(graph(id: "")), session: "s", teamName: "s") == nil, "no id: none")
    var noId = graph(); noId.removeValue(forKey: "id")
    check(GraphLine.from(viaJSON(noId), session: "s", teamName: "s") == nil, "id missing: none")
    let untitled = GraphLine.from(viaJSON(graph(title: "")), session: "s", teamName: "s")
    check(untitled?.title == "g1", "no title: its id", "title: \(untitled?.title ?? "nil")")
}

section("pausedWords matches the app's GGraph.pausedWords")
do {
    let cases: [(String, String)] = [
        ("", "Paused"), ("paused by you", "Paused"), ("Paused by you", "Paused"), ("  paused by you  ", "Paused"),
        ("paused for Claude's 5-hour limit", "Paused for Claude's 5-hour limit"),
        (" paused near Claude's weekly limit\n", "Paused near Claude's weekly limit"),
        ("held for review", "Paused"), ("paused", "Paused"),
    ]
    for (reason, want) in cases {
        let got = GraphLine.pausedWords(reason)
        check(got == want, "\(reason.debugDescription) -> \"\(want)\"", "got \"\(got)\"")
    }
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
