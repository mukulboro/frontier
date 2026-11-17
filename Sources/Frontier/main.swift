import AppKit
import FrontierCore

let args = CommandLine.arguments
if args.contains("--usage") {
    // Prints the tally in the terminal. Reads usage metadata only, never message content.
    let root = ProcessInfo.processInfo.environment["FRONTIER_USAGE_ROOT"].map { URL(fileURLWithPath: $0) } ?? UsageScanner.defaultRoot
    let r = UsageScanner(root: root).scan()
    print("messages \(r.all.messages)  output \(formatTokens(r.all.output))  write \(formatTokens(r.all.cacheWrite))  read \(formatTokens(r.all.cacheRead))")
    print("days \(r.days.count)  projects \(r.projects.count)  models \(r.models.count)")
    for (name, t) in r.top(r.models, 6) { print(String(format: "  %-24s %8d msgs  %10s out", (name as NSString).utf8String!, t.messages, (formatTokens(t.output) as NSString).utf8String!)) }
    for (name, t) in r.top(r.projects, 6) { print(String(format: "  %-24s %8d msgs  %10s out", (name as NSString).utf8String!, t.messages, (formatTokens(t.output) as NSString).utf8String!)) }
    exit(0)
} else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    Snapshots.run(outputDir: args[i + 1])
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
