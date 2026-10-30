# WebGrep 前端架构、极致性能与视觉流畅度开发规范

本文档是 `webgrep` 前端（`web/`）的核心工程规范。所有功能迭代、组件开发与重构必须遵循本文档确立的 **“渐进式搜索优先（Progressive Search First）+ 120Hz 零重排渲染管线 + 零闪烁视觉连续性（Zero-Flicker & Zero-CLS）+ 图标优先的少色少字设计语言（含移动端与触控）”** 四大原则。

---

## 目录

1. [技术栈基线与构建工具链](#一技术栈基线与构建工具链)
2. [产品与交互规范：零负担渐进式搜索](#二产品与交互规范零负担渐进式搜索)
3. [Svelte 5 细粒度响应式与内存管理铁律](#三svelte-5-细粒度响应式与内存管理铁律)
4. [120Hz 虚拟列表与浏览器合成器（Compositor）优化](#四120hz-虚拟列表与浏览器合成器compositor优化)
5. [视觉丝滑度与帧率控制（Frame Pacing & Stale-While-Revalidate）](#五视觉丝滑度与帧率控制frame-pacing--stale-while-revalidate)
6. [零累积布局偏移（Zero CLS）与高亮层级](#六零累积布局偏移zero-cls与高亮层级)
7. [代码审查清单（PR / Agent 自检 Checklist）](#七代码审查清单pr--agent-自检-checklist)
8. [设计语言：少色、少字、图标优先](#八设计语言少色少字图标优先)
9. [快捷键与命令面板规范](#九快捷键与命令面板规范)
10. [移动端与触控规范](#十移动端与触控规范)
11. [设置与数据源面板规范](#十一设置与数据源面板规范)

---

## 一、技术栈基线与构建工具链

| 模块 | 版本基线 | 关键约束 |
| :--- | :--- | :--- |
| **TypeScript** | **`^7.0.2`** (`@typescript/typescript-darwin-arm64`) | 原生编译器；`tsconfig.json` **严禁配置已移除的 `baseUrl`**，路径别名统一使用 `"paths": { "$lib/*": ["./src/lib/*"] }`，并显式声明 `"types": ["svelte", "vite/client"]`。 |
| **Vite** | **`^8.3.5`** (Rolldown 原生打包引擎) | 保持 ESNext 产物目标与 Tree-shaking 纯净，避免全量导入图标库或工具包。 |
| **Tailwind CSS** | **`^3.4.19`**（PostCSS + `tailwind.config.js`，`darkMode: 'class'`，`future.hoverOnlyWhenSupported: true`） | 颜色一律走语义令牌（`primary`、`status`、`secondary`、`muted-foreground` 等），禁止硬编码彩色类；字体使用系统字体栈，**不依赖外链字体**。 |
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
- **禁止常驻模式按钮**：搜索栏严禁堆砌常驻的 `Aa`、`\b`、`.*` 或高级过滤抽屉按钮；输入后右侧仅展示清除键 `×`，激活的条件以状态栏胶囊呈现。唯一例外是移动端软键盘上方的 [`SymbolBar.svelte`](../web/src/lib/components/SymbolBar.svelte)（见第十章），它只在窄屏且输入框聚焦时出现。
- **输入框提示**：首页用简短 placeholder 提示语法（`空格深搜 · -排除 · @范围 · $r`），完整帮助收在设置的「快捷键」页，不设独立的帮助弹窗。
- **空格即深搜（Progressive Drill-Down）**：
  - 无论在字面量模式还是正则模式（`$r`）下，**第 1 个普通词永远作为主匹配模式（`primaryPattern`）**；
  - 后续以空格分隔的普通词一律归入二次过滤条件（`contains`），在已命中的结果行内做渐进式收窄（AND 语义）。
  - 如果主正则或二次过滤词本身包含空格，使用双引号包裹（如 `"GET /outerserv"`）即可作为单一体词元解析；而单Token带引号且无内部空格时（如 `"\d{12}"`）保留原引号供正则匹配。

### 2.2 内联操作符（`@` 数据源范围、`$模式` 与 `-排除`）
1. **`@` 数据源范围（及 `-@排除范围`）**：
   - `webgrep` 不再使用启动命令行绑定单目录的旧模式，而是通过 [`SettingsPopover.svelte`](../web/src/lib/components/SettingsPopover.svelte) 的「数据源」页（顶栏 `Database` 图标或 `⌘/Ctrl + K` 命令面板）动态管理目录/单文件数据源，持久化至 `<data_dir>/sources.json`。数据源只有名称、路径、启停三个属性，**没有 Tag 概念**，也不做 Tag 聚合。
   - 语法：`@数据源名` 限定检索范围，`-@数据源名` 排除；输入 `@` 唤起补全菜单，菜单仅列出已配置的数据源（按名称或 id 模糊匹配），点击或 `Enter` 确认。
   - 结果行上点击 `@源` 可把该数据源追加到查询；长按行菜单可追加 `@源` / `-@源`（见第十章）。
2. **`$模式`（`$r` 正则、`$c` 区分大小写、`$w` 全词匹配）只有带括号的作用域写法生效**：
   - 写法为 `$r(…)`、`$c(…)`、`$w(…)`，以及组合 `$rc(…)`、`$rw(…)`、`$cw(…)`、`$rcw(…)`；模式只作用于括号内的词元，**可在同一查询中叠加多个**（如 `error $r(\d+) timeout $c(Foo)`）。
   - **不存在“整体开关”**：裸 `$r` / `$c` / `$w` 不改变任何全局状态，解析器会忽略它们；`caseMode`、`wholeWord` 等全局派生状态已移除，发给后端的 `case`、`wholeWord` 固定为 `insensitive` / `false`。严禁重新引入全局大小写、全词或正则开关（状态不可见、不可叠加、难以判断）。
   - 输入 `$` 弹出补全菜单，选中后插入 `$r()` 并把光标放进括号；快捷键 `Alt + C/W/R` 与移动端符号工具条的行为一致——**在光标处插入对应的作用域 token**（见第九、十章）。
   - **防冲突规则**：仅当独立词以 `$` 开头且精确匹配已知标志时才解析为模式；词尾的正则行尾锚点（如 `"^\d{12}"$`）或代码中的普通变量（如 `$PATH`、`$100`）一律正常作为搜索内容处理；末尾正在输入的裸 `$` 或裸 `@` 在解析器中静默忽略，严禁打断当前屏幕已有的搜索结果。
3. **所有激活态角标与胶囊必须可点击剥离**：
   - 状态栏（[`TelemetryBar.svelte`](../web/src/lib/components/TelemetryBar.svelte)）中的 `+深搜词 ×`、`-排除词 ×` 等胶囊，点击后必须立即从查询串中剥离对应条件并重搜；触屏下胶囊命中区不得小于 44px（见第十章）。

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
  // ✅ 1. 行内只与单一原始值（当前选中下标）比对
  //    （`workbench.activeHitIndex` 是 number，每次只会让新旧两行重新求值）
  ```
  ```svelte
  <!-- ✅ 2. 行内仅做原始值（number）相等比对，按 ↑/↓ 时全屏仅 2 个 DOM 节点更新样式 -->
  {@const active = row.idx === workbench.activeHitIndex}
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

> 适用范围仅限结果列表与详情中的**高频行内片段**。设置、数据源等低频面板应拆分为小组件复用（`ui/SettingRow`、`ui/Segmented`、`settings/*Pane`，见第十一章），以保持单文件职责单一。

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
  3. 每一个具有固定高度的虚拟行（结果行）必须标注 `.virtual-row-strict`（[`app.css`](../web/src/app.css)）：
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
  - 虚拟列表 `onscroll`（[`ResultList.svelte`](../web/src/lib/components/ResultList.svelte)）与右侧详情栏宽度拖拽 `pointermove`（[`App.svelte`](../web/src/App.svelte)，使用 Pointer Events + `setPointerCapture`，不再使用 `mouse*` 事件，以兼容触屏与笔）必须经过 `requestAnimationFrame` 节流，保证每帧最多触发 1 次状态变更。

---

## 六、零累积布局偏移（Zero CLS）与高亮层级

1. **状态栏左侧视觉锚点固定（[`TelemetryBar.svelte`](../web/src/lib/components/TelemetryBar.svelte)）**：
   - 命中数（`Hash` 图标 + 数字）必须永远固定在状态栏最左侧第一位；
   - 临时状态（检索中的转圈与 `Square` 停止图标、完成后的 `Timer` 图标 + 耗时）共用其右侧的同一槽位原地切换；
   - **严禁**在最左侧动态插入/移除临时状态元素，杜绝搜索开始和结束时整行内容与胶囊左右横跳。
2. **结果行高单调锁死（[`ResultList.svelte`](../web/src/lib/components/ResultList.svelte) `lockedMaxLines`）**：
   - 同一次搜索（同一个 `currentSearchId`）的流式追加过程中，换行模式下的最大行数（1 / 2 行）只增不减，新搜索开始时才重置，防止后续分片到达时已渲染行上下抽动；
   - 来源面包屑行（`@源`）**始终保留占位高度**，只在数据源切换时显示内容，不得因条件渲染改变行高。
3. **等宽数字对齐（`tabular-nums`）**：
   - 所有行号、命中数、耗时、文件计数必须启用 `tabular-nums`，防止数字变化时宽度抖动。
4. **深搜词与正文高亮：同一色相，靠下划线样式分层**（详见第八章）：
   - 主匹配词 `.match-span-primary`：`primary` 底色，实线下划线；
   - 第 1 深搜词 `.match-span-contains-0`：实线下划线；第 2 个 `.match-span-contains-1`：虚线；第 3 个 `.match-span-contains-2`：点线；
   - 状态栏胶囊统一使用 `bg-primary/10 text-primary`，排除词使用灰阶胶囊。**严禁再用多种色相区分层级。**

---

## 七、代码审查清单（PR / Agent 自检 Checklist）

在提交任何前端代码前，逐条核对以下问题：

- [ ] 是否在搜索框中新增了非必要的常驻按钮？（应通过 `@` / `$` 内联语法或可点击状态胶囊实现）
- [ ] 新增的大数组/流式集合是否使用了 `$state.raw`？
- [ ] `{#each}` 列表循环内是否存在每次重绘都执行的复杂函数或未缓存的字符串处理？（应使用 `WeakMap` 缓存或外提 `$derived` 原始值）
- [ ] 虚拟列表是否保持了 `translate3d(0, offsetY, 0)` + `.virtual-row-strict`（`contain: strict`）结构？
- [ ] 新搜索触发时是否保持了 `awaitingFirstChunk`（无缝保留旧结果，不闪白屏）？
- [ ] 动态出现的 UI 元素是否会导致相邻文字或列表发生水平/垂直位移（CLS）？
- [ ] 是否引入了 `amber/emerald/rose/sky/fuchsia` 等硬编码彩色类或新的颜色令牌？（只允许 `primary` / `status` / 灰阶）
- [ ] 新增按钮、状态是否优先用图标，文字是否放进 `title` / `aria-label`？
- [ ] 可点击元素在触屏下命中区是否 ≥ 44px（`.touch-target`）？是否依赖 `hover` 才能看到核心操作？
- [ ] 窄屏（< 768px）下列表/详情/设置是否仍可用？输入框字号在触屏下是否为 16px（避免 iOS 聚焦放大）？
- [ ] 是否新增了全局模式开关或整体切换快捷键？（应改为在查询中插入 `$x(…)` token）
- [ ] 快捷键是否使用 `e.code`（Alt + 字母）、是否同步更新了设置里的「快捷键」页（`i18n.ts`）？
- [ ] 文案是否进入 `i18n.ts`（zh / en 同步），组件内有无散落的 `locale === 'zh' ? … : …`？
- [ ] `npm --prefix web run test && npm --prefix web run check && npm --prefix web run build` 是否零报错、零警告通过？

---

## 八、设计语言：少色、少字、图标优先

### 8.1 色彩（令牌见 [`app.css`](../web/src/app.css) 与 `tailwind.config.js`）
| 角色 | 令牌 | 用途 |
| :--- | :--- | :--- |
| 中性灰阶 | `background` / `foreground` / `secondary` / `border` / `muted-foreground` | 99% 的界面 |
| 强调色 | `primary` | 当前选中、激活开关、匹配高亮、可点击胶囊 |
| 状态色 | `status` | 错误、警告、断线、缺失路径、二次确认（**错误与警告共用同一个色**） |

- 灰阶透明度只用三档：`text-muted-foreground`（次要）、`/70`（弱）、`/45`（仅装饰，**不得承载文字**）。
- 禁止在组件里硬编码 `amber / emerald / rose / sky / fuchsia / indigo` 等色类；语言/文件类型徽章也不得按类型着色。
- 匹配高亮：`.match-span-*` 全部使用 `primary` 同一色相，层级靠下划线样式区分（实线 / 虚线 / 点线）。

### 8.2 文字与图标
- 状态栏、顶栏、行内操作、设置标签页一律使用 lucide 图标；说明性文字放进 `title` / `aria-label`，不占版面。
- 允许保留的文字：搜索框内容、结果正文、设置项的**短标签**（`SettingRow` 的 `label`）、快捷键帮助。设置项的详细说明只作为 tooltip（`hint`）。
- 禁止用大写字母加字距（`uppercase tracking-wider`）的分组小标题；分组用细分隔线（`border-t border-border/60`）。
- 新增图标前确认 `lucide-svelte` 中存在该名称（如没有 `wrap-text`，用 `AlignLeft` 代替）；按需具名导入，禁止全量导入。

### 8.3 顶栏
- 仅保留三项：连接状态图标（断线时变为可点击的 `WifiOff`，状态色）、数据源（`Database`，有缺失源时带状态色圆点）、设置（`SlidersHorizontal`）。
- **禁止**在顶栏加入计数动画、主题/语言/快捷键独立按钮；这些进入设置或命令面板。

### 8.4 结果行
- 复制按钮**常驻**显示（低对比），不得使用 `opacity-0 group-hover:opacity-100`；窄屏的行内容为 `文件名:行号`。
- 来源 `@源` 仅在与上一行数据源不同时显示（占位高度不变，见第六章）。
- 触屏上行不可选中文字（`select-none`），长按弹出操作面板（第十章）。

### 8.5 输入与状态
- 触屏上所有 `input` / `textarea` / `select` 字号强制 16px（`app.css` 的 `any-pointer: coarse` 规则），否则 iOS Safari 聚焦时会整页放大并撑出屏幕。
- 取消搜索（停止按钮、`Esc`）必须**立即定格**：冲刷已到达的命中，记录 `cancelledSearchId`，丢弃该 id 后续的所有 WebSocket 帧，再向后端发送 `cancel`；否则排队中的分片会让结果在点击停止后继续增长。

## 九、快捷键与命令面板规范

| 快捷键 | 行为 |
| :--- | :--- |
| `⌘/Ctrl + K` | 命令面板（[`CommandPalette.svelte`](../web/src/lib/components/CommandPalette.svelte)，命令表 `lib/commands.ts`，文案 `t.palette.*`） |
| `⌘/Ctrl + ,` | 设置 |
| `?` | 设置的「快捷键」页 |
| `/` | 聚焦搜索框 |
| `Enter` | 立即搜索；焦点在列表时打开预览 |
| `↑ ↓` / `j k` | 上一条 / 下一条命中 |
| `[` `]` | 预览中上一个 / 下一个文件 |
| `Tab` | 在搜索框与列表之间切换焦点 |
| `Esc` | 逐层返回：命令面板 → 设置 → 详情（窄屏）→ 取消搜索 → 清空 → 失焦 |
| `Alt + C / W / R` | 在光标处插入 `$c()` / `$w()` / `$r()` |
| `⌘/Ctrl + C`（无选区、列表焦点） | 复制当前命中行 |

规则：
1. `Alt + 字母` 必须用 `e.code`（`KeyC` 等）判断，macOS 下 `e.key` 会变成特殊字符；且仅在未按 `meta/ctrl` 时生效。
2. 不占用浏览器保留键（如 `⌘D` 加书签）。新增入口优先放进命令面板，而不是新增全局快捷键。
3. `Alt + C/W/R` 与符号工具条通过 `workbench.insertToken`（由 `SearchBar` 注册）插入 token，**禁止实现为全局切换**。
4. 新增、修改快捷键必须同步更新 `i18n.ts` 的 `shortcuts.items`（带 `group: 'syntax' | 'nav' | 'panel'`），设置的「快捷键」页会据此分组渲染。

## 十、移动端与触控规范

### 10.1 布局断点
- `workbench.isCompact`：由 `App.svelte` 监听 `matchMedia('(max-width: 767px)')` 设置，**唯一**的窄屏判据；组件不得各自读取 `window.innerWidth`。
- `workbench.isTouch`：全局 `pointerdown`（capture）记录最近一次输入是否为手指，用于触摸笔记本等**鼠标与触屏混用**设备的运行时切换（长按菜单、禁用行内选区、划词气泡）。
- 触控命中区放大使用 `any-pointer: coarse`（只要有触屏就放大，视觉大小不变），不要用 `pointer: coarse`（触摸笔记本主指针是鼠标，不会命中）。

### 10.2 栈式导航（窄屏）
- 列表与详情互斥：点击行进入全屏详情（`workbench.detailOpen`，`.detail-enter` 从右滑入），返回按钮、`Esc`、系统返回键、**左边缘右滑**均可回到列表。
- 打开详情时 `history.pushState({ detail: true })`，`popstate` 关闭详情；`App.svelte` 的 `$effect` 负责保持两者同步，不得在别处直接操作 history。
- 桌面端保持左右分栏，分隔条使用 Pointer Events，命中区向两侧扩展（触屏更宽）。

### 10.3 符号工具条（[`SymbolBar.svelte`](../web/src/lib/components/SymbolBar.svelte)）
- 仅在 `isCompact && 搜索框聚焦` 时显示，用 `visualViewport` 的 `resize/scroll` 计算 `bottom` 贴住软键盘。
- 按钮：`$r` `$c` `$w`（每次点击**插入**新的 `$x()`，可叠加）、`@`、`-`、`"`、退格（回退一个 token）。
- 按钮必须 `onmousedown` / `onpointerdown` 里 `preventDefault()`，**不得抢走输入框焦点**。

### 10.4 手势与面板
- 长按结果行（480ms）弹出底部操作面板：复制、限定 `@源`、排除 `-@源`；移动超过 8px 取消。
- 结果列表在 `scrollTop === 0` 时下拉可重新搜索（`touchstart/move/end`，带 `RefreshCw` 指示）；列表使用 `overscroll-contain`。
- 设置与命令面板在窄屏均为底部抽屉/顶部全宽；设置抽屉顶部有拖拽把手，下拉超过 96px 关闭。

### 10.5 视口与触控细节
- 根容器使用 `h-app`（`100vh` → `100dvh`），顶/底使用 `pt-safe` / `pb-safe`（`env(safe-area-inset-*)`），`index.html` 的 viewport 带 `viewport-fit=cover`。
- 全局 `touch-action: manipulation` 去除点击延迟；`hover:` 样式经 Tailwind `hoverOnlyWhenSupported` 仅在支持 hover 的设备生效；`.hover-only` 在 `hover: none` 时恒显。
- `.touch-target`：用伪元素把命中区扩展到 44×44，不改变视觉尺寸；所有图标按钮、开关、步进器、胶囊、列表行、补全项都应使用。

## 十一、设置与数据源面板规范

- [`SettingsPopover.svelte`](../web/src/lib/components/SettingsPopover.svelte) 只是外壳（遮罩、图标标签栏、标题栏、拖拽把手）；内容在 `components/settings/`：`GeneralPane`、`SourcesPane`（含 `AddSourceForm`）、`ShortcutsPane`。标签页固定为三个：通用、数据源、快捷键。
- 设置项统一使用 [`ui/SettingRow`](../web/src/lib/components/ui/SettingRow.svelte)（图标 + 短标签 + 控件，说明放 `hint`）；二选/多选用 [`ui/Segmented`](../web/src/lib/components/ui/Segmented.svelte)（图标或短文字）；开关用 `ui/Switch`，数值用 `ui/NumberStepper`。**不要**在面板里手写分段按钮样式。
- 会重新搜索的设置（最大结果数、上下文行数）走“保存 + `scheduleSearch(true)`”；仅影响显示的设置只保存。
- 数据源：
  - 添加表单内联在数据源页（`workbench.sourceAddOpen`），`openSettings('add-source')` 仅作为“打开数据源页并展开表单”的别名，不是独立标签页。
  - 行结构：类型图标（缺失路径变状态色警告）、名称、路径、启用开关、删除。停用的行整体变淡。
  - 删除为**两步确认**（第一次点击图标变为对勾，2.5 秒内再点才删除），不得改回一键删除。
  - 路径补全的目录项右侧有进入下一级的 `>` 按钮，不依赖键盘 `Tab`。
- 所有文案（含错误提示、占位符）走 `t.settings.*` / `t.ui.*`，禁止在组件里写死中英文。
