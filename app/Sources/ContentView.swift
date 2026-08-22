import SwiftUI
import AppKit
import AVKit
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

    enum SilenceStatus: Equatable {
        case notChecked
        /// progress 為 nil 表示還不知道檔案總長（duration 尚未探測完），只能顯示不確定的轉圈圈。
        case detecting(progress: Double?)
        case detected([SilenceRange])
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var status: ProbeStatus = .loading
    var silenceStatus: SilenceStatus = .notChecked
    var selectedSilenceIDs: Set<UUID> = []

    var probedDuration: Double? {
        if case .loaded(let info) = status { return info.durationSeconds }
        return nil
    }

    var probedStreamInfo: StreamInfo? {
        if case .loaded(let info) = status { return info }
        return nil
    }
}

struct ContentView: View {
    @State private var entries: [FileEntry] = []
    @State private var state: MergeState = .idle
    @State private var isImporting = false
    @State private var mergeStartDate: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var previewTarget: SilencePreviewTarget?
    @State private var silenceProgressBoxes: [FileEntry.ID: SilenceDetectionProgress] = [:]
    @State private var removalState: MergeState = .idle
    @State private var removalProgressBox: RemovalProgress?

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

                        silenceSection(for: entry)
                    }
                }
            }
            .frame(minHeight: 200)
            .overlay {
                if entries.isEmpty {
                    Text("Drop mp4 files here, or click “Add Files” below")
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)

            statusView
            removalStatusView

            HStack {
                Button("Add Files") { isImporting = true }
                Spacer()
                Button("Clear") { entries.removeAll() }
                    .disabled(entries.isEmpty)
                Button("Merge") { performMerge() }
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
        .sheet(item: $previewTarget) { target in
            SilencePreviewView(url: target.url, range: target.range)
        }
        .onReceive(ticker) { _ in
            guard let start = mergeStartDate else { return }
            elapsedSeconds = Int(Date().timeIntervalSince(start))
        }
        .onReceive(ticker) { _ in
            for (id, box) in silenceProgressBoxes {
                let fraction = box.current()
                updateEntry(id: id) { entry in
                    if case .detecting = entry.silenceStatus {
                        entry.silenceStatus = .detecting(progress: fraction)
                    }
                }
            }
        }
        .onReceive(ticker) { _ in
            guard let box = removalProgressBox, case .working = removalState else { return }
            removalState = .working(box.current())
        }
    }

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    private var isRemoving: Bool {
        if case .working = removalState { return true }
        return false
    }

    @ViewBuilder
    private var removalStatusView: some View {
        switch removalState {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack {
                ProgressView().controlSize(.small)
                Text(message)
            }
        case .succeeded(let url):
            Text(L("Silent segments removed — saved to: %@", url.path))
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
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
            Text(L("Done: %@", url.path))
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
            Text("Reading format…")
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
            parts.append(String(localized: "No audio"))
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

    @ViewBuilder
    private func silenceSection(for entry: FileEntry) -> some View {
        switch entry.silenceStatus {
        case .notChecked:
            Button("Detect Silence") { detectSilenceEntry(id: entry.id, url: entry.url, duration: entry.probedDuration) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
        case .detecting(let progress):
            if let progress {
                HStack(spacing: 4) {
                    ProgressView(value: progress).frame(maxWidth: 160)
                    Text(L("Detecting silence…%@%%", "\(Int(progress * 100))"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Detecting silence…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .detected(let ranges):
            if ranges.isEmpty {
                Text("No mid-clip silence detected (leading/trailing silence ignored)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Detected %@ silent range(s) (leading/trailing ignored). Check the ones to remove:", "\(ranges.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ranges) { range in
                        HStack(spacing: 4) {
                            Toggle(isOn: silenceToggleBinding(entryID: entry.id, rangeID: range.id)) {
                                Text(L("%@ – %@ (%@s)", durationText(range.start), durationText(range.end), String(format: "%.1f", range.duration)))
                            }
                            .toggleStyle(.checkbox)
                            if range.extendedForDuplicate {
                                Text("Extended: includes frozen frame")
                                    .foregroundStyle(.orange)
                            }
                            Button {
                                previewTarget = SilencePreviewTarget(url: entry.url, range: range)
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                    }
                    if !entry.selectedSilenceIDs.isEmpty {
                        Button("Remove Selected (Save As New File)") { performRemoval(for: entry) }
                            .font(.caption)
                            .disabled(isRemoving)
                    }
                }
            }
        case .failed(let message):
            Text(L("Silence detection failed: %@", message))
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func silenceToggleBinding(entryID: FileEntry.ID, rangeID: UUID) -> Binding<Bool> {
        Binding(
            get: { entries.first(where: { $0.id == entryID })?.selectedSilenceIDs.contains(rangeID) ?? false },
            set: { _ in toggleSilenceSelection(entryID: entryID, rangeID: rangeID) }
        )
    }

    private func toggleSilenceSelection(entryID: FileEntry.ID, rangeID: UUID) {
        updateEntry(id: entryID) { entry in
            if entry.selectedSilenceIDs.contains(rangeID) {
                entry.selectedSilenceIDs.remove(rangeID)
            } else {
                entry.selectedSilenceIDs.insert(rangeID)
            }
        }
    }

    private func detectSilenceEntry(id: FileEntry.ID, url: URL, duration: Double?) {
        let box: SilenceDetectionProgress? = (duration.map { $0 > 0 } ?? false) ? SilenceDetectionProgress() : nil
        if let box { silenceProgressBoxes[id] = box }
        updateEntry(id: id) { $0.silenceStatus = .detecting(progress: box != nil ? 0 : nil) }
        Task {
            do {
                let ranges = try await Task.detached(priority: .utility) {
                    let raw = try FFmpegRunner.detectSilence(url, duration: duration, progress: box)
                    let edgeFiltered = FFmpegRunner.excludingEdges(raw, duration: duration)
                    guard let duration, duration > 0 else { return edgeFiltered }
                    return edgeFiltered.map { FFmpegRunner.extendRangeWithNearbyFreeze($0, in: url, duration: duration) }
                }.value
                silenceProgressBoxes[id] = nil
                updateEntry(id: id) { $0.silenceStatus = .detected(ranges) }
            } catch {
                silenceProgressBoxes[id] = nil
                updateEntry(id: id) { $0.silenceStatus = .failed(error.localizedDescription) }
            }
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
        state = .working(String(localized: "Checking format compatibility…"))
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
                state = .working(String(localized: "Merging…"))
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
        panel.title = String(localized: "Choose Output Location")
        panel.nameFieldStringValue = first.deletingPathExtension().lastPathComponent + "_merged.mp4"
        panel.directoryURL = first.deletingLastPathComponent()
        panel.allowedContentTypes = [.mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func performRemoval(for entry: FileEntry) {
        guard case .detected(let ranges) = entry.silenceStatus else { return }
        let selected = ranges.filter { entry.selectedSilenceIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        guard let streamInfo = entry.probedStreamInfo else { return }
        guard let output = chooseCleanedOutputURL(for: entry.url) else { return }

        let box = RemovalProgress()
        removalProgressBox = box
        removalState = .working(String(localized: "Preparing to remove segments…"))

        let url = entry.url
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FFmpegRunner.removeSilenceRanges(
                        from: url,
                        ranges: selected,
                        streamInfo: streamInfo,
                        output: output,
                        progress: box
                    )
                }.value
                removalProgressBox = nil
                removalState = .succeeded(output)
            } catch {
                removalProgressBox = nil
                removalState = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func chooseCleanedOutputURL(for input: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Choose Output Location")
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + "_cleaned.mp4"
        panel.directoryURL = input.deletingLastPathComponent()
        panel.allowedContentTypes = [.mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

#Preview {
    ContentView()
}

struct SilencePreviewTarget: Identifiable {
    let id = UUID()
    let url: URL
    let range: SilenceRange
}

/// 播放靜音區間前後各留 2 秒的上下文，方便判斷「這段真的是要拿掉的斷線片段」還是正常的安靜場景。
struct SilencePreviewView: View {
    let url: URL
    let range: SilenceRange

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var boundaryToken: Any?

    private static let contextMargin: Double = 2

    var body: some View {
        VStack(spacing: 8) {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: 480, height: 270)
            }
            Text(L("Silent range: %@ – %@ (±2s context)", timeText(range.start), timeText(range.end)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
        }
        .padding()
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: teardownPlayer)
    }

    private func setupPlayer() {
        let newPlayer = AVPlayer(url: url)
        let startTime = CMTime(seconds: max(0, range.start - Self.contextMargin), preferredTimescale: 600)
        let endTime = CMTime(seconds: range.end + Self.contextMargin, preferredTimescale: 600)
        newPlayer.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            newPlayer.play()
        }
        boundaryToken = newPlayer.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) {
            newPlayer.pause()
        }
        player = newPlayer
    }

    private func teardownPlayer() {
        if let token = boundaryToken {
            player?.removeTimeObserver(token)
        }
        player?.pause()
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
