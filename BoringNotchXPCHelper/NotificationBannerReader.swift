//
//  NotificationBannerReader.swift
//  BoringNotchXPCHelper
//
//  Reads the notification banners currently shown by macOS (the
//  NotificationCenter process) through the Accessibility API so the app can
//  mirror them in the notch. Requires Accessibility permission.
//

import AppKit
import ApplicationServices
import Foundation

/// Must match `NotchBannerPayload` in the app.
struct NotificationBannerPayload: Codable {
    let key: String
    let texts: [String]
    let description: String?
    let identifier: String?
    let title: String?
    /// Custom accessibility actions offered by the banner (e.g. "Reply", "Balas").
    let actions: [String]
    let canReply: Bool
}

enum NotificationBannerReader {
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private static let maxDepth = 14
    /// Localized names of the banner's reply action.
    private static let replyKeywords = ["reply", "balas", "respond", "antwort", "répondre", "responder", "rispondi", "返信", "回复", "답장"]

    // MARK: - Public

    static func readBanners() -> [NotificationBannerPayload] {
        guard AXIsProcessTrusted() else { return [] }
        return bannerElements().map { payload(for: $0) }
    }

    /// Clicks the banner with the given key (same as clicking the macOS banner).
    static func pressBanner(withKey key: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for element in bannerElements() where payload(for: element).key == key {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }
            // Some banners expose the action on a child instead.
            for child in children(of: element) where actions(of: child).contains(kAXPressAction as String) {
                if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success { return true }
            }
        }
        return false
    }

    /// Triggers the banner's own inline reply UI (Messages, WhatsApp, ...).
    static func replyToBanner(withKey key: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for element in bannerElements() where payload(for: element).key == key {
            for (target, action) in customActions(in: element) where isReplyAction(action) {
                if AXUIElementPerformAction(target, action as CFString) == .success { return true }
            }
        }
        return false
    }

    /// Text dump of the NotificationCenter accessibility tree, for troubleshooting.
    static func debugDump() -> String {
        guard AXIsProcessTrusted() else { return "Accessibility permission not granted to the helper." }
        guard let app = notificationCenterApp() else { return "NotificationCenter process not found." }
        var lines: [String] = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        let windows = windows(of: app)
        lines.append("windows: \(windows.count)")
        for window in windows {
            dump(window, depth: 0, into: &lines)
        }
        lines.append("--- detected banners ---")
        for banner in readBanners() {
            lines.append("texts=\(banner.texts) desc=\(banner.description ?? "-") id=\(banner.identifier ?? "-") title=\(banner.title ?? "-") actions=\(banner.actions) canReply=\(banner.canReply)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tree walking

    private static func notificationCenterApp() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []
    }

    private static func bannerElements() -> [AXUIElement] {
        guard let app = notificationCenterApp() else { return [] }
        var bySubrole: [AXUIElement] = []
        var pressableGroups: [AXUIElement] = []
        for window in windows(of: app) {
            collect(window, depth: 0, bySubrole: &bySubrole, pressableGroups: &pressableGroups)
        }
        return bySubrole.isEmpty ? pressableGroups : bySubrole
    }

    private static func collect(_ element: AXUIElement, depth: Int, bySubrole: inout [AXUIElement], pressableGroups: inout [AXUIElement]) {
        guard depth <= maxDepth else { return }
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        let role: String? = attribute(element, kAXRoleAttribute)

        // e.g. AXNotificationCenterBanner / AXNotificationCenterAlert
        if let subrole, subrole.hasPrefix("AXNotificationCenter"), !subrole.contains("Stack") {
            bySubrole.append(element)
            return
        }

        let kids = children(of: element)

        // Fallback: innermost clickable group that contains text.
        if role == kAXGroupRole as String,
           actions(of: element).contains(kAXPressAction as String),
           !staticTexts(in: element, depth: 0).isEmpty
        {
            var nested: [AXUIElement] = []
            var nestedSub: [AXUIElement] = []
            for child in kids { collect(child, depth: depth + 1, bySubrole: &nestedSub, pressableGroups: &nested) }
            bySubrole.append(contentsOf: nestedSub)
            if nested.isEmpty { pressableGroups.append(element) } else { pressableGroups.append(contentsOf: nested) }
            return
        }

        for child in kids {
            collect(child, depth: depth + 1, bySubrole: &bySubrole, pressableGroups: &pressableGroups)
        }
    }

    private static func payload(for element: AXUIElement) -> NotificationBannerPayload {
        let texts = staticTexts(in: element, depth: 0)
        let description: String? = attribute(element, kAXDescriptionAttribute)
        let identifier: String? = attribute(element, kAXIdentifierAttribute)
        let title: String? = attribute(element, kAXTitleAttribute)
        let key = ([description ?? "", identifier ?? ""] + texts).joined(separator: "\u{1F}")
        let actionNames = customActions(in: element).map { displayName(of: $0.action) }
        return NotificationBannerPayload(
            key: key,
            texts: texts,
            description: description?.nilIfEmpty,
            identifier: identifier?.nilIfEmpty,
            title: title?.nilIfEmpty,
            actions: actionNames,
            canReply: actionNames.contains { isReplyAction($0) }
        )
    }

    private static func staticTexts(in element: AXUIElement, depth: Int) -> [String] {
        guard depth <= maxDepth else { return [] }
        var result: [String] = []
        let role: String? = attribute(element, kAXRoleAttribute)
        if role == kAXStaticTextRole as String {
            if let value: String = attribute(element, kAXValueAttribute), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(value)
            } else if let value: String = attribute(element, kAXDescriptionAttribute), !value.isEmpty {
                result.append(value)
            }
        }
        if role == kAXButtonRole as String { return result } // skip "Close", "Options", ...
        for child in children(of: element) {
            result.append(contentsOf: staticTexts(in: child, depth: depth + 1))
        }
        return result
    }

    private static func dump(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth <= maxDepth, lines.count < 400 else { return }
        let role: String = attribute(element, kAXRoleAttribute) ?? "?"
        let subrole: String = attribute(element, kAXSubroleAttribute) ?? ""
        let desc: String = attribute(element, kAXDescriptionAttribute) ?? ""
        let ident: String = attribute(element, kAXIdentifierAttribute) ?? ""
        let title: String = attribute(element, kAXTitleAttribute) ?? ""
        let value: String = attribute(element, kAXValueAttribute) ?? ""
        let acts = actions(of: element).joined(separator: ",")
        let pad = String(repeating: "  ", count: depth)
        lines.append("\(pad)\(role) [\(subrole)] desc=\(desc.prefix(80)) title=\(title.prefix(60)) value=\(value.prefix(80)) id=\(ident) actions=\(acts)")
        for child in children(of: element) {
            dump(child, depth: depth + 1, into: &lines)
        }
    }

    // MARK: - Actions

    private static let standardActions: Set<String> = [
        kAXPressAction as String, kAXShowMenuAction as String, kAXCancelAction as String,
        kAXConfirmAction as String, kAXRaiseAction as String, kAXPickAction as String,
        kAXIncrementAction as String, kAXDecrementAction as String, "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI",
    ]

    /// Non-standard actions on the banner and its direct children.
    private static func customActions(in element: AXUIElement) -> [(target: AXUIElement, action: String)] {
        var result: [(AXUIElement, String)] = []
        for target in [element] + children(of: element) {
            for action in actions(of: target) where !standardActions.contains(action) {
                result.append((target, action))
            }
        }
        return result
    }

    /// Custom actions look like "Name:Reply\nTarget:0x0\nSelector:(null)".
    private static func displayName(of action: String) -> String {
        let firstLine = action.components(separatedBy: "\n").first ?? action
        return firstLine.hasPrefix("Name:") ? String(firstLine.dropFirst(5)) : firstLine
    }

    private static func isReplyAction(_ action: String) -> Bool {
        let name = displayName(of: action).lowercased()
        return replyKeywords.contains { name.contains($0) }
    }

    // MARK: - AX helpers

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        return value as? T
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] else {
            return []
        }
        return names
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
