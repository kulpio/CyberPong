import Foundation

// What the notch panel says (2.1, spec §4, §5, §7, §14.3), worked out from one read of the graph feed
// (GraphStore) and the team feed (IslandTeamFeed): the marker and counts beside the notch, which line
// wins, the rotation, the nudge of a new question, the banners, the questions first, and each graph's
// and team's row in plain words. Nothing here draws, reads a file, runs a command or looks at the
// clock: the time comes in with the input, so tests/swift/island checks every state with made-up data.
// The words are the app's own (`Words`, `GLimits.pausedWords`, `GNode.stepWords`, `TeamInfo.plainLine`).

// MARK: - Input

/// One team as the Teams view needs it: the Teams page's words (TeamInfo) plus what the engine says
/// each member is doing (2.1). IslandTeamFeed builds these.
struct IslandTeamInput: Equatable {
    struct Member: Equatable {
        let isLead: Bool
        /// "Claude Opus" ("" when not known).
        let ai: String
        let status: PongStatus
        /// TeamInfo's word: "Working", "Idle", "Needs you", "Stopped".
        let word: String
        /// What it is doing, in the engine's plain words ("" when not sent).
        var doing: String = ""
        var doingAt: Double?
        /// The graph step it works on ("" when none).
        var graphTitle: String = ""
        var stepName: String = ""
    }

    let session: String
    let name: String
    let running: Bool
    let status: PongStatus
    /// "Lead: Claude Opus · 2 helpers · 1 graph needs you · 1 working".
    let plainLine: String
    /// The lead first, then the helpers in the order they are shown.
    let members: [Member]
    /// The lead's latest message and when ("" when none).
    var lastMessage: String = ""
    var lastMessageAt: Double?
}

/// Everything one build reads. The controller fills it once per feed change; tests fill it by hand.
struct IslandInput {
    var graphs: [GGraph] = []
    var asks: [GChatAsk] = []
    var architects: [GArchitect] = []
    var limits: GLimits?
    /// Whether the graph runner is on (nil: the engine didn't say).
    var runnerOK: Bool?
    /// CyberPong can't read the graphs (no Python, or the engine didn't answer and nothing is known).
    var engineOff = false
    /// The graph feed has had a good read (GraphStore: loadedOnce, no error). Until then the nudge takes
    /// no baseline: the panel starts before the feed's first read, and that empty read would make every
    /// question already open look new once the feed arrives.
    var loaded = true
    /// Teams whose terminals are there (`SchedulesPageView.runningTeams`, asked once per build).
    var runningTeams: Set<String> = []
    /// Team names by session (the graph's own team label wins when it has one).
    var teamNames: [String: String] = [:]
    var teams: [IslandTeamInput] = []
    /// Seconds since 1970.
    var now: Double = 0
    /// How a time reads ("3:45 pm" today, "Monday 9:00 am" this week).
    var clock: (Double) -> String = { GraphTime.comesBack($0) }
    var calendar = Calendar.current
}

// MARK: - Output pieces

/// One group beside the notch: a marker, maybe a count, and whether the working ring holds still.
struct IslandMark: Equatable {
    let status: PongStatus
    let count: Int?
    var still = false
}

/// The closed panel's line: the head and tail never cut, the name in between truncates in the middle
/// ("Checkout fix" + "· 3/4"; "Paused by you · " + "Checkout fix").
struct IslandLine: Equatable {
    enum Tone: Equatable { case normal, you, fail, quiet }
    /// Identity in the rotation: the same graph in the same state keeps its place.
    let key: String
    var head = ""
    let name: String
    var tail = ""
    var tone = Tone.normal
    /// What VoiceOver reads for it.
    var spoken = ""

    var text: String {
        var s = head + name
        if !tail.isEmpty { s += " " + tail }
        return s
    }
}

/// The nudge of a new question (§14.3): the panel opens a little with the question for a few seconds.
struct IslandNudge: Equatable {
    /// The question it opens the panel at.
    let key: String
    /// The question itself (one line, cut at the end).
    let title: String
    /// "Northwind › Pricing page", or "Pricing page needs you · and 2 more".
    let source: String
    let more: Int
    let since: Double
    /// When it folds back; nil: when the pointer visits it.
    let until: Double?
    /// Read once by VoiceOver: "Pricing page needs you: Is the new pricing page ready to publish?"
    let announcement: String
}

/// Beside the notch, now.
struct IslandClosed: Equatable {
    var marks: [IslandMark] = []
    var line: IslandLine?
    var nudge: IslandNudge?
    /// The closed panel as one sentence for VoiceOver (it changes with the subject, not each turn).
    var accessibilityLabel = "CyberPong: nothing needs you."
    /// Nothing to show: the bare notch.
    var isEmpty: Bool { marks.isEmpty && line == nil && nudge == nil }
}

/// One thing that needs the person, oldest first: a graph's question, a chat's question, or a step
/// asking for something on its screen.
struct IslandNeed: Equatable {
    enum Kind: Equatable { case question, chat, step }
    let kind: Kind
    /// The question card's key (`QuestionModel.key`); a step: its graph's key, "@", the step's id.
    let key: String
    let graphKey: String
    /// The chat that asked ("" unless a chat).
    let chatKey: String
    let session: String
    /// The step that asks ("" unless a step).
    let nodeId: String
    /// "Pricing page", "Launch plan".
    let subject: String
    /// The question, or "Run the tests is asking: “Allow make test?”".
    let text: String
    /// "Northwind › Pricing page", "Chat · Launch plan".
    let source: String
    let openedAt: Double

    /// The closed line: "Pricing page needs you", "Launch plan asks you".
    var line: IslandLine {
        IslandLine(key: "need:" + key, name: subject, tail: kind == .chat ? "asks you" : "needs you", tone: .you,
                   spoken: subject + (kind == .chat ? " asks you" : " needs you"))
    }

    /// The row under the focused card: "Release notes · Approve the changelog?", "Launch plan chat asks:
    /// Which launch date…", "Checkout fix · Run the tests is asking…".
    var rowText: String {
        kind == .chat ? subject + " chat asks: " + text : subject + " · " + text
    }

    /// "4 min", "just now".
    func waited(now: Double) -> String { IslandWords.waited(now - openedAt) }
}

/// Something that needs a hand but asks no question (a step hit an error): a red card, not counted amber.
struct IslandProblem: Equatable {
    let key: String
    let graphKey: String
    let session: String
    let nodeId: String
    /// "Run the tests hit an error".
    let title: String
    /// "Checkout fix · Northwind".
    let line: String
}

/// A problem the person can fix, under the count line (§5.3).
struct IslandBanner: Equatable {
    enum Kind: Equatable { case engineOff, runnerOff, limit5h, limitWeek }
    let kind: Kind
    let text: String
    var sub = ""
    /// The button: "Turn on", "Resume anyway", "Fix" (nil: none).
    var action: String?
    /// Red: something is broken (else a quiet raised banner).
    var isProblem: Bool { kind == .engineOff || kind == .runnerOff }
    var accessibilityLabel: String {
        (isProblem ? "Problem: " : "") + text + (sub.isEmpty ? "" : " " + sub) + (action.map { " \($0), button." } ?? "")
    }
}

/// One item of the count line: "◆ 2 need you", "◠ 3 working".
struct IslandCount: Equatable {
    let status: PongStatus
    let count: Int
    let words: String
    /// The amber item at 0 shows dimmed.
    var dim = false
    var still = false
}

/// One place on a graph's step track.
enum IslandTrack: Equatable { case done, now, you, failed, ahead }

/// A row action, by what it does (the view names and wires the button).
enum IslandRowAction: Equatable {
    case watch, resume, startTeam, openGraph, openScreen

