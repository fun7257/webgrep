import type { McpStateResponse, WsIncomingMessage, WsSearchMessage } from '../types.ts';

export const WS_DEGRADED_GRACE_MS = 650;

export type WsConnectionStatus = 'connecting' | 'connected' | 'reconnecting' | 'offline';

export interface SearchWsTransportCallbacks {
  canConnect: () => boolean;
  shouldReconnect: () => boolean;
  shouldVerifySessionOnDisconnect: () => boolean;
  getCurrentSearchId: () => number;
  onStatusChange: (status: WsConnectionStatus) => void;
  onDegradedChange: (degraded: boolean) => void;
  onOpen: (isReconnect: boolean) => void;
  onMcpStatePush: (state: McpStateResponse) => void;
  onSearchMessage: (msg: WsIncomingMessage) => void;
  onVerifySessionOnDisconnect: () => void;
  onDisconnectSearchReset: () => void;
  createSocket?: (url: string) => WebSocket;
  resolveUrl?: () => string | null;
}

const WS_CONNECTING = typeof WebSocket !== 'undefined' ? WebSocket.CONNECTING : 0;
const WS_OPEN = typeof WebSocket !== 'undefined' ? WebSocket.OPEN : 1;

/**
 * Manages the search & push WebSocket connection, 650ms degraded grace timer,
 * exponential backoff reconnection, and zero-overhead packet fast filtering.
 */
export class SearchWsTransport {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private wsDegradedTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempt = 0;
  private isUnloading = false;
  private status: WsConnectionStatus = 'connecting';
  private degraded = false;
  private readonly callbacks: SearchWsTransportCallbacks;

  constructor(callbacks: SearchWsTransportCallbacks) {
    this.callbacks = callbacks;
  }

  private setStatus(next: WsConnectionStatus): void {
    this.status = next;
    this.callbacks.onStatusChange(next);
  }

  private setDegraded(next: boolean): void {
    this.degraded = next;
    this.callbacks.onDegradedChange(next);
  }

  private clearDegradedTimer(): void {
    if (this.wsDegradedTimer !== null) {
      clearTimeout(this.wsDegradedTimer);
      this.wsDegradedTimer = null;
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private scheduleDegraded(): void {
    if (this.isUnloading || this.degraded || this.wsDegradedTimer !== null) return;
    this.wsDegradedTimer = setTimeout(() => {
      this.wsDegradedTimer = null;
      if (!this.isUnloading && this.status !== 'connected') {
        this.setDegraded(true);
      }
    }, WS_DEGRADED_GRACE_MS);
  }

  private scheduleReconnect(): void {
    if (!this.callbacks.shouldReconnect()) return;
    this.clearReconnectTimer();
    this.reconnectAttempt += 1;
    const delay = Math.min(2500, 300 * Math.pow(1.4, Math.min(6, this.reconnectAttempt)));
    this.reconnectTimer = setTimeout(() => {
      this.connect();
    }, delay);
  }

  private getWsUrl(): string | null {
    if (this.callbacks.resolveUrl) {
      return this.callbacks.resolveUrl();
    }
    if (typeof window === 'undefined') return null;
    const protocol = window.location.protocol === 'https:' ? 'wss://' : 'ws://';
    return `${protocol}${window.location.host}/api/ws`;
  }

  isOpen(): boolean {
    return Boolean(this.ws && this.ws.readyState === WS_OPEN);
  }

  /** Parses incoming WS text packets using fast prefix & 48-byte search ID filtering. */
  handleRawMessage(raw: string): void {
    if (!raw) return;
    try {
      if (raw.startsWith('{"type":"mcp_state"')) {
        const push = JSON.parse(raw) as { type: string; state?: McpStateResponse };
        if (push.type === 'mcp_state' && push.state) {
          this.callbacks.onMcpStatePush(push.state);
        }
        return;
      }
      const idMatch = /"id":(\d+)/.exec(raw.slice(0, 48));
      if (idMatch && Number(idMatch[1]) !== this.callbacks.getCurrentSearchId()) {
        return;
      }
      const msg = JSON.parse(raw) as WsIncomingMessage;
      this.callbacks.onSearchMessage(msg);
    } catch {
      // ignore malformed packet
    }
  }

  connect(): void {
    const wsUrl = this.getWsUrl();
    if (!wsUrl) return;
    if (!this.callbacks.canConnect()) return;
    if (this.ws && (this.ws.readyState === WS_OPEN || this.ws.readyState === WS_CONNECTING)) {
      return;
    }

    this.isUnloading = false;
    const isReconnect = this.reconnectAttempt > 0;
    this.setStatus(isReconnect ? 'reconnecting' : 'connecting');
    this.scheduleDegraded();

    try {
      const socket = this.callbacks.createSocket
        ? this.callbacks.createSocket(wsUrl)
        : new WebSocket(wsUrl);
      this.ws = socket;

      socket.onopen = () => {
        this.clearDegradedTimer();
        this.setDegraded(false);
        this.setStatus('connected');
        this.reconnectAttempt = 0;
        this.callbacks.onOpen(isReconnect);
      };

      socket.onmessage = (event: MessageEvent) => {
        const raw = typeof event.data === 'string' ? event.data : '';
        this.handleRawMessage(raw);
      };

      socket.onerror = () => {
        // handled by onclose
      };

      socket.onclose = () => {
        if (this.ws === socket) {
          this.ws = null;
        }
        this.callbacks.onDisconnectSearchReset();
        if (this.isUnloading) return;
        if (!this.callbacks.shouldReconnect()) return;
        if (this.callbacks.shouldVerifySessionOnDisconnect()) {
          this.callbacks.onVerifySessionOnDisconnect();
        }
        this.setStatus('reconnecting');
        this.scheduleDegraded();
        this.scheduleReconnect();
      };
    } catch {
      if (!this.isUnloading) {
        this.setStatus('offline');
        this.setDegraded(true);
        this.scheduleReconnect();
      }
    }
  }

  sendSearch(payload: WsSearchMessage): boolean {
    if (!this.ws || this.ws.readyState !== WS_OPEN) return false;
    this.ws.send(JSON.stringify(payload));
    return true;
  }

  sendCancel(searchId: number): boolean {
    if (!this.ws || this.ws.readyState !== WS_OPEN) return false;
    this.ws.send(JSON.stringify({ type: 'cancel', id: searchId }));
    return true;
  }

  closeForLock(): void {
    this.clearDegradedTimer();
    this.setDegraded(false);
    this.clearReconnectTimer();
    const sock = this.ws;
    this.ws = null;
    if (sock) {
      try {
        sock.onclose = null;
        sock.close();
      } catch {
        // ignore close failure
      }
    }
  }

  handleBeforeUnload(): void {
    this.isUnloading = true;
    this.clearDegradedTimer();
    this.clearReconnectTimer();
  }

  handlePageHide(persisted: boolean): void {
    if (!persisted) {
      this.isUnloading = true;
      this.clearDegradedTimer();
    }
  }

  handlePageShow(): void {
    this.isUnloading = false;
  }
}
