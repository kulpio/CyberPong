import AppKit

/// New graph (⌘N): "What do you want done?", where, an optional recipe, and Start.
/// A chat (the engine's architect) opens with the request as its brief and plans the graph
/// with you (design-language.md §4, New graph sheet; ux-review.md §2: two steps, not seven).
final class NewGraphSheet: PongSheet, NSTextViewDelegate {
    private var onStarted: ((String) -> Void)?

    private let field = NSTextView()
    private let fieldScroll = NSScrollView()
    private let placeholder = PongUI.label("e.g. Compare our three competitors' prices and tell me where we stand",
                                           PongType.body, PongColor.textTertiary)
    private let wherePop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let moreBtn = PongButton(title: "More options", style: .quiet, size: .small)
    /// The AI and model this graph's chat runs on; first item: your default, or the recommendation.
    private let picker = ArchitectPicker(style: .newGraph)
    private var aiPop: NSPopUpButton { picker.aiPop }
    private var modelPop: NSPopUpButton { picker.modelPop }
    private var catalogObserver: NSObjectProtocol?
    private let templateLink = PongButton(title: "Start from a template…", style: .quiet, size: .small)
    private let errorLine = PongUI.label("", PongType.secondary, PongColor.fail, lines: 4)
    private let startBtn = PongButton(title: "Start", style: .primary, size: .large)
    private let cancelBtn = PongButton(title: "Cancel", style: .secondary, size: .large)
    /// Shown only for a chat that was saved but whose AI didn't start.
    private let openBtn = PongButton(title: "Open the chat", style: .secondary, size: .large)
    private let working = StatusMarkerView(.working, size: 14)
    /// While the graph runner is off: a graph started now stops after its first step. Said before
    /// Start, with a way to turn it on here.
    private let runnerMark = StatusMarkerView(.needsYou, size: 14)
    private let runnerLine = PongUI.label("Graphs won't move past their first step until the graph runner is on.",
                                          PongType.secondary, PongColor.textSecondary, lines: 2)
    private let runnerBtn = PongButton(title: "Turn on", style: .secondary, size: .small)
    private var runnerShown = false
    /// Why Turn on didn't work, while the error line shows it (cleared once it works).
    private var runnerError: String?
    private var moreOpen = false
    private var extra: [NSView] = []
    /// A chat that was saved but whose AI didn't start: Start becomes "Try again", which starts
    /// its team again (the AI comes back on this chat), and "Open the chat" opens it as it is.
    private var savedChat: String?

    private static let recentKey = "newgraph.recentFolders"

    /// - Parameter onStarted: the new chat's key ("session/id") once the architect is up.
    static func present(from parent: NSWindow?, onStarted: @escaping (String) -> Void) {
        let s = NewGraphSheet(width: 560, height: 436)
        s.onStarted = onStarted
        s.build()
        s.present(on: parent)
        s.window.makeFirstResponder(s.field)
    }

