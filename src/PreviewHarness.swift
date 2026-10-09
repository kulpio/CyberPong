import AppKit
import SceneKit

/// A development preview: `PONG_PREVIEW=1` runs the app with none of its side effects (no
/// island, no schedules firing, no menu bar item, no Dock icon, no window recovery), behind
/// every other window, and `PONG_PREVIEW_STEPS` drives it, e.g.
///
///     size:960x680;go:home;wait:3;shot:home;go:graphs;wait:3;shot:graphs;quit
///
/// Shots are PNGs of the app's own window (no screen-recording grant needed) in
/// `PONG_PREVIEW_SHOTS`. It only navigates: it never presses an answer or a stop.
///
/// Its child processes are kept off the live setup (AppDelegate.isolatePreviewChildren):
/// `PONG_HOME` is `PONG_PREVIEW_STATE` when that is set, tmux gets an empty server of its own,
/// and `quit` leaves the live notch panel alone (a preview never touches it).
///
/// The notch panel (2.1, spec §13.2): with `PONG_PREVIEW_ISLAND=1` it is drawn on a stand-in screen
/// (a 14-inch MacBook Pro, 1512 × 982 pt with a 185 × 32 pt notch, or 1920 × 1080 with none) far off
/// every display, behind every window, and photographed from its layers. Its steps:
///
///     island:<scene>          quiet, working1, working3, needsyou, peek, limit5h, limitweek, runneroff,
///                             teamstopped, finished, problem, engineoff, nonotch (made-up graphs and teams)
///     islandopen:graphs|teams islandclose   islandfocus:<n>   islandsteps:<graph name>
///     islandscreen:nonotch|notch
///     shotisland:<name>       the panel over a drawn slice of menu bar, as <name>.png
///     islandcheck:<name>      every view's frame and string, as <name>.json (§13.3)
enum UIPreview {
    static let env = ProcessInfo.processInfo.environment
    static let isOn = env["PONG_PREVIEW"] == "1"
    static var shotDir: String { env["PONG_PREVIEW_SHOTS"] ?? NSTemporaryDirectory() }

    static func runSteps() {
        let steps = (env["PONG_PREVIEW_STEPS"] ?? "wait:3;shot:window;quit")
            .split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
        run(steps[...])
    }

