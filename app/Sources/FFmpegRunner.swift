import Foundation

struct StreamInfo: Equatable {
    let videoCodec: String
    let width: Int
    let height: Int
    let frameRate: String
    let pixFmt: String
    let videoTimeBase: String?
    let audioCodec: String?
    let sampleRate: String?
    let channels: Int?
    let durationSeconds: Double?

    /// "1/60" 之類的字串，取出分母當作 mp4 muxer 的 -video_track_timescale。
    /// 拿不到就回傳 nil，呼叫端要自己處理「沒有可用 timescale」的情況。
    var videoTimescaleValue: Int? {
        guard let videoTimeBase else { return nil }
        let parts = videoTimeBase.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    // durationSeconds 不列入比較：每個檔案長度本來就會不一樣，不是不相容的判斷依據。
    static func == (lhs: StreamInfo, rhs: StreamInfo) -> Bool {
        lhs.videoCodec == rhs.videoCodec &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.frameRate == rhs.frameRate &&
        lhs.pixFmt == rhs.pixFmt &&
        lhs.videoTimeBase == rhs.videoTimeBase &&
        lhs.audioCodec == rhs.audioCodec &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.channels == rhs.channels
    }
}

struct SilenceRange: Identifiable, Equatable {
    let id = UUID()
    let start: Double
    let end: Double
    /// true 表示這個區間的結尾是被 extendRangeIfDuplicateFollows 延伸過的
    /// （偵測到靜音後面接了一段重播的重複內容，一併框進移除範圍）。
    var extendedForDuplicate: Bool = false
    var duration: Double { end - start }
}

/// 讓背景執行緒（讀 ffmpeg -progress 輸出）跟 UI 執行緒安全地交換一個 0...1 的進度值。
/// 用 lock 保護，不透過 Swift concurrency 的 actor/closure 捕捉，避免 detached task 的 Sendable 檢查牽連到 View。
final class SilenceDetectionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction: Double = 0

    func update(_ value: Double) {
        lock.lock()
        fraction = value
        lock.unlock()
    }

    func current() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return fraction
    }
}

enum FFmpegError: LocalizedError {
    case binaryNotFound(String)
    case probeFailed(String, String)
    case incompatible(String)
    case mergeFailed(String)
    case silenceDetectFailed(String, String)
    case unsupportedCodecForRemoval(String)
    case removalFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            let package = name == "fpcalc" ? "chromaprint" : "ffmpeg"
            return L("Can't find %@. Make sure it's installed via Homebrew (brew install %@).", name, package)
        case .probeFailed(let file, let detail):
            return L("Couldn't read format info for “%@”:\n%@", file, detail)
        case .incompatible(let detail):
            return detail
        case .mergeFailed(let detail):
            return L("Merge failed:\n%@", detail)
        case .silenceDetectFailed(let file, let detail):
            return L("Silence detection failed for “%@”:\n%@", file, detail)
        case .unsupportedCodecForRemoval(let detail):
            return L("Precise cutting currently only supports H.264 video / AAC audio sources: %@", detail)
        case .removalFailed(let detail):
            return L("Failed to remove silent segments:\n%@", detail)
        }
    }
}

/// 讓背景執行緒（跑移除片段的多步驟 ffmpeg 流程）跟 UI 執行緒安全地交換一段文字說明目前進度。
final class RemovalProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String = ""

    func update(_ value: String) {
        lock.lock()
        message = value
        lock.unlock()
    }

    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}

/// 讓 FileHandle.readabilityHandler（背景 GCD queue）安全地把讀到的資料交給呼叫端執行緒讀取。
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 把 readabilityHandler 陸續收到的 chunk 累積起來，切出完整的行；狀態是 mutable var，
/// 一定要包在 lock 後面的 class 裡，不能讓 closure 直接捕捉外面的 var（Swift 6 會擋
/// 「concurrently-executing code 修改同一個變數」）。
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func appendAndExtractLines(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        var lines: [String] = []
        while let range = buffer.range(of: "\n") {
            lines.append(String(buffer[..<range.lowerBound]))
            buffer.removeSubrange(..<range.upperBound)
        }
        return lines
    }
}

