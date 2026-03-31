import Foundation
import Logging
import SwiftParser
import SwiftSyntax

actor SemanticProjectIndex {
    private struct FileSignature: Hashable, Sendable {
        let modificationDate: Date?
        let fileSize: Int?
    }

    private struct IndexedFile: Sendable {
        let url: URL
        let signature: FileSignature
    }

    private let projectPath: URL
    private let logger: Logger
    private var cachedSnapshot: SemanticProjectSnapshot?
    private var cachedFileSnapshots: [URL: SemanticFileSnapshot] = [:]
    private var cachedFileSignatures: [URL: FileSignature] = [:]
    private var cachedPackageManifest: SemanticPackageManifest?
    private var cachedPackageSignature: FileSignature?

    init(projectPath: URL, logger: Logger) {
        self.projectPath = projectPath
        self.logger = logger
    }

    func snapshot() async throws -> SemanticProjectSnapshot {
        let snapshot = try await buildSnapshot()
        cachedSnapshot = snapshot
        return snapshot
    }

    func invalidate() {
        cachedSnapshot = nil
        cachedFileSnapshots.removeAll()
        cachedFileSignatures.removeAll()
        cachedPackageManifest = nil
        cachedPackageSignature = nil
    }

    private func buildSnapshot() async throws -> SemanticProjectSnapshot {
        let indexedSwiftFiles = try findAllSwiftFiles()
        let reconciliation = reconcileCachedFiles(with: indexedSwiftFiles)
        let packageState = try packageManifestState()
        let packageChanged = packageState?.signature != cachedPackageSignature ||
            (packageState == nil && (cachedPackageSignature != nil || cachedPackageManifest != nil))

        if reconciliation.changedFiles.isEmpty,
           !reconciliation.removedFiles,
           !packageChanged,
           let cachedSnapshot {
            return cachedSnapshot
        }

        if !reconciliation.changedFiles.isEmpty {
            let parsedFiles = try await parse(files: reconciliation.changedFiles)
            for (url, snapshot) in parsedFiles {
                cachedFileSnapshots[url] = snapshot
            }
        }

        let semanticFiles = indexedSwiftFiles.compactMap { cachedFileSnapshots[$0.url] }
        let packageManifest = try loadPackageManifest(from: packageState)

        logger.debug(
            "📚 Semantic index refreshed: \(semanticFiles.count) files, reparsed \(reconciliation.changedFiles.count), package manifest changed: \(packageChanged)"
        )

        return SemanticProjectSnapshot(
            projectPath: projectPath,
            files: semanticFiles,
            packageTargets: packageManifest?.targets ?? [],
            externalDependencies: packageManifest?.externalDependencies ?? []
        )
    }

    private func findAllSwiftFiles() throws -> [IndexedFile] {
        var swiftFiles: [IndexedFile] = []
        let enumerator = FileManager.default.enumerator(
            at: projectPath,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                swiftFiles.append(
                    IndexedFile(
                        url: url,
                        signature: try signature(for: url)
                    )
                )
            }
        }

        return swiftFiles.sorted { $0.url.path < $1.url.path }
    }

    private func reconcileCachedFiles(with indexedFiles: [IndexedFile]) -> (changedFiles: [IndexedFile], removedFiles: Bool) {
        let currentURLs = Set(indexedFiles.map(\.url))
        let removedURLs = cachedFileSnapshots.keys.filter { !currentURLs.contains($0) }
        removedURLs.forEach { url in
                cachedFileSnapshots.removeValue(forKey: url)
                cachedFileSignatures.removeValue(forKey: url)
            }

        let changedFiles = indexedFiles.filter { indexedFile in
            cachedFileSignatures[indexedFile.url] != indexedFile.signature ||
            cachedFileSnapshots[indexedFile.url] == nil
        }

        return (changedFiles, !removedURLs.isEmpty)
    }

    private func parse(files indexedFiles: [IndexedFile]) async throws -> [URL: SemanticFileSnapshot] {
        guard !indexedFiles.isEmpty else {
            return [:]
        }

        let parsedFiles = try await withThrowingTaskGroup(of: (URL, FileSignature, SemanticFileSnapshot).self) { group in
            for indexedFile in indexedFiles {
                group.addTask {
                    (
                        indexedFile.url,
                        indexedFile.signature,
                        try Self.parse(fileURL: indexedFile.url)
                    )
                }
            }

            var snapshots: [URL: SemanticFileSnapshot] = [:]
            for try await (url, signature, snapshot) in group {
                cachedFileSignatures[url] = signature
                snapshots[url] = snapshot
            }
            return snapshots
        }

        return parsedFiles
    }

    private func packageManifestState() throws -> IndexedFile? {
        let packageManifest = projectPath.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packageManifest.path) else {
            return nil
        }

        return IndexedFile(url: packageManifest, signature: try signature(for: packageManifest))
    }

    private func loadPackageManifest(from state: IndexedFile?) throws -> SemanticPackageManifest? {
        guard let state else {
            cachedPackageManifest = nil
            cachedPackageSignature = nil
            return nil
        }

        if cachedPackageSignature == state.signature, let cachedPackageManifest {
            return cachedPackageManifest
        }

        let source = try String(contentsOf: state.url, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let collector = PackageManifestCollector()
        collector.walk(tree)

        let manifest = collector.manifest
        cachedPackageManifest = manifest
        cachedPackageSignature = state.signature
        return manifest
    }

    private func signature(for url: URL) throws -> FileSignature {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileSignature(
            modificationDate: resourceValues.contentModificationDate,
            fileSize: resourceValues.fileSize
        )
    }

    private static func parse(fileURL: URL) throws -> SemanticFileSnapshot {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileURL.path, tree: tree)
        let collector = SemanticFileCollector(
            fileURL: fileURL,
            source: source,
            converter: converter
        )

        collector.walk(tree)
        return collector.snapshot()
    }
}

