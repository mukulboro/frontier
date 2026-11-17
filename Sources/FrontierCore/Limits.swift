import Foundation

/// One quota window reported by a coding agent, e.g. "Current session: 80% used".
public struct UsageLimit: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var percentUsed: Int
    /// Free text as the tool printed it, e.g. "Nov 17 at 5:25pm (Asia/Katmandu)".
    public var resets: String?

    public var id: String { label }
    public var percentLeft: Int { max(0, min(100, 100 - percentUsed)) }
    /// 0…1 remaining, for the ring.
    public var fractionLeft: Double { Double(percentLeft) / 100 }

    public init(label: String, percentUsed: Int, resets: String? = nil) {
        self.label = label
        self.percentUsed = max(0, min(100, percentUsed))
        self.resets = resets
    }

    /// "Current week (all models)" → "Week". Keeps ring captions short.
    public var shortLabel: String {
        var s = label
        if let paren = s.firstIndex(of: "(") { s = String(s[s.startIndex..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["Current ", "This "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.isEmpty ? label : s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// What one agent reported the last time it was asked.
public struct ProviderReading: Codable, Equatable, Sendable, Identifiable {
    public var provider: String
    public var limits: [UsageLimit] = []
    /// Set when the agent could not be asked, or said something unparseable.
    public var problem: String?
    /// A notice worth passing on, such as an expiring sign-in.
    public var notice: String?
    public var checked: Date?
    /// False when the tool isn't installed, so the UI can leave it out quietly.
    public var available = true

    public var id: String { provider }

    public init(provider: String) { self.provider = provider }

    /// The window closest to running out — what the headline ring should show.
    public var tightest: UsageLimit? { limits.min { $0.percentLeft < $1.percentLeft } }
}

/// An agent Frontier can ask about quota, and how to ask it.
public struct LimitProvider: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    /// Executable name, looked up on a known list of paths.
    public var executable: String
    public var arguments: [String]
    /// Nil when the tool has no command that reports quota; the UI says so instead of guessing.
    public var supported: Bool

    public var id: String { name }

    public init(name: String, executable: String, arguments: [String], supported: Bool = true) {
        self.name = name; self.executable = executable; self.arguments = arguments; self.supported = supported
    }

    /// Checked against this machine on 2026-11-17.
    ///
    /// Only Claude Code publishes quota through its CLI. Codex and Antigravity have no documented
    /// command that reports it, so they are listed as unsupported rather than guessed at — reading
    /// their private session logs would be both fragile and an overreach.
    public static let builtIn: [LimitProvider] = [
        // `--no-session-persistence` keeps the check from leaving a resumable session behind.
        .init(name: "Claude Code", executable: "claude",
              arguments: ["-p", "/usage", "--no-session-persistence"]),
        .init(name: "Codex", executable: "codex", arguments: [], supported: false),
        .init(name: "Antigravity", executable: "agy", arguments: [], supported: false),
    ]
}

public enum LimitParser {
    /// Reads lines of the form `<label>: <n>% used · resets <when>`.
    ///
    /// Only lines shaped exactly like that count. The same output also carries advice lines such as
    /// `  90%  Start fresh when you switch tasks`, which are percentages of something else entirely
    /// and must never be mistaken for quota.
    public static func parse(_ text: String) -> [UsageLimit] {
        var out: [UsageLimit] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // A quota line starts hard left; the advice lines are indented.
            guard line == line.trimmingCharacters(in: .whitespaces) else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count < 60 else { continue }
            var rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // "<n>% used"
            guard let pct = rest.firstIndex(of: "%") else { continue }
            let digits = String(rest[rest.startIndex..<pct])
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) else { continue }
            rest = String(rest[rest.index(after: pct)...]).trimmingCharacters(in: .whitespaces)
            guard rest.lowercased().hasPrefix("used") else { continue }
            rest = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces)

            var resets: String?
            if let dot = rest.range(of: "resets") {
                resets = String(rest[dot.upperBound...]).trimmingCharacters(in: .whitespaces)
                if resets?.isEmpty == true { resets = nil }
            }
            out.append(UsageLimit(label: label, percentUsed: value, resets: resets))
        }
        return out
    }

    /// Picks out a warning worth repeating, such as an expiring sign-in.
    public static func notice(in text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard lower.contains("sign-in ends") || lower.contains("auth login")
                    || lower.hasPrefix("warning:") else { continue }
            return line.hasPrefix("Warning: ") ? String(line.dropFirst(9)) : line
        }
        return nil
    }

    /// Turns raw command output into a reading.
    public static func reading(provider: String, output: String, exitCode: Int32) -> ProviderReading {
        var r = ProviderReading(provider: provider)
        r.checked = Date()
        r.limits = parse(output)
        r.notice = notice(in: output)
        if r.limits.isEmpty {
            let lower = output.lowercased()
            if exitCode != 0 {
                r.problem = "couldn't read limits (exit \(exitCode))"
            } else if lower.contains("log in") || lower.contains("login") || lower.contains("not authenticated") {
                r.problem = "not signed in"
            } else {
                r.problem = "couldn't read limits"
            }
        }
        return r
    }
}
