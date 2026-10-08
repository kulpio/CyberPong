// PongIsland — a notch island for CyberPong.
//
// A VIEW, not a second brain. It never touches pong internals: it reads
// `pong snapshot` (contract v1) and every action shells out to a `pong` command
// you could have typed by hand. If this app vanished, nothing about the agents
// would change.
//
// Two properties worth protecting, both learned the hard way:
//
//   1. It must not steal focus. You approve a draft mid-sentence and keep typing
//      where you were. `.nonactivatingPanel` + becomesKeyOnlyIfNeeded gives that:
//      the panel takes the keyboard ONLY when you click into a field.
//   2. It must never cover what it is reporting on. It sits BELOW the menu bar.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuartzCore
import WebKit

// MARK: - Model ------------------------------------------------------------

struct Seat: Identifiable, Hashable {
    let id: String, label: String, type: String, state: String, reason: String
    var role: String = ""
    var hint: String = ""
    var paneActive: Bool = false
    var busyMinutes: Double = 0
    /// Who this seat reports to on the org graph, and whether it is a
    /// disposable loop seat. Both come straight off the snapshot; they decide
    /// which seats may own a loop (`Island.orgMains`).
    var parentId: String = ""
    var ephemeral: Bool = false
    /// Short usage chip from this poll's pane (`12.4k`, `84%`). Empty when
    /// the pane printed nothing — never a guessed or carried-forward number.
    var usageChip: String = ""
    /// Waitroom / job truth. Never pane-thinking — a spinning TUI is not a held seat.
    var deliveryBusy: Bool {
        state == "busy" || hint == "running" || hint == "busy"
    }
    /// Visible on the island: delivering a job, or mid-turn in the TUI.
    var busy: Bool { deliveryBusy || paneActive }
}

struct Approval: Identifiable, Hashable {
    let id: String, worker: String, workerLabel: String
    let round: Int, preview: String
}

/// A graph loop waiting on a person at a gate (`teams[].work_graph.graphs[].gates[]`).
/// Every team's, not only the one on show: the gate is where the person is needed.
struct GateItem: Identifiable, Hashable {
    let id: String                 // "<graph>:<gate node>:<opened at>": one visit of the gate
    let session: String, teamName: String, graphId: String, title: String
    let node: String, reason: String, summary: String
    let options: [String]          // the words this gate takes ("approved", "rejected", route labels)
    let routes: [String: [String]] // where each word goes; [] = it ends that branch
    let files: [String]            // the work to look at, full paths
    let notesPath: String
    let seat: String               // the seat of the step that led here ("" = nothing to open)
    let gradeLine: String          // how the reviewer and Jev graded the work, in words
    let adviceLine: String         // Jev's suggestion for this gate, or why there is none on show
    let question: String           // the question in plain words ("" = the engine gave none: show the summary)
    let context: [String]          // up to three short lines on what is being decided
    let choices: [String: String]  // what each answer does, in plain words
    var detail: [DetailPoint] = [] // what is being decided, in more depth, each fact with its file
    var detailBy = ""              // who wrote it: "CyberPong", "Claude Haiku", "the graph's designer"
    var detailPending = false      // the plain words or the details are still being written
}

/// A question an AI asked the person with `pong ask` (`teams[].asks[]`): the same card as a gate.
struct AskItem: Identifiable, Hashable {
    struct Option: Hashable { let key: String, label: String, what: String }
    let id: String
    let session: String, teamName: String
    let question: String
    let context: [String]
    let options: [Option]
    let files: [String]
    var detail: [DetailPoint] = []
    var detailBy = ""              // "the chat" or "Claude Haiku"
    var detailPending = false
}

/// One fact behind a question (the card's `detail`, 2.0): what it says, the file it comes from, and
/// where in that file. The island folds them under "Details"; the app shows them open.
struct DetailPoint: Hashable {
    let text: String
    let file: String               // a full path ("" = none)
    let place: String              // a heading or an item number ("" = none)

    /// A card's points: a list of {text, file, where}, a list of strings, one string (a point per
    /// line) or one {text, file, where}. The engine's limits, as the app reads them: at most six
    /// points, each at most 280 characters, 1,400 in all; a place at most 60.
    static func parse(_ a: Any?) -> [DetailPoint] {
        var raw: [(String, String, String)] = []
        if let s = a as? String {
            raw = s.components(separatedBy: .newlines).map { ($0, "", "") }
        } else if let d = a as? [String: Any] {
            raw = [((d["text"] as? String) ?? "", (d["file"] as? String) ?? "", (d["where"] as? String) ?? "")]
        } else if let list = a as? [Any] {
            for item in list {
                if let s = item as? String { raw.append((s, "", "")) }
                else if let d = item as? [String: Any] {
                    raw.append(((d["text"] as? String) ?? "", (d["file"] as? String) ?? "", (d["where"] as? String) ?? ""))
                }
            }
        }
        var out: [DetailPoint] = []
        var total = 0
        for (t, f, w) in raw where out.count < 6 {
            var text = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if let m = text.range(of: #"^[•·*\-–]\s+"#, options: .regularExpression) { text.removeSubrange(m) }
            guard !text.isEmpty else { continue }
            if text.count > 280 { text = String(text.prefix(279)) + "…" }
            guard total + text.count <= 1_400 else { break }
            total += text.count
            var place = w.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if place.count > 60 { place = String(place.prefix(59)) + "…" }
            out.append(DetailPoint(text: text, file: f.trimmingCharacters(in: .whitespacesAndNewlines), place: place))
        }
        return out
    }

    /// "Summary by Claude Haiku from the files", "Written by the chat" … ("" when nobody said).
    static func attribution(_ by: String) -> String {
        switch by.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": return ""
        case "Claude Haiku": return "Summary by Claude Haiku from the files · check the files for the full picture"
        case "the chat": return "Written by the chat"
        case "CyberPong": return "Written by CyberPong from the step's report"
        case "the graph's designer and Claude Haiku":
            return "Written by the graph's designer, with points by Claude Haiku from the files · check the files for the full picture"
        case "the graph's designer and CyberPong": return "Written by the graph's designer, with points from the step's report"
        case let who: return "Written by \(who)"
        }
    }
}

/// A running graph step whose seat needs a person: a permission question, a
/// folder to trust, or a terminal with no model running in it.
struct AttentionItem: Identifiable, Hashable {
    let id: String                 // "<graph>:<node>"
    let session: String, title: String, node: String, seat: String, what: String
}

struct ChatLine: Identifiable, Hashable {
    let id: String, kind: String, text: String, seat: String, ts: Double
    var mine: Bool { kind == "from_you" }
    var status: Bool { kind == "status" }
}

struct TeamRef: Identifiable, Hashable {
    let id: String        // session
    let name: String
    let busy: Int, needsYou: Int
}

/// Weekly usage for the model that is actually live on this team.
/// `available` is false unless this poll read a real weekly figure.
struct WeeklyUsage: Hashable {
    var model = ""
    var available = false
    var chip = ""
    var used = ""
    var remaining = ""
    var reset = ""
}

/// A running graph, on any team: one 32 pt line in the panel (1.9). A paused one is listed too, as
/// paused: the app's rule (GGraph.isWorking) is that a paused graph is never counted as working (2.0).
struct GraphLine: Identifiable {
    let id: String          // session/graph id
    let session: String
    let title: String
    let teamName: String
    let step: String        // the working step, by name
    let doing: String       // its latest line
    let since: Double
    let waiting: Bool       // at a question, or a step needs the person (counted under "need you")
    let paused: Bool        // held by a pause: the person's, or the runner's at Claude's limits
    let pausedWords: String // "Paused", "Paused for Claude's 5-hour limit"

    /// At work: not waiting on the person, not paused (the app's GGraph.isWorking).
    var working: Bool { !waiting && !paused }

    /// One graph of a team's snapshot, or nil when it isn't running. Waiting and paused read the way the
    /// app reads them (GGraph.waitingOnYou, isPausedNow): a graph at a question needs you, paused or not.
    static func from(_ g: [String: Any], session: String, teamName: String) -> GraphLine? {
        guard (g["status"] as? String) == "running", let gid = g["id"] as? String, !gid.isEmpty else { return nil }
        let nodes = (g["nodes"] as? [[String: Any]]) ?? []
        let live = nodes.first { ($0["status"] as? String) == "waiting_human" } ?? nodes.first { ($0["status"] as? String) == "running" }
        let stepId = (live?["id"] as? String) ?? ""
        let step = stepId.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let title = ((g["title"] as? String) ?? "").isEmpty ? gid : ((g["title"] as? String) ?? gid)
        let waiting = !((g["gates"] as? [[String: Any]]) ?? []).isEmpty || !((g["attention"] as? [[String: Any]]) ?? []).isEmpty
        return GraphLine(
            id: session + "/" + gid, session: session, title: title, teamName: teamName,
            step: step.prefix(1).uppercased() + step.dropFirst(),
            doing: ((live?["live"] as? [String: Any])?["doing"] as? String) ?? "",
            since: (g["created_at"] as? Double) ?? 0,
            waiting: waiting,
            paused: ((g["manual_pause"] as? Bool) ?? false) && !waiting,
            pausedWords: pausedWords((g["pause_reason"] as? String) ?? ""))
    }

    /// "Paused", or the runner's reason: "Paused for Claude's 5-hour limit" (the app's GGraph.pausedWords).
    static func pausedWords(_ reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.lowercased().hasPrefix("paused "), r.lowercased() != "paused by you" else { return "Paused" }
        return "Paused" + r.dropFirst(6)
    }
}

struct Island {
    var session = "", teamName = ""
    var teams: [TeamRef] = []
    /// Every running graph, paused ones included (each line says which).
    var graphsRunning: [GraphLine] = []
    var conductor: Seat?
    var seats: [Seat] = []
    var approvals: [Approval] = []
    var gates: [GateItem] = []
    var asks: [AskItem] = []
    var attention: [AttentionItem] = []
    var queued = 0, openJobs = 0
    var bridgeOn = false
    /// The lines the right ear rotates through, most urgent first. Each is a
    /// tone — "orange" | "green" | "purple" — and text already short enough to
    /// fit. Empty means say nothing: a quiet ear is the correct answer more
    /// often than not, and stale news teaches you to ignore it.
    var tickerLines: [(tone: String, text: String)] = []
    var lastReply = ""
    var weekly = WeeklyUsage()
    var chat: [ChatLine] = []
    /// Only the Chief thread: what you said, what c1 said, and status lines. Terminal chrome
    /// the pane reader picked up (a menu's key hints, a spinner's token count) is not something
    /// anyone said, and an old spinner line read as work that had long stopped.
    var chiefChat: [ChatLine] { chat.filter { ($0.seat.isEmpty || $0.seat == "c1") && !Island.isChrome($0.text) } }

    static func isChrome(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("enter to select") || l.contains("to navigate") || l.contains("esc to")
            || l.contains("? for shortcuts") || l.contains("bypass permissions")
            || (l.contains(" tokens") && l.contains("·") && (l.contains("thinking") || l.contains("…") || l.contains("...")))
    }
    /// Everything a given worker has reported, newest last.
    func output(for seat: String) -> [ChatLine] { chat.filter { $0.seat == seat } }
    /// True while c1 owes us an answer — but only for as long as that is
    /// plausible. A reply lands in c1's tmux pane, and only CyberPong's own
    /// sync promotes it into a card; with its panel closed nothing ever arrives,
    /// so an untimed spinner would run until the heat death of the session.
    var chiefThinking: Bool {
        if conductor?.paneActive == true || conductor?.busy == true { return true }
        guard let last = chiefChat.last, last.kind != "from_orch" else { return false }
        return Date().timeIntervalSince1970 - last.ts < 90
    }
    /// The tail of c1's own pane, so the island can show the answer even when
    /// CyberPong is not running to sync it.
    var chiefTail: String = ""
    var error: String?

    var working: [Seat] { seats.filter(\.busy) }
    /// Busy for a long time with no job is the shape of stuck, not of work.
    var stuck: [Seat] {
        seats.filter { $0.deliveryBusy && ($0.reason.contains("stale") || $0.busyMinutes > 20) }
    }
    var idle: [Seat] { seats.filter { !$0.busy } }
    var needsYou: Int { approvals.count + gates.count + asks.count + attention.count }
    /// Across every team: what the header says ("2 need you · 1 working").
    var needsYouAll: Int { teams.reduce(0) { $0 + $1.needsYou } }
    /// Graphs at work, on every team: the number the app's Needs you strip shows. One waiting on the
    /// person is already counted under "need you", and a paused one isn't working.
    var workingAll: Int { graphsRunning.filter(\.working).count }
    /// Graphs held by a pause, on every team ("‖ 1 paused" in the app).
    var pausedAll: Int { graphsRunning.filter(\.paused).count }
    /// The graph lines in the order the panel lists them: at work or waiting first, paused last.
    var graphLines: [GraphLine] { graphsRunning.filter { !$0.paused } + graphsRunning.filter(\.paused) }

    /// Seats a loop may hang under: the conductor plus parentless, permanent
    /// workers. The same rule the loop picker has always used, read off this
    /// island's own snapshot rather than the pairs DB.
    ///
    /// A child seat is excluded because a loop under it would put disposable
    /// seats two levels down from a main, and an ephemeral seat is excluded
    /// because it IS a loop seat — offering it as an owner invites a loop
    /// under a loop, which the work graph has no story for.
    var orgMains: [Seat] {
        var out: [Seat] = []
        var seen = Set<String>()
        if let c = conductor { out.append(c); seen.insert(c.id) }
        for s in seats where !seen.contains(s.id) {
            guard s.parentId.isEmpty, !s.ephemeral, !s.id.isEmpty else { continue }
            out.append(s); seen.insert(s.id)
        }
        return out
    }
}

/// One work-graph loop, as `pong goal status` reports it.
///
/// Cancelled graphs are carried, not filtered out. Stop leaves a graph behind
/// as history and Delete is what forgets it, so a list of only live loops
/// would hide exactly the leftovers Delete exists to clear.
struct LoopGraph: Identifiable, Hashable {
    let id: String, kind: String, owner: String, status: String
    let nodes: Int
    var live: Bool { status == "running" }
}

/// One node of a loop and who will run it, as `pong wire plan --json` says.
///
/// `rejected` is the other half of the answer — one line per platform that was
/// not chosen — and rides on the tooltip. `conflict` is non-empty when a pin
/// was refused or nothing installed can take the node; the row turns amber.
struct WiringRow: Identifiable, Hashable {
    let id: String
    let role: String, runtime: String, model: String, why: String
    let rejected: [String]
    let conflict: String
}

/// Link chips that wrap onto as many rows as they need.
///
/// A plain HStack would push chips off the right edge, and an x you cannot
/// reach is a link you cannot remove. Rows are packed on a measured width
/// rather than a guessed chip count, so a long URL takes a row of its own
/// instead of silently pushing its neighbour out of view.
struct LinkChipFlow: View {
    let links: [String]
    let remove: (String) -> Void

    /// Shown on the chip: host plus the last path piece is enough to tell two
    /// links apart, and the whole URL is on the tooltip.
    private func short(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let tail = u.lastPathComponent
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return tail.isEmpty || tail == "/" ? clean : "\(clean)/\(tail)"
    }

    private func rows(width: CGFloat) -> [[String]] {
        var out: [[String]] = [[]]
        var used: CGFloat = 0
        for url in links {
            // ~6pt per character plus the x and the padding. An estimate, but
            // it only decides where a row breaks, and it errs toward breaking
            // early rather than overflowing.
            let w = min(width, CGFloat(short(url).count) * 6 + 34)
            if used + w > width, !(out[out.count - 1].isEmpty) {
                out.append([]); used = 0
            }
            out[out.count - 1].append(url)
            used += w + 5
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows(width: geo.size.width).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        ForEach(row, id: \.self) { url in
                            HStack(spacing: 4) {
                                Text(short(url))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Ink.second).lineLimit(1)
                                Button { remove(url) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Ink.dim)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Ink.chip))
                            .help(url)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(height: 22 * CGFloat(min(3, max(1, (links.count + 2) / 3))))
    }
}

/// The pure part of starting a loop: who leads a picked set, and the argv that
/// says so.
///
/// Free functions in their own enum, with no SwiftUI, no `Store` and no AppKit
/// around them, so `tests/swift/run-loop-args.sh` can slice this block out and
/// compile it on its own. The Who row can only be checked by eye; the mapping
/// from what is lit to what `pong goal start` is handed is the part that has to
/// be right, and this is the part a stranger can run.
enum LoopArgs {
    /// Which picked seat gets `--owner`; the rest get `--with`.
    ///
    /// The conductor when they are in the set — a loop that includes the chief
    /// but hangs under one of their reports would put the chief inside their
    /// own report's loop — otherwise whoever was picked first. Written once,
    /// here, because the Who caption and the argv both have to answer it, and
    /// two copies of a rule is how they come to disagree.
    static func lead(picked: [String], conductor: String) -> String {
        if !conductor.isEmpty, picked.contains(conductor) { return conductor }
        return picked.first ?? ""
    }

    /// How many seat chips fit on each row, at a given width.
    ///
    /// ~6pt per character plus the chip padding. An estimate, like the one in
    /// `LinkChipFlow`, and it errs toward breaking a row early rather than
    /// overflowing the panel. It lives here rather than in the view so the
    /// harness can check that a real roster fits the fixed height the panel
    /// gives it: the Who row cannot grow, so a roster that needs one more row
    /// than it has is a seat a human cannot see.
    ///
    /// `Double` rather than `CGFloat` because nothing in this enum imports a
    /// graphics framework, and this is arithmetic, not drawing.
    static func chipRows(_ titles: [String], width: Double) -> [Int] {
        var out: [Int] = [0]
        var used: Double = 0
        for t in titles {
            let w = min(width, Double(t.count) * 6 + 22)
            if used + w > width, out[out.count - 1] > 0 { out.append(0); used = 0 }
            out[out.count - 1] += 1
            used += w + 5
        }
        return out
    }

    /// What `chipRows` needs to draw without clipping.
    static func chipHeight(_ titles: [String], width: Double,
                           rowHeight: Double, rowGap: Double) -> Double {
        let n = Double(max(1, chipRows(titles, width: width).count))
        return n * rowHeight + (n - 1) * rowGap
    }

    /// The argv for `pong goal start`, from a picked set.
    ///
    /// One seat is `--owner wN` and no `--with` at all — the spelling every
    /// loop used before the Who row existed, so a single-agent loop is byte
    /// for byte what it always was. Several seats add `--with`, comma
    /// separated, lead excluded because it is already `--owner`.
    static func goalStart(session: String, kind: String, picked: [String],
                          conductor: String, task: String,
                          pieces: Int, fanCap: Int, maxRounds: Int,
                          bar: String?, links: [String]) -> [String] {
        let owner = lead(picked: picked, conductor: conductor)
        let rest = picked.filter { $0 != owner }
        var args = ["-s", session, "goal", "start",
                    "--owner", owner, "--loop", kind, "--task", task]
        if !rest.isEmpty { args += ["--with", rest.joined(separator: ",")] }
        switch kind {
        case "fan":      args += ["--pieces", String(max(1, min(pieces, fanCap)))]
        case "cycle":    args += ["--max-rounds", String(max(1, maxRounds))]
        case "gauntlet":
            if let b = bar, !b.isEmpty { args += ["--bar", b] }
        default: break
        }
        // One --example per chip. The repeatable spelling rather than the
        // comma list, so a URL that happens to contain a comma cannot be split
        // in half on its way to the engine.
        for url in links { args += ["--example", url] }
        return args
    }
}

/// Who a loop runs on: every org main as a chip you tap to include.
///
/// Wraps rather than scrolling sideways, for the same reason `LinkChipFlow`
/// does — a chip you cannot see is a seat you cannot pick. It does not own the
/// selection: order is the caller's, because the first seat picked is the loop
/// owner and an order this view invented would change who leads.
///
/// The width is passed in rather than read from a `GeometryReader`. The island
/// body is a fixed `Store.bodyWidth`, and a reader inside the scroll view that
/// holds this would have to answer before it had a height — the packing does
/// not need to be measured, it needs to be right.
struct WhoChipFlow: View {
    let mains: [Seat]
    let picked: [String]
    let width: CGFloat
    let toggle: (String) -> Void

    /// Label first, id second. A chip that reads `w16` alone asks a human to
    /// remember the roster; `Engineering — CyberPong · w16` does not.
    static func title(_ s: Seat) -> String {
        s.label.isEmpty ? s.id : "\(s.label) · \(s.id)"
    }

    static let rowHeight: CGFloat = 21
    static let rowGap: CGFloat = 5

    /// The packing is `LoopArgs.chipRows` — one implementation, so what the
    /// harness measures is what the panel draws. All this does is cut the
    /// roster on the row lengths it hands back.
    static func rows(_ mains: [Seat], width: CGFloat) -> [[Seat]] {
        var out: [[Seat]] = []
        var i = 0
        for n in LoopArgs.chipRows(mains.map(title), width: Double(width)) where n > 0 {
            out.append(Array(mains[i ..< min(i + n, mains.count)]))
            i += n
        }
        return out.isEmpty ? [[]] : out
    }

