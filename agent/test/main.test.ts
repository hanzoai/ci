// The whole tool over small bundles: each fixture's in/ must become its want/
// byte for byte, a second run must change nothing, and every opt-out must
// leave the bundle as it was. Regenerate a want/ only after reading the diff:
//   rm -rf test/fixtures/<f>/want && cp -a test/fixtures/<f>/in test/fixtures/<f>/want
//   node main.ts --dir test/fixtures/<f>/want <the args below>

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main } from '../main.ts';

const fixtures = fileURLToPath(new URL('./fixtures/', import.meta.url));

const cases: Array<{ name: string; args: string[] }> = [
  { name: 'site', args: ['--host', 'example.com'] },
  { name: 'bare', args: ['--host', 'bare.example.com'] },
  { name: 'skills', args: ['--host', 'skills.example.com', '--skills', path.join(fixtures, 'skills', 'skills')] },
];

function tree(dir: string, rel = '', out = new Map<string, Buffer>()): Map<string, Buffer> {
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) tree(dir, r, out);
    else out.set(r, fs.readFileSync(path.join(dir, r)));
  }
  return out;
}

function copy(name: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `agent-${name}-`));
  fs.cpSync(path.join(fixtures, name, 'in'), dir, { recursive: true });
  return dir;
}

function same(got: Map<string, Buffer>, want: Map<string, Buffer>): void {
  assert.deepEqual([...got.keys()].sort(), [...want.keys()].sort());
  for (const [k, v] of want) assert.equal(got.get(k)?.toString('latin1'), v.toString('latin1'), k);
}

for (const c of cases) {
  test(`${c.name}: in/ becomes want/, byte for byte`, async () => {
    const dir = copy(c.name);
    await main(['--dir', dir, ...c.args]);
    same(tree(dir), tree(path.join(fixtures, c.name, 'want')));
  });

  test(`${c.name}: a second run changes nothing`, async () => {
    const dir = copy(c.name);
    await main(['--dir', dir, ...c.args]);
    const once = tree(dir);
    const report = await main(['--dir', dir, ...c.args]);
    same(tree(dir), once);
    for (const line of report.slice(1)) assert.match(line, /: (present|off|0 written, \d+ present|0 added, \d+ present)$/, line);
  });
}

test('every piece opted out leaves the bundle as it was', async () => {
  const dir = copy('site');
  const before = tree(dir);
  const report = await main(['--dir', dir, '--host', 'example.com', ...['twins', 'links', 'robots', 'sitemap', 'llms', 'catalog', 'auth'].map((p) => `--no-${p}`)]);
  same(tree(dir), before);
  assert.match(report.join('\n'), /robots\.txt: off/);
});

test('a page hardlinked into a second bundle changes in this bundle alone', async () => {
  const dir = copy('bare');
  const twin = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-twin-'));
  for (const f of fs.readdirSync(dir)) fs.linkSync(path.join(dir, f), path.join(twin, f));
  const before = tree(twin);
  await main(['--dir', dir, '--host', 'bare.example.com']);
  same(tree(twin), before);
  assert.notEqual(fs.readFileSync(path.join(dir, 'index.html'), 'latin1'), before.get('index.html')?.toString('latin1'));
});

test('many pages go through the worker pool, to the bytes one thread writes', async () => {
  const make = () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-many-'));
    for (let i = 0; i < 80; i++) {
      fs.writeFileSync(path.join(dir, `p${i}.html`), `<html><head><title>Page ${i}</title></head><body><main><p>Body ${i}</p></main></body></html>`);
    }
    return dir;
  };
  const serial = make();
  await main(['--dir', serial, '--host', 'many.example.com', '--jobs', '1']);
  const dir = make();
  const report = await main(['--dir', dir, '--host', 'many.example.com', '--jobs', '3']);
  assert.match(report[0] ?? '', /80 public pages/);
  same(tree(dir), tree(serial));
  for (let i = 0; i < 80; i++) {
    assert.equal(fs.readFileSync(path.join(dir, `p${i}.md`), 'utf8'), `# Page ${i}\n\nBody ${i}\n`);
    assert.match(fs.readFileSync(path.join(dir, `p${i}.html`), 'utf8'), new RegExp(`href="/p${i}\\.md"></head>`));
  }
});

test('refuses what it cannot do, before touching anything', async () => {
  const dir = copy('bare');
  const before = tree(dir);
  await assert.rejects(main(['--dir', dir]), /usage: agent/);
  await assert.rejects(main(['--dir', dir, '--host', 'https://bare.example.com']), /not a lowercase hostname/);
  await assert.rejects(main(['--dir', path.join(dir, 'nope'), '--host', 'bare.example.com']), /not a directory/);
  await assert.rejects(main(['--dir', dir, '--host', 'bare.example.com', '--jobs', '0']), /positive integer/);
  await assert.rejects(main(['--dir', dir, '--host', 'bare.example.com', '--bogus']), /Unknown option/);
  same(tree(dir), before);
});
