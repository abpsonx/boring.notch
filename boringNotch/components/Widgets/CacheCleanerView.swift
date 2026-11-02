//
//  CacheCleanerView.swift
//  boringNotch
//
//  Settings page that lists ~/Library/Caches per app (via the XPC helper)
//  and moves the selected caches to the Trash (or deletes them).
//

import AppKit
import Defaults
import SwiftUI

/// Must match `CacheEntryPayload` / `CacheRemovalResult` in the XPC helper.
struct CacheEntry: Codable, Identifiable, Hashable {
    let path: String
    let name: String
    let bytes: Int64
    var id: String { path }
}

struct CacheRemovalSummary: Codable {
    let removed: [String]
    let failed: [String: String]
    let freedBytes: Int64
}

@MainActor
final class CacheCleanerModel: ObservableObject {
    @Published var entries: [CacheEntry] = []
    @Published var selected: Set<String> = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var includeApple = false
    @Published var permanently = false
    @Published var message: String?

    var selectedBytes: Int64 {
        entries.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        Task { @MainActor in
            defer { isScanning = false }
            guard let data = await XPCHelperClient.shared.scanUserCaches(includeApple: includeApple),
                  let result = try? JSONDecoder().decode([CacheEntry].self, from: data)
            else {
                message = "Couldn't read ~/Library/Caches. Try again."
                return
            }
            entries = result
            // Pre-select everything except caches of apps that are running right now.
            selected = Set(result.filter { !isRunning($0) }.map(\.path))
        }
    }

    func clean() {
        let paths = Array(selected)
        guard !paths.isEmpty, !isCleaning else { return }
        isCleaning = true
        Task { @MainActor in
            defer { isCleaning = false }
            guard let data = await XPCHelperClient.shared.removeUserCaches(paths: paths, permanently: permanently),
                  let summary = try? JSONDecoder().decode(CacheRemovalSummary.self, from: data)
            else {
                message = "Cleaning failed."
                return
            }
            let freed = ByteCountFormatter.string(fromByteCount: summary.freedBytes, countStyle: .file)
            var text = permanently
                ? "Deleted \(summary.removed.count) cache folders, freed \(freed)."
                : "Moved \(summary.removed.count) cache folders (\(freed)) to the Trash. Empty the Trash to free the space."
            if !summary.failed.isEmpty {
                text += " \(summary.failed.count) couldn't be removed (in use or protected)."
            }
            message = text
            scan()
        }
    }

    // MARK: - App info

    func isRunning(_ entry: CacheEntry) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return id.caseInsensitiveCompare(entry.name) == .orderedSame
                || entry.name.lowercased().hasPrefix(id.lowercased() + ".")
                || app.localizedName?.caseInsensitiveCompare(entry.name) == .orderedSame
        }
    }

    func appURL(for entry: CacheEntry) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.name)
    }

    func displayName(for entry: CacheEntry) -> String {
        if let url = appURL(for: entry) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return entry.name
    }

    func icon(for entry: CacheEntry) -> NSImage {
        if let url = appURL(for: entry) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .folder)
    }
}

struct CacheCleanerSettings: View {
    @StateObject private var model = CacheCleanerModel()

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.entries.isEmpty ? "App caches" : "App caches: \(format(model.totalBytes))")
                            .font(.headline)
                        Text("Selected: \(format(model.selectedBytes))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.isScanning ? "Scanning…" : "Scan") { model.scan() }
                        .disabled(model.isScanning || model.isCleaning)
                    Button(model.isCleaning ? "Cleaning…" : (model.permanently ? "Delete Selected" : "Move Selected to Trash"), role: .destructive) {
                        model.clean()
                    }
                    .disabled(model.selected.isEmpty || model.isCleaning || model.isScanning)
                }
                Toggle("Include Apple system caches (com.apple.*)", isOn: $model.includeApple)
                    .onChange(of: model.includeApple) { _, _ in model.scan() }
                Toggle("Delete permanently instead of moving to the Trash", isOn: $model.permanently)
                Defaults.Toggle(key: .showCleanerButton) {
                    Text("Show cleaner button (🧹) in the notch")
                }
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Caches are files apps can re-create; apps may be slower the first time after cleaning. Caches of apps that are running are not selected by default; quit those apps first if you want to clean them.")
            }

            if !model.entries.isEmpty {
                Section {
                    HStack {
                        Button("Select All") { model.selected = Set(model.entries.map(\.path)) }
                        Button("Select None") { model.selected.removeAll() }
                        Spacer()
                        Button("Open Caches Folder") {
                            if let first = model.entries.first {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first.path)])
                            }
                        }
                    }
                    .buttonStyle(.link)

                    ForEach(model.entries) { entry in
                        let running = model.isRunning(entry)
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { model.selected.contains(entry.path) },
                                set: { isOn in
                                    if isOn { model.selected.insert(entry.path) } else { model.selected.remove(entry.path) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            Image(nsImage: model.icon(for: entry))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.displayName(for: entry))
                                    .lineLimit(1)
                                if model.displayName(for: entry) != entry.name {
                                    Text(entry.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if running {
                                Text("Running")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(format(entry.bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(model.entries.count) cache folders in ~/Library/Caches")
                }
            }
        }
        .onAppear { if model.entries.isEmpty { model.scan() } }
        .accentColor(.effectiveAccent)
        .navigationTitle("Cleaner")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Notch panel

extension Defaults.Keys {
    static let showCleanerButton = Key<Bool>("showCleanerButton", default: true)
}

/// Compact cleaner shown inside the open notch (opened from the 🧹 header button).
struct NotchCleanerView: View {
    @StateObject private var model = CacheCleanerModel()
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Summary + actions
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.cyan)
                    Text("Cleaner")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Button {
                        coordinator.currentView = .home
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)
                    .help("Close")
                }
                Text(model.isScanning && model.entries.isEmpty ? "…" : format(model.totalBytes))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Selected \(format(model.selectedBytes))")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                Toggle("Delete permanently", isOn: $model.permanently)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                HStack(spacing: 6) {
                    Button {
                        model.scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 22)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(model.isScanning || model.isCleaning)
                    .help("Scan again")

                    Button {
                        model.clean()
                    } label: {
                        Text(model.isCleaning ? "Cleaning…" : "Clean")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(model.selected.isEmpty ? Color.white.opacity(0.2) : Color.white.opacity(0.9)))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selected.isEmpty || model.isCleaning || model.isScanning)
                }
            }
            .frame(width: 150, alignment: .leading)

            // List
            VStack(alignment: .leading, spacing: 4) {
                if let message = model.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .lineLimit(2)
                }
                if model.isScanning && model.entries.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack {
                        Text("\(model.entries.count) app caches")
                        Spacer()
                        Button("All") { model.selected = Set(model.entries.map(\.path)) }
                        Button("None") { model.selected.removeAll() }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .buttonStyle(.plain)

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(model.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if model.entries.isEmpty { model.scan() } }
    }

    private func row(_ entry: CacheEntry) -> some View {
        let running = model.isRunning(entry)
        let isOn = model.selected.contains(entry.path)
        return HStack(spacing: 6) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(isOn ? Color.cyan : Color.gray)
            Image(nsImage: model.icon(for: entry))
                .resizable()
                .frame(width: 14, height: 14)
            Text(model.displayName(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
            if running {
                Text("Running")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            Text(format(entry.bytes))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(isOn ? 0.08 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { model.selected.remove(entry.path) } else { model.selected.insert(entry.path) }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
