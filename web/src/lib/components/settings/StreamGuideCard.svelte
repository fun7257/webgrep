<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import Segmented from '../ui/Segmented.svelte';
  import { Check, Copy, Loader2, Search, Send } from 'lucide-svelte';

  interface Props {
    serviceName: string;
    showActions?: boolean;
  }

  let { serviceName, showActions = false }: Props = $props();

  type ProtoTab = 'http' | 'tcp' | 'es' | 'loki' | 'otel';
  let proto = $state<ProtoTab>('http');
  let copied = $state(false);
  let sending = $state(false);
  let sentOk = $state(false);

  const t = $derived(workbench.t.ui);

  const cleanService = $derived(
    serviceName
      .trim()
      .replace(/^@+/, '')
      .replace(/[^a-zA-Z0-9._-]/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 64) || 'app-logs'
  );

  const httpOrigin = $derived(
    typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:8787'
  );
  const hostOnly = $derived(
    typeof window !== 'undefined' ? window.location.hostname || '127.0.0.1' : '127.0.0.1'
  );

  const snippet = $derived.by(() => {
    switch (proto) {
      case 'http':
        return `curl -X POST "${httpOrigin}/ingest/${cleanService}" \\\n  -d '{"level":"error","service":"${cleanService}","msg":"request timeout"}'`;
      case 'tcp':
        return `echo '{"service":"${cleanService}","level":"error","msg":"udp/tcp log"}' | nc -u -w1 ${hostOnly} 5514`;
      case 'es':
        return `# Vector / Filebeat / Fluent Bit (_bulk)\nendpoint: "${httpOrigin}"\nindex: "${cleanService}"`;
      case 'loki':
        return `# Promtail / Grafana Alloy\nurl: "${httpOrigin}/loki/api/v1/push"\nlabels: { service: "${cleanService}" }`;
      case 'otel':
        return `# OpenTelemetry OTLP/HTTP JSON\nendpoint: "${httpOrigin}/v1/logs"\nresource.attributes: service.name="${cleanService}"`;
    }
  });

  function copySnippet() {
    navigator.clipboard?.writeText(snippet);
    copied = true;
    setTimeout(() => (copied = false), 1500);
  }

  async function sendTest() {
    if (sending) return;
    sending = true;
    try {
      await workbench.ingestTestLog(cleanService);
      sentOk = true;
      setTimeout(() => (sentOk = false), 1800);
    } finally {
      sending = false;
    }
  }

  function searchThisStream() {
    workbench.pattern = `@${cleanService} $t(15m)`;
    workbench.settingsOpen = false;
    workbench.sourceAddOpen = false;
    workbench.executeSearch(false);
  }
</script>

<div class="space-y-2 rounded-xl border border-border/60 bg-background/60 p-2.5">
  <div class="flex items-center justify-between gap-2">
    <Segmented
      value={proto}
      options={[
        { value: 'http', label: 'HTTP', title: 'HTTP POST /ingest/{service}' },
        { value: 'tcp', label: 'TCP/UDP', title: 'Syslog / JSON / Raw (:5514)' },
        { value: 'es', label: 'ES', title: 'Elasticsearch / Vector / Filebeat _bulk' },
        { value: 'loki', label: 'Loki', title: 'Grafana Loki / Promtail /loki/api/v1/push' },
        { value: 'otel', label: 'OTel', title: 'OpenTelemetry /v1/logs' },
      ]}
      onchange={(v) => (proto = v)}
    />

    <div class="flex items-center gap-1 shrink-0">
      {#if showActions}
        <button
          type="button"
          onclick={sendTest}
          disabled={sending}
          title={t.streamSendTest}
          class="touch-target flex h-7 items-center gap-1 rounded-lg bg-secondary/80 px-2 text-[11.5px] font-medium text-foreground hover:bg-secondary transition-colors cursor-pointer"
        >
          {#if sending}
            <Loader2 class="h-3 w-3 animate-spin" />
          {:else if sentOk}
            <Check class="h-3 w-3 text-primary" />
          {:else}
            <Send class="h-3 w-3" />
          {/if}
          <span>{sentOk ? t.streamTestSent : t.streamSendTest}</span>
        </button>

        <button
          type="button"
          onclick={searchThisStream}
          title={t.streamSearchNow}
          aria-label={t.streamSearchNow}
          class="touch-target flex h-7 w-7 items-center justify-center rounded-lg text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
        >
          <Search class="h-3.5 w-3.5" />
        </button>
      {/if}

      <button
        type="button"
        onclick={copySnippet}
        title={t.copy}
        aria-label={t.copy}
        class="touch-target flex h-7 w-7 items-center justify-center rounded-lg text-muted-foreground hover:bg-secondary hover:text-foreground transition-colors cursor-pointer"
      >
        {#if copied}
          <Check class="h-3.5 w-3.5 text-primary" />
        {:else}
          <Copy class="h-3.5 w-3.5" />
        {/if}
      </button>
    </div>
  </div>

  <pre
    class="overflow-x-auto rounded-lg bg-secondary/40 px-2.5 py-2 font-mono text-[11px] leading-relaxed text-foreground/90 select-all"
  >{snippet}</pre>
</div>
