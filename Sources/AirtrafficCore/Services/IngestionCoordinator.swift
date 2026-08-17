import Foundation

/// Owns the (non-Sendable, stateful) adapters and runs scans off the main thread.
public actor IngestionCoordinator {
    private let adapters: [any AgentAdapter]

    public init(adapters: [any AgentAdapter]) {
        self.adapters = adapters
    }

    /// Convenience: all three built-in adapters against their default roots.
    public static func standard(config: ScanConfig = .default) -> IngestionCoordinator {
        IngestionCoordinator(adapters: [
            ClaudeCodeAdapter(config: config),
            CodexAdapter(config: config),
            GrokAdapter(config: config),
        ])
    }

    /// One scan pass across all agents. Adapter failures are isolated so one
    /// broken transcript never hides the other agents' sessions.
    public func scan(now: Date = Date()) -> [SessionSnapshot] {
        var snapshots: [SessionSnapshot] = []
        for adapter in adapters {
            if let result = try? adapter.scan(now: now) {
                snapshots.append(contentsOf: result)
            }
        }
        return snapshots.sorted { lhs, rhs in
            if lhs.status.sortOrder != rhs.status.sortOrder {
                return lhs.status.sortOrder < rhs.status.sortOrder
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }
}
