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
    UnfoldVertical,
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

</div>
