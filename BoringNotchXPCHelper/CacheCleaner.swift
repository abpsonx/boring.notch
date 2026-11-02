//
//  CacheCleaner.swift
//  BoringNotchXPCHelper
//
//  Lists and removes folders inside ~/Library/Caches. Runs in the (unsandboxed)
//  helper because the app's sandbox can't see other apps' caches.
//
//  Safety: only *direct children* of ~/Library/Caches are ever touched; any
//  other path is refused. Items go to the Trash unless permanent deletion is
//  explicitly requested.
//

import Foundation

struct CacheEntryPayload: Codable {
    let path: String
    let name: String
    let bytes: Int64
}

struct CacheRemovalResult: Codable {
    let removed: [String]
    let failed: [String: String]
    let freedBytes: Int64
}

enum CacheCleaner {
    static var cachesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    static func scan(includeApple: Bool) -> [CacheEntryPayload] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil, options: []) else {
            return []
        }
        var entries: [CacheEntryPayload] = []
        for url in children {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            if !includeApple && name.lowercased().hasPrefix("com.apple.") { continue }
            let bytes = allocatedSize(of: url)
            if bytes <= 0 { continue }
            entries.append(CacheEntryPayload(path: url.path, name: name, bytes: bytes))
        }
        return entries.sorted { $0.bytes > $1.bytes }
    }

    static func remove(paths: [String], permanently: Bool) -> CacheRemovalResult {
        let fileManager = FileManager.default
        let root = cachesURL.standardizedFileURL
        var removed: [String] = []
        var failed: [String: String] = [:]
        var freed: Int64 = 0

        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            // Only direct children of ~/Library/Caches, no symlink tricks.
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
                  !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".."
            else {
                failed[path] = "Refused: not inside ~/Library/Caches"
                continue
            }
            let size = allocatedSize(of: url)
            do {
                if permanently {
                    try fileManager.removeItem(at: url)
                } else {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                }
                removed.append(path)
                freed += size
            } catch {
                failed[path] = error.localizedDescription
            }
        }
        return CacheRemovalResult(removed: removed, failed: failed, freedBytes: freed)
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
