import Foundation
import Logging

/// Comprehensive project analysis backed by syntax and package metadata.
public final class ProjectAnalyzer {
    private let projectPath: URL
    private let logger: Logger
    private let architectureAnalyzer: ArchitectureAnalyzer
    private let semanticIndex: SemanticProjectIndex
    private let options: AnalysisOptions

    private let uiBaseTypes: Set<String> = [
        "App",
        "NSView",
        "NSViewController",
        "Scene",
        "UIView",
        "UIViewController",
        "View",
        "WKInterfaceController"
    ]
    private let persistenceImports: Set<String> = ["CoreData", "GRDB", "RealmSwift", "SQLite3", "SwiftData"]
    private let networkingSymbols: Set<String> = [
        "FileManager",
        "HTTPURLResponse",
        "JSONDecoder",
        "JSONEncoder",
        "ModelContainer",
        "ModelContext",
        "NSManagedObjectContext",
        "NSPersistentContainer",
        "PersistenceController",
        "URLComponents",
        "URLRequest",
        "URLResponse",
        "URLSession"
    ]

    public init(projectPath: URL, logger: Logger, options: AnalysisOptions = AnalysisOptions()) {
        self.projectPath = projectPath
        self.logger = logger
        self.options = options
        self.semanticIndex = SemanticProjectIndexCache.shared.index(for: projectPath, logger: logger)
        self.architectureAnalyzer = ArchitectureAnalyzer(
            projectPath: projectPath,
            logger: logger,
            semanticIndex: self.semanticIndex,
            options: options
        )
    }

    public var architectureDetectionEnabled: Bool {
        options.enableArchitectureDetection
    }

    /// Perform comprehensive project analysis.
    public func analyzeProject() async throws -> ProjectAnalysisResult {
        logger.info("🔍 Starting comprehensive project analysis for \(projectPath.lastPathComponent)")

        async let projectType = determineProjectType()
        async let projectStructure = architectureAnalyzer.extractModulesAndFeatures()
        async let layerAnalysis = architectureAnalyzer.analyzeLayerSeparation()
        async let dependencies = analyzeDependencies()
        async let codeMetrics = calculateCodeMetrics()
        async let testCoverage = analyzeTestStructure()

        let architecturePattern: ArchitecturePattern
        if options.enableArchitectureDetection {
            architecturePattern = try await architectureAnalyzer.detectArchitecturePattern()
        } else {
            architecturePattern = .custom
        }

        let result = ProjectAnalysisResult(
            projectName: projectPath.lastPathComponent,
            projectType: try await projectType,
            architecturePattern: architecturePattern,
            structure: try await projectStructure,
            layers: try await layerAnalysis,
            dependencies: try await dependencies,
            metrics: try await codeMetrics,
            testStructure: try await testCoverage,
            recommendations: []
        )

        let recommendations = try await generateRecommendations(for: result)

        return ProjectAnalysisResult(
            projectName: result.projectName,
            projectType: result.projectType,
            architecturePattern: result.architecturePattern,
            structure: result.structure,
            layers: result.layers,
            dependencies: result.dependencies,
            metrics: result.metrics,
            testStructure: result.testStructure,
            recommendations: recommendations
        )
    }

    /// Create project memory/documentation.
    public func createProjectMemory() async throws -> ProjectMemory {
        logger.info("📝 Creating project memory")

        async let analysis = analyzeProject()
        async let keySymbols = findKeySymbols()
        async let patterns = identifyCodePatterns()

        return ProjectMemory(
            analysis: try await analysis,
            keySymbols: try await keySymbols,
            codePatterns: try await patterns,
            lastUpdated: Date()
        )
    }

