import Darwin
import Foundation

/// Tokens recorded against one bucket — a day, a project or a model.
public struct UsageTotals: Codable, Equatable, Sendable {
    public var messages = 0
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init() {}

    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        var r = a
        r.messages += b.messages; r.input += b.input; r.output += b.output
        r.cacheWrite += b.cacheWrite; r.cacheRead += b.cacheRead
        return r
    }

    public static func += (a: inout UsageTotals, b: UsageTotals) { a = a + b }

    /// Everything the model was shown, however it got there.
    public var readTokens: Int { input + cacheWrite + cacheRead }
}

/// Everything the Tally tab draws.
public struct UsageReport: Codable, Equatable, Sendable {
    /// Local day (yyyy-MM-dd) → totals.
    public var days: [String: UsageTotals] = [:]
    public var projects: [String: UsageTotals] = [:]
    public var models: [String: UsageTotals] = [:]
    public var all = UsageTotals()
    /// When the transcripts were last read.
    public var updated: Date?

    public init() {}

    public func totals(sinceDaysAgo n: Int, today: Date = Date(), calendar: Calendar = .current) -> UsageTotals {
        var out = UsageTotals()
        for i in 0..<max(1, n) {
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            if let t = days[UsageScanner.dayKey(d, calendar: calendar)] { out += t }
        }
        return out
    }

    /// Oldest-first run of daily output tokens, for the sparkline.
    public func recentDays(_ n: Int, today: Date = Date(), calendar: Calendar = .current) -> [(day: String, totals: UsageTotals)] {
        (0..<max(1, n)).reversed().compactMap { i in
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { return nil }
            let key = UsageScanner.dayKey(d, calendar: calendar)
            return (key, days[key] ?? UsageTotals())
        }
    }

    public func top(_ bucket: [String: UsageTotals], _ n: Int) -> [(name: String, totals: UsageTotals)] {
        bucket.map { (name: $0.key, totals: $0.value) }
            .sorted { ($0.totals.output, $0.name) > ($1.totals.output, $1.name) }
            .prefix(n).map { $0 }
    }
}

/// Where each transcript was read up to, so a rescan only reads what is new.
struct FileMark: Codable, Equatable {
    var size: UInt64
    var modified: Double
    /// Byte offset just past the last complete line counted.
    var offset: UInt64
}

struct UsageCache: Codable {
    var version = 3
    var marks: [String: FileMark] = [:]
    /// Hashes of every message already counted. Messages repeat both within a file and across files
    /// (a subagent transcript restates its parent's rows), so dedupe has to be global, not adjacent.
    var seen: [UInt64] = []
    var report = UsageReport()
}

/// Reads Claude Code's local transcripts and adds up the tokens they record.
///
/// **It reads usage metadata only** — message ids, timestamps, model names, the working directory and
/// the token counts. Message content is never decoded, stored, logged or displayed.
///
/// Two things make the raw rows misleading, and both are handled here:
/// one API call is written as several rows — one per content block, and again in a subagent's own
/// transcript — so the same `usage` repeats (about 2.2× on this machine); and most transcripts are
/// nested well below the project folder.
public struct UsageScanner {
    public let root: URL
    public let cacheURL: URL?

