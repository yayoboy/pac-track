import PacEngine

public protocol EngineClient: Sendable {
    /// Applies `cmd` and returns the snapshot that includes it; throws the engine's error.
    func send(_ cmd: Command) async throws -> Snapshot
    func advance(wallMs: Double) async -> Snapshot
    /// Log entries from `seq` on; empty when `epoch` is no longer current (the network was reloaded).
    func events(from seq: Int, epoch: Int) async -> [EventView]
    /// Header-by-header view of one logged frame; nil once it left the log or the network was reloaded.
    func pdu(_ seq: Int, epoch: Int) async -> [PduLayer]?
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

    public func events(from seq: Int, epoch: Int) -> [EventView] {
        epoch == runtime.epoch ? runtime.events(from: seq) : []
    }

    public func pdu(_ seq: Int, epoch: Int) -> [PduLayer]? {
        epoch == runtime.epoch ? runtime.pdu(seq) : nil
    }
}
