import Agentic
import Foundation

/// Live benchmarking uses the same routed-model API as Agentic. The caller
/// supplies a configured invoker (provider, gateway, credentials and route),
/// plus an independent evaluator. This library does not own any credentials.
public struct RoutedContextProbe: ContextBenchmark.Probe {
    public typealias Evaluator = @Sendable (AgentResponse, String) async throws -> Bool
    public typealias Cost = @Sendable (AgentModelInvocation.Result) -> Double?

    public let invoker: any AgentModelInvoking
    public let selection: AgentModelSelection
    public let evaluator: Evaluator
    public let cost: Cost?

    public init(
        invoker: any AgentModelInvoking,
        selection: AgentModelSelection = .executor,
        evaluator: @escaping Evaluator,
        cost: Cost? = nil
    ) {
        self.invoker = invoker
        self.selection = selection
        self.evaluator = evaluator
        self.cost = cost
    }

    public func observe(
        _ request: AgentRequest,
        expected: String
    ) async throws -> ContextBenchmark.Observation {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await invoker.buffered(.init(
            request: request,
            selection: selection
        ))
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let passed = try await evaluator(result.response, expected)
        return ContextBenchmark.Observation(
            measuredInputTokens: result.response.usage?.inputTokens,
            measuredOutputTokens: result.response.usage?.outputTokens,
            costUSD: cost?(result),
            wallSeconds: seconds,
            taskPassed: passed
        )
    }
}
