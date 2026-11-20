<script lang="ts">
  import { workbench } from '$lib/state.svelte';
  import FloatingPopoverShell from './pickers/FloatingPopoverShell.svelte';
  import SourcePickerContent from './pickers/SourcePickerContent.svelte';

  interface Props {
    onClose: () => void;
    onFocusMainInput?: () => void;
  }

  let { onClose, onFocusMainInput }: Props = $props();

  let panelEl = $state<HTMLDivElement | null>(null);
  let contentRef = $state<SourcePickerContent | null>(null);
</script>

<FloatingPopoverShell
  bind:panelEl
  isCompact={workbench.isCompact}
  ariaLabel={workbench.t.scopeBar.pickerTitle}
  desktopWidthClass="w-[352px] sm:w-[376px] max-w-[calc(100vw-1.5rem)]"
  mobileMaxHeightClass="max-h-[80dvh]"
  {onClose}
  onKeydown={(e) => contentRef?.handleKeydown(e)}
>
  <SourcePickerContent
    bind:this={contentRef}
    bind:panelEl
    {onClose}
    {onFocusMainInput}
  />
</FloatingPopoverShell>
