import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MergeState: Equatable {
    case idle
    case working(String)
    case succeeded(URL)
    case failed(String)
}

struct FileEntry: Identifiable {
    enum ProbeStatus: Equatable {
        case loading
        case loaded(StreamInfo)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var status: ProbeStatus = .loading
}

struct ContentView: View {
    @State private var entries: [FileEntry] = []
    @State private var state: MergeState = .idle
    @State private var isImporting = false
    @State private var mergeStartDate: Date?
    @State private var elapsedSeconds: Int = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            List {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                            Text(entry.url.lastPathComponent)
                            Spacer()
                            Button {
                                moveUp(index)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)
                            Button {
                                moveDown(index)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == entries.count - 1)
                            Button(role: .destructive) {
                                entries.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .buttonStyle(.plain)

                        formatSummary(for: entry.status)
                            .font(.caption)
                    }
                }
            }
            .frame(minHeight: 200)
            .overlay {
                if entries.isEmpty {
                    Text("把 mp4 檔案拖曳到這裡，或按下方「加入檔案」")
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)

            statusView

            HStack {
                Button("加入檔案") { isImporting = true }
                Spacer()
                Button("清空") { entries.removeAll() }
                    .disabled(entries.isEmpty)
                Button("合併") { performMerge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entries.count < 2 || isWorking)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                addFiles(urls)
            }
        }
        .onReceive(ticker) { _ in
            guard let start = mergeStartDate else { return }
            elapsedSeconds = Int(Date().timeIntervalSince(start))
        }
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack {
                ProgressView().controlSize(.small)
                Text(message)
                if mergeStartDate != nil {
                    Text(elapsedText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        case .succeeded(let url):
            Text("完成：\(url.path)")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private func formatSummary(for status: FileEntry.ProbeStatus) -> some View {
        switch status {
        case .loading:
            Text("讀取格式中…")
                .foregroundStyle(.secondary)
        case .loaded(let info):
            Text(summary(for: info))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private func summary(for info: StreamInfo) -> String {
        var parts: [String] = []
        if let duration = info.durationSeconds {
            parts.append(durationText(duration))
        }
        parts.append("\(info.width)×\(info.height)")
        parts.append(codecName(info.videoCodec))
        parts.append(frameRateText(info.frameRate))
        if let audioCodec = info.audioCodec {
            var audio = codecName(audioCodec)
            if let rate = info.sampleRate { audio += " \(sampleRateText(rate))" }
            if let channels = info.channels { audio += " \(channelText(channels))" }
            parts.append(audio)
        } else {
            parts.append("無音訊")
        }
        return parts.joined(separator: " · ")
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func codecName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "aac": return "AAC"
        case "ac3": return "AC3"
        case "mp3": return "MP3"
        case "alac": return "ALAC"
        case "prores": return "ProRes"
        default: return raw.uppercased()
        }
    }

    private func frameRateText(_ raw: String) -> String {
        let parts = raw.split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 else {
            return raw
        }
        return String(format: "%.2ffps", num / den)
    }

    private func sampleRateText(_ raw: String) -> String {
        guard let hz = Int(raw) else { return raw }
        return String(format: "%.1fkHz", Double(hz) / 1000)
    }

    private func channelText(_ channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        default: return "\(channels)ch"
        }
    }

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        entries.swapAt(index, index - 1)
    }

    private func moveDown(_ index: Int) {
        guard index < entries.count - 1 else { return }
        entries.swapAt(index, index + 1)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    addFiles([url])
                }
            }
        }
        return true
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let entry = FileEntry(url: url)
            entries.append(entry)
            probeEntry(id: entry.id, url: url)
        }
    }

    private func probeEntry(id: FileEntry.ID, url: URL) {
        Task {
            do {
                let info = try await Task.detached(priority: .utility) {
                    try FFmpegRunner.probe(url)
                }.value
                updateEntry(id: id) { $0.status = .loaded(info) }
            } catch {
                updateEntry(id: id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    private func updateEntry(id: FileEntry.ID, _ mutate: (inout FileEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
    }

    private func performMerge() {
        guard entries.count >= 2 else { return }
        let inputFiles = entries.map(\.url)
        state = .working("檢查格式相容性…")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FFmpegRunner.checkCompatible(inputFiles)
                }.value

                guard let output = chooseOutputURL(for: inputFiles) else {
                    state = .idle
                    return
                }

                mergeStartDate = Date()
                elapsedSeconds = 0
                state = .working("合併中…")
                try await Task.detached(priority: .userInitiated) {
                    try FFmpegRunner.merge(files: inputFiles, output: output)
                }.value

                mergeStartDate = nil
                state = .succeeded(output)
            } catch {
                mergeStartDate = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func chooseOutputURL(for inputFiles: [URL]) -> URL? {
        guard let first = inputFiles.first else { return nil }
        let panel = NSSavePanel()
        panel.title = "選擇輸出位置"
        panel.nameFieldStringValue = first.deletingPathExtension().lastPathComponent + "_merged.mp4"
        panel.directoryURL = first.deletingLastPathComponent()
        panel.allowedContentTypes = [.mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

#Preview {
    ContentView()
}
