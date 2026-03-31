import Foundation
import Logging

/// Symbol search backed by the semantic AST index.
public class SymbolSearchEngine {
    private let projectPath: URL
    private let logger: Logger
    private let semanticIndex: SemanticProjectIndex
    
    public init(projectPath: URL, logger: Logger) {
        self.projectPath = projectPath
        self.logger = logger
        self.semanticIndex = SemanticProjectIndexCache.shared.index(for: projectPath, logger: logger)
    }
    
    /// Find symbols with syntax-aware filtering.
    public func findSymbols(
        namePattern: String = "",
        symbolType: String = "",
        useRegex: Bool = false,
        includePrivate: Bool = false,
        includeInherited: Bool = false
    ) async throws -> [SymbolInfo] {
        logger.debug("🔍 Searching symbols with pattern: \(namePattern), type: \(symbolType)")

        let snapshot = try await semanticIndex.snapshot()
        let allowedKinds = normalizedKinds(for: symbolType)
        _ = includeInherited

        return snapshot.declarations
            .filter { declaration in
                (allowedKinds.isEmpty || allowedKinds.contains(declaration.kind)) &&
                (includePrivate || declaration.accessLevel != "private" && declaration.accessLevel != "fileprivate")
            }
            .filter { declaration in
                matches(name: declaration.name, pattern: namePattern, useRegex: useRegex)
            }
            .map(makeSymbolInfo)
            .sorted {
                if $0.location.uri == $1.location.uri {
                    if $0.location.line == $1.location.line {
                        return $0.location.character < $1.location.character
                    }
                    return $0.location.line < $1.location.line
                }
                return $0.location.uri < $1.location.uri
            }
    }
    
    /// Find all syntax-level references to a symbol.
    public func findReferences(
        symbolName: String,
        symbolType: String = "",
        includeComments: Bool = false
    ) async throws -> [ReferenceInfo] {
        logger.debug("📍 Finding references for symbol: \(symbolName)")

        let snapshot = try await semanticIndex.snapshot()
        let allowedKinds = Set(normalizedKinds(for: symbolType))

        return snapshot.references
            .filter { $0.name == symbolName }
            .filter { reference in
                guard !allowedKinds.isEmpty else { return true }
                if reference.kind == .declaration {
                    return snapshot.declarations.contains {
                        $0.name == symbolName &&
                        $0.line == reference.line &&
                        $0.fileURL == reference.fileURL &&
                        allowedKinds.contains($0.kind)
                    }
                }
                return true
            }
            .map { reference in
                ReferenceInfo(
                    symbolName: symbolName,
                    file: reference.fileURL.path,
                    line: reference.line,
                    character: reference.character,
                    context: reference.context,
                    usageType: reference.kind.rawValue
                )
            }
    }
    
    /// Get type hierarchy based on semantic inheritance information.
    public func getSymbolHierarchy(symbolName: String) async throws -> SymbolHierarchy {
        logger.debug("🏗️ Building hierarchy for symbol: \(symbolName)")

        let snapshot = try await semanticIndex.snapshot()
        guard let targetType = snapshot.types.first(where: { $0.name == symbolName && isTypeLike(kind: $0.kind) }) else {
            throw SwiftMCPError.lspNotInitialized
        }

        let parents = snapshot.types
            .filter { targetType.inheritedTypes.contains($0.name) }
            .map(makeTypeSymbolInfo)

        let children = snapshot.types
            .filter { $0.inheritedTypes.contains(symbolName) }
            .map(makeTypeSymbolInfo)

        return SymbolHierarchy(
            symbol: makeTypeSymbolInfo(targetType),
            parents: parents,
            children: children
        )
    }
    
