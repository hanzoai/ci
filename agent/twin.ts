// A page as Markdown: `# Title`, the meta description as a quote, then the
// page's meaningful content with absolute links. And the one change a page
// itself gets: a `<link rel="alternate" type="text/markdown">` before `</head>`.

import domino from '@mixmark-io/domino';
import TurndownService from 'turndown';

export type Meta = {
  title: string;
  description: string;
  noindex: boolean;
  alternate: boolean; // already names a text/markdown alternate
};

// Where `</head>` starts, or -1. Searched in latin1 so the index is a byte
// offset into the file, whatever its encoding.
export function headEnd(latin1: string): number {
  const m = /<\/head\s*>/i.exec(latin1);
  return m ? m.index : -1;
}

// A page's text. A declared charset decides; with none, UTF-8 when the bytes
// are UTF-8 and windows-1252 when they are not, which is what a browser does.
export function decode(buf: Buffer): string {
  const m = /<meta\b[^>]*charset\s*=\s*["']?\s*([\w-]+)/i.exec(buf.subarray(0, 1024).toString('latin1'));
  const label = (m?.[1] ?? '').toLowerCase();
  if (label && label !== 'utf-8' && label !== 'utf8') {
    try {
      return new TextDecoder(label).decode(buf);
    } catch {
      // A label TextDecoder does not know: read it as the bytes say below.
    }
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    return new TextDecoder('windows-1252').decode(buf);
  }
}

const attrRe = /([^\s=\/>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;

function attrs(tag: string): Map<string, string> {
  const out = new Map<string, string>();
  const body = tag.replace(/^<[a-zA-Z][\w:-]*/, '').replace(/\/?>$/, '');
  for (const m of body.matchAll(attrRe)) {
    const name = (m[1] ?? '').toLowerCase();
    if (!out.has(name)) out.set(name, m[2] ?? m[3] ?? m[4] ?? '');
  }
  return out;
}

// The head's title, description and robots directive, read without parsing the
// body: most of a page is its body, and a page that already has a twin needs
// none of it.
export function meta(html: string): Meta {
  const end = headEnd(html);
  const head = end < 0 ? html : html.slice(0, end);
  const t = /<title\b[^>]*>([\s\S]*?)<\/title\s*>/i.exec(head);
  let description = '';
  let og = '';
  let noindex = false;
  let alternate = false;
  for (const m of head.matchAll(/<(meta|link)\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    if ((m[1] ?? '').toLowerCase() === 'link') {
      const rel = (a.get('rel') ?? '').toLowerCase().split(/\s+/);
      if (rel.includes('alternate') && (a.get('type') ?? '').toLowerCase().startsWith('text/markdown')) alternate = true;
      continue;
    }
    const name = (a.get('name') ?? '').toLowerCase();
    const content = a.get('content') ?? '';
    if (name === 'description' && !description) description = content;
    if ((a.get('property') ?? '').toLowerCase() === 'og:description' && !og) og = content;
    if (name === 'robots' && /\b(noindex|none)\b/i.test(content)) noindex = true;
  }
  return {
    title: text(t?.[1] ?? ''),
    description: text(description || og),
    noindex,
    alternate,
  };
}

// Entity-decoded, whitespace-collapsed text of an HTML fragment.
function text(fragment: string): string {
  const s = fragment.includes('&') || fragment.includes('<')
    ? domino.createDocument('<p>' + fragment + '</p>').body.textContent ?? ''
    : fragment;
  return s.replace(/\s+/g, ' ').trim();
}

// The link a page gains, before `</head>`. Byte for byte the rest of the page
// is what it was. Null when the page has no head to put it in.
export function inject(page: Buffer, href: string): Buffer | null {
  const at = headEnd(page.toString('latin1'));
  if (at < 0) return null;
  const tag = Buffer.from(`<link rel="alternate" type="text/markdown" href="${href}">`, 'latin1');
  return Buffer.concat([page.subarray(0, at), tag, page.subarray(at)]);
}

// ---- the body ---------------------------------------------------------------

// Before the parse, the bytes that never become Markdown are cut: scripts
// (Next's data payload is most of an export), styles, comments, svg, and the
// class, style and data- attributes. Each code block is reduced to its text,
// so a highlighter's one span per token is not a thousand elements to parse.
// A 1 MB docs page is 37 KB by then (measured), and parses in a third of the time.
function prep(html: string): string {
  let s = html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, '')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style\s*>/gi, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<svg\b[\s\S]*?<\/svg\s*>/gi, '');
  s = s.replace(/<pre\b([^>]*)>([\s\S]*?)<\/pre\s*>/gi, (_m, a: string, inner: string) => {
    const head = a + inner.slice(0, 600);
    const lm = /\b(?:language|lang)-([\w+#.-]+)/i.exec(head) ?? /\bdata-language="([^"]+)"/i.exec(head);
    const lang = (lm?.[1] ?? '').replace(/[^\w+#.-]/g, '');
    const code = inner.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]*>/g, '');
    return `<pre data-code="${lang}"><code>${code}</code></pre>`;
  });
  // Attributes inside a start tag only, never text. A class naming a cookie or
  // consent banner is kept as a mark, so the banner can be cut after the parse.
  return s.replace(/<([a-zA-Z][\w-]*)(\s[^>]*)>/g, (_m, n: string, a: string) =>
    '<' + n + a.replace(/\s(class|style|srcset|sizes|on[a-z]+|data-(?!code\b)[\w-]+)\s*=\s*"([^"]*)"/gi,
      (_x, k: string, v: string) => (k.toLowerCase() === 'class' && /cookie|consent|gdpr/i.test(v) ? ' data-chrome=""' : '')) + '>');
}

// What is a page's chrome rather than its content. Inside <main> or <article>
// the header usually holds the page's own heading, so it stays.
const chrome = [
  'nav', 'aside', 'footer', 'form', 'dialog', 'button', 'select', 'textarea', 'input',
  'iframe', 'canvas', 'object', 'embed', 'video', 'audio', 'noscript', 'template',
  '[role="navigation"]', '[role="banner"]', '[role="contentinfo"]', '[role="complementary"]',
  '[role="dialog"]', '[role="search"]', '[aria-hidden="true"]', '[data-chrome]',
].join(',');

function strip(root: Element, whole: boolean): void {
  for (const el of Array.from(root.querySelectorAll(whole ? chrome + ',header' : chrome))) el.remove();
  for (const el of Array.from(root.querySelectorAll('[hidden]'))) {
    // Next streams a suspended boundary's content as <div hidden id="S:0">.
    if (!/^S:\d+$/.test(el.getAttribute('id') ?? '')) el.remove();
  }
  for (const el of Array.from(root.querySelectorAll('[id]'))) {
    if (/cookie|consent|gdpr/i.test(el.getAttribute('id') ?? '')) el.remove();
  }
}

// The element holding the page's content: the first non-empty <main>, else
// <article>, else role=main, else the body.
function content(doc: Document): { root: HTMLElement; whole: boolean } {
  for (const sel of ['main', 'article', '[role="main"]']) {
    for (const el of Array.from(doc.querySelectorAll(sel))) {
      if ((el.textContent ?? '').trim()) return { root: el as HTMLElement, whole: false };
    }
  }
  return { root: doc.body, whole: true };
}

function absolute(href: string, base: string): string | null {
  const h = href.trim();
  if (!h || /^(javascript|data|blob|vbscript):/i.test(h)) return null;
  try {
    return new URL(h, base).href;
  } catch {
    return null;
  }
}

function fence(code: string): string {
  let n = 3;
  for (const m of code.matchAll(/`{3,}/g)) n = Math.max(n, m[0].length + 1);
  return '`'.repeat(n);
}

function inHeading(node: Node): boolean {
  for (let p = node.parentNode; p; p = p.parentNode) {
    if (/^H[1-6]$/.test(p.nodeName)) return true;
  }
  return false;
}

function cell(content: string): string {
  return ' ' + content.replace(/\s*\n+\s*/g, ' ').replace(/\|/g, '\\|').trim() + ' |';
}

function service(base: string): TurndownService {
  const td = new TurndownService({
    headingStyle: 'atx',
    hr: '---',
    bulletListMarker: '-',
    codeBlockStyle: 'fenced',
    fence: '```',
    emDelimiter: '_',
    strongDelimiter: '**',
    linkStyle: 'inlined',
  });
  td.addRule('code', {
    filter: (node) => node.nodeName === 'PRE',
    replacement: (_c, node) => {
      const code = (node.textContent ?? '').replace(/\n+$/, '');
      const f = fence(code);
      return `\n\n${f}${(node as Element).getAttribute('data-code') ?? ''}\n${code}\n${f}\n\n`;
    },
  });
  td.addRule('link', {
    filter: (node) => node.nodeName === 'A',
    replacement: (c, node) => {
      const label = c.replace(/\s*\n+\s*/g, ' ').trim();
      if (!label) return '';
      const raw = (node as Element).getAttribute('href') ?? '';
      if (raw.startsWith('#') && inHeading(node)) return c;
      const href = absolute(raw, base);
      return href ? `[${label}](${href})` : c;
    },
  });
  // One space after the marker, where turndown pads to four.
  td.addRule('item', {
    filter: 'li',
    replacement: (c, node) => {
      const parent = node.parentNode as Element | null;
      let prefix = '- ';
      if (parent?.nodeName === 'OL') {
        const start = Number(parent.getAttribute('start') ?? '1') || 1;
        prefix = `${start + Array.prototype.indexOf.call(parent.children, node)}. `;
      }
      const body = c.replace(/^\n+/, '').replace(/\n+$/, '\n').replace(/\n/gm, '\n' + ' '.repeat(prefix.length));
      return prefix + body + (node.nextSibling && !/\n$/.test(body) ? '\n' : '');
    },
  });
  td.addRule('image', {
    filter: (node) => node.nodeName === 'IMG',
    replacement: (_c, node) => {
      const el = node as Element;
      const alt = (el.getAttribute('alt') ?? '').replace(/\s+/g, ' ').trim();
      const src = absolute(el.getAttribute('src') ?? '', base);
      return alt && src ? `![${alt.replace(/[[\]]/g, '')}](${src})` : '';
    },
  });
  td.addRule('cell', { filter: ['th', 'td'], replacement: (c) => cell(c) });
  td.addRule('row', {
    filter: 'tr',
    replacement: (c, node) => {
      const row = node as HTMLTableRowElement;
      const table = row.closest('table');
      const first = table?.querySelector('tr') === row;
      const n = row.querySelectorAll('th,td').length;
      return '\n|' + c + (first ? '\n|' + ' --- |'.repeat(Math.max(n, 1)) : '');
    },
  });
  td.addRule('section', { filter: ['thead', 'tbody', 'tfoot'], replacement: (c) => c });
  td.addRule('table', {
    filter: 'table',
    replacement: (c) => {
      const body = c.replace(/\n{2,}/g, '\n').trim();
      return body ? `\n\n${body}\n\n` : '';
    },
  });
  return td;
}

// The page as Markdown. `url` is its canonical address, the title of last
// resort; `base` is the address its relative links resolve against, which for
// a directory page (`a/index.html`, served at `/a/`) ends in a slash.
export function markdown(html: string, url: string, base: string, m: Meta): string {
  const prepped = prep(html);
  const doc = domino.createDocument(prepped);
  const declared = doc.querySelector('base[href]')?.getAttribute('href');
  const from = (declared && absolute(declared, base)) || base;
  const { root, whole } = content(doc);
  strip(root, whole);
  let body = service(from).turndown(root).replace(/\n{3,}/g, '\n\n').trim();
  const title = m.title || new URL(url).pathname;
  // The page's own first heading repeats its title; one is enough.
  const h1 = /^# (.+)\n*/.exec(body);
  if (h1 && title.startsWith((h1[1] ?? '').trim())) body = body.slice(h1[0].length);
  // So does a lede that is the description, which the quote below carries.
  const lede = /^([^\n]+)(\n\n|$)/.exec(body);
  if (m.description && lede && plain(lede[1] ?? '') === m.description) body = body.slice(lede[0].length);
  const out = [`# ${title}`];
  if (m.description) out.push(`> ${m.description}`);
  if (body) out.push(body);
  else {
    // A shell the client renders: what it links to, chrome included, is what
    // an agent can use. Parsed again because the strip above removed the nav.
    const links = shell(domino.createDocument(prepped), from);
    if (links.length) out.push('## Links', links.join('\n'));
  }
  return out.join('\n\n') + '\n';
}

function plain(md: string): string {
  return md.replace(/\\(.)/g, '$1').replace(/\s+/g, ' ').trim();
}

function shell(doc: Document, base: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const a of Array.from(doc.querySelectorAll('a[href]'))) {
    const href = absolute(a.getAttribute('href') ?? '', base);
    const label = (a.textContent ?? '').replace(/\s+/g, ' ').trim();
    if (!href || !label || seen.has(href)) continue;
    seen.add(href);
    out.push(`- [${label.replace(/[[\]]/g, '')}](${href})`);
  }
  return out;
}