    static func height(_ mains: [Seat], width: CGFloat) -> CGFloat {
        CGFloat(LoopArgs.chipHeight(mains.map(title), width: Double(width),
                                    rowHeight: Double(rowHeight),
                                    rowGap: Double(rowGap)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WhoChipFlow.rowGap) {
            ForEach(Array(WhoChipFlow.rows(mains, width: width).enumerated()),
                    id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { m in
                        let on = picked.contains(m.id)
                        Button { toggle(m.id) } label: {
                            Text(WhoChipFlow.title(m))
                                .font(.system(size: 11,
                                              weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Ink.bg : Ink.second)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(on ? Ink.violet : Ink.chip))
                        }
                        .buttonStyle(.plain)
                        .help(on ? "Tap to drop \(m.id)" : "Tap to include \(m.id)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// One candidate reference from `pong examples search --json`.
///
/// Only ever built by decoding that array. Nothing in this file constructs a
/// URL: if the search returns nothing the list is empty and stays empty, which
/// is the same discipline the engine keeps when no source answers.
struct ExampleRow: Identifiable, Hashable {
    let id: String, title: String, url: String, host: String
}

// MARK: - pong ------------------------------------------------------------

/// What the island checks before running the engine, and how it words a refusal: the same rules as the
/// app's EngineCheck and Words.engineSentence (tests/swift/questions checks they agree).
enum PongCheck {
    /// What a `pong` call says when no usable Python is on this Mac (the app's own sentence).
    static let noPythonMessage = "Python isn't installed yet: install Apple's command line tools (Help › Set up CyberPong…)."

    /// A launcher that ends in a bare `exec python3 …` (the app's ~/bin/pong, install-control-plane's,
    /// the repo's scripts/pong) runs Apple's stub when no other Python is there; one that names its own
    /// interpreter does not. A Python script whose first line is `#!/usr/bin/env python3` (or Apple's
    /// /usr/bin/python3) reaches the stub the same way.
    static func launchesPathPython(_ script: String) -> Bool {
        let bare: (String) -> Bool = { $0 == "python3" || $0 == "python" || $0 == "/usr/bin/python3" }
        for (n, raw) in script.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if n == 0, line.hasPrefix("#!") {
                let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    .filter { $0 != "/usr/bin/env" && $0 != "-S" }
                if let cmd = words.first, bare(cmd) { return true }
            }
            guard !line.hasPrefix("#") else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let i = words.firstIndex(of: "exec") else { continue }
            // `exec python3 …` or `exec /usr/bin/env python3 …`
            let rest = words.dropFirst(i + 1).filter { $0 != "/usr/bin/env" && $0 != "env" }
            if let cmd = rest.first, bare(cmd) { return true }
        }
        return false
    }

    /// The engine's own words for a failure, when they already read as a sentence a person can use: a
    /// JSON reply's `error` or `note`, else the text after its last "error:", else its only line. A
    /// capital first, a stop at the end, and no ids, flags, paths, brackets or exception names.
    static func sentence(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var s: String
        if t.hasPrefix("{"), let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] {
            s = ((o["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (o["note"] as? String) ?? "")
        } else {
            let lines = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let e = lines.last(where: { $0.contains("error:") }), let r = e.range(of: "error:", options: .backwards) {
                s = String(e[r.upperBound...])
            } else if lines.count == 1 {
                s = lines[0]
            } else {
                return nil
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 8, s.count <= 240, let first = s.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
              let last = s.last, ".!?".contains(last) else { return nil }
        let jargon = #"[_/\\{}\[\]<>`=|$]|--|[A-Za-z]*(Error|Exception)\b|Errno|Traceback"#
        return s.range(of: jargon, options: .regularExpression) == nil ? s : nil
    }

    /// An answer the engine refused for a reason "try again" doesn't fix, in plain words: the question's
    /// rounds are spent (`moreRounds`: one more round can be allowed, then the answer goes), or it isn't
    /// open any more (answered elsewhere, or its graph ended). nil: any other refusal. The app's
    /// QuestionWords.answerRefusal says the same.
    static func answerRefusal(_ said: String) -> (words: String, moreRounds: Bool)? {
        if said.contains("--extend") || said.contains("one more round") {
            return ("Its rounds are spent: allow one more round to send your answer.", true)
        }
        if ["is not an open gate", "nothing to resume", "no question ", " is already "].contains(where: { said.contains($0) }) {
            return ("This question isn't open any more, so your answer wasn't sent.", false)
        }
        return nil
    }
}

enum Pong {
    /// The `pong` command, ready for bash: ~/bin/pong when it is installed. An app-only install has
    /// no launcher yet, so the engine CyberPong seeded into ~/.pong/lib runs through python3 instead.
    /// With no real Python, a plain line on stderr and a failure: Apple's /usr/bin/python3 without the
    /// command line tools is a stub that asks to install them, and the island polls every few seconds.
    static var command: String {
        let h = NSHomeDirectory()
        let fm = FileManager.default
        let noPython = "printf '%s\\n' " + quote(PongCheck.noPythonMessage) + " >&2; false"
        var c = [h + "/bin/pong"]
        #if DEBUG
        // a development checkout, in a debug build only: the scripts/pong of the tree this file was
        // built from. Release builds leave it out, so no local path ships in the binary.
        c.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("scripts/pong").path)
        #endif
        if let b = c.first(where: { fm.isExecutableFile(atPath: $0) }) {
            // a launcher that runs whatever python3 is on PATH would reach the stub; one that names its
            // own interpreter still runs
            if python == nil, launcherRunsPathPython(b) { return noPython }
            return quote(b)
        }
        guard let py = python else { return noPython }
        guard fm.fileExists(atPath: h + "/.pong/lib/pong/cli/main.py") else {
            return "printf '%s\\n' 'The CyberPong engine is not set up on this Mac yet.' >&2; false"
        }
        return "export PATH=\"$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; PYTHONPATH="
            + quote(h + "/.pong/lib") + "\"${PYTHONPATH:+:$PYTHONPATH}\" " + quote(py) + " -m pong.cli.main"
    }

    /// A Python 3 that runs: Homebrew's first; Apple's /usr/bin/python3 only when the command line
    /// tools (or Xcode) are there to back it. nil: none.
    static var python: String? {
        let fm = FileManager.default
        for c in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where fm.isExecutableFile(atPath: c) { return c }
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                     "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        if tools.contains(where: { fm.isExecutableFile(atPath: $0) }), fm.isExecutableFile(atPath: "/usr/bin/python3") {
            return "/usr/bin/python3"
        }
        return nil
    }

    /// Whether the `pong` at `path` (a link is followed) runs whatever python3 is on PATH. A launcher is a
    /// few lines; a large file is a real program that found its own interpreter.
    static func launcherRunsPathPython(_ path: String) -> Bool {
        let real = (path as NSString).resolvingSymlinksInPath
        let size = ((try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? NSNumber)?.intValue ?? -1
        guard size >= 0, size < 16_384, let text = try? String(contentsOfFile: real, encoding: .utf8) else { return false }
        return PongCheck.launchesPathPython(text)
    }

    /// One word for bash, whatever it holds.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// What the AIs call the person (settings.json "owner_name"); "the person" until it is set.
    /// One line, at most 60 characters.
    static var ownerName: String {
        let path = NSHomeDirectory() + "/.pong/settings.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let raw = o["owner_name"] as? String
        else { return "the person" }
        let n = String(raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(60))
        return n.isEmpty ? "the person" : n
    }

    @discardableResult
    static func run(_ args: [String]) -> (out: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let cmd = ([command] + args.map(quote)).joined(separator: " ")
        p.arguments = ["-lc", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return ("", false) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: d, encoding: .utf8) ?? "", p.terminationStatus == 0)
    }

    /// Same as `run`, but keeps stderr.
    ///
    /// `run` discards stderr on purpose — its callers parse stdout as JSON and
    /// a stray warning would corrupt that. But `pong` prints its refusals to
    /// stderr ("error: gauntlet requires --bar PATH …", "cross-session write
    /// to '…' refused"), so a caller that wants to SHOW the reason gets an
    /// empty string from `run` and has to invent wording for a failure the
    /// control plane already explained. The loop actions want the real
    /// sentence, so they use this and nothing else changes.
    @discardableResult
    static func runShowingErrors(_ args: [String], clean: Bool = false) -> (out: String, err: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let cmd = ([command] + args.map(quote)).joined(separator: " ")
        p.arguments = ["-lc", cmd]
        if clean {
            // no inherited seat or team identity: `-s` alone names the team
            var env = ProcessInfo.processInfo.environment
            for k in ["PONG_SEAT", "PONG_SESSION", "HERMES_PONG_SESSION", "PONG_TOKEN", "PONG_SESSION_TOKEN"] {
                env.removeValue(forKey: k)
            }
            p.environment = env
        }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return ("", "could not run pong", false) }
        let o = outPipe.fileHandleForReading.readDataToEndOfFile()
        let e = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: o, encoding: .utf8) ?? "",
                String(data: e, encoding: .utf8) ?? "",
                p.terminationStatus == 0)
    }

    /// Ask CyberPong to bring a seat's Terminal forward.
    ///
    /// CyberPong already owns the open-or-raise path (`Pairing.frontWorker`),
    /// which raises the existing window when the seat already has one and only
    /// re-attaches when it does not — so clicking twice never leaves two copies.
    /// It also already holds the Automation permission for Terminal; the island
    /// does not, and asking for it on a click would put a TCC prompt in front of
    /// someone who just wanted to see a pane. So the island states the intent
    /// and lets the app that is allowed to do it, do it.
    static func frontSeat(seat: String, session: String) {
        guard !seat.isEmpty, !session.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.owi.cyberpong.frontSeat"),
            object: nil,
            userInfo: ["session": session, "seat": seat],
            deliverImmediately: true)
    }

    /// Where CyberPong keeps a live snapshot. Reading it costs ~1ms.
    static var cachePath: String { NSHomeDirectory() + "/.pong/snapshot.json" }

    /// Shelling out costs ~480ms of bash + python + a scan of every session.
    /// At a 2.5s poll that is roughly a fifth of a core, permanently, to render
    /// a status dot. CyberPong already maintains ~/.pong/snapshot.json, so read
    /// that when it is fresh and only pay for the CLI when it is not — which
    /// also keeps the island working when CyberPong is not running.
    static func rawSnapshot() -> [String: Any]? {
        let url = URL(fileURLWithPath: cachePath)
        if let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let gen = root["generated_at"] as? Double,
           // 90s, not 15. CyberPong refreshes this file on its own cadence,
           // which sits right around 15 — so a 15s threshold meant the island
           // fell back to the 0.48s CLI on nearly every poll and burned ~9% of
           // a core reading data it already had.
           Date().timeIntervalSince1970 - gen < 90 {
            return root
        }
        let (out, ok) = run(["snapshot"])
        guard ok, let d = out.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func snapshot(preferred: String?, wantTail: Bool = false) -> Island {
        var isl = Island()
        guard let root = rawSnapshot() else {
            isl.error = "pong snapshot did not answer"; return isl
        }
        isl.bridgeOn = (root["bridge_on"] as? Bool) ?? false
        let bound = (root["bound_session"] as? String) ?? ""
        let teams = (root["teams"] as? [[String: Any]]) ?? []

        func seats(_ t: [String: Any]) -> (Seat?, [Seat]) {
            let status = (t["seat_status"] as? [String: Any]) ?? [:]
            func chip(from rec: [String: Any]) -> String {
                let u = rec["usage"] as? [String: Any]
                let c = ((u?["chip"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return c.count <= 12 ? c : ""
            }
            func mk(_ id: String, _ label: String, _ type: String,
                    hint: String = "", paneActive: Bool = false,
                    usageChip: String = "") -> Seat {
                let r = status[id] as? [String: Any]
                var s = Seat(id: id, label: label, type: type,
                             state: (r?["state"] as? String) ?? "available",
                             reason: (r?["reason"] as? String) ?? "",
                             role: "",
                             busyMinutes: {
                                 guard let u = r?["updated_at"] as? Double else { return 0 }
                                 return (Date().timeIntervalSince1970 - u) / 60
                             }())
                s.hint = hint
                s.paneActive = paneActive
                s.usageChip = usageChip
                return s
            }
            var cond: Seat?
            if let c = t["conductor"] as? [String: Any] {
                cond = mk((c["id"] as? String) ?? "c1",
                          (c["label"] as? String) ?? "Conductor",
                          (c["type"] as? String) ?? "",
                          hint: (c["status_hint"] as? String) ?? "",
                          paneActive: (c["pane_active"] as? Bool) ?? false,
                          usageChip: chip(from: c))
            }
            let ws = ((t["workers"] as? [[String: Any]]) ?? []).map { w -> Seat in
                var seat = mk((w["id"] as? String) ?? "?", (w["label"] as? String) ?? "Worker",
                              (w["type"] as? String) ?? "",
                              hint: (w["status_hint"] as? String) ?? "",
                              paneActive: (w["pane_active"] as? Bool) ?? false,
                              usageChip: chip(from: w))
                seat.role = (w["mission_role"] as? String) ?? ""
                seat.parentId = ((w["parent_id"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                seat.ephemeral = (w["ephemeral"] as? Bool) ?? false
                return seat
            }
            return (cond, ws)
        }
        func approvals(_ t: [String: Any]) -> [Approval] {
            let jobs = (t["jobs"] as? [String: Any]) ?? [:]
            return ((jobs["open"] as? [[String: Any]]) ?? []).compactMap { j in
                let handed = (j["human_takeover"] as? Bool) ?? false
                    || (j["status"] as? String) == "human_takeover"
                guard handed, let id = j["id"] as? String else { return nil }
                return Approval(id: id, worker: (j["worker"] as? String) ?? "",
                                workerLabel: (j["worker_label"] as? String) ?? "",
                                round: (j["round"] as? Int) ?? 1,
                                preview: (j["task_preview"] as? String) ?? "")
            }
        }

        // Every team, so the picker can show where the work actually is.
        for t in teams {
            let s = (t["session"] as? String) ?? ""
            let disp = (t["display_name"] as? String) ?? ""
            let (_, ws) = seats(t)
            let (gs, att) = graphAsks(t, session: s, teamName: disp.isEmpty ? s : disp)
            isl.gates += gs
            isl.attention += att
            let qs: [AskItem] = ((t["asks"] as? [[String: Any]]) ?? []).compactMap { a in
                guard let id = a["id"] as? String, let q = a["question"] as? String, !q.isEmpty else { return nil }
                let opts = ((a["options"] as? [[String: Any]]) ?? []).map {
                    AskItem.Option(key: "\($0["key"] ?? "")", label: ($0["label"] as? String) ?? "", what: ($0["what"] as? String) ?? "")
                }
                return AskItem(id: id, session: s, teamName: disp.isEmpty ? s : disp, question: q,
                               context: (a["context"] as? [String]) ?? [], options: opts, files: (a["files"] as? [String]) ?? [],
                               detail: DetailPoint.parse(a["detail"]), detailBy: (a["detail_by"] as? String) ?? "",
                               detailPending: (a["detail_pending"] as? Bool) ?? false)
            }
            isl.asks += qs
            for g in ((t["work_graph"] as? [String: Any])?["graphs"] as? [[String: Any]]) ?? [] {
                if let line = GraphLine.from(g, session: s, teamName: disp.isEmpty ? s : disp) { isl.graphsRunning.append(line) }
            }
            isl.teams.append(TeamRef(id: s, name: disp.isEmpty ? s : disp,
                                     busy: ws.filter(\.busy).count,
                                     needsYou: approvals(t).count + gs.count + qs.count + att.count))
        }

        let want = preferred ?? bound
        guard let team = teams.first(where: { ($0["session"] as? String) == want })
                ?? teams.first(where: { ($0["session"] as? String) == bound })
                ?? teams.first else { return isl }

        isl.session = (team["session"] as? String) ?? ""
        let disp = (team["display_name"] as? String) ?? ""
        isl.teamName = disp.isEmpty ? isl.session : disp
        isl.queued = (team["waitroom_queued"] as? Int) ?? 0
        // Already composed and already shortened by the control plane — the ear
        // takes a tone and a string, and never reads prose to decide either.
        isl.tickerLines = ((team["ticker"] as? [[String: Any]]) ?? []).compactMap {
            let text = ($0["text"] as? String) ?? ""
            return text.isEmpty ? nil : (($0["tone"] as? String) ?? "purple", text)
        }
        (isl.conductor, isl.seats) = seats(team)
        if let w = team["weekly_usage"] as? [String: Any] {
            isl.weekly.model = (w["model"] as? String) ?? ""
            isl.weekly.available = (w["available"] as? Bool) ?? false
            isl.weekly.chip = (w["chip"] as? String) ?? ""
            isl.weekly.used = (w["used"] as? String) ?? ""
            isl.weekly.remaining = (w["remaining"] as? String) ?? ""
            isl.weekly.reset = (w["reset"] as? String) ?? ""
        }
        // One cheap look at the chief's pane. Snapshot can be up to 90s old,
        // which is how a live turn stayed invisible on the island.
        if !isl.session.isEmpty, let c = isl.conductor {
            let pane = Pong.shOut(
                "tmux capture-pane -p -J -t '\(isl.session):0' -S -16 2>/dev/null")
            if Pong.paneThinking(pane) {
                var live = c
                live.paneActive = true
                isl.conductor = live
            }
        }
        isl.approvals = approvals(team)
        // The actual conversation, from the same chat.jsonl CyberPong renders.
        // last-reply.txt is a different mechanism and never carried what c1
        // said back to you, which is why sends looked like they vanished.
        let chatPath = NSHomeDirectory() + "/.pong/human/\(isl.session)/chat.jsonl"
        if let raw = try? String(contentsOfFile: chatPath, encoding: .utf8) {
            let lines = raw.split(separator: "\n").suffix(40)
            isl.chat = lines.compactMap { line in
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let id = o["id"] as? String,
                      let txt = o["text"] as? String else { return nil }
                return ChatLine(id: id, kind: (o["kind"] as? String) ?? "",
                                text: txt, seat: (o["seat_id"] as? String) ?? "",
                                ts: (o["ts"] as? Double) ?? 0)
            }
        }

        // Read c1's pane directly. This is the same text you would see in the
        // terminal, and it is the only place a reply exists until CyberPong
        // syncs it into a card.
        // Only while you are looking. Capturing a pane spawns a process, and a
        // subprocess on every poll is exactly what cost 6% of a core last time.
        // Collapsed, the island needs no transcript.
        if !isl.session.isEmpty, wantTail {
            let out = Pong.shOut("tmux capture-pane -p -t '\(isl.session):0' 2>/dev/null | tail -14")
            let cleaned = out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("│") && !$0.hasPrefix("─") }
            isl.chiefTail = cleaned.suffix(6).joined(separator: "\n")
        }

        // What the agents last said, so you do not have to open a terminal to
        // find out whether anything happened.
        if let art = team["artifacts"] as? [String: Any],
           let path = art["last_reply"] as? String,
           let txt = try? String(contentsOfFile: path, encoding: .utf8) {
            isl.lastReply = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        isl.openJobs = (((team["jobs"] as? [String: Any])?["open"]) as? [[String: Any]])?.count ?? 0
        return isl
    }

    /// The gates and seat questions of one team's running graph loops, read off the
    /// snapshot as the control plane wrote them. Nothing here decides anything.
    static func graphAsks(_ t: [String: Any], session: String, teamName: String) -> ([GateItem], [AttentionItem]) {
        let graphs = ((t["work_graph"] as? [String: Any])?["graphs"] as? [[String: Any]]) ?? []
        var gates: [GateItem] = [], att: [AttentionItem] = []
        for g in graphs where (g["status"] as? String) == "running" {
            let gid = (g["id"] as? String) ?? ""
            let title = ((g["title"] as? String) ?? "").isEmpty ? gid : ((g["title"] as? String) ?? gid)
            let nodes = (g["nodes"] as? [[String: Any]]) ?? []
            for gate in (g["gates"] as? [[String: Any]]) ?? [] {
                let node = (gate["node"] as? String) ?? ""
                guard !gid.isEmpty, !node.isEmpty else { continue }
                let from = (gate["from"] as? String) ?? ""
                let fromSeat = (nodes.first { ($0["id"] as? String) == from }?["seat"] as? String) ?? ""
                var grade = ""
                if let j = gate["jev"] as? [String: Any], !j.isEmpty {
                    let critic = (j["critic"] as? String) ?? ""
                    let jv = (j["jev_verdict"] as? String) ?? ((j["verdict"] as? String) ?? "")
                    var parts: [String] = []
                    if !critic.isEmpty { parts.append("Reviewer: \(critic)") }
                    if !jv.isEmpty { parts.append("Jev: \(jv == "uncertain" ? "unsure" : jv)") }
                    if let low = j["lowest"] as? String, !low.isEmpty,
                       let line = ((j["lines"] as? [[String: Any]]) ?? []).first(where: { ($0["id"] as? String) == low }),
                       let p = line["p_meets"] as? Double {
                        // the point by its words, not its number
                        let text = ((line["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = text.isEmpty ? low.replacingOccurrences(of: "_", with: " ").capitalized
                                                : (text.count > 70 ? String(text.prefix(69)) + "…" : text)
                        parts.append("Weakest: \(name) (\(Int((p * 100).rounded()))%)")
                    }
                    grade = parts.joined(separator: " · ")
                }
                var advice = ""
                if let a = gate["advice"] as? [String: Any] {
                    if (a["blind"] as? Bool) == true {
                        advice = "Jev's pick stays hidden until you answer (one question in five, to check it)."
                    } else if (a["pending"] as? Bool) == true {
                        advice = "Jev is reading it — you can answer now."
                    } else if let pick = a["pick"] as? String, !pick.isEmpty {
                        let p = (a["p"] as? Double).map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
                        advice = "Jev suggests: \(Store.answerWord(pick))\(p.isEmpty ? "" : p.replacingOccurrences(of: "%)", with: "% sure)"))"
                    }
                }
                let at = (gate["at"] as? Double) ?? 0
                gates.append(GateItem(
                    id: "\(gid):\(node):\(Int(at))", session: session, teamName: teamName, graphId: gid, title: title,
                    node: node, reason: (gate["reason"] as? String) ?? "",
                    // the snapshot cuts a gate's summary at 200 characters: say so
                    summary: {
                        let t = ((gate["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.count >= 195 ? t + "…" : t
                    }(),
                    options: (gate["options"] as? [String]) ?? ["approved", "rejected"],
                    routes: (gate["routes"] as? [String: [String]]) ?? [:],
                    // the engine's full paths first: a name relative to the project would not open
                    files: {
                        let full = ((gate["ask"] as? [String: Any])?["files"] as? [String]) ?? []
                        return full.isEmpty ? ((gate["artifacts"] as? [String]) ?? []) : full
                    }(),
                    notesPath: (g["notes_path"] as? String) ?? "",
                    seat: fromSeat.contains(".") ? fromSeat : "",
                    gradeLine: grade, adviceLine: advice,
                    question: ((gate["ask"] as? [String: Any])?["question"] as? String) ?? "",
                    context: ((gate["ask"] as? [String: Any])?["context"] as? [String]) ?? [],
                    choices: ((gate["ask"] as? [String: Any])?["choices"] as? [String: String]) ?? [:],
                    detail: DetailPoint.parse((gate["ask"] as? [String: Any])?["detail"]),
                    detailBy: ((gate["ask"] as? [String: Any])?["detail_by"] as? String) ?? "",
                    detailPending: ((gate["ask_pending"] as? Bool) ?? false)
                        || (((gate["ask"] as? [String: Any])?["detail_pending"] as? Bool) ?? false)))
            }
            for a in (g["attention"] as? [[String: Any]]) ?? [] {
                let node = (a["node"] as? String) ?? ""
                att.append(AttentionItem(id: gid + ":" + node, session: session, title: title, node: node,
                                         seat: (a["seat"] as? String) ?? "", what: (a["what"] as? String) ?? ""))
            }
        }
        return (gates, att)
    }

    /// Open a file a step wrote: a document in its app, anything else shown in Finder, never run.
    static func openWork(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let viewable: Set<String> = ["md", "markdown", "txt", "json", "csv", "tsv", "log", "yaml", "yml", "pdf",
                                     "png", "jpg", "jpeg", "gif", "svg", "webp"]
        if viewable.contains(url.pathExtension.lowercased()) && !FileManager.default.isExecutableFile(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func approve(_ a: Approval, _ s: String) {
        run(["-s", s, "ledger", "record", "--task-id", a.id, "--round", String(a.round),
             "--verdict", "accept", "--worker", a.worker])
        run(["-s", s, "job", "status", a.id, "done"])
    }
    static func deny(_ a: Approval, _ s: String, note: String) {
        var v = ["-s", s, "ledger", "record", "--task-id", a.id, "--round", String(a.round),
                 "--verdict", "reject", "--worker", a.worker]
        if !note.isEmpty { v += ["--evidence", note] }
        run(v); run(["-s", s, "job", "status", a.id, "rejected"])
    }
    /// Edit is never a silent overwrite — the correction is recorded, because the
    /// diff between what an agent wrote and what you accepted is the learning signal.
    static func edit(_ a: Approval, _ s: String, correction: String) {
        run(["-s", s, "ledger", "record", "--task-id", a.id, "--round", String(a.round),
             "--verdict", "escalate", "--worker", a.worker, "--evidence", correction])
        run(["-s", s, "job", "create", "--worker", a.worker,
             "--task", "Revise per \(ownerName)'s edit: \(correction)"])
        run(["-s", s, "job", "status", a.id, "done"])
    }
    /// Where dropped files are kept.
    ///
    /// A screenshot dragged off the macOS thumbnail lives in a temp path that
    /// the system deletes, often before an agent gets round to reading it. So
    /// the file is COPIED here first and the agent is given this path — the
    /// alternative is a message pointing at a file that no longer exists.
    static var dropDir: URL {
        let d = URL(fileURLWithPath: NSHomeDirectory() + "/.pong/island-drops")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func keep(_ src: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = dropDir.appendingPathComponent("\(stamp)-\(src.lastPathComponent)")
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch { return nil }
    }

    /// Send exactly the way CyberPong's own human box does.
    ///
    /// Talking to c1 is NOT a job — `job create --worker c1` is refused twice
    /// over: c1 is the conductor rather than a worker, and session writes need a
    /// PONG_TOKEN. What CyberPong's deliver() actually does is append to the
    /// human console log, write an outbox file agents can read, drop a card on
    /// the chat stream, and paste into the conductor's tmux pane. This does the
    /// same four things, so a message from the island is indistinguishable from
    /// one typed into the app.
    static func say(_ t: String, _ session: String, to _: String) {
        guard !session.isEmpty else { return }
        let home = NSHomeDirectory()
        let dir = "\(home)/.pong/human/\(session)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n—— YOU · \(stamp) ——\n"
        let body = header + t + "\n"

        // 1. console log
        let logPath = dir + "/console.log"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(Data(body.utf8)); try? h.close()
        } else {
            try? body.write(toFile: logPath, atomically: true, encoding: .utf8)
        }

        // 2. outbox agents read
        try? body.write(toFile: dir + "/outbox.md", atomically: true, encoding: .utf8)

        // 3. cards, so it shows in CyberPong's stream like any other message
        card(dir: dir, kind: "from_you", text: t, seat: nil)
        card(dir: dir, kind: "status", text: "Sent from the island · waiting for update…", seat: "c1")

        // 4. paste into the conductor pane
        let tmp = NSTemporaryDirectory() + "pong-island-\(UUID().uuidString).txt"
        try? body.write(toFile: tmp, atomically: true, encoding: .utf8)
        let target = conductorTarget(session)
        let q = tmp.replacingOccurrences(of: "'", with: "'\\''")
        _ = sh("""
            tmux load-buffer -b pong-island '\(q)' 2>/dev/null && \
            tmux paste-buffer -b pong-island -t '\(target)' 2>/dev/null && \
            sleep 0.15 && tmux send-keys -t '\(target)' Enter 2>/dev/null && \
            sleep 0.1 && tmux send-keys -t '\(target)' Enter 2>/dev/null
        """)
        try? FileManager.default.removeItem(atPath: tmp)
        Store.log("sent to \(target): \(t.prefix(48))")
    }

    /// Registered c1 pane if there is one, else window 0 of the session.
    private static func conductorTarget(_ session: String) -> String {
        let path = NSHomeDirectory() + "/.pong/pairs.json"
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let db = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let entry = db[session] as? [String: Any],
           let cond = entry["conductor"] as? [String: Any],
           let pid = cond["pane_id"] as? String, !pid.isEmpty {
            return pid
        }
        return "\(session):0"
    }

    private static func card(dir: String, kind: String, text: String, seat: String?) {
        var obj: [String: Any] = [
            "id": "m-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))",
            "ts": Date().timeIntervalSince1970,
            "text": text, "kind": kind,
        ]
        if let seat { obj["seat_id"] = seat }
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        let path = dir + "/chat.jsonl"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Read-only shell, for capturing a pane.
    static func shOut(_ cmd: String) -> String { sh(cmd) }

    /// Same tests as pong.pane_activity.is_thinking — a mid-turn pane, not a
    /// clock redraw or a leftover "Crunched for 2m".
    static func paneThinking(_ pane: String) -> Bool {
        if pane.range(of: #"\[stop\]"#, options: .regularExpression) != nil {
            return true
        }
        if pane.range(of: #"(?:ctrl\s*\+\s*c|esc)\s+to interrupt"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let claudeDone = pane.range(
            of: #"[✻✽]\s+\S.+\s+for\s+\d+"#,
            options: .regularExpression) != nil
        let past = pane.range(
            of: #"(?:crunched|cogitated|baked|cooked|worked|thought|churned)\s+for\s+"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        if claudeDone || past { return false }
        return pane.range(
            of: #"(?:[\u{2800}-\u{28FF}⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|[✶✻✽])\s+\S.+\d+(?:\.\d+)?s\b"#,
            options: .regularExpression) != nil
    }

    /// Raw shell, for the tmux paste. Everything else goes through the CLI.
    @discardableResult
    static func sh(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Wipe the last-reply file so the panel can be dismissed.
    static func clearChat(_ session: String) {
        guard !session.isEmpty else { return }
        try? "".write(toFile: NSHomeDirectory() + "/.pong/human/\(session)/chat.jsonl",
                      atomically: true, encoding: .utf8)
    }

    static func free(_ seat: String, _ s: String) {
        run(["-s", s, "seat", "available", "--seat", seat, "--reason", "island"])
    }
}

// MARK: - Notch ----------------------------------------------------------

/// Where the physical notch is, so the island can hide inside it.
///
/// The collapsed pill is sized to the notch and parked at the very top. On a
/// notched Mac it is invisible — the black cutout swallows it — and only the
/// status hairline peeks out below. On a Mac without a notch we fake one, so the
/// behaviour is identical rather than "different on some machines".
enum Notch {
    /// The screen that owns the menu bar. NOT NSScreen.main — that is the screen
    /// with the key window, and an accessory app that never takes key has none.
    static var host: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    /// How far past the notch the collapsed state reaches, per side.
    ///
    /// Sized to hug what is actually in there — the orb and its count — so the
    /// black sits an even margin around them on every side. At 74 the orb was
    /// stranded at one end of a long bar with a wide empty run beside it, which
    /// is what made the left margin disagree with the top and bottom.
    static let ear: CGFloat = 52
    /// As wide as an ear may grow to carry a ticker line.
    ///
    /// 132 is picked off the measurement, not by eye: the upstream cap is 16
    /// characters, and the widest 16 characters anyone actually writes are
    /// all-caps prose — "URGENT DEPLOY NO" is 104.7pt, "REVIEW BAR READY"
    /// 100.8pt. Minus the trailing wall and the cutout gap, 132 leaves 112.1pt
    /// usable, so those clear with room instead of the 1.4pt that 126 left.
    /// It caps the collapsed island at 449pt against a 504pt panel, so it still
    /// reads as a notch rather than as the whole sheet.
    static let maxEar: CGFloat = 132

    /// How far the ticker text sits in from the ear's outer edge.
    ///
    /// Measured, not guessed. IslandShape insets its body by `shoulder` on each
    /// side — the flare only reaches full width at the very top — so at the
    /// text's own vertical band the black stops 9.9pt in. Padded by the usual
    /// collapsedInset (6.5) the last glyph hung 3.4pt PAST that wall and the
    /// clip took half of it. The bottom corner curve turned out to be innocent:
    /// it starts below the text entirely. Shoulder plus 4 puts the line back
    /// inside the black with a margin you can see.
    static var tickerTrailing: CGFloat { shoulder + 4 }

    /// Clearance between the first glyph and the cutout on the ear's inner side.
    static let tickerLeading: CGFloat = 6

    /// Ear width for a given ticker line, applied to BOTH sides.
    ///
    /// Symmetry is not cosmetic here: the cutout is centred on screen, and the
    /// collapsed silhouette is centred on the window, so growing one ear alone
    /// would slide the black off the real notch. Both grow, the left simply
    /// carries more empty black, and the hole stays where the hardware put it.
    static func ear(forTicker text: String) -> CGFloat {
        guard !text.isEmpty else { return ear }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        // Size to the INNER usable width, not the outer box: whatever the ear
        // is, the text only ever gets it minus the trailing wall and the gap
        // from the cutout. The old `w + 18` measured against the outer box and
        // so promised room that the clip then took back.
        return min(maxEar, max(ear, w + tickerTrailing + tickerLeading))
    }

    static func width(_ screen: NSScreen) -> CGFloat {
        let full = screen.frame.width
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let w = full - left.width - right.width
            if w > 60, w < 400 { return w }        // sane notch, use it
        }
        return 190                                  // no notch: a believable stand-in
    }
    /// The notch's bottom corner radius.
    ///
    /// macOS publishes the notch's SIZE and nothing else: `safeAreaInsets.top`
    /// gives its height (33pt here) and the gap between `auxiliaryTopLeftArea`
    /// and `auxiliaryTopRightArea` gives its width (185pt here). There is no
    /// corner radius to read — `_cornerRadius`, `_notchCornerRadius`,
    /// `_displayCornerRadius` and `_notchRect` were each probed by KVC on this
    /// OS and every one of them raises.
    ///
    /// So rather than typing a number in points tuned against one screenshot,
    /// the radius is derived from the height that IS measurable, which keeps it
    /// proportionate on a 14", a 16" or an Air. The ratio is empirical: this is
    /// the one number here that was not read off the system, and it is the one
    /// to nudge if the corners read wrong against the real cutout.
    static var cornerRadius: CGFloat {
        let h = host?.safeAreaInsets.top ?? 33
        return max(6, min(14, h * 0.30))
    }

    /// How far the collapsed silhouette flares OUTWARD into the bezel at the top.
    ///
    /// The real cutout and the expanded island both curve outward where they
    /// meet the screen edge; a flat top read as a pill parked under the menu bar
    /// instead of as the notch itself. Scaled to the same measured height the
    /// bottom radius comes from, so the two corners belong to one another.
    static var shoulder: CGFloat { cornerRadius }
}

// MARK: - Look ------------------------------------------------------------

/// CyberPong's Night tokens (design-language.md §2), shared with the app: one colour, one job.
/// Amber = needs you, cyan = machines at work and links, magenta = the architect, red = failed.
enum Ink {
    static let bg      = Color(hex: "000000")          // meets the notch: the one exception
    static let raised  = Color(hex: "121821")
    static let chip    = Color(hex: "1A212C")
    static let hair    = Color(hex: "ECE7DC").opacity(0.08)
    static let text    = Color(hex: "ECE7DC")
    static let second  = Color(hex: "AAB2BE")
    static let dim     = Color(hex: "8C96A5")
    static let ink     = Color(hex: "ECE7DC")          // the primary button
    static let onInk   = Color(hex: "0B0F14")
    static let tintYou = Color(hex: "221915")          // the question card
    static let teal    = Color(hex: "4CD6E0")          // working (was green-teal)
    static let amber   = Color(hex: "F5A524")          // needs you, only
    static let violet  = Color(hex: "AAB2BE")          // retired: neutral
    static let purple  = Color(hex: "8C96A5")          // retired: neutral
    static let green   = Color(hex: "4CD6E0")          // working
    static let orange  = Color(hex: "F5A524")
    static let red     = Color(hex: "FF7A6E")          // failed, destructive
    static let blue    = Color(hex: "4CD6E0")          // links
    static let magenta = Color(hex: "FF6EC7")          // the architect
}

extension Color {
    /// Lets a status colour be written once, as the hex the orb canvas is
    /// tinted with, and still paint SwiftUI text. Anything unparseable comes
    /// back black rather than trapping — a wrong colour is not worth a crash.
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >>  8) & 0xFF) / 255,
                  blue:  Double( v        & 0xFF) / 255)
    }
}

/// What a seat is DOING, not just whether it is busy.
///
/// Thinking Orbs ships nine hand-tuned types; these are the six that map onto
/// work this team actually does. The motion is the message — you should be able
/// to tell research from writing across the room, with the colour ignored.
enum Status {
    case idle          // breathing   — nothing happening
    case searching     // scan sweep  — reading the outside world
    case solving       // scramble    — code, migrations, hard problems
    case delegating    // constellation — routing work to someone else
    case composing     // sash roll   — writing something a human will read
    case working       // orbits      — generic work with no better label
    case listening     // waveform    — waiting on input from outside
    case weaving       // plaited     — assembling something from parts
    case shaping       // morphing    — drafting, form not settled yet
    case needsYou      // knock       — waiting on a person
    case stuck         // scatter     — busy far too long

    /// The five things an orb is ever actually saying.
    ///
    /// Motion and colour are picked together, once, here. The ear, the seat rows
    /// and the expanded list all read this one table, which is the only reason
    /// they cannot drift apart again — the previous split had three separate
    /// switches and they disagreed with each other on all three of stall, chief
    /// and research.
    enum Motion {
        case idle, thinking, coding, research, stall, needsYou

        /// thinking-orbs OrbState names, spelled exactly as their engine keys
        /// them in STATE_TO_MODE. Anything else resolves to undefined and throws.
        var state: String {
            switch self {
            case .idle:     return "composing"    // ribbon — resting
            case .thinking: return "breathing"    // ring   — busy, thinking
            case .coding:   return "shaping"      // morph  — a coder at work
            case .research: return "listening"    // wave   — reading the world
            case .stall:    return "connecting"   // web    — busy far too long
            case .needsYou: return "breathing"    // ring   — waiting on a person
            }
        }
        /// The single definition of a status colour: the canvas is tinted with
        /// this and the label beside it is painted from the same string, so the
        /// two can never disagree.
        var hex: String {
            switch self {
            case .idle:     return "8C96A5"       // grey   — resting
            case .stall:    return "FF7A6E"       // red    — stalled
            case .needsYou: return "F5A524"       // amber  — wants a person
            default:        return "4CD6E0"       // cyan   — working
            }
        }
        var color: Color { Color(hex: hex) }
    }

    /// Which of the five a case means. Coding and research earn their own
    /// motion; everything else that is busy — orchestrating, operating,
    /// reviewing, running a task, plain work — is the team thinking.
    var motion: Motion {
        switch self {
        case .idle:     return .idle
        case .solving:  return .coding
        case .searching: return .research
        case .stuck:    return .stall
        case .needsYou: return .needsYou
        default:        return .thinking
        }
    }
    var orbState: String { motion.state }
    var hex: String { motion.hex }
    var color: Color { motion.color }

    var verb: String {
        switch self {
        case .idle: return "quiet"
        case .searching: return "researching"
        case .solving: return "solving"
        case .delegating: return "delegating"
        case .composing: return "writing"
        case .working: return "working"
        case .listening: return "listening"
        case .weaving: return "assembling"
        case .shaping: return "drafting"
        case .needsYou: return "waiting on you"
        case .stuck: return "stuck"
        }
    }

    /// A seat's role says more about what its motion should be than its
    /// busy flag does.
    /// The case here only has to pick the right *verb* for the row; the motion
    /// and colour come from `motion` above. Reviewer used to land on .searching,
    /// which reads as research — a reviewer is thinking, not reading the world.
    static func forRole(_ role: String) -> Status {
        switch role {
        case "researcher":   return .searching   // research → listening
        case "coder":        return .solving     // coding   → shaping
        case "orchestrator": return .delegating  // thinking → breathing
        case "operator":     return .composing   // thinking → breathing
        case "reviewer":     return .working     // thinking → breathing
        case "task_runner":  return .shaping     // thinking → breathing
        default:             return .working     // thinking → breathing
        }
    }

    /// The one place a seat turns into an orb.
    ///
    /// Stall outranks the role: a seat busy this long has stopped telling you
    /// what it does and started telling you it is wedged. The test is the same
    /// one Island.stuck uses, so the red orb and the stuck list always agree.
    static func forSeat(_ s: Seat) -> Status {
        guard s.busy else { return .idle }
        // Stuck is a held job that went quiet — not a chief mid-turn.
        if s.deliveryBusy && (s.reason.contains("stale") || s.busyMinutes > 20) {
            return .stuck
        }
        return forRole(s.role)
    }
}


/// Ported from thinking-orbs' own PRESETS table — the inline (20px) column,
/// which is the size we actually draw at. Hand-tuning these was the mistake:
/// the real numbers say small orbs want FEWER, BIGGER dots.
struct OrbMode {
    enum Kind { case globe, rubik, wave, web, braid, ring, ribbon, morph, scatter, knock }
    let kind: Kind, speed: Double, count: Double, size: Double
}

extension Status {
    var mode: OrbMode {
        switch self {
        case .idle:       return OrbMode(kind: .ring,    speed: 3.78,  count: 0.028, size: 1.622)
        case .searching:  return OrbMode(kind: .globe,   speed: 2.665, count: 0.105, size: 1.75)
        case .solving:    return OrbMode(kind: .rubik,   speed: 1.95,  count: 0.088, size: 1.9)
        case .delegating: return OrbMode(kind: .web,     speed: 6.63,  count: 0.25,  size: 1.52)   // connecting
        case .composing:  return OrbMode(kind: .ribbon,  speed: 3.12,  count: 0.051, size: 1.073)  // their ribbon
        case .listening:  return OrbMode(kind: .wave,    speed: 3.998, count: 0.105, size: 1.6)
        case .weaving:    return OrbMode(kind: .braid,   speed: 2.75,  count: 0.1125, size: 1.36)
        case .shaping:    return OrbMode(kind: .morph,   speed: 2.08,  count: 0.53,  size: 1.011)  // their morph
        case .working:    return OrbMode(kind: .globe,   speed: 3.9,   count: 0.105, size: 1.75)
        case .needsYou:   return OrbMode(kind: .knock,   speed: 3.12,  count: 0.051, size: 1.9)
        case .stuck:      return OrbMode(kind: .scatter, speed: 3.24,  count: 0.088, size: 1.6)
        }
    }
}


/// Their engine, run rather than reimplemented.
///
/// thinking-orbs is canvas/JS, so the honest way to "use theirs" is to host it.
/// `MODE_DRAWS` is a vanilla (ctx, size, t, dark, opts) map — no React — so a
/// tiny transparent WebView per orb runs the real geometry, and a source-atop
/// fill tints it to our palette while keeping their alpha and depth fade.
///
/// Used for the Chief. The ported Swift orbs stay for the other seats: 24 of
/// these would be 24 web processes, which is not a trade worth making for a
/// status dot.
/// Serves the bundled orb page to the web views over a scheme of our own.
///
/// orb.html is an ES module and it imports the engine as a sibling file. A
/// module fetched over file:// is treated as cross-origin by WebKit and refused
/// before its first statement runs — so the canvas was never even sized, let
/// alone painted, and every orb was an empty page. Giving the page a real,
/// stable origin makes the import resolve the way it does in their playground.
///
/// The alternative was switching on blanket file access for the web view, which
/// is a private setting and a wider grant than one bundled page needs. This is
/// public API, serves nothing outside web/, and drops loadFileURL — which
/// raises rather than fails when it dislikes a URL — out of the path entirely.
final class OrbScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "pongorb"
    static let shared = OrbScheme()

    /// The bundled web/ directory, resolved absolute. Bundle.main.resourceURL is
    /// a *relative* URL carried against the bundle, and leaving it that way is
    /// how the orb path broke before.
    private let root = Bundle.main.resourceURL?
        .appendingPathComponent("web").absoluteURL.standardizedFileURL

    static func url(state: String, size: CGFloat, hex: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "orb"
        c.path = "/orb.html"
        c.queryItems = [.init(name: "state", value: state),
                        .init(name: "size", value: String(Int(size))),
                        .init(name: "color", value: hex)]
        return c.url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let root, let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = root.appendingPathComponent(rel).standardizedFileURL
        // Anything that resolves outside web/ is refused rather than served.
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime: String
        switch file.pathExtension {
        case "html": mime = "text/html"
        case "js":   mime = "text/javascript"   // a module is refused without this
        default:     mime = "application/octet-stream"
        }
        task.didReceive(URLResponse(url: url, mimeType: mime,
                                    expectedContentLength: data.count,
                                    textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct WebOrb: NSViewRepresentable {
    let state: String        // their OrbState: composing, searching, solving…
    let size: CGFloat
    let hex: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Must be registered before the web view exists.
        cfg.setURLSchemeHandler(OrbScheme.shared, forURLScheme: OrbScheme.scheme)
        let v = WKWebView(frame: .zero, configuration: cfg)
        // Public API only. underPageBackgroundColor is macOS 12+, and the
        // layer keeps it transparent everywhere else.
        if #available(macOS 12.0, *) { v.underPageBackgroundColor = .clear }
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        v.allowsMagnification = false
        // The other half of the white square. WKWebView paints an opaque white
        // backdrop behind the page, and none of the above touches it:
        // underPageBackgroundColor only covers the over-scroll area, and a
        // transparent <body> just lets that white show through. drawsBackground
        // is the switch, and on macOS it is reachable only through KVC — so ask
        // for the backing setter first and skip rather than throw if some later
        // OS drops it. Setting an undefined key would raise, and an uncaught
        // ObjC exception here is a hard crash.
        if v.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            v.setValue(false, forKey: "drawsBackground")
        }
        load(v)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) { load(v) }

    private func load(_ v: WKWebView) {
        guard let url = OrbScheme.url(state: state, size: size, hex: hex) else { return }
        if v.url?.absoluteString != url.absoluteString {
            v.load(URLRequest(url: url))
        }
    }
}

/// A dotted thinking orb, after Jakub Antalik's Thinking Orbs.
///
/// The thing that makes those read as *alive* is that they are SPHERES, not
/// rings — "particles on tilted orbits", "a scan meridian sweeps a dotted
/// globe". So points are distributed on a real sphere (Fibonacci lattice, which
/// spaces them evenly without clumping at the poles), spun around a tilted
/// axis, and projected flat. Depth drives radius and opacity, so the front face
/// reads bright and near and the back falls away.
///
/// Plain 2D Canvas, no shaders. Every instance reads the same wall clock, so a
/// wall of orbs breathes together instead of looking like a dropped bag of
/// marbles — that phase-sharing is the detail that makes many indicators feel
/// like one system.
struct Orb: View {
    let status: Status
    var size: CGFloat = 16
    var dots: Int = 170

    /// Idle still breathes — it just breathes cheaply. Freezing it entirely was
    /// correct for power and wrong for the product: with everything idle, which
    /// is most of the day, nothing on screen moved at all.
    var body: some View {
        TimelineView(.periodic(from: .now, by: status == .idle ? 1.0 / 8.0
                                                               : 1.0 / 20.0)) { tl in
            canvas(clock: tl.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func canvas(clock: Double) -> some View {
        Canvas { ctx, box in
            let t = clock
            let c = CGPoint(x: box.width / 2, y: box.height / 2)
            let R = min(box.width, box.height) * 0.42
            let col = status.color
            let m = status.mode

            // Their INLINE preset, ported. The lesson from the real numbers is
            // that small orbs get FEWER and BIGGER dots — count multipliers down
            // at 0.028–0.53 while the size multiplier goes UP to 1.0–2.4. Grid
            // counts scale by sqrt(count), radii scale linearly by size.
            let cs = sqrt(m.count)
            let latRings = max(2, Int((17.0 * cs).rounded()))
            let lonDens  = max(2, Int((44.0 * cs).rounded()))
            let rBase = 0.6 * m.size
            let rDepth = 1.7 * m.size
            let yaw = t * m.speed * 0.35
            let tilt = 0.42

            struct P { let x: Double; let y: Double; let z: Double; let r: Double; let a: Double }
            var pts: [P] = []

            // RIBBON is not a globe. Their base is {lanes:5, segs:88, ghostN:150}:
            // a few continuous bands wrapping the sphere, undulating, over a
            // faint ghost shell. Built separately because culling rings out of a
            // lattice gives a wavy sphere, not a sash.
            if m.kind == .ribbon {
                // PORTED from thinking-orbs' own `Z` (ribbon/ring), not
                // reinvented from the description. The shape is a GREAT-CIRCLE
                // BAND: an orthonormal frame defines a circle plane, lanes are
                // offset along its normal, and every point is normalised back
                // onto the sphere. The plane's tilt oscillates, which is the
                // undulation — no amount of tuning a lat/lon grid gets there.
                //
                //   _(n,s) = (n/300)^s          radius scale
                //   J(i,n)                      fibonacci point, for the ghosts
                //   T(yaw,tilt,cx,cy,scale)     the projection below
                let o = Double(min(box.width, box.height)) / 2 * 0.78
                let rs = pow(Double(min(box.width, box.height)) / 300.0, 0.6)
                let spin = 1.0
                let tiltZ = 0.3

                func proj(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
                    let sn = sin(tiltZ), cs2 = cos(tiltZ)
                    let sy2 = sin(t * 0.1 * spin), cy2 = cos(t * 0.1 * spin)
                    let e = x * cy2 + z * sy2
                    let l = -x * sy2 + z * cy2
                    let d = y * cs2 - l * sn
                    let w = y * sn + l * cs2
                    return (e, -d, w)
                }

                // ghost shell — ghostN scaled by their linear rule
                let ghostN = max(0, Int(150.0 * m.count))
                for i in 0..<ghostN {
                    let ga = Double.pi * (3 - sqrt(5.0))
                    let ry = 1 - 2 * (Double(i) + 0.5) / Double(ghostN)
                    let ra = sqrt(max(0, 1 - ry * ry))
                    let oa = Double(i) * ga
                    let (x, y, z) = proj(ra * cos(oa) * o, ry * o, ra * sin(oa) * o)
                    let k = (z / o + 1) / 2
                    pts.append(P(x: x, y: y, z: k, r: max(0.5, 0.8 * rs),
                                 a: 0.1 + 0.22 * k))
                }

                // the band frame
                let e0 = t * 0.24 * spin
                let l0 = 0.55 + 0.3 * sin(t * 0.18) * spin      // plane tilt, oscillating
                let D = cos(e0), w0 = 0.0, iC = sin(e0)
                let u = -iC * sin(l0), g = cos(l0), b = D * sin(l0)
                let fN = w0 * b - iC * g
                let pN = iC * u - D * b
                let yN = D * g - w0 * u

                let wobMul = 1.0
                let lanes = max(1, Int((5.0 * cs).rounded()))
                let segs  = max(6, Int((88.0 * cs).rounded()))
                let bandMul = 4.94                              // ribbon inline extra
                let S = max(1, Int((Double(lanes) * bandMul).rounded()))

                for z in 0..<S {
                    let off = (Double(z) - Double(S - 1) / 2) * 0.075
                    let edge = abs(Double(z) - Double(S - 1) / 2)
                             / max(1, Double(S - 1) / 2)
                    for n in 0..<segs {
                        let k = Double(n) / Double(segs) * 2 * .pi
                        let wob1 = 0.16 * sin(k * 3 - t * 1.7 + Double(z) * 0.22)
                        let wob2 = 0.07 * sin(k * 5 + t * 1.1)
                        let L = (wob1 + wob2) * wobMul
                        let C = off + L
                        let vx = D * cos(k) + u * sin(k) + fN * C
                        let vy = w0 * cos(k) + g * sin(k) + pN * C
                        let vz = iC * cos(k) + b * sin(k) + yN * C
                        let W = sqrt(vx * vx + vy * vy + vz * vz)
                        guard W > 0 else { continue }
                        let (px, py, pz) = proj(vx / W * o, vy / W * o, vz / W * o)
                        let K = (pz / o + 1) / 2
                        let rr = (1.1 + 1.7 * K) * (1 - 0.25 * edge) * rs
                        pts.append(P(x: px, y: py, z: K,
                                     r: max(0.6, rr), a: 0.4 + 0.6 * K))
                    }
                }
            } else {

            // A lat/lon lattice, not a Fibonacci scatter. This is what makes
            // theirs read as a globe with structure rather than a cloud.
            for iLat in 0..<latRings {
                let v = (Double(iLat) + 0.5) / Double(latRings)
                let phi = acos(1 - 2 * v)
                let ring = max(2, Int((Double(lonDens) * sin(phi)).rounded()))
                for iLon in 0..<ring {
                    var theta = (Double(iLon) / Double(ring)) * .pi * 2
                    var rad = 1.0
                    var boost = 1.0
                    var dim = 1.0

                    switch m.kind {
                    case .globe:                       // searching: scan meridian
                        let sweep = (t * m.speed * 0.18).truncatingRemainder(dividingBy: 1) * .pi * 2
                        var d = abs(theta - sweep)
                        if d > .pi { d = .pi * 2 - d }
                        let beam = max(0, 1 - d / 0.5)
                        boost = 1 + 3.0 * beam
                        dim = 0.45 + 0.55 * beam
                    case .rubik:                       // solving: bands scramble
                        let cyc = (t * m.speed * 0.2).truncatingRemainder(dividingBy: 1)
                        let mess = cyc < 0.7 ? sin(cyc / 0.7 * .pi) : 0
                        if iLat % 3 == 0 { theta += 1.1 * mess }
                        dim = 0.5 + 0.5 * (1 - mess)
                    case .wave:                        // listening
                        let w = sin(t * m.speed * 0.5 - phi * 3.4)
                        rad = 1 + 0.14 * w
                        boost = 1 + 0.6 * max(0, w)
                    case .web:                         // delegating
                        let head = (t * m.speed * 0.14).truncatingRemainder(dividingBy: 1)
                        var d = (theta / (.pi * 2)) - head
                        if d < 0 { d += 1 }
                        boost = 1 + 2.2 * pow(1 - d, 4)
                        dim = 0.28 + 0.72 * pow(1 - d, 1.6)
                    case .ribbon: break        // built above, own geometry

                    case .morph:                       // shaping: circle→tri→square
                        let stage = (t * m.speed * 0.12).truncatingRemainder(dividingBy: 3)
                        let sides: Double = stage < 1 ? 0 : (stage < 2 ? 3 : 4)
                        if sides > 0 {
                            // Pull each dot onto the nearest polygon edge, so the
                            // outline visibly snaps from circle to triangle to square.
                            let seg = .pi * 2 / sides
                            let corner = (theta / seg).rounded() * seg
                            let apoth = cos(seg / 2) / max(0.35, cos(theta - corner))
                            rad = apoth
                        }
                        boost = 1.25

                    case .braid:                       // weaving
                        theta += 0.5 * sin(t * m.speed * 0.3 + Double(iLat) * 2.094)
                    case .ring:                        // idle breathing
                        rad = 1 + 0.05 * sin(t * m.speed * 0.28)
                        dim = 0.72
                    case .scatter:                     // stuck
                        let j = sin(t * m.speed * 0.4 + Double(iLat * 7 + iLon) * 2.399)
                        theta += 0.5 * j
                        rad = 1 + 0.18 * j
                        dim = 0.5 + 0.4 * abs(j)
                    case .knock:                       // needs you
                        let cyc = t.truncatingRemainder(dividingBy: 2.17)
                        let k = cyc < 0.34 ? sin(cyc / 0.34 * .pi)
                              : (cyc < 0.72 ? sin((cyc - 0.38) / 0.34 * .pi) : 0)
                        rad = 1 + 0.26 * max(0, k)
                        boost = 1 + 1.4 * max(0, k)
                        dim = 0.5 + 0.5 * max(0, k)
                    }

                    let sx = sin(phi) * cos(theta + yaw)
                    let sy = cos(phi)
                    let sz = sin(phi) * sin(theta + yaw)
                    let ty = sy * cos(tilt) - sz * sin(tilt)
                    let tz = sy * sin(tilt) + sz * cos(tilt)
                    let z = (tz + 1) / 2                       // 0 back … 1 front

                    // Their radius and ink curves, verbatim in shape:
                    //   r = (rBase * 1.5 + rDepth * z) * mul
                    //   a = 0.5 + 0.5 * z
                    let rr = (rBase * 1.5 + rDepth * z) * boost * (R / 26.0)
                    pts.append(P(x: sx * R * rad, y: ty * R * rad, z: z,
                                 r: max(0.5, rr), a: (0.5 + 0.5 * z) * dim))
                }
            }

            }   // end lattice branch

            // Constellation wiring for `web`. Near-neighbour pairs on the front
            // face get a hairline, which is what "a constellation wires itself"
            // actually looks like. Their preset carries lineW: 0.8 for this.
            if m.kind == .web {
                let front = pts.filter { $0.z > 0.55 }
                for i in 0..<front.count {
                    for j in (i + 1)..<front.count {
                        let a = front[i], b = front[j]
                        let dx = a.x - b.x, dy = a.y - b.y
                        let dist = (dx * dx + dy * dy).squareRoot()
                        guard dist < R * 0.52 else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: c.x + a.x, y: c.y + a.y))
                        path.addLine(to: CGPoint(x: c.x + b.x, y: c.y + b.y))
                        let fade = (1 - dist / (R * 0.52)) * 0.45
                        ctx.stroke(path, with: .color(col.opacity(fade)), lineWidth: 0.8)
                    }
                }
            }

            for q in pts.sorted(by: { $0.z < $1.z }) {
                // No rounding. Sub-pixel positions are what make rotation glide;
                // snapping them to the grid is what made it stutter.
                let d = max(1.2, q.r)
                if q.a <= 0.001 { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + q.x - d / 2,
                                                y: c.y + q.y - d / 2,
                                                width: d, height: d)),
                         with: .color(col.opacity(min(1, q.a))))
            }
        }
    }
}

/// The strip that clears the notch. One orb per state that has anything in it.
struct StatusStrip: View {
    let working: Int, needsYou: Int, stuck: Int
    private var idle: Bool { working == 0 && needsYou == 0 && stuck == 0 }
    var body: some View {
        HStack(spacing: 8) {
            if needsYou > 0 { pair(.needsYou, needsYou, 22) }
            if working > 0 { pair(.working, working, 22) }
            if stuck > 0 { pair(.stuck, stuck, 22) }
            if idle { Orb(status: .idle, size: 22, dots: 150) }
        }
    }
    private func pair(_ s: Status, _ n: Int, _ px: CGFloat) -> some View {
        HStack(spacing: 3) {
            Orb(status: s, size: px, dots: 150)
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(s.color)
        }
    }
}


/// The island's own silhouette: flush with the top of the screen, with the top
/// corners curving OUTWARD into it rather than away. That inverse shoulder is
/// what makes a notch panel read as part of the bezel instead of a card floating
/// near it — and it only works if there is no gap at the top at all.
struct IslandShape: Shape {
    var radius: CGFloat = 20
    var shoulder: CGFloat = Store.shoulder

    /// Collapsed and expanded are this same outline with different numbers, so
    /// the expand can interpolate along one family instead of cross-fading two
    /// unrelated paths. The collapsed state used to be its own `Shape` type,
    /// which SwiftUI can only swap, never morph — that swap is the pop.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulder) }
        set { radius = newValue.first; shoulder = newValue.second }
    }

    func path(in outer: CGRect) -> Path {
        // Inset so the outward shoulders have room to exist. Drawing past the
        // bounds gets clipped, and a clipped shoulder is a square corner.
        let r = outer.insetBy(dx: shoulder, dy: 0)
        var p = Path()
        p.move(to: CGPoint(x: r.minX - shoulder, y: r.minY))
        // outward curve, screen edge → left wall
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + shoulder),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY),
                       control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - radius),
                       control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + shoulder))
        // outward curve, right wall → screen edge
        p.addQuadCurve(to: CGPoint(x: r.maxX + shoulder, y: r.minY),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - View ------------------------------------------------------------

struct IslandView: View {
    @ObservedObject var store: Store
    @State private var draft = ""
    @State private var editingID: String?
    @State private var editText = ""
    @State private var showIdle = false { didSet { store.showIdleRows = showIdle } }
    @State private var showFull = false { didSet { store.showFullReply = showFull } }
    @State private var drops: [URL] = []
    @State private var dropping = false
    @FocusState private var chatFocused: Bool
    @FocusState private var gateFocus: String?
    // Loop form. Local to the view because none of it is worth persisting —
    // an abandoned half-typed loop should not come back tomorrow.
    @State private var loopKind = "fan"
    /// Who the loop runs on, in the order they were picked. One id is a single
    /// agent; several is a set. Order matters — see `LoopArgs.lead`.
    @State private var loopWho: [String] = []
    @State private var loopPieces = 2
    @State private var loopRounds = 3
    @State private var loopBar = ""
    @State private var linkDraft = ""
    /// Lets the ear orb become the panel's lead orb instead of two orbs
    /// cross-fading — the small one grows into the big one.
    @Namespace private var morph

    var isl: Island { store.island }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Only the visible state is mounted. Keeping both in a ZStack
                // at opacity 0 still ran TimelineView orbs and WKWebViews, which
                // is why PongIsland sat at ~40% CPU with WebKit.GPU at ~190%
                // while the pill was collapsed. A swap-in pop is cheaper than
                // that, and the silhouette still interpolates.
                if store.expanded { expanded } else { collapsed }
            }
            .frame(width: store.visibleWidth, height: store.visibleHeight,
                   alignment: .top)
            // Clip AFTER the frame, so the clip, the fill below and the frame
            // are all the same rectangle. It used to sit on the inner stack,
            // where the shape was handed the content's own bounds instead —
            // a different, taller rect than the black, so content could fall
            // outside the sheet and still be drawn.
            .clipShape(silhouette)
            .background(
                // One silhouette throughout. Only its two numbers and its fill
                // change between states, so the expand grows out of the notch
                // instead of replacing it. Collapsed is pure black rather than
                // Ink.bg — a hair lighter would show a seam exactly where the
                // shape meets the real cutout.
                silhouette
                    .fill(store.expanded ? Ink.bg : Color.black)
                    .overlay(
                        silhouette.stroke(Ink.hair.opacity(store.expanded ? 1 : 0),
                                          lineWidth: 1)
                    )
                    .padding(.horizontal, -silhouetteShoulder)  // spill into the margin
                    .compositingGroup()                          // shadow the SILHOUETTE,
                    .shadow(color: .black.opacity(store.expanded ? 0.45 : 0),
                            radius: 16, x: 0, y: 6)              // not the bounding box
            )
        }
        // The watch owns hover; this only drops field focus when the pointer
        // leaves the (now silhouette-sized) window.
        .onHover { inside in
            if !inside { editingID = nil; chatFocused = false }
        }
        // Window size is the drawn sheet, not the expanded ceiling. A
        // 504×1083 transparent panel at menu-bar level is what WindowServer
        // composited all day while the pill was 35pt tall. Top edge stays on
        // the screen edge; expand grows down. layout() pins the AppKit frame
        // to the same rect so the hosting view cannot drag us to (0, -484).
        .frame(width: store.panelWidth, height: store.panelHeight, alignment: .top)
    }

    /// The silhouette for the current state. Same shape, two settings — the
    /// collapsed one carries the measured notch corner and a matching outward
    /// shoulder, the expanded one the panel's larger pair.
    private var silhouette: IslandShape {
        store.expanded
            ? IslandShape(radius: 20, shoulder: Store.shoulder)
            : IslandShape(radius: Notch.cornerRadius, shoulder: Notch.shoulder)
    }
    private var silhouetteShoulder: CGFloat {
        store.expanded ? Store.shoulder : Notch.shoulder
    }

    // ---- collapsed: flanks the notch. Nothing is ever drawn over the cutout.
    private var collapsed: some View {
        HStack(spacing: 0) {
            // LEFT EAR — what the team is doing, always.
            //
            // Leading-aligned, inset by the same gap the orb has above and below
            // it. Right-aligned it sat against the cutout with a wide empty run
            // of black to its left, so the padding disagreed with itself on
            // three sides. No capsule: deep purple carries itself up here, and a
            // grey pill on the menu bar reads as a mistake.
            HStack(spacing: 5) {
                // No seat name. The ear is far too narrow for one, so anything
                // longer than a short word truncated to a letter and an ellipsis
                // — "Engineering" as "E…" — which reads as a glitch rather than
                // as information. The orb carries the state, the count the
                // number, and the name is on the row you get by hovering.
                Orb(status: store.headline, size: 22, dots: 110)
                    .frame(width: 22, height: 22)
                if store.headlineCount > 0 {
                    Text("\(store.headlineCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(store.headline.color)
                        .padding(.trailing, 5)   // 5pt further from the cutout
                }
            }
            .padding(.leading, collapsedInset)
            .frame(width: store.earWidth, alignment: .leading)

            // THE NOTCH — left alone. The cutout is not ours to paint on.
            Color.clear.frame(width: store.notchWidth)

            // RIGHT EAR — one line, or nothing at all.
            //
            // The tone and the words arrive already decided and already
            // shortened; this only draws them. lineLimit(1) and tail truncation
            // are the backstop, not the plan — a string that needs truncating
            // here means the words should have been shorter upstream. Never
            // wraps, so it can never reach down over the cutout.
            // A ZStack, not an HStack: mid-rotation both lines exist at once,
            // and stacked they overlap where a row would shove each other
            // sideways. Clipped so a line leaving looks like it goes under the
            // black rather than floating out over the screen.
            ZStack(alignment: .trailing) {
                if let line = store.tickerLine {
                    Text(line.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.tickerColor)
                        .lineLimit(1)
                        // Shrink before you cut. The ear is sized so real lines
                        // fit outright; this only engages on something abnormal,
                        // and a line a shade small still reads, where "need…"
                        // has had a word taken off it. Tail truncation stays as
                        // the last resort under that.
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(store.tickerIndex)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .padding(.trailing, Notch.tickerTrailing)
            .frame(width: store.earWidth, alignment: .trailing)
            .clipped()
        }
        .frame(height: store.chin, alignment: .center)
    }

    /// The black margin around the orb, matched on every side.
    ///
    /// Top and bottom already came out even because the orb is centred in the
    /// chin, so the left is simply the same number rather than a second value
    /// tuned by eye against a screenshot.
    private var collapsedInset: CGFloat { max(4, (store.chin - 22) / 2) }

    /// The list itself, used bare when it fits and inside a ScrollView when it
    /// does not. A ScrollView always takes the height it is offered, which is
    /// why the panel used to be mostly empty black.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(isl.gates) { gateCard($0) }
            ForEach(isl.asks) { askCard($0) }
            ForEach(isl.attention) { attentionRow($0) }
            ForEach(isl.approvals) { ask($0) }
            // one line per running graph, on every team, paused ones last (1.9: the seat list is retired)
            ForEach(isl.graphLines) { graphRow($0) }
            if isl.approvals.isEmpty && isl.gates.isEmpty && isl.asks.isEmpty && isl.attention.isEmpty
                && isl.graphsRunning.isEmpty && !isl.chiefThinking {
                HStack(spacing: 8) {
                    Orb(status: .idle, size: 22, dots: 110)
                    Text("All quiet. Nothing needs you.")
                        .font(.system(size: 13)).foregroundStyle(Ink.second)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .padding(.bottom, 6)
    }

    // ---- expanded: rows carry their own state. No section labels.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Everything above the composer shares what is left and scrolls
            // when that is not enough.
            //
            // Conversation moved INSIDE this region. As a sibling of the
            // composer it was a second fixed-height child, and at 240pt on More
            // it was most of the shortfall that pushed the composer off the
            // bottom: header 46 + list 320 + Conversation 240 + composer
            // chrome 46 is 652 against a 520 ceiling, so something had to be
            // drawn outside the sheet and the bottom-most child is what it was.
            //
            // The scroll also absorbs the leftover. Everything else in this
            // stack is a fixed size, so with a flexible middle the sheet is
            // exactly as tall as the store says it is — which is the height the
            // black is drawn at, and the height `silhouetteRect` reports to
            // `hitTest`. Without it the stack laid out at its own natural
            // height while the background used the store's formula, the two
            // drifted by however much the chat and the composer happened to
            // want, and the composer hung below the sheet. Two independent
            // numbers for one height is the bug.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    rows
                    lastWord
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // over the list, not in it: answering one gate must not move another card's buttons
            .overlay(alignment: .bottom) {
                if let done = store.gateToast { gateToastRow(done, warn: store.gateToastWarn) }
            }
            // Loops sit above the composer and yield before it. Three priority
            // tiers, so the order things give way in is stated rather than
            // emergent: the list first (0), then the loop panel (1), and the
            // composer last (2). The owner's rule — if the two compete for the
            // bottom, the composer wins.
            loopSection.layoutPriority(1)
            // Yields before loops (1) and the composer (2). A weekly strip that
            // outranked the composer would push it off the sheet.
            if store.weeklyHeight > 0 { weeklyStrip.layoutPriority(0) }
            // Claimed before everything, and never given back. A VStack shares
            // a shortfall out among its children, so without this priority the
            // bottom-most child is the one that ends up drawn past the
            // silhouette — which is exactly how the composer went missing with
            // a full seat list and Conversation open.
            chatBar.layoutPriority(2)
        }
        .frame(height: store.visibleHeight, alignment: .top)
    }

    /// Usage strip, in their idiom: tiny, mono, muted, with the live number lit.
    private var header: some View {
        HStack(spacing: 8) {
            // across every team, the way the app's sidebar counts: "2 need you · 1 working · 1 paused"
            if isl.needsYouAll > 0 {
                Image(systemName: "diamond.fill").font(.system(size: 11)).foregroundStyle(Ink.amber)
                Text("\(isl.needsYouAll) need\(isl.needsYouAll == 1 ? "s" : "") you")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.amber)
            }
            if isl.workingAll > 0 {
                if isl.needsYouAll > 0 { Text("·").font(.system(size: 12)).foregroundStyle(Ink.dim) }
                Text("\(isl.workingAll) working").font(.system(size: 12)).foregroundStyle(Ink.teal)
            }
            if isl.pausedAll > 0 {
                if isl.needsYouAll > 0 || isl.workingAll > 0 { Text("·").font(.system(size: 12)).foregroundStyle(Ink.dim) }
                Text("\(isl.pausedAll) paused").font(.system(size: 12)).foregroundStyle(Ink.second)
            }
            // only when there is no graph line at all: a question just answered here is hidden from
            // "need you" while the snapshot still shows its graph waiting, and that graph is running
            if isl.needsYouAll == 0 && isl.graphsRunning.isEmpty {
                Text("No graphs running").font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Collapse") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        store.expanded = false
                    }
                }
                Divider()
                Button("Quit Pong Island") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.dim)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Collapse or quit")
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 11)
    }

    /// A graph waiting on you: the question, how the work was graded, a note, and the
    /// three answers — Approve, Edit (send it back with your note), Refuse (stop the run).
    private func gateCard(_ g: GateItem) -> some View {
        let busy = store.gateBusy.contains(g.id)
        let editing = store.gateEditing == g.id
        let draft = Binding<String>(get: { store.gateDraft[g.id] ?? "" },
                                    set: { store.gateDraft[g.id] = $0 })
        let hasNote = !(store.gateDraft[g.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let extra = g.options.filter { $0 != "approved" && $0 != "rejected" }
        // "rejected" with nowhere to go would END the run: that is Refuse's job, with its confirm
        let canSendBack = g.options.contains("rejected") && (g.routes["rejected"].map { !$0.isEmpty } ?? true)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Orb(status: .needsYou, size: 22, dots: 130)
                Text("Needs your answer · \(g.title)")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.amber)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                chip(g.teamName)
            }
            .padding(.bottom, 8)

            // the question in plain words first; the step's own report only when there is none
            Text(!g.question.isEmpty ? g.question : (g.summary.isEmpty ? g.reason : g.summary))
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.text)
                .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, g.context.isEmpty ? 6 : 3)
            ForEach(Array(g.context.prefix(3).enumerated()), id: \.offset) { _, line in
                Text("· " + line).font(.system(size: 11.5)).foregroundStyle(Ink.second)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            detailDisclosure(id: g.id, points: g.detail, by: g.detailBy, pending: g.detailPending)
            if !g.gradeLine.isEmpty {
                Text(g.gradeLine).font(.system(size: 11)).foregroundStyle(Ink.second).padding(.bottom, 2)
            }
            if !g.adviceLine.isEmpty {
                Text(g.adviceLine).font(.system(size: 12)).foregroundStyle(Ink.second).padding(.bottom, 2)
            }
            HStack(spacing: 10) {
                ForEach(Array(g.files.prefix(3)), id: \.self) { f in
                    Button((f as NSString).lastPathComponent) { Pong.openWork(f) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.blue).lineLimit(1)
                }
                if !g.notesPath.isEmpty {
                    Button("Graph notes") { Pong.openWork(g.notesPath) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.blue)
                }
            }
            .padding(.top, 4).padding(.bottom, 9)

            // The answers first and the note under them: showing the note never moves a button.
            VStack(spacing: 6) {
                gateButton(approveTitle(g, hasNote), Ink.teal) {
                    store.answerGate(g, outcome: "approved")
                }
                .help(g.choices["approved"] ?? "")
                if canSendBack {
                    gateButton(editing ? (hasNote ? "Send it back with this note" : "Type what should change below, then press here")
                                       : "Send back with a note", Ink.amber) {
                        if editing && hasNote { store.answerGate(g, outcome: "rejected") }
                        else {
                            store.startGateNote(g)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { gateFocus = g.id }
                        }
                    }
                    .help(g.choices["rejected"] ?? "")
                }
                ForEach(extra, id: \.self) { o in
                    gateButton(extraTitle(g, o), Ink.violet) { store.answerGate(g, outcome: o) }
                        .help(g.choices[o] ?? "")
                }
                gateButton(store.gateConfirmStop == g.id ? "Click again to stop it"
                                                          : "Stop the graph", Ink.red) {
                    store.refuseGate(g)
                }
                if let again = store.gateRetry[g.id] {
                    gateButton("Allow one more round and send it", Ink.amber) { store.answerGate(g, outcome: again, extend: true) }
                }
            }
            .disabled(busy).opacity(busy ? 0.5 : 1)

            if editing || hasNote {
                // no Return-to-send: every answer is an explicit button
                TextField("Your note: what should change (goes to the step that redoes it)", text: draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .lineLimit(1...4).padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Ink.raised))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.amber.opacity(0.45)))
                    .focused($gateFocus, equals: g.id)
                    .simultaneousGesture(TapGesture().onEnded { store.startGateNote(g); gateFocus = g.id })
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                if busy {
                    Text("Sending…").font(.system(size: 11)).foregroundStyle(Ink.second)
                } else if let m = store.gateMsg[g.id] {
                    Text(m).font(.system(size: 11)).foregroundStyle(Ink.red).lineLimit(3)
                }
                Spacer()
                if !g.seat.isEmpty {
                    Button("Open its screen ↗") { Pong.frontSeat(seat: g.seat, session: g.session) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.second)
                        .help("The terminal of \(g.seat), the step that led to this question")
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Ink.tintYou)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .bottom)
    }

    /// A chat's question: its options as buttons (the first is the recommendation), or a note.
    private func askCard(_ a: AskItem) -> some View {
        let busy = store.gateBusy.contains(a.id)
        let draft = Binding<String>(get: { store.gateDraft[a.id] ?? "" }, set: { store.gateDraft[a.id] = $0 })
        let note = (store.gateDraft[a.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.amber)
                Text("NEEDS YOU").font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(Ink.amber)
                Image(systemName: "text.bubble.fill").font(.system(size: 11)).foregroundStyle(Ink.magenta)
                Text("Chat · \(a.teamName)").font(.system(size: 12)).foregroundStyle(Ink.second).lineLimit(1)
                Spacer()
            }
            .padding(.bottom, 8)
            Text(a.question)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, a.context.isEmpty ? 8 : 4)
            ForEach(Array(a.context.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(Ink.second)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            }
            detailDisclosure(id: a.id, points: a.detail, by: a.detailBy, pending: a.detailPending)
            HStack(spacing: 10) {
                ForEach(Array(a.files.prefix(3)), id: \.self) { f in
                    Button((f as NSString).lastPathComponent) { Pong.openWork(f) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.blue).lineLimit(1)
                }
            }
            .padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(Array(a.options.enumerated()), id: \.offset) { i, o in
                    gateButton(o.label, i == 0 ? Ink.teal : Ink.amber) { store.answerAsk(a, choice: o.key) }
                        .help(o.what)
                }
                if a.options.isEmpty {
                    gateButton(note.isEmpty ? "Type your answer below" : "Reply", Ink.teal) {
                        if !note.isEmpty { store.answerAsk(a, choice: "") }
                    }
                }
            }
            .disabled(busy).opacity(busy ? 0.5 : 1)
            TextField(a.options.isEmpty ? "Your answer" : "Add a note (optional)", text: draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13))
                .lineLimit(1...4).padding(9)
                .background(RoundedRectangle(cornerRadius: 6).fill(Ink.raised))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: "6B778B")))
                .padding(.top, 8)
            if let m = store.gateMsg[a.id] {
                Text(m).font(.system(size: 11)).foregroundStyle(Ink.red).lineLimit(3).padding(.top, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Ink.tintYou)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .bottom)
    }

    /// "Details (4) ›": what is being decided, in more depth, folded until asked for. Each point is a
    /// fact with a link to the file it comes from; then who wrote them. "Details coming…" while a
    /// helper AI is still writing.
    @ViewBuilder
    private func detailDisclosure(id: String, points: [DetailPoint], by: String, pending: Bool) -> some View {
        if points.isEmpty && pending {
            Text("Details coming…").font(.system(size: 11)).foregroundStyle(Ink.dim)
                .padding(.top, 2).padding(.bottom, 4)
        } else if !points.isEmpty {
            let open = store.detailOpen.contains(id)
            VStack(alignment: .leading, spacing: 4) {
                Button { store.toggleDetail(id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                        Text(open ? "Details" : "Details (\(points.count))").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Ink.second)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Fold the details away" : "What you're deciding, in more depth, with the files")
                .accessibilityLabel(open ? "Hide details" : "Show details, \(points.count) point\(points.count == 1 ? "" : "s")")
                if open {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("• " + p.text + (p.file.isEmpty && !p.place.isEmpty ? " · " + p.place : ""))
                                .font(.system(size: 11.5)).foregroundStyle(Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if !p.file.isEmpty {
                                let name = (p.file as NSString).lastPathComponent
                                Button("↗ " + name + (p.place.isEmpty ? "" : " · " + p.place)) { Pong.openWork(p.file) }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.blue)
                                    .lineLimit(1).truncationMode(.middle)
                                    .padding(.leading, 10)
                                    .help(p.file)
                                    .accessibilityLabel("Open " + name + (p.place.isEmpty ? "" : ", at " + p.place))
                            }
                        }
                    }
                    let who = DetailPoint.attribution(by)
                    if !who.isEmpty {
                        Text(who).font(.system(size: 11)).foregroundStyle(Ink.dim)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    if pending { Text("Details coming…").font(.system(size: 11)).foregroundStyle(Ink.dim) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What you're deciding")
            .padding(.top, 3).padding(.bottom, 5)
        }
    }

    private func approveTitle(_ g: GateItem, _ hasNote: Bool) -> String {
        let to = (g.routes["approved"] ?? []).filter { $0 != "end" }
        let base = hasNote ? "Approve, with my note" : "Approve"
        if g.routes["approved"] == ["end"] { return base + " — finish" }
        return to.isEmpty ? base : base + " — go on to " + to.joined(separator: ", ")
    }

    private func extraTitle(_ g: GateItem, _ o: String) -> String {
        let to = (g.routes[o] ?? []).joined(separator: ", ")
        return "Answer: " + o.replacingOccurrences(of: "route:", with: "") + (to.isEmpty ? "" : " → " + to)
    }

    private func gateButton(_ title: String, _ tint: Color, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            // Wallace-clean: the primary is ink on sodium white, the rest quiet; red only stops
            let primary = tint == Ink.teal
            let danger = tint == Ink.red
            HStack {
                Text(title).font(.system(size: 13, weight: primary ? .semibold : .medium))
                    .foregroundStyle(primary ? Ink.onInk : (danger ? Ink.red : Ink.text))
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(primary ? Ink.ink : (danger ? Color.clear : Color(hex: "161D27"))))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(primary || danger ? Color.clear : Color(hex: "6B778B")))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// A running step whose seat needs a person, one line and a way in.
    private func attentionRow(_ a: AttentionItem) -> some View {
        HStack(spacing: 10) {
            Orb(status: .needsYou, size: 18, dots: 100)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(a.title) · \(a.node) on \(a.seat)")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.amber).lineLimit(1)
                Text(a.what).font(.system(size: 11.5)).foregroundStyle(Ink.second).lineLimit(2)
            }
            Spacer()
            if !a.seat.isEmpty {
                Button("Open ↗") { Pong.frontSeat(seat: a.seat, session: a.session) }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.blue)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Ink.raised)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .bottom)
    }

    /// What the last answer did, for a few seconds after its card is gone.
    private func gateToastRow(_ t: String, warn: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(warn ? Ink.amber : Ink.teal)
            Text(t).font(.system(size: 12)).foregroundStyle(Ink.text).lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.bg).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hair)))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    /// An agent asking for you. Full-width option rows with keycaps, not pills.
    private func ask(_ a: Approval) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Orb(status: .needsYou, size: 22, dots: 130)
                Text("\(a.workerLabel.isEmpty ? a.worker : a.workerLabel) asks")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.violet)
                Spacer()
                chip(a.worker)
            }
            .padding(.bottom, 9)

            Text(a.preview.isEmpty ? "Waiting on your decision." : a.preview)
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 11)

            if editingID == a.id {
                TextField("What should change?", text: $editText, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .lineLimit(1...4).padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Ink.raised))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Ink.amber.opacity(0.45)))
                    .padding(.bottom, 8)
                    .onSubmit { commitEdit(a) }
            }

            VStack(spacing: 6) {
                option("1", "Approve", Ink.teal) {
                    Pong.approve(a, isl.session); store.refresh()
                }
                option("2", editingID == a.id ? "Send this edit" : "Edit", Ink.amber) {
                    if editingID == a.id { commitEdit(a) }
                    else { editingID = a.id; editText = ""; store.claimKeyboard() }
                }
                option("3", "Deny", Ink.red) {
                    Pong.deny(a, isl.session, note: ""); store.refresh()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Ink.raised)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .bottom)
    }

    private func option(_ key: String, _ title: String, _ tint: Color,
                        _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 10) {
                Text("⌘\(key)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.second)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Ink.chip))
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(tint)
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.22)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Edit is never a silent overwrite: your words are recorded as the verdict,
    /// then handed back as a revise job. That diff is the learning signal.
    private func commitEdit(_ a: Approval) {
        let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { editingID = nil; return }
        Pong.edit(a, isl.session, correction: t)
        editText = ""; editingID = nil; store.refresh()
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Ink.second)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Ink.chip))
    }

    /// A seat, in their row idiom: orb, name, what it is doing, chips, right-aligned.
    /// A running graph: its name, the step it is on (or why it is paused), its team and how long it has run.
    /// Opens it in the app. A paused one rests (grey, not the cyan of work), like the app's paused rows.
    private func graphRow(_ l: GraphLine) -> some View {
        Button { store.openGraph(l.id) } label: {
            HStack(spacing: 8) {
                Orb(status: l.waiting ? .needsYou : (l.paused ? .idle : .working), size: 16, dots: 70)
                    .frame(width: 16, height: 16)
                Text(l.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.text)
                    .lineLimit(1).truncationMode(.middle)
                if l.paused {
                    Text("· " + l.pausedWords).font(.system(size: 12)).foregroundStyle(Ink.second).lineLimit(1)
                } else if !l.step.isEmpty {
                    Text("· " + l.step).font(.system(size: 12)).foregroundStyle(l.waiting ? Ink.amber : Ink.second).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(l.teamName).font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(1)
                if l.since > 0 {
                    Text(Self.elapsed(since: l.since)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l.paused ? l.pausedWords + ". Open it in CyberPong" : (l.doing.isEmpty ? "Open it in CyberPong" : l.doing))
    }

    /// "12m", "3h 05m".
    static func elapsed(since: Double) -> String {
        let m = max(0, Int((Date().timeIntervalSince1970 - since) / 60))
        return m < 60 ? "\(m)m" : String(format: "%dh %02dm", m / 60, m % 60)
    }

    @ViewBuilder private func seatRow(_ s: Seat, lead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            // Same table as the ear, chief included. This row used to hardcode
            // the chief to .composing and to skip the stall test for everyone
            // else, so a seat wedged for an hour still showed its role motion.
            {
                let st: Status = lead ? (isl.chiefThinking ? .working : .idle)
                                      : Status.forSeat(s)
                return Orb(status: st, size: 26, dots: 110)
                    .frame(width: 26, height: 26)
            }()
                .matchedGeometryEffect(id: lead ? "headline" : "seat-\(s.id)", in: morph,
                                       isSource: !lead)
            VStack(alignment: .leading, spacing: 2) {
                Text(lead ? "Lead" : s.label)
                    .font(.system(size: 13.5, weight: lead ? .semibold : .medium))
                    .foregroundStyle(s.busy || lead ? Ink.text : Ink.text.opacity(0.66))
                    .lineLimit(1)
                if s.busy {
                    let st = Status.forSeat(s)
                    Text(lead ? "thinking"
                         : (st == .stuck
                            ? (s.busyMinutes > 20 ? "stuck · \(Int(s.busyMinutes))m" : "stuck")
                            : st.verb))
                        .font(.system(size: 11.5))
                        .foregroundStyle(st.color).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // Straight to this seat's pane. SF Symbol, like every other glyph in
            // here — an emoji would be the one thing on the island that is not
            // drawn in the same hand.
            Button {
                Pong.frontSeat(seat: lead ? (isl.conductor?.id ?? "c1") : s.id,
                               session: isl.session)
            } label: {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.dim)
            .help("Open \(lead ? "the lead" : s.label)'s terminal")
            if !s.type.isEmpty { chip(s.type) }
            chip(s.id)
            if !s.usageChip.isEmpty { chip(s.usageChip) }
            if s.state == "busy" {
                Button("free") { Pong.free(s.id, isl.session); store.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.teal)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !lead else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.openSeat = (store.openSeat == s.id) ? nil : s.id
            }
            store.layout()
        }
        .background(store.openSeat == s.id ? Ink.raised : Color.clear)
        // What this worker actually reported. The Chief thread stays clean.
        if store.openSeat == s.id {
            let out = isl.output(for: s.id)
            VStack(alignment: .leading, spacing: 6) {
                if out.isEmpty {
                    Text("Nothing reported yet.")
                        .font(.system(size: 11)).foregroundStyle(Ink.dim)
                } else {
                    ForEach(out.suffix(6)) { m in
                        Text(m.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.text.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
    }

    private var idleDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showIdle.toggle() }
                store.showIdleRows = showIdle
                store.layout()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: showIdle ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                    Text("\(isl.idle.count) idle").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(Ink.dim)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showIdle { ForEach(isl.idle) { seatRow($0, lead: false) } }
        }
    }

    /// The live exchange. Newest at the bottom, the way a terminal reads.
    @ViewBuilder private var lastWord: some View {
        if !isl.chiefChat.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    if isl.chiefThinking {
                        // Thinking, from the table — not the hardcoded resting
                        // motion this used to draw next to the word "thinking".
                        Orb(status: .working, size: 19, dots: 90)
                            .frame(width: 19, height: 19)

                        Text("Lead is thinking…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Ink.violet)
                    } else {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 11)).foregroundStyle(Ink.blue)
                        Text("Messages").font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Ink.blue)
                    }
                    Spacer()
                    Button {
                        Pong.clearChat(isl.session); store.refresh()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }.buttonStyle(.plain).foregroundStyle(Ink.dim).help("Clear")
                    Button(showFull ? "Less" : "More") {
                        withAnimation(.easeInOut(duration: 0.18)) { showFull.toggle() }
                        store.showFullReply = showFull; store.layout()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.second)
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)

                ScrollViewReader { sp in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            let shown = showFull ? isl.chiefChat
                                                 : Array(isl.chiefChat.suffix(3))
                            ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                                if let stamp = timeSeparator(at: i, in: shown) {
                                    Text(stamp)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Ink.text.opacity(0.5))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, i == 0 ? 0 : 3)
                                }
                                line(m)
                            }
                            if isl.chiefThinking && !isl.chiefTail.isEmpty {
                                HStack(alignment: .top, spacing: 7) {
                                    Text("c1")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Ink.violet)
                                        .frame(width: 26, alignment: .leading)
                                    Text(isl.chiefTail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Ink.text.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    .frame(height: showFull ? 190 : 76)
                    .onChange(of: isl.chiefChat.count) { _ in sp.scrollTo("end", anchor: .bottom) }
                    .onAppear { sp.scrollTo("end", anchor: .bottom) }
                }
            }
            .background(Ink.raised.opacity(0.45))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .top)
        }
    }

    /// Message-app rule: a stamp only where the conversation actually paused,
    /// and the date only when the day turns over.
    ///
    /// This is a separator BETWEEN messages rather than a field on each one,
    /// which is the whole difference between a conversation and a log — a time
    /// against every line is noise you stop reading.
    private func timeSeparator(at i: Int, in msgs: [ChatLine]) -> String? {
        guard i >= 0, i < msgs.count else { return nil }
        let ts = msgs[i].ts
        // Cards written before ts existed would otherwise date to 1970.
        guard ts > 0 else { return nil }
        let cur = Date(timeIntervalSince1970: ts)
        // The first line shown always anchors the day, so scrolling back never
        // leaves you guessing which day you are looking at.
        guard i > 0, msgs[i - 1].ts > 0 else { return Self.dayStamp(cur) }
        let prev = Date(timeIntervalSince1970: msgs[i - 1].ts)
        if !Calendar.current.isDate(cur, inSameDayAs: prev) { return Self.dayStamp(cur) }
        guard cur.timeIntervalSince(prev) >= Self.gapForStamp else { return nil }
        return Self.clock.string(from: cur)
    }

    /// Ten minutes of silence is a pause worth marking.
    private static let gapForStamp: TimeInterval = 600

    /// Locale-aware, so it reads 1:32 AM or 13:32 the way the rest of the Mac does.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let dayName: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()
    private static func dayStamp(_ d: Date) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(d) { day = "Today" }
        else if cal.isDateInYesterday(d) { day = "Yesterday" }
        else { day = dayName.string(from: d) }
        return "\(day) · \(clock.string(from: d))"
    }

    private func line(_ m: ChatLine) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(m.mine ? "you" : (m.seat.isEmpty ? "c1" : m.seat))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(m.mine ? Ink.teal : (m.status ? Ink.dim : Ink.violet))
                .frame(width: 26, alignment: .leading)
            Text(m.text)
                .font(.system(size: 11.5))
                .foregroundStyle(m.status ? Ink.dim : Ink.text.opacity(0.9))
                .italic(m.status)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: loops ---------------------------------------------------------

    /// Live model's weekly figure, collapsed to one line. Expands in place.
    /// Empty is the honest state — we never paint a guessed percentage.
    private var weeklyStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.showWeekly.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gauge.medium")
                        .font(.system(size: 11)).foregroundStyle(Ink.dim)
                    Text(weeklyCollapsed)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(isl.weekly.available ? Ink.second : Ink.dim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: store.showWeekly ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.dim)
                }
                .padding(.horizontal, 16)
                .frame(height: Store.weeklyBarChrome)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.showWeekly {
                VStack(alignment: .leading, spacing: 3) {
                    if isl.weekly.available {
                        if !isl.weekly.used.isEmpty {
                            Text("Used \(isl.weekly.used)")
                        }
                        if !isl.weekly.remaining.isEmpty {
                            Text("Remaining \(isl.weekly.remaining)")
                        }
                        if !isl.weekly.reset.isEmpty {
                            Text("Resets \(isl.weekly.reset)")
                        }
                        if isl.weekly.used.isEmpty
                            && isl.weekly.remaining.isEmpty
                            && isl.weekly.reset.isEmpty
                            && !isl.weekly.chip.isEmpty {
                            Text("Weekly \(isl.weekly.chip)")
                        }
                    } else {
                        Text("Nothing on the live panes this poll.")
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.dim)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: store.weeklyHeight, alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .top)
    }

    private var weeklyCollapsed: String {
        if isl.weekly.available, !isl.weekly.chip.isEmpty, !isl.weekly.model.isEmpty {
            return "\(isl.weekly.model) · \(isl.weekly.chip)"
        }
        return ""
    }

    /// Start a Fan, Cycle or Gauntlet without leaving the island.
    ///
    /// A strip that is always there when expanded, and a panel it opens. The
    /// panel's height is fixed and declared in `Store.loopPanelHeight` so the
    /// sheet the store draws and the rect `hitTest` uses stay the same number;
    /// the running list scrolls inside it rather than growing the sheet.
    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.showLoops.toggle()
                if store.showLoops {
                    if loopWho.isEmpty, let lead = store.island.orgMains.first {
                        loopWho = [lead.id]
                    }
                    if loopBar.isEmpty { loopBar = Store.barPaths.first ?? "" }
                    store.refreshLoops()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).foregroundStyle(Ink.violet)
                    Text("Graphs").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    if !store.loops.isEmpty { chip("\(store.loops.count) running") }
                    Spacer(minLength: 0)
                    Button { store.openNewGraphInterview() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            Text("New graph").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Ink.teal)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Ink.chip))
                    }
                    .buttonStyle(.plain)
                    .help("Design a graph by answering a few questions — opens in Terminal")
                    Image(systemName: store.showLoops ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.dim)
                }
                .padding(.horizontal, 16)
                .frame(height: Store.loopBarChrome)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.showLoops { loopPanel }
        }
        .frame(height: store.loopHeight, alignment: .top)
        .background(Ink.raised.opacity(0.35))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.hair), alignment: .top)
    }

    /// Paste links, or ask the engine to suggest some, and keep them as chips.
    ///
    /// Links ARE the bar: each chip becomes its own `--example` and the engine
    /// writes the markdown bar from them, so with links present a gauntlet
    /// needs no picked bar and the field below says so rather than looking
    /// like something required is missing.
    /// Who the loop runs on — the row that used to be a chip in a menu.
    ///
    /// The old control was a `chip("c1")` opening a list of org mains. It was
    /// easy to miss, and it could only ever hold one seat, so the engine's own
    /// participant set had no way to be expressed from here at all. This shows
    /// the whole roster of mains at once, lit or not, and writes the resolved
    /// answer beside the caption: a human should be able to read who a loop is
    /// about to run on without opening anything.
    ///
    /// One chip is `--owner` — point it at a single agent. Several is a set:
    /// `--owner` plus `--with`. Which of several leads is `LoopArgs.lead`'s
    /// answer and nobody else's, so this caption and the argv `startLoop`
    /// builds cannot tell a human two different stories.
    private var whoRow: some View {
        let mains = store.island.orgMains
        // Only seats that are still mains on this poll. A pick made before a
        // roster change should stop being lit, not quietly stay selected.
        let picked = loopWho.filter { id in mains.contains { $0.id == id } }
        let lead = LoopArgs.lead(picked: picked,
                                 conductor: store.island.conductor?.id ?? "")
        let rest = picked.filter { $0 != lead }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Who runs this")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.second)
                Spacer(minLength: 0)
                Text(picked.isEmpty
                     ? "nobody picked"
                     : (rest.isEmpty
                        ? "\(lead) alone"
                        : "\(lead) leads · with \(rest.joined(separator: ", "))"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(picked.isEmpty ? Ink.amber : Ink.teal)
                    .lineLimit(1).truncationMode(.middle)
            }
            // Fixed height, for the same reason the panel around it is fixed:
            // the sheet and the hit-test silhouette are drawn from one number.
            // A roster with more mains than these rows hold scrolls here rather
            // than growing the panel out from under `Store.loopPanelHeight`.
            ScrollView {
                WhoChipFlow(mains: mains, picked: picked,
                            width: Store.bodyWidth - 32) { id in
                    if let i = loopWho.firstIndex(of: id) { loopWho.remove(at: i) }
                    else { loopWho.append(id) }
                }
                .frame(height: WhoChipFlow.height(mains, width: Store.bodyWidth - 32),
                       alignment: .topLeading)
            }
            .frame(height: Store.loopWhoHeight)
        }
    }

    private var linksRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Paste links — newline or comma", text: $linkDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Ink.chip))
                    .onSubmit { store.addLinks(linkDraft); linkDraft = "" }
                if !linkDraft.isEmpty {
                    Button { store.addLinks(linkDraft); linkDraft = "" } label: {
                        Text("Add").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.teal)
                    }.buttonStyle(.plain)
                }
                Button { store.suggestExamples(prompt: store.loopTask) } label: {
                    Text(store.suggestState == "searching" ? "Searching…" : "Suggest")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.violet)
                }
                .buttonStyle(.plain)
                .disabled(store.suggestState == "searching")
                .help("Search the web from the task text")
            }

            if !store.loopLinks.isEmpty {
                // Wraps rather than scrolling sideways: a chip you cannot see
                // is a link you cannot remove.
                LinkChipFlow(links: store.loopLinks) { url in
                    store.loopLinks.removeAll { $0 == url }
                }
            }

            // Three honest states, and never a fourth: searching, nothing
            // found, or the real reason it failed. No URL is ever made up
            // here — the list is only ever what the engine returned.
            if store.suggestState == "empty" {
                Text("Nothing found for that prompt.")
                    .font(.system(size: 11)).foregroundStyle(Ink.dim)
            } else if store.suggestState != "" && store.suggestState != "searching" {
                Text(store.suggestState)
                    .font(.system(size: 11)).foregroundStyle(Ink.red)
                    .lineLimit(1).truncationMode(.middle)
            }

            if !store.suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.suggestions) { row in
                            Button {
                                store.addLinks(row.url)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 11)).foregroundStyle(Ink.teal)
                                    Text(row.title).font(.system(size: 11))
                                        .foregroundStyle(Ink.text).lineLimit(1)
                                    Text(row.host).font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Ink.dim).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 58)
            }
        }
    }

    /// Who runs each node — the answer `pong wire plan` gives for the picked
    /// owner, kind and task, before anything is spawned. Hover a row for why
    /// the other platforms were not chosen. Read-only on purpose: a pin is a
    /// `--pin` on the CLI until the map's composer lands.
    private var wiringRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Runs on")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.second)
                Spacer(minLength: 0)
                if store.wiringState == "planning" {
                    Text("wiring…").font(.system(size: 11)).foregroundStyle(Ink.dim)
                } else if !store.wiringState.isEmpty {
                    Text(store.wiringState).font(.system(size: 11))
                        .foregroundStyle(Ink.red).lineLimit(1).truncationMode(.middle)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if store.wiring.isEmpty && store.wiringState.isEmpty {
                        Text("Pick who and say what — each node gets a platform, with the reason.")
                            .font(.system(size: 11)).foregroundStyle(Ink.dim)
                    }
                    ForEach(store.wiring) { w in
                        HStack(spacing: 6) {
                            Text(w.id).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Ink.second)
                                .frame(width: 46, alignment: .leading)
                            chip(w.runtime.isEmpty
                                 ? "unwired"
                                 : (w.model.isEmpty ? w.runtime : "\(w.runtime) · \(w.model)"))
                            Text(w.why).font(.system(size: 11))
                                .foregroundStyle(w.conflict.isEmpty ? Ink.text : Ink.amber)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .help(w.rejected.isEmpty
                              ? w.why
                              : w.why + "\n\nWhy not:\n" + w.rejected.joined(separator: "\n"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Store.loopWiringHeight - 18)
        }
    }

    /// Re-plan from what is lit: the same lead rule the argv uses, so the
    /// preview and the start cannot name two different owners.
    private func planWiring() {
        let mains = store.island.orgMains
        let picked = loopWho.filter { id in mains.contains { $0.id == id } }
        let owner = LoopArgs.lead(picked: picked, conductor: store.island.conductor?.id ?? "")
        store.planWiring(kind: loopKind, owner: owner, task: store.loopTask)
    }

    private var loopPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(["fan", "cycle", "gauntlet"], id: \.self) { k in
                    Button { loopKind = k } label: {
                        Text(["fan": "Split up", "cycle": "Build and review", "gauntlet": "Meet the bar"][k] ?? k.capitalized)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(loopKind == k ? Ink.text : Ink.second)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(loopKind == k ? Ink.chip : Color.clear))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            whoRow

            TextField("What should it do?", text: $store.loopTask)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Ink.text)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Ink.chip))

            wiringRow

            linksRow

            HStack(spacing: 8) {
                switch loopKind {
                case "fan":
                    Text("Parts").font(.system(size: 11)).foregroundStyle(Ink.second)
                    // Capped at the engine's own FAN_CAP so the UI cannot offer
                    // a number `goal start` would refuse.
                    Stepper(value: $loopPieces, in: 1...Store.fanCap) {
                        Text("\(loopPieces)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.text)
                    }.fixedSize()
                case "cycle":
                    Text("Max rounds").font(.system(size: 11)).foregroundStyle(Ink.second)
                    Stepper(value: $loopRounds, in: 1...9) {
                        Text("\(loopRounds)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.text)
                    }.fixedSize()
                default:
                    Text("Quality bar").font(.system(size: 11)).foregroundStyle(Ink.second)
                    Menu {
                        ForEach(Store.barPaths, id: \.self) { p in
                            Button((p as NSString).lastPathComponent) { loopBar = p }
                        }
                    } label: {
                        chip(loopBar.isEmpty
                             ? "pick a bar"
                             : (loopBar as NSString).lastPathComponent)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Spacer(minLength: 0)
                Button {
                    // The draft is NOT cleared here. It used to be, which threw
                    // away what someone typed the moment a start was refused —
                    // the one time they most need it back. startLoop clears it
                    // only once the engine has accepted the loop.
                    store.startLoop(kind: loopKind, who: loopWho,
                                    task: store.loopTask,
                                    pieces: loopPieces, maxRounds: loopRounds,
                                    bar: loopBar.isEmpty ? nil : loopBar)
                } label: {
                    Text(store.loopBusy ? "Starting…" : "Start")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.bg)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Ink.teal))
                }
                .buttonStyle(.plain)
                .disabled(store.loopBusy)
            }

            if let err = store.loopError {
                Text(err)
                    .font(.system(size: 11)).foregroundStyle(Ink.red)
                    .lineLimit(1).truncationMode(.middle)
            }

            // Running loops. Scrolls inside the fixed panel so a busy team does
            // not push the sheet — and therefore the composer — around.
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if store.loops.isEmpty {
                        Text("No loops yet.")
                            .font(.system(size: 11)).foregroundStyle(Ink.dim)
                    }
                    ForEach(store.loops) { g in
                        HStack(spacing: 7) {
                            Text(g.kind).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(g.live ? Ink.violet : Ink.dim)
                            Text(g.owner).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Ink.second)
                            // The state is on the row, so a stopped loop reads
                            // as stopped rather than looking live.
                            chip(g.live ? "\(g.nodes) nodes" : "cancelled")
                            Spacer(minLength: 0)
                            // Stop and Delete are different things: Stop ends
                            // the run and keeps the record, Delete forgets it.
                            // Stop is offered only while there is something to
                            // stop; Delete is always offered, which is what
                            // makes a cancelled leftover clearable.
                            if g.live {
                                Button { store.cancelLoop(id: g.id) } label: {
                                    Text("Stop").font(.system(size: 11))
                                        .foregroundStyle(Ink.amber)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.loopBusy)
                            }
                            Button { store.deleteLoop(id: g.id) } label: {
                                Text("Delete").font(.system(size: 11))
                                    .foregroundStyle(Ink.dim)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.loopBusy)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .frame(height: Store.loopPanelHeight - Store.loopBarChrome, alignment: .top)
        .onAppear { planWiring() }
        .onChange(of: store.loopTask) { _ in planWiring() }
        .onChange(of: loopKind) { _ in planWiring() }
        .onChange(of: loopWho) { _ in planWiring() }
    }

    private var chatBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !drops.isEmpty {
                HStack(spacing: 6) {
                    ForEach(drops, id: \.self) { u in
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip").font(.system(size: 11))
                            Text(u.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            Button { drops.removeAll { $0 == u } } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            }.buttonStyle(.plain)
                        }
                        .foregroundStyle(Ink.second)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Ink.chip))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 9)
            }

            // Bottom-aligned: once the field is several lines tall the glyph and
            // the chip belong beside the line you are typing on, not floating in
            // the middle of the block.
            HStack(alignment: .bottom, spacing: 9) {
                Image(systemName: dropping ? "tray.and.arrow.down.fill" : "arrow.turn.down.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(dropping ? Ink.teal : Ink.dim)
                    .padding(.bottom, 2)
                // Takes every point left over rather than sharing the row with a
                // Spacer. Measured: the Spacer only cost about 9pt of 470, so it
                // was never the reason text ran off the end — the caret was, once
                // the draft grew past the visible box. This scrolls instead.
                GrowingComposer(
                    text: $draft,
                    placeholder: dropping ? "Drop to attach" : "Message the lead…",
                    onSubmit: send,
                    onHeightChange: { store.setComposerHeight($0) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: store.composerHeight)
                .focused($chatFocused)
                if !draft.isEmpty || !drops.isEmpty {
                    Button {
                        draft = ""; drops = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
                // whom this writes to: a team's lead, picked here (the header no longer picks a team)
                Menu {
                    ForEach(isl.teams) { t in
                        Button { store.preferred = t.id; store.refresh() } label: { Text(t.name) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("To \(isl.teamName.isEmpty ? "a lead" : isl.teamName)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.second).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.dim)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Which team's lead this message goes to")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Ink.raised.opacity(dropping ? 0.9 : 0.6))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(dropping ? Ink.teal : Ink.hair),
                 alignment: .top)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // Must be simultaneous: a TextField consumes the tap itself, so a
            // plain onTapGesture on the row never fires and the panel never
            // becomes key — which is why typing did nothing.
            store.claimKeyboard()
            chatFocused = true
        })
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let kept = Pong.keep(url) else { return }
                    DispatchQueue.main.async { drops.append(kept) }
                }
            }
            return true
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isl.session.isEmpty, !(t.isEmpty && drops.isEmpty) else { return }
        // Paths, not contents: the agent reads the file itself, so a 4MB
        // screenshot never goes through a job payload.
        let files = drops.map(\.path).joined(separator: "\n")
        let body = drops.isEmpty ? t
                 : (t.isEmpty ? "Look at these files:\n\(files)"
                              : "\(t)\n\nAttached:\n\(files)")
        Pong.say(body, isl.session, to: isl.conductor?.id ?? "c1")
        draft = ""; drops = []; store.refresh()
    }
}


