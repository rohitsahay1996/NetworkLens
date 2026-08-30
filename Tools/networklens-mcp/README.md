# networklens-mcp

Exposes a NetworkLens trace to an MCP client (Claude Code) as queryable tools,
so an agent can read the app's real requests and responses instead of being told
about them.

Reads the trace, and writes the rules file the app reads at launch — so an agent
can capture a screen, build the variants, apply a scenario and export the result
as a shareable pack without a hand ever reaching the overlay. What it cannot do
is reach a *running* app; see the launch note below.

## The live channel

Write tools reach a **running** app rather than only the session file it reads
at launch. This server hosts a command queue on `http://127.0.0.1:8788`; the app
polls it every two seconds when its `LensConfiguration` carries
`control: ControlOptions()`.

Nothing to install and nothing to start — an MCP client launches this server from
`.mcp.json`, and the queue comes up with it. Run `lens_live` to see whether a
write will land in the app or in the file.

| Situation | What a write does |
|---|---|
| App running, control on | Applies in ~2s, no relaunch |
| App running, control off | Refuses, as before — the app would overwrite the file |
| App not running | Writes the session file, picked up at launch |

`NETWORKLENS_CONTROL_PORT` moves the port. `NETWORKLENS_SIDECAR` points at an
already-running queue — the browser lens's sidecar, say — and this server then
hosts nothing. If the port is already taken by another editor window running its
own copy, this one speaks to that queue over HTTP instead; whichever started
first serves, and both work.

Port 8788 rather than the browser sidecar's 8787 on purpose: that one also
serves `/ingest`, and binding it here would swallow the extension's traces
whenever this server started first.

## 1. Turn the trace on in the app

```swift
NetworkLens.start(
    configuration: LensConfiguration(
        trace: TraceOptions()          // nil (the default) writes nothing
    )
)
```

`NetworkLens.traceURL` reports where it landed. On a simulator that is inside
the app's data container.

## 2. Build the server

```bash
cd Tools/networklens-mcp
npm install && npm run build
```

## 3. Point it at a trace

Precedence: `NETWORKLENS_TRACE` → `NETWORKLENS_BUNDLE_ID` (booted simulator) →
the host's own Application Support.

```jsonc
// .mcp.json in the app repo
{
  "mcpServers": {
    "networklens": {
      "command": "node",
      "args": ["/absolute/path/to/NetworkLens/Tools/networklens-mcp/dist/index.js"],
      "env": { "NETWORKLENS_BUNDLE_ID": "com.gdn.blibli" }
    }
  }
}
```

A physical device has no path the Mac can read. Pull the container with Xcode
(Devices → app → Download Container), then set `NETWORKLENS_TRACE` to the
`trace.ndjson` inside it.

## Tools

| Tool | Returns |
|---|---|
| `lens_status` | Trace path, exchange count, sessions. Start here when nothing else returns rows. |
| `lens_list` | One line per exchange — id, status, ms, size, screen, endpoint, flags. Never bodies. |
| `lens_get` | Headers, timing and metadata for one exchange. |
| `lens_body` | A JSON-Pointer slice of one body, or a depth-collapsed outline. |
| `lens_search` | Key/value match across bodies → pointers to read, not payloads. |
| `lens_stats` | Counts by status and endpoint, slowest calls, mocked vs live. |
| `lens_curl` | One request rebuilt as curl. |
| `lens_diff` | Two exchanges — status, timing, and which body pointers differ. |

Reading the trace is only half of it. These read and set the rules file:

| Tool | Answers |
|---|---|
| `lens_mocks` | What is mocked, the variants each rule carries, which one is live, master switch. |
| `lens_scenarios` | Saved scenarios and what each pins. |
| `lens_apply_scenario` | Set every rule the way a scenario describes, and turn mocking on. |
| `lens_set_variant` | Point one endpoint at one variant, or turn its rule off for live traffic. |
| `lens_set_mocking` | The master switch. |
| `lens_import_pack` | Merge a `.networklens-pack.json` — scenarios plus the rules they need. |

And these author them, which is the part that used to mean thirty taps in the
overlay:

| Tool | Does |
|---|---|
| `lens_mock_endpoint` | Turns a captured response into a rule carrying `loaded`, `empty`, `500`, `slow`, `timeout`. Arrives disabled. |
| `lens_mock_screen` | The same for every endpoint on one screen, plus a scenario per state and a `— live` way back, grouped under the screen. |
| `lens_set_variant_body` | Writes what one variant serves — a file, an inline body, or one derived (`empty`/`500`) from the captured `loaded`. Creates the variant if the name is new. |
| `lens_delete_rule` | Removes rules and prunes the scenario entries that named them. The way out of a stale mock quietly serving an old body. |
| `lens_export_pack` | Writes the device's rules and scenarios out as a `.networklens-pack.json`. Redacted by default. |

`lens_mock_endpoint` and `lens_mock_screen` build from the **last live 200** for
an endpoint, never a mocked hit — otherwise a stale variant would copy itself
forward and become permanent. They leave an existing rule alone unless
`replace: true`, because an edited rule is someone's work; the scenarios still
name it either way, so applying one fully determines the screen.

The variants are the port of `CapturedVariants` in `NetworkLensCore`, byte for
byte: `empty` hollows the containers and keeps the envelope (a bare `{}` makes
the app fail to decode and show its *error* state, so the empty state never
renders and the variant proves nothing), and `500` rewrites `code`/`status`/
`data` in the app's own envelope shape. A pack written here imports in the
overlay, and one exported from the overlay imports here.

`lens_export_pack` redacts on the way out — same header names and key terms as
`DefaultRedactor`, so `cardNumber` and `accessToken` go but `company` and
`japan` stay. Bodies captured through the overlay were already redacted into the
trace; this is the only pass over anything authored host-side, and packs get
committed. `redact: false` opts out and says so in the result.

**Writes land at the next launch, never in the running app.** The overlay owns
`session.json` while the process lives and autosaves over it, so a write made
mid-session is both invisible and lost. Every write tool says so in its output
rather than leaving you to discover it. `NETWORKLENS_SESSION` overrides the path
the same way `NETWORKLENS_TRACE` does.

Every tool is summary-first by design. A megabyte response pasted whole into a
model's context makes its answers worse, not better, so bodies are reached
through `lens_body` with a pointer (`/data/summary`) or a depth cap, and are
clipped at 8k characters even then.

## Reading the file yourself

NDJSON, one `TraceRecord` per line. Bodies are base64 (Swift encodes `Data` that
way). An exchange is written when it finishes and again on every later edit, so
**the last line for an id is its current state** — collapse by id taking the
last, and earlier lines are the audit trail.

```bash
jq -r 'select(.exchange.response.statusCode >= 400)
       | "\(.exchange.endpointKey) \(.exchange.response.statusCode)"' trace.ndjson
```

## What it will not show you

- **Secrets.** The trace is redacted before it reaches disk, so auth headers read
  `<redacted>`. `redactor: NoRedactor()` opts out — do that on a throwaway build
  and never on one holding real credentials.
- **Whole large bodies.** `maxCapturedResponseBodyBytes` caps capture at 1MB;
  `lens_get` prints `TRUNCATED` and the original size when it bit.
- **Anything NetworkLens cannot intercept** — `WKWebView`, background sessions,
  gRPC and raw sockets. See the root README.
