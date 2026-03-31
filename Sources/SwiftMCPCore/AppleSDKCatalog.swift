import Foundation
import Logging
import SwiftParser
import SwiftSyntax

public actor AppleSDKCatalog {
    private struct ModuleRecord {
        let name: String
        var kind: AppleSDKModuleKind
        var platforms: Set<AppleSDKPlatform>
        var interfacePaths: Set<URL>
    }

    private struct CatalogIndex {
        let developerDirectory: URL?
        let xcodeVersion: String?
        let sdkPaths: [AppleSDKPlatform: URL]
        let modules: [String: ModuleRecord]
    }

    private let logger: Logger
    private let configuredSDKPaths: [AppleSDKPlatform: URL]?
    private let configuredToolchainPaths: [AppleSDKPlatform: URL]
    private let developerDirectoryOverride: URL?
    private let xcodeVersionOverride: String?

    private var cachedIndex: CatalogIndex?
    private var cachedModuleDetails: [String: AppleSDKModule] = [:]

    public init(
        logger: Logger,
        sdkPaths: [AppleSDKPlatform: URL]? = nil,
        toolchainSwiftPaths: [AppleSDKPlatform: URL] = [:],
        developerDirectory: URL? = nil,
        xcodeVersion: String? = nil
    ) {
        self.logger = logger
        self.configuredSDKPaths = sdkPaths
        self.configuredToolchainPaths = toolchainSwiftPaths
        self.developerDirectoryOverride = developerDirectory
        self.xcodeVersionOverride = xcodeVersion
    }

    public func summary() async throws -> AppleSDKCatalogSummary {
        let index = try buildIndex()
        let platformSummaries = index.sdkPaths
            .map { platform, path in
                AppleSDKPlatformSummary(
                    platform: platform,
                    sdkPath: path.path,
                    moduleCount: index.modules.values.filter { $0.platforms.contains(platform) }.count
                )
            }
            .sorted { $0.platform.sortOrder < $1.platform.sortOrder }

        return AppleSDKCatalogSummary(
            xcodeVersion: index.xcodeVersion,
            developerDirectory: index.developerDirectory?.path,
            moduleCount: index.modules.count,
            platforms: platformSummaries
        )
    }

    public func availableModuleNames() async throws -> Set<String> {
        Set(try buildIndex().modules.keys)
    }

    public func contains(module name: String) async throws -> Bool {
        try buildIndex().modules[name] != nil
    }

    public func module(named name: String) async throws -> AppleSDKModule? {
        let index = try buildIndex()
        guard let record = index.modules[name] else {
            return nil
        }

        if let cachedModule = cachedModuleDetails[name] {
            return cachedModule
        }

        let module = try loadModule(from: record)
        cachedModuleDetails[name] = module
        return module
    }

    public func documentationReferences(for modules: Set<String>) async throws -> [DocumentationReference] {
        let index = try buildIndex()
        var references = Set<DocumentationReference>()

        references.insert(
            DocumentationReference(
                title: "Swift Language Documentation",
                url: "https://www.swift.org/documentation/",
                source: "swift.org"
            )
        )

        for moduleName in modules.sorted() where index.modules[moduleName] != nil {
            for reference in documentationReferences(forModuleNamed: moduleName) {
                references.insert(reference)
            }
        }

        return references.sorted { lhs, rhs in
            if lhs.source == rhs.source {
                return lhs.title < rhs.title
            }
            return lhs.source < rhs.source
        }
    }

    private func buildIndex() throws -> CatalogIndex {
        if let cachedIndex {
            return cachedIndex
        }

        let developerDirectory = try developerDirectoryOverride ?? discoverDeveloperDirectory()
        let xcodeVersion = xcodeVersionOverride ?? discoverXcodeVersion()
        var sdkPaths = try configuredSDKPaths ?? discoverSDKPaths()

        for (platform, path) in configuredToolchainPaths where sdkPaths[platform] == nil {
            sdkPaths[platform] = path
        }

        var modules: [String: ModuleRecord] = [:]

        for (platform, sdkPath) in sdkPaths {
            try scanFrameworkModules(in: sdkPath, platform: platform, modules: &modules)
            try scanSwiftModules(in: sdkPath, platform: platform, modules: &modules)

            if let toolchainPath = configuredToolchainPaths[platform] {
                try scanSwiftModules(in: toolchainPath, platform: platform, modules: &modules)
            } else if configuredSDKPaths == nil, let developerDirectory {
                let inferredToolchainPath = inferredToolchainSwiftPath(
                    developerDirectory: developerDirectory,
                    platform: platform
                )
                if FileManager.default.fileExists(atPath: inferredToolchainPath.path) {
                    try scanSwiftModules(in: inferredToolchainPath, platform: platform, modules: &modules)
                }
            }
        }

        let index = CatalogIndex(
            developerDirectory: developerDirectory,
            xcodeVersion: xcodeVersion,
            sdkPaths: sdkPaths,
            modules: modules
        )
        cachedIndex = index
        return index
    }

    private func discoverDeveloperDirectory() throws -> URL? {
        let selected = try runProcess(executable: "/usr/bin/xcode-select", arguments: ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: selected)
    }

    private func discoverXcodeVersion() -> String? {
        guard let output = try? runProcess(executable: "/usr/bin/xcodebuild", arguments: ["-version"]) else {
            return nil
        }
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first
    }

    private func discoverSDKPaths() throws -> [AppleSDKPlatform: URL] {
        var sdkPaths: [AppleSDKPlatform: URL] = [:]

        for platform in AppleSDKPlatform.allCases {
            guard let path = try sdkPath(for: platform) else {
                continue
            }
            sdkPaths[platform] = path
        }

        return sdkPaths
    }

    private func sdkPath(for platform: AppleSDKPlatform) throws -> URL? {
        do {
            let output = try runProcess(
                executable: "/usr/bin/xcrun",
                arguments: ["--sdk", platform.sdkIdentifier, "--show-sdk-path"]
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: trimmed)
        } catch {
            logger.debug("Skipping unavailable SDK \(platform.sdkIdentifier): \(String(describing: error))")
            return nil
        }
    }

    private func scanFrameworkModules(
        in sdkPath: URL,
        platform: AppleSDKPlatform,
        modules: inout [String: ModuleRecord]
    ) throws {
        let frameworksRoot = sdkPath.appendingPathComponent("System/Library/Frameworks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: frameworksRoot.path) else {
            return
        }

        let frameworkURLs = try FileManager.default.contentsOfDirectory(
            at: frameworksRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for frameworkURL in frameworkURLs where frameworkURL.pathExtension == "framework" {
            let frameworkName = frameworkURL.deletingPathExtension().lastPathComponent
            guard shouldIncludeModule(named: frameworkName) else {
                continue
            }

            let moduleDirectory = frameworkURL
                .appendingPathComponent("Modules", isDirectory: true)
                .appendingPathComponent("\(frameworkName).swiftmodule", isDirectory: true)

            let interfacePaths = try swiftInterfacePaths(in: moduleDirectory)
            registerModule(
                named: frameworkName,
                kind: .framework,
                platform: platform,
                interfacePaths: interfacePaths,
                modules: &modules
            )
        }
    }

    private func scanSwiftModules(
        in root: URL,
        platform: AppleSDKPlatform,
        modules: inout [String: ModuleRecord]
    ) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swiftmodule" else {
                continue
            }

            let moduleName = url.deletingPathExtension().lastPathComponent
            guard shouldIncludeModule(named: moduleName) else {
                continue
            }

            let interfacePaths = try swiftInterfacePaths(in: url)
            guard !interfacePaths.isEmpty else {
                continue
            }

            registerModule(
                named: moduleName,
                kind: .library,
                platform: platform,
                interfacePaths: interfacePaths,
                modules: &modules
            )
        }
    }

    private func swiftInterfacePaths(in moduleDirectory: URL) throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: moduleDirectory.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: moduleDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return Set(contents.filter { $0.pathExtension == "swiftinterface" })
    }

    private func registerModule(
        named name: String,
        kind: AppleSDKModuleKind,
        platform: AppleSDKPlatform,
        interfacePaths: Set<URL>,
        modules: inout [String: ModuleRecord]
    ) {
        guard !interfacePaths.isEmpty else {
            return
        }

        if var existing = modules[name] {
            existing.kind = existing.kind == .framework ? .framework : kind
            existing.platforms.insert(platform)
            existing.interfacePaths.formUnion(interfacePaths)
            modules[name] = existing
            return
        }

        modules[name] = ModuleRecord(
            name: name,
            kind: kind,
            platforms: [platform],
            interfacePaths: interfacePaths
        )
    }

    private func loadModule(from record: ModuleRecord) throws -> AppleSDKModule {
        var importedModules = Set<String>()
        var symbolNames = Set<String>()
        var memberSymbolsByContainer: [String: Set<String>] = [:]

        for interfacePath in record.interfacePaths.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: interfacePath, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let collector = AppleSDKInterfaceCollector()
            collector.walk(tree)

            importedModules.formUnion(collector.importedModules)
            symbolNames.formUnion(collector.symbolNames)
            for (container, members) in collector.memberSymbolsByContainer {
                memberSymbolsByContainer[container, default: []].formUnion(members)
            }
        }

        return AppleSDKModule(
            name: record.name,
            kind: record.kind,
            platforms: record.platforms.sorted(by: { $0.sortOrder < $1.sortOrder }),
            interfacePaths: record.interfacePaths.map(\.path).sorted(),
            importedModules: importedModules.sorted(),
            symbolNames: symbolNames.sorted(),
            memberSymbolsByContainer: memberSymbolsByContainer
                .mapValues { $0.sorted() }
        )
    }

    private func documentationReferences(forModuleNamed moduleName: String) -> [DocumentationReference] {
        switch moduleName {
        case "Swift":
            return [
                DocumentationReference(
                    title: "Swift Language Documentation",
                    url: "https://www.swift.org/documentation/",
                    source: "swift.org"
                )
            ]

        case "SwiftUI":
            return [
                genericDeveloperDocumentationReference(for: moduleName),
                DocumentationReference(
                    title: "SwiftUI Documents",
                    url: "https://developer.apple.com/documentation/swiftui/documents",
                    source: "developer.apple.com"
                ),
                DocumentationReference(
                    title: "SwiftUI Resources",
                    url: "https://developer.apple.com/swiftui/resources/",
                    source: "developer.apple.com"
                )
            ]

        case "FoundationModels":
            return [
                genericDeveloperDocumentationReference(for: moduleName),
                DocumentationReference(
                    title: "Foundation Models Guide",
                    url: "https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models",
                    source: "developer.apple.com"
                ),
                DocumentationReference(
                    title: "Apple Intelligence Get Started",
                    url: "https://developer.apple.com/apple-intelligence/get-started/",
                    source: "developer.apple.com"
                ),
                DocumentationReference(
                    title: "Foundation Models Code-Along",
                    url: "https://developer.apple.com/events/resources/code-along-205/",
                    source: "developer.apple.com"
                )
            ]

        case "ImagePlayground":
            return [
                genericDeveloperDocumentationReference(for: moduleName),
                DocumentationReference(
                    title: "ImageCreator API",
                    url: "https://developer.apple.com/documentation/ImagePlayground/ImageCreator",
                    source: "developer.apple.com"
                ),
                DocumentationReference(
                    title: "ImagePlaygroundConcept API",
                    url: "https://developer.apple.com/documentation/ImagePlayground/ImagePlaygroundConcept",
                    source: "developer.apple.com"
                )
            ]

        default:
            guard shouldPublishDeveloperDocumentation(for: moduleName) else {
                return []
            }
            return [genericDeveloperDocumentationReference(for: moduleName)]
        }
    }

    private func genericDeveloperDocumentationReference(for moduleName: String) -> DocumentationReference {
        DocumentationReference(
            title: "\(moduleName) API Reference",
            url: "https://developer.apple.com/documentation/\(moduleName)",
            source: "developer.apple.com"
        )
    }

    private func shouldIncludeModule(named moduleName: String) -> Bool {
        guard !moduleName.hasPrefix("_") else {
            return false
        }
        guard !moduleName.hasSuffix("_Private") else {
            return false
        }
        guard moduleName != "SwiftOnoneSupport" else {
            return false
        }
        return moduleName.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private func shouldPublishDeveloperDocumentation(for moduleName: String) -> Bool {
        moduleName != "Swift"
    }

    private func inferredToolchainSwiftPath(developerDirectory: URL, platform: AppleSDKPlatform) -> URL {
        developerDirectory
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain", isDirectory: true)
            .appendingPathComponent("usr/lib/swift/\(platform.sdkIdentifier)", isDirectory: true)
    }

    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw AppleSDKCatalogError.processFailed(
                executable: executable,
                arguments: arguments,
                error: stderr.isEmpty ? stdout : stderr
            )
        }

        return stdout
    }
}

