// llms.txt, the API catalog, the skills index and the canonical auth.md.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { catalog } from '../catalog.ts';
import { merge } from '../llms.ts';
import { frontmatter } from '../skills.ts';

const both = { auth: true, catalog: true };

test("a site's own llms.txt gains the /auth.md line at the end of its For agents section", () => {
  const text = '# S\n\n## For agents\n\n- [A](https://a)\n\n\n## Docs\n\n- [D](https://d)\n';
  const got = merge(text, 'example.com', both) ?? '';
  assert.equal(got, '# S\n\n## For agents\n\n- [A](https://a)\n- [Sign in as an agent](https://example.com/auth.md): a wallet with no person, the device flow (`hanzo auth login`), API keys, and OpenID Connect at hanzo.id.\n\n\n## Docs\n\n- [D](https://d)\n');
  assert.equal(merge(got, 'example.com', both), undefined);
});

test('a For agents section at the end of a file without a final newline', () => {
  const got = merge('# S\r\n\r\n## For agents\r\n\r\n- [A](https://a)', 'example.com', both) ?? '';
  assert.match(got, /^# S\r\n\r\n## For agents\r\n\r\n- \[A\]\(https:\/\/a\)\r\n- \[Sign in as an agent\]\(https:\/\/example\.com\/auth\.md\)[^\r\n]*\r\n$/);
});

test('a file with no For agents section gets one, after every byte it had', () => {
  const text = '# S\n\n> d\n\n## Docs\n\n- [D](https://d)';
  const got = merge(text, 'example.com', { auth: true, catalog: false }) ?? '';
  assert.ok(got.startsWith(text + '\n\n## For agents\n\n- [Sign in as an agent](https://example.com/auth.md)'));
  assert.doesNotMatch(got, /api-catalog/);
});

test('the section goes before ## Optional, which llmstxt.org keeps last', () => {
  const got = merge('# S\n\n## Docs\n\n- [D](https://d)\n\n## Optional\n\n- [All](https://all)\n', 'example.com', both) ?? '';
  assert.match(got, /^# S\n\n## Docs\n\n- \[D\]\(https:\/\/d\)\n\n## For agents\n\n- \[Sign in[^\n]*\n(- [^\n]*\n)+\n## Optional\n\n- \[All\]\(https:\/\/all\)\n$/);
});

test('nothing is linked that this host does not serve', () => {
  assert.equal(merge('# S\n', 'example.com', { auth: false, catalog: true }), undefined);
  assert.equal(merge('# S\nSee https://example.com/auth.md\n', 'example.com', both), undefined);
  assert.doesNotMatch(catalog('example.com', { auth: false, catalog: true, llms: false }), /example\.com/);
  const all = catalog('example.com', { auth: true, catalog: true, llms: true });
  assert.match(all, /https:\/\/example\.com\/auth\.md/);
  assert.match(all, /https:\/\/example\.com\/llms\.txt/);
});

test('the catalog is an RFC 9727 linkset whose API entry names its description, docs, metadata and status', () => {
  const doc = JSON.parse(catalog('example.com', { auth: true, catalog: true, llms: true })) as { linkset: Array<Record<string, unknown>> };
  const api = doc.linkset.find((l) => l.anchor === 'https://api.hanzo.ai/v1');
  assert.ok(api);
  for (const rel of ['service-desc', 'service-doc', 'service-meta', 'status']) assert.ok(Array.isArray(api[rel]), rel);
});

test('SKILL.md frontmatter: plain, quoted, folded and literal', () => {
  assert.deepEqual(Object.fromEntries(frontmatter('---\nname: a\ndescription: x, y # c\n---\nbody')), { name: 'a', description: 'x, y' });
  assert.equal(frontmatter("---\ndescription: 'it''s'\n---\n").get('description'), "it's");
  assert.equal(frontmatter('---\ndescription: "a\\nb \\"q\\""\n---\n').get('description'), 'a\nb "q"');
  assert.equal(frontmatter('---\ndescription: >\n  one\n  two\n\n  three\nname: n\n---\n').get('description'), 'one two\nthree');
  assert.equal(frontmatter('---\ndescription: |-\n  one\n  two\n---\n').get('description'), 'one\ntwo');
  assert.equal(frontmatter('---\ndescription: plain\n  continued\n---\n').get('description'), 'plain continued');
  assert.equal(frontmatter('﻿---\r\nname: bom\r\n---\r\n').get('name'), 'bom');
  assert.equal(frontmatter('# none\n').size, 0);
  assert.equal(frontmatter('---\nname: open\n').size, 0);
});

test('auth.md names what answers, opens as auth.md, and holds no secret', () => {
  const text = fs.readFileSync(new URL('../auth.md', import.meta.url), 'utf8');
  assert.match(text, /^# auth\.md\n/);
  for (const must of [
    'https://api.hanzo.ai/.well-known/oauth-protected-resource',
    'https://hanzo.id/.well-known/openid-configuration',
    'https://hanzo.id/v1/iam/web3/nonce',
    'https://hanzo.id/v1/iam/web3/verify',
    'https://hanzo.id/v1/iam/oauth/token',
    'https://hanzo.id/v1/iam/oauth/device',
    'https://api.hanzo.ai/v1/account/keys',
    'https://hanzo.id/v1/iam/oauth/authorize',
    'hanzo auth login',
    '## Scopes',
  ]) assert.ok(text.includes(must), must);
  assert.doesNotMatch(text, /\b(sk|pk)-[A-Za-z0-9]{8,}/);
  assert.doesNotMatch(text, /TODO|TBD|placeholder/i);
});
