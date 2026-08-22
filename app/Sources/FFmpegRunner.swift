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

enum FFmpegError: LocalizedError {
    case binaryNotFound(String)
    case probeFailed(String, String)
    case incompatible(String)
    case mergeFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "找不到 \(name)，請確認已透過 Homebrew 安裝（brew install ffmpeg）。"
        case .probeFailed(let file, let detail):
            return "無法讀取「\(file)」的格式資訊：\n\(detail)"
        case .incompatible(let detail):
            return detail
        case .mergeFailed(let detail):
            return "合併失敗：\n\(detail)"
        }
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
