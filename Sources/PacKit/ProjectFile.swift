import Foundation
import PacEngine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static let pacTrackProject = UTType(exportedAs: "com.pactrack.project")
}

public enum ProjectFile {
    public static func encode(_ t: Topology) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(t)
    }

    public static func decode(_ data: Data) throws -> Topology {
        let t: Topology
        do {
            t = try JSONDecoder().decode(Topology.self, from: data)
        } catch {
            throw EngineError("Not a Pac-Track project file")
        }
        guard t.version == 1 else { throw EngineError("Unsupported or corrupt project file") }
        return t
    }
}

public struct PacDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.pacTrackProject] }
    public var topology: Topology

    public init(topology: Topology = .empty) {
        self.topology = topology
    }

    public init(configuration: ReadConfiguration) throws {
        topology = try ProjectFile.decode(configuration.file.regularFileContents ?? Data())
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ProjectFile.encode(topology))
    }
}
