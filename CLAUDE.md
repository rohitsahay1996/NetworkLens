# NetworkLens — working context

On-device network debugging for iOS, shipped as a Swift package. Capture, mock,
breakpoint and replay traffic from inside the app — no proxy, no cert, no
desktop. Works on SSL-pinned builds because it sits *below* the app's networking
stack (`URLProtocol` + swizzled `URLSessionConfiguration`) rather than in front
of it.

iOS 15+ / macOS 12+ (macOS only so `swift test` can drive Core headlessly).
Zero third-party dependencies, and it must stay that way.

`README.md` is the **user-facing** doc — integration, API cheat sheet,
troubleshooting. This file is the **contributor/agent** doc — architecture,
invariants, and the reasons behind them. When public behaviour changes, both
need updating.

---

## Repo map

```
Sources/
  NetworkLens/        Umbrella. Re-export shim only — what an app links.
  NetworkLensCore/    All logic. Foundation-only. No UIKit, no Combine, no SwiftUI.
  NetworkLensUI/      SwiftUI/UIKit overlay. Depends on Core.
  NetworkLensNoOp/    Inert mirror of the whole public surface. Depends on nothing.
Tests/
  NetworkLensCoreTests/    The real suite (~415 test funcs, runs on macOS).
  NetworkLensUITests/      Compiles README's UIKit snippets. Empty on macOS by design.
  NetworkLensNoOpTests/    API parity — fails the build when Core grows API NoOp lacks.
Tools/
  networklens-mcp/    TypeScript MCP server over the trace file. Not in Package.swift,
                      not built by `swift build` — it ships in the repo, not in the binary.
```

### Target dependency rules — these are load-bearing

| Rule | Why |
|---|---|
| **Core imports Foundation only** | So `swift test` can drive it headlessly in CI with no simulator and no host app. Adding `import UIKit` or `import Combine` to Core breaks CI silently on the next platform bump. Observation adapters live in UI. |
| **NoOp does not depend on Core** | The point of NoOp is that a release binary provably contains none of the capture machinery. Linking Core defeats it entirely. |
| **UI wraps UIKit code in `#if canImport(UIKit)`** | Same reason — the target must still compile on macOS for the package to resolve. |
| **NoOp mirrors every public Core+UI symbol** | Host apps swap `import NetworkLensUI` → `import NetworkLensNoOp` in release and every call site compiles unchanged, with no `#if` guards in host code. `APIParityTests` enforces this. |

**If you add public API to Core or UI, you must add the inert twin to NoOp in
the same change.** Otherwise the failure surfaces as a broken release build
months later.

---

## Architecture

### Interception — three mechanisms

| # | Mechanism | Covers | Trigger |
|---|---|---|---|
| 1 | `URLProtocol.registerClass(LensURLProtocol.self)` | `URLSession.shared` | `start()` |
| 2 | Swizzled `URLSessionConfiguration.default` / `.ephemeral` getters | Any session built from those **after** `start()` | `start()` |
| 3 | `NetworkLens.install(into:)` | Any configuration you can reach | Explicit call |

Mechanism 2 is what makes a networking module in a separate package work
untouched — the module writes `URLSession(configuration: .default)` as always
and receives a configuration that already has the lens installed. It is also why
**ordering matters**: a session built before `start()` is invisible forever.

`LensSwizzler` guards every hook behind a `static let`, initialised once and
lazily. Double-swizzling is *not* a no-op — it restores the original IMP and
silently disables everything, presenting as "the tool stopped working" with no
error anywhere.

Task-creation hooks (`installTaskHooks`) exist purely for screen attribution:
`ScreenContext` must be read on the *caller's* thread at task creation. Reading
it later in `canInit` gives the delegate queue's screen, which is nobody's
screen. Gated by `automaticScreenAttribution`.

### `LensURLProtocol` — the hot path

`startLoading()` does **not** work synchronously. It defers onto a `Task` and
returns. `URLProtocol` only requires client callbacks to be called *eventually*.
This is what lets a breakpoint hold a request without blocking a thread — the
obvious semaphore-in-`startLoading` version deadlocks the moment two breakpoints
fire together and burns a thread per paused request. Do not "simplify" this.

Request properties carried through the protocol:
- `handledKey` — marks the passthrough leg. **Checked first in `canInit`**, else
  the passthrough request re-enters and recurses forever.
- `screenKey` — screen stamped at task creation.
- `exchangeIDKey` — identity carried from task creation so the recorded exchange
  and the breakpoint UI refer to the same thing.
- `replayOfKey` — set when the tool fired this itself.

Empty-case cost matters: `Mocks` / `Breakpoints` are consulted on every request,
so both short-circuit on an `isEmpty` check before any matcher chain runs.

### Endpoint identity