    /// Generate migration recommendations.
    public func generateMigrationPlan(to targetArchitecture: ArchitecturePattern) async throws -> MigrationPlan {
        logger.info("🚀 Generating migration plan to \(targetArchitecture.rawValue)")

        let currentAnalysis = try await analyzeProject()
        let currentArchitecture = currentAnalysis.architecturePattern

        if currentArchitecture == targetArchitecture {
            return MigrationPlan(
                from: currentArchitecture,
                to: targetArchitecture,
                steps: [],
                estimatedEffort: .none,
                risks: [],
                benefits: ["Architecture already matches target pattern"]
            )
        }

        let steps = generateMigrationSteps(from: currentArchitecture, to: targetArchitecture)
        let effort = estimateMigrationEffort(steps: steps, currentStructure: currentAnalysis.structure)
        let risks = identifyMigrationRisks(from: currentArchitecture, to: targetArchitecture)
        let benefits = identifyMigrationBenefits(from: currentArchitecture, to: targetArchitecture)

        return MigrationPlan(
            from: currentArchitecture,
            to: targetArchitecture,
            steps: steps,
            estimatedEffort: effort,
            risks: risks,
            benefits: benefits
        )
    }

    // MARK: - Core Analysis

    private func determineProjectType() async throws -> ProjectType {
        let contents = (try? FileManager.default.contentsOfDirectory(at: projectPath, includingPropertiesForKeys: nil)) ?? []

        if contents.contains(where: { $0.pathExtension == "xcworkspace" }) {
            return .xcworkspace
        }

        if contents.contains(where: { $0.pathExtension == "xcodeproj" }) {
            return .xcodeproj
        }

        let snapshot = try await semanticIndex.snapshot()
        if !snapshot.packageTargets.isEmpty {
            return .swiftPackage
        }

        return .unknown
    }

    private func analyzeDependencies() async throws -> DependencyAnalysis {
        let snapshot = try await semanticIndex.snapshot()
        var analysis = DependencyAnalysis()

        analysis.swiftPackages = snapshot.externalDependencies.map { dependency in
            Dependency(
                name: dependency.name,
                type: .swiftPackage,
                version: dependency.requirement ?? dependency.location
            )
        }

        let podfile = projectPath.appendingPathComponent("Podfile")
        if FileManager.default.fileExists(atPath: podfile.path) {
            analysis.cocoapods = try parsePodfile(podfile)
        }

        let cartfile = projectPath.appendingPathComponent("Cartfile")
        if FileManager.default.fileExists(atPath: cartfile.path) {
            analysis.carthage = try parseCartfile(cartfile)
        }

        analysis.internalDependencies = snapshot.importedModules
        return analysis
    }

    private func calculateCodeMetrics() async throws -> CodeMetrics {
        logger.debug("📊 Calculating code metrics")

        let snapshot = try await semanticIndex.snapshot()
        let declarationsByFile = Dictionary(grouping: snapshot.declarations, by: \.fileURL)
        let totalLines = snapshot.files.reduce(0) { $0 + $1.lineCount }
        let totalFiles = snapshot.files.count
        let longestFile = snapshot.files.max(by: { $0.lineCount < $1.lineCount })
        let deepestFile = snapshot.files.max(by: { $0.maximumControlFlowDepth < $1.maximumControlFlowDepth })
        let busiestFile = snapshot.files.max {
            declarationsByFile[$0.fileURL, default: []].count < declarationsByFile[$1.fileURL, default: []].count
        }

        var complexityIndicators: [String] = []
        if let longestFile {
            complexityIndicators.append("Largest file: \(longestFile.fileURL.lastPathComponent) (\(longestFile.lineCount) lines)")
        }
        if let deepestFile, deepestFile.maximumControlFlowDepth > 0 {
            complexityIndicators.append(
                "Deepest control flow: \(deepestFile.fileURL.lastPathComponent) (depth \(deepestFile.maximumControlFlowDepth))"
            )
        }
        if let busiestFile {
            let declarationCount = declarationsByFile[busiestFile.fileURL, default: []].count
            complexityIndicators.append(
                "Most declarations: \(busiestFile.fileURL.lastPathComponent) (\(declarationCount) declarations)"
            )
        }

        return CodeMetrics(
            totalLines: totalLines,
            totalFiles: totalFiles,
            averageFileLength: totalFiles > 0 ? totalLines / totalFiles : 0,
            longestFile: longestFile?.fileURL.path,
            longestFileLines: longestFile?.lineCount,
            complexityIndicators: complexityIndicators
        )
    }

