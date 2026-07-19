import AppKit

/// Floating team inspector — digests control-plane activity into a readable task flow.
final class TeamFocusController: NSObject {
    static let shared = TeamFocusController()

    private var window: NSWindow?
    private var session: String = ""
    private var body: NSView!
    private var scroll: NSScrollView!
    private let W: CGFloat = 440
    private let H: CGFloat = 580

    func show(session: String) {
        self.session = session
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "Team focus"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = PongTheme.bg
        win.minSize = NSSize(width: 380, height: 420)
        win.setFrameAutosaveName("PongTeamFocus")

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongTheme.bg.cgColor
        root.autoresizingMask = [.width, .height]

        scroll = NSScrollView(frame: root.bounds.insetBy(dx: 14, dy: 40))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        body = NSView(frame: NSRect(x: 0, y: 0, width: W - 28, height: 500))
        scroll.documentView = body
        root.addSubview(scroll)

        win.contentView = root
        window = win
    }

    private func reload() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let boxW = max(340, scroll.contentSize.width > 20 ? scroll.contentSize.width - 4 : W - 28)

        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
        let cond = entry["conductor"] as? [String: Any]
        let condLabel = (cond?["label"] as? String) ?? "Orchestrator"
        let condType = (cond?["type"] as? String) ?? ""
        let workers = Workers.list(from: entry)
        let brief = (entry["team_brief"] as? String) ?? ""
        let rootPath = (entry["project_root"] as? String) ?? ""

        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        let teamSnap = ((snap["teams"] as? [[String: Any]]) ?? []).first { ($0["session"] as? String) == session }
        let openJobs = ((teamSnap?["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
        let counts = (teamSnap?["jobs"] as? [String: Any])?["counts"] as? [String: Any] ?? [:]
        let recentJobs = ((teamSnap?["jobs"] as? [String: Any])?["recent"] as? [[String: Any]]) ?? []
        let events = ((snap["events_tail"] as? [[String: Any]]) ?? [])
            .filter { ($0["session"] as? String) == session || $0["session"] == nil }

        let ledger = snap["ledger"] as? [String: Any] ?? [:]
        let rejectStreak = ledger["reject_streak"] as? Int ?? 0

        // Derive stage of pipeline
        let stage = digestStage(openJobs: openJobs, workers: workers, events: events, rejectStreak: rejectStreak)

        var blocks: [NSView] = []
        var total: CGFloat = 12

        // —— Header ——
        let headH: CGFloat = brief.isEmpty && rootPath.isEmpty ? 108 : 128
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: headH))
        PongTheme.applyFloating(head)
        head.addSubview(PanelController.label(display,
            frame: NSRect(x: 16, y: headH - 34, width: boxW - 32, height: 22), bold: true, size: 17))
        head.addSubview(PanelController.label("\(condLabel)\(condType.isEmpty ? "" : " · \(condType)") · \(workers.count) worker\(workers.count == 1 ? "" : "s")",
            frame: NSRect(x: 16, y: headH - 54, width: boxW - 32, height: 16), size: 11, secondary: true))
        if !brief.isEmpty {
            head.addSubview(PanelController.label(String(brief.prefix(120)),
                frame: NSRect(x: 16, y: 44, width: boxW - 32, height: 28), size: 11, secondary: true))
        } else if !rootPath.isEmpty {
            head.addSubview(PanelController.label(rootPath,
                frame: NSRect(x: 16, y: 48, width: boxW - 32, height: 16), size: 10, secondary: true))
        }
        let openOrch = btn("Open orchestrator", #selector(openOrch), filled: true)
        openOrch.frame = NSRect(x: 16, y: 12, width: 138, height: 28)
        head.addSubview(openOrch)
        let ref = btn("Refresh", #selector(refreshPressed), filled: false)
        ref.frame = NSRect(x: 162, y: 12, width: 72, height: 28)
        head.addSubview(ref)
        blocks.append(head)
        total += headH + 14

        // —— Flow digest (story) ——
        let story = flowStory(stage: stage, openCount: openJobs.count, workers: workers, rejectStreak: rejectStreak)
        let storyH: CGFloat = 72
        let storyCard = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: storyH))
        PongTheme.applyFloating(storyCard)
        let accent = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: storyH))
        accent.wantsLayer = true
        accent.layer?.backgroundColor = stage.color.cgColor
        storyCard.addSubview(accent)
        storyCard.addSubview(PanelController.label("What’s happening",
            frame: NSRect(x: 16, y: 46, width: boxW - 32, height: 14), size: 10, secondary: true))
        storyCard.addSubview(PanelController.label(story,
            frame: NSRect(x: 16, y: 12, width: boxW - 36, height: 34), bold: true, size: 13))
        blocks.append(storyCard)
        total += storyH + 14

        // —— Pipeline stages ——
        let stages = pipelineStages(openJobs: openJobs, events: events, rejectStreak: rejectStreak)
        let pipeH: CGFloat = 88
        let pipe = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: pipeH))
        PongTheme.applyFloating(pipe)
        pipe.addSubview(PanelController.label("Task flow",
            frame: NSRect(x: 14, y: pipeH - 26, width: 120, height: 16), bold: true, size: 12))
        let labels = ["Plan", "Assign", "Build", "Verify", "Done"]
        let gap: CGFloat = 6
        let sw = (boxW - 28 - gap * 4) / 5
        for (i, lab) in labels.enumerated() {
            let st = stages[i]
            let x = 14 + CGFloat(i) * (sw + gap)
            let cell = NSView(frame: NSRect(x: x, y: 12, width: sw, height: 46))
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 10
            cell.layer?.backgroundColor = st.active ? st.color.withAlphaComponent(0.18).cgColor : PongTheme.bgInput.cgColor
            cell.layer?.borderWidth = st.active ? 1.5 : 1
            cell.layer?.borderColor = st.active ? st.color.cgColor : PongTheme.border.cgColor
            let t = PanelController.label(lab, frame: NSRect(x: 4, y: 22, width: sw - 8, height: 14), bold: st.active, size: 10)
            t.alignment = .center
            if st.active { t.textColor = st.color }
            cell.addSubview(t)
            let sub = PanelController.label(st.caption, frame: NSRect(x: 2, y: 6, width: sw - 4, height: 12), size: 8, secondary: true)
            sub.alignment = .center
            cell.addSubview(sub)
            pipe.addSubview(cell)
            if i < labels.count - 1 {
                let arrow = PanelController.label("→", frame: NSRect(x: x + sw - 2, y: 24, width: gap + 4, height: 14), size: 10, secondary: true)
                pipe.addSubview(arrow)
            }
        }
        blocks.append(pipe)
        total += pipeH + 14

        // —— In flight jobs (digest) ——
        let jobRows = max(openJobs.count, 1)
        let qH: CGFloat = 44 + CGFloat(jobRows) * 52
        let queue = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: qH))
        PongTheme.applyFloating(queue)
        queue.addSubview(PanelController.label("In flight",
            frame: NSRect(x: 16, y: qH - 28, width: 160, height: 18), bold: true, size: 13))
        queue.addSubview(PanelController.label("\(openJobs.count) open · \(counts["done"] as? Int ?? 0) done",
            frame: NSRect(x: boxW - 140, y: qH - 26, width: 124, height: 14), size: 10, secondary: true))
        if openJobs.isEmpty {
            queue.addSubview(PanelController.label("Queue empty. Orchestrator can plan next work or wait for human.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 28), size: 12, secondary: true))
        } else {
            var ly = qH - 48
            for j in openJobs.prefix(6) {
                let st = (j["status"] as? String) ?? "queued"
                let prev = (j["task_preview"] as? String) ?? (j["id"] as? String) ?? ""
                let worker = (j["worker_label"] as? String) ?? (j["worker"] as? String) ?? "?"
                let sk = PongTheme.statusKind(st)
                let row = NSView(frame: NSRect(x: 12, y: ly - 44, width: boxW - 24, height: 48))
                row.wantsLayer = true
                row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                row.layer?.cornerRadius = 12
                row.layer?.borderWidth = 1
                row.layer?.borderColor = sk.soft.cgColor
                let badge = pill(sk.label, color: sk.color, soft: sk.soft)
                badge.frame = NSRect(x: 10, y: 26, width: 72, height: 18)
                row.addSubview(badge)
                row.addSubview(PanelController.label("→ \(worker)",
                    frame: NSRect(x: 90, y: 26, width: boxW - 130, height: 16), size: 10, secondary: true))
                row.addSubview(PanelController.label(prev,
                    frame: NSRect(x: 12, y: 6, width: boxW - 48, height: 16), size: 11))
                queue.addSubview(row)
                ly -= 52
            }
        }
        blocks.append(queue)
        total += qH + 14

        // —— Orchestra ——
        let aH: CGFloat = 40 + CGFloat(workers.count + 1) * 44
        let orch = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: aH))
        PongTheme.applyFloating(orch)
        orch.addSubview(PanelController.label("Orchestra",
            frame: NSRect(x: 16, y: aH - 28, width: 160, height: 18), bold: true, size: 13))
        var ay = aH - 52
        orch.addSubview(agentRow(boxW: boxW, y: ay, title: condLabel, sub: "orchestrator · plans & verifies",
                                  id: "orch", accent: PongTheme.blue))
        ay -= 44
        for w in workers {
            let wid = (w["id"] as? String) ?? "?"
            let lab = (w["label"] as? String) ?? wid
            let typ = (w["type"] as? String) ?? "worker"
            var hint = "ready"
            if let ws = teamSnap?["workers"] as? [[String: Any]],
               let match = ws.first(where: { ($0["id"] as? String) == wid }) {
                hint = (match["status_hint"] as? String) ?? hint
            }
            orch.addSubview(agentRow(boxW: boxW, y: ay, title: lab, sub: "\(typ) · \(hint)",
                                      id: wid, accent: PongTheme.magenta))
            ay -= 44
        }
        blocks.append(orch)
        total += aH + 14

        // —— Timeline (digested events) ——
        let digested = digestEvents(Array(events.suffix(10).reversed()))
        let tH: CGFloat = 40 + CGFloat(max(digested.count, 1)) * 36
        let time = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: tH))
        PongTheme.applyFloating(time)
        time.addSubview(PanelController.label("Recent flow",
            frame: NSRect(x: 16, y: tH - 28, width: 160, height: 18), bold: true, size: 13))
        if digested.isEmpty {
            time.addSubview(PanelController.label("No activity yet. When jobs run, steps show up here.",
                frame: NSRect(x: 16, y: 12, width: boxW - 32, height: 16), size: 11, secondary: true))
        } else {
            var ey = tH - 48
            for (i, line) in digested.enumerated() {
                let dot = NSView(frame: NSRect(x: 18, y: ey + 6, width: 8, height: 8))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = line.color.cgColor
                time.addSubview(dot)
                if i < digested.count - 1 {
                    let stem = NSView(frame: NSRect(x: 21, y: ey - 24, width: 2, height: 28))
                    stem.wantsLayer = true
                    stem.layer?.backgroundColor = PongTheme.border.cgColor
                    time.addSubview(stem)
                }
                time.addSubview(PanelController.label(line.text,
                    frame: NSRect(x: 36, y: ey, width: boxW - 52, height: 28), size: 11, secondary: false))
                ey -= 36
            }
        }
        blocks.append(time)
        total += tH + 20

        // Recently completed (if any)
        if !recentJobs.isEmpty {
            let rH: CGFloat = 36 + CGFloat(min(recentJobs.count, 4)) * 24
            let rec = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: rH))
            PongTheme.applyFloating(rec)
            rec.addSubview(PanelController.label("Recently finished",
                frame: NSRect(x: 16, y: rH - 26, width: 180, height: 16), bold: true, size: 12))
            var ry = rH - 44
            for j in recentJobs.prefix(4) {
                let st = (j["status"] as? String) ?? "done"
                let prev = (j["task_preview"] as? String) ?? ""
                rec.addSubview(PanelController.label("\(st) · \(prev)",
                    frame: NSRect(x: 16, y: ry, width: boxW - 32, height: 16), size: 10, secondary: true))
                ry -= 24
            }
            blocks.append(rec)
            total += rH + 14
        }

        let contentH = max(scroll.contentSize.height, total)
        body.setFrameSize(NSSize(width: boxW, height: contentH))
        var y = contentH - 8
        for b in blocks {
            y -= b.frame.height
            b.setFrameOrigin(NSPoint(x: 0, y: y))
            body.addSubview(b)
            y -= 14
        }
        window?.title = "Focus · \(display)"
    }

    // MARK: Digest helpers

    private struct StageInfo {
        let name: String
        let color: NSColor
        let summary: String
    }

    private func digestStage(openJobs: [[String: Any]], workers: [[String: Any]],
                             events: [[String: Any]], rejectStreak: Int) -> StageInfo {
        if rejectStreak >= 2 {
            return StageInfo(name: "human", color: PongTheme.orange,
                             summary: "Reject streak \(rejectStreak) — review claims or help the orchestrator.")
        }
        let statuses = openJobs.compactMap { $0["status"] as? String }
        if statuses.contains(where: { $0 == "human_takeover" }) {
            return StageInfo(name: "human", color: PongTheme.orange,
                             summary: "A worker is in human takeover — open that terminal.")
        }
        if statuses.contains(where: { $0 == "running" || $0 == "notified" }) {
            return StageInfo(name: "build", color: PongTheme.magenta,
                             summary: "Workers are building. Orchestrator waits on claims.")
        }
        if statuses.contains(where: { $0 == "queued" }) {
            return StageInfo(name: "assign", color: PongTheme.blue,
                             summary: "Jobs queued — waiting for workers to pick up.")
        }
        if events.contains(where: { ($0["type"] as? String) == "job.claim" || ($0["verdict"] as? String) != nil }) {
            return StageInfo(name: "verify", color: PongTheme.blue,
                             summary: "Recent claims/verdicts — orchestrator is verifying.")
        }
        return StageInfo(name: "plan", color: PongTheme.idle,
                         summary: "Idle. Orchestrator can plan the next slice of work.")
    }

    private func flowStory(stage: StageInfo, openCount: Int, workers: [[String: Any]], rejectStreak: Int) -> String {
        stage.summary
    }

    private struct PipeCell { let active: Bool; let caption: String; let color: NSColor }

    private func pipelineStages(openJobs: [[String: Any]], events: [[String: Any]], rejectStreak: Int) -> [PipeCell] {
        let statuses = Set(openJobs.compactMap { $0["status"] as? String })
        let hasOpen = !openJobs.isEmpty
        let building = statuses.contains("running") || statuses.contains("notified")
        let queued = statuses.contains("queued")
        let human = statuses.contains("human_takeover") || rejectStreak >= 2
        let verifying = events.contains { ($0["type"] as? String)?.contains("claim") == true || ($0["type"] as? String) == "verdict" }
        let doneRecently = events.contains { ($0["verdict"] as? String) == "accept" || ($0["status"] as? String) == "done" }

        return [
            PipeCell(active: !hasOpen && !verifying, caption: human ? "—" : (hasOpen ? "ok" : "now"), color: PongTheme.blue),
            PipeCell(active: queued, caption: queued ? "\(openJobs.count)" : "—", color: PongTheme.blue),
            PipeCell(active: building || human, caption: human ? "you" : (building ? "live" : "—"), color: human ? PongTheme.orange : PongTheme.magenta),
            PipeCell(active: verifying && !building, caption: verifying ? "check" : "—", color: PongTheme.blue),
            PipeCell(active: doneRecently && !hasOpen, caption: doneRecently ? "ok" : "—", color: PongTheme.live),
        ]
    }

    private struct DigestLine { let text: String; let color: NSColor }

    private func digestEvents(_ events: [[String: Any]]) -> [DigestLine] {
        events.compactMap { e -> DigestLine? in
            guard let t = e["type"] as? String, !t.isEmpty else { return nil }
            switch t {
            case "job.created":
                return DigestLine(text: "Job created · \(e["worker"] as? String ?? "worker")", color: PongTheme.blue)
            case "job.dispatch":
                return DigestLine(text: "Dispatched to worker · \(e["status"] as? String ?? "")", color: PongTheme.blue)
            case "job.status":
                let st = e["status"] as? String ?? "?"
                let sk = PongTheme.statusKind(st)
                return DigestLine(text: "Status → \(st)", color: sk.color)
            case "job.claim":
                return DigestLine(text: "Worker filed a claim — ready to verify", color: PongTheme.magenta)
            case "verdict":
                let v = e["verdict"] as? String ?? "?"
                let c: NSColor = v == "accept" ? PongTheme.live : (v == "reject" ? PongTheme.orange : PongTheme.danger)
                return DigestLine(text: "Verdict: \(v)", color: c)
            default:
                return DigestLine(text: t, color: PongTheme.textSecondary)
            }
        }
    }

    private func agentRow(boxW: CGFloat, y: CGFloat, title: String, sub: String, id: String, accent: NSColor) -> NSView {
        let row = NSView(frame: NSRect(x: 12, y: y, width: boxW - 24, height: 38))
        row.wantsLayer = true
        row.layer?.backgroundColor = PongTheme.bgInput.cgColor
        row.layer?.cornerRadius = 10
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 38))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = accent.cgColor
        row.addSubview(bar)
        row.addSubview(PanelController.label(title,
            frame: NSRect(x: 14, y: 16, width: 160, height: 16), bold: true, size: 12))
        row.addSubview(PanelController.label(sub,
            frame: NSRect(x: 14, y: 2, width: 200, height: 12), size: 9, secondary: true))
        let b = btn("Terminal", #selector(openAgent(_:)), filled: false)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.frame = NSRect(x: boxW - 118, y: 7, width: 78, height: 24)
        row.addSubview(b)
        return row
    }

    private func pill(_ text: String, color: NSColor, soft: NSColor) -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        v.layer?.backgroundColor = soft.cgColor
        let l = NSTextField(labelWithString: text)
        l.font = PongTheme.font(9, weight: .bold)
        l.textColor = color
        l.alignment = .center
        l.isBordered = false
        l.backgroundColor = .clear
        l.frame = NSRect(x: 0, y: 1, width: 72, height: 16)
        v.addSubview(l)
        return v
    }

    private func btn(_ title: String, _ sel: Selector, filled: Bool) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        if filled {
            b.layer?.backgroundColor = PongTheme.blue.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white, .font: PongTheme.font(11, weight: .semibold),
            ])
        } else {
            b.layer?.backgroundColor = PongTheme.bgHover.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.border.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textPrimary, .font: PongTheme.font(10, weight: .medium),
            ])
        }
        b.target = self
        b.action = sel
        return b
    }

    @objc private func openOrch() {
        DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(self.session) }
    }

    @objc private func openAgent(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id == "orch" {
            openOrch()
        } else {
            Workers.frontWorker(pair: session, workerId: id)
        }
    }

    @objc private func refreshPressed() { reload() }
}
