// The pages of a built static bundle, and how a file in it is written.
//
// A page is an HTML file the edge serves at a canonical path. The Sites plane
// answers `/a` from `a/index.html` first and `a.html` second (bin/smoke), so
// that is the order a collision between the two is settled in. Framework
// internals are not pages: any path segment starting with `_` (`_next/`,
// `_not-found.html`, `_site/`), any dot directory (`.well-known/`), and the
// error pages 404 and 500.

import fs from 'node:fs';
import path from 'node:path';

export type Page = {
  file: string; // relative to the bundle, forward slashes: `a/b/index.html`
  path: string; // the canonical path it is served at: `/a/b`
  twin: string; // its Markdown twin, relative: `a/b.md` (`index.md` for `/`)
};

const errors = new Set(['404', '500']);

// Every page, sorted by canonical path, plus the files that lost a collision.
export function pages(dir: string): { pages: Page[]; shadowed: string[] } {
  const found: Page[] = [];
  walk(dir, '', found);
  const byPath = new Map<string, Page>();
  const shadowed: string[] = [];
  // `a/index.html` sorts after `a.html`; it is the one the plane serves.
  found.sort((x, y) => rank(x) - rank(y) || cmp(x.file, y.file));
  for (const p of found) {
    if (byPath.has(p.path)) shadowed.push(p.file);
    else byPath.set(p.path, p);
  }
  const out = [...byPath.values()].sort((x, y) => cmp(x.path, y.path));
  return { pages: out, shadowed: shadowed.sort(cmp) };
}

function rank(p: Page): number {
  return p.file === 'index.html' || p.file.endsWith('/index.html') ? 0 : 1;
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function walk(root: string, rel: string, out: Page[]): void {
  const entries = fs.readdirSync(path.join(root, rel), { withFileTypes: true });
  for (const e of entries) {
    if (e.name.startsWith('.') || e.name.startsWith('_') || e.name === 'node_modules') continue;
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) {
      walk(root, r, out);
      continue;
    }
    if (!e.isFile() || !e.name.endsWith('.html')) continue;
    const page = locate(r);
    if (page) out.push(page);
  }
}

// The canonical path and twin of one HTML file, or null for an error page.
// A dotted name is a page like any other: `models/zen5.8.html` is `/models/zen5.8`.
export function locate(file: string): Page | null {
  const stem = file.slice(0, -'.html'.length);
  const parts = stem.split('/');
  const segs = parts[parts.length - 1] === 'index' ? parts.slice(0, -1) : parts;
  const leaf = segs[segs.length - 1];
  if (leaf !== undefined && errors.has(leaf)) return null;
  if (segs.length === 0) return { file, path: '/', twin: 'index.md' };
  return { file, path: '/' + segs.join('/'), twin: segs.join('/') + '.md' };
}

// The absolute URL a canonical path is served at.
export function url(host: string, p: string): string {
  return new URL(p, `https://${host}`).href;
}

// Replaces a file by rename, so a reader never sees half of it and a file the
// build hardlinked into a second bundle (`cp -al out out-bot`) changes in this
// bundle alone rather than through the shared inode.
export function write(file: string, data: string | Buffer, mode?: number): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.agent-${process.pid}-${Math.random().toString(36).slice(2)}`;
  fs.writeFileSync(tmp, data, { mode: mode ?? 0o644 });
  try {
    fs.renameSync(tmp, file);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

// A file the tool may create: true when it was absent and is now written. The
// exclusive open is the absence check, so a file the site wrote is never
// replaced, and a new file needs no rename.
export function create(file: string, data: string | Buffer): boolean {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  try {
    fs.writeFileSync(file, data, { flag: 'wx', mode: 0o644 });
    return true;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'EEXIST') return false;
    throw err;
  }
}

export function read(file: string): string | undefined {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw err;
  }
}
