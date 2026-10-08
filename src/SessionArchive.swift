import AppKit
import Foundation

// MARK: - Session vault (continuity archives)

/// Durable **saved sessions** (story/continuity) — not the same as Saved teams (roster templates).
/// On-disk layout is owned by `python/pong/session_archive.py` under `~/.pong/session-archive/`.
enum SessionArchive {
    struct Entry: Equatable {
        var id: String
        var title: String
        var sourceSession: String
        var displayName: String
        var projectRoot: String
        var teamBrief: String
        var createdAt: TimeInterval
        var updatedAt: TimeInterval
        var recapPath: String

        /// Picker / list label: always surface team name when title is custom.
        var rowLabel: String {
            let team = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if team.isEmpty { return title }
            if title.range(of: team, options: .caseInsensitive) != nil {
                return title
            }
            return "\(title) · \(team)"
        }
    }

    /// Prefer installed control plane (`~/bin/pong` → `~/.pong/lib`), then app-bundle Resources.
    /// Shared with ReviewBarSetup: the app must be able to reach the control
    /// plane from its own bundle when ~/bin/pong is not installed.
    static func pongPrefix() -> String {
        let home = NSHomeDirectory()
        // App bundle path (CyberPong.app Resources/python) if present
        let bundlePy: String = {
            if let res = Bundle.main.resourcePath {
                let p = res + "/python"
                if FileManager.default.fileExists(atPath: p + "/pong/session_archive.py") {
                    return p
                }
            }
            return ""
        }()
        var pyParts = ["\(home)/.pong/lib"]
        if !bundlePy.isEmpty { pyParts.append(bundlePy) }
        let py = pyParts.joined(separator: ":")
        return """
        export PATH="\(home)/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        export PYTHONPATH="\(py)${PYTHONPATH:+:$PYTHONPATH}"
        """
    }

    /// Run continuity CLI with installed lib first (no repo PYTHONPATH required).
    private static func runPong(_ args: String) -> String {
        Pong.sh("""
            \(pongPrefix())
            if command -v pong >/dev/null 2>&1; then
              pong \(args)
            else
              python3 -m pong.cli.main \(args)
            fi
            """)
    }

