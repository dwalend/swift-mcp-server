import Foundation
import Logging

/// Analyze Swift project structure from parsed syntax and package metadata.
public final class ArchitectureAnalyzer {
    private let projectPath: URL
    private let logger: Logger
    private let semanticIndex: SemanticProjectIndex
    private let options: AnalysisOptions

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
            semanticIndex: SemanticProjectIndexCache.shared.index(for: projectPath, logger: logger),
            options: AnalysisOptions()
        )
    }

    public convenience init(projectPath: URL, logger: Logger, options: AnalysisOptions) {
        self.init(
            projectPath: projectPath,
            logger: logger,
            semanticIndex: SemanticProjectIndexCache.shared.index(for: projectPath, logger: logger),
            options: options
        )
    }

    init(projectPath: URL, logger: Logger, semanticIndex: SemanticProjectIndex, options: AnalysisOptions = AnalysisOptions()) {
        self.projectPath = projectPath
        self.logger = logger
        self.semanticIndex = semanticIndex
        self.options = options
    }

    public var architectureDetectionEnabled: Bool {
        options.enableArchitectureDetection
    }

    /// Detect the dominant architecture pattern using semantic evidence only.
    public func detectArchitecturePattern() async throws -> ArchitecturePattern {
        logger.debug("🏗️ Detecting architecture pattern in \(projectPath.path)")

        guard options.enableArchitectureDetection else {
            logger.debug("🏗️ Architecture detection skipped because it is disabled in analysis options")
            return .custom
        }

        let snapshot = try await semanticIndex.snapshot()
        return detectArchitecture(in: snapshot).dominantPattern
    }

    /// Return the full semantic architecture scoring result for the current workspace.
    public func detectArchitecture() async throws -> ArchitectureDetectionResult {
        logger.debug("🏗️ Scoring architecture patterns in \(projectPath.path)")

        guard options.enableArchitectureDetection else {
            logger.debug("🏗️ Architecture scoring skipped because it is disabled in analysis options")
            return ArchitectureDetectionResult(dominantPattern: .custom, scores: [:], isEnabled: false)
        }

        let snapshot = try await semanticIndex.snapshot()
        return detectArchitecture(in: snapshot)
    }

    func detectArchitecture(in snapshot: SemanticProjectSnapshot) -> ArchitectureDetectionResult {
        guard options.enableArchitectureDetection else {
            return ArchitectureDetectionResult(dominantPattern: .custom, scores: [:], isEnabled: false)
        }

        let scores = architectureScores(in: snapshot)
        let ranked = scores
            .filter { $0.key != .custom }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return architecturePriority(lhs.key) < architecturePriority(rhs.key)
                }
                return lhs.value > rhs.value
            }

        if let best = ranked.first, best.value >= minimumConfidenceScore(for: best.key) {
            return ArchitectureDetectionResult(dominantPattern: best.key, scores: scores, isEnabled: true)
        }

        return ArchitectureDetectionResult(dominantPattern: .custom, scores: scores, isEnabled: true)
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

    private func architectureScores(in snapshot: SemanticProjectSnapshot) -> [ArchitecturePattern: Int] {
        let protocols = Set(snapshot.types.filter { $0.kind == "protocol" }.map(\.name))
        let observables = snapshot.types.filter(isObservableType)
        let observableNames = Set(observables.map(\.name))
        let views = snapshot.types.filter(isPresentationView)
        let controllers = snapshot.types.filter(isControllerType)
        let presentationTypes = snapshot.types.filter { isPresentationType($0) || isObservableType($0) }
        let repositories = snapshot.types.filter { isRepositoryType($0, protocolNames: protocols) }
        let repositoryNames = Set(repositories.map(\.name))
        let domainNames = Set(
            snapshot.types
                .filter { isDomainType($0, protocolNames: protocols) && $0.kind != "protocol" }
                .map(\.name)
        )
        let roleIndex = ArchitectureRoleIndex(snapshot: snapshot)

        let mvvm = scoreMVVM(
            views: views,
            observableNames: observableNames,
            observables: observables
        )
        let mvc = scoreMVC(
            controllers: controllers,
            domainNames: domainNames,
            observableNames: observableNames
        )
        let mvp = scoreMVP(
            snapshot: snapshot,
            roleIndex: roleIndex,
            observableNames: observableNames
        )
        let viper = scoreVIPER(
            snapshot: snapshot,
            roleIndex: roleIndex,
            repositoryNames: repositoryNames,
            protocolNames: protocols
        )
        let coordinator = scoreCoordinator(snapshot: snapshot, roleIndex: roleIndex)
        let tca = scoreTCA(snapshot: snapshot, views: views)
        let cleanArchitecture = scoreCleanArchitecture(
            snapshot: snapshot,
            presentationTypes: presentationTypes,
            adapterTypes: repositories,
            protocolNames: protocols
        )
        let featuresBased = scoreFeaturesBased(snapshot: snapshot)
        let modular = scoreModular(snapshot: snapshot)

        return [
            .mvc: mvc,
            .mvvm: mvvm,
            .mvp: mvp,
            .viper: viper,
            .coordinator: coordinator,
            .tca: tca,
            .featuresBased: featuresBased,
            .cleanArchitecture: cleanArchitecture,
            .modular: modular,
            .custom: 0
        ]
    }

    private func scoreMVVM(
        views: [SemanticTypeSummary],
        observableNames: Set<String>,
        observables: [SemanticTypeSummary]
    ) -> Int {
        guard !views.isEmpty, !observables.isEmpty else {
            return 0
        }

        var score = 0
        let observableLikeNames = observableNames.union(
            Set(observables.map(\.name).filter { normalizedIdentifier($0).contains("viewmodel") })
        )

        for view in views {
            let references = Set(view.memberTypeNames).union(view.referencedNames)
            if view.hasStateObjectWrapper {
                score += 2
            }
            if !references.intersection(observableLikeNames).isEmpty {
                score += 2
            }
        }

        if observables.contains(where: { normalizedIdentifier($0.name).contains("viewmodel") }) {
            score += 2
        }

        return min(12, score)
    }

    private func scoreMVC(
        controllers: [SemanticTypeSummary],
        domainNames: Set<String>,
        observableNames: Set<String>
    ) -> Int {
        guard !controllers.isEmpty, !domainNames.isEmpty else {
            return 0
        }

        var score = 0
        for controller in controllers {
            let referencedNames = Set(controller.memberTypeNames).union(controller.referencedNames)
            if !referencedNames.intersection(domainNames).isEmpty {
                score += 2
            }
            if referencedNames.intersection(observableNames).isEmpty {
                score += 1
            }
        }

        return min(10, score)
    }

    private func scoreMVP(
        snapshot: SemanticProjectSnapshot,
        roleIndex: ArchitectureRoleIndex,
        observableNames: Set<String>
    ) -> Int {
        guard !roleIndex.presenters.isEmpty else {
            return 0
        }

        let presenterNames = Set(roleIndex.presenters.map(\.name))
        let presenterProtocolNames = Set(
            roleIndex.presenters
                .filter { $0.kind == "protocol" }
                .map(\.name)
        )
        let presentationViews = snapshot.types.filter(isPresentationView)
        let candidateViews = presentationViews.filter { type in
            let referencedNames = Set(type.memberTypeNames).union(type.referencedNames)
            return !referencedNames.intersection(presenterNames.union(presenterProtocolNames)).isEmpty
        }
        let presentersTouchObservable = roleIndex.presenters.contains { presenter in
            let referencedNames = Set(presenter.memberTypeNames).union(presenter.referencedNames)
            return !referencedNames.intersection(observableNames).isEmpty
        }

        guard !candidateViews.isEmpty, !presentersTouchObservable else {
            return 0
        }

        var score = 0
        score += min(4, candidateViews.count * 2)
        score += min(4, roleIndex.presenters.count)

        if roleIndex.presenters.contains(where: { presenter in
            let referencedNames = Set(presenter.memberTypeNames).union(presenter.referencedNames)
            return !referencedNames.intersection(roleIndex.models.union(roleIndex.services)).isEmpty
        }) {
            score += 3
        }

        return min(12, score)
    }

    private func scoreVIPER(
        snapshot: SemanticProjectSnapshot,
        roleIndex: ArchitectureRoleIndex,
        repositoryNames: Set<String>,
        protocolNames: Set<String>
    ) -> Int {
        guard !roleIndex.presenters.isEmpty,
              !roleIndex.interactors.isEmpty,
              !roleIndex.routers.isEmpty else {
            return 0
        }

        let presenterNames = Set(roleIndex.presenters.map(\.name))
        let interactorNames = Set(roleIndex.interactors.map(\.name))
        let routerNames = Set(roleIndex.routers.map(\.name))
        let viewNames = roleIndex.views.union(roleIndex.presentationViews)

        let viewReferencesPresenter = snapshot.types.contains { type in
            (isPresentationView(type) || viewNames.contains(type.name)) &&
            typeReferences(type, names: presenterNames)
        }
        let presenterReferencesInteractor = roleIndex.presenters.contains { presenter in
            typeReferences(presenter, names: interactorNames)
        }
        let presenterReferencesRouter = roleIndex.presenters.contains { presenter in
            typeReferences(presenter, names: routerNames)
        }
        let interactorTouchesDomain = roleIndex.interactors.contains { interactor in
            let referencedNames = Set(interactor.memberTypeNames).union(interactor.referencedNames)
            return !referencedNames.intersection(repositoryNames.union(protocolNames).union(roleIndex.entities)).isEmpty
        }

        guard viewReferencesPresenter, presenterReferencesInteractor, presenterReferencesRouter else {
            return 0
        }

        var score = 0
        score += min(3, roleIndex.presenters.count)
        score += min(3, roleIndex.interactors.count)
        score += min(2, roleIndex.routers.count)
        if !roleIndex.views.isEmpty || !roleIndex.presentationViews.isEmpty {
            score += 2
        }
        if !roleIndex.entities.isEmpty {
            score += 1
        }
        if interactorTouchesDomain {
            score += 2
        }

        return min(14, score)
    }

    private func scoreCoordinator(
        snapshot: SemanticProjectSnapshot,
        roleIndex: ArchitectureRoleIndex
    ) -> Int {
        guard !roleIndex.coordinators.isEmpty else {
            return 0
        }

        let coordinatorNames = Set(roleIndex.coordinators.map(\.name))
        let navigationSymbols: Set<String> = [
            "NavigationPath",
            "NavigationStack",
            "UINavigationController",
            "present",
            "pushViewController",
            "setViewControllers",
            "show",
            "navigationDestination"
        ]
        let startLikeFunctions = Set(
            snapshot.declarations
                .filter { $0.kind == "function" && $0.containerName != nil }
                .filter { declaration in
                    let tokens = normalizedTokens(in: declaration.name)
                    return tokens.contains("start") || tokens.contains("coordinate") || tokens.contains("route")
                }
                .compactMap(\.containerName)
        )
        let coordinatorReferencesChildCoordinator = roleIndex.coordinators.contains { coordinator in
            let referencedNames = Set(coordinator.memberTypeNames).union(coordinator.referencedNames)
            return !referencedNames.intersection(coordinatorNames.subtracting([coordinator.name])).isEmpty
        }
        let coordinatorReferencesNavigation = roleIndex.coordinators.contains { coordinator in
            let referencedNames = Set(coordinator.memberTypeNames)
                .union(coordinator.referencedNames)
                .union(coordinator.memberCalls)
            return !referencedNames.intersection(navigationSymbols).isEmpty
        }

        var score = min(4, roleIndex.coordinators.count * 2)
        if !startLikeFunctions.isEmpty {
            score += 2
        }
        if coordinatorReferencesNavigation {
            score += 3
        }
        if coordinatorReferencesChildCoordinator {
            score += 2
        }

        return min(12, score)
    }

    private func scoreTCA(
        snapshot: SemanticProjectSnapshot,
        views: [SemanticTypeSummary]
    ) -> Int {
        let imports = Set(snapshot.importedModules)
        let tcaSymbols: Set<String> = [
            "BindingReducer",
            "ComposableArchitecture",
            "Dependency",
            "DependencyValues",
            "PresentationAction",
            "PresentationState",
            "Reducer",
            "ReducerOf",
            "ReducerProtocol",
            "Scope",
            "StackAction",
            "StackState",
            "Store",
            "StoreOf",
            "TestStore",
            "WithViewStore"
        ]
        let tcaAttributes: Set<String> = ["ObservableState", "Reducer"]
        let importsTCA = imports.contains("ComposableArchitecture")
        let typeUsesTCA = snapshot.types.filter { type in
            let attributes = Set(type.attributes).union(type.memberAttributes)
            let referencedNames = Set(type.inheritedTypes)
                .union(type.memberTypeNames)
                .union(type.referencedNames)
                .union(type.memberCalls)
            return !attributes.intersection(tcaAttributes).isEmpty ||
                !referencedNames.intersection(tcaSymbols).isEmpty
        }
        let nestedStateContainers = Set(
            snapshot.declarations
                .filter { $0.kind == "struct" && $0.name == "State" }
                .compactMap(\.containerName)
        )
        let nestedActionContainers = Set(
            snapshot.declarations
                .filter { ["enum", "struct"].contains($0.kind) && $0.name == "Action" }
                .compactMap(\.containerName)
        )
        let reducerContainers = nestedStateContainers.intersection(nestedActionContainers)
        let viewStoreBindings = views.filter { view in
            let referencedNames = Set(view.memberTypeNames).union(view.referencedNames).union(view.memberCalls)
            return !referencedNames.intersection(["Store", "StoreOf", "WithViewStore", "ViewStore"]).isEmpty
        }

        guard importsTCA || !typeUsesTCA.isEmpty || !reducerContainers.isEmpty else {
            return 0
        }

        var score = 0
        if importsTCA {
            score += 3
        }
        score += min(4, typeUsesTCA.count * 2)
        score += min(4, reducerContainers.count * 2)
        score += min(3, viewStoreBindings.count * 2)

        return min(16, score)
    }

    private func scoreCleanArchitecture(
        snapshot: SemanticProjectSnapshot,
        presentationTypes: [SemanticTypeSummary],
        adapterTypes: [SemanticTypeSummary],
        protocolNames: Set<String>
    ) -> Int {
        guard !protocolNames.isEmpty, !presentationTypes.isEmpty, !adapterTypes.isEmpty else {
            return 0
        }

        let presentationDependsOnProtocols = presentationTypes.filter { type in
            !Set(type.memberTypeNames).intersection(protocolNames).isEmpty
        }
        let adaptersBackedByProtocols = adapterTypes.filter { type in
            !Set(type.inheritedTypes).intersection(protocolNames).isEmpty
        }

        guard !presentationDependsOnProtocols.isEmpty, !adaptersBackedByProtocols.isEmpty else {
            return 0
        }

        var score = 0
        score += min(4, presentationDependsOnProtocols.count * 2)
        score += min(4, adaptersBackedByProtocols.count * 2)
        if scoreModular(snapshot: snapshot) > 0 {
            score += 2
        }

        return min(12, score)
    }

    private func scoreFeaturesBased(snapshot: SemanticProjectSnapshot) -> Int {
        let internalTargets = snapshot.packageTargets.filter { $0.type == "regular" }
        let targetNames = Set(internalTargets.map(\.name))

        if let executable = snapshot.packageTargets.first(where: { $0.type == "executable" }) {
            let featureTargets = executable.dependencies.filter { targetNames.contains($0) }
            if featureTargets.count >= 2 {
                return min(10, featureTargets.count * 2)
            }
        }

        if internalTargets.count >= 3 {
            return min(8, internalTargets.count)
        }

        return 0
    }

    private func scoreModular(snapshot: SemanticProjectSnapshot) -> Int {
        let internalTargets = snapshot.packageTargets.filter { $0.type != "test" }.count
        guard internalTargets > 1 else {
            return 0
        }
        return min(8, internalTargets * 2)
    }

    private func hasMVVMEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let views = snapshot.types.filter(isPresentationView)
        let observables = snapshot.types.filter(isObservableType)
        let observableNames = Set(observables.map(\.name))
        return scoreMVVM(views: views, observableNames: observableNames, observables: observables) >= minimumConfidenceScore(for: .mvvm)
    }

    private func hasMVCEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let controllers = snapshot.types.filter(isControllerType)
        let observableNames = Set(snapshot.types.filter(isObservableType).map(\.name))
        let modelNames = Set(
            snapshot.types
                .filter { isDomainType($0, protocolNames: []) && $0.kind != "protocol" }
                .map(\.name)
        )
        return scoreMVC(controllers: controllers, domainNames: modelNames, observableNames: observableNames) >= minimumConfidenceScore(for: .mvc)
    }

    private func hasCleanArchitectureEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        let protocols = snapshot.types.filter { $0.kind == "protocol" }
        let protocolNames = Set(protocols.map(\.name))
        let presentationTypes = snapshot.types.filter { isPresentationType($0) || isObservableType($0) }
        let adapterTypes = snapshot.types.filter { isRepositoryType($0, protocolNames: protocolNames) }
        return scoreCleanArchitecture(
            snapshot: snapshot,
            presentationTypes: presentationTypes,
            adapterTypes: adapterTypes,
            protocolNames: protocolNames
        ) >= minimumConfidenceScore(for: .cleanArchitecture)
    }

    private func hasFeaturesBasedEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        scoreFeaturesBased(snapshot: snapshot) >= minimumConfidenceScore(for: .featuresBased)
    }

    private func hasModularEvidence(in snapshot: SemanticProjectSnapshot) -> Bool {
        scoreModular(snapshot: snapshot) >= minimumConfidenceScore(for: .modular)
    }

    private func minimumConfidenceScore(for pattern: ArchitecturePattern) -> Int {
        switch pattern {
        case .mvc:
            return 3
        case .mvvm:
            return 4
        case .mvp:
            return 5
        case .viper:
            return 7
        case .coordinator:
            return 5
        case .tca:
            return 7
        case .featuresBased:
            return 4
        case .cleanArchitecture:
            return 6
        case .modular:
            return 4
        case .custom:
            return Int.max
        }
    }

    private func architecturePriority(_ pattern: ArchitecturePattern) -> Int {
        switch pattern {
        case .tca:
            return 0
        case .viper:
            return 1
        case .cleanArchitecture:
            return 2
        case .mvvm:
            return 3
        case .mvp:
            return 4
        case .coordinator:
            return 5
        case .mvc:
            return 6
        case .featuresBased:
            return 7
        case .modular:
            return 8
        case .custom:
            return 9
        }
    }

    private func typeReferences(_ type: SemanticTypeSummary, names: Set<String>) -> Bool {
        let referencedNames = Set(type.memberTypeNames)
            .union(type.referencedNames)
            .union(type.memberCalls)
            .union(type.inheritedTypes)
        return !referencedNames.intersection(names).isEmpty
    }

    private func normalizedTokens(in value: String) -> Set<String> {
        Self.tokenizeIdentifier(value)
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
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
    case mvp                = "MVP"
    case viper              = "VIPER"
    case coordinator        = "Coordinator"
    case tca                = "TCA"
    case featuresBased      = "Features-based"
    case cleanArchitecture  = "Clean Architecture"
    case modular            = "Modular"
    case custom             = "Custom"

    public var identifier: String {
        switch self {
        case .mvc:
            return "mvc"
        case .mvvm:
            return "mvvm"
        case .mvp:
            return "mvp"
        case .viper:
            return "viper"
        case .coordinator:
            return "coordinator"
        case .tca:
            return "tca"
        case .featuresBased:
            return "features_based"
        case .cleanArchitecture:
            return "clean_architecture"
        case .modular:
            return "modular"
        case .custom:
            return "custom"
        }
    }

    public static func parse(_ value: String) -> ArchitecturePattern? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        return allCases.first {
            $0.identifier == normalized ||
            $0.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_") == normalized
        }
    }
}

