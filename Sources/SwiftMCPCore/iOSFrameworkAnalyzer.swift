import Foundation
import Logging

/// iOS framework and UI analysis backed by syntax and semantic project data.
public final class iOSFrameworkAnalysisEngine {
    private let logger: Logger
    private let projectPath: URL
    private let semanticIndex: SemanticProjectIndex
    private let architectureAnalyzer: ArchitectureAnalyzer
    private let sdkCatalog: AppleSDKCatalog
    private let options: AnalysisOptions

    public init(
        projectPath: URL,
        logger: Logger,
        sdkCatalog: AppleSDKCatalog? = nil,
        options: AnalysisOptions = AnalysisOptions()
    ) {
        self.logger = logger
        self.projectPath = projectPath
        self.options = options
        self.semanticIndex = SemanticProjectIndexCache.shared.index(for: projectPath, logger: logger)
        self.architectureAnalyzer = ArchitectureAnalyzer(
            projectPath: projectPath,
            logger: logger,
            semanticIndex: semanticIndex,
            options: options
        )
        self.sdkCatalog = sdkCatalog ?? AppleSDKCatalog(logger: logger)
    }

    // MARK: - Public API

    public func analyzeIOSPatterns() async throws -> iOSAnalysisResult {
        logger.info("📱 Starting iOS pattern analysis")

        let snapshot = try await semanticIndex.snapshot()
        let catalogSummary = try await sdkCatalog.summary()
        let availableAppleModules = try await sdkCatalog.availableModuleNames()
        let importedAppleModules = Set(snapshot.importedModules).intersection(availableAppleModules)
        let foundationModelsModule = try await sdkCatalog.module(named: "FoundationModels")
        let imagePlaygroundModule = try await sdkCatalog.module(named: "ImagePlayground")

        let frameworkUsage = analyzeFrameworkUsage(in: snapshot, availableAppleModules: availableAppleModules)
        let uiPatterns = analyzeUIPatterns(in: snapshot)
        let architecturePatterns = try await analyzeArchitecturePatterns(in: snapshot)
        let modernFeatures = analyzeModernFeatures(in: snapshot)
        let appleModules = try await analyzeAppleModules(
            in: snapshot,
            importedAppleModules: importedAppleModules
        )
        let appleIntelligence = analyzeAppleIntelligence(
            in: snapshot,
            foundationModelsModule: foundationModelsModule,
            imagePlaygroundModule: imagePlaygroundModule
        )
        let documentationReferences = try await sdkCatalog.documentationReferences(
            for: importedAppleModules
        )

        let result = iOSAnalysisResult(
            frameworkUsage: frameworkUsage,
            uiPatterns: uiPatterns,
            architecturePatterns: architecturePatterns,
            modernFeatures: modernFeatures,
            appleModules: appleModules,
            appleIntelligence: appleIntelligence,
            sdkCatalog: catalogSummary,
            documentationReferences: documentationReferences,
            recommendations: generateRecommendations(
                framework: frameworkUsage,
                ui: uiPatterns,
                architecture: architecturePatterns,
                modern: modernFeatures,
                appleModules: appleModules,
                appleIntelligence: appleIntelligence
            )
        )

        logger.info("✅ iOS pattern analysis completed")
        return result
    }

    // MARK: - Apple Framework Detection

    private let networkingSymbols: Set<String> = [
        "Data", "HTTPURLResponse", "JSONDecoder", "JSONEncoder", "NWPathMonitor", "URLComponents",
        "URLRequest", "URLResponse", "URLSession", "URLSessionConfiguration"
    ]

    private let storyboardSymbols: Set<String> = [
        "UIStoryboard", "instantiateInitialViewController", "instantiateViewController", "performSegue"
    ]

    private let autolayoutSymbols: Set<String> = [
        "NSLayoutConstraint", "activate", "constraint", "translatesAutoresizingMaskIntoConstraints"
    ]

    private let swiftUIModifierNames: Set<String> = [
        "onAppear", "onChange", "onDisappear", "task"
    ]

