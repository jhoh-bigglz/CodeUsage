import Foundation

// MARK: - Shared networking / decoding helpers
//
// Everything lives under the `HTTP` namespace so helpers never collide with private helpers in other files.
//
// Requests (errors are always mapped to `ProviderError`):
//   HTTP.getJSON(_ url:, headers:, debugLabel:) async throws -> [String: Any]
//   HTTP.postJSON(_ url:, body:, headers:) async throws -> [String: Any]
//   HTTP.send(_ request:, debugLabel:) async throws -> Data       // raw body of a 2xx response
//     401 -> .unauthorized, other non-2xx -> .http(code, short sanitized snippet), URLError -> .network,
//     non-JSON / non-object body (getJSON/postJSON) -> .decoding. Task cancellation rethrows CancellationError.
//     `debugLabel` (usage endpoints only, never token endpoints) dumps the raw body to stderr when CODEUSAGE_DEBUG=1.
//   HTTP.userAgent                                 // "CodeUsage/1.0"
//
// Lenient decoding of JSONSerialization values:
//   HTTP.double(_:) / HTTP.int(_:)                 // accepts Int, Double, Bool-free NSNumber, numeric String
//   HTTP.string(_:)                                // non-empty String (numbers are stringified); NSNull -> nil
//   HTTP.dict(_:) / HTTP.array(_:)                 // [String: Any] / [Any], NSNull -> nil
//
// Dates:
//   HTTP.parseISO8601(_:) -> Date?                 // fractional seconds (any digits), Z / +00:00 / +0000 offsets, space separator
//   HTTP.formatISO8601(_:) -> String               // "2026-11-16T04:29:26.847Z"
//   HTTP.epochDate(_:) -> Date?                    // seconds or milliseconds (> 1e12), as number or string
//   HTTP.date(_:) -> Date?                         // epoch number or ISO8601 string
//
// JWT:
//   HTTP.jwtPayload(_ token:) -> [String: Any]?    // base64url-decoded payload, no signature verification
//
// Debug:
//   HTTP.isDebug                                   // env CODEUSAGE_DEBUG == "1"
//   HTTP.debugDump(_ label:, data:)                // pretty JSON to stderr when isDebug. Never pass token responses.

enum HTTP {
    static let userAgent = "CodeUsage/1.0"

    /// Ephemeral session: no cookies, no cache, bounded timeouts.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: Requests

    /// GET a JSON object. `headers` are added on top of `Accept: application/json` and the User-Agent.
    static func getJSON(_ url: URL, headers: [String: String] = [:], debugLabel: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyDefaultHeaders(&request, headers: headers)
        let data = try await send(request, debugLabel: debugLabel)
        return try jsonObject(data)
    }

