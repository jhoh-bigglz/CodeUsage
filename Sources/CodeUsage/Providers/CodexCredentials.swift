import Foundation
import Darwin

// MARK: - Credentials model

/// Tokens and identity claims read from the Codex CLI's `auth.json`.
/// `description` is redacted so accidental printing never leaks a token.
struct CodexCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    /// `tokens.account_id`, falling back to the JWT `chatgpt_account_id` claim.
    var accountID: String?
    /// `exp` of the access token JWT, when decodable.
    var accessTokenExpiresAt: Date?
    var email: String?
    var name: String?
    /// Raw `chatgpt_plan_type` claim (e.g. "prolite").
    var planClaim: String?

    /// True when the access token expires within `leeway` seconds. Unknown expiry never forces a refresh.
    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let accessTokenExpiresAt else { return false }
        return accessTokenExpiresAt <= now.addingTimeInterval(leeway)
    }

    var description: String {
        "CodexCredentials(accountID: \(accountID != nil ? "set" : "nil"), "
            + "expiresAt: \(accessTokenExpiresAt.map { "\($0)" } ?? "nil"), "
            + "refreshToken: \(refreshToken != nil ? "<redacted>" : "nil"), accessToken: <redacted>)"
    }

    var debugDescription: String { description }

    static let notLoggedInHint = "Codex에 ChatGPT 계정으로 로그인하세요 (codex login)"
    static let tokenExpiredHint = "Codex 토큰이 만료되었습니다. codex 를 한 번 실행하세요"
    static let refreshRejectedHint = "Codex 토큰 갱신이 거부되었습니다. 터미널에서 codex login 으로 다시 로그인하세요"
    static let notWritableHint = "Codex auth.json 에 쓸 수 없어 토큰을 갱신하지 않았습니다. 파일 권한을 확인하거나 codex 를 한 번 실행하세요"

    /// Parses the contents of `auth.json`. Throws `.notLoggedIn` when there is no ChatGPT login.
    static func parse(authJSON data: Data) throws -> CodexCredentials {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ProviderError.decoding("Codex auth.json 형식을 읽을 수 없습니다")
        }
        guard let root = object as? [String: Any] else {
            throw ProviderError.decoding("Codex auth.json 형식을 읽을 수 없습니다")
        }
        if let mode = CodexSupport.string(root["auth_mode"]),
           !mode.lowercased().hasPrefix("chatgpt") {
            throw ProviderError.notLoggedIn(notLoggedInHint)
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = CodexSupport.string(tokens["access_token"]) else {
            throw ProviderError.notLoggedIn(notLoggedInHint)
        }

        let refresh = CodexSupport.string(tokens["refresh_token"])
        let idToken = CodexSupport.string(tokens["id_token"])
        let idClaims = idToken.flatMap(CodexJWT.payload) ?? [:]
        let accessClaims = CodexJWT.payload(access) ?? [:]
        let idAuth = idClaims[CodexJWT.authClaimKey] as? [String: Any] ?? [:]
        let accessAuth = accessClaims[CodexJWT.authClaimKey] as? [String: Any] ?? [:]
        let accessProfile = accessClaims[CodexJWT.profileClaimKey] as? [String: Any] ?? [:]

        let expiry = CodexSupport.number(accessClaims["exp"]).map { Date(timeIntervalSince1970: $0) }
        let accountID = CodexSupport.string(tokens["account_id"])
            ?? CodexSupport.string(idAuth["chatgpt_account_id"])
            ?? CodexSupport.string(accessAuth["chatgpt_account_id"])
        let email = CodexSupport.string(idClaims["email"]) ?? CodexSupport.string(accessProfile["email"])
        let name = CodexSupport.string(idClaims["name"])
        let plan = CodexSupport.string(idAuth["chatgpt_plan_type"])
            ?? CodexSupport.string(accessAuth["chatgpt_plan_type"])

        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            idToken: idToken,
            accountID: accountID,
            accessTokenExpiresAt: expiry,
            email: email,
            name: name,
            planClaim: plan
        )
    }
}

// MARK: - JWT (payload decoding only, no verification)

enum CodexJWT {
    static let authClaimKey = "https://api.openai.com/auth"
    static let profileClaimKey = "https://api.openai.com/profile"

    /// Decodes the base64url JSON payload (second segment) of a JWT.
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}

// MARK: - Auth store (read, refresh, write back)

