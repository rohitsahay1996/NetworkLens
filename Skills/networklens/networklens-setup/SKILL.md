---
name: networklens-setup
description: Verifies, repairs and upgrades the NetworkLens network interceptor in this repo — checks the SPM package resolved, the MCP server is built and registered, the bootstrap is wired and the captured-host list is right, then fixes whatever is broken. Use for "set up NetworkLens", "networklens isn't capturing anything", "the networklens MCP won't connect", "no trace", "mocks aren't sticking", "upgrade NetworkLens to tag X", "install the networklens MCP".
argument-hint: [optional package tag, e.g. 14.5.0]
allowed-tools: [Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, Skill, mcp__networklens__lens_status, mcp__networklens__lens_stats, mcp__networklens__lens_list]
---

> **Committed tooling — nothing to patch in or out.** NetworkLens ships from the
> `BlibliLogger` SPM package (`NetworkLens` product, real in Debug, inert in
> Release). The host-side driver lives in this repo:
>
> - `tools/networklens/lens` — the one entry point. Set the prefix once per Bash
>   call, since shell state does not persist between them:
>   `LENS="$(git rev-parse --show-toplevel)/tools/networklens/lens"`
> - `tools/networklens-mcp/` — the MCP server behind the `mcp__networklens__*`
>   tools, registered in `BlibliMobile-iOS/.mcp.json`.
> - `BlibliMobile-iOS/BlibliMobile-iOS/DevUtils/NetworkLens/NetworkLensBootstrap.swift`
>   — the only app-side file, committed, lint-covered.

# NetworkLens Setup — Verify, Repair, Upgrade

There is no "wire it in" flow any more. A developer who pulls this repo and opens
the workspace already has the framework; this skill exists for the three things
that still go wrong, and for moving to a new package tag.

**Never build or launch the app from here.** Xcode is the developer's. Every
command below reads the simulator or the repo — none of them compile anything.

---

## Step 1 — One command tells you almost everything

```bash
LENS="$(git rev-parse --show-toplevel)/tools/networklens/lens"; $LENS doctor
```

It reports the booted simulator, the app's data container, the trace size, the
armed mock rules and the resolved captured-host list. Read it before asking the
user anything — most reports of "it isn't working" are one of the four failures
below, and `doctor` names which.

Then confirm the pieces `doctor` does not cover:

```bash
ROOT="$(git rev-parse --show-toplevel)"
# package resolved, and at which version
python3 -c "import json;d=json.load(open('$ROOT/BlibliMobile-iOS/BlibliMobile-iOS.xcworkspace/xcshareddata/swiftpm/Package.resolved'));print([p for p in d['pins'] if 'logger' in p['identity']])"
# MCP server registered, built, and answering
python3 -c "import json;print(json.load(open('$ROOT/BlibliMobile-iOS/.mcp.json'))['mcpServers'].get('networklens'))"
ls "$ROOT/tools/networklens-mcp/dist/index.js" 2>/dev/null || echo "MCP not built — first run of bin/start.sh will build it"
# the app-side file
ls "$ROOT/BlibliMobile-iOS/BlibliMobile-iOS/DevUtils/NetworkLens/NetworkLensBootstrap.swift"
```

---

## Step 2 — The four failures, in the order they actually happen

### A. The MCP tools are missing or the server won't connect

`mcp__networklens__*` absent from the session means Claude Code has not connected
it. In order:

1. The server is registered per-project in `BlibliMobile-iOS/.mcp.json`, so the
   user must **approve the project's MCP servers once and restart Claude Code**.
   Nothing you can do from here substitutes for that restart — say so plainly.
2. Confirm the server runs at all:
   ```bash
   printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}\n' \
     | "$ROOT/tools/networklens-mcp/bin/start.sh"
   ```
   A `serverInfo` line back means the server is fine and the problem is the
   approval/restart. `bin/start.sh` runs `npm ci && npm run build` itself on the
   first call, so a missing `dist/` is not a failure — it is a slow first run.
   It needs Node 18+ and network access for that one install.
3. If `npm ci` fails, report the error verbatim. Do not hand-edit
   `package-lock.json`.

While the MCP tools are unavailable, `$LENS trackers` and `$LENS mock list` still
work — they read the same trace. Use them rather than stalling.

### B. The trace is empty

