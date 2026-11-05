import Foundation

struct ConvertOptions: Equatable, Sendable {
    var source: URL
    var format: AudioFormat
    /// kbps, for the lossy formats.
    var bitrate: Int
    var folder: URL
}

/// Converts audio and video files on this Mac to an audio format with FFmpeg.
enum Converter {
    static let mediaExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "wma", "aif",
                                               "aiff", "caf", "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv"]

    /// A file in `folder` named `base` that doesn't exist yet ("base 2.ext" and so on).
    static func uniqueURL(in folder: URL, base: String, extension pathExtension: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(pathExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).\(pathExtension)")
            number += 1
        }
        return url
    }

    static func codecArguments(for format: AudioFormat, bitrate: Int) -> [String] {
        switch format {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case .m4a: return ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case .opus: return ["-c:a", "libopus", "-b:a", "\(bitrate)k"]
        case .flac: return ["-c:a", "flac"]
        case .wav: return ["-c:a", "pcm_s16le"]
        }
    }

    /// Converts the file. `progress` is called on a background thread. Returns the new file.
    static func convert(ffmpeg: Tool, options: ConvertOptions,
                        progress: @escaping @Sendable (JobProgress) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
        let target = uniqueURL(in: options.folder, base: options.source.deletingPathExtension().lastPathComponent,
                               extension: options.format.rawValue)
        let parser = ConvertOutputParser()
        let arguments = ["-hide_banner", "-nostdin", "-y", "-i", options.source.path, "-vn", "-map_metadata", "0"]
            + codecArguments(for: options.format, bitrate: options.bitrate)
            + ["-progress", "pipe:1", "-nostats", target.path]
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(ffmpeg.url, arguments) { line in
                if let report = parser.handle(line) { progress(report) }
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: target)
            let message = result.errors.last?.trimmingCharacters(in: .whitespaces) ?? "it stopped unexpectedly."
            throw YTDLP.Failure(message: "FFmpeg couldn't convert \(options.source.lastPathComponent): \(message)")
        }
        return target
    }
}

/// Reads the duration FFmpeg prints and its `-progress` output.
final class ConvertOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: TimeInterval?

    func handle(_ line: OutputLine) -> JobProgress? {
        lock.withLock { () -> JobProgress? in
            switch line {
            case let .err(text):
                if duration == nil { duration = Self.duration(in: text) }
            case let .out(text):
                // -progress writes key=value lines; out_time_us is the position in microseconds.
                guard text.hasPrefix("out_time_us="), let duration, duration > 0,
                      let microseconds = Double(text.dropFirst("out_time_us=".count)) else { return nil }
                let fraction = min(max(microseconds / 1_000_000 / duration, 0), 1)
                return JobProgress(fraction: fraction, speed: nil, eta: nil, stage: .converting)
            }
            return nil
        }
    }

    /// "  Duration: 00:03:21.45, start: …" → 201.45
    static func duration(in line: String) -> TimeInterval? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Duration:"),
              let time = trimmed.dropFirst("Duration:".count).split(separator: ",").first else { return nil }
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
