import AppKit
import SwiftUI

@MainActor
final class ExportController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case exporting
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    private var exporter: Exporter?

    func start(model: EditorModel, options: ExportOptions) {
        guard let media = model.media, phase != .exporting else { return }
        let url = Self.destination(name: model.project.name, options: options)
        let exporter = Exporter()
        self.exporter = exporter
        phase = .exporting
        progress = 0
        let state = model.state
        let info = model.info
        model.pause()

        Task {
            do {
                try await exporter.export(media: media, info: info, state: state, options: options, to: url) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                phase = .finished(url)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                phase = .idle
            } catch {
                try? FileManager.default.removeItem(at: url)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        exporter?.cancel()
    }

    func reset() {
        phase = .idle
        progress = 0
    }

    private static func destination(name: String, options: ExportOptions) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let base = "\(name) \(options.resolution.title)"
        let ext = options.format.fileExtension
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return url
    }
}

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @StateObject private var controller = ExportController()
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.format") private var format: ExportFormat = .mp4
    @AppStorage("export.resolution") private var resolution: ExportResolution = .p1080
    @AppStorage("export.fps") private var fps = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Export")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }

            Group {
                row("Format") {
                    Picker("", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                }
                row("Resolution") {
                    Picker("", selection: $resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                    }
                }
                row("Frame rate") {
                    if format == .mp4 {
                        Picker("", selection: $fps) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                    } else {
                        Text("GIFs export at \(ExportOptions.gifFPS) fps without sound")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .disabled(controller.phase == .exporting)

            statusView

            HStack(spacing: 10) {
                Spacer()
                switch controller.phase {
                case .idle, .failed:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export to Downloads") {
                        controller.start(model: model, options: ExportOptions(format: format, resolution: resolution, fps: Int32(fps)))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.media == nil)
                case .exporting:
                    Button("Stop") { controller.cancel() }
                        .keyboardShortcut(.cancelAction)
                case .finished(let url):
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Copy to Clipboard") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([url as NSURL])
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .preferredColorScheme(.dark)
    }

    private var summary: String {
        let size = model.state.canvasSize(shortSide: Double(resolution.rawValue), sourceSize: model.sourceSize)
        return "\(Int(size.width)) × \(Int(size.height)) · \(formatShortDuration(model.duration))"
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .exporting:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: controller.progress)
                    .tint(Theme.accent)
                Text("Exporting… \(Int(controller.progress * 100))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        case .finished(let url):
            Label("Saved \(url.lastPathComponent) to Downloads", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.green)
                .lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 90, alignment: .leading)
            content()
                .pickerStyle(.segmented)
                .labelsHidden()
        }
    }
}
