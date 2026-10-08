import AppKit
import Foundation

// MARK: - Cron schedule (who does what · when)

/// Persistent per-team cron definitions. Stored at `~/.pong/cron-schedules.json`.
enum CronSchedule {
    struct Job: Equatable {
        var id: String
        var name: String
        /// What the owner agent should actually do when this fires.
        var task: String
        /// Human cadence label, e.g. "every 15m", "daily 04:00"
        var cadence: String
        /// Interval seconds for next-run math (0 = use clock phase only)
        var intervalSec: TimeInterval
        /// Seconds-from-midnight phase for daily jobs; also used as stagger for intervals
        var phaseSec: TimeInterval
        /// Seat id on the team (c1, w1, …) — owner that fires the job
        var ownerId: String
        var enabled: Bool
        /// When this last fired, epoch seconds; 0 = never seen by the runner.
        ///
        /// Lives beside the schedule so it survives a restart. Without it the
        /// runner has no memory and every tick after a due time fires again —
        /// a burst, not a cron.
        var lastFired: TimeInterval = 0

        func asDict() -> [String: Any] {
            [
                "id": id, "name": name, "task": task, "cadence": cadence,
                "interval_sec": intervalSec, "phase_sec": phaseSec,
                "owner_id": ownerId, "enabled": enabled,
                "last_fired": lastFired,
            ]
        }

