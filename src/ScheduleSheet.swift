import AppKit

/// New schedule / Edit schedule: one sheet in the new look (design-language.md §3, Sheet),
/// replacing the Cron manager's list window and its alert form. What it's called, what the
/// AI does each time, when, which AI, on or off. Saved to the same schedule file.
final class ScheduleSheet: PongSheet, NSTextViewDelegate {
    private let team: String
    private var job: CronSchedule.Job?
    private var onDone: (() -> Void)?

    private let nameField = NSTextField()
    private let taskView = NSTextView()
    private let taskScroll = NSScrollView()
    private let taskHint = PongUI.label("e.g. Check what's waiting on me and list it in three lines",
                                        PongType.body, PongColor.textTertiary)
    private let whenPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let everyField = NSTextField()
    private let everyUnit = PongUI.label("", PongType.body, PongColor.textSecondary)
    private let timePicker = NSDatePicker()
    private let whoPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onSwitch = NSSwitch()
    private let errorLine = PongUI.label("", PongType.secondary, PongColor.fail)
    private let saveBtn = PongButton(title: "Save", style: .primary, size: .large)
    private let cancelBtn = PongButton(title: "Cancel", style: .secondary, size: .large)
    private let deleteBtn = PongButton(title: "Delete…", style: .quiet, size: .large)

    private enum When: Int { case minutes = 0, hours, daily }

    /// - Parameters:
    ///   - job: the schedule to edit; nil for a new one on `team`.
    static func present(team: String, job: CronSchedule.Job?, owner: String? = nil, on parent: NSWindow?, onDone: @escaping () -> Void) {
        let s = ScheduleSheet(team: team, job: job)
        s.onDone = onDone
        s.build()
        if job == nil, let owner, let i = s.whoPop.itemArray.firstIndex(where: { ($0.representedObject as? String) == owner }) {
            s.whoPop.selectItem(at: i)
        }
        s.present(on: parent)
        s.window.makeFirstResponder(job == nil ? s.nameField : s.taskView)
    }

    private init(team: String, job: CronSchedule.Job?) {
        self.team = team
        self.job = job
        super.init(width: 520, height: 470)
    }

