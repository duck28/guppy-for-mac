import Foundation

/// A video, or one video of a playlist.
struct MediaEntry: Identifiable, Equatable, Sendable {
    var id: String { url }
    let url: String
    let title: String
    let channel: String?
    let duration: TimeInterval?
    let thumbnail: URL?
}

struct MediaInfo: Equatable, Sendable {
    let isPlaylist: Bool
    let title: String
    let channel: String?
    let thumbnail: URL?
    /// Video heights on offer (2160, 1080…), highest first. Empty for playlists.
    let heights: [Int]
    /// The video itself, or the videos of the playlist.
    let entries: [MediaEntry]
}

enum Container: String, CaseIterable, Identifiable, Sendable {
    case mp4, mkv, webm

    var id: Self { self }

    var title: String {
        switch self {
        case .mp4: return "MP4"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        }
    }
}

enum AudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3, m4a, opus, flac, wav

    var id: Self { self }

    var title: String {
        switch self {
        case .mp3: return "MP3"
        case .m4a: return "M4A (AAC)"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        }
    }

    var isLossless: Bool { self == .flac || self == .wav }
}

struct DownloadOptions: Equatable, Sendable {
    var url: String
    var audioOnly: Bool
    /// The highest video height to download; nil for the best there is.
    var maxHeight: Int?
    var container: Container
    var audioFormat: AudioFormat
    /// kbps, for the lossy audio formats.
    var audioBitrate: Int
    /// Cover art, title, artist and chapters.
    var embedMetadata: Bool
    var folder: URL
}

/// How far a download or conversion is.
struct JobProgress: Equatable, Sendable {
    enum Stage: Sendable { case downloading, processing, converting }

    /// 0...1, or nil while it isn't known.
    var fraction: Double?
    /// Bytes per second.
    var speed: Double?
    /// Seconds left.
    var eta: Double?
    var stage: Stage
}

/// Reads what's behind a link and downloads it with yt-dlp.
enum YTDLP {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The error yt-dlp reported, in a sentence.
    static func failure(from errors: [String]) -> Failure {
        var message = errors.last { $0.hasPrefix("ERROR:") }.map { String($0.dropFirst("ERROR:".count)) }
            ?? errors.last
            ?? "it stopped unexpectedly."
        message = message.trimmingCharacters(in: .whitespaces)
        // "[youtube] abc123: Video unavailable" reads better without the prefix.
        if let range = message.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        return Failure(message: "\(message) If this keeps happening, update yt-dlp in Settings.")
    }

