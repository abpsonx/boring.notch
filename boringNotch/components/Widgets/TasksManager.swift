//
//  TasksManager.swift
//  boringNotch
//
//  Two kinds of work:
//  • Routine ("Rutin"): jobs that happen every day (or on chosen weekdays).
//    Defined once; they show up unchecked again each day.
//  • Extra ("Tambahan"): one-off jobs that come and go. They stay until done.
//
//  Jobs with a time show a reminder around the closed notch when it's due,
//  with "Selesai" and "Tunda" actions. Saved to Application Support.
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let tasksEnabled = Key<Bool>("tasksEnabled", default: true)
    static let taskReminderSound = Key<Bool>("taskReminderSound", default: true)
    static let taskSnoozeMinutes = Key<Int>("taskSnoozeMinutes", default: 15)
}

struct RoutineTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// Minutes after midnight, nil = no specific time.
    var minuteOfDay: Int?
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var weekdays: Set<Int> = Set(1...7)

    var timeText: String? { minuteOfDay.map(TasksManager.format(minuteOfDay:)) }

    var scheduleText: String { Self.scheduleText(for: weekdays) }

    static let dayNames = ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"]   // weekday 1…7

    static func scheduleText(for weekdays: Set<Int>) -> String {
        if weekdays.count == 7 { return "Tiap hari" }
        if weekdays == Set(2...6) { return "Sen–Jum" }
        if weekdays == Set(2...7) { return "Sen–Sab" }
        // Mon-first order
        let order = [2, 3, 4, 5, 6, 7, 1]
        return order.filter { weekdays.contains($0) }.map { dayNames[$0 - 1] }.joined(separator: ", ")
    }
}

struct ExtraTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var due: Date?
    var createdAt = Date()
    var doneAt: Date?
}

struct TaskReminder: Identifiable, Equatable {
    let id: UUID          // task id
    let title: String
    let timeText: String
    let isRoutine: Bool
}

@MainActor
final class TasksManager: ObservableObject {
    static let shared = TasksManager()

    @Published private(set) var routines: [RoutineTask] = []
    @Published private(set) var extras: [ExtraTask] = []
    /// Routine ids done, per day ("yyyy-MM-dd").
    @Published private(set) var routineDone: [String: Set<UUID>] = [:]
    /// Reminder shown around the closed notch (auto-hides).
    @Published private(set) var banner: TaskReminder?
    /// Reminder waiting for "Selesai" / "Tunda" in the Tasks tab.
    @Published private(set) var pending: TaskReminder?
    @Published private(set) var today = Date()

    private var notified: [String: Date] = [:]      // "day|taskID" -> when shown
    private var snoozedUntil: [UUID: Date] = [:]
    private var timer: Timer?
    private var bannerTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("BoringNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("tasks.json")
    }()

    private init() {
        load()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 5
        tick()
    }

    // MARK: - Today

    var dayKey: String { Self.dayFormatter.string(from: today) }

    var todaysRoutines: [RoutineTask] {
        let weekday = Calendar.current.component(.weekday, from: today)
        return routines
            .filter { $0.weekdays.contains(weekday) }
            .sorted { ($0.minuteOfDay ?? Int.max, $0.title) < ($1.minuteOfDay ?? Int.max, $1.title) }
    }

    func isDone(_ routine: RoutineTask) -> Bool {
        routineDone[dayKey]?.contains(routine.id) ?? false
    }

    /// Open extras first (by due time), then the ones finished today.
    var visibleExtras: [ExtraTask] {
        let calendar = Calendar.current
        let open = extras.filter { $0.doneAt == nil }
            .sorted { ($0.due ?? .distantFuture, $0.createdAt) < ($1.due ?? .distantFuture, $1.createdAt) }
        let doneToday = extras.filter { $0.doneAt.map { calendar.isDate($0, inSameDayAs: today) } ?? false }
        return open + doneToday
    }

    var progress: (done: Int, total: Int) {
        let routinesToday = todaysRoutines
        let doneRoutines = routinesToday.filter { isDone($0) }.count
        let extrasToday = visibleExtras
        let doneExtras = extrasToday.filter { $0.doneAt != nil }.count
        return (doneRoutines + doneExtras, routinesToday.count + extrasToday.count)
    }

    func isOverdue(_ task: ExtraTask) -> Bool {
        guard task.doneAt == nil, let due = task.due else { return false }
        return due < Date()
    }

    func isOverdue(_ routine: RoutineTask) -> Bool {
        guard !isDone(routine), let minute = routine.minuteOfDay else { return false }
        return Self.minuteOfDay(Date()) > minute
    }

    // MARK: - Editing

    /// "09:00 Cek email" → routine at 09:00. Returns false if the title is empty.
    @discardableResult
    func addRoutine(from input: String, weekdays: Set<Int>) -> Bool {
        let (minute, title) = Self.parse(input)
        guard !title.isEmpty, !weekdays.isEmpty else { return false }
        routines.append(RoutineTask(title: title, minuteOfDay: minute, weekdays: weekdays))
        scheduleSave()
        return true
    }

    func updateRoutine(_ routine: RoutineTask) {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[index] = routine
        scheduleSave()
    }

