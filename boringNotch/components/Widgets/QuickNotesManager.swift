//
//  QuickNotesManager.swift
//  boringNotch
//
//  Small notes (e.g. meeting notes) kept in the notch, saved to disk, with
//  options to add the note to Calendar or its tasks to Reminders.
//
//  Lines starting with "-", "*", "•", "[ ]" or "1." are treated as tasks.
//

import AppKit
import Combine
import Defaults
import EventKit
import Foundation

extension Defaults.Keys {
    static let quickNotesEnabled = Key<Bool>("quickNotesEnabled", default: true)
    static let quickNotesAlertMinutes = Key<Int>("quickNotesAlertMinutes", default: 10)
    static let quickNotesEventMinutes = Key<Int>("quickNotesEventMinutes", default: 60)
}

struct QuickNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String = ""
    var body: String = ""
    var createdAt = Date()
    var updatedAt = Date()
    var calendarEventDate: Date?
    var remindersAdded: Int = 0

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "New note" : firstLine
    }

    /// Task lines from the body, without their bullet.
    var tasks: [String] {
        body.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [ ] ", "- [x] ", "[ ] ", "[x] ", "☐ ", "- ", "* ", "• ", "– "] where line.hasPrefix(prefix) {
                let task = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return task.isEmpty ? nil : task
            }
            // "1. task" / "1) task"
            if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                let task = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return task.isEmpty ? nil : task
            }
            return nil
        }
    }
}

@MainActor
final class QuickNotesManager: ObservableObject {
    static let shared = QuickNotesManager()

    @Published private(set) var notes: [QuickNote] = []
    @Published var selectedID: UUID?

    private let store = EKEventStore()
    private var saveTask: Task<Void, Never>?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("BoringNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("notes.json")
    }()

    private init() {
        load()
    }

    var selected: QuickNote? {
        notes.first { $0.id == selectedID }
    }

    // MARK: - Editing

    @discardableResult
    func newNote() -> QuickNote {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM"
        let note = QuickNote(title: "Rapat \(formatter.string(from: Date()))")
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
        return note
    }

    func update(_ id: UUID, title: String? = nil, body: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if (title == nil || title == notes[index].title) && (body == nil || body == notes[index].body) { return }
        if let title { notes[index].title = title }
        if let body { notes[index].body = body }
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = notes.first?.id }
        scheduleSave()
    }

    // MARK: - Calendar / Reminders

    enum ExportError: LocalizedError {
        case noAccess(String)
        case noDefaultCalendar(String)
        case nothingToAdd

        var errorDescription: String? {
            switch self {
            case .noAccess(let app): return "No access to \(app). Allow it in System Settings → Privacy & Security → \(app)."
            case .noDefaultCalendar(let app): return "No default list in \(app). Open \(app) and create one first."
            case .nothingToAdd: return "Nothing to add."
            }
        }
    }

    /// Adds the note as a Calendar event with an alert.
    func addToCalendar(_ note: QuickNote, start: Date, durationMinutes: Int, alertMinutes: Int) async throws {
        guard try await requestAccess(.event) else { throw ExportError.noAccess("Calendars") }
        guard let calendar = store.defaultCalendarForNewEvents else { throw ExportError.noDefaultCalendar("Calendar") }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = note.displayTitle
        event.notes = note.body
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(max(5, durationMinutes) * 60))
        if alertMinutes > 0 {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMinutes * 60)))
        }
        try store.save(event, span: .thisEvent, commit: true)

        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index].calendarEventDate = start
            scheduleSave()
        }
    }

    /// Adds each task (or the whole note if it has no task lines) to Reminders.
    @discardableResult
    func addToReminders(_ note: QuickNote, due: Date?, withAlarm: Bool) async throws -> Int {
        guard try await requestAccess(.reminder) else { throw ExportError.noAccess("Reminders") }
        guard let list = store.defaultCalendarForNewReminders() else { throw ExportError.noDefaultCalendar("Reminders") }

        let titles = note.tasks.isEmpty ? [note.displayTitle] : note.tasks
        guard !titles.isEmpty else { throw ExportError.nothingToAdd }

        for title in titles {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = title
            reminder.notes = note.tasks.isEmpty ? note.body : "From note: \(note.displayTitle)"
            if let due {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                if withAlarm { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            try store.save(reminder, commit: false)
        }
        try store.commit()

        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index].remindersAdded += titles.count
            scheduleSave()
        }
        return titles.count
    }

    private func requestAccess(_ type: EKEntityType) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess || status == .writeOnly { return true }
        switch type {
        case .event: return try await store.requestFullAccessToEvents()
        case .reminder: return try await store.requestFullAccessToReminders()
        @unknown default: return false
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = (try? decoder.decode([QuickNote].self, from: data)) ?? []
        selectedID = notes.first?.id
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Keyboard input in the notch

/// The notch panel normally never takes keyboard focus (so it doesn't steal it
/// from the app you're using). While the Notes tab is open it may, so you can type.
enum NotchKeyboard {
    nonisolated(unsafe) static var allowsKeyboard = false

    @MainActor
    static func begin() {
        allowsKeyboard = true
    }

    /// Stops accepting keys and hands keyboard focus back to the app you were using.
    @MainActor
    static func end() {
        guard allowsKeyboard else { return }
        allowsKeyboard = false
        for window in NSApp.windows where window.isKeyWindow && (window is BoringNotchSkyLightWindow || window is BoringNotchWindow) {
            // Ordering out a key window makes it resign key; put it straight back.
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
    }
}