    private static func run(_ steps: ArraySlice<String>) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let cmd = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        var delay: Double = 0.4
        switch cmd {
        case "wait": delay = Double(arg) ?? 1
        case "size": PanelController.shared.previewResize(arg)
        case "go": PanelController.shared.previewNavigate(arg)
        case "shot": shot(arg.isEmpty ? "window" : arg)
        case "shotwin":
            // shotwin:Settings=settings — another window by its title
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if let w = NSApp.windows.first(where: { $0.title == p[0] && $0.isVisible }) { shot(p.count > 1 ? p[1] : p[0], window: w) }
        case "dump": dump()
        case "parts": drawParts()
        // the notch panel on its stand-in screen (PONG_PREVIEW_ISLAND=1; never at the real notch)
        case "island": IslandPreviewScenes.load(arg)
        case "islandopen": IslandController.shared.previewOpen(arg == "teams" ? .teams : .graphs)
        case "islandclose": IslandController.shared.previewClose()
        case "islandfocus": IslandController.shared.previewFocus(Int(arg) ?? 1)
        case "islandsteps": IslandController.shared.previewSteps(arg)
        case "islandscreen": IslandController.shared.previewSetNotch(arg != "nonotch")
        case "shotisland":
            try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
            IslandController.shared.previewShot((shotDir as NSString).appendingPathComponent((arg.isEmpty ? "island" : arg) + ".png"))
        case "islandcheck":
            try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
            IslandController.shared.previewCheck((shotDir as NSString).appendingPathComponent((arg.isEmpty ? "island" : arg) + ".json"))
        case "quit":
            NSApp.terminate(nil)
            return
        default: Pong.log("preview: unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(rest) }
    }

    /// The window's views drawn into a bitmap: the layer tree (fills, corners, text), with each
    /// SceneKit view's own snapshot laid over it. No screen-recording grant is needed.
    static func shot(_ name: String, window: NSWindow? = nil) {
        let dir = shotDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(name + ".png")
        guard let win = window ?? PanelController.shared.previewWindow ?? NSApp.appKeyWindow,
              let view = win.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        PongColor.base.setFill()
        NSRect(origin: .zero, size: size).fill()
        // the scroll edge effect (a backdrop layer) can't be drawn offscreen: leave it out of the shot
        func backdrops(_ v: NSView) -> [NSView] {
            let name = String(describing: type(of: v))
            let mine = name.contains("Backdrop") || name.contains("Pocket")
                || (v.layer.map { String(describing: type(of: $0)).contains("Backdrop") } ?? false)
            return (mine ? [v] : []) + v.subviews.flatMap { backdrops($0) }
        }
        let hidden = backdrops(view).filter { !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        defer { hidden.forEach { $0.isHidden = false } }
        // SceneKit draws with Metal and its layer renders empty: slip its own snapshot in under its
        // subviews (the deck's flat layer, its buttons) so everything above it still draws above it
        func scenes(_ v: NSView) -> [SCNView] { (v as? SCNView).map { [$0] } ?? v.subviews.flatMap { scenes($0) } }
        var stand: [CALayer] = []
        for sv in scenes(view) where !sv.isHiddenOrHasHiddenAncestor && sv.bounds.width > 10 {
            guard let host = sv.layer else { continue }
            let l = CALayer()
            l.frame = host.bounds
            l.contents = sv.snapshot()
            l.contentsGravity = .resize
            host.insertSublayer(l, at: 0)
            stand.append(l)
        }
        if let layer = view.layer {
            layer.render(in: cg)
        } else {
            view.displayIgnoringOpacity(view.bounds, in: ctx)
        }
        stand.forEach { $0.removeFromSuperlayer() }
        // child windows (⌘K, sheets) at their place over the window
        for child in (win.childWindows ?? []) + [win.attachedSheet].compactMap({ $0 }) {
            guard let cv = child.contentView, let cl = cv.layer else { continue }
            let origin = NSPoint(x: child.frame.minX - win.frame.minX, y: child.frame.minY - win.frame.minY)
            cg.saveGState()
            cg.translateBy(x: origin.x, y: origin.y)
            if cv.isFlipped {  // a flipped root draws upside down through render(in:)
                cg.translateBy(x: 0, y: cv.bounds.height)
                cg.scaleBy(x: 1, y: -1)
            }
            cl.render(in: cg)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            Pong.log("preview: shot \(path)")
        }
    }
}

extension UIPreview {
    /// Each visible view under the stage drawn on its own, to find what paints over the page.
    static func drawParts() {
        guard let root = PanelController.shared.previewWindow?.contentView else { return }
        var i = 0
        func walk(_ v: NSView, _ d: Int) {
            guard d < 6, !v.isHidden, v.bounds.width > 20, v.bounds.height > 20 else { return }
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let n = String(format: "part-%02d-d%d-%@.png", i, d, String(describing: type(of: v)))
                    try? data.write(to: URL(fileURLWithPath: (shotDir as NSString).appendingPathComponent(n)))
                    i += 1
                }
            }
            for c in v.subviews { walk(c, d + 1) }
        }
        if let stage = root.subviews.first(where: { $0.frame.minX > 50 && $0.frame.height > 300 }) { walk(stage, 0) }
    }

