# webgrep

[English](README.md) | [简体中文](README.zh-CN.md)

**`webgrep`** is an ultra-fast, browser-based text, log, and code search workbench powered by **Zig 0.17.0** (`std.http.Server` + full-duplex `WebSocket`), the **[`libwebgrep v0.5.0`](https://github.com/fun7257/libwebgrep)** SIMD search engine (24–62 GB/s), and a **120Hz zero-flicker Svelte 5** frontend.

---

## Documentation & Engineering Guides

- 🧭 **[AI Agent Entry & Standard Workflow (`AGENTS.md`)](AGENTS.md)** — Repository overview, mandatory build verification, and the 5-step AI Agent closed-loop development workflow.
- 📗 **[Backend Engine & `libwebgrep v0.5.0` Guide (`docs/LIBWEBGREP_GUIDE.md`)](docs/LIBWEBGREP_GUIDE.md)** — Authoritative guide on search entry points, `EngineLimits`, Pause/Resume two-stage water-filling, lock-free `*const` matchers, zero-disk archive search (`archive::entry`), and `walk_*` submodules.
- 📘 **[Frontend 120Hz Performance & UI Guide (`docs/FRONTEND_GUIDE.md`)](docs/FRONTEND_GUIDE.md)** — Progressive search UX, Svelte 5 `$state.raw` reactivity rules, GPU-composited virtual scrolling, and anti-patterns.

---

## Key Highlights

- **24–62 GB/s SIMD Search Engine ([`libwebgrep v0.5.0`](https://github.com/fun7257/libwebgrep))**:
  - **Cost-Based Selectivity Planner**: Automatically evaluates all positive predicates in a query, scores literal and regex selectivity, and elects the highest-selectivity term as the primary SIMD scanner (`*const Finder`, `*const Multi`, or `*const Regex` with `RequiredLiteral` prefiltering).
  - **Linear-Time $O(n)$ Guarantee & Structured Diagnostics**: Hybrid Lazy DFA + lockstep Thompson NFA / PikeVM regex engine immune to catastrophic backtracking (ReDoS), with `Regex.initDiagnostic` (`CompileDiagnostic`) reporting exact line, column, and error codes.
  - **Zero-Disk Multi-File Archive & Streaming Codec Support**:
    - **In-Memory Multi-File Archive Search & Preview**: Directly searches inside `.tar`, `.tar.gz`/`.tgz`, `.tar.zst`/`.tzst`, `.tar.xz`/`.txz`, and `.zip` archives (`searchArchiveSlice` / `ArchiveTree`) and previews internal entries via virtual paths (`archive.tar.gz::path/to/file`) without extracting temporary files to disk.
    - **Bomb-Safe Streaming Decompression**: Transparently decompresses `.gz`, `.zst`, and `.xz` streams in-process with `max_decompressed_bytes` and `max_compression_ratio` bomb guards.
    - **Auto Encoding Sniffing & Transcoding**: Automatically detects BOM and transcodes UTF-16LE/BE, GBK/GB18030, and Latin-1/Windows-1252 to UTF-8 while preserving exact `raw_offset` mappings.
  - **Two-Stage Elastic Water-Filling & Colossal File Streaming**: Isolates colossal files (`> 256 MiB`) into Stage 2 and streams `> 512 MiB` logs (e.g. 13.87GB `10000w.log`) via `searcher.searchFile` + L2-aligned `optimalBufferSize` + reusable `Scratch` buffers without `mmap` page-table thrashing.
- **Zero-Burden Progressive Search Syntax**:
  - **Space = Progressive Drill-Down (`AND`)**: Type `error timeout 502` to narrow results in real time—every space-separated token filters the current line set with multi-color highlight spans.
  - **Exclusion (`-word`) & Exact Phrase (`"..."`)**: Prefix any token with `-` (e.g. `-healthcheck`) to exclude lines, or wrap in quotes for exact phrases.
  - **Unified Scope (`in:`) & Time (`time:`) Qualifiers**: Filter by data source, language type (67+ built-in types via `walk_types`), or path glob (`in:zig`, `in:src/`), and filter timestamped logs (`time:today`, `time:2026-11-12`).
  - **Regex (`/pattern/`) & Scoped `$` Modifiers**: Use `/pattern/` directly or scoped `$r(...)`, `$c(...)`, `$w(...)` modifiers.
- **Directory & Single-File / Archive Data Sources**:
  - Mount either **Local Directories (`dir`)** or **Single Files / Archives (`file`)** via the Settings center, with real-time `walk_list.Lister` server path autocomplete and automatic RFC 4122 UUID v4 persistence.
- **120Hz Zero-Flicker Streaming UI**:
  - Full-duplex WebSocket micro-batch streaming (`1 -> 32 -> 128 -> 512` ramp-up) with `Stale-While-Revalidate` result transitions, GPU-composited virtual scrolling (`translate3d` + `contain: strict`), and `WeakMap` zero-allocation highlight caching.

---

## Quick Start

### Prerequisites

- **Zig `0.17.0`**
- **Node.js `20+`** & **npm**

### 1. Build Frontend Assets

```bash
npm --prefix web install
npm --prefix web run build
```

### 2. Build & Run the Zig Server

```bash
# Compile and run backend unit tests (linked with libwebgrep v0.5.0)
zig build && zig build test

# Start the webgrep server (default: http://127.0.0.1:8787 + active Tailscale interface(s), `--host 127.0.0.1,tailscale`)
./zig-out/bin/webgrep --port 8787

# Optional deployment authentication (Web password-only login & MCP Bearer token via env vars or flags):
WEBGREP_PASSWORD="your-web-password" WEBGREP_MCP_TOKEN="your-mcp-token" ./zig-out/bin/webgrep --port 8787
# Or pass flags: ./zig-out/bin/webgrep --password "your-web-password" --mcp-token "your-mcp-token"
```

Open **http://127.0.0.1:8787** (or your node's Tailscale IP/MagicDNS on `:8787` — `webgrep` binds `127.0.0.1` plus active Tailscale interfaces by default and watches for Tailscale reconnects without exposing LAN/`0.0.0.0`). Click the Settings icon in the top-right corner to add a **Directory**, **Single File**, or **Docker Containers** (`auto` zero-disk live container log discovery) data source and start searching immediately.

### 3. Development Mode (Hot Reload)

Keep `./zig-out/bin/webgrep` running on `:8787`, and start the Vite dev server in another terminal:

```bash
npm --prefix web run dev
```

---

## Architecture

- [`src/`](src/) — **Zig 0.17.0 HTTP & WebSocket Backend**
  - [`src/main.zig`](src/main.zig): CLI entry point and server bootstrap.
  - [`src/net_bind.zig`](src/net_bind.zig): Multi-listener host parser (`--host 127.0.0.1,tailscale` default) and automatic Tailscale interface discovery/hot-binding.
  - [`src/server.zig`](src/server.zig): HTTP REST endpoints (`/api/meta`, `/api/sources`, `/api/sources/complete`, `/api/file`, `/api/context`) and full-duplex WebSocket handler (`/api/ws`).
  - [`src/search_job.zig`](src/search_job.zig): Multi-threaded search scheduler, cost-based selectivity planner, two-stage water-filling (`resumeSourceSlice` / `searcher.searchFile`), and `searchArchiveSlice` integration.
  - [`src/file_api.zig`](src/file_api.zig): Safe path sanitization, archive/compression detection, `archive::entry` virtual path protocol, and context preview builder (`ArchiveTree`, `decompress`, `encoding`).
  - [`src/search_cache.zig`](src/search_cache.zig): Concurrent directory inventory (`walk_ignore`, `walk_file_id`, `walk_list`) and hot-file read-only `mmap` cache (`<= 512 MiB`).
  - [`src/docker_logs.zig`](src/docker_logs.zig): Zero-disk-landing Docker Engine / Podman / OrbStack / Colima socket, TCP, and `json-file` directory container discovery and multiplexed stream reader (`DockerLogReader`).
  - [`src/source_registry.zig`](src/source_registry.zig): Persistent UUID v4 data source registry supporting directory (`dir`), single-file (`file`), and zero-disk Docker container (`docker`) sources.
- [`web/`](web/) — **Svelte 5 + Vite 8 + TypeScript 7 + Tailwind CSS 3.4 Frontend**
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts): Reactive state store, progressive query parser, and two-stage WebSocket frame pacer (`60ms` first paint + `80ms` VSync streaming).
  - [`web/src/lib/components/`](web/src/lib/components/): Search bar with smart suggestions, 120Hz virtualized result stream, context inspector pane, command palette (`⌘/Ctrl+K`), and settings center.

---

## License

Licensed under the [MIT License](LICENSE).
