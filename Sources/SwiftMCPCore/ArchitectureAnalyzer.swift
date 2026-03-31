import Foundation
import Logging

/// Analyze Swift project structure from parsed syntax and package metadata.
public final class ArchitectureAnalyzer {
    private let projectPath: URL
    private let logger: Logger
    private let semanticIndex: SemanticProjectIndex

    private let uiFrameworkImports: Set<String> = ["AppKit", "SwiftUI", "UIKit", "WatchKit"]
    private let controllerBaseTypes: Set<String> = ["NSViewController", "UIViewController", "WKInterfaceController"]
    private let viewBaseTypes: Set<String> = ["App", "NSView", "Scene", "SwiftUI.View", "UIView", "View"]
    private let persistenceImports: Set<String> = ["CoreData", "GRDB", "RealmSwift", "SQLite3", "SwiftData"]
    private let networkingSymbols: Set<String> = [
        "Data",
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

    public convenience init(projectPath: URL, logger: Logger) {
        self.init(
            projectPath: projectPath,
            logger: logger,
            semanticIndex: SemanticProjectIndexCache.shared.index(for: projectPath, logger: logger)
        )
    }

    init(projectPath: URL, logger: Logger, semanticIndex: SemanticProjectIndex) {
        self.projectPath = projectPath
        self.logger = logger
        self.semanticIndex = semanticIndex
    }

    /// Detect the dominant architecture pattern using semantic evidence only.
    public func detectArchitecturePattern() async throws -> ArchitecturePattern {
        logger.debug("🏗️ Detecting architecture pattern in \(projectPath.path)")

        let snapshot = try await semanticIndex.snapshot()

        if hasMVVMEvidence(in: snapshot) {
            return .mvvm
        }

        if hasCleanArchitectureEvidence(in: snapshot) {
            return .cleanArchitecture
        }

        if hasFeaturesBasedEvidence(in: snapshot) {
            return .featuresBased
        }

        if hasMVCEvidence(in: snapshot) {
            return .mvc
        }

        if hasModularEvidence(in: snapshot) {
            return .modular
        }

        return .custom
    }

    /// Extract modules and semantically classified feature components.
    public func extractModulesAndFeatures() async throws -> ProjectStructure {
        logger.debug("📦 Extracting modules and features")

        let snapshot = try await semanticIndex.snapshot()
        let filesByTarget = filesByTarget(in: snapshot)
        let internalTargets = snapshot.packageTargets.filter { $0.type != "test" }

        let modules: [Module]
        if internalTargets.isEmpty {
            modules = [
                Module(
                    name: projectPath.lastPathComponent,
                    path: projectPath.path,
                    fileCount: snapshot.files.count
                )
            ]
        } else {
            modules = internalTargets.map { target in
                Module(
                    name: target.name,
                    path: inferredTargetPath(for: target).path,
                    fileCount: filesByTarget[target.name, default: []].count
                )
            }
            .sorted { $0.name < $1.name }
        }

        let featureTargetNames = semanticFeatureTargetNames(in: snapshot)
        let features = featureTargetNames.map { targetName in
            let files = filesByTarget[targetName, default: []]
            return Feature(
                name: targetName,
                path: inferredTargetPath(named: targetName, type: targetType(for: targetName, in: snapshot)).path,
                components: analyzeFeatureComponents(in: files, snapshot: snapshot)
            )
        }

        return ProjectStructure(modules: modules, features: features)
    }

    /// Analyze semantic layer separation based on UI, abstraction, and IO boundaries.
    public func analyzeLayerSeparation() async throws -> LayerAnalysis {
        logger.debug("🎯 Analyzing layer separation")

        let snapshot = try await semanticIndex.snapshot()
        let typesByFile = Dictionary(grouping: snapshot.types, by: \.fileURL)
        let declarationsByFile = Dictionary(grouping: snapshot.declarations, by: \.fileURL)
        let protocols = Set(snapshot.types.filter { $0.kind == "protocol" }.map(\.name))
        let layers = LayerAnalysis()

        for file in snapshot.files {
            let fileTypes = typesByFile[file.fileURL, default: []]
            let fileDeclarations = declarationsByFile[file.fileURL, default: []]
            let filePath = file.fileURL.path

            if fileTypes.contains(where: isPresentationType) || fileTypes.contains(where: isObservableType) {
                layers.presentation.append(filePath)
            }

            if fileTypes.contains(where: isDataAdapterType) {
                layers.data.append(filePath)
            }

            if fileTypes.contains(where: { isDomainType($0, protocolNames: protocols) }) {
                layers.domain.append(filePath)
            }

            if shouldClassifyAsInfrastructure(fileTypes: fileTypes, fileDeclarations: fileDeclarations) {
                layers.infrastructure.append(filePath)
            }
        }

        layers.presentation.sort()
        layers.domain.sort()
        layers.data.sort()
        layers.infrastructure.sort()
        return layers
    }

    /// Analyze Protocol-Oriented Programming adoption from declarations and conformances.
    public func analyzePOPUsage() async throws -> POPAnalysisResult {
        logger.debug("🔍 Analyzing Protocol-Oriented Programming usage")

        let snapshot = try await semanticIndex.snapshot()
        let protocolNames = Set(snapshot.types.filter { $0.kind == "protocol" }.map(\.name))
        let totalFiles = snapshot.files.count
        let protocolDefinitions = protocolNames.count
        let protocolExtensions = snapshot.types.filter { $0.kind == "extension" && !$0.inheritedTypes.isEmpty }.count
        let protocolConformances = snapshot.types
            .filter { $0.kind != "protocol" }
            .reduce(into: 0) { count, type in
                count += Set(type.inheritedTypes).intersection(protocolNames).count
            }
        let structUsage = snapshot.declarations.filter { $0.kind == "struct" }.count
        let classUsage = snapshot.declarations.filter { $0.kind == "class" }.count
        let protocolAsTypeUsage = snapshot.declarations
            .filter { !Set($0.referencedTypeNames).intersection(protocolNames).isEmpty }
            .count

        var popPatterns: [String] = []
        if protocolDefinitions > 0 && protocolExtensions > 0 {
            popPatterns.append("Protocols with default implementations")
        }
        if snapshot.types.contains(where: { $0.kind == "protocol" && $0.hasAssociatedType }) {
            popPatterns.append("Protocols with associated types")
        }
        if protocolAsTypeUsage > 0 {
            popPatterns.append("Protocol-backed dependencies")
        }

        let structToClassRatio = classUsage > 0 ? Double(structUsage) / Double(classUsage) : Double(structUsage)
        let protocolDensity = totalFiles > 0 ? Double(protocolDefinitions + protocolExtensions) / Double(totalFiles) : 0
        let conformanceDensity = protocolDefinitions > 0 ? Double(protocolConformances) / Double(protocolDefinitions) : 0
        let popScore = min(100, Int((structToClassRatio * 30) + (protocolDensity * 40) + (conformanceDensity * 30)))

        let level: POPAdoptionLevel
        switch popScore {
        case 80...:
            level = .high
        case 50..<80:
            level = .medium
        case 20..<50:
            level = .low
        default:
            level = .minimal
        }

        return POPAnalysisResult(
            totalFiles: totalFiles,
            protocolDefinitions: protocolDefinitions,
            protocolExtensions: protocolExtensions,
            protocolConformances: protocolConformances,
            structUsage: structUsage,
            classUsage: classUsage,
            protocolAsTypeUsage: protocolAsTypeUsage,
            popPatterns: popPatterns.sorted(),
            popScore: popScore,
            adoptionLevel: level,
            recommendations: generatePOPRecommendations(level: level, structToClassRatio: structToClassRatio)
        )
    }

    // MARK: - Semantic Detection

    private func hasMVVMEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let views = snapshot.types.filter(isPresentationView)
        let observables = snapshot.types.filter(isObservableType)
        let observableNames = Set(observables.map(\.name))

        guard !views.isEmpty, !observables.isEmpty else {
            return false
        }

        return views.contains { view in
            view.hasStateObjectWrapper ||
            !Set(view.memberTypeNames).intersection(observableNames).isEmpty ||
            !Set(view.referencedNames).intersection(observableNames).isEmpty
        }
    }