    /// POST a JSON body and decode a JSON object response.
    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyDefaultHeaders(&request, headers: headers)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw ProviderError.decoding("요청 본문을 만들 수 없습니다")
        }
        let data = try await send(request)
        return try jsonObject(data)
    }

    /// Perform a request, returning the body of a 2xx response. Errors are mapped to `ProviderError`.
    static func send(_ request: URLRequest, debugLabel: String? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw ProviderError.network(networkMessage(error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("HTTP 응답이 아닙니다")
        }
        if let debugLabel {
            debugDump("\(debugLabel) [HTTP \(http.statusCode)]", data: data)
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ProviderError.unauthorized
        case 429:
            throw ProviderError.rateLimited(retryAfter: retryAfter(http))
        default:
            throw ProviderError.http(http.statusCode, errorSnippet(data))
        }
    }

    /// Seconds to wait from a `Retry-After` header (delta-seconds or HTTP-date); nil when absent or invalid.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty
        else { return nil }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    private static func applyDefaultHeaders(_ request: inout URLRequest, headers: [String: String]) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw ProviderError.decoding("빈 응답") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ProviderError.decoding("JSON 형식이 아닙니다")
        }
        guard let dict = object as? [String: Any] else {
            throw ProviderError.decoding("JSON 객체가 아닙니다")
        }
        return dict
    }

    private static func networkMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "인터넷에 연결되어 있지 않습니다"
        case .timedOut: return "요청 시간이 초과되었습니다"
        case .cannotFindHost, .dnsLookupFailed: return "서버를 찾을 수 없습니다"
        case .cannotConnectToHost: return "서버에 연결할 수 없습니다"
        case .networkConnectionLost: return "네트워크 연결이 끊어졌습니다"
        default: return error.localizedDescription
        }
    }

    /// Short, sanitized description of an error body. Prefers well-known JSON error fields; never echoes
    /// anything that looks like a token.
    static func errorSnippet(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        var text: String?
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let dict = object as? [String: Any] {
                text = errorText(from: dict)
            } else if let s = object as? String {
                text = s
            }
        }
        if text == nil, let raw = String(data: data.prefix(512), encoding: .utf8) {
            // HTML error pages are noise; keep only plain-ish text.
            text = raw.contains("<") ? nil : raw
        }
        guard var snippet = text?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty else { return nil }
        snippet = redactTokens(snippet)
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        if snippet.count > 120 { snippet = String(snippet.prefix(117)) + "..." }
        return snippet
    }

    private static func errorText(from dict: [String: Any]) -> String? {
        if let nested = dict["error"] as? [String: Any] {
            let type = string(nested["type"]) ?? string(nested["code"])
            let message = string(nested["message"])
            let joined = [type, message].compactMap { $0 }.joined(separator: ": ")
            return joined.isEmpty ? nil : joined
        }
        let code = string(dict["error"]) ?? string(dict["code"]) ?? string(dict["type"])
        let message = string(dict["error_description"]) ?? string(dict["message"]) ?? string(dict["detail"])
        let joined = [code, message].compactMap { $0 }.joined(separator: ": ")
        return joined.isEmpty ? nil : joined
    }

    /// Replaces long opaque runs (JWTs, OAuth tokens, keys) with "[redacted]".
    private static func redactTokens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9_\\-\\.~+/=]{32,}") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[redacted]")
    }

    // MARK: Lenient values

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            guard let d = Double(trimmed), d.isFinite else { return nil }
            return d
        case let d as Double:
            return d.isFinite ? d : nil
        case let i as Int:
            return Double(i)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        guard let d = double(value), d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return Int(d.rounded())
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func array(_ value: Any?) -> [Any]? { value as? [Any] }

    // MARK: Dates

    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoRegex = try? NSRegularExpression(
        pattern: "^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2})(?:[.,](\\d+))?)?\\s*(Z|z|[+-]\\d{2}(?::?\\d{2})?)?$"
    )

    /// Parses ISO8601 / RFC3339 timestamps: fractional seconds of any length, `Z`, `+00:00`, `+0000`, `+00`,
    /// a space instead of `T`, and missing offsets (treated as UTC).
    static func parseISO8601(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let d = isoFractional.date(from: raw) ?? isoPlain.date(from: raw) { return d }
        guard let regex = isoRegex,
              let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: raw) else { return nil }
            return String(raw[r])
        }
        guard let year = Int(group(1) ?? ""), let month = Int(group(2) ?? ""), let day = Int(group(3) ?? ""),
              let hour = Int(group(4) ?? ""), let minute = Int(group(5) ?? "") else { return nil }
        let second = Int(group(6) ?? "0") ?? 0
        var fraction = 0.0
        if let digits = group(7) { fraction = Double("0." + digits) ?? 0 }

        var offsetSeconds = 0
        if let tz = group(8), tz != "Z", tz != "z" {
            let sign = tz.hasPrefix("-") ? -1 : 1
            let digits = tz.dropFirst().replacingOccurrences(of: ":", with: "")
            let hh = Int(digits.prefix(2)) ?? 0
            let mm = digits.count >= 4 ? (Int(digits.dropFirst(2).prefix(2)) ?? 0) : 0
            offsetSeconds = sign * (hh * 3600 + mm * 60)
        }

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        guard let base = calendar.date(from: comps) else { return nil }
        return base.addingTimeInterval(fraction - TimeInterval(offsetSeconds))
    }

    /// ISO8601 in UTC with millisecond precision and `Z`, e.g. "2026-11-16T04:29:26.847Z".
    static func formatISO8601(_ date: Date) -> String {
        isoFractional.string(from: date)
    }

    /// Epoch seconds or milliseconds (values above 1e12 are treated as ms), as number or numeric string.
    static func epochDate(_ value: Any?) -> Date? {
        guard let v = double(value), v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
    }

    /// Either an epoch number or an ISO8601 string.
    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            if let d = parseISO8601(s) { return d }
            return epochDate(s)
        }
        return epochDate(value)
    }

    // MARK: JWT

    /// Decodes the (unverified) payload of a JWT into a dictionary.
    static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: b64),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return nil }
        return object
    }

    // MARK: Debug

    static var isDebug: Bool {
        ProcessInfo.processInfo.environment["CODEUSAGE_DEBUG"] == "1"
    }

    /// Prints a response body (pretty-printed when it is JSON) to stderr, only when CODEUSAGE_DEBUG=1.
    /// Only pass usage/profile responses here — never token endpoint responses or request headers.
    static func debugDump(_ label: String, data: Data) {
        guard isDebug else { return }
        var text: String
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let s = String(data: pretty, encoding: .utf8) {
            text = s
        } else {
            text = String(data: data.prefix(4096), encoding: .utf8) ?? "<\(data.count) bytes>"
        }
        text = redactTokens(text)
        FileHandle.standardError.write(Data("[CodeUsage debug] \(label)\n\(text)\n".utf8))
    }
}
