import AppKit
import SceneKit
import simd

// MARK: - The graph deck (design-language.md, "3D deck"). SceneKit draws the room: the fog, the deck
// plane and its dots, the loop rings. Everything you read is drawn flat on top, in points, so it stays
// sharp at every zoom and always faces you: steps as 24 pt squares, the edges and their arrows, the
// labels, the HUD line and the Esper readout. One graph (Wiring), or every graph as a cluster on its
// team's column (Orbit).
//
// Reads GGraph only. Nothing on the deck is drawn that is not in the snapshot.

final class GraphDeckView: SCNView {
    enum Mode { case orbit, wiring }

    var onSelectNode: ((String?) -> Void)?
    var onSelectGraph: ((String) -> Void)?
    var onOpenSeat: ((String) -> Void)?

    private(set) var mode: Mode = .wiring
    private let root = SCNNode()
    private let cameraNode = SCNNode()
    private var content = SCNNode()
    private var signature = ""
    private var selectedNode: String?
    private var lastExtent = CGSize(width: 10, height: 6)
    private var lastWiringKey: String?
    private var lastCenter = SCNVector3Zero
    /// The camera as the last fit left it: a resize refits only while nobody has moved it since.
    private var fitted: SCNMatrix4?
    private var fitDistance: CGFloat = 10
    private var fitScale: CGFloat = 5

    private let overlay = DeckOverlayView()
    private let watch = DeckRenderWatch()
    private let fitBtn = PongButton(title: "", style: .quiet)
    private let outBtn = PongButton(title: "", style: .quiet)
    private let inBtn = PongButton(title: "", style: .quiet)
    private let flatBtn = PongButton(title: "2D", style: .quiet)
    /// Seen from straight above, where a drag pans instead of turning (the 2D button). Remembered.
    private var flat = UserDefaults.standard.bool(forKey: "deck.flat")
    private var esperUntil: TimeInterval = 0

    // deck units
    private let dx: CGFloat = 3.4
    private let dz: CGFloat = 2.7

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let scene = SCNScene()
        scene.rootNode.addChildNode(root)
        self.scene = scene
        backgroundColor = PongColor.void
        scene.background.contents = GraphTextures.fog()
        scene.fogColor = PongColor.void
        scene.fogStartDistance = 34
        scene.fogEndDistance = 110
        scene.fogDensityExponent = 1.4
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 30
        allowsCameraControl = true
        defaultCameraController.interactionMode = flat ? .pan : .orbitTurntable
        defaultCameraController.inertiaEnabled = true
        defaultCameraController.maximumVerticalAngle = 80
        defaultCameraController.minimumVerticalAngle = 8

        let cam = SCNCamera()
        cam.fieldOfView = 38
        cam.zNear = 0.1
        cam.zFar = 400
        cam.usesOrthographicProjection = flat
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        root.addChildNode(content)

        overlay.project = { [weak self] p in self?.screenPoint(p) }
        overlay.esperText = { [weak self] in self?.esperLine() ?? "" }
        addSubview(overlay)
        // the flat layer follows the camera: SceneKit says when a frame moved it
        watch.onChange = { [weak self] in self?.overlay.needsDisplay = true }
        delegate = watch

