import AppKit
import FrontierCore

/// Asks each coding agent how much of its quota is gone, by running its own CLI.
///
/// Nothing here reads an agent's private session files; it only runs the documented command and
/// parses what the tool chooses to print.
enum LimitsRunner {
    /// A GUI app inherits almost no PATH, so the executables have to be found by hand.
    private static let searchPaths = [
        NSHomeDirectory() + "/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.npm-global/bin",
        "/usr/bin",
        "/bin",
    ]

    static func locate(_ executable: String) -> String? {
        searchPaths.lazy.map { $0 + "/" + executable }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs every supported provider that is actually installed. Blocking — call it off the main thread.
    static func readAll(_ providers: [LimitProvider] = LimitProvider.builtIn, timeout: TimeInterval = 45) -> [ProviderReading] {
        providers.map { provider in
            var reading = ProviderReading(provider: provider.name)
            guard let path = locate(provider.executable) else {
                reading.available = false
                reading.problem = "not installed"
                return reading
            }
            guard provider.supported else {
                reading.problem = "no usage command"
                return reading
            }
            let (output, code) = run(path, provider.arguments, timeout: timeout)
            return LimitParser.reading(provider: provider.name, output: output, exitCode: code)
        }
    }

    /// Runs one command, killing it if it overruns. Returns its combined output and exit code.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (String, Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        // A neutral directory: these tools read project config from the working directory.
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do { try task.run() } catch { return ("could not run \(path): \(error.localizedDescription)", 127) }

        // Read on a background queue, so a chatty command can't deadlock on a full pipe.
        var data = Data()
        let lock = NSLock()
        let reader = DispatchQueue(label: "frontier.limits.read")
        reader.async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); data = chunk; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning {
            task.terminate()
            usleep(200_000)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            return ("timed out after \(Int(timeout))s", 124)
        }
        task.waitUntilExit()
        reader.sync {}
        lock.lock(); let out = String(data: data, encoding: .utf8) ?? ""; lock.unlock()
        return (out, task.terminationStatus)
    }
}
