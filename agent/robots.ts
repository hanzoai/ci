// robots.txt: which paths the `*` group closes (RFC 9309), the canonical file a
// site without one gets, and the two lines a site's own file gains when it
// lacks them. A site's own groups, rules and comments are never rewritten.

export const signal = 'Content-Signal: search=yes, ai-input=yes, ai-train=yes';

// The crawlers named Allow in a robots.txt the tool writes. Bytespider is not
// named: a site that names it keeps what it wrote.
export const crawlers = [
  'GPTBot',
  'OAI-SearchBot',
  'ChatGPT-User',
  'ClaudeBot',
  'Claude-User',
  'Claude-SearchBot',
  'Claude-Web',
  'anthropic-ai',
  'PerplexityBot',
  'Perplexity-User',
  'Google-Extended',
  'CCBot',
  'Applebot-Extended',
  'Meta-ExternalAgent',
  'Amazonbot',
  'cohere-ai',
  'DuckAssistBot',
  'Bingbot',
  'Googlebot',
];

export function canonical(host: string): string {
  return [
    'User-agent: *',
    signal,
    'Allow: /',
    '',
    ...crawlers.map((c) => `User-agent: ${c}`),
    'Allow: /',
    '',
    `Sitemap: https://${host}/sitemap.xml`,
    '',
  ].join('\n');
}

type Line = { key: string; value: string; index: number };
type Group = { agents: string[]; lines: Line[]; lastAgent: number };

function lines(text: string): Line[] {
  const out: Line[] = [];
  text.split(/\r?\n/).forEach((raw, index) => {
    const bare = raw.replace(/#.*$/, '').trim();
    const colon = bare.indexOf(':');
    if (colon <= 0) return;
    out.push({ key: bare.slice(0, colon).trim().toLowerCase(), value: bare.slice(colon + 1).trim(), index });
  });
  return out;
}

// Groups in file order: consecutive user-agent lines open one, every line
// after them up to the next user-agent line is its member. Sitemap belongs to
// no group.
function groups(text: string): Group[] {
  const out: Group[] = [];
  let cur: Group | undefined;
  let open = false;
  for (const l of lines(text)) {
    if (l.key === 'sitemap') continue;
    if (l.key === 'user-agent') {
      if (!cur || !open) {
        cur = { agents: [], lines: [], lastAgent: l.index };
        out.push(cur);
        open = true;
      }
      cur.agents.push(l.value.toLowerCase());
      cur.lastAgent = l.index;
      continue;
    }
    open = false;
    cur?.lines.push(l);
  }
  return out;
}

export type Rule = { allow: boolean; pattern: string };

// The rules every crawler without a group of its own obeys: all `*` groups,
// combined (RFC 9309 2.2.1).
export function rules(text: string): Rule[] {
  const out: Rule[] = [];
  for (const g of groups(text)) {
    if (!g.agents.includes('*')) continue;
    for (const l of g.lines) {
      if ((l.key === 'allow' || l.key === 'disallow') && l.value !== '') {
        out.push({ allow: l.key === 'allow', pattern: l.value });
      }
    }
  }
  return out;
}

const compiled = new Map<string, RegExp>();
function regex(pattern: string): RegExp {
  let re = compiled.get(pattern);
  if (!re) {
    const end = pattern.endsWith('$');
    const body = (end ? pattern.slice(0, -1) : pattern)
      .split('*')
      .map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
      .join('.*');
    re = new RegExp('^' + body + (end ? '$' : ''));
    compiled.set(pattern, re);
  }
  return re;
}

// RFC 9309 2.2.2: the longest matching pattern decides, and Allow wins a tie.
export function allowed(rs: Rule[], urlPath: string): boolean {
  let best: Rule | undefined;
  for (const r of rs) {
    if (!regex(r.pattern).test(urlPath)) continue;
    if (!best || r.pattern.length > best.pattern.length || (r.pattern.length === best.pattern.length && r.allow)) {
      best = r;
    }
  }
  return best ? best.allow : true;
}

// The site's own file plus what it lacks: the content signal inside the first
// `*` group (a `*` group of its own, which allows what no group allowed, when
// the file has none) and a Sitemap line. Undefined when it lacks neither.
export function merge(text: string, host: string): { text: string; added: string[] } | undefined {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const rows = text.split(/\r?\n/);
  const added: string[] = [];
  const star = groups(text).find((g) => g.agents.includes('*'));
  if (star && !star.lines.some((l) => l.key === 'content-signal')) {
    rows.splice(star.lastAgent + 1, 0, signal);
    added.push('Content-Signal');
  } else if (!star) {
    const first = lines(text).find((l) => l.key === 'user-agent');
    const block = ['User-agent: *', signal, 'Allow: /', ''];
    if (first) rows.splice(first.index, 0, ...block);
    else {
      while (rows.length && rows[rows.length - 1] === '') rows.pop();
      if (rows.length) rows.push('');
      rows.push(...block.slice(0, -1), '');
    }
    added.push('a User-agent: * group with Content-Signal');
  }
  if (!lines(text).some((l) => l.key === 'sitemap')) {
    while (rows.length && rows[rows.length - 1] === '') rows.pop();
    rows.push('', `Sitemap: https://${host}/sitemap.xml`, '');
    added.push('Sitemap');
  }
  if (!added.length) return undefined;
  let out = rows.join(eol);
  if (!out.endsWith(eol)) out += eol;
  return { text: out, added };
}
