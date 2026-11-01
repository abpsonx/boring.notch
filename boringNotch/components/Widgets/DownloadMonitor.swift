//
//  DownloadMonitor.swift
//  boringNotch
//
//  Watches ~/Downloads for in-progress browser downloads and shows their
//  progress in the closed notch.
//
//  • Safari:   "name.download" bundles — progress read from their Info.plist
//  • Chromium: "name.crdownload" (Chrome, Edge, Brave, Arc, Opera, Vivaldi)
//  • Firefox:  "name.part"
//  Exact percentages also come from the file progress browsers publish to
//  Finder (NSProgress), when available; otherwise the size so far is shown.
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let downloadProgressEnabled = Key<Bool>("downloadProgressEnabled", default: true)
}

struct DownloadItem: Identifiable, Equatable {
    let id: String            // temp file path
    let fileName: String      // final name, e.g. "report.pdf"
    var bytes: Int64
    var total: Int64?
    var fraction: Double?     // 0...1 when known
    var isFinished = false
    var finalURL: URL?

    var progressText: String {
        if isFinished { return "Done" }
        if let fraction { return "\(Int((fraction * 100).rounded()))%" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class DownloadMonitor: ObservableObject {
    static let shared = DownloadMonitor()

    /// Download shown in the notch (in progress, or just finished for a few seconds).
    @Published private(set) var current: DownloadItem?
    @Published private(set) var activeCount = 0

    private var tracked: [String: DownloadItem] = [:]
    private var publishedFractions: [String: Double] = [:]  // keyed by temp file name
    private var timer: Timer?
    private var subscriber: Any?
    private var progressObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var finishedTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let tempExtensions = ["crdownload", "download", "part", "partial", "opdownload"]

    private let downloadsURL: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }()

    private init() {}

    func start() {
        Defaults.publisher(.downloadProgressEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    change.newValue ? self?.startWatching() : self?.stopWatching()
                }
            }
            .store(in: &cancellables)
    }

    private func startWatching() {
        guard timer == nil else { return }
        // Seed with downloads already running so we don't announce stale files as new.
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        timer?.tolerance = 0.3

        // Exact progress published by browsers (the same progress Finder shows on file icons).
        subscriber = Progress.addSubscriber(forFileURL: downloadsURL) { [weak self] progress in
            Task { @MainActor in self?.observe(progress) }
            return { [weak self] in
                Task { @MainActor in self?.progressObservers[ObjectIdentifier(progress)] = nil }
            }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        progressObservers.removeAll()
        tracked.removeAll()
        publishedFractions.removeAll()
        current = nil
        activeCount = 0
    }

    private func observe(_ progress: Progress) {
        guard let url = progress.fileURL else { return }
        let name = url.lastPathComponent
        progressObservers[ObjectIdentifier(progress)] = progress.publisher(for: \.fractionCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    if fraction > 0 && fraction < 1 { self.publishedFractions[name] = fraction }
                }
            }
    }

    // MARK: - Scanning

    private func scan() {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return
        }

        var seen = Set<String>()
        for url in urls where tempExtensions.contains(url.pathExtension.lowercased()) {
            let id = url.path
            seen.insert(id)
            var item = tracked[id] ?? DownloadItem(id: id, fileName: finalName(for: url), bytes: 0)
            let info = progressInfo(for: url)
            item.bytes = info.bytes
            item.total = info.total
            if let total = info.total, total > 0 {
                item.fraction = min(1, Double(info.bytes) / Double(total))
            } else if let published = publishedFractions[url.lastPathComponent] {
                item.fraction = published
            }
            tracked[id] = item
        }

        // Temp files that disappeared: finished (final file exists) or cancelled.
        for (id, item) in tracked where !seen.contains(id) {
            tracked[id] = nil
            publishedFractions[URL(fileURLWithPath: id).lastPathComponent] = nil
            let finalURL = downloadsURL.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                showFinished(item, finalURL: finalURL)
            }
        }

        activeCount = tracked.count
        if let active = tracked.values.sorted(by: { $0.id < $1.id }).first {
            finishedTask?.cancel()
            if current != active {
                withAnimation(.smooth) { current = active }
            }
        } else if current?.isFinished != true, current != nil {
            withAnimation(.smooth) { current = nil }
        }
    }

    private func showFinished(_ item: DownloadItem, finalURL: URL) {
        guard tracked.isEmpty else { return }
        var done = item
        done.isFinished = true
        done.fraction = 1
        done.finalURL = finalURL
        withAnimation(.smooth) { current = done }
        finishedTask?.cancel()
        finishedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            if self.current?.isFinished == true {
                withAnimation(.smooth) { self.current = nil }
            }
        }
    }

    func revealCurrent() {
        guard let url = current?.finalURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        withAnimation(.smooth) { current = nil }
    }

    // MARK: - Helpers

    private func finalName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        // Chrome: "Unconfirmed 12345.crdownload" before the name is known.
        if name.hasPrefix("Unconfirmed ") { name = "Downloading…" }
        return name
    }

    private func progressInfo(for url: URL) -> (bytes: Int64, total: Int64?) {
        let ext = url.pathExtension.lowercased()
        if ext == "download" {
            // Safari bundle: Info.plist holds the byte counts.
            let plistURL = url.appendingPathComponent("Info.plist")
            if let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] {
                let soFar = (dict["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
                let total = (dict["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value
                return (soFar, (total ?? 0) > 0 ? total : nil)
            }
            return (directorySize(url), nil)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        return (size, nil)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Closed notch view

/// Download progress around the closed notch: ring on the left, percentage on
/// the right, file name in the middle on Macs without a camera notch.
struct DownloadLiveActivity: View {
    let item: DownloadItem
    let activeCount: Int
    let middleWidth: CGFloat
    let height: CGFloat
    let showsNameInMiddle: Bool

    private let sideWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                if let fraction = item.fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(item.isFinished ? Color.green : Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth, value: fraction)
                } else {
                    IndeterminateArc()
                }
                Image(systemName: item.isFinished ? "checkmark" : "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(item.isFinished ? Color.green : Color.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 18, height: 18)
            .frame(width: sideWidth, alignment: .leading)
            .padding(.leading, 4)

            ZStack {
                Rectangle().fill(.black)
                if showsNameInMiddle {
                    Text(activeCount > 1 ? "\(item.fileName)  +\(activeCount - 1)" : item.fileName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                }
            }
            .frame(width: middleWidth)

            Text(item.progressText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(item.isFinished ? Color.green : Color.white)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: sideWidth, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .frame(height: height, alignment: .center)
    }
}

private struct IndeterminateArc: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

// MARK: - Rainbow visualizer fill

/// Rainbow gradient whose hues slowly rotate; used as the music visualizer fill.
struct RainbowFill: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            LinearGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
                startPoint: .leading,
                endPoint: .trailing
            )
            .hueRotation(.degrees(phase * 360))
        }
    }
}
