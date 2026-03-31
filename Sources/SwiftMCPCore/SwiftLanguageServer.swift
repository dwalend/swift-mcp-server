import Foundation
import Logging

/// Swift Language Server that provides Swift language intelligence through SourceKit-LSP integration.
public final class SwiftLanguageServer {
    private static let symbolKindNames: [Int: String] = [
        1: "file",
        2: "module",
        3: "namespace",
        4: "package",
        5: "class",
        6: "method",
        7: "property",
        8: "field",
        9: "constructor",
        10: "enum",
        11: "interface",
        12: "function",
        13: "variable",
        14: "constant",
        15: "string",
        16: "number",
        17: "boolean",
        18: "array",
        19: "object",
        20: "key",
        21: "null",
        22: "enumMember",
        23: "struct",
        24: "event",
        25: "operator",
        26: "typeParameter"
    ]

    private let logger: Logger
    private let workspaceRoot: URL
    private let sourceKitLSPPath: String
    private let sourceKitLSPClient: SourceKitLSPClient
    private var isInitialized: Bool = false

    /// The workspace root URL
    public var workspaceURL: URL {
        workspaceRoot
    }

    public init(logger: Logger, workspaceRoot: URL? = nil) {
        self.logger = logger
        self.workspaceRoot = (workspaceRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        self.sourceKitLSPPath = Self.findSourceKitLSP() ?? "/usr/bin/sourcekit-lsp"
        self.sourceKitLSPClient = SourceKitLSPClient(
            executablePath: self.sourceKitLSPPath,
            workspaceRoot: self.workspaceRoot,
            logger: logger
        )

        logger.info("🚀 Swift Language Server initialized")
        logger.info("📁 Workspace: \(self.workspaceRoot.path)")
        logger.info("🔧 SourceKit-LSP: \(self.sourceKitLSPPath)")
    }

    // MARK: - SourceKit-LSP Discovery

    /// Find SourceKit-LSP executable in common locations
    private static func findSourceKitLSP() -> String? {
        let commonPaths = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
            "/usr/local/bin/sourcekit-lsp",
            "/opt/homebrew/bin/sourcekit-lsp",
            "/usr/bin/sourcekit-lsp"
        ]

        return commonPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - LSP Communication

    public func initialize() async throws {
        guard !isInitialized else { return }

        logger.info("🔄 Initializing SourceKit-LSP connection...")

        try await sourceKitLSPClient.start()

        isInitialized = true
        logger.info("✅ Swift Language Server initialized successfully")
    }

    // MARK: - Symbol Operations for MCP

    public func findSymbols(in filePath: String, namePattern: String) async throws -> [SymbolInfo] {
        logger.debug("🔍 Finding symbols in \(filePath) with pattern: \(namePattern)")
        return try await withInitialized {
            let normalizedPattern = namePattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let symbols = try await sourceKitLSPClient.documentSymbols(fileURL: resolveFileURL(filePath))

            return symbols
                .filter { symbol in
                    normalizedPattern.isEmpty || symbol.name.lowercased().contains(normalizedPattern)
                }
                .map(makeSymbolInfo)
                .sorted {
                    if $0.location.line == $1.location.line {
                        return $0.location.character < $1.location.character
                    }
                    return $0.location.line < $1.location.line
                }
        }
    }

    public func findReferences(at position: Position, in filePath: String) async throws -> [Location] {
        logger.debug("📍 Finding references at \(position) in \(filePath)")
        return try await withInitialized {
            let locations = try await sourceKitLSPClient.references(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            )

            return locations.map(makeLocation)
        }
    }

    public func getDefinition(at position: Position, in filePath: String) async throws -> [LocationLink] {
        logger.debug("🎯 Getting definition at \(position) in \(filePath)")
        return try await withInitialized {
            let definitions = try await sourceKitLSPClient.definition(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            )

            return definitions.map(makeLocationLink)
        }
    }

    public func getHover(at position: Position, in filePath: String) async throws -> Hover? {
        logger.debug("💡 Getting hover info at \(position) in \(filePath)")
        return try await withInitialized {
            guard let hover = try await sourceKitLSPClient.hover(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            ) else {
                return nil
            }

            return makeHover(hover)
        }
    }

    public func getDiagnostics(for filePath: String) async throws -> [Diagnostic] {
        logger.debug("🔍 Getting diagnostics for \(filePath)")
        return try await withInitialized {
            let diagnostics = try await sourceKitLSPClient.diagnostics(fileURL: resolveFileURL(filePath))
            return diagnostics.map(makeDiagnostic)
        }
    }

    public func formatDocument(at filePath: String) async throws -> [TextEdit] {
        logger.debug("🎨 Formatting document at \(filePath)")
        return try await withInitialized {
            let edits = try await sourceKitLSPClient.formatDocument(fileURL: resolveFileURL(filePath))
            return edits.map(makeTextEdit)
        }
    }

    public func shutdown() async {
        logger.info("🛑 Swift Language Server shutdown")
        await sourceKitLSPClient.shutdown()
        isInitialized = false
    }

    // MARK: - Helpers

    private func resolveFileURL(_ filePath: String) -> URL {
        if let url = URL(string: filePath), url.isFileURL {
            return url.standardizedFileURL
        }

        if filePath.hasPrefix("/") {
            return URL(fileURLWithPath: filePath).standardizedFileURL
        }

        return workspaceRoot.appendingPathComponent(filePath).standardizedFileURL
    }

    private func withInitialized<T>(_ operation: () async throws -> T) async throws -> T {
        try await initialize()
        return try await operation()
    }

    private func makeLSPPosition(_ position: Position) -> LSPPosition {
        LSPPosition(line: position.line, character: position.character)
    }

    private func makePosition(_ position: LSPPosition) -> Position {
        Position(line: position.line, character: position.character)
    }

    private func makeRange(_ range: LSPRange) -> Range {
        Range(start: makePosition(range.start), end: makePosition(range.end))
    }

    private func makeLocation(_ location: LSPLocation) -> Location {
        Location(
            uri: location.uri,
            line: location.range.start.line,
            character: location.range.start.character
        )
    }

    private func makeSymbolInfo(_ symbol: LSPSymbolInfo) -> SymbolInfo {
        SymbolInfo(
            name: symbol.name,
            kind: symbolKindName(symbol.kind),
            location: makeLocation(symbol.location),
            containerName: symbol.containerName,
            detail: symbol.detail
        )
    }

    private func makeLocationLink(_ link: LSPLocationLink) -> LocationLink {
        LocationLink(
            originSelectionRange: link.originSelectionRange.map(makeRange),
            targetUri: link.targetUri,
            targetRange: makeRange(link.targetRange),
            targetSelectionRange: makeRange(link.targetSelectionRange)
        )
    }

    private func makeHover(_ hover: LSPHover) -> Hover {
        Hover(
            contents: .markupContent(
                MarkupContent(
                    kind: "markdown",
                    value: hover.markdown
                )
            ),
            range: hover.range.map(makeRange)
        )
    }

    private func makeDiagnostic(_ diagnostic: LSPDiagnostic) -> Diagnostic {
        Diagnostic(
            range: makeRange(diagnostic.range),
            severity: diagnostic.severity.flatMap(DiagnosticSeverity.init(rawValue:)),
            code: diagnostic.code,
            source: diagnostic.source,
            message: diagnostic.message
        )
    }

    private func makeTextEdit(_ edit: LSPTextEdit) -> TextEdit {
        TextEdit(
            range: makeRange(edit.range),
            newText: edit.newText
        )
    }

    private func symbolKindName(_ rawValue: Int) -> String {
        Self.symbolKindNames[rawValue] ?? "unknown"
    }
}

// MARK: - Supporting Types

public struct SymbolInfo {
    public let name: String
    public let kind: String
    public let location: Location
    public let containerName: String?
    public let detail: String?