    private func hasMVCEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let controllers = snapshot.types.filter(isControllerType)
        let observableNames = Set(snapshot.types.filter(isObservableType).map(\.name))
        let modelNames = Set(
            snapshot.types
                .filter { isDomainType($0, protocolNames: []) && $0.kind != "protocol" }
                .map(\.name)
        )

        guard !controllers.isEmpty, !modelNames.isEmpty else {
            return false
        }

        let controllerTouchesModel = controllers.contains { controller in
            let referencedNames = Set(controller.memberTypeNames).union(controller.referencedNames)
            return !referencedNames.intersection(modelNames).isEmpty
        }

        let controllerTouchesObservable = controllers.contains { controller in
            let referencedNames = Set(controller.memberTypeNames).union(controller.referencedNames)
            return !referencedNames.intersection(observableNames).isEmpty
        }

        return controllerTouchesModel && !controllerTouchesObservable
    }

    private func hasCleanArchitectureEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let protocols = snapshot.types.filter { $0.kind == "protocol" }
        let protocolNames = Set(protocols.map(\.name))
        let presentationTypes = snapshot.types.filter { isPresentationType($0) || isObservableType($0) }
        let adapterTypes = snapshot.types.filter { isRepositoryType($0, protocolNames: protocolNames) }

        guard !protocolNames.isEmpty, !presentationTypes.isEmpty, !adapterTypes.isEmpty else {
            return false
        }

        let presentationDependsOnProtocols = presentationTypes.contains { type in
            !Set(type.memberTypeNames).intersection(protocolNames).isEmpty
        }

        return presentationDependsOnProtocols && hasModularEvidence(in: snapshot)
    }

    private func hasFeaturesBasedEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let internalTargets = snapshot.packageTargets.filter { $0.type == "regular" }
        let targetNames = Set(internalTargets.map(\.name))

        if let executable = snapshot.packageTargets.first(where: { $0.type == "executable" }) {
            let featureTargets = executable.dependencies.filter { targetNames.contains($0) }
            return featureTargets.count >= 2
        }

        return internalTargets.count >= 3
    }

    private func hasModularEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        snapshot.packageTargets.filter { $0.type != "test" }.count > 1
    }

    // MARK: - Semantic Structure

    private func analyzeFeatureComponents(
        in files: [SemanticFileSnapshot],
        snapshot: SemanticProjectSnapshot
    ) -> FeatureComponents {
        let fileURLs = Set(files.map(\.fileURL))
        let protocols = Set(snapshot.types.filter { $0.kind == "protocol" }.map(\.name))
        let types = snapshot.types.filter { fileURLs.contains($0.fileURL) }

        let repositories = types.filter { isRepositoryType($0, protocolNames: protocols) }
        let repositoryNames = Set(repositories.map(\.name))

        var components = FeatureComponents()
        components.views = types.filter(isPresentationView).map(\.name).sorted()
        components.viewModels = types.filter(isObservableType).map(\.name).sorted()
        components.models = types
            .filter { isDomainType($0, protocolNames: protocols) && ["class", "enum", "struct"].contains($0.kind) }
            .map(\.name)
            .sorted()
        components.repositories = repositories.map(\.name).sorted()
        components.services = types
            .filter { isDataAdapterType($0) && !repositoryNames.contains($0.name) }
            .map(\.name)
            .sorted()
        return components
    }

    private func semanticFeatureTargetNames(in snapshot: SemanticProjectSnapshot) -> [String] {
        let internalTargets = snapshot.packageTargets.filter { $0.type == "regular" }
        let targetNames = Set(internalTargets.map(\.name))

        if let executable = snapshot.packageTargets.first(where: { $0.type == "executable" }) {
            let directDependencies = executable.dependencies.filter { targetNames.contains($0) }
            if !directDependencies.isEmpty {
                return directDependencies.sorted()
            }
        }

        return internalTargets.map(\.name).sorted()
    }

    private func filesByTarget(in snapshot: SemanticProjectSnapshot) -> [String: [SemanticFileSnapshot]] {
        guard !snapshot.packageTargets.isEmpty else {
            return [:]
        }

        return snapshot.files.reduce(into: [String: [SemanticFileSnapshot]]()) { result, file in
            guard let targetName = targetName(for: file.fileURL, in: snapshot.packageTargets) else {
                return
            }
            result[targetName, default: []].append(file)
        }
    }

    private func targetName(for fileURL: URL, in targets: [SemanticPackageTarget]) -> String? {
        let relativePath = fileURL.path.replacingOccurrences(of: projectPath.path + "/", with: "")

        for target in targets {
            let root = inferredTargetPath(for: target).path.replacingOccurrences(of: projectPath.path + "/", with: "")
            if relativePath.hasPrefix(root + "/") || relativePath == root {
                return target.name
            }
        }

        return nil
    }

    private func targetType(for name: String, in snapshot: SemanticProjectSnapshot) -> String {
        snapshot.packageTargets.first(where: { $0.name == name })?.type ?? "regular"
    }

    private func inferredTargetPath(for target: SemanticPackageTarget) -> URL {
        inferredTargetPath(named: target.name, type: target.type)
    }

    private func inferredTargetPath(named name: String, type: String) -> URL {
        switch type {
        case "test":
            return projectPath.appendingPathComponent("Tests/\(name)")
        default:
            return projectPath.appendingPathComponent("Sources/\(name)")
        }
    }

    // MARK: - Semantic Roles

    private func isPresentationType(_ type: SemanticTypeSummary) -> Bool {
        isPresentationView(type) || isObservableType(type)
    }

    private func isPresentationView(_ type: SemanticTypeSummary) -> Bool {
        let inheritedTypes = Set(type.inheritedTypes)
        return !inheritedTypes.intersection(controllerBaseTypes).isEmpty ||
            !inheritedTypes.intersection(viewBaseTypes).isEmpty
    }

    private func isControllerType(_ type: SemanticTypeSummary) -> Bool {
        !Set(type.inheritedTypes).intersection(controllerBaseTypes).isEmpty
    }

    private func isObservableType(_ type: SemanticTypeSummary) -> Bool {
        let inheritedTypes = Set(type.inheritedTypes)
        let attributes = Set(type.attributes).union(type.memberAttributes)

        return inheritedTypes.contains("ObservableObject") ||
            attributes.contains("Observable") ||
            attributes.contains("Published") ||
            type.hasStateObjectWrapper
    }

    private func isRepositoryType(_ type: SemanticTypeSummary, protocolNames: Set<String>) -> Bool {
        guard isDataAdapterType(type) else {
            return false
        }

        let abstractions = Set(type.inheritedTypes).union(type.memberTypeNames)
        return !abstractions.intersection(protocolNames).isEmpty
    }

    private func isDomainType(_ type: SemanticTypeSummary, protocolNames: Set<String>) -> Bool {
        guard !isPresentationType(type), !isDataAdapterType(type) else {
            return false
        }

        switch type.kind {
        case "protocol":
            return true
        case "enum", "struct":
            return true
        case "class", "actor":
            let imports = Set(type.imports)
            let allowedImports = uiFrameworkImports.union(persistenceImports)
            return imports.intersection(allowedImports).isEmpty ||
                !Set(type.memberTypeNames).intersection(protocolNames).isEmpty
        default:
            return false
        }
    }

    private func isDataAdapterType(_ type: SemanticTypeSummary) -> Bool {
        guard !isPresentationType(type), type.kind != "protocol" else {
            return false
        }

        let imports = Set(type.imports)
        let references = Set(type.referencedNames).union(type.memberCalls).union(type.memberTypeNames)
        return !imports.intersection(persistenceImports).isEmpty ||
            !references.intersection(networkingSymbols).isEmpty
    }

    private func shouldClassifyAsInfrastructure(
        fileTypes: [SemanticTypeSummary],
        fileDeclarations: [SemanticDeclaration]
    ) -> Bool {
        guard !fileTypes.isEmpty || !fileDeclarations.isEmpty else {
            return false
        }

        if fileTypes.contains(where: isPresentationType) || fileTypes.contains(where: isDataAdapterType) {
            return false
        }

        return fileTypes.allSatisfy { $0.kind == "extension" || $0.kind == "typealias" } ||
            fileDeclarations.allSatisfy { ["extension", "function", "property", "typealias"].contains($0.kind) }
    }

    // MARK: - Recommendations

    private func generatePOPRecommendations(level: POPAdoptionLevel, structToClassRatio: Double) -> [String] {
        var recommendations: [String] = []

        switch level {
        case .minimal:
            recommendations.append("Consider defining protocols for shared behaviors")
            recommendations.append("Use protocol extensions for reusable default implementations")
            recommendations.append("Prefer value types when inheritance is not required")
        case .low:
            recommendations.append("Increase protocol-based abstractions between layers")
            recommendations.append("Adopt protocol extensions where concrete implementations repeat")
        case .medium:
            recommendations.append("Good POP adoption; consider associated types for generic abstractions")
            recommendations.append("Use protocol constraints to tighten API contracts")
        case .high:
            recommendations.append("POP usage is already strong and broadly consistent")
        }

        if structToClassRatio < 1.0 {
            recommendations.append("Review whether additional reference types can become value types")
        }

        return recommendations
    }
}