    private func analyzeTestStructure() async throws -> TestStructure {
        logger.debug("🧪 Analyzing test structure")

        let snapshot = try await semanticIndex.snapshot()
        let testFiles = snapshot.files.filter(isTestFile)
        let testTargets = snapshot.packageTargets
            .filter { $0.type == "test" }
            .map(\.name)
            .sorted()

        var testTypes = Set<String>()
        if testFiles.contains(where: { Set($0.imports).contains("XCTest") || Set($0.imports).contains("Testing") }) {
            testTypes.insert("Unit Tests")
        }
        if testFiles.contains(where: { $0.references.contains { ["XCUIApplication", "XCUIElement", "XCUIElementQuery"].contains($0.name) } }) {
            testTypes.insert("UI Tests")
        }
        if testFiles.contains(where: { $0.references.contains { $0.name == "measure" } }) {
            testTypes.insert("Performance Tests")
        }

        var coverage = TestCoverage()
        coverage.hasTests = !testFiles.isEmpty

        let internalTargets = snapshot.packageTargets.filter { $0.type != "test" }
        let internalTargetNames = Set(internalTargets.map(\.name))
        let testedTargets = Set(
            snapshot.packageTargets
                .filter { $0.type == "test" }
                .flatMap(\.dependencies)
        )
        .intersection(internalTargetNames)

        if !internalTargets.isEmpty {
            coverage.estimatedCoverage = (Double(testedTargets.count) / Double(internalTargets.count)) * 100
        }

        return TestStructure(
            testFiles: testFiles.map { $0.fileURL.path }.sorted(),
            testTargets: testTargets,
            testTypes: testTypes.sorted(),
            coverage: coverage
        )
    }

    private func findKeySymbols() async throws -> [SymbolInfo] {
        logger.debug("🔑 Finding key symbols")

        let snapshot = try await semanticIndex.snapshot()
        let referenceCounts = Dictionary(snapshot.references.filter { $0.kind != .declaration }.map { ($0.name, 1) }, uniquingKeysWith: +)
        let typeSummariesByName = Dictionary(grouping: snapshot.types, by: \.name)

        let ranked = snapshot.declarations
            .filter(isInterestingDeclaration)
            .sorted { lhs, rhs in
                let lhsScore = symbolScore(for: lhs, referenceCounts: referenceCounts, typeSummariesByName: typeSummariesByName)
                let rhsScore = symbolScore(for: rhs, referenceCounts: referenceCounts, typeSummariesByName: typeSummariesByName)
                if lhsScore == rhsScore {
                    if lhs.fileURL == rhs.fileURL {
                        return lhs.line < rhs.line
                    }
                    return lhs.fileURL.path < rhs.fileURL.path
                }
                return lhsScore > rhsScore
            }

        var seen = Set<String>()
        var symbols: [SymbolInfo] = []

        for declaration in ranked {
            let key = "\(declaration.fileURL.path):\(declaration.line):\(declaration.name)"
            guard seen.insert(key).inserted else {
                continue
            }

            symbols.append(makeSymbolInfo(from: declaration))
            if symbols.count == 20 {
                break
            }
        }

        return symbols
    }

    private func identifyCodePatterns() async throws -> [CodePattern] {
        logger.debug("🎨 Identifying code patterns")

        let snapshot = try await semanticIndex.snapshot()
        var patterns: [CodePattern] = []
        patterns.append(contentsOf: findSingletonPatterns(in: snapshot))
        patterns.append(contentsOf: findObservationPatterns(in: snapshot))
        patterns.append(contentsOf: findDependencyInversionPatterns(in: snapshot))
        return patterns.sorted { $0.confidence > $1.confidence }
    }

