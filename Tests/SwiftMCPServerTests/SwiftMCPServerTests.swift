import XCTest
import Logging
@testable import SwiftMCPCore

final class SwiftMCPServerTests: XCTestCase {

    func testMCPProtocolHandlerInitialization() throws {
        defer { cleanupCurrentWorkspaceProjectMemory() }

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
                "name": "analyze_project",
                "arguments": {
                    "project_path": "/tmp/project",
                    "include_tests": true,
                    "targets": ["App", "Tests"]
                }
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let request = try JSONDecoder().decode(MCPRequest.self, from: data)

        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.method, "tools/call")
        XCTAssertEqual(request.params?.string("name"), "analyze_project")
        XCTAssertEqual(request.params?.object("arguments")?.string("project_path"), "/tmp/project")
        XCTAssertEqual(request.params?.object("arguments")?.bool("include_tests"), true)
        XCTAssertEqual(request.params?.object("arguments")?.array("targets")?.count, 2)
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

    func testToolsListIncludesWorkspaceAwareProjectTools() async throws {
        defer { cleanupCurrentWorkspaceProjectMemory() }

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

        let analyzeProject = try XCTUnwrap(
            tools
                .compactMap(\.objectValue)
                .first(where: { $0.string("name") == "analyze_project" })
        )

        XCTAssertEqual(analyzeProject.object("inputSchema")?.object("properties")?.object("project_path")?.string("type"), "string")
    }

    func testAnalyzeProjectDefaultsToCurrentWorkspace() async throws {
        defer { cleanupCurrentWorkspaceProjectMemory() }

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

        let response = try await handler.handleRequest(request)
        let result = try XCTUnwrap(response.result?.objectValue)
        let content = try XCTUnwrap(result["content"]?.arrayValue?.first?.objectValue?.string("text"))

        XCTAssertTrue(content.contains("Project Analysis"))
        XCTAssertTrue(content.contains("swift-mcp-server"))
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

    func testFormatDocumentUsesSourceKitLSP() async throws {
        try XCTSkipUnless(sourceKitLSPAvailable())

        let workspace = try makeTemporaryPackage(named: "FormattingWorkspace")
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

    func testArchitectureAnalyzerDetectsMVVMFromSemanticEvidence() async throws {
        let workspace = try makeTemporaryPackage(named: "SemanticArchitecture")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/SemanticArchitecture/ContentView.swift")
        try """
        import SwiftUI

        struct ContentView: View {
            @StateObject private var viewModel = CounterViewModel()

            var body: some View {
                Text(viewModel.title)
            }
        }

        final class CounterViewModel: ObservableObject {
            @Published var title = "Hello"
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let analyzer = ArchitectureAnalyzer(
            projectPath: workspace,
            logger: Logger(label: "test"),
            options: AnalysisOptions(enableArchitectureDetection: true)
        )
        let pattern = try await analyzer.detectArchitecturePattern()

        XCTAssertEqual(pattern, .mvvm)
    }

    func testArchitectureAnalyzerDetectsTCAFromSemanticEvidence() async throws {
        let workspace = try makeTemporaryPackage(named: "SemanticTCA")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/SemanticTCA/CounterFeature.swift")
        try """
        import SwiftUI
        import ComposableArchitecture

        @Reducer
        struct CounterFeature {
            @ObservableState
            struct State: Equatable {
                var count = 0
            }

            enum Action {
                case incrementTapped
            }

            var body: some ReducerOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .incrementTapped:
                        state.count += 1
                        return .none
                    }
                }
            }
        }

        struct CounterView: View {
            let store: StoreOf<CounterFeature>

            var body: some View {
                Text("\\(store)")
            }
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let analyzer = ArchitectureAnalyzer(
            projectPath: workspace,
            logger: Logger(label: "test"),
            options: AnalysisOptions(enableArchitectureDetection: true)
        )
        let detection = try await analyzer.detectArchitecture()

        XCTAssertEqual(detection.dominantPattern, .tca)
        XCTAssertGreaterThan(detection.score(for: .tca), detection.score(for: .mvvm))
    }

