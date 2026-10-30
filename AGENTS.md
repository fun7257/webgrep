# AGENTS.md — WebGrep AI Agent 开发入口与规范索引

本文档是 AI Agent 在 `webgrep` 仓库中进行开发的**总入口**。任何前端 UI、交互或状态层修改，**必须首先阅读并严格遵守独立的前端开发与极致性能规范文档**。

---

## 一、核心规范文档索引（必读）

- 📘 **[前端开发、120Hz 极致性能与视觉丝滑度规范 (`docs/FRONTEND_GUIDE.md`)](docs/FRONTEND_GUIDE.md)**
  - **核心产品理念**：零负担渐进式搜索优先（空格即深搜、内联 `@范围` / `$r(...)`/`$c`/`$w` 模式 / `-排除词`、禁止堆砌常驻按钮、可逆胶囊剥离）。
  - **设计语言**：少色（灰阶 + `primary` + `status`）、少字（图标优先、说明进 `title`）、触控友好（窄屏栈式导航、符号工具条、底部抽屉、`.touch-target` 44px）、快捷键用 `e.code` 且 `Alt+C/W/R` 为插入 `$x()` 而非全局开关、`⌘/Ctrl+K` 命令面板；设置与数据源见指南第八至十一章。
  - **Svelte 5 + TypeScript 7 响应式与内存铁律**：大数据集强制 `$state.raw` + Copy-on-Write、列表循环内细粒度原始值信号隔离、`WeakMap` 零分配高亮缓存、`{#snippet}` 模板复用。
  - **120Hz 渲染管线与零闪烁（Zero-Flicker / Zero-CLS）**：GPU 合成层 `translate3d` + `contain: strict` 零重排虚拟列表、Stale-While-Revalidate 无缝保留旧结果、`60ms` 首屏聚合 + `80ms` VSync 对齐流式节拍、左侧固定视觉锚点与单文件行高单调锁死。
  - **反模式红线清单（Anti-Patterns）**：所有严禁出现的代码写法与标准替代方案对照表。

---

## 二、仓库架构速览

- `web/`：**Svelte 5 (`^5.57.2`) + Vite 8 (`^8.3.5` Rolldown) + TypeScript 7 (`^7.0.2`) + Tailwind CSS 3.4** 前端工作台。
  - [`web/src/lib/state.svelte.ts`](web/src/lib/state.svelte.ts)：全局响应式状态、目录/文件数据源管理、渐进式查询解析器（`parsedQuery`）、WebSocket 流式两阶段节拍器。
  - [`web/src/lib/components/SettingsPopover.svelte`](web/src/lib/components/SettingsPopover.svelte)：图标 Tab 设置中心（通用、数据源〔内联添加表单〕、快捷键帮助），子面板位于 `settings/`，通用控件 `ui/SettingRow`、`ui/Segmented`；移动端为可下拉关闭的底部抽屉。
  - [`web/src/lib/components/CommandPalette.svelte`](web/src/lib/components/CommandPalette.svelte)：`⌘/Ctrl + K` 命令面板。
  - [`web/src/lib/components/SymbolBar.svelte`](web/src/lib/components/SymbolBar.svelte)：移动端软键盘上方符号工具条。
  - [`web/src/lib/components/SearchBar.svelte`](web/src/lib/components/SearchBar.svelte)：极简浏览器式搜索栏、`@数据源` 补全、`$` 模式补全、清除键与移动端符号工具条入口。
  - [`web/src/lib/components/TelemetryBar.svelte`](web/src/lib/components/TelemetryBar.svelte)：零 CLS 遥测状态栏与可点击剥离的深搜/排除胶囊。
  - [`web/src/lib/components/ResultList.svelte`](web/src/lib/components/ResultList.svelte)：120Hz GPU 合成层零重排虚拟列表。
  - [`web/src/lib/components/InspectorPane.svelte`](web/src/lib/components/InspectorPane.svelte)：右侧上下文预览面板与划词追加深搜气泡。
  - [`web/src/lib/utils.ts`](web/src/lib/utils.ts)：`WeakMap` 高亮分段缓存（`getCachedHighlightSegments`）与路径解析缓存（`splitFilePath`）。
- `src/`：**Zig 后端 HTTP / WebSocket 检索服务**，通过 [`build.zig.zon`](build.zig.zon) 依赖本地 [`../libwebgrep`](../libwebgrep) 搜索引擎。

---

## 三、修改后强制校验指令

每次完成代码修改后，Agent 必须执行以下构建与测试校验，确保零警告、零报错：

1. **前端单元测试、TypeScript 7 类型检查与生产构建**：
   ```bash
   npm --prefix web run test && npm --prefix web run check && npm --prefix web run build
   ```
2. **Zig 后端与 `../libwebgrep` 联调构建及测试**：
   ```bash
   zig build && zig build test
   ```
