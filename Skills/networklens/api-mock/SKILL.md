---
name: api-mock
description: Mocks an API response on the simulator with NetworkLens — no rebuild, no proxy. Use for "mock this endpoint", "mock the API response", "fake an empty list / 500 / timeout", "test the empty state", "make this call hang", "stub the flash sale API". Takes an endpoint plus an example response (pasted, captured from the live trace, or derived from the Codable model), asks which variants to build, writes the rules into the simulator's NetworkLens session.json, and hands back a relaunch instruction.
argument-hint: [endpoint or URL, e.g. "GET /backend/content-api/flashsale" or a full URL]
allowed-tools: [Bash, Read, Write, Grep, Glob, AskUserQuestion, Skill, mcp__networklens__lens_status, mcp__networklens__lens_list, mcp__networklens__lens_search, mcp__networklens__lens_get, mcp__networklens__lens_body]
---


> **Committed tooling — nothing to patch in or out.** NetworkLens ships from the
> `BlibliLogger` SPM package (`NetworkLens` product, real in Debug, inert in
> Release). The host-side driver lives in this repo:
>
> - `tools/networklens/lens` — the one entry point. Set the prefix once per Bash
>   call, since shell state does not persist between them:
>   `LENS="$(git rev-parse --show-toplevel)/tools/networklens/lens"`
> - `tools/networklens/mocks/` — mock specs (two committed examples; new ones are
>   gitignored). `tools/networklens/reports/` — validation reports, gitignored.
> - `tools/networklens-mcp/` — the MCP server behind the `mcp__networklens__*`
>   tools, registered in `BlibliMobile-iOS/.mcp.json`.
> - `$LENS doctor` first when anything looks empty: it reports the booted
>   simulator, the app container, trace size, armed mocks and the captured hosts.
> - An empty trace is usually the host filter, not a broken install — check
>   `$LENS hosts` before debugging anything else.
# API Mock — NetworkLens Rules Without a Rebuild

Writes mock rules straight into the booted simulator's NetworkLens snapshot
(`Library/Application Support/NetworkLens/session.json`). The app starts the lens
with `persistsRules: true` and `keepBreakpointsAcrossLaunches: true`
(`BlibliMobile-iOS/DevUtils/NetworkLens/NetworkLensBootstrap.swift`), so rules
written here **come back armed on the next launch** — no Swift change, no compile.