    public init(root: URL = UsageScanner.defaultRoot, cacheURL: URL? = nil) {
        self.root = root
        self.cacheURL = cacheURL
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Only the fields we need; everything else in the row is ignored.
    private struct Row: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                var input_tokens: Int?
                var output_tokens: Int?
                var cache_creation_input_tokens: Int?
                var cache_read_input_tokens: Int?
            }
            var id: String?
            var model: String?
            var usage: Usage?
        }
        var type: String?
        var timestamp: String?
        var cwd: String?
        var requestId: String?
        var message: Message?
    }

    /// Rescans, reusing the cache for files that haven't changed. Safe to call repeatedly.
    public func scan() -> UsageReport {
        var cache = loadCache()
        let decoder = JSONDecoder()
        var marks = cache.marks
        var report = cache.report
        var seen = Set(cache.seen)
        let files = transcripts()

        // The report holds running totals, so a file whose earlier bytes changed can't be fixed by
        // reading its tail: its old contribution is already baked in and can't be subtracted. That
        // happens when a transcript is removed, truncated or rewritten, so in those cases start over.
        // Transcripts are otherwise append-only, which is the case this stays incremental for.
        let present = Set(files.map(\.path))
        var stale = marks.keys.contains { !present.contains($0) }
        if !stale {
            for file in files where marks[file.path] != nil {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.uint64Value ?? 0
                if size < marks[file.path]!.offset { stale = true; break }
            }
        }
        if stale {
            marks = [:]
            report = UsageReport()
            seen = []
        }

        for file in files {
            autoreleasepool {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
            var mark = marks[file.path] ?? FileMark(size: 0, modified: 0, offset: 0)
            if mark.size == size, mark.modified == modified { return }
            read(file, from: &mark, into: &report, seen: &seen, decoder: decoder)
            mark.size = size
            mark.modified = modified
            marks[file.path] = mark
            }
        }

        report.all = report.days.values.reduce(UsageTotals(), +)
        report.updated = Date()
        cache.marks = marks
        cache.seen = Array(seen)
        cache.report = report
        save(cache)
        return report
    }

    /// Every .jsonl under the root, at any depth — most live several levels down.
    func transcripts() -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    private func read(_ url: URL, from mark: inout FileMark, into report: inout UsageReport,
                      seen: inout Set<UInt64>, decoder: JSONDecoder) {
        // Deliberately POSIX rather than FileHandle: `FileHandle.read(upToCount:)` hands back an
        // autoreleased object per chunk, and in a tight loop with no pool draining those pile up —
        // reading these transcripts that way peaked at 658 MB with no parsing at all. One reused
        // buffer allocates nothing per chunk.
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard lseek(fd, off_t(mark.offset), SEEK_SET) >= 0 else { return }

        let chunkSize = 1 << 20
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var pending: [UInt8] = []
        var consumed = mark.offset

        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunkSize) }
            guard n > 0 else { break }
            pending.append(contentsOf: chunk[0..<n])
            var start = 0
            // Belt and braces: drains anything autoreleased while decoding this chunk's lines.
            autoreleasepool {
                while let nl = pending[start...].firstIndex(of: 0x0A) {
                    if nl > start {
                        count(line: Data(pending[start..<nl]), into: &report, seen: &seen, decoder: decoder)
                    }
                    consumed += UInt64(nl - start + 1)
                    start = nl + 1
                }
            }
            // Keep only the unfinished tail.
            if start > 0 { pending.removeFirst(start) }
        }

        // Whatever is left has no newline yet: the file is still being written. Leave it for next time.
        mark.offset = consumed
    }

    private func count(line: Data, into report: inout UsageReport, seen: inout Set<UInt64>, decoder: JSONDecoder) {
        // Cheap rejects first: most lines are not assistant rows with usage.
        guard line.count > 40, contains(line, Self.usageMarker), contains(line, Self.assistantMarker) else { return }
        guard let row = try? decoder.decode(Row.self, from: line), row.type == "assistant",
              let message = row.message, let usage = message.usage else { return }
        let model = message.model ?? "unknown"
        guard model != "<synthetic>" else { return }

        // Count each API call once, however many rows restate it.
        guard seen.insert(Self.fingerprint((message.id ?? "") + "|" + (row.requestId ?? ""))).inserted else { return }

        var t = UsageTotals()
        t.messages = 1
        t.input = usage.input_tokens ?? 0
        t.output = usage.output_tokens ?? 0
        t.cacheWrite = usage.cache_creation_input_tokens ?? 0
        t.cacheRead = usage.cache_read_input_tokens ?? 0

        report.days[Self.localDay(fromISO: row.timestamp), default: UsageTotals()] += t
        report.models[model, default: UsageTotals()] += t
        if let cwd = row.cwd, !cwd.isEmpty {
            report.projects[(cwd as NSString).lastPathComponent, default: UsageTotals()] += t
        }
    }

    /// FNV-1a. Swift's own hashing is seeded per process, so it cannot be persisted across launches.
    static func fingerprint(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    private static let usageMarker = Array(#""usage""#.utf8)
    private static let assistantMarker = Array(#""assistant""#.utf8)

    private func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        let first = needle[0]
        return haystack.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            outer: for i in 0...(b.count - needle.count) {
                guard b[i] == first else { continue }
                for j in 1..<needle.count where b[i + j] != needle[j] { continue outer }
                return true
            }
            return false
        }
    }

    // MARK: Dates

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-11-17T08:12:33.123Z" → the local day it falls on. Hand-rolled because a DateFormatter per
    /// row is far too slow across tens of thousands of rows.
    static func localDay(fromISO iso: String?, offsetSeconds: Int? = nil) -> String {
        guard let iso, iso.count >= 19 else { return "unknown" }
        let d = Array(iso.utf8)
        func num(_ r: Range<Int>) -> Int {
            var v = 0
            for i in r {
                let c = d[i]
                guard c >= 48, c <= 57 else { return -1 }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        let y = num(0..<4), m = num(5..<7), day = num(8..<10), hh = num(11..<13), mm = num(14..<16)
        guard y > 0, m > 0, day > 0, hh >= 0, mm >= 0 else { return "unknown" }
        let offset = offsetSeconds ?? TimeZone.current.secondsFromGMT()
        let shifted = days(y: y, m: m, d: day) * 86400 + hh * 3600 + mm * 60 + offset
        let (ly, lm, ld) = civil(fromDays: Int(floor(Double(shifted) / 86400)))
        return String(format: "%04d-%02d-%02d", ly, lm, ld)
    }

    /// Days since 1970-01-01 (Howard Hinnant's civil calendar algorithm).
    static func days(y: Int, m: Int, d: Int) -> Int {
        let y2 = y - (m <= 2 ? 1 : 0)
        let era = (y2 >= 0 ? y2 : y2 - 399) / 400
        let yoe = y2 - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    // MARK: Cache

    private func loadCache() -> UsageCache {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(UsageCache.self, from: data), c.version == 3 else { return UsageCache() }
        return c
    }

    private func save(_ cache: UsageCache) {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("Frontier: could not save the usage cache: \(error.localizedDescription)")
        }
    }
}

/// Compact token counts: 980, 12.4k, 3.1M, 1.2B.
public func formatTokens(_ n: Int) -> String {
    let v = Double(n)
    switch abs(n) {
    case 0..<1_000: return "\(n)"
    case 1_000..<1_000_000: return String(format: "%.1fk", v / 1_000)
    case 1_000_000..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
    default: return String(format: "%.2fB", v / 1_000_000_000)
    }
}
