//
//  CacheCleanerView.swift
//  boringNotch
//
//  Settings page that lists ~/Library/Caches per app (via the XPC helper)
//  and moves the selected caches to the Trash (or deletes them).
//

import AppKit
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
