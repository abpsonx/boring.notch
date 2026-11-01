//
//  QuickNotesView.swift
//  boringNotch
//
//  Notch tab: list of notes on the left, editor on the right, with
//  "Add to Calendar" and "Add tasks to Reminders" forms shown inline
//  (no popovers, so the notch stays open).
//

import Defaults
import SwiftUI

struct QuickNotesView: View {
    @ObservedObject var manager = QuickNotesManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NotesListColumn(manager: manager)
                .frame(width: 150)

            if let note = manager.selected {
                NoteEditor(note: note, manager: manager)
                    .id(note.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.title2)
                    Text("Catat isi rapat, ide, atau to-do")
                        .font(.caption)
                    Button("New note") { manager.newNote() }
                        .buttonStyle(.plain)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { NotchKeyboard.begin() }
        .onDisappear {
            NotchKeyboard.end()
            manager.save()
        }
    }
}

private struct NotesListColumn: View {
    @ObservedObject var manager: QuickNotesManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Notes")
                    .font(.caption.bold())
                    .foregroundStyle(.gray)
                Spacer()
                Button {
                    withAnimation(.smooth) { _ = manager.newNote() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("New note")
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    ForEach(manager.notes) { note in
                        let isSelected = note.id == manager.selectedID
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.displayTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(note.updatedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                                if note.calendarEventDate != nil { Image(systemName: "calendar") }
                                if note.remindersAdded > 0 { Image(systemName: "checklist") }
                            }
                            .font(.system(size: 9))
                            .foregroundStyle(.gray)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(isSelected ? 0.14 : 0.04))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { manager.selectedID = note.id }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                withAnimation(.smooth) { manager.delete(note.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NoteEditor: View {
    let note: QuickNote
    @ObservedObject var manager: QuickNotesManager

    enum Mode { case edit, calendar, reminders }

    @State private var title: String = ""
    @State private var text: String = ""
    @State private var mode: Mode = .edit
    @State private var status: String?
    @State private var isWorking = false
    enum Field { case title, body }
    @FocusState private var focus: Field?

    // Calendar form
    @State private var eventStart = QuickNoteDefaults.nextHour()
    @State private var eventMinutes = Defaults[.quickNotesEventMinutes]
    @State private var alertMinutes = Defaults[.quickNotesAlertMinutes]
    // Reminders form
    @State private var reminderDue = QuickNoteDefaults.endOfWorkday()
    @State private var reminderHasDue = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .focused($focus, equals: .title)
                    .onChange(of: title) { _, newValue in manager.update(note.id, title: newValue) }

                toolbarButton("calendar.badge.plus", help: "Add to Calendar", active: mode == .calendar) {
                    mode = mode == .calendar ? .edit : .calendar
                    status = nil
                }
                toolbarButton("checklist", help: "Add tasks to Reminders", active: mode == .reminders) {
                    mode = mode == .reminders ? .edit : .reminders
                    status = nil
                }
                toolbarButton("trash", help: "Delete note", active: false) {
                    withAnimation(.smooth) { manager.delete(note.id) }
                }
            }

            switch mode {
            case .edit: editor
            case .calendar: calendarForm
            case .reminders: remindersForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            title = note.title
            text = note.body
        }
        .onChange(of: focus) { oldValue, newValue in
            // Keep the notch open while typing, even if the pointer wanders off.
            if oldValue == nil && newValue != nil {
                SharingStateManager.shared.beginInteraction()
            } else if oldValue != nil && newValue == nil {
                SharingStateManager.shared.endInteraction()
            }
        }
        .onDisappear {
            if focus != nil { SharingStateManager.shared.endInteraction() }
        }
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
                .focused($focus, equals: .body)
                .onChange(of: text) { _, newValue in manager.update(note.id, body: newValue) }
                .onExitCommand { focus = nil }

            if text.isEmpty {
                Text("Tulis isi rapat…\n- baris diawali \"-\" jadi tugas untuk Reminders")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray.opacity(0.7))
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .overlay(alignment: .bottomTrailing) {
            if focus != nil {
                Button("Done") { focus = nil }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
                    .foregroundStyle(Color.black)
                    .padding(6)
            }
        }
    }

    // MARK: Calendar

    private var calendarForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Start")
                DatePicker("", selection: $eventStart, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Picker("Duration", selection: $eventMinutes) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                .frame(width: 150)
                Picker("Alert", selection: $alertMinutes) {
                    Text("None").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min before").tag($0) }
                }
                .frame(width: 170)
            }
            formFooter(actionTitle: "Add to Calendar") {
                try await manager.addToCalendar(note, start: eventStart, durationMinutes: eventMinutes, alertMinutes: alertMinutes)
                Defaults[.quickNotesEventMinutes] = eventMinutes
                Defaults[.quickNotesAlertMinutes] = alertMinutes
                return "Added to Calendar · \(eventStart.formatted(date: .abbreviated, time: .shortened))"
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .controlSize(.small)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    // MARK: Reminders

    private var remindersForm: some View {
        let tasks = currentTasks
        return VStack(alignment: .leading, spacing: 6) {
            Text(tasks.isEmpty
                 ? "No \"-\" task lines found: the note will be added as one reminder."
                 : "\(tasks.count) task(s): " + tasks.prefix(3).joined(separator: " · ") + (tasks.count > 3 ? " …" : ""))
                .lineLimit(2)
                .foregroundStyle(.gray)
            HStack(spacing: 8) {
                Toggle("Due", isOn: $reminderHasDue)
                    .toggleStyle(.checkbox)
                DatePicker("", selection: $reminderDue, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .disabled(!reminderHasDue)
            }
            formFooter(actionTitle: "Add to Reminders") {
                var snapshot = note
                snapshot.title = title
                snapshot.body = text
                let count = try await manager.addToReminders(snapshot, due: reminderHasDue ? reminderDue : nil, withAlarm: reminderHasDue)
                return "Added \(count) reminder\(count == 1 ? "" : "s")"
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .controlSize(.small)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private var currentTasks: [String] {
        var snapshot = note
        snapshot.body = text
        return snapshot.tasks
    }

    // MARK: Shared pieces

    private func formFooter(actionTitle: String, action: @escaping () async throws -> String) -> some View {
        HStack(spacing: 8) {
            if let status {
                Text(status)
                    .lineLimit(2)
                    .foregroundStyle(status.hasPrefix("Added") ? Color.green : Color.orange)
            }
            Spacer(minLength: 0)
            Button("Cancel") { mode = .edit; status = nil }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
            Button {
                isWorking = true
                Task { @MainActor in
                    do {
                        status = try await action()
                        try? await Task.sleep(for: .seconds(1.5))
                        mode = .edit
                    } catch {
                        status = error.localizedDescription
                    }
                    isWorking = false
                }
            } label: {
                Text(isWorking ? "Adding…" : actionTitle)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
    }

    private func toolbarButton(_ icon: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(active ? 0.25 : 0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }
}

enum QuickNoteDefaults {
    /// Next full hour, e.g. 14:00 when it's 13:20.
    static func nextHour() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return hourStart.addingTimeInterval(3600)
    }

    /// Today 17:00, or one hour from now if that has passed.
    static func endOfWorkday() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let fivePM = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now) ?? now
        return fivePM > now ? fivePM : nextHour()
    }
}
