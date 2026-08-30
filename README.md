# NetworkLens

On-device network debugging for iOS. Capture traffic, mock it, break on it,
replay it — from inside the app. No proxy, no certificate, no desktop, and it
works on SSL-pinned builds because it sits *below* your networking stack rather
than in front of it.

Requires iOS 15+. No dependencies.

---

## Contents

1. [Install](#install)
2. [Quick start](#quick-start)
3. [How interception works](#how-interception-works) — read this before integrating
4. [Integration by architecture](#integration-by-architecture)
   - [Networking in the app target](#a-networking-in-the-app-target)
   - [Networking in your own module or framework](#b-networking-in-your-own-module-or-framework)
   - [Networking in a package you do not control](#c-networking-in-a-package-you-do-not-control)
   - [Alamofire, Moya and other wrappers](#d-alamofire-moya-and-other-wrappers)
   - [Delegate-based and multiple sessions](#e-delegate-based-and-multiple-sessions)
5. [The one ordering rule](#the-one-ordering-rule)
6. [Legacy UIKit: AppDelegate, no SceneDelegate](#legacy-uikit-appdelegate-no-scenedelegate)
7. [Screen attribution](#screen-attribution)
8. [Keeping it out of release builds](#keeping-it-out-of-release-builds)
9. [Verifying it works](#verifying-it-works)
10. [Troubleshooting](#troubleshooting)
11. [What it cannot see](#what-it-cannot-see)
12. [Using it](#using-it)
13. [Driving it from a UI test](#driving-it-from-a-ui-test)
14. [Reading the trace from an agent](#reading-the-trace-from-an-agent) — the MCP server
15. [API cheat sheet](#api-cheat-sheet)

---

## Install

Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/rohitsahay1996/NetworkLens.git", from: "1.0.0")
]

// Your app target
.product(name: "NetworkLens", package: "NetworkLens")
```

In Xcode: **File → Add Package Dependencies…**, paste
`https://github.com/rohitsahay1996/NetworkLens.git`, then add the
**NetworkLens** library to your **app target** (not to your networking
module — see below).

---

## Quick start

```swift
import SwiftUI
import NetworkLens

@main
struct MyApp: App {

    init() {
        NetworkLens.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .networkLensOverlay()
        }
    }
}
```

UIKit, with a scene delegate:

```swift
import NetworkLens

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions options: [...]?) -> Bool {
    NetworkLens.start()
    return true
}

// In your scene delegate, once the scene exists:
func sceneDidBecomeActive(_ scene: UIScene) {
    guard let windowScene = scene as? UIWindowScene else { return }
    NetworkLens.attachOverlay(to: windowScene)
}
```

No scene delegate — an app delegate that still owns `var window: UIWindow?`?
See [Legacy UIKit](#legacy-uikit-appdelegate-no-scenedelegate).

For many apps that is the entire integration. Whether it is enough for *yours*
depends on where your sessions come from, which the next section explains.

---

## How interception works

There are three mechanisms. Knowing which one covers your app is the whole of
integration.

| # | Mechanism | Covers | Needs |
|---|---|---|---|
| 1 | `URLProtocol.registerClass` | `URLSession.shared` | `start()` only |
| 2 | Swizzled `URLSessionConfiguration.default` / `.ephemeral` getters | Any session built from those **after** `start()` | `start()` only |
| 3 | `NetworkLens.install(into:)` | Any configuration you can reach | One call |

`start()` sets up 1 and 2. Mechanism 2 is what makes a networking module in a
separate package work without touching it: the module writes
`URLSession(configuration: .default)` as it always did, and the configuration it
receives already has the lens installed.

Mechanism 3 is the escape hatch for a configuration the swizzle never handed
out — one obtained before `start()` ran, one copied and passed around by a
module, or one you simply want to be explicit about.

> `URLSessionConfiguration` has no usable initialiser. Every configuration comes
> from `.default`, `.ephemeral` or `.background(withIdentifier:)`; calling
> `URLSessionConfiguration()` traps at runtime. So mechanism 2 covers the two
> configurations that can exist in an interceptable form — which is why so many
> apps need no integration work at all.

### What the real request runs on

An intercepted request is re-sent by the lens, on the lens's own session. That
session's configuration is therefore what your traffic actually gets, and three
things follow:

- **`install(into:)` is how the lens learns your configuration.** It copies the
  one you pass and uses it for the real leg, so additional headers, credentials,
  proxies, connectivity rules and — most importantly — your cookie jar survive.
  Without it the lens falls back to a copy of `URLSessionConfiguration.default`,
  which shares `HTTPCookieStorage.shared` and is the right answer for
  `URLSession.shared` and any `.default` session. An app with a private cookie
  store should install explicitly.
- **Caching is off on that leg**, deliberately: a response served from a cache
  is one the lens never sees and cannot mock, edit or export.
- **Redirects are handed back to your app.** The lens stops at the 3xx, records
  it as its own row, and lets the URL loading system carry on — so your
  `willPerformHTTPRedirection` still runs and every hop appears on the timeline.
  A *mocked* 3xx is delivered as a plain response instead; following it would
  send a mocked request to a real server.

---

## Integration by architecture

### A. Networking in the app target

Nothing beyond the quick start. `URLSession.shared` is covered by mechanism 1,
and anything you build from `.default` or `.ephemeral` is covered by mechanism 2.

If you customise a configuration, installing explicitly costs nothing and
removes any doubt about ordering:

```swift
let configuration = URLSessionConfiguration.default
configuration.timeoutIntervalForRequest = 30
configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
NetworkLens.install(into: configuration)          // already true after start(),
                                                  // harmless to repeat
let session = URLSession(configuration: configuration)
```

### B. Networking in your own module or framework

The common shape: a `CoreNetwork` package or framework that the app imports.

**Do not add NetworkLens to that module.** It ships to production, and a
debugging tool has no business in its dependency graph — every consumer would
inherit it.

If the module builds sessions from `.default` or `.ephemeral`, you are already
done: mechanism 2 covers it, and the module never learns the lens exists.

If it builds its own configuration, give the app a way in. One property is
enough:

```swift
// CoreNetwork — no NetworkLens import
public enum CoreNetwork {
    public static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }()

    public static var session = URLSession(configuration: configuration)
}
```

If that `configuration` is built lazily *after* `start()`, mechanism 2 has
already installed the lens and there is nothing to do. The explicit form below
is for when you cannot be sure of the order — which, with a `static let`
initialised on first use, is most of the time.

```swift
// App target
NetworkLens.start()
NetworkLens.install(into: CoreNetwork.configuration)
CoreNetwork.session = URLSession(configuration: CoreNetwork.configuration)
```

The reassignment matters: a `URLSession` copies its configuration at
construction, so installing into the configuration afterwards has no effect on a
session that already exists.

Alternatively, expose a seam the app can fill without exposing the configuration
at all:

```swift
// CoreNetwork
public enum CoreNetwork {
    /// Set by the app in debug builds. Ignored in production.
    public static var configureSession: ((URLSessionConfiguration) -> Void)?
}

// App
CoreNetwork.configureSession = { NetworkLens.install(into: $0) }
```

### C. Networking in a package you do not control

A third-party SDK, or an internal package you cannot edit this week.

If it uses `URLSession.shared` or builds from `.default`/`.ephemeral`, it is
already captured — you need nothing. This covers most SDKs.

If it builds its configuration before your `start()` runs and exposes no hook,
its traffic is out of reach. Your options, in order of preference:

1. Ask for a configuration hook. One optional closure, as above.
2. Record it yourself at the boundary where you call the SDK:

   ```swift
   NetworkLens.record(
       NetworkExchange(
           endpointKey: "POST /sdk/upload",
           request: RequestSnapshot(method: "POST", url: url),
           response: ResponseSnapshot(statusCode: 200, headers: [:], body: data)
       )
   )
   ```

   Manual, but it puts the call on the same timeline as everything else, which
   is usually the thing you actually wanted.

### D. Alamofire, Moya and other wrappers

They sit on `URLSession`, so the lens sits under them.

```swift
// Alamofire
let configuration = URLSessionConfiguration.af.default
NetworkLens.install(into: configuration)
let session = Alamofire.Session(configuration: configuration)
```

Moya, and anything built on Alamofire, takes the same `Session`:

```swift
let provider = MoyaProvider<MyAPI>(session: session)
```

Alamofire's own `Session.default` is built from `URLSessionConfiguration.af.default`,
which derives from `.default` — so it is covered by mechanism 2 as long as
`start()` ran first. Constructing your own `Session` is still the clearer choice.

### E. Delegate-based and multiple sessions

Delegates are irrelevant to interception — the lens works at the protocol layer,
below the delegate. Install into the configuration as usual:

```swift
let configuration = URLSessionConfiguration.default   // covered automatically
let session = URLSession(configuration: configuration,
                         delegate: self,
                         delegateQueue: nil)
```

Multiple sessions are fine. Install into each configuration you build yourself;
anything from `.default`/`.ephemeral` needs nothing.

---

## The one ordering rule

> **Call `NetworkLens.start()` before your app creates any session.**

Mechanism 2 hooks the configuration *getter*. A session built before `start()`
ran holds a configuration that was handed out before the hook existed, and it
will never be intercepted.

This bites when a networking module holds a `static let session`, because Swift
initialises it lazily on first use — which may be before or after your `start()`
depending on what touches it first. Two safe patterns:

```swift
// Either: start first, in the app's init / didFinishLaunching, and make sure
// nothing touches the networking module before that line.
init() { NetworkLens.start() }
```

```swift
// Or: install explicitly and rebuild the session, which works regardless of
// ordering.
NetworkLens.start()
NetworkLens.install(into: CoreNetwork.configuration)
CoreNetwork.session = URLSession(configuration: CoreNetwork.configuration)
```

`URLSession.shared` is immune to this — mechanism 1 covers it whenever `start()`
happens to run.

---

## Legacy UIKit: AppDelegate, no SceneDelegate

An app that predates iOS 13 has no `SceneDelegate` and no
`UIApplicationSceneManifest` in its `Info.plist`. The app delegate builds the
window itself:

```swift
window = UIWindow(frame: UIScreen.main.bounds)
window?.rootViewController = RootViewController()
window?.makeKeyAndVisible()
```

Interception does not care. `start()` works identically — it hooks
`URLProtocol` and the configuration getters, neither of which knows what a scene
is. **Capture, mocking, breakpoints and replay all work with no changes.**

Only the overlay needs thought, because `attachOverlay(to:)` takes a
`UIWindowScene` and this app never sees one. Full integration:

```swift
import UIKit
import NetworkLens

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // First line of the method. Everything below may build a session, and
        // a session built before this line is never intercepted.
        NetworkLens.start()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = RootViewController()
        window?.makeKeyAndVisible()

        showLensOverlay()
        return true
    }

    private func showLensOverlay() {
        // makeKeyAndVisible() has run, so the window is on screen and iOS has
        // given it a scene.
        if let scene = window?.windowScene {
            NetworkLens.attachOverlay(to: scene)
            return
        }

        // One retry, next runloop tick, for the case where it has not. Not a
        // loop — see the warning below.
        DispatchQueue.main.async {
            NetworkLens.attachOverlayToActiveScene()
        }
    }
}
```

There is no compatibility shim involved: iOS 13+ runs a scene-less app inside
one implicit `UIWindowScene` anyway, so `window?.windowScene` is the same handle
a modern app passes in, obtained a different way.

> **Never write `while !NetworkLens.attachOverlayToActiveScene() { }`, or retry
> on a timer until it returns `true`.** In a release build the call is the inert
> mirror and always returns `false`, so that loop never ends — a debug-only
> convenience turning into a shipped hang. Attempt it a bounded number of times
> and let it fail quietly.

### Objective-C app delegates

The package is Swift-only and exposes no `@objc` surface, so an
`AppDelegate.m` cannot call it. Add one Swift file and call that:

```swift
// LensBootstrap.swift
import UIKit
import NetworkLens

@objc final class LensBootstrap: NSObject {

    @objc static func start() {
        NetworkLens.start()
    }

    // @MainActor because attachOverlay(to:) is. Without it this does not
    // compile, which is easy to miss in a shim that looks like plumbing.
    @MainActor
    @objc static func attachOverlay(to window: UIWindow) {
        guard let scene = window.windowScene else { return }
        NetworkLens.attachOverlay(to: scene)
    }
}
```

```objc
// AppDelegate.m
#import "YourApp-Swift.h"

[LensBootstrap start];
// ...after makeKeyAndVisible
[LensBootstrap attachOverlayToWindow:self.window];
```

Keep the shim thin. Everything it wraps is inert in a release build, so the
shim inherits that and needs no `#if` of its own.

### Screen attribution from view controllers

The ambient API is the natural fit here, because a view controller has exactly
the lifecycle it wants — but read the caveat under
[Screen attribution](#screen-attribution) first: it is wrong for a controller
that presents another one which also fires requests.

```swift
final class CheckoutViewController: UIViewController {

    private var lensToken: UUID?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lensToken = ScreenContext.shared.push("Checkout")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let lensToken { ScreenContext.shared.pop(lensToken) }
    }
}
```

Prefer `NetworkLens.tagged(request, screen:)` when a screen fires several calls
at once.

---

## Screen attribution

Grouping traffic by screen turns a list into an explanation, which matters most
on a screen firing four calls. Three ways, most specific first.

**1. Per request, from the app** — correct when a screen fires several calls
concurrently, because attribution travels with the request rather than with the
caller:

```swift
let tagged = NetworkLens.tagged(request, screen: "Checkout")
let (data, response) = try await session.data(for: tagged)
```

**2. By header, from a module that cannot import the lens** — no dependency, no
linking, no conditional compilation:

```swift
// In CoreNetwork. Just a string on a request.
request.setValue(screenName, forHTTPHeaderField: "X-NetworkLens-Screen")
```

The lens reads it and **strips it before the request goes out**, so a server
never sees it — and neither does the capture or a `curl` export, which would
otherwise fail to reproduce. Remove the lens and you are left with a header
nobody reads.

**3. Ambient, for a screen that owns everything it fires:**

```swift
.onAppear { token = ScreenContext.shared.push("Checkout") }
.onDisappear { ScreenContext.shared.pop(token) }
```

Avoid #3 when several screens can be pushing concurrently — the innermost one
wins and the attribution is whichever task got there first.

---

## Keeping it out of release builds

`import NetworkLens` resolves to the real tool or to an inert mirror with an
identical API. You never edit the import.

| Condition | Resolves to |
|---|---|
| `NETWORKLENS_DISABLED` defined | inert mirror |
| otherwise | real tool |

Two switches, answering different questions. The one above is **compile time**:
is the code in the binary at all. `LensConfiguration.isEnabled` is **runtime**:
is it allowed to run. A feature flag can only ever answer the second — it cannot
un-link a module — which is why both exist.

```swift
// Ships in every build, dormant unless the flag says otherwise.
NetworkLens.start(configuration: LensConfiguration(isEnabled: staffFlag))
```

Off means off: no `URLProtocol` registration, no swizzling, no restored rules,
no trace writer, no overlay. Not a filter that drops exchanges after capturing
them. `canInit` re-checks the gate on every request, because
`URLProtocol.registerClass` is process-wide and an earlier enabled `start()`
cannot be un-registered out of a swizzle.

**Read the flag at launch.** Interception only reaches sessions created after
`start()`, so a flag resolved three seconds in has already missed the calls
worth seeing. Cache the last known value, act on the cached one, refresh it for
next launch.

The lens does not key off `DEBUG`. "Release" and "shipping to the App Store" are
not the same thing — a team handing TestFlight builds to QA needs the lens in a
Release configuration, and configuration-sniffing left that team fighting the
framework. So: real by default, opt out per configuration with
`NETWORKLENS_DISABLED`.

That default is deliberate and has teeth — every configuration that omits the
flag links and runs the real interceptor, **including an App Store archive**. An
app that must not ship the lens defines `NETWORKLENS_DISABLED` in its store
configuration, or takes strategy 1 below.

The mirror is a hand-written twin of the entire public API whose methods do
nothing, so every call site compiles untouched. A dedicated test target compiles
host-shaped code against it, so the build fails the day the two diverge rather
than months later in a release build.

One caveat worth knowing if you run the tests yourself: the overlay half of that
surface is UIKit-only, so `swift test` on macOS cannot see it. Run the package
against an iOS simulator destination to check those call sites — that gap is
exactly how the mirror once went several versions without
`networkLensOverlay()`.

**Three strategies, strictest first:**

1. **Provable removal** — link `NetworkLensNoOp` in your store configuration and
   `NetworkLensUI` elsewhere, no umbrella. Your release binary contains no lens
   code at all, demonstrably.
2. **Umbrella + `NETWORKLENS_DISABLED`** — one import, both modules linked, one
   compiled away. The linker strips the dead one in practice but does not
   guarantee it on paper.
3. **Ship it everywhere** (the default above) — define nothing, and every build
   carries the lens, TestFlight and App Store alike.

Whichever you pick, keep `start()` and the overlay calls behind the same
condition. `.networkLensOverlay()`, `attachOverlay(to:)`, `detachOverlay(from:)`
and `attachOverlayToActiveScene()` are all no-ops in the mirror, so they are
safe to leave in place — including the app delegate wiring in
[Legacy UIKit](#legacy-uikit-appdelegate-no-scenedelegate).

---

## Verifying it works

1. Launch the app. The floating bubble appears.
2. Trigger a request. The bubble's badge count increases.
3. Tap it → **Traffic**. Your request is listed with method, status and timing.
4. Open it → **Actions → Add a mock…**, save a variant, fire the request again.
   The row is badged `MOCKED`.

If step 2 never happens, see the next section.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No traffic at all | `start()` never ran, or ran after the session was built | Move `start()` earlier; see [the ordering rule](#the-one-ordering-rule) |
| Some traffic missing | That session uses a configuration the lens never saw | `NetworkLens.install(into:)` on it |
| One SDK's traffic missing | It builds its own configuration, or does not use `URLSession` | Configuration hook, or `record(_:)` |
| A host's traffic missing, everything else fine | `capturedHostPatterns` is non-empty and that host is not in it, **or the Hosts list is locked** | Check the Session tab: a locked list shows a padlock and the unpinned hosts read "not captured". Unlock, or add the host to `capturedHostPatterns`. An excluded host is dropped at `canInit`, so mocks, breakpoints and replay cannot reach it either |
| Nothing captured, no error | A background configuration | Check `NetworkLens.uninterceptable`; background transfers are impossible to intercept |
| `WKWebView` requests missing | Out of `URLProtocol`'s reach | Not supported — see below |
| Mocks not served | Master switch off, or rule disabled | Mocks tab → *Mocking enabled*; the bubble turns purple when mocks are serving |
| Bubble never appears | `.networkLensOverlay()` missing, or no active scene | Attach it, or call `attachOverlay(to:)` from the scene delegate |
| A launch-argument scenario did nothing | Persistence is off, so there was nothing on disk to name | `persistsRules: true` **and** `keepBreakpointsAcrossLaunches: true` — see [Driving it from a UI test](#driving-it-from-a-ui-test); the overlay also shows the miss and the names it did find |
| Mocks vanish on relaunch | Default behaviour — **both** persistence flags default to `false`, so nothing is written and nothing comes back | `LensConfiguration(keepBreakpointsAcrossLaunches: true, persistsRules: true)` — the second decides whether anything is written at all, the first whether it may come back *armed*. Either one alone still loses mocks |
| Mocks come back but behave differently | `redactsPersistedRules` scrubbed the token out of the saved copy | `redactsPersistedRules: false`, deliberately — the rule then lands on disk carrying whatever the response carried |
| Auth fails only with the lens attached | The real leg is not carrying your session's cookies or headers | `NetworkLens.install(into:)` with the configuration your app actually uses — it is copied for that leg |
| A captured body is cut short | Longer than `maxCapturedResponseBodyBytes` | Expected: the app received it whole, the capture keeps a prefix and reports `originalBodyByteCount` |

`NetworkLens.uninterceptable` lists every configuration the lens was asked to
install into and could not, so a tester can be told rather than left guessing.

---

## What it cannot see

Stated plainly, because discovering these by surprise wastes an afternoon:

- **`WKWebView` traffic.** Web views do their networking outside the app's
  `URLProtocol` chain.
- **Background sessions.** `URLSessionConfiguration.background(withIdentifier:)`
  runs transfers in another process, where a custom `URLProtocol` is never
  consulted. `install(into:)` returns `false` rather than pretending.
- **Non-`URLSession` stacks.** gRPC, raw sockets, `Network.framework`, and SDKs
  with their own transport.
- **Streaming.** SSE and chunked responses are buffered, so they arrive all at
  once rather than incrementally.
- **Any host you excluded.** `capturedHostPatterns` is empty by default, which
  captures everything. Naming hosts turns it into an allowlist and everything
  else is dropped at `canInit` — no capture, no trace line, and no mock,
  breakpoint or replay on that host either. **Lock to shown** in the Session tab
  does the same thing at runtime; see below.

For the first three, `NetworkLens.record(_:)` puts an exchange on the timeline by
hand, which is worth doing at the boundary of anything important.

### Sharing scenarios

A scenario is a set of pointers: endpoint key, match, variant. Sending someone
that file alone gives them a scenario that resolves to nothing — and it fails
quietly, applying and reporting success while the app serves live traffic. So
the shareable unit is a **pack**: the scenarios plus the rules they reference,
as one JSON file.

From the Scenarios tab:

| Action | What it does |
|---|---|
| **Export all as a pack…** | Every saved scenario plus its rules, named, out through the share sheet — Files, AirDrop, Slack |
| Long-press a scenario → **Export as a pack…** | Just that one |
| **Import a pack…** | Files picker; merges and reports what was added, replaced and unresolved |

Bodies are redacted on the way out, because the file is going somewhere else —
a repository, a ticket, a chat thread. `ScenarioPack.exporting(redactedBy: nil)`
opts out for the case where a token's fidelity is what is being tested.

Import replaces by endpoint key and match, never by id: the same endpoint mocked
on two devices has two ids, and matching on those would duplicate every rule on
every import. The pack wins on conflict — someone is being handed a state to
reproduce, and a merge that kept half their local edits would reproduce
something else — and the outcome says how much it overwrote.

A pack that names a rule it does not carry says so before the file is written
(`unresolved`), rather than on the other person's device where the only symptom
is a scenario that does nothing.

Packs are app content, not tool code: keep the real ones in the app's own
repository, next to the endpoints they mock, so a pack changes in the same pull
request as the API that changed.

```swift
let pack = ScenarioPack.exporting(Scenarios.shared.all, from: Mocks.shared.all, named: "Checkout states")
try pack.encoded().write(to: url)

let outcome = try ScenarioPack.decoding(Data(contentsOf: url)).import()
outcome.isComplete   // false when an entry still points at nothing
```

### Locking the host list

The Session tab's **Hosts** section carries two independent controls, and the
difference matters:

| Control | Scope | Effect |
|---|---|---|
| Checkmark | visibility | Hides a host from the Traffic list and the bubble badge. Still captured, still mockable, still breakpointable, still in Session stats. Persisted. |
| **Padlock**, per row | capture | Pins that host. While any host is padlocked, those hosts are the only ones intercepted — everything else is dropped at `canInit`. Persisted, and applied before the first request of the next launch. |

The padlock is per host rather than a single bulk action, because a lock is
built up: pin one backend, watch a screen, pin a second when the next screen
turns out to need it. Tap another row's padlock to add it; tap a closed one to
drop it; **Unlock all** releases everything. Nothing has to be released to add
something.

Locking solves the problem the checkmark cannot: narrow to one backend, navigate
to another screen, and that screen's SDKs and image CDNs pour into the 500-slot
ring buffer and evict what you were reading. Hiding rows does not stop that;
locking does.

While locked, `capturedHostPatterns` is overridden — the tester's decision, made
while looking at real traffic, outranks the one the app hardcoded at `start()`.
Matching is exact host equality, with no suffix or wildcard expansion: the set
comes from hosts the tool itself listed, and a lock that quietly admitted
`eu.api.acme.com` because `api.acme.com` was pinned would not be a lock.

Unpinned hosts stay listed rather than vanishing. Interception is what teaches
the tool a host exists, so a lock would otherwise erase its own escape route —
the next unknown domain would never appear anywhere, and you would have no way to
add it. `HostInventory` records every host the capture gate is asked about,
before the decision to drop it, so the list stays complete and any domain is one
unlock away.

Locking mid-session keeps what is already captured. Only new traffic is affected.

---

## Using it

**Capture** — endpoint keys with path templating (`GET /users/{id}`), GraphQL
operation names, a timing breakdown from `URLSessionTaskMetrics`, redaction,
per-screen grouping, session stats.

**Mock** — save any captured response as a named variant, then switch between
`empty` / `500` / `expired token` in one tap. Scenarios flip a whole screen's
endpoints at once, and **packs** take those scenarios off the device — see
[Sharing scenarios](#sharing-scenarios). Scripts express sequences (fail → fail → succeed). Latency,
transport failures as real `URLError`s, and a `.hang` outcome that holds a
request open so the loading state is reachable at all.

```swift
// Everything the UI does is available programmatically, for UI tests too.
Mocks.shared.set(
    MockRule(endpointKey: "GET /cart", response: .json(#"{"items":[]}"#), name: "empty")
)
Mocks.shared.set(
    MockRule(endpointKey: "GET /cart", steps: [.hang], name: "stuck loading")
)
```

**Break** — pause a request or response, edit body or status, resume. Queued
FIFO, with auto-resume at 80% of the app's own timeout so a forgotten breakpoint
cannot hang the app.

**Perturbations** — a saved JSON-patch edit applied automatically, forever, with
drift detection when the response shape moves under it.

**Replay** — re-fire a captured request, or a whole screen's, through the full
pipeline so armed mocks and variants apply.

**Edit** — tap a field in the response tree to change it, empty a list, null a
value, or duplicate a row a hundred times to push a paginated screen past its
page size. Edits are stored as JSON-patch ops against the captured payload, not
as rewritten bytes, so a mock written today still means something after the
server adds a field.

**Export** — copy any request as `curl`, redacted by default, or copy a whole
body to the pasteboard from the tree.

---

## Driving it from a UI test

Everything the overlay does is reachable in code, which is the point: a setup
built by hand once should not have to be rebuilt by hand ever again.

Build the scenario in the app, then name it at launch:

```swift
// UITests
let app = XCUIApplication()
app.launchArguments += ["-NetworkLensScenario", "cart empty"]
app.launch()
```

or, when a test plan makes arguments awkward, through the environment:

```swift
app.launchEnvironment["NETWORKLENS_SCENARIO"] = "cart empty"
```

The name is matched ignoring case and surrounding whitespace. An argument beats
the environment, so a scheme can set a default that a single run overrides.

**This needs persistence on.** A launch argument names a scenario saved on a
previous run, and nothing is read off disk unless you ask for it. The CI path is
the one case where persistence is unambiguously wanted:

```swift
NetworkLens.start(
    configuration: LensConfiguration(
        keepBreakpointsAcrossLaunches: true,   // let saved rules come back armed
        persistsRules: true,                   // ...and be written in the first place
        redactsPersistedRules: false           // a mock that needs its token to work
    )
)
```

Consider `redactsPersistedRules: false` here specifically. It defaults on, and it
is the right default for a device someone carries around — but a mock whose token
was scrubbed will not satisfy an app that reads that token back, and a test
failing for that reason is a long afternoon.

Apply one directly instead, if you would rather not depend on what is on disk:

```swift
let activation = NetworkLens.applyScenario(named: "cart empty")
XCTAssertTrue(activation.isApplied, activation.summary)
```

It returns rather than throws, and reports a miss as data — because a test that
asks for a scenario, silently gets live traffic and passes anyway is reporting
green about a state it never entered. When a launch argument misses, the overlay
says so on screen and `NetworkLens.launchScenarioActivation` carries the same
answer.

---

## Reading the trace from an agent

`TraceOptions` writes every finished exchange to a newline-delimited JSON file,
redacted, which is what makes the session readable by something other than the
overlay:

```swift
NetworkLens.start(configuration: LensConfiguration(trace: TraceOptions()))
// NetworkLens.traceURL reports where it landed.
// NetworkLens.flushTrace() blocks until queued lines have been written.
```

Off by default, for the same reason `persistsRules` is — a debugging tool should
not start writing a host app's traffic to disk uninvited.

An exchange is written when it finishes and again on every later edit, so the
last line for an id is its current state and the earlier ones are the audit
trail. `TraceOptions(includesBodies: false)` keeps headers, status and timing
without the payloads; the file rotates at `maxBytes` keeping one generation.

### The control channel

Rules normally reach the app through the session file, which it reads at
`start()` — so a change means a relaunch, and a relaunch means losing whatever
screen the tester had walked to. The control channel is the way around that.

```swift
LensConfiguration(
    capturedHostPatterns: hosts,
    persistsRules: true,
    trace: TraceOptions(),
    control: ControlOptions()
)
```

The app then polls `http://127.0.0.1:8788/commands` every two seconds and
applies whatever it collects. It **polls rather than listens** on purpose: a
listener on iOS trips the local-network permission prompt and dies with the app,
while a queue on the host survives the app being backgrounded, killed and
relaunched.

**There is nothing to start.** The queue is hosted by the `networklens` MCP
server, which an MCP client launches from `.mcp.json` on its own — so a fresh
clone is live with nothing extra installed. `lens_live` reports which endpoint
is in use and whether an app is answering on it.

Port 8788, deliberately not the browser sidecar's 8787: that one also serves
`/ingest`, and taking it would send the extension's traces into a 404 whenever
this server happened to start first. To drive an app from the browser sidecar
instead, point this server at it and it will host nothing:

```bash
NETWORKLENS_SIDECAR=http://127.0.0.1:8787
```

| Verb | Does |
|---|---|
| `state` | Reports the rules, the master switch and the armed breakpoints |
| `arm` | Adds a variant to an endpoint, creating the rule if there is none |
| `disarm` | Disables one rule, or all of them with no `endpointKey` |
| `variant` | Activates a variant by name, and names the available ones on a miss |
| `scenario` | Imports a pack and applies its first scenario |
| `edit` | Installs whole rules, drops rules by substring, sets the master switch |
| `export` | Returns the device's rules and scenarios as a pack |

The names match the browser lens exactly, so an agent's vocabulary does not fork
per platform. `edit` is the one the MCP server uses: reading a trace and
building a five-variant rule from it is logic that belongs where the trace is,
so the wire carries the finished rule rather than describing it a field at a
time.

Two limits worth knowing. Loopback means the simulator and the host Mac, never a
device. And breakpoints cannot be armed this way — `state` reports them, but no
verb writes them.

### The MCP server

`Tools/networklens-mcp` serves that file to an MCP client such as Claude Code,
so an agent reads the app's real requests instead of being told about them. Its
write tools reach a running app through the control channel below, and fall back
to the session file — which the app reads at launch — when nothing is listening.
`lens_live` says which of the two a write is about to take.

```bash
cd Tools/networklens-mcp
npm install && npm run build
```

Point it at a trace. Precedence is `NETWORKLENS_TRACE` →
`NETWORKLENS_BUNDLE_ID` (booted simulator) → the host's own Application Support:

```jsonc
// .mcp.json, in the app repo
{
  "mcpServers": {
    "networklens": {
      "command": "node",
      "args": ["/absolute/path/to/NetworkLens/Tools/networklens-mcp/dist/index.js"],
      "env": { "NETWORKLENS_BUNDLE_ID": "com.example.myapp" }
    }
  }
}
```

| Tool | Returns |
|---|---|
| `lens_status` | Trace path, exchange count, sessions. Start here when nothing else returns rows |
| `lens_list` | One line per exchange — id, status, ms, size, screen, endpoint, flags. Never bodies |
| `lens_get` | Headers, timing and metadata for one exchange |
| `lens_body` | A JSON-Pointer slice of one body, or a depth-collapsed outline |
| `lens_search` | Key/value match across bodies → pointers to read, not payloads |
| `lens_stats` | Counts by status and endpoint, slowest calls, mocked vs live |
| `lens_curl` | One request rebuilt as curl |
| `lens_diff` | Two exchanges — status, timing, and which body pointers differ |

Every tool is summary-first on purpose: a megabyte response pasted whole into a
model's context makes its answers worse, not better, so bodies are reached
through `lens_body` by pointer or depth cap and clipped at 8k characters even
then. A physical device has no path the Mac can read — pull the container with
Xcode (Devices → app → Download Container) and set `NETWORKLENS_TRACE` to the
`trace.ndjson` inside it. Full detail in
[`Tools/networklens-mcp/README.md`](Tools/networklens-mcp/README.md).

## API cheat sheet

```swift
// Lifecycle
NetworkLens.start(configuration: LensConfiguration = .default)
NetworkLens.install(into: URLSessionConfiguration) -> Bool
NetworkLens.canIntercept(_: URLSessionConfiguration) -> Bool
NetworkLens.uninterceptable: [String]

// Overlay — all @MainActor
View.networkLensOverlay()                // SwiftUI
NetworkLens.attachOverlay(to: UIWindowScene)
NetworkLens.detachOverlay(from: UIWindowScene)
NetworkLens.attachOverlayToActiveScene() -> Bool   // never loop on this

// Attribution
NetworkLens.tagged(_ request: URLRequest, screen: String) -> URLRequest
LensHeaders.screen                       // "X-NetworkLens-Screen"
ScreenContext.shared.push(_:) / .pop(_:)

// Escape hatch
NetworkLens.record(_ exchange: NetworkExchange)

// Rules, programmatically
Mocks.shared.set(_:) / .activateVariant(_:forRuleID:) / .setMockingEnabled(_:)
Breakpoints.shared.set(_:) / .save(_ perturbation:)
Scenarios.shared.save(_:) / .apply(_:) / .scenario(named:)

// UI tests and CI
NetworkLens.applyScenario(named: String) -> ScenarioActivation
NetworkLens.launchScenarioActivation: ScenarioActivation?
LensLaunchOptions.scenarioFlag            // "-NetworkLensScenario"
LensLaunchOptions.scenarioEnvironmentKey  // "NETWORKLENS_SCENARIO"

// Export and replay
CurlExport.command(for: exchange, secrets: .redacted)
NetworkLens.replay(_ exchange: NetworkExchange) async throws

// Trace
NetworkLens.traceURL: URL?
NetworkLens.flushTrace()
TraceOptions(url:maxBytes:includesBodies:)
```

### Configuration

```swift
NetworkLens.start(
    configuration: LensConfiguration(
        matchers: [GraphQLMatcher(), PathMatcher()],
        redactor: DefaultRedactor(),
        maxStoredExchanges: 500,
        // Swizzles task creation so `ScreenContext` is read on the caller's
        // thread. Turn off if your team would rather not have task-creation
        // hooked; per-request tagging and the header still work.
        automaticScreenAttribution: true,
        maxCapturedRequestBodyBytes: 1_048_576,
        // What is *retained*, not what is delivered: the app always receives
        // the whole body, and anything past the cap is dropped on the way into
        // the ring buffer, with the real size kept as `originalBodyByteCount`.
        maxCapturedResponseBodyBytes: 1_048_576,
        // Empty by default, which captures everything. Naming hosts here drops
        // everything else at `canInit` — no interception, no ring-buffer slot,
        // no trace line — which is what keeps a chatty analytics SDK from
        // evicting the API calls you opened the lens to read. The cost is that
        // mocks, breakpoints and replay cannot reach an excluded host either.
        capturedHostPatterns: ["api.myapp.com"],     // "" or omitted = capture everything
        productionHostPatterns: ["api.myapp.com"],   // guards request editing
        // Both persistence flags default to *false* — out of the box nothing
        // is written and nothing comes back. The pair shown here is the
        // conservative opt-in: rules are written to disk, but only
        // perturbations are allowed back. Set keepBreakpointsAcrossLaunches to
        // true as well for mocks and breakpoints to return armed — a forgotten
        // mock reads as a backend bug, and a forgotten breakpoint as a hang,
        // which is why neither is on by default.
        keepBreakpointsAcrossLaunches: false,        // nothing comes back armed (default)
        persistsRules: true,                         // rules survive a relaunch (default: false)
        redactsPersistedRules: true                  // and are scrubbed on disk (default)
    )
)
```
