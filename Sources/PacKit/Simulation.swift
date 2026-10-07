import PacEngine

public protocol EngineClient: Sendable {
    /// Applies `cmd` and returns the snapshot that includes it; throws the engine's error.
    func send(_ cmd: Command) async throws -> Snapshot
    func advance(wallMs: Double) async -> Snapshot
}

/// Confines one `Runtime` (and its engine objects) to an actor.
public actor Simulation: EngineClient {
    private let runtime = Runtime()

    public init() {}

    public func send(_ cmd: Command) throws -> Snapshot {
        try runtime.handle(cmd)
        return runtime.snapshot()
    }

    public func advance(wallMs: Double) -> Snapshot {
        runtime.advance(wallMs: wallMs)
        return runtime.snapshot()
    }
}