// MARK: - Supporting Types

public enum ArchitecturePattern: String, CaseIterable {
    case mvc                = "MVC"
    case mvvm               = "MVVM"
    case viper              = "VIPER"
    case featuresBased      = "Features-based"
    case cleanArchitecture  = "Clean Architecture"
    case modular            = "Modular"
    case custom             = "Custom"
}

public struct ProjectStructure {
    public let modules: [Module]
    public let features: [Feature]

    public init(modules: [Module], features: [Feature]) {
        self.modules = modules
        self.features = features
    }
}

public struct Module {
    public let name: String
    public let path: String
    public let fileCount: Int

    public init(name: String, path: String, fileCount: Int) {
        self.name = name
        self.path = path
        self.fileCount = fileCount
    }
}

public struct Feature {
    public let name: String
    public let path: String
    public let components: FeatureComponents

    public init(name: String, path: String, components: FeatureComponents) {
        self.name = name
        self.path = path
        self.components = components
    }
}

public struct FeatureComponents {
    public var views: [String] = []
    public var viewModels: [String] = []
    public var models: [String] = []
    public var services: [String] = []
    public var repositories: [String] = []

    public init() {}
}

public class LayerAnalysis {
    public var presentation: [String] = []
    public var domain: [String] = []
    public var data: [String] = []
    public var infrastructure: [String] = []

