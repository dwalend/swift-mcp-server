import XCTest
import Logging
@testable import SwiftMCPCore

final class SwiftMCPServerTests: XCTestCase {

    // MARK: - Protocol Shape

    func testMCPProtocolHandlerInitialization() throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        XCTAssertNotNil(handler)
    }

    func testMCPRequestDecodingSupportsNestedJSON() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "test-id",
            "method": "tools/call",
            "params": {
                "name": "find_symbols",
                "arguments": {
                    "file_path": "/tmp/project/main.swift",
                    "name_pattern": "Greeter"
                }
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let request = try JSONDecoder().decode(MCPRequest.self, from: data)

        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.method, "tools/call")
        XCTAssertEqual(request.params?.string("name"), "find_symbols")
        XCTAssertEqual(request.params?.object("arguments")?.string("file_path"), "/tmp/project/main.swift")
        XCTAssertEqual(request.params?.object("arguments")?.string("name_pattern"), "Greeter")
    }

    func testMCPResponseEncodingPreservesJSONObjectShape() throws {
        let response = MCPResponse(
            jsonrpc: "2.0",
            id: .string("test-id"),
            result: [
                "status": "ok",
                "count": 1
            ]
        )

        let data = try JSONEncoder().encode(response)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObject["id"] as? String, "test-id")
        XCTAssertTrue(jsonObject["result"] is [String: Any])

        let result = try XCTUnwrap(jsonObject["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["count"] as? Int, 1)
    }

    func testToolsListExposesOnlySourceKitBackedTools() async throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .string("tools"),
            method: "tools/list",
            params: [:]
        )

        let response = try await handler.handleRequest(request)
        let result = try XCTUnwrap(response.result?.objectValue)
        let tools = try XCTUnwrap(result["tools"]?.arrayValue)

        let toolNames = Set(tools.compactMap { $0.objectValue?.string("name") })
        XCTAssertEqual(
            toolNames,
            [
                "find_symbols",
                "find_references",
                "get_definition",
                "get_hover_info",
                "format_document",
                "get_diagnostics"
            ]
        )
    }

    func testUnknownToolReturnsToolNotFound() async throws {
        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .string("call"),
            method: "tools/call",
            params: [
                "name": "analyze_project",
                "arguments": [:]
            ]
        )

        do {
            _ = try await handler.handleRequest(request)
            XCTFail("Expected a tool-not-found error for a removed tool")
        } catch let error as MCPError {
            if case .toolNotFound(let name) = error {
                XCTAssertEqual(name, "analyze_project")
            } else {
                XCTFail("Expected .toolNotFound, got \(error)")
            }
        }
    }

    func testToolDefinition() throws {
        let tool = Tool(
            name: "find_symbols",
            description: "Find Swift symbols",
            inputSchema: [
                "type": "object",
                "properties": [
                    "file_path": ["type": "string"]
                ]
            ]
        )

        XCTAssertEqual(tool.name, "find_symbols")
        XCTAssertEqual(tool.description, "Find Swift symbols")
        XCTAssertEqual(tool.inputSchema.object("properties")?.object("file_path")?.string("type"), "string")
    }

    // MARK: - SourceKit-LSP Behaviour

    func testFormatDocumentUsesSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "FormattingWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceFile = workspace.appendingPathComponent("Sources/FormattingWorkspace/main.swift")

        try """
        import Foundation

        struct  Greeter{
        let name:String
        func greet()->String{
        "Hello, \\(name)"
        }
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let edits = try await swiftLanguageServer.formatDocument(at: sourceFile.path)
        XCTAssertFalse(edits.isEmpty)
    }

    func testDiagnosticsUseSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "DiagnosticsWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceFile = workspace.appendingPathComponent("Sources/DiagnosticsWorkspace/main.swift")

        try """
        import Foundation

        struct Greeter {
            let number: Int = "oops"
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let diagnostics = try await swiftLanguageServer.getDiagnostics(for: sourceFile.path)
        XCTAssertFalse(diagnostics.isEmpty)
        XCTAssertTrue(diagnostics.contains { $0.message.contains("Cannot convert value of type 'String' to specified type 'Int'") })
    }

    func testNavigationRequestsUseSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "NavigationWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourcesDirectory = workspace.appendingPathComponent("Sources/NavigationWorkspace")
        let definitionFile = sourcesDirectory.appendingPathComponent("Greeter.swift")
        let usageFile = sourcesDirectory.appendingPathComponent("main.swift")

        try """
        import Foundation

        struct Greeter {
            let name: String

            func greet() -> String {
                "Hello, \\(name)"
            }
        }
        """
            .write(to: definitionFile, atomically: true, encoding: .utf8)

        try """
        import Foundation

        let greeter = Greeter(name: "World")
        print(greeter.greet())
        """
            .write(to: usageFile, atomically: true, encoding: .utf8)

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        defer { Task { await swiftLanguageServer.shutdown() } }

        let symbols = try await swiftLanguageServer.findSymbols(in: definitionFile.path, namePattern: "Greeter")
        XCTAssertTrue(symbols.contains { $0.name == "Greeter" && $0.kind == "struct" })

        let definition = try await swiftLanguageServer.getDefinition(
            at: Position(line: 2, character: 15),
            in: usageFile.path
        )
        XCTAssertFalse(definition.isEmpty)
        XCTAssertEqual(
            canonicalPath(URL(string: try XCTUnwrap(definition.first).targetUri)?.path),
            canonicalPath(definitionFile.path)
        )

        let references = try await swiftLanguageServer.findReferences(
            at: Position(line: 2, character: 8),
            in: definitionFile.path
        )
        XCTAssertTrue(
            references.contains { canonicalPath(URL(string: $0.uri)?.path) == canonicalPath(usageFile.path) }
        )

        let hover = try await swiftLanguageServer.getHover(
            at: Position(line: 2, character: 15),
            in: usageFile.path
        )
        XCTAssertNotNil(hover)

        switch hover?.contents {
        case .markupContent(let content):
            XCTAssertTrue(content.value.contains("Greeter"))
        case .markedString(let content):
            XCTAssertTrue(content.value.contains("Greeter"))
        case .none:
            XCTFail("Expected hover content")
        }
    }

    // MARK: - Helpers

    private func sourceKitLSPAvailable() -> Bool {
        let commonPaths = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
            "/usr/local/bin/sourcekit-lsp",
            "/opt/homebrew/bin/sourcekit-lsp",
            "/usr/bin/sourcekit-lsp"
        ]

        return commonPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func canonicalPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func makeTemporaryPackage(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourcesDirectory = directory.appendingPathComponent("Sources/\(name)", isDirectory: true)

        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            targets: [
                .executableTarget(name: "\(name)")
            ]
        )
        """
            .write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        return directory
    }
}
