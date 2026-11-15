import { splitFilePath } from './utils.ts';

function assertSplit(
  input: string,
  expected: { dir: string; name: string; ext: string }
): void {
  const actual = splitFilePath(input);
  if (
    actual.dir !== expected.dir ||
    actual.name !== expected.name ||
    actual.ext !== expected.ext
  ) {
    throw new Error(
      `splitFilePath(${JSON.stringify(input)}) mismatch: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
    );
  }
}

export function runSplitFilePathTests(): void {
  assertSplit('README.md', {
    dir: '',
    name: 'README.md',
    ext: 'md',
  });
  assertSplit('src/lib/utils.ts', {
    dir: 'src/lib/',
    name: 'utils.ts',
    ext: 'ts',
  });
  assertSplit('web-grep-v0.1.7.tar.gz::README.md', {
    dir: 'web-grep-v0.1.7.tar.gz::',
    name: 'README.md',
    ext: 'md',
  });
  assertSplit('agent/web-grep-v0.1.7.tar.gz::package.json', {
    dir: 'agent/web-grep-v0.1.7.tar.gz::',
    name: 'package.json',
    ext: 'json',
  });
  assertSplit('dir/archive.tar.gz::sub/file.zig', {
    dir: 'dir/archive.tar.gz::sub/',
    name: 'file.zig',
    ext: 'zig',
  });
  assertSplit('bundle.zip::logs/2026/app.log', {
    dir: 'bundle.zip::logs/2026/',
    name: 'app.log',
    ext: 'log',
  });
  assertSplit('docker/nginx', {
    dir: 'docker/',
    name: 'nginx',
    ext: '',
  });
  assertSplit('docker/api-111111111111', {
    dir: 'docker/',
    name: 'api-111111111111',
    ext: '',
  });
}

runSplitFilePathTests();