Almost always the host filter, not a broken install.

```bash
$LENS hosts                                    # resolved list
$LENS hosts wwwuatb.gdn-app.com bwa-qa2-gcp.gdn-app.com   # set it
$LENS hosts --reset                            # back to the compiled defaults
```

A host absent from the resolved list is invisible to the whole tool — mocks,
breakpoints and replay included. Precedence, most explicit first:

1. `NETWORKLENS_HOSTS` in the Xcode scheme's environment (comma-separated)
2. `NetworkLensCapturedHosts` in the app's `UserDefaults` — what `$LENS hosts` writes
3. the compiled defaults in `NetworkLensBootstrap.swift`

The list is read once, at `start()`, so **relaunch the app** after changing it.
Only edit the Swift defaults when the change is for the whole team.

Other causes worth checking, in order: the app was launched in a Release
configuration (everything compiles to the inert mirror — expected, not a bug);
the app has not made a request since launch; the ring buffer evicted the calls
(500 slots, which is why the host filter exists).

### C. Mocks are not sticking

The app rewrites `session.json` on every rule change and when it backgrounds, so
a write while it is running is lost. Every mutating command refuses a live app
unless `--force` is passed. **Quit the app, write, relaunch.** Rules come back
armed — the bootstrap sets `persistsRules: true` and
`keepBreakpointsAcrossLaunches: true`.

Never hand-edit `session.json`: the shape is Swift's synthesised `Codable` and a
malformed file decodes as "no rules", silently dropping every mock the user had.

### D. The package did not resolve

`import NetworkLens` failing to build means the `BlibliLogger` dependency did not
resolve — File ▸ Packages ▸ Resolve Package Versions in Xcode, and check the pin
in `Package.resolved` matches a tag that actually contains `NetworkLens`. To test
an unreleased change, drag the local `BlibliLogger` checkout into the workspace:
a local package override wins over the remote pin.

---

## Step 3 — Upgrading to a new package tag

The framework, the MCP server and these skills are versioned together in
`gdncomm/BlibliLogger` under `NetworkLens/`. This repo carries a vendored copy of
the two host-side pieces, so an upgrade is two moves, not one.

1. Bump the pin in Xcode (File ▸ Packages ▸ Update, or edit the requirement) and
   confirm `Package.resolved` shows the new version.
2. Re-vendor the tooling from the same tag, then tell the user to restart Claude
   Code so the rebuilt MCP server is picked up:
   ```bash
   PKG=<path to the BlibliLogger checkout at the new tag>
   rsync -a --exclude node_modules --exclude dist "$PKG/NetworkLens/Tools/networklens-mcp/" "$ROOT/tools/networklens-mcp/"
   rsync -a "$PKG/NetworkLens/Skills/networklens/" "$ROOT/BlibliMobile-iOS/.claude/skills/"
   rm -rf "$ROOT/tools/networklens-mcp/dist"    # start.sh rebuilds on next launch
   ```
3. Read `NetworkLens/Docs/README.md` at the new tag for API changes, and check
   `NetworkLensBootstrap.swift` still compiles against them — `LensConfiguration`
   is the surface most likely to have moved.

Ask before bumping a pin the user did not ask for.

---

## Step 4 — Wiring a *different* app (rare)

For an app that has never had NetworkLens: add the `BlibliLogger` package, link
the `NetworkLens` product only (not `Core`/`UI` — the umbrella picks per
configuration), copy this repo's `NetworkLensBootstrap.swift` as the template,
call `start()` as the first statement of `didFinishLaunchingWithOptions` and
`attachOverlay(to:)` at the end, then copy `tools/networklens*` and register the
server in that repo's `.mcp.json`. `NetworkLens/Docs/README.md` in the package is
the reference; chain `swift-codegen` for the Swift file.

---

## Do not

- Do not run `xcodebuild` or boot a simulator. Ask the user to build in Xcode.
- Do not add `#if DEBUG` around bootstrap call sites — the umbrella already
  resolves to an inert mirror in Release, and the guards rot.
- Do not write mock specs or reports outside `tools/networklens/{mocks,reports}`.
- Do not commit `tools/networklens-mcp/{dist,node_modules}` — both are gitignored
  and rebuilt on demand.
- Do not edit the compiled host defaults for a one-developer need; that is what
  `$LENS hosts` is for.
