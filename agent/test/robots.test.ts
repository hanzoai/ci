import assert from 'node:assert/strict';
import { test } from 'node:test';
import { allowed, canonical, merge, rules, signal } from '../robots.ts';

test('the * group decides, longest pattern first, Allow on a tie', () => {
  const rs = rules([
    'User-agent: GPTBot',
    'Disallow: /',
    '',
    'User-agent: *',
    'Disallow: /private',
    'Allow: /private/open',
    'Disallow: /*.pdf$',
    'Disallow: /*?session=',
    'Disallow:',
    '',
    'user-agent: *',
    'disallow: /tmp # a comment',
    'Allow: /same',
    'Disallow: /same',
  ].join('\n'));
  assert.equal(allowed(rs, '/'), true);
  assert.equal(allowed(rs, '/private'), false);
  assert.equal(allowed(rs, '/private/x'), false);
  assert.equal(allowed(rs, '/private/open/x'), true);
  assert.equal(allowed(rs, '/a/b.pdf'), false);
  assert.equal(allowed(rs, '/a/b.pdf/x'), true);
  assert.equal(allowed(rs, '/a?session=1'), false);
  assert.equal(allowed(rs, '/tmp/x'), false);
  assert.equal(allowed(rs, '/same'), true);
  // GPTBot's own group closes everything to it, and nothing to everyone else.
  assert.equal(rules('User-agent: GPTBot\nDisallow: /\n').length, 0);
});

test('a site file gains the content signal inside its first * group, and a Sitemap', () => {
  const site = '# ours\nUser-Agent: *\nUser-Agent: Foo\nAllow: /\nDisallow: /auth\n\nUser-agent: Bytespider\nDisallow: /\n';
  const got = merge(site, 'example.com');
  assert.deepEqual(got?.added, ['Content-Signal', 'Sitemap']);
  assert.equal(
    got?.text,
    `# ours\nUser-Agent: *\nUser-Agent: Foo\n${signal}\nAllow: /\nDisallow: /auth\n\nUser-agent: Bytespider\nDisallow: /\n\nSitemap: https://example.com/sitemap.xml\n`,
  );
  assert.equal(merge(got?.text ?? '', 'example.com'), undefined);
});

test('a file with both lines is left byte for byte', () => {
  assert.equal(merge(`User-agent: *\n${signal}\nAllow: /\nSitemap: https://x.example/s.xml`, 'example.com'), undefined);
});

test('CRLF stays CRLF, and a Sitemap elsewhere is not added again', () => {
  const got = merge('User-agent: *\r\nDisallow: /a\r\n\r\nSitemap: https://example.com/sitemap.xml\r\n', 'example.com');
  assert.equal(got?.text, `User-agent: *\r\n${signal}\r\nDisallow: /a\r\n\r\nSitemap: https://example.com/sitemap.xml\r\n`);
});

test('a file with no * group gets one that allows what no group closed', () => {
  const got = merge('# managed comments only\n', 'example.com');
  assert.equal(got?.text, `# managed comments only\n\nUser-agent: *\n${signal}\nAllow: /\n\nSitemap: https://example.com/sitemap.xml\n`);
  const named = merge('User-agent: GPTBot\nDisallow: /x\nSitemap: https://example.com/sitemap.xml\n', 'example.com');
  assert.equal(named?.text, `User-agent: *\n${signal}\nAllow: /\n\nUser-agent: GPTBot\nDisallow: /x\nSitemap: https://example.com/sitemap.xml\n`);
  assert.deepEqual(rules(named?.text ?? ''), [{ allow: true, pattern: '/' }]);
});

test('the canonical file names every AI crawler Allow and leaves Bytespider unnamed', () => {
  const text = canonical('example.com');
  for (const c of ['GPTBot', 'ClaudeBot', 'Claude-SearchBot', 'Meta-ExternalAgent', 'Googlebot', 'PerplexityBot']) {
    assert.match(text, new RegExp(`^User-agent: ${c}$`, 'm'));
  }
  assert.doesNotMatch(text, /Bytespider/);
  assert.match(text, /^User-agent: \*\nContent-Signal: search=yes, ai-input=yes, ai-train=yes\nAllow: \/$/m);
  assert.match(text, /\nSitemap: https:\/\/example\.com\/sitemap\.xml\n$/);
  assert.equal(merge(text, 'example.com'), undefined);
});
