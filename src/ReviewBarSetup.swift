import AppKit

/// The write path for a bar — the questions are asked elsewhere.
///
/// This used to be a nine-field floating window, and that window is retired:
/// it was the CLI interview transcribed into text fields, it asked in schema
/// words ("Short id (file name)", "min mean"), and being a stray
/// `NSWindowController` it could sit behind the app where nobody ever found it.
/// `GauntletSheet` asks the questions now, on the panel.
///
/// What survives is the part that was right: answers go to the same builder the
/// CLI uses (`review create` → `run_answers`), so the app is a way of asking
/// rather than a second opinion about what a bar is, and every refusal still
/// applies — nobody grades their own work, and a bar needs something to point
/// at.
enum ReviewBarSetup {
    enum Outcome {
        case success(barPath: String, heldByNobody: Bool)
        /// Carries what the engine actually said, so a refusal reaches the
        /// person in the engine's own words rather than as "something failed".
        case failure(String)
    }

    /// Write a bar from an answers dict.
    ///
    /// Through the CLI on purpose: it is the engine, and going around it would
    /// put two things in charge of what a valid bar is.
    static func create(answers: [String: Any], session: String) -> Outcome {
        guard let data = try? JSONSerialization.data(withJSONObject: answers),
              let json = String(data: data, encoding: .utf8) else {
            return .failure("CyberPong couldn't read the answers.")
        }
        let tmp = NSTemporaryDirectory() + "pong-review-\(UUID().uuidString).json"
        do {
            try json.write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            return .failure("CyberPong couldn't write the answers — \(error.localizedDescription)")
        }
        let out = Pong.sh("""
        \(SessionArchive.pongPrefix())
        python3 -m pong.cli.main -s \(session) review create --answers '\(tmp)' 2>&1
        """)
        try? FileManager.default.removeItem(atPath: tmp)

        guard out.contains("\"bar_path\"") else {
            // Predictable refusals are caught in the sheet before submission;
            // anything reaching here is the engine or the CLI failing, and its
            // first line is the only honest thing to show.
            let first = out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "no output"
            return .failure("CyberPong couldn't write the bar — \(first)")
        }
        let path = (try? JSONSerialization.jsonObject(with: Data(out.utf8)))
            .flatMap { ($0 as? [String: Any])?["bar_path"] as? String } ?? ""
        Pong.log("bar written: \(path.isEmpty ? "(path unread)" : path)")
        return .success(barPath: path, heldByNobody: out.contains("\"held_by\": []"))
    }

    /// Ask Research to go and find what good looks like.
    ///
    /// A real job on the real road — c1's architecture is not bypassed just
    /// because a button started it; the human clicking here is the human
    /// action. Research files candidates and a person confirms, which is the
    /// standing rule for anything Research brings back.
    static func fileResearchJob(goal: String, session: String) -> Bool {
        let task = """
        RESEARCH — find the best in class for: \(goal)

        Look on X, GitHub, Reddit and the open web. Bring back concrete examples
        a reviewer could point at — links, repos, screenshots, posts — and say
        for each WHY it is good, in one line.

        File them as candidates. Do not adopt anything and do not change any bar:
        a person confirms which one becomes the anchor.
        """
        let tmp = NSTemporaryDirectory() + "pong-research-\(UUID().uuidString).md"
        try? task.write(toFile: tmp, atomically: true, encoding: .utf8)
        // PONG_SEAT unset on purpose. The control plane infers who is assigning
        // from the environment, so a stray seat id would make this look like one
        // seat routing to another and the flow graph would refuse it — correctly,
        // since Engineering may not assign Research. This is the human's action,
        // and it has to look like one.
        let out = Pong.sh("""
        \(SessionArchive.pongPrefix())
        unset PONG_SEAT
        python3 -m pong.cli.main -s \(session) job create --worker w10 --file '\(tmp)' 2>&1
        """)
        try? FileManager.default.removeItem(atPath: tmp)
        Pong.log("gauntlet research job: \(out.prefix(200))")
        return out.contains("job_id=")
    }
}
