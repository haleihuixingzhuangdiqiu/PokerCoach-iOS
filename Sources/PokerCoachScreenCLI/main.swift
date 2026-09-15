import Foundation
import ImageIO
import PokerCoachCapture
import PokerCoachCore

do {
    let cards = try FourColorCardReader.wpkVideoProfile(), fields = WPKPublicStateReader()
    struct Row: Encodable {
        let file: String; let evidence: PublicStateEvidence; let facts: PublicBettingFacts
        let hand: String?; let estimate: CardEquityEstimate?; let milliseconds: Double
    }
    var rows: [Row] = []
    for path in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: path), start = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PokerError.invalid("图片不可读") }
        let evidence = try fields.read(image)
        let facts = PublicBettingFacts(raw: evidence.raw, scores: evidence.scores, callControlVisible: evidence.callControlVisible)
        let cardEvidence = try cards.read(image, regions: WPKVideoLayout.cardRegions)
        let position = cardEvidence.contains(where: \.hasUnresolvedCard) ? nil : try? LiveCardPosition(slots: cardEvidence.map(\.card))
        let estimate = facts.maximumOpponents > 0 ? try position.map { try LiveCardAnalyzer.analyze($0, maximumOpponents: facts.maximumOpponents) } : nil
        rows.append(Row(file: url.lastPathComponent, evidence: evidence, facts: facts, hand: position?.handName, estimate: estimate,
                        milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(rows), as: UTF8.self))
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
