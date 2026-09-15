import Foundation
import CoreGraphics
import PokerCoachCore
import PokerCoachCapture

/// The theme indexes skip the bottom hero between right/left sides. Core indexes
/// always proceed clockwise. This mapping applies to dealer, actor and straddler too.
enum WPKFullTableAdapter {
    static let clockwiseSourceSeats = [0, 1, 2, 3, 7, 4, 5, 6]
    static func controls(_ control: WPKActionControlEvidence) -> VisiblePassiveActions {
        let amounts = control.raiseCandidates.filter { $0.confidence >= 0.9 }
        return .init(heroTurnConfirmed: control.heroTurnConfirmed,
            foldAvailable: control.canFold, checkAvailable: control.canCheck,
            callAmount: control.callConfidence >= 0.9 ? control.callAmountText.flatMap { try? ChipAmountParser.parse($0) } : nil,
            visibleBetAmounts: control.heroWagerAreaClear ? amounts.filter { $0.meaning == .bet }.compactMap { try? ChipAmountParser.parse($0.amountText) } : [],
            heroStreetCommitted: control.heroWagerAreaClear ? 0 : control.heroWager.flatMap { $0.confidence >= 0.9 ? try? ChipAmountParser.parse($0.amountText) : nil },
            visibleRaiseToAmounts: amounts.filter { $0.meaning == .raiseTo }.compactMap { try? ChipAmountParser.parse($0.amountText) })
    }
    static func snapshot(_ evidence: WPKTableSnapshotEvidence, position: LiveCardPosition,
                         heroTurn: Bool) throws -> PublicTableSnapshot {
        guard evidence.seats.count == 8, Set(evidence.seats.map(\.index)) == Set(0..<8) else {
            throw PokerError.invalid("完整牌桌座位尚未读全")
        }
        let indexed = Dictionary(uniqueKeysWithValues: evidence.seats.map { ($0.index, $0) })
        let seats = clockwiseSourceSeats.map { source -> PublicSeatSnapshot in
            let seat = indexed[source]!
            let stack = amount(seat.stack)
            let wager = amount(seat.currentStreetWager)
                ?? (seat.streetWagerAreaClear != nil ? 0 : nil)
            let folded: Bool?
            if seat.folded != nil { folded = true }
            else if seat.allIn != nil || seat.positiveCards != nil || (source == 7 && heroTurn) { folded = false }
            else { folded = nil }
            return .init(id: source, stack: stack, streetWager: wager, folded: folded)
        }
        let rules = try evidence.blindText.flatMap { reading -> PokerGameRules? in
            guard reading.confidence >= 0.9 else { return nil }
            let text = reading.rawText.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "盲注", with: "").replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "：", with: "")
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3 else { return nil }
            let values = try parts.map { try ChipAmountParser.parse(String($0)) }
            return try PokerGameRules(smallBlind: values[0], bigBlind: values[1],
                utgStraddle: parts.count == 3 ? .optional(amount: values[2]) : .disabled)
        }
        let straddler = evidence.straddleSeat.flatMap { clockwiseSourceSeats.firstIndex(of: $0) }
        let optional: Bool?
        if straddler != nil { optional = true }
        else if let rules, rules.utgStraddle == .disabled { optional = false }
        else { optional = nil }
        return .init(seats: seats, hero: 4, cards: position.hero, board: position.board,
            pot: amount(evidence.raw["table.pot"]),
            button: evidence.dealerSeat.flatMap { clockwiseSourceSeats.firstIndex(of: $0) },
            actor: heroTurn ? 4 : nil, rules: rules, optionalStraddle: optional, straddleSeat: straddler)
    }
    private static func amount(_ text: WPKSnapshotTextEvidence?) -> Int? {
        guard let text, text.confidence >= 0.9 else { return nil }
        return try? ChipAmountParser.parse(text.rawText)
    }
}

struct FullTablePacket {
    let timestamp: Double
    let sessionGeneration: UInt64
    let position: LiveCardPosition
    let observation: LiveDecisionObservation
    let snapshot: PublicTableSnapshot?
    let milliseconds: Double
    let error: String?
}

/// Optional slower full-seat OCR has its own one-frame mailbox and exact crop cache.
/// It never runs in the card reader or queues an unbounded backlog of old images.
final class FullTableReadWorker {
    var onResult: ((FullTablePacket) -> Void)?
    private let queue = DispatchQueue(label: "com.lgj.pokercoach.full-table", qos: .utility)
    private let lock = NSLock()
    private let reader = WPKTableSnapshotReader()
    private var active = false, busy = false
    private var generation = 0
    private var lastOffered = 0.0
    private struct Input {
        let image: CGImage; let timestamp: Double; let sessionGeneration: UInt64; let generation: Int
        let position: LiveCardPosition; let observation: LiveDecisionObservation
    }
    private var pending: Input?
    func setActive(_ value: Bool) {
        lock.lock(); active = value; generation += 1; pending = nil; lastOffered = 0; lock.unlock()
    }
    func offer(_ image: CGImage, at timestamp: Double, sessionGeneration: UInt64,
               position: LiveCardPosition, observation: LiveDecisionObservation) {
        lock.lock()
        guard active, timestamp - lastOffered >= 0.33 else { lock.unlock(); return }
        lastOffered = timestamp
        pending = Input(image: image, timestamp: timestamp, sessionGeneration: sessionGeneration,
                        generation: generation, position: position, observation: observation)
        let schedule = !busy; busy = true; lock.unlock()
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock()
        guard active, let input = pending else { busy = false; pending = nil; lock.unlock(); return }
        pending = nil; lock.unlock()
        let started = ProcessInfo.processInfo.systemUptime
        if started - input.timestamp <= 0.8 {
            let packet: FullTablePacket = autoreleasepool {
                var snapshot: PublicTableSnapshot?, error: String?
                do {
                    snapshot = try WPKFullTableAdapter.snapshot(reader.read(input.image), position: input.position,
                        heroTurn: input.observation.actions.heroTurnConfirmed)
                } catch let caught { error = String(describing: caught) }
                return FullTablePacket(timestamp: input.timestamp, sessionGeneration: input.sessionGeneration,
                    position: input.position, observation: input.observation, snapshot: snapshot,
                    milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, error: error)
            }
            lock.lock(); let deliver = active && input.generation == generation; lock.unlock()
            if deliver { onResult?(packet) }
        }
        queue.async { [weak self] in self?.drain() }
    }
}
