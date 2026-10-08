import AppKit
import QuartzCore

/// Minimalist Guide chat on the 3D map — FAB that grows on hover / nudge.
/// On disconnect: shows reconnect strip → login Terminal → headless again.
final class AppAIChatBubble: NSView {
    static let shared = AppAIChatBubble()

    private let fab = NSButton(frame: .zero)
    private let panel = NSView(frame: .zero)
    private let titleLabel = PongUI.eyebrow("Guide")
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let input = NSTextField(frame: .zero)
    private let sendBtn = PongButton(title: "Ask", style: .primary, size: .small)
    private let nudgeChip = NSTextField(labelWithString: "")
    /// Disconnect / reconnect strip above the input
    private let reconnectBar = NSView(frame: .zero)
    private let reconnectLabel = NSTextField(wrappingLabelWithString: "")
    private let reconnectBtn = PongButton(title: "Reconnect", style: .primary, size: .small)
    /// Coach / Apply action strip (ghost seats, spawn sub, chat intents)
    private let actionBar = NSView(frame: .zero)
    private let actionLabel = NSTextField(wrappingLabelWithString: "")
    private let actionBtn = PongButton(title: "Apply", style: .primary, size: .small)
    private let actionBtn2 = PongButton(title: "", style: .secondary, size: .small)
    private var actionHandler: (() -> Void)?
    private var secondaryHandler: (() -> Void)?
    private var pendingIntents: [AppAIMutator.Intent] = []
    private var expanded = false
    private var hovering = false
    private var busy = false
    /// Map/canvas host for collapsed FAB. Expanded panel reparents to window contentView.
    private weak var mapHost: NSView?
    private var attachedTo: NSView?
    private var nudgeHideWork: DispatchWorkItem?
    /// reconnectIdle | awaitingSignIn | connecting
    private var reconnectPhase: ReconnectPhase = .hidden
    /// Cap transcript so Guide never becomes a novel.
    private let maxTranscriptChars = 6_000

    private enum ReconnectPhase {
        case hidden
        case needsReconnect
        case awaitingSignIn
        case connecting
    }

    /// Collapsed FAB size · expanded panel (sizes fixed — job e83a7a)
    private let fabSize: CGFloat = 44
    private let panelW: CGFloat = 360
    private let panelH: CGFloat = 440
    private let pad: CGFloat = 16
    private let reconnectBarH: CGFloat = 80
    private let actionBarH: CGFloat = 72
    /// Above stage + topBar siblings so close ✕ is never under status pill.
    private let overlayZ: CGFloat = 50_000

    private override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func attachIfNeeded(to host: NSView? = nil) {
        if let host {
            mapHost = host
        } else if mapHost == nil {
            mapHost = PanelController.shared.mapHostView()
        }
        guard mapHost != nil || PanelController.shared.guideOverlayHost() != nil else { return }
        isHidden = !expanded
        reparentForCurrentMode()
        layoutInHost()
        ensureFrontmost()
        // If already offline from a prior session, offer reconnect when first attached
        if !AppAIRuntime.isHeadlessReady, AppAISettings.providerId != nil {
            showDisconnected(
                userFacing: "Guide is offline. Open sign-in Terminal, then tap I’m signed in (safe to close that window after).",
                expand: false
            )
        }
    }

    /// Raise Guide above map HUD and top-bar chrome (call after panel layout / expand).
    func ensureFrontmost() {
        guard let host = superview else { return }
        host.addSubview(self, positioned: .above, relativeTo: nil)
        layer?.zPosition = overlayZ
        // Close control last among panel children so it wins hit-tests
        if expanded, let close = panel.subviews.first(where: { $0.identifier?.rawValue == "close" }) {
            panel.addSubview(close, positioned: .above, relativeTo: nil)
            close.layer?.zPosition = 10
        }
    }

    /// Collapsed → map host (FAB). Expanded → window contentView above topBar.
    private func reparentForCurrentMode() {
        let desired: NSView? = {
            if expanded {
                return PanelController.shared.guideOverlayHost() ?? mapHost ?? superview
            }
            return mapHost ?? PanelController.shared.mapHostView()
        }()
        guard let desired else { return }
        if superview === desired {
            attachedTo = desired
            return
        }
        removeFromSuperview()
        desired.addSubview(self, positioned: .above, relativeTo: nil)
        attachedTo = desired
    }

