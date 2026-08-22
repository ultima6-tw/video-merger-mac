import Foundation

struct StreamInfo: Equatable {
    let videoCodec: String
    let width: Int
    let height: Int
    let frameRate: String
    let pixFmt: String
    let audioCodec: String?
    let sampleRate: String?
    let channels: Int?
    let durationSeconds: Double?

    // durationSeconds 不列入比較：每個檔案長度本來就會不一樣，不是不相容的判斷依據。
    static func == (lhs: StreamInfo, rhs: StreamInfo) -> Bool {
        lhs.videoCodec == rhs.videoCodec &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.frameRate == rhs.frameRate &&
        lhs.pixFmt == rhs.pixFmt &&
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
            return "找不到 \(name)，請確認已透過 Homebrew 安裝（brew install \(package)）。"
        case .probeFailed(let file, let detail):
            return "無法讀取「\(file)」的格式資訊：\n\(detail)"
        case .incompatible(let detail):
            return detail
        case .mergeFailed(let detail):
            return "合併失敗：\n\(detail)"
        case .silenceDetectFailed(let file, let detail):
            return "「\(file)」靜音偵測失敗：\n\(detail)"
        case .unsupportedCodecForRemoval(let detail):
            return "目前只支援 H.264 視訊／AAC 音訊來源做精準切除：\(detail)"
        case .removalFailed(let detail):
            return "移除靜音片段失敗：\n\(detail)"
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
            "-show_entries", "format=duration:stream=codec_name,codec_type,width,height,r_frame_rate,pix_fmt,sample_rate,channels",
            url.path,
        ])

        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "未知錯誤"
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
        }
        struct Format: Decodable { let duration: String? }
        struct Probe: Decodable { let streams: [Stream]; let format: Format? }

        let probe = try JSONDecoder().decode(Probe.self, from: outData)
        guard let video = probe.streams.first(where: { $0.codec_type == "video" }) else {
            throw FFmpegError.probeFailed(url.lastPathComponent, "找不到視訊軌，確認這是有效的影片檔案")
        }
        let audio = probe.streams.first(where: { $0.codec_type == "audio" })

        return StreamInfo(
            videoCodec: video.codec_name ?? "",
            width: video.width ?? 0,
            height: video.height ?? 0,
            frameRate: video.r_frame_rate ?? "",
            pixFmt: video.pix_fmt ?? "",
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
        var diffs: [String] = []
        if first.videoCodec != other.videoCodec { diffs.append("視訊編碼：\(first.videoCodec) vs \(other.videoCodec)") }
        if first.width != other.width || first.height != other.height {
            diffs.append("解析度：\(first.width)x\(first.height) vs \(other.width)x\(other.height)")
        }
        if first.frameRate != other.frameRate { diffs.append("幀率：\(first.frameRate) vs \(other.frameRate)") }
        if first.pixFmt != other.pixFmt { diffs.append("像素格式：\(first.pixFmt) vs \(other.pixFmt)") }
        if first.audioCodec != other.audioCodec { diffs.append("音訊編碼：\(first.audioCodec ?? "無") vs \(other.audioCodec ?? "無")") }
        if first.sampleRate != other.sampleRate { diffs.append("取樣率：\(first.sampleRate ?? "無") vs \(other.sampleRate ?? "無")") }
        if first.channels != other.channels { diffs.append("聲道數：\(first.channels.map(String.init) ?? "無") vs \(other.channels.map(String.init) ?? "無")") }

        let diffText = diffs.isEmpty ? "格式不一致" : diffs.joined(separator: "\n")
        return "「\(firstName)」與「\(otherName)」格式不相容，無法無損合併：\n\(diffText)\n\n不會自動重新編碼，請確認來源檔案後再試。"
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
    /// 做法：只在每個切點前後重新編碼一小段（貼齊最近的 keyframe），其餘大部分內容維持
    /// stream copy，盡量不動到畫質。演算法：
    ///   1. 依序處理每個（已排序的）靜音區間，游標 cursor 一開始是 0
    ///   2. [cursor, 切點前最近 keyframe] 用 -c copy（這段一定跨好幾個 keyframe，量體最大）
    ///   3. [切點前最近 keyframe, range.start] 重新編碼（通常只有一小段，因為 keyframe 間隔本來就不長）
    ///   4. range.start ~ range.end 之間（靜音本身）整段捨棄，這就是「移除」的實際動作
    ///   5. [range.end, 切點後最近 keyframe] 重新編碼
    ///   6. 游標移到「切點後最近 keyframe」，換下一個區間，最後剩餘的 [cursor, duration] 用 -c copy
    ///   7. 全部片段依序用 concat demuxer 的 -c copy 接回去（重新編碼的片段參數對齊原始碼，接得起來）
    ///
    /// 目前只驗證過 H.264/AAC 這組最常見的攝影機/OBS 錄影格式，其他編碼組合會直接報錯，
    /// 因為重新編碼時要用對應的 encoder（例如 HEVC 來源要用 libx265），還沒補上這個對應表。
    static func removeSilenceRanges(
        from url: URL,
        ranges: [SilenceRange],
        streamInfo: StreamInfo,
        output: URL,
        progress: RemovalProgress? = nil
    ) throws {
        guard streamInfo.videoCodec.lowercased() == "h264" else {
            throw FFmpegError.unsupportedCodecForRemoval("視訊編碼是 \(streamInfo.videoCodec)")
        }
        guard let audioCodec = streamInfo.audioCodec, audioCodec.lowercased() == "aac" else {
            throw FFmpegError.unsupportedCodecForRemoval("音訊編碼是 \(streamInfo.audioCodec ?? "無")")
        }
        guard let duration = streamInfo.durationSeconds, duration > 0 else {
            throw FFmpegError.removalFailed("找不到檔案總長度")
        }
        guard !ranges.isEmpty else {
            throw FFmpegError.removalFailed("沒有選擇要移除的片段")
        }

        let sortedRanges = ranges.sorted { $0.start < $1.start }

        progress?.update("讀取關鍵影格位置…")
        let keyframes = try keyframeTimestamps(url)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("videomerger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var pieces: [URL] = []
        var pieceIndex = 0
        func nextPieceURL() -> URL {
            pieceIndex += 1
            return tempDir.appendingPathComponent("piece_\(pieceIndex).mp4")
        }

        var cursor: Double = 0
        for (index, range) in sortedRanges.enumerated() {
            let preKey = nearestKeyframe(atOrBefore: range.start, in: keyframes)
            if preKey > cursor {
                progress?.update("複製片段 \(index + 1)/\(sortedRanges.count)…")
                let piece = nextPieceURL()
                try copySegment(url, from: cursor, to: preKey, output: piece)
                pieces.append(piece)
            }
            if preKey < range.start {
                progress?.update("重新編碼切點 \(index + 1)/\(sortedRanges.count)（前）…")
                let piece = nextPieceURL()
                try reencodeSegment(url, from: preKey, to: range.start, streamInfo: streamInfo, output: piece)
                pieces.append(piece)
            }
            let postKey = nearestKeyframe(atOrAfter: range.end, in: keyframes, duration: duration)
            if range.end < postKey {
                progress?.update("重新編碼切點 \(index + 1)/\(sortedRanges.count)（後）…")
                let piece = nextPieceURL()
                try reencodeSegment(url, from: range.end, to: postKey, streamInfo: streamInfo, output: piece)
                pieces.append(piece)
            }
            cursor = postKey
        }
        if cursor < duration {
            progress?.update("複製最後一段…")
            let piece = nextPieceURL()
            try copySegment(url, from: cursor, to: duration, output: piece)
            pieces.append(piece)
        }

        progress?.update("接回所有片段…")
        try concatPieces(pieces, output: output)
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
            let msg = String(data: errData, encoding: .utf8) ?? "未知錯誤"
            throw FFmpegError.removalFailed("讀取關鍵影格失敗：\n\(msg)")
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
    /// 搭配 -c copy 完全不重新編碼。
    private static func copySegment(_ url: URL, from: Double, to: Double, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y", "-nostats", "-loglevel", "error",
            "-ss", String(from),
            "-i", url.path,
            "-t", String(to - from),
            "-c", "copy",
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "未知錯誤"
            throw FFmpegError.removalFailed(msg)
        }
    }

    /// from 通常不是 keyframe（就是切點本身）。-ss 放在 -i 前面時，ffmpeg 對重新編碼輸出
    /// 預設就是「精準 seek」：內部仍會先跳到附近的 keyframe 再往前解碼校正，不會整段從頭解碼。
    /// pix_fmt/frame rate/sample rate/channels 都對齊原始檔案，確保等一下 concat -c copy 接得起來。
    private static func reencodeSegment(_ url: URL, from: Double, to: Double, streamInfo: StreamInfo, output: URL) throws {
        let ffmpeg = try locate("ffmpeg")
        var args = [
            "-y", "-nostats", "-loglevel", "error",
            "-ss", String(from),
            "-i", url.path,
            "-t", String(to - from),
            "-c:v", "libx264",
            "-preset", "slow",
            "-crf", "14",
            "-pix_fmt", streamInfo.pixFmt,
        ]
        if !streamInfo.frameRate.isEmpty {
            args += ["-r", streamInfo.frameRate]
        }
        args += ["-c:a", "aac", "-b:a", "320k"]
        if let sampleRate = streamInfo.sampleRate { args += ["-ar", sampleRate] }
        if let channels = streamInfo.channels { args += ["-ac", String(channels)] }
        args.append(output.path)

        let (status, _, errData) = try runCapturingStderr(ffmpeg, args)
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "未知錯誤"
            throw FFmpegError.removalFailed(msg)
        }
    }

    private static func concatPieces(_ pieces: [URL], output: URL) throws {
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
            "-c", "copy",
            output.path,
        ])
        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "未知錯誤"
            throw FFmpegError.removalFailed(msg)
        }
    }

    static func merge(files: [URL], output: URL) throws {
        let ffmpeg = try locate("ffmpeg")

        let listFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let listContent = files.map { url -> String in
            let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }.joined(separator: "\n")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listFile) }

        let (status, _, errData) = try runCapturingStderr(ffmpeg, [
            "-y",
            "-nostats", "-loglevel", "error",
            "-f", "concat", "-safe", "0",
            "-i", listFile.path,
            "-c", "copy",
            output.path,
        ])

        guard status == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "未知錯誤"
            throw FFmpegError.mergeFailed(msg)
        }
    }
}
