import Foundation

/// What one seat is doing, in a sentence a person can absorb.
///
/// The display this feeds is only worth having if it is honest, so every pulse
/// carries how old it is. A line that confidently says a dead seat is "working
/// on auth" is worse than no line at all — it teaches you to stop believing the
/// display.
struct SeatPulse {
    let seat: String
    let label: String
    /// Cheap mechanical phrasing. Instant, no model, no cost.
    let line: String
    /// Seconds since this seat's pane last changed.
    let age: TimeInterval
    let needsYou: Bool
    let stale: Bool
    /// Higher sorts first. Need beats output.
    let urgency: Int

    /// Short ambient form for the island — the thing you catch out of the
    /// corner of your eye, not a log line.
    var ambient: String {
        stale ? "\(line) \(SeatPulseEngine.ageWords(age))." : line
    }

    /// Fuller form for the CyberPong human window, always stamped with age.
    var detailed: String {
        "\(line) · \(SeatPulseEngine.ageWords(age))"
    }
}

/// Turns raw seat state and terminal output into the top few pulses.
///
/// Ranking favours the seat that needs a human over the seat producing the most
/// output: a seat stopped at a permission prompt emits almost nothing and is the
/// single most valuable thing this can surface, while a seat grinding happily
/// through a long task is the least urgent. Ordering by recent activity gets
/// that exactly backwards.
enum SeatPulseEngine {

    // Pane fingerprints, so "age" means "since anything actually changed"
    // rather than "since we last looked".
    private static var paneMark: [String: String] = [:]
    private static var paneChangedAt: [String: TimeInterval] = [:]
    private static let lock = NSLock()

    /// Past this, the wording admits the line is not fresh.
    static let staleAfter: TimeInterval = 150
    /// Past this, it stops asserting activity at all.
    static let deadAfter: TimeInterval = 12 * 60
    /// A busy seat whose pane has not moved for this long has stopped talking.
    ///
    /// Usually it is just thinking. Sometimes it is stopped dead behind a native
    /// macOS sheet — an Automation or Accessibility consent dialog — which is
    /// drawn by another process and never appears in the pane at all. From here
    /// those two look identical, and a frozen pane is the only thing that
    /// separates them, so it gets surfaced rather than guessed at or silently
    /// answered.
    static let silentAfter: TimeInterval = 90
    /// Reading two dozen panes on a poll is not free. Only busy seats can be
    /// blocked or wedged, so only busy seats are worth the capture.
    static let maxCaptures = 8

    static let urgencyNeedsYou = 40
    static let urgencyStalled = 30
    /// Above ordinary work, below a confirmed stall: something a person should
    /// glance at, not something that is definitely wrong.
    static let urgencySilent = 25
    static let urgencyBusy = 20
    static let urgencyIdle = 0

    // MARK: Redaction

    /// Terminal output carries keys, tokens and file contents. Nothing leaves
    /// this function with a credential still in it — a status line is never
    /// worth a leak, and this text goes to a window and to disk.
    static func scrub(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            ("(?i)\\b[a-z]{2,4}-[A-Za-z0-9_-]{20,}", "«key»"),
            ("\\bgh[pousr]_[A-Za-z0-9]{16,}", "«token»"),
            ("\\bAKIA[0-9A-Z]{12,}", "«aws-key»"),
            ("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}[.A-Za-z0-9_-]*", "«jwt»"),
            ("(?i)\\bbearer\\s+[A-Za-z0-9._-]{10,}", "bearer «token»"),
            ("(?i)\\b(api[_-]?key|secret|password|passwd|token|authorization)\\b\\s*[:=]\\s*\\S+",
             "$1 «redacted»"),
            ("(?i)\\b(export\\s+[A-Z_]*(KEY|SECRET|TOKEN|PASSWORD)[A-Z_]*)=\\S+", "$1=«redacted»"),
            // A bare env assignment with no `export` and no lower-case word to
            // anchor on: AWS_SECRET_ACCESS_KEY=… slipped through every rule
            // above, because \bsecret\b cannot match inside an underscored name.
            ("\\b([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIALS?|AUTH)[A-Z0-9_]*)\\s*=\\s*\\S+",
             "$1=«redacted»"),
            ("\\b[A-Fa-f0-9]{32,}\\b", "«hash»"),
        ]
        for (p, r) in rules {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t
    }

    // MARK: Age wording

    static func ageWords(_ age: TimeInterval) -> String {
        if age < 0 { return "just now" }
        if age < 45 { return "just now" }
        if age < 90 { return "a minute ago" }
        let m = Int(age / 60)
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return h == 1 ? "over an hour ago" : "\(h)h ago"
    }

    // MARK: Pane reading