enum FFmpegRunner {
    private static let candidateDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func locate(_ name: String) throws -> String {
        for dir in candidateDirs {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw FFmpegError.binaryNotFound(name)
    }

    // 讀 pipe 一定要在 waitUntilExit() 之前，避免子行程 stderr/stdout 塞滿 64KB buffer 卡死。
    private static func runCapturingStderr(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, outData, errData)
    }

    static func probe(_ url: URL) throws -> StreamInfo {
        let ffprobe = try locate("ffprobe")
        let (status, outData, errData) = try runCapturingStderr(ffprobe, [
            "-v", "error",
            "-print_format", "json",
            "-show_entries", "format=duration:stream=codec_name,codec_type,width,height,r_frame_rate,pix_fmt,sample_rate,channels,time_base",
            url.path,
        ])

        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.probeFailed(url.lastPathComponent, msg)
        }

        struct Stream: Decodable {
            let codec_name: String?
            let codec_type: String?
            let width: Int?
            let height: Int?
            let r_frame_rate: String?
            let pix_fmt: String?
            let sample_rate: String?
            let channels: Int?
            let time_base: String?
        }
        struct Format: Decodable { let duration: String? }
        struct Probe: Decodable { let streams: [Stream]; let format: Format? }

        let probe = try JSONDecoder().decode(Probe.self, from: outData)
        guard let video = probe.streams.first(where: { $0.codec_type == "video" }) else {
            throw FFmpegError.probeFailed(url.lastPathComponent, String(localized: "No video track found — check that this is a valid video file"))
        }
        let audio = probe.streams.first(where: { $0.codec_type == "audio" })