    func layoutInHost() {
        // Ensure correct parent before measuring bounds
        reparentForCurrentMode()
        guard let host = superview else { return }
        let w = host.bounds.width
        let h = host.bounds.height
        if expanded {
            // Bottom-right of usable stage; keep panel fully below top bar so ✕ is visible.
            let topClear = PanelController.shared.guideTopBarClearance
            let maxTopY = max(panelH + pad, h - topClear)
            var y = pad + 36
            if y + panelH > maxTopY {
                y = max(pad, maxTopY - panelH)
            }
            frame = NSRect(
                x: w - panelW - pad,
                y: y,
                width: panelW,
                height: panelH
            )
            panel.isHidden = false
            fab.isHidden = true
            nudgeChip.isHidden = true
            layer?.zPosition = overlayZ
        } else {
            // collapsed is closed: the floating button is retired (1.9)
            frame = .zero
            panel.isHidden = true
            fab.isHidden = true
            layer?.zPosition = 100
        }
        isHidden = !expanded
        autoresizingMask = [.minXMargin, .maxYMargin]
        ensureFrontmost()
    }

    private func build() {
        // 1.9: the floating sparkle button is retired; the Guide opens from ⌘K (Ask the Guide)
        // and its hints arrive as toasts. What is left is the panel, in the popover look.
        fab.isHidden = true
        fab.target = self
        fab.action = #selector(toggleExpand)
        addSubview(fab)
        nudgeChip.isHidden = true
        addSubview(nudgeChip)

        panel.wantsLayer = true
        panel.layer?.backgroundColor = PongColor.overlay.cgColor
        panel.layer?.cornerRadius = PongRadius.card
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.45
        panel.layer?.shadowRadius = 16
        panel.isHidden = true
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Guide")
        addSubview(panel)

        panel.addSubview(titleLabel)

        let close = PongButton(title: "", style: .quiet, size: .small)
        close.symbol = "xmark"
        close.target = self
        close.action = #selector(collapse)
        close.frame = NSRect(x: panelW - 36, y: panelH - 36, width: 28, height: 28)
        close.identifier = NSUserInterfaceItemIdentifier("close")
        close.toolTip = "Close the Guide"
        close.setAccessibilityLabel("Close the Guide")
        panel.addSubview(close)

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        transcript.isEditable = false
        transcript.isRichText = false
        transcript.font = PongType.body
        transcript.textColor = PongColor.textPrimary
        transcript.backgroundColor = .clear
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 8, height: 8)
        transcript.setAccessibilityLabel("The Guide's answers")
        scroll.documentView = transcript
        panel.addSubview(scroll)

        // offline: it needs you, so it sits on the question tint
        reconnectBar.wantsLayer = true
        reconnectBar.layer?.backgroundColor = PongColor.tintYou.cgColor
        reconnectBar.layer?.cornerRadius = PongRadius.control
        reconnectBar.isHidden = true
        panel.addSubview(reconnectBar)
        reconnectLabel.font = PongType.secondary
        reconnectLabel.textColor = PongColor.textPrimary
        reconnectLabel.maximumNumberOfLines = 3
        reconnectLabel.isEditable = false
        reconnectLabel.isBezeled = false
        reconnectLabel.drawsBackground = false
        reconnectBar.addSubview(reconnectLabel)
        reconnectBtn.target = self
        reconnectBtn.action = #selector(reconnectPressed)
        reconnectBar.addSubview(reconnectBtn)

        // a change the Guide can apply
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = PongColor.raised.cgColor
        actionBar.layer?.cornerRadius = PongRadius.control
        actionBar.isHidden = true
        panel.addSubview(actionBar)
        actionLabel.font = PongType.secondary
        actionLabel.textColor = PongColor.textPrimary
        actionLabel.maximumNumberOfLines = 2
        actionLabel.isEditable = false
        actionLabel.isBezeled = false
        actionLabel.drawsBackground = false
        actionBar.addSubview(actionLabel)
        actionBtn.target = self
        actionBtn.action = #selector(actionPressed)
        actionBar.addSubview(actionBtn)
        actionBtn2.target = self
        actionBtn2.action = #selector(secondaryActionPressed)
        actionBtn2.isHidden = true
        actionBar.addSubview(actionBtn2)

