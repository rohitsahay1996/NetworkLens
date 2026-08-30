---
name: tracker-validation
description: Validates that analytics trackers actually fired on device, with the right payload, by reading the NetworkLens trace of a simulator session. Use for "validate trackers", "did my trackers fire", "check TRMS IDs", "tracker QA", "verify analytics for IOS-1234", "watch trackers while I tap". Produces the DA-format Trackers Validation table (event, contract link, trigger point, payload, status), checks payload fields against an expected contract, supports a live watch mode while the tester navigates, and can publish the result to Confluence or comment it on the JIRA ticket.
argument-hint: [TRMS IDs (comma-separated) or a JIRA ticket key]
allowed-tools: [Bash, Read, Write, Grep, Glob, AskUserQuestion, mcp__networklens__lens_status, mcp__networklens__lens_stats, mcp__networklens__lens_search, mcp__networklens__lens_get, mcp__networklens__lens_body, mcp__atlassian__getJiraIssue, mcp__atlassian__addCommentToJiraIssue, mcp__atlassian__getConfluencePage, mcp__atlassian__createConfluencePage, mcp__atlassian__updateConfluencePage, mcp__atlassian__getConfluenceSpaces]
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
# Tracker Validation — Did It Fire, and Was the Payload Right

Reads the NetworkLens trace written by the running app
(`Library/Application Support/NetworkLens/trace.ndjson`) and reports, per TRMS ID:
did it fire, how often, on which endpoint, with what payload — and, when an
expected-payload contract is supplied, what is wrong with that payload.

This is **evidence from the device**, not a code read. It complements
`ios-analytics-tracker` (which writes tracker code); this skill proves the code
works at runtime. Everything runs through
`tools/networklens/extract_trackers.py`.

**This skill never builds or launches the app.** The user runs it in Xcode and
taps through the flow; this skill reads what the app left behind.

---

## Step 1 — Get the TRMS IDs

| Input | What to do |
|---|---|
| IDs given (`ENG0002-0001, ENT1002-0006`) | Use them, in the order given — that order is the row order in the report. |
| A JIRA key (`IOS-46294`) | `mcp__atlassian__getJiraIssue` → pull every `XXX0000-0000`-shaped ID out of the description, the tracker table, and the comments. Show the extracted list and confirm before running. |
| Nothing | Run without `--ids` — the report then lists every ID that fired, which is how the expected list gets built in the first place. Say that is what you did. |

---

## Step 2 — Confirm there is a session to read

```bash
$LENS trackers --ids <IDS> --format json | head -40
```

- `No trace at …` → the app is not running with tracing on, or was reinstalled
  (new data container). Tell the user to launch the app from Xcode and walk the
  flow, then re-run. Do not launch it yourself.
- Zero fires for everything → almost always the wrong session: the report reads
  the **most recent launch only** unless `--all-sessions` is passed. Ask whether
  the flow was walked in this launch before concluding the trackers are broken.

`mcp__networklens__lens_status` / `lens_stats` are the quick sanity check that
the app is capturing at all.

---

## Step 3 — Build the payload contract (the part that makes this more than "it fired")

"It fired" passes DA review far less often than developers expect — an empty
`origin_screen`, a missing `item_id` on the third item, or `cp1` carrying the
wrong section name all ship as green otherwise.

Ask the user (via `AskUserQuestion`) whether to check payload fields, and if so
where the expectations come from: the JIRA/TRMS tracker table, or dictated. Then
write a contract JSON to the scratchpad:

```json
{
  "ENG0002-0001": {
    "event": "view_item_list",
    "origin_screen": "retail-home",
    "required": ["cp1", "items[].item_id", "items[].item_name", "items[].price"],
    "expect": {"cp1": "Penawaran spesial"}
  },
  "ENT1002-0006": {
    "event": "button_impression",
    "origin_screen": "retail-daily-check-in"
  }
}
```

| Key | Meaning |
|---|---|
| `event` | expected `payload.event`; mismatch is a finding |
| `origin_screen` | expected `payload.origin_screen` |
| `required` | dotted paths that must be present **and non-empty**; `items[]` fans out over every item, so one bad item is caught |
| `expect` | exact expected values |

Every fire of an ID is checked, not just the first — the third impression with a
blank field is exactly the bug this catches. Findings land in the report's
**Status** column, grouped by problem with the fire numbers that carry it.

Run:

```bash
$LENS trackers \
  --ids ENG0002-0001,ENT1002-0006 \
  --contract /path/to/contract.json \
  --out tools/networklens/reports/<TICKET>-tracker-validation.md
```

Name the report after the JIRA key when there is one, else the feature.
`--format json --contract …` gives the same findings machine-readably under
`problems`, which is the form to read when summarising in chat.

---

## Step 4 — Live watch mode (while the tester taps)

For "tell me as I go" / "I'm about to walk the flow", poll the watermarked diff
instead of regenerating the whole report:

```bash
$LENS trackers --reset          # start clean
$LENS trackers --new            # only unreported fires
```

Loop `--new` roughly every 15–30 seconds while the user navigates, and after each
poll report **only what is new**: TRMS ID, event, HTTP status, origin screen, and
anything the contract flags. Say "nothing new since the last check" rather than
repeating the previous output.

- The watermark is keyed on the launch session, so a relaunch starts clean by
  itself — no `--reset` needed after the app restarts.
- Call out an expected ID that is still missing after the user says they walked
  its screen; that is the moment it is cheapest to fix.
- Stop polling when the user says they are done, then generate the full report
  (Step 3) for the session.

---

## Step 5 — Read the report before handing it over

The generated table is evidence plus **two derived, human-checkable columns** —
say so rather than presenting the whole thing as verified fact:

- **Trigger point** is inferred from the payload (`cp1` / `section_name` /
  `button_name` + `origin_screen`). The trace shows what was sent, never what was
  tapped. Correct any row you can from the ticket, and flag the rest.
- **Design** and **Sample Response** are left blank on purpose — neither an image
  nor an API response is present in a tracker request. Fill them in only if the
  user supplies them.

Also read the **"Fired but not on the list"** section. An ID nobody asked to
validate firing on the screen under test is worth raising — usually a copy-paste
of the wrong TRMS ID in the tracker code, which is a real defect even though the
requested IDs all passed.

Summarise in chat as: `N of M fired · K with payload problems · report path`.
Never report "all trackers valid" when a contract was not supplied — say
"all fired; payload fields not checked".

---

## Step 6 — Publish (only if asked)

Ask via `AskUserQuestion` before publishing anything outward; the report is a
local file until the user says otherwise.

- **JIRA comment** — `mcp__atlassian__addCommentToJiraIssue` with the summary
  line, the missing/invalid IDs, and the full table. Keep the report file as the
  source of truth.
- **Confluence** — if the ticket links a tracker/QA page, `getConfluencePage`
  then `updateConfluencePage`, replacing the iOS section only; otherwise
  `createConfluencePage` under the space the user names. Follow the same
  conventions `jira-doc-generator` uses for placement and titles.

State exactly what was posted and where.

---

## Do not

- Do not run `xcodebuild`, boot a simulator, or launch the app.
- Do not conclude a tracker is broken from an empty trace or the wrong session —
  rule out "the flow was not walked in this launch" first.
- Do not edit tracker code from this skill. A confirmed miss hands off to
  `ios-analytics-tracker`, which owns the tracker POP pattern.
- Do not paste a full report into chat when it is already on disk — summary plus
  path, and the failing rows.
