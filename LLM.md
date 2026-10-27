# hanzoai/ci

README.md is the usage document. This file holds what an agent working in this
repo needs and the README does not say.

## Releases

- `uses: …@v2` resolves the TAG `v2`, which rides main: a release is a tag
  `v2.1.N` on main and `v2` moved to the same commit (`git tag -f v2 <sha> &&
  git push -f origin refs/tags/v2`). `v1` is frozen at 30af8df; its callers
  (site action `@v1`) do not move with main.
- The site action runs `bin/site` and `bin/agent` from its own ref
  (`github.action_ref`); build.yml clones its tools from the caller's pin, then
  its own commit, then the caller's ref, and falls through any tree missing a
  tool in `need=`.
- GitHub is home; git.hanzo.ai/hanzoai/ci is its pull mirror (interval 10m). A
  forge caller of `@v2` resolves against the mirror, so a release reaches forge
  callers after the next sync.

## agent/ (`agent:` on a site)

- Strict TypeScript run by Node's own type stripping (22.18+; the runner image
  carries 22.23.3; the suite passes on 22.23.3 and 24). Erasable syntax only
  (`erasableSyntaxOnly`), `.ts` import specifiers, no build. `npm ci` installs
  typescript and the types for the gate; `bin/agent` installs `--omit=dev`
  (turndown and `@mixmark-io/domino`, 9 MB).
- domino's own declaration names the module `domino` and exports nothing, so
  `agent/domino.d.ts` declares the one function the tool calls.
- Goldens: `agent/test/fixtures/<f>/{in,want}`. Regenerate a `want/` only after
  reading the diff, with the commands at the top of `test/main.test.ts`.
- Writes: an existing file is replaced by rename, so a page hardlinked into a
  second bundle (hanzo-inc/app builds `out-bot` with `cp -al out`) changes in
  one bundle only; a new file is an exclusive open, which is the absence check.
- Measured on 249 live docs.hanzo.ai pages (835 KB each, 208 MB): 11.8 s on one
  thread, 6.0 s on eight, on dgx, where `open(2)` was 29% of the profile. The
  CPU per page is about 34 ms; the prep step cuts a 1 MB page to 37 KB before
  domino parses it. Every one of the 249 pages changed by the one `<link>`
  before `</head>` and nothing else (checked byte for byte).
- On the live hanzoskills.com bundle every file but llms.txt is the site's own
  and is left; llms.txt gains the For agents block before its `## Optional`.
  On a hanzo.ai sample every page already has its twin and link; robots.txt
  gains Content-Signal, llms.txt the /auth.md line, and auth.md is written.
- `agent/auth.md` is the estate's one auth.md: hanzoai/skills `public/auth.md`
  (fd0347e) verbatim, plus "OpenID Connect, for apps" and "Scopes". A site that
  ships its own keeps it; dropping it lets `agent:` write this one. Every
  endpoint it names answered as it says on 2026-10-26 (nonce 200, verify 400 on
  an empty body, token 400 invalid_grant, device 200, keys 403
  unauthenticated, MCP 405 Allow: POST, userinfo 401, authorize 400; jwks,
  OIDC, OAuth AS and PRM metadata 200).
- `/.well-known/api-catalog` has no extension, so its Content-Type is the
  edge's to set (application/linkset+json); bin/site stores it as
  octet-stream and the edge does not read the stored type.

## Sweep findings (2026-10-26, agent/sweep.ts)

hanzo.ai: 1,939 URLs, 5,817 requests, 22 failed, all from llms.txt:
/openai/o4-mini, /openai/o3-mini, /deepseek/deepseek-r1, /microsoft,
/models/cohere/command-r, /moonshotai/kimi-k2 and
docs.hanzo.ai/docs/agents/prompt answer 404 to every crawler; startlandnews.com
answered ClaudeBot 429. docs.hanzo.ai/docs/agents is a noindex redirect page to
/docs/openapi/agent/.

## Known local failure

`gocache`'s `TestTheGoCommandBuildsWarmFromTheStore` fails in a `git worktree`
(the go command's VCS stamping exits 128 there), on a clean origin/main worktree
as much as on a change, so a red there locally is not the change.