        for (b, sym, tip) in [(fitBtn, "arrow.up.left.and.arrow.down.right", "Fit the whole graph in view"),
                              (outBtn, "minus", "Zoom out"), (inBtn, "plus", "Zoom in")] {
            b.symbol = sym
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            addSubview(b)
        }
        // VoiceOver: the deck is a group named for its graph; its steps are buttons that select
        // (the Steps tab stays the full accessible equivalent)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityHelp("The Steps tab lists every step with its state.")
        fitBtn.onPress = { [weak self] in self?.resetCamera() }
        outBtn.onPress = { [weak self] in self?.zoom(by: 1.25) }
        inBtn.onPress = { [weak self] in self?.zoom(by: 0.8) }
        flatBtn.onPress = { [weak self] in self?.toggleFlat() }
        addSubview(flatBtn)
        styleFlatButton()
    }

    func retheme() {
        backgroundColor = PongColor.void
        signature = ""
        GraphTextures.clear()
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        // Fit, −, + and 2D: 28 pt quiet icons, top right
        var x = bounds.width - 12
        let y = bounds.height - 12 - 28
        for b in [flatBtn, inBtn, outBtn, fitBtn] {
            let w = max(28, b.intrinsicContentSize.width)
            x -= w
            b.frame = NSRect(x: x, y: y, width: w, height: 28)
            x -= 4
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        // fit to the bounds on open and on resize, unless the camera was moved since
        if old != newSize, newSize.width > 40, newSize.height > 40, cameraUntouched {
            resetCamera(animated: false)
        }
    }

    private var cameraUntouched: Bool {
        guard let f = fitted else { return true }
        guard let pov = pointOfView, pov === cameraNode else { return false }
        return SCNMatrix4EqualToMatrix4(pov.transform, f)
    }

    // MARK: Public

    func showWiring(_ g: GGraph?, selected: String?, force: Bool = false) {
        let sig = "W|" + (g?.visualSignature ?? "none") + "|" + (selected ?? "")
        let modeChanged = mode != .wiring
        mode = .wiring
        selectedNode = selected
        let key = (g?.session ?? "") + "/" + (g?.id ?? "")
        let keyChanged = key != lastWiringKey
        lastWiringKey = key
        let lay = g.map { GraphLayout.compute($0) }
        if force || sig != signature || modeChanged {
            signature = sig
            rebuild { self.buildWiringRoom(g, lay) }
        }
        // the words and the working minutes change without the shape changing: the flat layer every time
        overlay.model = wiringModel(g, lay)
        setAccessibilityLabel(g.map { "Plan of \($0.displayTitle): " + spokenLine($0) } ?? "No graph open")
        // Frame the deck on first draw and whenever another graph is shown (the Esper zoom);
        // a status change keeps the view the person set.
        if modeChanged || force || keyChanged {
            if keyChanged && !force && g != nil { esperOpen() } else { resetCamera(animated: !force && !keyChanged) }
        }
    }

    func showOrbit(_ graphs: [GGraph], selectedKey: String?, force: Bool = false) {
        var sig = "O|" + (selectedKey ?? "")
        for g in graphs {
            sig += "|" + g.key + ":" + g.status + ":" + g.stopReason + ":" + "\(g.gates.count):\(g.nodes.map { $0.status }.joined(separator: ","))"
        }
        let modeChanged = mode != .orbit
        mode = .orbit
        let first = signature.isEmpty
        if force || sig != signature || modeChanged {
            signature = sig
            rebuild { self.buildOrbitRoom(graphs) }
        }
        overlay.model = orbitModel(graphs, selectedKey: selectedKey)
        setAccessibilityLabel("Every graph on one map: \(Words.plural(graphs.count, "graph"))")
        lastWiringKey = nil
        if modeChanged || force || first { resetCamera(animated: !force && !first) }
    }

    // MARK: Camera

    private struct Pose {
        var position: SCNVector3
        var target: SCNVector3
        var scale: CGFloat
    }

    /// Where the camera sits to fit the deck to the view less 48 pt on every side, `zoom` times as far.
    private func fitPose(zoom: CGFloat = 1) -> Pose {
        let w = max(lastExtent.width, 6)
        let h = max(lastExtent.height, 4)
        let W = max(bounds.width, 100), H = max(bounds.height, 100)
        let mW = W / max(40, W - 96), mH = H / max(40, H - 96)
        let aspect = W / H
        let target = lastCenter
        if flat {
            let scale = max(h / 2 * mH, (w / 2) / aspect * mW) * 1.04
            fitScale = scale
            return Pose(position: SCNVector3(target.x, target.y + 60, target.z), target: target, scale: scale * zoom)
        }
        // the vertical field of view is fixed, the horizontal one follows the view's shape; the deck
        // is seen from about 55° above so labels overlap less than from a low angle
        let vfov = CGFloat((cameraNode.camera?.fieldOfView ?? 38) * .pi / 180)
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        let fitW = (w / 2) * mW / tan(hfov / 2)
        let fitH = (h * 0.95 / 2) * mH / tan(vfov / 2)
        let dist = max(fitW, fitH, 8) * (mode == .orbit ? 1.18 : 1.08)
        fitDistance = dist
        let d = dist * zoom
        return Pose(position: SCNVector3(target.x, target.y + d * 0.82, target.z + d * 0.57), target: target, scale: 0)
    }

    private func apply(_ p: Pose) {
        cameraNode.camera?.usesOrthographicProjection = flat
        if flat {
            cameraNode.camera?.orthographicScale = Double(p.scale)
            cameraNode.position = p.position
            // straight down, the deck's far edge up
            cameraNode.look(at: p.target, up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        } else {
            cameraNode.position = p.position
            cameraNode.look(at: p.target)
        }
    }

    func resetCamera(animated: Bool = true) {
        pointOfView = cameraNode
        let pose = fitPose()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && !PongMotion.reduced ? 0.45 : 0
        SCNTransaction.animationTimingFunction = PongMotion.easeInOut
        apply(pose)
        SCNTransaction.commit()
        defaultCameraController.target = pose.target
        fitted = cameraNode.transform
        overlay.needsDisplay = true
    }

    /// Opening a graph: the deck zooms in three 90 ms steps with its coordinates showing
    /// (the `esper` motion). Under Reduce Motion it fades in instead.
    private func esperOpen() {
        pointOfView = cameraNode
        guard !PongMotion.reduced else {
            resetCamera(animated: false)
            overlay.alphaValue = 0
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.15
                overlay.animator().alphaValue = 1
            }
            return
        }
        let steps: [CGFloat] = [2.4, 1.7, 1.3, 1.0]
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        apply(fitPose(zoom: steps[0]))
        SCNTransaction.commit()
        defaultCameraController.target = lastCenter
        showEsper(for: 0.27 + 0.4)
        for (i, z) in steps.dropFirst().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09 * Double(i)) { [weak self] in
                guard let self else { return }
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.09
                SCNTransaction.animationTimingFunction = PongMotion.easeOut
                self.apply(self.fitPose(zoom: z))
                SCNTransaction.commit()
                if z == 1 { self.fitted = self.cameraNode.transform }
            }
        }
    }

    private func zoom(by f: CGFloat) {
        guard let pov = pointOfView else { return }
        let t = defaultCameraController.target
        SCNTransaction.begin()
        SCNTransaction.animationDuration = PongMotion.reduced ? 0 : PongMotion.base
        SCNTransaction.animationTimingFunction = PongMotion.easeOut
        if let cam = pov.camera, cam.usesOrthographicProjection {
            cam.orthographicScale = max(0.5, cam.orthographicScale * Double(f))
        } else {
            let p = pov.position
            pov.position = SCNVector3(t.x + (p.x - t.x) * f, t.y + (p.y - t.y) * f, t.z + (p.z - t.z) * f)
        }
        SCNTransaction.commit()
        showEsper(for: PongMotion.base + 0.6)
    }

    private func toggleFlat() {
        flat.toggle()
        UserDefaults.standard.set(flat, forKey: "deck.flat")
        defaultCameraController.interactionMode = flat ? .pan : .orbitTurntable
        styleFlatButton()
        resetCamera(animated: false)
    }

    private func styleFlatButton() {
        flatBtn.title = flat ? "3D" : "2D"
        flatBtn.toolTip = flat ? "Tilt the deck again" : "See the deck from straight above"
        flatBtn.setAccessibilityLabel(flat ? "Tilted view" : "Flat view")
    }

    /// The readout shows while the deck zooms, then fades in 150 ms.
    private func showEsper(for seconds: TimeInterval) {
        esperUntil = max(esperUntil, Date().timeIntervalSince1970 + seconds)
        overlay.esperAlpha = 1
        overlay.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, Date().timeIntervalSince1970 >= self.esperUntil - 0.02 else { return }
            for i in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { [weak self] in
                    guard let self, Date().timeIntervalSince1970 >= self.esperUntil - 0.02 else { return }
                    self.overlay.esperAlpha = 1 - CGFloat(i) / 5
                    self.overlay.needsDisplay = true
                }
            }
        }
    }

    /// "X 0.42  Y 0.18  ×2.4": where on the deck the camera looks, and how close it is.
    private func esperLine() -> String {
        let t = defaultCameraController.target
        let w = max(lastExtent.width, 1), h = max(lastExtent.height, 1)
        let x = min(1, max(0, (t.x - (lastCenter.x - w / 2)) / w))
        let y = min(1, max(0, (t.z - (lastCenter.z - h / 2)) / h))
        var z: CGFloat = 1
        if let pov = pointOfView {
            if let cam = pov.camera, cam.usesOrthographicProjection {
                z = fitScale / max(0.01, CGFloat(cam.orthographicScale))
            } else {
                let p = pov.presentation.position
                let d = sqrt((p.x - t.x) * (p.x - t.x) + (p.y - t.y) * (p.y - t.y) + (p.z - t.z) * (p.z - t.z))
                z = fitDistance / max(0.01, d)
            }
        }
        return String(format: "X %.2f  Y %.2f  ×%.1f", x, y, z)
    }

    /// A deck point in the flat layer's (flipped) coordinates; nil behind the camera.
    private func screenPoint(_ p: SCNVector3) -> CGPoint? {
        let s = projectPoint(p)
        guard s.z > 0, s.z < 1 else { return nil }
        return CGPoint(x: s.x, y: bounds.height - s.y)
    }

    // MARK: Build: the room (SceneKit)

    private func rebuild(_ body: () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        content.removeFromParentNode()
        content = SCNNode()
        root.addChildNode(content)
        body()
        SCNTransaction.commit()
    }

    private func positions(_ g: GGraph, _ lay: GraphLayout.Result) -> [String: SCNVector3] {
        // the Lead (the lead the graph hangs under) sits one layer before the start
        var out: [String: SCNVector3] = [:]
        for n in g.nodes {
            let p = lay.pos[n.id] ?? .zero
            out[n.id] = SCNVector3(CGFloat(p.x + 1) * dx, 0, p.y * dz)
        }
        return out
    }

    private struct Ring {
        let center: SCNVector3
        let rx: CGFloat
        let rz: CGFloat
        let spent: CGFloat
        let label: String
    }

    /// One ring per loop the engine found, labelled with its own rounds in its steps' words (`GLoop.label`;
    /// a person's loop drawn outside the agent loop it holds); older records fall back to the drawn cycles.
    private func rings(_ g: GGraph, _ lay: GraphLayout.Result, _ pos: [String: SCNVector3]) -> [Ring] {
        var out: [Ring] = []
        if !g.loops.isEmpty {
            for l in g.loops.sorted(by: { ($0.kind == "person" ? 0 : 1, $0.depth) < ($1.kind == "person" ? 0 : 1, $1.depth) }) {
                let pts = l.members.compactMap { pos[$0] }
                guard !pts.isEmpty else { continue }
                let pad: CGFloat = l.kind == "person" ? 0.9 : 0.0
                let cx = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
                let cz = pts.map { $0.z }.reduce(0, +) / CGFloat(pts.count)
                out.append(Ring(center: SCNVector3(cx, 0.01, cz),
                                rx: (pts.map { abs($0.x - cx) }.max() ?? 0) + 1.6 + pad,
                                rz: (pts.map { abs($0.z - cz) }.max() ?? 0) + 1.25 + pad,
                                spent: CGFloat(l.round) / CGFloat(max(1, l.maxIters)), label: l.label))
            }
        } else {
            for comp in lay.cycles {
                let pts = comp.compactMap { pos[$0] }
                guard !pts.isEmpty else { continue }
                let cx = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
                let cz = pts.map { $0.z }.reduce(0, +) / CGFloat(pts.count)
                let spent = comp.compactMap { g.node($0)?.visits }.max() ?? 0
                out.append(Ring(center: SCNVector3(cx, 0.01, cz),
                                rx: (pts.map { abs($0.x - cx) }.max() ?? 0) + 1.6,
                                rz: (pts.map { abs($0.z - cz) }.max() ?? 0) + 1.25,
                                spent: CGFloat(spent) / CGFloat(max(1, g.maxRounds)), label: "round \(spent) of \(g.maxRounds)"))
            }
        }
        return out
    }

    private func buildWiringRoom(_ g: GGraph?, _ lay: GraphLayout.Result?) {
        guard let g, let lay, !g.nodes.isEmpty else {
            addDeck(width: 10, depth: 6, center: SCNVector3Zero)
            lastExtent = CGSize(width: 10, height: 6)
            lastCenter = SCNVector3Zero
            return
        }
        let minX: CGFloat = -1.6
        let maxX = CGFloat(lay.layers) * dx + 1.6
        let halfZ = max(CGFloat(lay.lanes) * dz / 2 + 1.4, 2.8)
        let center = SCNVector3((minX + maxX) / 2, 0, 0)
        addDeck(width: maxX - minX, depth: halfZ * 2, center: center)
        lastExtent = CGSize(width: maxX - minX, height: halfZ * 2)
        lastCenter = SCNVector3(center.x, 0, 0)
        for r in rings(g, lay, positions(g, lay)) {
            addRing(center: r.center, rx: r.rx, rz: r.rz, spent: r.spent)
        }
    }

    private static let orbitColW: CGFloat = 6.0
    private static let orbitRowD: CGFloat = 5.2
    private static let orbitRing: CGFloat = 1.3

    private func buildOrbitRoom(_ graphs: [GGraph]) {
        let (teams, cells) = orbitCells(graphs)
        for c in cells {
            let ring = SCNNode(geometry: GraphShapes.circle(radius: Self.orbitRing, segments: 72))
            ring.geometry?.materials = [GraphShapes.lineMaterial(c.1.pongStatus.color.withAlphaComponent(0.6))]
            ring.position = SCNVector3(c.0.x, 0.01, c.0.z)
            content.addChildNode(ring)
        }
        let perRow = max(1, teams.map { t in graphs.filter { $0.session == t }.count }.max() ?? 1)
        // the team's name sits left of its row
        let minX: CGFloat = -Self.orbitColW * 1.8
        let maxX = CGFloat(perRow - 1) * Self.orbitColW + Self.orbitColW / 2
        let minZ: CGFloat = -Self.orbitRowD / 2
        let maxZ = CGFloat(max(1, teams.count) - 1) * Self.orbitRowD + Self.orbitRowD / 2 + 0.6
        let center = SCNVector3((minX + maxX) / 2, 0, (minZ + maxZ) / 2)
        addDeck(width: maxX - minX, depth: maxZ - minZ, center: center)
        lastExtent = CGSize(width: maxX - minX, height: maxZ - minZ)
        lastCenter = center
    }

    /// One row per team, its graphs to the right, newest first (the view is wider than tall).
    private func orbitCells(_ graphs: [GGraph]) -> ([String], [(SCNVector3, GGraph)]) {
        var teams: [String] = []
        for g in graphs where !teams.contains(g.session) { teams.append(g.session) }
        var cells: [(SCNVector3, GGraph)] = []
        for (ti, team) in teams.enumerated() {
            for (gi, g) in graphs.filter({ $0.session == team }).enumerated() {
                cells.append((SCNVector3(CGFloat(gi) * Self.orbitColW, 0, CGFloat(ti) * Self.orbitRowD), g))
            }
        }
        return (teams, cells)
    }

    /// The deck: a plane of dots with a hairline edge. No corner brackets, no caption.
    private func addDeck(width: CGFloat, depth: CGFloat, center: SCNVector3) {
        let plane = SCNPlane(width: width, height: depth)
        let m = SCNMaterial()
        m.diffuse.contents = GraphTextures.grid()
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(width / 1.0, depth / 1.0, 1)
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let deck = SCNNode(geometry: plane)
        deck.eulerAngles.x = -.pi / 2
        deck.position = SCNVector3(center.x, -0.02, center.z)
        deck.renderingOrder = -10
        content.addChildNode(deck)
        let hw = width / 2, hd = depth / 2
        let c = [SCNVector3(center.x - hw, 0, center.z - hd), SCNVector3(center.x + hw, 0, center.z - hd),
                 SCNVector3(center.x + hw, 0, center.z + hd), SCNVector3(center.x - hw, 0, center.z + hd)]
        content.addChildNode(lineNode([c[0], c[1], c[1], c[2], c[2], c[3], c[3], c[0]], color: PongColor.mark.withAlphaComponent(0.6)))
    }

    private func addRing(center: SCNVector3, rx: CGFloat, rz: CGFloat, spent: CGFloat) {
        let ring = SCNNode(geometry: GraphShapes.ellipse(rx: rx, rz: rz, segments: 96, dashed: true))
        ring.geometry?.materials = [GraphShapes.lineMaterial(PongColor.mark)]
        ring.position = center
        content.addChildNode(ring)
        if spent > 0 {
            let arc = SCNNode(geometry: GraphShapes.ellipse(rx: rx, rz: rz, segments: 96, dashed: false, fraction: min(1, spent)))
            arc.geometry?.materials = [GraphShapes.lineMaterial(spent >= 1 ? PongColor.textSecondary : PongColor.textTertiary)]
            arc.position = SCNVector3(center.x, center.y + 0.01, center.z)
            content.addChildNode(arc)
        }
    }

    private func lineNode(_ pts: [SCNVector3], color: NSColor) -> SCNNode {
        let geo = GraphShapes.lines(pts)
        geo.materials = [GraphShapes.lineMaterial(color)]
        return SCNNode(geometry: geo)
    }

    // MARK: Build: the flat layer (what you read)

    private func wiringModel(_ g: GGraph?, _ lay: GraphLayout.Result?) -> DeckOverlayView.Model {
        var m = DeckOverlayView.Model()
        guard let g, let lay, !g.nodes.isEmpty else {
            m.hud = "NO GRAPH OPEN"
            return m
        }
        let pos = positions(g, lay)
        let lead = SCNVector3(0, 0, 0)
        m.items.append(.init(id: "", world: lead, name: "Lead", line2: "", status: .pending, lead: true))

        // the Lead → the start
        let starts = g.nodes.filter { n in !g.edges.contains { $0.to == n.id && !lay.backEdges.contains($0) } }
        for s in starts {
            if let p = pos[s.id] { m.links.append(.init(from: "", to: s.id, points: [lead, p], color: PongColor.mark, dashed: false, label: "")) }
        }

        // A graph's steps at work: held still (a pause for Claude's limits, or its team is stopped), or
        // finishing under the person's own pause, the way the Steps list says it.
        let still = held(g)
        let finishing = g.isPausedNow && !still
        let teamDown = still && !g.teamUp

        // The edge into the working step is cyan, into a question amber, both at 60%: the edges
        // that were taken to get there, else every edge into it.
        let hot = Dictionary(uniqueKeysWithValues: g.nodes.compactMap { n -> (String, PongStatus)? in
            let st = n.pongStatus(graphRunning: g.isRunning, graphPaused: still)
            return st == .working || st == .needsYou ? (n.id, st) : nil
        })
        var taken = Set<String>()
        for e in g.edges where hot[e.to] != nil {
            if let src = g.node(e.from), src.status == "done", edgeTaken(e, outcome: src.lastOutcome) { taken.insert(e.to + "<" + e.from) }
        }
        var pairCount: [String: Int] = [:]
        // parallel edges between the same two steps say their outcomes once, in words: "passed · left it
        // to you · hit an error"
        var words: [String: [String]] = [:]
        var labelled = Set<String>()
        for e in g.edges where e.on != "*" { words[e.from + ">" + e.to, default: []].append(Words.outcome(e.on).lowercased()) }
        for e in g.edges {
            guard let a = pos[e.from], let b = pos[e.to] else { continue }
            let back = lay.backEdges.contains(e) || e.from == e.to
            let pairKey = [e.from, e.to].sorted().joined(separator: ">")
            let k = pairCount[pairKey, default: 0]
            pairCount[pairKey] = k + 1
            var color = PongColor.mark
            if let st = hot[e.to] {
                let anyTaken = taken.contains { $0.hasPrefix(e.to + "<") }
                if !anyTaken || taken.contains(e.to + "<" + e.from) {
                    color = (st == .needsYou ? PongColor.you : PongColor.live).withAlphaComponent(0.6)
                }
            }
            let curve: CGFloat = back ? 1.0 + CGFloat(k) * 0.5 : (k > 0 ? CGFloat(k) * 0.55 : 0)
            // an outcome word only where it says something: on a lit edge, or at the selected step
            let says = e.on != "*" && (color != PongColor.mark || e.from == selectedNode || e.to == selectedNode)
                && labelled.insert(e.from + ">" + e.to).inserted
            m.links.append(.init(from: e.from, to: e.to, points: curvePoints(a, b, curve: curve), color: color,
                                 dashed: back, label: says ? (words[e.from + ">" + e.to] ?? []).joined(separator: " · ") : ""))
        }

        for n in g.nodes {
            guard let p = pos[n.id] else { continue }
            let st = n.pongStatus(graphRunning: g.isRunning, graphPaused: still)
            let sel = n.id == selectedNode
            m.items.append(.init(id: n.id, world: p, name: Words.name(n.id),
                                 line2: line2(n, st, selected: sel, finishing: finishing, teamDown: teamDown),
                                 status: st,
                                 human: n.role == "human", refused: g.refusals.contains { $0.node == n.id }, selected: sel))
        }
        for r in rings(g, lay, pos) where !r.label.isEmpty {
            m.tags.append(.init(world: SCNVector3(r.center.x, 0, r.center.z - r.rz - 0.4), text: r.label))
        }
        m.hud = hudLine(g)
        return m
    }

    /// Under a working, waiting or selected step: what it is doing, in words. Verdicts are said the way
    /// every page says them ("didn't pass", never "fail"); a step at work in a paused graph is finishing,
    /// and one whose team is stopped waits for it, as the Steps list says.
    private func line2(_ n: GNode, _ st: PongStatus, selected: Bool, finishing: Bool = false, teamDown: Bool = false) -> String {
        var parts: [String] = []
        switch st {
        case .paused where teamDown && n.status == "running":
            parts.append("waits for its team")
        case .working:
            let word = finishing && n.status == "running" ? "finishing" : "working"
            if let s = n.startedAt { parts.append(word + " · " + PongUI.duration(Date().timeIntervalSince1970 - s)) } else { parts.append(word) }
        case .needsYou:
            parts.append(n.role == "human" ? "waiting on you"
                         : (n.liveState == "no_model" ? "no model running" : (n.attention.contains("folder") ? "asks to open a folder" : "asks you something")))
        case .failed where !n.lastOutcome.isEmpty:
            // the cross already says it failed: say how ("didn't pass", "hit an error", "ran out of time")
            let how = Words.outcome(n.lastOutcome).lowercased()
            parts.append(["done", "passed"].contains(how) ? "failed" : how)
        case .done where !n.lastOutcome.isEmpty && n.lastOutcome != "done":
            // the tick already says it is done: say how ("passed", "sent back", "chose fix"), short, as the
            // words under a step have little room
            parts.append(Words.outcome(n.lastOutcome).lowercased())
        default:
            parts.append(st.word.lowercased())
        }
        if !n.loopId.isEmpty && n.loopMax > 0 { parts.append("round \(max(1, n.loopRound)) of \(n.loopMax)") }
        if selected && !n.isSeatless && !n.runtime.isEmpty { parts.append(Words.ai(n.runtime, n.model)) }
        return parts.joined(separator: " · ")
    }

    /// "STEP 03 / 07 · CRITIQUE": the step that matters (a question, else the working one), numbered
    /// as the Steps list numbers it; a graph with neither says how many steps and how it ended.
    private func hudLine(_ g: GGraph) -> String {
        let steps = g.nodes.filter { $0.role != "end" }
        let total = steps.count
        let cur = steps.firstIndex { $0.status == "waiting_human" || !$0.attention.isEmpty }
            ?? steps.firstIndex { $0.status == "running" }
        if let i = cur {
            return String(format: "STEP %02d / %02d · ", i + 1, total) + Words.name(steps[i].id).uppercased()
        }
        return String(format: "%02d STEPS · ", total) + g.pongStatus.word.uppercased()
    }

    /// The HUD line, spoken: "step 3 of 7, Critique, needs you" or "9 steps, done".
    private func spokenLine(_ g: GGraph) -> String {
        let steps = g.nodes.filter { $0.role != "end" }
        if let i = steps.firstIndex(where: { $0.status == "waiting_human" || !$0.attention.isEmpty })
            ?? steps.firstIndex(where: { $0.status == "running" }) {
            let n = steps[i]
            return "step \(i + 1) of \(steps.count), \(Words.name(n.id)), \(n.pongStatus(graphRunning: g.isRunning, graphPaused: held(g)).word.lowercased())"
        }
        return "\(Words.plural(steps.count, "step")), \(g.pongStatus.word.lowercased())"
    }

    /// Each step on the deck as a button VoiceOver can reach; pressing it selects the step.
    override func accessibilityChildren() -> [Any]? {
        guard mode == .wiring else { return super.accessibilityChildren() }
        var out: [Any] = [fitBtn, outBtn, inBtn, flatBtn]
        for (id, rect) in overlay.stepRects where !id.isEmpty {
            guard let item = overlay.model.items.first(where: { $0.id == id }) else { continue }
            let e = DeckStepElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel("\(item.name), \(item.status.word)" + (item.line2.isEmpty ? "" : ", \(item.line2)"))
            e.setAccessibilitySelected(item.selected)
            let r = overlay.convert(rect, to: nil)
            e.setAccessibilityFrame(window?.convertToScreen(r) ?? r)
            e.onPress = { [weak self] in self?.onSelectNode?(id) }
            out.append(e)
        }
        return out
    }

    private func orbitModel(_ graphs: [GGraph], selectedKey: String?) -> DeckOverlayView.Model {
        var m = DeckOverlayView.Model()
        let (teams, cells) = orbitCells(graphs)
        for (ti, team) in teams.enumerated() {
            m.tags.append(.init(world: SCNVector3(-Self.orbitRing - 0.9, 0, CGFloat(ti) * Self.orbitRowD), text: TeamNames.name(team),
                                eyebrow: true, right: true))
        }
        for (p, g) in cells {
            let k = max(1, g.nodes.count)
            let still = held(g)
            var dots: [(SCNVector3, PongStatus)] = []
            for (i, n) in g.nodes.enumerated() {
                let a = CGFloat(i) / CGFloat(k) * .pi * 2
                dots.append((SCNVector3(p.x + cos(a) * 0.85, 0, p.z + sin(a) * 0.85),
                             n.pongStatus(graphRunning: g.isRunning, graphPaused: still)))
            }
            m.clusters.append(.init(key: g.key, world: p, radius: Self.orbitRing, title: g.displayTitle, line2: g.plainStatus,
                                    status: g.pongStatus, dots: dots, waiting: g.waitingOnYou, selected: g.key == selectedKey))
        }
        m.hud = "\(graphs.count) GRAPHS · \(teams.count) TEAMS"
        return m
    }

    /// Whether a graph's steps at work hold still: a pause for Claude's limits, or its team is stopped,
    /// paused or not (`GGraph.stepsHoldStill`, the test the Steps list uses). The person's own pause lets
    /// them finish.
    private func held(_ g: GGraph) -> Bool {
        g.stepsHoldStill(teamUp: SchedulesPageView.runningTeams.contains(g.session))
    }

    private func edgeTaken(_ e: GEdge, outcome: String) -> Bool {
        if e.on == "*" || e.on == outcome { return true }
        if e.on == "done" { return ["done", "win", "approved"].contains(outcome) }
        // the engine's fail family (graph_engine.FAIL_FAMILY); abstain and error have edges of their own
        if e.on == "fail" { return ["fail", "failed", "blocked", "rejected", "not_found"].contains(outcome) }
        return false
    }

    /// An edge on the deck: straight, or bent (a second edge between the same steps, a loop back).
    private func curvePoints(_ a: SCNVector3, _ b: SCNVector3, curve: CGFloat) -> [SCNVector3] {
        let dxv = b.x - a.x, dzv = b.z - a.z
        let len = max(0.001, sqrt(dxv * dxv + dzv * dzv))
        guard curve > 0 else { return [a, b] }
        let px = -dzv / len, pz = dxv / len
        let bulge = curve * (len * 0.22 + 0.9)
        let mid = SCNVector3((a.x + b.x) / 2 + px * bulge, 0, (a.z + b.z) / 2 + pz * bulge)
        var pts: [SCNVector3] = []
        for i in 0...24 {
            let t = CGFloat(i) / 24, u = 1 - t
            pts.append(SCNVector3(u * u * a.x + 2 * u * t * mid.x + t * t * b.x, 0,
                                  u * u * a.z + 2 * u * t * mid.z + t * t * b.z))
        }
        return pts
    }

    // MARK: Picking

    /// A click on a node selects it even when the window was not the key
    /// window (otherwise the first click only activates the window).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pickingInstalled = false

    /// SceneKit's camera control owns the drag; clicks are picked by gesture
    /// recognizers that sit beside it (a click selects, a double click opens
    /// the node's seat).
    private func installPicking() {
        guard !pickingInstalled else { return }
        pickingInstalled = true
        let single = NSClickGestureRecognizer(target: self, action: #selector(handlePick(_:)))
        single.numberOfClicksRequired = 1
        let double = NSClickGestureRecognizer(target: self, action: #selector(handleOpen(_:)))
        double.numberOfClicksRequired = 2
        addGestureRecognizer(single)
        addGestureRecognizer(double)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installPicking()
    }

    @objc private func handlePick(_ g: NSClickGestureRecognizer) {
        pick(at: g.location(in: self), open: false)
    }

    @objc private func handleOpen(_ g: NSClickGestureRecognizer) {
        pick(at: g.location(in: self), open: true)
    }

    /// What was drawn is what is picked: the flat layer knows where each square and label is.
    private func pick(at local: NSPoint, open: Bool) {
        let p = CGPoint(x: local.x, y: bounds.height - local.y)
        if mode == .orbit {
            if let key = overlay.clusterAt(p) {
                Pong.log("graph deck: pick graph \(key)")
                onSelectGraph?(key)
            }
            return
        }
        if let id = overlay.nodeAt(p), !id.isEmpty {
            Pong.log("graph deck: \(open ? "open" : "pick") node \(id)")
            if open { onOpenSeat?(id) } else { onSelectNode?(id) }
            return
        }
        if !open { onSelectNode?(nil) }
    }
}

/// One step of the deck, for VoiceOver: a button that selects it.
final class DeckStepElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Tells the deck when a rendered frame moved the camera. A separate object: SceneKit calls it on
/// its own thread, and the view itself belongs to the main thread.
final class DeckRenderWatch: NSObject, SCNSceneRendererDelegate {
    var onChange: (() -> Void)?
    private let lock = NSLock()
    private var last = simd_float4x4()
    private var lastScale: Double = 0

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let pov = renderer.pointOfView else { return }
        let t = pov.presentation.simdWorldTransform
        let s = pov.presentation.camera?.orthographicScale ?? 0
        lock.lock()
        let moved = t != last || s != lastScale
        if moved { last = t; lastScale = s }
        lock.unlock()
        if moved { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
    }
}

// MARK: - The flat layer

/// Drawn in points over the deck, never textured: steps as 24 pt squares, edges, labels, the HUD
/// line, the registration marks and the Esper readout. Redrawn whenever the camera moves.
final class DeckOverlayView: NSView {
    struct Item {
        let id: String
        let world: SCNVector3
        let name: String
        let line2: String
        let status: PongStatus
        var lead = false
        var human = false
        var refused = false
        var selected = false
        /// A working, waiting or selected step's label always shows.
        var priority: Bool { selected || status == .working || status == .needsYou }
    }

    struct Link {
        let from: String
        let to: String
        let points: [SCNVector3]
        let color: NSColor
        let dashed: Bool
        let label: String
    }

    struct Tag {
        let world: SCNVector3
        let text: String
        var eyebrow = false
        /// Ends at its point instead of centring on it.
        var right = false
    }

    struct Cluster {
        let key: String
        let world: SCNVector3
        let radius: CGFloat
        let title: String
        let line2: String
        let status: PongStatus
        let dots: [(SCNVector3, PongStatus)]
        let waiting: Bool
        let selected: Bool
    }

    struct Model {
        var items: [Item] = []
        var links: [Link] = []
        var tags: [Tag] = []
        var clusters: [Cluster] = []
        var hud = ""
    }

    var model = Model() { didSet { needsDisplay = true } }
    var project: ((SCNVector3) -> CGPoint?)?
    var esperText: (() -> String)?
    var esperAlpha: CGFloat = 0

    private var nodeHits: [(String, CGRect)] = []
    private var clusterHits: [(String, CGPoint, CGFloat)] = []
    /// Where each step's square was last drawn (flipped layer points), for VoiceOver.
    private(set) var stepRects: [(String, CGRect)] = []

    /// A step is a 24 pt square.
    static let half: CGFloat = 12

    override var isFlipped: Bool { true }
    /// The camera owns the mouse; picking asks nodeAt / clusterAt.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func nodeAt(_ p: CGPoint) -> String? { nodeHits.last { $0.1.insetBy(dx: -4, dy: -4).contains(p) }?.0 }

    func clusterAt(_ p: CGPoint) -> String? {
        clusterHits.first { hypot(p.x - $0.1.x, p.y - $0.1.y) <= $0.2 + 8 }?.0
    }

    private var plain: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !plain { drawTexture() }
        drawMarks()
        nodeHits = []
        clusterHits = []
        edgeWords = []
        clusterLabels = []
        guard let project else { return }
        var at: [String: CGPoint] = [:]
        for it in model.items { if let p = project(it.world) { at[it.id] = p } }
        for l in model.links { drawLink(l, at: at) }
        if !plain { for it in model.items where it.status == .working { if let c = at[it.id] { drawGlow(c, ctx) } } }
        stepRects = []
        for it in model.items {
            guard let c = at[it.id] else { continue }
            drawStep(it, c)
            let r = CGRect(x: c.x - Self.half, y: c.y - Self.half, width: Self.half * 2, height: Self.half * 2)
            nodeHits.append((it.id, r))
            stepRects.append((it.id, r))
        }
        for c in model.clusters { drawCluster(c) }
        drawLabels(at: at)
        drawHUD()
    }

    // MARK: Pieces

    private func drawTexture() {
        Self.grain.setFill()
        bounds.fill(using: .sourceOver)
        Self.scanlines.setFill()
        bounds.fill(using: .sourceOver)
    }

    /// Registration marks at the corners: 1 pt, 12 pt arms, 6 pt in.
    private func drawMarks() {
        let arm: CGFloat = 12, inset: CGFloat = 6
        let r = bounds.insetBy(dx: inset, dy: inset)
        let p = NSBezierPath()
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] {
            p.move(to: CGPoint(x: x + sx * arm, y: y))
            p.line(to: CGPoint(x: x, y: y))
            p.line(to: CGPoint(x: x, y: y + sy * arm))
        }
        PongColor.mark.setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    private func drawLink(_ l: Link, at: [String: CGPoint]) {
        guard let project else { return }
        var pts = l.points.compactMap { project($0) }
        guard pts.count >= 2 else { return }
        if let a = at[l.from] { pts = Array(Self.trimEnd(Array(pts.reversed()), around: a, half: Self.half + 2).reversed()) }
        if let b = at[l.to] { pts = Self.trimEnd(pts, around: b, half: Self.half + 3) }
        guard pts.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.lineWidth = 1
        path.lineJoinStyle = .round
        if l.dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        l.color.setStroke()
        path.stroke()
        // the arrow, along the last few points of the line
        let tip = pts[pts.count - 1]
        var prev = pts[pts.count - 2]
        for p in pts.reversed().dropFirst() where hypot(tip.x - p.x, tip.y - p.y) >= 6 { prev = p; break }
        var ux = tip.x - prev.x, uy = tip.y - prev.y
        let len = max(0.001, hypot(ux, uy))
        ux /= len
        uy /= len
        let base = CGPoint(x: tip.x - ux * 7, y: tip.y - uy * 7)
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: CGPoint(x: base.x - uy * 3.5, y: base.y + ux * 3.5))
        arrow.line(to: CGPoint(x: base.x + uy * 3.5, y: base.y - ux * 3.5))
        arrow.close()
        l.color.withAlphaComponent(min(1, l.color.alphaComponent + 0.2)).setFill()
        arrow.fill()
        if !l.label.isEmpty { edgeWords.append((l.label, pts[pts.count / 2])) }
    }

    /// An edge's outcome words, placed with the labels so they never sit on one.
    private var edgeWords: [(String, CGPoint)] = []

    /// Cut a projected path where it enters a step's square, so the line stops at its edge.
    static func trimEnd(_ pts: [CGPoint], around c: CGPoint, half: CGFloat) -> [CGPoint] {
        func inside(_ p: CGPoint) -> Bool { max(abs(p.x - c.x), abs(p.y - c.y)) < half }
        var out = pts
        while out.count >= 2, inside(out[out.count - 1]) {
            let last = out.removeLast()
            let prev = out[out.count - 1]
            if !inside(prev) {
                var lo: CGFloat = 0, hi: CGFloat = 1
                for _ in 0..<14 {
                    let m = (lo + hi) / 2
                    if inside(CGPoint(x: prev.x + (last.x - prev.x) * m, y: prev.y + (last.y - prev.y) * m)) { hi = m } else { lo = m }
                }
                out.append(CGPoint(x: prev.x + (last.x - prev.x) * lo, y: prev.y + (last.y - prev.y) * lo))
                break
            }
        }
        return out
    }

    /// A working step glows: one colour, 1.6× the node, 35%.
    private func drawGlow(_ c: CGPoint, _ ctx: CGContext) {
        let colors = [PongColor.live.withAlphaComponent(0.35).cgColor, PongColor.live.withAlphaComponent(0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: Self.half * 0.5, endCenter: c, endRadius: Self.half * 1.6 * 1.2, options: [])
    }

    private func drawStep(_ it: Item, _ c: CGPoint) {
        let h = Self.half
        let r = CGRect(x: c.x - h, y: c.y - h, width: h * 2, height: h * 2)
        let fill: NSColor, stroke: NSColor
        var alpha: CGFloat = 1
        switch it.status {
        case .working: fill = PongColor.fogTeal; stroke = PongColor.live
        case .needsYou: fill = PongColor.tintYou; stroke = PongColor.you
        case .done, .paused: fill = PongColor.base; stroke = PongColor.textSecondary
        case .failed: fill = PongColor.base; stroke = PongColor.fail
        case .stale: fill = PongColor.base; stroke = PongColor.textSecondary; alpha = 0.6
        case .stopped: fill = PongColor.base; stroke = PongColor.textTertiary
        case .pending: fill = PongColor.base; stroke = it.lead ? PongColor.textTertiary : PongColor.control
        }
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        fill.setFill()
        path.fill()
        stroke.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1.5
        if it.status == .stale { path.setLineDash([1.5, 2.5], count: 2, phase: 0) }
        path.stroke()
        switch it.status {
        case .done: symbol("checkmark", PongColor.textSecondary, in: r)
        case .failed: symbol("xmark", PongColor.fail, in: r)
        case .paused: symbol("pause.fill", PongColor.textSecondary, in: r)
        default:
            if it.lead { symbol("person.2.fill", PongColor.textTertiary, in: r, size: 9) }
            else if it.human { symbol("person.fill", stroke.withAlphaComponent(alpha), in: r, size: 10) }
        }
        if it.status == .needsYou {
            // ◆ above
            let d = NSBezierPath()
            let top = CGPoint(x: c.x, y: r.minY - 13)
            d.move(to: top)
            d.line(to: CGPoint(x: c.x + 4, y: top.y + 4))
            d.line(to: CGPoint(x: c.x, y: top.y + 8))
            d.line(to: CGPoint(x: c.x - 4, y: top.y + 4))
            d.close()
            PongColor.you.setFill()
            d.fill()
        }
        if it.refused {
            // a refusal is never hidden
            PongColor.fail.setFill()
            NSBezierPath(ovalIn: CGRect(x: r.minX - 3, y: r.minY - 3, width: 6, height: 6)).fill()
        }
        if it.selected { ticks(r.insetBy(dx: -6, dy: -6)) }
    }

    /// Selection: corner ticks 6 pt out, in text.primary. Never a glow: glow means live.
    private func ticks(_ r: CGRect) {
        let a: CGFloat = 5
        let p = NSBezierPath()
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] {
            p.move(to: CGPoint(x: x + sx * a, y: y))
            p.line(to: CGPoint(x: x, y: y))
            p.line(to: CGPoint(x: x, y: y + sy * a))
        }
        PongColor.textPrimary.setStroke()
        p.lineWidth = 1.5
        p.stroke()
    }

    private func drawCluster(_ c: Cluster) {
        guard let project, let center = project(c.world) else { return }
        let edge = project(SCNVector3(c.world.x + c.radius, 0, c.world.z)).map { hypot($0.x - center.x, $0.y - center.y) } ?? 30
        let edgeZ = project(SCNVector3(c.world.x, 0, c.world.z + c.radius)).map { hypot($0.x - center.x, $0.y - center.y) } ?? edge
        let pr = max(edge, edgeZ)
        for (w, st) in c.dots {
            guard let p = project(w) else { continue }
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            (st == .working ? PongColor.fogTeal : (st == .needsYou ? PongColor.tintYou : PongColor.base)).setFill()
            path.fill()
            st.color.setStroke()
            path.lineWidth = 1.25
            path.stroke()
        }
        if c.waiting {
            let d = NSBezierPath()
            d.move(to: CGPoint(x: center.x, y: center.y - 6))
            d.line(to: CGPoint(x: center.x + 6, y: center.y))
            d.line(to: CGPoint(x: center.x, y: center.y + 6))
            d.line(to: CGPoint(x: center.x - 6, y: center.y))
            d.close()
            PongColor.you.setFill()
            d.fill()
        }
        if c.selected { ticks(CGRect(x: center.x - pr - 6, y: center.y - edgeZ - 6, width: (pr + 6) * 2, height: (edgeZ + 6) * 2)) }
        // its label under the ring, placed with the others
        let lead = c.selected || c.waiting || c.status == .working
        var lines = [NSAttributedString(string: c.title, attributes: labelAttrs(PongType.sf(11, .medium), lead ? PongColor.textPrimary : PongColor.textSecondary))]
        if lead || c.status == .failed {
            lines.append(NSAttributedString(string: c.line2, attributes: labelAttrs(PongType.sf(11), c.status.color == PongColor.textTertiary ? PongColor.textSecondary : c.status.color)))
        }
        clusterLabels.append((c.key, lines, labelRect(lines, centerX: center.x, top: center.y + edgeZ + 6, maxW: 150), lead))
        clusterHits.append((c.key, center, pr))
    }

    /// A cluster's label waiting for its place: key, lines, where, and whether it always shows.
    private var clusterLabels: [(String, [NSAttributedString], CGRect, Bool)] = []

    private func labelAttrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: para]
    }

    private func labelRect(_ lines: [NSAttributedString], centerX: CGFloat, top: CGFloat, maxW: CGFloat = 200) -> CGRect {
        let w = min(maxW, lines.map { ceil($0.size().width) }.max() ?? 0) + 12
        return CGRect(x: centerX - w / 2, y: top, width: w, height: CGFloat(lines.count) * 14 + 4)
    }

    /// 11/14 SF Medium on a void chip at 70%.
    private func drawLabel(_ lines: [NSAttributedString], in r: CGRect) {
        PongColor.void.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        var y = r.minY + 2
        for s in lines {
            s.draw(with: CGRect(x: r.minX + 6, y: y, width: r.width - 12, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += 14
        }
    }

    /// Labels under the steps: the ones that matter first, then the loop tags, then a quiet
    /// label only where it fits.
    private func drawLabels(at: [String: CGPoint]) {
        var placed: [CGRect] = []
        let squares = at.values.map { CGRect(x: $0.x - Self.half - 1, y: $0.y - Self.half - 1, width: Self.half * 2 + 2, height: Self.half * 2 + 2) }
        // a question first, then a step at work, then the selected one: when two neighbours' words would
        // sit on each other, the later one keeps its name and drops its second line
        let rank: (Item) -> Int = { $0.status == .needsYou ? 0 : ($0.status == .working ? 1 : 2) }
        let first = model.items.filter { $0.priority }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map { $0.element }
        let rest = model.items.filter { !$0.priority }
        func place(_ it: Item) {
            guard let c = at[it.id] else { return }
            var lines = [NSAttributedString(string: it.name, attributes: labelAttrs(PongType.sf(11, .medium),
                                                                                    it.priority || it.lead ? PongColor.textPrimary : PongColor.textSecondary))]
            if (it.priority || it.lead) && !it.line2.isEmpty {
                let color: NSColor = it.status == .needsYou ? PongColor.you : (it.status == .working ? PongColor.live : PongColor.textSecondary)
                lines.append(NSAttributedString(string: it.line2, attributes: labelAttrs(PongType.sf(11), color)))
            }
            var r = labelRect(lines, centerX: c.x, top: c.y + Self.half + 6)
            if it.priority, lines.count > 1, placed.contains(where: { $0.intersects(r) }) {
                lines.removeLast()
                r = labelRect(lines, centerX: c.x, top: c.y + Self.half + 6)
            }
            if !it.priority && (placed.contains { $0.intersects(r) } || squares.contains { $0.intersects(r) }) { return }
            placed.append(r)
            drawLabel(lines, in: r)
            nodeHits.append((it.id, r))
        }
        first.forEach(place)
        let rings = clusterHits.map { CGRect(x: $0.1.x - $0.2, y: $0.1.y - $0.2, width: $0.2 * 2, height: $0.2 * 2) }
        func placeCluster(_ l: (String, [NSAttributedString], CGRect, Bool)) {
            if !l.3 && (placed.contains { $0.intersects(l.2) } || rings.contains { $0.intersects(l.2) }) { return }
            placed.append(l.2)
            drawLabel(l.1, in: l.2)
        }
        clusterLabels.filter { $0.3 }.forEach(placeCluster)
        // every step's name before an edge's words: the words give way when they would hide a name
        rest.forEach(place)
        for (text, p) in edgeWords {
            let r = tagRect(Tag(world: SCNVector3Zero, text: text), at: p)
            if placed.contains(where: { $0.intersects(r) }) || squares.contains(where: { $0.intersects(r) }) { continue }
            placed.append(r)
            chip(text, at: p, mono: true, color: PongColor.textSecondary)
        }
        for t in model.tags {
            guard let p = project?(t.world) else { continue }
            let r = tagRect(t, at: p)
            if !t.eyebrow && (placed.contains { $0.intersects(r) } || squares.contains { $0.intersects(r) }) { continue }
            placed.append(r)
            drawTag(t, at: p)
        }
        clusterLabels.filter { !$0.3 }.forEach(placeCluster)
    }

    private func tagRect(_ t: Tag, at p: CGPoint) -> CGRect {
        let w = t.eyebrow ? ceil(PongType.eyebrowString(t.text).size().width)
            : ceil(NSAttributedString(string: t.text, attributes: [.font: PongTheme.mono(11, weight: .regular)]).size().width) + 10
        return CGRect(x: t.right ? p.x - w : p.x - w / 2, y: p.y - 8, width: w, height: 16)
    }

    private func drawTag(_ t: Tag, at p: CGPoint) {
        if t.eyebrow {
            let s = PongType.eyebrowString(t.text, color: PongColor.textSecondary)
            let w = ceil(s.size().width)
            s.draw(at: CGPoint(x: t.right ? p.x - w : p.x - w / 2, y: p.y - 7))
        } else {
            chip(t.text, at: p, mono: true, color: PongColor.textTertiary)
        }
    }

    private func chip(_ text: String, at p: CGPoint, mono: Bool, color: NSColor) {
        let s = NSAttributedString(string: text, attributes: [.font: mono ? PongTheme.mono(11, weight: .regular) : PongType.sf(11), .foregroundColor: color])
        let sz = s.size()
        let r = CGRect(x: p.x - ceil(sz.width) / 2 - 5, y: p.y - 8, width: ceil(sz.width) + 10, height: 16)
        PongColor.void.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        s.draw(at: CGPoint(x: r.minX + 5, y: r.minY + (16 - sz.height) / 2))
    }

    /// The HUD line top left; the Esper readout bottom left while the deck zooms.
    private func drawHUD() {
        if !model.hud.isEmpty {
            let s = NSAttributedString(string: model.hud, attributes: [.font: PongTheme.mono(12, weight: .medium),
                                                                       .foregroundColor: PongColor.textSecondary, .kern: 0.6])
            s.draw(at: CGPoint(x: 18, y: 16))
        }
        if esperAlpha > 0.01, let text = esperText?() {
            let s = NSAttributedString(string: text, attributes: [.font: PongTheme.mono(11, weight: .regular),
                                                                  .foregroundColor: PongColor.textTertiary.withAlphaComponent(esperAlpha)])
            s.draw(at: CGPoint(x: 18, y: bounds.height - 30))
        }
    }

    private static var symbols: [String: NSImage] = [:]

    private func symbol(_ name: String, _ color: NSColor, in r: CGRect, size: CGFloat = 11) {
        let key = "\(name)|\(color.description)|\(size)"
        let img: NSImage
        if let cached = Self.symbols[key] {
            img = cached
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))
            img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
            Self.symbols[key] = img
        }
        let s = img.size
        img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Scanlines: one device pixel of light every three, white 3%.
    private static let scanlines: NSColor = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<3 {
            for x in 0..<2 { rep.setColor(NSColor(white: 1, alpha: y == 0 ? 0.03 : 0), atX: x, y: y) }
        }
        let img = NSImage(size: NSSize(width: 1, height: 1.5))
        img.addRepresentation(rep)
        return NSColor(patternImage: img)
    }()

    /// Grain: still one-colour noise, a 128 px tile at 2x, fixed seed, white 3%.
    private static let grain: NSColor = {
        let n = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var seed: UInt32 = 0x9E3779B9
        for y in 0..<n {
            for x in 0..<n {
                seed = seed &* 1664525 &+ 1013904223
                rep.setColor(NSColor(white: 1, alpha: CGFloat(seed >> 24) / 255 * 0.06), atX: x, y: y)
            }
        }
        let img = NSImage(size: NSSize(width: n / 2, height: n / 2))
        img.addRepresentation(rep)
        return NSColor(patternImage: img)
    }()
}