    private func generateRecommendations(for analysis: ProjectAnalysisResult) async throws -> [Recommendation] {
        var recommendations: [Recommendation] = []

        if !analysis.testStructure.coverage.hasTests {
            recommendations.append(
                Recommendation(
                    type: .testing,
                    priority: .high,
                    title: "Add executable tests",
                    description: "No XCTest or Testing-based files were found in the workspace.",
                    actionItems: [
                        "Create at least one test target",
                        "Cover public APIs or entry-point modules first",
                        "Add regression tests for current behavior"
                    ]
                )
            )
        } else if analysis.testStructure.coverage.estimatedCoverage > 0 && analysis.testStructure.coverage.estimatedCoverage < 50 {
            recommendations.append(
                Recommendation(
                    type: .testing,
                    priority: .medium,
                    title: "Expand target-level test coverage",
                    description: "Only \(Int(analysis.testStructure.coverage.estimatedCoverage))% of internal targets are referenced by test targets.",
                    actionItems: [
                        "Add tests for uncovered internal targets",
                        "Map each library target to at least one test target",
                        "Track runtime coverage separately if needed"
                    ]
                )
            )
        }

        if let longestFileLines = analysis.metrics.longestFileLines,
           longestFileLines > max(analysis.metrics.averageFileLength * 2, analysis.metrics.averageFileLength + 200) {
            recommendations.append(
                Recommendation(
                    type: .codeQuality,
                    priority: .medium,
                    title: "Review the largest file",
                    description: "The largest file is substantially larger than the project average.",
                    actionItems: [
                        "Inspect the largest file for mixed responsibilities",
                        "Extract supporting types or services where boundaries are clear",
                        "Add focused tests before refactoring"
                    ]
                )
            )
        }

        return recommendations
    }

    // MARK: - Migration Planning

    private func generateMigrationSteps(from: ArchitecturePattern, to: ArchitecturePattern) -> [MigrationStep] {
        switch (from, to) {
        case (.custom, .mvvm):
            return [
                MigrationStep(title: "Identify presentation entry points", description: "Locate views and controllers that still own domain logic"),
                MigrationStep(title: "Extract observable state", description: "Move UI state and side effects into dedicated observable types"),
                MigrationStep(title: "Define domain dependencies", description: "Inject abstractions rather than concrete data implementations"),
                MigrationStep(title: "Add tests around state transitions", description: "Lock current behavior before refactoring UI wiring")
            ]
        case (.mvc, .mvvm):
            return [
                MigrationStep(title: "Extract view state", description: "Move presentation state out of controllers"),
                MigrationStep(title: "Introduce observable models", description: "Bind controllers or views to observable state holders"),
                MigrationStep(title: "Reduce controller responsibilities", description: "Keep controllers focused on lifecycle and rendering")
            ]
        case (_, .tca):
            return [
                MigrationStep(title: "Define feature reducers", description: "Create reducer-backed feature boundaries with nested State and Action models"),
                MigrationStep(title: "Move side effects behind dependencies", description: "Replace ad-hoc service access with explicit dependency injection"),
                MigrationStep(title: "Bind views to stores", description: "Route UI state through Store or StoreOf rather than direct mutable models"),
                MigrationStep(title: "Add reducer tests", description: "Use deterministic state transition tests before cutting over feature flows")
            ]
        case (_, .coordinator):
            return [
                MigrationStep(title: "Extract navigation ownership", description: "Move navigation flow out of views or controllers into coordinator types"),
                MigrationStep(title: "Define feature entry points", description: "Give each flow a single start boundary and explicit child routing"),
                MigrationStep(title: "Keep screens passive", description: "Let screens request routes instead of constructing downstream screens directly")
            ]
        case (_, .mvp):
            return [
                MigrationStep(title: "Introduce presenters", description: "Move presentation decisions into presenter types or protocols"),
                MigrationStep(title: "Keep views passive", description: "Reduce UI layer responsibilities to rendering and forwarding user input"),
                MigrationStep(title: "Push domain access behind presenters", description: "Let presenters coordinate data dependencies and mapping")
            ]
        case (_, .featuresBased):
            return [
                MigrationStep(title: "Split internal targets", description: "Create feature-scoped modules with explicit dependencies"),
                MigrationStep(title: "Move feature code behind public APIs", description: "Expose only the interfaces each feature needs"),
                MigrationStep(title: "Consolidate shared infrastructure", description: "Push cross-cutting concerns into dedicated shared targets")
            ]
        default:
            return [
                MigrationStep(title: "Define migration boundaries", description: "Map the code you will move and the APIs that must remain stable")
            ]
        }
    }

    private func estimateMigrationEffort(steps: [MigrationStep], currentStructure: ProjectStructure) -> MigrationEffort {
        let fileCount = currentStructure.modules.reduce(0) { $0 + $1.fileCount }
        let featureCount = currentStructure.features.count

        if fileCount < 50 && featureCount < 5 {
            return .low
        } else if fileCount < 150 && featureCount < 15 {
            return .medium
        } else {
            return .high
        }
    }