    var title: String {
        switch self {
        case .watch: return "Watch"
        case .resume: return "Resume"
        case .startTeam: return "Start team"
        case .openGraph: return "Open the graph"
        case .openScreen: return "Open its screen"
        }
    }
}

/// One step in a graph's step list: "03  ◠ Run the tests · running a command · Claude Sonnet · 2 min".
struct IslandStepRow: Equatable {
    let number: String
    let nodeId: String
    let status: PongStatus
    let name: String
    let words: String
    let time: String
}

/// A graph's row in the Graphs view (§5.5).
struct IslandGraphRow: Equatable {
    enum State: Equatable {
        case asking, working, quiet, betweenSteps, pausedByYou, pausedLimit, pausedWeek, waitsForTeam
        case passed, finished, stopped, failed
    }
    let key: String
    let session: String
    let state: State
    let marker: PongStatus
    let name: String
    let team: String
    /// Quiet: the title in secondary.
    var titleDim = false
    /// "26 min"; a finished row "12 min ago".
    let time: String
    /// Line 2: the main words and, after them in tertiary, the AI and the round.
    var line2 = ""
    var line2Meta = ""
    /// Line 3: what it is doing, and its age in tertiary (nil: no third line).
    var line3: String?
    var line3Age = ""
    var action: IslandRowAction?
    /// One segment per step place (empty: no track on this row).
    var track: [IslandTrack] = []
    /// "3/4", "step 2" ("" when not known).
    var fraction = ""
    var sentBack = 0
    /// A finished row: one line.
    var oneLine = false
    /// Hover actions.
    var canPause = false
    var canResume = false
    /// The step list (at most 8) and how many more there are.
    var steps: [IslandStepRow] = []
    var moreSteps = 0
    var accessibilityLabel = ""

    /// The compact row's second line (anything waits): what it is doing, else its state.
    var compactLine: String { line3 ?? line2 }
    var compactAge: String { line3 == nil ? "" : line3Age }
}

struct IslandGraphGroup: Equatable {
    enum Kind: Equatable { case working, pausedOrWaiting, finished }
    let kind: Kind
    /// "Working", "Paused or waiting", "Finished · last 30 min" (the view draws it as an eyebrow).
    let title: String
    let rows: [IslandGraphRow]
    /// The finished group starts folded: "Show 3 finished".
    var foldTitle = ""
}

/// A team's row in the Teams view (§5.6).
struct IslandTeamRow: Equatable {
    struct Member: Equatable {
        let status: PongStatus
        /// "Lead", "Helper 1".
        let who: String
        let ai: String
        /// "checking the test results", "Checkout fix › Run the tests", "idle".
        let doing: String
        var text: String { who + (ai.isEmpty ? "" : " · " + ai) + " — " + doing }
    }
    struct Chip: Equatable {
        let graphKey: String
        let title: String
        /// " 3/4", " ◆", " ‖" ("" when nothing to add).
        let suffix: String
        let needsYou: Bool
        var text: String { title + suffix }
    }
    let session: String
    let name: String
    let marker: PongStatus
    /// "2 graphs" ("" when none).
    let graphs: String
    let plainLine: String
    var members: [Member] = []
    /// "Lead, 4 min ago: The tests pass. Review starts next." ("" when none).
    var lastMessage = ""
    var chips: [Chip] = []
    /// A stopped team offers [Start team].
    var stopped = false
    var accessibilityLabel = ""
}

/// A chat (a graph architect) after the teams: "Launch plan chat · Claude Opus · 3 graphs · Live".
struct IslandChatRow: Equatable {
    let key: String
    let title: String
    let line: String
    let live: Bool
}

// MARK: - The state of one read

/// Everything the panel draws from one read of the feeds, except what moves with the clock (the
/// rotation, the finished note, the nudge: `IslandModel`).
struct IslandState: Equatable {
    /// The view the list shows ("Automatic" resolved).
    var view = IslandSettings.View.graphs
    // counts
    var needsCount = 0
    var workingCount = 0
    var pausedCount = 0
    var limitPausedCount = 0
    var pausedByYouCount = 0
    var waitsForTeamCount = 0
    var runningCount = 0
    var runnerOff = false
    var engineOff = false
    // open panel
    var countLine: [IslandCount] = []
    /// "All quiet." when nothing at all is going on.
    var countQuiet = ""
    var banners: [IslandBanner] = []
    var needs: [IslandNeed] = []
    /// The question the card shows first: the oldest that can be a card (a step asking can't).
    var focusIndex: Int?
    var problems: [IslandProblem] = []
    var graphGroups: [IslandGraphGroup] = []
    /// Rows go compact while anything waits.
    var compact = false
    var teamRows: [IslandTeamRow] = []
    var chatRows: [IslandChatRow] = []
    /// "Claude this week: 84%" (nil: under 80%, or something is paused).
    var footerWeek: String?
    var emptyTitle = ""
    var emptyLine = ""
    var teamsEmptyTitle = ""
    var teamsEmptyLine = ""
    // closed-panel candidates (§4.3), before the clock picks among them
    var urgentLine: IslandLine?
    var urgentMarks: [IslandMark] = []
    var rotation: [IslandLine] = []
    var rotationMarks: [IslandMark] = []
    var restLine: IslandLine?
    var restMarks: [IslandMark] = []
    var accessibilityLabel = "CyberPong: nothing needs you."

    /// Every graph row, in the order shown.
    var graphRows: [IslandGraphRow] { graphGroups.flatMap { $0.rows } }
}

// MARK: - Building it