/// The chat input, as AppKit rather than SwiftUI.
/// The composer: full width, grows with the text, then scrolls.
///
/// SwiftUI's `TextField(axis: .vertical)` grows and caps correctly — measured at
/// 16pt for one line, 48 for three, 96 at the six-line cap and no further. What
/// it does not give is a guarantee about the caret once the text is taller than
/// the cap, and "the last characters disappear while you type" is the whole
/// complaint. An NSTextView inside an NSScrollView does: the scroll view owns
/// the clipping, and `scrollRangeToVisible` keeps the insertion point on screen
/// no matter how long the draft gets.
///
/// Return sends, Shift-Return breaks the line — handled here rather than left to
/// `onSubmit`, because a text view treats Return as an ordinary newline.
struct GrowingComposer: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    /// Reports the height the text currently wants, uncapped. The Store owns
    /// the ceiling (`composerCeiling`); this only measures.
    var onHeightChange: (CGFloat) -> Void

    static let lineHeight: CGFloat = 16

    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed

        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 0, height: 1)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.onSubmit = { onSubmit() }
        tv.placeholder = placeholder
        tv.string = text

        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        tv.placeholder = placeholder
        // Only write back when they differ, or every keystroke resets the caret
        // to the end of the string.
        if tv.string != text {
            tv.string = text
            context.coordinator.reportHeight()
        }
    }

    final class Coord: NSObject, NSTextViewDelegate {
        var parent: GrowingComposer
        weak var textView: ComposerTextView?
        init(_ p: GrowingComposer) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            tv.needsDisplay = true      // repaint the placeholder
            reportHeight()
            tv.scrollRangeToVisible(tv.selectedRange())
        }

        /// Height the text actually wants. Not capped here.
        ///
        /// This used to clamp to a line cap before reporting, so the Store was
        /// told a lie and a draft past that many lines was clipped rather than
        /// scrolled. Measuring and deciding are now separate jobs: the text
        /// view measures — `usedRect` is what the layout manager already knows
        /// exactly — and `Store.setComposerHeight` decides how much of it to
        /// draw. Past that, the NSScrollView this text view already sits in
        /// scrolls, which is what makes the field keep every line instead of
        /// losing the ones past the cap.
        func reportHeight() {
            guard let tv = textView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            parent.onHeightChange(max(GrowingComposer.lineHeight, used))
        }
    }
}

