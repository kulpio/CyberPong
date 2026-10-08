import AppKit

// MARK: - What the app knows about bars ------------------------------------

/// A lane the bar can cover, named the way a person names it.
///
/// Not a seat, and never shown as one. "Engineering" is one chip that stands
/// for every engineering lane on the roster (Backend, Web, Design), because
/// that is how a person says it — the roster does the expanding underneath.
struct GauntletLane {
    let title: String
    /// Lead seat ids behind this chip. Empty means the lane is not on the team,
    /// which the chip has to say BEFORE the person fills anything in.
    let leads: [String]
    let seats: Int
    var onTeam: Bool { !leads.isEmpty && seats > 0 }
}

/// A bar as the card needs to describe it, and as the sheet needs to edit it.
///
/// Everything a person reads is composed by the control plane; everything the
/// engine needs back on a save — dimensions, references, the directory the
/// references really live in — is carried through untouched. The app never
/// forms an opinion about either.
struct GauntletBar {
    let id: String
    let title: String
    let summary: String
    let kind: String
    /// A bar nobody set: it came with CyberPong and grades work already.
    let shipped: Bool
    /// Where it was loaded from, so an override can carry its reference files
    /// across instead of writing blank stubs over them.
    let dir: String
    let lanes: [String]
    /// Who holds it, in owner language — never a seat id, and never the raw
    /// label, because every reviewer seat on this team is called "Reviewer".
    let held: String
    let references: [String]
    /// True while the only anchor is the engine's TODO stub: the bar exists but
    /// has nothing real to point at yet.
    let pending: Bool
    let minEach: Int
    let minMean: Double
    /// The engine's own pass sentence, never-waived line included — shown on
    /// Edit so the person reads the rule as it is enforced, not a paraphrase.
    let passNote: String
    /// Opaque to the app. Handed straight back on save.
    let dimensions: [[String: Any]]
    let rawReferences: [[String: Any]]
}

/// What the card got back, including the case where it got nothing.
struct GauntletRead {
    let bars: [GauntletBar]
    /// nil when the read worked. A non-nil value is shown on the card rather
    /// than left to look like "no bars", which is a different thing entirely.
    let error: String?
}

/// Reading the roster and the bars. Both come from the control plane rather
/// than from anything typed in here — the roster changes, and a list of lanes
/// hard-coded in Swift would drift from it within a week.
enum Gauntlet {
    /// The five leads, in the order the setup sheet draws them.
    static let laneOrder = ["Engineering", "Delivery", "Growth", "Research", "Ops"]

    /// Which chip a lead's label belongs under. Every engineering lane folds
    /// into one chip; everyone else is their own.
    static func chip(for label: String) -> String {
        label.hasPrefix("Engineering") ? "Engineering" : label
    }

    static func lanes(session: String) -> [GauntletLane] {
        let py = [
            "import json",
            "from pong.state import load_session_state",
            "from pong.review_init import lead_groups",
            "print(json.dumps(lead_groups(load_session_state('\(session)'))))",
        ].joined(separator: "; ")
        let rows = run(py).rows
        var leads: [String: [String]] = [:]
        var seats: [String: Int] = [:]
        for r in rows {
            let label = (r["label"] as? String) ?? ""
            guard let lead = r["lead"] as? String, !label.isEmpty else { continue }
            let key = chip(for: label)
            leads[key, default: []].append(lead)
            seats[key, default: 0] += ((r["seats"] as? [String])?.count ?? 0)
        }
        return laneOrder.map {
            GauntletLane(title: $0, leads: leads[$0] ?? [], seats: seats[$0] ?? 0)
        }
    }

    static func bars(session: String) -> GauntletRead {
        let (rows, error) = run(barsScript(session: session), multiline: true)
        return GauntletRead(bars: rows.map {
            GauntletBar(
                id: ($0["id"] as? String) ?? "",
                title: ($0["title"] as? String) ?? "",
                summary: ($0["summary"] as? String) ?? "",
                kind: ($0["kind"] as? String) ?? "",
                shipped: ($0["shipped"] as? Bool) ?? false,
                dir: ($0["dir"] as? String) ?? "",
                lanes: ($0["lanes"] as? [String]) ?? [],
                held: ($0["held"] as? String) ?? "",
                references: ($0["refs"] as? [String]) ?? [],
                pending: ($0["pending"] as? Bool) ?? false,
                minEach: ($0["min_each"] as? Int) ?? 3,
                minMean: ($0["min_mean"] as? Double) ?? 4.0,
                passNote: ($0["pass_note"] as? String) ?? "",
                // JSONSerialization hands back NSArray-of-NSDictionary; the
                // direct [[String: Any]] cast can fail and silently return [],
                // and empty dimensions make Save wipe the bar's anchors.
                dimensions: (($0["dimensions"] as? [Any]) ?? [])
                    .compactMap { $0 as? [String: Any] },
                rawReferences: (($0["references"] as? [Any]) ?? [])
                    .compactMap { $0 as? [String: Any] })
        }, error: error)
    }

