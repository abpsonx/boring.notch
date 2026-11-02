//
//  ConversionCenter.swift
//  boringNotch
//
//  Runs file conversions, saves the results to ~/Downloads/Converted, adds
//  them to the shelf, and shows progress / result (with Open and Show in
//  Finder) in the notch.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
final class ConversionCenter: ObservableObject {
    static let shared = ConversionCenter()

    enum Phase: Equatable {
        case idle
        case running(index: Int, total: Int, fileName: String, target: String)
        case finished(outputs: [URL], failures: [String])
    }

    @Published private(set) var phase: Phase = .idle
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// ~/Downloads/Converted (real path, not the sandbox container).
    var outputFolder: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = URL(fileURLWithPath: NSHomeDirectory())
        }
        return home.appendingPathComponent("Downloads/Converted", isDirectory: true)
    }

    var outputs: [URL] {
        if case .finished(let outputs, _) = phase { return outputs }
        return []
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Run

    func run(urls: [URL], targetID: String) {
        guard !urls.isEmpty else { return }
        dismissTask?.cancel()

        Task { @MainActor in
            var results: [URL] = []
            var failures: [String] = []

            for (index, url) in urls.enumerated() {
                let target = FileConversionService.target(withID: targetID, for: url)
                withAnimation(.smooth) {
                    phase = .running(index: index + 1, total: urls.count, fileName: url.lastPathComponent, target: target?.title ?? "")
                }
                // Let the progress UI render before the (synchronous) conversion runs.
                try? await Task.sleep(for: .milliseconds(120))

                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard let target else {
                        throw FileConversionError.unsupported("can't be converted to that format.")
                    }
                    let temporary = try FileConversionService.convert(url, to: target)
                    // File moves happen off the main thread so a privacy prompt can't freeze the notch.
                    let folder = outputFolder
                    let moved = await Task.detached(priority: .userInitiated) {
                        Self.moveToOutputFolder(temporary, folder: folder)
                    }.value
                    results.append(moved)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            addToShelf(results)
            withAnimation(.smooth) { phase = .finished(outputs: results, failures: failures) }
            scheduleDismiss(after: failures.isEmpty ? 10 : 20)
        }
    }

    // MARK: - Actions

    func revealOutputs() {
        let urls = outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            NSWorkspace.shared.open(outputFolder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        dismiss()
    }

    func openOutputs() {
        for url in outputs.prefix(5) {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.smooth) { phase = .idle }
    }

    /// Keep the result visible while the pointer is over it.
    func pauseAutoDismiss(_ paused: Bool) {
        guard case .finished = phase else { return }
        if paused { dismissTask?.cancel() } else { scheduleDismiss(after: 6) }
    }

    // MARK: - Helpers

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    /// Moves a converted file/folder from the temp folder to ~/Downloads/Converted,
    /// adding " 2", " 3", … if the name is taken. Falls back to the temp location.
    nonisolated private static func moveToOutputFolder(_ source: URL, folder outputFolder: URL) -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var destination = outputFolder.appendingPathComponent(source.lastPathComponent)
            var counter = 2
            while fileManager.fileExists(atPath: destination.path) {
                let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                destination = outputFolder.appendingPathComponent(name)
                counter += 1
            }
            try fileManager.moveItem(at: source, to: destination)
            try? fileManager.removeItem(at: source.deletingLastPathComponent()) // empty temp folder
            return destination
        } catch {
            NSLog("Couldn't move converted file to Downloads/Converted: \(error)")
            return source
        }
    }

    private func addToShelf(_ urls: [URL]) {
        let items: [ShelfItem] = urls.compactMap { url in
            guard let bookmark = try? Bookmark(url: url) else { return nil }
            let isTemporary = url.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path)
            return ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: isTemporary)
        }
        if !items.isEmpty { ShelfStateViewModel.shared.add(items) }
    }
}

// MARK: - Open notch banner

/// Shown at the bottom of the open notch while converting / after converting.
struct ConversionStatusBanner: View {
    @ObservedObject var center = ConversionCenter.shared

    var body: some View {
        if center.isActive {
            HStack(spacing: 8) {
                switch center.phase {
                case .running(let index, let total, let fileName, let target):
                    ProgressView()
                        .controlSize(.small)
                    Text("Converting \(fileName) → \(target)" + (total > 1 ? "  (\(index)/\(total))" : ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)

                case .finished(let outputs, let failures):
                    Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : (outputs.isEmpty ? "xmark.circle.fill" : "exclamationmark.circle.fill"))
                        .foregroundStyle(failures.isEmpty ? Color.green : (outputs.isEmpty ? Color.red : Color.orange))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary(outputs: outputs, failures: failures))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let firstFailure = failures.first {
                            Text(firstFailure)
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(failures.joined(separator: "\n"))
                        } else {
                            Text("Saved to Downloads › Converted")
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                    }
                    Spacer(minLength: 0)
                    if !outputs.isEmpty {
                        pill("Open", icon: "arrow.up.forward.app", prominent: false) { center.openOutputs() }
                        pill("Show in Finder", icon: "folder", prominent: true) { center.revealOutputs() }
                    }
                    Button { center.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)

                case .idle:
                    EmptyView()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.13))
                    .shadow(color: .black.opacity(0.5), radius: 8)
            )
            .onHover { center.pauseAutoDismiss($0) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func summary(outputs: [URL], failures: [String]) -> String {
        if outputs.isEmpty { return "Conversion failed" }
        if outputs.count == 1 { return "Converted: \(outputs[0].lastPathComponent)" }
        return "\(outputs.count) files converted" + (failures.isEmpty ? "" : ", \(failures.count) failed")
    }

    private func pill(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(prominent ? Color.white.opacity(0.9) : Color.white.opacity(0.12)))
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Closed notch

/// Compact status around the closed notch; click reveals the results in Finder.
struct ConversionLiveActivity: View {
    let phase: ConversionCenter.Phase
    let middleWidth: CGFloat
    let height: CGFloat
    let showsTextInMiddle: Bool

    private let sideWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if case .finished(let outputs, _) = phase {
                    Image(systemName: outputs.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(outputs.isEmpty ? Color.red : Color.green)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 14))
            .frame(width: sideWidth, alignment: .leading)
            .padding(.leading, 4)

            ZStack {
                Rectangle().fill(.black)
                if showsTextInMiddle {
                    Text(middleText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                }
            }
            .frame(width: middleWidth)

            Text(rightText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isFinished ? Color.green : Color.white)
                .lineLimit(1)
                .frame(width: sideWidth, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .frame(height: height, alignment: .center)
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    private var middleText: String {
        switch phase {
        case .running(_, _, let fileName, let target): return "\(fileName) → \(target)"
        case .finished(let outputs, _): return outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files · Downloads › Converted"
        case .idle: return ""
        }
    }

    private var rightText: String {
        switch phase {
        case .running(let index, let total, _, _): return total > 1 ? "\(index)/\(total)" : "…"
        case .finished(let outputs, _): return outputs.isEmpty ? "Failed" : "Done"
        case .idle: return ""
        }
    }
}
