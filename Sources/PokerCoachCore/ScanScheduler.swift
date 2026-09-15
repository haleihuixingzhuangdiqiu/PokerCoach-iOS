import Foundation

public struct RegionDigest: Sendable {
    public let id: String
    public let pixels: [UInt8]
    public init(id: String, pixels: [UInt8]) { self.id = id; self.pixels = pixels }
}

public struct ChangedRegion: Sendable, Codable {
    public let id: String
    public let sequence: UInt64
    public let capturedAt: Double
    public let meanAbsoluteDifference: Double
}

/// Cheap per-region detection; image decoding/downsampling is supplied by the capture adapter.
/// A fixed reference prevents slow incremental changes from being absorbed forever.
public struct RegionChangeDetector: Sendable {
    private var references: [String: [UInt8]] = [:]
    public let meanThreshold: Double
    public let pixelThreshold: Int
    public let minimumChangedFraction: Double
    public init(meanThreshold: Double = 7, pixelThreshold: Int = 18, minimumChangedFraction: Double = 0.08) {
        self.meanThreshold = meanThreshold; self.pixelThreshold = pixelThreshold; self.minimumChangedFraction = minimumChangedFraction
    }
    public mutating func reset() { references = [:] }
    public mutating func inspect(_ regions: [RegionDigest], sequence: UInt64, capturedAt: Double) -> [ChangedRegion] {
        var changes: [ChangedRegion] = []
        for region in regions where !region.pixels.isEmpty {
            guard let previous = references[region.id], previous.count == region.pixels.count else {
                references[region.id] = region.pixels
                changes.append(ChangedRegion(id: region.id, sequence: sequence, capturedAt: capturedAt, meanAbsoluteDifference: 255))
                continue
            }
            var sum = 0, changed = 0
            for i in previous.indices {
                let delta = abs(Int(previous[i]) - Int(region.pixels[i])); sum += delta
                if delta >= pixelThreshold { changed += 1 }
            }
            let mean = Double(sum) / Double(previous.count)
            if mean >= meanThreshold && Double(changed) / Double(previous.count) >= minimumChangedFraction {
                references[region.id] = region.pixels
                changes.append(ChangedRegion(id: region.id, sequence: sequence, capturedAt: capturedAt, meanAbsoluteDifference: mean))
            }
        }
        return changes
    }
}

/// Distinct observed transitions must survive slow OCR. Overflow marks the history incomplete.
/// Keep cropped critical fields as Payload, rather than retaining full-resolution video buffers.
public struct CriticalTransitionQueue<Payload: Sendable>: Sendable {
    public private(set) var historyGap = false
    private var items: [Payload] = []
    public let capacity: Int
    public init(capacity: Int = 12) { self.capacity = max(1, capacity) }
    public mutating func append(_ payload: Payload) {
        if items.count == capacity { items.removeFirst(); historyGap = true }
        items.append(payload)
    }
    public mutating func take() -> Payload? { items.isEmpty ? nil : items.removeFirst() }
    public mutating func resetAtNewHand() { items = []; historyGap = false }
}

public enum ChipAmountParser {
    /// Explicit dot-decimal/comma-grouping notation, K/M suffixes. No automatic O→0 or I→1 repair.
    /// unitScale=100 encodes 1.25 table units as 125 integer chip units.
    public static func parse(_ text: String, unitScale: Int = 100) throws -> Int {
        guard unitScale > 0 && unitScale <= 1_000_000 else { throw PokerError.invalid("筹码精度无效") }
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var multiplier = 1
        if raw.hasSuffix("K") { multiplier = 1000; raw.removeLast() }
        else if raw.hasSuffix("M") { multiplier = 1_000_000; raw.removeLast() }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && $0.isNumber })) else { throw PokerError.invalid("金额格式不确定") }
        let groups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              groups.count == 1 || ((1...3).contains(groups[0].count) && groups.dropFirst().allSatisfy({ $0.count == 3 })) else { throw PokerError.invalid("金额千位分隔符不确定") }
        guard let value = Decimal(string: raw.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) else { throw PokerError.invalid("金额无法解析") }
        var scaled = value * Decimal(unitScale) * Decimal(multiplier), integral = Decimal()
        NSDecimalRound(&integral, &scaled, 0, .plain)
        guard scaled == integral && scaled >= 0 && scaled <= 1_000_000_000 else { throw PokerError.invalid("金额超出精度或范围") }
        return NSDecimalNumber(decimal: integral).intValue
    }
}
