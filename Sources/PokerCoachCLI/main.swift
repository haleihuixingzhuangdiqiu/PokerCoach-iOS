import Foundation
import PokerCoachCore

struct InputDocument: Codable {
    let schemaVersion: Int
    let table: TableState
    let hero: Int
    let holeCards: HoleCards
    let ranges: [String: String]
    let samples: Int?
    let milliseconds: Int?
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first ?? "help" {
    case "analyze":
        guard args.count == 2 else { throw PokerError.invalid("用法：poker-coach analyze fixtures/six-player-flop.json") }
        let document = try JSONDecoder().decode(InputDocument.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard document.schemaVersion == 1 else { throw PokerError.invalid("不支持的输入版本") }
        var ranges: [Int: HandRange] = [:]
        for (index, range) in document.ranges {
            guard let seat = Int(index) else { throw PokerError.invalid("范围键应为座位数组下标") }
            ranges[seat] = try HandRange.parse(range)
        }
        try printJSON(DecisionEngine.analyze(state: document.table, hero: document.hero, cards: document.holeCards, ranges: ranges,
                                            budget: .init(samples: document.samples ?? 2_000, milliseconds: document.milliseconds ?? 3_000)))
    case "equity":
        guard args.count >= 4 else { throw PokerError.invalid("用法：poker-coach equity AsKs Js8s5d 'AcJc' ['QQ+,AKs']；空公共牌用 '-' ") }
        let request = try EquityRequest(hero: HoleCards(args[1]), board: args[2] == "-" ? [] : Card.parse(args[2]),
                                        opponents: args.dropFirst(3).map { try HandRange.parse($0) })
        try printJSON(EquityEngine.analyze(request, budget: .init(samples: 50_000, milliseconds: 5_000)))
    case "benchmark":
        struct Row: Codable { let name: String; let samples: Int; let milliseconds: Double; let equity: Double }
        var rows: [Row] = []
        for opponents in [1, 3, 5, 8] {
            let request = try EquityRequest(hero: HoleCards("AsKs"), board: Card.parse("Qs8s5d"),
                                            opponents: (0..<opponents).map { _ in .random })
            let result = try EquityEngine.analyze(request, budget: .init(samples: 20_000, milliseconds: 15_000, exactOutcomeLimit: 0))
            rows.append(Row(name: "\(opponents + 1) 人翻牌", samples: result.samples, milliseconds: result.elapsedMilliseconds, equity: result.equity))
        }
        try printJSON(rows)
    default:
        print("""
        PokerCoach 研究算法核心（未接入实时 WPK）
        swift run -c release poker-coach analyze fixtures/six-player-flop.json
        swift run -c release poker-coach equity AsKs Js8s5d AcJc
        swift run -c release poker-coach benchmark
        """)
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(1)
}
