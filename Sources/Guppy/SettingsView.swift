import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: GuppyModel

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    HStack {
                        Text((model.folder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: model.chooseFolder)
                    }
                }
                Toggle("Add cover art, title and chapters", isOn: $model.embedMetadata)
            }

            Section("Tools") {
                LabeledContent("yt-dlp") {
                    HStack {
                        Text(model.isCheckingTools ? "Looking…" : model.tools?.ytdlp?.version ?? "Not installed")
                            .foregroundStyle(.secondary)
                            .help(model.tools?.ytdlp?.url.path ?? "")
                        Button(model.tools?.ytdlp == nil ? "Install" : "Update",
                               action: model.tools?.ytdlp == nil ? model.installTools : model.updateYTDLP)
                            .disabled(!model.canUpdateTools)
                    }
                }
                LabeledContent("FFmpeg") {
                    HStack {
                        Text(model.isCheckingTools ? "Looking…" : model.tools?.ffmpeg.map { shortVersion($0.version) } ?? "Not installed")
                            .foregroundStyle(.secondary)
                            .help(model.tools?.ffmpeg?.url.path ?? "")
                        if model.tools?.ffmpeg == nil {
                            Button("Install", action: model.installTools).disabled(!model.canUpdateTools)
                        }
                    }
                }
                if let install = model.toolInstall {
                    LabeledContent("Downloading \(install.tool)…") {
                        ProgressView(value: install.fraction).frame(width: 160)
                    }
                }
                if let error = model.toolError {
                    Text(error).font(.caption).foregroundStyle(Color.guppyRed)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Guppy uses the newest yt-dlp it finds on this Mac (Homebrew, pip) or keeps its own copy. YouTube changes often; when downloads start failing, updating yt-dlp usually fixes it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Folder", action: model.revealToolsFolder).controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                GuppyLogo().frame(width: 16, height: 16)
                Text("Guppy 1.0 · Downloads with yt-dlp, converts with FFmpeg. Only download what you have the right to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(.guppyOrange)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "N-122320-g38e89fe502" → "N-122320"; release builds ("9.0.2") stay as they are.
    private func shortVersion(_ version: String) -> String {
        version.split(separator: "-").prefix(2).joined(separator: "-")
    }
}
