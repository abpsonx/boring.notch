//
//  GoogleTasksService.swift
//  boringNotch
//
//  Google Tasks integration.
//
//  Sign-in uses Google's OAuth flow for desktop apps: the browser opens Google's
//  sign-in page and redirects back to a temporary local web server
//  (http://127.0.0.1:<port>) with PKCE. The password never passes through this
//  app; the refresh token is stored in the macOS Keychain.
//
//  You need your own OAuth client (type "Desktop app") from Google Cloud Console
//  with the Google Tasks API enabled; paste its Client ID/Secret in Settings → Tasks.
//

import AppKit
import Combine
import CryptoKit
import Defaults
import Foundation
import Network
import Security

extension Defaults.Keys {
    static let googleClientID = Key<String>("googleClientID", default: "")
    static let googleClientSecret = Key<String>("googleClientSecret", default: "")
    static let googleTaskListIDs = Key<[String]>("googleTaskListIDs", default: [])   // empty = all lists
    static let googleAccountEmail = Key<String>("googleAccountEmail", default: "")
}

struct GoogleTaskList: Identifiable, Hashable, Decodable {
    let id: String
    let title: String
}

struct GoogleTask: Identifiable, Hashable {
    let id: String
    let listID: String
    let listTitle: String
    var title: String
    var notes: String?
    var due: Date?          // Google stores a date only (time is ignored)
    var isCompleted: Bool
    var completedAt: Date?
}

@MainActor
final class GoogleTasksManager: ObservableObject {
    static let shared = GoogleTasksManager()

    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var lists: [GoogleTaskList] = []
    @Published private(set) var tasks: [GoogleTask] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastSync: Date?

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshTimer: Timer?
    private var loopback: LoopbackReceiver?

    private static let scope = "https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/userinfo.email"
    private static let keychainService = "boringnotch.google.tasks"

    private init() {
        isConnected = Keychain.read(service: Self.keychainService) != nil
    }

