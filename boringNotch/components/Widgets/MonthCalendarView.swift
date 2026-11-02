//
//  MonthCalendarView.swift
//  boringNotch
//
//  A big month calendar in its own window: every day of the month with its
//  events (from the calendars selected in Settings → Calendar, including Google
//  calendars added in System Settings → Internet Accounts), Google Tasks with a
//  due date, and the routine/extra jobs from the Tasks tab. Click a day to see
//  its details on the right.
//

import AppKit
import EventKit
import SwiftUI

// MARK: - Window

@MainActor
final class MonthCalendarWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MonthCalendarWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Calendar"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.contentView = NSHostingView(rootView: MonthCalendarView())
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .monthCalendarShouldReload, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app unless Settings is still open.
        let settingsOpen = NSApp.windows.contains { $0.identifier?.rawValue == "BoringNotchSettingsWindow" && $0.isVisible }
        if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

extension Notification.Name {
    static let monthCalendarShouldReload = Notification.Name("monthCalendarShouldReload")
}

// MARK: - Model

struct MonthItem: Identifiable, Hashable {
    enum Kind: Hashable { case event, allDay, reminder, googleTask, job }

    let id: String
    let title: String
    let start: Date
    let end: Date?
    let kind: Kind
    let color: Color
    let detail: String?
    var isDone: Bool = false

    var timeText: String? {
        switch kind {
        case .event, .reminder:
            return start.formatted(date: .omitted, time: .shortened)
        case .job:
            return Calendar.current.component(.hour, from: start) == 0 && Calendar.current.component(.minute, from: start) == 0
                ? nil : start.formatted(date: .omitted, time: .shortened)
        default:
            return nil
        }
    }
}

@MainActor
final class MonthCalendarModel: ObservableObject {
    @Published var month: Date = Calendar.current.startOfMonth(for: Date())
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var itemsByDay: [Date: [MonthItem]] = [:]
    @Published private(set) var isLoading = false

