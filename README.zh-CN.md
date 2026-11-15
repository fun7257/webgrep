# webgrep

[English](README.md) | [简体中文](README.zh-CN.md)

**`webgrep`** 是一款基于 **Zig 0.17.0**（`std.http.Server` + 全双工 `WebSocket`）、**[`libwebgrep v0.5.0`](https://github.com/fun7257/libwebgrep)** SIMD 搜索引擎核心（24–62 GB/s）与 **Svelte 5 (Runes)** 构建的 120Hz 零闪烁极速文本、日志与代码检索工作台。

---

## 核心工程规范与文档索引

- 🧭 **[AI Agent 开发入口与标准工作流 (`AGENTS.md`)](AGENTS.md)** — 仓库架构总览、强制双线校验指令与 AI Agent 五步闭环开发流程。
- 📗 **[后端引擎与 `libwebgrep v0.5.0` 权威规范 (`docs/LIBWEBGREP_GUIDE.md`)](docs/LIBWEBGREP_GUIDE.md)** — 搜索入口选型矩阵、`EngineLimits` 预算铁律、Pause/Resume 二阶段注水调度、`*const` 无锁匹配器、`archive::entry` 零落盘归档直搜与 `walk_*` 原生子模块手册。
- 📘 **[前端开发与 120Hz 极致性能规范 (`docs/FRONTEND_GUIDE.md`)](docs/FRONTEND_GUIDE.md)** — 零负担渐进式搜索交互、Svelte 5 `$state.raw` 响应式铁律、GPU 合成层虚拟列表与反模式红线清单。

---

## 核心特性

- **24–62 GB/s 原生 SIMD 检索引擎（[`libwebgrep v0.5.0`](https://github.com/fun7257/libwebgrep)）**：
  - **基于代价的选择性查询规划器（Cost-Based Selectivity Planner）**：自动评估查询中所有正向词条（字面量与正则）的选择性得分，选举最具区分度的词条作为主 SIMD 扫描器（`*const Finder`、`*const Multi` 或带 `RequiredLiteral` 预过滤的 `*const Regex`），保证词条顺序无关的恒定极速体验。
  - **最坏 $O(n)$ 线性时间复杂度与结构化正则诊断**：混合 Lazy DFA + 锁步 Thompson NFA / PikeVM 正则引擎，彻底免疫灾难性回溯（ReDoS），并通过 `Regex.initDiagnostic`（`CompileDiagnostic`）提供精确到字节偏移、行列号与错误码的语法诊断。
  - **零落盘多文件归档直搜与流式编解码**：
    - **多文件归档内存直搜与上下文预览**：无需解压临时文件到磁盘，直接在内存中检索 `.tar`、`.tar.gz`/`.tgz`、`.tar.zst`/`.tzst`、`.tar.xz`/`.txz`、`.zip` 归档包（`searchArchiveSlice` / `ArchiveTree`），并通过虚拟路径协议（`archive.tar.gz::inner/path`）在右侧面板实时预览归档内文件的上下文代码与高亮。
    - **进程内防爆流式解压**：无需派生外部子进程，透明流式检索 `.gz`、`.zst`、`.xz` 单文件压缩流，内置 `max_decompressed_bytes` 与 `max_compression_ratio` 解压炸弹双重防护。
    - **多字符集自动嗅探与转码**：自动识别 BOM 并透明转码 UTF-16LE/BE、GBK/GB18030、Latin-1/Windows-1252，同时通过 `OffsetMap` 精确映射回底层原始文件字节偏移 `raw_offset`。
  - **二阶段弹性注水调度与 10GB+ 巨型日志免 `mmap` 流式扫描**：将 `> 256 MiB` 的巨型文件自动隔离至 Stage 2 执行，对 `> 512 MiB` 的超大日志（如 13.87GB `10000w.log`）强制采用 `searcher.searchFile` + L2 缓存对齐 `optimalBufferSize` + 线程私有 `Scratch` 缓冲池流式扫描，彻底杜绝 8GB 内存设备上的页表抖动。
- **零心智负担的渐进式内联搜索语法**：
  - **空格即深搜（`AND`）**：直接输入 `error timeout 502`，空格分隔的每个词条实时对命中行做交集过滤，并以多色高亮区分。
  - **内联排除（`-word`）与精确短语（`"..."`）**：任意词条前加 `-`（如 `-healthcheck`）即可实时剔除包含该词的行；用双引号包裹即可匹配完整短语。
  - **统一范围限定（`in:`）与时间过滤（`time:`）**：支持按数据源、语言类型（内置 `walk_types` 67 种语言映射，如 `in:zig`、`in:ts`）或路径通配（`in:src/`）限定范围，以及按时间戳范围过滤日志（`time:today`、`time:2026-11-12`）。
  - **正则表达式（`/pattern/`）与局部 `$` 修饰符**：支持直写 `/pattern/` 正则或局部作用域 `$r(...)`、`$c(...)`、`$w(...)` 修饰符。
- **多类型数据源管理（目录模式 + 单文件/归档模式）**：
  - 支持挂载 **本地目录（`dir`）** 或 **单文件/归档包（`file`）**，基于 `walk_list.Lister` 提供极速服务端路径实时补全，创建时自动分配并持久化 RFC 4122 UUID v4。
- **120Hz 零闪烁流式渲染管线**：
  - 全双工 WebSocket 自适应批次流式传输（`1 -> 32 -> 128 -> 512` 阶梯爬坡），结合 `Stale-While-Revalidate` 无缝过渡、GPU 合成层零重排虚拟列表（`translate3d` + `contain: strict`）与 `WeakMap` 零分配高亮缓存。

---

## 快速上手

### 环境要求

- **Zig `0.17.0`**
- **Node.js `20+`** 与 **npm**

### 1. 构建前端静态资源

```bash
npm --prefix web install
npm --prefix web run build
```

### 2. 编译并启动 Zig 服务端

```bash
# 编译并运行后端单元测试（链接 libwebgrep v0.5.0 引擎）
zig build && zig build test

# 启动 webgrep 服务（默认监听 http://127.0.0.1:8787）
./zig-out/bin/webgrep --port 8787
```

浏览器打开 **http://127.0.0.1:8787**，点击右上角设置图标进入数据源管理，即可添加目录、单文件/归档包或 **Docker 容器**（零落盘自动发现全部容器日志）开始极速检索。

### 3. 前端热更新开发模式（可选）

保持 `./zig-out/bin/webgrep` 在 `:8787` 运行，另开终端启动 Vite 开发服务器：

```bash
npm --prefix web run dev
```

---

## 仓库目录结构

- [`src/`](src/) — **Zig 0.17.0 HTTP & WebSocket 后端服务**
  - [`src/main.zig`](src/main.zig)：命令行参数解析与服务启动入口。
  - [`src/server.zig`](src/server.zig)：HTTP 接口（`/api/meta`、`/api/sources`、`/api/sources/complete`、`/api/file`、`/api/context`）与 WebSocket 全双工检索通道（`/api/ws`）。
  - [`src/search_job.zig`](src/search_job.zig)：多线程并发检索调度器、代价导向选择性规划器、二阶段弹性注水（`resumeSourceSlice` / `searcher.searchFile`）与 `searchArchiveSlice` 归档直搜。
  - [`src/file_api.zig`](src/file_api.zig)：路径安全消毒、多文件归档与单流压缩识别、`archive::entry` 虚拟路径协议及上下文窗口构建器（集成 `ArchiveTree`、`decompress`、`encoding`）。
  - [`src/search_cache.zig`](src/search_cache.zig)：并发目录文件清单缓存（集成 `walk_ignore`、`walk_file_id`、`walk_list`）与热文件只读 `mmap` 缓存（`<= 512 MiB`）。
  - [`src/docker_logs.zig`](src/docker_logs.zig)：零落盘 Docker Engine / Podman / OrbStack / Colima 套接字、TCP 与 `json-file` 容器目录自动发现及 8 字节多路复用日志流解码器（`DockerLogReader`）。
  - [`src/source_registry.zig`](src/source_registry.zig)：UUID v4 数据源持久化注册中心，支持目录（`dir`）、单文件（`file`）与零落盘 Docker 容器（`docker`）挂载及服务端补全。
- [`web/`](web/) — **Svelte 5 + Vite 8 + TypeScript 7 + Tailwind CSS 3.4 前端工作台**
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts)：全局响应式状态、渐进式查询解析器、两阶段流式帧节拍器（`60ms` 首屏聚合 + `80ms` VSync 对齐刷新）。
  - [`web/src/lib/components/`](web/src/lib/components/)：浏览器式搜索栏（支持主动建议与限定词补全）、120Hz 虚拟列表、上下文预览面板、`⌘/Ctrl+K` 命令面板与图标 Tab 设置中心。

---

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
