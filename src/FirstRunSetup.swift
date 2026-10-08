import AppKit

/// The first-run setup (2.0): a sheet on the main window in the 1.9 look, one plain question
/// per step — Welcome · Is this Mac ready? · Which AIs do you use? · Which AI plans your graphs?
/// · Limits and spending · Keys (optional) · You're set. It shows once on a new Mac (Skip setup
/// counts as done) and any time from Help › Set up CyberPong…, the menu bar menu and
/// Settings › AI accounts › Run setup again…. Settings shows the same rows (SetupParts.swift).
final class FirstRunSetup: PongSheet, SetupHost {
    static let stepCount = 7
    private static weak var shown: FirstRunSetup?

    private static let words: [(String, String)] = [
        ("Welcome to CyberPong",
         "Say what you want done: an AI plans it as a graph of steps, your AIs do the steps, and they ask you when a decision is yours."),
        ("Is this Mac ready?",
         "CyberPong needs a few tools and two Mac permissions. Fix what you can; you can continue either way."),
        ("Which AIs do you use?",
         "Sign in to each AI you want CyberPong to use, and switch off the ones you don't."),
        ("Which AI plans your graphs?",
         "When you start a graph, a chat with this AI turns your request into steps."),
        ("Limits and spending",
         "What happens near Claude's limits, and what CyberPong may spend on its own."),
        ("Keys (optional)",
         "Two extra services, each with its own key. You can add them later in Settings › Limits & keys."),
        ("You're set",
         "Here's what's ready. Anything still missing can be fixed later in Settings."),
    ]

    private let W: CGFloat = 600
    private let pad: CGFloat = 24

    /// The window the sheet hangs from (known before it is attached).
    private weak var hostWindow: NSWindow?
    /// The host's frame before setup made it taller, and the frame it made: put back on close
    /// unless the person has resized it since.
    private var hostFrameBefore: NSRect?
    private var hostFrameGrown: NSRect?
    private lazy var fade = MoreBelowFade(on: bodyScroll, color: PongColor.raised)

    private var host: NSWindow? { window.sheetParent ?? hostWindow ?? PanelController.shared.sheetHost }

    /// The tallest body the host window allows, under a header of `bodyY` points: the sheet hangs
    /// ~66 pt below the window's top, keeps ~12 pt clear at its foot, and has a 76 pt footer.
    private func maxBody(bodyY: CGFloat) -> CGFloat {
        let parentH = host?.frame.height ?? 680
        return max(240, parentH - 66 - 12 - bodyY - 76)
    }

    private var step = 0
    private var afterClose: (() -> Void)?
    private let dots = StepDotsView(count: FirstRunSetup.stepCount)
    private let titleLabel = PongUI.label("", PongType.question, PongColor.textPrimary)
    private let subLabel = PongUI.label("", PongType.secondary, PongColor.textSecondary, lines: 3)
    private let bodyScroll = NSScrollView()
    private let bodyDoc = SetupFlipped()
    private var rule: NSView?
    private let skipBtn = PongButton(title: "Skip setup", style: .quiet, size: .large)
    private let backBtn = PongButton(title: "Back", style: .secondary, size: .large)
    private let laterBtn = PongButton(title: "Later", style: .secondary, size: .large)
    private let nextBtn = PongButton(title: "Continue", style: .primary, size: .large)
    private let picker = ArchitectPicker(style: .settings)
    private var nameField: SetupField?
    private var permissionsOn = true
    private var observer: NSObjectProtocol?
    private var lastHeight: CGFloat = 0
    private var lastSignature = ""
    private var flashedStep = -1
    /// Set once close() starts: late redraw requests (a field ending its edit) are ignored.
    private var closing = false

    // MARK: Showing

    /// On a new Mac: setup was never finished or skipped, and the person never went through the
    /// 1.x onboarding either (people who did aren't made to do it again).
    static var shouldShowOnLaunch: Bool {
        guard !AppSettings.setupDone else { return false }
        let ai = (AppSettings.load()["app_ai"] as? [String: Any]) ?? [:]
        return AppSettings.flag(ai["onboarding_complete"]) != true
    }

