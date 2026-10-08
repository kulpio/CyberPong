import AppKit
import Foundation

// Standalone harness for CronSchedule.tick / CronSchedule.file.
//
// There is no Swift test target in this repo (no Package.swift, no .xcodeproj);
// the app is built by swiftc over src/*.swift. run.sh compiles the CronSchedule
// enum plus Stubs.swift plus this file into one binary. Exit 0 = all green.

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

// MARK: - temp state

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "cron-harness-out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func freshStateDir(_ tag: String) -> String {
    let dir = NSTemporaryDirectory() + "cron-harness-\(tag)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pong.stateDirOverride = dir
    Pong.reset()
    return dir
}

let session = "harness-team"          // never a live team; state dir is a temp dir
let schedulePath = { Pong.stateDir + "/cron-schedules.json" }

func seed(lastFired: TimeInterval, id: String = "perimeter", intervalSec: Double = 900) {
    Pong.writeJSON(schedulePath(), [
        session: [[
            "id": id,
            "name": "Perimeter sweep",
            "task": "Quick health check of open jobs and stuck seats.",
            "cadence": "every 15m",
            "interval_sec": intervalSec,
            "phase_sec": 0,
            "owner_id": "c1",
            "enabled": true,
            "last_fired": lastFired,
        ]],
    ])
}

/// last_fired as it exists ON DISK after the tick — the value the next tick reads.
func persistedLastFired(_ id: String = "perimeter") -> Double {
    let db = Pong.loadJSON(schedulePath())
    let rows = (db[session] as? [[String: Any]]) ?? []
    return (rows.first(where: { ($0["id"] as? String) == id })?["last_fired"] as? Double) ?? -1
}

