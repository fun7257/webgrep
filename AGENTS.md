# AGENTS.md — WebGrep AI Agent 开发入口与规范索引

本文档是 AI Agent 在 `webgrep` 仓库中进行开发的**总入口**。任何后端引擎、API 或前端 UI、交互、状态层修改，**必须首先阅读并严格遵守对应的权威开发规范文档**。

---

## 一、核心规范文档索引（必读）

- 📗 **[后端引擎与 `libwebgrep v0.5.0` 原生能力权威规范 (`docs/LIBWEBGREP_GUIDE.md`)](docs/LIBWEBGREP_GUIDE.md)**（**后端/引擎修改必读**）
  - **搜索入口选型矩阵与 `EngineLimits` 预算铁律**：`searchSourceSlice` / `resumeSourceSlice`、`searchSource` / `resumeSource`、`searcher.searchFile` + `SearchConfig.optimalBufferSize` + `Scratch`、`searchArchiveSlice` / `searchArchive` / `searchTree`、`openSourcePull` / `openReaderPull`。**特别警示**：`serviceConfig` 在预算字段为 `null` 时默认限制为 `16 MiB`，`webgrep` 全量强一致搜索必须显式传入非 `null` 的 `EngineLimits` 覆盖默认值！
  - **流式控制与二阶段注水调度（Pause / Resume）**：`Event` 流模型、`Flow`（`.cont` / `.pause` / `.stop`）、`Result.resume_state` + `Continuation` 精确断点续扫（含转码文件 `raw_resume_at` 尾部续转），以及针对超大文件的三大铁律（`> 256 MiB` 二阶段隔离调度并关闭 `soft_quota`、严禁对 `> 512 MiB` 文件 `mmap` 防 8GB macOS 页表抖动、`1 -> 32 -> 128 -> 512` 自适应流式批次爬坡）。
  - **无锁只读匹配器体系与结构化编译诊断**：`*const Finder`（SIMD 子串 + 智能大小写 + BMP `unicode_case`）、`*const Multi`（4 级自适应 Teddy SIMD / Aho-Corasick + `initFromText`）、`*const Regex`（Lazy DFA + 锁步 Thompson NFA + PikeVM + `RegexScratch` 线程私有复用 + `Regex.initDiagnostic` / `CompileDiagnostic` 结构化行列诊断）、`*const RegexSet`、`AnyMatcher`。强制跨工作线程共享 `*const` 只读指针，严禁按值浅拷贝匹配器。
  - **零落盘多文件归档直搜与流式编解码**：`Compression`（`.gz`/`.zst`/`.xz` 透明流式解压与解压炸弹防护 `max_decompressed_bytes` / `max_compression_ratio`）、`Encoding`（BOM 嗅探、`charset` 提示、UTF-16LE/BE、GBK/GB18030、Latin-1 转码及 `OffsetMap` 精确映射回 `raw_offset`）、`ArchiveTree` / `ArchiveFormat` / `ArchiveOptions`（`.tar`、`.tar.gz`/`.tgz`、`.tar.zst`/`.tzst`、`.tar.xz`/`.txz`、`.zip` 内存直搜、Zip-Slip 拦截与虚拟路径 `archive::entry` 上下文预览）。
  - **原生目录遍历与过滤子模块**：`walk_glob`（`expandBraces`、`compileGlobs`、`matchGlobs`）、`walk_ignore`（`.gitignore`/`.ignore` 层级作用域解析 `parseLayerInto`）、`walk_types`（内置 67 种语言类型映射 `expandTypesToGlobs` / `matchesWithTable`）、`walk_file_id`（跨平台 `(dev, ino)` 符号链接防环去重）、`walk_list`（`32 KiB` 批量目录读取）、`stop_on_nonmatch` 有序时序短路。
  - **反模式红线清单（Anti-Patterns — 严禁重复造轮子对照表）**：所有严禁在 `src/` 手写的逻辑与 `libwebgrep v0.5.0` 标准原生替代方案对照表。