public struct ArchitectureDetectionResult {
    public let dominantPattern: ArchitecturePattern
    public let scores: [ArchitecturePattern: Int]
    public let isEnabled: Bool

    public init(dominantPattern: ArchitecturePattern, scores: [ArchitecturePattern: Int], isEnabled: Bool) {
        self.dominantPattern = dominantPattern
        self.scores = scores
        self.isEnabled = isEnabled
    }

    public func score(for pattern: ArchitecturePattern) -> Int {
        scores[pattern, default: 0]
    }
}

private struct ArchitectureRoleIndex {
    let presenters: [SemanticTypeSummary]
    let interactors: [SemanticTypeSummary]
    let routers: [SemanticTypeSummary]
    let coordinators: [SemanticTypeSummary]
    let views: Set<String>
    let presentationViews: Set<String>
    let entities: Set<String>
    let services: Set<String>
    let models: Set<String>

    init(snapshot: SemanticProjectSnapshot) {
        func matches(_ type: SemanticTypeSummary, keywords: Set<String>) -> Bool {
            keywords.contains { ArchitectureAnalyzer.matchesKeyword($0, in: type.name) }
        }

        presenters = snapshot.types.filter { matches($0, keywords: ["presenter"]) }
        interactors = snapshot.types.filter { matches($0, keywords: ["interactor", "usecase"]) }
        routers = snapshot.types.filter { matches($0, keywords: ["router", "routing", "wireframe"]) }
        coordinators = snapshot.types.filter { matches($0, keywords: ["coordinator"]) }
        views = Set(
            snapshot.types
                .filter { matches($0, keywords: ["view"]) && !ArchitectureAnalyzer.matchesKeyword("viewmodel", in: $0.name) }
                .map(\.name)
        )
        presentationViews = Set(
            snapshot.types
                .filter { type in
                    let inherited = Set(type.inheritedTypes)
                    return inherited.contains("UIViewController") ||
                        inherited.contains("NSViewController") ||
                        inherited.contains("View")
                }
                .map(\.name)
        )
        entities = Set(
            snapshot.types
                .filter { matches($0, keywords: ["entity", "model"]) && !ArchitectureAnalyzer.matchesKeyword("viewmodel", in: $0.name) }
                .map(\.name)
        )
        services = Set(snapshot.types.filter { matches($0, keywords: ["service", "repository", "client"]) }.map(\.name))
        models = Set(
            snapshot.types
                .filter { matches($0, keywords: ["model"]) && !ArchitectureAnalyzer.matchesKeyword("viewmodel", in: $0.name) }
                .map(\.name)
        )
    }
}

fileprivate extension ArchitectureAnalyzer {
    static func tokenizeIdentifier(_ value: String) -> Set<String> {
        var token = ""
        var tokens: [String] = []

        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let character = String(scalar)
                if scalar.properties.isUppercase, !token.isEmpty {
                    tokens.append(token.lowercased())
                    token = character
                } else {
                    token += character
                }
            } else if !token.isEmpty {
                tokens.append(token.lowercased())
                token = ""
            }
        }

        if !token.isEmpty {
            tokens.append(token.lowercased())
        }

        return Set(tokens)
    }

    static func matchesKeyword(_ keyword: String, in value: String) -> Bool {
        let normalizedKeyword = keyword.lowercased()
        let normalizedValue = value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        if normalizedValue.contains(normalizedKeyword) {
            return true
        }

        let tokens = tokenizeIdentifier(value)
        return tokens.contains(normalizedKeyword)
    }
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