    func start() {
        guard isConnected else { return }
        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var hasClientCredentials: Bool {
        !Defaults[.googleClientID].trimmingCharacters(in: .whitespaces).isEmpty
            && !Defaults[.googleClientSecret].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Open tasks first (by due date), then the ones completed today.
    var visibleTasks: [GoogleTask] {
        let calendar = Calendar.current
        let open = tasks.filter { !$0.isCompleted }
            .sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
        let doneToday = tasks.filter { $0.isCompleted && ($0.completedAt.map { calendar.isDateInToday($0) } ?? false) }
        return open + doneToday
    }

    // MARK: - Sign in / out

    func connect() {
        guard hasClientCredentials else {
            lastError = "Enter your Google Client ID and Client Secret first."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        lastError = nil

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(length: 24)

        let receiver = LoopbackReceiver()
        loopback = receiver
        receiver.start { [weak self] port in
            Task { @MainActor in
                guard let self else { return }
                guard let port else {
                    self.fail("Couldn't start the local sign-in listener.")
                    return
                }
                let redirect = "http://127.0.0.1:\(port)"
                var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                components.queryItems = [
                    URLQueryItem(name: "client_id", value: Defaults[.googleClientID].trimmingCharacters(in: .whitespaces)),
                    URLQueryItem(name: "redirect_uri", value: redirect),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: Self.scope),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"),
                    URLQueryItem(name: "state", value: state),
                ]
                NSWorkspace.shared.open(components.url!)

                receiver.waitForRedirect { [weak self] query in
                    Task { @MainActor in
                        guard let self else { return }
                        self.loopback = nil
                        guard let query else { self.fail("Sign-in was cancelled or timed out."); return }
                        if let error = query["error"] { self.fail("Google sign-in failed: \(error)"); return }
                        guard query["state"] == state, let code = query["code"] else {
                            self.fail("Sign-in response wasn't valid.")
                            return
                        }
                        await self.exchange(code: code, verifier: verifier, redirect: redirect)
                    }
                }
            }
        }
    }

    func disconnect() {
        if let refreshToken = Keychain.read(service: Self.keychainService) {
            // Best effort: revoke the token at Google.
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(["token": refreshToken])
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.delete(service: Self.keychainService)
        accessToken = nil
        isConnected = false
        lists = []
        tasks = []
        CalendarManager.shared.refreshGoogleTasks()
        Defaults[.googleAccountEmail] = ""
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func exchange(code: String, verifier: String, redirect: String) async {
        do {
            let json = try await tokenRequest([
                "code": code,
                "client_id": Defaults[.googleClientID].trimmingCharacters(in: .whitespaces),
                "client_secret": Defaults[.googleClientSecret].trimmingCharacters(in: .whitespaces),
                "redirect_uri": redirect,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ])
            guard let refreshToken = json["refresh_token"] as? String else {
                throw GoogleError.message("Google didn't return a refresh token.")
            }
            Keychain.save(refreshToken, service: Self.keychainService)
            storeAccessToken(json)
            isConnected = true
            isBusy = false
            NSApp.activate(ignoringOtherApps: true)
            await loadEmail()
            start()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        lastError = message
        isBusy = false
        loopback?.stop()
        loopback = nil
    }

    // MARK: - Sync

    func refresh() async {
        guard isConnected else { return }
        do {
            let listResponse: ListsResponse = try await api("users/@me/lists?maxResults=100")
            lists = listResponse.items ?? []
            let wanted = Set(Defaults[.googleTaskListIDs])
            let selectedLists = wanted.isEmpty ? lists : lists.filter { wanted.contains($0.id) }

            var collected: [GoogleTask] = []
            for list in selectedLists {
                let encoded = list.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? list.id
                let response: TasksResponse = try await api("lists/\(encoded)/tasks?showCompleted=true&showHidden=true&maxResults=100")
                for item in response.items ?? [] where !(item.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    collected.append(GoogleTask(
                        id: item.id,
                        listID: list.id,
                        listTitle: list.title,
                        title: item.title ?? "",
                        notes: item.notes,
                        due: item.due.flatMap(Self.parseDate),
                        isCompleted: item.status == "completed",
                        completedAt: item.completed.flatMap(Self.parseDate)
                    ))
                }
            }
            tasks = collected
            lastSync = Date()
            lastError = nil
            CalendarManager.shared.refreshGoogleTasks()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggle(_ task: GoogleTask) {
        let done = !task.isCompleted
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].isCompleted = done
            tasks[index].completedAt = done ? Date() : nil
        }
        CalendarManager.shared.refreshGoogleTasks()
        Task {
            do {
                let body: [String: Any] = done ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
                let _: TaskItem = try await api(taskPath(task), method: "PATCH", body: body)
            } catch {
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func add(title: String, due: Date?, listID: String? = nil) async -> Bool {
        guard let list = listID.flatMap({ id in lists.first { $0.id == id } }) ?? defaultList else {
            lastError = "No Google task list found."
            return false
        }
        var body: [String: Any] = ["title": title]
        if let due {
            // Google keeps the date only; send midnight UTC of the local day.
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: due)
            body["due"] = String(format: "%04d-%02d-%02dT00:00:00.000Z", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
        }
        do {
            let encoded = list.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? list.id
            let _: TaskItem = try await api("lists/\(encoded)/tasks", method: "POST", body: body)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private var defaultList: GoogleTaskList? {
        let wanted = Defaults[.googleTaskListIDs]
        return lists.first { wanted.contains($0.id) } ?? lists.first
    }

    private func taskPath(_ task: GoogleTask) -> String {
        let list = task.listID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? task.listID
        let id = task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? task.id
        return "lists/\(list)/tasks/\(id)"
    }

    private func loadEmail() async {
        guard let token = try? await validAccessToken() else { return }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["email"] as? String {
            Defaults[.googleAccountEmail] = email
        }
    }

    // MARK: - HTTP

    private enum GoogleError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    private struct ListsResponse: Decodable { let items: [GoogleTaskList]? }
    private struct TasksResponse: Decodable { let items: [TaskItem]? }
    private struct TaskItem: Decodable {
        let id: String
        let title: String?
        let notes: String?
        let status: String?
        let due: String?
        let completed: String?
    }

    private func api<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { accessToken = nil }
            throw GoogleError.message(Self.errorText(from: data) ?? "Google Tasks error (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refreshToken = Keychain.read(service: Self.keychainService) else {
            isConnected = false
            throw GoogleError.message("Not connected to Google.")
        }
        let json = try await tokenRequest([
            "refresh_token": refreshToken,
            "client_id": Defaults[.googleClientID].trimmingCharacters(in: .whitespaces),
            "client_secret": Defaults[.googleClientSecret].trimmingCharacters(in: .whitespaces),
            "grant_type": "refresh_token",
        ])
        storeAccessToken(json)
        guard let accessToken else { throw GoogleError.message("Couldn't refresh the Google session.") }
        return accessToken
    }

    private func storeAccessToken(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        accessTokenExpiry = Date().addingTimeInterval(expiresIn)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if status == 400 || status == 401 {
                // Revoked or expired: sign in again.
                Keychain.delete(service: Self.keychainService)
                isConnected = false
            }
            throw GoogleError.message(Self.errorText(from: data) ?? "Google sign-in error (\(status)).")
        }
        return json
    }

    // MARK: - Helpers

    private static func errorText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let description = json["error_description"] as? String { return description }
        return json["error"] as? String
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return localDay(date, from: text) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return localDay(date, from: text) }
        return nil
    }

    /// Google "due" values are midnight UTC; show them on that calendar day locally.
    private static func localDay(_ date: Date, from text: String) -> Date {
        guard text.contains("T00:00:00") else { return date }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return Calendar.current.date(from: parts) ?? date
    }

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(base64URL(Data(bytes)).prefix(length))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Local redirect receiver

/// Tiny one-shot HTTP listener on 127.0.0.1 that captures Google's OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private var onRedirect: (([String: String]?) -> Void)?
    private var timeout: DispatchWorkItem?
    private let queue = DispatchQueue(label: "boringnotch.oauth.loopback")

    func start(onReady: @escaping (UInt16?) -> Void) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            var reported = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !reported { reported = true; onReady(listener.port?.rawValue) }
                case .failed:
                    if !reported { reported = true; onReady(nil) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            onReady(nil)
        }
    }

    func waitForRedirect(_ handler: @escaping ([String: String]?) -> Void) {
        queue.async {
            self.onRedirect = handler
            let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
            self.timeout = work
            self.queue.asyncAfter(deadline: .now() + 300, execute: work)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.timeout?.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            // Ignore favicon and other stray requests.
            guard query["code"] != nil || query["error"] != nil else {
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let ok = query["code"] != nil
            let html = """
            <html><head><meta charset="utf-8"><title>Boring Notch</title></head>
            <body style="font-family:-apple-system;background:#111;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
            <div style="text-align:center"><h2>\(ok ? "✅ Google Tasks connected" : "❌ Sign-in failed")</h2>
            <p>You can close this tab and go back to Boring Notch.</p></div></body></html>
            """
            let body = html.data(using: .utf8) ?? Data()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: (header.data(using: .utf8) ?? Data()) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finish(query)
        }
    }

    private func finish(_ query: [String: String]?) {
        timeout?.cancel()
        let handler = onRedirect
        onRedirect = nil
        listener?.cancel()
        listener = nil
        handler?(query)
    }
}

// MARK: - Keychain

enum Keychain {
    static func save(_ value: String, service: String) {
        delete(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