extension IslandState {
    static func build(_ input: IslandInput, settings: IslandSettings) -> IslandState {
        var s = IslandState()
        let now = input.now
        let reads = input.graphs.map { GraphRead($0, input) }
        let running = reads.filter { $0.g.isRunning }

        s.runningCount = running.count
        // a graph held by a step's error isn't at work (its problem card says so)
        s.workingCount = running.filter { [.working, .quiet, .betweenSteps].contains($0.state) && $0.failedStep == nil }.count
        s.pausedByYouCount = running.filter { $0.state == .pausedByYou }.count
        s.limitPausedCount = running.filter { $0.state == .pausedLimit || $0.state == .pausedWeek }.count
        s.pausedCount = s.pausedByYouCount + s.limitPausedCount
        s.waitsForTeamCount = running.filter { $0.state == .waitsForTeam }.count
        s.engineOff = input.engineOff
        s.runnerOff = input.runnerOK == false && !running.isEmpty
        s.view = settings.view == .automatic ? (running.isEmpty ? .teams : .graphs) : settings.view

        // Needs you: the graphs' questions, the chats' questions, the steps asking; oldest first
        var needs: [IslandNeed] = []
        for r in running {
            let g = r.g
            for gate in g.gates {
                let q = gate.ask?.question ?? (gate.reason.isEmpty
                    ? (Words.isYourAnswer(gate.node) ? "Go on with \(g.displayTitle)?" : "Go on with \(Words.name(gate.node))?")
                    : gate.reason)
                needs.append(IslandNeed(kind: .question, key: g.key + "#" + gate.node, graphKey: g.key, chatKey: "",
                                        session: g.session, nodeId: "", subject: g.displayTitle, text: oneLine(q),
                                        source: r.team + " › " + g.displayTitle, openedAt: gate.at ?? g.lastActivity))
            }
            for n in g.nodes where !n.attention.isEmpty && n.status == "running" {
                needs.append(IslandNeed(kind: .step, key: g.key + "@" + n.id, graphKey: g.key, chatKey: "",
                                        session: g.session, nodeId: n.id, subject: g.displayTitle,
                                        text: n.displayName + " " + attentionWords(n.attention),
                                        source: r.team + " › " + g.displayTitle,
                                        openedAt: g.now?.waitingSince ?? n.liveChangedAt ?? n.startedAt ?? g.createdAt))
            }
        }
        for a in input.asks {
            let chat = input.architects.first { $0.id == a.architect && $0.session == a.session }
            let title = chat?.displayTitle ?? input.teamNames[a.session] ?? a.session
            needs.append(IslandNeed(kind: .chat, key: a.key, graphKey: "", chatKey: a.chatKey ?? "", session: a.session,
                                    nodeId: "", subject: title, text: oneLine(a.question), source: "Chat · " + title,
                                    openedAt: a.createdAt))
        }
        // oldest first; the same moment keeps the order above (questions, steps, chats)
        s.needs = needs.enumerated().sorted { ($0.element.openedAt, $0.offset) < ($1.element.openedAt, $1.offset) }.map { $0.element }
        s.needsCount = s.needs.count
        s.focusIndex = s.needs.firstIndex { $0.kind != .step }
        s.compact = !s.needs.isEmpty

        // Problems that aren't questions: a step that hit an error in a running graph
        for r in running {
            for n in r.g.nodes where n.status == "failed" && n.attention.isEmpty {
                s.problems.append(IslandProblem(key: r.g.key + "!" + n.id, graphKey: r.g.key, session: r.g.session,
                                                nodeId: n.id, title: n.displayName + " hit an error",
                                                line: r.g.displayTitle + " · " + r.team))
            }
        }

        // Count line (§5.3)
        let still = s.needsCount > 0
        var counts: [IslandCount] = []
        if s.workingCount > 0 { counts.append(IslandCount(status: .working, count: s.workingCount, words: "\(s.workingCount) working", still: still)) }
        if s.pausedCount > 0 { counts.append(IslandCount(status: .paused, count: s.pausedCount, words: "\(s.pausedCount) paused")) }
        if s.waitsForTeamCount > 0 {
            counts.append(IslandCount(status: .pending, count: s.waitsForTeamCount,
                                      words: s.waitsForTeamCount == 1 ? "1 waits for its team" : "\(s.waitsForTeamCount) wait for their teams"))
        }
        if counts.isEmpty && s.needsCount == 0 && s.problems.isEmpty {
            s.countQuiet = "All quiet."
        } else {
            let n = s.needsCount
            counts.insert(IslandCount(status: .needsYou, count: n, words: "\(n) need" + (n == 1 ? "s" : "") + " you", dim: n == 0), at: 0)
        }
        s.countLine = counts

        // Banners (§5.3, §7)
        if s.engineOff {
            s.banners.append(IslandBanner(kind: .engineOff, text: "Engine off: CyberPong can't read your graphs.", action: "Fix"))
        }
        if s.runnerOff {
            s.banners.append(IslandBanner(kind: .runnerOff, text: "Graph runner off: graphs can't move past their first step.",
                                          action: "Turn on"))
        }
        if let l = input.limits, let words = l.pausedWords(now: now, clock: input.clock) {
            if l.state == "paused_week" {
                s.banners.append(IslandBanner(kind: .limitWeek, text: words.text, action: "Resume anyway"))
            } else {
                s.banners.append(IslandBanner(kind: .limit5h, text: words.text + ".", sub: "They go on by themselves."))
            }
        }
        s.footerWeek = input.limits?.weekWords

        // Graph rows (§5.5): working, paused or waiting, finished lately; a graph at a question isn't
        // listed again (its question is in Needs you)
        let working = running.filter { [.asking, .working, .quiet, .betweenSteps].contains($0.state) && !$0.atGate }
        let waiting = running.filter { [.pausedByYou, .pausedLimit, .pausedWeek, .waitsForTeam].contains($0.state) }
        let keep = Double(settings.keepFinishedMinutes) * 60
        let finished = reads.filter { !$0.g.isRunning && now - ($0.g.finishedAt ?? $0.g.createdAt) <= keep }
            .sorted { ($0.g.finishedAt ?? 0) > ($1.g.finishedAt ?? 0) }
        if !working.isEmpty { s.graphGroups.append(IslandGraphGroup(kind: .working, title: "Working", rows: working.map { $0.row(input) })) }
        if !waiting.isEmpty {
            s.graphGroups.append(IslandGraphGroup(kind: .pausedOrWaiting, title: "Paused or waiting", rows: waiting.map { $0.row(input) }))
        }
        if !finished.isEmpty {
            s.graphGroups.append(IslandGraphGroup(kind: .finished, title: "Finished · " + lastWords(settings.keepFinishedMinutes),
                                                  rows: finished.map { $0.row(input) },
                                                  foldTitle: "Show \(finished.count) finished"))
        }
        if s.needs.isEmpty { s.emptyTitle = "Nothing needs you." }
        if running.isEmpty {
            let today = input.graphs.filter { !$0.isRunning && $0.finishedAt.map { input.calendar.isDate(Date(timeIntervalSince1970: $0), inSameDayAs: Date(timeIntervalSince1970: now)) } ?? false }.count
            s.emptyLine = "No graphs running." + (today > 0 ? " \(today) finished today." : "")
        }

        // Teams view (§5.6)
        for t in input.teams { s.teamRows.append(teamRow(t, reads: running, now: now)) }
        if input.teams.isEmpty {
            s.teamsEmptyTitle = "No teams yet."
            s.teamsEmptyLine = "A team is a lead AI plus helpers. A new graph starts one for you."
        }
        let asking = Set(input.asks.compactMap { $0.chatKey })
        for a in input.architects where a.alive || asking.contains(a.key) {
            let title = a.displayTitle.lowercased().hasSuffix("chat") ? a.displayTitle : a.displayTitle + " chat"
            var bits = [Words.ai(a.runtime, a.model)]
            if !a.graphs.isEmpty { bits.append(Words.plural(a.graphs.count, "graph")) }
            if asking.contains(a.key) { bits.append("asked you a question") }
            if !a.alive { bits.append("stopped") }
            s.chatRows.append(IslandChatRow(key: a.key, title: title, line: bits.filter { !$0.isEmpty }.joined(separator: " · "), live: a.alive))
        }

        // The closed panel's candidates (§4.3)
        let workMark = s.workingCount > 0 ? IslandMark(status: .working, count: s.workingCount >= 2 ? s.workingCount : nil, still: still) : nil
        if let first = s.needs.first {
            s.urgentLine = first.line
            s.urgentMarks = [IslandMark(status: .needsYou, count: s.needsCount)] + (workMark.map { [$0] } ?? [])
        } else if s.engineOff {
            s.urgentLine = IslandLine(key: "engine", name: "Engine off", tone: .fail, spoken: "Engine off")
            s.urgentMarks = [IslandMark(status: .failed, count: nil)]
        } else if s.runnerOff {
            s.urgentLine = IslandLine(key: "runner", name: "Graph runner off", tone: .fail, spoken: "Graph runner off")
            s.urgentMarks = [IslandMark(status: .failed, count: nil)]
        }
        // the rotation: each graph at work, each quiet one, and one item for Claude's limit
        var rot: [IslandLine] = []
        if s.view == .teams {
            for t in input.teams where t.running {
                if let line = teamLine(t) { rot.append(line) }
            }
        }
        if rot.isEmpty {
            for r in running {
                switch r.state {
                case .betweenSteps where r.failedStep != nil:
                    rot.append(IslandLine(key: "g:" + r.g.key + ":failed", name: r.g.displayTitle, tail: "· hit an error", tone: .fail,
                                          spoken: r.g.displayTitle + ", a step hit an error"))
                case .working, .betweenSteps:
                    let f = r.fraction
                    rot.append(IslandLine(key: "g:" + r.g.key + ":work", name: r.g.displayTitle, tail: "· " + (f.isEmpty ? "working" : f),
                                          spoken: r.g.displayTitle + ", " + (r.spokenPlace.isEmpty ? "working" : r.spokenPlace)))
                case .quiet:
                    let m = r.quietMinutes
                    rot.append(IslandLine(key: "g:" + r.g.key + ":quiet", name: r.g.displayTitle,
                                          tail: "· quiet" + (m > 0 ? " \(m) min" : ""), tone: .quiet,
                                          spoken: r.g.displayTitle + ", quiet" + (m > 0 ? " for " + IslandWords.spoken(Double(m) * 60) : "")))
                default: break
                }
            }
        }
        let limitHolds = s.limitPausedCount > 0 || (input.limits?.isPaused ?? false)
        if limitHolds {
            rot.append(limitLine(input, reads: running))
        }
        s.rotation = rot
        if !rot.isEmpty {
            if let w = workMark {
                s.rotationMarks = [IslandMark(status: .working, count: w.count)]
            } else if limitHolds {
                // nothing at work, only Claude's limit to say: the pause sign, never a ring
                s.rotationMarks = [IslandMark(status: .paused, count: s.limitPausedCount >= 2 ? s.limitPausedCount : nil)]
            } else if running.contains(where: { $0.failedStep != nil }) {
                s.rotationMarks = [IslandMark(status: .failed, count: nil)]
            } else {
                s.rotationMarks = [IslandMark(status: .working, count: nil)]
            }
        }
        if s.pausedByYouCount > 0 {
            let mine = running.filter { $0.state == .pausedByYou }
            s.restLine = IslandLine(key: "pausedbyyou", head: "Paused by you · ",
                                    name: mine.count == 1 ? mine[0].g.displayTitle : Words.plural(mine.count, "graph"),
                                    spoken: "Paused by you: " + (mine.count == 1 ? mine[0].g.displayTitle : Words.plural(mine.count, "graph")))
            s.restMarks = [IslandMark(status: .paused, count: mine.count >= 2 ? mine.count : nil)]
        } else if s.waitsForTeamCount > 0 {
            let mine = running.filter { $0.state == .waitsForTeam }
            s.restLine = IslandLine(key: "team:" + mine[0].g.key, name: mine[0].g.displayTitle, tail: "· team stopped", tone: .quiet,
                                    spoken: mine[0].g.displayTitle + ", its team is stopped")
            s.restMarks = [IslandMark(status: .pending, count: mine.count >= 2 ? mine.count : nil)]
        }
        s.accessibilityLabel = spokenSentence(s, now: now)
        return s
    }