    /// The view tree with frames, to the log.
    static func dump() {
        guard let v = PanelController.shared.previewWindow?.contentView else { return }
        var out: [String] = []
        func walk(_ v: NSView, _ d: Int) {
            guard d < 7 else { return }
            let bg = v.layer?.backgroundColor.map { NSColor(cgColor: $0)?.description ?? "?" } ?? "-"
            out.append(String(repeating: "  ", count: d) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) layer=\(v.layer.map { String(describing: type(of: $0)) } ?? "none") bg=\(bg.prefix(40))")
            for c in v.subviews { walk(c, d + 1) }
        }
        walk(v, 0)
        try? out.joined(separator: "\n").write(toFile: (shotDir as NSString).appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
    }
}

extension PanelController {
    var previewWindow: NSWindow? { NSApp.windows.first { $0.contentView?.subviews.contains { $0 is SidebarView } == true } }

    func previewResize(_ arg: String) {
        let p = arg.lowercased().split(separator: "x").compactMap { Double($0) }
        guard p.count == 2, let win = previewWindow else { return }
        var f = win.frame
        f.size = NSSize(width: p[0], height: p[1])
        win.setFrame(f, display: true)
    }

    func previewNavigate(_ arg: String) {
        let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "home": goArea(.home)
        case "chats": goArea(.chats)
        case "graphs": goArea(.graphs)
        case "teams": goArea(.teams)
        case "schedules": goArea(.schedules)
        case "team": if parts.count > 1 { openTeam(parts[1]) }
        case "graph": if parts.count > 1 { goArea(.graphs); previewOpenGraph(parts[1]) }
        case "chat": if parts.count > 1 { goArea(.chats); previewOpenChat(parts[1]) }
        case "diagnostics": goDiagnostics()
        case "setup": goSetup()
        case "palette": openPalette()
        case "newgraph": newGraph()
        case "sidebar": toggleSidebar()
        case "tab": previewGraphTab(Int(parts.count > 1 ? parts[1] : "0") ?? 0)
        case "node": if parts.count > 1 { previewSelectNode(parts[1]) }
        case "settings": SettingsWindow.shared.show(parts.count > 1 ? SettingsWindow.Pane(rawValue: Int(parts[1]) ?? 0) : nil)
        // firstrun=<0-6>: the setup sheet on that step. A doctor.json in PONG_PREVIEW_STATE is
        // its made-up `pong doctor`; without one it asks the engine on PONG_HOME.
        case "firstrun": FirstRunSetup.present(force: true, step: Int(parts.count > 1 ? parts[1] : "0") ?? 0, on: previewWindow)
        case "guide": AppAIChatBubble.shared.previewOpen()
        case "newteam": NewTeamSheet.present(on: previewWindow)
        case "layout": if parts.count > 1 { FlowDesignSheetController.shared.show(session: parts[1], seats: []) {} }
        case "conversation": if parts.count > 1 { TeamConversationSheet.present(session: parts[1], on: previewWindow) }
        case "schedule":
            // schedule=<team> opens New schedule on it; schedule=<team>/<id> edits that one
            let ref = (parts.count > 1 ? parts[1] : "").split(separator: "/").map(String.init)
            if let team = ref.first {
                let job = ref.count > 1 ? CronSchedule.load(session: team).first { $0.id == ref[1] } : nil
                goArea(.schedules)
                ScheduleSheet.present(team: team, job: job, on: previewWindow) {}
            }
        case "activity": previewToggleActivity()
        default: Pong.log("preview: unknown page \(arg)")
        }
    }
}

// MARK: - The notch panel's made-up scenes (spec §13.2)

