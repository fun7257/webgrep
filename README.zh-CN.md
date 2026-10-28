# webgrep

[English](README.md) | [简体中文](README.zh-CN.md)

**`webgrep`** 是一款基于 **Zig 0.17.0**（`std.http.Server` + 全双工 `WebSocket`）、**[`libwebgrep`](https://github.com/fun7257/libwebgrep)** SIMD 搜索引擎核心（24–62 GB/s）与 **Svelte 5 (Runes)** 构建的 120Hz 零闪烁极速文本、日志与代码检索工作台。

---

## 核心特性

- **24–62 GB/s 原生 SIMD 检索引擎（[`libwebgrep`](https://github.com/fun7257/libwebgrep)）**：
  - **基于代价的选择性查询规划器（Cost-Based Selectivity Planner）**：自动评估查询中所有正向词条（字面量与正则）的选择性得分，选举最具区分度的词条作为主 SIMD 扫描器（`Finder` 或带 `RequiredLiteral` 预过滤的 `Regex`），保证词条顺序无关的恒定极速体验。
  - **最坏 $O(n)$ 线性时间复杂度**：无回溯 Thompson NFA / PikeVM 正则引擎，彻底免疫灾难性回溯（ReDoS）。
  - **进程内防爆流式解压**：无需派生外部子进程，直接流式检索 `.gz`、`.zst`、`.xz` 压缩文件。
- **零心智负担的渐进式内联搜索语法**：
  - **空格即深搜（`AND`）**：直接输入 `error timeout 502`，空格分隔的每个词条实时对命中行做交集过滤，并以多色高亮区分。
  - **内联排除（`-word`）**：任意词条前加 `-`（如 `-healthcheck`）即可实时剔除包含该词的行。
  - **局部作用域 `$` 修饰符（`$r(...)` / `$c(...)` / `$w(...)`）**：仅对括号内的词条生效，不影响外部普通词条，支持在输入框任意位置触发 `$` 智能补全与括号自动配对：
    - `$r(pattern)` — 局部正则表达式匹配
    - `$c(pattern)` — 局部区分大小写匹配
    - `$w(pattern)` — 局部全词匹配
    - 支持任意组合：`$rc(...)`、`$rw(...)`、`$cw(...)`、`$rcw(...)`，以及取反排除 `-$r(...)`、`-$c(...)`、`-$w(...)`
  - **数据源范围限定（`@名称`）**：在搜索框输入 `@` 实时呼出已挂载的数据源补全列表。
- **多类型数据源管理（目录模式 + 单文件模式）**：
  - 采用 macOS 原生风格居中分栏设置弹窗，支持先选择数据源类型（**目录模式 `dir`** 或 **单文件模式 `file`**），再通过服务端路径实时补全挂载目标路径，创建时自动分配 RFC 4122 UUID v4。
- **120Hz 零闪烁流式渲染管线**：
  - 全双工 WebSocket 微批流式传输，结合 `Stale-While-Revalidate` 无缝过渡、GPU 合成层零重排虚拟列表（`translate3d` + `contain: strict`）与 `WeakMap` 零分配高亮缓存。

---

## 快速上手

### 环境要求

- **Zig `0.17.0`**
- **Node.js `20+`** 与 **pnpm**（或 npm）

### 1. 构建前端静态资源

```bash
npm --prefix web install
npm --prefix web run build
```

### 2. 编译并启动 Zig 服务端

```bash
# 编译并运行后端单元测试（自动拉取 GitHub 上的 libwebgrep v0.1.1 依赖）
zig build && zig build test

# 启动 webgrep 服务（默认监听 http://127.0.0.1:8787）
./zig-out/bin/webgrep --port 8787
```

浏览器打开 **http://127.0.0.1:8787**，点击右上角设置图标进入 **「添加数据源」**，即可选择目录或单文件开始极速检索。

### 3. 前端热更新开发模式（可选）

保持 `./zig-out/bin/webgrep` 在 `:8787` 运行，另开终端启动 Vite 开发服务器：

```bash
npm --prefix web run dev
```

---

## 仓库目录结构

- [`src/`](src/) — **Zig 0.17.0 HTTP & WebSocket 后端服务**
  - [`src/main.zig`](src/main.zig)：命令行参数解析与服务启动入口。
  - [`src/server.zig`](src/server.zig)：HTTP 接口（`/api/meta`、`/api/sources`、`/api/sources/complete`、`/api/file`）与 WebSocket 全双工检索通道（`/api/ws`）。
  - [`src/search_job.zig`](src/search_job.zig)：多线程并发检索调度器、基于代价的词条选择性规划器、局部 `$` 修饰符编译器。
  - [`src/source_registry.zig`](src/source_registry.zig)：UUID v4 数据源持久化注册中心，支持目录（`dir`）与单文件（`file`）挂载及服务端路径补全。
- [`web/`](web/) — **Svelte 5 + Vite 8 + TypeScript 7 + Tailwind CSS 4 前端工作台**
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts)：全局响应式状态、渐进式查询解析器、两阶段流式帧节拍器（`60ms` 首屏聚合 + `80ms` VSync 对齐刷新）。
  - [`web/src/lib/components/`](web/src/lib/components/)：浏览器式搜索栏（支持 `@` 与 `$` 智能补全）、120Hz 虚拟列表、上下文预览面板与 macOS 风格分栏设置弹窗。

---

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