    private func identifyMigrationRisks(from: ArchitecturePattern, to: ArchitecturePattern) -> [String] {
        var risks = [
            "Potential breaking changes during refactoring",
            "Temporary reduction in development velocity",
            "Need for team alignment on new boundaries"
        ]

        if from == .custom {
            risks.append("Current boundaries are implicit, so extraction order matters")
        }

        return risks
    }

    private func identifyMigrationBenefits(from: ArchitecturePattern, to: ArchitecturePattern) -> [String] {
        switch to {
        case .mvvm:
            return [
                "Clearer presentation-state ownership",
                "Improved UI testability",
                "Less lifecycle code in controllers or views"
            ]
        case .featuresBased:
            return [
                "Better isolation between product areas",
                "Clearer target-level dependencies",
                "Smaller change surface per feature"
            ]
        case .viper:
            return [
                "Highly explicit boundaries",
                "Rigid separation of responsibilities"
            ]
        case .coordinator:
            return [
                "Centralized navigation ownership",
                "Lower coupling between screens"
            ]
        case .mvp:
            return [
                "Passive views with clearer presentation boundaries",
                "Improved presenter testability"
            ]
        case .tca:
            return [
                "Deterministic state transitions",
                "Testable side effects and feature composition",
                "Explicit dependency management"
            ]
        default:
            return [
                "More explicit architecture",
                "Better maintainability"
            ]
        }
    }

    // MARK: - Dependency Parsing

    private func parsePodfile(_ file: URL) throws -> [Dependency] {
        let content = try String(contentsOf: file, encoding: .utf8)
        return content
            .components(separatedBy: .newlines)
            .compactMap { line -> Dependency? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("pod ") else {
                    return nil
                }

                let quotedSegments = trimmed.split(separator: "'").map(String.init)
                if quotedSegments.count >= 2 {
                    return Dependency(name: quotedSegments[1], type: .cocoapod, version: nil)
                }

                let doubleQuotedSegments = trimmed.split(separator: "\"").map(String.init)
                if doubleQuotedSegments.count >= 2 {
                    return Dependency(name: doubleQuotedSegments[1], type: .cocoapod, version: nil)
                }

                return nil
            }
    }