- 📘 **[前端开发、120Hz 极致性能与视觉丝滑度规范 (`docs/FRONTEND_GUIDE.md`)](docs/FRONTEND_GUIDE.md)**（**前端/UI 修改必读**）
  - **核心产品理念**：显式回车检索（不做打字实时搜索，按 `Enter` 执行并保留主框文字便于微调、重复按 `Enter` 强制刷新）+ 类 Google 纯净单文本搜索框 + 显式 `Aa`〔区分大小写〕、`ab`〔全词〕、`.*`〔正则〕开关；无隐式智能大小写、`/re/` 或 `in:`/`time:` 内联解析（空格及符号一律作为纯字面量）；点击 `+ 继续筛选` 或 `Shift+Enter` 将当前条件（含 `+`/`-` 同行包含/排除与开关）锁定进条件链 `#1 -> #2 -> #3 ...` 并重置为空白单文本框；独立双胶囊 `ScopeBar` 解耦「数据源选择入口（点击弹出 [`SourcePickerModal.svelte`](web/src/lib/components/SourcePickerModal.svelte)）/ 时间范围」；四级前端缓存与持久化（结构化 `localStorage` 历史 + `sourceRevision`/`tenant` 绑定真短路 L0 步骤 LRU + 16 槽位单行详情 `AbortController` 缓存）；默认严格单行同行收敛（`nearbyLines = 0`）；`ResultList` 提供 1–6 行（默认 3 行）单条记录多行富内容预览，`InspectorPane` 100% 专注当前选中单条记录（`context = 0`，无前后无关邻近行）。
  - **设计语言**：少色（灰阶 + `primary` + `status`）、少字（图标优先、说明进 `title`）、触控友好（窄屏栈式导航、符号工具条、底部抽屉、`.touch-target` 44px）、快捷键用 `e.code`（`Alt+C` / `Alt+W` / `Alt+R` 切换 `Aa` / `ab` / `.*` 开关）、`⌘/Ctrl+K` 命令面板；设置与数据源见指南第八至十一章。
  - **Svelte 5 + TypeScript 7 响应式与内存铁律**：大数据集强制 `$state.raw` + Copy-on-Write、列表循环内细粒度原始值信号隔离、`WeakMap` 零分配高亮缓存、`{#snippet}` 模板复用。
  - **120Hz 渲染管线与零闪烁（Zero-Flicker / Zero-CLS）**：GPU 合成层 `translate3d` + `contain: strict` 零重排虚拟列表、Stale-While-Revalidate 无缝保留旧结果、`60ms` 首屏聚合 + `80ms` VSync 对齐流式节拍、左侧固定视觉锚点与单文件行高单调锁死。
  - **反模式红线清单（Anti-Patterns）**：所有严禁出现的代码写法与标准替代方案对照表。

---

## 二、仓库架构速览

- `web/`：**Svelte 5 (`^5.57.2`) + Vite 8 (`^8.3.5` Rolldown) + TypeScript 7 (`^7.0.2`) + Tailwind CSS 3.4** 前端工作台。
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts)：全局响应式状态、显式 `Aa`/`ab`/`.*` 开关、无限层级递进条件链、严格单行匹配默认（`strictLine = true` / `nearbyLines = 0`）、目录/文件数据源管理与 WebSocket 流式两阶段节拍器。
  - [`web/src/lib/components/SettingsPopover.svelte`](web/src/lib/components/SettingsPopover.svelte)：图标 Tab 设置中心（通用、数据源〔内联添加表单〕、快捷键帮助），子面板位于 `settings/`，通用控件 `ui/SettingRow`、`ui/Segmented`；移动端为可下拉关闭的底部抽屉。
  - [`web/src/lib/components/CommandPalette.svelte`](web/src/lib/components/CommandPalette.svelte)：`⌘/Ctrl + K` 命令面板。
  - [`web/src/lib/components/SymbolBar.svelte`](web/src/lib/components/SymbolBar.svelte)：移动端软键盘上方符号工具条。
  - [`web/src/lib/components/ScopeBar.svelte`](web/src/lib/components/ScopeBar.svelte) & [`web/src/lib/components/SourcePickerModal.svelte`](web/src/lib/components/SourcePickerModal.svelte)：与文本检索解耦的双胶囊范围筛选栏（单一简洁数据源触发胶囊 + 点击弹出大容量可搜分类/单选/多选/排除数据源弹窗与移动端抽屉 + 时间范围预设）。
  - [`web/src/lib/components/SearchBar.svelte`](web/src/lib/components/SearchBar.svelte)：显式回车触发的类 Google 纯净单文本搜索框、`Aa`/`ab`/`.*` 开关、`+ 继续筛选` 按钮、下方无限层级同行收敛条件链与移动端符号工具条入口。
  - [`web/src/lib/components/TelemetryBar.svelte`](web/src/lib/components/TelemetryBar.svelte)：零 CLS 遥测状态栏与状态胶囊。
  - [`web/src/lib/components/ResultList.svelte`](web/src/lib/components/ResultList.svelte)：120Hz GPU 合成层零重排虚拟列表（单条记录 1–6 行多行富内容折行预览，默认 3 行）。
  - [`web/src/lib/components/InspectorPane.svelte`](web/src/lib/components/InspectorPane.svelte)：右侧单条记录完整预览面板（100% 专注当前选中记录，无前后无关邻近行；未截断记录 0ms 即时渲染，超长记录按 `context=0` 拉取完整单条正文，支持 JSON/KV/HTML/STRUCT 结构化与原文视图）与划词追加/排除筛选气泡（支持普通文件、单文件压缩流及 `archive::entry` 归档内部条目预览）。
  - [`web/src/lib/utils.ts`](web/src/lib/utils.ts)：`WeakMap` 高亮分段缓存（`getCachedHighlightSegments`）与路径解析缓存（`splitFilePath`，原生识别 `archive.tar.gz::inner/path` 虚拟路径层次）。
