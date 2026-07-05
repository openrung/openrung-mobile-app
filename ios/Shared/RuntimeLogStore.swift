import Foundation

/// File-backed runtime log that survives restarts (contract §3 getPersistedLog), stored in
/// the app-group container so the PacketTunnel extension writes and the host app reads.
/// Every line the live 80-line console sees is ALSO scrubbed and appended here, capped at
/// `maxLines` with amortized compaction (append-only writes; the file is only rewritten when
/// it overshoots, at tunnel start or on read — never per append).
///
/// Scrubbing happens BEFORE a line ever hits disk: proxy URIs, URLs, IPs (v4+v6), UUIDs (the
/// relay clientId is a credential) and credential-shaped key=value pairs become placeholder
/// tokens, bare domains last. Shared design with the Android RuntimeLogStore — keep the two
/// scrubbers in sync.
///
/// Cross-process note: the extension is effectively the sole appender (the app only reads and
/// clears), and appends are small single-line O_APPEND writes, so no NSFileCoordinator.
enum RuntimeLogStore {
    private static let maxLines = 1000
    private static let compactThreshold = 1200
    private static let maxLineLength = 600
    private static let queue = DispatchQueue(label: "com.openrung.mobile.runtime-log", qos: .utility)

    private static var logFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("runtime.log")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    /// Scrubs + appends one line (async, off the caller's thread).
    static func append(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(scrub(message))\n"
        queue.async {
            guard let url = logFileURL, let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                // Best-effort: the live console still has the line.
            }
        }
    }

    /// Full persisted log, oldest first, capped to `maxLines`.
    static func readLines() -> [String] {
        queue.sync {
            guard let url = logFileURL, let content = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return Array(lines.suffix(maxLines))
        }
    }

    static func clear() {
        queue.sync {
            guard let url = logFileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Rewrites the file down to `maxLines` when it overshot — called at tunnel start so the
    /// hot append path stays append-only.
    static func compactIfNeeded() {
        queue.async {
            guard let url = logFileURL, let content = try? String(contentsOf: url, encoding: .utf8) else {
                return
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > compactThreshold else { return }
            let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
            try? kept.data(using: .utf8)?.write(to: url)
        }
    }

    // MARK: - Scrubber

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ template: String) -> Rule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return Rule(regex: regex, template: template)
        }
        return [
            rule("\\b(?:vless|vmess|trojan|ss|socks[45]?|hysteria2?|hy2|tuic|wireguard|anytls|naive\\+https)://\\S+", "<proxy-link>"),
            rule("\\bhttps?://\\S+", "<url>"),
            rule("\\b[a-z][a-z0-9+.-]{1,20}://\\S+", "<uri>"),
            rule("\\b(server|host|sni|server_name|uuid|password|token|secret|public_key|private_key|short_id|client_id)\\s*[=:]\\s*\\S+", "$1=<redacted>"),
            rule("\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b", "<uuid>"),
            rule("\\b(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d+)?\\b", "<ip>"),
            // Conservative IPv6: full/near-full groups, or a compressed "::" form —
            // deliberately does NOT match "HH:mm:ss"-style two-colon runs.
            rule("\\[?(?:(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}|[0-9a-fA-F]{1,4}::[0-9a-fA-F:]{0,34}|::(?:[0-9a-fA-F]{1,4}:?){1,7})\\]?(?::\\d+)?", "<ip>"),
            // Bare domains LAST, or it would eat the hosts inside URLs before their whole match runs.
            rule("\\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}\\b", "<domain>"),
            rule("\\s+", " "),
        ].compactMap { $0 }
    }()

    static func scrub(_ message: String) -> String {
        var result = message
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return String(result.prefix(maxLineLength))
    }
}