`RequestMatcher` turns a concrete request into a stable logical key
(`GET /users/{id}`). It is a protocol from day one because path comparison is a
REST-only assumption — GraphQL sends everything to `POST /graphql` and
identifies operations by a body field. `MatcherChain` tries matchers in order,
first non-nil wins, and never returns nil (falls back to method + path so an
unmatched request still groups instead of vanishing).

**Everything keys off `endpointKey`**: grouping, stats, mock rules, breakpoints,
scenarios.

### The three registries — deliberately identical

`Mocks.shared`, `Breakpoints.shared`, `Scenarios.shared` all share:
`NSLock` + `@unchecked Sendable`, an observer-token API, and the same relaunch
semantics. A reader who understands one understands all three. **Keep them
mirrored** — divergence is the main way this layer becomes hard to read.

- `Mocks` — rules keyed by `endpointKey` **plus** `MockMatch` conditions, so
  `page=1` and `page=2` are two rules, not one overwriting the other. `resolve`
  picks the *narrowest* match so the answer never depends on arming order.
  Rules hold many named `variants` with exactly one active. Hits keyed by rule
  `id` (not endpoint key) so replacing a rule restarts its count.
  `MockOutcome`: `.respond` / `.fail` / `.hang` / `.rewrite`.
  `MockExhaustion` for scripts: `.repeatLast` / `.loop` / `.passThrough`.
- `Breakpoints` — armed rules plus safety rules. Request editing is **off by
  default behind an explicit toggle**: editing a response is client-side and
  affects one screen; editing a request sends different data to a real backend
  and can create real records that outlive the session. `productionHostPatterns`
  guards it. Breakpoint identity is the URL when pinned, the endpoint key
  otherwise, so two exact-URL breakpoints on one endpoint stay distinct.
- `Scenarios` — a named set of rule states. `applied(in:)` is **verified, not
  remembered**: changing one endpoint by hand makes it go nil on its own, so the
  label can never claim a setup no longer in force.

`BreakpointCoordinator` is an `actor`. Several breakpointed requests fire
together on a screen load and stacking modals is unusable, so presentation is
serialised FIFO with the queue position shown. The isolation boundary is crossed
exactly twice per pause — publish the presented item, deliver the outcome — so
nothing hops threads inside the hold. Auto-resume fires at 80% of the app's own
timeout so a forgotten breakpoint cannot hang the app.

### Edits are patches, not bytes

Hand edits and perturbations are stored as `PatchOp`s (JSON Pointer based)
against the captured payload, with `originalHash` and `shapeDrifted`. A mock
written today still means something after the server adds a field. `JSONNode` is
a **lossless ordered** tree — key order and number literals survive a
parse/serialise round trip, which raw `JSONSerialization` does not give you.

Enabled perturbations apply in **save order** — ops compose, and two
perturbations touching the same path must resolve identically on every hit or
nothing is reproducible.

`NetworkExchange.source` carries provenance: `.live` / `.mocked` / `.edited` /
`.perturbed(name:)`. Keep it accurate — a synthetic exchange that reads as live
is the worst possible bug in a debugging tool.

### Storage, redaction, persistence

- `ExchangeStore` — bounded ring buffer, `NSLock`, oldest evicted at capacity.
  Reads return oldest-first; views reverse at the call site.
- **Redaction runs before persistence, not before display.** There must be no
  code path where a stored exchange still carries auth headers or payment
  fields. Anything new that writes to disk goes through `Redactor` first.
- `LensPersistence` owns *policy* (what survives a relaunch); `LensSnapshot`
  owns *format*. Autosave is suppressed while restoring, else replaying a
  snapshot writes it straight back out.
- Two flags, deliberately separate: `persistsRules` (is anything written at
  all) and `keepBreakpointsAcrossLaunches` (may anything come back **armed**).
  Default is the conservative pair — a forgotten mock reads as a backend bug and
  a forgotten breakpoint reads as a hang. `redactsPersistedRules` defaults on;
  CI setups often want it off so a token-carrying mock still works.

### UI layer

- `LensObservable` (`@MainActor`) bridges Core's lock-based stores to SwiftUI
  and hops change notifications onto the main actor. This adapter lives in UI
  precisely because Core must stay Combine-free.
- `PassthroughWindow` — invisible to touches except where it has content.
  Comparing the hit view against the root view **does not work**: SwiftUI draws
  the whole hierarchy into the hosting view, so every point hit-tests to the
  root. The content declares `interactiveRects` instead.
- `OverlayWindowController` keys windows by **scene**, not by app — attaching to
  the app delegate's window breaks iPad multi-window and split view.
- `RenderedBody` derives everything a body view needs **once, off the main
  thread**, and splits into lines. SwiftUI re-evaluates `body` on every store
  notification; a megabyte response was previously reparsed several times per
  captured request, and a single `Text` holding a megabyte lays the whole string
  out synchronously before the first frame.

---

## Conventions

- **Every source file carries the author header block** (`// FileName.swift /
  TargetName / Created by ...`). Match it on new files.
