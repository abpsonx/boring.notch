//
//  ClipboardHistoryView.swift
//  boringNotch
//
//  Notch tab showing clipboard history and recent screenshots.
//  Click = copy again (then ⌘V anywhere), drag = drop into another app.
//

import Defaults
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var manager = ClipboardHistoryManager.shared
    @Default(.clipboardHistoryEnabled) var enabled
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case text = "Text"
        case images = "Images"
        var id: String { rawValue }
    }

    private var filteredItems: [ClipboardItem] {
        switch filter {
        case .all: return manager.items
        case .text: return manager.items.filter { if case .text = $0.kind { return true } else { return false } }
        case .images: return manager.items.filter(\.isImage)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if !enabled {
                placeholder(icon: "doc.on.clipboard", text: "Clipboard history is turned off in Settings")
            } else if filteredItems.isEmpty {
                placeholder(icon: "doc.on.clipboard", text: manager.items.isEmpty ? "Copy something or take a screenshot" : "Nothing here yet")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            ClipboardItemCard(item: item, copied: manager.lastCopiedID == item.id)
                                .onTapGesture { manager.copy(item) }
                                .onDrag { manager.itemProvider(for: item) }
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Spacer()

            if manager.screenshotFolder != nil {
                Label("Watching screenshots", systemImage: "camera.viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }

            if !manager.items.isEmpty {
                Button {
                    withAnimation(.smooth) { manager.clear() }
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button("Copy") { manager.copy(item) }
        if item.fileURL != nil, !(item.kind.isTemporaryImage) {
            Button("Show in Finder") { manager.reveal(item) }
        }
        Divider()
        Button("Remove from History") {
            withAnimation(.smooth) { manager.remove(item) }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ClipboardItem.Kind {
    var isTemporaryImage: Bool {
        if case .image = self { return true }
        return false
    }
}

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let copied: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            preview
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 4) {
                Image(systemName: badgeIcon)
                    .font(.system(size: 9))
                Text(item.isImage ? item.title : (item.sourceApp ?? "Text"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .lineLimit(1)
            }
            .font(.system(size: 9))
            .foregroundStyle(.gray)
            .frame(width: 112)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
        )
        .overlay {
            if copied {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.6))
                    .overlay {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: copied)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    @ViewBuilder
    private var preview: some View {
        if case .text(let text) = item.kind {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
                .background(Color.white.opacity(0.06))
        } else if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: item.isImage ? .fill : .fit)
                .padding(item.isImage ? 0 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
        } else {
            Image(systemName: "doc")
                .font(.title)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
        }
    }

    private var badgeIcon: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .screenshot: return "camera.viewfinder"
        }
    }

    private var helpText: String {
        switch item.kind {
        case .text(let text): return String(text.prefix(300))
        default: return item.title
        }
    }
}
