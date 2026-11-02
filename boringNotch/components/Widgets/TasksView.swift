//
//  TasksView.swift
//  boringNotch
//
//  Notch tab: daily routine jobs on the left, extra (one-off) jobs on the right,
//  quick-add fields ("09:00 Cek email"), and the due-reminder banner.
//

import Defaults
import SwiftUI

struct TasksView: View {
    @ObservedObject var manager = TasksManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reminder = manager.pending {
                ReminderStrip(reminder: reminder, manager: manager)
            }
            HStack(alignment: .top, spacing: 10) {
                RoutineColumn(manager: manager)
                ExtraColumn(manager: manager)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            NotchKeyboard.begin()
            manager.hideBanner()
        }
        .onDisappear {
            NotchKeyboard.end()
            manager.save()
        }
    }
}

// MARK: - Reminder strip

private struct ReminderStrip: View {
    let reminder: TaskReminder
    @ObservedObject var manager: TasksManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "alarm.fill")
                .foregroundStyle(.orange)
            Text(reminder.timeText.isEmpty ? reminder.title : "\(reminder.timeText) · \(reminder.title)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            TaskPill(title: "Tunda \(Defaults[.taskSnoozeMinutes])m", icon: "clock", prominent: false) { manager.snoozePending() }
            TaskPill(title: "Selesai", icon: "checkmark", prominent: true) { manager.completePending() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.18)))
    }
}

// MARK: - Columns

private struct RoutineColumn: View {
    @ObservedObject var manager: TasksManager
    @State private var input = ""
    @State private var workdaysOnly = false
    @FocusState private var focused: Bool

    var body: some View {
        let routines = manager.todaysRoutines
        let doneCount = routines.filter { manager.isDone($0) }.count

        VStack(alignment: .leading, spacing: 4) {
            ColumnHeader(icon: "repeat", title: "Rutin harian", trailing: routines.isEmpty ? nil : "\(doneCount)/\(routines.count)")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    if routines.isEmpty {
                        EmptyHint(text: "Job yang pasti tiap hari.\nContoh: 09:00 Cek email")
                    }
                    ForEach(routines) { routine in
                        TaskRow(
                            title: routine.title,
                            time: routine.timeText,
                            subtitle: routine.weekdays.count == 7 ? nil : routine.scheduleText,
                            isDone: manager.isDone(routine),
                            isOverdue: manager.isOverdue(routine),
                            highlighted: manager.pending?.id == routine.id
                        ) {
                            manager.toggleRoutine(routine.id)
                        }
                        .contextMenu {
                            Button(routine.weekdays.count == 7 ? "Ubah ke hari kerja saja" : "Ubah ke setiap hari") {
                                var updated = routine
                                updated.weekdays = routine.weekdays.count == 7 ? Set(2...6) : Set(1...7)
                                manager.updateRoutine(updated)
                            }
                            Button("Hapus rutin", role: .destructive) { manager.deleteRoutine(routine.id) }
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                QuickAddField(placeholder: "09:00 Job rutin…", text: $input, focused: $focused) {
                    if manager.addRoutine(from: input, workdaysOnly: workdaysOnly) { input = "" }
                }
                Button {
                    workdaysOnly.toggle()
                } label: {
                    Text(workdaysOnly ? "Sen–Jum" : "Tiap hari")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .help("Ulangi setiap hari atau hanya hari kerja")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .keepNotchOpenWhileTyping(focused)
    }
}

private struct ExtraColumn: View {
    @ObservedObject var manager: TasksManager
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        let extras = manager.visibleExtras
        let open = extras.filter { $0.doneAt == nil }.count

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ColumnHeader(icon: "plus.square.on.square", title: "Job tambahan", trailing: open > 0 ? "\(open) sisa" : nil)
                if extras.contains(where: { $0.doneAt != nil }) {
                    Button("Bersihkan") { withAnimation(.smooth) { manager.clearFinishedExtras() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    if extras.isEmpty {
                        EmptyHint(text: "Job yang kadang ada.\nContoh: 14:00 Kirim invoice")
                    }
                    ForEach(extras) { task in
                        TaskRow(
                            title: task.title,
                            time: task.due.map { dueText($0) },
                            subtitle: nil,
                            isDone: task.doneAt != nil,
                            isOverdue: manager.isOverdue(task),
                            highlighted: manager.pending?.id == task.id
                        ) {
                            manager.toggleExtra(task.id)
                        }
                        .contextMenu {
                            Button("Hapus", role: .destructive) { manager.deleteExtra(task.id) }
                        }
                    }
                }
            }

            QuickAddField(placeholder: "14:00 Job tambahan… (jam opsional)", text: $input, focused: $focused) {
                if manager.addExtra(from: input) { input = "" }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .keepNotchOpenWhileTyping(focused)
    }

    private func dueText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInTomorrow(date) { return "Besok \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

// MARK: - Pieces

private struct ColumnHeader: View {
    let icon: String
    let title: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.gray)
    }
}

private struct TaskRow: View {
    let title: String
    let time: String?
    let subtitle: String?
    let isDone: Bool
    let isOverdue: Bool
    let highlighted: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isDone ? Color.green : Color.gray)
            if let time {
                Text(time)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isDone ? Color.gray : (isOverdue ? Color.red : Color.cyan))
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isDone ? Color.gray : Color.white)
                .strikethrough(isDone, color: .gray)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? Color.orange.opacity(0.2) : Color.white.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.2)) { toggle() }
        }
    }
}

