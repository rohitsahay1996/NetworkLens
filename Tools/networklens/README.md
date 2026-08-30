# NetworkLens — dev/QA commands

Committed tooling for the on-device network interceptor. The framework itself
ships from the `BlibliLogger` SPM package (`NetworkLens` product); this directory
is only the host-side driver, plus `../networklens-mcp` for the MCP server.

```sh
tools/networklens/lens doctor            # simulator, app container, trace, mocks, hosts
tools/networklens/lens mock list         # what is armed right now
tools/networklens/lens mock seed --endpoint "flashsale/v2/facets"
tools/networklens/lens mock apply --spec tools/networklens/mocks/my-spec.json
tools/networklens/lens mock activate --rule "flashsale" --variant "Error 500"
tools/networklens/lens mock off
tools/networklens/lens trackers --ids ENG0002-0001 --contract mocks/example-tracker-contract.json
tools/networklens/lens trackers --new    # only fires since your last check
tools/networklens/lens hosts             # which hosts the lens captures
tools/networklens/lens hosts wwwuatb.gdn-app.com bwa-qa2-gcp.gdn-app.com
tools/networklens/lens hosts --reset
```

Nothing here needs a rebuild. Mock rules and the captured-host list live in the
simulator, read by the app at `start()` — so the cost of a change is a relaunch.

| Path | What |
|---|---|
| `lens` | the one entry point; everything below is reached through it |
| `write_mock.py` | writes rules into the simulator's `session.json` |
| `extract_trackers.py` | TRMS fires + payload contract checks, read from the trace |
| `mocks/` | spec files. Two committed examples; your own are gitignored |
| `reports/` | tracker validation output. Gitignored |

The app must be **quit** for a mock write to stick — it rewrites `session.json`
on every rule change and when it backgrounds. Mutating commands refuse a live app
unless `--force` is passed.

Prefer the skills over calling these by hand: `/api-mock`, `/tracker-validation`,
`/networklens-setup`.

## Which hosts get captured

Precedence, most explicit first:

1. `NETWORKLENS_HOSTS` — comma-separated, set in the Xcode scheme's environment
2. `NetworkLensCapturedHosts` in the app's `UserDefaults` — what `lens hosts` writes
3. the compiled defaults in `NetworkLensBootstrap.swift`

A host absent from the resolved list is invisible to the whole tool — mocks,
breakpoints and replay included. That filter is deliberate: unfiltered, one home
screen launch spent most of the 500-slot ring buffer on Firebase, MoEngage,
AppsFlyer, Forter and the image CDN, evicting the backend calls worth reading.

The `--bundle`/`NETWORKLENS_BUNDLE_ID` default is `com.blibli.mobile`.
