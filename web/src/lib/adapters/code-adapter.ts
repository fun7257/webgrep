import { splitFilePath } from '../format.ts';
import { resolveSourcePluginPreset } from '../prefilter.ts';
import type { DataSourceItem, HitItem } from '../types.ts';
import { getCachedLogProbe } from './log-parser.ts';
import type {
  CodeDirStat,
  CodeLangStat,
  CodeLanguageInfo,
  CodeStreamStats,
  CodeVirtualItem,
  CodeVirtualLayout,
  FastLogProbe,
  HeadlessAdapter,
  ParsedPlainRecord,
  PlainRowProbe,
  RowLayoutMetrics,
  RowMeasureContext,
} from './types.ts';

export const CODE_HEADER_HEIGHT = 34;

export const CODE_EXT_MAP: Record<string, CodeLanguageInfo> = {
  zig: { id: 'zig', label: 'Zig', ext: '.zig' },
  zon: { id: 'zon', label: 'ZON', ext: '.zon' },
  ts: { id: 'ts', label: 'TypeScript', ext: '.ts' },
  mts: { id: 'ts', label: 'TypeScript', ext: '.mts' },
  cts: { id: 'ts', label: 'TypeScript', ext: '.cts' },
  tsx: { id: 'tsx', label: 'TSX', ext: '.tsx' },
  js: { id: 'js', label: 'JavaScript', ext: '.js' },
  mjs: { id: 'js', label: 'JavaScript', ext: '.mjs' },
  cjs: { id: 'js', label: 'JavaScript', ext: '.cjs' },
  jsx: { id: 'jsx', label: 'JSX', ext: '.jsx' },
  svelte: { id: 'svelte', label: 'Svelte', ext: '.svelte' },
  vue: { id: 'vue', label: 'Vue', ext: '.vue' },
  rs: { id: 'rs', label: 'Rust', ext: '.rs' },
  go: { id: 'go', label: 'Go', ext: '.go' },
  py: { id: 'py', label: 'Python', ext: '.py' },
  pyi: { id: 'py', label: 'Python', ext: '.pyi' },
  java: { id: 'java', label: 'Java', ext: '.java' },
  kt: { id: 'kt', label: 'Kotlin', ext: '.kt' },
  kts: { id: 'kt', label: 'Kotlin', ext: '.kts' },
  scala: { id: 'scala', label: 'Scala', ext: '.scala' },
  c: { id: 'c', label: 'C', ext: '.c' },
  h: { id: 'c', label: 'C/C++', ext: '.h' },
  cpp: { id: 'cpp', label: 'C++', ext: '.cpp' },
  cc: { id: 'cpp', label: 'C++', ext: '.cc' },
  cxx: { id: 'cpp', label: 'C++', ext: '.cxx' },
  hpp: { id: 'cpp', label: 'C++', ext: '.hpp' },
  hh: { id: 'cpp', label: 'C++', ext: '.hh' },
  cs: { id: 'cs', label: 'C#', ext: '.cs' },
  rb: { id: 'rb', label: 'Ruby', ext: '.rb' },
  php: { id: 'php', label: 'PHP', ext: '.php' },
  swift: { id: 'swift', label: 'Swift', ext: '.swift' },
  m: { id: 'objc', label: 'Obj-C', ext: '.m' },
  mm: { id: 'objc', label: 'Obj-C++', ext: '.mm' },
  lua: { id: 'lua', label: 'Lua', ext: '.lua' },
  r: { id: 'r', label: 'R', ext: '.r' },
  dart: { id: 'dart', label: 'Dart', ext: '.dart' },
  ex: { id: 'elixir', label: 'Elixir', ext: '.ex' },
  exs: { id: 'elixir', label: 'Elixir', ext: '.exs' },
  erl: { id: 'erlang', label: 'Erlang', ext: '.erl' },
  hs: { id: 'haskell', label: 'Haskell', ext: '.hs' },
  ml: { id: 'ocaml', label: 'OCaml', ext: '.ml' },
  mli: { id: 'ocaml', label: 'OCaml', ext: '.mli' },
  clj: { id: 'clojure', label: 'Clojure', ext: '.clj' },
  sh: { id: 'shell', label: 'Shell', ext: '.sh' },
  bash: { id: 'shell', label: 'Bash', ext: '.bash' },
  zsh: { id: 'shell', label: 'Zsh', ext: '.zsh' },
  fish: { id: 'shell', label: 'Fish', ext: '.fish' },
  ps1: { id: 'powershell', label: 'PowerShell', ext: '.ps1' },
  css: { id: 'css', label: 'CSS', ext: '.css' },
  scss: { id: 'scss', label: 'SCSS', ext: '.scss' },
  sass: { id: 'sass', label: 'Sass', ext: '.sass' },
  less: { id: 'less', label: 'Less', ext: '.less' },
  html: { id: 'html', label: 'HTML', ext: '.html' },
  htm: { id: 'html', label: 'HTML', ext: '.htm' },
  xml: { id: 'xml', label: 'XML', ext: '.xml' },
  svg: { id: 'svg', label: 'SVG', ext: '.svg' },
  sql: { id: 'sql', label: 'SQL', ext: '.sql' },
  proto: { id: 'proto', label: 'Protobuf', ext: '.proto' },
  graphql: { id: 'graphql', label: 'GraphQL', ext: '.graphql' },
  gql: { id: 'graphql', label: 'GraphQL', ext: '.gql' },
  toml: { id: 'toml', label: 'TOML', ext: '.toml' },
  yaml: { id: 'yaml', label: 'YAML', ext: '.yaml' },
  yml: { id: 'yaml', label: 'YAML', ext: '.yml' },
  md: { id: 'markdown', label: 'Markdown', ext: '.md' },
  mdx: { id: 'markdown', label: 'MDX', ext: '.mdx' },
  json: { id: 'json', label: 'JSON', ext: '.json' },
  jsonc: { id: 'json', label: 'JSONC', ext: '.jsonc' },
  json5: { id: 'json', label: 'JSON5', ext: '.json5' },
  lock: { id: 'lock', label: 'Lockfile', ext: '.lock' },
  tf: { id: 'terraform', label: 'Terraform', ext: '.tf' },
  hcl: { id: 'hcl', label: 'HCL', ext: '.hcl' },
  nix: { id: 'nix', label: 'Nix', ext: '.nix' },
  cmake: { id: 'cmake', label: 'CMake', ext: '.cmake' },
  gradle: { id: 'gradle', label: 'Gradle', ext: '.gradle' },
  ini: { id: 'ini', label: 'INI', ext: '.ini' },
  cfg: { id: 'cfg', label: 'Config', ext: '.cfg' },
  conf: { id: 'conf', label: 'Config', ext: '.conf' },
  env: { id: 'env', label: 'Env', ext: '.env' },
};

