#!/usr/bin/env python3
"""Write NetworkLens mock rules straight into the booted simulator's session.

The app runs with `persistsRules: true` and `keepBreakpointsAcrossLaunches: true`
(see `NetworkLensBootstrap.swift`), so rules written here come back armed on the
next launch — no rebuild, no code change, just quit and relaunch.

Commands:
    apply    --spec spec.json      write/merge rules into session.json
    list                           what is armed right now
    seed     --endpoint "GET /x"   spec skeleton seeded from a real captured response
    activate --rule R --variant V  switch which answer is served
    enable | disable --rule R      arm/disarm one rule
    remove   --rule R              delete a rule
    on | off                       the mocking master switch

The app rewrites session.json on every rule change and when it backgrounds, so a
write while it is running is silently lost. Every mutating command refuses to run
against a live app unless `--force` is passed.
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from datetime import datetime
from pathlib import Path

# Overridable so a developer on a different scheme or a fork of the app does not
# have to edit a committed script.
BUNDLE_ID = os.environ.get("NETWORKLENS_BUNDLE_ID", "com.blibli.mobile")
SESSION_RELATIVE = "Library/Application Support/NetworkLens/session.json"
TRACE_RELATIVE = "Library/Application Support/NetworkLens/trace.ndjson"


def repo_root():
    """The checkout this script lives in, asked of git rather than assumed.

    This file is committed at <root>/tools/networklens, so walking up from
    __file__ would work — until someone runs it through a symlink or moves the
    directory. git answers correctly in both cases.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
            cwd=str(Path(__file__).resolve().parent),
        )
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip())
    except (subprocess.SubprocessError, OSError):
        pass
    return Path(__file__).resolve().parents[2]


BOOTSTRAP = repo_root() / "BlibliMobile-iOS/BlibliMobile-iOS/DevUtils/NetworkLens/NetworkLensBootstrap.swift"

# URLError.Code raw values. Mirrors MockFailure's presets — the labels are what
# the rule list shows, so they are kept identical to the Swift side.
FAILURES = {
    "offline": (-1009, "offline"),
    "timedOut": (-1001, "timed out"),
    "connectionLost": (-1005, "connection lost"),
    "cannotFindHost": (-1003, "DNS failure"),
    "secureConnectionFailed": (-1200, "TLS failure"),
}

EXHAUSTIONS = ("repeatLast", "loop", "passThrough")


# --------------------------------------------------------------------------- #
# Container resolution
# --------------------------------------------------------------------------- #

def container_path():
    """Resolved per run, never cached: a reinstall gives the app a new container."""
    out = subprocess.run(
        ["xcrun", "simctl", "get_app_container", "booted", BUNDLE_ID, "data"],
        capture_output=True, text=True, timeout=30,
    )
    path = out.stdout.strip()
    if out.returncode != 0 or not path:
        sys.exit(
            "No booted simulator with the app installed.\n"
            f"{out.stderr.strip() or 'xcrun simctl get_app_container failed'}"
        )
    return Path(path)


def session_path(explicit=None):
    return Path(explicit) if explicit else container_path() / SESSION_RELATIVE


def app_is_running():
    """A write while the app lives is overwritten by its own autosave."""
    probe = subprocess.run(
        ["pgrep", "-f", f"{BUNDLE_ID}|BlibliMobile-iOS.app/BlibliMobile-iOS"],
        capture_output=True, text=True,
    )
    return probe.returncode == 0 and bool(probe.stdout.strip())


def captured_hosts():
    """The host allowlist the app starts the lens with.

    A mock on a host absent from that list can never fire — the request is
    dropped at `canInit`, before mocking is consulted — and that failure looks
    exactly like a rule that does not match, so it is worth catching up front.
    """
    try:
        text = BOOTSTRAP.read_text(encoding="utf-8")
    except OSError:
        return []
    block = re.search(r"capturedHosts\s*=\s*\[(.*?)\]", text, re.S)
    return re.findall(r'"([^"]+)"', block.group(1)) if block else []


# --------------------------------------------------------------------------- #
# Snapshot I/O
# --------------------------------------------------------------------------- #

def load_snapshot(path):
    if not path.exists():
        return {"mocks": [], "breakpoints": [], "perturbations": [],
                "scenarios": [], "isMockingEnabled": True}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        sys.exit(f"Cannot read {path}: {error}")


def save_snapshot(path, snapshot, force=False):
    if app_is_running() and not force:
        sys.exit(
            "The app is running — it rewrites session.json on every rule change\n"
            "and when it backgrounds, so this write would be lost.\n"
            "Quit the app in the simulator first, or pass --force if you are sure."
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_name(f"{path.name}.bak-{stamp}"))
    path.write_text(json.dumps(snapshot, indent=1, sort_keys=True), encoding="utf-8")


