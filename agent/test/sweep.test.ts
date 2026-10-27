import assert from 'node:assert/strict';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';
import { agents, get, lines, llmsLinks, sweep } from '../sweep.ts';

test('every sitemap, llms.txt and --from URL is fetched as each crawler, six at a time, and each failure names its linker', async () => {
  let open = 0;
  let most = 0;
  const seen = new Set<string>();
  const server = http.createServer((req, res) => {
    open++;
    most = Math.max(most, open);
    seen.add(String(req.headers['user-agent']));
    const o = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const send = (code: number, body = '', headers: Record<string, string> = {}) =>
      setTimeout(() => {
        open--;
        res.writeHead(code, headers);
        res.end(body);
      }, 5);
    switch (req.url) {
      case '/sitemap.xml':
        return send(200, `<?xml version="1.0"?><sitemapindex><sitemap><loc>${o}/pages.xml</loc></sitemap></sitemapindex>`);
      case '/pages.xml':
        return send(200, `<urlset>${['/', '/a', '/gone', '/moved', '/moved-gone', '/q?x=1&amp;y=2'].map((p) => `<url><loc>${o}${p}</loc></url>`).join('')}</urlset>`);
      case '/llms.txt':
        return send(200, `# S\n\n- [A](${o}/a)\n- [Old](/old#frag): see ${o}/bare.\n- \`POST ${o}/post-only\`\n\n\`\`\`\ncurl ${o}/in-code\n\`\`\`\n`);
      case '/':
      case '/a':
      case '/q?x=1&y=2':
      case '/bare':
      case '/kept':
        return send(200, 'ok');
      case '/moved':
        return send(301, '', { location: '/a' });
      case '/moved-gone':
        return send(308, '', { location: `${o}/gone` });
      default:
        return send(404, 'missing');
    }
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const o = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  try {
    const r = await sweep(o, 6, [{ file: 'redirects.txt', body: '# old paths\n/kept 301\n/removed\n' }]);
    assert.deepEqual(r.read, [`${o}/sitemap.xml`, `${o}/llms.txt`, 'redirects.txt']);
    assert.equal(r.urls, 10);
    assert.equal(r.requests, 10 * 3);
    assert.ok(most <= 6, `at most six at once, saw ${most}`);
    for (const ua of Object.values(agents)) assert.ok(seen.has(ua), ua);
    assert.deepEqual(lines(r.failures), [
      `404 ${o}/gone  [ClaudeBot, Googlebot, Meta-ExternalAgent]  <- ${o}/pages.xml`,
      `404 ${o}/moved-gone -> ${o}/gone  [ClaudeBot, Googlebot, Meta-ExternalAgent]  <- ${o}/pages.xml`,
      `404 ${o}/old  [ClaudeBot, Googlebot, Meta-ExternalAgent]  <- ${o}/llms.txt`,
      `404 ${o}/removed  [ClaudeBot, Googlebot, Meta-ExternalAgent]  <- redirects.txt`,
    ]);
  } finally {
    server.close();
  }
});

test('a host that does not answer is a status 0 with its reason, never a crash', async () => {
  const closed = http.createServer();
  await new Promise<void>((r) => closed.listen(0, '127.0.0.1', r));
  const o = `http://127.0.0.1:${(closed.address() as AddressInfo).port}`;
  await new Promise<void>((r) => closed.close(() => r()));
  const a = await get(`${o}/x`, 'probe');
  assert.equal(a.status, 0);
  assert.match(a.error ?? '', /ECONNREFUSED/);
  const r = await sweep(o, 6);
  assert.deepEqual(r.read, []);
  assert.equal(r.requests, 0);
});

test('llms.txt links: Markdown links and prose URLs, relative ones resolved, code skipped', () => {
  const links = new Map<string, Set<string>>();
  llmsLinks('- [x](/x "t") and <https://a.example/y>, also https://b.example/z.\n`GET https://c.example/` [r](mailto:a@b)', 'https://s.example/llms.txt', links);
  assert.deepEqual([...links.keys()].sort(), ['https://a.example/y', 'https://b.example/z', 'https://s.example/x']);
});