    private let propertyWrapperNames: Set<String> = [
        "AppStorage", "Binding", "Environment", "EnvironmentObject", "ObservedObject", "Published",
        "Query", "SceneStorage", "State", "StateObject"
    ]

    private let foundationModelSymbols: Set<String> = [
        "FoundationModels",
        "Generable",
        "GenerationSchema",
        "LanguageModelSession",
        "SystemLanguageModel"
    ]

    private let imagePlaygroundSymbols: Set<String> = [
        "ImageCreator",
        "ImagePlaygroundConcept",
        "ImagePlaygroundStyle",
        "imagePlaygroundSheet"
    ]

    // MARK: - Framework Usage Analysis

    private func analyzeFrameworkUsage(
        in snapshot: SemanticProjectSnapshot,
        availableAppleModules: Set<String>
    ) -> FrameworkUsage {
        let imports = snapshot.files.reduce(into: [String: Int]()) { counts, file in
            for module in file.imports {
                counts[module, default: 0] += 1
            }
        }

        let appleFrameworksOnly = imports.filter { item in
            !["Combine", "CoreData", "Foundation", "Network", "SwiftUI", "UIKit", "URLSession"].contains(item.key) &&
            availableAppleModules.contains(item.key)
        }

        let networkingCount = (imports["Network"] ?? 0) +
            snapshot.references.filter { networkingSymbols.contains($0.name) }.count

        return FrameworkUsage(
            uiKit: imports["UIKit"] ?? 0,
            swiftUI: imports["SwiftUI"] ?? 0,
            foundation: imports["Foundation"] ?? 0,
            combine: imports["Combine"] ?? 0,
            coreData: (imports["CoreData"] ?? 0) + (imports["SwiftData"] ?? 0),
            networking: networkingCount,
            foundationModels: imports["FoundationModels"] ?? 0,
            imagePlayground: imports["ImagePlayground"] ?? 0,
            other: appleFrameworksOnly,
            dominantFramework: determineDominantFramework(imports)
        )
    }

    private func determineDominantFramework(_ imports: [String: Int]) -> String {
        let uiImports = imports.filter { ["UIKit", "SwiftUI"].contains($0.key) }
        guard let dominant = uiImports.max(by: { $0.value < $1.value }) else {
            return "Foundation"
        }
        return dominant.key
    }

    // MARK: - UI Pattern Analysis

    private func analyzeUIPatterns(in snapshot: SemanticProjectSnapshot) -> UIPatterns {
        let viewControllers = snapshot.types.filter { Set($0.inheritedTypes).contains("UIViewController") }.count
        let swiftUIViews = snapshot.types.filter { Set($0.inheritedTypes).contains("View") }.count
        let storyboardUsage = snapshot.references.filter { storyboardSymbols.contains($0.name) }.count
        let autolayoutUsage = snapshot.references.filter { autolayoutSymbols.contains($0.name) }.count
        let delegatePatterns = snapshot.declarations.filter { $0.name == "delegate" }.count

        return UIPatterns(
            viewControllers: viewControllers,
            swiftUIViews: swiftUIViews,
            storyboardUsage: storyboardUsage,
            autolayoutUsage: autolayoutUsage,
            delegatePatterns: delegatePatterns,
            primaryUIFramework: swiftUIViews > viewControllers ? "SwiftUI" : "UIKit"
        )
    }

    // MARK: - Architecture Pattern Analysis

    private func analyzeArchitecturePatterns(in snapshot: SemanticProjectSnapshot) async throws -> ArchitecturePatterns {
        let detection = architectureAnalyzer.detectArchitecture(in: snapshot)

        return ArchitecturePatterns(
            enabled: options.enableArchitectureDetection,
            mvcScore: detection.score(for: .mvc),
            mvvmScore: detection.score(for: .mvvm),
            mvpScore: detection.score(for: .mvp),
            viperScore: detection.score(for: .viper),
            coordinatorScore: detection.score(for: .coordinator),
            tcaScore: detection.score(for: .tca),
            cleanArchitectureScore: detection.score(for: .cleanArchitecture),
            featuresBasedScore: detection.score(for: .featuresBased),
            modularScore: detection.score(for: .modular),
            dominantPattern: detection.isEnabled ? detection.dominantPattern.rawValue : "Skipped"
        )
    }