    /// A busy team's closed line (Teams view): "Northwind · 3 AIs working", or the lead's own words when
    /// it is the one at work: "Northwind · lead is writing the plan". nil: nobody on the team is working.
    private static func teamLine(_ t: IslandTeamInput) -> IslandLine? {
        let busy = t.members.filter { $0.status == .working }
        guard !busy.isEmpty else { return nil }
        // the lead's own words only when they read after "is" and fit beside the notch (the tail is
        // never cut): "writing the plan", "running a command"; anything else counts the AIs
        if busy.count == 1, let lead = busy.first, lead.isLead, !lead.doing.isEmpty {
            let d = IslandWords.lowerFirst(lead.doing)
            let first = d.split(separator: " ").first.map(String.init) ?? ""
            if d.count <= 20, first.count > 4, first.hasSuffix("ing"), !d.hasSuffix("…") {
                return IslandLine(key: "t:" + t.session, name: t.name, tail: "· lead is " + d, spoken: t.name + ", the lead is " + d)
            }
        }
        let w = Words.plural(busy.count, "AI") + " working"
        return IslandLine(key: "t:" + t.session, name: t.name, tail: "· " + w, spoken: t.name + ", " + w)
    }

    /// "Paused · back 3:45 pm" (Claude's 5-hour limit), "Paused · weekly limit".
    private static func limitLine(_ input: IslandInput, reads: [GraphRead]) -> IslandLine {
        let l = input.limits
        let week = l?.state == "paused_week" || (l?.isPaused != true && reads.contains { $0.state == .pausedWeek })
        if week { return IslandLine(key: "limit", name: "Paused", tail: "· weekly limit", spoken: "Paused for Claude's weekly limit") }
        let until = [l?.until, l?.sessionReset].compactMap { $0 }.first { $0 > input.now }
            ?? reads.compactMap { $0.g.now?.limitUntil }.first { $0 > input.now }
        if let u = until {
            let at = input.clock(u)
            return IslandLine(key: "limit", name: "Paused", tail: "· back " + at, spoken: "Paused for Claude's 5-hour limit, back at " + at)
        }
        return IslandLine(key: "limit", name: "Paused", tail: "· Claude's limit", spoken: "Paused for Claude's 5-hour limit")
    }

    private static func teamRow(_ t: IslandTeamInput, reads: [GraphRead], now: Double) -> IslandTeamRow {
        let mine = reads.filter { $0.g.session == t.session }
        var row = IslandTeamRow(session: t.session, name: t.name, marker: t.status,
                                graphs: mine.isEmpty ? "" : Words.plural(mine.count, "graph"), plainLine: t.plainLine)
        row.stopped = !t.running
        if t.running {
            var helper = 0
            for m in t.members {
                let who: String
                if m.isLead { who = "Lead" } else { helper += 1; who = "Helper \(helper)" }
                let doing: String
                if !m.graphTitle.isEmpty {
                    doing = m.graphTitle + (m.stepName.isEmpty ? "" : " › " + m.stepName) + (m.status == .stale ? " · quiet" : "")
                } else if !m.doing.isEmpty, m.status != .stopped {
                    doing = IslandWords.lowerFirst(m.doing)
                } else {
                    doing = m.word.isEmpty ? m.status.word.lowercased() : m.word.lowercased()
                }
                row.members.append(IslandTeamRow.Member(status: m.status, who: who, ai: m.ai, doing: doing))
            }
            if !t.lastMessage.isEmpty {
                let when = t.lastMessageAt.map { IslandWords.agoShort($0, now: now) } ?? ""
                let text = String(oneLine(t.lastMessage).prefix(200))
                row.lastMessage = "Lead" + (when.isEmpty ? "" : ", " + when) + ": " + text
            }
        }
        for r in mine {
            let suffix: String
            let you = r.g.waitingOnYou
            if you { suffix = " ◆" } else if r.state == .pausedByYou || r.state == .pausedLimit || r.state == .pausedWeek { suffix = " ‖" } else {
                // progress only for a graph at work: one waiting for its team has none to show
                let atWork = r.state == .working || r.state == .quiet || r.state == .betweenSteps
                suffix = atWork && !r.fraction.isEmpty ? " " + r.fraction : ""
            }
            row.chips.append(IslandTeamRow.Chip(graphKey: r.g.key, title: r.g.displayTitle, suffix: suffix, needsYou: you))
        }
        row.accessibilityLabel = t.name + ". " + t.plainLine.replacingOccurrences(of: " · ", with: ", ") + "."
        return row
    }