    /// - Parameters:
    ///   - force: false shows it only when `shouldShowOnLaunch`.
    ///   - step: 0–6.
    ///   - afterClose: runs once the sheet is gone (the launch path attaches the Guide).
    @discardableResult
    static func present(force: Bool = true, step: Int = 0, on parent: NSWindow? = nil,
                        afterClose: (() -> Void)? = nil) -> Bool {
        guard force || shouldShowOnLaunch else { return false }
        let to = max(0, min(stepCount - 1, step))
        if let s = shown {
            s.go(to)
            if !UIPreview.isOn { NSApp.activate(ignoringOtherApps: true) }
            return true
        }
        var host = parent
        if host == nil {
            if !UIPreview.isOn || PanelController.shared.sheetHost == nil { PanelController.shared.show() }
            host = PanelController.shared.sheetHost
        }
        let s = FirstRunSetup(width: 600, height: 480)
        s.afterClose = afterClose
        s.hostWindow = host
        s.build()
        shown = s
        s.go(to)
        s.present(on: host)
        if to == 0, let f = s.nameField { s.window.makeFirstResponder(f.field) }
        Pong.log("setup: shown at step \(to)")
        return true
    }

    private func build() {
        content.addSubview(dots)
        titleLabel.setAccessibilityRole(.staticText)
        content.addSubview(titleLabel)
        content.addSubview(subLabel)
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .noBorder
        bodyScroll.documentView = bodyDoc
        content.addSubview(bodyScroll)
        content.addSubview(fade)
        let r = footerRule(y: 0)
        content.addSubview(r)
        rule = r
        skipBtn.toolTip = "Close setup. Help › Set up CyberPong… opens it again."
        skipBtn.onPress = { [weak self] in self?.skip() }
        backBtn.onPress = { [weak self] in self?.back() }
        laterBtn.toolTip = "Close setup and start later from New graph (⌘N)"
        laterBtn.onPress = { [weak self] in self?.finish(newGraph: false) }
        nextBtn.onPress = { [weak self] in self?.next() }
        for b in [skipBtn, backBtn, laterBtn, nextBtn] { content.addSubview(b) }
        observer = NotificationCenter.default.addObserver(forName: SetupModel.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.modelChanged()
        }
        let m = SetupModel.shared
        if m.doctor == nil { m.refreshDoctor() }
        m.refreshCatalog()
        // Never chosen: on for a new person (graphs that wait for a click on every tool aren't
        // graphs); for someone who has used CyberPong before, what the engine does today (ask).
        // Whatever shows is saved the moment step 3 shows it (render).
        permissionsOn = AppSettings.seatPermissions.map { $0 == "auto" } ?? Self.shouldShowOnLaunch
    }

    // MARK: Moving between steps

    private func go(_ s: Int) {
        // a number or a name still being typed is saved before its step goes (Return presses
        // Continue without ending the edit, and a field taken off the window drops it)
        endEditing()
        if step == 0 && s != 0 { commitName() }
        step = s
        dots.current = s
        let m = SetupModel.shared
        if s == 1 || s == 2 { m.startPolling(self, every: 3) } else { m.stopPolling(self) }
        if s == 3 || s == 6 { m.refreshCatalog() }
        if s >= 4 { m.refreshDoctor(); m.refreshKeys() }
        if s == Self.stepCount - 1 { Self.markDone() }
        bodyScroll.contentView.scroll(to: .zero)
        render()
    }

    private func endEditing() {
        if window.firstResponder is NSText { window.makeFirstResponder(nil) }
    }

    /// Setup finished or skipped. A preview only looks: it never writes the person's settings.
    private static func markDone() {
        guard !UIPreview.isOn else { return }
        AppSettings.markSetupDone()
        AppAISettings.markOnboardingComplete()
    }

    private func next() {
        guard nextBtn.isEnabled else { return }
        if step == Self.stepCount - 1 {
            finish(newGraph: true)
            return
        }
        go(step + 1)
    }

    private func back() {
        guard step > 0 else { return }
        go(step - 1)
    }