/// Text view that sends on Return and draws its own placeholder.
final class ComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var placeholder: String = ""

    override func keyDown(with event: NSEvent) {
        // 36 is Return. Shift-Return falls through to the normal newline.
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(0.34),
        ]
        placeholder.draw(at: NSPoint(x: 0, y: 1), withAttributes: attrs)
    }
}

struct NativeField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onFocus: () -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = FocusReportingField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.textColor = .white
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.onMouseDown = onFocus
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
    }

    final class Coord: NSObject, NSTextFieldDelegate {
        let parent: NativeField
        init(_ p: NativeField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
        }
        func control(_ c: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(); return true
            }
            return false
        }
    }
}

/// Clicking must both focus the field AND tell the app to become active — an
/// accessory app gets no key events until it does.
final class FocusReportingField: NSTextField {
    var onMouseDown: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Panel + store ---------------------------------------------------

/// Borderless panels refuse the keyboard by default, which is why the chat bar
/// could not be typed in. See the styleMask note in the delegate: it
/// takes focus only when you click a field, and never just because it is there.
/// Only the island itself takes the mouse. Everywhere else in this (large,
/// fixed) window the click goes straight through to whatever is underneath —
/// otherwise a transparent panel would silently eat your menu bar.
final class PassThroughHost: NSHostingView<IslandView> {
    /// Screen-space rect of the visible silhouette. Everything outside it is a
    /// transparent part of the window that must behave as though it is not there.
    var silhouetteInScreen: () -> NSRect = { .zero }

