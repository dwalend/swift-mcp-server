# Configuration Files Guide

## Available Configurations

### 1. MCP STDIO Configuration for AI Clients (`vscode-mcp-config.json`)
Complete MCP `stdio` integration example for AI/editor clients.
- **Purpose**: Direct integration with VS Code, Cursor, Claude-style MCP clients, and similar tools
- **Transport**: STDIO (required for VS Code)
- **Features**: Complete troubleshooting documentation, debugging steps, configuration variations

### 2. STDIO Configuration (`stdio-config.json`)
Basic STDIO transport configuration for direct integrations.
- **Purpose**: Serena MCP integration, direct STDIO communication
- **Transport**: STDIO with HTTP fallback
- **Port Range**: 8080-8090
- **Features**: Basic Swift language support, experimental features

### 3. HTTP Configuration (`http-config.json`)
Enterprise HTTP transport configuration for web integrations.
- **Purpose**: REST API access, web service integration
- **Transport**: HTTP only
- **Port Range**: 9000-9010
- **Features**: Enhanced capabilities, performance tuning, enterprise features

## Usage Examples

### MCP Client Integration
```bash
# Reuse the example JSON in your MCP-capable AI/editor client config
cp vscode-mcp-config.json ~/mcp-client-settings-template.json
```

### Serena Integration
```bash
swift-mcp-server --config stdio-config.json --transport stdio
```

### Generic AI Client Integration
```bash
swift-mcp-server --transport stdio --workspace /path/to/project
```
Use this command in any local AI client that can spawn MCP servers over `stdio`.

### HTTP API Server
```bash
swift-mcp-server --config http-config.json --transport http --port 9000
```

## Quick Setup

For immediate setup, use the supported management script:
```bash
./swift-mcp.sh       # Build and bootstrap the local setup
./swift-mcp.sh health
./swift-mcp.sh vscode
```
