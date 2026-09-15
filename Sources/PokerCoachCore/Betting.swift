import Foundation

public struct Seat: Sendable, Codable, Equatable {
    public let id: Int
    public var stack: Int
    public var committed: Int
    public var streetCommitted: Int
    public var folded: Bool
    /// Current bet when this seat last acted. nil = has not acted this street.
    public var actedAtBet: Int?
    public init(id: Int, stack: Int, committed: Int = 0, streetCommitted: Int = 0,
                folded: Bool = false, actedAtBet: Int? = nil) {
        self.id = id; self.stack = stack; self.committed = committed
        self.streetCommitted = streetCommitted; self.folded = folded; self.actedAtBet = actedAtBet
    }
}

public enum PokerAction: Hashable, Codable, Sendable, CustomStringConvertible {
    case fold, check, call, raiseTo(Int)
    public var description: String {
        switch self {
        case .fold: return "弃牌"
        case .check: return "过牌"
        case .call: return "跟注"
        case .raiseTo(let n): return "加注到 \(n)"
        }
    }
}

/// Chip amounts are integers in the table's smallest chip unit. The pot INCLUDES current bets.
/// Seat array is clockwise; pending contains indices, not external seat IDs.
public struct TableState: Sendable, Codable, Equatable {
    public var seats: [Seat]
    public var board: [Card]
    public let bigBlind: Int
    /// Explicit nominal preflop bring-in, such as a live straddle. nil preserves
    /// legacy ordinary-blind initialization and decoding. bigBlind never changes.
    public let preflopMinimum: Int?
    public let button: Int
    public var currentBet: Int
    public var lastFullRaise: Int
    public var pending: [Int]
    public var pot: Int { seats.reduce(0) { $0 + $1.committed } }
    public var actor: Int? { pending.first }
    public var live: [Int] { seats.indices.filter { !seats[$0].folded } }
    public var roundComplete: Bool { pending.isEmpty || live.count <= 1 }
    public var minimumBet: Int { board.isEmpty ? (preflopMinimum ?? bigBlind) : bigBlind }

    public init(seats: [Seat], board: [Card], bigBlind: Int, button: Int,
                currentBet: Int, lastFullRaise: Int, pending: [Int], preflopMinimum: Int? = nil) throws {
        self.seats = seats; self.board = board; self.bigBlind = bigBlind; self.button = button
        self.preflopMinimum = preflopMinimum
        self.currentBet = currentBet; self.lastFullRaise = lastFullRaise; self.pending = pending
        try validate()
    }

    public func validate() throws {
        guard (2...9).contains(seats.count), Set(seats.map(\.id)).count == seats.count,
              seats.indices.contains(button), bigBlind > 0, bigBlind <= 1_000_000_000,
              preflopMinimum.map({ $0 >= bigBlind && $0 <= 1_000_000_000 }) ?? true,
              lastFullRaise >= minimumBet, lastFullRaise <= 1_000_000_000,
              [0, 3, 4, 5].contains(board.count), Set(board).count == board.count,
              currentBet >= 0, currentBet <= 1_000_000_000,
              seats.allSatisfy({ $0.stack >= 0 && $0.committed >= $0.streetCommitted && $0.streetCommitted >= 0
                  && $0.stack <= 1_000_000_000 && $0.committed <= 1_000_000_000
                  && ($0.actedAtBet == nil || (0...currentBet).contains($0.actedAtBet!)) }),
              seats.map(\.streetCommitted).max()! <= currentBet,
              Set(pending).count == pending.count,
              pending.allSatisfy({ seats.indices.contains($0) && !seats[$0].folded && seats[$0].stack > 0 }),
              !live.isEmpty else { throw PokerError.invalid("牌桌状态不完整或金额/轮次不合法") }
        // A nominal preflop bring-in can exceed a short all-in blind's actual payment.
        guard currentBet == seats.map(\.streetCommitted).max()! || (board.isEmpty && currentBet == minimumBet) else {
            throw PokerError.invalid("当前下注额与已投入金额不一致")
        }
        if live.count > 1 {
            for i in live where seats[i].stack > 0 && amountToCall(i) > 0 {
                guard pending.contains(i) else { throw PokerError.invalid("遗漏尚需行动的玩家") }
            }
        }
    }

