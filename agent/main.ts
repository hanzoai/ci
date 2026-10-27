// agent: makes a built static bundle readable by AI agents, in place.
//
//   node agent/main.ts --dir <bundle> --host <host> [--skills <dir>] [--jobs <n>]
//                      [--no-twins] [--no-links] [--no-robots] [--no-sitemap]
//                      [--no-llms] [--no-catalog] [--no-auth]
//
// What a bundle gains, each piece only where the site wrote none of its own:
//
//   <page>.md                 a Markdown twin of every public page
//   <link rel="alternate">    in each page's <head>, naming its twin
//   robots.txt                the canonical file; a site's own gains only the
//                             Content-Signal line and a Sitemap line it lacks
//   sitemap.xml               every public page's canonical URL
//   llms.txt                  the pages and where an agent goes next; a site's
//                             own gains only the line to /auth.md it lacks
//   .well-known/api-catalog   the Hanzo API catalog (RFC 9727)
//   auth.md                   how an agent signs in (agent/auth.md, one text)
//   .well-known/agent-skills/index.json   with --skills <dir> of SKILL.md files
//
// Public means served, not closed to `*` by the site's robots.txt, not noindex,
// and not an error page or framework internal (bundle.ts). Running it twice
// changes nothing the second time.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { create, pages, read, url, write } from './bundle.ts';
import { catalog } from './catalog.ts';
import { llms, merge as mergeLlms, type Entry } from './llms.ts';
import { run, type Result, type Task } from './pool.ts';
import { allowed, canonical, merge as mergeRobots, rules } from './robots.ts';
import { sitemap } from './sitemap.ts';
import { document, skills } from './skills.ts';

const pieces = ['twins', 'links', 'robots', 'sitemap', 'llms', 'catalog', 'auth'] as const;
type Piece = (typeof pieces)[number];

const usage = 'usage: agent --dir <bundle> --host <host> [--skills <dir>] [--jobs <n>] ' +
  pieces.map((p) => `[--no-${p}]`).join(' ');

const hostname = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/;

class Refusal extends Error {}

