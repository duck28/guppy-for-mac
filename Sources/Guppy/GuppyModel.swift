import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DownloadMode: String, CaseIterable, Identifiable {
    case video, audio

    var id: Self { self }
}

enum JobStatus: Equatable {
    case waiting, running, done, failed, cancelled

    var isActive: Bool { self == .waiting || self == .running }
}

enum JobTask: Equatable {
    case download(DownloadOptions)
    case convert(ConvertOptions)
}

/// A download or conversion in the queue.
struct Job: Identifiable, Equatable {
    let id = UUID()
    let title: String
    /// The channel, or where a converted file came from.
    let subtitle: String?
    let thumbnail: URL?
    /// "MP4 · 1080p", "MP3 · 320 kbps"…
    let formatTitle: String
    let task: JobTask
    var status: JobStatus = .waiting
    var progress: JobProgress?
    /// The saved file, once done.
    var file: URL?
    var error: String?

    var isConversion: Bool {
        if case .convert = task { return true }
        return false
    }
}

struct ToolInstall: Equatable {
    var tool: String
    var fraction: Double
}

/// Video heights offered.
let videoHeights = [2160, 1440, 1080, 720, 480, 360]
let audioBitrates = [320, 256, 192, 128]

func heightTitle(_ height: Int?) -> String {
    guard let height else { return "Best quality" }
    if height >= 2160 { return "4K (2160p)" }
    if height >= 1440 { return "2K (1440p)" }
    return "\(height)p"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}

private func formatSpeed(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000) }
    return "\(max(1, Int((bytesPerSecond / 1000).rounded()))) KB/s"
}

/// The app's state and behavior: the link being looked at, the download queue and the tools.
@MainActor
final class GuppyModel: ObservableObject {
    /// How many downloads and conversions run at the same time.
    private static let parallelJobs = 2

    // MARK: Link
    @Published var link = ""
    @Published private(set) var info: MediaInfo?
    @Published private(set) var isFetching = false
    @Published private(set) var fetchError: String?
    private var fetchTask: Task<Void, Never>?
    private var fetchingLink = ""
    /// The last link taken from the clipboard, so it isn't offered again after it's cleared.
    private var clipboardLink = ""

    // MARK: Queue
    @Published private(set) var jobs: [Job] = []
    private var jobTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Tools
    @Published private(set) var tools: ToolSet?
    @Published private(set) var isCheckingTools = true
    @Published private(set) var toolInstall: ToolInstall?
    @Published private(set) var toolError: String?

    @Published var isDropTargeted = false
    private var activationObserver: NSObjectProtocol?
    /// Set once the user agreed to quit, so they aren't asked twice.
    private var quitApproved = false

    // MARK: Settings
    private let defaults = UserDefaults.standard

    @Published var mode: DownloadMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    /// nil is the best quality there is.
    @Published var maxHeight: Int? { didSet { defaults.set(maxHeight ?? 0, forKey: "maxHeight") } }
    @Published var container: Container { didSet { defaults.set(container.rawValue, forKey: "container") } }
    @Published var audioFormat: AudioFormat { didSet { defaults.set(audioFormat.rawValue, forKey: "audioFormat") } }
    @Published var audioBitrate: Int { didSet { defaults.set(audioBitrate, forKey: "audioBitrate") } }
    @Published var embedMetadata: Bool { didSet { defaults.set(embedMetadata, forKey: "embedMetadata") } }
    @Published var folder: URL { didSet { defaults.set(folder.path, forKey: "folder") } }

    init() {
        let defaults = UserDefaults.standard
        mode = DownloadMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .video
        container = Container(rawValue: defaults.string(forKey: "container") ?? "") ?? .mp4
        audioFormat = AudioFormat(rawValue: defaults.string(forKey: "audioFormat") ?? "") ?? .mp3
        let bitrate = defaults.integer(forKey: "audioBitrate")
        audioBitrate = audioBitrates.contains(bitrate) ? bitrate : 320
        embedMetadata = defaults.object(forKey: "embedMetadata") as? Bool ?? true
        folder = defaults.string(forKey: "folder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Last: as an Optional, maxHeight already starts out as nil, so this assignment goes through its setter.
        let height = defaults.integer(forKey: "maxHeight")
        maxHeight = height > 0 ? height : nil
    }

    // MARK: - Launch

    func launch() {
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
            Task { @MainActor in self?.offerClipboardLink() }
        }
        Task {
            await checkTools()
            offerClipboardLink()
        }
    }

    var canDownload: Bool { tools?.ytdlp != nil && tools?.ffmpeg != nil }

    // MARK: - Tools

    func checkTools() async {
        isCheckingTools = true
        tools = await ToolBox.find()
        isCheckingTools = false
    }

