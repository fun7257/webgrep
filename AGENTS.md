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
  - **核心产品理念**：显式回车检索（不做打字实时搜索，按 `Enter` 执行并保留主框文字便于微调、重复按 `Enter` 强制刷新）+ 类 Google 纯净单文本搜索框 + 放大镜紧邻右侧双内嵌范围选择器（默认 `全部` 的 [`SourcePickerPopover.svelte`](web/src/lib/components/SourcePickerPopover.svelte) 数据源模糊搜索列表勾选器，以及默认 `不限` 的 [`TimeRangePicker.svelte`](web/src/lib/components/TimeRangePicker.svelte) 同源快捷/自定义时间面板——去除下方多余范围行）+ 显式 `Aa`〔区分大小写〕、`ab`〔全词〕、`.*`〔正则〕开关；无隐式智能大小写、`/re/` 或 `in:`/`time:` 内联解析（空格及符号一律作为纯字面量）；点击 `+ 继续筛选` 或 `Shift+Enter` 将当前条件（含 `+`/`-` 同行包含/排除与开关）锁定进条件链 `#1 -> #2 -> #3 ...` 并重置为空白单文本框；四级前端缓存与持久化（结构化 `localStorage` 历史 + `sourceRevision`/`tenant` 绑定真短路 L0 步骤 LRU + 16 槽位单行详情 `AbortController` 缓存）；默认严格单行同行收敛（`nearbyLines = 0`）；`ResultList` 提供 1–6 行（默认 3 行）单条记录多行富内容预览，`InspectorPane` 100% 专注当前选中单条记录（`context = 0`），需看相邻上下文时通过顶栏上下文图标按钮复用 [`RightDrawer.svelte`](web/src/lib/components/RightDrawer.svelte) + [`ContextDrawerPane.svelte`](web/src/lib/components/ContextDrawerPane.svelte) 按需加载（默认上下各 `10` 行、滑到顶/底边缘带可调速冷却自动增量加载 `10` 行、初始行数/每次条数/自动加载调速均可在设置中配置，普通文件走 `O(window)` `pread` + `firstByte`/`nextByte` 游标直读）；顶栏 `<Header />` 右侧提供四个独立一级图标菜单（「数据源」、「MCP 服务」、「快捷键说明」、「设置」），各自复用同一右侧滑出抽屉模板 [`RightDrawer.svelte`](web/src/lib/components/RightDrawer.svelte) + [`DrawerTemplate.svelte`](web/src/lib/components/ui/DrawerTemplate.svelte) 且互不切换。
  - **设计语言**：少色（灰阶 + `primary` + `status`）、少字（图标优先、说明进 `title`）、触控友好（窄屏栈式导航、符号工具条、底部抽屉、`.touch-target` 44px）、快捷键用 `e.code`（`Alt+C` / `Alt+W` / `Alt+R` 切换 `Aa` / `ab` / `.*` 开关）、`⌘/Ctrl+K` 命令面板；设置与数据源见指南第八至十一章。
  - **Svelte 5 + TypeScript 7 响应式与内存铁律**：大数据集强制 `$state.raw` + Copy-on-Write、列表循环内细粒度原始值信号隔离、`WeakMap` 零分配高亮缓存、`{#snippet}` 模板复用。
  - **120Hz 渲染管线与零闪烁（Zero-Flicker / Zero-CLS）**：GPU 合成层 `translate3d` + `contain: strict` 零重排虚拟列表、Stale-While-Revalidate 无缝保留旧结果、`60ms` 首屏聚合 + `80ms` VSync 对齐流式节拍、左侧固定视觉锚点与单文件行高单调锁死。
  - **反模式红线清单（Anti-Patterns）**：所有严禁出现的代码写法与标准替代方案对照表。

---

## 二、仓库架构速览