private struct QuickAddField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.gray)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .focused(focused)
                .onSubmit(onSubmit)
                .onExitCommand { focused.wrappedValue = false }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
    }
}

private struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.gray.opacity(0.8))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

private struct TaskPill: View {
    let title: String
    let icon: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(prominent ? Color.white.opacity(0.9) : Color.white.opacity(0.12)))
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// While a field is focused, keep the notch open even if the pointer leaves.
    func keepNotchOpenWhileTyping(_ focused: Bool) -> some View {
        self
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    SharingStateManager.shared.beginInteraction()
                } else {
                    SharingStateManager.shared.endInteraction()
                }
            }
            .onDisappear {
                if focused { SharingStateManager.shared.endInteraction() }
            }
    }
}

// MARK: - Closed notch

/// Due reminder around the closed notch.
struct TaskReminderLiveActivity: View {
    let reminder: TaskReminder
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(.orange)
                Text(reminder.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 150, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            Text(reminder.timeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: height, alignment: .center)
    }
}

// MARK: - Settings

struct TasksSettings: View {
    @ObservedObject var manager = TasksManager.shared
    @Default(.taskSnoozeMinutes) var snoozeMinutes

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .tasksEnabled) {
                    Text("Show Tasks tab and reminders")
                }
                Defaults.Toggle(key: .taskReminderSound) {
                    Text("Play a sound when a job is due")
                }
                Stepper(value: $snoozeMinutes, in: 5...120, step: 5) {
                    Text("Snooze for \(snoozeMinutes) minutes")
                }
            } footer: {
                Text("In the notch, type \"09:00 Cek email\" to add a job with a time, or just \"Cek email\" without one.")
            }

            Section {
                if manager.routines.isEmpty {
                    Text("No routine jobs yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.routines) { routine in
                    RoutineEditorRow(routine: routine, manager: manager)
                }
                Button {
                    manager.addRoutine(RoutineTask(title: "Job baru", minuteOfDay: 9 * 60))
                } label: {
                    Label("Add routine job", systemImage: "plus")
                }
            } header: {
                Text("Daily routine")
            } footer: {
                Text("Routine jobs come back unchecked every day they're scheduled.")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Tasks")
    }
}

private struct RoutineEditorRow: View {
    let routine: RoutineTask
    @ObservedObject var manager: TasksManager
    @State private var title = ""
    @State private var hasTime = true
    @State private var time = Date()

    private let dayNames = ["M", "S", "S", "R", "K", "J", "S"]   // Min … Sab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Job", text: $title)
                    .onSubmit(save)
                Toggle("Time", isOn: $hasTime)
                    .toggleStyle(.checkbox)
                    .onChange(of: hasTime) { _, _ in save() }
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!hasTime)
                    .onChange(of: time) { _, _ in save() }
                Button(role: .destructive) {
                    manager.deleteRoutine(routine.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { weekday in
                    let isOn = routine.weekdays.contains(weekday)
                    Button {
                        var updated = routine
                        if isOn { updated.weekdays.remove(weekday) } else { updated.weekdays.insert(weekday) }
                        if !updated.weekdays.isEmpty { manager.updateRoutine(updated) }
                    } label: {
                        Text(dayNames[weekday - 1])
                            .font(.caption.bold())
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.2)))
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Text(routine.scheduleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            title = routine.title
            hasTime = routine.minuteOfDay != nil
            let minute = routine.minuteOfDay ?? 9 * 60
            time = Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minute * 60))
        }
        .onDisappear(perform: save)
    }

    private func save() {
        var updated = routine
        updated.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? routine.title : title
        updated.minuteOfDay = hasTime ? TasksManager.minuteOfDay(time) : nil
        guard updated != routine else { return }
        manager.updateRoutine(updated)
    }
}