func writeToken(_ value: String) -> String {
    let dir = Pong.stateDir + "/sessions/\(session)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/token"
    try? (value + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return path
}

let now = Date(timeIntervalSince1970: 1_760_000_000)   // fixed clock, no wall-clock flake
let anHourAgo = now.timeIntervalSince1970 - 3600

// MARK: - 1. refused dispatch must not advance the clock

section("T1  dispatch returns false => lastFired UNCHANGED (in memory and on disk)")
_ = freshStateDir("t1")
seed(lastFired: anHourAgo)
var dispatched = 0
var results = CronSchedule.tick(session: session, now: now, dispatch: { _, _, _ in
    dispatched += 1
    return false
})
check(dispatched == 1, "dispatch was attempted", "calls=\(dispatched)")
check(results.first?.1 == .failed("job create refused"), "outcome is failed",
      "got \(String(describing: results.first?.1))")
check(persistedLastFired() == anHourAgo,
      "persisted last_fired still \(anHourAgo)", "got \(persistedLastFired())")
check(CronSchedule.isDue(CronSchedule.load(session: session)[0], now: now),
      "job is still due after the refusal (it will retry next tick)")

// MARK: - 2. successful dispatch advances it

section("T2  dispatch returns true => lastFired advances")
_ = freshStateDir("t2")
seed(lastFired: anHourAgo)
results = CronSchedule.tick(session: session, now: now, dispatch: { _, _, _ in true })
check(results.first?.1 == .dispatched, "outcome is dispatched",
      "got \(String(describing: results.first?.1))")
check(persistedLastFired() == now.timeIntervalSince1970,
      "persisted last_fired advanced to now", "got \(persistedLastFired())")
check(!CronSchedule.isDue(CronSchedule.load(session: session)[0], now: now),
      "job is no longer due")

// MARK: - 3. first sight seeds the clock without firing

section("T3  first sight (last_fired <= 0) => seeded, stamped, not dispatched")
_ = freshStateDir("t3")
seed(lastFired: 0)
dispatched = 0
results = CronSchedule.tick(session: session, now: now, dispatch: { _, _, _ in
    dispatched += 1
    return true
})
check(results.first?.1 == .seeded, "outcome is seeded", "got \(String(describing: results.first?.1))")
check(dispatched == 0, "dispatch NOT called", "calls=\(dispatched)")
check(persistedLastFired() == now.timeIntervalSince1970,
      "persisted last_fired stamped to now", "got \(persistedLastFired())")

// MARK: - 4. the real file() dispatch presents the token without leaking it

section("T4  default dispatch (real file()) presents PONG_TOKEN by path, never by value")
let stateDir4 = freshStateDir("t4")
let secret = "SENTINEL0d0f1e2a3b4c5d6e7f8091a2b3c4d5e6"     // stands in for the real token
let tokenPath = writeToken(secret)
seed(lastFired: anHourAgo)
Pong.shResponder = { _ in "job_id=job_20260101_000000_abcdef\nsession=\(session) worker=c1 status=queued" }
results = CronSchedule.tick(session: session, now: now)     // <- no dispatch injected: real file()
let script = Pong.shScripts.first ?? ""
check(Pong.shScripts.count == 1, "exactly one shell invocation", "count=\(Pong.shScripts.count)")
check(results.first?.1 == .dispatched, "outcome is dispatched",
      "got \(String(describing: results.first?.1))")
check(script.contains("export PONG_TOKEN=\"$(cat '\(tokenPath)' 2>/dev/null)\""),
      "script reads the token file itself", script)
check(!script.contains(secret),
      "the token VALUE is absent from the script (= the bash -c argv element)", script)
check(!Pong.logLines.joined(separator: "\n").contains(secret),
      "the token VALUE is absent from every log line", Pong.logLines.joined(separator: "\n"))
check(script.contains("unset PONG_SEAT"), "unset PONG_SEAT kept", script)
check(script.contains("python3 -m pong.cli.main -s \(session) job create --worker c1 --file "),
      "job create shape unchanged", script)
check(tokenPath.hasPrefix(stateDir4), "token path is under the temp state dir", tokenPath)

// Hand the exact emitted script to the Python-layer proof.
let sidecar: [String: Any] = ["script": script, "token_path": tokenPath, "session": session,
                              "state_dir": stateDir4, "token": secret]
Pong.writeJSON(outDir + "/captured.json", sidecar)
print("  ->   captured script written to \(outDir)/captured.json")

// MARK: - 5. a refusal from the control plane: logged, and the clock stays put

section("T5  control plane refuses (the live failure) => logged, clock unchanged, no token in the log")
_ = freshStateDir("t5")
_ = writeToken(secret)
seed(lastFired: anHourAgo)
Pong.shResponder = { _ in
    "write to session '\(session)' refused — present matching PONG_TOKEN (caller=none)"
}
results = CronSchedule.tick(session: session, now: now)
let logs = Pong.logLines.joined(separator: "\n")
check(results.first?.1 == .failed("job create refused"), "outcome is failed",
      "got \(String(describing: results.first?.1))")
check(persistedLastFired() == anHourAgo,
      "persisted last_fired still \(anHourAgo) after a refusal", "got \(persistedLastFired())")
check(logs.contains("cron dispatch failed for perimeter"), "the refusal is logged", logs)
check(!logs.contains(secret), "no token value in the logged output", logs)

// MARK: - 6. missing token file: visible, not a crash

section("T6  no token file yet => named in the log, still attempts, still no crash")
let stateDir6 = freshStateDir("t6")
seed(lastFired: anHourAgo)
Pong.shResponder = { _ in "write to session '\(session)' refused — present matching PONG_TOKEN (caller=none)" }
results = CronSchedule.tick(session: session, now: now)
let logs6 = Pong.logLines.joined(separator: "\n")
check(logs6.contains("no session token at \(stateDir6)/sessions/\(session)/token"),
      "missing token is reported with its path", logs6)
check(Pong.shScripts.count == 1,
      "still attempts (the CLI creates the token while refusing, so the next tick works)")
check(persistedLastFired() == anHourAgo, "clock unchanged", "got \(persistedLastFired())")

// MARK: - 7. a disabled / not-due job is untouched (no regression in the surrounding logic)

section("T7  not-due job is left alone")
_ = freshStateDir("t7")
seed(lastFired: now.timeIntervalSince1970 - 60)      // 1 min ago, cadence 15m
dispatched = 0
results = CronSchedule.tick(session: session, now: now, dispatch: { _, _, _ in
    dispatched += 1
    return true
})
check(results.first?.1 == .notDue, "outcome is notDue", "got \(String(describing: results.first?.1))")
check(dispatched == 0, "dispatch NOT called")

// MARK: - 8. claiming stamps on disk before any filing (the background runner's half)

section("T8  claimDue stamps first, so a second pass in the same minute files nothing")
_ = freshStateDir("t8")
seed(lastFired: anHourAgo)
let (claims8, _) = CronSchedule.claimDue(session: session, now: now)
check(claims8.count == 1, "one due job claimed", "got \(claims8.count)")
check(persistedLastFired() == now.timeIntervalSince1970, "stamp is on disk before filing", "got \(persistedLastFired())")
check(claims8.first?.before == anHourAgo, "the claim remembers the old clock", "got \(String(describing: claims8.first?.before))")
let (again8, _) = CronSchedule.claimDue(session: session, now: now)
check(again8.isEmpty, "a second pass claims nothing", "got \(again8.count)")
check(Pong.shScripts.isEmpty, "claiming files nothing", "count=\(Pong.shScripts.count)")

// MARK: - 9. a refused filing rolls back only a stamp nobody has touched since

section("T9  rollBack restores the clock, unless the stamp moved on")
_ = freshStateDir("t9")
seed(lastFired: anHourAgo)
let (claims9, _) = CronSchedule.claimDue(session: session, now: now)
if let c = claims9.first {
    CronSchedule.rollBack(session: session, id: c.job.id, stamp: c.stamp, to: c.before)
    check(persistedLastFired() == anHourAgo, "refused filing: clock back where it was", "got \(persistedLastFired())")
    check(CronSchedule.isDue(CronSchedule.load(session: session)[0], now: now), "and the job is due again")
    // someone ran it by hand since: that newer stamp stays
    seed(lastFired: now.timeIntervalSince1970 + 30)
    CronSchedule.rollBack(session: session, id: c.job.id, stamp: c.stamp, to: c.before)
    check(persistedLastFired() == now.timeIntervalSince1970 + 30, "a newer stamp is left alone", "got \(persistedLastFired())")
} else {
    check(false, "a claim to roll back")
}

// MARK: - 10. a team that was stopped does not owe what it missed

section("T10 a team just started: due jobs start their clock, nothing fires")
_ = freshStateDir("t10")
seed(lastFired: anHourAgo)
let (claims10, results10) = CronSchedule.claimDue(session: session, now: now, justStarted: true)
check(claims10.isEmpty, "nothing claimed", "got \(claims10.count)")
check(results10.first?.1 == .seeded, "outcome is seeded", "got \(String(describing: results10.first?.1))")
check(persistedLastFired() == now.timeIntervalSince1970, "clock starts now", "got \(persistedLastFired())")

// MARK: - 11. a gated job's draft task names the person from settings, never a fixed name

section("T11 the draft-only task says where the owner (settings.json owner_name) can see it")
func seedOutward() {
    Pong.writeJSON(schedulePath(), [
        session: [[
            "id": "mail", "name": "Weekly mail", "task": "Send the weekly report email to the client.",
            "cadence": "every 15m", "interval_sec": 900.0, "phase_sec": 0.0, "owner_id": "c1",
            "enabled": true, "last_fired": anHourAgo,
        ]],
    ])
}
let stateDir11 = freshStateDir("t11")
seedOutward()
let (claims11, _) = CronSchedule.claimDue(session: session, now: now)
check(claims11.first?.outward == true, "the email task is gated")
check(claims11.first?.body.contains("put it where the person can see it") == true,
      "no owner name set: 'the person'", claims11.first?.body ?? "")
_ = freshStateDir("t11b")
Pong.writeJSON(Pong.stateDir + "/settings.json", ["owner_name": "Sam"])
seedOutward()
let (claims11b, _) = CronSchedule.claimDue(session: session, now: now)
check(claims11b.first?.body.contains("put it where Sam can see it") == true,
      "owner_name Sam is used", claims11b.first?.body ?? "")
check(stateDir11 != Pong.stateDir, "each case has its own temp state dir")
_ = freshStateDir("t11c")
Pong.writeJSON(Pong.stateDir + "/settings.json", ["owner_name": "  Sam\n\nLee  "])
seedOutward()
let (claims11c, _) = CronSchedule.claimDue(session: session, now: now)
check(claims11c.first?.body.contains("put it where Sam Lee can see it") == true,
      "a name typed over two lines reads as one", claims11c.first?.body ?? "")
_ = freshStateDir("t11d")
Pong.writeJSON(Pong.stateDir + "/settings.json", ["owner_name": "   "])
seedOutward()
let (claims11d, _) = CronSchedule.claimDue(session: session, now: now)
check(claims11d.first?.body.contains("put it where the person can see it") == true,
      "a blank name is 'the person'", claims11d.first?.body ?? "")

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED (\(failures))")
    exit(1)
}
print("OK")
exit(0)
