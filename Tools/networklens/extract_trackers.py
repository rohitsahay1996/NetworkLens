#!/usr/bin/env python3
"""Extract TRMS-ID tracker fires from a NetworkLens trace.

Coverage report: which of the expected TRMS IDs fired, how often, on which
endpoint, and the request body each one carried.

The trace is append-only and an exchange is rewritten on every later edit, so
rows are collapsed by exchange id keeping the last occurrence — the same rule
the MCP reader uses. Without that a replayed or edited request counts twice.

Usage:
    extract_trackers.py --ids ENG0002-0001,ENG1011-0001 [--trace PATH]
    extract_trackers.py --ids-file ids.txt --format markdown
"""

import argparse
import base64
import json
import os
import subprocess
import sys
from collections import OrderedDict
from datetime import datetime
from pathlib import Path

TRACE_RELATIVE = "Library/Application Support/NetworkLens/trace.ndjson"
BUNDLE_ID = os.environ.get("NETWORKLENS_BUNDLE_ID", "com.blibli.mobile")
TRMS_KEY = "trms_id"


def resolve_trace(explicit):
    """Mirrors the MCP server's resolution so both read the same file.

    Resolved per run rather than cached: a reinstall gives the app a new data
    container, which is exactly the stale-path failure the MCP server hits.
    """
    if explicit:
        return Path(explicit)
    try:
        out = subprocess.run(
            ["xcrun", "simctl", "get_app_container", "booted", BUNDLE_ID, "data"],
            capture_output=True, text=True, timeout=30,
        )
        container = out.stdout.strip()
        if out.returncode == 0 and container:
            return Path(container) / TRACE_RELATIVE
    except (subprocess.SubprocessError, OSError):
        pass
    return Path.home() / TRACE_RELATIVE


def load_exchanges(path):
    """Last line wins per exchange id; a partial final line is skipped."""
    if not path.exists():
        sys.exit(f"No trace at {path}\nIs the app running with NetworkLens tracing on?")

    collapsed = OrderedDict()
    sessions = OrderedDict()
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            exchange = record.get("exchange")
            if not isinstance(exchange, dict) or "id" not in exchange:
                continue
            collapsed[exchange["id"]] = exchange
            sessions.setdefault(record.get("sessionID"), []).append(exchange["id"])
    return collapsed, sessions


def decode_body(snapshot):
    raw = (snapshot or {}).get("body")
    if not raw:
        return None
    try:
        return base64.b64decode(raw).decode("utf-8", "replace")
    except (ValueError, TypeError):
        return raw if isinstance(raw, str) else None


