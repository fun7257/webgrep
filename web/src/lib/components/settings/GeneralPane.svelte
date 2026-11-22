<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import {
    MAX_CONTEXT_LINE_SETTING,
    MIN_CONTEXT_LINE_SETTING,
    clampContextLineSetting,
    normalizeContextAutoLoadPace,
  } from '$lib/context-window';
  import NumberStepper from '../ui/NumberStepper.svelte';
  import Segmented from '../ui/Segmented.svelte';
  import SettingRow from '../ui/SettingRow.svelte';
  import Switch from '../ui/Switch.svelte';
  import {
    ALargeSmall,
    ChevronsUpDown,
    Cpu,
    FoldVertical,
    Gauge,
    Languages,
    ListOrdered,
    Moon,
    Palette,
    PanelRight,
    Rows3,
    Rows4,
    Sun,
    SunMoon,
    TextWrap,
    Timer,
    Turtle,
    UnfoldVertical,
    Zap,
  } from 'lucide-svelte';

  const s = $derived(workbench.t.settings);

  /** Display-only settings: persisted, no re-search. */
  function display(fn: () => void) {
    fn();
    workbench.saveSettings();
  }

  /** Search-affecting settings: persisted and re-run if there is an active search. */
  function search(fn: () => void) {
    fn();
    workbench.saveSettings();
    if (workbench.hasSearchedOnce && workbench.hasExecutableQuery) {
      workbench.executeSearch({ forceRefresh: false });
    }
  }
</script>

<div class="space-y-4">
  <div>
    <div
      class="mb-1.5 flex items-center gap-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground"
      title={s.sectionAppearance}
    >
      <Palette class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" aria-hidden="true" />
      <span>{s.sectionAppearance}</span>
    </div>
    <div class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5">
      <SettingRow icon={Languages} label={workbench.t.ui.language} hint={workbench.t.ui.languageDesc}>
        <Segmented
          value={workbench.locale}
          options={[
            { value: 'zh', label: '中', title: '中文' },
            { value: 'en', label: 'EN', title: 'English' },
          ]}
          onchange={(v) => display(() => (workbench.locale = v))}
        />
      </SettingRow>

      <SettingRow
        icon={SunMoon}
        label={s.themeLabel}
        hint={`${workbench.t.header.lightMode} / ${workbench.t.header.darkMode}`}
      >
        <Segmented
          value={workbench.darkMode}
          options={[
            { value: false, icon: Sun, title: workbench.t.header.lightMode },
            { value: true, icon: Moon, title: workbench.t.header.darkMode },
          ]}
          onchange={(v) => workbench.darkMode !== v && workbench.toggleTheme()}
        />
      </SettingRow>

      <SettingRow icon={ALargeSmall} label={s.fontSizeLabel} hint={s.fontSizeDesc}>
        <NumberStepper
          value={workbench.codeFontSize}
          min={10}
          max={28}
          step={0.5}
          suffix="px"
          widthClass="w-11"
          onchange={(v) => display(() => (workbench.codeFontSize = v))}
        />
      </SettingRow>

      <SettingRow icon={TextWrap} label={s.wordWrapLabel} hint={s.wordWrapDesc}>
        <Switch
          checked={workbench.wordWrap}
          title={s.wordWrapDesc}
          onchange={(v) => display(() => (workbench.wordWrap = v))}
        />
      </SettingRow>

      <SettingRow icon={Rows3} label={s.densityLabel} hint={s.densityDesc}>
        <Segmented
          value={workbench.resultDensity}
          options={[
            { value: 'compact', icon: Rows4, title: s.densityCompact },
            { value: 'comfortable', icon: Rows3, title: s.densityComfortable },
          ]}
          onchange={(v) => display(() => (workbench.resultDensity = v))}
        />
      </SettingRow>

      <SettingRow icon={UnfoldVertical} label={s.previewLinesLabel} hint={s.previewLinesDesc}>
        <NumberStepper
          value={workbench.previewLines}
          min={1}
          max={6}
          step={1}
          widthClass="w-10"
          onchange={(v) => display(() => (workbench.previewLines = v))}
        />
      </SettingRow>
    </div>
  </div>

  <div>
    <div
      class="mb-1.5 flex items-center gap-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground"
      title={s.sectionContext}
    >
      <PanelRight class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" aria-hidden="true" />
      <span>{s.sectionContext}</span>
    </div>
    <div class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5">
      <SettingRow
        icon={FoldVertical}
        label={s.contextInitialLinesLabel}
        hint={s.contextInitialLinesDesc}
      >
        <NumberStepper
          value={workbench.contextInitialLines}
          min={MIN_CONTEXT_LINE_SETTING}
          max={MAX_CONTEXT_LINE_SETTING}
          step={1}
          widthClass="w-10"
          onchange={(v) =>
            display(() => (workbench.contextInitialLines = clampContextLineSetting(v)))}
        />
      </SettingRow>

      <SettingRow
        icon={ChevronsUpDown}
        label={s.contextStepLinesLabel}
        hint={s.contextStepLinesDesc}
      >
        <NumberStepper
          value={workbench.contextStepLines}
          min={MIN_CONTEXT_LINE_SETTING}
          max={MAX_CONTEXT_LINE_SETTING}
          step={1}
          widthClass="w-10"
          onchange={(v) =>
            display(() => (workbench.contextStepLines = clampContextLineSetting(v)))}
        />
      </SettingRow>

      <SettingRow
        icon={Timer}
        label={s.contextAutoLoadPaceLabel}
        hint={s.contextAutoLoadPaceDesc}
      >
        <Segmented
          value={workbench.contextAutoLoadPace}
          options={[
            { value: 'slow', icon: Turtle, title: `${s.paceSlow} (480ms)` },
            { value: 'normal', icon: Gauge, title: `${s.paceNormal} (240ms)` },
            { value: 'fast', icon: Zap, title: `${s.paceFast} (90ms)` },
          ]}
          onchange={(v) =>
            display(() => (workbench.contextAutoLoadPace = normalizeContextAutoLoadPace(v)))}
        />
      </SettingRow>
    </div>
  </div>

  <div>
    <div
      class="mb-1.5 flex items-center gap-1.5 px-0.5 text-[11.5px] font-medium text-muted-foreground"
      title={s.sectionEngine}
    >
      <Cpu class="h-3.5 w-3.5 shrink-0 text-muted-foreground/75" aria-hidden="true" />
      <span>{s.sectionEngine}</span>
    </div>
    <div class="rounded-xl border border-border/55 bg-card/55 dark:bg-card/50 divide-y divide-border/40 px-3.5">
      <SettingRow icon={ListOrdered} label={s.maxResultsLabel} hint={s.maxResultsDesc}>
        <NumberStepper
          value={workbench.maxResults}
          min={1}
          max={500000}
          step={1000}
          widthClass="w-16"
          onchange={(v) => search(() => (workbench.maxResults = v))}
        />
      </SettingRow>
    </div>
  </div>
</div>