/// Scenes for the notch panel's preview, built from the feed's own shapes (the dictionaries
/// `pong graph list --json` sends), so the panel reads them exactly as it reads the real feed. Every
/// graph, team and file name is made up; the files the questions point at are written to a temporary
/// folder so the cards can show them.
enum IslandPreviewScenes {
    static func load(_ name: String) {
        let now = Date().timeIntervalSince1970
        let s = Builder(now: now)
        let island = IslandController.shared
        switch name {
        case "quiet": island.previewScene(s.input([s.finished1(ago: 3 * 3600)]))
        case "working1": island.previewScene(s.input([s.checkout()]))
        case "working3": island.previewScene(s.input(s.working3))
        case "needsyou", "nonotch":
            if name == "nonotch" { island.previewSetNotch(false) }
            island.previewScene(s.input(s.working3 + [s.pricing(), s.release()], asks: [s.launchAsk()]))
        case "peek":
            // a question arrives: the panel opens a little with it
            island.previewScene(s.input(s.working3 + [s.pricing(), s.release()], asks: [s.launchAsk()]),
                                before: s.input(s.working3 + [s.pricing()], asks: [s.launchAsk()]))
        case "limit5h":
            var l = s.input([s.checkout(limit: true), s.onboarding(limit: true)])
            l.limits = GLimits(["state": "paused_5h", "until": now + 47 * 60, "paused": [["session": "team-a"], ["session": "team-b"]],
                                "usage": ["session_pct": 100, "week_pct": 62, "read_at": now - 60]])
            island.previewScene(l)
        case "limitweek":
            var l = s.input([s.research(), s.checkout(limit: true, week: true), s.onboarding(limit: true, week: true)])
            l.limits = GLimits(["state": "paused_week", "until": now + 3 * 86_400, "paused": [["session": "team-a"], ["session": "team-b"]],
                                "usage": ["session_pct": 40, "week_pct": 97, "read_at": now - 60]])
            island.previewScene(l)
        case "runneroff":
            var l = s.input(s.working3)
            l.runnerOK = false
            island.previewScene(l)
        case "teamstopped": island.previewScene(s.input([s.docs()]))
        case "engineoff":
            var l = s.input([])
            l.engineOff = true
            island.previewScene(l)
        case "finished": island.previewScene(s.input([s.checkout(finished: true)]), before: s.input([s.checkout()]))
        case "problem": island.previewScene(s.input([s.checkout(failed: true), s.login(noModel: true), s.help()]))
        default: Pong.log("preview: unknown island scene \(name)")
        }
    }

    /// The made-up feed.
    struct Builder {
        let now: Double

        var working3: [GGraph] { [checkout(), help(), login(), onboarding(), docs(), finished1(ago: 12 * 60), invoice()] }

        func input(_ graphs: [GGraph], asks: [GChatAsk] = []) -> IslandInput {
            var i = IslandInput()
            i.graphs = graphs
            i.asks = asks
            i.architects = [GArchitect(["id": "a_1", "session": "team-b", "title": "Launch plan", "alive": true, "runtime": "claude",
                                        "model": "opus", "graphs": ["g_help", "g_release", "g_onboard"], "created_at": now - 7200])]
            i.runnerOK = true
            i.runningTeams = ["team-a", "team-b"]
            i.teamNames = ["team-a": "Northwind", "team-b": "Juniper", "team-c": "Harbor"]
            i.teams = teams(graphs, asks: asks)
            i.now = now
            return i
        }

        // MARK: Graphs

        func checkout(limit: Bool = false, week: Bool = false, finished: Bool = false, failed: Bool = false) -> GGraph {
            let testsLive: [String: Any]? = limit || finished || failed ? nil
                : ["state": "working", "doing": "Bash(make test)", "changed_at": now - 20, "busy": true]
            let tests = N("run-the-tests", "check", failed ? "failed" : (finished ? "done" : "running"), title: "Run the tests",
                          rt: "claude", model: "sonnet", started: now - 120, finished: finished ? now - 30 : nil, visits: 1,
                          live: testsLive, loop: ["id": "L1", "round": 2, "max_iters": 3])
            let why = limit ? (week ? "paused near Claude's weekly limit" : "paused for Claude's 5-hour limit") : ""
            return G("g_checkout", session: "team-a", label: "Northwind", title: "Checkout fix",
                     status: finished ? "done" : "running", start: "find-the-cause",
                     nodes: [N("find-the-cause", "researcher", "done", title: "Find the cause", rt: "claude", model: "opus",
                               started: now - 1560, finished: now - 1200, visits: 1),
                             N("fix", "builder", "done", title: "Fix", rt: "claude", model: "sonnet", started: now - 800,
                               finished: now - 130, visits: 2),
                             tests,
                             N("review", "critic", finished ? "done" : "pending", title: "Review"),
                             N("end", "end")],
                     edges: [E("find-the-cause", "fix"), E("fix", "run-the-tests"), E("run-the-tests", "review", "win"),
                             E("run-the-tests", "fix", "fail"), E("review", "end", "win"), E("review", "fix", "fail")],
                     wall: 26, finished: finished ? now - 2 : nil, stop: finished ? "win" : "",
                     pause: limit, reason: why, held: limit ? 1 : 0)
        }

