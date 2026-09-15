#if canImport(CoreGraphics)
import Foundation

public enum RankLearningError: Error, LocalizedError, Equatable {
    case notConfigured
    case invalidRank
    case invalidShape
    case invalidRegion
    case conflictingRank(String)
    case rankLimit(String)
    case incompatibleFormat
    case corruptedFile

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "本机牌张样本库尚未就绪。"
        case .invalidRank: return "请选择 A、K、Q、J、10 或 2 至 9 中的一个点数。"
        case .invalidShape: return "这张牌的字形不完整，请重新采集清晰、正立的牌面。"
        case .invalidRegion: return "样本缺少有效的牌张位置。"
        case let .conflictingRank(rank): return "字形与已有的 \(rank == "T" ? "10" : rank) 过于相似，请重新核对牌面。"
        case let .rankLimit(rank): return "\(rank == "T" ? "10" : rank) 已保存 4 个样本，请先撤销不需要的样本。"
        case .incompatibleFormat: return "本机样本的版本、主题或方向不匹配，未加载这些样本。"
        case .corruptedFile: return "本机牌张样本文件损坏，未加载这些样本。"
        }
    }
}

/// Stores explicitly user-labelled, upright ocean-theme glyphs only. No OCR result is used as a label.
/// All state and disk operations share one lock. Atomic persistence precedes any in-memory mutation.
public final class RankLearningLibrary: @unchecked Sendable {
    public static let shared = RankLearningLibrary()
    public static let ranks = ["A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2"]
    private static let formatVersion = 1
    private static let theme = WPKVideoLayout.identifier
    private static let orientation = "upright"
    private static let maximumPerRank = 4
    private static let maximumFileBytes = 512 * 1024
    private static let conflictDistance = 0.04
    private static let duplicateDistance = 0.01

    private struct Sample: Codable {
        let id: UUID
        let rank: String
        let pixels: [UInt8]
        let region: String
        let createdAt: Date
        var template: RankTemplate {
            RankTemplate(rank: rank, pixels: pixels,
                         source: "user-confirmed:\(region):\(id.uuidString)")
        }
    }
    private struct FileContents: Codable {
        let formatVersion: Int
        let theme: String
        let orientation: String
        let samples: [Sample]
    }

    private let lock = NSLock()
    private var storageURL: URL?
    private var samples: [Sample] = []

    public init() {}

    public var templates: [RankTemplate] {
        lock.lock(); defer { lock.unlock() }
        return samples.map(\.template)
    }
    public var coverage: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(samples.map(\.rank))
    }
    public var hasSavedSamples: Bool {
        lock.lock(); defer { lock.unlock() }
        return !samples.isEmpty
    }
    public var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// Call explicitly at app launch. Missing files start an empty library; any invalid file disables
    /// this instance until a later successful configure, including clearing previously loaded data.
    public func configure(storageURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        self.storageURL = nil; samples = []
        guard storageURL.isFileURL else { throw RankLearningError.corruptedFile }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            self.storageURL = storageURL; return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes else {
            throw RankLearningError.corruptedFile
        }
        let data = try Data(contentsOf: storageURL)
        guard data.count <= Self.maximumFileBytes else { throw RankLearningError.corruptedFile }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let contents: FileContents
        do { contents = try decoder.decode(FileContents.self, from: data) }
        catch { throw RankLearningError.corruptedFile }
        guard contents.formatVersion == Self.formatVersion, contents.theme == Self.theme,
              contents.orientation == Self.orientation else { throw RankLearningError.incompatibleFormat }
        try Self.validate(contents.samples)
        samples = contents.samples
        self.storageURL = storageURL
    }

    /// The caller supplies the user's explicit rank selection and a 24×32 binary glyph.
    /// Near duplicates of the same rank are no-ops, including duplicates of built-in templates.
    public func save(rank: String, pixels: [UInt8], region: String, builtInTemplates: [RankTemplate]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let storageURL else { throw RankLearningError.notConfigured }
        try Self.validate(rank: rank, pixels: pixels, region: region)
        for template in builtInTemplates {
            try Self.validate(rank: template.rank, pixels: template.pixels)
        }
        let existing = builtInTemplates + samples.map(\.template)
        if let conflict = existing.first(where: {
            $0.rank != rank && Self.distance(pixels, $0.pixels) < Self.conflictDistance
        }) { throw RankLearningError.conflictingRank(conflict.rank) }
        if existing.contains(where: {
            $0.rank == rank && Self.distance(pixels, $0.pixels) < Self.duplicateDistance
        }) { return }
        guard samples.filter({ $0.rank == rank }).count < Self.maximumPerRank else {
            throw RankLearningError.rankLimit(rank)
        }
        let next = samples + [Sample(id: UUID(), rank: rank, pixels: pixels, region: region, createdAt: Date())]
        try persist(next, at: storageURL)
        samples = next
    }

    /// Undo the most recent saved sample; a rejected or duplicate save does not add an undo entry.
    public func removeLast() throws {
        lock.lock(); defer { lock.unlock() }
        guard let storageURL else { throw RankLearningError.notConfigured }
        guard !samples.isEmpty else { return }
        let next = Array(samples.dropLast())
        try persist(next, at: storageURL)
        samples = next
    }

    private func persist(_ samples: [Sample], at url: URL) throws {
        let contents = FileContents(formatVersion: Self.formatVersion, theme: Self.theme,
                                    orientation: Self.orientation, samples: samples)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contents)
        guard data.count <= Self.maximumFileBytes else { throw RankLearningError.corruptedFile }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func validate(rank: String, pixels: [UInt8], region: String? = nil) throws {
        guard ranks.contains(rank) else { throw RankLearningError.invalidRank }
        guard pixels.count == 768, pixels.allSatisfy({ $0 == 0 || $0 == 255 }),
              pixels.contains(0), pixels.contains(255) else { throw RankLearningError.invalidShape }
        if let region, region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || region.utf8.count > 64 {
            throw RankLearningError.invalidRegion
        }
    }

    private static func validate(_ samples: [Sample]) throws {
        guard samples.count <= ranks.count * maximumPerRank,
              Set(samples.map(\.id)).count == samples.count else { throw RankLearningError.corruptedFile }
        var counts: [String: Int] = [:]
        for (index, sample) in samples.enumerated() {
            try validate(rank: sample.rank, pixels: sample.pixels, region: sample.region)
            guard sample.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw RankLearningError.corruptedFile }
            counts[sample.rank, default: 0] += 1
            guard counts[sample.rank, default: 0] <= maximumPerRank else { throw RankLearningError.rankLimit(sample.rank) }
            for earlier in samples.prefix(index) {
                let difference = distance(sample.pixels, earlier.pixels)
                if sample.rank != earlier.rank, difference < conflictDistance {
                    throw RankLearningError.conflictingRank(earlier.rank)
                }
                if sample.rank == earlier.rank, difference < duplicateDistance { throw RankLearningError.corruptedFile }
            }
        }
    }

    private static func distance(_ first: [UInt8], _ second: [UInt8]) -> Double {
        // Both shapes were validated before comparison; distance is the fraction of differing pixels.
        Double(zip(first, second).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }) / 768.0
    }
}
#endif
