// One page's work, and the threads that do it for a whole bundle. A docs
// export is thousands of pages of tens of milliseconds each, so they run on a
// bounded set of worker threads; this file is also each worker's entry.

import fs from 'node:fs';
import path from 'node:path';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { create, write } from './bundle.ts';
import { decode, inject, markdown, meta } from './twin.ts';

export type Task = {
  file: string; // the page, relative to the bundle
  twin: string; // its twin, relative
  url: string; // canonical address
  base: string; // what its relative links resolve against
  href: string; // the twin's path on the site, for the <link>
  twins: boolean; // write a twin when it has none
  links: boolean; // add the <link> when it has a twin and lacks one
};

export type Result = {
  file: string;
  title: string;
  description: string;
  noindex: boolean;
  twin: 'written' | 'present' | 'absent';
  link: 'added' | 'present' | 'nohead' | 'none';
};

export function work(dir: string, t: Task): Result {
  const file = path.join(dir, t.file);
  const buf = fs.readFileSync(file);
  const html = decode(buf);
  const m = meta(html);
  const r: Result = { file: t.file, title: m.title, description: m.description, noindex: m.noindex, twin: 'absent', link: 'none' };
  if (m.noindex) return r;
  const twin = path.join(dir, t.twin);
  if (fs.existsSync(twin)) r.twin = 'present';
  else if (t.twins) r.twin = create(twin, markdown(html, t.url, t.base, m)) ? 'written' : 'present';
  if (m.alternate) r.link = 'present';
  else if (t.links && r.twin !== 'absent') {
    const next = inject(buf, t.href);
    if (next) {
      write(file, next, fs.statSync(file).mode & 0o7777);
      r.link = 'added';
    } else r.link = 'nohead';
  }
  return r;
}

// Every task, on at most `jobs` threads. A bundle small enough that starting a
// thread costs more than its pages runs here instead.
export async function run(dir: string, tasks: Task[], jobs: number): Promise<Result[]> {
  if (jobs <= 1 || tasks.length <= 32) return tasks.map((t) => work(dir, t));
  const out: Result[] = new Array(tasks.length);
  let next = 0;
  const n = Math.min(jobs, Math.ceil(tasks.length / 16));
  await Promise.all(
    Array.from({ length: n }, () =>
      new Promise<void>((resolve, reject) => {
        const w = new Worker(new URL(import.meta.url), { workerData: { agent: dir } });
        const give = () => {
          if (next >= tasks.length) {
            void w.terminate().then(() => resolve());
            return;
          }
          const i = next++;
          w.postMessage({ i, task: tasks[i] });
        };
        w.on('message', (msg: { i: number; result?: Result; error?: string }) => {
          if (msg.error !== undefined) {
            reject(new Error(`${tasks[msg.i]?.file}: ${msg.error}`));
            void w.terminate();
            return;
          }
          if (msg.result) out[msg.i] = msg.result;
          give();
        });
        w.on('error', reject);
        w.on('online', give);
      }),
    ),
  );
  return out;
}

if (!isMainThread && parentPort && typeof (workerData as { agent?: unknown })?.agent === 'string') {
  const dir = (workerData as { agent: string }).agent;
  const port = parentPort;
  port.on('message', ({ i, task }: { i: number; task: Task }) => {
    try {
      port.postMessage({ i, result: work(dir, task) });
    } catch (err) {
      port.postMessage({ i, error: err instanceof Error ? err.message : String(err) });
    }
  });
}