    private func parseCartfile(_ file: URL) throws -> [Dependency] {
        let content = try String(contentsOf: file, encoding: .utf8)
        return content
            .components(separatedBy: .newlines)
            .compactMap { line -> Dependency? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return nil
                }

                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2 else {
                    return nil
                }

                let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return Dependency(name: name, type: .carthage, version: nil)
            }
    }

    // MARK: - Semantic Patterns

    private func findSingletonPatterns(in snapshot: SemanticProjectSnapshot) -> [CodePattern] {
        let staticPropertiesByContainer = Dictionary(grouping: snapshot.declarations.filter { $0.kind == "property" && $0.isStatic }) {
            $0.containerName ?? ""
        }

        return snapshot.types.compactMap { type in
            guard type.hasPrivateInitializer,
                  let declaration = declaration(for: type.name, in: snapshot),
                  staticPropertiesByContainer[type.name]?.contains(where: { $0.referencedTypeNames.contains(type.name) }) == true else {
                return nil
            }

            return CodePattern(
                name: "Singleton",
                description: "A private initializer and same-type static property suggest a singleton boundary in \(type.name)",
                location: declaration.fileURL.path,
                confidence: 0.92
            )
        }
    }

    private func findObservationPatterns(in snapshot: SemanticProjectSnapshot) -> [CodePattern] {
        let observableTypes = snapshot.types.filter(isObservableType)
        let notificationReferences = snapshot.references.filter { $0.name == "NotificationCenter" }

        let semanticPatterns = observableTypes.compactMap { type -> CodePattern? in
            guard let declaration = declaration(for: type.name, in: snapshot) else {
                return nil
            }

            return CodePattern(
                name: "Observation",
                description: "Observable state is exposed through \(type.name)",
                location: declaration.fileURL.path,
                confidence: 0.88
            )
        }

        let notificationPatterns = notificationReferences.map { reference in
            CodePattern(
                name: "Notification Observation",
                description: "NotificationCenter usage suggests event-driven observation",
                location: reference.fileURL.path,
                confidence: 0.72
            )
        }

        return semanticPatterns + notificationPatterns
    }

    private func findDependencyInversionPatterns(in snapshot: SemanticProjectSnapshot) -> [CodePattern] {
        let protocolNames = Set(snapshot.types.filter { $0.kind == "protocol" }.map(\.name))

        return snapshot.types.compactMap { type in
            guard type.kind != "protocol",
                  let abstraction = Set(type.memberTypeNames).intersection(protocolNames).first,
                  let declaration = declaration(for: type.name, in: snapshot) else {
                return nil
            }

            return CodePattern(
                name: "Dependency Inversion",
                description: "\(type.name) depends on the protocol abstraction \(abstraction)",
                location: declaration.fileURL.path,
                confidence: 0.83
            )
        }
    }

    // MARK: - Helpers

    private func isTestFile(_ file: SemanticFileSnapshot) -> Bool {
        let imports = Set(file.imports)
        return file.fileURL.path.contains("/Tests/") ||
            imports.contains("XCTest") ||
            imports.contains("Testing")
    }

    private func isInterestingDeclaration(_ declaration: SemanticDeclaration) -> Bool {
        switch declaration.kind {
        case "actor", "class", "enum", "function", "protocol", "struct":
            return declaration.containerName == nil || isTypeLike(declaration.kind)
        default:
            return false
        }
    }

    private func isTypeLike(_ kind: String) -> Bool {
        ["actor", "class", "enum", "protocol", "struct"].contains(kind)
    }

    private func symbolScore(
        for declaration: SemanticDeclaration,
        referenceCounts: [String: Int],
        typeSummariesByName: [String: [SemanticTypeSummary]]
    ) -> Int {
        var score = referenceCounts[declaration.name, default: 0] * 10

        if isTypeLike(declaration.kind) {
            score += 20
        }
        if declaration.accessLevel == "public" {
            score += 20
        }
        if declaration.containerName == nil {
            score += 10
        }
        if typeSummariesByName[declaration.name, default: []].contains(where: isEntryPointType) {
            score += 50
        }

        return score
    }

    private func isEntryPointType(_ type: SemanticTypeSummary) -> Bool {
        Set(type.attributes).contains("main") || !Set(type.inheritedTypes).intersection(uiBaseTypes).isEmpty
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

    private func declaration(for name: String, in snapshot: SemanticProjectSnapshot) -> SemanticDeclaration? {
        snapshot.declarations.first { $0.name == name && isTypeLike($0.kind) }
    }

    private func isObservableType(_ type: SemanticTypeSummary) -> Bool {
        let attributes = Set(type.attributes).union(type.memberAttributes)
        return Set(type.inheritedTypes).contains("ObservableObject") ||
            attributes.contains("Observable") ||
            attributes.contains("Published") ||
            type.hasStateObjectWrapper
    }

    private func isDataAdapterType(_ type: SemanticTypeSummary) -> Bool {
        guard type.kind != "protocol" else {
            return false
        }

        let imports = Set(type.imports)
        let references = Set(type.referencedNames).union(type.memberCalls).union(type.memberTypeNames)
        return !imports.intersection(persistenceImports).isEmpty ||
            !references.intersection(networkingSymbols).isEmpty
    }
}

// MARK: - Supporting Types

public struct ProjectAnalysisResult {
    public let projectName: String
    public let projectType: ProjectType
    public let architecturePattern: ArchitecturePattern
    public let structure: ProjectStructure
    public let layers: LayerAnalysis
    public let dependencies: DependencyAnalysis
    public let metrics: CodeMetrics
    public let testStructure: TestStructure
    public let recommendations: [Recommendation]

    public init(projectName: String, projectType: ProjectType, architecturePattern: ArchitecturePattern, structure: ProjectStructure, layers: LayerAnalysis, dependencies: DependencyAnalysis, metrics: CodeMetrics, testStructure: TestStructure, recommendations: [Recommendation]) {
        self.projectName = projectName
        self.projectType = projectType
        self.architecturePattern = architecturePattern
        self.structure = structure
        self.layers = layers
        self.dependencies = dependencies
        self.metrics = metrics
        self.testStructure = testStructure
        self.recommendations = recommendations
    }
}

