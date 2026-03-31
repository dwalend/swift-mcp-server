import Foundation
import Logging

public final class MCPProtocolHandler {
    private let swiftLanguageServer: SwiftLanguageServer
    private let projectAnalyzer: ProjectAnalyzer
    private let architectureAnalyzer: ArchitectureAnalyzer
    private let symbolSearchEngine: SymbolSearchEngine
    private let projectMemory: IntelligentProjectMemory
    private let documentationGenerator: DocumentationGenerator
    private let iOSFrameworkAnalyzer: iOSFrameworkAnalysisEngine
    private let templateGenerator: TemplateGenerator
    private let runtimeConfiguration: MCPRuntimeConfiguration
    private let logger: Logger

    public init(
        swiftLanguageServer: SwiftLanguageServer,
        logger: Logger,
        runtimeConfiguration: MCPRuntimeConfiguration = MCPRuntimeConfiguration()
    ) {
        self.swiftLanguageServer = swiftLanguageServer
        self.logger = logger
        self.runtimeConfiguration = runtimeConfiguration

        let analysisOptions = runtimeConfiguration.analysis

        self.projectAnalyzer = ProjectAnalyzer(
            projectPath: swiftLanguageServer.workspaceURL,
            logger: logger,
            options: analysisOptions
        )
        self.architectureAnalyzer = ArchitectureAnalyzer(
            projectPath: swiftLanguageServer.workspaceURL,
            logger: logger,
            options: analysisOptions
        )
        self.symbolSearchEngine = SymbolSearchEngine(projectPath: swiftLanguageServer.workspaceURL, logger: logger)
        self.projectMemory = IntelligentProjectMemory(projectPath: swiftLanguageServer.workspaceURL, logger: logger)
        self.documentationGenerator = DocumentationGenerator(projectPath: swiftLanguageServer.workspaceURL, logger: logger)
        self.iOSFrameworkAnalyzer = iOSFrameworkAnalysisEngine(
            projectPath: swiftLanguageServer.workspaceURL,
            logger: logger,
            options: analysisOptions
        )
        self.templateGenerator = TemplateGenerator(projectPath: swiftLanguageServer.workspaceURL, logger: logger)
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
        let tools = [
            Tool(
                name: "find_symbols",
                description: "Find Swift symbols in a file by name pattern",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file"
                        ],
                        "name_pattern": [
                            "type": "string",
                            "description": "Pattern to match symbol names"
                        ]
                    ],
                    "required": ["file_path", "name_pattern"]
                ]
            ),
            Tool(
                name: "find_references",
                description: "Find all references to a symbol at a specific position",
                inputSchema: [
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
            ),
            Tool(
                name: "get_definition",
                description: "Get definition location for a symbol at a specific position",
                inputSchema: [
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
            ),
            Tool(
                name: "get_hover_info",
                description: "Get hover information for a symbol at a specific position",
                inputSchema: [
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
            ),
            Tool(
                name: "format_document",
                description: "Format a Swift document",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file to format"
                        ]
                    ],
                    "required": ["file_path"]
                ]
            ),
            Tool(
                name: "get_diagnostics",
                description: "Get SourceKit-LSP diagnostics for a Swift document",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file"
                        ]
                    ],
                    "required": ["file_path"]
                ]
            ),
            Tool(
                name: "analyze_project",
                description: "Perform comprehensive project analysis. Architecture detection is skipped unless enabled in config or per request.",
                inputSchema: projectPathInputSchema(includeArchitectureDetectionToggle: true)
            ),
            Tool(
                name: "detect_architecture",
                description: "Detect the architecture pattern used in the project when architecture detection is enabled",
                inputSchema: projectPathInputSchema(includeArchitectureDetectionToggle: true)
            ),
            Tool(
                name: "analyze_symbol_usage",
                description: "Analyze how a symbol is used throughout the project using semantic reference categories",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "symbol_name": [
                            "type": "string",
                            "description": "Name of the symbol to analyze"
                        ],
                        "project_path": [
                            "type": "string",
                            "description": "Optional path to the project. Defaults to the current workspace."
                        ]
                    ],
                    "required": ["symbol_name"]
                ]
            ),
            Tool(
                name: "create_project_memory",
                description: "Create comprehensive project documentation and memory",
                inputSchema: projectPathInputSchema(includeArchitectureDetectionToggle: true)
            ),
            Tool(
                name: "generate_migration_plan",
                description: "Generate a plan to migrate to a different architecture pattern",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "target_architecture": [
                            "type": "string",
                            "description": "Target architecture pattern (mvc, mvvm, mvp, viper, coordinator, tca, features_based, clean_architecture, modular)"
                        ],
                        "project_path": [
                            "type": "string",
                            "description": "Optional path to the project. Defaults to the current workspace."
                        ],
                        "enable_architecture_detection": [
                            "type": "boolean",
                            "description": "Optional override. Architecture detection is disabled by default unless enabled in config or per request."
                        ]
                    ],
                    "required": ["target_architecture"]
                ]
            ),
            Tool(
                name: "analyze_pop_usage",
                description: "Analyze project's Protocol-Oriented Programming (POP) adoption",
                inputSchema: projectPathInputSchema()
            ),
            Tool(
                name: "intelligent_project_memory",
                description: "Manage intelligent project memory with pattern learning",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "description": "Action to perform: cache, retrieve, learn_patterns, get_evolution"
                        ],
                        "key": [
                            "type": "string",
                            "description": "Key for caching/retrieving analysis results"
                        ]
                    ],
                    "required": ["action"]
                ]
            ),
            Tool(
                name: "generate_documentation",
                description: "Generate comprehensive project documentation including README and API docs",
                inputSchema: projectPathInputSchema()
            ),
            Tool(
                name: "analyze_ios_frameworks",
                description: "Analyze iOS framework usage and detect UI patterns",
                inputSchema: projectPathInputSchema(includeArchitectureDetectionToggle: true)
            ),
            Tool(
                name: "generate_template",
                description: "Generate Swift/iOS project templates",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "template_type": [
                            "type": "string",
                            "description": "Template type: swift-package, uikit-viewcontroller, swiftui-view, mvvm-module, coordinator, network-service, coredata-model, unit-tests"
                        ],
                        "name": [
                            "type": "string",
                            "description": "Name for the generated template"
                        ],
                        "description": [
                            "type": "string",
                            "description": "Optional description for the template"
                        ]
                    ],
                    "required": ["template_type", "name"]
                ]
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
        case "analyze_project":
            result = try await handleAnalyzeProject(arguments)
        case "detect_architecture":
            result = try await handleDetectArchitecture(arguments)
        case "analyze_symbol_usage":
            result = try await handleAnalyzeSymbolUsage(arguments)
        case "create_project_memory":
            result = try await handleCreateProjectMemory(arguments)
        case "generate_migration_plan":
            result = try await handleGenerateMigrationPlan(arguments)
        case "analyze_pop_usage":
            result = try await handleAnalyzePOPUsage(arguments)
        case "intelligent_project_memory":
            result = try await handleIntelligentProjectMemory(arguments)
        case "generate_documentation":
            result = try await handleGenerateDocumentation(arguments)
        case "analyze_ios_frameworks":
            result = try await handleAnalyzeiOSFrameworks(arguments)
        case "generate_template":
            result = try await handleGenerateTemplate(arguments)
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
                "capabilities": ["symbol_search", "references", "definitions", "hover", "formatting"],
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

    // MARK: - Enhanced Analysis Tools

    private func handleAnalyzeProject(_ arguments: JSONObject) async throws -> String {
        let projectURL = resolveProjectURL(from: arguments)
        let analyzer = projectAnalyzer(for: projectURL, arguments: arguments)
        let analysis = try await analyzer.analyzeProject()
        let architectureDescription = analyzer.architectureDetectionEnabled
            ? analysis.architecturePattern.rawValue
            : "Skipped (disabled by configuration)"

        return """
        Project Analysis for: \(projectURL.path)
        Architecture: \(architectureDescription)
        Modules: \(analysis.structure.modules.count)
        Features: \(analysis.structure.features.count)
        Metrics: \(analysis.metrics.totalFiles) files, \(analysis.metrics.totalLines) lines
        """
    }

    private func handleDetectArchitecture(_ arguments: JSONObject) async throws -> String {
        let analyzer = architectureAnalyzer(for: resolveProjectURL(from: arguments), arguments: arguments)
        guard analyzer.architectureDetectionEnabled else {
            return "Architecture detection disabled by configuration"
        }
        let pattern = try await analyzer.detectArchitecturePattern()

        return pattern.rawValue
    }

    private func handleAnalyzeSymbolUsage(_ arguments: JSONObject) async throws -> String {
        guard let symbolName = arguments.string("symbol_name") else {
            throw MCPError.invalidParams
        }

        let projectURL = resolveProjectURL(from: arguments)
        let symbolEngine = symbolSearchEngine(for: projectURL)
        let usage = try await symbolEngine.analyzeSymbolUsage(symbolName: symbolName)
        let usageCategories = usage.usagePatterns
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        return """
        Symbol Usage Analysis for: \(symbolName)
        Total occurrences: \(usage.totalReferences)
        Files containing symbol: \(usage.uniqueFiles)
        Semantically resolved: \(usage.resolvedSemantically ? "Yes" : "No")
        Usage categories: \(usageCategories.isEmpty ? "None" : usageCategories)
        """
    }

    private func handleCreateProjectMemory(_ arguments: JSONObject) async throws -> String {
        let analyzer = projectAnalyzer(for: resolveProjectURL(from: arguments), arguments: arguments)
        let memory = try await analyzer.createProjectMemory()
        let architectureDescription = analyzer.architectureDetectionEnabled
            ? memory.analysis.architecturePattern.rawValue
            : "Skipped (disabled by configuration)"

        return """
        Project Memory Created:
        Project: \(memory.analysis.projectName)
        Architecture: \(architectureDescription)
        Key Symbols: \(memory.keySymbols.count) symbols captured
        Code Patterns: \(memory.codePatterns.count) patterns identified
        Last Updated: \(memory.lastUpdated)
        """
    }

    private func handleGenerateMigrationPlan(_ arguments: JSONObject) async throws -> String {
        guard let targetArchitecture = arguments.string("target_architecture") else {
            throw MCPError.invalidParams
        }

        guard let targetPattern = ArchitecturePattern.parse(targetArchitecture) else {
            throw MCPError.invalidParams
        }

        let analyzer = projectAnalyzer(for: resolveProjectURL(from: arguments), arguments: arguments)
        let plan = try await analyzer.generateMigrationPlan(to: targetPattern)

        return """
        Migration Plan from \(plan.from.rawValue) to \(plan.to.rawValue):

        Steps: \(plan.steps.count) migration steps
        Estimated effort: \(plan.estimatedEffort)
        Risks: \(plan.risks.count) identified
        Benefits: \(plan.benefits.count) expected benefits

        First Steps:
        \(plan.steps.prefix(3).map { "• \($0.title): \($0.description)" }.joined(separator: "\n"))
        """
    }

    private func handleAnalyzePOPUsage(_ arguments: JSONObject) async throws -> String {
        let projectURL = resolveProjectURL(from: arguments)
        let analyzer = architectureAnalyzer(for: projectURL)
        let analysis = try await analyzer.analyzePOPUsage()

        return """
        🔍 Protocol-Oriented Programming Analysis for: \(projectURL.path)

        📊 Overview:
        • Total Swift files: \(analysis.totalFiles)
        • POP Score: \(analysis.popScore)/100 (\(analysis.adoptionLevel.rawValue))
        • Struct vs Class ratio: \(analysis.structUsage):\(analysis.classUsage)

        📈 Protocol Usage:
        • Protocol definitions: \(analysis.protocolDefinitions)
        • Protocol extensions: \(analysis.protocolExtensions)
        • Protocol conformances: \(analysis.protocolConformances)
        • Protocol as types: \(analysis.protocolAsTypeUsage)

        🎯 POP Patterns Found:
        \(analysis.popPatterns.isEmpty ? "None detected" : analysis.popPatterns.map { "• \($0)" }.joined(separator: "\n"))

        💡 Recommendations:
        \(analysis.recommendations.map { "• \($0)" }.joined(separator: "\n"))
        """
    }

    // MARK: - Analysis Tool Handlers

    private func handleIntelligentProjectMemory(_ arguments: JSONObject) async throws -> String {
        guard let action = arguments.string("action") else {
            throw MCPError.invalidParams
        }

        switch action {
        case "cache":
            guard let key = arguments.string("key") else {
                throw MCPError.invalidParams
            }

            let result = IntelligentAnalysisResult(
                timestamp: Date(),
                analysisType: "generic_analysis",
                result: Data("analysis_data".utf8),
                checksum: "demo_checksum"
            )
            await projectMemory.cacheAnalysis(result, for: key)
            return "✅ Analysis cached for key: \(key)"

        case "retrieve":
            guard let key = arguments.string("key") else {
                throw MCPError.invalidParams
            }

            if let cached = await projectMemory.getCachedAnalysis(for: key) {
                return """
                📋 Cached Analysis for key: \(key)
                • Timestamp: \(cached.timestamp)
                • Type: \(cached.analysisType)
                • Checksum: \(cached.checksum)
                """
            }

            return "❌ No cached analysis found for key: \(key)"

        case "learn_patterns":
            let patterns = await projectMemory.getMostCommonPatterns()
            return """
            🧠 Learned Patterns (\(patterns.count) total):
            \(patterns.map { "• \($0.key.rawValue): \($0.value) occurrences" }.joined(separator: "\n"))
            """

        case "get_evolution":
            return """
            📈 Project Evolution:
            • Total cached analyses: \(await projectMemory.getCachedAnalysis(for: "count") != nil ? "Available" : "None")
            • Pattern learning: Active
            • Memory system: Operational
            """

        default:
            throw MCPError.invalidParams
        }
    }

    private func handleGenerateDocumentation(_ arguments: JSONObject) async throws -> String {
        let generator = DocumentationGenerator(projectPath: resolveProjectURL(from: arguments), logger: logger)
        let result = try await generator.generateProjectDocumentation()

        return """
        📚 Documentation Generated Successfully!

        📄 Generated Files:
        \(result.generatedFiles.map { "• \($0)" }.joined(separator: "\n"))

        📊 Project Structure:
        • Name: \(result.projectStructure.name)
        • Type: \(result.projectStructure.type)
        • Swift files: \(result.projectStructure.swiftFileCount)
        • Has Package.swift: \(result.projectStructure.hasPackageSwift)

        🔍 API Documentation:
        • Total API items: \(result.apiDocumentation.count)
        • Classes: \(result.apiDocumentation.filter { $0.type == .classType }.count)
        • Structs: \(result.apiDocumentation.filter { $0.type == .structType }.count)
        • Functions: \(result.apiDocumentation.filter { $0.type == .function }.count)

        ✅ README.md has been generated and saved to the project root.
        """
    }

    private func handleAnalyzeiOSFrameworks(_ arguments: JSONObject) async throws -> String {
        let analyzer = iOSFrameworkAnalyzer(for: resolveProjectURL(from: arguments), arguments: arguments)
        let result = try await analyzer.analyzeIOSPatterns()

        return """
        📱 iOS Framework Analysis Results

        🧭 Apple SDK Catalog:
        • Xcode: \(result.sdkCatalog.xcodeVersion ?? "Unknown")
        • Cataloged modules: \(result.sdkCatalog.moduleCount)
        • Platforms: \(result.sdkCatalog.platforms.map { $0.platform.rawValue }.joined(separator: ", "))

        🛠️ Framework Usage:
        • UIKit: \(result.frameworkUsage.uiKit) imports
        • SwiftUI: \(result.frameworkUsage.swiftUI) imports
        • Foundation: \(result.frameworkUsage.foundation) imports
        • Combine: \(result.frameworkUsage.combine) imports
        • Core Data: \(result.frameworkUsage.coreData) imports
        • Networking: \(result.frameworkUsage.networking) imports
        • Foundation Models: \(result.frameworkUsage.foundationModels) imports
        • Image Playground: \(result.frameworkUsage.imagePlayground) imports
        • Dominant framework: \(result.frameworkUsage.dominantFramework)

        🎨 UI Patterns:
        • View Controllers: \(result.uiPatterns.viewControllers)
        • SwiftUI Views: \(result.uiPatterns.swiftUIViews)
        • Storyboard usage: \(result.uiPatterns.storyboardUsage)
        • AutoLayout usage: \(result.uiPatterns.autolayoutUsage)
        • Primary UI: \(result.uiPatterns.primaryUIFramework)

        🏗️ Architecture:
        • Enabled: \(result.architecturePatterns.enabled ? "Yes" : "No")
        • MVC Score: \(result.architecturePatterns.mvcScore)
        • MVVM Score: \(result.architecturePatterns.mvvmScore)
        • MVP Score: \(result.architecturePatterns.mvpScore)
        • VIPER Score: \(result.architecturePatterns.viperScore)
        • Coordinator Score: \(result.architecturePatterns.coordinatorScore)
        • TCA Score: \(result.architecturePatterns.tcaScore)
        • Clean Architecture Score: \(result.architecturePatterns.cleanArchitectureScore)
        • Features-based Score: \(result.architecturePatterns.featuresBasedScore)
        • Modular Score: \(result.architecturePatterns.modularScore)
        • Dominant pattern: \(result.architecturePatterns.dominantPattern)

        ⚡ Modern Features:
        • Async/await usage: \(result.modernFeatures.asyncAwaitUsage)
        • Actor usage: \(result.modernFeatures.actorUsage)
        • Combine usage: \(result.modernFeatures.combineUsage)
        • Modernity score: \(result.modernFeatures.modernityScore)

        🍎 Apple Modules:
        \(result.appleModules.isEmpty ? "• None detected" : result.appleModules.map {
            let symbols = $0.matchedSymbols.isEmpty ? "no symbol hits" : $0.matchedSymbols.joined(separator: ", ")
            return "• \($0.moduleName): imports=\($0.importCount), symbolHits=\($0.symbolHitCount), symbols=\(symbols)"
        }.joined(separator: "\n"))

        🧠 Apple Intelligence:
        • Foundation Models features: \(result.appleIntelligence.foundationModelFeatures.isEmpty ? "None detected" : result.appleIntelligence.foundationModelFeatures.joined(separator: ", "))
        • Foundation Models symbols: \(result.appleIntelligence.foundationModelSymbolHits.isEmpty ? "None" : result.appleIntelligence.foundationModelSymbolHits.keys.sorted().joined(separator: ", "))
        • Image Playground features: \(result.appleIntelligence.imagePlaygroundFeatures.isEmpty ? "None detected" : result.appleIntelligence.imagePlaygroundFeatures.joined(separator: ", "))
        • Image Playground symbols: \(result.appleIntelligence.imagePlaygroundSymbolHits.isEmpty ? "None" : result.appleIntelligence.imagePlaygroundSymbolHits.keys.sorted().joined(separator: ", "))

        📚 Official References:
        \(result.documentationReferences.map { "• \($0.title): \($0.url)" }.joined(separator: "\n"))

        💡 Recommendations:
        \(result.recommendations.map { "• \($0)" }.joined(separator: "\n"))
        """
    }

    private func handleGenerateTemplate(_ arguments: JSONObject) async throws -> String {
        guard let templateTypeString = arguments.string("template_type"),
              let name = arguments.string("name") else {
            throw MCPError.invalidParams
        }

        guard let templateType = TemplateType(rawValue: templateTypeString) else {
            throw MCPError.invalidParams
        }

        let description = arguments.string("description")
        let options = TemplateOptions(description: description)

        let result = try await templateGenerator.generateTemplate(templateType, name: name, options: options)

        return """
        🛠️ Template Generated Successfully!

        📄 Template: \(result.templateType.displayName)
        📁 Name: \(name)

        📝 Generated Files (\(result.generatedFiles.count)):
        \(result.generatedFiles.map { "• \($0)" }.joined(separator: "\n"))

        📋 Next Steps:
        \(result.instructions.map { "• \($0)" }.joined(separator: "\n"))

        ✅ Template files have been created in your project directory.
        """
    }

    // MARK: - Helpers

    private func makeResponse<T: Encodable>(id: RequestID?, result: T) throws -> MCPResponse {
        MCPResponse(id: id, result: try JSONValue.fromEncodable(result))
    }

    private func resolveProjectURL(from arguments: JSONObject) -> URL {
        if let projectPath = arguments.string("path") ?? arguments.string("project_path") {
            return URL(fileURLWithPath: projectPath)
        }

        return swiftLanguageServer.workspaceURL
    }

    private func projectAnalyzer(for projectURL: URL, arguments: JSONObject? = nil) -> ProjectAnalyzer {
        let options = analysisOptions(from: arguments)
        if isCurrentWorkspace(projectURL), options == runtimeConfiguration.analysis {
            return projectAnalyzer
        }
        return ProjectAnalyzer(projectPath: projectURL, logger: logger, options: options)
    }

    private func architectureAnalyzer(for projectURL: URL, arguments: JSONObject? = nil) -> ArchitectureAnalyzer {
        let options = analysisOptions(from: arguments)
        if isCurrentWorkspace(projectURL), options == runtimeConfiguration.analysis {
            return architectureAnalyzer
        }
        return ArchitectureAnalyzer(projectPath: projectURL, logger: logger, options: options)
    }

    private func symbolSearchEngine(for projectURL: URL) -> SymbolSearchEngine {
        isCurrentWorkspace(projectURL) ? symbolSearchEngine : SymbolSearchEngine(projectPath: projectURL, logger: logger)
    }

    private func iOSFrameworkAnalyzer(for projectURL: URL, arguments: JSONObject? = nil) -> iOSFrameworkAnalysisEngine {
        let options = analysisOptions(from: arguments)
        if isCurrentWorkspace(projectURL), options == runtimeConfiguration.analysis {
            return iOSFrameworkAnalyzer
        }
        return iOSFrameworkAnalysisEngine(projectPath: projectURL, logger: logger, options: options)
    }

    private func isCurrentWorkspace(_ projectURL: URL) -> Bool {
        projectURL.standardizedFileURL.resolvingSymlinksInPath() ==
            swiftLanguageServer.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func analysisOptions(from arguments: JSONObject?) -> AnalysisOptions {
        AnalysisOptions(
            enableArchitectureDetection: arguments?.bool("enable_architecture_detection") ??
                runtimeConfiguration.analysis.enableArchitectureDetection
        )
    }

    private func projectPathInputSchema(includeArchitectureDetectionToggle: Bool = false) -> JSONObject {
        var properties: JSONObject = [
            "project_path": [
                "type": "string",
                "description": "Optional path to the project. Defaults to the current workspace."
            ]
        ]

        if includeArchitectureDetectionToggle {
            properties["enable_architecture_detection"] = [
                "type": "boolean",
                "description": "Optional override. Architecture detection is disabled by default unless enabled in config or per request."
            ]
        }

        return [
            "type": "object",
            "properties": .object(properties),
            "required": []
        ]
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
