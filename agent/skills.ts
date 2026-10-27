// /.well-known/agent-skills/index.json (cloudflare/agent-skills-discovery-rfc
// v0.2.0) from a directory of SKILL.md files. Each skill's url is the file the
// site serves and its digest is the SHA-256 of those bytes: a SKILL.md inside
// the bundle is served where it is, one outside it is copied to
// /.well-known/agent-skills/<name>/SKILL.md.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { create } from './bundle.ts';

export const schema = 'https://schemas.agentskills.io/discovery/0.2.0/schema.json';

export type Skill = { name: string; type: 'skill-md'; description: string; url: string; digest: string };

// The two frontmatter keys an index reads, from the YAML a SKILL.md opens
// with: plain, single- and double-quoted scalars, and | and > blocks.
export function frontmatter(text: string): Map<string, string> {
  const out = new Map<string, string>();
  const rows = text.replace(/^﻿/, '').split(/\r?\n/);
  if (rows[0]?.trim() !== '---') return out;
  const end = rows.findIndex((r, i) => i > 0 && /^(---|\.\.\.)\s*$/.test(r));
  if (end < 0) return out;
  const body = rows.slice(1, end);
  for (let i = 0; i < body.length; i++) {
    const m = /^([A-Za-z_][\w-]*):(?:\s+(.*))?$/.exec(body[i] ?? '');
    if (!m) continue;
    const key = m[1] ?? '';
    let v = (m[2] ?? '').trim();
    // The lines that continue this value: indented, or blank.
    const more: string[] = [];
    while (i + 1 < body.length && /^(\s+\S|\s*$)/.test(body[i + 1] ?? '')) more.push(body[++i] ?? '');
    while (more.length && (more[more.length - 1] ?? '').trim() === '') more.pop();
    const block = /^([|>])([+-]?)\d*\s*(#.*)?$/.exec(v);
    if (block) {
      const lines = more.map((l) => l.trim());
      v = block[1] === '|' ? lines.join('\n') : fold(lines);
    } else if (v.startsWith('"')) {
      const raw = [v, ...more.map((l) => l.trim())].join(' ');
      try {
        v = JSON.parse(raw.replace(/\\'/g, "'")) as string;
      } catch {
        v = raw.replace(/^"|"$/g, '');
      }
    } else if (v.startsWith("'")) {
      v = [v, ...more.map((l) => l.trim())].join(' ').replace(/^'|'$/g, '').replace(/''/g, "'");
    } else {
      // A plain scalar ends at a comment.
      v = fold([v, ...more.map((l) => l.trim())]).replace(/\s+#.*$/, '');
    }
    out.set(key, v.trim());
  }
  return out;
}

// YAML folding: lines join with a space, a blank line is a newline.
function fold(lines: string[]): string {
  return lines.reduce((acc, l) => (l === '' ? acc + '\n' : acc === '' || acc.endsWith('\n') ? acc + l : acc + ' ' + l), '');
}

const valid = /^[a-z0-9]+(-[a-z0-9]+)*$/;

function find(dir: string, out: string[]): void {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('.') || e.name === 'node_modules') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) find(p, out);
    else if (e.isFile() && e.name === 'SKILL.md') out.push(p);
  }
}

export function skills(src: string, bundle: string): { skills: Skill[]; copied: number; skipped: string[] } {
  const files: string[] = [];
  find(src, files);
  files.sort();
  const root = path.resolve(bundle);
  const seen = new Set<string>();
  const out: Skill[] = [];
  const skipped: string[] = [];
  let copied = 0;
  for (const f of files) {
    const fm = frontmatter(fs.readFileSync(f, 'utf8'));
    const name = fm.get('name') ?? '';
    const description = (fm.get('description') ?? '').trim();
    const rel = path.relative(src, f);
    if (!valid.test(name) || name.length > 64) {
      skipped.push(`${rel}: name ${JSON.stringify(name)} is not 1-64 of a-z, 0-9 and single hyphens`);
      continue;
    }
    if (!description) {
      skipped.push(`${rel}: no description`);
      continue;
    }
    if (description.length > 1024) {
      skipped.push(`${rel}: description is ${description.length} characters, over 1024`);
      continue;
    }
    if (seen.has(name)) {
      skipped.push(`${rel}: ${name} is named twice`);
      continue;
    }
    seen.add(name);
    const abs = path.resolve(f);
    let served = abs;
    if (!abs.startsWith(root + path.sep)) {
      served = path.join(root, '.well-known', 'agent-skills', name, 'SKILL.md');
      if (create(served, fs.readFileSync(abs))) copied++;
    }
    const url = '/' + path.relative(root, served).split(path.sep).join('/');
    const digest = 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(served)).digest('hex');
    out.push({ name, type: 'skill-md', description, url, digest });
  }
  out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return { skills: out, copied, skipped };
}

export function document(list: Skill[]): string {
  return JSON.stringify({ $schema: schema, skills: list }, null, 2) + '\n';
}
