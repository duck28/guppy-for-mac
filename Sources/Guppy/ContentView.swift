import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: GuppyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolsNotice()
            LinkField()
            if let error = model.fetchError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.guppyRed)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
            if model.isFetching { PreviewSkeleton() }
            if let info = model.info { PreviewCard(info: info) }
            if !model.jobs.isEmpty {
                QueueView()
            } else if model.info == nil && !model.isFetching {
                EmptyState()
            }
        }
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 600, minHeight: 480)
        .background(Color.white)
        .foregroundStyle(Color.guppyLabel)
        .tint(.guppyOrange)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.info)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isFetching)
        .overlay { if model.isDropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            model.convertFiles(urls)
            return true
        } isTargeted: { model.isDropTargeted = $0 && model.tools?.ffmpeg != nil }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    GuppyLogo().frame(width: 22, height: 22)
                    Text("Guppy").font(.system(size: 14, weight: .bold))
                }
                .padding(.horizontal, 4)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .modifier(HidesWindowTitle())
        .toolbarBackground(Color.white, for: .windowToolbar)
        .background(WindowCloseGuard(shouldClose: model.windowShouldClose))
    }
}

/// Hides the window title next to the logo; removing toolbar items by kind needs macOS 15.
private struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

// MARK: - Tools

private struct ToolsNotice: View {
    @EnvironmentObject private var model: GuppyModel

    var body: some View {
        if let install = model.toolInstall {
            notice(icon: "arrow.down.circle") {
                Text(verbatim: "Downloading \(install.tool)… \(Int(install.fraction * 100)) %")
                GuppyProgressBar(value: install.fraction)
            } action: { EmptyView() }
        } else if let tools = model.tools, !tools.missing.isEmpty {
            notice(icon: "wrench.and.screwdriver") {
                Text("One-time setup").fontWeight(.semibold)
                Text("Guppy downloads with yt-dlp and converts with FFmpeg. It can get \(tools.missing.joined(separator: " and ")) for you and keep \(tools.missing.count > 1 ? "them" : "it") in its own folder (about \(tools.ffmpeg == nil ? "70" : "40") MB). If you use Homebrew, “brew install yt-dlp ffmpeg” works too.")
                    .foregroundStyle(Color.guppySecondary)
                if let error = model.toolError { Text(error).foregroundStyle(Color.guppyRed) }
            } action: {
                Button("Set Up", action: model.installTools).buttonStyle(GuppyButtonStyle(prominent: true))
            }
        } else if let tools = model.tools, tools.isYTDLPOutdated {
            notice(icon: "exclamationmark.circle") {
                Text("yt-dlp \(tools.ytdlp?.version ?? "") is out of date, and YouTube regularly breaks older versions.")
                if let error = model.toolError { Text(error).foregroundStyle(Color.guppyRed) }
            } action: {
                Button("Update", action: model.updateYTDLP)
                    .buttonStyle(GuppyButtonStyle())
                    .disabled(!model.canUpdateTools)
            }
        }
    }

    private func notice<Content: View, Action: View>(icon: String, @ViewBuilder content: () -> Content,
                                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.guppyOrange)
            VStack(alignment: .leading, spacing: 4) { content() }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.guppySoft))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.guppyOrange.opacity(0.22)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Link

private struct LinkField: View {
    @EnvironmentObject private var model: GuppyModel
    @FocusState private var isFocused: Bool

    private var hasText: Bool { !model.link.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.guppyOrange)
            TextField("Paste a YouTube link", text: $model.link)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit(model.fetch)
            if hasText && !model.isFetching {
                Button(action: model.clearLink) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .help("Clear")
            }
            if hasText {
                Button(action: model.fetch) {
                    if model.isFetching {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("Go")
                    }
                }
                .buttonStyle(GuppyButtonStyle(prominent: true))
                .frame(minWidth: 64)
                .disabled(model.isFetching)
            } else {
                Button(action: model.pasteAndFetch) { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(GuppyButtonStyle())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
        .background(shape.fill(model.canDownload ? Color.white : Color.guppySurface))
        .overlay(shape.strokeBorder(isFocused ? Color.guppyOrange : Color.guppyBorder, lineWidth: 1.5))
        .background(shape.stroke(Color.guppyOrange.opacity(isFocused ? 0.25 : 0), lineWidth: 8))
        .shadow(color: Color.guppyShadow.opacity(0.06), radius: 8, y: 3)
        .disabled(!model.canDownload)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // Look a link up right away when it's pasted into the empty field.
        .onChange(of: model.link) { old, new in
            if old.isEmpty, GuppyModel.link(in: new) != nil { model.fetch() }
        }
        .onChange(of: model.canDownload) { _, canDownload in if canDownload { isFocused = true } }
        .onAppear { isFocused = model.canDownload }
    }
}

// MARK: - Preview

private struct Thumbnail: View {
    let url: URL?
    let symbol: String
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            Color.guppySoft
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.guppyOrange)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct PreviewSkeleton: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10).frame(width: 160, height: 90)
            VStack(alignment: .leading, spacing: 10) {
                Capsule().frame(width: 260, height: 12)
                Capsule().frame(width: 150, height: 12)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.guppySoft)
        .opacity(pulse ? 0.55 : 1)
        .padding(14)
        .card()
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
        .accessibilityLabel("Loading")
    }
}

private struct PreviewCard: View {
    @EnvironmentObject private var model: GuppyModel
    let info: MediaInfo

