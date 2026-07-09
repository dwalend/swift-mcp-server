import Foundation
import Logging
import SourceKitLSP

/// STDIO transport implementation for MCP protocol
/// Compatible with VS Code MCP and Serena integration
public final class StdioTransport: @unchecked Sendable {
    private let logger: Logger
    private let swiftLanguageServer: SwiftLanguageServer
    private let mcpProtocolHandler: MCPProtocolHandler
    private let modernConcurrency: ModernConcurrencyIntegration
    private let shutdownLock = NSLock()
    private var hasShutdown = false

    public init(
        logger: Logger,
        workspaceRoot: URL? = nil
    ) {
        self.logger = logger
        self.modernConcurrency = ModernConcurrencyIntegration(logger: logger)
        self.swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspaceRoot)
        self.mcpProtocolHandler = MCPProtocolHandler(
            swiftLanguageServer: swiftLanguageServer,
            logger: logger
        )
    }

    public func start() async throws {
        logger.info("Swift MCP Server started with STDIO transport")
        logger.info("Modern concurrency enabled with enhanced task management")
        logger.info("Server is ready to handle MCP requests via STDIO")

        let resourceUsage = await modernConcurrency.getResourceUsage()
        logger.info("Initial resource usage - Memory: \(resourceUsage.memoryMB)MB, CPU: \(resourceUsage.cpuPercentage)%, Network: \(resourceUsage.networkOperations)")

        // Warm up SourceKit-LSP in the background so the first tool call does
        // not pay the full startup and index-warmup latency.
        Task { [weak self] in
            try? await self?.swiftLanguageServer.initialize()
        }

        while true {
            guard let line = readLine() else {
                logger.debug("STDIO input closed, shutting down")
                break
            }

            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            logger.trace("Received STDIO input")

            do {
                let response = try await processRequest(line)
                writeToStdout(response)
                logger.trace("Sent STDIO response")
            } catch {
                logger.error("Error processing request: \(error)")
                writeToStdout(createErrorResponse(error: error))
            }
        }

        await shutdownIfNeeded(logMessage: "Shutting down Swift MCP Server (STDIO)...")
    }

    private func processRequest(_ input: String) async throws -> String {
        guard let data = input.data(using: .utf8) else {
            throw StdioError.invalidInput
        }

        let response: MCPResponse

        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: data)

            do {
                response = try await mcpProtocolHandler.handleRequest(request)
            } catch let error as MCPError {
                response = MCPResponse(id: request.id, error: error)
            } catch {
                logger.error("Unexpected request failure: \(error)")
                response = MCPResponse(id: request.id, error: .internalError)
            }
        } catch {
            logger.error("Failed to decode STDIO request: \(error)")
            response = MCPResponse(id: extractRequestID(from: data), error: .parseError)
        }

        return try encodeResponse(response)
    }

    private func encodeResponse(_ response: MCPResponse) throws -> String {
        let responseData = try JSONEncoder().encode(response)

        guard let responseString = String(data: responseData, encoding: .utf8) else {
            throw StdioError.encodingError
        }

        return responseString
    }

    private func createErrorResponse(error: Error) -> String {
        let mcpError = (error as? MCPError) ?? .internalError
        let errorResponse = MCPResponse(id: nil, error: mcpError)

        do {
            return try encodeResponse(errorResponse)
        } catch {
            return "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
    }

    private func extractRequestID(from data: Data) -> RequestID? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = jsonObject["id"] else {
            return nil
        }

        if let stringID = rawID as? String {
            return .string(stringID)
        }

        if let intID = rawID as? Int {
            return .number(intID)
        }

        return nil
    }

    private func writeToStdout(_ response: String) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
        fflush(stdout)
    }

    private func shutdownIfNeeded(logMessage: String) async {
        let shouldShutdown = markShutdownIfNeeded()
        guard shouldShutdown else {
            return
        }

        logger.info("\(logMessage)")
        await modernConcurrency.shutdown()
        await swiftLanguageServer.shutdown()
        logger.info("Swift MCP Server (STDIO) stopped")
    }

    /// Public shutdown method for external calls
    public func gracefulShutdown() async {
        await shutdownIfNeeded(logMessage: "Shutting down STDIO transport")
    }

    private func markShutdownIfNeeded() -> Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }

        guard !hasShutdown else {
            return false
        }

        hasShutdown = true
        return true
    }
}

// MARK: - Error Types

enum StdioError: Error, LocalizedError {
    case invalidInput
    case encodingError

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid STDIO input format"
        case .encodingError:
            return "Failed to encode response"
        }
    }
}
