<script lang="ts">
  import { onDestroy } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    MAX_MCP_MAX_LOGS,
    MIN_MCP_MAX_LOGS,
    buildMcpClientConfigJson,
    buildMcpEndpointUrl,
    formatMcpTimestamp,
  } from '$lib/mcp';
  import { copyTextToClipboard, formatMs } from '$lib/utils';
  import NumberStepper from '../ui/NumberStepper.svelte';
  import SettingRow from '../ui/SettingRow.svelte';
  import Switch from '../ui/Switch.svelte';
  import {
    Activity,
    AlertTriangle,
    Braces,
    Check,
    ChevronDown,
    ChevronRight,
    Copy,
    Database,
    FileText,
    KeyRound,
    Link,
    ListOrdered,
    Plug,
    Power,
    ScrollText,
    Search,
    Trash2,
    Wrench,
  } from 'lucide-svelte';

  const m = $derived(workbench.t.mcp);

  const endpointUrl = $derived.by(() => {
    const origin = typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:8787';
    return buildMcpEndpointUrl(origin, workbench.mcpEndpointPath);
  });

  const statusSummaryTitle = $derived.by(() => {
    const stateLabel = workbench.mcpEnabled ? m.statusRunning : m.statusStopped;
    const total = workbench.mcpStats.totalCalls;
    const errors = workbench.mcpStats.errorCalls;
    if (total <= 0) return stateLabel;
    return errors > 0
      ? `${stateLabel} · ${total.toLocaleString()} (${errors} ${m.fieldError})`
      : `${stateLabel} · ${total.toLocaleString()}`;
  });

  function getToolIcon(name: string): typeof Wrench {
    switch (name) {
      case 'webgrep_search':
        return Search;
      case 'webgrep_get_context':
        return FileText;
      case 'webgrep_list_sources':
        return Database;
      case 'webgrep_status':
        return Activity;
      default:
        return Wrench;
    }
  }

  let copiedWhich = $state<'url' | 'config' | null>(null);
  let copyTimer: ReturnType<typeof setTimeout> | null = null;
  let expandedTool = $state<string | null>(null);
  let expandedSeq = $state<number | null>(null);

  onDestroy(() => {
    if (copyTimer !== null) clearTimeout(copyTimer);
  });

  async function copyValue(which: 'url' | 'config', text: string) {
    const ok = await copyTextToClipboard(text);
    if (!ok) return;
    copiedWhich = which;
    if (copyTimer !== null) clearTimeout(copyTimer);
    copyTimer = setTimeout(() => {
      copiedWhich = null;
      copyTimer = null;
    }, 1500);
  }

  function toggleTool(name: string) {
    expandedTool = expandedTool === name ? null : name;
  }

  function toggleLog(seq: number) {
    expandedSeq = expandedSeq === seq ? null : seq;
  }
</script>