    public init(name: String, kind: String, location: Location, containerName: String?, detail: String? = nil) {
        self.name = name
        self.kind = kind
        self.location = location
        self.containerName = containerName
        self.detail = detail
    }
}

public struct Location {
    public let uri: String
    public let line: Int
    public let character: Int

    public init(uri: String, line: Int, character: Int) {
        self.uri = uri
        self.line = line
        self.character = character
    }
}

public struct Position {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct Range {
    public let start: Position
    public let end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

public struct LocationLink {
    public let originSelectionRange: Range?
    public let targetUri: String
    public let targetRange: Range
    public let targetSelectionRange: Range

    public init(originSelectionRange: Range?, targetUri: String, targetRange: Range, targetSelectionRange: Range) {
        self.originSelectionRange = originSelectionRange
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }
}

public struct Hover {
    public let contents: HoverContent
    public let range: Range?

    public init(contents: HoverContent, range: Range?) {
        self.contents = contents
        self.range = range
    }
}

public enum HoverContent {
    case markupContent(MarkupContent)
    case markedString(MarkedString)
}

public struct MarkupContent {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct MarkedString {
    public let language: String?
    public let value: String

    public init(language: String?, value: String) {
        self.language = language
        self.value = value
    }
}

public struct TextEdit {
    public let range: Range
    public let newText: String

    public init(range: Range, newText: String) {
        self.range = range
        self.newText = newText
    }
}

public struct Diagnostic {
    public let range: Range
    public let severity: DiagnosticSeverity?
    public let code: String?
    public let source: String?
    public let message: String

    public init(range: Range, severity: DiagnosticSeverity?, code: String?, source: String?, message: String) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

public enum DiagnosticSeverity: Int {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public enum SwiftMCPError: Error, LocalizedError {
    case sourceKitNotFound
    case lspNotInitialized
    case symbolSearchFailed(Error)
    case referenceSearchFailed(Error)
    case definitionSearchFailed(Error)
    case hoverFailed(Error)
    case formattingFailed(Error)
    case communicationError(String)

    public var errorDescription: String? {
        switch self {
        case .sourceKitNotFound:
            return "SourceKit-LSP executable not found on system"
        case .lspNotInitialized:
            return "Language server not initialized. Call initialize() first."
        case .symbolSearchFailed(let error):
            return "Symbol search failed: \(error.localizedDescription)"
        case .referenceSearchFailed(let error):
            return "Reference search failed: \(error.localizedDescription)"
        case .definitionSearchFailed(let error):
            return "Definition search failed: \(error.localizedDescription)"
        case .hoverFailed(let error):
            return "Hover request failed: \(error.localizedDescription)"
        case .formattingFailed(let error):
            return "Code formatting failed: \(error.localizedDescription)"
        case .communicationError(let message):
            return "LSP communication error: \(message)"
        }
    }
}