        static func from(_ d: [String: Any]) -> Job? {
            guard let name = d["name"] as? String, !name.isEmpty else { return nil }
            let id = (d["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(UUID().uuidString.prefix(8)).lowercased()
            let task = (d["task"] as? String)
                ?? (d["prompt"] as? String)
                ?? (d["description"] as? String)
                ?? ""
            return Job(
                id: id,
                name: name,
                task: task,
                cadence: (d["cadence"] as? String) ?? "hourly",
                intervalSec: (d["interval_sec"] as? Double)
                    ?? Double("\(d["interval_sec"] ?? 3600)") ?? 3600,
                phaseSec: (d["phase_sec"] as? Double)
                    ?? Double("\(d["phase_sec"] ?? 0)") ?? 0,
                ownerId: (d["owner_id"] as? String) ?? "c1",
                enabled: (d["enabled"] as? Bool) ?? true,
                lastFired: (d["last_fired"] as? Double) ?? 0
            )
        }

        /// Next fire date after `from`.
        func nextRun(after from: Date = Date()) -> Date {
            guard enabled else { return from.addingTimeInterval(365 * 86400) }
            // daily only when the interval IS a day: "every 168h" is weekly, not daily
            if abs(intervalSec - 86400) < 2 {
                // Daily (or longer): next day at phaseSec from midnight local
                let cal = Calendar.current
                var comps = cal.dateComponents([.year, .month, .day], from: from)
                comps.hour = 0; comps.minute = 0; comps.second = 0
                let midnight = cal.date(from: comps) ?? from
                var candidate = midnight.addingTimeInterval(phaseSec)
                if candidate <= from {
                    candidate = candidate.addingTimeInterval(86400)
                }
                return candidate
            }
            if intervalSec <= 0 { return from.addingTimeInterval(3600) }
            // Interval jobs: align to epoch + phase
            let t = from.timeIntervalSince1970
            let base = floor((t - phaseSec) / intervalSec) * intervalSec + phaseSec
            var next = base + intervalSec
            if next <= t { next += intervalSec }
            return Date(timeIntervalSince1970: next)
        }

        var ownerTag: String {
            let o = ownerId.lowercased()
            if o.hasPrefix("c") { return "ORCH \(ownerId.uppercased())" }
            if o.hasPrefix("w") { return "AGT \(ownerId.uppercased())" }
            return ownerId.uppercased()
        }
    }

    private static var path: String { Pong.stateDir + "/cron-schedules.json" }

    static func load(session: String) -> [Job] {
        let db = Pong.loadJSON(path)
        // Explicit empty array = user chose no cron (wizard / cleared). Never auto-seed.
        if let arr = db[session] as? [[String: Any]] {
            return arr.compactMap { Job.from($0) }
        }
        return []
    }

    static func save(session: String, jobs: [Job]) {
        var db = Pong.loadJSON(path)
        db[session] = jobs.map { $0.asDict() }
        db["updated"] = Date().timeIntervalSince1970
        Pong.writeJSON(path, db)
    }

    /// Insert or replace by id (or by case-insensitive name when id empty).
    @discardableResult
    static func upsert(session: String, job: Job) -> Job {
        var jobs = load(session: session)
        var j = job
        if j.id.isEmpty {
            j.id = String(UUID().uuidString.prefix(8)).lowercased()
        }
        if let ix = jobs.firstIndex(where: { $0.id == j.id }) {
            jobs[ix] = j
        } else if let ix = jobs.firstIndex(where: { $0.name.lowercased() == j.name.lowercased() }) {
            j.id = jobs[ix].id
            jobs[ix] = j
        } else {
            jobs.append(j)
        }
        save(session: session, jobs: jobs)
        Pong.log("CronSchedule.upsert session=\(session) id=\(j.id) name=\(j.name) owner=\(j.ownerId) cadence=\(j.cadence)")
        return j
    }

    // MARK: - Running them

    /// What a tick decided about one job. Returned so the runner is testable
    /// without a control plane, and logged so a missed cron is diagnosable.
    enum Outcome: Equatable {
        case seeded            // first sight: clock started, deliberately not fired
        case dispatched
        case gated             // would send/spend/publish — a draft job was filed instead
        case notDue
        case disabled
        case failed(String)
    }

    /// Verbs that mean the task reaches outside this machine.
    ///
    /// Deliberately generous: a false positive costs a draft job that a person
    /// approves, a false negative sends mail or moves money on a timer with
    /// nobody's name on it. The gate is the whole reason a cron runner is
    /// allowed to exist here at all.
    private static let outwardVerbs = [
        "send", "email", "e-mail", "reply", "publish", "post ", "tweet", "dm ",
        "spend", "pay ", "invoice", "charge", "refund", "purchase", "buy ",
        "deploy", "release", "ship to", "merge to main", "grant", "scope",
    ]

    static func reachesOutside(_ task: String) -> Bool {
        let t = task.lowercased()
        return outwardVerbs.contains { t.contains($0) }
    }

    /// Is this job due, given when it last fired?
    ///
    /// Anchored on lastFired rather than on the clock alone, so a machine that
    /// was asleep for a week fires once on wake instead of replaying every
    /// missed slot.
    static func isDue(_ job: Job, now: Date) -> Bool {
        guard job.enabled, job.lastFired > 0 else { return false }
        return job.nextRun(after: Date(timeIntervalSince1970: job.lastFired)) <= now
    }

    /// A due job, stamped and waiting to be filed.
    struct Claim {
        let job: Job
        let body: String
        let outward: Bool
        /// lastFired before the stamp, to roll back to if the filing is refused.
        let before: TimeInterval
        let stamp: TimeInterval
    }

    /// The deciding half of a tick: seed first sights, stamp what is due, save.
    /// Nothing is filed here, so this is quick and safe on the main thread.
    /// `justStarted`: the team was stopped at the last pass. What it missed while
    /// stopped is not owed, so its due jobs start their clocks from now instead of
    /// all firing the moment it comes back.
    static func claimDue(session: String, now: Date, justStarted: Bool = false) -> (claims: [Claim], results: [(String, Outcome)]) {
        var jobs = load(session: session)
        guard !jobs.isEmpty else { return ([], []) }
        var claims: [Claim] = []
        var results: [(String, Outcome)] = []
        var changed = false

        for i in jobs.indices {
            let job = jobs[i]
            guard job.enabled else {
                results.append((job.id, .disabled))
                continue
            }
            // First sight starts the clock instead of firing. Otherwise every
            // cron on a freshly installed team goes off at once, which is a
            // thundering herd rather than a schedule.
            if job.lastFired <= 0 {
                jobs[i].lastFired = now.timeIntervalSince1970
                changed = true
                results.append((job.id, .seeded))
                continue
            }
            guard isDue(job, now: now) else {
                results.append((job.id, .notDue))
                continue
            }
            if justStarted {
                jobs[i].lastFired = now.timeIntervalSince1970
                changed = true
                results.append((job.id, .seeded))
                continue
            }
            // Stamp BEFORE dispatching. A dispatch that takes longer than the
            // tick interval must not let the next tick see the same job as due.
            jobs[i].lastFired = now.timeIntervalSince1970
            changed = true
            let outward = reachesOutside(job.task)
            claims.append(Claim(job: job, body: outward ? draftOnlyTask(job) : job.task, outward: outward,
                                before: job.lastFired, stamp: now.timeIntervalSince1970))
        }
        if changed { save(session: session, jobs: jobs) }
        return (claims, results)
    }

    /// Nothing was filed, so the clock must not move. A refused dispatch that
    /// still advanced lastFired is worse than a loud failure: the job silently
    /// skips its slot and the schedule reads as healthy. Roll back, stay due,
    /// try again next tick. Only when nobody has touched the stamp since.
    static func rollBack(session: String, id: String, stamp: TimeInterval, to before: TimeInterval) {
        var jobs = load(session: session)
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].lastFired == stamp else { return }
        jobs[i].lastFired = before
        save(session: session, jobs: jobs)
    }