    private let service = CalendarService()
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .monthCalendarShouldReload, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        })
    }

    /// 6 weeks starting on the locale's first weekday.
    var gridDays: [Date] {
        let calendar = Calendar.current
        let firstOfMonth = calendar.startOfMonth(for: month)
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: firstOfMonth)!
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    func items(on day: Date) -> [MonthItem] {
        itemsByDay[Calendar.current.startOfDay(for: day)] ?? []
    }

    func move(months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
        Task { await reload() }
    }

    func goToToday() {
        month = Calendar.current.startOfMonth(for: Date())
        selectedDay = Calendar.current.startOfDay(for: Date())
        Task { await reload() }
    }

    func reload() async {
        let calendar = Calendar.current
        let days = gridDays
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        isLoading = true
        defer { isLoading = false }

        var grouped: [Date: [MonthItem]] = [:]
        func add(_ item: MonthItem, on day: Date) {
            grouped[calendar.startOfDay(for: day), default: []].append(item)
        }

        // Calendar events and reminders (EventKit, incl. Google/iCloud accounts in macOS).
        let calendarIDs = Array(CalendarManager.shared.selectedCalendarIDs)
        let events = await service.events(from: first, to: end, calendars: calendarIDs)
        for event in events {
            let color = Color(nsColor: event.calendar.color)
            switch event.type {
            case .reminder(let completed):
                add(MonthItem(id: event.id, title: event.title, start: event.start, end: nil, kind: .reminder, color: color, detail: event.calendar.title, isDone: completed), on: event.start)
            default:
                if event.isAllDay {
                    // Spread multi-day all-day events across their days.
                    var day = calendar.startOfDay(for: event.start)
                    let lastDay = calendar.startOfDay(for: event.end.addingTimeInterval(-1))
                    while day <= lastDay && day < end {
                        if day >= first {
                            add(MonthItem(id: "\(event.id)-\(day.timeIntervalSince1970)", title: event.title, start: day, end: nil, kind: .allDay, color: color, detail: event.calendar.title), on: day)
                        }
                        day = calendar.date(byAdding: .day, value: 1, to: day)!
                    }
                } else {
                    let detail = [event.calendar.title, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    add(MonthItem(id: event.id, title: event.title, start: event.start, end: event.end, kind: .event, color: color, detail: detail), on: event.start)
                }
            }
        }

        // Google Tasks with a due date.
        let google = GoogleTasksManager.shared
        for task in google.tasks {
            guard let due = task.due, due >= first, due < end else { continue }
            add(MonthItem(id: "g-\(task.id)", title: task.title, start: due, end: nil, kind: .googleTask, color: .blue, detail: "Google Tasks · \(task.listTitle)", isDone: task.isCompleted), on: due)
        }

        // Jobs from the Tasks tab: routines on their weekdays (from today on) and extras with a due time.
        let tasks = TasksManager.shared
        let today = calendar.startOfDay(for: Date())
        for day in days where day >= today {
            let weekday = calendar.component(.weekday, from: day)
            for routine in tasks.routines where routine.weekdays.contains(weekday) {
                let start = day.addingTimeInterval(TimeInterval((routine.minuteOfDay ?? 0) * 60))
                let done = calendar.isDateInToday(day) && tasks.isDone(routine)
                add(MonthItem(id: "r-\(routine.id)-\(day.timeIntervalSince1970)", title: routine.title, start: start, end: nil, kind: .job, color: .orange, detail: "Rutin · \(routine.scheduleText)", isDone: done), on: day)
            }
        }
        for task in tasks.extras {
            guard let due = task.due, due >= first, due < end else { continue }
            add(MonthItem(id: "e-\(task.id)", title: task.title, start: due, end: nil, kind: .job, color: .pink, detail: "Job tambahan", isDone: task.doneAt != nil), on: due)
        }

        // Order: all-day first, then by time.
        for key in grouped.keys {
            grouped[key]?.sort { lhs, rhs in
                if (lhs.kind == .allDay) != (rhs.kind == .allDay) { return lhs.kind == .allDay }
                return lhs.start < rhs.start
            }
        }
        itemsByDay = grouped
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

// MARK: - Views

struct MonthCalendarView: View {
    @StateObject private var model = MonthCalendarModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                header
                weekdayHeader
                grid
            }
            .padding(16)
            .padding(.top, 18)

            Divider()

            DayDetailPanel(model: model)
                .frame(width: 260)
        }
        .frame(minWidth: 820, minHeight: 560)
        .task { await model.reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.month.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 26, weight: .bold))
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button { model.move(months: -1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Today") { model.goToToday() }
                .keyboardShortcut("t", modifiers: [])
            Button { model.move(months: 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .controlSize(.large)
    }

    private var weekdayHeader: some View {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let ordered = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        return HStack(spacing: 6) {
            ForEach(ordered, id: \.self) { name in
                Text(name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
            }
        }
    }

    private var grid: some View {
        let days = model.gridDays
        return VStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { index in
                        let day = days[week * 7 + index]
                        DayCell(day: day, month: model.month, items: model.items(on: day), isSelected: Calendar.current.isDate(day, inSameDayAs: model.selectedDay))
                            .onTapGesture { model.selectedDay = day }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let month: Date
    let items: [MonthItem]
    let isSelected: Bool

    private var calendar: Calendar { Calendar.current }
    private var inMonth: Bool { calendar.isDate(day, equalTo: month, toGranularity: .month) }
    private var isToday: Bool { calendar.isDateInToday(day) }

    var body: some View {
        GeometryReader { geo in
            let maxRows = max(1, Int((geo.size.height - 30) / 17))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 13, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Circle().fill(isToday ? Color.red : Color.clear))
                    Spacer()
                }
                ForEach(items.prefix(items.count > maxRows ? maxRows - 1 : maxRows)) { item in
                    ItemChip(item: item)
                }
                if items.count > maxRows {
                    Text("+\(items.count - maxRows + 1) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(inMonth ? 0.04 : 0.015))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

private struct ItemChip: View {
    let item: MonthItem

    var body: some View {
        HStack(spacing: 4) {
            switch item.kind {
            case .allDay:
                EmptyView()
            case .googleTask, .reminder, .job:
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(item.color)
            case .event:
                Circle().fill(item.color).frame(width: 6, height: 6)
            }
            if let time = item.timeText {
                Text(time)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Text(item.title)
                .font(.system(size: 10, weight: item.kind == .allDay ? .semibold : .regular))
                .lineLimit(1)
                .strikethrough(item.isDone)
                .foregroundStyle(item.kind == .allDay ? Color.white : (item.isDone ? Color.secondary : Color.primary))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(item.kind == .allDay ? item.color.opacity(0.85) : item.color.opacity(0.12))
        )
        .help([item.title, item.detail].compactMap { $0 }.joined(separator: "\n"))
    }
}

private struct DayDetailPanel: View {
    @ObservedObject var model: MonthCalendarModel

    var body: some View {
        let items = model.items(on: model.selectedDay)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedDay.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                Text(model.selectedDay.formatted(.dateTime.day().month(.wide).year()))
                    .font(.system(size: 20, weight: .bold))
            }
            .padding(.top, 30)

            if items.isEmpty {
                Text("Nothing scheduled")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(item.color)
                                    .frame(width: 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .strikethrough(item.isDone)
                                    Text(timeRange(item))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    if let detail = item.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Open in Calendar app") {
                NSWorkspace.shared.open(URL(string: "ical://")!)
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.02))
    }

    private func timeRange(_ item: MonthItem) -> String {
        switch item.kind {
        case .allDay: return "All day"
        case .googleTask: return item.isDone ? "Google task · done" : "Google task · due this day"
        case .reminder: return "Reminder · \(item.start.formatted(date: .omitted, time: .shortened))"
        case .job: return item.timeText.map { "Job · \($0)" } ?? "Job"
        case .event:
            let start = item.start.formatted(date: .omitted, time: .shortened)
            if let end = item.end { return "\(start) – \(end.formatted(date: .omitted, time: .shortened))" }
            return start
        }
    }
}