        return StreamInfo(
            videoCodec: video.codec_name ?? "",
            width: video.width ?? 0,
            height: video.height ?? 0,
            frameRate: video.r_frame_rate ?? "",
            pixFmt: video.pix_fmt ?? "",
            videoTimeBase: video.time_base,
            audioCodec: audio?.codec_name,
            sampleRate: audio?.sample_rate,
            channels: audio?.channels,
            durationSeconds: probe.format?.duration.flatMap(Double.init)
        )
    }

    /// ffmpeg concat demuxer 的 -c copy 不會驗證輸入格式是否相容，
    /// 格式不合硬跑會產生壞掉的輸出而不是乾淨報錯，所以在呼叫 ffmpeg 之前
    /// 一定要先用 ffprobe 比對過，全部一致才放行。
    @discardableResult
    static func checkCompatible(_ files: [URL]) throws -> [StreamInfo] {
        let infos = try files.map { try probe($0) }
        guard let first = infos.first else { return infos }
        for (index, info) in infos.enumerated() where index > 0 && info != first {
            throw FFmpegError.incompatible(diffDescription(
                first: first, other: info,
                firstName: files[0].lastPathComponent, otherName: files[index].lastPathComponent
            ))
        }
        return infos
    }

    private static func diffDescription(first: StreamInfo, other: StreamInfo, firstName: String, otherName: String) -> String {
        let none = String(localized: "None")
        var diffs: [String] = []
        if first.videoCodec != other.videoCodec { diffs.append(L("Video codec: %@ vs %@", first.videoCodec, other.videoCodec)) }
        if first.width != other.width || first.height != other.height {
            diffs.append(L("Resolution: %@x%@ vs %@x%@", "\(first.width)", "\(first.height)", "\(other.width)", "\(other.height)"))
        }
        if first.frameRate != other.frameRate { diffs.append(L("Frame rate: %@ vs %@", first.frameRate, other.frameRate)) }
        if first.pixFmt != other.pixFmt { diffs.append(L("Pixel format: %@ vs %@", first.pixFmt, other.pixFmt)) }
        if first.videoTimeBase != other.videoTimeBase {
            diffs.append(L(
                "Video timescale: %@ vs %@ (mismatched timescales muxed together via -c copy can overflow the DTS calculation and crash — not just a quality issue)",
                first.videoTimeBase ?? none, other.videoTimeBase ?? none
            ))
        }
        if first.audioCodec != other.audioCodec { diffs.append(L("Audio codec: %@ vs %@", first.audioCodec ?? none, other.audioCodec ?? none)) }
        if first.sampleRate != other.sampleRate { diffs.append(L("Sample rate: %@ vs %@", first.sampleRate ?? none, other.sampleRate ?? none)) }
        if first.channels != other.channels {
            diffs.append(L("Channels: %@ vs %@", first.channels.map(String.init) ?? none, other.channels.map(String.init) ?? none))
        }

        let diffText = diffs.isEmpty ? String(localized: "Formats differ") : diffs.joined(separator: "\n")
        return L(
            "“%@” and “%@” have incompatible formats and can't be losslessly merged:\n%@\n\nWon't re-encode automatically — please check the source files and try again.",
            firstName, otherName, diffText
        )
    }

    /// 用 silencedetect audio filter 掃出靜音區間，純分析、不產生輸出檔案，不會動到原始檔案。
    /// ffmpeg 輸出到 -f null 時分析結果寫在 stderr，格式：
    ///   [silencedetect @ 0x...] silence_start: 12.345
    ///   [silencedetect @ 0x...] silence_end: 15.678 | silence_duration: 3.333
    ///
    /// `-progress pipe:1` 讓 ffmpeg 把處理進度（out_time=HH:MM:SS.ffffff）即時印到 stdout，
    /// 跟 stderr 的 silencedetect 訊息是分開的兩條管線，互不干擾。有給 duration 時才能算出百分比，
    /// 沒有 duration（例如 ffprobe 還沒探測完）就不回報進度，呼叫端會退回顯示不確定的轉圈圈。
    static func detectSilence(
        _ url: URL,
        noiseThresholdDB: Double = -30,
        minDurationSeconds: Double = 1.5,
        duration: Double? = nil,
        progress: SilenceDetectionProgress? = nil
    ) throws -> [SilenceRange] {
        let ffmpeg = try locate("ffmpeg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", url.path,
            "-vn",
            "-progress", "pipe:1",
            "-nostats",
            "-af", "silencedetect=noise=\(noiseThresholdDB)dB:d=\(minDurationSeconds)",
            "-f", "null", "-",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrCollector = DataCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrCollector.append(data) }
        }

        let lineBuffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in lineBuffer.appendAndExtractLines(chunk) {
                guard let duration, duration > 0, line.hasPrefix("out_time=") else { continue }
                if let seconds = parseFFmpegTimestamp(line.dropFirst("out_time=".count)) {
                    progress?.update(min(1, max(0, seconds / duration)))
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let output = String(data: stderrCollector.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw FFmpegError.silenceDetectFailed(url.lastPathComponent, output)
        }
        progress?.update(1)
        return parseSilenceRanges(output)
    }

    private static func parseFFmpegTimestamp(_ text: Substring) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// 排除緊貼檔案開頭／結尾的靜音（開錄前、收工後的正常安靜片段），只留中段的異常靜音，
    /// 例如串流斷線造成的空白。edgeMargin 只判斷「是否貼著頭尾」，跟靜音本身長度無關。
    static func excludingEdges(_ ranges: [SilenceRange], duration: Double?, edgeMargin: Double = 1.0) -> [SilenceRange] {
        guard let duration else { return ranges }
        return ranges.filter { range in
            let touchesStart = range.start <= edgeMargin
            let touchesEnd = range.end >= duration - edgeMargin
            return !touchesStart && !touchesEnd
        }
    }

    /// 串流斷線當下常見的實際狀況（用使用者的實際檔案驗證過）：畫面先凍結，音訊還迴圈播了
    /// 一下子，最後才完全無聲；恢復的瞬間畫面音訊通常同時解凍/回來。純音訊靜音偵測只抓得到
    /// 最後那段「完全無聲」，前面「凍結＋音訊迴圈」那幾秒會漏掉，導致移除範圍偏短、殘留一小段
    /// 沒清乾淨的內容。
    ///
    /// 一開始想用音訊指紋（chromaprint）比對「後面是不是重播前面的內容」去抓這個殘留，
    /// 但實測發現音樂內容本身結構重複（副歌、鼓點）會讓音訊指紋比對誤判，不夠可靠；改用
    /// ffmpeg 內建的 `freezedetect`（直接偵測畫面凍結，不用猜）驗證後跟使用者回報的實際時間點
    /// 完全吻合，簡單可靠很多。
    ///
    /// 只在這段靜音前後一小段時間窗內跑 freezedetect（不是整部影片），避免為了抓凍結去解碼
    /// 一支可能超過半小時的影片全長度。
    static func extendRangeWithNearbyFreeze(
        _ range: SilenceRange,
        in url: URL,
        duration: Double,
        lookbackSeconds: Double = 30,
        lookaheadSeconds: Double = 5,
        noiseThresholdDB: Double = -30,
        minFreezeDurationSeconds: Double = 1
    ) -> SilenceRange {
        do {
            let windowStart = max(0, range.start - lookbackSeconds)
            let windowEnd = min(duration, range.end + lookaheadSeconds)
            let windowDuration = windowEnd - windowStart
            guard windowDuration > 0 else { return range }

            let ffmpeg = try locate("ffmpeg")
            let (status, _, errData) = try runCapturingStderr(ffmpeg, [
                "-ss", String(windowStart),
                "-i", url.path,
                "-t", String(windowDuration),
                "-an",
                "-vf", "freezedetect=n=\(noiseThresholdDB)dB:d=\(minFreezeDurationSeconds)",
                "-f", "null", "-",
            ])
            guard status == 0 else { return range }
            let output = String(data: errData, encoding: .utf8) ?? ""
            let freezes = parseFreezeRanges(output).map { (start: $0.start + windowStart, end: $0.end + windowStart) }

            // 只採用跟這段靜音重疊、或緊接在靜音前後 2 秒內的凍結區間，取聯集延伸範圍；
            // 距離太遠的凍結（例如另一段完全無關的問題）不應該被一起框進來。
            var newStart = range.start
            var newEnd = range.end
            var extended = false
            for freeze in freezes where freeze.start <= range.end + 2 && freeze.end >= range.start - 2 {
                newStart = min(newStart, freeze.start)
                newEnd = max(newEnd, freeze.end)
                extended = true
            }
            guard extended, newStart < newEnd, newStart < range.start || newEnd > range.end else { return range }
            return SilenceRange(start: newStart, end: newEnd, extendedForDuplicate: true)
        } catch {
            return range
        }
    }

    private static func parseFreezeRanges(_ output: String) -> [(start: Double, end: Double)] {
        var ranges: [(start: Double, end: Double)] = []
        var pendingStart: Double?
        for line in output.split(separator: "\n") {
            if let start = value(after: "freeze_start:", in: line) {
                pendingStart = start
            } else if let end = value(after: "freeze_end:", in: line), let start = pendingStart {
                ranges.append((start, end))
                pendingStart = nil
            }
        }
        return ranges
    }

    private static func parseSilenceRanges(_ output: String) -> [SilenceRange] {
        var ranges: [SilenceRange] = []
        var pendingStart: Double?
        for line in output.split(separator: "\n") {
            if let start = value(after: "silence_start:", in: line) {
                pendingStart = start
            } else if let end = value(after: "silence_end:", in: line), let start = pendingStart {
                ranges.append(SilenceRange(start: start, end: end))
                pendingStart = nil
            }
        }
        // 靜音持續到檔案結尾時 ffmpeg 不會印 silence_end，這種未配對的 pendingStart 直接捨棄，
        // 因為沒有明確結束時間就無法安全裁切。
        return ranges
    }

    private static func value(after label: String, in line: Substring) -> Double? {
        guard let range = line.range(of: label) else { return nil }
        let rest = line[range.upperBound...]
        let numberText = rest.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return Double(numberText.trimmingCharacters(in: .whitespaces))
    }

    /// 把選定的靜音區間從影片裡切掉，輸出成新檔案，不動原始檔案。
    ///
    /// 做法：只在每個切點前後重新編碼一小段視訊（貼齊最近的 keyframe），其餘大部分內容維持
    /// stream copy，盡量不動到畫質。演算法：
    ///   1. 依序處理每個（已排序的）靜音區間，游標 cursor 一開始是 0
    ///   2. [cursor, 切點前最近 keyframe] 視訊用 -c copy（這段一定跨好幾個 keyframe，量體最大）
    ///   3. [切點前最近 keyframe, range.start] 視訊重新編碼（通常只有一小段，因為 keyframe 間隔本來就不長）
    ///   4. range.start ~ range.end 之間（靜音本身）整段捨棄，這就是「移除」的實際動作
    ///   5. [range.end, 切點後最近 keyframe] 視訊重新編碼
    ///   6. 游標移到「切點後最近 keyframe」，換下一個區間，最後剩餘的 [cursor, duration] 視訊用 -c copy
    ///
    /// 音訊完全獨立處理，全程 -c:a copy、不重新編碼：每個保留片段各自抽出 raw ADTS，
    /// 最後用位元組直接串接（不透過 mp4 muxer 的 concat）。這是實測過的教訓——即使視訊/音訊
    /// 都只是純 stream copy，讓 concat demuxer／mp4 muxer 處理音訊接點還是可能在真實播放器上
    /// 造成那個接點附近完全沒有聲音（scalefactor bands 解碼錯誤），用 raw ADTS 位元組串接完全
    /// 避開這個問題，因為根本不經過會出錯的那個 mp4 mux 步驟。
    ///
    /// 最後把「接好的視訊」跟「接好的音訊」重新 mux 成一個檔案，才是最終輸出。
    ///
    /// 目前只驗證過 H.264/AAC 這組最常見的攝影機/OBS 錄影格式，其他編碼組合會直接報錯，
    /// 因為重新編碼視訊時要用對應的 encoder（例如 HEVC 來源要用 libx265），還沒補上這個對應表。
    static func removeSilenceRanges(
        from url: URL,
        ranges: [SilenceRange],
        streamInfo: StreamInfo,
        output: URL,
        progress: RemovalProgress? = nil
    ) throws {
        guard streamInfo.videoCodec.lowercased() == "h264" else {
            throw FFmpegError.unsupportedCodecForRemoval(L("Video codec is %@", streamInfo.videoCodec))
        }
        guard let audioCodec = streamInfo.audioCodec, audioCodec.lowercased() == "aac" else {
            throw FFmpegError.unsupportedCodecForRemoval(L("Audio codec is %@", streamInfo.audioCodec ?? String(localized: "None")))
        }
        // 重新編碼的片段一定要跟原始檔案用同一個 video timescale，不然 concat 出來的檔案
        // 整體 timescale 會跑掉（實測發生過：原本 1/60 的來源，切過的輸出變成 1/15360），
        // 這種檔案再拿去跟其他正常檔案合併時，ffmpeg mux 階段算 DTS 會溢位直接崩潰
        // （EXC: Assertion next_dts <= 2147483647 failed at libavformat/movenc.c）。
        guard let videoTimescale = streamInfo.videoTimescaleValue else {
            throw FFmpegError.removalFailed(String(localized: "Couldn't read the source file's video timescale. Stopping rather than risk producing a file with a mismatched timescale (which can crash ffmpeg when merging)."))
        }
        guard let duration = streamInfo.durationSeconds, duration > 0 else {
            throw FFmpegError.removalFailed(String(localized: "Couldn't determine file duration"))
        }
        guard !ranges.isEmpty else {
            throw FFmpegError.removalFailed(String(localized: "No segments selected for removal"))
        }

        let sortedRanges = ranges.sorted { $0.start < $1.start }

        progress?.update(String(localized: "Reading keyframe positions…"))
        let keyframes = try keyframeTimestamps(url)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("videomerger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var videoPieces: [URL] = []
        var audioPieces: [URL] = []
        var pieceIndex = 0

        func addKeptSegment(from: Double, to: Double, reencodeVideo: Bool) throws {
            pieceIndex += 1
            let videoPiece = tempDir.appendingPathComponent("video_\(pieceIndex).mp4")
            let audioPiece = tempDir.appendingPathComponent("audio_\(pieceIndex).aac")
            if reencodeVideo {
                try reencodeVideoOnly(url, from: from, to: to, streamInfo: streamInfo, videoTimescale: videoTimescale, output: videoPiece)
            } else {
                try copyVideoOnly(url, from: from, to: to, videoTimescale: videoTimescale, output: videoPiece)
            }
            try extractAudioADTS(url, from: from, to: to, output: audioPiece)
            videoPieces.append(videoPiece)
            audioPieces.append(audioPiece)
        }

        var cursor: Double = 0
        for (index, range) in sortedRanges.enumerated() {
            let preKey = nearestKeyframe(atOrBefore: range.start, in: keyframes)
            if preKey > cursor {
                progress?.update(L("Copying segment %@/%@…", "\(index + 1)", "\(sortedRanges.count)"))
                try addKeptSegment(from: cursor, to: preKey, reencodeVideo: false)
            }
            if preKey < range.start {
                progress?.update(L("Re-encoding cut point %@/%@ (before)…", "\(index + 1)", "\(sortedRanges.count)"))
                try addKeptSegment(from: preKey, to: range.start, reencodeVideo: true)
            }
            let postKey = nearestKeyframe(atOrAfter: range.end, in: keyframes, duration: duration)
            if range.end < postKey {
                progress?.update(L("Re-encoding cut point %@/%@ (after)…", "\(index + 1)", "\(sortedRanges.count)"))
                try addKeptSegment(from: range.end, to: postKey, reencodeVideo: true)
            }
            cursor = postKey
        }
        if cursor < duration {
            progress?.update(String(localized: "Copying final segment…"))
            try addKeptSegment(from: cursor, to: duration, reencodeVideo: false)
        }

        progress?.update(String(localized: "Stitching segments back together…"))
        let videoConcat = tempDir.appendingPathComponent("video_concat.mp4")
        try concatVideoPieces(videoPieces, videoTimescale: videoTimescale, output: videoConcat)
        let audioConcat = tempDir.appendingPathComponent("audio_concat.aac")
        try concatRawFiles(audioPieces, output: audioConcat)
        try muxVideoAudio(video: videoConcat, audio: audioConcat, videoTimescale: videoTimescale, output: output, wrapError: FFmpegError.removalFailed)
    }

    /// 用 ffprobe 的 `-skip_frame nokey` 只列出關鍵影格的時間戳，避免解碼整段影片來找 keyframe。
    private static func keyframeTimestamps(_ url: URL) throws -> [Double] {
        let ffprobe = try locate("ffprobe")
        let (status, outData, errData) = try runCapturingStderr(ffprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-skip_frame", "nokey",
            "-show_entries", "frame=pts_time",
            "-of", "csv=p=0",
            url.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.removalFailed(L("Failed to read keyframes:\n%@", msg))
        }
        let text = String(data: outData, encoding: .utf8) ?? ""
        return text.split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .sorted()
    }

    private static func nearestKeyframe(atOrBefore time: Double, in keyframes: [Double]) -> Double {
        var result: Double = 0
        for k in keyframes {
            if k <= time { result = k } else { break }
        }
        return result
    }

    private static func nearestKeyframe(atOrAfter time: Double, in keyframes: [Double], duration: Double) -> Double {
        for k in keyframes where k >= time {
            return k
        }
        return duration
    }

    /// from 一定是 keyframe 時間戳（或 0），所以用 -ss 放在 -i 前面做快速、精準的 keyframe 對齊 seek，
    /// 搭配 -c:v copy 完全不重新編碼視訊，`-an` 完全不含音訊（音訊獨立用 extractAudioADTS 處理）。
    ///
    /// -video_track_timescale 就算是純 -c copy 也要明確帶——實測發現 ffmpeg 的 mp4 muxer
    /// 重新寫 mp4 容器時（即使串流本身完全沒有重新編碼），還是會自己選一個新的 timescale
    /// （原始 1/60 變成 1/15360），不會照抄來源檔案封裝時用的值。跟 reencodeVideoOnly 同一個坑，
    /// 只是這裡連程式碼看起來完全「無害」的 -c copy 也會中招，一定要每個寫 mp4 的步驟都補上。
    private static func copyVideoOnly(_ url: URL, from: Double, to: Double, videoTimescale: Int, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-ss", String(from),
            "-i", url.path,
            "-t", String(to - from),
            "-an", "-c:v", "copy",
            "-avoid_negative_ts", "make_zero",
            "-video_track_timescale", String(videoTimescale),
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.removalFailed(msg)
        }
    }

    /// from 通常不是 keyframe（就是切點本身）。-ss 放在 -i 前面時，ffmpeg 對重新編碼輸出
    /// 預設就是「精準 seek」：內部仍會先跳到附近的 keyframe 再往前解碼校正，不會整段從頭解碼。
    /// pix_fmt/frame rate 對齊原始檔案，確保等一下 concat -c copy 接得起來。
    /// -video_track_timescale 一定要跟原始檔案的 video timescale 一致，不然這個重新編碼片段
    /// 的 timescale 會用 libx264/mp4 muxer 自己選的預設值（實測發生過變成 1/15360，
    /// 原始檔案是 1/60），跟其他 -c copy 片段 concat 在一起、或之後拿去跟別的檔案合併時，
    /// timescale 不一致會導致 ffmpeg mux 階段算 DTS 溢位崩潰。
    ///
    /// `-an`：完全不含音訊，只重新編碼視訊。音訊全部交給 extractAudioADTS 獨立處理、最後用
    /// raw ADTS 位元組串接再跟視訊重新 mux——這是實測驗證過的教訓：即使音訊全程 -c:a copy
    /// 不重新編碼，只要視訊/音訊被 concat demuxer／mp4 muxer 一起處理，接點附近還是可能出現
    /// AAC 解碼錯誤（scalefactor bands exceeds limit），真實播放器（不像 ffmpeg 自己的解碼器
    /// 那麼寬容）遇到這個錯誤會讓接點之後一大段完全沒有聲音。把音訊完全獨立、用位元組層級串接，
    /// 才是實測完全零瑕疵的做法。
    private static func reencodeVideoOnly(_ url: URL, from: Double, to: Double, streamInfo: StreamInfo, videoTimescale: Int, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        var args = [
            "-y", "-nostats", "-loglevel", "error",
            "-ss", String(from),
            "-i", url.path,
            "-t", String(to - from),
            "-an", "-c:v", "libx264",
            "-preset", "slow",
            "-crf", "14",
            "-pix_fmt", streamInfo.pixFmt,
            "-avoid_negative_ts", "make_zero",
            "-video_track_timescale", String(videoTimescale),
        ]
        if !streamInfo.frameRate.isEmpty {
            args += ["-r", streamInfo.frameRate]
        }
        args.append(output.path)

        let (status, _, errData) = try runCapturingStderr(ffmpeg, args)
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.removalFailed(msg)
        }
    }

    /// 抽出 [from, to] 這段的音訊，存成 raw ADTS（不是 mp4 容器）。之後多段 ADTS 檔案會直接用
    /// 位元組串接（見 concatRawFiles），完全繞過 mp4 muxer 處理 concat 的方式，避開接點解碼錯誤。
    private static func extractAudioADTS(_ url: URL, from: Double, to: Double, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-ss", String(from),
            "-i", url.path,
            "-t", String(to - from),
            "-vn", "-c:a", "copy",
            "-f", "adts",
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.removalFailed(msg)
        }
    }

    /// 整個檔案的音訊都要，沒有 -ss/-t 限制範圍（merge() 用）。
    private static func extractAudioADTS(_ url: URL, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-i", url.path,
            "-vn", "-c:a", "copy",
            "-f", "adts",
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.mergeFailed(msg)
        }
    }

    /// 純位元組串接（不透過任何 ffmpeg mux 步驟）。實測證實這是唯一完全不會在接點產生
    /// AAC 解碼錯誤的方式——連 concat demuxer 的 -c copy 都會踩到 mp4 muxer 處理
    /// encoder priming／負時間戳的坑，raw ADTS 位元組直接串接則完全繞過這一層。
    private static func concatRawFiles(_ files: [URL], output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for file in files {
            let data = try Data(contentsOf: file)
            handle.write(data)
        }
    }

    /// 這一步一樣要帶 -video_track_timescale／-avoid_negative_ts，理由跟 copyVideoOnly 一樣：
    /// concat demuxer 輸出最終檔案時，mp4 muxer 還是會自己選 timescale／處理負時間戳的方式，
    /// 不會照抄輸入片段的值。輸入的每個片段都已經是純視訊（無音訊），`-an` 再保險一次。
    private static func concatVideoPieces(_ pieces: [URL], videoTimescale: Int, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        let listFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let listContent = pieces.map { url -> String in
            let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }.joined(separator: "\n")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listFile) }

        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-f", "concat", "-safe", "0",
            "-i", listFile.path,
            "-an", "-c:v", "copy",
            "-avoid_negative_ts", "make_zero",
            "-video_track_timescale", String(videoTimescale),
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.removalFailed(msg)
        }
    }

    /// 把獨立處理好的視訊（已經串接完成的 mp4，無音訊）跟音訊（raw ADTS）重新合成一個檔案。
    /// `wrapError` 讓呼叫端（removeSilenceRanges vs merge）決定失敗時要包成哪一種 FFmpegError，
    /// 這樣使用者看到的錯誤訊息才會對應到他實際在做的操作。
    private static func muxVideoAudio(video: URL, audio: URL, videoTimescale: Int, output: URL, wrapError: (String) -> FFmpegError) throws {
        let ffmpeg = try locate("ffmpeg")
        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-i", video.path,
            "-i", audio.path,
            "-map", "0:v", "-map", "1:a",
            "-c:v", "copy", "-c:a", "copy",
            "-video_track_timescale", String(videoTimescale),
            "-avoid_negative_ts", "make_zero",
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw wrapError(msg)
        }
    }

    /// 跟 removeSilenceRanges 同一套教訓：即使輸入檔案完全沒被動過，讓 concat demuxer／mp4 muxer
    /// 同時處理視訊＋音訊，接點附近還是可能出現 AAC 解碼錯誤，真實播放器遇到會讓那之後一大段
    /// 完全沒聲音（不是只有 ffmpeg 自己測試時看到的一格小瑕疵）。改成音訊獨立用 raw ADTS
    /// 位元組串接、視訊維持 concat demuxer（視訊沒有這個問題），最後重新 mux 回一個檔案。
    static func merge(files: [URL], output: URL) throws {
        guard let first = files.first else { return }
        let firstInfo = try probe(first)
        guard let videoTimescale = firstInfo.videoTimescaleValue else {
            throw FFmpegError.mergeFailed(String(localized: "Couldn't read the source file's video timescale. Stopping rather than risk producing a file with a mismatched timescale (which can crash ffmpeg when merging)."))
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("videomerger-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var audioPieces: [URL] = []
        for (index, file) in files.enumerated() {
            let audioPiece = tempDir.appendingPathComponent("audio_\(index).aac")
            try extractAudioADTS(file, output: audioPiece)
            audioPieces.append(audioPiece)
        }
        let audioConcat = tempDir.appendingPathComponent("audio_concat.aac")
        try concatRawFiles(audioPieces, output: audioConcat)

        let ffmpeg = try locate("ffmpeg")
        let listFile = tempDir.appendingPathComponent("list.txt")
        let listContent = files.map { url -> String in
            let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }.joined(separator: "\n")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)

        let videoConcat = tempDir.appendingPathComponent("video_concat.mp4")
        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-f", "concat", "-safe", "0",
            "-i", listFile.path,
            "-an", "-c:v", "copy",
            "-avoid_negative_ts", "make_zero",
            "-video_track_timescale", String(videoTimescale),
            videoConcat.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? String(localized: "Unknown error")
            throw FFmpegError.mergeFailed(msg)
        }

        try muxVideoAudio(video: videoConcat, audio: audioConcat, videoTimescale: videoTimescale, output: output, wrapError: FFmpegError.mergeFailed)
    }
}