    private func build() {
        let W: CGFloat = 560, pad: CGFloat = 24
        let title = PongUI.label("What do you want done?", PongType.question, PongColor.textPrimary)
        title.frame = NSRect(x: pad, y: 24, width: W - pad * 2, height: 24)
        content.addSubview(title)
        let sub = PongUI.label("A chat plans it with you, then runs it.", PongType.secondary, PongColor.textSecondary)
        sub.frame = NSRect(x: pad, y: 52, width: W - pad * 2, height: 16)
        content.addSubview(sub)

        // the request
        field.font = PongType.body
        field.textColor = PongColor.textPrimary
        field.backgroundColor = PongColor.field
        field.insertionPointColor = PongColor.live
        field.isRichText = false
        field.allowsUndo = true
        field.textContainerInset = NSSize(width: 6, height: 8)
        field.delegate = self
        field.setAccessibilityLabel("What do you want done?")
        fieldScroll.documentView = field
        fieldScroll.hasVerticalScroller = true
        fieldScroll.autohidesScrollers = true
        fieldScroll.drawsBackground = true
        fieldScroll.backgroundColor = PongColor.field
        fieldScroll.borderType = .noBorder
        fieldScroll.wantsLayer = true
        fieldScroll.layer?.cornerRadius = PongRadius.control
        fieldScroll.layer?.borderWidth = 1
        fieldScroll.layer?.borderColor = PongColor.control.cgColor
        fieldScroll.frame = NSRect(x: pad, y: 82, width: W - pad * 2, height: 120)
        field.frame = NSRect(x: 0, y: 0, width: W - pad * 2, height: 120)
        field.autoresizingMask = [.width]
        content.addSubview(fieldScroll)
        placeholder.frame = NSRect(x: pad + 11, y: 90, width: W - pad * 2 - 22, height: 18)
        content.addSubview(placeholder)

        // where
        let whereLabel = PongUI.eyebrow("Where")
        whereLabel.frame = NSRect(x: pad, y: 218, width: 200, height: 16)
        content.addSubview(whereLabel)
        wherePop.frame = NSRect(x: pad - 2, y: 238, width: W - pad * 2 + 4, height: 28)
        wherePop.target = self
        wherePop.action = #selector(whereChanged)
        fillWhere()
        PongTheme.stylePopUp(wherePop)
        content.addSubview(wherePop)

        // recipes
        let recipesLabel = PongUI.eyebrow("Start from a recipe")
        recipesLabel.frame = NSRect(x: pad, y: 282, width: 300, height: 16)
        content.addSubview(recipesLabel)
        var x = pad
        for (name, text) in Self.recipes {
            let chip = PongButton(title: name, style: .secondary, size: .small)
            chip.toolTip = text
            chip.onPress = { [weak self] in self?.useRecipe(text) }
            let w = chip.intrinsicContentSize.width
            chip.frame = NSRect(x: x, y: 304, width: w, height: 24)
            content.addSubview(chip)
            x += w + 8
        }

        // more options: the AI and model, the template flow
        moreBtn.symbol = "chevron.right"
        moreBtn.toolTip = "Choose the AI and model the chat runs on"
        moreBtn.onPress = { [weak self] in self?.toggleMore() }
        moreBtn.frame = NSRect(x: pad - 8, y: 342, width: moreBtn.intrinsicContentSize.width, height: 24)
        content.addSubview(moreBtn)
        loadModels()
        for v in [aiPop, modelPop] { v.isHidden = true; content.addSubview(v) }
        templateLink.toolTip = "Run a ready-made graph (build and check, split up, best of N…) on a team you already have"
        templateLink.onPress = { [weak self] in
            self?.close()
            PanelController.shared.startFromTemplate()
        }
        templateLink.isHidden = true
        content.addSubview(templateLink)
        extra = [aiPop, modelPop, templateLink]

        // the graph runner: the engine's own word from the last graph list (nil: it didn't say)
        runnerShown = GraphStore.shared.runnerOK == false
        runnerBtn.toolTip = "Start the graph runner now and whenever you log in"
        runnerBtn.onPress = { [weak self] in self?.turnOnRunner() }
        for v in [runnerMark, runnerLine, runnerBtn] as [NSView] {
            v.isHidden = !runnerShown
            content.addSubview(v)
        }

        errorLine.isHidden = true
        content.addSubview(errorLine)
        working.isHidden = true
        content.addSubview(working)
        cancelBtn.onPress = { [weak self] in self?.close() }
        cancelBtn.keyEquivalent = "\u{1b}"
        startBtn.onPress = { [weak self] in self?.start() }
        startBtn.toolTip = "Open the chat with your request (Return)"
        openBtn.isHidden = true
        openBtn.toolTip = "Open the saved chat as it is: its AI isn't running"
        openBtn.onPress = { [weak self] in
            guard let self, let key = self.savedChat else { return }
            self.close()
            self.onStarted?(key)
        }
        content.addSubview(cancelBtn)
        content.addSubview(openBtn)
        content.addSubview(startBtn)
        layoutFooter()
        updatePlaceholder()
    }