    private func skip() {
        endEditing()
        commitName()
        Self.markDone()
        Pong.log("setup: skipped at step \(step)")
        close()
    }

    private func finish(newGraph: Bool) {
        Self.markDone()
        close()
        if newGraph {
            DispatchQueue.main.async { PanelController.shared.newGraph() }
        }
    }

    override func close() {
        guard !closing else { return }
        closing = true
        endEditing()        // saves a number still being typed (its redraw request is ignored now)
        commitName()
        SetupModel.shared.stopPolling(self)
        SetupModel.shared.keyDrafts = [:]
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        super.close()
        // The rows' buttons and the picker call back into this sheet: let them go, and forget it,
        // so the next Set up CyberPong… builds a new sheet instead of finding this closed one.
        picker.onChange = nil
        bodyDoc.subviews.forEach { $0.removeFromSuperview() }
        restoreHost()
        if Self.shown === self { Self.shown = nil }
        let after = afterClose
        afterClose = nil
        after?()
    }

    /// Esc is Skip setup.
    @objc func cancelOperation(_ sender: Any?) { skip() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        skip()
        return false
    }

    private func commitName() {
        guard let f = nameField else { return }
        let n = AppSettings.cleanName(f.field.stringValue)
        if n != AppSettings.ownerName { AppSettings.setOwnerName(n) }
    }

    // MARK: SetupHost

    var setupWindow: NSWindow? { window }

    func setupNeedsRender() {
        guard !closing else { return }
        render()
    }

    /// Redraw only when what this step shows changed: a redraw drops a half-typed number.
    private func modelChanged() {
        guard !closing else { return }
        let sig = signature()
        guard sig != lastSignature else { return }
        render()
    }

    private func signature() -> String {
        let m = SetupModel.shared
        let doctor = String(describing: m.doctor?.forDisplay)
        switch step {
        case 1: return "\(doctor)|\(m.mac)"
        case 2: return "\(String(describing: m.doctor?.ais))|\(m.signingIn.sorted())"
        case 3: return "\(String(describing: m.catalog))|\(String(describing: m.doctor?.ais))"
        case 4: return "\(m.keys)|\(m.credits ?? "")"
        case 5: return "\(m.keys)|\(m.keyNotes.map { "\($0.key)=\($0.value)" }.sorted())"
        case 6: return "\(doctor)|\(m.mac)|\(String(describing: m.catalog))"
        default: return ""
        }
    }

    // MARK: Drawing a step