    public init() {}
}

// MARK: - Protocol-Oriented Programming Analysis

public struct POPAnalysisResult {
    public let totalFiles: Int
    public let protocolDefinitions: Int
    public let protocolExtensions: Int
    public let protocolConformances: Int
    public let structUsage: Int
    public let classUsage: Int
    public let protocolAsTypeUsage: Int
    public let popPatterns: [String]
    public let popScore: Int
    public let adoptionLevel: POPAdoptionLevel
    public let recommendations: [String]

    public init(totalFiles: Int, protocolDefinitions: Int, protocolExtensions: Int, protocolConformances: Int, structUsage: Int, classUsage: Int, protocolAsTypeUsage: Int, popPatterns: [String], popScore: Int, adoptionLevel: POPAdoptionLevel, recommendations: [String]) {
        self.totalFiles = totalFiles
        self.protocolDefinitions = protocolDefinitions
        self.protocolExtensions = protocolExtensions
        self.protocolConformances = protocolConformances
        self.structUsage = structUsage
        self.classUsage = classUsage
        self.protocolAsTypeUsage = protocolAsTypeUsage
        self.popPatterns = popPatterns
        self.popScore = popScore
        self.adoptionLevel = adoptionLevel
        self.recommendations = recommendations
    }
}

public enum POPAdoptionLevel: String, CaseIterable {
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}