    /// Deno is used automatically when it's on the PATH; Node or Bun have to be named explicitly.
    /// (yt-dlp needs a JavaScript runtime for YouTube since 2025.11.)
    private static func javaScriptRuntimeArguments(for tool: Tool) -> [String] {
        guard tool.version >= "2025.11" else { return [] }
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        func firstExecutable(_ paths: [String]) -> String? { paths.first { fileManager.isExecutableFile(atPath: $0) } }

        if firstExecutable(["/opt/homebrew/bin/deno", "/usr/local/bin/deno", "\(home)/.deno/bin/deno"]) != nil { return [] }
        let nvmRoot = "\(home)/.nvm/versions/node"
        let nvmNodes = ((try? fileManager.contentsOfDirectory(atPath: nvmRoot)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmRoot)/\($0)/bin/node" }
        if let node = firstExecutable(["/opt/homebrew/bin/node", "/usr/local/bin/node", "\(home)/.volta/bin/node"] + nvmNodes) {
            return ["--js-runtimes", "node:\(node)"]
        }
        if let bun = firstExecutable(["/opt/homebrew/bin/bun", "/usr/local/bin/bun", "\(home)/.bun/bin/bun"]) {
            return ["--js-runtimes", "bun:\(bun)"]
        }
        return []
    }

    // MARK: - Info

    /// What's behind `url`: a video (with its formats) or a playlist (with its videos).
    static func info(tool: Tool, url: String) async throws -> MediaInfo {
        let result = try await ProcessRunner.run(tool.url, javaScriptRuntimeArguments(for: tool) + [
            "-J", "--flat-playlist", "--no-playlist", "--no-warnings", "--encoding", "utf-8", url,
        ])
        guard result.succeeded else { throw failure(from: result.errors) }
        return try parseInfo(Data(result.output.utf8))
    }

    static func parseInfo(_ data: Data) throws -> MediaInfo {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "yt-dlp didn't describe this link.")
        }
        if value["_type"] as? String == "playlist" {
            let entries = ((value["entries"] as? [[String: Any]]) ?? []).compactMap(entry)
            guard let first = entries.first else { throw Failure(message: "This playlist has no videos that can be downloaded.") }
            return MediaInfo(isPlaylist: true,
                             title: string(value, "title") ?? "Playlist",
                             channel: string(value, "channel") ?? string(value, "uploader"),
                             thumbnail: thumbnail(value) ?? first.thumbnail,
                             heights: [],
                             entries: entries)
        }
        let formats = (value["formats"] as? [[String: Any]]) ?? []
        let heights = Set(formats.filter { $0["vcodec"] as? String != "none" }.compactMap { $0["height"] as? Int })
        guard let video = entry(value) else { throw Failure(message: "This video can't be downloaded.") }
        return MediaInfo(isPlaylist: false, title: video.title, channel: video.channel, thumbnail: video.thumbnail,
                         heights: heights.sorted(by: >), entries: [video])
    }

    private static func string(_ value: [String: Any], _ key: String) -> String? {
        (value[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func thumbnail(_ value: [String: Any]) -> URL? {
        let url = string(value, "thumbnail")
            ?? (value["thumbnails"] as? [[String: Any]])?.reversed().lazy.compactMap { string($0, "url") }.first
        return url.flatMap(URL.init(string:))
    }

    private static func entry(_ value: [String: Any]) -> MediaEntry? {
        guard let url = string(value, "webpage_url") ?? string(value, "url")
                ?? string(value, "id").map({ "https://www.youtube.com/watch?v=\($0)" }) else { return nil }
        let title = string(value, "title") ?? url
        // Flat playlists list videos that can't be watched under placeholder titles.
        guard title != "[Private video]" && title != "[Deleted video]" else { return nil }
        return MediaEntry(url: url, title: title,
                     channel: string(value, "channel") ?? string(value, "uploader"),
                     duration: (value["duration"] as? NSNumber)?.doubleValue,
                     thumbnail: thumbnail(value))
    }

    // MARK: - Downloading

    static func arguments(for options: DownloadOptions, ffmpeg: Tool) -> [String] {
        var arguments = [
            "--no-playlist", "--newline", "--progress", "--no-simulate", "--encoding", "utf-8",
            "--ffmpeg-location", ffmpeg.url.path,
            "-P", options.folder.path, "-o", "%(title)s.%(ext)s",
            "--progress-template",
            "download:GUPPY_DL|%(progress.filename)s|%(progress.downloaded_bytes)s|%(progress.total_bytes,progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:GUPPY_PP|%(progress.postprocessor)s|%(progress.status)s",
            "--print", "after_move:GUPPY_FILE|%(filepath)s",
        ]
        let canEmbedThumbnail: Bool
        if options.audioOnly {
            let format = options.audioFormat
            // Take the stream that needs no conversion when there is one.
            let selector: String
            switch format {
            case .m4a: selector = "ba[ext=m4a]/ba/b"
            case .opus: selector = "ba[acodec=opus]/ba/b"
            default: selector = "ba/b"
            }
            arguments += ["-f", selector, "-x", "--audio-format", format.rawValue]
            if !format.isLossless { arguments += ["--audio-quality", "\(options.audioBitrate)K"] }
            canEmbedThumbnail = format != .wav
        } else {
            let container = options.container
            let resolution = options.maxHeight.map { "res:\($0)" } ?? "res"
            // Prefer codecs every player can open in that container.
            let sort: String
            switch container {
            case .webm: sort = "\(resolution),vcodec:vp9,acodec:opus"
            case .mkv: sort = resolution
            case .mp4: sort = "\(resolution),vcodec:h264,acodec:aac"
            }
            arguments += ["-f", "bv*+ba/b", "-S", sort,
                          "--merge-output-format", container.rawValue, "--remux-video", container.rawValue]
            if options.embedMetadata { arguments += ["--embed-chapters"] }
            canEmbedThumbnail = container != .webm
        }
        if options.embedMetadata {
            arguments += ["--embed-metadata"]
            if canEmbedThumbnail { arguments += ["--embed-thumbnail", "--convert-thumbnails", "jpg"] }
        }
        arguments.append(options.url)
        return arguments
    }

    /// Downloads a video or its audio. `progress` is called on a background thread. Returns the saved file.
    static func download(tool: Tool, ffmpeg: Tool, options: DownloadOptions,
                         progress: @escaping @Sendable (JobProgress) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
        let parser = DownloadOutputParser()
        let result = try await ProcessRunner.run(tool.url, javaScriptRuntimeArguments(for: tool)
                                                 + arguments(for: options, ffmpeg: ffmpeg)) { line in
            if let report = parser.handle(line) { progress(report) }
        }
        guard result.succeeded else { throw failure(from: result.errors) }
        guard let file = parser.savedFile else { throw Failure(message: "yt-dlp finished without saving a file.") }
        return URL(fileURLWithPath: file)
    }
}

/// Turns yt-dlp's output (with Guppy's progress templates) into progress reports and finds the saved file.
final class DownloadOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String] = []
    private var lastReport = Date.distantPast
    private var file: String?
    /// Reports at most this often, since yt-dlp prints a line for every chunk.
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.12) {
        self.minimumInterval = minimumInterval
    }

    /// The final file, once yt-dlp has printed it.
    var savedFile: String? { lock.withLock { file } }

    func handle(_ line: OutputLine) -> JobProgress? {
        lock.withLock { () -> JobProgress? in
            switch line {
            case let .out(text):
                if text.hasPrefix("GUPPY_FILE|") {
                    file = String(text.dropFirst("GUPPY_FILE|".count)).trimmingCharacters(in: .whitespaces)
                } else if text.hasPrefix("GUPPY_DL|") {
                    return downloadProgress(String(text.dropFirst("GUPPY_DL|".count)))
                }
            case let .err(text):
                // GUPPY_PP|Merger|started
                let parts = text.components(separatedBy: "|")
                if parts.count >= 3, parts[0] == "GUPPY_PP", parts[2] == "started", parts[1] != "MoveFiles" {
                    return JobProgress(fraction: nil, speed: nil, eta: nil, stage: .processing)
                }
            }
            return nil
        }
    }

    /// filename|downloaded|total|speed|eta (values are "NA" when unknown).
    private func downloadProgress(_ fields: String) -> JobProgress? {
        let parts = fields.components(separatedBy: "|")
        guard parts.count >= 5 else { return nil }
        let count = parts.count
        let name = parts[0..<(count - 4)].joined(separator: "|")
        if !files.contains(name) { files.append(name) }
        guard Date().timeIntervalSince(lastReport) >= minimumInterval else { return nil }
        lastReport = Date()

        let number = { (text: String) in Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil } }
        var fraction: Double?
        if let downloaded = number(parts[count - 4]), let total = number(parts[count - 3]), total > 0 {
            fraction = min(downloaded / total, 1)
        }
        // A video and its audio are downloaded separately ("Title.f137.mp4", "Title.f140.m4a") and then merged.
        // The video is most of the bytes: count it as 85 %, the audio as the rest.
        let isStream = name.range(of: #"\.f[0-9A-Za-z_-]+\.[0-9A-Za-z]+(\.part)?$"#, options: .regularExpression) != nil
        if let value = fraction, isStream {
            fraction = files.count == 1 ? value * 0.85 : 0.85 + value * 0.15
        }
        return JobProgress(fraction: fraction, speed: number(parts[count - 2]), eta: number(parts[count - 1]),
                           stage: .downloading)
    }
}
