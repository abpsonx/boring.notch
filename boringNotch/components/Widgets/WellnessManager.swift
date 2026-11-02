//
//  WellnessManager.swift
//  boringNotch
//
//  Break reminder (continuous screen time) and drink-water reminder.
//
//  "Continuous screen time" starts when you begin using the Mac and resets when
//  the screen sleeps/locks or when there's no keyboard/mouse input for
//  `idleResetMinutes` (that counts as a break).
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation
import SwiftUI

struct WellnessReminder: Identifiable, Equatable {
    enum Kind { case takeBreak, drinkWater }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let date = Date()

    var icon: String {
        switch kind {
        case .takeBreak: return "figure.walk"
        case .drinkWater: return "drop.fill"
        }
    }
}

@MainActor
final class WellnessManager: ObservableObject {
    static let shared = WellnessManager()

    /// When the current uninterrupted screen session started (nil while idle/asleep).
    @Published private(set) var sessionStart: Date?
    @Published private(set) var now = Date()
    @Published private(set) var waterCount: Int = 0
    /// Reminder currently shown in the closed notch (auto hides).
    @Published private(set) var banner: WellnessReminder?
    /// Reminder waiting for an action in the Today tab.
    @Published private(set) var pendingReminder: WellnessReminder?
    /// End of a break the user started from the notch.
    @Published private(set) var breakEndsAt: Date?

    private var tickTimer: Timer?
    private var bannerTask: Task<Void, Never>?
    private var lastBreakReminder: Date?
    private var lastWaterReference = Date()
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private let bannerDuration: TimeInterval = 8

    private init() {}

