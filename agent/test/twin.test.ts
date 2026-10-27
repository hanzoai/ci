import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { locate, pages } from '../bundle.ts';
import { decode, inject, markdown, meta } from '../twin.ts';

const page = (head: string, body: string) => `<!doctype html><html><head>${head}</head><body>${body}</body></html>`;
const md = (html: string, url = 'https://example.com/p') => markdown(html, url, url, meta(html));

test('the head is read without the body', () => {
  const m = meta(page(
    '<title>A &amp; B</title><meta content="Desc &quot;q&quot;" name="Description"><meta name="robots" content="index"><link rel="alternate" type="application/rss+xml" href="/rss">',
    '<meta name="robots" content="noindex">',
  ));
  assert.deepEqual(m, { title: 'A & B', description: 'Desc "q"', noindex: false, alternate: false });
  assert.equal(meta(page('<meta property="og:description" content="From og">', '')).description, 'From og');
  assert.equal(meta(page("<meta name='robots' content='NONE'>", '')).noindex, true);
  assert.equal(meta(page('<link href="/a.md" type="text/markdown; charset=utf-8" rel="Alternate">', '')).alternate, true);
});

test('the link goes in before </head> and every other byte stays', () => {
  const raw = Buffer.concat([Buffer.from('<html><HEAD><title>x</title>\r\n</Head ><body>\xe9</body>', 'latin1'), Buffer.from([0xff, 0x00])]);
  const got = inject(raw, '/a.md');
  const tag = '<link rel="alternate" type="text/markdown" href="/a.md">';
  assert.ok(got);
  const at = raw.indexOf('</Head');
  assert.deepEqual(got.subarray(0, at), raw.subarray(0, at));
  assert.equal(got.subarray(at, at + tag.length).toString('latin1'), tag);
  assert.deepEqual(got.subarray(at + tag.length), raw.subarray(at));
  assert.equal(inject(Buffer.from('<p>no head</p>'), '/a.md'), null);
});

test('a declared charset decides, and bytes that are not UTF-8 read as windows-1252', () => {
  assert.equal(decode(Buffer.from('<meta charset="iso-8859-1"><p>caf\xe9</p>', 'latin1')), '<meta charset="iso-8859-1"><p>café</p>');
  assert.equal(decode(Buffer.from('<p>caf\xe9 \x80</p>', 'latin1')), '<p>café €</p>');
  assert.equal(decode(Buffer.from('<p>café</p>', 'utf8')), '<p>café</p>');
});

test('main content: chrome is cut, links are absolute, the title is not said twice', () => {
  const got = md(page(
    '<title>Guide | Site</title><meta name="description" content="The lede.">',
    '<header><a href="/">Site</a></header><nav><a href="/x">X</a></nav><main><h1>Guide</h1><p>The lede.</p>' +
      '<p>Go <a href="/next">next</a>, <a href="../up">up</a> or <a href="#here">here</a>.</p>' +
      '<h2 id="here"><a href="#here">Here</a></h2><aside>Related</aside><div id="cookie-banner">Cookies</div>' +
      '<div aria-hidden="true">decor</div><p role="search">find</p></main><footer>F</footer>',
  ), 'https://example.com/a/guide');
  assert.equal(got, '# Guide | Site\n\n> The lede.\n\nGo [next](https://example.com/next), [up](https://example.com/up) or [here](https://example.com/a/guide#here).\n\n## Here\n');
});

test('without <main> the body is the content, minus its header and footer', () => {
  const got = md(page('<title>T</title>', '<header>Top</header><div><p>Body</p><ul><li>one</li><li>two<ol><li>a</li></ol></li></ul></div><footer>Bottom</footer>'));
  assert.equal(got, '# T\n\nBody\n\n- one\n- two\n  1. a\n');
});

test('tables are GFM tables, code keeps its text and language', () => {
  const got = md(page('<title>T</title>',
    '<main><table><tr><th>a|b</th><th>c</th></tr><tr><td><p>x</p><p>y</p></td><td></td></tr></table>' +
      '<pre data-language="go"><code><span>fmt</span>.Println(<span>"```"</span>)</code></pre></main>'));
  assert.equal(got, '# T\n\n| a\\|b | c |\n| --- | --- |\n| x y |  |\n\n````go\nfmt.Println("```")\n````\n');
});

test('a shell with no content still says what it links to', () => {
  const got = md(page('<title>App</title><meta name="description" content="Rendered in the browser.">',
    '<nav><a href="/a">A</a><a href="/a">A</a><a href="javascript:x()">J</a></nav><div id="root"></div>'));
  assert.equal(got, '# App\n\n> Rendered in the browser.\n\n## Links\n\n- [A](https://example.com/a)\n');
});

test('pages, their canonical paths and their twins', () => {
  assert.deepEqual(locate('index.html'), { file: 'index.html', path: '/', twin: 'index.md' });
  assert.deepEqual(locate('a/b/index.html'), { file: 'a/b/index.html', path: '/a/b', twin: 'a/b.md' });
  assert.deepEqual(locate('a/b.html'), { file: 'a/b.html', path: '/a/b', twin: 'a/b.md' });
  assert.deepEqual(locate('models/hanzo/zen5.8.html'), { file: 'models/hanzo/zen5.8.html', path: '/models/hanzo/zen5.8', twin: 'models/hanzo/zen5.8.md' });
  assert.equal(locate('404.html'), null);
  assert.equal(locate('docs/500/index.html'), null);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-pages-'));
  for (const f of ['a.html', 'a/index.html', '_next/x.html', '.well-known/x.html', 'b/_hidden.html', 'c.htm', 'node_modules/x.html']) {
    fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true });
    fs.writeFileSync(path.join(dir, f), '<html></html>');
  }
  // The plane serves /a from a/index.html first, so that is the page.
  assert.deepEqual(pages(dir), { pages: [{ file: 'a/index.html', path: '/a', twin: 'a.md' }], shadowed: ['a.html'] });
});