final class SemanticProjectIndexCache {
    static let shared = SemanticProjectIndexCache()

    private let lock = NSLock()
    private var indexes: [String: SemanticProjectIndex] = [:]

    func index(for projectPath: URL, logger: Logger) -> SemanticProjectIndex {
        let key = projectPath.standardizedFileURL.resolvingSymlinksInPath().path

        lock.lock()
        defer { lock.unlock() }

        if let existing = indexes[key] {
            return existing
        }

        let index = SemanticProjectIndex(projectPath: projectPath, logger: logger)
        indexes[key] = index
        return index
    }
}

private final class PackageManifestCollector: SyntaxVisitor {
    private var targets: [SemanticPackageTarget] = []
    private var externalDependencies: [SemanticExternalDependency] = []

    var manifest: SemanticPackageManifest {
        SemanticPackageManifest(
            targets: targets,
            externalDependencies: externalDependencies
        )
    }

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text else {
            return .visitChildren
        }

        switch callee {
        case "package":
            if let dependency = makeExternalDependency(from: node.arguments) {
                externalDependencies.append(dependency)
            }
            return .skipChildren
        case "target":
            if let target = makeTarget(from: node.arguments, type: "regular") {
                targets.append(target)
            }
            return .skipChildren
        case "executableTarget":
            if let target = makeTarget(from: node.arguments, type: "executable") {
                targets.append(target)
            }
            return .skipChildren
        case "testTarget":
            if let target = makeTarget(from: node.arguments, type: "test") {
                targets.append(target)
            }
            return .skipChildren
        default:
            return .visitChildren
        }
    }

    private func makeExternalDependency(from arguments: LabeledExprListSyntax) -> SemanticExternalDependency? {
        let name = stringArgument(named: "name", in: arguments)
        let location = stringArgument(named: "url", in: arguments) ?? stringArgument(named: "path", in: arguments)
        let resolvedName = name ?? location.flatMap(deriveDependencyName(from:)) ?? "unknown"

        let requirement = stringArgument(named: "from", in: arguments) ??
            stringArgument(named: "exact", in: arguments) ??
            stringArgument(named: "branch", in: arguments).map { "branch:\($0)" } ??
            stringArgument(named: "revision", in: arguments).map { "revision:\($0)" } ??
            (location != nil ? "local" : nil)

        return SemanticExternalDependency(
            name: resolvedName,
            location: location,
            requirement: requirement
        )
    }

    private func makeTarget(from arguments: LabeledExprListSyntax, type: String) -> SemanticPackageTarget? {
        guard let name = stringArgument(named: "name", in: arguments) else {
            return nil
        }

        let dependencies = dependencyNames(from: expressionArgument(named: "dependencies", in: arguments))
        return SemanticPackageTarget(name: name, type: type, dependencies: dependencies)
    }

    private func stringArgument(named label: String, in arguments: LabeledExprListSyntax) -> String? {
        guard let expression = expressionArgument(named: label, in: arguments) else {
            return nil
        }

        return stringValue(from: expression)
    }

    private func expressionArgument(named label: String, in arguments: LabeledExprListSyntax) -> ExprSyntax? {
        arguments.first(where: { $0.label?.text == label })?.expression
    }

    private func dependencyNames(from expression: ExprSyntax?) -> [String] {
        guard let array = expression?.as(ArrayExprSyntax.self) else {
            return []
        }

        return array.elements.compactMap { element in
            if let stringDependency = stringValue(from: element.expression) {
                return stringDependency
            }

            guard let functionCall = element.expression.as(FunctionCallExprSyntax.self),
                  let callee = functionCall.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text else {
                return nil
            }

            switch callee {
            case "product", "byName", "target":
                return stringArgument(named: "name", in: functionCall.arguments)
            default:
                return nil
            }
        }
    }

    private func stringValue(from expression: ExprSyntax) -> String? {
        let text = expression.trimmedDescription
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else {
            return nil
        }

        let startIndex = text.index(after: text.startIndex)
        let endIndex = text.index(before: text.endIndex)
        return String(text[startIndex..<endIndex])
    }

    private func deriveDependencyName(from location: String) -> String? {
        let rawName = URL(string: location)?.deletingPathExtension().lastPathComponent ??
            URL(fileURLWithPath: location).deletingPathExtension().lastPathComponent
        return rawName.isEmpty ? nil : rawName
    }
}