    private func field(_ f: NSTextField, placeholder: String) {
        f.font = PongType.body
        f.textColor = PongColor.textPrimary
        f.drawsBackground = false
        f.isBezeled = false
        f.focusRingType = .none
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: PongType.body, .foregroundColor: PongColor.textTertiary])
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
    }

    /// A field sits in its own box (the fill and the 1 pt edge), inset so the text has room.
    private func place(_ f: NSTextField, in r: NSRect) {
        let box = NSView(frame: r)
        box.wantsLayer = true
        box.layer?.backgroundColor = PongColor.field.cgColor
        box.layer?.cornerRadius = PongRadius.control
        box.layer?.borderWidth = 1
        box.layer?.borderColor = PongColor.control.cgColor
        content.addSubview(box)
        f.frame = r.insetBy(dx: 8, dy: 5)
        content.addSubview(f)
        boxes[ObjectIdentifier(f)] = box
    }

    private var boxes: [ObjectIdentifier: NSView] = [:]

    private func eyebrow(_ s: String, y: CGFloat, x: CGFloat = 24) {
        let e = PongUI.eyebrow(s)
        e.frame = NSRect(x: x, y: y, width: 240, height: 16)
        content.addSubview(e)
    }

    private func build() {
        let W: CGFloat = 520, pad: CGFloat = 24
        let teamName = SchedulesPageView.teamName(team)
        let title = PongUI.label(job == nil ? "What should run on its own?" : "Edit “\(job!.name)”", PongType.question, PongColor.textPrimary)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: pad, y: 24, width: W - pad * 2, height: 24)
        content.addSubview(title)
        let sub = PongUI.label("For \(teamName). At set times, one of its AIs gets this task.", PongType.secondary, PongColor.textSecondary)
        sub.frame = NSRect(x: pad, y: 52, width: W - pad * 2, height: 16)
        content.addSubview(sub)

        // name
        eyebrow("Name", y: 84)
        field(nameField, placeholder: "Morning check")
        nameField.stringValue = job?.name ?? ""
        place(nameField, in: NSRect(x: pad, y: 104, width: W - pad * 2, height: 28))
        nameField.setAccessibilityLabel("Name")

        // the task
        eyebrow("What it does each time", y: 146)
        taskView.font = PongType.body
        taskView.textColor = PongColor.textPrimary
        taskView.backgroundColor = PongColor.field
        taskView.insertionPointColor = PongColor.live
        taskView.isRichText = false
        taskView.allowsUndo = true
        taskView.textContainerInset = NSSize(width: 6, height: 8)
        taskView.delegate = self
        taskView.string = job?.task ?? ""
        taskView.setAccessibilityLabel("What it does each time")
        taskScroll.documentView = taskView
        taskScroll.hasVerticalScroller = true
        taskScroll.autohidesScrollers = true
        taskScroll.drawsBackground = true
        taskScroll.backgroundColor = PongColor.field
        taskScroll.borderType = .noBorder
        taskScroll.wantsLayer = true
        taskScroll.layer?.cornerRadius = PongRadius.control
        taskScroll.layer?.borderWidth = 1
        taskScroll.layer?.borderColor = PongColor.control.cgColor
        taskScroll.frame = NSRect(x: pad, y: 166, width: W - pad * 2, height: 96)
        taskView.frame = NSRect(x: 0, y: 0, width: W - pad * 2, height: 96)
        taskView.autoresizingMask = [.width]
        content.addSubview(taskScroll)
        taskHint.frame = NSRect(x: pad + 11, y: 174, width: W - pad * 2 - 22, height: 18)
        taskHint.isHidden = !taskView.string.isEmpty
        content.addSubview(taskHint)

        // when
        eyebrow("When", y: 278)
        whenPop.addItems(withTitles: ["Every few minutes", "Every few hours", "Every day at"])
        whenPop.target = self
        whenPop.action = #selector(whenChanged)
        PongTheme.stylePopUp(whenPop)
        whenPop.frame = NSRect(x: pad - 2, y: 298, width: 200, height: 28)
        content.addSubview(whenPop)
        field(everyField, placeholder: "15")
        everyField.alignment = .right
        place(everyField, in: NSRect(x: pad + 210, y: 298, width: 64, height: 28))
        everyField.setAccessibilityLabel("How many")
        everyUnit.frame = NSRect(x: pad + 282, y: 304, width: 80, height: 18)
        content.addSubview(everyUnit)
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.isBezeled = false
        timePicker.drawsBackground = true
        timePicker.backgroundColor = PongColor.field
        timePicker.textColor = PongColor.textPrimary
        timePicker.font = PongType.body
        timePicker.frame = NSRect(x: pad + 210, y: 300, width: 110, height: 24)
        timePicker.setAccessibilityLabel("Time of day")
        content.addSubview(timePicker)

        // who, and on/off
        eyebrow("Who does it", y: 342)
        for seat in SchedulesPageView.seats(for: team) {
            whoPop.addItem(withTitle: seat.id == "c1" ? "The Lead" : seat.title)
            whoPop.lastItem?.representedObject = seat.id
        }
        if let j = job, let i = whoPop.itemArray.firstIndex(where: { ($0.representedObject as? String) == j.ownerId }) {
            whoPop.selectItem(at: i)
        }
        PongTheme.stylePopUp(whoPop)
        whoPop.frame = NSRect(x: pad - 2, y: 362, width: 240, height: 28)
        content.addSubview(whoPop)
        eyebrow("On", y: 342, x: W - pad - 60)
        onSwitch.state = (job?.enabled ?? true) ? .on : .off
        onSwitch.frame = NSRect(x: W - pad - 44, y: 364, width: 44, height: 24)
        onSwitch.setAccessibilityLabel("Schedule on")
        content.addSubview(onSwitch)

        errorLine.frame = NSRect(x: pad, y: 398, width: W - pad * 2, height: 16)
        errorLine.isHidden = true
        content.addSubview(errorLine)

        // footer: Delete… on the left when editing; Cancel and Save on the right
        content.addSubview(footerRule(y: 470 - 57))
        let fy: CGFloat = 470 - 44
        let sw = saveBtn.intrinsicContentSize.width, cw = cancelBtn.intrinsicContentSize.width
        saveBtn.frame = NSRect(x: W - pad - sw, y: fy, width: sw, height: 32)
        cancelBtn.frame = NSRect(x: W - pad - sw - 8 - cw, y: fy, width: cw, height: 32)
        saveBtn.keyEquivalent = "\r"
        saveBtn.onPress = { [weak self] in self?.save() }
        cancelBtn.onPress = { [weak self] in self?.close() }
        content.addSubview(saveBtn)
        content.addSubview(cancelBtn)
        if job != nil {
            deleteBtn.frame = NSRect(x: pad - 12, y: fy, width: deleteBtn.intrinsicContentSize.width, height: 32)
            deleteBtn.onPress = { [weak self] in self?.confirmDelete() }
            content.addSubview(deleteBtn)
        }

        // the schedule's own when
        let j = job
        var when = When.minutes
        var n = 15
        if let j {
            if abs(j.intervalSec - 86_400) < 2 {
                when = .daily
            } else if j.intervalSec >= 3600, Int(j.intervalSec) % 3600 == 0 {
                when = .hours
                n = Int(j.intervalSec) / 3600
            } else {
                n = max(1, Int(j.intervalSec) / 60)
            }
        }
        whenPop.selectItem(at: when.rawValue)
        everyField.stringValue = "\(n)"
        let midnight = Calendar.current.startOfDay(for: Date())
        timePicker.dateValue = midnight.addingTimeInterval(j.map { abs($0.intervalSec - 86_400) < 2 ? $0.phaseSec : 7 * 3600 } ?? 7 * 3600)
        whenChanged()
    }

    func textDidChange(_ notification: Notification) {
        taskHint.isHidden = !taskView.string.isEmpty
    }

    @objc private func whenChanged() {
        let w = When(rawValue: whenPop.indexOfSelectedItem) ?? .minutes
        everyField.isHidden = w == .daily
        boxes[ObjectIdentifier(everyField)]?.isHidden = w == .daily
        everyUnit.isHidden = w == .daily
        timePicker.isHidden = w != .daily
        everyUnit.stringValue = w == .hours ? "hours" : "minutes"
        if w == .hours, let n = Int(everyField.stringValue), n > 24 { everyField.stringValue = "1" }
    }

    private func fail(_ s: String) {
        errorLine.stringValue = s
        errorLine.isHidden = false
        NSSound.beep()
    }

    private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = taskView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fail("Give it a name.") }
        guard !task.isEmpty else { return fail("Say what the AI should do each time.") }
        let w = When(rawValue: whenPop.indexOfSelectedItem) ?? .minutes
        var interval: TimeInterval = 86_400, phase: TimeInterval = 0, cadence = ""
        switch w {
        case .minutes, .hours:
            guard let n = Int(everyField.stringValue.trimmingCharacters(in: .whitespaces)), n > 0 else {
                return fail("How often? A whole number of \(w == .hours ? "hours" : "minutes").")
            }
            interval = TimeInterval(n * (w == .hours ? 3600 : 60))
            cadence = w == .hours ? "every \(n)h" : "every \(n)m"
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
            let h = c.hour ?? 7, m = c.minute ?? 0
            phase = TimeInterval(h * 3600 + m * 60)
            cadence = String(format: "daily %02d:%02d", h, m)
        }
        let owner = (whoPop.selectedItem?.representedObject as? String) ?? "c1"
        var j = job ?? CronSchedule.Job(id: "", name: name, task: task, cadence: cadence, intervalSec: interval,
                                        phaseSec: phase, ownerId: owner, enabled: true)
        let clockChanged = j.intervalSec != interval || j.phaseSec != phase
        j.name = name
        j.task = task
        j.cadence = cadence
        j.intervalSec = interval
        j.phaseSec = phase
        j.ownerId = owner
        j.enabled = onSwitch.state == .on
        // a new clock starts from its next slot, not from when the old one last fired
        if clockChanged { j.lastFired = 0 }
        CronSchedule.upsert(session: team, job: j)
        Toast.show(job == nil ? "“\(name)” is scheduled." : "Saved.")
        close()
        onDone?()
    }

    private func confirmDelete() {
        guard let j = job else { return }
        PongAlert.show(on: window, title: "Delete “\(j.name)”?", message: "It stops running. Nothing else changes.",
                       buttons: [.init("Delete", .destructive), .init("Keep it", .primary)], cancelIndex: 1) { [weak self] i in
            guard i == 0, let self else { return }
            let jobs = CronSchedule.load(session: self.team).filter { $0.id != j.id }
            CronSchedule.save(session: self.team, jobs: jobs)
            Toast.show("Deleted “\(j.name)”.")
            self.close()
            self.onDone?()
        }
    }

    @objc func cancelOperation(_ sender: Any?) { close() }
}
