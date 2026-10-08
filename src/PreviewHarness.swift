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
/// and `quit` leaves the live notch island alone.
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
        guard let win = window ?? PanelController.shared.previewWindow ?? NSApp.keyWindow,
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
