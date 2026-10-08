import AppKit

/// The island, as a helper of this app rather than a second app to find.
///
/// It stays a separate process on purpose: it is an accessory app whose whole
/// job is a borderless panel pinned to the notch, with its own activation
/// policy and window level. Folding that into the map process would put two
/// unrelated window-server jobs in one place, and the panel's tricks — never
/// taking key on hover, passing clicks through outside its silhouette — are
/// exactly the kind of thing that gets broken by sharing a process with a
/// normal windowed app.
///
/// What it should NOT be is a thing the person launches themselves. So it ships inside
/// this bundle, comes up with the app, and goes down with it.
enum IslandHelper {
    static let bundleID = "com.owi.pongisland"

    /// Where the helper lives inside us. Nil in a dev run from a loose binary,
    /// which is why every caller treats absence as "nothing to do" rather than
    /// an error.
    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PongIsland.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    /// Bring the island up if it is not already there.
    ///
    /// Idempotent by design: opening CyberPong twice, or a relaunch after an
    /// install, must not leave two islands fighting over the same notch.
    static func ensureRunning() {
        guard running.isEmpty else {
            Pong.log("island helper already running")
            return
        }
        guard let url = bundledURL else {
            Pong.log("island helper not in bundle — skipping (dev build?)")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false           // it is an accessory; it must not steal focus
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err {
                Pong.log("island helper failed to start: \(err.localizedDescription)")
            } else {
                Pong.log("island helper started from \(url.path)")
            }
        }
    }

    /// Ask the island to open itself.
    ///
    /// Hovering now only opens the island on the real camera cutout, which is a
    /// small target to hit on purpose — it stopped the island opening every
    /// time someone reached for a menu. This is the deliberate way in, from the
    /// map toolbar's Island pill.
    ///
    /// `ensureRunning()` first, because a dead helper cannot answer a
    /// notification and the pill going nowhere would read as a broken button
    /// rather than a missing process. It is idempotent, so a live island just
    /// logs and carries on.
    ///
    /// Same channel and conventions as `Pong.frontSeat` in the island
    /// (`island/PongIsland.swift`), which is island → app; this is app →
    /// island.
    static func expand() {
        ensureRunning()
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.owi.cyberpong.expandIsland"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        Pong.log("island expand requested")
    }

    /// Take the island down with us.
    ///
    /// Terminate rather than kill: the island has no unsaved state, but it does
    /// own a panel, and asking it to go lets AppKit tear that down properly.
    /// Agent panes are tmux and are entirely unaffected either way.
    static func stop() {
        let apps = running
        guard !apps.isEmpty else { return }
        for app in apps { app.terminate() }
        Pong.log("island helper asked to stop (\(apps.count))")
    }
}
