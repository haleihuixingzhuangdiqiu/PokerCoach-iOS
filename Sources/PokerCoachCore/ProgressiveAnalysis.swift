import Foundation

public enum AnalysisPhase: String, Codable, Sendable { case preview, refined }
public struct AnalysisUpdate: Sendable {
    public let ticket: AnalysisTicket
    public let phase: AnalysisPhase
    public let result: DecisionResult
}

public enum ProgressiveAnalysis {
    /// The caller cancels consumption on any state change and checks ObservationGate.accepts before display.
    /// The stream owns a cancellable background task; cancelling it stops ongoing simulations at checkpoints.
    public static func updates(ticket: AnalysisTicket, ranges: [Int: HandRange],
                               preview: ComputeBudget = .init(samples: 1000, milliseconds: 150),
                               refined: ComputeBudget = .init(samples: 12000, milliseconds: 600)) -> AsyncThrowingStream<AnalysisUpdate, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    for (phase, budget) in [(AnalysisPhase.preview, preview), (.refined, refined)] {
                        try Task.checkCancellation()
                        let t = ticket.table
                        let result = try DecisionEngine.analyze(state: t.state, hero: t.hero, cards: t.holeCards,
                                                               ranges: ranges, budget: budget, isCancelled: { Task.isCancelled })
                        try Task.checkCancellation()
                        continuation.yield(AnalysisUpdate(ticket: ticket, phase: phase, result: result))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}