public enum AppleSDKPlatform: String, CaseIterable, Hashable, Sendable {
    case iOS = "iphoneos"
    case iOSSimulator = "iphonesimulator"
    case macOS = "macosx"
    case tvOS = "appletvos"
    case tvOSSimulator = "appletvsimulator"
    case watchOS = "watchos"
    case watchOSSimulator = "watchsimulator"
    case visionOS = "xros"
    case visionOSSimulator = "xrsimulator"

    var sdkIdentifier: String {
        rawValue
    }

    var sortOrder: Int {
        switch self {
        case .iOS: return 0
        case .iOSSimulator: return 1
        case .macOS: return 2
        case .tvOS: return 3
        case .tvOSSimulator: return 4
        case .watchOS: return 5
        case .watchOSSimulator: return 6
        case .visionOS: return 7
        case .visionOSSimulator: return 8
        }
    }
}

public enum AppleSDKModuleKind: String, Hashable, Sendable {
    case framework
    case library
}

public struct AppleSDKCatalogSummary: Hashable, Sendable {
    public let xcodeVersion: String?
    public let developerDirectory: String?
    public let moduleCount: Int
    public let platforms: [AppleSDKPlatformSummary]
}

public struct AppleSDKPlatformSummary: Hashable, Sendable {
    public let platform: AppleSDKPlatform
    public let sdkPath: String
    public let moduleCount: Int
}

