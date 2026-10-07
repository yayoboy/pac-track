/// A user-facing validation error. `message` matches the M1 engine's texts.
struct EngineError: Error, CustomStringConvertible, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