        func help() -> GGraph {
            func write(_ n: Int, _ title: String, started: Double, doing: String) -> [String: Any] {
                N("write#\(n)", "writer", "running", title: title, copyOf: "write", rt: "claude", model: "opus", started: started,
                  visits: 1, live: ["state": "working", "doing": doing, "changed_at": now - 70, "busy": true])
            }
            return G("g_help", session: "team-b", label: "Juniper", title: "Help center articles", start: "plan",
                     nodes: [N("plan", "researcher", "done", title: "Plan the articles", rt: "claude", model: "opus",
                               started: now - 1980, finished: now - 1500, visits: 1),
                             write(1, "Intro", started: now - 1400, doing: "Write(docs/INTRO.md)"),
                             write(2, "Setup", started: now - 1390, doing: "Write(docs/SETUP.md)"),
                             write(3, "FAQ", started: now - 1380, doing: "Write(docs/FAQ.md)"),
                             N("gather", "join", "waiting"), N("review", "critic", "pending", title: "Review the articles"), N("end", "end")],
                     edges: [E("plan", "write#1"), E("plan", "write#2"), E("plan", "write#3"), E("write#1", "gather", "*"),
                             E("write#2", "gather", "*"), E("write#3", "gather", "*"), E("gather", "review", "*"),
                             E("review", "end", "win"), E("review", "plan", "fail")],
                     wall: 33)
        }

        func login(noModel: Bool = false) -> GGraph {
            var polish = N("polish", "builder", "running", title: "Polish the form", rt: "codex", started: now - 2400, visits: 1,
                           live: ["state": "quiet", "doing": "Edit(src/LoginForm.tsx)", "changed_at": now - 14 * 60])
            if noModel {
                polish["attention"] = "has stopped: its AI is not running. Open its screen."
                polish["seat"] = "w3"
            }
            return G("g_login", session: "team-a", label: "Northwind", title: "Login form", start: "build",
                     nodes: [N("build", "builder", "done", title: "Build the form", rt: "codex", started: now - 3100, finished: now - 2450,
                               visits: 1), polish, N("review", "critic", "pending", title: "Review"), N("end", "end")],
                     edges: [E("build", "polish"), E("polish", "review"), E("review", "end", "win"), E("review", "polish", "fail")],
                     wall: 52)
        }

        func onboarding(limit: Bool = false, week: Bool = false) -> GGraph {
            G("g_onboard", session: "team-b", label: "Juniper", title: "Onboarding emails", start: "draft",
              nodes: [N("draft", "writer", "done", title: "Draft the emails", rt: "claude", model: "opus", started: now - 4000,
                        finished: now - 3000, visits: 1),
                      N("send-a-test", "builder", "ready", title: "Send a test"), N("end", "end")],
              edges: [E("draft", "send-a-test"), E("send-a-test", "end")],
              wall: 64, pause: true,
              reason: limit ? (week ? "paused near Claude's weekly limit" : "paused for Claude's 5-hour limit") : "", held: 1)
        }

