# The egress allowlist, and what is deliberately left out of it

`bin/claude-egress-firewall` composes a default-deny allowlist by resolving a baked
list of hostnames to addresses. This file is the other half of that list: **the
record of what the vendor's published network requirements name that this container
does NOT pin, and why**.

It exists because an allowlist is only trustworthy if the gaps in it are deliberate.
A host that is simply absent looks identical to a host someone forgot, and the
difference only shows up as a feature that mysteriously does not work in a
locked-down container weeks later. Before this file, the script's own comment pointed
at "the egress-allowlist memo" and no such memo existed anywhere in the repo, so the
one claim it made in passing (that the artifact host is "browser-only") had no
written basis and was, as it happens, wrong: the vendor documents the CLI itself as
fetching artifact content from that host.

Source of record: Claude Code's published network access requirements,
<https://code.claude.com/docs/en/network-config>, section "Network access
requirements" plus its "Desktop and claude.ai" subsection. Anthropic's published
address space: <https://platform.claude.com/docs/en/api/ip-addresses>.

## How to keep this honest

`test/egress-packages-unit.sh` parses the table below and fails when it and the
shipped allowlist disagree, so this is executable documentation, not commentary:

- every `pinned` row must appear in the composed host set (the
  `CLAUDE_EGRESS_PRINT_HOSTS=1` dry run);
- every `omitted` and `omitted-wildcard` row must **not** appear there, and must
  carry a non-empty Why-not;
- every `omitted-wildcard` row must name a pattern (it contains `*`) and must be
  reported by name, with its feature, in the script's composition-time log;
- a hardcoded list of the hosts the published requirements name must all have a row
  here, so a row cannot be quietly deleted to make a documented host disappear.

Row format is load-bearing: `| host in backticks | status | what needs it | why not |`,
status being exactly `pinned`, `omitted` or `omitted-wildcard`.

## The published CLI requirements

| Host | Status | What needs it | Why not pinned |
|---|---|---|---|
| `api.anthropic.com` | pinned | Claude API requests, the WebFetch domain safety check, feature flag fetches, telemetry event logging | |
| `claude.ai` | pinned | claude.ai account authentication | |
| `claude.com` | pinned | claude.ai sign-in opens a claude.com page; pre-approved WebFetch documentation lookups also reach it from the CLI | |
| `platform.claude.com` | pinned | Console account authentication, and OAuth token exchange, refresh and revocation for claude.ai accounts too | |
| `mcp-proxy.anthropic.com` | pinned | MCP connectors from claude.ai, which are enabled by default for claude.ai-authenticated users | |
| `downloads.claude.ai` | pinned | Plugin executable downloads; native installer, native auto-updater and update version checks | |
| `storage.googleapis.com` | pinned | Plugin install counts and metadata shown in `/plugin`; the native installer on CLI versions before 2.1.116 | |
| `registry.npmjs.org` | pinned | Plugin installs, `npx`-launched MCP servers, and the package registry this image installs Claude Code itself from | |
| `bridge.claudeusercontent.com` | pinned | The Claude in Chrome extension WebSocket bridge | |
| `raw.githubusercontent.com` | pinned | The changelog feed behind `/release-notes`, also fetched in the background at startup | |
| `http-intake.logs.us5.datadoghq.com` | pinned | Operational telemetry events, sent when the CLI talks to the Anthropic API directly | |
| `browser-intake-us5-datadoghq.com` | pinned | Operational error reports, sent when the CLI talks to the Anthropic API directly and a rollout gate enables them | |
| `code.claude.com` | pinned | Documentation lookups by the built-in claude-code-guide agent and pre-approved WebFetch requests | |
| `*.frame.claudeusercontent.com` | omitted-wildcard | Artifact content reads: the CLI fetches an artifact's files from this host when Claude opens one | A name pattern has no address to pin, and an IP allowlist admits addresses. Nothing here can fix that, so the script names the pattern and the lost feature at composition time on every run instead of letting it fail silently. An operator who does not want the gap sets `CLAUDE_CODE_DISABLE_ARTIFACT=1` (or `"enableArtifact": false`) and drops the requirement rather than hitting it. This is the entry the script's old comment called "browser-only", which was wrong: the vendor documents the CLI as the fetcher |
| `formulae.brew.sh` | omitted | Update version checks on Homebrew installs of the CLI | This image installs Claude Code with `npm install -g @anthropic-ai/claude-code` (see the Dockerfile) and pins the version, and the vendor states other install methods do not contact this host. Pinning a Homebrew endpoint in a Debian container would widen the allowlist for traffic that can never happen. Add it via `CLAUDE_EGRESS_EXTRA_HOSTS` if you rebuild on a Homebrew-installed CLI |

The two Datadog intake hosts carry optional telemetry that the vendor says can be
turned off, and a security-minded reading would drop them. This image cannot: the
Dockerfile and `entrypoint.sh` both refuse to set `DISABLE_TELEMETRY`,
`DO_NOT_TRACK` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, because those
short-circuit the GrowthBook feature-flag fetch and Remote Control, the point of this
image, then reports itself as not enabled for the account. Telemetry is on by
deliberate decision here, so the hosts it goes to are pinned rather than left to
drop.

