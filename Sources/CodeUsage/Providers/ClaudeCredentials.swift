import Foundation

/// Claude Code OAuth credentials as stored by the CLI (`{"claudeAiOauth": {...}}`).
/// Token values are kept in memory only; they are never logged, printed or shown.
struct ClaudeCredentials: Sendable {
    enum Source: Sendable, Equatable {
        /// Keychain generic password, service `Claude Code-credentials`.
        case keychain
        /// Fallback JSON file (normally `~/.claude/.credentials.json`).
        case file(URL)
    }

    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?
    let source: Source
    /// The complete stored JSON document, so a write-back can preserve every unknown key.
    let rawJSON: Data

    /// True when the access token expires within `margin` seconds (or already has).
    func expires(within margin: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(margin)
    }

    var refreshTokenExpired: Bool {
        guard let refreshTokenExpiresAt else { return false }
        return refreshTokenExpiresAt <= Date()
    }
}

/// Reads and writes the Claude Code credential store.
///
/// The keychain is accessed through `/usr/bin/security` (no shell), which is already trusted by the
/// Claude Code keychain item's ACL, so the ad-hoc signed app does not trigger an access prompt.
/// Secrets are never placed in argv: write-back feeds `security -i` through stdin.
enum ClaudeCredentialStore {
    static let keychainService = "Claude Code-credentials"
    static let oauthKey = "claudeAiOauth"

    static let notLoggedInError = ProviderError.notLoggedIn("Claude Code 로그인이 필요합니다. 터미널에서 claude 실행 후 /login")

    /// `security -i` reads each command into a 4 KiB line buffer and silently splits longer lines.
    /// Claude Code uses the same conservative ceiling.
    static let securityInteractiveLineLimit = 4096 - 64

    private static let securityPath = "/usr/bin/security"

    /// `~/.claude/.credentials.json`, honouring `CLAUDE_CONFIG_DIR` when the app was launched with it.
    static var fallbackFileURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(".credentials.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    // MARK: Status (for the settings window; existence only)

    /// Whether the Claude Code keychain item exists. Does not read the secret.
    static func keychainItemExists() async -> Bool {
        let result = await ClaudeProcessRunner.run(securityPath, ["find-generic-password", "-s", keychainService])
        return result.status == 0
    }

    static func fallbackFileExists() -> Bool {
        FileManager.default.fileExists(atPath: fallbackFileURL.path)
    }

    // MARK: Load

    /// Loads credentials from the keychain, falling back to the credentials file.
    /// Throws `ProviderError.notLoggedIn` when neither holds a usable access token.
    static func load() async throws -> ClaudeCredentials {
        if let data = await readKeychainSecret(), let creds = parse(data, source: .keychain) {
            return creds
        }
        let url = fallbackFileURL
        if let data = try? Data(contentsOf: url), let creds = parse(data, source: .file(url)) {
            return creds
        }
        throw notLoggedInError
    }

    /// Parses a credential document. Returns nil when it has no access token.
    static func parse(_ data: Data, source: ClaudeCredentials.Source) -> ClaudeCredentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let oauth = root[oauthKey] as? [String: Any],
              let access = HTTP.string(oauth["accessToken"]) else { return nil }
        let scopes: [String]
        if let list = oauth["scopes"] as? [Any] {
            scopes = list.compactMap { HTTP.string($0) }
        } else if let joined = HTTP.string(oauth["scopes"]) {
            scopes = joined.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        } else {
            scopes = []
        }
        return ClaudeCredentials(
            accessToken: access,
            refreshToken: HTTP.string(oauth["refreshToken"]),
            expiresAt: HTTP.date(oauth["expiresAt"]),
            refreshTokenExpiresAt: HTTP.date(oauth["refreshTokenExpiresAt"]),
            scopes: scopes,
            subscriptionType: HTTP.string(oauth["subscriptionType"]),
            rateLimitTier: HTTP.string(oauth["rateLimitTier"]),
            source: source,
            rawJSON: data
        )
    }

    private static func readKeychainSecret() async -> Data? {
        let result = await ClaudeProcessRunner.run(securityPath, ["find-generic-password", "-s", keychainService, "-w"])
        guard result.status == 0, !result.timedOut else { return nil }
        guard var text = String(data: result.stdout, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return Data(text.utf8) }
        // `security -w` prints non-printable / non-ASCII secrets as hex.
        return hexDecode(text)
    }

    // MARK: Refresh result

