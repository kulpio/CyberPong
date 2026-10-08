import Foundation

// Standalone harness for LoopArgs — the island's who-runs-this → argv mapping.
//
// There is no Swift test target in this repo (no Package.swift, no .xcodeproj),
// so this follows the shape tests/swift/run.sh already uses for CronSchedule:
// run-loop-args.sh slices `enum LoopArgs` out of island/PongIsland.swift and
// compiles it with this file. Exit 0 = all green.
//
// The Who row itself can only be judged by eye. What it hands `pong goal start`
// cannot, and that is what these check: one lit chip must produce the argv the
// island produced before the row existed, and several must produce a set.

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

/// The argv as it would be logged and run, so a failure prints the real line.
func line(_ a: [String]) -> String { a.joined(separator: " ") }

/// The value after a flag, or nil when the flag is absent or has nothing after
/// it. Never a force unwrap: a mapping that drops `--with` is exactly what
/// these tests exist to catch, and a harness that traps on it reports a crash
/// instead of the failure.
func value(_ flag: String, _ a: [String]) -> String? {
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func args(_ picked: [String], conductor: String = "c1", kind: String = "cycle",
          pieces: Int = 2, maxRounds: Int = 3, bar: String? = nil,
          links: [String] = []) -> [String] {
    LoopArgs.goalStart(session: "pong-team", kind: kind, picked: picked,
                       conductor: conductor, task: "do the thing",
                       pieces: pieces, fanCap: 4, maxRounds: maxRounds,
                       bar: bar, links: links)
}

section("one chip is a single agent")
do {
    let a = args(["w16"])
    check(value("--owner", a) == "w16", "the one seat picked is --owner", line(a))
    check(!a.contains("--with"),
          "no --with at all — an owner-only loop is spelled exactly as before",
          line(a))
    check(a == ["-s", "pong-team", "goal", "start", "--owner", "w16",
                "--loop", "cycle", "--task", "do the thing", "--max-rounds", "3"],
          "the whole argv is unchanged from the pre-Who-row spelling", line(a))
}

section("several chips are a set")
do {
    let a = args(["w16", "w1", "w5"], conductor: "c1")
    check(value("--owner", a) == "w16",
          "first picked leads when the conductor is not in the set", line(a))
    check(value("--with", a) == "w1,w5",
          "the rest ride on --with, comma separated, lead excluded", line(a))
}

section("the conductor leads any set they are in")
do {
    let a = args(["w16", "c1", "w5"], conductor: "c1")
    check(value("--owner", a) == "c1",
          "conductor is --owner even though w16 was picked first", line(a))
    check(value("--with", a) == "w16,w5",
          "and everyone else keeps their pick order on --with", line(a))
    check(LoopArgs.lead(picked: ["w16", "c1"], conductor: "c1") == "c1",
          "lead() says the same thing the caption will read")
}

section("no conductor on the snapshot")
do {
    let a = args(["w5", "w1"], conductor: "")
    check(value("--owner", a) == "w5",
          "an empty conductor id never wins the lead", line(a))
    check(LoopArgs.lead(picked: [], conductor: "c1") == "",
          "an empty pick has no lead — Start refuses before it gets here")
}

section("a seat is never named twice")
do {
    // The Who row toggles, so it cannot produce a duplicate — but --owner
    // appearing again inside --with would silently widen the set, so the
    // mapping is checked rather than trusted.
    let a = args(["w16", "w16", "w1"], conductor: "c1")
    check(value("--with", a) == "w1",
          "the lead is filtered out of --with however many times it was picked",
          line(a))
}

section("the set does not disturb the rest of the argv")
do {
    let fan = args(["w16", "w1"], kind: "fan", pieces: 9)
    check(value("--pieces", fan) == "4",
          "fan width is still clamped to the engine's cap", line(fan))
    let g = args(["w16", "w1"], kind: "gauntlet", bar: "/tmp/bar.md",
                 links: ["https://a.example/x", "https://b.example/y"])
    check(value("--bar", g) == "/tmp/bar.md", "bar survives", line(g))
    check(g.filter { $0 == "--example" }.count == 2,
          "one --example per link, still repeatable rather than comma-joined",
          line(g))
    if let w = g.firstIndex(of: "--with"), let b = g.firstIndex(of: "--bar") {
        check(w < b, "--with lands before the kind-specific flags", line(g))
    } else {
        check(false, "--with lands before the kind-specific flags",
              "one of --with / --bar is missing: \(line(g))")
    }
}

section("the roster fits the row the panel gives it")
do {
    // The eight org mains of a full team, as the Who row labels
    // them (`label · id`). The panel is a fixed height and so is the Who area
    // inside it — Store.loopWhoHeight is four rows — so a roster that packs
    // into five is a chip a human has to scroll to find.
    let mains = ["Hermes · c1", "Delivery · w1", "Growth · w5", "Research · w10",
                 "Engineering — CyberPong · w16", "Ops · w20",
                 "Engineering — Web · w25", "Engineering — Design (UX/UI) · w29"]
    let width = 470.0 - 32          // Store.bodyWidth less the panel padding
    let rows = LoopArgs.chipRows(mains, width: width)
    check(rows.reduce(0, +) == mains.count,
          "every main lands on a row — none are dropped by the packing",
          "rows: \(rows)")
    check(rows.allSatisfy { $0 > 0 }, "no empty rows", "rows: \(rows)")
    let h = LoopArgs.chipHeight(mains, width: width, rowHeight: 21, rowGap: 5)
    check(h <= 104, "the whole roster fits Store.loopWhoHeight without scrolling",
          "\(rows.count) rows = \(h)pt, area is 104pt")
    // A label longer than the panel is wide must still get a row, not a loop.
    let huge = LoopArgs.chipRows([String(repeating: "x", count: 400)], width: width)
    check(huge == [1], "an over-wide label takes one row rather than none",
          "rows: \(huge)")
    check(LoopArgs.chipRows([], width: width) == [0],
          "an empty roster is one empty row, not a crash")
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
