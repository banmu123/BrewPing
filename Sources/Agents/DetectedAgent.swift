import Foundation

struct DetectedAgent: Codable {
    let id: String
    let name: String
    let command: String
    let installed: Bool
    let version: String?
    let path: String?
}

struct AgentDefinition {
    let id: String
    let name: String
    let command: String
    let versionArguments: [String]
}