    /// Without this the panel never takes the keyboard: becomesKeyOnlyIfNeeded
    /// asks the clicked view whether it needs key, and NSHostingView does not
    /// answer. That is why the chat bar swallowed every keystroke.
    override var needsPanelToBecomeKey: Bool { true }

    /// Deliver the FIRST click instead of eating it to become key. Without this
    /// the chat bar needs two clicks — one to focus the window, one to act —
    /// and since hovering away collapses the island, the second never comes.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Let clicks outside the silhouette fall through to whatever is beneath.
    ///
    /// This class was already called PassThroughHost but did not pass anything
    /// through — it only fixed key handling. That was survivable while the
    /// window shrank to the size of the collapsed pill; now that the window is
    /// permanently the full box, without this it would be an invisible slab
    /// sitting over the middle of the menu bar eating every click on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        // Borderless window: the content view fills it, so the point arrives in
        // window coordinates.
        let onScreen = window.convertPoint(toScreen: point)
        guard silhouetteInScreen().contains(onScreen) else { return nil }
        return super.hitTest(point)
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Store: ObservableObject {
    @Published var island = Island()
    @Published var expanded = false
    // Gate cards. The draft lives here, not in the view: leaving the sheet clears view state.
    @Published var gateDraft: [String: String] = [:]
    @Published var gateEditing: String?
    @Published var gateBusy: Set<String> = []
    @Published var gateMsg: [String: String] = [:]
    @Published var gateConfirmStop: String?
    @Published var gateRetry: [String: String] = [:]     // gate id -> the outcome to resend with --extend 1
    @Published var gateToast: String?
    @Published var gateToastWarn = false
    /// Answer clicks on a card are ignored briefly after its layout changed under the pointer.
    private var gateQuietUntil: [String: Date] = [:]
    private var gateArmedAt: [String: Date] = [:]
    /// Answered gates, hidden until the snapshot (rewritten every ~15 s) stops listing them.
    private var answeredGates: [String: Date] = [:]

    /// Questions whose "Details" are open. Folded by default: the island is small, the app shows them open.
    @Published var detailOpen: Set<String> = []

    func toggleDetail(_ id: String) {
        if detailOpen.contains(id) { detailOpen.remove(id) } else { detailOpen.insert(id) }
    }

    /// Edit pressed, or the note field clicked: show the field and take the keyboard.
    func startGateNote(_ g: GateItem) {
        if gateEditing != g.id { gateQuietUntil[g.id] = Date().addingTimeInterval(0.6) }
        gateEditing = g.id
        claimKeyboard()
    }

    /// Approve, send back, or pick a route: `pong -s <team> goal resume --id --node --outcome [--note=]`.
    /// An answer's word as the app's question card says it.
    static func answerWord(_ outcome: String) -> String {
        switch outcome {
        case "approved": return "Approve"
        case "rejected": return "Send back"
        default:
            let w = outcome.replacingOccurrences(of: "route:", with: "").replacingOccurrences(of: "-", with: " ")
            return w.prefix(1).uppercased() + w.dropFirst()
        }
    }

    func answerGate(_ g: GateItem, outcome: String, extend: Bool = false) {
        if let quiet = gateQuietUntil[g.id], Date() < quiet { return }  // a click meant for the button that moved
        let note = (gateDraft[g.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome == "rejected" && note.isEmpty {
            gateMsg[g.id] = "Say what should change first — your note goes to the step that redoes it."
            startGateNote(g)
            return
        }
        var argv = ["-s", g.session, "goal", "resume", "--id", g.graphId, "--node", g.node, "--outcome", outcome]
        if !note.isEmpty { argv.append("--note=" + note) }  // one word: a note starting with "-" is not a flag
        if extend { argv += ["--extend", "1"] }
        runGate(g, argv, outcome: outcome, stops: false)
    }

    /// A chat's question: `pong ask answer`; the answer goes back into the chat as news.
    func answerAsk(_ a: AskItem, choice: String) {
        guard !gateBusy.contains(a.id) else { return }
        let note = (gateDraft[a.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var argv = ["-s", a.session, "ask", "answer", "--id", a.id]
        if !choice.isEmpty { argv += ["--choice", choice] }
        if !note.isEmpty { argv.append("--note=" + note) }
        gateBusy.insert(a.id)
        gateMsg[a.id] = nil
        Store.log("ask \(a.id): answer \(choice)")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Pong.runShowingErrors(argv, clean: true)
            DispatchQueue.main.async {
                self.gateBusy.remove(a.id)
                if r.ok {
                    self.gateDraft[a.id] = nil
                    self.refresh()
                } else {
                    // the engine's own sentence, else plain words; what it said goes to the log
                    let said = Store.errorLine(r.err) ?? Store.firstLine(r.out) ?? "(no error text)"
                    Store.log("ask \(a.id): answer failed: " + String((said.components(separatedBy: "pong -s").first ?? "").prefix(300)))
                    self.gateMsg[a.id] = PongCheck.sentence(r.err.isEmpty ? r.out : r.err)
                        ?? PongCheck.answerRefusal(said)?.words
                        ?? "Your answer didn't reach the chat. Try again in a moment."
                }
            }
        }
    }

    /// Refuse = stop the whole run, after a second click at least 0.6 s later. The graph stays as history.
    func refuseGate(_ g: GateItem) {
        if gateConfirmStop == g.id, let armed = gateArmedAt[g.id], Date().timeIntervalSince(armed) >= 0.6 {
            runGate(g, ["-s", g.session, "goal", "cancel", "--id", g.graphId], outcome: "cancel", stops: true)
            return
        }
        if gateConfirmStop == g.id { return }  // the second half of a double-click: not a confirmation
        gateConfirmStop = g.id
        gateArmedAt[g.id] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.gateConfirmStop == g.id { self?.gateConfirmStop = nil }
        }
    }

    func runGate(_ g: GateItem, _ argv: [String], outcome: String, stops: Bool) {
        guard !gateBusy.contains(g.id) else { return }
        gateBusy.insert(g.id)
        gateMsg[g.id] = nil
        gateRetry[g.id] = nil
        // the note itself stays out of the log
        Store.log("gate \(g.id): " + argv.filter { !$0.hasPrefix("--note=") }.joined(separator: " "))
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Pong.runShowingErrors(argv, clean: true)
            DispatchQueue.main.async {
                self.gateBusy.remove(g.id)
                let err = Store.errorLine(r.err) ?? Store.firstLine(r.out) ?? "it failed and said nothing"
                let gone = !r.ok && err.contains("is not an open gate")
                if r.ok || gone {
                    let owned = self.gateEditing == g.id       // only the gate that holds the keyboard gives it back
                    self.answeredGates[g.id] = Date()
                    self.island.gates.removeAll { $0.id == g.id }
                    if self.gateConfirmStop == g.id { self.gateConfirmStop = nil }
                    if owned { self.gateEditing = nil; self.releaseKeyboard() }
                    if gone {
                        // answered somewhere else first: this answer was NOT sent, and the note is kept
                        let draft = (self.gateDraft[g.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !draft.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft, forType: .string)
                        }
                        self.showGateToast("\(g.title): already answered elsewhere — your answer was not sent"
                                           + (draft.isEmpty ? "." : " (your note is on the clipboard)."), warn: true)
                    } else {
                        self.gateDraft[g.id] = nil
                        self.showGateToast(stops ? "\(g.title): run stopped." : Store.resumedWords(g, outcome, r.out), warn: false)
                    }
                    self.refresh()
                } else {
                    // the engine's own sentence, else plain words; what it said goes to the log, without
                    // the command it suggests (that carries the note)
                    Store.log("gate \(g.id): failed: " + String((err.components(separatedBy: "pong -s").first ?? "").prefix(300)))
                    let refusal = stops ? nil : PongCheck.answerRefusal(err)
                    if refusal?.moreRounds == true { self.gateRetry[g.id] = outcome }
                    self.gateMsg[g.id] = PongCheck.sentence(r.err.isEmpty ? r.out : r.err)
                        ?? refusal?.words
                        ?? (stops ? "Couldn't stop the graph. Try again in a moment."
                            : "Your answer didn't reach the graph. Try again in a moment.")
                }
                self.layout()
            }
        }
    }

    private func showGateToast(_ t: String, warn: Bool) {
        gateToast = t
        gateToastWarn = warn
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.gateToast == t { self?.gateToast = nil; self?.layout() }
        }
    }

    /// "resumed g_1 round=1 status=running — me: rejected → plan" → "site-review: sent back to plan with your note."
    /// Reads status= and stop_reason= too: an answer that ended the run says so.
    static func resumedWords(_ g: GateItem, _ outcome: String, _ out: String) -> String {
        let line = firstLine(out) ?? ""
        func field(_ k: String) -> String {
            guard let r = line.range(of: k + "=") else { return "" }
            return String(line[r.upperBound...].prefix { !$0.isWhitespace })
        }
        let status = field("status"), stop = field("stop_reason")
        let tail = line.range(of: " — ").map { String(line[$0.upperBound...]) } ?? ""
        let to = tail.components(separatedBy: " → ").dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
        let ended = status != "" && status != "running"
        let why = (stop.isEmpty || stop == "win") ? "" : " (\(stop.replacingOccurrences(of: "_", with: " ")))"
        if tail.contains("no edge out") { return "\(g.title): \(outcome) — that ended the run\(why)." }
        switch outcome {
        case "approved":
            return ended || to == "end" || to.isEmpty ? "\(g.title): approved — the run is done\(why)." : "\(g.title): approved — on to \(to)."
        case "rejected":
            return ended || to == "end" ? "\(g.title): sent back — the run ended\(why)." : "\(g.title): sent back to \(to) with your note."
        default:
            return ended ? "\(g.title): \(outcome) — the run ended\(why)." : "\(g.title): \(outcome)" + (to.isEmpty ? "." : " → \(to).")
        }
    }

    /// The refusal pong printed: its last "error:" line, without the prefix.
    static func errorLine(_ s: String) -> String? {
        let lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let e = lines.last(where: { $0.contains("error:") }) else { return nil }
        let t = e.range(of: "error:").map { String(e[$0.upperBound...]) } ?? e
        let out = t.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? nil : out
    }

    private func dropAnswered(_ s: inout Island) {
        let now = Date()
        // keyed by the gate's visit (graph:node:opened-at): the same gate opening again is a new card
        answeredGates = answeredGates.filter { now.timeIntervalSince($0.value) < 180 }
        let hidden = s.gates.filter { answeredGates[$0.id] != nil }
        s.gates.removeAll { answeredGates[$0.id] != nil }
        if !hidden.isEmpty {
            s.teams = s.teams.map { t in
                let n = hidden.filter { $0.session == t.id }.count
                return n == 0 ? t : TeamRef(id: t.id, name: t.name, busy: t.busy, needsYou: max(0, t.needsYou - n))
            }
        }
        if let e = gateEditing, !s.gates.contains(where: { $0.id == e }) { gateEditing = nil }
    }
    var preferred: String?
    /// Pointer came in. Expand immediately and cancel any pending collapse.
    func enter() {
        cancelExit()
        guard !expanded else { return }
        // Against the CUTOUT — not the window, and no longer the silhouette.
        // The window is the full 504x520 box, so "the pointer is over our
        // hosting view" means "somewhere in a large piece of transparent air".
        // Narrowing that to the silhouette was the previous fix and it was not
        // enough: the silhouette is both ears too, padded, which still spans
        // the middle of the menu bar. Only the camera cutout is a region
        // nothing else is trying to use, so only the cutout opens the island.
        let m = NSEvent.mouseLocation
        let hit = expandHitRect
        guard hit.contains(m) else {
            Store.log(String(format: "enter refused — cursor %.0f,%.0f outside notch %@",
                             m.x, m.y, NSStringFromRect(hit)))
            return
        }
        Store.log(String(format: "enter — cursor %.0f,%.0f in notch %@",
                         m.x, m.y, NSStringFromRect(hit)))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { expanded = true }
        expandedChanged()
    }

    /// Pointer left the sheet. Start the grace period — once.
    ///
    /// This used to bump a token and re-arm on every call, which is fine when
    /// the only caller is a one-shot hover event and fatal now that a timer
    /// calls it ten times a second: each call pushed the deadline back, so the
    /// collapse never arrived and the sheet only ever closed because the watch
    /// was torn down. Scheduling once and letting `exitAt` identify the pending
    /// collapse makes repeated calls harmless.
    func requestExit() {
        guard expanded, exitAt == nil else { return }
        let at = Date().addingTimeInterval(Store.exitDelay)
        exitAt = at
        Store.log(String(format: "exit scheduled — collapsing in %.1fs unless the pointer returns",
                         Store.exitDelay))
        DispatchQueue.main.asyncAfter(deadline: .now() + Store.exitDelay) { [weak self] in
            guard let self, self.exitAt == at, self.expanded else { return }
            self.exitAt = nil
            // Against the SILHOUETTE, not the window. The window is now always
            // the full box, so testing it would say the pointer is still inside
            // whenever it is anywhere near the top of the screen — and the
            // island would never collapse again.
            let m = NSEvent.mouseLocation
            if self.hoverRect.contains(m) {
                Store.log(String(format: "exit cancelled — pointer came back to %.0f,%.0f", m.x, m.y))
                return
            }
            Store.log(String(format: "exit confirmed after %.1fs — cursor %.0f,%.0f, outside %@",
                             Store.exitDelay, m.x, m.y, NSStringFromRect(self.hoverRect)))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.expanded = false }
            self.expandedChanged()
        }
    }
    /// When the pending collapse is due, or nil when none is pending. Doubles
    /// as the identity of that collapse, so a cancelled or re-armed one cannot
    /// be fired by an older block still sitting in the queue.
    private var exitAt: Date?
    private var pointerWatch: Timer?

