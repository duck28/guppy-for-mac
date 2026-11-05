import Foundation

/// An installed yt-dlp or FFmpeg.
struct Tool: Equatable, Sendable {
    let url: URL
    /// yt-dlp: a release date such as "2026.10.21". FFmpeg: its build name ("9.0.2", "N-122320-g38e89fe502").
    let version: String

    /// Downloaded by Guppy into its own folder.
    var isManaged: Bool { url.path.hasPrefix(ToolBox.folder.path) }
}

struct ToolSet: Equatable, Sendable {
    var ytdlp: Tool?
    var ffmpeg: Tool?

    /// YouTube regularly breaks older yt-dlp releases.
    var isYTDLPOutdated: Bool {
        guard let version = ytdlp?.version,
              let released = ToolBox.versionFormatter.date(from: String(version.prefix(10))) else { return false }
        return Date().timeIntervalSince(released) > 90 * 24 * 3600
    }

    var missing: [String] {
        [ytdlp == nil ? "yt-dlp" : nil, ffmpeg == nil ? "FFmpeg" : nil].compactMap { $0 }
    }
}

/// Finds yt-dlp and FFmpeg on this Mac, or downloads them into Guppy's own folder
/// (~/Library/Application Support/Guppy/bin), which is checked first.
enum ToolBox {
    enum ToolError: LocalizedError {
        case download(String, Int)
        case unpack(String)

        var errorDescription: String? {
            switch self {
            case let .download(tool, status):
                return "\(tool) couldn't be downloaded (HTTP \(status)). Try again in a moment, or install it with Homebrew: brew install yt-dlp ffmpeg"
            case let .unpack(message):
                return "FFmpeg couldn't be unpacked: \(message)"
            }
        }
    }

    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Guppy", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)

    static let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// Static FFmpeg builds for macOS by Martin Riedl. The server sometimes answers 404, so the snapshot build is the fallback.
    static var ffmpegURLs: [URL] {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        return ["release", "snapshot"].map {
            URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(architecture)/\($0)/ffmpeg.zip")!
        }
    }

    static let versionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    /// Apps launched from Finder don't get the shell's PATH, so add the usual install locations.
    /// yt-dlp looks up FFmpeg and Deno there; PYTHONIOENCODING keeps titles with accents intact.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = [folder.path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.deno/bin"]
        environment["PATH"] = (folders + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUTF8"] = "1"
        return environment
    }

    private static func executables(named name: String, in folders: [String]) -> [URL] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        return folders
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .filter { fileManager.isExecutableFile(atPath: $0.path) && seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    private static func ytdlpCandidates() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var folders = [folder.path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin"]
        // pip installs into a folder per Python version.
        for root in ["/Library/Frameworks/Python.framework/Versions", "\(home)/Library/Python"] {
            let versions = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            folders += versions.filter { $0 != "Current" }.map { "\(root)/\($0)/bin" }
        }
        return executables(named: "yt-dlp", in: folders)
    }

    private static func ffmpegCandidates() -> [URL] {
        executables(named: "ffmpeg", in: [folder.path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"])
    }

    /// The newest yt-dlp (Guppy's own copy wins a tie, since Guppy can update it) and the first working FFmpeg.
    static func find() async -> ToolSet {
        let ytdlps = await withTaskGroup(of: Tool?.self) { group in
            for url in ytdlpCandidates() {
                group.addTask {
                    guard let result = try? await ProcessRunner.run(url, ["--version"]), result.succeeded else { return nil }
                    let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return version.isEmpty ? nil : Tool(url: url, version: version)
                }
            }
            var tools: [Tool] = []
            for await tool in group { if let tool { tools.append(tool) } }
            return tools
        }
        let ytdlp = ytdlps.max { ($0.version, $0.isManaged ? 1 : 0) < ($1.version, $1.isManaged ? 1 : 0) }

        var ffmpeg: Tool?
        for url in ffmpegCandidates() {
            guard let result = try? await ProcessRunner.run(url, ["-version"]), result.succeeded else { continue }
            // "ffmpeg version 9.0.2 Copyright (c) 2000-2026 …"
            let words = result.output.split(separator: " ", maxSplits: 3)
            ffmpeg = Tool(url: url, version: words.count > 2 ? String(words[2]) : "")
            break
        }
        return ToolSet(ytdlp: ytdlp, ffmpeg: ffmpeg)
    }

    // MARK: - Installing

    /// Downloads the latest yt-dlp into Guppy's folder (replacing an older copy there). `progress` gets 0...1.
    static func installYTDLP(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("yt-dlp")
        try await download(ytdlpURL, named: "yt-dlp", to: target, progress: progress)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    /// Downloads FFmpeg and unpacks it into Guppy's folder.
    static func installFFmpeg(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("ffmpeg.zip")
        defer { try? FileManager.default.removeItem(at: archive) }

        var lastError: Error?
        downloading: for url in ffmpegURLs {
            for attempt in 0..<2 {
                do {
                    try await download(url, named: "FFmpeg", to: archive, progress: progress)
                    lastError = nil
                    break downloading
                } catch {
                    lastError = error
                    if attempt == 0 { try await Task.sleep(for: .seconds(2)) }
                }
            }
        }
        if let lastError { throw lastError }

        let unzip = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, folder.path])
        guard unzip.succeeded else { throw ToolError.unpack(unzip.errors.last ?? "ditto failed.") }
        let ffmpeg = folder.appendingPathComponent("ffmpeg")
        guard FileManager.default.fileExists(atPath: ffmpeg.path) else { throw ToolError.unpack("the download didn't contain ffmpeg.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
    }

    private static func download(_ url: URL, named tool: String, to destination: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ToolError.download(tool, status) }
        let total = response.expectedContentLength

        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        var lastReport = 0.0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                guard buffer.count >= 1 << 16 else { continue }
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let fraction = Double(received) / Double(total)
                    if fraction - lastReport >= 0.01 {
                        lastReport = fraction
                        progress(fraction)
                    }
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
    }
}
