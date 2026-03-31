import Foundation

public typealias JSONObject = [String: JSONValue]

// MARK: - JSON Value

public enum JSONValue: Codable, Sendable, Equatable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(JSONObject.self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value):
            return value
        case .double(let value) where value.rounded() == value:
            return Int(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value):
            return Double(value)
        case .double(let value):
            return value
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var objectValue: JSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func int(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func double(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func object(_ key: String) -> JSONObject? {
        self[key]?.objectValue
    }

    func array(_ key: String) -> [JSONValue]? {
        self[key]?.arrayValue
    }
}

// MARK: - MCP Protocol Types

public struct MCPRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: RequestID?
    public let method: String
    public let params: JSONObject?
}

public struct MCPResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: RequestID?
    public let result: JSONValue?
    public let error: MCPError?

    public init(jsonrpc: String = "2.0", id: RequestID?, result: JSONValue? = nil, error: MCPError? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum RequestID: Codable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let numberValue = try? container.decode(Int.self) {
            self = .number(numberValue)
        } else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or Int"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        }
    }
}

public enum MCPError: Error, Codable, Sendable, LocalizedError {
    case parseError
    case invalidRequest
    case methodNotFound(String)
    case invalidParams
    case internalError
    case toolNotFound(String)
    case resourceNotFound(String)

    enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)

        switch code {
        case -32700:
            self = .parseError
        case -32600:
            self = .invalidRequest
        case -32601:
            self = .methodNotFound(message)
        case -32602:
            self = .invalidParams
        case -32603:
            self = .internalError
        case -32001:
            self = .toolNotFound(message)
        case -32002:
            self = .resourceNotFound(message)
        default:
            self = .internalError
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
    }

    public var code: Int {
        switch self {
        case .parseError:
            return -32700
        case .invalidRequest:
            return -32600
        case .methodNotFound:
            return -32601
        case .invalidParams:
            return -32602
        case .internalError:
            return -32603
        case .toolNotFound:
            return -32001
        case .resourceNotFound:
            return -32002
        }
    }

    public var message: String {
        switch self {
        case .parseError:
            return "Parse error"
        case .invalidRequest:
            return "Invalid Request"
        case .methodNotFound(let method):
            return "Method not found: \(method)"
        case .invalidParams:
            return "Invalid params"
        case .internalError:
            return "Internal error"
        case .toolNotFound(let tool):
            return "Tool not found: \(tool)"
        case .resourceNotFound(let resource):
            return "Resource not found: \(resource)"
        }
    }

    public var errorDescription: String? {
        message
    }
}

// MARK: - Server Capabilities

public struct ServerCapabilities: Codable {
    public let tools: ToolsCapability?
    public let resources: ResourcesCapability?

    public init(tools: ToolsCapability? = nil, resources: ResourcesCapability? = nil) {
        self.tools = tools
        self.resources = resources
    }
}

public struct ToolsCapability: Codable {
    public let listChanged: Bool?

    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

public struct ResourcesCapability: Codable {
    public let subscribe: Bool?
    public let listChanged: Bool?

    public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }
}

// MARK: - Initialize Types

public struct InitializeResult: Codable {
    public let protocolVersion: String
    public let capabilities: ServerCapabilities
    public let serverInfo: ServerInfo

    public init(protocolVersion: String, capabilities: ServerCapabilities, serverInfo: ServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

public struct ServerInfo: Codable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

// MARK: - Tool Types

public struct Tool: Codable {
    public let name: String
    public let description: String
    public let inputSchema: JSONObject

    public init(name: String, description: String, inputSchema: JSONObject) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolsListResult: Codable {
    public let tools: [Tool]

    public init(tools: [Tool]) {
        self.tools = tools
    }
}

public struct ToolCallParams: Codable {
    public let name: String
    public let arguments: JSONObject
}

public struct ToolCallResult: Codable {
    public let content: [ToolContent]

    public init(content: [ToolContent]) {
        self.content = content
    }
}

public struct ToolContent: Codable {
    public let type: String
    public let text: String

    public init(type: String, text: String) {
        self.type = type
        self.text = text
    }
}

// MARK: - Resource Types

public struct Resource: Codable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct ResourcesListResult: Codable {
    public let resources: [Resource]

    public init(resources: [Resource]) {
        self.resources = resources
    }
}

public struct ResourceReadResult: Codable {
    public let contents: [ResourceContent]

    public init(contents: [ResourceContent]) {
        self.contents = contents
    }
}

public struct ResourceContent: Codable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: Data?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: Data? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}