- `src/`：**Zig 后端 HTTP / WebSocket 检索服务**，通过 [`build.zig.zon`](build.zig.zon) 接入 `libwebgrep v0.5.0` 搜索引擎。
  - [`src/search_job.zig`](src/search_job.zig)：多线程并行检索引擎与 WebSocket 流式推送调度器。集成 `libwebgrep` 无锁只读 `*const` 匹配器（`Finder` / `Multi` / `Regex`）、`Regex.initDiagnostic`（`CompileDiagnostic` 结构化行列诊断）、代价导向锚点重排、显式 `EngineLimits` 全量配额、`searchArchiveSlice` / `searchArchive` 零落盘多文件归档直搜、二阶段弹性注水调度（`<= 256 MiB` Stage 1 软配额 + `resumeSourceSlice` 断点续扫，`> 256 MiB` Stage 2 无软配额线性扫描）、`> 512 MiB` 巨型文件免 `mmap` 流式 `searcher.searchFile` + `optimalBufferSize` + `Scratch`，以及 `walk_glob` / `walk_types` / `stop_on_nonmatch` 过滤加速。
  - [`src/file_api.zig`](src/file_api.zig)：文件树安全枚举、路径消毒、多文件归档与单流压缩识别（`detectArchiveFormat` / `detectCompression`）、归档虚拟路径协议（`ARCHIVE_VIRTUAL_SEP = "::"`、`splitArchiveVirtualPath`、`formatArchiveVirtualPathAlloc`）、`/api/file` 与 `/api/context` 上下文窗口构建（支持物理文件、`.gz`/`.zst`/`.xz` 透明解压、BOM/UTF-16/GB18030/Latin-1 转码及 `ArchiveTree` 归档条目内存直读预览）。
  - [`src/search_cache.zig`](src/search_cache.zig)：并发安全的两级缓存系统——`DirInventory` 目录文件清单缓存（集成 `walk_ignore.parseLayerInto`、`(dev, ino)` `walk_file_id` 防环去重与 `walk_list.Lister` 批量读取）与 `HotFileCache` 热文件只读 `mmap` 缓存（严格限制单文件 `<= MAX_HOT_FILE_MAP_BYTES` 即 `512 MiB`）。
  - [`src/docker_logs.zig`](src/docker_logs.zig)：零落盘 Docker 容器日志适配器。自动发现 `$DOCKER_HOST`、Docker Desktop / OrbStack / Colima / Podman Unix 套接字、TCP 与 `/var/lib/docker/containers`（`config.v2.json` + 轮转 `*-json.log[.N[.gz]]`），通过 `DockerLogReader` 解码 HTTP `chunked` 与 8 字节多路复用流头并直连 `libwebgrep.searchSource` 及 `/api/file` 内存预览。
  - [`src/source_registry.zig`](src/source_registry.zig)：多数据源注册中心（`dir` 本地目录、`file` 单文件/归档与 `docker` 零落盘容器数据源）、UUID v4 持久化、文件访问热度追踪（`file_heat`）与基于 `walk_list.Lister` / Docker 守护进程的服务端自动补全。
  - [`src/server.zig`](src/server.zig)：HTTP / WebSocket 路由分发、静态资源服务与查询生命周期管理。

---

## 三、修改后强制校验指令

每次完成代码修改后，Agent 必须执行以下构建与测试校验，确保零警告、零报错：

1. **前端单元测试、TypeScript 7 类型检查与生产构建**：
   ```bash
   npm --prefix web run test && npm --prefix web run check && npm --prefix web run build
   ```
2. **Zig 后端与 `libwebgrep` 联调构建及测试**：
   ```bash
   zig build && zig build test
   ```

