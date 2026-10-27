// sweep: fetches every URL a site's sitemap.xml and llms.txt name, as the
// crawlers that read them, and prints each one that does not answer 2xx with
// the file that linked it. Six requests at a time, so a sweep is never load.
//
//   node agent/sweep.ts <host | origin> [--from <file>]... [--jobs <n>]
//
//   node agent/sweep.ts hanzo.ai
//   node agent/sweep.ts hanzo.ai --from redirects.txt  # and every URL in a file
//   node agent/sweep.ts http://127.0.0.1:8787          # a local preview of a bundle
//
// --from adds the URLs of a file, one per line (a redirect table's sources, a
// crawler log's paths); a path is read against the site. A redirect is
// followed, as a crawler follows it, and what counts is where it ends. Exit 1
// when any request failed, 2 when the site cannot be read at all.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

export const agents: Record<string, string> = {
  ClaudeBot: 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)',
  'Meta-ExternalAgent': 'meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)',
  Googlebot: 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
};

export type Answer = { status: number; final: string; error?: string };
export type Failure = { url: string; agent: string; answer: Answer; from: string[] };

const timeout = 30_000;

// One GET as `agent`, redirects followed by hand so the last hop is known.
export async function get(url: string, agent: string): Promise<Answer> {
  let at = url;
  for (let hop = 0; hop < 6; hop++) {
    let res: Response;
    try {
      res = await fetch(at, { redirect: 'manual', headers: { 'user-agent': agent, accept: '*/*' }, signal: AbortSignal.timeout(timeout) });
    } catch (err) {
      return { status: 0, final: at, error: err instanceof Error ? (err.cause instanceof Error ? err.cause.message : err.message) : String(err) };
    }
    await res.body?.cancel();
    const loc = res.headers.get('location');
    if (res.status >= 300 && res.status < 400 && loc) {
      at = new URL(loc, at).href;
      continue;
    }
    return { status: res.status, final: at };
  }
  return { status: 0, final: at, error: 'more than five redirects' };
}

async function text(url: string): Promise<string | undefined> {
  try {
    const res = await fetch(url, { headers: { 'user-agent': agents.Googlebot ?? '' }, signal: AbortSignal.timeout(timeout) });
    return res.ok ? await res.text() : undefined;
  } catch {
    return undefined;
  }
}

// The URLs a sitemap names, through sitemap indexes two deep.
async function sitemap(url: string, depth: number, out: Map<string, Set<string>>): Promise<boolean> {
  const xml = await text(url);
  if (xml === undefined) return false;
  const locs = [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => unxml(m[1] ?? ''));
  if (/<sitemapindex\b/.test(xml) && depth < 2) {
    for (const loc of locs) await sitemap(loc, depth + 1, out);
  } else for (const loc of locs) link(out, loc, url);
  return true;
}

function unxml(s: string): string {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}