    func start() {
        rollOverWaterCountIfNeeded()
        sessionStart = Date()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endSession() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.beginSessionIfNeeded() }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endSession() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.beginSessionIfNeeded() }
        })

        Defaults.publisher(.waterCount)
            .sink { [weak self] change in
                Task { @MainActor in self?.waterCount = change.newValue }
            }
            .store(in: &cancellables)

        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tickTimer?.tolerance = 5
    }

    // MARK: - Derived values

    var continuousScreenTime: TimeInterval {
        guard let sessionStart else { return 0 }
        return max(0, now.timeIntervalSince(sessionStart))
    }

    var breakInterval: TimeInterval { TimeInterval(max(1, Defaults[.breakIntervalMinutes]) * 60) }

    var breakProgress: Double {
        min(1, continuousScreenTime / breakInterval)
    }

    var timeUntilBreak: TimeInterval { max(0, breakInterval - continuousScreenTime) }

    // MARK: Water amounts (waterCount = glasses logged today)

    var waterML: Int { waterCount * max(50, Defaults[.waterGlassML]) }
    var waterGoalML: Int { max(250, Defaults[.waterGoalML]) }
    var waterProgress: Double { min(1, Double(waterML) / Double(waterGoalML)) }

    /// "750 ml", "1,5 L", "2 L"
    static func formatML(_ ml: Int) -> String {
        if ml < 1000 { return "\(ml) ml" }
        let liters = Double(ml) / 1000
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "id_ID")
        return "\(formatter.string(from: NSNumber(value: liters)) ?? String(liters)) L"
    }

    var timeUntilWater: TimeInterval {
        let interval = TimeInterval(max(1, Defaults[.waterIntervalMinutes]) * 60)
        return max(0, interval - now.timeIntervalSince(lastWaterReference))
    }

    // MARK: - Actions

    func logWater() {
        rollOverWaterCountIfNeeded()
        Defaults[.waterCount] += 1
        lastWaterReference = Date()
        if pendingReminder?.kind == .drinkWater { clearReminder() }
    }

    func undoWater() {
        Defaults[.waterCount] = max(0, Defaults[.waterCount] - 1)
    }

    /// User accepted the break: count down 5 minutes and reset the session.
    func startBreak(minutes: Int = 5) {
        breakEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sessionStart = nil
        lastBreakReminder = nil
        if pendingReminder?.kind == .takeBreak { clearReminder() }
        now = Date()
    }

    func endBreakEarly() {
        breakEndsAt = nil
        sessionStart = Date()
        now = Date()
    }

    /// Ask again later.
    func snooze() {
        guard let reminder = pendingReminder else { return }
        switch reminder.kind {
        case .takeBreak: lastBreakReminder = Date()
        case .drinkWater: lastWaterReference = Date().addingTimeInterval(-TimeInterval(max(1, Defaults[.waterIntervalMinutes]) * 60) + 15 * 60)
        }
        clearReminder()
    }

    func clearReminder() {
        pendingReminder = nil
        hideBanner()
    }

    func hideBanner() {
        bannerTask?.cancel()
        withAnimationIfPossible { self.banner = nil }
    }

    /// For trying the reminders from Settings.
    func preview(_ kind: WellnessReminder.Kind) {
        switch kind {
        case .takeBreak: showBreakReminder()
        case .drinkWater: showWaterReminder()
        }
    }

    // MARK: - Session tracking

    private func endSession() {
        sessionStart = nil
        lastBreakReminder = nil
        now = Date()
    }

    private func beginSessionIfNeeded() {
        if sessionStart == nil && breakEndsAt == nil {
            sessionStart = Date()
        }
        now = Date()
    }

    private func tick() {
        now = Date()
        rollOverWaterCountIfNeeded()

        if let breakEndsAt, now >= breakEndsAt {
            self.breakEndsAt = nil
            sessionStart = Date()
        }

        let idle = Self.secondsSinceLastInput()
        let idleLimit = TimeInterval(max(1, Defaults[.idleResetMinutes]) * 60)
        if idle >= idleLimit {
            // Away from the keyboard long enough: that's a break.
            sessionStart = nil
            lastBreakReminder = nil
            return
        }
        if sessionStart == nil && breakEndsAt == nil {
            sessionStart = now.addingTimeInterval(-idle)
        }

        // Don't stack reminders while one is on screen.
        guard banner == nil else { return }

        if Defaults[.breakReminderEnabled], breakEndsAt == nil, continuousScreenTime >= breakInterval {
            let repeatInterval = TimeInterval(max(5, Defaults[.breakRepeatMinutes]) * 60)
            if lastBreakReminder == nil || now.timeIntervalSince(lastBreakReminder!) >= repeatInterval {
                showBreakReminder()
                return
            }
        }

        if Defaults[.waterReminderEnabled],
           waterML < waterGoalML,
           timeUntilWater <= 0
        {
            showWaterReminder()
        }
    }

    private func showBreakReminder() {
        lastBreakReminder = Date()
        let minutes = Int(continuousScreenTime / 60)
        let detail = minutes >= 1 ? Self.format(duration: continuousScreenTime) : Self.format(duration: breakInterval)
        show(WellnessReminder(kind: .takeBreak, title: "Istirahat dulu!", detail: detail))
    }

    private func showWaterReminder() {
        lastWaterReference = Date()
        show(WellnessReminder(kind: .drinkWater, title: "Waktunya minum air", detail: "\(Self.formatML(waterML))/\(Self.formatML(waterGoalML))"))
    }

    private func show(_ reminder: WellnessReminder) {
        pendingReminder = reminder
        withAnimationIfPossible { self.banner = reminder }
        if Defaults[.wellnessReminderSound] {
            NSSound(named: reminder.kind == .drinkWater ? "Bottle" : "Glass")?.play()
        }
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(bannerDuration))
            guard !Task.isCancelled else { return }
            withAnimationIfPossible { self.banner = nil }
        }
    }

    private func rollOverWaterCountIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        if Defaults[.waterCountDay] != today {
            Defaults[.waterCountDay] = today
            Defaults[.waterCount] = 0
        }
        waterCount = Defaults[.waterCount]
    }

    // MARK: - Helpers

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// "2j 5m" style, short enough for the notch.
    static func format(duration: TimeInterval) -> String {
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours)j \(minutes)m" : "\(hours) jam" }
        return "\(minutes)m"
    }
}

@MainActor
private func withAnimationIfPossible(_ body: () -> Void) {
    withAnimation(.smooth) { body() }
}