---

## 四、AI Agent 标准开发流程（固化工作流）

任何 AI Agent 在处理 `webgrep` 的新需求、性能优化或缺陷修复时，**必须严格执行以下五步闭环工作流**，禁止跳步：

### 第一步：规范先行与原生能力核查（Spec-First & Native Capability Audit）
- 修改后端/引擎代码前，**必读 [`docs/LIBWEBGREP_GUIDE.md`](docs/LIBWEBGREP_GUIDE.md)**；修改前端/UI/状态层代码前，**必读 [`docs/FRONTEND_GUIDE.md`](docs/FRONTEND_GUIDE.md)**。
- 先在 [`docs/LIBWEBGREP_GUIDE.md` 第七章符号速查索引](docs/LIBWEBGREP_GUIDE.md#七libwebgrep-v050-全量导出符号速查索引) 中核查目标能力是否已由 `libwebgrep v0.5.0` 原生提供（如流式解压、多字符集转码、`.tar.*`/`.zip` 归档解包、Glob 花括号展开、`.gitignore` 层级解析、67 种语言类型映射、`CompileDiagnostic` 诊断、`ResumeState` 续扫等）。
- **严禁在 `webgrep/src/` 下手写任何 `libwebgrep` 已原生实现的编解码、归档、匹配或目录过滤逻辑**。

### 第二步：边界设计与性能预算评估（Boundary Design & Performance Budgeting）
- **后端内存与 IO 预算**：
  - 调用 `searchSourceSlice` / `resumeSourceSlice` / `searchSource` / `searchArchiveSlice` 时，必须显式配置非 `null` 的 `EngineLimits`（防止触发 `serviceConfig` 默认 `16 MiB` 截断）；
  - 明确大文件分级边界：`> 256 MiB` 必须进入 Stage 2（`colossal_indices`）且关闭软配额；`> 512 MiB` 严禁 `mmap`，必须走 `searcher.searchFile` + `optimalBufferSize` + `Scratch`。
- **前端 120Hz 与零 CLS 预算**：
  - 大数据集一律使用 `$state.raw` + Copy-on-Write，虚拟列表严守 `contain: strict` + `translate3d` 固定行高与 Stale-While-Revalidate 零闪烁过渡。
- **多 Agent 协同隔离（`/swarm`）**：
  - 当任务横跨多个独立子系统（如归档预览、检索引擎、前端交互、文档规范）时，优先使用 `/swarm` 拆分为职责正交的 Worker Agent，并在 Brief 中**严格划定每个 Agent 独占的文件所有权边界**，严禁两个 Agent 同时编辑同一文件，由独立的 `@verifier` 统一执行构建与端到端实测。

### 第三步：零分配/零拷贝实现与单测覆盖（Zero-Alloc Implementation & Unit Tests）
- 跨工作线程一律通过 `*const` 只读指针共享 `Finder` / `Multi` / `Regex` 匹配器，线程可变状态全部收归线程私有的 `Scratch` / `RegexScratch`。
- 归档搜索与上下文预览全程在内存中基于 `searchArchiveSlice` / `ArchiveTree` 与 `::` 虚拟路径完成，零临时文件落盘。
- 每新增或修改一项核心能力（如归档虚拟路径拆分、多字符集预览、正则编译诊断、阶段调度），必须在对应模块内同步编写覆盖正常路径与边界异常（如 Zip-Slip `..` 路径穿越、非法正则、超长行）的单元测试。

### 第四步：强制全量构建与静态检查（Mandatory Build & Static Check）
- 依次运行第三节中的前后端双线校验指令：
  1. `npm --prefix web run test && npm --prefix web run check && npm --prefix web run build`
  2. `zig build && zig build test`
- 任何编译错误、类型检查告警或单测失败必须当场清零，严禁带病提交。

### 第五步：真实数据集端到端基准回归（Real-Dataset E2E Benchmark Regression）
- 涉及检索引擎、流式管线、归档直搜或上下文预览的改动，必须在真实数据集上完成端到端回归验证：
  - **常规与多条件检索**：验证首屏命中延迟（TTFR `< 20ms`）与全量计数强一致性；
  - **10GB+ 巨型日志（如 `10000w.log`）**：验证免 `mmap` 流式扫描吞吐、内存平稳度（无页表抖动）与 `totalMatches` 准确性；
  - **多文件归档（如 `.tar.gz` / `.zip`）**：验证零落盘归档直搜返回的 `archive::entry` 虚拟路径可直接通过 `/api/context` 正常渲染上下文代码预览。
