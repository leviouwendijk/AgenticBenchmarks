import Agentic
import AgenticContext
import Foundation

/// Provider-neutral inference-request benchmark. Estimates are NOT actual
/// provider usage; real measurements require an injected Probe.
public enum ContextBenchmark {
    public enum Strategy: String, Codable, Sendable, CaseIterable {
        case accumulating
        case dynamic
        case dynamic_with_finding
    }

    public struct Scenario: Sendable {
        public let turns: Int
        public let payloadRepeats: Int
        public let history: Context.HistoryPolicy

        public init(turns: Int = 14, payloadRepeats: Int = 70,
                    history: Context.HistoryPolicy = .init(maximumTurns: 2, maximumTokens: 4_000)) {
            self.turns = turns
            self.payloadRepeats = payloadRepeats
            self.history = history
        }
    }

    /// Optional actual-inference observations. Never infer correctness or real
    /// token usage from the lexical estimate. Probe owns task evaluation.
    public struct Observation: Sendable, Codable, Hashable {
        public let measuredInputTokens: Int?
        public let measuredOutputTokens: Int?
        public let costUSD: Double?
        public let wallSeconds: Double?
        public let taskPassed: Bool?

        public init(measuredInputTokens: Int? = nil,
                    measuredOutputTokens: Int? = nil, costUSD: Double? = nil,
                    wallSeconds: Double? = nil, taskPassed: Bool? = nil) {
            self.measuredInputTokens = measuredInputTokens
            self.measuredOutputTokens = measuredOutputTokens
            self.costUSD = costUSD
            self.wallSeconds = wallSeconds
            self.taskPassed = taskPassed
        }
    }

    public protocol Probe: Sendable {
        func observe(_ request: AgentRequest, expected: String) async throws -> Observation
    }

    public struct Sample: Sendable, Codable, Hashable {
        public let strategy: Strategy
        public let turn: Int
        public let estimatedInputTokens: Int
        public let semanticRequestBytes: Int
        public let retainedHistoryMessages: Int
        public let omittedHistoryMessages: Int
        public let selectedAllocations: Int
        /// Deterministic availability check; this does NOT measure model understanding.
        public let evidenceMarkerPresent: Bool
        public let observation: Observation?
    }

    public struct Aggregate: Sendable, Codable, Hashable {
        public let strategy: Strategy
        public let inferences: Int
        public let cumulativeEstimatedInputTokens: Int
        public let peakEstimatedInputTokens: Int
        public let missingEvidenceAfterLearning: Int
        public let measuredInputTokens: Int?
        public let measuredOutputTokens: Int?
        public let measuredCostUSD: Double?
        public let measuredWallSeconds: Double?
        public let passedTasks: Int?
    }

    public struct Report: Sendable, Codable, Hashable {
        public let scenarioTurns: Int
        public let estimatesOnly: Bool
        public let samples: [Sample]
        public let aggregates: [Aggregate]
        public let evidenceLifecycle: ContextEvidenceBenchmark.Report
    }

    public enum Failure: Error, Sendable {
        case invalidScenario
    }

    private static let marker = "corrected_invocation_use_safe_mode"

    private struct Resolver: Context.RecordResolving {
        func resolve(_ pointer: Context.Pointer) async throws -> Context.Resolved {
            .init(pointer: .init(source: pointer.source, record: pointer.record,
                    selection: pointer.selection, revision: .recorded("tool-fixture-v1")),
                  messages: [.init(id: "context.known_tool_correction", role: .assistant,
                                   content: .init(text: "Verified tool correction: " + marker))])
        }
    }

    private static func request(through turn: Int, repeats: Int) -> AgentRequest {
        var messages: [Message] = [
            .init(id: "system", role: .system,
                  content: .init(text: "Finish the task, respecting observed tool corrections."))
        ]
        for index in 0..<turn {
            let payload = String(repeating: "Routine task context. ", count: repeats)
            messages.append(.init(id: "user-\(index)", role: .user,
                                  content: .init(text: "Step \(index): " + payload)))
            if index < turn - 1 {
                let completion = index == 1
                    ? "A tool invocation failed; verified correction: " + marker
                    : "Completed step \(index). " + payload
                messages.append(.init(id: "assistant-\(index)", role: .assistant,
                                      content: .init(text: completion)))
            }
        }
        return AgentRequest(messages: messages)
    }