    private static func runJSON(_ args: String) -> [[String: Any]] {
        let out = runPong(args)
        guard let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    private static func runObject(_ args: String) -> [String: Any] {
        let out = runPong(args)
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// Load continuity archives. Optional team scope (OR when both set):
    /// - `displayName` → CLI `--team` (case-insensitive on meta.display_name)
    /// - `sourceSession` → CLI `-s` (exact meta.source_session)
    /// Rename edge: prefer both from live context so session id still matches after display rename.
    static func loadAll(displayName: String? = nil, sourceSession: String? = nil) -> [Entry] {
        var parts: [String] = []
        let sess = (sourceSession ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sess.isEmpty {
            parts.append("-s \(shellQuote(sess))")
        }
        parts.append("continuity list --json")
        let team = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !team.isEmpty {
            parts.append("--team \(shellQuote(team))")
        }
        return runJSON(parts.joined(separator: " ")).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Entry(
                id: id,
                title: (row["title"] as? String) ?? id,
                sourceSession: (row["source_session"] as? String) ?? "",
                displayName: (row["display_name"] as? String) ?? "",
                projectRoot: (row["project_root"] as? String) ?? "",
                teamBrief: (row["team_brief"] as? String) ?? "",
                createdAt: (row["created_at"] as? Double) ?? 0,
                updatedAt: (row["updated_at"] as? Double) ?? 0,
                recapPath: Pong.stateDir + "/session-archive/\(id)/recap.md"
            )
        }
    }

    /// Compress a live pair into the vault. Does **not** kill terminals.
    @discardableResult
    static func saveFromLive(session: String, title: String? = nil) -> (ok: Bool, id: String, message: String) {
        let sess = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sess.isEmpty else { return (false, "", "No session") }
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleArg = t.isEmpty ? "" : " --title \(shellQuote(t))"
        // Global -s/--session must precede the subcommand
        let obj = runObject("-s \(shellQuote(sess)) continuity save\(titleArg) --json")
        guard let id = obj["id"] as? String, !id.isEmpty else {
            return (false, "", "Compress failed — is the pong CLI available?")
        }
        let path = (obj["recap_path"] as? String) ?? ""
        Pong.log("session archive save id=\(id) session=\(sess) path=\(path)")
        return (true, id, path)
    }

    static func loadRecap(id: String) -> String {
        let aid = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aid.isEmpty else { return "" }
        return runPong("continuity show \(shellQuote(aid)) --recap-only")
    }

    static func delete(id: String) {
        _ = runPong("continuity delete \(shellQuote(id))")
    }

    static func rename(id: String, title: String) {
        _ = runPong("continuity rename \(shellQuote(id)) --title \(shellQuote(title))")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Continuity ops (re-prime / inject)

/// Fresh agent context with continuity story — same live pair (or inject into another).
enum SessionContinuity {
    /// After spawn, kickoff may need an archive id once panes exist.
    private static var pendingArchiveBySession: [String: String] = [:]
    private static let lock = NSLock()

    static func setPendingArchive(session: String, archiveId: String) {
        lock.lock()
        pendingArchiveBySession[session] = archiveId
        lock.unlock()
    }

    static func takePendingArchive(session: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let v = pendingArchiveBySession[session]
        pendingArchiveBySession[session] = nil
        return v
    }

    /// Save compress + respawn all seats + inject recap + primes. Same pair id.
    /// Call off main thread.
    static func newSessionWithRecap(session: String, title: String? = nil) -> (ok: Bool, message: String) {
        let save = SessionArchive.saveFromLive(session: session, title: title)
        guard save.ok else { return (false, save.message) }
        return injectArchive(session: session, archiveId: save.id, respawn: true)
    }

    /// Inject an existing archive into a live session (optional respawn).
    static func injectArchive(
        session: String,
        archiveId: String,
        respawn: Bool
    ) -> (ok: Bool, message: String) {
        let recap = SessionArchive.loadRecap(id: archiveId)
        guard !recap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "Archive recap empty or missing")
        }

        // Bump continuity generation on pair state (does not rename session id)
        PairState.mutate(session) { entry in
            let n = (entry["continuity_generation"] as? Int) ?? 0
            entry["continuity_generation"] = n + 1
            entry["continuity_archive_id"] = archiveId
            entry["updated"] = Date().timeIntervalSince1970
        }

        if respawn {
            let seats = seatIds(session: session)
            for sid in seats {
                _ = respawnSeat(session: session, seatId: sid)
            }
            // Wait for TUIs
            for sid in seats {
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 0.4)
                    if ConductorKickoff.seatLooksReady(session: session, seatId: sid) { break }
                }
            }
        }

        let ctx = ConductorKickoff.contextFromPairState(session: session)
        let boot = ConductorKickoff.buildPrompt(ctx, continuityRecap: recap)
        let okC = ConductorKickoff.pasteIntoConductor(session: session, text: boot)
        Thread.sleep(forTimeInterval: 0.35)

        var workerOk = 0
        for seat in ctx.roster {
            let prime = ConductorKickoff.buildWorkerPrimePrompt(
                session: session, seatId: seat.id, continuityRecap: recap
            )
            if ConductorKickoff.pasteIntoSeat(session: session, seatId: seat.id, text: prime) {
                workerOk += 1
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Mirror recap into session dir for human browsing
        let dir = Pong.stateDir + "/sessions/\(session)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? recap.write(
            toFile: dir + "/continuity-recap.md",
            atomically: true,
            encoding: .utf8
        )

        Pong.log(
            "continuity inject session=\(session) archive=\(archiveId) respawn=\(respawn) c1=\(okC) workers=\(workerOk)/\(ctx.roster.count)"
        )
        let msg = okC
            ? "Re-primed \(session) with archive \(archiveId) (workers \(workerOk)/\(ctx.roster.count))"
            : "Archive loaded but conductor paste may have failed — check Terminal"
        return (okC || workerOk > 0, msg)
    }

    private static func seatIds(session: String) -> [String] {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        var ids = ["c1"]
        for w in Workers.list(from: entry) {
            if let id = w["id"] as? String, !id.isEmpty { ids.append(id) }
        }
        return ids
    }

    /// Respawn one seat pane with the same CLI (clears model context, keeps tmux window).
    @discardableResult
    static func respawnSeat(session: String, seatId: String) -> Bool {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let pathExport = TerminalTheme.panePathExport()
        let token = Isolation.ensureToken(session: session)
        let target = ConductorKickoff.seatTarget(session: session, seatId: seatId)

        let launch: String
        let banner: String
        let tmuxIdx: Int
        if seatId == "c1" {
            let cond = entry["conductor"] as? [String: Any] ?? [:]
            let cmd = ((cond["cmd"] as? String) ?? (cond["type"] as? String) ?? "grok")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            launch = cmd.isEmpty ? "grok" : cmd
            let lab = (cond["label"] as? String) ?? "Conductor"
            banner = "CONDUCTOR · \(lab) · \(session):0 (new session + recap)"
            tmuxIdx = 0
        } else {
            let ws = Workers.list(from: entry)
            guard let w = ws.first(where: { ($0["id"] as? String) == seatId }) else { return false }
            let cmd = ((w["cmd"] as? String) ?? (w["type"] as? String) ?? "claude")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            launch = cmd.isEmpty ? "claude" : cmd
            let lab = (w["label"] as? String) ?? seatId
            tmuxIdx = (w["tmux_index"] as? Int) ?? 1
            banner = "WORKER · \(lab) · \(session):\(tmuxIdx) (new session + recap)"
        }

        let safeCmd = launch.replacingOccurrences(of: "'", with: "'\\''")
        var parts: [String] = [
            pathExport,
            "export PONG_SESSION=\(session)",
            "export HERMES_PONG_SESSION=\(session)",
            "export PONG_SEAT=\(seatId)",
        ]
        if seatId == "c1" {
            parts.append("export PONG_ROLE=conductor")
            parts.append("export HERMES_PONG_ROLE=orchestra")
        }
        if !token.isEmpty { parts.append("export PONG_TOKEN=\"$(cat '" + Pong.stateDir + "/sessions/\(session)/token' 2>/dev/null)\"") }
        parts.append("printf \"\\n  \(banner)\\n\\n\"")
        parts.append("exec \(safeCmd)")
        let shellLine = TerminalTheme.joinShell(parts)
        let q = shellLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let out = Pong.sh("""
            tmux has-session -t '\(session)' 2>/dev/null || exit 1
            tmux respawn-pane -k -t '\(target)' \"\(q)\" 2>/dev/null || \
              (tmux send-keys -t '\(target)' C-c; sleep 0.2; tmux send-keys -t '\(target)' -l '\(shellLine.replacingOccurrences(of: "'", with: "'\\''"))'; sleep 0.05; tmux send-keys -t '\(target)' Enter)
            echo OK
            """)
        if out.contains("OK") {
            _ = Isolation.registerPane(
                session: session,
                workerId: seatId,
                tmuxTarget: "\(session):\(tmuxIdx)",
                startCommand: launch
            )
        }
        return out.contains("OK")
    }
}

// MARK: - Continuity UI helpers (confirm dialogs)

enum SessionContinuityUI {
    /// Save session (compress) without killing.
    static func confirmSaveSession(session: String, displayName: String, onDone: (() -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Save a recap of “\(displayName)”?"
        a.informativeText = "A recap keeps the goals, decisions, what is done and what is next, so the team can pick up later. Nothing stops."
        a.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        field.stringValue = "\(displayName) · \(stamp)"
        field.placeholderString = "Recap title"
        a.accessoryView = field
        a.addButton(withTitle: "Save recap")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        PongLoadingOverlay.show(on: NSApp.keyWindow ?? NSApp.mainWindow, message: "Writing the recap…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SessionArchive.saveFromLive(session: session, title: title.isEmpty ? nil : title)
            DispatchQueue.main.async {
                // Always clear spinner (success or failure)
                PongLoadingOverlay.hide()
                if result.ok {
                    Toast.show("Recap saved.")
                } else {
                    Toast.show("The recap wasn't saved. " + String(result.message.prefix(120)), warn: true)
                }
                onDone?()
            }
        }
    }

    /// Compress → archive → re-prime same pair (fresh agent context, keep session id).
    static func confirmNewSessionWithRecap(session: String, displayName: String, onDone: (() -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Give “\(displayName)” a fresh start?"
        a.informativeText = "Its AIs restart with an empty memory and read a recap of the work so far. Their terminals stay open."
        a.alertStyle = .warning
        a.addButton(withTitle: "Fresh start")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        PongLoadingOverlay.show(on: NSApp.keyWindow ?? NSApp.mainWindow, message: "Writing the recap and restarting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SessionContinuity.newSessionWithRecap(session: session)
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                Toast.show(result.ok ? "Fresh start done: the team read its recap." : "The fresh start didn't finish. " + String(result.message.prefix(120)),
                           warn: !result.ok)
                PanelController.shared.refreshUI()
                onDone?()
            }
        }
    }

    /// Pick an archive (nil = cancel, empty string = no continuity).
    /// When `displayName` and/or `sourceSession` are set, only that team's archives appear
    /// (OR match — see `SessionArchive.loadAll` / CLI `archive_matches_team`).
    static func pickArchive(
        allowNone: Bool,
        message: String,
        displayName: String? = nil,
        sourceSession: String? = nil
    ) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let teamHint = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sessHint = (sourceSession ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = !teamHint.isEmpty || !sessHint.isEmpty
        let archives = SessionArchive.loadAll(
            displayName: teamHint.isEmpty ? nil : teamHint,
            sourceSession: sessHint.isEmpty ? nil : sessHint
        )
        if archives.isEmpty {
            let teamLabel = !teamHint.isEmpty ? teamHint : (!sessHint.isEmpty ? sessHint : "this team")
            if allowNone {
                let a = NSAlert()
                a.messageText = scoped ? "No recaps for \(teamLabel) yet" : "No recaps yet"
                a.informativeText = "Save one from a running team: its lead's menu › Save recap."
                a.addButton(withTitle: "Continue without")
                a.addButton(withTitle: "Cancel")
                return a.runModal() == .alertFirstButtonReturn ? "" : nil
            }
            let a = NSAlert()
            a.messageText = scoped ? "No recaps for \(teamLabel) yet" : "No recaps yet"
            a.informativeText = "Save one from a running team: its lead's menu › Save recap."
            a.addButton(withTitle: "OK")
            a.runModal()
            return nil
        }
        let a = NSAlert()
        a.messageText = message
        a.informativeText = scoped
            ? "Recaps of “\(!teamHint.isEmpty ? teamHint : sessHint)”: the goals, decisions and what is next."
            : "A recap holds a team's goals, decisions and what is next."
        if allowNone {
            a.addButton(withTitle: "Start fresh")
        }
        for e in archives.prefix(12) {
            let src = e.sourceSession.isEmpty ? "" : " · \(e.sourceSession)"
            a.addButton(withTitle: "\(e.rowLabel)\(src)")
        }
        a.addButton(withTitle: "Cancel")
        let resp = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        var idx = resp.rawValue - first
        if allowNone {
            if idx == 0 { return "" }
            idx -= 1
        }
        if idx >= 0 && idx < min(12, archives.count) {
            return archives[idx].id
        }
        return nil
    }

    /// Attach archive to a live pair (inject, optional respawn).
    static func confirmAttachToLive(archiveId: String) {
        let pairs = PairState.listPairs()
        if pairs.isEmpty {
            let a = NSAlert()
            a.messageText = "No live teams"
            a.informativeText = "Spawn a team first, then attach this continuity package."
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = "Use continuity on live team…"
        a.informativeText = "Pick a running pair. Agents will re-prime with this recap (optional fresh TUIs)."
        for p in pairs {
            let entry = PairState.loadPairsDb()[p] as? [String: Any] ?? [:]
            let name = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            a.addButton(withTitle: (name?.isEmpty == false ? name! : p) + "  (\(p))")
        }
        a.addButton(withTitle: "Cancel")
        let resp = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = resp.rawValue - first
        guard idx >= 0, idx < pairs.count else { return }
        let session = pairs[idx]

        let mode = NSAlert()
        mode.messageText = "How to apply?"
        mode.informativeText =
            "Fresh agent context restarts TUIs in the same pair (recommended).\n" +
            "Inject only pastes the recap into current agents."
        mode.addButton(withTitle: "Fresh + recap")
        mode.addButton(withTitle: "Inject only")
        mode.addButton(withTitle: "Cancel")
        let mr = mode.runModal()
        if mr == .alertThirdButtonReturn { return }
        let respawn = mr == .alertFirstButtonReturn

        PongLoadingOverlay.show(on: NSApp.keyWindow ?? NSApp.mainWindow, message: "Applying continuity…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SessionContinuity.injectArchive(
                session: session, archiveId: archiveId, respawn: respawn
            )
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                let done = NSAlert()
                done.messageText = result.ok ? "Continuity applied" : "Apply incomplete"
                done.informativeText = result.message
                done.addButton(withTitle: "OK")
                done.runModal()
                PanelController.shared.refreshUI()
            }
        }
    }
}

// MARK: - Saved sessions manager panel

final class SessionsManagerPanel: NSObject {
    static let shared = SessionsManagerPanel()
    private var window: NSWindow?
    private var scrollView: NSScrollView!
    private var listBox: FlippedView!
    private var onChange: (() -> Void)?
    private let winW: CGFloat = 480
    private let winH: CGFloat = 540
    private let footerH: CGFloat = 52
    private let headerH: CGFloat = 78