    /// Returns the stored document with the refreshed token fields replaced and every other key preserved.
    static func applyingRefresh(
        to creds: ClaudeCredentials,
        accessToken: String,
        refreshToken: String?,
        expiresIn: TimeInterval?,
        refreshTokenExpiresIn: TimeInterval?,
        scopes: [String]?,
        now: Date = Date()
    ) -> ClaudeCredentials? {
        var root = ((try? JSONSerialization.jsonObject(with: creds.rawJSON, options: [])) as? [String: Any]) ?? [:]
        var oauth = (root[oauthKey] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        // Never keep the old (about-to-expire) expiry for a new token, or every later fetch would refresh again.
        let expiresAt: Date
        if let expiresIn, expiresIn > 0 {
            expiresAt = now.addingTimeInterval(expiresIn)
        } else if let exp = HTTP.double(HTTP.jwtPayload(accessToken)?["exp"]), exp > now.timeIntervalSince1970 {
            expiresAt = Date(timeIntervalSince1970: exp)
        } else {
            expiresAt = now.addingTimeInterval(3_600)   // conservative; a 401 still triggers a refresh
        }
        oauth["expiresAt"] = NSNumber(value: Int64(expiresAt.timeIntervalSince1970 * 1000))
        if let refreshTokenExpiresIn {
            oauth["refreshTokenExpiresAt"] = NSNumber(value: Int64((now.timeIntervalSince1970 + refreshTokenExpiresIn) * 1000))
        }
        if let scopes, !scopes.isEmpty { oauth["scopes"] = scopes }
        root[oauthKey] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]) else { return nil }
        return parse(data, source: creds.source)
    }

    // MARK: Write-back

    /// Whether a refreshed document derived from `creds` can be written back without exposing it in argv.
    /// Checked before refreshing, because a refresh rotates the refresh token: refreshing without being
    /// able to store the result would log the CLI out.
    static func canWriteBack(_ creds: ClaudeCredentials) -> Bool {
        switch creds.source {
        case .file:
            return true
        case .keychain:
            // Allow growth for longer tokens / later expiry digits; account name is bounded separately.
            let estimatedJSONBytes = creds.rawJSON.count + 256
            return addCommand(account: String(repeating: "a", count: 64), hex: String(repeating: "0", count: estimatedJSONBytes * 2))
                .utf8.count <= securityInteractiveLineLimit
        }
    }

    /// Writes `creds.rawJSON` back to where it came from. Throws on failure.
    static func write(_ creds: ClaudeCredentials) async throws {
        switch creds.source {
        case .keychain:
            try await writeKeychain(creds)
        case .file(let url):
            try writeFileAtomically(creds.rawJSON, to: url)
        }
    }

    private static func addCommand(account: String, hex: String) -> String {
        "add-generic-password -U -a \"\(account)\" -s \"\(keychainService)\" -X \(hex)\n"
    }

    private static func writeKeychain(_ creds: ClaudeCredentials) async throws {
        let account = await keychainAccount()
        guard !account.isEmpty,
              !account.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
            throw ProviderError.decoding("키체인 계정 이름을 확인할 수 없습니다")
        }
        let command = addCommand(account: account, hex: hexEncode(creds.rawJSON))
        guard command.utf8.count <= securityInteractiveLineLimit else {
            throw ProviderError.decoding("자격 증명이 너무 커서 키체인에 안전하게 저장할 수 없습니다")
        }
        let result = await ClaudeProcessRunner.run(securityPath, ["-i"], stdin: Data(command.utf8))
        // `security -i` exits 0 even when a command fails; failures are reported on stderr.
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        if result.timedOut || result.status != 0 || stderr.contains("returned") || stderr.contains("unknown command") {
            throw ProviderError.decoding("키체인에 갱신된 토큰을 저장하지 못했습니다")
        }
        // Verify by reading the item back.
        guard let stored = await readKeychainSecret(),
              let reread = parse(stored, source: .keychain),
              reread.accessToken == creds.accessToken else {
            throw ProviderError.decoding("키체인에 갱신된 토큰을 저장하지 못했습니다")
        }
    }

    /// The keychain item's account (`"acct"<blob>="..."`), falling back to the macOS user name.
    static func keychainAccount() async -> String {
        let result = await ClaudeProcessRunner.run(securityPath, ["find-generic-password", "-s", keychainService])
        if result.status == 0,
           let text = String(data: result.stdout, encoding: .utf8) ?? String(data: result.stdout, encoding: .isoLatin1),
           let account = parseAccount(fromAttributes: text) {
            return account
        }
        return NSUserName()
    }

    /// Parses `"acct"<blob>="name"` or `"acct"<blob>=0x6E616D65  "name"` from `security` attribute output.
    static func parseAccount(fromAttributes text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"acct\"<blob>=") else { continue }
            let value = trimmed.dropFirst("\"acct\"<blob>=".count)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                let inner = String(value.dropFirst().dropLast())
                return inner.isEmpty ? nil : inner
            }
            if value.hasPrefix("0x") {
                let hex = value.dropFirst(2).prefix(while: { $0.isHexDigit })
                if let data = hexDecode(String(hex)), let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    return s
                }
            }
            return nil
        }
        return nil
    }

    /// Temp file created with open(O_CREAT|O_EXCL, 0600) — never readable by others, not even briefly —
    /// then fsynced and renamed over the target.
    private static func writeFileAtomically(_ data: Data, to url: URL) throws {
        do {
            try CodexSupport.atomicWrite(data, to: url)
        } catch {
            throw ProviderError.decoding("자격 증명 파일을 저장하지 못했습니다")
        }
    }

    // MARK: Hex

    static func hexEncode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hexDecode(_ text: String) -> Data? {
        var hex = Substring(text)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.dropFirst(2) }
        let bytes = Array(hex.utf8)
        guard !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var data = Data(capacity: bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        return data
    }
}

// MARK: - Process runner

/// Runs a command-line tool directly (no shell) off the cooperative thread pool, with a timeout.
/// Output is returned in memory only.
enum ClaudeProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 30) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, stdin: stdin, timeout: timeout))
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        func set(out: Data) { lock.lock(); stdout = out; lock.unlock() }
        func set(err: Data) { lock.lock(); stderr = err; lock.unlock() }
        func values() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: Data(), stderr: Data(), timedOut: false)
        }

        let collector = Collector()
        let readers = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            collector.set(out: outHandle.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            collector.set(err: errHandle.readDataToEndOfFile())
        }

        let writer = inPipe.fileHandleForWriting
        // Never let a child that closes stdin early kill the app with SIGPIPE.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let stdin, !stdin.isEmpty {
            do {
                try writer.write(contentsOf: stdin)
            } catch {
                // The child exited early or closed stdin; its status/stderr will tell.
            }
        }
        try? writer.close()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        _ = readers.wait(timeout: .now() + 5)
        let (out, err) = collector.values()
        let status = process.isRunning ? -1 : process.terminationStatus
        return Output(status: status, stdout: out, stderr: err, timedOut: timedOut)
    }
}