const SPECIAL_FILENAME_LANGS: Record<string, CodeLanguageInfo> = {
  dockerfile: { id: 'docker', label: 'Dockerfile', ext: 'Dockerfile' },
  makefile: { id: 'make', label: 'Makefile', ext: 'Makefile' },
  'cmakelists.txt': { id: 'cmake', label: 'CMake', ext: 'CMake' },
  justfile: { id: 'make', label: 'Justfile', ext: 'Justfile' },
  rakefile: { id: 'rb', label: 'Rakefile', ext: 'Rakefile' },
  gemfile: { id: 'rb', label: 'Gemfile', ext: 'Gemfile' },
  podfile: { id: 'rb', label: 'Podfile', ext: 'Podfile' },
  vagrantfile: { id: 'rb', label: 'Vagrantfile', ext: 'Vagrantfile' },
  'go.mod': { id: 'go', label: 'Go Mod', ext: 'go.mod' },
  'go.sum': { id: 'go', label: 'Go Sum', ext: 'go.sum' },
  '.gitignore': { id: 'ignore', label: 'GitIgnore', ext: '.gitignore' },
  '.ignore': { id: 'ignore', label: 'Ignore', ext: '.ignore' },
};

const MANIFEST_JSON_FILENAMES = new Set<string>([
  'package.json',
  'package-lock.json',
  'tsconfig.json',
  'jsconfig.json',
  'composer.json',
  'deno.json',
  'deno.jsonc',
  'manifest.json',
]);