    private static func spokenSentence(_ s: IslandState, now: Double) -> String {
        var parts: [String] = []
        if let first = s.needs.first {
            let n = s.needsCount
            parts.append(Words.plural(n, "thing") + (n == 1 ? " needs" : " need") + " you.")
            let waited = now - first.openedAt
            parts.append(first.line.spoken + (waited >= 30 ? ", waiting " + IslandWords.spoken(waited) : "") + ".")
        }
        if s.engineOff { parts.append("Engine off: CyberPong can't read your graphs.") }
        if s.runnerOff { parts.append("Graph runner off.") }
        if s.workingCount > 0 { parts.append(Words.plural(s.workingCount, "graph") + " working.") }
        if s.limitPausedCount > 0 { parts.append(Words.plural(s.limitPausedCount, "graph") + " paused for Claude's limit.") }
        if s.pausedByYouCount > 0 { parts.append(Words.plural(s.pausedByYouCount, "graph") + " paused by you.") }
        if s.waitsForTeamCount > 0 {
            parts.append(s.waitsForTeamCount == 1 ? "1 graph waits for its team." : "\(s.waitsForTeamCount) graphs wait for their teams.")
        }
        return "CyberPong: " + (parts.isEmpty ? "nothing needs you." : parts.joined(separator: " "))
    }

    /// "last 30 min", "last hour", "last 4 hours".
    static func lastWords(_ minutes: Int) -> String {
        if minutes < 60 { return "last \(minutes) min" }
        if minutes == 60 { return "last hour" }
        return minutes % 60 == 0 ? "last \(minutes / 60) hours" : "last \(minutes) min"
    }

    /// A step's ask without the instruction its button already gives: "is asking: “Allow make test?”",
    /// "has stopped: its AI is not running".
    static func attentionWords(_ a: String) -> String {
        var t = a.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: " Open its screen") { t = String(t[..<r.lowerBound]) }
        while t.hasSuffix(".") { t = String(t.dropLast()) }
        return t
    }

    /// Text on one line with its spaces collapsed.
    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - One graph, read once

/// A graph read for the panel: its one state now, the step to show and its place, from the engine's
/// `now` when it sends one, else from the steps themselves.
private struct GraphRead {
    let g: GGraph
    let now: Double
    let team: String
    let state: IslandGraphRow.State
    let places: StepPlaces.Result
    let shown: GNode?
    let place: Int?
    let total: Int?
    let running: [GNode]
    let runnerOff: Bool
    let clock: (Double) -> String
    let limitUntil: Double?
    /// At a question: its question is in Needs you, so it isn't listed as a row.
    let atGate: Bool
    /// The step that finished last (between steps, its place is the graph's place).
    let lastDone: GNode?
    /// A step hit an error and nothing else is at work: the graph waits on it (its problem card, under
    /// the questions, offers to run it again). Its row says so rather than "Step 2 of 4 done".
    let failedStep: GNode?

