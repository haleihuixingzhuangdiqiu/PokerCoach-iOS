import Foundation
import XCTest
@testable import PokerCoachCapture

#if canImport(CoreGraphics)
final class RankLearningLibraryTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("ranks.json") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RankLearningTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    private func shape(_ variant: Int = 0) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 768)
        for index in (variant * 100)..<(variant * 100 + 100) { result[index] = 255 }
        return result
    }
    private func library() throws -> RankLearningLibrary {
        let library = RankLearningLibrary(); try library.configure(storageURL: url); return library
    }

    func testPersistsReloadsAndRecordsOnlyGlyphMetadata() throws {
        let first = try library()
        XCTAssertFalse(first.hasSavedSamples)
        try first.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        let reloaded = try library()
        XCTAssertEqual(reloaded.coverage, ["6"])
        XCTAssertEqual(reloaded.sampleCount, 1)
        XCTAssertEqual(reloaded.templates.first?.pixels, shape())
        let contents = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(contents["formatVersion"] as? Int, 1)
        XCTAssertEqual(contents["theme"] as? String, WPKVideoLayout.identifier)
        XCTAssertEqual(contents["orientation"] as? String, "upright")
        let sample = try XCTUnwrap((contents["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["region"] as? String, "hero.0")
        XCTAssertNotNil(sample["createdAt"] as? String)
        XCTAssertEqual(Set(sample.keys), ["id", "rank", "pixels", "region", "createdAt"])
    }

    func testUndoPersistsAndRepeatedUndoOnEmptyIsHarmless() throws {
        let library = try library()
        try library.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        try library.save(rank: "5", pixels: shape(1), region: "board.0", builtInTemplates: [])
        try library.removeLast()
        XCTAssertEqual(try self.library().coverage, ["6"])
        try library.removeLast(); try library.removeLast()
        XCTAssertFalse(library.hasSavedSamples)
        XCTAssertFalse(try self.library().hasSavedSamples)
    }

    func testRejectsLabelsAndMalformedOrBlankGlyphsWithoutSaving() throws {
        let library = try library()
        for rank in ["1", "B", "10", "q", ""] {
            XCTAssertThrowsError(try library.save(rank: rank, pixels: shape(), region: "hero.0", builtInTemplates: []))
        }
        var nonbinary = shape(); nonbinary[500] = 120
        for pixels in [[], [UInt8](repeating: 0, count: 767), [UInt8](repeating: 0, count: 768),
                       [UInt8](repeating: 255, count: 768), nonbinary] {
            XCTAssertThrowsError(try library.save(rank: "6", pixels: pixels, region: "hero.0", builtInTemplates: []))
        }
        XCTAssertThrowsError(try library.save(rank: "6", pixels: shape(), region: " ", builtInTemplates: []))
        XCTAssertEqual(library.sampleCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRejectsNearIdenticalDifferentLabelsAgainstBuiltInAndSavedSamples() throws {
        let library = try library()
        var nearby = shape(); nearby[101] = 255
        let nine = RankTemplate(rank: "9", pixels: shape(), source: "builtin")
        XCTAssertThrowsError(try library.save(rank: "6", pixels: nearby, region: "hero.0", builtInTemplates: [nine])) { error in
            XCTAssertEqual(error as? RankLearningError, .conflictingRank("9"))
        }
        // A clearly different six is allowed even when a nine already exists.
        try library.save(rank: "6", pixels: shape(1), region: "hero.0", builtInTemplates: [nine])
        XCTAssertThrowsError(try library.save(rank: "5", pixels: shape(1), region: "hero.0", builtInTemplates: []))
        XCTAssertEqual(library.coverage, ["6"])
    }

    func testSameRankDuplicateIsIdempotentAndDoesNotConsumeUndoOrLimit() throws {
        let library = try library()
        try library.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        let before = try Data(contentsOf: url)
        var nearby = shape(); nearby[101] = 255
        try library.save(rank: "6", pixels: nearby, region: "board.0", builtInTemplates: [])
        XCTAssertEqual(library.sampleCount, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        try library.removeLast()
        XCTAssertEqual(library.sampleCount, 0)
        try library.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [
            RankTemplate(rank: "6", pixels: shape(), source: "builtin")
        ])
        XCTAssertEqual(library.sampleCount, 0)
    }

    func testAtMostFourDifferentSamplesPerRank() throws {
        let library = try library()
        for variant in 0..<4 { try library.save(rank: "6", pixels: shape(variant), region: "hero.0", builtInTemplates: []) }
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try library.save(rank: "6", pixels: shape(4), region: "hero.0", builtInTemplates: [])) { error in
            XCTAssertEqual(error as? RankLearningError, .rankLimit("6"))
        }
        XCTAssertEqual(library.sampleCount, 4)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try self.library().sampleCount, 4)
    }

    func testCorruptedConfigureClearsPreviouslyLoadedDataAndDisablesSaving() throws {
        let library = try library()
        try library.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        try Data("not valid JSON".utf8).write(to: url)
        XCTAssertThrowsError(try library.configure(storageURL: url))
        XCTAssertEqual(library.sampleCount, 0)
        XCTAssertThrowsError(try library.save(rank: "5", pixels: shape(1), region: "board.0", builtInTemplates: [])) { error in
            XCTAssertEqual(error as? RankLearningError, .notConfigured)
        }
    }

    func testPersistFailureDoesNotPublishUnsavedTemplate() throws {
        let library = try library()
        // Replacing the destination with a directory deterministically prevents an atomic file write.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: []))
        XCTAssertFalse(library.hasSavedSamples)
    }

    func testIncompatibleThemeDoesNotLoad() throws {
        let first = try library()
        try first.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        var contents = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        contents["theme"] = "another-theme"
        try JSONSerialization.data(withJSONObject: contents).write(to: url)
        XCTAssertThrowsError(try first.configure(storageURL: url)) { error in
            XCTAssertEqual(error as? RankLearningError, .incompatibleFormat)
        }
        XCTAssertEqual(first.sampleCount, 0)
    }

    func testLoadingRevalidatesStoredLabelsGlyphsConflictsAndClassLimit() throws {
        let first = try library()
        try first.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for scenario in ["rank", "size", "nonbinary", "blank", "limit", "conflict"] {
            var modified = original
            var stored = try XCTUnwrap(original["samples"] as? [[String: Any]])
            switch scenario {
            case "rank": stored[0]["rank"] = "invalid"
            case "size": stored[0]["pixels"] = [0, 255]
            case "nonbinary": var pixels = shape(); pixels[300] = 120; stored[0]["pixels"] = pixels
            case "blank": stored[0]["pixels"] = [UInt8](repeating: 0, count: 768)
            case "limit":
                let sample = stored[0]
                stored = (0..<5).map { variant in
                    var copy = sample; copy["id"] = UUID().uuidString; copy["pixels"] = shape(variant); return copy
                }
            default:
                var other = stored[0]; other["id"] = UUID().uuidString; other["rank"] = "9"; stored.append(other)
            }
            modified["samples"] = stored
            try JSONSerialization.data(withJSONObject: modified).write(to: url)
            let reloaded = RankLearningLibrary()
            XCTAssertThrowsError(try reloaded.configure(storageURL: url), scenario)
            XCTAssertEqual(reloaded.sampleCount, 0, scenario)
        }
    }

    func testFailedUndoKeepsPreviouslyPublishedSample() throws {
        let library = try library()
        try library.save(rank: "6", pixels: shape(), region: "hero.0", builtInTemplates: [])
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.removeLast())
        XCTAssertEqual(library.sampleCount, 1)
        XCTAssertEqual(library.templates.first?.pixels, shape())
    }
}
#endif