public enum ProjectType: String {
    case xcodeproj = "Xcode Project"
    case xcworkspace = "Xcode Workspace"
    case swiftPackage = "Swift Package"
    case unknown = "Unknown"
}

public struct DependencyAnalysis {
    public var swiftPackages: [Dependency] = []
    public var cocoapods: [Dependency] = []
    public var carthage: [Dependency] = []
    public var internalDependencies: [String] = []

    public init() {}
}

public struct Dependency {
    public let name: String
    public let type: DependencyType
    public let version: String?

    public init(name: String, type: DependencyType, version: String?) {
        self.name = name
        self.type = type
        self.version = version
    }
}

public enum DependencyType {
    case swiftPackage
    case cocoapod
    case carthage
    case framework
}

public struct CodeMetrics {
    public let totalLines: Int
    public let totalFiles: Int
    public let averageFileLength: Int
    public let longestFile: String?
    public let longestFileLines: Int?
    public let complexityIndicators: [String]

    public init(totalLines: Int, totalFiles: Int, averageFileLength: Int, longestFile: String?, longestFileLines: Int?, complexityIndicators: [String]) {
        self.totalLines = totalLines
        self.totalFiles = totalFiles
        self.averageFileLength = averageFileLength
        self.longestFile = longestFile
        self.longestFileLines = longestFileLines
        self.complexityIndicators = complexityIndicators
    }
}

public struct TestStructure {
    public let testFiles: [String]
    public let testTargets: [String]
    public let testTypes: [String]
    public let coverage: TestCoverage

    public init(testFiles: [String], testTargets: [String], testTypes: [String], coverage: TestCoverage) {
        self.testFiles = testFiles
        self.testTargets = testTargets
        self.testTypes = testTypes
        self.coverage = coverage
    }
}

public struct TestCoverage {
    public var estimatedCoverage: Double = 0
    public var hasTests: Bool = false

    public init() {}
}

public struct ProjectMemory {
    public let analysis: ProjectAnalysisResult
    public let keySymbols: [SymbolInfo]
    public let codePatterns: [CodePattern]
    public let lastUpdated: Date

    public init(analysis: ProjectAnalysisResult, keySymbols: [SymbolInfo], codePatterns: [CodePattern], lastUpdated: Date) {
        self.analysis = analysis
        self.keySymbols = keySymbols
        self.codePatterns = codePatterns
        self.lastUpdated = lastUpdated
    }
}

public struct CodePattern {
    public let name: String
    public let description: String
    public let location: String
    public let confidence: Double

    public init(name: String, description: String, location: String, confidence: Double) {
        self.name = name
        self.description = description
        self.location = location
        self.confidence = confidence
    }
}

public struct Recommendation {
    public let type: RecommendationType
    public let priority: Priority
    public let title: String
    public let description: String
    public let actionItems: [String]

    public init(type: RecommendationType, priority: Priority, title: String, description: String, actionItems: [String]) {
        self.type = type
        self.priority = priority
        self.title = title
        self.description = description
        self.actionItems = actionItems
    }
}

public enum RecommendationType {
    case architecture
    case codeQuality
    case testing
    case dependencies
    case performance
    case security
}

public enum Priority {
    case low
    case medium
    case high
    case critical
}

public struct MigrationPlan {
    public let from: ArchitecturePattern
    public let to: ArchitecturePattern
    public let steps: [MigrationStep]
    public let estimatedEffort: MigrationEffort
    public let risks: [String]
    public let benefits: [String]

    public init(from: ArchitecturePattern, to: ArchitecturePattern, steps: [MigrationStep], estimatedEffort: MigrationEffort, risks: [String], benefits: [String]) {
        self.from = from
        self.to = to
        self.steps = steps
        self.estimatedEffort = estimatedEffort
        self.risks = risks
        self.benefits = benefits
    }
}

public struct MigrationStep {
    public let title: String
    public let description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

public enum MigrationEffort {
    case none
    case low
    case medium
    case high
}
