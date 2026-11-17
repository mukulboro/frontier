import AppKit
import Darwin

struct AppInfo: Identifiable, Equatable {
    let path: String
    let name: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// What the wheel's hub shows about the highlighted app.
struct AppMeta: Equatable {
    var name: String
    var version: String?
    var category: String?
    var running: Bool
    var hidden: Bool
    var launchedAt: Date?
    var memoryMB: Int?
}

enum AppCatalog {
    private static let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                "/Applications/Utilities", NSHomeDirectory() + "/Applications",
                                "/System/Library/CoreServices/Finder.app"]

    /// Every installed app, sorted by name. Scans a handful of folders; called only when the picker opens.
    static func installed() -> [AppInfo] {
        let fm = FileManager.default
        var seen = Set<String>(), out: [AppInfo] = []
        func add(_ path: String) {
            guard seen.insert(path).inserted else { return }
            out.append(AppInfo(path: path, name: fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")))
        }
        for root in roots {
            if root.hasSuffix(".app") { if fm.fileExists(atPath: root) { add(root) }; continue }
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where item.hasSuffix(".app") {
                add(root + "/" + item)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func info(path: String) -> AppInfo? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return AppInfo(path: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
    }

    static let defaultSlots: [String] = {
        let wanted = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app",
                      "/System/Applications/Utilities/Terminal.app", "/System/Applications/Mail.app",
                      "/System/Applications/Calendar.app", "/System/Applications/Notes.app",
                      "/System/Applications/Music.app", "/System/Applications/System Settings.app"]
        let alt = ["/System/Cryptexes/App/System/Applications/Safari.app"]
        return wanted.map { p in
            if FileManager.default.fileExists(atPath: p) { return p }
            if p.hasSuffix("Safari.app"), let a = alt.first(where: { FileManager.default.fileExists(atPath: $0) }) { return a }
            return ""
        }
    }()

    private static var iconCache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let hit = iconCache[path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 128, height: 128)
        iconCache[path] = img
        return img
    }

    static func flushIcons() { iconCache.removeAll() }

    static func running(_ path: String) -> NSRunningApplication? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.resolvingSymlinksInPath() == url
        }
    }

    static func meta(_ app: AppInfo) -> AppMeta {
        let bundle = Bundle(url: app.url)
        let run = running(app.path)
        var mem: Int?
        if let pid = run?.processIdentifier {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 { mem = Int(usage.ri_phys_footprint / 1_048_576) }
        }
        return AppMeta(name: app.name,
                       version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       category: prettyCategory(bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String),
                       running: run != nil, hidden: run?.isHidden ?? false, launchedAt: run?.launchDate, memoryMB: mem)
    }

    /// "public.app-category.developer-tools" -> "Developer Tools"
    static func prettyCategory(_ uti: String?) -> String? {
        guard let last = uti?.split(separator: ".").last, !last.isEmpty else { return nil }
        return last.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Brings the app forward if it's running (switching Spaces as needed), otherwise launches it.
    static func summon(_ app: AppInfo) {
        if let run = running(app.path) {
            if run.isHidden { run.unhide() }
            NSApp.yieldActivation(to: run)
            if run.activate(from: .current, options: [.activateAllWindows]) { return }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) { _, error in
            if let error { NSLog("Frontier: could not open \(app.name): \(error.localizedDescription)") }
        }
    }
}
