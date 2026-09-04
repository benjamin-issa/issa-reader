import Foundation

/// The app's own log, kept so a beta tester can hand over what happened.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` can only see the running
/// process, and the reports worth having are about the launch *before* the one
/// you are looking at — so this writes its own file.
///
/// Deliberately small: append a line, keep six hours, redact the secrets.
/// Everything else is the caller's job.
///
/// Lives in `Application Support`, not `Caches`: iOS empties Caches under
/// storage pressure, which is one of the conditions a report would be about.
public enum IssaLog {
    public enum Level: String, Sendable, Codable, CaseIterable {
        case debug, info, warning, error
    }

    /// How far back an export reaches.
    public static let window: TimeInterval = 6 * 60 * 60

    // MARK: - Writing

    public static func debug(_ message: String, _ fields: [String: String] = [:]) {
        write(.debug, message, fields)
    }

    public static func info(_ message: String, _ fields: [String: String] = [:]) {
        write(.info, message, fields)
    }

    public static func warning(_ message: String, _ fields: [String: String] = [:]) {
        write(.warning, message, fields)
    }

    public static func error(_ message: String, _ fields: [String: String] = [:]) {
        write(.error, message, fields)
    }

    /// Records a thrown error at a named site.
    ///
    /// The point of the whole exercise: thirteen `catch` blocks used to discard
    /// the error entirely, and several of them are exactly what a beta report
    /// would be about.
    public static func failure(
        _ site: String, _ error: any Error, _ fields: [String: String] = [:],
    ) {
        var all = fields
        all["site"] = site
        for (key, value) in Self.describe(error) { all[key] = value }
        write(.error, "\(site) failed", all)
    }

    /// What is worth keeping about an error, beyond the sentence shown to the
    /// reader — which is the part that is already known and the least useful.
    static func describe(_ error: any Error) -> [String: String] {
        var fields: [String: String] = ["error": String(describing: error)]
        if let storyteller = error as? StorytellerError {
            switch storyteller {
            case let .server(status, message):
                fields["status"] = String(status)
                if let message { fields["serverMessage"] = message }
            case let .transport(detail): fields["transport"] = detail
            case let .download(detail): fields["download"] = detail
            case let .decoding(detail): fields["decoding"] = detail
            default: break
            }
            fields["retryable"] = String(storyteller.isRetryable)
        } else {
            let ns = error as NSError
            fields["domain"] = ns.domain
            fields["code"] = String(ns.code)
        }
        return fields
    }

    static func write(_ level: Level, _ message: String, _ fields: [String: String]) {
        store.append(entry(level, message, fields))
    }

    /// Builds the entry that would be written, redaction and all.
    ///
    /// Separate from `write` so a test can assert on what *would* reach the
    /// file without writing one. A test that rebuilt this itself would pass
    /// with the redaction removed, which is the one thing it exists to catch.
    static func entry(
        _ level: Level, _ message: String, _ fields: [String: String],
        at time: Date = Date(),
    ) -> Entry {
        Entry(
            time: time,
            level: level,
            message: Redaction.scrub(message),
            // A field *named* as a secret loses its value outright; anything
            // else is scrubbed for secrets that turn up inside it.
            fields: fields.reduce(into: [:]) { result, pair in
                result[pair.key] = Redaction.isSecret(pair.key)
                    ? "«redacted»" : Redaction.scrub(pair.value)
            },
        )
    }

    // MARK: - Reading

    /// Everything from the last six hours, oldest first, as plain text.
    public static func export() -> String { store.text(since: Date() - window) }

    /// Writes the export to a file for sharing, and returns it.
    public static func exportFile() -> URL? { store.exportFile(since: Date() - window) }

    /// Number of entries currently held, for the screen that offers the export.
    public static func count() -> Int { store.count(since: Date() - window) }

    public static func clear() { store.clear() }