    /// The pointer came back onto the island — call off the collapse.
    func cancelExit() {
        guard exitAt != nil else { return }
        exitAt = nil
        Store.log(String(format: "exit cancelled — pointer returned before the %.1fs was up",
                         Store.exitDelay))
    }

    /// Set while a `forceExpand()` is holding the sheet open against the exit
    /// path, until the pointer reaches it once or the grace ceiling fires.
    private var awaitingFirstEntry = false
    /// Identity of the current forced open, so an older ceiling block cannot
    /// release a newer hold. Same trick as `exitAt`.
    private var forcedOpenAt: Date?

    /// End the forced-open hold and say why. Normal collapse rules resume.
    private func releaseForcedHold(_ why: String) {
        guard awaitingFirstEntry else { return }
        awaitingFirstEntry = false
        forcedOpenAt = nil
        Store.log("forced open — hold released (\(why))")
    }

    /// Open from the map's Island pill rather than from the pointer.
    ///
    /// The trap this exists to avoid: `pointerWatch` ticks every 0.10s, and at
    /// the moment this runs the cursor is down on the map toolbar, far outside
    /// the expanded sheet. The very next tick would call `requestExit()` and
    /// the island would collapse a second later — before anyone could move the
    /// mouse up to it. So the exit path is suppressed until the pointer has
    /// been inside the sheet once.
    ///
    /// The hold is bounded on purpose. If the pointer never arrives — a stray
    /// click, or a changed mind — the island must not sit open across the notch
    /// forever, so `forcedOpenGrace` releases it and the ordinary rules take it
    /// from there. Both endings are logged, because "why is it still open" is
    /// otherwise unanswerable from outside the process. The Collapse menu item
    /// keeps working throughout: it sets `expanded` directly, and the watch
    /// drops the hold as soon as it sees the sheet closed.
    func forceExpand() {
        cancelExit()
        let token = Date()
        forcedOpenAt = token
        awaitingFirstEntry = true
        if expanded {
            // Already open — do not re-animate, just re-arm the hold so a pill
            // press while the sheet is on its way out keeps it.
            Store.log("forceExpand — already open, re-arming the hold")
        } else {
            Store.log(String(format: "forceExpand — opening from the map, held until the pointer arrives (ceiling %.0fs)",
                             Store.forcedOpenGrace))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { expanded = true }
            expandedChanged()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Store.forcedOpenGrace) { [weak self] in
            guard let self, self.forcedOpenAt == token, self.awaitingFirstEntry else { return }
            self.releaseForcedHold("pointer never arrived")
            // Release only — no second collapse path. The next watch tick
            // applies the same rule as any other open sheet: collapse if the
            // pointer is away, leave it alone if it is not.
            self.followPointer()
        }
    }