    /// Coverage is asked of the engine, seat by seat, rather than read off
    /// `scope.seats`.
    ///
    /// The shipped code bar names no seats at all — it matches on mission role —
    /// so reading `scope.seats` said it covered nobody and the card rendered
    /// "the team", which is what made it useless to look at. `bar_for_seat` is
    /// the same call that decides which bar a real job gets attached to, so
    /// asking it per seat means the card and the job can never disagree.
    private static func barsScript(session: String) -> String {
        """
        import json
        from pong.state import load_session_state, workers_from_state
        from pong.review_bar import load_bars, bar_for_seat, reviewers_for_seat, _PKG_ROOT
        from pong.review_init import lead_groups

        st = load_session_state('\(session)')
        workers = list(workers_from_state(st))
        label = {str(w.get("id")): str(w.get("label") or w.get("id")) for w in workers}
        lane_of = {}
        for g in lead_groups(st):
            for s in g.get("seats") or []:
                lane_of.setdefault(s, g["label"])
        parent_of = {str(w.get("id")): str(w.get("parent_id") or "") for w in workers}

        def short(v):
            v = v.strip()
            if v.startswith("http"):
                host = v.split("//", 1)[-1].split("/", 1)[0]
                return host[4:] if host.startswith("www.") else host
            # Only a real path gets basenamed. A sentence that merely CONTAINS
            # a slash (a standard citation with its URL) was being sliced at
            # its last slash into a 135-char fragment.
            if "/" in v and " " not in v:
                return v.rstrip("/").rsplit("/", 1)[-1]
            return v if len(v) <= 32 else v[:31].rstrip() + "…"

        pkg = str(_PKG_ROOT / "review")
        out = []
        for bid, b in sorted(load_bars(str(st.get("project_root") or "")).items()):
            seats = [str(w.get("id")) for w in workers
                     if (bar_for_seat(st, str(w.get("id"))) or {}).get("id") == bid]
            lanes, rev_lanes = [], []
            for s in seats:
                n = lane_of.get(s)
                if n and n not in lanes:
                    lanes.append(n)
                for r in reviewers_for_seat(st, s):
                    ln = label.get(parent_of.get(r, ""), "")
                    if ln and ln not in rev_lanes:
                        rev_lanes.append(ln)
            scope = b.get("scope") or {}
            if scope.get("reviewer_seats"):
                held = ("the " + " and ".join(rev_lanes) + " reviewer") if rev_lanes \
                       else "a named reviewer"
            elif rev_lanes:
                held = "each lane's own reviewer"
            else:
                held = "nobody yet"
            refs = b.get("references") or []
            out.append({
                "id": bid, "title": b.get("title") or bid,
                # No bar on disk actually carries a kind — not the shipped ones,
                # not the team's. For the four the engine knows, the id IS the
                # kind, so Edit can pre-tick the right chip. Anything else leaves
                # it blank rather than claiming "Building it" about a bar that
                # never said so, and the step simply asks the person.
                "summary": b.get("summary") or "",
                "kind": b.get("kind") or (bid if bid in ("code", "design", "writing", "research") else ""),
                "shipped": str(b.get("_dir") or "") == pkg, "dir": str(b.get("_dir") or ""),
                "lanes": lanes, "held": held,
                # A placeholder is not something you are judged against. The
                # engine's own stub is "-TODO-find-an-anchor", but a hand-written
                # bar names its gaps too ("code-5-TODO-security-anchor"), and
                # listing those as anchors would tell the person the bar is grounded
                # where it is exactly the opposite.
                "refs": [short(str(r.get("why") or "")) for r in refs
                         if int(r.get("score") or 0) == 5
                         and "-TODO-" not in str(r.get("file") or "")],
                "pending": any("-TODO-" in str(r.get("file") or "") for r in refs),
                "min_each": (b.get("pass") or {}).get("min_each", 3),
                "min_mean": (b.get("pass") or {}).get("min_mean", 4.0),
                "pass_note": (b.get("pass") or {}).get("note") or "",
                "dimensions": b.get("dimensions") or [],
                "references": refs,
            })
        print(json.dumps(out))
        """
    }

    /// Run a snippet and read its JSON. Failure is reported, not swallowed:
    /// stderr used to go to /dev/null, so a control plane that hiccuped left a
    /// card that looked exactly like "you have no bars".
    private static func run(_ py: String, multiline: Bool = false)
        -> (rows: [[String: Any]], error: String?) {
        let script: String
        var tmp: String?
        if multiline {
            let path = NSTemporaryDirectory() + "pong-gauntlet-\(UUID().uuidString).py"
            do {
                try py.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return ([], "CyberPong couldn't prepare the read — \(error.localizedDescription)")
            }
            tmp = path
            script = "python3 '\(path)'"
        } else {
            script = "python3 -c \"\(py)\""
        }
        let out = Pong.sh("""
        \(SessionArchive.pongPrefix())
        \(script) 2>&1
        """)
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }

        guard let data = out.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            let first = out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "no output"
            Pong.log("gauntlet read failed: \(out.prefix(400))")
            return ([], "CyberPong couldn't read the bars — \(first)")
        }
        return (rows, nil)
    }
}

// MARK: - The sheet ---------------------------------------------------------

/// Setting the bar, in the person's own words, on the panel they are already looking at.
///
/// Three questions, one at a time: what should we be great at, who does it
/// apply to, what does great look like. The engine underneath is untouched —
/// the answers go to `pong review create --answers` exactly as the old form's
/// did — so this asks the questions rather than holding a second opinion about
/// what a bar is, and every refusal still applies.
///
/// A sheet rather than a window on purpose: this is a scoped task inside the
/// panel's context, and modal is right — the person should finish it or cancel it, not
/// leave it half-filled behind the map. The old floating controller could be
/// lost behind the app entirely, which is most of why it could not be found.
final class GauntletSheet: NSWindowController {
    static var shared: GauntletSheet?

    private let session: String
    private var lanes: [GauntletLane] = []

    // Answers
    private var step = 0
    private let goalView = NSTextView()
    private var kind = ""                       // code / design / writing / research
    private var chosenLanes = Set<String>()
    private var references: [String] = []       // urls and file paths, in order
    private var research = false

    /// The bar being edited, or nil when this is a new one.
    ///
    /// Editing carries far more than the sheet shows: the dimensions and their
    /// scored anchors, the reference files that already exist on disk, the pass
    /// marks. None of that is editable here and none of it may be lost, so it
    /// rides along and goes back to the engine untouched.
    private let editing: GauntletBar?
    /// References the bar already had, minus any the person removed.
    private var keptReferences: [[String: Any]] = []

    private var errorLine = ""

    private let W: CGFloat = 560
    private let H: CGFloat = 520
    private let inset: CGFloat = 20

    /// The four kinds, in the person's words. The engine's own kind ids ride underneath;
    /// the words "code" and "research" never reach the screen.
    private static let kinds: [(label: String, id: String)] = [
        ("Building it", "code"), ("How it looks", "design"),
        ("The words", "writing"), ("Finding out", "research"),
    ]

    /// The one content view the window ever gets. Steps rebuild INSIDE it:
    /// swapping `contentView` on a sheet that is already presented is what
    /// left every page after the first one blank.
    private let host = PongSheetChrome.rootView(width: 560, height: 520)

