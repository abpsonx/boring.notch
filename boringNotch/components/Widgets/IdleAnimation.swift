//
//  IdleAnimation.swift
//  boringNotch
//
//  Your own animation (GIF or Lottie .json) shown in the closed notch when
//  nothing else is happening — standing in the middle, or walking back and
//  forth along the notch. The chosen file is copied into the app's own folder.
//

import AppKit
import Defaults
import Lottie
import SwiftUI
import UniformTypeIdentifiers

enum IdleAnimationMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case center = "Diam di tengah"
    case walk = "Jalan bolak-balik"
    var id: String { rawValue }
}

extension Defaults.Keys {
    static let idleAnimationEnabled = Key<Bool>("idleAnimationEnabled", default: false)
    static let idleAnimationFileName = Key<String>("idleAnimationFileName", default: "")
    static let idleAnimationMode = Key<IdleAnimationMode>("idleAnimationMode", default: .walk)
    static let idleAnimationSpeed = Key<Double>("idleAnimationSpeed", default: 1.0)
    /// Animation height relative to the notch (1 = fits inside; bigger grows the notch downward).
    static let idleAnimationScale = Key<Double>("idleAnimationScale", default: 2.0)
}

enum IdleAnimationStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("BoringNotch/IdleAnimation", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The stored animation file, if one was chosen and still exists.
    static var currentURL: URL? {
        let name = Defaults[.idleAnimationFileName]
        guard !name.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isReady: Bool { Defaults[.idleAnimationEnabled] && currentURL != nil }

    /// Lets the user pick a GIF / Lottie file and copies it in.
    @MainActor
    static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gif, .json]
        panel.message = "Choose a GIF or a Lottie animation (.json)"
        panel.prompt = "Use Animation"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        // Replace the previous file.
        if let old = currentURL { try? FileManager.default.removeItem(at: old) }
        let name = "idle-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            Defaults[.idleAnimationFileName] = name
            Defaults[.idleAnimationEnabled] = true
        } catch {
            NSLog("Couldn't copy idle animation: \(error)")
        }
    }

    static func remove() {
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        Defaults[.idleAnimationFileName] = ""
        Defaults[.idleAnimationEnabled] = false
    }
}

// MARK: - Player

/// Plays a GIF or a Lottie file, scaled to fit.
struct IdleAnimationPlayer: View {
    let url: URL
    var speed: Double = 1

    var body: some View {
        if url.pathExtension.lowercased() == "gif" {
            AnimatedGIFView(url: url)
        } else {
            LottieView(url: url, speed: speed, loopMode: .loop)
        }
    }
}

private struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.canDrawSubviewsIntoLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if (view.image?.name() ?? "") != url.lastPathComponent {
            let image = NSImage(contentsOf: url)
            _ = image?.setName(url.lastPathComponent)
            view.image = image
        }
    }
}

// MARK: - Closed notch

/// The idle animation around the closed notch.
struct IdleAnimationActivity: View {
    let url: URL
    let notchWidth: CGFloat
    let height: CGFloat
    let hasPhysicalNotch: Bool
    @Default(.idleAnimationMode) var mode
    @Default(.idleAnimationSpeed) var speed
    @Default(.idleAnimationScale) var scale

    private var size: CGFloat { max(16, (height - 4) * CGFloat(scale)) }
    /// The closed notch grows downward when the animation is taller than the notch.
    private var areaHeight: CGFloat { max(height, size + 6) }
    private var trackWidth: CGFloat { notchWidth + 2 * max(0, height - 12) + 20 }

    var body: some View {
        Group {
            if mode == .walk {
                walking
            } else {
                standing
            }
        }
        .frame(width: trackWidth, height: areaHeight, alignment: .bottom)
        .padding(.bottom, areaHeight > height ? 6 : 0)
        .clipped()
    }

    /// In the middle on Macs without a camera notch, beside it on Macs with one.
    private var standing: some View {
        HStack {
            if hasPhysicalNotch && size <= height {
                // Small: next to the camera notch.
                Spacer()
                IdleAnimationPlayer(url: url, speed: speed)
                    .frame(width: size, height: size)
                    .padding(.trailing, 6)
            } else {
                Spacer()
                IdleAnimationPlayer(url: url, speed: speed)
                    .frame(width: size * 1.6, height: size)
                Spacer()
            }
        }
    }

    /// Walks left → right → left along the notch, facing the walking direction.
    private var walking: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let travel = max(1, trackWidth - size)
            let secondsPerLap = max(4, Double(travel) / (28 * max(0.25, speed)))   // ~28 pt/s
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: secondsPerLap * 2)
            let goingRight = t < secondsPerLap
            let progress = goingRight ? t / secondsPerLap : 2 - t / secondsPerLap
            IdleAnimationPlayer(url: url, speed: speed)
                .frame(width: size, height: size)
                .scaleEffect(x: goingRight ? 1 : -1, y: 1)
                .offset(x: CGFloat(progress) * travel)
                .frame(width: trackWidth, height: areaHeight, alignment: .bottomLeading)
        }
    }
}

// MARK: - Settings

struct IdleAnimationSettingsSection: View {
    @Default(.idleAnimationEnabled) var enabled
    @Default(.idleAnimationFileName) var fileName
    @Default(.idleAnimationMode) var mode
    @Default(.idleAnimationSpeed) var speed

    var body: some View {
        Section {
            Toggle("Show an animation when the notch is idle", isOn: $enabled)
                .disabled(IdleAnimationStore.currentURL == nil)
            HStack {
                if let url = IdleAnimationStore.currentURL, !fileName.isEmpty {
                    IdleAnimationPlayer(url: url, speed: speed)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                        .id(fileName)
                    Text(url.pathExtension.uppercased() + " animation")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No animation chosen")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(fileName.isEmpty ? "Choose GIF / Lottie…" : "Change…") { IdleAnimationStore.choose() }
                if !fileName.isEmpty {
                    Button("Remove", role: .destructive) { IdleAnimationStore.remove() }
                }
            }
            Picker("Style", selection: $mode) {
                ForEach(IdleAnimationMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(fileName.isEmpty)
            HStack {
                Text("Size")
                Slider(value: $scale, in: 1...4, step: 0.25)
                Text(String(format: "%.2g×", scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
            .disabled(fileName.isEmpty)
            HStack {
                Text("Speed")
                Slider(value: $speed, in: 0.5...2, step: 0.25)
                Text(String(format: "%.2g×", speed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
            .disabled(fileName.isEmpty)
        } header: {
            Text("Idle animation")
        } footer: {
            Text("Use any GIF (e.g. a chibi/anime sticker from GIPHY or Tenor; transparent background looks best) or a Lottie .json from LottieFiles. Shown when no music, notification or reminder is on the notch.")
        }
    }
}