    /// Analyze symbol usage patterns from semantic reference contexts.
    public func analyzeSymbolUsage(symbolName: String) async throws -> SymbolUsageAnalysis {
        logger.debug("📊 Analyzing usage for symbol: \(symbolName)")

        let references = try await findReferences(symbolName: symbolName)

        var usagePatterns: [String: Int] = [:]
        var fileDistribution: [String: Int] = [:]

        for reference in references {
            let pattern = reference.context.trimmingCharacters(in: .whitespacesAndNewlines)
            usagePatterns[pattern, default: 0] += 1
            fileDistribution[reference.file, default: 0] += 1
        }

        return SymbolUsageAnalysis(
            symbolName: symbolName,
            totalReferences: references.count,
            uniqueFiles: fileDistribution.count,
            usagePatterns: usagePatterns,
            fileDistribution: fileDistribution,
            mostUsedIn: fileDistribution.max(by: { $0.value < $1.value })?.key
        )
    }

    // MARK: - Helpers

    private func normalizedKinds(for symbolType: String) -> Set<String> {
        guard !symbolType.isEmpty else {
            return []
        }

        switch symbolType {
        case "function":
            return ["function"]
        case "property":
            return ["property"]
        default:
            return [symbolType]
        }
    }

    private func matches(name: String, pattern: String, useRegex: Bool) -> Bool {
        guard !pattern.isEmpty else {
            return true
        }

        if useRegex {
            return name.range(of: pattern, options: .regularExpression) != nil
        }

        return name.localizedCaseInsensitiveContains(pattern)
    }

    private func isTypeLike(kind: String) -> Bool {
        ["class", "struct", "enum", "protocol", "actor"].contains(kind)
    }

    private func makeSymbolInfo(from declaration: SemanticDeclaration) -> SymbolInfo {
        SymbolInfo(
            name: declaration.name,
            kind: declaration.kind,
            location: Location(
                uri: "file://\(declaration.fileURL.path)",
                line: max(0, declaration.line - 1),
                character: declaration.character
            ),
            containerName: declaration.containerName,
            detail: declaration.kind + " " + declaration.name
        )
    }

    private func makeTypeSymbolInfo(_ typeSummary: SemanticTypeSummary) -> SymbolInfo {
        SymbolInfo(
            name: typeSummary.name,
            kind: typeSummary.kind,
            location: Location(
                uri: "file://\(typeSummary.fileURL.path)",
                line: max(0, typeSummary.line - 1),
                character: typeSummary.character
            ),
            containerName: nil,
            detail: typeSummary.kind + " " + typeSummary.name
        )
    }
}

// MARK: - Supporting Types

public struct ReferenceInfo {
    public let symbolName: String
    public let file: String
    public let line: Int
    public let character: Int
    public let context: String
    public let usageType: String
    
    public init(symbolName: String, file: String, line: Int, character: Int, context: String, usageType: String) {
        self.symbolName = symbolName
        self.file = file
        self.line = line
        self.character = character
        self.context = context
        self.usageType = usageType
    }
}

public struct SymbolHierarchy {
    public let symbol: SymbolInfo
    public let parents: [SymbolInfo]
    public let children: [SymbolInfo]
    
    public init(symbol: SymbolInfo, parents: [SymbolInfo], children: [SymbolInfo]) {
        self.symbol = symbol
        self.parents = parents
        self.children = children
    }
}

public struct SymbolUsageAnalysis {
    public let symbolName: String
    public let totalReferences: Int
    public let uniqueFiles: Int
    public let usagePatterns: [String: Int]
    public let fileDistribution: [String: Int]
    public let mostUsedIn: String?
    
    public init(symbolName: String, totalReferences: Int, uniqueFiles: Int, usagePatterns: [String: Int], fileDistribution: [String: Int], mostUsedIn: String?) {
        self.symbolName = symbolName
        self.totalReferences = totalReferences
        self.uniqueFiles = uniqueFiles
        self.usagePatterns = usagePatterns
        self.fileDistribution = fileDistribution
        self.mostUsedIn = mostUsedIn
    }
}