def find_trms_ids(node):
    """Every trms_id in the payload, at any depth.

    Recursive rather than a fixed payload.trms_id lookup: the key sits at
    payload level today, and a nested per-item variant should surface as a
    finding rather than be silently missed.
    """
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == TRMS_KEY and isinstance(value, (str, int)):
                found.append(str(value))
            found.extend(find_trms_ids(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(find_trms_ids(item))
    return found


def collect(exchanges, session_filter=None):
    """TRMS ID -> every fire of it, in trace order."""
    fires = OrderedDict()
    for exchange_id, exchange in exchanges.items():
        if session_filter and exchange_id not in session_filter:
            continue
        body = decode_body(exchange.get("request"))
        if not body or TRMS_KEY not in body:
            continue
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            continue
        for trms_id in find_trms_ids(parsed):
            fires.setdefault(trms_id, []).append({
                "exchangeID": exchange_id,
                "endpoint": exchange.get("endpointKey", "?"),
                "status": (exchange.get("response") or {}).get("statusCode"),
                "startedAt": exchange.get("startedAt"),
                "event": (parsed.get("payload") or {}).get("event"),
                "originScreen": (parsed.get("payload") or {}).get("origin_screen"),
                "body": parsed,
            })
    return fires


TMS_DETAIL = "https://tracker-management-system.gdn-app.com/tracker-detail/"


def cell_json(obj):
    """JSON inside a markdown table cell.

    Newlines end a table row, so line breaks become `<br>` and indentation
    becomes non-breaking spaces. A literal pipe would split the cell, so it is
    escaped even though tracker payloads rarely carry one.
    """
    text = json.dumps(obj, indent=2, ensure_ascii=False)
    text = text.replace("|", "\\|")
    lines = []
    for line in text.split("\n"):
        stripped = line.lstrip(" ")
        indent = "&nbsp;" * (len(line) - len(stripped))
        lines.append(indent + stripped)
    return "<br>".join(lines)


def trigger_point(payload):
    """Best guess at the trigger, from whatever the payload names itself by.

    A guess, and labelled as one on the page: the trace shows what was sent,
    never what the tester tapped to send it. Left for a human to correct.
    """
    screen = payload.get("origin_screen") or "—"
    # cp1 carries the section's display title on list events, which reads better
    # than anything under items — item_list_name is often a flag pair, not a name.
    for key, shape in (
        ("button_name", "On click/view {} in {}"),
        ("section_name", "On view {} section in {}"),
        ("cp1", "On view {} section in {}"),
    ):
        value = payload.get(key)
        if value:
            return shape.format(value, screen)
    items = payload.get("items")
    if isinstance(items, list) and items:
        name = (items[0] or {}).get("promotion_name")
        if name:
            return f"On view promotion {name} in {screen}"
    component = payload.get("component")
    return f"On {payload.get('event', 'event')} of {component} in {screen}" if component else f"In {screen}"


def resolve_path(payload, path):
    """Values at a dotted path, with `items[]` fanning out over a list.

    Returns a list rather than one value because `items[].item_id` asks about
    every item — one item missing the key is a finding, and a scalar return
    would hide it behind the first item that has it.
    """
    nodes = [payload]
    for segment in path.split("."):
        fanned = segment.endswith("[]")
        key = segment[:-2] if fanned else segment
        collected = []
        for node in nodes:
            if not isinstance(node, dict) or key not in node:
                continue
            value = node[key]
            if fanned:
                collected.extend(value if isinstance(value, list) else [value])
            else:
                collected.append(value)
        nodes = collected
        if not nodes:
            return []
    return nodes


def is_blank(value):
    """Empty is a failure, not a pass — an empty `origin_screen` breaks the DA
    report exactly as a missing one does, and the app sends "" far more often."""
    return value is None or value == "" or value == [] or value == {}


def check_contract(hit, rule):
    """Everything wrong with one fire, against the expected-payload rule.

    A rule is what the tracker document promises; this is where "it fired" gets
    upgraded to "it fired correctly", which is the part a DA rejects a ticket for.
    """
    if not rule:
        return []
    payload = hit["body"].get("payload") or {}
    problems = []

    expected_event = rule.get("event")
    if expected_event and hit.get("event") != expected_event:
        problems.append(f"event is `{hit.get('event') or '—'}`, expected `{expected_event}`")

    expected_screen = rule.get("origin_screen")
    if expected_screen and payload.get("origin_screen") != expected_screen:
        problems.append(
            f"origin_screen is `{payload.get('origin_screen') or '—'}`, "
            f"expected `{expected_screen}`"
        )

    for path in rule.get("required", []):
        values = resolve_path(payload, path)
        if not values:
            problems.append(f"missing `{path}`")
        elif any(is_blank(value) for value in values):
            problems.append(f"`{path}` is empty")

    for path, wanted in (rule.get("expect") or {}).items():
        values = resolve_path(payload, path)
        if not values:
            problems.append(f"missing `{path}` (expected `{wanted}`)")
        elif any(value != wanted for value in values):
            problems.append(f"`{path}` is `{values[0]}`, expected `{wanted}`")

    return problems


def render_markdown(expected, fires, provenance=None, contracts=None):
    hit = [i for i in expected if i in fires]
    missed = [i for i in expected if i not in fires]
    unexpected = [i for i in fires if i not in expected]

    versions = sorted({
        f["body"].get("app_version") for hits in fires.values() for f in hits
        if f["body"].get("app_version")
    })

    lines = ["# Trackers Validation", ""]
    lines += ["| | |", "|---|---|"]
    lines.append(f"| **Trackers** | {', '.join(f'[{i}]({TMS_DETAIL}{i})' for i in expected)} |")
    if provenance:
        for label, value in provenance.items():
            lines.append(f"| **{label}** | {value} |")
    lines.append("")

    lines += ["## iOS", ""]
    lines.append(f"Validated in **{', '.join(versions) or '<build_no>'}**")
    lines.append("")
    invalid = [
        i for i in hit
        if any(check_contract(one, (contracts or {}).get(i)) for one in fires[i])
    ]
    lines.append(
        f"{len(hit)} of {len(expected)} trackers fired."
        + (f" Not seen: {', '.join(f'`{i}`' for i in missed)}" if missed else "")
        + (f" Fired with payload problems: {', '.join(f'`{i}`' for i in invalid)}" if invalid else "")
    )
    lines.append("")

    header = ("|  | **Event Name** | **Tracker Contract** | **Trigger point** | **Design** "
              "| **Sample Response** | **Tracker Payload** | **Status** | **DA Feedback** |")
    lines += [header, "|---|---|---|---|---|---|---|---|---|"]

    for index, trms_id in enumerate(expected, start=1):
        hits = fires.get(trms_id)
        contract = f"[{trms_id}]({TMS_DETAIL}{trms_id})"
        if not hits:
            lines.append(
                f"| {index} | — | {contract} | — |  |  | **Not fired in this session** "
                f"| Need fix |  |"
            )
            continue
        first = hits[0]
        payload = first["body"].get("payload") or {}
        event = first["event"] or "—"
        repeats = f"<br><br>_Fired {len(hits)}× this session; first shown._" if len(hits) > 1 else ""
        # Checked against every fire, not just the first shown: the third
        # impression carrying an empty item_id is the bug, and it would be
        # invisible if only the first were validated.
        rule = (contracts or {}).get(trms_id)
        # Grouped by problem rather than by fire: the same missing key across
        # six impressions is one bug, and six identical lines in a table cell
        # buries the second, different one.
        grouped = OrderedDict()
        for position, one in enumerate(hits, start=1):
            for problem in check_contract(one, rule):
                grouped.setdefault(problem, []).append(position)
        problems = [
            problem if len(where) == len(hits) and len(hits) == 1
            else f"{problem} (fire{'s' if len(where) > 1 else ''} {', '.join(map(str, where))})"
            for problem, where in grouped.items()
        ]
        status = "Valid" if not problems else "**Need fix**<br>" + "<br>".join(problems)
        lines.append(
            f"| {index} | **{event}** | {contract} | {trigger_point(payload)} |  |  "
            f"| `{first['endpoint']}` → HTTP {first['status']}<br><br>{cell_json(first['body'])}{repeats} "
            f"| {status} |  |"
        )
    lines.append("")
    lines.append("_Trigger points are derived from the payload and need a human check. "
                 "Design and Sample Response are left blank — images and API responses "
                 "are not in the tracker request._")
    lines.append("")

    if unexpected:
        lines += ["## Fired but not on the list", "",
                  "Not a failure on its own, but an ID nobody asked to validate is worth a look.", "",
                  "| TRMS ID | Event | Fires | Origin screen |", "|---|---|---|---|"]
        for trms_id in unexpected:
            hits = fires[trms_id]
            screens = sorted({h["originScreen"] for h in hits if h["originScreen"]})
            lines.append(f"| [{trms_id}]({TMS_DETAIL}{trms_id}) | `{hits[0]['event'] or '—'}` "
                         f"| {len(hits)} | {', '.join(screens) or '—'} |")
        lines.append("")

    return "\n".join(lines)


# Host side, not in the repo: "what have I already looked at" is one
# developer's cursor through their own simulator, never a shared fact.
WATERMARK = Path.home() / "Library/Application Support/NetworkLens/.last-seen.json"


def load_watermark(session_id):
    """Exchange ids already reported for this session.

    Keyed on the session so a relaunch starts clean — a new launch is a new
    run, and carrying the previous one's watermark would hide its first fires.
    """
    try:
        saved = json.loads(WATERMARK.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    if saved.get("session") != session_id:
        return set()
    return set(saved.get("seen", []))


def save_watermark(session_id, seen):
    try:
        WATERMARK.write_text(
            json.dumps({"session": session_id, "seen": sorted(seen)}),
            encoding="utf-8",
        )
    except OSError:
        pass  # A watermark that cannot be written is not worth failing a report over.


def render_new(fires, already_seen):
    """Only the fires whose exchange has not been reported yet."""
    fresh = []
    for trms_id, hits in fires.items():
        for hit in hits:
            if hit["exchangeID"] not in already_seen:
                fresh.append((trms_id, hit))
    fresh.sort(key=lambda pair: pair[1].get("startedAt") or "")

    if not fresh:
        return "No new tracker fires since the last check.", []

    lines = [f"{len(fresh)} new fire(s):", ""]
    for trms_id, hit in fresh:
        payload = hit["body"].get("payload") or {}
        extras = {k: v for k, v in payload.items()
                  if k not in ("trms_id", "event", "origin_screen", "items")}
        lines.append(f"  {trms_id}  {hit['event'] or '—'}  →  HTTP {hit['status']}")
        lines.append(f"      screen: {payload.get('origin_screen') or '—'}")
        if extras:
            rendered = "  ".join(f"{k}={json.dumps(v, ensure_ascii=False)}"
                                 for k, v in list(extras.items())[:6])
            lines.append(f"      {rendered}")
        items = payload.get("items")
        if isinstance(items, list) and items:
            lines.append(f"      items: {len(items)}")
        lines.append("")
    return "\n".join(lines), [hit["exchangeID"] for _, hit in fresh]


def write_report(text, out_path):
    if not out_path:
        print(text)
        return
    destination = Path(out_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text + "\n", encoding="utf-8")
    print(f"Wrote {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", help="trace.ndjson path; defaults to the booted sim's container")
    parser.add_argument("--ids", help="comma-separated TRMS IDs to validate")
    parser.add_argument("--ids-file", help="file with one TRMS ID per line")
    parser.add_argument("--all-sessions", action="store_true",
                        help="include every launch, not just the most recent")
    parser.add_argument("--format", choices=["markdown", "json"], default="markdown")
    parser.add_argument("--new", action="store_true",
                        help="only fires not reported by a previous --new run")
    parser.add_argument("--reset", action="store_true",
                        help="forget the --new watermark and start over")
    parser.add_argument("--contract", help="JSON of expected payload rules per TRMS ID")
    parser.add_argument("--out", help="write the report here instead of stdout")
    args = parser.parse_args()

    expected = []
    if args.ids:
        expected = [i.strip() for i in args.ids.split(",") if i.strip()]
    elif args.ids_file:
        text = Path(args.ids_file).read_text(encoding="utf-8")
        expected = [line.strip() for line in text.splitlines()
                    if line.strip() and not line.startswith("#")]

    contracts = {}
    if args.contract:
        contracts = json.loads(Path(args.contract).read_text(encoding="utf-8"))
        unknown = [i for i in contracts if expected and i not in expected]
        if unknown:
            # A contract for an ID nobody is validating is almost always a typo
            # in the ID, which would otherwise pass as "no rule, nothing to check".
            print(f"warning: contract has IDs not in the validated list: "
                  f"{', '.join(unknown)}", file=sys.stderr)

    path = resolve_trace(args.trace)
    exchanges, sessions = load_exchanges(path)

    session_filter = None
    if not args.all_sessions and sessions:
        session_filter = set(list(sessions.values())[-1])

    fires = collect(exchanges, session_filter)

    # No list given: report what is there, which is how you build the list.
    if not expected:
        expected = sorted(fires)

    session_id = list(sessions)[-1] if sessions else "unknown"

    if args.reset:
        WATERMARK.unlink(missing_ok=True)
        print("Watermark cleared.")
        if not args.new:
            return

    if args.new:
        already_seen = load_watermark(session_id)
        report, fresh_ids = render_new(fires, already_seen)
        print(report)
        save_watermark(session_id, already_seen | set(fresh_ids))
        return

    if args.format == "json":
        problems = {
            trms_id: sorted({
                problem for one in hits
                for problem in check_contract(one, contracts.get(trms_id))
            })
            for trms_id, hits in fires.items()
        }
        report = json.dumps(
            {"trace": str(path), "expected": expected, "fires": fires,
             "problems": {k: v for k, v in problems.items() if v}},
            indent=2, ensure_ascii=False,
        )
        write_report(report, args.out)
    else:
        provenance = OrderedDict([
            ("Generated", datetime.now().strftime("%Y-%m-%d %H:%M")),
            ("Session", f"`{session_id}`" + ("" if not args.all_sessions else " (all sessions)")),
            ("Exchanges in session", len(session_filter) if session_filter else len(exchanges)),
            ("Trace", f"`{path}`"),
        ])
        write_report(render_markdown(expected, fires, provenance, contracts), args.out)


if __name__ == "__main__":
    main()