    /// One pass over a team's schedule, filing on this thread.
    ///
    /// `dispatch` is injected so the decision logic can be tested without a
    /// control plane; the default actually files the job.
    @discardableResult
    static func tick(session: String,
                     now: Date = Date(),
                     dispatch: (Job, String, String) -> Bool = CronSchedule.file) -> [(String, Outcome)] {
        var (claims, results) = claimDue(session: session, now: now)
        for c in claims {
            if dispatch(c.job, c.body, session) {
                results.append((c.job.id, c.outward ? .gated : .dispatched))
            } else {
                rollBack(session: session, id: c.job.id, stamp: c.stamp, to: c.before)
                results.append((c.job.id, .failed("job create refused")))
            }
        }
        for (id, outcome) in results where outcome != .notDue && outcome != .disabled {
            Pong.log("cron \(session)/\(id): \(outcome)")
        }
        return results
    }

    /// The one clock that fires crons, for the life of the app.
    ///
    /// A minute, not a poll: the shortest cadence the parser accepts is "every
    /// 1m", so a 60s tick can be at most a minute late and costs one JSON read
    /// per team. This is deliberately not a watcher that wakes c1 and not a
    /// 10Hz loop — it reads the schedule, and the only thing it can do is file a job.
    private static var runner: Timer?

    /// Posted after a pass or a Run now filed something (the Schedules page redraws).
    static let didFire = Notification.Name("CronSchedule.didFire")

    /// Filing runs the CLI, which can take a second or two: never on the main thread.
    private static let filer = DispatchQueue(label: "pong.cron.file", qos: .utility)
    private static var passing = false
    /// The teams that were up at the runner's last pass (nil before the first one).
    private static var lastPassLive: Set<String>?

    /// Teams whose tmux session is up, as of the last pass (nil before the first).
    private(set) static var running: Set<String>?

    static func startRunner() {
        guard runner == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { _ in tickRunningTeams() }
        t.tolerance = 10                      // let the OS coalesce it; nothing here is urgent
        RunLoop.main.add(t, forMode: .common)
        runner = t
        Pong.log("cron runner started (60s, every running team)")
        tickRunningTeams()
    }