    // MARK: - Apple Intelligence Analysis

    private func analyzeAppleModules(
        in snapshot: SemanticProjectSnapshot,
        importedAppleModules: Set<String>
    ) async throws -> [AppleModuleUsage] {
        let importCounts = snapshot.files.reduce(into: [String: Int]()) { counts, file in
            for module in file.imports {
                counts[module, default: 0] += 1
            }
        }
        let projectSymbolCounts = projectSymbolCounts(in: snapshot)

        var usages: [AppleModuleUsage] = []
        usages.reserveCapacity(importedAppleModules.count)

        for moduleName in importedAppleModules.sorted() {
            guard let module = try await sdkCatalog.module(named: moduleName) else {
                continue
            }

            let matchedSymbols = module.symbolNames
                .compactMap { symbolName -> (String, Int)? in
                    guard let count = projectSymbolCounts[symbolName] else {
                        return nil
                    }
                    return (symbolName, count)
                }
                .sorted {
                    if $0.1 == $1.1 {
                        return $0.0 < $1.0
                    }
                    return $0.1 > $1.1
                }

            let symbolHitCount = matchedSymbols.reduce(0) { $0 + $1.1 }
            let sampleSymbols = matchedSymbols.prefix(12).map(\.0)
            let importedDependencies = module.importedModules
                .filter(importedAppleModules.contains)
                .filter { $0 != moduleName }
                .sorted()

            usages.append(
                AppleModuleUsage(
                    moduleName: moduleName,
                    importCount: importCounts[moduleName] ?? 0,
                    kind: module.kind,
                    platforms: module.platforms,
                    symbolHitCount: symbolHitCount,
                    matchedSymbols: sampleSymbols,
                    importedDependencies: importedDependencies
                )
            )
        }

        return usages
    }

    private func analyzeAppleIntelligence(
        in snapshot: SemanticProjectSnapshot,
        foundationModelsModule: AppleSDKModule?,
        imagePlaygroundModule: AppleSDKModule?
    ) -> AppleIntelligenceUsage {
        let imports = Set(snapshot.importedModules)
        let resolvedFoundationModelSymbols = resolvedSymbols(
            requested: foundationModelSymbols.subtracting(["FoundationModels"]),
            from: foundationModelsModule
        )
        let resolvedImagePlaygroundSymbols = resolvedSymbols(
            requested: imagePlaygroundSymbols,
            from: imagePlaygroundModule
        )
        let foundationModelSymbolHits = symbolHits(
            for: resolvedFoundationModelSymbols,
            in: snapshot
        )
        let imagePlaygroundSymbolHits = symbolHits(
            for: resolvedImagePlaygroundSymbols,
            in: snapshot
        )

        var foundationModelFeatures: [String] = []
        if foundationModelSymbolHits["LanguageModelSession", default: 0] > 0 ||
            foundationModelSymbolHits["SystemLanguageModel", default: 0] > 0 {
            foundationModelFeatures.append("Session-based generation")
        }
        if foundationModelSymbolHits["Generable", default: 0] > 0 ||
            foundationModelSymbolHits["GenerationSchema", default: 0] > 0 {
            foundationModelFeatures.append("Structured generation")
        }

        var imagePlaygroundFeatures: [String] = []
        if imagePlaygroundSymbolHits["ImageCreator", default: 0] > 0 {
            imagePlaygroundFeatures.append("Programmatic image creation")
        }
        if imagePlaygroundSymbolHits["imagePlaygroundSheet", default: 0] > 0 {
            imagePlaygroundFeatures.append("SwiftUI sheet presentation")
        }
        if imagePlaygroundSymbolHits["ImagePlaygroundConcept", default: 0] > 0 ||
            imagePlaygroundSymbolHits["ImagePlaygroundStyle", default: 0] > 0 {
            imagePlaygroundFeatures.append("Concept and style configuration")
        }

        return AppleIntelligenceUsage(
            foundationModelsImports: imports.contains("FoundationModels") ? 1 : 0,
            foundationModelSymbolHits: foundationModelSymbolHits,
            foundationModelFeatures: foundationModelFeatures.sorted(),
            imagePlaygroundImports: imports.contains("ImagePlayground") ? 1 : 0,
            imagePlaygroundSymbolHits: imagePlaygroundSymbolHits,
            imagePlaygroundFeatures: imagePlaygroundFeatures.sorted()
        )
    }

