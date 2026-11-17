export const DEFAULT_MCP_MAX_LOGS = 20;
export const MIN_MCP_MAX_LOGS = 1;
export const MAX_MCP_MAX_LOGS = 200;

export function clampMcpMaxLogs(value: unknown, fallback = DEFAULT_MCP_MAX_LOGS): number {
  const num = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(num)) return fallback;
  return Math.max(MIN_MCP_MAX_LOGS, Math.min(MAX_MCP_MAX_LOGS, Math.round(num)));
}

export function buildMcpEndpointUrl(origin: string, endpointPath = '/mcp'): string {
  const cleanOrigin = origin.trim().replace(/\/+$/, '');
  const cleanPath = endpointPath.startsWith('/') ? endpointPath : `/${endpointPath}`;
  return cleanOrigin ? `${cleanOrigin}${cleanPath}` : cleanPath;
}

export function buildMcpClientConfigJson(endpointUrl: string, tokenRequired = false): string {
  const serverConfig: Record<string, unknown> = {
    url: endpointUrl,
  };
  if (tokenRequired) {
    serverConfig.headers = {
      Authorization: 'Bearer <YOUR_MCP_TOKEN>',
    };
  }
  return JSON.stringify(
    {
      mcpServers: {
        webgrep: serverConfig,
      },
    },
    null,
    2
  );
}

export function formatMcpTimestamp(timestampMs: number): string {
  if (!Number.isFinite(timestampMs) || timestampMs <= 0) return '—';
  const d = new Date(timestampMs);
  if (Number.isNaN(d.getTime())) return '—';
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  return `${hh}:${mm}:${ss}`;
}