    public func amountToCall(_ i: Int) -> Int {
        let others = live.filter { $0 != i }
        let target: Int
        if others.allSatisfy({ seats[$0].stack == 0 }) {
            target = min(currentBet, others.map { seats[$0].streetCommitted }.max() ?? 0)
        } else { target = currentBet }
        return min(seats[i].stack, max(0, target - seats[i].streetCommitted))
    }
    public func mayRaise(_ i: Int) -> Bool {
        guard !seats[i].folded, seats[i].stack + seats[i].streetCommitted > currentBet,
              live.contains(where: { $0 != i && seats[$0].stack > 0
                  && seats[$0].stack + seats[$0].streetCommitted > currentBet }) else { return false }
        guard let previous = seats[i].actedAtBet, previous > 0 else { return true }
        return currentBet - previous >= lastFullRaise
    }
    /// No-limit requires a full raise above an incomplete all-in opening bet;
    /// e.g. a short opening 5 with BB 10 is raised to at least 15, not completed to 10.
    public var minimumRaiseTo: Int { currentBet + lastFullRaise }

    public func legalActions(potFractions: [Double] = [0.33, 0.5, 0.75, 1]) -> [PokerAction] {
        guard let i = actor, !roundComplete else { return [] }
        let toCall = amountToCall(i)
        var actions: [PokerAction] = toCall == 0 ? [.check] : [.fold, .call]
        guard mayRaise(i) else { return actions }
        let maximum = seats[i].streetCommitted + seats[i].stack
        if minimumRaiseTo <= maximum { actions.append(.raiseTo(minimumRaiseTo)) }
        for fraction in potFractions where fraction.isFinite && fraction > 0 && fraction <= 10 {
            // Raise by a fraction of the pot after calling; always express as total on this street.
            let amount = currentBet + Int((Double(pot + toCall) * fraction).rounded())
            if amount >= minimumRaiseTo && amount < maximum { actions.append(.raiseTo(amount)) }
        }
        actions.append(.raiseTo(maximum))
        return actions.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public func applying(_ action: PokerAction) throws -> TableState {
        guard let i = actor, !roundComplete else { throw PokerError.invalid("当前没有待行动玩家") }
        var next = self
        next.pending.removeFirst()
        func pay(_ amount: Int) {
            next.seats[i].stack -= amount
            next.seats[i].committed += amount
            next.seats[i].streetCommitted += amount
        }
        switch action {
        case .fold:
            next.seats[i].folded = true
        case .check:
            guard amountToCall(i) == 0 else { throw PokerError.invalid("面对下注不能过牌") }
        case .call:
            guard amountToCall(i) > 0 else { throw PokerError.invalid("无须跟注，请过牌") }
            pay(amountToCall(i))
        case .raiseTo(let target):
            let maximum = seats[i].streetCommitted + seats[i].stack
            guard mayRaise(i), target > currentBet, target <= maximum,
                  target >= minimumRaiseTo || target == maximum else { throw PokerError.invalid("加注额或加注权不合法") }
            pay(target - seats[i].streetCommitted)
            if target >= minimumRaiseTo {
                next.lastFullRaise = target - currentBet
            }
            next.currentBet = target
            next.pending = (1..<seats.count).map { (i + $0) % seats.count }.filter {
                !next.seats[$0].folded && next.seats[$0].stack > 0 && next.seats[$0].streetCommitted < target
            }
        }
        next.seats[i].actedAtBet = next.currentBet
        if next.live.count <= 1 { next.pending = [] }
        // When every opponent is all-in, an already matched seat has no further betting decision.
        let withChips = next.live.filter { next.seats[$0].stack > 0 }
        if withChips.count <= 1 {
            next.pending = next.pending.filter { next.amountToCall($0) > 0 }
        }
        return next
    }

    public func advancing(to newBoard: [Card]) throws -> TableState {
        let required = board.isEmpty ? 3 : board.count + 1
        guard roundComplete, live.count > 1, required <= 5, newBoard.count == required,
              Array(newBoard.prefix(board.count)) == board, Set(newBoard).count == newBoard.count else {
            throw PokerError.invalid("公共牌变化或换街时机不合法")
        }
        var next = self
        next.board = newBoard; next.currentBet = 0; next.lastFullRaise = bigBlind
        for i in seats.indices { next.seats[i].streetCommitted = 0; next.seats[i].actedAtBet = nil }
        next.pending = (1...seats.count).map { (button + $0) % seats.count }.filter { !seats[$0].folded && seats[$0].stack > 0 }
        if next.pending.count <= 1 { next.pending = [] }
        return next
    }
}

public struct PotLayer: Equatable, Sendable {
    public let amount: Int
    public let eligible: [Int]
    public let refundTo: Int?
}

public enum PotSettlement {
    public static func layers(seats: [Seat]) throws -> [PotLayer] {
        guard seats.allSatisfy({ $0.committed >= 0 && $0.committed <= 1_000_000_000 }) else { throw PokerError.invalid("底池投入无效") }
        let levels = Set(seats.map(\.committed).filter { $0 > 0 }).sorted()
        var previous = 0
        var pots: [PotLayer] = []
        for level in levels {
            let contributors = seats.indices.filter { seats[$0].committed >= level }
            let eligible = contributors.filter { !seats[$0].folded }
            let refund = contributors.count == 1 ? contributors[0] : nil
            guard refund != nil || !eligible.isEmpty else { throw PokerError.invalid("边池没有有资格的玩家") }
            var amount = (level - previous) * contributors.count
            // Dead contributions can introduce extra cut points without creating a
            // different pot. Merge adjacent layers with identical winning eligibility.
            if let last = pots.last, last.eligible == eligible, last.refundTo == refund {
                amount += last.amount
                pots.removeLast()
            }
            pots.append(PotLayer(amount: amount, eligible: eligible, refundTo: refund))
            previous = level
        }
        return pots
    }
    /// Fractional awards are appropriate for expected-value estimates; odd-chip handling is separate.
    public static func expectedAwards(seats: [Seat], values: [Int: HandValue]) throws -> [Double] {
        var awards = [Double](repeating: 0, count: seats.count)
        for pot in try layers(seats: seats) {
            if let refund = pot.refundTo { awards[refund] += Double(pot.amount); continue }
            let winners = try winners(pot, values)
            for i in winners { awards[i] += Double(pot.amount) / Double(winners.count) }
        }
        return awards
    }
    public static func integerAwards(seats: [Seat], values: [Int: HandValue], button: Int) throws -> [Int] {
        guard seats.indices.contains(button) else { throw PokerError.invalid("庄家位置无效") }
        var awards = [Int](repeating: 0, count: seats.count)
        for pot in try layers(seats: seats) {
            if let refund = pot.refundTo { awards[refund] += pot.amount; continue }
            let winners = try winners(pot, values).sorted { (($0 - button - 1 + seats.count) % seats.count) < (($1 - button - 1 + seats.count) % seats.count) }
            for (offset, i) in winners.enumerated() { awards[i] += pot.amount / winners.count + (offset < pot.amount % winners.count ? 1 : 0) }
        }
        return awards
    }
    private static func winners(_ pot: PotLayer, _ values: [Int: HandValue]) throws -> [Int] {
        if pot.eligible.count == 1 { return pot.eligible }
        guard pot.eligible.allSatisfy({ values[$0] != nil }) else { throw PokerError.invalid("摊牌牌力缺失") }
        let best = pot.eligible.map { values[$0]! }.max()!
        return pot.eligible.filter { values[$0] == best }
    }
}