    init(_ g: GGraph, _ input: IslandInput) {
        self.g = g
        now = input.now
        clock = input.clock
        team = g.teamLabel.isEmpty ? (input.teamNames[g.session] ?? g.session) : g.teamLabel
        let ps = StepPlaces.of(g)
        let live = g.nodes.filter { $0.status == "running" }
        places = ps
        running = live
        runnerOff = input.runnerOK == false
        let n = g.now
        // the step to show: the engine's, else one waiting on the person, else the one at work that started last
        let failed = g.isRunning && live.isEmpty ? g.nodes.first { $0.status == "failed" } : nil
        let sh = n.flatMap { now in g.node(now.step) }
            ?? g.nodes.first { $0.status == "running" && !$0.attention.isEmpty }
            ?? g.nodes.first { $0.status == "waiting_human" }
            ?? live.max { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
            ?? failed
        let done = g.nodes.filter { $0.status == "done" && $0.role != "end" }.max { ($0.finishedAt ?? 0) < ($1.finishedAt ?? 0) }
        shown = sh
        lastDone = done
        atGate = g.isRunning && !g.gates.isEmpty
        total = n?.steps ?? ps.total
        limitUntil = n?.limitUntil ?? input.limits.flatMap { $0.until ?? $0.sessionReset }
        let teamUp = input.runningTeams.contains(g.session)
        if !g.isRunning {
            state = GraphRead.ending(g)
        } else if !g.gates.isEmpty {
            state = .asking   // at a question: listed in Needs you, not as a row
        } else if g.nodes.contains(where: { !$0.attention.isEmpty && $0.status == "running" }) {
            state = .asking
        } else if g.manualPause {
            // the runner's pauses say "Claude's 5-hour limit" / "Claude's weekly limit"; the person's own
            // reason ("back next week") is theirs, even with "week" in it
            let why = (n?.pauseReason.isEmpty == false ? n!.pauseReason : g.pauseReason).lowercased()
            if n?.state == "paused_limit" || why.contains("limit") {
                state = why.contains("week") ? .pausedWeek : .pausedLimit
            } else {
                state = .pausedByYou
            }
        } else if !teamUp {
            state = .waitsForTeam
        } else if let s = n?.state, ["working", "quiet", "between_steps"].contains(s) {
            state = s == "quiet" ? .quiet : s == "between_steps" ? .betweenSteps : .working
        } else if live.isEmpty {
            state = .betweenSteps
        } else if let sh, GraphRead.isQuiet(sh, now: input.now) {
            state = .quiet
        } else {
            state = .working
        }
        failedStep = state == .betweenSteps ? failed : nil
        // a step that hit an error holds the graph's place, whatever finished before it
        place = failedStep.flatMap { ps.place[$0.id] } ?? n?.stepN ?? (sh ?? (live.isEmpty ? done : nil)).flatMap { ps.place[$0.id] }
    }

    /// How a graph that isn't running ended: stopped by the person, passed, failed (a step's error,
    /// out of rounds or time, no next step), or simply finished.
    static func ending(_ g: GGraph) -> IslandGraphRow.State {
        let r = g.stopReason
        if r == "cancelled" { return .stopped }
        if r == "win" { return .passed }
        if r.hasPrefix("failed") || r.hasPrefix("no_edge") || r.hasPrefix("error") || !g.lastError.isEmpty { return .failed }
        return .finished
    }

    /// No news for 10 minutes, or the engine says the step went quiet.
    static func isQuiet(_ n: GNode, now: Double) -> Bool {
        if n.liveState == "quiet" { return true }
        // mid-turn (a long command with nothing new on screen) is at work, as the engine counts it
        if n.liveBusy { return false }
        if let c = n.liveChangedAt, now - c >= 600 { return true }
        return false
    }

    /// "3/4", "step 2", "" when its place isn't known.
    var fraction: String {
        guard let p = place else { return "" }
        if let t = total { return "\(p)/\(t)" }
        return "step \(p)"
    }

    /// "step 3 of 4", "step 2".
    var spokenPlace: String {
        guard let p = place else { return "" }
        return total.map { "step \(p) of \($0)" } ?? "step \(p)"
    }

    /// "Step 3 of 4", "Step 2" ("" when not known).
    var stepWords: String {
        guard let p = place else { return "" }
        return total.map { "Step \(p) of \($0)" } ?? "Step \(p)"
    }

    /// When the shown step last changed on screen.
    var doingAt: Double? { g.now?.doingChangedAt ?? shown?.liveChangedAt }

    /// Whole minutes since the shown step last changed.
    var quietMinutes: Int { doingAt.map { Int(max(0, now - $0) / 60) } ?? 0 }

    /// What the shown step is doing, in plain words (nil: nothing a person can use).
    var doing: String? {
        if let p = g.now?.doingPlain, !p.isEmpty { return p }
        if let sh = shown, !sh.liveDoingPlain.isEmpty { return sh.liveDoingPlain }
        if let raw = g.now?.doing, !raw.isEmpty, let d = Words.doing(raw) { return d }
        return shown.flatMap { Words.doing($0.liveDoing) }
    }

    var ai: String {
        if let n = g.now, !n.runtime.isEmpty { return Words.ai(n.runtime, n.model) }
        guard let sh = shown, !sh.runtime.isEmpty else { return "" }
        return Words.ai(sh.runtime, sh.model)
    }

    /// "round 2 of 3": shown once the work has gone round at least once.
    var roundWords: String {
        var r = 0, m = 0
        if let n = g.now, n.round > 0 { r = n.round; m = n.rounds }
        else if let sh = shown, sh.loopMax > 0 { r = sh.loopRound; m = sh.loopMax }
        else { r = g.round; m = g.maxRounds }
        guard r >= 2 else { return "" }
        return m > 0 ? "round \(r) of \(m)" : "round \(r)"
    }

    var sentBack: Int { g.now?.sentBack ?? max(0, (shown?.visits ?? 1) - 1) }

    var startedAt: Double? { g.now?.stepStartedAt ?? shown?.startedAt }

    /// The steps at work now (names, up to three) and, when they share one place, how many of that
    /// place's steps are done; the last of them still at work keeps the count ("2 of 3 done").
    var atOnce: (count: Int, names: [String], done: Int?, of: Int?) {
        if let n = g.now, n.atOnce >= 2 || (n.atOnce == 1 && n.atOnceDone > 0) {
            return (n.atOnce, n.atOnceNames, n.atOnceDone, n.atOnce + n.atOnceDone)
        }
        // side by side, copies go by their own names without their numbers ("Intro, Setup, FAQ at once"),
        // and copies of one step by its name once ("Write · 3 at once"), as the engine names them
        var names: [String] = []
        for n in running {
            let base = n.title.isEmpty ? Words.name(n.copyOf.isEmpty ? n.id : n.copyOf) : n.title
            if !names.contains(base) { names.append(base) }
        }
        names = Array(names.prefix(3))
        let ps = Set(running.compactMap { places.place[$0.id] })
        guard !running.isEmpty, ps.count == 1, let p = ps.first else { return (running.count, names, nil, nil) }
        // the steps at that place done in this pass (one finished in an earlier round doesn't count)
        let began = running.compactMap { $0.startedAt }.min() ?? 0
        let at = g.nodes.filter { $0.role != "end" && places.place[$0.id] == p }
        guard at.count >= 2 else { return (running.count, names, nil, nil) }
        let done = at.filter { $0.status == "done" && ($0.finishedAt.map { $0 >= began - 5 } ?? true) }.count
        return (running.count, names, done, running.count + done)
    }

    /// One segment per place: done before the step now, the step now, ahead after it (a step sent back
    /// eases the track back rather than leaving later places lit).
    var track: [IslandTrack] {
        guard let p = place else { return [] }
        let count = max(total ?? p, p)
        guard count >= 1, count <= 40 else { return [] }
        let order = g.nodes.map { $0.id }
        var out: [IslandTrack] = []
        for i in 1...count {
            let ids = places.ids(at: i, order: order)
            let nodes = ids.compactMap { g.node($0) }
            if i < p {
                out.append(nodes.contains { $0.status == "failed" } ? .failed : .done)
            } else if i == p {
                if nodes.contains(where: { $0.status == "failed" }) && (state != .betweenSteps || failedStep != nil) { out.append(.failed) }
                else if state == .betweenSteps { out.append(.done) }
                else if nodes.contains(where: { $0.status == "waiting_human" || !$0.attention.isEmpty }) { out.append(.you) }
                else { out.append(.now) }
            } else {
                out.append(.ahead)
            }
        }
        return out
    }

    func row(_ input: IslandInput) -> IslandGraphRow {
        let name = g.displayTitle
        let time: String
        if g.isRunning {
            time = PongUI.duration(g.wallMin * 60)
        } else {
            time = IslandWords.agoShort(g.finishedAt ?? g.createdAt, now: now)
        }
        var row = IslandGraphRow(key: g.key, session: g.session, state: state, marker: marker, name: name, team: team, time: time)
        row.fraction = fraction
        switch state {
        case .working, .quiet, .betweenSteps:
            fillWorking(&row)
        case .asking:
            let n = g.nodes.first { !$0.attention.isEmpty && $0.status == "running" }
            if let n {
                row.line2 = "Needs you: " + n.displayName + " " + IslandState.attentionWords(n.attention)
                row.action = .openScreen
            } else {
                row.line2 = "Needs your answer"
            }
            row.canPause = true
        case .pausedByYou:
            let held = g.now?.held ?? g.held
            row.line2 = "Paused by you" + (held > 0 ? " · " + Words.plural(held, "step") + " waiting to start" : "")
            row.canResume = true
            row.action = .resume
        case .pausedLimit:
            let back = limitUntil.flatMap { $0 > now ? "goes on by itself at " + clock($0) : nil } ?? "goes on by itself after the reset"
            row.line2 = "Paused for Claude's 5-hour limit · " + back
        case .pausedWeek:
            row.line2 = "Paused near Claude's weekly limit"
        case .waitsForTeam:
            row.line2 = "Waits for its team to start"
            row.action = .startTeam
        case .passed:
            row.line2 = "Finished · passed"
            row.oneLine = true
        case .finished:
            row.line2 = "Finished"
            row.oneLine = true
        case .stopped:
            row.line2 = "Stopped by you"
            row.oneLine = true
        case .failed:
            if g.stopReason.hasPrefix("failed_bounded") || g.stopReason.hasPrefix("no_edge") {
                row.line2 = g.plainStatus
            } else if let n = g.nodes.first(where: { $0.status == "failed" || ["error", "fail", "failed"].contains($0.lastOutcome.lowercased()) }) {
                row.line2 = "Failed · " + n.displayName + " hit an error"
            } else {
                row.line2 = g.plainStatus.hasPrefix("Failed") ? g.plainStatus : "Failed"
            }
            row.oneLine = true
            row.action = .openGraph
        }
        if g.isRunning {
            let all = stepRows   // worked out once: it sorts and words every step
            row.steps = Array(all.prefix(8))
            row.moreSteps = max(0, all.count - 8)
        }
        row.accessibilityLabel = spoken(row)
        return row
    }

    var marker: PongStatus {
        if failedStep != nil { return .failed }
        switch state {
        case .asking: return .needsYou
        case .working, .betweenSteps: return .working
        case .quiet: return .stale
        case .pausedByYou, .pausedLimit, .pausedWeek: return .paused
        case .waitsForTeam: return .pending
        case .passed, .finished: return .done
        case .stopped: return .stopped
        case .failed: return .failed
        }
    }

    private func fillWorking(_ row: inout IslandGraphRow) {
        row.canPause = true
        row.track = track
        row.sentBack = sentBack
        let step = stepWords
        if let f = failedStep {
            // "Step 3 of 4 · Run the tests hit an error" (its problem card offers to run it again)
            row.line2 = [step, f.displayName + " hit an error"].filter { !$0.isEmpty }.joined(separator: " · ")
            return
        }
        if state == .betweenSteps {
            if runnerOff {
                row.line2 = "Waits for the graph runner"
                return
            }
            // the step about to start, else the one the engine says comes next
            let next = g.nodes.first { $0.status == "ready" }.map { $0.displayName }
                ?? g.now.flatMap { $0.nextName.isEmpty ? nil : $0.nextName }
            var s = step.isEmpty ? "Between steps" : step + " done"
            if let n = next { s += " · moving to " + n }
            row.line2 = s
            return
        }
        let once = atOnce
        var main: [String] = []
        if !step.isEmpty { main.append(step) }
        if once.count >= 2 {
            let names = Array(once.names.prefix(3))
            if names.count <= 1 {
                // copies of one step (the engine names each step once): "Write · 3 at once"
                main.append((names.first ?? shown?.displayName ?? "Steps") + " · \(once.count) at once")
            } else {
                main.append(names.joined(separator: ", ") + (once.count > names.count ? " +\(once.count - names.count)" : "") + " at once")
            }
        } else if let sh = shown {
            main.append(sh.displayName)
        } else if let sn = g.now?.stepName, !sn.isEmpty {
            main.append(sn)
        }
        if sentBack > 0 { main.append(sentBack == 1 ? "sent back once" : "sent back \(sentBack) times") }
        row.line2 = main.joined(separator: " · ")
        row.line2Meta = [ai, roundWords].filter { !$0.isEmpty }.joined(separator: " · ")
        if state == .quiet {
            let m = quietMinutes
            row.titleDim = true
            row.line3 = m > 0 ? "No news for \(m) min" : "No news for a while"
            row.action = .watch
            return
        }
        var l3: [String] = []
        if let d = once.done, let of = once.of, d > 0, of >= 2 { l3.append("\(d) of \(of) done") }
        if let d = doing {
            l3.append(d)
            row.line3 = l3.joined(separator: " · ")
            row.line3Age = doingAt.map { IslandWords.ago(now - $0) } ?? ""
        } else if let st = startedAt {
            l3.append("Started " + IslandWords.ago(now - st))
            row.line3 = l3.joined(separator: " · ")
        } else if !l3.isEmpty {
            row.line3 = l3.joined(separator: " · ")
        }
    }

    /// The graph's steps in place order, worded like its Steps list.
    var stepRows: [IslandStepRow] {
        let order = g.nodes.map { $0.id }
        let paused = g.stepsHoldStill(teamUp: state != .waitsForTeam)
        let steps = g.nodes.filter { $0.role != "end" }
            .sorted { (places.place[$0.id] ?? Int.max, order.firstIndex(of: $0.id) ?? 0) < (places.place[$1.id] ?? Int.max, order.firstIndex(of: $1.id) ?? 0) }
        return steps.enumerated().map { i, n in
            var words: [String] = []
            var time = ""
            if n.status == "running" && !paused && state != .waitsForTeam {
                let d = n.liveDoingPlain.isEmpty ? Words.doing(n.liveDoing) : n.liveDoingPlain
                words.append(d.map { IslandWords.lowerFirst($0) } ?? "working")
                if !n.runtime.isEmpty { words.append(Words.ai(n.runtime, n.model)) }
                if let st = n.startedAt { time = PongUI.duration(max(0, now - st)) }
            } else {
                if n.visits > 1 { words.append(n.visits == 2 ? "sent back once" : "sent back \(n.visits - 1) times") }
                words.append(n.stepWords(running: g.isRunning, paused: paused && n.status == "running",
                                         teamDown: state == .waitsForTeam))
                if n.status == "done", let a = n.startedAt, let b = n.finishedAt, b > a { time = PongUI.duration(b - a) }
            }
            return IslandStepRow(number: String(format: "%02d", i + 1), nodeId: n.id,
                                 status: n.pongStatus(graphRunning: g.isRunning, graphPaused: paused),
                                 name: n.displayName, words: words.joined(separator: " · "), time: time)
        }
    }

    /// "Checkout fix, Northwind. Working: Run the tests, step 3 of 4, Claude Sonnet, round 2 of 3.
    /// Running a command, 20 seconds ago. 26 minutes."
    private func spoken(_ row: IslandGraphRow) -> String {
        var s = row.name + ", " + row.team + ". "
        switch state {
        case .working, .quiet:
            let what = atOnce.count >= 2 ? atOnce.names.joined(separator: ", ") + " at once" : (shown?.displayName ?? "")
            let bits = [what, spokenPlace, ai, roundWords].filter { !$0.isEmpty }
            s += (state == .quiet ? "Quiet" : "Working") + (bits.isEmpty ? "" : ": " + bits.joined(separator: ", ")) + ". "
            if let l3 = row.line3 {
                s += l3.replacingOccurrences(of: " · ", with: ", ")
                if let at = doingAt, state == .working, doing != nil { s += ", " + IslandWords.spoken(now - at) + " ago" }
                s += ". "
            }
        default:
            s += row.line2.replacingOccurrences(of: " · ", with: ", ") + ". "
        }
        if g.isRunning, g.wallMin >= 1 { s += IslandWords.spoken(g.wallMin * 60) + "." }
        else if !g.isRunning { s += "Finished " + row.time + "." }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Words for time

enum IslandWords {
    /// "just now", "20 s ago", "3 min ago", "2 h ago", "1 h 5 min ago": a doing line's age.
    static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 || h >= 6 ? "\(h) h ago" : "\(h) h \(m) min ago"
    }

    /// "12 min ago", "1 h ago": a finished row's time, or a message's (from a moment).
    static func agoShort(_ t: Double, now: Double) -> String {
        guard t > 0 else { return "" }
        let s = max(0, Int(now - t))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }

    /// How long a question has waited: "just now" for 30 s, then "4 min", "1 h 5 min".
    static func waited(_ seconds: Double) -> String {
        seconds < 30 ? "just now" : PongUI.duration(seconds)
    }

    /// A duration as VoiceOver reads it: "20 seconds", "12 minutes", "1 hour 5 minutes".
    static func spoken(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return s == 1 ? "1 second" : "\(s) seconds" }
        if s < 3600 { return Words.plural(s / 60, "minute") }
        let h = s / 3600, m = (s % 3600) / 60
        return Words.plural(h, "hour") + (m == 0 ? "" : " " + Words.plural(m, "minute"))
    }

    /// "Checking the tests" → "checking the tests" (an initialism like "CI" stays, and so does "I").
    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        let second = s.dropFirst().first
        if let c = second, c.isUppercase { return s }
        if f == "I", second.map({ $0 == " " || $0 == "'" || $0 == "’" }) ?? true { return s }
        return f.lowercased() + s.dropFirst()
    }
}