        func docs() -> GGraph {
            G("g_docs", session: "team-c", label: "Harbor", title: "Docs refresh", start: "gather",
              nodes: [N("gather", "researcher", "running", title: "Gather the old pages", rt: "claude", model: "sonnet",
                        started: now - 540, visits: 1),
                      N("rewrite", "writer", "pending", title: "Rewrite"), N("end", "end")],
              edges: [E("gather", "rewrite"), E("rewrite", "end")], wall: 9)
        }

        func research() -> GGraph {
            G("g_research", session: "team-b", label: "Juniper", title: "Research sources", start: "",
              nodes: [N("scan", "researcher", "done", title: "Scan the brief", rt: "grok", model: "grok-4.7", started: now - 840,
                        finished: now - 600, visits: 1),
                      N("gather", "researcher", "running", title: "Gather the sources", rt: "grok", model: "grok-4.7",
                        started: now - 590, visits: 1,
                        live: ["state": "working", "doing": "WebSearch(\"bakery pricing pages\")", "changed_at": now - 40, "busy": true])],
              edges: [E("scan", "gather"), E("gather", "scan", "more")], wall: 14)
        }

        func finished1(ago: Double) -> GGraph {
            G("g_search", session: "team-b", label: "Juniper", title: "Faster search", status: "done", start: "build",
              nodes: [N("build", "builder", "done", title: "Build"), N("end", "end", "done")], edges: [E("build", "end")],
              wall: 41, finished: now - ago, stop: "win")
        }

        func invoice() -> GGraph {
            G("g_invoice", session: "team-a", label: "Northwind", title: "Invoice export", status: "done", start: "build",
              nodes: [N("build", "builder", "done", title: "Build"), N("end", "end")], edges: [E("build", "end")],
              wall: 18, finished: now - 3700, stop: "cancelled")
        }

        func pricing() -> GGraph {
            let dir = IslandPreviewScenes.files()
            let ask: [String: Any] = [
                "question": "Is the new pricing page ready to publish?",
                "context": ["The review passed on its second round. The page has three plans and a yearly discount."],
                "detail": [
                    ["text": "Three plans: Starter $9, Team $29 and Business $79 a month.", "file": dir + "/PRICES.md", "where": "Plans"],
                    ["text": "Yearly billing takes 20% off every plan.", "file": dir + "/PRICES.md", "where": "Yearly"],
                    ["text": "The reviewer checked phone and desktop widths and found no layout problems.",
                     "file": dir + "/review-notes.md", "where": "Round 2"],
                    ["text": "Approving doesn't publish anything yet: Prepare the release builds it for one more check."],
                ],
                "detail_by": "Claude Haiku",
                "files": [dir + "/PRICES.md", dir + "/pricing.html", dir + "/review-notes.md"],
            ]
            return G("g_pricing", session: "team-a", label: "Northwind", title: "Pricing page", start: "write-the-page",
                     nodes: [N("write-the-page", "writer", "done", title: "Write the page", rt: "claude", model: "opus",
                               started: now - 3000, finished: now - 2000, visits: 2),
                             N("check-the-page", "critic", "done", title: "Check the page", rt: "claude", model: "sonnet",
                               started: now - 1900, finished: now - 720, visits: 2),
                             N("final-review", "human", "waiting_human", title: "Final review"),
                             N("prepare-the-release", "builder", "pending", title: "Prepare the release"), N("end", "end")],
                     edges: [E("write-the-page", "check-the-page"), E("check-the-page", "final-review", "win"),
                             E("check-the-page", "write-the-page", "fail"), E("final-review", "prepare-the-release", "approved"),
                             E("final-review", "write-the-page", "rejected"), E("prepare-the-release", "end")],
                     gates: [["node": "final-review", "from": "check-the-page", "at": now - 720, "options": ["approved", "rejected"],
                              "ask": ask, "advice": ["probabilities": ["approved": 0.71, "rejected": 0.24]]]],
                     wall: 48)
        }

