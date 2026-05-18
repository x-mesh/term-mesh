import Foundation

struct CliProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var family: String
    var executable: String
    var extraArgs: [String] = []
    var env: [String: String] = [:]
    var modelOverride: String? = nil
}