    private var details: String {
        let duration = info.isPlaylist ? nil : info.entries.first?.duration.map(formatDuration)
        return [info.channel, info.isPlaylist ? "Playlist · \(info.entries.count) videos" : nil, duration]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Thumbnail(url: info.thumbnail, symbol: "film").frame(width: 160, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(details).foregroundStyle(Color.guppySecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            Rectangle().fill(Color.guppySeparator).frame(height: 1)

            HStack(spacing: 10) {
                ModeSwitch(mode: $model.mode)
                if model.mode == .video {
                    Picker("Quality", selection: $model.maxHeight) {
                        ForEach(model.offeredHeights, id: \.self) { Text(heightTitle($0)).tag($0) }
                    }
                    .fixedSize()
                    Picker("Format", selection: $model.container) {
                        ForEach(Container.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                } else {
                    Picker("Format", selection: $model.audioFormat) {
                        ForEach(AudioFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    if model.audioFormat.isLossless {
                        Text("Lossless")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.guppyOrangeStrong)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.guppySoft))
                    } else {
                        Picker("Quality", selection: $model.audioBitrate) {
                            ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                        }
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
                Button(action: model.download) {
                    Label(info.isPlaylist ? "Download \(info.entries.count)" : "Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(GuppyButtonStyle(prominent: true, large: true))
                .disabled(!model.canDownload)
            }
            .pickerStyle(.menu)
            .padding(12)
            .background(Color.guppySurface)
        }
        .card()
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Video or Audio, with the selection in orange.
private struct ModeSwitch: View {
    @Binding var mode: DownloadMode
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            segment(.video, title: "Video", icon: "film")
            segment(.audio, title: "Audio", icon: "music.note")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.guppyOrange.opacity(0.12)))
    }

    private func segment(_ value: DownloadMode, title: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = value }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(mode == value ? Color.guppyOrangeStrong : Color.guppySecondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    if mode == value {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: Color.guppyShadow.opacity(0.14), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}

// MARK: - Queue

private struct QueueView: View {
    @EnvironmentObject private var model: GuppyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                if model.activeJobCount > 0 {
                    Text("\(model.activeJobCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Color.guppyOrange))
                        .padding(.leading, 4)
                }
                Spacer()
                Button(action: model.openFolder) { Label(model.folder.lastPathComponent, systemImage: "folder") }
                    .buttonStyle(QuietButtonStyle())
                    .help(model.folder.path)
                if model.hasFinishedJobs {
                    Button(action: model.clearFinished) { Label("Clear finished", systemImage: "trash") }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, 2)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                        if job.id != model.jobs.last?.id {
                            Rectangle().fill(Color.guppySeparator).frame(height: 1).padding(.horizontal, 10)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct JobRow: View {
    @EnvironmentObject private var model: GuppyModel
    let job: Job
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: job.thumbnail, symbol: job.isConversion ? "waveform" : "film", cornerRadius: 7)
                .frame(width: 72, height: 40)
                .saturation(job.status == .failed || job.status == .cancelled ? 0 : 1)
                .opacity(job.status == .failed || job.status == .cancelled ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                    Text(job.formatTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.guppyOrangeStrong)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.guppySoft))
                        .fixedSize()
                }
                HStack(spacing: 4) {
                    if job.status == .done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.guppyGreen)
                    }
                    Text(model.statusText(job))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(job.status == .failed ? Color.guppyRed : Color.guppySecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.statusText(job))
                }
                if job.status == .running {
                    GuppyProgressBar(value: job.progress?.fraction).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                if job.status.isActive {
                    action("Cancel", "xmark") { model.cancel(job) }
                }
                if job.status == .done {
                    action("Play", "play.fill") { model.open(job) }
                    action("Show in Finder", "folder") { model.reveal(job) }
                }
                if job.status == .failed || job.status == .cancelled {
                    action("Try Again", "arrow.clockwise") { model.retry(job) }
                }
                if !job.status.isActive {
                    action("Remove from List", "trash") { model.remove(job) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovered ? Color.guppySurface : .clear))
        .onHover { isHovered = $0 }
        .contextMenu {
            if job.status == .done {
                Button("Play") { model.open(job) }
                Button("Show in Finder") { model.reveal(job) }
            }
            if !job.status.isActive {
                Button("Remove from List") { model.remove(job) }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func action(_ title: String, _ icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: icon) }
            .buttonStyle(IconButtonStyle())
            .help(title)
            .accessibilityLabel(title)
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    @EnvironmentObject private var model: GuppyModel
    @State private var swims = false

    var body: some View {
        VStack(spacing: 6) {
            GuppyLogo()
                .frame(width: 112, height: 112)
                .offset(x: swims ? 6 : 0, y: swims ? -4 : 0)
                .rotationEffect(.degrees(swims ? -2 : 0))
                .padding(.bottom, 8)
                .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever()) { swims = true } }
            Text("Paste a link to get started")
                .font(.system(size: 18, weight: .bold))
            Text("Download YouTube videos in up to 4K, or just their audio as MP3, M4A, Opus, FLAC or WAV.")
                .foregroundStyle(Color.guppySecondary)
                .frame(maxWidth: 380)
            HStack(spacing: 4) {
                Text("Converting a file? Drop it here, or").foregroundStyle(Color.guppySecondary)
                Button("choose files", action: model.chooseFilesToConvert)
                    .buttonStyle(.link)
                    .foregroundStyle(Color.guppyOrangeStrong)
                    .disabled(model.tools?.ffmpeg == nil)
            }
            .font(.system(size: 12))
            .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 56)
    }
}

private struct DropHighlight: View {
    @EnvironmentObject private var model: GuppyModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.guppySoft.opacity(0.85))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.guppyOrange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            Label("Drop to convert to \(model.audioFormat.rawValue.uppercased())", systemImage: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.guppyOrange))
                .shadow(color: Color.guppyShadow.opacity(0.2), radius: 12, y: 6)
        }
        .padding(8)
        .allowsHitTesting(false)
    }
}