    /// Downloads yt-dlp and FFmpeg into Guppy's folder (only what's missing or outdated).
    func installTools() {
        let current = tools
        runToolInstall {
            if current?.ytdlp == nil || current?.isYTDLPOutdated == true {
                try await ToolBox.installYTDLP(progress: Self.reporter(for: "yt-dlp", model: self))
            }
            if current?.ffmpeg == nil {
                try await ToolBox.installFFmpeg(progress: Self.reporter(for: "FFmpeg", model: self))
            }
        }
    }

    func updateYTDLP() {
        runToolInstall {
            try await ToolBox.installYTDLP(progress: Self.reporter(for: "yt-dlp", model: self))
        }
    }

    /// Whether the tools can be replaced now (not while they run).
    var canUpdateTools: Bool {
        toolInstall == nil && !isFetching && !jobs.contains { $0.status == .running }
    }

    private static func reporter(for tool: String, model: GuppyModel) -> @Sendable (Double) -> Void {
        { [weak model] fraction in
            Task { @MainActor in
                // Ignore reports that arrive after the install finished.
                if let model, model.toolInstall != nil { model.toolInstall = ToolInstall(tool: tool, fraction: fraction) }
            }
        }
    }

    private func runToolInstall(_ install: @escaping () async throws -> Void) {
        guard toolInstall == nil else { return }
        toolInstall = ToolInstall(tool: "tools", fraction: 0)
        toolError = nil
        Task {
            do {
                try await install()
            } catch {
                toolError = error.localizedDescription
            }
            toolInstall = nil
            await checkTools()
        }
    }

    func revealToolsFolder() {
        try? FileManager.default.createDirectory(at: ToolBox.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ToolBox.folder)
    }

    // MARK: - Link

