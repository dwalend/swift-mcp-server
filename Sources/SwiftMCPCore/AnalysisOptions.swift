import Foundation

public struct AnalysisOptions: Codable, Equatable, Sendable {
    public let enableArchitectureDetection: Bool

    public init(enableArchitectureDetection: Bool = false) {
        self.enableArchitectureDetection = enableArchitectureDetection
    }
}

public struct MCPRuntimeConfiguration: Codable, Equatable, Sendable {
    public let analysis: AnalysisOptions

    public init(analysis: AnalysisOptions = AnalysisOptions()) {
        self.analysis = analysis
    }
}