export async function main(argv: string[]): Promise<string[]> {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      strict: true,
      allowPositionals: false,
      options: {
        dir: { type: 'string' },
        host: { type: 'string' },
        skills: { type: 'string' },
        jobs: { type: 'string' },
        ...Object.fromEntries(pieces.map((p) => [`no-${p}`, { type: 'boolean' as const }])),
      },
    });
  } catch (err) {
    throw new Refusal(`${err instanceof Error ? err.message : String(err)}\n${usage}`);
  }
  const { values } = parsed;
  const dir = values.dir ? path.resolve(values.dir) : '';
  const host = values.host ?? '';
  if (!dir || !host) throw new Refusal(usage);
  if (!hostname.test(host)) throw new Refusal(`--host ${JSON.stringify(host)} is not a lowercase hostname (no scheme, no port, no path)`);
  if (!fs.statSync(dir, { throwIfNoEntry: false })?.isDirectory()) throw new Refusal(`--dir ${dir} is not a directory`);
  const jobs = values.jobs === undefined ? Math.min(os.availableParallelism(), 8) : Number(values.jobs);
  if (!Number.isInteger(jobs) || jobs < 1) throw new Refusal(`--jobs ${values.jobs} is not a positive integer`);
  const on = (p: Piece) => !(values as Record<string, unknown>)[`no-${p}`];
  const at = (rel: string) => path.join(dir, rel);
  const report: string[] = [];
  const say = (piece: string, what: string) => report.push(`  ${piece}: ${what}`);

  // Which pages are public, by the site's own robots.txt as it stands.
  const robotsText = read(at('robots.txt'));
  const closedTo = robotsText === undefined ? [] : rules(robotsText);
  const found = pages(dir);
  const open = found.pages.filter((p) => allowed(closedTo, new URL(url(host, p.path)).pathname));
  const tasks: Task[] = open.map((p) => ({
    file: p.file,
    twin: p.twin,
    url: url(host, p.path),
    base: p.path !== '/' && p.file.endsWith('/index.html') ? url(host, p.path + '/') : url(host, p.path),
    href: '/' + p.twin,
    twins: on('twins'),
    links: on('links'),
  }));
  const results: Result[] = await run(dir, tasks, jobs);
  const pub = results.map((r, i) => ({ r, task: tasks[i] as Task })).filter(({ r }) => !r.noindex);
  const noindex = results.length - pub.length;
  report.push(
    `agent ${host}: ${pub.length} public page${pub.length === 1 ? '' : 's'}` +
      [
        [found.pages.length - open.length, 'closed by robots.txt'],
        [noindex, 'noindex'],
        [found.shadowed.length, 'shadowed by a directory page'],
      ]
        .filter(([n]) => n !== 0)
        .map(([n, why]) => `, ${n} ${why}`)
        .join(''),
  );
  const count = (k: 'twin' | 'link', v: string) => pub.filter(({ r }) => r[k] === v).length;
  say('twins', on('twins') ? `${count('twin', 'written')} written, ${count('twin', 'present')} present` : `off, ${count('twin', 'present')} present`);
  say('links', on('links')
    ? `${count('link', 'added')} added, ${count('link', 'present')} present${count('link', 'nohead') ? `, ${count('link', 'nohead')} pages without </head>` : ''}`
    : 'off');

  // What this host will serve once the files below are written.
  const exists = (rel: string) => fs.existsSync(at(rel));
  const have = {
    auth: exists('auth.md') || on('auth'),
    catalog: exists('.well-known/api-catalog') || on('catalog'),
    llms: exists('llms.txt') || on('llms'),
  };

  if (on('auth')) {
    say('auth.md', create(at('auth.md'), fs.readFileSync(new URL('./auth.md', import.meta.url))) ? 'written' : 'present');
  } else say('auth.md', 'off');

  if (on('catalog')) {
    say('.well-known/api-catalog', create(at('.well-known/api-catalog'), catalog(host, have)) ? 'written' : 'present');
  } else say('.well-known/api-catalog', 'off');

  if (on('sitemap')) {
    say('sitemap.xml', create(at('sitemap.xml'), sitemap(pub.map(({ task }) => task.url))) ? 'written' : 'present');
  } else say('sitemap.xml', 'off');

  if (on('llms')) {
    const text = read(at('llms.txt'));
    if (text === undefined) {
      const home = pub.find(({ task }) => task.file === 'index.html')?.r;
      const entries: Entry[] = pub.map(({ r, task }) => ({
        url: r.twin === 'absent' ? task.url : url(host, task.href),
        title: r.title,
        description: r.description,
      }));
      write(at('llms.txt'), llms(host, { title: home?.title ?? host, description: home?.description ?? '' }, entries, have));
      say('llms.txt', 'written');
    } else {
      const next = mergeLlms(text, host, have);
      if (next !== undefined) write(at('llms.txt'), next);
      say('llms.txt', next === undefined ? 'present' : 'present, /auth.md line added');
    }
  } else say('llms.txt', 'off');

  if (values.skills !== undefined) {
    const index = '.well-known/agent-skills/index.json';
    if (exists(index)) say(index, 'present');
    else {
      const s = skills(path.resolve(values.skills), dir);
      if (!s.skills.length) throw new Refusal(`--skills ${values.skills} holds no valid SKILL.md`);
      write(at(index), document(s.skills));
      say(index, `written, ${s.skills.length} skills (${s.copied} copied into .well-known/agent-skills)`);
      for (const why of s.skipped) say('skipped skill', why);
    }
  }

  if (on('robots')) {
    if (robotsText === undefined) {
      write(at('robots.txt'), canonical(host));
      say('robots.txt', 'written');
    } else {
      const next = mergeRobots(robotsText, host);
      if (next !== undefined) write(at('robots.txt'), next.text);
      say('robots.txt', next === undefined ? 'present' : `present, added ${next.added.join(' and ')}`);
    }
  } else say('robots.txt', 'off');

  return report;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main(process.argv.slice(2)).then(
    (report) => console.log(report.join('\n')),
    (err: unknown) => {
      console.error(`agent: ${err instanceof Refusal ? err.message : err instanceof Error ? err.stack ?? err.message : String(err)}`);
      process.exit(err instanceof Refusal ? 2 : 1);
    },
  );
}
