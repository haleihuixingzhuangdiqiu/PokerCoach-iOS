import Foundation

/// A single live straddle at the seat immediately after the big blind.
/// Optional straddles require the full amount. Mandatory means an explicitly
/// configured third blind, including its nominal bring-in when the poster is short.
public enum UTGStraddlePolicy: Sendable, Codable, Equatable {
    case disabled
    case optional(amount: Int)
    case mandatory(amount: Int)
}

/// Clockwise indices of players dealt into this hand, not external seat IDs.
public struct PokerPositions: Sendable, Codable, Equatable {
    public let button: Int
    public let smallBlind: Int
    public let bigBlind: Int
    public let underTheGun: Int
    public let straddle: Int?
    /// Includes all dealt seats; TableState.pending removes players already all-in.
    public let preflopOrder: [Int]
    public let postflopOrder: [Int]
}

public struct ForcedBetPosting: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case ante, smallBlind, bigBlind, straddle }
    public let seat: Int
    public let kind: Kind
    public let nominalAmount: Int
    public let paidAmount: Int
}

public struct PokerHandStart: Sendable, Codable, Equatable {
    public let state: TableState
    public let positions: PokerPositions
    public let forcedBets: [ForcedBetPosting]
}

/// No-limit hold'em rules for 2...9 dealt players, normal blinds and at most
/// one UTG live straddle. Does not imply support for button/Mississippi or double straddles.
/// All amounts use the same integer chip unit as TableState (WPK adapter: 100 units = 1).
public struct PokerGameRules: Sendable, Codable, Equatable {
    public let smallBlind: Int
    public let bigBlind: Int
    /// Equal ante per dealt player, separate from live street wagers. Zero by default.
    public let ante: Int
    public let utgStraddle: UTGStraddlePolicy

    public init(smallBlind: Int, bigBlind: Int, ante: Int = 0,
                utgStraddle: UTGStraddlePolicy = .disabled) throws {
        self.smallBlind = smallBlind; self.bigBlind = bigBlind
        self.ante = ante; self.utgStraddle = utgStraddle
        try validate()
    }

    public func validate() throws {
        guard smallBlind > 0, smallBlind <= bigBlind, bigBlind <= 1_000_000_000,
              ante >= 0, ante <= 1_000_000_000 else { throw PokerError.invalid("盲注或前注配置无效") }
        switch utgStraddle {
        case .disabled: break
        case .optional(let amount), .mandatory(let amount):
            guard amount >= 2 * bigBlind, amount <= 1_000_000_000 else {
                throw PokerError.invalid("仅支持至少两倍大盲的一档UTG第三盲")
            }
        }
    }

    /// Starts from players' balances BEFORE forced bets. Rejects an already-progressed
    /// hand rather than silently discarding its contributions or fold history.
    public func startHand(seats: [Seat], button: Int, optionalStraddle: Bool = false) throws -> PokerHandStart {
        try validate()
        guard (2...9).contains(seats.count), seats.indices.contains(button),
              Set(seats.map(\.id)).count == seats.count,
              seats.allSatisfy({ $0.stack > 0 && $0.stack <= 1_000_000_000 && $0.committed == 0
                  && $0.streetCommitted == 0 && !$0.folded && $0.actedAtBet == nil }) else {
            throw PokerError.invalid("开手需要2–9名实际参与者、有效庄家和未投入的初始筹码")
        }
        let straddleAmount: Int?
        switch utgStraddle {
        case .disabled:
            guard !optionalStraddle else { throw PokerError.invalid("本桌未启用可选第三盲") }
            straddleAmount = nil
        case .optional(let amount): straddleAmount = optionalStraddle ? amount : nil
        case .mandatory(let amount): straddleAmount = amount
        }
        guard straddleAmount == nil || seats.count >= 3 else {
            throw PokerError.invalid("单挑不支持UTG第三盲；不能将庄家盲注当成第三盲")
        }
        let n = seats.count
        let small = n == 2 ? button : (button + 1) % n
        let big = (small + 1) % n
        let utg = (big + 1) % n
        let straddler = straddleAmount.map { _ in utg }
        let first = straddler.map { ($0 + 1) % n } ?? utg
        let positions = PokerPositions(button: button, smallBlind: small, bigBlind: big,
            underTheGun: utg, straddle: straddler,
            preflopOrder: (0..<n).map { (first + $0) % n },
            postflopOrder: (1...n).map { (button + $0) % n })

        var posted = seats
        var records: [ForcedBetPosting] = []
        func post(_ index: Int, _ kind: ForcedBetPosting.Kind, _ nominal: Int, live: Bool) {
            let amount = min(posted[index].stack, nominal)
            posted[index].stack -= amount
            posted[index].committed += amount
            if live { posted[index].streetCommitted += amount }
            records.append(.init(seat: index, kind: kind, nominalAmount: nominal, paidAmount: amount))
        }
        if ante > 0 { for i in posted.indices { post(i, .ante, ante, live: false) } }
        post(small, .smallBlind, smallBlind, live: true)
        post(big, .bigBlind, bigBlind, live: true)
        if let straddler, let straddleAmount {
            if case .optional = utgStraddle, posted[straddler].stack < straddleAmount {
                throw PokerError.invalid("可选live第三盲需足额投入；短筹码第三盲需要明确强制桌规")
            }
            post(straddler, .straddle, straddleAmount, live: true)
        }
        let bringIn = straddleAmount ?? bigBlind
        var pending = positions.preflopOrder.filter { posted[$0].stack > 0 }
        // A single funded player has no blind option when all opponents are all-in.
        // They only need to match the largest ACTUAL live wager, never phantom chips.
        if pending.count == 1, let i = pending.first {
            let actualOpponentBet = posted.indices.filter { $0 != i }.map { posted[$0].streetCommitted }.max() ?? 0
            if posted[i].streetCommitted >= actualOpponentBet { pending = [] }
        }
        let state = try TableState(seats: posted, board: [], bigBlind: bigBlind, button: button,
            currentBet: bringIn, lastFullRaise: bringIn, pending: pending, preflopMinimum: bringIn)
        return PokerHandStart(state: state, positions: positions, forcedBets: records)
    }
}