    /// Follow the real cursor while it is anywhere over the island's window.
    ///
    /// SwiftUI's hover reports on the hosting view, and the window is now
    /// permanently the full box, so hover can only ever say "the pointer is
    /// somewhere in that 504x520 rectangle". Two things it therefore cannot
    /// tell us: that the pointer arrived on the ears after entering through the
    /// empty air beside them, and that it left the open sheet into that same
    /// air — it never left the view, so no exit is reported at all. The cursor
    /// position is the only thing that knows either, which is why the collapse
    /// path already trusted it. Now both ends do.
    /// Watch the real cursor for the life of the app.
    ///
    /// This used to be started and stopped by SwiftUI's `.onHover` on the window
    /// box, and the log shows why that had to go: with the cursor warped dead
    /// centre onto the island and then held perfectly still, `.onHover` reported
    /// "inside" again two seconds later having never reported a leave. It is
    /// edge triggered, the window is a mostly transparent 504x520 box, and the
    /// edges it reports are its own resizes as much as the pointer's movement.
    /// Miss the edge and nothing was polling, so a still hover sat on the island
    /// and did nothing — which is what made people wobble the mouse until one of
    /// the manufactured edges happened to land. A timer that always runs has no
    /// edge to miss. It costs one rect test per tick, against a snapshot poll
    /// that already runs every few seconds.
    func startPointerWatch() {
        guard pointerWatch == nil else { return }
        // .common so it keeps ticking while the mouse is being tracked.
        let t = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.followPointer()
        }
        RunLoop.main.add(t, forMode: .common)
        pointerWatch = t
        // All three rects, once, on the record, because they are deliberately
        // different and confusing them is the bug this lane keeps hitting:
        // opening is the cutout only, staying open is the sheet, and hitTest
        // still tests the silhouette so the ears keep taking clicks.
        Store.log(String(format: "pointer watch running — opens %@ / stays open %@ / clicks %@",
                         NSStringFromRect(expandHitRect),
                         NSStringFromRect(hoverRect),
                         NSStringFromRect(silhouetteRect)))
        followPointer()
    }

    /// Two different questions, so two different rects.
    ///
    /// Collapsed, the only question is "should this open", and the answer is
    /// the camera cutout alone (`expandHitRect`). Expanded, the question is
    /// "should this stay open", and that is judged against the whole sheet
    /// (`hoverRect`) — once it is open there is no reason to make someone keep
    /// the pointer parked in the little notch. Asking both questions of one
    /// rect is what made the collapsed hover zone span the menu bar.
    private func followPointer() {
        guard expanded else {
            // Closed by any route, including the Collapse menu item, ends the
            // hold — there is nothing left to hold open.
            releaseForcedHold("island collapsed")
            if expandHitRect.contains(NSEvent.mouseLocation) { enter() }
            return
        }
        if hoverRect.contains(NSEvent.mouseLocation) {
            releaseForcedHold("pointer arrived")
            cancelExit()
        } else if !awaitingFirstEntry && !(gateEditing != nil && panel?.isKeyWindow == true) {
            requestExit()                 // once, and it re-confirms itself
        }                                 // (never under someone typing a gate note)
    }

    func expandedChanged() {
        // Window follows the silhouette (grows down from the notch). Must run
        // here or the hosting view sizes us to leftover content and the top
        // edge lifts off the screen.
        layout()
        schedule()
        if expanded { refresh() } else { gateEditing = nil; gateConfirmStop = nil; releaseKeyboard() }
    }

    /// Claim the keyboard only when someone clicks into a field, and hand it
    /// straight back when the island closes. An accessory app that is never
    /// active gets no keystrokes at all, so this has to be explicit.
    func claimKeyboard() {
        // An LSUIElement / .accessory app is not a normal citizen of the
        // activation system: NSApp.activate is frequently ignored for it, which
        // is why four separate keyboard fixes changed nothing. Becoming .regular
        // for the moment you are typing makes activation actually take, and we
        // drop straight back so no Dock icon lingers.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        Self.log("claim: active=\(NSApp.isActive) key=\(panel?.isKeyWindow == true) policy=regular")
    }