// MARK: - What moves with the clock

/// The closed line's turns (§4.3): every few seconds the next working graph. The order is the order
/// items first appeared; an item keeps its place until it goes away (a graph that changes state comes
/// back as a new item at the end).
struct IslandRotation: Equatable {
    private(set) var order: [String] = []
    private(set) var index = 0
    private(set) var shownAt: Double = 0

    var currentKey: String? { order.isEmpty ? nil : order[min(index, order.count - 1)] }

    mutating func update(keys: [String], now: Double) {
        let current = currentKey
        let keep = Set(keys)
        order = order.filter { keep.contains($0) } + keys.filter { !order.contains($0) }
        if let c = current, let i = order.firstIndex(of: c) {
            index = i
        } else {
            // the item on show went away: the next one in its place, shown from now
            index = order.isEmpty ? 0 : min(index, order.count - 1)
            shownAt = now
        }
        if order.count <= 1 { shownAt = now }
    }

    /// Moves on when the item has had its time. Never while `hold` (the pointer is on the closed
    /// panel, or "Don't move"). True when it moved.
    mutating func tick(now: Double, every: Double, hold: Bool) -> Bool {
        guard order.count > 1, every > 0, !hold else {
            if hold { shownAt = now }   // a full turn after the pointer leaves
            return false
        }
        guard now - shownAt >= every - 1e-9 else { return false }
        index = (index + 1) % order.count
        shownAt = now
        return true
    }
}

/// The nudge of a new question (§14.3). A question is new the first read it appears in; the questions
/// already there at the first read are not (the model gives it good reads of the feed only, so that is
/// the feed's first good read, not the empty one before it). Several arriving together make one nudge
/// ("and 2 more"); one arriving while a nudge shows joins it. None at night (with "Quiet at night"), none
/// while the panel is open, none when the setting says otherwise or the screen is full-screen and hidden.
struct IslandNudgeQueue: Equatable {
    private(set) var seen: Set<String> = []
    private(set) var current: IslandNudge?
    private(set) var started = false