- `web/`：**Svelte 5 (`^5.57.2`) + Vite 8 (`^8.3.5` Rolldown) + TypeScript 7 (`^7.0.2`) + Tailwind CSS 3.4** 前端工作台（采用正交模块化布局，详见 [`docs/FRONTEND_GUIDE.md` 第十二章](docs/FRONTEND_GUIDE.md#十二模块化架构与人机协作human-ai-collaboration规范)）。
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts) & `web/src/lib/state/*`：Svelte 5 Runes 全局响应式协调层（直接持有 `$state.raw` 热路径与 VSync 两阶段节拍器），下沉纯模块化子域 [`state/persistence.ts`](web/src/lib/state/persistence.ts)、[`state/api-client.ts`](web/src/lib/state/api-client.ts)、[`state/stream-buffer.ts`](web/src/lib/state/stream-buffer.ts)（Copy-on-Write 合并与 16 槽位上下文 LRU）、[`state/query-actions.ts`](web/src/lib/state/query-actions.ts) 与 [`state/ws-transport.ts`](web/src/lib/state/ws-transport.ts)。
  - [`web/src/lib/components/RightDrawer.svelte`](web/src/lib/components/RightDrawer.svelte) & [`web/src/lib/components/SettingsPopover.svelte`](web/src/lib/components/SettingsPopover.svelte)：统一右侧滑出工作区抽屉外壳（桌面端贴靠顶栏 `<Header />` 下方自右滑入、透明无模糊背景遮罩保留左侧结果清晰可见、`bg-background` 主画布与 `bg-card/55` Layer-1 色调分组及单色键帽 `Segmented` 控件；移动端为可下拉关闭底部抽屉），一方面专注承载顶栏四个彼此严格独立的一级菜单抽屉内容页（数据源管理〔含内联添加表单〕、MCP 服务〔`settings/McpPane.svelte`，含状态开关、能力列表与默认 20 条可配实时调用日志〕、快捷键说明、通用设置），另一方面被 [`ContextDrawerPane.svelte`](web/src/lib/components/ContextDrawerPane.svelte) 复用承载按需滑出的上下相邻记录增量查看面板，通过 [`ui/DrawerTemplate.svelte`](web/src/lib/components/ui/DrawerTemplate.svelte) 统一页眉与页脚样板，设置子面板位于 `settings/`，通用控件 `ui/SettingRow`、`ui/Segmented`、`ui/NumberStepper`。
  - [`web/src/lib/components/ContextDrawerPane.svelte`](web/src/lib/components/ContextDrawerPane.svelte) & [`web/src/lib/context-window.ts`](web/src/lib/context-window.ts)：复用右侧滑出抽屉的按需上下文记录加载面板（支持以目标行居中高亮展开、常见代码/日志/JSON/YAML/TOML/SQL 语法与语义高亮及顶栏结构化展开切换、滑到顶部/底部边缘按可配冷却节奏自动增量加载上文/下文并保持上翻零跳动锚定，初始行数 `10`、每次条数 `10` 及自动加载调速（慢 `480ms` / 标准 `240ms` / 快 `90ms`）均可在通用设置配置，普通文件利用命中 `byteOffset` 与响应 `firstByte`/`nextByte` 游标实现 `O(window)` 秒开，同时支持单流压缩与 `archive::entry` 虚拟路径）。
  - [`web/src/lib/components/CommandPalette.svelte`](web/src/lib/components/CommandPalette.svelte)：`⌘/Ctrl + K` 命令面板。
  - [`web/src/lib/components/SymbolBar.svelte`](web/src/lib/components/SymbolBar.svelte)：移动端软键盘上方符号工具条。
  - [`web/src/lib/components/SourcePickerPopover.svelte`](web/src/lib/components/SourcePickerPopover.svelte)、[`web/src/lib/components/TimeRangePicker.svelte`](web/src/lib/components/TimeRangePicker.svelte) & `components/pickers/*`：与文本内容正交的数据源与时间范围控制，共享 [`pickers/FloatingPopoverShell.svelte`](web/src/lib/components/pickers/FloatingPopoverShell.svelte) 浮层/底部面板外壳与 [`pickers/DateTimeRangeSlots.svelte`](web/src/lib/components/pickers/DateTimeRangeSlots.svelte) 分段式日期时间槽位控件；时间解析纯逻辑拆分于 `lib/time-range/`（`presets.ts`、`paste-parser.ts`、`slots.ts`、`quick-candidates.ts`）并经 [`web/src/lib/time-range.ts`](web/src/lib/time-range.ts) 门面转发。
  - [`web/src/lib/components/SearchBar.svelte`](web/src/lib/components/SearchBar.svelte) & `components/search/*`：放大镜紧邻右侧双内嵌数据源与时间范围选择器（[`search/SearchScopeTriggers.svelte`](web/src/lib/components/search/SearchScopeTriggers.svelte)）+ 显式回车触发的类 Google 纯净单文本搜索框、`Aa`/`ab`/`.*` 开关、`+ 继续筛选` 按钮、附着式建议下拉（[`search/SearchAttachedDropdown.svelte`](web/src/lib/components/search/SearchAttachedDropdown.svelte)）与下方无限层级同行收敛条件链（[`search/ConditionChainBar.svelte`](web/src/lib/components/search/ConditionChainBar.svelte)）。
  - [`web/src/lib/components/TelemetryBar.svelte`](web/src/lib/components/TelemetryBar.svelte)：零 CLS 遥测状态栏与状态胶囊（含 `filesPruned > 0` 预过滤剪枝、节省字节指标及 `auto`/`log`/`plain` 视图切换）。
  - [`web/src/lib/components/settings/SourcePrefilterEditor.svelte`](web/src/lib/components/settings/SourcePrefilterEditor.svelte)、[`web/src/lib/components/settings/SourceTimeFormatEditor.svelte`](web/src/lib/components/settings/SourceTimeFormatEditor.svelte) & [`web/src/lib/prefilter.ts`](web/src/lib/prefilter.ts)：统一的数据源模式切换（`auto` / `timeseries` / `code` / `raw`）、内联时间戳格式确认与示例验证（不在搜索栏或界面中区分“内容时间/行时间”）、可折叠插件微调与 `sourcePluginsSig` 缓存签名隔离。
  - [`web/src/lib/adapters/`](web/src/lib/adapters/index.ts) & [`components/adapters/*`](web/src/lib/components/adapters/registry.ts)：工作台级展示适配体系（无头纯 TS 内核 `HeadlessAdapter` / `probeLogLineFast` 含 `dateKey` / `parseLogLine` / `CodeStreamStatsTracker` / `LogStreamStatsTracker` + Svelte 5 `PresentationAdapter` 查表注册表，彻底零分支分发 `log` 对齐事件流、`code` 按文件分组高亮与 ±12 行代码详情、`plain` 原文流，共享 `VirtualScrollShell` 与 `AdapterHost` 命令总线）。
  - [`web/src/lib/components/ResultList.svelte`](web/src/lib/components/ResultList.svelte)：120Hz GPU 合成层零重排虚拟列表（消费 `lib/adapters/*`，日志/原文混合行高动态适配）。
  - [`web/src/lib/components/InspectorPane.svelte`](web/src/lib/components/InspectorPane.svelte) & `components/inspector/*`：右侧单条记录完整预览面板（100% 专注当前选中记录，未截断记录 0ms 即时渲染，超长记录按 `context=0` 拉取完整单条正文，支持 JSON/KV/HTML/STRUCT 结构化与原文视图，并通过顶栏上下文图标按钮按需滑出 [`ContextDrawerPane.svelte`](web/src/lib/components/ContextDrawerPane.svelte) 查看上下相邻记录）与划词追加/排除筛选气泡（支持普通文件、单文件压缩流及 `archive::entry` 归档内部条目预览）；拆分为顶栏 [`inspector/InspectorHeader.svelte`](web/src/lib/components/inspector/InspectorHeader.svelte) 与结构化视图 [`inspector/StructuredRecordView.svelte`](web/src/lib/components/inspector/StructuredRecordView.svelte)（高频片段保留 `{#snippet}` 内联编译）。
  - [`web/src/lib/utils.ts`](web/src/lib/utils.ts) & [`web/src/lib/i18n.ts`](web/src/lib/i18n.ts)（零开销门面）：分别收敛 [`format.ts`](web/src/lib/format.ts)（路径解析 `splitFilePath` 缓存）、[`highlight/segments.ts`](web/src/lib/highlight/segments.ts)（`WeakMap` 高亮分词 `getCachedHighlightSegments`）、[`highlight/syntax.ts`](web/src/lib/highlight/syntax.ts)、[`structured/analyzer.ts`](web/src/lib/structured/analyzer.ts) 以及双语字典 [`i18n/zh.ts`](web/src/lib/i18n/zh.ts) / [`i18n/en.ts`](web/src/lib/i18n/en.ts)。
