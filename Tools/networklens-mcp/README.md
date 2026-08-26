# networklens-mcp

Exposes a NetworkLens trace to an MCP client (Claude Code) as queryable tools,
so an agent can read the app's real requests and responses instead of being told
about them.

Read-only. Nothing here can arm a mock or edit a response — that needs a control
channel into the running app, which this does not have.

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