    private func render() {
        lastSignature = signature()
        let (title, sub) = Self.words[step]
        titleLabel.stringValue = title
        subLabel.stringValue = sub
        let keepScroll = bodyScroll.contentView.bounds.origin
        if step != 0 {
            commitName()
            nameField = nil
        }
        bodyDoc.subviews.forEach { $0.removeFromSuperview() }
        let bw = W - pad * 2
        var y: CGFloat = 0

        func card(_ rows: [SetupRowView]) {
            let c = SetupCardView(rows: rows, fill: PongColor.base)
            let h = c.fit(width: bw)
            c.frame = NSRect(x: 0, y: y, width: bw, height: h)
            bodyDoc.addSubview(c)
            y += h
        }
        func note(_ text: String, color: NSColor = PongColor.textTertiary, mark: PongStatus? = nil) {
            guard !text.isEmpty else { return }
            y += 10
            let x: CGFloat = mark == nil ? 4 : 24
            let l = PongUI.label(text, PongType.secondary, color, lines: 4)
            let h = ceil(l.attributedStringValue.boundingRect(with: NSSize(width: bw - x - 4, height: 200),
                                                              options: [.usesLineFragmentOrigin]).height) + 2
            l.frame = NSRect(x: x, y: y, width: bw - x - 4, height: h)
            bodyDoc.addSubview(l)
            if let mark {
                let mv = StatusMarkerView(mark, size: 14)
                mv.frame = NSRect(x: 4, y: y + 1, width: 14, height: 14)
                bodyDoc.addSubview(mv)
            }
            y += h
        }
        func section(_ s: String) {
            y += 24
            let e = PongUI.eyebrow(s)
            e.frame = NSRect(x: 4, y: y, width: bw - 8, height: 16)
            bodyDoc.addSubview(e)
            y += 24
        }

        let m = SetupModel.shared
        switch step {
        case 0:
            let ask = PongUI.label("What should your AIs call you?", PongType.bodyStrong, PongColor.textPrimary)
            ask.frame = NSRect(x: 0, y: 8, width: bw, height: 18)
            bodyDoc.addSubview(ask)
            let f = nameField ?? SetupField(placeholder: "Your first name", value: AppSettings.ownerName, width: 280)
            f.field.setAccessibilityLabel("What should your AIs call you?")
            f.onReturn = { [weak self] _ in self?.next() }
            f.onCommit = { [weak self] _ in self?.commitName() }
            f.frame = NSRect(x: 0, y: 34, width: 280, height: 28)
            bodyDoc.addSubview(f)
            nameField = f
            y = 62
            note("They use it in their messages to you and to each other, like “Sam answered your question.” Left empty, they say “the person”.")
            section("What happens next")
            note("Six short steps: this Mac, your AIs, the AI that plans your graphs, limits and spending, keys, and your first graph. Skip setup any time: Help › Set up CyberPong… brings it back.",
                 color: PongColor.textSecondary)

        case 1:
            card(SetupRows.macRows(host: self))
            let effects = SetupRows.macConsequences(m.doctor, m.mac)
            if m.doctor != nil {
                if SetupRows.macGaps(m.doctor, m.mac).isEmpty {
                    note("Everything CyberPong needs is on this Mac.", color: PongColor.textSecondary, mark: .done)
                } else if effects.isEmpty {
                    note("You can continue: macOS asks for what's left the first time CyberPong needs it.")
                } else {
                    note(MacReadiness.continueNote(effects), color: PongColor.textSecondary, mark: .needsYou)
                }
                if let d = m.doctor, !d.fromEngine { note(d.problem) }
            }

        case 2:
            card(SetupRows.aiRows(host: self))
            note("Each AI signs in inside its own command line, with its own account. CyberPong never sees a password.")
            if let block = SetupRows.aiBlocker(), m.doctor != nil {
                note(block, color: PongColor.textSecondary, mark: .needsYou)
            }

        case 3:
            // the switch shows a value before anyone touches it: save that now, so Skip, Back, Esc
            // or quitting can't leave the engine on "ask" while this sheet said on (a preview
            // only looks, like markDone)
            if !UIPreview.isOn { AppSettings.saveSeatPermissionsShown(auto: permissionsOn) }
            card(SetupRows.architectRows(picker: picker, permissionsOn: permissionsOn, host: self) { [weak self] v in
                self?.permissionsOn = v
                AppSettings.setSeatPermissions(auto: v)
            })
            note("You can pick another AI for one graph when you start it (New graph › More options).")

        case 4:
            card(SetupRows.limitsRows(host: self))
            note("These apply to graphs running on this Mac. Change them any time in Settings › Limits & keys.")

        case 5:
            card(SetupRows.keyRows(host: self))
            note("Keys stay on this Mac, in a file only you can read. CyberPong never shows a key again after you save it.")

        default:
            // the question itself is the subtitle, so it shows however long the recap is
            let ai = SetupRows.architectPair()
            subLabel.stringValue = "What do you want done first? New graph opens a chat"
                + (ai == "its AI" ? "" : " with \(ai)") + " that plans it with you. Later closes setup."
            card(recapRows())
        }

        layoutSheet(bodyHeight: y + 4)
        let maxY = max(0, bodyDoc.frame.height - bodyScroll.contentSize.height)
        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: min(keepScroll.y, maxY)))
        bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
        updateFooter()
    }

    /// What's ready and what isn't, on the last step: one short line each.
    private func recapRows() -> [SetupRowView] {
        let m = SetupModel.shared
        var rows: [SetupRowView] = []
        let gaps = SetupRows.macGaps(m.doctor, m.mac)
        rows.append(gaps.isEmpty
            ? SetupRowView(mark: .ok, title: "This Mac", line: "Ready.")
            : SetupRowView(mark: .needsYou, title: "This Mac", line: "Still to fix: " + MacReadiness.list(gaps) + "."))
        let ready = (m.doctor?.ais ?? []).filter { ai in
            ai.installed && AppSettings.aiEnabled(ai.id)
                && (ai.signedIn == true || (ai.signedIn == nil && ProviderAuth.isMarkedReady(typeId: ai.id)))
        }.map(\.label)
        rows.append(ready.isEmpty
            ? SetupRowView(mark: .needsYou, title: "Your AIs", line: "None is signed in yet. Settings › AI accounts signs one in.")
            : SetupRowView(mark: .ok, title: "Your AIs", line: MacReadiness.list(ready) + (ready.count == 1 ? " is ready." : " are ready.")))
        let planPassedOver = AppSettings.architect != nil && SetupRows.savedArchitectThatRuns() == nil
        rows.append(SetupRowView(mark: planPassedOver ? .needsYou : .ok, title: "Plans your graphs",
                                 line: SetupRows.architectWords() + "."))
        // what step 3 showed and saved (a preview saves nothing, and shows the same)
        let auto = AppSettings.seatPermissions.map { $0 == "auto" } ?? permissionsOn
        rows.append(SetupRowView(mark: .ok, title: "Working without asking",
                                 line: auto ? "On: Claude and Grok use their own auto mode." : "Off: each AI asks before using a tool."))
        let l = AppSettings.limits
        let lim = [l.rideOut5h ? "pause at the 5-hour limit" : "no 5-hour pause",
                   l.weekStopPct > 0 ? "stop at \(l.weekStopPct)% of the week" : "no weekly stop",
                   l.helperAI ? "helper AI on" : "helper AI off"].joined(separator: " · ")
        rows.append(SetupRowView(mark: .ok, title: "Limits", line: lim.prefix(1).uppercased() + lim.dropFirst() + "."))
        let k = m.keys
        rows.append(SetupRowView(mark: k.jev.set || k.perplexity.set ? .ok : .off, title: "Keys",
                                 line: "Jev: \(k.jev.set ? "set" : "not set") · Perplexity: \(k.perplexity.set ? "set" : "not set")."))
        return rows
    }

    /// A step taller than the window it hangs from allows: make that window taller, as far as its
    /// screen has room, rather than hide rows under the scroll edge. Only ever taller; put back
    /// as it was when setup closes (`restoreHost`).
    private func growHost(by extra: CGFloat) {
        guard extra >= 1, let h = host, h.styleMask.contains(.resizable), !h.styleMask.contains(.fullScreen),
              let vis = (h.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = h.frame
        let below = max(0, f.minY - vis.minY - 8)
        let above = max(0, vis.maxY - f.maxY)
        let add = min(extra, below + above, max(0, h.maxSize.height - f.height))
        guard add >= 1 else { return }
        if hostFrameBefore == nil { hostFrameBefore = f }
        let down = min(add, below)
        f.origin.y -= down          // the foot goes down first, then the top goes up
        f.size.height += add
        h.setFrame(f, display: true, animate: false)
        hostFrameGrown = h.frame
        Pong.log("setup: made the window \(Int(add)) pt taller for step \(step)")
    }

    private func restoreHost() {
        guard let before = hostFrameBefore, let h = hostWindow ?? PanelController.shared.sheetHost else { return }
        hostFrameBefore = nil
        // the person resized it meanwhile: theirs now
        guard let grown = hostFrameGrown, h.frame.equalTo(grown) else { return }
        h.setFrame(before, display: true, animate: !PongMotion.reduced)
    }

    private func layoutSheet(bodyHeight: CGFloat) {
        let tw = W - pad * 2
        dots.frame = NSRect(x: pad, y: 24, width: 160, height: 8)
        titleLabel.frame = NSRect(x: pad, y: 44, width: tw, height: 24)
        let subH = ceil(subLabel.attributedStringValue.boundingRect(with: NSSize(width: tw - 4, height: 200),
                                                                    options: [.usesLineFragmentOrigin]).height) + 2
        subLabel.frame = NSRect(x: pad, y: 72, width: tw, height: subH)
        let bodyY = 72 + subH + 20
        if bodyHeight > maxBody(bodyY: bodyY) { growHost(by: bodyHeight - maxBody(bodyY: bodyY)) }
        let visible = min(bodyHeight, maxBody(bodyY: bodyY))
        bodyScroll.frame = NSRect(x: pad, y: bodyY, width: tw, height: visible)
        bodyDoc.frame = NSRect(x: 0, y: 0, width: tw, height: bodyHeight)
        fade.place()
        // still more than fits (a small screen): the fade says so, and each step shows its
        // scroller for a moment once it is on screen
        if bodyHeight > visible + 1, flashedStep != step {
            flashedStep = step
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.bodyScroll.flashScrollers() }
        }
        let footerY = bodyY + visible + 20
        rule?.frame = NSRect(x: 0, y: footerY, width: W, height: 1)
        let by = footerY + 12
        var x = W - pad
        for b in [nextBtn, laterBtn, backBtn] where !b.isHidden {
            let w = max(88, b.intrinsicContentSize.width)
            x -= w
            b.frame = NSRect(x: x, y: by, width: w, height: 32)
            x -= 8
        }
        skipBtn.frame = NSRect(x: pad - 12, y: by, width: skipBtn.intrinsicContentSize.width, height: 32)
        let H = footerY + 56
        if abs(H - lastHeight) > 0.5 {
            lastHeight = H
            window.setContentSize(NSSize(width: W, height: H))
            content.frame = NSRect(x: 0, y: 0, width: W, height: H)
        }
    }

    private func updateFooter() {
        let last = step == Self.stepCount - 1
        backBtn.isHidden = step == 0
        laterBtn.isHidden = !last
        skipBtn.isHidden = last
        nextBtn.title = last ? "New graph…" : "Continue"
        nextBtn.toolTip = last ? "Close setup and open New graph" : nil
        nextBtn.isEnabled = step != 2 || SetupRows.aiBlocker() == nil
        // on the keys step Return saves the key being typed, not the step
        nextBtn.keyEquivalent = step == 5 ? "" : "\r"
        layoutSheet(bodyHeight: bodyDoc.frame.height)
    }
}

