# WebGrep 前端架构、极致性能与视觉流畅度开发规范

本文档是 `webgrep` 前端（`web/`）的核心工程规范。所有功能迭代、组件开发与重构必须遵循本文档确立的 **“渐进式搜索优先（Progressive Search First）+ 120Hz 零重排渲染管线 + 零闪烁视觉连续性（Zero-Flicker & Zero-CLS）”** 三大原则。

---

## 目录

1. [技术栈基线与构建工具链](#一技术栈基线与构建工具链)
2. [产品与交互规范：零负担渐进式搜索](#二产品与交互规范零负担渐进式搜索)
3. [Svelte 5 细粒度响应式与内存管理铁律](#三svelte-5-细粒度响应式与内存管理铁律)
4. [120Hz 虚拟列表与浏览器合成器（Compositor）优化](#四120hz-虚拟列表与浏览器合成器compositor优化)
5. [视觉丝滑度与帧率控制（Frame Pacing & Stale-While-Revalidate）](#五视觉丝滑度与帧率控制frame-pacing--stale-while-revalidate)
6. [零累积布局偏移（Zero CLS）与色彩体系](#六零累积布局偏移zero-cls与色彩体系)
7. [代码审查清单（PR / Agent 自检 Checklist）](#七代码审查清单pr--agent-自检-checklist)

---

## 一、技术栈基线与构建工具链

| 模块 | 版本基线 | 关键约束 |
| :--- | :--- | :--- |
| **TypeScript** | **`^7.0.2`** (`@typescript/typescript-darwin-arm64`) | 原生编译器；`tsconfig.json` **严禁配置已移除的 `baseUrl`**，路径别名统一使用 `"paths": { "$lib/*": ["./src/lib/*"] }`，并显式声明 `"types": ["svelte", "vite/client"]`。 |
| **Vite** | **`^8.3.5`** (Rolldown 原生打包引擎) | 保持 ESNext 产物目标与 Tree-shaking 纯净，避免全量导入图标库或工具包。 |
| **Svelte** | **`^5.57.2`** + `@sveltejs/vite-plugin-svelte` **`^7.3.1`** | 全面启用 **Svelte 5 Runes**（`$state`、`$state.raw`、`$derived`、`$derived.by`、`$effect`、`{#snippet}` / `{@render}`），**严禁混用 Svelte 4 旧语法**（`export let`、`$:`、`createEventDispatcher`、`<slot>`）。 |

### 必跑校验命令
每次修改前端代码后，必须确保以下两条命令零报错通过：
```bash
npm --prefix web run check   # TypeScript 7 (tsc --noEmit) 全量类型检查 (<100ms)
npm --prefix web run build   # Vite 8 (Rolldown) 生产环境打包校验
```

---

## 二、产品与交互规范：零负担渐进式搜索

### 2.1 浏览器地址栏式极简搜索框（[`SearchBar.svelte`](../web/src/lib/components/SearchBar.svelte)）
- **禁止常驻模式按钮**：搜索栏右侧严禁堆砌常驻的 `Aa`、`\b`、`.*` 或高级过滤抽屉按钮。未输入时右侧仅展示 `/` 快捷键提示；输入后仅展示当前激活的紧凑状态角标与清除键 `×`。
- **空格即深搜（Progressive Drill-Down）**：
  - 无论在字面量模式还是正则模式（`$r`）下，**第 1 个普通词永远作为主匹配模式（`primaryPattern`）**；
  - 后续以空格分隔的普通词一律归入二次过滤条件（`contains`），在已命中的结果行内做渐进式收窄（AND 语义）。
  - 如果主正则或二次过滤词本身包含空格，使用双引号包裹（如 `"GET /outerserv"`）即可作为单一体词元解析；而单Token带引号且无内部空格时（如 `"\d{12}"`）保留原引号供正则匹配。

### 2.2 内联操作符（`@` 无限层级范围、`$模式` 与 `-排除`）
1. **`@` 无限层级多 Tag 数据源与路径过滤（及 `-@排除范围`）**：
   - `webgrep` 不再使用启动命令行绑定单目录的旧模式，而是通过 [`SettingsPopover.svelte`](../web/src/lib/components/SettingsPopover.svelte) 的「数据源」页（顶栏 `Database` 图标或 `⌘/Ctrl + K` 命令面板）动态管理目录数据源，每个目录支持绑定**多个 Tag**，并持久化至 `<data_dir>/sources.json`。
   - **无限层级 `@` 语法**：支持 `@tag`（按 Tag 聚合群搜）、`@tag1-tag2`（多 Tag 交集）、`@tag-数据源名`（精确锁源）、以及继续通过 `/` 或 `-` 深入任意层级的子目录与文件（如 `@zig-webgrep/web/src/lib/components` 或 `@zig-webgrep-src-search_job.zig`）。
   - **分级下钻补全交互**：输入 `@` 唤起下拉菜单时，按 **`Enter` 或点击条目**直接确认该范围；按 **`Tab` 或点击右侧「下钻 ▸」**则自动补全 `-` 或 `/` 分隔符并立即展开下一层级（`Tag -> 数据源 -> 子目录 -> 文件`），全程无需关闭补全菜单。
2. **`$模式`（`$r` 正则、`$c` 区分大小写、`$w` 全词匹配）**：
   - 仅保留 `$r`、`$c`、`$w` 三个独立模式开关（不设 `$rc` 组合项，保持心智模型极简）。
   - **防重复选择机制**：当用户输入 `$` 弹出菜单时，实时扫描当前输入光标前已启用的 `$` 标记（`priorRegex` / `priorCase` / `priorWord`）。**已启用过的选项必须在下拉列表中打勾（`✓`）、置灰（`disabled` + `opacity-45 cursor-not-allowed`）、不可点击**，且键盘 `↑`/`↓` 导航与默认高亮索引（`effectiveFlagIdx`）自动跳过已置灰项。
   - **防冲突规则**：仅当独立词以 `$` 开头且精确匹配已知标志时才解析为模式开关；词尾的正则行尾锚点（如 `"^\d{12}"$`）或代码中的普通变量（如 `$PATH`、`$100`）一律正常作为搜索内容处理；末尾正在输入的裸 `$` 或裸 `@` 在解析器中静默忽略，严禁打断当前屏幕已有的搜索结果。
3. **所有激活态角标与胶囊必须可点击剥离**：
   - 搜索框右侧的 `.*`、`Aa`、`\b`、`+N`、`-N`、`@N`，以及状态栏（[`TelemetryBar.svelte`](../web/src/lib/components/TelemetryBar.svelte)）中的 `+深搜词 ×`、`-排除词 ×`、`@分类` 胶囊，点击后必须立即从查询串中剥离对应条件并重搜。

---

## 三、Svelte 5 细粒度响应式与内存管理铁律

### 3.1 大数据集强制使用 `$state.raw`（[`state.svelte.ts`](../web/src/lib/state.svelte.ts)）
流式搜索结果经常包含数千至数万条 `HitItem`。如果使用普通 `$state([])`，Svelte 5 会递归将每一条 `HitItem` 及其 `spans` 数组包装为 `Proxy`，导致严重的内存膨胀与 GC 停顿。

- **错误写法（严禁）**：
  ```ts
  // ❌ 严禁对大批量流式数据使用深层响应式 $state
  fileGroups = $state<FileHitGroup[]>([]);
  flatHits = $state<HitItem[]>([]);
  ```
- **正确写法（强制）**：
  ```ts
  // ✅ 强制使用 $state.raw，配合 Copy-on-Write 浅拷贝更新
  fileGroups = $state.raw<FileHitGroup[]>([]);
  flatHits = $state.raw<HitItem[]>([]);
  ```
  在 [`flushPendingHitsSync`](../web/src/lib/state.svelte.ts) 中合并流式分片时，仅对本次有新增命中的 `FileHitGroup` 做浅拷贝（`touchedGroups`），未发生变动的文件分组保持原对象引用不变。

### 3.2 消除 `{#each}` 内部广播依赖（O(1) 选中态更新）
在虚拟列表 `{#each visibleSlice.items as row (row.key)}` 中，严禁在每行内部直接读取高频变化的全局对象信号。

- **错误写法（严禁）**：
  ```svelte
  <!-- ❌ 每次按 ↑/↓ 切换 activeHit 时，视口内全部 25 行都会重新求值 -->
  {@const active = workbench.activeHit?.file === item.file && workbench.activeHit?.line === item.line}
  ```
- **正确写法（强制）**：
  ```ts
  // ✅ 1. 在列表顶层派生单一原始字符串信号
  const activeHitKey = $derived.by(() => {
    const cur = workbench.activeHit;
    return cur ? `${cur.file}:${cur.line}:${cur.col}` : '';
  });
  ```
  ```svelte
  <!-- ✅ 2. 行内仅做原始字符串相等比对，按 ↑/↓ 时全屏仅 2 个 DOM 节点更新样式 -->
  {@const active = row.hitKey === activeHitKey}
  ```

### 3.3 `WeakMap` 零分配高亮分词缓存（[`utils.ts`](../web/src/lib/utils.ts)）
单条 JSON 日志行可达数千字符。若在滚动帧或选中态切换时重复调用 `buildHighlightSegments`（含 `toLowerCase()`、Span 排序、长行窗口裁剪与字符串切片），会产生大量短命对象分配并触发 GC 掉帧。

- **强制规范**：
  - 虚拟列表中的高亮分词必须调用 [`getCachedHighlightSegments(item, containsTerms, isCaseInsensitive, segmentCacheKey)`](../web/src/lib/utils.ts)；
  - 内部使用 `WeakMap<HitItem, { cacheKey: string; segments: HighlightSegment[] }>` 缓存分词结果；
  - 滚动与上下键导航时直接 **O(1) 命中缓存（零内存分配）**；当新搜索替换 `flatHits` 后，旧 `HitItem` 引用脱离，由引擎自动垃圾回收，无任何内存泄漏风险。
  - 文件路径解析统一调用带缓存的 [`splitFilePath(filePath)`](../web/src/lib/utils.ts)。

### 3.4 编译级模板复用 `{#snippet}`
对于列表行、详情面板（JSON 视图 / 原文视图 / KV 视图）中重复出现的高亮片段渲染，优先使用 Svelte 5 的 `{#snippet renderSegments(segments)}` 与 `{@render renderSegments(segments)}`。严禁将高频渲染的单行词元拆分为独立 `.svelte` 子组件而引入额外的组件实例开销。

---

## 四、120Hz 虚拟列表与浏览器合成器（Compositor）优化

### 4.1 零重排（Zero-Reflow）GPU 合成层位移（[`ResultList.svelte`](../web/src/lib/components/ResultList.svelte)）
- **错误写法（严禁）**：
  - 严禁使用上下两个 `<div style="height: {topPad}px">` 和 `<div style="height: {bottomPad}px">` 占位元素来实现虚拟列表定位。每次滚动修改文档流内元素的 `height` 会使整个滚动容器布局失效，强制浏览器主线程每帧执行全树 **Layout（重排）**。
- **正确写法（强制）**：
  1. 外层跑道容器固定总高度：`style="height: {visibleSlice.totalHeight}px"`；
  2. 内层视口切片容器使用 GPU 硬件合成层位移：
     ```svelte
     <div
       class="virtual-slice-gpu absolute left-0 right-0 top-0"
       style={`transform: translate3d(0, ${visibleSlice.offsetY}px, 0)`}
     >
     ```
  3. 每一个具有固定高度的虚拟行（`header`、`hit`、`gap`）必须标注 `.virtual-row-strict`（[`app.css`](../web/src/app.css)）：
     ```css
     .virtual-row-strict {
       contain: strict; /* 同时隔离 size, layout, paint, style */
     }
     .virtual-slice-gpu {
       will-change: transform;
       contain: layout style;
     }
     ```
  - **效果**：浏览器合成器直接在 GPU 线程平移视口层，单行内部的文本重绘绝不穿透到行外，在 120Hz ProMotion 屏幕上实现 `< 0.1ms` 的主线程布局耗时。

---

## 五、视觉丝滑度与帧率控制（Frame Pacing & Stale-While-Revalidate）

### 5.1 无缝保留旧结果（Stale-While-Revalidate，严禁白屏闪烁）
人类视觉对“大面积亮暗跳变（高对比度频闪）”极其敏感。

- **严禁行为**：在 [`executeSearch`](../web/src/lib/state.svelte.ts) 发起新搜索时，**严禁同步调用 `resetResultBuffer()` 清空 `fileGroups`**。否则用户连续输入 5 个字母时，屏幕会经历 5 次 `结果列表 -> 空白背景转圈 -> 结果列表` 的剧烈频闪。
- **标准流程**：
  1. `executeSearch()` 启动时仅设置 `this.awaitingFirstChunk = true` 并清空待处理队列 `pendingChunks = []`，**旧的 `fileGroups` 和统计数字保持在屏幕上不动**；
  2. 搜索框底边显示 `1.5px` 的 GPU 流光进度条（`.search-progress-shimmer`），提供非侵入式的“正在扫描”反馈；
  3. 当新搜索的首屏聚合数据到达（或 `done` 消息到达）时，在 `flushPendingHitsSync()` 内部**同一渲染帧内原子替换**旧数据。

### 5.2 两阶段流式节拍器与 VSync 帧边界对齐（[`state.svelte.ts`](../web/src/lib/state.svelte.ts)）
后端多线程引擎在毫秒级即可吐出分片。如果前端以 16ms（60Hz）毫无节制地刷新列表高度与计数，用户眼睛看到的将是一团无法阅读的跳动残影。

- **阶段一：首屏聚合窗口（`60ms`）**：
  - 当 `awaitingFirstChunk === true` 时，收到首个 `hits` 分片后开启 `60ms` 聚合窗口（`scheduleFlushHits(60)`）。
  - 若搜索在 `60ms` 内完成（如常见的 `20ms–55ms` 快搜），`done` 帧直接触发一次性全量渲染——**整个搜索生命周期 DOM 只更新 1 次**，彻底消灭 `1条 -> 17条 -> 81条 -> 546条` 的碎片跳动。
  - 若搜索耗时超过 `60ms`（如扫描数 GB 日志），在 `60ms` 到期时已攒够铺满整个首屏视口的命中行，一次性平滑替换首屏。
- **阶段二：稳态流式节拍（`80ms` + `requestAnimationFrame`）**：
  - 首屏铺满后，后续分片以 `80ms`（约 12.5fps 的舒适阅读节奏）合并，并通过 `requestAnimationFrame` 对齐到浏览器下一帧 VSync 起点统一提交。
- **高频交互事件全面 rAF 锁流**：
  - 虚拟列表 `onscroll`（[`ResultList.svelte`](../web/src/lib/components/ResultList.svelte)）与右侧详情栏宽度拖拽 `onmousemove`（[`App.svelte`](../web/src/App.svelte)）必须经过 `requestAnimationFrame` 节流，保证每帧最多触发 1 次状态变更。

---

## 六、零累积布局偏移（Zero CLS）与色彩体系

1. **状态栏左侧视觉锚点固定（[`TelemetryBar.svelte`](../web/src/lib/components/TelemetryBar.svelte)）**：
   - `N 处命中 · M 个文件` 必须永远固定在状态栏最左侧第一位；
   - 临时状态（检索中的 `正在检索… [停止]` 与检索完成后的 `耗时 · 扫描体积`）共用其右侧的同一槽位原地切换；
   - **严禁**在最左侧动态插入/移除临时状态元素，杜绝搜索开始和结束时整行文字与分类胶囊左右横跳。
2. **单文件行高单调锁死（[`ResultList.svelte`](../web/src/lib/components/ResultList.svelte) `groupLineCache`）**：
   - 在同一次搜索（同一个 `currentSearchId`）的流式追加过程中，通过 `groupLineCache` 记录每个文件分组已计算出的最大行数（1 / 2 / 3 行），确保单文件行高**只增不减**，防止后续流式分片到达时已渲染卡片上下抽动。
3. **等宽数字对齐（`tabular-nums`）**：
   - 所有行号（`min-w-[3.25rem] tabular-nums` 适配千万行日志）、命中数、耗时、文件计数必须启用 `tabular-nums`，防止数字变化时宽度抖动。
4. **深搜胶囊与正文高亮色彩严格映射**：
   - 主匹配词（`primary`）：琥珀金 `.match-span-primary`
   - 第 1 深搜词（`contains-0`）：天蓝 `.match-span-contains-0` ↔ 状态栏天蓝胶囊
   - 第 2 深搜词（`contains-1`）：紫红 `.match-span-contains-1` ↔ 状态栏紫红胶囊
   - 第 3 深搜词（`contains-2`）：翠绿 `.match-span-contains-2` ↔ 状态栏翠绿胶囊
   - 排除词（`exclude`）：玫红状态栏胶囊

---

## 七、代码审查清单（PR / Agent 自检 Checklist）

在提交任何前端代码前，逐条核对以下问题：

- [ ] 是否在搜索框中新增了非必要的常驻按钮？（应通过 `@` / `$` 内联语法或可点击状态胶囊实现）
- [ ] 新增的大数组/流式集合是否使用了 `$state.raw`？
- [ ] `{#each}` 列表循环内是否存在每次重绘都执行的复杂函数或未缓存的字符串处理？（应使用 `WeakMap` 缓存或外提 `$derived` 原始值）
- [ ] 虚拟列表是否保持了 `translate3d(0, offsetY, 0)` + `.virtual-row-strict`（`contain: strict`）结构？
- [ ] 新搜索触发时是否保持了 `awaitingFirstChunk`（无缝保留旧结果，不闪白屏）？
- [ ] 动态出现的 UI 元素是否会导致相邻文字或列表发生水平/垂直位移（CLS）？
- [ ] `npm --prefix web run check && npm --prefix web run build` 是否零报错通过？

---

## 八、图标优先、快捷键与移动端规范

- **色彩**：仅「中性灰阶 + `primary` 强调色 + `status` 状态色」。禁止新增 `amber/emerald/rose/sky/fuchsia` 等硬编码彩色类；匹配高亮层级用下划线样式（实线/虚线/点线）区分。
- **文字**：状态栏、顶栏、按钮优先使用 lucide 图标，文字放入 `title` / `aria-label`。
- **顶栏**：仅连接状态、数据源、设置。主题、语言、快捷键帮助归入设置；命令入口为 `⌘/Ctrl + K`（[`CommandPalette.svelte`](../web/src/lib/components/CommandPalette.svelte)，命令表见 `lib/commands.ts`）。
- **快捷键**：`Alt + C/W/R` 必须使用 `e.code`（macOS 下 `e.key` 会变成特殊字符）；`Esc` 逐层返回；`[` `]` 切换文件；`Tab` 在搜索框与列表间切换焦点。
- **移动端（< 768px，`workbench.isCompact`）**：列表与详情为栈式导航（`detailOpen` + `history.pushState`，系统返回键回列表）；设置为底部抽屉；软键盘上方显示 [`SymbolBar.svelte`](../web/src/lib/components/SymbolBar.svelte)；结果行长按弹出操作面板。
- **触控**：可点击元素在 `(pointer: coarse)` 下命中区 ≥ 44px（`.touch-target`）；不得依赖 `hover` 显示核心操作；根容器使用 `h-app`（`100dvh`）与 `pt-safe` / `pb-safe`。