    func addRoutine(_ routine: RoutineTask) {
        routines.append(routine)
        scheduleSave()
    }

    func deleteRoutine(_ id: UUID) {
        routines.removeAll { $0.id == id }
        scheduleSave()
    }

    func toggleRoutine(_ id: UUID) {
        var done = routineDone[dayKey] ?? []
        if done.contains(id) { done.remove(id) } else { done.insert(id) }
        routineDone[dayKey] = done
        if pending?.id == id { clearReminder() }
        scheduleSave()
    }

    /// "14:00 Kirim invoice" → extra job due today at 14:00 (tomorrow if that time passed).
    @discardableResult
    func addExtra(from input: String) -> Bool {
        let (minute, title) = Self.parse(input)
        guard !title.isEmpty else { return false }
        var due: Date?
        if let minute {
            let start = Calendar.current.startOfDay(for: Date())
            var date = start.addingTimeInterval(TimeInterval(minute * 60))
            if date < Date().addingTimeInterval(-60) { date = date.addingTimeInterval(86_400) }
            due = date
        }
        extras.append(ExtraTask(title: title, due: due))
        scheduleSave()
        return true
    }

    func toggleExtra(_ id: UUID) {
        guard let index = extras.firstIndex(where: { $0.id == id }) else { return }
        extras[index].doneAt = extras[index].doneAt == nil ? Date() : nil
        if pending?.id == id { clearReminder() }
        scheduleSave()
    }

    func deleteExtra(_ id: UUID) {
        extras.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearFinishedExtras() {
        extras.removeAll { $0.doneAt != nil }
        scheduleSave()
    }

    // MARK: - Reminder actions

    func completePending() {
        guard let reminder = pending else { return }
        if reminder.isRoutine { toggleRoutine(reminder.id) } else { toggleExtra(reminder.id) }
        clearReminder()
    }

    func snoozePending() {
        guard let reminder = pending else { return }
        snoozedUntil[reminder.id] = Date().addingTimeInterval(TimeInterval(max(5, Defaults[.taskSnoozeMinutes]) * 60))
        notified["\(dayKey)|\(reminder.id)"] = nil
        clearReminder()
    }

    func clearReminder() {
        pending = nil
        hideBanner()
    }

    func hideBanner() {
        bannerTask?.cancel()
        withAnimation(.smooth) { banner = nil }
    }

    // MARK: - Reminder engine

    private func tick() {
        let now = Date()
        if !Calendar.current.isDate(now, inSameDayAs: today) {
            today = now
            notified.removeAll()
            pruneHistory()
        }
        today = now
        guard Defaults[.tasksEnabled], banner == nil else { return }

        let nowMinute = Self.minuteOfDay(now)
        for routine in todaysRoutines where !isDone(routine) {
            guard let minute = routine.minuteOfDay, minute <= nowMinute, nowMinute - minute < 180 else { continue }
            if fireIfNeeded(id: routine.id, title: routine.title, timeText: routine.timeText ?? "", isRoutine: true) { return }
        }
        for task in extras where task.doneAt == nil {
            guard let due = task.due, due <= now, now.timeIntervalSince(due) < 6 * 3600 else { continue }
            let time = due.formatted(date: .omitted, time: .shortened)
            if fireIfNeeded(id: task.id, title: task.title, timeText: time, isRoutine: false) { return }
        }
    }

    private func fireIfNeeded(id: UUID, title: String, timeText: String, isRoutine: Bool) -> Bool {
        let key = "\(dayKey)|\(id)"
        if let until = snoozedUntil[id] {
            guard Date() >= until else { return false }
            snoozedUntil[id] = nil
        } else if notified[key] != nil {
            return false
        }
        notified[key] = Date()
        let reminder = TaskReminder(id: id, title: title, timeText: timeText, isRoutine: isRoutine)
        pending = reminder
        withAnimation(.smooth) { banner = reminder }
        if Defaults[.taskReminderSound] { NSSound(named: "Ping")?.play() }
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self.banner = nil }
        }
        return true
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var routines: [RoutineTask]
        var extras: [ExtraTask]
        var routineDone: [String: Set<UUID>]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else { return }
        routines = stored.routines
        extras = stored.extras
        routineDone = stored.routineDone
        pruneHistory()
    }

    private func pruneHistory() {
        // Keep 60 days of routine history; drop extras finished more than 7 days ago.
        let cutoff = Self.dayFormatter.string(from: Date().addingTimeInterval(-60 * 86_400))
        routineDone = routineDone.filter { $0.key >= cutoff }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        extras.removeAll { ($0.doneAt ?? .distantFuture) < weekAgo }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(Stored(routines: routines, extras: extras, routineDone: routineDone)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Helpers

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func format(minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// Splits "09:00 Cek email" / "9.30 Standup" / "Cek email" into (minute, title).
    static func parse(_ input: String) -> (Int?, String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: #"^(\d{1,2})[:.](\d{2})\s+"#, options: .regularExpression) else {
            return (nil, text)
        }
        let timePart = text[match].trimmingCharacters(in: .whitespaces)
        let numbers = timePart.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
        guard numbers.count == 2, numbers[0] < 24, numbers[1] < 60 else { return (nil, text) }
        return (numbers[0] * 60 + numbers[1], String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}
