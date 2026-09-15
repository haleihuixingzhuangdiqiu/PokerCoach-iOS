import Foundation
import PokerCoachCore
import PokerCoachCapture
#if os(macOS)
import CoreGraphics

func executable(_ name: String) throws -> URL {
    for root in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/opt/homebrew/bin").split(separator: ":") {
        let url = URL(fileURLWithPath: String(root)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw PokerError.invalid("视频回放验证需要安装 \(name)")
}

do {
    guard CommandLine.arguments.count == 2 else { throw PokerError.invalid("用法：poker-video /path/to/screen-recording.mp4") }
    let source = CommandLine.arguments[1]
    let probe = Process(), probePipe = Pipe()
    probe.executableURL = try executable("ffprobe")
    probe.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", source]
    probe.standardOutput = probePipe
    try probe.run()
    let info = try JSONSerialization.jsonObject(with: probePipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
    probe.waitUntilExit()
    guard probe.terminationStatus == 0, let stream = (info?["streams"] as? [[String: Any]])?.first,
          let width = stream["width"] as? Int, let height = stream["height"] as? Int,
          abs(Double(width) / Double(height) - 220.0 / 480) < 0.01 else {
        throw PokerError.invalid("视频比例与当前布局样本不符；先校准布局，不能直接拉伸")
    }
    let process = Process(), pipe = Pipe()
    process.executableURL = try executable("ffmpeg")
    process.arguments = ["-hide_banner", "-loglevel", "error", "-i", source, "-vf", "fps=15,scale=220:480", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"]
    process.standardOutput = pipe
    try process.run()
    let frameSize = 220 * 480
    var detector = RegionChangeDetector(), frame = 0
    var elapsedSamples: [Double] = [], changeCounts: [String: Int] = [:]
    struct Event: Codable { let atSeconds: Double; let fields: [String] }
    var events: [Event] = []
    let overallStart = ProcessInfo.processInfo.systemUptime
    while true {
        var data = Data()
        while data.count < frameSize {
            guard let part = try pipe.fileHandleForReading.read(upToCount: frameSize - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        if data.isEmpty { break }
        guard data.count == frameSize else { throw PokerError.invalid("视频帧被截断") }
        try autoreleasepool {
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: 220, height: 480, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 220,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PokerError.invalid("图像构建失败") }
            let started = ProcessInfo.processInfo.systemUptime
            let digests = WPKVideoLayout.regions.compactMap { region in region.digest(image).map { RegionDigest(id: region.id, pixels: $0) } }
            let changes = detector.inspect(digests, sequence: UInt64(frame), capturedAt: Double(frame) / 15)
            elapsedSamples.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            if !changes.isEmpty {
                events.append(Event(atSeconds: Double(frame) / 15, fields: changes.map(\.id)))
                for change in changes { changeCounts[change.id, default: 0] += 1 }
            }
        }
        frame += 1
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0, !elapsedSamples.isEmpty else { throw PokerError.invalid("视频解码失败") }
    elapsedSamples.sort()
    struct Report: Codable {
        let profile: String; let sourceWidth: Int; let sourceHeight: Int; let sampledFrames: Int
        let samplingFPS: Int; let wholeReplaySeconds: Double
        let digestAndChangeMedianMs: Double; let digestAndChangeP95Ms: Double
        let changesByRegion: [String: Int]; let events: [Event]; let scope: String
    }
    let report = Report(profile: WPKVideoLayout.identifier, sourceWidth: width, sourceHeight: height, sampledFrames: frame,
                        samplingFPS: 15, wholeReplaySeconds: ProcessInfo.processInfo.systemUptime - overallStart,
                        digestAndChangeMedianMs: elapsedSamples[elapsedSamples.count / 2],
                        digestAndChangeP95Ms: elapsedSamples[min(elapsedSamples.count - 1, Int(Double(elapsedSamples.count) * 0.95))],
                        changesByRegion: changeCounts, events: events,
                        scope: "Mac 离线视频：12 个区域裁剪、灰度摘要和变化检测。不是语义识别成功率，也不是真机端到端延迟。")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8)); exit(1)
}
#else
print("视频回放验证器在 macOS 上运行；iPhone 使用 PokerCoachCapture。")
#endif