# --------------------------------------------------------------------------- #
# Endpoint keys
# --------------------------------------------------------------------------- #

def is_volatile(segment):
    """Same rule as PathMatcher: numeric, UUID, or a long opaque hex token."""
    if not segment:
        return False
    if segment.isdigit():
        return True
    try:
        uuid.UUID(segment)
        return True
    except ValueError:
        pass
    return len(segment) >= 16 and all(c in "0123456789abcdefABCDEF" for c in segment)


def endpoint_key(method, path):
    """`GET /users/{id}/orders` — the key everything in the lens is keyed by."""
    segments = [s for s in path.split("/") if s]
    templated = "/" + "/".join("{id}" if is_volatile(s) else s for s in segments)
    return f"{method.upper()} {templated if segments else '/'}"


def key_from_url(method, url):
    from urllib.parse import urlparse, parse_qsl
    parsed = urlparse(url)
    query = dict(parse_qsl(parsed.query))
    return endpoint_key(method, parsed.path), parsed.netloc, query


# --------------------------------------------------------------------------- #
# Rule building
# --------------------------------------------------------------------------- #

def encode_body(variant):
    """Body as base64, whatever shape the spec gave it in."""
    if "bodyFile" in variant:
        raw = Path(variant["bodyFile"]).read_bytes()
    else:
        body = variant.get("body")
        if body is None:
            raw = b""
        elif isinstance(body, (dict, list)):
            raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        else:
            raw = str(body).encode("utf-8")
    return base64.b64encode(raw).decode("ascii")


def build_step(variant):
    """One MockOutcome, in the shape Swift's synthesised enum Codable expects."""
    if variant.get("hang"):
        return {"hang": {}}

    failure = variant.get("failure")
    if failure:
        if failure not in FAILURES:
            sys.exit(f"Unknown failure '{failure}'. One of: {', '.join(FAILURES)}")
        code, label = FAILURES[failure]
        return {"fail": {"_0": {"errorCode": code, "label": label,
                                "delay": variant.get("delay", 0)}}}

    headers = dict(variant.get("headers") or {})
    body_is_json = isinstance(variant.get("body"), (dict, list))
    if body_is_json and not any(h.lower() == "content-type" for h in headers):
        headers["Content-Type"] = "application/json"

    return {"respond": {"_0": {
        "statusCode": variant.get("status", 200),
        "headers": headers,
        "body": encode_body(variant),
        "delay": variant.get("delay", 0),
    }}}


def build_variant(variant, existing=None):
    """Reuses the existing variant's id when the name matches.

    Ids are how the active variant and hit counts are addressed, so regenerating
    them on every apply would silently reset which answer is being served.
    """
    steps = ([build_step(step) for step in variant["steps"]]
             if "steps" in variant else [build_step(variant)])
    exhaustion = variant.get("exhaustion", "repeatLast")
    if exhaustion not in EXHAUSTIONS:
        sys.exit(f"Unknown exhaustion '{exhaustion}'. One of: {', '.join(EXHAUSTIONS)}")
    return {
        "id": (existing or {}).get("id") or str(uuid.uuid4()).upper(),
        "name": variant["name"],
        "steps": steps,
        "exhaustion": exhaustion,
    }


def build_match(spec):
    match = {"query": dict(spec.get("match", {}).get("query") or {}),
             "headers": dict(spec.get("match", {}).get("headers") or {})}
    body_contains = spec.get("match", {}).get("bodyContains")
    if body_contains:
        match["bodyContains"] = body_contains
    return match


def same_rule(rule, key, match):
    """Identity is endpointKey *plus* match — that is what Mocks keys rules by."""
    return rule.get("endpointKey") == key and (rule.get("match") or {}) == match


def normalize(spec):
    """Fills endpointKey/query from a pasted URL. Run once per rule — it warns."""
    spec = dict(spec)
    if "url" in spec:
        key, host, query = key_from_url(spec.get("method", "GET"), spec["url"])
        spec.setdefault("endpointKey", key)
        if query and not spec.get("match", {}).get("query"):
            spec.setdefault("match", {})["query"] = query
        hosts = captured_hosts()
        if hosts and host and host not in hosts:
            print(f"warning: {host} is not in capturedHosts {hosts} — "
                  "the lens never sees this request, so the mock cannot fire.",
                  file=sys.stderr)
    return spec