        func release() -> GGraph {
            let dir = IslandPreviewScenes.files()
            let ask: [String: Any] = [
                "question": "Use this changelog for version 4.2?",
                "context": ["Eleven changes, grouped as New, Fixed and Removed."],
                "detail": [
                    ["text": "Two changes are marked as breaking: the old export link and the first sign-in page.",
                     "file": dir + "/CHANGELOG.md", "where": "Removed"],
                    ["text": "Internal fixes are left out, as the brief asked.", "file": dir + "/BRIEF.md", "where": "Scope"],
                    ["text": "The wording matches last month's notes."],
                ],
                "detail_by": "CyberPong",
                "files": [dir + "/CHANGELOG.md", dir + "/BRIEF.md"],
            ]
            return G("g_release", session: "team-b", label: "Juniper", title: "Release notes", start: "write-the-draft",
                     nodes: [N("write-the-draft", "writer", "done", title: "Write the draft", rt: "claude", model: "opus",
                               started: now - 1500, finished: now - 260, visits: 1),
                             N("changelog-check", "human", "waiting_human", title: "Changelog check"), N("end", "end")],
                     edges: [E("write-the-draft", "changelog-check"), E("changelog-check", "end", "approved"),
                             E("changelog-check", "write-the-draft", "rejected")],
                     gates: [["node": "changelog-check", "from": "write-the-draft", "at": now - 240, "options": ["approved", "rejected"],
                              "ask": ask, "advice": ["probabilities": ["approved": 0.58, "rejected": 0.38]]]],
                     wall: 18)
        }

        func launchAsk() -> GChatAsk {
            let dir = IslandPreviewScenes.files()
            return GChatAsk(["id": "q_launch", "session": "team-b", "seat": "c1.arch", "architect": "a_1",
                             "question": "Which launch date should I plan the release around?",
                             "context": ["Both dates leave two days for a last check."],
                             "options": [["key": "1", "label": "Tuesday 14 Oct", "what": "The chat plans the release around Tuesday."],
                                         ["key": "2", "label": "Thursday 16 Oct", "what": "The chat plans the release around Thursday."]],
                             "files": [dir + "/LAUNCH.md"],
                             "detail": [["text": "Tuesday 14 Oct gives the docs team one extra day.", "file": dir + "/LAUNCH.md", "where": "Dates"],
                                        ["text": "Thursday 16 Oct lines up with the newsletter.", "file": dir + "/LAUNCH.md", "where": "Newsletter"]],
                             "detail_by": "the chat", "created_at": now - 540])
        }

        // MARK: Teams