// MARK: - The graph runner, for someone past the first-run setup

extension FirstRunSetup {
    private static let runnerAskedKey = "setup.runnerQuestion.asked"

    /// At launch, for someone who isn't shown the first-run setup (it was done, or they set up
    /// before 2.0): when the graph runner isn't installed, ask once whether to turn it on. Once it is
    /// installed again the question is forgotten, so losing it later asks again. True when the
    /// question shows; `afterClose` runs once it is answered.
    @discardableResult
    static func askToTurnOnRunner(on parent: NSWindow? = nil, afterClose: (() -> Void)? = nil) -> Bool {
        guard !UIPreview.isOn else { return false }
        let ud = UserDefaults.standard
        let installed = FileManager.default.fileExists(atPath: RunnerInstall.plistPath(home: NSHomeDirectory()))
        let q = RunnerInstall.launchQuestion(installed: installed, asked: ud.bool(forKey: runnerAskedKey))
        if let r = q.remember { ud.set(r, forKey: runnerAskedKey) }
        guard q.ask else { return false }
        Pong.log("setup: the graph runner isn't installed; asking once to turn it on")
        PongAlert.show(on: parent ?? PanelController.shared.sheetHost, title: "Turn on the graph runner?",
                       message: "It moves your graphs from step to step, even with this window closed. While it's off, graphs stop after their first step.",
                       buttons: [.init("Not now"), .init("Turn on", .primary)], cancelIndex: 0) { i in
            if i == 1 {
                SetupActions.installRunner(.elsewhere) { ok, words in
                    if ok {
                        Toast.show(words)
                    } else {
                        // what's missing is on Settings › This Mac: one click away
                        Toast.show(words, warn: true, action: "Open This Mac") { SettingsWindow.shared.show(.mac) }
                    }
                }
            }
            afterClose?()
        }
        return true
    }
}