    func testArchitectureAnalyzerDetectsVIPERFromSemanticEvidence() async throws {
        let workspace = try makeTemporaryPackage(named: "SemanticVIPER")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/SemanticVIPER/LoginModule.swift")
        try """
        import UIKit

        protocol LoginView: AnyObject {
            func render()
        }

        protocol LoginRouting {
            func showHome()
        }

        protocol LoginInteractorProtocol {
            func loadUser() -> LoginEntity
        }

        struct LoginEntity {
            let name: String
        }

        final class LoginRepository {
            func fetchUser() -> LoginEntity {
                LoginEntity(name: "Blob")
            }
        }

        final class LoginInteractor: LoginInteractorProtocol {
            let repository: LoginRepository

            init(repository: LoginRepository) {
                self.repository = repository
            }

            func loadUser() -> LoginEntity {
                repository.fetchUser()
            }
        }

        final class LoginRouter: LoginRouting {
            func showHome() {}
        }

        final class LoginPresenter {
            weak var view: (any LoginView)?
            let interactor: LoginInteractorProtocol
            let router: LoginRouting

            init(interactor: LoginInteractorProtocol, router: LoginRouting) {
                self.interactor = interactor
                self.router = router
            }

            func login() {
                _ = interactor.loadUser()
                view?.render()
                router.showHome()
            }
        }

        final class LoginViewController: UIViewController, LoginView {
            let presenter: LoginPresenter

            init(presenter: LoginPresenter) {
                self.presenter = presenter
                super.init(nibName: nil, bundle: nil)
            }

            required init?(coder: NSCoder) {
                fatalError()
            }

            func render() {}
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let analyzer = ArchitectureAnalyzer(
            projectPath: workspace,
            logger: Logger(label: "test"),
            options: AnalysisOptions(enableArchitectureDetection: true)
        )
        let detection = try await analyzer.detectArchitecture()

        XCTAssertEqual(detection.dominantPattern, .viper)
        XCTAssertGreaterThanOrEqual(detection.score(for: .viper), 7)
    }

    func testArchitectureAnalyzerDetectsCoordinatorFromSemanticEvidence() async throws {
        let workspace = try makeTemporaryPackage(named: "SemanticCoordinator")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/SemanticCoordinator/AppCoordinator.swift")
        try """
        import UIKit

        protocol AppCoordinating {
            func start()
        }

        final class LoginCoordinator {
            let navigationController: UINavigationController

            init(navigationController: UINavigationController) {
                self.navigationController = navigationController
            }

            func coordinateToLogin() {
                navigationController.pushViewController(UIViewController(), animated: true)
            }
        }

        final class AppCoordinator: AppCoordinating {
            let navigationController: UINavigationController
            let childCoordinator: LoginCoordinator

            init(navigationController: UINavigationController, childCoordinator: LoginCoordinator) {
                self.navigationController = navigationController
                self.childCoordinator = childCoordinator
            }

            func start() {
                navigationController.setViewControllers([], animated: false)
                childCoordinator.coordinateToLogin()
            }
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let analyzer = ArchitectureAnalyzer(
            projectPath: workspace,
            logger: Logger(label: "test"),
            options: AnalysisOptions(enableArchitectureDetection: true)
        )
        let detection = try await analyzer.detectArchitecture()

        XCTAssertEqual(detection.dominantPattern, .coordinator)
        XCTAssertGreaterThanOrEqual(detection.score(for: .coordinator), 5)
    }

    func testArchitecturePatternParsingAcceptsIdentifiersAndDisplayNames() {
        XCTAssertEqual(ArchitecturePattern.parse("tca"), .tca)
        XCTAssertEqual(ArchitecturePattern.parse("clean_architecture"), .cleanArchitecture)
        XCTAssertEqual(ArchitecturePattern.parse("Clean Architecture"), .cleanArchitecture)
        XCTAssertEqual(ArchitecturePattern.parse("Features-based"), .featuresBased)
    }

    func testArchitectureDetectionIsDisabledByDefault() async throws {
        let workspace = try makeTemporaryPackage(named: "DisabledArchitecture")
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeFile(
            at: "Sources/DisabledArchitecture/ContentView.swift",
            relativeTo: workspace,
            contents: """
            import SwiftUI

            struct ContentView: View {
                @StateObject private var viewModel = CounterViewModel()

                var body: some View {
                    Text(viewModel.title)
                }
            }

            final class CounterViewModel: ObservableObject {
                @Published var title = "Hello"
            }
            """
        )

        let analyzer = ArchitectureAnalyzer(projectPath: workspace, logger: Logger(label: "test"))
        let detection = try await analyzer.detectArchitecture()

        XCTAssertFalse(detection.isEnabled)
        XCTAssertEqual(detection.dominantPattern, .custom)
    }

    func testDetectArchitectureToolRequiresExplicitEnablement() async throws {
        let workspace = try makeTemporaryPackage(named: "ArchitectureToolWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeFile(
            at: "Sources/ArchitectureToolWorkspace/ContentView.swift",
            relativeTo: workspace,
            contents: """
            import SwiftUI

            struct ContentView: View {
                @StateObject private var viewModel = CounterViewModel()

                var body: some View {
                    Text(viewModel.title)
                }
            }

            final class CounterViewModel: ObservableObject {
                @Published var title = "Hello"
            }
            """
        )

        let logger = Logger(label: "test")
        let swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspace)
        let handler = MCPProtocolHandler(swiftLanguageServer: swiftLanguageServer, logger: logger)

        let disabledRequest = MCPRequest(
            jsonrpc: "2.0",
            id: .string("detect-disabled"),
            method: "tools/call",
            params: [
                "name": "detect_architecture",
                "arguments": [:]
            ]
        )

        let disabledResponse = try await handler.handleRequest(disabledRequest)
        let disabledText = try XCTUnwrap(
            disabledResponse.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?.string("text")
        )
        XCTAssertTrue(disabledText.contains("disabled"))

        let enabledRequest = MCPRequest(
            jsonrpc: "2.0",
            id: .string("detect-enabled"),
            method: "tools/call",
            params: [
                "name": "detect_architecture",
                "arguments": [
                    "enable_architecture_detection": true
                ]
            ]
        )

        let enabledResponse = try await handler.handleRequest(enabledRequest)
        let enabledText = try XCTUnwrap(
            enabledResponse.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?.string("text")
        )
        XCTAssertTrue(enabledText.contains("MVVM"))
    }

