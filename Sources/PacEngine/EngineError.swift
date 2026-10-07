/// A user-facing validation error. `message` matches the M1 engine's texts.
public struct EngineError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
