# Swift MCP Server

Swift MCP Server is a Model Context Protocol server for Swift workspaces. It exposes navigation, diagnostics, formatting, and project-analysis tools over `stdio` or HTTP.

The project is intentionally split into two analysis layers:
- `SourceKit-LSP` for editor-grade operations such as references, definitions, hover, formatting, and diagnostics.
- `SwiftSyntax` plus `Package.swift` AST parsing for project structure, symbol indexing, and conservative architecture analysis.
- `AppleSDKCatalog` for local Xcode SDK module discovery and official Apple documentation references used by iOS framework analysis.

## Status

What works today:
- MCP `initialize`, `tools/list`, `tools/call`, `resources/list`, and `resources/read`
- `SourceKit-LSP`-backed `find_references`, `get_definition`, `get_hover_info`, `format_document`, and `get_diagnostics`
- Syntax-aware `find_symbols`, `analyze_project`, `detect_architecture`, `analyze_symbol_usage`, and `analyze_pop_usage`
- Local Xcode SDK cataloging for Apple framework/module discovery across imported Apple modules, with richer enrichments for `FoundationModels` and `ImagePlayground`
- STDIO transport for editor integrations and HTTP transport for local API usage

What this project does not claim:
- It is not a whole-program compiler analysis framework
- It does not guarantee that every project can be classified into a named architecture
- It does not infer patterns like VIPER or TCA from file names anymore

If semantic evidence is weak, `detect_architecture` returns `Custom` rather than guessing.

## Requirements

- Swift 5.9+
- macOS with Xcode toolchain recommended
- `sourcekit-lsp` available through Xcode or on `PATH` for navigation, diagnostics, and formatting

The project still builds as a Swift package without SourceKit-LSP, but editor-grade tools will be limited.

## Quick Start

Build:

```bash
swift build --configuration release
```

Run in STDIO mode against the current workspace:

```bash
./.build/release/swift-mcp-server --transport stdio --workspace .
```

Run in HTTP mode:

```bash
./.build/release/swift-mcp-server --transport http --workspace . --port 8080
```

You can also use the helper script:

```bash
./swift-mcp.sh build
./swift-mcp.sh health
./swift-mcp.sh stdio
```

## AI / Editor Integration

The server is already usable by AI clients that support MCP over `stdio`. A local handshake with `initialize` and `tools/list` succeeds against the built binary.

For MCP clients that speak over `stdio`, point them at the built binary:

```json
{
  "mcp": {
    "servers": {
      "swift-mcp-server": {
        "command": "/path/to/swift-mcp-server/.build/release/swift-mcp-server",
        "args": ["--transport", "stdio", "--workspace", "/path/to/project"]
      }
    }
  }
}
```

There is also a checked-in example at [`vscode-mcp-config.json`](vscode-mcp-config.json).

This covers MCP-capable AI/editor clients in general, not just VS Code:
- Claude Desktop / Claude Code style MCP setups
- Cursor / VS Code style MCP setups
- any local AI client that can spawn an MCP server over `stdio`

## Tools

SourceKit-LSP-backed tools:
- `find_references`
- `get_definition`
- `get_hover_info`
- `format_document`
- `get_diagnostics`

Syntax/package-analysis tools:
- `find_symbols`
- `analyze_project`
- `detect_architecture`
- `analyze_symbol_usage`
- `create_project_memory`
- `generate_migration_plan`
- `analyze_pop_usage`
- `generate_documentation`
- `analyze_ios_frameworks`
- `generate_template`

`analyze_ios_frameworks` now reports:
- imported Apple modules resolved from the local Xcode SDK catalog
- semantic symbol hits per imported Apple module
- official documentation links for imported Apple modules
- richer feature-level analysis for `FoundationModels` and `ImagePlayground`

State/cache helpers:
- `intelligent_project_memory`

## How Analysis Works

`find_symbols`, `analyze_project`, and `detect_architecture` no longer scan raw text with regexes. They now build a parsed project snapshot from:
- Swift declarations and references extracted with `SwiftSyntax`
- import graphs and type relationships extracted from parsed AST nodes
- target and dependency information extracted from `Package.swift` syntax

That means the project analyzer can reason about:
- concrete type declarations
- protocol conformances and inherited types
- observable/view relationships for MVVM-style detection
- test targets and package dependencies
- package modularity without shelling out to SwiftPM during analysis

It also means some results are intentionally conservative:
- `find_symbols` is syntax-aware, but not a cross-module compiler index
- `detect_architecture` only reports patterns when code structure supports them
- `analyze_project` reports structural metrics, not line-coverage or formal complexity proofs

## Architecture Detection

Current architecture detection is evidence-driven:
- `MVVM` when views depend on observable state types
- `MVC` when controllers depend directly on model/domain types without an observable layer
- `Clean Architecture` when presentation depends on protocol abstractions and data adapters implement those abstractions across module boundaries
- `Features-based` when executable targets depend on multiple internal feature targets
- `Modular` when the package is clearly split into multiple internal targets
- `Custom` when the workspace does not expose enough evidence for a stronger label

This keeps false positives lower than the old folder-name and file-name matching approach.

## Development

Run tests:

```bash
swift test
```

Current test coverage includes:
- JSON-RPC/MCP request and response shape
- SourceKit-LSP formatting, diagnostics, hover, definitions, and references
- MVVM detection from semantic evidence
- `Package.swift` parsing for target and dependency analysis

## Project Layout

```text
Sources/
├── SwiftMCPServer/      CLI entrypoint and transport bootstrapping
├── SwiftMCPCore/        MCP protocol, SourceKit-LSP client, syntax analysis
└── ModernConcurrency/   concurrency helpers

Tests/
└── SwiftMCPServerTests/ integration and protocol tests
```

## Notes

- Logs are written to `stderr` so STDIO MCP output stays clean
- The workspace path can be passed either as `--workspace <path>` or as the positional argument accepted by the CLI
- `analyze_project` defaults to the current workspace when no `project_path` is provided

## Related Docs

- [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md)
- [`SERENA_INTEGRATION.md`](SERENA_INTEGRATION.md)
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