    func testSymbolSearchReflectsImmediateFileChanges() async throws {
        let workspace = try makeTemporaryPackage(named: "ImmediateSearchWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("Sources/ImmediateSearchWorkspace/main.swift")
        try """
        struct Greeter {
            func greet() {}
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let engine = SymbolSearchEngine(projectPath: workspace, logger: Logger(label: "test"))

        let initialSymbols = try await engine.findSymbols(namePattern: "^Greeter$", useRegex: true)
        XCTAssertEqual(initialSymbols.map(\.name), ["Greeter"])

        try """
        struct GreeterRenamed {
            func greet() {}
        }
        """
            .write(to: sourceFile, atomically: true, encoding: .utf8)

        let renamedSymbols = try await engine.findSymbols(namePattern: "^GreeterRenamed$", useRegex: true)
        XCTAssertEqual(renamedSymbols.map(\.name), ["GreeterRenamed"])

        let staleSymbols = try await engine.findSymbols(namePattern: "^Greeter$", useRegex: true)
        XCTAssertTrue(staleSymbols.isEmpty)
    }

    func testProjectAnalyzerParsesPackageManifestSemantically() async throws {
        let workspace = try makeTemporaryPackage(named: "SemanticPackage")
        defer { try? FileManager.default.removeItem(at: workspace) }

        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "SemanticPackage",
            dependencies: [
                .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0")
            ],
            targets: [
                .executableTarget(
                    name: "SemanticPackage",
                    dependencies: ["CoreFeature"]
                ),
                .target(
                    name: "CoreFeature",
                    dependencies: [
                        .product(name: "Logging", package: "swift-log")
                    ]
                ),
                .testTarget(
                    name: "SemanticPackageTests",
                    dependencies: ["CoreFeature"]
                )
            ]
        )
        """
            .write(to: workspace.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try writeFile(
            at: "Sources/CoreFeature/CoreService.swift",
            relativeTo: workspace,
            contents: """
            import Foundation
            import Logging

            public protocol GreetingProviding {
                func greeting() -> String
            }

            public struct CoreService: GreetingProviding {
                public init() {}

                public func greeting() -> String {
                    Logger(label: "test").info("hello")
                    return "Hello"
                }
            }
            """
        )

        try writeFile(
            at: "Sources/SemanticPackage/main.swift",
            relativeTo: workspace,
            contents: """
            import CoreFeature

            print(CoreService().greeting())
            """
        )

        try writeFile(
            at: "Tests/SemanticPackageTests/CoreServiceTests.swift",
            relativeTo: workspace,
            contents: """
            import XCTest
            @testable import CoreFeature

            final class CoreServiceTests: XCTestCase {
                func testGreeting() {
                    XCTAssertEqual(CoreService().greeting(), "Hello")
                }
            }
            """
        )

        let analyzer = ProjectAnalyzer(
            projectPath: workspace,
            logger: Logger(label: "test"),
            options: AnalysisOptions(enableArchitectureDetection: true)
        )
        let analysis = try await analyzer.analyzeProject()

        XCTAssertEqual(analysis.projectType, .swiftPackage)
        XCTAssertEqual(analysis.architecturePattern, .modular)
        XCTAssertEqual(analysis.dependencies.swiftPackages.map(\.name), ["swift-log"])
        XCTAssertEqual(analysis.structure.modules.map(\.name), ["CoreFeature", "SemanticPackage"])
        XCTAssertEqual(analysis.testStructure.testTargets, ["SemanticPackageTests"])
        XCTAssertTrue(analysis.testStructure.coverage.hasTests)
        XCTAssertEqual(analysis.testStructure.coverage.estimatedCoverage, 50, accuracy: 0.1)
    }

    func testProjectAnalyzerDoesNotRecommendArchitectureWhenClassificationIsCustom() async throws {
        let workspace = try makeTemporaryPackage(named: "UnclassifiedWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeFile(
            at: "Sources/UnclassifiedWorkspace/main.swift",
            relativeTo: workspace,
            contents: """
            import Foundation

            struct Greeter {
                func greet() -> String {
                    "Hello"
                }
            }

            print(Greeter().greet())
            """
        )

        let analyzer = ProjectAnalyzer(projectPath: workspace, logger: Logger(label: "test"))
        let analysis = try await analyzer.analyzeProject()

        XCTAssertEqual(analysis.architecturePattern, .custom)
        XCTAssertFalse(analysis.recommendations.contains { $0.type == .architecture })
    }

    func testAppleSDKCatalogBuildsModuleIndexFromSyntheticSDK() async throws {
        let sdkRoot = try makeSyntheticSDKRoot(
            modules: [
                "SwiftUI": """
                public import Swift

                public protocol View {}

                extension View {
                    public func imagePlaygroundSheet() -> some View
                }
                """,
                "FoundationModels": """
                public import Foundation
                public protocol Generable {}
                public struct LanguageModelSession {}
                public struct GenerationSchema {}
                """,
                "ImagePlayground": """
                public import SwiftUI
                public struct ImageCreator {}
                public struct ImagePlaygroundConcept {}
                public struct ImagePlaygroundStyle {}
                extension View {
                    public func imagePlaygroundSheet() -> some View
                }
                """
            ]
        )
        defer { try? FileManager.default.removeItem(at: sdkRoot) }

        let catalog = AppleSDKCatalog(
            logger: Logger(label: "test"),
            sdkPaths: [.iOSSimulator: sdkRoot],
            xcodeVersion: "Xcode 26.4"
        )

        let summary = try await catalog.summary()
        XCTAssertEqual(summary.moduleCount, 3)
        XCTAssertEqual(summary.xcodeVersion, "Xcode 26.4")
        XCTAssertEqual(summary.platforms.first?.moduleCount, 3)

        let foundationModelsModule = try await catalog.module(named: "FoundationModels")
        let foundationModels = try XCTUnwrap(foundationModelsModule)
        XCTAssertTrue(foundationModels.symbolNames.contains("Generable"))
        XCTAssertTrue(foundationModels.symbolNames.contains("LanguageModelSession"))

        let documentationReferences = try await catalog.documentationReferences(
            for: Set(["SwiftUI", "FoundationModels", "ImagePlayground"])
        )
        XCTAssertTrue(documentationReferences.contains { $0.url == "https://www.swift.org/documentation/" })
        XCTAssertTrue(documentationReferences.contains { $0.url == "https://developer.apple.com/documentation/swiftui/documents" })
        XCTAssertTrue(documentationReferences.contains {
            $0.url == "https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models"
        })
        XCTAssertTrue(documentationReferences.contains {
            $0.url == "https://developer.apple.com/documentation/ImagePlayground/ImageCreator"
        })
    }

    func testiOSFrameworkAnalyzerIncludesOfficialDocumentationReferences() async throws {
        let workspace = try makeTemporaryPackage(named: "AppleIntelligenceWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sdkRoot = try makeSyntheticSDKRoot(
            modules: [
                "SwiftUI": """
                public import Swift

                public protocol View {}

                extension View {
                    public func imagePlaygroundSheet() -> some View
                }
                """,
                "FoundationModels": """
                public import Foundation
                public protocol Generable {}
                public struct LanguageModelSession {}
                public struct GenerationSchema {}
                public struct SystemLanguageModel {}
                """,
                "ImagePlayground": """
                public import SwiftUI
                public struct ImageCreator {}
                public struct ImagePlaygroundConcept {}
                public struct ImagePlaygroundStyle {}
                extension View {
                    public func imagePlaygroundSheet() -> some View
                }
                """
            ]
        )
        defer { try? FileManager.default.removeItem(at: sdkRoot) }

        let catalog = AppleSDKCatalog(
            logger: Logger(label: "test"),
            sdkPaths: [.iOSSimulator: sdkRoot],
            xcodeVersion: "Xcode 26.4"
        )

        try writeFile(
            at: "Sources/AppleIntelligenceWorkspace/ContentView.swift",
            relativeTo: workspace,
            contents: """
            import SwiftUI
            import FoundationModels
            import ImagePlayground

            @Generable
            struct TripIdea {
                let title: String
            }

            struct ContentView: View {
                var body: some View {
                    Text("Hello")
                        .imagePlaygroundSheet(isPresented: .constant(false)) { _ in }
                }

                func prepare() {
                    _ = LanguageModelSession.self
                    _ = ImageCreator.self
                    _ = ImagePlaygroundConcept.self
                    _ = ImagePlaygroundStyle.self
                }
            }
            """
        )

        let analyzer = iOSFrameworkAnalysisEngine(
            projectPath: workspace,
            logger: Logger(label: "test"),
            sdkCatalog: catalog
        )
        let result = try await analyzer.analyzeIOSPatterns()

        XCTAssertEqual(result.frameworkUsage.foundationModels, 1)
        XCTAssertEqual(result.frameworkUsage.imagePlayground, 1)
        XCTAssertEqual(result.sdkCatalog.moduleCount, 3)
        XCTAssertTrue(result.appleIntelligence.foundationModelFeatures.contains("Session-based generation"))
        XCTAssertTrue(result.appleIntelligence.foundationModelFeatures.contains("Structured generation"))
        XCTAssertTrue(result.appleIntelligence.imagePlaygroundFeatures.contains("Programmatic image creation"))
        XCTAssertTrue(result.appleIntelligence.imagePlaygroundFeatures.contains("SwiftUI sheet presentation"))
        XCTAssertTrue(result.documentationReferences.contains { $0.url == "https://www.swift.org/documentation/" })
        XCTAssertTrue(result.documentationReferences.contains { $0.url == "https://developer.apple.com/documentation/swiftui/documents" })
        XCTAssertTrue(result.documentationReferences.contains {
            $0.url == "https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models"
        })
        XCTAssertTrue(result.documentationReferences.contains {
            $0.url == "https://developer.apple.com/documentation/ImagePlayground/ImageCreator"
        })
    }

    func testiOSFrameworkAnalyzerReportsGenericAppleModules() async throws {
        let workspace = try makeTemporaryPackage(named: "GenericAppleModulesWorkspace")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sdkRoot = try makeSyntheticSDKRoot(
            modules: [
                "Vision": """
                public import Foundation
                public struct VNRecognizeTextRequest {}
                public struct VNImageRequestHandler {}
                """,
                "NaturalLanguage": """
                public import Foundation
                public struct NLTagger {}
                public struct NLLanguageRecognizer {}
                """,
                "MapKit": """
                public import Foundation
                public struct MKMapView {}
                public struct MKCoordinateRegion {}
                """
            ]
        )
        defer { try? FileManager.default.removeItem(at: sdkRoot) }

        let catalog = AppleSDKCatalog(
            logger: Logger(label: "test"),
            sdkPaths: [.iOSSimulator: sdkRoot],
            xcodeVersion: "Xcode 26.4"
        )

        try writeFile(
            at: "Sources/GenericAppleModulesWorkspace/main.swift",
            relativeTo: workspace,
            contents: """
            import Vision
            import NaturalLanguage
            import MapKit

            func analyze() {
                _ = VNRecognizeTextRequest.self
                _ = VNImageRequestHandler.self
                _ = NLTagger.self
                _ = MKMapView.self
            }
            """
        )

        let analyzer = iOSFrameworkAnalysisEngine(
            projectPath: workspace,
            logger: Logger(label: "test"),
            sdkCatalog: catalog
        )
        let result = try await analyzer.analyzeIOSPatterns()

        let visionUsage = try XCTUnwrap(result.appleModules.first(where: { $0.moduleName == "Vision" }))
        XCTAssertGreaterThan(visionUsage.symbolHitCount, 0)
        XCTAssertTrue(visionUsage.matchedSymbols.contains("VNRecognizeTextRequest"))

        let naturalLanguageUsage = try XCTUnwrap(result.appleModules.first(where: { $0.moduleName == "NaturalLanguage" }))
        XCTAssertGreaterThan(naturalLanguageUsage.symbolHitCount, 0)
        XCTAssertTrue(naturalLanguageUsage.matchedSymbols.contains("NLTagger"))

        let mapKitUsage = try XCTUnwrap(result.appleModules.first(where: { $0.moduleName == "MapKit" }))
        XCTAssertGreaterThan(mapKitUsage.symbolHitCount, 0)
        XCTAssertTrue(mapKitUsage.matchedSymbols.contains("MKMapView"))

        XCTAssertTrue(result.documentationReferences.contains { $0.url == "https://developer.apple.com/documentation/Vision" })
        XCTAssertTrue(result.documentationReferences.contains { $0.url == "https://developer.apple.com/documentation/NaturalLanguage" })
        XCTAssertTrue(result.documentationReferences.contains { $0.url == "https://developer.apple.com/documentation/MapKit" })
    }

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

    private func cleanupCurrentWorkspaceProjectMemory() {
        let projectMemoryDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".swift-mcp-memory", isDirectory: true)
        try? FileManager.default.removeItem(at: projectMemoryDirectory)
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

    private func writeFile(at relativePath: String, relativeTo root: URL, contents: String) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func makeSyntheticSDKRoot(modules: [String: String]) throws -> URL {
        let sdkRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        for (moduleName, interfaceContents) in modules {
            let interfaceDirectory = sdkRoot
                .appendingPathComponent("System/Library/Frameworks/\(moduleName).framework/Modules/\(moduleName).swiftmodule", isDirectory: true)
            try FileManager.default.createDirectory(at: interfaceDirectory, withIntermediateDirectories: true)
            let interfaceFile = interfaceDirectory.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface")
            try interfaceContents.write(to: interfaceFile, atomically: true, encoding: .utf8)
        }

        return sdkRoot
    }
}
