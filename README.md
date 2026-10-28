# webgrep

[English](README.md) | [简体中文](README.zh-CN.md)

**`webgrep`** is an ultra-fast, browser-based text, log, and code search workbench powered by **Zig 0.17.0** (`std.http.Server` + full-duplex `WebSocket`), the **[`libwebgrep`](https://github.com/fun7257/libwebgrep)** SIMD search engine (24–62 GB/s), and a **120Hz zero-flicker Svelte 5** frontend.

---

## Key Highlights

- **24–62 GB/s SIMD Search Engine ([`libwebgrep`](https://github.com/fun7257/libwebgrep))**:
  - **Cost-Based Selectivity Planner**: Automatically evaluates all positive predicates in a query, scores literal and regex selectivity, and elects the highest-selectivity term as the primary SIMD scanner (`Finder` or `Regex` with `RequiredLiteral` prefiltering).
  - **Linear-Time $O(n)$ Guarantee**: Lockstep Thompson NFA / PikeVM regex engine immune to catastrophic backtracking (ReDoS).
  - **In-Process Bomb-Safe Streaming Decompression**: Directly searches `.gz`, `.zst`, and `.xz` archives in-process without spawning external binaries.
- **Zero-Burden Progressive Search Syntax**:
  - **Space = Progressive Drill-Down (`AND`)**: Type `error timeout 502` to narrow results in real time—every space-separated token filters the current line set with multi-color highlight spans.
  - **Exclusion (`-word`)**: Prefix any token with `-` (e.g. `-healthcheck`) to exclude lines containing that term.
  - **Scoped `$` Modifiers (`$r(...)`, `$c(...)`, `$w(...)`)**: Apply modifiers strictly to the token inside parentheses without affecting other terms in the query:
    - `$r(pattern)` — Scoped regular expression
    - `$c(pattern)` — Scoped case-sensitive match
    - `$w(pattern)` — Scoped whole-word match
    - Combinable as `$rc(...)`, `$rw(...)`, `$cw(...)`, `$rcw(...)`, and negatable as `-$r(...)`, `-$c(...)`, `-$w(...)`
  - **Project Scope (`@name`)**: Type `@` in the search bar for instant autocomplete across mounted data sources.
- **Directory & Single-File Data Sources**:
  - Mount either **Local Directories (`dir`)** or **Single Files (`file`)** via the macOS-style Settings dialog, with real-time server path autocomplete and automatic RFC 4122 UUID v4 assignment.
- **120Hz Zero-Flicker Streaming UI**:
  - Full-duplex WebSocket micro-batch streaming with `Stale-While-Revalidate` result transitions, GPU-composited virtual scrolling (`translate3d` + `contain: strict`), and `WeakMap` zero-allocation highlight caching.

---

## Quick Start

### Prerequisites

- **Zig `0.17.0`**
- **Node.js `20+`** & **pnpm** (or npm)

### 1. Build Frontend Assets

```bash
npm --prefix web install
npm --prefix web run build
```

### 2. Build & Run the Zig Server

```bash
# Compile and run backend unit tests (automatically fetches libwebgrep v0.1.1)
zig build && zig build test

# Start the webgrep server (default: http://127.0.0.1:8787)
./zig-out/bin/webgrep --port 8787
```

Open **http://127.0.0.1:8787** in your browser. Click the Settings icon in the top-right corner to add a **Directory** or **Single File** data source and start searching immediately.

### 3. Development Mode (Hot Reload)

Keep `./zig-out/bin/webgrep` running on `:8787`, and start the Vite dev server in another terminal:

```bash
npm --prefix web run dev
```

---

## Architecture

- [`src/`](src/) — **Zig 0.17.0 HTTP & WebSocket Backend**
  - [`src/main.zig`](src/main.zig): CLI entry point and server bootstrap.
  - [`src/server.zig`](src/server.zig): HTTP REST endpoints (`/api/meta`, `/api/sources`, `/api/sources/complete`, `/api/file`) and full-duplex WebSocket handler (`/api/ws`).
  - [`src/search_job.zig`](src/search_job.zig): Multi-threaded work-stealing search runner, cost-based selectivity planner, and scoped `$` modifier compiler.
  - [`src/source_registry.zig`](src/source_registry.zig): Persistent UUID v4 data source registry supporting both directory (`dir`) and single-file (`file`) sources.
- [`web/`](web/) — **Svelte 5 + Vite 8 + TypeScript 7 + Tailwind CSS 4 Frontend**
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts): Reactive state store, progressive query parser, and two-stage WebSocket frame pacer (`60ms` first paint + `80ms` VSync streaming).
  - [`web/src/lib/components/`](web/src/lib/components/): Search bar with `@` and `$` autocomplete, 120Hz virtualized result stream, context inspector pane, and macOS-style settings dialog.

---

## License

Licensed under the [MIT License](LICENSE).
