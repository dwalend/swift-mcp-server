# Swift MCP Server

A [Model Context Protocol](https://modelcontextprotocol.io) server that gives AI agents and editors semantic access to Swift code. It exposes SourceKit-LSP — Apple's official language server — over `stdio` or HTTP, so a client can navigate, inspect, format, and diagnose Swift without reimplementing a compiler front end.

The server is deliberately small: it wraps the operations that require a real language server and nothing else. Anything an LLM can already do well from source text (summaries, docs, refactors, templates) is intentionally left to the client.

## Tools

Every tool is backed by SourceKit-LSP and works on a single file addressed by path. Line and character positions are **0-based**.

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `find_symbols` | List symbols declared in a file, filtered by name | `file_path`, `name_pattern` |
| `find_references` | Find all references to the symbol at a position | `file_path`, `line`, `character` |
| `get_definition` | Resolve the definition of the symbol at a position | `file_path`, `line`, `character` |
| `get_hover_info` | Type and documentation for the symbol at a position | `file_path`, `line`, `character` |
| `format_document` | Format a file and return the resulting edits | `file_path` |
| `get_diagnostics` | Compiler errors and warnings for a file | `file_path` |
| `search_workspace_symbols` | Search symbols by name across the whole workspace | `query` |
| `rename_symbol` | Rename a symbol across the workspace and write the edits to disk | `file_path`, `line`, `character`, `new_name` |
| `call_hierarchy` | Find callers (`incoming`) or callees (`outgoing`) of a function | `file_path`, `line`, `character`, `direction` |
| `type_hierarchy` | Find `supertypes` or `subtypes`/conformers of a type | `file_path`, `line`, `character`, `direction` |
| `get_implementations` | Find concrete implementations of a protocol requirement or method | `file_path`, `line`, `character` |
| `code_actions` | List compiler fix-its and refactorings on a line, or `apply` one by title | `file_path`, `line`, `apply` |

The server also implements `initialize`, `tools/list`, `tools/call`, `resources/list`, and `resources/read`, and exposes a `swift://workspace` resource describing the active workspace.

`search_workspace_symbols`, `rename_symbol`, `call_hierarchy`, `type_hierarchy`, and `get_implementations` rely on SourceKit-LSP's global index. Right after the server starts, the index may still be building; these tools wait a bounded amount of time for it to become ready before returning. `rename_symbol` and `code_actions` (when applying) modify files on disk.

## Requirements

- Swift 5.9+
- macOS with the Xcode toolchain (recommended)
- `sourcekit-lsp` available through Xcode or on `PATH`

Navigation, hover, formatting, and diagnostics all depend on SourceKit-LSP. Without it the binary still runs but these tools cannot resolve symbols.

## Build

```bash
swift build --configuration release
```

The binary is produced at `.build/release/swift-mcp-server`.

## Running

STDIO transport (for editors and AI clients):

```bash
.build/release/swift-mcp-server --transport stdio --workspace /path/to/project
```

HTTP transport (for local API use and testing):

```bash
.build/release/swift-mcp-server --transport http --workspace /path/to/project --port 8080
```

The workspace can be passed with `--workspace <path>` or as a positional argument. A helper script is also available:

```bash
./swift-mcp.sh build
./swift-mcp.sh health
./swift-mcp.sh stdio
```

## Editor / AI client integration

Point any MCP client that speaks `stdio` at the built binary:

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

This works with any local MCP client, including Claude Code / Claude Desktop and Cursor / VS Code style setups. A checked-in example lives in [`vscode-mcp-config.json`](vscode-mcp-config.json).

## How it works

The server keeps a single SourceKit-LSP session bound to the workspace and translates each MCP tool call into the matching LSP request:

- `find_symbols` → `textDocument/documentSymbol`, filtered by name
- `find_references` → `textDocument/references`
- `get_definition` → `textDocument/definition`
- `get_hover_info` → `textDocument/hover`
- `format_document` → `textDocument/formatting`
- `get_diagnostics` → `textDocument/publishDiagnostics`
- `search_workspace_symbols` → `workspace/symbol`
- `rename_symbol` → `textDocument/rename` (edits applied to disk)
- `call_hierarchy` → `textDocument/prepareCallHierarchy` + `callHierarchy/incomingCalls` / `outgoingCalls`
- `type_hierarchy` → `textDocument/prepareTypeHierarchy` + `typeHierarchy/supertypes` / `subtypes`
- `get_implementations` → `textDocument/implementation`
- `code_actions` → `textDocument/codeAction` (applying an action writes its edits to disk)

Because results come from the compiler's own index, they reflect real Swift semantics rather than text heuristics.

## Development

Run the test suite:

```bash
swift test
```

Tests cover the JSON-RPC/MCP request and response shapes, the exposed tool surface, and the SourceKit-LSP-backed operations (symbols, definitions, references, hover, formatting, diagnostics). Tests that require SourceKit-LSP skip automatically when it is not installed.

## Project layout

```text
Sources/
├── SwiftMCPServer/      CLI entry point and transport bootstrapping
├── SwiftMCPCore/        MCP protocol handling and the SourceKit-LSP client
└── ModernConcurrency/   concurrency helpers

Tests/
└── SwiftMCPServerTests/ protocol and SourceKit-LSP integration tests
```

## Notes

- Logs go to `stderr` so STDIO MCP output stays clean.
- HTTP mode supports automatic port selection via `--port-min` / `--port-max`.

## License

See [LICENSE](LICENSE).