    /// A seat's pane, scrubbed. Never the island — it has no pane, and reading
    /// our own output back in would make the display narrate itself.
    private static func capture(target: String) -> String {
        let q = target.replacingOccurrences(of: "'", with: "'\\''")
        let out = Pong.sh("tmux capture-pane -p -J -t '\(q)' -S -40 2>/dev/null")
        return scrub(HumanConsoleController.stripAnsiPublic(out))
    }

    /// Fingerprint of what a pane is SAYING, not of how it is animating.
    ///
    /// Hashing the raw pane made `age` meaningless, and age is the whole honesty
    /// guarantee of this display. Two captures of the chief's pane five seconds
    /// apart differ by exactly one character — a spinner flipping ◉ to ○ — and a
    /// raw hash reads that as fresh activity. So age reset on every poll, a
    /// wedged seat could never reach stale (150s) or dead (12m), and the display
    /// would confidently describe a seat that had been stopped for an hour.
    ///
    /// The volatile chrome is therefore removed before hashing rather than
    /// hashed and hoped over. Only time, rate and spinner furniture is stripped:
    /// counts and words survive, because a changing count IS progress.
    static func paneFingerprint(_ pane: String) -> String {
        var t = pane
        let volatile = [
            "[\u{2800}-\u{28FF}]",                                  // braille spinners
            "[◉○●◌◍◎⦿✽✻✢✳✶✷◐◑◒◓◔◕⣾⣽⠿⏳⌛]",                          // dot / clock spinners
            "\\b\\d{1,2}:\\d{2}(:\\d{2})?\\s*([AaPp][Mm])?",        // clocks
            "\\b\\d+(\\.\\d+)?\\s*(ms|s|m|h)\\b",                   // 45s, 2m11s
            "\\b\\d+(\\.\\d+)?[kKmM]?\\s*/\\s*\\d+(\\.\\d+)?[kKmM]?\\b", // 185K / 500K
            "\\b\\d+(\\.\\d+)?\\s*tokens?(/s)?\\b",                 // token meters
            "\\b\\d+\\s*%",                                         // progress
            "[↑↓]\\s*\\d+",                                         // transfer counters
            "(?i)esc to interrupt",
            "(?i)worked for[^\n]*",
            // Whatever codepoint this month's TUI spins. The chief's pane cycles
            // ⸬ to : and back; the named glyph classes above miss it, and
            // enumerating every spinner anyone ships is whack-a-mole. An
            // isolated run of one or two symbols standing alone between spaces
            // is furniture — a spinner, a rule, a divider. Prose punctuation is
            // attached to a word and survives this untouched.
            "(?<=\\s)[^\\p{L}\\p{N}\\s]{1,2}(?=\\s)",
        ]
        for p in volatile {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // A redraw that only re-pads a line is not activity either.
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return HumanConsoleController.stableFingerprint(t)
    }

    /// True when a pane is showing a prompt that only a person can clear.
    /// This is the highest-value signal the display has, so it is matched
    /// tightly — a false "waiting on you" costs more than a missed one.
    ///
    /// `ourOwn` carries lines this display has already published. The island is
    /// a separate app with no pane, so it cannot be captured directly — but a
    /// seat that prints one of our cards back into its terminal would let the
    /// display read itself and start narrating its own output. Drop those.
    static func blockedPrompt(_ pane: String, excluding ourOwn: [String] = []) -> String? {
        let lines = pane.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { l in
                !ourOwn.contains { own in
                    own.count >= 16 && (l.contains(own) || own.contains(l))
                }
            }
        let tail = lines.suffix(12)
        let needles = [
            "do you want to proceed", "do you want to continue",
            "[y/n]", "(y/n)", "y/n?", "allow this tool", "allow tool",
            "grant access", "requires approval", "waiting for your approval",
            "press enter to continue", "authorize this", "permission to",
        ]
        for l in tail.reversed() {
            let low = l.lowercased()
            if needles.contains(where: { low.contains($0) }) {
                return String(l.prefix(90))
            }
        }
        return nil
    }

    // MARK: Ranking

    /// The five (or `limit`) seats most worth a person's attention.
    static func top(session: String, limit: Int = 5) -> [SeatPulse] {
        guard !session.isEmpty else { return [] }
        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        guard let team = ((snap["teams"] as? [[String: Any]]) ?? [])
            .first(where: { ($0["session"] as? String) == session }) else { return [] }
        let workers = (team["workers"] as? [[String: Any]]) ?? []
        let jobsBlob = team["jobs"] as? [String: Any]
        let open = (jobsBlob?["open"] as? [[String: Any]]) ?? []
        let now = Date().timeIntervalSince1970

        // Newest open job per seat — what it is actually on right now.
        var jobBySeat: [String: [String: Any]] = [:]
        for j in open {
            guard let w = j["worker"] as? String else { continue }
            let ts = (j["updated_at"] as? Double) ?? 0
            if let cur = jobBySeat[w], ((cur["updated_at"] as? Double) ?? 0) >= ts { continue }
            jobBySeat[w] = j
        }

        // Only busy seats can be blocked or wedged, so only they earn a capture.
        let busySeats = workers.filter { w in
            let hint = ((w["status_hint"] as? String) ?? "").lowercased()
            return hint.contains("busy") || hint.contains("running")
                || jobBySeat[(w["id"] as? String) ?? ""] != nil
        }
        let ourOwn = HumanConsoleController.recentCardTexts(session: session, limit: 12)
        var captured: [String: String] = [:]
        for w in busySeats.prefix(maxCaptures) {
            let id = (w["id"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            let pane = (w["pane_id"] as? String) ?? ""
            let idx = (w["tmux_index"] as? Int) ?? -1
            let target = !pane.isEmpty ? pane : (idx >= 0 ? "\(session):\(idx)" : "")
            guard !target.isEmpty else { continue }
            captured[id] = capture(target: target)
        }

        var pulses: [SeatPulse] = []
        for w in workers {
            let id = (w["id"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            let label = (w["label"] as? String) ?? id
            let hint = ((w["status_hint"] as? String) ?? "").lowercased()
            let job = jobBySeat[id]
            let busy = hint.contains("busy") || hint.contains("running") || job != nil

            // Age is measured from the last real change in the pane.
            var age: TimeInterval = 0
            if let pane = captured[id] {
                let mark = paneFingerprint(pane)
                lock.lock()
                if paneMark[id] != mark {
                    paneMark[id] = mark
                    paneChangedAt[id] = now
                }
                age = now - (paneChangedAt[id] ?? now)
                lock.unlock()
            } else if let j = job, let up = j["updated_at"] as? Double {
                age = now - up
            }

            let prompt = captured[id].flatMap { blockedPrompt($0, excluding: ourOwn) }
            let jobStatus = ((job?["status"] as? String) ?? "").lowercased()
            let flagged = (job?["human_takeover"] as? Bool) == true
                || jobStatus.contains("human") || jobStatus.contains("ask")
                || hint.contains("human") || hint.contains("takeover")
            let needsYou = flagged || prompt != nil

            let minutes = ((job?["updated_at"] as? Double).map { (now - $0) / 60 })
                ?? (age / 60)
            let wedged = busy && !needsYou && (age >= deadAfter || minutes > 20)
            let silent = busy && !needsYou && !wedged && age >= silentAfter
            let stale = age >= staleAfter

            let task = HumanConsoleController.humanTaskLine(
                (job?["task_preview"] as? String) ?? (job?["task"] as? String) ?? "")

            let line: String
            if needsYou {
                if let p = prompt {
                    line = "\(label) is waiting on you — \(p)"
                } else if task.isEmpty {
                    line = "\(label) is waiting on you."
                } else {
                    line = "\(label) is waiting on you on \(task)."
                }
            } else if wedged {
                // Dash rather than "is on X" — a task headline keeps its own
                // capital, and "is on Two related pieces" reads like a typo.
                line = task.isEmpty
                    ? "\(label) has gone quiet with a job still open."
                    : "\(label) — \(task), \(Int(minutes))m with nothing new."
            } else if silent {
                let m = max(1, Int(age / 60))
                let head = task.isEmpty
                    ? "\(label) has printed nothing for \(m)m"
                    : "\(label) — \(task), nothing for \(m)m"
                // Once a pane has been frozen for minutes rather than seconds,
                // a native sheet nobody can see is the likeliest explanation —
                // and it is the one thing a person has to go and look at.
                line = age >= 300 ? "\(head). It may be stopped on a system dialog."
                                  : "\(head)."
            } else if busy {
                line = task.isEmpty ? "\(label) is working." : "\(label) — \(task)."
            } else {
                line = "\(label) is free."
            }

            let urgency = needsYou ? urgencyNeedsYou
                : (wedged ? urgencyStalled
                   : (silent ? urgencySilent : (busy ? urgencyBusy : urgencyIdle)))
            pulses.append(SeatPulse(seat: id, label: label, line: line, age: age,
                                    needsYou: needsYou, stale: stale, urgency: urgency))
        }

        // Need first. Within the same kind, a seat grinding a long task is the
        // least interesting, so shorter waits surface ahead of long ones.
        pulses.sort { a, b in
            if a.urgency != b.urgency { return a.urgency > b.urgency }
            if a.urgency == urgencyNeedsYou { return a.age > b.age }
            return a.age < b.age
        }
        return Array(pulses.prefix(limit))
    }
}
