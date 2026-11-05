import XCTest
@testable import Guppy

final class ParsingTests: XCTestCase {
    func testReadsAVideo() throws {
        let json = """
        {"id":"abc","title":"A video","channel":"Someone","duration":61.5,
         "webpage_url":"https://www.youtube.com/watch?v=abc","thumbnail":"https://i.ytimg.com/vi/abc/hq.jpg",
         "formats":[{"vcodec":"none","height":null},{"vcodec":"avc1","height":720},{"vcodec":"vp9","height":1080},
                    {"vcodec":"avc1","height":720}]}
        """
        let info = try YTDLP.parseInfo(Data(json.utf8))
        XCTAssertFalse(info.isPlaylist)
        XCTAssertEqual(info.heights, [1080, 720])
        XCTAssertEqual(info.entries.count, 1)
        XCTAssertEqual(info.entries[0].duration, 61.5)
        XCTAssertEqual(info.thumbnail?.host, "i.ytimg.com")
    }

    func testReadsAPlaylistWithoutPrivateVideos() throws {
        let json = """
        {"_type":"playlist","title":"Mix","entries":[
          {"id":"a","title":"One","url":"https://www.youtube.com/watch?v=a","thumbnails":[{"url":"https://i.ytimg.com/a.jpg"}]},
          {"id":"b","title":"[Private video]","url":"https://www.youtube.com/watch?v=b"}]}
        """
        let info = try YTDLP.parseInfo(Data(json.utf8))
        XCTAssertTrue(info.isPlaylist)
        XCTAssertEqual(info.entries.map(\.title), ["One"])
        XCTAssertEqual(info.thumbnail?.absoluteString, "https://i.ytimg.com/a.jpg")
    }

    func testExplainsFailuresWithoutPrefixes() {
        let failure = YTDLP.failure(from: ["WARNING: x", "ERROR: [youtube] abc: Video unavailable"])
        XCTAssertTrue(failure.message.hasPrefix("Video unavailable"), failure.message)
    }

    func testCountsTheVideoStreamAsMostOfTheDownload() {
        let parser = DownloadOutputParser(minimumInterval: 0)
        let video = parser.handle(.out("GUPPY_DL|/tmp/Clip.f137.mp4|50|100|2000000|3"))
        XCTAssertEqual(video?.fraction ?? 0, 0.425, accuracy: 0.001)
        XCTAssertEqual(video?.speed, 2_000_000)
        let audio = parser.handle(.out("GUPPY_DL|/tmp/Clip.f140.m4a|100|100|NA|NA"))
        XCTAssertEqual(audio?.fraction ?? 0, 1, accuracy: 0.001)
        XCTAssertNil(audio?.eta)
        XCTAssertEqual(parser.handle(.err("GUPPY_PP|Merger|started"))?.stage, .processing)
        XCTAssertNil(parser.handle(.out("GUPPY_FILE|/tmp/Clip.mp4")))
        XCTAssertEqual(parser.savedFile, "/tmp/Clip.mp4")
    }

    func testReadsSingleFileProgress() {
        let parser = DownloadOutputParser(minimumInterval: 0)
        let progress = parser.handle(.out("GUPPY_DL|/tmp/Song.webm|25|100|NA|NA"))
        XCTAssertEqual(progress?.fraction ?? 0, 0.25, accuracy: 0.001)
    }

    func testReadsTheFFmpegDuration() {
        XCTAssertEqual(ConvertOutputParser.duration(in: "  Duration: 00:03:21.50, start: 0.000000, bitrate: 128 kb/s"), 201.5)
        XCTAssertNil(ConvertOutputParser.duration(in: "Stream #0:0: Audio: aac"))
    }