- `src/`：**Zig 后端 HTTP / WebSocket 检索服务**，通过 [`build.zig.zon`](build.zig.zon) 接入 `libwebgrep v0.5.0` 搜索引擎。
  - [`src/auth.zig`](src/auth.zig)：部署期无用户名单密码鉴权与 MCP Token 校验模块。支持通过 `WEBGREP_PASSWORD` / `--password` 启用 Web 会话保护（`SHA-256` 常量时间比对 + 30 天无状态 `HMAC-SHA256` `HttpOnly` Cookie `webgrep_session`、`/api/auth/status|login|logout` 与 `/api/*` + `/api/ws` 鉴权拦截），以及通过 `WEBGREP_MCP_TOKEN` / `--mcp-token` 保护 `/mcp`（`Authorization: Bearer` / `X-MCP-Token`、`--mcp` stdio 自动透传）。
  - [`src/main.zig`](src/main.zig) & [`src/net_bind.zig`](src/net_bind.zig)：服务启动入口与多监听器网络绑定。默认绑定 `--host 127.0.0.1,tailscale`（即同时监听本机回环 `127.0.0.1` 与活跃的 Tailscale `100.64.0.0/10` / `fd7a:115c:a1e0::/48` 接口，且后台每 `2s` 自动热绑定后续连上的 Tailscale 接口），**默认不暴露 `0.0.0.0` 或局域网接口**。
  - [`src/search_job.zig`](src/search_job.zig)：多线程并行检索引擎与 WebSocket 流式推送调度器。集成 `libwebgrep` 无锁只读 `*const` 匹配器（`Finder` / `Multi` / `Regex`）、`Regex.initDiagnostic`（`CompileDiagnostic` 结构化行列诊断）、代价导向锚点重排、显式 `EngineLimits` 全量配额、`searchArchiveSlice` / `searchArchive` 零落盘多文件归档直搜、二阶段弹性注水调度（`<= 256 MiB` Stage 1 软配额 + `resumeSourceSlice` 断点续扫，`> 256 MiB` Stage 2 无软配额线性扫描）、`> 512 MiB` 巨型文件免 `mmap` 流式 `searcher.searchFile` + `optimalBufferSize` + `Scratch`，以及 `walk_glob` / `walk_types` / `stop_on_nonmatch` 过滤加速。
  - [`src/file_api.zig`](src/file_api.zig)：文件树安全枚举、路径消毒、多文件归档与单流压缩识别（`detectArchiveFormat` / `detectCompression`）、归档虚拟路径协议（`ARCHIVE_VIRTUAL_SEP = "::"`、`splitArchiveVirtualPath`、`formatArchiveVirtualPathAlloc`）、`/api/file` 与 `/api/context` 上下文窗口构建（支持物理文件、`.gz`/`.zst`/`.xz` 透明解压、BOM/UTF-16/GB18030/Latin-1 转码及 `ArchiveTree` 归档条目内存直读预览）。
  - [`src/search_cache.zig`](src/search_cache.zig)：并发安全的两级缓存系统——`DirInventory` 目录文件清单缓存（集成 `walk_ignore.parseLayerInto`、`(dev, ino)` `walk_file_id` 防环去重与 `walk_list.Lister` 批量读取）与 `HotFileCache` 热文件只读 `mmap` 缓存（严格限制单文件 `<= MAX_HOT_FILE_MAP_BYTES` 即 `512 MiB`）。
  - [`src/docker_logs.zig`](src/docker_logs.zig)：零落盘 Docker 容器日志适配器。自动发现 `$DOCKER_HOST`、Docker Desktop / OrbStack / Colima / Podman Unix 套接字、TCP 与 `/var/lib/docker/containers`（`config.v2.json` + 轮转 `*-json.log[.N[.gz]]`），通过 `DockerLogReader` 解码 HTTP `chunked` 与 8 字节多路复用流头并直连 `libwebgrep.searchSource` 及 `/api/file` 内存预览。
  - [`src/source_registry.zig`](src/source_registry.zig)：多数据源注册中心（`dir` 本地目录、`file` 单文件/归档与 `docker` 零落盘容器数据源）、UUID v4 持久化、文件访问热度追踪（`file_heat`）与基于 `walk_list.Lister` / Docker 守护进程的服务端自动补全。
  - [`src/mcp.zig`](src/mcp.zig)：原生 Model Context Protocol (MCP) JSON-RPC 2.0 查询服务（支持 Streamable HTTP `/mcp` 与 `--mcp` stdio 桥接），对外 AI Agent 暴露 `webgrep_search`、`webgrep_get_context`、`webgrep_list_sources`、`webgrep_status` 四项能力，持久化 `<data_dir>/mcp.json` 并通过 `/api/ws` 实时推送可配置容量的最近调用日志（默认 20 条，1–200 可调）。
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

### 本地常驻启动约定（Tailscale + `127.0.0.1`）
- 后续在本地启动 `webgrep` 供本机或 Tailscale 网络访问时，**始终直接运行默认绑定（`127.0.0.1,tailscale`）的 `./zig-out/bin/webgrep`**（默认端口 `:8787`），严禁回退为仅绑定 `127.0.0.1` 或对外暴露 `0.0.0.0` / 局域网网卡（除非用户明确要求）。

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