    /// Which teams are up: their tmux session exists. Off the main thread.
    private static func liveTeams() -> Set<String> {
        let out = Pong.sh("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        return Set(out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Look again at which teams are up, then call back on the main thread.
    static func refreshRunning(_ then: (() -> Void)? = nil) {
        filer.async {
            let live = liveTeams()
            DispatchQueue.main.async {
                running = live
                then?()
            }
        }
    }

    /// Fire what is due on every running team (1.9: it used to be the bound team only,
    /// so a second team's schedules sat on hold). Deciding and stamping happen on the
    /// main thread, where the pages write the schedule file too; filing goes to a
    /// background queue, and a refused filing rolls its stamp back. A stopped team's
    /// schedules wait: a job filed to a team with no seats would only pile up.
    private static func tickRunningTeams() {
        guard !passing else { return }
        passing = true
        refreshRunning {
            let live = running ?? []
            let previous = lastPassLive
            lastPassLive = live
            let db = Pong.loadJSON(path)
            var work: [(String, Claim)] = []
            for team in db.keys.sorted() where team != "updated" && live.contains(team) {
                // after a launch every team counts as up before: a Mac that slept still catches up once
                let justStarted = previous.map { !$0.contains(team) } ?? false
                let (claims, results) = claimDue(session: team, now: Date(), justStarted: justStarted)
                for (id, outcome) in results where outcome == .seeded {
                    Pong.log("cron \(team)/\(id): \(justStarted ? "team just started, clock starts now" : "seeded")")
                }
                work += claims.map { (team, $0) }
            }
            guard !work.isEmpty else { passing = false; return }
            filer.async {
                let filed = work.map { ($0.0, $0.1, file($0.1.job, $0.1.body, $0.0)) }
                DispatchQueue.main.async {
                    for (team, c, ok) in filed {
                        if !ok { rollBack(session: team, id: c.job.id, stamp: c.stamp, to: c.before) }
                        Pong.log("cron \(team)/\(c.job.id): \(ok ? (c.outward ? "gated" : "dispatched") : "failed: job create refused")")
                    }
                    passing = false
                    NotificationCenter.default.post(name: didFire, object: nil)
                }
            }
        }
    }

    /// Run one schedule now, whatever its clock says (Schedules › Run now). The next
    /// run counts from now; a refused filing rolls that back. `done` gets nil, or why
    /// it did not go, in plain words.
    static func runNow(session: String, id: String, done: @escaping (String?) -> Void) {
        var jobs = load(session: session)
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { done("That schedule is gone."); return }
        let job = jobs[i]
        let before = job.lastFired
        let stamp = Date().timeIntervalSince1970
        jobs[i].lastFired = stamp
        save(session: session, jobs: jobs)
        let body = reachesOutside(job.task) ? draftOnlyTask(job, byHand: true) : job.task
        filer.async {
            let ok = file(job, body, session)
            DispatchQueue.main.async {
                if !ok { rollBack(session: session, id: id, stamp: stamp, to: before) }
                Pong.log("cron \(session)/\(id): run now, \(ok ? "filed" : "refused")")
                done(ok ? nil : "The team didn't take it. Check that it's running.")
                NotificationCenter.default.post(name: didFire, object: nil)
            }
        }
    }

    /// The task a gated cron gets instead of its own.
    ///
    /// It still runs — the work of preparing is useful on a schedule — but it
    /// stops at the point where a person has to say yes, and it says so in the
    /// text rather than relying on the seat to remember. Run now is a person
    /// starting the task, not a person approving what it would send.
    private static func draftOnlyTask(_ job: Job, byHand: Bool = false) -> String {
        let why = byHand
            ? "Someone pressed Run now on this schedule: that starts the task, it approves nothing it would send."
            : "This fired on a timer, so nobody has approved it."
        // what the AIs call the person (settings.json "owner_name"), one line of at most 60
        // characters; "the person" until it is set
        let raw = (Pong.loadJSON(Pong.stateDir + "/settings.json")["owner_name"] as? String) ?? ""
        let named = String(raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(60))
        let owner = named.isEmpty ? "the person" : named
        return """
        SCHEDULED — \(job.name)

        \(job.task)

        HUMAN GATE. \(why) This
        wording looks like it would send, publish or spend. Prepare the work and
        STOP at the point of sending: draft it, put it where \(owner) can see it,
        and say plainly what you would do next and what it would cost. Do not
        send, publish, pay, deploy, or widen a scope. A named human presses the
        button, not a schedule.
        """
    }

    /// File a real job on the control plane. One dispatch path, the same one
    /// the rest of the app uses.
    private static func file(_ job: Job, _ body: String, _ session: String) -> Bool {
        let tmp = NSTemporaryDirectory() + "pong-cron-\(job.id)-\(UUID().uuidString).md"
        do {
            try body.write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            Pong.log("cron could not stage task for \(job.id): \(error.localizedDescription)")
            return false
        }
        // PONG_SEAT unset for the same reason the bar setter unsets it: the
        // control plane infers the assigner from the environment, and a stray
        // seat id would make a schedule look like one seat routing to another.
        // The control plane refuses an explicit `-s <session>` from a caller it
        // cannot identify (routing.resolve_write_session): this app exports no
        // PONG_SESSION, so it is caller=none and must present that session's own
        // token. bash reads the token file itself — interpolating the secret into
        // this script would put it in the `bash -c` argv, where `ps` shows it to
        // anything running on the box. Only the path travels in argv.
        let tokenPath = Pong.stateDir + "/sessions/\(session)/token"
        if !FileManager.default.fileExists(atPath: tokenPath) {
            // Not fatal, and deliberately not a second auth path: the CLI creates
            // the token while refusing this attempt, so the next tick authenticates.
            // Logged so "refused once, right after install" is readable.
            Pong.log("cron \(job.id): no session token at \(tokenPath) — this dispatch will be refused")
        }
        let out = Pong.sh("""
        \(SessionArchive.pongPrefix())
        unset PONG_SEAT
        export PONG_TOKEN="$(cat '\(tokenPath)' 2>/dev/null)"
        python3 -m pong.cli.main -s \(session) job create --worker \(job.ownerId) --file '\(tmp)' 2>&1
        """)
        try? FileManager.default.removeItem(atPath: tmp)
        // The CLI writes the job file and THEN tries to deliver it. A seat with
        // no pane makes it exit non-zero while the job is already written and
        // queued for the waitroom, so job_id= is the honest test of "did this
        // cron fire" — but a delivery that failed still has to be visible, or a
        // cron that never reaches its seat looks identical to one that did.
        let ok = out.contains("job_id=")
        if !ok {
            Pong.log("cron dispatch failed for \(job.id): \(out.prefix(200))")
        } else if out.contains("error:") {
            Pong.log("cron \(job.id) queued but not delivered: \(out.prefix(200))")
        }
        return ok
    }

    /// Parse human cadence into interval + phase. Accepts "every 15m", "every 1h", "daily 04:00".
    static func parseCadence(_ raw: String) -> (label: String, intervalSec: TimeInterval, phaseSec: TimeInterval) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.isEmpty {
            return ("every 1h", 3600, 0)
        }
        if let re = try? NSRegularExpression(pattern: #"every\s+(\d+)\s*m"#, options: .caseInsensitive),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range(at: 1), in: s),
           let n = Int(s[r]), n > 0 {
            return ("every \(n)m", TimeInterval(n * 60), 0)
        }
        if let re = try? NSRegularExpression(pattern: #"every\s+(\d+)\s*h"#, options: .caseInsensitive),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range(at: 1), in: s),
           let n = Int(s[r]), n > 0 {
            return ("every \(n)h", TimeInterval(n * 3600), 0)
        }
        if lower.hasPrefix("daily") || lower.contains("daily") {
            var phase: TimeInterval = 4 * 3600
            if let re = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})"#, options: []),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let rh = Range(m.range(at: 1), in: s),
               let rm = Range(m.range(at: 2), in: s),
               let h = Int(s[rh]), let mi = Int(s[rm]) {
                phase = TimeInterval(h * 3600 + mi * 60)
            }
            let label = s.isEmpty ? "daily 04:00" : s
            return (label, 86400, phase)
        }
        if let n = Int(s), n > 0 {
            return ("every \(n)m", TimeInterval(n * 60), 0)
        }
        return (s, 3600, 0)
    }

    /// Optional templates — only applied when the user opts in (wizard or Cron Manager).
    static func suggestedJobs(session: String) -> [Job] {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
        let workers = Workers.list(from: entry)
        let w1 = (workers.first?["id"] as? String) ?? "w1"
        let w2 = workers.count > 1 ? ((workers[1]["id"] as? String) ?? "w2") : w1
        let wSub = workers.last(where: {
            (($0["parent_id"] as? String) ?? "").isEmpty == false
        })?["id"] as? String

        return [
            Job(id: "perimeter", name: "Perimeter sweep",
                task: "Quick health check of open jobs, stuck seats, and route errors. Report anything that needs human or reassignment.",
                cadence: "every 15m",
                intervalSec: 15 * 60, phaseSec: 0, ownerId: condId, enabled: true),
            Job(id: "snapshot", name: "Snapshot",
                task: "Summarize team state: open jobs, last verdicts, reject streak. Keep it to 5 bullets.",
                cadence: "every 30m",
                intervalSec: 30 * 60, phaseSec: 120, ownerId: condId, enabled: true),
            Job(id: "telemetry", name: "Telemetry sync",
                task: "Pull latest control-plane events and note anomalies (failures, route refused, long runtime).",
                cadence: "every 1h",
                intervalSec: 3600, phaseSec: 300, ownerId: w2, enabled: true),
            Job(id: "audit", name: "Log audit",
                task: "Review recent job claims for weak evidence or scope drift. Flag anything that should have been rejected.",
                cadence: "every 6h",
                intervalSec: 6 * 3600, phaseSec: 600, ownerId: wSub ?? w1, enabled: true),
            Job(id: "warmup", name: "Model warmup",
                task: "Open your seat, confirm tool access, and reply READY with model + cwd. Do not start product work.",
                cadence: "daily 04:00",
                intervalSec: 86400, phaseSec: 4 * 3600, ownerId: w1, enabled: true),
        ]
    }

    /// Back-compat alias for Cron Manager “restore suggestions”.
    static func defaultJobs(session: String) -> [Job] { suggestedJobs(session: session) }

    /// Templates for the install wizard before the team session exists.
    /// `owners`: [(id, label)] e.g. c1 / w1… with display names.
    static func wizardSuggestions(owners: [(id: String, label: String)]) -> [Job] {
        let cond = owners.first?.id ?? "c1"
        let w1 = owners.first(where: { $0.id.hasPrefix("w") })?.id ?? owners.dropFirst().first?.id ?? cond
        let w2 = owners.dropFirst(2).first?.id ?? w1
        return [
            Job(id: "perimeter", name: "Perimeter sweep",
                task: "Quick health check of open jobs, stuck seats, and route errors. Report anything that needs human or reassignment.",
                cadence: "every 15m", intervalSec: 15 * 60, phaseSec: 0, ownerId: cond, enabled: true),
            Job(id: "snapshot", name: "Snapshot",
                task: "Summarize team state: open jobs, last verdicts, reject streak. Keep it to 5 bullets.",
                cadence: "every 30m", intervalSec: 30 * 60, phaseSec: 120, ownerId: cond, enabled: true),
            Job(id: "telemetry", name: "Telemetry sync",
                task: "Pull latest control-plane events and note anomalies (failures, route refused, long runtime).",
                cadence: "every 1h", intervalSec: 3600, phaseSec: 300, ownerId: w2, enabled: true),
            Job(id: "audit", name: "Log audit",
                task: "Review recent job claims for weak evidence or scope drift. Flag anything that should have been rejected.",
                cadence: "every 6h", intervalSec: 6 * 3600, phaseSec: 600, ownerId: w1, enabled: true),
            Job(id: "warmup", name: "Model warmup",
                task: "Open your seat, confirm tool access, and reply READY with model + cwd. Do not start product work.",
                cadence: "daily 04:00", intervalSec: 86400, phaseSec: 4 * 3600, ownerId: w1, enabled: true),
        ]
    }

    static func accent(forOwnerId ownerId: String, seats: [Seat3D]) -> NSColor {
        if let s = seats.first(where: { $0.id == ownerId }) {
            switch s.role {
            case "conductor": return PongTheme.blue
            case "subagent": return PongTheme.violet
            case "human": return PongTheme.amber
            default: return PongTheme.magenta
            }
        }
        let o = ownerId.lowercased()
        if o.hasPrefix("c") { return PongTheme.blue }
        if o.contains("sub") { return PongTheme.violet }
        return PongTheme.magenta
    }
}

// MARK: - end of CronSchedule (tests/swift/run.sh slices the enum above this line)