    func testBuildsAudioArguments() {
        let ffmpeg = Tool(url: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), version: "9.0.2")
        let options = DownloadOptions(url: "https://youtu.be/abc", audioOnly: true, maxHeight: nil, container: .mp4,
                                      audioFormat: .mp3, audioBitrate: 192, embedMetadata: true,
                                      folder: URL(fileURLWithPath: "/tmp"))
        let arguments = YTDLP.arguments(for: options, ffmpeg: ffmpeg)
        XCTAssertTrue(arguments.contains("--audio-quality"))
        XCTAssertTrue(arguments.contains("192K"))
        XCTAssertTrue(arguments.contains("--embed-thumbnail"))
        XCTAssertEqual(arguments.last, "https://youtu.be/abc")
    }

    func testBuildsVideoArguments() {
        let ffmpeg = Tool(url: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), version: "9.0.2")
        let options = DownloadOptions(url: "https://youtu.be/abc", audioOnly: false, maxHeight: 1080, container: .webm,
                                      audioFormat: .mp3, audioBitrate: 320, embedMetadata: true,
                                      folder: URL(fileURLWithPath: "/tmp"))
        let arguments = YTDLP.arguments(for: options, ffmpeg: ffmpeg)
        XCTAssertTrue(arguments.contains("res:1080,vcodec:vp9,acodec:opus"))
        // WebM can't hold a cover image.
        XCTAssertFalse(arguments.contains("--embed-thumbnail"))
    }

    func testFindsAFreeFileName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Song.mp3").path, contents: Data())
        XCTAssertEqual(Converter.uniqueURL(in: folder, base: "Song", extension: "mp3").lastPathComponent, "Song 2.mp3")
    }

    @MainActor
    func testRecognizesLinks() {
        XCTAssertEqual(GuppyModel.link(in: "  https://youtu.be/abc \n"), "https://youtu.be/abc")
        XCTAssertNil(GuppyModel.link(in: "not a link"))
        XCTAssertTrue(GuppyModel.isYouTubeLink("https://www.youtube.com/watch?v=abc"))
        XCTAssertFalse(GuppyModel.isYouTubeLink("https://vimeo.com/123"))
    }

    func testFormatsDurations() {
        XCTAssertEqual(formatDuration(754), "12:34")
        XCTAssertEqual(formatDuration(3_725), "1:02:05")
    }
}

/// Downloads a 19-second video with the yt-dlp and FFmpeg on this Mac. Runs only with GUPPY_INTEGRATION=1,
/// since it needs the network (and YouTube often blocks CI machines).
final class IntegrationTests: XCTestCase {
    func testDownloadsAndConvertsWithTheRealTools() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GUPPY_INTEGRATION"] == "1", "Set GUPPY_INTEGRATION=1 to run.")
        let tools = await ToolBox.find()
        let ytdlp = try XCTUnwrap(tools.ytdlp, "yt-dlp not found")
        let ffmpeg = try XCTUnwrap(tools.ffmpeg, "FFmpeg not found")
        let url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

        let info = try await YTDLP.info(tool: ytdlp, url: url)
        XCTAssertEqual(info.title, "Me at the zoo")
        XCTAssertFalse(info.heights.isEmpty)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guppy-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func options(audioOnly: Bool) -> DownloadOptions {
            DownloadOptions(url: url, audioOnly: audioOnly, maxHeight: 360, container: .mp4, audioFormat: .mp3,
                            audioBitrate: 192, embedMetadata: true, folder: folder)
        }
        let audio = try await YTDLP.download(tool: ytdlp, ffmpeg: ffmpeg, options: options(audioOnly: true)) { _ in }
        XCTAssertEqual(audio.pathExtension, "mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let video = try await YTDLP.download(tool: ytdlp, ffmpeg: ffmpeg, options: options(audioOnly: false)) { _ in }
        XCTAssertEqual(video.pathExtension, "mp4")

        let converted = try await Converter.convert(ffmpeg: ffmpeg, options: ConvertOptions(
            source: video, format: .flac, bitrate: 0, folder: folder)) { _ in }
        XCTAssertEqual(converted.pathExtension, "flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.path))
    }
}