// MARK: - Geometry (the room's lines)

enum GraphShapes {
    static func lineMaterial(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.emission.contents = c
        m.lightingModel = .constant
        m.isDoubleSided = true
        return m
    }

    static func circle(radius: CGFloat, segments: Int, dashed: Bool = false) -> SCNGeometry {
        ellipse(rx: radius, rz: radius, segments: segments, dashed: dashed)
    }

    static func ellipse(rx: CGFloat, rz: CGFloat, segments: Int, dashed: Bool, fraction: CGFloat = 1) -> SCNGeometry {
        var lv: [SCNVector3] = []
        let n = max(8, segments)
        let upto = Int((CGFloat(n) * max(0, min(1, fraction))).rounded())
        for i in 0..<upto {
            if dashed && i % 2 == 1 { continue }
            let a0 = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(n) * .pi * 2
            let a1 = -CGFloat.pi / 2 + CGFloat(i + 1) / CGFloat(n) * .pi * 2
            lv += [SCNVector3(cos(a0) * rx, 0, sin(a0) * rz), SCNVector3(cos(a1) * rx, 0, sin(a1) * rz)]
        }
        return lines(lv)
    }

    static func lines(_ pts: [SCNVector3]) -> SCNGeometry {
        var idx: [Int32] = []
        for i in 0..<pts.count { idx.append(Int32(i)) }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pts)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
    }
}

