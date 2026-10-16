import Agentic
import AgenticContext

public enum ContextEvidenceBenchmark {
    public struct Report: Codable, Sendable, Hashable {
        public let relevantSelected: Bool
        public let irrelevantExcluded: Bool
        public let findingRehydrated: Bool
        public let staleFindingExcluded: Bool
    }

    private actor Fixture: Context.RecordResolving {
        private var version = "v1"
        func changeRevision() { version = "v2" }
        func resolve(_ pointer: Context.Pointer) async throws -> Context.Resolved {
            let current = pointer.record == "original" ? version : "finding-v1"
            return .init(pointer: .init(source: pointer.source,
                                        record: pointer.record,
                                        selection: pointer.selection,
                                        revision: .recorded(current)),
                         messages: [.init(id: "evidence.\(pointer.record)",
                                          role: .assistant,
                                          content: .init(text: "corrected_invocation_use_safe_mode"))])
        }
    }

    public enum Failure: Error { case regression }

    public static func run() async throws -> Report {
        let fixture = Fixture()
        let correction = Context.Record(id: "tool-correction", kind: "finding",
            pointer: .init(source: "fixture", record: "finding",
                           revision: .recorded("finding-v1")),
            derivedFrom: [.init(source: "fixture", record: "original",
                                revision: .recorded("v1"))])
        let unrelated = Context.Record(id: "weather", kind: "finding",
            pointer: .init(source: "fixture", record: "weather",
                           revision: .recorded("finding-v1")),
            derivedFrom: [.init(source: "fixture", record: "original",
                                revision: .recorded("v1"))])
        let index = try Context.FindingIndex([
            .init(record: correction, terms: ["tool", "correction"]),
            .init(record: unrelated, terms: ["weather"])
        ])
        let entries = try await index.eligible(for: "tool correction", maximum: 3,
                                               using: fixture)
        let relevant = entries.map(\.record.id).contains("tool-correction")
        let irrelevant = !entries.map(\.record.id).contains("weather")
        let allocator = try Context.Allocator()
        try await allocator.createWorkingSet(id: "benchmark-evidence")
        try await allocator.apply(entries.map {
            .allocate(Context.FindingIndex.allocation(for: $0, required: true))
        }, to: "benchmark-evidence")
        let frame = try await allocator.prepareFrame(for: "benchmark-evidence",
            using: fixture, modelContextLimit: 100_000)
        let rehydrated = frame.messages.contains { $0.content.text.contains("corrected_invocation") }
        await fixture.changeRevision()
        let stale = try await index.eligible(for: "tool correction", maximum: 3,
                                             using: fixture)
        let report = Report(relevantSelected: relevant,
                            irrelevantExcluded: irrelevant,
                            findingRehydrated: rehydrated,
                            staleFindingExcluded: stale.isEmpty)
        guard relevant && irrelevant && rehydrated && stale.isEmpty else {
            throw Failure.regression
        }
        return report
    }
}
