// /.well-known/api-catalog (RFC 9727): one linkset, the same on every Hanzo
// site, naming the API, its MCP endpoint, the identity provider and the agents
// guide. Every href answers 200; the two on this host only when the bundle
// ships them.

import type { Have } from './llms.ts';

type Link = { href: string; type: string };

export function catalog(host: string, have: Have & { llms: boolean }): string {
  const linkset: Array<Record<string, string | Link[]>> = [
    {
      anchor: 'https://api.hanzo.ai/v1',
      'service-desc': [{ href: 'https://api.hanzo.ai/v1/openapi.json', type: 'application/json' }],
      'service-doc': [{ href: 'https://docs.hanzo.ai/docs/openapi', type: 'text/html' }],
      'service-meta': [{ href: 'https://api.hanzo.ai/.well-known/oauth-protected-resource', type: 'application/json' }],
      status: [{ href: 'https://status.hanzo.ai', type: 'text/html' }],
    },
    {
      anchor: 'https://api.hanzo.ai/v1/mcp',
      'service-doc': [{ href: 'https://docs.hanzo.ai/docs/mcp', type: 'text/html' }],
    },
    {
      anchor: 'https://hanzo.id',
      'service-meta': [{ href: 'https://hanzo.id/.well-known/openid-configuration', type: 'application/json' }],
      'service-doc': [
        ...(have.auth ? [{ href: `https://${host}/auth.md`, type: 'text/markdown' }] : []),
        { href: 'https://hanzo.ai/agents', type: 'text/html' },
      ],
    },
    {
      anchor: 'https://hanzo.ai/agents',
      describedby: [
        { href: 'https://hanzo.ai/llms.txt', type: 'text/plain' },
        { href: 'https://docs.hanzo.ai/llms.txt', type: 'text/plain' },
        { href: 'https://hanzoskills.com/llms.txt', type: 'text/plain' },
      ],
    },
  ];
  if (have.llms) {
    linkset.push({ anchor: `https://${host}/`, describedby: [{ href: `https://${host}/llms.txt`, type: 'text/plain' }] });
  }
  return JSON.stringify({ linkset }, null, 2) + '\n';
}