    func show(onChange: (() -> Void)? = nil) {
        self.onChange = onChange
        if window == nil { build() }
        rebuildList()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func build() {
        let W = winW, H = winH
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Saved sessions"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        let title = NSTextField(labelWithString: "Saved sessions")
        title.font = .boldSystemFont(ofSize: 16)
        title.textColor = .white
        title.frame = NSRect(x: 20, y: H - 40, width: 280, height: 22)
        content.addSubview(title)

        let hint = NSTextField(wrappingLabelWithString:
            "Continuity packages (story), not roster templates. Use on a live team or when spawning.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        hint.frame = NSRect(x: 20, y: H - 72, width: W - 40, height: 32)
        content.addSubview(hint)

        let scrollY = footerH
        let scrollH = H - headerH - footerH
        scrollView = NSScrollView(frame: NSRect(x: 16, y: scrollY, width: W - 32, height: scrollH))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        listBox = FlippedView(frame: NSRect(x: 0, y: 0, width: W - 32, height: scrollH))
        scrollView.documentView = listBox
        content.addSubview(scrollView)

        let footer = NSView(frame: NSRect(x: 0, y: 0, width: W, height: footerH))
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor
        let close = NSButton(frame: NSRect(x: W - 100, y: 12, width: 80, height: 30))
        close.title = "Close"
        close.bezelStyle = .rounded
        close.target = self
        close.action = #selector(closePressed)
        footer.addSubview(close)
        content.addSubview(footer)

        win.contentView = content
        window = win
    }

    private func rebuildList() {
        listBox.subviews.forEach { $0.removeFromSuperview() }
        let entries = SessionArchive.loadAll()
        let rowH: CGFloat = 64
        let gap: CGFloat = 8
        let pad: CGFloat = 8
        let width = max(scrollView.contentSize.width, winW - 32)

        if entries.isEmpty {
            let h = max(scrollView.contentSize.height, 200)
            listBox.setFrameSize(NSSize(width: width, height: h))
            let empty = NSTextField(wrappingLabelWithString:
                "No saved sessions yet.\n\nOn a live team: conductor card → Save session (compress).\n\nSaved teams (Show Teams) are roster templates — different from continuity.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
            empty.alignment = .center
            empty.maximumNumberOfLines = 8
            empty.frame = NSRect(x: 16, y: 40, width: width - 32, height: 120)
            listBox.addSubview(empty)
            return
        }

        let contentH = pad + CGFloat(entries.count) * (rowH + gap) + pad
        listBox.setFrameSize(NSSize(width: width, height: max(contentH, scrollView.contentSize.height)))

        var y = pad
        for e in entries {
            let row = NSView(frame: NSRect(x: 4, y: y, width: width - 8, height: rowH))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
            row.layer?.cornerRadius = 8

            let name = NSTextField(labelWithString: e.rowLabel)
            name.font = .boldSystemFont(ofSize: 12)
            name.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
            name.frame = NSRect(x: 10, y: 34, width: width - 200, height: 18)
            row.addSubview(name)

            let teamBit = e.displayName.isEmpty ? "?" : e.displayName
            let fromBit = e.sourceSession.isEmpty ? "?" : e.sourceSession
            let sub = NSTextField(labelWithString: "team \(teamBit) · from \(fromBit) · \(e.id)")
            sub.font = .systemFont(ofSize: 10)
            sub.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
            sub.frame = NSRect(x: 10, y: 14, width: width - 200, height: 14)
            row.addSubview(sub)

            row.addSubview(smallBtn("Use…", #selector(usePressed(_:)),
                                    NSRect(x: width - 168, y: 18, width: 56, height: 26), e.id))
            row.addSubview(smallBtn("Delete", #selector(deletePressed(_:)),
                                    NSRect(x: width - 100, y: 18, width: 64, height: 26), e.id))
            listBox.addSubview(row)
            y += rowH + gap
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func smallBtn(_ title: String, _ sel: Selector, _ frame: NSRect, _ id: String) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        b.target = self
        b.action = sel
        b.identifier = NSUserInterfaceItemIdentifier(id)
        return b
    }

    @objc private func usePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        SessionContinuityUI.confirmAttachToLive(archiveId: id)
        onChange?()
    }

    @objc private func deletePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let a = NSAlert()
        a.messageText = "Delete saved session?"
        a.informativeText = "Removes the continuity archive only. Live teams are untouched.\n\n\(id)"
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SessionArchive.delete(id: id)
        rebuildList()
        onChange?()
    }

    @objc private func closePressed() {
        window?.orderOut(nil)
        onChange?()
    }
}