// MARK: - The room's textures, cached

enum GraphTextures {
    private static var cache: [String: NSImage] = [:]

    static func clear() { cache.removeAll() }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let i = cache[key] { return i }
        let i = make()
        cache[key] = i
        return i
    }

    /// The deck's dots.
    static func grid() -> NSImage {
        cached("G|night") {
            let size = NSSize(width: 64, height: 64)
            let img = NSImage(size: size)
            img.lockFocus()
            PongColor.base.withAlphaComponent(0.72).setFill()
            NSRect(origin: .zero, size: size).fill()
            PongColor.mark.setFill()
            NSBezierPath(ovalIn: NSRect(x: 31, y: 31, width: 3, height: 3)).fill()
            img.unlockFocus()
            return img
        }
    }

    /// The deck's room: void above, a teal haze at the middle, a warm floor (design-language.md §2.9).
    static func fog() -> NSImage {
        cached("F|night") {
            let size = NSSize(width: 8, height: 512)
            let img = NSImage(size: size)
            img.lockFocus()
            let g = NSGradient(colorsAndLocations:
                (NSColor(srgbRed: 0x20 / 255.0, green: 0x21 / 255.0, blue: 0x1D / 255.0, alpha: 1), 0.0),
                (NSColor(srgbRed: 0x09 / 255.0, green: 0x18 / 255.0, blue: 0x1D / 255.0, alpha: 1), 0.45),
                (PongColor.void, 1.0))
            g?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
            img.unlockFocus()
            return img
        }
    }
}