const JSON_LOG_EXTS = new Set<string>(['json', 'jsonl', 'ndjson']);

export function detectCodeLanguage(filePath: string): CodeLanguageInfo | null {
  const { name, ext } = splitFilePath(filePath);
  const lowerName = name.toLowerCase();
  const special = SPECIAL_FILENAME_LANGS[lowerName];
  if (special) return special;
  if (!ext) return null;
  return CODE_EXT_MAP[ext] ?? null;
}

export function isCodeOrManifestPath(filePath: string): boolean {
  return detectCodeLanguage(filePath) !== null;
}

/**
 * Returns true for dedicated source/config/manifest paths that are never treated as logs in `auto` mode
 * (non-manifest `.json`/`.jsonl`/`.ndjson` files are intentionally excluded so NDJSON log dumps can use `log`).
 */
export function isCodeOnlyPath(filePath: string): boolean {
  const { name, ext } = splitFilePath(filePath);
  const lowerName = name.toLowerCase();
  if (MANIFEST_JSON_FILENAMES.has(lowerName) || SPECIAL_FILENAME_LANGS[lowerName]) {
    return true;
  }
  if (!ext || JSON_LOG_EXTS.has(ext)) return false;
  return Boolean(CODE_EXT_MAP[ext]);
}

/**
 * Extracts a compact top-2 directory key inside a source path (e.g. `web/src/` or `.`).
 */
export function extractCodeDirectory(filePath: string): string {
  const slash = filePath.indexOf('/');
  const lastSlash = filePath.lastIndexOf('/');
  if (lastSlash <= 0 || (slash > 0 && lastSlash === slash)) {
    return '.';
  }
  const relStart = slash > 0 ? slash + 1 : 0;
  if (relStart >= lastSlash) return '.';
  const subDir = filePath.slice(relStart, lastSlash);
  const parts = subDir.split('/').filter(Boolean);
  if (parts.length === 0) return '.';
  return `${parts.slice(0, 2).join('/')}/`;
}

export function scoreCodeConfidence(
  item: HitItem,
  source?: DataSourceItem,
  logProbe?: FastLogProbe
): number {
  const preset = source ? resolveSourcePluginPreset(source) : 'auto';
  if (source) {
    if (preset === 'code') return 0.95;
    if (preset === 'timeseries' || preset === 'raw' || source.kind === 'docker') {
      return 0;
    }
  }

  const { name, ext } = splitFilePath(item.file);
  const lowerName = name.toLowerCase();
  if (MANIFEST_JSON_FILENAMES.has(lowerName) || SPECIAL_FILENAME_LANGS[lowerName]) {
    return 0.9;
  }

  if (JSON_LOG_EXTS.has(ext)) {
    const probe = logProbe ?? getCachedLogProbe(item);
    if (probe.isLog) return 0;
  }

  return detectCodeLanguage(item.file) ? 0.9 : 0;
}

export function measureCodeHitRow(probe: PlainRowProbe, ctx: RowMeasureContext): RowLayoutMetrics {
  const maxLines = ctx.wordWrap ? Math.max(1, Math.min(3, ctx.maxPreviewLines)) : 1;
  let lines = 1;
  if (maxLines > 1) {
    lines = Math.min(maxLines, Math.max(1, Math.ceil(probe.cols / ctx.charsPerLine - 0.12)));
  }
  const pad = ctx.density === 'compact' ? 8 : 12;
  return {
    lines,
    height: pad + lines * ctx.lineHeight,
  };
}

export const codeAdapter: HeadlessAdapter = {
  id: 'code',
  order: 1,
  inspectContextLines: 12,
  supportsStructuredToggle: false,

  classifyHit(item: HitItem, source?: DataSourceItem): number {
    return scoreCodeConfidence(item, source, getCachedLogProbe(item));
  },

  getFormattedCopyText(): string | null {
    return null;
  },
};

