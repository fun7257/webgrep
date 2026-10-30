<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import NumberStepper from '../ui/NumberStepper.svelte';
  import Segmented from '../ui/Segmented.svelte';
  import SettingRow from '../ui/SettingRow.svelte';
  import Switch from '../ui/Switch.svelte';
  import {
    AlignLeft,
    ALargeSmall,
    Languages,
    ListOrdered,
    Moon,
    Rows3,
    Rows4,
    Sun,
    SunMoon,
    Timer,
    UnfoldVertical,
    Zap,
  } from 'lucide-svelte';

  const s = $derived(workbench.t.settings);

  /** Display-only settings: persisted, no re-search. */
  function display(fn: () => void) {
    fn();
    workbench.saveSettings();
  }

  /** Search-affecting settings: persisted and re-run the current query. */
  function search(fn: () => void) {
    fn();
    workbench.saveSettings();
    if (workbench.pattern.trim().length > 0) workbench.scheduleSearch(true);
  }
</script>

<div class="space-y-1">
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

  <SettingRow icon={SunMoon} label={s.themeLabel}>
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

  <SettingRow icon={AlignLeft} label={s.wordWrapLabel} hint={s.wordWrapDesc}>
    <Switch
      checked={workbench.wordWrap}
      title={s.wordWrapLabel}
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

  <div class="my-2 border-t border-border/60"></div>

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

  <SettingRow icon={UnfoldVertical} label={s.contextLinesLabel} hint={s.contextLinesDesc}>
    <NumberStepper
      value={workbench.contextLines}
      min={0}
      max={10}
      step={1}
      prefix="±"
      widthClass="w-8"
      onchange={(v) => search(() => (workbench.contextLines = v))}
    />
  </SettingRow>

  <SettingRow icon={Timer} label={s.debounceLabel} hint={s.debounceDesc}>
    <NumberStepper
      value={workbench.debounceMs}
      min={0}
      max={2000}
      step={20}
      suffix="ms"
      widthClass="w-11"
      onchange={(v) => display(() => (workbench.debounceMs = v))}
    />
  </SettingRow>

  <SettingRow icon={Zap} label={s.liveSearchLabel} hint={s.liveSearchDesc}>
    <Switch
      checked={workbench.liveSearch}
      title={s.liveSearchLabel}
      onchange={(v) => display(() => (workbench.liveSearch = v))}
    />
  </SettingRow>
</div>