/// Owns all access to `auth.json`. Being an actor (plus a shared in-flight task) guarantees
/// that two fetches never refresh the token concurrently.
actor CodexAuthStore {
    static let shared = CodexAuthStore()

    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let fileURLOverride: URL?
    private var refreshTask: Task<CodexCredentials, Error>?
    /// Refreshed `auth.json` contents that could not be written back, with the on-disk access token they replace.
    /// Used until the file changes (the CLI refreshes or logs in again), so rotated tokens are never lost.
    private var memoryOverride: (replacedAccessToken: String, data: Data)?

    /// - Parameter fileURL: explicit `auth.json` location (tests); nil = `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
    init(fileURL: URL? = nil) {
        self.fileURLOverride = fileURL
    }

    /// `$CODEX_HOME/auth.json`, defaulting to `~/.codex/auth.json`.
    static func defaultAuthFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            let expanded = (home as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// Whether the credential file exists (no content is read). For settings status display.
    nonisolated static func authFileExists() -> Bool {
        FileManager.default.fileExists(atPath: defaultAuthFileURL().path)
    }

    var authFileURL: URL { fileURLOverride ?? Self.defaultAuthFileURL() }

    /// Reads and parses `auth.json` as it is on disk right now.
    func load() throws -> CodexCredentials {
        try CodexCredentials.parse(authJSON: effectiveAuthData())
    }

    /// The document in effect: the in-memory override while `auth.json` still holds the token it replaced,
    /// otherwise the file itself.
    private func effectiveAuthData() throws -> Data {
        let disk: Data
        do {
            disk = try readAuthFile()
        } catch ProviderError.notLoggedIn(let hint) {
            memoryOverride = nil   // file removed: logged out
            throw ProviderError.notLoggedIn(hint)
        } catch {
            if let memoryOverride { return memoryOverride.data }
            throw error
        }
        if let override = memoryOverride {
            if let stored = try? CodexCredentials.parse(authJSON: disk),
               stored.accessToken == override.replacedAccessToken {
                return override.data
            }
            memoryOverride = nil
        }
        return disk
    }

    /// Whether a refreshed `auth.json` can be written (directory writable for the temp file + rename,
    /// and the file itself writable when it exists). Checked before refreshing, because a refresh rotates
    /// the refresh token on the server.
    private func canWriteBack() -> Bool {
        let target = authFileURL.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        guard access(directory.path, W_OK) == 0 else { return false }
        if access(target.path, F_OK) == 0 {
            return access(target.path, W_OK) == 0
        }
        return true
    }

    /// Current credentials, refreshed first when the access token expires within 60 s.
    func validCredentials(now: Date = Date()) async throws -> CodexCredentials {
        let current = try load()
        guard current.needsRefresh(now: now) else { return current }
        return try await refresh(replacing: current.accessToken)
    }

    /// Refreshes the token that replaced (or should replace) `staleAccessToken`.
    /// Re-reads the file first: if the CLI already wrote a different, still-valid token, that one is used.
    /// Concurrent callers share one in-flight refresh.
    func refresh(replacing staleAccessToken: String) async throws -> CodexCredentials {
        if let running = refreshTask {
            return try await running.value
        }
        let task = Task { try await self.performRefresh(replacing: staleAccessToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: Private

    private func performRefresh(replacing staleAccessToken: String) async throws -> CodexCredentials {
        // The CLI may have refreshed meanwhile.
        let onDisk = try load()
        if onDisk.accessToken != staleAccessToken && !onDisk.needsRefresh() {
            return onDisk
        }

        let autoRefresh = UserDefaults.standard.object(forKey: SettingsKey.autoRefreshTokens) as? Bool
            ?? SettingsDefaults.autoRefreshTokens
        guard autoRefresh else {
            throw ProviderError.tokenExpired(CodexCredentials.tokenExpiredHint)
        }
        guard let refreshToken = onDisk.refreshToken else {
            throw ProviderError.tokenExpired(CodexCredentials.refreshRejectedHint)
        }
        // Never rotate the refresh token unless the result can be stored for the CLI too.
        guard canWriteBack() else {
            throw ProviderError.tokenExpired(CodexCredentials.notWritableHint)
        }

        let fresh = try await requestNewTokens(refreshToken: refreshToken)
        let written = try writeBack(fresh)
        return try CodexCredentials.parse(authJSON: written)
    }

    private struct TokenResponse {
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
    }

    private func requestNewTokens(refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CodexSupport.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await CodexSupport.send(request)
        switch response.statusCode {
        case 200..<300:
            break
        case 400, 401, 403:
            // invalid_grant / refresh_token_expired / refresh_token_reused: only a new login helps.
            throw ProviderError.tokenExpired(CodexCredentials.refreshRejectedHint)
        default:
            throw ProviderError.http(response.statusCode, CodexSupport.oauthErrorCode(from: data))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            throw ProviderError.decoding("Codex 토큰 갱신 응답")
        }
        let tokens = TokenResponse(
            idToken: CodexSupport.string(dict["id_token"]),
            accessToken: CodexSupport.string(dict["access_token"]),
            refreshToken: CodexSupport.string(dict["refresh_token"])
        )
        guard tokens.accessToken != nil || tokens.idToken != nil || tokens.refreshToken != nil else {
            throw ProviderError.decoding("Codex 토큰 갱신 응답에 토큰이 없습니다")
        }
        return tokens
    }

    /// Merges new tokens into the current file (keeping every unknown key and absent tokens),
    /// sets `last_refresh`, and atomically replaces the file with mode 0600. Returns the bytes written.
    private func writeBack(_ fresh: TokenResponse) throws -> Data {
        // Merge into the document in effect (the override when one is active), re-read now in case the CLI wrote meanwhile.
        let currentData = try effectiveAuthData()
        guard let object = try? JSONSerialization.jsonObject(with: currentData, options: []),
              var root = object as? [String: Any] else {
            throw ProviderError.decoding("Codex auth.json 형식을 읽을 수 없습니다")
        }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        if let value = fresh.idToken { tokens["id_token"] = value }
        if let value = fresh.accessToken { tokens["access_token"] = value }
        if let value = fresh.refreshToken { tokens["refresh_token"] = value }
        root["tokens"] = tokens
        root["last_refresh"] = CodexSupport.iso8601Fractional(Date())

        let output: Data
        do {
            output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw ProviderError.decoding("Codex auth.json 직렬화 실패")
        }
        do {
            try CodexSupport.atomicWrite(output, to: authFileURL)
            memoryOverride = nil
        } catch {
            // The server already rotated the refresh token: keep the new tokens in memory so the app keeps
            // working until auth.json changes. Record the token the file still holds (not a previous override's).
            guard let replaced = memoryOverride?.replacedAccessToken
                    ?? (try? CodexCredentials.parse(authJSON: currentData))?.accessToken else {
                throw ProviderError.tokenExpired("갱신된 Codex 토큰을 auth.json 에 저장하지 못했습니다. codex login 으로 다시 로그인하세요")
            }
            memoryOverride = (replaced, output)
            if ProcessInfo.processInfo.environment["CODEUSAGE_DEBUG"] == "1" {
                FileHandle.standardError.write(Data("[CodeUsage debug] Codex auth.json write-back failed\n".utf8))
            }
        }
        return output
    }

    private func readAuthFile() throws -> Data {
        let url = authFileURL
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw ProviderError.notLoggedIn(CodexCredentials.notLoggedInHint)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                throw ProviderError.notLoggedIn(CodexCredentials.notLoggedInHint)
            }
            throw ProviderError.decoding("Codex auth.json 을 읽을 수 없습니다 (\(error.localizedDescription))")
        }
    }
}

// MARK: - Small shared helpers (prefixed to avoid clashing with Core/HTTP.swift)

enum CodexSupport {
    static let userAgent = "CodeUsage/1.0"

    /// Ephemeral session: no cookies, no cache, nothing persisted.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static var debugEnabled: Bool {
        ProcessInfo.processInfo.environment["CODEUSAGE_DEBUG"] == "1"
    }

    /// Performs a request, mapping transport failures to `ProviderError.network`.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ProviderError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("HTTP 응답이 아닙니다")
        }
        return (data, http)
    }

    /// Lenient number: Int, Double, or numeric String. Booleans are rejected.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            return d
        default:
            return nil
        }
    }

    /// Non-empty string, or nil.
    static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ISO8601 with fractional seconds and `Z`, e.g. `2026-11-16T04:29:26.847Z`.
    static func iso8601Fractional(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// The OAuth `error` code only (never the whole body).
    static func oauthErrorCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else { return nil }
        if let code = string(dict["error"]) { return String(code.prefix(80)) }
        if let err = dict["error"] as? [String: Any], let code = string(err["code"]) ?? string(err["type"]) {
            return String(code.prefix(80))
        }
        return nil
    }

    /// Short human message from an API error body (`detail`, `message`, `error.message`).
    static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else { return nil }
        let candidates: [String?] = [
            string(dict["detail"]),
            (dict["detail"] as? [String: Any]).flatMap { string($0["message"]) },
            string(dict["message"]),
            (dict["error"] as? [String: Any]).flatMap { string($0["message"]) ?? string($0["code"]) },
            string(dict["error"]),
        ]
        guard let message = candidates.compactMap({ $0 }).first else { return nil }
        return String(message.prefix(160))
    }

    /// Writes `data` to a temp file in the target's directory (mode 0600), fsyncs, and renames it over the target.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(target.lastPathComponent).codeusage-\(UUID().uuidString).tmp")
        let tempPath = tempURL.path

        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError(errno) }

        var renamed = false
        defer { if !renamed { unlink(tempPath) } }

        do {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError(errno)
                    }
                    offset += written
                }
            }
            guard fchmod(fd, 0o600) == 0 else { throw posixError(errno) }
            guard fsync(fd) == 0 else { throw posixError(errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw posixError(errno) }
        guard rename(tempPath, target.path) == 0 else { throw posixError(errno) }
        renamed = true
    }

    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
