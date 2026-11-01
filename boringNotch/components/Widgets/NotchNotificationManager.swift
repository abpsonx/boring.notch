//
//  NotchNotificationManager.swift
//  boringNotch
//
//  Mirrors macOS notification banners in the notch. The XPC helper reads the
//  banners via Accessibility; this class polls it, detects new ones and shows
//  them around the closed notch. Nothing is stored or sent anywhere.
//

import AppKit
import Combine
import Defaults
import SwiftUI

/// Must match `NotificationBannerPayload` in the XPC helper.
struct NotchBannerPayload: Codable {
    let key: String
    let texts: [String]
    let description: String?
    let identifier: String?
    let title: String?
}

struct NotchNotification: Identifiable, Equatable {
    let id = UUID()
    let key: String
    let appName: String
    let appIcon: NSImage?
    let bundleURL: URL?
    let title: String
    let body: String
    let date = Date()

    static func == (lhs: NotchNotification, rhs: NotchNotification) -> Bool { lhs.id == rhs.id }
}

extension Defaults.Keys {
    static let notchNotificationsEnabled = Key<Bool>("notchNotificationsEnabled", default: false)
    static let notchNotificationDuration = Key<Double>("notchNotificationDuration", default: 6)
    static let notchNotificationShowPreview = Key<Bool>("notchNotificationShowPreview", default: true)
}

@MainActor
final class NotchNotificationManager: ObservableObject {
    static let shared = NotchNotificationManager()

    @Published private(set) var banner: NotchNotification?
    @Published private(set) var history: [NotchNotification] = []
    @Published private(set) var isAuthorized = false

    private var pollTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var queue: [NotchNotification] = []
    private var visibleKeys: Set<String> = []
    private var isFirstPoll = true
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        Defaults.publisher(.notchNotificationsEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    if change.newValue {
                        await self.enable()
                    } else {
                        self.disable()
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)
            .sink { [weak self] note in
                let granted = note.userInfo?["granted"] as? Bool ?? false
                Task { @MainActor in self?.isAuthorized = granted }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    private func enable() async {
        isAuthorized = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        startPolling()
    }

    private func disable() {
        pollTask?.cancel()
        pollTask = nil
        queue.removeAll()
        visibleKeys.removeAll()
        isFirstPoll = true
        hideBanner()
    }

    func refreshAuthorization() async {
        isAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
    }

    func requestAuthorization() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
    }

    private func startPolling() {
        pollTask?.cancel()
        isFirstPoll = true
        pollTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if tick % 6 == 0 { await self?.refreshAuthorization() }
                tick += 1
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    private func poll() async {
        guard let data = await XPCHelperClient.shared.currentNotificationBanners(),
              let payloads = try? JSONDecoder().decode([NotchBannerPayload].self, from: data)
        else { return }

        let currentKeys = Set(payloads.map(\.key))
        defer {
            visibleKeys = currentKeys
            isFirstPoll = false
        }
        // Banners already on screen when monitoring starts are not replayed.
        guard !isFirstPoll else { return }

        for payload in payloads where !visibleKeys.contains(payload.key) {
            if let notification = makeNotification(from: payload) {
                enqueue(notification)
            }
        }
    }

    // MARK: - Presentation

    private func enqueue(_ notification: NotchNotification) {
        history.insert(notification, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }

        if banner == nil {
            present(notification)
        } else {
            queue.append(notification)
        }
    }

    private func present(_ notification: NotchNotification) {
        withAnimation(.smooth) { banner = notification }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(2, Defaults[.notchNotificationDuration])))
            guard !Task.isCancelled else { return }
            self.hideBanner()
        }
    }

    func hideBanner() {
        hideTask?.cancel()
        withAnimation(.smooth) { banner = nil }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                self.present(next)
            }
        }
    }

    /// Click on the notch banner: click the macOS banner (opens the exact chat/mail),
    /// or just open the app if the banner is already gone.
    func activate(_ notification: NotchNotification) {
        hideBanner()
        Task { @MainActor in
            let pressed = await XPCHelperClient.shared.pressNotificationBanner(key: notification.key)
            if !pressed, let url = notification.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }

    func previewBanner() {
        enqueue(NotchNotification(
            key: UUID().uuidString,
            appName: "Boring Notch",
            appIcon: NSApp.applicationIconImage,
            bundleURL: nil,
            title: "Contoh notifikasi",
            body: "Notifikasi dari app lain akan tampil seperti ini di notch."
        ))
    }

    func debugInfo() async -> String {
        await XPCHelperClient.shared.notificationDebugDump()
    }

    // MARK: - Parsing

    private func makeNotification(from payload: NotchBannerPayload) -> NotchNotification? {
        let descriptionParts = (payload.description ?? "")
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Figure out which app posted it.
        let candidates = [payload.identifier, payload.title, descriptionParts.first, payload.texts.first].compactMap { $0 }
        let app = candidates.lazy.compactMap { Self.runningApp(matching: $0) }.first

        var texts = payload.texts
        if texts.isEmpty { texts = descriptionParts }
        if let name = app?.localizedName, texts.first?.caseInsensitiveCompare(name) == .orderedSame, texts.count > 1 {
            texts.removeFirst()
        }
        guard !texts.isEmpty else { return nil }

        let appName = app?.localizedName ?? (descriptionParts.count > texts.count ? descriptionParts.first : nil) ?? "Notification"
        return NotchNotification(
            key: payload.key,
            appName: appName,
            appIcon: app?.icon,
            bundleURL: app?.bundleURL,
            title: texts[0],
            body: texts.dropFirst().joined(separator: " ")
        )
    }

    private static func runningApp(matching candidate: String) -> NSRunningApplication? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier?.caseInsensitiveCompare(value) == .orderedSame
                || app.localizedName?.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

// MARK: - Closed notch view

/// Notification shown around the closed notch: app + time on the first row,
/// sender and message below it.
struct NotchNotificationLiveActivity: View {
    let notification: NotchNotification
    let notchWidth: CGFloat
    let height: CGFloat
    @Default(.notchNotificationShowPreview) var showPreview

    private let sideWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if let icon = notification.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.white)
                    }
                    Text(notification.appName)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                .frame(width: sideWidth, alignment: .leading)

                Rectangle()
                    .fill(.black)
                    .frame(width: notchWidth + 10)

                Text("now")
                    .foregroundStyle(.gray)
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(height: height, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if showPreview && !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
            }
            .frame(width: sideWidth + notchWidth + 10 + 60, alignment: .leading)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Settings