<div class="space-y-4">
  {#if workbench.mcpError}
    <div
      role="alert"
      class="flex items-center gap-2 rounded-lg bg-status/10 px-3 py-2 text-xs text-status"
    >
      <AlertTriangle class="h-3.5 w-3.5 shrink-0" />
      <span class="min-w-0 flex-1 break-words">{workbench.mcpError}</span>
    </div>
  {/if}

  <!-- Section 1: Service -->
  <div>
    <div
      class="mb-1.5 flex items-center gap-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground"
      title={m.enableDesc}
    >
      <Plug class="h-3.5 w-3.5 text-muted-foreground/75" />
      <span>{m.sectionStatus}</span>
    </div>

    <div
      class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5"
    >
      <SettingRow icon={Power} label={m.enableLabel} hint={m.enableDesc}>
        <div class="flex items-center gap-2.5">
          <span
            title={statusSummaryTitle}
            aria-label={statusSummaryTitle}
            class="inline-flex items-center gap-1.5 font-mono text-[11px] tabular-nums text-muted-foreground"
          >
            <span
              class={`h-2 w-2 rounded-full ${
                workbench.mcpEnabled ? 'bg-primary' : 'bg-muted-foreground/45'
              }`}
            ></span>
            {#if workbench.mcpStats.totalCalls > 0}
              <span>{workbench.mcpStats.totalCalls.toLocaleString()}</span>
              {#if workbench.mcpStats.errorCalls > 0}
                <span class="text-status">/{workbench.mcpStats.errorCalls}</span>
              {/if}
            {/if}
          </span>
          <Switch
            checked={workbench.mcpEnabled}
            title={workbench.mcpEnabled ? m.statusRunning : m.statusStopped}
            onchange={(v) => void workbench.setMcpEnabled(v)}
          />
        </div>
      </SettingRow>

      <div class="flex min-h-11 items-center gap-2 py-1.5">
        <Link class="h-4 w-4 shrink-0 text-muted-foreground/80" />
        <code
          class="min-w-0 flex-1 truncate font-mono text-[12px] text-foreground/90 select-all"
          title={endpointUrl}
        >
          {endpointUrl}
        </code>
        {#if workbench.mcpTokenRequired}
          <span
            title={m.tokenRequiredHint}
            aria-label={m.tokenRequiredHint}
            class="inline-flex h-5 shrink-0 items-center gap-1 rounded bg-status/12 px-1.5 font-mono text-[10.5px] font-medium text-status ring-1 ring-inset ring-status/20"
          >
            <KeyRound class="h-3 w-3 shrink-0" />
            <span>{m.tokenRequiredBadge}</span>
          </span>
        {/if}
        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            title={m.copyUrlTitle}
            aria-label={m.copyUrlTitle}
            onclick={() => void copyValue('url', endpointUrl)}
            class="touch-target inline-flex h-7 items-center gap-1 rounded-md border border-border/55 bg-background/70 px-2 font-mono text-[11px] text-muted-foreground hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
          >
            {#if copiedWhich === 'url'}
              <Check class="h-3 w-3 text-primary" />
            {:else}
              <Copy class="h-3 w-3" />
            {/if}
            <span>URL</span>
          </button>
          <button
            type="button"
            title={m.copyConfigTitle}
            aria-label={m.copyConfigTitle}
            onclick={() =>
              void copyValue('config', buildMcpClientConfigJson(endpointUrl, workbench.mcpTokenRequired))}
            class="touch-target inline-flex h-7 items-center gap-1 rounded-md border border-border/55 bg-background/70 px-2 font-mono text-[11px] text-muted-foreground hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
          >
            {#if copiedWhich === 'config'}
              <Check class="h-3 w-3 text-primary" />
            {:else}
              <Braces class="h-3 w-3" />
            {/if}
            <span>JSON</span>
          </button>
        </div>
      </div>

      <SettingRow icon={ListOrdered} label={m.maxLogsLabel} hint={m.maxLogsDesc}>
        <NumberStepper
          value={workbench.mcpMaxLogs}
          min={MIN_MCP_MAX_LOGS}
          max={MAX_MCP_MAX_LOGS}
          step={5}
          widthClass="w-11"
          onchange={(v) => workbench.setMcpMaxLogs(v)}
        />
      </SettingRow>
    </div>
  </div>

  <!-- Section 2: Capabilities (Icon-led single-line rows, expand params on demand) -->
  <div>
    <div class="mb-1.5 flex items-center justify-between px-0.5">
      <span class="inline-flex items-center gap-1.5 text-[11.5px] font-medium text-muted-foreground">
        <Wrench class="h-3.5 w-3.5 text-muted-foreground/75" />
        <span>{m.sectionCapabilities}</span>
      </span>
      <span class="rounded-full bg-secondary/75 px-1.5 py-0.5 font-mono text-[10.5px] tabular-nums text-muted-foreground">
        {workbench.mcpCapabilities.length}
      </span>
    </div>

    <div
      class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5"
    >
      {#each workbench.mcpCapabilities as cap (cap.name)}
        {@const localized = m.toolLabels[cap.name]}
        {@const isOpen = expandedTool === cap.name}
        {@const ToolIcon = getToolIcon(cap.name)}
        <div>
          <button
            type="button"
            title={localized?.desc ?? cap.description}
            aria-expanded={isOpen}
            onclick={() => toggleTool(cap.name)}
            class="touch-target flex min-h-10 w-full items-center justify-between gap-2 py-1.5 text-left cursor-pointer group"
          >
            <div class="flex min-w-0 items-center gap-2">
              <ToolIcon class="h-3.5 w-3.5 shrink-0 text-muted-foreground/80 group-hover:text-foreground" />
              <code class="truncate font-mono text-[12px] font-medium text-foreground/95">
                {cap.name}
              </code>
            </div>
            <div class="flex shrink-0 items-center gap-1.5">
              {#if localized?.title}
                <span class="text-xs text-muted-foreground">{localized.title}</span>
              {/if}
              <span class="text-muted-foreground/55 group-hover:text-foreground">
                {#if isOpen}
                  <ChevronDown class="h-3.5 w-3.5" />
                {:else}
                  <ChevronRight class="h-3.5 w-3.5" />
                {/if}
              </span>
            </div>
          </button>

          {#if isOpen}
            <div class="space-y-1.5 pb-2.5 pl-[22px] select-text">
              <p class="text-[11.5px] leading-relaxed text-muted-foreground">
                {localized?.desc ?? cap.description}
              </p>
              {#if cap.params.length > 0}
                <div class="flex flex-wrap gap-1.5 font-mono text-[11px] text-muted-foreground/85">
                  {#each cap.params as param (param.name)}
                    <span
                      title={`${param.name}: ${param.type}${param.required ? ` (${m.requiredParamTitle})` : ''} — ${param.description}`}
                      class={`rounded bg-secondary/70 px-1.5 py-0.5 ${
                        param.required ? 'text-foreground/95 font-medium' : ''
                      }`}
                    >
                      {param.name}{param.required ? '*' : ''}
                    </span>
                  {/each}
                </div>
              {/if}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  </div>

  <!-- Section 3: Real-Time Call Logs -->
  <div>
    <div class="mb-1.5 flex items-center justify-between px-0.5">
      <span class="inline-flex items-center gap-1.5 text-[11.5px] font-medium text-muted-foreground">
        <ScrollText class="h-3.5 w-3.5 text-muted-foreground/75" />
        <span>{m.sectionLogs}</span>
      </span>

      <div class="flex items-center gap-1">
        <span class="rounded-full bg-secondary/75 px-1.5 py-0.5 font-mono text-[10.5px] tabular-nums text-muted-foreground">
          {workbench.mcpLogs.length}/{workbench.mcpMaxLogs}
        </span>
        <button
          type="button"
          disabled={workbench.mcpLogs.length === 0}
          title={m.clearLogsTitle}
          aria-label={m.clearLogsTitle}
          onclick={() => void workbench.clearMcpLogs()}
          class="touch-target flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary disabled:opacity-30 disabled:pointer-events-none cursor-pointer"
        >
          <Trash2 class="h-3.5 w-3.5" />
        </button>
      </div>
    </div>

    <div class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 overflow-hidden">
      {#if workbench.mcpLogs.length === 0}
        <div class="flex flex-col items-center justify-center gap-1.5 py-6 text-xs text-muted-foreground">
          <Activity class="h-4 w-4 text-muted-foreground/50" />
          <span>{m.emptyLogsTitle}</span>
        </div>
      {:else}
        <div class="divide-y divide-border/40 px-3.5">
          {#each workbench.mcpLogs as entry (entry.seq)}
            {@const isExpanded = expandedSeq === entry.seq}
            {@const LogIcon = getToolIcon(entry.toolName || entry.method)}
            <div class="py-2">
              <button
                type="button"
                aria-expanded={isExpanded}
                title={`${formatMcpTimestamp(entry.timestampMs)} · ${entry.toolName || entry.method} · ${formatMs(entry.durationMs)}`}
                onclick={() => toggleLog(entry.seq)}
                class="touch-target flex w-full items-center gap-2 text-left cursor-pointer group"
              >
                <span
                  class={`h-1.5 w-1.5 shrink-0 rounded-full ${
                    entry.ok ? 'bg-primary' : 'bg-status'
                  }`}
                ></span>

                <LogIcon class="h-3 w-3 shrink-0 text-muted-foreground/70" />

                <span class="min-w-0 flex-1 truncate font-mono text-[12px] text-foreground/95">
                  {entry.toolName || entry.method}
                  {#if entry.argsSummary || entry.resultSummary || entry.errorMessage}
                    <span class="ml-1.5 text-[11px] text-muted-foreground/80">
                      {!entry.ok && entry.errorMessage
                        ? entry.errorMessage
                        : entry.argsSummary || entry.resultSummary}
                    </span>
                  {/if}
                </span>

                <span class="shrink-0 font-mono text-[11px] tabular-nums text-muted-foreground/80">
                  {formatMs(entry.durationMs)}
                </span>
                <span class="shrink-0 text-muted-foreground/55 group-hover:text-foreground">
                  {#if isExpanded}
                    <ChevronDown class="h-3 w-3" />
                  {:else}
                    <ChevronRight class="h-3 w-3" />
                  {/if}
                </span>
              </button>

              {#if isExpanded}
                <div class="mt-1.5 ml-3.5 space-y-1 border-l border-border/50 pl-2.5 font-mono text-[11px] text-muted-foreground select-text">
                  <div class="flex items-center justify-between gap-2">
                    <span>#{entry.seq} · {formatMcpTimestamp(entry.timestampMs)} · {entry.method}</span>
                    {#if entry.clientInfo}
                      <span class="truncate max-w-[160px]" title={entry.clientInfo}>
                        {m.fieldClient}: {entry.clientInfo}
                      </span>
                    {/if}
                  </div>
                  {#if entry.argsSummary}
                    <div class="break-all text-foreground/85">
                      {m.fieldArgs}: {entry.argsSummary}
                    </div>
                  {/if}
                  {#if entry.resultSummary}
                    <div class="break-all text-foreground/85">
                      {m.fieldResult}: {entry.resultSummary}
                    </div>
                  {/if}
                  {#if entry.errorMessage}
                    <div class="break-all text-status">
                      {m.fieldError}: {entry.errorMessage}
                    </div>
                  {/if}
                </div>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  </div>
</div>