    /// Append one line to ~/.pong/island.log. Guessing about focus has cost four
    /// rounds; this makes the next answer evidence instead of a theory.
    static func log(_ m: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(m)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.pong/island.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    func releaseKeyboard() {
        guard let panel else { return }
        if panel.isKeyWindow {
            panel.resignKey()
            // Hand focus back to whatever was in front — WITHOUT hiding ourselves.
            // NSApp.hide(nil) hides every window this app owns, which is why the
            // island vanished the moment you clicked away to type.
            NSApp.deactivate()
        } else if NSApp.activationPolicy() == .accessory {
            return
        }
        // Always back to accessory: leaving by clicking another app took the key
        // away first, and the island stayed a regular app with a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        panel.orderFrontRegardless()
        Self.log("release: back to accessory")
    }
    weak var panel: NSPanel?
    private var timer: Timer?

    func start() {
        refresh()
        schedule()
        startPointerWatch()
    }

    /// How long a line sits before the next one takes the ear, and how long
    /// the hand-off takes. Two seconds is enough to read four words without
    /// making you wait on the one line you actually want.
    static let tickerHold: TimeInterval = 2.0
    static let tickerSlide: TimeInterval = 0.28

    /// Off unless PONG_ISLAND_DEBUG is set. Things that repeat — the ear moving
    /// on a timer, a layout that lands on the same numbers again — are invisible
    /// from outside the process and are exactly what you want to see while
    /// checking them, and exactly what nobody wants in the log the rest of the
    /// time. This is the switch between those two.
    static let debugLogging = ProcessInfo.processInfo.environment["PONG_ISLAND_DEBUG"] != nil
    static let tickerLogPath =
        (("~/.pong/island-ticker.log") as NSString).expandingTildeInPath
    static func tickerLog(_ m: String) {
        guard debugLogging else { return }
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + m + "\n"
        if let h = FileHandle(forWritingAtPath: tickerLogPath) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: tickerLogPath, atomically: true, encoding: .utf8)
        }
    }

    /// Which line the ear is on, and the clock that advances it.
    @Published private(set) var tickerIndex = 0
    private var tickerTimer: Timer?

    /// Keep the rotation honest across polls: the list is rebuilt every refresh,
    /// so the index can fall off the end, and a list that shrinks to one must
    /// stop moving. A single message holds still — a loop of one is just a
    /// flicker that makes you look at nothing.
    private func syncTicker() {
        let n = island.tickerLines.count
        if tickerIndex >= n { tickerIndex = 0 }
        guard n > 1 else {
            if tickerTimer != nil { Store.tickerLog("rotation stop (\(n) line(s) — holding)") }
            tickerTimer?.invalidate(); tickerTimer = nil
            return
        }
        guard tickerTimer == nil else { return }
        Store.tickerLog("rotation start (\(n) lines, \(Store.tickerHold)s hold)")
        tickerTimer = Timer.scheduledTimer(
            withTimeInterval: Store.tickerHold, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            let n = self.island.tickerLines.count
            guard n > 1 else { self.syncTicker(); return }
            withAnimation(.easeInOut(duration: Store.tickerSlide)) {
                self.tickerIndex = (self.tickerIndex + 1) % n
            }
            Store.tickerLog("ear -> [\(self.tickerIndex)] \(self.tickerLine?.text ?? "")")
        }
    }

    /// How long the open sheet waits, after the pointer leaves it, before it
    /// collapses. The old 0.18s was a debounce against a spurious exit, not a
    /// grace period — the sheet vanished the instant you looked away, so there
    /// was no way to move off it and take a screenshot. The 2s that replaced it
    /// went too far the other way — too long to sit through on every glance —
    /// so this is now one second. Coming back inside cancels it.
    static let exitDelay: TimeInterval = 1.0

    /// Ceiling on the hold that `forceExpand()` puts on the exit path.
    ///
    /// The hold normally ends the moment the pointer reaches the sheet. This is
    /// what ends it when the pointer never comes — a stray click on the map's
    /// Island pill must not leave the island open across the notch forever.
    static let forcedOpenGrace: TimeInterval = 10

    /// Fast while you are looking or while work is live; lazy otherwise.
    /// A status dot for an idle team does not need four updates a second.
    private func schedule() {
        let quiet = !expanded && island.working.isEmpty && island.approvals.isEmpty && island.attention.isEmpty
            && !island.chiefThinking
        let want: TimeInterval = expanded ? 2.0 : (quiet ? 10.0 : 4.0)
        if abs((timer?.timeInterval ?? -1) - want) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: want, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let want = preferred
        let expandedNow = expanded
        DispatchQueue.global(qos: .utility).async {
            var s = Pong.snapshot(preferred: want, wantTail: expandedNow)
            DispatchQueue.main.async {
                self.dropAnswered(&s)
                self.island = s; self.schedule(); self.syncTicker(); self.layout()
            }
        }
    }

    /// ONE frame, set once. The window never moves.
    ///
    /// The flicker was an oscillation: collapsed sat in the notch, expanded
    /// jumped below the menu bar, and the two frames did not overlap where the
    /// cursor was. Expanding pulled the window out from under the mouse, hover
    /// went false, it collapsed back under the mouse, and round it went.
    ///
    /// So the panel is now always the full expanded box, anchored at the notch.
    /// Only the CONTENT changes size. Nothing can move out from under you.
    /// Where the black silhouette actually is on screen right now.
    ///
    /// This is what the window frame used to be. It is still the shape you see
    /// and the only region that should take a click; the window around it is now
    /// a fixed, transparent box.
    var silhouetteRect: NSRect {
        guard let screen = Notch.host else { return .zero }
        let full = screen.frame
        let w = expanded ? Store.maxWidth
                         : (notchWidth + earWidth * 2 + Notch.shoulder * 2)
        let h = visibleHeight
        return NSRect(x: full.midX - w / 2, y: full.maxY - h, width: w, height: h)
    }

    /// The zone that keeps an ALREADY-OPEN sheet open — silhouette plus 4pt.
    ///
    /// This used to pad the COLLAPSED silhouette too: 12pt below the chin and
    /// 6pt past each ear, so that stopping the cursor in the neighbourhood
    /// opened the island rather than having to be walked onto it. That pad is
    /// gone and must not come back. It is the accident people kept hitting: the
    /// collapsed silhouette is both ears plus the notch, and padded out it
    /// became a strip lying across the menu bar and the top of the map window,
    /// so reaching for a menu opened the island. Opening is now
    /// `expandHitRect` — the camera cutout, nothing else.
    ///
    /// What survives is 4pt of forgiveness, which is not a target-widener: the
    /// open sheet is large, and 4pt only has to cover the pixel the pointer
    /// straddles on the boundary, so a cursor resting exactly on the edge does
    /// not flicker the sheet shut.
    ///
    /// HOVER ONLY. Clicks are still tested against `silhouetteRect` in the
    /// panel's `hitTest`, so this zone never becomes a slab that eats a click
    /// meant for the window underneath.
    var hoverRect: NSRect {
        let r = silhouetteRect
        guard !r.isEmpty else { return r }
        return r.insetBy(dx: -4, dy: -4)
    }

    /// The zone that OPENS the island: the hardware camera cutout, and nothing
    /// else.
    ///
    /// Expanding used to test `hoverRect`, which is why the island opened by
    /// accident all day — see the note there. This is deliberately the smallest
    /// honest target: notch width by chin height, centred on the host screen,
    /// hard against the top edge. **No ears and no padding.** Padding is what
    /// put the trigger under the menus, so adding any back here reintroduces
    /// the bug.
    ///
    /// On a Mac with no notch `notchWidth` already falls back to a believable
    /// stand-in (`Notch.width`, 190pt), so this stays a reachable target there
    /// without a second special case.
    ///
    /// EXPANSION ONLY, and only while collapsed. Clicks still test
    /// `silhouetteRect`, so the ears keep drawing the orb and the ticker and
    /// keep taking a click — they just stop opening the sheet. Once open,
    /// staying open and collapsing are judged against `hoverRect` on the
    /// expanded sheet, never against this.
    var expandHitRect: NSRect {
        guard let screen = Notch.host else { return .zero }
        let full = screen.frame
        let w = notchWidth
        let h = chin
        return NSRect(x: full.midX - w / 2, y: full.maxY - h, width: w, height: h)
    }

    /// The window never changes size. Only the silhouette inside it does.
    ///
    /// It used to resize on every expand, and the log shows what that cost: one
    /// hover produced 308x35 → 504x414, then a second, UNANIMATED snap to
    /// 504x482 a beat later when a background refresh landed and called this
    /// again. So an AppKit frame animation (0.20s easeOut) was running against a
    /// SwiftUI spring (0.42s) on the same visual, and then got cut mid-flight by
    /// a hard setFrame. That is the flicker, and no amount of tuning the two
    /// curves fixes a third thing interrupting them.
    ///
    /// Pinning the frame to the full box removes all of it: nothing to animate,
    /// nothing to interrupt, and the top edge can never lift off the menu bar
    /// because it never moves. The growth is now purely SwiftUI's, on a shape
    /// that already knows how to interpolate.
    func layout() {
        guard let panel, Notch.host != nil else { return }
        // Silhouette-sized, top edge glued to the screen. Animate:false — an
        // AppKit frame animation fighting the SwiftUI spring was the flicker.
        // Collapsed and expanded share the notch, so the cursor never sits
        // outside the window at the moment of expand.
        let target = silhouetteRect
        if panel.frame != target {
            panel.setFrame(target, display: true, animate: false)
        }
        // Only a change is news.
        //
        // The window is pinned, so w and h here are constants and this line
        // could never differ in them — it was writing one identical row per
        // snapshot poll, which is 87% of a 1.8MB log, and a burst of screen
        // reconfigurations turned that into 60 identical rows in a second.
        // Nothing in layout() is expensive once the frame matches: setFrame is
        // already skipped above, so the open-seek-write-close on every call WAS
        // the cost of that storm. Under PONG_ISLAND_DEBUG it still says
        // everything, because then the repeats are the thing being looked at.
        // w and h are the pinned window; `sheet` is what is actually drawn
        // inside it and what `silhouetteRect` hands to hitTest, and `comp` is
        // the composer's share of it. Those two are the numbers that move now,
        // so a layout line without them says nothing about whether the
        // composer fits.
        let note = "layout expanded=\(expanded) w=\(Int(target.width)) h=\(Int(target.height)) "
                 + "sheet=\(Int(visibleHeight)) comp=\(Int(composerHeight)) "
                 + "compCeil=\(Int(composerCeiling)) loop=\(Int(loopHeight)) "
                 + "rows=\(island.working.count) idle=\(island.idle.count) "
                 + "cards=\(island.approvals.count)"
        guard note != lastLayoutNote || Store.debugLogging else { return }
        lastLayoutNote = note
        Self.log(note)
    }

    /// The last layout line written, so an unchanged one can be dropped.
    private var lastLayoutNote = ""
    /// Body width. What the content actually occupies.
    static let bodyWidth: CGFloat = 470
    /// Window width — wider than the body so the outward shoulders have
    /// somewhere to be. This is why they kept rendering square: there was no
    /// room outside the body for a curve to exist in.
    static let shoulder: CGFloat = 17
    static let maxWidth: CGFloat = bodyWidth + shoulder * 2

    /// Used when there is no screen to ask — the old hardcoded ceiling.
    static let fallbackMaxHeight: CGFloat = 520
    /// Keep the sheet off the Dock rather than resting on it.
    static let bottomMargin: CGFloat = 24

    /// Ceiling on the drawn sheet: nearly the whole screen below the notch.
    ///
    /// This was 520, which is where the composer went. A full seat list and
    /// Conversation on More already want more than 520 before a single line is
    /// typed, so the sheet could not grow and the bottom child was drawn
    /// outside it. Derived rather than typed: the sheet hangs from the top of
    /// the screen, so the room it has is the distance from the screen's top
    /// edge down to the top of the Dock — `visibleFrame.minY` — less a margin.
    /// That follows a Dock that moves, hides or changes size, which a number
    /// tuned against one screenshot cannot.
    ///
    /// This does NOT change what opens the island: `expandHitRect` is
    /// `notchWidth` by `chin` and has nothing to do with this. Nor does it make
    /// the window eat clicks — the window is transparent outside the drawn
    /// silhouette and `hitTest` returns nil there, so a taller window passes
    /// through exactly as much as it did before, over more of the desktop.
    static var maxHeight: CGFloat {
        guard let screen = Notch.host else { return fallbackMaxHeight }
        let room = screen.frame.maxY - screen.visibleFrame.minY - bottomMargin
        // The floor is a sanity rail for an absurdly short display, not a
        // target; on any real Mac `room` wins.
        return max(320, floor(room))
    }

    /// The header strip, and the chrome around a one-line composer. Named
    /// because `visibleHeight` and `composerCeiling` must agree about them —
    /// two copies of 46 that drift is the same class of bug as two heights.
    static let headerChrome: CGFloat = 46
    static let composerChrome: CGFloat = 46
    /// Never let the composer take the whole sheet: a glimpse of the list has
    /// to survive a long paste, or the island stops being a status island.
    static let minListRoom: CGFloat = 80

    /// How tall the composer may draw before it scrolls inside itself.
    ///
    /// Replaces the old six-line cap, which clipped rather than scrolled: past
    /// six lines the text simply was not shown. The NSScrollView the composer
    /// already lives in handles the overflow, so the only thing needed here is
    /// a height at which to hand over to it — and that is a share of the
    /// sheet, not a line count.
    /// How tall the composer may draw before it scrolls inside itself.
    ///
    /// An instance property, not a static, because it has to subtract whatever
    /// else is pinned to the bottom right now. With the loop panel open the
    /// old static was 264pt too generous: header + loop panel + a maximal
    /// composer wanted 168pt more than the ceiling, and since both of those
    /// carry fixed frames the panel would have been squeezed into the composer
    /// rather than either of them scrolling. Subtracting `loopHeight` here
    /// keeps the same guarantee the composer already had — see `visibleHeight`.
    var composerCeiling: CGFloat {
        max(GrowingComposer.lineHeight,
            Store.maxHeight - Store.headerChrome - loopHeight - weeklyHeight
            - Store.composerChrome - Store.minListRoom)
    }

    // ---- loops -----------------------------------------------------------
    /// The always-visible trigger strip, and the panel it opens.
    ///
    /// Both are FIXED. `visibleHeight` adds exactly these, so what the sheet is
    /// drawn at and what `silhouetteRect` hands to `hitTest` cannot drift — the
    /// bug the comment in the expanded VStack is about. A panel that sized
    /// itself to its content would put that drift straight back, so the panel
    /// scrolls inside its own height instead.
    static let loopBarChrome: CGFloat = 32
    /// 330 before the Who row. The row adds its caption, the gap under it and
    /// `loopWhoHeight`; the panel is raised by exactly that so the running-loop
    /// list underneath keeps the room it had rather than being squeezed out of
    /// a panel that did not grow.
    static let loopPanelHeight: CGFloat = 508
    /// The "Runs on" block: a caption row plus two node rows that scroll.
    static let loopWiringHeight: CGFloat = 48
    /// Four rows of seat chips. Eight org mains pack into four rows at this
    /// width, so the usual roster is all visible at once and a larger one
    /// scrolls — the panel's height cannot move, so this cannot either.
    static let loopWhoHeight: CGFloat = 104

    @Published var showLoops = false { didSet { reclampComposer(); layout() } }
    @Published var loops: [LoopGraph] = []
    /// What the loop should do. Lives here rather than in the view so a
    /// refused start can leave it exactly as typed.
    @Published var loopTask = ""
    /// URLs the human pasted or picked. Each becomes its own `--example`.
    @Published var loopLinks: [String] = []
    @Published var suggestions: [ExampleRow] = []
    /// "" idle · "searching" · "empty" · anything else is the real error text.
    /// Kept as one value so the three honest states cannot contradict each
    /// other — a spinner and an error cannot both be showing.
    @Published var suggestState = ""
    /// One line, in the island. Never an alert: an accessory app throwing a
    /// modal over the menu bar is worse than the failure it reports.
    @Published var loopError: String?
    @Published var loopBusy = false

    /// Who will run each node, from the same solver `goal start` uses, so the
    /// preview cannot disagree with what actually gets spawned.
    @Published var wiring: [WiringRow] = []
    /// "" idle · "planning" · anything else is the real error text. One value,
    /// like `suggestState`, so a spinner and an error cannot both be showing.
    @Published var wiringState = ""
    private var wiringWork: DispatchWorkItem?
    static let wiringDebounce: TimeInterval = 0.35

    /// Open a graph in the app (session/id). CyberPong owns its window; the island only asks.
    func openGraph(_ key: String) {
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.owi.cyberpong.openGraph"), object: nil, userInfo: ["key": key], deliverImmediately: true)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded = false }
    }

    /// New graph: the app's own sheet ("What do you want done?"), the same way in as from the app.
    /// CyberPong owns it; the island only asks it to open.
    func openNewGraphInterview() {
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.owi.cyberpong.newGraph"), object: nil, userInfo: nil, deliverImmediately: true)
        Store.log("graph new: asked CyberPong for its New graph sheet")
    }

    /// Ask the control plane who runs each node of `kind` under `owner`.
    ///
    /// Debounced: the task field re-plans as it is typed, and a solver call per
    /// keystroke is a subprocess per keystroke. Nothing here decides anything —
    /// it prints what `pong wire plan` answers, and an empty answer stays empty.
    func planWiring(kind: String, owner: String, task: String) {
        wiringWork?.cancel()
        let session = island.session
        guard !session.isEmpty, !owner.isEmpty, !kind.isEmpty else {
            wiring = []; wiringState = ""; return
        }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let work = DispatchWorkItem { [weak self] in
            var args = ["-s", session, "wire", "plan", "--loop", kind, "--owner", owner, "--json"]
            if !trimmed.isEmpty { args += ["--task", trimmed] }
            let r = Pong.runShowingErrors(args)
            let rows = Store.parseWiring(r.out)
            DispatchQueue.main.async {
                guard let self else { return }
                if rows.isEmpty, !r.ok {
                    self.wiringState = Store.firstLine(r.err)
                        ?? Store.firstLine(r.out)
                        ?? "wiring failed"
                } else {
                    self.wiringState = ""
                }
                self.wiring = rows
            }
        }
        wiringWork = work
        wiringState = "planning"
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + Store.wiringDebounce, execute: work)
    }

    /// Decode `wire plan --json`. Nodes come back as a dictionary, so the order
    /// people expect (what builds first, who grades it, then the join) is
    /// applied here rather than left to hashing.
    static func parseWiring(_ out: String) -> [WiringRow] {
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let nodes = root["nodes"] as? [String: [String: Any]] else { return [] }
        let order = ["builder", "fan", "critic", "router", "join"]
        let ids = nodes.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }
        return ids.compactMap { id in
            guard let n = nodes[id] else { return nil }
            let rej = ((n["rejected"] as? [String: String]) ?? [:])
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
            return WiringRow(
                id: id,
                role: (n["role"] as? String) ?? "",
                runtime: (n["runtime"] as? String) ?? "",
                model: (n["model"] as? String) ?? "",
                why: (n["why"] as? String) ?? "",
                rejected: rej,
                conflict: (n["conflict"] as? String) ?? ""
            )
        }
    }

    var loopHeight: CGFloat {
        Store.loopBarChrome + (showLoops ? Store.loopPanelHeight : 0)
    }

    /// One-line weekly strip, plus a few lines when expanded. Fixed, like
    /// the loop bar, so the sheet height and the hit-test silhouette agree.
    static let weeklyBarChrome: CGFloat = 28
    static let weeklyPanelHeight: CGFloat = 52
    @Published var showWeekly = false { didSet { reclampComposer(); layout() } }
    var weeklyHeight: CGFloat {
        guard island.weekly.available, !island.weekly.chip.isEmpty else { return 0 }  // unknown: say nothing
        return Store.weeklyBarChrome + (showWeekly ? Store.weeklyPanelHeight : 0)
    }

    /// The bars this team already has, newest first.
    ///
    /// Read straight off `~/.pong/review/bars/*.md`. The map app has
    /// `Gauntlet.bars(session:)` for this, but `island/build.sh` compiles
    /// exactly one file — `PongIsland.swift` — so nothing in `src/` is on this
    /// target, and adding it would drag the map app's dependencies into an
    /// accessory process, which is the coupling `IslandHelper`'s doc comment
    /// exists to prevent. A directory listing does not need a subprocess.
    static var barPaths: [String] {
        let dir = NSHomeDirectory() + "/.pong/review/bars"
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
            .map(\.path)
    }

    /// Read the running loops. `goal status` answers JSON; parse it rather than
    /// scraping the printed lines, which are for a human and may change.
    func refreshLoops() {
        let session = island.session
        guard !session.isEmpty else { loops = []; return }
        DispatchQueue.global(qos: .utility).async {
            let r = Pong.run(["-s", session, "goal", "status"])
            let parsed = Store.parseLoops(r.out)
            DispatchQueue.main.async { self.loops = parsed }
        }
    }

    static func parseLoops(_ out: String) -> [LoopGraph] {
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let graphs = root["graphs"] as? [[String: Any]] else { return [] }
        return graphs.compactMap { g in
            let id = (g["id"] as? String) ?? ""
            let status = (g["status"] as? String) ?? ""
            // Running AND cancelled. Stop leaves the graph as history and
            // Delete is what removes it, so filtering cancelled ones out here
            // would make Delete unreachable for the rows it is for. `live`
            // carries the difference to the row.
            guard !id.isEmpty, status == "running" || status == "cancelled" else {
                return nil
            }
            return LoopGraph(
                id: id,
                kind: (g["kind"] as? String) ?? "",
                owner: (g["owner"] as? String) ?? "",
                status: status,
                nodes: ((g["nodes"] as? [[String: Any]]) ?? []).count
            )
        }
    }

    /// Start a loop. Always against the island's own bound session — the
    /// control plane refuses a cross-session write, and it is right to.
    /// Split pasted text into URLs on newline or comma, keeping order.
    ///
    /// Static and pure so the splitting rule is one thing rather than being
    /// re-derived at each call site. Nothing is normalised beyond trimming —
    /// the engine's `normalize_selected` owns that, and a second opinion here
    /// would be a second place to disagree about what a URL is.
    static func splitLinks(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func addLinks(_ text: String) {
        for url in Store.splitLinks(text) where !loopLinks.contains(url) {
            loopLinks.append(url)
        }
    }

    /// Search for candidate references from the loop's own task text.
    ///
    /// Delegates to `pong examples search --json`, which is the reviewed path
    /// — it prints only JSON on stdout, so this decodes rather than scrapes.
    /// An empty prompt does not search: searching for "" returns whatever the
    /// web feels like and would look like a suggestion.
    func suggestExamples(prompt: String) {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            suggestions = []
            suggestState = "type the task first — Suggest searches from it"
            return
        }
        suggestions = []
        suggestState = "searching"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Pong.runShowingErrors(["examples", "search", q, "--json", "--limit", "6"])
            let rows = Store.parseExamples(r.out)
            DispatchQueue.main.async {
                if !r.ok && rows.isEmpty {
                    // Say what actually went wrong. A dead network must not
                    // read as "nothing found" — the engine is careful to raise
                    // rather than return [] for exactly that reason.
                    self.suggestState = Store.firstLine(r.err)
                        ?? Store.firstLine(r.out)
                        ?? "search failed"
                    return
                }
                self.suggestions = rows
                self.suggestState = rows.isEmpty ? "empty" : ""
            }
        }
    }

    /// Decode the array `examples search --json` prints. Rows without a URL
    /// are dropped rather than patched up — a suggestion with no link is not
    /// a suggestion, and inventing one is the thing this must never do.
    static func parseExamples(_ out: String) -> [ExampleRow] {
        guard let data = out.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { r in
            let url = (r["url"] as? String) ?? ""
            guard !url.isEmpty else { return nil }
            let host = (r["host"] as? String) ?? ""
            let title = (r["title"] as? String) ?? ""
            return ExampleRow(
                id: (r["id"] as? String) ?? url,
                title: title.isEmpty ? (host.isEmpty ? url : host) : title,
                url: url,
                host: host
            )
        }
    }

    /// Start a loop on one seat, or on a set.
    ///
    /// `who` is the Who row's selection in pick order. The lead becomes
    /// `--owner` and everyone else `--with`, which is the argv spelling of the
    /// participant set `work_graph.start` has always accepted.
    func startLoop(kind: String, who: [String], task: String,
                   pieces: Int, maxRounds: Int, bar: String?) {
        let session = island.session
        guard !session.isEmpty else { loopError = "no bound session"; return }
        // Only seats that are still org mains on this poll. A selection made
        // before a roster change would otherwise hand `goal start` a seat that
        // is no longer there. An empty roster means no snapshot yet, not a
        // stale pick, so it filters nothing rather than refusing everything.
        let mains = Set(island.orgMains.map(\.id))
        let picked = mains.isEmpty ? who : who.filter { mains.contains($0) }
        guard !picked.isEmpty else { loopError = "pick who runs this"; return }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { loopError = "say what the loop should do"; return }
        // Links are a bar. The engine documents --bar as required for gauntlet
        // *unless* --example/--examples is given, and writes the bar itself
        // from the URLs, so demanding one here would be the UI inventing a
        // requirement the control plane does not have.
        if kind == "gauntlet", (bar ?? "").isEmpty, loopLinks.isEmpty {
            loopError = "gauntlet needs a bar or at least one link"; return
        }
        let args = LoopArgs.goalStart(session: session, kind: kind, picked: picked,
                                      conductor: island.conductor?.id ?? "",
                                      task: trimmed, pieces: pieces,
                                      fanCap: Store.fanCap, maxRounds: maxRounds,
                                      bar: bar, links: loopLinks)
        loopBusy = true
        loopError = nil
        Store.log("goal start argv: \(args.joined(separator: " "))")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Pong.runShowingErrors(args)
            DispatchQueue.main.async {
                self.loopBusy = false
                if r.ok {
                    // Accepted — now it is safe to clear the form.
                    self.loopTask = ""
                    self.loopLinks = []
                    self.suggestions = []
                    self.suggestState = ""
                    self.refreshLoops()
                } else {
                    // Surface what the control plane actually said, first line
                    // only. A refused cross-session write reads verbatim here.
                    self.loopError = Store.firstLine(r.err)
                        ?? Store.firstLine(r.out)
                        ?? "goal start failed"
                    Store.log("goal start refused: \(self.loopError ?? "")")
                }
            }
        }
    }

    /// Stop a live loop. The graph stays in the document as history — that is
    /// `goal cancel`, and `deleteLoop` is the separate one that forgets it.
    func cancelLoop(id: String) { runLoopAction("cancel", id: id, failed: "stop failed") }

    /// Forget a loop. `goal delete` removes it from work_graph.json, which is
    /// why it is a different button and not a second name for Stop.
    func deleteLoop(id: String) { runLoopAction("delete", id: id, failed: "delete failed") }

    private func runLoopAction(_ verb: String, id: String, failed: String) {
        let session = island.session
        guard !session.isEmpty, !id.isEmpty else { return }
        loopBusy = true
        Store.log("goal \(verb) argv: -s \(session) goal \(verb) --id \(id)")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Pong.runShowingErrors(["-s", session, "goal", verb, "--id", id])
            DispatchQueue.main.async {
                self.loopBusy = false
                if !r.ok {
                    self.loopError = Store.firstLine(r.err)
                        ?? Store.firstLine(r.out)
                        ?? failed
                }
                // Refresh either way: a failed delete still needs the list to
                // show what is actually there rather than what was expected.
                self.refreshLoops()
            }
        }
    }

    /// First non-empty line, or nil. Nil means "it failed and said nothing",
    /// and the caller supplies its own wording rather than showing a blank
    /// line. Callers try stderr first, because that is where `pong` prints a
    /// refusal.
    static func firstLine(_ s: String) -> String? {
        let line = s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return (line?.isEmpty ?? true) ? nil : line
    }

    /// The engine's own cap (`loops.FAN_CAP`), mirrored so the stepper cannot
    /// offer a value the control plane will refuse.
    static let fanCap = 4

    /// Height of the visible island right now — the only part that takes clicks.
    /// One generous expanded height. Computing it from row counts meant the
    /// list could outgrow the clickable area — which is why the team would not
    /// scroll: the rows were there, but the scroll wheel was landing outside
    /// the window's hit region.
    /// Grows with what is on screen and stops at a sane ceiling. The hit rect
    /// uses the SAME number, which is what was broken before: the list rendered
    /// past the clickable region, so the scroll wheel landed outside the window.
    /// The composer's current height, reported by the text view itself.
    ///
    /// This used to be estimated from the character count and an assumed glyph
    /// width, which is guesswork about something the layout manager already
    /// knows exactly. The text view measures its own used rect and hands the
    /// number over, so the window and the field can never disagree about how
    /// tall the composer is.
    @Published private(set) var composerHeight: CGFloat = GrowingComposer.lineHeight

    /// The one place the composer's height is decided.
    ///
    /// The text view reports what the text actually wants and this decides how
    /// much of it to draw; past `composerCeiling` the field scrolls inside
    /// itself rather than being clipped. It used to be clamped in both places
    /// at once — here and again in `reportHeight` — which is two owners for one
    /// number, and the reason a long draft was silently truncated at six lines
    /// instead of scrolling.
    func setComposerHeight(_ h: CGFloat) {
        let clamped = min(max(GrowingComposer.lineHeight, h), composerCeiling)
        guard abs(clamped - composerHeight) > 0.5 else { return }
        composerHeight = clamped
        layout()
    }

    /// Re-apply the ceiling without new text. Opening the loop panel lowers it,
    /// and a draft that was legal a moment ago has to come down with it or the
    /// panel and the composer both hold fixed frames that no longer fit.
    func reclampComposer() {
        let clamped = min(max(GrowingComposer.lineHeight, composerHeight), composerCeiling)
        if abs(clamped - composerHeight) > 0.5 { composerHeight = clamped }
    }

    /// What one gate card will draw, from what it shows (the list scrolls past the ceiling).
    func gateHeight(_ g: GateItem) -> CGFloat {
        let text = !g.question.isEmpty ? g.question : (g.summary.isEmpty ? g.reason : g.summary)
        var lines = CGFloat(min(5, max(1, Int((Double(text.count) / 58).rounded(.up)))))
        for c in g.context.prefix(3) { lines += CGFloat(min(3, max(1, Int((Double(c.count) / 66).rounded(.up))))) * 0.9 }
        let sendBack = g.options.contains("rejected") && (g.routes["rejected"].map { !$0.isEmpty } ?? true)
        let buttons = CGFloat(2 + (sendBack ? 1 : 0) + g.options.filter { $0 != "approved" && $0 != "rejected" }.count
                              + (gateRetry[g.id] == nil ? 0 : 1))
        var h: CGFloat = 26 + 30 + lines * 18 + 6 + buttons * 38 + 30
        if !g.gradeLine.isEmpty { h += 16 }
        if !g.adviceLine.isEmpty { h += 16 }
        if !g.files.isEmpty || !g.notesPath.isEmpty { h += 26 }
        h += detailHeight(g.id, g.detail, pending: g.detailPending)
        let note = !(gateDraft[g.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if gateEditing == g.id || note { h += 52 }
        return h
    }

    /// What a chat's question card will draw.
    func askHeight(_ a: AskItem) -> CGFloat {
        var lines = CGFloat(min(3, max(1, Int((Double(a.question.count) / 50).rounded(.up))))) * 20
        for c in a.context.prefix(3) { lines += CGFloat(min(3, max(1, Int((Double(c.count) / 62).rounded(.up))))) * 16 }
        var h: CGFloat = 26 + 12 + lines + 8 + CGFloat(max(1, a.options.count)) * 38 + 52 + 26
        if !a.files.isEmpty { h += 22 }
        h += detailHeight(a.id, a.detail, pending: a.detailPending)
        if gateMsg[a.id] != nil { h += 20 }
        return h
    }

    /// The "Details" disclosure: one line folded; each point, its file link and who wrote them open.
    func detailHeight(_ id: String, _ points: [DetailPoint], pending: Bool) -> CGFloat {
        if points.isEmpty { return pending ? 20 : 0 }
        var h: CGFloat = 26
        guard detailOpen.contains(id) else { return h }
        for p in points {
            h += CGFloat(max(1, Int((Double(p.text.count + 2) / 62).rounded(.up)))) * 15 + 4
            if !p.file.isEmpty { h += 16 }
        }
        h += 30  // who wrote them
        if pending { h += 15 }
        return h
    }

    var visibleHeight: CGFloat {
        guard expanded else { return chin }
        let rows   = CGFloat(island.working.count + (island.conductor == nil ? 0 : 1))
        let idle   = CGFloat(showIdleRows ? island.idle.count : (island.idle.isEmpty ? 0 : 1))
        let cards  = CGFloat(island.approvals.count)
        let word: CGFloat = island.chiefChat.isEmpty ? 0 : (showFullReply ? 240 : 126)
        let out: CGFloat = openSeat == nil ? 0 : 150
        // a question card is the tallest thing here; with one open the list may use more of the sheet
        let gates  = island.gates.reduce(CGFloat(0)) { $0 + gateHeight($1) } + CGFloat(island.attention.count) * 58
            + island.asks.reduce(CGFloat(0)) { $0 + askHeight($1) }
        let body   = min(island.gates.isEmpty && island.asks.isEmpty ? 320 : 480,
                         14 + rows * 34 + idle * 34 + cards * 168 + gates)
        // `composerChrome` is the padding around a one-line composer; whatever
        // the field grew beyond that first line has to come out of the sheet
        // too, or it is simply clipped. `body`, `word` and `out` all live in
        // the scrolling region, so when the total meets the ceiling it is that
        // region that gives — never the composer, which holds its height by
        // layout priority.
        let grown  = composerHeight - GrowingComposer.lineHeight
        return min(Store.maxHeight,
                   Store.headerChrome + body + word + out
                   + loopHeight + weeklyHeight + Store.composerChrome + grown)
    }

    /// Mirrored from the view so the window can size to what is actually drawn.
    var showIdleRows = false
    var openSeat: String?
    var showFullReply = false

    var visibleWidth: CGFloat {
        expanded ? Store.bodyWidth : notchWidth + earWidth * 2
    }
    /// AppKit window / SwiftUI root — silhouette including shoulders, not the
    /// old full-screen ceiling.
    var panelWidth: CGFloat { silhouetteRect.width }
    var panelHeight: CGFloat { silhouetteRect.height }
    var notchWidth: CGFloat { Notch.host.map { Notch.width($0) } ?? 185 }

    /// Ear width for the LONGEST line, both sides — not the line on screen.
    /// Sizing to the current line made the island breathe in and out on every
    /// rotation, which reads as a glitch; the ear picks one width and holds it
    /// for as long as the set of messages holds.
    var earWidth: CGFloat {
        island.tickerLines.map { Notch.ear(forTicker: $0.text) }.max()
            ?? Notch.ear(forTicker: "")
    }

    /// The line the ear is showing right now, or nil when there is nothing
    /// to say. Clamped because a poll can shorten the list under the index.
    var tickerLine: (tone: String, text: String)? {
        let lines = island.tickerLines
        guard !lines.isEmpty else { return nil }
        return lines[min(tickerIndex, lines.count - 1)]
    }

    /// The ear's colour for a tone. Orange is deliberately its own colour rather
    /// than the amber already used for "waiting on a person" — this is the tone
    /// that means stop, and it should not be mistaken for the other at a glance.
    var tickerColor: Color {
        switch tickerLine?.tone ?? "" {
        case "orange": return Color(hex: "FF8A3D")
        case "green":  return Color(hex: "35D07F")
        case "purple": return Color(hex: "7B5CFF")
        default:       return Ink.dim
        }
    }

    var headline: Status {
        // Stall first. The chief thinks for up to 90 seconds at a time, and
        // letting that sit on top used to hide a wedged seat behind it — the
        // one state the ear most needs to be able to shout.
        if !island.stuck.isEmpty { return .stuck }
        if island.needsYou > 0 { return .needsYou }
        // The chief thinking is thinking, the same as any other seat's. It used
        // to get .composing, which is the *resting* motion — the ear went calm
        // at exactly the moment something was happening.
        if island.chiefThinking { return .working }
        if let w = island.working.first { return Status.forSeat(w) }
        return .idle
    }
    var headlineCount: Int {
        switch headline {
        case .stuck: return island.stuck.count
        case .needsYou: return island.needsYou
        case .idle: return 0
        default: return island.working.count + (island.chiefThinking ? 1 : 0)
        }
    }
    var chin: CGFloat {
        // Two points past the safe-area inset. Flush with it exactly, a rounding
        // difference between the window and the bezel let a sliver of desktop
        // show under the shape; the overhang costs nothing because the menu bar
        // band is already dark.
        let t = Notch.host?.safeAreaInsets.top ?? 0
        return t > 0 ? t + 2 : 28
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: IslandPanel!

    /// Cmd-C / Cmd-V / Cmd-X / Cmd-A in the composer.
    ///
    /// Those key equivalents are dispatched by NSMenu, not by the text view —
    /// so an app with no main menu, which is every accessory app that never
    /// bothered to build one, silently has no clipboard. The field was never the
    /// problem: `NSApp.mainMenu` was nil, `performKeyEquivalent` for cmd-V came
    /// back false, and the keystroke died before it reached the field editor.
    ///
    /// Items get a nil target on purpose. That sends them down the responder
    /// chain to whatever is first responder — the field editor when you are
    /// typing — instead of binding them to this object. Return-to-send is
    /// untouched: Return is not a key equivalent here.
    ///
    /// An accessory app draws no menu bar, so none of this is visible.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        let items: [(String, Selector, String)] = [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, sel, key) in items {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.keyEquivalentModifierMask = [.command]
            edit.addItem(mi)
        }
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 224, height: 36),
                            styleMask: [.borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false     // a click may take key; hover never does
        panel.level = .popUpMenu   // above the menu bar band
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = PassThroughHost(rootView: IslandView(store: store))
        host.silhouetteInScreen = { [weak store] in store?.silhouetteRect ?? .zero }
        panel.contentView = host

        store.panel = panel
        store.start()
        panel.orderFrontRegardless()

        // Position AFTER the panel is on screen. The hosting view resizes the
        // window as it lays out its content, so a frame set before that gets
        // grown downward from the old 36pt top — which is how this ended up at
        // (0, -484) with only its shadow on screen.
        store.layout()
        DispatchQueue.main.async { [weak store] in store?.layout() }
        // The map asks us to open. Now that hovering only opens on the camera
        // cutout, this is the deliberate way in — the Island pill on the map
        // toolbar posts this, and `forceExpand` holds the sheet open long
        // enough for the pointer to travel up to it. Mirror of
        // `Pong.frontSeat`, which is this same channel in the other direction.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.owi.cyberpong.expandIsland"), object: nil, queue: .main
        ) { [weak store] _ in
            Store.log("expandIsland requested by the map")
            store?.forceExpand()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak store] _ in store?.layout() }
    }
}

@main
enum PongIslandApp {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        withExtendedLifetime(d) { app.run() }
    }
}