    // MARK: - Modern Features Analysis

    private func analyzeModernFeatures(in snapshot: SemanticProjectSnapshot) -> ModernFeatures {
        let asyncAwaitUsage = snapshot.references.filter { ["async", "await"].contains($0.name) }.count
        let actorUsage = snapshot.declarations.filter { $0.kind == "actor" }.count
        let combineUsage = snapshot.files.filter { Set($0.imports).contains("Combine") }.count +
            snapshot.types.filter(isObservableType).count
        let swiftUIModifiers = snapshot.references.filter { swiftUIModifierNames.contains($0.name) }.count
        let propertyWrappers = snapshot.declarations.reduce(into: 0) { count, declaration in
            if !Set(declaration.attributes).intersection(propertyWrapperNames).isEmpty {
                count += 1
            }
        }

        return ModernFeatures(
            asyncAwaitUsage: asyncAwaitUsage,
            actorUsage: actorUsage,
            combineUsage: combineUsage,
            swiftUIModifiers: swiftUIModifiers,
            propertyWrappers: propertyWrappers,
            modernityScore: calculateModernityScore(
                async: asyncAwaitUsage,
                actor: actorUsage,
                combine: combineUsage,
                swiftUI: swiftUIModifiers,
                wrappers: propertyWrappers
            )
        )
    }

    private func calculateModernityScore(async: Int, actor: Int, combine: Int, swiftUI: Int, wrappers: Int) -> Double {
        let totalSignals = async + actor + combine + swiftUI + wrappers
        let baseline = max(1, snapshotBaselineCount())
        return min(100.0, (Double(totalSignals) / Double(baseline)) * 100)
    }

    private func snapshotBaselineCount() -> Int {
        max(10, projectPath.pathComponents.count * 5)
    }

    private func isObservableType(_ type: SemanticTypeSummary) -> Bool {
        let attributes = Set(type.attributes).union(type.memberAttributes)
        return Set(type.inheritedTypes).contains("ObservableObject") ||
            attributes.contains("Observable") ||
            attributes.contains("Published") ||
            type.hasStateObjectWrapper
    }

    private func symbolHits(for symbols: Set<String>, in snapshot: SemanticProjectSnapshot) -> [String: Int] {
        symbols.reduce(into: [String: Int]()) { counts, symbol in
            let totalHits = snapshot.references.filter { $0.name == symbol }.count +
                snapshot.declarations.filter { $0.name == symbol }.count
            if totalHits > 0 {
                counts[symbol] = totalHits
            }
        }
    }

    private func projectSymbolCounts(in snapshot: SemanticProjectSnapshot) -> [String: Int] {
        var counts: [String: Int] = [:]

        for declaration in snapshot.declarations {
            counts[declaration.name, default: 0] += 1
        }

        for reference in snapshot.references {
            counts[reference.name, default: 0] += 1
        }

        return counts
    }

    private func resolvedSymbols(requested: Set<String>, from module: AppleSDKModule?) -> Set<String> {
        guard let module else {
            return requested
        }

        let availableSymbols = Set(module.symbolNames)
        let resolved = requested.intersection(availableSymbols)
        return resolved.isEmpty ? requested : resolved
    }

    // MARK: - Recommendations

