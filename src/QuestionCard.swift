import AppKit

// One question card, everywhere a question shows: Home, a graph, a chat, ⌘J
// (design-language.md §3, "The question card"). The question first, in plain words;
// three lines of context; "What you're deciding" (2.0): the facts behind it, each one
// click from its file; the files to read; Jev's odds; a note; buttons that say what
// they do. Stop asks twice. The answers are the gate's own: an AI never words a button.

/// Runs a graph's commands from anywhere and says how it went.
enum GraphActions {
    /// Answer a gate. `note` goes to the step that redoes the work. `extend`: the person allowed one more
    /// round of its loop (its rounds were spent), as the island's "Allow one more round" does.
    static func answer(_ g: GGraph, gate: String, outcome: String, note: String = "", extend: Bool = false,
                       done: @escaping (Bool, String) -> Void) {
        var args = ["-s", g.session, "goal", "resume", "--id", g.id, "--node", gate, "--outcome", outcome]
        // "--note=…" in one word: a note that starts with "-" is otherwise read as a flag
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args += ["--note=" + n] }
        if extend { args += ["--extend", "1"] }
        run(args, done: done)
    }

    static func pause(_ g: GGraph, done: @escaping (Bool, String) -> Void) {
        run(["-s", g.session, "goal", "pause", "--id", g.id], done: done)
    }

    static func resume(_ g: GGraph, done: @escaping (Bool, String) -> Void) {
        run(["-s", g.session, "goal", "resume", "--id", g.id], done: done)
    }

    static func stop(_ g: GGraph, done: @escaping (Bool, String) -> Void) {
        run(["-s", g.session, "goal", "cancel", "--id", g.id], done: done)
    }

    /// Answer a question a chat asked with `pong ask`: the choice's key, or a note alone.
    static func answerAsk(_ q: GChatAsk, choice: String, note: String, done: @escaping (Bool, String) -> Void) {
        var args = ["-s", q.session, "ask", "answer", "--id", q.id]
        if !choice.isEmpty { args += ["--choice", choice] }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args += ["--note=" + n] }
        run(args, done: done)
    }

    static func retry(_ g: GGraph, node: String, done: @escaping (Bool, String) -> Void) {
        run(["-s", g.session, "graph", "retry", "--id", g.id, "--node", node], done: done)
    }

    private static func run(_ args: [String], done: @escaping (Bool, String) -> Void) {
        GraphCLI.run(args, timeout: 60) { r in
            let err = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            done(r.code == 0, r.code == 0 ? "" : String(err.prefix(200)))
            GraphStore.shared.refresh()
        }
    }

    /// A failed command in plain words for a toast: the engine's own line when it is already a sentence
    /// (`Words.engineSentence`), else `fallback`. What the engine said goes to the log either way, without
    /// a command it suggests (one to answer a question again carries the person's note).
    static func failure(_ said: String, _ fallback: String, log what: String) -> String {
        let t = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let logged = (t.components(separatedBy: "pong -s ").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Pong.log("\(what) failed: " + (logged.isEmpty ? "(no error text)" : String(logged.prefix(400))))
        return Words.engineSentence(t) ?? fallback
    }

    /// Open a file a person clicked: a document in its app; anything else (a script, an app,
    /// a .command) is shown in Finder, never run. ⌥ always shows it in Finder.
    static func openSafely(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            Toast.show("Not on this Mac. The path is copied.")
            return
        }
        let viewable: Set<String> = ["md", "markdown", "txt", "json", "csv", "tsv", "log", "yaml", "yml", "pdf",
                                     "png", "jpg", "jpeg", "gif", "svg", "webp", "html", "htm"]
        let reveal = NSEvent.modifierFlags.contains(.option)
        if !reveal && viewable.contains(url.pathExtension.lowercased()) && !FileManager.default.isExecutableFile(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// A short message at the bottom centre of the window: one at a time, 4 s (6 s with an action). A
/// longer one wraps onto up to three lines rather than losing its end (the fix is usually there).
final class Toast: NSView {
    private static weak var current: Toast?
    private let text = PongUI.label("", PongType.body, PongColor.textPrimary, lines: 3)
    private var action: PongButton?
    private var hideWork: DispatchWorkItem?
    /// The widest the whole toast gets, and the most lines its text takes.
    static let maxWidth: CGFloat = 460
    static let maxLines = 3

    static func show(_ message: String, warn: Bool = false, action: String? = nil, in window: NSWindow? = nil,
                     onAction: (() -> Void)? = nil) {
        guard let win = window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let host = win.contentView else { return }
        current?.removeFromSuperview()
        let t = Toast(frame: .zero)
        t.text.stringValue = message
        t.text.textColor = warn ? PongColor.fail : PongColor.textPrimary
        if let action, let onAction {
            let b = PongButton(title: action, style: .quiet, size: .small)
            b.onPress = { onAction(); t.dismiss() }
            t.action = b
            t.addSubview(b)
        }
        // the toast is 16 + text + 8 + action + 8 wide (layout() puts the action 8 pt from the edge), so the
        // label is exactly textW wide with an action or without one
        let actionW = t.action.map { $0.intrinsicContentSize.width } ?? 0
        let room = min(maxWidth, host.bounds.width - 32) - actionW - 32
        let natural = ceil(t.text.attributedStringValue.size().width) + 4
        let textW = max(40, min(room, natural))
        // measured 4 pt narrower than the label: its cell keeps 2 pt each side, and a line measured as
        // fitting that then wraps would be cut off with "…" (often the end, where the fix is)
        let textH = natural <= textW ? 18 : Toast.textHeight(t.text.attributedStringValue, width: textW - 4)
        t.textHeight = textH
        let w = textW + actionW + 32
        t.frame = NSRect(x: (host.bounds.width - w) / 2, y: 20, width: w, height: max(36, textH + 18))
        t.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        host.addSubview(t)
        current = t
        NSAccessibility.post(element: t, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        t.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PongMotion.reduced ? 0 : PongMotion.base
            t.animator().alphaValue = 1
        }
        t.schedule(after: onAction == nil ? (warn ? 6 : 4) : 6)
    }

    private var textHeight: CGFloat = 18

    /// The text's height at a width, three lines at most.
    static func textHeight(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        let r = s.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let line = ceil(NSLayoutManager().defaultLineHeight(for: PongType.body))
        return min(ceil(r.height) + 2, line * CGFloat(maxLines) + 2)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        PongTheme.applyFloating(self)
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = Toast.maxLines
        text.cell?.truncatesLastVisibleLine = true
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var right = bounds.width - 16
        if let a = action {
            let w = a.intrinsicContentSize.width
            a.frame = NSRect(x: right - w + 8, y: (bounds.height - 24) / 2, width: w, height: 24)
            right -= w
        }
        text.frame = NSRect(x: 16, y: 9, width: max(40, right - 16), height: max(18, textHeight))
    }

    private func schedule(after s: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    func dismiss() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PongMotion.reduced ? 0 : PongMotion.exit
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }
}

/// One answer a card offers: its button words, its style, and what it does.
struct QuestionAnswer {
    enum Kind { case approve, sendBack, stopByAnswer, stopGraph, route, option, reply }
    let kind: Kind
    /// The gate outcome, an option's key ("1"…), or "" (stop the whole graph; reply with a note).
    let outcome: String
    let title: String
    let what: String
}

/// A question for the person, and where it comes from: a graph's gate, or a chat's `pong ask`.
struct QuestionModel {
    enum Source {
        case gate(GGraph, GGate)
        case ask(GChatAsk)
    }

    let source: Source
    let key: String
    let question: String
    let context: [String]
    /// "Research team › Weekly report › Final review", or "Chat · Weekly report".
    let origin: String
    let openedAt: Double
    let answers: [QuestionAnswer]
    /// What a toast calls it: the graph's or the chat's name.
    let subject: String
    /// What is being decided, in more depth: the facts, each with the file it comes from (C1).
    let detail: [GDetail]
    /// Who wrote the detail: "CyberPong", "Claude Haiku", "the chat", "the graph's designer".
    let detailBy: String
    /// A helper AI is still writing the plain words or the detail: the card says "Details coming…".
    let detailPending: Bool
    /// A gate's plain-words rewrite is on its way (its notification waits for it, two minutes at most).
    let plainWordsPending: Bool
    private let rawFiles: [String]
    private let roots: [String]
    private let advice: GAdvice?

    var isChat: Bool { if case .ask = source { return true } else { return false } }
    var graph: GGraph? { if case .gate(let g, _) = source { return g } else { return nil } }
    /// Where the card's ↗ goes: the graph, or the chat that asked.
    var graphKey: String? { graph?.key }
    var chatKey: String? { if case .ask(let a) = source { return a.chatKey } else { return nil } }

    init(graph g: GGraph, gate: GGate) {
        source = .gate(g, gate)
        key = g.key + "#" + gate.node
        question = gate.ask?.question ?? (gate.reason.isEmpty
            ? (Words.isYourAnswer(gate.node) ? "Go on with \(g.displayTitle)?" : "Go on with \(Words.name(gate.node))?")
            : gate.reason)
        context = gate.ask?.context ?? (gate.summary.isEmpty ? [] : [String(gate.summary.prefix(300))])
        // the person's own step ("Your answer") adds nothing to "Needs you": the crumb ends at the graph
        origin = ([g.teamName, g.displayTitle] + (Words.isYourAnswer(gate.node) ? [] : [Words.name(gate.node)]))
            .joined(separator: " › ")
        openedAt = gate.at ?? g.lastActivity
        subject = g.displayTitle
        detail = gate.ask?.detail ?? []
        detailBy = gate.ask?.detailBy ?? ""
        detailPending = gate.askPending || (gate.ask?.detailPending ?? false)
        plainWordsPending = gate.askPending
        rawFiles = (gate.ask?.files ?? []) + gate.artifacts
        roots = [gate.ask?.root ?? "", g.filesRoot]
        advice = gate.advice
        answers = QuestionModel.gateAnswers(g, gate)
    }

    init(ask a: GChatAsk, store: GraphStore? = nil) {
        source = .ask(a)
        key = a.key
        question = a.question
        context = a.context
        let chat = (store ?? GraphStore.shared).architects.first { $0.id == a.architect && $0.session == a.session }
        origin = "Chat · " + (chat?.displayTitle ?? TeamNames.name(a.session))
        openedAt = a.createdAt
        subject = chat?.displayTitle ?? "the chat"
        detail = a.detail
        detailBy = a.detailBy
        detailPending = a.detailPending
        plainWordsPending = false
        rawFiles = a.files
        roots = [chat?.cwd ?? ""]
        advice = nil
        if a.options.isEmpty {
            answers = [QuestionAnswer(kind: .reply, outcome: "", title: "Reply", what: "Your note goes back to the chat.")]
        } else {
            answers = a.options.map {
                QuestionAnswer(kind: .option, outcome: $0.key, title: $0.label,
                               what: $0.what.isEmpty ? "Tells the chat: \($0.label)." : $0.what)
            }
        }
    }

    /// The files it is about: full paths that exist on this Mac.
    var files: [String] {
        var out: [String] = []
        for f in rawFiles {
            if let p = resolve(f), !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// A path as a full path that exists here: as given, or under the question's folders. nil otherwise.
    private func resolve(_ f: String) -> String? {
        let fm = FileManager.default
        var p = (f as NSString).expandingTildeInPath
        if !p.hasPrefix("/") {
            for root in roots where !root.isEmpty {
                let c = ((root as NSString).expandingTildeInPath as NSString).appendingPathComponent(p)
                if fm.fileExists(atPath: c) { p = c; break }
            }
        }
        return p.hasPrefix("/") && fm.fileExists(atPath: p) ? p : nil
    }

    /// The file a point comes from, as a full path to open: resolved here when it can be (a name the
    /// card's own files carry counts), else as written, so a click still says where it was. nil: none.
    func detailFile(_ d: GDetail) -> String? {
        let f = d.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return nil }
        if let p = resolve(f) { return p }
        let base = (f as NSString).lastPathComponent
        if let p = files.first(where: { ($0 as NSString).lastPathComponent == base }) { return p }
        return (f as NSString).expandingTildeInPath
    }

    /// Who wrote "What you're deciding", in a line under it ("" when nobody said).
    var detailAttribution: String { QuestionWords.attribution(detailBy) }

    /// The files the points link to: the card's file row doesn't repeat them while the points show.
    var linkedFiles: Set<String> { Set(detail.compactMap { detailFile($0) }) }

    /// Everything a card draws from its words: a page redraws a card when this changes, so a
    /// plain-words rewrite or details that arrive late show up without a click.
    var redrawKey: String {
        var s = question + "|" + context.joined(separator: "¶") + "|" + detailBy + "|\(detailPending)|"
        s += detail.map { $0.text + "@" + $0.file + "#" + $0.location }.joined(separator: "¶")
        return s
    }

    /// A gate's answers, in the card's words: Approve · Send back with a note · Stop the graph.
    private static func gateAnswers(_ graph: GGraph, _ gate: GGate) -> [QuestionAnswer] {
        var out: [QuestionAnswer] = []
        var stopOffered = false
        for o in graph.gateOutcomes(gate.node) {
            let what = gate.ask?.choices[o] ?? ""
            let backTo = graph.edges.first { $0.from == gate.node && $0.on == o }.flatMap { graph.node($0.to) }
            switch o {
            case "approved":
                let next = graph.edges.first { $0.from == gate.node && ($0.on == "approved" || $0.on == "done") }
                    .flatMap { graph.node($0.to) }
                let fallback = next.map { $0.role == "end" ? "Approve finishes the graph." : "Approve goes on to \(Words.name($0.id))." }
                    ?? "Approve lets the graph go on."
                out.append(.init(kind: .approve, outcome: o, title: "Approve", what: what.isEmpty ? fallback : what))
            case "rejected":
                if backTo == nil || backTo?.role == "end" {
                    stopOffered = true
                    out.append(.init(kind: .stopByAnswer, outcome: o, title: "Stop the graph",
                                     what: what.isEmpty ? "Stop ends the graph here. It stays in the list." : what))
                } else {
                    out.append(.init(kind: .sendBack, outcome: o, title: "Send back with a note",
                                     what: what.isEmpty ? "Send back returns the work to \(Words.name(backTo?.id ?? "the step before")) with your note." : what))
                }
            default:
                let route = o.hasPrefix("route:") ? String(o.dropFirst(6)) : o
                out.append(.init(kind: .route, outcome: o, title: Words.name(route),
                                 what: what.isEmpty ? "Goes to \(Words.name(backTo?.id ?? route))." : what))
            }
        }
        if !stopOffered {
            out.append(.init(kind: .stopGraph, outcome: "", title: "Stop the graph",
                             what: "Stop ends the whole graph now. Steps at work stop; it stays in the list."))
        }
        return out
    }

    /// Jev's odds under the card's own words, most likely first.
    var jevLine: (lead: String, rest: String)? {
        guard let a = advice, !a.blind, !a.pending, !a.probabilities.isEmpty else { return nil }
        let names = Dictionary(answers.filter { !$0.outcome.isEmpty }.map { ($0.outcome, $0.title) }, uniquingKeysWith: { a, _ in a })
        func word(_ k: String) -> String {
            if let n = names[k] { return n.replacingOccurrences(of: " with a note", with: "") }
            return Words.name(k.hasPrefix("route:") ? String(k.dropFirst(6)) : k)
        }
        let probs = a.probabilities
        guard let top = probs.first else { return nil }
        let rest = probs.dropFirst().map { "\(word($0.0)) \(ProbText.pct($0.1))" }.joined(separator: " · ")
        if top.1 < 0.5 {
            return ("Jev is unsure", probs.map { "\(word($0.0)) \(ProbText.pct($0.1))" }.joined(separator: " · "))
        }
        return ("\(word(top.0)) \(ProbText.pct(top.1))", rest)
    }

    /// Send an answer. The note goes with it; `extend` allows a gate's loop one more round first.
    func send(_ a: QuestionAnswer, note: String, extend: Bool = false, done: @escaping (Bool, String) -> Void) {
        switch source {
        case .gate(let g, let gate):
            if a.kind == .stopGraph {
                GraphActions.stop(g, done: done)
            } else {
                GraphActions.answer(g, gate: gate.node, outcome: a.outcome, note: note, extend: extend, done: done)
            }
        case .ask(let q):
            GraphActions.answerAsk(q, choice: a.outcome, note: note, done: done)
        }
    }
}

extension QuestionModel {
    /// Hold a new gate's notification while its plain words are being written and it is under two
    /// minutes old: the notification then says the question the card will say.
    static func holdNotification(_ q: QuestionModel, now: Double = Date().timeIntervalSince1970) -> Bool {
        QuestionWords.holdNotification(plainWordsPending: q.plainWordsPending, openedAt: q.openedAt, now: now)
    }

    /// A notification's body: the question, then the first line of context. Never the details:
    /// a notification can show on a locked screen.
    static func notificationBody(_ q: QuestionModel) -> String {
        QuestionWords.notificationBody(question: q.question, context: q.context)
    }
}

/// What a question says about itself outside the card's drawing: who wrote its details, and what its
/// notification says and when. Plain values in and out (tests/swift/questions checks them).
enum QuestionWords {
    /// How long a gate's notification waits for its plain words.
    static let plainWordsWait: Double = 120

    /// The line under "What you're deciding": who wrote the points ("" when nobody said).
    static func attribution(_ by: String) -> String {
        switch by.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": return ""
        case "Claude Haiku": return "Summary by Claude Haiku from the files · check the files for the full picture"
        case "the chat": return "Written by the chat"
        case "CyberPong": return "Written by CyberPong from the step's report"
        case "the graph's designer": return "Written by the graph's designer"
        case "the graph's designer and Claude Haiku":
            return "Written by the graph's designer, with points by Claude Haiku from the files · check the files for the full picture"
        case "the graph's designer and CyberPong": return "Written by the graph's designer, with points from the step's report"
        case let who: return "Written by \(who)"
        }
    }

    /// An answer the engine refused for a reason "try again" doesn't fix, in plain words: the question's
    /// rounds are spent (`moreRounds`: one more round can be allowed, then the answer goes), or it isn't
    /// open any more (answered elsewhere, or its graph ended). nil: any other refusal.
    static func answerRefusal(_ said: String) -> (words: String, moreRounds: Bool)? {
        if said.contains("--extend") || said.contains("one more round") {
            return ("Its rounds are spent: allow one more round to send your answer.", true)
        }
        if ["is not an open gate", "nothing to resume", "no question ", " is already "].contains(where: { said.contains($0) }) {
            return ("This question isn't open any more, so your answer wasn't sent.", false)
        }
        return nil
    }

    /// A gate whose plain words are still being written waits, two minutes at most.
    static func holdNotification(plainWordsPending: Bool, openedAt: Double, now: Double) -> Bool {
        plainWordsPending && now - openedAt < plainWordsWait
    }

    /// The question, then the first line of context that has words. Never the details.
    static func notificationBody(question: String, context: [String]) -> String {
        let why = context.lazy.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        return why.isEmpty ? question : question + "\n" + why
    }

    /// The card's file row: the question's files, less those a point above already links (one link per
    /// file on a card), in their order.
    static func fileRow(_ files: [String], linked: Set<String>) -> [String] {
        let seen = Set(linked.map { ($0 as NSString).standardizingPath })
        return files.filter { !seen.contains(($0 as NSString).standardizingPath) }
    }

    /// What a file link says: the file's name; two files with one name add their folder's name.
    static func fileTitles(_ paths: [String]) -> [String] {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        return zip(paths, names).map { path, name in
            names.filter { $0 == name }.count > 1
                ? name + " — " + ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent : name
        }
    }

    /// Where a card that is taller than its place stops, so no line is cut in half: the lowest gap
    /// between its pieces (each a top and a bottom, from the card's top) at or above `limit`, and not
    /// above `floor`. `limit` itself when it already falls in a gap, or when no gap is low enough.
    static func cleanCut(_ spans: [(top: Double, bottom: Double)], limit: Double, floor: Double) -> Double {
        func clean(_ y: Double) -> Bool { !spans.contains { $0.top < y - 0.5 && $0.bottom > y + 0.5 } }
        if clean(limit) { return limit }
        let candidates = spans.flatMap { [$0.top, $0.bottom] }.filter { $0 <= limit && $0 >= floor && clean($0) }
        return candidates.max() ?? limit
    }
}

enum ProbText {
    static func pct(_ p: Double) -> String {
        if p > 0 && p < 0.005 { return "<1%" }
        if p < 1 && p > 0.995 { return ">99%" }
        return "\(Int((p * 100).rounded()))%"
    }
}

/// The card. `compact` (a graph's or a chat's banner, every card after Home's first) shows the header,
/// the question, its first line of context and the buttons; "Details ›" opens it in place to the full card.
final class QuestionCardView: NSView {
    var onOpen: (() -> Void)?
    /// Called after an answer went through, so a page can re-read.
    var onAnswered: (() -> Void)?
    /// Called when the card's height changed (details opened or folded, a note, Details ›, the receipt),
    /// so the page lays its cards out again.
    var onHeightChange: (() -> Void)?

    let model: QuestionModel
    /// Header, question, one line of context and the buttons. Setting it opens or folds the card in place.
    var compact: Bool {
        didSet {
            guard compact != oldValue else { return }
            if collapsible {
                if compact { QuestionCardView.opened.remove(model.key) } else { QuestionCardView.opened.insert(model.key) }
            }
            applyMode()
            heightChanged()
        }
    }
    /// The focused card shows its keycaps and takes ⌘1–3.
    var focused = false { didSet { restyleButtons(); needsLayout = true } }

    /// The answers part: a note, the buttons (with Details › or Show less) and what the pointed-at
    /// button does. A page that gives the card less room than it needs pins this under the card's
    /// scrolling part, so the buttons stay in sight: it sets `footerPinned` and adds `footer` to its
    /// own view (`bodyHeight` and `pinnedFooterHeight` say how tall each part is).
    var footer: NSView { footerView }
    /// A note or a reply is being typed here, wherever the answers part sits (a page may pin it outside
    /// the card): a page leaves the card alone until it is done.
    var isEditingNote: Bool { noteField.currentEditor() != nil }
    var footerPinned = false {
        didSet {
            guard footerPinned != oldValue else { return }
            if !footerPinned { addSubview(footerView) }
            needsLayout = true
            footerView.needsLayout = true
        }
    }
    /// Draws the focus ring on another view (a page's banner box, when the footer is pinned outside the
    /// card); nil: on the card itself.
    var externalBorder: ((CGFloat, CGColor) -> Void)? { didSet { restyleButtons() } }

    /// Made compact, so it can fold back ("Show less").
    private let collapsible: Bool
    private let footerView = CardFooterView()
    /// Compact cards the person opened: a redraw (a late detail, a new question) keeps them open.
    private static var opened: Set<String> = []

    private let diamond = NSImageView()
    private let eyebrow = PongUI.eyebrow("Needs you", color: PongColor.you)
    private let source = PongUI.label("", PongType.secondary, PongColor.textSecondary)
    private let waited = PongUI.label("", PongType.meta, PongColor.textTertiary)
    private let questionText = PongUI.label("", PongType.question, PongColor.textPrimary, lines: 3)
    private let contextText = PongUI.label("", PongType.body, PongColor.textSecondary, lines: 5)
    /// A compact card's one line of context.
    private let contextLine = PongUI.label("", PongType.body, PongColor.textSecondary)
    private let details: QuestionDetailView
    private let expand = PongButton(title: "Details ›", style: .quiet, size: .small)
    private let collapse = PongButton(title: "Show less", style: .quiet, size: .small)
    private var fileButtons: [NSButton] = []
    /// "+3 more": a menu of the files past the first three.
    private var moreFiles: PongButton?
    private let jevEyebrow = PongUI.eyebrow("Jev")
    private let jevLead = PongUI.label("", NSFont.systemFont(ofSize: 12, weight: .semibold), PongColor.textPrimary)
    private let jevRest = PongUI.label("", PongType.secondary, PongColor.textSecondary)
    private let addNote = PongButton(title: "Add a note", style: .quiet, size: .small)
    private let noteField = NSTextField()
    private var buttons: [PongButton] = []
    private let whatLine = PongUI.label("", NSFont.systemFont(ofSize: 11), PongColor.textTertiary, lines: 2)
    private let working = StatusMarkerView(.working, size: 14)
    private let receipt = PongUI.label("", PongType.control, PongColor.textSecondary)
    private let openBtn = PongButton(title: "", style: .quiet, size: .small)

    private var noteOpen = false
    private var sending = false
    private var armedStop: Int?
    private var armWork: DispatchWorkItem?
    private var hoverIndex: Int?

    init(_ model: QuestionModel, compact: Bool = false) {
        self.model = model
        self.collapsible = compact
        // a card the person opened stays open when the page draws it again
        self.compact = compact && !QuestionCardView.opened.contains(model.key)
        self.details = QuestionDetailView(model)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = PongColor.tintYou.cgColor
        layer?.cornerRadius = PongRadius.card
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            layer?.borderWidth = 1
            layer?.borderColor = PongColor.you.cgColor
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Needs you: " + model.question)

        diamond.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        diamond.contentTintColor = PongColor.you
        addSubview(diamond)
        addSubview(eyebrow)
        source.stringValue = model.origin
        source.toolTip = model.origin
        // too long for its place: the graph's name gives, the team and the step stay readable
        source.lineBreakMode = .byTruncatingMiddle
        if model.isChat {
            let glyph = ChatGlyphView(live: true)
            glyph.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            chatGlyph = glyph
            addSubview(glyph)
        }
        addSubview(source)
        waited.alignment = .right
        addSubview(waited)
        questionText.stringValue = model.question
        questionText.toolTip = model.question
        addSubview(questionText)

        let ctx = model.context.joined(separator: "\n")
        contextText.stringValue = ctx
        contextText.toolTip = ctx.isEmpty ? nil : ctx
        addSubview(contextText)
        contextLine.stringValue = model.context.first ?? ""
        contextLine.toolTip = ctx.isEmpty ? nil : ctx
        addSubview(contextLine)

        // details folded or opened: the card grows or shrinks, and a file a point links leaves or
        // rejoins the file row
        details.onToggle = { [weak self] in
            self?.buildFileRow()
            self?.heightChanged()
        }
        addSubview(details)
        expand.toolTip = "Show what you're deciding, the files and Jev's view"
        expand.setAccessibilityHelp("Opens this question in full: what you're deciding, the files and Jev's view.")
        expand.onPress = { [weak self] in self?.compact = false }
        footerView.addSubview(expand)
        collapse.toolTip = "Show only the question and the answers"
        collapse.onPress = { [weak self] in self?.compact = true }
        footerView.addSubview(collapse)

        buildFileRow()

        if let j = model.jevLine {
            jevLead.stringValue = j.lead
            jevRest.stringValue = j.rest
            jevEyebrow.toolTip = "Jev, a scoring model, gives a second opinion and how sure it is."
            addSubview(jevEyebrow)
            addSubview(jevLead)
            addSubview(jevRest)
        }

        addNote.symbol = "plus"
        addNote.onPress = { [weak self] in self?.openNote() }
        footerView.addSubview(addNote)
        noteField.placeholderString = "Add a note for the step that redoes the work (optional)"
        noteField.font = PongType.body
        noteField.textColor = PongColor.textPrimary
        noteField.backgroundColor = PongColor.field
        noteField.drawsBackground = true
        noteField.isBezeled = false
        noteField.focusRingType = .none
        noteField.wantsLayer = true
        noteField.layer?.cornerRadius = PongRadius.control
        noteField.layer?.borderWidth = 1
        noteField.layer?.borderColor = PongColor.control.cgColor
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        noteField.usesSingleLineMode = false
        noteField.isHidden = true
        footerView.addSubview(noteField)

        for (i, a) in model.answers.enumerated() {
            let style: PongButton.Style
            switch a.kind {
            case .approve: style = .primary
            case .stopByAnswer, .stopGraph: style = .destructive
            case .option, .reply: style = i == 0 ? .primary : .secondary
            default: style = .secondary
            }
            let b = PongButton(title: a.title, style: style, size: compact ? .regular : .large)
            b.toolTip = a.what
            b.setAccessibilityHelp(a.what)
            b.onPress = { [weak self] in self?.press(i) }
            buttons.append(b)
            footerView.addSubview(b)
        }
        whatLine.stringValue = model.answers.first?.what ?? ""
        footerView.addSubview(whatLine)
        // "what it does" follows the pointer over the buttons; a click beside them focuses the card
        footerView.onHover = { [weak self] p in self?.hover(p) }
        footerView.onClick = { [weak self] in
            guard let self else { return }
            self.focused = true
            self.onFocus?(self)
        }
        footerView.onLayout = { [weak self] in
            guard let self, !self.answered else { return }
            _ = self.layoutFooter(width: self.footerView.bounds.width, apply: true, pinned: self.footerPinned)
        }
        addSubview(footerView)
        if model.answers.count == 1, model.answers.first?.kind == .reply {
            noteOpen = true
            noteField.isHidden = false
            addNote.isHidden = true
            noteField.placeholderString = "Your answer"
        }
        working.isHidden = true
        addSubview(working)
        receipt.isHidden = true
        addSubview(receipt)
        openBtn.symbol = "arrow.up.right"
        openBtn.toolTip = "Open the graph at this question"
        openBtn.onPress = { [weak self] in self?.onOpen?() }
        addSubview(openBtn)
        refreshWaited()
        restyleButtons()
        applyMode()
    }

    private var chatGlyph: NSView?
    private var fileBoxes: [ClosureBox] = []
    private var menuBoxes: [ClosureBox] = []
    /// The files the row shows, in order (the first three as links, the rest under "+N more").
    private var rowFiles: [String] = []

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The file row: each file by its name, its folder in the tooltip, the first three as links and
    /// "+N more" for the rest. While the points show, a file one of them already links isn't repeated.
    private func buildFileRow() {
        fileButtons.forEach { $0.removeFromSuperview() }
        fileButtons = []
        fileBoxes = []
        moreFiles?.removeFromSuperview()
        moreFiles = nil
        let pointsShown = details.open && !model.detail.isEmpty
        let files = QuestionWords.fileRow(model.files, linked: pointsShown ? model.linkedFiles : [])
        rowFiles = files
        let titles = QuestionWords.fileTitles(files)
        for (i, path) in files.prefix(3).enumerated() {
            let b = NSButton(title: "", target: nil, action: nil)
            b.isBordered = false
            b.bezelStyle = .inline
            b.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            b.imagePosition = .imageLeading
            b.contentTintColor = PongColor.live
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            b.attributedTitle = NSAttributedString(string: " " + titles[i], attributes: [
                .font: PongType.data, .foregroundColor: PongColor.live, .paragraphStyle: para,
            ])
            b.toolTip = "Open \(abbreviate(path)) (⌥-click shows it in Finder)"
            b.setAccessibilityLabel("Open " + titles[i])
            let box = ClosureBox { GraphActions.openSafely(path) }
            fileBoxes.append(box)
            b.target = box
            b.action = #selector(ClosureBox.fire)
            b.tag = i
            b.isHidden = compact
            fileButtons.append(b)
            addSubview(b)
        }
        if files.count > 3 {
            let m = PongButton(title: "+\(files.count - 3) more", style: .quiet, size: .small)
            m.toolTip = "The other files: " + titles.dropFirst(3).joined(separator: ", ")
            m.setAccessibilityHelp("Opens a menu of the other \(files.count - 3) files.")
            m.onPress = { [weak self] in self?.showMoreFiles() }
            m.isHidden = compact
            moreFiles = m
            addSubview(m)
        }
        needsLayout = true
    }

    func refreshWaited() {
        let s = Date().timeIntervalSince1970 - model.openedAt
        waited.stringValue = s > 30 ? "waiting " + PongUI.duration(s) : "just now"
    }

    /// Show what the mode shows: a compact card hides the context's other lines, the details, the files,
    /// Jev's line, "Add a note" and the what-line; a full one shows them.
    private func applyMode() {
        guard !answered else { return }
        let full = !compact
        questionText.maximumNumberOfLines = compact ? 2 : 3
        contextText.isHidden = !full || contextText.stringValue.isEmpty
        contextLine.isHidden = full || contextLine.stringValue.isEmpty
        details.isHidden = !full || !details.hasContent
        fileButtons.forEach { $0.isHidden = !full }
        moreFiles?.isHidden = !full
        let jev = full && !jevLead.stringValue.isEmpty
        for v in [jevEyebrow, jevLead, jevRest] as [NSView] { v.isHidden = !jev }
        addNote.isHidden = !full || noteOpen
        noteField.isHidden = !noteOpen
        whatLine.isHidden = !full
        expand.isHidden = full
        collapse.isHidden = !(full && collapsible)
        for b in buttons { b.size = compact ? .regular : .large }
        needsLayout = true
        footerView.needsLayout = true
    }

    private func heightChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        footerView.needsLayout = true
        superview?.needsLayout = true
        onHeightChange?()
    }

    /// "What it does" follows the pointer over the buttons (`p` in the footer's coordinates; nil: it left).
    private func hover(_ p: NSPoint?) {
        let i = p.flatMap { pt in buttons.firstIndex { !$0.isHidden && $0.frame.contains(pt) } }
        guard i != hoverIndex else { return }
        hoverIndex = i
        if let i, !(model.answers[i].kind == .sendBack && noteOpen) {
            whatLine.stringValue = model.answers[i].what
        } else if i == nil {
            whatLine.stringValue = model.answers.first?.what ?? ""
        }
    }

    private func openNote() {
        noteOpen = true
        noteField.isHidden = false
        addNote.isHidden = true
        heightChanged()
        window?.makeFirstResponder(noteField)
    }

    /// The files past the first three, in a menu: a click opens one the way the links do.
    private func showMoreFiles() {
        guard let m = moreFiles else { return }
        // two files with one name say which folder each is in
        let rest = Array(zip(rowFiles, QuestionWords.fileTitles(rowFiles)).dropFirst(3))
        let menu = NSMenu()
        menuBoxes = []
        for (path, title) in rest {
            let box = ClosureBox { GraphActions.openSafely(path) }
            menuBoxes.append(box)
            let item = NSMenuItem(title: title, action: #selector(ClosureBox.fire), keyEquivalent: "")
            item.target = box
            item.toolTip = abbreviate(path)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: m.isFlipped ? m.bounds.height + 2 : -2), in: m)
    }

    private func restyleButtons() {
        for (i, b) in buttons.enumerated() {
            b.keycap = focused && i < 3 ? "⌘\(i + 1)" : nil
            if armedStop == i {
                b.style = .confirm
                b.title = "Click again to stop"
            } else {
                let a = model.answers[i]
                b.title = a.title
                switch a.kind {
                case .approve: b.style = .primary
                case .stopByAnswer, .stopGraph: b.style = .destructive
                case .option, .reply: b.style = i == 0 ? .primary : .secondary
                default: b.style = .secondary
                }
            }
            b.isEnabled = !sending
        }
        let bw: CGFloat = focused ? 2 : (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0)
        let bc = (focused ? PongColor.live : PongColor.you).cgColor
        if let ext = externalBorder {
            layer?.borderWidth = 0
            ext(bw, bc)
        } else {
            layer?.borderWidth = bw
            layer?.borderColor = bc
        }
    }

    /// ⌘1–3 on the focused card.
    func press(_ i: Int) {
        guard i < model.answers.count, !sending else { return }
        let a = model.answers[i]
        switch a.kind {
        case .stopByAnswer, .stopGraph:
            if armedStop != i {
                armedStop = i
                restyleButtons()
                armWork?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.armedStop = nil; self?.restyleButtons() }
                armWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
                return
            }
            armWork?.cancel()
            armedStop = nil
        case .sendBack:
            if !noteOpen {
                openNote()
                whatLine.stringValue = "Say what should change, then press Send back again (a note is optional)."
                return
            }
        case .reply:
            if !noteOpen || noteField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                openNote()
                whatLine.stringValue = "Write your answer, then press Reply."
                return
            }
        default: break
        }
        send(a)
    }

    override func cancelOperation(_ sender: Any?) {
        if armedStop != nil {
            armedStop = nil
            armWork?.cancel()
            restyleButtons()
        }
    }

    /// `note`: the one sent before, when the toast's "Allow one more round" sends the answer again.
    private func send(_ a: QuestionAnswer, note given: String? = nil, extend: Bool = false) {
        sending = true
        working.isHidden = false
        restyleButtons()
        let note = given ?? (noteOpen ? noteField.stringValue : "")
        let finish: (Bool, String) -> Void = { [weak self] ok, err in
            guard let self else { return }
            self.sending = false
            self.working.isHidden = true
            if ok {
                let word: String
                switch a.kind {
                case .approve: word = "Approved"
                case .sendBack: word = "Sent back"
                case .stopByAnswer, .stopGraph: word = "Stopped"
                case .route, .option: word = a.title
                case .reply: word = "Replied"
                }
                self.showReceipt("✓ \(word) · \(PongUI.clock(Date().timeIntervalSince1970))")
                Toast.show(self.model.isChat ? "\(word): sent to \(self.model.subject)." : "\(word): \(self.model.subject).")
                self.onAnswered?()
            } else {
                self.restyleButtons()
                // the toast goes away; the log keeps what failed, so a lost answer can be traced afterwards.
                // A refusal that trying again won't fix says what it is: spent rounds (one more can be
                // allowed here, as on the island) or a question that closed.
                let refusal = a.kind == .stopGraph ? nil : QuestionWords.answerRefusal(err)
                let plain = refusal?.words ?? (a.kind == .stopGraph ? "Couldn't stop the graph. Try again in a moment."
                    : "Your answer didn't reach the \(self.model.isChat ? "chat" : "graph"). Try again in a moment.")
                let words = GraphActions.failure(err, plain, log: "answer \(a.title) on \(self.model.subject)")
                if refusal?.moreRounds == true, !extend, case .gate = self.model.source {
                    // the card itself is kept for the toast's few seconds: a redraw may have replaced it
                    Toast.show(words, warn: true, action: "Allow one more round") { self.send(a, note: note, extend: true) }
                } else {
                    Toast.show(words, warn: true)
                }
            }
        }
        model.send(a, note: note, extend: extend, done: finish)
    }

    private func showReceipt(_ s: String) {
        receipt.stringValue = s
        receipt.isHidden = false
        for v in subviews where v !== receipt { v.isHidden = true }
        footerView.isHidden = true  // also when a page pinned it outside the card
        answered = true
        heightChanged()
    }

    private(set) var answered = false

    override func mouseDown(with event: NSEvent) {
        focused = true
        onFocus?(self)
    }

    var onFocus: ((QuestionCardView) -> Void)?

    // MARK: Layout

    /// The card's height at a width, its answers part included.
    func height(for width: CGFloat) -> CGFloat {
        if answered { return 36 }
        return layoutBody(width: width, apply: false) + layoutFooter(width: width, apply: false, pinned: false)
    }

    /// With the answers part pinned outside: the height of the part above it.
    func bodyHeight(for width: CGFloat) -> CGFloat {
        if answered { return 36 }
        return layoutBody(width: width, apply: false) + (compact ? 12 : 0)
    }

    /// The pinned answers part's height at a width.
    func pinnedFooterHeight(for width: CGFloat) -> CGFloat {
        answered ? 0 : layoutFooter(width: width, apply: false, pinned: true)
    }

    /// Where to stop showing the card's part above the pinned answers, so no line is cut in half: the
    /// lowest gap between its pieces at or above `limit` (from the card's top, at its present width).
    func cleanCut(atMost limit: CGFloat) -> CGFloat {
        guard !answered else { return limit }
        _ = layoutBody(width: bounds.width, apply: true)
        details.layoutSubtreeIfNeeded()
        var spans: [(top: Double, bottom: Double)] = []
        func collect(_ v: NSView) {
            for s in v.subviews where !s.isHidden && s !== footerView {
                // the points are lines of their own: a cut may fall between two of them
                if s === details { collect(s); continue }
                let r = s.convert(s.bounds, to: self)
                spans.append((Double(r.minY), Double(r.maxY)))
            }
        }
        collect(self)
        return CGFloat(QuestionWords.cleanCut(spans, limit: Double(limit), floor: 60))
    }

    override func layout() {
        super.layout()
        if answered {
            receipt.frame = NSRect(x: 16, y: 9, width: bounds.width - 32, height: 18)
            return
        }
        let y = layoutBody(width: bounds.width, apply: true)
        if !footerPinned {
            let fh = layoutFooter(width: bounds.width, apply: false, pinned: false)
            footerView.frame = NSRect(x: 0, y: y, width: bounds.width, height: fh)
        }
        footerView.needsLayout = true
    }

    /// The header, the question and what is under it, down to where the answers part starts.
    @discardableResult
    private func layoutBody(width W: CGFloat, apply: Bool) -> CGFloat {
        let pad: CGFloat = compact ? 16 : 20
        let inner = max(40, W - pad * 2)
        var y = pad
        func place(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        // header
        place(diamond, NSRect(x: pad, y: y + 3, width: 10, height: 10))
        let ew = ceil(eyebrow.attributedStringValue.size().width) + 8
        place(eyebrow, NSRect(x: pad + 16, y: y, width: ew, height: 16))
        if let g = chatGlyph { place(g, NSRect(x: pad + 16 + ew + 8, y: y - 2, width: 20, height: 20)) }
        let ww = min(140, ceil(waited.attributedStringValue.size().width) + 6)
        place(waited, NSRect(x: W - pad - ww, y: y + 1, width: ww, height: 14))
        let openW: CGFloat = onOpen == nil ? 0 : 28
        place(openBtn, NSRect(x: W - pad - ww - openW - 4, y: y - 5, width: 24, height: 24))
        openBtn.isHidden = onOpen == nil
        place(working, NSRect(x: W - pad - ww - openW - 24, y: y + 1, width: 14, height: 14))
        let sx = pad + 16 + ew + 10 + (chatGlyph == nil ? 0 : 26)
        place(source, NSRect(x: sx, y: y, width: max(20, W - pad - ww - openW - 30 - sx), height: 16))
        y += 16 + 12
        // question
        let qh = textHeight(questionText, width: inner, maxLines: compact ? 2 : 3, lineH: 22)
        place(questionText, NSRect(x: pad, y: y, width: inner, height: qh))
        y += qh
        if compact {
            if !contextLine.stringValue.isEmpty {
                y += 6
                place(contextLine, NSRect(x: pad, y: y, width: inner, height: 18))
                y += 18
            }
        } else {
            if !contextText.stringValue.isEmpty {
                y += 8
                let ch = textHeight(contextText, width: inner, maxLines: 5, lineH: 18)
                place(contextText, NSRect(x: pad, y: y, width: inner, height: ch))
                y += ch
            }
            // what you're deciding: the facts, each with its file
            if details.hasContent {
                y += 14
                let dh = details.height(for: inner)
                place(details, NSRect(x: pad, y: y, width: inner, height: dh))
                if apply { details.needsLayout = true }
                y += dh
            }
            if !fileButtons.isEmpty {
                y += 12
                for b in fileButtons {
                    place(b, NSRect(x: pad - 2, y: y, width: min(inner, ceil(b.attributedTitle.size().width) + 24), height: 20))
                    y += 22
                }
                if let m = moreFiles {
                    place(m, NSRect(x: pad - 10, y: y - 2, width: m.intrinsicContentSize.width, height: 24))
                    y += 22
                }
            }
            if !jevLead.stringValue.isEmpty {
                y += 12
                let je = ceil(jevEyebrow.attributedStringValue.size().width) + 2
                place(jevEyebrow, NSRect(x: pad, y: y + 1, width: je, height: 16))
                let lw = ceil(jevLead.attributedStringValue.size().width) + 4
                place(jevLead, NSRect(x: pad + je + 10, y: y, width: lw, height: 17))
                place(jevRest, NSRect(x: pad + je + 10 + lw + 8, y: y + 1, width: max(20, inner - je - lw - 18), height: 16))
                y += 18
            }
            y += 12
        }
        return y
    }

    /// The answers part, in its own view's coordinates: the note (or "Add a note"), the buttons with
    /// Details › (compact) or Show less (a compact card opened), then what the pointed-at button does.
    /// Pinned outside the card, it starts with a little room under the line that divides it.
    @discardableResult
    private func layoutFooter(width W: CGFloat, apply: Bool, pinned: Bool) -> CGFloat {
        let pad: CGFloat = compact ? 16 : 20
        let inner = max(40, W - pad * 2)
        func place(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        var y: CGFloat = pinned ? 12 : 0
        if compact {
            if noteOpen {
                if !pinned { y += 12 }
                place(noteField, NSRect(x: pad, y: y, width: inner, height: 44))
                y += 44 + 12
            } else if !pinned {
                y += 12
            }
        } else {
            y += 4
            if noteOpen {
                place(noteField, NSRect(x: pad, y: y, width: inner, height: 52))
                y += 52
            } else {
                place(addNote, NSRect(x: pad - 8, y: y - 4, width: addNote.intrinsicContentSize.width, height: 24))
                y += 20
            }
            y += 16
        }
        var x = pad
        let bh: CGFloat = compact ? 28 : 32
        var row = buttons
        if compact { row.append(expand) } else if collapsible { row.append(collapse) }
        for b in row {
            let w = b.intrinsicContentSize.width
            let h = b.height
            if x + w > W - pad && x > pad {  // wrap onto a second row
                x = pad
                y += bh + 8
            }
            place(b, NSRect(x: x, y: y + (bh - h) / 2, width: w, height: h))
            x += w + 8
        }
        y += bh
        if !compact {
            y += 8
            let wh = textHeight(whatLine, width: inner, maxLines: 2, lineH: 14)
            place(whatLine, NSRect(x: pad, y: y, width: inner, height: wh))
            y += wh
        }
        return y + pad
    }

    private func textHeight(_ f: NSTextField, width: CGFloat, maxLines: Int, lineH: CGFloat) -> CGFloat {
        guard !f.stringValue.isEmpty else { return 0 }
        let r = f.attributedStringValue.boundingRect(with: NSSize(width: width, height: 10_000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = max(1, Int(ceil(r.height / max(1, lineH - 4))))
        let h = ceil(r.height) + 2
        if maxLines > 0 { return min(h, CGFloat(maxLines) * lineH) }
        return max(h, CGFloat(min(lines, 1)) * lineH)
    }
}

/// A card's answers part, a view of its own so a page can pin it under a card that scrolls. The card
/// lays out what is in it; this view only says when, where the pointer is, and a click beside the buttons.
private final class CardFooterView: NSView {
    var onLayout: (() -> Void)?
    var onHover: ((NSPoint?) -> Void)?
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// "What you're deciding": the facts behind a question, in more depth than its three lines, each with
/// a quiet link to the file it comes from, then who wrote them. Open by default on a full card; "Hide
/// details" folds it to its title, and the choice is kept per question. While a helper AI is still
/// writing, it says "Details coming…". VoiceOver reads it as one group of points and links.
final class QuestionDetailView: NSView {
    /// The section opened or folded: the card lays itself out again.
    var onToggle: (() -> Void)?

    private let model: QuestionModel
    private let title = PongUI.eyebrow("What you're deciding")
    private let toggle = PongButton(title: "", style: .quiet, size: .small)
    private var rows: [(bullet: NSTextField, text: NSTextField, link: NSButton?)] = []
    private var boxes: [ClosureBox] = []
    private let byLine = PongUI.label("", NSFont.systemFont(ofSize: 11), PongColor.textTertiary, lines: 2)
    private let pending = PongUI.label("Details coming…", NSFont.systemFont(ofSize: 11), PongColor.textTertiary)
    private(set) var open: Bool

    init(_ model: QuestionModel) {
        self.model = model
        open = !QuestionDetailView.isFolded(model.key)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Something to show: points, or points on their way.
    var hasContent: Bool { !model.detail.isEmpty || model.detailPending }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("What you're deciding")
        title.setAccessibilityElement(false)  // the group's label says it
        addSubview(title)
        toggle.onPress = { [weak self] in
            guard let self else { return }
            self.setOpen(!self.open)
        }
        addSubview(toggle)
        for d in model.detail {
            let bullet = PongUI.label("•", PongType.body, PongColor.textTertiary)
            bullet.setAccessibilityElement(false)
            let text = PongUI.label("", PongType.body, PongColor.textPrimary, lines: 0)
            // a place with no file to open ("What each answer does") says nothing a person can follow:
            // only a link carries it
            let s = NSMutableAttributedString(string: d.text, attributes: [.font: PongType.body, .foregroundColor: PongColor.textPrimary])
            let file = model.detailFile(d)
            text.attributedStringValue = s
            text.setAccessibilityLabel(s.string)
            addSubview(bullet)
            addSubview(text)
            var link: NSButton?
            if let path = file {
                let name = (path as NSString).lastPathComponent
                let b = NSButton(title: "", target: nil, action: nil)
                b.isBordered = false
                b.bezelStyle = .inline
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingMiddle
                b.attributedTitle = NSAttributedString(string: "↗ " + name + (d.location.isEmpty ? "" : " · " + d.location), attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: PongColor.live, .paragraphStyle: para,
                ])
                b.toolTip = "Open \(path) (⌥-click shows it in Finder)"
                b.setAccessibilityLabel("Open " + name + (d.location.isEmpty ? "" : ", at " + d.location))
                let box = ClosureBox { GraphActions.openSafely(path) }
                boxes.append(box)
                b.target = box
                b.action = #selector(ClosureBox.fire)
                addSubview(b)
                link = b
            }
            rows.append((bullet, text, link))
        }
        byLine.stringValue = model.detailAttribution
        addSubview(byLine)
        addSubview(pending)
        apply()
    }

    func setOpen(_ o: Bool) {
        open = o
        QuestionDetailView.remember(model.key, folded: !o)
        apply()
        onToggle?()
    }

    private func apply() {
        let n = model.detail.count
        toggle.title = open ? "Hide details" : "Show details (\(n))"
        toggle.setAccessibilityHelp(open ? "Folds the points away." : "Shows the \(n) point\(n == 1 ? "" : "s") behind this question.")
        toggle.isHidden = n == 0
        for r in rows {
            r.bullet.isHidden = !open
            r.text.isHidden = !open
            r.link?.isHidden = !open
        }
        byLine.isHidden = !open || n == 0 || byLine.stringValue.isEmpty
        pending.isHidden = !model.detailPending || (!open && n > 0)
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat { layoutContent(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = layoutContent(width: bounds.width, apply: true)
    }

    @discardableResult
    private func layoutContent(width W: CGFloat, apply: Bool) -> CGFloat {
        func place(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        var y: CGFloat = 0
        let tw = min(W, ceil(title.attributedStringValue.size().width) + 4)
        place(title, NSRect(x: 0, y: y + 4, width: tw, height: 16))
        if !toggle.isHidden {
            let w = toggle.intrinsicContentSize.width
            place(toggle, NSRect(x: max(tw + 8, W - w + 10), y: y, width: w, height: 24))
        }
        y += 24
        if open {
            let tx: CGFloat = 14
            for r in rows {
                y += 4
                let th = textHeight(r.text, width: W - tx)
                place(r.bullet, NSRect(x: 0, y: y, width: 12, height: 18))
                place(r.text, NSRect(x: tx, y: y, width: W - tx, height: th))
                y += th
                if let l = r.link {
                    let lw = min(W - tx + 4, ceil(l.attributedTitle.size().width) + 8)
                    place(l, NSRect(x: tx - 4, y: y + 1, width: lw, height: 18))
                    y += 20
                }
            }
            if !byLine.isHidden {
                y += 8
                let bh = min(30, textHeight(byLine, width: W))
                place(byLine, NSRect(x: 0, y: y, width: W, height: bh))
                y += bh
            }
        }
        if !pending.isHidden {
            y += rows.isEmpty || !open ? 2 : 6
            place(pending, NSRect(x: 0, y: y, width: W, height: 16))
            y += 16
        }
        return y
    }

    private func textHeight(_ f: NSTextField, width: CGFloat) -> CGFloat {
        guard !f.stringValue.isEmpty else { return 0 }
        let r = f.attributedStringValue.boundingRect(with: NSSize(width: max(20, width), height: 10_000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height) + 2
    }

    // MARK: Folded, per question

    private static let foldedKey = "question.detailsFolded"

    static func isFolded(_ key: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: foldedKey) as? [String: Double])?[key] != nil
    }

    static func remember(_ key: String, folded: Bool) {
        var d = UserDefaults.standard.dictionary(forKey: foldedKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        d = d.filter { now - $0.value < 30 * 86_400 }  // a question long answered is forgotten
        if folded { d[key] = now } else { d.removeValue(forKey: key) }
        UserDefaults.standard.set(d, forKey: foldedKey)
    }
}