    /// The link in `text`, if it is one (yt-dlp handles many sites besides YouTube).
    static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return trimmed
    }

    static func isYouTubeLink(_ text: String) -> Bool {
        guard let link = link(in: text), let host = URL(string: link)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// Puts a YouTube link from the clipboard into the empty field and looks it up.
    func offerClipboardLink() {
        guard link.trimmingCharacters(in: .whitespaces).isEmpty, info == nil, canDownload,
              let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isYouTubeLink(copied), copied != clipboardLink else { return }
        clipboardLink = copied
        link = copied
        fetch()
    }

    func pasteAndFetch() {
        guard let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !copied.isEmpty else { return }
        clipboardLink = copied
        link = copied
        fetch()
    }

    /// Looks up what's behind the link.
    func fetch() {
        guard let url = Self.link(in: link) else {
            fetchError = link.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "That doesn't look like a link."
            return
        }
        guard !(isFetching && fetchingLink == url), let tool = tools?.ytdlp else { return }
        fetchTask?.cancel()
        fetchingLink = url
        isFetching = true
        fetchError = nil
        info = nil
        fetchTask = Task {
            do {
                let info = try await YTDLP.info(tool: tool, url: url)
                try Task.checkCancellation()
                self.info = info
            } catch is CancellationError {
                return
            } catch {
                fetchError = error.localizedDescription
            }
            isFetching = false
        }
    }

    func clearLink() {
        fetchTask?.cancel()
        fetchTask = nil
        link = ""
        info = nil
        isFetching = false
        fetchError = nil
    }

    /// Video heights to offer for the current video (all of them for playlists).
    var offeredHeights: [Int?] {
        let highest = info?.heights.first
        return [nil] + videoHeights.filter { highest == nil || $0 <= highest! }
    }

    var formatTitle: String {
        if mode == .video { return "\(container.title) · \(maxHeight == nil ? "Best" : heightTitle(maxHeight))" }
        return audioFormatTitle
    }

    private var audioFormatTitle: String {
        let name = audioFormat.rawValue.uppercased()
        return audioFormat.isLossless ? "\(name) · Lossless" : "\(name) · \(audioBitrate) kbps"
    }

    // MARK: - Queue

    /// Adds the video (or every video of the playlist) to the queue with the chosen format.
    func download() {
        guard let info, canDownload else { return }
        for entry in info.entries {
            let options = DownloadOptions(url: entry.url, audioOnly: mode == .audio, maxHeight: maxHeight,
                                          container: container, audioFormat: audioFormat, audioBitrate: audioBitrate,
                                          embedMetadata: embedMetadata, folder: folder)
            jobs.insert(Job(title: entry.title, subtitle: entry.channel, thumbnail: entry.thumbnail,
                            formatTitle: formatTitle, task: .download(options)), at: 0)
        }
        clearLink()
        pump()
    }

    /// Converts audio or video files on this Mac to the chosen audio format.
    func convertFiles(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL && Converter.mediaExtensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty, tools?.ffmpeg != nil else {
            if !urls.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Guppy can't convert this file."
                alert.informativeText = "Drop audio or video files, such as MP3, M4A, WAV, FLAC, MP4, MOV or MKV."
                alert.runModal()
            }
            return
        }
        for file in files {
            let options = ConvertOptions(source: file, format: audioFormat, bitrate: audioBitrate, folder: folder)
            jobs.insert(Job(title: file.deletingPathExtension().lastPathComponent,
                            subtitle: "Converted from \(file.pathExtension.uppercased())", thumbnail: nil,
                            formatTitle: audioFormatTitle, task: .convert(options)), at: 0)
        }
        pump()
    }

    func chooseFilesToConvert() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        panel.prompt = "Convert"
        panel.message = "Choose audio or video files to convert to \(audioFormat.title)."
        if panel.runModal() == .OK { convertFiles(panel.urls) }
    }

    /// Starts waiting jobs, oldest first, while fewer than `parallelJobs` run.
    private func pump() {
        let running = jobs.filter { $0.status == .running }.count
        let waiting = jobs.filter { $0.status == .waiting }.reversed()
        for job in waiting.prefix(max(0, Self.parallelJobs - running)) {
            start(job.id)
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func start(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), let tools else { return }
        update(id) {
            $0.status = .running
            $0.progress = nil
            $0.error = nil
        }
        let report: @Sendable (JobProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.update(id) { if $0.status == .running { $0.progress = progress } }
            }
        }
        jobTasks[id] = Task {
            do {
                guard let ffmpeg = tools.ffmpeg else { throw YTDLP.Failure(message: "Guppy needs FFmpeg. Set it up in Settings.") }
                let file: URL
                switch job.task {
                case let .download(options):
                    guard let ytdlp = tools.ytdlp else { throw YTDLP.Failure(message: "Guppy needs yt-dlp. Set it up in Settings.") }
                    file = try await YTDLP.download(tool: ytdlp, ffmpeg: ffmpeg, options: options, progress: report)
                case let .convert(options):
                    file = try await Converter.convert(ffmpeg: ffmpeg, options: options, progress: report)
                }
                update(id) {
                    $0.status = .done
                    $0.file = file
                }
            } catch is CancellationError {
                update(id) { $0.status = .cancelled }
            } catch {
                update(id) {
                    $0.status = .failed
                    $0.error = error.localizedDescription
                }
            }
            update(id) { $0.progress = nil }
            jobTasks[id] = nil
            pump()
        }
    }

    func cancel(_ job: Job) {
        if job.status == .running {
            jobTasks[job.id]?.cancel()
        } else if job.status == .waiting {
            update(job.id) { $0.status = .cancelled }
        }
    }

    func retry(_ job: Job) {
        update(job.id) {
            $0.status = .waiting
            $0.error = nil
            $0.file = nil
        }
        pump()
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
    }

    var activeJobCount: Int { jobs.filter { $0.status.isActive }.count }

    var hasFinishedJobs: Bool { jobs.contains { !$0.status.isActive } }

    func clearFinished() {
        jobs.removeAll { !$0.status.isActive }
    }

    /// The line under a job's title.
    func statusText(_ job: Job) -> String {
        switch job.status {
        case .waiting: return "Waiting"
        case .cancelled: return "Cancelled"
        case .failed: return job.error ?? "Failed"
        case .done: return job.file?.lastPathComponent ?? "Done"
        case .running:
            guard let progress = job.progress else { return job.isConversion ? "Converting…" : "Starting…" }
            if progress.stage == .processing { return "Finishing…" }
            let parts = [progress.fraction.map { "\(Int(($0 * 100).rounded())) %" },
                         progress.speed.map(formatSpeed),
                         progress.eta.flatMap { $0 > 0 ? "\(formatDuration($0)) left" : nil }].compactMap { $0 }
            return parts.isEmpty ? (progress.stage == .converting ? "Converting…" : "Downloading…")
                                 : parts.joined(separator: " · ")
        }
    }

    func reveal(_ job: Job) {
        if let file = job.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    func open(_ job: Job) {
        if let file = job.file { NSWorkspace.shared.open(file) }
    }

    func openFolder() {
        NSWorkspace.shared.open(folder)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    // MARK: - Quitting

    /// Closing the window quits Guppy, so ask the same question.
    func windowShouldClose(_ window: NSWindow) -> Bool {
        confirmQuit()
    }

    /// Asks before quitting while something is downloading; stops it if the answer is yes.
    func confirmQuit() -> Bool {
        let active = activeJobCount
        guard active > 0, !quitApproved else { return true }
        let alert = NSAlert()
        alert.messageText = active == 1 ? "A download isn't finished yet." : "\(active) downloads aren't finished yet."
        alert.informativeText = "If you quit now, they stop and you'll have to start them again."
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        quitApproved = true
        // Cancelling ends yt-dlp and FFmpeg right away.
        jobTasks.values.forEach { $0.cancel() }
        return true
    }
}