const EMPTY_CODE_STATS: CodeStreamStats = {
  totalScanned: 0,
  fileCount: 0,
  languages: [],
  topDirs: [],
};

/**
 * Incremental O(delta) codebase statistics tracker for `CodeSummaryStrip`.
 */
export class CodeStreamStatsTracker {
  private firstHitRef: HitItem | null = null;
  private scannedLen = 0;
  private fileSet = new Set<string>();
  private langCounts = new Map<string, { id: string; label: string; count: number }>();
  private dirCounts = new Map<string, number>();
  private cachedStats: CodeStreamStats = EMPTY_CODE_STATS;

  reset(): void {
    this.firstHitRef = null;
    this.scannedLen = 0;
    this.fileSet.clear();
    this.langCounts.clear();
    this.dirCounts.clear();
    this.cachedStats = EMPTY_CODE_STATS;
  }

  update(hits: readonly HitItem[]): CodeStreamStats {
    const hLen = hits.length;
    if (hLen === 0) {
      if (this.scannedLen !== 0) this.reset();
      return this.cachedStats;
    }

    if (hits[0] !== this.firstHitRef || hLen < this.scannedLen) {
      this.reset();
      this.firstHitRef = hits[0];
    }

    if (this.scannedLen === hLen) {
      return this.cachedStats;
    }

    let lastFile = '';
    let lastLang: CodeLanguageInfo | null = null;
    let lastDir = '';

    for (let i = this.scannedLen; i < hLen; i++) {
      const it = hits[i];
      if (it.file !== lastFile) {
        lastFile = it.file;
        this.fileSet.add(lastFile);
        lastLang = detectCodeLanguage(lastFile);
        lastDir = extractCodeDirectory(lastFile);
      }

      const langId = lastLang?.id ?? 'other';
      const langLabel = lastLang?.ext ?? 'text';
      const prevLang = this.langCounts.get(langId);
      if (prevLang) {
        prevLang.count += 1;
      } else {
        this.langCounts.set(langId, { id: langId, label: langLabel, count: 1 });
      }

      if (lastDir) {
        this.dirCounts.set(lastDir, (this.dirCounts.get(lastDir) ?? 0) + 1);
      }
    }

    this.scannedLen = hLen;

    const languages: CodeLangStat[] = Array.from(this.langCounts.values())
      .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label))
      .slice(0, 6)
      .map((entry) => ({ id: entry.id, label: entry.label, count: entry.count }));

    const topDirs: CodeDirStat[] = Array.from(this.dirCounts.entries())
      .filter(([dir]) => dir !== '.' || this.dirCounts.size === 1)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 4)
      .map(([dir, count]) => ({ dir, count }));

    this.cachedStats = {
      totalScanned: hLen,
      fileCount: this.fileSet.size,
      languages,
      topDirs,
    };
    return this.cachedStats;
  }
}

interface GroupedCodeFile {
  file: string;
  srcName: string;
  dirLabel: string;
  fileName: string;
  lang: CodeLanguageInfo | null;
  dirKey: string;
  hits: { item: HitItem; flatIdx: number }[];
}