def build_rule(spec, existing=None):
    key = spec["endpointKey"]
    match = build_match(spec)
    existing = existing or {}
    by_name = {v.get("name"): v for v in existing.get("variants", [])}

    variants = [build_variant(v, by_name.get(v["name"])) for v in spec["variants"]]
    if not variants:
        sys.exit(f"Rule {key} has no variants.")

    wanted = spec.get("activeVariant")
    active = next((v for v in variants if v["name"] == wanted), variants[0])

    return {
        "id": existing.get("id") or str(uuid.uuid4()).upper(),
        "endpointKey": key,
        "isEnabled": spec.get("enabled", True),
        "match": match,
        "variants": variants,
        "activeVariantID": active["id"],
    }


# --------------------------------------------------------------------------- #
# Rule lookup
# --------------------------------------------------------------------------- #

def find_rules(snapshot, needle):
    """Matches a rule by endpoint key, variant name, or id — whatever was typed."""
    needle_lower = needle.lower()
    hits = []
    for rule in snapshot.get("mocks", []):
        names = [v.get("name", "") for v in rule.get("variants", [])]
        haystack = [rule.get("endpointKey", ""), rule.get("id", "")] + names
        if any(needle_lower in value.lower() for value in haystack):
            hits.append(rule)
    return hits


def resolve_one(snapshot, needle):
    hits = find_rules(snapshot, needle)
    if not hits:
        sys.exit(f"No rule matching '{needle}'. Run `list` to see what is armed.")
    if len(hits) > 1:
        # Two rules can share an endpoint key and differ only by match, so the
        # key alone is not enough to tell the caller which one to name.
        lines = []
        for rule in hits:
            match = rule.get("match") or {}
            narrow = " ".join(f"{k}={v}" for k, v in (match.get("query") or {}).items())
            lines.append(f"{rule['endpointKey']}{'  ?' + narrow if narrow else ''}"
                         f"  id={rule['id']}")
        joined = "\n  ".join(lines)
        sys.exit(f"'{needle}' matches {len(hits)} rules:\n  {joined}\n"
                 "Name one by its id, or by a variant name unique to it.")
    return hits[0]


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

def cmd_apply(args):
    path = session_path(args.session)
    spec = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    rules = spec.get("rules", [spec] if "variants" in spec else [])
    if not rules:
        sys.exit("Spec has no rules.")

    snapshot = load_snapshot(path)
    existing = snapshot.get("mocks", [])

    written = []
    for rule_spec in rules:
        if "url" not in rule_spec and "endpointKey" not in rule_spec:
            sys.exit("Each rule needs an endpointKey or a url.")
        rule_spec = normalize(rule_spec)
        key, match = rule_spec["endpointKey"], build_match(rule_spec)
        prior = next((r for r in existing if same_rule(r, key, match)), None)
        rule = build_rule(rule_spec, prior)
        if prior:
            existing[existing.index(prior)] = rule
        else:
            existing.append(rule)
        written.append(rule)

    snapshot["mocks"] = existing
    if args.enable_mocking:
        snapshot["isMockingEnabled"] = True

    if args.dry_run:
        print(json.dumps(snapshot, indent=1, sort_keys=True))
        return

    save_snapshot(path, snapshot, args.force)
    for rule in written:
        active = next(v["name"] for v in rule["variants"] if v["id"] == rule["activeVariantID"])
        print(f"{'armed' if rule['isEnabled'] else 'saved (off)'}  {rule['endpointKey']}"
              f"  [{', '.join(v['name'] for v in rule['variants'])}]  active: {active}")
    print(f"\n{path}\nRelaunch the app for these to take effect.")


def cmd_list(args):
    path = session_path(args.session)
    snapshot = load_snapshot(path)
    rules = snapshot.get("mocks", [])
    print(f"mocking master switch: {'ON' if snapshot.get('isMockingEnabled', True) else 'OFF'}")
    if not rules:
        print("no rules")
        return
    for rule in rules:
        active_id = rule.get("activeVariantID")
        variants = ", ".join(
            f"*{v['name']}*" if v["id"] == active_id else v["name"]
            for v in rule.get("variants", [])
        )
        match = rule.get("match") or {}
        narrow = " ".join(f"{k}={v}" for k, v in (match.get("query") or {}).items())
        print(f"[{'x' if rule.get('isEnabled') else ' '}] {rule['endpointKey']}"
              f"{'  ?' + narrow if narrow else ''}  ({variants})")


def cmd_activate(args):
    path = session_path(args.session)
    snapshot = load_snapshot(path)
    rule = resolve_one(snapshot, args.rule)
    variant = next((v for v in rule["variants"] if v["name"].lower() == args.variant.lower()), None)
    if not variant:
        names = ", ".join(v["name"] for v in rule["variants"])
        sys.exit(f"No variant '{args.variant}' on {rule['endpointKey']}. Have: {names}")
    rule["activeVariantID"] = variant["id"]
    rule["isEnabled"] = True
    save_snapshot(path, snapshot, args.force)
    print(f"{rule['endpointKey']} → {variant['name']} (armed). Relaunch to apply.")


