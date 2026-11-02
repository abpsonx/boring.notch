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
    let actions: [String]?
    let canReply: Bool?
}

struct NotchNotification: Identifiable, Equatable {
    let id = UUID()
    let key: String
    let appName: String
    let appIcon: NSImage?
    let bundleURL: URL?
    let title: String
    let body: String
    var canReply: Bool = false
    let date = Date()

    static func == (lhs: NotchNotification, rhs: NotchNotification) -> Bool { lhs.id == rhs.id }
}

extension Defaults.Keys {
    static let notchNotificationsEnabled = Key<Bool>("notchNotificationsEnabled", default: false)
    static let notchNotificationDuration = Key<Double>("notchNotificationDuration", default: 6)
    static let notchNotificationShowPreview = Key<Bool>("notchNotificationShowPreview", default: true)
    static let notchNotificationMissedIndicator = Key<Bool>("notchNotificationMissedIndicator", default: true)
    /// Close the macOS banner right after reading it, so notifications only show in the notch.
    static let notchNotificationHideSystemBanner = Key<Bool>("notchNotificationHideSystemBanner", default: false)
}

@MainActor
final class NotchNotificationManager: ObservableObject {
    static let shared = NotchNotificationManager()

    @Published private(set) var banner: NotchNotification?
    @Published private(set) var history: [NotchNotification] = []
    @Published private(set) var isAuthorized = false
    /// Notifications that arrived since the Notifications tab was last viewed.
    @Published private(set) var unreadCount = 0

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
                // Poll faster when hiding macOS banners so they disappear quickly.
                try? await Task.sleep(for: .milliseconds(Defaults[.notchNotificationHideSystemBanner] ? 300 : 800))
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
            guard let notification = makeNotification(from: payload) else { continue }
            // A banner's text can change (hover, inline reply), which changes its key.
            // Don't show the same message twice within a minute.
            let isDuplicate = history.contains {
                $0.appName == notification.appName && $0.title == notification.title && $0.body == notification.body
                    && Date().timeIntervalSince($0.date) < 60
            }
            if Defaults[.notchNotificationHideSystemBanner] {
                // Show it only in the notch: close the macOS banner.
                let key = payload.key
                Task { _ = await XPCHelperClient.shared.dismissNotificationBanner(key: key) }
            }
            if !isDuplicate {
                var shown = notification
                // The macOS banner (needed for inline reply) is gone when hiding banners.
                if Defaults[.notchNotificationHideSystemBanner] { shown.canReply = false }
                enqueue(shown)
            }
        }
    }

    // MARK: - Presentation

    private func enqueue(_ notification: NotchNotification) {
        history.insert(notification, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        unreadCount += 1

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

    /// Opens the banner's inline reply (macOS shows its own text field in the banner).
    func reply(to notification: NotchNotification) {
        hideTask?.cancel()
        Task { @MainActor in
            let ok = await XPCHelperClient.shared.replyToNotificationBanner(key: notification.key)
            hideBanner()
            if !ok {
                // Banner already gone: open the app instead.
                activate(notification)
            }
        }
    }

    /// Opens the app that posted a notification from the history list.
    func open(_ notification: NotchNotification) {
        Task { @MainActor in
            let pressed = await XPCHelperClient.shared.pressNotificationBanner(key: notification.key)
            if !pressed, let url = notification.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }

    func markAllRead() {
        unreadCount = 0
    }

    func remove(_ notification: NotchNotification) {
        history.removeAll { $0.id == notification.id }
    }

    func clearHistory() {
        history.removeAll()
        unreadCount = 0
    }

    /// App icons of the unread notifications (newest first, unique apps).
    var unreadIcons: [NSImage] {
        var seen = Set<String>()
        var icons: [NSImage] = []
        for item in history.prefix(unreadCount) where !seen.contains(item.appName) {
            seen.insert(item.appName)
            if let icon = item.appIcon { icons.append(icon) }
            if icons.count == 3 { break }
        }
        return icons
    }

    func previewBanner() {
        enqueue(NotchNotification(
            key: UUID().uuidString,
            appName: "Boring Notch",
            appIcon: NSApp.applicationIconImage,
            bundleURL: nil,
            title: "Contoh notifikasi",
            body: "Notifikasi dari app lain akan tampil seperti ini di notch. Pesan yang panjang tetap terbaca sampai tiga baris sebelum dipotong."
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
            body: texts.dropFirst().joined(separator: " "),
            canReply: payload.canReply ?? false
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
    @ObservedObject var manager = NotchNotificationManager.shared

    private let sideWidth: CGFloat = 170
    private var totalWidth: CGFloat { sideWidth * 2 + notchWidth + 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    .frame(width: sideWidth, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(height: height, alignment: .center)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if showPreview && !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if notification.canReply {
                    Button {
                        manager.reply(to: notification)
                    } label: {
                        Label("Balas", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.9)))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: totalWidth, alignment: .leading)
            .padding(.bottom, 12)
        }
        .fixedSize()
    }
}

/// Small "missed notifications" indicator for the closed notch: app icons on the
/// left, bell + count on the right.
struct MissedNotificationsIndicator: View {
    let icons: [NSImage]
    let count: Int
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: -6) {
                ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.black))
                }
                if icons.isEmpty {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 50, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth - 20)

            HStack(spacing: 3) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .frame(height: height, alignment: .center)
    }
}

// MARK: - Notifications tab

struct NotificationsTabView: View {
    @ObservedObject var manager = NotchNotificationManager.shared
    @Default(.notchNotificationsEnabled) var enabled
    @Default(.notchNotificationShowPreview) var showPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(manager.history.isEmpty ? "No notifications" : "\(manager.history.count) notifications")
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer()
                if !manager.history.isEmpty {
                    Button {
                        withAnimation(.smooth) { manager.clearHistory() }
                    } label: {
                        Label("Clear", systemImage: "trash").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)
                }
            }

            if !enabled {
                placeholder("Turn on notifications in Settings → Notifications")
            } else if manager.history.isEmpty {
                placeholder("Notifications that arrive will be listed here")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(manager.history) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { manager.markAllRead() }
        .onChange(of: manager.unreadCount) { _, newValue in
            if newValue > 0 { manager.markAllRead() }
        }
    }

    private func row(_ item: NotchNotification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = item.appIcon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: "bell.fill")
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.date, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
                Text(showPreview && !item.body.isEmpty ? item.body : item.appName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { manager.open(item) }
        .contextMenu {
            Button("Open \(item.appName)") { manager.open(item) }
            Button("Remove") { withAnimation(.smooth) { manager.remove(item) } }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash").font(.title2)
            Text(text).font(.caption)
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Defaults.Toggle(key: .notchNotificationMissedIndicator) {
                    Text("Show unread count on the closed notch")
                }
                Defaults.Toggle(key: .notchNotificationHideSystemBanner) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show notifications only in the notch")
                        Text("Closes the macOS banner right after it appears (it may flash briefly). Inline Reply isn't available then; clicking opens the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