struct NotchNotificationSettings: View {
    @ObservedObject var manager = NotchNotificationManager.shared
    @Default(.notchNotificationsEnabled) var enabled
    @Default(.notchNotificationDuration) var duration
    @State private var debugStatus: String?

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .notchNotificationsEnabled) {
                    Text("Show notifications in the notch")
                }
                HStack {
                    if manager.isAuthorized {
                        Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Accessibility access needed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant access") { manager.requestAuthorization() }
                    }
                }
                .disabled(!enabled)
            } header: {
                Text("General")
            } footer: {
                Text("Boring Notch reads the banners macOS shows (via Accessibility) and shows them in the notch. Click the notch banner to open the message. Nothing is stored or sent anywhere.")
            }

            Section {
                Defaults.Toggle(key: .notchNotificationShowPreview) {
                    Text("Show message preview")
                }
                Slider(value: $duration, in: 3...12, step: 1) {
                    Text("Show for \(Int(duration)) seconds")
                }
                Button("Show example") { manager.previewBanner() }
            } header: {
                Text("Appearance")
            }

            Section {
                HStack {
                    Button("Copy debug info in 8 seconds") {
                        Task { @MainActor in
                            for remaining in stride(from: 8, to: 0, by: -1) {
                                debugStatus = "Capturing in \(remaining)s… trigger a notification now"
                                try? await Task.sleep(for: .seconds(1))
                            }
                            let info = await manager.debugInfo()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(info, forType: .string)
                            debugStatus = "Copied to clipboard"
                            try? await Task.sleep(for: .seconds(3))
                            debugStatus = nil
                        }
                    }
                    .disabled(debugStatus != nil)
                    if let debugStatus {
                        Text(debugStatus).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("If a notification isn't shown correctly: click the button, make a notification appear (e.g. send yourself a message) and wait. The copied text describes the banners on screen at that moment, including their text.")
            }
        }
        .task { await manager.refreshAuthorization() }
        .accentColor(.effectiveAccent)
        .navigationTitle("Notifications")
    }
}