def cmd_toggle(args, enabled):
    path = session_path(args.session)
    snapshot = load_snapshot(path)
    hits = find_rules(snapshot, args.rule)
    if not hits:
        sys.exit(f"No rule matching '{args.rule}'.")
    for rule in hits:
        rule["isEnabled"] = enabled
        print(f"{'enabled' if enabled else 'disabled'}  {rule['endpointKey']}")
    save_snapshot(path, snapshot, args.force)
    print("Relaunch to apply.")


def cmd_remove(args):
    path = session_path(args.session)
    snapshot = load_snapshot(path)
    doomed = find_rules(snapshot, args.rule)
    if not doomed:
        sys.exit(f"No rule matching '{args.rule}'.")
    for rule in doomed:
        print(f"removed  {rule['endpointKey']}")
    snapshot["mocks"] = [r for r in snapshot.get("mocks", []) if r not in doomed]
    save_snapshot(path, snapshot, args.force)
    print("Relaunch to apply.")


def cmd_switch(args, enabled):
    path = session_path(args.session)
    snapshot = load_snapshot(path)
    snapshot["isMockingEnabled"] = enabled
    save_snapshot(path, snapshot, args.force)
    print(f"mocking {'ON' if enabled else 'OFF'} — every rule stays saved. Relaunch to apply.")


def cmd_seed(args):
    """Spec skeleton carrying the endpoint's last real response as the body.

    Editing a captured payload beats inventing one: the field the app actually
    reads is present, spelled the way the backend spells it.
    """
    trace = Path(args.trace) if args.trace else container_path() / TRACE_RELATIVE
    if not trace.exists():
        sys.exit(f"No trace at {trace}. Run the app with tracing on first.")

    latest = None
    with trace.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                exchange = json.loads(line).get("exchange") or {}
            except json.JSONDecodeError:
                continue
            key = exchange.get("endpointKey", "")
            if args.endpoint.lower() not in key.lower():
                continue
            if (exchange.get("response") or {}).get("body"):
                latest = exchange

    if not latest:
        sys.exit(f"No captured response for '{args.endpoint}' in {trace}.")

    raw = base64.b64decode((latest.get("response") or {}).get("body") or "")
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        body = raw.decode("utf-8", "replace")

    print(json.dumps({"rules": [{
        "endpointKey": latest.get("endpointKey"),
        "enabled": True,
        "activeVariant": "Captured",
        "variants": [{
            "name": "Captured",
            "status": (latest.get("response") or {}).get("statusCode", 200),
            "body": body,
        }],
    }]}, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--session", help="session.json path; defaults to the booted sim")
    parser.add_argument("--force", action="store_true",
                        help="write even though the app is running (it may overwrite you)")
    sub = parser.add_subparsers(dest="command", required=True)

    apply_parser = sub.add_parser("apply", help="write/merge rules from a spec file")
    apply_parser.add_argument("--spec", required=True)
    apply_parser.add_argument("--dry-run", action="store_true",
                              help="print the resulting snapshot, write nothing")
    apply_parser.add_argument("--enable-mocking", action="store_true", default=True,
                              help="also turn the master switch on (default)")

    sub.add_parser("list", help="what is armed right now")

    seed_parser = sub.add_parser("seed", help="spec seeded from a real captured response")
    seed_parser.add_argument("--endpoint", required=True)
    seed_parser.add_argument("--trace", help="trace.ndjson path; defaults to the booted sim")

    activate_parser = sub.add_parser("activate", help="switch the served variant")
    activate_parser.add_argument("--rule", required=True)
    activate_parser.add_argument("--variant", required=True)

    for name in ("enable", "disable", "remove"):
        rule_parser = sub.add_parser(name)
        rule_parser.add_argument("--rule", required=True)

    sub.add_parser("on", help="mocking master switch on")
    sub.add_parser("off", help="mocking master switch off")

    args = parser.parse_args()
    handlers = {
        "apply": cmd_apply,
        "list": cmd_list,
        "seed": cmd_seed,
        "activate": cmd_activate,
        "enable": lambda a: cmd_toggle(a, True),
        "disable": lambda a: cmd_toggle(a, False),
        "remove": cmd_remove,
        "on": lambda a: cmd_switch(a, True),
        "off": lambda a: cmd_switch(a, False),
    }
    handlers[args.command](args)


if __name__ == "__main__":
    main()
