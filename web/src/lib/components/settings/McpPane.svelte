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
    Braces,
    Check,
    ChevronDown,
    ChevronRight,
    Copy,
    KeyRound,
    Link,
    ListOrdered,
    Plug,
    Trash2,
  } from 'lucide-svelte';

  const m = $derived(workbench.t.mcp);

  const endpointUrl = $derived.by(() => {
    const origin = typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:8787';
    return buildMcpEndpointUrl(origin, workbench.mcpEndpointPath);
  });

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
  <!-- Section 1: Service Config (Minimalist rows mirroring GeneralPane) -->
  <div>
    <div class="mb-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground">
      {m.sectionStatus}
    </div>

    <div
      class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5"
    >
      <SettingRow icon={Plug} label={m.enableLabel} hint={m.enableDesc}>
        <div class="flex items-center gap-2.5">
          <span class="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
            <span
              class={`h-1.5 w-1.5 rounded-full ${
                workbench.mcpEnabled ? 'bg-primary' : 'bg-muted-foreground/45'
              }`}
            ></span>
            <span>{workbench.mcpEnabled ? m.statusRunning : m.statusStopped}</span>
            {#if workbench.mcpStats.totalCalls > 0}
              <span class="font-mono text-[11px] tabular-nums text-muted-foreground/75">
                · {workbench.mcpStats.totalCalls.toLocaleString()}
              </span>
              {#if workbench.mcpStats.errorCalls > 0}
                <span class="font-mono text-[11px] tabular-nums text-status">
                  ({workbench.mcpStats.errorCalls})
                </span>
              {/if}
            {/if}
          </span>
          <Switch
            checked={workbench.mcpEnabled}
            title={m.enableLabel}
            onchange={(v) => void workbench.setMcpEnabled(v)}
          />
        </div>
      </SettingRow>

      <div class="flex min-h-11 items-center gap-3 py-1.5">
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
            class="inline-flex shrink-0 items-center gap-1 rounded bg-secondary px-1.5 py-0.5 text-[11px] text-muted-foreground"
          >
            <KeyRound class="h-3 w-3" />
            <span class="hidden sm:inline">{m.tokenRequiredBadge}</span>
          </span>
        {/if}
        <div class="flex shrink-0 items-center gap-0.5">
          <button
            type="button"
            title={m.copyUrlTitle}
            aria-label={m.copyUrlTitle}
            onclick={() => void copyValue('url', endpointUrl)}
            class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
          >
            {#if copiedWhich === 'url'}
              <Check class="h-3.5 w-3.5 text-primary" />
            {:else}
              <Copy class="h-3.5 w-3.5" />
            {/if}
          </button>
          <button
            type="button"
            title={m.copyConfigTitle}
            aria-label={m.copyConfigTitle}
            onclick={() =>
              void copyValue('config', buildMcpClientConfigJson(endpointUrl, workbench.mcpTokenRequired))}
            class="touch-target flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground active:bg-secondary cursor-pointer"
          >
            {#if copiedWhich === 'config'}
              <Check class="h-3.5 w-3.5 text-primary" />
            {:else}
              <Braces class="h-3.5 w-3.5" />
            {/if}
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

  <!-- Section 2: Capabilities List (Compact single-line rows, expand on click) -->
  <div>
    <div class="mb-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground">
      {m.sectionCapabilities}
    </div>

    <div
      class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5"
    >
      {#each workbench.mcpCapabilities as cap (cap.name)}
        {@const localized = m.toolLabels[cap.name]}
        {@const isOpen = expandedTool === cap.name}
        <div>
          <button
            type="button"
            title={localized?.desc ?? cap.description}
            aria-expanded={isOpen}
            onclick={() => toggleTool(cap.name)}
            class="touch-target flex min-h-10 w-full items-center justify-between gap-2 py-1.5 text-left cursor-pointer group"
          >
            <div class="flex min-w-0 items-center gap-2">
              <span class="shrink-0 text-muted-foreground/60 group-hover:text-foreground">
                {#if isOpen}
                  <ChevronDown class="h-3 w-3" />
                {:else}
                  <ChevronRight class="h-3 w-3" />
                {/if}
              </span>
              <code class="truncate font-mono text-[12.5px] font-medium text-foreground/95">
                {cap.name}
              </code>
            </div>
            {#if localized?.title}
              <span class="shrink-0 text-xs text-muted-foreground">{localized.title}</span>
            {/if}
          </button>

          {#if isOpen}
            <div class="space-y-1.5 pb-2.5 pl-5 select-text">
              <p class="text-[11.5px] leading-relaxed text-muted-foreground">
                {localized?.desc ?? cap.description}
              </p>
              {#if cap.params.length > 0}
                <div class="flex flex-wrap gap-x-2 gap-y-1 font-mono text-[11px] text-muted-foreground/85">
                  {#each cap.params as param (param.name)}
                    <span
                      title={`${param.name}: ${param.type}${param.required ? ` (${m.requiredParamTitle})` : ''} — ${param.description}`}
                      class={param.required ? 'text-foreground/90 font-medium' : ''}
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
      <span class="text-[11.5px] font-medium text-muted-foreground">
        {m.sectionLogs}
      </span>

      <div class="flex items-center gap-1">
        <span class="font-mono text-[11px] tabular-nums text-muted-foreground/80">
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
        <div class="py-7 text-center text-xs text-muted-foreground">
          {m.emptyLogsTitle}
        </div>
      {:else}
        <div class="max-h-[320px] overflow-y-auto divide-y divide-border/40 px-3.5">
          {#each workbench.mcpLogs as entry (entry.seq)}
            {@const isExpanded = expandedSeq === entry.seq}
            <div class="py-2">
              <button
                type="button"
                aria-expanded={isExpanded}
                onclick={() => toggleLog(entry.seq)}
                class="flex w-full items-center gap-2 text-left cursor-pointer group"
              >
                <span
                  class={`h-1.5 w-1.5 shrink-0 rounded-full ${
                    entry.ok ? 'bg-primary' : 'bg-status'
                  }`}
                ></span>

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
                  {formatMs(entry.durationMs)}ms · {formatMcpTimestamp(entry.timestampMs)}
                </span>
              </button>

              {#if isExpanded}
                <div class="mt-1.5 ml-3.5 space-y-1 border-l border-border/50 pl-2.5 font-mono text-[11px] text-muted-foreground select-text">
                  <div class="flex items-center justify-between gap-2">
                    <span>#{entry.seq} · {entry.method}</span>
                    {#if entry.clientInfo}
                      <span class="truncate max-w-[180px]" title={entry.clientInfo}>
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
