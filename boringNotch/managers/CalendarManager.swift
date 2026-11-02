//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            print("📅 Current calendar authorization status: \(status)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                publish(await calendarService.events(
                    from: currentWeekStartDate,
                    to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                    calendars: selectedCalendars.map { $0.id }))
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            publish(await calendarService.events(
                from: currentWeekStartDate,
                to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                calendars: selectedCalendars.map { $0.id }))
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            print("📅 Current reminder authorization status: \(status)")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        publish(eventsResult)
    }

    // MARK: Google Tasks in the calendar

    /// Events from macOS calendars, before Google Tasks are merged in.
    private var baseEvents: [EventModel] = []

    private func publish(_ base: [EventModel]) {
        baseEvents = base
        events = Self.merge(base, googleTasksOn: currentWeekStartDate)
    }

    /// Re-merge after Google Tasks were synced or toggled.
    func refreshGoogleTasks() {
        events = Self.merge(baseEvents, googleTasksOn: currentWeekStartDate)
    }

    static let googleTaskPrefix = "google-task:"

    /// Google tasks due on `day`, shown like reminders.
    private static func merge(_ base: [EventModel], googleTasksOn day: Date) -> [EventModel] {
        let google = GoogleTasksManager.shared
        guard google.isConnected else { return base }
        let calendar = Calendar.current
        let googleCalendar = CalendarModel(
            id: "google-tasks", account: "Google", title: "Google Tasks",
            color: .systemBlue, isSubscribed: false, isReminder: true
        )
        let tasks = google.tasks.filter { task in
            guard let due = task.due else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
        let models = tasks.map { task in
            EventModel(
                id: googleTaskPrefix + task.id,
                start: calendar.startOfDay(for: day),
                end: calendar.startOfDay(for: day),
                title: task.title,
                location: nil,
                notes: task.notes,
                url: nil,
                isAllDay: true,
                type: .reminder(completed: task.isCompleted),
                calendar: googleCalendar,
                participants: [],
                timeZone: nil,
                hasRecurrenceRules: false,
                priority: nil
            )
        }
        return (base + models).sorted { $0.start < $1.start }
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        if reminderID.hasPrefix(Self.googleTaskPrefix) {
            let id = String(reminderID.dropFirst(Self.googleTaskPrefix.count))
            if let task = GoogleTasksManager.shared.tasks.first(where: { $0.id == id }), task.isCompleted != completed {
                GoogleTasksManager.shared.toggle(task)
            }
            refreshGoogleTasks()
            return
        }
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        publish(await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: selectedCalendars.map { $0.id }))
    }
}
