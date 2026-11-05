import Foundation

/// A line a process wrote to standard output or standard error.
enum OutputLine: Sendable {
    case out(String)
    case err(String)
}

struct ProcessResult: Sendable {
    let succeeded: Bool
    let output: String
    /// The lines written to standard error.
    let errors: [String]
}

/// Runs command-line tools (yt-dlp, FFmpeg) and reports their output line by line.
enum ProcessRunner {
    /// Runs `executable`. `onLine` is called on a background thread for every line it writes.
    /// Cancelling the task ends the process and everything it started (yt-dlp runs FFmpeg) and throws CancellationError.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ToolBox.environment()

        let output = OutputCollector { line in onLine?(.out(line)) }
        let errors = OutputCollector { line in onLine?(.err(line)) }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        for (pipe, collector) in [(outputPipe, output), (errorPipe, errors)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data) }
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { terminateTree(process.processIdentifier) }
        }

        for (pipe, collector) in [(outputPipe, output), (errorPipe, errors)] {
            pipe.fileHandleForReading.readabilityHandler = nil
            collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
            collector.finish()
        }
        try Task.checkCancellation()
        return ProcessResult(succeeded: process.terminationStatus == 0, output: output.text,
                             errors: errors.text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Ends `pid` and all its descendants. The standalone yt-dlp is a launcher that starts Python, which starts FFmpeg.
    private static func terminateTree(_ pid: pid_t) {
        var tree = [pid]
        var index = 0
        while index < tree.count {
            tree += childProcesses(of: tree[index])
            index += 1
        }
        for process in tree.reversed() { kill(process, SIGTERM) }
    }

    private static func childProcesses(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
}

/// Collects a process's output and reports complete lines (yt-dlp ends progress lines with \r or \n).
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var partialLine = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines = lock.withLock { () -> [String] in
            data.append(chunk)
            var parts = (partialLine + String(decoding: chunk, as: UTF8.self))
                .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            partialLine = parts.removeLast()
            return parts.filter { !$0.isEmpty }
        }
        lines.forEach(onLine)
    }

    /// Reports the last line if it didn't end with a line break.
    func finish() {
        let last = lock.withLock { () -> String in
            defer { partialLine = "" }
            return partialLine
        }
        if !last.isEmpty { onLine(last) }
    }
}