// `from` names the file that links it; `base` is what a relative URL in it is
// read against, the file's own address unless that is a local file.
function link(out: Map<string, Set<string>>, url: string, from: string, base = from): void {
  let u: URL;
  try {
    u = new URL(url, base);
  } catch {
    return;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return;
  u.hash = '';
  const set = out.get(u.href) ?? new Set<string>();
  set.add(from);
  out.set(u.href, set);
}

// The URLs an llms.txt links: Markdown links, autolinks and bare URLs in its
// prose. A URL in code (`POST https://…/v1/mcp`) is an instruction, not a link.
export function llmsLinks(body: string, from: string, out: Map<string, Set<string>>): void {
  const prose = body.replace(/^(```|~~~)[\s\S]*?^\1/gm, '').replace(/`[^`\n]*`/g, '');
  for (const m of prose.matchAll(/\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) link(out, m[1] ?? '', from);
  for (const m of prose.matchAll(/<(https?:\/\/[^>\s]+)>/g)) link(out, m[1] ?? '', from);
  for (const m of prose.matchAll(/(?<![(<])\bhttps?:\/\/[^\s<>()"'`\]]+/g)) link(out, (m[0] ?? '').replace(/[.,;:!?]+$/, ''), from);
}

export async function sweep(origin: string, jobs: number, extra: Array<{ file: string; body: string }> = []): Promise<{ urls: number; requests: number; failures: Failure[]; read: string[] }> {
  const links = new Map<string, Set<string>>();
  const read: string[] = [];
  const map = new URL('/sitemap.xml', origin).href;
  if (await sitemap(map, 0, links)) read.push(map);
  const llmsUrl = new URL('/llms.txt', origin).href;
  const llms = await text(llmsUrl);
  if (llms !== undefined) {
    llmsLinks(llms, llmsUrl, links);
    read.push(llmsUrl);
  }
  for (const { file, body } of extra) {
    for (const line of body.split(/\r?\n/)) {
      const u = line.trim().split(/\s+/)[0] ?? '';
      if (u && !u.startsWith('#')) link(links, u, file, origin);
    }
    read.push(file);
  }
  const work: Array<{ url: string; agent: string }> = [];
  for (const url of [...links.keys()].sort()) for (const agent of Object.keys(agents)) work.push({ url, agent });
  const failures: Failure[] = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(jobs, work.length) }, async () => {
    while (next < work.length) {
      const w = work[next++];
      if (!w) break;
      const answer = await get(w.url, agents[w.agent] ?? w.agent);
      if (answer.status < 200 || answer.status > 299) failures.push({ ...w, answer, from: [...(links.get(w.url) ?? [])].sort() });
    }
  }));
  failures.sort((a, b) => (a.url < b.url ? -1 : a.url > b.url ? 1 : a.agent < b.agent ? -1 : 1));
  return { urls: links.size, requests: work.length, failures, read };
}

// One line per failing URL: its status, the agents it failed for, where it
// ended when it redirected, and the files that link it.
export function lines(failures: Failure[]): string[] {
  const byUrl = new Map<string, Failure[]>();
  for (const f of failures) byUrl.set(f.url, [...(byUrl.get(f.url) ?? []), f]);
  const out: string[] = [];
  for (const [url, fs] of byUrl) {
    const first = fs[0] as Failure;
    const status = [...new Set(fs.map((f) => (f.answer.status === 0 ? `ERR ${f.answer.error ?? ''}`.trim() : String(f.answer.status))))].join('/');
    const ended = first.answer.final !== url ? ` -> ${first.answer.final}` : '';
    out.push(`${status} ${url}${ended}  [${fs.map((f) => f.agent).join(', ')}]  <- ${first.from.join(', ')}`);
  }
  return out;
}

function origin(arg: string): string {
  return new URL(/^https?:\/\//.test(arg) ? arg : `https://${arg}`).origin;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: { jobs: { type: 'string', default: '6' }, from: { type: 'string', multiple: true } },
  });
  const jobs = Number(values.jobs);
  if (positionals.length !== 1 || !Number.isInteger(jobs) || jobs < 1) {
    console.error('usage: sweep <host | origin> [--from <file>]... [--jobs <n>]');
    process.exit(2);
  }
  const site = origin(positionals[0] ?? '');
  const extra = (values.from ?? []).map((file) => ({ file, body: fs.readFileSync(file, 'utf8') }));
  const r = await sweep(site, jobs, extra);
  if (!r.read.length) {
    console.error(`sweep ${site}: neither /sitemap.xml nor /llms.txt answered 200`);
    process.exit(2);
  }
  for (const l of lines(r.failures)) console.log(l);
  console.log(`sweep ${site}: ${r.urls} URLs from ${r.read.join(' and ')}, ${r.requests} requests as ${Object.keys(agents).join(', ')}; ${r.failures.length} failed`);
  process.exit(r.failures.length ? 1 : 0);
}