    private func generateRecommendations(
        framework: FrameworkUsage,
        ui: UIPatterns,
        architecture: ArchitecturePatterns,
        modern: ModernFeatures,
        appleModules: [AppleModuleUsage],
        appleIntelligence: AppleIntelligenceUsage
    ) -> [String] {
        var recommendations: [String] = []

        if framework.swiftUI > 0 && framework.uiKit > framework.swiftUI {
            recommendations.append("The codebase mixes SwiftUI and UIKit; consider pushing more UI state into SwiftUI views or adapters.")
        }

        if framework.combine == 0 && framework.swiftUI > 0 {
            recommendations.append("SwiftUI is present but Combine or Observation usage is limited; review whether explicit state models would clarify updates.")
        }

        if modern.asyncAwaitUsage == 0 {
            recommendations.append("No async/await usage was detected; review asynchronous APIs for modern concurrency adoption.")
        }

        if modern.modernityScore < 30 {
            recommendations.append("The iOS surface shows limited modern Swift signals; review actors, async/await, and explicit state wrappers where appropriate.")
        }

        if ui.storyboardUsage > 0 && framework.swiftUI > 0 {
            recommendations.append("Both storyboard and SwiftUI navigation are present; reducing mixed navigation styles may simplify maintenance.")
        }

        for module in appleModules where module.importCount > 0 && module.symbolHitCount == 0 {
            recommendations.append("\(module.moduleName) is imported, but no semantic symbol usage was detected in the current snapshot.")
        }

        if appleIntelligence.foundationModelsImports > 0 && appleIntelligence.foundationModelFeatures.isEmpty {
            recommendations.append("Foundation Models is imported, but no core usage signals such as LanguageModelSession or Generable were detected.")
        }

        if appleIntelligence.imagePlaygroundImports > 0 && appleIntelligence.imagePlaygroundFeatures.isEmpty {
            recommendations.append("ImagePlayground is imported, but no usage signals such as ImageCreator or imagePlaygroundSheet were detected.")
        }

        return recommendations
    }
}

// MARK: - Data Structures

public struct iOSAnalysisResult {
    public let frameworkUsage: FrameworkUsage
    public let uiPatterns: UIPatterns
    public let architecturePatterns: ArchitecturePatterns
    public let modernFeatures: ModernFeatures
    public let appleModules: [AppleModuleUsage]
    public let appleIntelligence: AppleIntelligenceUsage
    public let sdkCatalog: AppleSDKCatalogSummary
    public let documentationReferences: [DocumentationReference]
    public let recommendations: [String]
}

public struct FrameworkUsage {
    public let uiKit: Int
    public let swiftUI: Int
    public let foundation: Int
    public let combine: Int
    public let coreData: Int
    public let networking: Int
    public let foundationModels: Int
    public let imagePlayground: Int
    public let other: [String: Int]
    public let dominantFramework: String
}

public struct UIPatterns {
    public let viewControllers: Int
    public let swiftUIViews: Int
    public let storyboardUsage: Int
    public let autolayoutUsage: Int
    public let delegatePatterns: Int
    public let primaryUIFramework: String
}

public struct ArchitecturePatterns {
    public let enabled: Bool
    public let mvcScore: Int
    public let mvvmScore: Int
    public let mvpScore: Int
    public let viperScore: Int
    public let coordinatorScore: Int
    public let tcaScore: Int
    public let cleanArchitectureScore: Int
    public let featuresBasedScore: Int
    public let modularScore: Int
    public let dominantPattern: String
}

public struct ModernFeatures {
    public let asyncAwaitUsage: Int
    public let actorUsage: Int
    public let combineUsage: Int
    public let swiftUIModifiers: Int
    public let propertyWrappers: Int
    public let modernityScore: Double
}

public struct AppleModuleUsage {
    public let moduleName: String
    public let importCount: Int
    public let kind: AppleSDKModuleKind
    public let platforms: [AppleSDKPlatform]
    public let symbolHitCount: Int
    public let matchedSymbols: [String]
    public let importedDependencies: [String]
}

public struct AppleIntelligenceUsage {
    public let foundationModelsImports: Int
    public let foundationModelSymbolHits: [String: Int]
    public let foundationModelFeatures: [String]
    public let imagePlaygroundImports: Int
    public let imagePlaygroundSymbolHits: [String: Int]
    public let imagePlaygroundFeatures: [String]
}

public struct DocumentationReference: Hashable {
    public let title: String
    public let url: String
    public let source: String
}
