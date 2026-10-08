import AppKit
import UserNotifications

/// Say when the person is needed (ux-review.md quick win 1): a Mac notification per new
/// question that opens it, the count on the Dock icon and in the menu bar. It reads the
/// shared GraphStore, so the count is the same number the sidebar shows.
final class Attention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Attention()

    /// The menu bar item shows the count beside the mark.
    var onCount: ((Int) -> Void)?

    private let notifiedKey = "attention.notified"
    private let finishedKey = "attention.finishedNotified"
    private var started = false
    private var authorized: Bool?

    func start() {
        guard !started else { return }
        started = true
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: GraphStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(changed),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        // the feed runs even with the window closed: slowly then, so the badge and notifications still move
        GraphStore.shared.start()
        update()
    }

    @objc private func changed() {
        update()
        notifyNew()
    }

    /// The Dock badge and the menu bar count.
    func update() {
        let n = GraphStore.shared.needsYouCount
        let dock = UserDefaults.standard.bool(forKey: "attention.noDockBadge") ? nil : (n > 0 ? "\(n)" : nil)
        if NSApp.dockTile.badgeLabel != dock { NSApp.dockTile.badgeLabel = dock }
        onCount?(n)
    }

    // MARK: Notifications

    private func ensureAuthorized(_ then: @escaping (Bool) -> Void) {
        if let a = authorized { then(a); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
            if let err { Pong.log("notifications: \(err.localizedDescription)") }
            DispatchQueue.main.async {
                self.authorized = ok
                then(ok)
            }
        }
    }

    private func notifyNew() {
        let st = GraphStore.shared
        guard st.loadedOnce, st.loadError.isEmpty else { return }
        let ud = UserDefaults.standard
        var seen = ud.dictionary(forKey: notifiedKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        let models = st.questionModels
        let open = Set(models.map { $0.key })
        // a question answered and asked again later is new again
        seen = seen.filter { open.contains($0.key) || now - $0.value < 3600 }
        var fresh: [QuestionModel] = []
        for q in models where seen[q.key] == nil {
            // a gate's plain words are on their way: wait for them (two minutes at most), so the
            // notification says the question a person reads, not the engine's first draft
            if firstPassDone && QuestionModel.holdNotification(q, now: now) { continue }
            seen[q.key] = now
            // the first read after a launch only learns what is already open
            if firstPassDone { fresh.append(q) }
        }
        var done = ud.dictionary(forKey: finishedKey) as? [String: Double] ?? [:]
        var finished: [GGraph] = []
        for g in st.finished where (g.finishedAt ?? 0) > now - 3600 {
            if done[g.key] == nil {
                done[g.key] = now
                if firstPassDone { finished.append(g) }
            }
        }
        done = done.filter { now - $0.value < 7 * 86_400 }
        ud.set(seen, forKey: notifiedKey)
        ud.set(done, forKey: finishedKey)
        firstPassDone = true
        guard !UIPreview.isOn else { return }
        if !ud.bool(forKey: "attention.noNotify") {
            for q in fresh.prefix(3) { post(question: q) }
        }
        if ud.bool(forKey: "attention.notifyFinished") {
            for g in finished.prefix(3) { post(finished: g) }
        }
    }

    private var firstPassDone = false

    private func post(question m: QuestionModel) {
        ensureAuthorized { ok in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = "Needs you · " + m.subject
            c.subtitle = m.origin
            // the question, then why in one line; the details stay in the app (a lock screen shows this)
            c.body = QuestionModel.notificationBody(m)
            if !UserDefaults.standard.bool(forKey: "attention.noSound") { c.sound = .default }
            c.userInfo = ["question": m.key, "graph": m.graphKey ?? "", "chat": m.chatKey ?? ""]
            c.threadIdentifier = m.graphKey ?? m.chatKey ?? m.key
            let r = UNNotificationRequest(identifier: "q-" + m.key, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(r) { err in
                if let err { Pong.log("notification failed: \(err.localizedDescription)") }
            }
        }
    }

    private func post(finished g: GGraph) {
        ensureAuthorized { ok in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = g.displayTitle
            c.body = g.plainStatus
            c.userInfo = ["graph": g.key]
            let r = UNNotificationRequest(identifier: "f-" + g.key, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(r) { _ in }
        }
    }

    /// Clicking a notification opens the question (or the graph).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["graph"] as? String ?? ""
        let isQuestion = info["question"] != nil
        DispatchQueue.main.async {
            if isQuestion {
                PanelController.shared.nextQuestion()
            } else if !key.isEmpty {
                PanelController.shared.openGraph(key)
            }
        }
        completionHandler()
    }

    /// While CyberPong is in front, the question is already on screen: no banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(NSApp.isActive ? [] : [.banner, .sound])
    }
}
