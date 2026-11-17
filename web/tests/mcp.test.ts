import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_MCP_MAX_LOGS,
  MAX_MCP_MAX_LOGS,
  MIN_MCP_MAX_LOGS,
  buildMcpClientConfigJson,
  buildMcpEndpointUrl,
  clampMcpMaxLogs,
  formatMcpTimestamp,
} from '../src/lib/mcp.ts';

describe('mcp helpers', () => {
  it('defaults maxLogs to 20 and clamps within [1, 200]', () => {
    assert.equal(DEFAULT_MCP_MAX_LOGS, 20);
    assert.equal(clampMcpMaxLogs(undefined), 20);
    assert.equal(clampMcpMaxLogs('invalid'), 20);
    assert.equal(clampMcpMaxLogs(0), MIN_MCP_MAX_LOGS);
    assert.equal(clampMcpMaxLogs(-5), MIN_MCP_MAX_LOGS);
    assert.equal(clampMcpMaxLogs(999), MAX_MCP_MAX_LOGS);
    assert.equal(clampMcpMaxLogs(35.6), 36);
  });

  it('builds clean MCP HTTP URL and JSON client snippet with optional auth header', () => {
    const url = buildMcpEndpointUrl('http://127.0.0.1:8787/', 'mcp');
    assert.equal(url, 'http://127.0.0.1:8787/mcp');
    const parsedOpen = JSON.parse(buildMcpClientConfigJson(url));
    assert.equal(parsedOpen.mcpServers.webgrep.url, 'http://127.0.0.1:8787/mcp');
    assert.equal(parsedOpen.mcpServers.webgrep.headers, undefined);

    const parsedProtected = JSON.parse(buildMcpClientConfigJson(url, true));
    assert.equal(parsedProtected.mcpServers.webgrep.url, 'http://127.0.0.1:8787/mcp');
    assert.equal(
      parsedProtected.mcpServers.webgrep.headers.Authorization,
      'Bearer <YOUR_MCP_TOKEN>'
    );
  });

  it('formats timestamps as HH:mm:ss', () => {
    assert.equal(formatMcpTimestamp(0), '—');
    const formatted = formatMcpTimestamp(Date.UTC(2026, 10, 17, 12, 34, 56));
    assert.match(formatted, /^\d{2}:\d{2}:56$/);
  });
});