        func teams(_ graphs: [GGraph], asks: [GChatAsk]) -> [IslandTeamInput] {
            typealias M = IslandTeamInput.Member
            let waitingA = graphs.filter { $0.session == "team-a" && $0.waitingOnYou }.count
            let waitingB = graphs.filter { $0.session == "team-b" && $0.waitingOnYou }.count
            func line(_ lead: String, _ helpers: Int, _ waiting: Int, _ working: Int, _ paused: Int) -> String {
                var p = ["Lead: " + lead, Words.plural(helpers, "helper")]
                if waiting > 0 { p.append(Words.plural(waiting, "graph") + (waiting == 1 ? " needs" : " need") + " you") }
                if working > 0 { p.append((waiting > 0 ? "\(working) " : Words.plural(working, "graph") + " ") + "working") }
                if paused > 0 { p.append("\(paused) paused") }
                return p.joined(separator: " · ")
            }
            let a = IslandTeamInput(
                session: "team-a", name: "Northwind", running: true, status: waitingA > 0 ? .needsYou : .working,
                plainLine: line("Claude Opus", 2, waitingA, 2, 0),
                members: [M(isLead: true, ai: "Claude Opus", status: .working, word: "Working", doing: "Checking the test results"),
                          M(isLead: false, ai: "Claude Sonnet", status: .working, word: "Working", graphTitle: "Checkout fix",
                            stepName: "Run the tests"),
                          M(isLead: false, ai: "Codex", status: .stale, word: "Working", graphTitle: "Login form", stepName: "Polish the form")],
                lastMessage: "The tests pass on the second round. Review starts next.", lastMessageAt: now - 240)
            let b = IslandTeamInput(
                session: "team-b", name: "Juniper", running: true, status: waitingB > 0 || !asks.isEmpty ? .needsYou : .working,
                plainLine: line("Claude Opus", 3, waitingB, 1, 1),
                members: [M(isLead: true, ai: "Claude Opus", status: .working, word: "Working", doing: "Planning the docs"),
                          M(isLead: false, ai: "Claude Opus", status: .working, word: "Working", graphTitle: "Help center articles",
                            stepName: "Intro"),
                          M(isLead: false, ai: "Claude Opus", status: .working, word: "Working", graphTitle: "Help center articles",
                            stepName: "Setup"),
                          M(isLead: false, ai: "Claude Sonnet", status: .pending, word: "Idle")],
                lastMessage: "FAQ is the last article, then the review.", lastMessageAt: now - 660)
            let c = IslandTeamInput(
                session: "team-c", name: "Harbor", running: false, status: .stopped,
                plainLine: "Lead: Claude Sonnet · 1 helper · stopped · 1 graph waits for it",
                members: [M(isLead: true, ai: "Claude Sonnet", status: .stopped, word: "Stopped"),
                          M(isLead: false, ai: "Claude Sonnet", status: .stopped, word: "Stopped")])
            return [a, b, c]
        }

        // MARK: Shapes of the feed

        func N(_ id: String, _ role: String = "builder", _ status: String = "pending", title: String = "", copyOf: String = "",
               rt: String = "", model: String = "", started: Double? = nil, finished: Double? = nil, visits: Int = 0,
               live: [String: Any]? = nil, loop: [String: Any]? = nil) -> [String: Any] {
            var d: [String: Any] = ["id": id, "role": role, "status": status, "visits": visits]
            if !title.isEmpty { d["title"] = title }
            if !copyOf.isEmpty { d["copy_of"] = copyOf }
            if !rt.isEmpty { d["runtime"] = rt; d["model"] = model }
            if let started { d["started_at"] = started }
            if let finished { d["finished_at"] = finished }
            if let live { d["live"] = live }
            if let loop { d["loop"] = loop }
            return d
        }

        func E(_ f: String, _ t: String, _ on: String = "done") -> [String: Any] { ["from": f, "to": t, "on": on] }

        func G(_ id: String, session: String, label: String, title: String, status: String = "running", start: String,
               nodes: [[String: Any]], edges: [[String: Any]], gates: [[String: Any]] = [], wall: Double,
               finished: Double? = nil, stop: String = "", pause: Bool = false, reason: String = "", held: Int = 0) -> GGraph {
            var d: [String: Any] = ["id": id, "session": session, "team_label": label, "title": title, "status": status,
                                    "start": start, "nodes": nodes, "edges": edges, "gates": gates,
                                    "budget": ["wall_min": wall, "max_wall_min": 180, "jobs": 3, "max_jobs": 12],
                                    "created_at": now - wall * 60 - 60, "stop_reason": stop, "manual_pause": pause,
                                    "pause_reason": reason, "held": held, "round": 1, "max_rounds": 3]
            if let finished { d["finished_at"] = finished }
            return GGraph(d)
        }
    }

    /// The files the made-up questions point at, in a temporary folder of their own.
    static func files() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("cyberpong-island-preview")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in ["PRICES.md", "pricing.html", "review-notes.md", "CHANGELOG.md", "BRIEF.md", "LAUNCH.md"] {
            let p = (dir as NSString).appendingPathComponent(name)
            if !fm.fileExists(atPath: p) { fm.createFile(atPath: p, contents: Data("# \(name)\n\nMade up for the preview.\n".utf8)) }
        }
        return dir
    }
}