Everything runs through `tools/networklens/write_mock.py`. **Never hand-edit
`session.json`** — the rule shape is Swift's synthesised `Codable` (`{"respond":
{"_0": {...}}}`, base64 bodies, per-variant UUIDs) and a malformed file decodes
as "no rules", silently losing every mock the user already had.

---

## Step 0 — Preconditions

```bash
xcrun simctl get_app_container booted com.blibli.mobile data
```

- No booted sim / app not installed → say so and stop. Do **not** boot a
  simulator or build the app; the user runs Xcode themselves.
- Then check what is already armed:

```bash
$LENS mock list
```

Report anything already armed on the same endpoint before adding to it — a
forgotten mock reads as a backend bug.

---

## Step 1 — Resolve the endpoint

Accept any of these from the user and normalise to an **endpoint key**
(`METHOD /templated/path`, query dropped):

| User gives | What to do |
|---|---|
| Full URL | Pass it as `"url"` + `"method"` in the spec — the script derives the key, folds the query string into `match.query`, and warns if the host is outside the lens's allowlist. |
| `GET /backend/...` | Use it as `endpointKey` verbatim. |
| A feature name ("flash sale range") | Find the real key from the live trace: `mcp__networklens__lens_list` / `lens_search`, or `write_mock.py seed`. Confirm the key with the user before writing. |

**Volatile path segments are templated to `{id}`** (all-numeric, UUID, or ≥16-char
hex) — the same rule `PathMatcher` uses. `/product/12345/detail` becomes
`GET /product/{id}/detail`, and that key is what matches at runtime.

**Host allowlist gate:** only the hosts listed in `capturedHosts` in
`NetworkLensBootstrap.swift` are visible to the lens at all. A mock on any other
host can never fire. The script warns; relay the warning and stop rather than
writing a rule that will look broken.

Narrow with `match` when only some of the endpoint's traffic should be mocked —
`match.query` (`{"page": "1"}`, `"*"` matches any value), `match.headers`,
`match.bodyContains`. Identity is endpoint key **plus** match, so `page=1` and
`page=2` are two rules rather than one overwriting the other.

---

## Step 2 — Get the response body

Three sources; pick per the user's wording, and ask when it is not obvious.

**a) User pastes an example response** — the default when they give one. Use it
verbatim as the body of the success variant. Ask for anything missing that
changes behaviour: status code, `Content-Type` if not JSON, delay.

**b) Derived from a real captured response** — for "same as what the server
returns, but empty / with X null / with 30 items". Seed from the trace:

```bash
$LENS mock seed --endpoint "flashsale/v2/facets" > tools/networklens/mocks/spec.json
```

That prints a ready spec whose body is the endpoint's last real response. Then
mutate that body per the user's instruction. For a targeted read instead of a
whole body, use `mcp__networklens__lens_search` → `lens_body`.

**c) Generated from the app's Codable model** — when nothing has been captured
and the user has no sample. Locate the response type with the `repo-index`
skill (`symbol query decl <Name>`), read the model, and synthesise a body that
matches its keys, `CodingKeys` and optionality. **Say explicitly that the body is
synthesised from the model, not from the server** — a wrong key name here reads
as a decoding bug in the app.

Whatever the source: keep the app's envelope (`code` / `status` / `data`) intact
unless the user is deliberately testing a malformed one.

---

## Step 3 — Ask which variants to build

**Always `AskUserQuestion`** — a rendered multi-select, not a typed list in chat.
Propose a set based on the endpoint and let the user pick. A sensible starting
proposal:

| Variant | Spec | Tests |
|---|---|---|
| Success | the body from Step 2, 200 | the happy path |
| Empty | same envelope, `data: []` / `null` | empty state |
| Error 500 | `{"code":500,"status":"INTERNAL_SERVER_ERROR"}`, status 500 | error state |
| Timeout | `"failure": "timedOut"` | retry / offline banner |
| Hang | `"hang": true` | skeleton, shimmer, spinner leaks, cancel-on-navigate |
| Slow | Success + `"delay": 3` | loading state that is otherwise too fast to see |

Also offer a **script** (several outcomes in order) when the user is testing
retries — `"steps": [{"failure":"connectionLost"}, {"status":200,"body":{…}}]`
with `"exhaustion": "passThrough"` so the third attempt hits the real server.

One variant is active at a time; ask which one to arm (default: Success).

---

## Step 4 — Write the spec and apply it

Write the spec to the scratchpad (never into the repo), then apply:

```json
{"rules": [{
  "url": "https://bwa-qa2-gcp.gdn-app.com/backend/content-api/sub-flashsale/range?page=1",
  "method": "GET",
  "enabled": true,
  "activeVariant": "Empty",
  "variants": [
    {"name": "Success",   "status": 200, "body": {"code": 200, "status": "OK", "data": [{"id": "x"}]}},
    {"name": "Empty",     "status": 200, "body": {"code": 200, "status": "OK", "data": []}},
    {"name": "Error 500", "status": 500, "body": {"code": 500, "status": "INTERNAL_SERVER_ERROR"}},
    {"name": "Timeout",   "failure": "timedOut", "delay": 2},
    {"name": "Hang",      "hang": true},
    {"name": "Retry then win", "exhaustion": "passThrough",
     "steps": [{"failure": "connectionLost"}, {"status": 200, "body": {"code": 200}}]}
  ]
}]}
```

```bash
$LENS mock apply --spec tools/networklens/mocks/spec.json
```

Spec field reference:

| Field | Notes |
|---|---|
| `endpointKey` / `url`+`method` | one or the other; `url` also seeds `match.query` |
| `match` | `{"query": {...}, "headers": {...}, "bodyContains": "..."}`, all optional |
| `enabled` | default `true` |
| `activeVariant` | variant name; defaults to the first |
| variant `body` | object/array (JSON-encoded, `Content-Type: application/json` added), or a raw string, or `"bodyFile": "path"` |
| variant `status` | default 200 |
| variant `delay` | seconds; clamped by the request's own timeout |
| variant `failure` | `offline` · `timedOut` · `connectionLost` · `cannotFindHost` · `secureConnectionFailed` |
| variant `hang` | `true` — never answers, the only way to reach a genuinely pending state |
| variant `steps` | list of the above, served one per hit |
| `exhaustion` | `repeatLast` (default) · `loop` · `passThrough` (go live) |

**Safety rails the script enforces — do not work around them without saying so:**

- It **refuses to write while the app is running** (`--force` overrides). The app
  rewrites `session.json` on every rule change and when it backgrounds, so a
  write into a live app is silently lost. Tell the user to quit the app in the
  simulator first, then re-run.
- It **backs up** `session.json` to `session.json.bak-<timestamp>` before writing.
- It **reuses ids** for a rule/variant whose name already exists, so the active
  variant and hit counts survive a re-apply.
- `--dry-run` prints the resulting snapshot without writing. Use it when the
  endpoint key or match is at all uncertain.

---

## Step 5 — Hand back

Report, in this order:

1. What was armed — endpoint key, variant names, which one is active.
2. **"Relaunch the app from Xcode for these to take effect."** Rules load at
   `NetworkLens.start()`; a running app will not pick up a file written under it.
3. How to flip variants without touching Xcode again:

```bash
$LENS mock list
$LENS mock activate --rule "sub-flashsale/range" --variant "Error 500"
$LENS mock disable --rule "sub-flashsale/range"
$LENS mock off      # master switch, keeps every rule saved
```

Also mention the in-app overlay (the floating bubble) — variants can be switched
there live, without a relaunch. This skill is for authoring rules in bulk; the
overlay is for flipping them mid-session.

---

## Making a mock permanent

If the user asks to commit / share a mock with the team, `session.json` is the
wrong home — it is per-simulator, untracked, and wiped by a reinstall. Write a
Swift file under `BlibliMobile-iOS/DevUtils/NetworkLens/Mocks/` calling
`Mocks.shared.set(MockRule(endpointKey:variants:))` from a `#if DEBUG` seam, and
**invoke the `swift-codegen` skill** for it — that path needs a rebuild, so say so.

---

## Do not

- Do not run `xcodebuild`, boot a simulator, or launch the app. The user builds
  and runs in Xcode.
- Do not hand-edit `session.json`, and do not delete an existing rule the user
  did not ask about — `list` first, and ask before replacing.
- Do not mock a host outside `capturedHosts`; fix the allowlist first (a
  `NetworkLensBootstrap.swift` edit, which needs a rebuild) or pick another host.
- Do not claim a mock is live. Nothing here is verified until the user relaunches
  and sees it — say "armed, pending relaunch", not "done".