    init(session: String, editing bar: GauntletBar? = nil) {
        self.session = session
        self.editing = bar
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                           styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: win)
        PongSheetChrome.styleWindow(win, title: bar == nil ? "Set the bar" : "Edit the bar")
        win.contentView = host
        lanes = Gauntlet.lanes(session: session)
        if let bar { prefill(from: bar) }
        render()
    }

    /// Load an existing bar into the three steps.
    ///
    /// The lanes come back as chip names, so a bar covering "Engineering —
    /// Backend" and "Engineering — Web" pre-selects the one Engineering chip
    /// it was set with — the sheet only ever offered that granularity.
    private func prefill(from bar: GauntletBar) {
        goalView.string = bar.summary.isEmpty ? bar.title : bar.summary
        kind = bar.kind
        chosenLanes = Set(bar.lanes.map { Gauntlet.chip(for: $0) })
        // The anchors it already has stay in `keptReferences` and are shown
        // alongside anything added in this sitting; removing one here removes it
        // from the bar, and the ones left keep their real file names.
        keptReferences = bar.rawReferences.filter {
            !(($0["file"] as? String) ?? "").contains("TODO-find-an-anchor")
        }
        research = bar.pending
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Open it on the panel, or on `window` (Settings › Quality bars). The panel has
    /// to be up first — a sheet with no host is the floating window this replaces.
    static func present(session: String, editing bar: GauntletBar? = nil, on window: NSWindow? = nil) {
        let host = window ?? PanelController.shared.sheetHost ?? {
            PanelController.shared.show()
            return PanelController.shared.sheetHost
        }()
        let c = GauntletSheet(session: session, editing: bar)
        shared = c
        guard let sheet = c.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Sized and laid out once, here — before presentation, never during.
        sheet.setContentSize(NSSize(width: 560, height: 520))
        sheet.contentView?.layoutSubtreeIfNeeded()
        if let host {
            host.beginSheet(sheet) { _ in shared = nil }
        } else {
            // No panel to hang it on (never in normal use, but a sheet that
            // silently does not open is the bug this whole job is about).
            c.showWindow(nil)
        }
        Pong.log("gauntlet sheet opened for \(session)"
                 + (bar.map { " editing \($0.id)" } ?? " (new bar)"))
    }

    private func close(_ code: NSApplication.ModalResponse) {
        guard let sheet = window else { return }
        if let host = sheet.sheetParent {
            host.endSheet(sheet, returnCode: code)
        } else {
            sheet.close()
        }
    }

    // MARK: Small chrome the spec asks for by name

    /// Section labels are `textSecondary`, NOT `PongSheetChrome.sectionLabel`.
    /// That helper paints `limeDim`, which the spec measured at 3.69:1 on dark
    /// and 2.42:1 on light — a 10pt label needs 4.5:1, so it fails AA in both
    /// appearances. Whether to fix the shared helper is a separate call; this
    /// sheet just does not use it.
    private func sectionLabel(_ text: String, y: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text.uppercased())
        f.font = PongTheme.labelFont(10)
        f.textColor = PongTheme.textSecondary
        f.frame = NSRect(x: inset, y: y, width: W - inset * 2, height: 14)
        return f
    }

    private func caption(_ text: String, y: CGFloat, height: CGFloat = 16,
                         color: NSColor? = nil) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = PongTheme.font(12)
        f.textColor = color ?? PongTheme.textSecondary
        f.frame = NSRect(x: inset, y: y, width: W - inset * 2, height: height)
        return f
    }

    /// A 28pt pill. Selection carries a ✓ as well as the lime fill, so it never
    /// rides on colour alone. The system focus ring is left alone on purpose —
    /// Full Keyboard Access and VoiceOver reach these for free.
    private func chip(_ title: String, selected: Bool, enabled: Bool = true,
                      action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.isEnabled = enabled
        b.layer?.cornerRadius = 4
        b.layer?.borderWidth = 1
        b.layer?.backgroundColor = (selected ? PongSheetChrome.limeSoft : .clear).cgColor
        b.layer?.borderColor = (selected ? PongSheetChrome.lime : PongTheme.line).cgColor
        let text = selected ? "✓ " + title : title
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: enabled ? PongTheme.textPrimary : PongTheme.textSecondary,
            .font: PongTheme.font(12, weight: .medium),
        ])
        b.target = self
        b.action = action
        b.identifier = NSUserInterfaceItemIdentifier(title)
        let w = ceil((text as NSString).size(withAttributes: [
            .font: PongTheme.font(12, weight: .medium)]).width) + 22
        b.frame = NSRect(x: 0, y: 0, width: w, height: 28)
        return b
    }

    /// Lay chips out in rows that wrap inside the sheet, returning the y the
    /// caller should carry on from.
    private func layChips(_ chips: [NSButton], into root: NSView, top: CGFloat) -> CGFloat {
        var x = inset, y = top
        for c in chips {
            if x + c.frame.width > W - inset {
                x = inset; y -= 34
            }
            c.setFrameOrigin(NSPoint(x: x, y: y))
            root.addSubview(c)
            x += c.frame.width + 6
        }
        return y
    }

    // MARK: Render

    private func render() {
        // Rebuild inside the stable host — never a fresh contentView.
        let root = host
        root.subviews.forEach { $0.removeFromSuperview() }

        root.addSubview(PongSheetChrome.titleLabel(
            editing == nil ? "Set the bar" : "Edit the bar",
            frame: NSRect(x: inset, y: H - 44, width: 300, height: 22)))
        let progress = NSTextField(labelWithString: "\(step + 1) of 3")
        progress.font = PongTheme.labelFont(11)
        progress.textColor = PongTheme.textSecondary
        progress.alignment = .right
        progress.frame = NSRect(x: W - inset - 80, y: H - 41, width: 80, height: 16)
        root.addSubview(progress)

        switch step {
        case 0: renderGoal(root)
        case 1: renderLanes(root)
        default: renderGreat(root)
        }

        // The footer band, which the content cursor never reaches. Refusals are
        // `danger` and never amber: amber as running text is 3.99:1 on light,
        // which fails AA at this size.
        if !errorLine.isEmpty {
            root.addSubview(caption(errorLine, y: 58, height: 32, color: PongTheme.danger))
        } else if step == 2, !stepIsValid {
            // Inactive is never the only signal — this says what is missing.
            root.addSubview(caption("The reviewer needs at least one real example — "
                                    + "or let us go find one.", y: 58, height: 18))
        }

        let leftTitle = step == 0 ? "Cancel" : "Back"
        let left = PongSheetChrome.outlineButton(
            leftTitle, target: self, action: step == 0 ? #selector(cancel) : #selector(back))
        left.frame = NSRect(x: inset, y: 24, width: 92, height: 30)
        left.keyEquivalent = "\u{1b}"
        root.addSubview(left)

        let rightTitle = step == 2 ? (editing == nil ? "Set the bar" : "Save") : "Continue"
        let right = PongSheetChrome.primaryButton(rightTitle, target: self, action: #selector(next))
        right.frame = NSRect(x: W - inset - 120, y: 24, width: 120, height: 30)
        right.keyEquivalent = "\r"
        right.isEnabled = stepIsValid
        // Inactive is never the only signal — each step says what is missing.
        right.alphaValue = stepIsValid ? 1 : 0.4
        root.addSubview(right)
    }

    private var stepIsValid: Bool {
        switch step {
        case 0: return !goalText.isEmpty && !kind.isEmpty
        case 1: return !chosenLanes.isEmpty
        default: return !referenceRows.isEmpty || research
        }
    }

    /// The reference rows on screen: what the bar already had, then anything
    /// added in this sitting. The id tells the delete button which list to take
    /// it out of.
    private var referenceRows: [(label: String, id: String)] {
        keptReferences.enumerated().map {
            (Self.shortRef(($0.element["why"] as? String) ?? ""), "kept:\($0.offset)")
        } + references.map { (Self.shortRef($0), "new:\($0)") }
    }

    private var goalText: String {
        goalView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- Step 1

    private func renderGoal(_ root: NSView) {
        var y = H - 84
        root.addSubview(sectionLabel("What should we be great at?", y: y)); y -= 20
        // Edit is for READING the bar as much as changing it, and the sheet is
        // a fixed 520pt: the goal box gives up two lines so the requirements
        // panel below gets real room. Create keeps the four-line box.
        let goalH: CGFloat = editing == nil ? 78 : 44
        if editing == nil {
            root.addSubview(caption("Say it like you'd say it to the team.", y: y))
        }
        y -= (editing == nil ? 12 : -14) + goalH

        // Four lines of real room: the goal becomes the bar's title, id and
        // summary, so a one-word answer makes a one-word bar.
        let scroll = NSScrollView(frame: NSRect(x: inset, y: y, width: W - inset * 2, height: goalH))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = PongTheme.bgInput
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = PongTheme.line.cgColor
        goalView.frame = NSRect(x: 0, y: 0, width: W - inset * 2, height: goalH)
        goalView.autoresizingMask = [.width]
        goalView.font = PongTheme.font(12)
        goalView.textColor = PongTheme.textPrimary
        goalView.backgroundColor = PongTheme.bgInput
        goalView.drawsBackground = true
        goalView.textContainerInset = NSSize(width: 6, height: 6)
        goalView.delegate = self
        scroll.documentView = goalView
        // Prefill lands in init, before the text view has ever been in a
        // window; after it becomes the scroll view's documentView it can draw
        // empty even though `string` is set. Re-applying the string once it is
        // attached is what makes Edit's prefill actually visible.
        let text = goalView.string
        goalView.string = text
        root.addSubview(scroll)
        y -= 26

        root.addSubview(sectionLabel("What kind of work is it?", y: y)); y -= 34
        let chips = Self.kinds.map {
            chip($0.label, selected: kind == $0.id, action: #selector(pickKind(_:)))
        }
        y = layChips(chips, into: root, top: y)
        if editing != nil { addRequirements(root, labelY: y - 24) }
    }

    /// The bar as it stands — why Edit gets opened at all.
    ///
    /// Every dimension with its own 5 and 1, the engine's pass sentence, and
    /// the anchors already on file, in a scroll view so nothing is clipped off
    /// the fixed sheet. Read-only on purpose: dimensions ride through Save
    /// untouched, so showing them is honest and editing them here would not be.
    private func addRequirements(_ root: NSView, labelY: CGFloat) {
        guard let bar = editing else { return }
        root.addSubview(sectionLabel("The bar as it stands", y: labelY))
        // Down to just above the footer band (buttons end at 54; refusals at 58
        // only ever paint on step 3, so this page can use the room).
        let bottom: CGFloat = 62
        let scrollH = labelY - 6 - bottom
        guard scrollH > 60 else { return }
        let scroll = NSScrollView(frame: NSRect(x: inset, y: bottom,
                                                width: W - inset * 2, height: scrollH))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = PongTheme.bgElevated
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = PongTheme.border.cgColor

        let docW = W - inset * 2 - 16
        let doc = GauntletFlippedView(frame: NSRect(x: 0, y: 0, width: docW, height: 10))
        var cy: CGFloat = 10
        func line(_ text: String, font: NSFont, color: NSColor, gap: CGFloat = 4) {
            guard !text.isEmpty else { return }
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = font
            f.textColor = color
            let w = docW - 24
            let h = f.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: w, height: .greatestFiniteMagnitude)).height ?? 16
            f.frame = NSRect(x: 12, y: cy, width: w, height: ceil(h))
            doc.addSubview(f)
            cy += ceil(h) + gap
        }

        let passLine = bar.passNote.isEmpty
            ? "Pass: at least \(bar.minEach) on every dimension, and a mean of \(bar.minMean)."
            : bar.passNote
        line(passLine, font: PongTheme.font(11), color: PongTheme.textSecondary, gap: 12)

        for d in bar.dimensions {
            let name = (d["name"] as? String) ?? (d["id"] as? String) ?? ""
            line(name, font: PongTheme.font(12, weight: .semibold),
                 color: PongTheme.textPrimary)
            line(((d["five"] as? String).map { "5 — " + $0 }) ?? "",
                 font: PongTheme.font(11), color: PongTheme.textSecondary)
            line(((d["one"] as? String).map { "1 — " + $0 }) ?? "",
                 font: PongTheme.font(11), color: PongTheme.textSecondary, gap: 12)
        }

        if !keptReferences.isEmpty {
            line("ANCHORS", font: PongTheme.labelFont(10),
                 color: PongTheme.textSecondary, gap: 6)
            for r in keptReferences {
                let score = ((r["score"] as? NSNumber).map { "\($0.intValue) — " }) ?? ""
                line(score + ((r["file"] as? String) ?? ""),
                     font: PongTheme.mono(11), color: PongTheme.textSecondary)
            }
        }

        doc.frame.size.height = cy + 6
        scroll.documentView = doc
        root.addSubview(scroll)
    }

    // ---- Step 2

    private func renderLanes(_ root: NSView) {
        var y = H - 84
        root.addSubview(sectionLabel("Who does this apply to?", y: y)); y -= 20
        root.addSubview(caption("Pick the parts of the team this bar covers.", y: y)); y -= 40

        let chips = lanes.map {
            chip($0.title, selected: chosenLanes.contains($0.title),
                 enabled: $0.onTeam, action: #selector(toggleLane(_:)))
        }
        y = layChips(chips, into: root, top: y) - 26

        // A lane with nobody on it used to surface as `no seats matched` AFTER
        // submitting a whole bar. Saying it here deletes that error state.
        let missing = lanes.filter { !$0.onTeam }.map(\.title)
        if !missing.isEmpty {
            let verb = missing.count == 1 ? "isn't" : "aren't"
            root.addSubview(caption("\(missing.joined(separator: ", ")) \(verb) on this team yet.",
                                    y: y, height: 18))
            y -= 26
        }
        if !chosenLanes.isEmpty {
            root.addSubview(caption(reviewerCaption, y: y - 14, height: 34))
        }
    }

    /// Who will hold it, in words — never a seat picker. The engine's own
    /// `suggest_reviewers` does exactly what this promises, which is why the
    /// sheet submits an empty reviewers field rather than asking.
    private var reviewerCaption: String {
        switch kind {
        case "code":
            return "Held by the code reviewer in each lane you picked — never the "
                 + "person who built the work."
        case "design":
            return "Held by the design reviewer — never the person who built the work."
        default:
            return "Held by a reviewer outside the lane that did the work — never "
                 + "the person who built it."
        }
    }

    // ---- Step 3

    private func renderGreat(_ root: NSView) {
        // A strict top-down cursor. The first draft placed each element with its
        // own arithmetic and the link plate ended up 22pt inside the caption
        // above it — with a fixed 520pt sheet and no way to eyeball it, the
        // layout has to be the kind that cannot drift.
        // The band from 444 down to ~76 is all step 3 has: the footer buttons
        // own 24…54 and the refusal line 58…90. Everything below is sized to
        // land inside it — three plates, two reference rows and the sentence.
        var cursor = H - 76
        func slot(_ height: CGFloat, gap: CGFloat = 10) -> CGFloat {
            cursor -= height + gap
            return cursor + gap
        }

        let label = sectionLabel("What does great look like?", y: 0)
        label.setFrameOrigin(NSPoint(x: inset, y: slot(14, gap: 4)))
        root.addSubview(label)
        let intro = caption("Give the reviewer something real to hold the work against. "
                            + "Pick any — or more than one.", y: 0, height: 30)
        intro.setFrameOrigin(NSPoint(x: inset, y: slot(30, gap: 6)))
        root.addSubview(intro)

        // Three plates of equal weight. "Find best in class" is as big and as
        // prominent as the other two: a first-class choice, not an escape hatch.
        let plateW = W - inset * 2

        let link = PongSheetChrome.plate(
            frame: NSRect(x: inset, y: slot(56, gap: 8), width: plateW, height: 56))
        addPlateTitle("Paste a link", to: link)
        let url = NSTextField(frame: NSRect(x: 14, y: 6, width: plateW - 110, height: 24))
        url.placeholderString = "https://…"
        url.font = PongTheme.font(12)
        url.isBordered = true
        url.bezelStyle = .roundedBezel
        url.identifier = NSUserInterfaceItemIdentifier("gauntletURL")
        link.addSubview(url)
        let add = PongSheetChrome.outlineButton("Add", target: self, action: #selector(addLink))
        add.frame = NSRect(x: plateW - 88, y: 6, width: 74, height: 24)
        link.addSubview(add)
        root.addSubview(link)

        let file = FileDropPlate(frame: NSRect(x: inset, y: slot(56, gap: 8), width: plateW, height: 56))
        addPlateTitle("Drop a file", to: file)
        file.onDrop = { [weak self] path in self?.addReference(path) }
        file.addSubview(caption2("Drag it here, or", x: 14, y: 10))
        let choose = PongSheetChrome.outlineButton("Choose…", target: self, action: #selector(chooseFile))
        choose.frame = NSRect(x: 132, y: 6, width: 90, height: 24)
        file.addSubview(choose)
        root.addSubview(file)

        let find = PongSheetChrome.plate(
            frame: NSRect(x: inset, y: slot(70, gap: 8), width: plateW, height: 70))
        addPlateTitle("Find best in class", to: find)
        let copy = NSTextField(wrappingLabelWithString:
            "We'll look at X, GitHub, Reddit and the open web for the best example "
            + "of this, and bring back candidates. Nothing counts until you confirm it.")
        copy.font = PongTheme.font(12)
        copy.textColor = PongTheme.textSecondary
        copy.frame = NSRect(x: 14, y: 8, width: plateW - 110, height: 40)
        find.addSubview(copy)
        let doIt = PongSheetChrome.outlineButton(research ? "✓ On" : "Do it",
                                                 target: self, action: #selector(toggleResearch))
        doIt.frame = NSRect(x: plateW - 88, y: 20, width: 74, height: 24)
        find.addSubview(doIt)
        root.addSubview(find)

        // Two rows is all the band has room for; beyond that it says how many
        // are held rather than growing down through the footer. The pitch is 30,
        // not 22: the × needs a 28pt hit region, and at 22 consecutive rows put
        // their delete targets 6pt on top of one another.
        let rows = referenceRows
        for ref in rows.prefix(2) {
            let y = slot(30, gap: 0)
            let row = NSTextField(labelWithString: "✓ " + ref.label)
            row.font = PongTheme.font(12)
            row.textColor = PongTheme.textPrimary
            row.frame = NSRect(x: inset, y: y + 6, width: W - inset * 2 - 40, height: 18)
            root.addSubview(row)
            // 28pt of hit region for a 10pt glyph — the difference between
            // removable and merely decorative.
            let x = NSButton(frame: NSRect(x: W - inset - 28, y: y + 1, width: 28, height: 28))
            x.bezelStyle = .inline
            x.isBordered = false
            x.attributedTitle = NSAttributedString(string: "×", attributes: [
                .foregroundColor: PongTheme.textSecondary, .font: PongTheme.font(14)])
            x.target = self
            x.action = #selector(dropReference(_:))
            x.identifier = NSUserInterfaceItemIdentifier(ref.id)
            root.addSubview(x)
        }
        if rows.count > 2 {
            let more = caption("and \(rows.count - 2) more", y: 0, height: 14)
            more.setFrameOrigin(NSPoint(x: inset, y: slot(14, gap: 2)))
            root.addSubview(more)
        }

        // The summary sentence assembles from the person's own words as they go. It is
        // the last chance to notice a wrong chip, which is why there is no
        // separate confirm step.
        //
        // It stands down for a refusal. The two would share the same strip of
        // sheet, and when the engine has just said no, its words are the ones
        // the person needs — not a description of what they were trying to set.
        guard errorLine.isEmpty else { return }
        let sum = NSTextField(wrappingLabelWithString: summarySentence)
        sum.font = PongTheme.font(12)
        sum.textColor = PongTheme.textSecondary
        sum.frame = NSRect(x: inset, y: slot(32, gap: 8), width: W - inset * 2, height: 32)
        root.addSubview(sum)
    }

    private func addPlateTitle(_ text: String, to plate: NSView) {
        let t = NSTextField(labelWithString: text)
        t.font = PongTheme.font(12, weight: .semibold)
        t.textColor = PongTheme.textPrimary
        t.frame = NSRect(x: 14, y: plate.frame.height - 22, width: 300, height: 16)
        plate.addSubview(t)
    }

    private func caption2(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = PongTheme.font(12)
        f.textColor = PongTheme.textSecondary
        f.frame = NSRect(x: x, y: y, width: 120, height: 16)
        return f
    }

    static func shortRef(_ ref: String) -> String {
        if ref.hasPrefix("http"), let u = URL(string: ref), let host = u.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return (ref as NSString).lastPathComponent
    }

    private var summarySentence: String {
        let who = chosenLanes.isEmpty ? "The team"
                : Self.list(Array(chosenLanes).sorted())
        let goal = goalText.isEmpty ? "the goal you set" : "\"\(goalText.prefix(60))\""
        var against = ""
        let rows = referenceRows.map(\.label)
        if !rows.isEmpty {
            against = ", judged against \(Self.list(rows))"
        } else if research {
            against = ", judged against the best in class once you confirm it"
        }
        return "\(who) will be held to \(goal)\(against) — by their reviewers, never by themselves."
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    // MARK: Actions

    @objc private func pickKind(_ sender: NSButton) {
        let label = sender.identifier?.rawValue ?? ""
        kind = Self.kinds.first { $0.label == label }?.id ?? ""
        errorLine = ""
        render()
    }

    @objc private func toggleLane(_ sender: NSButton) {
        let title = sender.identifier?.rawValue ?? ""
        if chosenLanes.contains(title) { chosenLanes.remove(title) } else { chosenLanes.insert(title) }
        errorLine = ""
        render()
    }

    @objc private func addLink() {
        guard let field = findURLField() else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // A link the engine will store as an anchor has to be a link. Saying so
        // here beats storing "asdf" as what great looks like.
        guard let u = URL(string: raw), let scheme = u.scheme,
              scheme.hasPrefix("http"), (u.host ?? "").contains(".") else {
            errorLine = "That doesn't look like a link."
            render()
            return
        }
        addReference(raw)
    }

    private func findURLField() -> NSTextField? {
        func hunt(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField,
               f.identifier?.rawValue == "gauntletURL" { return f }
            for s in v.subviews { if let f = hunt(s) { return f } }
            return nil
        }
        return window?.contentView.flatMap(hunt)
    }

    private func addReference(_ ref: String) {
        if !references.contains(ref) { references.append(ref) }
        errorLine = ""
        render()
    }

    @objc private func dropReference(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        if id.hasPrefix("kept:"), let i = Int(id.dropFirst(5)), keptReferences.indices.contains(i) {
            keptReferences.remove(at: i)
        } else if id.hasPrefix("new:") {
            let value = String(id.dropFirst(4))
            references.removeAll { $0 == value }
        }
        render()
    }

    @objc private func chooseFile() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { addReference(url.path) }
    }

    @objc private func toggleResearch() {
        research.toggle()
        errorLine = ""
        render()
    }

    /// Seams for the layout harness. The sheet is 560x520 with no scrolling, so
    /// "does step 3 still fit with five references and a refusal on screen" is a
    /// correctness question, and a click cannot get there in one move.
    func testSetReferences(_ refs: [String]) { references = refs; render() }
    func testSetError(_ line: String) { errorLine = line; render() }

    @objc private func cancel() { close(.cancel) }

    @objc private func back() {
        step = max(0, step - 1)
        errorLine = ""
        render()
    }

    @objc private func next() {
        guard stepIsValid else { return }
        if step < 2 { step += 1; errorLine = ""; render(); return }
        submit()
    }

    // MARK: Submit

    private func submit() {
        let goal = goalText
        let leads = lanes.filter { chosenLanes.contains($0.title) }.flatMap(\.leads)
        let title = editing?.title ?? goal.split(separator: " ").prefix(6).joined(separator: " ")
        var answers: [String: Any] = [
            "kind": kind,
            // The picker's own language. `run_answers` expands each lead into
            // its lane's seats, so the sheet never names a seat.
            "groups": leads,
            "title": title,
            "bar_id": editing?.id ?? "",
            "summary": goal,
            // Only what the person added in this sitting; anything the bar already had
            // travels as a structured reference below, keeping its real file.
            "great": references.isEmpty ? (referenceRows.isEmpty ? "help" : "")
                                        : references.joined(separator: ", "),
            "fail": "",
            "dimensions": "",
            "min_each": editing?.minEach ?? 3,
            "min_mean": editing?.minMean ?? 4.0,
            "never_waived": "",
            // Empty on purpose — `suggest_reviewers` decides, matching what the
            // step-2 caption promised.
            "reviewers": "",
            "scope": "project",
        ]

        if let bar = editing {
            // An edit is an OVERRIDE, never a rewrite of what shipped.
            //
            // Machine scope rather than project: both live bars came with
            // CyberPong and match on role, so they are not one project's
            // standard, and `~/.pong/review/bars` is the layer that sits over
            // the package and under any project. It also keeps CyberPong from
            // writing files into whatever repo happens to be bound.
            answers["scope"] = "machine"
            // Dimensions and their scored anchors are not editable here and must
            // survive verbatim; the comma-separated form would blank every
            // anchor and split "Root cause, not symptom" into two dimensions.
            answers["dimensions"] = bar.dimensions
            if !keptReferences.isEmpty { answers["references"] = keptReferences }
            // So the real reference files are carried across rather than
            // replaced by empty stubs in the new directory.
            answers["inherit_refs_from"] = bar.dir
        }

        switch ReviewBarSetup.create(answers: answers, session: session) {
        case .failure(let why):
            errorLine = why
            render()
        case .success:
            if research {
                let ok = ReviewBarSetup.fileResearchJob(goal: goal, session: session)
                Pong.log("gauntlet research job filed=\(ok)")
            }
            Pong.log("gauntlet bar \(editing == nil ? "written" : "overridden") "
                     + "for \(chosenLanes.sorted())")
            close(.OK)
            PanelController.shared.refreshUI()
        }
    }
}

extension GauntletSheet: NSTextViewDelegate {
    /// The Continue button is inactive until the goal has words in it, so the
    /// button has to hear about every keystroke.
    func textDidChange(_ notification: Notification) {
        guard step == 0 else { return }
        if let b = window?.contentView?.subviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.keyEquivalent == "\r" }) {
            b.isEnabled = stepIsValid
            b.alphaValue = stepIsValid ? 1 : 0.4
        }
    }
}

/// Top-down document view for the requirements scroll — AppKit's default
/// bottom-up coordinates would stack the list upside down.
final class GauntletFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The file plate, which is also a drop target.
///
/// The Choose… button beside it is the alternative route, not a fallback: drag
/// and drop should never be the only way to do something.
final class FileDropPlate: NSView {
    var onDrop: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongTheme.bgElevated.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = PongSheetChrome.lime.withAlphaComponent(0.35).cgColor
        let rail = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: frame.height))
        rail.wantsLayer = true
        rail.layer?.backgroundColor = PongSheetChrome.lime.cgColor
        addSubview(rail)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL],
              let first = urls.first else { return false }
        onDrop?(first.path)
        return true
    }
}
