import Foundation

public struct DetectedAgent: Codable {
    public let id: String
    public let name: String
    public let command: String
    public let installed: Bool
    public let version: String?
    public let path: String?
}

public struct AgentDefinition {
    public let id: String
    public let name: String
    public let command: String
    public let versionArguments: [String]
}