## Desktop and browser hosts (the published requirements list them, the CLI does not use them)

The vendor's own text draws this line: "The preceding table covers the standalone
CLI." What follows it is what the Desktop app and claude.ai in a browser load. This
container runs the CLI, so these are omitted, and named here so the omission is a
decision rather than an oversight.

| Host | Status | What needs it | Why not pinned |
|---|---|---|---|
| `assets-proxy.anthropic.com` | omitted | Application code and user content for the Claude Desktop app and claude.ai in a browser | Neither runs in this container. Blocking it produces a blank page in those apps, not a CLI failure |
| `*.claudeusercontent.com` | omitted-wildcard | Artifact origins serving artifacts inside the Desktop app and claude.ai | Both a name pattern (unpinnable) and a browser-side requirement (unused here). Reported at composition time anyway, for an operator who proxies a browser through this container |
| `fonts.googleapis.com` | omitted | Typefaces an artifact may load from Google Fonts | Browser-side artifact rendering, and the vendor calls it optional: blocked, artifacts fall back to another typeface |
| `fonts.gstatic.com` | omitted | The font files behind the above | Same: browser-side, optional, degrades to a fallback typeface |
| `cdnjs.cloudflare.com` | omitted | JavaScript libraries an artifact may load | Browser-side artifact rendering. Nothing the CLI does fetches from it |
| `cdn.jsdelivr.net` | omitted | JavaScript libraries an artifact may load | Browser-side artifact rendering. Nothing the CLI does fetches from it |
| `cdn.tailwindcss.com` | omitted | JavaScript libraries an artifact may load | Browser-side artifact rendering. Nothing the CLI does fetches from it |
| `code.jquery.com` | omitted | JavaScript libraries an artifact may load | Browser-side artifact rendering. Nothing the CLI does fetches from it |

### Two names that appear on the requirements page but are not requirements

`assets.claude.ai` and `www.claude.com` occur in the published page and have **no row
above and no pin**, which is correct rather than an omission anybody forgot. Both
appear only in the documentation site's own furniture: `assets.claude.ai` in the
page's `@font-face` CSS and in the analytics/script blob at the end of it,
`www.claude.com` in that same blob. Neither is in the "Network access requirements"
table, and neither is in the "Desktop and claude.ai" subsection, so neither is
something the vendor asks a client to reach. They are recorded here because they are
easy to find with a text search of the saved page and would otherwise be re-litigated
by the next person who does one. A host that turns out to be genuinely required gets
a row in a table above, not a mention here.

## Hosts this image pins that the vendor does not require

These are this container's requirements, not Claude Code's published ones, and they
are listed for symmetry: someone auditing the allowlist against the vendor page
should be able to account for every entry in it, in both directions.

| Host | What needs it |
|---|---|
| `statsig.anthropic.com`, `statsig.com`, `api.growthbook.io`, `cdn.growthbook.io` | The feature-flag fetch that gates Remote Control. Blocking these makes Remote Control report itself as not enabled for the account, which is the failure this image exists to avoid. `statsig.anthropic.com` is not publicly resolvable and therefore often pins nothing; that is expected |
| `us.sentry.io`, `downloads.sentry-cdn.com` | Error reporting from the CLI |
| `objects.githubusercontent.com`, `github.com`, `api.github.com`, `codeload.github.com` | The container's own git workflow, plus the `api.github.com/meta` fetch that pins GitHub's published ranges |

## Anthropic's published address space

`bin/claude-egress-firewall` pins Anthropic's published **inbound** ranges
(`160.79.104.0/23` and `2607:6bc0::/48`) on both families, in addition to whatever
per-host DNS returned, so a CDN answer that moves between refreshes cannot take the
API with it.

The publisher's page has three sections and only the first is a destination:

- **Inbound** (`160.79.104.0/23`, `2607:6bc0::/48`): where Anthropic services
  *receive* connections. This is what a container dials, so this is what is pinned.
- **Outbound** (`160.79.104.0/21`): the stable source addresses Anthropic uses when
  *it* makes requests out, for example MCP tool calls to external servers. That
  belongs in someone else's *ingress* allowlist. It is also an eightfold wider
  prefix than the inbound one, so pinning it as a destination would broaden this
  container's egress by 2048 addresses to buy nothing the CLI dials.
- **Phased out** (`34.162.46.92/32`, `34.162.102.82/32`, `34.162.136.91/32`,
  `34.162.142.92/32`, `34.162.183.95/32`): addresses the publisher states are no
  longer in use and asks anyone who allowlisted them to remove.

Neither the outbound prefix nor the phased-out addresses appear anywhere in the
composed allowlist, and the unit suite asserts they never reach either family's
ruleset.

## Refreshing the allowlist

A pinned address is a snapshot. `CLAUDE_EGRESS_REFRESH_INTERVAL=<seconds>` makes the
firewall re-resolve this list on an interval and commit the refreshed ruleset, as
root, for as long as the container lives; unset (the default) it is resolved exactly
once, at boot. See the `CLAUDE_EGRESS_REFRESH_INTERVAL` row in the README's
environment table. The refresh never narrows the allowlist on a failed lookup: a host
that comes back empty retains the ruleset in force and is logged by name.