private final class SemanticFileCollector: SyntaxVisitor {
    private struct TypeContext {
        let name: String
        let kind: String
        let accessLevel: String
        let inheritedTypes: [String]
        let attributes: [String]
        let fileURL: URL
        let line: Int
        let character: Int
        var memberTypeNames: Set<String> = []
        var memberAttributes: Set<String> = []
        var referencedNames: Set<String> = []
        var memberCalls: Set<String> = []
        var hasPrivateInitializer = false
        var hasAssociatedType = false
        var hasStateObjectWrapper = false
    }

    private let fileURL: URL
    private let source: String
    private let converter: SourceLocationConverter
    private let lines: [String]

    private var imports = Set<String>()
    private var declarations: [SemanticDeclaration] = []
    private var references: [SemanticReference] = []
    private var typeContexts: [TypeContext] = []
    private var completedTypes: [SemanticTypeSummary] = []
    private var currentControlFlowDepth = 0
    private var maximumControlFlowDepth = 0

    init(fileURL: URL, source: String, converter: SourceLocationConverter) {
        self.fileURL = fileURL
        self.source = source
        self.converter = converter
        self.lines = source.components(separatedBy: .newlines)
        super.init(viewMode: .sourceAccurate)
    }

    func snapshot() -> SemanticFileSnapshot {
        SemanticFileSnapshot(
            fileURL: fileURL,
            imports: Array(imports).sorted(),
            declarations: declarations,
            references: references,
            types: completedTypes,
            lineCount: lines.count,
            maximumControlFlowDepth: maximumControlFlowDepth
        )
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let importedModule = node.path.trimmedDescription
        imports.insert(importedModule)
        recordReference(
            name: importedModule,
            kind: .importModule,
            node: node
        )
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushTypeContext(
            name: node.name.text,
            kind: "class",
            accessLevel: accessLevel(from: node.modifiers),
            inheritedTypes: inheritedTypeNames(from: node.inheritanceClause),
            attributes: attributeNames(from: node.attributes),
            node: node
        )
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        popTypeContext()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushTypeContext(
            name: node.name.text,
            kind: "struct",
            accessLevel: accessLevel(from: node.modifiers),
            inheritedTypes: inheritedTypeNames(from: node.inheritanceClause),
            attributes: attributeNames(from: node.attributes),
            node: node
        )
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        popTypeContext()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushTypeContext(
            name: node.name.text,
            kind: "enum",
            accessLevel: accessLevel(from: node.modifiers),
            inheritedTypes: inheritedTypeNames(from: node.inheritanceClause),
            attributes: attributeNames(from: node.attributes),
            node: node
        )
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        popTypeContext()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushTypeContext(
            name: node.name.text,
            kind: "protocol",
            accessLevel: accessLevel(from: node.modifiers),
            inheritedTypes: inheritedTypeNames(from: node.inheritanceClause),
            attributes: attributeNames(from: node.attributes),
            node: node
        )
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        popTypeContext()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushTypeContext(
            name: node.name.text,
            kind: "actor",
            accessLevel: accessLevel(from: node.modifiers),
            inheritedTypes: inheritedTypeNames(from: node.inheritanceClause),
            attributes: attributeNames(from: node.attributes),
            node: node
        )
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        popTypeContext()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extendedType = node.extendedType.trimmedDescription
        pushTypeContext(
            name: extendedType,
            kind: "extension",
            accessLevel: accessLevel(from: node.modifiers),
            inheritedTypes: inheritedTypeNames(from: node.inheritanceClause),
            attributes: attributeNames(from: node.attributes),
            node: node
        )
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        popTypeContext()
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        recordDeclaration(
            name: node.name.text,
            kind: "typealias",
            accessLevel: accessLevel(from: node.modifiers),
            attributes: attributeNames(from: node.attributes),
            typeNames: Set(referencedTypeNames(in: node.initializer.value)),
            node: node
        )
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let accessLevel = accessLevel(from: node.modifiers)
        let attributes = attributeNames(from: node.attributes)
        let isStaticMember = isStatic(modifiers: node.modifiers)

        for binding in node.bindings {
            guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            let typeNames = Set(referencedTypeNames(in: binding.typeAnnotation?.type))
            recordDeclaration(
                name: identifierPattern.identifier.text,
                kind: "property",
                accessLevel: accessLevel,
                attributes: attributes,
                typeNames: typeNames,
                isStatic: isStaticMember,
                node: binding.pattern
            )

            if !typeContexts.isEmpty {
                typeContexts[typeContexts.count - 1].memberTypeNames.formUnion(typeNames)
                typeContexts[typeContexts.count - 1].memberAttributes.formUnion(attributes)
                if attributes.contains("StateObject") || attributes.contains("ObservedObject") {
                    typeContexts[typeContexts.count - 1].hasStateObjectWrapper = true
                }
            }
        }

        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let signatureTypes = Set(referencedTypeNames(in: node.signature))
        if node.signature.effectSpecifiers?.asyncSpecifier != nil {
            recordReference(name: "async", kind: .languageFeature, node: node.name)
        }
        recordDeclaration(
            name: node.name.text,
            kind: "function",
            accessLevel: accessLevel(from: node.modifiers),
            attributes: attributeNames(from: node.attributes),
            typeNames: signatureTypes,
            node: node
        )
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let accessLevel = accessLevel(from: node.modifiers)
        if accessLevel == "private" || accessLevel == "fileprivate" {
            if !typeContexts.isEmpty {
                typeContexts[typeContexts.count - 1].hasPrivateInitializer = true
            }
        }

        recordDeclaration(
            name: "init",
            kind: "initializer",
            accessLevel: accessLevel,
            attributes: attributeNames(from: node.attributes),
            typeNames: Set(referencedTypeNames(in: node.signature)),
            node: node
        )
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        if !typeContexts.isEmpty {
            typeContexts[typeContexts.count - 1].hasAssociatedType = true
        }

        recordDeclaration(
            name: node.name.text,
            kind: "associatedtype",
            accessLevel: accessLevel(from: node.modifiers),
            attributes: attributeNames(from: node.attributes),
            typeNames: [],
            node: node
        )
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        recordReference(name: name, kind: .typeReference, node: node)
        if !typeContexts.isEmpty {
            typeContexts[typeContexts.count - 1].referencedNames.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        let kind: SemanticReferenceKind = node.parent?.is(FunctionCallExprSyntax.self) == true ? .functionCall : .valueReference
        recordReference(name: name, kind: kind, node: node)
        if !typeContexts.isEmpty {
            typeContexts[typeContexts.count - 1].referencedNames.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName.text
        recordReference(name: name, kind: .memberAccess, node: node)
        if !typeContexts.isEmpty {
            typeContexts[typeContexts.count - 1].memberCalls.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        for typeName in referencedTypeNames(in: node.type) {
            recordReference(name: typeName, kind: .inheritance, node: node.type)
        }
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let name = attributeName(from: node)
        recordReference(name: name, kind: .attribute, node: node)
        if !typeContexts.isEmpty {
            typeContexts[typeContexts.count - 1].memberAttributes.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        recordReference(name: "await", kind: .languageFeature, node: node)
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: IfExprSyntax) {
        popControlFlow()
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: SwitchExprSyntax) {
        popControlFlow()
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: WhileStmtSyntax) {
        popControlFlow()
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: ForStmtSyntax) {
        popControlFlow()
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: RepeatStmtSyntax) {
        popControlFlow()
    }

    override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: DoStmtSyntax) {
        popControlFlow()
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushControlFlow()
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        popControlFlow()
    }

    private func pushTypeContext(
        name: String,
        kind: String,
        accessLevel: String,
        inheritedTypes: [String],
        attributes: [String],
        node: some SyntaxProtocol
    ) {
        let location = sourceLocation(for: node)
        let typeSummary = TypeContext(
            name: name,
            kind: kind,
            accessLevel: accessLevel,
            inheritedTypes: inheritedTypes,
            attributes: attributes,
            fileURL: fileURL,
            line: location.line,
            character: location.character
        )
        typeContexts.append(typeSummary)

        recordDeclaration(
            name: name,
            kind: kind,
            accessLevel: accessLevel,
            attributes: attributes,
            typeNames: Set(inheritedTypes),
            node: node
        )
    }

    private func popTypeContext() {
        guard let completed = typeContexts.popLast() else {
            return
        }

        completedTypes.append(
            SemanticTypeSummary(
                name: completed.name,
                kind: completed.kind,
                fileURL: completed.fileURL,
                line: completed.line,
                character: completed.character,
                accessLevel: completed.accessLevel,
                inheritedTypes: completed.inheritedTypes,
                attributes: Array(completed.attributes),
                memberTypeNames: Array(completed.memberTypeNames),
                memberAttributes: Array(completed.memberAttributes),
                referencedNames: Array(completed.referencedNames),
                memberCalls: Array(completed.memberCalls),
                hasPrivateInitializer: completed.hasPrivateInitializer,
                hasAssociatedType: completed.hasAssociatedType,
                hasStateObjectWrapper: completed.hasStateObjectWrapper,
                imports: Array(imports)
            )
        )
    }

    private func recordDeclaration(
        name: String,
        kind: String,
        accessLevel: String,
        attributes: [String],
        typeNames: Set<String>,
        isStatic: Bool = false,
        node: some SyntaxProtocol
    ) {
        let location = sourceLocation(for: node)
        let containerName = typeContexts.last?.name

        declarations.append(
            SemanticDeclaration(
                name: name,
                kind: kind,
                fileURL: fileURL,
                line: location.line,
                character: location.character,
                accessLevel: accessLevel,
                containerName: containerName,
                referencedTypeNames: Array(typeNames).sorted(),
                attributes: attributes,
                isStatic: isStatic
            )
        )

        references.append(
            SemanticReference(
                name: name,
                kind: .declaration,
                fileURL: fileURL,
                line: location.line,
                character: location.character,
                enclosingTypeName: containerName,
                context: context(around: location.line)
            )
        )
    }

    private func recordReference(name: String, kind: SemanticReferenceKind, node: some SyntaxProtocol) {
        let location = sourceLocation(for: node)
        references.append(
            SemanticReference(
                name: name,
                kind: kind,
                fileURL: fileURL,
                line: location.line,
                character: location.character,
                enclosingTypeName: typeContexts.last?.name,
                context: context(around: location.line)
            )
        )
    }

    private func sourceLocation(for node: some SyntaxProtocol) -> (line: Int, character: Int) {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let line = max(1, location.line)
        let column = max(1, location.column)
        return (line, column - 1)
    }

    private func context(around lineNumber: Int) -> String {
        let lineIndex = max(0, lineNumber - 1)
        let lowerBound = max(0, lineIndex - 1)
        let upperBound = min(lines.count - 1, lineIndex + 1)
        guard lowerBound <= upperBound else {
            return ""
        }
        return lines[lowerBound...upperBound].joined(separator: "\n")
    }

    private func accessLevel(from modifiers: DeclModifierListSyntax?) -> String {
        let modifierTexts = modifiers?.map(\.name.text) ?? []
        if modifierTexts.contains("public") { return "public" }
        if modifierTexts.contains("package") { return "package" }
        if modifierTexts.contains("private") { return "private" }
        if modifierTexts.contains("fileprivate") { return "fileprivate" }
        return "internal"
    }

    private func isStatic(modifiers: DeclModifierListSyntax?) -> Bool {
        let modifierTexts = modifiers?.map(\.name.text) ?? []
        return modifierTexts.contains("static") || modifierTexts.contains("class")
    }

    private func attributeNames(from attributes: AttributeListSyntax?) -> [String] {
        guard let attributes else {
            return []
        }

        return attributes.compactMap { element in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return nil
            }
            return attributeName(from: attribute)
        }
    }

    private func attributeName(from attribute: AttributeSyntax) -> String {
        attribute.attributeName.trimmedDescription
    }

    private func inheritedTypeNames(from clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else {
            return []
        }

        return clause.inheritedTypes.flatMap { referencedTypeNames(in: $0.type) }
    }

    private func referencedTypeNames(in syntax: (some SyntaxProtocol)?) -> [String] {
        guard let syntax else {
            return []
        }

        return syntax.tokens(viewMode: .sourceAccurate).compactMap { token in
            switch token.tokenKind {
            case .identifier(let identifier):
                return identifier
            default:
                return nil
            }
        }
    }

    private func pushControlFlow() {
        currentControlFlowDepth += 1
        maximumControlFlowDepth = max(maximumControlFlowDepth, currentControlFlowDepth)
    }

    private func popControlFlow() {
        currentControlFlowDepth = max(0, currentControlFlowDepth - 1)
    }
}

struct SemanticProjectSnapshot: Sendable {
    let projectPath: URL
    let files: [SemanticFileSnapshot]
    let packageTargets: [SemanticPackageTarget]
    let externalDependencies: [SemanticExternalDependency]

    var declarations: [SemanticDeclaration] {
        files.flatMap(\.declarations)
    }

    var references: [SemanticReference] {
        files.flatMap(\.references)
    }

    var types: [SemanticTypeSummary] {
        files.flatMap(\.types)
    }

    var importedModules: [String] {
        Array(Set(files.flatMap(\.imports))).sorted()
    }
}

struct SemanticFileSnapshot: Sendable {
    let fileURL: URL
    let imports: [String]
    let declarations: [SemanticDeclaration]
    let references: [SemanticReference]
    let types: [SemanticTypeSummary]
    let lineCount: Int
    let maximumControlFlowDepth: Int
}

struct SemanticDeclaration: Sendable {
    let name: String
    let kind: String
    let fileURL: URL
    let line: Int
    let character: Int
    let accessLevel: String
    let containerName: String?
    let referencedTypeNames: [String]
    let attributes: [String]
    let isStatic: Bool
}

struct SemanticTypeSummary: Sendable {
    let name: String
    let kind: String
    let fileURL: URL
    let line: Int
    let character: Int
    let accessLevel: String
    let inheritedTypes: [String]
    let attributes: [String]
    let memberTypeNames: [String]
    let memberAttributes: [String]
    let referencedNames: [String]
    let memberCalls: [String]
    let hasPrivateInitializer: Bool
    let hasAssociatedType: Bool
    let hasStateObjectWrapper: Bool
    let imports: [String]
}

struct SemanticReference: Sendable {
    let name: String
    let kind: SemanticReferenceKind
    let fileURL: URL
    let line: Int
    let character: Int
    let enclosingTypeName: String?
    let context: String
}

enum SemanticReferenceKind: String, Sendable {
    case declaration
    case inheritance
    case typeReference
    case valueReference
    case functionCall
    case memberAccess
    case attribute
    case importModule
    case languageFeature
}

struct SemanticPackageTarget: Sendable {
    let name: String
    let type: String
    let dependencies: [String]
}

struct SemanticExternalDependency: Sendable {
    let name: String
    let location: String?
    let requirement: String?
}

private struct SemanticPackageManifest: Sendable {
    let targets: [SemanticPackageTarget]
    let externalDependencies: [SemanticExternalDependency]
}