    /// Read the needs. Returns the ones that are new since the last read, oldest first (the controller
    /// opens the whole panel at the first with "Open the whole panel").
    @discardableResult
    mutating func update(_ needs: [IslandNeed], now: Double, settings: IslandSettings, allowed: Bool,
                         panelOpen: Bool) -> [IslandNeed] {
        let keys = Set(needs.map { $0.key })
        defer { seen = keys }
        guard started else {
            started = true
            return []
        }
        // a nudge whose question was answered elsewhere folds away
        if let c = current, !keys.contains(c.key) { current = nil }
        let fresh = needs.filter { !seen.contains($0.key) }
        guard !fresh.isEmpty else { return [] }
        guard settings.onQuestion == .nudge, allowed, !panelOpen else { return fresh }
        let until: Double? = settings.nudgeSeconds > 0 ? now + settings.nudgeSeconds : nil
        if let c = current {
            current = IslandNudgeQueue.nudge(for: needs.first { $0.key == c.key } ?? fresh[0], more: c.more + fresh.count,
                                             since: c.since, until: until)
        } else {
            current = IslandNudgeQueue.nudge(for: fresh[0], more: fresh.count - 1, since: now, until: until)
        }
        return fresh
    }

    static func nudge(for n: IslandNeed, more: Int, since: Double, until: Double?) -> IslandNudge {
        let say = n.subject + (n.kind == .chat ? " asks you" : " needs you")
        return IslandNudge(key: n.key, title: n.text, source: more > 0 ? say + " · and \(more) more" : n.source, more: more,
                           since: since, until: until, announcement: say + ": " + n.text)
    }

    /// Folds back when its time is up. True when it folded.
    mutating func tick(now: Double) -> Bool {
        guard let c = current, let u = c.until, now >= u - 1e-9 else { return false }
        current = nil
        return true
    }

    /// The pointer visited it, or the panel opened: it has done its job.
    mutating func dismiss() { current = nil }
}

/// The notch panel's model: the state of the last read plus what moves with the clock (the rotation,
/// the 3-second note of a graph that just finished, the nudge). The controller calls `update` on every
/// feed change and `tick` every second while the closed panel shows; `closed` is what to draw beside
/// the notch.
struct IslandModel {
    /// Things the controller knows that the model can't.
    struct Flags: Equatable {
        /// The pointer is over the closed panel (the line holds still).
        var pointerOverClosed = false
        var panelOpen = false
        /// A nudge may show (false in a full-screen app with "Always hide it").
        var nudgeAllowed = true
    }

    private(set) var state = IslandState()
    private(set) var settings = IslandSettings()
    private(set) var rotation = IslandRotation()
    private(set) var nudges = IslandNudgeQueue()
    /// A graph that just finished: its line and mark, until when.
    private(set) var finishedNote: (line: IslandLine, mark: IslandMark, until: Double)?
    private var wasRunning: [String: Bool] = [:]
    private var started = false
    private(set) var now: Double = 0
    private(set) var flags = Flags()
    /// New questions in the last read (for "Open the whole panel", and VoiceOver's announcement).
    private(set) var arrived: [IslandNeed] = []
    /// Said once by VoiceOver when new questions arrive (nil: nothing to say).
    private(set) var announcement: String?

    init() {}

    /// The quiet hours: 22:00 to 08:00.
    static func isQuietNight(_ t: Double, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: Date(timeIntervalSince1970: t))
        return h >= 22 || h < 8
    }

    mutating func update(_ input: IslandInput, settings: IslandSettings, flags: Flags) {
        self.settings = settings
        self.flags = flags
        now = input.now
        state = IslandState.build(input, settings: settings)
        // a graph seen running that has now finished gets its 3-second note
        if started {
            for g in input.graphs where !g.isRunning && wasRunning[g.key] == true {
                let (tail, mark): (String, PongStatus) = {
                    switch GraphRead.ending(g) {
                    case .stopped: return ("stopped", .stopped)
                    case .passed: return ("passed", .done)
                    case .failed: return ("failed", .failed)
                    default: return ("finished", .done)
                    }
                }()
                finishedNote = (IslandLine(key: "done:" + g.key, name: g.displayTitle, tail: "· " + tail,
                                           tone: mark == .failed ? .fail : .normal, spoken: g.displayTitle + " " + tail),
                                IslandMark(status: mark, count: nil), now + 3)
            }
        }
        wasRunning = Dictionary(input.graphs.map { ($0.key, $0.isRunning) }, uniquingKeysWith: { a, b in a || b })
        rotation.update(keys: state.rotation.map { $0.key }, now: now)
        let quiet = settings.quietNight && IslandModel.isQuietNight(now, calendar: input.calendar)
        // the nudge reads only good reads of the feed: its first one is the baseline (what is open then
        // is not new), and a failed read keeps the last good graphs, so skipping it misses nothing
        arrived = input.loaded
            ? nudges.update(state.needs, now: now, settings: settings, allowed: flags.nudgeAllowed && !quiet,
                            panelOpen: flags.panelOpen)
            : []
        if quiet { arrived = [] }   // nothing pops up at night, the whole panel included
        // VoiceOver says each new question once, with the nudge or without it ("Only turn the count
        // amber"); one joining a nudge on show is said too, not the one already said
        announcement = arrived.first.map {
            IslandNudgeQueue.nudge(for: $0, more: 0, since: now, until: nil).announcement
                + (arrived.count > 1 ? ". And \(arrived.count - 1) more." : "")
        }
        started = true
    }

    /// The clock moved. True when anything beside the notch changed.
    @discardableResult
    mutating func tick(now t: Double, flags: Flags) -> Bool {
        now = t
        self.flags = flags
        var changed = false
        if let n = finishedNote, t >= n.until - 1e-9 { finishedNote = nil; changed = true }
        if nudges.tick(now: t) { changed = true }
        if flags.panelOpen, nudges.current != nil { nudges.dismiss(); changed = true }
        let hold = flags.pointerOverClosed || settings.rotateSeconds <= 0 || state.urgentLine != nil
        if rotation.tick(now: t, every: settings.rotateSeconds, hold: hold) { changed = true }
        announcement = nil
        return changed
    }

    /// The pointer visited the nudge, or it was clicked: the panel opens at its question.
    mutating func nudgeLooked() { nudges.dismiss() }

    /// Beside the notch now (§4.2, §4.3, §4.4).
    var closed: IslandClosed {
        var c = IslandClosed()
        c.accessibilityLabel = state.accessibilityLabel
        c.nudge = nudges.current
        let s = state
        if let u = s.urgentLine {
            c.line = u
            c.marks = s.urgentMarks
            // while a nudge shows, the words beside the notch name the same question as the nudge
            // (not the oldest one), so the two never point at different graphs
            if u.tone == .you, let n = c.nudge, let need = s.needs.first(where: { $0.key == n.key }) {
                c.line = need.line
            }
        } else if let n = finishedNote, now < n.until {
            c.line = n.line
            c.marks = [n.mark]
        } else if let key = rotation.currentKey, let line = s.rotation.first(where: { $0.key == key }) ?? s.rotation.first {
            c.line = line
            c.marks = s.rotationMarks
        } else if let r = s.restLine {
            c.line = r
            c.marks = s.restMarks
        }
        switch settings.beside {
        case .words: break
        case .count: c.line = nil
        case .needsMe:
            if s.needsCount == 0 { c.line = nil; c.marks = [] }
        }
        return c
    }
}