export function buildCodeVirtualLayout(params: {
  hits: readonly HitItem[];
  collapsedFiles: ReadonlySet<string>;
  activeLangFilter: string | null;
  activeDirFilter: string | null;
  ctx: RowMeasureContext;
  budget: number;
  getPlainMeta: (item: HitItem) => ParsedPlainRecord;
  getPlainProbe: (item: HitItem, budget: number) => PlainRowProbe;
}): CodeVirtualLayout {
  const {
    hits,
    collapsedFiles,
    activeLangFilter,
    activeDirFilter,
    ctx,
    budget,
    getPlainMeta,
    getPlainProbe,
  } = params;

  const hLen = hits.length;
  const hitIdxToVirtualIdx = new Int32Array(hLen);
  hitIdxToVirtualIdx.fill(-1);

  if (hLen === 0) {
    return {
      items: [],
      offsets: new Float64Array(1),
      hitIdxToVirtualIdx,
      totalHeight: 0,
      matchedHitCount: 0,
      visibleFileCount: 0,
      totalFileCount: 0,
      allCollapsed: false,
    };
  }

  const fileOrder: GroupedCodeFile[] = [];
  const byFile = new Map<string, GroupedCodeFile>();

  let lastFile = '';
  let lastGroup: GroupedCodeFile | null = null;
  for (let i = 0; i < hLen; i++) {
    const item = hits[i];
    if (item.file !== lastFile || !lastGroup) {
      lastFile = item.file;
      let grp = byFile.get(lastFile);
      if (!grp) {
        const meta = getPlainMeta(item);
        grp = {
          file: lastFile,
          srcName: meta.srcName,
          dirLabel: meta.dirLabel,
          fileName: meta.fileName,
          lang: detectCodeLanguage(lastFile),
          dirKey: extractCodeDirectory(lastFile),
          hits: [],
        };
        byFile.set(lastFile, grp);
        fileOrder.push(grp);
      }
      lastGroup = grp;
    }
    lastGroup.hits.push({ item, flatIdx: i });
  }

  const items: CodeVirtualItem[] = [];
  let matchedHitCount = 0;
  let visibleFileCount = 0;
  let collapsedCount = 0;
  let prevSrc = '';

  for (let g = 0; g < fileOrder.length; g++) {
    const grp = fileOrder[g];
    const langId = grp.lang?.id ?? 'other';
    if (activeLangFilter && langId !== activeLangFilter) continue;
    if (activeDirFilter && grp.dirKey !== activeDirFilter) continue;

    visibleFileCount += 1;
    const isCollapsed = collapsedFiles.has(grp.file);
    if (isCollapsed) collapsedCount += 1;
    matchedHitCount += grp.hits.length;

    const showSrc = Boolean(grp.srcName) && (visibleFileCount === 1 || grp.srcName !== prevSrc);
    prevSrc = grp.srcName;

    const headerIdx = items.length;
    items.push({
      kind: 'file-header',
      key: `fh:${grp.file}`,
      file: grp.file,
      srcName: grp.srcName,
      showSrc,
      dirLabel: grp.dirLabel,
      fileName: grp.fileName,
      lang: grp.lang,
      matchCount: grp.hits.length,
      collapsed: isCollapsed,
      firstHitIdx: grp.hits[0].flatIdx,
      height: CODE_HEADER_HEIGHT,
    });

    if (isCollapsed) {
      for (let k = 0; k < grp.hits.length; k++) {
        hitIdxToVirtualIdx[grp.hits[k].flatIdx] = headerIdx;
      }
      continue;
    }

    for (let k = 0; k < grp.hits.length; k++) {
      const { item, flatIdx } = grp.hits[k];
      const probe = getPlainProbe(item, budget);
      const metrics = measureCodeHitRow(probe, ctx);
      const vIdx = items.length;
      hitIdxToVirtualIdx[flatIdx] = vIdx;
      items.push({
        kind: 'hit',
        key: `ch:${flatIdx}:${grp.file}:${item.line}:${item.col}`,
        hitIdx: flatIdx,
        item,
        srcName: grp.srcName,
        fileName: grp.fileName,
        lang: grp.lang,
        lines: metrics.lines,
        height: metrics.height,
      });
    }
  }

  const offsets = new Float64Array(items.length + 1);
  let acc = 0;
  for (let i = 0; i < items.length; i++) {
    offsets[i] = acc;
    acc += items[i].height;
  }
  offsets[items.length] = acc;

  return {
    items,
    offsets,
    hitIdxToVirtualIdx,
    totalHeight: acc,
    matchedHitCount,
    visibleFileCount,
    totalFileCount: fileOrder.length,
    allCollapsed: visibleFileCount > 0 && collapsedCount === visibleFileCount,
  };
}