    static let recipes: [(String, String)] = [
        ("Research and summarise", "Research … and write me a one-page summary with its sources."),
        ("Build and check", "Build … and check it works: the tests pass and a reviewer approves it."),
        ("Review a document", "Review … and list what to fix, most important first."),
    ]

    private func useRecipe(_ text: String) {
        field.string = text
        updatePlaceholder()
        window.makeFirstResponder(field)
        if let r = text.range(of: "…") {
            field.setSelectedRange(NSRange(r, in: text))
        }
    }

    private func toggleMore() {
        moreOpen.toggle()
        moreBtn.symbol = moreOpen ? "chevron.down" : "chevron.right"
        for v in extra { v.isHidden = !moreOpen }
        layoutFooter()
    }

    private func layoutFooter() {
        let W: CGFloat = 560, pad: CGFloat = 24
        var y: CGFloat = 372
        if moreOpen {
            // the AI pop-up names only the AI ("AI: Codex / OpenAI (recommended)" is the longest)
            aiPop.frame = NSRect(x: pad - 2, y: y, width: 270, height: 28)
            modelPop.frame = NSRect(x: pad + 278, y: y, width: 234, height: 28)
            y += 36
            templateLink.frame = NSRect(x: pad - 8, y: y, width: templateLink.intrinsicContentSize.width, height: 24)
            y += 32
        }
        if runnerShown {
            // marker, the line (as tall as its words) and Turn on at the end
            let bw = runnerBtn.intrinsicContentSize.width
            let tw = W - pad * 2 - 22 - bw - 12
            let th = max(16, min(34, ceil(runnerLine.attributedStringValue.boundingRect(with: NSSize(width: tw - 4, height: 200),
                                                                                    options: [.usesLineFragmentOrigin]).height) + 2))
            let rowH = max(24, th)
            runnerMark.frame = NSRect(x: pad, y: y + (rowH - 14) / 2, width: 14, height: 14)
            runnerLine.frame = NSRect(x: pad + 22, y: y + (rowH - th) / 2, width: tw, height: th)
            runnerBtn.frame = NSRect(x: W - pad - bw, y: y + (rowH - 24) / 2, width: bw, height: 24)
            y += rowH + 8
        }
        if !errorLine.isHidden {
            // as tall as its words: a line cut off would hide what to do next
            let h = min(64, ceil(errorLine.attributedStringValue.boundingRect(with: NSSize(width: W - pad * 2 - 4, height: 200),
                                                                              options: [.usesLineFragmentOrigin]).height) + 2)
            errorLine.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: max(16, h))
            y += max(16, h) + 4
        }
        y += 8
        let rule = content.subviews.first { $0.identifier?.rawValue == "footerRule" } ?? {
            let r = footerRule(y: 0)
            r.identifier = NSUserInterfaceItemIdentifier("footerRule")
            content.addSubview(r)
            return r
        }()
        rule.frame = NSRect(x: 0, y: y, width: W, height: 1)
        let sw = max(96, startBtn.intrinsicContentSize.width)
        startBtn.frame = NSRect(x: W - pad - sw, y: y + 12, width: sw, height: 32)
        var left = startBtn.frame.minX
        if !openBtn.isHidden {
            let ow = openBtn.intrinsicContentSize.width
            openBtn.frame = NSRect(x: left - 8 - ow, y: y + 12, width: ow, height: 32)
            left = openBtn.frame.minX
        }
        cancelBtn.frame = NSRect(x: left - 8 - 88, y: y + 12, width: 88, height: 32)
        working.frame = NSRect(x: cancelBtn.frame.minX - 26, y: y + 21, width: 14, height: 14)
        let H = y + 56
        window.setContentSize(NSSize(width: W, height: H))
        content.frame = NSRect(x: 0, y: 0, width: W, height: H)
    }

    // MARK: Where

    private var recentFolders: [String] {
        (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func fillWhere() {
        wherePop.removeAllItems()
        let home = NSHomeDirectory()
        for f in recentFolders.prefix(6) {
            wherePop.addItem(withTitle: f.hasPrefix(home) ? "~" + f.dropFirst(home.count) : f)
            wherePop.lastItem?.representedObject = f
        }
        if wherePop.numberOfItems == 0 {
            wherePop.addItem(withTitle: "Choose a project folder…")
            wherePop.lastItem?.representedObject = nil
        } else {
            wherePop.menu?.addItem(.separator())
        }
        if wherePop.itemArray.last?.title != "Choose…" && wherePop.numberOfItems > 1 {
            wherePop.addItem(withTitle: "Choose…")
        }
        wherePop.selectItem(at: 0)
        wherePop.toolTip = "The project's folder: the graph's steps and its chat work there."
    }

    @objc private func whereChanged() {
        let t = wherePop.titleOfSelectedItem ?? ""
        if t == "Choose…" || t == "Choose a project folder…" { chooseFolder() }
        PongTheme.stylePopUpItemTitles(wherePop)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "The project's folder: its graphs' steps and its chat work here."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            if r == .OK, let url = panel.url { self.remember(url.path) }
            self.fillWhere()
            PongTheme.stylePopUp(self.wherePop)
        }
    }

    private func remember(_ path: String) {
        var list = recentFolders.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: Self.recentKey)
    }

    private var folder: String? { wherePop.selectedItem?.representedObject as? String }

    // MARK: AI and model

    /// The shared catalog (SetupModel): read once, refreshed here in case an AI was installed
    /// or switched off since. The pop-ups keep a choice already made while it updates.
    private func loadModels() {
        let m = SetupModel.shared
        picker.fill(catalog: m.catalog, doctor: m.doctor)
        catalogObserver = NotificationCenter.default.addObserver(forName: SetupModel.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let rt = self.picker.runtime, model = self.picker.model
            self.picker.fill(catalog: m.catalog, doctor: m.doctor)
            self.picker.select(runtime: rt, model: model)
        }
        m.refreshCatalog()
    }

    override func close() {
        if let o = catalogObserver { NotificationCenter.default.removeObserver(o) }
        catalogObserver = nil
        super.close()
    }

    // MARK: Text

    func textDidChange(_ notification: Notification) { updatePlaceholder() }

    private func updatePlaceholder() {
        placeholder.isHidden = !field.string.isEmpty
    }

    /// Return starts; ⌥Return or ⇧Return adds a line; Esc cancels.
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.option) || flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            start()
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    // MARK: Start

    private func showError(_ s: String) {
        errorLine.stringValue = "✕ " + s
        errorLine.isHidden = s.isEmpty
        layoutFooter()
    }

    /// Turn on: the graph runner, as setup's row does it. On, the line says so and the button goes;
    /// not on, the error line says why in plain words.
    private func turnOnRunner() {
        runnerBtn.isEnabled = false
        runnerBtn.title = "Turning on…"
        layoutFooter()
        SetupActions.installRunner(.elsewhere) { [weak self] ok, words in
            guard let self else { return }
            self.runnerBtn.isEnabled = true
            self.runnerBtn.title = "Turn on"
            if ok {
                self.runnerMark.status = .done
                self.runnerLine.stringValue = words
                self.runnerBtn.isHidden = true
                // only the runner's own error goes: one about the request or the folder stays
                if let e = self.runnerError, self.errorLine.stringValue == "✕ " + e { self.showError("") }
                self.runnerError = nil
            } else {
                Pong.log("new graph: the graph runner didn't turn on")
                self.runnerError = words
                self.showError(words)
            }
            self.layoutFooter()
        }
    }

    /// A short name from the request: its first words.
    static func titleFrom(_ text: String, folder: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6).map(String.init)
        var t = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?…"))
        if t.count > 48 { t = String(t.prefix(48)) + "…" }
        return t.isEmpty ? (folder as NSString).lastPathComponent : t
    }

    /// Busy while the engine works: the buttons wait and the marker turns.
    private func busy(_ on: Bool, title: String) {
        startBtn.isEnabled = !on
        cancelBtn.isEnabled = !on
        openBtn.isEnabled = !on
        working.isHidden = !on
        startBtn.title = title
        layoutFooter()
    }

    /// The saved chat's AI didn't start: start its team again (`pong team start`), which brings
    /// the lead, this chat's AI, back on this chat's prompt; then open the chat.
    private func tryAgain(_ key: String) {
        let session = String(key.split(separator: "/").first ?? "")
        guard !session.isEmpty else {
            close()
            onStarted?(key)
            return
        }
        busy(true, title: "Starting…")
        GraphCLI.run(["-s", session, "team", "start", "--json"], timeout: 60) { [weak self] r in
            guard let self else { return }
            let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] ?? [:]
            guard AppSettings.flag(obj["ok"]) == true else {
                let error = (obj["error"] as? String) ?? r.err
                Pong.log("new graph: team start \(session) failed: \(error.prefix(300))")
                self.busy(false, title: "Try again")
                self.showError(ArchitectStart.retryProblem(error))
                return
            }
            PairState.invalidatePairsCache()
            // an AI that isn't signed in (or isn't there) stops at once: look before saying it's up
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openIfAlive(key) }
        }
    }

    /// After Try again: open the chat once its AI is really running, else say it still isn't.
    private func openIfAlive(_ key: String) {
        GraphCLI.run(["architect", "list", "--json"], timeout: 20) { [weak self] r in
            guard let self else { return }
            let rows = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]] ?? []
            let row = rows.first { "\(($0["session"] as? String) ?? "")/\(($0["id"] as? String) ?? "")" == key }
            GraphStore.shared.refresh()
            if let row, AppSettings.flag(row["alive"]) == false {
                Pong.log("new graph: chat \(key) started again but its AI stopped at once")
                self.busy(false, title: "Try again")
                self.showError(ArchitectStart.retryProblem(""))
                return
            }
            self.close()
            Toast.show("Chat open. Its AI is reading your request.")
            self.onStarted?(key)
        }
    }

    private func start() {
        if let key = savedChat {
            tryAgain(key)
            return
        }
        let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showError("Say what you want done: the chat starts from it.")
            window.makeFirstResponder(field)
            return
        }
        guard let folder else {
            showError("Choose the project's folder first.")
            chooseFolder()
            return
        }
        showError("")
        remember(folder)
        busy(true, title: "Starting…")
        var args = ["architect", "new", "--title", Self.titleFrom(text, folder: folder), "--project", folder,
                    "--brief", text, "--json"]
        // the first item passes nothing: the engine runs the default saved in Settings, or its
        // recommendation when there is none or the saved AI can't run here (switched off, not
        // installed), which an explicit --runtime would turn into an error instead
        if let rt = picker.runtime {
            args += ["--runtime", rt]
            if let m = picker.model { args += ["--model", m] }
        }
        GraphCLI.run(args, timeout: 90) { [weak self] r in
            guard let self else { return }
            switch ArchitectStart.read(out: r.out, err: r.err) {
            case .failed(let why):
                self.busy(false, title: "Start")
                Pong.log("architect new failed: \(r.err.isEmpty ? r.out : r.err)")
                self.showError(why)
            case .opened(let key, let warning):
                GraphStore.shared.refresh()
                if let warning {
                    // the chat exists but its AI isn't running: say so here, not "Chat open"
                    Pong.log("architect new: chat \(key) saved, AI not started (\(r.out.prefix(300)))")
                    self.savedChat = key
                    self.cancelBtn.title = "Close"
                    self.openBtn.isHidden = false
                    self.startBtn.toolTip = "Start the chat's AI again on this chat, then open it"
                    self.busy(false, title: "Try again")
                    self.showError(warning + " " + ArchitectStart.startAgainHint)
                    return
                }
                self.close()
                Toast.show("Chat open. Its AI is reading your request.")
                self.onStarted?(key)
            }
        }
    }
}
