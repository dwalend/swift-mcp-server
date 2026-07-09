import Foundation
import Logging

public final class MCPProtocolHandler {
    private let swiftLanguageServer: SwiftLanguageServer
    private let logger: Logger

    public init(
        swiftLanguageServer: SwiftLanguageServer,
        logger: Logger
    ) {
        self.swiftLanguageServer = swiftLanguageServer
        self.logger = logger
    }

    public func handleRequest(_ request: MCPRequest) async throws -> MCPResponse {
        logger.debug("Handling MCP request: \(request.method)")

        switch request.method {
        case "initialize":
            return try await handleInitialize(request)
        case "tools/list":
            return try await handleToolsList(request)
        case "tools/call":
            return try await handleToolCall(request)
        case "resources/list":
            return try await handleResourcesList(request)
        case "resources/read":
            return try await handleResourceRead(request)
        default:
            throw MCPError.methodNotFound(request.method)
        }
    }

    // MARK: - Initialize

    private func handleInitialize(_ request: MCPRequest) async throws -> MCPResponse {
        let capabilities = ServerCapabilities(
            tools: ToolsCapability(listChanged: true),
            resources: ResourcesCapability(subscribe: true, listChanged: true)
        )

        let result = InitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: capabilities,
            serverInfo: ServerInfo(
                name: "swift-mcp-server",
                version: "1.0.0"
            )
        )

        return try makeResponse(id: request.id, result: result)
    }

    // MARK: - Tools

    private func handleToolsList(_ request: MCPRequest) async throws -> MCPResponse {
        let positionSchema: JSONObject = [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Path to the Swift file"
                ],
                "line": [
                    "type": "integer",
                    "description": "Line number (0-based)"
                ],
                "character": [
                    "type": "integer",
                    "description": "Character position (0-based)"
                ]
            ],
            "required": ["file_path", "line", "character"]
        ]

        let filePathSchema: JSONObject = [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Path to the Swift file"
                ]
            ],
            "required": ["file_path"]
        ]

        let tools = [
            Tool(
                name: "find_symbols",
                description: "List Swift symbols declared in a file, optionally filtered by a name pattern. Backed by SourceKit-LSP.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file"
                        ],
                        "name_pattern": [
                            "type": "string",
                            "description": "Substring to match against symbol names"
                        ]
                    ],
                    "required": ["file_path", "name_pattern"]
                ]
            ),
            Tool(
                name: "find_references",
                description: "Find all references to the symbol at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "get_definition",
                description: "Jump to the definition of the symbol at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "get_hover_info",
                description: "Get hover documentation and type information for the symbol at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "format_document",
                description: "Format a Swift document and return the resulting text edits. Backed by SourceKit-LSP.",
                inputSchema: filePathSchema
            ),
            Tool(
                name: "get_diagnostics",
                description: "Get compiler diagnostics (errors and warnings) for a Swift document. Backed by SourceKit-LSP.",
                inputSchema: filePathSchema
            )
        ]

        return try makeResponse(id: request.id, result: ToolsListResult(tools: tools))
    }

    private func handleToolCall(_ request: MCPRequest) async throws -> MCPResponse {
        guard let params = request.params else {
            throw MCPError.invalidParams
        }

        guard let name = params.string("name") else {
            throw MCPError.invalidParams
        }

        let arguments = params.object("arguments") ?? [:]

        let result: Any

        switch name {
        case "find_symbols":
            result = try await handleFindSymbols(arguments)
        case "find_references":
            result = try await handleFindReferences(arguments)
        case "get_definition":
            result = try await handleGetDefinition(arguments)
        case "get_hover_info":
            result = try await handleGetHoverInfo(arguments)
        case "format_document":
            result = try await handleFormatDocument(arguments)
        case "get_diagnostics":
            result = try await handleGetDiagnostics(arguments)
        default:
            throw MCPError.toolNotFound(name)
        }

        let toolResult = ToolCallResult(
            content: [
                ToolContent(type: "text", text: renderToolResult(result))
            ]
        )

        return try makeResponse(id: request.id, result: toolResult)
    }

    // MARK: - Tool Implementations

    private func handleFindSymbols(_ arguments: JSONObject) async throws -> [SymbolInfo] {
        guard let filePath = arguments.string("file_path"),
              let namePattern = arguments.string("name_pattern") else {
            throw MCPError.invalidParams
        }

        return try await swiftLanguageServer.findSymbols(in: filePath, namePattern: namePattern)
    }

    private func handleFindReferences(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let locations = try await swiftLanguageServer.findReferences(at: position, in: filePath)

        return locations.map { "\($0.uri):\($0.line):\($0.character)" }
    }

    private func handleGetDefinition(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let locations = try await swiftLanguageServer.getDefinition(at: position, in: filePath)

        return locations.map { "\($0.targetUri):\($0.targetRange.start.line):\($0.targetRange.start.character)" }
    }

    private func handleGetHoverInfo(_ arguments: JSONObject) async throws -> String {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let hover = try await swiftLanguageServer.getHover(at: position, in: filePath)

        if case .markupContent(let content) = hover?.contents {
            return content.value
        } else if case .markedString(let string) = hover?.contents {
            return string.value
        }

        return "No hover information available"
    }

    private func handleFormatDocument(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path") else {
            throw MCPError.invalidParams
        }

        let edits = try await swiftLanguageServer.formatDocument(at: filePath)
        return edits.map { "Line \($0.range.start.line): \($0.newText)" }
    }

    private func handleGetDiagnostics(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path") else {
            throw MCPError.invalidParams
        }

        let diagnostics = try await swiftLanguageServer.getDiagnostics(for: filePath)
        return diagnostics.map {
            let severity = $0.severity.map { String(describing: $0).lowercased() } ?? "unknown"
            return "\($0.range.start.line):\($0.range.start.character) [\(severity)] \($0.message)"
        }
    }

    // MARK: - Resources

    private func handleResourcesList(_ request: MCPRequest) async throws -> MCPResponse {
        let resources = [
            Resource(
                uri: "swift://workspace",
                name: "Swift Workspace",
                description: "Current Swift workspace information",
                mimeType: "application/json"
            )
        ]

        return try makeResponse(id: request.id, result: ResourcesListResult(resources: resources))
    }

    private func handleResourceRead(_ request: MCPRequest) async throws -> MCPResponse {
        guard let params = request.params,
              let uri = params.string("uri") else {
            throw MCPError.invalidParams
        }

        let content: String

        switch uri {
        case "swift://workspace":
            content = """
            {
                "type": "swift_workspace",
                "capabilities": ["symbol_search", "references", "definitions", "hover", "formatting", "diagnostics"],
                "sourcekit_lsp": "available"
            }
            """
        default:
            throw MCPError.resourceNotFound(uri)
        }

        let result = ResourceReadResult(
            contents: [
                ResourceContent(
                    uri: uri,
                    mimeType: "application/json",
                    text: content
                )
            ]
        )

        return try makeResponse(id: request.id, result: result)
    }

    // MARK: - Helpers

    private func makeResponse<T: Encodable>(id: RequestID?, result: T) throws -> MCPResponse {
        MCPResponse(id: id, result: try JSONValue.fromEncodable(result))
    }

    private func renderToolResult(_ result: Any) -> String {
        switch result {
        case let string as String:
            return string
        case let strings as [String]:
            return strings.joined(separator: "\n")
        case let symbols as [SymbolInfo]:
            return symbols.map {
                "\($0.kind) \($0.name) @ \($0.location.uri):\($0.location.line):\($0.location.character)"
            }.joined(separator: "\n")
        default:
            return String(describing: result)
        }
    }
}