- **Comments explain *why*, never *what*.** This codebase's doc comments name
  the failure mode avoided ("the obvious semaphore version deadlocks…", "double
  swizzling silently disables everything…"). Restating the code is the wrong
  register here; so is a comment with no consequence in it.
- Public types are `Sendable` or `@unchecked Sendable` with an explicit lock.
  State the discipline in the doc comment.
- Commits: Conventional Commits, `type(scope): lowercase imperative summary`.
  Body explains the reasoning when non-obvious. See `git log`.
- Tests live beside the concept, one file per unit
  (`MocksTests`, `PatchOpTests`, `BreakpointCoordinatorTests`, …).
  `ReadmeSnippetTests` compiles the README's code — **if you change a README
  snippet, that test must still compile it.**

## Build and test

```bash
swift build
swift test                        # Core suite, headless, no simulator
swift test --filter MocksTests
```

`NetworkLensUITests` is intentionally empty on macOS — it needs an iOS simulator
destination to mean anything, since its job is compiling README UIKit lifecycle
snippets.

---

## Known limits (documented, not bugs)

- `WKWebView` traffic — outside the app's `URLProtocol` chain.
- Background sessions — transfers run in another process; `install(into:)`
  returns `false` rather than pretending. Listed in `NetworkLens.uninterceptable`.
- Non-`URLSession` stacks — gRPC, raw sockets, `Network.framework`.
- Streaming — SSE and chunked responses are buffered, so they arrive at once.

`NetworkLens.record(_:)` is the escape hatch for all four.

---

## Where to start

| Task | Files |
|---|---|
| Capture missing / wrong | `Interception/LensURLProtocol.swift`, `LensSwizzler.swift` |
| Endpoint grouping wrong | `Matching/*`, `Models/NetworkExchange.swift` |
| Mock not served | `Mocking/Mocks.swift` (resolve + narrowness), `MockRule.swift` |
| Breakpoint hangs / queues wrong | `Breakpoints/BreakpointCoordinator.swift` |
| Rule lost or wrong after relaunch | `Persistence/LensPersistence.swift`, `LensSnapshot.swift` |
| Secret on disk | `Redaction/DefaultRedactor.swift` — and add a test |
| Overlay swallows taps | `Window/PassthroughWindow.swift` |
| Main-thread stall on big bodies | `Views/BodyRenderer.swift` |
| Editing a field in the tree | `JSON/PatchOp.swift`, `Views/JSONTreeView.swift`, `JSONValueEditor.swift` |
| New public API | Core/UI **and** `NetworkLensNoOp/`, **and** `APIParityTests` |

## State

Published at `https://github.com/rohitsahay1996/NetworkLens.git`, `main`.
Core, UI, NoOp, persistence, mocking (variants / scripts / scenarios),
breakpoints, perturbations, replay, curl export and launch-argument scenario
activation are all shipped and covered by tests.

`1.3.0` closed what Core's comments call "milestone 4": `Trace/TraceWriter.swift`
writes redacted NDJSON to disk (off unless `TraceOptions` is passed), the
`capturedHostPatterns` allowlist drops uninteresting hosts at `canInit` before
they can evict real traffic from the ring buffer, and `Tools/networklens-mcp`
serves the trace to Claude Code as read-only query tools. The redaction and
clock seams (`Time/LensClock.swift`) were put in for exactly this.

`Control/LensControlChannel.swift` closed the gap that made the MCP server
read-only. The app polls a sidecar for commands and applies them to
`Mocks.shared` and `Scenarios.shared` in memory, so an agent changes what is
armed without a relaunch and without the tester losing the screen they were on.

Polling rather than listening is the whole design: a listener on iOS trips the
local-network prompt and dies with the app, while a queue on the host survives
the app being killed and relaunched — which is the lifecycle a mock-and-check
loop actually lives in. The verb names are the browser lens's, so one agent
vocabulary covers both platforms.

The queue itself is hosted by `Tools/networklens-mcp` (`src/queue.ts`) rather
than by a separate process, because a separate process is a thing a teammate has
to be given. That server already ships in the app repo and is already launched
by `.mcp.json`, so hosting it there is what makes a fresh clone work with nothing
extra installed. It binds 8788, not the browser sidecar's 8787: that one also
serves `/ingest`, and taking it would send the extension's traces into a 404
whenever the MCP server started first.

`Tests/NetworkLensCoreTests/Fixtures/mcp-edit-command.json` is real bytes
captured off that sidecar. The MCP server and this decoder are the seam that
breaks silently, and a hand-written approximation of the payload cannot catch
it — the first version of that test passed against an invented payload while the
real one was missing a required key.

Breakpoints are still not armable this way. `state` reports them; no verb writes
them. That is the next piece if this direction is continued.

The MCP server is read-only by design — arming a mock from an agent needs a
control channel into the running app, which does not exist yet. That is the next
piece if this direction is continued.