    public static func run(
        _ scenario: Scenario = .init(),
        probe: (any Probe)? = nil
    ) async throws -> Report {
        guard scenario.turns >= 5, scenario.payloadRepeats > 0 else {
            throw Failure.invalidScenario
        }
        let policy = Context.Policy(
            preferredInputTokens: 80_000, maximumInputTokens: 100_000,
            reservedOutputTokens: 2_000, maximumResolutions: 8,
            history: scenario.history
        )
        var samples: [Sample] = []
        let empty = Context.Frame(workingSetID: "bench", items: [],
            skippedAllocationIDs: [], inputBudget: 100_000, estimatedInputTokens: 0)

        for strategy in Strategy.allCases {
            let allocator = try Context.Allocator(policy: policy)
            try await allocator.createWorkingSet(id: "bench")
            for turn in 1...scenario.turns {
                if strategy == .dynamic_with_finding && turn == 4 {
                    try await allocator.apply([.allocate(.init(
                        id: "known-tool-correction", pointer: .init(
                            source: "fixture", record: "tool-outcome",
                            revision: .recorded("tool-fixture-v1")),
                        representation: .facts, priority: 100, required: true
                    ))], to: "bench")
                }
                let request = request(through: turn, repeats: scenario.payloadRepeats)
                let prepared: Context.InferencePreparation
                if strategy == .accumulating {
                    prepared = try Context.InferencePreparer.prepare(
                        request: request, frame: empty, delivery: .supplement,
                        maximumInputTokens: 98_000
                    )
                } else {
                    prepared = try await allocator.prepareDynamic(
                        request: request, for: "bench", using: Resolver(),
                        modelContextLimit: 100_000
                    )
                }
                let materializedText = prepared.request.messages
                    .map { message in message.content.blocks.map(String.init(describing:)).joined(separator: " ") }
                    .joined(separator: " ")
                let evidencePresent = materializedText.contains(marker)
                let observation = try await probe?.observe(
                    prepared.request, expected: marker
                )
                samples.append(.init(
                    strategy: strategy, turn: turn,
                    estimatedInputTokens: prepared.measurement.estimatedInputTokens,
                    semanticRequestBytes: prepared.measurement.serializedRequestBytes,
                    retainedHistoryMessages: prepared.history.retained.count,
                    omittedHistoryMessages: prepared.history.omitted.count,
                    selectedAllocations: prepared.measurement.selectedAllocations,
                    evidenceMarkerPresent: evidencePresent,
                    observation: observation
                ))
            }
        }

        let aggregates = Strategy.allCases.map { strategy in
            let rows = samples.filter { $0.strategy == strategy }
            let measured = rows.compactMap(\.observation)
            let allObserved = measured.count == rows.count
            return Aggregate(
                strategy: strategy, inferences: rows.count,
                cumulativeEstimatedInputTokens: rows.reduce(0) { $0 + $1.estimatedInputTokens },
                peakEstimatedInputTokens: rows.map(\.estimatedInputTokens).max() ?? 0,
                missingEvidenceAfterLearning: rows.filter { $0.turn >= 4 && !$0.evidenceMarkerPresent }.count,
                measuredInputTokens: allObserved && measured.allSatisfy({ $0.measuredInputTokens != nil })
                    ? measured.compactMap(\.measuredInputTokens).reduce(0,+) : nil,
                measuredOutputTokens: allObserved && measured.allSatisfy({ $0.measuredOutputTokens != nil })
                    ? measured.compactMap(\.measuredOutputTokens).reduce(0,+) : nil,
                measuredCostUSD: allObserved && measured.allSatisfy({ $0.costUSD != nil })
                    ? measured.compactMap(\.costUSD).reduce(0,+) : nil,
                measuredWallSeconds: allObserved && measured.allSatisfy({ $0.wallSeconds != nil })
                    ? measured.compactMap(\.wallSeconds).reduce(0,+) : nil,
                passedTasks: allObserved && measured.allSatisfy({ $0.taskPassed != nil })
                    ? measured.filter { $0.taskPassed == true }.count : nil
            )
        }
        return Report(scenarioTurns: scenario.turns, estimatesOnly: samples.contains { $0.observation?.measuredInputTokens == nil },
                      samples: samples, aggregates: aggregates,
                      evidenceLifecycle: try await ContextEvidenceBenchmark.run())
    }
}
