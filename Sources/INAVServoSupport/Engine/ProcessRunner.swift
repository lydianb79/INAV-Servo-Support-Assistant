import Foundation

/// Runs external tools (git, cmake/make) and streams their output line by line.
final class ProcessRunner {
    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    /// Runs `command` through a login shell so Homebrew / user PATH entries (cmake, arm toolchain) are found.
    func runShell(_ command: String, in directory: URL?,
                  output: @escaping (String) -> Void,
                  completion: @escaping (Int32) -> Void) {
        run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-l", "-c", command],
            in: directory, output: output, completion: completion)
    }

    func run(executable: URL, arguments: [String], in directory: URL?,
             output: @escaping (String) -> Void,
             completion: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let d = directory { p.currentDirectoryURL = d }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            // git progress uses carriage returns – turn them into new lines for the log view
            let text = s.replacingOccurrences(of: "\r", with: "\n")
            DispatchQueue.main.async { output(text) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { output(s) }
                completion(status)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            DispatchQueue.main.async {
                output("Failed to start \(executable.path): \(error.localizedDescription)\n")
                completion(-1)
            }
        }
    }

    func cancel() {
        process?.terminate()
    }

    /// Absolute path of an executable via `/usr/bin/which` in a login shell, or nil.
    static func locate(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v \(tool)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0 && !s.isEmpty) ? s : nil
    }
}

/// Quotes a string for safe use inside a zsh command line.
func shellQuote(_ s: String) -> String {
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