public struct AppleSDKModule: Hashable, Sendable {
    public let name: String
    public let kind: AppleSDKModuleKind
    public let platforms: [AppleSDKPlatform]
    public let interfacePaths: [String]
    public let importedModules: [String]
    public let symbolNames: [String]
    public let memberSymbolsByContainer: [String: [String]]
}

enum AppleSDKCatalogError: Error {
    case processFailed(executable: String, arguments: [String], error: String)
}

private final class AppleSDKInterfaceCollector: SyntaxVisitor {
    private var containerStack: [String] = []

    var importedModules = Set<String>()
    var symbolNames = Set<String>()
    var memberSymbolsByContainer: [String: Set<String>] = [:]

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let importPath = node.path.trimmedDescription
        if let moduleName = importPath.split(separator: ".").first {
            importedModules.insert(String(moduleName))
        }
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(named: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        popContainer()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(named: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        popContainer()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(named: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        popContainer()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(named: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        popContainer()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(named: node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        popContainer()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushExtensionContainer(named: node.extendedType.trimmedDescription)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        popContainer()
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        registerSymbol(named: node.name.text)
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        registerSymbol(named: node.name.text)
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        registerSymbol(named: "init")
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                registerSymbol(named: identifier)
            }
        }
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        registerSymbol(named: "subscript")
        return .skipChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        registerSymbol(named: node.name.text)
        return .skipChildren
    }

    private func pushContainer(named name: String) {
        guard !name.isEmpty else {
            return
        }

        symbolNames.insert(name)
        containerStack.append(name)
    }

    private func pushExtensionContainer(named rawName: String) {
        let normalizedName = rawName
            .components(separatedBy: " where ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? rawName

        guard !normalizedName.isEmpty else {
            return
        }

        containerStack.append(normalizedName)
    }

    private func popContainer() {
        guard !containerStack.isEmpty else {
            return
        }
        containerStack.removeLast()
    }

    private func registerSymbol(named name: String) {
        guard !name.isEmpty else {
            return
        }

        symbolNames.insert(name)

        if let container = containerStack.last {
            memberSymbolsByContainer[container, default: []].insert(name)
        }
    }
}