    /// Writes everything buffered, now.
    ///
    /// `append` buffers and schedules a flush on a utility-priority detached
    /// task, because a page turn can log several times in a few milliseconds
    /// and opening the file for each would put disk I/O on the main thread
    /// during the one animation that must not stutter. Nothing called this,
    /// though — so the entries immediately before a crash, a force-quit or a
    /// suspension that the system then kills are exactly the ones that never
    /// reached the file, and they are the entries this log exists to capture.
    ///
    /// Called from the app's own suspend and terminate handlers.
    public static func flush() { store.flush() }
    /// Removes any diagnostics file written for sharing.
    public static func discardExports() { store.discardExports() }

    /// Where the log is, so the diagnostics screen can say so.
    public static var directory: URL? { store.directory }

    static let store = LogStore()
}

// MARK: - An entry

extension IssaLog {
    struct Entry: Codable, Sendable {
        var time: Date
        var level: Level
        var message: String
        var fields: [String: String]

        /// One line, readable by a person first and a parser second. A beta
        /// report gets read by eye long before anything parses it.
        var line: String {
            let stamp = time.formatted(Entry.stamp)
            let extras = fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let level = level.rawValue.uppercased().padding(
                toLength: 7, withPad: " ", startingAt: 0)
            return extras.isEmpty
                ? "\(stamp) \(level) \(message)"
                : "\(stamp) \(level) \(message)  \(extras)"
        }

        // `ISO8601DateFormatter` is a non-Sendable reference type and cannot be
        // a `static let` under strict concurrency; the format *style* is a
        // value. `StorytellerDate` made the same move for the same reason.
        static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }
}

// MARK: - Redaction

public extension IssaLog {
    /// Keeping secrets out of a file whose whole purpose is to be sent to
    /// somebody else.
    ///
    /// Redaction happens on the way *in*, not on the way out: a file that has
    /// held a token for six hours has already been backed up, indexed and
    /// possibly synced, and scrubbing the export would be too late.
    enum Redaction {
        /// Field names whose value is never recorded, whatever it looks like.
        static let secretKeys: Set<String> = [
            "authorization", "token", "access_token", "accesstoken",
            "refresh_token", "refreshtoken", "device_code", "devicecode",
            "user_code", "usercode", "password", "secret", "client_secret",
            // A username is a credential too, and the password form's wire field
            // is literally `usernameOrEmail`, so a future call site that logged
            // the form body would be scrubbed on both halves rather than one.
            "username", "usernameoremail", "username_or_email",
        ]

        public static func scrub(_ text: String) -> String {
            var result = text
            // `Bearer <token>` wherever it appears in prose.
            result = result.replacingOccurrences(
                of: "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+",
                with: "Bearer «redacted»",
                options: .regularExpression,
            )
            // Credentials typed into the address itself: `https://user:pw@host`.
            // The server address is logged everywhere a request can fail, and
            // it also rides inside `URLError` descriptions, so no call-site
            // rule could catch it. The whole userinfo goes — a username is a
            // credential too — and the host stays, or the log cannot be
            // matched against anything.
            result = result.replacingOccurrences(
                of: "://[^/@\\s]+@",
                with: "://«redacted»@",
                options: .regularExpression,
            )
            // `key=value` and `"key": "value"` for anything named as a secret.
            for key in secretKeys {
                result = result.replacingOccurrences(
                    of: "(?i)\(key)\\s*[=:]\\s*\"?[A-Za-z0-9._~+/=-]+\"?",
                    with: "\(key)=«redacted»",
                    options: .regularExpression,
                )
            }
            // A user code as the app shows it: four, a dash, four — and
            // nothing adjacent. Without the guards this also matches the middle
            // of a UUID, and redacting the task identifiers out of a network
            // error leaves a log that cannot be correlated with anything.
            result = result.replacingOccurrences(
                of: "(?<![A-Za-z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4}(?![A-Za-z0-9-])",
                with: "«code»",
                options: .regularExpression,
            )
            return result
        }

        /// Whether a field name means "do not record the value".
        public static func isSecret(_ key: String) -> Bool {
            secretKeys.contains(key.lowercased().replacingOccurrences(of: "-", with: "_"))
        }
    }
}
