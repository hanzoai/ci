// llms.txt (llmstxt.org): for a bundle that ships none, the site's title and
// description, its pages with their Markdown twins, and where an agent goes
// next. A site's own llms.txt gains only the line to /auth.md when it lacks one.

export type Entry = { url: string; title: string; description: string };
export type Have = { auth: boolean; catalog: boolean };

const heading = /^## For agents[ \t]*\r?$/m;

function auth(host: string): string {
  return `- [Sign in as an agent](https://${host}/auth.md): a wallet with no person, the device flow (\`hanzo auth login\`), API keys, and OpenID Connect at hanzo.id.`;
}

// Every URL here answers 200; the two on this host only when the bundle ships them.
export function pointers(host: string, have: Have): string[] {
  return [
    ...(have.auth ? [auth(host)] : []),
    ...(have.catalog
      ? [`- [API catalog](https://${host}/.well-known/api-catalog): the Hanzo API, its OpenAPI document and its MCP endpoint, as an RFC 9727 linkset.`]
      : []),
    '- [Hanzo API](https://api.hanzo.ai/v1): every capability at one endpoint; every operation is in https://api.hanzo.ai/v1/openapi.json.',
    '- [MCP](https://docs.hanzo.ai/docs/mcp): `POST https://api.hanzo.ai/v1/mcp`, or locally `npx -y --package=@hanzo/mcp@latest hanzo-mcp serve`.',
    '- [Docs](https://docs.hanzo.ai/llms.txt): every Hanzo docs page.',
    '- [Skills](https://hanzoskills.com/llms.txt): the skills an agent installs.',
    '- [Agents](https://hanzo.ai/agents): sign up, the free tier, the first call, and paying with no person.',
  ];
}

function one(s: string): string {
  return s.replace(/\s+/g, ' ').trim();
}

export function llms(host: string, site: { title: string; description: string }, entries: Entry[], have: Have): string {
  const out = [`# ${one(site.title) || host}`, ''];
  if (site.description) out.push(`> ${one(site.description)}`, '');
  if (entries.length) {
    out.push('## Pages', '');
    for (const e of entries) {
      const label = one(e.title).replace(/[[\]]/g, '') || new URL(e.url).pathname;
      out.push(`- [${label}](${e.url})${e.description ? ': ' + one(e.description) : ''}`);
    }
    out.push('');
  }
  out.push('## For agents', '', ...pointers(host, have), '');
  return out.join('\n');
}

// The site's own file with the /auth.md line it lacks: at the end of its own
// "For agents" section when it has one, else as a section of its own, before
// an `## Optional` section, which llmstxt.org reserves for the end.
export function merge(text: string, host: string, have: Have): string | undefined {
  if (!have.auth || text.includes('/auth.md')) return undefined;
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const m = heading.exec(text);
  if (!m) {
    const block = ['## For agents', '', ...pointers(host, have), '', ''].join(eol);
    const optional = /^## Optional[ \t]*\r?$/m.exec(text);
    if (optional) return text.slice(0, optional.index) + block + text.slice(optional.index);
    const sep = text === '' || text.endsWith('\n') ? '' : eol;
    return text + sep + eol + block.slice(0, -eol.length);
  }
  // The line goes after the section's last character; every byte around it stays.
  const after = m.index + m[0].length;
  const next = /^#{1,2} /m.exec(text.slice(after));
  const end = next ? after + next.index : text.length;
  const at = text.slice(0, end).replace(/\s+$/, '').length;
  return text.slice(0, at) + eol + auth(host) + text.slice(at) + (next || text.endsWith('\n') ? '' : eol);
}
