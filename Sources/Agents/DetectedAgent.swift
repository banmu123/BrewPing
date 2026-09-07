import Foundation

public struct DetectedAgent: Codable {
    public let id: String
    public let name: String
    public let command: String
    public let installed: Bool
    public let version: String?
    public let path: String?
}

struct AgentDefinition {
    let id: String
    let name: String
    let command: String
    let versionArguments: [String]
}
