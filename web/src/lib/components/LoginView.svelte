<script lang="ts">
  import { onMount, tick } from 'svelte';
  import { workbench } from '$lib/state.svelte';
  import {
    ArrowRight,
    Eye,
    EyeOff,
    Languages,
    Loader2,
    Lock,
    SunMoon,
    Unlock,
  } from 'lucide-svelte';

  let password = $state('');
  let showPassword = $state(false);
  let shaking = $state(false);
  let inputEl = $state<HTMLInputElement | null>(null);
  let pillEl = $state<HTMLDivElement | null>(null);
  let lastHandledShake = 0;

  const isUnlocking = $derived(workbench.authState === 'unlocking');
  const canSubmit = $derived(password.length > 0 && !workbench.authSubmitting && !isUnlocking);

  const headerBtn =
    'touch-target flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground/75 hover:text-foreground hover:bg-secondary/60 active:bg-secondary/80 cursor-pointer';

  onMount(() => {
    if (!workbench.isCompact && !workbench.isTouch) {
      inputEl?.focus();
    }
  });

  $effect(() => {
    const tickCount = workbench.authShakeTick;
    if (tickCount > 0 && tickCount !== lastHandledShake) {
      lastHandledShake = tickCount;
      shaking = false;
      void tick().then(() => {
        if (pillEl) {
          void pillEl.offsetWidth;
        }
        shaking = true;
        if (!workbench.isCompact && !workbench.isTouch) {
          inputEl?.focus();
          inputEl?.select();
        }
      });
    }
  });

  async function handleSubmit(e: SubmitEvent) {
    e.preventDefault();
    if (!canSubmit) return;
    await workbench.submitLogin(password);
  }
</script>

<div class="flex flex-1 flex-col min-h-0 bg-background">
  <!-- Minimal header matching authenticated workspace height (h-11) -->
  <header class="pt-safe flex shrink-0 items-center justify-end bg-background px-3 md:px-6 select-none">
    <div class="flex h-11 items-center gap-1">
      <button
        type="button"
        title={workbench.t.header.switchLangTitle}
        aria-label={workbench.t.header.switchLangTitle}
        onclick={() => workbench.toggleLocale()}
        class={headerBtn}
      >
        <Languages class="h-3.5 w-3.5" />
      </button>
      <button
        type="button"
        title={workbench.darkMode ? workbench.t.header.lightMode : workbench.t.header.darkMode}
        aria-label={workbench.darkMode ? workbench.t.header.lightMode : workbench.t.header.darkMode}
        onclick={() => workbench.toggleTheme()}
        class={headerBtn}
      >
        <SunMoon class="h-3.5 w-3.5" />
      </button>
    </div>
  </header>

  <!-- Centered hero stage aligned vertically with Home SearchBar -->
  <main class="flex flex-1 flex-col items-center justify-center pb-[14vh] px-3 md:px-6 select-none">
    <div
      class={`flex w-full max-w-[400px] flex-col items-center ${
        isUnlocking ? 'auth-stage-unlock' : 'auth-stage-enter'
      }`}
    >
      <div class="mb-7 flex flex-col items-center text-center">
        <h1 class="font-mono text-4xl font-semibold tracking-tight text-foreground">
          webgrep
        </h1>
      </div>

      <form onsubmit={handleSubmit} class="w-full">
        <div
          bind:this={pillEl}
          onanimationend={() => (shaking = false)}
          class={`relative flex min-h-12 w-full items-center gap-2 overflow-hidden rounded-full border pl-4 pr-2 py-1 shadow-sm focus-within:bg-card focus-within:shadow-md ${
            shaking ? 'auth-pill-shake' : ''
          } ${
            workbench.authError
              ? 'border-status/65 bg-card/90'
              : 'border-border/80 bg-card/85 hover:border-border focus-within:border-border'
          }`}
        >
          {#if workbench.authSubmitting}
            <div class="pointer-events-none absolute inset-x-4 bottom-0 h-[1.5px] overflow-hidden bg-primary/10">
              <div class="search-progress-shimmer h-full w-2/5 bg-gradient-to-r from-transparent via-primary to-transparent"></div>
            </div>
          {/if}

          <span class="flex h-5 w-5 shrink-0 items-center justify-center">
            {#if isUnlocking}
              <Unlock class="h-4 w-4 text-primary" />
            {:else}
              <Lock
                class={`h-4 w-4 ${
                  workbench.authError ? 'text-status' : 'text-muted-foreground/80'
                }`}
              />
            {/if}
          </span>

          <input
            bind:this={inputEl}
            bind:value={password}
            type={showPassword ? 'text' : 'password'}
            name="password"
            autocomplete="current-password"
            enterkeyhint="go"
            autocapitalize="off"
            autocorrect="off"
            spellcheck={false}
            disabled={isUnlocking}
            placeholder={workbench.t.auth.placeholder}
            aria-label={workbench.t.auth.placeholder}
            aria-invalid={Boolean(workbench.authError)}
            oninput={() => {
              if (workbench.authError) workbench.authError = null;
            }}
            class="h-9 min-w-0 flex-1 bg-transparent px-1 font-mono text-[14.5px] [@media(any-pointer:coarse)]:text-[16px] text-foreground placeholder:text-muted-foreground/65 focus:outline-none disabled:opacity-70"
          />

          <div class="flex shrink-0 items-center gap-1">
            {#if password.length > 0 && !isUnlocking}
              <button
                type="button"
                tabindex={-1}
                onmousedown={(e) => e.preventDefault()}
                onclick={() => (showPassword = !showPassword)}
                title={showPassword
                  ? workbench.t.auth.hidePasswordTitle
                  : workbench.t.auth.showPasswordTitle}
                aria-label={showPassword
                  ? workbench.t.auth.hidePasswordTitle
                  : workbench.t.auth.showPasswordTitle}
                class="touch-target flex h-7 w-7 items-center justify-center rounded-full text-muted-foreground/75 hover:bg-secondary/70 hover:text-foreground cursor-pointer"
              >
                {#if showPassword}
                  <EyeOff class="h-3.5 w-3.5" />
                {:else}
                  <Eye class="h-3.5 w-3.5" />
                {/if}
              </button>
            {/if}

            <button
              type="submit"
              disabled={!canSubmit}
              title={workbench.t.auth.unlockTitle}
              aria-label={workbench.t.auth.unlockTitle}
              class={`touch-target flex h-8 w-8 items-center justify-center rounded-full ${
                canSubmit
                  ? 'bg-primary text-primary-foreground hover:opacity-90 active:scale-95 cursor-pointer'
                  : isUnlocking
                    ? 'bg-primary/15 text-primary'
                    : 'bg-secondary/60 text-muted-foreground/45 cursor-default'
              }`}
            >
              {#if workbench.authSubmitting}
                <Loader2 class="h-3.5 w-3.5 animate-spin" />
              {:else}
                <ArrowRight class="h-3.5 w-3.5" />
              {/if}
            </button>
          </div>
        </div>

        <!-- Fixed height slot prevents vertical layout shift (Zero-CLS) when error appears -->
        <div class="mt-3 flex h-5 items-center justify-center">
          {#if workbench.authError}
            <span role="alert" class="text-xs text-status">
              {workbench.authError}
            </span>
          {/if}
        </div>
      </form>
    </div>
  </main>
</div>
