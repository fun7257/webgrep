//! Public facade for the native Model Context Protocol (MCP) JSON-RPC 2.0 service (`src/mcp/*`).

pub const types = @import("mcp/types.zig");
pub const rpc_helpers = @import("mcp/rpc_helpers.zig");
pub const tools = @import("mcp/tools.zig");
pub const service = @import("mcp/service.zig");
pub const stdio = @import("mcp/stdio.zig");

pub const DEFAULT_MAX_LOGS = types.DEFAULT_MAX_LOGS;
pub const MIN_MAX_LOGS = types.MIN_MAX_LOGS;
pub const MAX_MAX_LOGS = types.MAX_MAX_LOGS;
pub const PROTOCOL_VERSION = types.PROTOCOL_VERSION;
pub const SERVER_NAME = types.SERVER_NAME;
pub const SERVER_VERSION = types.SERVER_VERSION;
pub const ENDPOINT_PATH = types.ENDPOINT_PATH;

pub const clampMaxLogs = types.clampMaxLogs;
pub const ParamMeta = types.ParamMeta;
pub const CapabilityMeta = types.CapabilityMeta;
pub const CAPABILITIES = types.CAPABILITIES;
pub const McpStatsDto = types.McpStatsDto;
pub const McpCallLogDto = types.McpCallLogDto;
pub const McpStateDto = types.McpStateDto;
pub const UpdateMcpConfigRequest = types.UpdateMcpConfigRequest;
pub const WsSubscriber = types.WsSubscriber;
pub const McpService = service.McpService;
pub const runStdioBridge = stdio.runStdioBridge;

test {
    _ = @import("mcp/tests.zig");
}
