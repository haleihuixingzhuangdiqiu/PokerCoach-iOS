import Foundation
import PokerCoachCapture
#if canImport(ImageIO)
import ImageIO

do {
    guard CommandLine.arguments.count > 1 else { throw NSError(domain: "PokerCoach", code: 1, userInfo: [NSLocalizedDescriptionKey: "用法：poker-cards frame.png [another.png]"]) }
    let reader = try FourColorCardReader.wpkVideoProfile()
    struct Row: Codable { let file: String; let milliseconds: Double; let cards: [CardReadEvidence] }
    var rows: [Row] = []
    for path in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "PokerCoach", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片无法解码"])
        }
        let start = ProcessInfo.processInfo.systemUptime
        let cards = try reader.read(image, regions: WPKVideoLayout.cardRegions)
        rows.append(Row(file: url.lastPathComponent, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, cards: cards))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(rows), as: UTF8.self))
} catch { FileHandle.standardError.write(Data("错误：\(error)\n".utf8)); exit(1) }
#endif