        input.placeholderAttributedString = NSAttributedString(string: "Ask the Guide…", attributes: [
            .font: PongType.body, .foregroundColor: PongColor.textTertiary])
        input.font = PongType.body
        input.textColor = PongColor.textPrimary
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.target = self
        input.action = #selector(send)
        input.setAccessibilityLabel("Ask the Guide")
        inputBox.wantsLayer = true
        inputBox.layer?.backgroundColor = PongColor.field.cgColor
        inputBox.layer?.cornerRadius = PongRadius.control
        inputBox.layer?.borderWidth = 1
        inputBox.layer?.borderColor = PongColor.control.cgColor
        panel.addSubview(inputBox)
        panel.addSubview(input)

        sendBtn.target = self
        sendBtn.action = #selector(send)
        panel.addSubview(sendBtn)

        appendLocal("Ask about your teams and graphs: what is running, what is stuck, what needs you.")
    }

    private let inputBox = NSView()

    private func styleReconnectButton(title: String) {
        reconnectBtn.title = title
    }

    private func styleActionButton(title: String) {
        actionBtn.title = title
    }

    override func layout() {
        super.layout()
        if expanded {
            panel.frame = bounds
            titleLabel.frame = NSRect(x: 16, y: panelH - 30, width: 160, height: 16)
            let reconOn = !reconnectBar.isHidden
            let actOn = !actionBar.isHidden
            let reconH: CGFloat = reconOn ? reconnectBarH : 0
            let actH: CGFloat = actOn ? actionBarH : 0
            let gap: CGFloat = (reconOn || actOn) ? 6 : 0
            let bottomChrome = reconH + actH + (reconOn && actOn ? 6 : 0) + gap
            scroll.frame = NSRect(
                x: 8, y: 48 + bottomChrome,
                width: panelW - 16,
                height: max(60, panelH - 84 - bottomChrome)
            )
            var yBar: CGFloat = 44
            if reconOn {
                reconnectBar.frame = NSRect(x: 10, y: yBar, width: panelW - 20, height: reconnectBarH)
                reconnectLabel.frame = NSRect(x: 10, y: 32, width: panelW - 40, height: 40)
                reconnectBtn.frame = NSRect(x: 10, y: 6, width: reconnectBtn.intrinsicContentSize.width, height: 24)
                yBar += reconnectBarH + 6
            }
            if actOn {
                actionBar.frame = NSRect(x: 10, y: yBar, width: panelW - 20, height: actionBarH)
                actionLabel.frame = NSRect(x: 10, y: 36, width: panelW - 40, height: 28)
                let aw = actionBtn.intrinsicContentSize.width
                actionBtn.frame = NSRect(x: 10, y: 6, width: aw, height: 24)
                if !actionBtn2.isHidden {
                    actionBtn2.frame = NSRect(x: 18 + aw, y: 6, width: actionBtn2.intrinsicContentSize.width, height: 24)
                }
            }
            let sw = sendBtn.intrinsicContentSize.width
            inputBox.frame = NSRect(x: 12, y: 12, width: panelW - 24 - sw - 8, height: 28)
            input.frame = inputBox.frame.insetBy(dx: 8, dy: 5)
            sendBtn.frame = NSRect(x: panelW - 12 - sw, y: 14, width: sw, height: 24)
            if let close = panel.subviews.first(where: { $0.identifier?.rawValue == "close" }) {
                close.frame = NSRect(x: panelW - 36, y: panelH - 36, width: 28, height: 28)
            }
        } else if !nudgeChip.isHidden {
            let s = fab.frame.width
            nudgeChip.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: bounds.width - s - 10, height: 16)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !expanded {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                layoutInHost()
            }
            pulseFab(strong: true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !expanded {
            layoutInHost()
            pulseFab(strong: false)
        }
    }

    private func pulseFab(strong: Bool) {
        fab.layer?.shadowOpacity = strong ? 0.7 : 0.35
        fab.layer?.shadowRadius = strong ? 14 : 10
    }

    @objc private func toggleExpand() {
        expanded = true
        // Reparent to contentView above topBar so close ✕ is never under status pill
        reparentForCurrentMode()
        layoutInHost()
        needsLayout = true
        layout()
        ensureFrontmost()
        window?.makeFirstResponder(input)
    }

    /// Open the panel without asking anything (previews).
    func previewOpen() {
        attachIfNeeded()
        toggleExpand()
    }

    @objc private func collapse() {
        expanded = false
        // Restore FAB on map host
        reparentForCurrentMode()
        layoutInHost()
    }

    /// Expand Guide and seed a cron-creation conversation (chat-first schedule path).
    func beginCronWizard(session: String?, ownerHint: String? = nil, seatLabels: [String] = []) {
        attachIfNeeded()
        expanded = true
        layoutInHost()
        let sess = session ?? PairState.listPairs().first ?? "(current team)"
        let seats = seatLabels.isEmpty ? "c1 / w1…" : seatLabels.joined(separator: ", ")
        let ownerLine = ownerHint.map { " Prefer owner seat `\($0)` unless the user picks another." } ?? ""
        let intro =
            "Help me schedule a cron for team `\(sess)`. Seats: \(seats)." +
            ownerLine +
            " Ask what should run, which seat owns it, and how often." +
            " When ready, emit one line the app can Apply:\n" +
            "CREATE_CRON name=\"…\" owner=w1 cadence=\"every 15m\" task=\"…\""
        appendLocal("Guide: Let's set up a schedule. Tell me what should run, who owns it, and how often.")
        window?.makeFirstResponder(input)
        // Seed headless with the structured brief so Guide asks the right questions
        if AppAIRuntime.isHeadlessReady, !busy {
            busy = true
            sendBtn.isEnabled = false
            AppAIRuntime.chat(userMessage: intro) { [weak self] result in
                guard let self else { return }
                self.busy = false
                self.sendBtn.isEnabled = true
                switch result {
                case .reply(let reply):
                    self.appendLocal("Guide: \(reply)")
                    let fromReply = AppAIMutator.parseChatIntents(reply, defaultSession: session ?? PairState.listPairs().first)
                    if !fromReply.isEmpty {
                        self.offerApply(
                            intents: fromReply,
                            summary: "Guide drafted \(fromReply.count) cron change\(fromReply.count == 1 ? "" : "s") — apply?"
                        )
                    }
                case .disconnected(_, let userFacing):
                    self.appendLocal("Guide: \(userFacing)")
                    self.showDisconnected(userFacing: userFacing, expand: true)
                }
            }
        } else if !AppAIRuntime.isHeadlessReady {
            showDisconnected(
                userFacing: "The Guide is offline. Reconnect, then describe the schedule (or add it on the Schedules page).",
                expand: true
            )
        }
        Pong.log("Guide beginCronWizard session=\(sess)")
    }

    /// Expand Guide with a mission/ops question and live snapshot context (via AppAIRuntime).
    func beginMissionAsk(_ question: String) {
        attachIfNeeded()
        expanded = true
        layoutInHost()
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            window?.makeFirstResponder(input)
            return
        }
        appendLocal("You: \(q)")
        let sess = PairState.listPairs().first
        let local = AppAIMutator.parseChatIntents(q, defaultSession: sess)
        if !local.isEmpty {
            offerApply(intents: local, summary: "Detected \(local.count) change(s) from your question.")
        }
        guard AppAIRuntime.isHeadlessReady else {
            // Offline: still answer from snapshot rules
            let grounded = GuideCoach.answerMissionQuestion(q)
            appendLocal("Guide: \(grounded)")
            return
        }
        busy = true
        sendBtn.isEnabled = false
        let prompt =
            "MISSION Q&A (use live team state only; name seats and job ages; no fluff).\n" +
            "Question: \(q)\n" +
            "If useful, suggest opening a job id or switching the team shown on the Team page."
        AppAIRuntime.chat(userMessage: prompt) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.sendBtn.isEnabled = true
            switch result {
            case .reply(let reply):
                self.appendLocal("Guide: \(reply)")
            case .disconnected(_, let userFacing):
                let grounded = GuideCoach.answerMissionQuestion(q)
                self.appendLocal("Guide: \(grounded)\n(\(userFacing))")
                self.showDisconnected(userFacing: userFacing, expand: true)
            }
        }
    }

    /// Brief nudge — grows chip next to FAB without full chat.
    func nudge(_ text: String) {
        attachIfNeeded()
        let short = String(text.prefix(80))
        if expanded {
            appendLocal("Guide: \(short)")
            return
        }
        // 1.9: a hint is a toast (the floating button it used to sit beside is retired)
        Toast.show(short)
    }

    /// Proactive coach: short card + action button(s) — not a wall of text.
    func nudgeAction(
        text: String,
        actionTitle: String?,
        action: (() -> Void)?,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        chipText: String? = nil
    ) {
        attachIfNeeded()
        let short = String(text.prefix(120))
        // Collapsed: a toast, with the action on it when there is one (no transcript spam)
        if !expanded {
            if let actionTitle, let action {
                Toast.show(chipText ?? short, action: actionTitle, onAction: action)
            } else {
                nudge(chipText ?? short)
            }
        }
        // Expanded transcript: one short line, not a novel
        if expanded {
            appendLocal("Guide: \(short)")
        }
        // Do NOT expand. A nudge is Guide's idea, not a request — opening the
        // panel over what someone is doing to volunteer a suggestion is the
        // interruption, and it arrives from a background poll they never asked
        // for. Collapsed, it glows and waits to be opened. An explicit click,
        // the cron wizard and a direct question all still expand, because those
        // are asked for.
        if !expanded {
            pulseFab(strong: true)
        }
        layoutInHost()
        if let actionTitle, let action {
            actionHandler = action
            pendingIntents = []
            actionLabel.stringValue = short
            styleActionButton(title: actionTitle)
            actionBar.isHidden = false
            if let secondaryTitle, let secondaryAction {
                secondaryHandler = secondaryAction
                actionBtn2.isHidden = false
                actionBtn2.title = secondaryTitle
            } else {
                secondaryHandler = nil
                actionBtn2.isHidden = true
            }
        } else {
            actionBar.isHidden = true
            actionHandler = nil
            secondaryHandler = nil
            actionBtn2.isHidden = true
        }
        needsLayout = true
        layout()
        pulseFab(strong: true)
    }

    private func offerApply(intents: [AppAIMutator.Intent], summary: String) {
        guard !intents.isEmpty else { return }
        pendingIntents = intents
        actionHandler = nil
        actionLabel.stringValue = summary
        styleActionButton(title: "Apply \(intents.count) change\(intents.count == 1 ? "" : "s")")
        actionBar.isHidden = false
        expanded = true
        layoutInHost()
        needsLayout = true
        layout()
    }

    @objc private func actionPressed() {
        if let handler = actionHandler {
            actionHandler = nil
            secondaryHandler = nil
            actionBar.isHidden = true
            actionBtn2.isHidden = true
            needsLayout = true
            layout()
            handler()
            return
        }
        let intents = pendingIntents
        pendingIntents = []
        actionBar.isHidden = true
        actionBtn2.isHidden = true
        needsLayout = true
        layout()
        guard !intents.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppAIMutator.apply(intents)
            DispatchQueue.main.async {
                if result.failed.isEmpty {
                    self.appendLocal("Guide: Applied — \(result.applied.joined(separator: ", ")).")
                    PanelController.shared.refreshUI()
                } else {
                    self.appendLocal("Guide: Partial fail — " + result.failed.map { "\($0.0): \($0.1)" }.joined(separator: "; "))
                    PanelController.shared.refreshUI()
                }
            }
        }
    }

    @objc private func secondaryActionPressed() {
        let handler = secondaryHandler
        secondaryHandler = nil
        actionBtn2.isHidden = true
        needsLayout = true
        layout()
        handler?()
    }

    // MARK: - Disconnect / reconnect

    private func showDisconnected(userFacing: String, expand: Bool = true) {
        reconnectPhase = .needsReconnect
        reconnectBar.isHidden = false
        reconnectLabel.stringValue = userFacing
        styleReconnectButton(title: "Open sign-in Terminal")
        reconnectBtn.isEnabled = true
        if expand {
            expanded = true
            layoutInHost()
        }
        needsLayout = true
        layout()
        if !expand {
            nudge("The Guide is offline: ask it something to reconnect")
        }
    }

    private func hideReconnectBar() {
        reconnectPhase = .hidden
        reconnectBar.isHidden = true
        needsLayout = true
        layout()
    }

    @objc private func reconnectPressed() {
        switch reconnectPhase {
        case .hidden:
            break
        case .needsReconnect:
            startLoginReconnect()
        case .awaitingSignIn:
            finishLoginReconnect()
        case .connecting:
            break
        }
    }

    private func startLoginReconnect() {
        reconnectPhase = .awaitingSignIn
        reconnectLabel.stringValue = "Sign in / pick model in Terminal.\nSafe to close that window after — or tap I’m signed in (we close it)."
        styleReconnectButton(title: "I’m signed in")
        reconnectBtn.isEnabled = true
        appendLocal("Opening \(AppAISettings.provider?.label ?? "AI") sign-in Terminal…")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppAIRuntime.openLoginTerminal()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func finishLoginReconnect() {
        reconnectPhase = .connecting
        reconnectLabel.stringValue = "Closing Terminal · checking headless…"
        styleReconnectButton(title: "Connecting…")
        reconnectBtn.isEnabled = false
        AppAIRuntime.completeLogin { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                self.hideReconnectBar()
                self.appendLocal("Guide: \(msg)")
                self.nudge("Guide reconnected")
                self.window?.makeFirstResponder(self.input)
            } else {
                self.reconnectPhase = .needsReconnect
                self.reconnectLabel.stringValue = msg + "\nTry again — open sign-in Terminal."
                self.styleReconnectButton(title: "Open sign-in Terminal")
                self.reconnectBtn.isEnabled = true
                self.appendLocal("Guide: \(msg)")
            }
        }
    }

    @objc private func send() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        // If offline, treat send as a nudge to reconnect rather than silent rules
        if reconnectPhase != .hidden || !AppAIRuntime.isHeadlessReady {
            input.stringValue = ""
            appendLocal("You: \(text)")
            showDisconnected(
                userFacing: "Guide is offline. Open sign-in Terminal, sign in, then tap I’m signed in (safe to close that window after).",
                expand: true
            )
            appendLocal("Guide: Still offline. Use Open sign-in Terminal below to reconnect.")
            return
        }
        input.stringValue = ""
        appendLocal("You: \(text)")
        // Local mutator parse — offer Apply without waiting for headless
        let sess = PairState.listPairs().first
        let localIntents = AppAIMutator.parseChatIntents(text, defaultSession: sess)
        if !localIntents.isEmpty {
            offerApply(
                intents: localIntents,
                summary: "Detected \(localIntents.count) architecture change\(localIntents.count == 1 ? "" : "s") from your message."
            )
        }
        busy = true
        sendBtn.isEnabled = false
        AppAIRuntime.chat(userMessage: text) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.sendBtn.isEnabled = true
            switch result {
            case .reply(let reply):
                self.appendLocal("Guide: \(reply)")
                // Also parse Guide reply for apply lines
                let fromReply = AppAIMutator.parseChatIntents(reply, defaultSession: sess)
                if !fromReply.isEmpty, self.pendingIntents.isEmpty {
                    self.offerApply(
                        intents: fromReply,
                        summary: "Guide suggested \(fromReply.count) change\(fromReply.count == 1 ? "" : "s") — apply?"
                    )
                }
            case .disconnected(_, let userFacing):
                self.appendLocal("Guide: \(userFacing)")
                self.showDisconnected(userFacing: userFacing, expand: true)
            }
        }
    }

    private func appendLocal(_ s: String) {
        // Skip near-duplicate consecutive lines (same coach spam)
        let cur = transcript.string
        if cur.hasSuffix(s) || cur.contains("\n\n" + s) {
            let tail = String(cur.suffix(min(cur.count, s.count + 40)))
            if tail.contains(s) { return }
        }
        var next = cur.isEmpty ? s : cur + "\n\n" + s
        if next.count > maxTranscriptChars {
            next = "…\n\n" + String(next.suffix(maxTranscriptChars - 8))
        }
        transcript.string = next
        transcript.scrollToEndOfDocument(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(hostResized),
                name: NSView.frameDidChangeNotification, object: superview
            )
            superview?.postsFrameChangedNotifications = true
        }
    }

    @objc private func hostResized() { layoutInHost() }
}

// Hook for PanelController
extension PanelController {
    /// Host view for floating Guide bubble (3D map page).
    func mapHostView() -> NSView? {
        return _mapHostForBubble()
    }
}
