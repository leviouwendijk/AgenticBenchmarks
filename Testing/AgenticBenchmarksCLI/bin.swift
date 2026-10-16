import AgenticBenchmarks
import Foundation

private enum BenchmarkExpectationError: Error {
    case insufficientReduction
    case lostRetainedFinding
    case invalidBaseline
}

@main
enum BenchmarkMain {
    static func main() async throws {
        let report = try await ContextBenchmark.run()
        guard let accumulating = report.aggregates.first(where: { $0.strategy == .accumulating }),
              let dynamic = report.aggregates.first(where: { $0.strategy == .dynamic }),
              let retained = report.aggregates.first(where: { $0.strategy == .dynamic_with_finding })
        else { throw BenchmarkExpectationError.invalidBaseline }
        guard dynamic.cumulativeEstimatedInputTokens < accumulating.cumulativeEstimatedInputTokens
        else { throw BenchmarkExpectationError.insufficientReduction }
        guard retained.missingEvidenceAfterLearning == 0
        else { throw BenchmarkExpectationError.lostRetainedFinding }
        guard accumulating.missingEvidenceAfterLearning == 0
        else { throw BenchmarkExpectationError.invalidBaseline }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    }
}
